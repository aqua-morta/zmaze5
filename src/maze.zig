//! Core maze data model: cells, walls and the maze itself, plus the
//! construction of periodic (tile based) mazes.

const std = @import("std");
const geo = @import("geo.zig");
const structure = @import("structure.zig");
const rng = @import("rng.zig");
const Mask = @import("mask.zig").Mask;

const Allocator = std.mem.Allocator;
pub const Vec2 = geo.Vec2;
pub const Structure = structure.Structure;

/// Cell types. Values below `VALID` denote cells that are part of the maze.
pub const TYPE_A: u8 = 0;
pub const TYPE_CROSSABLE: u8 = 64;
pub const TYPE_THETA: u8 = 100;
pub const TYPE_VORONOI: u8 = 102;
pub const TYPE_VALID: u8 = 200;
/// excluded cell (`--pillars`): not part of the maze, drawn filled
pub const TYPE_PILLAR: u8 = 251;
/// cave cell (`--cave`) while carving; restored to its type afterwards
pub const TYPE_CAVE: u8 = 250;
pub const TYPE_CROSSOVER: u8 = 252;
pub const TYPE_TMP: u8 = 253;
pub const TYPE_OFF: u8 = 254;
pub const TYPE_NONE: u8 = 255;

/// Marks used by the various algorithms.
pub const MARK_NONE: u8 = 0x00;
pub const MARK_VISITED: u8 = 0x01;
pub const MARK_FRONTIER: u8 = 0x02;
pub const MARK_OUT: u8 = 0x04;
pub const MARK_TAINTED: u8 = 0x08;
pub const MARK_CLIP: u8 = 0x08;
pub const MARK_CLIP1: u8 = 0x10;
pub const MARK_CLIP2: u8 = 0x20;
pub const MARK_CLIP12: u8 = 0x30;
pub const MARK_FIXED1: u8 = 0x40;
pub const MARK_FIXED2: u8 = 0x80;

pub const Direction = enum(i8) {
    none = -1,
    north = 0,
    west = 1,
    south = 2,
    east = 3,
};

pub const Algorithm = enum { backtracker, prim, tree, wilson };

/// Where recursive mazes join neighbouring copies of the base maze: in the
/// middle of their common side, at a random cell of it, or at the given cell
/// (0: as drawn, the left end of a horizontal side, the top end of a
/// vertical side).
pub const RecursionOpening = union(enum) { middle, random, at: u32 };

/// How the copies of the base maze of recursive mazes are turned: all the
/// same way, by a random multiple of 90°, by any of the eight symmetries
/// of the square (rotations and reflections), chosen for every copy, or
/// towards a side of the maze: the side of the sector (between the
/// diagonals) the copy is in, or the side the spiral through all cells
/// (from the lower left corner north, clockwise inwards) follows there.
pub const RecursionOrientation = enum { same, rotate, random, sector, spiral };

/// Parameters controlling the maze construction and carving.
pub const Params = struct {
    structure: *const Structure = structure.default,
    columns: i32 = -1,
    rows: i32 = -1,
    seed: u32 = 0,
    mask: ?*const Mask = null,
    tileable: bool = false,
    /// theta mazes: first ring
    startring: i32 = -1,
    /// voronoi mazes
    roughborder: bool = false,
    jitter: f64 = 0.3,
    minwalllength: f64 = 0.33,
    /// carving
    algorithm: Algorithm = .backtracker,
    entrance: Direction = .none,
    exit: Direction = .none,
    treefactor: f64 = 0.5,
    crossings: f64 = 0,
    /// direction weights per cell type (`-W`); indexed by cell type, an
    /// empty entry means all directions are equally likely
    weights: []const []const f64 = &.{},
    /// cell types excluded from the maze (`--pillars`), bit i = type A + i
    pillars: u32 = 0,
    /// cell types that become rooms with a single entry (`--cave`)
    caves: u32 = 0,
    /// recursive mazes (`--recursion`): number of times every cell is
    /// replaced by the base maze of `recursion_base` x `recursion_base`
    /// cells (rows and columns are the size of the whole maze)
    recursion: u32 = 0,
    recursion_base: i32 = 0,
    recursion_opening: RecursionOpening = .middle,
    recursion_orientation: RecursionOrientation = .same,
    /// maximum number of cells (for mazes whose size isn't rows x columns)
    max_cells: usize = std.math.maxInt(u32),
    /// misc
    dummy: bool = false,
    debug: i32 = 0,
};

