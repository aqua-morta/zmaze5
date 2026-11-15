//! Draws a maze and writes it as PDF, SVG or PNG.
//!
//! The drawing code is generic over the canvas: vector.zig for SVG and PDF,
//! raster.zig for PNG. Both canvases offer the same operations: colors, paths with lines, Bézier
//! curves and arcs, stroking and filling, translation and rotation, and
//! text.

const std = @import("std");
const geo = @import("geo.zig");
const mz = @import("maze.zig");
const render = @import("render.zig");
const vector = @import("vector.zig");
const raster = @import("raster.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Maze = mz.Maze;
const Cell = mz.Cell;
const RenderParams = render.RenderParams;
const Stroke = render.Stroke;
const Color = render.Color;
const TextAlign = vector.TextAlign;

const SOLUTION_COLOR = Color{ .red = 0.8, .green = 0, .blue = 0, .alpha = 1 };

pub const OutputError = error{ OutOfMemory, TextTooLong, PathTooShort, WriteFailed };

// ---------------------------------------------------------------------------
// drawing (generic over the canvas)

fn drawNumber(cv: anytype, cell: *const Cell, pr: *const RenderParams, xoff: f64, yoff: f64) !void {
    var buf: [32]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d}", .{cell.no}) catch return;
    try cv.text(txt, cell.center.x * pr.xcellsize + pr.xoff + xoff, cell.center.y * pr.ycellsize + pr.yoff + yoff, .center);
}

fn drawNumbers(cv: anytype, m: *Maze, pr: *const RenderParams) !void {
    try cv.setColor(pr.foreground);
    for (m.cells[0..m.n_cells]) |*cell| try drawNumber(cv, cell, pr, 0, 0);
    if (m.tileable) {
        const xoff = m.tileWidth() * pr.xcellsize;
        const yoff = m.tileHeight() * pr.ycellsize;
        var i: i32 = 0;
        while (i < m.rows) : (i += 1) {
            try drawNumber(cv, m.cell2D(0, i), pr, xoff, 0);
            try drawNumber(cv, m.cell2D(m.columns - 1, i), pr, -xoff, 0);
        }
        i = 0;
        while (i < m.columns) : (i += 1) {
            try drawNumber(cv, m.cell2D(i, 0), pr, 0, yoff);
            try drawNumber(cv, m.cell2D(i, m.rows - 1), pr, 0, -yoff);
        }
        try drawNumber(cv, m.cell2D(0, 0), pr, xoff, yoff);
        try drawNumber(cv, m.cell2D(m.rows - 1, m.columns - 1), pr, -xoff, -yoff);
    }
}

fn renderStroke(cv: anytype, s: *const Stroke) !void {
    const pts = s.points.items;
    var i: usize = 0;
    while (i < pts.len) : (i += 1) {
        const p = pts[i];
        switch (p.type) {
            .move => try cv.moveTo(p.p.x, p.p.y),
            .center => {
                std.debug.assert(i > 0 and i + 1 < pts.len);
                const p1 = pts[i - 1].p;
                const ctr = p.p;
                i += 1;
                const p2 = pts[i].p;
                const dx = p2.x - ctr.x;
                const dy = p2.y - ctr.y;
                const r = @sqrt(dx * dx + dy * dy);
                const a1 = geo.atan2(p1.y - ctr.y, p1.x - ctr.x);
                const a2 = geo.atan2(dy, dx);
                try cv.arc(ctr.x, ctr.y, r, a1, a2);
            },
            .bezier => {
                std.debug.assert(i + 2 < pts.len);
                try cv.curveTo(p.p.x, p.p.y, pts[i + 1].p.x, pts[i + 1].p.y, pts[i + 2].p.x, pts[i + 2].p.y);
                i += 2;
            },
            else => try cv.lineTo(p.p.x, p.p.y),
        }
    }
    try cv.stroke();
}

fn renderArea(cv: anytype, s: *const Stroke) !void {
    for (s.points.items) |p| {
        if (p.type == .move) try cv.moveTo(p.p.x, p.p.y) else try cv.lineTo(p.p.x, p.p.y);
    }
    try cv.fill();
}

/// Filled polygons; each one ends with an `outline` point closing it.
/// Edges can be arcs (a `center` or `center_neg` point between their end
/// points).
fn renderPolygons(cv: anytype, s: *const Stroke) !void {
    const pts = s.points.items;
    var i: usize = 0;
    while (i < pts.len) : (i += 1) {
        const p = pts[i];
        switch (p.type) {
            .move => try cv.moveTo(p.p.x, p.p.y),
            .outline => try cv.closePath(),
            .center, .center_neg => {
                std.debug.assert(i > 0 and i + 1 < pts.len);
                const p1 = pts[i - 1].p;
                i += 1;
                const p2 = pts[i].p;
                const r = p2.sub(p.p).len();
                const a1 = geo.atan2(p1.y - p.p.y, p1.x - p.p.x);
                const a2 = geo.atan2(p2.y - p.p.y, p2.x - p.p.x);
                if (p.type == .center) {
                    try cv.arc(p.p.x, p.p.y, r, a1, a2);
                } else {
                    try cv.arcNegative(p.p.x, p.p.y, r, a1, a2);
                }
            },
            else => try cv.lineTo(p.p.x, p.p.y),
        }
    }
    if (pts.len > 0) try cv.fillStroke();
}

