//! Aperiodic mazes based on Socolar's clamshell tiling (Tilings
//! Encyclopedia: "Clamshell"): two kinds of the same isosceles trapezoid
//! and a small "clamshell", with tenfold symmetry.
//!
//! Trapezoid: a short edge of length 1 and three edges of length φ² (angles
//! 108°, 108°, 72°, 72°). Clamshell: three consecutive edges of a regular
//! decagon with unit edges, closed by the chord of length φ².
//!
//! The substitution (inflation factor φ²) replaces a type A trapezoid by
//! 5 A + 3 B trapezoids and 2 clamshells, a type B trapezoid by 3 A + 2 B
//! and 1 clamshell; clamshells are replaced by nothing. The children stick
//! out of their parent (and leave part of it empty), but together the
//! children of all tiles of a tiling form a new edge-to-edge tiling, so the
//! clamshells of the last step fill the remaining gaps exactly. The rule
//! was measured from the encyclopedia's picture; the orientation of the
//! children is the only one for which repeated substitution never makes
//! tiles overlap. The substitution matrix [[5, 3], [3, 2]] has the
//! eigenvalue φ⁴, the area factor.

const std = @import("std");
const geo = @import("geo.zig");
const mz = @import("maze.zig");
const rng = @import("rng.zig");
const tiling = @import("tiling.zig");

const Allocator = std.mem.Allocator;
const Vec2 = geo.Vec2;
const Maze = mz.Maze;
const Params = mz.Params;

const PHI: f64 = (1.0 + @sqrt(5.0)) / 2.0;
const PHI2: f64 = PHI * PHI;
/// inflation factor
const LAMBDA: f64 = PHI2;

pub const TRAPEZOID_A = mz.TYPE_A;
pub const TRAPEZOID_B = mz.TYPE_A + 1;
pub const CLAMSHELL = mz.TYPE_A + 2;

fn unit(deg: f64) Vec2 {
    const a = deg * std.math.pi / 180.0;
    return .{ .x = @cos(a), .y = @sin(a) };
}

inline fn mul(a: Vec2, b: Vec2) Vec2 {
    return .{ .x = a.x * b.x - a.y * b.y, .y = a.x * b.y + a.y * b.x };
}

inline fn conj(a: Vec2) Vec2 {
    return .{ .x = a.x, .y = -a.y };
}

/// distance of the short and the long edge of the trapezoid
const WIDTH: f64 = PHI2 * @cos(std.math.pi / 10.0);

/// The trapezoid in its own frame: short edge on the y axis (centered at
/// the origin), long edge at x = WIDTH.
const TRAPEZOID: [4]Vec2 = .{
    .{ .x = 0, .y = 0.5 },
    .{ .x = 0, .y = -0.5 },
    .{ .x = WIDTH, .y = -PHI2 / 2.0 },
    .{ .x = WIDTH, .y = PHI2 / 2.0 },
};

/// Vertices of the substitution rule in the frame of the parent trapezoid
/// inflated by LAMBDA (children have unit size).
const R = struct {
    const p0: Vec2 = .{ .y = -PHI2 / 2.0 };
    const p1 = p0.add(unit(-54).scale(PHI2));
    const p2 = p1.add(unit(54).scale(PHI2));
    const p3: Vec2 = .{ .x = WIDTH, .y = -0.5 };
    const p4 = p1.add(unit(-18).scale(PHI2));
    const p5 = p4.add(unit(90).scale(PHI2));
    const p6 = p4.add(unit(18).scale(PHI2));
    const p8: Vec2 = .{ .x = 2.0 * WIDTH, .y = -PHI2 / 2.0 };
    const p9 = p6.add(unit(54).scale(PHI2));
    const p10 = p9.add(unit(162).scale(PHI2));
};

/// A child trapezoid: its type and its frame (origin at the middle of the
/// short edge, direction towards the long edge).
const Child = struct {
    type: u8,
    origin: Vec2,
    dir: Vec2,

    fn init(t: u8, short0: Vec2, short1: Vec2, long0: Vec2, long1: Vec2) Child {
        const s = short0.mean(short1);
        const l = long0.mean(long1);
        return .{ .type = t, .origin = s, .dir = l.sub(s).norm() };
    }
};

const A = TRAPEZOID_A;
const B = TRAPEZOID_B;

/// The children common to both rules (above the parent's axis).
fn upper(comptime t0: u8, comptime t5: u8) [5]Child {
    return .{
        // long edge on the parent's short edge, short edges shared ("bow tie")
        Child.init(t0, R.p3, conj(R.p3), R.p0, conj(R.p0)),
        Child.init(t5, R.p3, conj(R.p3), R.p8, conj(R.p8)),
        Child.init(B, R.p2, R.p3, R.p0, R.p1),
        Child.init(A, R.p5, R.p2, R.p1, R.p4),
        Child.init(A, R.p8, R.p5, R.p4, R.p6),
    };
}

