//! The maze5 program without its I/O: command line parsing, conversion of
//! the parameters into maze and render parameters, construction, carving and
//! rendering into memory. Shared by the command line program (`main.zig`)
//! and the WebAssembly module (`wasm.zig`); errors are reported with
//! `std.log` and returned as `error.InvalidArguments` / `error.Failed`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const mz = @import("maze.zig");
const structure = @import("structure.zig");
const rng = @import("rng.zig");
const carve = @import("carve.zig");
const render = @import("render.zig");
const output = @import("output.zig");
const pillars = @import("pillars.zig");
const recursive = @import("recursive.zig");
const Parameters = @import("params.zig").Parameters;
const Mask = @import("mask.zig").Mask;

pub const version = "1.0.0-zig";

/// Set by tests that provoke error messages.
pub var silence_logs = false;

/// Messages go to `std.log`. The test runner counts every logged error as a
/// failure, so in tests they are printed directly (unless silenced).
const log = if (builtin.is_test) struct {
    pub fn err(comptime format: []const u8, args: anytype) void {
        if (!silence_logs) std.debug.print("error: " ++ format ++ "\n", args);
    }
    pub fn warn(comptime format: []const u8, args: anytype) void {
        if (!silence_logs) std.debug.print("warning: " ++ format ++ "\n", args);
    }
    pub fn info(comptime format: []const u8, args: anytype) void {
        if (!silence_logs) std.debug.print("info: " ++ format ++ "\n", args);
    }
} else std.log;

const MAX_NO_SAMPLE_ROWS = 12;
const MAX_NO_SAMPLE_COLUMNS = 12;
const MAX_SAMPLE_CELLSIZE = 32;
const MIN_MAX_CELLS = 144;

pub const ArgKind = enum { none, required, optional };

pub const Opt = struct {
    long: []const u8,
    short: ?u8 = null,
    arg: ArgKind = .none,
    /// name of the parameter stored; flags store "1"; null for options the
    /// host handles itself (`--load`, `--save`, `--sample`)
    param: ?[]const u8 = null,
};

/// The options; the parameter names are also the keys of the JSON file.
pub const options = [_]Opt{
    .{ .long = "load", .arg = .optional },
    .{ .long = "save", .arg = .required },
    .{ .long = "type", .short = 't', .arg = .required, .param = "type" },
    .{ .long = "format", .short = 'f', .arg = .required, .param = "format" },
    .{ .long = "entrance", .short = 'e', .arg = .required, .param = "entrance" },
    .{ .long = "exit", .short = 'x', .arg = .required, .param = "exit" },
    .{ .long = "tileable", .short = 'T', .param = "tileable" },
    .{ .long = "columns", .short = 'c', .arg = .required, .param = "columns" },
    .{ .long = "rows", .short = 'r', .arg = .required, .param = "rows" },
    .{ .long = "output", .short = 'o', .arg = .required, .param = "output" },
    .{ .long = "seed", .short = 'S', .arg = .required, .param = "seed" },
    .{ .long = "cellsize", .short = 'C', .arg = .required, .param = "cellsize" },
    .{ .long = "bordersize", .short = 'b', .arg = .required, .param = "bordersize" },
    .{ .long = "background", .short = 'B', .arg = .required, .param = "background" },
    .{ .long = "foreground", .short = 'F', .arg = .required, .param = "foreground" },
    .{ .long = "pillar-color", .arg = .required, .param = "pillar-color" },
    .{ .long = "numbers", .param = "numbers" },
    .{ .long = "nomarks", .param = "nomarks" },
    .{ .long = "solution", .short = 'P', .param = "solution" },
    .{ .long = "linewidth", .short = 'l', .arg = .required, .param = "linewidth" },
    .{ .long = "bridgewidth", .arg = .required, .param = "bridgewidth" },
    .{ .long = "algorithm", .short = 'a', .arg = .required, .param = "algorithm" },
    .{ .long = "arcs", .arg = .required, .param = "arcs" },
    .{ .long = "boundary", .arg = .required, .param = "boundary" },
    .{ .long = "mask", .short = 'm', .arg = .required, .param = "mask" },
    .{ .long = "fuzzy", .param = "fuzzy" },
    .{ .long = "organic", .short = 'O', .param = "organic" },
    .{ .long = "no-fuzzy", .arg = .required, .param = "no-fuzzy" },
    .{ .long = "amplitude", .arg = .required, .param = "amplitude" },
    .{ .long = "jitter", .short = 'j', .arg = .required, .param = "jitter" },
    .{ .long = "crossings", .arg = .required, .param = "crossings" },
    .{ .long = "weights", .short = 'W', .arg = .required, .param = "weights" },
    .{ .long = "pillars", .short = 'X', .arg = .required, .param = "pillars" },
    .{ .long = "cave", .arg = .required, .param = "cave" },
    .{ .long = "max-openings", .arg = .required, .param = "max-openings" },
    .{ .long = "recursion", .arg = .required, .param = "recursion" },
    .{ .long = "recursion-opening", .arg = .required, .param = "recursion-opening" },
    .{ .long = "recursion-orientation", .arg = .required, .param = "recursion-orientation" },
    .{ .long = "wall-length", .short = 'w', .arg = .required, .param = "wall-length" },
    .{ .long = "rough-border", .param = "rough-border" },
    .{ .long = "rotate", .short = 'R', .arg = .required, .param = "rotate" },
    .{ .long = "text", .arg = .required, .param = "text" },
    .{ .long = "stats", .param = "stats" },
    .{ .long = "version", .short = 'v', .param = "version" },
    .{ .long = "dummy", .short = 'd', .param = "dummy" },
    .{ .long = "debug", .short = 'D', .arg = .optional, .param = "debug" },
    .{ .long = "copyright", .param = "copyright" },
    .{ .long = "sample" },
    .{ .long = "maxcells", .arg = .required, .param = "maxcells" },
    .{ .long = "help", .short = 'h', .param = "help" },
};

