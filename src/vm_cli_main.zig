const std = @import("std");
const plugin_api = @import("plugin_api");
const plugin = @import("plugin.zig");

/// Local driver that mirrors `sa vm <run|test> [options] <file.sa|.sab>` without
/// requiring the plugin host. Used for manual verification of both pipelines.
pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    const ctx = plugin_api.Context{ .allocator = allocator };
    const result = plugin.runVmCommand(allocator, &ctx, args[1..], stdout_buf.writer().any(), stderr_buf.writer().any()) catch |err| {
        std.debug.print("vm_cli: runVmCommand failed: {}\n", .{err});
        return 1;
    };

    if (stdout_buf.items.len != 0) {
        std.io.getStdOut().writeAll(stdout_buf.items) catch {};
    }
    if (stderr_buf.items.len != 0) {
        std.io.getStdErr().writeAll(stderr_buf.items) catch {};
    }
    return result orelse 1;
}
