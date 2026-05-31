const std = @import("std");
const parser = @import("parser.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // Skip executable name
    const target_file = args.next() orelse {
        std.debug.print("Usage: dump_preprocessed <file.sa>\n", .{});
        std.process.exit(1);
    };

    var p = parser.Parser.init(allocator);
    defer p.deinit();

    const preprocessed = try p.preprocess(target_file);
    defer {
        for (preprocessed) |line| allocator.free(line);
        allocator.free(preprocessed);
    }

    std.debug.print("=== PREPROCESSED LINES ===\n", .{});
    for (preprocessed, 0..) |line, idx| {
        std.debug.print("{d: >3}: {s}\n", .{ idx + 1, line });
    }
}
