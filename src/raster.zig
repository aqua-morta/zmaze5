//! Native rasterizer for PNG output (no cairo needed).
//!
//! The same drawing context as vector.zig (paths with lines, Bézier curves
//! and arcs, stroking with round caps and joins, filling, translation and
//! rotation, text), rendered into an RGBA image with anti-aliasing:
//!
//! * Paths are transformed to device space and flattened into polygons
//!   (curves and arcs within 0.05 pixel; the vertices of arcs lie
//!   slightly outside the circle, so that the polygon has the circle's
//!   area).
//! * Polygons are filled with the nonzero winding rule (cairo's default):
//!   every pixel row is sampled at `SUBSAMPLES` heights, along each of
//!   them the exact horizontal coverage of the spans with nonzero winding
//!   is accumulated.
//! * Strokes are converted to polygons first: a rectangle per segment, a
//!   circle at every corner and end (round joins and caps; nearly straight
//!   corners only need a small wedge). All polygons are oriented the same
//!   way, so with nonzero winding they merge without seams or double
//!   coverage.
//! * Text is drawn with a small built-in stroke font (cairo's or the
//!   system's fonts aren't available), with capitals as high as the other
//!   outputs' text.
//!
//! Colors are blended with the "over" operator on premultiplied pixels.
//! A knockout group is drawn on a cleared image (the pixels below are kept
//! aside), its cut out area is erased, then it is blended over the pixels
//! below.

const std = @import("std");
const geo = @import("geo.zig");
const png = @import("png.zig");
const vector = @import("vector.zig");

const Allocator = std.mem.Allocator;
const Vec2 = geo.Vec2;
const Color = vector.Color;
const TextAlign = vector.TextAlign;

const SUBSAMPLES = 16;
/// maximum deviation of flattened curves from the true curve (pixels)
const TOLERANCE = 0.05;
/// curves (Bézier) only need cairo's tolerance
const CURVE_TOLERANCE = 0.1;
/// corners turning less than this (radians) get a wedge instead of a
/// round join
const MIN_JOIN_ANGLE = 0.2;

const Edge = struct {
    x0: f64,
    y0: f64,
    y1: f64,
    /// dx / dy
    slope: f64,
    dir: i32,

    fn xAt(e: Edge, y: f64) f64 {
        return e.x0 + (y - e.y0) * e.slope;
    }
};

const Crossing = struct { x: f64, dir: i32, edge: usize };

const Subpath = struct { start: usize, len: usize, closed: bool };

