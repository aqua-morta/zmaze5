//! Native PNG encoding and decoding (no cairo or libpng needed).
//!
//! The encoder writes 8 bit RGBA images with an adaptive filter per row
//! (the filter with the smallest sum of absolute values, as recommended by
//! the PNG specification) and zlib compression.
//!
//! The decoder reads all standard PNG images: gray, gray + alpha, RGB, RGBA
//! and palette images with all bit depths (1, 2, 4, 8, 16), transparency
//! (tRNS) and Adam7 interlacing. It returns 8 bit RGBA pixels (16 bit
//! samples are reduced to their high byte).

const std = @import("std");

const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const Crc32 = std.hash.Crc32;

const SIGNATURE = "\x89PNG\r\n\x1a\n";

pub const Image = struct {
    width: usize,
    height: usize,
    /// RGBA, 4 bytes per pixel, row major
    pixels: []u8,

    pub fn deinit(img: *Image, gpa: Allocator) void {
        gpa.free(img.pixels);
    }
};

// ---------------------------------------------------------------------------
// encoding

fn writeChunk(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc = Crc32.init();
    crc.update(kind);
    crc.update(data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc.final(), .big);
    try out.appendSlice(gpa, &c);
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Applies filter `f` to the row `cur` (previous row `prev`, `bpp` bytes
/// per pixel) into `dst`.
fn filterRow(f: u8, bpp: usize, cur: []const u8, prev: []const u8, dst: []u8) void {
    for (cur, 0..) |x, i| {
        const a: u8 = if (i >= bpp) cur[i - bpp] else 0;
        const b = prev[i];
        const c: u8 = if (i >= bpp) prev[i - bpp] else 0;
        dst[i] = switch (f) {
            0 => x,
            1 => x -% a,
            2 => x -% b,
            3 => x -% @as(u8, @intCast((@as(u16, a) + b) / 2)),
            else => x -% paeth(a, b, c),
        };
    }
}

/// Encodes an RGBA image (non-premultiplied, 4 bytes per pixel) as PNG; a
/// fully opaque image is stored as RGB.
pub fn encode(gpa: Allocator, width: usize, height: usize, rgba: []const u8) ![]u8 {
    std.debug.assert(rgba.len == width * height * 4);
    const opaque_ = for (0..width * height) |i| {
        if (rgba[i * 4 + 3] != 255) break false;
    } else true;
    const bpp: usize = if (opaque_) 3 else 4;
    const stride = width * bpp;
    // RGB rows (opaque images): the current and the previous one
    const rows = try gpa.alloc(u8, if (opaque_) 2 * stride else 0);
    defer gpa.free(rows);
    // the filtered rows go straight into the compressor
    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, @max(64, rgba.len / 16));
    defer aw.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var comp = flate.Compress.init(&aw.writer, window, .zlib, .default) catch return error.OutOfMemory;
    const zero = try gpa.alloc(u8, stride);
    defer gpa.free(zero);
    @memset(zero, 0);
    const trial = try gpa.alloc(u8, stride);
    defer gpa.free(trial);
    const best = try gpa.alloc(u8, stride);
    defer gpa.free(best);
    for (0..height) |y| {
        var cur: []const u8 = undefined;
        var prev: []const u8 = undefined;
        if (opaque_) {
            const c = rows[(y % 2) * stride ..][0..stride];
            for (0..width) |x| @memcpy(c[x * 3 ..][0..3], rgba[(y * width + x) * 4 ..][0..3]);
            cur = c;
            prev = if (y > 0) rows[((y + 1) % 2) * stride ..][0..stride] else zero;
        } else {
            cur = rgba[y * stride ..][0..stride];
            prev = if (y > 0) rgba[(y - 1) * stride ..][0..stride] else zero;
        }
        var best_sum: u64 = std.math.maxInt(u64);
        var best_f: u8 = 0;
        for (0..5) |f| {
            filterRow(@intCast(f), bpp, cur, prev, trial);
            var sum: u64 = 0;
            for (trial) |v| sum += @abs(@as(i8, @bitCast(v)));
            if (sum < best_sum) {
                best_sum = sum;
                best_f = @intCast(f);
                @memcpy(best, trial);
            }
        }
        comp.writer.writeByte(best_f) catch return error.OutOfMemory;
        comp.writer.writeAll(best) catch return error.OutOfMemory;
    }
    comp.finish() catch return error.OutOfMemory;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, SIGNATURE);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = if (opaque_) 2 else 6; // RGB or RGBA
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    try writeChunk(gpa, &out, "IHDR", &ihdr);
    try writeChunk(gpa, &out, "IDAT", aw.written());
    try writeChunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// decoding

pub const DecodeError = error{ NotPng, Corrupt, Unsupported, OutOfMemory };

const Header = struct {
    width: usize,
    height: usize,
    depth: u8,
    color: u8,
    interlace: bool,

    /// samples per pixel
    fn channels(h: Header) usize {
        return switch (h.color) {
            0, 3 => 1,
            4 => 2,
            2 => 3,
            6 => 4,
            else => unreachable,
        };
    }

    fn bitsPerPixel(h: Header) usize {
        return h.channels() * h.depth;
    }

    /// bytes per row of a (sub) image of the given width, without the
    /// filter byte
    fn rowBytes(h: Header, w: usize) usize {
        return (w * h.bitsPerPixel() + 7) / 8;
    }
};

const Palette = struct {
    rgba: [256][4]u8 = @splat(.{ 0, 0, 0, 255 }),
    /// tRNS of gray / RGB images: the transparent color (in sample units)
    key: ?[3]u16 = null,
};

/// Decodes a PNG file into 8 bit RGBA pixels.
pub fn decode(gpa: Allocator, data: []const u8) DecodeError!Image {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], SIGNATURE)) return error.NotPng;
    var pos: usize = 8;
    var header: ?Header = null;
    var pal: Palette = .{};
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(gpa);
    while (true) {
        if (pos + 12 > data.len) return error.Corrupt;
        const len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const kind = data[pos + 4 ..][0..4];
        if (pos + 12 + len > data.len) return error.Corrupt;
        const body = data[pos + 8 ..][0..len];
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13) return error.Corrupt;
            const h: Header = .{
                .width = std.mem.readInt(u32, body[0..4], .big),
                .height = std.mem.readInt(u32, body[4..8], .big),
                .depth = body[8],
                .color = body[9],
                .interlace = body[12] == 1,
            };
            const ok = switch (h.color) {
                0 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8 or h.depth == 16,
                3 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8,
                2, 4, 6 => h.depth == 8 or h.depth == 16,
                else => false,
            };
            if (!ok or body[10] != 0 or body[11] != 0 or body[12] > 1) return error.Unsupported;
            if (h.width == 0 or h.height == 0 or h.width > 1 << 24 or h.height > 1 << 24) return error.Corrupt;
            header = h;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (len % 3 != 0 or len > 768) return error.Corrupt;
            for (0..len / 3) |i| pal.rgba[i] = .{ body[3 * i], body[3 * i + 1], body[3 * i + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            const h = header orelse return error.Corrupt;
            switch (h.color) {
                3 => for (body[0..@min(len, 256)], 0..) |a, i| {
                    pal.rgba[i][3] = a;
                },
                0 => if (len >= 2) {
                    const g = std.mem.readInt(u16, body[0..2], .big);
                    pal.key = .{ g, g, g };
                },
                2 => if (len >= 6) {
                    pal.key = .{ std.mem.readInt(u16, body[0..2], .big), std.mem.readInt(u16, body[2..4], .big), std.mem.readInt(u16, body[4..6], .big) };
                },
                else => {},
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, body);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        } else if (kind[0] & 0x20 == 0) {
            // unknown critical chunk
            return error.Unsupported;
        }
    }
    const h = header orelse return error.Corrupt;

    // decompress
    var in: std.Io.Reader = .fixed(idat.items);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var dec: flate.Decompress = .init(&in, .zlib, window);
    const raw = dec.reader.allocRemaining(gpa, .unlimited) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    defer gpa.free(raw);

    const pixels = try gpa.alloc(u8, h.width * h.height * 4);
    errdefer gpa.free(pixels);
    var off: usize = 0;
    if (!h.interlace) {
        try decodePass(gpa, h, &pal, raw, &off, h.width, h.height, pixels, 0, 0, 1, 1);
    } else {
        // Adam7: start and step of the passes
        const passes = [7][4]usize{ .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 } };
        for (passes) |p| {
            if (p[0] >= h.width or p[1] >= h.height) continue;
            const pw = (h.width - p[0] + p[2] - 1) / p[2];
            const ph = (h.height - p[1] + p[3] - 1) / p[3];
            try decodePass(gpa, h, &pal, raw, &off, pw, ph, pixels, p[0], p[1], p[2], p[3]);
        }
    }
    return .{ .width = h.width, .height = h.height, .pixels = pixels };
}

