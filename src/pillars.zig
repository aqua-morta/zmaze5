//! Pillars (`--pillars`): all cells of the given types are excluded from
//! the maze; they become solid blocks the paths have to go around.
//!
//! Caves (`--cave`): cells of the given types become rooms with a single
//! entry. While carving they are excluded like pillars (so they are never
//! passed through and don't get the entrance or exit); afterwards each one
//! is opened to one random neighbouring maze cell (`finishCaves`). As dead
//! ends they keep the maze perfect. Caves without a neighbouring maze cell
//! (e.g. only surrounded by other caves) become pillars.
//!
//! Excluding cell types can split the maze. Before the cells are excluded
//! the connected parts of the maze are determined (a mask can already split
//! a maze), then again afterwards. If one of the original parts falls apart,
//! the pieces besides the largest one are cut off. Small pieces at the outer
//! border are a side effect of cutting the tiling at the maze border (e.g. a
//! single triangle in a corner that only touches excluded squares); they
//! become pillars as well. A piece completely enclosed by pillars proves that
//! the tiling itself falls apart without the excluded types (it could only
//! be connected to the rest through cells outside of the maze, but then it
//! would touch the border); so do large pieces cut off (e.g. stripes): no
//! maze can be built.

const std = @import("std");
const mz = @import("maze.zig");
const geo = @import("geo.zig");
const structure = @import("structure.zig");

const Allocator = std.mem.Allocator;
const Maze = mz.Maze;
const Cell = mz.Cell;
const Vec2 = geo.Vec2;

/// Maximum fraction (or number, for small mazes) of the remaining cells that
/// may be cut off at the border.
const MAX_CUT_OFF = 0.05;
const MAX_CUT_OFF_CELLS = 3;

const MAX_TYPES = 26;

inline fn bit(t: usize) u32 {
    return @as(u32, 1) << @intCast(t);
}

/// The cell type as index (A = 0) if the cell belongs to the maze and has a
/// lettered type.
fn baseType(c: *const Cell) ?usize {
    if (!c.valid()) return null;
    const t = c.type & ~mz.TYPE_CROSSABLE;
    return if (t < MAX_TYPES) t else null;
}

pub const ParseError = error{ InvalidSyntax, UnknownCellType };

/// Parses a list of cell type letters like "B", "b,c" or "BC" into a bit
/// set (bit i = type A + i). For structures with a tile table the letters
/// are checked against its cell types; for the others `apply` reports types
/// that don't occur in the maze.
pub fn parse(s: *const structure.Structure, arg: []const u8) ParseError!u32 {
    var res: u32 = 0;
    for (arg) |ch| {
        switch (ch) {
            ',', ' ', '/' => {},
            'a'...'z', 'A'...'Z' => {
                const t = std.ascii.toUpper(ch) - 'A';
                if (s.neighbours.len > 0 and t >= s.neighbours.len) return error.UnknownCellType;
                res |= bit(t);
            },
            else => return error.InvalidSyntax,
        }
    }
    if (res == 0) return error.InvalidSyntax;
    return res;
}

pub const LimitError = error{ InvalidSyntax, UnknownCellType, DuplicateCellType };

/// Parses opening limits (`--max-openings`) like "B:2" or "B:0/C:3" into
/// the maximum number of openings per cell type (`mz.NO_LIMIT` for types
/// not given).
pub fn parseLimits(s: *const structure.Structure, arg: []const u8) LimitError![mz.MAX_TYPES]u8 {
    var res: [mz.MAX_TYPES]u8 = @splat(mz.NO_LIMIT);
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, arg, "/, ");
    while (it.next()) |part| : (n += 1) {
        if (part.len < 3 or part[1] != ':' or !std.ascii.isAlphabetic(part[0])) return error.InvalidSyntax;
        const t = std.ascii.toUpper(part[0]) - 'A';
        if (s.neighbours.len > 0 and t >= s.neighbours.len) return error.UnknownCellType;
        if (res[t] != mz.NO_LIMIT) return error.DuplicateCellType;
        const v = std.fmt.parseInt(u8, part[2..], 10) catch return error.InvalidSyntax;
        if (v >= mz.NO_LIMIT) return error.InvalidSyntax;
        res[t] = v;
    }
    if (n == 0) return error.InvalidSyntax;
    return res;
}

pub const Status = enum {
    ok,
    /// some of the types don't occur in the maze (`missing`)
    missing,
    /// no cell is left
    nothing_left,
    /// the maze falls apart
    split,
};