pub const Canvas = struct {
    gpa: Allocator,
    width: usize,
    height: usize,
    /// premultiplied RGBA
    pixels: []u8,
    /// user to device: x' = a·x + c·y + e, y' = b·x + d·y + f
    ctm: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    color: Color = .{ .red = 0, .green = 0, .blue = 0 },
    line_width: f64 = 2,
    /// the current path in device coordinates
    points: std.ArrayListUnmanaged(Vec2) = .empty,
    subpaths: std.ArrayListUnmanaged(Subpath) = .empty,
    /// current point (device) and whether the next segment starts a new
    /// subpath at it (after closePath)
    current: ?Vec2 = null,
    reopen: bool = false,
    // scratch buffers
    edges: std.ArrayListUnmanaged(Edge) = .empty,
    poly: std.ArrayListUnmanaged(Vec2) = .empty,
    /// the pixels below the open knockout group
    backdrop: ?[]u8 = null,
    /// fills erase (reduce the alpha by the coverage) instead of painting
    erasing: bool = false,

    pub fn init(gpa: Allocator, width: usize, height: usize) !Canvas {
        const pixels = try gpa.alloc(u8, width * height * 4);
        @memset(pixels, 0);
        return .{ .gpa = gpa, .width = width, .height = height, .pixels = pixels };
    }

    pub fn deinit(cv: *Canvas) void {
        cv.gpa.free(cv.pixels);
        cv.points.deinit(cv.gpa);
        cv.subpaths.deinit(cv.gpa);
        cv.edges.deinit(cv.gpa);
        cv.poly.deinit(cv.gpa);
        if (cv.backdrop) |b| cv.gpa.free(b);
    }

    // -- state ---------------------------------------------------------

    pub fn setColor(cv: *Canvas, col: Color) !void {
        cv.color = col;
    }

    pub fn setLineWidth(cv: *Canvas, w: f64) !void {
        cv.line_width = w;
    }

    pub fn translate(cv: *Canvas, x: f64, y: f64) !void {
        const m = &cv.ctm;
        m[4] += m[0] * x + m[2] * y;
        m[5] += m[1] * x + m[3] * y;
    }

    pub fn rotate(cv: *Canvas, angle: f64) !void {
        const s = @sin(angle);
        const co = @cos(angle);
        const m = cv.ctm;
        cv.ctm[0] = m[0] * co + m[2] * s;
        cv.ctm[1] = m[1] * co + m[3] * s;
        cv.ctm[2] = -m[0] * s + m[2] * co;
        cv.ctm[3] = -m[1] * s + m[3] * co;
    }

    fn device(cv: *const Canvas, x: f64, y: f64) Vec2 {
        const m = cv.ctm;
        return .{ .x = m[0] * x + m[2] * y + m[4], .y = m[1] * x + m[3] * y + m[5] };
    }

    /// Length scale of the transformation (it only translates and rotates
    /// here, but stay general).
    fn scale(cv: *const Canvas) f64 {
        const m = cv.ctm;
        return @sqrt(@abs(m[0] * m[3] - m[1] * m[2]));
    }

    // -- paths ---------------------------------------------------------

    fn addPoint(cv: *Canvas, p: Vec2) !void {
        try cv.points.append(cv.gpa, p);
        cv.subpaths.items[cv.subpaths.items.len - 1].len += 1;
        cv.current = p;
    }

    fn moveDevice(cv: *Canvas, p: Vec2) !void {
        try cv.subpaths.append(cv.gpa, .{ .start = cv.points.items.len, .len = 0, .closed = false });
        cv.reopen = false;
        try cv.addPoint(p);
    }

    fn lineDevice(cv: *Canvas, p: Vec2) !void {
        if (cv.current == null) return cv.moveDevice(p);
        if (cv.reopen) try cv.moveDevice(cv.current.?);
        try cv.addPoint(p);
    }

    pub fn moveTo(cv: *Canvas, x: f64, y: f64) !void {
        try cv.moveDevice(cv.device(x, y));
    }

    pub fn lineTo(cv: *Canvas, x: f64, y: f64) !void {
        try cv.lineDevice(cv.device(x, y));
    }

    pub fn curveTo(cv: *Canvas, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) !void {
        const p1 = cv.device(x1, y1);
        if (cv.current == null) try cv.moveDevice(p1);
        const p0 = cv.current.?;
        const p2 = cv.device(x2, y2);
        const p3 = cv.device(x3, y3);
        // the deviation of n uniform chords is at most |p0-2p1+p2|/(4n²)
        // (and likewise for p1, p2, p3)
        const d1 = p0.sub(p1.scale(2)).add(p2).len();
        const d2 = p1.sub(p2.scale(2)).add(p3).len();
        const dd = @max(d1, d2);
        const n: usize = @min(1000, @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(3.0 * dd / (4.0 * CURVE_TOLERANCE)))))));
        for (1..n + 1) |i| {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            const u = 1 - t;
            const p = p0.scale(u * u * u).add(p1.scale(3 * u * u * t)).add(p2.scale(3 * u * t * t)).add(p3.scale(t * t * t));
            try cv.lineDevice(p);
        }
    }

    pub fn arc(cv: *Canvas, xc: f64, yc: f64, r: f64, a1: f64, a2_: f64) !void {
        var a2 = a2_;
        while (a2 < a1) a2 += 2 * std.math.pi;
        try cv.arcPoints(xc, yc, r, a1, a2);
    }

    pub fn arcNegative(cv: *Canvas, xc: f64, yc: f64, r: f64, a1: f64, a2_: f64) !void {
        var a2 = a2_;
        while (a2 > a1) a2 -= 2 * std.math.pi;
        try cv.arcPoints(xc, yc, r, a1, a2);
    }

    fn arcPoints(cv: *Canvas, xc: f64, yc: f64, r: f64, a1: f64, a2: f64) !void {
        const n = segmentsFor(r * cv.scale(), @abs(a2 - a1));
        const rr = r * areaFactor(@abs(a2 - a1) / @as(f64, @floatFromInt(n)));
        for (0..n + 1) |i| {
            const a = a1 + (a2 - a1) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            // the end points exactly on the circle (they connect to lines)
            const ri = if (i == 0 or i == n) r else rr;
            const p = cv.device(xc + ri * @cos(a), yc + ri * @sin(a));
            // like cairo: a line from the current point to the start
            if (i == 0 and cv.current == null) try cv.moveDevice(p) else try cv.lineDevice(p);
        }
    }

    pub fn closePath(cv: *Canvas) !void {
        if (cv.current == null or cv.reopen) return;
        const sp = &cv.subpaths.items[cv.subpaths.items.len - 1];
        sp.closed = true;
        cv.current = cv.points.items[sp.start];
        cv.reopen = true;
    }

    pub fn rectangle(cv: *Canvas, x: f64, y: f64, w: f64, h: f64) !void {
        try cv.moveTo(x, y);
        try cv.lineTo(x + w, y);
        try cv.lineTo(x + w, y + h);
        try cv.lineTo(x, y + h);
        try cv.closePath();
    }

    fn clearPath(cv: *Canvas) void {
        cv.points.clearRetainingCapacity();
        cv.subpaths.clearRetainingCapacity();
        cv.current = null;
        cv.reopen = false;
    }

    // -- painting ------------------------------------------------------

    pub fn fill(cv: *Canvas) !void {
        try cv.fillPath();
        cv.clearPath();
    }

    pub fn stroke(cv: *Canvas) !void {
        try cv.strokePath();
        cv.clearPath();
    }

    pub fn fillStroke(cv: *Canvas) !void {
        try cv.fillPath();
        try cv.strokePath();
        cv.clearPath();
    }

    // -- knockout (see vector.zig) --------------------------------------

    pub fn beginKnockout(cv: *Canvas) !void {
        std.debug.assert(cv.backdrop == null);
        cv.backdrop = try cv.gpa.dupe(u8, cv.pixels);
        @memset(cv.pixels, 0);
    }

    /// Erases the area of the current path from the group's drawing and
    /// blends the group over the pixels below.
    pub fn endKnockout(cv: *Canvas) !void {
        const below = cv.backdrop.?;
        cv.backdrop = null;
        defer cv.gpa.free(below);
        cv.erasing = true;
        defer cv.erasing = false;
        try cv.fill();
        const px = cv.pixels;
        var i: usize = 0;
        while (i < px.len) : (i += 4) {
            const keep: u32 = 255 - @as(u32, px[i + 3]);
            for (0..4) |k| px[i + k] = @intCast(@min(255, @as(u32, px[i + k]) + (@as(u32, below[i + k]) * keep + 127) / 255));
        }
    }

    fn fillPath(cv: *Canvas) !void {
        cv.edges.clearRetainingCapacity();
        for (cv.subpaths.items) |sp| {
            const pts = cv.points.items[sp.start..][0..sp.len];
            for (pts, 0..) |p, i| try cv.addEdge(p, pts[(i + 1) % pts.len]);
        }
        try cv.rasterize();
    }

    fn strokePath(cv: *Canvas) !void {
        cv.edges.clearRetainingCapacity();
        const hw = cv.line_width * cv.scale() / 2;
        if (hw <= 0) return;
        for (cv.subpaths.items) |sp| try cv.strokeSubpath(cv.points.items[sp.start..][0..sp.len], sp.closed, hw);
        try cv.rasterize();
    }

    fn strokeSubpath(cv: *Canvas, raw: []const Vec2, closed: bool, hw: f64) !void {
        // without repeated points
        var pts: std.ArrayListUnmanaged(Vec2) = .empty;
        defer pts.deinit(cv.gpa);
        for (raw) |p| {
            if (pts.items.len == 0 or p.sub(pts.items[pts.items.len - 1]).len2() > 1e-12) try pts.append(cv.gpa, p);
        }
        if (closed and pts.items.len > 1 and pts.items[0].sub(pts.items[pts.items.len - 1]).len2() <= 1e-12) _ = pts.pop();
        const p = pts.items;
        if (p.len == 0) return;
        if (p.len == 1) {
            // a zero length segment gets a round dot (not a lone move)
            if (raw.len > 1 or closed) try cv.addCircle(p[0], hw);
            return;
        }
        const n = p.len;
        const n_seg = if (closed) n else n - 1;
        for (0..n_seg) |i| {
            const a = p[i];
            const b = p[(i + 1) % n];
            const d = b.sub(a);
            const nrm = Vec2{ .x = -d.y, .y = d.x };
            const o = nrm.scale(hw / nrm.len());
            try cv.addPolygon(&.{ a.add(o), b.add(o), b.sub(o), a.sub(o) });
        }
        // joins (and caps)
        for (0..n) |i| {
            const is_end = !closed and (i == 0 or i == n - 1);
            if (is_end) {
                try cv.addCircle(p[i], hw);
                continue;
            }
            const prev = p[(i + n - 1) % n];
            const next = p[(i + 1) % n];
            const d1 = p[i].sub(prev);
            const d2 = next.sub(p[i]);
            const cross = d1.x * d2.y - d1.y * d2.x;
            const dot = d1.x * d2.x + d1.y * d2.y;
            const turn = @abs(std.math.atan2(cross, dot));
            if (turn > MIN_JOIN_ANGLE) {
                try cv.addCircle(p[i], hw);
            } else if (turn > 0) {
                // fill the small gap on the outer side of the corner (the
                // inner side is covered by both segments)
                const side: f64 = if (cross > 0) -1 else 1;
                const n1 = (Vec2{ .x = -d1.y, .y = d1.x }).scale(side * hw / d1.len());
                const n2 = (Vec2{ .x = -d2.y, .y = d2.x }).scale(side * hw / d2.len());
                try cv.addPolygon(&.{ p[i], p[i].add(n1), p[i].add(n2) });
            }
        }
    }

    fn addCircle(cv: *Canvas, c: Vec2, r: f64) !void {
        const n = @max(8, segmentsFor(r, 2 * std.math.pi));
        const rr = r * areaFactor(2 * std.math.pi / @as(f64, @floatFromInt(n)));
        cv.poly.clearRetainingCapacity();
        for (0..n) |i| {
            const a = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            try cv.poly.append(cv.gpa, .{ .x = c.x + rr * @cos(a), .y = c.y + rr * @sin(a) });
        }
        try cv.addPolyEdges(cv.poly.items);
    }

    /// Adds a polygon with positive orientation (for the union of strokes).
    fn addPolygon(cv: *Canvas, pts: []const Vec2) !void {
        cv.poly.clearRetainingCapacity();
        try cv.poly.appendSlice(cv.gpa, pts);
        try cv.addPolyEdges(cv.poly.items);
    }

    fn addPolyEdges(cv: *Canvas, pts: []Vec2) !void {
        var area: f64 = 0;
        for (pts, 0..) |a, i| {
            const b = pts[(i + 1) % pts.len];
            area += a.x * b.y - a.y * b.x;
        }
        if (area < 0) std.mem.reverse(Vec2, pts);
        for (pts, 0..) |a, i| try cv.addEdge(a, pts[(i + 1) % pts.len]);
    }

    fn addEdge(cv: *Canvas, a: Vec2, b: Vec2) !void {
        if (a.y == b.y) return;
        const up = a.y > b.y;
        const p0 = if (up) b else a;
        const p1 = if (up) a else b;
        try cv.edges.append(cv.gpa, .{
            .x0 = p0.x,
            .y0 = p0.y,
            .y1 = p1.y,
            .slope = (p1.x - p0.x) / (p1.y - p0.y),
            .dir = if (up) -1 else 1,
        });
    }

    /// Fills the current edge list with the current color.
    fn rasterize(cv: *Canvas) !void {
        const edges = cv.edges.items;
        if (edges.len == 0 or (cv.color.alpha <= 0 and !cv.erasing)) return;
        std.mem.sortUnstable(Edge, edges, {}, struct {
            fn lt(_: void, a: Edge, b: Edge) bool {
                return a.y0 < b.y0;
            }
        }.lt);
        var ymax: f64 = 0;
        for (edges) |e| ymax = @max(ymax, e.y1);
        const fh: f64 = @floatFromInt(cv.height);
        const y_start: usize = @intFromFloat(std.math.clamp(@floor(edges[0].y0), 0, fh));
        const y_end: usize = @intFromFloat(std.math.clamp(@ceil(ymax), 0, fh));
        if (y_start >= y_end) return;

        const w = cv.width;
        const frac = try cv.gpa.alloc(f32, w + 2);
        defer cv.gpa.free(frac);
        const acc = try cv.gpa.alloc(f32, w + 2);
        defer cv.gpa.free(acc);
        @memset(frac, 0);
        @memset(acc, 0);
        // the edges crossing the current sample row with their x, kept
        // sorted by x (edges move little from row to row, so insertion sort
        // is nearly linear)
        var active: std.ArrayListUnmanaged(Crossing) = .empty;
        defer active.deinit(cv.gpa);

        var next: usize = 0;
        const fw: f64 = @floatFromInt(w);
        const weight: f32 = 1.0 / @as(f32, SUBSAMPLES);
        var y = y_start;
        while (y < y_end) : (y += 1) {
            var x_lo: usize = w;
            var x_hi: usize = 0;
            for (0..SUBSAMPLES) |s| {
                const sy = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(s)) + 0.5) / SUBSAMPLES;
                // drop finished edges (keeping the order), move the others
                var kept: usize = 0;
                for (active.items) |cr| {
                    const e = edges[cr.edge];
                    if (e.y1 <= sy) continue;
                    active.items[kept] = .{ .x = e.xAt(sy), .dir = cr.dir, .edge = cr.edge };
                    kept += 1;
                }
                active.shrinkRetainingCapacity(kept);
                while (next < edges.len and edges[next].y0 <= sy) : (next += 1) {
                    const e = edges[next];
                    if (e.y1 <= sy) continue;
                    try active.append(cv.gpa, .{ .x = e.xAt(sy), .dir = e.dir, .edge = next });
                }
                if (active.items.len < 2) continue;
                const c = active.items;
                for (1..c.len) |k| {
                    const v = c[k];
                    var j = k;
                    while (j > 0 and c[j - 1].x > v.x) : (j -= 1) c[j] = c[j - 1];
                    c[j] = v;
                }
                var wind: i32 = 0;
                var xa: f64 = 0;
                for (c) |cr| {
                    const before = wind;
                    wind += cr.dir;
                    if (before == 0 and wind != 0) {
                        xa = cr.x;
                    } else if (before != 0 and wind == 0) {
                        // the span [xa, cr.x), clipped to the image
                        const a = std.math.clamp(xa, 0, fw);
                        const b = std.math.clamp(cr.x, 0, fw);
                        if (b <= a) continue;
                        const ia: usize = @intFromFloat(@floor(a));
                        const ib: usize = @intFromFloat(@floor(b));
                        if (ia == ib) {
                            frac[ia] += @floatCast((b - a) * weight);
                        } else {
                            frac[ia] += @floatCast((@as(f64, @floatFromInt(ia + 1)) - a) * weight);
                            acc[ia + 1] += weight;
                            acc[ib] -= weight;
                            frac[ib] += @floatCast((b - @as(f64, @floatFromInt(ib))) * weight);
                        }
                        x_lo = @min(x_lo, ia);
                        x_hi = @max(x_hi, ib + 1);
                    }
                }
            }
            if (x_lo < x_hi) {
                var run: f32 = 0;
                var x = x_lo;
                while (x <= @min(x_hi, w)) : (x += 1) {
                    run += acc[x];
                    const cov = @min(1.0, run + frac[x]);
                    acc[x] = 0;
                    frac[x] = 0;
                    if (x < w and cov > 1e-4) cv.blend(y * w + x, cov);
                }
                acc[w + 1] = 0;
                frac[w + 1] = 0;
            }
        }
    }

    fn blend(cv: *Canvas, idx: usize, cov: f32) void {
        if (cv.erasing) {
            for (cv.pixels[idx * 4 ..][0..4]) |*c| c.* = @intFromFloat(@round(@as(f32, @floatFromInt(c.*)) * (1 - cov)));
            return;
        }
        const col = cv.color;
        const a: f32 = @as(f32, @floatCast(col.alpha)) * cov;
        const px = cv.pixels[idx * 4 ..][0..4];
        const src = [4]f32{ @as(f32, @floatCast(col.red)) * a, @as(f32, @floatCast(col.green)) * a, @as(f32, @floatCast(col.blue)) * a, a };
        for (0..4) |k| {
            const d = @as(f32, @floatFromInt(px[k])) / 255.0;
            const v = src[k] + d * (1 - a);
            px[k] = @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255.0));
        }
    }

    // -- text ----------------------------------------------------------

    pub fn text(cv: *Canvas, str: []const u8, x: f64, y: f64, alignment: TextAlign) !void {
        const u = CAP_HEIGHT * vector.FONT_SIZE / FONT_ROWS;
        // proportional: every glyph is as wide as its strokes
        var w: f64 = 0;
        for (str, 0..) |ch, i| {
            const b = glyphBounds(glyphOf(ch));
            w += b[1] - b[0];
            if (i + 1 < str.len) w += SPACING;
        }
        w *= u;
        const h = FONT_ROWS * u;
        const x0, const base = switch (alignment) {
            .center => .{ x - w / 2, y + h / 2 },
            .right_bottom => .{ x - w, y - h / 2 },
        };
        const saved = cv.line_width;
        defer cv.line_width = saved;
        cv.line_width = TEXT_WEIGHT * vector.FONT_SIZE;
        var gx0 = x0;
        for (str) |ch| {
            const glyph = glyphOf(ch);
            const b = glyphBounds(glyph);
            const gx = gx0 - b[0] * u;
            gx0 += (b[1] - b[0] + SPACING) * u;
            var strokes = std.mem.splitScalar(u8, glyph, ';');
            while (strokes.next()) |st| {
                var pts = std.mem.tokenizeScalar(u8, st, ' ');
                var first = true;
                while (pts.next()) |pt| {
                    const comma = std.mem.indexOfScalar(u8, pt, ',') orelse continue;
                    const fx = std.fmt.parseFloat(f64, pt[0..comma]) catch continue;
                    const fy = std.fmt.parseFloat(f64, pt[comma + 1 ..]) catch continue;
                    const px = gx + fx * u;
                    const py = base + (fy - FONT_ROWS) * u;
                    if (first) try cv.moveTo(px, py) else try cv.lineTo(px, py);
                    first = false;
                }
            }
        }
        try cv.stroke();
    }

    // -- output --------------------------------------------------------

    /// The image as PNG file. Drawing afterwards isn't possible (the pixels
    /// are converted in place).
    pub fn encodePng(cv: *Canvas) ![]u8 {
        // PNG wants straight (not premultiplied) alpha; done in place, the
        // image is complete
        const px = cv.pixels;
        var i: usize = 0;
        while (i < px.len) : (i += 4) {
            const a = px[i + 3];
            if (a == 255) continue;
            for (0..3) |k| {
                px[i + k] = if (a == 0) 0 else @intCast(@min(255, (@as(u32, px[i + k]) * 255 + a / 2) / a));
            }
        }
        return png.encode(cv.gpa, cv.width, cv.height, px);
    }
};

