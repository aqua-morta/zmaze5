//! Aperiodic mazes with 12-fold symmetry: Gähler's shield tiling and a
//! wheel tiling derived from it.
//!
//! Shield tiling (triangles, squares and "shields", hexagons with angles of
//! 90° and 150°, all edges of unit length): a cut and project tiling. The
//! vertices are the points Σ n_k·e_k (n ∈ Z⁴, e_k the unit vector at 30·k°,
//! k = 0..3) whose internal image Σ n_k·e*_k (e*_k at 150·k°) lies in a
//! regular dodecagon of circumradius 1 with corners at multiples of 30°.
//! The edges join vertices at distance 1 (the twelve vectors ±e_0, ..., ±e_5
//! with e_4 = e_2 − e_0, e_5 = e_3 − e_1), the tiles are the faces. A random
//! shift of the window selects a random part of the tiling.
//!
//! Wheel tiling: the Tilings Encyclopedia describes Nissen's wheel tiling as
//! the shield tiling with every edge replaced by the orthogonal edge of the
//! same length through its midpoint. Taken literally the new edges cross
//! inside the triangles, so here every new edge ends at the center of a
//! triangle (and at half its length in squares and shields, where the new
//! edges meet at the square centers and at the right angled corners of the
//! shields). The result is a tiling by pentagons and three-armed 12-gons that
//! is locally derivable from the shield tiling, but not identical to the
//! patch shown in the encyclopedia.

const std = @import("std");
const geo = @import("geo.zig");
const mz = @import("maze.zig");
const rng = @import("rng.zig");
const tiling = @import("tiling.zig");

const Allocator = std.mem.Allocator;
const Vec2 = geo.Vec2;
const Maze = mz.Maze;
const Params = mz.Params;

/// Mean tile areas for unit edges, measured on large patches (shield: 66.7%
/// triangles, 21.1% squares, 12.2% shields; wheel: 77.6% pentagons of area
/// 0.933, 22.4% 12-gons of area 3.232). The tilings are scaled so that the
/// mean cell area is 1.
const SHIELD_MEAN_AREA: f64 = 0.7876;
const WHEEL_MEAN_AREA: f64 = 1.4476;

const NONE = std.math.maxInt(u32);

/// The twelve unit directions in Z⁴ coordinates.
const DELTA: [12][4]i32 = blk: {
    var d: [12][4]i32 = undefined;
    for (0..4) |k| {
        d[k] = .{ 0, 0, 0, 0 };
        d[k][k] = 1;
    }
    d[4] = .{ -1, 0, 1, 0 }; // e_2 - e_0
    d[5] = .{ 0, -1, 0, 1 }; // e_3 - e_1
    for (0..6) |k| {
        for (0..4) |c| d[k + 6][c] = -d[k][c];
    }
    break :blk d;
};

fn unit(deg: f64) Vec2 {
    const a = deg * std.math.pi / 180.0;
    var v = Vec2{ .x = @cos(a), .y = @sin(a) };
    if (@abs(v.x) < 1e-15) v.x = 0;
    if (@abs(v.y) < 1e-15) v.y = 0;
    return v;
}

/// physical and internal images of the basis vectors
const PHYS: [4]Vec2 = .{ unit(0), unit(30), unit(60), unit(90) };
const INT: [4]Vec2 = .{ unit(0), unit(150), unit(300), unit(90) };

fn phys(n: [4]i32) Vec2 {
    var v = Vec2{};
    for (0..4) |k| v = v.add(PHYS[k].scale(@floatFromInt(n[k])));
    return v;
}

/// The window: a regular dodecagon of circumradius 1, corners at 30·j°.
fn inWindow(q: Vec2) bool {
    const r = @cos(std.math.pi / 12.0);
    for (0..12) |j| {
        const nrm = unit(15.0 + 30.0 * @as(f64, @floatFromInt(j)));
        if (q.x * nrm.x + q.y * nrm.y > r) return false;
    }
    return true;
}

