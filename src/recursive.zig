//! Recursive mazes (`--recursion=LEVELS`) on squares, triangles and
//! hexagons: a base maze with n cells along a side is carved first. Then,
//! LEVELS times, every cell of the maze is replaced by a copy of the base
//! maze (turned as `--recursion-orientation` asks for), and every passage
//! between two cells becomes one opening on the side their copies share
//! (placed as `--recursion-opening` asks for). Since every copy is a tree
//! and the copies are connected along the passages of a tree, the result is
//! a perfect maze again.
//!
//! Squares: the base maze is a square of n x n cells; the copy for the cell
//! c goes to n·c.
//!
//! Triangles: the base maze is a triangle of n x n cells (n cells along a
//! side). Every cell is replaced by a copy of it; downward pointing cells
//! hold the copy turned upside down.
//!
//! Hexagons can't be divided into hexagons. The base maze is a hexagon of
//! hexagons (n cells along a side, radius k = n - 1); such hexagons tile the
//! plane with their centers on the hexagonal lattice multiplied by
//! μ = (k + 1) + k·ω (an Eisenstein integer: a rotation and a scaling by
//! √(3k² + 3k + 1)). The copy for the cell c goes to μ·c, so the copies of
//! neighbouring cells are neighbours again. The outline becomes a turned,
//! snowflake like figure.
//!
//! Cells are identified by integer coordinates: squares by their column and
//! row (as drawn, the row downwards), triangles by three times their
//! centroid in the lattice basis e1, e2 (60° apart), hexagons by axial
//! coordinates. The final cells are built with tiling.zig.

const std = @import("std");
const geo = @import("geo.zig");
const mz = @import("maze.zig");
const rng = @import("rng.zig");
const carve = @import("carve.zig");
const tiling = @import("tiling.zig");
const tables = @import("structures.zig");
const Structure = @import("structure.zig").Structure;

const Allocator = std.mem.Allocator;
const Vec2 = geo.Vec2;
const Maze = mz.Maze;
const Params = mz.Params;

pub const Coord = [2]i64;

/// The structures recursive mazes can be made of.
pub const Kind = enum {
    square,
    triangle,
    hexagon,

    pub fn of(s: *const Structure) ?Kind {
        if (s == tables.ortho[0]) return .square;
        if (s == tables.tria[0]) return .triangle;
        if (s == tables.hexa[0]) return .hexagon;
        return null;
    }

    /// Cells of the base maze for `n` cells along a side.
    pub fn baseCells(k: Kind, n: u64) u64 {
        return switch (k) {
            .square, .triangle => n * n,
            .hexagon => 3 * n * n - 3 * n + 1,
        };
    }

    /// Rotations (clockwise as drawn) of the base maze; there are as many
    /// reflections.
    fn rotations(k: Kind) usize {
        return switch (k) {
            .square => 4,
            .triangle => 3,
            .hexagon => 6,
        };
    }
};

/// Number of cells of the whole maze, null if it gets too large.
pub fn cellCount(k: Kind, n: u64, levels: u32) ?u64 {
    const b = k.baseCells(n);
    var c: u64 = b;
    for (0..levels) |_| c = std.math.mul(u64, c, b) catch return null;
    return c;
}

// ---------------------------------------------------------------------------
// lattices

const S3 = @sqrt(3.0);

/// Squares at (x, y), y downwards as drawn; the base maze is the square
/// 0 <= x, y < n.
const Sq = struct {
    fn base(arena: Allocator, n: i64) ![]Coord {
        const cells = try arena.alloc(Coord, @intCast(n * n));
        for (cells, 0..) |*c, i| c.* = .{ @mod(@as(i64, @intCast(i)), n), @divTrunc(@as(i64, @intCast(i)), n) };
        return cells;
    }

    fn neighbours(c: Coord) [4]Coord {
        return .{ .{ c[0] + 1, c[1] }, .{ c[0], c[1] + 1 }, .{ c[0] - 1, c[1] }, .{ c[0], c[1] - 1 } };
    }

    fn place(c: Coord, d: Coord, n: i64) Coord {
        return .{ n * c[0] + d[0], n * c[1] + d[1] };
    }

    /// Symmetry t of the base square: t % 4 clockwise quarter turns (as
    /// drawn), mirrored first (left and right exchanged) for t >= 4.
    fn sym(d: Coord, t: usize, n: i64) Coord {
        var r = if (t >= 4) Coord{ n - 1 - d[0], d[1] } else d;
        for (0..t % 4) |_| {
            // via a copy: r = .{ ..., r[0] } would read the new r[0]
            const q = r;
            r = .{ n - 1 - q[1], q[0] };
        }
        return r;
    }

    /// The side of a square of side s (0: bottom, 1: left, 2: top, 3:
    /// right, the clockwise quarter turns that face the base maze's bottom
    /// towards it) the cell is nearest to; ties as described at `pickSide`.
    fn side(c: Coord, s: i64, spiral: bool) usize {
        const dist = [4]i64{ s - 1 - c[1], c[0], c[1], s - 1 - c[0] };
        return pickSide(&dist, &.{ 1, 2, 3, 0 }, spiral);
    }

    fn center(c: Coord) Vec2 {
        return .{ .x = @as(f64, @floatFromInt(c[0])) + 0.5, .y = @as(f64, @floatFromInt(c[1])) + 0.5 };
    }
};