pub const Result = struct {
    status: Status = .ok,
    missing: u32 = 0,
    /// cells excluded because of their type
    pillars: usize = 0,
    /// cells cut off at the border (turned into pillars as well)
    cut_off: usize = 0,
    /// cave cells, and those of them without a neighbouring maze cell
    /// (turned into pillars)
    caves: usize = 0,
    lonely_caves: usize = 0,
    /// split: number of pieces, pieces enclosed by pillars, cells of the
    /// largest piece and remaining cells in total
    parts: usize = 0,
    enclosed: usize = 0,
    largest: usize = 0,
    total: usize = 0,
};

const NONE = std.math.maxInt(u32);

inline fn index(m: *Maze, c: *const Cell) usize {
    return (@intFromPtr(c) - @intFromPtr(m.cells.ptr)) / @sizeOf(Cell);
}

/// Labels the connected parts of the maze (valid cells connected by
/// breakable walls); invalid cells get `NONE`. Returns the number of parts.
fn label(gpa: Allocator, m: *Maze, comp: []u32) !u32 {
    @memset(comp, NONE);
    var stack: std.ArrayListUnmanaged(*Cell) = .empty;
    defer stack.deinit(gpa);
    var n: u32 = 0;
    for (m.cells[0..m.n_cells], 0..) |*start, si| {
        if (!start.valid() or comp[si] != NONE) continue;
        comp[si] = n;
        try stack.append(gpa, start);
        while (stack.pop()) |c| {
            for (0..c.nWalls()) |i| {
                const w = m.cellWall(c, i);
                const o = w.other(c);
                if (o == c or !o.valid() or !w.breakable()) continue;
                const oi = index(m, o);
                if (comp[oi] != NONE) continue;
                comp[oi] = n;
                try stack.append(gpa, o);
            }
        }
        n += 1;
    }
    return n;
}

fn atBorder(m: *Maze, c: *const Cell) bool {
    for (0..c.nWalls()) |i| {
        if (m.neighbour(c, i).type == mz.TYPE_OFF) return true;
    }
    return false;
}

fn makePillar(c: *Cell) void {
    c.type = mz.TYPE_PILLAR;
    c.mark = mz.MARK_VISITED;
}

fn makeCave(m: *Maze, c: *Cell) !void {
    try m.caves.append(m.alloc(), .{ .cell = c, .type = c.type });
    c.type = mz.TYPE_CAVE;
    c.mark = mz.MARK_VISITED;
}

/// The walls of a cave cell leading to a maze cell.
fn caveExits(m: *Maze, c: *const Cell) u64 {
    var res: u64 = 0;
    for (0..@min(c.nWalls(), 64)) |i| {
        const w = m.cellWall(c, i);
        if (w.breakable() and w.isClosed() and w.other(c).valid()) res |= @as(u64, 1) << @intCast(i);
    }
    return res;
}

/// Turns all cells of the types `pillar_types` into pillars and those of
/// `cave_types` into caves and checks that the remaining maze stays
/// connected (see the module documentation). Unless the status is `ok` the
/// maze must not be used.
pub fn apply(gpa: Allocator, m: *Maze, pillar_types: u32, cave_types: u32) !Result {
    const types = pillar_types | cave_types;
    if (types == 0) return .{};
    const cells = m.cells[0..m.n_cells];
    var present: u32 = 0;
    for (cells) |*c| {
        if (baseType(c)) |t| present |= bit(t);
    }
    if (types & ~present != 0) return .{ .status = .missing, .missing = types & ~present };

    const before = try gpa.alloc(u32, cells.len);
    defer gpa.free(before);
    const after = try gpa.alloc(u32, cells.len);
    defer gpa.free(after);
    const n_before = try label(gpa, m, before);

    var res: Result = .{};
    for (cells) |*c| {
        const t = baseType(c) orelse continue;
        if (pillar_types & bit(t) != 0) {
            makePillar(c);
            res.pillars += 1;
        } else if (cave_types & bit(t) != 0) {
            try makeCave(m, c);
            res.caves += 1;
        }
    }
    defer m.countValid();

    const n_after = try label(gpa, m, after);
    if (n_after == 0) {
        res.status = .nothing_left;
        return res;
    }
    // size, original part and border contact of each piece
    const size = try gpa.alloc(usize, n_after);
    defer gpa.free(size);
    const orig = try gpa.alloc(u32, n_after);
    defer gpa.free(orig);
    const border = try gpa.alloc(bool, n_after);
    defer gpa.free(border);
    @memset(size, 0);
    @memset(border, false);
    for (cells, after, before) |*c, a, b| {
        if (a == NONE) continue;
        size[a] += 1;
        orig[a] = b;
        if (!border[a] and atBorder(m, c)) border[a] = true;
    }
    // the largest piece of every original part is kept
    const keep = try gpa.alloc(u32, n_before);
    defer gpa.free(keep);
    @memset(keep, NONE);
    for (size, orig, 0..) |s, o, a| {
        if (keep[o] == NONE or s > size[keep[o]]) keep[o] = @intCast(a);
    }
    res.parts = n_after;
    for (size, orig, border, 0..) |s, o, bd, a| {
        res.total += s;
        res.largest = @max(res.largest, s);
        if (keep[o] == a) continue;
        res.cut_off += s;
        if (!bd) res.enclosed += 1;
    }
    if (res.cut_off == 0) return checkCaves(m, res);
    const max_cut = @max(MAX_CUT_OFF * @as(f64, @floatFromInt(res.total)), MAX_CUT_OFF_CELLS);
    if (res.enclosed > 0 or @as(f64, @floatFromInt(res.cut_off)) > max_cut) {
        res.status = .split;
        return res;
    }
    for (cells, after) |*c, a| {
        if (a != NONE and keep[orig[a]] != a) makePillar(c);
    }
    return checkCaves(m, res);
}