pub const Parsed = struct {
    opt: *const Opt,
    value: ?[]const u8,
};

pub const ParseError = error{ InvalidOption, OutOfMemory };

/// getopt_long like command line scanner: supports `-abc`, `-cVALUE`,
/// `-c VALUE`, `--name=VALUE`, `--name VALUE`, unambiguous prefixes of long
/// options and `--` to end option processing. `args` are the arguments
/// without the program name.
pub fn parseArgs(gpa: Allocator, args: []const []const u8, out: *std.ArrayListUnmanaged(Parsed), rest: *std.ArrayListUnmanaged([]const u8)) ParseError!void {
    var i: usize = 0;
    var ok = true;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            for (args[i + 1 ..]) |r| try rest.append(gpa, r);
            break;
        } else if (std.mem.startsWith(u8, a, "--")) {
            const body = a[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const opt = findLong(name) orelse {
                ok = false;
                continue;
            };
            var value: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;
            switch (opt.arg) {
                .none => if (value != null) {
                    log.err("option '--{s}' doesn't allow an argument", .{opt.long});
                    ok = false;
                    continue;
                },
                .required => if (value == null) {
                    if (i + 1 >= args.len) {
                        log.err("option '--{s}' requires an argument", .{opt.long});
                        ok = false;
                        continue;
                    }
                    i += 1;
                    value = args[i];
                },
                .optional => {},
            }
            try out.append(gpa, .{ .opt = opt, .value = value });
        } else if (a.len > 1 and a[0] == '-') {
            var k: usize = 1;
            while (k < a.len) : (k += 1) {
                const opt = findShort(a[k]) orelse {
                    log.err("invalid option -- '{c}'", .{a[k]});
                    ok = false;
                    continue;
                };
                switch (opt.arg) {
                    .none => try out.append(gpa, .{ .opt = opt, .value = null }),
                    .optional => {
                        const v: ?[]const u8 = if (k + 1 < a.len) a[k + 1 ..] else null;
                        try out.append(gpa, .{ .opt = opt, .value = v });
                        break;
                    },
                    .required => {
                        var v: []const u8 = undefined;
                        if (k + 1 < a.len) {
                            v = a[k + 1 ..];
                        } else if (i + 1 < args.len) {
                            i += 1;
                            v = args[i];
                        } else {
                            log.err("option requires an argument -- '{c}'", .{a[k]});
                            ok = false;
                            break;
                        }
                        try out.append(gpa, .{ .opt = opt, .value = v });
                        break;
                    },
                }
            }
        } else {
            try rest.append(gpa, a);
        }
    }
    if (!ok) return error.InvalidOption;
}

fn findShort(ch: u8) ?*const Opt {
    for (&options) |*o| {
        if (o.short == ch) return o;
    }
    return null;
}

fn findLong(name: []const u8) ?*const Opt {
    var match: ?*const Opt = null;
    var ambiguous = false;
    for (&options) |*o| {
        if (std.mem.eql(u8, o.long, name)) return o;
        if (std.mem.startsWith(u8, o.long, name)) {
            if (match != null) ambiguous = true;
            match = o;
        }
    }
    if (ambiguous) {
        log.err("option '--{s}' is ambiguous", .{name});
        return null;
    }
    if (match == null) log.err("unrecognized option '--{s}'", .{name});
    return match;
}

/// Stores the parsed options as named parameters (flags as "1"); options
/// without a parameter name (`--load`, `--save`, `--sample`) are left to
/// the caller. Returns false if an option was given twice.
pub fn collect(parsed: []const Parsed, paras: *Parameters) !bool {
    var ok = true;
    for (parsed) |p| {
        const name = p.opt.param orelse continue;
        const value = p.value orelse "1";
        if (!try paras.set(name, value)) {
            if (p.opt.short) |s| {
                log.err("option '--{s}/-{c}' was multiple given!", .{ p.opt.long, s });
            } else {
                log.err("option '--{s}' was multiple given!", .{p.opt.long});
            }
            ok = false;
        }
    }
    return ok;
}

// ---------------------------------------------------------------------------
// value conversion

/// Parses the longest numeric prefix of `s` (like strtod); returns the value
/// and the remaining suffix.
fn parseFloatPrefix(s: []const u8) ?struct { f64, []const u8 } {
    var end: usize = s.len;
    while (end > 0) : (end -= 1) {
        const v = std.fmt.parseFloat(f64, s[0..end]) catch continue;
        return .{ v, s[end..] };
    }
    return null;
}

fn toInt(s: []const u8) ?i32 {
    const v = std.fmt.parseInt(i32, s, 0) catch return null;
    return if (v < 0) null else v;
}

fn toDouble(s: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, s) catch null;
}

/// Length with an optional unit (px, pt, mm, cm, in); result in points.
fn toPoints(s: []const u8) ?f64 {
    const r = parseFloatPrefix(s) orelse return null;
    const v, const unit = r;
    if (unit.len == 0 or std.mem.eql(u8, unit, "px") or std.mem.eql(u8, unit, "pt")) return v;
    if (std.mem.eql(u8, unit, "mm")) return v / 0.35277138;
    if (std.mem.eql(u8, unit, "cm")) return v / 0.035277138;
    if (std.mem.eql(u8, unit, "in")) return v * 72;
    return null;
}

