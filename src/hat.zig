//! Aperiodic mazes based on the "einstein" hat monotile (D. Smith, J. S.
//! Myers, C. S. Kaplan, C. Goodman-Strauss, 2023): a single tile - made of
//! eight kites - which tiles the plane only aperiodically.
//!
//! The tiling is generated with the H/T/P/F metatile substitution system
//! of the paper, following Craig S. Kaplan's reference implementation
//! (hatviz): four clusters of hats (metatiles) are combined level by level to
//! bigger metatiles of the same four kinds.

const std = @import("std");
const geo = @import("geo.zig");
const mz = @import("maze.zig");
const rng = @import("rng.zig");
const tiling = @import("tiling.zig");

const Allocator = std.mem.Allocator;
const Vec2 = geo.Vec2;
const Maze = mz.Maze;
const Params = mz.Params;

const hr3: f64 = @sqrt(3.0) / 2.0;

// ---------------------------------------------------------------------------
// affine transformations: x' = a*x + b*y + c, y' = d*x + e*y + f

const Affine = [6]f64;

const ident: Affine = .{ 1, 0, 0, 0, 1, 0 };

fn mul(A: Affine, B: Affine) Affine {
    return .{
        A[0] * B[0] + A[1] * B[3], A[0] * B[1] + A[1] * B[4], A[0] * B[2] + A[1] * B[5] + A[2],
        A[3] * B[0] + A[4] * B[3], A[3] * B[1] + A[4] * B[4], A[3] * B[2] + A[4] * B[5] + A[5],
    };
}

fn inv(T: Affine) Affine {
    const det = T[0] * T[4] - T[1] * T[3];
    return .{
        T[4] / det,  -T[1] / det, (T[1] * T[5] - T[2] * T[4]) / det,
        -T[3] / det, T[0] / det,  (T[2] * T[3] - T[0] * T[5]) / det,
    };
}

fn ttrans(x: f64, y: f64) Affine {
    return .{ 1, 0, x, 0, 1, y };
}

fn rotAbout(p: Vec2, ang: f64) Affine {
    const sc = geo.sincos(ang);
    return mul(ttrans(p.x, p.y), mul(.{ sc.cos, -sc.sin, 0, sc.sin, sc.cos, 0 }, ttrans(-p.x, -p.y)));
}

fn tp(M: Affine, p: Vec2) Vec2 {
    return .{ .x = M[0] * p.x + M[1] * p.y + M[2], .y = M[3] * p.x + M[4] * p.y + M[5] };
}

/// Similarity mapping the segment (0,0)-(1,0) to p-q.
fn matchSeg(p: Vec2, q: Vec2) Affine {
    return .{ q.x - p.x, p.y - q.y, p.x, q.y - p.y, q.x - p.x, p.y };
}

/// Similarity mapping p1 to p2 and q1 to q2.
fn matchTwo(p1: Vec2, q1: Vec2, p2: Vec2, q2: Vec2) Affine {
    return mul(matchSeg(p2, q2), inv(matchSeg(p1, q1)));
}

/// Intersection of the lines p1-q1 and p2-q2.
fn intersect(p1: Vec2, q1: Vec2, p2: Vec2, q2: Vec2) Vec2 {
    const d = (q2.y - p2.y) * (q1.x - p1.x) - (q2.x - p2.x) * (q1.y - p1.y);
    const u = ((q2.x - p2.x) * (p1.y - p2.y) - (q2.y - p2.y) * (p1.x - p2.x)) / d;
    return .{ .x = p1.x + u * (q1.x - p1.x), .y = p1.y + u * (q1.y - p1.y) };
}

fn pt(x: f64, y: f64) Vec2 {
    return .{ .x = x, .y = y };
}

/// Point of the triangular grid the hat's kites live on.
fn hexPt(x: f64, y: f64) Vec2 {
    return .{ .x = x + 0.5 * y, .y = hr3 * y };
}

// ---------------------------------------------------------------------------
// hats and metatiles

