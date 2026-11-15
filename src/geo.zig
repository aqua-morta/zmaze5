//! 2D geometry helpers.
//!
//! Trigonometric functions are Zig's own implementations (builtins and
//! `std.math`). Note that results may differ in the last bit from glibc's
//! libm, so a given seed does not necessarily reproduce the exact maze of
//! the original C maze5 for maze types with geometric ties (theta, discs).

const std = @import("std");

pub inline fn tan(x: f64) f64 {
    return @tan(x);
}

pub inline fn atan2(y: f64, x: f64) f64 {
    return std.math.atan2(y, x);
}

pub const SinCos = struct { sin: f64, cos: f64 };

/// Sine and cosine of `x`.
pub inline fn sincos(x: f64) SinCos {
    return .{ .sin = @sin(x), .cos = @cos(x) };
}

pub const EPSILON: f64 = 1e-5;
pub const pi: f64 = std.math.pi;

/// Equality within `EPSILON` (the original `DEQUAL`).
pub inline fn dequal(a: f64, b: f64) bool {
    return @abs(a - b) < EPSILON;
}

pub inline fn weightedMean(a: f64, b: f64, w: f64) f64 {
    return a * w + b * (1 - w);
}

pub const Vec2 = struct {
    x: f64 = 0,
    y: f64 = 0,

    pub inline fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub inline fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub inline fn scale(a: Vec2, f: f64) Vec2 {
        return .{ .x = a.x * f, .y = a.y * f };
    }

    pub inline fn len2(a: Vec2) f64 {
        return a.x * a.x + a.y * a.y;
    }

    pub inline fn len(a: Vec2) f64 {
        return @sqrt(a.x * a.x + a.y * a.y);
    }

    pub inline fn norm(a: Vec2) Vec2 {
        const l = a.len();
        return .{ .x = a.x / l, .y = a.y / l };
    }

    /// Rotates the vector by `arc` radians (counter clockwise).
    pub inline fn rot(a: Vec2, arc: f64) Vec2 {
        const sc = sincos(arc);
        return .{ .x = a.x * sc.cos - a.y * sc.sin, .y = a.x * sc.sin + a.y * sc.cos };
    }

    pub inline fn mean(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = 0.5 * (a.x + b.x), .y = 0.5 * (a.y + b.y) };
    }

    pub inline fn weightedMean2(a: Vec2, b: Vec2, w: f64) Vec2 {
        return .{ .x = weightedMean(a.x, b.x, w), .y = weightedMean(a.y, b.y, w) };
    }

    /// Unit vector pointing from `from` to `to`.
    pub inline fn unit(from: Vec2, to: Vec2) Vec2 {
        return to.sub(from).norm();
    }

    pub inline fn colinear(a: Vec2, b: Vec2) bool {
        return @abs(a.x * b.y - a.y * b.x) < EPSILON;
    }

    pub inline fn equal(a: Vec2, b: Vec2) bool {
        return dequal(a.x, b.x) and dequal(a.y, b.y);
    }
};

test "vector basics" {
    const a = Vec2{ .x = 3, .y = 4 };
    try std.testing.expectEqual(@as(f64, 5), a.len());
    const r = (Vec2{ .x = 1, .y = 0 }).rot(pi / 2.0);
    try std.testing.expect(r.equal(.{ .x = 0, .y = 1 }));
    try std.testing.expect(a.colinear(a.scale(-2)));
}
