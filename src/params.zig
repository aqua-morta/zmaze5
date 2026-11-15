//! Named string parameters, as given on the command line, with JSON
//! persistence (`--save` / `--load`, default file `~/.maze5.last`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Parameters = struct {
    gpa: Allocator,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    values: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(gpa: Allocator) Parameters {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Parameters) void {
        for (self.names.items, self.values.items) |n, v| {
            self.gpa.free(n);
            self.gpa.free(v);
        }
        self.names.deinit(self.gpa);
        self.values.deinit(self.gpa);
    }

    pub fn get(self: *const Parameters, name: []const u8) ?[]const u8 {
        for (self.names.items, self.values.items) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        return null;
    }

    /// Sets a parameter unless it is already set; returns whether it was set.
    pub fn set(self: *Parameters, name: []const u8, value: []const u8) !bool {
        if (self.get(name) != null) return false;
        try self.put(name, value);
        return true;
    }

    /// Sets or replaces a parameter.
    pub fn put(self: *Parameters, name: []const u8, value: []const u8) !void {
        const v = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(v);
        for (self.names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) {
                self.gpa.free(self.values.items[i]);
                self.values.items[i] = v;
                return;
            }
        }
        const n = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(n);
        try self.names.append(self.gpa, n);
        errdefer _ = self.names.pop();
        try self.values.append(self.gpa, v);
    }

    /// Serialises the parameters as a JSON object of strings.
    pub fn toJson(self: *const Parameters, gpa: Allocator) ![]u8 {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
        s.beginObject() catch return error.OutOfMemory;
        for (self.names.items, self.values.items) |n, v| {
            s.objectField(n) catch return error.OutOfMemory;
            s.write(v) catch return error.OutOfMemory;
        }
        s.endObject() catch return error.OutOfMemory;
        aw.writer.writeByte('\n') catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    /// Adds all parameters from a JSON object (string values only; other
    /// scalar values are converted to strings).
    pub fn fromJson(self: *Parameters, text: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        if (root != .object) return error.InvalidParameterFile;
        var it = root.object.iterator();
        while (it.next()) |e| {
            const v: []const u8 = switch (e.value_ptr.*) {
                .string => |s| s,
                .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
                .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
                .bool => |b| if (b) "1" else "0",
                .number_string => |s| s,
                else => return error.InvalidParameterFile,
            };
            try self.put(e.key_ptr.*, v);
        }
    }

    pub fn save(self: *const Parameters, io: Io, path: []const u8) !void {
        const json = try self.toJson(self.gpa);
        defer self.gpa.free(json);
        if (std.mem.eql(u8, path, "-")) {
            try Io.File.stdout().writeStreamingAll(io, json);
        } else {
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
        }
    }

    pub fn load(self: *Parameters, io: Io, path: []const u8) !void {
        const text = if (std.mem.eql(u8, path, "-")) blk: {
            var buf: [4096]u8 = undefined;
            var reader = Io.File.stdin().readerStreaming(io, &buf);
            break :blk try reader.interface.allocRemaining(self.gpa, .limited(1 << 20));
        } else try Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(1 << 20));
        defer self.gpa.free(text);
        try self.fromJson(text);
    }
};

test "set, get and json round trip" {
    const gpa = std.testing.allocator;
    var p = Parameters.init(gpa);
    defer p.deinit();
    try std.testing.expect(try p.set("type", "4"));
    try std.testing.expect(!try p.set("type", "6"));
    try p.put("rows", "20");
    try std.testing.expectEqualStrings("4", p.get("type").?);
    const json = try p.toJson(gpa);
    defer gpa.free(json);
    var q = Parameters.init(gpa);
    defer q.deinit();
    try q.fromJson(json);
    try std.testing.expectEqualStrings("20", q.get("rows").?);
    try std.testing.expectEqualStrings("4", q.get("type").?);
}
