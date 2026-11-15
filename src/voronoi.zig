//! Voronoi based mazes. The cell walls are computed with Fortune's sweep line
//! algorithm and then clipped to the maze border (rectangle or ellipse).

const std = @import("std");
const geo = @import("geo.zig");
const mz = @import("maze.zig");
const rng = @import("rng.zig");
const structure = @import("structure.zig");

const Allocator = std.mem.Allocator;
const Maze = mz.Maze;
const Cell = mz.Cell;
const Wall = mz.Wall;
const Params = mz.Params;
const Vec2 = geo.Vec2;
const dequal = geo.dequal;
const EPSILON = geo.EPSILON;
const DBL_MAX = std.math.floatMax(f64);

/// sqrt(3)/2
const RSPACE: f64 = 0.866025403784438596588302061718;

const Event = struct {
    kind: enum { site, circle },
    site: *Cell,
    time: f64,
    deleted: bool = false,
    /// circle events only
    center: Vec2 = .{},
    entry: ?*BeachEntry = null,

    inline fn x(e: *const Event) f64 {
        return if (e.kind == .site) e.site.center.x else e.center.x;
    }
};

const BeachEntry = struct {
    site: *Cell,
    circle: ?*Event = null,
    prev: ?*BeachEntry = null,
    next: ?*BeachEntry = null,
};

fn cmpy(a: *const Event, b: *const Event) i32 {
    const diff = a.time - b.time;
    if (diff == 0) {
        return if (a.x() - b.x() < 0) -1 else 1;
    }
    return if (diff < 0) -1 else 1;
}

/// Binary heap of events, a faithful port of the original implementation
/// (the order in which equal keys are delivered matters for reproducibility).
const Heap = struct {
    items: std.ArrayListUnmanaged(*Event) = .empty,

    fn add(h: *Heap, gpa: Allocator, item: *Event) !void {
        try h.items.append(gpa, item);
        const it = h.items.items;
        var i = it.len - 1;
        while (i > 0) {
            const j = (i - 1) / 2;
            if (cmpy(it[i], it[j]) >= 0) break;
            std.mem.swap(*Event, &it[i], &it[j]);
            i = j;
        }
    }

    fn removeFirst(h: *Heap) ?*Event {
        if (h.items.items.len == 0) return null;
        const it = h.items.items;
        const ret = it[0];
        const n = it.len - 1;
        if (n > 0) {
            it[0] = it[n];
            var i: usize = 0;
            while (true) {
                var j = 2 * i + 1;
                if (j >= n) break;
                if (n > j + 1 and cmpy(it[j], it[j + 1]) > 0) j += 1;
                if (cmpy(it[i], it[j]) < 0) break;
                std.mem.swap(*Event, &it[i], &it[j]);
                i = j;
            }
        }
        h.items.items.len = n;
        return ret;
    }
};

const Line = struct { x1: f64, y1: f64, x2: f64, y2: f64 };

const ClipFn = *const fn (m: *Maze, l: *Line) bool;

const Voronoi = struct {
    gpa: Allocator,
    heap: Heap = .{},
    buckets: []?*BeachEntry,
    clip: ClipFn = neverClip,
    rectangle_cuts: bool = false,

    fn bucket(v: *Voronoi, no: i32) *?*BeachEntry {
        const n: i32 = @intCast(v.buckets.len);
        return &v.buckets[@intCast(@min(@max(no, 0), n - 1))];
    }

    fn newEntry(v: *Voronoi, site: *Cell) !*BeachEntry {
        const e = try v.gpa.create(BeachEntry);
        e.* = .{ .site = site };
        return e;
    }
};

fn leftBreakpoint(entry: *BeachEntry, directrix: f64) f64 {
    const prev = entry.prev orelse return -DBL_MAX;
    const x1 = entry.site.center.x;
    const y1 = entry.site.center.y;
    const x2 = prev.site.center.x;
    const y2 = prev.site.center.y;
    if (@abs(y2 - y1) < EPSILON) return (x1 + x2) / 2;
    if (@abs(y1 - directrix) < EPSILON) return x1;
    if (@abs(y2 - directrix) < EPSILON) return x2;
    const k1 = (y1 + directrix) / 2.0;
    const h2 = x2 - x1;
    const k2 = (y2 + directrix) / 2.0;
    const p1 = k1 - directrix;
    const a1 = 1 / (4 * p1);
    const p2 = k2 - directrix;
    const a2 = 1 / (4 * p2);
    const b2 = -h2 / (2 * p2);
    const c2 = h2 * h2 / (4 * p2) + k2;
    return (-b2 - @sqrt(b2 * b2 - 4 * (a2 - a1) * (c2 - k1))) / (2 * (a2 - a1)) + x1;
}

fn rightBreakpoint(entry: *BeachEntry, directrix: f64) f64 {
    const next = entry.next orelse return DBL_MAX;
    return leftBreakpoint(next, directrix);
}

inline fn releaseCircleEvent(entry: *BeachEntry) void {
    if (entry.circle) |c| {
        c.deleted = true;
        entry.circle = null;
    }
}

const Center = struct { c: Vec2, time: f64 };