fn renderOutline(cv: anytype, s: *const Stroke) !void {
    for (s.points.items) |p| {
        if (p.type == .outline) try cv.lineTo(p.p.x, p.p.y) else try cv.moveTo(p.p.x, p.p.y);
    }
    try cv.stroke();
}

fn renderCurvedStroke(cv: anytype, s: *const Stroke) !void {
    const pts = s.points.items;
    if (pts.len == 0) return;
    try cv.moveTo(pts[0].p.x, pts[0].p.y);
    var i: usize = 0;
    while (i < pts.len) : (i += 1) {
        if (i + 1 < pts.len) {
            try cv.curveTo(pts[i].p.x, pts[i].p.y, pts[i].p.x, pts[i].p.y, pts[i + 1].p.x, pts[i + 1].p.y);
            i += 1;
        }
    }
    try cv.stroke();
}

fn renderText(cv: anytype, m: *Maze, pr: *const RenderParams) !void {
    try cv.setColor(pr.foreground);
    for (m.cells[0..m.n_cells]) |*cell| {
        // 255 marks path cells which intentionally stay empty
        if (cell.user_data == 0 or cell.user_data == 255) continue;
        const buf = [1]u8{cell.user_data};
        try cv.text(&buf, cell.center.x * pr.xcellsize + pr.xoff, cell.center.y * pr.ycellsize + pr.yoff, .center);
    }
}

fn renderCopyright(cv: anytype, pr: *const RenderParams) !void {
    const txt = pr.copyright_text orelse return;
    const bg = pr.background;
    try cv.setColor(.{ .red = bg.red * 0.8, .green = bg.green * 0.8, .blue = bg.blue, .alpha = 1.0 });
    try cv.text(txt, pr.width - 8, pr.height, .right_bottom);
}

/// The bridges of the crossings. With `cover` their area is filled with the
/// background color to hide the walls below; otherwise those walls were cut
/// out already (`bridgeAreas`).
fn renderCrossovers(gpa: Allocator, cv: anytype, m: *Maze, pr: *const RenderParams, cover: bool) !void {
    for (m.cells[0..m.n_cells]) |*cell| {
        if (cell.type != mz.TYPE_CROSSOVER) continue;
        var idx: usize = 0;
        for (0..2) |_| {
            var s = try render.renderCrossover(gpa, m, cell, &idx, pr);
            defer s.deinit();
            if (cover) {
                try cv.setColor(pr.background);
                try renderArea(cv, &s);
            }
            try cv.setColor(pr.foreground);
            try renderOutline(cv, &s);
        }
    }
}

fn hasCrossovers(m: *const Maze) bool {
    for (m.cells[0..m.n_cells]) |*cell| {
        if (cell.type == mz.TYPE_CROSSOVER) return true;
    }
    return false;
}

/// Adds the areas of all bridges to the current path, all with the same
/// orientation: bridges of neighbouring crossings overlap a little, and with
/// opposite orientations the overlap would be a hole (nonzero winding).
fn bridgeAreas(gpa: Allocator, cv: anytype, m: *Maze, pr: *const RenderParams) !void {
    for (m.cells[0..m.n_cells]) |*cell| {
        if (cell.type != mz.TYPE_CROSSOVER) continue;
        var idx: usize = 0;
        for (0..2) |_| {
            var s = try render.renderCrossover(gpa, m, cell, &idx, pr);
            defer s.deinit();
            const pts = s.points.items;
            if (pts.len < 3) continue;
            var area: f64 = 0;
            for (pts, 0..) |a, i| {
                const b = pts[(i + 1) % pts.len];
                area += a.p.x * b.p.y - a.p.y * b.p.x;
            }
            for (0..pts.len) |i| {
                const p = pts[if (area < 0) pts.len - 1 - i else i].p;
                if (i == 0) try cv.moveTo(p.x, p.y) else try cv.lineTo(p.x, p.y);
            }
            try cv.closePath();
        }
    }
}