pub const WallState = enum(u8) { open = 0, closed = 1, bridged = 2 };

pub const Cell = struct {
    no: i32 = 0,
    user_data: u8 = 0,
    mark: u8 = MARK_NONE,
    type: u8 = TYPE_A,
    /// indices into `Maze.walls`
    walls: std.ArrayListUnmanaged(u32) = .empty,
    center: Vec2 = .{},

    pub inline fn valid(c: *const Cell) bool {
        return c.type <= TYPE_VALID;
    }

    pub inline fn nWalls(c: *const Cell) usize {
        return c.walls.items.len;
    }

    /// Wall index of the i-th wall; `i` wraps around.
    pub inline fn wallIdx(c: *const Cell, i: usize) u32 {
        return c.walls.items[i % c.walls.items.len];
    }

    pub inline fn visited(c: *const Cell) bool {
        return (c.mark & MARK_VISITED) != 0;
    }

    /// If none of the bits in `check` is set, sets `mark` and returns true.
    pub inline fn checkNMark(c: *Cell, check: u8, mark: u8) bool {
        const res = (c.mark & check) == 0;
        if (res) c.mark |= mark;
        return res;
    }

    pub inline fn visit(c: *Cell) bool {
        return c.checkNMark(MARK_VISITED, MARK_VISITED);
    }

    /// Removes the idx-th wall reference (the last one takes its place).
    pub fn removeWallIdx(c: *Cell, idx: usize) void {
        if (c.walls.items.len > 0) {
            _ = c.walls.swapRemove(idx);
        }
    }

    pub fn removeWall(c: *Cell, wall: *const Wall) void {
        for (c.walls.items, 0..) |w, i| {
            if (w == wall.no) {
                c.removeWallIdx(i);
                break;
            }
        }
    }
};

pub const Wall = struct {
    no: u32 = 0,
    mark: u8 = MARK_NONE,
    state: WallState = .closed,
    features: u8 = 0,
    cells: [2]*Cell = undefined,
    points: [2]Vec2 = .{ .{}, .{} },
    /// angle of arc walls
    value: f64 = 0,

    pub inline fn has(w: *const Wall, f: u8) bool {
        return (w.features & f) != 0;
    }

    pub inline fn primary(w: *const Wall) *Cell {
        return w.cells[0];
    }

    pub inline fn secondary(w: *const Wall) *Cell {
        return w.cells[1];
    }

    pub inline fn other(w: *const Wall, c: *const Cell) *Cell {
        return if (c == w.cells[1]) w.cells[0] else w.cells[1];
    }

    pub inline fn isOpen(w: *const Wall) bool {
        return w.state == .open;
    }

    pub inline fn isClosed(w: *const Wall) bool {
        return w.state != .open;
    }

    pub inline fn isBridged(w: *const Wall) bool {
        return w.state == .bridged;
    }

    pub inline fn breakable(w: *const Wall) bool {
        return !w.has(structure.WALL_INDESTRUCTIBLE);
    }

    pub inline fn bridgeable(w: *const Wall) bool {
        return w.has(structure.WALL_BRIDGEABLE) and w.state == .closed and
            w.cells[0].valid() and w.cells[1].valid();
    }

    pub inline fn outer(w: *const Wall) bool {
        return w.cells[0].type == TYPE_OFF or w.cells[1].type == TYPE_OFF;
    }

    pub inline fn length(w: *const Wall) f64 {
        return w.points[1].sub(w.points[0]).len();
    }

    pub inline fn center(w: *const Wall) Vec2 {
        return w.points[0].mean(w.points[1]);
    }
};

pub const Kind = enum { poly, theta, voronoi, aperiodic };

pub const Dimension = struct {
    xmin: f64 = 9E9,
    ymin: f64 = 9E9,
    xmax: f64 = -9E9,
    ymax: f64 = -9E9,

    pub fn addPoint(d: *Dimension, p: Vec2) void {
        d.xmin = @min(p.x, d.xmin);
        d.xmax = @max(p.x, d.xmax);
        d.ymin = @min(p.y, d.ymin);
        d.ymax = @max(p.y, d.ymax);
    }
};

pub const Cave = struct { cell: *Cell, type: u8 };

/// number of lettered cell types (A-Z)
pub const MAX_TYPES = 26;
pub const NO_LIMIT: u8 = 255;