fn calcCenter(c1: *const Cell, c2: *const Cell, c3: *const Cell, force: bool) ?Center {
    const x2 = c2.center.x;
    const y2 = c2.center.y;
    const x1 = c1.center.x - x2;
    const y1 = c1.center.y - y2;
    const x3 = c3.center.x - x2;
    const y3 = c3.center.y - y2;
    const d = 2 * (x1 * y3 - y1 * x3);
    if (force or d < -EPSILON) {
        const h1 = x1 * x1 + y1 * y1;
        const h3 = x3 * x3 + y3 * y3;
        const x = (y3 * h1 - y1 * h3) / d;
        const y = (x1 * h3 - x3 * h1) / d;
        const cy = y2 + y;
        return .{ .c = .{ .x = x2 + x, .y = cy }, .time = cy + @sqrt(x * x + y * y) };
    }
    return null;
}

fn calcCircleEvent(v: *Voronoi, e1: ?*BeachEntry, e2: *BeachEntry, e3: ?*BeachEntry, time: f64) !void {
    const a = e1 orelse return;
    const b = e3 orelse return;
    const ctr = calcCenter(a.site, e2.site, b.site, false) orelse return;
    if (ctr.time >= time and (e2.circle == null or ctr.time < e2.circle.?.time)) {
        const ev = try v.gpa.create(Event);
        ev.* = .{ .kind = .circle, .site = e2.site, .time = ctr.time, .center = ctr.c, .entry = e2 };
        releaseCircleEvent(e2);
        e2.circle = ev;
        try v.heap.add(v.gpa, ev);
    }
}

fn siteEvent(v: *Voronoi, m: *Maze, event: *Event) !void {
    const entry = try v.newEntry(event.site);
    const sx = event.site.center.x;
    const no: i32 = @intFromFloat(sx);
    const bsize: i32 = @intCast(v.buckets.len);
    var lentry_opt = v.bucket(no).*;
    if (lentry_opt == null) {
        const n = @max(no, bsize - no);
        var i: i32 = 1;
        while (i <= n) : (i += 1) {
            lentry_opt = v.bucket(no - i).*;
            if (lentry_opt != null) break;
            lentry_opt = v.bucket(no + i).*;
            if (lentry_opt != null) break;
        }
    }
    if ((no >= 0 and no < bsize) or v.bucket(no).* == null) {
        v.bucket(no).* = entry;
    }
    var lentry = lentry_opt orelse return;
    var lbp = leftBreakpoint(lentry, event.time);
    if (sx < lbp) {
        while (sx < lbp) {
            lentry = lentry.prev.?;
            lbp = leftBreakpoint(lentry, event.time);
        }
    } else {
        var rbp = rightBreakpoint(lentry, event.time);
        while (sx >= rbp) {
            lentry = lentry.next.?;
            rbp = rightBreakpoint(lentry, event.time);
        }
    }
    releaseCircleEvent(lentry);
    // note: `lbp` is intentionally the value computed before walking right
    if (lbp == entry.site.center.x) {
        const rentry = lentry;
        lentry = lentry.prev.?;
        releaseCircleEvent(lentry);
        entry.next = rentry;
        rentry.prev = entry;
        lentry.next = entry;
        entry.prev = lentry;
        try calcAndEvalCircleEvent(v, m, lentry.site, entry.site, rentry.site);
        try calcCircleEvent(v, lentry.prev, lentry, entry, event.time);
        try calcCircleEvent(v, entry, rentry, rentry.next, event.time);
    } else if (dequal(lentry.site.center.y, entry.site.center.y)) {
        const rentry = lentry.next;
        if (rentry) |r| r.prev = entry;
        entry.next = rentry;
        lentry.next = entry;
        entry.prev = lentry;
        try calcCircleEvent(v, lentry.prev, lentry, entry, event.time);
    } else {
        const rentry = try v.gpa.create(BeachEntry);
        rentry.* = lentry.*;
        if (lentry.next) |n| n.prev = rentry;
        lentry.next = entry;
        entry.prev = lentry;
        rentry.prev = entry;
        entry.next = rentry;
        try calcCircleEvent(v, lentry.prev, lentry, entry, event.time);
        try calcCircleEvent(v, entry, rentry, rentry.next, event.time);
    }
}

fn circleEvent(v: *Voronoi, m: *Maze, event: *Event) !void {
    const entry = event.entry.?;
    const le = entry.prev.?;
    const re = entry.next.?;
    const c = event.center;
    try installWall(v, m, c.x, c.y, entry.site, le.site);
    try installWall(v, m, c.x, c.y, entry.site, re.site);
    try installWall(v, m, c.x, c.y, le.site, re.site);
    le.next = re;
    re.prev = le;
    const no: i32 = @intFromFloat(event.site.center.x);
    if (v.bucket(no).* == entry) v.bucket(no).* = null;
    try calcCircleEvent(v, le.prev, le, re, event.time);
    try calcCircleEvent(v, le, re, re.next, event.time);
}