fn drawMaze(gpa: Allocator, cv: anytype, m: *Maze, pr: *const RenderParams) !void {
    try cv.setLineWidth(pr.linewidth);
    try cv.setColor(pr.background);
    try cv.rectangle(0, 0, pr.width, pr.height);
    try cv.fill();
    try cv.translate(pr.width / 2.0, pr.height / 2.0);
    try cv.rotate(pr.rotation);
    try cv.translate(-pr.xdisp - pr.bordersize, -pr.ydisp - pr.bordersize);
    if (m.tileable and pr.bordersize > 0) {
        try cv.setColor(.{ .red = 0.5, .green = 0.5, .blue = 0.5, .alpha = 0.33 });
        try cv.rectangle(pr.bordersize, pr.bordersize, pr.width - 2 * pr.bordersize, pr.height - 2 * pr.bordersize);
        try cv.fill();
    }
    try renderCopyright(cv, pr);
    // A bridge hides the walls below it by covering them with the background
    // color. A (partly) transparent background can't, so the bridges are cut
    // out of the walls and pillars instead.
    const knockout = pr.background.alpha < 1 and hasCrossovers(m);
    if (knockout) try cv.beginKnockout();
    try cv.setColor(pr.pillar orelse pr.foreground);
    {
        var s = try render.renderPillars(gpa, m, pr);
        defer s.deinit();
        try renderPolygons(cv, &s);
    }
    try cv.setColor(pr.foreground);
    {
        var s = try render.renderMaze(gpa, m, pr);
        defer s.deinit();
        try renderStroke(cv, &s);
    }
    if (knockout) {
        try bridgeAreas(gpa, cv, m, pr);
        try cv.endKnockout();
    }
    try renderCrossovers(gpa, cv, m, pr, !knockout);
    try cv.setColor(pr.foreground);
    if (pr.draw_marks) {
        var s = try render.renderEntryExit(gpa, m, m.entrance, pr);
        try renderStroke(cv, &s);
        s.deinit();
        s = try render.renderEntryExit(gpa, m, m.exit, pr);
        try renderStroke(cv, &s);
        s.deinit();
    }
    if (pr.draw_solution or pr.solution_text != null) {
        try cv.setColor(SOLUTION_COLOR);
        var s = try render.renderSolution(gpa, m, pr);
        defer s.deinit();
        if (pr.draw_solution) try renderCurvedStroke(cv, &s);
        if (pr.solution_text) |txt| {
            try render.renderTextAlongStroke(m, &s, txt);
            try renderText(cv, m, pr);
        }
    }
    if (pr.drawno) try drawNumbers(cv, m, pr);
}

/// Computes the page size and the offsets of the maze on the page.
fn setupSize(m: *Maze, pr: *RenderParams) void {
    const sc = geo.sincos(pr.rotation);
    const sn = sc.sin;
    const co = sc.cos;
    const dim = m.dimension();
    const cborder = pr.bordersize;
    pr.xoff = cborder - (pr.xcellsize * dim.xmin);
    pr.yoff = cborder - (pr.ycellsize * dim.ymin);
    const w = (dim.xmax - dim.xmin) * pr.xcellsize;
    const h = (dim.ymax - dim.ymin) * pr.ycellsize;
    pr.width = @round(w * co + h * sn + 2 * cborder);
    pr.height = @round(w * sn + h * co + 2 * cborder);
    pr.xdisp = w / 2.0;
    pr.ydisp = h / 2.0;
}

// ---------------------------------------------------------------------------
// output

/// The maze as SVG or PDF document, drawn with the native canvas.
pub fn renderVector(gpa: Allocator, m: *Maze, pr: *RenderParams, kind: vector.Kind) ![]u8 {
    setupSize(m, pr);
    var cv = vector.Canvas.init(gpa, kind, pr.width, pr.height);
    defer cv.deinit();
    try drawMaze(gpa, &cv, m, pr);
    return cv.finish();
}

/// The maze as PNG file, drawn with the native rasterizer.
pub fn renderPng(gpa: Allocator, m: *Maze, pr: *RenderParams) ![]u8 {
    setupSize(m, pr);
    var cv = try raster.Canvas.init(gpa, @intFromFloat(pr.width), @intFromFloat(pr.height));
    defer cv.deinit();
    try drawMaze(gpa, &cv, m, pr);
    return cv.encodePng();
}

pub const RenderError = error{ OutOfMemory, TextTooLong, PathTooShort };

/// Renders the maze in the format given in the render parameters (default
/// PNG); the caller owns the returned document.
pub fn renderDocument(gpa: Allocator, m: *Maze, pr: *RenderParams) RenderError![]u8 {
    const format = pr.format orelse .png;
    const doc = switch (format) {
        .svg => renderVector(gpa, m, pr, .svg),
        .pdf => renderVector(gpa, m, pr, .pdf),
        .png => renderPng(gpa, m, pr),
    };
    return doc catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TextTooLong => return error.TextTooLong,
        error.PathTooShort => return error.PathTooShort,
    };
}

/// Writes a rendered document to the file, or to stdout if `filename` is null.
pub fn write(io: Io, doc: []const u8, filename: ?[:0]const u8) error{WriteFailed}!void {
    if (filename) |f| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = f, .data = doc }) catch |e| {
            std.log.err("cannot write '{s}': {t}", .{ f, e });
            return error.WriteFailed;
        };
    } else {
        var w = Io.File.stdout().writerStreaming(io, &.{});
        w.interface.writeAll(doc) catch return error.WriteFailed;
    }
}