/// The triangle with the corners (0, 0), (n, 0), (0, n) of the lattice.
const Tri = struct {
    fn up(c: Coord) bool {
        return @mod(c[0], 3) == 1;
    }

    /// The lattice point (a, b) the cell hangs at: the corner of an upward
    /// cell with the right angle in lattice coordinates, the opposite corner
    /// of a downward one.
    fn anchor(c: Coord) Coord {
        return if (up(c)) .{ @divExact(c[0] - 1, 3), @divExact(c[1] - 1, 3) } else .{ @divExact(c[0] - 2, 3) + 1, @divExact(c[1] - 2, 3) + 1 };
    }

    fn base(arena: Allocator, n: i64) ![]Coord {
        var cells: std.ArrayListUnmanaged(Coord) = .empty;
        // from the bottom row up, left to right
        var b: i64 = 0;
        while (b < n) : (b += 1) {
            var a: i64 = 0;
            while (a + b < n) : (a += 1) {
                try cells.append(arena, .{ 3 * a + 1, 3 * b + 1 });
                if (a + b + 1 < n) try cells.append(arena, .{ 3 * a + 2, 3 * b + 2 });
            }
        }
        return cells.items;
    }

    fn neighbours(c: Coord) [3]Coord {
        const s: i64 = if (up(c)) 1 else -1;
        return .{ .{ c[0] + s, c[1] + s }, .{ c[0] - 2 * s, c[1] + s }, .{ c[0] + s, c[1] - 2 * s } };
    }

    /// The cell `d` of a base maze of side n placed into cell c.
    fn place(c: Coord, d: Coord, n: i64) Coord {
        const p = anchor(c);
        return if (up(c)) .{ 3 * n * p[0] + d[0], 3 * n * p[1] + d[1] } else .{ 3 * n * p[0] - d[0], 3 * n * p[1] - d[1] };
    }

    /// Symmetry t of the base triangle: t % 3 clockwise turns (as drawn),
    /// reflected first (a and b exchanged) for t >= 3.
    fn sym(d: Coord, t: usize, n: i64) Coord {
        var r = if (t >= 3) Coord{ d[1], d[0] } else d;
        for (0..t % 3) |_| {
            const q = r;
            // the corner (0, n) at the top goes to (n, 0), (n, 0) to (0, 0)
            r = .{ q[1], 3 * n - q[0] - q[1] };
        }
        return r;
    }

    /// The side of a triangle of side s (0: bottom, 1: left, 2: right, the
    /// clockwise turns that face the base maze's bottom towards it) the cell
    /// is nearest to; ties as described at `pickSide`.
    fn side(c: Coord, s: i64, spiral: bool) usize {
        // distances (times 3) to the bottom (b = 0), the left (a = 0) and
        // the right side (a + b = s)
        const dist = [3]i64{ c[1], c[0], 3 * s - c[0] - c[1] };
        return pickSide(&dist, &.{ 1, 2, 0 }, spiral);
    }

    fn corners(c: Coord) [3]Coord {
        const p = anchor(c);
        return if (up(c))
            .{ p, .{ p[0] + 1, p[1] }, .{ p[0], p[1] + 1 } }
        else
            .{ p, .{ p[0] - 1, p[1] }, .{ p[0], p[1] - 1 } };
    }

    fn point(p: Coord) Vec2 {
        const a: f64 = @floatFromInt(p[0]);
        const b: f64 = @floatFromInt(p[1]);
        // y down: the triangle points up
        return .{ .x = a + b / 2.0, .y = -b * S3 / 2.0 };
    }
};

