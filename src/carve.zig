//! Maze carving algorithms (recursive backtracker, Prim, growing tree,
//! Wilson),
//! crossover construction and the search for entrance and exit.
//!
//! The recursive algorithms of the original are implemented with explicit
//! stacks (same visiting order, so the same seed gives the same maze) to
//! avoid stack overflows on big mazes.

const std = @import("std");
const mz = @import("maze.zig");
const geo = @import("geo.zig");

const Allocator = std.mem.Allocator;
const Maze = mz.Maze;
const Cell = mz.Cell;
const Wall = mz.Wall;
const Params = mz.Params;

pub const CarveError = error{ OutOfMemory, NoEntrance, NoExit, NoValidCell, LimitUnsatisfiable };

const FAIL_MAX = 100;

const Carver = struct {
    m: *Maze,
    params: *const Params,
    gpa: Allocator,

    inline fn direction(self: *Carver, c: *const Cell) usize {
        return self.m.rand.below(c.nWalls());
    }

    /// The direction weights of the cell's type, if any were given.
    fn weightsFor(self: *const Carver, c: *const Cell) ?[]const f64 {
        const t = c.type & ~mz.TYPE_CROSSABLE;
        const ws = self.params.weights;
        if (t >= ws.len or ws[t].len == 0 or ws[t].len != c.nWalls()) return null;
        return ws[t];
    }

    /// Chooses one of the directions in `avail` (bit mask) with probability
    /// proportional to its weight. Directions with weight 0 are only chosen
    /// (with equal probability) if no other direction is left.
    fn pickWeighted(self: *Carver, w: []const f64, avail: u64) ?usize {
        if (avail == 0) return null;
        var sum: f64 = 0;
        var zeros: usize = 0;
        for (w, 0..) |x, i| {
            if (avail & bit(i) == 0) continue;
            sum += x;
            if (x == 0) zeros += 1;
        }
        if (sum > 0) {
            var r = self.m.rand.unit() * sum;
            var last: usize = 0;
            for (w, 0..) |x, i| {
                if (avail & bit(i) == 0 or x == 0) continue;
                if (r < x) return i;
                r -= x;
                last = i;
            }
            return last; // rounding
        }
        var k = self.m.rand.below(zeros);
        for (0..w.len) |i| {
            if (avail & bit(i) == 0) continue;
            if (k == 0) return i;
            k -= 1;
        }
        unreachable;
    }

    /// Tries the directions of `c` in weighted random order and breaks the
    /// first wall that can be broken; returns the neighbour.
    fn digWeighted(self: *Carver, c: *Cell, w: []const f64) ?*Cell {
        var avail = allDirections(w.len);
        while (self.pickWeighted(w, avail)) |i| {
            avail &= ~bit(i);
            if (dig(self.m, c, i)) |n| return n;
        }
        return null;
    }
};

inline fn bit(i: usize) u64 {
    return @as(u64, 1) << @intCast(i);
}

inline fn allDirections(n: usize) u64 {
    return if (n >= 64) ~@as(u64, 0) else bit(n) - 1;
}

/// Parses direction weights (`-W`) like "A:0,1,2,1/B:1,1,2,2,1,1": for
/// each cell type of the structure one weight per wall (neighbour), in the
/// order of the structure tables. Weights must not be negative and not all
/// be 0. Returns the weights indexed by cell type.
pub fn parseWeights(gpa: Allocator, s: *const mz.Structure, arg: []const u8) ![]const []const f64 {
    const n_types = s.neighbours.len;
    if (n_types == 0) return error.NoCellTypes;
    const res = try gpa.alloc([]const f64, n_types);
    @memset(res, &.{});
    var it = std.mem.splitScalar(u8, arg, '/');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " ");
        if (p.len < 3 or p[1] != ':') return error.InvalidSyntax;
        const letter = std.ascii.toUpper(p[0]);
        if (letter < 'A' or letter - 'A' >= n_types) return error.UnknownCellType;
        const t = letter - 'A';
        if (res[t].len != 0) return error.DuplicateCellType;
        const n_walls = s.neighbours[t].len;
        const ws = try gpa.alloc(f64, n_walls);
        var vals = std.mem.splitScalar(u8, p[2..], ',');
        var k: usize = 0;
        var sum: f64 = 0;
        while (vals.next()) |v| : (k += 1) {
            if (k >= n_walls) return error.WrongNumberOfWeights;
            const x = std.fmt.parseFloat(f64, std.mem.trim(u8, v, " ")) catch return error.InvalidSyntax;
            if (!(x >= 0) or std.math.isInf(x)) return error.InvalidWeight;
            ws[k] = x;
            sum += x;
        }
        if (k != n_walls) return error.WrongNumberOfWeights;
        if (sum == 0) return error.InvalidWeight;
        res[t] = ws;
    }
    return res;
}

fn randomBegin(m: *Maze) CarveError!*Cell {
    if (m.n_valid == 0) return error.NoValidCell;
    var n = m.rand.below(m.n_cells);
    var c = m.cell(n);
    while (!c.valid()) {
        n = (n + 1) % m.n_cells;
        c = m.cell(n);
    }
    m.entrance = c;
    return c;
}

