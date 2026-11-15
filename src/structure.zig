//! Description of a maze "structure" (tiling). Periodic structures carry a
//! tile description (cells, their centers and their neighbour walls); the
//! circular and voronoi structures only carry their constructor kind.

const std = @import("std");
const geo = @import("geo.zig");
const tables = @import("structures.zig");

pub const Vec2 = geo.Vec2;

/// Feature flags of a structure.
pub const ARCS: u32 = 0x001;
pub const TILEABLE: u32 = 0x002;
pub const RINGS: u32 = 0x004;
pub const SEGMENTS: u32 = 0x008;
pub const RANDOMNESS: u32 = 0x010;
pub const CROSSOVERS: u32 = 0x020;

/// Wall feature flags.
pub const WALL_ARC: u8 = 1;
pub const WALL_BRIDGEABLE: u8 = 2;
pub const WALL_INDESTRUCTIBLE: u8 = 128;

pub const Construct = enum {
    periodic,
    theta,
    voronoi,
    voronoi4,
    voronoi6,
    voronoi3,
    voronoi_disc,
    penrose,
    penrose_rhombs,
    einstein,
    ammann_beenker,
    supergolden,
    shield,
    wheel,
    socolar,
    clamshell,
    pentagonal_rotational,
};

/// A neighbour of a tile cell together with the wall separating them. The
/// wall coordinates are relative to the cell center.
pub const Neighbour = struct {
    dx: i32,
    dy: i32,
    p1: Vec2,
    p2: Vec2,
    features: u8 = 0,
    value: f64 = 0,
};

pub const Structure = struct {
    name: []const u8,
    kind: []const u8,
    construct: Construct,
    features: u32,
    rows: i32 = 0,
    columns: i32 = 0,
    width: f64 = 0,
    height: f64 = 0,
    xminadd: f64 = 0,
    yminadd: f64 = 0,
    xmaxadd: f64 = 0,
    ymaxadd: f64 = 0,
    center_points: []const Vec2 = &.{},
    cell_types: []const u8 = &.{},
    /// neighbours[cell_type & ~CROSSABLE]
    neighbours: []const []const Neighbour = &.{},

    pub inline fn has(self: *const Structure, f: u32) bool {
        return (self.features & f) != 0;
    }

    pub inline fn center(self: *const Structure, xi: usize, yi: usize) Vec2 {
        return self.center_points[yi * @as(usize, @intCast(self.columns)) + xi];
    }

    pub inline fn cellType(self: *const Structure, xi: usize, yi: usize) u8 {
        return self.cell_types[yi * @as(usize, @intCast(self.columns)) + xi];
    }

    pub inline fn border(self: *const Structure, cell_type: u8) []const Neighbour {
        return self.neighbours[cell_type & ~@as(u8, 64)];
    }
};

pub const default = tables.all[0];

const Alias = struct {
    names: []const []const u8,
    group: []const *const Structure,
};

const aliases = [_]Alias{
    .{ .names = &.{ "3", "triangular" }, .group = &tables.tria },
    .{ .names = &.{ "4", "orthogonal" }, .group = &tables.ortho },
    .{ .names = &.{ "6", "hexagonal", "sigma" }, .group = &tables.hexa },
    .{ .names = &.{ "6-4", "hexagon-square" }, .group = &tables.hexa_square },
    .{ .names = &.{ "3-4", "triangle-square" }, .group = &tables.triangle_square },
    .{ .names = &.{ "8-4", "octagon-square" }, .group = &tables.octa_square },
    .{ .names = &.{"hexagonal-rhombic"}, .group = &tables.hexa_rhombic },
    .{ .names = &.{ "rhombic", "zeta" }, .group = &tables.rhombic },
    .{ .names = &.{"cairo"}, .group = &tables.cairo },
    .{ .names = &.{"house"}, .group = &tables.pentagon_house },
    .{ .names = &.{ "pentagonal_1", "5_1" }, .group = &tables.pentagon_1 },
    .{ .names = &.{ "pentagonal_2", "5_2" }, .group = &tables.pentagon_2 },
    .{ .names = &.{ "pentagonal_3", "5_3" }, .group = &tables.pentagon_3 },
    .{ .names = &.{ "pentagonal_10", "5_10" }, .group = &tables.pentagon_10 },
    .{ .names = &.{"6-4-3"}, .group = &tables.hexa_ortho_tria },
    .{ .names = &.{ "12-6-4", "square-hexagon-dodecagon" }, .group = &tables.truncated_trihexagonal },
    .{ .names = &.{ "floret", "floret-pentagonal" }, .group = &tables.floret },
    .{ .names = &.{"theta"}, .group = &tables.theta },
    .{ .names = &.{ "pentagonal-rotational", "klaassen" }, .group = &tables.pentagon_rotational },
    .{ .names = &.{"random"}, .group = &tables.random },
    .{ .names = &.{"random-4"}, .group = &tables.random4 },
    .{ .names = &.{"random-6"}, .group = &tables.random6 },
    .{ .names = &.{"random-3"}, .group = &tables.random3 },
    .{ .names = &.{"random-disc"}, .group = &tables.random_disc },
    .{ .names = &.{ "penrose", "kite-dart" }, .group = &tables.penrose },
    .{ .names = &.{ "einstein", "hat" }, .group = &tables.einstein },
    .{ .names = &.{ "ammann-beenker", "ammann" }, .group = &tables.ammann_beenker },
    .{ .names = &.{ "supergolden", "stepped-plane" }, .group = &tables.supergolden },
    .{ .names = &.{"shield"}, .group = &tables.shield },
    .{ .names = &.{"wheel"}, .group = &tables.wheel },
    .{ .names = &.{ "socolar", "butterfly" }, .group = &tables.socolar },
    .{ .names = &.{"clamshell"}, .group = &tables.clamshell },
};

