//! Aperiodic mazes based on the Ammann–Beenker tiling (squares and 45°
//! rhombi with eightfold rotational symmetry).
//!
//! The tiling is generated with de Bruijn's multigrid method (see
//! multigrid.zig) from four line families at multiples of 45°: crossings of
//! perpendicular lines give squares, all other crossings 45° rhombi. Random
//! line offsets select a random part of the (infinite, non-repeating) tiling.

const std = @import("std");
const mz = @import("maze.zig");
const rng = @import("rng.zig");
const multigrid = @import("multigrid.zig");

const Allocator = std.mem.Allocator;
const Maze = mz.Maze;
const Params = mz.Params;

/// In the tiling there are √2 rhombi (area √½) per square (area 1), so the
/// mean tile area is 2 / (1 + √2) for unit edges. This edge length makes the
/// mean tile about as large as a unit square.
const EDGE: f64 = @sqrt((1.0 + std.math.sqrt2) / 2.0);

/// Crossings of perpendicular lines give squares, all others 45° rhombi.
fn tileType(j: usize, k: usize) u8 {
    return if (k - j == 2) mz.TYPE_A else mz.TYPE_A + 1;
}

pub fn newAmmannBeenkerMaze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var g: multigrid.Grid = .{ .n = 4, .step = std.math.pi / 4.0, .gamma = undefined, .edge = EDGE, .tileType = tileType };
    for (g.gamma[0..4]) |*x| x.* = rand.unit();
    return multigrid.newMultigridMaze(gpa, params, rand, g);
}

test "ammann-beenker tiles are unit squares and 45 degree rhombi" {
    const gpa = std.testing.allocator;
    var params: Params = .{ .rows = 30, .columns = 30 };
    var rand = rng.Random.init(5);
    const m = try newAmmannBeenkerMaze(gpa, &params, &rand);
    defer m.deinit();
    var squares: f64 = 0;
    var rhombi: f64 = 0;
    for (m.cells[0..m.n_cells]) |*c| {
        try std.testing.expectEqual(@as(usize, 4), c.nWalls());
        if (c.type == mz.TYPE_A) squares += 1 else rhombi += 1;
        for (0..4) |i| try std.testing.expectApproxEqAbs(EDGE, m.cellWall(c, i).length(), 1e-9);
    }
    // √2 rhombi per square
    try std.testing.expect(@abs(rhombi / squares - std.math.sqrt2) < 0.15);
    try std.testing.expect(m.n_cells > 800 and m.n_cells < 1000);
}
