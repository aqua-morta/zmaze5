//! Aperiodic mazes based on the Socolar tiling (regular hexagons, squares
//! and 30° rhombi with twelvefold rotational symmetry).
//!
//! The tiling is generated with de Bruijn's dual method (see multigrid.zig)
//! from six line families at multiples of 30° that form two triangular
//! grids: the families at 0°, 60°, 120° (A) and at 30°, 90°, 150° (B) are
//! each concurrent, i.e. their offsets satisfy γ₀ − γ₂ + γ₄ ∈ ℤ and
//! γ₁ − γ₃ + γ₅ ∈ ℤ (because e₆₀ = e₀ + e₁₂₀ and e₉₀ = e₃₀ + e₁₅₀). Every
//! triple point of a grid becomes a regular hexagon, every crossing of an
//! A line with a B line a square (perpendicular lines) or a 30° rhombus.
//! The result has the tiles, the local structure and the tile frequencies of
//! Socolar's tiling (hexagons : squares : rhombi = √3 : 3 : 3, hexagons never
//! share an edge). Random offsets select a random part of the tiling.

const std = @import("std");
const mz = @import("maze.zig");
const rng = @import("rng.zig");
const multigrid = @import("multigrid.zig");

const Allocator = std.mem.Allocator;
const Maze = mz.Maze;
const Params = mz.Params;

/// Per unit area of the grid there are √3 triple points (hexagons, area
/// 3√3/2), 3 squares (area 1) and 3 rhombi (area 1/2) for unit edges: the
/// mean tile area is 9 / (6 + √3). This edge length makes it 1.
const EDGE: f64 = @sqrt((6.0 + @sqrt(3.0)) / 9.0);

pub const HEXAGON = mz.TYPE_A;
pub const SQUARE = mz.TYPE_A + 1;
pub const RHOMB = mz.TYPE_A + 2;

/// Crossings of an A and a B line: perpendicular ones give squares, the
/// others 30° rhombi (crossings within a group are triple points).
fn tileType(j: usize, k: usize) u8 {
    return if (k - j == 3) SQUARE else RHOMB;
}

pub fn newSocolarMaze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var g: multigrid.Grid = .{
        .n = 6,
        .step = std.math.pi / 6.0,
        .gamma = undefined,
        .edge = EDGE,
        .tileType = tileType,
        .triples = &.{ .{ 0, 2, 4 }, .{ 1, 3, 5 } },
        .hex_type = HEXAGON,
    };
    for (g.gamma[0..4]) |*x| x.* = rand.unit();
    g.gamma[4] = g.gamma[2] - g.gamma[0];
    g.gamma[5] = g.gamma[3] - g.gamma[1];
    return multigrid.newMultigridMaze(gpa, params, rand, g);
}

test "socolar tiles are regular hexagons, squares and 30 degree rhombi" {
    const gpa = std.testing.allocator;
    var params: Params = .{ .rows = 30, .columns = 30 };
    var rand = rng.Random.init(5);
    const m = try newSocolarMaze(gpa, &params, &rand);
    defer m.deinit();
    var count: [3]f64 = @splat(0);
    var area: f64 = 0;
    for (m.cells[0..m.n_cells]) |*c| {
        const t = c.type - mz.TYPE_A;
        count[t] += 1;
        try std.testing.expectEqual(@as(usize, if (t == 0) 6 else 4), c.nWalls());
        for (0..c.nWalls()) |i| try std.testing.expectApproxEqAbs(EDGE, m.cellWall(c, i).length(), 1e-9);
        // area from the center (all tiles are convex)
        for (0..c.nWalls()) |i| {
            const w = m.cellWall(c, i);
            const a = w.points[0].sub(c.center);
            const b = w.points[1].sub(c.center);
            area += @abs(a.x * b.y - a.y * b.x) / 2;
        }
        // hexagons never share an edge
        if (t == 0) {
            for (0..6) |i| try std.testing.expect(m.neighbour(c, i).type != HEXAGON);
        }
    }
    // hexagons : squares : rhombi = √3 : 3 : 3
    try std.testing.expectApproxEqAbs(@sqrt(3.0) / 3.0, count[0] / count[1], 0.08);
    try std.testing.expectApproxEqAbs(@as(f64, 1), count[2] / count[1], 0.08);
    const n = count[0] + count[1] + count[2];
    try std.testing.expectApproxEqAbs(@as(f64, 1), area / n, 0.03);
    try std.testing.expect(n > 800 and n < 1000);
}
