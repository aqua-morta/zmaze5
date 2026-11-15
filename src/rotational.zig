//! Mazes on Klaassen's monohedral pentagonal tilings with n-fold rotational
//! symmetry (B. Klaassen, "Rotationally symmetric tilings with convex
//! pentagons and hexagons", Elemente der Mathematik 71, 2016; the 5-fold
//! example is shown on Wikipedia's "Pentagonal tiling" page).
//!
//! With δ = π/n the plane around the center is split into 2n wedges of
//! angle δ. Every wedge is filled with translates of one equilateral
//! hexagon, the zonogon of the unit vectors a, b, c at φ-δ, φ, φ+δ (φ: the
//! wedge's axis): its corners have the angles 2δ, π-δ, π-δ, 2δ, π-δ, π-δ.
//! The hexagons of a wedge lie at O + p(a+b) + q(b+c) (row p+q) with O at
//! the center (even wedges) or at b (odd wedges). Every hexagon is cut by a
//! line through its center into two congruent pentagons: the corners at the
//! apex O and at O+a, then a third of b, the cut, two thirds of b and O+c.
//! The pentagon has the angles 2δ, π-δ, π-δ and two angles adding up to π.
//!
//! The pentagons form rings like the cells of a theta maze: ring r (r = 0
//! at the center) has n(r+1) pentagons, the inner ones of row j in the even
//! wedges and the outer ones of row j in the odd wedges belong to ring 2j
//! (resp. 2j+1, 2j+2). `-r` gives the number of rings (or the first and the
//! last ring), `-c` the symmetry n (the number of pentagons at the center).
//!
//! The tiling is not edge-to-edge: the cut of a hexagon meets its
//! neighbours' edges at a third of an edge. All edges are therefore split
//! at their thirds; tiling.zig joins the parts with the same neighbour.

const std = @import("std");
const geo = @import("geo.zig");
const mz = @import("maze.zig");
const rng = @import("rng.zig");
const tiling = @import("tiling.zig");

const Allocator = std.mem.Allocator;
const Vec2 = geo.Vec2;
const Maze = mz.Maze;
const Params = mz.Params;

/// pentagons with their apex (the 2δ corner) towards the center
pub const INNER = mz.TYPE_A;
/// pentagons with their apex away from the center
pub const OUTER = mz.TYPE_A + 1;

pub const MIN_FOLD = 3;
pub const MAX_FOLD = 8;

fn dir(angle: f64) Vec2 {
    const sc = geo.sincos(angle);
    return .{ .x = sc.cos, .y = sc.sin };
}

/// Edge length for a mean cell area of 1: a pentagon is half of the
/// hexagon, whose area is sin δ + sin δ + sin 2δ for unit edges.
fn edgeLength(n: usize) f64 {
    const d = std.math.pi / @as(f64, @floatFromInt(n));
    return @sqrt(2.0 / (2.0 * @sin(d) + @sin(2.0 * d)));
}

/// Number of pentagons in the rings 0 to `rings` - 1.
pub fn cellCount(n: usize, rings: usize) usize {
    return n * rings * (rings + 1) / 2;
}