const hat_outline = [_]Vec2{
    hexPt(0, 0),  hexPt(-1, -1), hexPt(0, -2), hexPt(2, -2),
    hexPt(2, -1), hexPt(4, -2),  hexPt(5, -1), hexPt(4, 0),
    hexPt(3, 0),  hexPt(2, 2),   hexPt(0, 3),  hexPt(0, 2),
    hexPt(-1, 2),
};

const Geom = union(enum) {
    /// a hat; true if it is a reflected one
    hat: bool,
    meta: *const Meta,

    fn shape(g: Geom) []const Vec2 {
        return switch (g) {
            .hat => &hat_outline,
            .meta => |m| m.shape,
        };
    }
};

const Child = struct { t: Affine, g: Geom };

const Meta = struct {
    shape: []Vec2,
    children: std.ArrayListUnmanaged(Child) = .empty,
    /// distance of the farthest outline point from the origin
    radius: f64 = 0,

    fn create(a: Allocator, shape: []const Vec2) !*Meta {
        const m = try a.create(Meta);
        m.* = .{ .shape = try a.dupe(Vec2, shape) };
        return m;
    }

    fn add(m: *Meta, a: Allocator, t: Affine, g: Geom) !void {
        try m.children.append(a, .{ .t = t, .g = g });
    }

    fn evalChild(m: *const Meta, n: usize, i: usize) Vec2 {
        const ch = m.children.items[n];
        return tp(ch.t, ch.g.shape()[i]);
    }

    /// Moves the centroid of the outline to the origin.
    fn recentre(m: *Meta) void {
        var c = Vec2{};
        for (m.shape) |p| c = c.add(p);
        c = c.scale(1.0 / @as(f64, @floatFromInt(m.shape.len)));
        for (m.shape) |*p| p.* = p.sub(c);
        const t = ttrans(-c.x, -c.y);
        for (m.children.items) |*ch| ch.t = mul(t, ch.t);
        m.radius = 0;
        for (m.shape) |p| m.radius = @max(m.radius, p.len());
    }
};

const Shape = enum { H, T, P, F };
const Set = [4]*const Meta;

/// The four initial metatiles (H: 4 hats, one of them reflected; T: 1 hat;
/// P and F: 2 hats each).
fn initialMetatiles(a: Allocator) !Set {
    const H_outline = [_]Vec2{ pt(0, 0), pt(4, 0), pt(4.5, hr3), pt(2.5, 5 * hr3), pt(1.5, 5 * hr3), pt(-0.5, hr3) };
    const H = try Meta.create(a, &H_outline);
    try H.add(a, matchTwo(hat_outline[5], hat_outline[7], H_outline[5], H_outline[0]), .{ .hat = false });
    try H.add(a, matchTwo(hat_outline[9], hat_outline[11], H_outline[1], H_outline[2]), .{ .hat = false });
    try H.add(a, matchTwo(hat_outline[5], hat_outline[7], H_outline[3], H_outline[4]), .{ .hat = false });
    try H.add(a, mul(ttrans(2.5, hr3), mul(.{ -0.5, -hr3, 0, hr3, -0.5, 0 }, .{ 0.5, 0, 0, 0, -0.5, 0 })), .{ .hat = true });

    const T = try Meta.create(a, &.{ pt(0, 0), pt(3, 0), pt(1.5, 3 * hr3) });
    try T.add(a, .{ 0.5, 0, 0.5, 0, 0.5, hr3 }, .{ .hat = false });

    const two_hats = [_]Affine{
        .{ 0.5, 0, 1.5, 0, 0.5, hr3 },
        mul(ttrans(0, 2 * hr3), mul(.{ 0.5, hr3, 0, -hr3, 0.5, 0 }, .{ 0.5, 0, 0, 0, 0.5, 0 })),
    };
    const P = try Meta.create(a, &.{ pt(0, 0), pt(4, 0), pt(3, 2 * hr3), pt(-1, 2 * hr3) });
    const F = try Meta.create(a, &.{ pt(0, 0), pt(3, 0), pt(3.5, hr3), pt(3, 2 * hr3), pt(-1, 2 * hr3) });
    for (two_hats) |t| {
        try P.add(a, t, .{ .hat = false });
        try F.add(a, t, .{ .hat = false });
    }
    return .{ H, T, P, F };
}