fn calcAndEvalCircleEvent(v: *Voronoi, m: *Maze, left: *Cell, center: *Cell, right: *Cell) !void {
    if (calcCenter(left, center, right, true)) |ctr| {
        try installWall(v, m, ctr.c.x, ctr.c.y, center, left);
        try installWall(v, m, ctr.c.x, ctr.c.y, center, right);
        try installWall(v, m, ctr.c.x, ctr.c.y, left, right);
    }
}

// ---------------------------------------------------------------------------
// Nicholl-Lee-Nicholl line clipping

const REGION_CENTER: u8 = 0x00;
const REGION_LEFT: u8 = 0x01;
const REGION_RIGHT: u8 = 0x02;
const REGION_TOP: u8 = 0x04;
const REGION_BOTTOM: u8 = 0x08;

const Nln = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    xmin: f64,
    xmax: f64,
    ymin: f64,
    ymax: f64,

    fn swap(s: *Nln) void {
        std.mem.swap(f64, &s.x1, &s.x2);
        std.mem.swap(f64, &s.y1, &s.y2);
    }

    fn flipX(s: *Nln) void {
        s.x1 = -s.x1;
        s.x2 = -s.x2;
        const t = -s.xmin;
        s.xmin = -s.xmax;
        s.xmax = t;
    }

    fn flipY(s: *Nln) void {
        s.y2 = -s.y2;
        s.y1 = -s.y1;
        const t = -s.ymin;
        s.ymin = -s.ymax;
        s.ymax = t;
    }

    fn rotCW(s: *Nln) void {
        var t = -s.x1;
        s.x1 = s.y1;
        s.y1 = t;
        t = -s.x2;
        s.x2 = s.y2;
        s.y2 = t;
        t = s.xmax;
        s.xmax = s.ymax;
        s.ymax = -s.xmin;
        s.xmin = s.ymin;
        s.ymin = -t;
    }

    fn rotCCW(s: *Nln) void {
        var t = s.x1;
        s.x1 = -s.y1;
        s.y1 = t;
        t = s.x2;
        s.x2 = -s.y2;
        s.y2 = t;
        t = s.xmax;
        s.xmax = -s.ymin;
        s.ymin = s.xmin;
        s.xmin = -s.ymax;
        s.ymax = t;
    }

    fn region(s: *const Nln, x: f64, y: f64) u8 {
        var r: u8 = REGION_CENTER;
        if (!(x >= s.xmin)) r |= REGION_LEFT;
        if (!(x <= s.xmax)) r |= REGION_RIGHT;
        if (!(y >= s.ymin)) r |= REGION_BOTTOM;
        if (!(y <= s.ymax)) r |= REGION_TOP;
        return r;
    }

    /// Returns false if the line lies completely inside the clip rectangle.
    fn clip(s: *Nln) bool {
        const r1 = s.region(s.x1, s.y1);
        const r2 = s.region(s.x2, s.y2);
        if ((r1 | r2) == REGION_CENTER) return false;
        const dx = s.x2 - s.x1;
        const dy = s.y2 - s.y1;
        if (r1 == REGION_LEFT) {
            if (r2 == REGION_BOTTOM) {
                const a = (s.xmin - s.x1) * dy;
                const b = (s.ymin - s.y1) * dx;
                if (a >= b) { // clip at left/bottom
                    s.x2 = s.x1 + b / dy;
                    s.y2 = s.ymin;
                    s.x1 = s.xmin;
                    s.y1 = s.y1 + a / dx;
                }
            } else if (r2 == (REGION_BOTTOM | REGION_RIGHT)) {
                const a = (s.xmax - s.x1) * dy;
                const b = (s.ymin - s.y1) * dx;
                if (a >= b) { // clip at left/right
                    s.x2 = s.xmax;
                    s.y2 = s.y1 + a / dx;
                } else { // clip at left/bottom
                    s.x2 = s.x1 + b / dy;
                    s.y2 = s.ymin;
                }
                s.y1 = s.y1 + (s.xmin - s.x1) / dx * dy;
                s.x1 = s.xmin;
            } else if (r2 & REGION_TOP != 0) {
                s.flipY();
                _ = s.clip();
                s.flipY();
            } else if (r2 == REGION_RIGHT) {
                s.x2 = s.xmax;
                s.y2 = s.y1 + dy * (s.xmax - s.x1) / dx;
                s.y1 = s.y1 + dy * (s.xmin - s.x1) / dx;
                s.x1 = s.xmin;
            } else if (r2 == REGION_CENTER) {
                s.y1 = s.y1 + dy * (s.xmin - s.x1) / dx;
                s.x1 = s.xmin;
            }
        } else if (r1 == (REGION_LEFT | REGION_BOTTOM)) {
            if (r2 == (REGION_TOP | REGION_RIGHT)) {
                var a = (s.xmax - s.x1) * dy;
                var b = (s.ymax - s.y1) * dx;
                if (a < b) { // at right
                    s.x2 = s.xmax;
                    s.y2 = s.y1 + a / dx;
                } else { // top
                    s.y2 = s.ymax;
                    s.x2 = s.x1 + b / dy;
                }
                a = (s.xmin - s.x1) * dy;
                b = (s.ymin - s.y1) * dx;
                if (a < b) { // at bottom
                    s.y1 = s.ymin;
                    s.x1 = s.x1 + b / dy;
                } else { // at left
                    s.x1 = s.xmin;
                    s.y1 = s.y1 + a / dx;
                }
            } else if (r2 == REGION_CENTER) {
                const a = (s.xmin - s.x1) * dy;
                const b = (s.ymin - s.y1) * dx;
                if (a < b) { // at bottom
                    s.y1 = s.ymin;
                    s.x1 = s.x1 + b / dy;
                } else { // at left
                    s.x1 = s.xmin;
                    s.y1 = s.y1 + a / dx;
                }
            } else if (r2 == REGION_RIGHT) {
                s.swap();
                s.flipX();
                _ = s.clip();
                s.flipX();
                s.swap();
            } else if (r2 == REGION_TOP) {
                s.swap();
                s.rotCCW();
                _ = s.clip();
                s.rotCW();
                s.swap();
            }
        } else if (r1 == REGION_CENTER) {
            s.swap();
            _ = s.clip();
            s.swap();
        } else if (r1 & REGION_RIGHT != 0) {
            s.flipX();
            _ = s.clip();
            s.flipX();
        } else if (r1 & REGION_TOP != 0) {
            s.rotCCW();
            _ = s.clip();
            s.rotCW();
        } else if (r1 & REGION_BOTTOM != 0) {
            s.rotCW();
            _ = s.clip();
            s.rotCCW();
        }
        return true;
    }
};