/// Unfilters one (sub) image of w x h pixels starting at raw[off.*] and
/// stores its pixels at (x0 + x·dx, y0 + y·dy).
fn decodePass(gpa: Allocator, h: Header, pal: *const Palette, raw: []const u8, off: *usize, w: usize, ht: usize, pixels: []u8, x0: usize, y0: usize, dx: usize, dy: usize) DecodeError!void {
    const rb = h.rowBytes(w);
    const bpp = @max(1, h.bitsPerPixel() / 8); // filter distance in bytes
    const prev = try gpa.alloc(u8, rb);
    defer gpa.free(prev);
    @memset(prev, 0);
    const cur = try gpa.alloc(u8, rb);
    defer gpa.free(cur);
    for (0..ht) |y| {
        if (off.* + 1 + rb > raw.len) return error.Corrupt;
        const f = raw[off.*];
        const src = raw[off.* + 1 ..][0..rb];
        off.* += 1 + rb;
        for (0..rb) |i| {
            const a: u8 = if (i >= bpp) cur[i - bpp] else 0;
            const b = prev[i];
            const c: u8 = if (i >= bpp) prev[i - bpp] else 0;
            cur[i] = switch (f) {
                0 => src[i],
                1 => src[i] +% a,
                2 => src[i] +% b,
                3 => src[i] +% @as(u8, @intCast((@as(u16, a) + b) / 2)),
                4 => src[i] +% paeth(a, b, c),
                else => return error.Corrupt,
            };
        }
        for (0..w) |x| {
            const px = pixels[((y0 + y * dy) * h.width + x0 + x * dx) * 4 ..][0..4];
            px.* = pixelAt(h, pal, cur, x);
        }
        @memcpy(prev, cur);
    }
}