/// Inverts a 4x4 matrix (Gauss-Jordan with partial pivoting).
fn invert4(a_: [4][4]f64) [4][4]f64 {
    var a = a_;
    var inv: [4][4]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        inv[i][j] = if (i == j) 1 else 0;
    };
    for (0..4) |c| {
        var p = c;
        for (c + 1..4) |r| {
            if (@abs(a[r][c]) > @abs(a[p][c])) p = r;
        }
        std.mem.swap([4]f64, &a[c], &a[p]);
        std.mem.swap([4]f64, &inv[c], &inv[p]);
        const f = a[c][c];
        for (0..4) |j| {
            a[c][j] /= f;
            inv[c][j] /= f;
        }
        for (0..4) |r| {
            if (r == c) continue;
            const g = a[r][c];
            for (0..4) |j| {
                a[r][j] -= g * a[c][j];
                inv[r][j] -= g * inv[c][j];
            }
        }
    }
    return inv;
}

/// A patch of the shield tiling with unit edges.
const Shield = struct {
    keys: std.ArrayListUnmanaged([4]i32) = .empty,
    points: std.ArrayListUnmanaged(Vec2) = .empty,
    /// neighbour in each of the twelve directions (or NONE)
    nbs: std.ArrayListUnmanaged([12]u32) = .empty,
    /// tiles: vertex ids, counter clockwise
    tiles: std.ArrayListUnmanaged([]u32) = .empty,
    /// tile left of the edge leaving vertex v in direction k (or NONE)
    left: std.AutoHashMapUnmanaged([2]u32, u32) = .empty,

    /// Generates all vertices with physical position in [x0,x1]×[y0,y1].
    fn generate(gpa: Allocator, x0: f64, y0: f64, x1: f64, y1: f64, shift: Vec2) !Shield {
        var s: Shield = .{};
        var a: [4][4]f64 = undefined;
        for (0..4) |k| {
            a[0][k] = PHYS[k].x;
            a[1][k] = PHYS[k].y;
            a[2][k] = INT[k].x;
            a[3][k] = INT[k].y;
        }
        const ainv = invert4(a);
        // range of n_0, n_1 (interval arithmetic over rectangle x window)
        const lo_z = [4]f64{ x0, y0, shift.x - 1, shift.y - 1 };
        const hi_z = [4]f64{ x1, y1, shift.x + 1, shift.y + 1 };
        var lo: [2]i32 = undefined;
        var hi: [2]i32 = undefined;
        for (0..2) |i| {
            var mn: f64 = 0;
            var mx: f64 = 0;
            for (0..4) |j| {
                const c = ainv[i][j];
                mn += @min(c * lo_z[j], c * hi_z[j]);
                mx += @max(c * lo_z[j], c * hi_z[j]);
            }
            lo[i] = @intFromFloat(@floor(mn));
            hi[i] = @intFromFloat(@ceil(mx));
        }
        // n_2, n_3 from the internal position: q = n_2·e*_2 + n_3·e*_3 + r
        const det = INT[2].x * INT[3].y - INT[2].y * INT[3].x;
        var map: std.AutoHashMapUnmanaged([4]i32, u32) = .empty;
        defer map.deinit(gpa);
        var n0 = lo[0];
        while (n0 <= hi[0]) : (n0 += 1) {
            var n1 = lo[1];
            while (n1 <= hi[1]) : (n1 += 1) {
                const r = INT[0].scale(@floatFromInt(n0)).add(INT[1].scale(@floatFromInt(n1)));
                const t = shift.sub(r); // the window center relative to r
                // (n_2, n_3) = B⁻¹·(t + d) for |d| <= 1
                const c2 = (t.x * INT[3].y - t.y * INT[3].x) / det;
                const c3 = (INT[2].x * t.y - INT[2].y * t.x) / det;
                const r2 = (@abs(INT[3].y) + @abs(INT[3].x)) / @abs(det);
                const r3 = (@abs(INT[2].x) + @abs(INT[2].y)) / @abs(det);
                var n2: i32 = @intFromFloat(@floor(c2 - r2));
                while (n2 <= @as(i32, @intFromFloat(@ceil(c2 + r2)))) : (n2 += 1) {
                    var n3: i32 = @intFromFloat(@floor(c3 - r3));
                    while (n3 <= @as(i32, @intFromFloat(@ceil(c3 + r3)))) : (n3 += 1) {
                        const n = [4]i32{ n0, n1, n2, n3 };
                        const q = r.add(INT[2].scale(@floatFromInt(n2))).add(INT[3].scale(@floatFromInt(n3)));
                        if (!inWindow(q.sub(shift))) continue;
                        const p = phys(n);
                        if (p.x < x0 or p.x > x1 or p.y < y0 or p.y > y1) continue;
                        try map.put(gpa, n, @intCast(s.keys.items.len));
                        try s.keys.append(gpa, n);
                        try s.points.append(gpa, p);
                    }
                }
            }
        }
        // edges
        try s.nbs.resize(gpa, s.keys.items.len);
        for (s.keys.items, s.nbs.items) |n, *nb| {
            for (DELTA, 0..) |d, k| {
                var m = n;
                for (0..4) |c| m[c] += d[c];
                nb[k] = map.get(m) orelse NONE;
            }
        }
        // faces: follow every edge with the face on its left; at each vertex
        // take the first edge clockwise from the one coming in
        var seen: std.AutoHashMapUnmanaged([2]u32, void) = .empty;
        defer seen.deinit(gpa);
        var verts: std.ArrayListUnmanaged(u32) = .empty;
        defer verts.deinit(gpa);
        for (s.nbs.items, 0..) |nb, v0| {
            for (0..12) |k0| {
                if (nb[k0] == NONE or seen.contains(.{ @intCast(v0), @intCast(k0) })) continue;
                verts.clearRetainingCapacity();
                var v: u32 = @intCast(v0);
                var k: u32 = @intCast(k0);
                var turns: [7]u32 = undefined;
                var ok = true;
                while (true) {
                    try seen.put(gpa, .{ v, k }, {});
                    if (verts.items.len >= 6) ok = false;
                    if (ok) try verts.append(gpa, v);
                    const w = s.nbs.items[v][k];
                    const back = (k + 6) % 12;
                    var k2 = (back + 11) % 12;
                    while (s.nbs.items[w][k2] == NONE) k2 = (k2 + 11) % 12;
                    // exterior angle in steps of 30°
                    if (ok) turns[verts.items.len - 1] = (k2 + 12 - k) % 12;
                    v = w;
                    k = k2;
                    if (v == v0 and k == k0) break;
                    if (seen.contains(.{ v, k })) {
                        ok = false;
                        break;
                    }
                }
                if (!ok) continue;
                const t = turns[0..verts.items.len];
                const valid = switch (t.len) {
                    3 => std.mem.allEqual(u32, t, 4),
                    4 => std.mem.allEqual(u32, t, 3),
                    6 => (t[0] == 3 and t[1] == 1 and t[2] == 3 and t[3] == 1 and t[4] == 3 and t[5] == 1) or
                        (t[0] == 1 and t[1] == 3 and t[2] == 1 and t[3] == 3 and t[4] == 1 and t[5] == 3),
                    else => false,
                };
                if (!valid) continue;
                const ti: u32 = @intCast(s.tiles.items.len);
                try s.tiles.append(gpa, try gpa.dupe(u32, verts.items));
                for (verts.items, 0..) |a0, i| {
                    const b0 = verts.items[(i + 1) % verts.items.len];
                    for (0..12) |kk| {
                        if (s.nbs.items[a0][kk] == b0) try s.left.put(gpa, .{ a0, @intCast(kk) }, ti);
                    }
                }
            }
        }
        return s;
    }

    fn center(s: *const Shield, t: []const u32) Vec2 {
        var c = Vec2{};
        for (t) |v| c = c.add(s.points.items[v]);
        return c.scale(1.0 / @as(f64, @floatFromInt(t.len)));
    }
};

