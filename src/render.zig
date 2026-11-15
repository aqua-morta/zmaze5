//! Converts a maze into strokes (device independent paths): walls, organic
//! cell outlines, crossovers, entrance/exit marks and the solution path.

const std = @import("std");
const geo = @import("geo.zig");
const mz = @import("maze.zig");
const structure = @import("structure.zig");
const pillars = @import("pillars.zig");

const Allocator = std.mem.Allocator;
const Vec2 = geo.Vec2;
const Maze = mz.Maze;
const Cell = mz.Cell;
const Wall = mz.Wall;

const DEG90: f64 = std.math.pi / 2.0;

pub const Color = struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64 = 1,
};

pub const Boundary = enum(i8) { keep = 0, outside = 1, inside = -1 };

pub const Format = enum { pdf, svg, png };

pub const RenderParams = struct {
    /// null means stdout
    filename: ?[:0]const u8 = null,
    format: ?Format = null,
    width: f64 = -1,
    height: f64 = -1,
    xcellsize: f64 = 32,
    ycellsize: f64 = 32,
    bordersize: f64 = 16,
    xoff: f64 = 16,
    yoff: f64 = 16,
    linewidth: f64 = 2.5,
    rotation: f64 = 0,
    xdisp: f64 = 0,
    ydisp: f64 = 0,
    drawno: bool = false,
    organic: bool = false,
    bridgewidth: f64 = 0.25,
    foreground: Color = .{ .red = 0.3, .green = 0.3, .blue = 0.8 },
    background: Color = .{ .red = 1, .green = 1, .blue = 1 },
    /// fill color of the pillars (`--pillar-color`); default: foreground
    pillar: ?Color = null,
    draw_marks: bool = true,
    draw_solution: bool = false,
    bending: f64 = 1,
    boundary: Boundary = .outside,
    fuzzy: bool = false,
    amplitude: f64 = 0.1,
    n_fuzzy: usize = 8,
    solution_text: ?[]const u8 = null,
    copyright_text: ?[:0]const u8 = null,
};

/// `center` is the center of an arc from the previous point to the next
/// one (in the direction of increasing angles), `center_neg` the same in
/// the opposite direction.
pub const StrokeType = enum(u8) { move, line, outline, arc, center, center_neg, bezier };

pub const Point = struct {
    type: StrokeType,
    p: Vec2,
    cell: ?*Cell = null,
};

const MIN_DIST: f64 = 0.01;

/// A sequence of drawing commands in device coordinates.
pub const Stroke = struct {
    gpa: Allocator,
    params: *const RenderParams,
    points: std.ArrayListUnmanaged(Point) = .empty,

    pub fn init(gpa: Allocator, params: *const RenderParams) Stroke {
        return .{ .gpa = gpa, .params = params };
    }

    pub fn deinit(s: *Stroke) void {
        s.points.deinit(s.gpa);
    }

    pub fn append(s: *Stroke, t: StrokeType, v: Vec2) !void {
        try s.appendCell(t, v, null);
    }

    /// Appends a point given in maze coordinates. Points too close to the
    /// previous one are skipped and consecutive moves are merged.
    pub fn appendCell(s: *Stroke, t: StrokeType, v: Vec2, c: ?*Cell) !void {
        const pr = s.params;
        const p = Vec2{ .x = pr.xcellsize * v.x + pr.xoff, .y = pr.ycellsize * v.y + pr.yoff };
        const items = s.points.items;
        const n = items.len;
        if (n == 0 or t == .bezier or p.sub(items[n - 1].p).len2() > MIN_DIST) {
            if (n > 0 and t == .move and items[n - 1].type == .move) {
                items[n - 1] = .{ .type = t, .p = p, .cell = c };
            } else {
                try s.points.append(s.gpa, .{ .type = t, .p = p, .cell = c });
            }
        }
    }
};

// ---------------------------------------------------------------------------
// walls

fn xSeparated(c1: *const Cell, c2: *const Cell) f64 {
    const dx = c2.center.x - c1.center.x;
    return if (dx * dx > 2.5) (if (dx < 0) -1 else 1) else 0;
}

fn ySeparated(c1: *const Cell, c2: *const Cell) f64 {
    const dy = c2.center.y - c1.center.y;
    return if (dy * dy > 2.5) (if (dy < 0) -1 else 1) else 0;
}

