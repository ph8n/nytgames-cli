const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Application version") orelse "0.0.0";

    // Create executable module (for ZLS support)
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    exe_mod.addOptions("build_options", build_options);

    // Add vaxis dependency to module
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("vaxis", vaxis.module("vaxis"));

    // Add zig-sqlite
    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("sqlite", sqlite.module("sqlite"));

    // Add zig-curl
    const curl = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("curl", curl.module("curl"));

    // Create executable
    const exe = b.addExecutable(.{
        .name = "nytgames",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test step
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