pub const Maze = struct {
    /// All memory of the maze lives in this arena.
    arena: std.heap.ArenaAllocator,
    kind: Kind = .poly,
    tileable: bool = false,
    structure: *const Structure,
    rows: i32 = 0,
    columns: i32 = 0,
    /// `n_cells + 1` entries; the cell behind the last one is the "off" cell
    /// representing everything outside of the maze.
    cells: []Cell = &.{},
    n_cells: usize = 0,
    off: *Cell = undefined,
    /// capacity of the wall array; `n_walls` are in use
    walls: []Wall = &.{},
    n_walls: usize = 0,
    n_valid: usize = 0,
    entrance: ?*Cell = null,
    exit: ?*Cell = null,
    rand: *rng.Random,
    /// cave cells (`--cave`) with their original types
    caves: std.ArrayListUnmanaged(Cave) = .empty,
    /// maximum number of openings per cell type (`--max-openings`),
    /// `NO_LIMIT` for none; only used if `has_limits`
    max_open: [MAX_TYPES]u8 = @splat(NO_LIMIT),
    has_limits: bool = false,

    pub fn alloc(self: *Maze) Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Maze) void {
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self);
    }

    pub inline fn cell(self: *Maze, i: usize) *Cell {
        return &self.cells[i];
    }

    pub inline fn wall(self: *Maze, i: usize) *Wall {
        return &self.walls[i];
    }

    /// The i-th wall of a cell (`i` wraps around).
    pub inline fn cellWall(self: *Maze, c: *const Cell, i: usize) *Wall {
        return &self.walls[c.wallIdx(i)];
    }

    pub inline fn neighbour(self: *Maze, c: *const Cell, i: usize) *Cell {
        return self.cellWall(c, i).other(c);
    }

    pub inline fn isOpen(self: *Maze, c: *const Cell, i: usize) bool {
        return self.cellWall(c, i).isOpen();
    }

    pub fn allocCells(self: *Maze, n: usize) !void {
        self.cells = try self.alloc().alloc(Cell, n + 1);
        @memset(self.cells, .{});
        self.n_cells = n;
    }

    /// Allocates `n` walls; numbers them but leaves `n_walls` at `n`.
    pub fn allocWalls(self: *Maze, n: usize) !void {
        self.walls = try self.alloc().alloc(Wall, n + 1);
        for (self.walls, 0..) |*w, i| {
            w.* = .{ .no = @intCast(i), .cells = .{ self.off, self.off } };
        }
        self.n_walls = n;
    }

    /// Takes the next unused wall (voronoi construction) and returns its
    /// index. The wall array may be reallocated, so pointers to walls must
    /// not be held across this call.
    pub fn newWall(self: *Maze) !u32 {
        if (self.n_walls >= self.walls.len) {
            const nw = try self.alloc().alloc(Wall, self.walls.len * 2 + 16);
            @memcpy(nw[0..self.walls.len], self.walls);
            for (nw[self.walls.len..], self.walls.len..) |*w, i| {
                w.* = .{ .no = @intCast(i), .cells = .{ self.off, self.off } };
            }
            self.walls = nw;
        }
        const idx: u32 = @intCast(self.n_walls);
        const w = &self.walls[idx];
        w.no = idx;
        w.state = .closed;
        self.n_walls += 1;
        return idx;
    }

    pub fn addWallIdx(self: *Maze, c: *Cell, idx: u32) !void {
        try c.walls.append(self.alloc(), idx);
    }

    /// Initialises the "off" cell behind the last regular cell.
    pub fn setupOff(self: *Maze) void {
        const o = &self.cells[self.n_cells];
        o.* = .{
            .type = TYPE_OFF,
            .mark = MARK_OUT | MARK_VISITED,
            .no = -1,
            .center = .{ .x = std.math.floatMax(f64), .y = std.math.floatMax(f64) },
        };
        self.off = o;
    }

    pub fn clearCellMarks(self: *Maze) void {
        for (self.cells[0..self.n_cells]) |*c| {
            if (c.valid()) c.mark = MARK_NONE;
        }
    }

    pub fn clearWallMarks(self: *Maze) void {
        for (self.walls[0..self.n_walls]) |*w| w.mark = MARK_NONE;
    }

    pub fn clearMarks(self: *Maze) void {
        self.clearCellMarks();
        self.clearWallMarks();
    }

    pub fn clearUserData(self: *Maze) void {
        for (self.cells[0..self.n_cells]) |*c| c.user_data = 0;
    }

    /// Cell at the given column/row; wraps around for tileable mazes.
    pub fn cell2D(self: *Maze, column: i32, row: i32) *Cell {
        if (column >= 0 and column < self.columns and row >= 0 and row < self.rows) {
            return &self.cells[@intCast(row * self.columns + column)];
        } else if (self.tileable) {
            const r = @mod(row, self.rows);
            const c = @mod(column, self.columns);
            return &self.cells[@intCast(r * self.columns + c)];
        }
        return self.off;
    }

    /// Follows the idx-th wall of `c` if it is passable and the neighbour
    /// could be marked with `mark`.
    pub fn go(self: *Maze, c: *Cell, idx: usize, mark: u8) ?*Cell {
        const w = self.cellWall(c, idx);
        const n = w.other(c);
        if ((w.isBridged() or w.isOpen()) and n.checkNMark(mark, mark)) {
            return n;
        }
        return null;
    }

    /// Sets the maximum number of openings for the cell types (`NO_LIMIT`
    /// for none).
    pub fn setLimits(self: *Maze, limits: [MAX_TYPES]u8) void {
        self.max_open = limits;
        self.has_limits = false;
        for (limits) |l| {
            if (l != NO_LIMIT) self.has_limits = true;
        }
    }

    /// Maximum number of openings of a cell (`NO_LIMIT` if unlimited).
    pub fn openLimit(self: *const Maze, c: *const Cell) u8 {
        if (!self.has_limits or !c.valid()) return NO_LIMIT;
        const t = c.type & ~TYPE_CROSSABLE;
        return if (t < MAX_TYPES) self.max_open[t] else NO_LIMIT;
    }

    /// Whether another wall of `c` may be opened (`--max-openings`).
    pub fn canOpen(self: *Maze, c: *const Cell) bool {
        const limit = self.openLimit(c);
        if (limit == NO_LIMIT) return true;
        var n: usize = 0;
        for (0..c.nWalls()) |i| {
            if (!self.cellWall(c, i).isClosed() or self.cellWall(c, i).isBridged()) n += 1;
        }
        return n < limit;
    }

    /// Number of passable walls of a cell; `first_idx` receives the index
    /// of the first one.
    pub fn openings(self: *Maze, c: *Cell, first_idx: *usize) usize {
        var n: usize = 0;
        if (c.valid()) {
            for (0..c.nWalls()) |i| {
                const w = self.cellWall(c, i);
                if (w.isOpen() or w.isBridged()) {
                    if (n == 0) first_idx.* = i;
                    n += 1;
                }
            }
        }
        return n;
    }

    /// Finds the wall of `c` connected to the point `idx` of `wall` and
    /// replaces `wall`/`idx` with it. Returns whether the new wall is
    /// passable.
    pub fn connectedWall(self: *Maze, c: *Cell, wall_: **Wall, idx: *usize) bool {
        const p = wall_.*.points[idx.*];
        for (0..c.nWalls()) |i| {
            const n = self.cellWall(c, i);
            if (n != wall_.*) {
                if (p.equal(n.points[0])) {
                    wall_.* = n;
                    idx.* = 1;
                    break;
                } else if (p.equal(n.points[1])) {
                    wall_.* = n;
                    idx.* = 0;
                    break;
                }
            }
        }
        return wall_.*.isOpen() or wall_.*.isBridged();
    }

    pub fn dimension(self: *Maze) Dimension {
        return switch (self.kind) {
            .poly => self.polyDimension(),
            .theta => blk: {
                const r: f64 = @floatFromInt(self.rows);
                break :blk .{ .xmin = -r - 2, .xmax = r + 2, .ymin = -r - 2, .ymax = r + 2 };
            },
            .voronoi, .aperiodic => self.cellWallsDimension(),
        };
    }

    fn polyDimension(self: *Maze) Dimension {
        var dim: Dimension = .{};
        const s = self.structure;
        if (!self.tileable) {
            for (self.walls[0..self.n_walls]) |*w| {
                dim.addPoint(w.points[0]);
                dim.addPoint(w.points[1]);
            }
        } else {
            for (self.cells[0..self.n_cells]) |*c| dim.addPoint(c.center);
            dim.xmin += s.xminadd;
            dim.xmax += s.xmaxadd;
            dim.ymin += s.yminadd;
            dim.ymax += s.ymaxadd;
        }
        return dim;
    }

    /// Bounding box of the walls of all valid cells.
    fn cellWallsDimension(self: *Maze) Dimension {
        var dim: Dimension = .{};
        for (self.cells[0..self.n_cells]) |*c| {
            if (!c.valid()) continue;
            for (0..c.nWalls()) |j| {
                const w = self.cellWall(c, j);
                dim.addPoint(w.points[0]);
                dim.addPoint(w.points[1]);
            }
        }
        return dim;
    }

    /// Width of a tileable maze (in cell units).
    pub fn tileWidth(self: *Maze) f64 {
        const s = self.structure;
        return @as(f64, @floatFromInt(@divTrunc(self.columns, s.columns))) * s.width;
    }

    /// Height of a tileable maze (in cell units).
    pub fn tileHeight(self: *Maze) f64 {
        const s = self.structure;
        return @as(f64, @floatFromInt(@divTrunc(self.rows, s.rows))) * s.height;
    }

    /// Removes all cells which are masked out.
    pub fn applyMask(self: *Maze, params: *const Params) void {
        const mask = params.mask orelse return;
        const dim = self.dimension();
        const w = dim.xmax - dim.xmin;
        const h = dim.ymax - dim.ymin;
        for (self.cells[0..self.n_cells]) |*c| {
            if (!mask.query((c.center.x - dim.xmin) / w, (c.center.y - dim.ymin) / h)) {
                c.type = TYPE_OFF;
                _ = c.visit();
            }
        }
    }

    pub fn countValid(self: *Maze) void {
        var n: usize = 0;
        for (self.cells[0..self.n_cells]) |*c| {
            if (c.valid()) n += 1;
        }
        self.n_valid = n;
    }
};