fn borderClip(m: *Maze, l: *Line) bool {
    var s = Nln{
        .x1 = l.x1,
        .y1 = l.y1,
        .x2 = l.x2,
        .y2 = l.y2,
        .xmin = 0,
        .ymin = 0,
        .xmax = @floatFromInt(m.columns),
        .ymax = @floatFromInt(m.rows),
    };
    const clipped = s.clip();
    l.* = .{ .x1 = s.x1, .y1 = s.y1, .x2 = s.x2, .y2 = s.y2 };
    return clipped;
}

fn ellipticClip(m: *Maze, l: *Line) bool {
    const f = @as(f64, @floatFromInt(m.columns)) / @as(f64, @floatFromInt(m.rows));
    const r = @as(f64, @floatFromInt(m.columns)) / 2.0;
    const cx = r;
    const cy = r;
    const dx = l.x2 - l.x1;
    const dy = (l.y2 - l.y1) * f;
    const fx = l.x1 - cx;
    const fy = l.y1 * f - cy;
    const a = dx * dx + dy * dy;
    const b = 2.0 * (fx * dx + fy * dy);
    const c = fx * fx + fy * fy - r * r;
    const p1in = c < 0;
    var d = b * b - 4 * a * c;
    var clipped = d <= 0;
    if (d > 0) {
        d = @sqrt(d);
        var t = (-b + d) / (2 * a);
        if (t >= 0 and t <= 1) {
            clipped = true;
            if (p1in) {
                l.x2 = l.x1 + t * dx;
                l.y2 = l.y1 + t * dy / f;
            } else {
                l.x1 = l.x1 + t * dx;
                l.y1 = l.y1 + t * dy / f;
            }
        } else {
            clipped = !p1in;
        }
        t = (-b - d) / (2 * a);
        if (t >= 0 and t <= 1) {
            clipped = true;
            if (p1in) {
                l.x2 = l.x1 + t * dx;
                l.y2 = l.y1 + t * dy / f;
            } else {
                l.x1 = l.x1 + t * dx;
                l.y1 = l.y1 + t * dy / f;
            }
        } else {
            clipped = clipped or !p1in;
        }
    }
    return clipped;
}

fn neverClip(m: *Maze, l: *Line) bool {
    _ = m;
    _ = l;
    return false;
}

// ---------------------------------------------------------------------------
// wall handling

/// Registers a wall with its (non-off) cells.
fn addWall(m: *Maze, wi: u32) !void {
    const w = m.wall(wi);
    for (w.cells) |c| {
        if (c.type != mz.TYPE_OFF) try m.addWallIdx(c, wi);
    }
}

/// Copies the cells, state and geometry of `src` to `dst` and registers it.
fn cpWall(m: *Maze, src: u32, dst: u32) !void {
    const s = m.wall(src);
    const d = m.wall(dst);
    d.cells = s.cells;
    d.state = s.state;
    d.points = s.points;
    try addWall(m, dst);
}