/// Breaks the idx-th wall of `c` if possible and returns the neighbour.
fn dig(m: *Maze, c: *Cell, idx: usize) ?*Cell {
    const w = m.cellWall(c, idx);
    if (w.isClosed() and w.breakable() and !w.isBridged()) {
        const n = w.other(c);
        if (n.valid() and (n.mark & (mz.MARK_VISITED | mz.MARK_TAINTED)) == 0 and m.canOpen(c) and m.canOpen(n)) {
            n.mark |= mz.MARK_VISITED;
            w.state = .open;
            return n;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// crossovers

/// Finds the wall opposite to the idx-th wall of a cell.
fn findVisAVis(m: *Maze, c: *Cell, idx_: usize) ?usize {
    var idx = idx_;
    const ctr = c.center;
    const v1 = m.cellWall(c, idx).center().sub(ctr);
    idx += 1;
    for (0..c.nWalls()) |_| {
        const v2 = m.cellWall(c, idx).center().sub(ctr);
        if (v1.colinear(v2)) return idx;
        idx += 1;
    }
    return null;
}

fn doCrossing(m: *Maze, c: *Cell, idx1: usize, idx2: usize) void {
    const w1 = m.cellWall(c, idx1);
    if (w1.primary() == c) std.mem.swap(*Cell, &w1.cells[0], &w1.cells[1]);
    const w2 = m.cellWall(c, idx2);
    if (w2.primary() == c) std.mem.swap(*Cell, &w2.cells[0], &w2.cells[1]);
    w1.state = .bridged;
    w2.state = .bridged;
    w1.cells[1] = w2.primary();
    w2.cells[1] = w1.primary();
}

fn crossable(m: *Maze, c: *Cell) bool {
    var n: usize = 0;
    // bridges would add openings to cells with a limit (--max-openings)
    if (c.valid() and (c.type & mz.TYPE_CROSSABLE) != 0 and m.openLimit(c) == mz.NO_LIMIT) {
        for (0..c.nWalls()) |i| {
            const w = m.cellWall(c, i);
            if (!w.bridgeable() or !w.other(c).valid() or m.openLimit(w.other(c)) != mz.NO_LIMIT) {
                n = 0;
                break;
            }
            n += 1;
        }
    }
    return n >= 4;
}

/// Union-find over the cells connected by bridges: bridges are passages from
/// the start, so they must not form a loop on their own.
const BridgeSets = struct {
    parent: []u32,

    fn init(gpa: Allocator, n: usize) !BridgeSets {
        const p = try gpa.alloc(u32, n);
        for (p, 0..) |*x, i| x.* = @intCast(i);
        return .{ .parent = p };
    }

    fn find(self: *BridgeSets, x_: u32) u32 {
        var x = x_;
        while (self.parent[x] != x) {
            self.parent[x] = self.parent[self.parent[x]];
            x = self.parent[x];
        }
        return x;
    }
};

fn cellIndex(m: *const Maze, c: *const Cell) u32 {
    return @intCast((@intFromPtr(c) - @intFromPtr(m.cells.ptr)) / @sizeOf(Cell));
}

fn buildCrossovers(cv: *Carver) !void {
    const m = cv.m;
    const crossings = cv.params.crossings;
    if (crossings <= 0) return;
    var sets = try BridgeSets.init(cv.gpa, m.n_cells);
    defer cv.gpa.free(sets.parent);
    const nvalid: f64 = @floatFromInt(m.n_valid);
    var ncrossings: usize = @intFromFloat(if (crossings > 0.5) @round(crossings) else nvalid * crossings);
    if (ncrossings > m.n_valid / 2) {
        std.log.warn("number of crossings to high ({d})! limiting to {d}.", .{ ncrossings, m.n_valid / 2 });
        ncrossings = m.n_valid / 2;
    }
    var failures: usize = 0;
    for (0..ncrossings) |built| {
        var build = false;
        while (!build and failures < FAIL_MAX) {
            failures += 1;
            const c = m.cell(m.rand.below(m.n_cells));
            if (!crossable(m, c)) continue;
            var widx: [5]usize = undefined;
            var wi: usize = 0;
            var dir = cv.direction(c);
            for (0..c.nWalls()) |_| {
                const w = m.cellWall(c, dir);
                if (w.bridgeable()) {
                    widx[wi] = dir;
                    wi += 1;
                    if (findVisAVis(m, c, dir)) |v| {
                        widx[wi] = v;
                        wi += 1;
                    } else {
                        wi -= 1;
                    }
                    if (wi >= 4) break;
                }
                dir += 1;
            }
            if (wi >= 4) {
                // the cells the two bridges would connect
                var r: [4]u32 = undefined;
                for (&r, widx[0..4]) |*x, i| x.* = sets.find(cellIndex(m, m.cellWall(c, i).other(c)));
                if (r[0] == r[1] or r[2] == r[3] or
                    (r[0] == r[2] and r[1] == r[3]) or (r[0] == r[3] and r[1] == r[2])) continue;
                sets.parent[r[0]] = r[1];
                sets.parent[sets.find(r[2])] = sets.find(r[3]);
                build = true;
                doCrossing(m, c, widx[0], widx[1]);
                doCrossing(m, c, widx[2], widx[3]);
                c.type = mz.TYPE_CROSSOVER;
                failures = 0;
            }
        }
        if (failures >= FAIL_MAX) {
            std.log.warn("cannot build as many crossovers as desired, built {d} of {d}", .{ built, ncrossings });
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// recursive backtracker

fn taintBridgedNeighbours(m: *Maze, c: *Cell) void {
    for (0..c.nWalls()) |i| {
        if (m.go(c, i, mz.MARK_TAINTED)) |cur| taintBridgedNeighbours(m, cur);
    }
}

const StepFrame = struct {
    cell: *Cell,
    /// next direction to try (unweighted)
    idx: usize,
    /// number of directions tried
    i: usize,
    /// directions tried (weighted)
    tried: u64 = 0,
};

fn backtracker(cv: *Carver) CarveError!void {
    const m = cv.m;
    m.clearMarks();
    try buildCrossovers(cv);
    const start = try randomBegin(m);
    if (!start.visit()) return;
    try backtrackFrom(cv, start);
}

/// The backtracker starting at the (visited) cell `start`.
fn backtrackFrom(cv: *Carver, start: *Cell) CarveError!void {
    const m = cv.m;
    var stack: std.ArrayListUnmanaged(StepFrame) = .empty;
    defer stack.deinit(cv.gpa);
    try pushStep(cv, &stack, start);
    while (stack.items.len > 0) {
        const f = &stack.items[stack.items.len - 1];
        if (f.i >= f.cell.nWalls()) {
            _ = stack.pop();
            continue;
        }
        const c = f.cell;
        var idx = f.idx;
        if (cv.weightsFor(c)) |w| {
            idx = cv.pickWeighted(w, allDirections(w.len) & ~f.tried).?;
            f.tried |= bit(idx);
        } else {
            f.idx += 1;
        }
        f.i += 1;
        const cur = m.go(c, idx, mz.MARK_VISITED) orelse dig(m, c, idx);
        if (cur) |n| try pushStep(cv, &stack, n);
    }
}

fn pushStep(cv: *Carver, stack: *std.ArrayListUnmanaged(StepFrame), c: *Cell) !void {
    // weighted cells choose their directions one by one
    const idx = if (cv.weightsFor(c) == null) cv.direction(c) else 0;
    c.mark |= mz.MARK_TAINTED;
    taintBridgedNeighbours(cv.m, c);
    try stack.append(cv.gpa, .{ .cell = c, .idx = idx, .i = 0 });
}

// ---------------------------------------------------------------------------
// Prim's algorithm

fn addFrontiersFor(cv: *Carver, coll: *std.ArrayListUnmanaged(*Cell), c: *Cell) !void {
    const m = cv.m;
    const otype = c.type;
    c.type = mz.TYPE_TMP;
    defer c.type = otype;
    for (0..c.nWalls()) |i| {
        const w = m.cellWall(c, i);
        if (w.isBridged()) {
            if (m.go(c, i, mz.MARK_NONE)) |n| {
                if (n.valid()) try addFrontiersFor(cv, coll, n);
            }
        } else {
            const n = w.other(c);
            if (n.valid() and (n.mark & (mz.MARK_VISITED | mz.MARK_FRONTIER)) == 0) {
                n.mark = mz.MARK_FRONTIER;
                try coll.append(cv.gpa, n);
            }
        }
    }
}

fn addPrimNeighbours(m: *Maze, c: *Cell) void {
    c.mark = mz.MARK_VISITED;
    for (0..c.nWalls()) |i| {
        const w = m.cellWall(c, i);
        if (w.isBridged()) {
            if (m.go(c, i, mz.MARK_NONE)) |n| {
                if (n.mark & mz.MARK_VISITED == 0) addPrimNeighbours(m, n);
            }
        }
    }
}

/// Removes the frontier mark: the cell can be added again by another
/// neighbour.
fn dropFrontier(c: *Cell) void {
    c.mark &= ~mz.MARK_FRONTIER;
}

fn prim(cv: *Carver) CarveError!void {
    const m = cv.m;
    m.clearMarks();
    try buildCrossovers(cv);
    // after building the crossovers: the start must not become one
    var cur = try randomBegin(m);
    var coll: std.ArrayListUnmanaged(*Cell) = .empty;
    defer coll.deinit(cv.gpa);
    var carved = true;
    while (true) {
        if (carved) {
            addPrimNeighbours(m, cur);
            try addFrontiersFor(cv, &coll, cur);
        }
        carved = false;
        if (coll.items.len == 0) break;
        const idx = m.rand.below(coll.items.len);
        cur = coll.items[idx];
        if (cur.mark & mz.MARK_FRONTIER != 0) {
            if (cv.weightsFor(cur)) |w| {
                // connect to the visited part through a weighted direction
                var avail: u64 = 0;
                for (0..cur.nWalls()) |i| {
                    const wl = m.cellWall(cur, i);
                    const n = wl.other(cur);
                    if (n.valid() and (n.mark & mz.MARK_VISITED) != 0 and
                        wl.breakable() and wl.isClosed() and !wl.isBridged() and m.canOpen(n)) avail |= bit(i);
                }
                if (cv.pickWeighted(w, avail)) |i| {
                    m.cellWall(cur, i).state = .open;
                    _ = coll.swapRemove(idx);
                    carved = true;
                } else if (m.has_limits) {
                    dropFrontier(cur);
                    _ = coll.swapRemove(idx);
                }
                continue;
            }
            var nidx = m.rand.below(cur.nWalls());
            for (0..cur.nWalls()) |_| {
                const w = m.cellWall(cur, nidx);
                const n = w.other(cur);
                if (n.valid() and (n.mark & mz.MARK_VISITED) != 0 and
                    w.breakable() and w.isClosed() and !w.isBridged() and m.canOpen(n))
                {
                    w.state = .open;
                    _ = coll.swapRemove(idx);
                    carved = true;
                    break;
                }
                nidx += 1;
            }
            if (!carved and m.has_limits) {
                // all visited neighbours are full (--max-openings): wait
                // until another neighbour gets visited
                dropFrontier(cur);
                _ = coll.swapRemove(idx);
            }
        } else {
            _ = coll.swapRemove(idx);
        }
    }
}

// ---------------------------------------------------------------------------
// growing tree

/// List with cheap prepend: the head of the list is the end of the array.
const CellList = struct {
    items: std.ArrayListUnmanaged(*Cell) = .empty,

    fn prepend(l: *CellList, gpa: Allocator, c: *Cell) !void {
        try l.items.append(gpa, c);
    }

    fn len(l: *const CellList) usize {
        return l.items.items.len;
    }

    /// Removes and returns the n-th element counted from the head.
    fn remove(l: *CellList, n: usize) *Cell {
        return l.items.orderedRemove(l.items.items.len - 1 - n);
    }
};

fn addTreeNeighbours(cv: *Carver, list: *CellList, c: *Cell) !void {
    const m = cv.m;
    for (0..c.nWalls()) |i| {
        const w = m.cellWall(c, i);
        if (w.isBridged()) {
            if (m.go(c, i, mz.MARK_VISITED)) |n| {
                try list.prepend(cv.gpa, n);
                try addTreeNeighbours(cv, list, n);
            }
        }
    }
}

fn growingTree(cv: *Carver) CarveError!void {
    const m = cv.m;
    var list: CellList = .{};
    defer list.items.deinit(cv.gpa);
    const treefactor = @min(1.0, @max(0.0, cv.params.treefactor));
    m.clearMarks();
    try buildCrossovers(cv);
    var c = try randomBegin(m);
    _ = c.visit();
    try addTreeNeighbours(cv, &list, c);
    try list.prepend(cv.gpa, c);
    while (list.len() > 0) {
        const l = list.len();
        const n: usize = @intFromFloat(@as(f64, @floatFromInt(l - 1)) * treefactor);
        c = list.remove(n);
        const weights = cv.weightsFor(c);
        var idx = if (weights == null) cv.direction(c) else 0;
        for (0..c.nWalls()) |_| {
            if (m.go(c, idx, mz.MARK_VISITED)) |nb| try list.prepend(cv.gpa, nb);
            idx += 1;
        }
        if (weights) |w| {
            if (cv.digWeighted(c, w)) |nb| {
                try list.prepend(cv.gpa, c);
                try addTreeNeighbours(cv, &list, nb);
                try list.prepend(cv.gpa, nb);
            }
            continue;
        }
        for (0..c.nWalls()) |_| {
            if (dig(m, c, idx)) |nb| {
                try list.prepend(cv.gpa, c);
                try addTreeNeighbours(cv, &list, nb);
                try list.prepend(cv.gpa, nb);
                break;
            }
            idx += 1;
        }
    }
}

// ---------------------------------------------------------------------------
// Wilson's algorithm

/// Biased walks can take very long to hit the tree when they have to walk
/// against the bias; after this many steps (times √cells) a walk continues
/// unweighted.
const WILSON_WEIGHTED_STEPS = 20;

/// Wilson's algorithm: loop-erased random walks from every cell until they
/// hit the part already carved. Without weights every perfect maze is
/// equally likely. Cells connected by bridges are treated as one node.
fn wilson(cv: *Carver) CarveError!void {
    const m = cv.m;
    const gpa = cv.gpa;
    m.clearMarks();
    try buildCrossovers(cv);
    const start = try randomBegin(m);
    const n = m.n_cells;

    // the nodes: sets of cells connected by bridges
    var sets = try BridgeSets.init(gpa, n);
    defer gpa.free(sets.parent);
    for (0..n) |ci| {
        const c = m.cell(ci);
        if (!c.valid()) continue;
        for (0..c.nWalls()) |i| {
            const w = m.cellWall(c, i);
            if (!w.isBridged()) continue;
            const o = w.other(c);
            if (!o.valid()) continue;
            const a = sets.find(@intCast(ci));
            const b = sets.find(cellIndex(m, o));
            if (a != b) sets.parent[a] = b;
        }
    }
    const node = try gpa.alloc(u32, n);
    defer gpa.free(node);
    for (node, 0..) |*x, ci| x.* = sets.find(@intCast(ci));

    // the breakable walls leaving every node (compressed rows)
    const first = try gpa.alloc(u32, n + 1);
    defer gpa.free(first);
    @memset(first, 0);
    const Edge = struct { wall: u32, to: u32, weight: f64 };
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(gpa);
    for (0..2) |pass| {
        for (0..n) |ci| {
            const c = m.cell(ci);
            if (!c.valid()) continue;
            const ws = cv.weightsFor(c);
            for (0..c.nWalls()) |i| {
                const w = m.cellWall(c, i);
                const o = w.other(c);
                if (!o.valid() or !w.isClosed() or !w.breakable() or w.isBridged()) continue;
                const to = node[cellIndex(m, o)];
                if (to == node[ci]) continue;
                if (pass == 0) {
                    first[node[ci] + 1] += 1;
                    continue;
                }
                const weight: f64 = if (ws) |x| x[i] else 1;
                edges.items[first[node[ci]]] = .{ .wall = c.wallIdx(i), .to = to, .weight = weight };
                first[node[ci]] += 1;
            }
        }
        if (pass == 0) {
            for (1..n + 1) |k| first[k] += first[k - 1];
            try edges.resize(gpa, first[n]);
        } else {
            // the fill moved every start to the next row's start
            std.mem.copyBackwards(u32, first[1..], first[0..n]);
            first[0] = 0;
        }
    }
    const out = struct {
        fn of(f: []const u32, e: []const Edge, x: u32) []const Edge {
            return e[f[x]..f[x + 1]];
        }
    }.of;

    // only the nodes reachable from the start take part (the others would
    // never meet the tree)
    const State = enum(u8) { unreachable_, outside, tree };
    const state = try gpa.alloc(State, n);
    defer gpa.free(state);
    @memset(state, .unreachable_);
    var reach: std.ArrayListUnmanaged(u32) = .empty;
    defer reach.deinit(gpa);
    const root = node[cellIndex(m, start)];
    state[root] = .outside;
    try reach.append(gpa, root);
    var k: usize = 0;
    while (k < reach.items.len) : (k += 1) {
        for (out(first, edges.items, reach.items[k])) |e| {
            if (state[e.to] != .unreachable_) continue;
            state[e.to] = .outside;
            try reach.append(gpa, e.to);
        }
    }
    state[root] = .tree;

    // next[x]: index of the edge the last walk left node x through
    const next = try gpa.alloc(u32, n);
    defer gpa.free(next);
    const weighted = cv.params.weights.len > 0;
    const max_weighted: usize = WILSON_WEIGHTED_STEPS * (@as(usize, @intFromFloat(@sqrt(@as(f64, @floatFromInt(reach.items.len))))) + 1);
    // with opening limits walks may get stuck or wander in a part of the
    // maze whose only connections are full; such walks are given up (the
    // cells are connected by `repairLimits` afterwards)
    const max_steps = 100 * reach.items.len + 1000;
    walks: for (reach.items) |s| {
        var x = s;
        var steps: usize = 0;
        while (state[x] != .tree) : (steps += 1) {
            const es = out(first, edges.items, x);
            if (m.has_limits) {
                if (steps > max_steps) continue :walks;
                const j = wilsonLimitedStep(m, es, state, weighted and steps < max_weighted) orelse continue :walks;
                next[x] = first[x] + @as(u32, @intCast(j));
                x = es[j].to;
                continue;
            }
            var j: usize = 0;
            var sum: f64 = 0;
            if (weighted and steps < max_weighted) {
                for (es) |e| sum += e.weight;
            }
            if (sum > 0) {
                var r = m.rand.unit() * sum;
                while (j + 1 < es.len and (es[j].weight == 0 or r >= es[j].weight)) : (j += 1) r -= es[j].weight;
                // rounding
                while (es[j].weight == 0) j -= 1;
            } else {
                // unweighted, or only directions with weight 0 left
                j = m.rand.below(es.len);
            }
            next[x] = first[x] + @as(u32, @intCast(j));
            x = es[j].to;
        }
        // the walk without its loops joins the tree
        x = s;
        while (state[x] != .tree) {
            state[x] = .tree;
            const e = edges.items[next[x]];
            m.walls[e.wall].state = .open;
            x = e.to;
        }
    }
}

/// A step of a walk of Wilson's algorithm with opening limits: tree nodes
/// whose cell can't get another opening are avoided. Returns the index of
/// the edge, or null if no step is possible.
fn wilsonLimitedStep(m: *Maze, es: anytype, state: anytype, weighted: bool) ?usize {
    var allowed: u64 = 0;
    var count: usize = 0;
    var sum: f64 = 0;
    for (es, 0..) |e, i| {
        if (i >= 64) break;
        if (state[e.to] == .tree and !m.canOpen(m.cell(e.to))) continue;
        allowed |= bit(i);
        count += 1;
        if (weighted) sum += e.weight;
    }
    if (count == 0) return null;
    if (sum > 0) {
        var r = m.rand.unit() * sum;
        var last: usize = 0;
        for (es, 0..) |e, i| {
            if (i >= 64) break;
            if (allowed & bit(i) == 0 or e.weight == 0) continue;
            if (r < e.weight) return i;
            r -= e.weight;
            last = i;
        }
        return last; // rounding
    }
    var k = m.rand.below(count);
    for (0..@min(es.len, 64)) |i| {
        if (allowed & bit(i) == 0) continue;
        if (k == 0) return i;
        k -= 1;
    }
    unreachable;
}

// ---------------------------------------------------------------------------
// opening limits

/// After carving with opening limits (`--max-openings`) some cells may not
/// be connected: their only neighbours in the maze were full. Connects them
/// through a neighbour that can still get an opening and carves on from
/// there (backtracker). If all neighbours are full, one of them is freed by
/// moving one of its passages elsewhere (`freeNeighbour`). Fails if that
/// isn't possible either.
fn repairLimits(cv: *Carver, start: *Cell) CarveError!void {
    const m = cv.m;
    // the cells connected to the start
    m.clearMarks();
    var stack: std.ArrayListUnmanaged(*Cell) = .empty;
    defer stack.deinit(cv.gpa);
    _ = start.visit();
    try stack.append(cv.gpa, start);
    while (stack.pop()) |c| {
        for (0..c.nWalls()) |i| {
            if (m.go(c, i, mz.MARK_VISITED)) |n| try stack.append(cv.gpa, n);
        }
    }
    const Link = struct { from: *Cell, idx: usize };
    var links: std.ArrayListUnmanaged(Link) = .empty;
    defer links.deinit(cv.gpa);
    var stuck: std.ArrayListUnmanaged(*Cell) = .empty;
    defer stuck.deinit(cv.gpa);
    while (true) {
        links.clearRetainingCapacity();
        stuck.clearRetainingCapacity();
        for (m.cells[0..m.n_cells]) |*c| {
            if (!c.valid() or c.visited()) continue;
            if (!m.canOpen(c)) return error.LimitUnsatisfiable;
            const n_links = links.items.len;
            var near = false;
            for (0..c.nWalls()) |i| {
                const w = m.cellWall(c, i);
                const n = w.other(c);
                if (!n.valid() or !n.visited() or !openable(w)) continue;
                near = true;
                if (m.canOpen(n)) try links.append(cv.gpa, .{ .from = c, .idx = i });
            }
            if (near and links.items.len == n_links) try stuck.append(cv.gpa, c);
        }
        if (links.items.len > 0) {
            const l = links.items[m.rand.below(links.items.len)];
            m.cellWall(l.from, l.idx).state = .open;
            _ = l.from.visit();
            try backtrackFrom(cv, l.from);
            continue;
        }
        // only cells next to full ones (or none at all) are left
        for (stuck.items) |c| {
            if (try freeNeighbour(cv, c)) break;
        } else {
            for (m.cells[0..m.n_cells]) |*c| {
                if (c.valid() and !c.visited()) return error.LimitUnsatisfiable;
            }
            return;
        }
    }
}

/// A closed wall that may be opened.
fn openable(w: *const Wall) bool {
    return w.isClosed() and !w.isBridged() and w.breakable();
}

fn passable(w: *const Wall) bool {
    return w.isOpen() or w.isBridged();
}

/// Tries to connect the unconnected cell `u` whose maze neighbours are all
/// full: a passage n-v of such a neighbour n is closed, the part of the
/// maze behind v is connected elsewhere (through two cells that can still
/// get an opening) and n is opened to u. Returns false if no neighbour can
/// be freed.
fn freeNeighbour(cv: *Carver, u: *Cell) !bool {
    const m = cv.m;
    const gpa = cv.gpa;
    const part = try gpa.alloc(bool, m.n_cells);
    defer gpa.free(part);
    var stack: std.ArrayListUnmanaged(*Cell) = .empty;
    defer stack.deinit(gpa);
    const Link = struct { from: *Cell, idx: usize };
    var links: std.ArrayListUnmanaged(Link) = .empty;
    defer links.deinit(gpa);

    const nu = u.nWalls();
    const off_u = m.rand.below(nu);
    for (0..nu) |k| {
        const ui = (k + off_u) % nu;
        const wu = m.cellWall(u, ui);
        const n = wu.other(u);
        if (!n.valid() or !n.visited() or !openable(wu)) continue;
        const nn = n.nWalls();
        const off_n = m.rand.below(nn);
        for (0..nn) |kk| {
            const ni = (kk + off_n) % nn;
            const wn = m.cellWall(n, ni);
            if (!wn.isOpen()) continue;
            const v = wn.other(n);
            if (!v.valid()) continue;
            // the part behind v without the passage n-v
            wn.state = .closed;
            @memset(part, false);
            part[cellIndex(m, v)] = true;
            stack.clearRetainingCapacity();
            try stack.append(gpa, v);
            while (stack.pop()) |c| {
                for (0..c.nWalls()) |i| {
                    const w = m.cellWall(c, i);
                    const o = w.other(c);
                    if (!passable(w) or !o.valid()) continue;
                    const oi = cellIndex(m, o);
                    if (part[oi]) continue;
                    part[oi] = true;
                    try stack.append(gpa, o);
                }
            }
            // other connections of that part to the rest of the maze
            links.clearRetainingCapacity();
            for (m.cells[0..m.n_cells], 0..) |*c, ci| {
                if (!part[ci]) continue;
                if (!m.canOpen(c)) continue;
                for (0..c.nWalls()) |i| {
                    const w = m.cellWall(c, i);
                    const o = w.other(c);
                    if (o == n or !o.valid() or !o.visited() or part[cellIndex(m, o)] or !openable(w)) continue;
                    if (m.canOpen(o)) try links.append(gpa, .{ .from = c, .idx = i });
                }
            }
            if (links.items.len > 0) {
                const l = links.items[m.rand.below(links.items.len)];
                m.cellWall(l.from, l.idx).state = .open;
                wu.state = .open;
                _ = u.visit();
                try backtrackFrom(cv, u);
                return true;
            }
            wn.state = .open;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// entrance and exit

/// Where the entrance or exit may be placed: a breakable wall to the
/// outside of the maze. For a side (`-e`/`-x`) the wall must face that side
/// (its outward normal less than 45° off that direction) and lie within
/// `BAND` of the outermost such wall, so that walls at the corners which
/// only slightly face the side (e.g. of hexagons) aren't used. If no wall
/// faces the side (e.g. north in the triangular `random-3` maze), any wall
/// whose normal points somewhat towards it will do. In tileable
/// mazes any cell will do (there are no outer walls).
const Side = struct {
    dir: mz.Direction,
    tileable: bool,
    /// minimum position of the wall in the direction `dir`
    limit: f64 = -std.math.inf(f64),
    /// no wall faces the side: accept walls up to 90° off
    relaxed: bool = false,

    const BAND = 0.5;

    fn init(m: *Maze, dir: mz.Direction, tileable: bool) Side {
        var s: Side = .{ .dir = dir, .tileable = tileable };
        if (tileable or dir == .none) return s;
        for ([_]bool{ false, true }) |relaxed| {
            s.relaxed = relaxed;
            var best = -std.math.inf(f64);
            for (m.cells[0..m.n_cells]) |*c| {
                if (!c.valid()) continue;
                for (0..c.nWalls()) |i| {
                    if (s.position(m, c, i)) |x| best = @max(best, x);
                }
            }
            s.limit = best - BAND;
            if (best > -std.math.inf(f64)) break;
        }
        return s;
    }

    /// If the idx-th wall of `c` leads outside and faces the side, its
    /// position in the direction of the side (larger is farther out).
    fn position(s: *const Side, m: *Maze, c: *const Cell, idx: usize) ?f64 {
        const w = m.cellWall(c, idx);
        if (w.other(c).type != mz.TYPE_OFF or !w.breakable()) return null;
        const p = w.center();
        // outward normal of the wall
        var d = w.points[1].sub(w.points[0]).rot(std.math.pi / 2.0);
        if (d.x * (p.x - c.center.x) + d.y * (p.y - c.center.y) < 0) d = d.scale(-1);
        // normal component towards the side and across it
        const along, const across, const x = switch (s.dir) {
            .none => return 0,
            .north => .{ -d.y, d.x, -p.y },
            .south => .{ d.y, d.x, p.y },
            .west => .{ -d.x, d.y, -p.x },
            .east => .{ d.x, d.y, p.x },
        };
        const faces = if (s.relaxed) along > 1e-9 * @abs(across) else along > @abs(across);
        return if (faces) x else null;
    }

    /// Whether the idx-th wall of `c` is a possible entrance/exit.
    fn wallOk(s: *const Side, m: *Maze, c: *const Cell, idx: usize) bool {
        if (!m.canOpen(c)) return false;
        const x = s.position(m, c, idx) orelse return false;
        return x >= s.limit;
    }

    fn cellOk(s: *const Side, m: *Maze, c: *const Cell) bool {
        if (s.tileable) return true;
        return s.wall(m, c) != null;
    }

    fn wall(s: *const Side, m: *Maze, c: *const Cell) ?usize {
        for (0..c.nWalls()) |i| {
            if (s.wallOk(m, c, i)) return i;
        }
        return null;
    }

    /// Opens the wall of the entrance/exit cell `c` leading outside.
    fn carveOut(s: *const Side, m: *Maze, c: *const Cell) void {
        if (s.tileable) return;
        if (s.wall(m, c)) |i| m.cellWall(c, i).state = .open;
    }
};

const FarFrame = struct { cell: *Cell, depth: usize, i: usize };

/// Depth first search from `start`; returns the cell farthest away (in
/// steps) suitable for the side. `start` itself is only returned if
/// `allow_start` is set and no other cell is suitable.
fn findFarest(cv: *Carver, start: *Cell, side: *const Side, allow_start: bool) !?*Cell {
    const m = cv.m;
    var len: usize = 0;
    var farest: ?*Cell = if (allow_start and side.cellOk(m, start)) start else null;
    var stack: std.ArrayListUnmanaged(FarFrame) = .empty;
    defer stack.deinit(cv.gpa);

    var next: ?*Cell = start;
    var depth: usize = 0;
    while (true) {
        if (next) |c| {
            if (depth > len and side.cellOk(m, c)) {
                len = depth;
                farest = c;
            }
            try stack.append(cv.gpa, .{ .cell = c, .depth = depth, .i = 0 });
            next = null;
        }
        if (stack.items.len == 0) break;
        const f = &stack.items[stack.items.len - 1];
        if (f.i >= f.cell.nWalls()) {
            _ = stack.pop();
            continue;
        }
        const i = f.i;
        f.i += 1;
        if (m.go(f.cell, i, mz.MARK_VISITED)) |n| {
            next = n;
            depth = f.depth + 1;
        }
    }
    return farest;
}

fn searchEntrance(cv: *Carver) CarveError!void {
    const m = cv.m;
    m.clearMarks();
    const side = Side.init(m, cv.params.entrance, cv.params.tileable);
    const entrance = m.entrance.?;
    _ = entrance.visit();
    if (try findFarest(cv, entrance, &side, true)) |c| {
        m.entrance = c;
        side.carveOut(m, c);
    } else if (cv.params.debug == 0) {
        return error.NoEntrance;
    }
}

fn searchExit(cv: *Carver) CarveError!void {
    const m = cv.m;
    m.clearMarks();
    const side = Side.init(m, cv.params.exit, cv.params.tileable);
    // note: like the original, the entrance itself is not marked visited here
    if (try findFarest(cv, m.entrance.?, &side, false)) |c| {
        m.exit = c;
        side.carveOut(m, c);
    } else if (cv.params.debug == 0) {
        return error.NoExit;
    }
}

fn carveOnce(cv: *Carver) CarveError!void {
    cv.m.clearMarks();
    switch (cv.params.algorithm) {
        .backtracker => try backtracker(cv),
        .prim => try prim(cv),
        .tree => try growingTree(cv),
        .wilson => try wilson(cv),
    }
}

/// Attempts at carving with opening limits before giving up.
const LIMIT_TRIES = 20;

/// Carving with opening limits (`--max-openings`): carves, connects the
/// cells left over (`repairLimits`) and starts over (with other random
/// numbers) if that fails.
fn carveLimited(cv: *Carver) CarveError!void {
    const m = cv.m;
    // the state before carving (crossovers change walls and cell types)
    const walls = try cv.gpa.dupe(Wall, m.walls[0..m.n_walls]);
    defer cv.gpa.free(walls);
    const types = try cv.gpa.alloc(u8, m.n_cells);
    defer cv.gpa.free(types);
    for (m.cells[0..m.n_cells], types) |*c, *t| t.* = c.type;
    for (0..LIMIT_TRIES) |attempt| {
        if (attempt > 0) {
            @memcpy(m.walls[0..m.n_walls], walls);
            for (m.cells[0..m.n_cells], types) |*c, t| c.type = t;
        }
        try carveOnce(cv);
        if (repairLimits(cv, m.entrance.?)) |_| return else |e| switch (e) {
            error.LimitUnsatisfiable => {},
            else => return e,
        }
    }
    return error.LimitUnsatisfiable;
}

/// Carves the maze and places entrance and exit.
/// Places the entrance and the exit of a maze whose passages were made
/// without carving (e.g. recursive mazes): the entrance is the border cell
/// farthest from a random cell, the exit the one farthest from the entrance.
pub fn placeEntranceExit(gpa: Allocator, params: *const Params, m: *Maze) CarveError!void {
    var cv = Carver{ .m = m, .params = params, .gpa = gpa };
    _ = try randomBegin(m);
    m.clearMarks();
    try searchEntrance(&cv);
    m.clearMarks();
    try searchExit(&cv);
}

pub fn carveMaze(gpa: Allocator, params: *const Params, m: *Maze) CarveError!void {
    var cv = Carver{ .m = m, .params = params, .gpa = gpa };
    if (m.has_limits) {
        try carveLimited(&cv);
    } else {
        try carveOnce(&cv);
    }
    m.clearMarks();
    try searchEntrance(&cv);
    m.clearMarks();
    try searchExit(&cv);
}

test "parseWeights" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lookup = @import("structure.zig").lookup;
    const hs = try lookup("6-4"); // A(6),B(4),C(6)
    const ws = try parseWeights(arena, hs, "B:0,1,2,1/a:1,1,1,1,1,3");
    try std.testing.expectEqual(@as(usize, 3), ws.len);
    try std.testing.expectEqualSlices(f64, &.{ 1, 1, 1, 1, 1, 3 }, ws[0]);
    try std.testing.expectEqualSlices(f64, &.{ 0, 1, 2, 1 }, ws[1]);
    try std.testing.expectEqual(@as(usize, 0), ws[2].len);
    try std.testing.expectError(error.WrongNumberOfWeights, parseWeights(arena, hs, "B:1,1,1"));
    try std.testing.expectError(error.UnknownCellType, parseWeights(arena, hs, "D:1,1,1,1"));
    try std.testing.expectError(error.DuplicateCellType, parseWeights(arena, hs, "B:1,1,1,1/B:1,1,1,1"));
    try std.testing.expectError(error.InvalidWeight, parseWeights(arena, hs, "B:0,0,0,0"));
    try std.testing.expectError(error.InvalidSyntax, parseWeights(arena, hs, "B:1,x,1,1"));
    try std.testing.expectError(error.NoCellTypes, parseWeights(arena, try lookup("random"), "A:1"));
}

test "pickWeighted follows the weights" {
    const rng = @import("rng.zig");
    var params: Params = .{ .rows = 2, .columns = 2 };
    var rand = rng.Random.init(1);
    const m = try mz.newMaze(std.testing.allocator, &params, &rand);
    defer m.deinit();
    m.rand = &rand;
    var cv = Carver{ .m = m, .params = &params, .gpa = std.testing.allocator };
    const w = [_]f64{ 0, 1, 2, 1 };
    const N = 40000;
    var count: [4]f64 = @splat(0);
    for (0..N) |_| count[cv.pickWeighted(&w, 0b1111).?] += 1;
    try std.testing.expectEqual(@as(f64, 0), count[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), count[1] / N, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), count[2] / N, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), count[3] / N, 0.01);
    // without direction 2, the others share its probability
    count = @splat(0);
    for (0..N) |_| count[cv.pickWeighted(&w, 0b1011).?] += 1;
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), count[1] / N, 0.01);
    // a weight 0 direction is taken if nothing else is left
    try std.testing.expectEqual(@as(?usize, 0), cv.pickWeighted(&w, 0b0001));
    try std.testing.expectEqual(@as(?usize, null), cv.pickWeighted(&w, 0));
}

test "wilson makes every maze equally likely" {
    const rng = @import("rng.zig");
    // a 2x3 grid has 15 spanning trees
    var count: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    defer count.deinit(std.testing.allocator);
    const N = 15000;
    for (0..N) |seed| {
        var params: Params = .{ .rows = 2, .columns = 3, .algorithm = .wilson };
        var rand = rng.Random.init(@intCast(seed + 1));
        const m = try mz.newMaze(std.testing.allocator, &params, &rand);
        defer m.deinit();
        m.rand = &rand;
        try carveMaze(std.testing.allocator, &params, m);
        var key: u64 = 0;
        for (m.walls[0..m.n_walls], 0..) |*w, i| {
            if (w.cells[0].valid() and w.cells[1].valid() and w.isOpen()) key |= bit(i);
        }
        const gop = try count.getOrPut(std.testing.allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    try std.testing.expectEqual(@as(usize, 15), count.count());
    var it = count.valueIterator();
    // expected 1000 each, standard deviation about 31
    while (it.next()) |v| try std.testing.expect(v.* > 850 and v.* < 1150);
}

test "entrance and exit are placed at the requested sides" {
    const gpa = std.testing.allocator;
    const structure = @import("structure.zig");
    const rng = @import("rng.zig");
    const dirs = [_]mz.Direction{ .north, .west, .south, .east };
    for ([_][]const u8{ "4", "6", "3-4", "hexagonal-rhombic", "penrose", "shield" }) |name| {
        for (dirs, 0..) |entrance, k| {
            const exit = dirs[(k + 2) % 4];
            var rand = rng.Random.init(@intCast(k + 1));
            var params: Params = .{ .structure = try structure.lookup(name), .rows = 8, .columns = 8, .entrance = entrance, .exit = exit };
            const m = try mz.newMaze(gpa, &params, &rand);
            defer m.deinit();
            try carveMaze(gpa, &params, m);
            // the bounding box of the maze
            var dim: mz.Dimension = .{};
            for (m.walls[0..m.n_walls]) |*w| {
                dim.addPoint(w.points[0]);
                dim.addPoint(w.points[1]);
            }
            for ([_]*Cell{ m.entrance.?, m.exit.? }, [_]mz.Direction{ entrance, exit }) |c, dir| {
                var found = false;
                for (0..c.nWalls()) |i| {
                    const w = m.cellWall(c, i);
                    if (!w.isOpen() or w.other(c).type != mz.TYPE_OFF) continue;
                    const p = w.center();
                    // within 1.5 cells of that side
                    const dist = switch (dir) {
                        .north => p.y - dim.ymin,
                        .south => dim.ymax - p.y,
                        .west => p.x - dim.xmin,
                        .east => dim.xmax - p.x,
                        .none => unreachable,
                    };
                    if (dist < 1.5) found = true;
                }
                if (!found) {
                    std.debug.print("{s}: {t} not at its side\n", .{ name, dir });
                    return error.WrongSide;
                }
            }
        }
    }
}

test "opening limits are kept and the maze stays perfect" {
    const gpa = std.testing.allocator;
    const structure = @import("structure.zig");
    const rng = @import("rng.zig");
    const tests = @import("tests.zig");
    const Case = struct { name: []const u8, limits: []const struct { u8, u8 } };
    const cases = [_]Case{
        .{ .name = "6-4", .limits = &.{.{ 1, 2 }} },
        .{ .name = "6-4", .limits = &.{ .{ 0, 2 }, .{ 2, 2 } } },
        .{ .name = "12-6-4", .limits = &.{.{ 0, 2 }} },
        .{ .name = "8-4", .limits = &.{.{ 1, 3 }} },
        .{ .name = "4", .limits = &.{.{ 0, 3 }} },
        .{ .name = "cairo", .limits = &.{ .{ 0, 3 }, .{ 1, 3 }, .{ 2, 3 }, .{ 3, 3 } } },
    };
    for (cases) |cs| {
        for ([_]mz.Algorithm{ .backtracker, .prim, .tree, .wilson }) |alg| {
            {
                var rand = rng.Random.init(3);
                var params: Params = .{ .structure = try structure.lookup(cs.name), .rows = 12, .columns = 12, .algorithm = alg };
                const m = try mz.newMaze(gpa, &params, &rand);
                defer m.deinit();
                var limits: [mz.MAX_TYPES]u8 = @splat(mz.NO_LIMIT);
                for (cs.limits) |l| limits[l[0]] = l[1];
                m.setLimits(limits);
                carveMaze(gpa, &params, m) catch |e| {
                    std.debug.print("{s} {t}: {t}\n", .{ cs.name, alg, e });
                    return e;
                };
                try tests.checkPerfect(m);
                for (m.cells[0..m.n_cells]) |*c| {
                    const limit = m.openLimit(c);
                    if (limit == mz.NO_LIMIT) continue;
                    var n: usize = 0;
                    for (0..c.nWalls()) |i| {
                        if (passable(m.cellWall(c, i))) n += 1;
                    }
                    try std.testing.expect(n <= limit);
                }
            }
        }
    }
}