/// Colors: `R,G,B[,A]` (floats 0..1), `#RGB`, `#RRGGBB`,
/// `rgba(r,g,b[,a])` (0..255, alpha 0..1) or `transparent`.
fn toColor(s: []const u8) ?render.Color {
    if (s.len > 0 and s[0] == '#') {
        const div: i64 = if (s.len == 4) 16 else 256;
        var val = std.fmt.parseInt(i64, s[1..], 16) catch return null;
        const fdiv: f64 = @floatFromInt(div - 1);
        const b: f64 = @floatFromInt(@mod(val, div));
        val = @divTrunc(val, div);
        const g: f64 = @floatFromInt(@mod(val, div));
        val = @divTrunc(val, div);
        const r: f64 = @floatFromInt(@mod(val, div));
        return .{ .red = r / fdiv, .green = g / fdiv, .blue = b / fdiv, .alpha = 1 };
    }
    if (std.mem.eql(u8, s, "transparent")) return .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };
    if (std.mem.startsWith(u8, s, "rgba(")) {
        var body = s[5..];
        if (std.mem.endsWith(u8, body, ")")) body = body[0 .. body.len - 1];
        var it = std.mem.splitScalar(u8, body, ',');
        var comps: [3]f64 = undefined;
        for (&comps) |*cp| {
            const part = std.mem.trim(u8, it.next() orelse return null, " ");
            const v = std.fmt.parseInt(i64, part, 0) catch return null;
            cp.* = @as(f64, @floatFromInt(v)) / 255.0;
        }
        var alpha: f64 = 1;
        if (it.next()) |a| alpha = toDouble(std.mem.trim(u8, a, " ")) orelse return null;
        if (it.next() != null) return null;
        return .{ .red = comps[0], .green = comps[1], .blue = comps[2], .alpha = alpha };
    }
    var it = std.mem.splitScalar(u8, s, ',');
    var comps: [3]f64 = undefined;
    for (&comps) |*cp| cp.* = toDouble(it.next() orelse return null) orelse return null;
    var alpha: f64 = 1;
    if (it.next()) |a| alpha = toDouble(a) orelse return null;
    if (it.next() != null) return null;
    return .{ .red = comps[0], .green = comps[1], .blue = comps[2], .alpha = alpha };
}

fn toDirection(s: []const u8) ?mz.Direction {
    const names = [_]struct { []const u8, mz.Direction }{
        .{ "north", .north }, .{ "west", .west }, .{ "south", .south }, .{ "east", .east },
    };
    for (names) |n| {
        if (std.mem.eql(u8, s, n[0])) return n[1];
    }
    return null;
}

/// The output format for a file name (by its extension).
pub fn formatFromExtension(name: []const u8) ?render.Format {
    if (name.len < 4) return null;
    const ext = name[name.len - 4 ..];
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return .png;
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return .svg;
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return .pdf;
    return null;
}