/// Hexagons in axial coordinates: q along e1 = (1, 0), r along e2 at 60°
/// (downwards as drawn); the neighbours are the units of the Eisenstein
/// integers.
const Hex = struct {
    const units = [6]Coord{ .{ 1, 0 }, .{ 0, 1 }, .{ -1, 1 }, .{ -1, 0 }, .{ 0, -1 }, .{ 1, -1 } };

    fn mul(a: Coord, b: Coord) Coord {
        // (a0 + a1 ω)(b0 + b1 ω) with ω² = ω - 1
        return .{ a[0] * b[0] - a[1] * b[1], a[0] * b[1] + a[1] * b[0] + a[1] * b[1] };
    }

    fn dist(c: Coord) i64 {
        return @intCast(@max(@max(@abs(c[0]), @abs(c[1])), @abs(c[0] + c[1])));
    }

    fn base(arena: Allocator, n: i64) ![]Coord {
        var cells: std.ArrayListUnmanaged(Coord) = .empty;
        const k = n - 1;
        var r: i64 = -k;
        while (r <= k) : (r += 1) {
            var q: i64 = -k;
            while (q <= k) : (q += 1) {
                if (dist(.{ q, r }) <= k) try cells.append(arena, .{ q, r });
            }
        }
        return cells.items;
    }

    fn neighbours(c: Coord) [6]Coord {
        var res: [6]Coord = undefined;
        for (units, &res) |u, *r| r.* = .{ c[0] + u[0], c[1] + u[1] };
        return res;
    }

    fn place(c: Coord, d: Coord, n: i64) Coord {
        const p = mul(.{ n, n - 1 }, c);
        return .{ p[0] + d[0], p[1] + d[1] };
    }

    /// Symmetry t of the hexagon: t % 6 clockwise turns by 60° (as drawn),
    /// reflected first (q and r exchanged) for t >= 6.
    fn sym(d: Coord, t: usize) Coord {
        var r = if (t >= 6) Coord{ d[1], d[0] } else d;
        for (0..t % 6) |_| r = mul(.{ 0, 1 }, r);
        return r;
    }

    /// The side of its ring around the center the cell lies on (0: bottom,
    /// then clockwise as drawn: lower left, upper left, top, upper right,
    /// lower right); ties as described at `pickSide`.
    fn side(c: Coord, spiral: bool) usize {
        const d = dist(c);
        if (d == 0) return 0;
        // the side is the one whose coordinate reaches ±d; as distances:
        // d minus the coordinate in the side's direction
        const q = c[0];
        const r = c[1];
        const s = -q - r;
        const dists = [6]i64{ d - r, d + q, d - s, d + r, d - q, d + s };
        return pickSide(&dists, &.{ 1, 2, 3, 4, 5, 0 }, spiral);
    }

    fn center(c: Coord) Vec2 {
        const q: f64 = @floatFromInt(c[0]);
        const r: f64 = @floatFromInt(c[1]);
        return .{ .x = q + r / 2.0, .y = r * S3 / 2.0 };
    }
};

/// The side with the smallest distance. Ties: `order` lists the sides in
/// clockwise order (as drawn) starting with the one the spiral begins with
/// (at the lower left corner, going up). The spiral gives a corner to the
/// side it arrives on, the earlier one in `order`; the sectors give it to
/// the side clockwise after it (the same rule for every side). A cell at
/// equal distance to all sides belongs to side 0 (the bottom).
fn pickSide(dist: []const i64, order: []const usize, spiral: bool) usize {
    var best: i64 = std.math.maxInt(i64);
    for (dist) |d| best = @min(best, d);
    var count: usize = 0;
    for (dist) |d| count += @intFromBool(d == best);
    if (count == dist.len) return 0;
    if (spiral) {
        for (order) |s| if (dist[s] == best) return s;
        unreachable;
    }
    // the last nearest side of a run of nearest sides (cyclic)
    const m = order.len;
    for (0..m) |i| {
        const s = order[i];
        if (dist[s] == best and dist[order[(i + 1) % m]] != best) return s;
    }
    unreachable;
}

// ---------------------------------------------------------------------------
// levels

/// The cells of one level of the construction and the passages between
/// them (indices into `cells`).
const Level = struct {
    cells: []Coord,
    passages: [][2]u32,
};