/// Caves without a neighbouring maze cell become pillars.
fn checkCaves(m: *Maze, res_: Result) Result {
    var res = res_;
    for (m.caves.items) |cv| {
        if (cv.cell.type == mz.TYPE_CAVE and caveExits(m, cv.cell) == 0) {
            makePillar(cv.cell);
            res.lonely_caves += 1;
        }
    }
    return res;
}

/// Gives every cave a single entry from a random neighbouring maze cell (if
/// `open`, i.e. after carving) and makes the caves normal cells again.
pub fn finishCaves(m: *Maze, open: bool) void {
    if (m.caves.items.len == 0) return;
    if (open) {
        // all caves first: they must not be opened to each other
        for (m.caves.items) |cv| {
            const c = cv.cell;
            if (c.type != mz.TYPE_CAVE) continue;
            const exits = caveExits(m, c);
            if (exits == 0) continue;
            var k = m.rand.below(@popCount(exits));
            for (0..c.nWalls()) |i| {
                if (exits & (@as(u64, 1) << @intCast(i)) == 0) continue;
                if (k == 0) {
                    m.cellWall(c, i).state = .open;
                    break;
                }
                k -= 1;
            }
        }
    }
    for (m.caves.items) |cv| {
        if (cv.cell.type != mz.TYPE_CAVE) continue;
        cv.cell.type = cv.type;
        cv.cell.mark = mz.MARK_NONE;
    }
    m.caves.clearRetainingCapacity();
    m.countValid();
}

/// A wall of a cell outline, oriented along the outline.
pub const Edge = struct {
    wall: *const mz.Wall,
    from: Vec2,
    to: Vec2,
    /// from = points[1], to = points[0] of the wall
    reversed: bool = false,
};

/// `p` moved by whole tile sizes as close to `ref` as possible (tileable
/// mazes store walls crossing the tile border at one side only).
fn nearest(m: *Maze, ref: Vec2, p: Vec2) Vec2 {
    if (!m.tileable) return p;
    const tw = m.tileWidth();
    const th = m.tileHeight();
    return .{
        .x = p.x - tw * @round((p.x - ref.x) / tw),
        .y = p.y - th * @round((p.y - ref.y) / th),
    };
}

/// The outline of a cell: its walls chained at their common end points.
/// Returns null if the walls don't form a closed polygon.
pub fn outline(m: *Maze, c: *const Cell, buf: []Edge) ?[]Edge {
    const n = c.nWalls();
    if (n < 2 or n > buf.len or n > 64) return null;
    const eps = 1e-6;
    var used: u64 = 1;
    const w0 = m.cellWall(c, 0);
    buf[0] = .{ .wall = w0, .from = nearest(m, c.center, w0.points[0]), .to = nearest(m, c.center, w0.points[1]) };
    var k: usize = 1;
    while (k < n) : (k += 1) {
        const last = buf[k - 1].to;
        for (1..n) |i| {
            if (used & (@as(u64, 1) << @intCast(i)) != 0) continue;
            const w = m.cellWall(c, i);
            const p0 = nearest(m, c.center, w.points[0]);
            const p1 = nearest(m, c.center, w.points[1]);
            if (p0.sub(last).len() < eps) {
                buf[k] = .{ .wall = w, .from = p0, .to = p1 };
            } else if (p1.sub(last).len() < eps) {
                buf[k] = .{ .wall = w, .from = p1, .to = p0, .reversed = true };
            } else continue;
            used |= @as(u64, 1) << @intCast(i);
            break;
        } else return null;
    }
    if (buf[n - 1].to.sub(buf[0].from).len() >= eps) return null;
    return buf[0..n];
}