/// Sample `i` of a row with the header's bit depth (16 bit: full value).
fn sample(h: Header, row: []const u8, i: usize) u16 {
    return switch (h.depth) {
        8 => row[i],
        16 => std.mem.readInt(u16, row[2 * i ..][0..2], .big),
        else => blk: {
            const bit = i * h.depth;
            const shift: u3 = @intCast(8 - h.depth - bit % 8);
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(h.depth)) - 1);
            break :blk (row[bit / 8] >> shift) & mask;
        },
    };
}

/// A sample scaled to 8 bits.
fn to8(h: Header, v: u16) u8 {
    return switch (h.depth) {
        16 => @intCast(v >> 8),
        8 => @intCast(v),
        else => @intCast(v * 255 / ((@as(u16, 1) << @intCast(h.depth)) - 1)),
    };
}

fn pixelAt(h: Header, pal: *const Palette, row: []const u8, x: usize) [4]u8 {
    switch (h.color) {
        0 => {
            const g = sample(h, row, x);
            const a: u8 = if (pal.key) |k| (if (g == k[0]) 0 else 255) else 255;
            const v = to8(h, g);
            return .{ v, v, v, a };
        },
        3 => return pal.rgba[sample(h, row, x)],
        4 => {
            const v = to8(h, sample(h, row, 2 * x));
            return .{ v, v, v, to8(h, sample(h, row, 2 * x + 1)) };
        },
        2 => {
            const r = sample(h, row, 3 * x);
            const g = sample(h, row, 3 * x + 1);
            const b = sample(h, row, 3 * x + 2);
            const a: u8 = if (pal.key) |k| (if (r == k[0] and g == k[1] and b == k[2]) 0 else 255) else 255;
            return .{ to8(h, r), to8(h, g), to8(h, b), a };
        },
        6 => return .{ to8(h, sample(h, row, 4 * x)), to8(h, sample(h, row, 4 * x + 1)), to8(h, sample(h, row, 4 * x + 2)), to8(h, sample(h, row, 4 * x + 3)) },
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------

test "png round trip" {
    const gpa = std.testing.allocator;
    const w = 37;
    const h = 23;
    var rgba: [w * h * 4]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const p = rgba[(y * w + x) * 4 ..][0..4];
        p.* = .{ @intCast(x * 7 % 256), @intCast(y * 11 % 256), @intCast((x * y) % 256), @intCast((x + y) * 5 % 256) };
    };
    const enc = try encode(gpa, w, h, &rgba);
    defer gpa.free(enc);
    var img = try decode(gpa, enc);
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(usize, w), img.width);
    try std.testing.expectEqualSlices(u8, &rgba, img.pixels);
    // opaque: stored as RGB
    for (0..w * h) |i| rgba[i * 4 + 3] = 255;
    const enc2 = try encode(gpa, w, h, &rgba);
    defer gpa.free(enc2);
    try std.testing.expectEqual(@as(u8, 2), enc2[8 + 8 + 9]);
    var img2 = try decode(gpa, enc2);
    defer img2.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &rgba, img2.pixels);
}

test "png decodes sub-byte gray samples" {
    const gpa = std.testing.allocator;
    // a 2 bit gray image by hand: 3x2 pixels
    const h: Header = .{ .width = 3, .height = 2, .depth = 2, .color = 0, .interlace = false };
    // row 0: values 0,1,2 -> bits 00 01 10 xx = 0b00011000; row 1: 3,3,3
    const raw = [_]u8{ 0, 0b00011000, 0, 0b11111100 };
    var pixels: [3 * 2 * 4]u8 = undefined;
    var off: usize = 0;
    const pal: Palette = .{};
    try decodePass(gpa, h, &pal, &raw, &off, 3, 2, &pixels, 0, 0, 1, 1);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 85, 85, 85, 255, 170, 170, 170, 255 }, pixels[0..12]);
    try std.testing.expectEqual(@as(u8, 255), pixels[12]);
}
