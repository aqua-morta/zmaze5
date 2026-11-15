//! Rhombus tilings generated with de Bruijn's multigrid method (used for the
//! Ammann–Beenker and the Penrose rhombus tilings).
//!
//! There are n families of parallel lines with directions e_0..e_{n-1}, the
//! lines of family i being { p : p·e_i = k + γ_i } for integers k. Every
//! crossing of two lines becomes a rhombus whose edges are parallel to the
//! two lines' directions. A point p of the plane maps to the tiling vertex
//! Σ K_i(p)·e_i with K_i(p) = ⌈p·e_i − γ_i⌉; the four corners of a
//! crossing's rhombus are the vertices of the four regions meeting at the
//! crossing. The offsets γ_i select a part of the (infinite, non-repeating)
//! tiling. Vertices are identified by their integer coordinates K, so
//! neighbouring tiles share them exactly.
//!
//! Optionally groups of three families are concurrent (their offsets are
//! chosen such that every crossing of two of them lies on a line of the
//! third, as for the Socolar tiling): such a triple point becomes a hexagon
//! instead of three rhombi.

const std = @import("std");
const geo = @import("geo.zig");
const mz = @import("maze.zig");
const rng = @import("rng.zig");
const tiling = @import("tiling.zig");

const Allocator = std.mem.Allocator;
const Vec2 = geo.Vec2;
const Maze = mz.Maze;
const Params = mz.Params;

pub const MAX_N = 8;

pub const Grid = struct {
    /// number of line families
    n: usize,
    /// angle between consecutive directions (π/n or 2π/n)
    step: f64,
    /// offsets of the line families
    gamma: [MAX_N]f64,
    /// edge length of the rhombi
    edge: f64,
    /// cell type of the rhombus at a crossing of families j < k
    tileType: *const fn (j: usize, k: usize) u8,
    /// groups of three concurrent families (indices ascending); their
    /// triple points become hexagons of type `hex_type`
    triples: []const [3]usize = &.{},
    hex_type: u8 = 0,
};

/// The triple group containing both j and k, if any.
fn tripleOf(g: *const Grid, j: usize, k: usize) ?[3]usize {
    for (g.triples) |t| {
        if (std.mem.indexOfScalar(usize, &t, j) != null and std.mem.indexOfScalar(usize, &t, k) != null) return t;
    }
    return null;
}

inline fn dot(a: Vec2, b: Vec2) f64 {
    return a.x * b.x + a.y * b.y;
}

/// Builds the maze from the rhombi whose centers lie in the maze rectangle.
pub fn newMultigridMaze(gpa: Allocator, params: *Params, rand: *rng.Random, g: Grid) !*Maze {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const tmp = arena_state.allocator();

    const n = g.n;
    var dirs: [MAX_N]Vec2 = undefined;
    for (0..n) |i| {
        const a = g.step * @as(f64, @floatFromInt(i));
        dirs[i] = .{ .x = @cos(a), .y = @sin(a) };
    }
    // a few directions are exact (keeps e.g. Ammann–Beenker squares square)
    for (dirs[0..n]) |*d| {
        if (@abs(d.x) < 1e-12) d.x = 0;
        if (@abs(d.y) < 1e-12) d.y = 0;
        if (@abs(@abs(d.x) - std.math.sqrt1_2) < 1e-12) d.x = std.math.copysign(@as(f64, std.math.sqrt1_2), d.x);
        if (@abs(@abs(d.y) - std.math.sqrt1_2) < 1e-12) d.y = std.math.copysign(@as(f64, std.math.sqrt1_2), d.y);
    }

    const w: f64 = @floatFromInt(params.columns);
    const h: f64 = @floatFromInt(params.rows);

    // The tiling vertex of a grid point p is (n/2)·p plus a bounded offset
    // (at most Σ|δ_i − γ_i| < n); tiles have a diameter below 2 edges.
    const scale = @as(f64, @floatFromInt(n)) / 2.0 * g.edge;
    const margin = @as(f64, @floatFromInt(n + 2)) / scale * g.edge;
    const gx0 = -margin;
    const gy0 = -margin;
    const gx1 = w / scale + margin;
    const gy1 = h / scale + margin;
    const corners = [4]Vec2{ .{ .x = gx0, .y = gy0 }, .{ .x = gx1, .y = gy0 }, .{ .x = gx0, .y = gy1 }, .{ .x = gx1, .y = gy1 } };
    // range of line numbers of each family crossing the rectangle
    var lo: [MAX_N]i64 = undefined;
    var hi: [MAX_N]i64 = undefined;
    for (0..n) |i| {
        var mn = std.math.inf(f64);
        var mx = -std.math.inf(f64);
        for (corners) |c| {
            const d = dot(c, dirs[i]) - g.gamma[i];
            mn = @min(mn, d);
            mx = @max(mx, d);
        }
        lo[i] = @intFromFloat(@floor(mn));
        hi[i] = @intFromFloat(@ceil(mx));
    }

    var vert_ids: std.AutoHashMapUnmanaged([MAX_N]i64, u32) = .empty;
    var points: std.ArrayListUnmanaged(Vec2) = .empty;
    var tiles: std.ArrayListUnmanaged(tiling.Tile) = .empty;

    for (0..n) |j| for (j + 1..n) |k| {
        // triple points are handled once, at the crossings of the group's
        // first two families
        const triple = tripleOf(&g, j, k);
        if (triple) |t| {
            if (j != t[0] or k != t[1]) continue;
        }
        const ej = dirs[j];
        const ek = dirs[k];
        const det = ej.x * ek.y - ej.y * ek.x;
        var nj = lo[j];
        while (nj <= hi[j]) : (nj += 1) {
            var nk = lo[k];
            while (nk <= hi[k]) : (nk += 1) {
                // crossing of line nj of family j and line nk of family k
                const a = @as(f64, @floatFromInt(nj)) + g.gamma[j];
                const b = @as(f64, @floatFromInt(nk)) + g.gamma[k];
                const p = Vec2{ .x = (a * ek.y - b * ej.y) / det, .y = (b * ej.x - a * ek.x) / det };
                if (p.x < gx0 or p.x > gx1 or p.y < gy0 or p.y > gy1) continue;

                var key: [MAX_N]i64 = @splat(0);
                for (0..n) |i| key[i] = @intFromFloat(@ceil(dot(p, dirs[i]) - g.gamma[i]));
                key[j] = nj;
                key[k] = nk;
                if (triple) |t| {
                    try addHexagon(tmp, &g, dirs[0..n], t, p, key, w, h, &vert_ids, &points, &tiles);
                    continue;
                }
                // corners: (j, k) offsets (0,0), (1,0), (1,1), (0,1)
                const offs = [4][2]i64{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
                var pos: [4]Vec2 = undefined;
                var ids: [4]u32 = undefined;
                for (offs, 0..) |o, ci| {
                    var vk = key;
                    vk[j] += o[0];
                    vk[k] += o[1];
                    var v = Vec2{};
                    for (0..n) |i| v = v.add(dirs[i].scale(@floatFromInt(vk[i])));
                    pos[ci] = v.scale(g.edge);
                    const gop = try vert_ids.getOrPut(tmp, vk);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = @intCast(points.items.len);
                        try points.append(tmp, pos[ci]);
                    }
                    ids[ci] = gop.value_ptr.*;
                }
                const ctr = pos[0].mean(pos[2]);
                if (ctr.x < 0 or ctr.x > w or ctr.y < 0 or ctr.y > h) continue;
                const v = try tmp.dupe(u32, &ids);
                // make the vertex order counter clockwise
                if (det < 0) std.mem.reverse(u32, v);
                try tiles.append(tmp, .{ .type = g.tileType(j, k), .verts = v, .center = ctr });
            }
        }
    };
    return tiling.buildMaze(gpa, params, rand, points.items, tiles.items);
}