// ---------------------------------------------------------------------------

const rng = @import("rng.zig");
const carve = @import("carve.zig");

fn testMaze(gpa: Allocator, name: []const u8, rows: i32, cols: i32, rand: *rng.Random) !*Maze {
    var params: mz.Params = .{ .structure = try structure.lookup(name), .rows = rows, .columns = cols };
    return mz.newMaze(gpa, &params, rand);
}

test "parse opening limits" {
    const hs = try structure.lookup("6-4"); // A(6),B(4),C(6)
    const l = try parseLimits(hs, "B:2/c:0");
    try std.testing.expectEqual(@as(u8, mz.NO_LIMIT), l[0]);
    try std.testing.expectEqual(@as(u8, 2), l[1]);
    try std.testing.expectEqual(@as(u8, 0), l[2]);
    try std.testing.expectError(error.UnknownCellType, parseLimits(hs, "D:1"));
    try std.testing.expectError(error.DuplicateCellType, parseLimits(hs, "B:1,B:2"));
    try std.testing.expectError(error.InvalidSyntax, parseLimits(hs, "B"));
    try std.testing.expectError(error.InvalidSyntax, parseLimits(hs, "B:-1"));
}

test "parse pillar types" {
    const hs = try structure.lookup("6-4"); // A(6),B(4),C(6)
    try std.testing.expectEqual(@as(u32, 0b010), try parse(hs, "B"));
    try std.testing.expectEqual(@as(u32, 0b110), try parse(hs, "b,C"));
    try std.testing.expectEqual(@as(u32, 0b101), try parse(hs, "AC"));
    try std.testing.expectError(error.UnknownCellType, parse(hs, "D"));
    try std.testing.expectError(error.InvalidSyntax, parse(hs, "B:1"));
    try std.testing.expectError(error.InvalidSyntax, parse(hs, ""));
}

test "pillars: hexagon-square without squares gives a perfect maze" {
    const gpa = std.testing.allocator;
    const tests = @import("tests.zig");
    for ([_]mz.Algorithm{ .backtracker, .prim, .tree, .wilson }) |alg| {
        var rand = rng.Random.init(5);
        const m = try testMaze(gpa, "6-4", 12, 12, &rand);
        defer m.deinit();
        const n_cells = m.n_valid;
        const res = try apply(gpa, m, 0b010, 0);
        try std.testing.expectEqual(Status.ok, res.status);
        try std.testing.expect(res.pillars > 0);
        try std.testing.expectEqual(n_cells - res.pillars - res.cut_off, m.n_valid);
        for (m.cells[0..m.n_cells]) |*c| {
            if (c.valid()) try std.testing.expect(c.type & ~mz.TYPE_CROSSABLE != 1);
        }
        const params: mz.Params = .{ .algorithm = alg };
        try carve.carveMaze(gpa, &params, m);
        try tests.checkPerfect(m);
    }
}

test "pillars: octagon-square without octagons falls apart" {
    const gpa = std.testing.allocator;
    var rand = rng.Random.init(1);
    const m = try testMaze(gpa, "8-4", 10, 10, &rand); // A(4),B(8)
    defer m.deinit();
    const res = try apply(gpa, m, 0b10, 0);
    try std.testing.expectEqual(Status.split, res.status);
    try std.testing.expect(res.enclosed > 0);
    try std.testing.expectEqual(@as(usize, 1), res.largest);
}

test "pillars: missing and all types" {
    const gpa = std.testing.allocator;
    var rand = rng.Random.init(1);
    const m = try testMaze(gpa, "4", 5, 5, &rand); // A(4)
    defer m.deinit();
    const res = try apply(gpa, m, 0b10, 0);
    try std.testing.expectEqual(Status.missing, res.status);
    try std.testing.expectEqual(@as(u32, 0b10), res.missing);
    try std.testing.expectEqual(Status.nothing_left, (try apply(gpa, m, 0b1, 0)).status);
}