/// How a metatile of the patch is placed: either as the first one, by
/// matching its edge `nedge` to edge `edge` of child `src`, or by matching
/// its edge to the segment between point `pi` of child `p` and point `qi`
/// of child `q`.
const Rule = union(enum) {
    root: Shape,
    edge: struct { src: u8, edge: u8, shape: Shape, nedge: u8 },
    points: struct { p: u8, pi: u8, q: u8, qi: u8, shape: Shape, nedge: u8 },
};

fn r1(src: u8, edge: u8, shape: Shape, nedge: u8) Rule {
    return .{ .edge = .{ .src = src, .edge = edge, .shape = shape, .nedge = nedge } };
}

fn r2(p: u8, pi: u8, q: u8, qi: u8, shape: Shape, nedge: u8) Rule {
    return .{ .points = .{ .p = p, .pi = pi, .q = q, .qi = qi, .shape = shape, .nedge = nedge } };
}

const rules = [_]Rule{
    .{ .root = .H },  r1(0, 0, .P, 2),  r1(1, 0, .H, 2),       r1(2, 0, .P, 2),       r1(3, 0, .H, 2),
    r1(4, 4, .P, 2),  r1(0, 4, .F, 3),  r1(2, 4, .F, 3),       r2(4, 1, 3, 2, .F, 0), r1(8, 3, .H, 0),
    r1(9, 2, .P, 0),  r1(10, 2, .H, 0), r1(11, 4, .P, 2),      r1(12, 0, .H, 2),      r1(13, 0, .F, 3),
    r1(14, 2, .F, 1), r1(15, 3, .H, 4), r1(8, 2, .F, 1),       r1(17, 3, .H, 0),      r1(18, 2, .P, 0),
    r1(19, 2, .H, 2), r1(20, 4, .F, 3), r1(20, 0, .P, 2),      r1(22, 0, .H, 2),      r1(23, 4, .F, 3),
    r1(23, 0, .F, 3), r1(16, 0, .P, 2), r2(9, 4, 0, 2, .T, 2), r1(4, 0, .F, 3),
};

/// Arranges 29 metatiles to a patch from which the next level's metatiles
/// are cut out.
fn constructPatch(a: Allocator, set: Set) !*Meta {
    const patch = try Meta.create(a, &.{});
    for (rules) |rule| switch (rule) {
        .root => |s| try patch.add(a, ident, .{ .meta = set[@backingInt(s)] }),
        .edge => |r| {
            const ch = patch.children.items[r.src];
            const poly = ch.g.shape();
            const P = tp(ch.t, poly[(r.edge + 1) % poly.len]);
            const Q = tp(ch.t, poly[r.edge]);
            const ns = set[@backingInt(r.shape)];
            const np = ns.shape;
            try patch.add(a, matchTwo(np[r.nedge], np[(r.nedge + 1) % np.len], P, Q), .{ .meta = ns });
        },
        .points => |r| {
            const P = patch.evalChild(r.q, r.qi);
            const Q = patch.evalChild(r.p, r.pi);
            const ns = set[@backingInt(r.shape)];
            const np = ns.shape;
            try patch.add(a, matchTwo(np[r.nedge], np[(r.nedge + 1) % np.len], P, Q), .{ .meta = ns });
        },
    };
    return patch;
}