fn appendSubStrokes(m: *Maze, s: *Stroke, w1: Vec2, w2: Vec2) !void {
    const pr = s.params;
    const delta = w2.sub(w1);
    const n = pr.n_fuzzy;
    for (0..n) |i| {
        const sc = (0.5 - m.rand.unit()) * pr.amplitude;
        const fi: f64 = @floatFromInt(i);
        const fnn: f64 = @floatFromInt(n);
        try s.append(.line, w1.add(delta.scale(fi / fnn)).add(delta.scale(sc).rot(DEG90)));
    }
}

fn bridgePoint(v1: Vec2, v2: Vec2, pr: *const RenderParams) Vec2 {
    return v1.weightedMean2(v2, pr.bridgewidth);
}

fn bridgePointWall(w: *const Wall, idx: usize, pr: *const RenderParams) Vec2 {
    return if (idx == 0)
        w.points[1].weightedMean2(w.points[0], pr.bridgewidth)
    else
        w.points[0].weightedMean2(w.points[1], pr.bridgewidth);
}

/// The bending angle of an arc wall (drawn from points[0] to points[1]),
/// or 0 for straight walls.
fn arcAngle(w: *const Wall, pr: *const RenderParams) f64 {
    if (!w.has(structure.WALL_ARC) or w.isBridged()) return 0;
    // the center point of the arc is calculated from its angle
    var alpha = if (@abs(pr.bending) > 2.0) pr.bending / 180.0 * std.math.pi else w.value * pr.bending;
    if (w.outer()) {
        switch (pr.boundary) {
            .outside => alpha = @abs(alpha),
            .inside => alpha = -@abs(alpha),
            .keep => {},
        }
    }
    return if (@abs(geo.tan(0.5 * alpha)) > 1e-5) alpha else 0;
}

/// Center of the arc with angle `alpha` from w1 to w2.
fn arcCenter(w1: Vec2, w2: Vec2, alpha: f64) Vec2 {
    const cl = 0.5 / geo.tan(0.5 * alpha);
    return w1.mean(w2).add(w2.sub(w1).scale(cl).rot(DEG90));
}

fn strokeWall(m: *Maze, s: *Stroke, w: *const Wall, w1_: Vec2, w2_: Vec2) !void {
    const pr = s.params;
    var w1 = w1_;
    var w2 = w2_;
    const alpha = arcAngle(w, pr);
    if (alpha != 0) {
        const ctr = arcCenter(w1, w2, alpha);
        if (alpha < 0) std.mem.swap(Vec2, &w1, &w2);
        try s.append(.move, w1);
        try s.append(.center, ctr);
        try s.append(.arc, w2);
    } else {
        try s.append(.move, w1);
        if (pr.fuzzy) try appendSubStrokes(m, s, w1, w2);
        try s.append(.line, w2);
    }
}

fn wallStroke(m: *Maze, c: *const Cell, w: *const Wall, w1: Vec2, w2: Vec2, s: *Stroke) !void {
    try strokeWall(m, s, w, w1, w2);
    if (m.tileable) {
        // repeat walls crossing the tile border on the opposite side
        const xoff = m.tileWidth();
        const yoff = m.tileHeight();
        const other = w.other(c);
        const xsep = xSeparated(c, other);
        const ysep = ySeparated(c, other);
        if (xsep != 0) {
            var off = Vec2{ .x = xoff * xsep, .y = 0 };
            try strokeWall(m, s, w, w1.add(off), w2.add(off));
            if (ysep != 0) {
                off = .{ .x = xoff * xsep, .y = yoff * ysep };
                try strokeWall(m, s, w, w1.add(off), w2.add(off));
            }
        }
        if (ysep != 0) {
            const off = Vec2{ .x = 0, .y = yoff * ysep };
            try strokeWall(m, s, w, w1.add(off), w2.add(off));
        }
    }
}

fn renderCell(m: *Maze, c: *Cell, s: *Stroke) !void {
    const n = c.nWalls();
    var cn: usize = 0;
    for (0..n) |j| {
        if (m.isOpen(c, j)) {
            cn = j;
            break;
        }
    }
    for (0..n) |_| {
        const w = m.cellWall(c, cn);
        if (w.mark != mz.MARK_VISITED) {
            w.mark = mz.MARK_VISITED;
            const w1 = w.points[0];
            const w2 = w.points[1];
            if (w.isBridged()) {
                try wallStroke(m, c, w, w1, bridgePoint(w2, w1, s.params), s);
                try wallStroke(m, c, w, w2, bridgePoint(w1, w2, s.params), s);
            } else if (w.isClosed()) {
                try wallStroke(m, c, w, w1, w2, s);
            }
        }
        cn = (cn + 1) % n;
    }
}

