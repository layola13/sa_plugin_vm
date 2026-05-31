const std = @import("std");
const parser = @import("parser.zig");
const ffi = @import("ffi.zig");

pub const Val = union(enum) {
    integer: u64,
    float: f64,
    pointer: usize,
    null_val,
};

pub const VM = struct {
    program: *parser.Program,
    allocator: std.mem.Allocator,
    ffi: *ffi.FfiManager,
    function_addresses: std.AutoHashMap(usize, []const u8),
    function_names: std.StringHashMap(usize),
    dummy_buffers: std.ArrayList(*u8),

    pub fn init(allocator: std.mem.Allocator, program: *parser.Program, ffi_mgr: *ffi.FfiManager) VM {
        return .{
            .allocator = allocator,
            .program = program,
            .ffi = ffi_mgr,
            .function_addresses = std.AutoHashMap(usize, []const u8).init(allocator),
            .function_names = std.StringHashMap(usize).init(allocator),
            .dummy_buffers = std.ArrayList(*u8).init(allocator),
        };
    }

    pub fn deinit(self: *VM) void {
        self.function_addresses.deinit();
        self.function_names.deinit();
        for (self.dummy_buffers.items) |buf| {
            self.allocator.destroy(buf);
        }
        self.dummy_buffers.deinit();
    }

    pub fn run(self: *VM) !i32 {
        try self.initFunctionsAndVtables();

        const main_func = self.program.functions.get("main") orelse {
            std.debug.print("Error: @main function not found!\n", .{});
            return 1;
        };
        const main_code = try self.executeFunction(&main_func, &.{});
        return @as(i32, @bitCast(@as(u32, @intCast(main_code & 0xffffffff))));
    }

    fn initFunctionsAndVtables(self: *VM) !void {
        // 1. Assign unique mock addresses to all internal functions
        var func_it = self.program.functions.iterator();
        while (func_it.next()) |entry| {
            const func_name = entry.key_ptr.*;
            const dummy = try self.allocator.create(u8);
            dummy.* = 0;
            try self.dummy_buffers.append(dummy);
            
            const addr = @intFromPtr(dummy);
            try self.function_addresses.put(addr, func_name);
            try self.function_names.put(func_name, addr);
        }

        // 2. Scan and compile vtable constants in-place
        var const_it = self.program.constants.iterator();
        while (const_it.next()) |entry| {
            const val_str = entry.value_ptr.*;

            if (std.mem.startsWith(u8, val_str, "vtable {")) {
                const brace_start = std.mem.indexOf(u8, val_str, "{").?;
                const brace_end = std.mem.lastIndexOf(u8, val_str, "}").?;
                const inner = val_str[brace_start + 1 .. brace_end];

                var methods_list = std.ArrayList(usize).init(self.allocator);
                errdefer methods_list.deinit();

                var method_it = std.mem.tokenizeAny(u8, inner, ",");
                while (method_it.next()) |method| {
                    const cleaned = std.mem.trim(u8, method, " \t");
                    if (cleaned.len == 0) continue;

                    const eq_idx = std.mem.indexOf(u8, cleaned, "=") orelse return error.InvalidVTableSyntax;
                    const m_val_raw = std.mem.trim(u8, cleaned[eq_idx + 1 ..], " \t");

                    var target_func_name = m_val_raw;
                    if (std.mem.startsWith(u8, target_func_name, "@")) {
                        target_func_name = target_func_name[1..];
                    }

                    const func_ptr = if (self.function_names.get(target_func_name)) |ptr|
                        ptr
                    else if (self.ffi.resolveSymbol(target_func_name)) |sym|
                        @intFromPtr(sym)
                    else {
                        std.debug.print("VTable method target function not found: {s}\n", .{target_func_name});
                        return error.SymbolNotFound;
                    };
                    try methods_list.append(func_ptr);
                }

                const vtable_mem = try self.allocator.alloc(usize, methods_list.items.len);
                @memcpy(vtable_mem, methods_list.items);
                methods_list.deinit();

                self.allocator.free(val_str);

                const byte_slice = std.mem.sliceAsBytes(vtable_mem);
                entry.value_ptr.* = byte_slice;
            }
        }
    }

    fn executeFunction(self: *VM, func: *const parser.Function, call_args: []const usize) !usize {
        var regs = std.StringHashMap(Val).init(self.allocator);
        defer {
            var it = regs.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            regs.deinit();
        }

        // Initialize parameter registers
        for (func.params, call_args) |param_name, arg_val| {
            const p_name = try self.allocator.dupe(u8, param_name);
            try regs.put(p_name, Val{ .integer = arg_val });
        }

        var stack_allocs = std.ArrayList([]u64).init(self.allocator);
        defer {
            for (stack_allocs.items) |buf| {
                self.allocator.free(buf);
            }
            stack_allocs.deinit();
        }

        var pc: usize = 0;
        while (pc < func.instructions.len) {
            const inst = func.instructions[pc];

            switch (inst.op) {
                .stack_alloc, .alloc => {
                    const size = try self.resolveVal(&regs, inst.args[0]);
                    const word_count = @max(@as(usize, 1), (size + @sizeOf(u64) - 1) / @sizeOf(u64));
                    const buf = try self.allocator.alloc(u64, word_count);
                    const bytes = std.mem.sliceAsBytes(buf);
                    @memset(bytes, 0);
                    try stack_allocs.append(buf);
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    try regs.put(dest_name, Val{ .pointer = @intFromPtr(bytes.ptr) });
                    pc += 1;
                },
                .ptr_add => {
                    const ptr_val = try self.resolveVal(&regs, inst.args[0]);
                    const offset_val = try self.resolveVal(&regs, inst.args[1]);
                    const result = ptr_val + offset_val;
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    try regs.put(dest_name, Val{ .pointer = result });
                    pc += 1;
                },
                .add, .sub, .mul, .div, .rem, .sdiv, .udiv, .srem, .urem, .shl, .shr => {
                    const arg1 = try self.resolveVal(&regs, inst.args[0]);
                    const arg2 = try self.resolveVal(&regs, inst.args[1]);
                    const result = switch (inst.op) {
                        .add => arg1 +% arg2,
                        .sub => arg1 -% arg2,
                        .mul => arg1 *% arg2,
                        .div => if (arg2 != 0) arg1 / arg2 else 0,
                        .sdiv => sdiv: {
                            const s_arg1 = @as(i64, @bitCast(arg1));
                            const s_arg2 = @as(i64, @bitCast(arg2));
                            break :sdiv @as(u64, @bitCast(if (s_arg2 != 0) @divTrunc(s_arg1, s_arg2) else @as(i64, 0)));
                        },
                        .udiv => if (arg2 != 0) arg1 / arg2 else 0,
                        .srem => srem: {
                            const s_arg1 = @as(i64, @bitCast(arg1));
                            const s_arg2 = @as(i64, @bitCast(arg2));
                            break :srem @as(u64, @bitCast(if (s_arg2 != 0) @rem(s_arg1, s_arg2) else @as(i64, 0)));
                        },
                        .urem, .rem => if (arg2 != 0) arg1 % arg2 else 0,
                        .shl => arg1 << @intCast(arg2 & 63),
                        .shr => arg1 >> @intCast(arg2 & 63),
                        else => unreachable,
                    };
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    try regs.put(dest_name, Val{ .integer = result });
                    pc += 1;
                },
                .and_, .or_, .xor_ => {
                    const arg1 = try self.resolveVal(&regs, inst.args[0]);
                    const arg2 = try self.resolveVal(&regs, inst.args[1]);
                    const result = switch (inst.op) {
                        .and_ => arg1 & arg2,
                        .or_ => arg1 | arg2,
                        .xor_ => arg1 ^ arg2,
                        else => unreachable,
                    };
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    try regs.put(dest_name, Val{ .integer = result });
                    pc += 1;
                },
                .call => {
                    const func_name = inst.args[0].name;
                    var args = std.ArrayList(usize).init(self.allocator);
                    defer args.deinit();
                    for (inst.args[1..]) |arg| {
                        const val = try self.resolveVal(&regs, arg);
                        try args.append(val);
                    }

                    if (std.mem.eql(u8, func_name, "sa_print_bytes")) {
                        const ptr_val = args.items[0];
                        const len_val = args.items[1];
                        const slice = @as([*]const u8, @ptrFromInt(ptr_val))[0..len_val];
                        _ = std.posix.write(std.posix.STDOUT_FILENO, slice) catch {};
                        if (inst.dest) |d| {
                            const dest_name = try self.allocator.dupe(u8, d);
                            try regs.put(dest_name, Val{ .integer = 0 });
                        }
                    } else if (std.mem.eql(u8, func_name, "sa_time_unix_s")) {
                        if (inst.dest) |d| {
                            const dest_name = try self.allocator.dupe(u8, d);
                            try regs.put(dest_name, Val{ .integer = @as(u64, @bitCast(std.time.timestamp())) });
                        }
                    } else if (std.mem.eql(u8, func_name, "sa_time_unix_ms")) {
                        if (inst.dest) |d| {
                            const dest_name = try self.allocator.dupe(u8, d);
                            try regs.put(dest_name, Val{ .integer = @as(u64, @bitCast(std.time.milliTimestamp())) });
                        }
                    } else if (std.mem.eql(u8, func_name, "sa_time_unix_ns")) {
                        if (inst.dest) |d| {
                            const dest_name = try self.allocator.dupe(u8, d);
                            try regs.put(dest_name, Val{ .integer = @as(u64, @bitCast(@as(i64, @intCast(std.time.nanoTimestamp())))) });
                        }
                    } else if (std.mem.eql(u8, func_name, "sa_time_instant_ns")) {
                        if (inst.dest) |d| {
                            const dest_name = try self.allocator.dupe(u8, d);
                            // For simplicity, use unix_ns or a monotonic clock if available
                            try regs.put(dest_name, Val{ .integer = @as(u64, @bitCast(@as(i64, @intCast(std.time.nanoTimestamp())))) });
                        }
                    } else if (std.mem.eql(u8, func_name, "sa_time_sleep_ns")) {
                        const ns = args.items[0];
                        std.time.sleep(ns);
                        if (inst.dest) |d| {
                            const dest_name = try self.allocator.dupe(u8, d);
                            try regs.put(dest_name, Val{ .integer = 0 });
                        }
                    } else if (std.mem.eql(u8, func_name, "sa_time_sleep_ms")) {
                        const ms = args.items[0];
                        std.time.sleep(ms * std.time.ns_per_ms);
                        if (inst.dest) |d| {
                            const dest_name = try self.allocator.dupe(u8, d);
                            try regs.put(dest_name, Val{ .integer = 0 });
                        }
                    } else if (std.mem.eql(u8, func_name, "sa_time_utc_now")) {
                        const ptr = args.items[0];
                        try self.writeUtcNow(ptr);
                        if (inst.dest) |d| {
                            const dest_name = try self.allocator.dupe(u8, d);
                            try regs.put(dest_name, Val{ .integer = 0 });
                        }
                    } else if (std.mem.eql(u8, func_name, "sa_deno_plugin_free_buffer")) {
                        if (self.ffi.resolveSymbol("sa_deno_plugin_free_buffer")) |sym| {
                            const f = @as(ffi.FfiFn, @ptrCast(sym));
                            const ret = f(args.items[0], args.items[1], 0, 0, 0, 0, 0, 0, 0);
                            if (inst.dest) |d| {
                                const dest_name = try self.allocator.dupe(u8, d);
                                try regs.put(dest_name, Val{ .integer = ret });
                            }
                        } else {
                            if (inst.dest) |d| {
                                const dest_name = try self.allocator.dupe(u8, d);
                                try regs.put(dest_name, Val{ .integer = 0 });
                            }
                        }
                    } else {
                        // Check if it is a user-defined function in our program
                        if (self.program.functions.get(func_name)) |target_func| {
                            const ret = try self.executeFunction(&target_func, args.items);
                            if (inst.dest) |d| {
                                const dest_name = try self.allocator.dupe(u8, d);
                                try regs.put(dest_name, Val{ .integer = ret });
                            }
                        } else if (self.ffi.resolveSymbol(func_name)) |sym| {
                            const f = @as(ffi.FfiFn, @ptrCast(sym));
                            var pad_args = [_]usize{0} ** 9;
                            for (args.items, 0..) |arg, arg_idx| {
                                if (arg_idx < 9) pad_args[arg_idx] = arg;
                            }
                            const ret = f(pad_args[0], pad_args[1], pad_args[2], pad_args[3], pad_args[4], pad_args[5], pad_args[6], pad_args[7], pad_args[8]);
                            if (inst.dest) |d| {
                                const dest_name = try self.allocator.dupe(u8, d);
                                try regs.put(dest_name, Val{ .integer = ret });
                            }
                        } else {
                            std.debug.print("Symbol not found: {s}\n", .{func_name});
                            return error.SymbolNotFound;
                        }
                    }
                    pc += 1;
                },
                .call_indirect => {
                    const func_ptr = try self.resolveVal(&regs, inst.args[0]);
                    var args = std.ArrayList(usize).init(self.allocator);
                    defer args.deinit();
                    for (inst.args[1..]) |arg| {
                        const val = try self.resolveVal(&regs, arg);
                        try args.append(val);
                    }

                    if (self.function_addresses.get(func_ptr)) |func_name| {
                        if (self.program.functions.get(func_name)) |target_func| {
                            const ret = try self.executeFunction(&target_func, args.items);
                            if (inst.dest) |d| {
                                const dest_name = try self.allocator.dupe(u8, d);
                                try regs.put(dest_name, Val{ .integer = ret });
                            }
                        } else {
                            std.debug.print("Indirect target function not found: {s}\n", .{func_name});
                            return error.SymbolNotFound;
                        }
                    } else {
                        // Handle native FFI pointer call
                        const f = @as(ffi.FfiFn, @ptrFromInt(func_ptr));
                        var pad_args = [_]usize{0} ** 9;
                        for (args.items, 0..) |arg, arg_idx| {
                            if (arg_idx < 9) pad_args[arg_idx] = arg;
                        }
                        const ret = f(pad_args[0], pad_args[1], pad_args[2], pad_args[3], pad_args[4], pad_args[5], pad_args[6], pad_args[7], pad_args[8]);
                        if (inst.dest) |d| {
                            const dest_name = try self.allocator.dupe(u8, d);
                            try regs.put(dest_name, Val{ .integer = ret });
                        }
                    }
                    pc += 1;
                },
                .load, .atomic_load => {
                    const addr = try self.resolveVal(&regs, inst.args[0]);
                    const val: u64 = switch (inst.dest_type) {
                        .ptr, .i64, .u64 => @as(*const u64, @ptrFromInt(addr)).*,
                        // Signed types must be sign-extended so that negative values
                        // remain negative when stored as u64 (bitcasted to i64 later)
                        .i32 => @as(u64, @bitCast(@as(i64, @as(*const i32, @ptrFromInt(addr)).*) )),
                        .u32 => @as(u64, @intCast(@as(*const u32, @ptrFromInt(addr)).*)),
                        .i16 => @as(u64, @bitCast(@as(i64, @as(*const i16, @ptrFromInt(addr)).*) )),
                        .u16 => @as(u64, @intCast(@as(*const u16, @ptrFromInt(addr)).*)),
                        .i8  => @as(u64, @bitCast(@as(i64, @as(*const i8,  @ptrFromInt(addr)).*) )),
                        .u8  => @as(u64, @intCast(@as(*const u8, @ptrFromInt(addr)).*)),
                        .f64 => @bitCast(@as(*const f64, @ptrFromInt(addr)).*),
                        .f32 => @as(u64, @intCast(@as(u32, @bitCast(@as(*const f32, @ptrFromInt(addr)).*)))),
                        else => return error.UnsupportedLoadType,
                    };
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    try regs.put(dest_name, Val{ .integer = val });
                    pc += 1;
                },
                .store, .atomic_store => {
                    const val = try self.resolveVal(&regs, inst.args[0]);
                    const addr = try self.resolveVal(&regs, inst.args[1]);
                    switch (inst.dest_type) {
                        .ptr, .i64, .u64 => @as(*u64, @ptrFromInt(addr)).* = val,
                        .i32, .u32 => @as(*u32, @ptrFromInt(addr)).* = @as(u32, @intCast(val & 0xffffffff)),
                        .i16, .u16 => @as(*u16, @ptrFromInt(addr)).* = @as(u16, @intCast(val & 0xffff)),
                        .i8, .u8 => @as(*u8, @ptrFromInt(addr)).* = @as(u8, @intCast(val & 0xff)),
                        else => @as(*u64, @ptrFromInt(addr)).* = val,
                    }
                    pc += 1;
                },
                .cmpxchg => {
                    const addr = try self.resolveVal(&regs, inst.args[0]);
                    const expected = try self.resolveVal(&regs, inst.args[1]);
                    const new_val = try self.resolveVal(&regs, inst.args[2]);

                    const old_val: u64 = switch (inst.dest_type) {
                        .ptr, .i64, .u64 => block: {
                            const ptr = @as(*u64, @ptrFromInt(addr));
                            break :block @cmpxchgStrong(u64, ptr, expected, new_val, .seq_cst, .seq_cst) orelse expected;
                        },
                        .i32, .u32 => block: {
                            const ptr = @as(*u32, @ptrFromInt(addr));
                            break :block @cmpxchgStrong(u32, ptr, @as(u32, @intCast(expected)), @as(u32, @intCast(new_val)), .seq_cst, .seq_cst) orelse @as(u32, @intCast(expected));
                        },
                        .i16, .u16 => block: {
                            const ptr = @as(*u16, @ptrFromInt(addr));
                            break :block @cmpxchgStrong(u16, ptr, @as(u16, @intCast(expected)), @as(u16, @intCast(new_val)), .seq_cst, .seq_cst) orelse @as(u16, @intCast(expected));
                        },
                        .i8, .u8 => block: {
                            const ptr = @as(*u8, @ptrFromInt(addr));
                            break :block @cmpxchgStrong(u8, ptr, @as(u8, @intCast(expected)), @as(u8, @intCast(new_val)), .seq_cst, .seq_cst) orelse @as(u8, @intCast(expected));
                        },
                        else => return error.UnsupportedCmpxchgType,
                    };

                    const success: u64 = if (old_val == expected) 1 else 0;

                    if (inst.dest) |d| {
                        if (std.mem.indexOf(u8, d, ",")) |comma_idx| {
                            const old_name = std.mem.trim(u8, d[0..comma_idx], " \t");
                            const ok_name = std.mem.trim(u8, d[comma_idx + 1 ..], " \t");
                            
                            const old_dupe = try self.allocator.dupe(u8, old_name);
                            try regs.put(old_dupe, Val{ .integer = old_val });
                            
                            const ok_dupe = try self.allocator.dupe(u8, ok_name);
                            try regs.put(ok_dupe, Val{ .integer = success });
                        } else {
                            const dest_dupe = try self.allocator.dupe(u8, d);
                            try regs.put(dest_dupe, Val{ .integer = old_val });
                        }
                    }
                    pc += 1;
                },
                .atomic_rmw_add => {
                    const addr = try self.resolveVal(&regs, inst.args[0]);
                    const value = try self.resolveVal(&regs, inst.args[1]);

                    const old_val: u64 = switch (inst.dest_type) {
                        .ptr, .i64, .u64 => block: {
                            const ptr = @as(*u64, @ptrFromInt(addr));
                            break :block @atomicRmw(u64, ptr, .Add, value, .seq_cst);
                        },
                        .i32, .u32 => block: {
                            const ptr = @as(*u32, @ptrFromInt(addr));
                            break :block @atomicRmw(u32, ptr, .Add, @as(u32, @intCast(value)), .seq_cst);
                        },
                        .i16, .u16 => block: {
                            const ptr = @as(*u16, @ptrFromInt(addr));
                            break :block @atomicRmw(u16, ptr, .Add, @as(u16, @intCast(value)), .seq_cst);
                        },
                        .i8, .u8 => block: {
                            const ptr = @as(*u8, @ptrFromInt(addr));
                            break :block @atomicRmw(u8, ptr, .Add, @as(u8, @intCast(value)), .seq_cst);
                        },
                        else => return error.UnsupportedAtomicRmwType,
                    };

                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    try regs.put(dest_name, Val{ .integer = old_val });
                    pc += 1;
                },
                .eq => {
                    const val1 = try self.resolveVal(&regs, inst.args[0]);
                    const val2 = try self.resolveVal(&regs, inst.args[1]);
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    try regs.put(dest_name, Val{ .integer = if (val1 == val2) 1 else 0 });
                    pc += 1;
                },
                .ne => {
                    const val1 = try self.resolveVal(&regs, inst.args[0]);
                    const val2 = try self.resolveVal(&regs, inst.args[1]);
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    try regs.put(dest_name, Val{ .integer = if (val1 != val2) 1 else 0 });
                    pc += 1;
                },
                .sgt, .ugt, .gt => {
                    const val1 = try self.resolveVal(&regs, inst.args[0]);
                    const val2 = try self.resolveVal(&regs, inst.args[1]);
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    const is_true = if (inst.op == .sgt or inst.op == .gt) @as(i64, @bitCast(val1)) > @as(i64, @bitCast(val2)) else val1 > val2;
                    try regs.put(dest_name, Val{ .integer = if (is_true) 1 else 0 });
                    pc += 1;
                },
                .slt, .ult, .lt => {
                    const val1 = try self.resolveVal(&regs, inst.args[0]);
                    const val2 = try self.resolveVal(&regs, inst.args[1]);
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    const is_true = if (inst.op == .slt or inst.op == .lt) @as(i64, @bitCast(val1)) < @as(i64, @bitCast(val2)) else val1 < val2;
                    try regs.put(dest_name, Val{ .integer = if (is_true) 1 else 0 });
                    pc += 1;
                },
                .sge, .uge => {
                    const val1 = try self.resolveVal(&regs, inst.args[0]);
                    const val2 = try self.resolveVal(&regs, inst.args[1]);
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    const is_true = if (inst.op == .sge) @as(i64, @bitCast(val1)) >= @as(i64, @bitCast(val2)) else val1 >= val2;
                    try regs.put(dest_name, Val{ .integer = if (is_true) 1 else 0 });
                    pc += 1;
                },
                .sle, .ule => {
                    const val1 = try self.resolveVal(&regs, inst.args[0]);
                    const val2 = try self.resolveVal(&regs, inst.args[1]);
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    const is_true = if (inst.op == .sle) @as(i64, @bitCast(val1)) <= @as(i64, @bitCast(val2)) else val1 <= val2;
                    try regs.put(dest_name, Val{ .integer = if (is_true) 1 else 0 });
                    pc += 1;
                },
                .br => {
                    const cond = try self.resolveVal(&regs, inst.args[0]);
                    const dest_label = if (cond != 0) inst.args[1].name else inst.args[2].name;
                    pc = try self.findBlockInstructionIndex(func, dest_label);
                },
                .jmp => {
                    const dest_label = inst.args[0].name;
                    pc = try self.findBlockInstructionIndex(func, dest_label);
                },
                .consume => {
                    pc += 1;
                },
                .assign => {
                    const val = try self.resolveVal(&regs, inst.args[0]);
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    try regs.put(dest_name, Val{ .integer = val });
                    pc += 1;
                },
                .assume_safe => {
                    const val = try self.resolveVal(&regs, inst.args[0]);
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    try regs.put(dest_name, Val{ .integer = val });
                    pc += 1;
                },
                .raw_cast => {
                    const val = try self.resolveVal(&regs, inst.args[0]);
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    try regs.put(dest_name, Val{ .integer = val });
                    pc += 1;
                },
                .take => {
                    const addr = try self.resolveVal(&regs, inst.args[0]);
                    const ptr = @as(*usize, @ptrFromInt(addr));
                    const val = ptr.*;
                    ptr.* = 0;
                    const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                    try regs.put(dest_name, Val{ .integer = val });
                    pc += 1;
                },
                .try_ => {
                    const res_addr = try self.resolveVal(&regs, inst.args[0]);
                    const tag = @as(*const u64, @ptrFromInt(res_addr)).*;
                    if (tag != 0) {
                        return tag;
                    } else {
                        const ok_val = @as(*const u64, @ptrFromInt(res_addr + 8)).*;
                        const dest_name = try self.allocator.dupe(u8, inst.dest.?);
                        try regs.put(dest_name, Val{ .integer = ok_val });
                    }
                    pc += 1;
                },
                .panic => {
                    const code = try self.resolveVal(&regs, inst.args[0]);
                    std.debug.print("PANIC: code {d}\n", .{code});
                    return error.Panic;
                },
                .panic_msg => {
                    const code = try self.resolveVal(&regs, inst.args[0]);
                    const msg_ptr = try self.resolveVal(&regs, inst.args[1]);
                    const msg_len = try self.resolveVal(&regs, inst.args[2]);
                    const slice = @as([*]const u8, @ptrFromInt(msg_ptr))[0..msg_len];
                    std.debug.print("PANIC: code {d}, message: {s}\n", .{code, slice});
                    return error.Panic;
                },
                .return_ => {
                    var ret_val: usize = 0;
                    if (inst.args.len > 0) {
                        ret_val = try self.resolveVal(&regs, inst.args[0]);
                    }
                    if (func.returns_result and !std.mem.eql(u8, func.name, "main")) {
                        const buf = try self.allocator.alloc(u64, 3);
                        const bytes = std.mem.sliceAsBytes(buf);
                        @memset(bytes, 0);
                        @as(*u64, @ptrFromInt(@intFromPtr(bytes.ptr))).* = 0; // Result_tag = 0 (OK)
                        @as(*u64, @ptrFromInt(@intFromPtr(bytes.ptr) + 8)).* = ret_val; // Result_ok = ret_val
                        @as(*u64, @ptrFromInt(@intFromPtr(bytes.ptr) + 16)).* = 0; // Result_err = 0
                        return @intFromPtr(bytes.ptr);
                    }
                    return ret_val;
                },
            }
        }

        return 0;
    }

    fn resolveVal(self: *VM, regs: *const std.StringHashMap(Val), arg: parser.Operand) !usize {
        switch (arg.kind) {
            .immediate => return @as(usize, @intCast(arg.imm_val)),
            .constant_addr => {
                if (self.program.constants.get(arg.name)) |val| {
                    return @intFromPtr(val.ptr);
                }
                std.debug.print("Constant not found: {s}\n", .{arg.name});
                return error.ConstantNotFound;
            },
            .stack_addr => {
                if (regs.get(arg.name)) |val| {
                    return switch (val) {
                        .pointer => |p| p,
                        .integer => |i| @as(usize, @intCast(i)),
                        else => error.InvalidStackAddress,
                    };
                }
                std.debug.print("Stack variable not found: {s}\n", .{arg.name});
                return error.VariableNotFound;
            },
            .offset_addr => {
                if (regs.get(arg.name)) |val| {
                    const base = switch (val) {
                        .pointer => |p| p,
                        .integer => |i| @as(usize, @intCast(i)),
                        else => return error.InvalidBaseAddress,
                    };
                    const offset_addr = @as(isize, @intCast(base)) + arg.offset;
                    return @as(usize, @bitCast(offset_addr));
                }
                std.debug.print("Base variable for offset not found: '{s}'\n", .{arg.name});
                return error.VariableNotFound;
            },
            .register => {
                if (regs.get(arg.name)) |val| {
                    return switch (val) {
                        .integer => |i| @as(usize, @intCast(i)),
                        .pointer => |p| p,
                        .float => |f| @bitCast(f),
                        else => 0,
                    };
                }
                if (self.program.constants.get(arg.name)) |val| {
                    return val.len;
                }
                std.debug.print("Register not found: '{s}' (kind: {s})\n", .{ arg.name, @tagName(arg.kind) });
                return error.RegisterNotFound;
            },
            .label => return error.LabelAsValueUnsupported,
        }
    }

    const TimeDate = extern struct {
        unix_ms: i64,
        unix_ns: i64,
        year: u16,
        month: u8,
        day: u8,
        hour: u8,
        minute: u8,
        second: u8,
        millisecond: u16,
    };

    fn writeUtcNow(self: *VM, ptr: usize) !void {
        _ = self;
        const unix_ms = std.time.milliTimestamp();
        const unix_ns = std.time.nanoTimestamp();
        const unix_s = @divFloor(unix_ms, std.time.ms_per_s);
        
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(unix_s)) };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();

        const td = TimeDate{
            .unix_ms = unix_ms,
            .unix_ns = @as(i64, @intCast(unix_ns)),
            .year = year_day.year,
            .month = @intFromEnum(month_day.month),
            .day = month_day.day_index + 1,
            .hour = day_seconds.getHoursIntoDay(),
            .minute = day_seconds.getMinutesIntoHour(),
            .second = day_seconds.getSecondsIntoMinute(),
            .millisecond = @as(u16, @intCast(@mod(unix_ms, std.time.ms_per_s))),
        };

        const out = @as(*TimeDate, @ptrFromInt(ptr));
        out.* = td;
    }

    fn findBlockInstructionIndex(self: *VM, func: *const parser.Function, label: []const u8) !usize {
        _ = self;
        for (func.blocks) |block| {
            if (std.mem.eql(u8, block.label, label)) {
                return block.start_inst;
            }
        }
        std.debug.print("Label block not found: {s}\n", .{label});
        return error.LabelNotFound;
    }
};