/// Creates an empty maze object.
pub fn create(gpa: Allocator, params: *const Params, rand: *rng.Random) !*Maze {
    const m = try gpa.create(Maze);
    m.* = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .structure = params.structure,
        .rand = rand,
    };
    return m;
}

/// Builds a maze according to the structure given in `params`.
pub fn newMaze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    const theta = @import("theta.zig");
    const voronoi = @import("voronoi.zig");
    const penrose = @import("penrose.zig");
    const hat = @import("hat.zig");
    const ammann = @import("ammann.zig");
    const stepped = @import("stepped.zig");
    const shield = @import("shield.zig");
    const socolar = @import("socolar.zig");
    const clamshell = @import("clamshell.zig");
    const rotational = @import("rotational.zig");
    const recursive = @import("recursive.zig");
    const m = switch (params.structure.construct) {
        .periodic => if (params.recursion > 0 and recursive.Kind.of(params.structure) != null)
            try recursive.newRecursiveMaze(gpa, params, rand)
        else
            try newPeriodicMaze(gpa, params, rand),
        .theta => try theta.newThetaMaze(gpa, params, rand),
        .voronoi => try voronoi.newVoronoiMaze(gpa, params, rand),
        .voronoi4 => try voronoi.newVoronoi4Maze(gpa, params, rand),
        .voronoi6 => try voronoi.newVoronoi6Maze(gpa, params, rand),
        .voronoi3 => try voronoi.newVoronoi3Maze(gpa, params, rand),
        .voronoi_disc => try voronoi.newVoronoiDiscMaze(gpa, params, rand),
        .penrose => try penrose.newPenroseMaze(gpa, params, rand),
        .penrose_rhombs => try penrose.newPenroseRhombMaze(gpa, params, rand),
        .einstein => try hat.newHatMaze(gpa, params, rand),
        .ammann_beenker => try ammann.newAmmannBeenkerMaze(gpa, params, rand),
        .supergolden => try stepped.newSupergoldenMaze(gpa, params, rand),
        .shield => try shield.newShieldMaze(gpa, params, rand),
        .wheel => try shield.newWheelMaze(gpa, params, rand),
        .socolar => try socolar.newSocolarMaze(gpa, params, rand),
        .clamshell => try clamshell.newClamshellMaze(gpa, params, rand),
        .pentagonal_rotational => try rotational.newRotationalMaze(gpa, params, rand),
    };
    m.countValid();
    return m;
}