const VertIds = std.AutoHashMapUnmanaged([MAX_N]i64, u32);

fn vertexId(tmp: Allocator, g: *const Grid, dirs: []const Vec2, vk: [MAX_N]i64, vert_ids: *VertIds, points: *std.ArrayListUnmanaged(Vec2)) !struct { u32, Vec2 } {
    var v = Vec2{};
    for (dirs, 0..) |d, i| v = v.add(d.scale(@floatFromInt(vk[i])));
    v = v.scale(g.edge);
    const gop = try vert_ids.getOrPut(tmp, vk);
    if (!gop.found_existing) {
        gop.value_ptr.* = @intCast(points.items.len);
        try points.append(tmp, v);
    }
    return .{ gop.value_ptr.*, v };
}

/// The hexagon at the triple point p of the group t: the vertices of the six
/// regions around p. `key` has the line numbers of the group's families.
fn addHexagon(tmp: Allocator, g: *const Grid, dirs: []const Vec2, t: [3]usize, p: Vec2, key_: [MAX_N]i64, w: f64, h: f64, vert_ids: *VertIds, points: *std.ArrayListUnmanaged(Vec2), tiles: *std.ArrayListUnmanaged(tiling.Tile)) !void {
    var key = key_;
    // the third line passes through p
    key[t[2]] = @intFromFloat(@round(dot(p, dirs[t[2]]) - g.gamma[t[2]]));
    // the three lines are 60° apart; the regions lie in between, i.e. in the
    // directions of the lines' normals and their opposites
    var ids: [6]u32 = undefined;
    var pos: [6]Vec2 = undefined;
    var ctr = Vec2{};
    for (0..6) |r| {
        const a = std.math.pi / 3.0 * @as(f64, @floatFromInt(r)) + std.math.atan2(dirs[t[0]].y, dirs[t[0]].x);
        const dir = Vec2{ .x = @cos(a), .y = @sin(a) };
        var vk = key;
        // the region's side of each line (K = n on the line, n + 1 beyond)
        for (t) |i| {
            if (dot(dir, dirs[i]) > 0) vk[i] += 1;
        }
        ids[r], pos[r] = try vertexId(tmp, g, dirs, vk, vert_ids, points);
        ctr = ctr.add(pos[r].scale(1.0 / 6.0));
    }
    if (ctr.x < 0 or ctr.x > w or ctr.y < 0 or ctr.y > h) return;
    // counter clockwise
    var area: f64 = 0;
    for (0..6) |r| {
        const a = pos[r];
        const b = pos[(r + 1) % 6];
        area += a.x * b.y - a.y * b.x;
    }
    const v = try tmp.dupe(u32, &ids);
    if (area < 0) std.mem.reverse(u32, v);
    try tiles.append(tmp, .{ .type = g.hex_type, .verts = v, .center = ctr });
}