/// Writes all maze types as a JSON array, for user interfaces: the type
/// specification (`spec`, e.g. "6:2") with its alias names, the display
/// name, kind, construction, features, cell types with their numbers of
/// neighbours.
pub fn writeTypesJson(w: *std.Io.Writer) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{} };
    try s.beginArray();
    for (aliases) |a| {
        for (a.group, 1..) |st, variant| {
            var buf: [64]u8 = undefined;
            const spec = if (a.group.len > 1) std.fmt.bufPrint(&buf, "{s}:{d}", .{ a.names[0], variant }) catch unreachable else a.names[0];
            try s.beginObject();
            try s.objectField("spec");
            try s.write(spec);
            try s.objectField("names");
            try s.write(a.names);
            try s.objectField("variant");
            try s.write(variant);
            try s.objectField("variants");
            try s.write(a.group.len);
            try s.objectField("name");
            try s.write(st.name);
            try s.objectField("kind");
            try s.write(st.kind);
            try s.objectField("construct");
            try s.write(@tagName(st.construct));
            try s.objectField("features");
            try s.beginArray();
            const flags = .{ .{ "arcs", ARCS }, .{ "tileable", TILEABLE }, .{ "rings", RINGS }, .{ "segments", SEGMENTS }, .{ "randomness", RANDOMNESS }, .{ "crossovers", CROSSOVERS } };
            inline for (flags) |f| {
                if (st.has(f[1])) try s.write(f[0]);
            }
            try s.endArray();
            try s.objectField("cells");
            try s.beginArray();
            for (st.neighbours, 0..) |n, i| {
                const letter = [1]u8{'A' + @as(u8, @intCast(i))};
                try s.beginObject();
                try s.objectField("type");
                try s.write(letter[0..]);
                try s.objectField("neighbours");
                try s.write(n.len);
                try s.endObject();
            }
            try s.endArray();
            try s.endObject();
        }
    }
    try s.endArray();
}

test "types json lists every structure" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeTypesJson(&aw.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const list = parsed.value.array.items;
    try std.testing.expectEqual(tables.all.len, list.len);
    var hexa2: ?std.json.Value = null;
    for (list) |item| {
        const spec = item.object.get("spec").?.string;
        // every spec resolves to the structure it describes
        const st = try lookup(spec);
        try std.testing.expectEqualStrings(st.name, item.object.get("name").?.string);
        if (std.mem.eql(u8, spec, "6:2")) hexa2 = item;
    }
    const features = hexa2.?.object.get("features").?.array.items;
    try std.testing.expectEqualStrings("arcs", features[0].string);
    try std.testing.expectEqual(@as(usize, 2), hexa2.?.object.get("cells").?.array.items.len);
}

pub const LookupError = error{ UnknownType, InvalidVariant };

/// Resolves a type specification like `hexagonal` or `6:2` to a structure.
pub fn lookup(spec: []const u8) LookupError!*const Structure {
    var name = spec;
    var variant: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, spec, ':')) |sep| {
        name = spec[0..sep];
        const v = std.fmt.parseInt(usize, spec[sep + 1 ..], 0) catch return error.InvalidVariant;
        if (v == 0) return error.InvalidVariant;
        variant = v - 1;
    }
    for (aliases) |alias| {
        for (alias.names) |n| {
            if (std.mem.eql(u8, n, name)) {
                if (variant >= alias.group.len) return error.InvalidVariant;
                return alias.group[variant];
            }
        }
    }
    return error.UnknownType;
}