/// Writes cell type letters like "B,C".
fn typeLetters(buf: []u8, types: u32) []const u8 {
    var n: usize = 0;
    for (0..26) |t| {
        if (types & (@as(u32, 1) << @intCast(t)) == 0) continue;
        if (n > 0 and n < buf.len) {
            buf[n] = ',';
            n += 1;
        }
        if (n < buf.len) {
            buf[n] = 'A' + @as(u8, @intCast(t));
            n += 1;
        }
    }
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// configuration

pub const Error = error{
    /// the parameters are invalid (the errors were logged)
    InvalidArguments,
    /// no maze could be built or rendered (the reason was logged)
    Failed,
    OutOfMemory,
};

/// Everything needed to build and draw the maze.
pub const Config = struct {
    params: mz.Params = .{},
    rp: render.RenderParams = .{},
    limits: [mz.MAX_TYPES]u8 = @splat(mz.NO_LIMIT),
    max_cells: i64 = std.math.maxInt(i32),
    stats: bool = false,
};

pub const ConfigureOptions = struct {
    /// the mask image, already loaded by the host (`--mask` names a file
    /// for the command line program, in the browser the image is uploaded)
    mask: ?*const Mask = null,
    /// seed used when none was given (the current time)
    default_seed: u32,
    /// `--sample`: a small PNG preview
    sample: bool = false,
    /// the command line program needs an output file (`-o`)
    require_output: bool = true,
    /// positional arguments (none are allowed)
    rest: []const []const u8 = &.{},
};

/// Parses the position of the openings of recursive mazes on a side of `n`
/// cells: 'middle', 'random', 'first', 'last' or a cell number 1..n.
fn toRecursionOpening(arg: []const u8, n: i32) ?mz.RecursionOpening {
    if (std.mem.eql(u8, arg, "middle")) return .middle;
    if (std.mem.eql(u8, arg, "random")) return .random;
    if (std.mem.eql(u8, arg, "first")) return .{ .at = 0 };
    if (std.mem.eql(u8, arg, "last")) return .{ .at = @intCast(n - 1) };
    const v = toInt(arg) orelse return null;
    if (v < 1 or v > n) return null;
    return .{ .at = @intCast(v - 1) };
}

/// Turns the named parameters into maze and render parameters. The seed is
/// added to `paras` if it was not given. Strings in the config point into
/// `paras` and `arena`.
pub fn configure(arena: Allocator, paras: *Parameters, opts: ConfigureOptions) Error!Config {
    var cfg: Config = .{};
    const params = &cfg.params;
    const rp = &cfg.rp;
    var doexit = false;

    if (paras.get("type")) |arg| {
        params.structure = structure.lookup(arg) catch |e| blk: {
            switch (e) {
                error.UnknownType => log.err("invalid maze type '{s}'", .{arg}),
                error.InvalidVariant => log.err("illegal variant in maze type '{s}'", .{arg}),
            }
            doexit = true;
            break :blk structure.default;
        };
    }
    const st = params.structure;

    if (paras.get("output")) |arg| {
        if (!std.mem.eql(u8, arg, "-")) rp.format = formatFromExtension(arg);
    }
    if (paras.get("format")) |arg| {
        if (std.mem.eql(u8, arg, "png")) {
            rp.format = .png;
        } else if (std.mem.eql(u8, arg, "svg")) {
            rp.format = .svg;
        } else if (std.mem.eql(u8, arg, "pdf")) {
            rp.format = .pdf;
        } else {
            log.err("unknown output format '{s}'", .{arg});
            doexit = true;
        }
    }
    if (paras.get("numbers") != null) rp.drawno = true;
    if (paras.get("nomarks") != null) rp.draw_marks = false;
    if (paras.get("dummy") != null) {
        params.dummy = true;
        rp.draw_solution = false;
        rp.draw_marks = false;
    }
    if (paras.get("debug")) |arg| {
        params.debug = 1;
        if (toInt(arg)) |d| params.debug = d;
        rp.drawno = true;
    }
    if (paras.get("rotate")) |arg| {
        if (toDouble(arg)) |r| {
            rp.rotation = r * std.math.pi / 180.0;
        } else {
            log.err("invalid parameter for --rotate/-R '{s}'", .{arg});
            doexit = true;
        }
    }
    {
        var seed: ?i32 = null;
        if (paras.get("seed")) |arg| {
            seed = toInt(arg);
            if (seed == null) log.warn("invalid seed '{s}'; using a time based seed", .{arg});
        }
        params.seed = if (seed) |s| @bitCast(s) else opts.default_seed;
        if (paras.get("seed") == null) {
            var buf: [16]u8 = undefined;
            _ = try paras.set("seed", std.fmt.bufPrint(&buf, "{d}", .{params.seed}) catch unreachable);
        }
    }
    if (paras.get("stats") != null) cfg.stats = true;
    if (paras.get("cellsize")) |arg| {
        if (toPoints(arg)) |v| {
            rp.xcellsize = v;
            rp.ycellsize = v;
        } else {
            log.err("invalid cellsize parameter '{s}'", .{arg});
            doexit = true;
        }
    }
    if (paras.get("bordersize")) |arg| {
        if (toPoints(arg)) |v| rp.bordersize = v else {
            log.err("invalid bordersize parameter '{s}'", .{arg});
            doexit = true;
        }
    }
    if (paras.get("background")) |arg| {
        if (toColor(arg)) |col| rp.background = col else {
            log.err("invalid color '{s}'", .{arg});
            doexit = true;
        }
    }
    if (paras.get("foreground")) |arg| {
        if (toColor(arg)) |col| rp.foreground = col else {
            log.err("invalid color '{s}'", .{arg});
            doexit = true;
        }
    }
    if (paras.get("pillar-color")) |arg| {
        if (toColor(arg)) |col| rp.pillar = col else {
            log.err("invalid color '{s}'", .{arg});
            doexit = true;
        }
    }
    if (paras.get("linewidth")) |arg| {
        if (toPoints(arg)) |v| rp.linewidth = v else {
            log.err("invalid linewidth parameter '{s}'", .{arg});
            doexit = true;
        }
    }
    if (paras.get("fuzzy") != null) rp.fuzzy = true;
    if (paras.get("organic") != null) rp.organic = true;
    if (paras.get("bridgewidth")) |arg| {
        if (toDouble(arg)) |v| {
            if (v < 0.2 or v > 0.8) {
                log.err("parameter {d} for --bridgewidth out of bounds [0.2,0.8]", .{v});
                doexit = true;
            }
            rp.bridgewidth = (1 - v) / 2.0;
        } else {
            log.err("invalid bridge width '{s}'", .{arg});
            doexit = true;
        }
    }
    if (paras.get("amplitude")) |arg| {
        if (toDouble(arg)) |v| rp.amplitude = v else {
            log.err("invalid amplitude parameter '{s}'", .{arg});
            doexit = true;
        }
        rp.fuzzy = true;
    }
    if (paras.get("no-fuzzy")) |arg| {
        if (toInt(arg)) |v| rp.n_fuzzy = @intCast(v) else {
            log.err("invalid fuzzy parameter '{s}'", .{arg});
            doexit = true;
        }
        rp.fuzzy = true;
    }
    if (paras.get("copyright") != null) rp.copyright_text = "Maze 5 (c) B. Breitenbach";
    if (paras.get("text")) |arg| rp.solution_text = arg;
    if (paras.get("algorithm")) |arg| {
        if (!params.dummy) {
            const algos = [_]struct { []const u8, mz.Algorithm }{
                .{ "backtracker", .backtracker }, .{ "prim", .prim }, .{ "tree", .tree }, .{ "wilson", .wilson },
            };
            var found = false;
            for (algos) |al| {
                if (std.mem.startsWith(u8, arg, al[0])) {
                    params.algorithm = al[1];
                    if (std.mem.lastIndexOfScalar(u8, arg, ':')) |sep| {
                        params.treefactor = if (parseFloatPrefix(arg[sep + 1 ..])) |r| r[0] else 0;
                    }
                    found = true;
                    break;
                }
            }
            if (!found) {
                log.err("unknown algorithm '{s}'", .{arg});
                doexit = true;
            }
        } else {
            log.warn("In dummy mode ('--dummy/-d') carving algorithm '{s}' will be ignored!", .{arg});
        }
    }
    if (paras.get("tileable") != null) {
        if (st.has(structure.TILEABLE)) {
            params.tileable = true;
            rp.bordersize = 0;
        } else {
            log.warn("maze type '{s}' is not tileable (-T was given).", .{st.name});
        }
    }
    if (paras.get("solution") != null) {
        if (!params.dummy) {
            rp.draw_solution = true;
        } else {
            log.warn("could not draw solution in dummy mode!", .{});
        }
    }
    if (paras.get("columns")) |arg| {
        if (toInt(arg)) |v| {
            params.columns = v;
            if (st.has(structure.RINGS)) {
                if (v < 3 or v > 8) {
                    log.err("maze types with rings only allow column numbers from 3 to 8. Using 6 as default!", .{});
                    params.columns = 6;
                }
            } else if (v < 3) {
                log.warn("given number of columns is to low ({d}); setting it to 3!", .{v});
                params.columns = 3;
            }
        } else {
            log.err("invalid column parameter '{s}'", .{arg});
            doexit = true;
        }
    }
    if (paras.get("rows")) |arg| {
        // recursive mazes can be made of base mazes with 2 cells per side
        const min_rows: i32 = if (paras.get("recursion") != null) 2 else 3;
        var ok = true;
        if (st.has(structure.RINGS)) {
            // either "LAST" or "FIRST-LAST"
            if (std.mem.indexOfScalar(u8, arg, '-')) |sep| {
                const a = toInt(arg[0..sep]);
                const b = toInt(arg[sep + 1 ..]);
                if (a != null and b != null) {
                    params.startring = a.?;
                    params.rows = b.?;
                } else ok = false;
            } else if (toInt(arg)) |v| {
                params.rows = v;
            } else ok = false;
        } else if (toInt(arg)) |v| {
            params.rows = v;
        } else ok = false;
        if (!ok) {
            log.err("invalid row parameter '{s}'", .{arg});
            doexit = true;
        } else if (params.rows < min_rows) {
            log.warn("given number of rows is to low ({d}); setting it to {d}!", .{ params.rows, min_rows });
            params.rows = min_rows;
        }
    }
    if (paras.get("maxcells")) |arg| {
        if (toInt(arg)) |v| {
            if (v < MIN_MAX_CELLS) {
                log.warn("given number of max_cells ({d}) is to low!", .{v});
            } else cfg.max_cells = v;
        } else {
            log.err("invalid max_cells parameter '{s}'", .{arg});
            doexit = true;
        }
    }
    if (paras.get("entrance")) |arg| {
        if (toDirection(arg)) |d| params.entrance = d else {
            log.err("invalid direction '{s}'", .{arg});
            doexit = true;
        }
    }
    if (paras.get("exit")) |arg| {
        if (toDirection(arg)) |d| params.exit = d else {
            log.err("invalid direction '{s}'", .{arg});
            doexit = true;
        }
    }
    if (paras.get("arcs")) |arg| {
        if (st.has(structure.ARCS)) {
            if (toDouble(arg)) |v| {
                rp.bending = v;
                if (@abs(v) > 180) {
                    log.err("parameter {d} for --arcs out of bounds [-180.,180]", .{v});
                    doexit = true;
                }
            } else {
                log.err("invalid parameter '{s}' for --arcs", .{arg});
                doexit = true;
            }
        } else {
            log.warn("maze type '{s}' has no arcs! '--arcs' will be ignored", .{st.name});
        }
    }
    if (paras.get("jitter")) |arg| {
        if (st.has(structure.RANDOMNESS)) {
            if (toDouble(arg)) |v| {
                params.jitter = v;
                if (v < 0 or v > 1) {
                    log.err("parameter {d} for --jitter out of bounds [0,1]", .{v});
                    doexit = true;
                }
            } else {
                log.err("invalid parameter '{s}' for --jitter", .{arg});
                doexit = true;
            }
        } else {
            log.warn("parameter '--jitter/-j' is not applicable for maze type '{s}' and will be ignored", .{st.name});
        }
    }
    if (paras.get("crossings")) |arg| {
        if (st.has(structure.CROSSOVERS)) {
            if (toDouble(arg)) |v| {
                params.crossings = v;
                if (v < 0 or (v > 0.5 and v < 1)) {
                    log.err("parameter {d} for --crossings out of bounds [0,0.5] or [1..n]", .{v});
                    doexit = true;
                }
            } else {
                log.err("invalid parameter '{s}' for option --crossings", .{arg});
                doexit = true;
            }
        } else {
            log.warn("parameter '--crossings' is not applicable for maze type '{s}' and will be ignored", .{st.name});
        }
    }
    if (paras.get("weights")) |arg| {
        if (params.dummy) {
            log.warn("In dummy mode ('--dummy/-d') the weights '{s}' will be ignored!", .{arg});
        } else if (carve.parseWeights(arena, st, arg)) |ws| {
            params.weights = ws;
        } else |e| switch (e) {
            error.NoCellTypes => log.warn("parameter '--weights/-W' is not applicable for maze type '{s}' and will be ignored", .{st.name}),
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const msg = switch (e) {
                    error.InvalidSyntax => "expected e.g. 'A:1,2,1,2/B:1,1,1,1'",
                    error.UnknownCellType => "unknown cell type (see --help for the cell types of each maze type)",
                    error.DuplicateCellType => "cell type given twice",
                    error.WrongNumberOfWeights => "the number of weights must equal the number of neighbours of the cell type (see --help)",
                    error.InvalidWeight => "weights must not be negative and not all be 0",
                    else => unreachable,
                };
                log.err("invalid weights '{s}' for maze type '{s}': {s}", .{ arg, st.name, msg });
                doexit = true;
            },
        }
    }
    inline for (.{ .{ "pillars", "pillars" }, .{ "cave", "caves" } }) |o| {
        if (paras.get(o[0])) |arg| {
            if (pillars.parse(st, arg)) |types| {
                @field(params, o[1]) = types;
            } else |e| {
                const msg = switch (e) {
                    error.InvalidSyntax => "expected cell type letters, e.g. 'B' or 'B,C'",
                    error.UnknownCellType => "unknown cell type (see --help for the cell types of each maze type)",
                };
                log.err("invalid --{s} '{s}' for maze type '{s}': {s}", .{ o[0], arg, st.name, msg });
                doexit = true;
            }
        }
    }
    if (paras.get("max-openings")) |arg| {
        if (pillars.parseLimits(st, arg)) |l| {
            // 0 openings: pillar, 1: cave
            for (l, 0..) |v, t| {
                const b = @as(u32, 1) << @intCast(t);
                if (v == mz.NO_LIMIT) continue;
                if ((params.pillars | params.caves) & b != 0) {
                    log.err("cell type {c} given for --max-openings and --pillars/--cave", .{'A' + @as(u8, @intCast(t))});
                    doexit = true;
                }
                switch (v) {
                    0 => params.pillars |= b,
                    1 => params.caves |= b,
                    else => cfg.limits[t] = v,
                }
            }
        } else |e| {
            const msg = switch (e) {
                error.InvalidSyntax => "expected cell type letters with a number of openings, e.g. 'B:2' or 'B:2/C:3'",
                error.UnknownCellType => "unknown cell type (see --help for the cell types of each maze type)",
                error.DuplicateCellType => "cell type given twice",
            };
            log.err("invalid --max-openings '{s}' for maze type '{s}': {s}", .{ arg, st.name, msg });
            doexit = true;
        }
    }
    if (params.pillars & params.caves != 0) {
        var buf: [64]u8 = undefined;
        log.err("cell type(s) {s} given for both --pillars and --cave", .{typeLetters(&buf, params.pillars & params.caves)});
        doexit = true;
    }
    if (paras.get("rough-border") != null) {
        if (st.has(structure.RANDOMNESS)) {
            params.roughborder = true;
        } else {
            log.warn("parameter '--rough-border' is not applicable for maze type '{s}' and will be ignored", .{st.name});
        }
    }
    if (paras.get("wall-length")) |arg| {
        if (st.has(structure.RANDOMNESS)) {
            if (toDouble(arg)) |v| {
                params.minwalllength = v;
                if (v < 0 or v > 0.5) {
                    log.err("parameter {d} for --wall-length out of bounds [0.,0.5]", .{v});
                    doexit = true;
                }
            } else {
                log.err("invalid parameter '{s}' for --wall-length", .{arg});
                doexit = true;
            }
        } else {
            log.warn("parameter '--wall-length/-w' is not applicable for maze type '{s}' and will be ignored", .{st.name});
        }
    }
    if (paras.get("boundary")) |arg| {
        if (st.has(structure.ARCS)) {
            if (std.mem.eql(u8, arg, "outside")) {
                rp.boundary = .outside;
            } else if (std.mem.eql(u8, arg, "inside")) {
                rp.boundary = .inside;
            } else if (std.mem.eql(u8, arg, "keep")) {
                rp.boundary = .keep;
            } else {
                log.err("invalid parameter {s} for --boundary", .{arg});
                doexit = true;
            }
        } else {
            log.warn("maze type '{s}' has no arcs! '--boundary' will be ignored", .{st.name});
        }
    }
    if (params.rows < 0) {
        log.err("no number of rows '-r' given!", .{});
        doexit = true;
    }
    if (paras.get("recursion")) |arg| {
        if (toInt(arg)) |v| {
            if (v < 0) {
                log.err("invalid recursion parameter '{s}'", .{arg});
                doexit = true;
            } else if (v > 0 and recursive.Kind.of(st) == null) {
                log.err("--recursion is only available for the maze types 'orthogonal:1', 'triangular' and 'hexagonal:1' (so far)", .{});
                doexit = true;
            } else if (v > 0 and params.rows >= 0) {
                params.recursion = @intCast(v);
                params.recursion_base = params.rows;
                if (paras.get("recursion-orientation")) |o| {
                    if (std.meta.stringToEnum(mz.RecursionOrientation, o)) |v2| params.recursion_orientation = v2 else {
                        log.err("invalid --recursion-orientation '{s}': expected 'same', 'rotate', 'random', 'sector' or 'spiral'", .{o});
                        doexit = true;
                    }
                }
                if (paras.get("recursion-opening")) |pos| {
                    if (toRecursionOpening(pos, params.rows)) |o| params.recursion_opening = o else {
                        log.err("invalid --recursion-opening '{s}': expected 'middle', 'random', 'first', 'last' or a cell number from 1 to {d}", .{ pos, params.rows });
                        doexit = true;
                    }
                }
                if (params.columns >= 0 and params.columns != params.rows)
                    log.warn("recursive mazes are square: -c {d} is ignored, -r {d} gives rows and columns of the base maze", .{ params.columns, params.rows });
                // rows and columns stay the size of the base maze
                params.columns = params.rows;
                const total = recursive.cellCount(recursive.Kind.of(st).?, @intCast(params.rows), params.recursion) orelse std.math.maxInt(u64);
                if (total > cfg.max_cells) {
                    log.err("maze would exceed the maximum number of cells ({d}); no maze was created!", .{cfg.max_cells});
                    doexit = true;
                }
                if (params.weights.len > 0) log.warn("--weights is ignored for recursive mazes", .{});
                if (params.tileable) {
                    log.err("recursive mazes can't be tileable (-T)", .{});
                    doexit = true;
                }
                if (params.crossings > 0 or params.pillars | params.caves != 0 or paras.get("max-openings") != null) {
                    log.err("--crossings, --pillars, --cave and --max-openings can't be used for recursive mazes", .{});
                    doexit = true;
                }
            }
        } else {
            log.err("invalid recursion parameter '{s}'", .{arg});
            doexit = true;
        }
    }
    if (params.columns < 0) {
        log.err("no number of columns '-c' given!", .{});
        doexit = true;
    }
    if (opts.rest.len > 0) {
        log.err("illegal argument '{s}'", .{opts.rest[0]});
        doexit = true;
    }
    if (opts.require_output and paras.get("output") == null) {
        log.err("no output file '-o' given (use '-o -' for stdout)", .{});
        doexit = true;
    } else if (rp.format == null and !opts.sample) {
        log.err("no output format specified", .{});
        doexit = true;
    }
    params.max_cells = @intCast(cfg.max_cells);
    if (!doexit and @as(i64, params.rows) * params.columns > cfg.max_cells) {
        log.err("maze would exceed the maximum number of cells ({d}); no maze was created!", .{cfg.max_cells});
        doexit = true;
    }
    if (doexit) return error.InvalidArguments;

    if (opts.sample) {
        params.rows = @min(params.rows, MAX_NO_SAMPLE_ROWS);
        params.columns = @min(params.columns, MAX_NO_SAMPLE_COLUMNS);
        rp.format = .png;
        rp.xcellsize = @min(rp.xcellsize, MAX_SAMPLE_CELLSIZE);
        rp.ycellsize = @min(rp.ycellsize, MAX_SAMPLE_CELLSIZE);
    }
    if (st.has(structure.RINGS) and params.startring >= params.rows) {
        params.startring = params.rows - 2;
        log.warn("adjusting startring to {d}!", .{params.startring});
    }
    inline for (.{ "recursion-opening", "recursion-orientation" }) |o| {
        if (params.recursion == 0 and paras.get(o) != null)
            log.warn("'--" ++ o ++ "' is only used with '--recursion' and will be ignored", .{});
    }
    params.mask = opts.mask;
    if (params.recursion > 0 and opts.mask != null) {
        log.warn("--mask is ignored for recursive mazes", .{});
        params.mask = null;
    }
    return cfg;
}