const Geometry = struct {
    kind: Kind,
    n: i64,
    base: []Coord,

    fn neighbours(g: Geometry, c: Coord, buf: *[6]Coord) []Coord {
        switch (g.kind) {
            .square => {
                const nb = Sq.neighbours(c);
                @memcpy(buf[0..4], &nb);
                return buf[0..4];
            },
            .triangle => {
                const nb = Tri.neighbours(c);
                @memcpy(buf[0..3], &nb);
                return buf[0..3];
            },
            .hexagon => {
                buf.* = Hex.neighbours(c);
                return buf[0..6];
            },
        }
    }

    fn place(g: Geometry, c: Coord, d: Coord) Coord {
        return switch (g.kind) {
            .square => Sq.place(c, d, g.n),
            .triangle => Tri.place(c, d, g.n),
            .hexagon => Hex.place(c, d, g.n),
        };
    }

    fn sym(g: Geometry, d: Coord, t: usize) Coord {
        return switch (g.kind) {
            .square => Sq.sym(d, t, g.n),
            .triangle => Tri.sym(d, t, g.n),
            .hexagon => Hex.sym(d, t),
        };
    }

    /// The side (as a number of clockwise turns) of cell c of a level whose
    /// square or triangle has `side_len` cells along a side.
    fn side(g: Geometry, c: Coord, side_len: i64, spiral: bool) usize {
        return switch (g.kind) {
            .square => Sq.side(c, side_len, spiral),
            .triangle => Tri.side(c, side_len, spiral),
            .hexagon => Hex.side(c, spiral),
        };
    }

    fn center(g: Geometry, c: Coord) Vec2 {
        return switch (g.kind) {
            .square => Sq.center(c),
            .triangle => blk: {
                const cs = Tri.corners(c);
                const p = Tri.point(cs[0]).add(Tri.point(cs[1])).add(Tri.point(cs[2]));
                break :blk p.scale(1.0 / 3.0);
            },
            .hexagon => Hex.center(c),
        };
    }

    /// The corners of cell c, counter clockwise as drawn.
    fn polygon(g: Geometry, c: Coord, buf: *[6]Vec2) []Vec2 {
        switch (g.kind) {
            .square => {
                const ctr = Sq.center(c);
                for ([_][2]f64{ .{ -0.5, -0.5 }, .{ 0.5, -0.5 }, .{ 0.5, 0.5 }, .{ -0.5, 0.5 } }, 0..) |o, i|
                    buf[i] = ctr.add(.{ .x = o[0], .y = o[1] });
                return buf[0..4];
            },
            .triangle => {
                const cs = Tri.corners(c);
                for (cs, 0..) |p, i| buf[i] = Tri.point(p);
                return buf[0..3];
            },
            .hexagon => {
                const ctr = Hex.center(c);
                for (0..6) |i| {
                    const a = std.math.pi / 6.0 + std.math.pi / 3.0 * @as(f64, @floatFromInt(i));
                    buf[i] = ctr.add(.{ .x = @cos(a) / S3, .y = @sin(a) / S3 });
                }
                return buf[0..6];
            },
        }
    }

    /// The next level: every cell replaced by a copy of the base maze
    /// (passages `base_passages`), turned as `orientation` asks for (`turn`
    /// is null when only the cells are wanted), the copies joined where the
    /// cells have passages.
    fn expand(g: Geometry, arena: Allocator, level: Level, side_len: i64, base_passages: []const [2]u32, params: *const Params, rand: ?*rng.Random) !Level {
        const nb = g.base.len;
        const cells = try arena.alloc(Coord, level.cells.len * nb);
        const n_rot = g.kind.rotations();
        for (level.cells, 0..) |c, i| {
            const t: usize = if (rand) |r| switch (params.recursion_orientation) {
                .same => 0,
                .rotate => r.below(n_rot),
                .random => r.below(2 * n_rot),
                .sector => g.side(c, side_len, false),
                .spiral => g.side(c, side_len, true),
            } else 0;
            for (g.base, 0..) |d, j| cells[i * nb + j] = g.place(c, g.sym(d, t));
        }
        if (rand == null) return .{ .cells = cells, .passages = &.{} };

        var index: std.AutoHashMapUnmanaged(Coord, u32) = .empty;
        try index.ensureTotalCapacity(arena, @intCast(cells.len));
        for (cells, 0..) |c, i| index.putAssumeCapacity(c, @intCast(i));

        var passages: std.ArrayListUnmanaged([2]u32) = .empty;
        try passages.ensureTotalCapacity(arena, cells.len - 1);
        for (level.cells, 0..) |_, i| {
            const o: u32 = @intCast(i * nb);
            for (base_passages) |p| passages.appendAssumeCapacity(.{ o + p[0], o + p[1] });
        }
        // the openings between the copies
        const Cand = struct { a: u32, b: u32, pos: f64 };
        var cands: std.ArrayListUnmanaged(Cand) = .empty;
        for (level.passages) |p| {
            cands.clearRetainingCapacity();
            var dir: Vec2 = .{};
            for (0..nb) |j| {
                const a: u32 = @intCast(p[0] * nb + j);
                var buf: [6]Coord = undefined;
                for (g.neighbours(cells[a], &buf)) |nc| {
                    const b = index.get(nc) orelse continue;
                    if (@as(usize, b) / nb != p[1]) continue;
                    try cands.append(arena, .{ .a = a, .b = b, .pos = 0 });
                    dir = dir.add(g.center(cells[b]).sub(g.center(cells[a])));
                }
            }
            if (cands.items.len == 0) return error.NoCommonSide;
            // ordered along the common side: from the left, or from the top
            // for a vertical side (as drawn)
            var t = Vec2{ .x = -dir.y, .y = dir.x };
            if (t.x < -1e-9 * t.len() or (@abs(t.x) <= 1e-9 * t.len() and t.y < 0)) t = t.scale(-1);
            for (cands.items) |*cd| {
                const mid = g.center(cells[cd.a]).mean(g.center(cells[cd.b]));
                cd.pos = mid.x * t.x + mid.y * t.y;
            }
            std.sort.pdq(Cand, cands.items, {}, struct {
                fn lt(_: void, x: Cand, y: Cand) bool {
                    return x.pos < y.pos;
                }
            }.lt);
            const k = cands.items.len;
            const at: usize = switch (params.recursion_opening) {
                .middle => (k - 1) / 2,
                .random => rand.?.below(k),
                .at => |v| @min(v, k - 1),
            };
            try passages.append(arena, .{ cands.items[at].a, cands.items[at].b });
        }
        return .{ .cells = cells, .passages = passages.items };
    }
};