/// Builds a maze from a periodic tile structure.
pub fn newPeriodicMaze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    const s = params.structure;
    if (params.tileable) {
        var n = @rem(params.rows, s.rows);
        if (n != 0) {
            params.rows += s.rows - n;
            std.log.info("increasing no of rows to {d}", .{params.rows});
        }
        n = @rem(params.columns, s.columns);
        if (n != 0) {
            params.columns += s.columns - n;
            std.log.info("increasing no of columns to {d}", .{params.columns});
        }
    }
    const m = try create(gpa, params, rand);
    errdefer m.deinit();
    m.kind = .poly;
    m.tileable = params.tileable;
    m.columns = params.columns;
    m.rows = params.rows;
    try m.allocCells(@intCast(m.rows * m.columns));
    m.setupOff();
    initCells(m);
    const no_walls = countWalls(m);
    try m.allocWalls(no_walls);
    try connectCells(m);
    m.applyMask(params);
    return m;
}

fn initCells(m: *Maze) void {
    const s = m.structure;
    var n: usize = 0;
    var no: i32 = 0;
    var y: i32 = 0;
    while (y < m.rows) : (y += 1) {
        const qy = @divTrunc(y, s.rows);
        const ry: usize = @intCast(@rem(y, s.rows));
        var x: i32 = 0;
        while (x < m.columns) : (x += 1) {
            const qx = @divTrunc(x, s.columns);
            const rx: usize = @intCast(@rem(x, s.columns));
            const c = &m.cells[n];
            n += 1;
            const kind = s.cellType(rx, ry);
            c.type = kind;
            if (kind != TYPE_NONE) {
                c.no = no;
                no += 1;
                const ctr = s.center(rx, ry);
                c.center.x = @as(f64, @floatFromInt(qx)) * s.width + ctr.x;
                c.center.y = @as(f64, @floatFromInt(qy)) * s.height + ctr.y;
            }
        }
    }
}

