const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sci_root = b.option([]const u8, "sci-root", "Path to the sci checkout") orelse "../sci";
    const sio_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ sci_root, "src", "sa_io.zig" }) },
        .target = target,
        .optimize = optimize,
    });
    const plugin_api = b.createModule(.{
        .root_source_file = b.path("src/plugin_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("plugin_api", plugin_api);
    root_module.addImport("sio", sio_module);
    const lib = b.addLibrary(.{
        .name = "vm",
        .root_module = root_module,
        .linkage = .dynamic,
    });
    root_module.linkSystemLibrary("ffi", .{});
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_module = root_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run plugin tests");
    test_step.dependOn(&run_tests.step);
}