fn installWall(v: *Voronoi, m: *Maze, cx: f64, cy: f64, c: *Cell, other: *Cell) !void {
    if (!c.valid() and !other.valid()) return;
    var found: ?u32 = null;
    for (0..c.nWalls()) |i| {
        if (m.neighbour(c, i) == other) {
            found = c.wallIdx(i);
            break;
        }
    }
    if (found) |wi| {
        const w = m.wall(wi);
        w.points[1] = .{ .x = cx, .y = cy };
        var l = Line{ .x1 = w.points[0].x, .y1 = w.points[0].y, .x2 = cx, .y2 = cy };
        if (!v.clip(m, &l)) return;
        w.primary().mark = mz.MARK_CLIP;
        w.secondary().mark = mz.MARK_CLIP;
        if (!dequal(l.x1, w.points[0].x) or !dequal(l.y1, w.points[0].y)) {
            const w1 = try m.newWall();
            try cpWall(m, wi, w1);
            m.wall(wi).points[1] = .{ .x = l.x1, .y = l.y1 };
            m.wall(wi).mark = mz.MARK_CLIP;
            m.wall(w1).points[0] = .{ .x = l.x1, .y = l.y1 };
            m.wall(w1).mark = mz.MARK_CLIP1;
            const p2 = m.wall(w1).points[1];
            if (!dequal(l.x2, p2.x) or !dequal(l.y2, p2.y)) {
                const w2 = try m.newWall();
                try cpWall(m, w1, w2);
                m.wall(w1).points[1] = .{ .x = l.x2, .y = l.y2 };
                m.wall(w1).mark = mz.MARK_CLIP12;
                m.wall(w2).points[0] = .{ .x = l.x2, .y = l.y2 };
                m.wall(w2).mark = mz.MARK_CLIP;
            }
        } else if (!dequal(l.x2, w.points[1].x) or !dequal(l.y2, w.points[1].y)) {
            const w1 = try m.newWall();
            try cpWall(m, wi, w1);
            m.wall(wi).points[1] = .{ .x = l.x2, .y = l.y2 };
            m.wall(wi).mark = mz.MARK_CLIP2;
            m.wall(w1).points[0] = .{ .x = l.x2, .y = l.y2 };
            m.wall(w1).mark = mz.MARK_CLIP;
        } else {
            w.mark = mz.MARK_CLIP;
        }
    } else {
        const wi = try m.newWall();
        const w = m.wall(wi);
        w.mark = mz.MARK_NONE;
        w.cells = .{ c, other };
        w.points[0] = .{ .x = cx, .y = cy };
        try addWall(m, wi);
    }
}

/// Removes the chain of clipped-off walls starting at (x1,y1) from a cell and
/// closes the gap with new border walls.
fn cutCell(v: *Voronoi, m: *Maze, c: *Cell, x1_: f64, y1_: f64) !bool {
    var x1 = x1_;
    var y1 = y1_;
    const x2 = x1_;
    const y2 = y1_;
    var done = false;
    while (!done) {
        done = true;
        for (0..c.nWalls()) |i| {
            const w = m.cellWall(c, i);
            if (w.mark != mz.MARK_CLIP) continue;
            if (dequal(w.points[0].x, x1) and dequal(w.points[0].y, y1)) {
                x1 = w.points[1].x;
                y1 = w.points[1].y;
                done = false;
                c.removeWallIdx(i);
                break;
            }
            if (dequal(w.points[1].x, x1) and dequal(w.points[1].y, y1)) {
                x1 = w.points[0].x;
                y1 = w.points[0].y;
                done = false;
                c.removeWallIdx(i);
                break;
            }
        }
    }
    const xeq = dequal(x1, x2);
    const yeq = dequal(y1, y2);
    if (xeq and yeq) return false;
    c.mark = mz.MARK_NONE;
    if (v.rectangle_cuts and !xeq and !yeq) {
        const nwi = try m.newWall();
        var nw = m.wall(nwi);
        nw.points[0] = .{ .x = x1, .y = y1 };
        if (dequal(x1, 0) or dequal(x1, @floatFromInt(m.columns))) {
            nw.points[1] = .{ .x = x1, .y = y2 };
        } else {
            nw.points[1] = .{ .x = x2, .y = y1 };
        }
        nw.cells = .{ c, m.off };
        try addWall(m, nwi);
        const owi = try m.newWall();
        nw = m.wall(nwi);
        const ow = m.wall(owi);
        ow.points[0] = nw.points[1];
        ow.points[1] = .{ .x = x2, .y = y2 };
        ow.cells = .{ c, m.off };
        try addWall(m, owi);
    } else {
        const nwi = try m.newWall();
        const nw = m.wall(nwi);
        nw.points = .{ .{ .x = x1, .y = y1 }, .{ .x = x2, .y = y2 } };
        nw.cells = .{ c, m.off };
        try addWall(m, nwi);
    }
    return true;
}

fn stitchUp(v: *Voronoi, m: *Maze) !void {
    for (m.cells[0..m.n_cells]) |*c| {
        if (!(c.valid() and c.mark == mz.MARK_CLIP)) continue;
        var j: usize = 0;
        while (j < c.nWalls()) : (j += 1) {
            const wi = c.wallIdx(j);
            if (m.wall(wi).mark & mz.MARK_CLIP1 != 0) {
                const p = m.wall(wi).points[0];
                // restarting sets j to 0, the loop increment makes it 1
                if (try cutCell(v, m, c, p.x, p.y)) j = 0;
            }
            if (m.wall(wi).mark & mz.MARK_CLIP2 != 0) {
                const p = m.wall(wi).points[1];
                if (try cutCell(v, m, c, p.x, p.y)) j = 0;
            }
        }
    }
}