fn randomShift(rand: *rng.Random) Vec2 {
    return .{ .x = rand.unit() - 0.5, .y = rand.unit() - 0.5 };
}

pub fn newShieldMaze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const tmp = arena_state.allocator();
    const scale = 1.0 / @sqrt(SHIELD_MEAN_AREA);
    const w = @as(f64, @floatFromInt(params.columns)) / scale;
    const h = @as(f64, @floatFromInt(params.rows)) / scale;
    const s = try Shield.generate(tmp, -2, -2, w + 2, h + 2, randomShift(rand));
    var tiles: std.ArrayListUnmanaged(tiling.Tile) = .empty;
    for (s.tiles.items) |t| {
        const c = s.center(t);
        if (c.x < 0 or c.x > w or c.y < 0 or c.y > h) continue;
        const ty: u8 = switch (t.len) {
            3 => mz.TYPE_A,
            4 => mz.TYPE_A + 1,
            else => mz.TYPE_A + 2,
        };
        try tiles.append(tmp, .{ .type = ty, .verts = t, .center = c.scale(scale) });
    }
    const pts = try tmp.alloc(Vec2, s.points.items.len);
    for (pts, s.points.items) |*p, q| p.* = q.scale(scale);
    return tiling.buildMaze(gpa, params, rand, pts, tiles.items);
}