const WFAC: f64 = 0.5;

fn renderOrganicCell(m: *Maze, c: *Cell, s: *Stroke) !void {
    const pr = s.params;
    var idx: usize = 0;
    const n_open = m.openings(c, &idx);
    const cc = c.center;
    switch (n_open) {
        0 => {},
        1 => {
            var w = m.cellWall(c, idx);
            var widx: usize = 0;
            var bp = bridgePointWall(w, widx, pr);
            try s.append(.move, bp);
            var v = w.center().unit(cc).scale(0.05);
            try s.append(.bezier, bp.add(v));
            _ = m.connectedWall(c, &w, &widx);
            for (0..c.nWalls() - 1) |_| {
                const wp1 = w.points[1 - widx];
                const wp2 = w.points[widx];
                const wc = w.center();
                v = w.center().unit(cc).scale(0.05);
                try s.append(.bezier, wp1.weightedMean2(wp2, 0.75).add(v));
                try s.append(.bezier, wc.add(v));
                try s.append(.bezier, wp1.weightedMean2(wp2, 0.25).add(v));
                _ = m.connectedWall(c, &w, &widx);
            }
            bp = bridgePointWall(w, 1 - widx, pr);
            v = w.center().unit(cc).scale(0.05);
            try s.append(.line, bp.add(v));
            try s.append(.line, bp);
        },
        2 => {
            var w = m.cellWall(c, idx);
            var widx: usize = 0;
            const wp11 = bridgePointWall(w, widx, pr);
            const wp12 = bridgePointWall(w, 1 - widx, pr);
            const v1 = w.center().unit(cc);
            var open = m.connectedWall(c, &w, &widx);
            for (0..c.nWalls() - 1) |_| {
                if (open) {
                    const wp21 = bridgePointWall(w, 1 - widx, pr);
                    const wp22 = bridgePointWall(w, widx, pr);
                    const wc = w.center();
                    const v2 = wc.unit(cc);
                    const l1 = wp11.sub(wp21).len() * WFAC;
                    const l2 = wp22.sub(wp12).len() * WFAC;
                    try s.append(.move, wp11);
                    try s.append(.bezier, wp11.add(v1.scale(l1)));
                    try s.append(.bezier, wp21.add(v2.scale(l1)));
                    try s.append(.bezier, wp21);
                    try s.append(.move, wp22);
                    try s.append(.bezier, wp22.add(v2.scale(l2)));
                    try s.append(.bezier, wp12.add(v1.scale(l2)));
                    try s.append(.bezier, wp12);
                    break;
                }
                open = m.connectedWall(c, &w, &widx);
            }
        },
        else => {
            var w = m.cellWall(c, idx);
            var widx: usize = 0;
            var wp1 = bridgePointWall(w, widx, pr);
            var v1 = w.center().unit(cc);
            var open = m.connectedWall(c, &w, &widx);
            for (0..c.nWalls()) |_| {
                if (open) {
                    const wp2 = bridgePointWall(w, 1 - widx, pr);
                    const v2 = w.center().unit(cc);
                    const l = wp1.sub(wp2).len() * WFAC;
                    try s.append(.move, wp1);
                    try s.append(.bezier, wp1.add(v1.scale(l)));
                    try s.append(.bezier, wp2.add(v2.scale(l)));
                    try s.append(.bezier, wp2);
                    v1 = v2;
                    wp1 = bridgePointWall(w, widx, pr);
                }
                open = m.connectedWall(c, &w, &widx);
            }
        },
    }
}

/// Strokes for all walls of the maze.
pub fn renderMaze(gpa: Allocator, m: *Maze, pr: *const RenderParams) !Stroke {
    var s = Stroke.init(gpa, pr);
    errdefer s.deinit();
    m.clearMarks();
    for (m.cells[0..m.n_cells]) |*c| {
        if (c.type == mz.TYPE_PILLAR and !pr.organic) {
            // the outer border along pillars (may have another color)
            for (0..c.nWalls()) |i| {
                const w = m.cellWall(c, i);
                if (w.other(c).type == mz.TYPE_OFF) try wallStroke(m, c, w, w.points[0], w.points[1], &s);
            }
        }
        if (!c.valid()) continue;
        if (pr.organic) {
            try renderOrganicCell(m, c, &s);
        } else {
            try renderCell(m, c, &s);
        }
    }
    return s;
}

