const std = @import("std");
const parser = @import("../src/parser.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = parser.Parser.init(allocator);
    defer p.deinit();

    const preprocessed = try p.preprocess("tests/async_await_test.sa");
    defer {
        for (preprocessed) |line| allocator.free(line);
        allocator.free(preprocessed);
    }

    std.debug.print("=== PREPROCESSED LINES ===\n", .{});
    for (preprocessed, 0..) |line, idx| {
        std.debug.print("{d: >3}: {s}\n", .{ idx + 1, line });
    }
}
