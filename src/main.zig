//! maze5 - maze generator (Zig rewrite of maze5 0.9.0 by Bernd Breitenbach)
//!
//! The command line program: files, stdout, `--load`/`--save`, `--stats`.
//! Everything else (option parsing, maze construction, rendering) lives in
//! `app.zig`, which the WebAssembly module (`wasm.zig`) shares.

const std = @import("std");
const Io = std.Io;

const app = @import("app.zig");
const help = @import("help.zig");
const output = @import("output.zig");
const Parameters = @import("params.zig").Parameters;
const Mask = @import("mask.zig").Mask;

pub const version = app.version;

const OPTFILE = ".maze5.last";

extern "c" fn time(t: ?*i64) i64;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const prog = std.fs.path.basename(argv[0]);
    const args = try arena.alloc([]const u8, argv.len - 1);
    for (args, argv[1..]) |*a, v| a.* = v;

    var parsed: std.ArrayListUnmanaged(app.Parsed) = .empty;
    var rest: std.ArrayListUnmanaged([]const u8) = .empty;
    app.parseArgs(arena, args, &parsed, &rest) catch |e| switch (e) {
        error.InvalidOption => {
            std.log.err("try '{s} --help' for more information", .{prog});
            std.process.exit(1);
        },
        else => return e,
    };

    var doexit = false;

    // parameters loaded from a file (--load) serve as defaults for the
    // parameters given on the command line
    var loaded = Parameters.init(gpa);
    defer loaded.deinit();
    var paras = Parameters.init(gpa);
    defer paras.deinit();

    const home_optfile: ?[]const u8 = if (init.environ_map.get("HOME")) |home|
        try std.fs.path.join(arena, &.{ home, OPTFILE })
    else
        null;
    var save_file: ?[]const u8 = home_optfile;
    var sample = false;

    for (parsed.items) |p| {
        if (std.mem.eql(u8, p.opt.long, "load")) {
            const file = p.value orelse home_optfile orelse OPTFILE;
            loaded.load(io, file) catch |e| {
                std.log.err("could not load option file '{s}': {t}", .{ file, e });
                doexit = true;
            };
        } else if (std.mem.eql(u8, p.opt.long, "save")) {
            save_file = p.value.?;
        } else if (std.mem.eql(u8, p.opt.long, "sample")) {
            sample = true;
        }
    }
    if (!try app.collect(parsed.items, &paras)) doexit = true;
    // merge: command line wins over loaded values
    for (loaded.names.items, loaded.values.items) |n, v| _ = try paras.set(n, v);

    if (paras.get("version") != null) {
        var w = Io.File.stdout().writerStreaming(io, &.{});
        try w.interface.print("{s} {s}\n" ++ help.copyright, .{ prog, version });
        return;
    }
    if (paras.get("help") != null) {
        var w = Io.File.stdout().writerStreaming(io, &.{});
        try w.interface.print(help.text, .{prog});
        return;
    }

    var mask: ?Mask = null;
    defer if (mask) |*mk| mk.deinit(gpa);
    if (paras.get("mask")) |arg| {
        if (Mask.load(gpa, io, arg)) |mk| {
            mask = mk;
        } else |_| {
            std.log.err("cannot load mask file '{s}'", .{arg});
            doexit = true;
        }
    }

    var cfg = app.configure(arena, &paras, .{
        .mask = if (mask) |*mk| mk else null,
        .default_seed = @bitCast(@as(i32, @truncate(time(null)))),
        .sample = sample,
        .rest = rest.items,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.process.exit(1),
    };
    if (doexit) std.process.exit(1);
    if (paras.get("output")) |arg| {
        if (!std.mem.eql(u8, arg, "-")) cfg.rp.filename = try arena.dupeSentinel(u8, arg, 0);
    }

    var timer = Lap.start(io);
    const maze = app.construct(gpa, &cfg) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.process.exit(1),
    };
    defer maze.deinit();
    if (cfg.stats) std.debug.print("constructing time   :{d:.5}\n", .{timer.lap()});

    app.carveMaze(gpa, &cfg, maze) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.process.exit(1),
    };
    if (cfg.stats and !cfg.params.dummy) std.debug.print("carving time        :{d:.5}\n", .{timer.lap()});

    const doc = app.draw(gpa, &cfg, maze) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.process.exit(1),
    };
    defer gpa.free(doc);
    output.write(io, doc, cfg.rp.filename) catch std.process.exit(1);
    if (cfg.stats) {
        std.debug.print("rendering time      :{d:.5}\n", .{timer.lap()});
        std.debug.print("total time used     :{d:.5}\n", .{timer.total()});
    }

    if (save_file) |f| {
        paras.save(io, f) catch |e| std.log.err("could not write option file '{s}': {t}", .{ f, e });
    }
}

/// Simple stop watch for `--stats` (CPU time of the process).
const Lap = struct {
    io: Io,
    first: Io.Timestamp,
    last: Io.Timestamp,

    fn start(io: Io) Lap {
        const now = Io.Timestamp.now(io, .cpu_process);
        return .{ .io = io, .first = now, .last = now };
    }

    fn secs(d: Io.Duration) f64 {
        return @as(f64, @floatFromInt(d.nanoseconds)) / std.time.ns_per_s;
    }

    /// Seconds since the last lap.
    fn lap(self: *Lap) f64 {
        const now = Io.Timestamp.now(self.io, .cpu_process);
        defer self.last = now;
        return secs(self.last.durationTo(now));
    }

    fn total(self: *Lap) f64 {
        return secs(self.first.durationTo(self.last));
    }
};

test {
    _ = @import("app.zig");
    _ = @import("geo.zig");
    _ = @import("rng.zig");
    _ = @import("structure.zig");
    _ = @import("params.zig");
    _ = @import("mask.zig");
    _ = @import("vector.zig");
    _ = @import("raster.zig");
    _ = @import("png.zig");
    _ = @import("voronoi.zig");
    _ = @import("penrose.zig");
    _ = @import("hat.zig");
    _ = @import("ammann.zig");
    _ = @import("stepped.zig");
    _ = @import("shield.zig");
    _ = @import("socolar.zig");
    _ = @import("clamshell.zig");
    _ = @import("multigrid.zig");
    _ = @import("rotational.zig");
    _ = @import("recursive.zig");
    _ = @import("tests.zig");
    _ = @import("pillars.zig");
}