const RULE_A: [8]Child = upper(B, A) ++ [3]Child{
    Child.init(B, R.p10, R.p8, R.p6, R.p9),
    Child.init(A, R.p10, conj(R.p10), R.p9, conj(R.p9)),
    Child.init(A, conj(R.p10), conj(R.p8), conj(R.p6), conj(R.p9)),
};
const RULE_B: [5]Child = upper(A, B);

/// The clamshells left between the children.
const SHELL_1: [4]Vec2 = .{ R.p3, R.p2, R.p5, R.p8 };
const SHELL_2: [4]Vec2 = .{ R.p8, R.p10, conj(R.p10), conj(R.p8) };

fn polyArea(p: []const Vec2) f64 {
    var a: f64 = 0;
    for (0..p.len) |i| {
        const q = p[(i + 1) % p.len];
        a += p[i].x * q.y - q.x * p[i].y;
    }
    return a / 2.0;
}

/// There are 1/φ³ clamshells per trapezoid; this edge length (of the short
/// trapezoid edge) makes the mean cell area 1.
const EDGE: f64 = blk: {
    @setEvalBranchQuota(10000);
    const at = @abs(polyArea(&TRAPEZOID));
    const ac = @abs(polyArea(&SHELL_1));
    const f = 1.0 / (PHI2 * PHI);
    break :blk 1.0 / @sqrt((at + ac * f) / (1.0 + f));
};

/// All descendants of a trapezoid of size s lie within REACH·s of the middle
/// of its axis (measured: 2.195).
const REACH: f64 = 2.3;
/// The descendants of a type A trapezoid of size s cover the disc of radius
/// 0.83·s around COVER_CENTER·s (measured); a bit of it is kept as reserve.
const COVER_RADIUS: f64 = 0.75;
const COVER_CENTER: Vec2 = .{ .x = 1.415, .y = -0.796 };

const Tile = struct {
    type: u8,
    origin: Vec2,
    /// unit vector: direction of the axis
    dir: Vec2,
    /// length of the short edge
    size: f64,

    fn point(t: Tile, p: Vec2) Vec2 {
        return t.origin.add(mul(t.dir, p).scale(t.size));
    }
};

fn rectDist(p: Vec2, w: f64, h: f64) f64 {
    const dx = @max(0.0, -p.x, p.x - w);
    const dy = @max(0.0, -p.y, p.y - h);
    return @sqrt(dx * dx + dy * dy);
}

pub fn newClamshellMaze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const tmp = arena_state.allocator();

    const w: f64 = @floatFromInt(params.columns);
    const h: f64 = @floatFromInt(params.rows);
    const half_diag = @sqrt(w * w + h * h) / 2.0;
    const needed = half_diag + 2.0 * EDGE * PHI2;
    var size = EDGE;
    var steps: usize = 0;
    while (COVER_RADIUS * size < needed) : (steps += 1) size *= LAMBDA;

    // a randomly rotated trapezoid, randomly shifted within the slack
    const dir = unit(rand.unit() * 360.0);
    const slack = COVER_RADIUS * size - needed;
    const off = unit(rand.unit() * 360.0).scale(@sqrt(rand.unit()) * slack);
    const mid = Vec2{ .x = w / 2.0, .y = h / 2.0 };
    var tiles: std.ArrayListUnmanaged(Tile) = .empty;
    try tiles.append(tmp, .{
        .type = A,
        .origin = mid.add(off).sub(mul(dir, COVER_CENTER).scale(size)),
        .dir = dir,
        .size = size,
    });

    var shells: std.ArrayListUnmanaged([4]Vec2) = .empty;
    var next: std.ArrayListUnmanaged(Tile) = .empty;
    const margin = 2.0 * EDGE * PHI2;
    for (0..steps) |step| {
        next.clearRetainingCapacity();
        const last = step + 1 == steps;
        for (tiles.items) |t| {
            const s = t.size / LAMBDA;
            const rule: []const Child = if (t.type == A) &RULE_A else &RULE_B;
            for (rule) |ch| {
                const c: Tile = .{
                    .type = ch.type,
                    .origin = t.point(ch.origin.scale(1.0 / LAMBDA)),
                    .dir = mul(t.dir, ch.dir),
                    .size = s,
                };
                const axis_mid = c.point(.{ .x = WIDTH / 2.0 });
                if (rectDist(axis_mid, w, h) > REACH * s + margin) continue;
                try next.append(tmp, c);
            }
            if (last) {
                const shell_rule: []const [4]Vec2 = if (t.type == A) &.{ SHELL_1, SHELL_2 } else &.{SHELL_1};
                for (shell_rule) |sh| {
                    var p: [4]Vec2 = undefined;
                    for (sh, &p) |q, *r| r.* = t.point(q.scale(1.0 / LAMBDA));
                    try shells.append(tmp, p);
                }
            }
        }
        std.mem.swap(std.ArrayListUnmanaged(Tile), &tiles, &next);
    }

    var verts: tiling.PointSet = .{};
    var out: std.ArrayListUnmanaged(tiling.Tile) = .empty;
    const add = struct {
        fn f(a: Allocator, vs: *tiling.PointSet, o: *std.ArrayListUnmanaged(tiling.Tile), t: u8, p: [4]Vec2, ww: f64, hh: f64) !void {
            // area centroid
            const ar = polyArea(&p);
            var ctr = Vec2{};
            for (0..4) |i| {
                const q = p[(i + 1) % 4];
                const cr = p[i].x * q.y - q.x * p[i].y;
                ctr = ctr.add(p[i].add(q).scale(cr));
            }
            ctr = ctr.scale(1.0 / (6.0 * ar));
            if (ctr.x < 0 or ctr.x > ww or ctr.y < 0 or ctr.y > hh) return;
            var ids: [4]u32 = undefined;
            for (p, &ids) |q, *id| id.* = try vs.id(a, q);
            const v = try a.dupe(u32, &ids);
            if (ar < 0) std.mem.reverse(u32, v);
            try o.append(a, .{ .type = t, .verts = v, .center = ctr });
        }
    }.f;
    for (tiles.items) |t| {
        var p: [4]Vec2 = undefined;
        for (TRAPEZOID, &p) |q, *r| r.* = t.point(q);
        try add(tmp, &verts, &out, t.type, p, w, h);
    }
    for (shells.items) |p| try add(tmp, &verts, &out, CLAMSHELL, p, w, h);
    return tiling.buildMaze(gpa, params, rand, verts.points.items, out.items);
}

