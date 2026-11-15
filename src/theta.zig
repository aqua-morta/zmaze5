//! Theta mazes: concentric rings of cells around a center cell.

const std = @import("std");
const geo = @import("geo.zig");
const mz = @import("maze.zig");
const rng = @import("rng.zig");
const structure = @import("structure.zig");

const Maze = mz.Maze;
const Cell = mz.Cell;
const Wall = mz.Wall;
const Params = mz.Params;

fn ringSegments(r: i32, s: i32) i32 {
    return if (r < 1) 1 else r * s;
}

fn ringSegmentSum(r: i32, s: i32) i32 {
    if (r < 1) return @intFromBool(r == 0);
    return @divTrunc(s * (r + 1) * r, 2) + 1;
}

fn ringAlpha(r: i32, s: i32) f64 {
    return 2 * std.math.pi / @as(f64, @floatFromInt(ringSegments(r, s)));
}

/// Point at radius `r` and angle `a * s` (x = sin, y = cos as in the original).
fn thetaXY(a: f64, r: f64, s: f64) geo.Vec2 {
    const sc = geo.sincos(a * s);
    return .{ .x = sc.sin * r, .y = sc.cos * r };
}

fn f(i: i32) f64 {
    return @floatFromInt(i);
}

fn cellTheta(m: *Maze, ring: i32, segment: i32) *Cell {
    if (ring >= 0 and ring < m.rows) {
        const segs = ringSegments(ring, m.columns);
        const seg = @mod(segment + segs, segs);
        return &m.cells[@intCast(ringSegmentSum(ring - 1, m.columns) + seg)];
    }
    return m.off;
}

const Dir = enum { left, outer_right, outer_left, outer, inner };

fn thetaWall(m: *Maze, r: i32, s: i32, c: *Cell, nr: i32, ns: i32, other: *Cell, dir: Dir, wallno: u32) !*Wall {
    const ms = m.columns;
    const w = &m.walls[wallno];
    w.state = .closed;
    w.mark = mz.MARK_NONE;
    w.cells = .{ c, other };
    var p1: geo.Vec2 = undefined;
    var p2: geo.Vec2 = undefined;
    switch (dir) {
        .left => {
            p1 = thetaXY(ringAlpha(r, ms), f(r + 1), f(s + 1));
            p2 = thetaXY(ringAlpha(r, ms), f(r), f(s + 1));
            try m.addWallIdx(other, wallno);
        },
        .outer_right => {
            std.debug.assert(nr == r + 1);
            w.value = f(ns + 1) * ringAlpha(nr, ms) - f(s) * ringAlpha(r, ms);
            p1 = thetaXY(ringAlpha(nr, ms), f(nr), f(ns + 1));
            p2 = thetaXY(ringAlpha(r, ms), f(nr), f(s));
            try m.addWallIdx(other, wallno);
            w.features |= structure.WALL_ARC;
        },
        .outer_left => {
            std.debug.assert(nr == r + 1);
            w.value = f(s + 1) * ringAlpha(r, ms) - f(ns) * ringAlpha(nr, ms);
            p1 = thetaXY(ringAlpha(r, ms), f(nr), f(s + 1));
            p2 = thetaXY(ringAlpha(nr, ms), f(nr), f(ns));
            try m.addWallIdx(other, wallno);
            w.features |= structure.WALL_ARC;
        },
        .outer => {
            w.value = ringAlpha(r, ms);
            p1 = thetaXY(ringAlpha(r, ms), f(r + 1), f(s + 1));
            p2 = thetaXY(ringAlpha(r, ms), f(r + 1), f(s));
            w.features |= structure.WALL_ARC;
        },
        .inner => {
            w.value = ringAlpha(r, ms);
            p1 = thetaXY(ringAlpha(r, ms), f(r), f(s + 1));
            p2 = thetaXY(ringAlpha(r, ms), f(r), f(s));
            try m.addWallIdx(other, wallno);
            w.features |= structure.WALL_ARC;
        },
    }
    try m.addWallIdx(c, wallno);
    w.points = .{ p1, p2 };
    return w;
}

inline fn dst2(a: geo.Vec2, b: geo.Vec2) f64 {
    return b.sub(a).len2();
}

pub fn newThetaMaze(gpa: std.mem.Allocator, params: *Params, rand: *rng.Random) !*Maze {
    const m = try mz.create(gpa, params, rand);
    errdefer m.deinit();
    m.kind = .theta;
    m.tileable = false;
    m.rows = params.rows;
    m.columns = params.columns;
    const ms = m.columns;
    try m.allocCells(@intCast(ringSegmentSum(m.rows - 1, ms)));
    m.setupOff();
    try m.allocWalls(m.n_cells * 3 + @as(usize, @intCast(ms)));

    var i: usize = 0;
    var r: i32 = 0;
    while (r < m.rows) : (r += 1) {
        const segs = ringSegments(r, ms);
        var s: i32 = 0;
        while (s < segs) : (s += 1) {
            const cur = &m.cells[i];
            cur.no = @intCast(i);
            i += 1;
            cur.center = if (r > 0) thetaXY(ringAlpha(r, ms), f(r) + 0.5, f(s) + 0.5) else .{};
        }
    }

    var wi: u32 = 0;
    r = 1;
    while (r < m.rows) : (r += 1) {
        const segs = ringSegments(r, ms);
        var s: i32 = 0;
        while (s < segs) : (s += 1) {
            const cur = cellTheta(m, r, s);
            const cc = cur.center;
            _ = try thetaWall(m, r, s, cur, r, s + 1, cellTheta(m, r, s + 1), .left, wi);
            wi += 1;
            if (r + 1 < m.rows) {
                const so = @divTrunc(ringSegments(r + 1, ms) * s, ringSegments(r, ms));
                const n1 = cellTheta(m, r + 1, so);
                const n2 = cellTheta(m, r + 1, so + 1);
                const w1 = try thetaWall(m, r, s, cur, r + 1, so, n1, .outer_right, wi);
                wi += 1;
                const w2 = try thetaWall(m, r, s, cur, r + 1, so + 1, n2, .outer_left, wi);
                wi += 1;
                if (dst2(cc, n1.center) < dst2(cc, n2.center)) {
                    w2.features |= structure.WALL_INDESTRUCTIBLE;
                } else {
                    w1.features |= structure.WALL_INDESTRUCTIBLE;
                }
            } else {
                _ = try thetaWall(m, r, s, cur, 0, 0, m.off, .outer, wi);
                wi += 1;
            }
            if (r == 1) {
                _ = try thetaWall(m, r, s, cur, 0, 0, &m.cells[0], .inner, wi);
                wi += 1;
            }
        }
    }
    std.debug.assert(wi < m.n_walls);

    r = 0;
    while (r < params.startring) : (r += 1) {
        const segs = ringSegments(r, ms);
        var s: i32 = 0;
        while (s < segs) : (s += 1) {
            const cur = cellTheta(m, r, s);
            cur.type = mz.TYPE_OFF;
            _ = cur.visit();
        }
    }
    m.applyMask(params);
    return m;
}
