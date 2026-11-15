//! Builds a maze from an arbitrary set of polygonal tiles (used by the
//! aperiodic tilings). Tiles are given by vertex ids; tiles sharing an edge
//! (same two vertex ids) become neighbours.

const std = @import("std");
const geo = @import("geo.zig");
const mz = @import("maze.zig");
const rng = @import("rng.zig");

const Allocator = std.mem.Allocator;
const Vec2 = geo.Vec2;
const Maze = mz.Maze;
const Params = mz.Params;

/// Merges vertices which are numerically identical (within `TOL`).
pub const PointSet = struct {
    const CELL: f64 = 1e-6;
    const TOL: f64 = 1e-7;

    points: std.ArrayListUnmanaged(Vec2) = .empty,
    grid: std.AutoHashMapUnmanaged([2]i64, u32) = .empty,

    fn bucket(p: Vec2) [2]i64 {
        return .{ @intFromFloat(@floor(p.x / CELL)), @intFromFloat(@floor(p.y / CELL)) };
    }

    /// Returns the id of the point, adding it if it is new.
    pub fn id(self: *PointSet, gpa: Allocator, p: Vec2) !u32 {
        const b = bucket(p);
        var dx: i64 = -1;
        while (dx <= 1) : (dx += 1) {
            var dy: i64 = -1;
            while (dy <= 1) : (dy += 1) {
                if (self.grid.get(.{ b[0] + dx, b[1] + dy })) |i| {
                    const q = self.points.items[i];
                    if (@abs(q.x - p.x) < TOL and @abs(q.y - p.y) < TOL) return i;
                }
            }
        }
        const i: u32 = @intCast(self.points.items.len);
        try self.points.append(gpa, p);
        try self.grid.put(gpa, b, i);
        return i;
    }
};

pub const Tile = struct {
    /// cell type
    type: u8 = mz.TYPE_A,
    /// vertex ids in order around the tile; consecutive vertices must be
    /// the end points of edges shared completely with a neighbour
    verts: []const u32,
    center: Vec2,
};

inline fn edgeKey(a: u32, b: u32) [2]u32 {
    return if (a < b) .{ a, b } else .{ b, a };
}

const NONE = std.math.maxInt(u32);

/// Builds the maze from the tiles. Only the largest group of tiles connected
/// by edges is used (tiles touching the rest only at a corner would be
/// unreachable). Consecutive collinear edges with the same neighbour are
/// merged into one wall.
pub fn buildMaze(gpa: Allocator, params: *Params, rand: *rng.Random, points: []const Vec2, tiles: []const Tile) !*Maze {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const tmp = arena_state.allocator();

    // edge -> the (up to two) tiles using it
    var edge_tiles: std.AutoHashMapUnmanaged([2]u32, [2]u32) = .empty;
    for (tiles, 0..) |tile, ti| {
        const n = tile.verts.len;
        for (0..n) |i| {
            const gop = try edge_tiles.getOrPut(tmp, edgeKey(tile.verts[i], tile.verts[(i + 1) % n]));
            if (gop.found_existing) gop.value_ptr[1] = @intCast(ti) else gop.value_ptr.* = .{ @intCast(ti), NONE };
        }
    }
    const Edges = @TypeOf(edge_tiles);
    const other = struct {
        fn f(et: *const Edges, a: u32, b: u32, me: u32) u32 {
            const e = et.get(edgeKey(a, b)).?;
            return if (e[0] == me) e[1] else e[0];
        }
    }.f;

    // connected components
    const comp = try tmp.alloc(u32, tiles.len);
    @memset(comp, 0);
    var best_comp: u32 = 0;
    var best_size: usize = 0;
    {
        var stack: std.ArrayListUnmanaged(u32) = .empty;
        var ncomp: u32 = 0;
        for (tiles, 0..) |_, ti| {
            if (comp[ti] != 0) continue;
            ncomp += 1;
            comp[ti] = ncomp;
            var size: usize = 0;
            try stack.append(tmp, @intCast(ti));
            while (stack.pop()) |cur| {
                size += 1;
                const vs = tiles[cur].verts;
                for (0..vs.len) |i| {
                    const o = other(&edge_tiles, vs[i], vs[(i + 1) % vs.len], cur);
                    if (o != NONE and comp[o] == 0) {
                        comp[o] = ncomp;
                        try stack.append(tmp, o);
                    }
                }
            }
            if (size > best_size) {
                best_size = size;
                best_comp = ncomp;
            }
        }
    }
    if (best_size == 0) return error.EmptyMaze;

    // cells
    const m = try mz.create(gpa, params, rand);
    errdefer m.deinit();
    m.kind = .aperiodic;
    m.tileable = false;
    m.rows = params.rows;
    m.columns = params.columns;
    try m.allocCells(best_size);
    m.setupOff();
    const cell_of = try tmp.alloc(u32, tiles.len);
    var max_walls: usize = 0;
    var no: u32 = 0;
    for (tiles, 0..) |tile, ti| {
        if (comp[ti] != best_comp) {
            cell_of[ti] = NONE;
            continue;
        }
        cell_of[ti] = no;
        const c = &m.cells[no];
        c.no = @intCast(no);
        c.type = tile.type;
        c.center = tile.center;
        max_walls += tile.verts.len;
        no += 1;
    }

    // walls
    try m.allocWalls(max_walls);
    var walls: std.AutoHashMapUnmanaged([2]u32, u32) = .empty;
    var nw: u32 = 0;
    for (tiles, 0..) |tile, ti| {
        if (cell_of[ti] == NONE) continue;
        const c = &m.cells[cell_of[ti]];
        const vs = tile.verts;
        const n = vs.len;
        // neighbour cell (or NONE) and direction of every edge
        const nbs = try tmp.alloc(u32, n);
        const dirs = try tmp.alloc(Vec2, n);
        for (0..n) |i| {
            const o = other(&edge_tiles, vs[i], vs[(i + 1) % n], @intCast(ti));
            nbs[i] = if (o == NONE) NONE else cell_of[o];
            dirs[i] = points[vs[(i + 1) % n]].sub(points[vs[i]]);
        }
        const sameRun = struct {
            fn f(nb: []const u32, d: []const Vec2, i: usize, j: usize) bool {
                return nb[i] == nb[j] and d[i].colinear(d[j]) and d[i].x * d[j].x + d[i].y * d[j].y > 0;
            }
        }.f;
        // start at an edge beginning a run
        var start: usize = 0;
        for (0..n) |i| {
            if (!sameRun(nbs, dirs, (i + n - 1) % n, i)) {
                start = i;
                break;
            }
        }
        var k: usize = 0;
        while (k < n) {
            const first = (start + k) % n;
            var len: usize = 1;
            while (k + len < n and sameRun(nbs, dirs, first, (start + k + len) % n)) len += 1;
            const a = vs[first];
            const b = vs[(start + k + len) % n];
            const gop = try walls.getOrPut(tmp, edgeKey(a, b));
            if (gop.found_existing) {
                m.walls[gop.value_ptr.*].cells[1] = c;
            } else {
                gop.value_ptr.* = nw;
                m.walls[nw] = .{ .no = nw, .cells = .{ c, m.off }, .points = .{ points[a], points[b] } };
                nw += 1;
            }
            try m.addWallIdx(c, gop.value_ptr.*);
            k += len;
        }
    }
    m.n_walls = nw;
    m.applyMask(params);
    return m;
}