fn geometry(arena: Allocator, kind: Kind, n: i64) !Geometry {
    return .{ .kind = kind, .n = n, .base = switch (kind) {
        .square => try Sq.base(arena, n),
        .triangle => try Tri.base(arena, n),
        .hexagon => try Hex.base(arena, n),
    } };
}

/// Builds the maze cells for the cells `cells` (in this order).
fn buildCells(gpa: Allocator, arena: Allocator, params: *Params, rand: *rng.Random, g: Geometry, cells: []const Coord) !*Maze {
    var verts: tiling.PointSet = .{};
    const tiles = try arena.alloc(tiling.Tile, cells.len);
    var min = Vec2{ .x = std.math.inf(f64), .y = std.math.inf(f64) };
    var buf: [6]Vec2 = undefined;
    for (cells) |c| {
        for (g.polygon(c, &buf)) |p| {
            min.x = @min(min.x, p.x);
            min.y = @min(min.y, p.y);
        }
    }
    for (cells, tiles) |c, *tile| {
        const poly = g.polygon(c, &buf);
        const ids = try arena.alloc(u32, poly.len);
        for (poly, ids) |p, *id| id.* = try verts.id(arena, p.sub(min));
        tile.* = .{ .verts = ids, .center = g.center(c).sub(min) };
    }
    const m = try tiling.buildMaze(gpa, params, rand, verts.points.items, tiles);
    std.debug.assert(m.n_cells == cells.len);
    m.countValid();
    return m;
}

/// The cells of the whole maze in the order of the maze's cells.
fn finalCells(arena: Allocator, g: Geometry, params: *const Params) ![]Coord {
    var level: Level = .{ .cells = g.base, .passages = &.{} };
    for (0..params.recursion) |_| level = try g.expand(arena, level, 0, &.{}, params, null);
    return level.cells;
}

/// The uncarved recursive maze.
pub fn newRecursiveMaze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const kind = Kind.of(params.structure).?;
    const n: u64 = @intCast(params.recursion_base);
    const total = cellCount(kind, n, params.recursion) orelse return error.TooManyCells;
    if (total > params.max_cells) return error.TooManyCells;
    const g = try geometry(arena, kind, @intCast(n));
    return buildCells(gpa, arena, params, rand, g, try finalCells(arena, g, params));
}

/// Carves the recursive maze `m` built by `newRecursiveMaze` and places
/// entrance and exit.
pub fn carveRecursive(gpa: Allocator, params: *const Params, m: *Maze) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const kind = Kind.of(params.structure).?;
    const n: i64 = params.recursion_base;
    const g = try geometry(arena, kind, n);

    // the base maze, carved like any other maze
    var bp = params.*;
    bp.recursion = 0;
    bp.mask = null;
    bp.crossings = 0;
    bp.weights = &.{};
    const base_maze = try buildCells(gpa, arena, &bp, m.rand, g, g.base);
    defer base_maze.deinit();
    base_maze.rand = m.rand;
    try carve.carveMaze(gpa, &bp, base_maze);
    var base_passages: std.ArrayListUnmanaged([2]u32) = .empty;
    for (base_maze.walls[0..base_maze.n_walls]) |*w| {
        if (w.isOpen() and w.cells[0].valid() and w.cells[1].valid())
            try base_passages.append(arena, .{ @intCast(w.cells[0].no), @intCast(w.cells[1].no) });
    }

    var level: Level = .{ .cells = g.base, .passages = base_passages.items };
    var side_len: i64 = n;
    for (0..params.recursion) |_| {
        level = try g.expand(arena, level, side_len, base_passages.items, params, m.rand);
        side_len *= n;
    }

    // the maze's cells are in the order of `finalCells`
    const cells = try finalCells(arena, g, params);
    var index: std.AutoHashMapUnmanaged(Coord, u32) = .empty;
    for (cells, 0..) |c, i| try index.put(arena, c, @intCast(i));
    for (level.passages) |p| {
        const a = m.cell(index.get(level.cells[p[0]]).?);
        const b = m.cell(index.get(level.cells[p[1]]).?);
        for (0..a.nWalls()) |i| {
            const w = m.cellWall(a, i);
            if (w.other(a) == b) w.state = .open;
        }
    }
    try carve.placeEntranceExit(gpa, params, m);
}