/// Outlines of the pillars (cells excluded with `--pillars`), one closed
/// polygon each.
pub fn renderPillars(gpa: Allocator, m: *Maze, pr: *const RenderParams) !Stroke {
    var s = Stroke.init(gpa, pr);
    errdefer s.deinit();
    var buf: [64]pillars.Edge = undefined;
    for (m.cells[0..m.n_cells]) |*c| {
        if (c.type != mz.TYPE_PILLAR) continue;
        const poly = pillars.outline(m, c, &buf) orelse continue;
        try s.append(.move, poly[0].from);
        for (poly) |e| {
            const reversed = e.reversed;
            const alpha = arcAngle(e.wall, pr);
            if (alpha != 0) {
                // the arc as drawn for the wall: from points[0] to points[1]
                // (angle alpha), drawn in the direction of increasing angles
                // from points[1] to points[0] if alpha < 0
                const ctr = if (reversed) arcCenter(e.to, e.from, alpha) else arcCenter(e.from, e.to, alpha);
                try s.append(if (reversed == (alpha < 0)) .center else .center_neg, ctr);
            }
            try s.append(.line, e.to);
        }
        try s.append(.outline, poly[0].from);
    }
    return s;
}

const BOVER: f64 = 0.1;

/// The bridge of a crossover cell. `idx` is the wall index to continue the
/// search for bridged walls at; it is advanced past the found wall.
pub fn renderCrossover(gpa: Allocator, m: *Maze, c: *Cell, idx: *usize, pr: *const RenderParams) !Stroke {
    var s = Stroke.init(gpa, pr);
    errdefer s.deinit();
    var wall1: ?*Wall = null;
    var wall2: ?*Wall = null;
    var i = idx.*;
    while (i < c.nWalls()) : (i += 1) {
        const w1 = m.cellWall(c, i);
        if (w1.isBridged()) {
            wall1 = w1;
            const c1 = w1.primary();
            for (0..c.nWalls()) |j| {
                wall2 = m.cellWall(c, j);
                if (wall2.?.secondary() == c1) break;
            }
            idx.* = i + 1;
            break;
        }
    }
    const a = wall1 orelse return s;
    const b = wall2 orelse return s;
    const w11 = a.points[0];
    const w12 = a.points[1];
    var w21 = b.points[0];
    var w22 = b.points[1];
    if (!w21.sub(w11).colinear(w22.sub(w12))) std.mem.swap(Vec2, &w21, &w22);
    var delta = Vec2{};
    if (!pr.organic) {
        delta = w21.sub(w12).mean(w22.sub(w11)).norm().scale(BOVER);
    }
    try s.append(.move, bridgePoint(w12, w11, pr).sub(delta));
    try s.append(.outline, bridgePoint(w22, w21, pr).add(delta));
    try s.append(.line, bridgePoint(w21, w22, pr).add(delta));
    try s.append(.outline, bridgePoint(w11, w12, pr).sub(delta));
    return s;
}

/// Arrow marking the entrance (pointing in) or exit (pointing out).
pub fn renderEntryExit(gpa: Allocator, m: *Maze, cell: ?*Cell, pr: *const RenderParams) !Stroke {
    var s = Stroke.init(gpa, pr);
    errdefer s.deinit();
    const c = cell orelse return s;
    for (0..c.nWalls()) |i| {
        const w = m.cellWall(c, i);
        if (!w.isOpen()) continue;
        if (m.neighbour(c, i).type != mz.TYPE_OFF) continue;
        const w1 = w.points[0];
        const w2 = w.points[1];
        const mean = w.center();
        const delta = w2.sub(w1).norm();
        const v1 = mean.add(delta.scale(0.25).rot(DEG90));
        const v2 = mean.add(delta.scale(0.25).rot(-DEG90));
        const delta1 = c.center.sub(v1);
        const delta2 = c.center.sub(v2);
        const m12 = v1.mean(v2);
        if ((delta1.len2() < delta2.len2()) != (c == m.entrance)) {
            const tmp = v2.sub(v1).scale(0.3);
            try s.append(.move, m12.add(tmp.rot(-DEG90)));
            try s.append(.line, v2);
            try s.append(.line, m12.add(tmp.rot(DEG90)));
        } else {
            const tmp = v1.sub(v2).scale(0.3);
            try s.append(.move, m12.add(tmp.rot(-DEG90)));
            try s.append(.line, v1);
            try s.append(.line, m12.add(tmp.rot(DEG90)));
        }
        try s.append(.move, v1);
        try s.append(.line, v2);
        break;
    }
    return s;
}