test "lookup" {
    try std.testing.expectEqualStrings("Hexagonal (Arcs)", (try lookup("6:2")).name);
    try std.testing.expectEqualStrings("Theta", (try lookup("theta")).name);
    try std.testing.expectEqualStrings("Penrose (Kites & Darts)", (try lookup("penrose")).name);
    try std.testing.expectEqualStrings("Einstein (Hat)", (try lookup("einstein")).name);
    try std.testing.expectError(error.InvalidVariant, lookup("cairo:3"));
    try std.testing.expectError(error.UnknownType, lookup("nope"));
}

test "tables are consistent" {
    for (tables.all) |s| {
        if (s.construct != .periodic) continue;
        const n: usize = @intCast(s.rows * s.columns);
        try std.testing.expectEqual(n, s.center_points.len);
        try std.testing.expectEqual(n, s.cell_types.len);
        for (s.cell_types) |t| {
            if (t == 255) continue;
            try std.testing.expect(s.border(t).len >= 3);
        }
    }
}

test "neighbours in the tables point back across the same wall" {
    for (tables.all) |s| {
        if (s.construct != .periodic) continue;
        const cols: i32 = s.columns;
        const rows: i32 = s.rows;
        for (0..@intCast(rows)) |ry| for (0..@intCast(cols)) |rx| {
            const t = s.cellType(rx, ry);
            if (t == 255) continue;
            const c = s.center(rx, ry);
            for (s.border(t)) |n| {
                // the neighbour's slot and tile
                const gx = @as(i32, @intCast(rx)) + n.dx;
                const gy = @as(i32, @intCast(ry)) + n.dy;
                const qx = @divFloor(gx, cols);
                const qy = @divFloor(gy, rows);
                const nx: usize = @intCast(gx - qx * cols);
                const ny: usize = @intCast(gy - qy * rows);
                const nt = s.cellType(nx, ny);
                if (nt == 255) {
                    std.debug.print("{s}: ({d},{d}) has no cell at offset ({d},{d})\n", .{ s.name, rx, ry, n.dx, n.dy });
                    return error.MissingNeighbour;
                }
                const nc = s.center(nx, ny).add(.{ .x = @as(f64, @floatFromInt(qx)) * s.width, .y = @as(f64, @floatFromInt(qy)) * s.height });
                const p1 = c.add(n.p1);
                const p2 = c.add(n.p2);
                var found = false;
                for (s.border(nt)) |m| {
                    if (m.dx != -n.dx or m.dy != -n.dy) continue;
                    const q1 = nc.add(m.p1);
                    const q2 = nc.add(m.p2);
                    const eps = 1e-9;
                    if ((q1.sub(p2).len() < eps and q2.sub(p1).len() < eps) or (q1.sub(p1).len() < eps and q2.sub(p2).len() < eps)) found = true;
                }
                if (!found) {
                    std.debug.print("{s}: ({d},{d}) offset ({d},{d}) has no matching wall back\n", .{ s.name, rx, ry, n.dx, n.dy });
                    return error.NoWallBack;
                }
            }
        };
    }
}

/// Cell types of a structure with their number of neighbours, e.g.
/// "A(6),B(4)" (empty for structures without a tile table).
fn cellTypes(w: *std.Io.Writer, s: *const Structure) !void {
    for (s.neighbours, 0..) |n, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{c}({d})", .{ @as(u8, 'A') + @as(u8, @intCast(i)), n.len });
    }
}

test "the help text lists the cell types of every tiled maze type" {
    const help = @import("help.zig");
    for (aliases) |a| {
        if (a.group[0].neighbours.len == 0) continue;
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var same = true;
        for (a.group) |s| {
            var b1: [64]u8 = undefined;
            var b2: [64]u8 = undefined;
            var w1: std.Io.Writer = .fixed(&b1);
            var w2: std.Io.Writer = .fixed(&b2);
            try cellTypes(&w1, a.group[0]);
            try cellTypes(&w2, s);
            if (!std.mem.eql(u8, w1.buffered(), w2.buffered())) same = false;
        }
        try w.writeAll("[");
        if (same) {
            try cellTypes(&w, a.group[0]);
        } else for (a.group, 1..) |s, i| {
            if (i > 1) try w.writeAll("; ");
            try w.print("{d}: ", .{i});
            try cellTypes(&w, s);
        }
        try w.writeAll("]");
        // the cell types are on the line after the one naming the type
        var qbuf: [64]u8 = undefined;
        const quoted = try std.fmt.bufPrint(&qbuf, "'{s}'", .{a.names[a.names.len - 1]});
        var it = std.mem.splitScalar(u8, help.text, '\n');
        while (it.next()) |l| {
            if (std.mem.indexOf(u8, l, quoted) != null) break;
        } else return error.TypeNotInHelp;
        const line = std.mem.trim(u8, it.next() orelse "", " ");
        if (!std.mem.eql(u8, line, w.buffered())) {
            std.debug.print("help for {s} should be {s}, is {s}\n", .{ a.names[0], w.buffered(), line });
            return error.WrongCellTypes;
        }
    }
}