// ---------------------------------------------------------------------------

test "hexagons of hexagons tile the plane on the lattice μ·c" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (2..6) |n| {
        const g = try geometry(arena, .hexagon, @intCast(n));
        try std.testing.expectEqual(Kind.hexagon.baseCells(n), g.base.len);
        // the copies of a big hexagon of cells cover every lattice point
        // near the center exactly once
        var seen: std.AutoHashMapUnmanaged(Coord, void) = .empty;
        const big = try Hex.base(arena, 5);
        for (big) |c| for (g.base) |d| {
            const gop = try seen.getOrPut(arena, g.place(c, d));
            try std.testing.expect(!gop.found_existing);
        };
        var r: i64 = -2;
        while (r <= 2) : (r += 1) {
            var q: i64 = -2;
            while (q <= 2) : (q += 1) try std.testing.expect(seen.contains(.{ q, r }));
        }
        // the symmetries map the base hexagon to itself
        for (0..12) |t| for (g.base) |d| try std.testing.expect(Hex.dist(Hex.sym(d, t)) <= @as(i64, @intCast(n)) - 1);
    }
}

test "squares of squares and triangles of triangles" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]Kind{ .square, .triangle }) |kind| for (2..6) |n| {
        const g = try geometry(arena, kind, @intCast(n));
        try std.testing.expectEqual(kind.baseCells(n), g.base.len);
        var set: std.AutoHashMapUnmanaged(Coord, void) = .empty;
        for (g.base) |d| try set.put(arena, d, {});
        // the symmetries map the base to itself, up triangles to up
        // triangles for the rotations
        for (0..2 * kind.rotations()) |t| for (g.base) |d| {
            const e = g.sym(d, t);
            try std.testing.expect(set.contains(e));
            if (kind == .triangle and t < 3) try std.testing.expectEqual(Tri.up(d), Tri.up(e));
        };
        // the next level is the base of side n²
        const lv = try g.expand(arena, .{ .cells = g.base, .passages = &.{} }, @intCast(n), &.{}, &.{}, null);
        var all: std.AutoHashMapUnmanaged(Coord, void) = .empty;
        for (lv.cells) |c| try all.put(arena, c, {});
        try std.testing.expectEqual(lv.cells.len, all.count());
        const big = (try geometry(arena, kind, @intCast(n * n))).base;
        try std.testing.expectEqual(big.len, lv.cells.len);
        for (big) |c| try std.testing.expect(all.contains(c));
    };
    // a quarter turn maps (x, y) to (n-1-y, x): the bottom row becomes the
    // left column; the mirror image exchanges left and right
    try std.testing.expectEqual(Coord{ 0, 1 }, Sq.sym(.{ 1, 2 }, 1, 3));
    try std.testing.expectEqual(Coord{ 2, 0 }, Sq.sym(.{ 0, 0 }, 4, 3));
}