pub fn newWheelMaze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const tmp = arena_state.allocator();
    const scale = 1.0 / @sqrt(WHEEL_MEAN_AREA);
    const w = @as(f64, @floatFromInt(params.columns)) / scale;
    const h = @as(f64, @floatFromInt(params.rows)) / scale;
    const s = try Shield.generate(tmp, -4, -4, w + 4, h + 4, randomShift(rand));

    // the wheel edges: one per shield edge with tiles on both sides; their
    // end points are keyed by 6 times their Z⁴ coordinates (exact)
    var ids: std.AutoHashMapUnmanaged([4]i32, u32) = .empty;
    var pts: std.ArrayListUnmanaged(Vec2) = .empty;
    var nbs: std.ArrayListUnmanaged([12]u32) = .empty;
    const endpoint = struct {
        // end of the new edge of (v, k) inside the tile on the left
        fn f(sh: *const Shield, v: u32, k: usize) ?[4]i32 {
            const ti = sh.left.get(.{ v, @intCast(k) }) orelse return null;
            var key: [4]i32 = undefined;
            const n = sh.keys.items[v];
            if (sh.tiles.items[ti].len == 3) {
                // triangle center: v + (2·δ_k + δ_{k+4}) / 3
                for (0..4) |c| key[c] = 6 * n[c] + 4 * DELTA[k][c] + 2 * DELTA[(k + 4) % 12][c];
            } else {
                // midpoint plus half the left normal: v + (δ_k + δ_{k+3}) / 2
                for (0..4) |c| key[c] = 6 * n[c] + 3 * DELTA[k][c] + 3 * DELTA[(k + 3) % 12][c];
            }
            return key;
        }
    }.f;
    const vid = struct {
        fn f(a: Allocator, m: *std.AutoHashMapUnmanaged([4]i32, u32), p: *std.ArrayListUnmanaged(Vec2), nb: *std.ArrayListUnmanaged([12]u32), key: [4]i32) !u32 {
            const gop = try m.getOrPut(a, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(p.items.len);
                var v = Vec2{};
                for (0..4) |k| v = v.add(PHYS[k].scale(@as(f64, @floatFromInt(key[k])) / 6.0));
                try p.append(a, v);
                try nb.append(a, @splat(NONE));
            }
            return gop.value_ptr.*;
        }
    }.f;
    for (s.nbs.items, 0..) |nb, v| {
        for (0..12) |k| {
            const u = nb[k];
            if (u == NONE or u < v) continue;
            const pk = endpoint(&s, @intCast(v), k) orelse continue;
            const qk = endpoint(&s, u, (k + 6) % 12) orelse continue;
            const p = try vid(tmp, &ids, &pts, &nbs, pk);
            const q = try vid(tmp, &ids, &pts, &nbs, qk);
            // from the left end to the right end: direction k - 90°
            const d = (k + 9) % 12;
            nbs.items[p][d] = q;
            nbs.items[q][(d + 6) % 12] = p;
        }
    }

    // the faces of the wheel edges
    var tiles: std.ArrayListUnmanaged(tiling.Tile) = .empty;
    var seen: std.AutoHashMapUnmanaged([2]u32, void) = .empty;
    var verts: std.ArrayListUnmanaged(u32) = .empty;
    const MAX_VERTS = 24;
    for (nbs.items, 0..) |nb, v0| {
        for (0..12) |k0| {
            if (nb[k0] == NONE or seen.contains(.{ @intCast(v0), @intCast(k0) })) continue;
            verts.clearRetainingCapacity();
            var v: u32 = @intCast(v0);
            var k: u32 = @intCast(k0);
            var turn: i32 = 0;
            var ok = true;
            while (true) {
                try seen.put(tmp, .{ v, k }, {});
                if (verts.items.len >= MAX_VERTS) ok = false;
                if (ok) try verts.append(tmp, v);
                const nxt = nbs.items[v][k];
                const back = (k + 6) % 12;
                var k2 = (back + 11) % 12;
                while (nbs.items[nxt][k2] == NONE) k2 = (k2 + 11) % 12;
                turn += @as(i32, @intCast((k2 + 18 - k) % 12)) - 6;
                v = nxt;
                k = k2;
                if (v == v0 and k == k0) break;
                if (seen.contains(.{ v, k })) {
                    ok = false;
                    break;
                }
            }
            // bounded faces turn once counter clockwise
            if (!ok or turn != 12) continue;
            var c = Vec2{};
            var area: f64 = 0;
            const n = verts.items.len;
            for (0..n) |i| {
                const a = pts.items[verts.items[i]];
                const b = pts.items[verts.items[(i + 1) % n]];
                const cr = a.x * b.y - a.y * b.x;
                area += cr;
                c = c.add(a.add(b).scale(cr));
            }
            c = c.scale(1.0 / (3.0 * area));
            if (c.x < 0 or c.x > w or c.y < 0 or c.y > h) continue;
            try tiles.append(tmp, .{
                .type = if (n == 5) mz.TYPE_A else mz.TYPE_A + 1,
                .verts = try tmp.dupe(u32, verts.items),
                .center = c.scale(scale),
            });
        }
    }
    for (pts.items) |*p| p.* = p.scale(scale);
    return tiling.buildMaze(gpa, params, rand, pts.items, tiles.items);
}

