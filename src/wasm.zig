//! maze5 as a WebAssembly module (`zig build wasm`), for the browser.
//!
//! The module has no entry point; the host (JavaScript) calls the exported
//! functions. Strings and buffers are exchanged through the module's memory:
//! the host allocates input buffers with `maze5_alloc`, the module keeps the
//! results of the last call until the next one (`maze5_result_*`,
//! `maze5_log_*`, `maze5_params_*`). Messages that the command line program
//! prints to stderr are collected in the log instead.
//!
//! Protocol of `maze5_run`: the arguments are the command line arguments
//! (without the program name) separated by NUL bytes, e.g.
//! "-t\x006:2\x00-r\x0020\x00-c\x0020\x00-f\x00svg". An optional mask image
//! (PNG) is passed as a second buffer; `-o` is not needed, the format comes
//! from `-f`. The return value is 0 on success, 1 for invalid arguments,
//! 2 if no maze could be built and 3 when out of memory; the log says why.

const std = @import("std");
const app = @import("app.zig");
const structure = @import("structure.zig");
const Parameters = @import("params.zig").Parameters;
const Mask = @import("mask.zig").Mask;

pub const std_options: std.Options = .{ .logFn = logFn, .log_level = .info };
pub const panic = std.debug.FullPanic(panicFn);

const gpa = std.heap.wasm_allocator;

var log: std.Io.Writer.Allocating = .init(gpa);
var result: []u8 = &.{};
var params_json: []u8 = &.{};
var panic_msg: [256]u8 = undefined;
var panic_len: usize = 0;

fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    _ = scope;
    const prefix = switch (level) {
        .err => "error: ",
        .warn => "warning: ",
        .info => "info: ",
        .debug => "debug: ",
    };
    log.writer.print(prefix ++ format ++ "\n", args) catch {};
}

/// A panic traps; the host reads the message with `maze5_panic_*`.
fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    panic_len = @min(msg.len, panic_msg.len);
    @memcpy(panic_msg[0..panic_len], msg[0..panic_len]);
    @trap();
}

fn setResult(doc: []u8) void {
    gpa.free(result);
    result = doc;
}

fn reset() void {
    setResult(&.{});
    gpa.free(params_json);
    params_json = &.{};
    log.clearRetainingCapacity();
}

/// Memory for input buffers (arguments, mask image).
export fn maze5_alloc(len: usize) ?[*]u8 {
    const s = gpa.alloc(u8, len) catch return null;
    return s.ptr;
}

export fn maze5_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// Builds and renders a maze; see the protocol above.
export fn maze5_run(args_ptr: [*]const u8, args_len: usize, mask_ptr: ?[*]const u8, mask_len: usize, default_seed: u32) i32 {
    reset();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    if (args_len > 0) {
        var it = std.mem.splitScalar(u8, args_ptr[0..args_len], 0);
        while (it.next()) |a| args.append(arena, a) catch return 3;
    }

    var mask: ?Mask = null;
    defer if (mask) |*m| m.deinit(gpa);
    if (mask_ptr) |p| {
        if (mask_len > 0) {
            mask = Mask.fromPng(gpa, p[0..mask_len], "mask") catch |e| switch (e) {
                error.OutOfMemory => return 3,
                else => return 1,
            };
        }
    }

    var paras = Parameters.init(gpa);
    defer paras.deinit();
    const doc = app.run(gpa, arena, args.items, &paras, .{
        .mask = if (mask) |*m| m else null,
        .default_seed = default_seed,
        .require_output = false,
    }) catch |e| switch (e) {
        error.InvalidArguments => return 1,
        error.Failed => return 2,
        error.OutOfMemory => return 3,
    };
    setResult(doc);
    params_json = paras.toJson(gpa) catch &.{};
    return 0;
}

/// The maze types as JSON (see `structure.writeTypesJson`), as result.
export fn maze5_types() i32 {
    reset();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    structure.writeTypesJson(&aw.writer) catch {
        aw.deinit();
        return 3;
    };
    setResult(aw.toOwnedSlice() catch return 3);
    return 0;
}

/// The program version, as result.
export fn maze5_version() i32 {
    reset();
    setResult(gpa.dupe(u8, app.version) catch return 3);
    return 0;
}

export fn maze5_result_ptr() [*]const u8 {
    return result.ptr;
}

export fn maze5_result_len() usize {
    return result.len;
}

/// Messages of the last call (errors, warnings, infos), one per line.
export fn maze5_log_ptr() [*]const u8 {
    return log.written().ptr;
}

export fn maze5_log_len() usize {
    return log.written().len;
}

/// The effective parameters of the last successful run as a JSON object
/// of strings (the same format as `--save`), including the seed.
export fn maze5_params_ptr() [*]const u8 {
    return params_json.ptr;
}

export fn maze5_params_len() usize {
    return params_json.len;
}

export fn maze5_panic_ptr() [*]const u8 {
    return &panic_msg;
}

export fn maze5_panic_len() usize {
    return panic_len;
}