/// Radius factor for the vertices of a regular polygon with central angle
/// `step` per edge that has the area of the circle.
fn areaFactor(step: f64) f64 {
    if (step < 1e-6) return 1;
    return @sqrt(step / @sin(step));
}

/// Number of chords approximating an arc of radius r (pixels) and angle a
/// within the tolerance.
fn segmentsFor(r: f64, a: f64) usize {
    if (r <= TOLERANCE) return 4;
    const step = 2 * std.math.acos(1 - TOLERANCE / r);
    return @min(10000, @max(1, @as(usize, @intFromFloat(@ceil(a / step)))));
}

// ---------------------------------------------------------------------------
// stroke font

/// Capitals are CAP_HEIGHT · font size high (as in vector.zig).
const CAP_HEIGHT = 0.72;
/// glyph grid: x 0..4, y 0 (top of capitals) .. 6 (baseline), descenders
/// down to 8
const FONT_ROWS = 6.0;
/// space between glyphs and width of a blank (grid units)
const SPACING = 1.6;
const BLANK = 2.4;
/// stroke width relative to the font size
const TEXT_WEIGHT = 0.09;

fn glyphOf(ch: u8) []const u8 {
    return if (ch >= 32 and ch <= 126) FONT[ch - 32] else FONT['?' - 32];
}