test "sides of squares, triangles and hexagons" {
    // square of side 5: the spiral's outer ring and the center
    for ([_][3]i64{
        .{ 0, 4, 1 }, .{ 0, 0, 1 }, .{ 1, 0, 2 }, .{ 4, 0, 2 }, .{ 4, 1, 3 },
        .{ 4, 4, 3 }, .{ 3, 4, 0 }, .{ 1, 4, 0 }, .{ 1, 3, 1 }, .{ 2, 2, 0 },
    }) |x| try std.testing.expectEqual(@as(usize, @intCast(x[2])), Sq.side(.{ x[0], x[1] }, 5, true));
    // square of side 4: one cell inside each sector, and the diagonals
    for ([_][3]i64{
        .{ 0, 1, 1 }, .{ 1, 0, 2 }, .{ 3, 2, 3 }, .{ 2, 3, 0 },
        .{ 3, 3, 0 }, .{ 0, 3, 1 }, .{ 0, 0, 2 }, .{ 3, 0, 3 },
    }) |x| try std.testing.expectEqual(@as(usize, @intCast(x[2])), Sq.side(.{ x[0], x[1] }, 4, false));
    try std.testing.expectEqual(@as(usize, 0), Sq.side(.{ 2, 2 }, 5, false));
    // every sector of a square has the same number of cells
    for ([_]i64{ 4, 5, 8, 9 }) |s| {
        var count: [4]usize = @splat(0);
        var y: i64 = 0;
        while (y < s) : (y += 1) {
            var x: i64 = 0;
            while (x < s) : (x += 1) count[Sq.side(.{ x, y }, s, false)] += 1;
        }
        count[0] -= @intCast(@mod(s, 2)); // the center cell
        for (count) |c| try std.testing.expectEqual(count[0], c);
    }
    // triangle of side 3: the corners and the center
    try std.testing.expectEqual(@as(usize, 1), Tri.side(.{ 1, 1 }, 3, true)); // lower left: left
    try std.testing.expectEqual(@as(usize, 1), Tri.side(.{ 1, 1 }, 3, false)); // sector: left
    try std.testing.expectEqual(@as(usize, 1), Tri.side(.{ 1, 7 }, 3, true)); // top: left
    try std.testing.expectEqual(@as(usize, 2), Tri.side(.{ 1, 7 }, 3, false)); // sector: right
    try std.testing.expectEqual(@as(usize, 2), Tri.side(.{ 7, 1 }, 3, true)); // lower right: right
    try std.testing.expectEqual(@as(usize, 0), Tri.side(.{ 7, 1 }, 3, false)); // sector: bottom
    try std.testing.expectEqual(@as(usize, 0), Tri.side(.{ 4, 1 }, 3, true)); // bottom middle
    try std.testing.expectEqual(@as(usize, 0), Tri.side(.{ 2, 2 }, 2, true)); // center (all equal)
    // hexagon ring 1: (0, 1) is drawn below right of the center: on the
    // bottom side and the lower right one
    try std.testing.expectEqual(@as(usize, 5), Hex.side(.{ 0, 1 }, true));
    try std.testing.expectEqual(@as(usize, 0), Hex.side(.{ 0, 1 }, false));
    try std.testing.expectEqual(@as(usize, 0), Hex.side(.{ -1, 2 }, true)); // bottom side, middle
    try std.testing.expectEqual(@as(usize, 0), Hex.side(.{ 0, 0 }, true));
    // the sectors give every side of a ring the same number of cells; the
    // spiral's first side (lower left) keeps both of its corners, the
    // bottom one, the last, none
    for ([_]bool{ false, true }) |spiral| {
        var count: [6]usize = @splat(0);
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        for (try Hex.base(arena_state.allocator(), 4)) |c| {
            if (Hex.dist(c) == 3) count[Hex.side(c, spiral)] += 1;
        }
        const want = if (spiral) [6]usize{ 2, 4, 3, 3, 3, 3 } else [6]usize{ 3, 3, 3, 3, 3, 3 };
        try std.testing.expectEqualSlices(usize, &want, &count);
    }
}

const all_kinds = [_]Kind{ .square, .triangle, .hexagon };

fn testMaze(kind: Kind, n: i32, levels: u32, seed: u32, algo: mz.Algorithm, opening: mz.RecursionOpening, orientation: mz.RecursionOrientation) !*Maze {
    var params: Params = .{
        .structure = switch (kind) {
            .square => tables.ortho[0],
            .triangle => tables.tria[0],
            .hexagon => tables.hexa[0],
        },
        .rows = n,
        .columns = n,
        .recursion = levels,
        .recursion_base = n,
        .algorithm = algo,
        .recursion_opening = opening,
        .recursion_orientation = orientation,
    };
    var rand = rng.Random.init(seed);
    const m = try mz.newMaze(std.testing.allocator, &params, &rand);
    errdefer m.deinit();
    const r = try m.alloc().create(rng.Random);
    r.* = rand;
    m.rand = r;
    try carveRecursive(std.testing.allocator, &params, m);
    return m;
}

test "recursive mazes are perfect" {
    const tests = @import("tests.zig");
    for (all_kinds) |kind| {
        for ([_]mz.Algorithm{ .backtracker, .prim, .tree, .wilson }) |algo| {
            for ([_][2]u32{ .{ 2, 2 }, .{ 3, 1 }, .{ 3, 2 } }) |nl| {
                for ([_]mz.RecursionOpening{ .middle, .random, .{ .at = 0 }, .{ .at = 99 } }) |opening| {
                    for ([_]mz.RecursionOrientation{ .same, .rotate, .random, .sector, .spiral }) |orientation| {
                        const m = try testMaze(kind, @intCast(nl[0]), nl[1], nl[0] * 10 + nl[1], algo, opening, orientation);
                        defer m.deinit();
                        try std.testing.expectEqual(@as(usize, @intCast(cellCount(kind, nl[0], nl[1]).?)), m.n_cells);
                        tests.checkPerfect(m) catch |e| {
                            std.debug.print("{t} n={d} levels={d} {t} {any} {t}\n", .{ kind, nl[0], nl[1], algo, opening, orientation });
                            return e;
                        };
                    }
                }
            }
        }
    }
}