fn buildWalls(v: *Voronoi, m: *Maze) !void {
    for (m.cells[0..m.n_cells]) |*c| {
        const ev = try v.gpa.create(Event);
        ev.* = .{ .kind = .site, .site = c, .time = c.center.y };
        try v.heap.add(v.gpa, ev);
    }
    while (v.heap.removeFirst()) |ev| {
        if (ev.deleted) continue;
        switch (ev.kind) {
            .site => try siteEvent(v, m, ev),
            .circle => try circleEvent(v, m, ev),
        }
    }
}

fn fixWall(m: *Maze, c: *Cell, fx: f64, fy: f64, tx: f64, ty: f64) void {
    for (0..c.nWalls()) |i| {
        const w = m.cellWall(c, i);
        if (w.mark & mz.MARK_FIXED1 == 0 and dequal(w.points[0].x, fx) and dequal(w.points[0].y, fy)) {
            w.points[0] = .{ .x = tx, .y = ty };
            w.mark |= mz.MARK_FIXED1;
            fixWall(m, w.other(c), fx, fy, tx, ty);
            w.mark &= ~mz.MARK_FIXED1;
        } else if (w.mark & mz.MARK_FIXED2 == 0 and dequal(w.points[1].x, fx) and dequal(w.points[1].y, fy)) {
            w.points[1] = .{ .x = tx, .y = ty };
            w.mark |= mz.MARK_FIXED2;
            fixWall(m, w.other(c), fx, fy, tx, ty);
            w.mark &= ~mz.MARK_FIXED2;
        }
    }
}

fn connectedToBorder(m: *Maze, c: *Cell, x: f64, y: f64) bool {
    var res = false;
    c.mark = mz.MARK_VISITED;
    for (0..c.nWalls()) |i| {
        const w = m.cellWall(c, i);
        if ((dequal(w.points[0].x, x) and dequal(w.points[0].y, y)) or
            (dequal(w.points[1].x, x) and dequal(w.points[1].y, y)))
        {
            const other = w.other(c);
            if (other == m.off) {
                res = true;
                break;
            } else if (other.mark != mz.MARK_VISITED) {
                res = connectedToBorder(m, other, x, y);
            }
        }
    }
    c.mark = 0;
    return res;
}

/// Removes walls shorter than `minwalllength` by merging their end points.
fn fixWalls(params: *const Params, m: *Maze) void {
    for (m.walls[0..m.n_walls]) |*w| {
        const l = w.length();
        if (l >= params.minwalllength) continue;
        if (l < EPSILON) {
            w.primary().removeWall(w);
            w.secondary().removeWall(w);
            continue;
        }
        const c = w.primary();
        const other = w.secondary();
        var tx = (w.points[0].x + w.points[1].x) / 2.0;
        var ty = (w.points[0].y + w.points[1].y) / 2.0;
        if (c != m.off and other != m.off) { // internal wall
            c.removeWall(w);
            other.removeWall(w);
            var keep = true;
            if (connectedToBorder(m, c, w.points[0].x, w.points[0].y)) {
                if (connectedToBorder(m, c, w.points[1].x, w.points[1].y)) {
                    keep = false;
                } else {
                    tx = w.points[0].x;
                    ty = w.points[0].y;
                }
            } else if (connectedToBorder(m, c, w.points[1].x, w.points[1].y)) {
                tx = w.points[1].x;
                ty = w.points[1].y;
            }
            if (keep) {
                const p1 = w.points[0];
                const p2 = w.points[1];
                fixWall(m, c, p1.x, p1.y, tx, ty);
                fixWall(m, c, p2.x, p2.y, tx, ty);
                fixWall(m, other, p1.x, p1.y, tx, ty);
                fixWall(m, other, p2.x, p2.y, tx, ty);
            }
        } else {
            w.features |= structure.WALL_INDESTRUCTIBLE;
        }
    }
    for (m.walls[0..m.n_walls]) |*w| {
        if (w.primary().type == mz.TYPE_TMP) {
            w.cells = .{ w.cells[1], m.off };
        } else if (w.secondary().type == mz.TYPE_TMP) {
            w.cells[1] = m.off;
        }
    }
}

// ---------------------------------------------------------------------------
// construction

fn baseSetup(gpa: Allocator, params: *const Params, rand: *rng.Random, arena_out: **Maze) !Voronoi {
    const m = try mz.create(gpa, params, rand);
    m.kind = .voronoi;
    m.tileable = false;
    m.columns = params.columns;
    m.rows = params.rows;
    arena_out.* = m;
    const buckets = try m.alloc().alloc(?*BeachEntry, @intCast(m.columns));
    @memset(buckets, null);
    return .{ .gpa = m.alloc(), .buckets = buckets };
}

/// Finishes the cell setup and computes all walls.
fn buildMaze(m: *Maze, params: *const Params, v: *Voronoi, n_cells: usize, nwalls: usize) !void {
    m.n_cells = n_cells;
    m.setupOff();
    try m.allocWalls(nwalls);
    m.n_walls = 0;
    try buildWalls(v, m);
    try stitchUp(v, m);
    fixWalls(params, m);
    m.applyMask(params);
}

inline fn jitter(rand: *rng.Random, f: f64) f64 {
    return (rand.unit() - 0.5) * f;
}

fn fl(i: anytype) f64 {
    return @floatFromInt(i);
}