/// Horizontal extent [min, max] of a glyph's points (a blank: [0, BLANK]).
fn glyphBounds(glyph: []const u8) [2]f64 {
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = -std.math.inf(f64);
    var pts = std.mem.tokenizeAny(u8, glyph, " ;");
    while (pts.next()) |pt| {
        const comma = std.mem.indexOfScalar(u8, pt, ',') orelse continue;
        const x = std.fmt.parseFloat(f64, pt[0..comma]) catch continue;
        lo = @min(lo, x);
        hi = @max(hi, x);
    }
    if (lo > hi) return .{ 0, BLANK };
    return .{ lo, hi };
}

/// Glyphs for ASCII 32..126: strokes separated by ';', each a list of
/// points "x,y" (a single repeated point is a dot).
const FONT = [95][]const u8{
    "", // space
    "2,0 2,4;2,6 2,6", // !
    "1,0 1,1.5;3,0 3,1.5", // "
    "1,1 1,5;3,1 3,5;0,2 4,2;0,4 4,4", // #
    "4,1 3,0.5 1,0.5 0,1.5 1,3 3,3 4,4.5 3,5.5 1,5.5 0,5;2,-0.5 2,6.5", // $
    "0,6 4,0;0,0 1,0 1,1 0,1 0,0;3,5 4,5 4,6 3,6 3,5", // %
    "4,6 1,2 1,1 2,0 3,1 3,2 0,4 0,5 1,6 2,6 4,4", // &
    "2,0 2,1.5", // '
    "3,-0.5 2,1 1.5,3 2,5 3,6.5", // (
    "1,-0.5 2,1 2.5,3 2,5 1,6.5", // )
    "2,1 2,5;0,2 4,4;4,2 0,4", // *
    "2,1.5 2,4.5;0.5,3 3.5,3", // +
    "2,5.5 2,6 1.5,7", // ,
    "1,3.5 3,3.5", // -
    "2,6 2,6", // .
    "4,0 0,6", // /
    "1,0 3,0 4,1 4,5 3,6 1,6 0,5 0,1 1,0", // 0
    "1,1 2,0 2,6;1,6 3,6", // 1
    "0,1 1,0 3,0 4,1 4,2 0,6 4,6", // 2
    "0,1 1,0 3,0 4,1 4,2 3,3 2,3;3,3 4,4 4,5 3,6 1,6 0,5", // 3
    "3,6 3,0 0,4 4,4", // 4
    "4,0 0,0 0,3 3,3 4,4 4,5 3,6 1,6 0,5", // 5
    "4,1 3,0 1,0 0,1 0,5 1,6 3,6 4,5 4,4 3,3 0,3", // 6
    "0,0 4,0 1,6", // 7
    "1,0 3,0 4,1 4,2 3,3 1,3 0,4 0,5 1,6 3,6 4,5 4,4 3,3;1,3 0,2 0,1 1,0", // 8
    "4,3 1,3 0,2 0,1 1,0 3,0 4,1 4,5 3,6 1,6 0,5", // 9
    "2,2.5 2,2.5;2,5.5 2,5.5", // :
    "2,2.5 2,2.5;2,5.5 2,6 1.5,7", // ;
    "4,1 0,3 4,5", // <
    "0,2 4,2;0,4 4,4", // =
    "0,1 4,3 0,5", // >
    "0,1 1,0 3,0 4,1 4,2 2,3.5 2,4;2,6 2,6", // ?
    "3,4 3,2 1.5,2 1,3 1.5,4 3,4 4,3 4,1 3,0 1,0 0,1 0,5 1,6 4,6", // @
    "0,6 2,0 4,6;1,4 3,4", // A
    "0,6 0,0 3,0 4,1 4,2 3,3 0,3;3,3 4,4 4,5 3,6 0,6", // B
    "4,1 3,0 1,0 0,1 0,5 1,6 3,6 4,5", // C
    "0,0 0,6 3,6 4,5 4,1 3,0 0,0", // D
    "4,0 0,0 0,6 4,6;0,3 3,3", // E
    "4,0 0,0 0,6;0,3 3,3", // F
    "4,1 3,0 1,0 0,1 0,5 1,6 3,6 4,5 4,3 2,3", // G
    "0,0 0,6;4,0 4,6;0,3 4,3", // H
    "1,0 3,0;2,0 2,6;1,6 3,6", // I
    "4,0 4,5 3,6 1,6 0,5", // J
    "0,0 0,6;4,0 0,4;1,3 4,6", // K
    "0,0 0,6 4,6", // L
    "0,6 0,0 2,3 4,0 4,6", // M
    "0,6 0,0 4,6 4,0", // N
    "1,0 3,0 4,1 4,5 3,6 1,6 0,5 0,1 1,0", // O
    "0,6 0,0 3,0 4,1 4,2 3,3 0,3", // P
    "1,0 3,0 4,1 4,5 3,6 1,6 0,5 0,1 1,0;2,4 4,6", // Q
    "0,6 0,0 3,0 4,1 4,2 3,3 0,3;2,3 4,6", // R
    "4,1 3,0 1,0 0,1 0,2 1,3 3,3 4,4 4,5 3,6 1,6 0,5", // S
    "0,0 4,0;2,0 2,6", // T
    "0,0 0,5 1,6 3,6 4,5 4,0", // U
    "0,0 2,6 4,0", // V
    "0,0 1,6 2,3 3,6 4,0", // W
    "0,0 4,6;4,0 0,6", // X
    "0,0 2,3 4,0;2,3 2,6", // Y
    "0,0 4,0 0,6 4,6", // Z
    "3,-0.5 1.5,-0.5 1.5,6.5 3,6.5", // [
    "0,0 4,6", // backslash
    "1,-0.5 2.5,-0.5 2.5,6.5 1,6.5", // ]
    "1,2 2,0 3,2", // ^
    "0,7 4,7", // _
    "1.5,0 2.5,1.5", // `
    "1,2 3,2 4,3 4,6;4,4 1,4 0,5 1,6 3,6 4,5", // a
    "0,0 0,6;0,3 1,2 3,2 4,3 4,5 3,6 1,6 0,5", // b
    "4,3 3,2 1,2 0,3 0,5 1,6 3,6 4,5", // c
    "4,0 4,6;4,3 3,2 1,2 0,3 0,5 1,6 3,6 4,5", // d
    "0,4 4,4 4,3 3,2 1,2 0,3 0,5 1,6 3,6 4,5", // e
    "4,0 3,0 2,1 2,6;1,2 3,2", // f
    "4,2 4,7 3,8 1,8 0,7;4,3 3,2 1,2 0,3 0,5 1,6 3,6 4,5", // g
    "0,0 0,6;0,3 1,2 3,2 4,3 4,6", // h
    "2,2 2,6;2,0.3 2,0.3", // i
    "3,2 3,7 2,8 1,8;3,0.3 3,0.3", // j
    "0,0 0,6;4,2 0,5;1,4 4,6", // k
    "2,0 2,5 3,6", // l
    "0,6 0,2;0,3 1,2 2,3 2,6;2,3 3,2 4,3 4,6", // m
    "0,6 0,2;0,3 1,2 3,2 4,3 4,6", // n
    "1,2 3,2 4,3 4,5 3,6 1,6 0,5 0,3 1,2", // o
    "0,2 0,8;0,3 1,2 3,2 4,3 4,5 3,6 1,6 0,5", // p
    "4,2 4,8;4,3 3,2 1,2 0,3 0,5 1,6 3,6 4,5", // q
    "0,6 0,2;0,4 2,2 4,2", // r
    "4,2 1,2 0,3 1,4 3,4 4,5 3,6 0,6", // s
    "2,0 2,5 3,6 4,6;0,2 4,2", // t
    "0,2 0,5 1,6 3,6 4,5;4,2 4,6", // u
    "0,2 2,6 4,2", // v
    "0,2 1,6 2,4 3,6 4,2", // w
    "0,2 4,6;4,2 0,6", // x
    "0,2 2,6;4,2 1,8", // y
    "0,2 4,2 0,6 4,6", // z
    "3,-0.5 2,0 2,2.5 1,3 2,3.5 2,6 3,6.5", // {
    "2,-0.5 2,6.5", // |
    "1,-0.5 2,0 2,2.5 3,3 2,3.5 2,6 1,6.5", // }
    "0,3.5 1,2.5 3,3.5 4,2.5", // ~
};