/// Cuts the next level's H, T, P and F metatiles out of a patch.
fn constructMetatiles(a: Allocator, patch: *const Meta) !Set {
    const bps1 = patch.evalChild(8, 2);
    const bps2 = patch.evalChild(21, 2);
    const rbps = tp(rotAbout(bps1, -2.0 * std.math.pi / 3.0), bps2);
    const p72 = patch.evalChild(7, 2);
    const p252 = patch.evalChild(25, 2);
    const llc = intersect(bps1, rbps, patch.evalChild(6, 2), p72);
    var w = patch.evalChild(6, 2).sub(llc);

    var h_outline: [6]Vec2 = undefined;
    h_outline[0] = llc;
    h_outline[1] = bps1;
    w = tp(rotAbout(.{}, -std.math.pi / 3.0), w);
    h_outline[2] = h_outline[1].add(w);
    h_outline[3] = patch.evalChild(14, 2);
    w = tp(rotAbout(.{}, -std.math.pi / 3.0), w);
    h_outline[4] = h_outline[3].sub(w);
    h_outline[5] = patch.evalChild(6, 2);
    const H = try Meta.create(a, &h_outline);
    for ([_]usize{ 0, 9, 16, 27, 26, 6, 1, 8, 10, 15 }) |c| try H.children.append(a, patch.children.items[c]);

    const P = try Meta.create(a, &.{ p72, p72.add(bps1.sub(llc)), bps1, llc });
    for ([_]usize{ 7, 2, 3, 4, 28 }) |c| try P.children.append(a, patch.children.items[c]);

    const F = try Meta.create(a, &.{ bps2, patch.evalChild(24, 2), patch.evalChild(25, 0), p252, p252.add(llc.sub(bps1)) });
    for ([_]usize{ 21, 20, 22, 23, 24, 25 }) |c| try F.children.append(a, patch.children.items[c]);

    const AAA = h_outline[2];
    const BBB = h_outline[1].add(h_outline[4].sub(h_outline[5]));
    const CCC = tp(rotAbout(BBB, -std.math.pi / 3.0), AAA);
    const T = try Meta.create(a, &.{ BBB, CCC, AAA });
    try T.children.append(a, patch.children.items[11]);

    for ([_]*Meta{ H, T, P, F }) |m| m.recentre();
    return .{ H, T, P, F };
}

// ---------------------------------------------------------------------------
// maze construction

/// Area of a hat in metatile units (8 kites).
const HAT_AREA: f64 = 2.0 * @sqrt(3.0);

const Collector = struct {
    a: Allocator,
    /// target rectangle (maze units)
    w: f64,
    h: f64,
    /// extra margin (maze units) for the pruning test
    margin: f64,
    scale: f64,
    verts: tiling.PointSet = .{},
    tiles: std.ArrayListUnmanaged(tiling.Tile) = .empty,

    /// Collects all hats of `g` (placed with `t`) whose center lies within
    /// the target rectangle. Metatiles far away are skipped.
    fn collect(self: *Collector, g: Geom, t: Affine) !void {
        switch (g) {
            .meta => |m| {
                // hats can stick out of the outline by about 20% of the
                // metatile's size, hence the generous radius
                const c = tp(t, .{});
                const r = m.radius * 1.3 * self.scale + self.margin;
                if (c.x + r < 0 or c.x - r > self.w or c.y + r < 0 or c.y - r > self.h) return;
                for (m.children.items) |ch| try self.collect(ch.g, mul(t, ch.t));
            },
            .hat => |reflected| try self.addHat(t, reflected),
        }
    }

    fn addHat(self: *Collector, t: Affine, reflected: bool) !void {
        var poly: [hat_outline.len]Vec2 = undefined;
        for (hat_outline, 0..) |p, i| poly[i] = tp(t, p);
        // area centroid (lies inside the hat)
        var area: f64 = 0;
        var c = Vec2{};
        for (0..poly.len) |i| {
            const p = poly[i];
            const q = poly[(i + 1) % poly.len];
            const cr = p.x * q.y - q.x * p.y;
            area += cr;
            c = c.add(p.add(q).scale(cr));
        }
        c = c.scale(1.0 / (3.0 * area));
        if (c.x < 0 or c.x > self.w or c.y < 0 or c.y > self.h) return;
        // split the edges into kite edges (an outline edge may border two
        // different neighbours) and order the vertices counter clockwise
        var vs: std.ArrayListUnmanaged(u32) = .empty;
        const unit = self.unitEdge();
        for (0..poly.len) |i| {
            const p = poly[i];
            const q = poly[(i + 1) % poly.len];
            const pieces: usize = if (@abs(q.sub(p).len() - 2.0 * unit) < 1e-6 * unit) 2 else 1;
            for (0..pieces) |k| {
                const f = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(pieces));
                try vs.append(self.a, try self.verts.id(self.a, p.add(q.sub(p).scale(f))));
            }
        }
        if (area < 0) std.mem.reverse(u32, vs.items);
        try self.tiles.append(self.a, .{
            .type = if (reflected) mz.TYPE_A + 1 else mz.TYPE_A,
            .verts = vs.items,
            .center = c,
        });
    }

    /// Length of a short kite edge in maze units (the hats in the metatiles
    /// are scaled by 1/2, the short kite edge of `hat_outline` is 1).
    fn unitEdge(self: *const Collector) f64 {
        return 0.5 * self.scale;
    }
};

