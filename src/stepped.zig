//! Aperiodic mazes on the dual tiling of the substitution a -> ab, b -> c,
//! c -> a (Tilings Encyclopedia: "A->AB, B->C, C->A (dual)"), made of three
//! parallelograms.
//!
//! The substitution matrix has the characteristic polynomial x³ = x² + 1;
//! its largest root is the supergolden ratio ψ ≈ 1.4656. The dual tiling
//! (Arnoux–Ito) is the stepped plane with normal v = (ψ, 1/ψ, 1), the
//! Perron eigenvector of the transposed matrix: the faces
//!
//!     x + [0,1]·e_j + [0,1]·e_k   with   0 ≤ ⟨x, v⟩ + ρ < v_i
//!
//! of the unit cubes of Z³ (x ∈ Z³, {i, j, k} = {0, 1, 2}), i.e. the upper
//! boundary of all cubes below the plane ⟨x, v⟩ + ρ = 0, projected
//! orthogonally onto the plane. Face type i becomes cell type A + i. The
//! offset ρ selects a random part of the tiling; vertices are identified by
//! their integer coordinates, so neighbouring tiles share them exactly.

const std = @import("std");
const geo = @import("geo.zig");
const mz = @import("maze.zig");
const rng = @import("rng.zig");
const tiling = @import("tiling.zig");

const Allocator = std.mem.Allocator;
const Vec2 = geo.Vec2;
const Maze = mz.Maze;
const Params = mz.Params;

const V3 = [3]f64;

/// The real root of x³ = x² + 1.
pub const PSI: f64 = blk: {
    @setEvalBranchQuota(10000);
    var x: f64 = 1.5;
    for (0..60) |_| x -= (x * x * x - x * x - 1) / (3 * x * x - 2 * x);
    break :blk x;
};

/// Normal of the stepped plane.
const NORMAL: V3 = .{ PSI, 1.0 / PSI, 1.0 };

inline fn dot(a: V3, b: V3) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn normalize(a: V3) V3 {
    const l = @sqrt(dot(a, a));
    return .{ a[0] / l, a[1] / l, a[2] / l };
}

fn cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

