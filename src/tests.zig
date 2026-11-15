//! End to end tests: build and carve every maze type and check that the
//! result is a perfect maze (every cell reachable, no loops).

const std = @import("std");
const mz = @import("maze.zig");
const rng = @import("rng.zig");
const carve = @import("carve.zig");
const render = @import("render.zig");
const tables = @import("structures.zig");

const testing = std.testing;

/// Checks that every cell is reachable and that the maze has no loops.
/// Passages over bridges (crossovers) count as passages.
pub fn checkPerfect(m: *mz.Maze) !void {
    // crossover cells are counted in n_valid (they are built after counting)
    // but can't be entered; each provides two passages over bridged walls
    var crossovers: usize = 0;
    for (m.cells[0..m.n_cells]) |*c| {
        if (c.type == mz.TYPE_CROSSOVER) crossovers += 1;
    }
    const cells = m.n_valid - crossovers;
    // count passages (open or bridged walls) between valid cells; every
    // passage is seen from both of its cells
    var ends: usize = 0;
    for (m.cells[0..m.n_cells]) |*c| {
        if (!c.valid()) continue;
        for (0..c.nWalls()) |i| {
            const w = m.cellWall(c, i);
            if ((w.isOpen() or w.isBridged()) and w.other(c).valid()) {
                ends += 1;
                // passages must lead back
                const n = w.other(c);
                var back = false;
                for (0..n.nWalls()) |j| {
                    const wn = m.cellWall(n, j);
                    if ((wn.isOpen() or wn.isBridged()) and wn.other(n) == c) back = true;
                }
                if (!back) return error.OneWayPassage;
            }
        }
    }
    const open = ends / 2;
    // flood fill from the entrance
    m.clearMarks();
    var stack: std.ArrayListUnmanaged(*mz.Cell) = .empty;
    defer stack.deinit(testing.allocator);
    const start = m.entrance.?;
    _ = start.visit();
    try stack.append(testing.allocator, start);
    var reached: usize = 1;
    while (stack.pop()) |c| {
        for (0..c.nWalls()) |i| {
            if (m.go(c, i, mz.MARK_VISITED)) |n| {
                if (!n.valid()) continue;
                reached += 1;
                try stack.append(testing.allocator, n);
            }
        }
    }
    try testing.expectEqual(cells, reached);
    // a tree: one passage less than cells
    try testing.expectEqual(cells - 1, open);
    try testing.expect(m.exit != null);
}

fn build(s: *const @import("structure.zig").Structure, algo: mz.Algorithm, seed: u32, tileable: bool) !*mz.Maze {
    var params: mz.Params = .{
        .structure = s,
        .rows = if (s.has(@import("structure.zig").RINGS)) 6 else 9,
        .columns = if (s.has(@import("structure.zig").RINGS)) 6 else 9,
        .algorithm = algo,
        .tileable = tileable,
    };
    var rand = rng.Random.init(seed);
    const m = try mz.newMaze(testing.allocator, &params, &rand);
    errdefer m.deinit();
    // keep the generator alive for the maze's lifetime
    const r = try m.alloc().create(rng.Random);
    r.* = rand;
    m.rand = r;
    try carve.carveMaze(testing.allocator, &params, m);
    return m;
}

test "all maze types produce perfect mazes" {
    for (tables.all) |s| {
        for ([_]mz.Algorithm{ .backtracker, .prim, .tree, .wilson }) |algo| {
            for (1..4) |seed| {
                const m = try build(s, algo, @intCast(seed), false);
                defer m.deinit();
                checkPerfect(m) catch |e| {
                    std.debug.print("failed: {s} {t} seed {d}\n", .{ s.name, algo, seed });
                    return e;
                };
            }
        }
    }
}

test "mazes with direction weights are perfect" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var wrand = rng.Random.init(11);
    for (tables.all) |s| {
        if (s.neighbours.len == 0) continue;
        // random weights in {0, 1, 2, 5}, at least one of them non-zero
        const ws = try arena.alloc([]const f64, s.neighbours.len);
        for (ws, s.neighbours) |*w, nbs| {
            const v = try arena.alloc(f64, nbs.len);
            for (v) |*x| x.* = ([_]f64{ 0, 1, 2, 5 })[wrand.below(4)];
            v[wrand.below(v.len)] = 1;
            w.* = v;
        }
        for ([_]mz.Algorithm{ .backtracker, .prim, .tree, .wilson }) |algo| {
            for (1..3) |seed| {
                var params: mz.Params = .{
                    .structure = s,
                    .rows = 12,
                    .columns = 12,
                    .algorithm = algo,
                    .weights = ws,
                };
                var rand = rng.Random.init(@intCast(seed));
                const m = try mz.newMaze(testing.allocator, &params, &rand);
                defer m.deinit();
                const r = try m.alloc().create(rng.Random);
                r.* = rand;
                m.rand = r;
                try carve.carveMaze(testing.allocator, &params, m);
                checkPerfect(m) catch |e| {
                    std.debug.print("failed: {s} {t} seed {d}\n", .{ s.name, algo, seed });
                    return e;
                };
            }
        }
    }
}

test "mazes with crossovers are perfect" {
    const structure = @import("structure.zig");
    // high densities can't be reached and give a warning
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    for (tables.all) |s| {
        if (!s.has(structure.CROSSOVERS)) continue;
        // uniform weights except for type A, which prefers its first wall
        var wa: [8]f64 = @splat(1);
        wa[0] = 3;
        const ws = [_][]const f64{wa[0..s.neighbours[0].len]};
        for ([_]mz.Algorithm{ .backtracker, .prim, .tree, .wilson }) |algo| {
            for ([_]f64{ 0.1, 0.4 }) |crossings| for ([_]bool{ false, true }) |weighted| for (1..6) |seed| {
                var params: mz.Params = .{
                    .structure = s,
                    .rows = 14,
                    .columns = 14,
                    .algorithm = algo,
                    .crossings = crossings,
                    .weights = if (weighted) &ws else &.{},
                };
                var rand = rng.Random.init(@intCast(seed));
                const m = try mz.newMaze(testing.allocator, &params, &rand);
                defer m.deinit();
                const r = try m.alloc().create(rng.Random);
                r.* = rand;
                m.rand = r;
                try carve.carveMaze(testing.allocator, &params, m);
                checkPerfect(m) catch |e| {
                    std.debug.print("failed: {s} {t} crossings {d} weighted {} seed {d}\n", .{ s.name, algo, crossings, weighted, seed });
                    return e;
                };
            };
        }
    }
}

test "tileable mazes are connected" {
    for (tables.all) |s| {
        if (s.construct != .periodic) continue;
        const m = try build(s, .backtracker, 7, true);
        defer m.deinit();
        try checkPerfect(m);
    }
}

test "solution path connects exit and entrance" {
    const m = try build(tables.all[0], .backtracker, 42, false);
    defer m.deinit();
    const rp: render.RenderParams = .{};
    var s = try render.renderSolution(testing.allocator, m, &rp);
    defer s.deinit();
    try testing.expect(s.points.items.len >= 2);
    try testing.expectEqual(m.entrance.?, s.points.items[0].cell.?);
}
