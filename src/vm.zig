const std = @import("std");
const parser = @import("parser.zig");
const ffi = @import("ffi.zig");

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
                    if (std.mem.startsWith(u8, target_func_name, "@")) target_func_name = target_func_name[1..];
                    const func_ptr = if (self.function_names.get(target_func_name)) |ptr| ptr else if (self.ffi.resolveSymbol(target_func_name)) |sym| @intFromPtr(sym) else {
                        std.debug.print("VTable method target function not found: {s}\n", .{target_func_name});
                        return error.SymbolNotFound;
                    };
                    try methods_list.append(func_ptr);
                }
                const vtable_mem = try self.allocator.alloc(usize, methods_list.items.len);
                @memcpy(vtable_mem, methods_list.items);
                methods_list.deinit();
                self.allocator.free(val_str);
                entry.value_ptr.* = std.mem.sliceAsBytes(vtable_mem);
            }
        }
    }

    const Frame = struct {
        data: []u64,
        map: std.StringHashMap(usize),
        next_idx: usize = 0,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) !Frame {
            return .{
                .data = try allocator.alloc(u64, 1024),
                .map = std.StringHashMap(usize).init(allocator),
                .allocator = allocator,
            };
        }

        fn deinit(self: *Frame) void {
            var it = self.map.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            self.map.deinit();
            self.allocator.free(self.data);
        }

        fn getRegPtr(self: *Frame, name: []const u8) !*u64 {
            if (self.map.get(name)) |idx| return &self.data[idx];
            const idx = self.next_idx;
            self.next_idx += 8; // 64 bytes per register to allow struct overlays
            if (self.next_idx > self.data.len) return error.StackOverflow;
            try self.map.put(try self.allocator.dupe(u8, name), idx);
            return &self.data[idx];
        }
    };

    fn resolveVal(self: *VM, frame: *Frame, arg: parser.Operand) !usize {
        switch (arg.kind) {
            .immediate => return @as(usize, @intCast(arg.imm_val)),
            .constant_addr => {
                if (self.program.constants.get(arg.name)) |val| return @intFromPtr(val.ptr);
                std.debug.print("Constant not found: {s}\n", .{arg.name});
                return error.ConstantNotFound;
            },
            .stack_addr, .register => {
                const storage = try frame.getRegPtr(arg.name);
                return @as(usize, @intCast(storage.*));
            },
            .offset_addr => {
                const storage = try frame.getRegPtr(arg.name);
                const base = @as(usize, @intCast(storage.*));
                const offset_addr = @as(isize, @intCast(base)) + arg.offset;
                return @as(usize, @bitCast(offset_addr));
            },
            .label => return error.LabelAsValueUnsupported,
        }
    }

    fn executeFunction(self: *VM, func: *const parser.Function, call_args: []const usize) anyerror!usize {
        var frame = try Frame.init(self.allocator);
        defer frame.deinit();

        for (func.params, call_args) |param_name, arg_val| {
            const storage = try frame.getRegPtr(param_name);
            storage.* = arg_val;
        }

        var stack_allocs = std.ArrayList([]u64).init(self.allocator);
        defer {
            for (stack_allocs.items) |buf| self.allocator.free(buf);
            stack_allocs.deinit();
        }

        var pc: usize = 0;
        while (pc < func.instructions.len) {
            const inst = func.instructions[pc];
            switch (inst.op) {
                .stack_alloc, .alloc => {
                    const size = try self.resolveVal(&frame, inst.args[0]);
                    const word_count = (size + 7) / 8;
                    const buf = try self.allocator.alloc(u64, @max(1, word_count));
                    @memset(std.mem.sliceAsBytes(buf), 0);
                    try stack_allocs.append(buf);
                    const storage = try frame.getRegPtr(inst.dest.?);
                    storage.* = @intFromPtr(buf.ptr);
                    pc += 1;
                },
                .ptr_add => {
                    const ptr_val = try self.resolveVal(&frame, inst.args[0]);
                    const offset_val = try self.resolveVal(&frame, inst.args[1]);
                    const storage = try frame.getRegPtr(inst.dest.?);
                    storage.* = ptr_val +% offset_val;
                    pc += 1;
                },
                .add, .sub, .mul, .div, .rem, .sdiv, .udiv, .srem, .urem, .shl, .shr => {
                    const arg1 = try self.resolveVal(&frame, inst.args[0]);
                    const arg2 = try self.resolveVal(&frame, inst.args[1]);
                    const result = switch (inst.op) {
                        .add => arg1 +% arg2,
                        .sub => arg1 -% arg2,
                        .mul => arg1 *% arg2,
                        .div, .udiv => if (arg2 != 0) arg1 / arg2 else 0,
                        .sdiv => sdiv: {
                            const s1 = @as(i64, @bitCast(arg1));
                            const s2 = @as(i64, @bitCast(arg2));
                            break :sdiv @as(u64, @bitCast(if (s2 != 0) @divTrunc(s1, s2) else @as(i64, 0)));
                        },
                        .srem => srem: {
                            const s1 = @as(i64, @bitCast(arg1));
                            const s2 = @as(i64, @bitCast(arg2));
                            break :srem @as(u64, @bitCast(if (s2 != 0) @rem(s1, s2) else @as(i64, 0)));
                        },
                        .urem, .rem => if (arg2 != 0) arg1 % arg2 else 0,
                        .shl => arg1 << @intCast(arg2 & 63),
                        .shr => arg1 >> @intCast(arg2 & 63),
                        else => unreachable,
                    };
                    const storage = try frame.getRegPtr(inst.dest.?);
                    storage.* = result;
                    pc += 1;
                },
                .and_, .or_, .xor_ => {
                    const arg1 = try self.resolveVal(&frame, inst.args[0]);
                    const arg2 = try self.resolveVal(&frame, inst.args[1]);
                    const result = switch (inst.op) {
                        .and_ => arg1 & arg2,
                        .or_ => arg1 | arg2,
                        .xor_ => arg1 ^ arg2,
                        else => unreachable,
                    };
                    const storage = try frame.getRegPtr(inst.dest.?);
                    storage.* = result;
                    pc += 1;
                },
                .call => {
                    const func_name = inst.args[0].name;
                    var args = std.ArrayList(usize).init(self.allocator);
                    defer args.deinit();
                    for (inst.args[1..]) |arg| try args.append(try self.resolveVal(&frame, arg));
                    if (std.mem.eql(u8, func_name, "sa_print_bytes")) {
                        const slice = @as([*]const u8, @ptrFromInt(args.items[0]))[0..args.items[1]];
                        _ = std.posix.write(std.posix.STDOUT_FILENO, slice) catch {};
                        if (inst.dest) |d| (try frame.getRegPtr(d)).* = 0;
                    } else if (std.mem.eql(u8, func_name, "sa_time_unix_ms")) {
                        if (inst.dest) |d| (try frame.getRegPtr(d)).* = @as(u64, @bitCast(std.time.milliTimestamp()));
                    } else if (self.program.functions.get(func_name)) |target_func| {
                        const ret = try self.executeFunction(&target_func, args.items);
                        if (inst.dest) |d| (try frame.getRegPtr(d)).* = ret;
                    } else if (self.ffi.resolveSymbol(func_name)) |sym| {
                        const f = @as(ffi.FfiFn, @ptrCast(sym));
                        var pad = [_]usize{0} ** 9;
                        for (args.items, 0..) |arg, i| if (i < 9) { pad[i] = arg; };
                        const ret = f(pad[0], pad[1], pad[2], pad[3], pad[4], pad[5], pad[6], pad[7], pad[8]);
                        if (inst.dest) |d| (try frame.getRegPtr(d)).* = ret;
                    } else {
                        std.debug.print("Symbol not found: {s}\n", .{func_name});
                        return error.SymbolNotFound;
                    }
                    pc += 1;
                },
                .call_indirect => {
                    const ptr = try self.resolveVal(&frame, inst.args[0]);
                    var args = std.ArrayList(usize).init(self.allocator);
                    defer args.deinit();
                    for (inst.args[1..]) |arg| try args.append(try self.resolveVal(&frame, arg));
                    if (self.function_addresses.get(ptr)) |name| {
                        const ret = try self.executeFunction(&self.program.functions.get(name).?, args.items);
                        if (inst.dest) |d| (try frame.getRegPtr(d)).* = ret;
                    } else {
                        const f = @as(ffi.FfiFn, @ptrFromInt(ptr));
                        var pad = [_]usize{0} ** 9;
                        for (args.items, 0..) |arg, i| if (i < 9) { pad[i] = arg; };
                        const ret = f(pad[0], pad[1], pad[2], pad[3], pad[4], pad[5], pad[6], pad[7], pad[8]);
                        if (inst.dest) |d| (try frame.getRegPtr(d)).* = ret;
                    }
                    pc += 1;
                },
                .load, .atomic_load => {
                    const addr = try self.resolveVal(&frame, inst.args[0]);
                    const val: u64 = switch (inst.dest_type) {
                        .ptr, .i64, .u64 => @as(*align(1) const u64, @ptrFromInt(addr)).*,
                        .i32 => @as(u64, @bitCast(@as(i64, @as(*align(1) const i32, @ptrFromInt(addr)).*))),
                        .u32 => @as(u64, @intCast(@as(*align(1) const u32, @ptrFromInt(addr)).*)),
                        .i16 => @as(u64, @bitCast(@as(i64, @as(*align(1) const i16, @ptrFromInt(addr)).*))),
                        .u16 => @as(u64, @intCast(@as(*align(1) const u16, @ptrFromInt(addr)).*)),
                        .i8 => @as(u64, @bitCast(@as(i64, @as(*align(1) const i8, @ptrFromInt(addr)).*))),
                        .u8 => @as(u64, @intCast(@as(*align(1) const u8, @ptrFromInt(addr)).*)),
                        .f64 => @bitCast(@as(*align(1) const f64, @ptrFromInt(addr)).*),
                        .f32 => @as(u64, @intCast(@as(u32, @bitCast(@as(*align(1) const f32, @ptrFromInt(addr)).*)))),
                        else => return error.UnsupportedLoadType,
                    };
                    (try frame.getRegPtr(inst.dest.?)).* = val;
                    pc += 1;
                },
                .store, .atomic_store => {
                    const val = try self.resolveVal(&frame, inst.args[0]);
                    const addr = try self.resolveVal(&frame, inst.args[1]);
                    switch (inst.dest_type) {
                        .ptr, .i64, .u64 => @as(*align(1) u64, @ptrFromInt(addr)).* = val,
                        .i32, .u32 => @as(*align(1) u32, @ptrFromInt(addr)).* = @as(u32, @intCast(val & 0xffffffff)),
                        .i16, .u16 => @as(*align(1) u16, @ptrFromInt(addr)).* = @as(u16, @intCast(val & 0xffff)),
                        .i8, .u8 => @as(*align(1) u8, @ptrFromInt(addr)).* = @as(u8, @intCast(val & 0xff)),
                        else => @as(*align(1) u64, @ptrFromInt(addr)).* = val,
                    }
                    pc += 1;
                },
                .cmpxchg => {
                    const addr = try self.resolveVal(&frame, inst.args[0]);
                    const expected = try self.resolveVal(&frame, inst.args[1]);
                    const new_val = try self.resolveVal(&frame, inst.args[2]);
                    const old_val: u64 = switch (inst.dest_type) {
                        .ptr, .i64, .u64 => @cmpxchgStrong(u64, @as(*u64, @ptrFromInt(addr)), expected, new_val, .seq_cst, .seq_cst) orelse expected,
                        .i32, .u32 => @cmpxchgStrong(u32, @as(*u32, @ptrFromInt(addr)), @as(u32, @intCast(expected & 0xffffffff)), @as(u32, @intCast(new_val & 0xffffffff)), .seq_cst, .seq_cst) orelse @as(u32, @intCast(expected & 0xffffffff)),
                        .i16, .u16 => @cmpxchgStrong(u16, @as(*u16, @ptrFromInt(addr)), @as(u16, @intCast(expected & 0xffff)), @as(u16, @intCast(new_val & 0xffff)), .seq_cst, .seq_cst) orelse @as(u16, @intCast(expected & 0xffff)),
                        .i8, .u8 => @cmpxchgStrong(u8, @as(*u8, @ptrFromInt(addr)), @as(u8, @intCast(expected & 0xff)), @as(u8, @intCast(new_val & 0xff)), .seq_cst, .seq_cst) orelse @as(u8, @intCast(expected & 0xff)),
                        else => return error.UnsupportedCmpxchgType,
                    };
                    if (inst.dest) |d| {
                        if (std.mem.indexOf(u8, d, ",")) |comma| {
                            (try frame.getRegPtr(std.mem.trim(u8, d[0..comma], " \t"))).* = old_val;
                            (try frame.getRegPtr(std.mem.trim(u8, d[comma+1..], " \t"))).* = if (old_val == expected) 1 else 0;
                        } else (try frame.getRegPtr(d)).* = old_val;
                    }
                    pc += 1;
                },
                .atomic_rmw_add => {
                    const addr = try self.resolveVal(&frame, inst.args[0]);
                    const val = try self.resolveVal(&frame, inst.args[1]);
                    const old_val: u64 = switch (inst.dest_type) {
                        .ptr, .i64, .u64 => @atomicRmw(u64, @as(*u64, @ptrFromInt(addr)), .Add, val, .seq_cst),
                        .i32, .u32 => @atomicRmw(u32, @as(*u32, @ptrFromInt(addr)), .Add, @as(u32, @intCast(val & 0xffffffff)), .seq_cst),
                        .i16, .u16 => @atomicRmw(u16, @as(*u16, @ptrFromInt(addr)), .Add, @as(u16, @intCast(val & 0xffff)), .seq_cst),
                        .i8, .u8 => @atomicRmw(u8, @as(*u8, @ptrFromInt(addr)), .Add, @as(u8, @intCast(val & 0xff)), .seq_cst),
                        else => return error.UnsupportedAtomicRmwType,
                    };
                    if (inst.dest) |d| {
                        (try frame.getRegPtr(d)).* = old_val;
                    }
                    pc += 1;
                },
                .eq, .ne, .sgt, .ugt, .gt, .slt, .ult, .lt, .sge, .uge, .sle, .ule => {
                    const v1 = try self.resolveVal(&frame, inst.args[0]);
                    const v2 = try self.resolveVal(&frame, inst.args[1]);
                    const is_true = switch (inst.op) {
                        .eq => v1 == v2, .ne => v1 != v2,
                        .sgt, .gt => @as(i64, @bitCast(v1)) > @as(i64, @bitCast(v2)), .ugt => v1 > v2,
                        .slt, .lt => @as(i64, @bitCast(v1)) < @as(i64, @bitCast(v2)), .ult => v1 < v2,
                        .sge => @as(i64, @bitCast(v1)) >= @as(i64, @bitCast(v2)), .uge => v1 >= v2,
                        .sle => @as(i64, @bitCast(v1)) <= @as(i64, @bitCast(v2)), .ule => v1 <= v2,
                        else => unreachable,
                    };
                    (try frame.getRegPtr(inst.dest.?)).* = if (is_true) 1 else 0;
                    pc += 1;
                },
                .br => pc = try self.findBlockInstructionIndex(func, if ((try self.resolveVal(&frame, inst.args[0])) != 0) inst.args[1].name else inst.args[2].name),
                .jmp => pc = try self.findBlockInstructionIndex(func, inst.args[0].name),
                .assign, .assume_safe, .assume_borrow, .raw_cast => {
                    (try frame.getRegPtr(inst.dest.?)).* = try self.resolveVal(&frame, inst.args[0]);
                    pc += 1;
                },
                .take => {
                    const ptr = @as(*align(1) usize, @ptrFromInt(try self.resolveVal(&frame, inst.args[0])));
                    (try frame.getRegPtr(inst.dest.?)).* = ptr.*;
                    ptr.* = 0;
                    pc += 1;
                },
                .try_ => {
                    const addr = try self.resolveVal(&frame, inst.args[0]);
                    const tag = @as(*align(1) const u64, @ptrFromInt(addr)).*;
                    if (tag != 0) return tag;
                    (try frame.getRegPtr(inst.dest.?)).* = @as(*align(1) const u64, @ptrFromInt(addr + 8)).*;
                    pc += 1;
                },
                .panic, .panic_msg => return error.Panic,
                .consume => pc += 1,
                .return_ => {
                    const ret = if (inst.args.len > 0) try self.resolveVal(&frame, inst.args[0]) else 0;
                    if (func.returns_result and !std.mem.eql(u8, func.name, "main")) {
                        const buf = try self.allocator.alloc(u64, 3);
                        buf[0] = 0; buf[1] = ret; buf[2] = 0;
                        return @intFromPtr(buf.ptr);
                    }
                    return ret;
                },
            }
        }
        return 0;
    }

    fn findBlockInstructionIndex(self: *VM, func: *const parser.Function, label: []const u8) !usize {
        _ = self;
        for (func.blocks) |block| if (std.mem.eql(u8, block.label, label)) return block.start_inst;
        return error.LabelNotFound;
    }
};
