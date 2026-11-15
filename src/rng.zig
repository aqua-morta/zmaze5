//! A re-implementation of glibc's `srandom()`/`random()` (TYPE_3 additive
//! feedback generator).
//!
//! Using exactly the same generator as the original C program means that a
//! given `--seed` produces the very same maze as maze5 0.9.0 did.

const std = @import("std");

pub const RAND_MAX: i32 = 2147483647;

const DEG = 31;
const SEP = 3;

pub const Random = struct {
    state: [DEG]i32 = undefined,
    f: usize = SEP,
    r: usize = 0,

    pub fn init(s: u32) Random {
        var self: Random = .{};
        self.seed(s);
        return self;
    }

    pub fn seed(self: *Random, s: u32) void {
        const sd: u32 = if (s == 0) 1 else s;
        self.state[0] = @bitCast(sd);
        var word: i32 = @bitCast(sd);
        var i: usize = 1;
        while (i < DEG) : (i += 1) {
            // state[i] = (16807 * state[i - 1]) % 2147483647 without overflow
            const hi: i64 = @divTrunc(@as(i64, word), 127773);
            const lo: i64 = @rem(@as(i64, word), 127773);
            var w: i64 = 16807 * lo - 2836 * hi;
            if (w < 0) w += 2147483647;
            word = @truncate(w);
            self.state[i] = word;
        }
        self.f = SEP;
        self.r = 0;
        var k: usize = 0;
        while (k < DEG * 10) : (k += 1) {
            _ = self.next();
        }
    }

    /// Returns a pseudo random number in the range [0, RAND_MAX].
    pub fn next(self: *Random) i32 {
        const val: u32 = @as(u32, @bitCast(self.state[self.f])) +% @as(u32, @bitCast(self.state[self.r]));
        self.state[self.f] = @bitCast(val);
        self.f += 1;
        if (self.f >= DEG) {
            self.f = 0;
            self.r += 1;
        } else {
            self.r += 1;
            if (self.r >= DEG) self.r = 0;
        }
        return @intCast(val >> 1);
    }

    /// `random() % n` for positive `n`.
    pub inline fn below(self: *Random, n: usize) usize {
        return @as(usize, @intCast(self.next())) % n;
    }

    /// `random() / (double)RAND_MAX`
    pub inline fn unit(self: *Random) f64 {
        return @as(f64, @floatFromInt(self.next())) / @as(f64, @floatFromInt(RAND_MAX));
    }
};

test "matches glibc random()" {
    // Reference values produced by glibc: srandom(1); random() ...
    var r = Random.init(1);
    const expected = [_]i32{ 1804289383, 846930886, 1681692777, 1714636915, 1957747793 };
    for (expected) |e| try std.testing.expectEqual(e, r.next());
}