/// Completely random cell centers.
pub fn newVoronoiMaze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var m: *Maze = undefined;
    var v = try baseSetup(gpa, params, rand, &m);
    errdefer m.deinit();
    var off: f64 = 1;
    if (!params.roughborder) {
        v.clip = borderClip;
        v.rectangle_cuts = true;
        off = 5;
    }
    const n: usize = @intCast((m.columns + 2) * (m.rows + 2));
    try m.allocCells(n);
    const nwalls: usize = 3 * n + 6 * @as(usize, @intCast(m.rows + m.columns));
    const rmax: f64 = @floatFromInt(rng.RAND_MAX);
    const divx = rmax / fl(m.columns);
    const divy = rmax / fl(m.rows);
    var idx: usize = 0;
    var i: i32 = -1;
    while (i < m.rows + 1) : (i += 1) {
        var j: i32 = -1;
        while (j < m.columns + 1) : (j += 1) {
            const c = &m.cells[idx];
            c.no = @intCast(idx);
            idx += 1;
            c.center = .{ .x = fl(j), .y = fl(i) };
            c.type = mz.TYPE_VORONOI;
            if (i < 0) {
                c.type = mz.TYPE_TMP;
                c.center.y -= off;
            } else if (i == m.rows) {
                c.type = mz.TYPE_TMP;
                c.center.y += off;
            }
            if (j < 0) {
                c.type = mz.TYPE_TMP;
                c.center.x -= off;
            } else if (j == m.columns) {
                c.type = mz.TYPE_TMP;
                c.center.x += off;
            }
            if (c.type == mz.TYPE_VORONOI) {
                c.center.x = fl(rand.next()) / divx;
                c.center.y = fl(rand.next()) / divy;
            }
        }
    }
    try buildMaze(m, params, &v, idx, nwalls);
    return m;
}

/// Jittered square grid.
pub fn newVoronoi4Maze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var m: *Maze = undefined;
    var v = try baseSetup(gpa, params, rand, &m);
    errdefer m.deinit();
    var off: f64 = 0;
    if (!params.roughborder) {
        v.clip = borderClip;
        v.rectangle_cuts = true;
        off = 5;
    }
    const n: usize = @intCast((m.columns + 2) * (m.rows + 2));
    try m.allocCells(n);
    const nwalls: usize = 3 * n + 8 * @as(usize, @intCast(m.rows + m.columns));
    var idx: usize = 0;
    var i: i32 = -1;
    while (i < m.rows + 1) : (i += 1) {
        var j: i32 = -1;
        while (j < m.columns + 1) : (j += 1) {
            const c = &m.cells[idx];
            c.no = @intCast(idx);
            idx += 1;
            c.center.x = fl(j) + 0.5 + jitter(rand, params.jitter);
            c.center.y = fl(i) + 0.5 + jitter(rand, params.jitter);
            if (i < 0) {
                c.type = mz.TYPE_TMP;
                c.center.y -= off;
            } else if (i == m.rows) {
                c.type = mz.TYPE_TMP;
                c.center.y += off;
            }
            if (j < 0) {
                c.type = mz.TYPE_TMP;
                c.center.x -= off;
            } else if (j == m.columns) {
                c.type = mz.TYPE_TMP;
                c.center.x += off;
            }
        }
    }
    try buildMaze(m, params, &v, idx, nwalls);
    return m;
}

/// Jittered hexagonal grid forming a big hexagon.
pub fn newVoronoi6Maze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var m: *Maze = undefined;
    var v = try baseSetup(gpa, params, rand, &m);
    errdefer m.deinit();
    const r = m.rows + 4;
    const c = m.columns + 4;
    const est: usize = @intCast(c * r + @divTrunc(1 - r * r, 4));
    try m.allocCells(est);
    const nwalls: usize = 3 * est + 8 * @as(usize, @intCast(m.rows + m.columns));
    var cpr = c - @divTrunc(r, 2);
    const y: f64 = 0;
    var idx: usize = 0;
    var i: i32 = 0;
    while (i < r) : (i += 1) {
        const x = fl(c - cpr) * 0.5;
        var j: i32 = 0;
        while (j < cpr) : (j += 1) {
            std.debug.assert(idx < est);
            const cur = &m.cells[idx];
            cur.no = @intCast(idx);
            idx += 1;
            cur.center.x = x + fl(j);
            cur.center.y = y + (fl(i) * RSPACE);
            if (i > 1 and i < r - 2 and j > 1 and j < cpr - 2) {
                if (params.roughborder or (i > 2 and i < r - 3 and j > 2 and j < cpr - 3)) {
                    cur.center.y += jitter(rand, params.jitter);
                    cur.center.x += jitter(rand, params.jitter);
                }
            }
            if (i < 2 or i >= r - 2 or j < 2 or j >= cpr - 2) {
                cur.type = mz.TYPE_TMP;
            }
        }
        if (i < @divTrunc(r, 2)) cpr += 1 else cpr -= 1;
    }
    try buildMaze(m, params, &v, idx, nwalls);
    return m;
}