pub fn newHatMaze(gpa: Allocator, params: *Params, rand: *rng.Random) !*Maze {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const w: f64 = @floatFromInt(params.columns);
    const h: f64 = @floatFromInt(params.rows);
    const half_diag = @sqrt(w * w + h * h) / 2.0;
    // one hat has about the area of a unit square
    const scale = 1.0 / @sqrt(HAT_AREA);

    // random rotation and offset of the patch
    const angle = rand.unit() * 2.0 * std.math.pi;
    const off_r = @sqrt(rand.unit()) * half_diag;
    const off_a = rand.unit() * 2.0 * std.math.pi;
    const needed = half_diag + off_r + 4.0;

    var set = try initialMetatiles(a);
    var patch: *Meta = undefined;
    while (true) {
        patch = try constructPatch(a, set);
        set = try constructMetatiles(a, patch);
        // inner radius of the H metatile's outline (with a safety factor of
        // 2 for hats not covering the outline exactly)
        const H = set[0];
        var inner: f64 = std.math.floatMax(f64);
        for (0..H.shape.len) |i| {
            const p = H.shape[i];
            const q = H.shape[(i + 1) % H.shape.len];
            const d = q.sub(p);
            inner = @min(inner, @abs(p.x * d.y - p.y * d.x) / d.len());
        }
        if (inner * scale * 0.5 >= needed) break;
    }

    // world transform: scale, rotate, then move the (offset) center of the H
    // metatile to the center of the maze
    const off = geo.sincos(off_a);
    const center = Vec2{ .x = w / 2.0 + off.cos * off_r, .y = h / 2.0 + off.sin * off_r };
    const world = mul(ttrans(center.x, center.y), mul(rotAbout(.{}, angle), .{ scale, 0, 0, 0, scale, 0 }));

    var col = Collector{ .a = a, .w = w, .h = h, .margin = 4.0, .scale = scale };
    try col.collect(.{ .meta = set[0] }, world);
    return tiling.buildMaze(gpa, params, rand, col.verts.points.items, col.tiles.items);
}

test "hat tiles" {
    const gpa = std.testing.allocator;
    var params: Params = .{ .rows = 25, .columns = 25 };
    var rand = rng.Random.init(5);
    const m = try newHatMaze(gpa, &params, &rand);
    defer m.deinit();
    // about one hat per unit square
    try std.testing.expect(m.n_cells > 450 and m.n_cells < 800);
    var reflected: usize = 0;
    for (m.cells[0..m.n_cells]) |*c| {
        if (c.type != mz.TYPE_A) reflected += 1;
        // a hat has 13 corners; walls are merged per neighbour
        try std.testing.expect(c.nWalls() >= 3 and c.nWalls() <= 14);
    }
    // unreflected : reflected hats tends to phi^4 (~6.85)
    const ratio = @as(f64, @floatFromInt(m.n_cells - reflected)) / @as(f64, @floatFromInt(reflected));
    try std.testing.expect(ratio > 4.5 and ratio < 10);
    // every wall between two cells is shared by exactly these two
    for (m.walls[0..m.n_walls]) |*wl| {
        try std.testing.expect(wl.cells[0] != wl.cells[1]);
    }
}
