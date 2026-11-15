const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "maze5",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run maze5");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // generator of the periodic structure tables: `zig build gen-periodic -- TILING [ROWS]`
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_periodic.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    });
    const gen = b.addExecutable(.{ .name = "gen_periodic", .root_module = gen_mod });
    const gen_run = b.addRunArtifact(gen);
    gen_run.addPassthruArgs();
    const gen_step = b.step("gen-periodic", "Print the structure table of a periodic tiling (tools/gen_periodic.zig)");
    gen_step.dependOn(&gen_run.step);
    const gen_tests = b.addRunArtifact(b.addTest(.{ .root_module = gen_mod }));
    test_step.dependOn(&gen_tests.step);

    // WebAssembly module for the browser: `zig build wasm` -> zig-out/web/maze5.wasm
    const wasm_optimize = b.option(std.builtin.OptimizeMode, "wasm-optimize", "Optimization mode of the WebAssembly module (default: small)") orelse .small;
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = wasm_optimize,
    });
    const wasm = b.addExecutable(.{
        .name = "maze5",
        .root_module = wasm_mod,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const wasm_install = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
    const wasm_step = b.step("wasm", "Build the WebAssembly module (zig-out/web/maze5.wasm)");
    wasm_step.dependOn(&wasm_install.step);
}