/// Jittered triangular grid forming a big triangle.
pub fn newVoronoi3Maze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var m: *Maze = undefined;
    var v = try baseSetup(gpa, params, rand, &m);
    errdefer m.deinit();
    var r = m.rows + 2;
    const c = m.columns + 6;
    var n = @divTrunc((c + 1) * (c + 1), 4);
    const d = @divTrunc(c + 1, 2) - r;
    if (d > 0) {
        n -= d * d;
    } else {
        r = @divTrunc(c + 1, 2);
        m.rows = r;
    }
    const est: usize = @intCast(n);
    try m.allocCells(est);
    const nwalls: usize = 3 * est + 1 * @as(usize, @intCast(m.rows + m.columns));
    var idx: usize = 0;
    var i: i32 = 0;
    while (i < r) : (i += 1) {
        const l = c - i * 2;
        var j: i32 = 0;
        while (j < l) : (j += 1) {
            std.debug.assert(idx < est);
            const cur = &m.cells[idx];
            cur.no = @intCast(idx);
            idx += 1;
            cur.center.x = fl(i + j) * 0.5 + jitter(rand, 0.0001);
            cur.center.y = fl(r - i - 1) * RSPACE + RSPACE / 3.0 * fl(1 - @rem(j, 2)) + jitter(rand, 0.0001);
            if (i > 0 and i < r - 1 and j > 1 and j < l - 2) {
                if (params.roughborder or (i > 1 and i < r - 2 and j > 3 and j < l - 4)) {
                    cur.center.y += jitter(rand, params.jitter);
                    cur.center.x += jitter(rand, params.jitter);
                }
            }
            if (i < 1 or i >= r - 1 or j < 2 or j >= l - 2) {
                cur.type = mz.TYPE_TMP;
            }
        }
    }
    try buildMaze(m, params, &v, idx, nwalls);
    return m;
}

/// Concentric rings of jittered cells forming a disc (or ellipse).
pub fn newVoronoiDiscMaze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var m: *Maze = undefined;
    var v = try baseSetup(gpa, params, rand, &m);
    errdefer m.deinit();
    var off: f64 = 0.5;
    if (!params.roughborder) {
        v.clip = ellipticClip;
        off = 2.0;
    }
    const d = @divTrunc(m.columns + m.rows, 2);
    const r = @divTrunc(d + 1, 2);
    const ncells: usize = 1 + @as(usize, @intFromFloat(std.math.pi * fl(r) * fl(r + 1)));
    try m.allocCells(ncells);
    const nwalls: usize = 3 * ncells + 12 * @as(usize, @intCast(d));
    var idx: usize = 0;
    const cx = fl(m.columns) / 2.0;
    const cy = fl(m.rows) / 2.0;
    var cur = &m.cells[idx];
    cur.no = @intCast(idx);
    idx += 1;
    cur.center.x = cx + jitter(rand, params.jitter);
    cur.center.y = cy + jitter(rand, params.jitter);
    var ao: f64 = 0;
    var l: i32 = 0;
    var da: f64 = 0;
    var i: i32 = 1;
    while (i < r) : (i += 1) {
        ao = rand.unit() * std.math.pi;
        l = @intFromFloat(2.0 * std.math.pi * fl(i) + 0.5);
        da = 2.0 * std.math.pi / fl(l);
        var j: i32 = 0;
        while (j < l) : (j += 1) {
            const sc = geo.sincos(da * fl(j) + ao);
            const vx = sc.sin;
            const vy = sc.cos;
            std.debug.assert(idx < ncells);
            cur = &m.cells[idx];
            cur.no = @intCast(idx);
            idx += 1;
            cur.center.x = cx + fl(i) / (fl(r) - 0.5) * cx * vx;
            cur.center.y = cy + fl(i) / (fl(r) - 0.5) * cy * vy;
            if (i + 1 < r or params.roughborder) {
                cur.center.x += jitter(rand, params.jitter);
                cur.center.y += jitter(rand, params.jitter);
            }
        }
    }
    var j: i32 = 0;
    while (j < l) : (j += 1) {
        std.debug.assert(idx < ncells);
        const sc = geo.sincos(da * fl(j) + ao);
        const vx = sc.sin;
        const vy = sc.cos;
        cur = &m.cells[idx];
        cur.no = @intCast(idx);
        idx += 1;
        cur.type = mz.TYPE_TMP;
        cur.center.x = cx + cx * (1 + off / fl(r)) * vx;
        cur.center.y = cy + cy * (1 + off / fl(r)) * vy;
    }
    try buildMaze(m, params, &v, idx, nwalls);
    return m;
}

test "nln clip" {
    var s = Nln{ .x1 = -1, .y1 = 0.5, .x2 = 2, .y2 = 0.5, .xmin = 0, .xmax = 1, .ymin = 0, .ymax = 1 };
    try std.testing.expect(s.clip());
    try std.testing.expectEqual(@as(f64, 0), s.x1);
    try std.testing.expectEqual(@as(f64, 1), s.x2);
    var inside = Nln{ .x1 = 0.2, .y1 = 0.5, .x2 = 0.7, .y2 = 0.5, .xmin = 0, .xmax = 1, .ymin = 0, .ymax = 1 };
    try std.testing.expect(!inside.clip());
}