// ---------------------------------------------------------------------------
// construction, carving, rendering

/// Turns the cell types `pillar_types` into pillars (`--pillars`) and
/// `cave_types` into caves (`--cave`); fails if no maze can be built from
/// the remaining cells.
fn applyPillars(gpa: Allocator, maze: *mz.Maze, pillar_types: u32, cave_types: u32, name: []const u8) Error!void {
    var buf: [64]u8 = undefined;
    const types = pillar_types | cave_types;
    const opt = if (pillar_types == 0) "--cave" else if (cave_types == 0) "--pillars" else "--pillars/--cave";
    const res = pillars.apply(gpa, maze, pillar_types, cave_types) catch return error.OutOfMemory;
    switch (res.status) {
        .ok => {
            if (res.cut_off > 0) log.info("{s}: {d} cell(s) at the border cut off were turned into pillars", .{ opt, res.cut_off });
            if (res.lonely_caves > 0) log.info("--cave: {d} cave(s) without a neighbouring maze cell were turned into pillars", .{res.lonely_caves});
        },
        .missing => {
            log.err("{s}: maze type '{s}' has no cells of type {s} (see --help for the cell types)", .{ opt, name, typeLetters(&buf, res.missing) });
            return error.Failed;
        },
        .nothing_left => {
            log.err("{s}: no maze cells left when excluding cell type(s) {s}", .{ opt, typeLetters(&buf, types) });
            return error.Failed;
        },
        .split => {
            const why = if (cave_types != 0) " (caves are dead ends and can't connect parts of the maze)" else "";
            if (res.enclosed > 0)
                log.err("{s}: without cell type(s) {s} the maze splits into {d} separate parts ({d} of them enclosed, the largest has {d} of {d} cells){s}; no maze can be built", .{ opt, typeLetters(&buf, types), res.parts, res.enclosed, res.largest, res.total, why })
            else
                log.err("{s}: without cell type(s) {s} the maze splits into {d} separate parts (the largest has {d} of {d} cells){s}; no maze can be built", .{ opt, typeLetters(&buf, types), res.parts, res.largest, res.total, why });
            return error.Failed;
        },
    }
}

