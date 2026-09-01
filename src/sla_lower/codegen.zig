const std = @import("std");
const ast = @import("ast.zig");
const contract_parser = @import("contract_parser.zig");
const type_checker = @import("type_checker.zig");
const lowering_rules = @import("lowering_rules.zig");

pub const CodegenError = error{
    CodegenError,
    OutOfMemory,
};

const ThreadSpawnHelper = struct {
    worker_name: []const u8,
    spawn_name: []const u8,
    vtable_name: []const u8,
    closure: *const ast.ClosureLiteral,
    ret_ty: *const ast.Type,
    captures: []const ThreadCapture,
    slot_size: usize,
    inline_join: bool = false,
};

const ThreadCapture = struct {
    name: []const u8,
    offset: usize,
    is_fn_ptr: bool = false,
    is_noncopy_payload: bool = false,
};

const ThreadCaptureInfo = struct {
    is_fn_ptr: bool = false,
    is_noncopy_payload: bool = false,
};

const RefCellBorrowHandle = struct {
    cell_reg: []const u8,
    kind: lowering_rules.RefCellBorrowKind,
    cell_release_temp: ?[]const u8 = null,
};

const ResultSlotRefCellHandle = struct {
    cell_slot: []const u8,
    kind: lowering_rules.RefCellBorrowKind,
};

const BranchRefCellHandleOwnerMergeSlot = struct {
    cell_slot: []const u8,
    kind: lowering_rules.RefCellBorrowKind,
};

const MutexGuardHandle = struct {
    mutex_reg: []const u8,
};

const RwLockGuardHandle = struct {
    lock_reg: []const u8,
    is_write: bool,
};

const FileResultHandle = struct {};
const MetadataResultHandle = struct {};

const TimeMacroUseSummary = struct {
    has_duration_from_millis: bool = false,
    has_thread_sleep_ns: bool = false,
    has_unsupported: bool = false,

    fn observe(self: *TimeMacroUseSummary, name: []const u8) void {
        if (!std.mem.startsWith(u8, name, "TIME_")) return;
        if (std.mem.eql(u8, name, "TIME_DURATION_FROM_MILLIS")) {
            self.has_duration_from_millis = true;
        } else if (std.mem.eql(u8, name, "TIME_THREAD_SLEEP_NS")) {
            self.has_thread_sleep_ns = true;
        } else {
            self.has_unsupported = true;
        }
    }

    fn supportsPlainSleepMsAbi(self: TimeMacroUseSummary) bool {
        return self.has_duration_from_millis and self.has_thread_sleep_ns and !self.has_unsupported;
    }
};

pub const InjectedAddressBinding = struct {
    name: []const u8,
    address: []const u8,
};

pub const Options = struct {
    injected_address_bindings: []const InjectedAddressBinding = &.{},
};

pub const Codegen = struct {
    allocator: std.mem.Allocator,
    tc: *type_checker.TypeChecker,
    out: std.ArrayList(u8),
    tmp_idx: usize,
    label_idx: usize,
    string_idx: usize,
    macro_local_idx: usize,
    macro_inline_depth: usize,
    active_inline_macro: ?*const ast.MacroDecl,
    active_macro_try_cleanup: ?[]const []const u8,
    macro_locals: std.StringHashMap([]const u8),
    macro_arg_exprs: std.StringHashMap(*const ast.Node),
    macro_arg_types: std.StringHashMap(*const ast.Type),
    local_binding_types: std.StringHashMap(*const ast.Type),
    closure_bindings: std.StringHashMap(*const ast.ClosureLiteral),
    closure_param_regs: std.StringHashMap([]const u8),
    stack_alloc_bindings: std.StringHashMap(void),
    addressable_bindings: std.StringHashMap(void),
    assigned_bindings: std.StringHashMap(void),
    assigned_value_slots: std.StringHashMap(void),
    repeated_let_bindings: std.StringHashMap(void),
    global_const_bindings: std.StringHashMap(void),
    global_scalar_consts: std.StringHashMap(*const ast.Node),
    hashmap_key_slots: std.StringHashMap([]const u8),
    thread_spawn_helpers: std.AutoHashMap(*const ast.Node, ThreadSpawnHelper),
    thread_capture_regs: std.StringHashMap([]const u8),
    inline_thread_handles: std.StringHashMap(void),
    consumed_bindings: std.StringHashMap(void),
    mpsc_sender_bindings: std.StringHashMap(void),
    mpsc_sender_channels: std.StringHashMap([]const u8),
    mpsc_receiver_bindings: std.StringHashMap(void),
    string_buf_bindings: std.StringHashMap(void),
    hashmap_bindings: std.StringHashMap(void),
    btree_map_bindings: std.StringHashMap(void),
    hashset_bindings: std.StringHashMap(void),
    btree_set_bindings: std.StringHashMap(void),
    borrow_source_temps: std.StringHashMap([]const u8),
    refcell_borrow_handles: std.StringHashMap(RefCellBorrowHandle),
    result_slot_refcell_handles: std.StringHashMap(ResultSlotRefCellHandle),
    result_slot_refcell_slots: std.StringHashMap([]const u8),
    mutex_guard_handles: std.StringHashMap(MutexGuardHandle),
    mutex_lock_results: std.StringHashMap(MutexGuardHandle),
    rwlock_guard_handles: std.StringHashMap(RwLockGuardHandle),
    rwlock_lock_results: std.StringHashMap(RwLockGuardHandle),
    file_bindings: std.StringHashMap(void),
    file_open_results: std.StringHashMap(FileResultHandle),
    metadata_bindings: std.StringHashMap(void),
    metadata_open_results: std.StringHashMap(MetadataResultHandle),
    task_future_objects: std.StringHashMap([]const u8),
    future_state_vtables: std.StringHashMap([]const u8),
    future_readiness: std.StringHashMap(lowering_rules.FutureReadiness),
    executor_task_counts: std.StringHashMap(usize),
    binding_aliases: std.StringHashMap(std.ArrayList([]const u8)),
    let_binding_aliases: std.AutoHashMap(*const ast.Node, []const u8),
    injected_address_bindings: std.StringHashMap([]const u8),
    loop_continue_labels: std.ArrayList([]const u8),
    loop_break_labels: std.ArrayList([]const u8),
    loop_body_local_scopes: std.ArrayList(std.ArrayList([]const u8)),
    loop_body_block_depths: std.ArrayList(usize),
    current_expr_later_nodes: std.ArrayList(*const ast.Node),
    current_block: ?[]const *ast.Node = null,
    current_stmt_index: usize = 0,
    current_async: bool,
    current_async_return_ty: ?*const ast.Type,
    async_pending_return_emitted: bool,
    thread_helper_idx: usize,
    use_plain_time_sleep_ms_abi: bool,

    // Error diagnostics: what generation was doing when a CodegenError
    // escaped, so CLI output can name the function/statement/macro instead
    // of a bare error tag. Tracked entry points (genFuncDeclNamed,
    // genStmt, macro expansion) keep these current while their frame is
    // active and synthesize `error_detail` on failure. The first failure
    // wins; deeper frames never overwrite an earlier message.
    diag_func_name: ?[]const u8 = null,
    diag_stmt_node: ?*ast.Node = null,
    diag_macro_name: ?[]const u8 = null,
    diag_call_arg_index: ?usize = null,
    error_detail: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, tc: *type_checker.TypeChecker) Codegen {
        return initWithOptions(allocator, tc, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, tc: *type_checker.TypeChecker, options: Options) Codegen {
        var injected_address_bindings = std.StringHashMap([]const u8).init(allocator);
        for (options.injected_address_bindings) |binding| {
            injected_address_bindings.put(binding.name, binding.address) catch {};
        }
        return .{
            .allocator = allocator,
            .tc = tc,
            .out = std.ArrayList(u8).init(allocator),
            .tmp_idx = 0,
            .label_idx = 0,
            .string_idx = 0,
            .macro_local_idx = 0,
            .macro_inline_depth = 0,
            .active_inline_macro = null,
            .active_macro_try_cleanup = null,
            .macro_locals = std.StringHashMap([]const u8).init(allocator),
            .macro_arg_exprs = std.StringHashMap(*const ast.Node).init(allocator),
            .macro_arg_types = std.StringHashMap(*const ast.Type).init(allocator),
            .local_binding_types = std.StringHashMap(*const ast.Type).init(allocator),
            .closure_bindings = std.StringHashMap(*const ast.ClosureLiteral).init(allocator),
            .closure_param_regs = std.StringHashMap([]const u8).init(allocator),
            .stack_alloc_bindings = std.StringHashMap(void).init(allocator),
            .addressable_bindings = std.StringHashMap(void).init(allocator),
            .assigned_bindings = std.StringHashMap(void).init(allocator),
            .assigned_value_slots = std.StringHashMap(void).init(allocator),
            .repeated_let_bindings = std.StringHashMap(void).init(allocator),
            .global_const_bindings = std.StringHashMap(void).init(allocator),
            .global_scalar_consts = std.StringHashMap(*const ast.Node).init(allocator),
            .hashmap_key_slots = std.StringHashMap([]const u8).init(allocator),
            .thread_spawn_helpers = std.AutoHashMap(*const ast.Node, ThreadSpawnHelper).init(allocator),
            .thread_capture_regs = std.StringHashMap([]const u8).init(allocator),
            .inline_thread_handles = std.StringHashMap(void).init(allocator),
            .consumed_bindings = std.StringHashMap(void).init(allocator),
            .mpsc_sender_bindings = std.StringHashMap(void).init(allocator),
            .mpsc_sender_channels = std.StringHashMap([]const u8).init(allocator),
            .mpsc_receiver_bindings = std.StringHashMap(void).init(allocator),
            .string_buf_bindings = std.StringHashMap(void).init(allocator),
            .hashmap_bindings = std.StringHashMap(void).init(allocator),
            .btree_map_bindings = std.StringHashMap(void).init(allocator),
            .hashset_bindings = std.StringHashMap(void).init(allocator),
            .btree_set_bindings = std.StringHashMap(void).init(allocator),
            .borrow_source_temps = std.StringHashMap([]const u8).init(allocator),
            .refcell_borrow_handles = std.StringHashMap(RefCellBorrowHandle).init(allocator),
            .result_slot_refcell_handles = std.StringHashMap(ResultSlotRefCellHandle).init(allocator),
            .result_slot_refcell_slots = std.StringHashMap([]const u8).init(allocator),
            .mutex_guard_handles = std.StringHashMap(MutexGuardHandle).init(allocator),
            .mutex_lock_results = std.StringHashMap(MutexGuardHandle).init(allocator),
            .rwlock_guard_handles = std.StringHashMap(RwLockGuardHandle).init(allocator),
            .rwlock_lock_results = std.StringHashMap(RwLockGuardHandle).init(allocator),
            .file_bindings = std.StringHashMap(void).init(allocator),
            .file_open_results = std.StringHashMap(FileResultHandle).init(allocator),
            .metadata_bindings = std.StringHashMap(void).init(allocator),
            .metadata_open_results = std.StringHashMap(MetadataResultHandle).init(allocator),
            .task_future_objects = std.StringHashMap([]const u8).init(allocator),
            .future_state_vtables = std.StringHashMap([]const u8).init(allocator),
            .future_readiness = std.StringHashMap(lowering_rules.FutureReadiness).init(allocator),
            .executor_task_counts = std.StringHashMap(usize).init(allocator),
            .binding_aliases = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .let_binding_aliases = std.AutoHashMap(*const ast.Node, []const u8).init(allocator),
            .injected_address_bindings = injected_address_bindings,
            .loop_continue_labels = std.ArrayList([]const u8).init(allocator),
            .loop_break_labels = std.ArrayList([]const u8).init(allocator),
            .loop_body_local_scopes = std.ArrayList(std.ArrayList([]const u8)).init(allocator),
            .loop_body_block_depths = std.ArrayList(usize).init(allocator),
            .current_expr_later_nodes = std.ArrayList(*const ast.Node).init(allocator),
            .current_async = false,
            .current_async_return_ty = null,
            .async_pending_return_emitted = false,
            .thread_helper_idx = 0,
            .use_plain_time_sleep_ms_abi = false,
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.out.deinit();
        var val_iter = self.macro_locals.valueIterator();
        while (val_iter.next()) |v| {
            self.allocator.free(v.*);
        }
        self.macro_locals.deinit();
        self.macro_arg_exprs.deinit();
        self.macro_arg_types.deinit();
        self.local_binding_types.deinit();
        self.closure_bindings.deinit();
        self.closure_param_regs.deinit();
        self.stack_alloc_bindings.deinit();
        self.addressable_bindings.deinit();
        self.assigned_bindings.deinit();
        self.assigned_value_slots.deinit();
        self.repeated_let_bindings.deinit();
        self.global_const_bindings.deinit();
        self.global_scalar_consts.deinit();
        var key_slot_iter = self.hashmap_key_slots.valueIterator();
        while (key_slot_iter.next()) |slot| {
            self.allocator.free(slot.*);
        }
        self.hashmap_key_slots.deinit();
        var thread_iter = self.thread_spawn_helpers.valueIterator();
        while (thread_iter.next()) |helper| {
            self.allocator.free(helper.worker_name);
            self.allocator.free(helper.spawn_name);
            self.allocator.free(helper.vtable_name);
            self.allocator.free(helper.captures);
        }
        self.thread_spawn_helpers.deinit();
        self.thread_capture_regs.deinit();
        self.inline_thread_handles.deinit();
        self.consumed_bindings.deinit();
        self.mpsc_sender_bindings.deinit();
        self.mpsc_sender_channels.deinit();
        self.mpsc_receiver_bindings.deinit();
        self.string_buf_bindings.deinit();
        self.hashmap_bindings.deinit();
        self.btree_map_bindings.deinit();
        self.hashset_bindings.deinit();
        self.btree_set_bindings.deinit();
        self.borrow_source_temps.deinit();
        self.refcell_borrow_handles.deinit();
        self.result_slot_refcell_handles.deinit();
        self.result_slot_refcell_slots.deinit();
        self.mutex_guard_handles.deinit();
        self.mutex_lock_results.deinit();
        self.rwlock_guard_handles.deinit();
        self.rwlock_lock_results.deinit();
        self.file_bindings.deinit();
        self.file_open_results.deinit();
        self.metadata_bindings.deinit();
        self.metadata_open_results.deinit();
        self.task_future_objects.deinit();
        self.future_state_vtables.deinit();
        self.future_readiness.deinit();
        self.executor_task_counts.deinit();
        self.clearBindingAliases();
        self.binding_aliases.deinit();
        self.let_binding_aliases.deinit();
        self.injected_address_bindings.deinit();
        self.loop_continue_labels.deinit();
        self.loop_break_labels.deinit();
        while (self.loop_body_local_scopes.items.len > 0) {
            var scope = self.loop_body_local_scopes.pop().?;
            scope.deinit();
        }
        self.loop_body_local_scopes.deinit();
        self.loop_body_block_depths.deinit();
        self.current_expr_later_nodes.deinit();
        if (self.error_detail) |d| self.allocator.free(d);
    }

    fn clearBindingAliases(self: *Codegen) void {
        var iter = self.binding_aliases.valueIterator();
        while (iter.next()) |aliases| {
            aliases.deinit();
        }
        self.binding_aliases.clearRetainingCapacity();
    }

    fn resolveBindingName(self: *Codegen, name: []const u8) []const u8 {
        if (self.binding_aliases.getPtr(name)) |aliases| {
            if (aliases.items.len > 0) return aliases.items[aliases.items.len - 1];
        }
        return name;
    }

    fn bindingStorageAddress(self: *Codegen, name: []const u8) ?[]const u8 {
        if (self.injected_address_bindings.get(name)) |address| return address;
        return null;
    }

    fn pushBindingAlias(self: *Codegen, name: []const u8) CodegenError![]const u8 {
        const alias = try self.newTmp();
        var entry = self.binding_aliases.getOrPut(name) catch return CodegenError.OutOfMemory;
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList([]const u8).init(self.allocator);
        }
        entry.value_ptr.append(alias) catch return CodegenError.OutOfMemory;
        return alias;
    }

    fn popBindingAlias(self: *Codegen, name: []const u8) void {
        if (self.binding_aliases.getPtr(name)) |aliases| {
            if (aliases.items.len > 0) _ = aliases.pop();
        }
    }

    fn pushBindingAliasTo(self: *Codegen, name: []const u8, alias: []const u8) CodegenError!void {
        var entry = self.binding_aliases.getOrPut(name) catch return CodegenError.OutOfMemory;
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList([]const u8).init(self.allocator);
        }
        entry.value_ptr.append(alias) catch return CodegenError.OutOfMemory;
    }

    fn newTmp(self: *Codegen) CodegenError![]const u8 {
        const name = std.fmt.allocPrint(self.allocator, "tmp_{}", .{self.tmp_idx}) catch return CodegenError.OutOfMemory;
        self.tmp_idx += 1;
        return name;
    }

    fn newLabel(self: *Codegen, prefix: []const u8) CodegenError![]const u8 {
        const name = std.fmt.allocPrint(self.allocator, "{s}_{}", .{ prefix, self.label_idx }) catch return CodegenError.OutOfMemory;
        self.label_idx += 1;
        return name;
    }

    fn newStringConst(self: *Codegen) CodegenError![]const u8 {
        const name = std.fmt.allocPrint(self.allocator, "SLA_STR_{}", .{self.string_idx}) catch return CodegenError.OutOfMemory;
        self.string_idx += 1;
        return name;
    }

    fn newMacroLocal(self: *Codegen, macro_name: []const u8, local_name: []const u8) CodegenError![]const u8 {
        const name = std.fmt.allocPrint(self.allocator, "{s}_{s}_uniq_{}", .{ macro_name, local_name, self.macro_local_idx }) catch return CodegenError.OutOfMemory;
        self.macro_local_idx += 1;
        self.macro_locals.put(local_name, name) catch return CodegenError.OutOfMemory;
        return name;
    }

    fn newInlineMacroLocal(self: *Codegen, macro_name: []const u8, local_name: []const u8) CodegenError![]const u8 {
        const name = std.fmt.allocPrint(self.allocator, "__sla_macro_{s}_{s}_{}", .{ macro_name, local_name, self.macro_local_idx }) catch return CodegenError.OutOfMemory;
        self.macro_local_idx += 1;
        return name;
    }

    // ---- Error diagnostics ----

    /// Records `msg` as the codegen failure reason unless one is already
    /// recorded. Prefer `fail()` over a bare `return CodegenError.CodegenError`
    /// at sites that know why generation failed; the CLI prints the message.
    fn recordErrorDetail(self: *Codegen, comptime fmt: []const u8, args: anytype) void {
        if (self.error_detail != null) return;
        self.error_detail = std.fmt.allocPrint(self.allocator, fmt, args) catch null;
    }

    /// Records a failure reason and returns CodegenError.CodegenError so
    /// call sites read as `return self.fail("macro `{s}` expects ...", ...)`.
    fn fail(self: *Codegen, comptime fmt: []const u8, args: anytype) CodegenError {
        self.recordErrorDetail(fmt, args);
        return CodegenError.CodegenError;
    }

    /// Short human description of an AST node for error context; caller owns
    /// the returned slice.
    fn describeDiagNode(self: *Codegen, node: *ast.Node) []const u8 {
        const tag = @tagName(node.*);
        return switch (node.*) {
            .let_stmt => |let| std.fmt.allocPrint(self.allocator, "let `{s}`", .{let.name}) catch self.allocator.dupe(u8, tag) catch "",
            .const_stmt => |c| std.fmt.allocPrint(self.allocator, "const `{s}`", .{c.name}) catch self.allocator.dupe(u8, tag) catch "",
            else => self.allocator.dupe(u8, tag) catch "",
        };
    }

    /// Called when an unannotated CodegenError escapes a tracked region:
    /// composes a detail line from the current function/statement/macro
    /// context if no deeper site already recorded a more specific reason.
    fn synthesizeDiagFromContext(self: *Codegen, err: anyerror) void {
        if (err != CodegenError.CodegenError or self.error_detail != null) return;
        var buf = std.ArrayList(u8).init(self.allocator);
        const w = buf.writer();
        w.writeAll("code generation failed") catch {};
        if (self.diag_func_name) |f| w.print(" in function `{s}`", .{f}) catch {};
        if (self.diag_stmt_node) |stmt| {
            const desc = self.describeDiagNode(stmt);
            defer self.allocator.free(desc);
            w.print(" at statement ({s})", .{desc}) catch {};
        }
        if (self.diag_macro_name) |m| {
            if (self.diag_call_arg_index) |idx| {
                w.print(" while expanding macro `{s}` (lowering argument #{d})", .{ m, idx }) catch {};
            } else {
                w.print(" while expanding macro `{s}`", .{m}) catch {};
            }
        }
        w.writeAll(" (no more specific diagnostic recorded)") catch {};
        self.error_detail = buf.toOwnedSlice() catch null;
    }

    pub fn errorDetail(self: *Codegen) ?[]const u8 {
        return self.error_detail;
    }


    fn genUserMacroBlockInline(
        self: *Codegen,
        macro_decl: *const ast.MacroDecl,
        body: []const *ast.Node,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        var scoped_aliases = std.ArrayList([]const u8).init(self.allocator);
        const SavedLocalType = struct {
            name: []const u8,
            old_ty: ?*const ast.Type,
        };
        var scoped_types = std.ArrayList(SavedLocalType).init(self.allocator);
        defer {
            var type_i = scoped_types.items.len;
            while (type_i > 0) {
                type_i -= 1;
                const saved = scoped_types.items[type_i];
                if (saved.old_ty) |ty| {
                    self.macro_arg_types.put(saved.name, ty) catch unreachable;
                } else {
                    _ = self.macro_arg_types.remove(saved.name);
                }
            }
            scoped_types.deinit();

            var i = scoped_aliases.items.len;
            while (i > 0) {
                i -= 1;
                self.popBindingAlias(scoped_aliases.items[i]);
            }
            scoped_aliases.deinit();
        }

        for (body) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| {
                    if (lowering_rules.isDiscardName(let.name)) {
                        try self.genStmt(stmt, hoisted_allocs);
                        continue;
                    }
                    const alias = try self.newInlineMacroLocal(macro_decl.name, let.name);
                    var let_copy = let;
                    let_copy.name = alias;
                    var node = ast.Node{ .let_stmt = let_copy };
                    try self.genStmt(&node, hoisted_allocs);
                    try self.pushBindingAliasTo(let.name, alias);
                    try scoped_aliases.append(let.name);
                    try scoped_types.append(.{ .name = let.name, .old_ty = self.macro_arg_types.get(let.name) });
                    if (let.ty) |explicit| {
                        self.macro_arg_types.put(let.name, explicit) catch return CodegenError.OutOfMemory;
                    } else if (self.resolvedTypeForExpr(let.value)) |inferred| {
                        self.macro_arg_types.put(let.name, inferred) catch return CodegenError.OutOfMemory;
                    } else {
                        _ = self.macro_arg_types.remove(let.name);
                    }
                },
                .block_stmt => |block| try self.genUserMacroBlockInline(macro_decl, block.body, hoisted_allocs),
                .for_stmt => |for_stmt| {
                    const alias = try self.newInlineMacroLocal(macro_decl.name, for_stmt.var_name);
                    try self.pushBindingAliasTo(for_stmt.var_name, alias);
                    try scoped_aliases.append(for_stmt.var_name);
                    const counter_slot = std.fmt.allocPrint(self.allocator, "{s}_slot", .{alias}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc 8\n", .{counter_slot}) catch return CodegenError.CodegenError;
                    var for_copy = for_stmt;
                    for_copy.var_name = alias;
                    var node = ast.Node{ .for_stmt = for_copy };
                    try self.genStmt(&node, hoisted_allocs);
                },
                else => try self.genStmt(stmt, hoisted_allocs),
            }
            if (self.async_pending_return_emitted) break;
        }
    }

    fn genUserMacroUnsafeValueInline(
        self: *Codegen,
        macro_decl: *const ast.MacroDecl,
        body: []const *ast.Node,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        if (body.len == 0 or body[body.len - 1].* != .expr_stmt) return CodegenError.CodegenError;

        var scoped_aliases = std.ArrayList([]const u8).init(self.allocator);
        const SavedLocalType = struct { name: []const u8, old_ty: ?*const ast.Type };
        var scoped_types = std.ArrayList(SavedLocalType).init(self.allocator);
        defer {
            var type_i = scoped_types.items.len;
            while (type_i > 0) {
                type_i -= 1;
                const saved = scoped_types.items[type_i];
                if (saved.old_ty) |ty| {
                    self.macro_arg_types.put(saved.name, ty) catch unreachable;
                } else {
                    _ = self.macro_arg_types.remove(saved.name);
                }
            }
            scoped_types.deinit();
            var alias_i = scoped_aliases.items.len;
            while (alias_i > 0) {
                alias_i -= 1;
                self.popBindingAlias(scoped_aliases.items[alias_i]);
            }
            scoped_aliases.deinit();
        }

        for (body[0 .. body.len - 1]) |stmt| {
            if (stmt.* == .let_stmt and !lowering_rules.isDiscardName(stmt.let_stmt.name)) {
                const let = stmt.let_stmt;
                const alias = try self.newInlineMacroLocal(macro_decl.name, let.name);
                var let_copy = let;
                let_copy.name = alias;
                var node = ast.Node{ .let_stmt = let_copy };
                try self.genStmt(&node, hoisted_allocs);
                try self.pushBindingAliasTo(let.name, alias);
                try scoped_aliases.append(let.name);
                try scoped_types.append(.{ .name = let.name, .old_ty = self.macro_arg_types.get(let.name) });
                if (let.ty) |explicit| {
                    self.macro_arg_types.put(let.name, explicit) catch return CodegenError.OutOfMemory;
                } else if (self.resolvedTypeForExpr(let.value)) |inferred| {
                    self.macro_arg_types.put(let.name, inferred) catch return CodegenError.OutOfMemory;
                }
            } else {
                try self.genStmt(stmt, hoisted_allocs);
            }
        }

        const last = body[body.len - 1];
        const value_expr = last.expr_stmt;
        const value_reg = try self.genExpr(value_expr, hoisted_allocs);
        const value_ty = self.resolvedTypeForExpr(value_expr) orelse return CodegenError.CodegenError;
        const result = try self.newTmp();
        if (value_expr.* == .identifier and value_ty.* == .primitive) {
            try self.emitPrimitiveCopy(result, value_reg, value_ty);
        } else {
            self.out.writer().print("    {s} = {s}\n", .{ result, value_reg }) catch return CodegenError.CodegenError;
        }
        if (self.tc.cleanups.get(last)) |list| {
            for (list.items) |name| try self.emitRelease(name);
        }
        return result;
    }

    /// Tracked wrapper: remembers which user macro was being expanded so a
    /// failing CodegenError can be reported with the macro's name.
    fn genUserMacroCallInline(
        self: *Codegen,
        macro_decl: *const ast.MacroDecl,
        call: *const ast.CallExpr,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        const prev_macro = self.diag_macro_name;
        self.diag_macro_name = macro_decl.name;
        const result = self.genUserMacroCallInlineImpl(macro_decl, call, hoisted_allocs);
        if (result) |_| {
            self.diag_macro_name = prev_macro;
            self.diag_call_arg_index = null;
        } else |err| {
            self.synthesizeDiagFromContext(err);
            self.diag_macro_name = prev_macro;
            self.diag_call_arg_index = null;
            return err;
        }
    }

    fn genUserMacroCallInlineImpl(
        self: *Codegen,
        macro_decl: *const ast.MacroDecl,
        call: *const ast.CallExpr,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        if (macro_decl.params.len != call.args.len) return self.fail("user macro `{s}` expects {d} argument(s), got {d}", .{ macro_decl.name, macro_decl.params.len, call.args.len });

        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
        defer arg_regs.deinit();
        var arg_types = std.ArrayList(?*const ast.Type).init(self.allocator);
        defer arg_types.deinit();
        for (call.args) |arg| {
            const arg_ty = self.resolvedTypeForExpr(arg);
            try arg_regs.append(try self.genExpr(arg, hoisted_allocs));
            try arg_types.append(arg_ty);
        }

        const SavedArg = struct {
            name: []const u8,
            old_expr: ?*const ast.Node,
            old_ty: ?*const ast.Type,
        };
        var saved_args = std.ArrayList(SavedArg).init(self.allocator);
        defer saved_args.deinit();

        var aliased_params = std.ArrayList([]const u8).init(self.allocator);
        defer {
            var i = aliased_params.items.len;
            while (i > 0) {
                i -= 1;
                self.popBindingAlias(aliased_params.items[i]);
            }
            aliased_params.deinit();
        }

        for (macro_decl.params, arg_regs.items, call.args, arg_types.items) |param, arg_reg, arg, arg_ty| {
            try saved_args.append(.{
                .name = param,
                .old_expr = self.macro_arg_exprs.get(param),
                .old_ty = self.macro_arg_types.get(param),
            });
            try self.pushBindingAliasTo(param, arg_reg);
            try aliased_params.append(param);
            self.macro_arg_exprs.put(param, arg) catch return CodegenError.OutOfMemory;
            if (arg_ty) |ty| {
                self.macro_arg_types.put(param, ty) catch return CodegenError.OutOfMemory;
            } else {
                _ = self.macro_arg_types.remove(param);
            }
        }
        defer {
            var i = saved_args.items.len;
            while (i > 0) {
                i -= 1;
                const saved = saved_args.items[i];
                if (saved.old_expr) |expr| {
                    self.macro_arg_exprs.put(saved.name, expr) catch unreachable;
                } else {
                    _ = self.macro_arg_exprs.remove(saved.name);
                }
                if (saved.old_ty) |ty| {
                    self.macro_arg_types.put(saved.name, ty) catch unreachable;
                } else {
                    _ = self.macro_arg_types.remove(saved.name);
                }
            }
        }

        self.macro_inline_depth += 1;
        defer self.macro_inline_depth -= 1;
        const previous_inline_macro = self.active_inline_macro;
        self.active_inline_macro = macro_decl;
        defer self.active_inline_macro = previous_inline_macro;
        const previous_try_cleanup = self.active_macro_try_cleanup;
        self.active_macro_try_cleanup = if (self.tc.macro_call_try_cleanups.get(call)) |list| list.items else previous_try_cleanup;
        defer self.active_macro_try_cleanup = previous_try_cleanup;
        try self.genUserMacroBlockInline(macro_decl, macro_decl.body, hoisted_allocs);
    }

    fn mangleMethodName(self: *Codegen, ty_name: []const u8, method_name: []const u8) CodegenError![]const u8 {
        return lowering_rules.mangleMethodName(self.allocator, ty_name, method_name) catch return CodegenError.OutOfMemory;
    }

    fn mangleTraitMethodName(self: *Codegen, ty_name: []const u8, trait_name: []const u8, method_name: []const u8) CodegenError![]const u8 {
        return lowering_rules.mangleTraitMethodName(self.allocator, ty_name, trait_name, method_name) catch return CodegenError.OutOfMemory;
    }

    fn loweredFuncSymbol(self: *Codegen, name: []const u8) CodegenError![]const u8 {
        if (lowering_rules.isMainName(name)) {
            return std.fmt.allocPrint(self.allocator, "{s}", .{name}) catch return CodegenError.OutOfMemory;
        }
        if (self.tc.funcs.get(name)) |func| {
            if (func.is_extern or func.no_mangle) {
                return std.fmt.allocPrint(self.allocator, "{s}", .{name}) catch return CodegenError.OutOfMemory;
            }
        }
        if (self.tc.extern_funcs.contains(name) or std.mem.startsWith(u8, name, "sa_")) {
            return std.fmt.allocPrint(self.allocator, "{s}", .{name}) catch return CodegenError.OutOfMemory;
        }
        return std.fmt.allocPrint(self.allocator, "sla__{s}", .{name}) catch return CodegenError.OutOfMemory;
    }

    fn traitMethodCount(self: *Codegen, trait_name: []const u8) ?usize {
        return lowering_rules.traitMethodCount(self.tc, trait_name);
    }

    fn dynMethodSlot(self: *Codegen, trait_name: []const u8, method_name: []const u8) ?usize {
        return lowering_rules.dynMethodSlot(self.tc, trait_name, method_name);
    }

    fn concreteTypeName(ty: *const ast.Type) ?[]const u8 {
        return lowering_rules.concreteTypeName(ty);
    }

    fn dynTraitName(ty: *const ast.Type) ?[]const u8 {
        return lowering_rules.dynTraitName(ty);
    }

    fn vtableName(self: *Codegen, trait_name: []const u8, type_name: []const u8) CodegenError![]const u8 {
        return lowering_rules.vtableName(self.allocator, trait_name, type_name) catch return CodegenError.OutOfMemory;
    }

    fn dynVtableUpcastName(self: *Codegen, from_trait: []const u8, to_trait: []const u8) CodegenError![]const u8 {
        return lowering_rules.dynVtableUpcastName(self.allocator, from_trait, to_trait) catch return CodegenError.OutOfMemory;
    }

    fn fnPtrVTableName(self: *Codegen, func_name: []const u8) CodegenError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "SLA_FNPTR_VT_{s}", .{func_name}) catch return CodegenError.OutOfMemory;
    }

    fn emitFunctionPointerVTableDecl(self: *Codegen, func_name: []const u8) CodegenError!void {
        const vt_name = try self.fnPtrVTableName(func_name);
        defer self.allocator.free(vt_name);
        const lowered = try self.loweredFuncSymbol(func_name);
        defer self.allocator.free(lowered);
        self.out.writer().print("@const {s} = vtable {{ call = @{s} }}\n", .{ vt_name, lowered }) catch return CodegenError.CodegenError;
    }

    fn emitTraitVTableDecl(self: *Codegen, decl: *const ast.ImplDecl) CodegenError!void {
        const trait_name = decl.trait_name orelse return;
        const type_name = concreteTypeName(decl.target_ty) orelse return CodegenError.CodegenError;
        const vt_name = try self.vtableName(trait_name, type_name);
        defer self.allocator.free(vt_name);

        self.out.writer().print("@const {s} = vtable {{ ", .{vt_name}) catch return CodegenError.CodegenError;
        var first = true;
        try self.emitTraitVTableEntries(trait_name, type_name, &first);
        self.out.writer().print(" }}\n", .{}) catch return CodegenError.CodegenError;
    }

    fn emitTraitVTableEntries(self: *Codegen, trait_name: []const u8, type_name: []const u8, first: *bool) CodegenError!void {
        const trait_decl = self.tc.traits.get(trait_name) orelse return CodegenError.CodegenError;
        for (trait_decl.supertraits) |supertrait| {
            try self.emitTraitVTableEntries(supertrait, type_name, first);
        }
        // Trait vtable slots reference concrete pub const functions emitted by codegen for @const vtables.
        // Imported trait impl methods are pruned to decl-only stubs when import expansion runs and the method is
        // not reachable (e.g. `load_reachable_imported_bodies_from_registry`). Such a method is not emitted as a function body:
        // leaving a vtable slot pointing to its symbol forces the SAB verifier (`parseVtableSlots`) to trap with
        // `error.UnknownRegister` because no function sig exists for it. Skip slots whose target impl method is decl-only,
        // matching what codegen emits function bodies for. Slots for methods not registered in `tc.funcs` retain prior behavior.
        for (trait_decl.methods) |method| {
            const mangled = try self.mangleTraitMethodName(type_name, trait_name, method.name);
            defer self.allocator.free(mangled);
            if (self.tc.funcs.get(mangled)) |impl_method| {
                if (impl_method.is_decl_only) continue;
            }
            if (!first.*) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
            first.* = false;
            const lowered = try self.loweredFuncSymbol(mangled);
            defer self.allocator.free(lowered);
            self.out.writer().print("{s} = @{s}", .{ method.name, lowered }) catch return CodegenError.CodegenError;
        }
    }

    fn genDynBorrowCoercionArg(self: *Codegen, arg: *ast.Node, trait_name: []const u8, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        const source_expr = if (arg.* == .borrow_expr) arg.borrow_expr.expr else arg;
        const source_ty = self.tc.expr_types.get(source_expr) orelse return CodegenError.CodegenError;
        const source_reg = try self.genExpr(source_expr, hoisted_allocs);
        const fat_reg = try self.newTmp();
        self.out.writer().print("    {s} = alloc Dyn_SIZE\n", .{fat_reg}) catch return CodegenError.CodegenError;
        if (dynTraitName(source_ty)) |_| {
            const data_reg = try self.newTmp();
            const vtable_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+Dyn_data as ptr\n", .{ data_reg, source_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = load {s}+Dyn_vtable as ptr\n", .{ vtable_reg, source_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    store {s}+Dyn_data, {s} as ptr\n", .{ fat_reg, data_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    store {s}+Dyn_vtable, {s} as ptr\n", .{ fat_reg, vtable_reg }) catch return CodegenError.CodegenError;
        } else {
            const type_name = concreteTypeName(source_ty) orelse return CodegenError.CodegenError;
            const vt_name = try self.vtableName(trait_name, type_name);
            defer self.allocator.free(vt_name);
            self.out.writer().print("    store {s}+Dyn_data, {s} as ptr\n", .{ fat_reg, source_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    store {s}+Dyn_vtable, &{s} as ptr\n", .{ fat_reg, vt_name }) catch return CodegenError.CodegenError;
            if (callArgNeedsRelease(source_expr)) try self.emitRelease(source_reg);
        }
        return fat_reg;
    }

    fn genDynBoxCoercionExpr(self: *Codegen, expr: *ast.Node, trait_name: []const u8, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        const expr_ty = self.tc.expr_types.get(expr) orelse return CodegenError.CodegenError;
        const inner_ty = boxInnerType(expr_ty) orelse return CodegenError.CodegenError;
        const type_name = concreteTypeName(inner_ty) orelse return CodegenError.CodegenError;
        const vt_name = try self.vtableName(trait_name, type_name);
        defer self.allocator.free(vt_name);

        const box_reg = try self.genExpr(expr, hoisted_allocs);
        const data_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+Box_value as ptr\n", .{ data_reg, box_reg }) catch return CodegenError.CodegenError;
        const fat_reg = try self.newTmp();
        self.out.writer().print("    {s} = alloc Dyn_SIZE\n", .{fat_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+Dyn_data, {s} as ptr\n", .{ fat_reg, data_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+Dyn_vtable, &{s} as ptr\n", .{ fat_reg, vt_name }) catch return CodegenError.CodegenError;
        try self.emitRelease(data_reg);
        try self.emitRelease(box_reg);
        return fat_reg;
    }

    fn genDynRcCoercionExpr(self: *Codegen, expr: *ast.Node, trait_name: []const u8, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        if (expr.* != .call_expr) return CodegenError.CodegenError;
        const call = expr.call_expr;
        if (call.args.len != 1) return CodegenError.CodegenError;

        const arg_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
        const type_name = concreteTypeName(arg_ty) orelse return CodegenError.CodegenError;
        const vt_name = try self.vtableName(trait_name, type_name);
        defer self.allocator.free(vt_name);

        const data_reg = try self.genExpr(call.args[0], hoisted_allocs);
        const fat_reg = try self.newTmp();
        self.out.writer().print("    {s} = alloc Dyn_SIZE\n", .{fat_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+Dyn_data, {s} as ptr\n", .{ fat_reg, data_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+Dyn_vtable, &{s} as ptr\n", .{ fat_reg, vt_name }) catch return CodegenError.CodegenError;
        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(data_reg);

        const rc_reg = try self.newTmp();
        self.out.writer().print("    EXPAND RC_NEW {s}, {s}\n", .{ rc_reg, fat_reg }) catch return CodegenError.CodegenError;
        try self.emitRelease(fat_reg);
        return rc_reg;
    }

    fn genDynCoercionExpr(self: *Codegen, expr: *ast.Node, plan: lowering_rules.DynCoercionPlan, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        if (plan.isBoxToDyn()) {
            return try self.genDynBoxCoercionExpr(expr, plan.trait_name, hoisted_allocs);
        }
        if (plan.isRcNewToDynRc()) {
            return try self.genDynRcCoercionExpr(expr, plan.trait_name, hoisted_allocs);
        }
        return CodegenError.CodegenError;
    }

    fn emitIntConst(self: *Codegen, target: []const u8, value: i64) CodegenError!void {
        self.out.writer().print("    {s} = {}\n", .{ target, value }) catch return CodegenError.CodegenError;
    }

    fn emitFloatConst(self: *Codegen, target: []const u8, value: f64) CodegenError!void {
        if (std.math.isFinite(value) and @floor(value) == value) {
            self.out.writer().print("    {s} = {d}.0\n", .{ target, value }) catch return CodegenError.CodegenError;
            return;
        }
        self.out.writer().print("    {s} = {d}\n", .{ target, value }) catch return CodegenError.CodegenError;
    }

    fn genLiteralValue(self: *Codegen, lit: ast.Literal) CodegenError![]const u8 {
        const reg = try self.newTmp();
        switch (lit) {
            .int_val => |v| try self.emitIntConst(reg, v),
            .float_val => |v| try self.emitFloatConst(reg, v),
            .bool_val => |v| try self.emitIntConst(reg, if (v) 1 else 0),
            .string_val => |v| {
                const label = try self.newStringConst();
                // Emit one trailing NUL so the constant can also be treated as a
                // C string (raw `ptr` CSTR scans terminate at the first zero byte).
                // Explicit-length slice users use `escapedStringByteLen(v)`, which
                // excludes this terminator, so visible output is unchanged.
                self.out.writer().print("    @const {s} = utf8:\"{s}\\0\"\n", .{ label, v }) catch return CodegenError.CodegenError;
                const len_reg = try self.newTmp();
                try self.emitIntConst(len_reg, @as(i64, @intCast(escapedStringByteLen(v))));
                self.stack_alloc_bindings.put(reg, {}) catch return CodegenError.OutOfMemory;
                self.out.writer().print("    {s} = stack_alloc Slice_SIZE\n", .{reg}) catch return CodegenError.CodegenError;
                self.out.writer().print("    EXPAND SLICE_NEW {s}, &{s}, {s}\n", .{ reg, label, len_reg }) catch return CodegenError.CodegenError;
                try self.emitRelease(len_reg);
            },
        }
        return reg;
    }

    fn blockTerminates(block: []const *ast.Node) bool {
        return lowering_rules.blockTerminates(block);
    }

    fn stmtTerminates(stmt: *const ast.Node) bool {
        return lowering_rules.stmtTerminates(stmt);
    }

    fn emitRelease(self: *Codegen, name: []const u8) CodegenError!void {
        const resolved_name = self.resolveBindingName(name);
        if (lowering_rules.isInternalSymbol(resolved_name)) return;
        const borrow_temp_release = lowering_rules.planBorrowAddressTempRelease(self.borrow_source_temps.contains(resolved_name));
        if (borrow_temp_release.release_source_temps) {
            if (self.borrow_source_temps.get(resolved_name)) |source_temp| {
                _ = self.borrow_source_temps.remove(resolved_name);
                if (borrow_temp_release.release_borrow_value and !self.consumed_bindings.contains(resolved_name)) {
                    self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    !{s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
                }
                try self.emitRelease(source_temp);
                return;
            }
        }
        if (self.refcell_borrow_handles.get(resolved_name)) |handle| {
            _ = self.refcell_borrow_handles.remove(resolved_name);
            const has_owner_temp = if (handle.cell_release_temp) |temp| !std.mem.eql(u8, temp, resolved_name) else false;
            const release_plan = lowering_rules.planRefCellHandleRelease(has_owner_temp);
            if (release_plan.consume_handle_value) self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            if (release_plan.release_dynamic_borrow) {
                self.out.writer().print("    EXPAND {s} {s}\n", .{ lowering_rules.refCellBorrowReleaseMacroName(handle.kind), handle.cell_reg }) catch return CodegenError.CodegenError;
            }
            if (release_plan.consume_handle_value) self.out.writer().print("    !{s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
            if (handle.cell_release_temp) |temp| {
                if (release_plan.release_owner_temps) try self.emitRelease(temp);
            }
            return;
        }
        if (self.mutex_guard_handles.get(resolved_name)) |handle| {
            self.out.writer().print("    EXPAND MUTEX_UNLOCK {s}\n", .{handle.mutex_reg}) catch return CodegenError.CodegenError;
            try self.releaseTemporaryHandleRegister(handle.mutex_reg);
            _ = self.mutex_guard_handles.remove(resolved_name);
            self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            self.out.writer().print("    !{s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
            return;
        }
        if (self.mutex_lock_results.get(resolved_name)) |handle| {
            self.out.writer().print("    EXPAND MUTEX_UNLOCK {s}\n", .{handle.mutex_reg}) catch return CodegenError.CodegenError;
            try self.releaseTemporaryHandleRegister(handle.mutex_reg);
            _ = self.mutex_lock_results.remove(resolved_name);
            self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            self.out.writer().print("    !{s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
            return;
        }
        if (self.rwlock_guard_handles.get(resolved_name)) |handle| {
            if (handle.is_write) {
                self.out.writer().print("    EXPAND RWLOCK_RELEASE_WRITE {s}\n", .{handle.lock_reg}) catch return CodegenError.CodegenError;
            } else {
                self.out.writer().print("    EXPAND RWLOCK_RELEASE_READ {s}\n", .{handle.lock_reg}) catch return CodegenError.CodegenError;
            }
            try self.releaseTemporaryHandleRegister(handle.lock_reg);
            _ = self.rwlock_guard_handles.remove(resolved_name);
            self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            self.out.writer().print("    !{s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
            return;
        }
        if (self.rwlock_lock_results.get(resolved_name)) |handle| {
            if (handle.is_write) {
                self.out.writer().print("    EXPAND RWLOCK_RELEASE_WRITE {s}\n", .{handle.lock_reg}) catch return CodegenError.CodegenError;
            } else {
                self.out.writer().print("    EXPAND RWLOCK_RELEASE_READ {s}\n", .{handle.lock_reg}) catch return CodegenError.CodegenError;
            }
            try self.releaseTemporaryHandleRegister(handle.lock_reg);
            _ = self.rwlock_lock_results.remove(resolved_name);
            self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            self.out.writer().print("    !{s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
            return;
        }
        if (self.file_bindings.contains(resolved_name)) {
            const close_status = try self.newTmp();
            self.out.writer().print("    EXPAND FS_CLOSE {s}, {s}\n", .{ close_status, resolved_name }) catch return CodegenError.CodegenError;
            try self.emitRelease(close_status);
            self.out.writer().print("    !{s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
            _ = self.file_bindings.remove(resolved_name);
            self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            return;
        }
        if (self.file_open_results.contains(resolved_name)) {
            _ = self.file_open_results.remove(resolved_name);
        }
        if (self.metadata_bindings.contains(resolved_name)) {
            const close_status = try self.newTmp();
            self.out.writer().print("    EXPAND FS_METADATA_FREE {s}, {s}\n", .{ close_status, resolved_name }) catch return CodegenError.CodegenError;
            try self.emitRelease(close_status);
            _ = self.metadata_bindings.remove(resolved_name);
            self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            return;
        }
        if (self.metadata_open_results.contains(resolved_name)) {
            _ = self.metadata_open_results.remove(resolved_name);
        }
        var handles_to_release = std.ArrayList([]const u8).init(self.allocator);
        defer handles_to_release.deinit();
        var handle_iter = self.refcell_borrow_handles.iterator();
        while (handle_iter.next()) |entry| {
            const release_action = lowering_rules.planRefCellHandleCellRelease(
                std.mem.eql(u8, entry.value_ptr.cell_reg, resolved_name),
                std.mem.eql(u8, entry.key_ptr.*, resolved_name),
            );
            if (release_action.shouldRelease()) handles_to_release.append(entry.key_ptr.*) catch return CodegenError.OutOfMemory;
        }
        for (handles_to_release.items) |handle_name| {
            if (self.refcell_borrow_handles.get(handle_name)) |handle| {
                _ = self.refcell_borrow_handles.remove(handle_name);
                const has_owner_temp = if (handle.cell_release_temp) |temp| !std.mem.eql(u8, temp, handle_name) else false;
                const release_plan = lowering_rules.planRefCellHandleRelease(has_owner_temp);
                if (release_plan.consume_handle_value) self.consumed_bindings.put(handle_name, {}) catch return CodegenError.OutOfMemory;
                if (release_plan.release_dynamic_borrow) {
                    self.out.writer().print("    EXPAND {s} {s}\n", .{ lowering_rules.refCellBorrowReleaseMacroName(handle.kind), handle.cell_reg }) catch return CodegenError.CodegenError;
                }
                if (handle.cell_release_temp) |temp| {
                    if (release_plan.release_owner_temps) try self.emitRelease(temp);
                }
            }
        }
        if (std.mem.startsWith(u8, resolved_name, "&")) return;
        if (std.mem.startsWith(u8, resolved_name, "^")) return;
        if (self.stack_alloc_bindings.contains(resolved_name)) {
            if (try self.releaseResultSlotRefCellHandle(resolved_name, true)) {
                self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            }
            return;
        }
        if (self.global_const_bindings.contains(resolved_name)) return;
        if (self.consumed_bindings.contains(resolved_name)) return;
        if (self.mpsc_sender_bindings.contains(resolved_name)) return;
        if (self.mpsc_receiver_bindings.contains(resolved_name)) {
            self.out.writer().print("    EXPAND MPSC_FREE {s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
            self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            return;
        }
        if (self.string_buf_bindings.contains(resolved_name)) {
            self.out.writer().print("    EXPAND STRING_BUF_FREE {s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
            self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            return;
        }
        if (self.hashmap_bindings.contains(resolved_name)) {
            self.out.writer().print("    EXPAND MAP_FREE {s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
            self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            return;
        }
        if (self.btree_map_bindings.contains(resolved_name)) {
            self.out.writer().print("    EXPAND BTREE_MAP_FREE {s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
            self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            return;
        }
        if (self.hashset_bindings.contains(resolved_name)) {
            self.out.writer().print("    EXPAND SET_FREE {s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
            self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            return;
        }
        if (self.btree_set_bindings.contains(resolved_name)) {
            self.out.writer().print("    EXPAND BTREE_SET_FREE {s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
            self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
            return;
        }
        self.out.writer().print("    !{s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
        self.consumed_bindings.put(resolved_name, {}) catch return CodegenError.OutOfMemory;
        _ = self.future_state_vtables.remove(resolved_name);
        _ = self.future_readiness.remove(resolved_name);
        if (self.task_future_objects.get(resolved_name)) |future_obj| {
            _ = self.task_future_objects.remove(resolved_name);
            if (!self.consumed_bindings.contains(future_obj)) {
                self.out.writer().print("    !{s}\n", .{future_obj}) catch return CodegenError.CodegenError;
                self.consumed_bindings.put(future_obj, {}) catch return CodegenError.OutOfMemory;
            }
        }
    }

    fn markConsumedBinding(self: *Codegen, name: []const u8) CodegenError!void {
        self.consumed_bindings.put(name, {}) catch return CodegenError.OutOfMemory;
    }

    fn markMovedExprBinding(self: *Codegen, expr: *const ast.Node, reg: []const u8) CodegenError!void {
        if (lowering_rules.rootIdentifier(expr)) |name| return try self.markConsumedBinding(name);
        if (std.mem.startsWith(u8, reg, "^") or std.mem.startsWith(u8, reg, "&")) {
            return try self.markConsumedBinding(reg[1..]);
        }
        try self.markConsumedBinding(reg);
    }

    fn rebindRefCellBorrowHandleOwners(self: *Codegen, src: []const u8, dst: []const u8) void {
        if (std.mem.eql(u8, src, dst)) return;
        var iter = self.refcell_borrow_handles.valueIterator();
        while (iter.next()) |handle| {
            const owner_transfer = lowering_rules.planRefCellHandleOwnerTransfer(std.mem.eql(u8, handle.cell_reg, src));
            if (owner_transfer.rebindsOwner()) {
                handle.cell_reg = dst;
                if (handle.cell_release_temp) |temp| {
                    if (std.mem.eql(u8, temp, src)) handle.cell_release_temp = dst;
                }
            }
        }
    }

    fn emitLexicalCleanupRelease(self: *Codegen, name: []const u8) CodegenError!void {
        const resolved_name = self.resolveBindingName(name);
        try self.emitRelease(resolved_name);
    }

    fn pushLoopBodyLocalScope(self: *Codegen) CodegenError!void {
        self.loop_body_local_scopes.append(std.ArrayList([]const u8).init(self.allocator)) catch return CodegenError.OutOfMemory;
        self.loop_body_block_depths.append(0) catch return CodegenError.OutOfMemory;
    }

    fn popLoopBodyLocalScope(self: *Codegen) void {
        if (self.loop_body_local_scopes.items.len > 0) {
            var scope = self.loop_body_local_scopes.pop().?;
            scope.deinit();
        }
        if (self.loop_body_block_depths.items.len > 0) _ = self.loop_body_block_depths.pop();
    }

    fn enterBlockForLoopLocalTracking(self: *Codegen) void {
        for (self.loop_body_block_depths.items) |*depth| {
            depth.* += 1;
        }
    }

    fn leaveBlockForLoopLocalTracking(self: *Codegen) void {
        for (self.loop_body_block_depths.items) |*depth| {
            depth.* -= 1;
        }
    }

    fn rememberLoopBodyTopLevelLocal(self: *Codegen, name: []const u8) CodegenError!void {
        if (self.loop_body_local_scopes.items.len == 0) return;
        const scope_index = self.loop_body_local_scopes.items.len - 1;
        if (self.loop_body_block_depths.items[scope_index] > 1) return;
        self.loop_body_local_scopes.items[scope_index].append(name) catch return CodegenError.OutOfMemory;
    }

    fn cleanupListContainsName(self: *Codegen, list: ?*const std.ArrayList([]const u8), name: []const u8) bool {
        const cleanup_list = list orelse return false;
        const resolved_name = self.resolveBindingName(name);
        for (cleanup_list.items) |item| {
            if (std.mem.eql(u8, self.resolveBindingName(item), resolved_name)) return true;
        }
        return false;
    }

    fn emitLoopBodyLocalCleanup(self: *Codegen, name: []const u8, force_consumed_primitive: bool) CodegenError!void {
        const resolved_name = self.resolveBindingName(name);
        if (self.local_binding_types.get(resolved_name)) |ty| {
            if (force_consumed_primitive and ty.* == .primitive and self.consumed_bindings.contains(resolved_name)) {
                self.out.writer().print("    !{s}\n", .{resolved_name}) catch return CodegenError.CodegenError;
                return;
            }
        }
        try self.emitRelease(resolved_name);
    }

    fn activeLoopBodyLocalContainsName(self: *Codegen, name: []const u8) bool {
        if (self.loop_body_local_scopes.items.len == 0) return false;
        const resolved_name = self.resolveBindingName(name);
        const scope = &self.loop_body_local_scopes.items[self.loop_body_local_scopes.items.len - 1];
        for (scope.items) |item| {
            if (std.mem.eql(u8, self.resolveBindingName(item), resolved_name)) return true;
        }
        return false;
    }

    fn emitActiveLoopBodyLocalCleanups(self: *Codegen, skip_list: ?*const std.ArrayList([]const u8), force_consumed_primitive: bool) CodegenError!void {
        if (self.loop_body_local_scopes.items.len == 0) return;
        const scope = &self.loop_body_local_scopes.items[self.loop_body_local_scopes.items.len - 1];
        var i = scope.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.cleanupListContainsName(skip_list, scope.items[i])) {
                try self.emitLoopBodyLocalCleanup(scope.items[i], force_consumed_primitive);
            }
        }
    }

    fn transferResultSlotValueState(self: *Codegen, dst: []const u8, src: []const u8, mark_consumed: bool) CodegenError!void {
        if (std.mem.eql(u8, dst, src)) return;

        self.rebindRefCellBorrowHandleOwners(src, dst);

        if (self.task_future_objects.get(src)) |future_obj| {
            self.task_future_objects.put(dst, future_obj) catch return CodegenError.OutOfMemory;
            _ = self.task_future_objects.remove(src);
        }
        if (self.future_state_vtables.get(src)) |vt_name| {
            self.future_state_vtables.put(dst, vt_name) catch return CodegenError.OutOfMemory;
            _ = self.future_state_vtables.remove(src);
        }
        if (self.future_readiness.get(src)) |state| {
            self.future_readiness.put(dst, state) catch return CodegenError.OutOfMemory;
            _ = self.future_readiness.remove(src);
        }
        if (self.executor_task_counts.get(src)) |task_count| {
            self.executor_task_counts.put(dst, task_count) catch return CodegenError.OutOfMemory;
            _ = self.executor_task_counts.remove(src);
        }
        if (self.mpsc_sender_bindings.contains(src)) {
            self.mpsc_sender_bindings.put(dst, {}) catch return CodegenError.OutOfMemory;
            if (self.mpsc_sender_channels.get(src)) |chan| {
                self.mpsc_sender_channels.put(dst, chan) catch return CodegenError.OutOfMemory;
            }
            _ = self.mpsc_sender_bindings.remove(src);
            _ = self.mpsc_sender_channels.remove(src);
            if (mark_consumed) try self.markConsumedBinding(src);
        }
        const refcell_transfer_plan = lowering_rules.planRefCellValueStateTransfer(
            self.refcell_borrow_handles.contains(src),
            self.borrow_source_temps.contains(src),
        );
        if (refcell_transfer_plan.borrow_address_temps.movesBorrowAddressTemps()) {
            if (self.borrow_source_temps.get(src)) |source_temp| {
                self.borrow_source_temps.put(dst, source_temp) catch return CodegenError.OutOfMemory;
                _ = self.borrow_source_temps.remove(src);
            }
        }
        if (refcell_transfer_plan.handle.movesBorrowHandle()) {
            if (self.refcell_borrow_handles.get(src)) |handle| {
                self.refcell_borrow_handles.put(dst, handle) catch return CodegenError.OutOfMemory;
                _ = self.refcell_borrow_handles.remove(src);
                if (mark_consumed) try self.markConsumedBinding(src);
            }
        }
        if (self.mutex_guard_handles.get(src)) |handle| {
            self.mutex_guard_handles.put(dst, handle) catch return CodegenError.OutOfMemory;
            _ = self.mutex_guard_handles.remove(src);
            if (mark_consumed) try self.markConsumedBinding(src);
        }
        if (self.mutex_lock_results.get(src)) |handle| {
            self.mutex_lock_results.put(dst, handle) catch return CodegenError.OutOfMemory;
            _ = self.mutex_lock_results.remove(src);
            if (mark_consumed) try self.markConsumedBinding(src);
        }
        if (self.rwlock_guard_handles.get(src)) |handle| {
            self.rwlock_guard_handles.put(dst, handle) catch return CodegenError.OutOfMemory;
            _ = self.rwlock_guard_handles.remove(src);
            if (mark_consumed) try self.markConsumedBinding(src);
        }
        if (self.rwlock_lock_results.get(src)) |handle| {
            self.rwlock_lock_results.put(dst, handle) catch return CodegenError.OutOfMemory;
            _ = self.rwlock_lock_results.remove(src);
            if (mark_consumed) try self.markConsumedBinding(src);
        }
        if (self.file_bindings.contains(src)) {
            self.file_bindings.put(dst, {}) catch return CodegenError.OutOfMemory;
            _ = self.file_bindings.remove(src);
            if (mark_consumed) try self.markConsumedBinding(src);
        }
        if (self.file_open_results.get(src)) |handle| {
            self.file_open_results.put(dst, handle) catch return CodegenError.OutOfMemory;
            _ = self.file_open_results.remove(src);
            if (mark_consumed) try self.markConsumedBinding(src);
        }
        if (self.metadata_bindings.contains(src)) {
            self.metadata_bindings.put(dst, {}) catch return CodegenError.OutOfMemory;
            _ = self.metadata_bindings.remove(src);
            if (mark_consumed) try self.markConsumedBinding(src);
        }
        if (self.metadata_open_results.get(src)) |handle| {
            self.metadata_open_results.put(dst, handle) catch return CodegenError.OutOfMemory;
            _ = self.metadata_open_results.remove(src);
            if (mark_consumed) try self.markConsumedBinding(src);
        }
    }

    fn ensureResultSlotRefCellHandle(self: *Codegen, slot: []const u8, kind: lowering_rules.RefCellBorrowKind) CodegenError!ResultSlotRefCellHandle {
        if (self.result_slot_refcell_handles.get(slot)) |existing| {
            const updated = ResultSlotRefCellHandle{ .cell_slot = existing.cell_slot, .kind = kind };
            self.result_slot_refcell_handles.put(slot, updated) catch return CodegenError.OutOfMemory;
            return updated;
        }
        const cell_slot = try self.ensureResultSlotRefCellSlot(slot);
        const meta = ResultSlotRefCellHandle{ .cell_slot = cell_slot, .kind = kind };
        self.result_slot_refcell_handles.put(slot, meta) catch return CodegenError.OutOfMemory;
        return meta;
    }

    fn ensureResultSlotRefCellSlot(self: *Codegen, slot: []const u8) CodegenError![]const u8 {
        if (self.result_slot_refcell_slots.get(slot)) |existing| return existing;
        const cell_slot = try self.newTmp();
        self.out.writer().print("    {s} = alloc 8\n", .{cell_slot}) catch return CodegenError.CodegenError;
        self.result_slot_refcell_slots.put(slot, cell_slot) catch return CodegenError.OutOfMemory;
        return cell_slot;
    }

    fn prepareResultSlotRefCellCompanion(self: *Codegen, slot: []const u8, target_ty: *const ast.Type) CodegenError!void {
        if (!lowering_rules.planResultSlotTransfer(target_ty).needs_refcell_companion) return;
        _ = try self.ensureResultSlotRefCellSlot(slot);
    }

    fn storeResultSlotTransferredValueState(self: *Codegen, slot: []const u8, src: []const u8, target_ty: *const ast.Type, source_needs_release: bool) CodegenError!void {
        const plan = lowering_rules.planResultSlotTransfer(target_ty);
        const store_lifecycle = lowering_rules.planResultSlotStoreLifecycle(plan, source_needs_release);
        if (store_lifecycle.releasesSource()) return self.emitRelease(src);
        if (!store_lifecycle.transfersValueState()) return;
        const refcell_handle = self.refcell_borrow_handles.get(src);
        const refcell_store = lowering_rules.planResultSlotRefCellStore(plan, refcell_handle != null);
        if (refcell_store.storesBorrowHandleCompanion()) {
            const handle = refcell_handle.?;
            const meta = try self.ensureResultSlotRefCellHandle(slot, handle.kind);
            self.out.writer().print("    store {s}+0, {s} as ptr\n", .{ meta.cell_slot, handle.cell_reg }) catch return CodegenError.CodegenError;
            _ = self.refcell_borrow_handles.remove(src);
            const cleanup_plan = lowering_rules.planRefCellCompanionStoreCleanup(
                if (handle.cell_release_temp) |temp| !std.mem.eql(u8, temp, src) else false,
                false,
                false,
            );
            if (cleanup_plan.consume_handle_value) try self.markConsumedBinding(src);
            if (handle.cell_release_temp) |temp| {
                if (cleanup_plan.release_owner_temps) try self.emitRelease(temp);
            }
        }
        try self.transferResultSlotValueState(slot, src, true);
    }

    fn loadResultSlotTransferredValueState(self: *Codegen, dst: []const u8, slot: []const u8, target_ty: *const ast.Type) CodegenError!void {
        const plan = lowering_rules.planResultSlotTransfer(target_ty);
        if (!lowering_rules.planResultSlotLoadLifecycle(plan).loadsValueState()) return;
        const refcell_load = lowering_rules.planResultSlotRefCellLoad(
            plan,
            self.result_slot_refcell_handles.contains(slot),
            self.result_slot_refcell_slots.contains(slot),
        );
        if (refcell_load.restoresBorrowHandleCompanion()) {
            if (self.result_slot_refcell_handles.fetchRemove(slot)) |entry| {
                _ = self.result_slot_refcell_slots.fetchRemove(slot);
                const cell_reg = try self.newTmp();
                const restore_plan = lowering_rules.planRefCellCompanionRestore();
                self.out.writer().print("    {s} = load {s}+0 as ptr\n", .{ cell_reg, entry.value.cell_slot }) catch return CodegenError.CodegenError;
                self.refcell_borrow_handles.put(dst, .{
                    .cell_reg = cell_reg,
                    .kind = entry.value.kind,
                    .cell_release_temp = if (restore_plan.track_loaded_cell_owner_temp) cell_reg else null,
                }) catch return CodegenError.OutOfMemory;
                if (restore_plan.release_companion_slot_after_restore) try self.emitRelease(entry.value.cell_slot);
            }
        } else if (refcell_load.releasesEmptyCompanion()) {
            if (self.result_slot_refcell_slots.fetchRemove(slot)) |entry| {
                try self.emitRelease(entry.value);
            }
        }
        try self.transferResultSlotValueState(dst, slot, false);
    }

    fn releaseResultSlotRefCellHandle(self: *Codegen, slot: []const u8, remove_companion: bool) CodegenError!bool {
        if (self.result_slot_refcell_handles.get(slot)) |entry| {
            const cell_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as ptr\n", .{ cell_reg, entry.cell_slot }) catch return CodegenError.CodegenError;
            self.out.writer().print("    EXPAND {s} {s}\n", .{ lowering_rules.refCellBorrowReleaseMacroName(entry.kind), cell_reg }) catch return CodegenError.CodegenError;
            try self.emitRelease(cell_reg);
            if (remove_companion) {
                _ = self.result_slot_refcell_handles.remove(slot);
                _ = self.result_slot_refcell_slots.remove(slot);
                try self.emitRelease(entry.cell_slot);
            }
            return true;
        }
        return false;
    }

    fn releaseTemporaryHandleRegister(self: *Codegen, handle_reg: []const u8) CodegenError!void {
        if (!isTemporaryRegisterName(handle_reg)) return;
        if (self.consumed_bindings.contains(handle_reg)) return;
        self.out.writer().print("    !{s}\n", .{handle_reg}) catch return CodegenError.CodegenError;
        self.consumed_bindings.put(handle_reg, {}) catch return CodegenError.OutOfMemory;
    }

    fn isTemporaryRegisterName(name: []const u8) bool {
        return lowering_rules.isTemporaryRegisterName(name);
    }

    fn restoreConsumedBindings(self: *Codegen, saved: *std.StringHashMap(void)) CodegenError!void {
        self.consumed_bindings.clearRetainingCapacity();
        var iter = saved.iterator();
        while (iter.next()) |entry| {
            self.consumed_bindings.put(entry.key_ptr.*, entry.value_ptr.*) catch return CodegenError.OutOfMemory;
        }
    }

    fn restoreBorrowSourceTemps(self: *Codegen, saved: *std.StringHashMap([]const u8)) CodegenError!void {
        self.borrow_source_temps.clearRetainingCapacity();
        var iter = saved.iterator();
        while (iter.next()) |entry| {
            self.borrow_source_temps.put(entry.key_ptr.*, entry.value_ptr.*) catch return CodegenError.OutOfMemory;
        }
    }

    fn restoreRefCellBorrowHandles(self: *Codegen, saved: *std.StringHashMap(RefCellBorrowHandle)) CodegenError!void {
        self.refcell_borrow_handles.clearRetainingCapacity();
        var iter = saved.iterator();
        while (iter.next()) |entry| {
            self.refcell_borrow_handles.put(entry.key_ptr.*, entry.value_ptr.*) catch return CodegenError.OutOfMemory;
        }
    }

    fn restoreResultSlotRefCellState(
        self: *Codegen,
        handles: *std.StringHashMap(ResultSlotRefCellHandle),
        slots: *std.StringHashMap([]const u8),
    ) CodegenError!void {
        self.result_slot_refcell_handles.clearRetainingCapacity();
        var handle_iter = handles.iterator();
        while (handle_iter.next()) |entry| {
            self.result_slot_refcell_handles.put(entry.key_ptr.*, entry.value_ptr.*) catch return CodegenError.OutOfMemory;
        }
        self.result_slot_refcell_slots.clearRetainingCapacity();
        var slot_iter = slots.iterator();
        while (slot_iter.next()) |entry| {
            self.result_slot_refcell_slots.put(entry.key_ptr.*, entry.value_ptr.*) catch return CodegenError.OutOfMemory;
        }
    }

    fn emitBranchScopedCleanupList(self: *Codegen, names: []const []const u8) CodegenError!void {
        var saved_consumed = self.consumed_bindings.clone() catch return CodegenError.OutOfMemory;
        defer saved_consumed.deinit();
        var saved_borrow_sources = self.borrow_source_temps.clone() catch return CodegenError.OutOfMemory;
        defer saved_borrow_sources.deinit();
        var saved_refcell_handles = self.refcell_borrow_handles.clone() catch return CodegenError.OutOfMemory;
        defer saved_refcell_handles.deinit();

        for (names) |name| try self.emitRelease(name);

        try self.restoreConsumedBindings(&saved_consumed);
        try self.restoreBorrowSourceTemps(&saved_borrow_sources);
        try self.restoreRefCellBorrowHandles(&saved_refcell_handles);
    }

    fn emitBranchScopedCleanupForNode(self: *Codegen, node: *const ast.Node) CodegenError!void {
        if (self.active_macro_try_cleanup) |names| return try self.emitBranchScopedCleanupList(names);
        if (self.tc.cleanups.get(node)) |list| try self.emitBranchScopedCleanupList(list.items);
    }

    fn emitAwaitPendingCleanups(self: *Codegen, await_expr: *const ast.Node) CodegenError!void {
        if (self.tc.await_cleanups.get(await_expr)) |list| try self.emitBranchScopedCleanupList(list.items);
    }

    fn emitFunctionTailCleanups(self: *Codegen, stmt: *const ast.Node, tail_expr: *const ast.Node) CodegenError!void {
        if (self.tc.cleanups.get(stmt)) |list| {
            for (list.items) |name| {
                if ((try self.planFunctionResultCleanup(name, tail_expr)).releasesValue()) try self.emitRelease(name);
            }
        }
    }

    fn planFunctionResultCleanup(self: *Codegen, cleanup_name: []const u8, result_expr: *const ast.Node) CodegenError!lowering_rules.FunctionTailCleanupAction {
        const base_plan = lowering_rules.planFunctionTailCleanup(cleanup_name, result_expr);
        if (base_plan.transfersResult()) return base_plan;
        const root_name = lowering_rules.rootIdentifier(result_expr) orelse return base_plan;
        if (!std.mem.eql(u8, cleanup_name, root_name)) return base_plan;
        const result_ty = self.resolvedTypeForExpr(result_expr) orelse self.tc.expr_types.get(result_expr) orelse return base_plan;
        if (self.typeIsCopyValue(result_ty)) return base_plan;
        if (lowering_rules.isBorrowLikeType(result_ty)) return base_plan;
        return .transfer_result;
    }

    fn restoreRefCellBranchState(
        self: *Codegen,
        handles: *std.StringHashMap(RefCellBorrowHandle),
        borrow_sources: *std.StringHashMap([]const u8),
    ) CodegenError!void {
        try self.restoreRefCellBorrowHandles(handles);
        try self.restoreBorrowSourceTemps(borrow_sources);
    }

    fn setMergeRefCellBranchState(
        self: *Codegen,
        then_terminated: bool,
        then_handles: *std.StringHashMap(RefCellBorrowHandle),
        then_borrow_sources: *std.StringHashMap([]const u8),
        else_terminated: bool,
        else_handles: *std.StringHashMap(RefCellBorrowHandle),
        else_borrow_sources: *std.StringHashMap([]const u8),
        pre_handles: *std.StringHashMap(RefCellBorrowHandle),
        pre_borrow_sources: *std.StringHashMap([]const u8),
    ) CodegenError!void {
        const merge_action = lowering_rules.planRefCellBranchStateMerge(then_terminated, else_terminated);
        if (merge_action.restoresPre()) return try self.restoreRefCellBranchState(pre_handles, pre_borrow_sources);
        if (merge_action.restoresThen()) return try self.restoreRefCellBranchState(then_handles, then_borrow_sources);
        if (merge_action.restoresElse()) return try self.restoreRefCellBranchState(else_handles, else_borrow_sources);
    }

    fn prepareRefCellBranchHandleOwnerMergeSlots(
        self: *Codegen,
        pre_handles: *std.StringHashMap(RefCellBorrowHandle),
        slots: *std.StringHashMap(BranchRefCellHandleOwnerMergeSlot),
    ) CodegenError!void {
        var iter = pre_handles.iterator();
        while (iter.next()) |entry| {
            const cell_slot = try self.newTmp();
            self.out.writer().print("    {s} = alloc 8\n", .{cell_slot}) catch return CodegenError.CodegenError;
            slots.put(entry.key_ptr.*, .{
                .cell_slot = cell_slot,
                .kind = entry.value_ptr.kind,
            }) catch return CodegenError.OutOfMemory;
        }
    }

    fn storeRefCellBranchHandleOwnerMergeSlots(
        self: *Codegen,
        slots: *std.StringHashMap(BranchRefCellHandleOwnerMergeSlot),
        handles: *std.StringHashMap(RefCellBorrowHandle),
    ) CodegenError!void {
        var iter = slots.iterator();
        while (iter.next()) |entry| {
            if (handles.get(entry.key_ptr.*)) |handle| {
                self.out.writer().print("    store {s}+0, {s} as ptr\n", .{ entry.value_ptr.cell_slot, handle.cell_reg }) catch return CodegenError.CodegenError;
            }
        }
    }

    fn loadRefCellBranchHandleOwnerMergeSlots(
        self: *Codegen,
        slots: *std.StringHashMap(BranchRefCellHandleOwnerMergeSlot),
        then_terminated: bool,
        then_handles: *std.StringHashMap(RefCellBorrowHandle),
        else_terminated: bool,
        else_handles: *std.StringHashMap(RefCellBorrowHandle),
    ) CodegenError!void {
        var iter = slots.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const then_handle = if (!then_terminated) then_handles.get(key) else null;
            const else_handle = if (!else_terminated) else_handles.get(key) else null;
            const action = lowering_rules.planRefCellBranchHandleOwnerMerge(
                then_handle != null,
                else_handle != null,
                then_handle != null and else_handle != null and then_handle.?.kind == else_handle.?.kind,
                then_handle != null and else_handle != null and std.mem.eql(u8, then_handle.?.cell_reg, else_handle.?.cell_reg),
            );
            if (action.isMergeDynamicOwner()) {
                const cell_reg = try self.newTmp();
                const restore_plan = lowering_rules.planRefCellCompanionRestore();
                self.out.writer().print("    {s} = load {s}+0 as ptr\n", .{ cell_reg, entry.value_ptr.cell_slot }) catch return CodegenError.CodegenError;
                self.refcell_borrow_handles.put(key, .{
                    .cell_reg = cell_reg,
                    .kind = then_handle.?.kind,
                    .cell_release_temp = if (restore_plan.track_loaded_cell_owner_temp) cell_reg else null,
                }) catch return CodegenError.OutOfMemory;
                if (restore_plan.release_companion_slot_after_restore) try self.emitRelease(entry.value_ptr.cell_slot);
            } else {
                try self.emitRelease(entry.value_ptr.cell_slot);
            }
        }
    }

    fn restoreMutexState(
        self: *Codegen,
        guards: *const std.StringHashMap(MutexGuardHandle),
        results: *const std.StringHashMap(MutexGuardHandle),
    ) CodegenError!void {
        self.mutex_guard_handles.clearRetainingCapacity();
        var guard_iter = guards.iterator();
        while (guard_iter.next()) |entry| {
            self.mutex_guard_handles.put(entry.key_ptr.*, entry.value_ptr.*) catch return CodegenError.OutOfMemory;
        }

        self.mutex_lock_results.clearRetainingCapacity();
        var result_iter = results.iterator();
        while (result_iter.next()) |entry| {
            self.mutex_lock_results.put(entry.key_ptr.*, entry.value_ptr.*) catch return CodegenError.OutOfMemory;
        }
    }

    fn restoreRwLockState(
        self: *Codegen,
        guards: *const std.StringHashMap(RwLockGuardHandle),
        results: *const std.StringHashMap(RwLockGuardHandle),
    ) CodegenError!void {
        self.rwlock_guard_handles.clearRetainingCapacity();
        var guard_iter = guards.iterator();
        while (guard_iter.next()) |entry| {
            self.rwlock_guard_handles.put(entry.key_ptr.*, entry.value_ptr.*) catch return CodegenError.OutOfMemory;
        }

        self.rwlock_lock_results.clearRetainingCapacity();
        var result_iter = results.iterator();
        while (result_iter.next()) |entry| {
            self.rwlock_lock_results.put(entry.key_ptr.*, entry.value_ptr.*) catch return CodegenError.OutOfMemory;
        }
    }

    fn restoreFileState(
        self: *Codegen,
        files: *const std.StringHashMap(void),
        results: *const std.StringHashMap(FileResultHandle),
    ) CodegenError!void {
        self.file_bindings.clearRetainingCapacity();
        var file_iter = files.iterator();
        while (file_iter.next()) |entry| {
            self.file_bindings.put(entry.key_ptr.*, {}) catch return CodegenError.OutOfMemory;
        }

        self.file_open_results.clearRetainingCapacity();
        var result_iter = results.iterator();
        while (result_iter.next()) |entry| {
            self.file_open_results.put(entry.key_ptr.*, entry.value_ptr.*) catch return CodegenError.OutOfMemory;
        }
    }

    fn restoreMetadataState(
        self: *Codegen,
        metas: *const std.StringHashMap(void),
        results: *const std.StringHashMap(MetadataResultHandle),
    ) CodegenError!void {
        self.metadata_bindings.clearRetainingCapacity();
        var meta_iter = metas.iterator();
        while (meta_iter.next()) |entry| {
            self.metadata_bindings.put(entry.key_ptr.*, {}) catch return CodegenError.OutOfMemory;
        }

        self.metadata_open_results.clearRetainingCapacity();
        var result_iter = results.iterator();
        while (result_iter.next()) |entry| {
            self.metadata_open_results.put(entry.key_ptr.*, entry.value_ptr.*) catch return CodegenError.OutOfMemory;
        }
    }

    fn markOwnedCollectionBinding(self: *Codegen, name: []const u8, ty: *const ast.Type) CodegenError!void {
        if (hashMapTypes(ty) != null) {
            self.hashmap_bindings.put(name, {}) catch return CodegenError.OutOfMemory;
        }
        if (btreeMapTypes(ty) != null) {
            self.btree_map_bindings.put(name, {}) catch return CodegenError.OutOfMemory;
        }
        if (hashSetTypes(ty) != null) {
            self.hashset_bindings.put(name, {}) catch return CodegenError.OutOfMemory;
        }
        if (btreeSetTypes(ty) != null) {
            self.btree_set_bindings.put(name, {}) catch return CodegenError.OutOfMemory;
        }
    }

    fn emitExternDecl(self: *Codegen, f: *const ast.FuncDecl) CodegenError!void {
        const lowered_name = try self.loweredFuncSymbol(f.name);
        defer self.allocator.free(lowered_name);
        self.out.writer().print("@extern {s}(", .{lowered_name}) catch return CodegenError.CodegenError;
        for (f.params, 0..) |p, i| {
            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
            const prefix: []const u8 = self.abiParamPrefix(p);
            self.out.writer().print("{s}{s}: {s}", .{ prefix, p.name, abiParamTypeString(p) }) catch return CodegenError.CodegenError;
        }
        if (isVoidType(f.ret_ty)) {
            self.out.writer().print(") -> void\n", .{}) catch return CodegenError.CodegenError;
        } else {
            self.out.writer().print(") -> {s}\n", .{abiReturnTypeString(f.ret_ty)}) catch return CodegenError.CodegenError;
        }
    }

    fn hasConcreteFunctionSymbol(self: *Codegen, decls: []const *ast.Node, decl_only: *const ast.FuncDecl) CodegenError!bool {
        const decl_symbol = try self.loweredFuncSymbol(decl_only.name);
        defer self.allocator.free(decl_symbol);
        for (decls) |candidate| {
            if (candidate.* != .func_decl) continue;
            const f = &candidate.func_decl;
            if (f.is_decl_only) continue;
            const candidate_symbol = try self.loweredFuncSymbol(f.name);
            defer self.allocator.free(candidate_symbol);
            if (std.mem.eql(u8, decl_symbol, candidate_symbol)) return true;
        }
        return false;
    }

    fn clearHashMapKeySlots(self: *Codegen) void {
        var iter = self.hashmap_key_slots.valueIterator();
        while (iter.next()) |slot| {
            self.allocator.free(slot.*);
        }
        self.hashmap_key_slots.clearRetainingCapacity();
    }

    fn rootIdentifier(expr: *const ast.Node) ?[]const u8 {
        return switch (expr.*) {
            .identifier => |name| name,
            .index_expr => |idx| rootIdentifier(idx.target),
            .field_expr => |field| rootIdentifier(field.expr),
            else => null,
        };
    }

    fn threadSpawnClosureLiteral(expr: *const ast.Node) ?*const ast.ClosureLiteral {
        return switch (expr.*) {
            .closure_literal => |*lit| lit,
            .move_expr => |mv| threadSpawnClosureLiteral(mv.expr),
            else => null,
        };
    }

    fn captureNameFromIdentifier(
        self: *Codegen,
        name: []const u8,
        ty: ?*const ast.Type,
        used_as_fn_ptr: bool,
        captures: *std.StringHashMap(ThreadCaptureInfo),
        locals: *const std.StringHashMap(void),
    ) CodegenError!void {
        if (locals.contains(name)) return;
        if (self.global_const_bindings.contains(name)) return;
        if (self.tc.funcs.contains(name)) return;
        if (self.tc.macros.contains(name)) return;
        if (lowering_rules.isInternalSymbol(name)) return;
        var info = captures.get(name) orelse ThreadCaptureInfo{};
        if (used_as_fn_ptr) info.is_fn_ptr = true;
        if (ty) |capture_ty| {
            if (capture_ty.* == .fn_ptr) info.is_fn_ptr = true;
            if (!self.typeIsCopyValue(capture_ty) and !lowering_rules.isBorrowLikeType(capture_ty)) {
                info.is_noncopy_payload = true;
            }
        }
        captures.put(name, info) catch return CodegenError.OutOfMemory;
    }

    fn collectPatternBindings(self: *Codegen, pattern: ast.EnumPattern, locals: *std.StringHashMap(void)) CodegenError!void {
        _ = self;
        for (pattern.bindings) |binding| {
            locals.put(binding, {}) catch return CodegenError.OutOfMemory;
        }
    }

    fn collectThreadClosureCapturesInBlock(self: *Codegen, block: []const *ast.Node, captures: *std.StringHashMap(ThreadCaptureInfo), locals: *std.StringHashMap(void)) CodegenError!void {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| {
                    try self.collectThreadClosureCapturesInExpr(let.value, captures, locals);
                    locals.put(let.name, {}) catch return CodegenError.OutOfMemory;
                },
                .let_else_stmt => |let| {
                    try self.collectThreadClosureCapturesInExpr(let.value, captures, locals);
                    try self.collectPatternBindings(let.pattern, locals);
                    try self.collectThreadClosureCapturesInBlock(let.else_block, captures, locals);
                },
                .let_destructure_stmt => |let| {
                    try self.collectThreadClosureCapturesInExpr(let.value, captures, locals);
                    for (let.names) |name| {
                        locals.put(name, {}) catch return CodegenError.OutOfMemory;
                    }
                },
                .const_stmt => |c| {
                    try self.collectThreadClosureCapturesInExpr(c.value, captures, locals);
                    locals.put(c.name, {}) catch return CodegenError.OutOfMemory;
                },
                .assign_stmt => |assign| {
                    try self.collectThreadClosureCapturesInExpr(assign.target, captures, locals);
                    try self.collectThreadClosureCapturesInExpr(assign.value, captures, locals);
                },
                .block_stmt => |blk| {
                    var child_locals = locals.clone() catch return CodegenError.OutOfMemory;
                    defer child_locals.deinit();
                    try self.collectThreadClosureCapturesInBlock(blk.body, captures, &child_locals);
                },
                .expr_stmt => |expr| try self.collectThreadClosureCapturesInExpr(expr, captures, locals),
                .return_stmt => |ret| if (ret.value) |value| try self.collectThreadClosureCapturesInExpr(value, captures, locals),
                .for_stmt => |f| {
                    try self.collectThreadClosureCapturesInExpr(f.start, captures, locals);
                    if (f.end) |end_expr| try self.collectThreadClosureCapturesInExpr(end_expr, captures, locals);
                    var child_locals = locals.clone() catch return CodegenError.OutOfMemory;
                    defer child_locals.deinit();
                    child_locals.put(f.var_name, {}) catch return CodegenError.OutOfMemory;
                    try self.collectThreadClosureCapturesInBlock(f.body, captures, &child_locals);
                },
                .while_stmt => |w| {
                    try self.collectThreadClosureCapturesInExpr(w.cond, captures, locals);
                    var child_locals = locals.clone() catch return CodegenError.OutOfMemory;
                    defer child_locals.deinit();
                    if (w.let_pattern) |pattern| try self.collectPatternBindings(pattern, &child_locals);
                    try self.collectThreadClosureCapturesInBlock(w.body, captures, &child_locals);
                },
                else => {},
            }
        }
    }

    fn collectThreadClosureCapturesInExpr(self: *Codegen, expr: *const ast.Node, captures: *std.StringHashMap(ThreadCaptureInfo), locals: *std.StringHashMap(void)) CodegenError!void {
        switch (expr.*) {
            .identifier => |name| try self.captureNameFromIdentifier(name, self.tc.expr_types.get(expr), false, captures, locals),
            .binary_expr => |bin| {
                try self.collectThreadClosureCapturesInExpr(bin.left, captures, locals);
                try self.collectThreadClosureCapturesInExpr(bin.right, captures, locals);
            },
            .borrow_expr => |borrow| try self.collectThreadClosureCapturesInExpr(borrow.expr, captures, locals),
            .move_expr => |mv| try self.collectThreadClosureCapturesInExpr(mv.expr, captures, locals),
            .deref_expr => |deref| try self.collectThreadClosureCapturesInExpr(deref.expr, captures, locals),
            .cast_expr => |cast| try self.collectThreadClosureCapturesInExpr(cast.expr, captures, locals),
            .field_expr => |field| try self.collectThreadClosureCapturesInExpr(field.expr, captures, locals),
            .call_expr => |call| {
                if (call.associated_target == null) {
                    try self.captureNameFromIdentifier(call.func_name, null, true, captures, locals);
                }
                for (call.args) |arg| try self.collectThreadClosureCapturesInExpr(arg, captures, locals);
            },
            .struct_literal => |lit| for (lit.fields) |field| try self.collectThreadClosureCapturesInExpr(field.value, captures, locals),
            .enum_literal => |lit| for (lit.fields) |field| try self.collectThreadClosureCapturesInExpr(field.value, captures, locals),
            .tuple_literal => |lit| for (lit.elements) |elem| try self.collectThreadClosureCapturesInExpr(elem, captures, locals),
            .array_literal => |lit| for (lit.elements) |elem| try self.collectThreadClosureCapturesInExpr(elem, captures, locals),
            .repeat_array_literal => |lit| try self.collectThreadClosureCapturesInExpr(lit.value, captures, locals),
            .index_expr => |idx| {
                try self.collectThreadClosureCapturesInExpr(idx.target, captures, locals);
                try self.collectThreadClosureCapturesInExpr(idx.index, captures, locals);
            },
            .slice_expr => |slc| {
                try self.collectThreadClosureCapturesInExpr(slc.target, captures, locals);
                try self.collectThreadClosureCapturesInExpr(slc.start, captures, locals);
                try self.collectThreadClosureCapturesInExpr(slc.end, captures, locals);
            },
            .closure_literal => {},
            .await_expr => |aw| try self.collectThreadClosureCapturesInExpr(aw.expr, captures, locals),
            .try_expr => |trye| try self.collectThreadClosureCapturesInExpr(trye.expr, captures, locals),
            .if_expr => |ife| {
                try self.collectThreadClosureCapturesInExpr(ife.cond, captures, locals);
                if (ife.let_chain) |chain| {
                    for (chain) |cond| {
                        try self.collectThreadClosureCapturesInExpr(cond.value, captures, locals);
                    }
                }
                var then_locals = locals.clone() catch return CodegenError.OutOfMemory;
                defer then_locals.deinit();
                if (ife.let_chain) |chain| {
                    for (chain) |cond| {
                        try self.collectPatternBindings(cond.pattern, &then_locals);
                    }
                }
                try self.collectThreadClosureCapturesInBlock(ife.then_block, captures, &then_locals);
                if (ife.else_block) |else_block| {
                    var else_locals = locals.clone() catch return CodegenError.OutOfMemory;
                    defer else_locals.deinit();
                    try self.collectThreadClosureCapturesInBlock(else_block, captures, &else_locals);
                }
            },
            .switch_expr => |swe| {
                try self.collectThreadClosureCapturesInExpr(swe.val, captures, locals);
                for (swe.cases) |case| {
                    var child_locals = locals.clone() catch return CodegenError.OutOfMemory;
                    defer child_locals.deinit();
                    try self.collectThreadClosureCapturesInBlock(case.body, captures, &child_locals);
                }
            },
            .match_expr => |mat| {
                try self.collectThreadClosureCapturesInExpr(mat.val, captures, locals);
                for (mat.cases) |case| {
                    if (case.guard) |guard| try self.collectThreadClosureCapturesInExpr(guard, captures, locals);
                    var child_locals = locals.clone() catch return CodegenError.OutOfMemory;
                    defer child_locals.deinit();
                    try self.collectPatternBindings(case.pattern, &child_locals);
                    try self.collectThreadClosureCapturesInBlock(case.body, captures, &child_locals);
                }
            },
            .unsafe_expr => |ue| {
                var child_locals = locals.clone() catch return CodegenError.OutOfMemory;
                defer child_locals.deinit();
                try self.collectThreadClosureCapturesInBlock(ue.body, captures, &child_locals);
            },
            else => {},
        }
    }

    fn collectThreadClosureCaptures(self: *Codegen, closure: *const ast.ClosureLiteral) CodegenError![]const ThreadCapture {
        var captures = std.StringHashMap(ThreadCaptureInfo).init(self.allocator);
        defer captures.deinit();
        var locals = std.StringHashMap(void).init(self.allocator);
        defer locals.deinit();

        for (closure.params) |param| {
            locals.put(param.name, {}) catch return CodegenError.OutOfMemory;
        }

        try self.collectThreadClosureCapturesInExpr(closure.body, &captures, &locals);

        var ordered = std.ArrayList(ThreadCapture).init(self.allocator);
        errdefer ordered.deinit();
        var iter = captures.iterator();
        var offset: usize = 16;
        while (iter.next()) |entry| {
            ordered.append(.{
                .name = entry.key_ptr.*,
                .offset = offset,
                .is_fn_ptr = entry.value_ptr.is_fn_ptr,
                .is_noncopy_payload = entry.value_ptr.is_noncopy_payload,
            }) catch return CodegenError.OutOfMemory;
            offset += 8;
        }
        return ordered.toOwnedSlice() catch return CodegenError.OutOfMemory;
    }

    fn isVoidCall(self: *Codegen, call: *const ast.CallExpr) bool {
        if (lowering_rules.isPrintlnCall(call.*)) return true;
        if (self.tc.macros.contains(call.func_name)) return true;
        if (call.associated_target) |target| {
            if (lowering_rules.isMemForgetCall(call.*)) return true;
            var method_buf: [256]u8 = undefined;
            const method_key = std.fmt.bufPrint(&method_buf, "{s}_{s}", .{ target, call.func_name }) catch return false;
            if (self.tc.funcs.get(method_key)) |func| {
                return isVoidType(func.ret_ty);
            }
        }
        if (call.args.len > 0) {
            const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
            if (recv_ty) |rt| {
                const curr = lowering_rules.peelBorrowPointerType(rt);
                if (curr.* == .user_defined) {
                    var method_buf: [256]u8 = undefined;
                    const method_key = std.fmt.bufPrint(&method_buf, "{s}_{s}", .{ curr.user_defined.name, call.func_name }) catch return false;
                    if (self.tc.funcs.get(method_key)) |func| {
                        return isVoidType(func.ret_ty);
                    }
                }
            }
        }
        if (self.tc.extern_funcs.get(call.func_name)) |ext| {
            return std.mem.eql(u8, std.mem.trim(u8, ext.ret_ty, " \t\r"), "void");
        }
        if (self.tc.funcs.get(call.func_name)) |func| {
            if (func.is_async) return false;
            return isVoidType(func.ret_ty);
        }
        return lowering_rules.isPanicBuiltinName(call.func_name);
    }

    fn genCallStmt(self: *Codegen, call: *const ast.CallExpr, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!void {
        if (lowering_rules.isPrintlnCall(call.*)) {
            try self.emitPrintln(call, hoisted_allocs);
            return;
        }
        if (self.tc.macros.get(call.func_name)) |macro_decl| {
            try self.genUserMacroCallInline(macro_decl, call, hoisted_allocs);
            return;
        }
        if (call.associated_target) |target| {
            if (lowering_rules.isMemForgetCall(call.*)) {
                if (call.args.len != 1) return CodegenError.CodegenError;
                const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                self.out.writer().print("    EXPAND MEM_FORGET_U64 {s}\n", .{value_reg}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{value_reg}) catch return CodegenError.CodegenError;
                if (rootIdentifier(call.args[0])) |name| {
                    self.consumed_bindings.put(name, {}) catch return CodegenError.OutOfMemory;
                }
                return;
            }
            const method_key = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ target, call.func_name });
            defer self.allocator.free(method_key);
            if (self.tc.funcs.get(method_key)) |func| {
                if (isVoidType(func.ret_ty)) {
                    var arg_regs = std.ArrayList([]const u8).init(self.allocator);
                    defer arg_regs.deinit();
                    var arg_release_regs = std.ArrayList(?[]const u8).init(self.allocator);
                    defer arg_release_regs.deinit();
                    var arg_consume_regs = std.ArrayList([]const u8).init(self.allocator);
                    defer arg_consume_regs.deinit();
                    for (call.args, 0..) |arg, i| {
                        const sibling_mark = try self.pushCallSiblingArgExprs(call.args, i);
                        defer self.popExprLaterNodesTo(sibling_mark);
                        if (i < func.params.len) {
                            const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{
                                .param = func.params[i],
                                .arg_index = i,
                                .statement_receiver_auto_borrow = i == 0,
                            });
                            arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
                            try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
                            continue;
                        }
                        const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{});
                        arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
                        try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
                    }
                    const lowered_method = try self.loweredFuncSymbol(method_key);
                    defer self.allocator.free(lowered_method);
                    self.out.writer().print("    call @{s}(", .{lowered_method}) catch return CodegenError.CodegenError;
                    for (arg_regs.items, 0..) |arg_reg, i| {
                        if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
                        self.out.writer().print("{s}", .{arg_reg}) catch return CodegenError.CodegenError;
                    }
                    self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
                    try self.emitLoweredCallArgCleanups(arg_release_regs.items, arg_consume_regs.items, null);
                    return;
                }
            }
        }
        if (call.args.len > 0) {
            const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
            if (recv_ty) |rt| {
                const curr = lowering_rules.peelBorrowPointerType(rt);
                if (curr.* == .user_defined) {
                    var method_buf: [256]u8 = undefined;
                    const method_key = std.fmt.bufPrint(&method_buf, "{s}_{s}", .{ curr.user_defined.name, call.func_name }) catch return CodegenError.CodegenError;
                    if (self.tc.funcs.get(method_key)) |func| {
                        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
                        defer arg_regs.deinit();
                        var arg_release_regs = std.ArrayList(?[]const u8).init(self.allocator);
                        defer arg_release_regs.deinit();
                        var arg_consume_regs = std.ArrayList([]const u8).init(self.allocator);
                        defer arg_consume_regs.deinit();
                        for (call.args, 0..) |arg, i| {
                            const sibling_mark = try self.pushCallSiblingArgExprs(call.args, i);
                            defer self.popExprLaterNodesTo(sibling_mark);
                            if (i < func.params.len) {
                                const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{
                                    .param = func.params[i],
                                    .arg_index = i,
                                    .statement_receiver_auto_borrow = i == 0,
                                });
                                arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
                                try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
                                continue;
                            }
                            const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{});
                            arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
                            try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
                        }
                        const lowered_method = try self.loweredFuncSymbol(method_key);
                        defer self.allocator.free(lowered_method);
                        self.out.writer().print("    call @{s}(", .{lowered_method}) catch return CodegenError.CodegenError;
                        for (arg_regs.items, 0..) |ar, i| {
                            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
                            self.out.writer().print("{s}", .{ar}) catch return CodegenError.CodegenError;
                        }
                        self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
                        try self.emitLoweredCallArgCleanups(arg_release_regs.items, arg_consume_regs.items, call.func_name);
                        return;
                    }
                }
            }
        }
        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
        defer arg_regs.deinit();
        var arg_release_regs = std.ArrayList(?[]const u8).init(self.allocator);
        defer arg_release_regs.deinit();
        var arg_consume_regs = std.ArrayList([]const u8).init(self.allocator);
        defer arg_consume_regs.deinit();
        const resolved_func_name = self.tc.resolveFunctionAlias(call.func_name);
        const maybe_func = self.tc.funcs.get(resolved_func_name);
        for (call.args, 0..) |arg, i| {
            const sibling_mark = try self.pushCallSiblingArgExprs(call.args, i);
            defer self.popExprLaterNodesTo(sibling_mark);
            if (maybe_func) |func| {
                if (i < func.params.len) {
                    const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{
                        .param = func.params[i],
                        .arg_index = i,
                    });
                    arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
                    try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
                    continue;
                }
            }
            const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{});
            arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
            try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
        }

        const lowered_name = try self.loweredFuncSymbol(resolved_func_name);
        defer self.allocator.free(lowered_name);
        self.out.writer().print("    call @{s}(", .{lowered_name}) catch return CodegenError.CodegenError;
        for (arg_regs.items, 0..) |ar, i| {
            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}", .{ar}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
        try self.emitLoweredCallArgCleanups(arg_release_regs.items, arg_consume_regs.items, resolved_func_name);
    }

    fn genFallibleExternPayloadCall(
        self: *Codegen,
        call: *const ast.CallExpr,
        ext: contract_parser.ExternalFunction,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
        defer arg_regs.deinit();
        var arg_release_regs = std.ArrayList(?[]const u8).init(self.allocator);
        defer arg_release_regs.deinit();
        var arg_consume_regs = std.ArrayList([]const u8).init(self.allocator);
        defer arg_consume_regs.deinit();

        for (call.args, 0..) |arg, i| {
            const sibling_mark = try self.pushCallSiblingArgExprs(call.args, i);
            defer self.popExprLaterNodesTo(sibling_mark);
            const planned_param = if (i < ext.params.len) try self.externPtrParamAsAstParam(ext.params[i]) else null;
            const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{
                .param = planned_param,
                .arg_index = i,
            });
            const arg_reg = if (i < ext.params.len) switch (abiCallArgPrefix(ext.params[i])) {
                .borrow => try self.abiPrefixedArg('&', lowered_arg.reg),
                .move => try self.abiPrefixedArg('^', lowered_arg.reg),
                .none => lowered_arg.reg,
            } else lowered_arg.reg;
            arg_regs.append(arg_reg) catch return CodegenError.OutOfMemory;
            try self.appendExternLoweredCallArgCleanups(
                &arg_release_regs,
                &arg_consume_regs,
                lowered_arg,
                if (i < ext.params.len) ext.params[i] else null,
                arg_reg,
            );
        }

        const fallible_reg = try self.newTmp();
        const lowered_call = try self.loweredFuncSymbol(call.func_name);
        defer self.allocator.free(lowered_call);
        self.out.writer().print("    {s} = call @{s}(", .{ fallible_reg, lowered_call }) catch return CodegenError.CodegenError;
        for (arg_regs.items, 0..) |arg_reg, i| {
            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}", .{arg_reg}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
        try self.emitLoweredCallArgCleanups(arg_release_regs.items, arg_consume_regs.items, call.func_name);

        const payload_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{
            payload_reg,
            fallible_reg,
            lowering_rules.abiFalliblePayloadOffset(ext.ret_ty),
            abiRawPayloadTypeString(ext.ret_ty),
        }) catch return CodegenError.CodegenError;
        try self.emitRelease(fallible_reg);
        return payload_reg;
    }

    fn genExternPayloadCall(
        self: *Codegen,
        call: *const ast.CallExpr,
        ext: contract_parser.ExternalFunction,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
        defer arg_regs.deinit();
        var arg_release_regs = std.ArrayList(?[]const u8).init(self.allocator);
        defer arg_release_regs.deinit();
        var arg_consume_regs = std.ArrayList([]const u8).init(self.allocator);
        defer arg_consume_regs.deinit();

        for (call.args, 0..) |arg, i| {
            const sibling_mark = try self.pushCallSiblingArgExprs(call.args, i);
            defer self.popExprLaterNodesTo(sibling_mark);
            const planned_param = if (i < ext.params.len) try self.externPtrParamAsAstParam(ext.params[i]) else null;
            const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{
                .param = planned_param,
                .arg_index = i,
            });
            const arg_reg = if (i < ext.params.len) switch (abiCallArgPrefix(ext.params[i])) {
                .borrow => try self.abiPrefixedArg('&', lowered_arg.reg),
                .move => try self.abiPrefixedArg('^', lowered_arg.reg),
                .none => lowered_arg.reg,
            } else lowered_arg.reg;
            arg_regs.append(arg_reg) catch return CodegenError.OutOfMemory;
            try self.appendExternLoweredCallArgCleanups(
                &arg_release_regs,
                &arg_consume_regs,
                lowered_arg,
                if (i < ext.params.len) ext.params[i] else null,
                arg_reg,
            );
        }

        const reg = try self.newTmp();
        const lowered_call = try self.loweredFuncSymbol(call.func_name);
        defer self.allocator.free(lowered_call);
        self.out.writer().print("    {s} = call @{s}(", .{ reg, lowered_call }) catch return CodegenError.CodegenError;
        for (arg_regs.items, 0..) |arg_reg, i| {
            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}", .{arg_reg}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
        try self.emitLoweredCallArgCleanups(arg_release_regs.items, arg_consume_regs.items, call.func_name);
        return reg;
    }

    fn emitPrintln(self: *Codegen, call: *const ast.CallExpr, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!void {
        if (call.args.len == 0 or call.args[0].* != .literal or call.args[0].literal != .string_val) {
            self.out.writer().print("    call @sa_print_bytes(\"\\n\", 1)\n", .{}) catch return CodegenError.CodegenError;
            return;
        }

        const fmt = call.args[0].literal.string_val;
        var arg_idx: usize = 1;
        var i: usize = 0;
        while (i <= fmt.len) {
            const start = i;
            while (i < fmt.len and !(fmt[i] == '{' and i + 1 < fmt.len and fmt[i + 1] == '}')) : (i += 1) {}
            if (i > start) {
                const label = try self.newStringConst();
                self.out.writer().print("    @const {s} = utf8:\"{s}\"\n", .{ label, fmt[start..i] }) catch return CodegenError.CodegenError;
                self.out.writer().print("    call @sa_print_bytes(&{s}, {})\n", .{ label, i - start }) catch return CodegenError.CodegenError;
            }
            if (i >= fmt.len) break;
            if (arg_idx >= call.args.len) break;
            const arg = call.args[arg_idx];
            arg_idx += 1;
            const arg_ty = self.tc.expr_types.get(arg);
            if (arg.* == .literal and arg.literal == .string_val) {
                const s = arg.literal.string_val;
                const label = try self.newStringConst();
                self.out.writer().print("    @const {s} = utf8:\"{s}\"\n", .{ label, s }) catch return CodegenError.CodegenError;
                self.out.writer().print("    call @sa_print_bytes(&{s}, {})\n", .{ label, escapedStringByteLen(s) }) catch return CodegenError.CodegenError;
            } else {
                if (arg_ty) |ty| {
                    if (isFormatStringType(ty)) {
                        const string_reg = try self.genExpr(arg, hoisted_allocs);
                        const slice_reg = try self.newTmp();
                        const ptr_reg = try self.newTmp();
                        const len_reg = try self.newTmp();
                        self.out.writer().print("    EXPAND STRING_BUF_AS_STR {s}, {s}\n", .{ slice_reg, string_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND STRING_PTR {s}, {s}\n", .{ ptr_reg, slice_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND STRING_LEN {s}, {s}\n", .{ len_reg, slice_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    call @sa_print_bytes(&{s}, {s})\n", .{ ptr_reg, len_reg }) catch return CodegenError.CodegenError;
                        try self.emitRelease(ptr_reg);
                        try self.emitRelease(len_reg);
                        try self.emitRelease(slice_reg);
                        if (callArgNeedsRelease(arg)) try self.emitRelease(string_reg);
                        i += 2;
                        continue;
                    }

                    if (isStringLikeType(ty)) {
                        const slice_reg = try self.genExpr(arg, hoisted_allocs);
                        const ptr_reg = try self.newTmp();
                        const len_reg = try self.newTmp();
                        self.out.writer().print("    EXPAND STRING_PTR {s}, {s}\n", .{ ptr_reg, slice_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND STRING_LEN {s}, {s}\n", .{ len_reg, slice_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    call @sa_print_bytes(&{s}, {s})\n", .{ ptr_reg, len_reg }) catch return CodegenError.CodegenError;
                        try self.emitRelease(ptr_reg);
                        try self.emitRelease(len_reg);
                        if (callArgNeedsRelease(arg)) try self.emitRelease(slice_reg);
                        i += 2;
                        continue;
                    }

                    if (borrowedPrimitiveType(ty)) |inner_ty| {
                        const ptr_reg = try self.genExpr(arg, hoisted_allocs);
                        const val_reg = try self.newTmp();
                        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ val_reg, ptr_reg, typeString(inner_ty) }) catch return CodegenError.CodegenError;
                        switch (inner_ty.*) {
                            .primitive => |p| switch (p) {
                                .integer, .i8, .i16, .i32, .i64, .isize, .u8, .u16, .u32, .u64, .usize => {
                                    const fmt_buf = try self.newTmp();
                                    const data_reg = try self.newTmp();
                                    const len_reg = try self.newTmp();
                                    self.out.writer().print("    {s} = call @sa_fmt_u64({s}, 10)\n", .{ fmt_buf, val_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = call @sa_fmt_buffer_data({s})\n", .{ data_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = call @sa_fmt_buffer_len({s})\n", .{ len_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                    const print_ptr = try self.newTmp();
                                    self.out.writer().print("    {s} = {s}\n", .{ print_ptr, data_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    call @sa_print_bytes(&{s}, {s})\n", .{ print_ptr, len_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    call @sa_fmt_buffer_free(^{s})\n", .{fmt_buf}) catch return CodegenError.CodegenError;
                                    try self.emitRelease(print_ptr);
                                    try self.emitRelease(len_reg);
                                },
                                .f32, .f64, .float => {
                                    const fmt_buf = try self.newTmp();
                                    const data_reg = try self.newTmp();
                                    const len_reg = try self.newTmp();
                                    self.out.writer().print("    {s} = call @sa_fmt_f64({s}, 10)\n", .{ fmt_buf, val_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = call @sa_fmt_buffer_data({s})\n", .{ data_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = call @sa_fmt_buffer_len({s})\n", .{ len_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                    const print_ptr = try self.newTmp();
                                    self.out.writer().print("    {s} = {s}\n", .{ print_ptr, data_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    call @sa_print_bytes(&{s}, {s})\n", .{ print_ptr, len_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    call @sa_fmt_buffer_free(^{s})\n", .{fmt_buf}) catch return CodegenError.CodegenError;
                                    try self.emitRelease(print_ptr);
                                    try self.emitRelease(len_reg);
                                },
                                .boolean => {
                                    const fmt_buf = try self.newTmp();
                                    const data_reg = try self.newTmp();
                                    const len_reg = try self.newTmp();
                                    self.out.writer().print("    {s} = call @sa_fmt_bool({s})\n", .{ fmt_buf, val_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = call @sa_fmt_buffer_data({s})\n", .{ data_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = call @sa_fmt_buffer_len({s})\n", .{ len_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                    const print_ptr = try self.newTmp();
                                    self.out.writer().print("    {s} = {s}\n", .{ print_ptr, data_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    call @sa_print_bytes(&{s}, {s})\n", .{ print_ptr, len_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    call @sa_fmt_buffer_free(^{s})\n", .{fmt_buf}) catch return CodegenError.CodegenError;
                                    try self.emitRelease(print_ptr);
                                    try self.emitRelease(len_reg);
                                },
                                else => return CodegenError.CodegenError,
                            },
                            else => return CodegenError.CodegenError,
                        }
                        try self.emitRelease(val_reg);
                        if (callArgNeedsRelease(arg)) try self.emitRelease(ptr_reg);
                        i += 2;
                        continue;
                    }

                    if (boxInnerType(ty)) |inner_ty| {
                        const box_reg = try self.genExpr(arg, hoisted_allocs);
                        const val_reg = try self.newTmp();
                        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ val_reg, box_reg, typeString(inner_ty) }) catch return CodegenError.CodegenError;
                        switch (inner_ty.*) {
                            .primitive => |p| switch (p) {
                                .integer, .i8, .i16, .i32, .i64, .isize, .u8, .u16, .u32, .u64, .usize => {
                                    const fmt_buf = try self.newTmp();
                                    const data_reg = try self.newTmp();
                                    const len_reg = try self.newTmp();
                                    self.out.writer().print("    {s} = call @sa_fmt_u64({s}, 10)\n", .{ fmt_buf, val_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = call @sa_fmt_buffer_data({s})\n", .{ data_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = call @sa_fmt_buffer_len({s})\n", .{ len_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                    const ptr_reg = try self.newTmp();
                                    self.out.writer().print("    {s} = {s}\n", .{ ptr_reg, data_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    call @sa_print_bytes(&{s}, {s})\n", .{ ptr_reg, len_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    call @sa_fmt_buffer_free(^{s})\n", .{fmt_buf}) catch return CodegenError.CodegenError;
                                    try self.emitRelease(ptr_reg);
                                    try self.emitRelease(len_reg);
                                },
                                .f32, .f64, .float => {
                                    const fmt_buf = try self.newTmp();
                                    const data_reg = try self.newTmp();
                                    const len_reg = try self.newTmp();
                                    self.out.writer().print("    {s} = call @sa_fmt_f64({s}, 10)\n", .{ fmt_buf, val_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = call @sa_fmt_buffer_data({s})\n", .{ data_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = call @sa_fmt_buffer_len({s})\n", .{ len_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                    const ptr_reg = try self.newTmp();
                                    self.out.writer().print("    {s} = {s}\n", .{ ptr_reg, data_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    call @sa_print_bytes(&{s}, {s})\n", .{ ptr_reg, len_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    call @sa_fmt_buffer_free(^{s})\n", .{fmt_buf}) catch return CodegenError.CodegenError;
                                    try self.emitRelease(ptr_reg);
                                    try self.emitRelease(len_reg);
                                },
                                .boolean => {
                                    const fmt_buf = try self.newTmp();
                                    const data_reg = try self.newTmp();
                                    const len_reg = try self.newTmp();
                                    self.out.writer().print("    {s} = call @sa_fmt_bool({s})\n", .{ fmt_buf, val_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = call @sa_fmt_buffer_data({s})\n", .{ data_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = call @sa_fmt_buffer_len({s})\n", .{ len_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                    const ptr_reg = try self.newTmp();
                                    self.out.writer().print("    {s} = {s}\n", .{ ptr_reg, data_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    call @sa_print_bytes(&{s}, {s})\n", .{ ptr_reg, len_reg }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    call @sa_fmt_buffer_free(^{s})\n", .{fmt_buf}) catch return CodegenError.CodegenError;
                                    try self.emitRelease(ptr_reg);
                                    try self.emitRelease(len_reg);
                                },
                                else => return CodegenError.CodegenError,
                            },
                            else => return CodegenError.CodegenError,
                        }
                        try self.emitRelease(val_reg);
                        if (callArgNeedsRelease(arg)) try self.emitRelease(box_reg);
                        i += 2;
                        continue;
                    }

                    switch (ty.*) {
                        .primitive => |p| switch (p) {
                            .integer, .i8, .i16, .i32, .i64, .isize, .u8, .u16, .u32, .u64, .usize => {
                                const val_reg = try self.genExpr(arg, hoisted_allocs);
                                const fmt_buf = try self.newTmp();
                                const data_reg = try self.newTmp();
                                const len_reg = try self.newTmp();
                                self.out.writer().print("    {s} = call @sa_fmt_u64({s}, 10)\n", .{ fmt_buf, val_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = call @sa_fmt_buffer_data({s})\n", .{ data_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = call @sa_fmt_buffer_len({s})\n", .{ len_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                const ptr_reg = try self.newTmp();
                                self.out.writer().print("    {s} = {s}\n", .{ ptr_reg, data_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    call @sa_print_bytes(&{s}, {s})\n", .{ ptr_reg, len_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    call @sa_fmt_buffer_free(^{s})\n", .{fmt_buf}) catch return CodegenError.CodegenError;
                                try self.emitRelease(ptr_reg);
                                try self.emitRelease(len_reg);
                                if (callArgNeedsRelease(arg)) try self.emitRelease(val_reg);
                            },
                            .f32, .f64, .float => {
                                const val_reg = try self.genExpr(arg, hoisted_allocs);
                                const fmt_buf = try self.newTmp();
                                const data_reg = try self.newTmp();
                                const len_reg = try self.newTmp();
                                self.out.writer().print("    {s} = call @sa_fmt_f64({s}, 10)\n", .{ fmt_buf, val_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = call @sa_fmt_buffer_data({s})\n", .{ data_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = call @sa_fmt_buffer_len({s})\n", .{ len_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                const ptr_reg = try self.newTmp();
                                self.out.writer().print("    {s} = {s}\n", .{ ptr_reg, data_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    call @sa_print_bytes(&{s}, {s})\n", .{ ptr_reg, len_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    call @sa_fmt_buffer_free(^{s})\n", .{fmt_buf}) catch return CodegenError.CodegenError;
                                try self.emitRelease(ptr_reg);
                                try self.emitRelease(len_reg);
                                if (callArgNeedsRelease(arg)) try self.emitRelease(val_reg);
                            },
                            .boolean => {
                                const val_reg = try self.genExpr(arg, hoisted_allocs);
                                const fmt_buf = try self.newTmp();
                                const data_reg = try self.newTmp();
                                const len_reg = try self.newTmp();
                                self.out.writer().print("    {s} = call @sa_fmt_bool({s})\n", .{ fmt_buf, val_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = call @sa_fmt_buffer_data({s})\n", .{ data_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = call @sa_fmt_buffer_len({s})\n", .{ len_reg, fmt_buf }) catch return CodegenError.CodegenError;
                                const ptr_reg = try self.newTmp();
                                self.out.writer().print("    {s} = {s}\n", .{ ptr_reg, data_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    call @sa_print_bytes(&{s}, {s})\n", .{ ptr_reg, len_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    call @sa_fmt_buffer_free(^{s})\n", .{fmt_buf}) catch return CodegenError.CodegenError;
                                try self.emitRelease(ptr_reg);
                                try self.emitRelease(len_reg);
                                if (callArgNeedsRelease(arg)) try self.emitRelease(val_reg);
                            },
                            else => {
                                const val_reg = try self.genExpr(arg, hoisted_allocs);
                                const ptr_reg = try self.newTmp();
                                // `add x, 0` copy: a plain `ptr = val`
                                // assignment is a move in SA and would consume
                                // a binding that is still live.
                                self.out.writer().print("    {s} = add {s}, 0\n", .{ ptr_reg, val_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    call @sa_print_bytes(&{s}, 1)\n", .{ptr_reg}) catch return CodegenError.CodegenError;
                            },
                        },
                        else => {
                            const val_reg = try self.genExpr(arg, hoisted_allocs);
                            const ptr_reg = try self.newTmp();
                            self.out.writer().print("    {s} = add {s}, 0\n", .{ ptr_reg, val_reg }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    call @sa_print_bytes(&{s}, 1)\n", .{ptr_reg}) catch return CodegenError.CodegenError;
                        },
                    }
                } else {
                    const val_reg = try self.genExpr(arg, hoisted_allocs);
                    const ptr_reg = try self.newTmp();
                    self.out.writer().print("    {s} = add {s}, 0\n", .{ ptr_reg, val_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    call @sa_print_bytes(&{s}, 1)\n", .{ptr_reg}) catch return CodegenError.CodegenError;
                }
            }
            i += 2;
        }
        const nl_label = try self.newStringConst();
        self.out.writer().print("    @const {s} = utf8:\"\\n\"\n", .{nl_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    call @sa_print_bytes(&{s}, 1)\n", .{nl_label}) catch return CodegenError.CodegenError;
    }

    fn sanitizeTestName(self: *Codegen, name: []const u8) CodegenError![]const u8 {
        var out = std.ArrayList(u8).init(self.allocator);
        for (name) |c| {
            switch (c) {
                '(', ')' => out.append('-') catch return CodegenError.OutOfMemory,
                '"', '\\', '\n', '\r', '\t' => out.append(' ') catch return CodegenError.OutOfMemory,
                else => out.append(c) catch return CodegenError.OutOfMemory,
            }
        }
        return out.toOwnedSlice() catch return CodegenError.OutOfMemory;
    }

    const FieldLayout = struct {
        offset: usize,
        ty_str: []const u8,
    };

    const AddressProjection = struct {
        ptr: []const u8,
        source_temp: ?[]const u8 = null,
    };

    const IndexAddress = struct {
        ptr: []const u8,
        elem_ty: *ast.Type,
        base_tmp: ?[]const u8,
        base_reg: []const u8,
        release_base_reg: bool,
    };

    const VecReceiver = struct {
        reg: []const u8,
        release_reg: ?[]const u8 = null,
        consume_reg: ?[]const u8 = null,
    };

    fn typeSize(ty: *const ast.Type) usize {
        return lowering_rules.abiTypeSize(ty);
    }

    fn vecElementSlotSize(self: *Codegen, ty: *const ast.Type) usize {
        const size = if (ty.* == .user_defined and lowering_rules.smartPointerType(ty) == null)
            if (self.structDeclForType(ty)) |decl| structSize(decl) else typeSize(ty)
        else
            typeSize(ty);
        return if (size < 8) 8 else size;
    }

    fn typeString(ty: *const ast.Type) []const u8 {
        return lowering_rules.abiTypeString(ty);
    }

    fn ptrReadVolatileMacroName(ty: *const ast.Type) ?[]const u8 {
        return lowering_rules.ptrReadVolatileMacroName(ty);
    }

    fn abiParamTypeString(p: ast.Param) []const u8 {
        return lowering_rules.abiParamTypeString(p.is_borrow, p.is_move, p.ty);
    }

    fn abiParamPrefix(self: *Codegen, p: ast.Param) []const u8 {
        if (p.is_borrow or p.ty.* == .borrow) return "&";
        if (lowering_rules.byValueRawPointerParam(p)) return "";
        if (p.is_move or (!self.typeIsCopyValue(p.ty) and !lowering_rules.isBorrowLikeType(p.ty))) return "^";
        return "";
    }

    fn abiParamNeedsBorrowArg(p: ast.Param) bool {
        return lowering_rules.abiParamNeedsBorrowArg(p.is_borrow, p.ty);
    }

    fn abiReturnTypeString(ty: *const ast.Type) []const u8 {
        return lowering_rules.abiReturnTypeString(ty);
    }

    fn abiRawPayloadTypeString(raw: []const u8) []const u8 {
        return lowering_rules.abiRawPayloadTypeString(raw);
    }

    const AbiCallArgPrefix = enum {
        none,
        borrow,
        move,
    };

    fn abiCallArgPrefix(param: contract_parser.Param) AbiCallArgPrefix {
        return switch (lowering_rules.abiCallArgCapKind(param.is_borrow, param.is_move)) {
            .borrow => .borrow,
            .move => .move,
            .none, .raw => .none,
        };
    }

    fn externPtrParamAsAstParam(self: *Codegen, param: contract_parser.Param) CodegenError!?ast.Param {
        const ty_name = std.mem.trim(u8, param.ty, " \t\r");
        if (!std.mem.eql(u8, ty_name, "ptr")) return null;
        return .{
            .name = param.name,
            .ty = @constCast(try self.makePrimitiveType(.raw_ptr)),
            .is_borrow = param.is_borrow,
            .is_move = param.is_move,
        };
    }

    fn abiPrefixedArg(self: *Codegen, prefix: u8, reg: []const u8) CodegenError![]const u8 {
        if (reg.len != 0 and reg[0] == prefix) return reg;
        return std.fmt.allocPrint(self.allocator, "{c}{s}", .{ prefix, reg }) catch return CodegenError.OutOfMemory;
    }

    fn appendExternLoweredCallArgCleanups(
        self: *Codegen,
        release_regs: *std.ArrayList(?[]const u8),
        consume_regs: *std.ArrayList([]const u8),
        lowered_arg: LoweredCallArg,
        param: ?contract_parser.Param,
        call_arg_reg: []const u8,
    ) CodegenError!void {
        if (param) |target_param| {
            if (target_param.is_move) {
                try self.appendLoweredCallArgCleanups(release_regs, consume_regs, .{
                    .reg = call_arg_reg,
                    .release_after_call = false,
                    .consume_reg = call_arg_reg,
                });
                return;
            }
        }
        try self.appendLoweredCallArgCleanups(release_regs, consume_regs, lowered_arg);
    }

    fn bindingNeedsAddressableStorage(self: *Codegen, name: []const u8, ty: *const ast.Type) bool {
        return lowering_rules.planBorrowedBindingStorage(self.addressable_bindings.contains(name), ty).materialize_stack_slot;
    }

    fn bindingNeedsAssignedValueSlot(self: *Codegen, name: []const u8, ty: *const ast.Type) bool {
        return self.assigned_bindings.contains(name) and
            !self.typeIsCopyValue(ty) and
            self.typeIsShallowCopyCallArgValue(ty, 0);
    }

    fn collectAssignedBindings(self: *Codegen, block: []const *ast.Node) CodegenError!void {
        for (block) |stmt| {
            try self.collectAssignedBindingsInNode(stmt);
        }
    }

    fn collectAssignedBindingsInNode(self: *Codegen, node: *const ast.Node) CodegenError!void {
        switch (node.*) {
            .func_decl => |f| try self.collectAssignedBindings(f.body),
            .test_decl => |t| try self.collectAssignedBindings(t.body),
            .impl_decl => |i| for (i.methods) |method| try self.collectAssignedBindingsInNode(method),
            .overload_decl => |o| for (o.methods) |method| try self.collectAssignedBindingsInNode(method),
            .let_stmt => |let| try self.collectAssignedBindingsInNode(let.value),
            .let_else_stmt => |let| {
                try self.collectAssignedBindingsInNode(let.value);
                try self.collectAssignedBindings(let.else_block);
            },
            .let_destructure_stmt => |let| try self.collectAssignedBindingsInNode(let.value),
            .const_stmt => |c| try self.collectAssignedBindingsInNode(c.value),
            .var_stmt => {},
            .assign_stmt => |assign| {
                if (lowering_rules.rootIdentifier(assign.target)) |name| self.assigned_bindings.put(name, {}) catch return CodegenError.OutOfMemory;
                try self.collectAssignedBindingsInNode(assign.target);
                try self.collectAssignedBindingsInNode(assign.value);
            },
            .expr_stmt => |expr| try self.collectAssignedBindingsInNode(expr),
            .return_stmt => |ret| if (ret.value) |value| try self.collectAssignedBindingsInNode(value),
            .block_stmt => |blk| try self.collectAssignedBindings(blk.body),
            .for_stmt => |for_stmt| {
                try self.collectAssignedBindingsInNode(for_stmt.start);
                if (for_stmt.end) |end_expr| try self.collectAssignedBindingsInNode(end_expr);
                try self.collectAssignedBindings(for_stmt.body);
            },
            .while_stmt => |while_stmt| {
                try self.collectAssignedBindingsInNode(while_stmt.cond);
                try self.collectAssignedBindings(while_stmt.body);
            },
            .binary_expr => |bin| {
                try self.collectAssignedBindingsInNode(bin.left);
                try self.collectAssignedBindingsInNode(bin.right);
            },
            .call_expr => |call| for (call.args) |arg| try self.collectAssignedBindingsInNode(arg),
            .field_expr => |field| try self.collectAssignedBindingsInNode(field.expr),
            .index_expr => |index| {
                try self.collectAssignedBindingsInNode(index.target);
                try self.collectAssignedBindingsInNode(index.index);
            },
            .slice_expr => |slice| {
                try self.collectAssignedBindingsInNode(slice.target);
                try self.collectAssignedBindingsInNode(slice.start);
                try self.collectAssignedBindingsInNode(slice.end);
            },
            .struct_literal => |lit| {
                for (lit.fields) |field| try self.collectAssignedBindingsInNode(field.value);
                if (lit.update_expr) |update| try self.collectAssignedBindingsInNode(update);
            },
            .enum_literal => |lit| for (lit.fields) |field| try self.collectAssignedBindingsInNode(field.value),
            .tuple_literal => |lit| for (lit.elements) |elem| try self.collectAssignedBindingsInNode(elem),
            .array_literal => |lit| for (lit.elements) |elem| try self.collectAssignedBindingsInNode(elem),
            .repeat_array_literal => |lit| try self.collectAssignedBindingsInNode(lit.value),
            .borrow_expr => |borrow| try self.collectAssignedBindingsInNode(borrow.expr),
            .move_expr => |move| try self.collectAssignedBindingsInNode(move.expr),
            .deref_expr => |deref| try self.collectAssignedBindingsInNode(deref.expr),
            .cast_expr => |cast| try self.collectAssignedBindingsInNode(cast.expr),
            .await_expr => |await_expr| try self.collectAssignedBindingsInNode(await_expr.expr),
            .try_expr => |try_expr| try self.collectAssignedBindingsInNode(try_expr.expr),
            .unsafe_expr => |unsafe_expr| try self.collectAssignedBindings(unsafe_expr.body),
            .closure_literal => |closure| try self.collectAssignedBindingsInNode(closure.body),
            .if_expr => |ife| {
                try self.collectAssignedBindingsInNode(ife.cond);
                if (ife.let_chain) |chain| {
                    for (chain) |cond| try self.collectAssignedBindingsInNode(cond.value);
                }
                try self.collectAssignedBindings(ife.then_block);
                if (ife.else_block) |else_block| try self.collectAssignedBindings(else_block);
            },
            .switch_expr => |swe| {
                try self.collectAssignedBindingsInNode(swe.val);
                for (swe.cases) |case| try self.collectAssignedBindings(case.body);
            },
            .match_expr => |mat| {
                try self.collectAssignedBindingsInNode(mat.val);
                for (mat.cases) |case| {
                    if (case.guard) |guard| try self.collectAssignedBindingsInNode(guard);
                    try self.collectAssignedBindings(case.body);
                }
            },
            else => {},
        }
    }

    fn collectAddressableBindings(self: *Codegen, block: []const *ast.Node) CodegenError!void {
        for (block) |stmt| {
            try self.collectAddressableBindingsInStmt(stmt);
        }
    }

    fn collectAddressableBindingsInStmt(self: *Codegen, stmt: *const ast.Node) CodegenError!void {
        switch (stmt.*) {
            .let_stmt => |let| try self.collectAddressableBindingsInExpr(let.value),
            .let_else_stmt => |let| {
                try self.collectAddressableBindingsInExpr(let.value);
                try self.collectAddressableBindings(let.else_block);
            },
            .let_destructure_stmt => |let| try self.collectAddressableBindingsInExpr(let.value),
            .const_stmt => |c| try self.collectAddressableBindingsInExpr(c.value),
            .assign_stmt => |assign| {
                try self.collectAddressableBindingsInExpr(assign.target);
                try self.collectAddressableBindingsInExpr(assign.value);
            },
            .expr_stmt => |expr| try self.collectAddressableBindingsInExpr(expr),
            .return_stmt => |ret| if (ret.value) |value| try self.collectAddressableBindingsInExpr(value),
            .for_stmt => |for_stmt| {
                try self.collectAddressableBindingsInExpr(for_stmt.start);
                if (for_stmt.end) |end_expr| try self.collectAddressableBindingsInExpr(end_expr);
                try self.collectAddressableBindings(for_stmt.body);
            },
            .while_stmt => |while_stmt| {
                try self.collectAddressableBindingsInExpr(while_stmt.cond);
                try self.collectAddressableBindings(while_stmt.body);
            },
            .block_stmt => |blk| try self.collectAddressableBindings(blk.body),
            else => {},
        }
    }

    fn collectAddressableBindingsInExpr(self: *Codegen, expr: *const ast.Node) CodegenError!void {
        switch (expr.*) {
            .borrow_expr => |borrow| {
                if (lowering_rules.borrowedIdentifierName(expr)) |name| self.addressable_bindings.put(name, {}) catch return CodegenError.OutOfMemory;
                try self.collectAddressableBindingsInExpr(borrow.expr);
            },
            .move_expr => |move| try self.collectAddressableBindingsInExpr(move.expr),
            .deref_expr => |deref| try self.collectAddressableBindingsInExpr(deref.expr),
            .binary_expr => |bin| {
                try self.collectAddressableBindingsInExpr(bin.left);
                try self.collectAddressableBindingsInExpr(bin.right);
            },
            .call_expr => |call| {
                if (lowering_rules.planImportedMacroCall(self.tc, call)) |plan| {
                    for (call.args, 0..) |arg, i| {
                        if (plan.addressableIdentifierArgName(i, arg)) |name| {
                            if (self.resolvedTypeForExpr(arg)) |arg_ty| {
                                if (lowering_rules.importedMacroBorrowUsesRawPointerValue(arg_ty)) continue;
                            }
                            self.addressable_bindings.put(name, {}) catch return CodegenError.OutOfMemory;
                        }
                    }
                }
                for (call.args) |arg| {
                    try self.collectAddressableBindingsInExpr(arg);
                }
            },
            .if_expr => |ife| {
                try self.collectAddressableBindingsInExpr(ife.cond);
                if (ife.let_chain) |chain| {
                    for (chain) |cond| try self.collectAddressableBindingsInExpr(cond.value);
                }
                try self.collectAddressableBindings(ife.then_block);
                if (ife.else_block) |else_block| {
                    try self.collectAddressableBindings(else_block);
                }
            },
            .switch_expr => |swe| {
                try self.collectAddressableBindingsInExpr(swe.val);
                for (swe.cases) |case| {
                    try self.collectAddressableBindings(case.body);
                }
            },
            .match_expr => |mat| {
                try self.collectAddressableBindingsInExpr(mat.val);
                for (mat.cases) |case| {
                    if (case.guard) |guard| try self.collectAddressableBindingsInExpr(guard);
                    try self.collectAddressableBindings(case.body);
                }
            },
            .unsafe_expr => |unsafe_expr| try self.collectAddressableBindings(unsafe_expr.body),
            .await_expr => |await_expr| try self.collectAddressableBindingsInExpr(await_expr.expr),
            .cast_expr => |cast| try self.collectAddressableBindingsInExpr(cast.expr),
            .field_expr => |field| try self.collectAddressableBindingsInExpr(field.expr),
            .index_expr => |index| {
                try self.collectAddressableBindingsInExpr(index.target);
                try self.collectAddressableBindingsInExpr(index.index);
            },
            .slice_expr => |slice| {
                try self.collectAddressableBindingsInExpr(slice.target);
                try self.collectAddressableBindingsInExpr(slice.start);
                try self.collectAddressableBindingsInExpr(slice.end);
            },
            .tuple_literal => |tuple| {
                for (tuple.elements) |elem| {
                    try self.collectAddressableBindingsInExpr(elem);
                }
            },
            .array_literal => |array| {
                for (array.elements) |elem| {
                    try self.collectAddressableBindingsInExpr(elem);
                }
            },
            .struct_literal => |lit| {
                for (lit.fields) |field| {
                    try self.collectAddressableBindingsInExpr(field.value);
                }
            },
            .enum_literal => |lit| {
                for (lit.fields) |field| {
                    try self.collectAddressableBindingsInExpr(field.value);
                }
            },
            .closure_literal => |closure| {
                try self.collectAddressableBindingsInExpr(closure.body);
            },
            .try_expr => |try_expr| try self.collectAddressableBindingsInExpr(try_expr.expr),
            else => {},
        }
    }

    fn appendHexEscapedByte(buf: *std.ArrayList(u8), byte: u8) CodegenError!void {
        buf.writer().print("\\x{x:0>2}", .{byte}) catch return CodegenError.CodegenError;
    }

    fn constLiteralNode(node: *const ast.Node) ?*const ast.Node {
        return switch (node.*) {
            .literal => node,
            .cast_expr => |cast| constLiteralNode(cast.expr),
            else => null,
        };
    }

    fn literalHexBytes(self: *Codegen, node: *const ast.Node, ty: *const ast.Type) CodegenError![]const u8 {
        const literal_node = constLiteralNode(node) orelse return CodegenError.CodegenError;
        const literal = literal_node.literal;
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        switch (ty.*) {
            .primitive => |pr| switch (pr) {
                .boolean => switch (literal) {
                    .bool_val => |value| try appendHexEscapedByte(&buf, if (value) 1 else 0),
                    else => return CodegenError.CodegenError,
                },
                .i8 => switch (literal) {
                    .int_val => |value| try appendHexEscapedByte(&buf, @bitCast(@as(i8, @intCast(value)))),
                    else => return CodegenError.CodegenError,
                },
                .u8 => switch (literal) {
                    .int_val => |value| try appendHexEscapedByte(&buf, @as(u8, @intCast(value))),
                    else => return CodegenError.CodegenError,
                },
                .i16 => {
                    const value = switch (literal) {
                        .int_val => |v| v,
                        else => return CodegenError.CodegenError,
                    };
                    var bytes: [2]u8 = undefined;
                    std.mem.writeInt(i16, &bytes, @as(i16, @intCast(value)), .little);
                    for (bytes) |byte| try appendHexEscapedByte(&buf, byte);
                },
                .u16 => {
                    const value = switch (literal) {
                        .int_val => |v| v,
                        else => return CodegenError.CodegenError,
                    };
                    var bytes: [2]u8 = undefined;
                    std.mem.writeInt(u16, &bytes, @as(u16, @intCast(value)), .little);
                    for (bytes) |byte| try appendHexEscapedByte(&buf, byte);
                },
                .i32 => {
                    const value = switch (literal) {
                        .int_val => |v| v,
                        else => return CodegenError.CodegenError,
                    };
                    var bytes: [4]u8 = undefined;
                    std.mem.writeInt(i32, &bytes, @as(i32, @intCast(value)), .little);
                    for (bytes) |byte| try appendHexEscapedByte(&buf, byte);
                },
                .u32 => {
                    const value = switch (literal) {
                        .int_val => |v| v,
                        else => return CodegenError.CodegenError,
                    };
                    var bytes: [4]u8 = undefined;
                    std.mem.writeInt(u32, &bytes, @as(u32, @intCast(value)), .little);
                    for (bytes) |byte| try appendHexEscapedByte(&buf, byte);
                },
                .i64, .integer, .isize => {
                    const value = switch (literal) {
                        .int_val => |v| v,
                        else => return CodegenError.CodegenError,
                    };
                    var bytes: [8]u8 = undefined;
                    std.mem.writeInt(i64, &bytes, value, .little);
                    for (bytes) |byte| try appendHexEscapedByte(&buf, byte);
                },
                .u64, .usize => {
                    const value = switch (literal) {
                        .int_val => |v| v,
                        else => return CodegenError.CodegenError,
                    };
                    var bytes: [8]u8 = undefined;
                    std.mem.writeInt(u64, &bytes, @as(u64, @intCast(value)), .little);
                    for (bytes) |byte| try appendHexEscapedByte(&buf, byte);
                },
                else => return CodegenError.CodegenError,
            },
            else => return CodegenError.CodegenError,
        }

        return buf.toOwnedSlice() catch return CodegenError.OutOfMemory;
    }

    // Look up a scalar literal value for `expr`: returns the pointer node
    // stored in global_scalar_consts for identifiers, or the node itself when
    // it is already a literal scalar. Used by binary-const folding to resolve
    // operands regardless of whether they are direct literals or aliases.
    fn scalarConstantNodeFor(self: *Codegen, expr: *const ast.Node) ?*const ast.Node {
        if (expr.* == .literal) {
            switch (expr.literal) {
                .int_val, .float_val, .bool_val => return expr,
                .string_val => return null,
            }
        }
        if (expr.* == .identifier) {
            if (self.global_scalar_consts.get(expr.identifier)) |alias| return alias;
        }
        return null;
    }

    // Fold a top-level scalar binary const of the form `const N = a OP b;`
    // (most commonly `0 - 1` to model the VAriableSLA restriction that
    // forbids a unary minus directly applied to an integer literal). Returns
    // an allocated `*ast.Node` literal storing the computed scalar, or null if
    // the operands cannot be reduced to scalar literals. The caller registers
    // the returned node into global_scalar_consts; the node is allocated on
    // Codegen.allocator which lives at least as long as the program AST.
    fn foldTopLevelBinaryConst(self: *Codegen, bin: *const ast.BinaryExpr) CodegenError!?*ast.Node {
        const left_node = self.scalarConstantNodeFor(bin.left) orelse return null;
        const right_node = self.scalarConstantNodeFor(bin.right) orelse return null;
        const left_lit = left_node.literal;
        const right_lit = right_node.literal;
        const folded = try self.allocator.create(ast.Node);
        switch (left_lit) {
            .int_val => |li| {
                if (right_lit != .int_val) return null;
                const ri = right_lit.int_val;
                const ri_val = switch (bin.op) {
                    .add => std.math.add(i64, li, ri) catch return null,
                    .sub => std.math.sub(i64, li, ri) catch return null,
                    .mul => std.math.mul(i64, li, ri) catch return null,
                    .div => if (ri == 0) (return null) else @divTrunc(li, ri),
                    .mod => if (ri == 0) (return null) else @rem(li, ri),
                    .bit_and => li & ri,
                    .bit_or => li | ri,
                    .bit_xor => li ^ ri,
                    .shl => if (ri >= 0 and ri < 64) li << @as(u6, @intCast(ri)) else return null,
                    .shr => if (ri >= 0 and ri < 64) li >> @as(u6, @intCast(ri)) else return null,
                    .eq => return null,
                    .ne => return null,
                    .lt => return null,
                    .le => return null,
                    .gt => return null,
                    .ge => return null,
                    .spaceship => return null,
                    .logical_and => return null,
                    .logical_or => return null,
                };
                folded.* = .{ .literal = .{ .int_val = ri_val } };
            },
            .float_val => |lf| {
                if (right_lit != .float_val) return null;
                const rf = right_lit.float_val;
                if (bin.op != .add and bin.op != .sub and bin.op != .mul and bin.op != .div) return null;
                const rf_val = switch (bin.op) {
                    .add => lf + rf,
                    .sub => lf - rf,
                    .mul => lf * rf,
                    .div => if (rf == 0.0) (return null) else lf / rf,
                    else => unreachable,
                };
                folded.* = .{ .literal = .{ .float_val = rf_val } };
            },
            .bool_val => |lb| {
                if (right_lit != .bool_val) return null;
                const rb = right_lit.bool_val;
                const rf_val = switch (bin.op) {
                    .logical_and => lb and rb,
                    .logical_or => lb or rb,
                    else => return null,
                };
                folded.* = .{ .literal = .{ .bool_val = rf_val } };
            },
            .string_val => return null,
        }
        return folded;
    }

    fn emitTopLevelConstDecl(self: *Codegen, c: *const ast.ConstStmt) CodegenError!void {
        switch (c.value.*) {
            .literal => |lit| switch (lit) {
                .int_val, .float_val, .bool_val => {},
                .string_val => |value| {
                    self.out.writer().print("@const {s} = utf8:\"{s}\"\n", .{ c.name, value }) catch return CodegenError.CodegenError;
                },
            },
            .array_literal => |array| {
                const const_ty = c.ty orelse self.tc.expr_types.get(c.value) orelse return CodegenError.CodegenError;
                if (const_ty.* != .array) return CodegenError.CodegenError;
                self.out.writer().print("@const {s} = struct {{ ", .{c.name}) catch return CodegenError.CodegenError;
                for (array.elements, 0..) |elem, i| {
                    if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
                    const bytes = try self.literalHexBytes(elem, const_ty.array.elem);
                    defer self.allocator.free(bytes);
                    self.out.writer().print("f{}: {} = hex:{s}", .{ i, typeSize(const_ty.array.elem), bytes }) catch return CodegenError.CodegenError;
                }
                self.out.writer().print(" }}\n", .{}) catch return CodegenError.CodegenError;
            },
            .call_expr => |call| {
                if (std.mem.eql(u8, call.func_name, "RAW_WAKER_VTABLE_NEW") and call.args.len == 4) {
                    self.out.writer().print("@const {s} = vtable {{ clone = ", .{c.name}) catch return CodegenError.CodegenError;
                    for (call.args, 0..) |arg, i| {
                        if (arg.* != .identifier) return CodegenError.CodegenError;
                        const lowered = try self.loweredFuncSymbol(arg.identifier);
                        defer self.allocator.free(lowered);
                        if (i > 0) {
                            const field_name = switch (i) {
                                1 => "wake",
                                2 => "wake_by_ref",
                                3 => "drop",
                                else => return CodegenError.CodegenError,
                            };
                            self.out.writer().print(", {s} = ", .{field_name}) catch return CodegenError.CodegenError;
                        }
                        self.out.writer().print("@{s}", .{lowered}) catch return CodegenError.CodegenError;
                    }
                    self.out.writer().print(" }}\n", .{}) catch return CodegenError.CodegenError;
                    return;
                }
                return CodegenError.CodegenError;
            },
            // const A = B;  -- alias of another top-level const. Alias folding
            // into global_scalar_consts already happened during `generate`, so
            // scalar aliases reach their literal value at every use site through
            // that table (see the genIdentifier literal-node shortcut). For the
            // emitTopLevelConstDecl pass itself there is nothing material to emit
            // for a scalar alias: scalar consts live as compile-time SLA metadata
            // and never become an SA @const binding. Non-scalar aliases (e.g. of
            // a string/array const) are likewise handled as SLA metadata here; the
            // use-site binding resolves via global_const_bindings. Return without
            // emitting any SA text.
            //
            // If the alias target is unknown (not in global_const_bindings), jump
            // to the prior structural-error path rather than silently succeeding
            // so a future unsupported initializer still surfaces loudly.
            .identifier => |name| {
                if (self.global_scalar_consts.contains(c.name)) return;
                if (self.global_const_bindings.contains(name)) return;
                return CodegenError.CodegenError;
            },
            // const N = a OP b; (typically `0 - 1` to express a negative integer
            // literal). Scalar binary expressions are folded during `generate`
            // (see foldTopLevelBinaryConst) into the same global_scalar_consts
            // table used by literal/alias consts, so use sites resolve to the
            // computed value. There is nothing material to emit here: scalar
            // consts live as compile-time SLA metadata and never become an SA
            // @const binding. If the fold never happened for this decl, surface
            // the gap loudly rather than silently succeeding.
            .binary_expr => |bin| {
                _ = bin;
                if (self.global_scalar_consts.contains(c.name)) return;
                return CodegenError.CodegenError;
            },
            else => return CodegenError.CodegenError,
        }
    }

    fn boxInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.boxInnerType(ty);
    }

    fn manuallyDropInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.manuallyDropInnerType(ty);
    }

    fn borrowedPrimitiveType(ty: *const ast.Type) ?*const ast.Type {
        return lowering_rules.borrowedPrimitiveType(ty);
    }

    fn arrayType(ty: *const ast.Type) ?ast.ArrayType {
        return lowering_rules.arrayType(ty);
    }

    fn isStringLikeType(ty: *const ast.Type) bool {
        return lowering_rules.isStringLikeType(ty);
    }

    fn isFormatStringType(ty: *const ast.Type) bool {
        return lowering_rules.isFormatStringType(ty);
    }

    fn escapedStringByteLen(value: []const u8) usize {
        var len: usize = 0;
        var i: usize = 0;
        while (i < value.len) : (i += 1) {
            if (value[i] == '\\' and i + 1 < value.len) {
                i += 1;
            }
            len += 1;
        }
        return len;
    }

    fn emitFormatPushConstBytes(self: *Codegen, out_reg: []const u8, bytes: []const u8) CodegenError!void {
        if (bytes.len == 0) return;
        const label = try self.newStringConst();
        self.out.writer().print("    @const {s} = utf8:\"{s}\"\n", .{ label, bytes }) catch return CodegenError.CodegenError;
        const ptr_reg = try self.newTmp();
        self.out.writer().print("    {s} = &{s}\n", .{ ptr_reg, label }) catch return CodegenError.CodegenError;
        const tag = try self.newTmp();
        self.out.writer().print("    EXPAND FORMAT_PUSH_BYTES {s}, {s}, {s}, {}\n", .{ tag, out_reg, ptr_reg, escapedStringByteLen(bytes) }) catch return CodegenError.CodegenError;
        try self.emitRelease(ptr_reg);
    }

    fn emitFormatPushStringLike(self: *Codegen, out_reg: []const u8, arg: *ast.Node, ty: *const ast.Type, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!void {
        const tag = try self.newTmp();
        if (isFormatStringType(ty)) {
            const string_reg = try self.genExpr(arg, hoisted_allocs);
            const slice_reg = try self.newTmp();
            self.out.writer().print("    EXPAND STRING_BUF_AS_STR {s}, {s}\n", .{ slice_reg, string_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    EXPAND FORMAT_PUSH_SLICE {s}, {s}, {s}\n", .{ tag, out_reg, slice_reg }) catch return CodegenError.CodegenError;
            try self.emitRelease(slice_reg);
            if (callArgNeedsRelease(arg)) try self.emitRelease(string_reg);
            return;
        }

        if (arg.* == .literal and arg.literal == .string_val) {
            const value = arg.literal.string_val;
            const label = try self.newStringConst();
            self.out.writer().print("    @const {s} = utf8:\"{s}\"\n", .{ label, value }) catch return CodegenError.CodegenError;
            const ptr_reg = try self.newTmp();
            self.out.writer().print("    {s} = &{s}\n", .{ ptr_reg, label }) catch return CodegenError.CodegenError;
            self.out.writer().print("    EXPAND FORMAT_PUSH_BYTES {s}, {s}, {s}, {}\n", .{ tag, out_reg, ptr_reg, escapedStringByteLen(value) }) catch return CodegenError.CodegenError;
            try self.emitRelease(ptr_reg);
            return;
        }

        if (ty.* == .primitive and ty.primitive == .raw_ptr) {
            const ptr_reg = try self.genExpr(arg, hoisted_allocs);
            const len_reg = try self.newTmp();
            self.out.writer().print("    EXPAND CSTR_LEN {s}, {s}\n", .{ len_reg, ptr_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    EXPAND FORMAT_PUSH_BYTES {s}, {s}, {s}, {s}\n", .{ tag, out_reg, ptr_reg, len_reg }) catch return CodegenError.CodegenError;
            try self.emitRelease(len_reg);
            if (callArgNeedsRelease(arg)) try self.emitRelease(ptr_reg);
            return;
        }

        const slice_reg = try self.genExpr(arg, hoisted_allocs);
        self.out.writer().print("    EXPAND FORMAT_PUSH_SLICE {s}, {s}, {s}\n", .{ tag, out_reg, slice_reg }) catch return CodegenError.CodegenError;
        if (callArgNeedsRelease(arg)) try self.emitRelease(slice_reg);
    }

    const StringLikePathRegs = struct {
        owner_reg: []const u8,
        slice_reg: []const u8,
        ptr_reg: []const u8,
        len_reg: []const u8,
        owner_needs_release: bool,
    };

    fn genStringLikePathRegs(self: *Codegen, arg: *ast.Node, ty: *const ast.Type, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!StringLikePathRegs {
        if (isFormatStringType(ty)) {
            const owner_reg = try self.genExpr(arg, hoisted_allocs);
            const slice_reg = try self.newTmp();
            const ptr_reg = try self.newTmp();
            const len_reg = try self.newTmp();
            self.out.writer().print("    EXPAND STRING_BUF_AS_STR {s}, {s}\n", .{ slice_reg, owner_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = load {s}+Slice_ptr as ptr\n", .{ ptr_reg, slice_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = load {s}+Slice_len as u64\n", .{ len_reg, slice_reg }) catch return CodegenError.CodegenError;
            return .{
                .owner_reg = owner_reg,
                .slice_reg = slice_reg,
                .ptr_reg = ptr_reg,
                .len_reg = len_reg,
                .owner_needs_release = callArgNeedsRelease(arg),
            };
        }

        const slice_reg = try self.genExpr(arg, hoisted_allocs);
        const ptr_reg = try self.newTmp();
        const len_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+Slice_ptr as ptr\n", .{ ptr_reg, slice_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    {s} = load {s}+Slice_len as u64\n", .{ len_reg, slice_reg }) catch return CodegenError.CodegenError;
        return .{
            .owner_reg = slice_reg,
            .slice_reg = slice_reg,
            .ptr_reg = ptr_reg,
            .len_reg = len_reg,
            .owner_needs_release = callArgNeedsRelease(arg),
        };
    }

    fn releaseStringLikePathRegs(self: *Codegen, regs: StringLikePathRegs) CodegenError!void {
        try self.emitRelease(regs.len_reg);
        try self.emitRelease(regs.ptr_reg);
        try self.emitRelease(regs.slice_reg);
        if (regs.owner_needs_release and !std.mem.eql(u8, regs.owner_reg, regs.slice_reg)) {
            try self.emitRelease(regs.owner_reg);
        }
    }

    fn emitFormatPushArg(self: *Codegen, out_reg: []const u8, arg: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!void {
        const ty = self.tc.expr_types.get(arg) orelse return CodegenError.CodegenError;
        if (isStringLikeType(ty)) {
            try self.emitFormatPushStringLike(out_reg, arg, ty, hoisted_allocs);
            return;
        }

        const val_reg = try self.genExpr(arg, hoisted_allocs);
        try self.emitFormatPushValue(out_reg, val_reg, ty);
        if (callArgNeedsRelease(arg)) try self.emitRelease(val_reg);
    }

    fn emitFormatPushValue(self: *Codegen, out_reg: []const u8, val_reg: []const u8, ty: *const ast.Type) CodegenError!void {
        const tag = try self.newTmp();
        const suffix = lowering_rules.debugFormatSuffix(ty) orelse return CodegenError.CodegenError;
        if (std.mem.eql(u8, suffix, "U64")) {
            self.out.writer().print("    EXPAND FORMAT_PUSH_U64 {s}, {s}, {s}\n", .{ tag, out_reg, val_reg }) catch return CodegenError.CodegenError;
        } else if (std.mem.eql(u8, suffix, "F64")) {
            self.out.writer().print("    EXPAND FORMAT_PUSH_F64 {s}, {s}, {s}, 10\n", .{ tag, out_reg, val_reg }) catch return CodegenError.CodegenError;
        } else if (std.mem.eql(u8, suffix, "BOOL")) {
            self.out.writer().print("    EXPAND FORMAT_PUSH_BOOL {s}, {s}, {s}\n", .{ tag, out_reg, val_reg }) catch return CodegenError.CodegenError;
        } else {
            self.out.writer().print("    EXPAND FORMAT_PUSH_I64 {s}, {s}, {s}\n", .{ tag, out_reg, val_reg }) catch return CodegenError.CodegenError;
        }
    }

    fn alignOffset(offset: usize, size: usize) usize {
        return lowering_rules.alignAggregateOffset(offset, size);
    }

    fn structSize(s: *const ast.StructDecl) usize {
        return lowering_rules.structAbiSize(s);
    }

    fn tupleSize(tuple: ast.TupleType) usize {
        return lowering_rules.tupleAbiSize(tuple);
    }

    fn tupleFieldLayout(tuple: ast.TupleType, index: usize) ?FieldLayout {
        const layout = lowering_rules.tupleFieldLayout(tuple, index) orelse return null;
        return .{ .offset = layout.offset, .ty_str = typeString(layout.ty) };
    }

    fn fieldLayout(s: *const ast.StructDecl, name: []const u8) ?FieldLayout {
        const layout = lowering_rules.structFieldLayout(s, name) orelse return null;
        return .{ .offset = layout.offset, .ty_str = typeString(layout.ty) };
    }

    fn aggregateFieldLayout(self: *Codegen, ty: *const ast.Type, name: []const u8) ?FieldLayout {
        return self.fieldLayoutForType(ty, name);
    }

    fn structDeclForType(self: *Codegen, ty: *const ast.Type) ?*ast.StructDecl {
        const curr = lowering_rules.peelBorrowPointerType(ty);
        if (curr.* != .user_defined) return null;
        const name = curr.user_defined.name;
        if (self.tc.structs.get(name)) |decl| return decl;
        if (self.tc.alias_struct_cache.get(name)) |decl| return decl;

        const local_name = lowering_rules.userDefinedLocalName(name);
        if (std.mem.eql(u8, local_name, name)) return null;
        if (self.tc.structs.get(local_name)) |decl| return decl;
        if (self.tc.alias_struct_cache.get(local_name)) |decl| return decl;
        return null;
    }

    fn fieldLayoutForType(self: *Codegen, ty: *const ast.Type, name: []const u8) ?FieldLayout {
        const decl = self.structDeclForType(ty) orelse return null;
        return fieldLayout(decl, name);
    }

    fn fieldTypeForType(self: *Codegen, ty: *const ast.Type, name: []const u8) ?*const ast.Type {
        const curr = lowering_rules.peelBorrowPointerType(ty);
        if (curr.* == .tuple) {
            const index = std.fmt.parseInt(usize, name, 10) catch return null;
            if (index >= curr.tuple.elems.len) return null;
            return curr.tuple.elems[index];
        }
        const decl = self.structDeclForType(curr) orelse return null;
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.ty;
        }
        return null;
    }

    fn macroArgTypeForName(self: *Codegen, name: []const u8) ?*const ast.Type {
        if (self.macro_arg_types.get(name)) |ty| {
            if (ty.* != .infer) return ty;
        }
        if (self.macro_arg_exprs.get(name)) |arg| {
            if (self.tc.expr_types.get(arg)) |ty| {
                if (ty.* != .infer) return ty;
            }
        }
        return null;
    }

    fn localBindingTypeForName(self: *Codegen, name: []const u8) ?*const ast.Type {
        if (self.local_binding_types.get(name)) |ty| {
            if (ty.* != .infer) return ty;
        }
        const resolved_name = self.resolveBindingName(name);
        if (!std.mem.eql(u8, resolved_name, name)) {
            if (self.local_binding_types.get(resolved_name)) |ty| {
                if (ty.* != .infer) return ty;
            }
        }
        return null;
    }

    fn rememberLocalBindingType(self: *Codegen, name: []const u8, ty: *const ast.Type) CodegenError!void {
        if (isDiscardName(name) or ty.* == .infer) return;
        self.local_binding_types.put(name, ty) catch return CodegenError.OutOfMemory;
    }

    fn makeBorrowType(self: *Codegen, inner: *const ast.Type) CodegenError!*const ast.Type {
        const ty = self.allocator.create(ast.Type) catch return CodegenError.OutOfMemory;
        ty.* = .{ .borrow = @constCast(inner) };
        return ty;
    }

    fn makeTupleType(self: *Codegen, elems: []*ast.Type) CodegenError!*const ast.Type {
        const ty = self.allocator.create(ast.Type) catch return CodegenError.OutOfMemory;
        ty.* = .{ .tuple = .{ .elems = elems } };
        return ty;
    }

    fn makeArrayType(self: *Codegen, elem_ty: *const ast.Type, len: usize) CodegenError!*const ast.Type {
        const ty = self.allocator.create(ast.Type) catch return CodegenError.OutOfMemory;
        ty.* = .{ .array = .{ .elem = @constCast(elem_ty), .len = len } };
        return ty;
    }

    fn makePrimitiveType(self: *Codegen, primitive: ast.Primitive) CodegenError!*const ast.Type {
        const ty = self.allocator.create(ast.Type) catch return CodegenError.OutOfMemory;
        ty.* = .{ .primitive = primitive };
        return ty;
    }

    fn makeSliceType(self: *Codegen, inner: *const ast.Type) CodegenError!*const ast.Type {
        const generics = self.allocator.alloc(*ast.Type, 1) catch return CodegenError.OutOfMemory;
        generics[0] = @constCast(inner);
        const ty = self.allocator.create(ast.Type) catch return CodegenError.OutOfMemory;
        ty.* = .{ .user_defined = .{ .name = "Slice", .generics = generics } };
        return ty;
    }

    fn makeSliceU8Type(self: *Codegen) CodegenError!*const ast.Type {
        const elem = try self.makePrimitiveType(.u8);
        return try self.makeSliceType(elem);
    }

    /// True when `expr` is a call to an imported macro in expression-output
    /// form (arity - 1 args, result delivered as the leading output register).
    fn importedMacroExpressionOutputCall(self: *Codegen, expr: *const ast.Node) bool {
        if (expr.* != .call_expr) return false;
        const call = &expr.call_expr;
        const macro = self.tc.imported_macros.get(call.func_name) orelse return false;
        return lowering_rules.importedMacroUsesExpressionOutput(macro, call.args.len);
    }

    fn makeImportedMacroExpressionResultType(
        self: *Codegen,
        kind: lowering_rules.ImportedMacroExpressionResultKind,
    ) CodegenError!*const ast.Type {
        return switch (kind) {
            .raw_pointer => try self.makePrimitiveType(.raw_ptr),
            .boolean => try self.makePrimitiveType(.boolean),
            .u8 => try self.makePrimitiveType(.u8),
            .u32 => try self.makePrimitiveType(.u32),
            .u64 => try self.makePrimitiveType(.u64),
            .i32 => try self.makePrimitiveType(.i32),
            .i64 => try self.makePrimitiveType(.i64),
            .f64 => try self.makePrimitiveType(.f64),
            .slice_u8 => try self.makeSliceU8Type(),
        };
    }

    fn resolvedTypeForExpr(self: *Codegen, expr: *const ast.Node) ?*const ast.Type {
        if (self.tc.expr_types.get(expr)) |ty| {
            if (ty.* != .infer) return ty;
        }
        return switch (expr.*) {
            .literal => |lit| switch (lit) {
                .int_val => self.makePrimitiveType(.i64) catch null,
                .float_val => self.makePrimitiveType(.f64) catch null,
                .bool_val => self.makePrimitiveType(.boolean) catch null,
                .string_val => self.makePrimitiveType(.raw_ptr) catch null,
            },
            .identifier => |name| self.macroArgTypeForName(name) orelse self.localBindingTypeForName(name),
            .call_expr => |call| blk: {
                if (self.tc.funcs.get(call.func_name)) |func| break :blk func.ret_ty;
                if (self.tc.imported_function_signatures.get(call.func_name)) |signature| break :blk signature.ret_ty;
                if (lowering_rules.isBareLenUnaryCall(call)) {
                    break :blk self.makePrimitiveType(.usize) catch null;
                }
                if (self.tc.imported_macros.get(call.func_name)) |macro| {
                    if (macro.leading_outputs == 1 and call.args.len + 1 == macro.arity) {
                        if (lowering_rules.importedMacroExpressionResultKind(call.func_name)) |kind| {
                            break :blk self.makeImportedMacroExpressionResultType(kind) catch null;
                        }
                    }
                }
                break :blk null;
            },
            .binary_expr => |bin| blk: {
                if (bin.op == .eq or bin.op == .ne or bin.op == .lt or bin.op == .le or bin.op == .gt or bin.op == .ge or bin.op == .logical_and or bin.op == .logical_or) {
                    break :blk self.makePrimitiveType(.boolean) catch null;
                }
                break :blk self.resolvedTypeForExpr(bin.left) orelse self.resolvedTypeForExpr(bin.right);
            },
            .borrow_expr => |borrow| blk: {
                const inner = self.resolvedTypeForExpr(borrow.expr) orelse break :blk null;
                break :blk self.makeBorrowType(inner) catch null;
            },
            .deref_expr => |deref| blk: {
                const source_ty = self.resolvedTypeForExpr(deref.expr) orelse break :blk null;
                break :blk switch (source_ty.*) {
                    .borrow => |inner| inner,
                    .pointer => |inner| inner,
                    else => if (lowering_rules.smartPointerDerefType(source_ty)) |smart| smart.inner else null,
                };
            },
            .cast_expr => |cast| cast.ty,
            .field_expr => |field| blk: {
                const target_ty = self.resolvedTypeForExpr(field.expr) orelse break :blk null;
                break :blk self.fieldTypeForType(target_ty, field.field_name);
            },
            .index_expr => |idx| blk: {
                const target_ty = self.resolvedTypeForExpr(idx.target) orelse break :blk null;
                if (arrayType(@constCast(target_ty))) |arr| break :blk arr.elem;
                if (sliceElementType(target_ty)) |elem| break :blk elem;
                if (vecElementType(target_ty)) |elem| break :blk elem;
                if (vecDequeElementType(target_ty)) |elem| break :blk elem;
                break :blk null;
            },
            .struct_literal => |lit| lit.ty,
            .tuple_literal => |lit| blk: {
                if (lit.elements.len == 0) break :blk null;
                const elems = self.allocator.alloc(*ast.Type, lit.elements.len) catch break :blk null;
                for (lit.elements, 0..) |elem, i| {
                    elems[i] = @constCast(self.resolvedTypeForExpr(elem) orelse break :blk null);
                }
                break :blk self.makeTupleType(elems) catch null;
            },
            .array_literal => |lit| blk: {
                if (lit.elements.len == 0) break :blk null;
                const elem_ty = self.resolvedTypeForExpr(lit.elements[0]) orelse break :blk null;
                break :blk self.makeArrayType(elem_ty, lit.elements.len) catch null;
            },
            .repeat_array_literal => |lit| blk: {
                const elem_ty = self.resolvedTypeForExpr(lit.value) orelse break :blk null;
                break :blk self.makeArrayType(elem_ty, lit.len) catch null;
            },
            .move_expr => |move| self.resolvedTypeForExpr(move.expr),
            else => null,
        };
    }

    fn deriveNameMatches(actual: []const u8, wanted: []const u8) bool {
        return lowering_rules.deriveNameMatches(actual, wanted);
    }

    fn typeHasCopyDerive(self: *Codegen, ty: *const ast.Type) bool {
        if (lowering_rules.typeHasCopyDeriveBase(ty)) |decision| return decision;
        if (ty.* != .user_defined) return false;
        // Match SAB: std owners are never Copy even with derives absent/present noise.
        const decl = self.structDeclForType(ty) orelse return false;
        if (!lowering_rules.typeHasCopyDeriveStructGate(decl)) return false;
        for (decl.fields) |field| {
            if (!self.typeHasCopyDerive(field.ty)) return false;
        }
        return true;
    }

    fn typeIsCopyStruct(self: *Codegen, ty: *const ast.Type) bool {
        return lowering_rules.typeIsCopyStructFact(self.structDeclForType(ty) != null, self.typeHasCopyDerive(ty));
    }

    fn typeIsCopyValue(self: *Codegen, ty: *const ast.Type) bool {
        if (lowering_rules.typeIsCopyValueBase(ty)) |decision| return decision;
        return switch (ty.*) {
            .user_defined => self.typeHasCopyDerive(ty),
            .tuple => |tuple| blk: {
                for (tuple.elems) |elem| {
                    if (!self.typeIsCopyValue(elem)) break :blk false;
                }
                break :blk true;
            },
            .array => |arr| self.typeIsCopyValue(arr.elem),
            else => false,
        };
    }

    fn typeIsShallowCopyCallArgValue(self: *Codegen, ty: *const ast.Type, depth: usize) bool {
        if (lowering_rules.shallowCopyCallArgValueBase(ty, depth)) |decision| return decision;
        return switch (ty.*) {
            .tuple => |tuple| blk: {
                for (tuple.elems) |elem| {
                    if (!self.typeIsShallowCopyCallArgValue(elem, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            .array => |arr| self.typeIsShallowCopyCallArgValue(arr.elem, depth + 1),
            .user_defined => |ud| blk: {
                if (lowering_rules.shallowCopyCallArgUserDefinedBase(ty, depth)) |decision| break :blk decision;
                // Pure enums are POD-like at the register/ABI level even without
                // an explicit Copy derive. Treating them as non-shallow-copy made
                // structs such as ComponentInfo (i32 + enum) look ownership-only,
                // so SA vec.push emitted ^value and then reusing the local failed.
                if (self.tc.enums.contains(ud.name)) break :blk true;
                const decl = self.structDeclForType(ty) orelse break :blk false;
                if (!lowering_rules.shallowCopyCallArgStructGate(decl)) break :blk false;
                for (decl.fields) |field| {
                    if (!self.typeIsShallowCopyCallArgValue(field.ty, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    /// Vec push may copy bit-patterns for POD / shallow-copyable elements even when
    /// the type lacks an explicit Copy derive. Ownership transfer is only required
    /// for true non-copy owners (Vec, Box, String, etc.).
    fn vecElementPushConsumesSource(self: *Codegen, elem_ty: *const ast.Type) bool {
        const copy_like = self.typeIsCopyValue(elem_ty) or self.typeIsShallowCopyCallArgValue(elem_ty, 0);
        return lowering_rules.vecElementPushTransfersOwnership(elem_ty, copy_like);
    }

    fn typeIsSmallPlainSlotStruct(self: *Codegen, ty: *const ast.Type) bool {
        const decl = self.structDeclForType(ty) orelse return false;
        return lowering_rules.typeIsSmallPlainSlotStructDecl(decl);
    }

    fn slotCopyStructType(self: *Codegen, ty: *const ast.Type) ?*const ast.Type {
        const pointed_ty: ?*const ast.Type = if (ty.* == .pointer) ty.pointer else null;
        return lowering_rules.slotCopyStructTypeFact(
            ty,
            self.structDeclForType(ty) != null,
            pointed_ty,
            if (pointed_ty) |inner| self.structDeclForType(inner) != null else false,
        );
    }

    fn typeHasHashDerive(self: *Codegen, ty: *const ast.Type) bool {
        const primitive_ok = if (ty.* == .primitive) lowering_rules.primitiveIsHashable(ty.primitive) else false;
        if (lowering_rules.typeHasNamedDeriveBase(ty, primitive_ok)) |decision| return decision;
        if (ty.* != .user_defined) return false;
        const decl = self.structDeclForType(ty) orelse return false;
        if (!lowering_rules.typeHasNamedDeriveStructGate(decl, "hash")) return false;
        for (decl.fields) |field| {
            if (!self.typeHasHashDerive(field.ty)) return false;
        }
        return true;
    }

    fn typeHasDebugDerive(self: *Codegen, ty: *const ast.Type) bool {
        const primitive_ok = if (ty.* == .primitive) lowering_rules.primitiveIsCopyValue(ty.primitive) else false;
        if (lowering_rules.typeHasNamedDeriveBase(ty, primitive_ok)) |decision| return decision;
        if (ty.* != .user_defined) return false;
        const decl = self.structDeclForType(ty) orelse return false;
        if (!lowering_rules.typeHasNamedDeriveStructGate(decl, "debug")) return false;
        for (decl.fields) |field| {
            if (!self.typeHasDebugDerive(field.ty)) return false;
        }
        return true;
    }

    fn isNumericType(ty: *const ast.Type) bool {
        return lowering_rules.isNumericType(ty);
    }

    fn isFloatType(ty: *const ast.Type) bool {
        return lowering_rules.isFloatType(ty);
    }

    fn isUnsignedIntegerType(ty: *const ast.Type) bool {
        return lowering_rules.isUnsignedIntegerType(ty);
    }

    fn binaryOpName(op: ast.BinaryOp, left_ty: *const ast.Type, right_ty: *const ast.Type) ?[]const u8 {
        const plan = lowering_rules.planScalarBinaryOp(op, left_ty, right_ty) orelse return null;
        return lowering_rules.scalarBinaryOpName(plan);
    }

    fn asyncContinuationConditionOpName(op: ast.BinaryOp) ?[]const u8 {
        return lowering_rules.asyncContinuationConditionOpName(op);
    }

    fn zeroLiteralForType(ty: *const ast.Type) []const u8 {
        return lowering_rules.zeroLiteralForType(ty);
    }

    fn literalZero(expr: *const ast.Node) bool {
        return lowering_rules.literalZero(expr);
    }

    fn arithmeticOpName(op: ast.BinaryOp) ?[]const u8 {
        return switch (op) {
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => "div",
            .mod => "rem",
            else => null,
        };
    }

    fn genStructArithmeticExpr(
        self: *Codegen,
        bin: *const ast.BinaryExpr,
        left_ty: *const ast.Type,
        right_ty: *const ast.Type,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!?[]const u8 {
        const left_struct = self.structDeclForType(left_ty);
        const right_struct = self.structDeclForType(right_ty);

        if (left_struct == null and right_struct == null) return null;
        const op = arithmeticOpName(bin.op) orelse return null;

        const struct_decl = left_struct orelse right_struct.?;
        if (struct_decl.is_opaque or struct_decl.is_union) return null;

        const result = try self.newTmp();
        self.out.writer().print("    {s} = alloc {}\n", .{ result, structSize(struct_decl) }) catch return CodegenError.CodegenError;

        if (left_struct != null and right_struct != null) {
            if (left_struct.? != right_struct.? or !(bin.op == .add or bin.op == .sub)) return null;
            const left_reg = try self.genExpr(bin.left, hoisted_allocs);
            const right_reg = try self.genExpr(bin.right, hoisted_allocs);
            for (struct_decl.fields) |field| {
                if (!isNumericType(field.ty)) return CodegenError.CodegenError;
                const layout = fieldLayout(struct_decl, field.name) orelse return CodegenError.CodegenError;
                const lhs = try self.newTmp();
                const rhs = try self.newTmp();
                const value = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ lhs, left_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
                self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ rhs, right_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
                self.out.writer().print("    {s} = {s} {s}, {s}\n", .{ value, op, lhs, rhs }) catch return CodegenError.CodegenError;
                self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ result, layout.offset, value, layout.ty_str }) catch return CodegenError.CodegenError;
            }
            if (callArgNeedsRelease(bin.left)) try self.emitRelease(left_reg);
            if (callArgNeedsRelease(bin.right)) try self.emitRelease(right_reg);
            return result;
        }

        if (right_struct != null and bin.op == .sub and literalZero(bin.left)) {
            const zero_reg = try self.genExpr(bin.left, hoisted_allocs);
            try self.emitRelease(zero_reg);
            const right_reg = try self.genExpr(bin.right, hoisted_allocs);
            for (struct_decl.fields) |field| {
                if (!isNumericType(field.ty)) return CodegenError.CodegenError;
                const layout = fieldLayout(struct_decl, field.name) orelse return CodegenError.CodegenError;
                const rhs = try self.newTmp();
                const value = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ rhs, right_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
                self.out.writer().print("    {s} = sub {s}, {s}\n", .{ value, zeroLiteralForType(field.ty), rhs }) catch return CodegenError.CodegenError;
                self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ result, layout.offset, value, layout.ty_str }) catch return CodegenError.CodegenError;
            }
            if (callArgNeedsRelease(bin.right)) try self.emitRelease(right_reg);
            return result;
        }

        if (bin.op == .mul and left_struct != null and isNumericType(right_ty)) {
            const left_reg = try self.genExpr(bin.left, hoisted_allocs);
            const scalar = try self.genExpr(bin.right, hoisted_allocs);
            for (struct_decl.fields) |field| {
                if (!isNumericType(field.ty)) return CodegenError.CodegenError;
                const layout = fieldLayout(struct_decl, field.name) orelse return CodegenError.CodegenError;
                const lhs = try self.newTmp();
                const value = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ lhs, left_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
                self.out.writer().print("    {s} = mul {s}, {s}\n", .{ value, lhs, scalar }) catch return CodegenError.CodegenError;
                self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ result, layout.offset, value, layout.ty_str }) catch return CodegenError.CodegenError;
            }
            if (callArgNeedsRelease(bin.left)) try self.emitRelease(left_reg);
            if (callArgNeedsRelease(bin.right)) try self.emitRelease(scalar);
            return result;
        }

        if (bin.op == .mul and right_struct != null and isNumericType(left_ty)) {
            const scalar = try self.genExpr(bin.left, hoisted_allocs);
            const right_reg = try self.genExpr(bin.right, hoisted_allocs);
            for (struct_decl.fields) |field| {
                if (!isNumericType(field.ty)) return CodegenError.CodegenError;
                const layout = fieldLayout(struct_decl, field.name) orelse return CodegenError.CodegenError;
                const rhs = try self.newTmp();
                const value = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ rhs, right_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
                self.out.writer().print("    {s} = mul {s}, {s}\n", .{ value, scalar, rhs }) catch return CodegenError.CodegenError;
                self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ result, layout.offset, value, layout.ty_str }) catch return CodegenError.CodegenError;
            }
            if (callArgNeedsRelease(bin.left)) try self.emitRelease(scalar);
            if (callArgNeedsRelease(bin.right)) try self.emitRelease(right_reg);
            return result;
        }

        return null;
    }

    fn genStructEqualityExpr(
        self: *Codegen,
        bin: *const ast.BinaryExpr,
        left_ty: *const ast.Type,
        right_ty: *const ast.Type,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!?[]const u8 {
        if (!(bin.op == .eq or bin.op == .ne)) return null;
        const left_struct = self.structDeclForType(left_ty) orelse return null;
        const right_struct = self.structDeclForType(right_ty) orelse return null;
        if (left_struct != right_struct or left_struct.is_opaque or left_struct.is_union) return null;

        const left_reg = try self.genExpr(bin.left, hoisted_allocs);
        const right_reg = try self.genExpr(bin.right, hoisted_allocs);
        var acc: ?[]const u8 = null;
        for (left_struct.fields) |field| {
            const layout = fieldLayout(left_struct, field.name) orelse return CodegenError.CodegenError;
            const lhs = try self.newTmp();
            const rhs = try self.newTmp();
            const eq_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ lhs, left_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ rhs, right_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = eq {s}, {s}\n", .{ eq_reg, lhs, rhs }) catch return CodegenError.CodegenError;
            if (acc) |prev| {
                const next = try self.newTmp();
                self.out.writer().print("    {s} = and {s}, {s}\n", .{ next, prev, eq_reg }) catch return CodegenError.CodegenError;
                acc = next;
            } else {
                acc = eq_reg;
            }
        }

        const result = try self.newTmp();
        if (acc) |eq_all| {
            if (bin.op == .eq) {
                self.out.writer().print("    {s} = or {s}, 0\n", .{ result, eq_all }) catch return CodegenError.CodegenError;
            } else {
                self.out.writer().print("    {s} = ne {s}, 1\n", .{ result, eq_all }) catch return CodegenError.CodegenError;
            }
        } else {
            const empty_value: i32 = if (bin.op == .eq) 1 else 0;
            self.out.writer().print("    {s} = {}\n", .{ result, empty_value }) catch return CodegenError.CodegenError;
        }
        if (callArgNeedsRelease(bin.left)) try self.emitRelease(left_reg);
        if (callArgNeedsRelease(bin.right)) try self.emitRelease(right_reg);
        return result;
    }

    fn genStructOrdExpr(
        self: *Codegen,
        bin: *const ast.BinaryExpr,
        left_ty: *const ast.Type,
        right_ty: *const ast.Type,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!?[]const u8 {
        if (!(bin.op == .lt or bin.op == .le or bin.op == .gt or bin.op == .ge)) return null;
        const left_struct = self.structDeclForType(left_ty) orelse return null;
        const right_struct = self.structDeclForType(right_ty) orelse return null;
        if (left_struct != right_struct or left_struct.is_opaque or left_struct.is_union) return null;
        if (!lowering_rules.structHasDerive(left_struct, "ord")) return null;

        const left_reg = try self.genExpr(bin.left, hoisted_allocs);
        const right_reg = try self.genExpr(bin.right, hoisted_allocs);
        var order_acc: ?[]const u8 = null;
        var eq_prefix: ?[]const u8 = null;

        for (left_struct.fields) |field| {
            const layout = fieldLayout(left_struct, field.name) orelse return CodegenError.CodegenError;
            const lhs = try self.newTmp();
            const rhs = try self.newTmp();
            const cmp = try self.newTmp();
            const eq_reg = try self.newTmp();
            const cmp_op: []const u8 = switch (bin.op) {
                .lt, .le => "slt",
                .gt, .ge => "sgt",
                else => unreachable,
            };
            self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ lhs, left_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ rhs, right_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = {s} {s}, {s}\n", .{ cmp, cmp_op, lhs, rhs }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = eq {s}, {s}\n", .{ eq_reg, lhs, rhs }) catch return CodegenError.CodegenError;

            const term = if (eq_prefix) |prefix| blk: {
                const t = try self.newTmp();
                self.out.writer().print("    {s} = and {s}, {s}\n", .{ t, prefix, cmp }) catch return CodegenError.CodegenError;
                break :blk t;
            } else cmp;

            order_acc = if (order_acc) |prev| blk: {
                const next = try self.newTmp();
                self.out.writer().print("    {s} = or {s}, {s}\n", .{ next, prev, term }) catch return CodegenError.CodegenError;
                break :blk next;
            } else term;

            eq_prefix = if (eq_prefix) |prefix| blk: {
                const next = try self.newTmp();
                self.out.writer().print("    {s} = and {s}, {s}\n", .{ next, prefix, eq_reg }) catch return CodegenError.CodegenError;
                break :blk next;
            } else eq_reg;
        }

        const result = try self.newTmp();
        if (order_acc) |ordered| {
            if (bin.op == .le or bin.op == .ge) {
                const eq_all = eq_prefix orelse return CodegenError.CodegenError;
                self.out.writer().print("    {s} = or {s}, {s}\n", .{ result, ordered, eq_all }) catch return CodegenError.CodegenError;
            } else {
                self.out.writer().print("    {s} = or {s}, 0\n", .{ result, ordered }) catch return CodegenError.CodegenError;
            }
        } else {
            const empty_value: i32 = if (bin.op == .le or bin.op == .ge) 1 else 0;
            self.out.writer().print("    {s} = {}\n", .{ result, empty_value }) catch return CodegenError.CodegenError;
        }
        if (callArgNeedsRelease(bin.left)) try self.emitRelease(left_reg);
        if (callArgNeedsRelease(bin.right)) try self.emitRelease(right_reg);
        return result;
    }

    fn emitOrderingStore(self: *Codegen, target: []const u8, value_literal: []const u8) CodegenError!void {
        self.out.writer().print("    store {s}+0, {s} as i64\n", .{ target, value_literal }) catch return CodegenError.CodegenError;
    }

    fn genOrderingStructFromRaw(self: *Codegen, raw_value: []const u8) CodegenError![]const u8 {
        const result = try self.newTmp();
        self.out.writer().print("    {s} = alloc 8\n", .{result}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {s} as i64\n", .{ result, raw_value }) catch return CodegenError.CodegenError;
        return result;
    }

    fn genNumericSpaceshipRaw(
        self: *Codegen,
        left_reg: []const u8,
        right_reg: []const u8,
        ty: *const ast.Type,
    ) CodegenError![]const u8 {
        const raw = try self.newTmp();
        if (isFloatType(ty)) {
            const less = try self.newTmp();
            const greater = try self.newTmp();
            const less_label = try self.newLabel("L_SPACESHIP_FLOAT_LESS");
            const greater_check_label = try self.newLabel("L_SPACESHIP_FLOAT_CHECK_GREATER");
            const greater_label = try self.newLabel("L_SPACESHIP_FLOAT_GREATER");
            const equal_label = try self.newLabel("L_SPACESHIP_FLOAT_EQUAL");
            const done_label = try self.newLabel("L_SPACESHIP_FLOAT_DONE");
            self.out.writer().print("    {s} = fcmp_lt {s}, {s}\n", .{ less, left_reg, right_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ less, less_label, greater_check_label }) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{less_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = add 0, CMP_ORDERING_LESS\n", .{raw}) catch return CodegenError.CodegenError;
            self.out.writer().print("    jmp {s}\n\n", .{done_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{greater_check_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = fcmp_gt {s}, {s}\n", .{ greater, left_reg, right_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ greater, greater_label, equal_label }) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{greater_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = add 0, CMP_ORDERING_GREATER\n", .{raw}) catch return CodegenError.CodegenError;
            self.out.writer().print("    jmp {s}\n\n", .{done_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{equal_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = add 0, CMP_ORDERING_EQUAL\n", .{raw}) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{done_label}) catch return CodegenError.CodegenError;
            return raw;
        }

        const macro_name: []const u8 = if (isUnsignedIntegerType(ty)) "CMP_COMPARE_U64" else "CMP_COMPARE_I64";
        self.out.writer().print("    EXPAND {s} {s}, {s}, {s}\n", .{ macro_name, raw, left_reg, right_reg }) catch return CodegenError.CodegenError;
        return raw;
    }

    fn genSpaceshipExpr(
        self: *Codegen,
        bin: *const ast.BinaryExpr,
        left_ty: *const ast.Type,
        right_ty: *const ast.Type,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!?[]const u8 {
        if (bin.op != .spaceship) return null;
        const plan = lowering_rules.planSpaceship(
            left_ty,
            right_ty,
            self.structDeclForType(left_ty),
            self.structDeclForType(right_ty),
        ) orelse return CodegenError.CodegenError;
        const left_reg = try self.genExpr(bin.left, hoisted_allocs);
        const right_reg = try self.genExpr(bin.right, hoisted_allocs);

        if (plan.isNumeric()) {
            const raw = try self.genNumericSpaceshipRaw(left_reg, right_reg, left_ty);
            const result = try self.genOrderingStructFromRaw(raw);
            if (callArgNeedsRelease(bin.left)) try self.emitRelease(left_reg);
            if (callArgNeedsRelease(bin.right)) try self.emitRelease(right_reg);
            return result;
        }

        const left_struct = plan.struct_decl orelse return CodegenError.CodegenError;

        const result = try self.newTmp();
        const done_label = try self.newLabel("L_SPACESHIP_STRUCT_DONE");
        self.out.writer().print("    {s} = alloc 8\n", .{result}) catch return CodegenError.CodegenError;
        try self.emitOrderingStore(result, "CMP_ORDERING_EQUAL");
        for (left_struct.fields) |field| {
            const layout = fieldLayout(left_struct, field.name) orelse return CodegenError.CodegenError;
            const lhs = try self.newTmp();
            const rhs = try self.newTmp();
            const less = try self.newTmp();
            const greater = try self.newTmp();
            const less_label = try self.newLabel("L_SPACESHIP_STRUCT_LESS");
            const greater_check_label = try self.newLabel("L_SPACESHIP_STRUCT_CHECK_GREATER");
            const greater_label = try self.newLabel("L_SPACESHIP_STRUCT_GREATER");
            const next_label = try self.newLabel("L_SPACESHIP_STRUCT_NEXT");
            const less_op: []const u8 = if (isUnsignedIntegerType(field.ty)) "ult" else "slt";
            const greater_op: []const u8 = if (isUnsignedIntegerType(field.ty)) "ugt" else "sgt";
            self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ lhs, left_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ rhs, right_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = {s} {s}, {s}\n", .{ less, less_op, lhs, rhs }) catch return CodegenError.CodegenError;
            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ less, less_label, greater_check_label }) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{less_label}) catch return CodegenError.CodegenError;
            try self.emitOrderingStore(result, "CMP_ORDERING_LESS");
            self.out.writer().print("    jmp {s}\n\n", .{done_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{greater_check_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = {s} {s}, {s}\n", .{ greater, greater_op, lhs, rhs }) catch return CodegenError.CodegenError;
            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ greater, greater_label, next_label }) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{greater_label}) catch return CodegenError.CodegenError;
            try self.emitOrderingStore(result, "CMP_ORDERING_GREATER");
            self.out.writer().print("    jmp {s}\n\n", .{done_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{next_label}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print("{s}:\n", .{done_label}) catch return CodegenError.CodegenError;
        if (callArgNeedsRelease(bin.left)) try self.emitRelease(left_reg);
        if (callArgNeedsRelease(bin.right)) try self.emitRelease(right_reg);
        return result;
    }

    fn genCopyValueInto(self: *Codegen, target: []const u8, source_reg: []const u8, ty: *const ast.Type) CodegenError!void {
        const struct_decl = self.structDeclForType(ty) orelse return CodegenError.CodegenError;
        if (!self.typeHasCopyDerive(ty) or struct_decl.is_opaque or struct_decl.is_union) return CodegenError.CodegenError;
        self.out.writer().print("    {s} = alloc {}\n", .{ target, structSize(struct_decl) }) catch return CodegenError.CodegenError;
        for (struct_decl.fields) |field| {
            const layout = fieldLayout(struct_decl, field.name) orelse return CodegenError.CodegenError;
            const field_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ field_reg, source_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
            if (self.structDeclForType(field.ty) != null) {
                const copied_field = try self.newTmp();
                try self.genCopyValueInto(copied_field, field_reg, field.ty);
                self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, copied_field, layout.ty_str }) catch return CodegenError.CodegenError;
            } else {
                self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, field_reg, layout.ty_str }) catch return CodegenError.CodegenError;
            }
        }
    }

    fn genShallowCopyCallArgValue(self: *Codegen, source_reg: []const u8, ty: *const ast.Type) CodegenError![]const u8 {
        const struct_decl = self.structDeclForType(ty) orelse return CodegenError.CodegenError;
        if (!self.typeIsShallowCopyCallArgValue(ty, 0) or struct_decl.is_opaque or struct_decl.is_union) return CodegenError.CodegenError;

        const target = try self.newTmp();
        self.out.writer().print("    {s} = alloc {}\n", .{ target, structSize(struct_decl) }) catch return CodegenError.CodegenError;
        for (struct_decl.fields) |field| {
            const layout = fieldLayout(struct_decl, field.name) orelse return CodegenError.CodegenError;
            const field_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ field_reg, source_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
            if (lowering_rules.shallowCopyCallArgFieldShouldRecurse(self.structDeclForType(field.ty) != null, field.ty)) {
                const copied_field = try self.genShallowCopyCallArgValue(field_reg, field.ty);
                self.out.writer().print("    store {s}+{}, ^{s} as {s}\n", .{ target, layout.offset, copied_field, layout.ty_str }) catch return CodegenError.CodegenError;
                try self.emitRelease(field_reg);
            } else {
                self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, field_reg, layout.ty_str }) catch return CodegenError.CodegenError;
                try self.emitRelease(field_reg);
            }
        }
        return target;
    }

    fn primitiveHashBits(self: *Codegen, value_reg: []const u8, ty: *const ast.Type) CodegenError![]const u8 {
        if (ty.* != .primitive) return CodegenError.CodegenError;
        if (std.mem.eql(u8, typeString(ty), "u64")) return value_reg;
        const bits = try self.newTmp();
        self.out.writer().print("    {s} = {s} as u64\n", .{ bits, value_reg }) catch return CodegenError.CodegenError;
        return bits;
    }

    fn genHashValue(self: *Codegen, value_reg: []const u8, ty: *const ast.Type) CodegenError![]const u8 {
        if (ty.* == .primitive) return try self.primitiveHashBits(value_reg, ty);
        const struct_decl = self.structDeclForType(ty) orelse return CodegenError.CodegenError;
        if (!self.typeHasHashDerive(ty) or struct_decl.is_opaque or struct_decl.is_union) return CodegenError.CodegenError;

        var hash_reg = try self.newTmp();
        try self.emitIntConst(hash_reg, 1469598103934665603);
        for (struct_decl.fields) |field| {
            const layout = fieldLayout(struct_decl, field.name) orelse return CodegenError.CodegenError;
            const field_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ field_reg, value_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
            const field_hash = try self.genHashValue(field_reg, field.ty);
            const mixed = try self.newTmp();
            const next = try self.newTmp();
            self.out.writer().print("    {s} = xor {s}, {s}\n", .{ mixed, hash_reg, field_hash }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = mul {s}, 1099511628211\n", .{ next, mixed }) catch return CodegenError.CodegenError;
            hash_reg = next;
        }
        return hash_reg;
    }

    fn genHashCall(self: *Codegen, call: *const ast.CallExpr, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        if (call.args.len != 1) return CodegenError.CodegenError;
        const ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
        const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
        const result = try self.genHashValue(value_reg, ty);
        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
        return result;
    }

    fn genDebugValue(self: *Codegen, out_reg: []const u8, value_reg: []const u8, ty: *const ast.Type) CodegenError!void {
        if (ty.* == .primitive) {
            try self.emitFormatPushValue(out_reg, value_reg, ty);
            return;
        }
        const struct_decl = self.structDeclForType(ty) orelse return CodegenError.CodegenError;
        if (!self.typeHasDebugDerive(ty) or struct_decl.is_opaque or struct_decl.is_union) return CodegenError.CodegenError;
        try self.emitFormatPushConstBytes(out_reg, struct_decl.name);
        try self.emitFormatPushConstBytes(out_reg, " { ");
        for (struct_decl.fields, 0..) |field, i| {
            if (i > 0) try self.emitFormatPushConstBytes(out_reg, ", ");
            try self.emitFormatPushConstBytes(out_reg, field.name);
            try self.emitFormatPushConstBytes(out_reg, ": ");
            const layout = fieldLayout(struct_decl, field.name) orelse return CodegenError.CodegenError;
            const field_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ field_reg, value_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
            try self.genDebugValue(out_reg, field_reg, field.ty);
        }
        try self.emitFormatPushConstBytes(out_reg, " }");
    }

    fn genDebugCall(self: *Codegen, call: *const ast.CallExpr, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        if (call.args.len != 1) return CodegenError.CodegenError;
        const ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
        const out_reg = try self.newTmp();
        self.out.writer().print("    EXPAND FORMAT_BEGIN {s}, 128\n", .{out_reg}) catch return CodegenError.CodegenError;
        const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
        try self.genDebugValue(out_reg, value_reg, ty);
        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
        self.string_buf_bindings.put(out_reg, {}) catch return CodegenError.OutOfMemory;
        return out_reg;
    }

    // Enum tag/payload layout is owned by the shared `lowering_rules` layer so
    // SA-text and direct SAB agree on discriminant index, payload offsets, and
    // total size. These thin wrappers adapt the shared results to the SA-text
    // `FieldLayout` shape (which carries a `ty_str` for the text emitter).
    fn enumVariantIndex(e: *const ast.EnumDecl, name: []const u8) ?usize {
        return lowering_rules.enumVariantIndex(e, name);
    }

    fn enumVariant(e: *const ast.EnumDecl, name: []const u8) ?ast.EnumVariant {
        return lowering_rules.enumVariant(e, name);
    }

    fn enumFieldLayout(variant: ast.EnumVariant, name: []const u8) ?FieldLayout {
        const layout = lowering_rules.enumFieldLayout(variant, name) orelse return null;
        return .{ .offset = layout.offset, .ty_str = typeString(layout.ty) };
    }

    fn genEnumPatternCheck(self: *Codegen, decl: *const ast.EnumDecl, pattern: ast.EnumPattern, value_reg: []const u8, branch_flag: []const u8) CodegenError!void {
        const tag_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as i64\n", .{ tag_reg, value_reg }) catch return CodegenError.CodegenError;
        const tag = enumVariantIndex(decl, pattern.variant_name) orelse return CodegenError.CodegenError;
        const tag_const = try self.newTmp();
        try self.emitIntConst(tag_const, @as(i64, @intCast(tag)));
        self.out.writer().print("    {s} = eq {s}, {s}\n", .{ branch_flag, tag_reg, tag_const }) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{tag_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{tag_const}) catch return CodegenError.CodegenError;
    }

    fn genEnumPatternBindings(self: *Codegen, decl: *const ast.EnumDecl, pattern: ast.EnumPattern, value_reg: []const u8) CodegenError!void {
        const variant = enumVariant(decl, pattern.variant_name) orelse return CodegenError.CodegenError;
        if (pattern.bindings.len != variant.fields.len) return CodegenError.CodegenError;
        for (pattern.bindings, variant.fields) |binding, field| {
            const target = try self.pushBindingAlias(binding);
            const layout = enumFieldLayout(variant, field.name) orelse return CodegenError.CodegenError;
            self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ target, value_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
        }
    }

    fn enumSize(e: *const ast.EnumDecl) usize {
        return lowering_rules.enumAbiSize(e);
    }

    fn isVoidType(ty: *const ast.Type) bool {
        return lowering_rules.isVoidType(ty);
    }

    fn makeAbiPtrType(self: *Codegen) CodegenError!*const ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .raw_ptr };
        return ty;
    }

    fn emitArrayFillMacros(self: *Codegen) CodegenError!void {
        self.out.writer().print(
            \\
            \\[MACRO] SLA_ARRAY_FILL_U8 %array_ptr, %value, %length
            \\    call @sa_mem_set(&%array_ptr, %value, %length)
            \\[END_MACRO]
            \\
        , .{}) catch return CodegenError.CodegenError;
    }

    fn emitHashMapMacros(self: *Codegen) CodegenError!void {
        self.out.writer().print(
            \\
            \\[MACRO] SLA_MAP_TRY_GET_OPTION %out_opt, %map_reg, %key_reg
            \\    EXPAND MAP_TRY_GET __sla_map_get_ok_%out_opt, __sla_map_get_ptr_%out_opt, %map_reg, %key_reg
            \\    br __sla_map_get_ok_%out_opt -> L_SLA_MAP_GET_SOME_%out_opt, L_SLA_MAP_GET_NONE_%out_opt
            \\L_SLA_MAP_GET_SOME_%out_opt:
            \\    EXPAND OPTION_NEW_SOME %out_opt, __sla_map_get_ptr_%out_opt
            \\    !__sla_map_get_ptr_%out_opt
            \\    !__sla_map_get_ok_%out_opt
            \\    jmp L_SLA_MAP_GET_END_%out_opt
            \\L_SLA_MAP_GET_NONE_%out_opt:
            \\    EXPAND OPTION_NEW_NONE %out_opt
            \\    !__sla_map_get_ptr_%out_opt
            \\    !__sla_map_get_ok_%out_opt
            \\L_SLA_MAP_GET_END_%out_opt:
            \\[END_MACRO]
            \\
            \\[MACRO] SLA_MAP_INSERT_OPTION_U64 %out_opt, %map_reg, %key_reg, %value_reg
            \\    EXPAND MAP_INSERT __sla_map_insert_replaced_%out_opt, __sla_map_insert_old_ptr_%out_opt, %map_reg, %key_reg, %value_reg
            \\    br __sla_map_insert_replaced_%out_opt -> L_SLA_MAP_INSERT_SOME_%out_opt, L_SLA_MAP_INSERT_NONE_%out_opt
            \\L_SLA_MAP_INSERT_SOME_%out_opt:
            \\    __sla_map_insert_old_value_%out_opt = load __sla_map_insert_old_ptr_%out_opt+0 as u64
            \\    EXPAND OPTION_NEW_SOME %out_opt, __sla_map_insert_old_value_%out_opt
            \\    !__sla_map_insert_old_value_%out_opt
            \\    !__sla_map_insert_old_ptr_%out_opt
            \\    !__sla_map_insert_replaced_%out_opt
            \\    jmp L_SLA_MAP_INSERT_END_%out_opt
            \\L_SLA_MAP_INSERT_NONE_%out_opt:
            \\    EXPAND OPTION_NEW_NONE %out_opt
            \\    !__sla_map_insert_old_ptr_%out_opt
            \\    !__sla_map_insert_replaced_%out_opt
            \\L_SLA_MAP_INSERT_END_%out_opt:
            \\[END_MACRO]
            \\
        , .{}) catch return CodegenError.CodegenError;
    }

    fn emitBTreeMapMacros(self: *Codegen) CodegenError!void {
        self.out.writer().print(
            \\
            \\[MACRO] SLA_BTREE_MAP_INSERT_OPTION_U64 %out_opt, %map_reg, %key_reg, %value_reg
            \\    EXPAND BTREE_MAP_INSERT_OLD __sla_btree_insert_replaced_%out_opt, __sla_btree_insert_old_%out_opt, %map_reg, %key_reg, %value_reg
            \\    br __sla_btree_insert_replaced_%out_opt -> L_SLA_BTREE_INSERT_SOME_%out_opt, L_SLA_BTREE_INSERT_NONE_%out_opt
            \\L_SLA_BTREE_INSERT_SOME_%out_opt:
            \\    EXPAND OPTION_NEW_SOME %out_opt, __sla_btree_insert_old_%out_opt
            \\    !__sla_btree_insert_old_%out_opt
            \\    !__sla_btree_insert_replaced_%out_opt
            \\    jmp L_SLA_BTREE_INSERT_END_%out_opt
            \\L_SLA_BTREE_INSERT_NONE_%out_opt:
            \\    EXPAND OPTION_NEW_NONE %out_opt
            \\    !__sla_btree_insert_old_%out_opt
            \\    !__sla_btree_insert_replaced_%out_opt
            \\L_SLA_BTREE_INSERT_END_%out_opt:
            \\[END_MACRO]
            \\
            \\[MACRO] SLA_BTREE_MAP_TRY_GET_OPTION %out_opt, %map_reg, %key_reg
            \\    EXPAND BTREE_MAP_TRY_GET __sla_btree_get_ok_%out_opt, __sla_btree_get_value_%out_opt, %map_reg, %key_reg
            \\    br __sla_btree_get_ok_%out_opt -> L_SLA_BTREE_GET_SOME_%out_opt, L_SLA_BTREE_GET_NONE_%out_opt
            \\L_SLA_BTREE_GET_SOME_%out_opt:
            \\    __sla_btree_get_slot_%out_opt = stack_alloc 8
            \\    store __sla_btree_get_slot_%out_opt+0, __sla_btree_get_value_%out_opt as u64
            \\    EXPAND OPTION_NEW_SOME %out_opt, __sla_btree_get_slot_%out_opt
            \\    !__sla_btree_get_value_%out_opt
            \\    !__sla_btree_get_ok_%out_opt
            \\    jmp L_SLA_BTREE_GET_END_%out_opt
            \\L_SLA_BTREE_GET_NONE_%out_opt:
            \\    EXPAND OPTION_NEW_NONE %out_opt
            \\    !__sla_btree_get_value_%out_opt
            \\    !__sla_btree_get_ok_%out_opt
            \\L_SLA_BTREE_GET_END_%out_opt:
            \\[END_MACRO]
            \\
        , .{}) catch return CodegenError.CodegenError;
    }

    fn arrayIterSumSource(call: *const ast.CallExpr) ?*ast.Node {
        if (!std.mem.eql(u8, call.func_name, "sum") or call.args.len != 1) return null;
        const iter_expr = call.args[0];
        if (iter_expr.* != .call_expr) return null;
        const iter_call = &iter_expr.call_expr;
        if (!lowering_rules.isIterCall(iter_call.*) or iter_call.args.len != 1) return null;
        return iter_call.args[0];
    }

    fn stringCollectSource(call: *const ast.CallExpr) ?*ast.Node {
        if (!std.mem.eql(u8, call.func_name, "collect") or call.args.len != 1 or call.generics.len != 1) return null;
        const generic_ty = call.generics[0];
        if (concreteTypeName(generic_ty) == null or !std.mem.eql(u8, concreteTypeName(generic_ty).?, "String")) return null;
        const iter_expr = call.args[0];
        if (iter_expr.* != .call_expr) return null;
        const iter_call = &iter_expr.call_expr;
        if ((lowering_rules.isIterOrIntoIterCall(iter_call.*)) and iter_call.args.len == 1) {
            return iter_call.args[0];
        }
        if (lowering_rules.isCopiedCall(iter_call.*) and iter_call.args.len == 1 and iter_call.args[0].* == .call_expr) {
            const inner = &iter_call.args[0].call_expr;
            if ((lowering_rules.isIterOrIntoIterCall(inner.*)) and inner.args.len == 1) {
                return inner.args[0];
            }
        }
        return null;
    }

    fn stringJoinSource(call: *const ast.CallExpr) ?*ast.Node {
        if (!lowering_rules.isJoinCall(call.*) or call.args.len != 2) return null;
        const iter_expr = call.args[0];
        if (iter_expr.* != .call_expr) return null;
        const iter_call = &iter_expr.call_expr;
        if ((lowering_rules.isIterOrIntoIterCall(iter_call.*)) and iter_call.args.len == 1) {
            return iter_call.args[0];
        }
        return null;
    }

    fn emitStringLikeSlice(self: *Codegen, expr: *ast.Node, reg: []const u8, ty: *const ast.Type) CodegenError![]const u8 {
        if (expr.* == .literal and expr.literal == .string_val) return reg;
        if (isFormatStringType(ty)) {
            const slice_reg = try self.newTmp();
            self.out.writer().print("    EXPAND STRING_BUF_AS_STR {s}, {s}\n", .{ slice_reg, reg }) catch return CodegenError.CodegenError;
            return slice_reg;
        }
        return reg;
    }

    fn genStringJoin(
        self: *Codegen,
        source: *ast.Node,
        separator: *ast.Node,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        const source_ty = self.tc.expr_types.get(source) orelse return CodegenError.CodegenError;
        const elem_ty = if (arrayType(source_ty)) |arr| arr.elem else if (sliceElementType(source_ty)) |elem| elem else vecElementType(source_ty) orelse return CodegenError.CodegenError;
        if (!isStringLikeType(elem_ty) and !isFormatStringType(elem_ty)) return CodegenError.CodegenError;

        const out_reg = try self.newTmp();
        self.out.writer().print("    EXPAND STRING_BUF_NEW {s}\n", .{out_reg}) catch return CodegenError.CodegenError;
        self.string_buf_bindings.put(out_reg, {}) catch return CodegenError.OutOfMemory;

        const sep_ty = self.tc.expr_types.get(separator) orelse return CodegenError.CodegenError;
        const sep_reg = try self.genExpr(separator, hoisted_allocs);
        const sep_slice = try self.emitStringLikeSlice(separator, sep_reg, sep_ty);
        defer {
            if (!std.mem.eql(u8, sep_slice, sep_reg)) self.emitRelease(sep_slice) catch {};
            if (callArgNeedsRelease(separator)) self.emitRelease(sep_reg) catch {};
        }

        if (arrayType(source_ty)) |arr| {
            const base_source_reg = try self.genExpr(source, hoisted_allocs);
            const base_reg = if (source.* == .identifier and self.global_const_bindings.contains(source.identifier)) blk: {
                const addr_reg = try self.newTmp();
                self.out.writer().print("    {s} = &{s}\n", .{ addr_reg, base_source_reg }) catch return CodegenError.CodegenError;
                break :blk addr_reg;
            } else base_source_reg;

            var i: usize = 0;
            while (i < arr.len) : (i += 1) {
                if (i > 0) {
                    self.out.writer().print("    EXPAND STRING_BUF_PUSH_STR {s}, {s}\n", .{ out_reg, sep_slice }) catch return CodegenError.CodegenError;
                }
                const off_reg = try self.newTmp();
                try self.emitIntConst(off_reg, @as(i64, @intCast(i * typeSize(arr.elem))));
                const item_ptr = try self.newTmp();
                self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ item_ptr, base_reg, off_reg }) catch return CodegenError.CodegenError;
                const item_reg = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ item_reg, item_ptr, typeString(arr.elem) }) catch return CodegenError.CodegenError;
                const item_slice = try self.emitStringLikeSlice(source, item_reg, elem_ty);
                self.out.writer().print("    EXPAND STRING_BUF_PUSH_STR {s}, {s}\n", .{ out_reg, item_slice }) catch return CodegenError.CodegenError;
                if (!std.mem.eql(u8, item_slice, item_reg)) try self.emitRelease(item_slice);
                try self.emitRelease(off_reg);
                try self.emitRelease(item_ptr);
                try self.emitRelease(item_reg);
            }

            if (!std.mem.eql(u8, base_reg, base_source_reg)) try self.emitRelease(base_reg);
            if (callArgNeedsRelease(source)) try self.emitRelease(base_source_reg);
            return out_reg;
        }

        if (vecElementType(source_ty) != null) {
            const vec_reg = try self.genExpr(source, hoisted_allocs);
            const len_reg = try self.newTmp();
            self.out.writer().print("    {s} = call @sa_vec_len(&{s})\n", .{ len_reg, vec_reg }) catch return CodegenError.CodegenError;
            const data_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+Vec_ptr as ptr\n", .{ data_reg, vec_reg }) catch return CodegenError.CodegenError;
            const idx_slot = try self.newTmp();
            self.out.writer().print("    {s} = stack_alloc 8\n", .{idx_slot}) catch return CodegenError.CodegenError;
            self.out.writer().print("    store {s}+0, 0 as u64\n", .{idx_slot}) catch return CodegenError.CodegenError;
            const head_label = try self.newLabel("L_STRING_JOIN_VEC_HEAD");
            const body_label = try self.newLabel("L_STRING_JOIN_VEC_BODY");
            const end_label = try self.newLabel("L_STRING_JOIN_VEC_END");
            self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;

            self.out.writer().print("{s}:\n", .{head_label}) catch return CodegenError.CodegenError;
            const idx_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as u64\n", .{ idx_reg, idx_slot }) catch return CodegenError.CodegenError;
            const more_reg = try self.newTmp();
            self.out.writer().print("    {s} = ult {s}, {s}\n", .{ more_reg, idx_reg, len_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ more_reg, body_label, end_label }) catch return CodegenError.CodegenError;

            self.out.writer().print("{s}:\n", .{body_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    !{s}\n", .{more_reg}) catch return CodegenError.CodegenError;
            const has_sep = try self.newTmp();
            self.out.writer().print("    {s} = ne {s}, 0\n", .{ has_sep, idx_reg }) catch return CodegenError.CodegenError;
            const sep_label = try self.newLabel("L_STRING_JOIN_VEC_SEP");
            const item_label = try self.newLabel("L_STRING_JOIN_VEC_ITEM");
            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ has_sep, sep_label, item_label }) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{sep_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    EXPAND STRING_BUF_PUSH_STR {s}, {s}\n", .{ out_reg, sep_slice }) catch return CodegenError.CodegenError;
            self.out.writer().print("    jmp {s}\n\n", .{item_label}) catch return CodegenError.CodegenError;

            self.out.writer().print("{s}:\n", .{item_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    !{s}\n", .{has_sep}) catch return CodegenError.CodegenError;
            const elem_size = typeSize(elem_ty);
            const off_reg = try self.newTmp();
            self.out.writer().print("    {s} = mul {s}, {}\n", .{ off_reg, idx_reg, elem_size }) catch return CodegenError.CodegenError;
            const item_ptr = try self.newTmp();
            self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ item_ptr, data_reg, off_reg }) catch return CodegenError.CodegenError;
            const item_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ item_reg, item_ptr, typeString(elem_ty) }) catch return CodegenError.CodegenError;
            const item_slice = try self.emitStringLikeSlice(source, item_reg, elem_ty);
            self.out.writer().print("    EXPAND STRING_BUF_PUSH_STR {s}, {s}\n", .{ out_reg, item_slice }) catch return CodegenError.CodegenError;
            const next_idx = try self.newTmp();
            self.out.writer().print("    {s} = add {s}, 1\n", .{ next_idx, idx_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    store {s}+0, {s} as u64\n", .{ idx_slot, next_idx }) catch return CodegenError.CodegenError;
            if (!std.mem.eql(u8, item_slice, item_reg)) try self.emitRelease(item_slice);
            try self.emitRelease(off_reg);
            try self.emitRelease(item_ptr);
            try self.emitRelease(item_reg);
            try self.emitRelease(next_idx);
            try self.emitRelease(idx_reg);
            self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;

            self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    !{s}\n", .{more_reg}) catch return CodegenError.CodegenError;
            try self.emitRelease(idx_reg);
            try self.emitRelease(len_reg);
            try self.emitRelease(data_reg);
            if (callArgNeedsRelease(source)) try self.emitRelease(vec_reg);
            return out_reg;
        }

        const slice_reg = try self.genExpr(source, hoisted_allocs);
        const base_ptr = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+Slice_ptr as ptr\n", .{ base_ptr, slice_reg }) catch return CodegenError.CodegenError;
        const len_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+Slice_len as u64\n", .{ len_reg, slice_reg }) catch return CodegenError.CodegenError;
        const idx_slot = try self.newTmp();
        self.out.writer().print("    {s} = stack_alloc 8\n", .{idx_slot}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as u64\n", .{idx_slot}) catch return CodegenError.CodegenError;
        const head_label = try self.newLabel("L_STRING_JOIN_SLICE_HEAD");
        const body_label = try self.newLabel("L_STRING_JOIN_SLICE_BODY");
        const end_label = try self.newLabel("L_STRING_JOIN_SLICE_END");
        self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{head_label}) catch return CodegenError.CodegenError;
        const idx_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as u64\n", .{ idx_reg, idx_slot }) catch return CodegenError.CodegenError;
        const done_reg = try self.newTmp();
        self.out.writer().print("    {s} = eq {s}, {s}\n", .{ done_reg, idx_reg, len_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ done_reg, end_label, body_label }) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{body_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{done_reg}) catch return CodegenError.CodegenError;
        const has_sep = try self.newTmp();
        self.out.writer().print("    {s} = ne {s}, 0\n", .{ has_sep, idx_reg }) catch return CodegenError.CodegenError;
        const sep_label = try self.newLabel("L_STRING_JOIN_SLICE_SEP");
        const item_label = try self.newLabel("L_STRING_JOIN_SLICE_ITEM");
        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ has_sep, sep_label, item_label }) catch return CodegenError.CodegenError;
        self.out.writer().print("{s}:\n", .{sep_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    EXPAND STRING_BUF_PUSH_STR {s}, {s}\n", .{ out_reg, sep_slice }) catch return CodegenError.CodegenError;
        self.out.writer().print("    jmp {s}\n\n", .{item_label}) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{item_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{has_sep}) catch return CodegenError.CodegenError;
        const elem_size = typeSize(elem_ty);
        const off_reg = try self.newTmp();
        self.out.writer().print("    {s} = mul {s}, {}\n", .{ off_reg, idx_reg, elem_size }) catch return CodegenError.CodegenError;
        const item_ptr = try self.newTmp();
        self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ item_ptr, base_ptr, off_reg }) catch return CodegenError.CodegenError;
        const item_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ item_reg, item_ptr, typeString(elem_ty) }) catch return CodegenError.CodegenError;
        const item_slice = try self.emitStringLikeSlice(source, item_reg, elem_ty);
        self.out.writer().print("    EXPAND STRING_BUF_PUSH_STR {s}, {s}\n", .{ out_reg, item_slice }) catch return CodegenError.CodegenError;
        const next_idx = try self.newTmp();
        self.out.writer().print("    {s} = add {s}, 1\n", .{ next_idx, idx_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {s} as u64\n", .{ idx_slot, next_idx }) catch return CodegenError.CodegenError;
        if (!std.mem.eql(u8, item_slice, item_reg)) try self.emitRelease(item_slice);
        try self.emitRelease(off_reg);
        try self.emitRelease(item_ptr);
        try self.emitRelease(item_reg);
        try self.emitRelease(next_idx);
        try self.emitRelease(idx_reg);
        self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{done_reg}) catch return CodegenError.CodegenError;
        try self.emitRelease(idx_reg);
        try self.emitRelease(base_ptr);
        try self.emitRelease(len_reg);
        if (callArgNeedsRelease(source)) try self.emitRelease(slice_reg);
        return out_reg;
    }

    fn genStringCollect(
        self: *Codegen,
        source: *ast.Node,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        const source_ty = self.tc.expr_types.get(source) orelse return CodegenError.CodegenError;
        const elem_ty = if (arrayType(source_ty)) |arr| arr.elem else if (sliceElementType(source_ty)) |elem| elem else vecElementType(source_ty) orelse return CodegenError.CodegenError;
        if (!std.mem.eql(u8, typeString(elem_ty), "u8")) return CodegenError.CodegenError;

        const out_reg = try self.newTmp();
        self.out.writer().print("    EXPAND STRING_BUF_NEW {s}\n", .{out_reg}) catch return CodegenError.CodegenError;
        self.string_buf_bindings.put(out_reg, {}) catch return CodegenError.OutOfMemory;

        if (arrayType(source_ty)) |arr| {
            const elem_size = typeSize(arr.elem);
            const base_source_reg = try self.genExpr(source, hoisted_allocs);
            const base_reg = if (source.* == .identifier and self.global_const_bindings.contains(source.identifier)) blk: {
                const addr_reg = try self.newTmp();
                self.out.writer().print("    {s} = &{s}\n", .{ addr_reg, base_source_reg }) catch return CodegenError.CodegenError;
                break :blk addr_reg;
            } else base_source_reg;

            var i: usize = 0;
            while (i < arr.len) : (i += 1) {
                const off_reg = try self.newTmp();
                try self.emitIntConst(off_reg, @as(i64, @intCast(i * elem_size)));
                const item_ptr = try self.newTmp();
                self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ item_ptr, base_reg, off_reg }) catch return CodegenError.CodegenError;
                const item_reg = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+0 as u8\n", .{ item_reg, item_ptr }) catch return CodegenError.CodegenError;
                self.out.writer().print("    EXPAND STRING_BUF_PUSH_BYTE {s}, {s}\n", .{ out_reg, item_reg }) catch return CodegenError.CodegenError;
                try self.emitRelease(off_reg);
                try self.emitRelease(item_ptr);
                try self.emitRelease(item_reg);
            }

            if (callArgNeedsRelease(source)) try self.emitRelease(base_reg);
            if (!std.mem.eql(u8, base_reg, base_source_reg)) try self.emitRelease(base_reg);
            return out_reg;
        }

        if (vecElementType(source_ty) != null) {
            const vec_reg = try self.genExpr(source, hoisted_allocs);
            const len_reg = try self.newTmp();
            self.out.writer().print("    {s} = call @sa_vec_len(&{s})\n", .{ len_reg, vec_reg }) catch return CodegenError.CodegenError;
            const data_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+Vec_ptr as ptr\n", .{ data_reg, vec_reg }) catch return CodegenError.CodegenError;
            const idx_slot = try self.newTmp();
            self.out.writer().print("    {s} = stack_alloc 8\n", .{idx_slot}) catch return CodegenError.CodegenError;
            self.out.writer().print("    store {s}+0, 0 as u64\n", .{idx_slot}) catch return CodegenError.CodegenError;
            const head_label = try self.newLabel("L_VEC_STRING_COLLECT_HEAD");
            const body_label = try self.newLabel("L_VEC_STRING_COLLECT_BODY");
            const end_label = try self.newLabel("L_VEC_STRING_COLLECT_END");
            self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;

            self.out.writer().print("{s}:\n", .{head_label}) catch return CodegenError.CodegenError;
            const idx_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as u64\n", .{ idx_reg, idx_slot }) catch return CodegenError.CodegenError;
            const more_reg = try self.newTmp();
            self.out.writer().print("    {s} = ult {s}, {s}\n", .{ more_reg, idx_reg, len_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ more_reg, body_label, end_label }) catch return CodegenError.CodegenError;

            self.out.writer().print("{s}:\n", .{body_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    !{s}\n", .{more_reg}) catch return CodegenError.CodegenError;
            const item_ptr = try self.newTmp();
            self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ item_ptr, data_reg, idx_reg }) catch return CodegenError.CodegenError;
            const item_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as u8\n", .{ item_reg, item_ptr }) catch return CodegenError.CodegenError;
            self.out.writer().print("    EXPAND STRING_BUF_PUSH_BYTE {s}, {s}\n", .{ out_reg, item_reg }) catch return CodegenError.CodegenError;
            const next_idx = try self.newTmp();
            self.out.writer().print("    {s} = add {s}, 1\n", .{ next_idx, idx_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    store {s}+0, {s} as u64\n", .{ idx_slot, next_idx }) catch return CodegenError.CodegenError;
            try self.emitRelease(item_ptr);
            try self.emitRelease(item_reg);
            try self.emitRelease(next_idx);
            try self.emitRelease(idx_reg);
            self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;

            self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    !{s}\n", .{more_reg}) catch return CodegenError.CodegenError;
            try self.emitRelease(idx_reg);
            try self.emitRelease(len_reg);
            try self.emitRelease(data_reg);
            if (callArgNeedsRelease(source)) try self.emitRelease(vec_reg);
            return out_reg;
        }

        const slice_reg = try self.genExpr(source, hoisted_allocs);
        const base_ptr = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+Slice_ptr as ptr\n", .{ base_ptr, slice_reg }) catch return CodegenError.CodegenError;
        const len_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+Slice_len as u64\n", .{ len_reg, slice_reg }) catch return CodegenError.CodegenError;
        const idx_slot = try self.newTmp();
        self.out.writer().print("    {s} = stack_alloc 8\n", .{idx_slot}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as u64\n", .{idx_slot}) catch return CodegenError.CodegenError;
        const head_label = try self.newLabel("L_STRING_COLLECT_HEAD");
        const body_label = try self.newLabel("L_STRING_COLLECT_BODY");
        const end_label = try self.newLabel("L_STRING_COLLECT_END");
        self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{head_label}) catch return CodegenError.CodegenError;
        const idx_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as u64\n", .{ idx_reg, idx_slot }) catch return CodegenError.CodegenError;
        const done_reg = try self.newTmp();
        self.out.writer().print("    {s} = eq {s}, {s}\n", .{ done_reg, idx_reg, len_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ done_reg, end_label, body_label }) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{body_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{done_reg}) catch return CodegenError.CodegenError;
        const off_reg = try self.newTmp();
        self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ off_reg, base_ptr, idx_reg }) catch return CodegenError.CodegenError;
        const item_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as u8\n", .{ item_reg, off_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    EXPAND STRING_BUF_PUSH_BYTE {s}, {s}\n", .{ out_reg, item_reg }) catch return CodegenError.CodegenError;
        const next_idx = try self.newTmp();
        self.out.writer().print("    {s} = add {s}, 1\n", .{ next_idx, idx_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {s} as u64\n", .{ idx_slot, next_idx }) catch return CodegenError.CodegenError;
        try self.emitRelease(off_reg);
        try self.emitRelease(item_reg);
        try self.emitRelease(next_idx);
        try self.emitRelease(idx_reg);
        self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{done_reg}) catch return CodegenError.CodegenError;
        try self.emitRelease(idx_reg);
        try self.emitRelease(base_ptr);
        try self.emitRelease(len_reg);
        if (callArgNeedsRelease(source)) try self.emitRelease(slice_reg);
        return out_reg;
    }

    fn vecElementType(ty: *const ast.Type) ?*ast.Type {
        // Shared Y-layer peel; keep local wrapper for historic call sites.
        return lowering_rules.vecElementType(ty);
    }

    fn vecDequeElementType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.vecDequeElementType(ty);
    }

    fn isAtomicI32Type(ty: *const ast.Type) bool {
        return lowering_rules.isAtomicI32Type(ty);
    }

    fn isAtomicUsizeType(ty: *const ast.Type) bool {
        return lowering_rules.isAtomicUsizeType(ty);
    }

    fn cellInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.cellInnerType(ty);
    }

    fn refCellInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.refCellInnerType(ty);
    }

    fn mutexInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.mutexInnerType(ty);
    }

    fn mutexGuardInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.mutexGuardInnerType(ty);
    }

    fn rwLockInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.rwLockInnerType(ty);
    }

    fn rwLockReadGuardInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.rwLockReadGuardInnerType(ty);
    }

    fn rwLockWriteGuardInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.rwLockWriteGuardInnerType(ty);
    }

    fn isFileType(ty: *const ast.Type) bool {
        return lowering_rules.isFileType(ty);
    }

    fn isMetadataType(ty: *const ast.Type) bool {
        return lowering_rules.isMetadataType(ty);
    }

    fn isI32LikeType(ty: *const ast.Type) bool {
        return lowering_rules.isI32LikeType(ty);
    }

    fn isRawPtrAliasType(ty: *const ast.Type) bool {
        return lowering_rules.isRawPtrAliasType(ty);
    }

    fn isPointerCarrierCastType(ty: *const ast.Type) bool {
        return lowering_rules.isPointerCarrierCastType(ty);
    }

    fn refCellPayloadIsPointer(ty: *const ast.Type) bool {
        return lowering_rules.refCellPayloadIsPointer(ty);
    }

    fn atomicOrderingToken(expr: *const ast.Node) CodegenError![]const u8 {
        if (expr.* != .identifier) return CodegenError.CodegenError;
        return lowering_rules.atomicOrderingToken(expr.identifier) orelse CodegenError.CodegenError;
    }

    const HashMapTypes = lowering_rules.MapTypes;

    fn hashMapTypes(ty: *const ast.Type) ?HashMapTypes {
        return lowering_rules.hashMapTypes(ty);
    }

    const HashSetTypes = struct {
        key: *ast.Type,
    };

    fn hashSetTypes(ty: *const ast.Type) ?HashSetTypes {
        const key = lowering_rules.hashSetElementType(ty) orelse return null;
        return .{ .key = key };
    }

    const BTreeMapTypes = lowering_rules.MapTypes;

    fn btreeMapTypes(ty: *const ast.Type) ?BTreeMapTypes {
        return lowering_rules.btreeMapTypes(ty);
    }

    const BTreeSetTypes = struct {
        key: *ast.Type,
    };

    fn btreeSetTypes(ty: *const ast.Type) ?BTreeSetTypes {
        const key = lowering_rules.btreeSetElementType(ty) orelse return null;
        return .{ .key = key };
    }

    fn sliceElementType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.sliceElementType(ty);
    }

    fn optionInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.optionInnerType(ty);
    }

    fn resultOkType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.resultOkType(ty);
    }

    fn resultErrType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.resultErrType(ty);
    }

    fn patternUsesResultMacros(pattern: ast.EnumPattern) bool {
        return lowering_rules.patternUsesResultMacros(pattern.enum_name, pattern.variant_name);
    }

    fn patternUsesOptionMacros(pattern: ast.EnumPattern) bool {
        return lowering_rules.patternUsesOptionMacros(pattern.enum_name, pattern.variant_name);
    }

    fn enumNameMatchesDecl(pattern_name: []const u8, decl_name: []const u8) bool {
        return lowering_rules.enumNameMatchesDecl(pattern_name, decl_name);
    }

    fn enumDeclForValueType(self: *Codegen, value_ty: *const ast.Type) ?*ast.EnumDecl {
        const name = lowering_rules.typeBaseName(value_ty) orelse return null;
        if (std.mem.eql(u8, name, "Option") or std.mem.eql(u8, name, "Result")) return null;
        return self.tc.enums.get(name);
    }

    fn enumDeclForPatternValue(self: *Codegen, value: *const ast.Node, pattern: ast.EnumPattern) CodegenError!?*ast.EnumDecl {
        const value_ty = self.tc.expr_types.get(value) orelse return CodegenError.CodegenError;
        const decl = self.enumDeclForValueType(value_ty) orelse return null;
        if (!enumNameMatchesDecl(pattern.enum_name, decl.name)) return CodegenError.CodegenError;
        return decl;
    }

    fn joinHandleInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.joinHandleInnerType(ty);
    }

    fn senderInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.senderInnerType(ty);
    }

    fn receiverInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.receiverInnerType(ty);
    }

    fn rcInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.rcInnerType(ty);
    }

    fn arcInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.arcInnerType(ty);
    }

    fn atomicPtrInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.atomicPtrInnerType(ty);
    }

    fn ifLetChainNeedsNoSelf(comptime predicate: fn (*const ast.Node) bool, chain: ?[]const ast.IfLetCond) bool {
        if (chain) |items| {
            for (items) |cond| if (predicate(cond.value)) return true;
        }
        return false;
    }

    fn ifLetChainNeedsSelf(self: *Codegen, comptime predicate: fn (*Codegen, *const ast.Node) bool, chain: ?[]const ast.IfLetCond) bool {
        if (chain) |items| {
            for (items) |cond| if (predicate(self, cond.value)) return true;
        }
        return false;
    }

    fn ifExprNeedsNoSelf(comptime expr_predicate: fn (*const ast.Node) bool, comptime block_predicate: fn ([]const *ast.Node) bool, ife: ast.IfExpr) bool {
        if (expr_predicate(ife.cond) or ifLetChainNeedsNoSelf(expr_predicate, ife.let_chain)) return true;
        if (block_predicate(ife.then_block)) return true;
        if (ife.else_block) |eb| if (block_predicate(eb)) return true;
        return false;
    }

    fn ifExprNeedsSelf(self: *Codegen, comptime expr_predicate: fn (*Codegen, *const ast.Node) bool, comptime block_predicate: fn (*Codegen, []const *ast.Node) bool, ife: ast.IfExpr) bool {
        if (expr_predicate(self, ife.cond) or self.ifLetChainNeedsSelf(expr_predicate, ife.let_chain)) return true;
        if (block_predicate(self, ife.then_block)) return true;
        if (ife.else_block) |eb| if (block_predicate(self, eb)) return true;
        return false;
    }

    fn ifLetChainConsumesIdentifier(chain: ?[]const ast.IfLetCond, name: []const u8) bool {
        if (chain) |items| {
            for (items) |cond| if (exprConsumesIdentifier(cond.value, name)) return true;
        }
        return false;
    }

    fn exprNeedsIterMacros(expr: *const ast.Node) bool {
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (arrayIterSumSource(&call) != null) break :blk true;
                for (call.args) |arg| {
                    if (exprNeedsIterMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .binary_expr => |bin| exprNeedsIterMacros(bin.left) or exprNeedsIterMacros(bin.right),
            .borrow_expr => |borrow| exprNeedsIterMacros(borrow.expr),
            .move_expr => |move| exprNeedsIterMacros(move.expr),
            .deref_expr => |deref| exprNeedsIterMacros(deref.expr),
            .field_expr => |field| exprNeedsIterMacros(field.expr),
            .index_expr => |idx| exprNeedsIterMacros(idx.target) or exprNeedsIterMacros(idx.index),
            .slice_expr => |slc| exprNeedsIterMacros(slc.target) or exprNeedsIterMacros(slc.start) or exprNeedsIterMacros(slc.end),
            .closure_literal => |lit| exprNeedsIterMacros(lit.body),
            .await_expr => |aw| exprNeedsIterMacros(aw.expr),
            .try_expr => |trye| exprNeedsIterMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprNeedsIterMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprNeedsIterMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprNeedsIterMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprNeedsIterMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| ifExprNeedsNoSelf(exprNeedsIterMacros, blockNeedsIterMacros, ife),
            .switch_expr => |swe| blk: {
                if (exprNeedsIterMacros(swe.val)) break :blk true;
                for (swe.cases) |case| {
                    if (exprNeedsIterMacros(case.pattern) or blockNeedsIterMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (exprNeedsIterMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (exprNeedsIterMacros(guard)) break :blk true;
                    if (blockNeedsIterMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsIterMacros(block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (exprNeedsIterMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (exprNeedsIterMacros(let.value)) return true,
                .const_stmt => |c| if (exprNeedsIterMacros(c.value)) return true,
                .assign_stmt => |assign| if (exprNeedsIterMacros(assign.target) or exprNeedsIterMacros(assign.value)) return true,
                .expr_stmt => |expr| if (exprNeedsIterMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (exprNeedsIterMacros(v)) return true,
                .for_stmt => |f| if (exprNeedsIterMacros(f.start) or (if (f.end) |end_expr| exprNeedsIterMacros(end_expr) else false) or blockNeedsIterMacros(f.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsIterMacros(program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (blockNeedsIterMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and blockNeedsIterMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (blockNeedsIterMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsBoxMacros(expr: *const ast.Node) bool {
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (lowering_rules.isBoxNewCall(call) or
                    lowering_rules.isBoxIntoRawCall(call) or
                    lowering_rules.isBoxFromRawCall(call)) break :blk true;
                for (call.args) |arg| {
                    if (exprNeedsBoxMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .binary_expr => |bin| exprNeedsBoxMacros(bin.left) or exprNeedsBoxMacros(bin.right),
            .borrow_expr => |borrow| exprNeedsBoxMacros(borrow.expr),
            .move_expr => |move| exprNeedsBoxMacros(move.expr),
            .deref_expr => |deref| exprNeedsBoxMacros(deref.expr),
            .field_expr => |field| exprNeedsBoxMacros(field.expr),
            .index_expr => |idx| exprNeedsBoxMacros(idx.target) or exprNeedsBoxMacros(idx.index),
            .slice_expr => |slc| exprNeedsBoxMacros(slc.target) or exprNeedsBoxMacros(slc.start) or exprNeedsBoxMacros(slc.end),
            .closure_literal => |lit| exprNeedsBoxMacros(lit.body),
            .await_expr => |aw| exprNeedsBoxMacros(aw.expr),
            .try_expr => |trye| exprNeedsBoxMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprNeedsBoxMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprNeedsBoxMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprNeedsBoxMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprNeedsBoxMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| ifExprNeedsNoSelf(exprNeedsBoxMacros, blockNeedsBoxMacros, ife),
            .switch_expr => |swe| blk: {
                if (exprNeedsBoxMacros(swe.val)) break :blk true;
                for (swe.cases) |case| {
                    if (exprNeedsBoxMacros(case.pattern) or blockNeedsBoxMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (exprNeedsBoxMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (exprNeedsBoxMacros(guard)) break :blk true;
                    if (blockNeedsBoxMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsBoxMacros(block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (exprNeedsBoxMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (exprNeedsBoxMacros(let.value)) return true,
                .const_stmt => |c| if (exprNeedsBoxMacros(c.value)) return true,
                .assign_stmt => |assign| if (exprNeedsBoxMacros(assign.target) or exprNeedsBoxMacros(assign.value)) return true,
                .expr_stmt => |expr| if (exprNeedsBoxMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (exprNeedsBoxMacros(v)) return true,
                .for_stmt => |f| if (exprNeedsBoxMacros(f.start) or (if (f.end) |end_expr| exprNeedsBoxMacros(end_expr) else false) or blockNeedsBoxMacros(f.body)) return true,
                .while_stmt => |w| if (exprNeedsBoxMacros(w.cond) or blockNeedsBoxMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsVecMacros(self: *Codegen, expr: *const ast.Node) bool {
        if (lowering_rules.planDynCoercion(self.tc, expr)) |plan| {
            if (plan.isBoxToDyn()) return true;
        }
        if (self.tc.expr_types.get(expr)) |ty| {
            if (vecElementType(ty) != null) return true;
        }
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (std.mem.eql(u8, call.func_name, "vec") or lowering_rules.isPushCall(call)) break :blk true;
                for (call.args) |arg| {
                    if (self.exprNeedsVecMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .binary_expr => |bin| self.exprNeedsVecMacros(bin.left) or self.exprNeedsVecMacros(bin.right),
            .borrow_expr => |borrow| self.exprNeedsVecMacros(borrow.expr),
            .move_expr => |move| self.exprNeedsVecMacros(move.expr),
            .deref_expr => |deref| self.exprNeedsVecMacros(deref.expr),
            .field_expr => |field| self.exprNeedsVecMacros(field.expr),
            .index_expr => |idx| self.exprNeedsVecMacros(idx.target) or self.exprNeedsVecMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsVecMacros(slc.target) or self.exprNeedsVecMacros(slc.start) or self.exprNeedsVecMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsVecMacros(lit.body),
            .await_expr => |aw| self.exprNeedsVecMacros(aw.expr),
            .try_expr => |trye| self.exprNeedsVecMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsVecMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsVecMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsVecMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsVecMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsVecMacros, blockNeedsVecMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsVecMacros(swe.val)) break :blk true;
                for (swe.cases) |case| {
                    if (self.exprNeedsVecMacros(case.pattern) or self.blockNeedsVecMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsVecMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsVecMacros(guard)) break :blk true;
                    if (self.blockNeedsVecMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsVecMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsVecMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsVecMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsVecMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsVecMacros(assign.target) or self.exprNeedsVecMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsVecMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsVecMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsVecMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsVecMacros(end_expr) else false) or self.blockNeedsVecMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsVecMacros(w.cond) or self.blockNeedsVecMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsVecMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsVecMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsVecMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsVecMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    // `format("{}", path)` with a `ptr` arg emits `EXPAND CSTR_LEN ...` (from
    // `sa_std/ffi.sa`). Only import `ffi.sa` when such a call exists, so demos
    // that never format a raw pointer stay free of the FFI import.
    fn programNeedsFfiCstrMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsFfiCstrMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsFfiCstrMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsFfiCstrMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn blockNeedsFfiCstrMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsFfiCstrMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsFfiCstrMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsFfiCstrMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsFfiCstrMacros(assign.target) or self.exprNeedsFfiCstrMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsFfiCstrMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsFfiCstrMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsFfiCstrMacros(f.start) or (if (f.end) |e| self.exprNeedsFfiCstrMacros(e) else false) or self.blockNeedsFfiCstrMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsFfiCstrMacros(w.cond) or self.blockNeedsFfiCstrMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsFfiCstrMacros(self: *Codegen, expr: *const ast.Node) bool {
        switch (expr.*) {
            .call_expr => |call| {
                if (std.mem.eql(u8, call.func_name, "format")) {
                    for (call.args) |arg| {
                        if (self.tc.expr_types.get(arg)) |ty| {
                            if (ty.* == .primitive and ty.primitive == .raw_ptr) return true;
                        }
                    }
                }
                for (call.args) |arg| if (self.exprNeedsFfiCstrMacros(arg)) return true;
            },
            .binary_expr => |bin| return self.exprNeedsFfiCstrMacros(bin.left) or self.exprNeedsFfiCstrMacros(bin.right),
            .borrow_expr => |b| return self.exprNeedsFfiCstrMacros(b.expr),
            .move_expr => |m| return self.exprNeedsFfiCstrMacros(m.expr),
            .deref_expr => |d| return self.exprNeedsFfiCstrMacros(d.expr),
            .field_expr => |f| return self.exprNeedsFfiCstrMacros(f.expr),
            .index_expr => |idx| return self.exprNeedsFfiCstrMacros(idx.target) or self.exprNeedsFfiCstrMacros(idx.index),
            .slice_expr => |slc| return self.exprNeedsFfiCstrMacros(slc.target) or self.exprNeedsFfiCstrMacros(slc.start) or self.exprNeedsFfiCstrMacros(slc.end),
            .closure_literal => |lit| return self.exprNeedsFfiCstrMacros(lit.body),
            .await_expr => |aw| return self.exprNeedsFfiCstrMacros(aw.expr),
            .try_expr => |tr| return self.exprNeedsFfiCstrMacros(tr.expr),
            .struct_literal => |lit| for (lit.fields) |field| if (self.exprNeedsFfiCstrMacros(field.value)) return true,
            .enum_literal => |lit| for (lit.fields) |field| if (self.exprNeedsFfiCstrMacros(field.value)) return true,
            .tuple_literal => |lit| for (lit.elements) |e| if (self.exprNeedsFfiCstrMacros(e)) return true,
            .array_literal => |lit| for (lit.elements) |e| if (self.exprNeedsFfiCstrMacros(e)) return true,
            else => {},
        }
        return false;
    }

    fn programNeedsBoxMacros(program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (blockNeedsBoxMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and blockNeedsBoxMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (blockNeedsBoxMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsOptionMacros(self: *Codegen, expr: *const ast.Node) bool {
        if (self.tc.expr_types.get(expr)) |ty| {
            if (optionInnerType(ty) != null) return true;
        }
        return switch (expr.*) {
            .identifier => |name| lowering_rules.isOptionNoneName(name),
            .call_expr => |call| blk: {
                if (lowering_rules.isOptionSomeCall(call)) break :blk true;
                if ((lowering_rules.isOptionQueryCall(call) or lowering_rules.isMapCall(call) or lowering_rules.isAndThenCall(call) or lowering_rules.isUnwrapCall(call) or lowering_rules.isUnwrapOrCall(call) or lowering_rules.isUnwrapOrElseCall(call) or lowering_rules.isUnwrapOrDefaultCall(call) or lowering_rules.isCopiedCall(call) or lowering_rules.isGetCall(call)) and
                    call.args.len > 0)
                {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty != null and (optionInnerType(recv_ty.?) != null or hashMapTypes(recv_ty.?) != null)) break :blk true;
                }
                for (call.args) |arg| {
                    if (self.exprNeedsOptionMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .binary_expr => |bin| self.exprNeedsOptionMacros(bin.left) or self.exprNeedsOptionMacros(bin.right),
            .borrow_expr => |borrow| self.exprNeedsOptionMacros(borrow.expr),
            .move_expr => |move| self.exprNeedsOptionMacros(move.expr),
            .deref_expr => |deref| self.exprNeedsOptionMacros(deref.expr),
            .field_expr => |field| self.exprNeedsOptionMacros(field.expr),
            .index_expr => |idx| self.exprNeedsOptionMacros(idx.target) or self.exprNeedsOptionMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsOptionMacros(slc.target) or self.exprNeedsOptionMacros(slc.start) or self.exprNeedsOptionMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsOptionMacros(lit.body),
            .await_expr => |aw| self.exprNeedsOptionMacros(aw.expr),
            .try_expr => |trye| blk: {
                const inner_ty = self.tc.expr_types.get(trye.expr) orelse null;
                if (inner_ty != null and optionInnerType(inner_ty.?) != null) break :blk true;
                break :blk self.exprNeedsOptionMacros(trye.expr);
            },
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsOptionMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsOptionMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsOptionMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsOptionMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsOptionMacros, blockNeedsOptionMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsOptionMacros(swe.val)) break :blk true;
                for (swe.cases) |case| {
                    if (self.exprNeedsOptionMacros(case.pattern) or self.blockNeedsOptionMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsOptionMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsOptionMacros(guard)) break :blk true;
                    if (self.blockNeedsOptionMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsOptionMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsOptionMacros(let.value)) return true,
                .let_else_stmt => |let| if (self.exprNeedsOptionMacros(let.value) or self.blockNeedsOptionMacros(let.else_block)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsOptionMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsOptionMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsOptionMacros(assign.target) or self.exprNeedsOptionMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsOptionMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsOptionMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsOptionMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsOptionMacros(end_expr) else false) or self.blockNeedsOptionMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsOptionMacros(w.cond) or self.blockNeedsOptionMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsOptionMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsOptionMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsOptionMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsOptionMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsCmpMacros(self: *Codegen, expr: *const ast.Node) bool {
        return switch (expr.*) {
            .binary_expr => |bin| bin.op == .spaceship or self.exprNeedsCmpMacros(bin.left) or self.exprNeedsCmpMacros(bin.right),
            .call_expr => |call| blk: {
                for (call.args) |arg| if (self.exprNeedsCmpMacros(arg)) break :blk true;
                break :blk false;
            },
            .borrow_expr => |borrow| self.exprNeedsCmpMacros(borrow.expr),
            .move_expr => |move| self.exprNeedsCmpMacros(move.expr),
            .deref_expr => |deref| self.exprNeedsCmpMacros(deref.expr),
            .cast_expr => |cast| self.exprNeedsCmpMacros(cast.expr),
            .field_expr => |field| self.exprNeedsCmpMacros(field.expr),
            .struct_literal => |lit| blk: {
                if (lit.update_expr) |update_expr| if (self.exprNeedsCmpMacros(update_expr)) break :blk true;
                for (lit.fields) |field| if (self.exprNeedsCmpMacros(field.value)) break :blk true;
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsCmpMacros(field.value)) break :blk true;
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsCmpMacros(elem)) break :blk true;
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsCmpMacros(elem)) break :blk true;
                break :blk false;
            },
            .repeat_array_literal => |lit| self.exprNeedsCmpMacros(lit.value),
            .index_expr => |idx| self.exprNeedsCmpMacros(idx.target) or self.exprNeedsCmpMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsCmpMacros(slc.target) or self.exprNeedsCmpMacros(slc.start) or self.exprNeedsCmpMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsCmpMacros(lit.body),
            .await_expr => |aw| self.exprNeedsCmpMacros(aw.expr),
            .try_expr => |trye| self.exprNeedsCmpMacros(trye.expr),
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsCmpMacros, blockNeedsCmpMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsCmpMacros(swe.val)) break :blk true;
                for (swe.cases) |case| {
                    if (self.exprNeedsCmpMacros(case.pattern) or self.blockNeedsCmpMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsCmpMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsCmpMacros(guard)) break :blk true;
                    if (self.blockNeedsCmpMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .unsafe_expr => |ue| self.blockNeedsCmpMacros(ue.body),
            else => false,
        };
    }

    fn blockNeedsCmpMacros(self: *Codegen, body: []const *ast.Node) bool {
        for (body) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsCmpMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsCmpMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsCmpMacros(assign.target) or self.exprNeedsCmpMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsCmpMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |value| if (self.exprNeedsCmpMacros(value)) return true,
                .for_stmt => |for_stmt| {
                    if (self.exprNeedsCmpMacros(for_stmt.start)) return true;
                    if (for_stmt.end) |end| if (self.exprNeedsCmpMacros(end)) return true;
                    if (self.blockNeedsCmpMacros(for_stmt.body)) return true;
                },
                .while_stmt => |while_stmt| {
                    if (self.exprNeedsCmpMacros(while_stmt.cond)) return true;
                    if (self.blockNeedsCmpMacros(while_stmt.body)) return true;
                },
                .block_stmt => |block| if (self.blockNeedsCmpMacros(block.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsCmpMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsCmpMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsCmpMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsCmpMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsResultMacros(self: *Codegen, expr: *const ast.Node) bool {
        if (self.tc.expr_types.get(expr)) |ty| {
            if (resultOkType(ty) != null) return true;
        }
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (lowering_rules.isResultConstructorCall(call)) break :blk true;
                if (std.mem.eql(u8, call.func_name, "std__panic__catch_unwind")) break :blk true;
                if (call.associated_target) |target_name| {
                    if (std.mem.eql(u8, target_name, "panic") and std.mem.eql(u8, call.func_name, "catch_unwind")) break :blk true;
                }
                if ((lowering_rules.isUnwrapCall(call) or lowering_rules.isUnwrapOrCall(call) or lowering_rules.isResultQueryCall(call)) and
                    call.args.len > 0)
                {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty != null and resultOkType(recv_ty.?) != null) break :blk true;
                }
                if (lowering_rules.isCompareExchangeCall(call) and call.args.len > 0) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty != null and isAtomicI32Type(recv_ty.?)) break :blk true;
                }
                for (call.args) |arg| {
                    if (self.exprNeedsResultMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .binary_expr => |bin| self.exprNeedsResultMacros(bin.left) or self.exprNeedsResultMacros(bin.right),
            .borrow_expr => |borrow| self.exprNeedsResultMacros(borrow.expr),
            .move_expr => |move| self.exprNeedsResultMacros(move.expr),
            .deref_expr => |deref| self.exprNeedsResultMacros(deref.expr),
            .field_expr => |field| self.exprNeedsResultMacros(field.expr),
            .index_expr => |idx| self.exprNeedsResultMacros(idx.target) or self.exprNeedsResultMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsResultMacros(slc.target) or self.exprNeedsResultMacros(slc.start) or self.exprNeedsResultMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsResultMacros(lit.body),
            .await_expr => |aw| self.exprNeedsResultMacros(aw.expr),
            .try_expr => |trye| blk: {
                const inner_ty = self.tc.expr_types.get(trye.expr) orelse null;
                if (inner_ty != null and resultOkType(inner_ty.?) != null) break :blk true;
                break :blk self.exprNeedsResultMacros(trye.expr);
            },
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsResultMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsResultMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsResultMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsResultMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsResultMacros, blockNeedsResultMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsResultMacros(swe.val)) break :blk true;
                for (swe.cases) |case| {
                    if (self.exprNeedsResultMacros(case.pattern) or self.blockNeedsResultMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsResultMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsResultMacros(guard)) break :blk true;
                    if (patternUsesResultMacros(case.pattern) or self.blockNeedsResultMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsResultMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsResultMacros(let.value)) return true,
                .let_else_stmt => |let| if (patternUsesResultMacros(let.pattern) or self.exprNeedsResultMacros(let.value) or self.blockNeedsResultMacros(let.else_block)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsResultMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsResultMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsResultMacros(assign.target) or self.exprNeedsResultMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsResultMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsResultMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsResultMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsResultMacros(end_expr) else false) or self.blockNeedsResultMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsResultMacros(w.cond) or self.blockNeedsResultMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsResultMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsResultMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsResultMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsResultMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsMpscMacros(self: *Codegen, expr: *const ast.Node) bool {
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (lowering_rules.isMpscChannelCall(call)) break :blk true;
                if ((lowering_rules.isSendCall(call) or lowering_rules.isRecvCall(call)) and call.args.len > 0) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty) |ty| {
                        if (senderInnerType(ty) != null or receiverInnerType(ty) != null) break :blk true;
                    }
                }
                for (call.args) |arg| {
                    if (self.exprNeedsMpscMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .binary_expr => |bin| self.exprNeedsMpscMacros(bin.left) or self.exprNeedsMpscMacros(bin.right),
            .borrow_expr => |b| self.exprNeedsMpscMacros(b.expr),
            .move_expr => |m| self.exprNeedsMpscMacros(m.expr),
            .deref_expr => |d| self.exprNeedsMpscMacros(d.expr),
            .cast_expr => |c| self.exprNeedsMpscMacros(c.expr),
            .field_expr => |f| self.exprNeedsMpscMacros(f.expr),
            .index_expr => |idx| self.exprNeedsMpscMacros(idx.target) or self.exprNeedsMpscMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsMpscMacros(slc.target) or self.exprNeedsMpscMacros(slc.start) or self.exprNeedsMpscMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsMpscMacros(lit.body),
            .await_expr => |aw| self.exprNeedsMpscMacros(aw.expr),
            .try_expr => |trye| self.exprNeedsMpscMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsMpscMacros(field.value)) break :blk true;
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsMpscMacros(field.value)) break :blk true;
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsMpscMacros(elem)) break :blk true;
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsMpscMacros(elem)) break :blk true;
                break :blk false;
            },
            .repeat_array_literal => |lit| self.exprNeedsMpscMacros(lit.value),
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsMpscMacros, blockNeedsMpscMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsMpscMacros(swe.val)) break :blk true;
                for (swe.cases) |case| if (self.exprNeedsMpscMacros(case.pattern) or self.blockNeedsMpscMacros(case.body)) break :blk true;
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsMpscMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsMpscMacros(guard)) break :blk true;
                    if (self.blockNeedsMpscMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsMpscMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsMpscMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsMpscMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsMpscMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsMpscMacros(assign.target) or self.exprNeedsMpscMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsMpscMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsMpscMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsMpscMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsMpscMacros(end_expr) else false) or self.blockNeedsMpscMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsMpscMacros(w.cond) or self.blockNeedsMpscMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsMpscMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsMpscMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsMpscMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsMpscMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsRcMacros(self: *Codegen, expr: *const ast.Node) bool {
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (lowering_rules.isRcNewCall(call)) break :blk true;
                if (lowering_rules.isCloneUnaryCall(call)) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty != null and rcInnerType(recv_ty.?) != null) break :blk true;
                }
                for (call.args) |arg| {
                    if (self.exprNeedsRcMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .deref_expr => |deref| blk: {
                const inner_ty = self.tc.expr_types.get(deref.expr) orelse null;
                if (inner_ty != null and rcInnerType(inner_ty.?) != null) break :blk true;
                break :blk self.exprNeedsRcMacros(deref.expr);
            },
            .binary_expr => |bin| self.exprNeedsRcMacros(bin.left) or self.exprNeedsRcMacros(bin.right),
            .borrow_expr => |borrow| self.exprNeedsRcMacros(borrow.expr),
            .move_expr => |move| self.exprNeedsRcMacros(move.expr),
            .field_expr => |field| self.exprNeedsRcMacros(field.expr),
            .index_expr => |idx| self.exprNeedsRcMacros(idx.target) or self.exprNeedsRcMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsRcMacros(slc.target) or self.exprNeedsRcMacros(slc.start) or self.exprNeedsRcMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsRcMacros(lit.body),
            .await_expr => |aw| self.exprNeedsRcMacros(aw.expr),
            .try_expr => |trye| self.exprNeedsRcMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsRcMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsRcMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsRcMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsRcMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsRcMacros, blockNeedsRcMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsRcMacros(swe.val)) break :blk true;
                for (swe.cases) |case| {
                    if (self.exprNeedsRcMacros(case.pattern) or self.blockNeedsRcMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsRcMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsRcMacros(guard)) break :blk true;
                    if (self.blockNeedsRcMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsRcMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsRcMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsRcMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsRcMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsRcMacros(assign.target) or self.exprNeedsRcMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsRcMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsRcMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsRcMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsRcMacros(end_expr) else false) or self.blockNeedsRcMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsRcMacros(w.cond) or self.blockNeedsRcMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsRcMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsRcMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsRcMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsRcMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsVecDequeMacros(self: *Codegen, expr: *const ast.Node) bool {
        if (self.tc.expr_types.get(expr)) |ty| {
            if (vecDequeElementType(ty) != null) return true;
        }
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (call.associated_target) |target| {
                    if (std.mem.eql(u8, target, "VecDeque") and std.mem.eql(u8, call.func_name, "from")) break :blk true;
                }
                if (call.args.len > 0 and std.mem.eql(u8, call.func_name, "rotate_left")) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty != null and vecDequeElementType(recv_ty.?) != null) break :blk true;
                }
                for (call.args) |arg| {
                    if (self.exprNeedsVecDequeMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .index_expr => |idx| blk: {
                const target_ty = self.tc.expr_types.get(idx.target) orelse null;
                if (target_ty != null and vecDequeElementType(target_ty.?) != null) break :blk true;
                break :blk self.exprNeedsVecDequeMacros(idx.target) or self.exprNeedsVecDequeMacros(idx.index);
            },
            .binary_expr => |bin| self.exprNeedsVecDequeMacros(bin.left) or self.exprNeedsVecDequeMacros(bin.right),
            .borrow_expr => |borrow| self.exprNeedsVecDequeMacros(borrow.expr),
            .move_expr => |move| self.exprNeedsVecDequeMacros(move.expr),
            .deref_expr => |deref| self.exprNeedsVecDequeMacros(deref.expr),
            .field_expr => |field| self.exprNeedsVecDequeMacros(field.expr),
            .slice_expr => |slc| self.exprNeedsVecDequeMacros(slc.target) or self.exprNeedsVecDequeMacros(slc.start) or self.exprNeedsVecDequeMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsVecDequeMacros(lit.body),
            .await_expr => |aw| self.exprNeedsVecDequeMacros(aw.expr),
            .try_expr => |trye| self.exprNeedsVecDequeMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsVecDequeMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsVecDequeMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsVecDequeMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsVecDequeMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsVecDequeMacros, blockNeedsVecDequeMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsVecDequeMacros(swe.val)) break :blk true;
                for (swe.cases) |case| {
                    if (self.exprNeedsVecDequeMacros(case.pattern) or self.blockNeedsVecDequeMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsVecDequeMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsVecDequeMacros(guard)) break :blk true;
                    if (self.blockNeedsVecDequeMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsVecDequeMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsVecDequeMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsVecDequeMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsVecDequeMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsVecDequeMacros(assign.target) or self.exprNeedsVecDequeMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsVecDequeMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsVecDequeMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsVecDequeMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsVecDequeMacros(end_expr) else false) or self.blockNeedsVecDequeMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsVecDequeMacros(w.cond) or self.blockNeedsVecDequeMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsVecDequeMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsVecDequeMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsVecDequeMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsVecDequeMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsHashMapMacros(self: *Codegen, expr: *const ast.Node) bool {
        if (self.tc.expr_types.get(expr)) |ty| {
            if (hashMapTypes(ty) != null) return true;
        }
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (call.associated_target) |target| {
                    if (std.mem.eql(u8, target, "HashMap") and std.mem.eql(u8, call.func_name, "new")) break :blk true;
                }
                if (call.args.len > 0 and (lowering_rules.isInsertCall(call) or lowering_rules.isGetCall(call))) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty != null and hashMapTypes(recv_ty.?) != null) break :blk true;
                }
                for (call.args) |arg| {
                    if (self.exprNeedsHashMapMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .binary_expr => |bin| self.exprNeedsHashMapMacros(bin.left) or self.exprNeedsHashMapMacros(bin.right),
            .borrow_expr => |borrow| self.exprNeedsHashMapMacros(borrow.expr),
            .move_expr => |move| self.exprNeedsHashMapMacros(move.expr),
            .deref_expr => |deref| self.exprNeedsHashMapMacros(deref.expr),
            .field_expr => |field| self.exprNeedsHashMapMacros(field.expr),
            .index_expr => |idx| self.exprNeedsHashMapMacros(idx.target) or self.exprNeedsHashMapMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsHashMapMacros(slc.target) or self.exprNeedsHashMapMacros(slc.start) or self.exprNeedsHashMapMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsHashMapMacros(lit.body),
            .await_expr => |aw| self.exprNeedsHashMapMacros(aw.expr),
            .try_expr => |trye| self.exprNeedsHashMapMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsHashMapMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsHashMapMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsHashMapMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsHashMapMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsHashMapMacros, blockNeedsHashMapMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsHashMapMacros(swe.val)) break :blk true;
                for (swe.cases) |case| {
                    if (self.exprNeedsHashMapMacros(case.pattern) or self.blockNeedsHashMapMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsHashMapMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsHashMapMacros(guard)) break :blk true;
                    if (self.blockNeedsHashMapMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsHashMapMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsHashMapMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsHashMapMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsHashMapMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsHashMapMacros(assign.target) or self.exprNeedsHashMapMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsHashMapMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsHashMapMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsHashMapMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsHashMapMacros(end_expr) else false) or self.blockNeedsHashMapMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsHashMapMacros(w.cond) or self.blockNeedsHashMapMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsHashMapMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsHashMapMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsHashMapMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsHashMapMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsHashSetMacros(self: *Codegen, expr: *const ast.Node) bool {
        if (self.tc.expr_types.get(expr)) |ty| {
            if (hashSetTypes(ty) != null) return true;
        }
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (call.associated_target) |target| {
                    if (std.mem.eql(u8, target, "HashSet")) break :blk true;
                }
                if (call.args.len > 0 and (lowering_rules.isInsertCall(call) or lowering_rules.isContainsCall(call))) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty != null and hashSetTypes(recv_ty.?) != null) break :blk true;
                }
                for (call.args) |arg| {
                    if (self.exprNeedsHashSetMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .binary_expr => |bin| self.exprNeedsHashSetMacros(bin.left) or self.exprNeedsHashSetMacros(bin.right),
            .borrow_expr => |borrow| self.exprNeedsHashSetMacros(borrow.expr),
            .move_expr => |move| self.exprNeedsHashSetMacros(move.expr),
            .deref_expr => |deref| self.exprNeedsHashSetMacros(deref.expr),
            .field_expr => |field| self.exprNeedsHashSetMacros(field.expr),
            .index_expr => |idx| self.exprNeedsHashSetMacros(idx.target) or self.exprNeedsHashSetMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsHashSetMacros(slc.target) or self.exprNeedsHashSetMacros(slc.start) or self.exprNeedsHashSetMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsHashSetMacros(lit.body),
            .await_expr => |aw| self.exprNeedsHashSetMacros(aw.expr),
            .try_expr => |trye| self.exprNeedsHashSetMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsHashSetMacros(field.value)) break :blk true;
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsHashSetMacros(field.value)) break :blk true;
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsHashSetMacros(elem)) break :blk true;
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsHashSetMacros(elem)) break :blk true;
                break :blk false;
            },
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsHashSetMacros, blockNeedsHashSetMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsHashSetMacros(swe.val)) break :blk true;
                for (swe.cases) |case| if (self.exprNeedsHashSetMacros(case.pattern) or self.blockNeedsHashSetMacros(case.body)) break :blk true;
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsHashSetMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsHashSetMacros(guard)) break :blk true;
                    if (self.blockNeedsHashSetMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsHashSetMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsHashSetMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsHashSetMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsHashSetMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsHashSetMacros(assign.target) or self.exprNeedsHashSetMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsHashSetMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsHashSetMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsHashSetMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsHashSetMacros(end_expr) else false) or self.blockNeedsHashSetMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsHashSetMacros(w.cond) or self.blockNeedsHashSetMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsHashSetMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsHashSetMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsHashSetMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsHashSetMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsBTreeSetMacros(self: *Codegen, expr: *const ast.Node) bool {
        if (self.tc.expr_types.get(expr)) |ty| {
            if (btreeSetTypes(ty) != null) return true;
        }
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (call.associated_target) |target| {
                    if (std.mem.eql(u8, target, "BTreeSet")) break :blk true;
                }
                if (call.args.len > 0 and (lowering_rules.isInsertCall(call) or lowering_rules.isContainsCall(call))) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty != null and btreeSetTypes(recv_ty.?) != null) break :blk true;
                }
                for (call.args) |arg| {
                    if (self.exprNeedsBTreeSetMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .binary_expr => |bin| self.exprNeedsBTreeSetMacros(bin.left) or self.exprNeedsBTreeSetMacros(bin.right),
            .borrow_expr => |borrow| self.exprNeedsBTreeSetMacros(borrow.expr),
            .move_expr => |move| self.exprNeedsBTreeSetMacros(move.expr),
            .deref_expr => |deref| self.exprNeedsBTreeSetMacros(deref.expr),
            .field_expr => |field| self.exprNeedsBTreeSetMacros(field.expr),
            .index_expr => |idx| self.exprNeedsBTreeSetMacros(idx.target) or self.exprNeedsBTreeSetMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsBTreeSetMacros(slc.target) or self.exprNeedsBTreeSetMacros(slc.start) or self.exprNeedsBTreeSetMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsBTreeSetMacros(lit.body),
            .await_expr => |aw| self.exprNeedsBTreeSetMacros(aw.expr),
            .try_expr => |trye| self.exprNeedsBTreeSetMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsBTreeSetMacros(field.value)) break :blk true;
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsBTreeSetMacros(field.value)) break :blk true;
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsBTreeSetMacros(elem)) break :blk true;
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsBTreeSetMacros(elem)) break :blk true;
                break :blk false;
            },
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsBTreeSetMacros, blockNeedsBTreeSetMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsBTreeSetMacros(swe.val)) break :blk true;
                for (swe.cases) |case| if (self.exprNeedsBTreeSetMacros(case.pattern) or self.blockNeedsBTreeSetMacros(case.body)) break :blk true;
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsBTreeSetMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsBTreeSetMacros(guard)) break :blk true;
                    if (self.blockNeedsBTreeSetMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsBTreeSetMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsBTreeSetMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsBTreeSetMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsBTreeSetMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsBTreeSetMacros(assign.target) or self.exprNeedsBTreeSetMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsBTreeSetMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsBTreeSetMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsBTreeSetMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsBTreeSetMacros(end_expr) else false) or self.blockNeedsBTreeSetMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsBTreeSetMacros(w.cond) or self.blockNeedsBTreeSetMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsBTreeSetMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsBTreeSetMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsBTreeSetMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsBTreeSetMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsBTreeMapMacros(self: *Codegen, expr: *const ast.Node) bool {
        if (self.tc.expr_types.get(expr)) |ty| {
            if (btreeMapTypes(ty) != null) return true;
        }
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (call.associated_target) |target| {
                    if (std.mem.eql(u8, target, "BTreeMap")) break :blk true;
                }
                for (call.args) |arg| {
                    if (self.exprNeedsBTreeMapMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .binary_expr => |bin| self.exprNeedsBTreeMapMacros(bin.left) or self.exprNeedsBTreeMapMacros(bin.right),
            .borrow_expr => |borrow| self.exprNeedsBTreeMapMacros(borrow.expr),
            .move_expr => |move| self.exprNeedsBTreeMapMacros(move.expr),
            .deref_expr => |deref| self.exprNeedsBTreeMapMacros(deref.expr),
            .field_expr => |field| self.exprNeedsBTreeMapMacros(field.expr),
            .index_expr => |idx| self.exprNeedsBTreeMapMacros(idx.target) or self.exprNeedsBTreeMapMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsBTreeMapMacros(slc.target) or self.exprNeedsBTreeMapMacros(slc.start) or self.exprNeedsBTreeMapMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsBTreeMapMacros(lit.body),
            .await_expr => |aw| self.exprNeedsBTreeMapMacros(aw.expr),
            .try_expr => |trye| self.exprNeedsBTreeMapMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsBTreeMapMacros(field.value)) break :blk true;
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsBTreeMapMacros(field.value)) break :blk true;
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsBTreeMapMacros(elem)) break :blk true;
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsBTreeMapMacros(elem)) break :blk true;
                break :blk false;
            },
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsBTreeMapMacros, blockNeedsBTreeMapMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsBTreeMapMacros(swe.val)) break :blk true;
                for (swe.cases) |case| if (self.exprNeedsBTreeMapMacros(case.pattern) or self.blockNeedsBTreeMapMacros(case.body)) break :blk true;
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsBTreeMapMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsBTreeMapMacros(guard)) break :blk true;
                    if (self.blockNeedsBTreeMapMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsBTreeMapMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsBTreeMapMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsBTreeMapMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsBTreeMapMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsBTreeMapMacros(assign.target) or self.exprNeedsBTreeMapMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsBTreeMapMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsBTreeMapMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsBTreeMapMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsBTreeMapMacros(end_expr) else false) or self.blockNeedsBTreeMapMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsBTreeMapMacros(w.cond) or self.blockNeedsBTreeMapMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsBTreeMapMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsBTreeMapMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsBTreeMapMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsBTreeMapMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsAtomicMacros(self: *Codegen, expr: *const ast.Node) bool {
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (call.associated_target) |target| {
                    if (std.mem.eql(u8, target, "AtomicI32")) break :blk true;
                    if (std.mem.eql(u8, target, "AtomicUsize")) break :blk true;
                }
                if (call.args.len > 0) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty != null and isAtomicI32Type(recv_ty.?)) break :blk true;
                    if (recv_ty != null and isAtomicUsizeType(recv_ty.?)) break :blk true;
                }
                for (call.args) |arg| if (self.exprNeedsAtomicMacros(arg)) break :blk true;
                break :blk false;
            },
            .binary_expr => |bin| self.exprNeedsAtomicMacros(bin.left) or self.exprNeedsAtomicMacros(bin.right),
            .borrow_expr => |borrow| self.exprNeedsAtomicMacros(borrow.expr),
            .move_expr => |move| self.exprNeedsAtomicMacros(move.expr),
            .deref_expr => |deref| self.exprNeedsAtomicMacros(deref.expr),
            .field_expr => |field| self.exprNeedsAtomicMacros(field.expr),
            .index_expr => |idx| self.exprNeedsAtomicMacros(idx.target) or self.exprNeedsAtomicMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsAtomicMacros(slc.target) or self.exprNeedsAtomicMacros(slc.start) or self.exprNeedsAtomicMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsAtomicMacros(lit.body),
            .await_expr => |aw| self.exprNeedsAtomicMacros(aw.expr),
            .try_expr => |trye| self.exprNeedsAtomicMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsAtomicMacros(field.value)) break :blk true;
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsAtomicMacros(field.value)) break :blk true;
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsAtomicMacros(elem)) break :blk true;
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsAtomicMacros(elem)) break :blk true;
                break :blk false;
            },
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsAtomicMacros, blockNeedsAtomicMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsAtomicMacros(swe.val)) break :blk true;
                for (swe.cases) |case| if (self.exprNeedsAtomicMacros(case.pattern) or self.blockNeedsAtomicMacros(case.body)) break :blk true;
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsAtomicMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsAtomicMacros(guard)) break :blk true;
                    if (self.blockNeedsAtomicMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsAtomicMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsAtomicMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsAtomicMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsAtomicMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsAtomicMacros(assign.target) or self.exprNeedsAtomicMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsAtomicMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsAtomicMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsAtomicMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsAtomicMacros(end_expr) else false) or self.blockNeedsAtomicMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsAtomicMacros(w.cond) or self.blockNeedsAtomicMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsAtomicMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsAtomicMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsAtomicMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsAtomicMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsPtrMacros(self: *Codegen, expr: *const ast.Node) bool {
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (lowering_rules.callNeedsPtrMacros(call)) break :blk true;
                for (call.args) |arg| if (self.exprNeedsPtrMacros(arg)) break :blk true;
                break :blk false;
            },
            .binary_expr => |bin| self.exprNeedsPtrMacros(bin.left) or self.exprNeedsPtrMacros(bin.right),
            .borrow_expr => |borrow| self.exprNeedsPtrMacros(borrow.expr),
            .move_expr => |move| self.exprNeedsPtrMacros(move.expr),
            .deref_expr => |deref| self.exprNeedsPtrMacros(deref.expr),
            .field_expr => |field| self.exprNeedsPtrMacros(field.expr),
            .index_expr => |idx| self.exprNeedsPtrMacros(idx.target) or self.exprNeedsPtrMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsPtrMacros(slc.target) or self.exprNeedsPtrMacros(slc.start) or self.exprNeedsPtrMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsPtrMacros(lit.body),
            .await_expr => |aw| self.exprNeedsPtrMacros(aw.expr),
            .try_expr => |trye| self.exprNeedsPtrMacros(trye.expr),
            .unsafe_expr => |unsafe_expr| self.blockNeedsPtrMacros(unsafe_expr.body),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsPtrMacros(field.value)) break :blk true;
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsPtrMacros(field.value)) break :blk true;
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsPtrMacros(elem)) break :blk true;
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsPtrMacros(elem)) break :blk true;
                break :blk false;
            },
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsPtrMacros, blockNeedsPtrMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsPtrMacros(swe.val)) break :blk true;
                for (swe.cases) |case| if (self.exprNeedsPtrMacros(case.pattern) or self.blockNeedsPtrMacros(case.body)) break :blk true;
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsPtrMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsPtrMacros(guard)) break :blk true;
                    if (self.blockNeedsPtrMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsPtrMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsPtrMacros(let.value)) return true,
                .let_else_stmt => |let| if (self.exprNeedsPtrMacros(let.value) or self.blockNeedsPtrMacros(let.else_block)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsPtrMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsPtrMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsPtrMacros(assign.target) or self.exprNeedsPtrMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsPtrMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsPtrMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsPtrMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsPtrMacros(end_expr) else false) or self.blockNeedsPtrMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsPtrMacros(w.cond) or self.blockNeedsPtrMacros(w.body)) return true,
                .block_stmt => |blk| if (self.blockNeedsPtrMacros(blk.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsPtrMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsPtrMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsPtrMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsPtrMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsCellMacros(self: *Codegen, expr: *const ast.Node) bool {
        if (self.tc.expr_types.get(expr)) |ty| {
            if (cellInnerType(ty) != null) return true;
        }
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (call.associated_target) |target| {
                    if (std.mem.eql(u8, target, "Cell")) break :blk true;
                }
                if (call.args.len > 0) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty != null and cellInnerType(recv_ty.?) != null) break :blk true;
                }
                for (call.args) |arg| if (self.exprNeedsCellMacros(arg)) break :blk true;
                break :blk false;
            },
            .binary_expr => |bin| self.exprNeedsCellMacros(bin.left) or self.exprNeedsCellMacros(bin.right),
            .borrow_expr => |borrow| self.exprNeedsCellMacros(borrow.expr),
            .move_expr => |move| self.exprNeedsCellMacros(move.expr),
            .deref_expr => |deref| self.exprNeedsCellMacros(deref.expr),
            .field_expr => |field| self.exprNeedsCellMacros(field.expr),
            .index_expr => |idx| self.exprNeedsCellMacros(idx.target) or self.exprNeedsCellMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsCellMacros(slc.target) or self.exprNeedsCellMacros(slc.start) or self.exprNeedsCellMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsCellMacros(lit.body),
            .await_expr => |aw| self.exprNeedsCellMacros(aw.expr),
            .try_expr => |trye| self.exprNeedsCellMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsCellMacros(field.value)) break :blk true;
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| if (self.exprNeedsCellMacros(field.value)) break :blk true;
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsCellMacros(elem)) break :blk true;
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| if (self.exprNeedsCellMacros(elem)) break :blk true;
                break :blk false;
            },
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsCellMacros, blockNeedsCellMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsCellMacros(swe.val)) break :blk true;
                for (swe.cases) |case| if (self.exprNeedsCellMacros(case.pattern) or self.blockNeedsCellMacros(case.body)) break :blk true;
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsCellMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsCellMacros(guard)) break :blk true;
                    if (self.blockNeedsCellMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsCellMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsCellMacros(let.value)) return true,
                .let_else_stmt => |let| if (self.exprNeedsCellMacros(let.value) or self.blockNeedsCellMacros(let.else_block)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsCellMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsCellMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsCellMacros(assign.target) or self.exprNeedsCellMacros(assign.value)) return true,
                .expr_stmt => |expr| if (self.exprNeedsCellMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsCellMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsCellMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsCellMacros(end_expr) else false) or self.blockNeedsCellMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsCellMacros(w.cond) or self.blockNeedsCellMacros(w.body)) return true,
                .block_stmt => |blk| if (self.blockNeedsCellMacros(blk.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsCellMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsCellMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsCellMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsCellMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsAsyncMacros(expr: *const ast.Node) bool {
        return switch (expr.*) {
            .await_expr => true,
            .binary_expr => |bin| exprNeedsAsyncMacros(bin.left) or exprNeedsAsyncMacros(bin.right),
            .borrow_expr => |borrow| exprNeedsAsyncMacros(borrow.expr),
            .move_expr => |move| exprNeedsAsyncMacros(move.expr),
            .deref_expr => |deref| exprNeedsAsyncMacros(deref.expr),
            .field_expr => |field| exprNeedsAsyncMacros(field.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprNeedsAsyncMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprNeedsAsyncMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprNeedsAsyncMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprNeedsAsyncMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .index_expr => |idx| exprNeedsAsyncMacros(idx.target) or exprNeedsAsyncMacros(idx.index),
            .slice_expr => |slc| exprNeedsAsyncMacros(slc.target) or exprNeedsAsyncMacros(slc.start) or exprNeedsAsyncMacros(slc.end),
            .closure_literal => |lit| exprNeedsAsyncMacros(lit.body),
            .call_expr => |call| blk: {
                if (call.associated_target != null) {
                    if (lowering_rules.planFutureRuntimeCall(call) != null or
                        lowering_rules.planTaskRuntimeCall(call) != null or
                        lowering_rules.planExecutorRuntimeCall(call) != null or
                        lowering_rules.planPollRuntimeCall(call) != null)
                    {
                        break :blk true;
                    }
                }
                for (call.args) |arg| {
                    if (exprNeedsAsyncMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| ifExprNeedsNoSelf(exprNeedsAsyncMacros, blockNeedsAsyncMacros, ife),
            .switch_expr => |swe| blk: {
                if (exprNeedsAsyncMacros(swe.val)) break :blk true;
                for (swe.cases) |case| {
                    if (exprNeedsAsyncMacros(case.pattern) or blockNeedsAsyncMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (exprNeedsAsyncMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (exprNeedsAsyncMacros(guard)) break :blk true;
                    if (blockNeedsAsyncMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .try_expr => |trye| exprNeedsAsyncMacros(trye.expr),
            else => false,
        };
    }

    fn blockNeedsAsyncMacros(block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (exprNeedsAsyncMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (exprNeedsAsyncMacros(let.value)) return true,
                .const_stmt => |c| if (exprNeedsAsyncMacros(c.value)) return true,
                .assign_stmt => |assign| if (exprNeedsAsyncMacros(assign.target) or exprNeedsAsyncMacros(assign.value)) return true,
                .expr_stmt => |expr| if (exprNeedsAsyncMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (exprNeedsAsyncMacros(v)) return true,
                .for_stmt => |f| if (exprNeedsAsyncMacros(f.start) or (if (f.end) |end_expr| exprNeedsAsyncMacros(end_expr) else false) or blockNeedsAsyncMacros(f.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsTraitObjectMacros(self: *Codegen, expr: *const ast.Node) bool {
        if (lowering_rules.planDynCoercion(self.tc, expr) != null) return true;
        return switch (expr.*) {
            .call_expr => |call| blk: {
                _ = call;
                if (self.tc.dyn_call_traits.contains(expr)) {
                    break :blk true;
                }
                for (expr.call_expr.args) |arg| {
                    if (self.exprNeedsTraitObjectMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .borrow_expr => |borrow| {
                if (self.tc.dyn_borrow_args.contains(expr)) return true;
                return self.exprNeedsTraitObjectMacros(borrow.expr);
            },
            .binary_expr => |bin| self.exprNeedsTraitObjectMacros(bin.left) or self.exprNeedsTraitObjectMacros(bin.right),
            .move_expr => |move| self.exprNeedsTraitObjectMacros(move.expr),
            .deref_expr => |deref| self.exprNeedsTraitObjectMacros(deref.expr),
            .field_expr => |field| self.exprNeedsTraitObjectMacros(field.expr),
            .index_expr => |idx| self.exprNeedsTraitObjectMacros(idx.target) or self.exprNeedsTraitObjectMacros(idx.index),
            .slice_expr => |slc| self.exprNeedsTraitObjectMacros(slc.target) or self.exprNeedsTraitObjectMacros(slc.start) or self.exprNeedsTraitObjectMacros(slc.end),
            .closure_literal => |lit| self.exprNeedsTraitObjectMacros(lit.body),
            .await_expr => |aw| self.exprNeedsTraitObjectMacros(aw.expr),
            .try_expr => |trye| self.exprNeedsTraitObjectMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsTraitObjectMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (self.exprNeedsTraitObjectMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsTraitObjectMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (self.exprNeedsTraitObjectMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| self.ifExprNeedsSelf(exprNeedsTraitObjectMacros, blockNeedsTraitObjectMacros, ife),
            .switch_expr => |swe| blk: {
                if (self.exprNeedsTraitObjectMacros(swe.val)) break :blk true;
                for (swe.cases) |case| {
                    if (self.exprNeedsTraitObjectMacros(case.pattern) or self.blockNeedsTraitObjectMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (self.exprNeedsTraitObjectMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (self.exprNeedsTraitObjectMacros(guard)) break :blk true;
                    if (self.blockNeedsTraitObjectMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsTraitObjectMacros(self: *Codegen, block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (self.exprNeedsTraitObjectMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (self.exprNeedsTraitObjectMacros(let.value)) return true,
                .const_stmt => |c| if (self.exprNeedsTraitObjectMacros(c.value)) return true,
                .assign_stmt => |assign| if (self.exprNeedsTraitObjectMacros(assign.target) or self.exprNeedsTraitObjectMacros(assign.value)) return true,
                .expr_stmt => |e| if (self.exprNeedsTraitObjectMacros(e)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (self.exprNeedsTraitObjectMacros(v)) return true,
                .for_stmt => |f| if (self.exprNeedsTraitObjectMacros(f.start) or (if (f.end) |end_expr| self.exprNeedsTraitObjectMacros(end_expr) else false) or self.blockNeedsTraitObjectMacros(f.body)) return true,
                .while_stmt => |w| if (self.exprNeedsTraitObjectMacros(w.cond) or self.blockNeedsTraitObjectMacros(w.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsTraitObjectMacros(self: *Codegen, program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (self.blockNeedsTraitObjectMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and self.blockNeedsTraitObjectMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (self.blockNeedsTraitObjectMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsAsyncMacros(program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (f.is_async or blockNeedsAsyncMacros(f.body)) return true,
                .test_decl => |t| if (blockNeedsAsyncMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn collectThreadSpawnHelpers(self: *Codegen, program: *const ast.Node) CodegenError!void {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| try self.collectThreadSpawnInBlock(f.body),
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl) try self.collectThreadSpawnInBlock(method.func_decl.body);
                },
                .test_decl => |t| try self.collectThreadSpawnInBlock(t.body),
                .const_stmt => |c| try self.collectThreadSpawnInExpr(c.value),
                else => {},
            }
        }
    }

    fn threadSpawnHelperForExpr(self: *Codegen, expr: *const ast.Node) CodegenError!?ThreadSpawnHelper {
        if (expr.* != .call_expr) return null;
        const call = expr.call_expr;
        if (!lowering_rules.isThreadSpawnCall(call)) {
            return null;
        }
        const closure = threadSpawnClosureLiteral(call.args[0]) orelse return null;
        if (closure.params.len != 0) return null;
        if (self.thread_spawn_helpers.get(expr)) |helper| return helper;
        const join_ty = self.tc.expr_types.get(expr) orelse return CodegenError.CodegenError;
        const ret_ty = joinHandleInnerType(join_ty) orelse return CodegenError.CodegenError;
        const idx = self.thread_helper_idx;
        self.thread_helper_idx += 1;
        const captures = try self.collectThreadClosureCaptures(closure);
        var slot_size: usize = 16;
        for (captures) |capture| slot_size = capture.offset + 8;
        var capture_summary = lowering_rules.EscapedClosureCaptureSummary{};
        for (captures) |capture| {
            capture_summary.has_fn_ptr = capture_summary.has_fn_ptr or capture.is_fn_ptr;
            capture_summary.has_noncopy_payload = capture_summary.has_noncopy_payload or capture.is_noncopy_payload;
        }
        const execution_plan = lowering_rules.planEscapedClosureExecution(capture_summary);
        const helper = ThreadSpawnHelper{
            .worker_name = std.fmt.allocPrint(self.allocator, "sla_thread_worker_{}", .{idx}) catch return CodegenError.OutOfMemory,
            .spawn_name = std.fmt.allocPrint(self.allocator, "sla_thread_spawn_{}", .{idx}) catch return CodegenError.OutOfMemory,
            .vtable_name = std.fmt.allocPrint(self.allocator, "SLA_THREAD_VT_{}", .{idx}) catch return CodegenError.OutOfMemory,
            .closure = closure,
            .ret_ty = ret_ty,
            .captures = captures,
            .slot_size = slot_size,
            .inline_join = execution_plan.inline_join,
        };
        try self.thread_spawn_helpers.put(expr, helper);
        return helper;
    }

    fn collectThreadSpawnInBlock(self: *Codegen, block: []const *ast.Node) CodegenError!void {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| try self.collectThreadSpawnInExpr(let.value),
                .let_destructure_stmt => |let| try self.collectThreadSpawnInExpr(let.value),
                .const_stmt => |c| try self.collectThreadSpawnInExpr(c.value),
                .assign_stmt => |assign| {
                    try self.collectThreadSpawnInExpr(assign.target);
                    try self.collectThreadSpawnInExpr(assign.value);
                },
                .block_stmt => |b| try self.collectThreadSpawnInBlock(b.body),
                .expr_stmt => |expr| try self.collectThreadSpawnInExpr(expr),
                .return_stmt => |ret| if (ret.value) |v| try self.collectThreadSpawnInExpr(v),
                .for_stmt => |f| {
                    try self.collectThreadSpawnInExpr(f.start);
                    if (f.end) |end_expr| try self.collectThreadSpawnInExpr(end_expr);
                    try self.collectThreadSpawnInBlock(f.body);
                },
                .while_stmt => |w| {
                    try self.collectThreadSpawnInExpr(w.cond);
                    try self.collectThreadSpawnInBlock(w.body);
                },
                else => {},
            }
        }
    }

    fn collectThreadSpawnInExpr(self: *Codegen, expr: *const ast.Node) CodegenError!void {
        switch (expr.*) {
            .call_expr => |call| {
                if (lowering_rules.isThreadSpawnCall(call)) {
                    _ = try self.threadSpawnHelperForExpr(expr);
                }
                for (call.args) |arg| try self.collectThreadSpawnInExpr(arg);
            },
            .binary_expr => |bin| {
                try self.collectThreadSpawnInExpr(bin.left);
                try self.collectThreadSpawnInExpr(bin.right);
            },
            .borrow_expr => |b| try self.collectThreadSpawnInExpr(b.expr),
            .move_expr => |m| try self.collectThreadSpawnInExpr(m.expr),
            .deref_expr => |d| try self.collectThreadSpawnInExpr(d.expr),
            .cast_expr => |c| try self.collectThreadSpawnInExpr(c.expr),
            .field_expr => |f| try self.collectThreadSpawnInExpr(f.expr),
            .struct_literal => |lit| for (lit.fields) |field| try self.collectThreadSpawnInExpr(field.value),
            .enum_literal => |lit| for (lit.fields) |field| try self.collectThreadSpawnInExpr(field.value),
            .tuple_literal => |lit| for (lit.elements) |elem| try self.collectThreadSpawnInExpr(elem),
            .array_literal => |lit| for (lit.elements) |elem| try self.collectThreadSpawnInExpr(elem),
            .repeat_array_literal => |lit| try self.collectThreadSpawnInExpr(lit.value),
            .index_expr => |idx| {
                try self.collectThreadSpawnInExpr(idx.target);
                try self.collectThreadSpawnInExpr(idx.index);
            },
            .slice_expr => |slc| {
                try self.collectThreadSpawnInExpr(slc.target);
                try self.collectThreadSpawnInExpr(slc.start);
                try self.collectThreadSpawnInExpr(slc.end);
            },
            .closure_literal => |lit| try self.collectThreadSpawnInExpr(lit.body),
            .await_expr => |aw| try self.collectThreadSpawnInExpr(aw.expr),
            .try_expr => |trye| try self.collectThreadSpawnInExpr(trye.expr),
            .if_expr => |ife| {
                try self.collectThreadSpawnInExpr(ife.cond);
                if (ife.let_chain) |chain| {
                    for (chain) |cond| try self.collectThreadSpawnInExpr(cond.value);
                }
                try self.collectThreadSpawnInBlock(ife.then_block);
                if (ife.else_block) |eb| try self.collectThreadSpawnInBlock(eb);
            },
            .switch_expr => |swe| {
                try self.collectThreadSpawnInExpr(swe.val);
                for (swe.cases) |case| {
                    try self.collectThreadSpawnInExpr(case.pattern);
                    try self.collectThreadSpawnInBlock(case.body);
                }
            },
            .match_expr => |mat| {
                try self.collectThreadSpawnInExpr(mat.val);
                for (mat.cases) |case| {
                    if (case.guard) |guard| try self.collectThreadSpawnInExpr(guard);
                    try self.collectThreadSpawnInBlock(case.body);
                }
            },
            else => {},
        }
    }

    fn emitThreadSpawnHelpers(self: *Codegen) CodegenError!void {
        if (self.thread_spawn_helpers.count() == 0) return;
        var iter = self.thread_spawn_helpers.valueIterator();
        while (iter.next()) |helper| {
            if (helper.inline_join) continue;
            self.out.writer().print("@const {s} = vtable {{ call = @{s} }}\n", .{ helper.vtable_name, helper.worker_name }) catch return CodegenError.CodegenError;
        }
        self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;

        var fn_iter = self.thread_spawn_helpers.valueIterator();
        while (fn_iter.next()) |helper| {
            if (helper.inline_join) continue;
            self.out.writer().print("@ffi_wrapper {s}(*slot: ptr):\nL_ENTRY:\n", .{helper.spawn_name}) catch return CodegenError.CodegenError;
            self.out.writer().print("    worker_vt = &{s}\n", .{helper.vtable_name}) catch return CodegenError.CodegenError;
            self.out.writer().print("    worker_fn = load worker_vt+0 as ptr\n", .{}) catch return CodegenError.CodegenError;
            self.out.writer().print("    worker_raw = *worker_fn\n", .{}) catch return CodegenError.CodegenError;
            self.out.writer().print("    worker_safe = assume_safe worker_raw\n", .{}) catch return CodegenError.CodegenError;
            self.out.writer().print("    EXPAND THREAD_SPAWN handle, *worker_safe, *slot\n", .{}) catch return CodegenError.CodegenError;
            self.out.writer().print("    store slot+0, handle as i32\n", .{}) catch return CodegenError.CodegenError;
            self.out.writer().print("    !handle\n    !worker_safe\n    !worker_raw\n    !worker_fn\n    !worker_vt\n    !slot\n    return\n\n", .{}) catch return CodegenError.CodegenError;

            self.out.writer().print("@{s}(&slot: ptr) -> i32:\nL_ENTRY:\n", .{helper.worker_name}) catch return CodegenError.CodegenError;
            for (helper.captures) |capture| {
                const capture_reg = try self.newTmp();
                self.out.writer().print("    {s} = load slot+{} as ptr\n", .{ capture_reg, capture.offset }) catch return CodegenError.CodegenError;
                self.thread_capture_regs.put(capture.name, capture_reg) catch return CodegenError.OutOfMemory;
            }
            var hoisted_allocs = std.ArrayList([]const u8).init(self.allocator);
            defer hoisted_allocs.deinit();
            if (isVoidType(helper.ret_ty)) {
                // Void closure body: generate as a statement. genExpr would
                // emit `reg = call @void_fn()` and LLVM rejects a named void.
                if (helper.closure.body.* == .call_expr) {
                    try self.genCallStmt(&helper.closure.body.call_expr, &hoisted_allocs);
                } else {
                    _ = try self.genExpr(helper.closure.body, &hoisted_allocs);
                }
                for (helper.captures) |capture| {
                    _ = self.thread_capture_regs.remove(capture.name);
                }
                self.out.writer().print("    !slot\n    return 0\n\n", .{}) catch return CodegenError.CodegenError;
                continue;
            }
            const value_reg = try self.genExpr(helper.closure.body, &hoisted_allocs);
            for (helper.captures) |capture| {
                _ = self.thread_capture_regs.remove(capture.name);
            }
            self.out.writer().print("    store slot+8, {s} as {s}\n", .{ value_reg, typeString(helper.ret_ty) }) catch return CodegenError.CodegenError;
            if (helper.ret_ty.* == .primitive and helper.ret_ty.primitive == .i32) {
                self.out.writer().print("    !slot\n    return {s}\n\n", .{value_reg}) catch return CodegenError.CodegenError;
            } else {
                self.out.writer().print("    !{s}\n    !slot\n    return 0\n\n", .{value_reg}) catch return CodegenError.CodegenError;
            }
        }
    }

    fn emitFutureTaskHelpers(self: *Codegen) CodegenError!void {
        self.out.writer().print(
            \\@const SLA_READY_FUTURE_VT = vtable {{ poll = @sla_future_ready_poll }}
            \\@const SLA_DEFER_READY_FUTURE_VT = vtable {{ poll = @sla_future_defer_ready_poll }}
            \\@const SLA_SLEEP_FUTURE_VT = vtable {{ poll = @sla_future_sleep_poll }}
            \\@const SLA_JOIN2_FUTURE_VT = vtable {{ poll = @sla_future_join2_poll }}
            \\@const SLA_SELECT2_FUTURE_VT = vtable {{ poll = @sla_future_select2_poll }}
            \\
            \\@sla_future_ready_poll(&data_slot: ptr, &ctx_slot: ptr, &out_poll_slot: ptr):
            \\L_ENTRY:
            \\    EXPAND FUTURE_READY_SET_POLL_STATE out_poll_slot, data_slot
            \\    return
            \\
            \\@sla_future_sleep_poll(&data_slot: ptr, &ctx_slot: ptr, &out_poll_slot: ptr):
            \\L_ENTRY:
            \\    sleep_stage = load data_slot+0 as u64
            \\    sleep_now_ns = call @sa_time_instant_ns()
            \\    sleep_deadline_ns = load data_slot+8 as u64
            \\    sleep_is_after = ugt sleep_now_ns, sleep_deadline_ns
            \\    sleep_is_equal = eq sleep_now_ns, sleep_deadline_ns
            \\    sleep_is_expired = or sleep_is_after, sleep_is_equal
            \\    sleep_unfinished = eq sleep_stage, 0
            \\    br sleep_unfinished -> L_SLEEP_CHECK, L_SLEEP_READY
            \\L_SLEEP_CHECK:
            \\    br sleep_is_expired -> L_SLEEP_READY, L_SLEEP_PENDING
            \\L_SLEEP_PENDING:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    !sleep_is_equal
            \\    !sleep_is_after
            \\    !sleep_is_expired
            \\    !sleep_deadline_ns
            \\    !sleep_now_ns
            \\    !sleep_unfinished
            \\    !sleep_stage
            \\    jmp L_SLEEP_DONE
            \\L_SLEEP_READY:
            \\    sleep_zero = 0
            \\    store data_slot+0, 1 as u64
            \\    store data_slot+8, sleep_zero as u64
            \\    EXPAND POLL_SET_READY out_poll_slot, sleep_zero
            \\    !sleep_zero
            \\    !sleep_is_equal
            \\    !sleep_is_after
            \\    !sleep_is_expired
            \\    !sleep_deadline_ns
            \\    !sleep_now_ns
            \\    !sleep_unfinished
            \\    !sleep_stage
            \\L_SLEEP_DONE:
            \\    return
            \\@sla_future_defer_ready_poll(&data_slot: ptr, &ctx_slot: ptr, &out_poll_slot: ptr):
            \\L_ENTRY:
            \\    defer_ready_stage = load data_slot+0 as u64
            \\    defer_ready_is_initial = eq defer_ready_stage, 0
            \\    br defer_ready_is_initial -> L_DEFER_READY_PENDING, L_DEFER_READY_CHECK_READY
            \\L_DEFER_READY_PENDING:
            \\    store data_slot+0, 1 as u64
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    jmp L_DEFER_READY_DONE
            \\L_DEFER_READY_CHECK_READY:
            \\    defer_ready_is_ready = eq defer_ready_stage, 1
            \\    br defer_ready_is_ready -> L_DEFER_READY_READY, L_DEFER_READY_EMPTY
            \\L_DEFER_READY_READY:
            \\    defer_ready_value = load data_slot+8 as u64
            \\    store data_slot+0, 2 as u64
            \\    EXPAND POLL_SET_READY out_poll_slot, defer_ready_value
            \\    !defer_ready_value
            \\    !defer_ready_is_ready
            \\    jmp L_DEFER_READY_DONE
            \\L_DEFER_READY_EMPTY:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    !defer_ready_is_ready
            \\L_DEFER_READY_DONE:
            \\    !defer_ready_is_initial
            \\    !defer_ready_stage
            \\    return
            \\
            \\@sla_future_join2_poll(&data_slot: ptr, &ctx_slot: ptr, &out_poll_slot: ptr):
            \\L_ENTRY:
            \\    EXPAND FUTURE_JOIN2_STATE_POLL join2_poll_tmp, data_slot, ctx_slot
            \\    join2_poll_tag = load join2_poll_tmp+Poll_tag as u64
            \\    join2_poll_value = load join2_poll_tmp+Poll_value as u64
            \\    store out_poll_slot+Poll_tag, join2_poll_tag as u64
            \\    store out_poll_slot+Poll_value, join2_poll_value as u64
            \\    !join2_poll_value
            \\    !join2_poll_tag
            \\    !join2_poll_tmp
            \\    return
            \\
            \\@sla_future_select2_poll(&data_slot: ptr, &ctx_slot: ptr, &out_poll_slot: ptr):
            \\L_ENTRY:
            \\    EXPAND FUTURE_SELECT2_STATE_POLL select2_poll_tmp, data_slot, ctx_slot
            \\    select2_poll_tag = load select2_poll_tmp+Poll_tag as u64
            \\    select2_poll_value = load select2_poll_tmp+Poll_value as u64
            \\    store out_poll_slot+Poll_tag, select2_poll_tag as u64
            \\    store out_poll_slot+Poll_value, select2_poll_value as u64
            \\    !select2_poll_value
            \\    !select2_poll_tag
            \\    !select2_poll_tmp
            \\    return
            \\
            \\
        , .{}) catch return CodegenError.CodegenError;
    }

    fn collectTimeMacroUseExpr(expr: *const ast.Node, summary: *TimeMacroUseSummary) void {
        switch (expr.*) {
            .call_expr => |call| {
                summary.observe(call.func_name);
                for (call.args) |arg| collectTimeMacroUseExpr(arg, summary);
            },
            .binary_expr => |bin| {
                collectTimeMacroUseExpr(bin.left, summary);
                collectTimeMacroUseExpr(bin.right, summary);
            },
            .borrow_expr => |borrow| collectTimeMacroUseExpr(borrow.expr, summary),
            .move_expr => |move| collectTimeMacroUseExpr(move.expr, summary),
            .deref_expr => |deref| collectTimeMacroUseExpr(deref.expr, summary),
            .cast_expr => |cast| collectTimeMacroUseExpr(cast.expr, summary),
            .field_expr => |field| collectTimeMacroUseExpr(field.expr, summary),
            .closure_literal => |closure| collectTimeMacroUseExpr(closure.body, summary),
            .await_expr => |await_expr| collectTimeMacroUseExpr(await_expr.expr, summary),
            .try_expr => |try_expr| collectTimeMacroUseExpr(try_expr.expr, summary),
            .struct_literal => |lit| {
                if (lit.update_expr) |update| collectTimeMacroUseExpr(update, summary);
                for (lit.fields) |field| collectTimeMacroUseExpr(field.value, summary);
            },
            .enum_literal => |lit| {
                for (lit.fields) |field| collectTimeMacroUseExpr(field.value, summary);
            },
            .tuple_literal => |lit| {
                for (lit.elements) |element| collectTimeMacroUseExpr(element, summary);
            },
            .array_literal => |lit| {
                for (lit.elements) |element| collectTimeMacroUseExpr(element, summary);
            },
            .repeat_array_literal => |lit| collectTimeMacroUseExpr(lit.value, summary),
            .index_expr => |index| {
                collectTimeMacroUseExpr(index.target, summary);
                collectTimeMacroUseExpr(index.index, summary);
            },
            .slice_expr => |slice| {
                collectTimeMacroUseExpr(slice.target, summary);
                collectTimeMacroUseExpr(slice.start, summary);
                collectTimeMacroUseExpr(slice.end, summary);
            },
            .if_expr => |if_expr| {
                collectTimeMacroUseExpr(if_expr.cond, summary);
                if (if_expr.let_chain) |chain| {
                    for (chain) |item| collectTimeMacroUseExpr(item.value, summary);
                }
                collectTimeMacroUseBlock(if_expr.then_block, summary);
                if (if_expr.else_block) |else_block| collectTimeMacroUseBlock(else_block, summary);
            },
            .switch_expr => |switch_expr| {
                collectTimeMacroUseExpr(switch_expr.val, summary);
                for (switch_expr.cases) |case| {
                    collectTimeMacroUseExpr(case.pattern, summary);
                    collectTimeMacroUseBlock(case.body, summary);
                }
            },
            .match_expr => |match_expr| {
                collectTimeMacroUseExpr(match_expr.val, summary);
                for (match_expr.cases) |case| {
                    if (case.guard) |guard| collectTimeMacroUseExpr(guard, summary);
                    collectTimeMacroUseBlock(case.body, summary);
                }
            },
            .unsafe_expr => |unsafe_expr| collectTimeMacroUseBlock(unsafe_expr.body, summary),
            else => {},
        }
    }

    fn collectTimeMacroUseBlock(block: []const *ast.Node, summary: *TimeMacroUseSummary) void {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| collectTimeMacroUseExpr(let.value, summary),
                .let_else_stmt => |let| {
                    collectTimeMacroUseExpr(let.value, summary);
                    collectTimeMacroUseBlock(let.else_block, summary);
                },
                .let_destructure_stmt => |let| collectTimeMacroUseExpr(let.value, summary),
                .const_stmt => |constant| collectTimeMacroUseExpr(constant.value, summary),
                .assign_stmt => |assign| {
                    collectTimeMacroUseExpr(assign.target, summary);
                    collectTimeMacroUseExpr(assign.value, summary);
                },
                .block_stmt => |nested| collectTimeMacroUseBlock(nested.body, summary),
                .expr_stmt => |expr| collectTimeMacroUseExpr(expr, summary),
                .return_stmt => |ret| if (ret.value) |value| collectTimeMacroUseExpr(value, summary),
                .for_stmt => |for_stmt| {
                    collectTimeMacroUseExpr(for_stmt.start, summary);
                    if (for_stmt.end) |end| collectTimeMacroUseExpr(end, summary);
                    collectTimeMacroUseBlock(for_stmt.body, summary);
                },
                .while_stmt => |while_stmt| {
                    collectTimeMacroUseExpr(while_stmt.cond, summary);
                    collectTimeMacroUseBlock(while_stmt.body, summary);
                },
                else => {},
            }
        }
    }

    fn programSupportsPlainTimeSleepMsAbi(program: *const ast.Node) bool {
        var summary = TimeMacroUseSummary{};
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |func| collectTimeMacroUseBlock(func.body, &summary),
                .impl_decl => |impl| for (impl.methods) |method| {
                    if (method.* == .func_decl) collectTimeMacroUseBlock(method.func_decl.body, &summary);
                },
                .overload_decl => |overload| for (overload.methods) |method| {
                    if (method.* == .func_decl) collectTimeMacroUseBlock(method.func_decl.body, &summary);
                },
                .macro_decl => |macro| collectTimeMacroUseBlock(macro.body, &summary),
                .test_decl => |test_decl| collectTimeMacroUseBlock(test_decl.body, &summary),
                .const_stmt => |constant| collectTimeMacroUseExpr(constant.value, &summary),
                else => {},
            }
        }
        return summary.supportsPlainSleepMsAbi();
    }

    fn pruneUnusedThreadRuntimeImport(self: *Codegen) void {
        const output = self.out.items;
        const needs_runtime =
            std.mem.indexOf(u8, output, "EXPAND THREAD_") != null or
            std.mem.indexOf(u8, output, "call @pthread_") != null or
            std.mem.indexOf(u8, output, "call @sa_thread_") != null;
        if (needs_runtime) return;

        const import_line = "@import \"sa_std/thread.sa\"\n";
        var read: usize = 0;
        var write: usize = 0;
        while (read < self.out.items.len) {
            const at_line_start = read == 0 or self.out.items[read - 1] == '\n';
            if (at_line_start and std.mem.startsWith(u8, self.out.items[read..], import_line)) {
                read += import_line.len;
                continue;
            }
            self.out.items[write] = self.out.items[read];
            write += 1;
            read += 1;
        }
        self.out.items.len = write;
    }

    pub fn generate(self: *Codegen, program: *ast.Node) CodegenError![]const u8 {
        if (program.* != .program) return CodegenError.CodegenError;
        self.global_const_bindings.clearRetainingCapacity();
        self.global_scalar_consts.clearRetainingCapacity();
        self.use_plain_time_sleep_ms_abi = programSupportsPlainTimeSleepMsAbi(program);
        try self.collectThreadSpawnHelpers(program);

        // Struct layouts are compile-time Sla metadata. The generated SA uses
        // flattened stack offsets directly because SA rejects brace layouts.

        // 1. Emit imports before generated code so SA flattener sees std macros/contracts.
        for (program.program.decls) |decl| {
            if (decl.* == .import_decl) {
                try self.genImportDecl(&decl.import_decl);
            } else if (decl.* == .using_decl) {
                continue;
            }
        }
        if (self.use_plain_time_sleep_ms_abi) {
            self.out.writer().print("@extern sa_time_sleep_ms(ms: u64) -> i32\n", .{}) catch return CodegenError.CodegenError;
        }

        self.out.writer().print("@import \"sa_std/string.sa\"\n", .{}) catch return CodegenError.CodegenError;
        self.out.writer().print("@import \"sa_std/string_format.sa\"\n", .{}) catch return CodegenError.CodegenError;
        self.out.writer().print("@import \"sa_std/io/print.sai\"\n", .{}) catch return CodegenError.CodegenError;
        self.out.writer().print("@import \"sa_std/fmt.sai\"\n", .{}) catch return CodegenError.CodegenError;
        self.out.writer().print("@import \"sa_std/core/panic.sa\"\n", .{}) catch return CodegenError.CodegenError;

        try self.emitArrayFillMacros();
        if (self.programNeedsCmpMacros(program)) {
            self.out.writer().print("@import \"sa_std/cmp.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsOptionMacros(program)) {
            self.out.writer().print("@import \"sa_std/core/option.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsResultMacros(program)) {
            self.out.writer().print("@import \"sa_std/core/result.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsMpscMacros(program)) {
            self.out.writer().print("@import \"sa_std/sync/mpsc.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsRcMacros(program)) {
            self.out.writer().print("@import \"sa_std/core/rc.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsVecDequeMacros(program)) {
            self.out.writer().print("@import \"sa_std/vec_deque.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsHashMapMacros(program)) {
            self.out.writer().print("@import \"sa_std/hashmap.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsBTreeMapMacros(program)) {
            self.out.writer().print("@import \"sa_std/btree_map.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsHashSetMacros(program)) {
            self.out.writer().print("@import \"sa_std/hashset.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsBTreeSetMacros(program)) {
            self.out.writer().print("@import \"sa_std/btree_set.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsAtomicMacros(program)) {
            self.out.writer().print("@import \"sa_std/sync/atomic.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsCellMacros(program)) {
            self.out.writer().print("@import \"sa_std/core/cell.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (lowering_rules.programNeedsRefCellRuntime(self.tc, program)) {
            self.out.writer().print("@import \"sa_std/core/refcell.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (programNeedsBoxMacros(program)) {
            self.out.writer().print("@import \"sa_std/core/box.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsVecMacros(program)) {
            self.out.writer().print("@import \"sa_std/vec.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (programNeedsIterMacros(program)) {
            self.out.writer().print("@import \"sa_std/iter.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsTraitObjectMacros(program)) {
            self.out.writer().print("@import \"sa_std/core/trait_object.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (programNeedsAsyncMacros(program)) {
            self.out.writer().print("@import \"sa_std/core/future.sa\"\n", .{}) catch return CodegenError.CodegenError;
            self.out.writer().print("@import \"sa_std/core/task.sa\"\n", .{}) catch return CodegenError.CodegenError;
            self.out.writer().print("@import \"sa_std/time.sai\"\n", .{}) catch return CodegenError.CodegenError;
        }
        if (self.programNeedsFfiCstrMacros(program)) {
            self.out.writer().print("@import \"sa_std/ffi.sa\"\n", .{}) catch return CodegenError.CodegenError;
        }

        if (self.programNeedsHashMapMacros(program)) {
            try self.emitHashMapMacros();
        }
        if (self.programNeedsBTreeMapMacros(program)) {
            try self.emitBTreeMapMacros();
        }
        if (programNeedsAsyncMacros(program)) {
            try self.emitFutureTaskHelpers();
        }
        try self.emitThreadSpawnHelpers();

        // 2. User macros are inline-expanded at call sites.

        // 3. Emit top-level const declarations
        // 3a. Register every top-level const name into the binding set...
        for (program.program.decls) |decl| {
            if (decl.* == .const_stmt) {
                self.global_const_bindings.put(decl.const_stmt.name, {}) catch return CodegenError.OutOfMemory;
            }
        }
        // 3b. ...register every literal scalar const into the scalar consts...
        for (program.program.decls) |decl| {
            if (decl.* == .const_stmt) {
                if (decl.const_stmt.value.* == .literal) {
                    switch (decl.const_stmt.value.literal) {
                        .int_val, .float_val, .bool_val => self.global_scalar_consts.put(decl.const_stmt.name, decl.const_stmt.value) catch return CodegenError.OutOfMemory,
                        .string_val => {},
                    }
                }
            }
        }
        // 3c. Fold scalar aliases (const A = B;) into the scalar consts table.
        // Iterative, decoupled from declaration order: each pass resolves one
        // hop of the alias chain. Because a finite number of top-level consts
        // can only form a finite chain, the loop converges in O(n) passes.
        while (true) {
            var changed = false;
            for (program.program.decls) |decl| {
                if (decl.* != .const_stmt) continue;
                if (decl.const_stmt.value.* == .literal) continue;
                if (decl.const_stmt.value.* != .identifier) continue;
                if (self.global_scalar_consts.contains(decl.const_stmt.name)) continue;
                const target = decl.const_stmt.value.identifier;
                if (self.global_scalar_consts.get(target)) |target_literal| {
                    self.global_scalar_consts.put(decl.const_stmt.name, target_literal) catch return CodegenError.OutOfMemory;
                    changed = true;
                }
            }
            if (!changed) break;
        }
        // 3c-bis. Fold top-level scalar binary consts (const N = a OP b;)
        // such as `0 - 1` (the SLA idiom for a negative integer literal). Each
        // pass resolves one hop (both operands must already be literal scalar
        // const nodes or aliases folding into them). Repeats until the alias
        // and binary chains are fully resolved.
        while (true) {
            var folded_any = false;
            for (program.program.decls) |decl| {
                if (decl.* != .const_stmt) continue;
                if (decl.const_stmt.value.* != .binary_expr) continue;
                if (self.global_scalar_consts.contains(decl.const_stmt.name)) continue;
                const folded = try self.foldTopLevelBinaryConst(&decl.const_stmt.value.binary_expr);
                if (folded) |folded_node| {
                    self.global_scalar_consts.put(decl.const_stmt.name, folded_node) catch return CodegenError.OutOfMemory;
                    folded_any = true;
                }
            }
            if (!folded_any) break;
            // Newly folded consts may unblock further alias resolution.
            while (true) {
                var alias_changed = false;
                for (program.program.decls) |decl| {
                    if (decl.* != .const_stmt) continue;
                    if (decl.const_stmt.value.* == .literal) continue;
                    if (decl.const_stmt.value.* != .identifier) continue;
                    if (self.global_scalar_consts.contains(decl.const_stmt.name)) continue;
                    const target = decl.const_stmt.value.identifier;
                    if (self.global_scalar_consts.get(target)) |target_literal| {
                        self.global_scalar_consts.put(decl.const_stmt.name, target_literal) catch return CodegenError.OutOfMemory;
                        alias_changed = true;
                    }
                }
                if (!alias_changed) break;
            }
        }
        // 3d. Emit codegen for top-level const declarations (non-scalar forms
        // only; scalar aliases resolve at use sites via global_scalar_consts).
        for (program.program.decls) |decl| {
            if (decl.* == .const_stmt) {
                try self.emitTopLevelConstDecl(&decl.const_stmt);
            }
        }

        for (program.program.decls) |decl| {
            if (decl.* == .impl_decl and decl.impl_decl.trait_name != null) {
                try self.emitTraitVTableDecl(&decl.impl_decl);
            }
        }

        for (program.program.decls) |decl| {
            if (decl.* == .func_decl) {
                if (decl.func_decl.is_decl_only) {
                    if (!try self.hasConcreteFunctionSymbol(program.program.decls, &decl.func_decl)) {
                        try self.emitExternDecl(&decl.func_decl);
                    }
                } else {
                    try self.emitFunctionPointerVTableDecl(decl.func_decl.name);
                }
            }
        }

        // 4. Emit functions
        for (program.program.decls) |decl| {
            if (decl.* == .func_decl) {
                if (!decl.func_decl.is_decl_only) {
                    if (std.process.hasEnvVarConstant("SLA_CODEGEN_TRACE")) std.debug.print("[sla-trace] gen func {s}\n", .{decl.func_decl.name});
                    try self.genFuncDecl(&decl.func_decl);
                }
            } else if (decl.* == .impl_decl) {
                const impl_name = switch (decl.impl_decl.target_ty.*) {
                    .user_defined => |ud| ud.name,
                    else => return CodegenError.CodegenError,
                };
                for (decl.impl_decl.methods) |method| {
                    if (method.* != .func_decl) return CodegenError.CodegenError;
                    if (method.func_decl.is_decl_only) continue;
                    const mangled = if (decl.impl_decl.trait_name) |trait_name|
                        try self.mangleTraitMethodName(impl_name, trait_name, method.func_decl.name)
                    else
                        try self.mangleMethodName(impl_name, method.func_decl.name);
                    defer self.allocator.free(mangled);
                    try self.genFuncDeclNamed(mangled, &method.func_decl);
                }
            } else if (decl.* == .overload_decl) {
                const overload_name = switch (decl.overload_decl.target_ty.*) {
                    .user_defined => |ud| ud.name,
                    else => return CodegenError.CodegenError,
                };
                for (decl.overload_decl.methods) |method| {
                    if (method.* != .func_decl) return CodegenError.CodegenError;
                    if (method.func_decl.is_decl_only) continue;
                    const mangled = try self.mangleMethodName(overload_name, method.func_decl.name);
                    defer self.allocator.free(mangled);
                    try self.genFuncDeclNamed(mangled, &method.func_decl);
                }
            }
        }

        // 5. Emit test declarations
        for (program.program.decls) |decl| {
            if (decl.* == .test_decl) {
                try self.genTestDecl(&decl.test_decl);
            }
        }

        self.pruneUnusedThreadRuntimeImport();
        return self.out.toOwnedSlice() catch return CodegenError.OutOfMemory;
    }

    fn genImportDecl(self: *Codegen, import: *const ast.ImportDecl) CodegenError!void {
        var path = import.path;
        var path_buf: [1024]u8 = undefined;
        if (std.mem.endsWith(u8, path, ".sla")) {
            const base = path[0 .. path.len - 4];
            path = std.fmt.bufPrint(&path_buf, "{s}.sa", .{base}) catch path;
        }
        if (self.use_plain_time_sleep_ms_abi and std.mem.endsWith(u8, path, "sa_std/time.sa")) return;
        if (std.fs.path.isAbsolute(path)) {
            if (std.mem.indexOf(u8, path, "sa_std/")) |idx| {
                path = path[idx..];
            } else if (std.mem.indexOf(u8, path, ".sa/std/")) |idx| {
                const suffix = path[idx + ".sa/std/".len ..];
                self.out.writer().print("@import \"sa_std/{s}\"\n", .{suffix}) catch return CodegenError.CodegenError;
                return;
            } else if (std.mem.indexOf(u8, path, "sci/sa_std/")) |idx| {
                const suffix = path[idx + "sci/sa_std/".len ..];
                self.out.writer().print("@import \"sa_std/{s}\"\n", .{suffix}) catch return CodegenError.CodegenError;
                return;
            }
        }
        self.out.writer().print("@import \"{s}\"\n", .{path}) catch return CodegenError.CodegenError;
    }

    fn genMacroDecl(self: *Codegen, m: *const ast.MacroDecl) CodegenError!void {
        // Clear previous macro locals
        var val_iter = self.macro_locals.valueIterator();
        while (val_iter.next()) |v| {
            self.allocator.free(v.*);
        }
        self.macro_locals.clearRetainingCapacity();

        self.out.writer().print("[MACRO] {s}", .{m.name}) catch return CodegenError.CodegenError;
        for (m.params) |p| {
            self.out.writer().print(" %{s}", .{p}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;

        // Perform Alpha-conversion for local variables declared in macro body
        // and map macro parameters to %param
        for (m.body) |stmt| {
            try self.genMacroStmt(stmt, m);
        }
        self.out.writer().print("[END_MACRO]\n\n", .{}) catch return CodegenError.CodegenError;
    }

    fn genMacroStmt(self: *Codegen, stmt: *ast.Node, m: *const ast.MacroDecl) CodegenError!void {
        // Simple macro body transpile converting parameter names to %param
        // and mangling local variables to ensure hygiene
        switch (stmt.*) {
            .let_stmt => |let| {
                const mangled = try self.newMacroLocal(m.name, let.name);
                const val_reg = try self.genMacroExpr(let.value, m);
                self.out.writer().print("    {s} = {s}\n", .{ mangled, val_reg }) catch return CodegenError.CodegenError;
            },
            .assign_stmt => |assign| {
                const val_reg = try self.genMacroExpr(assign.value, m);
                if (assign.target.* == .identifier) {
                    const target_name = assign.target.identifier;
                    for (m.params) |p| {
                        if (std.mem.eql(u8, target_name, p)) {
                            self.out.writer().print("    !%{s}\n", .{p}) catch return CodegenError.CodegenError;
                            self.out.writer().print("    %{s} = {s}\n", .{ p, val_reg }) catch return CodegenError.CodegenError;
                            return;
                        }
                    }
                    if (self.macro_locals.get(target_name)) |mangled| {
                        self.out.writer().print("    !{s}\n", .{mangled}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    {s} = {s}\n", .{ mangled, val_reg }) catch return CodegenError.CodegenError;
                        return;
                    }
                }
                const target_reg = try self.genMacroExpr(assign.target, m);
                self.out.writer().print("    {s} = {s}\n", .{ target_reg, val_reg }) catch return CodegenError.CodegenError;
            },
            .release_stmt => |rel| {
                var is_param = false;
                for (m.params) |p| {
                    if (std.mem.eql(u8, rel.var_name, p)) {
                        self.out.writer().print("    !%{s}\n", .{p}) catch return CodegenError.CodegenError;
                        is_param = true;
                        break;
                    }
                }
                if (!is_param) {
                    // Assume it's a macro local
                    self.out.writer().print("    !{s}_{s}_uniq_0\n", .{ m.name, rel.var_name }) catch return CodegenError.CodegenError;
                }
            },
            .expr_stmt => |expr| {
                _ = try self.genMacroExpr(expr, m);
            },
            else => {},
        }
    }

    fn genMacroExpr(self: *Codegen, expr: *ast.Node, m: *const ast.MacroDecl) CodegenError![]const u8 {
        switch (expr.*) {
            .literal => |lit| {
                const reg = try self.newTmp();
                switch (lit) {
                    .int_val => |v| try self.emitIntConst(reg, v),
                    .float_val => |v| try self.emitFloatConst(reg, v),
                    .bool_val => |v| try self.emitIntConst(reg, if (v) 1 else 0),
                    .string_val => |v| {
                        const label = try self.newStringConst();
                        self.out.writer().print("    @const {s} = utf8:\"{s}\"\n", .{ label, v }) catch return CodegenError.CodegenError;
                        const len_reg = try self.newTmp();
                        try self.emitIntConst(len_reg, @as(i64, @intCast(escapedStringByteLen(v))));
                        self.out.writer().print("    {s} = alloc Slice_SIZE\n", .{reg}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND SLICE_NEW {s}, &{s}, {s}\n", .{ reg, label, len_reg }) catch return CodegenError.CodegenError;
                        try self.emitRelease(len_reg);
                    },
                }
                return reg;
            },
            .identifier => |name| {
                if (self.macro_locals.get(name)) |mangled| {
                    return mangled;
                }
                for (m.params) |p| {
                    if (std.mem.eql(u8, name, p)) {
                        return std.fmt.allocPrint(self.allocator, "%{s}", .{p}) catch return CodegenError.OutOfMemory;
                    }
                }
                return name;
            },
            .move_expr => |move| {
                const inner = try self.genMacroExpr(move.expr, m);
                return std.fmt.allocPrint(self.allocator, "^{s}", .{inner}) catch return CodegenError.OutOfMemory;
            },
            .borrow_expr => |borrow| {
                const inner = try self.genMacroExpr(borrow.expr, m);
                const reg = try self.newTmp();
                self.out.writer().print("    {s} = &{s}\n", .{ reg, inner }) catch return CodegenError.CodegenError;
                return reg;
            },
            .binary_expr => |bin| {
                const left_ty = self.tc.expr_types.get(bin.left) orelse return CodegenError.CodegenError;
                const right_ty = self.tc.expr_types.get(bin.right) orelse return CodegenError.CodegenError;
                const l = try self.genMacroExpr(bin.left, m);
                const r = try self.genMacroExpr(bin.right, m);
                const reg = try self.newTmp();
                const op = binaryOpName(bin.op, left_ty, right_ty) orelse return CodegenError.CodegenError;
                self.out.writer().print("    {s} = {s} {s}, {s}\n", .{ reg, op, l, r }) catch return CodegenError.CodegenError;
                return reg;
            },
            else => return "tmp_macro_res",
        }
    }

    /// Tracked wrapper: remembers which function was being lowered so a
    /// failing CodegenError can be reported with the function's name.
    fn genFuncDeclNamed(self: *Codegen, name: []const u8, f: *const ast.FuncDecl) CodegenError!void {
        const prev_func = self.diag_func_name;
        self.diag_func_name = name;
        const result = self.genFuncDeclNamedImpl(name, f);
        if (result) |_| {
            self.diag_func_name = prev_func;
            self.diag_call_arg_index = null;
        } else |err| {
            self.synthesizeDiagFromContext(err);
            self.diag_func_name = prev_func;
            self.diag_call_arg_index = null;
            return err;
        }
    }

    fn genFuncDeclNamedImpl(self: *Codegen, name: []const u8, f: *const ast.FuncDecl) CodegenError!void {
        const prev_async = self.current_async;
        const prev_async_return_ty = self.current_async_return_ty;
        const prev_async_pending_return = self.async_pending_return_emitted;
        self.current_async = f.is_async;
        self.current_async_return_ty = if (f.is_async) f.ret_ty else null;
        self.async_pending_return_emitted = false;
        defer self.current_async = prev_async;
        defer self.current_async_return_ty = prev_async_return_ty;
        defer self.async_pending_return_emitted = prev_async_pending_return;
        self.addressable_bindings.clearRetainingCapacity();
        self.assigned_bindings.clearRetainingCapacity();
        self.assigned_value_slots.clearRetainingCapacity();
        self.repeated_let_bindings.clearRetainingCapacity();
        self.stack_alloc_bindings.clearRetainingCapacity();
        self.inline_thread_handles.clearRetainingCapacity();
        self.consumed_bindings.clearRetainingCapacity();
        self.mpsc_sender_bindings.clearRetainingCapacity();
        self.mpsc_sender_channels.clearRetainingCapacity();
        self.mpsc_receiver_bindings.clearRetainingCapacity();
        self.string_buf_bindings.clearRetainingCapacity();
        self.hashmap_bindings.clearRetainingCapacity();
        self.btree_map_bindings.clearRetainingCapacity();
        self.hashset_bindings.clearRetainingCapacity();
        self.btree_set_bindings.clearRetainingCapacity();
        self.borrow_source_temps.clearRetainingCapacity();
        self.refcell_borrow_handles.clearRetainingCapacity();
        self.result_slot_refcell_handles.clearRetainingCapacity();
        self.result_slot_refcell_slots.clearRetainingCapacity();
        self.mutex_guard_handles.clearRetainingCapacity();
        self.mutex_lock_results.clearRetainingCapacity();
        self.rwlock_guard_handles.clearRetainingCapacity();
        self.rwlock_lock_results.clearRetainingCapacity();
        self.file_bindings.clearRetainingCapacity();
        self.file_open_results.clearRetainingCapacity();
        self.metadata_bindings.clearRetainingCapacity();
        self.metadata_open_results.clearRetainingCapacity();
        self.task_future_objects.clearRetainingCapacity();
        self.future_state_vtables.clearRetainingCapacity();
        self.future_readiness.clearRetainingCapacity();
        self.executor_task_counts.clearRetainingCapacity();
        self.local_binding_types.clearRetainingCapacity();
        self.clearBindingAliases();
        self.let_binding_aliases.clearRetainingCapacity();
        self.clearHashMapKeySlots();
        try lowering_rules.collectRepeatedLetBindings(self.allocator, f.body, &self.repeated_let_bindings);
        try self.collectAssignedBindings(f.body);
        try self.collectAddressableBindings(f.body);

        if (lowering_rules.planAsyncJoin2AwaitContinuation(f)) |plan| {
            return try self.genAsyncJoin2AwaitFuncDeclNamed(name, f, plan);
        }
        if (lowering_rules.planAsyncTwoAwaitContinuation(f)) |plan| {
            return try self.genAsyncTwoAwaitFuncDeclNamed(name, f, plan);
        }
        if (lowering_rules.planAsyncSingleAwaitContinuation(f)) |plan| {
            return try self.genAsyncSingleAwaitFuncDeclNamed(name, f, plan);
        }
        if (self.planAsyncTwoAwaitContinuationDynamic(f)) |plan| {
            return try self.genAsyncTwoAwaitFuncDeclNamed(name, f, plan);
        }
        if (self.planAsyncSingleAwaitContinuationDynamic(f)) |plan| {
            return try self.genAsyncSingleAwaitFuncDeclNamed(name, f, plan);
        }

        // Emit function signature
        const lowered_name = try self.loweredFuncSymbol(name);
        defer self.allocator.free(lowered_name);
        self.out.writer().print("@{s}(", .{lowered_name}) catch return CodegenError.CodegenError;
        for (f.params, 0..) |p, i| {
            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
            const prefix: []const u8 = self.abiParamPrefix(p);
            self.out.writer().print("{s}{s}: {s}", .{ prefix, p.name, abiParamTypeString(p) }) catch return CodegenError.CodegenError;
        }
        const async_return_plan = lowering_rules.planAsyncFunctionReturn(f.*, try self.makeAbiPtrType());
        const ret_type_str = abiReturnTypeString(async_return_plan.abi_ret_ty);
        if (isVoidType(f.ret_ty) and !f.is_async) {
            self.out.writer().print("):\n", .{}) catch return CodegenError.CodegenError;
        } else {
            self.out.writer().print(") -> {s}:\n", .{ret_type_str}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print("L_ENTRY:\n", .{}) catch return CodegenError.CodegenError;

        // 1. Loop allocation hoisting pre-pass
        // Detect all stack allocations inside for loops in this function body
        var hoisted_allocs = std.ArrayList([]const u8).init(self.allocator);
        defer hoisted_allocs.deinit();
        try self.collectHoistedAllocs(f.body, &hoisted_allocs);

        var loop_counter_slots = std.ArrayList([]const u8).init(self.allocator);
        defer loop_counter_slots.deinit();
        try self.collectLoopCounterSlots(f.body, &loop_counter_slots);

        for (hoisted_allocs.items) |h_name| {
            self.out.writer().print("    {s} = stack_alloc 16\n", .{h_name}) catch return CodegenError.CodegenError;
        }
        for (loop_counter_slots.items) |slot_name| {
            self.out.writer().print("    {s} = stack_alloc 8\n", .{slot_name}) catch return CodegenError.CodegenError;
            self.stack_alloc_bindings.put(slot_name, {}) catch return CodegenError.OutOfMemory;
        }

        for (f.params) |p| {
            try self.rememberLocalBindingType(p.name, p.ty);
            if (p.ty.* == .borrow and sliceElementType(p.ty.borrow) != null) {
                const raw_param = try self.newTmp();
                const raw_ptr = try self.newTmp();
                const raw_len = try self.newTmp();
                self.out.writer().print("    {s} = {s}\n", .{ raw_param, p.name }) catch return CodegenError.CodegenError;
                self.stack_alloc_bindings.put(p.name, {}) catch return CodegenError.OutOfMemory;
                self.out.writer().print("    {s} = stack_alloc Slice_SIZE\n", .{p.name}) catch return CodegenError.CodegenError;
                self.out.writer().print("    {s} = load {s}+0 as ptr\n", .{ raw_ptr, raw_param }) catch return CodegenError.CodegenError;
                self.out.writer().print("    {s} = load {s}+8 as u64\n", .{ raw_len, raw_param }) catch return CodegenError.CodegenError;
                self.out.writer().print("    store {s}+0, {s} as ptr\n", .{ p.name, raw_ptr }) catch return CodegenError.CodegenError;
                self.out.writer().print("    store {s}+8, {s} as u64\n", .{ p.name, raw_len }) catch return CodegenError.CodegenError;
                try self.emitRelease(raw_ptr);
                try self.emitRelease(raw_len);
                try self.emitRelease(raw_param);
            }
            if (!p.is_borrow and !p.is_move and self.bindingNeedsAddressableStorage(p.name, p.ty)) {
                const raw_param = try self.newTmp();
                self.out.writer().print("    {s} = {s}\n", .{ raw_param, p.name }) catch return CodegenError.CodegenError;
                self.stack_alloc_bindings.put(p.name, {}) catch return CodegenError.OutOfMemory;
                self.out.writer().print("    {s} = stack_alloc {}\n", .{ p.name, typeSize(p.ty) }) catch return CodegenError.CodegenError;
                self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ p.name, raw_param, typeString(p.ty) }) catch return CodegenError.CodegenError;
                try self.emitRelease(raw_param);
            } else if (!p.is_borrow and !p.is_move and self.bindingNeedsAssignedValueSlot(p.name, p.ty)) {
                const raw_param = try self.newTmp();
                self.out.writer().print("    {s} = {s}\n", .{ raw_param, p.name }) catch return CodegenError.CodegenError;
                self.stack_alloc_bindings.put(p.name, {}) catch return CodegenError.OutOfMemory;
                self.assigned_value_slots.put(p.name, {}) catch return CodegenError.OutOfMemory;
                self.out.writer().print("    {s} = stack_alloc {}\n", .{ p.name, typeSize(p.ty) }) catch return CodegenError.CodegenError;
                self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ p.name, raw_param, typeString(p.ty) }) catch return CodegenError.CodegenError;
            }
        }

        // 2. Compile body statements
        const tail_expr_return = !isVoidType(f.ret_ty) and f.body.len > 0 and f.body[f.body.len - 1].* == .expr_stmt and !blockTerminates(f.body);
        if (tail_expr_return) {
            for (f.body[0 .. f.body.len - 1]) |stmt| {
                try self.genStmt(stmt, &hoisted_allocs);
                if (self.async_pending_return_emitted) break;
            }
            if (!self.async_pending_return_emitted) {
                const tail_expr = f.body[f.body.len - 1].expr_stmt;
                var tail_reg = try self.genExpr(tail_expr, &hoisted_allocs);
                if (!self.async_pending_return_emitted) {
                    if (async_return_plan.wrap_ready_future) {
                        tail_reg = try self.genReadyFutureI64(tail_reg);
                    }
                    try self.emitFunctionTailCleanups(f.body[f.body.len - 1], tail_expr);
                    self.out.writer().print("    return {s}\n", .{tail_reg}) catch return CodegenError.CodegenError;
                }
            }
        } else {
            try self.genBlock(f.body, &hoisted_allocs);
        }

        if (self.async_pending_return_emitted) {
            // The generated pending await returned from this async function.
        } else if (async_return_plan.wrap_ready_future and !tail_expr_return and !blockTerminates(f.body)) {
            const zero = try self.newTmp();
            self.out.writer().print("    {s} = 0\n", .{zero}) catch return CodegenError.CodegenError;
            const future = try self.genReadyFutureI64(zero);
            self.out.writer().print("    return {s}\n", .{future}) catch return CodegenError.CodegenError;
        } else if (isVoidType(f.ret_ty)) {
            self.out.writer().print("    return\n", .{}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;
    }

    fn genFuncDecl(self: *Codegen, f: *const ast.FuncDecl) CodegenError!void {
        try self.genFuncDeclNamed(f.name, f);
    }

    fn genTestDecl(self: *Codegen, t: *const ast.TestDecl) CodegenError!void {
        self.addressable_bindings.clearRetainingCapacity();
        self.assigned_bindings.clearRetainingCapacity();
        self.assigned_value_slots.clearRetainingCapacity();
        self.repeated_let_bindings.clearRetainingCapacity();
        self.stack_alloc_bindings.clearRetainingCapacity();
        self.inline_thread_handles.clearRetainingCapacity();
        self.consumed_bindings.clearRetainingCapacity();
        self.mpsc_sender_bindings.clearRetainingCapacity();
        self.mpsc_sender_channels.clearRetainingCapacity();
        self.mpsc_receiver_bindings.clearRetainingCapacity();
        self.string_buf_bindings.clearRetainingCapacity();
        self.hashmap_bindings.clearRetainingCapacity();
        self.btree_map_bindings.clearRetainingCapacity();
        self.hashset_bindings.clearRetainingCapacity();
        self.btree_set_bindings.clearRetainingCapacity();
        self.borrow_source_temps.clearRetainingCapacity();
        self.refcell_borrow_handles.clearRetainingCapacity();
        self.result_slot_refcell_handles.clearRetainingCapacity();
        self.result_slot_refcell_slots.clearRetainingCapacity();
        self.mutex_guard_handles.clearRetainingCapacity();
        self.mutex_lock_results.clearRetainingCapacity();
        self.rwlock_guard_handles.clearRetainingCapacity();
        self.rwlock_lock_results.clearRetainingCapacity();
        self.file_bindings.clearRetainingCapacity();
        self.file_open_results.clearRetainingCapacity();
        self.metadata_bindings.clearRetainingCapacity();
        self.metadata_open_results.clearRetainingCapacity();
        self.task_future_objects.clearRetainingCapacity();
        self.future_state_vtables.clearRetainingCapacity();
        self.future_readiness.clearRetainingCapacity();
        self.executor_task_counts.clearRetainingCapacity();
        self.local_binding_types.clearRetainingCapacity();
        self.clearBindingAliases();
        self.let_binding_aliases.clearRetainingCapacity();
        self.clearHashMapKeySlots();
        try lowering_rules.collectRepeatedLetBindings(self.allocator, t.body, &self.repeated_let_bindings);
        try self.collectAssignedBindings(t.body);
        try self.collectAddressableBindings(t.body);

        // Emit SA @test header:  @test [ignored] [should_panic] "name"():
        self.out.writer().print("@test", .{}) catch return CodegenError.CodegenError;
        if (t.is_ignored) {
            self.out.writer().print(" ignored", .{}) catch return CodegenError.CodegenError;
        }
        if (t.should_panic) {
            self.out.writer().print(" should_panic", .{}) catch return CodegenError.CodegenError;
        }
        const test_name = try self.sanitizeTestName(t.name);
        defer self.allocator.free(test_name);
        self.out.writer().print(" \"{s}\"():\n", .{test_name}) catch return CodegenError.CodegenError;
        const entry_label = try self.newLabel("L_TEST_ENTRY");
        self.out.writer().print("{s}:\n", .{entry_label}) catch return CodegenError.CodegenError;

        // Hoist any stack allocations inside the test body
        var hoisted_allocs = std.ArrayList([]const u8).init(self.allocator);
        defer hoisted_allocs.deinit();
        try self.collectHoistedAllocs(t.body, &hoisted_allocs);

        var loop_counter_slots = std.ArrayList([]const u8).init(self.allocator);
        defer loop_counter_slots.deinit();
        try self.collectLoopCounterSlots(t.body, &loop_counter_slots);

        for (hoisted_allocs.items) |h_name| {
            self.out.writer().print("    {s} = stack_alloc 16\n", .{h_name}) catch return CodegenError.CodegenError;
        }
        for (loop_counter_slots.items) |slot_name| {
            self.out.writer().print("    {s} = stack_alloc 8\n", .{slot_name}) catch return CodegenError.CodegenError;
            self.stack_alloc_bindings.put(slot_name, {}) catch return CodegenError.OutOfMemory;
        }

        // Compile body statements
        try self.genBlock(t.body, &hoisted_allocs);

        // Tests return void
        self.out.writer().print("    return\n", .{}) catch return CodegenError.CodegenError;
        self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;
    }

    fn collectHoistedAllocs(self: *Codegen, block: []const *ast.Node, list: *std.ArrayList([]const u8)) CodegenError!void {
        try self.collectHoistedAllocsInternal(block, list, false);
    }

    fn appendUniqueName(self: *Codegen, list: *std.ArrayList([]const u8), name: []const u8) CodegenError!void {
        _ = self;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        list.append(name) catch return CodegenError.OutOfMemory;
    }

    fn collectLoopCounterSlots(self: *Codegen, block: []const *ast.Node, list: *std.ArrayList([]const u8)) CodegenError!void {
        for (block) |stmt| {
            switch (stmt.*) {
                .for_stmt => |f| {
                    const slot_name = std.fmt.allocPrint(self.allocator, "{s}_slot", .{f.var_name}) catch return CodegenError.OutOfMemory;
                    try self.appendUniqueName(list, slot_name);
                    try self.collectLoopCounterSlots(f.body, list);
                },
                .while_stmt => |w| {
                    try self.collectLoopCounterSlots(w.body, list);
                },
                .block_stmt => |blk| {
                    try self.collectLoopCounterSlots(blk.body, list);
                },
                .let_else_stmt => |let| {
                    try self.collectLoopCounterSlots(let.else_block, list);
                },
                .expr_stmt => |expr| {
                    try self.collectLoopCounterSlotsInExpr(expr, list);
                },
                .let_stmt => |let| {
                    try self.collectLoopCounterSlotsInExpr(let.value, list);
                },
                .const_stmt => |c| {
                    try self.collectLoopCounterSlotsInExpr(c.value, list);
                },
                .assign_stmt => |assign| {
                    try self.collectLoopCounterSlotsInExpr(assign.target, list);
                    try self.collectLoopCounterSlotsInExpr(assign.value, list);
                },
                .return_stmt => |ret| {
                    if (ret.value) |v| try self.collectLoopCounterSlotsInExpr(v, list);
                },
                .let_destructure_stmt => |let| {
                    try self.collectLoopCounterSlotsInExpr(let.value, list);
                },
                else => {},
            }
        }
    }

    fn collectLoopCounterSlotsInExpr(self: *Codegen, expr: *ast.Node, list: *std.ArrayList([]const u8)) CodegenError!void {
        switch (expr.*) {
            .if_expr => |ife| {
                try self.collectLoopCounterSlotsInExpr(ife.cond, list);
                if (ife.let_chain) |chain| {
                    for (chain) |cond| try self.collectLoopCounterSlotsInExpr(cond.value, list);
                }
                try self.collectLoopCounterSlots(ife.then_block, list);
                if (ife.else_block) |eb| try self.collectLoopCounterSlots(eb, list);
            },
            .switch_expr => |swe| {
                for (swe.cases) |case| try self.collectLoopCounterSlots(case.body, list);
            },
            .match_expr => |mat| {
                for (mat.cases) |case| try self.collectLoopCounterSlots(case.body, list);
            },
            .unsafe_expr => |ue| {
                try self.collectLoopCounterSlots(ue.body, list);
            },
            .call_expr => |call| {
                for (call.args) |arg| try self.collectLoopCounterSlotsInExpr(arg, list);
            },
            .binary_expr => |bin| {
                try self.collectLoopCounterSlotsInExpr(bin.left, list);
                try self.collectLoopCounterSlotsInExpr(bin.right, list);
            },
            .borrow_expr => |borrow| try self.collectLoopCounterSlotsInExpr(borrow.expr, list),
            .move_expr => |move| try self.collectLoopCounterSlotsInExpr(move.expr, list),
            .deref_expr => |deref| try self.collectLoopCounterSlotsInExpr(deref.expr, list),
            .cast_expr => |cast| try self.collectLoopCounterSlotsInExpr(cast.expr, list),
            .field_expr => |field| try self.collectLoopCounterSlotsInExpr(field.expr, list),
            .index_expr => |idx| {
                try self.collectLoopCounterSlotsInExpr(idx.target, list);
                try self.collectLoopCounterSlotsInExpr(idx.index, list);
            },
            .slice_expr => |slc| {
                try self.collectLoopCounterSlotsInExpr(slc.target, list);
                try self.collectLoopCounterSlotsInExpr(slc.start, list);
                try self.collectLoopCounterSlotsInExpr(slc.end, list);
            },
            .tuple_literal => |lit| {
                for (lit.elements) |elem| try self.collectLoopCounterSlotsInExpr(elem, list);
            },
            .array_literal => |lit| {
                for (lit.elements) |elem| try self.collectLoopCounterSlotsInExpr(elem, list);
            },
            .struct_literal => |lit| {
                for (lit.fields) |field| try self.collectLoopCounterSlotsInExpr(field.value, list);
            },
            .enum_literal => |lit| {
                for (lit.fields) |field| try self.collectLoopCounterSlotsInExpr(field.value, list);
            },
            .repeat_array_literal => |lit| try self.collectLoopCounterSlotsInExpr(lit.value, list),
            .await_expr => |aw| try self.collectLoopCounterSlotsInExpr(aw.expr, list),
            .try_expr => |trye| try self.collectLoopCounterSlotsInExpr(trye.expr, list),
            .closure_literal => |lit| try self.collectLoopCounterSlotsInExpr(lit.body, list),
            else => {},
        }
    }

    fn collectHoistedAllocsInternal(self: *Codegen, block: []const *ast.Node, list: *std.ArrayList([]const u8), in_loop: bool) CodegenError!void {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| {
                    if (in_loop) {
                        if (lowering_rules.isStackAllocNode(let.value)) {
                            list.append(let.name) catch return CodegenError.OutOfMemory;
                        }
                    }
                    try self.collectHoistedAllocsInExpr(let.value, list, in_loop);
                },
                .let_else_stmt => |let| {
                    try self.collectHoistedAllocsInExpr(let.value, list, in_loop);
                    try self.collectHoistedAllocsInternal(let.else_block, list, in_loop);
                },
                .let_destructure_stmt => |let| {
                    try self.collectHoistedAllocsInExpr(let.value, list, in_loop);
                },
                .const_stmt => |c| {
                    if (in_loop) {
                        if (lowering_rules.isStackAllocNode(c.value)) {
                            list.append(c.name) catch return CodegenError.OutOfMemory;
                        }
                    }
                    try self.collectHoistedAllocsInExpr(c.value, list, in_loop);
                },
                .assign_stmt => |assign| {
                    try self.collectHoistedAllocsInExpr(assign.target, list, in_loop);
                    try self.collectHoistedAllocsInExpr(assign.value, list, in_loop);
                },
                .expr_stmt => |expr| {
                    try self.collectHoistedAllocsInExpr(expr, list, in_loop);
                },
                .return_stmt => |ret| {
                    if (ret.value) |v| {
                        try self.collectHoistedAllocsInExpr(v, list, in_loop);
                    }
                },
                .for_stmt => |f| {
                    try self.collectHoistedAllocsInternal(f.body, list, true);
                },
                .release_stmt => {},
                else => {},
            }
        }
    }

    fn collectHoistedAllocsInExpr(self: *Codegen, expr: *ast.Node, list: *std.ArrayList([]const u8), in_loop: bool) CodegenError!void {
        switch (expr.*) {
            .if_expr => |ife| {
                try self.collectHoistedAllocsInExpr(ife.cond, list, in_loop);
                if (ife.let_chain) |chain| {
                    for (chain) |cond| try self.collectHoistedAllocsInExpr(cond.value, list, in_loop);
                }
                try self.collectHoistedAllocsInternal(ife.then_block, list, in_loop);
                if (ife.else_block) |eb| {
                    try self.collectHoistedAllocsInternal(eb, list, in_loop);
                }
            },
            .switch_expr => |swe| {
                for (swe.cases) |case| {
                    try self.collectHoistedAllocsInternal(case.body, list, in_loop);
                }
            },
            .binary_expr => |bin| {
                try self.collectHoistedAllocsInExpr(bin.left, list, in_loop);
                try self.collectHoistedAllocsInExpr(bin.right, list, in_loop);
            },
            .borrow_expr => |borrow| {
                try self.collectHoistedAllocsInExpr(borrow.expr, list, in_loop);
            },
            .move_expr => |move| {
                try self.collectHoistedAllocsInExpr(move.expr, list, in_loop);
            },
            .deref_expr => |deref| {
                try self.collectHoistedAllocsInExpr(deref.expr, list, in_loop);
            },
            .field_expr => |field| {
                try self.collectHoistedAllocsInExpr(field.expr, list, in_loop);
            },
            .struct_literal => |lit| {
                for (lit.fields) |field| {
                    try self.collectHoistedAllocsInExpr(field.value, list, in_loop);
                }
            },
            .enum_literal => |lit| {
                for (lit.fields) |field| {
                    try self.collectHoistedAllocsInExpr(field.value, list, in_loop);
                }
            },
            .tuple_literal => |lit| {
                for (lit.elements) |elem| {
                    try self.collectHoistedAllocsInExpr(elem, list, in_loop);
                }
            },
            .match_expr => |mat| {
                try self.collectHoistedAllocsInExpr(mat.val, list, in_loop);
                for (mat.cases) |case| {
                    if (case.guard) |guard| try self.collectHoistedAllocsInExpr(guard, list, in_loop);
                    try self.collectHoistedAllocsInternal(case.body, list, in_loop);
                }
            },
            .unsafe_expr => |ue| {
                try self.collectHoistedAllocsInternal(ue.body, list, in_loop);
            },
            .await_expr => |aw| {
                try self.collectHoistedAllocsInExpr(aw.expr, list, in_loop);
            },
            .closure_literal => |lit| {
                try self.collectHoistedAllocsInExpr(lit.body, list, in_loop);
            },
            .try_expr => |trye| {
                try self.collectHoistedAllocsInExpr(trye.expr, list, in_loop);
            },
            .call_expr => |call| {
                for (call.args) |arg| {
                    try self.collectHoistedAllocsInExpr(arg, list, in_loop);
                }
            },
            .array_literal => |lit| {
                for (lit.elements) |elem| {
                    try self.collectHoistedAllocsInExpr(elem, list, in_loop);
                }
            },
            .index_expr => |idx| {
                try self.collectHoistedAllocsInExpr(idx.target, list, in_loop);
                try self.collectHoistedAllocsInExpr(idx.index, list, in_loop);
            },
            .slice_expr => |slc| {
                try self.collectHoistedAllocsInExpr(slc.target, list, in_loop);
                try self.collectHoistedAllocsInExpr(slc.start, list, in_loop);
                try self.collectHoistedAllocsInExpr(slc.end, list, in_loop);
            },
            else => {},
        }
    }

    fn genBlock(self: *Codegen, block: []const *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!void {
        self.enterBlockForLoopLocalTracking();
        defer self.leaveBlockForLoopLocalTracking();

        const prev_block = self.current_block;
        const prev_stmt_index = self.current_stmt_index;
        self.current_block = block;
        defer {
            self.current_block = prev_block;
            self.current_stmt_index = prev_stmt_index;
        }

        var scoped_aliases = std.ArrayList([]const u8).init(self.allocator);
        defer {
            var i = scoped_aliases.items.len;
            while (i > 0) {
                i -= 1;
                self.popBindingAlias(scoped_aliases.items[i]);
            }
            scoped_aliases.deinit();
        }

        for (block, 0..) |stmt, stmt_index| {
            self.current_stmt_index = stmt_index;
            if (stmt.* == .let_stmt and !isDiscardName(stmt.let_stmt.name)) {
                const source_name = stmt.let_stmt.name;
                const resolved_name = self.resolveBindingName(source_name);
                if (self.repeated_let_bindings.contains(source_name) or self.stack_alloc_bindings.contains(resolved_name)) {
                    const alias = try self.pushBindingAlias(source_name);
                    try scoped_aliases.append(source_name);
                    if (self.addressable_bindings.contains(source_name)) {
                        self.addressable_bindings.put(alias, {}) catch return CodegenError.OutOfMemory;
                    }
                    if (self.assigned_bindings.contains(source_name)) {
                        self.assigned_bindings.put(alias, {}) catch return CodegenError.OutOfMemory;
                    }
                    self.let_binding_aliases.put(stmt, alias) catch return CodegenError.OutOfMemory;
                    var let_copy = stmt.let_stmt;
                    let_copy.name = alias;
                    var node = ast.Node{ .let_stmt = let_copy };
                    try self.genStmt(&node, hoisted_allocs);
                    try self.rememberLoopBodyTopLevelLocal(alias);
                } else {
                    try self.genStmt(stmt, hoisted_allocs);
                    try self.rememberLoopBodyTopLevelLocal(source_name);
                }
            } else {
                try self.genStmt(stmt, hoisted_allocs);
            }
            if (self.async_pending_return_emitted) break;
        }
    }

    fn isDiscardName(name: []const u8) bool {
        return lowering_rules.isDiscardName(name);
    }

    fn emitLoopBodyTopLevelLocalCleanups(self: *Codegen, block: []const *ast.Node) CodegenError!void {
        var i = block.len;
        while (i > 0) {
            i -= 1;
            switch (block[i].*) {
                .const_stmt => |c| if (!isDiscardName(c.name)) try self.emitRelease(c.name),
                .let_destructure_stmt => |let| {
                    if (let.rest_alias) |rest_alias| if (!isDiscardName(rest_alias)) try self.emitRelease(rest_alias);
                    if (let.rest_name) |rest_name| if (!isDiscardName(rest_name)) try self.emitRelease(rest_name);
                    var name_i = let.names.len;
                    while (name_i > 0) {
                        name_i -= 1;
                        const name = let.names[name_i];
                        if (!isDiscardName(name)) try self.emitRelease(name);
                    }
                },
                else => {},
            }
        }
    }

    fn genScopedBlock(self: *Codegen, block: []const *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!void {
        var scoped_var_aliases = std.ArrayList([]const u8).init(self.allocator);
        defer scoped_var_aliases.deinit();

        for (block) |stmt| {
            if (stmt.* == .var_stmt) {
                _ = try self.pushBindingAlias(stmt.var_stmt.name);
                try scoped_var_aliases.append(stmt.var_stmt.name);
            }
            try self.genStmt(stmt, hoisted_allocs);
            if (self.async_pending_return_emitted) break;
        }

        var i = scoped_var_aliases.items.len;
        while (i > 0) {
            i -= 1;
            self.popBindingAlias(scoped_var_aliases.items[i]);
        }
    }

    fn genBlockTailValueInto(
        self: *Codegen,
        block: []const *ast.Node,
        target: []const u8,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        if (block.len == 0) return CodegenError.CodegenError;

        for (block[0 .. block.len - 1]) |stmt| {
            try self.genStmt(stmt, hoisted_allocs);
        }

        const last = block[block.len - 1];
        if (last.* != .expr_stmt) return CodegenError.CodegenError;
        const value_expr = last.expr_stmt;
        const value_reg = try self.genExpr(value_expr, hoisted_allocs);
        const value_ty = self.tc.expr_types.get(value_expr) orelse return CodegenError.CodegenError;
        if (value_expr.* == .identifier and value_ty.* == .primitive) {
            switch (value_ty.primitive) {
                .boolean => self.out.writer().print("    {s} = or {s}, 0\n", .{ target, value_reg }) catch return CodegenError.CodegenError,
                .f32, .f64, .float => self.out.writer().print("    {s} = add {s}, 0.0\n", .{ target, value_reg }) catch return CodegenError.CodegenError,
                else => self.out.writer().print("    {s} = add {s}, 0\n", .{ target, value_reg }) catch return CodegenError.CodegenError,
            }
        } else {
            self.out.writer().print("    {s} = {s}\n", .{ target, value_reg }) catch return CodegenError.CodegenError;
        }

        if (!stmtTerminates(last)) {
            if (self.tc.cleanups.get(last)) |list| {
                for (list.items) |c_var| {
                    try self.emitRelease(c_var);
                }
            }
        }
    }

    fn genBlockTailValueStore(
        self: *Codegen,
        block: []const *ast.Node,
        target_ptr: []const u8,
        target_ty: *const ast.Type,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        if (block.len == 0) return CodegenError.CodegenError;

        for (block[0 .. block.len - 1]) |stmt| {
            try self.genStmt(stmt, hoisted_allocs);
        }

        const last = block[block.len - 1];
        if (last.* != .expr_stmt) return CodegenError.CodegenError;
        const value_expr = last.expr_stmt;
        const value_reg = try self.genExpr(value_expr, hoisted_allocs);
        const value_ty = self.tc.expr_types.get(value_expr) orelse return CodegenError.CodegenError;

        if (value_expr.* == .identifier and value_ty.* == .primitive) {
            const copied = try self.newTmp();
            switch (value_ty.primitive) {
                .boolean => self.out.writer().print("    {s} = or {s}, 0\n", .{ copied, value_reg }) catch return CodegenError.CodegenError,
                .f32, .f64, .float => self.out.writer().print("    {s} = add {s}, 0.0\n", .{ copied, value_reg }) catch return CodegenError.CodegenError,
                else => self.out.writer().print("    {s} = add {s}, 0\n", .{ copied, value_reg }) catch return CodegenError.CodegenError,
            }
            self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ target_ptr, copied, typeString(target_ty) }) catch return CodegenError.CodegenError;
            try self.emitRelease(copied);
        } else {
            self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ target_ptr, value_reg, typeString(target_ty) }) catch return CodegenError.CodegenError;
        }
        try self.storeResultSlotTransferredValueState(target_ptr, value_reg, target_ty, callArgNeedsRelease(value_expr));

        if (!stmtTerminates(last)) {
            if (self.tc.cleanups.get(last)) |list| {
                for (list.items) |c_var| {
                    try self.emitRelease(c_var);
                }
            }
        }
    }

    fn emitFutureStateVTable(self: *Codegen, state_reg: []const u8, vtable_name: []const u8) CodegenError!void {
        self.out.writer().print("    store {s}+FutureState_vtable, &{s} as ptr\n", .{ state_reg, vtable_name }) catch return CodegenError.CodegenError;
    }

    fn genReadyFutureI64(self: *Codegen, value_reg: []const u8) CodegenError![]const u8 {
        const future_reg = try self.newTmp();
        self.out.writer().print("    EXPAND FUTURE_READY_STATE_NEW {s}, {s}\n", .{ future_reg, value_reg }) catch return CodegenError.CodegenError;
        try self.emitFutureStateVTable(future_reg, "SLA_READY_FUTURE_VT");
        self.future_state_vtables.put(future_reg, "SLA_READY_FUTURE_VT") catch return CodegenError.OutOfMemory;
        self.future_readiness.put(future_reg, .ready) catch return CodegenError.OutOfMemory;
        return future_reg;
    }

    fn genPendingFuture(self: *Codegen) CodegenError![]const u8 {
        const future_reg = try self.newTmp();
        self.out.writer().print("    EXPAND FUTURE_PENDING_STATE_NEW {s}\n", .{future_reg}) catch return CodegenError.CodegenError;
        try self.emitFutureStateVTable(future_reg, "SLA_READY_FUTURE_VT");
        self.future_state_vtables.put(future_reg, "SLA_READY_FUTURE_VT") catch return CodegenError.OutOfMemory;
        self.future_readiness.put(future_reg, .pending) catch return CodegenError.OutOfMemory;
        return future_reg;
    }

    fn genDeferReadyFutureI64(self: *Codegen, value_reg: []const u8) CodegenError![]const u8 {
        const future_reg = try self.newTmp();
        self.out.writer().print("    {s} = alloc FutureState_SIZE\n", .{future_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as u64\n", .{future_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+8, {s} as u64\n", .{ future_reg, value_reg }) catch return CodegenError.CodegenError;
        try self.emitFutureStateVTable(future_reg, "SLA_DEFER_READY_FUTURE_VT");
        self.future_state_vtables.put(future_reg, "SLA_DEFER_READY_FUTURE_VT") catch return CodegenError.OutOfMemory;
        try self.recordFutureReadiness(future_reg, .unknown);
        return future_reg;
    }

    fn genSleepMsFuture(self: *Codegen, ms_reg: []const u8) CodegenError![]const u8 {
        const future_reg = try self.newTmp();
        const now_reg = try self.newTmp();
        const scaled_reg = try self.newTmp();
        const deadline_reg = try self.newTmp();
        self.out.writer().print("    {s} = call @sa_time_instant_ns()\n", .{now_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    {s} = mul {s}, 1000000\n", .{ scaled_reg, ms_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    {s} = add {s}, {s}\n", .{ deadline_reg, now_reg, scaled_reg }) catch return CodegenError.CodegenError;
        const zero_reg = try self.newTmp();
        self.out.writer().print("    {s} = alloc FutureState_SIZE\n", .{future_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    {s} = 0\n", .{zero_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {s} as u64\n", .{ future_reg, zero_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+8, {s} as u64\n", .{ future_reg, deadline_reg }) catch return CodegenError.CodegenError;
        try self.emitFutureStateVTable(future_reg, "SLA_SLEEP_FUTURE_VT");
        try self.emitRelease(zero_reg);
        self.emitRelease(deadline_reg) catch return CodegenError.CodegenError;
        self.emitRelease(scaled_reg) catch return CodegenError.CodegenError;
        self.emitRelease(now_reg) catch return CodegenError.CodegenError;
        self.future_state_vtables.put(future_reg, "SLA_SLEEP_FUTURE_VT") catch return CodegenError.OutOfMemory;
        try self.recordFutureReadiness(future_reg, .unknown);
        return future_reg;
    }

    fn futureReadinessForState(self: *Codegen, state_reg: []const u8) lowering_rules.FutureReadiness {
        const resolved = self.resolveBindingName(state_reg);
        if (self.future_readiness.get(resolved)) |readiness| return readiness;
        if (self.future_readiness.get(state_reg)) |readiness| return readiness;
        return .unknown;
    }

    fn recordFutureReadiness(self: *Codegen, state_reg: []const u8, readiness: lowering_rules.FutureReadiness) CodegenError!void {
        if (readiness == .unknown) {
            _ = self.future_readiness.remove(state_reg);
            return;
        }
        self.future_readiness.put(state_reg, readiness) catch return CodegenError.OutOfMemory;
    }

    fn transferFutureReadiness(self: *Codegen, src: []const u8, dst: []const u8) CodegenError!void {
        if (self.future_readiness.get(src)) |readiness| {
            try self.recordFutureReadiness(dst, readiness);
            _ = self.future_readiness.remove(src);
            return;
        }
        _ = self.future_readiness.remove(dst);
    }

    fn futureVTableForState(self: *Codegen, state_reg: []const u8) []const u8 {
        const resolved = self.resolveBindingName(state_reg);
        if (self.future_state_vtables.get(resolved)) |vt| return vt;
        if (self.future_state_vtables.get(state_reg)) |vt| return vt;
        return "SLA_READY_FUTURE_VT";
    }

    fn genFutureObjectForState(self: *Codegen, state_reg: []const u8) CodegenError![]const u8 {
        const vt_reg = try self.newTmp();
        const future_obj = try self.newTmp();
        const vt_name = self.futureVTableForState(state_reg);
        self.out.writer().print("    {s} = &{s}\n", .{ vt_reg, vt_name }) catch return CodegenError.CodegenError;
        self.out.writer().print("    EXPAND FUTURE_NEW {s}, {s}, {s}\n", .{ future_obj, state_reg, vt_reg }) catch return CodegenError.CodegenError;
        try self.emitRelease(vt_reg);
        return future_obj;
    }

    fn genJoin2Future(self: *Codegen, left_state: []const u8, right_state: []const u8) CodegenError![]const u8 {
        const left_future = try self.genFutureObjectForState(left_state);
        const right_future = try self.genFutureObjectForState(right_state);
        const join_state = try self.newTmp();
        self.out.writer().print("    EXPAND FUTURE_JOIN2_STATE_NEW {s}, {s}, {s}\n", .{ join_state, left_future, right_future }) catch return CodegenError.CodegenError;
        try self.emitFutureStateVTable(join_state, "SLA_JOIN2_FUTURE_VT");
        self.future_state_vtables.put(join_state, "SLA_JOIN2_FUTURE_VT") catch return CodegenError.OutOfMemory;
        try self.recordFutureReadiness(join_state, lowering_rules.join2Readiness(self.futureReadinessForState(left_state), self.futureReadinessForState(right_state)));
        try self.emitRelease(left_future);
        try self.emitRelease(right_future);
        return join_state;
    }

    fn genSelect2Future(self: *Codegen, left_state: []const u8, right_state: []const u8) CodegenError![]const u8 {
        const left_future = try self.genFutureObjectForState(left_state);
        const right_future = try self.genFutureObjectForState(right_state);
        const select_state = try self.newTmp();
        self.out.writer().print("    EXPAND FUTURE_SELECT2_STATE_NEW {s}, {s}, {s}\n", .{ select_state, left_future, right_future }) catch return CodegenError.CodegenError;
        try self.emitFutureStateVTable(select_state, "SLA_SELECT2_FUTURE_VT");
        self.future_state_vtables.put(select_state, "SLA_SELECT2_FUTURE_VT") catch return CodegenError.OutOfMemory;
        try self.recordFutureReadiness(select_state, lowering_rules.select2Readiness(self.futureReadinessForState(left_state), self.futureReadinessForState(right_state)));
        try self.emitRelease(left_future);
        try self.emitRelease(right_future);
        return select_state;
    }

    fn genFutureRuntimeCall(self: *Codegen, future_plan: lowering_rules.FutureRuntimeCallPlan, call: ast.CallExpr, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        if (future_plan.isReady()) {
            if (call.args.len != 1) return CodegenError.CodegenError;
            const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const future_reg = try self.genReadyFutureI64(value_reg);
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
            return future_reg;
        }
        if (future_plan.isPending()) {
            if (call.args.len != 0 or call.generics.len != 1) return CodegenError.CodegenError;
            return try self.genPendingFuture();
        }
        if (future_plan.isDeferReady()) {
            if (call.args.len != 1 or call.generics.len != 0) return CodegenError.CodegenError;
            const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const future_reg = try self.genDeferReadyFutureI64(value_reg);
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
            return future_reg;
        }
        if (future_plan.isSleepMs()) {
            if (call.args.len != 1 or call.generics.len != 0) return CodegenError.CodegenError;
            const ms_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const future_reg = try self.genSleepMsFuture(ms_reg);
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(ms_reg);
            return future_reg;
        }
        if (future_plan.isJoin2()) {
            if (call.args.len != 2 or call.generics.len != 0) return CodegenError.CodegenError;
            const left_state = try self.genExpr(call.args[0], hoisted_allocs);
            const right_state = try self.genExpr(call.args[1], hoisted_allocs);
            return try self.genJoin2Future(left_state, right_state);
        }
        if (future_plan.isSelect2()) {
            if (call.args.len != 2 or call.generics.len != 0) return CodegenError.CodegenError;
            const left_state = try self.genExpr(call.args[0], hoisted_allocs);
            const right_state = try self.genExpr(call.args[1], hoisted_allocs);
            return try self.genSelect2Future(left_state, right_state);
        }
        if (future_plan.isPairAccessor()) {
            if (call.args.len != 1 or call.generics.len != 0) return CodegenError.CodegenError;
            const pair_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const value_reg = try self.newTmp();
            const macro_name = future_plan.pairMacroName() orelse return CodegenError.CodegenError;
            self.out.writer().print("    EXPAND {s} {s}, {s}\n", .{ macro_name, value_reg, pair_reg }) catch return CodegenError.CodegenError;
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(pair_reg);
            return value_reg;
        }
        if (future_plan.isEitherAccessor()) {
            if (call.args.len != 1 or call.generics.len != 0) return CodegenError.CodegenError;
            const either_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const value_reg = try self.newTmp();
            const macro_name = future_plan.eitherValueMacroName() orelse return CodegenError.CodegenError;
            self.out.writer().print("    EXPAND {s} {s}, {s}\n", .{ macro_name, value_reg, either_reg }) catch return CodegenError.CodegenError;
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(either_reg);
            return value_reg;
        }
        return CodegenError.CodegenError;
    }

    fn genTaskRuntimeCall(self: *Codegen, task_plan: lowering_rules.TaskRuntimeCallPlan, call: ast.CallExpr, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        if (task_plan.isNew()) {
            if (call.args.len != 1) return CodegenError.CodegenError;
            const state_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const ctx = try self.newTmp();
            const task = try self.newTmp();
            const future_obj = try self.genFutureObjectForState(state_reg);
            self.out.writer().print("    {s} = 0\n", .{ctx}) catch return CodegenError.CodegenError;
            self.out.writer().print("    EXPAND TASK_NEW {s}, {s}, {s}\n", .{ task, future_obj, ctx }) catch return CodegenError.CodegenError;
            try self.emitRelease(ctx);
            self.task_future_objects.put(task, future_obj) catch return CodegenError.OutOfMemory;
            return task;
        }
        if (task_plan.isPoll()) {
            if (call.args.len != 1) return CodegenError.CodegenError;
            const task_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const poll_reg = try self.newTmp();
            const tag_reg = try self.newTmp();
            const ready_reg = try self.newTmp();
            self.out.writer().print("    EXPAND TASK_POLL {s}, {s}\n", .{ poll_reg, task_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = load {s}+Poll_tag as u64\n", .{ tag_reg, poll_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = eq {s}, Poll_READY\n", .{ ready_reg, tag_reg }) catch return CodegenError.CodegenError;
            try self.emitRelease(tag_reg);
            try self.emitRelease(poll_reg);
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(task_reg);
            return ready_reg;
        }
        if (task_plan.isIsReady()) {
            if (call.args.len != 1) return CodegenError.CodegenError;
            const task_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const ready_reg = try self.newTmp();
            self.out.writer().print("    EXPAND TASK_IS_READY {s}, {s}\n", .{ ready_reg, task_reg }) catch return CodegenError.CodegenError;
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(task_reg);
            return ready_reg;
        }
        if (task_plan.isResult()) {
            if (call.args.len != 1) return CodegenError.CodegenError;
            const task_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const value_reg = try self.newTmp();
            self.out.writer().print("    EXPAND TASK_RESULT {s}, {s}\n", .{ value_reg, task_reg }) catch return CodegenError.CodegenError;
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(task_reg);
            return value_reg;
        }
        if (task_plan.isState()) {
            if (call.args.len != 1) return CodegenError.CodegenError;
            const task_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const state_reg = try self.newTmp();
            self.out.writer().print("    EXPAND TASK_STATE {s}, {s}\n", .{ state_reg, task_reg }) catch return CodegenError.CodegenError;
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(task_reg);
            return state_reg;
        }
        return CodegenError.CodegenError;
    }

    fn asyncSingleAwaitVTableName(self: *Codegen, name: []const u8) CodegenError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "SLA_ASYNC_{s}_VT", .{name}) catch return CodegenError.OutOfMemory;
    }

    fn asyncSingleAwaitPollName(self: *Codegen, name: []const u8) CodegenError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "sla_async_{s}_poll", .{name}) catch return CodegenError.OutOfMemory;
    }

    fn asyncTwoAwaitVTableName(self: *Codegen, name: []const u8) CodegenError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "SLA_ASYNC_{s}_TWO_AWAIT_VT", .{name}) catch return CodegenError.OutOfMemory;
    }

    fn asyncTwoAwaitPollName(self: *Codegen, name: []const u8) CodegenError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "sla_async_{s}_two_await_poll", .{name}) catch return CodegenError.OutOfMemory;
    }

    fn asyncJoin2AwaitVTableName(self: *Codegen, name: []const u8) CodegenError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "SLA_ASYNC_{s}_JOIN2_AWAIT_VT", .{name}) catch return CodegenError.OutOfMemory;
    }

    fn asyncJoin2AwaitPollName(self: *Codegen, name: []const u8) CodegenError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "sla_async_{s}_join2_await_poll", .{name}) catch return CodegenError.OutOfMemory;
    }

    fn exprIsAsyncFunctionCall(self: *Codegen, expr: *const ast.Node) bool {
        if (expr.* != .call_expr) return false;
        const call = expr.call_expr;
        const symbol = self.tc.resolved_call_symbols.get(expr) orelse call.func_name;
        if (self.tc.funcs.get(symbol)) |func| return func.is_async;
        if (self.tc.imported_function_signatures.get(symbol)) |signature| return signature.is_async;
        return false;
    }

    fn planAsyncTwoAwaitContinuationDynamic(self: *Codegen, func: *const ast.FuncDecl) ?lowering_rules.AsyncTwoAwaitContinuationPlan {
        const plan = lowering_rules.planAsyncTwoAwaitContinuationDynamic(func) orelse return null;
        if (plan.first_dynamic_poll and !self.exprIsAsyncFunctionCall(plan.first_await_expr)) return null;
        if (plan.second_dynamic_poll and !self.exprIsAsyncFunctionCall(plan.second_await_expr)) return null;
        return plan;
    }

    fn planAsyncSingleAwaitContinuationDynamic(self: *Codegen, func: *const ast.FuncDecl) ?lowering_rules.AsyncSingleAwaitContinuationPlan {
        const plan = lowering_rules.planAsyncSingleAwaitContinuationDynamic(func) orelse return null;
        if (plan.dynamic_poll and !self.exprIsAsyncFunctionCall(plan.await_expr)) return null;
        return plan;
    }

    fn genAsyncSecondAwaitState(
        self: *Codegen,
        plan: lowering_rules.AsyncTwoAwaitContinuationPlan,
        first_value_reg: []const u8,
    ) CodegenError![]const u8 {
        var helper_allocs = std.ArrayList([]const u8).init(self.allocator);
        defer helper_allocs.deinit();
        const previous = self.closure_param_regs.get(plan.first_binding_name);
        self.closure_param_regs.put(plan.first_binding_name, first_value_reg) catch return CodegenError.OutOfMemory;
        defer if (previous) |old| {
            self.closure_param_regs.put(plan.first_binding_name, old) catch {};
        } else {
            _ = self.closure_param_regs.remove(plan.first_binding_name);
        };
        return try self.genExpr(@constCast(plan.second_await_expr), &helper_allocs);
    }

    fn emitAsyncSingleAwaitPollHelperDynamic(self: *Codegen, name: []const u8, plan: lowering_rules.AsyncSingleAwaitContinuationPlan) CodegenError!void {
        const vt_name = try self.asyncSingleAwaitVTableName(name);
        const poll_name = try self.asyncSingleAwaitPollName(name);
        self.out.writer().print(
            \\@const {s} = vtable {{ poll = @{s} }}
            \\@{s}(&data_slot: ptr, &ctx_slot: ptr, &out_poll_slot: ptr):
            \\L_ENTRY:
            \\    async_stage = load data_slot+0 as u64
            \\    async_done = eq async_stage, 1
            \\    br async_done -> L_ASYNC_DYNAMIC_SINGLE_EMPTY, L_ASYNC_DYNAMIC_SINGLE_POLL
            \\L_ASYNC_DYNAMIC_SINGLE_EMPTY:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    jmp L_ASYNC_DYNAMIC_SINGLE_DONE
            \\L_ASYNC_DYNAMIC_SINGLE_POLL:
            \\    async_inner_state = load data_slot+8 as ptr
            \\    EXPAND FUTURE_POLL_STATE async_inner_poll, async_inner_state, ctx_slot
            \\    EXPAND POLL_IS_READY async_inner_ready, async_inner_poll
            \\    br async_inner_ready -> L_ASYNC_DYNAMIC_SINGLE_READY, L_ASYNC_DYNAMIC_SINGLE_PENDING
            \\L_ASYNC_DYNAMIC_SINGLE_PENDING:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    !async_inner_ready
            \\    !async_inner_poll
            \\    !async_inner_state
            \\    jmp L_ASYNC_DYNAMIC_SINGLE_DONE
            \\L_ASYNC_DYNAMIC_SINGLE_READY:
            \\    EXPAND POLL_VALUE async_awaited_value, async_inner_poll
            \\
        , .{ vt_name, poll_name, poll_name }) catch return CodegenError.CodegenError;
        var captured_addend_regs: [2]?[]const u8 = .{ null, null };
        var captured_storage_regs: [2]?[]const u8 = .{ null, null };
        const scalar = plan.scalar;
        for (0..plan.capture_count) |capture_idx| {
            const capture = plan.captures[capture_idx] orelse return CodegenError.CodegenError;
            const reg_name: []const u8 = if (capture_idx == 0) "async_captured_addend" else "async_captured_addend2";
            switch (capture.storage) {
                .scalar => {
                    self.out.writer().print("    {s} = load data_slot+{} as u64\n", .{ reg_name, capture.offset }) catch return CodegenError.CodegenError;
                    captured_addend_regs[capture_idx] = reg_name;
                },
                .copy_struct => {
                    if (plan.branch != null) return CodegenError.CodegenError;
                    const field_name = if (capture_idx == 0) scalar.captured_field_name else scalar.captured2_field_name;
                    const field = field_name orelse return CodegenError.CodegenError;
                    const capture_ty = self.tc.expr_types.get(capture.expr) orelse return CodegenError.CodegenError;
                    if (!self.typeIsCopyStruct(capture_ty)) return CodegenError.CodegenError;
                    const layout = self.aggregateFieldLayout(capture_ty, field) orelse return CodegenError.CodegenError;
                    const ptr_reg: []const u8 = if (capture_idx == 0) "async_captured_struct" else "async_captured_struct2";
                    self.out.writer().print("    {s} = load data_slot+{} as ptr\n", .{ ptr_reg, capture.offset }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ reg_name, ptr_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
                    captured_addend_regs[capture_idx] = reg_name;
                    captured_storage_regs[capture_idx] = ptr_reg;
                },
            }
        }
        const result_reg = if (plan.branch != null) "async_result" else plan.resultBindingName() orelse if (scalar.isIdentity()) plan.binding_name else "async_result";
        if (plan.branch) |branch| {
            const condition_op = asyncContinuationConditionOpName(branch.condition_op) orelse return CodegenError.CodegenError;
            self.out.writer().print(
                \\    async_branch_cond = {s} {s}, {}
                \\    br async_branch_cond -> L_ASYNC_DYNAMIC_SINGLE_BRANCH_THEN, L_ASYNC_DYNAMIC_SINGLE_BRANCH_ELSE
                \\L_ASYNC_DYNAMIC_SINGLE_BRANCH_THEN:
                \\ 
            , .{ condition_op, plan.binding_name, branch.threshold }) catch return CodegenError.CodegenError;
            try self.emitAsyncContinuationScalarValue(branch.then_scalar, result_reg, "async_awaited_value", captured_addend_regs, "async_dynamic_then");
            self.out.writer().print(
                \\    jmp L_ASYNC_DYNAMIC_SINGLE_BRANCH_DONE
                \\L_ASYNC_DYNAMIC_SINGLE_BRANCH_ELSE:
                \\ 
            , .{}) catch return CodegenError.CodegenError;
            try self.emitAsyncContinuationScalarValue(branch.else_scalar, result_reg, "async_awaited_value", captured_addend_regs, "async_dynamic_else");
            self.out.writer().print(
                \\    jmp L_ASYNC_DYNAMIC_SINGLE_BRANCH_DONE
                \\L_ASYNC_DYNAMIC_SINGLE_BRANCH_DONE:
                \\ 
            , .{}) catch return CodegenError.CodegenError;
        } else {
            try self.emitAsyncContinuationScalarValue(scalar, result_reg, "async_awaited_value", captured_addend_regs, "async_dynamic");
        }
        if (plan.branch != null) self.out.writer().print("    !async_branch_cond\n", .{}) catch return CodegenError.CodegenError;
        for (captured_addend_regs) |maybe_addend_reg| {
            if (maybe_addend_reg) |addend_reg| {
                self.out.writer().print("    !{s}\n", .{addend_reg}) catch return CodegenError.CodegenError;
            }
        }
        for (captured_storage_regs) |maybe_storage_reg| {
            if (maybe_storage_reg) |storage_reg| {
                self.out.writer().print("    !{s}\n", .{storage_reg}) catch return CodegenError.CodegenError;
            }
        }
        self.out.writer().print(
            \\    store data_slot+0, 1 as u64
            \\    EXPAND POLL_SET_READY out_poll_slot, {s}
            \\    !{s}
            \\    !async_awaited_value
            \\    !async_inner_ready
            \\    !async_inner_poll
            \\    !async_inner_state
            \\    jmp L_ASYNC_DYNAMIC_SINGLE_DONE
            \\L_ASYNC_DYNAMIC_SINGLE_DONE:
            \\    !async_done
            \\    !async_stage
            \\    return
            \\
        , .{ result_reg, result_reg }) catch return CodegenError.CodegenError;
    }

    fn emitAsyncContinuationScalarValue(self: *Codegen, scalar: lowering_rules.AsyncContinuationScalarPlan, result_reg: []const u8, awaited_reg: []const u8, captured_regs: [2]?[]const u8, prefix: []const u8) CodegenError!void {
        const awaited_abs = std.fmt.allocPrint(self.allocator, "{s}_awaited_abs", .{prefix}) catch return CodegenError.OutOfMemory;
        defer self.allocator.free(awaited_abs);
        const awaited_scaled = std.fmt.allocPrint(self.allocator, "{s}_awaited_scaled", .{prefix}) catch return CodegenError.OutOfMemory;
        defer self.allocator.free(awaited_scaled);
        const captured_abs = std.fmt.allocPrint(self.allocator, "{s}_captured_abs", .{prefix}) catch return CodegenError.OutOfMemory;
        defer self.allocator.free(captured_abs);
        const captured_scaled = std.fmt.allocPrint(self.allocator, "{s}_captured_scaled", .{prefix}) catch return CodegenError.OutOfMemory;
        defer self.allocator.free(captured_scaled);
        const expr_sum = std.fmt.allocPrint(self.allocator, "{s}_expr_sum", .{prefix}) catch return CodegenError.OutOfMemory;
        defer self.allocator.free(expr_sum);
        const captured2_abs = std.fmt.allocPrint(self.allocator, "{s}_captured2_abs", .{prefix}) catch return CodegenError.OutOfMemory;
        defer self.allocator.free(captured2_abs);
        const captured2_scaled = std.fmt.allocPrint(self.allocator, "{s}_captured2_scaled", .{prefix}) catch return CodegenError.OutOfMemory;
        defer self.allocator.free(captured2_scaled);
        const expr_sum2 = std.fmt.allocPrint(self.allocator, "{s}_expr_sum2", .{prefix}) catch return CodegenError.OutOfMemory;
        defer self.allocator.free(expr_sum2);

        var current_reg: ?[]const u8 = null;
        var release_awaited_abs = false;
        var release_awaited_scaled = false;
        var release_captured_abs = false;
        var release_captured_scaled = false;
        var release_expr_sum = false;
        var release_captured2_abs = false;
        var release_captured2_scaled = false;
        var release_expr_sum2 = false;

        if (scalar.awaited_coeff != 0) {
            if (scalar.awaited_coeff == 1) {
                current_reg = awaited_reg;
            } else if (scalar.awaited_coeff == -1) {
                self.out.writer().print("    {s} = sub 0, {s}\n", .{ awaited_scaled, awaited_reg }) catch return CodegenError.CodegenError;
                current_reg = awaited_scaled;
                release_awaited_scaled = true;
            } else {
                const abs_coeff = if (scalar.awaited_coeff < 0) -scalar.awaited_coeff else scalar.awaited_coeff;
                self.out.writer().print("    {s} = mul {s}, {}\n", .{ awaited_abs, awaited_reg, abs_coeff }) catch return CodegenError.CodegenError;
                release_awaited_abs = true;
                if (scalar.awaited_coeff < 0) {
                    self.out.writer().print("    {s} = sub 0, {s}\n", .{ awaited_scaled, awaited_abs }) catch return CodegenError.CodegenError;
                    current_reg = awaited_scaled;
                    release_awaited_scaled = true;
                } else {
                    current_reg = awaited_abs;
                }
            }
        }

        if (scalar.captured_coeff != 0) {
            const addend_reg = captured_regs[0] orelse return CodegenError.CodegenError;
            var captured_term: []const u8 = addend_reg;
            const abs_coeff = if (scalar.captured_coeff < 0) -scalar.captured_coeff else scalar.captured_coeff;
            if (abs_coeff != 1) {
                self.out.writer().print("    {s} = mul {s}, {}\n", .{ captured_abs, addend_reg, abs_coeff }) catch return CodegenError.CodegenError;
                captured_term = captured_abs;
                release_captured_abs = true;
            }
            if (current_reg) |current| {
                const sum_dest = if (scalar.captured2_coeff == 0 and scalar.immediate == 0) result_reg else expr_sum;
                const op: []const u8 = if (scalar.captured_coeff < 0) "sub" else "add";
                self.out.writer().print("    {s} = {s} {s}, {s}\n", .{ sum_dest, op, current, captured_term }) catch return CodegenError.CodegenError;
                current_reg = sum_dest;
                release_expr_sum = scalar.captured2_coeff != 0 or scalar.immediate != 0;
            } else if (scalar.captured_coeff < 0) {
                self.out.writer().print("    {s} = sub 0, {s}\n", .{ captured_scaled, captured_term }) catch return CodegenError.CodegenError;
                current_reg = captured_scaled;
                release_captured_scaled = true;
            } else {
                current_reg = captured_term;
            }
        }

        if (scalar.captured2_coeff != 0) {
            const addend_reg = captured_regs[1] orelse return CodegenError.CodegenError;
            var captured_term: []const u8 = addend_reg;
            const abs_coeff = if (scalar.captured2_coeff < 0) -scalar.captured2_coeff else scalar.captured2_coeff;
            if (abs_coeff != 1) {
                self.out.writer().print("    {s} = mul {s}, {}\n", .{ captured2_abs, addend_reg, abs_coeff }) catch return CodegenError.CodegenError;
                captured_term = captured2_abs;
                release_captured2_abs = true;
            }
            if (current_reg) |current| {
                const sum_dest = if (scalar.immediate == 0) result_reg else expr_sum2;
                const op: []const u8 = if (scalar.captured2_coeff < 0) "sub" else "add";
                self.out.writer().print("    {s} = {s} {s}, {s}\n", .{ sum_dest, op, current, captured_term }) catch return CodegenError.CodegenError;
                current_reg = sum_dest;
                release_expr_sum2 = scalar.immediate != 0;
            } else if (scalar.captured2_coeff < 0) {
                self.out.writer().print("    {s} = sub 0, {s}\n", .{ captured2_scaled, captured_term }) catch return CodegenError.CodegenError;
                current_reg = captured2_scaled;
                release_captured2_scaled = true;
            } else {
                current_reg = captured_term;
            }
        }

        if (scalar.immediate != 0) {
            const current = current_reg orelse "0";
            const imm_abs = if (scalar.immediate < 0) -scalar.immediate else scalar.immediate;
            const op: []const u8 = if (scalar.immediate < 0) "sub" else "add";
            self.out.writer().print("    {s} = {s} {s}, {}\n", .{ result_reg, op, current, imm_abs }) catch return CodegenError.CodegenError;
            current_reg = result_reg;
        }

        const current = current_reg orelse "0";
        if (!std.mem.eql(u8, current, result_reg)) {
            self.out.writer().print("    {s} = add {s}, 0\n", .{ result_reg, current }) catch return CodegenError.CodegenError;
        }
        if (release_expr_sum) self.out.writer().print("    !{s}\n", .{expr_sum}) catch return CodegenError.CodegenError;
        if (release_expr_sum2) self.out.writer().print("    !{s}\n", .{expr_sum2}) catch return CodegenError.CodegenError;
        if (release_captured2_scaled) self.out.writer().print("    !{s}\n", .{captured2_scaled}) catch return CodegenError.CodegenError;
        if (release_captured2_abs) self.out.writer().print("    !{s}\n", .{captured2_abs}) catch return CodegenError.CodegenError;
        if (release_captured_scaled) self.out.writer().print("    !{s}\n", .{captured_scaled}) catch return CodegenError.CodegenError;
        if (release_captured_abs) self.out.writer().print("    !{s}\n", .{captured_abs}) catch return CodegenError.CodegenError;
        if (release_awaited_scaled) self.out.writer().print("    !{s}\n", .{awaited_scaled}) catch return CodegenError.CodegenError;
        if (release_awaited_abs) self.out.writer().print("    !{s}\n", .{awaited_abs}) catch return CodegenError.CodegenError;
    }

    fn emitAsyncSingleAwaitPollHelper(self: *Codegen, name: []const u8, plan: lowering_rules.AsyncSingleAwaitContinuationPlan) CodegenError!void {
        if (plan.dynamic_poll) return try self.emitAsyncSingleAwaitPollHelperDynamic(name, plan);
        const vt_name = try self.asyncSingleAwaitVTableName(name);
        const poll_name = try self.asyncSingleAwaitPollName(name);
        self.out.writer().print(
            \\@const {s} = vtable {{ poll = @{s} }}
            \\@{s}(&data_slot: ptr, &ctx_slot: ptr, &out_poll_slot: ptr):
            \\L_ENTRY:
            \\    async_stage = load data_slot+0 as u64
            \\    async_done = eq async_stage, 1
            \\    br async_done -> L_ASYNC_SINGLE_AWAIT_EMPTY, L_ASYNC_SINGLE_AWAIT_POLL
            \\L_ASYNC_SINGLE_AWAIT_EMPTY:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    jmp L_ASYNC_SINGLE_AWAIT_DONE
            \\L_ASYNC_SINGLE_AWAIT_POLL:
            \\    async_inner_state = load data_slot+8 as ptr
            \\    async_inner_stage = load async_inner_state+0 as u64
            \\    async_inner_initial = eq async_inner_stage, 0
            \\    br async_inner_initial -> L_ASYNC_SINGLE_AWAIT_PENDING, L_ASYNC_SINGLE_AWAIT_CHECK_READY
            \\L_ASYNC_SINGLE_AWAIT_PENDING:
            \\    store async_inner_state+0, 1 as u64
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    jmp L_ASYNC_SINGLE_AWAIT_CLEAN
            \\L_ASYNC_SINGLE_AWAIT_CHECK_READY:
            \\    async_inner_ready = eq async_inner_stage, 1
            \\    br async_inner_ready -> L_ASYNC_SINGLE_AWAIT_READY, L_ASYNC_SINGLE_AWAIT_INNER_EMPTY
            \\L_ASYNC_SINGLE_AWAIT_INNER_EMPTY:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    !async_inner_ready
            \\    jmp L_ASYNC_SINGLE_AWAIT_CLEAN
            \\L_ASYNC_SINGLE_AWAIT_READY:
            \\    {s} = load async_inner_state+8 as u64
            \\
        , .{ vt_name, poll_name, poll_name, plan.binding_name }) catch return CodegenError.CodegenError;
        var captured_addend_regs: [2]?[]const u8 = .{ null, null };
        var captured_storage_regs: [2]?[]const u8 = .{ null, null };
        const scalar = plan.scalar;
        for (0..plan.capture_count) |capture_idx| {
            const capture = plan.captures[capture_idx] orelse return CodegenError.CodegenError;
            const reg_name: []const u8 = if (capture_idx == 0) "async_captured_addend" else "async_captured_addend2";
            switch (capture.storage) {
                .scalar => {
                    self.out.writer().print("    {s} = load data_slot+{} as u64\n", .{ reg_name, capture.offset }) catch return CodegenError.CodegenError;
                    captured_addend_regs[capture_idx] = reg_name;
                },
                .copy_struct => {
                    if (plan.branch != null) return CodegenError.CodegenError;
                    const field_name = if (capture_idx == 0) scalar.captured_field_name else scalar.captured2_field_name;
                    const field = field_name orelse return CodegenError.CodegenError;
                    const capture_ty = self.tc.expr_types.get(capture.expr) orelse return CodegenError.CodegenError;
                    if (!self.typeIsCopyStruct(capture_ty)) return CodegenError.CodegenError;
                    const layout = self.aggregateFieldLayout(capture_ty, field) orelse return CodegenError.CodegenError;
                    const ptr_reg: []const u8 = if (capture_idx == 0) "async_captured_struct" else "async_captured_struct2";
                    self.out.writer().print("    {s} = load data_slot+{} as ptr\n", .{ ptr_reg, capture.offset }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ reg_name, ptr_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
                    captured_addend_regs[capture_idx] = reg_name;
                    captured_storage_regs[capture_idx] = ptr_reg;
                },
            }
        }
        const result_reg = if (plan.branch != null) "async_result" else plan.resultBindingName() orelse if (scalar.isIdentity()) plan.binding_name else "async_result";
        if (plan.branch) |branch| {
            const condition_op = asyncContinuationConditionOpName(branch.condition_op) orelse return CodegenError.CodegenError;
            self.out.writer().print(
                \\    async_branch_cond = {s} {s}, {}
                \\    br async_branch_cond -> L_ASYNC_SINGLE_AWAIT_BRANCH_THEN, L_ASYNC_SINGLE_AWAIT_BRANCH_ELSE
                \\L_ASYNC_SINGLE_AWAIT_BRANCH_THEN:
                \\
            , .{ condition_op, plan.binding_name, branch.threshold }) catch return CodegenError.CodegenError;
            try self.emitAsyncContinuationScalarValue(branch.then_scalar, result_reg, plan.binding_name, captured_addend_regs, "async_then");
            self.out.writer().print(
                \\    jmp L_ASYNC_SINGLE_AWAIT_BRANCH_DONE
                \\L_ASYNC_SINGLE_AWAIT_BRANCH_ELSE:
                \\
            , .{}) catch return CodegenError.CodegenError;
            try self.emitAsyncContinuationScalarValue(branch.else_scalar, result_reg, plan.binding_name, captured_addend_regs, "async_else");
            self.out.writer().print(
                \\    jmp L_ASYNC_SINGLE_AWAIT_BRANCH_DONE
                \\L_ASYNC_SINGLE_AWAIT_BRANCH_DONE:
                \\
            , .{}) catch return CodegenError.CodegenError;
        } else {
            try self.emitAsyncContinuationScalarValue(scalar, result_reg, plan.binding_name, captured_addend_regs, "async");
        }
        self.out.writer().print(
            \\    store async_inner_state+0, 2 as u64
            \\    store data_slot+0, 1 as u64
            \\    EXPAND POLL_SET_READY out_poll_slot, {s}
            \\
        , .{result_reg}) catch return CodegenError.CodegenError;
        if (!std.mem.eql(u8, result_reg, plan.binding_name)) {
            self.out.writer().print("    !{s}\n", .{result_reg}) catch return CodegenError.CodegenError;
        }
        if (plan.branch != null) self.out.writer().print("    !async_branch_cond\n", .{}) catch return CodegenError.CodegenError;
        for (captured_addend_regs) |maybe_addend_reg| {
            if (maybe_addend_reg) |addend_reg| {
                self.out.writer().print("    !{s}\n", .{addend_reg}) catch return CodegenError.CodegenError;
            }
        }
        for (captured_storage_regs) |maybe_storage_reg| {
            if (maybe_storage_reg) |storage_reg| {
                self.out.writer().print("    !{s}\n", .{storage_reg}) catch return CodegenError.CodegenError;
            }
        }
        self.out.writer().print(
            \\    !{s}
            \\    !async_inner_ready
            \\L_ASYNC_SINGLE_AWAIT_CLEAN:
            \\    !async_inner_initial
            \\    !async_inner_stage
            \\    !async_inner_state
            \\L_ASYNC_SINGLE_AWAIT_DONE:
            \\    !async_done
            \\    !async_stage
            \\    return
            \\
        , .{plan.binding_name}) catch return CodegenError.CodegenError;
    }

    fn emitAsyncTwoAwaitPollHelperDynamic(self: *Codegen, name: []const u8, plan: lowering_rules.AsyncTwoAwaitContinuationPlan) CodegenError!void {
        if (plan.second_depends_on_first) return try self.emitAsyncTwoAwaitPollHelperDependent(name, plan);
        const vt_name = try self.asyncTwoAwaitVTableName(name);
        const poll_name = try self.asyncTwoAwaitPollName(name);
        self.out.writer().print(
            \\@const {s} = vtable {{ poll = @{s} }}
            \\@{s}(&data_slot: ptr, &ctx_slot: ptr, &out_poll_slot: ptr):
            \\L_ENTRY:
            \\    async_stage = load data_slot+0 as u64
            \\    async_poll_first = eq async_stage, 0
            \\    async_done = eq async_stage, 2
            \\    br async_done -> L_ASYNC_DYNAMIC_TWO_EMPTY, L_ASYNC_DYNAMIC_TWO_DISPATCH
            \\L_ASYNC_DYNAMIC_TWO_EMPTY:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    jmp L_ASYNC_DYNAMIC_TWO_DONE
            \\L_ASYNC_DYNAMIC_TWO_DISPATCH:
            \\    br async_poll_first -> L_ASYNC_DYNAMIC_TWO_FIRST, L_ASYNC_DYNAMIC_TWO_SECOND
            \\L_ASYNC_DYNAMIC_TWO_FIRST:
            \\    async_first_state = load data_slot+8 as ptr
            \\    EXPAND FUTURE_POLL_STATE async_first_poll, async_first_state, ctx_slot
            \\    EXPAND POLL_IS_READY async_first_ready, async_first_poll
            \\    br async_first_ready -> L_ASYNC_DYNAMIC_TWO_FIRST_READY, L_ASYNC_DYNAMIC_TWO_FIRST_PENDING
            \\L_ASYNC_DYNAMIC_TWO_FIRST_PENDING:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    !async_first_ready
            \\    !async_first_poll
            \\    !async_first_state
            \\    jmp L_ASYNC_DYNAMIC_TWO_DONE
            \\L_ASYNC_DYNAMIC_TWO_FIRST_READY:
            \\    EXPAND POLL_VALUE async_first_value, async_first_poll
            \\    store data_slot+24, async_first_value as u64
            \\    store data_slot+0, 1 as u64
            \\    !async_first_value
            \\    !async_first_ready
            \\    !async_first_poll
            \\    !async_first_state
            \\    jmp L_ASYNC_DYNAMIC_TWO_SECOND
            \\L_ASYNC_DYNAMIC_TWO_SECOND:
            \\    async_second_state = load data_slot+16 as ptr
            \\    EXPAND FUTURE_POLL_STATE async_second_poll, async_second_state, ctx_slot
            \\    EXPAND POLL_IS_READY async_second_ready, async_second_poll
            \\    br async_second_ready -> L_ASYNC_DYNAMIC_TWO_SECOND_READY, L_ASYNC_DYNAMIC_TWO_SECOND_PENDING
            \\L_ASYNC_DYNAMIC_TWO_SECOND_PENDING:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    !async_second_ready
            \\    !async_second_poll
            \\    !async_second_state
            \\    jmp L_ASYNC_DYNAMIC_TWO_DONE
            \\L_ASYNC_DYNAMIC_TWO_SECOND_READY:
            \\    EXPAND POLL_VALUE async_second_value, async_second_poll
            \\    async_first_value = load data_slot+24 as u64
            \\
        , .{ vt_name, poll_name, poll_name }) catch return CodegenError.CodegenError;
        const scalar = lowering_rules.AsyncContinuationScalarPlan{
            .awaited_coeff = plan.scalar.second_coeff,
            .captured_coeff = plan.scalar.first_coeff,
            .immediate = plan.scalar.immediate,
        };
        try self.emitAsyncContinuationScalarValue(scalar, "async_two_result", "async_second_value", .{ "async_first_value", null }, "async_dynamic_two");
        self.out.writer().print(
            \\    store data_slot+0, 2 as u64
            \\    EXPAND POLL_SET_READY out_poll_slot, async_two_result
            \\    !async_two_result
            \\    !async_second_value
            \\    !async_first_value
            \\    !async_second_ready
            \\    !async_second_poll
            \\    !async_second_state
            \\L_ASYNC_DYNAMIC_TWO_DONE:
            \\    !async_poll_first
            \\    !async_done
            \\    !async_stage
            \\    return
            \\
        , .{}) catch return CodegenError.CodegenError;
    }

    fn emitAsyncTwoAwaitPollHelperDependent(self: *Codegen, name: []const u8, plan: lowering_rules.AsyncTwoAwaitContinuationPlan) CodegenError!void {
        const vt_name = try self.asyncTwoAwaitVTableName(name);
        const poll_name = try self.asyncTwoAwaitPollName(name);
        self.out.writer().print(
            \\@const {s} = vtable {{ poll = @{s} }}
            \\@{s}(&data_slot: ptr, &ctx_slot: ptr, &out_poll_slot: ptr):
            \\L_ENTRY:
            \\    async_stage = load data_slot+0 as u64
            \\    async_poll_first = eq async_stage, 0
            \\    async_done = eq async_stage, 2
            \\    br async_done -> L_ASYNC_DEP_TWO_EMPTY, L_ASYNC_DEP_TWO_DISPATCH
            \\L_ASYNC_DEP_TWO_EMPTY:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    jmp L_ASYNC_DEP_TWO_DONE
            \\L_ASYNC_DEP_TWO_DISPATCH:
            \\    br async_poll_first -> L_ASYNC_DEP_TWO_FIRST, L_ASYNC_DEP_TWO_SECOND
            \\L_ASYNC_DEP_TWO_FIRST:
            \\    async_first_state = load data_slot+8 as ptr
            \\    EXPAND FUTURE_POLL_STATE async_first_poll, async_first_state, ctx_slot
            \\    EXPAND POLL_IS_READY async_first_ready, async_first_poll
            \\    br async_first_ready -> L_ASYNC_DEP_TWO_FIRST_READY, L_ASYNC_DEP_TWO_FIRST_PENDING
            \\L_ASYNC_DEP_TWO_FIRST_PENDING:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    !async_first_ready
            \\    !async_first_poll
            \\    !async_first_state
            \\    jmp L_ASYNC_DEP_TWO_DONE
            \\L_ASYNC_DEP_TWO_FIRST_READY:
            \\    EXPAND POLL_VALUE async_first_value, async_first_poll
            \\    store data_slot+24, async_first_value as u64
            \\    !async_first_ready
            \\    !async_first_poll
            \\    !async_first_state
            \\
        , .{ vt_name, poll_name, poll_name }) catch return CodegenError.CodegenError;

        const second_state = try self.genAsyncSecondAwaitState(plan, "async_first_value");
        self.out.writer().print(
            \\    store data_slot+16, {s} as ptr
            \\    !{s}
            \\    !async_first_value
            \\    store data_slot+0, 1 as u64
            \\    jmp L_ASYNC_DEP_TWO_SECOND
            \\L_ASYNC_DEP_TWO_SECOND:
            \\    async_second_state = load data_slot+16 as ptr
            \\    EXPAND FUTURE_POLL_STATE async_second_poll, async_second_state, ctx_slot
            \\    EXPAND POLL_IS_READY async_second_ready, async_second_poll
            \\    br async_second_ready -> L_ASYNC_DEP_TWO_SECOND_READY, L_ASYNC_DEP_TWO_SECOND_PENDING
            \\L_ASYNC_DEP_TWO_SECOND_PENDING:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    !async_second_ready
            \\    !async_second_poll
            \\    !async_second_state
            \\    jmp L_ASYNC_DEP_TWO_DONE
            \\L_ASYNC_DEP_TWO_SECOND_READY:
            \\    EXPAND POLL_VALUE async_second_value, async_second_poll
            \\    async_first_value = load data_slot+24 as u64
            \\
        , .{ second_state, second_state }) catch return CodegenError.CodegenError;
        const scalar = lowering_rules.AsyncContinuationScalarPlan{
            .awaited_coeff = plan.scalar.second_coeff,
            .captured_coeff = plan.scalar.first_coeff,
            .immediate = plan.scalar.immediate,
        };
        try self.emitAsyncContinuationScalarValue(scalar, "async_two_result", "async_second_value", .{ "async_first_value", null }, "async_dependent_two");
        self.out.writer().print(
            \\    store data_slot+0, 2 as u64
            \\    EXPAND POLL_SET_READY out_poll_slot, async_two_result
            \\    !async_two_result
            \\    !async_second_value
            \\    !async_first_value
            \\    !async_second_ready
            \\    !async_second_poll
            \\    !async_second_state
            \\L_ASYNC_DEP_TWO_DONE:
            \\    !async_poll_first
            \\    !async_done
            \\    !async_stage
            \\    return
            \\
        , .{}) catch return CodegenError.CodegenError;
    }

    fn emitAsyncTwoAwaitPollHelper(self: *Codegen, name: []const u8, plan: lowering_rules.AsyncTwoAwaitContinuationPlan) CodegenError!void {
        if (plan.second_depends_on_first) return try self.emitAsyncTwoAwaitPollHelperDependent(name, plan);
        if (plan.first_dynamic_poll or plan.second_dynamic_poll) return try self.emitAsyncTwoAwaitPollHelperDynamic(name, plan);
        const vt_name = try self.asyncTwoAwaitVTableName(name);
        const poll_name = try self.asyncTwoAwaitPollName(name);
        self.out.writer().print(
            \\@const {s} = vtable {{ poll = @{s} }}
            \\@{s}(&data_slot: ptr, &ctx_slot: ptr, &out_poll_slot: ptr):
            \\L_ENTRY:
            \\    async_stage = load data_slot+0 as u64
            \\    async_poll_first = eq async_stage, 0
            \\    async_done = eq async_stage, 2
            \\    br async_done -> L_ASYNC_TWO_AWAIT_EMPTY, L_ASYNC_TWO_AWAIT_DISPATCH
            \\L_ASYNC_TWO_AWAIT_EMPTY:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    jmp L_ASYNC_TWO_AWAIT_DONE
            \\L_ASYNC_TWO_AWAIT_DISPATCH:
            \\    br async_poll_first -> L_ASYNC_TWO_AWAIT_FIRST, L_ASYNC_TWO_AWAIT_SECOND
            \\L_ASYNC_TWO_AWAIT_FIRST:
            \\    async_first_state = load data_slot+8 as ptr
            \\    async_first_stage = load async_first_state+0 as u64
            \\    async_first_initial = eq async_first_stage, 0
            \\    br async_first_initial -> L_ASYNC_TWO_AWAIT_FIRST_PENDING, L_ASYNC_TWO_AWAIT_FIRST_CHECK_READY
            \\L_ASYNC_TWO_AWAIT_FIRST_PENDING:
            \\    store async_first_state+0, 1 as u64
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    jmp L_ASYNC_TWO_AWAIT_FIRST_CLEAN
            \\L_ASYNC_TWO_AWAIT_FIRST_CHECK_READY:
            \\    async_first_ready = eq async_first_stage, 1
            \\    br async_first_ready -> L_ASYNC_TWO_AWAIT_FIRST_READY, L_ASYNC_TWO_AWAIT_FIRST_EMPTY
            \\L_ASYNC_TWO_AWAIT_FIRST_EMPTY:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    !async_first_ready
            \\    jmp L_ASYNC_TWO_AWAIT_FIRST_CLEAN
            \\L_ASYNC_TWO_AWAIT_FIRST_READY:
            \\    {s} = load async_first_state+8 as u64
            \\    store data_slot+24, {s} as u64
            \\    store async_first_state+0, 2 as u64
            \\    store data_slot+0, 1 as u64
            \\    !{s}
            \\    !async_first_ready
            \\    !async_first_initial
            \\    !async_first_stage
            \\    !async_first_state
            \\    jmp L_ASYNC_TWO_AWAIT_SECOND
            \\L_ASYNC_TWO_AWAIT_FIRST_CLEAN:
            \\    !async_first_initial
            \\    !async_first_stage
            \\    !async_first_state
            \\    jmp L_ASYNC_TWO_AWAIT_DONE
            \\L_ASYNC_TWO_AWAIT_SECOND:
            \\    async_second_state = load data_slot+16 as ptr
            \\    async_second_stage = load async_second_state+0 as u64
            \\    async_second_initial = eq async_second_stage, 0
            \\    br async_second_initial -> L_ASYNC_TWO_AWAIT_SECOND_PENDING, L_ASYNC_TWO_AWAIT_SECOND_CHECK_READY
            \\L_ASYNC_TWO_AWAIT_SECOND_PENDING:
            \\    store async_second_state+0, 1 as u64
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    jmp L_ASYNC_TWO_AWAIT_SECOND_CLEAN
            \\L_ASYNC_TWO_AWAIT_SECOND_CHECK_READY:
            \\    async_second_ready = eq async_second_stage, 1
            \\    br async_second_ready -> L_ASYNC_TWO_AWAIT_SECOND_READY, L_ASYNC_TWO_AWAIT_SECOND_EMPTY
            \\L_ASYNC_TWO_AWAIT_SECOND_EMPTY:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    !async_second_ready
            \\    jmp L_ASYNC_TWO_AWAIT_SECOND_CLEAN
            \\L_ASYNC_TWO_AWAIT_SECOND_READY:
            \\    {s} = load data_slot+24 as u64
            \\    {s} = load async_second_state+8 as u64
            \\
        , .{ vt_name, poll_name, poll_name, plan.first_binding_name, plan.first_binding_name, plan.first_binding_name, plan.first_binding_name, plan.second_binding_name }) catch return CodegenError.CodegenError;
        const scalar = lowering_rules.AsyncContinuationScalarPlan{
            .awaited_coeff = plan.scalar.second_coeff,
            .captured_coeff = plan.scalar.first_coeff,
            .immediate = plan.scalar.immediate,
        };
        try self.emitAsyncContinuationScalarValue(scalar, "async_two_result", plan.second_binding_name, .{ plan.first_binding_name, null }, "async_two");
        self.out.writer().print(
            \\    store async_second_state+0, 2 as u64
            \\    store data_slot+0, 2 as u64
            \\    EXPAND POLL_SET_READY out_poll_slot, async_two_result
            \\    !async_two_result
            \\    !{s}
            \\    !{s}
            \\    !async_second_ready
            \\L_ASYNC_TWO_AWAIT_SECOND_CLEAN:
            \\    !async_second_initial
            \\    !async_second_stage
            \\    !async_second_state
            \\L_ASYNC_TWO_AWAIT_DONE:
            \\    !async_poll_first
            \\    !async_done
            \\    !async_stage
            \\    return
            \\
        , .{ plan.second_binding_name, plan.first_binding_name }) catch return CodegenError.CodegenError;
    }

    fn emitAsyncJoin2AwaitPollHelper(self: *Codegen, name: []const u8, plan: lowering_rules.AsyncJoin2AwaitContinuationPlan) CodegenError!void {
        const vt_name = try self.asyncJoin2AwaitVTableName(name);
        const poll_name = try self.asyncJoin2AwaitPollName(name);
        self.out.writer().print(
            \\@const {s} = vtable {{ poll = @{s} }}
            \\@{s}(&data_slot: ptr, &ctx_slot: ptr, &out_poll_slot: ptr):
            \\L_ENTRY:
            \\    async_stage = load data_slot+0 as u64
            \\    async_done = eq async_stage, 1
            \\    br async_done -> L_ASYNC_JOIN2_AWAIT_EMPTY, L_ASYNC_JOIN2_AWAIT_POLL
            \\L_ASYNC_JOIN2_AWAIT_EMPTY:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    jmp L_ASYNC_JOIN2_AWAIT_DONE
            \\L_ASYNC_JOIN2_AWAIT_POLL:
            \\    async_join_state = load data_slot+8 as ptr
            \\    async_join_vt = &SLA_JOIN2_FUTURE_VT
            \\    EXPAND FUTURE_NEW async_join_future, async_join_state, async_join_vt
            \\    async_join_ctx = 0
            \\    EXPAND FUTURE_POLL async_join_poll, async_join_future, async_join_ctx
            \\    EXPAND POLL_IS_READY async_join_ready, async_join_poll
            \\    br async_join_ready -> L_ASYNC_JOIN2_AWAIT_READY, L_ASYNC_JOIN2_AWAIT_PENDING
            \\L_ASYNC_JOIN2_AWAIT_PENDING:
            \\    EXPAND POLL_SET_PENDING out_poll_slot
            \\    jmp L_ASYNC_JOIN2_AWAIT_CLEAN
            \\L_ASYNC_JOIN2_AWAIT_READY:
            \\    {s} = load async_join_poll+8 as ptr
            \\    async_pair_left = 0
            \\    async_pair_right = 0
            \\    EXPAND FUTURE_PAIR_LEFT async_pair_left, {s}
            \\    EXPAND FUTURE_PAIR_RIGHT async_pair_right, {s}
            \\
        , .{ vt_name, poll_name, poll_name, plan.binding_name, plan.binding_name, plan.binding_name }) catch return CodegenError.CodegenError;
        const scalar = lowering_rules.AsyncContinuationScalarPlan{
            .awaited_coeff = plan.scalar.right_coeff,
            .captured_coeff = plan.scalar.left_coeff,
            .immediate = plan.scalar.immediate,
        };
        try self.emitAsyncContinuationScalarValue(scalar, "async_join_result", "async_pair_right", .{ "async_pair_left", null }, "async_join");
        self.out.writer().print(
            \\    store data_slot+0, 1 as u64
            \\    EXPAND POLL_SET_READY out_poll_slot, async_join_result
            \\    !async_join_result
            \\    !async_pair_right
            \\    !async_pair_left
            \\    !{s}
            \\L_ASYNC_JOIN2_AWAIT_CLEAN:
            \\    !async_join_ready
            \\    !async_join_poll
            \\    !async_join_ctx
            \\    !async_join_future
            \\    !async_join_vt
            \\    !async_join_state
            \\L_ASYNC_JOIN2_AWAIT_DONE:
            \\    !async_done
            \\    !async_stage
            \\    return
            \\
        , .{plan.binding_name}) catch return CodegenError.CodegenError;
    }

    fn genAsyncSingleAwaitFuncDeclNamed(self: *Codegen, name: []const u8, f: *const ast.FuncDecl, plan: lowering_rules.AsyncSingleAwaitContinuationPlan) CodegenError!void {
        try self.emitAsyncSingleAwaitPollHelper(name, plan);

        const lowered_name = try self.loweredFuncSymbol(name);
        defer self.allocator.free(lowered_name);
        self.out.writer().print("@{s}(", .{lowered_name}) catch return CodegenError.CodegenError;
        for (f.params, 0..) |p, i| {
            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
            const prefix: []const u8 = self.abiParamPrefix(p);
            self.out.writer().print("{s}{s}: {s}", .{ prefix, p.name, abiParamTypeString(p) }) catch return CodegenError.CodegenError;
        }
        const async_return_plan = lowering_rules.planAsyncFunctionReturn(f.*, try self.makeAbiPtrType());
        const ret_type_str = abiReturnTypeString(async_return_plan.abi_ret_ty);
        self.out.writer().print(") -> {s}:\n", .{ret_type_str}) catch return CodegenError.CodegenError;
        self.out.writer().print("L_ENTRY:\n", .{}) catch return CodegenError.CodegenError;

        var hoisted_allocs = std.ArrayList([]const u8).init(self.allocator);
        defer hoisted_allocs.deinit();
        try self.collectHoistedAllocs(f.body, &hoisted_allocs);
        var captured_addends: [2]?[]const u8 = .{ null, null };
        for (0..plan.capture_count) |capture_idx| {
            const capture = plan.captures[capture_idx] orelse return CodegenError.CodegenError;
            const capture_reg = try self.genExpr(@constCast(capture.expr), &hoisted_allocs);
            captured_addends[capture_idx] = switch (capture.storage) {
                .scalar => capture_reg,
                .copy_struct => blk: {
                    const capture_ty = self.tc.expr_types.get(capture.expr) orelse return CodegenError.CodegenError;
                    if (!self.typeIsCopyStruct(capture_ty)) return CodegenError.CodegenError;
                    if (capture.expr.* == .identifier) {
                        const copied = try self.newTmp();
                        try self.genCopyValueInto(copied, capture_reg, capture_ty);
                        break :blk copied;
                    }
                    break :blk capture_reg;
                },
            };
        }
        const inner_state = try self.genExpr(@constCast(plan.await_expr), &hoisted_allocs);
        const async_state = try self.newTmp();
        self.out.writer().print("    {s} = alloc FutureState_SIZE\n", .{async_state}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as u64\n", .{async_state}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+8, {s} as ptr\n", .{ async_state, inner_state }) catch return CodegenError.CodegenError;
        for (0..plan.capture_count) |capture_idx| {
            const capture = plan.captures[capture_idx] orelse return CodegenError.CodegenError;
            const addend_reg = captured_addends[capture_idx] orelse return CodegenError.CodegenError;
            const store_ty: []const u8 = switch (capture.storage) {
                .scalar => "u64",
                .copy_struct => "ptr",
            };
            self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ async_state, capture.offset, addend_reg, store_ty }) catch return CodegenError.CodegenError;
            if (capture.storage == .scalar) try self.emitRelease(addend_reg);
        }
        try self.emitRelease(inner_state);
        for (f.params) |param| try self.emitRelease(param.name);
        const async_vtable = try self.asyncSingleAwaitVTableName(name);
        try self.emitFutureStateVTable(async_state, async_vtable);
        try self.future_state_vtables.put(async_state, async_vtable);
        try self.recordFutureReadiness(async_state, .unknown);
        self.out.writer().print("    return {s}\n\n", .{async_state}) catch return CodegenError.CodegenError;
    }

    fn genAsyncTwoAwaitFuncDeclNamed(self: *Codegen, name: []const u8, f: *const ast.FuncDecl, plan: lowering_rules.AsyncTwoAwaitContinuationPlan) CodegenError!void {
        try self.emitAsyncTwoAwaitPollHelper(name, plan);

        const lowered_name = try self.loweredFuncSymbol(name);
        defer self.allocator.free(lowered_name);
        self.out.writer().print("@{s}(", .{lowered_name}) catch return CodegenError.CodegenError;
        for (f.params, 0..) |p, i| {
            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
            const prefix: []const u8 = self.abiParamPrefix(p);
            self.out.writer().print("{s}{s}: {s}", .{ prefix, p.name, abiParamTypeString(p) }) catch return CodegenError.CodegenError;
        }
        const async_return_plan = lowering_rules.planAsyncFunctionReturn(f.*, try self.makeAbiPtrType());
        const ret_type_str = abiReturnTypeString(async_return_plan.abi_ret_ty);
        self.out.writer().print(") -> {s}:\n", .{ret_type_str}) catch return CodegenError.CodegenError;
        self.out.writer().print("L_ENTRY:\n", .{}) catch return CodegenError.CodegenError;

        var hoisted_allocs = std.ArrayList([]const u8).init(self.allocator);
        defer hoisted_allocs.deinit();
        try self.collectHoistedAllocs(f.body, &hoisted_allocs);
        const first_state = try self.genExpr(@constCast(plan.first_await_expr), &hoisted_allocs);
        const async_state = try self.newTmp();
        self.out.writer().print("    {s} = alloc FutureState_SIZE\n", .{async_state}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as u64\n", .{async_state}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+8, {s} as ptr\n", .{ async_state, first_state }) catch return CodegenError.CodegenError;
        if (plan.second_depends_on_first) {
            self.out.writer().print("    store {s}+16, 0 as ptr\n", .{async_state}) catch return CodegenError.CodegenError;
        } else {
            const second_state = try self.genExpr(@constCast(plan.second_await_expr), &hoisted_allocs);
            self.out.writer().print("    store {s}+16, {s} as ptr\n", .{ async_state, second_state }) catch return CodegenError.CodegenError;
            try self.emitRelease(second_state);
        }
        self.out.writer().print("    store {s}+24, 0 as u64\n", .{async_state}) catch return CodegenError.CodegenError;
        try self.emitRelease(first_state);
        for (f.params) |param| try self.emitRelease(param.name);
        const async_vtable = try self.asyncTwoAwaitVTableName(name);
        try self.emitFutureStateVTable(async_state, async_vtable);
        try self.future_state_vtables.put(async_state, async_vtable);
        try self.recordFutureReadiness(async_state, .unknown);
        self.out.writer().print("    return {s}\n\n", .{async_state}) catch return CodegenError.CodegenError;
    }

    fn genAsyncJoin2AwaitFuncDeclNamed(self: *Codegen, name: []const u8, f: *const ast.FuncDecl, plan: lowering_rules.AsyncJoin2AwaitContinuationPlan) CodegenError!void {
        try self.emitAsyncJoin2AwaitPollHelper(name, plan);

        const lowered_name = try self.loweredFuncSymbol(name);
        defer self.allocator.free(lowered_name);
        self.out.writer().print("@{s}(", .{lowered_name}) catch return CodegenError.CodegenError;
        for (f.params, 0..) |p, i| {
            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
            const prefix: []const u8 = self.abiParamPrefix(p);
            self.out.writer().print("{s}{s}: {s}", .{ prefix, p.name, abiParamTypeString(p) }) catch return CodegenError.CodegenError;
        }
        const async_return_plan = lowering_rules.planAsyncFunctionReturn(f.*, try self.makeAbiPtrType());
        const ret_type_str = abiReturnTypeString(async_return_plan.abi_ret_ty);
        self.out.writer().print(") -> {s}:\n", .{ret_type_str}) catch return CodegenError.CodegenError;
        self.out.writer().print("L_ENTRY:\n", .{}) catch return CodegenError.CodegenError;

        var hoisted_allocs = std.ArrayList([]const u8).init(self.allocator);
        defer hoisted_allocs.deinit();
        try self.collectHoistedAllocs(f.body, &hoisted_allocs);
        const join_state = try self.genExpr(@constCast(plan.await_expr), &hoisted_allocs);
        const async_state = try self.newTmp();
        self.out.writer().print("    {s} = alloc FutureState_SIZE\n", .{async_state}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as u64\n", .{async_state}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+8, {s} as ptr\n", .{ async_state, join_state }) catch return CodegenError.CodegenError;
        try self.emitRelease(join_state);
        for (f.params) |param| try self.emitRelease(param.name);
        const async_vtable = try self.asyncJoin2AwaitVTableName(name);
        try self.emitFutureStateVTable(async_state, async_vtable);
        try self.future_state_vtables.put(async_state, async_vtable);
        try self.recordFutureReadiness(async_state, .unknown);
        self.out.writer().print("    return {s}\n\n", .{async_state}) catch return CodegenError.CodegenError;
    }

    fn genReadyPoll(self: *Codegen, value_reg: []const u8) CodegenError![]const u8 {
        const poll_reg = try self.newTmp();
        self.out.writer().print("    EXPAND POLL_READY {s}, {s}\n", .{ poll_reg, value_reg }) catch return CodegenError.CodegenError;
        return poll_reg;
    }

    fn genPendingPoll(self: *Codegen) CodegenError![]const u8 {
        const poll_reg = try self.newTmp();
        self.out.writer().print("    EXPAND POLL_PENDING {s}\n", .{poll_reg}) catch return CodegenError.CodegenError;
        return poll_reg;
    }

    fn genPollRuntimeCall(self: *Codegen, call: ast.CallExpr, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!?[]const u8 {
        const plan = lowering_rules.planPollRuntimeCall(call) orelse return null;
        if (plan.isReady()) {
            if (call.args.len != 1 or call.generics.len != 0) return CodegenError.CodegenError;
            const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const poll_reg = try self.genReadyPoll(value_reg);
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
            return poll_reg;
        }
        if (plan.isPending()) {
            if (call.args.len != 0 or call.generics.len != 1) return CodegenError.CodegenError;
            return try self.genPendingPoll();
        }
        if (plan.isStatusCheck()) {
            if (call.args.len != 1 or call.generics.len != 0) return CodegenError.CodegenError;
            const poll_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const out_reg = try self.newTmp();
            const macro_name = plan.pollStatusMacroName() orelse return CodegenError.CodegenError;
            self.out.writer().print("    EXPAND {s} {s}, {s}\n", .{ macro_name, out_reg, poll_reg }) catch return CodegenError.CodegenError;
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(poll_reg);
            return out_reg;
        }
        if (plan.isValue()) {
            if (call.args.len != 1 or call.generics.len != 0) return CodegenError.CodegenError;
            const poll_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const value_reg = try self.newTmp();
            self.out.writer().print("    EXPAND POLL_VALUE {s}, {s}\n", .{ value_reg, poll_reg }) catch return CodegenError.CodegenError;
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(poll_reg);
            return value_reg;
        }
        return CodegenError.CodegenError;
    }

    fn genExecutorRuntimeCall(self: *Codegen, call: ast.CallExpr, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!?[]const u8 {
        const plan = lowering_rules.planExecutorRuntimeCall(call) orelse return null;
        if (plan.isNew()) {
            if (call.args.len != 1 or call.generics.len != 0) return CodegenError.CodegenError;
            const tasks_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
            const tasks_plan = lowering_rules.executorTaskBufferPlan(tasks_ty) orelse return CodegenError.CodegenError;
            const tasks_owner_reg = try self.genExpr(call.args[0], hoisted_allocs);
            var tasks_ptr_reg: []const u8 = tasks_owner_reg;
            var release_tasks_ptr = false;
            const len_reg = try self.newTmp();
            const executor_reg = try self.newTmp();
            if (tasks_plan.isFixedArray()) {
                try self.emitIntConst(len_reg, @as(i64, @intCast(tasks_plan.fixed_len.?)));
                self.executor_task_counts.put(executor_reg, tasks_plan.fixed_len.?) catch return CodegenError.OutOfMemory;
            } else if (tasks_plan.isVec()) {
                tasks_ptr_reg = try self.newTmp();
                release_tasks_ptr = true;
                self.out.writer().print("    EXPAND VEC_AS_PTR {s}, {s}\n", .{ tasks_ptr_reg, tasks_owner_reg }) catch return CodegenError.CodegenError;
                self.out.writer().print("    EXPAND VEC_LEN {s}, {s}\n", .{ len_reg, tasks_owner_reg }) catch return CodegenError.CodegenError;
            } else {
                return CodegenError.CodegenError;
            }
            self.out.writer().print("    EXPAND EXECUTOR_NEW {s}, {s}, {s}\n", .{ executor_reg, tasks_ptr_reg, len_reg }) catch return CodegenError.CodegenError;
            try self.emitRelease(len_reg);
            if (release_tasks_ptr) try self.emitRelease(tasks_ptr_reg);
            return executor_reg;
        }
        if (plan.isPollOne()) {
            if (call.args.len != 2 or call.generics.len != 0) return CodegenError.CodegenError;
            const executor_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const index_reg = try self.genExpr(call.args[1], hoisted_allocs);
            const poll_reg = try self.newTmp();
            const tag_reg = try self.newTmp();
            const ready_reg = try self.newTmp();
            self.out.writer().print("    EXPAND EXECUTOR_POLL_ONE {s}, {s}, {s}\n", .{ poll_reg, executor_reg, index_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = load {s}+Poll_tag as u64\n", .{ tag_reg, poll_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = eq {s}, Poll_READY\n", .{ ready_reg, tag_reg }) catch return CodegenError.CodegenError;
            try self.emitRelease(tag_reg);
            try self.emitRelease(poll_reg);
            if (callArgNeedsRelease(call.args[1])) try self.emitRelease(index_reg);
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(executor_reg);
            return ready_reg;
        }
        if (plan.isPollReadyCount()) {
            if (call.args.len != 1 or call.generics.len != 0) return CodegenError.CodegenError;
            const executor_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const task_count = self.executor_task_counts.get(self.resolveBindingName(executor_reg)) orelse blk_count: {
                if (call.args[0].* == .identifier) {
                    if (self.executor_task_counts.get(self.resolveBindingName(call.args[0].identifier))) |count| break :blk_count count;
                }
                const count_reg = try self.newTmp();
                self.out.writer().print("    EXPAND EXECUTOR_POLL_READY_COUNT {s}, {s}\n", .{ count_reg, executor_reg }) catch return CodegenError.CodegenError;
                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(executor_reg);
                return count_reg;
            };
            const count_reg = try self.genExecutorPollReadyCountUnrolled(executor_reg, task_count);
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(executor_reg);
            return count_reg;
        }
        if (plan.isRunUntilComplete()) {
            if (call.args.len != 1 or call.generics.len != 0) return CodegenError.CodegenError;
            const executor_reg = try self.genExpr(call.args[0], hoisted_allocs);
            const count_reg = try self.newTmp();
            self.out.writer().print("    EXPAND EXECUTOR_RUN_UNTIL_COMPLETE {s}, {s}\n", .{ count_reg, executor_reg }) catch return CodegenError.CodegenError;
            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(executor_reg);
            return count_reg;
        }
        return CodegenError.CodegenError;
    }

    fn genExecutorPollReadyCountUnrolled(self: *Codegen, executor_reg: []const u8, task_count: usize) CodegenError![]const u8 {
        const tasks_reg = try self.newTmp();
        const count_slot = try self.newTmp();

        self.out.writer().print("    {s} = load {s}+Executor_tasks as ptr\n", .{ tasks_reg, executor_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    {s} = stack_alloc 8\n", .{count_slot}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as u64\n", .{count_slot}) catch return CodegenError.CodegenError;

        for (0..task_count) |task_index| {
            const task_reg = try self.newTmp();
            const poll_reg = try self.newTmp();
            const tag_reg = try self.newTmp();
            const ready_reg = try self.newTmp();
            const ready_label = try self.newLabel("L_EXECUTOR_POLL_COUNT_READY");
            const next_label = try self.newLabel("L_EXECUTOR_POLL_COUNT_NEXT");
            self.out.writer().print("    {s} = load {s}+{} as ptr\n", .{ task_reg, tasks_reg, task_index * 8 }) catch return CodegenError.CodegenError;
            self.out.writer().print("    EXPAND TASK_POLL {s}, {s}\n", .{ poll_reg, task_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = load {s}+Poll_tag as u64\n", .{ tag_reg, poll_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = eq {s}, Poll_READY\n", .{ ready_reg, tag_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ ready_reg, ready_label, next_label }) catch return CodegenError.CodegenError;

            self.out.writer().print("{s}:\n", .{ready_label}) catch return CodegenError.CodegenError;
            const count_reg = try self.newTmp();
            const next_count_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as u64\n", .{ count_reg, count_slot }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = add {s}, 1\n", .{ next_count_reg, count_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    store {s}+0, {s} as u64\n", .{ count_slot, next_count_reg }) catch return CodegenError.CodegenError;
            try self.emitRelease(next_count_reg);
            try self.emitRelease(count_reg);
            self.out.writer().print("    jmp {s}\n\n", .{next_label}) catch return CodegenError.CodegenError;

            self.out.writer().print("{s}:\n", .{next_label}) catch return CodegenError.CodegenError;
            try self.emitRelease(ready_reg);
            try self.emitRelease(tag_reg);
            try self.emitRelease(poll_reg);
            try self.emitRelease(task_reg);
        }

        const out_count_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as u64\n", .{ out_count_reg, count_slot }) catch return CodegenError.CodegenError;
        try self.emitRelease(tasks_reg);
        return out_count_reg;
    }

    fn genFormatCall(self: *Codegen, call: *const ast.CallExpr, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        if (call.args.len == 0 or call.args[0].* != .literal or call.args[0].literal != .string_val) return CodegenError.CodegenError;
        const fmt = call.args[0].literal.string_val;
        const out_reg = try self.newTmp();
        const capacity = escapedStringByteLen(fmt) + (call.args.len - 1) * 24;
        self.out.writer().print("    EXPAND FORMAT_BEGIN {s}, {}\n", .{ out_reg, capacity }) catch return CodegenError.CodegenError;

        var literal = std.ArrayList(u8).init(self.allocator);
        defer literal.deinit();
        var arg_idx: usize = 1;
        var i: usize = 0;
        while (i < fmt.len) {
            if (fmt[i] == '{' and i + 1 < fmt.len) {
                if (fmt[i + 1] == '{') {
                    literal.append('{') catch return CodegenError.OutOfMemory;
                    i += 2;
                    continue;
                }
                if (fmt[i + 1] == '}') {
                    try self.emitFormatPushConstBytes(out_reg, literal.items);
                    literal.clearRetainingCapacity();
                    if (arg_idx >= call.args.len) return CodegenError.CodegenError;
                    try self.emitFormatPushArg(out_reg, call.args[arg_idx], hoisted_allocs);
                    arg_idx += 1;
                    i += 2;
                    continue;
                }
            }
            if (fmt[i] == '}' and i + 1 < fmt.len and fmt[i + 1] == '}') {
                literal.append('}') catch return CodegenError.OutOfMemory;
                i += 2;
                continue;
            }
            literal.append(fmt[i]) catch return CodegenError.OutOfMemory;
            i += 1;
        }
        try self.emitFormatPushConstBytes(out_reg, literal.items);
        if (arg_idx != call.args.len) return CodegenError.CodegenError;

        self.string_buf_bindings.put(out_reg, {}) catch return CodegenError.OutOfMemory;
        return out_reg;
    }

    fn genCallArg(self: *Codegen, arg: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        if (lowering_rules.prefixedIdentifierCallArg(arg)) |prefixed| {
            return std.fmt.allocPrint(self.allocator, "{c}{s}", .{ prefixed.prefix, self.resolveBindingName(prefixed.name) }) catch return CodegenError.OutOfMemory;
        }
        return try self.genExpr(arg, hoisted_allocs);
    }

    fn fnPtrInlineCandidateExpr(self: *Codegen, func: *const ast.FuncDecl) ?*const ast.Node {
        _ = self;
        const value = if (func.body.len == 1 and func.body[0].* == .return_stmt)
            func.body[0].return_stmt.value
        else if (func.body.len == 1 and func.body[0].* == .expr_stmt)
            func.body[0].expr_stmt
        else
            null;
        const expr = value orelse return null;
        for (func.params) |param| {
            if (nodeUsesIdentifier(expr, param.name)) return null;
        }
        return expr;
    }

    fn fnPtrInlineCanConsumeMovedArgs(self: *Codegen, lowered_args: []const LoweredCallArg, param_tys: []const *ast.Type) bool {
        _ = self;
        for (lowered_args, param_tys) |lowered_arg, param_ty| {
            if (!std.mem.startsWith(u8, lowered_arg.reg, "^")) continue;
            const smart = lowering_rules.smartPointerType(param_ty) orelse return false;
            if (smart.kind != .arc) return false;
        }
        return true;
    }

    fn emitFnPtrInlineMovedArgConsumes(self: *Codegen, lowered_args: []const LoweredCallArg, param_tys: []const *ast.Type) CodegenError!void {
        for (lowered_args, param_tys) |lowered_arg, param_ty| {
            if (!std.mem.startsWith(u8, lowered_arg.reg, "^")) continue;
            const smart = lowering_rules.smartPointerType(param_ty) orelse return CodegenError.CodegenError;
            if (smart.kind != .arc) return CodegenError.CodegenError;
            const arg_name = lowered_arg.reg[1..];
            self.out.writer().print("    !{s}\n", .{arg_name}) catch return CodegenError.CodegenError;
            try self.markConsumedBinding(arg_name);
        }
    }

    fn closureShadowsIdentifier(closure: ast.ClosureLiteral, name: []const u8) bool {
        for (closure.params) |param| {
            if (std.mem.eql(u8, param.name, name)) return true;
        }
        return false;
    }

    fn nodeBindsIdentifier(node: *const ast.Node, name: []const u8) bool {
        return switch (node.*) {
            .let_stmt => |let| std.mem.eql(u8, let.name, name),
            .const_stmt => |constant| std.mem.eql(u8, constant.name, name),
            .var_stmt => |variable| std.mem.eql(u8, variable.name, name),
            .let_destructure_stmt => |let| blk: {
                for (let.names) |binding| {
                    if (std.mem.eql(u8, binding, name)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn nodeUsesIdentifier(node: *const ast.Node, name: []const u8) bool {
        return switch (node.*) {
            .identifier => |ident| std.mem.eql(u8, ident, name),
            .literal, .generic_func_ref => false,
            .await_expr => |await_expr| nodeUsesIdentifier(await_expr.expr, name),
            .binary_expr => |bin| nodeUsesIdentifier(bin.left, name) or nodeUsesIdentifier(bin.right, name),
            .call_expr => |call| blk: {
                for (call.args) |arg| {
                    if (nodeUsesIdentifier(arg, name)) break :blk true;
                }
                break :blk false;
            },
            .closure_literal => |closure| if (closureShadowsIdentifier(closure, name)) false else nodeUsesIdentifier(closure.body, name),
            .borrow_expr => |borrow| nodeUsesIdentifier(borrow.expr, name),
            .move_expr => |move| nodeUsesIdentifier(move.expr, name),
            .deref_expr => |deref| nodeUsesIdentifier(deref.expr, name),
            .cast_expr => |cast| nodeUsesIdentifier(cast.expr, name),
            .field_expr => |field| nodeUsesIdentifier(field.expr, name),
            .struct_literal => |lit| blk: {
                if (lit.update_expr) |update| {
                    if (nodeUsesIdentifier(update, name)) break :blk true;
                }
                for (lit.fields) |field| {
                    if (nodeUsesIdentifier(field.value, name)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (nodeUsesIdentifier(field.value, name)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |tuple| blk: {
                for (tuple.elements) |elem| {
                    if (nodeUsesIdentifier(elem, name)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |array| blk: {
                for (array.elements) |elem| {
                    if (nodeUsesIdentifier(elem, name)) break :blk true;
                }
                break :blk false;
            },
            .repeat_array_literal => |repeat| nodeUsesIdentifier(repeat.value, name),
            .index_expr => |idx| nodeUsesIdentifier(idx.target, name) or nodeUsesIdentifier(idx.index, name),
            .slice_expr => |slice| nodeUsesIdentifier(slice.target, name) or nodeUsesIdentifier(slice.start, name) or nodeUsesIdentifier(slice.end, name),
            .try_expr => |try_expr| nodeUsesIdentifier(try_expr.expr, name),
            .if_expr => |ife| blk: {
                if (nodeUsesIdentifier(ife.cond, name)) break :blk true;
                if (ife.let_chain) |chain| {
                    for (chain) |item| {
                        if (nodeUsesIdentifier(item.value, name)) break :blk true;
                    }
                }
                for (ife.then_block) |stmt| {
                    if (nodeUsesIdentifier(stmt, name)) break :blk true;
                }
                if (ife.else_block) |else_block| {
                    for (else_block) |stmt| {
                        if (nodeUsesIdentifier(stmt, name)) break :blk true;
                    }
                }
                break :blk false;
            },
            .while_stmt => |w| blk: {
                if (nodeUsesIdentifier(w.cond, name)) break :blk true;
                for (w.body) |stmt| {
                    if (nodeUsesIdentifier(stmt, name)) break :blk true;
                }
                break :blk false;
            },
            .for_stmt => |f| blk: {
                if (nodeUsesIdentifier(f.start, name)) break :blk true;
                if (f.end) |end_expr| {
                    if (nodeUsesIdentifier(end_expr, name)) break :blk true;
                }
                if (std.mem.eql(u8, f.var_name, name)) break :blk false;
                for (f.body) |stmt| {
                    if (nodeUsesIdentifier(stmt, name)) break :blk true;
                }
                break :blk false;
            },
            .expr_stmt => |e| nodeUsesIdentifier(e, name),
            .return_stmt => |r| if (r.value) |v| nodeUsesIdentifier(v, name) else false,
            .let_stmt => |let| nodeUsesIdentifier(let.value, name),
            .assign_stmt => |a| nodeUsesIdentifier(a.target, name) or nodeUsesIdentifier(a.value, name),
            .switch_expr => |switch_expr| nodeUsesIdentifier(switch_expr.val, name),
            .match_expr => |match_expr| nodeUsesIdentifier(match_expr.val, name),
            else => false,
        };
    }

    fn identifierUsedLaterInCurrentExpr(self: *Codegen, name: []const u8) bool {
        for (self.current_expr_later_nodes.items) |node| {
            if (nodeUsesIdentifier(node, name)) return true;
        }
        return false;
    }

    fn identifierUsedLaterInCurrentBlock(self: *Codegen, name: []const u8) bool {
        const block = self.current_block orelse return false;
        var idx = self.current_stmt_index + 1;
        while (idx < block.len) : (idx += 1) {
            const stmt = block[idx];
            if (nodeUsesIdentifier(stmt, name)) return true;
            if (nodeBindsIdentifier(stmt, name)) return false;
        }
        return false;
    }

    fn identifierDefinedInCurrentBlock(self: *Codegen, name: []const u8) bool {
        const block = self.current_block orelse return false;
        var idx: usize = 0;
        while (idx <= self.current_stmt_index and idx < block.len) : (idx += 1) {
            if (nodeBindsIdentifier(block[idx], name)) return true;
        }
        return false;
    }

    fn identifierMustStayLiveForLaterUse(self: *Codegen, name: []const u8) bool {
        if (self.identifierUsedLaterInCurrentExpr(name) or self.identifierUsedLaterInCurrentBlock(name)) return true;
        // Loop back-edge: outer/param bindings that the body reads must remain
        // Active across iterations even when the current statement is the only
        // textual use in this pass through the body.
        if (self.loop_continue_labels.items.len == 0) return false;
        // Loop-local bindings are owned by this iteration and may be consumed.
        if (self.identifierDefinedInCurrentBlock(name)) return false;
        // Outer/param bindings remain live across the while/for back-edge.
        return true;
    }

    fn genVecCloneValue(self: *Codegen, source_reg: []const u8, elem_ty: *const ast.Type) CodegenError![]const u8 {
        const out = try self.newTmp();
        self.out.writer().print(
            "    EXPAND VEC_CLONE {s}, {s}, {}\n",
            .{ out, source_reg, self.vecElementSlotSize(elem_ty) },
        ) catch return CodegenError.CodegenError;
        return out;
    }

    fn pushCallSiblingArgExprs(self: *Codegen, args: []const *ast.Node, arg_index: usize) CodegenError!usize {
        const mark = self.current_expr_later_nodes.items.len;
        for (args, 0..) |arg, i| {
            if (i == arg_index) continue;
            self.current_expr_later_nodes.append(arg) catch return CodegenError.OutOfMemory;
        }
        return mark;
    }

    fn popExprLaterNodesTo(self: *Codegen, mark: usize) void {
        self.current_expr_later_nodes.shrinkRetainingCapacity(mark);
    }

    fn emitPrimitiveCopy(self: *Codegen, target: []const u8, source: []const u8, ty: *const ast.Type) CodegenError!void {
        if (ty.* != .primitive) return CodegenError.CodegenError;
        switch (ty.primitive) {
            .boolean => self.out.writer().print("    {s} = or {s}, 0\n", .{ target, source }) catch return CodegenError.CodegenError,
            .f32, .f64, .float => {
                // Floats need the `fadd` opcode, not integer `add`. Emitting
                // `add src, 0.0` makes the backend fold it as an integer identity
                // copy and coalesce the destination onto the source register, so a
                // later mutation of the destination clobbers the source. Materialize
                // a float-zero constant in a register and use `fadd`, mirroring the
                // `value + 0.0` lowering that produces an independent copy.
                const zero = try self.newTmp();
                try self.emitFloatConst(zero, 0.0);
                self.out.writer().print("    {s} = fadd {s}, {s}\n", .{ target, source, zero }) catch return CodegenError.CodegenError;
                try self.emitRelease(zero);
            },
            else => self.out.writer().print("    {s} = add {s}, 0\n", .{ target, source }) catch return CodegenError.CodegenError,
        }
    }

    fn genBranchConditionReg(self: *Codegen, cond: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        const cond_reg = try self.genExpr(cond, hoisted_allocs);
        const cond_ty = self.tc.expr_types.get(cond) orelse return CodegenError.CodegenError;
        if (cond.* == .identifier and cond_ty.* == .primitive) {
            const resolved_name = self.resolveBindingName(cond.identifier);
            if (std.mem.eql(u8, cond_reg, resolved_name) or std.mem.eql(u8, cond_reg, cond.identifier) or self.global_const_bindings.contains(cond.identifier)) {
                const copied = try self.newTmp();
                try self.emitPrimitiveCopy(copied, cond_reg, cond_ty);
                return copied;
            }
        }
        return cond_reg;
    }

    const LoweredCallArg = struct {
        reg: []const u8,
        release_after_call: bool,
        release_reg: ?[]const u8 = null,
        consume_reg: ?[]const u8 = null,
    };

    fn emitForgetMovedValue(self: *Codegen, reg: []const u8) CodegenError!void {
        if (std.mem.startsWith(u8, reg, "&")) return;
        if (std.mem.startsWith(u8, reg, "^")) return try self.markConsumedBinding(reg[1..]);
        self.out.writer().print("    ^{s}\n", .{reg}) catch return CodegenError.CodegenError;
        try self.markConsumedBinding(reg);
    }

    fn plannedCallArgReleaseReg(self: *Codegen, lowered_arg: LoweredCallArg) ?[]const u8 {
        const release_after_call = lowered_arg.release_reg != null or lowered_arg.release_after_call;
        const candidate = lowered_arg.release_reg orelse lowered_arg.reg;
        const lifecycle = lowering_rules.planRefCellCallArgLifecycle(
            release_after_call,
            self.refcell_borrow_handles.contains(candidate),
        );
        return if (lifecycle.shouldRelease()) candidate else null;
    }

    fn appendLoweredCallArgCleanups(
        self: *Codegen,
        release_regs: *std.ArrayList(?[]const u8),
        consume_regs: *std.ArrayList([]const u8),
        lowered_arg: LoweredCallArg,
    ) CodegenError!void {
        release_regs.append(self.plannedCallArgReleaseReg(lowered_arg)) catch return CodegenError.OutOfMemory;
        if (lowered_arg.consume_reg) |reg| consume_regs.append(reg) catch return CodegenError.OutOfMemory;
    }

    fn identifierCallArgTempNeedsRelease(self: *Codegen, arg: *const ast.Node, arg_reg: []const u8) bool {
        if (arg.* != .identifier) return false;
        if (!isTemporaryRegisterName(arg_reg)) return false;
        const resolved_name = self.resolveBindingName(arg.identifier);
        if (std.mem.eql(u8, arg_reg, arg.identifier) or std.mem.eql(u8, arg_reg, resolved_name)) return false;
        return true;
    }

    fn callArgResultTempNeedsRelease(self: *Codegen, arg: *const ast.Node, arg_reg: []const u8) bool {
        return self.exprResultRegNeedsRelease(arg) or self.identifierCallArgTempNeedsRelease(arg, arg_reg);
    }

    fn callArgResultTempNeedsReleaseForParam(self: *Codegen, param: ?ast.Param, arg: *const ast.Node, arg_reg: []const u8) bool {
        const action = lowering_rules.planStackSlotIdentifierCallArgTemp(
            param,
            self.identifierCallArgTempNeedsRelease(arg, arg_reg),
        );
        return action.releasesTemp() or (action.isKeep() and self.callArgResultTempNeedsRelease(arg, arg_reg));
    }

    fn callArgResultTempNeedsConsumeForParam(self: *Codegen, param: ?ast.Param, arg: *const ast.Node, arg_reg: []const u8) bool {
        const action = lowering_rules.planStackSlotIdentifierCallArgTemp(
            param,
            self.identifierCallArgTempNeedsRelease(arg, arg_reg),
        );
        return action.consumesTemp();
    }

    fn emitLoweredCallArgCleanups(
        self: *Codegen,
        release_regs: []const ?[]const u8,
        consume_regs: []const []const u8,
        skip_release_name: ?[]const u8,
    ) CodegenError!void {
        for (release_regs) |release_reg| {
            if (release_reg) |arg_reg| {
                if (skip_release_name) |name| {
                    if (std.mem.eql(u8, name, "sum")) continue;
                }
                try self.emitRelease(arg_reg);
            }
        }
        for (consume_regs) |consume_reg| try self.emitForgetMovedValue(consume_reg);
    }

    const CallArgLoweringOptions = struct {
        param: ?ast.Param = null,
        arg_index: usize = 0,
        auto_borrow_receiver: bool = false,
        receiver_style_auto_borrow: bool = false,
        statement_receiver_auto_borrow: bool = false,
        include_array_to_slice_borrow: bool = true,
        include_dyn_borrow: bool = true,
        include_copy_struct_value: bool = true,
    };

    fn macroArrayToSliceBorrowArg(self: *Codegen, arg: *const ast.Node, param: ?ast.Param) bool {
        if (self.active_inline_macro == null or arg.* != .borrow_expr) return false;
        const inner = arg.borrow_expr.expr;
        if (inner.* != .identifier) return false;
        const target_param = param orelse return false;
        if ((!target_param.is_borrow and target_param.ty.* != .borrow) or sliceElementType(target_param.ty) == null) return false;
        const inner_ty = self.macroArgTypeForName(inner.identifier) orelse return false;
        return arrayType(inner_ty) != null;
    }

    fn genCallArgFromMaterializationPlan(
        self: *Codegen,
        arg: *ast.Node,
        param: ?ast.Param,
        materialization: lowering_rules.CallArgMaterializationPlan,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!LoweredCallArg {
        if (materialization.isRawPointerStringLiteral()) {
            return blk: {
                if (arg.* != .literal or arg.literal != .string_val) return CodegenError.CodegenError;
                const ptr_reg = try self.genRawPointerStringLiteralArg(arg.literal.string_val);
                if (param) |target_param| {
                    if (std.mem.eql(u8, self.abiParamPrefix(target_param), "^")) {
                        const move_arg = std.fmt.allocPrint(self.allocator, "^{s}", .{ptr_reg}) catch return CodegenError.OutOfMemory;
                        break :blk .{ .reg = move_arg, .release_after_call = false, .consume_reg = move_arg };
                    }
                }
                break :blk .{ .reg = ptr_reg, .release_after_call = materialization.release_after_call };
            };
        } else if (materialization.isArrayToSliceBorrow()) {
            return try self.genArrayBorrowToSliceArg(arg, hoisted_allocs);
        } else if (materialization.isDynBorrow()) {
            return blk: {
                const trait_name = materialization.dyn_borrow_trait_name orelse return CodegenError.CodegenError;
                const fat_reg = try self.genDynBorrowCoercionArg(arg, trait_name, hoisted_allocs);
                const borrow_arg = std.fmt.allocPrint(self.allocator, "&{s}", .{fat_reg}) catch return CodegenError.OutOfMemory;
                break :blk .{ .reg = borrow_arg, .release_after_call = false, .release_reg = fat_reg };
            };
        } else if (materialization.isAutoBorrow()) {
            return blk: {
                const recv_reg = try self.genExpr(arg, hoisted_allocs);
                const borrow_arg = std.fmt.allocPrint(self.allocator, "&{s}", .{recv_reg}) catch return CodegenError.OutOfMemory;
                const release_recv = materialization.release_after_call or self.callArgResultTempNeedsRelease(arg, recv_reg);
                break :blk .{
                    .reg = borrow_arg,
                    .release_after_call = release_recv,
                    .release_reg = if (release_recv) recv_reg else null,
                };
            };
        } else if (materialization.isCopyStructValue()) {
            return blk: {
                const target_param = param orelse return CodegenError.CodegenError;
                const source_reg = try self.genExpr(arg, hoisted_allocs);
                const copied = try self.newTmp();
                try self.genCopyValueInto(copied, source_reg, target_param.ty);
                break :blk .{ .reg = copied, .release_after_call = materialization.release_after_call };
            };
        } else if (materialization.isShallowCopyPreservedValue()) {
            return blk: {
                const arg_ty = self.resolvedTypeForExpr(arg) orelse return CodegenError.CodegenError;
                const source_reg = try self.genCallArg(arg, hoisted_allocs);
                const copied = try self.genShallowCopyCallArgValue(source_reg, arg_ty);
                const moved_copy = std.fmt.allocPrint(self.allocator, "^{s}", .{copied}) catch return CodegenError.OutOfMemory;
                break :blk .{ .reg = moved_copy, .release_after_call = false };
            };
        } else if (materialization.isGeneratedFnPtrValueSlot() or materialization.isBorrowLocalFnPtrValue()) {
            return CodegenError.CodegenError;
        } else if (materialization.isValue()) {
            return blk: {
                if (lowering_rules.borrowedIdentifierName(arg)) |borrowed_name| {
                    if (self.addressable_bindings.contains(borrowed_name)) {
                        const addr_reg = try self.genExpr(arg, hoisted_allocs);
                        const call_arg = std.fmt.allocPrint(self.allocator, "&{s}", .{addr_reg}) catch return CodegenError.OutOfMemory;
                        break :blk .{
                            .reg = call_arg,
                            .release_after_call = false,
                            .release_reg = if (materialization.release_after_call) addr_reg else null,
                        };
                    }
                }
                const arg_reg = if (param != null)
                    try self.genExpr(arg, hoisted_allocs)
                else
                    try self.genCallArg(arg, hoisted_allocs);
                const abi_moves_arg = if (param) |target_param|
                    std.mem.eql(u8, self.abiParamPrefix(target_param), "^")
                else
                    false;
                if (materialization.transfers_ownership or abi_moves_arg) {
                    // Language semantics allow reusing a by-value Vec after a plain
                    // call (typechecker does not consume it). The SA ABI still uses
                    // ^ and the callee frees, so keep the source live by cloning
                    // when the binding is still needed after this call.
                    if (arg.* == .identifier and self.identifierMustStayLiveForLaterUse(arg.identifier)) {
                        if (self.resolvedTypeForExpr(arg) orelse self.tc.expr_types.get(arg)) |ty| {
                            if (vecElementType(ty)) |elem_ty| {
                                const cloned = try self.genVecCloneValue(arg_reg, elem_ty);
                                const move_arg = std.fmt.allocPrint(self.allocator, "^{s}", .{cloned}) catch return CodegenError.OutOfMemory;
                                break :blk .{
                                    .reg = move_arg,
                                    .release_after_call = false,
                                    .consume_reg = move_arg,
                                };
                            }
                        }
                    }
                    const move_arg = if (std.mem.startsWith(u8, arg_reg, "^"))
                        arg_reg
                    else
                        std.fmt.allocPrint(self.allocator, "^{s}", .{arg_reg}) catch return CodegenError.OutOfMemory;
                    break :blk .{
                        .reg = move_arg,
                        .release_after_call = false,
                        .consume_reg = move_arg,
                    };
                }
                if (param) |target_param| {
                    if (abiParamNeedsBorrowArg(target_param) and !std.mem.startsWith(u8, arg_reg, "&")) {
                        const borrow_arg = std.fmt.allocPrint(self.allocator, "&{s}", .{arg_reg}) catch return CodegenError.OutOfMemory;
                        const release_arg = materialization.release_after_call or self.callArgResultTempNeedsReleaseForParam(param, arg, arg_reg);
                        break :blk .{
                            .reg = borrow_arg,
                            .release_after_call = release_arg,
                            .release_reg = if (release_arg) arg_reg else null,
                        };
                    }
                }
                const release_arg = materialization.release_after_call or self.callArgResultTempNeedsReleaseForParam(param, arg, arg_reg);
                const consume_arg = self.callArgResultTempNeedsConsumeForParam(param, arg, arg_reg);
                break :blk .{
                    .reg = arg_reg,
                    .release_after_call = release_arg,
                    .consume_reg = if (consume_arg) arg_reg else null,
                };
            };
        } else unreachable;
    }

    fn genPlannedCallArg(
        self: *Codegen,
        arg: *ast.Node,
        hoisted_allocs: *const std.ArrayList([]const u8),
        options: CallArgLoweringOptions,
    ) CodegenError!LoweredCallArg {
        const copy_struct_value = options.include_copy_struct_value and
            lowering_rules.callArgIsCopyStructValue(
                arg,
                options.param,
                if (options.param) |param| self.typeIsCopyStruct(param.ty) else false,
            );
        const arg_ty = self.resolvedTypeForExpr(arg);
        // Shallow-copy materialization has struct-layout support only. Pure
        // enums still participate in copy analysis for nested struct fields,
        // but a top-level enum argument must use ordinary value transfer.
        const shallow_copy_value = lowering_rules.callArgIsShallowCopyValueCandidate(
            arg,
            options.param,
            arg_ty,
            if (arg_ty) |ty| self.typeIsCopyValue(ty) else false,
            if (arg_ty) |ty| self.typeIsShallowCopyCallArgValue(ty, 0) else false,
        ) and (if (arg_ty) |ty| self.structDeclForType(ty) != null else false);
        const materialization = lowering_rules.planCallArgMaterialization(arg, .{
            .param = options.param,
            .arg_ty = arg_ty,
            .arg_index = options.arg_index,
            .auto_borrow_receiver = options.auto_borrow_receiver,
            .receiver_style_auto_borrow = options.receiver_style_auto_borrow,
            .statement_receiver_auto_borrow = options.statement_receiver_auto_borrow,
            .array_to_slice_borrow = options.include_array_to_slice_borrow and
                (self.tc.array_to_slice_borrow_args.contains(arg) or self.macroArrayToSliceBorrowArg(arg, options.param)),
            .dyn_borrow_trait_name = if (options.include_dyn_borrow) self.tc.dyn_borrow_args.get(arg) else null,
            .copy_struct_value = copy_struct_value,
            .generated_fn_ptr_identifier = self.generatedFnPtrIdentifierArg(arg),
            .generated_scalar_const_identifier = self.generatedScalarConstIdentifierArg(arg),
            .preserve_identifier_for_later_use = arg.* == .identifier and self.identifierUsedLaterInCurrentExpr(arg.identifier),
            .shallow_copy_value = shallow_copy_value,
            .value_arg_transfers_ownership = self.valueArgTransfersOwnership(options.param, arg_ty),
        });
        return try self.genCallArgFromMaterializationPlan(arg, options.param, materialization, hoisted_allocs);
    }

    fn genCallArgForParam(
        self: *Codegen,
        arg: *ast.Node,
        param: ast.Param,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!LoweredCallArg {
        return try self.genPlannedCallArg(arg, hoisted_allocs, .{
            .param = param,
            .include_array_to_slice_borrow = false,
            .include_dyn_borrow = false,
        });
    }

    fn genResolvedFunctionCall(
        self: *Codegen,
        lowering: lowering_rules.StaticCallLoweringPlan,
        call: *const ast.CallExpr,
        hoisted_allocs: *const std.ArrayList([]const u8),
        auto_borrow_receiver: bool,
    ) CodegenError![]const u8 {
        const plan = lowering.call;
        const symbol = lowering_rules.staticCallEmitSymbol(plan);
        const func = self.tc.funcs.get(symbol) orelse return CodegenError.CodegenError;
        if (func.params.len != plan.arg_count or func.params.len != call.args.len) return CodegenError.CodegenError;

        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
        defer arg_regs.deinit();
        var release_regs = std.ArrayList(?[]const u8).init(self.allocator);
        defer release_regs.deinit();
        var consume_regs = std.ArrayList([]const u8).init(self.allocator);
        defer consume_regs.deinit();

        for (call.args, 0..) |arg, i| {
            const param = func.params[i];
            const sibling_mark = try self.pushCallSiblingArgExprs(call.args, i);
            defer self.popExprLaterNodesTo(sibling_mark);
            const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{
                .param = param,
                .arg_index = i,
                .auto_borrow_receiver = auto_borrow_receiver,
            });
            arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
            try self.appendLoweredCallArgCleanups(&release_regs, &consume_regs, lowered_arg);
        }

        const reg = if (lowering.result.returns_void) "return_ty_sentinel" else try self.newTmp();
        const lowered_symbol = try self.loweredFuncSymbol(symbol);
        defer self.allocator.free(lowered_symbol);
        if (lowering.result.returns_void) {
            self.out.writer().print("    call @{s}(", .{lowered_symbol}) catch return CodegenError.CodegenError;
        } else {
            self.out.writer().print("    {s} = call @{s}(", .{ reg, lowered_symbol }) catch return CodegenError.CodegenError;
        }
        for (arg_regs.items, 0..) |arg_reg, i| {
            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}", .{arg_reg}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;

        try self.emitLoweredCallArgCleanups(release_regs.items, consume_regs.items, null);
        return reg;
    }

    fn importedMacroExistingAddressableSymbol(self: *Codegen, arg: *const ast.Node) ?[]const u8 {
        if (arg.* != .identifier) return null;
        const resolved_name = self.resolveBindingName(arg.identifier);
        if (self.stack_alloc_bindings.contains(resolved_name)) return resolved_name;
        return null;
    }

    fn importedMacroArgType(self: *Codegen, arg: *const ast.Node) CodegenError!*const ast.Type {
        const ty = self.resolvedTypeForExpr(arg) orelse return switch (arg.*) {
            .identifier => |name| self.fail("macro argument `{s}` (identifier) has no resolvable type; annotate its `let` with an explicit type", .{name}),
            else => self.fail("macro argument expression ({s}) has no resolvable type", .{@tagName(arg.*)}),
        };
        return ty;
    }

    fn importedMacroArgAddressShape(self: *Codegen, arg: *const ast.Node) CodegenError!lowering_rules.AddressOfShape {
        var deref_source_ty: ?*const ast.Type = null;
        var index_target_ty: ?*const ast.Type = null;
        switch (arg.*) {
            .deref_expr => deref_source_ty = try self.importedMacroArgType(arg.deref_expr.expr),
            .index_expr => |idx| index_target_ty = try self.importedMacroArgType(idx.target),
            else => {},
        }
        return lowering_rules.planAddressOf(arg, .{
            .deref_source_ty = deref_source_ty,
            .index_target_ty = index_target_ty,
        }).shape;
    }

    fn genImportedMacroMaterializedSlotArg(self: *Codegen, arg: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!LoweredCallArg {
        const value_reg = try self.genExpr(arg, hoisted_allocs);
        const arg_ty = try self.importedMacroArgType(arg);
        const slot = try self.newTmp();
        self.stack_alloc_bindings.put(slot, {}) catch return CodegenError.OutOfMemory;
        self.out.writer().print("    {s} = stack_alloc {}\n", .{ slot, typeSize(arg_ty) }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ slot, value_reg, typeString(arg_ty) }) catch return CodegenError.CodegenError;
        if (self.importedMacroValueArgNeedsRelease(arg, value_reg)) try self.emitRelease(value_reg);
        return .{ .reg = slot, .release_after_call = false };
    }

    fn genImportedMacroAddressExpressionMaterializedSlotArg(self: *Codegen, arg: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!LoweredCallArg {
        const arg_ty = try self.importedMacroArgType(arg);
        const slot = try self.newTmp();
        self.stack_alloc_bindings.put(slot, {}) catch return CodegenError.OutOfMemory;
        self.out.writer().print("    {s} = stack_alloc {}\n", .{ slot, typeSize(arg_ty) }) catch return CodegenError.CodegenError;

        const value_reg = switch (try self.importedMacroArgAddressShape(arg)) {
            .field => blk: {
                const projection = try self.genFieldAddress(&arg.field_expr, hoisted_allocs);
                try self.rememberAddressProjectionSource(projection);
                const loaded = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ loaded, projection.ptr, typeString(arg_ty) }) catch return CodegenError.CodegenError;
                try self.emitRelease(projection.ptr);
                break :blk loaded;
            },
            .index => blk: {
                const address = try self.genIndexAddress(&arg.index_expr, hoisted_allocs);
                try self.rememberIndexAddressSource(address);
                const loaded = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ loaded, address.ptr, typeString(arg_ty) }) catch return CodegenError.CodegenError;
                try self.emitRelease(address.ptr);
                break :blk loaded;
            },
            .deref_borrow_or_pointer => blk: {
                const source = try self.genExpr(arg.deref_expr.expr, hoisted_allocs);
                const loaded = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ loaded, source, typeString(arg_ty) }) catch return CodegenError.CodegenError;
                if (exprResultNeedsRelease(arg.deref_expr.expr)) try self.emitRelease(source);
                break :blk loaded;
            },
            .deref_smart_pointer => try self.genExpr(arg, hoisted_allocs),
            else => |shape| return self.fail("cannot materialize stack slot for address shape `{s}`", .{@tagName(shape)}),
        };

        self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ slot, value_reg, typeString(arg_ty) }) catch return CodegenError.CodegenError;
        if (self.importedMacroValueArgNeedsRelease(arg, value_reg)) try self.emitRelease(value_reg);
        return .{ .reg = slot, .release_after_call = false };
    }

    fn genImportedMacroAddressExpressionArg(self: *Codegen, arg: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!LoweredCallArg {
        const address_reg = switch (try self.importedMacroArgAddressShape(arg)) {
            .field => blk: {
                const projection = try self.genFieldAddress(&arg.field_expr, hoisted_allocs);
                try self.rememberAddressProjectionSource(projection);
                break :blk projection.ptr;
            },
            .index => blk: {
                const address = try self.genIndexAddress(&arg.index_expr, hoisted_allocs);
                try self.rememberIndexAddressSource(address);
                break :blk address.ptr;
            },
            .deref_borrow_or_pointer => blk: {
                const source = try self.genExpr(arg.deref_expr.expr, hoisted_allocs);
                const addr = try self.newTmp();
                self.out.writer().print("    {s} = ptr_add {s}, 0\n", .{ addr, source }) catch return CodegenError.CodegenError;
                const temp_plan = lowering_rules.planBorrowAddressTemps(exprResultNeedsRelease(arg.deref_expr.expr), false);
                if (temp_plan.track_primary_temp) {
                    self.borrow_source_temps.put(addr, source) catch return CodegenError.OutOfMemory;
                }
                break :blk addr;
            },
            .deref_smart_pointer => try self.genExpr(arg, hoisted_allocs),
            else => return self.fail("cannot form address expression for this argument shape", .{}),
        };
        return .{ .reg = address_reg, .release_after_call = false, .release_reg = address_reg };
    }

    fn importedMacroValueArgNeedsRelease(self: *Codegen, arg: *const ast.Node, reg: []const u8) bool {
        if (self.exprResultRegNeedsRelease(arg)) return true;
        if (arg.* != .identifier) return false;

        const name = arg.identifier;
        const resolved_name = self.resolveBindingName(name);
        if (std.mem.eql(u8, reg, name) or std.mem.eql(u8, reg, resolved_name)) return false;

        if (self.global_scalar_consts.contains(name)) return true;
        if (self.tc.funcs.contains(name)) {
            if (self.resolvedTypeForExpr(arg)) |arg_ty| {
                if (arg_ty.* == .fn_ptr) return true;
            }
        }

        if (!std.mem.eql(u8, resolved_name, name)) {
            if (self.addressable_bindings.contains(resolved_name)) return true;
            return false;
        }
        if (self.addressable_bindings.contains(name)) return true;
        if (self.bindingStorageAddress(name) != null) return true;
        return !std.mem.eql(u8, reg, name) and
            !self.global_const_bindings.contains(name) and
            self.closure_param_regs.get(name) == null;
    }

    // Imported macros that receive callbacks (RawWakerVTable, poll fns) expect a
    // 16-byte fn object {data=0, vtable}; a bare &SLA_FNPTR_VT_* word would be
    // dereferenced at +8 by the macro body. Materialize the object form here.
    fn genImportedMacroFnObjectArg(
        self: *Codegen,
        arg: *ast.Node,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!?LoweredCallArg {
        _ = hoisted_allocs;
        if (arg.* != .identifier) return null;
        if (!self.tc.funcs.contains(arg.identifier)) return null;
        const arg_ty = self.resolvedTypeForExpr(arg) orelse return null;
        if (arg_ty.* != .fn_ptr) return null;

        const obj = try self.newTmp();
        const vt_name = try self.fnPtrVTableName(arg.identifier);
        defer self.allocator.free(vt_name);
        self.out.writer().print("    {s} = alloc 16\n", .{obj}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as ptr\n", .{obj}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+8, &{s} as ptr\n", .{ obj, vt_name }) catch return CodegenError.CodegenError;
        return .{ .reg = obj, .release_after_call = false };
    }

    fn genImportedMacroArg(
        self: *Codegen,
        plan: lowering_rules.ImportedMacroCallPlan,
        call_arg_index: usize,
        arg: *ast.Node,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!LoweredCallArg {
        if (try self.genImportedMacroFnObjectArg(arg, hoisted_allocs)) |fn_obj| return fn_obj;
        const arg_ty = try self.importedMacroArgType(arg);
        // A direct address-slot macro parameter consumes the address of the
        // caller-provided storage. `stack_alloc()` already returns that
        // address; routing it through `genExpr` would treat an addressable
        // raw-ptr binding as a value slot and emit `load name+0`, producing a
        // null pointer for an uninitialized slot (for example PIN_MUT_NEW).
        const existing_symbol = self.importedMacroExistingAddressableSymbol(arg);
        if (plan.callArgNeedsDirectAddressSlot(call_arg_index) and existing_symbol != null) {
            return .{ .reg = existing_symbol.?, .release_after_call = false };
        }
        if (plan.planArgValueBypassAction(call_arg_index, arg, arg_ty)) |action| {
            if (action.passesValue() or action.passesRawPointerValue()) {
                const reg = try self.genExpr(arg, hoisted_allocs);
                return .{ .reg = reg, .release_after_call = self.importedMacroValueArgNeedsRelease(arg, reg) };
            }
            return self.fail("imported macro `{s}` argument #{d}: bypass lowering action cannot lower this argument shape", .{ plan.macro_name, call_arg_index });
        }
        const address_shape = try self.importedMacroArgAddressShape(arg);
        const action = plan.planAddressableArgLoweringAction(call_arg_index, address_shape, existing_symbol != null, arg_ty);
        if (action.passesValue() or action.passesPointerBackedProjection()) {
            const reg = try self.genExpr(arg, hoisted_allocs);
            return .{ .reg = reg, .release_after_call = self.importedMacroValueArgNeedsRelease(arg, reg) };
        }
        if (action.passesAddressExpression()) return self.genImportedMacroAddressExpressionArg(arg, hoisted_allocs);
        if (action.reusesExistingAddressable()) return .{ .reg = existing_symbol.?, .release_after_call = false };
        if (action.materializesStackSlot()) return self.genImportedMacroMaterializedSlotArg(arg, hoisted_allocs);
        if (action.materializesAddressExpressionStackSlot()) return self.genImportedMacroAddressExpressionMaterializedSlotArg(arg, hoisted_allocs);
        return self.fail("imported macro `{s}` argument #{d}: no lowering action matched address shape `{s}` (borrow mask 0b{b}, address-slot mask 0b{b})", .{ plan.macro_name, call_arg_index, @tagName(address_shape), plan.borrowed_arg_mask, plan.address_slot_arg_mask });
    }

    fn genPlainTimeMacroCall(
        self: *Codegen,
        call: *const ast.CallExpr,
        plan: lowering_rules.ImportedMacroCallPlan,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!?[]const u8 {
        if (!self.use_plain_time_sleep_ms_abi) return null;

        if (std.mem.eql(u8, plan.macro_name, "TIME_DURATION_FROM_MILLIS")) {
            if (!plan.expression_output or call.args.len != 1) return CodegenError.CodegenError;
            const lowered_arg = try self.genImportedMacroArg(plan, 0, call.args[0], hoisted_allocs);
            const reg = try self.newTmp();
            self.out.writer().print("    {s} = mul {s}, 1000000\n", .{ reg, lowered_arg.reg }) catch return CodegenError.CodegenError;
            if (self.plannedCallArgReleaseReg(lowered_arg)) |release_reg| try self.emitRelease(release_reg);
            return reg;
        }

        if (std.mem.eql(u8, plan.macro_name, "TIME_THREAD_SLEEP_NS")) {
            if (plan.expression_output or call.args.len != 1) return CodegenError.CodegenError;
            const lowered_arg = try self.genImportedMacroArg(plan, 0, call.args[0], hoisted_allocs);
            const millis = try self.newTmp();
            const remainder = try self.newTmp();
            const has_remainder = try self.newTmp();
            const rounded_millis = try self.newTmp();
            const status = try self.newTmp();
            self.out.writer().print("    {s} = div {s}, 1000000\n", .{ millis, lowered_arg.reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = rem {s}, 1000000\n", .{ remainder, lowered_arg.reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = ne {s}, 0\n", .{ has_remainder, remainder }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = add {s}, {s}\n", .{ rounded_millis, millis, has_remainder }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = call @sa_time_sleep_ms({s})\n", .{ status, rounded_millis }) catch return CodegenError.CodegenError;
            try self.emitRelease(status);
            try self.emitRelease(rounded_millis);
            try self.emitRelease(has_remainder);
            try self.emitRelease(remainder);
            try self.emitRelease(millis);
            if (self.plannedCallArgReleaseReg(lowered_arg)) |release_reg| try self.emitRelease(release_reg);
            return "return_ty_sentinel";
        }

        return null;
    }

    fn genOnceGetOrInitCall(
        self: *Codegen,
        call: *const ast.CallExpr,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!?[]const u8 {
        if (!std.mem.eql(u8, call.func_name, "ONCE_GET_OR_INIT") or call.args.len != 2) return null;
        if (call.args[1].* != .identifier or !self.tc.funcs.contains(call.args[1].identifier)) return null;

        const once_reg = try self.genExpr(call.args[0], hoisted_allocs);
        const result_reg = try self.newTmp();
        const init_slot = try self.newTmp();
        self.stack_alloc_bindings.put(init_slot, {}) catch return CodegenError.OutOfMemory;
        self.out.writer().print("    {s} = stack_alloc 16\n", .{init_slot}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as ptr\n", .{init_slot}) catch return CodegenError.CodegenError;
        const vt_name = try self.fnPtrVTableName(call.args[1].identifier);
        defer self.allocator.free(vt_name);
        self.out.writer().print("    store {s}+8, &{s} as ptr\n", .{ init_slot, vt_name }) catch return CodegenError.CodegenError;
        self.out.writer().print("    EXPAND ONCE_GET_OR_INIT {s}, {s}, {s}\n", .{ result_reg, once_reg, init_slot }) catch return CodegenError.CodegenError;
        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(once_reg);
        return result_reg;
    }

    /// Tracked wrapper: remembers which imported macro was being expanded so
    /// a failing CodegenError can be reported with the macro's name.
    fn genImportedMacroCall(self: *Codegen, call: *const ast.CallExpr, plan: lowering_rules.ImportedMacroCallPlan, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        const prev_macro = self.diag_macro_name;
        self.diag_macro_name = plan.macro_name;
        const result = self.genImportedMacroCallImpl(call, plan, hoisted_allocs);
        if (result) |reg| {
            self.diag_macro_name = prev_macro;
            return reg;
        } else |err| {
            self.synthesizeDiagFromContext(err);
            self.diag_macro_name = prev_macro;
            return err;
        }
    }

    fn genImportedMacroCallImpl(self: *Codegen, call: *const ast.CallExpr, plan: lowering_rules.ImportedMacroCallPlan, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        if (try self.genPlainTimeMacroCall(call, plan, hoisted_allocs)) |reg| return reg;
        if (std.process.hasEnvVarConstant("SLA_CODEGEN_TRACE")) std.debug.print("[sla-trace] imported macro {s} arity={d} args={d} expr_out={} borrow=0b{b} addr=0b{b}\n", .{ plan.macro_name, plan.arity, call.args.len, plan.expression_output, plan.borrowed_arg_mask, plan.address_slot_arg_mask });
        const reg = if (plan.expression_output) try self.newTmp() else "return_ty_sentinel";
        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
        defer arg_regs.deinit();
        var release_regs = std.ArrayList(?[]const u8).init(self.allocator);
        defer release_regs.deinit();
        for (call.args, 0..) |arg, i| {
            self.diag_call_arg_index = i;
            const lowered_arg = try self.genImportedMacroArg(plan, i, arg, hoisted_allocs);
            self.diag_call_arg_index = null;
            var operand_reg = lowered_arg.reg;
            // The macro body forwards this identifier into a callee position
            // that consumes a pointer; pass a fresh copy so the caller's
            // binding stays usable after the expansion.
            if (plan.callArgNeedsConsumeCopy(i) and arg.* == .identifier and !std.mem.startsWith(u8, operand_reg, "&")) {
                const copy_reg = try self.newTmp();
                self.out.writer().print("    {s} = add {s}, 0\n", .{ copy_reg, operand_reg }) catch return CodegenError.CodegenError;
                operand_reg = copy_reg;
            }
            try arg_regs.append(operand_reg);
            release_regs.append(lowered_arg.release_reg orelse if (lowered_arg.release_after_call) lowered_arg.reg else null) catch return CodegenError.OutOfMemory;
        }

        self.out.writer().print("    EXPAND {s}", .{plan.macro_name}) catch return CodegenError.CodegenError;
        if (plan.expression_output) {
            self.out.writer().print(" {s}", .{reg}) catch return CodegenError.CodegenError;
        }
        for (arg_regs.items, 0..) |arg_reg, i| {
            const needs_borrow_prefix = plan.callArgNeedsBorrowPrefix(i) and !std.mem.startsWith(u8, arg_reg, "&");
            if (plan.expression_output or i > 0) {
                if (needs_borrow_prefix) {
                    self.out.writer().print(", &{s}", .{arg_reg}) catch return CodegenError.CodegenError;
                } else {
                    self.out.writer().print(", {s}", .{arg_reg}) catch return CodegenError.CodegenError;
                }
            } else {
                if (needs_borrow_prefix) {
                    self.out.writer().print(" &{s}", .{arg_reg}) catch return CodegenError.CodegenError;
                } else {
                    self.out.writer().print(" {s}", .{arg_reg}) catch return CodegenError.CodegenError;
                }
            }
        }
        self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;

        for (release_regs.items) |release_reg| {
            if (release_reg) |arg_reg| try self.emitRelease(arg_reg);
        }

        return reg;
    }

    fn genArrayBorrowToSliceInto(self: *Codegen, target: []const u8, arg: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!?[]const u8 {
        if (arg.* != .borrow_expr) return CodegenError.CodegenError;
        const inner = arg.borrow_expr.expr;
        const inner_ty = self.resolvedTypeForExpr(inner) orelse return CodegenError.CodegenError;
        const arr = arrayType(inner_ty) orelse return CodegenError.CodegenError;

        const base_source_reg = try self.genExpr(inner, hoisted_allocs);
        const base_reg = if (inner.* == .identifier and self.global_const_bindings.contains(inner.identifier)) blk: {
            const addr_reg = try self.newTmp();
            self.out.writer().print("    {s} = &{s}\n", .{ addr_reg, base_source_reg }) catch return CodegenError.CodegenError;
            break :blk addr_reg;
        } else base_source_reg;

        const len_reg = try self.newTmp();
        try self.emitIntConst(len_reg, @as(i64, @intCast(arr.len)));
        self.stack_alloc_bindings.put(target, {}) catch return CodegenError.OutOfMemory;
        self.out.writer().print("    {s} = stack_alloc Slice_SIZE\n", .{target}) catch return CodegenError.CodegenError;
        self.out.writer().print("    EXPAND SLICE_NEW {s}, {s}, {s}\n", .{ target, base_reg, len_reg }) catch return CodegenError.CodegenError;
        try self.emitRelease(len_reg);
        if (!std.mem.eql(u8, base_reg, base_source_reg)) try self.emitRelease(base_reg);
        return if (exprResultNeedsRelease(inner)) base_source_reg else null;
    }

    fn genArrayBorrowToSliceArg(self: *Codegen, arg: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!LoweredCallArg {
        const slice_reg = try self.newTmp();
        const base_release_reg = try self.genArrayBorrowToSliceInto(slice_reg, arg, hoisted_allocs);
        const borrow_arg = std.fmt.allocPrint(self.allocator, "&{s}", .{slice_reg}) catch return CodegenError.OutOfMemory;
        return .{ .reg = borrow_arg, .release_after_call = false, .release_reg = base_release_reg };
    }

    fn genOwnedStringLiteral(self: *Codegen, value: []const u8, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        _ = hoisted_allocs;
        const label = try self.newStringConst();
        self.out.writer().print("    @const {s} = utf8:\"{s}\"\n", .{ label, value }) catch return CodegenError.CodegenError;
        const len_reg = try self.newTmp();
        try self.emitIntConst(len_reg, @as(i64, @intCast(escapedStringByteLen(value))));
        const bytes_reg = try self.newTmp();
        self.stack_alloc_bindings.put(bytes_reg, {}) catch return CodegenError.OutOfMemory;
        self.out.writer().print("    {s} = stack_alloc Slice_SIZE\n", .{bytes_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    EXPAND SLICE_NEW {s}, &{s}, {s}\n", .{ bytes_reg, label, len_reg }) catch return CodegenError.CodegenError;
        try self.emitRelease(len_reg);
        const string_reg = try self.newTmp();
        self.string_buf_bindings.put(string_reg, {}) catch return CodegenError.OutOfMemory;
        self.out.writer().print("    EXPAND STRING_BUF_FROM_UTF8_UNCHECKED {s}, {s}\n", .{ string_reg, bytes_reg }) catch return CodegenError.CodegenError;
        return string_reg;
    }

    fn genRawPointerStringLiteralArg(self: *Codegen, value: []const u8) CodegenError![]const u8 {
        const label = try self.newStringConst();
        // Append a NUL so a `ptr` argument can also be scanned as a C string
        // (CSTR_LEN terminates at the first zero byte); explicit-length users
        // pass `escapedStringByteLen(value)`, which excludes this terminator.
        self.out.writer().print("    @const {s} = utf8:\"{s}\\0\"\n", .{ label, value }) catch return CodegenError.CodegenError;
        const ptr_reg = try self.newTmp();
        self.out.writer().print("    {s} = &{s}\n", .{ ptr_reg, label }) catch return CodegenError.CodegenError;
        return ptr_reg;
    }

    fn callArgNeedsRelease(arg: *const ast.Node) bool {
        return lowering_rules.callArgNeedsRelease(arg);
    }

    fn exprResultNeedsRelease(expr: *const ast.Node) bool {
        return lowering_rules.exprResultNeedsRelease(expr);
    }

    fn exprResultRegNeedsRelease(self: *Codegen, expr: *const ast.Node) bool {
        if (expr.* == .cast_expr) {
            const cast = expr.cast_expr;
            const src_ty = self.resolvedTypeForExpr(cast.expr) orelse self.tc.expr_types.get(cast.expr) orelse return exprResultNeedsRelease(expr);
            return lowering_rules.castResultMaterializesTemp(src_ty, cast.ty);
        }
        return exprResultNeedsRelease(expr);
    }

    fn fieldBaseResultNeedsRelease(self: *Codegen, expr: *const ast.Node, generated_reg: []const u8) bool {
        const generated_is_resolved_binding = expr.* == .identifier and
            std.mem.eql(u8, generated_reg, self.resolveBindingName(expr.identifier));
        return lowering_rules.fieldBaseResultNeedsRelease(
            exprResultNeedsRelease(expr),
            isTemporaryRegisterName(generated_reg),
            generated_is_resolved_binding,
        );
    }

    fn isSwitchDefaultPattern(pattern: *const ast.Node) bool {
        return lowering_rules.isSwitchDefaultPattern(pattern);
    }

    fn generatedFnPtrIdentifierArg(self: *Codegen, arg: *const ast.Node) bool {
        const arg_ty = self.tc.expr_types.get(arg);
        return lowering_rules.identifierIsGeneratedFnPtr(
            arg,
            arg.* == .identifier and self.tc.funcs.contains(arg.identifier),
            if (arg_ty) |ty| ty.* == .fn_ptr else false,
        );
    }

    fn generatedScalarConstIdentifierArg(self: *Codegen, arg: *const ast.Node) bool {
        return lowering_rules.identifierIsGeneratedScalarConst(
            arg,
            arg.* == .identifier and self.global_scalar_consts.contains(arg.identifier),
        );
    }

    fn storedIdentifierNeedsRelease(self: *Codegen, value: *const ast.Node, value_ty: *const ast.Type) bool {
        return lowering_rules.storedValueMovesIdentifier(value, value_ty, self.typeIsCopyValue(value_ty)) != null;
    }

    fn finishStoredValueAfterSlotStore(self: *Codegen, value: *const ast.Node, value_ty: *const ast.Type, value_reg: []const u8) CodegenError!void {
        if (self.storedIdentifierNeedsRelease(value, value_ty)) {
            try self.emitForgetMovedValue(value_reg);
            return;
        }
        if (!callArgNeedsRelease(value)) return;
        if (std.mem.eql(u8, typeString(value_ty), "ptr") or (!self.typeIsCopyValue(value_ty) and !lowering_rules.isBorrowLikeType(value_ty))) {
            try self.emitForgetMovedValue(value_reg);
            return;
        }
        try self.emitRelease(value_reg);
    }

    fn genLoadSlotValue(self: *Codegen, ptr_reg: []const u8, ty: *const ast.Type) CodegenError![]const u8 {
        const loaded = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ loaded, ptr_reg, typeString(ty) }) catch return CodegenError.CodegenError;
        if (self.slotCopyStructType(ty)) |copy_ty| {
            if (self.typeIsCopyStruct(copy_ty)) {
                const copied = try self.newTmp();
                try self.genCopyValueInto(copied, loaded, copy_ty);
                try self.emitForgetMovedValue(loaded);
                return copied;
            }
            if (self.typeIsSmallPlainSlotStruct(copy_ty)) {
                const copied = try self.genShallowCopyCallArgValue(loaded, copy_ty);
                try self.emitForgetMovedValue(loaded);
                return copied;
            }
        }
        return loaded;
    }

    fn valueArgTransfersOwnership(self: *Codegen, param: ?ast.Param, arg_ty: ?*const ast.Type) bool {
        const ty = arg_ty orelse if (param) |p| p.ty else null;
        return lowering_rules.valueArgTransfersOwnershipFromParam(
            param,
            arg_ty,
            if (ty) |t| self.typeIsCopyValue(t) else false,
        );
    }

    fn isNonOwningPointerCarrierCastArg(arg: *const ast.Node) bool {
        return lowering_rules.isNonOwningPointerCarrierCastArg(arg);
    }

    fn exprConsumesIdentifier(expr: *const ast.Node, name: []const u8) bool {
        return switch (expr.*) {
            .identifier, .literal => false,
            .await_expr => |aw| aw.expr.* == .identifier and std.mem.eql(u8, aw.expr.identifier, name) or exprConsumesIdentifier(aw.expr, name),
            .move_expr => |mv| mv.expr.* == .identifier and std.mem.eql(u8, mv.expr.identifier, name) or exprConsumesIdentifier(mv.expr, name),
            .borrow_expr => |borrow| exprConsumesIdentifier(borrow.expr, name),
            .deref_expr => |deref| exprConsumesIdentifier(deref.expr, name),
            .cast_expr => |cast| exprConsumesIdentifier(cast.expr, name),
            .field_expr => |field| exprConsumesIdentifier(field.expr, name),
            .index_expr => |idx| exprConsumesIdentifier(idx.target, name) or exprConsumesIdentifier(idx.index, name),
            .slice_expr => |slc| exprConsumesIdentifier(slc.target, name) or exprConsumesIdentifier(slc.start, name) or exprConsumesIdentifier(slc.end, name),
            .binary_expr => |bin| exprConsumesIdentifier(bin.left, name) or exprConsumesIdentifier(bin.right, name),
            .call_expr => |call| blk: {
                for (call.args) |arg| if (exprConsumesIdentifier(arg, name)) break :blk true;
                break :blk false;
            },
            .closure_literal => |lit| exprConsumesIdentifier(lit.body, name),
            .try_expr => |trye| exprConsumesIdentifier(trye.expr, name),
            .if_expr => |ife| exprConsumesIdentifier(ife.cond, name) or ifLetChainConsumesIdentifier(ife.let_chain, name) or blockConsumesIdentifier(ife.then_block, name) or if (ife.else_block) |eb| blockConsumesIdentifier(eb, name) else false,
            .switch_expr => |swe| blk: {
                if (exprConsumesIdentifier(swe.val, name)) break :blk true;
                for (swe.cases) |case| if (exprConsumesIdentifier(case.pattern, name) or blockConsumesIdentifier(case.body, name)) break :blk true;
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (exprConsumesIdentifier(mat.val, name)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| if (exprConsumesIdentifier(guard, name)) break :blk true;
                    if (blockConsumesIdentifier(case.body, name)) break :blk true;
                }
                break :blk false;
            },
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| if (exprConsumesIdentifier(field.value, name)) break :blk true;
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| if (exprConsumesIdentifier(field.value, name)) break :blk true;
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| if (exprConsumesIdentifier(elem, name)) break :blk true;
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| if (exprConsumesIdentifier(elem, name)) break :blk true;
                break :blk false;
            },
            .repeat_array_literal => |lit| exprConsumesIdentifier(lit.value, name),
            else => false,
        };
    }

    fn stmtConsumesIdentifier(stmt: *const ast.Node, name: []const u8) bool {
        return switch (stmt.*) {
            .let_stmt => |let| exprConsumesIdentifier(let.value, name),
            .let_else_stmt => |let| exprConsumesIdentifier(let.value, name) or blockConsumesIdentifier(let.else_block, name),
            .let_destructure_stmt => |let| exprConsumesIdentifier(let.value, name),
            .const_stmt => |c| exprConsumesIdentifier(c.value, name),
            .assign_stmt => |assign| exprConsumesIdentifier(assign.target, name) or exprConsumesIdentifier(assign.value, name),
            .expr_stmt => |expr| exprConsumesIdentifier(expr, name),
            .return_stmt => |ret| if (ret.value) |v| exprConsumesIdentifier(v, name) else false,
            .for_stmt => |f| exprConsumesIdentifier(f.start, name) or (if (f.end) |end_expr| exprConsumesIdentifier(end_expr, name) else false) or blockConsumesIdentifier(f.body, name),
            .while_stmt => |w| exprConsumesIdentifier(w.cond, name) or blockConsumesIdentifier(w.body, name),
            .block_stmt => |blk| blockConsumesIdentifier(blk.body, name),
            else => false,
        };
    }

    fn blockConsumesIdentifier(block: []const *ast.Node, name: []const u8) bool {
        for (block) |stmt| if (stmtConsumesIdentifier(stmt, name)) return true;
        return false;
    }

    fn genHashMapKeyReg(self: *Codegen, arg: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        if (arg.* == .literal and arg.literal == .string_val) {
            const value = arg.literal.string_val;
            if (self.hashmap_key_slots.get(value)) |slot| return slot;

            const slot = try self.newTmp();
            const owned_slot = self.allocator.dupe(u8, slot) catch return CodegenError.OutOfMemory;
            self.hashmap_key_slots.put(value, owned_slot) catch return CodegenError.OutOfMemory;

            const label = try self.newStringConst();
            self.out.writer().print("    @const {s} = utf8:\"{s}\"\n", .{ label, value }) catch return CodegenError.CodegenError;
            const len_reg = try self.newTmp();
            try self.emitIntConst(len_reg, @as(i64, @intCast(escapedStringByteLen(value))));
            self.stack_alloc_bindings.put(slot, {}) catch return CodegenError.OutOfMemory;
            self.out.writer().print("    {s} = stack_alloc Slice_SIZE\n", .{slot}) catch return CodegenError.CodegenError;
            self.out.writer().print("    EXPAND SLICE_NEW {s}, &{s}, {s}\n", .{ slot, label, len_reg }) catch return CodegenError.CodegenError;
            try self.emitRelease(len_reg);
            return slot;
        }
        return try self.genExpr(arg, hoisted_allocs);
    }

    fn genHashMapValueSlot(self: *Codegen, arg: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        const value_reg = try self.genExpr(arg, hoisted_allocs);
        const slot = try self.newTmp();
        self.stack_alloc_bindings.put(slot, {}) catch return CodegenError.OutOfMemory;
        self.out.writer().print("    {s} = stack_alloc 8\n", .{slot}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {s} as u64\n", .{ slot, value_reg }) catch return CodegenError.CodegenError;
        if (callArgNeedsRelease(arg)) try self.emitRelease(value_reg);
        return slot;
    }

    fn stackAllocSize(self: *Codegen, call: *const ast.CallExpr) i64 {
        if (call.args.len > 0) {
            if (lowering_rules.intConstantExprValue(call.args[0], self.global_scalar_consts)) |value| return value;
        }
        return 16;
    }

    fn isStackAllocCall(node: *const ast.Node) bool {
        return lowering_rules.isStackAllocNode(node);
    }

    /// Tracked wrapper: remembers which statement was being lowered so a
    /// failing CodegenError can be reported with statement context.
    fn genStmt(self: *Codegen, stmt: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!void {
        const prev_stmt = self.diag_stmt_node;
        self.diag_stmt_node = stmt;
        const result = self.genStmtImpl(stmt, hoisted_allocs);
        if (result) |_| {
            self.diag_stmt_node = prev_stmt;
            self.diag_call_arg_index = null;
        } else |err| {
            self.synthesizeDiagFromContext(err);
            self.diag_stmt_node = prev_stmt;
            self.diag_call_arg_index = null;
            return err;
        }
    }

    fn genStmtImpl(self: *Codegen, stmt: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!void {
        switch (stmt.*) {
            .let_stmt => |let| {
                // If it is a hoisted loop allocation, we bypass stack_alloc emission since it is pre-allocated
                var is_hoisted = false;
                for (hoisted_allocs.items) |h| {
                    if (std.mem.eql(u8, let.name, h)) {
                        is_hoisted = true;
                        break;
                    }
                }

                const let_ty = if (let.ty) |explicit| explicit else blk: {
                    // An imported-macro expression result whose result type the
                    // type checker could not name comes back as `.infer`. SA
                    // registers are 64-bit, so a scalar default keeps such
                    // bindings usable (e.g. passed on to further macros);
                    // without it the binding stays untyped and later uses
                    // fail with "no resolvable type".
                    if (self.resolvedTypeForExpr(let.value)) |ty| break :blk ty;
                    if (self.importedMacroExpressionOutputCall(let.value)) break :blk try self.makePrimitiveType(.i64);
                    break :blk (self.tc.expr_types.get(let.value)) orelse return CodegenError.CodegenError;
                };
                if (lowering_rules.isDiscardName(let.name)) {
                    const discard_reg = try self.genExpr(let.value, hoisted_allocs);
                    if (self.async_pending_return_emitted) return;
                    // Match type-checker discard moves: `let _ = owner` must
                    // consume by-value non-Copy identifiers so if-branch merges
                    // do not leave Active vs Consumed PhiStateConflict.
                    if (let.value.* == .identifier) {
                        const value_ty = self.resolvedTypeForExpr(let.value) orelse self.tc.expr_types.get(let.value);
                        if (value_ty) |ty| {
                            if (!self.typeIsCopyValue(ty) and !lowering_rules.isBorrowLikeType(ty)) {
                                try self.emitForgetMovedValue(discard_reg);
                                return;
                            }
                        }
                    }
                    if (callArgNeedsRelease(let.value)) try self.emitRelease(discard_reg);
                    return;
                }
                try self.rememberLocalBindingType(let.name, let_ty);
                if (isFormatStringType(let_ty)) {
                    self.string_buf_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                }
                try self.markOwnedCollectionBinding(let.name, let_ty);
                if (is_hoisted) {
                    self.out.writer().print("    // Hoisted stack slot {s} initialized\n", .{let.name}) catch return CodegenError.CodegenError;
                } else if (let.value.* == .call_expr and let.value.call_expr.associated_target != null and std.mem.eql(u8, let.value.call_expr.associated_target.?, "AtomicI32") and std.mem.eql(u8, let.value.call_expr.func_name, "new")) {
                    const call = &let.value.call_expr;
                    if (call.args.len != 1) return CodegenError.CodegenError;
                    const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    self.stack_alloc_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc AtomicI32_SIZE\n", .{let.name}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND ATOMIC_I32_INIT {s}, {s}\n", .{ let.name, value_reg }) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                } else if (let.value.* == .call_expr and let.value.call_expr.associated_target != null and std.mem.eql(u8, let.value.call_expr.associated_target.?, "AtomicUsize") and std.mem.eql(u8, let.value.call_expr.func_name, "new")) {
                    const call = &let.value.call_expr;
                    if (call.args.len != 1) return CodegenError.CodegenError;
                    const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    self.stack_alloc_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc AtomicUsize_SIZE\n", .{let.name}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND ATOMIC_USIZE_INIT {s}, {s}\n", .{ let.name, value_reg }) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                } else if (let.value.* == .call_expr and let.value.call_expr.associated_target != null and std.mem.eql(u8, let.value.call_expr.associated_target.?, "AtomicPtr") and std.mem.eql(u8, let.value.call_expr.func_name, "new")) {
                    const call = &let.value.call_expr;
                    if (call.args.len != 1) return CodegenError.CodegenError;
                    const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    self.stack_alloc_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc AtomicPtr_SIZE\n", .{let.name}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND ATOMIC_PTR_INIT {s}, {s}\n", .{ let.name, value_reg }) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                } else if (let.value.* == .call_expr and let.value.call_expr.associated_target != null and std.mem.eql(u8, let.value.call_expr.associated_target.?, "Cell") and std.mem.eql(u8, let.value.call_expr.func_name, "new")) {
                    const call = &let.value.call_expr;
                    if (call.args.len != 1) return CodegenError.CodegenError;
                    const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    self.stack_alloc_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc Cell_SIZE\n", .{let.name}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND CELL_SET {s}, {s}\n", .{ let.name, value_reg }) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                } else if (let.value.* == .call_expr and lowering_rules.isManuallyDropNewCall(let.value.call_expr)) {
                    const call = &let.value.call_expr;
                    if (call.args.len != 1) return CodegenError.CodegenError;
                    const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    self.stack_alloc_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc ManuallyDropU64_SIZE\n", .{let.name}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND MANUALLY_DROP_U64_NEW {s}, {s}\n", .{ let.name, value_reg }) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                } else if (let.value.* == .borrow_expr and sliceElementType(let_ty) != null) {
                    const borrowed_ty = self.tc.expr_types.get(let.value) orelse return CodegenError.CodegenError;
                    if (borrowed_ty.* == .borrow and arrayType(borrowed_ty.borrow) != null) {
                        _ = try self.genArrayBorrowToSliceInto(let.name, let.value, hoisted_allocs);
                    } else {
                        const val_reg = try self.genExpr(let.value, hoisted_allocs);
                        self.out.writer().print("    {s} = {s}\n", .{ let.name, val_reg }) catch return CodegenError.CodegenError;
                    }
                } else if (self.bindingNeedsAddressableStorage(let.name, let_ty) and !isStackAllocCall(let.value)) {
                    const val_reg = try self.genExpr(let.value, hoisted_allocs);
                    if (self.async_pending_return_emitted) return;
                    self.stack_alloc_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc {}\n", .{ let.name, typeSize(let_ty) }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ let.name, val_reg, typeString(let_ty) }) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(let.value)) try self.emitRelease(val_reg);
                } else if (self.bindingNeedsAssignedValueSlot(let.name, let_ty) and !isStackAllocCall(let.value)) {
                    const val_reg = try self.genExpr(let.value, hoisted_allocs);
                    if (self.async_pending_return_emitted) return;
                    self.stack_alloc_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                    self.assigned_value_slots.put(let.name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc {}\n", .{ let.name, typeSize(let_ty) }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ let.name, val_reg, typeString(let_ty) }) catch return CodegenError.CodegenError;
                    if (self.refcell_borrow_handles.contains(val_reg)) {
                        try self.storeResultSlotTransferredValueState(let.name, val_reg, let_ty, callArgNeedsRelease(let.value));
                    } else if (callArgNeedsRelease(let.value)) try self.emitRelease(val_reg);
                    if (self.storedIdentifierNeedsRelease(let.value, let_ty)) try self.markConsumedBinding(val_reg);
                } else if (isStackAllocCall(let.value)) {
                    self.stack_alloc_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc {}\n", .{ let.name, self.stackAllocSize(&let.value.call_expr) }) catch return CodegenError.CodegenError;
                } else if (let.value.* == .literal and let.value.literal == .string_val) {
                    const value = let.value.literal.string_val;
                    const label = try self.newStringConst();
                    self.out.writer().print("    @const {s} = utf8:\"{s}\"\n", .{ label, value }) catch return CodegenError.CodegenError;
                    const len_reg = try self.newTmp();
                    try self.emitIntConst(len_reg, @as(i64, @intCast(escapedStringByteLen(value))));
                    self.stack_alloc_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc Slice_SIZE\n", .{let.name}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND SLICE_NEW {s}, &{s}, {s}\n", .{ let.name, label, len_reg }) catch return CodegenError.CodegenError;
                    try self.emitRelease(len_reg);
                } else if (let.value.* == .closure_literal) {
                    try self.closure_bindings.put(let.name, &let.value.closure_literal);
                    self.out.writer().print("    {s} = 0\n", .{let.name}) catch return CodegenError.CodegenError;
                } else if (let.value.* == .struct_literal) {
                    try self.genStructLiteralInto(let.name, &let.value.struct_literal, hoisted_allocs);
                } else if (let.value.* == .enum_literal) {
                    try self.genEnumLiteralInto(let.name, &let.value.enum_literal, hoisted_allocs);
                } else if (let.value.* == .tuple_literal) {
                    try self.genTupleLiteralInto(let.name, &let.value.tuple_literal, hoisted_allocs);
                } else if (let.value.* == .array_literal) {
                    try self.genArrayLiteralInto(let.name, &let.value.array_literal, hoisted_allocs);
                } else if (let.value.* == .repeat_array_literal) {
                    try self.genRepeatArrayLiteralInto(let.name, let.value, &let.value.repeat_array_literal, hoisted_allocs);
                } else if (let.value.* == .identifier and self.typeIsCopyStruct(let_ty)) {
                    const source_reg = try self.genExpr(let.value, hoisted_allocs);
                    try self.genCopyValueInto(let.name, source_reg, let_ty);
                } else if (lowering_rules.planDynCoercion(self.tc, let.value)) |plan| {
                    const val_reg = try self.genDynCoercionExpr(let.value, plan, hoisted_allocs);
                    self.out.writer().print("    {s} = {s}\n", .{ let.name, val_reg }) catch return CodegenError.CodegenError;
                } else {
                    const val_reg = try self.genExpr(let.value, hoisted_allocs);
                    if (self.async_pending_return_emitted) return;
                    if (self.task_future_objects.get(val_reg)) |future_obj| {
                        self.task_future_objects.put(let.name, future_obj) catch return CodegenError.OutOfMemory;
                        _ = self.task_future_objects.remove(val_reg);
                    }
                    if (self.future_state_vtables.get(val_reg)) |vt_name| {
                        self.future_state_vtables.put(let.name, vt_name) catch return CodegenError.OutOfMemory;
                        _ = self.future_state_vtables.remove(val_reg);
                    }
                    try self.transferFutureReadiness(val_reg, let.name);
                    if (self.executor_task_counts.get(val_reg)) |task_count| {
                        self.executor_task_counts.put(let.name, task_count) catch return CodegenError.OutOfMemory;
                        _ = self.executor_task_counts.remove(val_reg);
                    }
                    if (self.inline_thread_handles.contains(val_reg)) {
                        self.inline_thread_handles.put(let.name, {}) catch return CodegenError.OutOfMemory;
                        _ = self.inline_thread_handles.remove(val_reg);
                    }
                    if (self.stack_alloc_bindings.contains(val_reg)) {
                        self.stack_alloc_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                    }
                    if (self.mpsc_sender_bindings.contains(val_reg)) {
                        self.mpsc_sender_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                        if (self.mpsc_sender_channels.get(val_reg)) |chan| {
                            self.mpsc_sender_channels.put(let.name, chan) catch return CodegenError.OutOfMemory;
                        }
                        _ = self.mpsc_sender_bindings.remove(val_reg);
                        _ = self.mpsc_sender_channels.remove(val_reg);
                        self.consumed_bindings.put(val_reg, {}) catch return CodegenError.OutOfMemory;
                    }
                    const refcell_handle = self.refcell_borrow_handles.get(val_reg);
                    const refcell_transfer_plan = lowering_rules.planRefCellValueStateTransfer(
                        refcell_handle != null,
                        self.borrow_source_temps.contains(val_reg),
                    );
                    const handle_binding = lowering_rules.planRefCellHandleBinding(refcell_transfer_plan.handle.movesBorrowHandle());
                    if (handle_binding.bindsBorrowHandle()) {
                        const handle = refcell_handle.?;
                        self.refcell_borrow_handles.put(let.name, handle) catch return CodegenError.OutOfMemory;
                        _ = self.refcell_borrow_handles.remove(val_reg);
                        self.consumed_bindings.put(val_reg, {}) catch return CodegenError.OutOfMemory;
                    }
                    if (self.mutex_guard_handles.get(val_reg)) |handle| {
                        self.mutex_guard_handles.put(let.name, handle) catch return CodegenError.OutOfMemory;
                        _ = self.mutex_guard_handles.remove(val_reg);
                        self.consumed_bindings.put(val_reg, {}) catch return CodegenError.OutOfMemory;
                    }
                    if (self.mutex_lock_results.get(val_reg)) |handle| {
                        self.mutex_lock_results.put(let.name, handle) catch return CodegenError.OutOfMemory;
                        _ = self.mutex_lock_results.remove(val_reg);
                        self.consumed_bindings.put(val_reg, {}) catch return CodegenError.OutOfMemory;
                    }
                    if (self.rwlock_guard_handles.get(val_reg)) |handle| {
                        self.rwlock_guard_handles.put(let.name, handle) catch return CodegenError.OutOfMemory;
                        _ = self.rwlock_guard_handles.remove(val_reg);
                        self.consumed_bindings.put(val_reg, {}) catch return CodegenError.OutOfMemory;
                    }
                    if (self.rwlock_lock_results.get(val_reg)) |handle| {
                        self.rwlock_lock_results.put(let.name, handle) catch return CodegenError.OutOfMemory;
                        _ = self.rwlock_lock_results.remove(val_reg);
                        self.consumed_bindings.put(val_reg, {}) catch return CodegenError.OutOfMemory;
                    }
                    if (refcell_transfer_plan.borrow_address_temps.movesBorrowAddressTemps()) {
                        if (self.borrow_source_temps.get(val_reg)) |source_temp| {
                            self.borrow_source_temps.put(let.name, source_temp) catch return CodegenError.OutOfMemory;
                            _ = self.borrow_source_temps.remove(val_reg);
                        }
                    }
                    self.rebindRefCellBorrowHandleOwners(val_reg, let.name);
                    const let_value_is_copy = let_ty.* == .primitive or let_ty.* == .fn_ptr or self.typeIsCopyStruct(let_ty);
                    if (lowering_rules.storedValueMovesIdentifier(let.value, let_ty, let_value_is_copy) != null) {
                        try self.markConsumedBinding(val_reg);
                    }
                    if (self.file_bindings.contains(val_reg)) {
                        self.file_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                        _ = self.file_bindings.remove(val_reg);
                        self.consumed_bindings.put(val_reg, {}) catch return CodegenError.OutOfMemory;
                    }
                    if (self.file_open_results.get(val_reg)) |handle| {
                        self.file_open_results.put(let.name, handle) catch return CodegenError.OutOfMemory;
                        _ = self.file_open_results.remove(val_reg);
                        self.consumed_bindings.put(val_reg, {}) catch return CodegenError.OutOfMemory;
                    }
                    if (self.metadata_bindings.contains(val_reg)) {
                        self.metadata_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                        _ = self.metadata_bindings.remove(val_reg);
                        self.consumed_bindings.put(val_reg, {}) catch return CodegenError.OutOfMemory;
                    }
                    if (self.metadata_open_results.get(val_reg)) |handle| {
                        self.metadata_open_results.put(let.name, handle) catch return CodegenError.OutOfMemory;
                        _ = self.metadata_open_results.remove(val_reg);
                        self.consumed_bindings.put(val_reg, {}) catch return CodegenError.OutOfMemory;
                    }
                    if (let_ty.* == .primitive) {
                        try self.emitPrimitiveCopy(let.name, val_reg, let_ty);
                        if (callArgNeedsRelease(let.value)) try self.emitRelease(val_reg);
                    } else {
                        self.out.writer().print("    {s} = {s}\n", .{ let.name, val_reg }) catch return CodegenError.CodegenError;
                    }
                }
            },
            .var_stmt => |v| {
                try self.rememberLocalBindingType(v.name, v.ty);
                const slot_name = self.resolveBindingName(v.name);
                self.stack_alloc_bindings.put(slot_name, {}) catch return CodegenError.OutOfMemory;
                self.addressable_bindings.put(slot_name, {}) catch return CodegenError.OutOfMemory;
                self.out.writer().print("    {s} = stack_alloc {}\n", .{ slot_name, typeSize(v.ty) }) catch return CodegenError.CodegenError;
            },
            .let_else_stmt => |let| {
                const value_reg = try self.genExpr(let.value, hoisted_allocs);
                const branch_flag = try self.newTmp();
                const success_label = try self.newLabel("L_LET_ELSE_OK");
                const else_label = try self.newLabel("L_LET_ELSE_ELSE");
                const cont_label = try self.newLabel("L_LET_ELSE_CONT");
                const enum_decl = try self.enumDeclForPatternValue(let.value, let.pattern);

                const success_on_true = enum_decl != null or std.mem.eql(u8, let.pattern.variant_name, "Some") or std.mem.eql(u8, let.pattern.variant_name, "Ok");
                if (enum_decl) |decl| {
                    try self.genEnumPatternCheck(decl, let.pattern, value_reg, branch_flag);
                } else if (patternUsesResultMacros(let.pattern)) {
                    self.out.writer().print("    EXPAND RESULT_IS_OK {s}, {s}\n", .{ branch_flag, value_reg }) catch return CodegenError.CodegenError;
                } else {
                    self.out.writer().print("    EXPAND OPTION_IS_SOME {s}, {s}\n", .{ branch_flag, value_reg }) catch return CodegenError.CodegenError;
                }
                if (success_on_true) {
                    self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ branch_flag, success_label, else_label }) catch return CodegenError.CodegenError;
                } else {
                    self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ branch_flag, else_label, success_label }) catch return CodegenError.CodegenError;
                }

                var pre_else_consumed = self.consumed_bindings.clone() catch return CodegenError.OutOfMemory;
                defer pre_else_consumed.deinit();
                var pre_else_borrow_sources = self.borrow_source_temps.clone() catch return CodegenError.OutOfMemory;
                defer pre_else_borrow_sources.deinit();
                var pre_else_refcell_handles = self.refcell_borrow_handles.clone() catch return CodegenError.OutOfMemory;
                defer pre_else_refcell_handles.deinit();

                self.out.writer().print("{s}:\n", .{else_label}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{branch_flag}) catch return CodegenError.CodegenError;
                if (callArgNeedsRelease(let.value)) try self.emitRelease(value_reg);
                try self.genBlock(let.else_block, hoisted_allocs);
                if (!blockTerminates(let.else_block)) {
                    self.out.writer().print("    jmp {s}\n", .{cont_label}) catch return CodegenError.CodegenError;
                }
                self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;
                try self.restoreConsumedBindings(&pre_else_consumed);
                try self.restoreBorrowSourceTemps(&pre_else_borrow_sources);
                try self.restoreRefCellBorrowHandles(&pre_else_refcell_handles);

                self.out.writer().print("{s}:\n", .{success_label}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{branch_flag}) catch return CodegenError.CodegenError;
                if (enum_decl) |decl| {
                    try self.genEnumPatternBindings(decl, let.pattern, value_reg);
                } else if (std.mem.eql(u8, let.pattern.variant_name, "Some") and let.pattern.bindings.len == 1) {
                    const binding = let.pattern.bindings[0];
                    const target = try self.pushBindingAlias(binding);
                    self.out.writer().print("    EXPAND OPTION_GET {s}, {s}\n", .{ target, value_reg }) catch return CodegenError.CodegenError;
                } else if (std.mem.eql(u8, let.pattern.variant_name, "Ok") and let.pattern.bindings.len == 1) {
                    const binding = let.pattern.bindings[0];
                    const target = try self.pushBindingAlias(binding);
                    self.out.writer().print("    EXPAND RESULT_GET_OK {s}, {s}\n", .{ target, value_reg }) catch return CodegenError.CodegenError;
                } else if (std.mem.eql(u8, let.pattern.variant_name, "Err") and let.pattern.bindings.len == 1) {
                    const binding = let.pattern.bindings[0];
                    const target = try self.pushBindingAlias(binding);
                    self.out.writer().print("    EXPAND RESULT_GET_ERR {s}, {s}\n", .{ target, value_reg }) catch return CodegenError.CodegenError;
                }
                if (callArgNeedsRelease(let.value)) try self.emitRelease(value_reg);
                self.out.writer().print("    jmp {s}\n\n", .{cont_label}) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{cont_label}) catch return CodegenError.CodegenError;
            },
            .let_destructure_stmt => |let| {
                if (let.value.* == .call_expr) {
                    const call = &let.value.call_expr;
                    if (lowering_rules.isMpscChannelCall(call.*)) {
                        if (let.names.len != 2) return CodegenError.CodegenError;
                        // The channel object must not live under the receiver's
                        // name: the receiver is routinely moved into a worker
                        // thread, and tx.send() expands to &<channel reg>.
                        // Emit into a dedicated temp and alias both ends to it.
                        const chan_reg = try self.newTmp();
                        self.out.writer().print("    {s} = 0\n", .{let.names[0]}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND MPSC_NEW {s}, 1024\n", .{chan_reg}) catch return CodegenError.CodegenError;
                        self.mpsc_sender_bindings.put(let.names[0], {}) catch return CodegenError.OutOfMemory;
                        self.mpsc_sender_channels.put(let.names[0], chan_reg) catch return CodegenError.OutOfMemory;
                        self.mpsc_sender_channels.put(let.names[1], chan_reg) catch return CodegenError.OutOfMemory;
                        self.mpsc_receiver_bindings.put(chan_reg, {}) catch return CodegenError.OutOfMemory;
                        const rx_alias = try self.pushBindingAlias(let.names[1]);
                        self.out.writer().print("    {s} = add {s}, 0\n", .{ rx_alias, chan_reg }) catch return CodegenError.CodegenError;
                        return;
                    }
                }
                const value_reg = try self.genExpr(let.value, hoisted_allocs);
                const value_ty = self.tc.expr_types.get(let.value) orelse return CodegenError.CodegenError;
                if (let.is_slice) {
                    const elem_ty = if (arrayType(value_ty)) |arr| arr.elem else if (sliceElementType(value_ty)) |elem| elem else return CodegenError.CodegenError;
                    const base_ptr = try self.newTmp();
                    const len_reg = try self.newTmp();
                    if (value_ty.* == .array) {
                        self.out.writer().print("    {s} = &{s}\n", .{ base_ptr, value_reg }) catch return CodegenError.CodegenError;
                        try self.emitIntConst(len_reg, @as(i64, @intCast(value_ty.array.len)));
                    } else {
                        self.out.writer().print("    {s} = load {s}+Slice_ptr as ptr\n", .{ base_ptr, value_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    {s} = load {s}+Slice_len as u64\n", .{ len_reg, value_reg }) catch return CodegenError.CodegenError;
                    }
                    const elem_size = typeSize(elem_ty);
                    var offset: usize = 0;
                    for (let.names) |name| {
                        const reg = try self.newTmp();
                        self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ reg, base_ptr, offset, typeString(elem_ty) }) catch return CodegenError.CodegenError;
                        if (!lowering_rules.isDiscardName(name)) {
                            self.out.writer().print("    {s} = {s}\n", .{ name, reg }) catch return CodegenError.CodegenError;
                        }
                        offset += elem_size;
                    }
                    if (let.rest_name) |rest_name| {
                        if (lowering_rules.isDiscardName(rest_name)) {
                            try self.emitRelease(base_ptr);
                            try self.emitRelease(len_reg);
                            if (let.rest_alias) |rest_alias| {
                                if (!lowering_rules.isDiscardName(rest_alias)) {
                                    self.out.writer().print("    {s} = {s}\n", .{ rest_alias, base_ptr }) catch return CodegenError.CodegenError;
                                }
                            }
                            return;
                        }
                        const rest_ptr = try self.newTmp();
                        self.out.writer().print("    {s} = ptr_add {s}, {}\n", .{ rest_ptr, base_ptr, offset }) catch return CodegenError.CodegenError;
                        const rest_len = try self.newTmp();
                        self.out.writer().print("    {s} = sub {s}, {}\n", .{ rest_len, len_reg, let.names.len }) catch return CodegenError.CodegenError;
                        self.stack_alloc_bindings.put(rest_name, {}) catch return CodegenError.OutOfMemory;
                        self.out.writer().print("    {s} = stack_alloc Slice_SIZE\n", .{rest_name}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND SLICE_NEW {s}, {s}, {s}\n", .{ rest_name, rest_ptr, rest_len }) catch return CodegenError.CodegenError;
                        if (let.rest_alias) |rest_alias| {
                            if (!lowering_rules.isDiscardName(rest_alias)) {
                                self.out.writer().print("    {s} = {s}\n", .{ rest_alias, rest_name }) catch return CodegenError.CodegenError;
                            }
                        }
                        try self.emitRelease(rest_ptr);
                        try self.emitRelease(rest_len);
                    }
                    try self.emitRelease(base_ptr);
                    try self.emitRelease(len_reg);
                } else {
                    if (value_ty.* != .tuple) return CodegenError.CodegenError;
                    for (let.names, 0..) |name, i| {
                        const layout = tupleFieldLayout(value_ty.tuple, i) orelse return CodegenError.CodegenError;
                        self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ name, value_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
                    }
                }
                if (!let.is_slice) {
                    try self.emitRelease(value_reg);
                } else if (callArgNeedsRelease(let.value)) {
                    try self.emitRelease(value_reg);
                }
            },
            .const_stmt => |c| {
                const const_ty = if (c.ty) |explicit| explicit else self.resolvedTypeForExpr(c.value) orelse self.tc.expr_types.get(c.value) orelse return CodegenError.CodegenError;
                try self.rememberLocalBindingType(c.name, const_ty);
                try self.markOwnedCollectionBinding(c.name, const_ty);
                if (self.bindingNeedsAddressableStorage(c.name, const_ty)) {
                    const val_reg = try self.genExpr(c.value, hoisted_allocs);
                    self.stack_alloc_bindings.put(c.name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc {}\n", .{ c.name, typeSize(const_ty) }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ c.name, val_reg, typeString(const_ty) }) catch return CodegenError.CodegenError;
                } else if (isStackAllocCall(c.value)) {
                    self.stack_alloc_bindings.put(c.name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc {}\n", .{ c.name, self.stackAllocSize(&c.value.call_expr) }) catch return CodegenError.CodegenError;
                } else if (c.value.* == .closure_literal) {
                    try self.closure_bindings.put(c.name, &c.value.closure_literal);
                    self.out.writer().print("    {s} = 0\n", .{c.name}) catch return CodegenError.CodegenError;
                } else if (c.value.* == .struct_literal) {
                    try self.genStructLiteralInto(c.name, &c.value.struct_literal, hoisted_allocs);
                } else if (c.value.* == .enum_literal) {
                    try self.genEnumLiteralInto(c.name, &c.value.enum_literal, hoisted_allocs);
                } else if (c.value.* == .tuple_literal) {
                    try self.genTupleLiteralInto(c.name, &c.value.tuple_literal, hoisted_allocs);
                } else if (c.value.* == .array_literal) {
                    try self.genArrayLiteralInto(c.name, &c.value.array_literal, hoisted_allocs);
                } else if (c.value.* == .repeat_array_literal) {
                    try self.genRepeatArrayLiteralInto(c.name, c.value, &c.value.repeat_array_literal, hoisted_allocs);
                } else if (c.value.* == .identifier and self.typeIsCopyStruct(const_ty)) {
                    const source_reg = try self.genExpr(c.value, hoisted_allocs);
                    try self.genCopyValueInto(c.name, source_reg, const_ty);
                } else if (lowering_rules.planDynCoercion(self.tc, c.value)) |plan| {
                    const val_reg = try self.genDynCoercionExpr(c.value, plan, hoisted_allocs);
                    self.out.writer().print("    {s} = {s}\n", .{ c.name, val_reg }) catch return CodegenError.CodegenError;
                } else {
                    const val_reg = try self.genExpr(c.value, hoisted_allocs);
                    if (self.task_future_objects.get(val_reg)) |future_obj| {
                        self.task_future_objects.put(c.name, future_obj) catch return CodegenError.OutOfMemory;
                        _ = self.task_future_objects.remove(val_reg);
                    }
                    if (self.future_state_vtables.get(val_reg)) |vt_name| {
                        self.future_state_vtables.put(c.name, vt_name) catch return CodegenError.OutOfMemory;
                        _ = self.future_state_vtables.remove(val_reg);
                    }
                    try self.transferFutureReadiness(val_reg, c.name);
                    if (self.executor_task_counts.get(val_reg)) |task_count| {
                        self.executor_task_counts.put(c.name, task_count) catch return CodegenError.OutOfMemory;
                        _ = self.executor_task_counts.remove(val_reg);
                    }
                    if (self.stack_alloc_bindings.contains(val_reg)) {
                        self.stack_alloc_bindings.put(c.name, {}) catch return CodegenError.OutOfMemory;
                    }
                    if (self.mpsc_sender_bindings.contains(val_reg)) {
                        self.mpsc_sender_bindings.put(c.name, {}) catch return CodegenError.OutOfMemory;
                        if (self.mpsc_sender_channels.get(val_reg)) |chan| {
                            self.mpsc_sender_channels.put(c.name, chan) catch return CodegenError.OutOfMemory;
                        }
                        _ = self.mpsc_sender_bindings.remove(val_reg);
                        _ = self.mpsc_sender_channels.remove(val_reg);
                        self.consumed_bindings.put(val_reg, {}) catch return CodegenError.OutOfMemory;
                    }
                    self.out.writer().print("    {s} = {s}\n", .{ c.name, val_reg }) catch return CodegenError.CodegenError;
                }
            },
            .assign_stmt => |assign| {
                if (assign.target.* == .index_expr) {
                    try self.genIndexAssign(&assign.target.index_expr, assign.value, hoisted_allocs);
                } else if (assign.target.* == .deref_expr) {
                    const target_ty = self.tc.expr_types.get(assign.target.deref_expr.expr) orelse return CodegenError.CodegenError;
                    const inner_ty = mutexGuardInnerType(target_ty) orelse rwLockWriteGuardInnerType(target_ty) orelse switch (target_ty.*) {
                        .borrow => |b| b,
                        .pointer => |p| p,
                        else => return CodegenError.CodegenError,
                    };
                    const target_reg = try self.genExpr(assign.target.deref_expr.expr, hoisted_allocs);
                    const val_reg = try self.genExpr(assign.value, hoisted_allocs);
                    self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ target_reg, val_reg, typeString(inner_ty) }) catch return CodegenError.CodegenError;
                    const target_lifecycle = lowering_rules.planDerefAssignmentTargetLifecycle(
                        assign.target.deref_expr.expr.* != .identifier,
                        self.refcell_borrow_handles.contains(target_reg),
                    );
                    if (target_lifecycle.shouldRelease()) try self.emitRelease(target_reg);
                    if (assign.target.deref_expr.expr.* != .identifier and self.mutex_guard_handles.contains(target_reg)) try self.emitRelease(target_reg);
                    if (assign.target.deref_expr.expr.* != .identifier and self.rwlock_guard_handles.contains(target_reg)) try self.emitRelease(target_reg);
                    try self.finishStoredValueAfterSlotStore(assign.value, inner_ty, val_reg);
                } else if (assign.target.* == .field_expr) {
                    const field = assign.target.field_expr;
                    if (field.expr.* == .index_expr) {
                        const idx = field.expr.index_expr;
                        const idx_target_ty = self.resolvedTypeForExpr(idx.target) orelse return CodegenError.CodegenError;
                        if (vecElementType(idx_target_ty)) |elem_ty| {
                            const layout = try self.fieldAddressLayout(elem_ty, field.field_name);
                            const target_ty = self.resolvedTypeForExpr(assign.target) orelse return CodegenError.CodegenError;
                            const vec_receiver = try self.genVecOwnerReceiver(idx.target, hoisted_allocs);
                            const vec_reg = vec_receiver.reg;
                            const index_reg = try self.genExpr(idx.index, hoisted_allocs);
                            const len_reg = try self.newTmp();
                            const in_bounds_reg = try self.newTmp();
                            const hit_label = try self.newLabel("L_VEC_INDEX_FIELD_ASSIGN_OK");
                            const miss_label = try self.newLabel("L_VEC_INDEX_FIELD_ASSIGN_OOB");
                            self.out.writer().print("    {s} = load {s}+Vec_len as u64\n", .{ len_reg, vec_reg }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    {s} = ult {s}, {s}\n", .{ in_bounds_reg, index_reg, len_reg }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ in_bounds_reg, hit_label, miss_label }) catch return CodegenError.CodegenError;
                            self.out.writer().print("{s}:\n", .{miss_label}) catch return CodegenError.CodegenError;
                            self.out.writer().print("    panic(87)\n\n", .{}) catch return CodegenError.CodegenError;
                            self.out.writer().print("{s}:\n", .{hit_label}) catch return CodegenError.CodegenError;
                            const data_reg = try self.newTmp();
                            const offset_reg = try self.newTmp();
                            const slot_reg = try self.newTmp();
                            const owner_reg = try self.newTmp();
                            self.out.writer().print("    !{s}\n", .{in_bounds_reg}) catch return CodegenError.CodegenError;
                            self.out.writer().print("    {s} = load {s}+Vec_ptr as ptr\n", .{ data_reg, vec_reg }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    {s} = mul {s}, {}\n", .{ offset_reg, index_reg, self.vecElementSlotSize(elem_ty) }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ slot_reg, data_reg, offset_reg }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    {s} = load {s}+0 as ptr\n", .{ owner_reg, slot_reg }) catch return CodegenError.CodegenError;
                            const val_reg = try self.genExpr(assign.value, hoisted_allocs);
                            self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ owner_reg, layout.offset, val_reg, typeString(target_ty) }) catch return CodegenError.CodegenError;
                            try self.emitForgetMovedValue(owner_reg);
                            try self.emitRelease(slot_reg);
                            try self.emitRelease(offset_reg);
                            try self.emitRelease(data_reg);
                            try self.emitRelease(len_reg);
                            if (callArgNeedsRelease(idx.index)) try self.emitRelease(index_reg);
                            if (vec_receiver.release_reg) |release_reg| try self.emitRelease(release_reg);
                            if (vec_receiver.consume_reg) |consume_reg| try self.emitForgetMovedValue(consume_reg);
                            try self.finishStoredValueAfterSlotStore(assign.value, target_ty, val_reg);
                            return;
                        }
                    }
                    const base_reg = try self.genExpr(field.expr, hoisted_allocs);
                    const target_ty = self.resolvedTypeForExpr(assign.target) orelse return CodegenError.CodegenError;
                    const val_reg = try self.genExpr(assign.value, hoisted_allocs);
                    const expr_ty = self.resolvedTypeForExpr(field.expr) orelse return CodegenError.CodegenError;
                    const curr_ty = lowering_rules.peelBorrowPointerType(expr_ty);

                    if (curr_ty.* == .tuple) {
                        const index = std.fmt.parseInt(usize, field.field_name, 10) catch return CodegenError.CodegenError;
                        const layout = tupleFieldLayout(curr_ty.tuple, index) orelse return CodegenError.CodegenError;
                        self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ base_reg, layout.offset, val_reg, typeString(target_ty) }) catch return CodegenError.CodegenError;
                    } else {
                        if (curr_ty.* != .user_defined) return CodegenError.CodegenError;
                        const struct_decl = self.tc.structs.get(curr_ty.user_defined.name) orelse return CodegenError.CodegenError;
                        const layout = fieldLayout(struct_decl, field.field_name) orelse return CodegenError.CodegenError;
                        self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ base_reg, layout.offset, val_reg, typeString(target_ty) }) catch return CodegenError.CodegenError;
                    }
                    if (self.fieldBaseResultNeedsRelease(field.expr, base_reg)) try self.emitRelease(base_reg);
                    try self.finishStoredValueAfterSlotStore(assign.value, target_ty, val_reg);
                } else if (assign.target.* == .identifier) {
                    const target_ty = self.resolvedTypeForExpr(assign.target) orelse return CodegenError.CodegenError;
                    if (assign.value.* == .identifier and self.typeIsCopyStruct(target_ty)) {
                        const target_name = self.resolveBindingName(assign.target.identifier);
                        try self.emitRelease(assign.target.identifier);
                        const source_reg = try self.genExpr(assign.value, hoisted_allocs);
                        try self.genCopyValueInto(target_name, source_reg, target_ty);
                        _ = self.consumed_bindings.remove(target_name);
                        return;
                    }
                    const val_reg = try self.genExpr(assign.value, hoisted_allocs);
                    const stored_val_reg = if (assign.value.* == .move_expr and std.mem.startsWith(u8, val_reg, "^")) val_reg[1..] else val_reg;
                    const target_name = self.resolveBindingName(assign.target.identifier);
                    if (self.bindingStorageAddress(target_name)) |address| {
                        self.out.writer().print("    store {s}, {s} as {s}\n", .{ address, stored_val_reg, typeString(target_ty) }) catch return CodegenError.CodegenError;
                        try self.finishStoredValueAfterSlotStore(assign.value, target_ty, stored_val_reg);
                    } else if (self.assigned_value_slots.contains(target_name)) {
                        _ = try self.releaseResultSlotRefCellHandle(target_name, false);
                        self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ target_name, stored_val_reg, typeString(target_ty) }) catch return CodegenError.CodegenError;
                        if (self.refcell_borrow_handles.contains(stored_val_reg)) {
                            try self.storeResultSlotTransferredValueState(target_name, stored_val_reg, target_ty, callArgNeedsRelease(assign.value));
                            try self.markConsumedBinding(stored_val_reg);
                        } else {
                            // Same as finishStoredValueAfterSlotStore: by-value
                            // non-Copy identifier assignment must emit `^src`
                            // so branch merges see Consumed on the then path.
                            try self.finishStoredValueAfterSlotStore(assign.value, target_ty, stored_val_reg);
                        }
                        _ = self.consumed_bindings.remove(target_name);
                    } else if (self.addressable_bindings.contains(target_name) or self.stack_alloc_bindings.contains(target_name)) {
                        self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ target_name, stored_val_reg, typeString(target_ty) }) catch return CodegenError.CodegenError;
                        try self.finishStoredValueAfterSlotStore(assign.value, target_ty, stored_val_reg);
                    } else {
                        try self.emitRelease(assign.target.identifier);
                        if (assign.value.* == .identifier and target_ty.* == .primitive) {
                            switch (target_ty.primitive) {
                                .boolean => self.out.writer().print("    {s} = or {s}, 0\n", .{ target_name, val_reg }) catch return CodegenError.CodegenError,
                                .f32, .f64, .float => self.out.writer().print("    {s} = add {s}, 0.0\n", .{ target_name, val_reg }) catch return CodegenError.CodegenError,
                                else => self.out.writer().print("    {s} = add {s}, 0\n", .{ target_name, val_reg }) catch return CodegenError.CodegenError,
                            }
                        } else {
                            self.out.writer().print("    {s} = {s}\n", .{ target_name, stored_val_reg }) catch return CodegenError.CodegenError;
                        }
                        if (self.refcell_borrow_handles.contains(stored_val_reg)) {
                            try self.transferResultSlotValueState(target_name, stored_val_reg, true);
                            try self.markConsumedBinding(stored_val_reg);
                        } else if (self.storedIdentifierNeedsRelease(assign.value, target_ty)) {
                            try self.transferResultSlotValueState(target_name, stored_val_reg, true);
                            try self.markConsumedBinding(stored_val_reg);
                        }
                        _ = self.consumed_bindings.remove(target_name);
                    }
                } else {
                    const target_reg = try self.genExpr(assign.target, hoisted_allocs);
                    const val_reg = try self.genExpr(assign.value, hoisted_allocs);
                    self.out.writer().print("    {s} = {s}\n", .{ target_reg, val_reg }) catch return CodegenError.CodegenError;
                }
            },
            .return_stmt => |ret| {
                var val_reg: ?[]const u8 = null;
                if (ret.value) |v| {
                    val_reg = try self.genExpr(v, hoisted_allocs);
                    if (self.async_pending_return_emitted) return;
                }
                if (self.current_async) {
                    if (val_reg == null) {
                        const zero = try self.newTmp();
                        self.out.writer().print("    {s} = 0\n", .{zero}) catch return CodegenError.CodegenError;
                        val_reg = zero;
                    }
                    val_reg = try self.genReadyFutureI64(val_reg.?);
                }

                // Inject scope cleanups before return
                if (self.tc.cleanups.get(stmt)) |list| {
                    for (list.items) |c_var| {
                        if (ret.value) |v| {
                            if ((try self.planFunctionResultCleanup(c_var, v)).releasesValue()) try self.emitRelease(c_var);
                        } else {
                            try self.emitRelease(c_var);
                        }
                    }
                }
                if (val_reg) |vr| {
                    self.out.writer().print("    return {s}\n", .{vr}) catch return CodegenError.CodegenError;
                } else {
                    self.out.writer().print("    return\n", .{}) catch return CodegenError.CodegenError;
                }
            },
            .for_stmt => |f| {
                const loop_head = try self.newLabel("L_LOOP_HEAD");
                const loop_body = try self.newLabel("L_LOOP_BODY");
                const loop_continue = try self.newLabel("L_LOOP_CONTINUE");
                const loop_continue_from_stmt = try self.newLabel("L_LOOP_CONTINUE_FROM_STMT");
                const loop_cond_false = try self.newLabel("L_LOOP_COND_FALSE");
                const loop_break_cleanup = try self.newLabel("L_LOOP_BREAK_CLEANUP");
                const loop_exit = try self.newLabel("L_LOOP_EXIT");
                const loop_control = lowering_rules.planLoopControl(f.body);

                const start_reg = try self.genExpr(f.start, hoisted_allocs);
                const end_reg = if (f.end) |end_expr| try self.genExpr(end_expr, hoisted_allocs) else null;
                const source_ty = self.tc.expr_types.get(f.start) orelse return CodegenError.CodegenError;
                const source_arr = if (end_reg == null) arrayType(source_ty) else null;
                var protocol_len_key: ?[]const u8 = null;
                var protocol_at_key: ?[]const u8 = null;
                defer if (protocol_len_key) |key| self.allocator.free(key);
                defer if (protocol_at_key) |key| self.allocator.free(key);
                var protocol_len_func: ?*ast.FuncDecl = null;
                var protocol_at_func: ?*ast.FuncDecl = null;
                var protocol_len_reg: ?[]const u8 = null;

                if (end_reg == null and source_arr == null) {
                    const type_name = concreteTypeName(source_ty) orelse return CodegenError.CodegenError;
                    protocol_len_key = try self.mangleMethodName(type_name, "iter_len");
                    protocol_at_key = try self.mangleMethodName(type_name, "iter_at");
                    protocol_len_func = self.tc.funcs.get(protocol_len_key.?) orelse return CodegenError.CodegenError;
                    protocol_at_func = self.tc.funcs.get(protocol_at_key.?) orelse return CodegenError.CodegenError;

                    const len_reg = try self.newTmp();
                    const lowered_len = try self.loweredFuncSymbol(protocol_len_key.?);
                    defer self.allocator.free(lowered_len);
                    if (protocol_len_func.?.params.len > 0 and protocol_len_func.?.params[0].is_borrow) {
                        self.out.writer().print("    {s} = call @{s}(&{s})\n", .{ len_reg, lowered_len, start_reg }) catch return CodegenError.CodegenError;
                    } else {
                        self.out.writer().print("    {s} = call @{s}({s})\n", .{ len_reg, lowered_len, start_reg }) catch return CodegenError.CodegenError;
                    }
                    protocol_len_reg = len_reg;
                }

                const counter_slot = std.fmt.allocPrint(self.allocator, "{s}_slot", .{f.var_name}) catch return CodegenError.OutOfMemory;
                defer self.allocator.free(counter_slot);

                if (end_reg != null) {
                    self.out.writer().print("    store {s}+0, {s} as i64\n", .{ counter_slot, start_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{start_reg}) catch return CodegenError.CodegenError;
                } else {
                    self.out.writer().print("    store {s}+0, 0 as i64\n", .{counter_slot}) catch return CodegenError.CodegenError;
                }
                self.out.writer().print("    jmp {s}\n\n", .{loop_head}) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{loop_head}) catch return CodegenError.CodegenError;
                const index_reg = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+0 as i64\n", .{ index_reg, counter_slot }) catch return CodegenError.CodegenError;
                const is_less = try self.newTmp();
                if (end_reg) |er| {
                    self.out.writer().print("    {s} = slt {s}, {s}\n", .{ is_less, index_reg, er }) catch return CodegenError.CodegenError;
                } else {
                    if (source_arr) |arr| {
                        self.out.writer().print("    {s} = slt {s}, {}\n", .{ is_less, index_reg, arr.len }) catch return CodegenError.CodegenError;
                    } else if (protocol_len_reg) |len_reg| {
                        self.out.writer().print("    {s} = slt {s}, {s}\n", .{ is_less, index_reg, len_reg }) catch return CodegenError.CodegenError;
                    } else return CodegenError.CodegenError;
                }
                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_less, loop_body, loop_cond_false }) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{loop_body}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{is_less}) catch return CodegenError.CodegenError;
                if (end_reg != null) {
                    self.out.writer().print("    {s} = add {s}, 0\n", .{ f.var_name, index_reg }) catch return CodegenError.CodegenError;
                } else {
                    if (source_arr) |arr| {
                        const elem_size = typeSize(arr.elem);
                        const byte_offset = try self.newTmp();
                        if (elem_size == 1) {
                            self.out.writer().print("    {s} = {s}\n", .{ byte_offset, index_reg }) catch return CodegenError.CodegenError;
                        } else {
                            self.out.writer().print("    {s} = mul {s}, {}\n", .{ byte_offset, index_reg, elem_size }) catch return CodegenError.CodegenError;
                        }
                        const elem_ptr = try self.newTmp();
                        self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ elem_ptr, start_reg, byte_offset }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ f.var_name, elem_ptr, typeString(arr.elem) }) catch return CodegenError.CodegenError;
                        try self.emitRelease(byte_offset);
                        try self.emitRelease(elem_ptr);
                    } else if (protocol_at_key) |at_key| {
                        const lowered_at = try self.loweredFuncSymbol(at_key);
                        defer self.allocator.free(lowered_at);
                        if (protocol_at_func.?.params.len > 0 and protocol_at_func.?.params[0].is_borrow) {
                            self.out.writer().print("    {s} = call @{s}(&{s}, {s})\n", .{ f.var_name, lowered_at, start_reg, index_reg }) catch return CodegenError.CodegenError;
                        } else {
                            self.out.writer().print("    {s} = call @{s}({s}, {s})\n", .{ f.var_name, lowered_at, start_reg, index_reg }) catch return CodegenError.CodegenError;
                        }
                    } else {
                        return CodegenError.CodegenError;
                    }
                }
                self.loop_continue_labels.append(if (loop_control.has_continue) loop_continue_from_stmt else loop_continue) catch return CodegenError.OutOfMemory;
                self.loop_break_labels.append(if (loop_control.has_break) loop_break_cleanup else loop_exit) catch return CodegenError.OutOfMemory;

                var pre_loop_borrow_sources = self.borrow_source_temps.clone() catch return CodegenError.OutOfMemory;
                defer pre_loop_borrow_sources.deinit();
                var pre_loop_refcell_handles = self.refcell_borrow_handles.clone() catch return CodegenError.OutOfMemory;
                defer pre_loop_refcell_handles.deinit();

                try self.genBlock(f.body, hoisted_allocs);
                _ = self.loop_continue_labels.pop();
                _ = self.loop_break_labels.pop();
                if (lowering_rules.planRefCellLoopStateMerge().restoresPreLoop()) try self.restoreRefCellBranchState(&pre_loop_refcell_handles, &pre_loop_borrow_sources);

                if (!blockTerminates(f.body)) {
                    self.out.writer().print("{s}:\n", .{loop_continue}) catch return CodegenError.CodegenError;
                    const next_i = try self.newTmp();
                    self.out.writer().print("    {s} = add {s}, 1\n", .{ next_i, index_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    store {s}+0, {s} as i64\n", .{ counter_slot, next_i }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{next_i}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{index_reg}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{f.var_name}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    jmp {s}\n\n", .{loop_head}) catch return CodegenError.CodegenError;
                }

                if (loop_control.has_continue) {
                    self.out.writer().print("{s}:\n", .{loop_continue_from_stmt}) catch return CodegenError.CodegenError;
                    const next_i_from_continue = try self.newTmp();
                    self.out.writer().print("    {s} = add {s}, 1\n", .{ next_i_from_continue, index_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    store {s}+0, {s} as i64\n", .{ counter_slot, next_i_from_continue }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{next_i_from_continue}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{index_reg}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    jmp {s}\n\n", .{loop_head}) catch return CodegenError.CodegenError;
                }

                if (loop_control.has_break) {
                    self.out.writer().print("{s}:\n", .{loop_break_cleanup}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{index_reg}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    jmp {s}\n\n", .{loop_exit}) catch return CodegenError.CodegenError;
                }

                self.out.writer().print("{s}:\n", .{loop_cond_false}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{is_less}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{index_reg}) catch return CodegenError.CodegenError;
                self.out.writer().print("    jmp {s}\n\n", .{loop_exit}) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{loop_exit}) catch return CodegenError.CodegenError;
                if (self.tc.cleanups.get(stmt)) |list| {
                    for (list.items) |c_var| {
                        try self.emitRelease(c_var);
                    }
                }
                if (end_reg) |er| {
                    if (callArgNeedsRelease(f.end.?)) try self.emitRelease(er);
                } else {
                    if (protocol_len_reg) |len_reg| try self.emitRelease(len_reg);
                    if (callArgNeedsRelease(f.start)) try self.emitRelease(start_reg);
                }
            },
            .while_stmt => |w| {
                const loop_head = try self.newLabel("L_WHILE_HEAD");
                const loop_body = try self.newLabel("L_WHILE_BODY");
                const loop_cond_false = try self.newLabel("L_WHILE_COND_FALSE");
                const loop_exit = try self.newLabel("L_WHILE_EXIT");

                self.out.writer().print("    jmp {s}\n\n", .{loop_head}) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{loop_head}) catch return CodegenError.CodegenError;
                const cond_reg = try self.genBranchConditionReg(w.cond, hoisted_allocs);
                if (w.let_pattern) |pattern| {
                    const branch_flag = try self.newTmp();
                    const enum_decl = try self.enumDeclForPatternValue(w.cond, pattern);
                    var scoped_bindings = std.ArrayList([]const u8).init(self.allocator);
                    defer scoped_bindings.deinit();
                    const success_on_true = enum_decl != null or std.mem.eql(u8, pattern.variant_name, "Some") or std.mem.eql(u8, pattern.variant_name, "Ok");
                    if (enum_decl) |decl| {
                        try self.genEnumPatternCheck(decl, pattern, cond_reg, branch_flag);
                    } else if (patternUsesResultMacros(pattern)) {
                        self.out.writer().print("    EXPAND RESULT_IS_OK {s}, {s}\n", .{ branch_flag, cond_reg }) catch return CodegenError.CodegenError;
                    } else {
                        self.out.writer().print("    EXPAND OPTION_IS_SOME {s}, {s}\n", .{ branch_flag, cond_reg }) catch return CodegenError.CodegenError;
                    }
                    if (success_on_true) {
                        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ branch_flag, loop_body, loop_cond_false }) catch return CodegenError.CodegenError;
                    } else {
                        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ branch_flag, loop_cond_false, loop_body }) catch return CodegenError.CodegenError;
                    }

                    self.out.writer().print("{s}:\n", .{loop_body}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{branch_flag}) catch return CodegenError.CodegenError;
                    if (enum_decl) |decl| {
                        try self.genEnumPatternBindings(decl, pattern, cond_reg);
                        for (pattern.bindings) |binding| {
                            scoped_bindings.append(binding) catch return CodegenError.OutOfMemory;
                        }
                    } else if (std.mem.eql(u8, pattern.variant_name, "Some") and pattern.bindings.len == 1) {
                        const binding = pattern.bindings[0];
                        const target = try self.pushBindingAlias(binding);
                        scoped_bindings.append(binding) catch return CodegenError.OutOfMemory;
                        self.out.writer().print("    EXPAND OPTION_GET {s}, {s}\n", .{ target, cond_reg }) catch return CodegenError.CodegenError;
                    } else if (std.mem.eql(u8, pattern.variant_name, "Ok") and pattern.bindings.len == 1) {
                        const binding = pattern.bindings[0];
                        const target = try self.pushBindingAlias(binding);
                        scoped_bindings.append(binding) catch return CodegenError.OutOfMemory;
                        self.out.writer().print("    EXPAND RESULT_GET_OK {s}, {s}\n", .{ target, cond_reg }) catch return CodegenError.CodegenError;
                    } else if (std.mem.eql(u8, pattern.variant_name, "Err") and pattern.bindings.len == 1) {
                        const binding = pattern.bindings[0];
                        const target = try self.pushBindingAlias(binding);
                        scoped_bindings.append(binding) catch return CodegenError.OutOfMemory;
                        self.out.writer().print("    EXPAND RESULT_GET_ERR {s}, {s}\n", .{ target, cond_reg }) catch return CodegenError.CodegenError;
                    }
                    try self.emitRelease(cond_reg);
                    self.loop_continue_labels.append(loop_head) catch return CodegenError.OutOfMemory;
                    self.loop_break_labels.append(loop_exit) catch return CodegenError.OutOfMemory;
                    try self.pushLoopBodyLocalScope();
                    defer self.popLoopBodyLocalScope();
                    var pre_loop_borrow_sources = self.borrow_source_temps.clone() catch return CodegenError.OutOfMemory;
                    defer pre_loop_borrow_sources.deinit();
                    var pre_loop_refcell_handles = self.refcell_borrow_handles.clone() catch return CodegenError.OutOfMemory;
                    defer pre_loop_refcell_handles.deinit();
                    try self.genBlock(w.body, hoisted_allocs);
                    _ = self.loop_continue_labels.pop();
                    _ = self.loop_break_labels.pop();
                    if (lowering_rules.planRefCellLoopStateMerge().restoresPreLoop()) try self.restoreRefCellBranchState(&pre_loop_refcell_handles, &pre_loop_borrow_sources);
                    if (!blockTerminates(w.body)) {
                        for (pattern.bindings) |binding| {
                            if (!blockConsumesIdentifier(w.body, binding)) {
                                try self.emitRelease(binding);
                            }
                        }
                        try self.emitActiveLoopBodyLocalCleanups(null, false);
                        try self.emitLoopBodyTopLevelLocalCleanups(w.body);
                        self.out.writer().print("    jmp {s}\n\n", .{loop_head}) catch return CodegenError.CodegenError;
                    }
                    for (scoped_bindings.items) |binding| {
                        self.popBindingAlias(binding);
                    }

                    self.out.writer().print("{s}:\n", .{loop_cond_false}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{branch_flag}) catch return CodegenError.CodegenError;
                    try self.emitRelease(cond_reg);
                    self.out.writer().print("    jmp {s}\n\n", .{loop_exit}) catch return CodegenError.CodegenError;

                    self.out.writer().print("{s}:\n", .{loop_exit}) catch return CodegenError.CodegenError;
                    return;
                }
                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ cond_reg, loop_body, loop_cond_false }) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{loop_body}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{cond_reg}) catch return CodegenError.CodegenError;
                self.loop_continue_labels.append(loop_head) catch return CodegenError.OutOfMemory;
                self.loop_break_labels.append(loop_exit) catch return CodegenError.OutOfMemory;
                try self.pushLoopBodyLocalScope();
                defer self.popLoopBodyLocalScope();
                var pre_loop_borrow_sources = self.borrow_source_temps.clone() catch return CodegenError.OutOfMemory;
                defer pre_loop_borrow_sources.deinit();
                var pre_loop_refcell_handles = self.refcell_borrow_handles.clone() catch return CodegenError.OutOfMemory;
                defer pre_loop_refcell_handles.deinit();
                try self.genBlock(w.body, hoisted_allocs);
                _ = self.loop_continue_labels.pop();
                _ = self.loop_break_labels.pop();
                if (lowering_rules.planRefCellLoopStateMerge().restoresPreLoop()) try self.restoreRefCellBranchState(&pre_loop_refcell_handles, &pre_loop_borrow_sources);
                if (!blockTerminates(w.body)) {
                    try self.emitActiveLoopBodyLocalCleanups(null, false);
                    try self.emitLoopBodyTopLevelLocalCleanups(w.body);
                    self.out.writer().print("    jmp {s}\n\n", .{loop_head}) catch return CodegenError.CodegenError;
                }

                self.out.writer().print("{s}:\n", .{loop_cond_false}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{cond_reg}) catch return CodegenError.CodegenError;
                self.out.writer().print("    jmp {s}\n\n", .{loop_exit}) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{loop_exit}) catch return CodegenError.CodegenError;
            },
            .break_stmt => {
                const cleanup_list = self.tc.cleanups.getPtr(stmt);
                if (cleanup_list) |list| {
                    for (list.items) |c_var| {
                        if (self.activeLoopBodyLocalContainsName(c_var)) {
                            try self.emitLoopBodyLocalCleanup(c_var, true);
                        } else {
                            try self.emitLexicalCleanupRelease(c_var);
                        }
                    }
                }
                try self.emitActiveLoopBodyLocalCleanups(cleanup_list, true);
                if (self.loop_break_labels.items.len == 0) return CodegenError.CodegenError;
                const break_label = self.loop_break_labels.items[self.loop_break_labels.items.len - 1];
                self.out.writer().print("    jmp {s}\n", .{break_label}) catch return CodegenError.CodegenError;
            },
            .continue_stmt => {
                const cleanup_list = self.tc.cleanups.getPtr(stmt);
                if (cleanup_list) |list| {
                    for (list.items) |c_var| {
                        if (self.activeLoopBodyLocalContainsName(c_var)) {
                            try self.emitLoopBodyLocalCleanup(c_var, true);
                        } else {
                            try self.emitLexicalCleanupRelease(c_var);
                        }
                    }
                }
                try self.emitActiveLoopBodyLocalCleanups(cleanup_list, true);
                if (self.loop_continue_labels.items.len == 0) return CodegenError.CodegenError;
                const continue_label = self.loop_continue_labels.items[self.loop_continue_labels.items.len - 1];
                self.out.writer().print("    jmp {s}\n", .{continue_label}) catch return CodegenError.CodegenError;
            },
            .release_stmt => |rel| {
                try self.emitRelease(self.resolveBindingName(rel.var_name));
            },
            .expr_stmt => |expr| {
                if (expr.* == .call_expr and self.isVoidCall(&expr.call_expr) and !lowering_rules.isPanicBuiltinName(expr.call_expr.func_name)) {
                    try self.genCallStmt(&expr.call_expr, hoisted_allocs);
                } else if (expr.* == .call_expr and lowering_rules.isPanicBuiltinName(expr.call_expr.func_name)) {
                    _ = try self.genExpr(expr, hoisted_allocs);
                } else if (expr.* == .if_expr or expr.* == .switch_expr or expr.* == .match_expr) {
                    _ = try self.genExpr(expr, hoisted_allocs);
                } else {
                    const value_reg = try self.genExpr(expr, hoisted_allocs);
                    if (self.async_pending_return_emitted) return;
                    try self.emitRelease(value_reg);
                }
            },
            .block_stmt => |blk| {
                try self.genScopedBlock(blk.body, hoisted_allocs);
            },
            else => {},
        }

        // Generate block exit cleanups if attached to this statement
        if (!stmtTerminates(stmt)) {
            if (self.tc.cleanups.get(stmt)) |list| {
                for (list.items) |c_var| {
                    try self.emitLexicalCleanupRelease(c_var);
                }
            }
        }
    }

    fn genStructLiteralInto(
        self: *Codegen,
        target: []const u8,
        lit: *const ast.StructLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        if (lit.ty.* != .user_defined) return CodegenError.CodegenError;
        const struct_decl = self.structDeclForType(lit.ty) orelse return CodegenError.CodegenError;

        self.out.writer().print("    {s} = alloc {}\n", .{ target, structSize(struct_decl) }) catch return CodegenError.CodegenError;

        if (lit.update_expr) |update_expr| {
            const update_reg = try self.genExpr(update_expr, hoisted_allocs);
            for (struct_decl.fields) |decl_field| {
                const plan = lowering_rules.planStructLiteralField(struct_decl, lit, decl_field) orelse return CodegenError.CodegenError;
                if (!plan.isUpdate()) continue;
                const layout = self.aggregateFieldLayout(lit.ty, decl_field.name) orelse return CodegenError.CodegenError;
                const transfer = lowering_rules.planStructLiteralFieldTransfer(plan, self.typeIsCopyStruct(plan.field_ty));
                const loaded_reg = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ loaded_reg, update_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
                if (transfer.isDirect()) {
                    self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, loaded_reg, layout.ty_str }) catch return CodegenError.CodegenError;
                    if (plan.release_loaded) try self.emitRelease(loaded_reg);
                } else if (transfer.isDeepCopy()) {
                    const copied = try self.newTmp();
                    try self.genCopyValueInto(copied, loaded_reg, plan.field_ty);
                    self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, copied, layout.ty_str }) catch return CodegenError.CodegenError;
                    if (plan.release_loaded) try self.emitRelease(loaded_reg);
                } else if (transfer.isMove()) {
                    const move_reg = if (std.mem.startsWith(u8, loaded_reg, "^")) loaded_reg else try std.fmt.allocPrint(self.allocator, "^{s}", .{loaded_reg});
                    self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, move_reg, layout.ty_str }) catch return CodegenError.CodegenError;
                } else unreachable;
            }
            if (callArgNeedsRelease(update_expr)) try self.emitRelease(update_reg);
        }

        if (struct_decl.is_union) {
            for (lit.fields) |literal_field| {
                const layout = self.aggregateFieldLayout(lit.ty, literal_field.name) orelse return CodegenError.CodegenError;
                var field_ty: ?*ast.Type = null;
                for (struct_decl.fields) |decl_field| {
                    if (std.mem.eql(u8, decl_field.name, literal_field.name)) {
                        field_ty = decl_field.ty;
                        break;
                    }
                }
                if (field_ty != null and manuallyDropInnerType(field_ty.?) != null and literal_field.value.* == .call_expr) {
                    const call = &literal_field.value.call_expr;
                    if (lowering_rules.isManuallyDropNewCall(call.*)) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const slot_reg = try self.newTmp();
                        self.out.writer().print("    {s} = ptr_add {s}, {}\n", .{ slot_reg, target, layout.offset }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND MANUALLY_DROP_U64_NEW {s}, {s}\n", .{ slot_reg, value_reg }) catch return CodegenError.CodegenError;
                        try self.emitRelease(slot_reg);
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                        continue;
                    }
                }
                if (literal_field.value.* == .identifier and field_ty != null and self.typeIsCopyStruct(field_ty.?)) {
                    const source_reg = try self.genExpr(literal_field.value, hoisted_allocs);
                    const copied = try self.newTmp();
                    try self.genCopyValueInto(copied, source_reg, field_ty.?);
                    self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, copied, layout.ty_str }) catch return CodegenError.CodegenError;
                } else {
                    const val_reg = try self.genExpr(literal_field.value, hoisted_allocs);
                    self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, val_reg, layout.ty_str }) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(literal_field.value)) try self.emitRelease(val_reg);
                }
            }
            return;
        }

        for (struct_decl.fields) |decl_field| {
            var literal_value: ?*ast.Node = null;
            for (lit.fields) |literal_field| {
                if (std.mem.eql(u8, literal_field.name, decl_field.name)) {
                    literal_value = literal_field.value;
                    break;
                }
            }
            if (literal_value == null and lit.update_expr != null) continue;
            const value = literal_value orelse return CodegenError.CodegenError;
            const layout = self.aggregateFieldLayout(lit.ty, decl_field.name) orelse return CodegenError.CodegenError;
            const plan = lowering_rules.planStructLiteralField(struct_decl, lit, decl_field) orelse return CodegenError.CodegenError;
            const transfer = lowering_rules.planStructLiteralFieldTransfer(plan, self.typeIsCopyStruct(plan.field_ty));
            if (manuallyDropInnerType(decl_field.ty) != null and value.* == .call_expr) {
                const call = &value.call_expr;
                if (lowering_rules.isManuallyDropNewCall(call.*)) {
                    if (call.args.len != 1) return CodegenError.CodegenError;
                    const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    const slot_reg = try self.newTmp();
                    self.out.writer().print("    {s} = ptr_add {s}, {}\n", .{ slot_reg, target, layout.offset }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND MANUALLY_DROP_U64_NEW {s}, {s}\n", .{ slot_reg, value_reg }) catch return CodegenError.CodegenError;
                    try self.emitRelease(slot_reg);
                    if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                    continue;
                }
            }
            if (transfer.isDeepCopy()) {
                const source_reg = try self.genExpr(value, hoisted_allocs);
                const copied = try self.newTmp();
                try self.genCopyValueInto(copied, source_reg, plan.field_ty);
                self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, copied, layout.ty_str }) catch return CodegenError.CodegenError;
                if (callArgNeedsRelease(value)) try self.emitRelease(source_reg);
            } else if (transfer.isDirect()) {
                const val_reg = try self.genExpr(value, hoisted_allocs);
                self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, val_reg, layout.ty_str }) catch return CodegenError.CodegenError;
                if (callArgNeedsRelease(value)) try self.emitRelease(val_reg);
            } else if (transfer.isMove()) {
                const val_reg = try self.genExpr(value, hoisted_allocs);
                const move_reg = if (std.mem.startsWith(u8, val_reg, "^")) val_reg else try std.fmt.allocPrint(self.allocator, "^{s}", .{val_reg});
                self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, move_reg, layout.ty_str }) catch return CodegenError.CodegenError;
                try self.markMovedExprBinding(value, val_reg);
            } else unreachable;
        }
    }

    fn genArrayLiteralInto(
        self: *Codegen,
        target: []const u8,
        lit: *const ast.ArrayLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        if (lit.elements.len == 0) return CodegenError.CodegenError;
        const first_ty = self.tc.expr_types.get(lit.elements[0]) orelse return CodegenError.CodegenError;
        const elem_size = typeSize(first_ty);
        const elem_ty_str = typeString(first_ty);
        const total_size = @max(elem_size * lit.elements.len, 1);

        self.out.writer().print("    {s} = alloc {}\n", .{ target, total_size }) catch return CodegenError.CodegenError;
        for (lit.elements, 0..) |elem, i| {
            const val_reg = try self.genExpr(elem, hoisted_allocs);
            self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, elem_size * i, val_reg, elem_ty_str }) catch return CodegenError.CodegenError;
            if (callArgNeedsRelease(elem)) try self.emitRelease(val_reg);
        }
    }

    fn genRepeatArrayLiteralInto(
        self: *Codegen,
        target: []const u8,
        node: *const ast.Node,
        lit: *const ast.RepeatArrayLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        const array_ty = self.tc.expr_types.get(node) orelse return CodegenError.CodegenError;
        const arr = arrayType(array_ty) orelse return CodegenError.CodegenError;
        const elem_size = typeSize(arr.elem);
        const total_size = @max(elem_size * arr.len, 1);
        self.out.writer().print("    {s} = alloc {}\n", .{ target, total_size }) catch return CodegenError.CodegenError;

        const value_reg = try self.genExpr(lit.value, hoisted_allocs);
        if (arr.elem.* == .primitive and arr.elem.primitive == .u8) {
            self.out.writer().print("    EXPAND SLA_ARRAY_FILL_U8 {s}, {s}, {}\n", .{ target, value_reg, arr.len }) catch return CodegenError.CodegenError;
        } else {
            const elem_ty_str = typeString(arr.elem);
            for (0..arr.len) |i| {
                self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, elem_size * i, value_reg, elem_ty_str }) catch return CodegenError.CodegenError;
            }
        }
        if (callArgNeedsRelease(lit.value)) try self.emitRelease(value_reg);
    }

    fn genTupleLiteralInto(
        self: *Codegen,
        target: []const u8,
        lit: *const ast.TupleLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        var elems = std.ArrayList(*ast.Type).init(self.allocator);
        for (lit.elements) |elem| {
            try elems.append(self.tc.expr_types.get(elem) orelse return CodegenError.CodegenError);
        }
        const tuple = ast.TupleType{ .elems = try elems.toOwnedSlice() };

        self.out.writer().print("    {s} = alloc {}\n", .{ target, tupleSize(tuple) }) catch return CodegenError.CodegenError;
        for (lit.elements, 0..) |elem, i| {
            const layout = tupleFieldLayout(tuple, i) orelse return CodegenError.CodegenError;
            const val_reg = try self.genExpr(elem, hoisted_allocs);
            self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, val_reg, layout.ty_str }) catch return CodegenError.CodegenError;
        }
    }

    fn genEnumLiteralInto(
        self: *Codegen,
        target: []const u8,
        lit: *const ast.EnumLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        const decl = self.tc.enums.get(lit.enum_name) orelse return CodegenError.CodegenError;
        const tag = enumVariantIndex(decl, lit.variant_name) orelse return CodegenError.CodegenError;
        const variant = enumVariant(decl, lit.variant_name) orelse return CodegenError.CodegenError;

        self.out.writer().print("    {s} = alloc {}\n", .{ target, enumSize(decl) }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {} as i64\n", .{ target, tag }) catch return CodegenError.CodegenError;

        for (variant.fields) |field| {
            var literal_value: ?*ast.Node = null;
            for (lit.fields) |literal_field| {
                if (std.mem.eql(u8, literal_field.name, field.name)) {
                    literal_value = literal_field.value;
                    break;
                }
            }
            const value = literal_value orelse return CodegenError.CodegenError;
            const layout = enumFieldLayout(variant, field.name) orelse return CodegenError.CodegenError;
            const val_reg = try self.genExpr(value, hoisted_allocs);
            self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, val_reg, layout.ty_str }) catch return CodegenError.CodegenError;
        }
    }

    fn genMatchExpr(self: *Codegen, expr: *ast.Node, mat: *const ast.MatchExpr, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        if (mat.cases.len == 0) return CodegenError.CodegenError;
        const val_reg = try self.genExpr(mat.val, hoisted_allocs);
        const val_ty = self.tc.expr_types.get(mat.val) orelse return CodegenError.CodegenError;
        if (optionInnerType(val_ty) != null or resultOkType(val_ty) != null) {
            return try self.genOptionMatchExpr(expr, mat, val_reg, hoisted_allocs);
        }
        if (val_ty.* != .user_defined) return CodegenError.CodegenError;
        const decl = self.tc.enums.get(val_ty.user_defined.name) orelse return CodegenError.CodegenError;
        const expr_ty = self.tc.expr_types.get(expr) orelse return CodegenError.CodegenError;
        const value_match = !isVoidType(expr_ty);
        const result_slot = if (value_match) blk: {
            const slot = try self.newTmp();
            self.out.writer().print("    {s} = alloc {}\n", .{ slot, typeSize(expr_ty) }) catch return CodegenError.CodegenError;
            try self.prepareResultSlotRefCellCompanion(slot, expr_ty);
            break :blk slot;
        } else null;

        const merge_label = try self.newLabel("L_MATCH_MERGE");
        const no_match_label = try self.newLabel("L_MATCH_NO_MATCH");
        var has_fallthrough_case = false;
        for (mat.cases) |case| {
            if (!blockTerminates(case.body)) {
                has_fallthrough_case = true;
                break;
            }
        }
        var check_labels = std.ArrayList([]const u8).init(self.allocator);
        var case_labels = std.ArrayList([]const u8).init(self.allocator);
        var cond_regs = std.ArrayList([]const u8).init(self.allocator);

        for (mat.cases, 0..) |_, i| {
            check_labels.append(try std.fmt.allocPrint(self.allocator, "L_MATCH_CHECK_{}_{}", .{ i, self.label_idx })) catch return CodegenError.OutOfMemory;
            case_labels.append(try std.fmt.allocPrint(self.allocator, "L_MATCH_CASE_{}_{}", .{ i, self.label_idx })) catch return CodegenError.OutOfMemory;
        }
        self.label_idx += 1;

        self.out.writer().print("    jmp {s}\n\n", .{check_labels.items[0]}) catch return CodegenError.CodegenError;

        for (mat.cases, 0..) |case, i| {
            self.out.writer().print("{s}:\n", .{check_labels.items[i]}) catch return CodegenError.CodegenError;
            if (i > 0) {
                self.out.writer().print("    !{s}\n", .{cond_regs.items[i - 1]}) catch return CodegenError.CodegenError;
            }
            const tag_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as i64\n", .{ tag_reg, val_reg }) catch return CodegenError.CodegenError;
            const tag = enumVariantIndex(decl, case.pattern.variant_name) orelse return CodegenError.CodegenError;
            const tag_const = try self.newTmp();
            try self.emitIntConst(tag_const, @as(i64, @intCast(tag)));
            const cond = try self.newTmp();
            cond_regs.append(cond) catch return CodegenError.OutOfMemory;
            self.out.writer().print("    {s} = eq {s}, {s}\n", .{ cond, tag_reg, tag_const }) catch return CodegenError.CodegenError;
            self.out.writer().print("    !{s}\n", .{tag_reg}) catch return CodegenError.CodegenError;
            self.out.writer().print("    !{s}\n", .{tag_const}) catch return CodegenError.CodegenError;
            const next_label = if (i + 1 < mat.cases.len) check_labels.items[i + 1] else no_match_label;
            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ cond, case_labels.items[i], next_label }) catch return CodegenError.CodegenError;

            self.out.writer().print("{s}:\n", .{case_labels.items[i]}) catch return CodegenError.CodegenError;
            const variant = enumVariant(decl, case.pattern.variant_name) orelse return CodegenError.CodegenError;
            for (case.pattern.bindings, variant.fields) |binding, field| {
                const layout = enumFieldLayout(variant, field.name) orelse return CodegenError.CodegenError;
                self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ binding, val_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
            }
            if (case.guard) |guard| {
                const body_label = try self.newLabel("L_MATCH_GUARD_BODY");
                const fail_label = try self.newLabel("L_MATCH_GUARD_FAIL");
                const guard_reg = try self.genExpr(guard, hoisted_allocs);
                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ guard_reg, body_label, fail_label }) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{fail_label}) catch return CodegenError.CodegenError;
                try self.emitRelease(guard_reg);
                for (case.pattern.bindings) |binding| {
                    try self.emitRelease(binding);
                }
                self.out.writer().print("    jmp {s}\n\n", .{next_label}) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{body_label}) catch return CodegenError.CodegenError;
                try self.emitRelease(guard_reg);
            }
            self.out.writer().print("    !{s}\n", .{cond}) catch return CodegenError.CodegenError;
            if (value_match and !blockTerminates(case.body)) {
                try self.genBlockTailValueStore(case.body, result_slot.?, expr_ty, hoisted_allocs);
            } else {
                try self.genBlock(case.body, hoisted_allocs);
            }
            if (!blockTerminates(case.body)) {
                for (case.pattern.bindings) |binding| {
                    if (!blockConsumesIdentifier(case.body, binding)) {
                        try self.emitRelease(binding);
                    }
                }
                self.out.writer().print("    jmp {s}\n", .{merge_label}) catch return CodegenError.CodegenError;
            }
            self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;
        }

        self.out.writer().print("{s}:\n", .{no_match_label}) catch return CodegenError.CodegenError;
        if (cond_regs.items.len > 0) {
            self.out.writer().print("    !{s}\n", .{cond_regs.items[cond_regs.items.len - 1]}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print("    panic(1)\n\n", .{}) catch return CodegenError.CodegenError;
        if (has_fallthrough_case) {
            self.out.writer().print("{s}:\n", .{merge_label}) catch return CodegenError.CodegenError;
        }
        if (result_slot) |slot| {
            const reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ reg, slot, typeString(expr_ty) }) catch return CodegenError.CodegenError;
            try self.loadResultSlotTransferredValueState(reg, slot, expr_ty);
            try self.emitRelease(slot);
            return reg;
        }
        return try self.newTmp();
    }

    fn genOptionMatchExpr(self: *Codegen, expr: *ast.Node, mat: *const ast.MatchExpr, val_reg: []const u8, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        const expr_ty = self.tc.expr_types.get(expr) orelse return CodegenError.CodegenError;
        const value_match = !isVoidType(expr_ty);
        const result_slot = if (value_match) blk: {
            const slot = try self.newTmp();
            self.out.writer().print("    {s} = alloc {}\n", .{ slot, typeSize(expr_ty) }) catch return CodegenError.CodegenError;
            try self.prepareResultSlotRefCellCompanion(slot, expr_ty);
            break :blk slot;
        } else null;

        const merge_label = try self.newLabel("L_OPTION_MATCH_MERGE");
        const no_match_label = try self.newLabel("L_OPTION_MATCH_NO_MATCH");
        var has_fallthrough_case = false;
        for (mat.cases) |case| {
            if (!blockTerminates(case.body)) {
                has_fallthrough_case = true;
                break;
            }
        }

        var check_labels = std.ArrayList([]const u8).init(self.allocator);
        var case_labels = std.ArrayList([]const u8).init(self.allocator);
        var cond_regs = std.ArrayList([]const u8).init(self.allocator);

        for (mat.cases, 0..) |_, i| {
            check_labels.append(try std.fmt.allocPrint(self.allocator, "L_OPTION_MATCH_CHECK_{}_{}", .{ i, self.label_idx })) catch return CodegenError.OutOfMemory;
            case_labels.append(try std.fmt.allocPrint(self.allocator, "L_OPTION_MATCH_CASE_{}_{}", .{ i, self.label_idx })) catch return CodegenError.OutOfMemory;
        }
        self.label_idx += 1;

        self.out.writer().print("    jmp {s}\n\n", .{check_labels.items[0]}) catch return CodegenError.CodegenError;

        for (mat.cases, 0..) |case, i| {
            self.out.writer().print("{s}:\n", .{check_labels.items[i]}) catch return CodegenError.CodegenError;
            if (i > 0) {
                self.out.writer().print("    !{s}\n", .{cond_regs.items[i - 1]}) catch return CodegenError.CodegenError;
            }
            const branch_flag = try self.newTmp();
            cond_regs.append(branch_flag) catch return CodegenError.OutOfMemory;
            if (patternUsesResultMacros(case.pattern)) {
                self.out.writer().print("    EXPAND RESULT_IS_OK {s}, {s}\n", .{ branch_flag, val_reg }) catch return CodegenError.CodegenError;
            } else {
                self.out.writer().print("    EXPAND OPTION_IS_SOME {s}, {s}\n", .{ branch_flag, val_reg }) catch return CodegenError.CodegenError;
            }
            const next_label = if (i + 1 < mat.cases.len) check_labels.items[i + 1] else no_match_label;
            if (std.mem.eql(u8, case.pattern.variant_name, "Some")) {
                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ branch_flag, case_labels.items[i], next_label }) catch return CodegenError.CodegenError;
            } else if (std.mem.eql(u8, case.pattern.variant_name, "None")) {
                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ branch_flag, next_label, case_labels.items[i] }) catch return CodegenError.CodegenError;
            } else if (std.mem.eql(u8, case.pattern.variant_name, "Ok")) {
                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ branch_flag, case_labels.items[i], next_label }) catch return CodegenError.CodegenError;
            } else if (std.mem.eql(u8, case.pattern.variant_name, "Err")) {
                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ branch_flag, next_label, case_labels.items[i] }) catch return CodegenError.CodegenError;
            } else {
                return CodegenError.CodegenError;
            }

            self.out.writer().print("{s}:\n", .{case_labels.items[i]}) catch return CodegenError.CodegenError;
            if (std.mem.eql(u8, case.pattern.variant_name, "Some") and case.pattern.bindings.len == 1) {
                self.out.writer().print("    EXPAND OPTION_GET {s}, {s}\n", .{ case.pattern.bindings[0], val_reg }) catch return CodegenError.CodegenError;
            } else if (std.mem.eql(u8, case.pattern.variant_name, "Ok") and case.pattern.bindings.len == 1) {
                self.out.writer().print("    EXPAND RESULT_GET_OK {s}, {s}\n", .{ case.pattern.bindings[0], val_reg }) catch return CodegenError.CodegenError;
            } else if (std.mem.eql(u8, case.pattern.variant_name, "Err") and case.pattern.bindings.len == 1) {
                self.out.writer().print("    EXPAND RESULT_GET_ERR {s}, {s}\n", .{ case.pattern.bindings[0], val_reg }) catch return CodegenError.CodegenError;
            }
            if (case.guard) |guard| {
                const body_label = try self.newLabel("L_OPTION_MATCH_GUARD_BODY");
                const fail_label = try self.newLabel("L_OPTION_MATCH_GUARD_FAIL");
                const guard_reg = try self.genExpr(guard, hoisted_allocs);
                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ guard_reg, body_label, fail_label }) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{fail_label}) catch return CodegenError.CodegenError;
                try self.emitRelease(guard_reg);
                for (case.pattern.bindings) |binding| {
                    try self.emitRelease(binding);
                }
                self.out.writer().print("    jmp {s}\n\n", .{next_label}) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{body_label}) catch return CodegenError.CodegenError;
                try self.emitRelease(guard_reg);
                self.out.writer().print("    !{s}\n", .{branch_flag}) catch return CodegenError.CodegenError;
            } else {
                self.out.writer().print("    !{s}\n", .{branch_flag}) catch return CodegenError.CodegenError;
            }
            if (value_match and !blockTerminates(case.body)) {
                try self.genBlockTailValueStore(case.body, result_slot.?, expr_ty, hoisted_allocs);
            } else {
                try self.genBlock(case.body, hoisted_allocs);
            }
            if (!blockTerminates(case.body)) {
                for (case.pattern.bindings) |binding| {
                    try self.emitRelease(binding);
                }
                self.out.writer().print("    jmp {s}\n", .{merge_label}) catch return CodegenError.CodegenError;
            }
            self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;
        }

        self.out.writer().print("{s}:\n", .{no_match_label}) catch return CodegenError.CodegenError;
        if (cond_regs.items.len > 0) {
            self.out.writer().print("    !{s}\n", .{cond_regs.items[cond_regs.items.len - 1]}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print("    panic(1)\n\n", .{}) catch return CodegenError.CodegenError;
        if (has_fallthrough_case) {
            self.out.writer().print("{s}:\n", .{merge_label}) catch return CodegenError.CodegenError;
        }
        if (result_slot) |slot| {
            const reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ reg, slot, typeString(expr_ty) }) catch return CodegenError.CodegenError;
            try self.loadResultSlotTransferredValueState(reg, slot, expr_ty);
            try self.emitRelease(slot);
            return reg;
        }
        return try self.newTmp();
    }

    fn genIndexAddress(
        self: *Codegen,
        idx: *const ast.IndexExpr,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!IndexAddress {
        const target_ty = self.resolvedTypeForExpr(idx.target) orelse return CodegenError.CodegenError;

        if (sliceElementType(target_ty)) |elem_ty| {
            const slice_reg = try self.genExpr(idx.target, hoisted_allocs);
            const base_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+Slice_ptr as ptr\n", .{ base_reg, slice_reg }) catch return CodegenError.CodegenError;
            const index_reg = try self.genExpr(idx.index, hoisted_allocs);
            const offset_reg = try self.newTmp();
            self.out.writer().print("    {s} = mul {s}, {}\n", .{ offset_reg, index_reg, typeSize(elem_ty) }) catch return CodegenError.CodegenError;
            const ptr_reg = try self.newTmp();
            self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ ptr_reg, base_reg, offset_reg }) catch return CodegenError.CodegenError;
            try self.emitRelease(offset_reg);
            try self.emitRelease(base_reg);
            if (callArgNeedsRelease(idx.index)) try self.emitRelease(index_reg);
            return .{
                .ptr = ptr_reg,
                .elem_ty = elem_ty,
                .base_tmp = null,
                .base_reg = slice_reg,
                .release_base_reg = exprResultNeedsRelease(idx.target) or isTemporaryRegisterName(slice_reg),
            };
        }

        const arr = arrayType(target_ty) orelse return CodegenError.CodegenError;

        const base_source_reg = try self.genExpr(idx.target, hoisted_allocs);
        const base_tmp = if (idx.target.* == .identifier and self.global_const_bindings.contains(idx.target.identifier)) blk: {
            const addr_reg = try self.newTmp();
            self.out.writer().print("    {s} = &{s}\n", .{ addr_reg, idx.target.identifier }) catch return CodegenError.CodegenError;
            break :blk addr_reg;
        } else null;
        const base_reg = base_tmp orelse base_source_reg;
        const index_reg = try self.genExpr(idx.index, hoisted_allocs);
        const offset_reg = try self.newTmp();
        self.out.writer().print("    {s} = mul {s}, {}\n", .{ offset_reg, index_reg, typeSize(arr.elem) }) catch return CodegenError.CodegenError;
        const ptr_reg = try self.newTmp();
        self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ ptr_reg, base_reg, offset_reg }) catch return CodegenError.CodegenError;
        try self.emitRelease(offset_reg);
        if (callArgNeedsRelease(idx.index)) try self.emitRelease(index_reg);
        return .{
            .ptr = ptr_reg,
            .elem_ty = arr.elem,
            .base_tmp = base_tmp,
            .base_reg = base_source_reg,
            .release_base_reg = base_tmp == null and (exprResultNeedsRelease(idx.target) or isTemporaryRegisterName(base_source_reg)),
        };
    }

    fn fieldAddressLayout(self: *Codegen, target_ty: *const ast.Type, field_name: []const u8) CodegenError!FieldLayout {
        const curr_ty = lowering_rules.peelBorrowPointerType(target_ty);
        if (curr_ty.* == .tuple) {
            const index = std.fmt.parseInt(usize, field_name, 10) catch return CodegenError.CodegenError;
            return tupleFieldLayout(curr_ty.tuple, index) orelse return CodegenError.CodegenError;
        }
        if (curr_ty.* != .user_defined) return CodegenError.CodegenError;
        return self.fieldLayoutForType(curr_ty, field_name) orelse return CodegenError.CodegenError;
    }

    fn rememberAddressProjectionSource(self: *Codegen, projection: AddressProjection) CodegenError!void {
        const plan = lowering_rules.planBorrowAddressTemps(projection.source_temp != null, false);
        if (plan.track_primary_temp) {
            const source_temp = projection.source_temp orelse return CodegenError.CodegenError;
            self.borrow_source_temps.put(projection.ptr, source_temp) catch return CodegenError.OutOfMemory;
        }
    }

    fn rememberIndexAddressSource(self: *Codegen, address: IndexAddress) CodegenError!void {
        const source_temp = address.base_tmp orelse if (address.release_base_reg) address.base_reg else null;
        const plan = lowering_rules.planBorrowAddressTemps(source_temp != null, false);
        if (plan.track_primary_temp) {
            self.borrow_source_temps.put(address.ptr, source_temp orelse return CodegenError.CodegenError) catch return CodegenError.OutOfMemory;
        }
    }

    fn finishIndexAddress(self: *Codegen, address: IndexAddress) CodegenError!void {
        try self.emitRelease(address.ptr);
        if (address.base_tmp) |base_tmp| try self.emitRelease(base_tmp);
        if (address.release_base_reg) try self.emitRelease(address.base_reg);
    }

    fn genFieldAddress(
        self: *Codegen,
        field: *const ast.FieldExpr,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!AddressProjection {
        const expr_ty = self.resolvedTypeForExpr(field.expr) orelse return CodegenError.CodegenError;
        const layout = try self.fieldAddressLayout(expr_ty, field.field_name);
        const base = if (field.expr.* == .field_expr) blk: {
            const nested = try self.genFieldAddress(&field.expr.field_expr, hoisted_allocs);
            const nested_ty = self.resolvedTypeForExpr(field.expr) orelse return CodegenError.CodegenError;
            if (std.mem.eql(u8, typeString(nested_ty), "ptr")) {
                const loaded = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+0 as ptr\n", .{ loaded, nested.ptr }) catch return CodegenError.CodegenError;
                try self.emitRelease(nested.ptr);
                if (nested.source_temp) |source_temp| {
                    self.borrow_source_temps.put(loaded, source_temp) catch return CodegenError.OutOfMemory;
                }
                break :blk loaded;
            }
            try self.rememberAddressProjectionSource(nested);
            break :blk nested.ptr;
        } else try self.genExpr(field.expr, hoisted_allocs);
        const ptr = try self.newTmp();
        self.out.writer().print("    {s} = ptr_add {s}, {}\n", .{ ptr, base, layout.offset }) catch return CodegenError.CodegenError;
        const base_is_resolved_binding = field.expr.* == .identifier and
            std.mem.eql(u8, base, self.resolveBindingName(field.expr.identifier));
        const track_source_temp = lowering_rules.fieldAddressProjectionTracksSourceTemp(
            field.expr.* == .field_expr,
            exprResultNeedsRelease(field.expr),
            isTemporaryRegisterName(base),
            base_is_resolved_binding,
        );
        return .{
            .ptr = ptr,
            .source_temp = if (track_source_temp) base else null,
        };
    }

    fn genVecOwnerReceiver(
        self: *Codegen,
        target: *ast.Node,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!VecReceiver {
        if (target.* == .field_expr) {
            const projection = try self.genFieldAddress(&target.field_expr, hoisted_allocs);
            try self.rememberAddressProjectionSource(projection);
            const owner = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as ptr\n", .{ owner, projection.ptr }) catch return CodegenError.CodegenError;
            try self.emitRelease(projection.ptr);
            const borrowed = try self.newTmp();
            self.out.writer().print("    {s} = &{s}\n", .{ borrowed, owner }) catch return CodegenError.CodegenError;
            return .{ .reg = borrowed, .release_reg = borrowed, .consume_reg = owner };
        }

        const reg = try self.genExpr(target, hoisted_allocs);
        return .{
            .reg = reg,
            .release_reg = if (exprResultNeedsRelease(target)) reg else null,
        };
    }

    fn genIndexAssign(
        self: *Codegen,
        idx: *const ast.IndexExpr,
        value: *ast.Node,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        const target_ty = self.resolvedTypeForExpr(idx.target) orelse return CodegenError.CodegenError;
        if (vecElementType(target_ty)) |elem_ty| {
            const vec_receiver = try self.genVecOwnerReceiver(idx.target, hoisted_allocs);
            const vec_reg = vec_receiver.reg;
            const index_reg = try self.genExpr(idx.index, hoisted_allocs);
            const val_reg = try self.genExpr(value, hoisted_allocs);
            const len_reg = try self.newTmp();
            const in_bounds_reg = try self.newTmp();
            const hit_label = try self.newLabel("L_VEC_INDEX_ASSIGN_OK");
            const miss_label = try self.newLabel("L_VEC_INDEX_ASSIGN_OOB");
            self.out.writer().print("    {s} = load {s}+Vec_len as u64\n", .{ len_reg, vec_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = ult {s}, {s}\n", .{ in_bounds_reg, index_reg, len_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ in_bounds_reg, hit_label, miss_label }) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{miss_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    panic(87)\n\n", .{}) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{hit_label}) catch return CodegenError.CodegenError;
            const data_reg = try self.newTmp();
            const offset_reg = try self.newTmp();
            const ptr_reg = try self.newTmp();
            self.out.writer().print("    !{s}\n", .{in_bounds_reg}) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = load {s}+Vec_ptr as ptr\n", .{ data_reg, vec_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = mul {s}, {}\n", .{ offset_reg, index_reg, self.vecElementSlotSize(elem_ty) }) catch return CodegenError.CodegenError;
            self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ ptr_reg, data_reg, offset_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    store {s}+0, {s} as u64\n", .{ ptr_reg, val_reg }) catch return CodegenError.CodegenError;
            try self.emitRelease(ptr_reg);
            try self.emitRelease(offset_reg);
            try self.emitRelease(data_reg);
            try self.emitRelease(len_reg);
            if (callArgNeedsRelease(idx.index)) try self.emitRelease(index_reg);
            try self.finishStoredValueAfterSlotStore(value, elem_ty, val_reg);
            if (vec_receiver.release_reg) |release_reg| try self.emitRelease(release_reg);
            if (vec_receiver.consume_reg) |consume_reg| try self.emitForgetMovedValue(consume_reg);
            return;
        }
        const addr = try self.genIndexAddress(idx, hoisted_allocs);
        const val_reg = try self.genExpr(value, hoisted_allocs);
        self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ addr.ptr, val_reg, typeString(addr.elem_ty) }) catch return CodegenError.CodegenError;
        try self.finishIndexAddress(addr);
        try self.finishStoredValueAfterSlotStore(value, addr.elem_ty, val_reg);
    }

    fn genVecIndexRead(
        self: *Codegen,
        idx: *const ast.IndexExpr,
        elem_ty: *ast.Type,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        const vec_receiver = try self.genVecOwnerReceiver(idx.target, hoisted_allocs);
        const vec_reg = vec_receiver.reg;
        const index_reg = try self.genExpr(idx.index, hoisted_allocs);
        const len_reg = try self.newTmp();
        const in_bounds_reg = try self.newTmp();
        const hit_label = try self.newLabel("L_VEC_INDEX_OK");
        const miss_label = try self.newLabel("L_VEC_INDEX_OOB");
        self.out.writer().print("    {s} = load {s}+Vec_len as u64\n", .{ len_reg, vec_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    {s} = ult {s}, {s}\n", .{ in_bounds_reg, index_reg, len_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ in_bounds_reg, hit_label, miss_label }) catch return CodegenError.CodegenError;
        self.out.writer().print("{s}:\n", .{miss_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    panic(32)\n\n", .{}) catch return CodegenError.CodegenError;
        self.out.writer().print("{s}:\n", .{hit_label}) catch return CodegenError.CodegenError;
        const data_reg = try self.newTmp();
        const offset_reg = try self.newTmp();
        const ptr_reg = try self.newTmp();
        self.out.writer().print("    !{s}\n", .{in_bounds_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    {s} = load {s}+Vec_ptr as ptr\n", .{ data_reg, vec_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    {s} = mul {s}, {}\n", .{ offset_reg, index_reg, self.vecElementSlotSize(elem_ty) }) catch return CodegenError.CodegenError;
        self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ ptr_reg, data_reg, offset_reg }) catch return CodegenError.CodegenError;
        const reg = try self.genLoadSlotValue(ptr_reg, elem_ty);
        try self.emitRelease(ptr_reg);
        try self.emitRelease(offset_reg);
        try self.emitRelease(data_reg);
        try self.emitRelease(len_reg);
        if (callArgNeedsRelease(idx.index)) try self.emitRelease(index_reg);
        if (vec_receiver.release_reg) |release_reg| try self.emitRelease(release_reg);
        if (vec_receiver.consume_reg) |consume_reg| try self.emitForgetMovedValue(consume_reg);
        return reg;
    }

    fn genSliceExpr(
        self: *Codegen,
        slc: *const ast.SliceExpr,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        const target_ty = self.tc.expr_types.get(slc.target) orelse return CodegenError.CodegenError;
        const arr = arrayType(target_ty) orelse return CodegenError.CodegenError;
        if (slc.start.* != .literal or slc.start.literal != .int_val) return CodegenError.CodegenError;
        const start = slc.start.literal.int_val;
        if (start < 0) return CodegenError.CodegenError;

        const base_source_reg = try self.genExpr(slc.target, hoisted_allocs);
        const base_reg = if (slc.target.* == .identifier and self.global_const_bindings.contains(slc.target.identifier)) blk: {
            const addr_reg = try self.newTmp();
            self.out.writer().print("    {s} = &{s}\n", .{ addr_reg, base_source_reg }) catch return CodegenError.CodegenError;
            break :blk addr_reg;
        } else base_source_reg;
        const offset_reg = try self.newTmp();
        try self.emitIntConst(offset_reg, @as(i64, @intCast(@as(usize, @intCast(start)) * typeSize(arr.elem))));
        const ptr_reg = try self.newTmp();
        self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ ptr_reg, base_reg, offset_reg }) catch return CodegenError.CodegenError;
        try self.emitRelease(offset_reg);
        if (!std.mem.eql(u8, base_reg, base_source_reg)) try self.emitRelease(base_reg);
        return ptr_reg;
    }

    fn genArrayIterSum(
        self: *Codegen,
        source: *ast.Node,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        const source_ty = self.tc.expr_types.get(source) orelse return CodegenError.CodegenError;
        const arr = arrayType(source_ty) orelse return CodegenError.CodegenError;
        const elem_size = typeSize(arr.elem);
        if (arr.len == 0) {
            const sum_reg = try self.newTmp();
            try self.emitIntConst(sum_reg, 0);
            return sum_reg;
        }

        const base_source_reg = try self.genExpr(source, hoisted_allocs);
        const base_reg = if (source.* == .identifier and self.global_const_bindings.contains(source.identifier)) blk: {
            const addr_reg = try self.newTmp();
            self.out.writer().print("    {s} = &{s}\n", .{ addr_reg, base_source_reg }) catch return CodegenError.CodegenError;
            break :blk addr_reg;
        } else base_source_reg;
        var acc_reg = try self.newTmp();
        try self.emitIntConst(acc_reg, 0);

        var i: usize = 0;
        while (i < arr.len) : (i += 1) {
            const off_reg = try self.newTmp();
            try self.emitIntConst(off_reg, @as(i64, @intCast(i * elem_size)));
            const item_ptr = try self.newTmp();
            self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ item_ptr, base_reg, off_reg }) catch return CodegenError.CodegenError;
            const item_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ item_reg, item_ptr, typeString(arr.elem) }) catch return CodegenError.CodegenError;
            const next_acc = try self.newTmp();
            self.out.writer().print("    {s} = add {s}, {s}\n", .{ next_acc, acc_reg, item_reg }) catch return CodegenError.CodegenError;
            try self.emitRelease(off_reg);
            try self.emitRelease(item_ptr);
            try self.emitRelease(item_reg);
            try self.emitRelease(acc_reg);
            acc_reg = next_acc;
        }

        if (callArgNeedsRelease(source)) try self.emitRelease(base_reg);
        if (!std.mem.eql(u8, base_reg, base_source_reg)) try self.emitRelease(base_reg);
        return acc_reg;
    }

    fn genSliceIterSum(
        self: *Codegen,
        source: *ast.Node,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        const source_ty = self.tc.expr_types.get(source) orelse return CodegenError.CodegenError;
        const elem_ty = sliceElementType(source_ty) orelse return CodegenError.CodegenError;
        const elem_size = typeSize(elem_ty);

        const slice_reg = try self.genExpr(source, hoisted_allocs);
        const base_ptr = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+Slice_ptr as ptr\n", .{ base_ptr, slice_reg }) catch return CodegenError.CodegenError;
        const len_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+Slice_len as u64\n", .{ len_reg, slice_reg }) catch return CodegenError.CodegenError;

        const acc_slot = try self.newTmp();
        self.out.writer().print("    {s} = stack_alloc {}\n", .{ acc_slot, typeSize(elem_ty) }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as {s}\n", .{ acc_slot, typeString(elem_ty) }) catch return CodegenError.CodegenError;
        const idx_slot = try self.newTmp();
        self.out.writer().print("    {s} = stack_alloc 8\n", .{idx_slot}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as u64\n", .{idx_slot}) catch return CodegenError.CodegenError;

        const head_label = try self.newLabel("L_SLICE_SUM_HEAD");
        const body_label = try self.newLabel("L_SLICE_SUM_BODY");
        const done_label = try self.newLabel("L_SLICE_SUM_DONE");
        self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{head_label}) catch return CodegenError.CodegenError;
        const idx_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as u64\n", .{ idx_reg, idx_slot }) catch return CodegenError.CodegenError;
        const at_end = try self.newTmp();
        self.out.writer().print("    {s} = eq {s}, {s}\n", .{ at_end, idx_reg, len_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ at_end, done_label, body_label }) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{body_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{at_end}) catch return CodegenError.CodegenError;
        const off_reg = try self.newTmp();
        self.out.writer().print("    {s} = mul {s}, {}\n", .{ off_reg, idx_reg, elem_size }) catch return CodegenError.CodegenError;
        const item_ptr = try self.newTmp();
        self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ item_ptr, base_ptr, off_reg }) catch return CodegenError.CodegenError;
        const item_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ item_reg, item_ptr, typeString(elem_ty) }) catch return CodegenError.CodegenError;
        const acc_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ acc_reg, acc_slot, typeString(elem_ty) }) catch return CodegenError.CodegenError;
        const next_acc = try self.newTmp();
        self.out.writer().print("    {s} = add {s}, {s}\n", .{ next_acc, acc_reg, item_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ acc_slot, next_acc, typeString(elem_ty) }) catch return CodegenError.CodegenError;
        const next_idx = try self.newTmp();
        self.out.writer().print("    {s} = add {s}, 1\n", .{ next_idx, idx_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {s} as u64\n", .{ idx_slot, next_idx }) catch return CodegenError.CodegenError;
        try self.emitRelease(off_reg);
        try self.emitRelease(item_ptr);
        try self.emitRelease(item_reg);
        try self.emitRelease(acc_reg);
        try self.emitRelease(next_acc);
        try self.emitRelease(next_idx);
        try self.emitRelease(idx_reg);
        self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{done_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{at_end}) catch return CodegenError.CodegenError;
        try self.emitRelease(idx_reg);
        const result_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ result_reg, acc_slot, typeString(elem_ty) }) catch return CodegenError.CodegenError;
        if (callArgNeedsRelease(source)) try self.emitRelease(slice_reg);
        try self.emitRelease(base_ptr);
        try self.emitRelease(len_reg);
        return result_reg;
    }

    fn genArrayIterMapSum(
        self: *Codegen,
        source: *ast.Node,
        mapper: *const ast.ClosureLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        const source_ty = self.tc.expr_types.get(source) orelse return CodegenError.CodegenError;
        const arr = arrayType(source_ty) orelse return CodegenError.CodegenError;
        const elem_size = typeSize(arr.elem);
        const sum_ty = self.tc.expr_types.get(mapper.body) orelse return CodegenError.CodegenError;
        if (arr.len == 0) {
            const sum_reg = try self.newTmp();
            try self.emitIntConst(sum_reg, 0);
            return sum_reg;
        }

        const base_source_reg = try self.genExpr(source, hoisted_allocs);
        const base_reg = if (source.* == .identifier and self.global_const_bindings.contains(source.identifier)) blk: {
            const addr_reg = try self.newTmp();
            self.out.writer().print("    {s} = &{s}\n", .{ addr_reg, base_source_reg }) catch return CodegenError.CodegenError;
            break :blk addr_reg;
        } else base_source_reg;
        var acc_reg = try self.newTmp();
        try self.emitIntConst(acc_reg, 0);

        var i: usize = 0;
        while (i < arr.len) : (i += 1) {
            const off_reg = try self.newTmp();
            try self.emitIntConst(off_reg, @as(i64, @intCast(i * elem_size)));
            const item_ptr = try self.newTmp();
            self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ item_ptr, base_reg, off_reg }) catch return CodegenError.CodegenError;
            const item_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ item_reg, item_ptr, typeString(arr.elem) }) catch return CodegenError.CodegenError;
            const mapped_reg = try self.genInlineClosureUnary(mapper, item_reg, hoisted_allocs);
            const next_acc = try self.newTmp();
            self.out.writer().print("    {s} = add {s}, {s}\n", .{ next_acc, acc_reg, mapped_reg }) catch return CodegenError.CodegenError;
            try self.emitRelease(off_reg);
            try self.emitRelease(item_ptr);
            try self.emitRelease(item_reg);
            if (!std.mem.eql(u8, mapped_reg, item_reg)) try self.emitRelease(mapped_reg);
            try self.emitRelease(acc_reg);
            acc_reg = next_acc;
            _ = sum_ty;
        }

        if (callArgNeedsRelease(source)) try self.emitRelease(base_reg);
        if (!std.mem.eql(u8, base_reg, base_source_reg)) try self.emitRelease(base_reg);
        return acc_reg;
    }

    fn genArrayIterFilterSum(
        self: *Codegen,
        source: *ast.Node,
        filter_lit: *const ast.ClosureLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        const source_ty = self.tc.expr_types.get(source) orelse return CodegenError.CodegenError;
        const arr = arrayType(source_ty) orelse return CodegenError.CodegenError;
        const elem_size = typeSize(arr.elem);
        if (arr.len == 0) {
            const sum_reg = try self.newTmp();
            try self.emitIntConst(sum_reg, 0);
            return sum_reg;
        }

        const base_source_reg = try self.genExpr(source, hoisted_allocs);
        const base_reg = if (source.* == .identifier and self.global_const_bindings.contains(source.identifier)) blk: {
            const addr_reg = try self.newTmp();
            self.out.writer().print("    {s} = &{s}\n", .{ addr_reg, base_source_reg }) catch return CodegenError.CodegenError;
            break :blk addr_reg;
        } else base_source_reg;
        const acc_slot = try self.newTmp();
        self.out.writer().print("    {s} = stack_alloc {}\n", .{ acc_slot, typeSize(arr.elem) }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as {s}\n", .{ acc_slot, typeString(arr.elem) }) catch return CodegenError.CodegenError;

        var i: usize = 0;
        while (i < arr.len) : (i += 1) {
            const off_reg = try self.newTmp();
            try self.emitIntConst(off_reg, @as(i64, @intCast(i * elem_size)));
            const item_ptr = try self.newTmp();
            self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ item_ptr, base_reg, off_reg }) catch return CodegenError.CodegenError;
            const item_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ item_reg, item_ptr, typeString(arr.elem) }) catch return CodegenError.CodegenError;
            const keep_reg = try self.genInlineClosureUnary(filter_lit, item_reg, hoisted_allocs);
            const then_label = try self.newLabel("L_FILTER_KEEP");
            const else_label = try self.newLabel("L_FILTER_SKIP");
            const merge_label = try self.newLabel("L_FILTER_MERGE");
            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ keep_reg, then_label, else_label }) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{then_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    !{s}\n", .{keep_reg}) catch return CodegenError.CodegenError;
            const acc_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ acc_reg, acc_slot, typeString(arr.elem) }) catch return CodegenError.CodegenError;
            const next_acc = try self.newTmp();
            self.out.writer().print("    {s} = add {s}, {s}\n", .{ next_acc, acc_reg, item_reg }) catch return CodegenError.CodegenError;
            self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ acc_slot, next_acc, typeString(arr.elem) }) catch return CodegenError.CodegenError;
            try self.emitRelease(acc_reg);
            try self.emitRelease(next_acc);
            self.out.writer().print("    jmp {s}\n\n", .{merge_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{else_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("    !{s}\n", .{keep_reg}) catch return CodegenError.CodegenError;
            self.out.writer().print("    jmp {s}\n\n", .{merge_label}) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}:\n", .{merge_label}) catch return CodegenError.CodegenError;
            try self.emitRelease(off_reg);
            try self.emitRelease(item_ptr);
            try self.emitRelease(item_reg);
        }

        if (callArgNeedsRelease(source)) try self.emitRelease(base_reg);
        if (!std.mem.eql(u8, base_reg, base_source_reg)) try self.emitRelease(base_reg);
        const result_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ result_reg, acc_slot, typeString(arr.elem) }) catch return CodegenError.CodegenError;
        return result_reg;
    }

    fn genArrayIterFold(
        self: *Codegen,
        source: *ast.Node,
        init_expr: *ast.Node,
        folder: *const ast.ClosureLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        const source_ty = self.tc.expr_types.get(source) orelse return CodegenError.CodegenError;
        const arr = arrayType(source_ty) orelse return CodegenError.CodegenError;
        const acc_ty = folder.params[0].ty;
        const elem_size = typeSize(arr.elem);

        const base_source_reg = try self.genExpr(source, hoisted_allocs);
        const base_reg = if (source.* == .identifier and self.global_const_bindings.contains(source.identifier)) blk: {
            const addr_reg = try self.newTmp();
            self.out.writer().print("    {s} = &{s}\n", .{ addr_reg, base_source_reg }) catch return CodegenError.CodegenError;
            break :blk addr_reg;
        } else base_source_reg;
        const init_reg = try self.genExpr(init_expr, hoisted_allocs);
        const acc_slot = try self.newTmp();
        self.out.writer().print("    {s} = stack_alloc {}\n", .{ acc_slot, typeSize(acc_ty) }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ acc_slot, init_reg, typeString(acc_ty) }) catch return CodegenError.CodegenError;
        if (callArgNeedsRelease(init_expr)) try self.emitRelease(init_reg);

        var i: usize = 0;
        while (i < arr.len) : (i += 1) {
            const off_reg = try self.newTmp();
            try self.emitIntConst(off_reg, @as(i64, @intCast(i * elem_size)));
            const item_ptr = try self.newTmp();
            self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ item_ptr, base_reg, off_reg }) catch return CodegenError.CodegenError;
            const item_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ item_reg, item_ptr, typeString(arr.elem) }) catch return CodegenError.CodegenError;
            const acc_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ acc_reg, acc_slot, typeString(acc_ty) }) catch return CodegenError.CodegenError;
            const next_acc = try self.genInlineClosureBinary(folder, acc_reg, item_reg, hoisted_allocs);
            self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ acc_slot, next_acc, typeString(acc_ty) }) catch return CodegenError.CodegenError;
            try self.emitRelease(off_reg);
            try self.emitRelease(item_ptr);
            try self.emitRelease(item_reg);
            try self.emitRelease(acc_reg);
            if (!std.mem.eql(u8, next_acc, acc_reg) and !std.mem.eql(u8, next_acc, item_reg)) try self.emitRelease(next_acc);
        }

        if (callArgNeedsRelease(source)) try self.emitRelease(base_reg);
        if (!std.mem.eql(u8, base_reg, base_source_reg)) try self.emitRelease(base_reg);
        const result_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ result_reg, acc_slot, typeString(acc_ty) }) catch return CodegenError.CodegenError;
        return result_reg;
    }

    fn genInlineClosureUnary(
        self: *Codegen,
        lit: *const ast.ClosureLiteral,
        arg_reg: []const u8,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        if (lit.params.len != 1) return CodegenError.CodegenError;
        var saved = std.ArrayList(SavedClosureParam).init(self.allocator);
        defer saved.deinit();
        saved.append(.{ .name = lit.params[0].name, .old = self.closure_param_regs.get(lit.params[0].name) }) catch return CodegenError.OutOfMemory;
        self.closure_param_regs.put(lit.params[0].name, arg_reg) catch return CodegenError.OutOfMemory;
        defer self.restoreClosureParams(saved.items);
        return try self.genExpr(lit.body, hoisted_allocs);
    }

    fn genInlineClosureNullary(
        self: *Codegen,
        lit: *const ast.ClosureLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        if (lit.params.len != 0) return CodegenError.CodegenError;
        return try self.genExpr(lit.body, hoisted_allocs);
    }

    fn genInlineClosureBinary(
        self: *Codegen,
        lit: *const ast.ClosureLiteral,
        left_reg: []const u8,
        right_reg: []const u8,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        if (lit.params.len != 2) return CodegenError.CodegenError;
        var saved = std.ArrayList(SavedClosureParam).init(self.allocator);
        defer saved.deinit();
        saved.append(.{ .name = lit.params[0].name, .old = self.closure_param_regs.get(lit.params[0].name) }) catch return CodegenError.OutOfMemory;
        saved.append(.{ .name = lit.params[1].name, .old = self.closure_param_regs.get(lit.params[1].name) }) catch return CodegenError.OutOfMemory;
        self.closure_param_regs.put(lit.params[0].name, left_reg) catch return CodegenError.OutOfMemory;
        self.closure_param_regs.put(lit.params[1].name, right_reg) catch return CodegenError.OutOfMemory;
        defer self.restoreClosureParams(saved.items);
        return try self.genExpr(lit.body, hoisted_allocs);
    }

    fn genVecDequeRotateLeft(self: *Codegen, deque_reg: []const u8, count_reg: []const u8) CodegenError![]const u8 {
        const len_reg = try self.newTmp();
        self.out.writer().print("    EXPAND VEC_DEQUE_LEN {s}, {s}\n", .{ len_reg, deque_reg }) catch return CodegenError.CodegenError;
        const idx_slot = try self.newTmp();
        self.out.writer().print("    {s} = stack_alloc 8\n", .{idx_slot}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as u64\n", .{idx_slot}) catch return CodegenError.CodegenError;
        const pop_slot = try self.newTmp();
        self.out.writer().print("    {s} = stack_alloc 8\n", .{pop_slot}) catch return CodegenError.CodegenError;
        const empty_reg = try self.newTmp();
        self.out.writer().print("    {s} = eq {s}, 0\n", .{ empty_reg, len_reg }) catch return CodegenError.CodegenError;

        const run_label = try self.newLabel("L_VEC_DEQUE_ROTATE_RUN");
        const empty_label = try self.newLabel("L_VEC_DEQUE_ROTATE_EMPTY");
        const init_label = try self.newLabel("L_VEC_DEQUE_ROTATE_INIT");
        const no_move_label = try self.newLabel("L_VEC_DEQUE_ROTATE_NO_MOVE");
        const head_label = try self.newLabel("L_VEC_DEQUE_ROTATE_HEAD");
        const body_label = try self.newLabel("L_VEC_DEQUE_ROTATE_BODY");
        const done_label = try self.newLabel("L_VEC_DEQUE_ROTATE_DONE");
        const end_label = try self.newLabel("L_VEC_DEQUE_ROTATE_END");

        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ empty_reg, empty_label, run_label }) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{empty_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{empty_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{run_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{empty_reg}) catch return CodegenError.CodegenError;
        const shift_reg = try self.newTmp();
        self.out.writer().print("    {s} = urem {s}, {s}\n", .{ shift_reg, count_reg, len_reg }) catch return CodegenError.CodegenError;
        const no_move_reg = try self.newTmp();
        self.out.writer().print("    {s} = eq {s}, 0\n", .{ no_move_reg, shift_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ no_move_reg, no_move_label, init_label }) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{no_move_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{no_move_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{shift_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{init_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{no_move_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as u64\n", .{idx_slot}) catch return CodegenError.CodegenError;
        self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{head_label}) catch return CodegenError.CodegenError;
        const idx_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as u64\n", .{ idx_reg, idx_slot }) catch return CodegenError.CodegenError;
        const done_reg = try self.newTmp();
        self.out.writer().print("    {s} = eq {s}, {s}\n", .{ done_reg, idx_reg, shift_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ done_reg, done_label, body_label }) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{body_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{done_reg}) catch return CodegenError.CodegenError;
        const pop_ok = try self.newTmp();
        const popped = try self.newTmp();
        self.out.writer().print("    {s} = call @sa_vec_deque_try_pop_front(&{s}, &{s})\n", .{ pop_ok, deque_reg, pop_slot }) catch return CodegenError.CodegenError;
        self.out.writer().print("    {s} = load {s}+0 as u64\n", .{ popped, pop_slot }) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{pop_ok}) catch return CodegenError.CodegenError;
        self.out.writer().print("    EXPAND VEC_DEQUE_PUSH_BACK {s}, {s}\n", .{ deque_reg, popped }) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{popped}) catch return CodegenError.CodegenError;
        const next_idx = try self.newTmp();
        self.out.writer().print("    {s} = add {s}, 1\n", .{ next_idx, idx_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {s} as u64\n", .{ idx_slot, next_idx }) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{next_idx}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{idx_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{done_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{done_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{idx_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{shift_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;

        self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{len_reg}) catch return CodegenError.CodegenError;
        const reg = try self.newTmp();
        try self.emitIntConst(reg, 0);
        return reg;
    }

    fn genVecIterSum(
        self: *Codegen,
        source: *ast.Node,
        mapper: ?*const ast.ClosureLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        const source_ty = self.tc.expr_types.get(source) orelse return CodegenError.CodegenError;
        const elem_ty = vecElementType(source_ty) orelse return CodegenError.CodegenError;
        const vec_reg = try self.genExpr(source, hoisted_allocs);
        const len_reg = try self.newTmp();
        self.out.writer().print("    {s} = call @sa_vec_len(&{s})\n", .{ len_reg, vec_reg }) catch return CodegenError.CodegenError;
        const data_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+Vec_ptr as ptr\n", .{ data_reg, vec_reg }) catch return CodegenError.CodegenError;
        const sum_ty = if (mapper) |lit| self.tc.expr_types.get(lit.body) orelse return CodegenError.CodegenError else elem_ty;
        const acc_slot = try self.newTmp();
        self.out.writer().print("    {s} = stack_alloc 8\n", .{acc_slot}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as {s}\n", .{ acc_slot, typeString(sum_ty) }) catch return CodegenError.CodegenError;
        const idx_slot = try self.newTmp();
        self.out.writer().print("    {s} = stack_alloc 8\n", .{idx_slot}) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, 0 as u64\n", .{idx_slot}) catch return CodegenError.CodegenError;
        const head_label = try self.newLabel("L_VEC_SUM_HEAD");
        const body_label = try self.newLabel("L_VEC_SUM_BODY");
        const end_label = try self.newLabel("L_VEC_SUM_END");
        self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("{s}:\n", .{head_label}) catch return CodegenError.CodegenError;
        const idx_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as u64\n", .{ idx_reg, idx_slot }) catch return CodegenError.CodegenError;
        const more_reg = try self.newTmp();
        self.out.writer().print("    {s} = ult {s}, {s}\n", .{ more_reg, idx_reg, len_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ more_reg, body_label, end_label }) catch return CodegenError.CodegenError;
        self.out.writer().print("{s}:\n", .{body_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{more_reg}) catch return CodegenError.CodegenError;
        const acc_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ acc_reg, acc_slot, typeString(sum_ty) }) catch return CodegenError.CodegenError;
        const off_reg = try self.newTmp();
        self.out.writer().print("    {s} = mul {s}, {}\n", .{ off_reg, idx_reg, self.vecElementSlotSize(elem_ty) }) catch return CodegenError.CodegenError;
        const slot_reg = try self.newTmp();
        self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ slot_reg, data_reg, off_reg }) catch return CodegenError.CodegenError;
        const item_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ item_reg, slot_reg, typeString(elem_ty) }) catch return CodegenError.CodegenError;
        const mapped_reg = if (mapper) |lit| try self.genInlineClosureUnary(lit, item_reg, hoisted_allocs) else item_reg;
        const next_acc = try self.newTmp();
        self.out.writer().print("    {s} = add {s}, {s}\n", .{ next_acc, acc_reg, mapped_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ acc_slot, next_acc, typeString(sum_ty) }) catch return CodegenError.CodegenError;
        try self.emitRelease(off_reg);
        try self.emitRelease(slot_reg);
        try self.emitRelease(item_reg);
        try self.emitRelease(acc_reg);
        try self.emitRelease(next_acc);
        if (mapper != null and !std.mem.eql(u8, mapped_reg, item_reg)) try self.emitRelease(mapped_reg);
        const next_idx = try self.newTmp();
        self.out.writer().print("    {s} = add {s}, 1\n", .{ next_idx, idx_reg }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {s} as u64\n", .{ idx_slot, next_idx }) catch return CodegenError.CodegenError;
        try self.emitRelease(next_idx);
        try self.emitRelease(idx_reg);
        self.out.writer().print("    jmp {s}\n\n", .{head_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
        self.out.writer().print("    !{s}\n", .{more_reg}) catch return CodegenError.CodegenError;
        try self.emitRelease(len_reg);
        try self.emitRelease(data_reg);
        const result_reg = try self.newTmp();
        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ result_reg, acc_slot, typeString(sum_ty) }) catch return CodegenError.CodegenError;
        if (callArgNeedsRelease(source)) try self.emitRelease(vec_reg);
        return result_reg;
    }

    const SavedClosureParam = struct {
        name: []const u8,
        old: ?[]const u8,
    };

    fn restoreClosureParams(self: *Codegen, saved: []const SavedClosureParam) void {
        var i = saved.len;
        while (i > 0) {
            i -= 1;
            const item = saved[i];
            if (item.old) |old| {
                self.closure_param_regs.put(item.name, old) catch {};
            } else {
                _ = self.closure_param_regs.remove(item.name);
            }
        }
    }

    fn genClosureCall(
        self: *Codegen,
        lit: *const ast.ClosureLiteral,
        call: *const ast.CallExpr,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        if (lit.params.len != call.args.len) return CodegenError.CodegenError;

        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
        defer arg_regs.deinit();
        for (call.args) |arg| {
            arg_regs.append(try self.genExpr(arg, hoisted_allocs)) catch return CodegenError.OutOfMemory;
        }

        var saved = std.ArrayList(SavedClosureParam).init(self.allocator);
        defer saved.deinit();
        for (lit.params, arg_regs.items) |param, arg_reg| {
            saved.append(.{ .name = param.name, .old = self.closure_param_regs.get(param.name) }) catch return CodegenError.OutOfMemory;
            self.closure_param_regs.put(param.name, arg_reg) catch return CodegenError.OutOfMemory;
        }
        defer self.restoreClosureParams(saved.items);

        return try self.genExpr(lit.body, hoisted_allocs);
    }

    fn genExpr(self: *Codegen, expr: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        @setEvalBranchQuota(10000);
        switch (expr.*) {
            .literal => |lit| {
                return try self.genLiteralValue(lit);
            },
            .identifier => |name| {
                if (lowering_rules.isOptionNoneName(name)) {
                    const reg = try self.newTmp();
                    self.out.writer().print("    EXPAND OPTION_NEW_NONE {s}\n", .{reg}) catch return CodegenError.CodegenError;
                    return reg;
                }
                if (self.thread_capture_regs.get(name)) |capture_reg| {
                    return capture_reg;
                }
                const resolved_name = self.resolveBindingName(name);
                if (!std.mem.eql(u8, resolved_name, name)) {
                    if (self.stack_alloc_bindings.contains(resolved_name)) return resolved_name;
                    if (self.assigned_value_slots.contains(resolved_name)) {
                        const expr_ty = self.resolvedTypeForExpr(expr) orelse return CodegenError.CodegenError;
                        const reg = try self.newTmp();
                        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ reg, resolved_name, typeString(expr_ty) }) catch return CodegenError.CodegenError;
                        return reg;
                    }
                    if (self.addressable_bindings.contains(resolved_name)) {
                        const expr_ty = self.resolvedTypeForExpr(expr) orelse return CodegenError.CodegenError;
                        if (isRawPtrAliasType(expr_ty)) return resolved_name;
                        const reg = try self.newTmp();
                        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ reg, resolved_name, typeString(expr_ty) }) catch return CodegenError.CodegenError;
                        return reg;
                    }
                    return resolved_name;
                }
                if (self.closure_param_regs.get(name)) |mapped| return mapped;
                if (self.global_scalar_consts.get(name)) |literal_node| {
                    if (literal_node.* != .literal) return CodegenError.CodegenError;
                    return try self.genLiteralValue(literal_node.literal);
                }
                if (self.global_const_bindings.contains(name)) return name;
                if (self.stack_alloc_bindings.contains(name)) return name;
                if (self.bindingStorageAddress(name)) |address| {
                    const expr_ty = self.resolvedTypeForExpr(expr) orelse return CodegenError.CodegenError;
                    const reg = try self.newTmp();
                    self.out.writer().print("    {s} = load {s} as {s}\n", .{ reg, address, typeString(expr_ty) }) catch return CodegenError.CodegenError;
                    return reg;
                }
                if (self.assigned_value_slots.contains(name)) {
                    const expr_ty = self.resolvedTypeForExpr(expr) orelse return CodegenError.CodegenError;
                    const reg = try self.newTmp();
                    self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ reg, name, typeString(expr_ty) }) catch return CodegenError.CodegenError;
                    return reg;
                }
                if (self.tc.funcs.contains(name)) {
                    const expr_ty = self.resolvedTypeForExpr(expr) orelse return CodegenError.CodegenError;
                    if (expr_ty.* == .fn_ptr) {
                        const reg = try self.newTmp();
                        const vt_name = try self.fnPtrVTableName(name);
                        defer self.allocator.free(vt_name);
                        self.out.writer().print("    {s} = &{s}\n", .{ reg, vt_name }) catch return CodegenError.CodegenError;
                        return reg;
                    }
                }
                if (self.addressable_bindings.contains(name)) {
                    const expr_ty = self.tc.expr_types.get(expr) orelse return CodegenError.CodegenError;
                    if (expr_ty.* == .primitive and !isRawPtrAliasType(expr_ty)) {
                        const reg = try self.newTmp();
                        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ reg, name, typeString(expr_ty) }) catch return CodegenError.CodegenError;
                        return reg;
                    }
                }
                return name;
            },
            .generic_func_ref => return CodegenError.CodegenError,
            .binary_expr => |bin| {
                if (self.tc.resolved_call_symbols.get(expr)) |symbol| {
                    const call = ast.CallExpr{
                        .func_name = symbol,
                        .associated_target = null,
                        .generics = &.{},
                        .args = &.{ bin.left, bin.right },
                    };
                    const lowering = lowering_rules.planResolvedStaticCallLowering(self.tc, expr, call, self.tc.expr_types.get(expr)) orelse return CodegenError.CodegenError;
                    return try self.genResolvedFunctionCall(lowering, &call, hoisted_allocs, false);
                }
                const left_ty = self.resolvedTypeForExpr(bin.left) orelse self.tc.expr_types.get(bin.left) orelse return CodegenError.CodegenError;
                const right_ty = self.resolvedTypeForExpr(bin.right) orelse self.tc.expr_types.get(bin.right) orelse return CodegenError.CodegenError;
                if (try self.genSpaceshipExpr(&bin, left_ty, right_ty, hoisted_allocs)) |reg| return reg;
                if (try self.genStructEqualityExpr(&bin, left_ty, right_ty, hoisted_allocs)) |reg| return reg;
                if (try self.genStructOrdExpr(&bin, left_ty, right_ty, hoisted_allocs)) |reg| return reg;
                if (try self.genStructArithmeticExpr(&bin, left_ty, right_ty, hoisted_allocs)) |reg| return reg;
                const l = try self.genExpr(bin.left, hoisted_allocs);
                const r = try self.genExpr(bin.right, hoisted_allocs);
                const reg = try self.newTmp();
                const op = binaryOpName(bin.op, left_ty, right_ty) orelse return CodegenError.CodegenError;
                self.out.writer().print("    {s} = {s} {s}, {s}\n", .{ reg, op, l, r }) catch return CodegenError.CodegenError;
                if (self.exprResultRegNeedsRelease(bin.left)) try self.emitRelease(l);
                if (self.exprResultRegNeedsRelease(bin.right)) try self.emitRelease(r);
                return reg;
            },
            .borrow_expr => |borrow| {
                var deref_source_ty: ?*const ast.Type = null;
                var index_target_ty: ?*const ast.Type = null;
                switch (borrow.expr.*) {
                    .deref_expr => deref_source_ty = self.resolvedTypeForExpr(borrow.expr.deref_expr.expr) orelse return CodegenError.CodegenError,
                    .index_expr => |idx| index_target_ty = self.resolvedTypeForExpr(idx.target) orelse return CodegenError.CodegenError,
                    else => {},
                }
                if (borrow.expr.* == .field_expr) {
                    const field_ty = self.resolvedTypeForExpr(borrow.expr) orelse return CodegenError.CodegenError;
                    if (vecElementType(field_ty) != null) {
                        const projection = try self.genFieldAddress(&borrow.expr.field_expr, hoisted_allocs);
                        try self.rememberAddressProjectionSource(projection);
                        const owner = try self.newTmp();
                        self.out.writer().print("    {s} = load {s}+0 as ptr\n", .{ owner, projection.ptr }) catch return CodegenError.CodegenError;
                        try self.emitRelease(projection.ptr);
                        return owner;
                    }
                    if (lowering_rules.smartPointerDerefType(field_ty) != null) {
                        return try self.genExpr(borrow.expr, hoisted_allocs);
                    }
                }
                const address_plan = lowering_rules.planAddressOf(borrow.expr, .{
                    .deref_source_ty = deref_source_ty,
                    .index_target_ty = index_target_ty,
                });
                switch (address_plan.shape) {
                    .identifier => {
                        if (lowering_rules.borrowedIdentifierName(expr)) |borrowed_name| {
                            const resolved_name = self.resolveBindingName(borrowed_name);
                            if (self.assigned_value_slots.contains(resolved_name)) {
                                const addr = try self.newTmp();
                                self.out.writer().print("    {s} = load {s}+0 as ptr\n", .{ addr, resolved_name }) catch return CodegenError.CodegenError;
                                return addr;
                            }
                            if (self.addressable_bindings.contains(borrowed_name) or self.addressable_bindings.contains(resolved_name)) {
                                const addr = try self.newTmp();
                                self.out.writer().print("    {s} = ptr_add {s}, 0\n", .{ addr, resolved_name }) catch return CodegenError.CodegenError;
                                return addr;
                            }
                        }
                    },
                    .deref_borrow_or_pointer => {
                        const source = try self.genExpr(borrow.expr.deref_expr.expr, hoisted_allocs);
                        const addr = try self.newTmp();
                        self.out.writer().print("    {s} = ptr_add {s}, 0\n", .{ addr, source }) catch return CodegenError.CodegenError;
                        const temp_plan = lowering_rules.planBorrowAddressTemps(exprResultNeedsRelease(borrow.expr.deref_expr.expr), false);
                        if (temp_plan.track_primary_temp) {
                            self.borrow_source_temps.put(addr, source) catch return CodegenError.OutOfMemory;
                        }
                        return addr;
                    },
                    .field => {
                        const field_ty = self.resolvedTypeForExpr(borrow.expr) orelse return CodegenError.CodegenError;
                        const projection = try self.genFieldAddress(&borrow.expr.field_expr, hoisted_allocs);
                        if (lowering_rules.structFieldIsPointerBacked(field_ty)) {
                            const loaded = try self.newTmp();
                            self.out.writer().print("    {s} = load {s}+0 as ptr\n", .{ loaded, projection.ptr }) catch return CodegenError.CodegenError;
                            try self.emitRelease(projection.ptr);
                            if (projection.source_temp) |source_temp| {
                                self.borrow_source_temps.put(loaded, source_temp) catch return CodegenError.OutOfMemory;
                            }
                            return loaded;
                        }
                        try self.rememberAddressProjectionSource(projection);
                        return projection.ptr;
                    },
                    .index => {
                        const address = try self.genIndexAddress(&borrow.expr.index_expr, hoisted_allocs);
                        try self.rememberIndexAddressSource(address);
                        return address.ptr;
                    },
                    .deref_smart_pointer => {
                        const source_ty = deref_source_ty orelse return CodegenError.CodegenError;
                        if (self.macro_inline_depth > 0 and boxInnerType(source_ty) != null) {
                            const source = try self.genExpr(borrow.expr.deref_expr.expr, hoisted_allocs);
                            const addr = try self.newTmp();
                            self.out.writer().print("    {s} = ptr_add {s}, 0\n", .{ addr, source }) catch return CodegenError.CodegenError;
                            const temp_plan = lowering_rules.planBorrowAddressTemps(exprResultNeedsRelease(borrow.expr.deref_expr.expr), false);
                            if (temp_plan.track_primary_temp) {
                                self.borrow_source_temps.put(addr, source) catch return CodegenError.OutOfMemory;
                            }
                            return addr;
                        }
                    },
                    .value_temp => {},
                }
                const inner = try self.genExpr(borrow.expr, hoisted_allocs);
                if (borrow.expr.* == .deref_expr) {
                    const deref_ty = self.resolvedTypeForExpr(borrow.expr) orelse return CodegenError.CodegenError;
                    const owner_ty = self.resolvedTypeForExpr(borrow.expr.deref_expr.expr) orelse return CodegenError.CodegenError;
                    if (dynTraitName(deref_ty) != null) {
                        if (boxInnerType(owner_ty)) |box_inner| {
                            if (dynTraitName(box_inner) != null) {
                                const data_reg = try self.newTmp();
                                const vtable_reg = try self.newTmp();
                                const fat_reg = try self.newTmp();
                                self.out.writer().print("    {s} = load {s}+Dyn_data as ptr\n", .{ data_reg, inner }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = load {s}+Dyn_vtable as ptr\n", .{ vtable_reg, inner }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = alloc Dyn_SIZE\n", .{fat_reg}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    store {s}+Dyn_data, {s} as ptr\n", .{ fat_reg, data_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    store {s}+Dyn_vtable, {s} as ptr\n", .{ fat_reg, vtable_reg }) catch return CodegenError.CodegenError;
                                try self.emitRelease(data_reg);
                                try self.emitRelease(vtable_reg);
                                return fat_reg;
                            }
                        }
                        if (rcInnerType(owner_ty)) |rc_inner| {
                            if (dynTraitName(rc_inner) != null) return inner;
                        }
                    }
                }
                const reg = try self.newTmp();
                self.out.writer().print("    {s} = &{s}\n", .{ reg, inner }) catch return CodegenError.CodegenError;
                if (exprResultNeedsRelease(borrow.expr)) {
                    self.borrow_source_temps.put(reg, inner) catch return CodegenError.OutOfMemory;
                }
                return reg;
            },
            .move_expr => |move| {
                const inner = try self.genExpr(move.expr, hoisted_allocs);
                return std.fmt.allocPrint(self.allocator, "^{s}", .{inner}) catch return CodegenError.OutOfMemory;
            },
            .deref_expr => |deref| {
                const generated_inner = try self.genExpr(deref.expr, hoisted_allocs);
                const inner = if (deref.expr.* == .move_expr and std.mem.startsWith(u8, generated_inner, "^")) generated_inner[1..] else generated_inner;
                const reg = try self.newTmp();
                const inner_ty = self.resolvedTypeForExpr(deref.expr) orelse return CodegenError.CodegenError;
                if (rcInnerType(inner_ty) != null) {
                    self.out.writer().print("    EXPAND RC_GET {s}, {s}\n", .{ reg, inner }) catch return CodegenError.CodegenError;
                    if (exprResultNeedsRelease(deref.expr)) try self.emitRelease(inner);
                    return reg;
                }
                if (arcInnerType(inner_ty) != null) {
                    self.out.writer().print("    EXPAND ARC_GET {s}, {s}\n", .{ reg, inner }) catch return CodegenError.CodegenError;
                    if (exprResultNeedsRelease(deref.expr)) try self.emitRelease(inner);
                    return reg;
                }
                if (boxInnerType(inner_ty)) |box_inner| {
                    if (dynTraitName(box_inner) != null) return inner;
                }
                const deref_ty = self.resolvedTypeForExpr(expr) orelse return CodegenError.CodegenError;
                self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ reg, inner, typeString(deref_ty) }) catch return CodegenError.CodegenError;
                if (deref.expr.* != .identifier and
                    (self.refcell_borrow_handles.contains(inner) or self.mutex_guard_handles.contains(inner) or self.rwlock_guard_handles.contains(inner)))
                {
                    try self.emitRelease(inner);
                } else if (exprResultNeedsRelease(deref.expr)) {
                    try self.emitRelease(inner);
                }
                return reg;
            },
            .cast_expr => |cast| {
                const inner = try self.genExpr(cast.expr, hoisted_allocs);
                const src_ty = self.resolvedTypeForExpr(cast.expr) orelse return CodegenError.CodegenError;
                if (isPointerCarrierCastType(src_ty) and isPointerCarrierCastType(cast.ty)) {
                    return inner;
                }
                // The SA `as` instruction consumes (moves) its source operand. When the
                // source is a bare owned Copy primitive local, consuming it would leave
                // that binding unusable for later reads (spurious UseAfterMove). Arithmetic
                // ops read Copy operands non-destructively, so casting `(x + 0)` works but
                // `x` alone does not. Materialize a non-consuming copy first so the original
                // binding survives, mirroring genBranchConditionReg.
                var src_reg = inner;
                if (cast.expr.* == .identifier and src_ty.* == .primitive) {
                    const resolved_name = self.resolveBindingName(cast.expr.identifier);
                    if (std.mem.eql(u8, inner, resolved_name) or
                        std.mem.eql(u8, inner, cast.expr.identifier) or
                        self.global_const_bindings.contains(cast.expr.identifier))
                    {
                        const copied = try self.newTmp();
                        try self.emitPrimitiveCopy(copied, inner, src_ty);
                        src_reg = copied;
                    }
                } else if (cast.expr.* == .cast_expr and src_ty.* == .primitive) {
                    // Chained cast `(x as A) as B`: the inner cast temp is fed
                    // directly into the outer `as`. When B is the same width as the
                    // original source register (e.g. `(f32 as i32) as f32`), the
                    // backend coalesces the round-trip cast back onto the original
                    // register, discarding the intermediate truncation. Materialize a
                    // non-consuming copy of the intermediate result so the outer cast
                    // operates on an independent register, mirroring the bare-identifier
                    // case above.
                    const copied = try self.newTmp();
                    try self.emitPrimitiveCopy(copied, inner, src_ty);
                    src_reg = copied;
                }
                const reg = try self.newTmp();
                self.out.writer().print("    {s} = {s} as {s}\n", .{ reg, src_reg, typeString(cast.ty) }) catch return CodegenError.CodegenError;
                return reg;
            },
            .field_expr => |field| {
                if (field.expr.* == .literal and field.expr.literal == .string_val and std.mem.eql(u8, field.field_name, "len")) {
                    const inner = try self.genExpr(field.expr, hoisted_allocs);
                    const reg = try self.newTmp();
                    self.out.writer().print("    EXPAND STRING_LEN {s}, {s}\n", .{ reg, inner }) catch return CodegenError.CodegenError;
                    return reg;
                }
                const inner = try self.genExpr(field.expr, hoisted_allocs);
                const reg = try self.newTmp();

                // Look up the struct's type to find the field offset
                const expr_ty = self.resolvedTypeForExpr(field.expr) orelse return CodegenError.CodegenError;
                const curr_ty = lowering_rules.peelBorrowPointerType(expr_ty);

                if (curr_ty.* == .tuple) {
                    const index = std.fmt.parseInt(usize, field.field_name, 10) catch return CodegenError.CodegenError;
                    const layout = tupleFieldLayout(curr_ty.tuple, index) orelse return CodegenError.CodegenError;
                    self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ reg, inner, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
                    if (self.fieldBaseResultNeedsRelease(field.expr, inner)) try self.emitRelease(inner);
                    return reg;
                }

                if (curr_ty.* != .user_defined) return CodegenError.CodegenError;
                const struct_decl = self.structDeclForType(curr_ty) orelse return CodegenError.CodegenError;
                // Old inline layout logic is intentionally kept here as comment per user preference.
                // It has been centralized into `fieldLayout(...)` so struct and union field access
                // share one layout rule instead of drifting apart in multiple call sites.
                //
                // var offset: usize = 0;
                // var found = false;
                // var field_ty_str: []const u8 = "i64";
                // for (struct_decl.fields) |f| {
                //     const size: usize = switch (f.ty.*) {
                //         .primitive => |p| switch (p) {
                //             .boolean => 1,
                //             .i8 => 1,
                //             .i16 => 2,
                //             .i32 => 4,
                //             .i64 => 8,
                //             .isize => 8,
                //             .u8 => 1,
                //             .u16 => 2,
                //             .u32 => 4,
                //             .u64 => 8,
                //             .usize => 8,
                //             .f32 => 4,
                //             .f64 => 8,
                //             .integer => 8,
                //             .float => 8,
                //             .void_type => 8,
                //         },
                //         else => 8, // pointer or borrow
                //     };
                //     if (size == 8) {
                //         offset = (offset + 7) & ~@as(usize, 7);
                //     }
                //     if (std.mem.eql(u8, f.name, field.field_name)) {
                //         found = true;
                //         field_ty_str = typeString(f.ty);
                //         break;
                //     }
                //     offset += size;
                // }
                // if (!found) return CodegenError.CodegenError;
                const layout = self.fieldLayoutForType(curr_ty, field.field_name) orelse return CodegenError.CodegenError;
                for (struct_decl.fields) |decl_field| {
                    if (std.mem.eql(u8, decl_field.name, field.field_name) and manuallyDropInnerType(decl_field.ty) != null) {
                        self.out.writer().print("    {s} = ptr_add {s}, {}\n", .{ reg, inner, layout.offset }) catch return CodegenError.CodegenError;
                        if (self.fieldBaseResultNeedsRelease(field.expr, inner)) try self.emitRelease(inner);
                        return reg;
                    }
                }
                self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ reg, inner, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
                if (self.fieldBaseResultNeedsRelease(field.expr, inner)) try self.emitRelease(inner);
                return reg;
            },
            .struct_literal => |lit| {
                const reg = try self.newTmp();
                try self.genStructLiteralInto(reg, &lit, hoisted_allocs);
                return reg;
            },
            .enum_literal => |lit| {
                const reg = try self.newTmp();
                try self.genEnumLiteralInto(reg, &lit, hoisted_allocs);
                return reg;
            },
            .tuple_literal => |lit| {
                const reg = try self.newTmp();
                try self.genTupleLiteralInto(reg, &lit, hoisted_allocs);
                return reg;
            },
            .array_literal => |lit| {
                const reg = try self.newTmp();
                try self.genArrayLiteralInto(reg, &lit, hoisted_allocs);
                return reg;
            },
            .repeat_array_literal => |lit| {
                const reg = try self.newTmp();
                try self.genRepeatArrayLiteralInto(reg, expr, &lit, hoisted_allocs);
                return reg;
            },
            .match_expr => |mat| {
                return try self.genMatchExpr(expr, &mat, hoisted_allocs);
            },
            .unsafe_expr => |ue| {
                if (self.active_inline_macro) |macro_decl| {
                    return try self.genUserMacroUnsafeValueInline(macro_decl, ue.body, hoisted_allocs);
                }
                const expr_ty = self.tc.expr_types.get(expr) orelse return CodegenError.CodegenError;
                if (isVoidType(expr_ty)) {
                    try self.genBlock(ue.body, hoisted_allocs);
                    return "return_ty_sentinel";
                }
                const reg = try self.newTmp();
                try self.genBlockTailValueInto(ue.body, reg, hoisted_allocs);
                return reg;
            },
            .inline_asm_expr => {
                return "return_ty_sentinel";
            },
            .await_expr => |aw| {
                const future_ty = self.tc.expr_types.get(aw.expr) orelse return CodegenError.CodegenError;
                const future_reg = try self.genExpr(aw.expr, hoisted_allocs);
                const plan = lowering_rules.planAwaitFutureWithReadiness(aw.expr, future_ty, self.current_async_return_ty, &self.future_readiness);
                if (self.current_async and plan.pending_return_if_async) {
                    try self.emitAwaitPendingCleanups(expr);
                    self.out.writer().print("    return {s}\n", .{future_reg}) catch return CodegenError.CodegenError;
                    self.async_pending_return_emitted = true;
                    return future_reg;
                }
                if (plan.poll_once_if_statically_ready) {
                    const future_obj = try self.genFutureObjectForState(future_reg);
                    const ctx = try self.newTmp();
                    const poll_reg = try self.newTmp();
                    const out_reg = try self.newTmp();
                    self.out.writer().print("    {s} = 0\n", .{ctx}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND FUTURE_POLL {s}, {s}, {s}\n", .{ poll_reg, future_obj, ctx }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND POLL_VALUE {s}, {s}\n", .{ out_reg, poll_reg }) catch return CodegenError.CodegenError;
                    try self.emitRelease(poll_reg);
                    try self.emitRelease(ctx);
                    try self.emitRelease(future_obj);
                    return out_reg;
                }
                if (self.current_async and plan.ready_pending_state_return_if_async) {
                    const state_reg = try self.newTmp();
                    const pending_reg = try self.newTmp();
                    const ready_label = try self.newLabel("L_AWAIT_READY");
                    const pending_label = try self.newLabel("L_AWAIT_PENDING");
                    self.out.writer().print("    {s} = load {s}+ReadyFuture_state as u64\n", .{ state_reg, future_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    {s} = eq {s}, 0\n", .{ pending_reg, state_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ pending_reg, pending_label, ready_label }) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{pending_label}) catch return CodegenError.CodegenError;
                    try self.emitAwaitPendingCleanups(expr);
                    self.out.writer().print("    return {s}\n", .{future_reg}) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{ready_label}) catch return CodegenError.CodegenError;
                    try self.emitRelease(state_reg);
                    try self.emitRelease(pending_reg);
                    const out_reg = try self.newTmp();
                    self.out.writer().print("    EXPAND FUTURE_READY_STATE_INTO_INNER {s}, {s}\n", .{ out_reg, future_reg }) catch return CodegenError.CodegenError;
                    try self.emitRelease(future_reg);
                    return out_reg;
                }
                if (!self.current_async and self.future_state_vtables.get(future_reg) != null) {
                    const ctx = try self.newTmp();
                    const poll_reg = try self.newTmp();
                    const ready_reg = try self.newTmp();
                    const loop_label = try self.newLabel("L_AWAIT_DYNAMIC_LOOP");
                    const ready_label = try self.newLabel("L_AWAIT_DYNAMIC_READY");
                    const pending_label = try self.newLabel("L_AWAIT_DYNAMIC_PENDING");
                    const out_reg = try self.newTmp();
                    self.out.writer().print("    {s} = 0\n", .{ctx}) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{loop_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND FUTURE_POLL_STATE {s}, {s}, {s}\n", .{ poll_reg, future_reg, ctx }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND POLL_IS_READY {s}, {s}\n", .{ ready_reg, poll_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ ready_reg, ready_label, pending_label }) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{pending_label}) catch return CodegenError.CodegenError;
                    try self.emitRelease(ready_reg);
                    try self.emitRelease(poll_reg);
                    self.out.writer().print("    jmp {s}\n\n", .{loop_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{ready_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND POLL_VALUE {s}, {s}\n", .{ out_reg, poll_reg }) catch return CodegenError.CodegenError;
                    try self.emitRelease(ready_reg);
                    try self.emitRelease(poll_reg);
                    try self.emitRelease(ctx);
                    try self.emitRelease(future_reg);
                    return out_reg;
                }
                if (!plan.ready_state_inner) return CodegenError.CodegenError;
                const out_reg = try self.newTmp();
                self.out.writer().print("    EXPAND FUTURE_READY_STATE_INTO_INNER {s}, {s}\n", .{ out_reg, future_reg }) catch return CodegenError.CodegenError;
                try self.emitRelease(future_reg);
                return out_reg;
            },
            .closure_literal => {
                const reg = try self.newTmp();
                self.out.writer().print("    {s} = 0\n", .{reg}) catch return CodegenError.CodegenError;
                return reg;
            },
            .index_expr => |idx| {
                const target_ty = self.resolvedTypeForExpr(idx.target) orelse return CodegenError.CodegenError;
                if (hashMapTypes(target_ty)) |hm| {
                    const map_reg = try self.genExpr(idx.target, hoisted_allocs);
                    const key_reg = try self.genHashMapKeyReg(idx.index, hoisted_allocs);
                    const value_ptr = try self.newTmp();
                    const found = try self.newTmp();
                    const hit_label = try self.newLabel("L_HASHMAP_INDEX_HIT");
                    const miss_label = try self.newLabel("L_HASHMAP_INDEX_MISS");
                    self.out.writer().print("    EXPAND MAP_GET {s}, {s}, {s}\n", .{ value_ptr, map_reg, key_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    {s} = ne {s}, 0\n", .{ found, value_ptr }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ found, hit_label, miss_label }) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{miss_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{found}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    panic(404)\n\n", .{}) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{hit_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{found}) catch return CodegenError.CodegenError;
                    const value_ty = self.resolvedTypeForExpr(expr) orelse hm.value;
                    const reg = try self.genLoadSlotValue(value_ptr, value_ty);
                    try self.emitRelease(value_ptr);
                    if (callArgNeedsRelease(idx.index)) try self.emitRelease(key_reg);
                    return reg;
                }
                if (btreeMapTypes(target_ty)) |bm| {
                    const map_reg = try self.genExpr(idx.target, hoisted_allocs);
                    const key_reg = try self.genHashMapKeyReg(idx.index, hoisted_allocs);
                    const raw_value = try self.newTmp();
                    const found = try self.newTmp();
                    const hit_label = try self.newLabel("L_BTREE_MAP_INDEX_HIT");
                    const miss_label = try self.newLabel("L_BTREE_MAP_INDEX_MISS");
                    self.out.writer().print("    EXPAND BTREE_MAP_TRY_GET {s}, {s}, {s}, {s}\n", .{ found, raw_value, map_reg, key_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ found, hit_label, miss_label }) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{miss_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{found}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    panic(404)\n\n", .{}) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{hit_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{found}) catch return CodegenError.CodegenError;
                    const reg = try self.newTmp();
                    self.out.writer().print("    {s} = {s} as {s}\n", .{ reg, raw_value, typeString(bm.value) }) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(idx.index)) try self.emitRelease(key_reg);
                    return reg;
                }
                if (vecElementType(target_ty)) |elem_ty| {
                    return try self.genVecIndexRead(&idx, elem_ty, hoisted_allocs);
                }
                if (vecDequeElementType(target_ty) != null) {
                    const deque_reg = try self.genExpr(idx.target, hoisted_allocs);
                    const index_reg = try self.genExpr(idx.index, hoisted_allocs);
                    const reg = try self.newTmp();
                    self.out.writer().print("    EXPAND VEC_DEQUE_GET {s}, {s}, {s}\n", .{ reg, deque_reg, index_reg }) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(idx.index)) try self.emitRelease(index_reg);
                    return reg;
                }
                const addr = try self.genIndexAddress(&idx, hoisted_allocs);
                const value_ty = self.resolvedTypeForExpr(expr) orelse addr.elem_ty;
                const reg = try self.genLoadSlotValue(addr.ptr, value_ty);
                try self.finishIndexAddress(addr);
                return reg;
            },
            .slice_expr => |slc| {
                return try self.genSliceExpr(&slc, hoisted_allocs);
            },
            .call_expr => |call| {
                if (lowering_rules.planResolvedStaticCallLowering(self.tc, expr, call, self.tc.expr_types.get(expr))) |lowering| {
                    return try self.genResolvedFunctionCall(lowering, &call, hoisted_allocs, call.associated_target == null);
                }
                if (std.mem.eql(u8, call.func_name, "format")) {
                    return try self.genFormatCall(&call, hoisted_allocs);
                }
                if (lowering_rules.isHashCall(call)) {
                    return try self.genHashCall(&call, hoisted_allocs);
                }
                if (lowering_rules.isDebugCall(call)) {
                    return try self.genDebugCall(&call, hoisted_allocs);
                }
                if (lowering_rules.isOptionSomeCall(call)) {
                    if (call.args.len != 1) return CodegenError.CodegenError;
                    const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    const reg = try self.newTmp();
                    self.out.writer().print("    EXPAND OPTION_NEW_SOME {s}, {s}\n", .{ reg, value_reg }) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                    return reg;
                }
                if (lowering_rules.isResultOkCall(call)) {
                    if (call.args.len != 1) return CodegenError.CodegenError;
                    const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    const reg = try self.newTmp();
                    self.out.writer().print("    EXPAND RESULT_NEW_OK {s}, {s}\n", .{ reg, value_reg }) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                    return reg;
                }
                if (lowering_rules.isResultErrCall(call)) {
                    if (call.args.len != 1) return CodegenError.CodegenError;
                    const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    const reg = try self.newTmp();
                    self.out.writer().print("    EXPAND RESULT_NEW_ERR {s}, {s}\n", .{ reg, value_reg }) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                    return reg;
                }
                if (lowering_rules.isPtrNullCall(call)) {
                    if (call.args.len != 0 or call.generics.len != 1) return CodegenError.CodegenError;
                    const reg = try self.newTmp();
                    self.out.writer().print("    EXPAND PTR_NULL {s}\n", .{reg}) catch return CodegenError.CodegenError;
                    return reg;
                }
                if (try self.genPollRuntimeCall(call, hoisted_allocs)) |poll_reg| return poll_reg;
                if (try self.genExecutorRuntimeCall(call, hoisted_allocs)) |executor_reg| return executor_reg;
                if (lowering_rules.planFutureRuntimeCall(call)) |future_plan| {
                    return try self.genFutureRuntimeCall(future_plan, call, hoisted_allocs);
                }
                if (std.mem.eql(u8, call.func_name, "std__ptr__read_volatile") or std.mem.eql(u8, call.func_name, "ptr__read_volatile")) {
                    if (call.args.len != 1) return CodegenError.CodegenError;
                    const ptr_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    const read_ty = self.tc.expr_types.get(expr) orelse return CodegenError.CodegenError;
                    const reg = try self.newTmp();
                    const macro_name = ptrReadVolatileMacroName(read_ty) orelse return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND {s} {s}, {s}\n", .{ macro_name, reg, ptr_reg }) catch return CodegenError.CodegenError;
                    if (call.args[0].* == .borrow_expr) {
                        const borrowed = call.args[0].borrow_expr.expr;
                        const is_direct_slot = borrowed.* == .identifier and std.mem.eql(u8, ptr_reg, borrowed.identifier);
                        if (!is_direct_slot) try self.emitRelease(ptr_reg);
                    } else if (callArgNeedsRelease(call.args[0])) try self.emitRelease(ptr_reg);
                    return reg;
                }
                if (call.associated_target) |target| {
                    const is_ptr_target = std.mem.eql(u8, target, "std__ptr") or std.mem.eql(u8, target, "ptr");
                    if (is_ptr_target and std.mem.eql(u8, call.func_name, "null")) {
                        if (call.args.len != 0 or call.generics.len != 1) return CodegenError.CodegenError;
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND PTR_NULL {s}\n", .{reg}) catch return CodegenError.CodegenError;
                        return reg;
                    }
                    if (is_ptr_target and std.mem.eql(u8, call.func_name, "read_volatile")) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const ptr_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const read_ty = self.tc.expr_types.get(expr) orelse return CodegenError.CodegenError;
                        const reg = try self.newTmp();
                        const macro_name = ptrReadVolatileMacroName(read_ty) orelse return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND {s} {s}, {s}\n", .{ macro_name, reg, ptr_reg }) catch return CodegenError.CodegenError;
                        if (call.args[0].* == .borrow_expr) {
                            const borrowed = call.args[0].borrow_expr.expr;
                            const is_direct_slot = borrowed.* == .identifier and std.mem.eql(u8, ptr_reg, borrowed.identifier);
                            if (!is_direct_slot) try self.emitRelease(ptr_reg);
                        } else if (callArgNeedsRelease(call.args[0])) try self.emitRelease(ptr_reg);
                        return reg;
                    }
                    if (lowering_rules.planFutureRuntimeCall(call)) |future_plan| {
                        return try self.genFutureRuntimeCall(future_plan, call, hoisted_allocs);
                    }
                    if (lowering_rules.planTaskRuntimeCall(call)) |task_plan| {
                        return try self.genTaskRuntimeCall(task_plan, call, hoisted_allocs);
                    }
                    if (lowering_rules.isMemForgetCall(call)) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        self.out.writer().print("    EXPAND MEM_FORGET_U64 {s}\n", .{value_reg}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    !{s}\n", .{value_reg}) catch return CodegenError.CodegenError;
                        if (rootIdentifier(call.args[0])) |name| {
                            self.consumed_bindings.put(name, {}) catch return CodegenError.OutOfMemory;
                        }
                        return "return_ty_sentinel";
                    }
                    if (lowering_rules.isManuallyDropNewCall(call)) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.stack_alloc_bindings.put(reg, {}) catch return CodegenError.OutOfMemory;
                        self.out.writer().print("    {s} = stack_alloc ManuallyDropU64_SIZE\n", .{reg}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND MANUALLY_DROP_U64_NEW {s}, {s}\n", .{ reg, value_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                        return reg;
                    }
                    if (lowering_rules.isManuallyDropIntoInnerCall(call)) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const slot_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND MANUALLY_DROP_U64_INTO_INNER {s}, {s}\n", .{ reg, slot_reg }) catch return CodegenError.CodegenError;
                        if (call.args[0].* == .identifier) {
                            self.consumed_bindings.put(call.args[0].identifier, {}) catch return CodegenError.OutOfMemory;
                        }
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(slot_reg);
                        return reg;
                    }
                    if (lowering_rules.isMpscChannelCall(call)) {
                        if (call.args.len != 0) return CodegenError.CodegenError;
                        const chan = try self.newTmp();
                        const tuple = try self.newTmp();
                        self.out.writer().print("    EXPAND MPSC_NEW {s}, 1024\n", .{chan}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    {s} = alloc 16\n", .{tuple}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    store {s}+0, {s} as ptr\n", .{ tuple, chan }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    store {s}+8, {s} as ptr\n", .{ tuple, chan }) catch return CodegenError.CodegenError;
                        return tuple;
                    }
                    if (lowering_rules.isThreadSpawnCall(call)) {
                        const helper = self.thread_spawn_helpers.get(expr) orelse return CodegenError.CodegenError;
                        const slot = try self.newTmp();
                        self.out.writer().print("    {s} = alloc {}\n", .{ slot, helper.slot_size }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    store {s}+0, 0 as i32\n", .{slot}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    store {s}+8, 0 as {s}\n", .{ slot, typeString(helper.ret_ty) }) catch return CodegenError.CodegenError;
                        if (helper.inline_join) {
                            const value_reg = try self.genExpr(helper.closure.body, hoisted_allocs);
                            self.out.writer().print("    store {s}+8, {s} as {s}\n", .{ slot, value_reg, typeString(helper.ret_ty) }) catch return CodegenError.CodegenError;
                            if (callArgNeedsRelease(helper.closure.body)) try self.emitRelease(value_reg);
                            self.out.writer().print("    store {s}+0, -1 as i32\n", .{slot}) catch return CodegenError.CodegenError;
                            self.inline_thread_handles.put(slot, {}) catch return CodegenError.OutOfMemory;
                            return slot;
                        }
                        for (helper.captures) |capture| {
                            const capture_name = self.resolveBindingName(capture.name);
                            // Sender clones are independent values at the SLA level.
                            // Preserve the clone register when transferring it into
                            // a thread slot; substituting the shared channel would
                            // move the receiver-side register more than once.
                            const capture_reg = capture_name;
                            // Non-copy payloads transfer ownership into the thread
                            // slot (same plan as SAB planEscapedClosureCapture).
                            // Store keeps a plain value write; emitForgetMovedValue
                            // then emits a SAB-style consume (`^name`) so branch
                            // merges agree when the else path also moves the local.
                            self.out.writer().print("    store {s}+{}, {s} as ptr\n", .{ slot, capture.offset, capture_reg }) catch return CodegenError.CodegenError;
                            if (capture.is_noncopy_payload) try self.emitForgetMovedValue(capture_reg);
                        }
                        self.out.writer().print("    call @{s}(*{s})\n", .{ helper.spawn_name, slot }) catch return CodegenError.CodegenError;
                        return slot;
                    }
                    if (lowering_rules.isBoxNewCall(call)) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const arg_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND BOX_NEW {s}, {s}\n", .{ reg, arg_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(arg_reg);
                        return reg;
                    }
                    if (lowering_rules.isBoxIntoRawCall(call)) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const box_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND BOX_INTO_RAW {s}, {s}\n", .{ reg, box_reg }) catch return CodegenError.CodegenError;
                        try self.emitRelease(box_reg);
                        return reg;
                    }
                    if (lowering_rules.isBoxFromRawCall(call)) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const raw_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND BOX_FROM_RAW {s}, {s}\n", .{ reg, raw_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(raw_reg);
                        return reg;
                    }
                    if (lowering_rules.isRcNewCall(call)) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const arg_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND RC_NEW {s}, {s}\n", .{ reg, arg_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(arg_reg);
                        return reg;
                    }
                    if (lowering_rules.isArcNewCall(call)) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const arg_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND ARC_NEW {s}, {s}\n", .{ reg, arg_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(arg_reg);
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "AtomicI32") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.stack_alloc_bindings.put(reg, {}) catch return CodegenError.OutOfMemory;
                        self.out.writer().print("    {s} = stack_alloc AtomicI32_SIZE\n", .{reg}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND ATOMIC_I32_INIT {s}, {s}\n", .{ reg, value_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "AtomicUsize") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.stack_alloc_bindings.put(reg, {}) catch return CodegenError.OutOfMemory;
                        self.out.writer().print("    {s} = stack_alloc AtomicUsize_SIZE\n", .{reg}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND ATOMIC_USIZE_INIT {s}, {s}\n", .{ reg, value_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "AtomicPtr") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.stack_alloc_bindings.put(reg, {}) catch return CodegenError.OutOfMemory;
                        self.out.writer().print("    {s} = stack_alloc AtomicPtr_SIZE\n", .{reg}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND ATOMIC_PTR_INIT {s}, {s}\n", .{ reg, value_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "Cell") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.stack_alloc_bindings.put(reg, {}) catch return CodegenError.OutOfMemory;
                        self.out.writer().print("    {s} = stack_alloc Cell_SIZE\n", .{reg}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND CELL_SET {s}, {s}\n", .{ reg, value_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "RefCell") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND REFCELL_U64_NEW {s}, {s}\n", .{ reg, value_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "Mutex") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const value_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
                        if (!isI32LikeType(value_ty)) return CodegenError.CodegenError;
                        const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND MUTEX_NEW_I32 {s}, {s}\n", .{ reg, value_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "RwLock") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const value_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
                        if (!isI32LikeType(value_ty)) return CodegenError.CodegenError;
                        const value_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND RWLOCK_NEW_I32 {s}, {s}\n", .{ reg, value_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(value_reg);
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "File") and std.mem.eql(u8, call.func_name, "open")) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const path_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
                        if (!isStringLikeType(path_ty)) return CodegenError.CodegenError;
                        const path_regs = try self.genStringLikePathRegs(call.args[0], path_ty, hoisted_allocs);
                        const status_reg = try self.newTmp();
                        const file_reg = try self.newTmp();
                        const result_reg = try self.newTmp();
                        const ok_reg = try self.newTmp();
                        const ok_label = try self.newLabel("L_FILE_OPEN_OK");
                        const err_label = try self.newLabel("L_FILE_OPEN_ERR");
                        const end_label = try self.newLabel("L_FILE_OPEN_END");
                        self.out.writer().print("    EXPAND FS_OPEN_READ {s}, {s}, {s}, {s}\n", .{ status_reg, file_reg, path_regs.ptr_reg, path_regs.len_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    {s} = eq {s}, SA_FS_OK\n", .{ ok_reg, status_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ ok_reg, ok_label, err_label }) catch return CodegenError.CodegenError;
                        self.out.writer().print("{s}:\n", .{ok_label}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND RESULT_NEW_OK {s}, {s}\n", .{ result_reg, file_reg }) catch return CodegenError.CodegenError;
                        // These branch-local temporaries must be consumed on both
                        // paths. Do not route through emitter cleanup tracking:
                        // it is intentionally shared while both arms are emitted.
                        self.out.writer().print("    !{s}\n    !{s}\n", .{ status_reg, file_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                        self.out.writer().print("{s}:\n", .{err_label}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND RESULT_NEW_ERR {s}, {s}\n", .{ result_reg, status_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    !{s}\n    !{s}\n", .{ status_reg, file_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                        self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                        try self.emitRelease(ok_reg);
                        try self.releaseStringLikePathRegs(path_regs);
                        self.file_open_results.put(result_reg, .{}) catch return CodegenError.OutOfMemory;
                        return result_reg;
                    }
                    if (lowering_rules.isPathMetadataCall(call)) {
                        if (call.args.len != 1) return CodegenError.CodegenError;
                        const path_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
                        if (!isStringLikeType(path_ty)) return CodegenError.CodegenError;
                        const path_regs = try self.genStringLikePathRegs(call.args[0], path_ty, hoisted_allocs);
                        const status_reg = try self.newTmp();
                        const meta_reg = try self.newTmp();
                        const result_reg = try self.newTmp();
                        const ok_reg = try self.newTmp();
                        const ok_label = try self.newLabel("L_PATH_METADATA_OK");
                        const err_label = try self.newLabel("L_PATH_METADATA_ERR");
                        const end_label = try self.newLabel("L_PATH_METADATA_END");
                        self.out.writer().print("    EXPAND FS_METADATA {s}, {s}, {s}, {s}\n", .{ status_reg, meta_reg, path_regs.ptr_reg, path_regs.len_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    {s} = eq {s}, SA_FS_OK\n", .{ ok_reg, status_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ ok_reg, ok_label, err_label }) catch return CodegenError.CodegenError;
                        self.out.writer().print("{s}:\n", .{ok_label}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND RESULT_NEW_OK {s}, {s}\n", .{ result_reg, meta_reg }) catch return CodegenError.CodegenError;
                        try self.emitRelease(status_reg);
                        try self.emitRelease(meta_reg);
                        self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                        self.out.writer().print("{s}:\n", .{err_label}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND RESULT_NEW_ERR {s}, {s}\n", .{ result_reg, status_reg }) catch return CodegenError.CodegenError;
                        try self.emitRelease(status_reg);
                        try self.emitRelease(meta_reg);
                        self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                        self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                        try self.emitRelease(ok_reg);
                        try self.releaseStringLikePathRegs(path_regs);
                        self.metadata_open_results.put(result_reg, .{}) catch return CodegenError.OutOfMemory;
                        return result_reg;
                    }
                    if (std.mem.eql(u8, target, "VecDeque") and std.mem.eql(u8, call.func_name, "from")) {
                        if (call.args.len != 1 or call.args[0].* != .array_literal) return CodegenError.CodegenError;
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND VEC_DEQUE_NEW {s}\n", .{reg}) catch return CodegenError.CodegenError;
                        for (call.args[0].array_literal.elements) |elem| {
                            const elem_reg = try self.genExpr(elem, hoisted_allocs);
                            self.out.writer().print("    EXPAND VEC_DEQUE_PUSH_BACK {s}, {s}\n", .{ reg, elem_reg }) catch return CodegenError.CodegenError;
                            if (callArgNeedsRelease(elem)) try self.emitRelease(elem_reg);
                        }
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "VecDeque") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return CodegenError.CodegenError;
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND VEC_DEQUE_NEW {s}\n", .{reg}) catch return CodegenError.CodegenError;
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "HashMap") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return CodegenError.CodegenError;
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND MAP_NEW {s}\n", .{reg}) catch return CodegenError.CodegenError;
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "BTreeMap") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return CodegenError.CodegenError;
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND BTREE_MAP_NEW {s}\n", .{reg}) catch return CodegenError.CodegenError;
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "HashSet") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return CodegenError.CodegenError;
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND SET_NEW {s}\n", .{reg}) catch return CodegenError.CodegenError;
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "BTreeSet") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return CodegenError.CodegenError;
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND BTREE_SET_NEW {s}\n", .{reg}) catch return CodegenError.CodegenError;
                        return reg;
                    }
                    if (std.mem.eql(u8, target, "Vec") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return CodegenError.CodegenError;
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND VEC_NEW {s}\n", .{reg}) catch return CodegenError.CodegenError;
                        return reg;
                    }
                    const method_key = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ target, call.func_name });
                    defer self.allocator.free(method_key);
                    if (self.tc.funcs.contains(method_key)) {
                        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
                        defer arg_regs.deinit();
                        var arg_release_regs = std.ArrayList(?[]const u8).init(self.allocator);
                        defer arg_release_regs.deinit();
                        var arg_consume_regs = std.ArrayList([]const u8).init(self.allocator);
                        defer arg_consume_regs.deinit();
                        const maybe_func = self.tc.funcs.get(method_key);
                        for (call.args, 0..) |arg, i| {
                            const sibling_mark = try self.pushCallSiblingArgExprs(call.args, i);
                            defer self.popExprLaterNodesTo(sibling_mark);
                            if (maybe_func) |func| {
                                if (i < func.params.len) {
                                    const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{
                                        .param = func.params[i],
                                        .arg_index = i,
                                        .receiver_style_auto_borrow = i == 0,
                                    });
                                    arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
                                    try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
                                    continue;
                                }
                            }
                            const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{});
                            arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
                            try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
                        }
                        const reg = try self.newTmp();
                        const lowered_method = try self.loweredFuncSymbol(method_key);
                        defer self.allocator.free(lowered_method);
                        self.out.writer().print("    {s} = call @{s}(", .{ reg, lowered_method }) catch return CodegenError.CodegenError;
                        for (arg_regs.items, 0..) |arg_reg, i| {
                            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
                            self.out.writer().print("{s}", .{arg_reg}) catch return CodegenError.CodegenError;
                        }
                        self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
                        try self.emitLoweredCallArgCleanups(arg_release_regs.items, arg_consume_regs.items, null);
                        return reg;
                    }
                }
                if (std.mem.eql(u8, call.func_name, "vec")) {
                    const reg = try self.newTmp();
                    self.out.writer().print("    EXPAND VEC_NEW {s}\n", .{reg}) catch return CodegenError.CodegenError;
                    const vec_ty = self.tc.expr_types.get(expr) orelse return CodegenError.CodegenError;
                    const elem_ty = vecElementType(vec_ty) orelse return CodegenError.CodegenError;
                    const elem_size = self.vecElementSlotSize(elem_ty);
                    const elem_transfers_ownership = self.vecElementPushConsumesSource(elem_ty);
                    for (call.args) |arg| {
                        const arg_reg = try self.genExpr(arg, hoisted_allocs);
                        self.out.writer().print("    EXPAND VEC_PUSH {s}, {s}, {}\n", .{ reg, arg_reg, elem_size }) catch return CodegenError.CodegenError;
                        if (elem_transfers_ownership) {
                            try self.emitForgetMovedValue(arg_reg);
                        } else if (self.callArgResultTempNeedsRelease(arg, arg_reg)) try self.emitRelease(arg_reg);
                    }
                    return reg;
                }
                if (lowering_rules.isLenCall(call) and call.args.len == 1) {
                    const arg_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (arg_ty) |ty| {
                        if (arrayType(ty)) |arr| {
                            const reg = try self.newTmp();
                            try self.emitIntConst(reg, @as(i64, @intCast(arr.len)));
                            return reg;
                        }
                        if (vecElementType(ty) != null) {
                            const recv = try self.genVecOwnerReceiver(call.args[0], hoisted_allocs);
                            const recv_reg = recv.reg;
                            const reg = try self.newTmp();
                            self.out.writer().print("    {s} = load {s}+Vec_len as u64\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                            if (recv.release_reg) |release_reg| try self.emitRelease(release_reg);
                            if (recv.consume_reg) |consume_reg| try self.emitForgetMovedValue(consume_reg);
                            return reg;
                        }
                        if (vecDequeElementType(ty) != null) {
                            const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                            const reg = try self.newTmp();
                            self.out.writer().print("    EXPAND VEC_DEQUE_LEN {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                            return reg;
                        }
                        if (hashMapTypes(ty) != null) {
                            const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                            const reg = try self.newTmp();
                            self.out.writer().print("    EXPAND MAP_LEN {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                            return reg;
                        }
                        if (btreeMapTypes(ty) != null) {
                            const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                            const reg = try self.newTmp();
                            self.out.writer().print("    EXPAND BTREE_MAP_LEN {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                            return reg;
                        }
                        if (hashSetTypes(ty) != null) {
                            const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                            const reg = try self.newTmp();
                            self.out.writer().print("    EXPAND SET_LEN {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                            return reg;
                        }
                        if (btreeSetTypes(ty) != null) {
                            const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                            const reg = try self.newTmp();
                            self.out.writer().print("    EXPAND BTREE_SET_LEN {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                            return reg;
                        }
                        if (isFormatStringType(ty)) {
                            const string_reg = try self.genExpr(call.args[0], hoisted_allocs);
                            const slice_reg = try self.newTmp();
                            const reg = try self.newTmp();
                            self.out.writer().print("    EXPAND STRING_BUF_AS_STR {s}, {s}\n", .{ slice_reg, string_reg }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    EXPAND STRING_LEN {s}, {s}\n", .{ reg, slice_reg }) catch return CodegenError.CodegenError;
                            try self.emitRelease(slice_reg);
                            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(string_reg);
                            return reg;
                        }
                    }
                    const inner = try self.genExpr(call.args[0], hoisted_allocs);
                    const reg = try self.newTmp();
                    self.out.writer().print("    EXPAND STRING_LEN {s}, {s}\n", .{ reg, inner }) catch return CodegenError.CodegenError;
                    return reg;
                }
                if (lowering_rules.isStrEqCall(call) and call.args.len == 2) {
                    const left_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
                    const right_ty = self.tc.expr_types.get(call.args[1]) orelse return CodegenError.CodegenError;
                    const left = try self.genExpr(call.args[0], hoisted_allocs);
                    const right = try self.genExpr(call.args[1], hoisted_allocs);
                    const left_arg = if (isFormatStringType(left_ty)) blk: {
                        const view = try self.newTmp();
                        self.out.writer().print("    EXPAND STRING_BUF_AS_STR {s}, {s}\n", .{ view, left }) catch return CodegenError.CodegenError;
                        break :blk view;
                    } else left;
                    const right_arg = if (isFormatStringType(right_ty)) blk: {
                        const view = try self.newTmp();
                        self.out.writer().print("    EXPAND STRING_BUF_AS_STR {s}, {s}\n", .{ view, right }) catch return CodegenError.CodegenError;
                        break :blk view;
                    } else right;
                    const reg = try self.newTmp();
                    self.out.writer().print("    EXPAND STR_EQ {s}, {s}, {s}\n", .{ reg, left_arg, right_arg }) catch return CodegenError.CodegenError;
                    if (!std.mem.eql(u8, left_arg, left)) try self.emitRelease(left_arg);
                    if (!std.mem.eql(u8, right_arg, right)) try self.emitRelease(right_arg);
                    if (callArgNeedsRelease(call.args[0])) try self.emitRelease(left);
                    if (callArgNeedsRelease(call.args[1])) try self.emitRelease(right);
                    return reg;
                }
                if (lowering_rules.isPushCall(call) and call.args.len == 2) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
                    const elem_ty = vecElementType(recv_ty) orelse return CodegenError.CodegenError;
                    const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    const arg_reg = try self.genExpr(call.args[1], hoisted_allocs);
                    self.out.writer().print("    EXPAND VEC_PUSH {s}, {s}, {}\n", .{ recv_reg, arg_reg, self.vecElementSlotSize(elem_ty) }) catch return CodegenError.CodegenError;
                    // POD / shallow-copy elements (including pure enums and structs of
                    // them) must remain usable after push so patterns like
                    // `registry.infos.push(info); return (registry, info);` match the
                    // typechecker and direct SAB backends.
                    if (self.vecElementPushConsumesSource(elem_ty)) {
                        try self.emitForgetMovedValue(arg_reg);
                    } else if (self.callArgResultTempNeedsRelease(call.args[1], arg_reg)) try self.emitRelease(arg_reg);
                    if (exprResultNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                    return "return_ty_sentinel";
                }
                if (lowering_rules.isPopCall(call) and call.args.len == 1) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
                    _ = vecElementType(recv_ty) orelse return CodegenError.CodegenError;
                    const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    const ok_reg = try self.newTmp();
                    const value_reg = try self.newTmp();
                    const value_slot = try self.newTmp();
                    const option_reg = try self.newTmp();
                    const some_label = try self.newLabel("L_VEC_POP_SOME");
                    const none_label = try self.newLabel("L_VEC_POP_NONE");
                    const end_label = try self.newLabel("L_VEC_POP_END");
                    self.out.writer().print("    {s} = alloc 8\n", .{value_slot}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    {s} = call @sa_vec_try_pop(&{s}, &{s})\n", .{ ok_reg, recv_reg, value_slot }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    {s} = load {s}+0 as u64\n", .{ value_reg, value_slot }) catch return CodegenError.CodegenError;
                    try self.emitRelease(value_slot);
                    self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ ok_reg, some_label, none_label }) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{some_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{ok_reg}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND OPTION_NEW_SOME {s}, {s}\n", .{ option_reg, value_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{value_reg}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{none_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{ok_reg}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{value_reg}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    EXPAND OPTION_NEW_NONE {s}\n", .{option_reg}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                    return option_reg;
                }
                if (lowering_rules.isRemoveCall(call) and call.args.len == 2) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
                    const elem_ty = vecElementType(recv_ty) orelse return CodegenError.CodegenError;
                    const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    const index_reg = try self.genExpr(call.args[1], hoisted_allocs);
                    const ok_reg = try self.newTmp();
                    const raw_reg = try self.newTmp();
                    const hit_label = try self.newLabel("L_VEC_REMOVE_OK");
                    const miss_label = try self.newLabel("L_VEC_REMOVE_OOB");
                    self.out.writer().print("    EXPAND VEC_REMOVE {s}, {s}, {s}, {s}, {}\n", .{ ok_reg, raw_reg, recv_reg, index_reg, self.vecElementSlotSize(elem_ty) }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ ok_reg, hit_label, miss_label }) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{miss_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    panic(86)\n\n", .{}) catch return CodegenError.CodegenError;
                    self.out.writer().print("{s}:\n", .{hit_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{ok_reg}) catch return CodegenError.CodegenError;
                    if (callArgNeedsRelease(call.args[1])) try self.emitRelease(index_reg);
                    if (std.mem.eql(u8, typeString(elem_ty), "u64")) return raw_reg;
                    const reg = try self.newTmp();
                    self.out.writer().print("    {s} = {s} as {s}\n", .{ reg, raw_reg, typeString(elem_ty) }) catch return CodegenError.CodegenError;
                    return reg;
                }
                if ((lowering_rules.isIterOrIntoIterCall(call)) and call.args.len == 1) {
                    return try self.genExpr(call.args[0], hoisted_allocs);
                }
                if (lowering_rules.isCopiedCall(call) and call.args.len == 1) {
                    const target_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (target_ty != null and optionInnerType(target_ty.?) != null) {
                        const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                        const reg = try self.newTmp();
                        self.out.writer().print("    EXPAND OPTION_COPIED_U64 {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                        return reg;
                    }
                    return try self.genExpr(call.args[0], hoisted_allocs);
                }
                if (std.mem.eql(u8, call.func_name, "fold") and call.args.len == 3 and call.args[0].* == .call_expr and call.args[2].* == .closure_literal) {
                    const iter_call = &call.args[0].call_expr;
                    if ((lowering_rules.isIterOrIntoIterCall(iter_call.*)) and iter_call.args.len == 1) {
                        const source_ty = self.tc.expr_types.get(iter_call.args[0]) orelse return CodegenError.CodegenError;
                        if (arrayType(source_ty) != null) {
                            return try self.genArrayIterFold(iter_call.args[0], call.args[1], &call.args[2].closure_literal, hoisted_allocs);
                        }
                    }
                }
                if (arrayIterSumSource(&call)) |source| {
                    const result = try self.genArrayIterSum(source, hoisted_allocs);
                    return result;
                }
                if (std.mem.eql(u8, call.func_name, "sum") and call.args.len == 1 and call.args[0].* == .call_expr) {
                    const inner = &call.args[0].call_expr;
                    if ((lowering_rules.isIterOrIntoIterCall(inner.*)) and inner.args.len == 1) {
                        const source_ty = self.tc.expr_types.get(inner.args[0]) orelse return CodegenError.CodegenError;
                        if (arrayType(source_ty) != null) {
                            return try self.genArrayIterSum(inner.args[0], hoisted_allocs);
                        }
                        if (sliceElementType(source_ty) != null) {
                            return try self.genSliceIterSum(inner.args[0], hoisted_allocs);
                        }
                        if (vecElementType(source_ty) != null) {
                            return try self.genVecIterSum(inner.args[0], null, hoisted_allocs);
                        }
                    }
                    if (lowering_rules.isCopiedCall(inner.*) and inner.args.len == 1 and inner.args[0].* == .call_expr) {
                        const copied_inner = &inner.args[0].call_expr;
                        if ((lowering_rules.isIterOrIntoIterCall(copied_inner.*)) and copied_inner.args.len == 1) {
                            const source_ty = self.tc.expr_types.get(copied_inner.args[0]) orelse return CodegenError.CodegenError;
                            if (arrayType(source_ty) != null) {
                                return try self.genArrayIterSum(copied_inner.args[0], hoisted_allocs);
                            }
                            if (sliceElementType(source_ty) != null) {
                                return try self.genSliceIterSum(copied_inner.args[0], hoisted_allocs);
                            }
                        }
                    }
                    if (lowering_rules.isMapCall(inner.*) and inner.args.len == 2 and inner.args[0].* == .call_expr) {
                        const iter_call = &inner.args[0].call_expr;
                        if ((lowering_rules.isIterOrIntoIterCall(iter_call.*)) and iter_call.args.len == 1 and inner.args[1].* == .closure_literal) {
                            const source_ty = self.tc.expr_types.get(iter_call.args[0]) orelse return CodegenError.CodegenError;
                            if (arrayType(source_ty) != null) {
                                return try self.genArrayIterMapSum(iter_call.args[0], &inner.args[1].closure_literal, hoisted_allocs);
                            }
                            if (vecElementType(source_ty) != null) {
                                return try self.genVecIterSum(iter_call.args[0], &inner.args[1].closure_literal, hoisted_allocs);
                            }
                        }
                    }
                    if (std.mem.eql(u8, inner.func_name, "filter") and inner.args.len == 2 and inner.args[0].* == .call_expr) {
                        const iter_call = &inner.args[0].call_expr;
                        if ((lowering_rules.isIterOrIntoIterCall(iter_call.*)) and iter_call.args.len == 1 and inner.args[1].* == .closure_literal) {
                            const source_ty = self.tc.expr_types.get(iter_call.args[0]) orelse return CodegenError.CodegenError;
                            if (arrayType(source_ty) != null) {
                                return try self.genArrayIterFilterSum(iter_call.args[0], &inner.args[1].closure_literal, hoisted_allocs);
                            }
                        }
                    }
                }

                if (std.mem.eql(u8, call.func_name, "collect") and call.args.len == 1 and call.generics.len == 1 and call.args[0].* == .call_expr) {
                    if (stringCollectSource(&call)) |source| {
                        return try self.genStringCollect(source, hoisted_allocs);
                    }
                }

                if (lowering_rules.isJoinCall(call) and call.args.len == 2 and call.args[0].* == .call_expr) {
                    if (stringJoinSource(&call)) |source| {
                        return try self.genStringJoin(source, call.args[1], hoisted_allocs);
                    }
                }

                if (self.closure_bindings.get(call.func_name)) |closure| {
                    return try self.genClosureCall(closure, &call, hoisted_allocs);
                }

                if (self.tc.fn_ptr_calls.contains(expr)) {
                    const fn_reg = if (self.thread_capture_regs.get(call.func_name)) |capture_reg|
                        capture_reg
                    else
                        self.resolveBindingName(call.func_name);
                    const fn_ptr_ty = self.localBindingTypeForName(call.func_name) orelse return CodegenError.CodegenError;
                    if (fn_ptr_ty.* != .fn_ptr or fn_ptr_ty.fn_ptr.params.len != call.args.len) return CodegenError.CodegenError;

                    var lowered_args = std.ArrayList(LoweredCallArg).init(self.allocator);
                    defer lowered_args.deinit();
                    var release_regs = std.ArrayList(?[]const u8).init(self.allocator);
                    defer release_regs.deinit();
                    var consume_regs = std.ArrayList([]const u8).init(self.allocator);
                    defer consume_regs.deinit();
                    for (call.args, fn_ptr_ty.fn_ptr.params) |arg, param_ty| {
                        const param = ast.Param{
                            .name = "",
                            .ty = param_ty,
                            .is_borrow = param_ty.* == .borrow,
                            .is_move = !lowering_rules.byValueRawPointerParam(.{
                                .name = "",
                                .ty = param_ty,
                                .is_borrow = param_ty.* == .borrow,
                                .is_move = false,
                            }) and !self.typeIsCopyValue(param_ty) and !lowering_rules.isBorrowLikeType(param_ty),
                        };
                        const lowered_arg = try self.genCallArgForParam(arg, param, hoisted_allocs);
                        lowered_args.append(lowered_arg) catch return CodegenError.OutOfMemory;
                        try self.appendLoweredCallArgCleanups(&release_regs, &consume_regs, lowered_arg);
                    }

                    var candidates = std.ArrayList([]const u8).init(self.allocator);
                    defer candidates.deinit();
                    var func_iter = self.tc.funcs.iterator();
                    while (func_iter.next()) |entry| {
                        const candidate = entry.value_ptr.*;
                        if (candidate.params.len != fn_ptr_ty.fn_ptr.params.len) continue;
                        if (!lowering_rules.typesEquivalent(candidate.ret_ty, fn_ptr_ty.fn_ptr.ret)) continue;
                        var params_match = true;
                        for (candidate.params, fn_ptr_ty.fn_ptr.params) |candidate_param, param_ty| {
                            if (!lowering_rules.typesEquivalent(candidate_param.ty, param_ty)) {
                                params_match = false;
                                break;
                            }
                        }
                        if (!params_match) continue;
                        candidates.append(entry.key_ptr.*) catch return CodegenError.OutOfMemory;
                    }

                    const returns_void = isVoidType(fn_ptr_ty.fn_ptr.ret);
                    const ret_reg = if (returns_void) "return_ty_sentinel" else try self.newTmp();
                    if (candidates.items.len == 0) {
                        const call_reg = try self.newTmp();
                        self.out.writer().print("    {s} = load {s}+0 as ptr\n", .{ call_reg, fn_reg }) catch return CodegenError.CodegenError;
                        if (returns_void) {
                            self.out.writer().print("    call_indirect {s}(", .{call_reg}) catch return CodegenError.CodegenError;
                        } else {
                            self.out.writer().print("    {s} = call_indirect {s}(", .{ ret_reg, call_reg }) catch return CodegenError.CodegenError;
                        }
                        for (lowered_args.items, 0..) |lowered_arg, i| {
                            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
                            self.out.writer().print("{s}", .{lowered_arg.reg}) catch return CodegenError.CodegenError;
                        }
                        self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
                        try self.emitRelease(call_reg);
                    } else {
                        const end_label = try self.newLabel("L_FNPTR_CALL_END");
                        for (candidates.items, 0..) |candidate_name, candidate_i| {
                            const lowered_name = try self.loweredFuncSymbol(candidate_name);
                            defer self.allocator.free(lowered_name);
                            if (candidate_i + 1 == candidates.items.len) {
                                const candidate_func = self.tc.funcs.get(candidate_name) orelse return CodegenError.CodegenError;
                                const inline_expr = if (self.fnPtrInlineCanConsumeMovedArgs(lowered_args.items, fn_ptr_ty.fn_ptr.params))
                                    self.fnPtrInlineCandidateExpr(candidate_func)
                                else
                                    null;
                                if (inline_expr) |inline_value_expr| {
                                    if (!returns_void) {
                                        const inline_value = try self.genExpr(@constCast(inline_value_expr), hoisted_allocs);
                                        self.out.writer().print("    {s} = add {s}, 0\n", .{ ret_reg, inline_value }) catch return CodegenError.CodegenError;
                                        if (exprResultNeedsRelease(inline_value_expr)) try self.emitRelease(inline_value);
                                    } else {
                                        _ = try self.genExpr(@constCast(inline_value_expr), hoisted_allocs);
                                    }
                                    try self.emitFnPtrInlineMovedArgConsumes(lowered_args.items, fn_ptr_ty.fn_ptr.params);
                                } else if (returns_void) {
                                    self.out.writer().print("    call @{s}(", .{lowered_name}) catch return CodegenError.CodegenError;
                                } else {
                                    self.out.writer().print("    {s} = call @{s}(", .{ ret_reg, lowered_name }) catch return CodegenError.CodegenError;
                                }
                                if (inline_expr == null) {
                                    for (lowered_args.items, 0..) |lowered_arg, i| {
                                        if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
                                        self.out.writer().print("{s}", .{lowered_arg.reg}) catch return CodegenError.CodegenError;
                                    }
                                    self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
                                }
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                                break;
                            }
                            const match_label = try self.newLabel("L_FNPTR_CALL_MATCH");
                            const next_label = try self.newLabel("L_FNPTR_CALL_NEXT");
                            const vt_reg = try self.newTmp();
                            const is_match = try self.newTmp();
                            const vt_name = try self.fnPtrVTableName(candidate_name);
                            defer self.allocator.free(vt_name);
                            self.out.writer().print("    {s} = &{s}\n", .{ vt_reg, vt_name }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    {s} = eq {s}, {s}\n", .{ is_match, fn_reg, vt_reg }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_match, match_label, next_label }) catch return CodegenError.CodegenError;
                            self.out.writer().print("{s}:\n", .{match_label}) catch return CodegenError.CodegenError;
                            self.out.writer().print("    !{s}\n    !{s}\n", .{ is_match, vt_reg }) catch return CodegenError.CodegenError;
                            const candidate_func = self.tc.funcs.get(candidate_name) orelse return CodegenError.CodegenError;
                            const inline_expr = if (self.fnPtrInlineCanConsumeMovedArgs(lowered_args.items, fn_ptr_ty.fn_ptr.params))
                                self.fnPtrInlineCandidateExpr(candidate_func)
                            else
                                null;
                            if (inline_expr) |inline_value_expr| {
                                if (!returns_void) {
                                    const inline_value = try self.genExpr(@constCast(inline_value_expr), hoisted_allocs);
                                    self.out.writer().print("    {s} = add {s}, 0\n", .{ ret_reg, inline_value }) catch return CodegenError.CodegenError;
                                    if (exprResultNeedsRelease(inline_value_expr)) try self.emitRelease(inline_value);
                                } else {
                                    _ = try self.genExpr(@constCast(inline_value_expr), hoisted_allocs);
                                }
                                try self.emitFnPtrInlineMovedArgConsumes(lowered_args.items, fn_ptr_ty.fn_ptr.params);
                            } else if (returns_void) {
                                self.out.writer().print("    call @{s}(", .{lowered_name}) catch return CodegenError.CodegenError;
                            } else {
                                self.out.writer().print("    {s} = call @{s}(", .{ ret_reg, lowered_name }) catch return CodegenError.CodegenError;
                            }
                            if (inline_expr == null) {
                                for (lowered_args.items, 0..) |lowered_arg, i| {
                                    if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
                                    self.out.writer().print("{s}", .{lowered_arg.reg}) catch return CodegenError.CodegenError;
                                }
                                self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
                            }
                            self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                            self.out.writer().print("{s}:\n", .{next_label}) catch return CodegenError.CodegenError;
                            self.out.writer().print("    !{s}\n    !{s}\n", .{ is_match, vt_reg }) catch return CodegenError.CodegenError;
                        }
                        self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                    }
                    try self.emitLoweredCallArgCleanups(release_regs.items, consume_regs.items, null);
                    return ret_reg;
                }

                if (call.args.len > 0) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty) |ty| {
                        if (senderInnerType(ty)) |_| {
                            if (lowering_rules.isCloneCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = if (call.args[0].* == .identifier)
                                    self.mpsc_sender_channels.get(call.args[0].identifier) orelse try self.genExpr(call.args[0], hoisted_allocs)
                                else
                                    try self.genExpr(call.args[0], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    {s} = add {s}, 0\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                                self.mpsc_sender_channels.put(reg, recv_reg) catch return CodegenError.OutOfMemory;
                                self.mpsc_sender_bindings.put(reg, {}) catch return CodegenError.OutOfMemory;
                                return reg;
                            }
                            if (lowering_rules.isSendCall(call)) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = if (call.args[0].* == .identifier)
                                    self.mpsc_sender_channels.get(call.args[0].identifier) orelse try self.genExpr(call.args[0], hoisted_allocs)
                                else
                                    try self.genExpr(call.args[0], hoisted_allocs);
                                const value_reg = try self.genExpr(call.args[1], hoisted_allocs);
                                const send_value = try self.newTmp();
                                self.out.writer().print("    {s} = add {s}, 0\n", .{ send_value, value_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    EXPAND MPSC_SEND {s}, {s}\n", .{ recv_reg, send_value }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(value_reg);
                                const result_reg = try self.newTmp();
                                self.out.writer().print("    EXPAND RESULT_NEW_OK {s}, 0\n", .{result_reg}) catch return CodegenError.CodegenError;
                                return result_reg;
                            }
                        }
                        if (receiverInnerType(ty)) |_| {
                            if (lowering_rules.isRecvCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const value_reg = try self.newTmp();
                                self.out.writer().print("    EXPAND MPSC_RECV {s}, {s}\n", .{ value_reg, recv_reg }) catch return CodegenError.CodegenError;
                                const result_reg = try self.newTmp();
                                self.out.writer().print("    EXPAND RESULT_NEW_OK {s}, {s}\n", .{ result_reg, value_reg }) catch return CodegenError.CodegenError;
                                try self.emitRelease(value_reg);
                                return result_reg;
                            }
                        }
                        if (joinHandleInnerType(ty)) |inner_ty| {
                            if (lowering_rules.isJoinCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                if (self.inline_thread_handles.contains(recv_reg)) {
                                    const result_reg = try self.newTmp();
                                    const value = try self.newTmp();
                                    const ok_tag = try self.newTmp();
                                    self.out.writer().print("    {s} = load {s}+8 as {s}\n", .{ value, recv_reg, typeString(inner_ty) }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = alloc 24\n", .{result_reg}) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    {s} = 0\n", .{ok_tag}) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    store {s}+0, {s} as u64\n", .{ result_reg, ok_tag }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    store {s}+8, {s} as {s}\n", .{ result_reg, value, typeString(inner_ty) }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    store {s}+16, {s} as u64\n", .{ result_reg, ok_tag }) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    !{s}\n", .{ok_tag}) catch return CodegenError.CodegenError;
                                    self.out.writer().print("    !{s}\n", .{value}) catch return CodegenError.CodegenError;
                                    _ = self.inline_thread_handles.remove(recv_reg);
                                    try self.emitRelease(recv_reg);
                                    return result_reg;
                                }
                                const handle = try self.newTmp();
                                const is_inline = try self.newTmp();
                                const status = try self.newTmp();
                                const is_ok = try self.newTmp();
                                const result_reg = try self.newTmp();
                                const inline_label = try self.newLabel("L_THREAD_JOIN_INLINE");
                                const pthread_label = try self.newLabel("L_THREAD_JOIN_PTHREAD");
                                const ok_label = try self.newLabel("L_THREAD_JOIN_OK");
                                const err_label = try self.newLabel("L_THREAD_JOIN_ERR");
                                const end_label = try self.newLabel("L_THREAD_JOIN_END");
                                self.out.writer().print("    {s} = load {s}+0 as i32\n", .{ handle, recv_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = eq {s}, -1\n", .{ is_inline, handle }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_inline, inline_label, pthread_label }) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{inline_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_inline}) catch return CodegenError.CodegenError;
                                const inline_value = try self.newTmp();
                                self.out.writer().print("    {s} = load {s}+8 as {s}\n", .{ inline_value, recv_reg, typeString(inner_ty) }) catch return CodegenError.CodegenError;
                                const inline_ok_tag = try self.newTmp();
                                self.out.writer().print("    {s} = alloc 24\n", .{result_reg}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = 0\n", .{inline_ok_tag}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    store {s}+0, {s} as u64\n", .{ result_reg, inline_ok_tag }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    store {s}+8, {s} as {s}\n", .{ result_reg, inline_value, typeString(inner_ty) }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    store {s}+16, {s} as u64\n", .{ result_reg, inline_ok_tag }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{inline_ok_tag}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{inline_value}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{pthread_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_inline}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    EXPAND THREAD_JOIN_STATUS {s}, {s}, *{s}\n", .{ status, handle, recv_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    EXPAND THREAD_DROP {s}\n", .{handle}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = eq {s}, 0\n", .{ is_ok, status }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_ok, ok_label, err_label }) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{ok_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_ok}) catch return CodegenError.CodegenError;
                                const value = try self.newTmp();
                                self.out.writer().print("    {s} = load {s}+8 as {s}\n", .{ value, recv_reg, typeString(inner_ty) }) catch return CodegenError.CodegenError;
                                const ok_tag = try self.newTmp();
                                self.out.writer().print("    {s} = alloc 24\n", .{result_reg}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = 0\n", .{ok_tag}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    store {s}+0, {s} as u64\n", .{ result_reg, ok_tag }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    store {s}+8, {s} as {s}\n", .{ result_reg, value, typeString(inner_ty) }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    store {s}+16, {s} as u64\n", .{ result_reg, ok_tag }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{ok_tag}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{value}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{status}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{err_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_ok}) catch return CodegenError.CodegenError;
                                const err_value = try self.newTmp();
                                self.out.writer().print("    {s} = add {s}, 0\n", .{ err_value, status }) catch return CodegenError.CodegenError;
                                const err_tag = try self.newTmp();
                                const err_zero = try self.newTmp();
                                self.out.writer().print("    {s} = alloc 24\n", .{result_reg}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = 1\n", .{err_tag}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = 0\n", .{err_zero}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    store {s}+0, {s} as u64\n", .{ result_reg, err_tag }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    store {s}+8, {s} as {s}\n", .{ result_reg, err_zero, typeString(inner_ty) }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    store {s}+16, {s} as i64\n", .{ result_reg, err_value }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{err_zero}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{err_tag}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{err_value}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{status}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{handle}) catch return CodegenError.CodegenError;
                                try self.markConsumedBinding(recv_reg);
                                return result_reg;
                            }
                        }
                        if (optionInnerType(ty) != null) {
                            if (lowering_rules.isOptionQueryCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const reg = try self.newTmp();
                                if (lowering_rules.isIsSomeCall(call)) {
                                    self.out.writer().print("    EXPAND OPTION_IS_SOME {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                                } else {
                                    self.out.writer().print("    EXPAND OPTION_IS_NONE {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                                }
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return reg;
                            }
                            const option_closure_plan = lowering_rules.planOptionClosureCall(call, ty);
                            if (option_closure_plan != null and option_closure_plan.?.isMap()) {
                                if (call.args.len != 2 or call.args[1].* != .closure_literal) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const is_some = try self.newTmp();
                                self.out.writer().print("    EXPAND OPTION_IS_SOME {s}, {s}\n", .{ is_some, recv_reg }) catch return CodegenError.CodegenError;
                                const some_label = try self.newLabel("L_OPTION_MAP_SOME");
                                const none_label = try self.newLabel("L_OPTION_MAP_NONE");
                                const end_label = try self.newLabel("L_OPTION_MAP_END");
                                const result_reg = try self.newTmp();
                                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_some, some_label, none_label }) catch return CodegenError.CodegenError;

                                self.out.writer().print("{s}:\n", .{some_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_some}) catch return CodegenError.CodegenError;
                                const value_reg = try self.newTmp();
                                self.out.writer().print("    EXPAND OPTION_GET {s}, {s}\n", .{ value_reg, recv_reg }) catch return CodegenError.CodegenError;
                                const mapped_reg = try self.genInlineClosureUnary(&call.args[1].closure_literal, value_reg, hoisted_allocs);
                                self.out.writer().print("    EXPAND OPTION_NEW_SOME {s}, {s}\n", .{ result_reg, mapped_reg }) catch return CodegenError.CodegenError;
                                try self.emitRelease(value_reg);
                                if (!std.mem.eql(u8, mapped_reg, value_reg)) try self.emitRelease(mapped_reg);
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;

                                self.out.writer().print("{s}:\n", .{none_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_some}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    EXPAND OPTION_NEW_NONE {s}\n", .{result_reg}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;

                                self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return result_reg;
                            }
                            if (option_closure_plan != null and option_closure_plan.?.isAndThen()) {
                                if (call.args.len != 2 or call.args[1].* != .closure_literal) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const is_some = try self.newTmp();
                                self.out.writer().print("    EXPAND OPTION_IS_SOME {s}, {s}\n", .{ is_some, recv_reg }) catch return CodegenError.CodegenError;
                                const some_label = try self.newLabel("L_OPTION_AND_THEN_SOME");
                                const none_label = try self.newLabel("L_OPTION_AND_THEN_NONE");
                                const end_label = try self.newLabel("L_OPTION_AND_THEN_END");
                                const result_slot = try self.newTmp();
                                self.out.writer().print("    {s} = stack_alloc 8\n", .{result_slot}) catch return CodegenError.CodegenError;
                                try self.prepareResultSlotRefCellCompanion(result_slot, ty);
                                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_some, some_label, none_label }) catch return CodegenError.CodegenError;

                                self.out.writer().print("{s}:\n", .{some_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_some}) catch return CodegenError.CodegenError;
                                const value_reg = try self.newTmp();
                                self.out.writer().print("    EXPAND OPTION_GET {s}, {s}\n", .{ value_reg, recv_reg }) catch return CodegenError.CodegenError;
                                const chained_reg = try self.genInlineClosureUnary(&call.args[1].closure_literal, value_reg, hoisted_allocs);
                                self.out.writer().print("    store {s}+0, {s} as ptr\n", .{ result_slot, chained_reg }) catch return CodegenError.CodegenError;
                                try self.storeResultSlotTransferredValueState(result_slot, chained_reg, ty, true);
                                try self.emitRelease(value_reg);
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;

                                self.out.writer().print("{s}:\n", .{none_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_some}) catch return CodegenError.CodegenError;
                                const none_reg = try self.newTmp();
                                self.out.writer().print("    EXPAND OPTION_NEW_NONE {s}\n", .{none_reg}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    store {s}+0, {s} as ptr\n", .{ result_slot, none_reg }) catch return CodegenError.CodegenError;
                                try self.storeResultSlotTransferredValueState(result_slot, none_reg, ty, true);
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;

                                self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                                const result_reg = try self.newTmp();
                                self.out.writer().print("    {s} = load {s}+0 as ptr\n", .{ result_reg, result_slot }) catch return CodegenError.CodegenError;
                                try self.loadResultSlotTransferredValueState(result_reg, result_slot, ty);
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return result_reg;
                            }
                            if (lowering_rules.isUnwrapCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND OPTION_UNWRAP {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0]) and !isNonOwningPointerCarrierCastArg(call.args[0])) try self.emitRelease(recv_reg);
                                return reg;
                            }
                            if (lowering_rules.isUnwrapOrCall(call)) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const default_reg = try self.genExpr(call.args[1], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND OPTION_UNWRAP_OR {s}, {s}, {s}\n", .{ reg, recv_reg, default_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(default_reg);
                                return reg;
                            }
                            if (option_closure_plan != null and option_closure_plan.?.isUnwrapOrElse()) {
                                if (call.args.len != 2 or call.args[1].* != .closure_literal) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const is_some = try self.newTmp();
                                self.out.writer().print("    EXPAND OPTION_IS_SOME {s}, {s}\n", .{ is_some, recv_reg }) catch return CodegenError.CodegenError;
                                const some_label = try self.newLabel("L_OPTION_UNWRAP_OR_ELSE_SOME");
                                const none_label = try self.newLabel("L_OPTION_UNWRAP_OR_ELSE_NONE");
                                const end_label = try self.newLabel("L_OPTION_UNWRAP_OR_ELSE_END");
                                const result_slot = try self.newTmp();
                                const inner_ty = optionInnerType(ty) orelse return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = stack_alloc 8\n", .{result_slot}) catch return CodegenError.CodegenError;
                                try self.prepareResultSlotRefCellCompanion(result_slot, inner_ty);
                                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_some, some_label, none_label }) catch return CodegenError.CodegenError;

                                self.out.writer().print("{s}:\n", .{some_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_some}) catch return CodegenError.CodegenError;
                                const value_reg = try self.newTmp();
                                self.out.writer().print("    EXPAND OPTION_GET {s}, {s}\n", .{ value_reg, recv_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ result_slot, value_reg, typeString(inner_ty) }) catch return CodegenError.CodegenError;
                                try self.storeResultSlotTransferredValueState(result_slot, value_reg, inner_ty, true);
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;

                                self.out.writer().print("{s}:\n", .{none_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_some}) catch return CodegenError.CodegenError;
                                const default_reg = try self.genInlineClosureNullary(&call.args[1].closure_literal, hoisted_allocs);
                                self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ result_slot, default_reg, typeString(inner_ty) }) catch return CodegenError.CodegenError;
                                try self.storeResultSlotTransferredValueState(result_slot, default_reg, inner_ty, true);
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;

                                self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                                const reg = try self.newTmp();
                                self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ reg, result_slot, typeString(inner_ty) }) catch return CodegenError.CodegenError;
                                try self.loadResultSlotTransferredValueState(reg, result_slot, inner_ty);
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return reg;
                            }
                            if (lowering_rules.isUnwrapOrDefaultCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND OPTION_UNWRAP_OR_DEFAULT {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return reg;
                            }
                        }
                        if (std.mem.eql(u8, call.func_name, "is_file") or std.mem.eql(u8, call.func_name, "is_dir") or std.mem.eql(u8, call.func_name, "is_symlink") or std.mem.eql(u8, call.func_name, "modified_ms") or std.mem.eql(u8, call.func_name, "created_ms")) {
                            if (call.args.len != 1) return CodegenError.CodegenError;
                            const meta_recv_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
                            if (isMetadataType(meta_recv_ty)) {
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const reg = try self.newTmp();
                                if (std.mem.eql(u8, call.func_name, "is_file")) {
                                    self.out.writer().print("    EXPAND FS_METADATA_IS_FILE {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                                } else if (std.mem.eql(u8, call.func_name, "is_dir")) {
                                    self.out.writer().print("    EXPAND FS_METADATA_IS_DIR {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                                } else if (std.mem.eql(u8, call.func_name, "is_symlink")) {
                                    self.out.writer().print("    EXPAND FS_METADATA_IS_SYMLINK {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                                } else if (std.mem.eql(u8, call.func_name, "modified_ms")) {
                                    self.out.writer().print("    EXPAND FS_METADATA_MODIFIED_MS {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                                } else {
                                    self.out.writer().print("    EXPAND FS_METADATA_CREATED_MS {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                                }
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return reg;
                            }
                        }
                        if (resultOkType(ty) != null) {
                            if (lowering_rules.isIsOkCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND RESULT_IS_OK {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return reg;
                            }
                            if (lowering_rules.isIsErrCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND RESULT_IS_ERR {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return reg;
                            }
                            if (lowering_rules.isMapCall(call)) {
                                if (call.args.len != 2 or call.args[1].* != .closure_literal) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const is_ok = try self.newTmp();
                                self.out.writer().print("    EXPAND RESULT_IS_OK {s}, {s}\n", .{ is_ok, recv_reg }) catch return CodegenError.CodegenError;
                                const ok_label = try self.newLabel("L_RESULT_MAP_OK");
                                const err_label = try self.newLabel("L_RESULT_MAP_ERR");
                                const end_label = try self.newLabel("L_RESULT_MAP_END");
                                const result_reg = try self.newTmp();
                                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_ok, ok_label, err_label }) catch return CodegenError.CodegenError;

                                self.out.writer().print("{s}:\n", .{ok_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_ok}) catch return CodegenError.CodegenError;
                                const value_reg = try self.newTmp();
                                self.out.writer().print("    EXPAND RESULT_GET_OK {s}, {s}\n", .{ value_reg, recv_reg }) catch return CodegenError.CodegenError;
                                const mapped_reg = try self.genInlineClosureUnary(&call.args[1].closure_literal, value_reg, hoisted_allocs);
                                self.out.writer().print("    EXPAND RESULT_NEW_OK {s}, {s}\n", .{ result_reg, mapped_reg }) catch return CodegenError.CodegenError;
                                try self.emitRelease(value_reg);
                                if (!std.mem.eql(u8, mapped_reg, value_reg)) try self.emitRelease(mapped_reg);
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;

                                self.out.writer().print("{s}:\n", .{err_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_ok}) catch return CodegenError.CodegenError;
                                const err_value = try self.newTmp();
                                self.out.writer().print("    EXPAND RESULT_GET_ERR {s}, {s}\n", .{ err_value, recv_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    EXPAND RESULT_NEW_ERR {s}, {s}\n", .{ result_reg, err_value }) catch return CodegenError.CodegenError;
                                try self.emitRelease(err_value);
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;

                                self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return result_reg;
                            }
                            if (lowering_rules.isUnwrapCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const result_recv_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
                                const ok_ty = resultOkType(result_recv_ty) orelse return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const reg = try self.newTmp();
                                const tag = try self.newTmp();
                                const is_ok = try self.newTmp();
                                const ok_label = try self.newLabel("L_RESULT_UNWRAP_OK");
                                const err_label = try self.newLabel("L_RESULT_UNWRAP_ERR");
                                const end_label = try self.newLabel("L_RESULT_UNWRAP_END");
                                self.out.writer().print("    {s} = load {s}+0 as u64\n", .{ tag, recv_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = eq {s}, 0\n", .{ is_ok, tag }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_ok, ok_label, err_label }) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{ok_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_ok}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = load {s}+8 as {s}\n", .{ reg, recv_reg, typeString(ok_ty) }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{tag}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{err_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{is_ok}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    panic(17)\n", .{}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = 0\n", .{reg}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{tag}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                                if (self.mutex_lock_results.get(recv_reg)) |handle| {
                                    self.mutex_guard_handles.put(reg, handle) catch return CodegenError.OutOfMemory;
                                    _ = self.mutex_lock_results.remove(recv_reg);
                                }
                                if (self.rwlock_lock_results.get(recv_reg)) |handle| {
                                    self.rwlock_guard_handles.put(reg, handle) catch return CodegenError.OutOfMemory;
                                    _ = self.rwlock_lock_results.remove(recv_reg);
                                }
                                if (self.file_open_results.contains(recv_reg)) {
                                    self.file_bindings.put(reg, {}) catch return CodegenError.OutOfMemory;
                                    _ = self.file_open_results.remove(recv_reg);
                                }
                                if (self.metadata_open_results.contains(recv_reg)) {
                                    self.metadata_bindings.put(reg, {}) catch return CodegenError.OutOfMemory;
                                    _ = self.metadata_open_results.remove(recv_reg);
                                }
                                try self.releaseTemporaryHandleRegister(recv_reg);
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return reg;
                            }
                            if (lowering_rules.isUnwrapOrCall(call)) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const default_reg = try self.genExpr(call.args[1], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND RESULT_UNWRAP_OR {s}, {s}, {s}\n", .{ reg, recv_reg, default_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(default_reg);
                                return reg;
                            }
                        }
                        if (isAtomicI32Type(ty)) {
                            if (lowering_rules.isLoadCall(call)) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const ordering = try atomicOrderingToken(call.args[1]);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND ATOMIC_I32_LOAD {s}, {s}, {s}\n", .{ reg, recv_reg, ordering }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return reg;
                            }
                            if (lowering_rules.isStoreCall(call)) {
                                if (call.args.len != 3) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const value_reg = try self.genExpr(call.args[1], hoisted_allocs);
                                const ordering = try atomicOrderingToken(call.args[2]);
                                self.out.writer().print("    EXPAND ATOMIC_I32_STORE {s}, {s}, {s}\n", .{ recv_reg, value_reg, ordering }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0]) and !isNonOwningPointerCarrierCastArg(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(value_reg);
                                return "return_ty_sentinel";
                            }
                            if (lowering_rules.isFetchAddCall(call)) {
                                if (call.args.len != 3) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const value_reg = try self.genExpr(call.args[1], hoisted_allocs);
                                const ordering = try atomicOrderingToken(call.args[2]);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND ATOMIC_I32_FETCH_ADD {s}, {s}, {s}, {s}\n", .{ reg, recv_reg, value_reg, ordering }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0]) and !isNonOwningPointerCarrierCastArg(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(value_reg);
                                return reg;
                            }
                            if (lowering_rules.isCompareExchangeCall(call)) {
                                if (call.args.len != 5) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const expected_reg = try self.genExpr(call.args[1], hoisted_allocs);
                                const new_reg = try self.genExpr(call.args[2], hoisted_allocs);
                                const success_ordering = try atomicOrderingToken(call.args[3]);
                                const failure_ordering = try atomicOrderingToken(call.args[4]);
                                const old_reg = try self.newTmp();
                                const ok_reg = try self.newTmp();
                                const result_reg = try self.newTmp();
                                const ok_label = try self.newLabel("L_ATOMIC_CMPXCHG_OK");
                                const err_label = try self.newLabel("L_ATOMIC_CMPXCHG_ERR");
                                const end_label = try self.newLabel("L_ATOMIC_CMPXCHG_END");
                                self.out.writer().print("    EXPAND ATOMIC_I32_COMPARE_EXCHANGE {s}, {s}, {s}, {s}, {s}, {s}, {s}\n", .{ old_reg, ok_reg, recv_reg, expected_reg, new_reg, success_ordering, failure_ordering }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ ok_reg, ok_label, err_label }) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{ok_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{ok_reg}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    EXPAND RESULT_NEW_OK {s}, {s}\n", .{ result_reg, old_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{err_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    !{s}\n", .{ok_reg}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    EXPAND RESULT_NEW_ERR {s}, {s}\n", .{ result_reg, old_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(expected_reg);
                                if (callArgNeedsRelease(call.args[2])) try self.emitRelease(new_reg);
                                try self.emitRelease(old_reg);
                                return result_reg;
                            }
                        }
                        if (isAtomicUsizeType(ty)) {
                            if (lowering_rules.isLoadCall(call)) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const ordering = try atomicOrderingToken(call.args[1]);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND ATOMIC_USIZE_LOAD {s}, {s}, {s}\n", .{ reg, recv_reg, ordering }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0]) and !isNonOwningPointerCarrierCastArg(call.args[0])) try self.emitRelease(recv_reg);
                                return reg;
                            }
                            if (lowering_rules.isStoreCall(call)) {
                                if (call.args.len != 3) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const value_reg = try self.genExpr(call.args[1], hoisted_allocs);
                                const ordering = try atomicOrderingToken(call.args[2]);
                                self.out.writer().print("    EXPAND ATOMIC_USIZE_STORE {s}, {s}, {s}\n", .{ recv_reg, value_reg, ordering }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0]) and !isNonOwningPointerCarrierCastArg(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(value_reg);
                                return "return_ty_sentinel";
                            }
                            if (lowering_rules.isFetchAddCall(call)) {
                                if (call.args.len != 3) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const value_reg = try self.genExpr(call.args[1], hoisted_allocs);
                                const ordering = try atomicOrderingToken(call.args[2]);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND ATOMIC_USIZE_FETCH_ADD {s}, {s}, {s}, {s}\n", .{ reg, recv_reg, value_reg, ordering }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0]) and !isNonOwningPointerCarrierCastArg(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(value_reg);
                                return reg;
                            }
                        }
                        if (atomicPtrInnerType(ty) != null) {
                            if (lowering_rules.isLoadCall(call)) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const ordering = try atomicOrderingToken(call.args[1]);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND ATOMIC_PTR_LOAD {s}, {s}, {s}\n", .{ reg, recv_reg, ordering }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return reg;
                            }
                        }
                        if (cellInnerType(ty) != null) {
                            if (lowering_rules.isGetCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND CELL_GET {s}, {s}\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return reg;
                            }
                            if (lowering_rules.isSetCall(call)) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const value_reg = try self.genExpr(call.args[1], hoisted_allocs);
                                self.out.writer().print("    EXPAND CELL_SET {s}, {s}\n", .{ recv_reg, value_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(value_reg);
                                return "return_ty_sentinel";
                            }
                        }
                        if (lowering_rules.planRefCellBorrowCall(call, ty)) |borrow_plan| {
                            {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const ok_reg = try self.newTmp();
                                const borrow_slot_reg = try self.newTmp();
                                const err_label = try self.newLabel("L_REFCELL_BORROW_PANIC");
                                const end_label = try self.newLabel("L_REFCELL_BORROW_END");
                                const guard_plan = lowering_rules.planRefCellBorrowRuntimeGuard(borrow_plan);
                                self.out.writer().print("    EXPAND {s} {s}, {s}, {s}\n", .{ borrow_plan.tryBorrowMacroName(), ok_reg, borrow_slot_reg, recv_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ ok_reg, end_label, err_label }) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{err_label}) catch return CodegenError.CodegenError;
                                if (guard_plan.release_status_on_conflict) self.out.writer().print("    !{s}\n", .{ok_reg}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    panic({})\n", .{guard_plan.conflict_panic_code}) catch return CodegenError.CodegenError;
                                self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                                if (guard_plan.release_status_on_success) self.out.writer().print("    !{s}\n", .{ok_reg}) catch return CodegenError.CodegenError;
                                const borrow_result_plan = lowering_rules.planRefCellBorrowResult(.sa_text, borrow_plan.value_kind);
                                const borrow_reg = if (borrow_result_plan.action.usesBorrowSlot())
                                    borrow_slot_reg
                                else if (borrow_result_plan.action.loadsPointerPayload()) blk: {
                                    const payload_reg = try self.newTmp();
                                    self.out.writer().print("    {s} = load {s}+0 as ptr\n", .{ payload_reg, borrow_slot_reg }) catch return CodegenError.CodegenError;
                                    if (borrow_result_plan.release_borrow_slot_after_payload) try self.emitRelease(borrow_slot_reg);
                                    break :blk payload_reg;
                                } else if (borrow_result_plan.action.takesPointerPayload())
                                    return CodegenError.CodegenError
                                else
                                    return CodegenError.CodegenError;
                                const handle_plan = lowering_rules.planRefCellBorrowHandleRegistration(borrow_plan);
                                self.refcell_borrow_handles.put(borrow_reg, .{
                                    .cell_reg = recv_reg,
                                    .kind = borrow_plan.kind,
                                    .cell_release_temp = if (handle_plan.track_receiver_owner_temp) recv_reg else null,
                                }) catch return CodegenError.OutOfMemory;
                                return borrow_reg;
                            }
                        }
                        if (mutexInnerType(ty) != null) {
                            if (std.mem.eql(u8, call.func_name, "lock")) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const guard_reg = try self.newTmp();
                                const result_reg = try self.newTmp();
                                self.out.writer().print("    EXPAND MUTEX_LOCK {s}\n", .{recv_reg}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = ptr_add {s}, Mutex_data\n", .{ guard_reg, recv_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    EXPAND RESULT_NEW_OK {s}, {s}\n", .{ result_reg, guard_reg }) catch return CodegenError.CodegenError;
                                self.mutex_lock_results.put(result_reg, .{ .mutex_reg = recv_reg }) catch return CodegenError.OutOfMemory;
                                try self.emitRelease(guard_reg);
                                if (call.args[0].* == .identifier) {
                                    self.consumed_bindings.put(call.args[0].identifier, {}) catch return CodegenError.OutOfMemory;
                                }
                                return result_reg;
                            }
                        }
                        if (rwLockInnerType(ty) != null) {
                            if (std.mem.eql(u8, call.func_name, "read") or std.mem.eql(u8, call.func_name, "write")) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const ok_reg = try self.newTmp();
                                const lock_guard_reg = try self.newTmp();
                                const guard_reg = try self.newTmp();
                                const result_reg = try self.newTmp();
                                const err_label = try self.newLabel("L_RWLOCK_RESULT_ERR");
                                const ok_label = try self.newLabel("L_RWLOCK_RESULT_OK");
                                const end_label = try self.newLabel("L_RWLOCK_RESULT_END");
                                const is_write = std.mem.eql(u8, call.func_name, "write");
                                if (is_write) {
                                    self.out.writer().print("    EXPAND RWLOCK_TRY_WRITE_NOERR {s}, {s}, {s}\n", .{ ok_reg, lock_guard_reg, recv_reg }) catch return CodegenError.CodegenError;
                                } else {
                                    self.out.writer().print("    EXPAND RWLOCK_TRY_READ_NOERR {s}, {s}, {s}\n", .{ ok_reg, lock_guard_reg, recv_reg }) catch return CodegenError.CodegenError;
                                }
                                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ ok_reg, ok_label, err_label }) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{err_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    EXPAND RESULT_NEW_ERR {s}, 1\n", .{result_reg}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{ok_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = ptr_add {s}, RwLock_data\n", .{ guard_reg, recv_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    EXPAND RESULT_NEW_OK {s}, {s}\n", .{ result_reg, guard_reg }) catch return CodegenError.CodegenError;
                                try self.emitRelease(guard_reg);
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                                self.rwlock_lock_results.put(result_reg, .{ .lock_reg = recv_reg, .is_write = is_write }) catch return CodegenError.OutOfMemory;
                                try self.emitRelease(ok_reg);
                                try self.emitRelease(lock_guard_reg);
                                return result_reg;
                            }
                        }
                        if (isFileType(ty)) {
                            if (std.mem.eql(u8, call.func_name, "as_raw_fd")) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const copied = try self.newTmp();
                                const reg = try self.newTmp();
                                self.out.writer().print("    {s} = add {s}, 0\n", .{ copied, recv_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = {s} as i32\n", .{ reg, copied }) catch return CodegenError.CodegenError;
                                return reg;
                            }
                        }
                        if (rcInnerType(ty) != null and lowering_rules.isCloneCall(call)) {
                            if (call.args.len != 1) return CodegenError.CodegenError;
                            const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                            const reg = try self.newTmp();
                            self.out.writer().print("    {s} = add {s}, 0\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    EXPAND RC_CLONE {s}\n", .{reg}) catch return CodegenError.CodegenError;
                            return reg;
                        }
                        if (arcInnerType(ty) != null and lowering_rules.isCloneCall(call)) {
                            if (call.args.len != 1) return CodegenError.CodegenError;
                            const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                            const reg = try self.newTmp();
                            self.out.writer().print("    {s} = add {s}, 0\n", .{ reg, recv_reg }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    EXPAND ARC_CLONE {s}\n", .{reg}) catch return CodegenError.CodegenError;
                            return reg;
                        }
                        if (vecDequeElementType(ty) != null and std.mem.eql(u8, call.func_name, "rotate_left")) {
                            if (call.args.len != 2) return CodegenError.CodegenError;
                            const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                            const count_reg = try self.genExpr(call.args[1], hoisted_allocs);
                            const reg = try self.genVecDequeRotateLeft(recv_reg, count_reg);
                            if (callArgNeedsRelease(call.args[1])) try self.emitRelease(count_reg);
                            return reg;
                        }
                        if (vecDequeElementType(ty) != null and lowering_rules.isPushBackCall(call)) {
                            if (call.args.len != 2) return CodegenError.CodegenError;
                            const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                            const value_reg = try self.genExpr(call.args[1], hoisted_allocs);
                            self.out.writer().print("    EXPAND VEC_DEQUE_PUSH_BACK {s}, {s}\n", .{ recv_reg, value_reg }) catch return CodegenError.CodegenError;
                            if (callArgNeedsRelease(call.args[1])) try self.emitRelease(value_reg);
                            return "return_ty_sentinel";
                        }
                        if (vecDequeElementType(ty) != null and lowering_rules.isPopFrontCall(call)) {
                            if (call.args.len != 1) return CodegenError.CodegenError;
                            const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                            const ok_reg = try self.newTmp();
                            const value_reg = try self.newTmp();
                            const option_reg = try self.newTmp();
                            const some_label = try self.newLabel("L_VEC_DEQUE_POP_FRONT_SOME");
                            const none_label = try self.newLabel("L_VEC_DEQUE_POP_FRONT_NONE");
                            const end_label = try self.newLabel("L_VEC_DEQUE_POP_FRONT_END");
                            self.out.writer().print("    EXPAND VEC_DEQUE_TRY_POP_FRONT {s}, {s}, {s}\n", .{ ok_reg, value_reg, recv_reg }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ ok_reg, some_label, none_label }) catch return CodegenError.CodegenError;
                            self.out.writer().print("{s}:\n", .{some_label}) catch return CodegenError.CodegenError;
                            self.out.writer().print("    !{s}\n", .{ok_reg}) catch return CodegenError.CodegenError;
                            self.out.writer().print("    EXPAND OPTION_NEW_SOME {s}, {s}\n", .{ option_reg, value_reg }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    !{s}\n", .{value_reg}) catch return CodegenError.CodegenError;
                            self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                            self.out.writer().print("{s}:\n", .{none_label}) catch return CodegenError.CodegenError;
                            self.out.writer().print("    !{s}\n", .{ok_reg}) catch return CodegenError.CodegenError;
                            self.out.writer().print("    !{s}\n", .{value_reg}) catch return CodegenError.CodegenError;
                            self.out.writer().print("    EXPAND OPTION_NEW_NONE {s}\n", .{option_reg}) catch return CodegenError.CodegenError;
                            self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                            self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                            if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                            return option_reg;
                        }
                        if (arrayType(ty)) |arr| {
                            if (lowering_rules.isAsPtrCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                if (call.args[0].* == .identifier and self.global_const_bindings.contains(call.args[0].identifier)) {
                                    const addr_reg = try self.newTmp();
                                    self.out.writer().print("    {s} = &{s}\n", .{ addr_reg, recv_reg }) catch return CodegenError.CodegenError;
                                    return addr_reg;
                                }
                                return recv_reg;
                            }
                            if (std.mem.eql(u8, call.func_name, "fill")) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const value_reg = try self.genExpr(call.args[1], hoisted_allocs);
                                if (arr.elem.* == .primitive and arr.elem.primitive == .u8) {
                                    self.out.writer().print("    EXPAND SLA_ARRAY_FILL_U8 {s}, {s}, {}\n", .{ recv_reg, value_reg, arr.len }) catch return CodegenError.CodegenError;
                                } else {
                                    const elem_size = typeSize(arr.elem);
                                    const elem_ty_str = typeString(arr.elem);
                                    for (0..arr.len) |i| {
                                        self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ recv_reg, elem_size * i, value_reg, elem_ty_str }) catch return CodegenError.CodegenError;
                                    }
                                }
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(value_reg);
                                return "return_ty_sentinel";
                            }
                        }
                        if (isStringLikeType(ty)) {
                            if (lowering_rules.isAsPtrCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const ptr_reg = try self.newTmp();
                                if (isFormatStringType(ty)) {
                                    self.out.writer().print("    EXPAND STRING_BUF_AS_PTR {s}, {s}\n", .{ ptr_reg, recv_reg }) catch return CodegenError.CodegenError;
                                } else {
                                    self.out.writer().print("    EXPAND STR_AS_PTR {s}, {s}\n", .{ ptr_reg, recv_reg }) catch return CodegenError.CodegenError;
                                }
                                if (callArgNeedsRelease(call.args[0]) and !isNonOwningPointerCarrierCastArg(call.args[0])) try self.emitRelease(recv_reg);
                                return ptr_reg;
                            }
                            if (std.mem.eql(u8, call.func_name, "as_bytes") or std.mem.eql(u8, call.func_name, "bytes")) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const slice_reg = try self.newTmp();
                                if (isFormatStringType(ty)) {
                                    self.out.writer().print("    EXPAND STRING_BUF_AS_BYTES {s}, {s}\n", .{ slice_reg, recv_reg }) catch return CodegenError.CodegenError;
                                } else {
                                    self.out.writer().print("    EXPAND STR_AS_BYTES {s}, {s}\n", .{ slice_reg, recv_reg }) catch return CodegenError.CodegenError;
                                }
                                return slice_reg;
                            }
                            if (std.mem.eql(u8, call.func_name, "try_exists")) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const status_reg = try self.newTmp();
                                const flag_reg = try self.newTmp();
                                const result_reg = try self.newTmp();
                                self.out.writer().print("    EXPAND PATH_TRY_EXISTS {s}, {s}, {s}\n", .{ status_reg, flag_reg, recv_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = eq {s}, 1\n", .{ result_reg, flag_reg }) catch return CodegenError.CodegenError;
                                try self.emitRelease(status_reg);
                                try self.emitRelease(flag_reg);
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return result_reg;
                            }
                            if (std.mem.eql(u8, call.func_name, "is_file")) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const flag_reg = try self.newTmp();
                                const result_reg = try self.newTmp();
                                self.out.writer().print("    EXPAND PATH_IS_FILE {s}, {s}\n", .{ flag_reg, recv_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = eq {s}, 1\n", .{ result_reg, flag_reg }) catch return CodegenError.CodegenError;
                                try self.emitRelease(flag_reg);
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return result_reg;
                            }
                            if (std.mem.eql(u8, call.func_name, "is_dir")) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const flag_reg = try self.newTmp();
                                const result_reg = try self.newTmp();
                                self.out.writer().print("    EXPAND PATH_IS_DIR {s}, {s}\n", .{ flag_reg, recv_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = eq {s}, 1\n", .{ result_reg, flag_reg }) catch return CodegenError.CodegenError;
                                try self.emitRelease(flag_reg);
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return result_reg;
                            }
                            if (std.mem.eql(u8, call.func_name, "is_symlink")) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const flag_reg = try self.newTmp();
                                const result_reg = try self.newTmp();
                                self.out.writer().print("    EXPAND PATH_IS_SYMLINK {s}, {s}\n", .{ flag_reg, recv_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = eq {s}, 1\n", .{ result_reg, flag_reg }) catch return CodegenError.CodegenError;
                                try self.emitRelease(flag_reg);
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                return result_reg;
                            }
                            if (lowering_rules.isMetadataCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const path_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
                                if (!isStringLikeType(path_ty)) return CodegenError.CodegenError;
                                const path_regs = try self.genStringLikePathRegs(call.args[0], path_ty, hoisted_allocs);
                                const status_reg = try self.newTmp();
                                const meta_reg = try self.newTmp();
                                const result_reg = try self.newTmp();
                                const ok_reg = try self.newTmp();
                                const ok_label = try self.newLabel("L_PATH_METADATA_OK");
                                const err_label = try self.newLabel("L_PATH_METADATA_ERR");
                                const end_label = try self.newLabel("L_PATH_METADATA_END");
                                self.out.writer().print("    EXPAND FS_METADATA {s}, {s}, {s}, {s}\n", .{ status_reg, meta_reg, path_regs.ptr_reg, path_regs.len_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    {s} = eq {s}, SA_FS_OK\n", .{ ok_reg, status_reg }) catch return CodegenError.CodegenError;
                                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ ok_reg, ok_label, err_label }) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{ok_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    EXPAND RESULT_NEW_OK {s}, {s}\n", .{ result_reg, meta_reg }) catch return CodegenError.CodegenError;
                                try self.emitRelease(status_reg);
                                try self.emitRelease(meta_reg);
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{err_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("    EXPAND RESULT_NEW_ERR {s}, {s}\n", .{ result_reg, status_reg }) catch return CodegenError.CodegenError;
                                try self.emitRelease(status_reg);
                                try self.emitRelease(meta_reg);
                                self.out.writer().print("    jmp {s}\n\n", .{end_label}) catch return CodegenError.CodegenError;
                                self.out.writer().print("{s}:\n", .{end_label}) catch return CodegenError.CodegenError;
                                try self.emitRelease(ok_reg);
                                try self.releaseStringLikePathRegs(path_regs);
                                self.metadata_open_results.put(result_reg, .{}) catch return CodegenError.OutOfMemory;
                                return result_reg;
                            }
                        }
                        if (sliceElementType(ty) != null) {
                            if (lowering_rules.isAsPtrCall(call)) {
                                if (call.args.len != 1) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const ptr_reg = try self.newTmp();
                                self.out.writer().print("    {s} = load {s}+Slice_ptr as ptr\n", .{ ptr_reg, recv_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0]) and !isNonOwningPointerCarrierCastArg(call.args[0])) try self.emitRelease(recv_reg);
                                return ptr_reg;
                            }
                        }
                        if (ty.* == .pointer and std.mem.eql(u8, call.func_name, "add")) {
                            if (call.args.len != 2) return CodegenError.CodegenError;
                            const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                            const index_reg = try self.genExpr(call.args[1], hoisted_allocs);
                            const offset_reg = try self.newTmp();
                            const ptr_reg = try self.newTmp();
                            self.out.writer().print("    {s} = mul {s}, {}\n", .{ offset_reg, index_reg, typeSize(ty.pointer) }) catch return CodegenError.CodegenError;
                            self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ ptr_reg, recv_reg, offset_reg }) catch return CodegenError.CodegenError;
                            try self.emitRelease(offset_reg);
                            if (callArgNeedsRelease(call.args[1])) try self.emitRelease(index_reg);
                            return ptr_reg;
                        }
                        if (hashMapTypes(ty) != null) {
                            if (lowering_rules.isInsertCall(call)) {
                                if (call.args.len != 3) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const key_reg = try self.genHashMapKeyReg(call.args[1], hoisted_allocs);
                                const value_slot = try self.genHashMapValueSlot(call.args[2], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND SLA_MAP_INSERT_OPTION_U64 {s}, {s}, {s}, {s}\n", .{ reg, recv_reg, key_reg, value_slot }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(key_reg);
                                return reg;
                            }
                            if (lowering_rules.isGetCall(call)) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const key_reg = try self.genHashMapKeyReg(call.args[1], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND SLA_MAP_TRY_GET_OPTION {s}, {s}, {s}\n", .{ reg, recv_reg, key_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(key_reg);
                                return reg;
                            }
                        }
                        if (btreeMapTypes(ty) != null) {
                            if (lowering_rules.isInsertCall(call)) {
                                if (call.args.len != 3) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const key_reg = try self.genHashMapKeyReg(call.args[1], hoisted_allocs);
                                const value_reg = try self.genExpr(call.args[2], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND SLA_BTREE_MAP_INSERT_OPTION_U64 {s}, {s}, {s}, {s}\n", .{ reg, recv_reg, key_reg, value_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(key_reg);
                                if (callArgNeedsRelease(call.args[2])) try self.emitRelease(value_reg);
                                return reg;
                            }
                            if (lowering_rules.isGetCall(call)) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const key_reg = try self.genHashMapKeyReg(call.args[1], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND SLA_BTREE_MAP_TRY_GET_OPTION {s}, {s}, {s}\n", .{ reg, recv_reg, key_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(key_reg);
                                return reg;
                            }
                        }
                        if (hashSetTypes(ty) != null) {
                            if (lowering_rules.isInsertCall(call)) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const key_reg = try self.genHashMapKeyReg(call.args[1], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND SET_INSERT {s}, {s}, {s}\n", .{ reg, recv_reg, key_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(key_reg);
                                return reg;
                            }
                            if (lowering_rules.isContainsCall(call)) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const key_reg = try self.genHashMapKeyReg(call.args[1], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND SET_CONTAINS {s}, {s}, {s}\n", .{ reg, recv_reg, key_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(key_reg);
                                return reg;
                            }
                        }
                        if (btreeSetTypes(ty) != null) {
                            if (lowering_rules.isInsertCall(call)) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const key_reg = try self.genHashMapKeyReg(call.args[1], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND BTREE_SET_INSERT {s}, {s}, {s}\n", .{ reg, recv_reg, key_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(key_reg);
                                return reg;
                            }
                            if (lowering_rules.isContainsCall(call)) {
                                if (call.args.len != 2) return CodegenError.CodegenError;
                                const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                                const key_reg = try self.genHashMapKeyReg(call.args[1], hoisted_allocs);
                                const reg = try self.newTmp();
                                self.out.writer().print("    EXPAND BTREE_SET_CONTAINS {s}, {s}, {s}\n", .{ reg, recv_reg, key_reg }) catch return CodegenError.CodegenError;
                                if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                                if (callArgNeedsRelease(call.args[1])) try self.emitRelease(key_reg);
                                return reg;
                            }
                        }
                    }
                }

                if (self.tc.dyn_call_traits.get(expr)) |trait_name| {
                    const slot = self.dynMethodSlot(trait_name, call.func_name) orelse return CodegenError.CodegenError;
                    if (call.args.len < 1) return CodegenError.CodegenError;
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse return CodegenError.CodegenError;
                    const recv_reg = try self.genExpr(call.args[0], hoisted_allocs);
                    var dyn_reg = recv_reg;
                    if (lowering_rules.planDynDispatchReceiver(recv_ty)) |receiver_plan| {
                        if (receiver_plan.needsRcGetDyn()) {
                            dyn_reg = try self.newTmp();
                            self.out.writer().print("    EXPAND RC_GET {s}, {s}\n", .{ dyn_reg, recv_reg }) catch return CodegenError.CodegenError;
                        }
                    }

                    var arg_regs = std.ArrayList([]const u8).init(self.allocator);
                    defer arg_regs.deinit();
                    for (call.args[1..]) |arg| {
                        arg_regs.append(try self.genCallArg(arg, hoisted_allocs)) catch return CodegenError.OutOfMemory;
                    }

                    const data_reg = try self.newTmp();
                    const vtable_reg = try self.newTmp();
                    const fn_reg = try self.newTmp();
                    self.out.writer().print("    {s} = load {s}+Dyn_data as ptr\n", .{ data_reg, dyn_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    {s} = load {s}+Dyn_vtable as ptr\n", .{ vtable_reg, dyn_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    {s} = load {s}+{} as ptr\n", .{ fn_reg, vtable_reg, slot }) catch return CodegenError.CodegenError;

                    const ret_ty = self.tc.expr_types.get(expr) orelse return CodegenError.CodegenError;
                    const returns_void = isVoidType(ret_ty);
                    const out_reg = if (returns_void) "return_ty_sentinel" else try self.newTmp();
                    if (returns_void) {
                        self.out.writer().print("    call_indirect {s}(&{s}", .{ fn_reg, data_reg }) catch return CodegenError.CodegenError;
                    } else {
                        self.out.writer().print("    {s} = call_indirect {s}(&{s}", .{ out_reg, fn_reg, data_reg }) catch return CodegenError.CodegenError;
                    }
                    for (arg_regs.items) |arg_reg| {
                        self.out.writer().print(", {s}", .{arg_reg}) catch return CodegenError.CodegenError;
                    }
                    self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;

                    try self.emitRelease(fn_reg);
                    try self.emitRelease(vtable_reg);
                    try self.emitRelease(data_reg);
                    for (call.args[1..], arg_regs.items) |arg, arg_reg| {
                        if (callArgNeedsRelease(arg)) try self.emitRelease(arg_reg);
                    }
                    if (!std.mem.eql(u8, dyn_reg, recv_reg)) try self.emitRelease(dyn_reg);
                    if (callArgNeedsRelease(call.args[0])) try self.emitRelease(recv_reg);
                    return out_reg;
                }

                if (self.tc.structs.get(call.func_name)) |decl| {
                    if (decl.is_opaque) return CodegenError.CodegenError;
                    if (decl.fields.len != call.args.len) return CodegenError.CodegenError;
                    const reg = try self.newTmp();
                    self.out.writer().print("    {s} = alloc {}\n", .{ reg, structSize(decl) }) catch return CodegenError.CodegenError;
                    var arg_release_regs = std.ArrayList(?[]const u8).init(self.allocator);
                    defer arg_release_regs.deinit();
                    var arg_consume_regs = std.ArrayList([]const u8).init(self.allocator);
                    defer arg_consume_regs.deinit();
                    for (decl.fields, call.args) |field, arg| {
                        const layout = fieldLayout(decl, field.name) orelse return CodegenError.CodegenError;
                        if (arg.* == .identifier and self.typeIsCopyStruct(field.ty)) {
                            const source_reg = try self.genExpr(arg, hoisted_allocs);
                            const copied = try self.newTmp();
                            try self.genCopyValueInto(copied, source_reg, field.ty);
                            self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ reg, layout.offset, copied, layout.ty_str }) catch return CodegenError.CodegenError;
                        } else {
                            const arg_reg = try self.genExpr(arg, hoisted_allocs);
                            self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ reg, layout.offset, arg_reg, layout.ty_str }) catch return CodegenError.CodegenError;
                            try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, .{
                                .reg = arg_reg,
                                .release_after_call = callArgNeedsRelease(arg),
                            });
                        }
                    }
                    try self.emitLoweredCallArgCleanups(arg_release_regs.items, arg_consume_regs.items, null);
                    return reg;
                }

                // Check if FFI function call
                if (call.args.len > 0) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty) |rt| {
                        const curr = lowering_rules.peelBorrowPointerType(rt);
                        if (curr.* == .user_defined) {
                            var method_buf: [256]u8 = undefined;
                            const method_key = std.fmt.bufPrint(&method_buf, "{s}_{s}", .{ curr.user_defined.name, call.func_name }) catch null;
                            if (method_key) |mk| {
                                if (self.tc.funcs.contains(mk)) {
                                    var arg_regs = std.ArrayList([]const u8).init(self.allocator);
                                    defer arg_regs.deinit();
                                    var arg_release_regs = std.ArrayList(?[]const u8).init(self.allocator);
                                    defer arg_release_regs.deinit();
                                    var arg_consume_regs = std.ArrayList([]const u8).init(self.allocator);
                                    defer arg_consume_regs.deinit();
                                    const method_func = self.tc.funcs.get(mk);
                                    for (call.args, 0..) |arg, i| {
                                        const sibling_mark = try self.pushCallSiblingArgExprs(call.args, i);
                                        defer self.popExprLaterNodesTo(sibling_mark);
                                        if (method_func) |func| {
                                            if (i < func.params.len and arg.* == .literal and arg.literal == .string_val and isFormatStringType(func.params[i].ty)) {
                                                const arg_reg = try self.genOwnedStringLiteral(arg.literal.string_val, hoisted_allocs);
                                                arg_regs.append(arg_reg) catch return CodegenError.OutOfMemory;
                                                try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, .{
                                                    .reg = arg_reg,
                                                    .release_after_call = true,
                                                });
                                                continue;
                                            }
                                            if (i < func.params.len) {
                                                const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{
                                                    .param = func.params[i],
                                                    .arg_index = i,
                                                    .receiver_style_auto_borrow = i == 0,
                                                });
                                                arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
                                                try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
                                                continue;
                                            }
                                        }
                                        const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{});
                                        arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
                                        try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
                                    }
                                    const reg = try self.newTmp();
                                    const lowered_method = try self.loweredFuncSymbol(mk);
                                    defer self.allocator.free(lowered_method);
                                    self.out.writer().print("    {s} = call @{s}(", .{ reg, lowered_method }) catch return CodegenError.CodegenError;
                                    for (arg_regs.items, 0..) |ar, i| {
                                        if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
                                        self.out.writer().print("{s}", .{ar}) catch return CodegenError.CodegenError;
                                    }
                                    self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
                                    try self.emitLoweredCallArgCleanups(arg_release_regs.items, arg_consume_regs.items, call.func_name);
                                    return reg;
                                }
                            }
                        }
                    }
                }

                if (self.tc.extern_funcs.get(call.func_name)) |ext| {
                    if (ext.return_fallible) return try self.genFallibleExternPayloadCall(&call, ext, hoisted_allocs);
                    return try self.genExternPayloadCall(&call, ext, hoisted_allocs);
                }

                if (self.tc.extern_funcs.contains(call.func_name) or self.tc.funcs.contains(call.func_name)) {
                    var arg_regs = std.ArrayList([]const u8).init(self.allocator);
                    defer arg_regs.deinit();
                    var arg_release_regs = std.ArrayList(?[]const u8).init(self.allocator);
                    defer arg_release_regs.deinit();
                    var arg_consume_regs = std.ArrayList([]const u8).init(self.allocator);
                    defer arg_consume_regs.deinit();
                    const maybe_func = self.tc.funcs.get(call.func_name);
                    for (call.args, 0..) |arg, i| {
                        const sibling_mark = try self.pushCallSiblingArgExprs(call.args, i);
                        defer self.popExprLaterNodesTo(sibling_mark);
                        if (maybe_func) |func| {
                            if (i < func.params.len and arg.* == .literal and arg.literal == .string_val and isFormatStringType(func.params[i].ty)) {
                                const arg_reg = try self.genOwnedStringLiteral(arg.literal.string_val, hoisted_allocs);
                                arg_regs.append(arg_reg) catch return CodegenError.OutOfMemory;
                                try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, .{
                                    .reg = arg_reg,
                                    .release_after_call = true,
                                });
                                continue;
                            }
                            if (i < func.params.len) {
                                const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{
                                    .param = func.params[i],
                                    .arg_index = i,
                                    .receiver_style_auto_borrow = i == 0,
                                });
                                arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
                                try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
                                continue;
                            }
                        }
                        const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{});
                        arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
                        try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
                    }
                    const reg = try self.newTmp();
                    const lowered_call = try self.loweredFuncSymbol(call.func_name);
                    defer self.allocator.free(lowered_call);
                    self.out.writer().print("    {s} = call @{s}(", .{ reg, lowered_call }) catch return CodegenError.CodegenError;
                    for (arg_regs.items, 0..) |ar, i| {
                        if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
                        self.out.writer().print("{s}", .{ar}) catch return CodegenError.CodegenError;
                    }
                    self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
                    try self.emitLoweredCallArgCleanups(arg_release_regs.items, arg_consume_regs.items, call.func_name);
                    if (maybe_func) |func| {
                        if (lowering_rules.planAsyncJoin2AwaitContinuation(func) != null) {
                            try self.future_state_vtables.put(reg, try self.asyncJoin2AwaitVTableName(call.func_name));
                            try self.recordFutureReadiness(reg, .unknown);
                        } else if (lowering_rules.planAsyncTwoAwaitContinuation(func) != null) {
                            try self.future_state_vtables.put(reg, try self.asyncTwoAwaitVTableName(call.func_name));
                            try self.recordFutureReadiness(reg, .unknown);
                        } else if (lowering_rules.planAsyncSingleAwaitContinuation(func) != null) {
                            try self.future_state_vtables.put(reg, try self.asyncSingleAwaitVTableName(call.func_name));
                            try self.recordFutureReadiness(reg, .unknown);
                        } else if (self.planAsyncTwoAwaitContinuationDynamic(func) != null) {
                            try self.future_state_vtables.put(reg, try self.asyncTwoAwaitVTableName(call.func_name));
                            try self.recordFutureReadiness(reg, .unknown);
                        } else if (self.planAsyncSingleAwaitContinuationDynamic(func) != null) {
                            try self.future_state_vtables.put(reg, try self.asyncSingleAwaitVTableName(call.func_name));
                            try self.recordFutureReadiness(reg, .unknown);
                        }
                    }
                    return reg;
                }

                if (call.associated_target) |target_name| {
                    if (std.mem.eql(u8, target_name, "str") and self.tc.funcs.contains(call.func_name)) {
                        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
                        defer arg_regs.deinit();
                        var arg_release_regs = std.ArrayList(?[]const u8).init(self.allocator);
                        defer arg_release_regs.deinit();
                        var arg_consume_regs = std.ArrayList([]const u8).init(self.allocator);
                        defer arg_consume_regs.deinit();
                        const maybe_func = self.tc.funcs.get(call.func_name);
                        for (call.args, 0..) |arg, i| {
                            const sibling_mark = try self.pushCallSiblingArgExprs(call.args, i);
                            defer self.popExprLaterNodesTo(sibling_mark);
                            if (maybe_func) |func| {
                                if (i < func.params.len and arg.* == .literal and arg.literal == .string_val and isFormatStringType(func.params[i].ty)) {
                                    const arg_reg = try self.genOwnedStringLiteral(arg.literal.string_val, hoisted_allocs);
                                    arg_regs.append(arg_reg) catch return CodegenError.OutOfMemory;
                                    try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, .{
                                        .reg = arg_reg,
                                        .release_after_call = true,
                                    });
                                    continue;
                                }
                                if (i < func.params.len) {
                                    const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{
                                        .param = func.params[i],
                                        .arg_index = i,
                                        .receiver_style_auto_borrow = i == 0,
                                    });
                                    arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
                                    try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
                                    continue;
                                }
                            }
                            const lowered_arg = try self.genPlannedCallArg(arg, hoisted_allocs, .{});
                            arg_regs.append(lowered_arg.reg) catch return CodegenError.OutOfMemory;
                            try self.appendLoweredCallArgCleanups(&arg_release_regs, &arg_consume_regs, lowered_arg);
                        }
                        const reg = try self.newTmp();
                        const lowered_call = try self.loweredFuncSymbol(call.func_name);
                        defer self.allocator.free(lowered_call);
                        self.out.writer().print("    {s} = call @{s}(", .{ reg, lowered_call }) catch return CodegenError.CodegenError;
                        for (arg_regs.items, 0..) |ar, i| {
                            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
                            self.out.writer().print("{s}", .{ar}) catch return CodegenError.CodegenError;
                        }
                        self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
                        try self.emitLoweredCallArgCleanups(arg_release_regs.items, arg_consume_regs.items, null);
                        return reg;
                    }
                }

                // If it is standard stack_alloc, it might be hoisted
                if (lowering_rules.isStackAllocCall(call)) {
                    const reg = try self.newTmp();
                    self.out.writer().print("    {s} = stack_alloc {}\n", .{ reg, self.stackAllocSize(&call) }) catch return CodegenError.CodegenError;
                    return reg;
                }

                if (std.mem.eql(u8, call.func_name, "std__panic__catch_unwind") or
                    (call.associated_target != null and std.mem.eql(u8, call.associated_target.?, "panic") and std.mem.eql(u8, call.func_name, "catch_unwind")))
                {
                    if (call.args.len != 1 or call.args[0].* != .closure_literal or call.args[0].closure_literal.params.len != 0) {
                        return CodegenError.CodegenError;
                    }
                    const closure = &call.args[0].closure_literal;
                    const result_reg = try self.newTmp();
                    const body = closure.body;
                    const panics = switch (body.*) {
                        .call_expr => |body_call| lowering_rules.isPanicBuiltinName(body_call.func_name),
                        else => false,
                    };
                    if (panics) {
                        const err_reg = try self.newTmp();
                        self.out.writer().print("    {s} = 1\n", .{err_reg}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    EXPAND RESULT_NEW_ERR {s}, {s}\n", .{ result_reg, err_reg }) catch return CodegenError.CodegenError;
                        try self.emitRelease(err_reg);
                    } else {
                        const ok_reg = try self.genExpr(body, hoisted_allocs);
                        self.out.writer().print("    EXPAND RESULT_NEW_OK {s}, {s}\n", .{ result_reg, ok_reg }) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(body)) try self.emitRelease(ok_reg);
                    }
                    return result_reg;
                }

                // panic(code) lowers to SA's panic intrinsic call syntax.
                if (std.mem.eql(u8, call.func_name, "panic")) {
                    const reg = try self.newTmp();
                    if (call.args.len > 0) {
                        const arg = call.args[0];
                        if (arg.* == .literal) {
                            switch (arg.literal) {
                                .int_val => |v| self.out.writer().print("    panic({})\n", .{v}) catch return CodegenError.CodegenError,
                                .bool_val => |v| self.out.writer().print("    panic({})\n", .{if (v) @as(u8, 1) else @as(u8, 0)}) catch return CodegenError.CodegenError,
                                .string_val => |msg| {
                                    const label = try self.newStringConst();
                                    self.out.writer().print("    @const {s} = utf8:\"{s}\"\n", .{ label, msg }) catch return CodegenError.CodegenError;
                                    const len_reg = try self.newTmp();
                                    try self.emitIntConst(len_reg, @as(i64, @intCast(escapedStringByteLen(msg))));
                                    self.out.writer().print("    EXPAND PANIC_MSG 103, *{s}, {s}\n", .{ label, len_reg }) catch return CodegenError.CodegenError;
                                    try self.emitRelease(len_reg);
                                },
                                else => {
                                    const code_reg = try self.genExpr(arg, hoisted_allocs);
                                    self.out.writer().print("    panic({s})\n", .{code_reg}) catch return CodegenError.CodegenError;
                                },
                            }
                        } else {
                            const code_reg = try self.genExpr(arg, hoisted_allocs);
                            self.out.writer().print("    panic({s})\n", .{code_reg}) catch return CodegenError.CodegenError;
                        }
                    } else {
                        self.out.writer().print("    panic(1)\n", .{}) catch return CodegenError.CodegenError;
                    }
                    return reg;
                }

                if (!(call.args.len > 0 and lowering_rules.isMetadataCall(call))) {
                    if (try self.genOnceGetOrInitCall(&call, hoisted_allocs)) |reg| return reg;
                    if (lowering_rules.planImportedMacroCall(self.tc, call)) |plan| {
                        return try self.genImportedMacroCall(&call, plan, hoisted_allocs);
                    }
                }

                if (self.tc.macros.get(call.func_name)) |macro_decl| {
                    try self.genUserMacroCallInline(macro_decl, &call, hoisted_allocs);
                    const sentinel = try self.newTmp();
                    try self.emitIntConst(sentinel, 0);
                    return sentinel;
                }

                // Assume macro expansion call in Sla
                const reg = try self.newTmp();
                var arg_regs = std.ArrayList([]const u8).init(self.allocator);
                defer arg_regs.deinit();
                for (call.args) |arg| {
                    const arg_reg = try self.genExpr(arg, hoisted_allocs);
                    try arg_regs.append(arg_reg);
                }
                self.out.writer().print("    EXPAND {s}", .{call.func_name}) catch return CodegenError.CodegenError;
                for (arg_regs.items) |arg_reg| {
                    self.out.writer().print(" {s}", .{arg_reg}) catch return CodegenError.CodegenError;
                }
                self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;
                return reg;
            },
            .if_expr => |ife| {
                if (ife.let_chain) |chain| {
                    const expr_ty = self.tc.expr_types.get(expr) orelse return CodegenError.CodegenError;
                    const value_if = !isVoidType(expr_ty);
                    const result_slot = if (value_if) try self.newTmp() else null;
                    if (result_slot) |slot| {
                        self.out.writer().print("    {s} = alloc {}\n", .{ slot, typeSize(expr_ty) }) catch return CodegenError.CodegenError;
                        try self.prepareResultSlotRefCellCompanion(slot, expr_ty);
                    }

                    const then_label = try self.newLabel("L_IF_LET_THEN");
                    const else_label = try self.newLabel("L_IF_LET_ELSE");
                    const merge_label = try self.newLabel("L_IF_LET_MERGE");
                    const then_terminates = blockTerminates(ife.then_block);
                    const else_terminates = if (ife.else_block) |eb| blockTerminates(eb) else false;
                    const needs_merge = !then_terminates or !else_terminates;

                    var acquired = std.ArrayList([]const u8).init(self.allocator);
                    defer acquired.deinit();

                    for (chain, 0..) |cond, i| {
                        const success_label = if (i + 1 == chain.len) then_label else try self.newLabel("L_IF_LET_NEXT");
                        const fail_label = try self.newLabel("L_IF_LET_FAIL");
                        const value_reg = try self.genExpr(cond.value, hoisted_allocs);
                        const branch_flag = try self.newTmp();
                        const enum_decl = try self.enumDeclForPatternValue(cond.value, cond.pattern);
                        const success_on_true = enum_decl != null or std.mem.eql(u8, cond.pattern.variant_name, "Some") or std.mem.eql(u8, cond.pattern.variant_name, "Ok");
                        if (enum_decl) |decl| {
                            try self.genEnumPatternCheck(decl, cond.pattern, value_reg, branch_flag);
                        } else if (patternUsesResultMacros(cond.pattern)) {
                            self.out.writer().print("    EXPAND RESULT_IS_OK {s}, {s}\n", .{ branch_flag, value_reg }) catch return CodegenError.CodegenError;
                        } else {
                            self.out.writer().print("    EXPAND OPTION_IS_SOME {s}, {s}\n", .{ branch_flag, value_reg }) catch return CodegenError.CodegenError;
                        }
                        if (success_on_true) {
                            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ branch_flag, success_label, fail_label }) catch return CodegenError.CodegenError;
                        } else {
                            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ branch_flag, fail_label, success_label }) catch return CodegenError.CodegenError;
                        }

                        var fail_path_consumed = self.consumed_bindings.clone() catch return CodegenError.OutOfMemory;
                        defer fail_path_consumed.deinit();
                        var fail_path_borrow_sources = self.borrow_source_temps.clone() catch return CodegenError.OutOfMemory;
                        defer fail_path_borrow_sources.deinit();
                        var fail_path_refcell_handles = self.refcell_borrow_handles.clone() catch return CodegenError.OutOfMemory;
                        defer fail_path_refcell_handles.deinit();

                        self.out.writer().print("{s}:\n", .{fail_label}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    !{s}\n", .{branch_flag}) catch return CodegenError.CodegenError;
                        if (callArgNeedsRelease(cond.value)) try self.emitRelease(value_reg);
                        for (acquired.items) |binding| {
                            try self.emitRelease(binding);
                        }
                        self.out.writer().print("    jmp {s}\n\n", .{else_label}) catch return CodegenError.CodegenError;
                        try self.restoreConsumedBindings(&fail_path_consumed);
                        try self.restoreBorrowSourceTemps(&fail_path_borrow_sources);
                        try self.restoreRefCellBorrowHandles(&fail_path_refcell_handles);

                        self.out.writer().print("{s}:\n", .{success_label}) catch return CodegenError.CodegenError;
                        self.out.writer().print("    !{s}\n", .{branch_flag}) catch return CodegenError.CodegenError;
                        if (enum_decl) |decl| {
                            try self.genEnumPatternBindings(decl, cond.pattern, value_reg);
                            for (cond.pattern.bindings) |binding| {
                                try acquired.append(binding);
                            }
                        } else if (std.mem.eql(u8, cond.pattern.variant_name, "Some") and cond.pattern.bindings.len == 1) {
                            const binding = cond.pattern.bindings[0];
                            const target = try self.pushBindingAlias(binding);
                            self.out.writer().print("    EXPAND OPTION_GET {s}, {s}\n", .{ target, value_reg }) catch return CodegenError.CodegenError;
                            try acquired.append(binding);
                        } else if (std.mem.eql(u8, cond.pattern.variant_name, "Ok") and cond.pattern.bindings.len == 1) {
                            const binding = cond.pattern.bindings[0];
                            const target = try self.pushBindingAlias(binding);
                            self.out.writer().print("    EXPAND RESULT_GET_OK {s}, {s}\n", .{ target, value_reg }) catch return CodegenError.CodegenError;
                            try acquired.append(binding);
                        } else if (std.mem.eql(u8, cond.pattern.variant_name, "Err") and cond.pattern.bindings.len == 1) {
                            const binding = cond.pattern.bindings[0];
                            const target = try self.pushBindingAlias(binding);
                            self.out.writer().print("    EXPAND RESULT_GET_ERR {s}, {s}\n", .{ target, value_reg }) catch return CodegenError.CodegenError;
                            try acquired.append(binding);
                        }
                        if (callArgNeedsRelease(cond.value)) try self.emitRelease(value_reg);
                        if (i + 1 == chain.len) break;
                    }

                    if (value_if and !then_terminates) {
                        try self.genBlockTailValueStore(ife.then_block, result_slot.?, expr_ty, hoisted_allocs);
                    } else {
                        try self.genBlock(ife.then_block, hoisted_allocs);
                    }
                    for (acquired.items) |binding| {
                        if (!blockConsumesIdentifier(ife.then_block, binding)) {
                            try self.emitRelease(binding);
                        }
                    }
                    for (acquired.items) |binding| {
                        self.popBindingAlias(binding);
                    }
                    if (ife.then_block.len > 0) {
                        if (self.tc.phi_cleanups.get(ife.then_block[ife.then_block.len - 1])) |list| {
                            for (list.items) |pv| {
                                self.out.writer().print("    !{s}\n", .{pv}) catch return CodegenError.CodegenError;
                            }
                        }
                    }
                    if (needs_merge and !then_terminates) {
                        self.out.writer().print("    jmp {s}\n", .{merge_label}) catch return CodegenError.CodegenError;
                    }
                    self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;

                    self.out.writer().print("{s}:\n", .{else_label}) catch return CodegenError.CodegenError;
                    if (ife.else_block) |eb| {
                        if (value_if and !else_terminates) {
                            try self.genBlockTailValueStore(eb, result_slot.?, expr_ty, hoisted_allocs);
                        } else {
                            try self.genBlock(eb, hoisted_allocs);
                        }
                        if (eb.len > 0) {
                            if (self.tc.phi_cleanups.get(eb[eb.len - 1])) |list| {
                                for (list.items) |pv| {
                                    self.out.writer().print("    !{s}\n", .{pv}) catch return CodegenError.CodegenError;
                                }
                            }
                        }
                    }
                    if (needs_merge and !else_terminates) {
                        self.out.writer().print("    jmp {s}\n", .{merge_label}) catch return CodegenError.CodegenError;
                    }
                    self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;

                    if (needs_merge) {
                        self.out.writer().print("{s}:\n", .{merge_label}) catch return CodegenError.CodegenError;
                    }
                    if (result_slot) |slot| {
                        const reg = try self.newTmp();
                        self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ reg, slot, typeString(expr_ty) }) catch return CodegenError.CodegenError;
                        try self.loadResultSlotTransferredValueState(reg, slot, expr_ty);
                        try self.emitRelease(slot);
                        return reg;
                    }
                    return try self.newTmp();
                }

                const cond_reg = try self.genBranchConditionReg(ife.cond, hoisted_allocs);
                const expr_ty = self.tc.expr_types.get(expr) orelse return CodegenError.CodegenError;
                const value_if = !isVoidType(expr_ty);
                const result_slot = if (value_if) try self.newTmp() else null;
                if (result_slot) |slot| {
                    self.out.writer().print("    {s} = alloc {}\n", .{ slot, typeSize(expr_ty) }) catch return CodegenError.CodegenError;
                    try self.prepareResultSlotRefCellCompanion(slot, expr_ty);
                }
                const then_label = try self.newLabel("L_THEN");
                const else_label = try self.newLabel("L_ELSE");
                const merge_label = try self.newLabel("L_MERGE");
                const then_terminates = blockTerminates(ife.then_block);
                const else_terminates = if (ife.else_block) |eb| blockTerminates(eb) else false;
                const needs_merge = !then_terminates or !else_terminates;

                var pre_branch_consumed = self.consumed_bindings.clone() catch return CodegenError.OutOfMemory;
                defer pre_branch_consumed.deinit();
                var pre_branch_borrow_sources = self.borrow_source_temps.clone() catch return CodegenError.OutOfMemory;
                defer pre_branch_borrow_sources.deinit();
                var pre_branch_refcell_handles = self.refcell_borrow_handles.clone() catch return CodegenError.OutOfMemory;
                defer pre_branch_refcell_handles.deinit();
                var pre_branch_result_refcell_handles = self.result_slot_refcell_handles.clone() catch return CodegenError.OutOfMemory;
                defer pre_branch_result_refcell_handles.deinit();
                var pre_branch_result_refcell_slots = self.result_slot_refcell_slots.clone() catch return CodegenError.OutOfMemory;
                defer pre_branch_result_refcell_slots.deinit();
                var branch_refcell_owner_slots = std.StringHashMap(BranchRefCellHandleOwnerMergeSlot).init(self.allocator);
                defer branch_refcell_owner_slots.deinit();
                if (needs_merge) try self.prepareRefCellBranchHandleOwnerMergeSlots(&pre_branch_refcell_handles, &branch_refcell_owner_slots);

                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ cond_reg, then_label, else_label }) catch return CodegenError.CodegenError;

                var pre_then_mutex_guards = self.mutex_guard_handles.clone() catch return CodegenError.OutOfMemory;
                defer pre_then_mutex_guards.deinit();
                var pre_then_mutex_results = self.mutex_lock_results.clone() catch return CodegenError.OutOfMemory;
                defer pre_then_mutex_results.deinit();
                var pre_then_rwlock_guards = self.rwlock_guard_handles.clone() catch return CodegenError.OutOfMemory;
                defer pre_then_rwlock_guards.deinit();
                var pre_then_rwlock_results = self.rwlock_lock_results.clone() catch return CodegenError.OutOfMemory;
                defer pre_then_rwlock_results.deinit();
                var pre_then_files = self.file_bindings.clone() catch return CodegenError.OutOfMemory;
                defer pre_then_files.deinit();
                var pre_then_file_results = self.file_open_results.clone() catch return CodegenError.OutOfMemory;
                defer pre_then_file_results.deinit();
                var pre_then_metadata = self.metadata_bindings.clone() catch return CodegenError.OutOfMemory;
                defer pre_then_metadata.deinit();
                var pre_then_metadata_results = self.metadata_open_results.clone() catch return CodegenError.OutOfMemory;
                defer pre_then_metadata_results.deinit();

                self.out.writer().print("{s}:\n", .{then_label}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{cond_reg}) catch return CodegenError.CodegenError;
                if (value_if and !then_terminates) {
                    try self.genBlockTailValueStore(ife.then_block, result_slot.?, expr_ty, hoisted_allocs);
                } else {
                    try self.genBlock(ife.then_block, hoisted_allocs);
                }
                // Emit then block Phi cleanups
                if (ife.then_block.len > 0) {
                    if (self.tc.phi_cleanups.get(ife.then_block[ife.then_block.len - 1])) |list| {
                        for (list.items) |pv| {
                            self.out.writer().print("    !{s}\n", .{pv}) catch return CodegenError.CodegenError;
                        }
                    }
                }
                if (needs_merge and !then_terminates) {
                    try self.storeRefCellBranchHandleOwnerMergeSlots(&branch_refcell_owner_slots, &self.refcell_borrow_handles);
                    self.out.writer().print("    jmp {s}\n", .{merge_label}) catch return CodegenError.CodegenError;
                }
                self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;

                var then_branch_borrow_sources = self.borrow_source_temps.clone() catch return CodegenError.OutOfMemory;
                defer then_branch_borrow_sources.deinit();
                var then_branch_refcell_handles = self.refcell_borrow_handles.clone() catch return CodegenError.OutOfMemory;
                defer then_branch_refcell_handles.deinit();

                if (then_terminates) {
                    try self.restoreMutexState(&pre_then_mutex_guards, &pre_then_mutex_results);
                    try self.restoreRwLockState(&pre_then_rwlock_guards, &pre_then_rwlock_results);
                    try self.restoreFileState(&pre_then_files, &pre_then_file_results);
                    try self.restoreMetadataState(&pre_then_metadata, &pre_then_metadata_results);
                }

                try self.restoreConsumedBindings(&pre_branch_consumed);
                try self.restoreBorrowSourceTemps(&pre_branch_borrow_sources);
                try self.restoreRefCellBorrowHandles(&pre_branch_refcell_handles);
                try self.restoreResultSlotRefCellState(&pre_branch_result_refcell_handles, &pre_branch_result_refcell_slots);

                var pre_else_mutex_guards = self.mutex_guard_handles.clone() catch return CodegenError.OutOfMemory;
                defer pre_else_mutex_guards.deinit();
                var pre_else_mutex_results = self.mutex_lock_results.clone() catch return CodegenError.OutOfMemory;
                defer pre_else_mutex_results.deinit();
                var pre_else_rwlock_guards = self.rwlock_guard_handles.clone() catch return CodegenError.OutOfMemory;
                defer pre_else_rwlock_guards.deinit();
                var pre_else_rwlock_results = self.rwlock_lock_results.clone() catch return CodegenError.OutOfMemory;
                defer pre_else_rwlock_results.deinit();
                var pre_else_files = self.file_bindings.clone() catch return CodegenError.OutOfMemory;
                defer pre_else_files.deinit();
                var pre_else_file_results = self.file_open_results.clone() catch return CodegenError.OutOfMemory;
                defer pre_else_file_results.deinit();
                var pre_else_metadata = self.metadata_bindings.clone() catch return CodegenError.OutOfMemory;
                defer pre_else_metadata.deinit();
                var pre_else_metadata_results = self.metadata_open_results.clone() catch return CodegenError.OutOfMemory;
                defer pre_else_metadata_results.deinit();

                self.out.writer().print("{s}:\n", .{else_label}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{cond_reg}) catch return CodegenError.CodegenError;
                if (ife.else_block) |eb| {
                    if (value_if and !else_terminates) {
                        try self.genBlockTailValueStore(eb, result_slot.?, expr_ty, hoisted_allocs);
                    } else {
                        try self.genBlock(eb, hoisted_allocs);
                    }
                    // Emit else block Phi cleanups
                    if (eb.len > 0) {
                        if (self.tc.phi_cleanups.get(eb[eb.len - 1])) |list| {
                            for (list.items) |pv| {
                                self.out.writer().print("    !{s}\n", .{pv}) catch return CodegenError.CodegenError;
                            }
                        }
                    }
                }
                if (needs_merge and !else_terminates) {
                    try self.storeRefCellBranchHandleOwnerMergeSlots(&branch_refcell_owner_slots, &self.refcell_borrow_handles);
                    self.out.writer().print("    jmp {s}\n", .{merge_label}) catch return CodegenError.CodegenError;
                }
                self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;

                var else_branch_borrow_sources = self.borrow_source_temps.clone() catch return CodegenError.OutOfMemory;
                defer else_branch_borrow_sources.deinit();
                var else_branch_refcell_handles = self.refcell_borrow_handles.clone() catch return CodegenError.OutOfMemory;
                defer else_branch_refcell_handles.deinit();

                if (else_terminates) {
                    try self.restoreMutexState(&pre_else_mutex_guards, &pre_else_mutex_results);
                    try self.restoreRwLockState(&pre_else_rwlock_guards, &pre_else_rwlock_results);
                    try self.restoreFileState(&pre_else_files, &pre_else_file_results);
                    try self.restoreMetadataState(&pre_else_metadata, &pre_else_metadata_results);
                }

                if (needs_merge) {
                    self.out.writer().print("{s}:\n", .{merge_label}) catch return CodegenError.CodegenError;
                }
                try self.setMergeRefCellBranchState(
                    then_terminates,
                    &then_branch_refcell_handles,
                    &then_branch_borrow_sources,
                    else_terminates,
                    &else_branch_refcell_handles,
                    &else_branch_borrow_sources,
                    &pre_branch_refcell_handles,
                    &pre_branch_borrow_sources,
                );
                if (needs_merge) try self.loadRefCellBranchHandleOwnerMergeSlots(
                    &branch_refcell_owner_slots,
                    then_terminates,
                    &then_branch_refcell_handles,
                    else_terminates,
                    &else_branch_refcell_handles,
                );
                if (result_slot) |slot| {
                    const reg = try self.newTmp();
                    self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ reg, slot, typeString(expr_ty) }) catch return CodegenError.CodegenError;
                    try self.loadResultSlotTransferredValueState(reg, slot, expr_ty);
                    try self.emitRelease(slot);
                    return reg;
                }
                return try self.newTmp();
            },
            .switch_expr => |swe| {
                const val_reg = try self.genExpr(swe.val, hoisted_allocs);
                const val_needs_release = exprResultNeedsRelease(swe.val);
                const merge_label = try self.newLabel("L_SWITCH_MERGE");

                var cases_labels = std.ArrayList([]const u8).init(self.allocator);
                var check_labels = std.ArrayList([]const u8).init(self.allocator);

                for (swe.cases, 0..) |_, idx| {
                    const c_lbl = std.fmt.allocPrint(self.allocator, "L_CASE_{}_{}", .{ idx, self.label_idx }) catch return CodegenError.OutOfMemory;
                    const chk_lbl = std.fmt.allocPrint(self.allocator, "L_CHECK_{}_{}", .{ idx, self.label_idx }) catch return CodegenError.OutOfMemory;
                    cases_labels.append(c_lbl) catch return CodegenError.OutOfMemory;
                    check_labels.append(chk_lbl) catch return CodegenError.OutOfMemory;
                }
                self.label_idx += 1;

                // Jump to first check
                self.out.writer().print("    jmp {s}\n\n", .{check_labels.items[0]}) catch return CodegenError.CodegenError;

                // Generate equality checking ladder
                var previous_cond: ?[]const u8 = null;
                for (swe.cases, 0..) |case, idx| {
                    self.out.writer().print("{s}:\n", .{check_labels.items[idx]}) catch return CodegenError.CodegenError;
                    if (previous_cond) |cond| {
                        self.out.writer().print("    !{s}\n", .{cond}) catch return CodegenError.CodegenError;
                        previous_cond = null;
                    }
                    const is_default = isSwitchDefaultPattern(case.pattern);
                    const is_eq = if (is_default) "" else try self.newTmp();
                    if (!is_default) {
                        const pat_reg = try self.genExpr(case.pattern, hoisted_allocs);
                        self.out.writer().print("    {s} = eq {s}, {s}\n", .{ is_eq, val_reg, pat_reg }) catch return CodegenError.CodegenError;
                        if (exprResultNeedsRelease(case.pattern)) try self.emitRelease(pat_reg);
                    }

                    const next_chk = if (idx + 1 < swe.cases.len) check_labels.items[idx + 1] else merge_label;
                    if (is_default) {
                        self.out.writer().print("    jmp {s}\n\n", .{cases_labels.items[idx]}) catch return CodegenError.CodegenError;
                    } else {
                        self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_eq, cases_labels.items[idx], next_chk }) catch return CodegenError.CodegenError;
                        previous_cond = is_eq;
                    }

                    // Generate case body
                    self.out.writer().print("{s}:\n", .{cases_labels.items[idx]}) catch return CodegenError.CodegenError;
                    if (!is_default) self.out.writer().print("    !{s}\n", .{is_eq}) catch return CodegenError.CodegenError;
                    if (val_needs_release and blockTerminates(case.body)) try self.emitRelease(val_reg);
                    try self.genBlock(case.body, hoisted_allocs);
                    if (!blockTerminates(case.body)) {
                        self.out.writer().print("    jmp {s}\n", .{merge_label}) catch return CodegenError.CodegenError;
                    }
                    self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;
                }

                self.out.writer().print("{s}:\n", .{merge_label}) catch return CodegenError.CodegenError;
                if (val_needs_release) try self.emitRelease(val_reg);
                const reg = try self.newTmp();
                return reg;
            },
            .try_expr => |trye| {
                // Postfix ? unwrapper
                const inner_ty = self.resolvedTypeForExpr(trye.expr) orelse return CodegenError.CodegenError;
                if (optionInnerType(inner_ty) != null) {
                    const inner_reg = try self.genExpr(trye.expr, hoisted_allocs);
                    const is_some = try self.newTmp();
                    self.out.writer().print("    EXPAND OPTION_IS_SOME {s}, {s}\n", .{ is_some, inner_reg }) catch return CodegenError.CodegenError;

                    const some_label = try self.newLabel("L_TRY_OPTION_SOME");
                    const none_label = try self.newLabel("L_TRY_OPTION_NONE");

                    self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_some, some_label, none_label }) catch return CodegenError.CodegenError;

                    self.out.writer().print("{s}:\n", .{none_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{is_some}) catch return CodegenError.CodegenError;
                    try self.emitBranchScopedCleanupForNode(expr);
                    self.out.writer().print("    return {s}\n\n", .{inner_reg}) catch return CodegenError.CodegenError;

                    self.out.writer().print("{s}:\n", .{some_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{is_some}) catch return CodegenError.CodegenError;
                    const some_val = try self.newTmp();
                    self.out.writer().print("    EXPAND OPTION_GET {s}, {s}\n", .{ some_val, inner_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{inner_reg}) catch return CodegenError.CodegenError;
                    return some_val;
                }
                if (resultOkType(inner_ty) != null) {
                    const inner_reg = try self.genExpr(trye.expr, hoisted_allocs);
                    const is_ok = try self.newTmp();
                    self.out.writer().print("    EXPAND RESULT_IS_OK {s}, {s}\n", .{ is_ok, inner_reg }) catch return CodegenError.CodegenError;

                    const ok_label = try self.newLabel("L_TRY_RESULT_OK");
                    const err_label = try self.newLabel("L_TRY_RESULT_ERR");

                    self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_ok, ok_label, err_label }) catch return CodegenError.CodegenError;

                    self.out.writer().print("{s}:\n", .{err_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{is_ok}) catch return CodegenError.CodegenError;
                    try self.emitBranchScopedCleanupForNode(expr);
                    self.out.writer().print("    return {s}\n\n", .{inner_reg}) catch return CodegenError.CodegenError;

                    self.out.writer().print("{s}:\n", .{ok_label}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{is_ok}) catch return CodegenError.CodegenError;
                    const ok_val = try self.newTmp();
                    self.out.writer().print("    EXPAND RESULT_GET_OK {s}, {s}\n", .{ ok_val, inner_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{inner_reg}) catch return CodegenError.CodegenError;
                    return ok_val;
                }
                const result_ty = lowering_rules.peelBorrowPointerType(inner_ty);
                if (result_ty.* != .user_defined) return CodegenError.CodegenError;
                const result_decl = self.tc.structs.get(result_ty.user_defined.name) orelse return CodegenError.CodegenError;
                const is_err_layout = fieldLayout(result_decl, "is_err") orelse return CodegenError.CodegenError;
                const value_layout = fieldLayout(result_decl, "value") orelse return CodegenError.CodegenError;

                const inner_reg = try self.genExpr(trye.expr, hoisted_allocs);
                const is_err = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ is_err, inner_reg, is_err_layout.offset, is_err_layout.ty_str }) catch return CodegenError.CodegenError;

                const ok_label = try self.newLabel("L_TRY_OK");
                const err_label = try self.newLabel("L_TRY_ERR");

                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_err, err_label, ok_label }) catch return CodegenError.CodegenError;

                // Error branch
                self.out.writer().print("{s}:\n", .{err_label}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{is_err}) catch return CodegenError.CodegenError;

                try self.emitBranchScopedCleanupForNode(expr);

                self.out.writer().print("    return {s}\n\n", .{inner_reg}) catch return CodegenError.CodegenError;

                // Ok branch
                self.out.writer().print("{s}:\n", .{ok_label}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{is_err}) catch return CodegenError.CodegenError;
                const ok_val = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ ok_val, inner_reg, value_layout.offset, value_layout.ty_str }) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{inner_reg}) catch return CodegenError.CodegenError;
                return ok_val;
            },
            else => return CodegenError.CodegenError,
        }
    }
};

test "if let chain scanner visits chained values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const first = try allocator.create(ast.Node);
    first.* = .{ .identifier = "first" };

    const payload = try allocator.create(ast.Node);
    payload.* = .{ .identifier = "payload" };

    const moved_payload = try allocator.create(ast.Node);
    moved_payload.* = .{ .move_expr = .{ .expr = payload } };

    const box_args = try allocator.alloc(*ast.Node, 1);
    box_args[0] = moved_payload;

    const boxed = try allocator.create(ast.Node);
    boxed.* = .{ .call_expr = .{
        .func_name = "new",
        .associated_target = "Box",
        .generics = &.{},
        .args = box_args,
    } };

    const chain = try allocator.alloc(ast.IfLetCond, 1);
    chain[0] = .{
        .pattern = .{
            .enum_name = "Option",
            .variant_name = "Some",
            .bindings = &.{"boxed"},
        },
        .value = boxed,
    };

    const if_node = try allocator.create(ast.Node);
    if_node.* = .{ .if_expr = .{
        .cond = first,
        .let_chain = chain,
        .then_block = &.{},
        .else_block = null,
    } };

    try std.testing.expect(Codegen.exprNeedsBoxMacros(if_node));
    try std.testing.expect(Codegen.exprConsumesIdentifier(if_node, "payload"));
}

test "basic code generation" {
    const source =
        \\fn sum(a: int, b: int) -> int {
        \\    return a + b;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser_mod = @import("parser.zig");
    var p = parser_mod.Parser.init(arena.allocator(), source);
    const prog = try p.parseProgram();

    // Type check first to populate type metadata
    var tc = type_checker.TypeChecker.init(arena.allocator());
    defer tc.deinit();
    try tc.checkProgram(prog);

    var cg = Codegen.init(arena.allocator(), &tc);
    defer cg.deinit();

    const sa_code = try cg.generate(prog);

    // Verify generated instructions
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "add") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "return") != null);
}

test "stack_alloc uses integer constant expression size" {
    const source =
        \\const ARG_SIZE: int = 16;
        \\const ARG_COUNT: int = 4;
        \\const ARG_BYTES: int = ARG_SIZE * ARG_COUNT;
        \\
        \\fn alloc_direct() -> ptr {
        \\    let argv = stack_alloc(ARG_SIZE * ARG_COUNT);
        \\    return argv;
        \\}
        \\
        \\fn alloc_alias() -> ptr {
        \\    let argv = stack_alloc(ARG_BYTES);
        \\    return argv;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser_mod = @import("parser.zig");
    var p = parser_mod.Parser.init(arena.allocator(), source);
    const prog = try p.parseProgram();

    var tc = type_checker.TypeChecker.init(arena.allocator());
    defer tc.deinit();
    try tc.checkProgram(prog);

    var cg = Codegen.init(arena.allocator(), &tc);
    defer cg.deinit();

    const sa_code = try cg.generate(prog);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, sa_code, "stack_alloc 64"));
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "stack_alloc 16") == null);
}

test "by-value raw pointer call arg does not release stack-slot load temp" {
    const source =
        \\struct Holder {
        \\    handle: ptr,
        \\}
        \\
        \\fn consume_handle(handle: ptr) -> i32 {
        \\    return 0;
        \\}
        \\
        \\fn release_holder(holder: Holder) -> i32 {
        \\    var handle: ptr;
        \\    handle = holder.handle;
        \\    return consume_handle(handle);
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser_mod = @import("parser.zig");
    var p = parser_mod.Parser.init(arena.allocator(), source);
    const prog = try p.parseProgram();

    var tc = type_checker.TypeChecker.init(arena.allocator());
    defer tc.deinit();
    try tc.checkProgram(prog);

    var cg = Codegen.init(arena.allocator(), &tc);
    defer cg.deinit();

    const sa_code = try cg.generate(prog);
    const call_start = std.mem.indexOf(u8, sa_code, "call @sla__consume_handle(") orelse return error.TestExpectedEqual;
    const arg_start = call_start + "call @sla__consume_handle(".len;
    const arg_end = std.mem.indexOfScalarPos(u8, sa_code, arg_start, ')') orelse return error.TestExpectedEqual;
    const arg_reg = sa_code[arg_start..arg_end];
    const release_line = try std.fmt.allocPrint(arena.allocator(), "\n    !{s}\n", .{arg_reg});
    try std.testing.expect(std.mem.indexOfPos(u8, sa_code, arg_end, release_line) == null);
    const consume_line = try std.fmt.allocPrint(arena.allocator(), "\n    ^{s}\n", .{arg_reg});
    try std.testing.expect(std.mem.indexOfPos(u8, sa_code, arg_end, consume_line) != null);
}

test "binary expression releases materialized cast result" {
    const source =
        \\fn cast_len_compare(values: Vec<i32>) -> bool {
        \\    let i: i64 = 0;
        \\    return i < len(values) as i64;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser_mod = @import("parser.zig");
    var p = parser_mod.Parser.init(arena.allocator(), source);
    const prog = try p.parseProgram();

    var tc = type_checker.TypeChecker.init(arena.allocator());
    defer tc.deinit();
    try tc.checkProgram(prog);

    var cg = Codegen.init(arena.allocator(), &tc);
    defer cg.deinit();

    const sa_code = try cg.generate(prog);
    const cast_pos = std.mem.indexOf(u8, sa_code, " as i64\n") orelse return error.TestExpectedEqual;
    const line_start = (std.mem.lastIndexOfScalar(u8, sa_code[0..cast_pos], '\n') orelse 0) + 1;
    const line_end = std.mem.indexOfScalarPos(u8, sa_code, cast_pos, '\n') orelse return error.TestExpectedEqual;
    const line = sa_code[line_start..line_end];
    const eq_pos = std.mem.indexOf(u8, line, " = ") orelse return error.TestExpectedEqual;
    const cast_reg = std.mem.trim(u8, line[0..eq_pos], " \t");
    const release_line = try std.fmt.allocPrint(arena.allocator(), "\n    !{s}\n", .{cast_reg});
    try std.testing.expect(std.mem.indexOfPos(u8, sa_code, line_end, release_line) != null);
}

test "set code generation" {
    const source =
        \\fn set_smoke() -> usize {
        \\    let hash = HashSet::new();
        \\    let hash_inserted = hash.insert(1);
        \\    let hash_contains = hash.contains(2);
        \\    let hash_len = hash.len();
        \\
        \\    let tree = BTreeSet::new();
        \\    let tree_inserted = tree.insert(3);
        \\    let tree_contains = tree.contains(4);
        \\    let tree_len = tree.len();
        \\
        \\    if hash_inserted == false { panic(101); };
        \\    if hash_contains == true { panic(102); };
        \\    if tree_inserted == false { panic(201); };
        \\    if tree_contains == true { panic(202); };
        \\    return hash_len + tree_len;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser_mod = @import("parser.zig");
    var p = parser_mod.Parser.init(arena.allocator(), source);
    const prog = try p.parseProgram();

    var tc = type_checker.TypeChecker.init(arena.allocator());
    defer tc.deinit();
    try tc.checkProgram(prog);

    var cg = Codegen.init(arena.allocator(), &tc);
    defer cg.deinit();

    const sa_code = try cg.generate(prog);

    try std.testing.expect(std.mem.indexOf(u8, sa_code, "@import \"sa_std/hashset.sa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "@import \"sa_std/btree_set.sa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "EXPAND SET_NEW") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "EXPAND BTREE_SET_NEW") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "EXPAND SET_INSERT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "EXPAND BTREE_SET_INSERT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "EXPAND SET_CONTAINS") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "EXPAND BTREE_SET_CONTAINS") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "EXPAND SET_LEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "EXPAND BTREE_SET_LEN") != null);
}
