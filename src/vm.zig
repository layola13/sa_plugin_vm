const std = @import("std");
const parser = @import("parser.zig");
const ffi = @import("ffi.zig");

/// Sentinel value indicating an unresolved register slot.
const INVALID_SLOT: u32 = std.math.maxInt(u32);
const CALL_CACHE_MAX_ARGS: usize = 4;

/// Pre-resolved dispatch target for a .call instruction, computed during the binding pass.
const ResolvedCall = union(enum) {
    builtin_print,
    builtin_time_ms,
    builtin_time_s,
    builtin_time_ns,
    builtin_time_instant_ns,
    interpreted: *const parser.Function,
    ffi_typed: struct { sym: *anyopaque, sig: parser.ExternSignature },
    ffi_legacy: *anyopaque,
    pthread_spawn,
    pthread_spawn_detached,
    pthread_join,
    pthread_drop,
    unresolved,
};

const CallCacheKey = struct {
    func_ptr: usize,
    memory_epoch: u64,
    argc: u8,
    args: [CALL_CACHE_MAX_ARGS]usize,
};

pub const VM = struct {
    program: *parser.Program,
    allocator: std.mem.Allocator,
    ffi: *ffi.FfiManager,
    function_addresses: std.AutoHashMap(usize, *const parser.Function),
    function_names: std.StringHashMap(usize),
    function_ptrs: std.StringHashMap(*const parser.Function),
    label_targets: std.StringHashMap(std.StringHashMap(usize)),
    function_registers: std.StringHashMap(std.StringHashMap(usize)),
    /// Number of register slots per function (populated by binding pass).
    function_slot_counts: std.StringHashMap(usize),
    /// Whether a function needs a per-call arena for stack_alloc instructions.
    function_needs_arena: std.StringHashMap(bool),
    /// Whether an interpreted function is safe to memoize for identical args and memory epoch.
    function_cacheable: std.StringHashMap(bool),
    /// Pre-resolved call targets per function, parallel to instruction array.
    function_call_targets: std.StringHashMap([]ResolvedCall),
    call_cache: std.AutoHashMap(CallCacheKey, usize),
    memory_epoch: u64,
    frame_pool: std.ArrayList([]u64),
    dummy_buffers: std.ArrayList(*u8),
    heap_allocs: std.ArrayList([]u64),
    result_allocs: std.ArrayList([]u64),
    result_alloc_index: std.AutoHashMap(usize, usize),
    panic_code: ?u8 = null,
    panic_message: ?[]u8 = null,
    thread_results: std.AutoHashMap(i32, usize),
    next_thread_handle: i32,
    run_arena: ?std.heap.ArenaAllocator = null,

    pub fn init(allocator: std.mem.Allocator, program: *parser.Program, ffi_mgr: *ffi.FfiManager) VM {
        return .{
            .allocator = allocator,
            .program = program,
            .ffi = ffi_mgr,
            .function_addresses = std.AutoHashMap(usize, *const parser.Function).init(allocator),
            .function_names = std.StringHashMap(usize).init(allocator),
            .function_ptrs = std.StringHashMap(*const parser.Function).init(allocator),
            .label_targets = std.StringHashMap(std.StringHashMap(usize)).init(allocator),
            .function_registers = std.StringHashMap(std.StringHashMap(usize)).init(allocator),
            .function_slot_counts = std.StringHashMap(usize).init(allocator),
            .function_needs_arena = std.StringHashMap(bool).init(allocator),
            .function_cacheable = std.StringHashMap(bool).init(allocator),
            .function_call_targets = std.StringHashMap([]ResolvedCall).init(allocator),
            .call_cache = std.AutoHashMap(CallCacheKey, usize).init(allocator),
            .memory_epoch = 1,
            .frame_pool = std.ArrayList([]u64).init(allocator),
            .dummy_buffers = std.ArrayList(*u8).init(allocator),
            .heap_allocs = std.ArrayList([]u64).init(allocator),
            .result_allocs = std.ArrayList([]u64).init(allocator),
            .result_alloc_index = std.AutoHashMap(usize, usize).init(allocator),
            .panic_code = null,
            .panic_message = null,
            .thread_results = std.AutoHashMap(i32, usize).init(allocator),
            .next_thread_handle = 1,
        };
    }

    pub fn deinit(self: *VM) void {
        self.clearPanicState();
        var label_it = self.label_targets.iterator();
        while (label_it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.label_targets.deinit();
        self.function_addresses.deinit();
        self.function_names.deinit();
        self.function_ptrs.deinit();
        var reg_it = self.function_registers.iterator();
        while (reg_it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.function_registers.deinit();
        self.function_slot_counts.deinit();
        self.function_needs_arena.deinit();
        self.function_cacheable.deinit();
        var ct_it = self.function_call_targets.iterator();
        while (ct_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.function_call_targets.deinit();
        self.call_cache.deinit();
        for (self.frame_pool.items) |buf| {
            self.allocator.free(buf);
        }
        self.frame_pool.deinit();
        self.thread_results.deinit();
        for (self.dummy_buffers.items) |buf| {
            self.allocator.destroy(buf);
        }
        self.dummy_buffers.deinit();
        for (self.heap_allocs.items) |buf| {
            self.allocator.free(buf);
        }
        self.heap_allocs.deinit();
        for (self.result_allocs.items) |buf| {
            self.allocator.free(buf);
        }
        self.result_allocs.deinit();
        self.result_alloc_index.deinit();
    }

    fn clearPanicState(self: *VM) void {
        if (self.panic_message) |msg| {
            self.allocator.free(msg);
        }
        self.panic_message = null;
        self.panic_code = null;
    }

    pub fn run(self: *VM) !i32 {
        self.clearPanicState();
        try self.initFunctionsAndVtables();

        const main_func = self.program.functions.get("main") orelse {
            std.debug.print("Error: @main function not found!\n", .{});
            return 1;
        };
        const main_code = try self.executeFunction(&main_func, &.{});
        return @as(i32, @bitCast(@as(u32, @intCast(main_code & 0xffffffff))));
    }

    fn findBlockForPc(self: *VM, func: *const parser.Function, pc: usize) ?parser.BasicBlock {
        _ = self;
        for (func.blocks) |block| {
            if (pc >= block.start_inst and pc < block.end_inst) return block;
        }
        return null;
    }

    /// Determines at binding time whether the call at `pc` is a tail self-call.
    fn isTailSelfCallAt(self: *VM, func: *const parser.Function, pc: usize) bool {
        const block = self.findBlockForPc(func, pc) orelse return false;
        if (pc + 1 >= block.end_inst) return false;
        var idx = pc + 1;
        while (idx < block.end_inst) : (idx += 1) {
            const next = func.instructions[idx];
            if (next.op == .consume) continue;
            if (next.op == .return_) return idx == block.end_inst - 1;
            return false;
        }
        return false;
    }

    fn freeTrackedResultAlloc(self: *VM, ptr: usize) bool {
        const idx = self.result_alloc_index.get(ptr) orelse return false;
        const buf = self.result_allocs.items[idx];
        self.allocator.free(buf);
        const last_idx = self.result_allocs.items.len - 1;
        if (idx != last_idx) {
            const moved = self.result_allocs.items[last_idx];
            self.result_allocs.items[idx] = moved;
            self.result_alloc_index.put(@intFromPtr(moved.ptr), idx) catch {};
        }
        _ = self.result_alloc_index.remove(ptr);
        _ = self.result_allocs.pop();
        return true;
    }

    /// Resolve a named call target to its ResolvedCall variant at binding time.
    fn resolveCallTarget(self: *VM, call_name: []const u8) ResolvedCall {
        if (std.mem.eql(u8, call_name, "sa_print_bytes")) return .builtin_print;
        if (std.mem.eql(u8, call_name, "sa_time_unix_ms")) return .builtin_time_ms;
        if (std.mem.eql(u8, call_name, "sa_time_unix_s")) return .builtin_time_s;
        if (std.mem.eql(u8, call_name, "sa_time_unix_ns")) return .builtin_time_ns;
        if (std.mem.eql(u8, call_name, "sa_time_instant_ns")) return .builtin_time_instant_ns;
        if (std.mem.eql(u8, call_name, "pthread_spawn")) return .pthread_spawn;
        if (std.mem.eql(u8, call_name, "pthread_spawn_detached")) return .pthread_spawn_detached;
        if (std.mem.eql(u8, call_name, "pthread_join")) return .pthread_join;
        if (std.mem.eql(u8, call_name, "pthread_drop")) return .pthread_drop;
        if (self.function_ptrs.get(call_name)) |target_func| {
            return ResolvedCall{ .interpreted = target_func };
        }
        if (self.program.externs.getPtr(call_name)) |sig| {
            if (self.ffi.resolveSymbol(call_name)) |sym| {
                return ResolvedCall{ .ffi_typed = .{ .sym = sym, .sig = sig.* } };
            }
        }
        if (self.ffi.resolveSymbol(call_name)) |sym| {
            return ResolvedCall{ .ffi_legacy = sym };
        }
        return .unresolved;
    }

    fn functionHasOp(func: *const parser.Function, op: parser.OpCode) bool {
        for (func.instructions) |inst| {
            if (inst.op == op) return true;
        }
        return false;
    }

    fn functionHasExternalSideEffect(self: *VM, func: *const parser.Function) bool {
        _ = self;
        for (func.instructions) |inst| {
            switch (inst.op) {
                .alloc, .atomic_store, .cmpxchg, .atomic_rmw_add, .panic, .panic_msg, .try_ => return true,
                .store => if (!inst.is_local_stack_write) return true,
                .call => return true,
                .call_indirect => return true,
                else => {},
            }
        }
        return false;
    }

    /// Binding pass: resolve register slot indices, branch pc targets, and call
    /// targets for every instruction in every function. Runs once after init.
    fn bindingPass(self: *VM) !void {
        var func_it = self.program.functions.iterator();
        while (func_it.next()) |entry| {
            const func_name = entry.key_ptr.*;
            const func = entry.value_ptr;
            const reg_map = self.function_registers.get(func_name) orelse continue;
            try self.function_slot_counts.put(func_name, reg_map.count());
            try self.function_needs_arena.put(func_name, functionHasOp(func, .stack_alloc));
            var stack_alloc_slots = std.AutoHashMap(u32, void).init(self.allocator);
            defer stack_alloc_slots.deinit();

            const call_targets = try self.allocator.alloc(ResolvedCall, func.instructions.len);
            errdefer self.allocator.free(call_targets);
            for (call_targets) |*t| t.* = .unresolved;

            for (func.instructions, 0..) |*inst, pc| {
                // Resolve destination register slot(s).
                if (inst.dest) |dest_name| {
                    if (std.mem.indexOf(u8, dest_name, ",")) |comma_idx| {
                        const d1 = std.mem.trim(u8, dest_name[0..comma_idx], " \t");
                        const d2 = std.mem.trim(u8, dest_name[comma_idx + 1 ..], " \t");
                        inst.dest_slot = @intCast(reg_map.get(d1) orelse INVALID_SLOT);
                        inst.dest_slot2 = @intCast(reg_map.get(d2) orelse INVALID_SLOT);
                    } else {
                        inst.dest_slot = @intCast(reg_map.get(dest_name) orelse INVALID_SLOT);
                    }
                }
                if (inst.op == .stack_alloc and inst.dest_slot != INVALID_SLOT) {
                    try stack_alloc_slots.put(inst.dest_slot, {});
                }
                // Resolve operand slot indices and label pc targets.
                for (inst.args) |*arg| {
                    switch (arg.kind) {
                        .register, .stack_addr, .offset_addr => {
                            arg.slot_idx = @intCast(reg_map.get(arg.name) orelse INVALID_SLOT);
                        },
                        .constant_addr => {
                            if (self.program.constants.get(arg.name)) |val| {
                                arg.imm_val = @intFromPtr(val.ptr);
                            }
                        },
                        .label => {
                            if (self.label_targets.get(func_name)) |lmap| {
                                if (lmap.get(arg.name)) |tpc| arg.pc_target = tpc;
                            }
                        },
                        else => {},
                    }
                }
                if ((inst.op == .store or inst.op == .atomic_store) and inst.args.len >= 2) {
                    const addr_arg = inst.args[1];
                    if (addr_arg.kind == .offset_addr and addr_arg.slot_idx != INVALID_SLOT and stack_alloc_slots.contains(addr_arg.slot_idx)) {
                        inst.is_local_stack_write = true;
                    }
                }
                // Pre-resolve call targets and tail-call flag.
                if (inst.op == .call and inst.args.len > 0) {
                    const cname = inst.args[0].name;
                    call_targets[pc] = self.resolveCallTarget(cname);
                    if (std.mem.eql(u8, cname, func_name)) {
                        inst.is_tail_call = self.isTailSelfCallAt(func, pc);
                    }
                }
                if ((inst.op == .assign or inst.op == .assume_safe or inst.op == .assume_borrow or inst.op == .raw_cast or inst.op == .bitcast) and inst.args.len > 0) {
                    const src = inst.args[0];
                    if (src.kind == .register or src.kind == .stack_addr) inst.src_slot = src.slot_idx;
                }
            }
            try self.function_call_targets.put(func_name, call_targets);
            try self.function_cacheable.put(func_name, !self.functionHasExternalSideEffect(func));
        }
    }

    fn initFunctionsAndVtables(self: *VM) !void {
        var func_it = self.program.functions.iterator();
        while (func_it.next()) |entry| {
            const func_name = entry.key_ptr.*;
            const func_ptr = self.program.functions.getPtr(func_name) orelse return error.SymbolNotFound;
            try self.function_ptrs.put(func_name, func_ptr);
            const dummy = try self.allocator.create(u8);
            dummy.* = 0;
            try self.dummy_buffers.append(dummy);
            const addr = @intFromPtr(dummy);
            try self.function_addresses.put(addr, func_ptr);
            try self.function_names.put(func_name, addr);

            var label_map = std.StringHashMap(usize).init(self.allocator);
            errdefer label_map.deinit();
            for (entry.value_ptr.blocks) |block| {
                try label_map.put(block.label, block.start_inst);
            }
            try self.label_targets.put(func_name, label_map);

            var reg_map = std.StringHashMap(usize).init(self.allocator);
            errdefer reg_map.deinit();
            var reg_idx: usize = 0;
            // Parameters occupy the first slots (0, 1, 2 ...) in order.
            for (entry.value_ptr.params) |param| {
                if (!reg_map.contains(param)) {
                    try reg_map.put(param, reg_idx);
                    reg_idx += 1;
                }
            }
            for (entry.value_ptr.instructions) |inst| {
                if (inst.dest) |dest| {
                    // cmpxchg dests may be "reg1, reg2" — register each part separately.
                    if (std.mem.indexOf(u8, dest, ",")) |comma_idx| {
                        const d1 = std.mem.trim(u8, dest[0..comma_idx], " \t");
                        const d2 = std.mem.trim(u8, dest[comma_idx + 1 ..], " \t");
                        if (!reg_map.contains(d1)) {
                            try reg_map.put(d1, reg_idx);
                            reg_idx += 1;
                        }
                        if (!reg_map.contains(d2)) {
                            try reg_map.put(d2, reg_idx);
                            reg_idx += 1;
                        }
                    } else if (!reg_map.contains(dest)) {
                        try reg_map.put(dest, reg_idx);
                        reg_idx += 1;
                    }
                }
                for (inst.args) |arg| {
                    if (arg.kind == .register or arg.kind == .stack_addr or arg.kind == .offset_addr) {
                        if (!reg_map.contains(arg.name)) {
                            try reg_map.put(arg.name, reg_idx);
                            reg_idx += 1;
                        }
                    }
                }
            }
            try self.function_registers.put(func_name, reg_map);
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
                const vtable_bytes = try self.program.allocator.alloc(u8, methods_list.items.len * @sizeOf(usize));
                @memcpy(vtable_bytes, std.mem.sliceAsBytes(methods_list.items));
                methods_list.deinit();
                self.program.allocator.free(val_str);
                entry.value_ptr.* = vtable_bytes;
            }
        }

        // Resolve all register slots, branch targets, and call targets.
        try self.bindingPass();
    }

    const CallArgs = struct {
        items: []usize,
        owned: ?[]usize = null,

        fn deinit(self: *CallArgs, allocator: std.mem.Allocator) void {
            if (self.owned) |buf| allocator.free(buf);
            self.* = .{ .items = &.{}, .owned = null };
        }
    };

    fn collectCallArgs(self: *VM, frame: *Frame, operands: []const parser.Operand, inline_buf: []usize) !CallArgs {
        if (operands.len <= inline_buf.len) {
            for (operands, 0..) |arg, idx| {
                inline_buf[idx] = self.resolveVal(frame, arg);
            }
            return .{ .items = inline_buf[0..operands.len] };
        }

        var count: usize = 0;
        var owned: ?[]usize = null;
        var owned_cap: usize = 0;
        var owned_len: usize = 0;

        for (operands) |arg| {
            const value = self.resolveVal(frame, arg);
            if (owned) |buf| {
                var buf_mut = buf;
                if (owned_len == owned_cap) {
                    const next_cap = @max(owned_len * 2, 16);
                    const next = try self.allocator.realloc(buf_mut, next_cap);
                    owned = next;
                    owned_cap = next_cap;
                    buf_mut = next;
                }
                buf_mut[owned_len] = value;
                owned_len += 1;
                continue;
            }
            if (count < inline_buf.len) {
                inline_buf[count] = value;
                count += 1;
                continue;
            }
            var buf = try self.allocator.alloc(usize, 16);
            @memcpy(buf[0..count], inline_buf[0..count]);
            buf[count] = value;
            owned = buf;
            owned_cap = buf.len;
            owned_len = count + 1;
        }

        if (owned) |buf| {
            return .{ .items = buf[0..owned_len], .owned = buf };
        }
        return .{ .items = inline_buf[0..count] };
    }

    fn getLabelIndex(self: *VM, func_name: []const u8, label: []const u8) !usize {
        const label_map = self.label_targets.get(func_name) orelse return error.LabelNotFound;
        return label_map.get(label) orelse error.LabelNotFound;
    }

    /// Flat register file — a plain []u64 array, zero HashMap overhead.
    const Frame = struct {
        data: []u64,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator, slot_count: usize) !Frame {
            const data = try allocator.alloc(u64, @max(slot_count, 1));
            @memset(data, 0);
            return Frame{ .data = data, .allocator = allocator };
        }

        fn deinit(self: *Frame) void {
            self.allocator.free(self.data);
        }

        fn reset(self: *Frame) void {
            @memset(self.data, 0);
        }
    };

    fn acquireFrame(self: *VM, allocator: std.mem.Allocator, slot_count: usize, pooled: bool) !Frame {
        const needed = @max(slot_count, 1);
        if (pooled) {
            var idx = self.frame_pool.items.len;
            while (idx > 0) {
                idx -= 1;
                const buf = self.frame_pool.items[idx];
                if (buf.len >= needed) {
                    _ = self.frame_pool.swapRemove(idx);
                    @memset(buf, 0);
                    return Frame{ .data = buf, .allocator = allocator };
                }
            }
        }
        return Frame.init(allocator, needed);
    }

    fn releaseFrame(self: *VM, frame: *Frame, pooled: bool) void {
        if (pooled) {
            self.frame_pool.append(frame.data) catch {
                frame.deinit();
                frame.data = &.{};
                return;
            };
            frame.data = &.{};
            return;
        }
        frame.deinit();
    }

    inline fn resolveVal(self: *VM, frame: *Frame, arg: parser.Operand) usize {
        _ = self;
        switch (arg.kind) {
            .immediate => return @as(usize, @intCast(arg.imm_val)),
            .constant_addr => return @as(usize, @intCast(arg.imm_val)),
            .stack_addr, .register => return @as(usize, @intCast(frame.data[arg.slot_idx])),
            .offset_addr => {
                const base = @as(usize, @intCast(frame.data[arg.slot_idx]));
                const offset_bits: usize = @bitCast(@as(isize, arg.offset));
                return base +% offset_bits;
            },
            .label => return arg.pc_target,
        }
    }

    inline fn resolveScalarVal(self: *VM, frame: *Frame, arg: parser.Operand) usize {
        return switch (arg.kind) {
            .register, .stack_addr => @as(usize, @intCast(frame.data[arg.slot_idx])),
            .immediate, .constant_addr => @as(usize, @intCast(arg.imm_val)),
            else => self.resolveVal(frame, arg),
        };
    }

    inline fn resolveAddrVal(self: *VM, frame: *Frame, arg: parser.Operand) usize {
        return switch (arg.kind) {
            .offset_addr => {
                const base = @as(usize, @intCast(frame.data[arg.slot_idx]));
                const offset_bits: usize = @bitCast(@as(isize, arg.offset));
                return base +% offset_bits;
            },
            .register, .stack_addr => @as(usize, @intCast(frame.data[arg.slot_idx])),
            .immediate, .constant_addr => @as(usize, @intCast(arg.imm_val)),
            else => self.resolveVal(frame, arg),
        };
    }

    fn executeThreadEntry(self: *VM, entry_ptr: usize, arg_ptr: usize) !usize {
        if (self.function_addresses.get(entry_ptr)) |target_func| {
            return try self.executeFunction(target_func, &.{arg_ptr});
        }
        return self.ffi.callPointerLegacy(entry_ptr, &.{arg_ptr});
    }

    inline fn bumpMemoryEpoch(self: *VM) void {
        self.memory_epoch +%= 1;
        if (self.memory_epoch == 0) {
            self.memory_epoch = 1;
            self.call_cache.clearRetainingCapacity();
        }
    }

    fn makeCallCacheKey(func: *const parser.Function, args: []const usize, memory_epoch: u64) ?CallCacheKey {
        if (args.len > CALL_CACHE_MAX_ARGS) return null;
        var key = CallCacheKey{
            .func_ptr = @intFromPtr(func),
            .memory_epoch = memory_epoch,
            .argc = @intCast(args.len),
            .args = [_]usize{0} ** CALL_CACHE_MAX_ARGS,
        };
        for (args, 0..) |arg, idx| key.args[idx] = arg;
        return key;
    }

    fn executeInterpretedCall(self: *VM, target_func: *const parser.Function, args: []const usize) !usize {
        if ((self.function_cacheable.get(target_func.name) orelse false)) {
            if (makeCallCacheKey(target_func, args, self.memory_epoch)) |key| {
                if (self.call_cache.get(key)) |cached| return cached;
                const ret = try self.executeFunction(target_func, args);
                try self.call_cache.put(key, ret);
                return ret;
            }
        }
        return self.executeFunction(target_func, args);
    }

    fn executePthreadCall(self: *VM, func_name: []const u8, args: []const usize) !usize {
        if (std.mem.eql(u8, func_name, "pthread_spawn")) {
            if (args.len < 2) return error.FfiArityMismatch;
            const ret = try self.executeThreadEntry(args[0], args[1]);
            const handle = self.next_thread_handle;
            self.next_thread_handle += 1;
            try self.thread_results.put(handle, ret);
            return @as(usize, @intCast(handle));
        }
        if (std.mem.eql(u8, func_name, "pthread_spawn_detached")) {
            if (args.len < 2) return error.FfiArityMismatch;
            _ = try self.executeThreadEntry(args[0], args[1]);
            return 0;
        }
        if (std.mem.eql(u8, func_name, "pthread_join")) {
            if (args.len < 1) return error.FfiArityMismatch;
            const handle = @as(i32, @bitCast(@as(u32, @intCast(args[0] & 0xffffffff))));
            const ret = self.thread_results.get(handle) orelse return 1;
            if (args.len >= 2 and args[1] != 0) {
                @as(*align(1) u32, @ptrFromInt(args[1])).* = @as(u32, @intCast(ret & 0xffffffff));
            }
            return 0;
        }
        if (std.mem.eql(u8, func_name, "pthread_drop")) {
            if (args.len < 1) return error.FfiArityMismatch;
            const handle = @as(i32, @bitCast(@as(u32, @intCast(args[0] & 0xffffffff))));
            _ = self.thread_results.remove(handle);
            return 0;
        }
        return error.SymbolNotFound;
    }

    /// Runtime fallback for calls that couldn't be resolved at binding time.
    fn callUnresolved(self: *VM, func_name: []const u8, args: []const usize) !usize {
        if (self.program.externs.get(func_name)) |signature| {
            return try self.ffi.callSymbol(func_name, signature, args);
        } else if (self.ffi.resolveSymbol(func_name)) |sym| {
            _ = sym;
            return try self.ffi.callSymbolLegacy(func_name, args);
        } else if (self.program.functions.get(func_name)) |target_func| {
            return try self.executeInterpretedCall(&target_func, args);
        } else {
            std.debug.print("Symbol not found: {s}\n", .{func_name});
            return error.SymbolNotFound;
        }
    }

    fn signExtend(value: usize, from_bits: u8) u64 {
        const raw = @as(u64, @intCast(value));
        if (from_bits >= 64) return raw;
        const width = @as(u6, @intCast(from_bits));
        const sign_width = @as(u6, @intCast(from_bits - 1));
        const mask = (@as(u64, 1) << width) - 1;
        const sign_bit = @as(u64, 1) << sign_width;
        const narrowed = raw & mask;
        return if ((narrowed & sign_bit) != 0) narrowed | ~mask else narrowed;
    }

    fn truncToType(value: usize, ty: parser.PrimType) u64 {
        const raw = @as(u64, @intCast(value));
        return switch (ty) {
            .i1 => raw & 1,
            .i8, .u8 => raw & 0xff,
            .i16, .u16 => raw & 0xffff,
            .i32, .u32, .f32 => raw & 0xffffffff,
            else => raw,
        };
    }

    fn executeFunction(self: *VM, func: *const parser.Function, call_args: []const usize) anyerror!usize {
        const needs_arena = self.function_needs_arena.get(func.name) orelse true;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer if (needs_arena) arena.deinit();
        const local_alloc = if (needs_arena) arena.allocator() else self.allocator;

        var current_args_buf: [16]usize = undefined;
        var current_args_owned = false;
        var current_args: []usize = undefined;
        if (call_args.len <= current_args_buf.len) {
            @memcpy(current_args_buf[0..call_args.len], call_args);
            current_args = current_args_buf[0..call_args.len];
        } else {
            current_args = try local_alloc.dupe(usize, call_args);
            current_args_owned = true;
        }
        defer if (current_args_owned and !needs_arena) self.allocator.free(current_args);

        const slot_count = self.function_slot_counts.get(func.name) orelse (func.params.len + 64);
        var frame = try self.acquireFrame(local_alloc, slot_count, !needs_arena);
        defer self.releaseFrame(&frame, !needs_arena);
        const call_targets = self.function_call_targets.get(func.name) orelse return error.SymbolNotFound;

        while (true) {

            // Params are at slots 0..N-1 (registered first, in order).
            for (current_args, 0..) |arg_val, i| {
                frame.data[i] = arg_val;
            }

            var pc: usize = 0;
            var tail_restart = false;

            instr_loop: while (pc < func.instructions.len) {
                const inst = &func.instructions[pc];
                switch (inst.op) {
                    .stack_alloc, .alloc => {
                        const size = self.resolveVal(&frame, inst.args[0]);
                        const word_count = (size + 7) / 8;
                        const buf = if (inst.op == .stack_alloc)
                            try local_alloc.alloc(u64, @max(1, word_count))
                        else
                            try self.allocator.alloc(u64, @max(1, word_count));
                        @memset(std.mem.sliceAsBytes(buf), 0);
                        if (inst.op == .alloc) {
                            try self.heap_allocs.append(buf);
                            self.bumpMemoryEpoch();
                        }
                        if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = @intFromPtr(buf.ptr);
                        pc += 1;
                    },
                    .ptr_add => {
                        const ptr_val = self.resolveScalarVal(&frame, inst.args[0]);
                        const offset_val = self.resolveScalarVal(&frame, inst.args[1]);
                        if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ptr_val +% offset_val;
                        pc += 1;
                    },
                    .add, .sub, .mul, .div, .rem, .sdiv, .udiv, .srem, .urem, .shl, .shr => {
                        const arg1 = self.resolveScalarVal(&frame, inst.args[0]);
                        const arg2 = self.resolveScalarVal(&frame, inst.args[1]);
                        const result: u64 = switch (inst.op) {
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
                        if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = result;
                        pc += 1;
                    },
                    .and_, .or_, .xor_ => {
                        const arg1 = self.resolveScalarVal(&frame, inst.args[0]);
                        const arg2 = self.resolveScalarVal(&frame, inst.args[1]);
                        const result: u64 = switch (inst.op) {
                            .and_ => arg1 & arg2,
                            .or_ => arg1 | arg2,
                            .xor_ => arg1 ^ arg2,
                            else => unreachable,
                        };
                        if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = result;
                        pc += 1;
                    },
                    .call => {
                        // Fast path: pre-computed tail self-call — no arg collection needed.
                        if (inst.is_tail_call) {
                            if (inst.args.len - 1 != current_args.len) return error.FfiArityMismatch;
                            for (inst.args[1..], 0..) |arg, ai| {
                                current_args[ai] = self.resolveScalarVal(&frame, arg);
                            }
                            tail_restart = true;
                            break :instr_loop;
                        }
                        var args_buf: [16]usize = undefined;
                        var args = try self.collectCallArgs(&frame, inst.args[1..], args_buf[0..]);
                        defer args.deinit(self.allocator);
                        const call_target = call_targets[pc];
                        switch (call_target) {
                            .builtin_print => {
                                const slice = @as([*]const u8, @ptrFromInt(args.items[0]))[0..args.items[1]];
                                _ = std.posix.write(std.posix.STDOUT_FILENO, slice) catch {};
                                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = 0;
                            },
                            .builtin_time_ms => {
                                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = @as(u64, @bitCast(std.time.milliTimestamp()));
                            },
                            .builtin_time_s => {
                                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = @as(u64, @bitCast(std.time.timestamp()));
                            },
                            .builtin_time_ns => {
                                const ns = @as(i64, @intCast(std.time.nanoTimestamp()));
                                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = @as(u64, @bitCast(ns));
                            },
                            .builtin_time_instant_ns => {
                                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = @as(u64, @intCast(std.time.nanoTimestamp()));
                            },
                            .interpreted => |target_func| {
                                const ret = try self.executeInterpretedCall(target_func, args.items);
                                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ret;
                            },
                            .ffi_typed => |ft| {
                                const ret = try self.ffi.callSymbolWithPtr(ft.sym, ft.sig, args.items);
                                self.bumpMemoryEpoch();
                                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ret;
                            },
                            .ffi_legacy => |sym| {
                                const ret = self.ffi.callPointerLegacy(@intFromPtr(sym), args.items);
                                self.bumpMemoryEpoch();
                                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ret;
                            },
                            .pthread_spawn => {
                                const ret = try self.executePthreadCall("pthread_spawn", args.items);
                                self.bumpMemoryEpoch();
                                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ret;
                            },
                            .pthread_spawn_detached => {
                                const ret = try self.executePthreadCall("pthread_spawn_detached", args.items);
                                self.bumpMemoryEpoch();
                                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ret;
                            },
                            .pthread_join => {
                                const ret = try self.executePthreadCall("pthread_join", args.items);
                                self.bumpMemoryEpoch();
                                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ret;
                            },
                            .pthread_drop => {
                                const ret = try self.executePthreadCall("pthread_drop", args.items);
                                self.bumpMemoryEpoch();
                                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ret;
                            },
                            .unresolved => {
                                const ret = try self.callUnresolved(inst.args[0].name, args.items);
                                self.bumpMemoryEpoch();
                                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ret;
                            },
                        }
                        pc += 1;
                    },
                    .call_indirect => {
                        const ptr = self.resolveAddrVal(&frame, inst.args[0]);
                        var args_buf: [16]usize = undefined;
                        var args = try self.collectCallArgs(&frame, inst.args[1..], args_buf[0..]);
                        defer args.deinit(self.allocator);
                        if (self.function_addresses.get(ptr)) |target| {
                            const ret = try self.executeInterpretedCall(target, args.items);
                            if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ret;
                        } else {
                            const ret = self.ffi.callPointerLegacy(ptr, args.items);
                            self.bumpMemoryEpoch();
                            if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ret;
                        }
                        pc += 1;
                    },
                    .load, .atomic_load => {
                        const addr = self.resolveAddrVal(&frame, inst.args[0]);
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
                        if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = val;
                        pc += 1;
                    },
                    .store, .atomic_store => {
                        const val = self.resolveScalarVal(&frame, inst.args[0]);
                        const addr = self.resolveAddrVal(&frame, inst.args[1]);
                        switch (inst.dest_type) {
                            .ptr, .i64, .u64 => @as(*align(1) u64, @ptrFromInt(addr)).* = val,
                            .i32, .u32 => @as(*align(1) u32, @ptrFromInt(addr)).* = @as(u32, @intCast(val & 0xffffffff)),
                            .i16, .u16 => @as(*align(1) u16, @ptrFromInt(addr)).* = @as(u16, @intCast(val & 0xffff)),
                            .i8, .u8 => @as(*align(1) u8, @ptrFromInt(addr)).* = @as(u8, @intCast(val & 0xff)),
                            else => @as(*align(1) u64, @ptrFromInt(addr)).* = val,
                        }
                        if (!inst.is_local_stack_write) self.bumpMemoryEpoch();
                        pc += 1;
                    },
                    .cmpxchg => {
                        const addr = self.resolveAddrVal(&frame, inst.args[0]);
                        const expected = self.resolveScalarVal(&frame, inst.args[1]);
                        const new_val = self.resolveScalarVal(&frame, inst.args[2]);
                        const old_val: u64 = switch (inst.dest_type) {
                            .ptr, .i64, .u64 => @cmpxchgStrong(u64, @as(*u64, @ptrFromInt(addr)), expected, new_val, .seq_cst, .seq_cst) orelse expected,
                            .i32, .u32 => @cmpxchgStrong(u32, @as(*u32, @ptrFromInt(addr)), @as(u32, @intCast(expected & 0xffffffff)), @as(u32, @intCast(new_val & 0xffffffff)), .seq_cst, .seq_cst) orelse @as(u32, @intCast(expected & 0xffffffff)),
                            .i16, .u16 => @cmpxchgStrong(u16, @as(*u16, @ptrFromInt(addr)), @as(u16, @intCast(expected & 0xffff)), @as(u16, @intCast(new_val & 0xffff)), .seq_cst, .seq_cst) orelse @as(u16, @intCast(expected & 0xffff)),
                            .i8, .u8 => @cmpxchgStrong(u8, @as(*u8, @ptrFromInt(addr)), @as(u8, @intCast(expected & 0xff)), @as(u8, @intCast(new_val & 0xff)), .seq_cst, .seq_cst) orelse @as(u8, @intCast(expected & 0xff)),
                            else => return error.UnsupportedCmpxchgType,
                        };
                        if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = old_val;
                        if (inst.dest_slot2 != INVALID_SLOT) frame.data[inst.dest_slot2] = if (old_val == expected) 1 else 0;
                        self.bumpMemoryEpoch();
                        pc += 1;
                    },
                    .atomic_rmw_add => {
                        const addr = self.resolveAddrVal(&frame, inst.args[0]);
                        const val = self.resolveScalarVal(&frame, inst.args[1]);
                        const old_val: u64 = switch (inst.dest_type) {
                            .ptr, .i64, .u64 => @atomicRmw(u64, @as(*u64, @ptrFromInt(addr)), .Add, val, .seq_cst),
                            .i32, .u32 => @atomicRmw(u32, @as(*u32, @ptrFromInt(addr)), .Add, @as(u32, @intCast(val & 0xffffffff)), .seq_cst),
                            .i16, .u16 => @atomicRmw(u16, @as(*u16, @ptrFromInt(addr)), .Add, @as(u16, @intCast(val & 0xffff)), .seq_cst),
                            .i8, .u8 => @atomicRmw(u8, @as(*u8, @ptrFromInt(addr)), .Add, @as(u8, @intCast(val & 0xff)), .seq_cst),
                            else => return error.UnsupportedAtomicRmwType,
                        };
                        if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = old_val;
                        self.bumpMemoryEpoch();
                        pc += 1;
                    },
                    .eq, .ne, .sgt, .ugt, .gt, .slt, .ult, .lt, .sge, .uge, .sle, .ule => {
                        const v1 = self.resolveScalarVal(&frame, inst.args[0]);
                        const v2 = self.resolveScalarVal(&frame, inst.args[1]);
                        const is_true = switch (inst.op) {
                            .eq => v1 == v2,
                            .ne => v1 != v2,
                            .sgt, .gt => @as(i64, @bitCast(v1)) > @as(i64, @bitCast(v2)),
                            .ugt => v1 > v2,
                            .slt, .lt => @as(i64, @bitCast(v1)) < @as(i64, @bitCast(v2)),
                            .ult => v1 < v2,
                            .sge => @as(i64, @bitCast(v1)) >= @as(i64, @bitCast(v2)),
                            .uge => v1 >= v2,
                            .sle => @as(i64, @bitCast(v1)) <= @as(i64, @bitCast(v2)),
                            .ule => v1 <= v2,
                            else => unreachable,
                        };
                        if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = if (is_true) 1 else 0;
                        pc += 1;
                    },
                    .br => {
                        const cond = self.resolveVal(&frame, inst.args[0]);
                        pc = if (cond != 0) inst.args[1].pc_target else inst.args[2].pc_target;
                    },
                    .jmp => pc = inst.args[0].pc_target,
                    .assign, .assume_safe, .assume_borrow, .raw_cast, .bitcast => {
                        if (inst.dest_slot != INVALID_SLOT) {
                            frame.data[inst.dest_slot] = if (inst.src_slot != INVALID_SLOT) frame.data[inst.src_slot] else self.resolveVal(&frame, inst.args[0]);
                        }
                        pc += 1;
                    },
                    .sext => {
                        const raw = self.resolveVal(&frame, inst.args[0]);
                        const from_bits: u8 = switch (inst.dest_type) {
                            .i8, .u8 => 8,
                            .i16, .u16 => 16,
                            .i32, .u32 => 32,
                            else => 64,
                        };
                        if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = signExtend(raw, from_bits);
                        pc += 1;
                    },
                    .zext, .trunc => {
                        const raw = self.resolveVal(&frame, inst.args[0]);
                        if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = truncToType(raw, inst.dest_type);
                        pc += 1;
                    },
                    .take => {
                        const ptr = @as(*align(1) usize, @ptrFromInt(self.resolveVal(&frame, inst.args[0])));
                        if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ptr.*;
                        ptr.* = 0;
                        pc += 1;
                    },
                    .try_ => {
                        const addr = self.resolveVal(&frame, inst.args[0]);
                        const tag = @as(*align(1) const u64, @ptrFromInt(addr)).*;
                        if (tag != 0) {
                            _ = self.freeTrackedResultAlloc(addr);
                            return tag;
                        }
                        if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = @as(*align(1) const u64, @ptrFromInt(addr + 8)).*;
                        _ = self.freeTrackedResultAlloc(addr);
                        pc += 1;
                    },
                    .panic => {
                        const panic_code = @as(u8, @truncate(self.resolveVal(&frame, inst.args[0])));
                        self.clearPanicState();
                        self.panic_code = panic_code;
                        return error.Panic;
                    },
                    .panic_msg => {
                        const panic_code = @as(u8, @truncate(self.resolveVal(&frame, inst.args[0])));
                        const msg_ptr = self.resolveVal(&frame, inst.args[1]);
                        const msg_len = @as(usize, @intCast(self.resolveVal(&frame, inst.args[2])));
                        self.clearPanicState();
                        self.panic_code = panic_code;
                        if (msg_ptr != 0 and msg_len != 0) {
                            const src = @as([*]const u8, @ptrFromInt(msg_ptr))[0..msg_len];
                            const buf = try self.allocator.alloc(u8, msg_len);
                            @memcpy(buf, src);
                            self.panic_message = buf;
                        }
                        return error.Panic;
                    },
                    .consume => {
                        const ptr = self.resolveVal(&frame, inst.args[0]);
                        _ = self.freeTrackedResultAlloc(ptr);
                        pc += 1;
                    },
                    .return_ => {
                        const ret = if (inst.args.len > 0) self.resolveVal(&frame, inst.args[0]) else 0;
                        if (func.returns_result and !std.mem.eql(u8, func.name, "main")) {
                            const buf = try self.allocator.alloc(u64, 3);
                            errdefer self.allocator.free(buf);
                            buf[0] = 0;
                            buf[1] = ret;
                            buf[2] = 0;
                            try self.result_allocs.append(buf);
                            try self.result_alloc_index.put(@intFromPtr(buf.ptr), self.result_allocs.items.len - 1);
                            return @intFromPtr(buf.ptr);
                        }
                        return ret;
                    },
                }
            }

            if (tail_restart) {
                if (needs_arena) frame.reset();
                continue;
            }
            return 0;
        }
    }
};