// ---------------------------------------------------------------------------

fn pixel(cv: *const Canvas, x: usize, y: usize) [4]u8 {
    return cv.pixels[(y * cv.width + x) * 4 ..][0..4].*;
}

test "fill covers exactly the polygon with anti-aliased edges" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 10, 10);
    defer cv.deinit();
    try cv.setColor(.{ .red = 1, .green = 0, .blue = 0 });
    // half pixel at x 2..2.5, full pixels 3..6
    try cv.rectangle(2.5, 2, 4.5, 3);
    try cv.fill();
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(&cv, 4, 3));
    try std.testing.expectEqual(@as(u8, 128), pixel(&cv, 2, 3)[3]);
    try std.testing.expectEqual(@as(u8, 0), pixel(&cv, 7, 3)[3]);
    try std.testing.expectEqual(@as(u8, 0), pixel(&cv, 4, 5)[3]);
    // total coverage equals the area
    var sum: f64 = 0;
    for (0..100) |i| sum += @as(f64, @floatFromInt(cv.pixels[i * 4 + 3])) / 255.0;
    try std.testing.expectApproxEqAbs(@as(f64, 4.5 * 3), sum, 0.05);
}

test "overlapping strokes don't add up" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 20, 20);
    defer cv.deinit();
    try cv.setColor(.{ .red = 0, .green = 0, .blue = 1, .alpha = 0.5 });
    try cv.setLineWidth(4);
    // a cross: both lines cover the center
    try cv.moveTo(2, 10);
    try cv.lineTo(18, 10);
    try cv.moveTo(10, 2);
    try cv.lineTo(10, 18);
    try cv.stroke();
    try std.testing.expectEqual(@as(u8, 128), pixel(&cv, 10, 10)[3]);
    try std.testing.expectEqual(@as(u8, 128), pixel(&cv, 4, 10)[3]);
    // round caps reach beyond the end points
    try std.testing.expect(pixel(&cv, 0, 10)[3] > 0);
}