test "clamshell tiles: trapezoids and clamshells with the right frequencies" {
    const gpa = std.testing.allocator;
    // the substitution matrix has the area factor as eigenvalue
    try std.testing.expectApproxEqAbs(LAMBDA * LAMBDA, (7.0 + @sqrt(45.0)) / 2.0, 1e-12);
    var params: Params = .{ .rows = 30, .columns = 30 };
    var rand = rng.Random.init(7);
    const m = try newClamshellMaze(gpa, &params, &rand);
    defer m.deinit();
    var count: [3]f64 = @splat(0);
    var area: f64 = 0;
    for (m.cells[0..m.n_cells]) |*c| {
        const t = c.type - mz.TYPE_A;
        count[t] += 1;
        try std.testing.expectEqual(@as(usize, 4), c.nWalls());
        // one short and three long edges (trapezoid), three short edges and
        // one long (clamshell)
        var short: usize = 0;
        for (0..4) |i| {
            const l = m.cellWall(c, i).length();
            if (@abs(l - EDGE) < 1e-9) {
                short += 1;
            } else try std.testing.expectApproxEqAbs(EDGE * PHI2, l, 1e-9);
            const wl = m.cellWall(c, i);
            const a = wl.points[0].sub(c.center);
            const b = wl.points[1].sub(c.center);
            area += @abs(a.x * b.y - a.y * b.x) / 2;
        }
        try std.testing.expectEqual(@as(usize, if (t == 2) 3 else 1), short);
    }
    // A : B = φ : 1, clamshells : trapezoids = 1 : φ³
    try std.testing.expectApproxEqAbs(PHI, count[0] / count[1], 0.12);
    try std.testing.expectApproxEqAbs(1.0 / (PHI2 * PHI), count[2] / (count[0] + count[1]), 0.03);
    const n = count[0] + count[1] + count[2];
    try std.testing.expectApproxEqAbs(@as(f64, 1), area / n, 0.03);
    try std.testing.expect(n > 800 and n < 1000);
}

test "clamshell substitution leaves no holes" {
    // walls without a neighbour cell are only found at the border of the
    // maze rectangle, never inside (a hole between the tiles)
    const gpa = std.testing.allocator;
    for (1..6) |seed| {
        var params: Params = .{ .rows = 20, .columns = 25 };
        var rand = rng.Random.init(@intCast(seed));
        const m = try newClamshellMaze(gpa, &params, &rand);
        defer m.deinit();
        for (m.walls[0..m.n_walls]) |*wl| {
            if (wl.cells[1] != m.off and wl.cells[0] != m.off) continue;
            const p = wl.points[0].mean(wl.points[1]);
            const d = @min(p.x, p.y, 25.0 - p.x, 20.0 - p.y);
            try std.testing.expect(d < 2.0 * EDGE * PHI2);
        }
    }
}