/// Builds the grid of the maze (not yet carved) with pillars, caves and
/// opening limits applied.
pub fn construct(gpa: Allocator, cfg: *Config) Error!*mz.Maze {
    const params = &cfg.params;
    const st = params.structure;
    var rand = rng.Random.init(params.seed);
    const maze = mz.newMaze(gpa, params, &rand) catch |e| switch (e) {
        error.TooManyCells => {
            log.err("maze would exceed the maximum number of cells ({d}); no maze was created!", .{cfg.max_cells});
            return error.Failed;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.err("an internal error occured ({t})! maze could not be built!", .{e});
            return error.Failed;
        },
    };
    errdefer maze.deinit();
    // carving keeps drawing numbers: the generator has to outlive this function
    const r = maze.alloc().create(rng.Random) catch return error.OutOfMemory;
    r.* = rand;
    maze.rand = r;
    if (params.pillars | params.caves != 0) try applyPillars(gpa, maze, params.pillars, params.caves, st.name);
    maze.setLimits(cfg.limits);
    return maze;
}

/// Carves the passages (unless in dummy mode) and opens the caves.
pub fn carveMaze(gpa: Allocator, cfg: *Config, maze: *mz.Maze) Error!void {
    const params = &cfg.params;
    if (!params.dummy) {
        const res = if (params.recursion > 0) recursive.carveRecursive(gpa, params, maze) else carve.carveMaze(gpa, params, maze);
        res catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoEntrance, error.NoExit => {
                if (params.pillars | params.caves != 0)
                    log.err("no cell at the border found for the {s}; maybe all of them are pillars or caves (--pillars, --cave)", .{if (e == error.NoEntrance) "entrance" else "exit"})
                else
                    log.err("an internal error occured ({t})! maze could not be built!", .{e});
                return error.Failed;
            },
            error.LimitUnsatisfiable => {
                log.err("no maze found with the given maximum numbers of openings (--max-openings); try other limits or another seed", .{});
                return error.Failed;
            },
            else => {
                log.err("an internal error occured ({t})! maze could not be built!", .{e});
                return error.Failed;
            },
        };
    }
    pillars.finishCaves(maze, !params.dummy);
}