test "knockout cuts only the group's drawing" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 10, 10);
    defer cv.deinit();
    // half transparent background below the group
    try cv.setColor(.{ .red = 1, .green = 0, .blue = 0, .alpha = 0.5 });
    try cv.rectangle(0, 0, 10, 10);
    try cv.fill();
    try cv.beginKnockout();
    try cv.setColor(.{ .red = 0, .green = 0, .blue = 1 });
    try cv.rectangle(0, 0, 10, 10);
    try cv.fill();
    try cv.rectangle(2, 2, 3, 3);
    try cv.endKnockout();
    // the hole shows the background, elsewhere the group covers it
    try std.testing.expectEqual([4]u8{ 128, 0, 0, 128 }, pixel(&cv, 3, 3));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(&cv, 7, 7));
    // painting works normally afterwards
    try cv.setColor(.{ .red = 0, .green = 1, .blue = 0 });
    try cv.rectangle(2, 2, 3, 3);
    try cv.fill();
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, pixel(&cv, 3, 3));
}

test "circle area" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 40, 40);
    defer cv.deinit();
    try cv.setColor(.{ .red = 0, .green = 0, .blue = 0 });
    try cv.arc(20, 20, 15, 0, 2 * std.math.pi);
    try cv.fill();
    var sum: f64 = 0;
    for (0..40 * 40) |i| sum += @as(f64, @floatFromInt(cv.pixels[i * 4 + 3])) / 255.0;
    try std.testing.expectApproxEqRel(std.math.pi * 15 * 15, sum, 0.005);
}

test "font has all printable characters" {
    try std.testing.expectEqual(@as(usize, 95), FONT.len);
    for (FONT[1..]) |g| try std.testing.expect(g.len > 0);
}