test "pillar outlines are closed polygons" {
    const gpa = std.testing.allocator;
    var rand = rng.Random.init(1);
    for ([_][]const u8{ "6-4", "12-6-4", "shield", "einstein" }) |name| {
        const m = try testMaze(gpa, name, 8, 8, &rand);
        defer m.deinit();
        var buf: [64]Edge = undefined;
        for (m.cells[0..m.n_cells]) |*c| {
            if (!c.valid()) continue;
            const poly = outline(m, c, &buf) orelse return error.NoOutline;
            try std.testing.expectEqual(c.nWalls(), poly.len);
        }
    }
}

test "pillar outlines in tileable mazes" {
    const gpa = std.testing.allocator;
    var rand = rng.Random.init(1);
    for ([_][]const u8{ "4", "6-4", "6-4:2", "3-4" }) |name| {
        var params: mz.Params = .{ .structure = try structure.lookup(name), .rows = 12, .columns = 12, .tileable = true };
        const m = try mz.newMaze(gpa, &params, &rand);
        defer m.deinit();
        var buf: [64]Edge = undefined;
        for (m.cells[0..m.n_cells]) |*c| {
            if (!c.valid()) continue;
            const poly = outline(m, c, &buf) orelse return error.NoOutline;
            for (poly) |e| try std.testing.expect(e.from.sub(c.center).len() < 2);
        }
    }
}

test "pillars: every accepted exclusion gives a perfect maze" {
    const gpa = std.testing.allocator;
    const tests = @import("tests.zig");
    const tables = @import("structures.zig");
    var accepted: usize = 0;
    for (tables.all) |s| {
        const n_types: usize = switch (s.construct) {
            .periodic => s.neighbours.len,
            .penrose, .penrose_rhombs, .einstein, .ammann_beenker, .wheel, .pentagonal_rotational => 2,
            .supergolden, .shield, .clamshell => 3,
            else => 0,
        };
        for (0..n_types) |t| {
            for ([_]mz.Algorithm{ .backtracker, .wilson }) |alg| {
                var rand = rng.Random.init(@intCast(t + 1));
                var params: mz.Params = .{ .structure = s, .rows = 10, .columns = 10, .algorithm = alg };
                const m = try mz.newMaze(gpa, &params, &rand);
                defer m.deinit();
                const res = try apply(gpa, m, bit(t), 0);
                if (res.status != .ok) continue;
                accepted += 1;
                carve.carveMaze(gpa, &params, m) catch |e| switch (e) {
                    // all border cells can be pillars
                    error.NoEntrance, error.NoExit => continue,
                    else => return e,
                };
                tests.checkPerfect(m) catch |e| {
                    std.debug.print("{s}: excluding {c} ({t})\n", .{ s.name, 'A' + @as(u8, @intCast(t)), alg });
                    return e;
                };
            }
        }
    }
    try std.testing.expect(accepted > 50);
}

test "caves: rooms with a single entry in a perfect maze" {
    const gpa = std.testing.allocator;
    const tests = @import("tests.zig");
    const tables = @import("structures.zig");
    var tested: usize = 0;
    for (tables.all) |s| {
        if (s.construct != .periodic) continue;
        for (0..s.neighbours.len) |t| {
            for ([_]mz.Algorithm{ .backtracker, .prim, .wilson }) |alg| {
                var rand = rng.Random.init(@intCast(t + 7));
                var params: mz.Params = .{ .structure = s, .rows = 10, .columns = 10, .algorithm = alg };
                const m = try mz.newMaze(gpa, &params, &rand);
                defer m.deinit();
                const res = try apply(gpa, m, 0, bit(t));
                if (res.status != .ok) continue;
                carve.carveMaze(gpa, &params, m) catch |e| switch (e) {
                    error.NoEntrance, error.NoExit => continue,
                    else => return e,
                };
                const entrance = m.entrance.?;
                const exit = m.exit.?;
                finishCaves(m, true);
                tested += 1;
                try tests.checkPerfect(m);
                // every cave has exactly one opening, to a maze cell
                var n_caves: usize = 0;
                for (m.cells[0..m.n_cells]) |*c| {
                    if (baseType(c) != t) continue;
                    n_caves += 1;
                    try std.testing.expect(c != entrance and c != exit);
                    var n_open: usize = 0;
                    for (0..c.nWalls()) |i| {
                        const w = m.cellWall(c, i);
                        if (!w.isOpen()) continue;
                        n_open += 1;
                        try std.testing.expect(baseType(w.other(c)) != t);
                    }
                    try std.testing.expectEqual(@as(usize, 1), n_open);
                }
                try std.testing.expectEqual(res.caves - res.lonely_caves, n_caves);
            }
        }
    }
    try std.testing.expect(tested > 50);
}