/// Draws the maze in the configured format (default PNG); the caller owns
/// the returned document.
pub fn draw(gpa: Allocator, cfg: *Config, maze: *mz.Maze) Error![]u8 {
    return output.renderDocument(gpa, maze, &cfg.rp) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TextTooLong => {
            log.err("the text (--text) is too long for the solution path", .{});
            return error.Failed;
        },
        error.PathTooShort => {
            log.err("the solution path is too short for the text (--text)", .{});
            return error.Failed;
        },
    };
}

/// Construction, carving and drawing in one step.
pub fn generate(gpa: Allocator, cfg: *Config) Error![]u8 {
    const maze = try construct(gpa, cfg);
    defer maze.deinit();
    try carveMaze(gpa, cfg, maze);
    return draw(gpa, cfg, maze);
}

/// Parses the arguments and generates the maze; the convenience entry point
/// of hosts without files (the WebAssembly module, tests). `paras` receives
/// the effective parameters (including the seed).
pub fn run(gpa: Allocator, arena: Allocator, args: []const []const u8, paras: *Parameters, opts: ConfigureOptions) Error![]u8 {
    var parsed: std.ArrayListUnmanaged(Parsed) = .empty;
    var rest: std.ArrayListUnmanaged([]const u8) = .empty;
    parseArgs(arena, args, &parsed, &rest) catch |e| switch (e) {
        error.InvalidOption => return error.InvalidArguments,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (!try collect(parsed.items, paras)) return error.InvalidArguments;
    var o = opts;
    o.rest = rest.items;
    for (parsed.items) |p| {
        if (std.mem.eql(u8, p.opt.long, "sample")) o.sample = true;
    }
    var cfg = try configure(arena, paras, o);
    return generate(gpa, &cfg);
}

// ---------------------------------------------------------------------------

test "color parsing" {
    const c1 = toColor("#ff0000").?;
    try std.testing.expectEqual(@as(f64, 1), c1.red);
    try std.testing.expectEqual(@as(f64, 0), c1.blue);
    const c2 = toColor("0.5,0.25,1,0.5").?;
    try std.testing.expectEqual(@as(f64, 0.25), c2.green);
    try std.testing.expectEqual(@as(f64, 0.5), c2.alpha);
    try std.testing.expect(toColor("rgba(255,0,0,0.5)") != null);
    try std.testing.expect(toColor("1,2") == null);
}

test "points" {
    try std.testing.expectEqual(@as(f64, 72), toPoints("1in").?);
    try std.testing.expectEqual(@as(f64, 12), toPoints("12").?);
    try std.testing.expect(toPoints("12xx") == null);
}

test "run renders a maze into memory" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var paras = Parameters.init(gpa);
    defer paras.deinit();
    const args = [_][]const u8{ "-t", "6:2", "-r", "5", "-c", "5", "-f", "svg", "-P" };
    const doc = try run(gpa, arena, &args, &paras, .{ .default_seed = 4711, .require_output = false });
    defer gpa.free(doc);
    try std.testing.expect(std.mem.startsWith(u8, doc, "<?xml"));
    try std.testing.expect(std.mem.indexOf(u8, doc, "<svg") != null);
    // the time based seed was recorded
    try std.testing.expectEqualStrings("4711", paras.get("seed").?);

    var paras2 = Parameters.init(gpa);
    defer paras2.deinit();
    const png = try run(gpa, arena, &[_][]const u8{ "-t", "4", "-r", "4", "-c", "4", "-f", "png", "-S", "1" }, &paras2, .{ .default_seed = 1, .require_output = false });
    defer gpa.free(png);
    try std.testing.expectEqualSlices(u8, "\x89PNG", png[0..4]);
}

test "run reports invalid arguments" {
    silence_logs = true;
    defer silence_logs = false;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var paras = Parameters.init(gpa);
    defer paras.deinit();
    try std.testing.expectError(error.InvalidArguments, run(gpa, arena, &[_][]const u8{ "-t", "nope", "-r", "5", "-c", "5", "-f", "svg" }, &paras, .{ .default_seed = 1, .require_output = false }));
    var paras2 = Parameters.init(gpa);
    defer paras2.deinit();
    try std.testing.expectError(error.InvalidArguments, run(gpa, arena, &[_][]const u8{ "-t", "4", "-r", "5", "-c", "5", "--bogus" }, &paras2, .{ .default_seed = 1, .require_output = false }));
}