pub fn newSupergoldenMaze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const tmp = arena_state.allocator();

    const v = NORMAL;
    const vsum = v[0] + v[1] + v[2];
    const n = normalize(v);
    // in-plane axes: y along the projection of e_2 (drawn downwards), x
    // perpendicular to it
    const e2n = n[2];
    const uy = normalize(.{ -e2n * n[0], -e2n * n[1], 1.0 - e2n * n[2] });
    const ux = cross(n, uy); // narrow faces right of the large ones, as in the encyclopedia
    // face i projects to a parallelogram of area v_i / |v|, the faces of type
    // i have a density proportional to v_i: the mean tile area is |v| / Σv.
    // Scale it to 1.
    const scale = @sqrt(vsum / @sqrt(dot(v, v)));
    const rho = rand.unit() * vsum;

    const w: f64 = @floatFromInt(params.columns);
    const h: f64 = @floatFromInt(params.rows);
    // integer range of the faces near the maze rectangle: the lifted
    // rectangle corners plus the distance of the faces from the plane
    var lo: [3]i64 = undefined;
    var hi: [3]i64 = undefined;
    for (0..3) |c| {
        var mn = std.math.inf(f64);
        var mx = -std.math.inf(f64);
        for ([_][2]f64{ .{ 0, 0 }, .{ w, 0 }, .{ 0, h }, .{ w, h } }) |p| {
            const x = (p[0] * ux[c] + p[1] * uy[c]) / scale;
            mn = @min(mn, x);
            mx = @max(mx, x);
        }
        const margin = 3.0 + (vsum + rho) / @sqrt(dot(v, v));
        lo[c] = @intFromFloat(@floor(mn - margin));
        hi[c] = @intFromFloat(@ceil(mx + margin));
    }

    var vert_ids: std.AutoHashMapUnmanaged([3]i64, u32) = .empty;
    var points: std.ArrayListUnmanaged(Vec2) = .empty;
    var tiles: std.ArrayListUnmanaged(tiling.Tile) = .empty;

    for (0..3) |i| {
        const j = (i + 1) % 3;
        const k = (i + 2) % 3;
        var xj = lo[j];
        while (xj <= hi[j]) : (xj += 1) {
            var xk = lo[k];
            while (xk <= hi[k]) : (xk += 1) {
                // the unique x_i with 0 <= <x,v> + rho < v_i
                const s = @as(f64, @floatFromInt(xj)) * v[j] + @as(f64, @floatFromInt(xk)) * v[k] + rho;
                const xi: i64 = @intFromFloat(@ceil(-s / v[i]));
                var x: [3]i64 = undefined;
                x[i] = xi;
                x[j] = xj;
                x[k] = xk;
                var corners: [4][3]i64 = .{ x, x, x, x };
                corners[1][j] += 1;
                corners[2][j] += 1;
                corners[2][k] += 1;
                corners[3][k] += 1;
                var pos: [4]Vec2 = undefined;
                for (corners, &pos) |c, *p| {
                    const f: V3 = .{ @floatFromInt(c[0]), @floatFromInt(c[1]), @floatFromInt(c[2]) };
                    p.* = .{ .x = dot(f, ux) * scale, .y = dot(f, uy) * scale };
                }
                const ctr = pos[0].mean(pos[2]);
                if (ctr.x < 0 or ctr.x > w or ctr.y < 0 or ctr.y > h) continue;
                var ids: [4]u32 = undefined;
                for (corners, pos, &ids) |c, p, *id| {
                    const gop = try vert_ids.getOrPut(tmp, c);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = @intCast(points.items.len);
                        try points.append(tmp, p);
                    }
                    id.* = gop.value_ptr.*;
                }
                const vs = try tmp.dupe(u32, &ids);
                // counter clockwise
                const a = pos[1].sub(pos[0]);
                const b = pos[3].sub(pos[0]);
                if (a.x * b.y - a.y * b.x < 0) std.mem.reverse(u32, vs);
                try tiles.append(tmp, .{ .type = mz.TYPE_A + @as(u8, @intCast(i)), .verts = vs, .center = ctr });
            }
        }
    }
    return tiling.buildMaze(gpa, params, rand, points.items, tiles.items);
}

test "supergolden tiles are parallelograms with the right frequencies" {
    const gpa = std.testing.allocator;
    try std.testing.expectApproxEqAbs(@as(f64, 0), PSI * PSI * PSI - PSI * PSI - 1, 1e-12);
    var params: Params = .{ .rows = 40, .columns = 40 };
    var rand = rng.Random.init(3);
    const m = try newSupergoldenMaze(gpa, &params, &rand);
    defer m.deinit();
    var count: [3]f64 = @splat(0);
    var area: f64 = 0;
    for (m.cells[0..m.n_cells]) |*c| {
        try std.testing.expectEqual(@as(usize, 4), c.nWalls());
        count[c.type - mz.TYPE_A] += 1;
        // opposite walls have the same length
        for (0..2) |e| {
            try std.testing.expectApproxEqAbs(m.cellWall(c, e).length(), m.cellWall(c, e + 2).length(), 1e-9);
        }
        const a = m.cellWall(c, 0).points[1].sub(m.cellWall(c, 0).points[0]);
        const b = m.cellWall(c, 1).points[1].sub(m.cellWall(c, 1).points[0]);
        area += @abs(a.x * b.y - a.y * b.x);
    }
    // frequencies proportional to the normal (ψ, 1/ψ, 1), mean area 1
    try std.testing.expectApproxEqAbs(PSI, count[0] / count[2], 0.1);
    try std.testing.expectApproxEqAbs(1.0 / PSI, count[1] / count[2], 0.1);
    const n = count[0] + count[1] + count[2];
    try std.testing.expectApproxEqAbs(@as(f64, 1), area / n, 0.02);
    try std.testing.expect(n > 1450 and n < 1750);
}