// ---------------------------------------------------------------------------
// solution

fn strokeToOff(m: *Maze, c: *Cell, s: *Stroke) !void {
    for (0..c.nWalls()) |i| {
        if (m.neighbour(c, i) == m.off) {
            const tmp = m.cellWall(c, i).center().weightedMean2(c.center, 0.66);
            try s.appendCell(.line, tmp, c);
            break;
        }
    }
}

const SolFrame = struct { cell: *Cell, i: usize };

/// Path from the exit back to the entrance. Each point remembers the cell it
/// belongs to (used to place text along the solution).
pub fn renderSolution(gpa: Allocator, m: *Maze, pr: *const RenderParams) !Stroke {
    var s = Stroke.init(gpa, pr);
    errdefer s.deinit();
    const exit = m.exit orelse return s;
    const goal = m.entrance;
    m.clearMarks();
    _ = exit.visit();

    // depth first search exit -> entrance; on success the path is unwound
    // appending wall centers and cell centers (as the recursive original)
    var stack: std.ArrayListUnmanaged(SolFrame) = .empty;
    defer stack.deinit(gpa);
    var found = false;
    if (exit == goal) {
        try s.appendCell(.line, exit.center, exit);
        found = true;
    } else {
        try stack.append(gpa, .{ .cell = exit, .i = 0 });
    }
    while (!found and stack.items.len > 0) {
        const f = &stack.items[stack.items.len - 1];
        if (f.i >= f.cell.nWalls()) {
            _ = stack.pop();
            continue;
        }
        const i = f.i;
        f.i += 1;
        if (m.go(f.cell, i, mz.MARK_VISITED)) |n| {
            if (n == goal) {
                try s.appendCell(.line, n.center, n);
                found = true;
            } else {
                try stack.append(gpa, .{ .cell = n, .i = 0 });
            }
        }
    }
    if (found) {
        var k = stack.items.len;
        while (k > 0) {
            k -= 1;
            const f = stack.items[k];
            // f.i - 1 is the wall leading to the next cell on the path
            const w = m.cellWall(f.cell, f.i - 1);
            try s.appendCell(.line, w.center(), f.cell);
            try s.appendCell(.line, f.cell.center, f.cell);
        }
    }
    try strokeToOff(m, exit, &s);
    return s;
}

const fillchars = "ABCEFGHIJKLMNOPQRSTUVWXYZ";

pub const TextError = error{ TextTooLong, PathTooShort };

/// Distributes `text` along the solution path and fills random characters
/// into the remaining cells (stored as `user_data` of the cells).
pub fn renderTextAlongStroke(m: *Maze, s: *const Stroke, text: []const u8) TextError!void {
    const len = text.len;
    const n = s.points.items.len;
    if (len > n) {
        std.log.err("Text too long ({d}); cannot render to stroke ({d} steps)", .{ len, n });
        return error.TextTooLong;
    }
    if (n < 4) {
        std.log.err("Path too short ({d}); stroke not rendered", .{n});
        return error.PathTooShort;
    }
    m.clearUserData();
    const delta = @as(f64, @floatFromInt(len)) / (@as(f64, @floatFromInt(n)) - 2);
    var sum: f64 = 0;
    var lidx: usize = 0;
    for (s.points.items) |p| {
        const cur = p.cell.?;
        const isum: usize = @intFromFloat(sum);
        if (lidx != isum) {
            cur.user_data = std.ascii.toUpper(text[lidx]);
        } else if (cur.user_data == 0) {
            // path cell without a letter (a cell has several path points,
            // don't overwrite a letter placed before)
            cur.user_data = 255;
        }
        lidx = isum;
        sum += delta;
    }
    for (m.cells[0..m.n_cells]) |*c| {
        if (c.type != mz.TYPE_OFF and c.type != mz.TYPE_PILLAR and c.user_data == 0) {
            const idx = m.rand.below(n);
            if (idx < len) {
                if (m.rand.below(3) == 0) {
                    c.user_data = std.ascii.toUpper(fillchars[m.rand.below(fillchars.len)]);
                } else {
                    c.user_data = std.ascii.toUpper(text[m.rand.below(len)]);
                }
            }
        }
    }
}