pub fn newRotationalMaze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const tmp = arena_state.allocator();

    const n: usize = @intCast(std.math.clamp(params.columns, MIN_FOLD, MAX_FOLD));
    const rings: usize = @intCast(@max(params.rows, 1));
    const first: usize = @intCast(std.math.clamp(params.startring, 0, @as(i32, @intCast(rings)) - 1));
    if (cellCount(n, rings) > params.max_cells) return error.TooManyCells;

    const d = std.math.pi / @as(f64, @floatFromInt(n));
    const s = edgeLength(n);
    // a corner of the central pentagons at the top, as in Wikipedia's figure
    const phi0 = -std.math.pi / 2.0;
    // the tiling's center, so that the maze lies in the positive quadrant;
    // ring r reaches out to about (r+1)·|a+b| from the center
    const radius = @as(f64, @floatFromInt(rings + 1)) * 2.0 * @cos(d / 2.0) * s;
    const center = Vec2{ .x = radius, .y = radius };

    var verts: tiling.PointSet = .{};
    var tiles: std.ArrayListUnmanaged(tiling.Tile) = .empty;
    for (0..2 * n) |k| {
        const phi = phi0 + @as(f64, @floatFromInt(k)) * d;
        const a = dir(phi - d).scale(s);
        const b = dir(phi).scale(s);
        const c = dir(phi + d).scale(s);
        const odd = k % 2;
        const base = if (odd == 1) center.add(b) else center;
        // rows of hexagons; row j holds the rings 2j+odd and 2j+odd+1
        var j: usize = 0;
        while (2 * j + odd < rings) : (j += 1) {
            for (0..j + 1) |p| {
                const o = base.add(a.add(b).scale(@floatFromInt(p))).add(b.add(c).scale(@floatFromInt(j - p)));
                const ring = 2 * j + odd;
                // the inner pentagon at o and the outer one, turned by π,
                // at the opposite apex
                if (ring >= first) try addPentagon(tmp, &verts, &tiles, o, a, b, c, INNER);
                if (ring + 1 < rings and ring + 1 >= first)
                    try addPentagon(tmp, &verts, &tiles, o.add(a).add(b).add(c), a.scale(-1), b.scale(-1), c.scale(-1), OUTER);
            }
        }
    }
    return tiling.buildMaze(gpa, params, rand, verts.points.items, tiles.items);
}

/// Adds the pentagon with the apex o and the edges a, b/3, (cut), 2b/3, c
/// (counter clockwise), every edge split at its thirds.
fn addPentagon(tmp: Allocator, verts: *tiling.PointSet, tiles: *std.ArrayListUnmanaged(tiling.Tile), o: Vec2, a: Vec2, b: Vec2, c: Vec2, cell_type: u8) !void {
    const t = 1.0 / 3.0;
    const pts = [_]Vec2{
        o,
        o.add(a.scale(t)),
        o.add(a.scale(2 * t)),
        o.add(a),
        o.add(a).add(b.scale(t)),
        // the cut
        o.add(c).add(b.scale(2 * t)),
        o.add(c).add(b.scale(t)),
        o.add(c),
        o.add(c.scale(2 * t)),
        o.add(c.scale(t)),
    };
    const ids = try tmp.alloc(u32, pts.len);
    for (pts, ids) |p, *id| id.* = try verts.id(tmp, p);
    const main_corners = [_]Vec2{ pts[0], pts[3], pts[4], pts[5], pts[7] };
    var ctr: Vec2 = .{};
    for (main_corners) |p| ctr = ctr.add(p);
    try tiles.append(tmp, .{ .type = cell_type, .verts = ids, .center = ctr.scale(1.0 / 5.0) });
}

// ---------------------------------------------------------------------------

fn testMaze(n: i32, rings: i32, first: i32) !*Maze {
    const tables = @import("structures.zig");
    var params: Params = .{ .structure = tables.pentagon_rotational[0], .rows = rings, .columns = n, .startring = first };
    var rand = rng.Random.init(1);
    return newRotationalMaze(std.testing.allocator, &params, &rand);
}

/// Corners of a cell: the end points of its walls where the direction
/// changes (walls along one pentagon edge are collinear).
fn corners(m: *Maze, c: *mz.Cell, buf: *[16]Vec2) []Vec2 {
    var pts: [16]Vec2 = undefined;
    const k = c.nWalls();
    for (0..k) |i| {
        const w = m.cellWall(c, i);
        // the wall's end point that comes first counter clockwise
        const p0 = w.points[0].sub(c.center);
        const p1 = w.points[1].sub(c.center);
        pts[i] = if (p0.x * p1.y - p0.y * p1.x > 0) w.points[0] else w.points[1];
    }
    // sort by angle around the center
    const Ctx = struct {
        c: Vec2,
        fn lt(ctx: @This(), x: Vec2, y: Vec2) bool {
            return geo.atan2(x.y - ctx.c.y, x.x - ctx.c.x) < geo.atan2(y.y - ctx.c.y, y.x - ctx.c.x);
        }
    };
    std.sort.insertion(Vec2, pts[0..k], Ctx{ .c = c.center }, Ctx.lt);
    var nc: usize = 0;
    for (0..k) |i| {
        const prev = pts[(i + k - 1) % k];
        const cur = pts[i];
        const next = pts[(i + 1) % k];
        const u = cur.sub(prev);
        const v = next.sub(cur);
        if (@abs(u.x * v.y - u.y * v.x) > 1e-9 * u.len() * v.len()) {
            buf[nc] = cur;
            nc += 1;
        }
    }
    return buf[0..nc];
}