fn nNeighbours(s: *const Structure, kind: u8) usize {
    if (kind == TYPE_NONE) return 0;
    return s.border(kind).len;
}

fn countWalls(m: *Maze) usize {
    const s = m.structure;
    var n: usize = 0;
    var no_walls: usize = 0;
    var y: i32 = 0;
    while (y < m.rows) : (y += 1) {
        var x: i32 = 0;
        while (x < m.columns) : (x += 1) {
            const c = &m.cells[n];
            n += 1;
            const kind = c.type;
            for (0..nNeighbours(s, kind)) |i| {
                const nb = s.border(kind)[i];
                const other = m.cell2D(x + nb.dx, y + nb.dy);
                no_walls += if (other.valid()) 1 else 2;
            }
        }
    }
    std.debug.assert(no_walls & 1 == 0);
    return no_walls / 2;
}

fn connectCells(m: *Maze) !void {
    const s = m.structure;
    var n: usize = 0;
    var no: u32 = 0;
    var y: i32 = 0;
    // A wall shared with a neighbour is created by whichever of the two
    // cells is processed first; the other one looks it up.
    const processed = try m.alloc().alloc(bool, m.n_cells);
    @memset(processed, false);
    while (y < m.rows) : (y += 1) {
        var x: i32 = 0;
        while (x < m.columns) : (x += 1) {
            const cur = &m.cells[n];
            processed[n] = true;
            n += 1;
            const kind = cur.type;
            const nn = nNeighbours(s, kind);
            try cur.walls.resize(m.alloc(), nn);
            @memset(cur.walls.items, 0);
            for (0..nn) |i| {
                const nb = s.border(kind)[i];
                const other = m.cell2D(x + nb.dx, y + nb.dy);
                const other_processed = other != m.off and
                    processed[(@intFromPtr(other) - @intFromPtr(m.cells.ptr)) / @sizeOf(Cell)];
                if (other_processed) {
                    for (other.walls.items) |wi| {
                        const w = &m.walls[wi];
                        if (cur == w.secondary()) {
                            cur.walls.items[i] = wi;
                            break;
                        }
                    }
                } else {
                    const w = &m.walls[no];
                    w.no = no;
                    cur.walls.items[i] = no;
                    w.state = .closed;
                    w.mark = MARK_NONE;
                    w.cells = .{ cur, other };
                    w.features = nb.features;
                    w.value = nb.value;
                    w.points[0] = nb.p1.add(cur.center);
                    w.points[1] = nb.p2.add(cur.center);
                    no += 1;
                }
            }
        }
    }
}