fn polyArea(m: *Maze, c: *mz.Cell) f64 {
    var a: f64 = 0;
    for (0..c.nWalls()) |i| {
        const wl = m.cellWall(c, i);
        // orient the wall as seen from the cell
        const p = wl.points[0].sub(c.center);
        const q = wl.points[1].sub(c.center);
        a += @abs(p.x * q.y - p.y * q.x) / 2;
    }
    return a;
}

test "shield tiling: triangles, squares and shields of the expected shape" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const s = try Shield.generate(arena_state.allocator(), 0, 0, 30, 30, .{ .x = 0.123, .y = -0.0456 });
    var count: [7]f64 = @splat(0);
    var area: f64 = 0;
    for (s.tiles.items) |t| {
        const c = s.center(t);
        if (c.x < 3 or c.x > 27 or c.y < 3 or c.y > 27) continue;
        count[t.len] += 1;
        for (0..t.len) |i| {
            const a = s.points.items[t[i]];
            const b = s.points.items[t[(i + 1) % t.len]];
            area += (a.x * b.y - a.y * b.x) / 2;
            try std.testing.expectApproxEqAbs(@as(f64, 1), a.sub(b).len(), 1e-9);
        }
    }
    const n = count[3] + count[4] + count[6];
    // the inner 24x24 square is covered (up to its boundary)
    try std.testing.expect(@abs(area - 24 * 24) < 4 * 24 * 2);
    try std.testing.expectApproxEqAbs(SHIELD_MEAN_AREA, area / n, 0.03);
    try std.testing.expect(count[3] > 0 and count[4] > 0 and count[6] > 0);
}

test "shield and wheel mazes have the expected cell sizes" {
    const gpa = std.testing.allocator;
    inline for (.{ newShieldMaze, newWheelMaze }, .{ [_]usize{ 3, 4, 6 }, [_]usize{ 5, 12 } }) |f, walls| {
        var params: Params = .{ .rows = 30, .columns = 30 };
        var rand = rng.Random.init(4);
        const m = try f(gpa, &params, &rand);
        defer m.deinit();
        var area: f64 = 0;
        for (m.cells[0..m.n_cells]) |*c| {
            const nw = c.nWalls();
            try std.testing.expect(std.mem.indexOfScalar(usize, &walls, nw) != null);
            area += polyArea(m, c);
        }
        const mean = area / @as(f64, @floatFromInt(m.n_cells));
        try std.testing.expectApproxEqAbs(@as(f64, 1), mean, 0.05);
        try std.testing.expect(m.n_cells > 750 and m.n_cells < 950);
    }
}
