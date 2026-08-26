const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
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

    // Shared SAB bytecode codec from the sibling sci repo. Resolution order,
    // first match wins: SCI_ROOT env var, then ../sci and ../../../sci sibling
    // probes (same convention sa_plugin_sla/build.zig uses).
    const sci_root = resolveSciRoot(b);
    const sab_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ sci_root, "src", "sab.zig" }) },
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("sab", sab_module);

    const lib = b.addLibrary(.{
        .name = "vm",
        .root_module = root_module,
        .linkage = .dynamic,
    });
    if (target.result.os.tag != .windows) lib.linkSystemLibrary("ffi");
    b.installArtifact(lib);

    // Local CLI driver for manual verification (mirrors `sa vm run`).
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/vm_cli_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_module.addImport("plugin_api", plugin_api);
    cli_module.addImport("sab", sab_module);
    const vm_cli = b.addExecutable(.{
        .name = "vm_cli",
        .root_module = cli_module,
    });
    if (target.result.os.tag != .windows) vm_cli.linkSystemLibrary("ffi");
    b.installArtifact(vm_cli);

    // Debug helper: print the Program produced by the SAB loader.
    const dump_module = b.createModule(.{
        .root_source_file = b.path("src/dump_prog.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dump_module.addImport("sab", sab_module);
    const dump_prog = b.addExecutable(.{
        .name = "dump_prog",
        .root_module = dump_module,
    });
    b.installArtifact(dump_prog);

    const tests = b.addTest(.{
        .root_module = root_module,
    });
    if (target.result.os.tag != .windows) tests.linkSystemLibrary("ffi");
    const run_tests = b.addRunArtifact(tests);

    // Capability I/O policy engine (src/policy.zig) — standalone test target,
    // no dependency on plugin/vm sources.
    const policy_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/policy_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_policy_tests = b.addRunArtifact(policy_tests);

    const test_step = b.step("test", "Run plugin tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_policy_tests.step);
}

fn dirHasFile(dir: []const u8, name: []const u8) bool {
    var d = std.fs.cwd().openDir(dir, .{}) catch return false;
    defer d.close();
    d.access(name, .{}) catch return false;
    return true;
}

/// Resolve the sibling sci repo that provides the shared SAB codec module.
/// SCI_ROOT env var wins, then ../sci and ../../../sci probes. Falls back to
/// ../sci so a missing repo reports a clear build-time path error.
fn resolveSciRoot(b: *std.Build) []const u8 {
    const a = b.allocator;
    if (std.process.getEnvVarOwned(a, "SCI_ROOT")) |env_root| {
        if (dirHasFile(env_root, "src/sab.zig")) return env_root;
    } else |_| {}
    for ([_][]const u8{ "../sci", "../../../sci" }) |candidate| {
        if (dirHasFile(candidate, "src/sab.zig")) return a.dupe(u8, candidate) catch candidate;
    }
    return "../sci";
}