fn area(p: []const Vec2) f64 {
    var s: f64 = 0;
    for (0..p.len) |i| {
        const q = p[(i + 1) % p.len];
        s += p[i].x * q.y - q.x * p[i].y;
    }
    return @abs(s) / 2.0;
}

fn inside(p: []const Vec2, x: Vec2) bool {
    // convex, counter clockwise
    for (0..p.len) |i| {
        const u = p[(i + 1) % p.len].sub(p[i]);
        const v = x.sub(p[i]);
        if (u.x * v.y - u.y * v.x <= 1e-9) return false;
    }
    return true;
}

test "rotational tilings: rings of n(r+1) congruent pentagons without gaps" {
    for (MIN_FOLD..MAX_FOLD + 1) |nf| {
        const n: i32 = @intCast(nf);
        const rings = 7;
        const m = try testMaze(n, rings, -1);
        defer m.deinit();
        try std.testing.expectEqual(cellCount(nf, rings), m.n_cells);
        const d = std.math.pi / @as(f64, @floatFromInt(nf));
        const pent = (2.0 * @sin(d) + @sin(2.0 * d)) / 2.0;
        const s = edgeLength(nf);
        var polys: std.ArrayListUnmanaged([]Vec2) = .empty;
        defer {
            for (polys.items) |p| std.testing.allocator.free(p);
            polys.deinit(std.testing.allocator);
        }
        // fewest and most walls of the inner cells per cell type
        var walls: [2][2]usize = .{ .{ 99, 0 }, .{ 99, 0 } };
        for (m.cells[0..m.n_cells]) |*c| {
            var outer = false;
            for (0..c.nWalls()) |i| outer = outer or m.cellWall(c, i).outer();
            if (!outer) {
                const t = c.type - INNER;
                walls[t][0] = @min(walls[t][0], c.nWalls());
                walls[t][1] = @max(walls[t][1], c.nWalls());
            }
            var buf: [16]Vec2 = undefined;
            const cs = corners(m, c, &buf);
            try std.testing.expectEqual(@as(usize, 5), cs.len);
            try std.testing.expectApproxEqAbs(pent * s * s, area(cs), 1e-9);
            try std.testing.expect(c.nWalls() >= 5 and c.nWalls() <= 7);
            try polys.append(std.testing.allocator, try std.testing.allocator.dupe(Vec2, cs));
        }
        // a wall to the outside has no cell on its other side: no gaps and
        // no edges with a missed T-junction; inner walls have one
        for (m.walls[0..m.n_walls]) |*w| {
            const mid = w.points[0].mean(w.points[1]);
            const t = w.points[1].sub(w.points[0]).norm();
            const nrm = Vec2{ .x = -t.y, .y = t.x };
            var hits: usize = 0;
            for ([_]f64{ 1e-4, -1e-4 }) |e| {
                for (polys.items) |p| {
                    if (inside(p, mid.add(nrm.scale(e)))) hits += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, if (w.outer()) 1 else 2), hits);
        }
        // as listed in the help text
        if (walls[0][0] != 5 or walls[0][1] != 7 or walls[1][0] != 5 or walls[1][1] != 6) {
            std.debug.print("{d}-fold: walls {any}\n", .{ nf, walls });
            return error.WrongCellTypes;
        }
    }
}

test "rotational tilings: the first rings can be left out" {
    const m = try testMaze(5, 6, 2);
    defer m.deinit();
    try std.testing.expectEqual(cellCount(5, 6) - cellCount(5, 2), m.n_cells);
}
