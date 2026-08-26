const std = @import("std");
const parser = @import("parser.zig");
const sab_loader = @import("sab_loader.zig");

/// Debug helper: load a .sab file through the VM loader and print the
/// resulting Program structure (ops, dests, operand kinds, blocks).
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.debug.print("usage: dump_prog <file.sab>\n", .{});
        return error.Usage;
    }

    const bytes = try std.fs.cwd().readFileAlloc(allocator, args[1], 256 * 1024 * 1024);
    const stdout = std.io.getStdOut().writer();

    const prog = try sab_loader.loadProgram(allocator, bytes);

    var ext_it = prog.externs.iterator();
    while (ext_it.next()) |entry| {
        try stdout.print("@extern {s}(", .{entry.key_ptr.*});
        for (entry.value_ptr.arg_types, 0..) |ty, idx| {
            if (idx != 0) try stdout.writeAll(", ");
            try stdout.print("{s}", .{@tagName(ty)});
        }
        try stdout.print(") -> {s}\n", .{@tagName(entry.value_ptr.return_type)});
    }

    var func_it = prog.functions.iterator();
    while (func_it.next()) |entry| {
        const func = entry.value_ptr.*;
        try stdout.print("\n@{s}({s}):\n", .{ func.name, blk: {
            var buf = std.ArrayList(u8).init(allocator);
            for (func.params, 0..) |param, idx| {
                if (idx != 0) try buf.appendSlice(", ");
                try buf.appendSlice(param);
            }
            break :blk buf.items;
        } });
        try stdout.print("returns_result={}\n", .{func.returns_result});
        for (func.blocks) |block| {
            try stdout.print("  block {s}: [{d}, {d})\n", .{ block.label, block.start_inst, block.end_inst });
        }
        for (func.instructions, 0..) |inst, pc| {
            try stdout.print("  {d:>3}: {s}", .{ pc, @tagName(inst.op) });
            if (inst.dest) |dest| try stdout.print(" {s}", .{dest});
            if (inst.dest_type != .void) try stdout.print(" :{s}", .{@tagName(inst.dest_type)});
            for (inst.args) |arg| {
                switch (arg.kind) {
                    .register => try stdout.print(" %{s}", .{arg.name}),
                    .stack_addr => try stdout.print(" &{s}", .{arg.name}),
                    .constant_addr => try stdout.print(" @{s}", .{arg.name}),
                    .offset_addr => try stdout.print(" &{s}+{d}", .{ arg.name, arg.offset }),
                    .immediate => try stdout.print(" #{d}", .{arg.imm_val}),
                    .label => try stdout.print(" ->{s}", .{arg.name}),
                }
            }
            try stdout.writeByte('\n');
        }
    }

    var const_it = prog.constants.iterator();
    while (const_it.next()) |entry| {
        try stdout.print("@const {s} = <{d} bytes>\n", .{ entry.key_ptr.*, entry.value_ptr.len });
    }
}
