//! Maze masks: a PNG image deciding which cells belong to the maze. Light
//! pixels (all of R, G and B above 0x80) keep a cell, dark pixels remove it.

const std = @import("std");
const png = @import("png.zig");

pub const Mask = struct {
    width: usize,
    height: usize,
    /// one entry per pixel, row major
    bits: []bool,

    pub const LoadError = error{ CannotLoad, UnsupportedFormat, OutOfMemory };

    /// Reads the mask file (any PNG format, see png.zig).
    pub fn load(gpa: std.mem.Allocator, io: std.Io, filename: []const u8) LoadError!Mask {
        const data = std.Io.Dir.cwd().readFileAlloc(io, filename, gpa, .limited(256 << 20)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.err("{s}: cannot read file ({t})", .{ filename, e });
                return error.CannotLoad;
            },
        };
        defer gpa.free(data);
        return fromPng(gpa, data, filename);
    }

    /// Decodes a PNG image into a mask; `name` is used in error messages.
    pub fn fromPng(gpa: std.mem.Allocator, data: []const u8, name: []const u8) LoadError!Mask {
        var img = png.decode(gpa, data) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.err("{s}: {s}", .{ name, switch (e) {
                    error.NotPng => "not a PNG file",
                    error.Unsupported => "unsupported PNG format",
                    else => "corrupt PNG file",
                } });
                return error.UnsupportedFormat;
            },
        };
        defer img.deinit(gpa);
        return fromRgba(gpa, img.width, img.height, img.pixels);
    }

    /// Light pixels (composited on white) belong to the maze.
    fn fromRgba(gpa: std.mem.Allocator, w: usize, h: usize, rgba: []const u8) LoadError!Mask {
        const bits = try gpa.alloc(bool, w * h);
        for (bits, 0..) |*b, i| {
            const px = rgba[i * 4 ..][0..4];
            const a: u32 = px[3];
            var light = true;
            for (px[0..3]) |v| {
                // composited over white, rounded
                const over = (@as(u32, v) * a + 255 * (255 - a) + 127) / 255;
                if (over <= 0x80) light = false;
            }
            b.* = light;
        }
        return .{ .width = w, .height = h, .bits = bits };
    }

    pub fn deinit(self: *Mask, gpa: std.mem.Allocator) void {
        gpa.free(self.bits);
    }

    /// Queries the mask at relative coordinates (0..1, 0..1).
    pub fn query(self: *const Mask, x: f64, y: f64) bool {
        if (self.width == 0 or self.height == 0) return true;
        const cx = std.math.clamp(x, 0.0, 1.0);
        const cy = std.math.clamp(y, 0.0, 1.0);
        const mx: usize = @min(@as(usize, @intFromFloat(cx * @as(f64, @floatFromInt(self.width)))), self.width - 1);
        const my: usize = @min(@as(usize, @intFromFloat(cy * @as(f64, @floatFromInt(self.height)))), self.height - 1);
        return self.bits[my * self.width + mx];
    }
};

test "query clamps" {
    var bits = [_]bool{ true, false, false, true };
    const m = Mask{ .width = 2, .height = 2, .bits = &bits };
    try std.testing.expect(m.query(0, 0));
    try std.testing.expect(!m.query(1, 0));
    try std.testing.expect(m.query(1, 1));
    try std.testing.expect(m.query(2, 5));
}