test "every copy is the base maze, turned as requested" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const levels = 2;
    for (all_kinds) |kind| {
        const n: i64 = 3;
        const g = try geometry(arena, kind, n);
        const nb = g.base.len;
        var base_index: std.AutoHashMapUnmanaged(Coord, usize) = .empty;
        for (g.base, 0..) |d, j| try base_index.put(arena, d, j);
        // the cells of the level before the last one, and its side length
        var coarse: Level = .{ .cells = g.base, .passages = &.{} };
        var side_len: i64 = n;
        for (0..levels - 1) |_| {
            coarse = try g.expand(arena, coarse, 0, &.{}, &.{}, null);
            side_len *= n;
        }
        for ([_]mz.RecursionOrientation{ .same, .rotate, .random, .sector, .spiral }) |orientation| {
            const m = try testMaze(kind, @intCast(n), levels, 5, .backtracker, .middle, orientation);
            defer m.deinit();
            const params: Params = .{ .recursion = levels };
            var index: std.AutoHashMapUnmanaged(Coord, u32) = .empty;
            for (try finalCells(arena, g, &params), 0..) |c, i| try index.put(arena, c, @intCast(i));
            const open = struct {
                fn f(mm: *Maze, a: u32, b: u32) bool {
                    const ca = mm.cell(a);
                    for (0..ca.nWalls()) |i| {
                        const w = mm.cellWall(ca, i);
                        if (w.other(ca) == mm.cell(b)) return w.isOpen();
                    }
                    return false;
                }
            }.f;
            // the passages of the copy in cell c, in base coordinates
            const blocks = try arena.alloc([]bool, coarse.cells.len);
            for (coarse.cells, blocks) |c, *bl| {
                bl.* = try arena.alloc(bool, nb * nb);
                for (0..nb) |j1| for (0..nb) |j2| {
                    const a = index.get(g.place(c, g.base[j1])).?;
                    const b = index.get(g.place(c, g.base[j2])).?;
                    bl.*[j1 * nb + j2] = j1 != j2 and open(m, a, b);
                };
            }
            // the copy turned by u equals the copy in cell c
            const Same = struct {
                fn f(gg: Geometry, bi: *const std.AutoHashMapUnmanaged(Coord, usize), first: []const bool, other: []const bool, u: usize) bool {
                    const k = gg.base.len;
                    for (0..k) |j1| for (0..k) |j2| {
                        const e1 = bi.get(gg.sym(gg.base[j1], u)).?;
                        const e2 = bi.get(gg.sym(gg.base[j2], u)).?;
                        if (first[j1 * k + j2] != other[e1 * k + e2]) return false;
                    };
                    return true;
                }
            };
            const rot = kind.rotations();
            for (coarse.cells, blocks) |c, bl| {
                const ok = switch (orientation) {
                    .same => Same.f(g, &base_index, blocks[0], bl, 0),
                    .rotate, .random => blk: {
                        const n_sym: usize = if (orientation == .rotate) rot else 2 * rot;
                        for (0..n_sym) |u| if (Same.f(g, &base_index, blocks[0], bl, u)) break :blk true;
                        break :blk false;
                    },
                    .sector, .spiral => blk: {
                        const spiral = orientation == .spiral;
                        // rotations add up: from the first copy's turn to c's
                        const t0 = g.side(coarse.cells[0], side_len, spiral);
                        const t = g.side(c, side_len, spiral);
                        break :blk Same.f(g, &base_index, blocks[0], bl, (t + rot - t0) % rot);
                    },
                };
                if (!ok) {
                    std.debug.print("{t} {t}: copy at {any}\n", .{ kind, orientation, c });
                    return error.WrongCopy;
                }
            }
        }
    }
}

test "the openings between copies: one per side, as many places as cells along it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (all_kinds) |kind| {
        const n = 3;
        const g = try geometry(arena, kind, n);
        // two neighbouring cells with a passage
        const lv0: Level = .{ .cells = g.base, .passages = &.{} };
        var buf: [6]Coord = undefined;
        const nbs = g.neighbours(g.base[0], &buf);
        // the first neighbour; for squares (1, 0)
        var other: u32 = 0;
        for (g.base, 0..) |c, i| {
            if (std.meta.eql(c, nbs[0])) other = @intCast(i);
        }
        try std.testing.expect(other != 0);
        var pass = [_][2]u32{.{ 0, other }};
        const lv = Level{ .cells = lv0.cells, .passages = &pass };
        var places: std.AutoHashMapUnmanaged([2]u32, void) = .empty;
        for (0..10) |at| {
            const params: Params = .{ .recursion_opening = .{ .at = @intCast(at) } };
            var rand = rng.Random.init(1);
            const next = try g.expand(arena, lv, n, &.{}, &params, &rand);
            try std.testing.expectEqual(@as(usize, 1), next.passages.len);
            try places.put(arena, next.passages[0], {});
            // squares: counted from the top of the vertical side between
            // (0, 0) and (1, 0)
            if (kind == .square) {
                const p = next.passages[0];
                try std.testing.expectEqual(@as(i64, @intCast(@min(at, n - 1))), next.cells[p[0]][1]);
            }
        }
        // squares and triangles share n edges, hexagons of radius n - 1
        // have 2n - 1 pairs of cells along their common side
        try std.testing.expectEqual(@as(usize, if (kind == .hexagon) 2 * n - 1 else n), places.count());
    }
}
