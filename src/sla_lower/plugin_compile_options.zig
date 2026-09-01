const std = @import("std");

pub const SlaCompileOptions = struct {
    test_filter: ?[]const u8 = null,
    allow_fallback: bool = true,
    prune_for_test_codegen: bool = false,
    prune_for_entry_function: ?[]const u8 = null,
    load_reachable_imported_bodies_from_registry: bool = false,
};

pub fn defaultSlaCompileOptions() SlaCompileOptions {
    return .{ .load_reachable_imported_bodies_from_registry = true };
}

pub fn slaProfileEnabled(allocator: std.mem.Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "SLA_PROFILE") catch return false;
    defer allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

pub fn slaProfileContractsEnabled(allocator: std.mem.Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "SLA_PROFILE_CONTRACTS") catch return false;
    defer allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

pub fn slaSabFallbackAllowed(allocator: std.mem.Allocator, options: SlaCompileOptions) bool {
    if (!options.allow_fallback) return false;
    const value = std.process.getEnvVarOwned(allocator, "SLA_SAB_NO_FALLBACK") catch return true;
    defer allocator.free(value);
    return value.len == 0 or std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false");
}

pub fn slaProfileStage(stderr: std.io.AnyWriter, enabled: bool, label: []const u8, start_ns: i128) void {
    if (!enabled) return;
    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - start_ns, std.time.ns_per_ms);
    stderr.print("[sla-profile] {s}: {d}ms\n", .{ label, elapsed_ms }) catch {};
}

pub fn writeEmptyTestResult(stdout: std.io.AnyWriter) !void {
    try stdout.writeAll("----\n");
    try stdout.writeAll("test result: ok. 0 passed; 0 failed; 0 skipped\n");
}
