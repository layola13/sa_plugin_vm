const std = @import("std");
const ast = @import("ast.zig");
const control_flow_rules = @import("control_flow_rules.zig");
const type_checker = @import("type_checker.zig");

pub fn deriveNameMatches(actual: []const u8, wanted: []const u8) bool {
    return std.ascii.eqlIgnoreCase(actual, wanted);
}

pub fn structHasDerive(decl: *const ast.StructDecl, name: []const u8) bool {
    for (decl.derives) |derive| {
        if (deriveNameMatches(derive, name)) return true;
        if (deriveNameMatches(name, "eq") and deriveNameMatches(derive, "PartialEq")) return true;
        if (deriveNameMatches(name, "ord") and deriveNameMatches(derive, "PartialOrd")) return true;
    }
    return false;
}

pub const StaticCallPlan = struct {
    target_symbol: []const u8,
    arg_count: usize,
    alias_metadata: ?type_checker.TypeChecker.FunctionAliasMetadata = null,

    pub fn argPrefix(_: StaticCallPlan, arg: *const ast.Node) ?u8 {
        return callArgPrefix(arg);
    }
};

pub const StaticCallResultPlan = struct {
    returns_void: bool,
};

pub const StaticCallLoweringPlan = struct {
    call: StaticCallPlan,
    result: StaticCallResultPlan,
};

pub const ParamCleanupCapability = enum {
    none,
    raw,
    borrow,
    by_value,
    other,
};

pub const ParamCleanupAction = enum {
    skip,
    mark_consumed,
    consume,
    release,

    pub fn skips(self: ParamCleanupAction) bool {
        return self == .skip;
    }

    pub fn marksConsumed(self: ParamCleanupAction) bool {
        return self == .mark_consumed;
    }

    pub fn consumes(self: ParamCleanupAction) bool {
        return self == .consume;
    }

    pub fn releases(self: ParamCleanupAction) bool {
        return self == .release;
    }
};

pub const ParamCleanupFacts = struct {
    is_param: bool,
    capability: ParamCleanupCapability,
    has_type: bool,
    abi_is_ptr: bool = false,
    is_copy_value: bool = false,
    is_fn_ptr: bool = false,
};

pub fn planParamCleanup(facts: ParamCleanupFacts) ParamCleanupAction {
    if (!facts.is_param) return .release;
    switch (facts.capability) {
        .none, .raw => return .skip,
        .borrow => return .release,
        .by_value, .other => {},
    }
    if (!facts.has_type) return .skip;
    if (facts.capability == .by_value and facts.abi_is_ptr) return .consume;
    // By-value copy parameters must still be released in the epilogue. The
    // SA-text emitter always emits `!param` for these (the type checker's tail
    // cleanups include by-value params), so skipping them here left the SAB
    // register `Active` at function exit and tripped the verifier's exit-leak
    // scan (MemoryLeak 1012) for any parameter-taking function declared after
    // `@main`. Releasing a scalar nobody can free is harmless and keeps both
    // emitters' instruction shapes identical.
    if (facts.capability == .by_value and facts.is_copy_value) return .release;
    if (facts.is_fn_ptr) return .consume;
    if (facts.is_copy_value) return .consume;
    if (facts.abi_is_ptr) return .consume;
    return .skip;
}

pub const AddressOfShape = enum {
    identifier,
    deref_borrow_or_pointer,
    deref_smart_pointer,
    field,
    index,
    value_temp,
};

pub const AddressOfInput = struct {
    deref_source_ty: ?*const ast.Type = null,
    index_target_ty: ?*const ast.Type = null,
};

pub const AddressOfPlan = struct {
    shape: AddressOfShape,
};

fn plainBorrowOrPointerAddressSource(ty: *const ast.Type) bool {
    switch (ty.*) {
        .borrow, .pointer => {},
        else => return false,
    }
    return smartPointerType(ty) == null;
}

pub fn peelBorrowPointerType(ty: *const ast.Type) *const ast.Type {
    var curr = ty;
    while (true) {
        switch (curr.*) {
            .borrow => |b| curr = b,
            .pointer => |p| curr = p,
            else => return curr,
        }
    }
}

/// Strip trailing local name from a possibly qualified user type name.
/// Accepts both `ns.Type` and `ns::Type` forms and returns the original name
/// when no qualifier separator is present.
pub fn userDefinedLocalName(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const colon = std.mem.lastIndexOf(u8, name, "::");
    const local_start = blk: {
        const dot_start = if (dot) |idx| idx + 1 else 0;
        const colon_start = if (colon) |idx| idx + 2 else 0;
        break :blk @max(dot_start, colon_start);
    };
    if (local_start == 0 or local_start >= name.len) return name;
    return name[local_start..];
}

pub fn ordinaryIndexAddressTargetType(ty: *const ast.Type) ?*const ast.Type {
    const target = peelBorrowPointerType(ty);
    return switch (target.*) {
        .array => target,
        .user_defined => |ud| if (std.mem.eql(u8, ud.name, "Slice") and ud.generics.len == 1) target else null,
        else => null,
    };
}

pub fn ordinaryIndexAddressable(ty: *const ast.Type) bool {
    return ordinaryIndexAddressTargetType(ty) != null;
}

pub const AsyncReturnPlan = struct {
    abi_ret_ty: *const ast.Type,
    wrap_ready_future: bool,
};

pub const AwaitPlan = struct {
    ready_state_inner: bool,
    pending_return_if_async: bool = false,
    ready_pending_state_return_if_async: bool = false,
    poll_once_if_statically_ready: bool = false,
};

pub const AsyncContinuationScalarPlan = struct {
    awaited_coeff: i64 = 1,
    captured_coeff: i64 = 0,
    captured2_coeff: i64 = 0,
    captured_field_name: ?[]const u8 = null,
    captured2_field_name: ?[]const u8 = null,
    immediate: i64 = 0,

    pub fn isIdentity(self: AsyncContinuationScalarPlan) bool {
        return self.awaited_coeff == 1 and self.captured_coeff == 0 and self.captured2_coeff == 0 and self.immediate == 0;
    }
};

pub const AsyncContinuationCaptureStorage = enum {
    scalar,
    copy_struct,
};

pub const AsyncContinuationCapturePlan = struct {
    name: []const u8,
    expr: *const ast.Node,
    offset: usize,
    size: usize = 8,
    storage: AsyncContinuationCaptureStorage = .scalar,
};

pub const AsyncContinuationBranchPlan = struct {
    condition_op: ast.BinaryOp,
    threshold: i64,
    then_scalar: AsyncContinuationScalarPlan,
    else_scalar: AsyncContinuationScalarPlan,
};

pub const AsyncSingleAwaitContinuationPlan = struct {
    binding_name: []const u8,
    post_binding_name: ?[]const u8 = null,
    captured_addend_name: ?[]const u8 = null,
    captured_addend_expr: ?*const ast.Node = null,
    capture_count: usize = 0,
    captures: [2]?AsyncContinuationCapturePlan = .{ null, null },
    await_expr: *const ast.Node,
    awaited_kind: FutureRuntimeCallKind,
    dynamic_poll: bool = false,
    addend: i64 = 0,
    scalar: AsyncContinuationScalarPlan = .{},
    branch: ?AsyncContinuationBranchPlan = null,

    pub fn resultBindingName(self: AsyncSingleAwaitContinuationPlan) ?[]const u8 {
        return self.post_binding_name;
    }

    pub fn hasCapturedAddend(self: AsyncSingleAwaitContinuationPlan) bool {
        return self.capture_count != 0 or self.captured_addend_expr != null;
    }

    pub fn asyncStateSize(self: AsyncSingleAwaitContinuationPlan) usize {
        return 16 + self.capture_count * 8;
    }
};

pub const AsyncTwoAwaitScalarPlan = struct {
    first_coeff: i64 = 1,
    second_coeff: i64 = 1,
    immediate: i64 = 0,
};

pub const AsyncTwoAwaitContinuationPlan = struct {
    first_binding_name: []const u8,
    second_binding_name: []const u8,
    first_await_expr: *const ast.Node,
    second_await_expr: *const ast.Node,
    first_awaited_kind: FutureRuntimeCallKind,
    second_awaited_kind: FutureRuntimeCallKind,
    first_dynamic_poll: bool = false,
    second_dynamic_poll: bool = false,
    second_depends_on_first: bool = false,
    scalar: AsyncTwoAwaitScalarPlan = .{},

    pub fn asyncStateSize(_: AsyncTwoAwaitContinuationPlan) usize {
        return 32;
    }
};

pub const AsyncPairResultScalarPlan = struct {
    left_coeff: i64 = 1,
    right_coeff: i64 = 1,
    immediate: i64 = 0,
};

pub const AsyncJoin2AwaitContinuationPlan = struct {
    binding_name: []const u8,
    await_expr: *const ast.Node,
    awaited_kind: FutureRuntimeCallKind,
    scalar: AsyncPairResultScalarPlan = .{},

    pub fn asyncStateSize(_: AsyncJoin2AwaitContinuationPlan) usize {
        return 16;
    }
};

pub const FutureReadiness = enum {
    unknown,
    ready,
    pending,
};

pub const FutureRuntimeCallKind = enum {
    ready,
    pending,
    defer_ready,
    sleep_ms,
    join2,
    pair_left,
    pair_right,
    select2,
    either_side,
    either_left,
    either_right,
};

pub const FutureRuntimeCallPlan = struct {
    kind: FutureRuntimeCallKind,

    pub fn isReady(self: FutureRuntimeCallPlan) bool {
        return self.kind == .ready;
    }

    pub fn isPending(self: FutureRuntimeCallPlan) bool {
        return self.kind == .pending;
    }

    pub fn isDeferReady(self: FutureRuntimeCallPlan) bool {
        return self.kind == .defer_ready;
    }

    pub fn isSleepMs(self: FutureRuntimeCallPlan) bool {
        return self.kind == .sleep_ms;
    }
    pub fn isJoin2(self: FutureRuntimeCallPlan) bool {
        return self.kind == .join2;
    }

    pub fn isSelect2(self: FutureRuntimeCallPlan) bool {
        return self.kind == .select2;
    }

    pub fn isPairAccessor(self: FutureRuntimeCallPlan) bool {
        return self.pairMacroName() != null;
    }

    pub fn isEitherAccessor(self: FutureRuntimeCallPlan) bool {
        return self.eitherValueMacroName() != null;
    }

    pub fn pairMacroName(self: FutureRuntimeCallPlan) ?[]const u8 {
        return switch (self.kind) {
            .pair_left => "FUTURE_PAIR_LEFT",
            .pair_right => "FUTURE_PAIR_RIGHT",
            else => null,
        };
    }

    pub fn eitherValueMacroName(self: FutureRuntimeCallPlan) ?[]const u8 {
        return switch (self.kind) {
            .either_side => "FUTURE_EITHER_SIDE",
            .either_left => "FUTURE_EITHER_LEFT_VALUE",
            .either_right => "FUTURE_EITHER_RIGHT_VALUE",
            else => null,
        };
    }
};

pub const TaskRuntimeCallKind = enum {
    new,
    poll,
    is_ready,
    result,
    state,
};

pub const TaskRuntimeCallPlan = struct {
    kind: TaskRuntimeCallKind,

    pub fn isNew(self: TaskRuntimeCallPlan) bool {
        return self.kind == .new;
    }

    pub fn isPoll(self: TaskRuntimeCallPlan) bool {
        return self.kind == .poll;
    }

    pub fn isIsReady(self: TaskRuntimeCallPlan) bool {
        return self.kind == .is_ready;
    }

    pub fn isResult(self: TaskRuntimeCallPlan) bool {
        return self.kind == .result;
    }

    pub fn isState(self: TaskRuntimeCallPlan) bool {
        return self.kind == .state;
    }
};

pub const ExecutorRuntimeCallKind = enum {
    new,
    poll_one,
    poll_ready_count,
    run_until_complete,
};

pub const ExecutorRuntimeCallPlan = struct {
    kind: ExecutorRuntimeCallKind,

    pub fn isNew(self: ExecutorRuntimeCallPlan) bool {
        return self.kind == .new;
    }

    pub fn isPollOne(self: ExecutorRuntimeCallPlan) bool {
        return self.kind == .poll_one;
    }

    pub fn isPollReadyCount(self: ExecutorRuntimeCallPlan) bool {
        return self.kind == .poll_ready_count;
    }

    pub fn isRunUntilComplete(self: ExecutorRuntimeCallPlan) bool {
        return self.kind == .run_until_complete;
    }
};

pub const ExecutorTaskBufferKind = enum {
    fixed_array,
    vec,
};

pub const ExecutorTaskBufferPlan = struct {
    kind: ExecutorTaskBufferKind,
    inner: *ast.Type,
    fixed_len: ?usize = null,

    pub fn isFixedArray(self: ExecutorTaskBufferPlan) bool {
        return self.kind == .fixed_array;
    }

    pub fn isVec(self: ExecutorTaskBufferPlan) bool {
        return self.kind == .vec;
    }
};

pub const PollRuntimeCallKind = enum {
    ready,
    pending,
    is_ready,
    is_pending,
    value,
};

pub const PollRuntimeCallPlan = struct {
    kind: PollRuntimeCallKind,

    pub fn isReady(self: PollRuntimeCallPlan) bool {
        return self.kind == .ready;
    }

    pub fn isPending(self: PollRuntimeCallPlan) bool {
        return self.kind == .pending;
    }

    pub fn isStatusCheck(self: PollRuntimeCallPlan) bool {
        return switch (self.kind) {
            .is_ready, .is_pending => true,
            else => false,
        };
    }

    pub fn isValue(self: PollRuntimeCallPlan) bool {
        return self.kind == .value;
    }

    pub fn pollStatusMacroName(self: PollRuntimeCallPlan) ?[]const u8 {
        return switch (self.kind) {
            .is_ready => "POLL_IS_READY",
            .is_pending => "POLL_IS_PENDING",
            else => null,
        };
    }
};

pub const ImportedMacroAddressableArgAction = enum {
    pass_value,
    pass_address_expression,
    reuse_existing_addressable,
    materialize_stack_slot,
    materialize_address_expression_stack_slot,

    pub fn passesValue(self: ImportedMacroAddressableArgAction) bool {
        return self == .pass_value;
    }

    pub fn passesAddressExpression(self: ImportedMacroAddressableArgAction) bool {
        return self == .pass_address_expression;
    }

    pub fn reusesExistingAddressable(self: ImportedMacroAddressableArgAction) bool {
        return self == .reuse_existing_addressable;
    }

    pub fn materializesStackSlot(self: ImportedMacroAddressableArgAction) bool {
        return self == .materialize_stack_slot;
    }

    pub fn materializesAddressExpressionStackSlot(self: ImportedMacroAddressableArgAction) bool {
        return self == .materialize_address_expression_stack_slot;
    }
};

pub const ImportedMacroArgLoweringAction = enum {
    pass_value,
    pass_raw_pointer_value,
    pass_address_expression,
    pass_pointer_backed_projection,
    reuse_existing_addressable,
    materialize_stack_slot,
    materialize_address_expression_stack_slot,

    pub fn passesValue(self: ImportedMacroArgLoweringAction) bool {
        return self == .pass_value;
    }

    pub fn passesRawPointerValue(self: ImportedMacroArgLoweringAction) bool {
        return self == .pass_raw_pointer_value;
    }

    pub fn passesAddressExpression(self: ImportedMacroArgLoweringAction) bool {
        return self == .pass_address_expression;
    }

    pub fn passesPointerBackedProjection(self: ImportedMacroArgLoweringAction) bool {
        return self == .pass_pointer_backed_projection;
    }

    pub fn reusesExistingAddressable(self: ImportedMacroArgLoweringAction) bool {
        return self == .reuse_existing_addressable;
    }

    pub fn materializesStackSlot(self: ImportedMacroArgLoweringAction) bool {
        return self == .materialize_stack_slot;
    }

    pub fn materializesAddressExpressionStackSlot(self: ImportedMacroArgLoweringAction) bool {
        return self == .materialize_address_expression_stack_slot;
    }
};

pub const BorrowedBindingStoragePlan = struct {
    materialize_stack_slot: bool,
};

pub const ImportedMacroCallPlan = struct {
    macro_name: []const u8,
    import_path: ?[]const u8,
    arity: usize,
    leading_outputs: usize,
    borrowed_arg_mask: u64,
    address_slot_arg_mask: u64,
    callee_borrow_prefix_mask: u64 = 0,
    callee_consume_ptr_mask: u64 = 0,
    expression_output: bool,

    pub fn macroParamIndexForCallArg(self: ImportedMacroCallPlan, call_arg_index: usize) usize {
        return if (self.expression_output) call_arg_index + self.leading_outputs else call_arg_index;
    }

    /// True when the macro body passes this argument plainly into a callee
    /// position whose contract requires a borrow; the emitted operand text
    /// must carry an explicit `&` capability prefix.
    pub fn callArgNeedsBorrowPrefix(self: ImportedMacroCallPlan, call_arg_index: usize) bool {
        const macro_idx = self.macroParamIndexForCallArg(call_arg_index);
        if (macro_idx >= 64) return false;
        return (self.callee_borrow_prefix_mask & (@as(u64, 1) << @intCast(macro_idx))) != 0;
    }

    /// True when the macro body forwards this argument into a callee position
    /// that consumes a pointer (plain `name: ptr` contract parameter); a
    /// possibly-reused caller identifier must be passed as a fresh copy.
    pub fn callArgNeedsConsumeCopy(self: ImportedMacroCallPlan, call_arg_index: usize) bool {
        const macro_idx = self.macroParamIndexForCallArg(call_arg_index);
        if (macro_idx >= 64) return false;
        return (self.callee_consume_ptr_mask & (@as(u64, 1) << @intCast(macro_idx))) != 0;
    }

    pub fn callArgNeedsAddressableSlot(self: ImportedMacroCallPlan, call_arg_index: usize) bool {
        const macro_idx = self.macroParamIndexForCallArg(call_arg_index);
        if (macro_idx >= 64) return false;
        const bit = @as(u64, 1) << @intCast(macro_idx);
        return (self.borrowed_arg_mask & bit) != 0 or (self.address_slot_arg_mask & bit) != 0;
    }

    pub fn callArgNeedsDirectAddressSlot(self: ImportedMacroCallPlan, call_arg_index: usize) bool {
        const macro_idx = self.macroParamIndexForCallArg(call_arg_index);
        if (macro_idx >= 64) return false;
        return (self.address_slot_arg_mask & (@as(u64, 1) << @intCast(macro_idx))) != 0;
    }

    pub fn addressableIdentifierArgName(self: ImportedMacroCallPlan, call_arg_index: usize, arg: *const ast.Node) ?[]const u8 {
        if (!self.callArgNeedsAddressableSlot(call_arg_index)) return null;
        if (arg.* != .identifier) return null;
        return arg.identifier;
    }

    pub fn planAddressableArgAction(self: ImportedMacroCallPlan, call_arg_index: usize, has_existing_addressable_symbol: bool) ImportedMacroAddressableArgAction {
        return self.planAddressExpressionArgAction(call_arg_index, .identifier, has_existing_addressable_symbol);
    }

    pub fn planAddressExpressionArgAction(
        self: ImportedMacroCallPlan,
        call_arg_index: usize,
        address_shape: AddressOfShape,
        has_existing_addressable_symbol: bool,
    ) ImportedMacroAddressableArgAction {
        if (!self.callArgNeedsAddressableSlot(call_arg_index)) return .pass_value;
        if (self.callArgNeedsDirectAddressSlot(call_arg_index)) {
            return switch (address_shape) {
                .identifier => if (has_existing_addressable_symbol) .reuse_existing_addressable else .materialize_stack_slot,
                .deref_borrow_or_pointer, .deref_smart_pointer, .field, .index => .pass_address_expression,
                .value_temp => .pass_value,
            };
        }
        return switch (address_shape) {
            .identifier => if (has_existing_addressable_symbol) .reuse_existing_addressable else .materialize_stack_slot,
            .deref_borrow_or_pointer, .deref_smart_pointer, .field, .index => .materialize_address_expression_stack_slot,
            .value_temp => .materialize_stack_slot,
        };
    }

    pub fn planArgValueBypassAction(
        self: ImportedMacroCallPlan,
        call_arg_index: usize,
        arg: *const ast.Node,
        arg_ty: *const ast.Type,
    ) ?ImportedMacroArgLoweringAction {
        if (!self.callArgNeedsAddressableSlot(call_arg_index)) return .pass_value;
        if (self.callArgNeedsDirectAddressSlot(call_arg_index) and arg.* == .identifier and (arg_ty.* == .infer or abiPassesAsPointer(arg_ty) or importedMacroBorrowUsesRawPointerValue(arg_ty))) return .pass_value;
        if (importedMacroArgUsesRawPointerValue(arg, arg_ty)) return .pass_raw_pointer_value;
        if (arg.* == .identifier and abiPassesAsPointer(arg_ty)) return .pass_value;
        return null;
    }

    pub fn planAddressableArgLoweringAction(
        self: ImportedMacroCallPlan,
        call_arg_index: usize,
        address_shape: AddressOfShape,
        has_existing_addressable_symbol: bool,
        arg_ty: *const ast.Type,
    ) ImportedMacroArgLoweringAction {
        if (self.callArgNeedsAddressableSlot(call_arg_index) and
            !self.callArgNeedsDirectAddressSlot(call_arg_index) and
            abiPassesAsPointer(arg_ty) and
            (address_shape == .field or address_shape == .index))
        {
            return .pass_pointer_backed_projection;
        }
        if (self.callArgNeedsAddressableSlot(call_arg_index) and
            !self.callArgNeedsDirectAddressSlot(call_arg_index) and
            abiPassesAsPointer(arg_ty) and
            (address_shape == .deref_borrow_or_pointer or address_shape == .deref_smart_pointer))
        {
            return .pass_address_expression;
        }
        return switch (self.planAddressExpressionArgAction(call_arg_index, address_shape, has_existing_addressable_symbol)) {
            .pass_value => .pass_value,
            .pass_address_expression => .pass_address_expression,
            .reuse_existing_addressable => .reuse_existing_addressable,
            .materialize_stack_slot => .materialize_stack_slot,
            .materialize_address_expression_stack_slot => .materialize_address_expression_stack_slot,
        };
    }
};

pub fn planBorrowedBindingStorage(binding_is_borrowed: bool, ty: *const ast.Type) BorrowedBindingStoragePlan {
    const needs_scalar_slot = switch (ty.*) {
        .primitive => |primitive| primitive != .raw_ptr,
        else => false,
    };
    return .{ .materialize_stack_slot = binding_is_borrowed and needs_scalar_slot };
}

pub const LoopControlPlan = struct {
    has_break: bool,
    has_continue: bool,
};

pub const WhileLetPatternKind = enum {
    enum_variant,
    option_some,
    option_none,
    result_ok,
    result_err,
};

pub const WhileLetPatternPlan = struct {
    kind: WhileLetPatternKind,
    success_on_true: bool,
    binding_count: usize,

    pub fn isEnumVariant(self: WhileLetPatternPlan) bool {
        return self.kind == .enum_variant;
    }

    pub fn isOptionSome(self: WhileLetPatternPlan) bool {
        return self.kind == .option_some;
    }

    pub fn isOptionNone(self: WhileLetPatternPlan) bool {
        return self.kind == .option_none;
    }

    pub fn isResultOk(self: WhileLetPatternPlan) bool {
        return self.kind == .result_ok;
    }

    pub fn isResultErr(self: WhileLetPatternPlan) bool {
        return self.kind == .result_err;
    }

    pub fn isOptionCheck(self: WhileLetPatternPlan) bool {
        return self.kind == .option_some or self.kind == .option_none;
    }

    pub fn isResultCheck(self: WhileLetPatternPlan) bool {
        return self.kind == .result_ok or self.kind == .result_err;
    }

    pub fn bindsPayload(self: WhileLetPatternPlan) bool {
        return switch (self.kind) {
            .enum_variant, .option_some, .result_ok, .result_err => self.binding_count != 0,
            .option_none => false,
        };
    }
};

pub const LetPatternKind = WhileLetPatternKind;
pub const LetPatternPlan = WhileLetPatternPlan;

pub const DynCoercionKind = enum {
    box_to_dyn,
    rc_new_to_dyn_rc,
};

pub const DynCoercionPlan = struct {
    kind: DynCoercionKind,
    trait_name: []const u8,

    pub fn isBoxToDyn(self: DynCoercionPlan) bool {
        return self.kind == .box_to_dyn;
    }

    pub fn isRcNewToDynRc(self: DynCoercionPlan) bool {
        return self.kind == .rc_new_to_dyn_rc;
    }
};

pub fn planDynCoercion(tc: *type_checker.TypeChecker, expr: *const ast.Node) ?DynCoercionPlan {
    if (tc.dyn_box_coercions.get(expr)) |trait_name| return .{ .kind = .box_to_dyn, .trait_name = trait_name };
    if (tc.dyn_rc_coercions.get(expr)) |trait_name| return .{ .kind = .rc_new_to_dyn_rc, .trait_name = trait_name };
    return null;
}

pub const DynDispatchReceiverKind = enum {
    direct_dyn,
    rc_get_dyn,
};

pub const DynDispatchReceiverPlan = struct {
    kind: DynDispatchReceiverKind,

    pub fn needsRcGetDyn(self: DynDispatchReceiverPlan) bool {
        return self.kind == .rc_get_dyn;
    }

    pub fn isDirectDyn(self: DynDispatchReceiverPlan) bool {
        return self.kind == .direct_dyn;
    }
};

pub fn planDynDispatchReceiver(receiver_ty: *const ast.Type) ?DynDispatchReceiverPlan {
    if (rcInnerType(receiver_ty)) |inner| {
        if (dynTraitName(inner) != null) return .{ .kind = .rc_get_dyn };
    }
    if (dynTraitName(receiver_ty) != null) return .{ .kind = .direct_dyn };
    if (boxInnerType(receiver_ty)) |inner| {
        if (dynTraitName(inner) != null) return .{ .kind = .direct_dyn };
    }
    return null;
}

pub fn planLoopControl(body: []const *ast.Node) LoopControlPlan {
    return .{
        .has_break = blockContainsCurrentLoopBreak(body),
        .has_continue = blockContainsCurrentLoopContinue(body),
    };
}

pub fn collectRepeatedLetBindings(
    allocator: std.mem.Allocator,
    body: []const *ast.Node,
    repeated: *std.StringHashMap(void),
) error{OutOfMemory}!void {
    repeated.clearRetainingCapacity();
    var counts = std.StringHashMap(u32).init(allocator);
    defer counts.deinit();
    try countLetBindingsInBlock(body, &counts);
    var iter = counts.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* >= 2) try repeated.put(entry.key_ptr.*, {});
    }
}

fn countLetBindingsInBlock(body: []const *ast.Node, counts: *std.StringHashMap(u32)) error{OutOfMemory}!void {
    for (body) |node| try countLetBindingsInNode(node, counts);
}

fn countLetBindingsInNode(node: *const ast.Node, counts: *std.StringHashMap(u32)) error{OutOfMemory}!void {
    switch (node.*) {
        .let_stmt => |let| {
            const entry = try counts.getOrPut(let.name);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
            try countLetBindingsInNode(let.value, counts);
        },
        .let_else_stmt => |let| {
            try countLetBindingsInNode(let.value, counts);
            try countLetBindingsInBlock(let.else_block, counts);
        },
        .let_destructure_stmt => |let| try countLetBindingsInNode(let.value, counts),
        .const_stmt => |c| try countLetBindingsInNode(c.value, counts),
        .assign_stmt => |assign| {
            try countLetBindingsInNode(assign.target, counts);
            try countLetBindingsInNode(assign.value, counts);
        },
        .expr_stmt => |expr| try countLetBindingsInNode(expr, counts),
        .return_stmt => |ret| if (ret.value) |value| try countLetBindingsInNode(value, counts),
        .block_stmt => |block| try countLetBindingsInBlock(block.body, counts),
        .binary_expr => |bin| {
            try countLetBindingsInNode(bin.left, counts);
            try countLetBindingsInNode(bin.right, counts);
        },
        .call_expr => |call| for (call.args) |arg| try countLetBindingsInNode(arg, counts),
        .field_expr => |field| try countLetBindingsInNode(field.expr, counts),
        .struct_literal => |lit| {
            for (lit.fields) |field| try countLetBindingsInNode(field.value, counts);
            if (lit.update_expr) |update| try countLetBindingsInNode(update, counts);
        },
        .tuple_literal => |lit| for (lit.elements) |elem| try countLetBindingsInNode(elem, counts),
        .array_literal => |lit| for (lit.elements) |elem| try countLetBindingsInNode(elem, counts),
        .repeat_array_literal => |lit| try countLetBindingsInNode(lit.value, counts),
        .index_expr => |idx| {
            try countLetBindingsInNode(idx.target, counts);
            try countLetBindingsInNode(idx.index, counts);
        },
        .if_expr => |ife| {
            try countLetBindingsInNode(ife.cond, counts);
            if (ife.let_chain) |chain| for (chain) |cond| try countLetBindingsInNode(cond.value, counts);
            try countLetBindingsInBlock(ife.then_block, counts);
            if (ife.else_block) |else_block| try countLetBindingsInBlock(else_block, counts);
        },
        .while_stmt => |w| {
            try countLetBindingsInNode(w.cond, counts);
            try countLetBindingsInBlock(w.body, counts);
        },
        .for_stmt => |f| {
            try countLetBindingsInNode(f.start, counts);
            if (f.end) |end| try countLetBindingsInNode(end, counts);
            try countLetBindingsInBlock(f.body, counts);
        },
        .match_expr => |mat| {
            try countLetBindingsInNode(mat.val, counts);
            for (mat.cases) |case| try countLetBindingsInBlock(case.body, counts);
        },
        .borrow_expr => |borrow| try countLetBindingsInNode(borrow.expr, counts),
        .move_expr => |move| try countLetBindingsInNode(move.expr, counts),
        .deref_expr => |deref| try countLetBindingsInNode(deref.expr, counts),
        .cast_expr => |cast| try countLetBindingsInNode(cast.expr, counts),
        .unsafe_expr => |unsafe_expr| try countLetBindingsInBlock(unsafe_expr.body, counts),
        .await_expr => |aw| try countLetBindingsInNode(aw.expr, counts),
        .closure_literal => |closure| try countLetBindingsInNode(closure.body, counts),
        else => {},
    }
}

pub fn planLetPattern(pattern: ast.EnumPattern, has_user_enum_decl: bool) ?LetPatternPlan {
    if (has_user_enum_decl) {
        return .{
            .kind = .enum_variant,
            .success_on_true = true,
            .binding_count = pattern.bindings.len,
        };
    }

    if (std.mem.eql(u8, pattern.enum_name, "Result") or std.mem.eql(u8, pattern.variant_name, "Ok") or std.mem.eql(u8, pattern.variant_name, "Err")) {
        if (std.mem.eql(u8, pattern.variant_name, "Ok")) {
            return .{ .kind = .result_ok, .success_on_true = true, .binding_count = pattern.bindings.len };
        }
        if (std.mem.eql(u8, pattern.variant_name, "Err")) {
            return .{ .kind = .result_err, .success_on_true = false, .binding_count = pattern.bindings.len };
        }
        return null;
    }

    if (std.mem.eql(u8, pattern.enum_name, "Option") or std.mem.eql(u8, pattern.variant_name, "Some") or std.mem.eql(u8, pattern.variant_name, "None")) {
        if (std.mem.eql(u8, pattern.variant_name, "Some")) {
            return .{ .kind = .option_some, .success_on_true = true, .binding_count = pattern.bindings.len };
        }
        if (std.mem.eql(u8, pattern.variant_name, "None")) {
            return .{ .kind = .option_none, .success_on_true = false, .binding_count = pattern.bindings.len };
        }
        return null;
    }

    return null;
}

pub fn planWhileLetPattern(pattern: ast.EnumPattern, has_user_enum_decl: bool) ?WhileLetPatternPlan {
    return planLetPattern(pattern, has_user_enum_decl);
}

pub fn scalarMatchGuardTempCount(guard: *const ast.Node) ?usize {
    if (guard.* == .call_expr) {
        const call = guard.call_expr;
        if (call.associated_target != null) return null;
        var count: usize = 1;
        for (call.args) |arg| count += scalarMatchGuardValueTempCount(arg) orelse return null;
        return count;
    }
    if (guard.* != .binary_expr) return null;
    const bin = guard.binary_expr;
    return switch (bin.op) {
        .eq, .ne, .lt, .le, .gt, .ge => if (bin.left.* == .identifier and
            (bin.right.* == .identifier or (bin.right.* == .literal and bin.right.literal == .int_val))) 1 else null,
        .logical_and, .logical_or => blk: {
            const left = scalarMatchGuardTempCount(bin.left) orelse break :blk null;
            const right = scalarMatchGuardTempCount(bin.right) orelse break :blk null;
            break :blk left + right + 1;
        },
        else => null,
    };
}

fn scalarMatchGuardValueTempCount(value: *const ast.Node) ?usize {
    if (value.* == .identifier or (value.* == .literal and value.literal == .int_val)) return 0;
    if (value.* == .field_expr) {
        if (value.field_expr.expr.* != .identifier) return null;
        return 1;
    }
    if (value.* == .index_expr) {
        const index = value.index_expr;
        const target_count: usize = if (index.target.* == .identifier)
            0
        else if (index.target.* == .field_expr and index.target.field_expr.expr.* == .identifier)
            1
        else
            return null;
        if (index.index.* == .literal and index.index.literal == .int_val and index.index.literal.int_val >= 0) return target_count + 1;
        if (index.index.* == .identifier) return target_count + 3;
        return target_count + (scalarMatchGuardValueTempCount(index.index) orelse return null) + 3;
    }
    if (value.* == .cast_expr) {
        if (value.cast_expr.ty.* != .primitive) return null;
        return (scalarMatchGuardValueTempCount(value.cast_expr.expr) orelse return null) + 1;
    }
    if (value.* != .binary_expr) return null;
    const bin = value.binary_expr;
    switch (bin.op) {
        .add, .sub, .mul, .div, .mod => {},
        else => return null,
    }
    const left = scalarMatchGuardValueTempCount(bin.left) orelse return null;
    const right = scalarMatchGuardValueTempCount(bin.right) orelse return null;
    return left + right + 1;
}

pub fn supportsScalarMatchGuard(guard: *const ast.Node) bool {
    return scalarMatchGuardTempCount(guard) != null;
}

pub fn blockTerminates(block: []const *ast.Node) bool {
    if (block.len == 0) return false;
    return stmtTerminates(block[block.len - 1]);
}

pub fn stmtTerminates(stmt: *const ast.Node) bool {
    return switch (stmt.*) {
        .return_stmt => true,
        .break_stmt => true,
        .continue_stmt => true,
        .expr_stmt => |expr| exprTerminates(expr),
        else => false,
    };
}

pub fn blockContainsCurrentLoopBreak(block: []const *ast.Node) bool {
    for (block) |stmt| {
        if (stmtContainsCurrentLoopBreak(stmt)) return true;
    }
    return false;
}

pub fn blockContainsCurrentLoopContinue(block: []const *ast.Node) bool {
    for (block) |stmt| {
        if (stmtContainsCurrentLoopContinue(stmt)) return true;
    }
    return false;
}

fn stmtContainsCurrentLoopBreak(stmt: *const ast.Node) bool {
    return switch (stmt.*) {
        .break_stmt => true,
        .for_stmt, .while_stmt => false,
        .block_stmt => |blk| blockContainsCurrentLoopBreak(blk.body),
        .let_else_stmt => |let_else| blockContainsCurrentLoopBreak(let_else.else_block),
        .expr_stmt => |expr| exprContainsCurrentLoopBreak(expr),
        else => false,
    };
}

fn stmtContainsCurrentLoopContinue(stmt: *const ast.Node) bool {
    return switch (stmt.*) {
        .continue_stmt => true,
        .for_stmt, .while_stmt => false,
        .block_stmt => |blk| blockContainsCurrentLoopContinue(blk.body),
        .let_else_stmt => |let_else| blockContainsCurrentLoopContinue(let_else.else_block),
        .expr_stmt => |expr| exprContainsCurrentLoopContinue(expr),
        else => false,
    };
}

fn exprContainsCurrentLoopBreak(expr: *const ast.Node) bool {
    return switch (expr.*) {
        .if_expr => |ife| blockContainsCurrentLoopBreak(ife.then_block) or if (ife.else_block) |eb| blockContainsCurrentLoopBreak(eb) else false,
        .switch_expr => |swe| blk: {
            for (swe.cases) |case| {
                if (blockContainsCurrentLoopBreak(case.body)) break :blk true;
            }
            break :blk false;
        },
        .match_expr => |mat| blk: {
            for (mat.cases) |case| {
                if (blockContainsCurrentLoopBreak(case.body)) break :blk true;
            }
            break :blk false;
        },
        .unsafe_expr => |ue| blockContainsCurrentLoopBreak(ue.body),
        else => false,
    };
}

fn exprContainsCurrentLoopContinue(expr: *const ast.Node) bool {
    return switch (expr.*) {
        .if_expr => |ife| blockContainsCurrentLoopContinue(ife.then_block) or if (ife.else_block) |eb| blockContainsCurrentLoopContinue(eb) else false,
        .switch_expr => |swe| blk: {
            for (swe.cases) |case| {
                if (blockContainsCurrentLoopContinue(case.body)) break :blk true;
            }
            break :blk false;
        },
        .match_expr => |mat| blk: {
            for (mat.cases) |case| {
                if (blockContainsCurrentLoopContinue(case.body)) break :blk true;
            }
            break :blk false;
        },
        .unsafe_expr => |ue| blockContainsCurrentLoopContinue(ue.body),
        else => false,
    };
}

fn exprTerminates(expr: *const ast.Node) bool {
    return switch (expr.*) {
        .call_expr => |call| std.mem.eql(u8, call.func_name, "panic"),
        .unsafe_expr => |ue| blockTerminates(ue.body),
        .if_expr => |ife| blockTerminates(ife.then_block) and if (ife.else_block) |eb| blockTerminates(eb) else false,
        .match_expr => |mat| {
            if (mat.cases.len == 0) return false;
            for (mat.cases) |case| {
                if (!blockTerminates(case.body)) return false;
            }
            return true;
        },
        else => false,
    };
}

pub fn isVoidType(ty: *const ast.Type) bool {
    return ty.* == .primitive and ty.primitive == .void_type;
}

/// SA-text / ABI register type names for scalar and pointer-backed values.
pub fn abiTypeString(ty: *const ast.Type) []const u8 {
    return switch (ty.*) {
        .primitive => |p| switch (p) {
            .boolean => "u8",
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "i64",
            .isize => "i64",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .usize => "u64",
            .f32 => "f32",
            .f64 => "f64",
            .integer => "i64",
            .float => "f64",
            .raw_ptr => "ptr",
            .void_type => "ptr",
        },
        .array => "ptr",
        .tuple => "ptr",
        else => "ptr",
    };
}

pub fn abiReturnTypeString(ty: *const ast.Type) []const u8 {
    return switch (ty.*) {
        .borrow => "&ptr",
        else => abiTypeString(ty),
    };
}

/// Shared pure ABI capability kind for returns/params (before emitter-specific CapPrefix).
pub const AbiCapKind = enum {
    none,
    borrow,
    move,
    raw,
};

/// Shared pure return-cap fact from a typed return type.
pub fn abiCapKindFromType(ty: *const ast.Type) AbiCapKind {
    return if (ty.* == .borrow) .borrow else .none;
}

/// Shared pure ABI capability kind from a raw external type string prefix.
pub fn abiCapKindFromRawTypeString(raw: []const u8) AbiCapKind {
    const name = std.mem.trim(u8, raw, " \t\r");
    if (name.len == 0) return .none;
    return switch (name[0]) {
        '&' => .borrow,
        '^' => .move,
        '*' => .raw,
        else => .none,
    };
}

/// Shared pure temporary-register name fact used by SA-text cleanup/lifecycle.
pub fn isTemporaryRegisterName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "tmp_");
}

/// Shared pure call-arg ABI capability from borrow/move flags (extern params, etc.).
pub fn abiCallArgCapKind(is_borrow: bool, is_move: bool) AbiCapKind {
    if (is_borrow) return .borrow;
    if (is_move) return .move;
    return .none;
}

/// Shared pure single-layer pointer/borrow pointee peel (no multi-layer walk).
pub fn pointerOrBorrowPointee(ty: *const ast.Type) ?*const ast.Type {
    return switch (ty.*) {
        .pointer => |p| p,
        .borrow => |b| b,
        else => null,
    };
}

pub fn abiParamTypeString(is_borrow: bool, is_move: bool, ty: *const ast.Type) []const u8 {
    if (is_borrow or is_move) return "ptr";
    return abiTypeString(ty);
}

pub fn abiParamNeedsBorrowArg(is_borrow: bool, ty: *const ast.Type) bool {
    return is_borrow or ty.* == .borrow;
}

pub fn abiRawPayloadTypeString(raw: []const u8) []const u8 {
    var name = std.mem.trim(u8, raw, " \t\r");
    if (name.len > 0 and (name[0] == '&' or name[0] == '^' or name[0] == '*')) {
        name = std.mem.trim(u8, name[1..], " \t\r");
    }
    if (std.mem.endsWith(u8, name, "!")) {
        name = std.mem.trim(u8, name[0 .. name.len - 1], " \t\r");
    }
    if (std.mem.eql(u8, name, "ptr")) return "ptr";
    if (std.mem.eql(u8, name, "bool")) return "u8";
    if (std.mem.eql(u8, name, "i8")) return "i8";
    if (std.mem.eql(u8, name, "i16")) return "i16";
    if (std.mem.eql(u8, name, "i32")) return "i32";
    if (std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "isize")) return "i64";
    if (std.mem.eql(u8, name, "u8")) return "u8";
    if (std.mem.eql(u8, name, "u16")) return "u16";
    if (std.mem.eql(u8, name, "u32")) return "u32";
    if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "usize")) return "u64";
    if (std.mem.eql(u8, name, "f32")) return "f32";
    if (std.mem.eql(u8, name, "f64") or std.mem.eql(u8, name, "float")) return "f64";
    return "ptr";
}

pub fn ptrReadVolatileMacroName(ty: *const ast.Type) ?[]const u8 {
    const ty_str = abiTypeString(ty);
    if (std.mem.eql(u8, ty_str, "i32")) return "PTR_READ_VOLATILE_I32";
    if (std.mem.eql(u8, ty_str, "u64")) return "PTR_READ_VOLATILE_U64";
    if (std.mem.eql(u8, ty_str, "u8")) return "PTR_READ_VOLATILE_U8";
    return null;
}

pub fn planStaticCallResult(tc: *type_checker.TypeChecker, call_plan: StaticCallPlan, expr_ty: ?*const ast.Type) StaticCallResultPlan {
    if (expr_ty) |ty| return .{ .returns_void = isVoidType(ty) };
    if (tc.funcs.get(call_plan.target_symbol)) |func| {
        return .{ .returns_void = !func.is_async and isVoidType(func.ret_ty) };
    }
    return .{ .returns_void = false };
}

pub fn planAsyncFunctionReturn(func: ast.FuncDecl, ptr_ty: *const ast.Type) AsyncReturnPlan {
    return .{
        .abi_ret_ty = if (func.is_async) ptr_ty else func.ret_ty,
        .wrap_ready_future = func.is_async,
    };
}

const AsyncContinuationAddend = struct {
    immediate: i64 = 0,
    has_immediate: bool = false,
    has_await_binding: bool = false,
    captured_addend_name: ?[]const u8 = null,
    captured2_addend_name: ?[]const u8 = null,
    captured_field_name: ?[]const u8 = null,
    captured2_field_name: ?[]const u8 = null,
    awaited_coeff: i64 = 0,
    captured_coeff: i64 = 0,
    captured2_coeff: i64 = 0,
};

fn captureNameIndex(name: []const u8, capture_names: []const []const u8) ?usize {
    for (capture_names, 0..) |captured, idx| {
        if (std.mem.eql(u8, name, captured)) return idx;
    }
    return null;
}

fn mergeOptionalCaptureField(existing: *?[]const u8, field_name: ?[]const u8) bool {
    if (existing.*) |current| {
        const next = field_name orelse return false;
        return std.mem.eql(u8, current, next);
    }
    if (field_name) |field| existing.* = field;
    return true;
}

fn addAsyncContinuationCapturedTerm(addend: *AsyncContinuationAddend, name: []const u8, field_name: ?[]const u8, coeff: i64, capture_names: []const []const u8) bool {
    const idx = captureNameIndex(name, capture_names) orelse return false;
    switch (idx) {
        0 => {
            if (addend.captured_addend_name) |existing| {
                if (!std.mem.eql(u8, existing, name)) return false;
            } else {
                addend.captured_addend_name = name;
            }
            if (!mergeOptionalCaptureField(&addend.captured_field_name, field_name)) return false;
            addend.captured_coeff = std.math.add(i64, addend.captured_coeff, coeff) catch return false;
            return true;
        },
        1 => {
            if (addend.captured2_addend_name) |existing| {
                if (!std.mem.eql(u8, existing, name)) return false;
            } else {
                addend.captured2_addend_name = name;
            }
            if (!mergeOptionalCaptureField(&addend.captured2_field_name, field_name)) return false;
            addend.captured2_coeff = std.math.add(i64, addend.captured2_coeff, coeff) catch return false;
            return true;
        },
        else => return false,
    }
}

fn collectAsyncContinuationAddend(expr: *const ast.Node, binding_name: []const u8, capture_names: []const []const u8, addend: *AsyncContinuationAddend) bool {
    switch (expr.*) {
        .identifier => |name| {
            if (std.mem.eql(u8, name, binding_name)) {
                addend.has_await_binding = true;
                addend.awaited_coeff += 1;
                return true;
            }
            return addAsyncContinuationCapturedTerm(addend, name, null, 1, capture_names);
        },
        .field_expr => |field| {
            if (field.expr.* != .identifier) return false;
            return addAsyncContinuationCapturedTerm(addend, field.expr.identifier, field.field_name, 1, capture_names);
        },
        .literal => |lit| {
            if (lit != .int_val or addend.has_immediate) return false;
            addend.immediate = lit.int_val;
            addend.has_immediate = true;
            return true;
        },
        .binary_expr => |bin| {
            if (bin.op == .mul) {
                const left_lit = intLiteral(bin.left);
                const right_lit = intLiteral(bin.right);
                if (left_lit != null and right_lit != null) return false;
                const factor = left_lit orelse right_lit orelse return false;
                const expr_side = if (left_lit != null) bin.right else bin.left;
                var nested = AsyncContinuationAddend{};
                if (!collectAsyncContinuationAddend(expr_side, binding_name, capture_names, &nested)) return false;
                if (!scaleAsyncContinuationAddend(&nested, factor)) return false;
                return addAsyncContinuationAddend(addend, nested);
            }
            if (!(bin.op == .add or bin.op == .sub)) return false;
            var left = AsyncContinuationAddend{};
            var right = AsyncContinuationAddend{};
            if (!collectAsyncContinuationAddend(bin.left, binding_name, capture_names, &left)) return false;
            if (!collectAsyncContinuationAddend(bin.right, binding_name, capture_names, &right)) return false;
            if (bin.op == .sub and !scaleAsyncContinuationAddend(&right, -1)) return false;
            return addAsyncContinuationAddend(addend, left) and addAsyncContinuationAddend(addend, right);
        },
        else => return false,
    }
}

fn intLiteral(expr: *const ast.Node) ?i64 {
    return switch (expr.*) {
        .literal => |lit| if (lit == .int_val) lit.int_val else null,
        else => null,
    };
}

fn scaleAsyncContinuationAddend(addend: *AsyncContinuationAddend, factor: i64) bool {
    addend.immediate = std.math.mul(i64, addend.immediate, factor) catch return false;
    addend.awaited_coeff = std.math.mul(i64, addend.awaited_coeff, factor) catch return false;
    addend.captured_coeff = std.math.mul(i64, addend.captured_coeff, factor) catch return false;
    addend.captured2_coeff = std.math.mul(i64, addend.captured2_coeff, factor) catch return false;
    return true;
}

fn mergeAddendFieldName(target: *?[]const u8, field_name: ?[]const u8, coeff: i64) bool {
    if (coeff == 0 and field_name == null) return true;
    return mergeOptionalCaptureField(target, field_name);
}

fn addAsyncContinuationAddend(target: *AsyncContinuationAddend, addend: AsyncContinuationAddend) bool {
    if (addend.has_await_binding) target.has_await_binding = true;
    target.immediate = std.math.add(i64, target.immediate, addend.immediate) catch return false;
    target.awaited_coeff = std.math.add(i64, target.awaited_coeff, addend.awaited_coeff) catch return false;
    if (addend.has_immediate) target.has_immediate = true;
    if (addend.captured_addend_name) |captured| {
        if (target.captured_addend_name) |existing| {
            if (!std.mem.eql(u8, existing, captured)) return false;
        } else {
            target.captured_addend_name = captured;
        }
        if (!mergeAddendFieldName(&target.captured_field_name, addend.captured_field_name, addend.captured_coeff)) return false;
        target.captured_coeff = std.math.add(i64, target.captured_coeff, addend.captured_coeff) catch return false;
    }
    if (addend.captured2_addend_name) |captured| {
        if (target.captured2_addend_name) |existing| {
            if (!std.mem.eql(u8, existing, captured)) return false;
        } else {
            target.captured2_addend_name = captured;
        }
        if (!mergeAddendFieldName(&target.captured2_field_name, addend.captured2_field_name, addend.captured2_coeff)) return false;
        target.captured2_coeff = std.math.add(i64, target.captured2_coeff, addend.captured2_coeff) catch return false;
    }
    return true;
}

fn addendHasInvalidCapture(addend: AsyncContinuationAddend) bool {
    return (addend.captured_addend_name == null and addend.captured_coeff != 0) or (addend.captured2_addend_name == null and addend.captured2_coeff != 0);
}

fn asyncContinuationAddend(expr: *const ast.Node, binding_name: []const u8, capture_names: []const []const u8) ?AsyncContinuationAddend {
    var addend = AsyncContinuationAddend{};
    if (!collectAsyncContinuationAddend(expr, binding_name, capture_names, &addend)) return null;
    if (!addend.has_await_binding or addend.awaited_coeff == 0) return null;
    if (addendHasInvalidCapture(addend)) return null;
    return addend;
}

fn asyncContinuationScalarExpr(expr: *const ast.Node, binding_name: []const u8, capture_names: []const []const u8) ?AsyncContinuationAddend {
    var addend = AsyncContinuationAddend{};
    if (!collectAsyncContinuationAddend(expr, binding_name, capture_names, &addend)) return null;
    if (addendHasInvalidCapture(addend)) return null;
    return addend;
}

fn asyncContinuationReturnExpr(stmt: *const ast.Node) ?*const ast.Node {
    return switch (stmt.*) {
        .return_stmt => |ret| ret.value,
        .expr_stmt => |expr| expr,
        else => null,
    };
}

const AsyncContinuationResult = struct {
    post_binding_name: ?[]const u8 = null,
    addend: i64 = 0,
    captured_addend_name: ?[]const u8 = null,
    captured2_addend_name: ?[]const u8 = null,
    captured_field_name: ?[]const u8 = null,
    captured2_field_name: ?[]const u8 = null,
    scalar: AsyncContinuationScalarPlan = .{},
    branch: ?AsyncContinuationBranchPlan = null,
};

fn scalarPlanFromAddend(addend: AsyncContinuationAddend) AsyncContinuationScalarPlan {
    return .{
        .awaited_coeff = addend.awaited_coeff,
        .captured_coeff = addend.captured_coeff,
        .captured2_coeff = addend.captured2_coeff,
        .captured_field_name = addend.captured_field_name,
        .captured2_field_name = addend.captured2_field_name,
        .immediate = addend.immediate,
    };
}

fn composePostReturnScalar(binding: AsyncContinuationAddend, ret: AsyncContinuationAddend) ?AsyncContinuationScalarPlan {
    if (ret.captured_coeff != 0 or ret.captured_addend_name != null or ret.captured2_coeff != 0 or ret.captured2_addend_name != null) return null;
    var scalar = scalarPlanFromAddend(binding);
    scalar.awaited_coeff = std.math.mul(i64, scalar.awaited_coeff, ret.awaited_coeff) catch return null;
    scalar.captured_coeff = std.math.mul(i64, scalar.captured_coeff, ret.awaited_coeff) catch return null;
    scalar.captured2_coeff = std.math.mul(i64, scalar.captured2_coeff, ret.awaited_coeff) catch return null;
    scalar.immediate = std.math.mul(i64, scalar.immediate, ret.awaited_coeff) catch return null;
    scalar.immediate = std.math.add(i64, scalar.immediate, ret.immediate) catch return null;
    return scalar;
}

const ScalarFieldMerge = struct {
    field_name: ?[]const u8 = null,
};

fn mergeScalarFieldName(base_field: ?[]const u8, base_coeff: i64, expr_field: ?[]const u8, expr_coeff: i64) ?ScalarFieldMerge {
    const base_active = base_coeff != 0 or base_field != null;
    const expr_active = expr_coeff != 0 or expr_field != null;
    if (!base_active) return .{ .field_name = expr_field };
    if (!expr_active) return .{ .field_name = base_field };
    if (base_field) |base| {
        const expr = expr_field orelse return null;
        if (!std.mem.eql(u8, base, expr)) return null;
        return .{ .field_name = base };
    }
    if (expr_field != null) return null;
    return .{};
}

fn composeContinuationScalar(base: AsyncContinuationScalarPlan, expr: AsyncContinuationAddend) ?AsyncContinuationScalarPlan {
    const awaited_coeff = std.math.mul(i64, base.awaited_coeff, expr.awaited_coeff) catch return null;
    const base_captured = std.math.mul(i64, base.captured_coeff, expr.awaited_coeff) catch return null;
    const captured_coeff = std.math.add(i64, base_captured, expr.captured_coeff) catch return null;
    const base_captured2 = std.math.mul(i64, base.captured2_coeff, expr.awaited_coeff) catch return null;
    const captured2_coeff = std.math.add(i64, base_captured2, expr.captured2_coeff) catch return null;
    const captured_field_name = (mergeScalarFieldName(base.captured_field_name, base_captured, expr.captured_field_name, expr.captured_coeff) orelse return null).field_name;
    const captured2_field_name = (mergeScalarFieldName(base.captured2_field_name, base_captured2, expr.captured2_field_name, expr.captured2_coeff) orelse return null).field_name;
    const base_immediate = std.math.mul(i64, base.immediate, expr.awaited_coeff) catch return null;
    const immediate = std.math.add(i64, base_immediate, expr.immediate) catch return null;
    return .{
        .awaited_coeff = awaited_coeff,
        .captured_coeff = captured_coeff,
        .captured2_coeff = captured2_coeff,
        .captured_field_name = captured_field_name,
        .captured2_field_name = captured2_field_name,
        .immediate = immediate,
    };
}

fn captureNameForScalar(captured_name: ?[]const u8, coeff: i64) ?[]const u8 {
    return if (coeff != 0) captured_name else null;
}

fn continuationBlockTailExpr(block: []const *ast.Node) ?*const ast.Node {
    if (block.len != 1) return null;
    const stmt = block[0];
    if (stmt.* != .expr_stmt) return null;
    return stmt.expr_stmt;
}

fn branchConditionPlan(cond: *const ast.Node, binding_name: []const u8) ?struct { op: ast.BinaryOp, threshold: i64 } {
    if (cond.* != .binary_expr) return null;
    const bin = cond.binary_expr;
    if (!(bin.op == .gt or bin.op == .ge or bin.op == .lt or bin.op == .le or bin.op == .eq or bin.op == .ne)) return null;
    if (bin.left.* != .identifier or !std.mem.eql(u8, bin.left.identifier, binding_name)) return null;
    const threshold = intLiteral(bin.right) orelse return null;
    return .{ .op = bin.op, .threshold = threshold };
}

fn mergeBranchCaptureName(left: ?[]const u8, right: ?[]const u8) ?[]const u8 {
    if (left) |l| {
        if (right) |r| {
            if (!std.mem.eql(u8, l, r)) return null;
        }
        return l;
    }
    return right;
}

fn mergeBranchCaptureField(left: ?[]const u8, right: ?[]const u8, left_active: bool, right_active: bool) ?ScalarFieldMerge {
    if (!left_active) return .{ .field_name = right };
    if (!right_active) return .{ .field_name = left };
    if (left) |l| {
        const r = right orelse return null;
        if (!std.mem.eql(u8, l, r)) return null;
        return .{ .field_name = l };
    }
    if (right != null) return null;
    return .{};
}

fn mergeBranchCaptureResult(left: AsyncContinuationAddend, right: AsyncContinuationAddend) ?struct { first: ?[]const u8, second: ?[]const u8, first_field: ?[]const u8, second_field: ?[]const u8 } {
    const first = mergeBranchCaptureName(left.captured_addend_name, right.captured_addend_name);
    if ((left.captured_addend_name != null or right.captured_addend_name != null) and first == null) return null;
    const second = mergeBranchCaptureName(left.captured2_addend_name, right.captured2_addend_name);
    if ((left.captured2_addend_name != null or right.captured2_addend_name != null) and second == null) return null;
    const first_field = mergeBranchCaptureField(left.captured_field_name, right.captured_field_name, left.captured_addend_name != null or left.captured_coeff != 0, right.captured_addend_name != null or right.captured_coeff != 0) orelse return null;
    const second_field = mergeBranchCaptureField(left.captured2_field_name, right.captured2_field_name, left.captured2_addend_name != null or left.captured2_coeff != 0, right.captured2_addend_name != null or right.captured2_coeff != 0) orelse return null;
    return .{ .first = first, .second = second, .first_field = first_field.field_name, .second_field = second_field.field_name };
}

fn asyncContinuationBranch(expr: *const ast.Node, binding_name: []const u8, capture_name: ?[]const u8) ?AsyncContinuationResult {
    if (expr.* != .if_expr) return null;
    const ife = expr.if_expr;
    if (ife.let_chain != null) return null;
    const else_block = ife.else_block orelse return null;
    const cond = branchConditionPlan(ife.cond, binding_name) orelse return null;
    const then_expr = continuationBlockTailExpr(ife.then_block) orelse return null;
    const else_expr = continuationBlockTailExpr(else_block) orelse return null;
    const capture_names = if (capture_name) |captured| &[_][]const u8{captured} else &[_][]const u8{};
    const then_addend = asyncContinuationScalarExpr(then_expr, binding_name, capture_names) orelse return null;
    const else_addend = asyncContinuationScalarExpr(else_expr, binding_name, capture_names) orelse return null;
    const captured = mergeBranchCaptureResult(then_addend, else_addend) orelse return null;
    return .{
        .captured_addend_name = captured.first,
        .captured2_addend_name = captured.second,
        .captured_field_name = captured.first_field,
        .captured2_field_name = captured.second_field,
        .branch = .{
            .condition_op = cond.op,
            .threshold = cond.threshold,
            .then_scalar = scalarPlanFromAddend(then_addend),
            .else_scalar = scalarPlanFromAddend(else_addend),
        },
    };
}

fn asyncContinuationResult(await_binding_name: []const u8, capture_names: []const []const u8, post_stmts: []const *ast.Node, ret_expr: *const ast.Node) ?AsyncContinuationResult {
    if (post_stmts.len != 0) {
        if (post_stmts.len > 2) return null;
        var current_name = await_binding_name;
        var current_scalar = AsyncContinuationScalarPlan{};
        var current_capture_name: ?[]const u8 = null;
        var current_capture2_name: ?[]const u8 = null;
        var current_capture_field_name: ?[]const u8 = null;
        var current_capture2_field_name: ?[]const u8 = null;
        var post_binding_name: ?[]const u8 = null;
        for (post_stmts) |stmt| {
            if (stmt.* != .let_stmt) return null;
            const let_stmt = stmt.let_stmt;
            const addend = asyncContinuationScalarExpr(let_stmt.value, current_name, capture_names) orelse return null;
            if (!addend.has_await_binding or addend.awaited_coeff == 0) return null;
            current_scalar = composeContinuationScalar(current_scalar, addend) orelse return null;
            if (addend.captured_addend_name) |captured| current_capture_name = captured;
            if (addend.captured2_addend_name) |captured| current_capture2_name = captured;
            if (addend.captured_field_name) |field| current_capture_field_name = field;
            if (addend.captured2_field_name) |field| current_capture2_field_name = field;
            current_name = let_stmt.name;
            post_binding_name = let_stmt.name;
        }

        if (ret_expr.* == .identifier and std.mem.eql(u8, ret_expr.identifier, current_name)) {
            const captured = captureNameForScalar(current_capture_name, current_scalar.captured_coeff);
            const captured2 = captureNameForScalar(current_capture2_name, current_scalar.captured2_coeff);
            const captured_field = captureNameForScalar(current_capture_field_name, current_scalar.captured_coeff);
            const captured2_field = captureNameForScalar(current_capture2_field_name, current_scalar.captured2_coeff);
            return .{ .post_binding_name = post_binding_name, .addend = current_scalar.immediate, .captured_addend_name = captured, .captured2_addend_name = captured2, .captured_field_name = captured_field, .captured2_field_name = captured2_field, .scalar = current_scalar };
        }
        const return_addend = asyncContinuationScalarExpr(ret_expr, current_name, &.{}) orelse return null;
        if (!return_addend.has_await_binding or return_addend.awaited_coeff == 0) return null;
        const scalar = composeContinuationScalar(current_scalar, return_addend) orelse return null;
        const captured = captureNameForScalar(current_capture_name, scalar.captured_coeff);
        const captured2 = captureNameForScalar(current_capture2_name, scalar.captured2_coeff);
        const captured_field = captureNameForScalar(current_capture_field_name, scalar.captured_coeff);
        const captured2_field = captureNameForScalar(current_capture2_field_name, scalar.captured2_coeff);
        return .{ .post_binding_name = post_binding_name, .addend = scalar.immediate, .captured_addend_name = captured, .captured2_addend_name = captured2, .captured_field_name = captured_field, .captured2_field_name = captured2_field, .scalar = scalar };
    }

    if (capture_names.len <= 1) {
        const capture_name = if (capture_names.len == 1) capture_names[0] else null;
        if (asyncContinuationBranch(ret_expr, await_binding_name, capture_name)) |branch| return branch;
    }

    const addend = asyncContinuationAddend(ret_expr, await_binding_name, capture_names) orelse return null;
    return .{ .addend = addend.immediate, .captured_addend_name = addend.captured_addend_name, .captured2_addend_name = addend.captured2_addend_name, .captured_field_name = addend.captured_field_name, .captured2_field_name = addend.captured2_field_name, .scalar = scalarPlanFromAddend(addend) };
}

fn stmtIsPreboundAwaitState(stmt: *const ast.Node, next_stmt: *const ast.Node) bool {
    if (stmt.* != .let_stmt or next_stmt.* != .let_stmt) return false;
    const state_let = stmt.let_stmt;
    const await_let = next_stmt.let_stmt;
    if (state_let.value.* != .call_expr or await_let.value.* != .await_expr) return false;
    const awaited_expr = await_let.value.await_expr.expr;
    return awaited_expr.* == .identifier and std.mem.eql(u8, awaited_expr.identifier, state_let.name);
}

const AsyncAwaitBindingShape = struct {
    binding_name: []const u8,
    state_expr: *const ast.Node,
    next_idx: usize,
};

fn asyncAwaitBindingAt(func: *const ast.FuncDecl, idx: usize) ?AsyncAwaitBindingShape {
    if (idx >= func.body.len or func.body[idx].* != .let_stmt) return null;
    const await_let = func.body[idx].let_stmt;
    if (await_let.value.* == .await_expr) {
        return .{
            .binding_name = await_let.name,
            .state_expr = await_let.value.await_expr.expr,
            .next_idx = idx + 1,
        };
    }
    if (idx + 1 >= func.body.len or !stmtIsPreboundAwaitState(func.body[idx], func.body[idx + 1])) return null;
    const state_let = func.body[idx].let_stmt;
    const bound_await_let = func.body[idx + 1].let_stmt;
    return .{
        .binding_name = bound_await_let.name,
        .state_expr = state_let.value,
        .next_idx = idx + 2,
    };
}

fn asyncExprUsesIdentifier(expr: *const ast.Node, name: []const u8) bool {
    return switch (expr.*) {
        .identifier => |ident| std.mem.eql(u8, ident, name),
        .await_expr => |await_expr| asyncExprUsesIdentifier(await_expr.expr, name),
        .binary_expr => |bin| asyncExprUsesIdentifier(bin.left, name) or asyncExprUsesIdentifier(bin.right, name),
        .call_expr => |call| blk: {
            for (call.args) |arg| {
                if (asyncExprUsesIdentifier(arg, name)) break :blk true;
            }
            break :blk false;
        },
        .borrow_expr => |borrow| asyncExprUsesIdentifier(borrow.expr, name),
        .move_expr => |move| asyncExprUsesIdentifier(move.expr, name),
        .deref_expr => |deref| asyncExprUsesIdentifier(deref.expr, name),
        .cast_expr => |cast| asyncExprUsesIdentifier(cast.expr, name),
        .field_expr => |field| asyncExprUsesIdentifier(field.expr, name),
        .index_expr => |index| asyncExprUsesIdentifier(index.target, name) or asyncExprUsesIdentifier(index.index, name),
        .slice_expr => |slice| asyncExprUsesIdentifier(slice.target, name) or
            asyncExprUsesIdentifier(slice.start, name) or
            asyncExprUsesIdentifier(slice.end, name),
        .try_expr => |try_expr| asyncExprUsesIdentifier(try_expr.expr, name),
        else => false,
    };
}

const AsyncTwoAwaitAddend = struct {
    has_first: bool = false,
    has_second: bool = false,
    first_coeff: i64 = 0,
    second_coeff: i64 = 0,
    immediate: i64 = 0,
};

fn scaleAsyncTwoAwaitAddend(addend: *AsyncTwoAwaitAddend, factor: i64) bool {
    addend.first_coeff = std.math.mul(i64, addend.first_coeff, factor) catch return false;
    addend.second_coeff = std.math.mul(i64, addend.second_coeff, factor) catch return false;
    addend.immediate = std.math.mul(i64, addend.immediate, factor) catch return false;
    return true;
}

fn addAsyncTwoAwaitAddend(target: *AsyncTwoAwaitAddend, addend: AsyncTwoAwaitAddend) bool {
    if (addend.has_first) target.has_first = true;
    if (addend.has_second) target.has_second = true;
    target.first_coeff = std.math.add(i64, target.first_coeff, addend.first_coeff) catch return false;
    target.second_coeff = std.math.add(i64, target.second_coeff, addend.second_coeff) catch return false;
    target.immediate = std.math.add(i64, target.immediate, addend.immediate) catch return false;
    return true;
}

fn collectAsyncTwoAwaitAddend(expr: *const ast.Node, first_name: []const u8, second_name: []const u8, addend: *AsyncTwoAwaitAddend) bool {
    switch (expr.*) {
        .identifier => |name| {
            if (std.mem.eql(u8, name, first_name)) {
                addend.has_first = true;
                addend.first_coeff = std.math.add(i64, addend.first_coeff, 1) catch return false;
                return true;
            }
            if (std.mem.eql(u8, name, second_name)) {
                addend.has_second = true;
                addend.second_coeff = std.math.add(i64, addend.second_coeff, 1) catch return false;
                return true;
            }
            return false;
        },
        .literal => |lit| {
            if (lit != .int_val) return false;
            addend.immediate = std.math.add(i64, addend.immediate, lit.int_val) catch return false;
            return true;
        },
        .binary_expr => |bin| {
            if (bin.op == .mul) {
                const left_lit = intLiteral(bin.left);
                const right_lit = intLiteral(bin.right);
                if (left_lit != null and right_lit != null) return false;
                const factor = left_lit orelse right_lit orelse return false;
                const expr_side = if (left_lit != null) bin.right else bin.left;
                var nested = AsyncTwoAwaitAddend{};
                if (!collectAsyncTwoAwaitAddend(expr_side, first_name, second_name, &nested)) return false;
                if (!scaleAsyncTwoAwaitAddend(&nested, factor)) return false;
                return addAsyncTwoAwaitAddend(addend, nested);
            }
            if (!(bin.op == .add or bin.op == .sub)) return false;
            var left = AsyncTwoAwaitAddend{};
            var right = AsyncTwoAwaitAddend{};
            if (!collectAsyncTwoAwaitAddend(bin.left, first_name, second_name, &left)) return false;
            if (!collectAsyncTwoAwaitAddend(bin.right, first_name, second_name, &right)) return false;
            if (bin.op == .sub and !scaleAsyncTwoAwaitAddend(&right, -1)) return false;
            return addAsyncTwoAwaitAddend(addend, left) and addAsyncTwoAwaitAddend(addend, right);
        },
        else => return false,
    }
}

fn asyncTwoAwaitScalarExpr(expr: *const ast.Node, first_name: []const u8, second_name: []const u8) ?AsyncTwoAwaitScalarPlan {
    var addend = AsyncTwoAwaitAddend{};
    if (!collectAsyncTwoAwaitAddend(expr, first_name, second_name, &addend)) return null;
    if (!addend.has_first and !addend.has_second) return null;
    if (addend.first_coeff == 0 and addend.second_coeff == 0) return null;
    return .{
        .first_coeff = addend.first_coeff,
        .second_coeff = addend.second_coeff,
        .immediate = addend.immediate,
    };
}

const AsyncPairResultAddend = struct {
    has_left: bool = false,
    has_right: bool = false,
    left_coeff: i64 = 0,
    right_coeff: i64 = 0,
    immediate: i64 = 0,
};

fn scaleAsyncPairResultAddend(addend: *AsyncPairResultAddend, factor: i64) bool {
    addend.left_coeff = std.math.mul(i64, addend.left_coeff, factor) catch return false;
    addend.right_coeff = std.math.mul(i64, addend.right_coeff, factor) catch return false;
    addend.immediate = std.math.mul(i64, addend.immediate, factor) catch return false;
    return true;
}

fn addAsyncPairResultAddend(target: *AsyncPairResultAddend, addend: AsyncPairResultAddend) bool {
    if (addend.has_left) target.has_left = true;
    if (addend.has_right) target.has_right = true;
    target.left_coeff = std.math.add(i64, target.left_coeff, addend.left_coeff) catch return false;
    target.right_coeff = std.math.add(i64, target.right_coeff, addend.right_coeff) catch return false;
    target.immediate = std.math.add(i64, target.immediate, addend.immediate) catch return false;
    return true;
}

fn pairAccessorKind(expr: *const ast.Node, binding_name: []const u8) ?FutureRuntimeCallKind {
    if (expr.* != .call_expr) return null;
    const call = expr.call_expr;
    const plan = planFutureRuntimeCall(call) orelse return null;
    if (!(plan.kind == .pair_left or plan.kind == .pair_right)) return null;
    if (call.args.len != 1 or call.generics.len != 0) return null;
    const arg = call.args[0];
    if (arg.* != .identifier or !std.mem.eql(u8, arg.identifier, binding_name)) return null;
    return plan.kind;
}

fn collectAsyncPairResultAddend(expr: *const ast.Node, binding_name: []const u8, addend: *AsyncPairResultAddend) bool {
    if (pairAccessorKind(expr, binding_name)) |kind| {
        switch (kind) {
            .pair_left => {
                addend.has_left = true;
                addend.left_coeff = std.math.add(i64, addend.left_coeff, 1) catch return false;
            },
            .pair_right => {
                addend.has_right = true;
                addend.right_coeff = std.math.add(i64, addend.right_coeff, 1) catch return false;
            },
            else => unreachable,
        }
        return true;
    }
    switch (expr.*) {
        .literal => |lit| {
            if (lit != .int_val) return false;
            addend.immediate = std.math.add(i64, addend.immediate, lit.int_val) catch return false;
            return true;
        },
        .binary_expr => |bin| {
            if (bin.op == .mul) {
                const left_lit = intLiteral(bin.left);
                const right_lit = intLiteral(bin.right);
                if (left_lit != null and right_lit != null) return false;
                const factor = left_lit orelse right_lit orelse return false;
                const expr_side = if (left_lit != null) bin.right else bin.left;
                var nested = AsyncPairResultAddend{};
                if (!collectAsyncPairResultAddend(expr_side, binding_name, &nested)) return false;
                if (!scaleAsyncPairResultAddend(&nested, factor)) return false;
                return addAsyncPairResultAddend(addend, nested);
            }
            if (!(bin.op == .add or bin.op == .sub)) return false;
            var left = AsyncPairResultAddend{};
            var right = AsyncPairResultAddend{};
            if (!collectAsyncPairResultAddend(bin.left, binding_name, &left)) return false;
            if (!collectAsyncPairResultAddend(bin.right, binding_name, &right)) return false;
            if (bin.op == .sub and !scaleAsyncPairResultAddend(&right, -1)) return false;
            return addAsyncPairResultAddend(addend, left) and addAsyncPairResultAddend(addend, right);
        },
        else => return false,
    }
}

fn asyncPairResultScalarExpr(expr: *const ast.Node, binding_name: []const u8) ?AsyncPairResultScalarPlan {
    var addend = AsyncPairResultAddend{};
    if (!collectAsyncPairResultAddend(expr, binding_name, &addend)) return null;
    if (!addend.has_left or !addend.has_right) return null;
    if (addend.left_coeff == 0 or addend.right_coeff == 0) return null;
    return .{
        .left_coeff = addend.left_coeff,
        .right_coeff = addend.right_coeff,
        .immediate = addend.immediate,
    };
}

fn join2HasLaterReadyInput(call: ast.CallExpr) bool {
    if (call.args.len != 2) return false;
    var has_defer_ready = false;
    var has_ready = false;
    for (call.args) |arg| {
        if (arg.* != .call_expr) return false;
        const plan = planFutureRuntimeCall(arg.call_expr) orelse return false;
        switch (plan.kind) {
            .defer_ready => has_defer_ready = true,
            .ready => has_ready = true,
            else => return false,
        }
    }
    return has_defer_ready and has_ready;
}

pub fn planAsyncJoin2AwaitContinuation(func: *const ast.FuncDecl) ?AsyncJoin2AwaitContinuationPlan {
    if (!func.is_async) return null;
    const awaited = asyncAwaitBindingAt(func, 0) orelse return null;
    if (awaited.next_idx + 1 != func.body.len) return null;
    const ret_expr = asyncContinuationReturnExpr(func.body[awaited.next_idx]) orelse return null;
    if (awaited.state_expr.* != .call_expr) return null;
    const awaited_call = planFutureRuntimeCall(awaited.state_expr.call_expr) orelse return null;
    if (awaited_call.kind != .join2) return null;
    if (!join2HasLaterReadyInput(awaited.state_expr.call_expr)) return null;
    const scalar = asyncPairResultScalarExpr(ret_expr, awaited.binding_name) orelse return null;
    return .{
        .binding_name = awaited.binding_name,
        .await_expr = awaited.state_expr,
        .awaited_kind = awaited_call.kind,
        .scalar = scalar,
    };
}

fn planAsyncTwoAwaitContinuationInternal(func: *const ast.FuncDecl, allow_dynamic: bool) ?AsyncTwoAwaitContinuationPlan {
    if (!func.is_async) return null;
    const first = asyncAwaitBindingAt(func, 0) orelse return null;
    const second = asyncAwaitBindingAt(func, first.next_idx) orelse return null;
    if (second.next_idx + 1 != func.body.len) return null;
    const ret_expr = asyncContinuationReturnExpr(func.body[second.next_idx]) orelse return null;
    if (first.state_expr.* != .call_expr or second.state_expr.* != .call_expr) return null;
    const first_call = planFutureRuntimeCall(first.state_expr.call_expr);
    const second_call = planFutureRuntimeCall(second.state_expr.call_expr);
    const first_dynamic = first_call == null;
    const second_dynamic = second_call == null;
    const second_depends_on_first = asyncExprUsesIdentifier(second.state_expr, first.binding_name);
    if (!allow_dynamic and (first_dynamic or second_dynamic or second_depends_on_first)) return null;
    if (first_call) |call| {
        if (call.kind != .defer_ready) return null;
    }
    if (second_call) |call| {
        if (call.kind != .defer_ready) return null;
    }
    if (allow_dynamic and !first_dynamic and !second_dynamic and !second_depends_on_first) return null;
    const scalar = asyncTwoAwaitScalarExpr(ret_expr, first.binding_name, second.binding_name) orelse return null;
    return .{
        .first_binding_name = first.binding_name,
        .second_binding_name = second.binding_name,
        .first_await_expr = first.state_expr,
        .second_await_expr = second.state_expr,
        .first_awaited_kind = if (first_call) |call| call.kind else .defer_ready,
        .second_awaited_kind = if (second_call) |call| call.kind else .defer_ready,
        .first_dynamic_poll = first_dynamic,
        .second_dynamic_poll = second_dynamic,
        .second_depends_on_first = second_depends_on_first,
        .scalar = scalar,
    };
}

pub fn planAsyncTwoAwaitContinuation(func: *const ast.FuncDecl) ?AsyncTwoAwaitContinuationPlan {
    return planAsyncTwoAwaitContinuationInternal(func, false);
}

pub fn planAsyncTwoAwaitContinuationDynamic(func: *const ast.FuncDecl) ?AsyncTwoAwaitContinuationPlan {
    return planAsyncTwoAwaitContinuationInternal(func, true);
}

fn planAsyncSingleAwaitContinuationInternal(func: *const ast.FuncDecl, allow_dynamic: bool) ?AsyncSingleAwaitContinuationPlan {
    if (!func.is_async) return null;

    const ContinuationShape = struct {
        binding_name: []const u8,
        state_expr: *const ast.Node,
        ret_expr: *const ast.Node,
        post_stmts: []const *ast.Node = &.{},
        capture_count: usize = 0,
        captures: [2]?AsyncContinuationCapturePlan = .{ null, null },
    };

    var idx: usize = 0;
    var capture_count: usize = 0;
    var captures: [2]?AsyncContinuationCapturePlan = .{ null, null };
    var capture_names: [2][]const u8 = undefined;
    while (capture_count < captures.len and idx < func.body.len and func.body[idx].* == .let_stmt) {
        const capture_let = func.body[idx].let_stmt;
        const is_direct_await = capture_let.value.* == .await_expr;
        const is_prebound_state = idx + 1 < func.body.len and stmtIsPreboundAwaitState(func.body[idx], func.body[idx + 1]);
        if (is_direct_await or is_prebound_state) break;
        captures[capture_count] = .{
            .name = capture_let.name,
            .expr = capture_let.value,
            .offset = 16 + capture_count * 8,
        };
        capture_names[capture_count] = capture_let.name;
        capture_count += 1;
        idx += 1;
    }

    if (idx >= func.body.len or func.body[idx].* != .let_stmt) return null;
    const first_await_let = func.body[idx].let_stmt;

    var binding_name: []const u8 = undefined;
    var state_expr: *const ast.Node = undefined;
    if (first_await_let.value.* == .await_expr) {
        binding_name = first_await_let.name;
        state_expr = first_await_let.value.await_expr.expr;
        idx += 1;
    } else {
        if (idx + 1 >= func.body.len or !stmtIsPreboundAwaitState(func.body[idx], func.body[idx + 1])) return null;
        const state_let = func.body[idx].let_stmt;
        const await_let = func.body[idx + 1].let_stmt;
        binding_name = await_let.name;
        state_expr = state_let.value;
        idx += 2;
    }

    if (idx >= func.body.len) return null;
    const post_stmts = func.body[idx .. func.body.len - 1];
    const ret_expr = asyncContinuationReturnExpr(func.body[func.body.len - 1]) orelse return null;

    const shape = ContinuationShape{
        .binding_name = binding_name,
        .state_expr = state_expr,
        .ret_expr = ret_expr,
        .post_stmts = post_stmts,
        .capture_count = capture_count,
        .captures = captures,
    };

    if (shape.state_expr.* != .call_expr) return null;
    const awaited_call = planFutureRuntimeCall(shape.state_expr.call_expr);
    const dynamic_poll = awaited_call == null;
    if (!allow_dynamic and dynamic_poll) return null;
    if (awaited_call) |call| {
        if (call.kind != .defer_ready) return null;
    }
    if (allow_dynamic and !dynamic_poll) return null;

    const result = asyncContinuationResult(shape.binding_name, capture_names[0..shape.capture_count], shape.post_stmts, shape.ret_expr) orelse return null;
    const used_capture_count: usize = @as(usize, if (result.captured_addend_name != null) 1 else 0) + @as(usize, if (result.captured2_addend_name != null) 1 else 0);
    if (shape.capture_count != used_capture_count) return null;

    var plan_captures: [2]?AsyncContinuationCapturePlan = .{ null, null };
    if (result.captured_addend_name) |captured| {
        var first = shape.captures[0] orelse return null;
        if (!std.mem.eql(u8, first.name, captured)) return null;
        first.storage = if (result.captured_field_name != null) .copy_struct else .scalar;
        plan_captures[0] = first;
    }
    if (result.captured2_addend_name) |captured| {
        var second = shape.captures[1] orelse return null;
        if (!std.mem.eql(u8, second.name, captured)) return null;
        second.storage = if (result.captured2_field_name != null) .copy_struct else .scalar;
        plan_captures[1] = second;
    }
    return .{
        .binding_name = shape.binding_name,
        .post_binding_name = result.post_binding_name,
        .captured_addend_name = result.captured_addend_name,
        .captured_addend_expr = if (plan_captures[0]) |capture| capture.expr else null,
        .capture_count = used_capture_count,
        .captures = plan_captures,
        .await_expr = shape.state_expr,
        .awaited_kind = if (awaited_call) |call| call.kind else .defer_ready,
        .dynamic_poll = dynamic_poll,
        .addend = result.addend,
        .scalar = result.scalar,
        .branch = result.branch,
    };
}

pub fn planAsyncSingleAwaitContinuation(func: *const ast.FuncDecl) ?AsyncSingleAwaitContinuationPlan {
    return planAsyncSingleAwaitContinuationInternal(func, false);
}

pub fn planAsyncSingleAwaitContinuationDynamic(func: *const ast.FuncDecl) ?AsyncSingleAwaitContinuationPlan {
    return planAsyncSingleAwaitContinuationInternal(func, true);
}

pub fn exprIsStaticallyPendingFuture(expr: *const ast.Node) bool {
    return exprFutureReadiness(expr, null) == .pending;
}

pub fn exprIsStaticallyReadyFuture(expr: *const ast.Node) bool {
    return exprFutureReadiness(expr, null) == .ready;
}

pub fn join2Readiness(left: FutureReadiness, right: FutureReadiness) FutureReadiness {
    if (left == .ready and right == .ready) return .ready;
    if (left == .pending or right == .pending) return .pending;
    return .unknown;
}

pub fn select2Readiness(left: FutureReadiness, right: FutureReadiness) FutureReadiness {
    if (left == .ready or right == .ready) return .ready;
    if (left == .pending and right == .pending) return .pending;
    return .unknown;
}

pub fn exprFutureReadiness(expr: *const ast.Node, readiness_by_name: ?*const std.StringHashMap(FutureReadiness)) FutureReadiness {
    if (expr.* == .identifier) {
        if (readiness_by_name) |map| return map.get(expr.identifier) orelse .unknown;
        return .unknown;
    }
    if (expr.* != .call_expr) return .unknown;
    const call = expr.call_expr;
    const plan = planFutureRuntimeCall(call) orelse return .unknown;
    return switch (plan.kind) {
        .ready => .ready,
        .pending => .pending,
        .join2 => if (call.args.len == 2)
            join2Readiness(exprFutureReadiness(call.args[0], readiness_by_name), exprFutureReadiness(call.args[1], readiness_by_name))
        else
            .unknown,
        .select2 => if (call.args.len == 2)
            select2Readiness(exprFutureReadiness(call.args[0], readiness_by_name), exprFutureReadiness(call.args[1], readiness_by_name))
        else
            .unknown,
        else => .unknown,
    };
}

pub fn exprNeedsPollOnceForReadyAwait(expr: *const ast.Node, readiness_by_name: ?*const std.StringHashMap(FutureReadiness)) bool {
    if (expr.* != .call_expr) return false;
    const call = expr.call_expr;
    const plan = planFutureRuntimeCall(call) orelse return false;
    return switch (plan.kind) {
        .join2, .select2 => exprFutureReadiness(expr, readiness_by_name) == .ready,
        else => false,
    };
}

pub fn futureInnerType(ty: *const ast.Type) ?*ast.Type {
    const curr = peelBorrowPointerType(ty);
    if (curr.* != .future) return null;
    return curr.future;
}

pub fn typesEquivalent(a: *const ast.Type, b: *const ast.Type) bool {
    if (a.* == .infer or b.* == .infer) return true;
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .infer => true,
        .primitive => |pa| pa == b.primitive,
        .pointer => |pa| typesEquivalent(pa, b.pointer),
        .borrow => |ba| typesEquivalent(ba, b.borrow),
        .array => |aa| aa.len == b.array.len and typesEquivalent(aa.elem, b.array.elem),
        .tuple => |ta| blk: {
            if (ta.elems.len != b.tuple.elems.len) break :blk false;
            for (ta.elems, b.tuple.elems) |ea, eb| {
                if (!typesEquivalent(ea, eb)) break :blk false;
            }
            break :blk true;
        },
        .future => |fa| typesEquivalent(fa, b.future),
        .closure => |ca| blk: {
            if (ca.params.len != b.closure.params.len) break :blk false;
            for (ca.params, b.closure.params) |pa, pb| {
                if (!typesEquivalent(pa, pb)) break :blk false;
            }
            break :blk typesEquivalent(ca.ret, b.closure.ret);
        },
        .fn_ptr => |fa| blk: {
            if (fa.abi == null) {
                if (b.fn_ptr.abi != null) break :blk false;
            } else if (b.fn_ptr.abi == null or !std.mem.eql(u8, fa.abi.?, b.fn_ptr.abi.?)) {
                break :blk false;
            }
            if (fa.params.len != b.fn_ptr.params.len) break :blk false;
            for (fa.params, b.fn_ptr.params) |pa, pb| {
                if (!typesEquivalent(pa, pb)) break :blk false;
            }
            break :blk typesEquivalent(fa.ret, b.fn_ptr.ret);
        },
        .user_defined => |ua| blk: {
            if (!std.mem.eql(u8, ua.name, b.user_defined.name)) break :blk false;
            if (ua.generics.len != b.user_defined.generics.len) break :blk false;
            for (ua.generics, b.user_defined.generics) |ga, gb| {
                if (!typesEquivalent(ga, gb)) break :blk false;
            }
            break :blk true;
        },
    };
}

pub fn planAwaitFuture(expr: *const ast.Node, future_ty: *const ast.Type, async_return_ty: ?*const ast.Type) AwaitPlan {
    return planAwaitFutureWithReadiness(expr, future_ty, async_return_ty, null);
}

pub fn planAwaitFutureWithReadiness(expr: *const ast.Node, future_ty: *const ast.Type, async_return_ty: ?*const ast.Type, readiness_by_name: ?*const std.StringHashMap(FutureReadiness)) AwaitPlan {
    const inner = futureInnerType(future_ty);
    return .{
        .ready_state_inner = true,
        .pending_return_if_async = exprFutureReadiness(expr, readiness_by_name) == .pending,
        .poll_once_if_statically_ready = exprNeedsPollOnceForReadyAwait(expr, readiness_by_name),
        .ready_pending_state_return_if_async = if (async_return_ty) |ret_ty|
            if (inner) |inner_ty| typesEquivalent(inner_ty, ret_ty) else false
        else
            false,
    };
}

pub fn planFutureRuntimeCall(call: ast.CallExpr) ?FutureRuntimeCallPlan {
    if (call.associated_target) |target| {
        if (!std.mem.eql(u8, target, "future")) return null;
        if (std.mem.eql(u8, call.func_name, "ready")) return .{ .kind = .ready };
        if (std.mem.eql(u8, call.func_name, "pending")) return .{ .kind = .pending };
        if (std.mem.eql(u8, call.func_name, "defer_ready")) return .{ .kind = .defer_ready };
        if (std.mem.eql(u8, call.func_name, "sleep_ms")) return .{ .kind = .sleep_ms };
        if (std.mem.eql(u8, call.func_name, "join2")) return .{ .kind = .join2 };
        if (std.mem.eql(u8, call.func_name, "pair_left")) return .{ .kind = .pair_left };
        if (std.mem.eql(u8, call.func_name, "pair_right")) return .{ .kind = .pair_right };
        if (std.mem.eql(u8, call.func_name, "select2")) return .{ .kind = .select2 };
        if (std.mem.eql(u8, call.func_name, "either_side")) return .{ .kind = .either_side };
        if (std.mem.eql(u8, call.func_name, "either_left")) return .{ .kind = .either_left };
        if (std.mem.eql(u8, call.func_name, "either_right")) return .{ .kind = .either_right };
        return null;
    }
    if (std.mem.eql(u8, call.func_name, "future__ready")) return .{ .kind = .ready };
    if (std.mem.eql(u8, call.func_name, "future__pending")) return .{ .kind = .pending };
    if (std.mem.eql(u8, call.func_name, "future__defer_ready")) return .{ .kind = .defer_ready };
    if (std.mem.eql(u8, call.func_name, "future__sleep_ms")) return .{ .kind = .sleep_ms };
    if (std.mem.eql(u8, call.func_name, "future__join2")) return .{ .kind = .join2 };
    if (std.mem.eql(u8, call.func_name, "future__pair_left")) return .{ .kind = .pair_left };
    if (std.mem.eql(u8, call.func_name, "future__pair_right")) return .{ .kind = .pair_right };
    if (std.mem.eql(u8, call.func_name, "future__select2")) return .{ .kind = .select2 };
    if (std.mem.eql(u8, call.func_name, "future__either_side")) return .{ .kind = .either_side };
    if (std.mem.eql(u8, call.func_name, "future__either_left")) return .{ .kind = .either_left };
    if (std.mem.eql(u8, call.func_name, "future__either_right")) return .{ .kind = .either_right };
    return null;
}

pub fn planTaskRuntimeCall(call: ast.CallExpr) ?TaskRuntimeCallPlan {
    const target = call.associated_target orelse return null;
    if (!std.mem.eql(u8, target, "task")) return null;
    if (std.mem.eql(u8, call.func_name, "new")) return .{ .kind = .new };
    if (std.mem.eql(u8, call.func_name, "poll")) return .{ .kind = .poll };
    if (std.mem.eql(u8, call.func_name, "is_ready")) return .{ .kind = .is_ready };
    if (std.mem.eql(u8, call.func_name, "result")) return .{ .kind = .result };
    if (std.mem.eql(u8, call.func_name, "state")) return .{ .kind = .state };
    return null;
}

pub fn planExecutorRuntimeCall(call: ast.CallExpr) ?ExecutorRuntimeCallPlan {
    const target = call.associated_target orelse return null;
    if (!std.mem.eql(u8, target, "executor")) return null;
    if (std.mem.eql(u8, call.func_name, "new")) return .{ .kind = .new };
    if (std.mem.eql(u8, call.func_name, "poll_one")) return .{ .kind = .poll_one };
    if (std.mem.eql(u8, call.func_name, "poll_ready_count")) return .{ .kind = .poll_ready_count };
    if (std.mem.eql(u8, call.func_name, "run_until_complete")) return .{ .kind = .run_until_complete };
    return null;
}

pub fn planPollRuntimeCall(call: ast.CallExpr) ?PollRuntimeCallPlan {
    if (call.associated_target) |target| {
        if (!std.mem.eql(u8, target, "poll")) return null;
        if (std.mem.eql(u8, call.func_name, "ready")) return .{ .kind = .ready };
        if (std.mem.eql(u8, call.func_name, "pending")) return .{ .kind = .pending };
        if (std.mem.eql(u8, call.func_name, "is_ready")) return .{ .kind = .is_ready };
        if (std.mem.eql(u8, call.func_name, "is_pending")) return .{ .kind = .is_pending };
        if (std.mem.eql(u8, call.func_name, "value")) return .{ .kind = .value };
        return null;
    }
    if (std.mem.eql(u8, call.func_name, "poll__ready")) return .{ .kind = .ready };
    if (std.mem.eql(u8, call.func_name, "poll__pending")) return .{ .kind = .pending };
    if (std.mem.eql(u8, call.func_name, "poll__is_ready")) return .{ .kind = .is_ready };
    if (std.mem.eql(u8, call.func_name, "poll__is_pending")) return .{ .kind = .is_pending };
    if (std.mem.eql(u8, call.func_name, "poll__value")) return .{ .kind = .value };
    return null;
}

pub fn importedMacroUsesExpressionOutput(macro: type_checker.ImportedMacro, arg_count: usize) bool {
    return macro.leading_outputs == 1 and arg_count + 1 == macro.arity;
}

pub const ImportedMacroExpressionResultKind = enum {
    raw_pointer,
    boolean,
    u8,
    u32,
    u64,
    i32,
    i64,
    f64,
    slice_u8,
};

pub fn importedMacroExpressionResultKind(macro_name: []const u8) ?ImportedMacroExpressionResultKind {
    if (std.mem.eql(u8, macro_name, "ENV_ARGS_JSON") or
        std.mem.eql(u8, macro_name, "ENV_VARS_JSON") or
        std.mem.eql(u8, macro_name, "ENV_SPLIT_PATHS_JSON") or
        std.mem.eql(u8, macro_name, "ENV_JOIN_PATHS_JSON") or
        std.mem.eql(u8, macro_name, "SLA_FS_OPEN_READ") or
        std.mem.eql(u8, macro_name, "SLA_FS_READ_TO_STRING") or
        std.mem.eql(u8, macro_name, "SLA_FS_READ_FILE") or
        std.mem.eql(u8, macro_name, "SLA_FS_METADATA"))
    {
        return .u64;
    }
    if (std.mem.eql(u8, macro_name, "JSON_PARSE") or
        std.mem.eql(u8, macro_name, "SLA_BUF_ALLOC") or
        std.mem.eql(u8, macro_name, "SLA_JSON_OBJECT_GET") or
        std.mem.eql(u8, macro_name, "SLA_JSON_ARRAY_GET") or
        std.mem.eql(u8, macro_name, "SLA_JSON_STRINGIFY") or
        std.mem.eql(u8, macro_name, "PIN_GET_REF") or
        std.mem.eql(u8, macro_name, "PIN_MUT_GET_REF") or
        std.mem.eql(u8, macro_name, "PIN_MUT_GET_MUT") or
        std.mem.eql(u8, macro_name, "PIN_MUT_GET_UNCHECKED_MUT") or
        std.mem.eql(u8, macro_name, "FUTURE_READY_POLL_STATE") or
        std.mem.eql(u8, macro_name, "FUTURE_POLL_STATE") or
        std.mem.eql(u8, macro_name, "FUTURE_PENDING_POLL_STATE") or
        std.mem.eql(u8, macro_name, "RAW_WAKER_NEW") or
        std.mem.eql(u8, macro_name, "RAW_WAKER_CLONE") or
        std.mem.eql(u8, macro_name, "RAW_WAKER_VTABLE_NEW") or
        std.mem.eql(u8, macro_name, "FUTURE_POLL_FN_STATE_NEW") or
        std.mem.eql(u8, macro_name, "FUTURE_POLL_FN_STATE_POLL") or
        std.mem.eql(u8, macro_name, "PTR_READ_U64") or
        std.mem.eql(u8, macro_name, "WAKER_FROM_RAW") or
        std.mem.eql(u8, macro_name, "CONTEXT_FROM_WAKER") or
        std.mem.eql(u8, macro_name, "ONCE_NEW") or
        std.mem.eql(u8, macro_name, "LAZY_LOCK_NEW") or
        std.mem.eql(u8, macro_name, "POLL_VALUE_PTR") or
        std.mem.endsWith(u8, macro_name, "_PTR") or
        std.mem.endsWith(u8, macro_name, "_DATA") or
        std.mem.endsWith(u8, macro_name, "_AS_PTR") or
        std.mem.endsWith(u8, macro_name, "_ADD") or
        std.mem.endsWith(u8, macro_name, "_NULL"))
    {
        return .raw_pointer;
    }
    if (std.mem.startsWith(u8, macro_name, "JSON_IS_") or
        std.mem.eql(u8, macro_name, "POLL_IS_READY") or
        std.mem.eql(u8, macro_name, "POLL_IS_PENDING") or
        std.mem.eql(u8, macro_name, "PIN_PTR_EQ") or
        std.mem.eql(u8, macro_name, "PIN_MUT_PTR_EQ"))
    {
        return .boolean;
    }
    if (std.mem.eql(u8, macro_name, "SLA_BYTE_AT") or
        std.mem.eql(u8, macro_name, "JSON_AS_BOOL") or
        std.mem.eql(u8, macro_name, "SLA_JSON_AS_BOOL") or
        std.mem.eql(u8, macro_name, "SLA_FS_EXISTS") or
        std.mem.eql(u8, macro_name, "SLA_FS_IS_FILE") or
        std.mem.eql(u8, macro_name, "SLA_FS_IS_DIR") or
        std.mem.endsWith(u8, macro_name, "_GET_BOOL") or
        std.mem.endsWith(u8, macro_name, "_READ_U8"))
    {
        return .u8;
    }
    if (std.mem.endsWith(u8, macro_name, "_KIND")) return .u32;
    if (std.mem.endsWith(u8, macro_name, "_READ_U64")) return .u64;
    if (std.mem.endsWith(u8, macro_name, "_READ_I32")) return .i32;
    if (std.mem.eql(u8, macro_name, "JSON_AS_I64") or
        std.mem.eql(u8, macro_name, "SLA_JSON_AS_I64") or
        std.mem.endsWith(u8, macro_name, "_GET_I64"))
    {
        return .i64;
    }
    if (std.mem.eql(u8, macro_name, "JSON_AS_F64") or
        std.mem.endsWith(u8, macro_name, "_GET_F64"))
    {
        return .f64;
    }
    if (std.mem.endsWith(u8, macro_name, "_LEN") or
        std.mem.endsWith(u8, macro_name, "_COUNT"))
    {
        return .i64;
    }
    if (std.mem.endsWith(u8, macro_name, "_FROM_PARTS") or
        std.mem.endsWith(u8, macro_name, "_AS_BYTES") or
        std.mem.endsWith(u8, macro_name, "_BYTES"))
    {
        return .slice_u8;
    }
    return null;
}

pub fn planImportedMacroCall(tc: *type_checker.TypeChecker, call: ast.CallExpr) ?ImportedMacroCallPlan {
    if (call.associated_target != null) return null;
    const macro = tc.imported_macros.get(call.func_name) orelse return null;
    const expression_output = importedMacroUsesExpressionOutput(macro, call.args.len);
    if (call.args.len != macro.arity and !expression_output) return null;
    return .{
        .macro_name = call.func_name,
        .import_path = macro.import_path,
        .arity = macro.arity,
        .leading_outputs = macro.leading_outputs,
        .borrowed_arg_mask = macro.borrowed_arg_mask,
        .address_slot_arg_mask = macro.address_slot_arg_mask,
        .callee_borrow_prefix_mask = macro.callee_borrow_prefix_mask,
        .callee_consume_ptr_mask = macro.callee_consume_ptr_mask,
        .expression_output = expression_output,
    };
}

pub const PrefixedIdentifierArg = struct {
    prefix: u8,
    name: []const u8,
};

pub const CallArgMaterializationKind = enum {
    raw_pointer_string_literal,
    array_to_slice_borrow,
    dyn_borrow,
    auto_borrow,
    copy_struct_value,
    generated_fn_ptr_value_slot,
    borrow_local_fn_ptr_value,
    shallow_copy_preserved_value,
    value,
};

pub const CallArgMaterializationTarget = enum {
    sa_text,
    direct_sab,
};

pub const CallArgMaterializationInput = struct {
    target: CallArgMaterializationTarget = .sa_text,
    param: ?ast.Param = null,
    arg_ty: ?*const ast.Type = null,
    arg_index: usize = 0,
    auto_borrow_receiver: bool = false,
    receiver_style_auto_borrow: bool = false,
    statement_receiver_auto_borrow: bool = false,
    abi_borrow_auto_borrow: bool = false,
    array_to_slice_borrow: bool = false,
    dyn_borrow_trait_name: ?[]const u8 = null,
    copy_struct_value: bool = false,
    generated_fn_ptr_identifier: bool = false,
    local_fn_ptr_identifier: bool = false,
    preserve_identifier_for_later_use: bool = false,
    shallow_copy_value: bool = false,
    generated_scalar_const_identifier: bool = false,
    value_arg_transfers_ownership: bool = false,
};

pub const CallArgMaterializationPlan = struct {
    kind: CallArgMaterializationKind,
    release_after_call: bool,
    dyn_borrow_trait_name: ?[]const u8 = null,
    transfers_ownership: bool = false,

    pub fn isRawPointerStringLiteral(self: CallArgMaterializationPlan) bool {
        return self.kind == .raw_pointer_string_literal;
    }
    pub fn isArrayToSliceBorrow(self: CallArgMaterializationPlan) bool {
        return self.kind == .array_to_slice_borrow;
    }
    pub fn isDynBorrow(self: CallArgMaterializationPlan) bool {
        return self.kind == .dyn_borrow;
    }
    pub fn isAutoBorrow(self: CallArgMaterializationPlan) bool {
        return self.kind == .auto_borrow;
    }
    pub fn isCopyStructValue(self: CallArgMaterializationPlan) bool {
        return self.kind == .copy_struct_value;
    }
    pub fn isGeneratedFnPtrValueSlot(self: CallArgMaterializationPlan) bool {
        return self.kind == .generated_fn_ptr_value_slot;
    }
    pub fn isBorrowLocalFnPtrValue(self: CallArgMaterializationPlan) bool {
        return self.kind == .borrow_local_fn_ptr_value;
    }
    pub fn isShallowCopyPreservedValue(self: CallArgMaterializationPlan) bool {
        return self.kind == .shallow_copy_preserved_value;
    }
    pub fn isValue(self: CallArgMaterializationPlan) bool {
        return self.kind == .value;
    }
};

pub const AbiFieldLayout = struct {
    offset: usize,
    size: usize,
    ty: *const ast.Type,
};

pub const StructLiteralFieldSource = enum {
    explicit,
    update,
};

pub const StructLiteralFieldTransfer = enum {
    direct,
    deep_copy,
    move,

    pub fn isDirect(self: StructLiteralFieldTransfer) bool {
        return self == .direct;
    }
    pub fn isDeepCopy(self: StructLiteralFieldTransfer) bool {
        return self == .deep_copy;
    }
    pub fn isMove(self: StructLiteralFieldTransfer) bool {
        return self == .move;
    }
};

pub const StructLiteralFieldPlan = struct {
    source: StructLiteralFieldSource,
    name: []const u8,
    value: ?*ast.Node,
    layout: AbiFieldLayout,
    field_ty: *const ast.Type,
    /// Whether an `.update` field's loaded value should be released after
    /// being stored. Mirrors SA-text's `callArgNeedsRelease(update_expr)`,
    /// so identifier-backed sources are not released (move-by-reuse) while
    /// temporary sources are released.
    release_loaded: bool,

    pub fn isExplicit(self: StructLiteralFieldPlan) bool {
        return self.source == .explicit;
    }
    pub fn isUpdate(self: StructLiteralFieldPlan) bool {
        return self.source == .update;
    }
};

pub const SliceAbi = struct {
    pub const size: usize = 16;
    pub const ptr_offset: usize = 0;
    pub const len_offset: usize = 8;
};

pub const VecAbi = struct {
    pub const object_size: usize = 24;
    pub const ptr_offset: usize = 0;
    pub const cap_offset: usize = 8;
    pub const len_offset: usize = 16;
};

pub const OptionClosureMethodKind = enum {
    map,
    and_then,
    unwrap_or_else,
};

pub const OptionClosureCallPlan = struct {
    kind: OptionClosureMethodKind,
    receiver_arg_index: usize = 0,
    closure_arg_index: usize = 1,
    closure_arity: usize,

    pub fn isMap(self: OptionClosureCallPlan) bool {
        return self.kind == .map;
    }

    pub fn isAndThen(self: OptionClosureCallPlan) bool {
        return self.kind == .and_then;
    }

    pub fn isUnwrapOrElse(self: OptionClosureCallPlan) bool {
        return self.kind == .unwrap_or_else;
    }
};

pub const SmartPointerKind = enum {
    box,
    rc,
    arc,
    refcell,
};

pub const SmartPointerType = struct {
    kind: SmartPointerKind,
    inner: *ast.Type,
};

pub const RefCellBorrowKind = enum {
    shared,
    mutable,
};

pub const RefCellBorrowValueKind = enum {
    scalar_slot,
    pointer_payload,
    smart_pointer_payload,
};

pub const RefCellBorrowPlan = struct {
    kind: RefCellBorrowKind,
    inner: *ast.Type,
    value_kind: RefCellBorrowValueKind,

    pub fn isMutable(self: RefCellBorrowPlan) bool {
        return self.kind == .mutable;
    }

    pub fn tryBorrowMacroName(self: RefCellBorrowPlan) []const u8 {
        return if (self.isMutable()) "REFCELL_U64_TRY_BORROW_MUT" else "REFCELL_U64_TRY_BORROW";
    }

    pub fn releaseMacroName(self: RefCellBorrowPlan) []const u8 {
        return refCellBorrowReleaseMacroName(self.kind);
    }
};

pub const RefCellBorrowResultTarget = enum {
    sa_text,
    direct_sab,
};

pub const RefCellBorrowResultAction = enum {
    use_borrow_slot,
    load_pointer_payload,
    take_pointer_payload,

    pub fn usesBorrowSlot(self: RefCellBorrowResultAction) bool {
        return self == .use_borrow_slot;
    }

    pub fn loadsPointerPayload(self: RefCellBorrowResultAction) bool {
        return self == .load_pointer_payload;
    }

    pub fn takesPointerPayload(self: RefCellBorrowResultAction) bool {
        return self == .take_pointer_payload;
    }
};

pub const RefCellBorrowResultPlan = struct {
    action: RefCellBorrowResultAction,
    release_borrow_slot_after_payload: bool,
    track_borrow_slot_release_temp: bool,
};

pub const RefCellBorrowRuntimeGuardPlan = struct {
    release_status_on_conflict: bool,
    conflict_panic_code: i64,
    release_status_on_success: bool,
};

pub const RefCellBorrowHandleRegistrationPlan = struct {
    track_receiver_owner_temp: bool,
};

pub const BorrowAddressTempPlan = struct {
    track_primary_temp: bool,
    track_extra_temps: bool,
    remember: bool,
};

pub const BorrowAddressTempTransferAction = enum {
    transfer_value_state,
    move_borrow_address_temps,

    pub fn movesBorrowAddressTemps(self: BorrowAddressTempTransferAction) bool {
        return self == .move_borrow_address_temps;
    }
};

pub const BorrowAddressTempReleasePlan = struct {
    release_borrow_value: bool,
    release_source_temps: bool,
};

pub const PrefixedBorrowAddressCallArgReleasePlan = struct {
    emit_arg_prefix: bool,
    restore_taken_value: bool,
    release_address_value: bool,
    release_source_temps: bool,
};

pub const PrefixedBorrowAddressCallArgRestoreTiming = enum {
    after_call,
    before_sibling_args,
};

pub const ResultSlotTransferPlan = struct {
    transfers_value: bool,
    needs_refcell_companion: bool,
};

pub const ResultSlotRefCellStoreAction = enum {
    transfer_value_state,
    store_borrow_handle_companion,

    pub fn storesBorrowHandleCompanion(self: ResultSlotRefCellStoreAction) bool {
        return self == .store_borrow_handle_companion;
    }
};

pub const ResultSlotRefCellLoadAction = enum {
    transfer_value_state,
    restore_borrow_handle_companion,
    release_empty_companion,

    pub fn restoresBorrowHandleCompanion(self: ResultSlotRefCellLoadAction) bool {
        return self == .restore_borrow_handle_companion;
    }

    pub fn releasesEmptyCompanion(self: ResultSlotRefCellLoadAction) bool {
        return self == .release_empty_companion;
    }
};

pub const ResultSlotLoadLifecycleAction = enum {
    load_value_state,
    no_value_state,

    pub fn loadsValueState(self: ResultSlotLoadLifecycleAction) bool {
        return self == .load_value_state;
    }
};

pub const ResultSlotStoreLifecycleAction = enum {
    transfer_value_state,
    release_source,
    keep_source,

    pub fn transfersValueState(self: ResultSlotStoreLifecycleAction) bool {
        return self == .transfer_value_state;
    }

    pub fn releasesSource(self: ResultSlotStoreLifecycleAction) bool {
        return self == .release_source;
    }
};

pub const RefCellHandleBindingAction = enum {
    ordinary_binding,
    bind_borrow_handle,

    pub fn bindsBorrowHandle(self: RefCellHandleBindingAction) bool {
        return self == .bind_borrow_handle;
    }
};

pub const RefCellHandleTransferAction = enum {
    transfer_value_state,
    move_borrow_handle,

    pub fn movesBorrowHandle(self: RefCellHandleTransferAction) bool {
        return self == .move_borrow_handle;
    }
};

pub const RefCellValueStateTransferPlan = struct {
    handle: RefCellHandleTransferAction,
    borrow_address_temps: BorrowAddressTempTransferAction,
};

pub const RefCellHandleReleasePlan = struct {
    release_dynamic_borrow: bool,
    consume_handle_value: bool,
    release_owner_temps: bool,
};

pub const RefCellHandleCellReleaseAction = enum {
    skip,
    release_handle,

    pub fn shouldRelease(self: RefCellHandleCellReleaseAction) bool {
        return self == .release_handle;
    }
};

pub const RefCellHandleOwnerTransferAction = enum {
    keep_owner,
    rebind_owner,

    pub fn rebindsOwner(self: RefCellHandleOwnerTransferAction) bool {
        return self == .rebind_owner;
    }
};

pub const RefCellCallArgLifecycleAction = enum {
    keep,
    release_value,
    release_borrow_handle,

    pub fn shouldRelease(self: RefCellCallArgLifecycleAction) bool {
        return self != .keep;
    }

    pub fn releasesBorrowHandle(self: RefCellCallArgLifecycleAction) bool {
        return self == .release_borrow_handle;
    }
};

pub const StackSlotIdentifierCallArgTempAction = enum {
    keep,
    release_temp,
    consume_temp,

    pub fn isKeep(self: StackSlotIdentifierCallArgTempAction) bool {
        return self == .keep;
    }

    pub fn releasesTemp(self: StackSlotIdentifierCallArgTempAction) bool {
        return self == .release_temp;
    }

    pub fn consumesTemp(self: StackSlotIdentifierCallArgTempAction) bool {
        return self == .consume_temp;
    }
};

pub const DerefAssignmentTargetLifecycleAction = enum {
    keep,
    release_value,
    release_borrow_handle,

    pub fn shouldRelease(self: DerefAssignmentTargetLifecycleAction) bool {
        return self != .keep;
    }
};

pub const RefCellCompanionStoreCleanupPlan = struct {
    consume_handle_value: bool,
    release_owner_temps: bool,
    release_borrow_address_temps: bool,
    clear_non_owning_metadata: bool,
};

pub const RefCellCompanionRestorePlan = struct {
    track_loaded_cell_owner_temp: bool,
    release_companion_slot_after_restore: bool,
};

pub const RefCellBranchStateMergeAction = control_flow_rules.BranchStateMergeAction;
pub const RefCellBranchHandleOwnerMergeAction = enum {
    keep_static_owner,
    merge_dynamic_owner,

    pub fn isMergeDynamicOwner(self: RefCellBranchHandleOwnerMergeAction) bool {
        return self == .merge_dynamic_owner;
    }
};
pub const MultiBranchStateMergeAction = control_flow_rules.MultiBranchStateMergeAction;

pub const RefCellLoopStateMergeAction = enum {
    restore_pre_loop,

    pub fn restoresPreLoop(self: RefCellLoopStateMergeAction) bool {
        return self == .restore_pre_loop;
    }
};

pub fn planResultSlotRefCellStore(transfer_plan: ResultSlotTransferPlan, source_has_refcell_handle: bool) ResultSlotRefCellStoreAction {
    if (transfer_plan.transfers_value and source_has_refcell_handle) return .store_borrow_handle_companion;
    return .transfer_value_state;
}

pub fn planResultSlotRefCellLoad(
    transfer_plan: ResultSlotTransferPlan,
    slot_has_refcell_handle: bool,
    slot_has_refcell_companion: bool,
) ResultSlotRefCellLoadAction {
    if (!transfer_plan.transfers_value) return .transfer_value_state;
    if (slot_has_refcell_handle) return .restore_borrow_handle_companion;
    if (slot_has_refcell_companion) return .release_empty_companion;
    return .transfer_value_state;
}

pub fn planResultSlotLoadLifecycle(transfer_plan: ResultSlotTransferPlan) ResultSlotLoadLifecycleAction {
    return if (transfer_plan.transfers_value) .load_value_state else .no_value_state;
}

pub fn planResultSlotStoreLifecycle(transfer_plan: ResultSlotTransferPlan, source_needs_release: bool) ResultSlotStoreLifecycleAction {
    if (transfer_plan.transfers_value) return .transfer_value_state;
    return if (source_needs_release) .release_source else .keep_source;
}

pub fn planRefCellHandleBinding(source_has_refcell_handle: bool) RefCellHandleBindingAction {
    return if (source_has_refcell_handle) .bind_borrow_handle else .ordinary_binding;
}

pub fn planRefCellHandleTransfer(source_has_refcell_handle: bool) RefCellHandleTransferAction {
    return if (source_has_refcell_handle) .move_borrow_handle else .transfer_value_state;
}

pub fn planRefCellValueStateTransfer(
    source_has_refcell_handle: bool,
    source_has_borrow_address_temps: bool,
) RefCellValueStateTransferPlan {
    return .{
        .handle = planRefCellHandleTransfer(source_has_refcell_handle),
        .borrow_address_temps = planBorrowAddressTempTransfer(source_has_borrow_address_temps),
    };
}

pub fn planRefCellHandleRelease(has_owner_temps: bool) RefCellHandleReleasePlan {
    return .{
        .release_dynamic_borrow = true,
        .consume_handle_value = true,
        .release_owner_temps = has_owner_temps,
    };
}

pub fn planRefCellHandleCellRelease(handle_cell_matches_release_target: bool, handle_is_release_target: bool) RefCellHandleCellReleaseAction {
    if (!handle_cell_matches_release_target) return .skip;
    if (handle_is_release_target) return .skip;
    return .release_handle;
}

pub fn planRefCellHandleOwnerTransfer(handle_cell_matches_source: bool) RefCellHandleOwnerTransferAction {
    return if (handle_cell_matches_source) .rebind_owner else .keep_owner;
}

pub fn planRefCellCallArgLifecycle(release_after_call: bool, carries_refcell_borrow_handle: bool) RefCellCallArgLifecycleAction {
    if (!release_after_call) return .keep;
    if (carries_refcell_borrow_handle) return .release_borrow_handle;
    return .release_value;
}

pub fn planStackSlotIdentifierCallArgTemp(
    param: ?ast.Param,
    is_identifier_stack_slot_temp: bool,
) StackSlotIdentifierCallArgTempAction {
    if (!is_identifier_stack_slot_temp) return .keep;
    const target_param = param orelse return .release_temp;
    if (byValueRawPointerParam(target_param)) return .consume_temp;
    return .release_temp;
}

pub fn planDerefAssignmentTargetLifecycle(target_is_temporary: bool, carries_refcell_borrow_handle: bool) DerefAssignmentTargetLifecycleAction {
    if (!target_is_temporary) return .keep;
    if (carries_refcell_borrow_handle) return .release_borrow_handle;
    return .release_value;
}

pub fn planRefCellBorrowResult(target: RefCellBorrowResultTarget, value_kind: RefCellBorrowValueKind) RefCellBorrowResultPlan {
    return switch (target) {
        .sa_text => switch (value_kind) {
            .scalar_slot => .{
                .action = .use_borrow_slot,
                .release_borrow_slot_after_payload = false,
                .track_borrow_slot_release_temp = false,
            },
            .pointer_payload, .smart_pointer_payload => .{
                .action = .load_pointer_payload,
                .release_borrow_slot_after_payload = true,
                .track_borrow_slot_release_temp = false,
            },
        },
        .direct_sab => switch (value_kind) {
            .scalar_slot, .smart_pointer_payload => .{
                .action = .use_borrow_slot,
                .release_borrow_slot_after_payload = false,
                .track_borrow_slot_release_temp = false,
            },
            .pointer_payload => .{
                .action = .take_pointer_payload,
                .release_borrow_slot_after_payload = false,
                .track_borrow_slot_release_temp = true,
            },
        },
    };
}

pub fn planRefCellBorrowRuntimeGuard(_: RefCellBorrowPlan) RefCellBorrowRuntimeGuardPlan {
    return .{
        .release_status_on_conflict = true,
        .conflict_panic_code = 107,
        .release_status_on_success = true,
    };
}

pub fn planRefCellBorrowHandleRegistration(_: RefCellBorrowPlan) RefCellBorrowHandleRegistrationPlan {
    return .{
        .track_receiver_owner_temp = false,
    };
}

pub fn planBorrowAddressTemps(has_primary_temp: bool, has_extra_temps: bool) BorrowAddressTempPlan {
    return .{
        .track_primary_temp = has_primary_temp,
        .track_extra_temps = has_extra_temps,
        .remember = has_primary_temp or has_extra_temps,
    };
}

pub fn planBorrowAddressTempTransfer(source_has_borrow_address_temps: bool) BorrowAddressTempTransferAction {
    return if (source_has_borrow_address_temps) .move_borrow_address_temps else .transfer_value_state;
}

pub fn planBorrowAddressTempRelease(has_borrow_address_temps: bool) BorrowAddressTempReleasePlan {
    return .{
        .release_borrow_value = has_borrow_address_temps,
        .release_source_temps = has_borrow_address_temps,
    };
}

pub fn planPrefixedBorrowAddressCallArgRelease(prefix: u8, address_value_is_temp: bool, has_source_temps: bool, has_taken_value_restore: bool) PrefixedBorrowAddressCallArgReleasePlan {
    return .{
        .emit_arg_prefix = prefix == '&' or prefix == '^',
        .restore_taken_value = prefix == '&' and has_taken_value_restore,
        .release_address_value = prefix == '&' and address_value_is_temp and !has_taken_value_restore,
        .release_source_temps = has_source_temps,
    };
}

pub fn planPrefixedBorrowAddressCallArgRestoreTiming(prefix: u8, has_taken_value_restore: bool, has_sibling_args: bool) PrefixedBorrowAddressCallArgRestoreTiming {
    if (prefix == '&' and has_taken_value_restore and has_sibling_args) return .before_sibling_args;
    return .after_call;
}

pub fn prefixedBorrowAddressCallArgNeedsOperandPrefix(prefix: u8, address_source_materialized: bool) bool {
    if (prefix == '&' and address_source_materialized) return false;
    return prefix == '&' or prefix == '^';
}

pub fn prefixedBorrowAddressCallArgOperandPrefix(prefix: u8, address_source_materialized: bool) ?u8 {
    return if (prefixedBorrowAddressCallArgNeedsOperandPrefix(prefix, address_source_materialized)) prefix else null;
}

pub fn planRefCellCompanionStoreCleanup(
    has_owner_temps: bool,
    has_borrow_address_temps: bool,
    has_non_owning_metadata: bool,
) RefCellCompanionStoreCleanupPlan {
    return .{
        .consume_handle_value = true,
        .release_owner_temps = has_owner_temps,
        .release_borrow_address_temps = has_borrow_address_temps,
        .clear_non_owning_metadata = has_non_owning_metadata,
    };
}

pub fn planRefCellCompanionRestore() RefCellCompanionRestorePlan {
    return .{
        .track_loaded_cell_owner_temp = true,
        .release_companion_slot_after_restore = true,
    };
}

pub fn planRefCellBranchStateMerge(then_terminated: bool, else_terminated: bool) RefCellBranchStateMergeAction {
    return control_flow_rules.planBranchStateMerge(then_terminated, else_terminated);
}

pub fn planRefCellBranchHandleOwnerMerge(
    then_live: bool,
    else_live: bool,
    same_kind: bool,
    same_owner: bool,
) RefCellBranchHandleOwnerMergeAction {
    if (then_live and else_live and same_kind and !same_owner) return .merge_dynamic_owner;
    return .keep_static_owner;
}

pub fn planMultiBranchStateMerge(live_branch_count: usize) MultiBranchStateMergeAction {
    return control_flow_rules.planMultiBranchStateMerge(live_branch_count);
}

pub fn planRefCellLoopStateMerge() RefCellLoopStateMergeAction {
    return .restore_pre_loop;
}

pub fn refCellBorrowReleaseMacroName(kind: RefCellBorrowKind) []const u8 {
    return switch (kind) {
        .shared => "REFCELL_U64_RELEASE_SHARED",
        .mutable => "REFCELL_U64_RELEASE_MUT",
    };
}

pub fn abiTypeSize(ty: *const ast.Type) usize {
    return switch (ty.*) {
        .primitive => |p| switch (p) {
            .boolean, .u8, .i8 => 1,
            .u16, .i16 => 2,
            .u32, .i32, .f32 => 4,
            .u64, .i64, .usize, .isize, .f64 => 8,
            .integer, .float => 8,
            .raw_ptr, .void_type => 8,
        },
        .array => 8,
        .tuple => |tuple| tupleAbiSize(tuple),
        else => 8,
    };
}

pub fn abiFalliblePayloadOffset(raw: []const u8) usize {
    var name = std.mem.trim(u8, raw, " \t\r");
    if (name.len > 0 and (name[0] == '&' or name[0] == '^' or name[0] == '*')) {
        name = std.mem.trim(u8, name[1..], " \t\r");
    }
    if (std.mem.endsWith(u8, name, "!")) {
        name = std.mem.trim(u8, name[0 .. name.len - 1], " \t\r");
    }
    const payload_align: usize = if (std.mem.eql(u8, name, "ptr") or
        std.mem.eql(u8, name, "i64") or
        std.mem.eql(u8, name, "u64") or
        std.mem.eql(u8, name, "isize") or
        std.mem.eql(u8, name, "usize") or
        std.mem.eql(u8, name, "int") or
        std.mem.eql(u8, name, "f64") or
        std.mem.eql(u8, name, "float")) 8 else 4;
    return (4 + payload_align - 1) & ~(payload_align - 1);
}

pub fn abiPassesAsPointer(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .pointer, .borrow, .fn_ptr, .user_defined, .tuple, .array, .future => true,
        else => false,
    };
}

/// Current SA macro borrow lowering expects raw pointer-like values to stay in
/// value registers. Materializing them into stack slots turns `&%arg` inside a
/// macro fragment into a pointer-to-pointer ABI mismatch for std/runtime calls
/// such as `sa_json_parse` and `sa_json_object_get`.
pub fn importedMacroBorrowUsesRawPointerValue(arg_ty: *const ast.Type) bool {
    return switch (arg_ty.*) {
        .primitive => |p| p == .raw_ptr,
        .pointer, .borrow => true,
        else => false,
    };
}

pub fn importedMacroArgUsesRawPointerValue(arg: *const ast.Node, arg_ty: *const ast.Type) bool {
    if (importedMacroBorrowUsesRawPointerValue(arg_ty)) return true;
    return switch (arg.*) {
        .call_expr => |call| std.mem.endsWith(u8, call.func_name, "_PTR") or
            std.mem.endsWith(u8, call.func_name, "_AS_PTR") or
            std.mem.eql(u8, call.func_name, "as_ptr"),
        else => false,
    };
}

pub fn alignAggregateOffset(offset: usize, size: usize) usize {
    if (size == 8) return (offset + 7) & ~@as(usize, 7);
    return offset;
}

pub fn tupleAbiSize(tuple: ast.TupleType) usize {
    var offset: usize = 0;
    for (tuple.elems) |elem_ty| {
        const size = abiTypeSize(elem_ty);
        offset = alignAggregateOffset(offset, size);
        offset += size;
    }
    return @max(offset, 1);
}

pub fn tupleFieldLayout(tuple: ast.TupleType, index: usize) ?AbiFieldLayout {
    var offset: usize = 0;
    for (tuple.elems, 0..) |elem_ty, i| {
        const size = abiTypeSize(elem_ty);
        offset = alignAggregateOffset(offset, size);
        if (i == index) return .{ .offset = offset, .size = size, .ty = elem_ty };
        offset += size;
    }
    return null;
}

pub fn inlineArrayStride(elem_ty: *const ast.Type) usize {
    return @max(abiTypeSize(elem_ty), 1);
}

pub fn inlineArraySize(arr: ast.ArrayType) usize {
    return @max(inlineArrayStride(arr.elem) * arr.len, 1);
}

/// Direct SAB stores fixed-array struct fields inline, while generated SA still
/// stores an array pointer in the field's first word. Reserve enough bytes for
/// both representations so they share all following field offsets without
/// changing `abiTypeSize`, which remains the pointer-sized value ABI.
pub fn structFieldStorageSize(ty: *const ast.Type) usize {
    return switch (ty.*) {
        .array => |arr| @max(inlineArraySize(arr), abiTypeSize(ty)),
        else => abiTypeSize(ty),
    };
}

/// Aggregate alignment follows the stored scalar (or fixed-array element)
/// width. In particular, arrays of ptr/i64 elements must begin on an 8-byte
/// boundary even when the preceding inline array ends at an odd offset.
pub fn structFieldAlignmentSize(ty: *const ast.Type) usize {
    return switch (ty.*) {
        .array => |arr| abiTypeSize(arr.elem),
        else => abiTypeSize(ty),
    };
}

pub fn arrayElementLayout(arr: ast.ArrayType, index: usize) ?AbiFieldLayout {
    if (index >= arr.len) return null;
    const stride = inlineArrayStride(arr.elem);
    return .{ .offset = stride * index, .size = stride, .ty = arr.elem };
}

pub fn arrayRestLen(arr: ast.ArrayType, prefix_count: usize) ?usize {
    if (prefix_count > arr.len) return null;
    return arr.len - prefix_count;
}

pub fn optionInnerType(ty: *const ast.Type) ?*ast.Type {
    const curr = peelBorrowPointerType(ty);
    if (curr.* != .user_defined) return null;
    if (!std.mem.eql(u8, curr.user_defined.name, "Option") or curr.user_defined.generics.len != 1) return null;
    return curr.user_defined.generics[0];
}

pub fn resultOkType(ty: *const ast.Type) ?*ast.Type {
    const curr = peelBorrowPointerType(ty);
    if (curr.* != .user_defined) return null;
    if (!std.mem.eql(u8, curr.user_defined.name, "Result") or curr.user_defined.generics.len != 2) return null;
    return curr.user_defined.generics[0];
}

pub fn resultErrType(ty: *const ast.Type) ?*ast.Type {
    const curr = peelBorrowPointerType(ty);
    if (curr.* != .user_defined) return null;
    if (!std.mem.eql(u8, curr.user_defined.name, "Result") or curr.user_defined.generics.len != 2) return null;
    return curr.user_defined.generics[1];
}

pub fn patternUsesResultMacros(enum_name: []const u8, variant_name: []const u8) bool {
    return std.mem.eql(u8, enum_name, "Result") or std.mem.eql(u8, variant_name, "Ok") or std.mem.eql(u8, variant_name, "Err");
}

pub fn patternUsesOptionMacros(enum_name: []const u8, variant_name: []const u8) bool {
    return std.mem.eql(u8, enum_name, "Option") or std.mem.eql(u8, variant_name, "Some") or std.mem.eql(u8, variant_name, "None");
}

pub fn asyncContinuationConditionOpName(op: ast.BinaryOp) ?[]const u8 {
    return switch (op) {
        .eq => "eq",
        .ne => "ne",
        .lt => "slt",
        .le => "sle",
        .gt => "sgt",
        .ge => "sge",
        else => null,
    };
}

pub fn enumNameMatchesDecl(pattern_name: []const u8, decl_name: []const u8) bool {
    if (std.mem.eql(u8, pattern_name, decl_name)) return true;
    if (decl_name.len <= pattern_name.len) return false;
    if (!std.mem.startsWith(u8, decl_name, pattern_name)) return false;
    return decl_name[pattern_name.len] == '_';
}

pub fn literalZero(expr: *const ast.Node) bool {
    return expr.* == .literal and switch (expr.literal) {
        .int_val => |v| v == 0,
        .float_val => |v| v == 0.0,
        else => false,
    };
}

/// Shared pure gate: non-opaque/non-union struct whose fields are all numeric.
pub fn structFieldsAllNumeric(decl: *const ast.StructDecl) bool {
    if (decl.is_opaque or decl.is_union) return false;
    for (decl.fields) |field| {
        if (!isNumericType(field.ty)) return false;
    }
    return true;
}

/// Shared pure gate: non-opaque/non-union struct whose fields are all
/// non-void primitives (Eq/Ord-style scalar aggregates).
pub fn structFieldsAllComparable(decl: *const ast.StructDecl) bool {
    if (decl.is_opaque or decl.is_union) return false;
    for (decl.fields) |field| {
        switch (field.ty.*) {
            .primitive => |p| switch (p) {
                .raw_ptr, .void_type => return false,
                else => {},
            },
            else => return false,
        }
    }
    return true;
}

/// Shared pure discard-binding name fact (`_`).
pub fn isDiscardName(name: []const u8) bool {
    return std.mem.eql(u8, name, "_");
}

/// Shared pure recognition of `thread::spawn(closure)` style calls.
pub fn isThreadSpawnCall(call: ast.CallExpr) bool {
    return call.associated_target != null and
        std.mem.eql(u8, call.associated_target.?, "thread") and
        std.mem.eql(u8, call.func_name, "spawn") and
        call.args.len == 1;
}

/// Shared pure fact: std-macro template integer literal argument text.
pub fn isStdMacroTemplateIntegerArg(arg: []const u8) bool {
    if (arg.len == 0) return false;
    var start: usize = 0;
    if (arg[0] == '-') {
        if (arg.len == 1) return false;
        start = 1;
    }
    for (arg[start..]) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

/// Shared pure fact: std-macro template identifier argument text.
pub fn isStdMacroTemplateIdentArg(arg: []const u8) bool {
    if (arg.len == 0) return false;
    for (arg, 0..) |ch, idx| {
        const is_alpha = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
        const is_digit = ch >= '0' and ch <= '9';
        if (idx == 0) {
            if (!is_alpha) return false;
        } else if (!is_alpha and !is_digit) return false;
    }
    return true;
}

/// Shared pure fact: std-macro template argument text is integer or identifier.
pub fn isStdMacroTemplateArgSafe(arg: []const u8) bool {
    if (arg.len == 0) return false;
    if (isStdMacroTemplateIntegerArg(arg)) return true;
    return isStdMacroTemplateIdentArg(arg);
}

/// Shared pure identifier-character fact used by SAB call-body/target scanners.
pub fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Shared pure switch-default pattern fact (`default` identifier).
pub fn isSwitchDefaultPattern(pattern: *const ast.Node) bool {
    return pattern.* == .identifier and std.mem.eql(u8, pattern.identifier, "default");
}

/// Shared pure recognition of bare `stack_alloc(...)` (no associated target).
pub fn isStackAllocCall(call: ast.CallExpr) bool {
    return call.associated_target == null and std.mem.eql(u8, call.func_name, "stack_alloc");
}

/// Shared pure node peel for bare `stack_alloc(...)` expressions.
pub fn isStackAllocNode(node: *const ast.Node) bool {
    return node.* == .call_expr and isStackAllocCall(node.call_expr);
}

/// Shared pure typecheck internal sentinel symbol name.
pub fn isInternalSymbol(name: []const u8) bool {
    return std.mem.eql(u8, name, "return_ty_sentinel");
}

/// Shared pure atomic Ordering path-name fact used by typecheck identifier typing.
pub fn isOrderingName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Ordering::SeqCst") or
        std.mem.eql(u8, name, "Ordering::Acquire") or
        std.mem.eql(u8, name, "Ordering::Release") or
        std.mem.eql(u8, name, "Ordering::Relaxed") or
        std.mem.eql(u8, name, "Ordering::AcqRel");
}

/// Shared pure non-owning pointer-carrier cast-of-identifier call-arg fact.
pub fn isNonOwningPointerCarrierCastArg(arg: *const ast.Node) bool {
    return switch (arg.*) {
        .cast_expr => |cast| cast.expr.* == .identifier and isPointerCarrierCastType(cast.ty),
        else => false,
    };
}

/// Shared pure ABI type-name fact: pointer carrier markers (`^`, `&`, `*`).
pub fn isPointerAbiTypeName(name: []const u8) bool {
    const raw = std.mem.trim(u8, name, " \t\r");
    return raw.len > 0 and (raw[0] == '^' or raw[0] == '&' or raw[0] == '*');
}

/// Shared pure ABI type-name fact: integer primitive ABI spellings.
pub fn isIntegerAbiTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "i8") or
        std.mem.eql(u8, name, "u8") or
        std.mem.eql(u8, name, "i16") or
        std.mem.eql(u8, name, "u16") or
        std.mem.eql(u8, name, "i32") or
        std.mem.eql(u8, name, "u32") or
        std.mem.eql(u8, name, "i64") or
        std.mem.eql(u8, name, "u64") or
        std.mem.eql(u8, name, "usize") or
        std.mem.eql(u8, name, "isize");
}

/// Shared pure builtin panic function-name fact (`panic` / `panic_msg`).
pub fn isPanicBuiltinName(name: []const u8) bool {
    return std.mem.eql(u8, name, "panic") or std.mem.eql(u8, name, "panic_msg");
}

/// Shared pure bare `panic` / `panic_msg` builtin call recognition.
pub fn isPanicBuiltinCall(call: ast.CallExpr) bool {
    return call.associated_target == null and isPanicBuiltinName(call.func_name);
}

/// Shared pure Option `None` identifier fact.
pub fn isOptionNoneName(name: []const u8) bool {
    return std.mem.eql(u8, name, "None");
}

/// Shared pure Option `Some(...)` constructor call recognition.
pub fn isOptionSomeCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "Some");
}

/// Shared pure Result `Ok(...)` constructor call recognition.
pub fn isResultOkCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "Ok");
}

/// Shared pure Result `Err(...)` constructor call recognition.
pub fn isResultErrCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "Err");
}

/// Shared pure Result constructor call recognition (`Ok` / `Err`).
pub fn isResultConstructorCall(call: ast.CallExpr) bool {
    return isResultOkCall(call) or isResultErrCall(call);
}

/// Shared pure bare `ptr__null` / `std__ptr__null` builtin name fact.
pub fn isPtrNullBuiltinName(name: []const u8) bool {
    return std.mem.eql(u8, name, "std__ptr__null") or std.mem.eql(u8, name, "ptr__null");
}

/// Shared pure bare `ptr__read_volatile` / `std__ptr__read_volatile` builtin name fact.
pub fn isPtrReadVolatileBuiltinName(name: []const u8) bool {
    return std.mem.eql(u8, name, "std__ptr__read_volatile") or std.mem.eql(u8, name, "ptr__read_volatile");
}

/// Shared pure recognition of bare ptr-null builtins.
pub fn isPtrNullCall(call: ast.CallExpr) bool {
    return isPtrNullBuiltinName(call.func_name);
}

/// Shared pure recognition of bare ptr-read-volatile builtins.
pub fn isPtrReadVolatileCall(call: ast.CallExpr) bool {
    return isPtrReadVolatileBuiltinName(call.func_name);
}

/// Shared pure fact: call needs std ptr macros (null / read_volatile surfaces).
pub fn callNeedsPtrMacros(call: ast.CallExpr) bool {
    if (isPtrNullCall(call) or isPtrReadVolatileCall(call)) return true;
    if (call.associated_target) |target| {
        const is_ptr_target = std.mem.eql(u8, target, "std__ptr") or std.mem.eql(u8, target, "ptr");
        if (is_ptr_target and (std.mem.eql(u8, call.func_name, "null") or std.mem.eql(u8, call.func_name, "read_volatile"))) return true;
    }
    return false;
}

/// Shared pure `println` call-name fact.
pub fn isPrintlnCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "println");
}

/// Shared pure `hash` call-name fact.
pub fn isHashCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "hash");
}

/// Shared pure `debug` call-name fact.
pub fn isDebugCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "debug");
}

/// Shared pure `str_eq` call-name fact.
pub fn isStrEqCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "str_eq");
}

/// Shared pure bare `vec(...)` constructor call recognition.
pub fn isBareVecCall(call: ast.CallExpr) bool {
    return call.associated_target == null and std.mem.eql(u8, call.func_name, "vec");
}

/// Shared pure `len` call-name fact.
pub fn isLenCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "len");
}

/// Shared pure bare unary `len(x)` call recognition.
pub fn isBareLenUnaryCall(call: ast.CallExpr) bool {
    return call.associated_target == null and isLenCall(call) and call.args.len == 1;
}

/// Shared pure `push` call-name fact.
pub fn isPushCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "push");
}

/// Shared pure bare binary `push(vec, value)` call recognition.
pub fn isBarePushBinaryCall(call: ast.CallExpr) bool {
    return call.associated_target == null and isPushCall(call) and call.args.len == 2;
}

/// Shared pure `pop` call-name fact.
pub fn isPopCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "pop");
}

/// Shared pure bare unary `pop(vec)` call recognition.
pub fn isBarePopUnaryCall(call: ast.CallExpr) bool {
    return call.associated_target == null and isPopCall(call) and call.args.len == 1;
}

/// Shared pure `join` call-name fact.
pub fn isJoinCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "join");
}

/// Shared pure bare unary `join(handle)` call recognition.
pub fn isBareJoinUnaryCall(call: ast.CallExpr) bool {
    return call.associated_target == null and isJoinCall(call) and call.args.len == 1;
}

/// Shared pure `unwrap` call-name fact.
pub fn isUnwrapCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "unwrap");
}

/// Shared pure bare unary `unwrap(x)` call recognition.
pub fn isBareUnwrapUnaryCall(call: ast.CallExpr) bool {
    return call.associated_target == null and isUnwrapCall(call) and call.args.len == 1;
}

/// Shared pure `clone` call-name fact.
pub fn isCloneCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "clone");
}

/// Shared pure unary `clone(x)` call recognition.
pub fn isCloneUnaryCall(call: ast.CallExpr) bool {
    return isCloneCall(call) and call.args.len == 1;
}

/// Shared pure entrypoint name fact.
pub fn isMainName(name: []const u8) bool {
    return std.mem.eql(u8, name, "main");
}

/// Shared pure `is_some` call-name fact.
pub fn isIsSomeCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "is_some");
}

/// Shared pure `is_none` call-name fact.
pub fn isIsNoneCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "is_none");
}

/// Shared pure Option query method name fact (`is_some` / `is_none`).
pub fn isOptionQueryCall(call: ast.CallExpr) bool {
    return isIsSomeCall(call) or isIsNoneCall(call);
}

/// Shared pure `is_ok` call-name fact.
pub fn isIsOkCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "is_ok");
}

/// Shared pure `is_err` call-name fact.
pub fn isIsErrCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "is_err");
}

/// Shared pure Result query method name fact (`is_ok` / `is_err`).
pub fn isResultQueryCall(call: ast.CallExpr) bool {
    return isIsOkCall(call) or isIsErrCall(call);
}

/// Shared pure `unwrap_or` call-name fact.
pub fn isUnwrapOrCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "unwrap_or");
}

/// Shared pure `unwrap_or_else` call-name fact.
pub fn isUnwrapOrElseCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "unwrap_or_else");
}

/// Shared pure `unwrap_or_default` call-name fact.
pub fn isUnwrapOrDefaultCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "unwrap_or_default");
}

/// Shared pure `and_then` call-name fact.
pub fn isAndThenCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "and_then");
}

/// Shared pure `copied` call-name fact.
pub fn isCopiedCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "copied");
}

/// Shared pure `map` call-name fact.
pub fn isMapCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "map");
}

/// Shared pure `get` call-name fact.
pub fn isGetCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "get");
}

/// Shared pure `insert` call-name fact.
pub fn isInsertCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "insert");
}

/// Shared pure `contains` call-name fact.
pub fn isContainsCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "contains");
}

/// Shared pure `load` call-name fact.
pub fn isLoadCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "load");
}

/// Shared pure `store` call-name fact.
pub fn isStoreCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "store");
}

/// Shared pure `fetch_add` call-name fact.
pub fn isFetchAddCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "fetch_add");
}

/// Shared pure `compare_exchange` call-name fact.
pub fn isCompareExchangeCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "compare_exchange");
}

/// Shared pure `as_ptr` call-name fact.
pub fn isAsPtrCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "as_ptr");
}

/// Shared pure `send` call-name fact.
pub fn isSendCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "send");
}

/// Shared pure `recv` call-name fact.
pub fn isRecvCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "recv");
}

/// Shared pure `set` call-name fact.
pub fn isSetCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "set");
}

/// Shared pure `remove` call-name fact.
pub fn isRemoveCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "remove");
}

/// Shared pure `push_back` call-name fact.
pub fn isPushBackCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "push_back");
}

/// Shared pure `pop_front` call-name fact.
pub fn isPopFrontCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "pop_front");
}

/// Shared pure `metadata` call-name fact.
pub fn isMetadataCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "metadata");
}

/// Shared pure `path::metadata` associated call recognition.
pub fn isPathMetadataCall(call: ast.CallExpr) bool {
    return call.associated_target != null and
        std.mem.eql(u8, call.associated_target.?, "path") and
        isMetadataCall(call);
}

/// Shared pure `new` call-name fact.
pub fn isNewCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "new");
}

/// Shared pure `into_raw` call-name fact.
pub fn isIntoRawCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "into_raw");
}

/// Shared pure `from_raw` call-name fact.
pub fn isFromRawCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "from_raw");
}

/// Shared pure `into_inner` call-name fact.
pub fn isIntoInnerCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "into_inner");
}

/// Shared pure `iter` call-name fact.
pub fn isIterCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "iter");
}

/// Shared pure `into_iter` call-name fact.
pub fn isIntoIterCall(call: ast.CallExpr) bool {
    return std.mem.eql(u8, call.func_name, "into_iter");
}

/// Shared pure iterator method name fact (`iter` / `into_iter`).
pub fn isIterOrIntoIterCall(call: ast.CallExpr) bool {
    return isIterCall(call) or isIntoIterCall(call);
}

/// Shared pure `mem::forget` associated call recognition.
pub fn isMemForgetCall(call: ast.CallExpr) bool {
    return call.associated_target != null and
        std.mem.eql(u8, call.associated_target.?, "mem") and
        std.mem.eql(u8, call.func_name, "forget");
}

/// Shared pure `mpsc::channel` associated call recognition.
pub fn isMpscChannelCall(call: ast.CallExpr) bool {
    return call.associated_target != null and
        std.mem.eql(u8, call.associated_target.?, "mpsc") and
        std.mem.eql(u8, call.func_name, "channel");
}

/// Shared pure `ManuallyDrop::new` associated call recognition.
pub fn isManuallyDropNewCall(call: ast.CallExpr) bool {
    return call.associated_target != null and
        std.mem.eql(u8, call.associated_target.?, "ManuallyDrop") and
        isNewCall(call);
}

/// Shared pure `ManuallyDrop::into_inner` associated call recognition.
pub fn isManuallyDropIntoInnerCall(call: ast.CallExpr) bool {
    return call.associated_target != null and
        std.mem.eql(u8, call.associated_target.?, "ManuallyDrop") and
        isIntoInnerCall(call);
}

/// Shared pure `Box::new` associated call recognition.
pub fn isBoxNewCall(call: ast.CallExpr) bool {
    return call.associated_target != null and
        isBoxTypeName(call.associated_target.?) and
        isNewCall(call);
}

/// Shared pure `Box::into_raw` associated call recognition.
pub fn isBoxIntoRawCall(call: ast.CallExpr) bool {
    return call.associated_target != null and
        isBoxTypeName(call.associated_target.?) and
        isIntoRawCall(call);
}

/// Shared pure `Box::from_raw` associated call recognition.
pub fn isBoxFromRawCall(call: ast.CallExpr) bool {
    return call.associated_target != null and
        isBoxTypeName(call.associated_target.?) and
        isFromRawCall(call);
}

/// Shared pure `Rc::new` associated call recognition.
pub fn isRcNewCall(call: ast.CallExpr) bool {
    return call.associated_target != null and
        isRcTypeName(call.associated_target.?) and
        isNewCall(call);
}

/// Shared pure `Arc::new` associated call recognition.
pub fn isArcNewCall(call: ast.CallExpr) bool {
    return call.associated_target != null and
        isArcTypeName(call.associated_target.?) and
        isNewCall(call);
}

fn userDefinedGenericInner(ty: *const ast.Type, name: []const u8) ?*ast.Type {
    const curr = peelBorrowPointerType(ty);
    if (curr.* != .user_defined) return null;
    if (!std.mem.eql(u8, curr.user_defined.name, name) or curr.user_defined.generics.len != 1) return null;
    return curr.user_defined.generics[0];
}

pub fn vecElementType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Vec");
}

pub fn vecDequeElementType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "VecDeque");
}

pub const MapTypes = struct {
    key: *ast.Type,
    value: *ast.Type,
};

fn userDefinedMapTypes(ty: *const ast.Type, name: []const u8) ?MapTypes {
    const curr = peelBorrowPointerType(ty);
    if (curr.* != .user_defined) return null;
    if (!std.mem.eql(u8, curr.user_defined.name, name) or curr.user_defined.generics.len != 2) return null;
    return .{ .key = curr.user_defined.generics[0], .value = curr.user_defined.generics[1] };
}

pub fn hashMapTypes(ty: *const ast.Type) ?MapTypes {
    return userDefinedMapTypes(ty, "HashMap");
}

pub fn btreeMapTypes(ty: *const ast.Type) ?MapTypes {
    return userDefinedMapTypes(ty, "BTreeMap");
}

pub fn hashSetElementType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "HashSet");
}

pub fn btreeSetElementType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "BTreeSet");
}

pub fn sliceElementType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Slice");
}

pub fn arrayType(ty: *const ast.Type) ?ast.ArrayType {
    const curr = peelBorrowPointerType(ty);
    if (curr.* != .array) return null;
    return curr.array;
}

pub fn taskInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Task");
}

pub fn executorTaskBufferPlan(ty: *const ast.Type) ?ExecutorTaskBufferPlan {
    const curr = peelBorrowPointerType(ty);
    if (curr.* == .array) {
        const arr = curr.array;
        const inner = taskInnerType(arr.elem) orelse return null;
        return .{ .kind = .fixed_array, .inner = inner, .fixed_len = arr.len };
    }
    const elem = vecElementType(curr) orelse return null;
    const inner = taskInnerType(elem) orelse return null;
    return .{ .kind = .vec, .inner = inner };
}

pub fn vecElementSlotSize(ty: *const ast.Type) usize {
    return @max(abiTypeSize(ty), 8);
}

pub fn boxInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Box");
}

pub fn rcInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Rc");
}

pub fn arcInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Arc");
}

pub fn manuallyDropInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "ManuallyDrop");
}

pub fn joinHandleInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "JoinHandle");
}

pub fn senderInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Sender");
}

pub fn receiverInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Receiver");
}

pub fn atomicPtrInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "AtomicPtr");
}

fn isUserDefinedNamed(ty: *const ast.Type, name: []const u8) bool {
    const curr = peelBorrowPointerType(ty);
    if (curr.* != .user_defined) return false;
    return std.mem.eql(u8, curr.user_defined.name, name) and curr.user_defined.generics.len == 0;
}

pub fn isFileType(ty: *const ast.Type) bool {
    return isUserDefinedNamed(ty, "File");
}

pub fn isMetadataType(ty: *const ast.Type) bool {
    return isUserDefinedNamed(ty, "Metadata");
}

pub fn isStringType(ty: *const ast.Type) bool {
    return isUserDefinedNamed(ty, "String");
}

pub fn isOrderingType(ty: *const ast.Type) bool {
    return isUserDefinedNamed(ty, "Ordering");
}

pub fn executorInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Executor");
}

pub fn pollInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Poll");
}

pub fn futurePairInnerTypes(ty: *const ast.Type) ?MapTypes {
    return userDefinedMapTypes(ty, "FuturePair");
}

pub fn futureEitherInnerTypes(ty: *const ast.Type) ?MapTypes {
    return userDefinedMapTypes(ty, "FutureEither");
}

pub fn unwrapPointerLikeType(ty: *ast.Type) *ast.Type {
    return @constCast(peelBorrowPointerType(ty));
}

pub fn isAtomicI32Type(ty: *const ast.Type) bool {
    return isUserDefinedNamed(ty, "AtomicI32");
}

pub fn isAtomicUsizeType(ty: *const ast.Type) bool {
    return isUserDefinedNamed(ty, "AtomicUsize");
}

pub fn atomicOrderingToken(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "Ordering::SeqCst")) return "seq_cst";
    if (std.mem.eql(u8, name, "Ordering::Acquire")) return "acquire";
    if (std.mem.eql(u8, name, "Ordering::Release")) return "release";
    if (std.mem.eql(u8, name, "Ordering::Relaxed")) return "relaxed";
    if (std.mem.eql(u8, name, "Ordering::AcqRel")) return "acq_rel";
    return null;
}

pub fn refCellInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "RefCell");
}

pub fn cellInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Cell");
}

pub fn mutexInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Mutex");
}

pub fn mutexGuardInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "MutexGuard");
}

pub fn rwLockInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "RwLock");
}

pub fn rwLockReadGuardInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "RwLockReadGuard");
}

pub fn rwLockWriteGuardInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "RwLockWriteGuard");
}

/// Std container/owner types that are never treated as Copy at the call-arg ABI
/// layer, even when nested inside user structs. Shared by SA-text and direct SAB.
pub fn userDefinedStdOwnerIsNonCopy(ty: *const ast.Type) bool {
    if (ty.* != .user_defined) return false;
    const name = ty.user_defined.name;
    return std.mem.eql(u8, name, "Vec") or
        std.mem.eql(u8, name, "VecDeque") or
        std.mem.eql(u8, name, "String") or
        std.mem.eql(u8, name, "Box") or
        std.mem.eql(u8, name, "Rc") or
        std.mem.eql(u8, name, "Arc") or
        std.mem.eql(u8, name, "HashMap") or
        std.mem.eql(u8, name, "BTreeMap") or
        std.mem.eql(u8, name, "HashSet") or
        std.mem.eql(u8, name, "BTreeSet") or
        std.mem.eql(u8, name, "RefCell") or
        std.mem.eql(u8, name, "Mutex") or
        std.mem.eql(u8, name, "RwLock") or
        std.mem.eql(u8, name, "JoinHandle");
}

/// Names that keep their generic user-defined form under monomorphization
/// rather than being specialized as struct/enum templates.
pub fn keepsGenericUserDefinedName(name: []const u8) bool {
    // Std containers / smart pointers / wrappers keep generic user-defined form
    // rather than monomorphizing as struct/enum templates.
    return std.mem.eql(u8, name, "Box") or
        std.mem.eql(u8, name, "Rc") or
        std.mem.eql(u8, name, "Arc") or
        std.mem.eql(u8, name, "Vec") or
        std.mem.eql(u8, name, "VecDeque") or
        std.mem.eql(u8, name, "HashMap") or
        std.mem.eql(u8, name, "BTreeMap") or
        std.mem.eql(u8, name, "HashSet") or
        std.mem.eql(u8, name, "BTreeSet") or
        std.mem.eql(u8, name, "Option") or
        std.mem.eql(u8, name, "Result") or
        std.mem.eql(u8, name, "String") or
        std.mem.eql(u8, name, "Cell") or
        std.mem.eql(u8, name, "RefCell") or
        std.mem.eql(u8, name, "Mutex") or
        std.mem.eql(u8, name, "RwLock") or
        std.mem.eql(u8, name, "JoinHandle") or
        std.mem.eql(u8, name, "Sender") or
        std.mem.eql(u8, name, "Receiver") or
        std.mem.eql(u8, name, "Task") or
        std.mem.eql(u8, name, "Future") or
        std.mem.eql(u8, name, "Poll") or
        std.mem.eql(u8, name, "Executor") or
        std.mem.eql(u8, name, "ManuallyDrop") or
        std.mem.eql(u8, name, "AtomicPtr") or
        std.mem.eql(u8, name, "FuturePair") or
        std.mem.eql(u8, name, "FutureEither") or
        std.mem.startsWith(u8, name, "__dyn_");
}

pub fn smartPointerType(ty: *const ast.Type) ?SmartPointerType {
    if (boxInnerType(ty)) |inner| return .{ .kind = .box, .inner = inner };
    if (rcInnerType(ty)) |inner| return .{ .kind = .rc, .inner = inner };
    if (arcInnerType(ty)) |inner| return .{ .kind = .arc, .inner = inner };
    if (refCellInnerType(ty)) |inner| return .{ .kind = .refcell, .inner = inner };
    return null;
}

pub fn isBoxTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Box");
}

pub fn isRcTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Rc");
}

pub fn isArcTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Arc");
}

pub fn isSmartPointerTypeName(name: []const u8) bool {
    return isBoxTypeName(name) or isRcTypeName(name) or isArcTypeName(name);
}

pub fn smartPointerStdImportPath(name: []const u8) ?[]const u8 {
    if (isBoxTypeName(name)) return "sa_std/box.sa";
    if (isRcTypeName(name)) return "sa_std/rc.sa";
    if (isArcTypeName(name)) return "sa_std/arc.sa";
    return null;
}

pub fn smartPointerDerefType(ty: *const ast.Type) ?SmartPointerType {
    const smart = smartPointerType(ty) orelse return null;
    return switch (smart.kind) {
        .box, .rc, .arc => smart,
        .refcell => null,
    };
}

pub fn smartPointerReceiverNeedsLoad(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .borrow, .pointer => smartPointerDerefType(ty) != null,
        else => false,
    };
}

pub fn smartPointerDerefNeedsValueSlot(inner_ty: *const ast.Type) bool {
    return smartPointerDerefType(inner_ty) != null;
}

pub fn smartPointerDerefIsDynBox(ty: *const ast.Type) bool {
    const inner = boxInnerType(ty) orelse return false;
    return dynTraitName(inner) != null;
}

pub const SmartPointerAddressAction = enum {
    unsupported,
    dyn_box_identity,
    as_ptr_slot,
    as_ptr_take_pointer_backed_value,

    pub fn isDynBoxIdentity(self: SmartPointerAddressAction) bool {
        return self == .dyn_box_identity;
    }

    pub fn isAsPtrTakePointerBackedValue(self: SmartPointerAddressAction) bool {
        return self == .as_ptr_take_pointer_backed_value;
    }
};

pub const SmartPointerValueSlotAction = enum {
    unsupported,
    as_ptr_slot,

    pub fn isAsPtrSlot(self: SmartPointerValueSlotAction) bool {
        return self == .as_ptr_slot;
    }
};

pub const SmartPointerGetAction = enum {
    unsupported,
    dyn_box_identity,
    get_value,

    pub fn isGetValue(self: SmartPointerGetAction) bool {
        return self == .get_value;
    }
};

pub fn planSmartPointerAddressAction(source_ty: *const ast.Type) SmartPointerAddressAction {
    const smart = smartPointerDerefType(source_ty) orelse return .unsupported;
    if (smart.kind == .box and smartPointerDerefIsDynBox(source_ty)) return .dyn_box_identity;
    if (smartPointerDerefLoadsPointerBackedValue(smart.inner)) return .as_ptr_take_pointer_backed_value;
    return .as_ptr_slot;
}

pub fn planSmartPointerValueSlotAction(source_ty: *const ast.Type) SmartPointerValueSlotAction {
    const smart = smartPointerDerefType(source_ty) orelse return .unsupported;
    if (smartPointerDerefNeedsValueSlot(smart.inner)) return .as_ptr_slot;
    return .unsupported;
}

pub fn planSmartPointerGetAction(source_ty: *const ast.Type) SmartPointerGetAction {
    const smart = smartPointerDerefType(source_ty) orelse return .unsupported;
    if (smart.kind == .box and smartPointerDerefIsDynBox(source_ty)) return .dyn_box_identity;
    return .get_value;
}

pub const PrintPrimitiveFormat = enum {
    signed_int,
    unsigned_int,
    float,
    boolean,
};

pub const PrintlnArgPlan = union(enum) {
    format_string,
    string_like,
    borrowed_primitive: *const ast.Type,
    boxed_primitive: *const ast.Type,
    primitive: PrintPrimitiveFormat,
    unsupported,

    pub fn isFormatString(self: PrintlnArgPlan) bool {
        return self == .format_string;
    }

    pub fn isStringLike(self: PrintlnArgPlan) bool {
        return self == .string_like;
    }

    pub fn borrowedPrimitive(self: PrintlnArgPlan) ?*const ast.Type {
        return switch (self) {
            .borrowed_primitive => |inner| inner,
            else => null,
        };
    }

    pub fn boxedPrimitive(self: PrintlnArgPlan) ?*const ast.Type {
        return switch (self) {
            .boxed_primitive => |inner| inner,
            else => null,
        };
    }

    pub fn primitiveFormat(self: PrintlnArgPlan) ?PrintPrimitiveFormat {
        return switch (self) {
            .primitive => |format| format,
            else => null,
        };
    }
};

pub fn borrowedPrimitiveType(ty: *const ast.Type) ?*const ast.Type {
    return switch (ty.*) {
        .borrow => |inner| if (inner.* == .primitive) inner else null,
        .pointer => |inner| if (inner.* == .primitive) inner else null,
        else => null,
    };
}

pub fn isStringLikeType(ty: *const ast.Type) bool {
    const curr = peelBorrowPointerType(ty);
    return switch (curr.*) {
        .primitive => |p| p == .raw_ptr,
        .array => true,
        .user_defined => |ud| std.mem.eql(u8, ud.name, "String"),
        else => false,
    };
}

pub fn isFormatStringType(ty: *const ast.Type) bool {
    const curr = peelBorrowPointerType(ty);
    if (curr.* != .user_defined) return false;
    return std.mem.eql(u8, curr.user_defined.name, "String");
}

pub fn printPrimitiveFormat(ty: *const ast.Type) ?PrintPrimitiveFormat {
    return switch (ty.*) {
        .primitive => |p| switch (p) {
            .i8, .i16, .i32, .i64, .isize, .integer => .signed_int,
            .u8, .u16, .u32, .u64, .usize => .unsigned_int,
            .f32, .f64, .float => .float,
            .boolean => .boolean,
            else => null,
        },
        else => null,
    };
}

pub fn planPrintlnArg(ty: ?*const ast.Type) PrintlnArgPlan {
    const arg_ty = ty orelse return .unsupported;
    if (isFormatStringType(arg_ty)) return .format_string;
    if (isStringLikeType(arg_ty)) return .string_like;
    if (borrowedPrimitiveType(arg_ty)) |inner| return .{ .borrowed_primitive = inner };
    if (boxInnerType(arg_ty)) |inner| {
        if (printPrimitiveFormat(inner) != null) return .{ .boxed_primitive = inner };
    }
    if (printPrimitiveFormat(arg_ty)) |format| return .{ .primitive = format };
    return .unsupported;
}

/// Returns true when an associated-call rule (e.g. `Rc::clone`, `Arc::clone`)
/// expects its `value` argument to be the underlying smart-pointer value rather
/// than a `borrow` handle. The SA-text emitter treats `&rc1` as a transparent
/// register copy, but the SAB emitter would otherwise emit a real `borrow`
/// instruction that produces a separate handle and breaks the `RC_CLONE_OUT`
/// (or `ARC_CLONE_OUT`) macro expansion. Both emitters share this contract via
/// this helper so they materialize the receiver consistently.
pub fn associatedRuleNeedsUnderlyingSmartPointer(type_name: []const u8, member_name: []const u8) bool {
    if (!std.mem.eql(u8, member_name, "clone")) return false;
    return std.mem.eql(u8, type_name, "Rc") or std.mem.eql(u8, type_name, "Arc");
}

pub fn smartPointerDerefLoadsPointerBackedValue(inner_ty: *const ast.Type) bool {
    return switch (inner_ty.*) {
        .user_defined => smartPointerDerefType(inner_ty) == null,
        .tuple, .array => true,
        else => false,
    };
}

pub fn refCellPayloadIsPointer(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .primitive => |p| p == .raw_ptr,
        else => true,
    };
}

pub fn planRefCellBorrowValueKind(inner: *const ast.Type) RefCellBorrowValueKind {
    if (smartPointerDerefType(inner) != null) return .smart_pointer_payload;
    if (refCellPayloadIsPointer(inner)) return .pointer_payload;
    return .scalar_slot;
}

pub fn planRefCellBorrowCall(call: ast.CallExpr, receiver_ty: *const ast.Type) ?RefCellBorrowPlan {
    if (call.args.len != 1) return null;
    const inner = refCellInnerType(receiver_ty) orelse return null;
    const value_kind = planRefCellBorrowValueKind(inner);
    if (std.mem.eql(u8, call.func_name, "borrow")) return .{ .kind = .shared, .inner = inner, .value_kind = value_kind };
    if (std.mem.eql(u8, call.func_name, "borrow_mut")) return .{ .kind = .mutable, .inner = inner, .value_kind = value_kind };
    return null;
}

fn ifLetChainNeedsRefCellRuntime(tc: *type_checker.TypeChecker, chain: []const ast.IfLetCond) bool {
    for (chain) |cond| {
        if (exprNeedsRefCellRuntime(tc, cond.value)) return true;
    }
    return false;
}

pub fn exprNeedsRefCellRuntime(tc: *type_checker.TypeChecker, expr: *const ast.Node) bool {
    if (tc.expr_types.get(expr)) |ty| {
        if (refCellInnerType(ty) != null) return true;
    }
    return switch (expr.*) {
        .call_expr => |call| blk: {
            if (call.associated_target) |target| {
                if (std.mem.eql(u8, target, "RefCell")) break :blk true;
            }
            if (call.args.len > 0) {
                if (tc.expr_types.get(call.args[0])) |recv_ty| {
                    if (refCellInnerType(recv_ty) != null) break :blk true;
                }
            }
            for (call.args) |arg| if (exprNeedsRefCellRuntime(tc, arg)) break :blk true;
            break :blk false;
        },
        .binary_expr => |bin| exprNeedsRefCellRuntime(tc, bin.left) or exprNeedsRefCellRuntime(tc, bin.right),
        .borrow_expr => |borrow| exprNeedsRefCellRuntime(tc, borrow.expr),
        .move_expr => |move| exprNeedsRefCellRuntime(tc, move.expr),
        .deref_expr => |deref| exprNeedsRefCellRuntime(tc, deref.expr),
        .field_expr => |field| exprNeedsRefCellRuntime(tc, field.expr),
        .index_expr => |idx| exprNeedsRefCellRuntime(tc, idx.target) or exprNeedsRefCellRuntime(tc, idx.index),
        .slice_expr => |slc| exprNeedsRefCellRuntime(tc, slc.target) or exprNeedsRefCellRuntime(tc, slc.start) or exprNeedsRefCellRuntime(tc, slc.end),
        .closure_literal => |lit| exprNeedsRefCellRuntime(tc, lit.body),
        .await_expr => |aw| exprNeedsRefCellRuntime(tc, aw.expr),
        .try_expr => |trye| exprNeedsRefCellRuntime(tc, trye.expr),
        .struct_literal => |lit| blk: {
            for (lit.fields) |field| if (exprNeedsRefCellRuntime(tc, field.value)) break :blk true;
            break :blk false;
        },
        .enum_literal => |lit| blk: {
            for (lit.fields) |field| if (exprNeedsRefCellRuntime(tc, field.value)) break :blk true;
            break :blk false;
        },
        .tuple_literal => |lit| blk: {
            for (lit.elements) |elem| if (exprNeedsRefCellRuntime(tc, elem)) break :blk true;
            break :blk false;
        },
        .array_literal => |lit| blk: {
            for (lit.elements) |elem| if (exprNeedsRefCellRuntime(tc, elem)) break :blk true;
            break :blk false;
        },
        .if_expr => |ife| exprNeedsRefCellRuntime(tc, ife.cond) or (if (ife.let_chain) |chain| ifLetChainNeedsRefCellRuntime(tc, chain) else false) or blockNeedsRefCellRuntime(tc, ife.then_block) or if (ife.else_block) |eb| blockNeedsRefCellRuntime(tc, eb) else false,
        .switch_expr => |swe| blk: {
            if (exprNeedsRefCellRuntime(tc, swe.val)) break :blk true;
            for (swe.cases) |case| if (exprNeedsRefCellRuntime(tc, case.pattern) or blockNeedsRefCellRuntime(tc, case.body)) break :blk true;
            break :blk false;
        },
        .match_expr => |mat| blk: {
            if (exprNeedsRefCellRuntime(tc, mat.val)) break :blk true;
            for (mat.cases) |case| {
                if (case.guard) |guard| if (exprNeedsRefCellRuntime(tc, guard)) break :blk true;
                if (blockNeedsRefCellRuntime(tc, case.body)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn blockNeedsRefCellRuntime(tc: *type_checker.TypeChecker, block: []const *ast.Node) bool {
    for (block) |stmt| {
        switch (stmt.*) {
            .let_stmt => |let| if (exprNeedsRefCellRuntime(tc, let.value)) return true,
            .let_else_stmt => |let| if (exprNeedsRefCellRuntime(tc, let.value) or blockNeedsRefCellRuntime(tc, let.else_block)) return true,
            .let_destructure_stmt => |let| if (exprNeedsRefCellRuntime(tc, let.value)) return true,
            .const_stmt => |c| if (exprNeedsRefCellRuntime(tc, c.value)) return true,
            .assign_stmt => |assign| if (exprNeedsRefCellRuntime(tc, assign.target) or exprNeedsRefCellRuntime(tc, assign.value)) return true,
            .expr_stmt => |expr| if (exprNeedsRefCellRuntime(tc, expr)) return true,
            .return_stmt => |ret| if (ret.value) |value| if (exprNeedsRefCellRuntime(tc, value)) return true,
            .for_stmt => |f| if (exprNeedsRefCellRuntime(tc, f.start) or (if (f.end) |end_expr| exprNeedsRefCellRuntime(tc, end_expr) else false) or blockNeedsRefCellRuntime(tc, f.body)) return true,
            .while_stmt => |w| if (exprNeedsRefCellRuntime(tc, w.cond) or blockNeedsRefCellRuntime(tc, w.body)) return true,
            .block_stmt => |blk| if (blockNeedsRefCellRuntime(tc, blk.body)) return true,
            else => {},
        }
    }
    return false;
}

pub fn programNeedsRefCellRuntime(tc: *type_checker.TypeChecker, program: *const ast.Node) bool {
    for (program.program.decls) |decl| {
        switch (decl.*) {
            .func_decl => |f| if (blockNeedsRefCellRuntime(tc, f.body)) return true,
            .impl_decl => |i| for (i.methods) |method| {
                if (method.* == .func_decl and blockNeedsRefCellRuntime(tc, method.func_decl.body)) return true;
            },
            .test_decl => |t| if (blockNeedsRefCellRuntime(tc, t.body)) return true,
            else => {},
        }
    }
    return false;
}

fn closureLiteralArity(expr: *const ast.Node) ?usize {
    return switch (expr.*) {
        .closure_literal => |lit| lit.params.len,
        .move_expr => |move| closureLiteralArity(move.expr),
        else => null,
    };
}

pub fn planOptionClosureCall(call: ast.CallExpr, receiver_ty: *const ast.Type) ?OptionClosureCallPlan {
    if (call.args.len != 2) return null;
    if (optionInnerType(receiver_ty) == null) return null;
    const arity = closureLiteralArity(call.args[1]) orelse return null;
    if (isMapCall(call)) {
        if (arity != 1) return null;
        return .{ .kind = .map, .closure_arity = arity };
    }
    if (isAndThenCall(call)) {
        if (arity != 1) return null;
        return .{ .kind = .and_then, .closure_arity = arity };
    }
    if (isUnwrapOrElseCall(call)) {
        if (arity != 0) return null;
        return .{ .kind = .unwrap_or_else, .closure_arity = arity };
    }
    return null;
}

pub fn structAbiSize(decl: *const ast.StructDecl) usize {
    if (decl.is_opaque) return 1;
    if (decl.is_union) {
        var max_size: usize = 0;
        for (decl.fields) |field| max_size = @max(max_size, abiTypeSize(field.ty));
        return @max(max_size, 1);
    }
    var offset: usize = 0;
    for (decl.fields) |field| {
        const size = structFieldStorageSize(field.ty);
        offset = alignAggregateOffset(offset, structFieldAlignmentSize(field.ty));
        offset += size;
    }
    return @max(offset, 1);
}

pub fn structFieldLayout(decl: *const ast.StructDecl, name: []const u8) ?AbiFieldLayout {
    if (decl.is_union) {
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                return .{ .offset = 0, .size = abiTypeSize(field.ty), .ty = field.ty };
            }
        }
        return null;
    }
    var offset: usize = 0;
    for (decl.fields) |field| {
        const size = structFieldStorageSize(field.ty);
        offset = alignAggregateOffset(offset, structFieldAlignmentSize(field.ty));
        if (std.mem.eql(u8, field.name, name)) {
            return .{ .offset = offset, .size = size, .ty = field.ty };
        }
        offset += size;
    }
    return null;
}

/// Byte offset of an enum's payload region. The tag occupies the first 8
/// bytes (`i64`), so every variant's fields start at offset 8. Shared by both
/// emitters so SA-text and direct SAB agree on enum tag/payload layout.
pub const enum_tag_offset: usize = 0;
pub const enum_payload_offset: usize = 8;

/// Index (discriminant tag) of an enum variant by name.
pub fn enumVariantIndex(decl: *const ast.EnumDecl, name: []const u8) ?usize {
    for (decl.variants, 0..) |variant, i| {
        if (std.mem.eql(u8, variant.name, name)) return i;
    }
    return null;
}

/// The full enum variant record by name.
pub fn enumVariant(decl: *const ast.EnumDecl, name: []const u8) ?ast.EnumVariant {
    for (decl.variants) |variant| {
        if (std.mem.eql(u8, variant.name, name)) return variant;
    }
    return null;
}

/// Layout of a named field inside an enum variant's payload. Payload fields are
/// laid out starting at `enum_payload_offset`, using the same ABI size/align
/// rules as struct/tuple aggregates.
pub fn enumFieldLayout(variant: ast.EnumVariant, name: []const u8) ?AbiFieldLayout {
    var offset: usize = enum_payload_offset;
    for (variant.fields) |field| {
        const size = abiTypeSize(field.ty);
        offset = alignAggregateOffset(offset, size);
        if (std.mem.eql(u8, field.name, name)) {
            return .{ .offset = offset, .size = size, .ty = field.ty };
        }
        offset += size;
    }
    return null;
}

/// Total ABI size of an enum: the tag word plus the largest variant payload.
pub fn enumAbiSize(decl: *const ast.EnumDecl) usize {
    var max_payload: usize = 0;
    for (decl.variants) |variant| {
        var offset: usize = enum_payload_offset;
        for (variant.fields) |field| {
            const size = abiTypeSize(field.ty);
            offset = alignAggregateOffset(offset, size);
            offset += size;
        }
        max_payload = @max(max_payload, offset - enum_payload_offset);
    }
    return @max(enum_payload_offset + max_payload, enum_payload_offset);
}

/// The explicit value node for a named field in an enum literal, if present.
pub fn enumLiteralFieldValue(lit: *const ast.EnumLiteral, name: []const u8) ?*ast.Node {
    for (lit.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.value;
    }
    return null;
}

/// `Ordering` discriminant values (`struct Ordering { value: i64 }`), shared so
/// SA-text and direct SAB emit identical `<=>` results. These mirror the
/// `CMP_ORDERING_*` constants in `sa_std/core/cmp.sa`.
pub const ordering_less: i64 = -1;
pub const ordering_equal: i64 = 0;
pub const ordering_greater: i64 = 1;

pub fn isPrimitiveType(ty: *const ast.Type, primitive: ast.Primitive) bool {
    return ty.* == .primitive and ty.primitive == primitive;
}

pub fn isIntegerPrimitive(p: ast.Primitive) bool {
    return switch (p) {
        .i8, .i16, .i32, .i64, .isize, .u8, .u16, .u32, .u64, .usize, .integer => true,
        else => false,
    };
}

pub fn isFloatPrimitive(p: ast.Primitive) bool {
    return switch (p) {
        .f32, .f64, .float => true,
        else => false,
    };
}

pub fn isFloatType(ty: *const ast.Type) bool {
    return ty.* == .primitive and isFloatPrimitive(ty.primitive);
}

pub fn isUnsignedIntegerType(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .primitive => |p| switch (p) {
            .u8, .u16, .u32, .u64, .usize => true,
            else => false,
        },
        else => false,
    };
}

pub fn isAnyIntegerType(ty: *const ast.Type) bool {
    return ty.* == .primitive and isIntegerPrimitive(ty.primitive);
}

pub fn isAnyFloatType(ty: *const ast.Type) bool {
    return isFloatType(ty);
}

pub fn isI32LikeType(ty: *const ast.Type) bool {
    return ty.* == .primitive and (ty.primitive == .i32 or ty.primitive == .integer);
}

pub fn zeroLiteralForType(ty: *const ast.Type) []const u8 {
    if (isFloatType(ty)) return "0.0";
    return "0";
}

pub fn isNumericType(ty: *const ast.Type) bool {
    return ty.* == .primitive and (isIntegerPrimitive(ty.primitive) or isFloatPrimitive(ty.primitive));
}

/// Shared pure fact: Cell payload and similar interior-mutable scalar slots.
pub fn isCellValueType(ty: *const ast.Type) bool {
    return isNumericType(ty) or isPrimitiveType(ty, .boolean);
}

/// Shared pure fact: Poll ready-payload scalars that need no heap materialization.
pub fn isPollScalarValueType(ty: *const ast.Type) bool {
    return isNumericType(ty);
}

/// Shared pure fact: raw pointer values including void-as-ptr alias.
pub fn isPointerValueType(ty: *const ast.Type) bool {
    return ty.* == .pointer or isRawPtrAliasType(ty);
}

pub const ScalarBinaryOp = enum {
    add,
    sub,
    mul,
    sdiv,
    udiv,
    srem,
    urem,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    lshr,
    ashr,
    eq,
    ne,
    slt,
    sle,
    sgt,
    sge,
    ult,
    ule,
    ugt,
    uge,
    logical_and,
    logical_or,
    fadd,
    fsub,
    fmul,
    fdiv,
    fcmp_eq,
    fcmp_ne,
    fcmp_lt,
    fcmp_le,
    fcmp_gt,
    fcmp_ge,
};

pub fn planScalarBinaryOp(op: ast.BinaryOp, left_ty: *const ast.Type, right_ty: *const ast.Type) ?ScalarBinaryOp {
    const use_float = isFloatType(left_ty) or isFloatType(right_ty);
    if (use_float) {
        return switch (op) {
            .add => .fadd,
            .sub => .fsub,
            .mul => .fmul,
            .div => .fdiv,
            .eq => .fcmp_eq,
            .ne => .fcmp_ne,
            .lt => .fcmp_lt,
            .le => .fcmp_le,
            .gt => .fcmp_gt,
            .ge => .fcmp_ge,
            else => null,
        };
    }

    const use_unsigned = isUnsignedIntegerType(left_ty);
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => if (use_unsigned) .udiv else .sdiv,
        .mod => if (use_unsigned) .urem else .srem,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => if (use_unsigned) .lshr else .ashr,
        .eq => .eq,
        .ne => .ne,
        .lt => if (use_unsigned) .ult else .slt,
        .le => if (use_unsigned) .ule else .sle,
        .gt => if (use_unsigned) .ugt else .sgt,
        .ge => if (use_unsigned) .uge else .sge,
        .logical_and => .logical_and,
        .logical_or => .logical_or,
        .spaceship => null,
    };
}

pub fn scalarBinaryOpName(op: ScalarBinaryOp) []const u8 {
    return switch (op) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .sdiv => "sdiv",
        .udiv => "udiv",
        .srem => "srem",
        .urem => "urem",
        .bit_and, .logical_and => "and",
        .bit_or, .logical_or => "or",
        .bit_xor => "xor",
        .shl => "shl",
        .lshr => "lshr",
        .ashr => "ashr",
        .eq => "eq",
        .ne => "ne",
        .slt => "slt",
        .sle => "sle",
        .sgt => "sgt",
        .sge => "sge",
        .ult => "ult",
        .ule => "ule",
        .ugt => "ugt",
        .uge => "uge",
        .fadd => "fadd",
        .fsub => "fsub",
        .fmul => "fmul",
        .fdiv => "fdiv",
        .fcmp_eq => "fcmp_eq",
        .fcmp_ne => "fcmp_ne",
        .fcmp_lt => "fcmp_lt",
        .fcmp_le => "fcmp_le",
        .fcmp_gt => "fcmp_gt",
        .fcmp_ge => "fcmp_ge",
    };
}

pub const SpaceshipOperandKind = enum {
    /// Numeric primitives compared directly into an Ordering.
    numeric,
    /// Same-struct lexicographic comparison over derived-`ord` fields.
    same_struct,
};

pub const SpaceshipPlan = struct {
    kind: SpaceshipOperandKind,
    /// For `.numeric`: whether the comparison is unsigned / float.
    is_unsigned: bool = false,
    is_float: bool = false,
    /// For `.same_struct`: the struct declaration whose fields are compared.
    struct_decl: ?*const ast.StructDecl = null,

    pub fn isNumeric(self: SpaceshipPlan) bool {
        return self.kind == .numeric;
    }

    pub fn isSameStruct(self: SpaceshipPlan) bool {
        return self.kind == .same_struct;
    }
};

/// Classify a `<=>` (spaceship) expression's operands into a shared plan so
/// both emitters agree on numeric vs. struct-lexicographic comparison and on
/// signedness/float selection. Returns null when the operand shape is not a
/// supported spaceship form (numeric-vs-numeric or same-struct-vs-same-struct).
pub fn planSpaceship(
    left_ty: *const ast.Type,
    right_ty: *const ast.Type,
    left_struct: ?*const ast.StructDecl,
    right_struct: ?*const ast.StructDecl,
) ?SpaceshipPlan {
    if (isNumericType(left_ty) and isNumericType(right_ty)) {
        return .{
            .kind = .numeric,
            .is_unsigned = isUnsignedIntegerType(left_ty),
            .is_float = isFloatType(left_ty),
        };
    }
    if (left_struct) |ls| {
        if (right_struct) |rs| {
            if (ls == rs and !ls.is_opaque and !ls.is_union) {
                return .{ .kind = .same_struct, .struct_decl = ls };
            }
        }
    }
    return null;
}

pub fn structLiteralExplicitValue(lit: *const ast.StructLiteral, name: []const u8) ?*ast.Node {
    for (lit.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.value;
    }
    return null;
}

pub fn planStructLiteralField(decl: *const ast.StructDecl, lit: *const ast.StructLiteral, field: ast.Field) ?StructLiteralFieldPlan {
    const layout = structFieldLayout(decl, field.name) orelse return null;
    if (structLiteralExplicitValue(lit, field.name)) |value| {
        return .{ .source = .explicit, .name = field.name, .value = value, .layout = layout, .field_ty = field.ty, .release_loaded = false };
    }
    if (lit.update_expr) |update_expr| {
        return .{ .source = .update, .name = field.name, .value = null, .layout = layout, .field_ty = field.ty, .release_loaded = callArgNeedsRelease(update_expr) };
    }
    return null;
}

/// Whether a struct field type is pointer-backed (heap-allocated aggregate,
/// slice, box, string buffer, nested struct, tuple, array). Such fields
/// cannot be safely shallow-copied through an update (`..base`) path without
/// a shared deep-copy/move plan, so direct SAB should fail explicitly rather
/// than emit an aliasing load/store.
pub fn structFieldIsPointerBacked(field_ty: *const ast.Type) bool {
    return switch (field_ty.*) {
        .infer, .primitive, .pointer, .borrow, .fn_ptr => false,
        .user_defined, .tuple, .array => true,
        else => true,
    };
}

pub fn planStructLiteralFieldTransfer(plan: StructLiteralFieldPlan, field_is_copy_struct: bool) StructLiteralFieldTransfer {
    return switch (plan.source) {
        .explicit => blk: {
            const value = plan.value orelse break :blk .direct;
            if (value.* == .move_expr) break :blk .move;
            if (field_is_copy_struct) break :blk .deep_copy;
            if (structFieldIsPointerBacked(plan.field_ty)) break :blk .move;
            break :blk .direct;
        },
        .update => blk: {
            if (!structFieldIsPointerBacked(plan.field_ty)) break :blk .direct;
            if (field_is_copy_struct) break :blk .deep_copy;
            break :blk .move;
        },
    };
}

/// Raw string literals stored in pointer fields can use the immutable string
/// symbol directly. This avoids creating a temporary SAB borrow view that has
/// no owner after the aggregate takes the pointer value.
pub fn structLiteralDirectFieldUsesConstStringSymbol(value: *const ast.Node, field_ty: *const ast.Type) bool {
    if (value.* != .literal or value.literal != .string_val) return false;
    return typeIsPointerScalarValue(field_ty);
}

/// A string literal normally materializes a temporary slice. A scalar raw
/// pointer struct field stores only the borrowed data pointer, so consume that
/// temporary after the store instead of treating the pointer field as an owner.
pub fn structLiteralDirectFieldConsumesBorrowedString(value: *const ast.Node, field_ty: *const ast.Type) bool {
    return value.* == .literal and value.literal == .string_val and
        field_ty.* == .primitive and field_ty.primitive == .raw_ptr;
}

pub fn mangleMethodName(allocator: std.mem.Allocator, ty_name: []const u8, method_name: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}_{s}", .{ ty_name, method_name });
}

pub fn mangleTraitMethodName(allocator: std.mem.Allocator, ty_name: []const u8, trait_name: []const u8, method_name: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}__{s}_{s}", .{ ty_name, trait_name, method_name });
}

pub fn concreteTypeName(ty: *const ast.Type) ?[]const u8 {
    const curr = peelBorrowPointerType(ty);
    if (curr.* != .user_defined) return null;
    return curr.user_defined.name;
}

pub fn typeBaseName(ty: *const ast.Type) ?[]const u8 {
    return concreteTypeName(ty);
}

pub fn firstGenericArg(ty: *const ast.Type) ?*ast.Type {
    const curr = peelBorrowPointerType(ty);
    if (curr.* != .user_defined or curr.user_defined.generics.len == 0) return null;
    return curr.user_defined.generics[0];
}

pub fn dynTraitName(ty: *const ast.Type) ?[]const u8 {
    const curr = peelBorrowPointerType(ty);
    if (curr.* != .user_defined) return null;
    if (!std.mem.startsWith(u8, curr.user_defined.name, "__dyn_")) return null;
    return curr.user_defined.name["__dyn_".len..];
}

pub fn vtableName(allocator: std.mem.Allocator, trait_name: []const u8, type_name: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "VT_{s}_{s}", .{ type_name, trait_name });
}

pub fn dynVtableUpcastName(allocator: std.mem.Allocator, from_trait: []const u8, to_trait: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "VT_DYN_{s}_TO_{s}", .{ from_trait, to_trait });
}

pub fn traitMethodCount(tc: *type_checker.TypeChecker, trait_name: []const u8) ?usize {
    const trait_decl = tc.traits.get(trait_name) orelse return null;
    var count: usize = 0;
    for (trait_decl.supertraits) |supertrait| {
        count += traitMethodCount(tc, supertrait) orelse return null;
    }
    count += trait_decl.methods.len;
    return count;
}

pub fn dynMethodSlot(tc: *type_checker.TypeChecker, trait_name: []const u8, method_name: []const u8) ?usize {
    const trait_decl = tc.traits.get(trait_name) orelse return null;
    var base: usize = 0;
    for (trait_decl.supertraits) |supertrait| {
        if (dynMethodSlot(tc, supertrait, method_name)) |slot| return base + slot;
        base += (traitMethodCount(tc, supertrait) orelse return null) * 8;
    }
    for (trait_decl.methods, 0..) |method, i| {
        if (std.mem.eql(u8, method.name, method_name)) return base + i * 8;
    }
    return null;
}

pub fn planResolvedStaticCall(tc: *type_checker.TypeChecker, expr: *const ast.Node, call: ast.CallExpr) ?StaticCallPlan {
    const symbol = tc.resolved_call_symbols.get(expr) orelse return null;
    return .{
        .target_symbol = symbol,
        .arg_count = call.args.len,
        .alias_metadata = tc.resolved_call_alias_metadata.get(expr),
    };
}

pub fn planStaticCall(tc: *type_checker.TypeChecker, expr: *const ast.Node, call: ast.CallExpr) ?StaticCallPlan {
    if (planResolvedStaticCall(tc, expr, call)) |plan| return plan;
    if (call.associated_target == null) return .{ .target_symbol = call.func_name, .arg_count = call.args.len };
    return null;
}

pub fn planStaticCallLowering(
    tc: *type_checker.TypeChecker,
    expr: *const ast.Node,
    call: ast.CallExpr,
    expr_ty: ?*const ast.Type,
) ?StaticCallLoweringPlan {
    const call_plan = planStaticCall(tc, expr, call) orelse return null;
    return .{
        .call = call_plan,
        .result = planStaticCallResult(tc, call_plan, expr_ty),
    };
}

pub fn planResolvedStaticCallLowering(
    tc: *type_checker.TypeChecker,
    expr: *const ast.Node,
    call: ast.CallExpr,
    expr_ty: ?*const ast.Type,
) ?StaticCallLoweringPlan {
    const call_plan = planResolvedStaticCall(tc, expr, call) orelse return null;
    return .{
        .call = call_plan,
        .result = planStaticCallResult(tc, call_plan, expr_ty),
    };
}

pub fn staticCallEmitSymbol(plan: StaticCallPlan) []const u8 {
    if (plan.alias_metadata) |metadata| return metadata.alias;
    return plan.target_symbol;
}

pub fn resolveStaticCallSymbol(tc: *type_checker.TypeChecker, expr: *const ast.Node, call: ast.CallExpr) ?[]const u8 {
    const plan = planStaticCall(tc, expr, call) orelse return null;
    return staticCallEmitSymbol(plan);
}

pub fn planAddressOf(expr: *const ast.Node, input: AddressOfInput) AddressOfPlan {
    return .{ .shape = switch (expr.*) {
        .identifier => .identifier,
        .deref_expr => blk: {
            const source_ty = input.deref_source_ty orelse break :blk .value_temp;
            if (plainBorrowOrPointerAddressSource(source_ty)) break :blk .deref_borrow_or_pointer;
            if (smartPointerDerefType(source_ty) != null) break :blk .deref_smart_pointer;
            break :blk .value_temp;
        },
        .field_expr => .field,
        .index_expr => if (input.index_target_ty) |target_ty| if (ordinaryIndexAddressTargetType(target_ty) != null) .index else .value_temp else .value_temp,
        else => .value_temp,
    } };
}

pub fn callArgPrefix(arg: *const ast.Node) ?u8 {
    return switch (arg.*) {
        .borrow_expr => '&',
        .move_expr => '^',
        else => null,
    };
}

pub fn prefixedIdentifierCallArg(arg: *const ast.Node) ?PrefixedIdentifierArg {
    const prefix = callArgPrefix(arg) orelse return null;
    const inner = switch (arg.*) {
        .borrow_expr => arg.borrow_expr.expr,
        .move_expr => arg.move_expr.expr,
        else => return null,
    };
    if (inner.* != .identifier) return null;
    return .{ .prefix = prefix, .name = inner.identifier };
}

pub fn borrowedIdentifierName(expr: *const ast.Node) ?[]const u8 {
    if (expr.* != .borrow_expr) return null;
    const inner = expr.borrow_expr.expr;
    if (inner.* != .identifier) return null;
    return inner.identifier;
}

pub fn callArgNeedsRelease(arg: *const ast.Node) bool {
    return switch (arg.*) {
        .literal => |lit| lit != .string_val,
        .identifier => false,
        .field_expr => true,
        .index_expr => true,
        .borrow_expr => true,
        .move_expr => |move| exprResultNeedsRelease(move.expr),
        .deref_expr => true,
        .cast_expr => false,
        else => true,
    };
}

pub fn exprResultNeedsRelease(expr: *const ast.Node) bool {
    return switch (expr.*) {
        .literal => |lit| lit != .string_val,
        .identifier => false,
        .field_expr => true,
        .index_expr => true,
        .borrow_expr => true,
        .deref_expr => true,
        .cast_expr => false,
        else => true,
    };
}

pub fn intConstantExprValue(expr: *const ast.Node, scalar_consts: anytype) ?i64 {
    return switch (expr.*) {
        .literal => |lit| switch (lit) {
            .int_val => |value| value,
            else => null,
        },
        .identifier => |name| blk: {
            const node = scalar_consts.get(name) orelse break :blk null;
            if (node.* == .literal and node.literal == .int_val) break :blk node.literal.int_val;
            break :blk null;
        },
        .cast_expr => |cast| intConstantExprValue(cast.expr, scalar_consts),
        .binary_expr => |bin| blk: {
            const left = intConstantExprValue(bin.left, scalar_consts) orelse break :blk null;
            const right = intConstantExprValue(bin.right, scalar_consts) orelse break :blk null;
            break :blk switch (bin.op) {
                .add => std.math.add(i64, left, right) catch null,
                .sub => std.math.sub(i64, left, right) catch null,
                .mul => std.math.mul(i64, left, right) catch null,
                .div => if (right == 0) null else @divTrunc(left, right),
                .mod => if (right == 0) null else @rem(left, right),
                .bit_and => left & right,
                .bit_or => left | right,
                .bit_xor => left ^ right,
                .shl => if (right >= 0 and right < 64) left << @as(u6, @intCast(right)) else null,
                .shr => if (right >= 0 and right < 64) left >> @as(u6, @intCast(right)) else null,
                else => null,
            };
        },
        else => null,
    };
}

pub fn fieldBaseResultNeedsRelease(
    expression_result_needs_release: bool,
    generated_register_is_temporary: bool,
    generated_register_is_resolved_binding: bool,
) bool {
    return expression_result_needs_release or
        (generated_register_is_temporary and !generated_register_is_resolved_binding);
}

pub fn fieldAddressProjectionTracksSourceTemp(
    field_expr_is_nested: bool,
    expression_result_needs_release: bool,
    generated_register_is_temporary: bool,
    generated_register_is_resolved_binding: bool,
) bool {
    return field_expr_is_nested or
        expression_result_needs_release or
        (generated_register_is_temporary and !generated_register_is_resolved_binding);
}

pub fn castResultMaterializesTemp(src_ty: *const ast.Type, dst_ty: *const ast.Type) bool {
    return !(isPointerCarrierCastType(src_ty) and isPointerCarrierCastType(dst_ty));
}

pub fn isPointerCarrierCastType(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .pointer, .borrow => true,
        .primitive => |p| p == .raw_ptr,
        .user_defined => |ud| std.mem.eql(u8, ud.name, "AtomicI32") or
            std.mem.eql(u8, ud.name, "AtomicUsize") or
            std.mem.eql(u8, ud.name, "RawWaker") or
            std.mem.eql(u8, ud.name, "Waker") or
            std.mem.eql(u8, ud.name, "LocalWaker") or
            std.mem.eql(u8, ud.name, "Wake"),
        else => false,
    };
}

pub fn isRawPtrAliasType(ty: *const ast.Type) bool {
    return ty.* == .primitive and ty.primitive == .raw_ptr;
}

/// Result slots used by `if`/`match`-style expression lowering must treat
/// pointer-passing values as moves into the slot, not copy-and-release temps.
/// The loaded merge result becomes the sole owner/borrow carrier.
pub fn resultSlotStoreTransfersValue(ty: *const ast.Type) bool {
    return abiPassesAsPointer(ty);
}

pub fn resultSlotNeedsRefCellCompanion(ty: *const ast.Type) bool {
    return ty.* == .borrow;
}

pub fn planResultSlotTransfer(ty: *const ast.Type) ResultSlotTransferPlan {
    return .{
        .transfers_value = resultSlotStoreTransfersValue(ty),
        .needs_refcell_companion = resultSlotNeedsRefCellCompanion(ty),
    };
}

pub fn rootIdentifier(expr: *const ast.Node) ?[]const u8 {
    return switch (expr.*) {
        .identifier => |name| name,
        .field_expr => |field| rootIdentifier(field.expr),
        .index_expr => |idx| rootIdentifier(idx.target),
        .borrow_expr => |borrow| rootIdentifier(borrow.expr),
        .move_expr => |move| rootIdentifier(move.expr),
        else => null,
    };
}

pub fn macroParamRequiresLvalue(tc: *type_checker.TypeChecker, body: []const *ast.Node, name: []const u8) bool {
    for (body) |node| {
        if (macroNodeRequiresLvalue(tc, node, name)) return true;
    }
    return false;
}

fn macroExprRequiresLvalue(tc: *type_checker.TypeChecker, expr: *const ast.Node, name: []const u8) bool {
    return switch (expr.*) {
        .borrow_expr => |borrow| if (rootIdentifier(borrow.expr)) |root| std.mem.eql(u8, root, name) else false,
        .move_expr => |move| if (rootIdentifier(move.expr)) |root| std.mem.eql(u8, root, name) else false,
        .call_expr => |call| blk: {
            const target = tc.resolveFunctionAlias(call.func_name);
            const func = tc.funcs.get(target);
            const is_user_macro = tc.macros.contains(call.func_name);
            const is_imported_macro = tc.imported_macros.contains(call.func_name);
            for (call.args, 0..) |arg, index| {
                if (rootIdentifier(arg)) |root| {
                    if (!std.mem.eql(u8, root, name)) continue;
                    if (is_user_macro or is_imported_macro) break :blk true;
                    if (func) |decl| {
                        if (index < decl.params.len and (decl.params[index].is_borrow or decl.params[index].is_move)) break :blk true;
                    }
                }
            }
            break :blk false;
        },
        .binary_expr => |bin| macroExprRequiresLvalue(tc, bin.left, name) or macroExprRequiresLvalue(tc, bin.right, name),
        .field_expr => |field| macroExprRequiresLvalue(tc, field.expr, name),
        .index_expr => |idx| macroExprRequiresLvalue(tc, idx.target, name),
        .deref_expr => |deref| macroExprRequiresLvalue(tc, deref.expr, name),
        .block_stmt => |block| macroParamRequiresLvalue(tc, block.body, name),
        else => false,
    };
}

fn macroNodeRequiresLvalue(tc: *type_checker.TypeChecker, node: *const ast.Node, name: []const u8) bool {
    return switch (node.*) {
        .assign_stmt => |assign| (if (rootIdentifier(assign.target)) |root| std.mem.eql(u8, root, name) else false) or
            macroExprRequiresLvalue(tc, assign.value, name),
        .release_stmt => |release| std.mem.eql(u8, release.var_name, name),
        .borrow_expr => |borrow| if (rootIdentifier(borrow.expr)) |root| std.mem.eql(u8, root, name) else false,
        .move_expr => |move| if (rootIdentifier(move.expr)) |root| std.mem.eql(u8, root, name) else false,
        .call_expr => |call| blk: {
            const target = tc.resolveFunctionAlias(call.func_name);
            const func = tc.funcs.get(target);
            const is_user_macro = tc.macros.contains(call.func_name);
            const is_imported_macro = tc.imported_macros.contains(call.func_name);
            for (call.args, 0..) |arg, index| {
                if (rootIdentifier(arg)) |root| {
                    if (!std.mem.eql(u8, root, name)) continue;
                    if (is_user_macro or is_imported_macro) break :blk true;
                    if (func) |decl| {
                        if (index < decl.params.len and (decl.params[index].is_borrow or decl.params[index].is_move)) break :blk true;
                    }
                }
            }
            break :blk false;
        },
        .block_stmt => |block| macroParamRequiresLvalue(tc, block.body, name),
        .if_expr => |ife| macroParamRequiresLvalue(tc, ife.then_block, name) or
            (if (ife.else_block) |else_block| macroParamRequiresLvalue(tc, else_block, name) else false),
        .switch_expr => |swe| blk: {
            for (swe.cases) |case| if (macroParamRequiresLvalue(tc, case.body, name)) break :blk true;
            break :blk false;
        },
        .match_expr => |mat| blk: {
            for (mat.cases) |case| if (macroParamRequiresLvalue(tc, case.body, name)) break :blk true;
            break :blk false;
        },
        .unsafe_expr => |unsafe_expr| macroParamRequiresLvalue(tc, unsafe_expr.body, name),
        .for_stmt => |for_stmt| macroParamRequiresLvalue(tc, for_stmt.body, name),
        .while_stmt => |while_stmt| macroParamRequiresLvalue(tc, while_stmt.body, name),
        .expr_stmt => |expr| macroNodeRequiresLvalue(tc, expr, name),
        else => false,
    };
}

pub const FunctionTailCleanupAction = control_flow_rules.FunctionExitCleanupAction;
pub const planFunctionTailCleanup = control_flow_rules.planFunctionExitCleanup;

pub fn isBorrowLikeType(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .borrow => true,
        .primitive => |p| p == .raw_ptr,
        else => false,
    };
}

pub fn storedValueMovesIdentifier(value: *const ast.Node, value_ty: *const ast.Type, value_is_copy: bool) ?[]const u8 {
    if (value.* != .identifier) return null;
    if (value_is_copy or isBorrowLikeType(value_ty)) return null;
    return value.identifier;
}

/// A non-Copy temporary becomes the owning storage for its `let` binding.
/// Direct SAB must retain that register as the local instead of assigning it to
/// an alias, because ownership of pointer-backed aggregate registers is not
/// transferred by `assign`.
pub fn letTemporaryValueBecomesBindingOwner(value_is_copy: bool, value_is_borrow_like: bool) bool {
    return !value_is_copy and !value_is_borrow_like;
}

pub fn assignmentMovesIdentifier(
    target: *const ast.Node,
    value: *const ast.Node,
    value_ty: *const ast.Type,
    value_is_copy: bool,
) ?[]const u8 {
    const value_name = storedValueMovesIdentifier(value, value_ty, value_is_copy) orelse return null;
    if (rootIdentifier(target)) |target_name| {
        if (std.mem.eql(u8, target_name, value_name)) return null;
    }
    return value_name;
}

pub const EscapedClosureCapturePlan = struct {
    consumes_source: bool,
};

pub fn planEscapedClosureCapture(value_ty: *const ast.Type, value_is_copy: bool) EscapedClosureCapturePlan {
    return .{ .consumes_source = !value_is_copy and !isBorrowLikeType(value_ty) };
}

pub const EscapedClosureCaptureSummary = struct {
    has_fn_ptr: bool = false,
    has_noncopy_payload: bool = false,
};

pub const EscapedClosureExecutionPlan = struct {
    inline_join: bool,
};

pub fn accumulateEscapedClosureCapture(summary: EscapedClosureCaptureSummary, value_ty: *const ast.Type, value_is_copy: bool) EscapedClosureCaptureSummary {
    var next = summary;
    if (value_ty.* == .fn_ptr) next.has_fn_ptr = true;
    if (!value_is_copy and !isBorrowLikeType(value_ty)) next.has_noncopy_payload = true;
    return next;
}

pub fn planEscapedClosureExecution(summary: EscapedClosureCaptureSummary) EscapedClosureExecutionPlan {
    return .{ .inline_join = summary.has_fn_ptr and summary.has_noncopy_payload };
}

pub const ValueCallArgConsumptionPlan = struct {
    consumes_source: bool,
};

pub fn planValueCallArgConsumption(
    arg: *const ast.Node,
    param: ?ast.Param,
    arg_ty: ?*const ast.Type,
    value_is_copy: bool,
    has_explicit_prefix: bool,
    source_is_param: bool,
    source_is_std_owner: bool,
    result_escapes_caller: bool,
) ValueCallArgConsumptionPlan {
    if (has_explicit_prefix) return .{ .consumes_source = false };
    const target_param = param orelse return .{ .consumes_source = false };
    if (target_param.is_borrow or target_param.is_move) return .{ .consumes_source = false };
    if (arg.* != .identifier) return .{ .consumes_source = false };
    const ty = arg_ty orelse return .{ .consumes_source = false };
    if (source_is_param and !result_escapes_caller) return .{ .consumes_source = false };
    if (!source_is_param and !source_is_std_owner and !result_escapes_caller) return .{ .consumes_source = false };
    return .{ .consumes_source = !value_is_copy and !isBorrowLikeType(ty) };
}

pub fn shouldAutoBorrowResolvedArg(
    param: ast.Param,
    arg: *const ast.Node,
    arg_ty: *const ast.Type,
    arg_index: usize,
    auto_borrow_receiver: bool,
) bool {
    if (!param.is_borrow or arg.* == .borrow_expr) return false;
    return (auto_borrow_receiver and arg_index == 0) or arg_ty.* == .borrow;
}

pub fn shouldAutoBorrowReceiverArg(param: ast.Param, arg: *const ast.Node, arg_ty: *const ast.Type) bool {
    if (!param.is_borrow or arg.* == .borrow_expr) return false;
    if (arg_ty.* == .borrow) return true;
    return true;
}

pub fn shouldAutoBorrowStatementReceiverArg(param: ast.Param, arg: *const ast.Node, arg_ty: *const ast.Type) bool {
    if (!param.is_borrow or arg.* == .borrow_expr) return false;
    return arg_ty.* != .borrow;
}

fn rawPointerValueType(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .primitive => |p| p == .raw_ptr,
        .pointer => true,
        else => false,
    };
}

pub fn byValueRawPointerParam(param: ast.Param) bool {
    if (param.is_borrow or param.is_move) return false;
    return rawPointerValueType(param.ty);
}

pub fn callArgUsesRawPointerStringLiteralValue(arg: *const ast.Node, param: ast.Param) bool {
    if (arg.* != .literal or arg.literal != .string_val) return false;
    return byValueRawPointerParam(param);
}

/// Shared pure predicate for by-value Copy-struct identifier args that both
/// emitters lower through `copy_struct_value` materialization.
pub fn callArgIsCopyStructValue(
    arg: *const ast.Node,
    param: ?ast.Param,
    param_is_copy_struct: bool,
) bool {
    const target = param orelse return false;
    if (target.is_borrow or target.is_move) return false;
    if (arg.* != .identifier) return false;
    return param_is_copy_struct;
}

/// Shared pure shape for by-value non-Copy identifier args that emitters may
/// shallow-copy at the call boundary. Emitter-local copy/shallow-copy depth
/// facts are passed in; this only classifies the shared eligibility shape.
pub fn callArgIsShallowCopyValueCandidate(
    arg: *const ast.Node,
    param: ?ast.Param,
    arg_ty: ?*const ast.Type,
    arg_is_copy_value: bool,
    arg_is_shallow_copy_call_arg_value: bool,
) bool {
    const target = param orelse return false;
    if (target.is_borrow or target.is_move) return false;
    if (arg.* != .identifier) return false;
    const ty = arg_ty orelse target.ty;
    if (ty.* != .user_defined) return false;
    if (arg_is_copy_value or isBorrowLikeType(ty)) return false;
    return arg_is_shallow_copy_call_arg_value;
}

/// Shared pure leaf/base decisions for recursive shallow-copy call-arg typing.
/// Returns null when the emitter must recurse into aggregates or look up
/// user-defined/enum decls.
pub fn shallowCopyCallArgValueBase(ty: *const ast.Type, depth: usize) ?bool {
    if (depth > 8) return false;
    if (isStdCollectionType(ty)) return depth > 0;
    return switch (ty.*) {
        .primitive, .pointer, .borrow, .fn_ptr => true,
        .tuple, .array, .user_defined => null,
        else => false,
    };
}

/// Shared pure gate for user-defined shallow-copy call-arg values before enum/
/// struct lookup. Returns `depth > 0` for std-owner/smart-pointer containers,
/// null when the emitter must continue with enum/struct resolution.
pub fn shallowCopyCallArgUserDefinedBase(ty: *const ast.Type, depth: usize) ?bool {
    if (userDefinedStdOwnerIsNonCopy(ty) or smartPointerType(ty) != null) return depth > 0;
    return null;
}

/// Shared pure gate after a user-defined struct decl has been resolved for
/// shallow-copy call-arg typing. Field recursion remains emitter-local.
pub fn shallowCopyCallArgStructGate(decl: *const ast.StructDecl) bool {
    return !decl.is_opaque and !decl.is_union;
}

/// Shared pure classification for small plain ABI slot structs: non-opaque,
/// non-union, <= 128 bytes, and only primitive/pointer/borrow/fnptr fields.
pub fn typeIsSmallPlainSlotStructDecl(decl: *const ast.StructDecl) bool {
    if (decl.is_opaque or decl.is_union or structAbiSize(decl) > 128) return false;
    for (decl.fields) |field| {
        switch (field.ty.*) {
            .primitive, .pointer, .borrow, .fn_ptr => {},
            else => return false,
        }
    }
    return true;
}

/// Shared pure Hash leaf for primitive types.
pub fn primitiveIsHashable(p: ast.Primitive) bool {
    return switch (p) {
        .raw_ptr, .void_type, .f32, .f64, .float => false,
        else => true,
    };
}

/// Shared pure resolution of the concrete struct type used for slot-copy
/// materialization: either the type itself or a single pointer peel.
pub fn slotCopyStructTypeFact(
    ty: *const ast.Type,
    ty_has_struct_decl: bool,
    pointed_ty: ?*const ast.Type,
    pointed_has_struct_decl: bool,
) ?*const ast.Type {
    if (ty_has_struct_decl) return ty;
    if (ty.* != .pointer) return null;
    if (pointed_ty) |inner| {
        if (pointed_has_struct_decl) return inner;
    }
    return null;
}

/// Shared pure fact: values that act as non-owning pointer scalars for SAB
/// register ownership (raw pointers and void-as-ptr).
pub fn typeIsPointerScalarValue(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .primitive => |prim| prim == .raw_ptr,
        .pointer => true,
        else => false,
    };
}

/// Shared pure fact: primitives may reuse a scalar reassign/copy slot.
pub fn typeCanUseScalarReassignSlot(ty: *const ast.Type) bool {
    return ty.* == .primitive;
}

/// Shared pure FORMAT_PUSH_* suffix for primitive Debug/format fields.
/// Returns null for non-primitive or void.
pub fn debugFormatSuffix(ty: *const ast.Type) ?[]const u8 {
    return switch (ty.*) {
        .primitive => |p| switch (p) {
            .i8, .i16, .i32, .i64, .isize, .integer => "I64",
            .u8, .u16, .u32, .u64, .usize => "U64",
            .f32, .f64, .float => "F64",
            .boolean => "BOOL",
            else => null,
        },
        else => null,
    };
}

/// Shared pure leaf/base decisions for recursive Copy-value typing.
/// Returns null when the emitter must recurse into aggregates or consult
/// user-defined Copy derives.
pub fn typeIsCopyValueBase(ty: *const ast.Type) ?bool {
    return switch (ty.*) {
        .primitive, .fn_ptr => typeIsCopyValueLeaf(ty) orelse false,
        .tuple, .array, .user_defined => null,
        else => false,
    };
}

/// Shared composition for Copy-struct classification used by both emitters.
pub fn typeIsCopyStructFact(has_struct_decl: bool, has_copy_derive: bool) bool {
    return has_struct_decl and has_copy_derive;
}

/// Shared pure base for recursive derive typing (Copy/Debug/Hash/...).
/// `primitive_ok` classifies primitive leaves; returns null when the emitter
/// must look up a user-defined decl and recurse into fields.
pub fn typeHasNamedDeriveBase(ty: *const ast.Type, primitive_ok: bool) ?bool {
    return switch (ty.*) {
        .primitive => primitive_ok,
        .user_defined => if (userDefinedStdOwnerIsNonCopy(ty)) false else null,
        else => false,
    };
}

/// Shared pure base for recursive Copy-derive typing.
pub fn typeHasCopyDeriveBase(ty: *const ast.Type) ?bool {
    const primitive_ok = if (ty.* == .primitive) primitiveIsCopyValue(ty.primitive) else false;
    return typeHasNamedDeriveBase(ty, primitive_ok);
}

/// Shared pure gate after a user-defined struct decl has been resolved for a
/// named derive. Field recursion remains emitter-local.
pub fn typeHasNamedDeriveStructGate(decl: *const ast.StructDecl, derive_name: []const u8) bool {
    return structHasDerive(decl, derive_name) and !decl.is_opaque and !decl.is_union;
}

/// Shared pure gate after a user-defined struct decl has been resolved.
pub fn typeHasCopyDeriveStructGate(decl: *const ast.StructDecl) bool {
    return typeHasNamedDeriveStructGate(decl, "copy");
}

/// Whether a nested struct field should be recursively shallow-copied while
/// building a shallow-copied call-arg aggregate. Pure containers/owners stay
/// as single field words; ordinary nested structs recurse.
pub fn shallowCopyCallArgFieldShouldRecurse(
    field_has_struct_decl: bool,
    field_ty: *const ast.Type,
) bool {
    if (!field_has_struct_decl) return false;
    if (userDefinedStdOwnerIsNonCopy(field_ty)) return false;
    if (smartPointerType(field_ty) != null) return false;
    if (isStdCollectionType(field_ty)) return false;
    return true;
}

pub fn planCallArgMaterialization(arg: *const ast.Node, input: CallArgMaterializationInput) CallArgMaterializationPlan {
    if (input.param) |param| {
        if (callArgUsesRawPointerStringLiteralValue(arg, param)) {
            return .{ .kind = .raw_pointer_string_literal, .release_after_call = true };
        }
    }
    if (input.array_to_slice_borrow) {
        return .{ .kind = .array_to_slice_borrow, .release_after_call = callArgNeedsRelease(arg) };
    }
    if (input.dyn_borrow_trait_name) |trait_name| {
        return .{ .kind = .dyn_borrow, .release_after_call = false, .dyn_borrow_trait_name = trait_name };
    }
    if (input.param) |param| {
        if (input.arg_ty) |arg_ty| {
            if (input.statement_receiver_auto_borrow) {
                if (shouldAutoBorrowStatementReceiverArg(param, arg, arg_ty)) {
                    return .{ .kind = .auto_borrow, .release_after_call = callArgNeedsRelease(arg) or input.generated_scalar_const_identifier };
                }
            } else if (input.receiver_style_auto_borrow) {
                if (shouldAutoBorrowReceiverArg(param, arg, arg_ty)) {
                    return .{ .kind = .auto_borrow, .release_after_call = callArgNeedsRelease(arg) or input.generated_scalar_const_identifier };
                }
            } else if (input.abi_borrow_auto_borrow and param.is_borrow and arg.* != .borrow_expr) {
                return .{ .kind = .auto_borrow, .release_after_call = callArgNeedsRelease(arg) or input.generated_scalar_const_identifier };
            } else if (shouldAutoBorrowResolvedArg(param, arg, arg_ty, input.arg_index, input.auto_borrow_receiver)) {
                return .{ .kind = .auto_borrow, .release_after_call = callArgNeedsRelease(arg) or input.generated_scalar_const_identifier };
            }
        }
    }
    if (input.copy_struct_value) {
        return .{ .kind = .copy_struct_value, .release_after_call = true };
    }
    if (input.target == .direct_sab) {
        if (input.generated_fn_ptr_identifier) {
            return .{ .kind = .generated_fn_ptr_value_slot, .release_after_call = true };
        }
        if (input.local_fn_ptr_identifier) {
            return .{ .kind = .borrow_local_fn_ptr_value, .release_after_call = false };
        }
    }
    if (input.shallow_copy_value) {
        return .{ .kind = .shallow_copy_preserved_value, .release_after_call = false };
    }
    return .{
        .kind = .value,
        .release_after_call = !input.value_arg_transfers_ownership and
            (callArgNeedsRelease(arg) or
                input.generated_fn_ptr_identifier or
                input.generated_scalar_const_identifier),
        .transfers_ownership = input.value_arg_transfers_ownership,
    };
}

pub fn vecElementPushTransfersOwnership(elem_ty: *const ast.Type, elem_is_copy: bool) bool {
    return !elem_is_copy and !isBorrowLikeType(elem_ty);
}

pub fn isStdCollectionType(ty: *const ast.Type) bool {
    return vecElementType(ty) != null or
        vecDequeElementType(ty) != null or
        hashMapTypes(ty) != null or
        btreeMapTypes(ty) != null or
        hashSetElementType(ty) != null or
        btreeSetElementType(ty) != null;
}

pub fn primitiveIsCopyValue(p: ast.Primitive) bool {
    return p != .raw_ptr and p != .void_type;
}

/// Non-recursive copy-value facts for shapes that do not need struct tables.
pub fn typeIsCopyValueLeaf(ty: *const ast.Type) ?bool {
    return switch (ty.*) {
        .primitive => |p| primitiveIsCopyValue(p),
        .fn_ptr => true,
        .pointer, .borrow => false,
        else => null,
    };
}

pub fn typeShapeIsCopyValueWithoutUserDefined(ty: *const ast.Type) ?bool {
    return switch (ty.*) {
        .primitive => |p| primitiveIsCopyValue(p),
        .fn_ptr => true,
        .tuple => null, // needs recursive user-defined checks
        .user_defined => null,
        else => false,
    };
}

/// Pure call-arg ownership facts shared by SA-text and direct SAB emitters.
/// Type identity / Copy-ness are supplied by the emitter (which owns the TC).
pub const ValueArgOwnershipFacts = struct {
    param_is_present: bool,
    param_is_borrow: bool,
    param_is_move: bool,
    param_is_by_value_raw_pointer: bool,
    arg_is_borrow_like: bool,
    arg_is_copy_value: bool,
};

pub fn planValueArgTransfersOwnership(facts: ValueArgOwnershipFacts) bool {
    if (!facts.param_is_present) return false;
    if (facts.param_is_borrow or facts.param_is_move) return false;
    if (facts.param_is_by_value_raw_pointer) return false;
    if (facts.arg_is_borrow_like) return false;
    return !facts.arg_is_copy_value;
}

/// Shared param/type packaging for `planValueArgTransfersOwnership`. Emitters
/// only supply the local copy-value fact for the resolved argument type.
pub fn valueArgTransfersOwnershipFromParam(
    param: ?ast.Param,
    arg_ty: ?*const ast.Type,
    arg_is_copy_value: bool,
) bool {
    const target = param orelse return planValueArgTransfersOwnership(.{
        .param_is_present = false,
        .param_is_borrow = false,
        .param_is_move = false,
        .param_is_by_value_raw_pointer = false,
        .arg_is_borrow_like = false,
        .arg_is_copy_value = false,
    });
    const ty = arg_ty orelse target.ty;
    return planValueArgTransfersOwnership(.{
        .param_is_present = true,
        .param_is_borrow = target.is_borrow,
        .param_is_move = target.is_move,
        .param_is_by_value_raw_pointer = byValueRawPointerParam(target),
        .arg_is_borrow_like = isBorrowLikeType(ty),
        .arg_is_copy_value = arg_is_copy_value,
    });
}

pub const FnPtrValueArgSlotFacts = struct {
    param_is_present: bool,
    param_is_borrow: bool,
    param_is_move: bool,
    param_ty_is_fn_ptr: bool,
    arg_ty_is_fn_ptr: bool,
};

pub fn planNeedsFnPtrValueArgSlot(facts: FnPtrValueArgSlotFacts) bool {
    if (!facts.param_is_present) return false;
    if (facts.param_is_borrow or facts.param_is_move or !facts.param_ty_is_fn_ptr) return false;
    return facts.arg_ty_is_fn_ptr;
}

/// Identifier that names a function symbol with fn-pointer type (generated fnptr value).
pub fn identifierIsGeneratedFnPtr(
    arg: *const ast.Node,
    is_func_symbol: bool,
    arg_ty_is_fn_ptr: bool,
) bool {
    return arg.* == .identifier and is_func_symbol and arg_ty_is_fn_ptr;
}

/// Identifier that names a top-level scalar const folded for call-arg materialization.
pub fn identifierIsGeneratedScalarConst(
    arg: *const ast.Node,
    is_global_scalar_const: bool,
) bool {
    return arg.* == .identifier and is_global_scalar_const;
}

/// By-value fn-pointer param receiving a generated function-symbol identifier.
pub fn callArgIsGeneratedFnPtrValue(
    arg: *const ast.Node,
    param: ?ast.Param,
    arg_ty_is_fn_ptr: bool,
    is_func_symbol: bool,
) bool {
    const target = param orelse return false;
    if (!planNeedsFnPtrValueArgSlot(.{
        .param_is_present = true,
        .param_is_borrow = target.is_borrow,
        .param_is_move = target.is_move,
        .param_ty_is_fn_ptr = target.ty.* == .fn_ptr,
        .arg_ty_is_fn_ptr = arg_ty_is_fn_ptr,
    })) return false;
    return identifierIsGeneratedFnPtr(arg, is_func_symbol, arg_ty_is_fn_ptr);
}

/// By-value fn-pointer param receiving a local non-function identifier.
pub fn callArgIsLocalFnPtrValue(
    arg: *const ast.Node,
    param: ?ast.Param,
    arg_ty_is_fn_ptr: bool,
    is_func_symbol: bool,
    has_local_binding: bool,
) bool {
    const target = param orelse return false;
    if (!planNeedsFnPtrValueArgSlot(.{
        .param_is_present = true,
        .param_is_borrow = target.is_borrow,
        .param_is_move = target.is_move,
        .param_ty_is_fn_ptr = target.ty.* == .fn_ptr,
        .arg_ty_is_fn_ptr = arg_ty_is_fn_ptr,
    })) return false;
    if (arg.* != .identifier or is_func_symbol) return false;
    return has_local_binding;
}

test "shared lowering rules normalize derives and call argument prefixes" {
    const derives = [_][]const u8{ "PartialEq", "Hash" };
    const decl = ast.StructDecl{
        .name = "Thing",
        .derives = derives[0..],
        .generics = &.{},
        .fields = &.{},
    };

    try std.testing.expect(structHasDerive(&decl, "eq"));
    try std.testing.expect(structHasDerive(&decl, "HASH"));
    try std.testing.expect(!structHasDerive(&decl, "debug"));

    var value = ast.Node{ .identifier = "value" };
    var borrowed = ast.Node{ .borrow_expr = .{ .expr = &value } };
    var moved = ast.Node{ .move_expr = .{ .expr = &value } };

    try std.testing.expectEqual(@as(?u8, null), callArgPrefix(&value));
    try std.testing.expectEqual(@as(?u8, '&'), callArgPrefix(&borrowed));
    try std.testing.expectEqual(@as(?u8, '^'), callArgPrefix(&moved));

    const borrowed_ident = prefixedIdentifierCallArg(&borrowed) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, '&'), borrowed_ident.prefix);
    try std.testing.expectEqualSlices(u8, "value", borrowed_ident.name);
    const moved_ident = prefixedIdentifierCallArg(&moved) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, '^'), moved_ident.prefix);
    try std.testing.expectEqualSlices(u8, "value", moved_ident.name);
}

test "shared lowering rules classify address-of shapes" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var borrow_i32_ty = ast.Type{ .borrow = &i32_ty };
    var pointer_i32_ty = ast.Type{ .pointer = &i32_ty };
    var box_ty = ast.Type{ .user_defined = .{ .name = "Box", .generics = &.{} } };
    const box_generics = [_]*ast.Type{&i32_ty};
    var box_i32_ty = ast.Type{ .user_defined = .{ .name = "Box", .generics = box_generics[0..] } };
    var borrow_box_i32_ty = ast.Type{ .borrow = &box_i32_ty };
    var pointer_box_i32_ty = ast.Type{ .pointer = &box_i32_ty };
    const refcell_generics = [_]*ast.Type{&i32_ty};
    var refcell_i32_ty = ast.Type{ .user_defined = .{ .name = "RefCell", .generics = refcell_generics[0..] } };
    var borrow_refcell_i32_ty = ast.Type{ .borrow = &refcell_i32_ty };
    var array_i32_ty = ast.Type{ .array = .{ .elem = &i32_ty, .len = 3 } };
    var borrow_array_i32_ty = ast.Type{ .borrow = &array_i32_ty };
    var pointer_array_i32_ty = ast.Type{ .pointer = &array_i32_ty };
    const slice_generics = [_]*ast.Type{&i32_ty};
    var slice_i32_ty = ast.Type{ .user_defined = .{ .name = "Slice", .generics = slice_generics[0..] } };
    var borrow_slice_i32_ty = ast.Type{ .borrow = &slice_i32_ty };
    var pointer_slice_i32_ty = ast.Type{ .pointer = &slice_i32_ty };
    const vec_generics = [_]*ast.Type{&i32_ty};
    var vec_i32_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = vec_generics[0..] } };

    var value = ast.Node{ .identifier = "value" };
    var deref_value = ast.Node{ .deref_expr = .{ .expr = &value } };
    var field_value = ast.Node{ .field_expr = .{ .expr = &value, .field_name = "field" } };
    var zero = ast.Node{ .literal = .{ .int_val = 0 } };
    var index_value = ast.Node{ .index_expr = .{ .target = &value, .index = &zero } };

    try std.testing.expectEqual(AddressOfShape.identifier, planAddressOf(&value, .{}).shape);
    try std.testing.expectEqual(AddressOfShape.deref_borrow_or_pointer, planAddressOf(&deref_value, .{ .deref_source_ty = &borrow_i32_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.deref_borrow_or_pointer, planAddressOf(&deref_value, .{ .deref_source_ty = &pointer_i32_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.value_temp, planAddressOf(&deref_value, .{ .deref_source_ty = &box_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.deref_smart_pointer, planAddressOf(&deref_value, .{ .deref_source_ty = &box_i32_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.deref_smart_pointer, planAddressOf(&deref_value, .{ .deref_source_ty = &borrow_box_i32_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.deref_smart_pointer, planAddressOf(&deref_value, .{ .deref_source_ty = &pointer_box_i32_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.value_temp, planAddressOf(&deref_value, .{ .deref_source_ty = &borrow_refcell_i32_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.field, planAddressOf(&field_value, .{}).shape);
    try std.testing.expectEqual(AddressOfShape.index, planAddressOf(&index_value, .{ .index_target_ty = &array_i32_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.index, planAddressOf(&index_value, .{ .index_target_ty = &borrow_array_i32_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.index, planAddressOf(&index_value, .{ .index_target_ty = &pointer_array_i32_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.index, planAddressOf(&index_value, .{ .index_target_ty = &slice_i32_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.index, planAddressOf(&index_value, .{ .index_target_ty = &borrow_slice_i32_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.index, planAddressOf(&index_value, .{ .index_target_ty = &pointer_slice_i32_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.value_temp, planAddressOf(&index_value, .{ .index_target_ty = &vec_i32_ty }).shape);
    try std.testing.expectEqual(AddressOfShape.value_temp, planAddressOf(&zero, .{}).shape);

    try std.testing.expectEqual(&array_i32_ty, ordinaryIndexAddressTargetType(&array_i32_ty).?);
    try std.testing.expectEqual(&array_i32_ty, ordinaryIndexAddressTargetType(&borrow_array_i32_ty).?);
    try std.testing.expectEqual(&array_i32_ty, ordinaryIndexAddressTargetType(&pointer_array_i32_ty).?);
    try std.testing.expectEqual(&slice_i32_ty, ordinaryIndexAddressTargetType(&borrow_slice_i32_ty).?);
    try std.testing.expect(ordinaryIndexAddressTargetType(&vec_i32_ty) == null);
}

test "shared lowering rules keep string literals as raw pointers for ptr params" {
    var string_arg = ast.Node{ .literal = .{ .string_val = "types" } };
    var ptr_ty = ast.Type{ .primitive = .raw_ptr };
    var borrow_ptr_ty = ast.Type{ .primitive = .raw_ptr };

    try std.testing.expect(byValueRawPointerParam(.{
        .name = "data",
        .ty = &ptr_ty,
    }));
    try std.testing.expect(!byValueRawPointerParam(.{
        .name = "data",
        .ty = &borrow_ptr_ty,
        .is_borrow = true,
    }));

    try std.testing.expect(callArgUsesRawPointerStringLiteralValue(&string_arg, .{
        .name = "data",
        .ty = &ptr_ty,
    }));
    try std.testing.expect(!callArgUsesRawPointerStringLiteralValue(&string_arg, .{
        .name = "data",
        .ty = &borrow_ptr_ty,
        .is_borrow = true,
    }));
}

test "shared imported macro call plan classifies addressable arg actions" {
    const plan = ImportedMacroCallPlan{
        .macro_name = "SLA_HELPER",
        .import_path = "helpers.sa",
        .arity = 2,
        .leading_outputs = 0,
        .borrowed_arg_mask = @as(u64, 1) << 1,
        .address_slot_arg_mask = 0,
        .expression_output = false,
    };

    try std.testing.expect(!plan.callArgNeedsAddressableSlot(0));
    try std.testing.expect(plan.callArgNeedsAddressableSlot(1));
    var value_ident = ast.Node{ .identifier = "value" };
    var other_ident = ast.Node{ .identifier = "other" };
    var value_field = ast.Node{ .field_expr = .{ .expr = &value_ident, .field_name = "field" } };
    try std.testing.expect(plan.addressableIdentifierArgName(0, &value_ident) == null);
    try std.testing.expectEqualStrings("value", plan.addressableIdentifierArgName(1, &value_ident).?);
    try std.testing.expect(plan.addressableIdentifierArgName(1, &value_field) == null);
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.pass_value, plan.planAddressableArgAction(0, false));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.reuse_existing_addressable, plan.planAddressableArgAction(1, true));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.materialize_stack_slot, plan.planAddressableArgAction(1, false));

    const expression_output_plan = ImportedMacroCallPlan{
        .macro_name = "SLA_EXPR_HELPER",
        .import_path = "helpers.sa",
        .arity = 2,
        .leading_outputs = 1,
        .borrowed_arg_mask = @as(u64, 1) << 1,
        .address_slot_arg_mask = 0,
        .expression_output = true,
    };

    try std.testing.expect(expression_output_plan.callArgNeedsAddressableSlot(0));
    try std.testing.expectEqualStrings("other", expression_output_plan.addressableIdentifierArgName(0, &other_ident).?);
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.reuse_existing_addressable, expression_output_plan.planAddressableArgAction(0, true));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.materialize_stack_slot, expression_output_plan.planAddressableArgAction(0, false));
}

test "shared imported macro expression result kinds cover compiler helper macros" {
    try std.testing.expectEqual(ImportedMacroExpressionResultKind.raw_pointer, importedMacroExpressionResultKind("SLA_BUF_ALLOC").?);
    try std.testing.expectEqual(ImportedMacroExpressionResultKind.u8, importedMacroExpressionResultKind("SLA_BYTE_AT").?);
    try std.testing.expectEqual(ImportedMacroExpressionResultKind.raw_pointer, importedMacroExpressionResultKind("SLA_JSON_OBJECT_GET").?);
    try std.testing.expectEqual(ImportedMacroExpressionResultKind.raw_pointer, importedMacroExpressionResultKind("SLA_JSON_ARRAY_GET").?);
    try std.testing.expectEqual(ImportedMacroExpressionResultKind.u32, importedMacroExpressionResultKind("JSON_KIND").?);
    try std.testing.expectEqual(ImportedMacroExpressionResultKind.i64, importedMacroExpressionResultKind("SLA_JSON_AS_I64").?);
    try std.testing.expectEqual(ImportedMacroExpressionResultKind.u8, importedMacroExpressionResultKind("SLA_JSON_AS_BOOL").?);
    try std.testing.expectEqual(ImportedMacroExpressionResultKind.u64, importedMacroExpressionResultKind("SLA_FS_READ_TO_STRING").?);
    try std.testing.expectEqual(ImportedMacroExpressionResultKind.raw_pointer, importedMacroExpressionResultKind("PIN_MUT_GET_MUT").?);
    try std.testing.expectEqual(ImportedMacroExpressionResultKind.raw_pointer, importedMacroExpressionResultKind("FUTURE_READY_POLL_STATE").?);
    try std.testing.expectEqual(ImportedMacroExpressionResultKind.boolean, importedMacroExpressionResultKind("POLL_IS_READY").?);
    try std.testing.expect(importedMacroExpressionResultKind("SLA_UNKNOWN_HELPER") == null);
}

test "shared borrowed binding storage plan keeps primitive address-taken bindings stack backed" {
    var i64_ty = ast.Type{ .primitive = .i64 };
    var ptr_i64_ty = ast.Type{ .pointer = &i64_ty };
    var borrow_i64_ty = ast.Type{ .borrow = &i64_ty };
    var user_ty = ast.Type{ .user_defined = .{ .name = "Payload", .generics = &.{} } };

    try std.testing.expect(planBorrowedBindingStorage(true, &i64_ty).materialize_stack_slot);
    try std.testing.expect(!planBorrowedBindingStorage(false, &i64_ty).materialize_stack_slot);
    try std.testing.expect(!planBorrowedBindingStorage(true, &ptr_i64_ty).materialize_stack_slot);
    try std.testing.expect(!planBorrowedBindingStorage(true, &borrow_i64_ty).materialize_stack_slot);
    try std.testing.expect(!planBorrowedBindingStorage(true, &user_ty).materialize_stack_slot);
}

test "shared imported macro address-expression args materialize stack slots" {
    const plan = ImportedMacroCallPlan{
        .macro_name = "SLA_HELPER",
        .import_path = "helpers.sa",
        .arity = 2,
        .leading_outputs = 0,
        .borrowed_arg_mask = @as(u64, 1) << 1,
        .address_slot_arg_mask = 0,
        .expression_output = false,
    };

    try std.testing.expectEqual(ImportedMacroAddressableArgAction.pass_value, plan.planAddressExpressionArgAction(0, .field, false));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.reuse_existing_addressable, plan.planAddressExpressionArgAction(1, .identifier, true));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.materialize_stack_slot, plan.planAddressExpressionArgAction(1, .identifier, false));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.materialize_address_expression_stack_slot, plan.planAddressExpressionArgAction(1, .field, false));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.materialize_address_expression_stack_slot, plan.planAddressExpressionArgAction(1, .index, false));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.materialize_address_expression_stack_slot, plan.planAddressExpressionArgAction(1, .deref_borrow_or_pointer, false));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.materialize_address_expression_stack_slot, plan.planAddressExpressionArgAction(1, .deref_smart_pointer, false));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.materialize_stack_slot, plan.planAddressExpressionArgAction(1, .value_temp, false));

    var ident = ast.Node{ .identifier = "value" };
    var int_ty = ast.Type{ .primitive = .i64 };
    var infer_ty = ast.Type{ .infer = {} };
    var aggregate_ty = ast.Type{ .user_defined = .{ .name = "Poll", .generics = &.{} } };
    try std.testing.expectEqual(ImportedMacroArgLoweringAction.pass_value, plan.planArgValueBypassAction(0, &ident, &int_ty).?);
    try std.testing.expect(plan.planArgValueBypassAction(1, &ident, &int_ty) == null);
    try std.testing.expect(plan.planArgValueBypassAction(1, &ident, &infer_ty) == null);
    try std.testing.expectEqual(ImportedMacroArgLoweringAction.pass_value, plan.planArgValueBypassAction(1, &ident, &aggregate_ty).?);
    try std.testing.expectEqual(ImportedMacroArgLoweringAction.reuse_existing_addressable, plan.planAddressableArgLoweringAction(1, .identifier, true, &aggregate_ty));
    try std.testing.expectEqual(ImportedMacroArgLoweringAction.materialize_stack_slot, plan.planAddressableArgLoweringAction(1, .identifier, false, &aggregate_ty));
    try std.testing.expectEqual(ImportedMacroArgLoweringAction.pass_pointer_backed_projection, plan.planAddressableArgLoweringAction(1, .field, false, &aggregate_ty));
    try std.testing.expectEqual(ImportedMacroArgLoweringAction.pass_pointer_backed_projection, plan.planAddressableArgLoweringAction(1, .index, false, &aggregate_ty));
    try std.testing.expectEqual(ImportedMacroArgLoweringAction.pass_address_expression, plan.planAddressableArgLoweringAction(1, .deref_borrow_or_pointer, false, &aggregate_ty));

    const address_slot_plan = ImportedMacroCallPlan{
        .macro_name = "SLA_WRITE_HELPER",
        .import_path = "helpers.sa",
        .arity = 2,
        .leading_outputs = 0,
        .borrowed_arg_mask = 0,
        .address_slot_arg_mask = @as(u64, 1) << 1,
        .expression_output = false,
    };
    try std.testing.expect(address_slot_plan.callArgNeedsAddressableSlot(1));
    try std.testing.expect(address_slot_plan.callArgNeedsDirectAddressSlot(1));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.pass_address_expression, address_slot_plan.planAddressExpressionArgAction(1, .field, false));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.pass_address_expression, address_slot_plan.planAddressExpressionArgAction(1, .index, false));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.pass_address_expression, address_slot_plan.planAddressExpressionArgAction(1, .deref_borrow_or_pointer, false));
    try std.testing.expectEqual(ImportedMacroAddressableArgAction.pass_value, address_slot_plan.planAddressExpressionArgAction(1, .value_temp, false));
    try std.testing.expectEqual(ImportedMacroArgLoweringAction.pass_address_expression, address_slot_plan.planAddressableArgLoweringAction(1, .field, false, &aggregate_ty));
    try std.testing.expectEqual(ImportedMacroArgLoweringAction.pass_value, address_slot_plan.planAddressableArgLoweringAction(1, .value_temp, false, &aggregate_ty));
    try std.testing.expectEqual(ImportedMacroArgLoweringAction.pass_value, address_slot_plan.planArgValueBypassAction(1, &ident, &infer_ty).?);
    try std.testing.expectEqual(ImportedMacroArgLoweringAction.pass_value, address_slot_plan.planArgValueBypassAction(1, &ident, &aggregate_ty).?);
}

test "shared imported macro borrowed ptr args stay raw values" {
    var ptr_ty = ast.Type{ .primitive = .raw_ptr };
    var ptr_ptr_ty = ast.Type{ .pointer = &ptr_ty };
    var borrow_ptr_ty = ast.Type{ .borrow = &ptr_ty };
    var int_ty = ast.Type{ .primitive = .i64 };
    try std.testing.expect(importedMacroBorrowUsesRawPointerValue(&ptr_ty));
    try std.testing.expect(importedMacroBorrowUsesRawPointerValue(&ptr_ptr_ty));
    try std.testing.expect(importedMacroBorrowUsesRawPointerValue(&borrow_ptr_ty));
    try std.testing.expect(!importedMacroBorrowUsesRawPointerValue(&int_ty));

    var ptr_call = ast.Node{ .call_expr = .{
        .func_name = "STR_PTR",
        .args = &.{},
        .associated_target = null,
        .generics = &.{},
    } };
    var non_ptr_call = ast.Node{ .call_expr = .{
        .func_name = "STR_LEN",
        .args = &.{},
        .associated_target = null,
        .generics = &.{},
    } };
    try std.testing.expect(importedMacroArgUsesRawPointerValue(&ptr_call, &int_ty));
    try std.testing.expect(!importedMacroArgUsesRawPointerValue(&non_ptr_call, &int_ty));

    const borrowed_arg_plan = ImportedMacroCallPlan{
        .macro_name = "SLA_HELPER",
        .import_path = "helpers.sa",
        .arity = 1,
        .leading_outputs = 0,
        .borrowed_arg_mask = 1,
        .address_slot_arg_mask = 0,
        .expression_output = false,
    };
    try std.testing.expectEqual(ImportedMacroArgLoweringAction.pass_raw_pointer_value, borrowed_arg_plan.planArgValueBypassAction(0, &ptr_call, &int_ty).?);
    try std.testing.expectEqual(ImportedMacroArgLoweringAction.pass_raw_pointer_value, borrowed_arg_plan.planArgValueBypassAction(0, &non_ptr_call, &ptr_ptr_ty).?);
}

test "shared loop control plan detects only current loop jumps" {
    var zero = ast.Node{ .literal = .{ .int_val = 0 } };
    var one = ast.Node{ .literal = .{ .int_val = 1 } };
    var cond = ast.Node{ .literal = .{ .bool_val = true } };
    var current_break = ast.Node{ .break_stmt = .{} };
    var current_continue = ast.Node{ .continue_stmt = .{} };
    var nested_break = ast.Node{ .break_stmt = .{} };

    const if_then = [_]*ast.Node{&current_break};
    var if_expr = ast.Node{ .if_expr = .{ .cond = &cond, .then_block = if_then[0..], .else_block = null } };
    var if_stmt = ast.Node{ .expr_stmt = &if_expr };
    const nested_body = [_]*ast.Node{&nested_break};
    var nested_for = ast.Node{ .for_stmt = .{ .var_name = "j", .start = &zero, .end = &one, .body = nested_body[0..] } };
    const body = [_]*ast.Node{ &if_stmt, &current_continue, &nested_for };

    const plan = planLoopControl(body[0..]);
    try std.testing.expect(plan.has_break);
    try std.testing.expect(plan.has_continue);

    const nested_only = [_]*ast.Node{&nested_for};
    const nested_plan = planLoopControl(nested_only[0..]);
    try std.testing.expect(!nested_plan.has_break);
    try std.testing.expect(!nested_plan.has_continue);
}

test "shared lowering rules classify call materialization decisions" {
    var value = ast.Node{ .identifier = "value" };
    var field = ast.Node{ .field_expr = .{ .expr = &value, .field_name = "field" } };
    var borrowed_value = ast.Node{ .borrow_expr = .{ .expr = &value } };
    var borrowed_field = ast.Node{ .borrow_expr = .{ .expr = &field } };
    var moved_value = ast.Node{ .move_expr = .{ .expr = &value } };
    var cast_ty = ast.Type{ .primitive = .i64 };
    var cast_value = ast.Node{ .cast_expr = .{ .expr = &value, .ty = &cast_ty } };

    try std.testing.expect(!callArgNeedsRelease(&value));
    try std.testing.expect(callArgNeedsRelease(&field));
    try std.testing.expect(callArgNeedsRelease(&borrowed_value));
    try std.testing.expect(callArgNeedsRelease(&borrowed_field));
    try std.testing.expect(!callArgNeedsRelease(&cast_value));
    try std.testing.expect(!exprResultNeedsRelease(&value));
    try std.testing.expect(exprResultNeedsRelease(&field));
    try std.testing.expect(exprResultNeedsRelease(&borrowed_value));
    try std.testing.expect(!fieldBaseResultNeedsRelease(false, true, true));
    try std.testing.expect(fieldBaseResultNeedsRelease(false, true, false));
    try std.testing.expect(fieldBaseResultNeedsRelease(true, false, true));
    try std.testing.expect(!fieldBaseResultNeedsRelease(false, false, false));
    try std.testing.expect(!fieldAddressProjectionTracksSourceTemp(false, false, true, true));
    try std.testing.expect(fieldAddressProjectionTracksSourceTemp(false, false, true, false));
    try std.testing.expect(fieldAddressProjectionTracksSourceTemp(false, true, false, true));
    try std.testing.expect(fieldAddressProjectionTracksSourceTemp(true, false, false, true));

    try std.testing.expectEqualStrings("value", borrowedIdentifierName(&borrowed_value).?);
    try std.testing.expect(borrowedIdentifierName(&borrowed_field) == null);
    try std.testing.expect(borrowedIdentifierName(&value) == null);
    try std.testing.expect(borrowedIdentifierName(&moved_value) == null);

    var boxed_ty = ast.Type{ .user_defined = .{ .name = "Boxed", .generics = &.{} } };
    var primitive_ty = ast.Type{ .primitive = .i32 };
    var borrow_boxed_ty = ast.Type{ .borrow = &boxed_ty };
    var target = ast.Node{ .identifier = "target" };
    var source = ast.Node{ .identifier = "source" };
    var same_target = ast.Node{ .identifier = "source" };
    var target_field = ast.Node{ .field_expr = .{ .expr = &target, .field_name = "field" } };

    const moved_to_identifier = assignmentMovesIdentifier(&target, &source, &boxed_ty, false) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualSlices(u8, "source", moved_to_identifier);
    const moved_to_field = assignmentMovesIdentifier(&target_field, &source, &boxed_ty, false) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualSlices(u8, "source", moved_to_field);
    try std.testing.expect(assignmentMovesIdentifier(&same_target, &source, &boxed_ty, false) == null);
    try std.testing.expect(assignmentMovesIdentifier(&target, &source, &primitive_ty, true) == null);
    try std.testing.expect(assignmentMovesIdentifier(&target, &source, &borrow_boxed_ty, false) == null);
    try std.testing.expect(assignmentMovesIdentifier(&target, &field, &boxed_ty, false) == null);
    try std.testing.expect(letTemporaryValueBecomesBindingOwner(false, false));
    try std.testing.expect(!letTemporaryValueBecomesBindingOwner(true, false));
    try std.testing.expect(!letTemporaryValueBecomesBindingOwner(false, true));

    const boxed_param = ast.Param{ .name = "value", .ty = &boxed_ty };
    try std.testing.expect(planValueCallArgConsumption(&source, boxed_param, &boxed_ty, false, false, false, false, true).consumes_source);
    try std.testing.expect(!planValueCallArgConsumption(&source, boxed_param, &boxed_ty, false, false, false, false, false).consumes_source);
    try std.testing.expect(planValueCallArgConsumption(&source, boxed_param, &boxed_ty, false, false, false, true, false).consumes_source);
    try std.testing.expect(!planValueCallArgConsumption(&source, boxed_param, &boxed_ty, false, false, true, true, false).consumes_source);
    try std.testing.expect(planValueCallArgConsumption(&source, boxed_param, &boxed_ty, false, false, true, true, true).consumes_source);
    try std.testing.expect(!planValueCallArgConsumption(&source, boxed_param, &boxed_ty, true, false, false, true, true).consumes_source);
    try std.testing.expect(!planValueCallArgConsumption(&source, boxed_param, &borrow_boxed_ty, false, false, false, true, true).consumes_source);
    try std.testing.expect(!planValueCallArgConsumption(&field, boxed_param, &boxed_ty, false, false, false, true, true).consumes_source);
    try std.testing.expect(!planValueCallArgConsumption(&source, boxed_param, &boxed_ty, false, true, false, true, true).consumes_source);

    var i64_ty = ast.Type{ .primitive = .i64 };
    var borrow_i64_ty = ast.Type{ .borrow = &i64_ty };
    const borrow_param = ast.Param{ .name = "self", .ty = &i64_ty, .is_borrow = true };
    const plain_param = ast.Param{ .name = "value", .ty = &i64_ty };

    try std.testing.expect(shouldAutoBorrowResolvedArg(borrow_param, &value, &i64_ty, 0, true));
    try std.testing.expect(!shouldAutoBorrowResolvedArg(borrow_param, &value, &i64_ty, 1, true));
    try std.testing.expect(shouldAutoBorrowResolvedArg(borrow_param, &value, &borrow_i64_ty, 1, false));
    try std.testing.expect(!shouldAutoBorrowResolvedArg(plain_param, &value, &i64_ty, 0, true));

    try std.testing.expect(shouldAutoBorrowReceiverArg(borrow_param, &value, &i64_ty));
    try std.testing.expect(shouldAutoBorrowReceiverArg(borrow_param, &value, &borrow_i64_ty));
    try std.testing.expect(!shouldAutoBorrowReceiverArg(borrow_param, &borrowed_value, &borrow_i64_ty));
    try std.testing.expect(!shouldAutoBorrowReceiverArg(plain_param, &value, &i64_ty));
    try std.testing.expect(shouldAutoBorrowStatementReceiverArg(borrow_param, &value, &i64_ty));
    try std.testing.expect(!shouldAutoBorrowStatementReceiverArg(borrow_param, &value, &borrow_i64_ty));
    try std.testing.expect(!shouldAutoBorrowStatementReceiverArg(plain_param, &value, &i64_ty));

    const array_plan = planCallArgMaterialization(&field, .{ .array_to_slice_borrow = true });
    try std.testing.expect(array_plan.isArrayToSliceBorrow());
    try std.testing.expect(array_plan.release_after_call);

    var raw_ptr_ty = ast.Type{ .pointer = &i64_ty };
    const raw_param = ast.Param{ .name = "raw", .ty = &raw_ptr_ty };
    var string_arg = ast.Node{ .literal = .{ .string_val = "raw" } };
    const raw_string_plan = planCallArgMaterialization(&string_arg, .{ .param = raw_param });
    try std.testing.expect(raw_string_plan.isRawPointerStringLiteral());
    try std.testing.expect(raw_string_plan.release_after_call);

    const dyn_plan = planCallArgMaterialization(&value, .{ .dyn_borrow_trait_name = "Drawable" });
    try std.testing.expect(dyn_plan.isDynBorrow());
    try std.testing.expect(!dyn_plan.release_after_call);
    try std.testing.expectEqualSlices(u8, "Drawable", dyn_plan.dyn_borrow_trait_name.?);

    const auto_borrow_plan = planCallArgMaterialization(&value, .{
        .param = borrow_param,
        .arg_ty = &i64_ty,
        .arg_index = 0,
        .auto_borrow_receiver = true,
    });
    try std.testing.expect(auto_borrow_plan.isAutoBorrow());
    try std.testing.expect(!auto_borrow_plan.release_after_call);

    const generated_auto_borrow_plan = planCallArgMaterialization(&value, .{
        .param = borrow_param,
        .arg_ty = &i64_ty,
        .arg_index = 0,
        .auto_borrow_receiver = true,
        .generated_scalar_const_identifier = true,
    });
    try std.testing.expect(generated_auto_borrow_plan.isAutoBorrow());
    try std.testing.expect(generated_auto_borrow_plan.release_after_call);

    const receiver_style_plan = planCallArgMaterialization(&value, .{
        .param = borrow_param,
        .arg_ty = &i64_ty,
        .receiver_style_auto_borrow = true,
    });
    try std.testing.expect(receiver_style_plan.isAutoBorrow());

    const explicit_borrow_receiver_style_plan = planCallArgMaterialization(&borrowed_value, .{
        .param = borrow_param,
        .arg_ty = &borrow_i64_ty,
        .receiver_style_auto_borrow = true,
    });
    try std.testing.expect(explicit_borrow_receiver_style_plan.isValue());
    try std.testing.expect(explicit_borrow_receiver_style_plan.release_after_call);

    const statement_receiver_plan = planCallArgMaterialization(&value, .{
        .param = borrow_param,
        .arg_ty = &borrow_i64_ty,
        .statement_receiver_auto_borrow = true,
    });
    try std.testing.expect(statement_receiver_plan.isValue());

    try std.testing.expect(callArgIsCopyStructValue(&value, plain_param, true));
    try std.testing.expect(!callArgIsCopyStructValue(&value, plain_param, false));
    try std.testing.expect(!callArgIsCopyStructValue(&value, borrow_param, true));
    try std.testing.expect(!callArgIsCopyStructValue(&borrowed_value, plain_param, true));
    try std.testing.expect(callArgIsShallowCopyValueCandidate(&source, boxed_param, &boxed_ty, false, true));
    try std.testing.expect(!callArgIsShallowCopyValueCandidate(&source, boxed_param, &boxed_ty, true, true));
    try std.testing.expect(!callArgIsShallowCopyValueCandidate(&source, boxed_param, &boxed_ty, false, false));
    try std.testing.expect(!callArgIsShallowCopyValueCandidate(&source, borrow_param, &boxed_ty, false, true));
    try std.testing.expect(!callArgIsShallowCopyValueCandidate(&field, boxed_param, &boxed_ty, false, true));
    const copy_plan = planCallArgMaterialization(&value, .{ .copy_struct_value = true });
    try std.testing.expect(copy_plan.isCopyStructValue());
    try std.testing.expect(copy_plan.release_after_call);

    const generated_plan = planCallArgMaterialization(&value, .{ .generated_fn_ptr_identifier = true });
    try std.testing.expect(generated_plan.isValue());
    try std.testing.expect(generated_plan.release_after_call);

    const generated_sab_plan = planCallArgMaterialization(&value, .{
        .target = .direct_sab,
        .generated_fn_ptr_identifier = true,
    });
    try std.testing.expect(generated_sab_plan.isGeneratedFnPtrValueSlot());
    try std.testing.expect(generated_sab_plan.release_after_call);

    const local_fnptr_sab_plan = planCallArgMaterialization(&value, .{
        .target = .direct_sab,
        .local_fn_ptr_identifier = true,
    });
    try std.testing.expect(local_fnptr_sab_plan.isBorrowLocalFnPtrValue());
    try std.testing.expect(!local_fnptr_sab_plan.release_after_call);

    const preserved_sab_plan = planCallArgMaterialization(&value, .{
        .target = .direct_sab,
        .preserve_identifier_for_later_use = true,
        .shallow_copy_value = true,
    });
    try std.testing.expect(preserved_sab_plan.isShallowCopyPreservedValue());
    try std.testing.expect(!preserved_sab_plan.release_after_call);

    const preserved_sa_plan = planCallArgMaterialization(&value, .{
        .preserve_identifier_for_later_use = true,
        .shallow_copy_value = true,
    });
    try std.testing.expect(preserved_sa_plan.isShallowCopyPreservedValue());
    try std.testing.expect(!preserved_sa_plan.release_after_call);
}

test "shared integer constant expression value resolves aliases and arithmetic" {
    var scalar_consts = std.StringHashMap(*const ast.Node).init(std.testing.allocator);
    defer scalar_consts.deinit();

    var sixteen = ast.Node{ .literal = .{ .int_val = 16 } };
    var four = ast.Node{ .literal = .{ .int_val = 4 } };
    try scalar_consts.put("ARG_SIZE", &sixteen);
    try scalar_consts.put("ARG_COUNT", &four);

    var size_ident = ast.Node{ .identifier = "ARG_SIZE" };
    var count_ident = ast.Node{ .identifier = "ARG_COUNT" };
    var product = ast.Node{ .binary_expr = .{ .left = &size_ident, .op = .mul, .right = &count_ident } };
    try std.testing.expectEqual(@as(?i64, 64), intConstantExprValue(&product, scalar_consts));

    var int_ty = ast.Type{ .primitive = .i64 };
    var cast_product = ast.Node{ .cast_expr = .{ .expr = &product, .ty = &int_ty } };
    try std.testing.expectEqual(@as(?i64, 64), intConstantExprValue(&cast_product, scalar_consts));

    var unknown = ast.Node{ .identifier = "MISSING" };
    try std.testing.expect(intConstantExprValue(&unknown, scalar_consts) == null);
}

test "shared lowering rules classify user macro lvalue parameters" {
    var tc = type_checker.TypeChecker.init(std.testing.allocator);
    defer tc.deinit();
    var value_ident = ast.Node{ .identifier = "value" };
    var one = ast.Node{ .literal = .{ .int_val = 1 } };
    var sum = ast.Node{ .binary_expr = .{ .op = .add, .left = &value_ident, .right = &one } };
    var value_stmt = ast.Node{ .expr_stmt = &sum };
    try std.testing.expect(!macroParamRequiresLvalue(&tc, &.{&value_stmt}, "value"));

    var out_ident = ast.Node{ .identifier = "out" };
    var assign = ast.Node{ .assign_stmt = .{ .target = &out_ident, .value = &sum } };
    try std.testing.expect(macroParamRequiresLvalue(&tc, &.{&assign}, "out"));
}

test "shared lowering rules classify result-slot value transfer" {
    var primitive_ty = ast.Type{ .primitive = .i32 };
    var borrow_primitive_ty = ast.Type{ .borrow = &primitive_ty };
    var user_ty = ast.Type{ .user_defined = .{ .name = "Payload", .generics = &.{} } };
    var future_inner_ty = ast.Type{ .primitive = .i64 };
    var future_ty = ast.Type{ .future = &future_inner_ty };

    try std.testing.expect(!resultSlotStoreTransfersValue(&primitive_ty));
    try std.testing.expect(resultSlotStoreTransfersValue(&borrow_primitive_ty));
    try std.testing.expect(resultSlotStoreTransfersValue(&user_ty));
    try std.testing.expect(resultSlotStoreTransfersValue(&future_ty));

    const primitive_plan = planResultSlotTransfer(&primitive_ty);
    try std.testing.expect(!primitive_plan.transfers_value);
    try std.testing.expect(!primitive_plan.needs_refcell_companion);
    try std.testing.expectEqual(ResultSlotLoadLifecycleAction.no_value_state, planResultSlotLoadLifecycle(primitive_plan));
    try std.testing.expectEqual(ResultSlotStoreLifecycleAction.keep_source, planResultSlotStoreLifecycle(primitive_plan, false));
    try std.testing.expectEqual(ResultSlotStoreLifecycleAction.release_source, planResultSlotStoreLifecycle(primitive_plan, true));
    try std.testing.expectEqual(ResultSlotRefCellStoreAction.transfer_value_state, planResultSlotRefCellStore(primitive_plan, false));
    try std.testing.expectEqual(ResultSlotRefCellStoreAction.transfer_value_state, planResultSlotRefCellStore(primitive_plan, true));
    try std.testing.expectEqual(ResultSlotRefCellLoadAction.transfer_value_state, planResultSlotRefCellLoad(primitive_plan, false, false));
    try std.testing.expectEqual(ResultSlotRefCellLoadAction.transfer_value_state, planResultSlotRefCellLoad(primitive_plan, true, true));

    const borrow_plan = planResultSlotTransfer(&borrow_primitive_ty);
    try std.testing.expect(borrow_plan.transfers_value);
    try std.testing.expect(borrow_plan.needs_refcell_companion);
    try std.testing.expectEqual(ResultSlotLoadLifecycleAction.load_value_state, planResultSlotLoadLifecycle(borrow_plan));
    try std.testing.expectEqual(ResultSlotStoreLifecycleAction.transfer_value_state, planResultSlotStoreLifecycle(borrow_plan, true));
    try std.testing.expectEqual(ResultSlotRefCellStoreAction.transfer_value_state, planResultSlotRefCellStore(borrow_plan, false));
    try std.testing.expectEqual(ResultSlotRefCellStoreAction.store_borrow_handle_companion, planResultSlotRefCellStore(borrow_plan, true));
    try std.testing.expectEqual(ResultSlotRefCellLoadAction.transfer_value_state, planResultSlotRefCellLoad(borrow_plan, false, false));
    try std.testing.expectEqual(ResultSlotRefCellLoadAction.release_empty_companion, planResultSlotRefCellLoad(borrow_plan, false, true));
    try std.testing.expectEqual(ResultSlotRefCellLoadAction.restore_borrow_handle_companion, planResultSlotRefCellLoad(borrow_plan, true, false));
    try std.testing.expectEqual(ResultSlotRefCellLoadAction.restore_borrow_handle_companion, planResultSlotRefCellLoad(borrow_plan, true, true));

    const user_plan = planResultSlotTransfer(&user_ty);
    try std.testing.expect(user_plan.transfers_value);
    try std.testing.expect(!user_plan.needs_refcell_companion);
    try std.testing.expectEqual(ResultSlotRefCellStoreAction.store_borrow_handle_companion, planResultSlotRefCellStore(user_plan, true));
    try std.testing.expectEqual(ResultSlotRefCellLoadAction.release_empty_companion, planResultSlotRefCellLoad(user_plan, false, true));

    const future_plan = planResultSlotTransfer(&future_ty);
    try std.testing.expect(future_plan.transfers_value);
    try std.testing.expect(!future_plan.needs_refcell_companion);
}

test "shared ABI layout reserves fixed-array struct field payloads" {
    var bool_ty = ast.Type{ .primitive = .boolean };
    var i32_ty = ast.Type{ .primitive = .i32 };
    var ptr_ty = ast.Type{ .primitive = .raw_ptr };
    var i64_ty = ast.Type{ .primitive = .i64 };
    var bool_array_ty = ast.Type{ .array = .{ .elem = &bool_ty, .len = 2 } };
    var i32_array_ty = ast.Type{ .array = .{ .elem = &i32_ty, .len = 2 } };
    var ptr_array_ty = ast.Type{ .array = .{ .elem = &ptr_ty, .len = 2 } };
    var flags_array_ty = ast.Type{ .array = .{ .elem = &bool_ty, .len = 3 } };
    var i64_array_ty = ast.Type{ .array = .{ .elem = &i64_ty, .len = 2 } };
    const fields = [_]ast.Field{
        .{ .name = "active", .ty = &bool_array_ty },
        .{ .name = "values", .ty = &i32_array_ty },
        .{ .name = "handles", .ty = &ptr_array_ty },
        .{ .name = "flags", .ty = &flags_array_ty },
        .{ .name = "times", .ty = &i64_array_ty },
        .{ .name = "tail", .ty = &bool_ty },
    };
    const decl = ast.StructDecl{
        .name = "Bag",
        .generics = &.{},
        .fields = fields[0..],
    };

    try std.testing.expectEqual(@as(usize, 8), abiTypeSize(&bool_array_ty));
    try std.testing.expectEqual(@as(usize, 2), inlineArraySize(bool_array_ty.array));
    try std.testing.expectEqual(@as(usize, 57), structAbiSize(&decl));
    try std.testing.expectEqual(@as(usize, 16), SliceAbi.size);
    try std.testing.expectEqual(@as(usize, 0), SliceAbi.ptr_offset);
    try std.testing.expectEqual(@as(usize, 8), SliceAbi.len_offset);
    try std.testing.expectEqual(@as(usize, 24), VecAbi.object_size);
    try std.testing.expectEqual(@as(usize, 0), VecAbi.ptr_offset);
    try std.testing.expectEqual(@as(usize, 8), VecAbi.cap_offset);
    try std.testing.expectEqual(@as(usize, 16), VecAbi.len_offset);
    try std.testing.expectEqual(@as(?usize, 1), arrayRestLen(bool_array_ty.array, 1));
    try std.testing.expectEqual(@as(?usize, null), arrayRestLen(bool_array_ty.array, 3));

    const active = structFieldLayout(&decl, "active") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), active.offset);
    try std.testing.expectEqual(@as(usize, 8), active.size);
    const values = structFieldLayout(&decl, "values") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 8), values.offset);
    try std.testing.expectEqual(@as(usize, 8), values.size);
    const handles = structFieldLayout(&decl, "handles") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 16), handles.offset);
    try std.testing.expectEqual(@as(usize, 16), handles.size);
    const flags = structFieldLayout(&decl, "flags") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 32), flags.offset);
    try std.testing.expectEqual(@as(usize, 8), flags.size);
    const times = structFieldLayout(&decl, "times") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 40), times.offset);
    try std.testing.expectEqual(@as(usize, 16), times.size);
    const tail = structFieldLayout(&decl, "tail") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 56), tail.offset);
    try std.testing.expectEqual(@as(usize, 1), tail.size);

    const elem = arrayElementLayout(bool_array_ty.array, 1) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), elem.offset);
    try std.testing.expectEqual(@as(usize, 1), elem.size);
}

test "shared ABI treats ready futures as pointer-backed values" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var future_ty = ast.Type{ .future = &i32_ty };

    try std.testing.expectEqual(@as(usize, 8), abiTypeSize(&future_ty));
    try std.testing.expect(abiPassesAsPointer(&future_ty));
}

test "shared fallible extern payload offsets follow C ABI alignment" {
    try std.testing.expectEqual(@as(usize, 4), abiFalliblePayloadOffset("i32!"));
    try std.testing.expectEqual(@as(usize, 4), abiFalliblePayloadOffset("u16!"));
    try std.testing.expectEqual(@as(usize, 8), abiFalliblePayloadOffset("u64!"));
    try std.testing.expectEqual(@as(usize, 8), abiFalliblePayloadOffset("ptr!"));
    try std.testing.expectEqual(@as(usize, 8), abiFalliblePayloadOffset("^ptr!"));
}

test "shared struct literal update field plan" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    const fields = [_]ast.Field{
        .{ .name = "x", .ty = &i32_ty },
        .{ .name = "y", .ty = &i32_ty },
    };
    const decl = ast.StructDecl{
        .name = "Point",
        .generics = &.{},
        .fields = fields[0..],
    };
    var x_value = ast.Node{ .identifier = "new_x" };
    var base_value = ast.Node{ .identifier = "old" };
    const literal_fields = [_]ast.StructLiteralField{.{ .name = "x", .value = &x_value }};
    const lit = ast.StructLiteral{
        .ty = undefined,
        .fields = literal_fields[0..],
        .update_expr = &base_value,
    };

    const x_plan = planStructLiteralField(&decl, &lit, fields[0]) orelse return error.TestExpectedEqual;
    try std.testing.expect(x_plan.isExplicit());
    try std.testing.expect(x_plan.value.? == &x_value);
    try std.testing.expectEqual(@as(usize, 0), x_plan.layout.offset);
    try std.testing.expect(x_plan.field_ty == &i32_ty);
    try std.testing.expect(!x_plan.release_loaded);

    const y_plan = planStructLiteralField(&decl, &lit, fields[1]) orelse return error.TestExpectedEqual;
    try std.testing.expect(y_plan.isUpdate());
    try std.testing.expect(y_plan.value == null);
    try std.testing.expectEqual(@as(usize, 4), y_plan.layout.offset);
    try std.testing.expect(y_plan.field_ty == &i32_ty);
    // identifier-backed update source is not released (move-by-reuse).
    try std.testing.expect(!y_plan.release_loaded);
    // i32 is a primitive scalar, not pointer-backed.
    try std.testing.expect(!structFieldIsPointerBacked(&i32_ty));
    try std.testing.expect(planStructLiteralFieldTransfer(y_plan, false).isDirect());

    var raw_ptr_ty = ast.Type{ .primitive = .raw_ptr };
    var pointer_ty = ast.Type{ .pointer = &i32_ty };
    var borrow_ty = ast.Type{ .borrow = &i32_ty };
    var fn_ptr_ty = ast.Type{ .fn_ptr = .{ .params = &.{}, .ret = &i32_ty } };
    try std.testing.expect(!structFieldIsPointerBacked(&raw_ptr_ty));
    try std.testing.expect(!structFieldIsPointerBacked(&pointer_ty));
    try std.testing.expect(!structFieldIsPointerBacked(&borrow_ty));
    try std.testing.expect(!structFieldIsPointerBacked(&fn_ptr_ty));
    var string_lit = ast.Node{ .literal = .{ .string_val = "field" } };
    var raw_ident = ast.Node{ .identifier = "raw" };
    try std.testing.expect(structLiteralDirectFieldUsesConstStringSymbol(&string_lit, &raw_ptr_ty));
    try std.testing.expect(!structLiteralDirectFieldUsesConstStringSymbol(&string_lit, &i32_ty));
    try std.testing.expect(!structLiteralDirectFieldUsesConstStringSymbol(&raw_ident, &raw_ptr_ty));

    var nested_ty = ast.Type{ .user_defined = .{ .name = "Nested", .generics = &.{} } };
    const nested_fields = [_]ast.Field{.{ .name = "payload", .ty = &nested_ty }};
    const nested_decl = ast.StructDecl{
        .name = "HasNested",
        .generics = &.{},
        .fields = nested_fields[0..],
    };
    const nested_lit = ast.StructLiteral{
        .ty = undefined,
        .fields = &.{},
        .update_expr = &base_value,
    };
    const nested_plan = planStructLiteralField(&nested_decl, &nested_lit, nested_fields[0]) orelse return error.TestExpectedEqual;
    try std.testing.expect(structFieldIsPointerBacked(nested_plan.field_ty));
    try std.testing.expect(planStructLiteralFieldTransfer(nested_plan, false).isMove());
    try std.testing.expect(planStructLiteralFieldTransfer(nested_plan, true).isDeepCopy());

    var nested_identifier = ast.Node{ .identifier = "existing_nested" };
    const nested_identifier_fields = [_]ast.StructLiteralField{.{ .name = "payload", .value = &nested_identifier }};
    const nested_identifier_lit = ast.StructLiteral{
        .ty = undefined,
        .fields = nested_identifier_fields[0..],
        .update_expr = null,
    };
    const explicit_nested_identifier_plan = planStructLiteralField(&nested_decl, &nested_identifier_lit, nested_fields[0]) orelse return error.TestExpectedEqual;
    try std.testing.expect(planStructLiteralFieldTransfer(explicit_nested_identifier_plan, true).isDeepCopy());

    var moved_nested_identifier = ast.Node{ .move_expr = .{ .expr = &nested_identifier } };
    const moved_nested_identifier_fields = [_]ast.StructLiteralField{.{ .name = "payload", .value = &moved_nested_identifier }};
    const moved_nested_identifier_lit = ast.StructLiteral{
        .ty = undefined,
        .fields = moved_nested_identifier_fields[0..],
        .update_expr = null,
    };
    const moved_nested_identifier_plan = planStructLiteralField(&nested_decl, &moved_nested_identifier_lit, nested_fields[0]) orelse return error.TestExpectedEqual;
    try std.testing.expect(planStructLiteralFieldTransfer(moved_nested_identifier_plan, true).isMove());

    const nested_temp_lit = ast.StructLiteral{ .ty = undefined, .fields = &.{}, .update_expr = null };
    var nested_temp = ast.Node{ .struct_literal = nested_temp_lit };
    const nested_temp_fields = [_]ast.StructLiteralField{.{ .name = "payload", .value = &nested_temp }};
    const nested_temp_outer_lit = ast.StructLiteral{
        .ty = undefined,
        .fields = nested_temp_fields[0..],
        .update_expr = null,
    };
    const explicit_nested_temp_plan = planStructLiteralField(&nested_decl, &nested_temp_outer_lit, nested_fields[0]) orelse return error.TestExpectedEqual;
    try std.testing.expect(planStructLiteralFieldTransfer(explicit_nested_temp_plan, true).isDeepCopy());
}

test "shared enum tag/payload layout" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var i64_ty = ast.Type{ .primitive = .i64 };
    const move_fields = [_]ast.Field{
        .{ .name = "x", .ty = &i32_ty },
        .{ .name = "y", .ty = &i64_ty },
    };
    const variants = [_]ast.EnumVariant{
        .{ .name = "Quit", .fields = &.{} },
        .{ .name = "Move", .fields = move_fields[0..] },
    };
    const decl = ast.EnumDecl{
        .name = "Message",
        .generics = &.{},
        .variants = variants[0..],
    };

    // Discriminant tags are assigned by declaration order.
    try std.testing.expectEqual(@as(usize, 0), enumVariantIndex(&decl, "Quit").?);
    try std.testing.expectEqual(@as(usize, 1), enumVariantIndex(&decl, "Move").?);
    try std.testing.expectEqual(@as(?usize, null), enumVariantIndex(&decl, "Nope"));

    const move = enumVariant(&decl, "Move").?;
    // Payload starts at offset 8 (after the i64 tag word). `x:i32` at 8,
    // `y:i64` aligned to the next 8-byte boundary at 16.
    const x_layout = enumFieldLayout(move, "x").?;
    try std.testing.expectEqual(@as(usize, 8), x_layout.offset);
    const y_layout = enumFieldLayout(move, "y").?;
    try std.testing.expectEqual(@as(usize, 16), y_layout.offset);

    // Total size = tag word + largest variant payload (Move: through y at 16+8=24).
    try std.testing.expectEqual(@as(usize, 24), enumAbiSize(&decl));
}

test "shared while let pattern classification" {
    const some_bindings = [_][]const u8{"value"};
    const some = ast.EnumPattern{ .enum_name = "Option", .variant_name = "Some", .bindings = some_bindings[0..] };
    const some_plan = planWhileLetPattern(some, false).?;
    const some_if_plan = planLetPattern(some, false).?;
    try std.testing.expectEqual(WhileLetPatternKind.option_some, some_plan.kind);
    try std.testing.expectEqual(LetPatternKind.option_some, some_if_plan.kind);
    try std.testing.expect(some_plan.isOptionSome());
    try std.testing.expect(some_plan.isOptionCheck());
    try std.testing.expect(some_if_plan.isOptionSome());
    try std.testing.expect(some_plan.success_on_true);
    try std.testing.expect(some_if_plan.success_on_true);
    try std.testing.expect(some_plan.bindsPayload());
    try std.testing.expect(some_if_plan.bindsPayload());

    const none = ast.EnumPattern{ .enum_name = "Option", .variant_name = "None", .bindings = &.{} };
    const none_plan = planWhileLetPattern(none, false).?;
    try std.testing.expectEqual(WhileLetPatternKind.option_none, none_plan.kind);
    try std.testing.expect(none_plan.isOptionNone());
    try std.testing.expect(none_plan.isOptionCheck());
    try std.testing.expect(!none_plan.success_on_true);
    try std.testing.expect(!none_plan.bindsPayload());

    const err_bindings = [_][]const u8{"err"};
    const err = ast.EnumPattern{ .enum_name = "Result", .variant_name = "Err", .bindings = err_bindings[0..] };
    const err_plan = planWhileLetPattern(err, false).?;
    try std.testing.expectEqual(WhileLetPatternKind.result_err, err_plan.kind);
    try std.testing.expect(err_plan.isResultErr());
    try std.testing.expect(err_plan.isResultCheck());
    try std.testing.expect(!err_plan.success_on_true);
    try std.testing.expect(err_plan.bindsPayload());

    const message = ast.EnumPattern{ .enum_name = "Message", .variant_name = "Move", .bindings = &.{} };
    const enum_plan = planWhileLetPattern(message, true).?;
    try std.testing.expectEqual(WhileLetPatternKind.enum_variant, enum_plan.kind);
    try std.testing.expect(enum_plan.isEnumVariant());
    try std.testing.expect(enum_plan.success_on_true);
}

test "shared scalar match guard scratch planning" {
    var value = ast.Node{ .identifier = "value" };
    var floor = ast.Node{ .identifier = "floor" };
    var ceiling = ast.Node{ .identifier = "ceiling" };
    var lower = ast.Node{ .binary_expr = .{ .op = .gt, .left = &value, .right = &floor } };
    var upper = ast.Node{ .binary_expr = .{ .op = .lt, .left = &value, .right = &ceiling } };
    var compound = ast.Node{ .binary_expr = .{ .op = .logical_and, .left = &lower, .right = &upper } };
    try std.testing.expectEqual(@as(?usize, 1), scalarMatchGuardTempCount(&lower));
    try std.testing.expectEqual(@as(?usize, 3), scalarMatchGuardTempCount(&compound));
    try std.testing.expect(supportsScalarMatchGuard(&compound));

    var call = ast.Node{ .call_expr = .{ .func_name = "check", .generics = &.{}, .args = &.{} } };
    try std.testing.expectEqual(@as(?usize, 1), scalarMatchGuardTempCount(&call));
    var one = ast.Node{ .literal = .{ .int_val = 1 } };
    var adjusted = ast.Node{ .binary_expr = .{ .op = .add, .left = &value, .right = &one } };
    const call_args = [_]*ast.Node{&adjusted};
    var adjusted_call = ast.Node{ .call_expr = .{ .func_name = "check", .generics = &.{}, .args = &call_args } };
    try std.testing.expectEqual(@as(?usize, 2), scalarMatchGuardTempCount(&adjusted_call));
    var i64_ty = ast.Type{ .primitive = .i64 };
    var adjusted_cast = ast.Node{ .cast_expr = .{ .expr = &adjusted, .ty = &i64_ty } };
    const cast_call_args = [_]*ast.Node{&adjusted_cast};
    var cast_call = ast.Node{ .call_expr = .{ .func_name = "check", .generics = &.{}, .args = &cast_call_args } };
    try std.testing.expectEqual(@as(?usize, 3), scalarMatchGuardTempCount(&cast_call));
    var limits = ast.Node{ .identifier = "limits" };
    var floor_field = ast.Node{ .field_expr = .{ .expr = &limits, .field_name = "floor" } };
    const field_call_args = [_]*ast.Node{ &value, &floor_field };
    var field_call = ast.Node{ .call_expr = .{ .func_name = "check", .generics = &.{}, .args = &field_call_args } };
    try std.testing.expectEqual(@as(?usize, 2), scalarMatchGuardTempCount(&field_call));
    var zero = ast.Node{ .literal = .{ .int_val = 0 } };
    var first_limit = ast.Node{ .index_expr = .{ .target = &limits, .index = &zero } };
    const index_call_args = [_]*ast.Node{ &value, &first_limit };
    var index_call = ast.Node{ .call_expr = .{ .func_name = "check", .generics = &.{}, .args = &index_call_args } };
    try std.testing.expectEqual(@as(?usize, 2), scalarMatchGuardTempCount(&index_call));
    var index_name = ast.Node{ .identifier = "index" };
    var dynamic_limit = ast.Node{ .index_expr = .{ .target = &limits, .index = &index_name } };
    const dynamic_index_args = [_]*ast.Node{ &value, &dynamic_limit };
    var dynamic_index_call = ast.Node{ .call_expr = .{ .func_name = "check", .generics = &.{}, .args = &dynamic_index_args } };
    try std.testing.expectEqual(@as(?usize, 4), scalarMatchGuardTempCount(&dynamic_index_call));
    var next_index = ast.Node{ .binary_expr = .{ .op = .add, .left = &index_name, .right = &one } };
    var arithmetic_limit = ast.Node{ .index_expr = .{ .target = &limits, .index = &next_index } };
    const arithmetic_index_args = [_]*ast.Node{ &value, &arithmetic_limit };
    var arithmetic_index_call = ast.Node{ .call_expr = .{ .func_name = "check", .generics = &.{}, .args = &arithmetic_index_args } };
    try std.testing.expectEqual(@as(?usize, 5), scalarMatchGuardTempCount(&arithmetic_index_call));
    var limits_field = ast.Node{ .field_expr = .{ .expr = &limits, .field_name = "values" } };
    var nested_limit = ast.Node{ .index_expr = .{ .target = &limits_field, .index = &index_name } };
    const nested_index_args = [_]*ast.Node{ &value, &nested_limit };
    var nested_index_call = ast.Node{ .call_expr = .{ .func_name = "check", .generics = &.{}, .args = &nested_index_args } };
    try std.testing.expectEqual(@as(?usize, 5), scalarMatchGuardTempCount(&nested_index_call));
}

test "shared executor task buffer classification" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    const task_generics = [_]*ast.Type{&i32_ty};
    var task_ty = ast.Type{ .user_defined = .{ .name = "Task", .generics = task_generics[0..] } };

    var array_ty = ast.Type{ .array = .{ .elem = &task_ty, .len = 3 } };
    const array_plan = executorTaskBufferPlan(&array_ty).?;
    try std.testing.expectEqual(ExecutorTaskBufferKind.fixed_array, array_plan.kind);
    try std.testing.expect(array_plan.isFixedArray());
    try std.testing.expect(!array_plan.isVec());
    try std.testing.expectEqual(@as(?usize, 3), array_plan.fixed_len);
    try std.testing.expect(array_plan.inner == &i32_ty);

    const vec_generics = [_]*ast.Type{&task_ty};
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = vec_generics[0..] } };
    const vec_plan = executorTaskBufferPlan(&vec_ty).?;
    try std.testing.expectEqual(ExecutorTaskBufferKind.vec, vec_plan.kind);
    try std.testing.expect(vec_plan.isVec());
    try std.testing.expect(!vec_plan.isFixedArray());
    try std.testing.expectEqual(@as(?usize, null), vec_plan.fixed_len);
    try std.testing.expect(vec_plan.inner == &i32_ty);
}

test "shared future runtime call classification" {
    var value_node = ast.Node{ .literal = .{ .int_val = 1 } };
    const args = [_]*ast.Node{&value_node};
    const ready = ast.CallExpr{ .func_name = "ready", .associated_target = "future", .generics = &.{}, .args = args[0..] };
    const ready_plan = planFutureRuntimeCall(ready).?;
    try std.testing.expectEqual(FutureRuntimeCallKind.ready, ready_plan.kind);
    try std.testing.expect(ready_plan.isReady());

    var i32_ty = ast.Type{ .primitive = .i32 };
    const generics = [_]*ast.Type{&i32_ty};
    const pending = ast.CallExpr{ .func_name = "pending", .associated_target = "future", .generics = generics[0..], .args = &.{} };
    const pending_plan = planFutureRuntimeCall(pending).?;
    try std.testing.expectEqual(FutureRuntimeCallKind.pending, pending_plan.kind);
    try std.testing.expect(pending_plan.isPending());

    const flat_pending = ast.CallExpr{ .func_name = "future__pending", .generics = generics[0..], .args = &.{} };
    try std.testing.expectEqual(FutureRuntimeCallKind.pending, planFutureRuntimeCall(flat_pending).?.kind);

    const defer_ready = ast.CallExpr{ .func_name = "defer_ready", .associated_target = "future", .generics = &.{}, .args = args[0..] };
    const defer_ready_plan = planFutureRuntimeCall(defer_ready).?;
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, defer_ready_plan.kind);
    try std.testing.expect(defer_ready_plan.isDeferReady());
    var defer_ready_node = ast.Node{ .call_expr = defer_ready };
    try std.testing.expectEqual(FutureReadiness.unknown, exprFutureReadiness(&defer_ready_node, null));

    const flat_defer_ready = ast.CallExpr{ .func_name = "future__defer_ready", .generics = &.{}, .args = args[0..] };
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, planFutureRuntimeCall(flat_defer_ready).?.kind);

    const join_args = [_]*ast.Node{ &value_node, &value_node };
    const join2 = ast.CallExpr{ .func_name = "join2", .associated_target = "future", .generics = &.{}, .args = join_args[0..] };
    const join2_plan = planFutureRuntimeCall(join2).?;
    try std.testing.expectEqual(FutureRuntimeCallKind.join2, join2_plan.kind);
    try std.testing.expect(join2_plan.isJoin2());

    var ready_left = ast.Node{ .call_expr = ready };
    var ready_right = ast.Node{ .call_expr = ready };
    const ready_join_args = [_]*ast.Node{ &ready_left, &ready_right };
    var ready_join = ast.Node{ .call_expr = .{ .func_name = "join2", .associated_target = "future", .generics = &.{}, .args = ready_join_args[0..] } };
    var pair_ty = ast.Type{ .user_defined = .{ .name = "FuturePair", .generics = &.{} } };
    var pair_future_ty = ast.Type{ .future = &pair_ty };
    const ready_join_await_plan = planAwaitFuture(&ready_join, &pair_future_ty, null);
    try std.testing.expect(ready_join_await_plan.poll_once_if_statically_ready);

    var readiness = std.StringHashMap(FutureReadiness).init(std.testing.allocator);
    defer readiness.deinit();
    try readiness.put("left", .ready);
    try readiness.put("right", .ready);
    var left_ident = ast.Node{ .identifier = "left" };
    var right_ident = ast.Node{ .identifier = "right" };
    const local_join_args = [_]*ast.Node{ &left_ident, &right_ident };
    var local_join = ast.Node{ .call_expr = .{ .func_name = "join2", .associated_target = "future", .generics = &.{}, .args = local_join_args[0..] } };
    const local_join_await_plan = planAwaitFutureWithReadiness(&local_join, &pair_future_ty, null, &readiness);
    try std.testing.expect(local_join_await_plan.poll_once_if_statically_ready);

    try readiness.put("right", .pending);
    const local_pending_join_await_plan = planAwaitFutureWithReadiness(&local_join, &pair_future_ty, null, &readiness);
    try std.testing.expect(local_pending_join_await_plan.pending_return_if_async);
    try std.testing.expect(!local_pending_join_await_plan.poll_once_if_statically_ready);

    var pending_node = ast.Node{ .call_expr = pending };
    const pending_await_plan = planAwaitFuture(&pending_node, &i32_ty, null);
    try std.testing.expect(pending_await_plan.ready_state_inner);
    try std.testing.expect(pending_await_plan.pending_return_if_async);

    const pair_left = ast.CallExpr{ .func_name = "pair_left", .associated_target = "future", .generics = &.{}, .args = args[0..] };
    const pair_left_plan = planFutureRuntimeCall(pair_left).?;
    try std.testing.expectEqual(FutureRuntimeCallKind.pair_left, pair_left_plan.kind);
    try std.testing.expect(pair_left_plan.isPairAccessor());

    const select2 = ast.CallExpr{ .func_name = "select2", .associated_target = "future", .generics = &.{}, .args = join_args[0..] };
    const select2_plan = planFutureRuntimeCall(select2).?;
    try std.testing.expectEqual(FutureRuntimeCallKind.select2, select2_plan.kind);
    try std.testing.expect(select2_plan.isSelect2());

    const either_right = ast.CallExpr{ .func_name = "either_right", .associated_target = "future", .generics = &.{}, .args = args[0..] };
    const either_right_plan = planFutureRuntimeCall(either_right).?;
    try std.testing.expectEqual(FutureRuntimeCallKind.either_right, either_right_plan.kind);
    try std.testing.expect(either_right_plan.isEitherAccessor());

    const task_new = ast.CallExpr{ .func_name = "new", .associated_target = "task", .generics = &.{}, .args = args[0..] };
    const task_new_plan = planTaskRuntimeCall(task_new).?;
    try std.testing.expectEqual(TaskRuntimeCallKind.new, task_new_plan.kind);
    try std.testing.expect(task_new_plan.isNew());

    const task_poll = ast.CallExpr{ .func_name = "poll", .associated_target = "task", .generics = &.{}, .args = args[0..] };
    const task_poll_plan = planTaskRuntimeCall(task_poll).?;
    try std.testing.expectEqual(TaskRuntimeCallKind.poll, task_poll_plan.kind);
    try std.testing.expect(task_poll_plan.isPoll());

    const task_is_ready = ast.CallExpr{ .func_name = "is_ready", .associated_target = "task", .generics = &.{}, .args = args[0..] };
    const task_is_ready_plan = planTaskRuntimeCall(task_is_ready).?;
    try std.testing.expectEqual(TaskRuntimeCallKind.is_ready, task_is_ready_plan.kind);
    try std.testing.expect(task_is_ready_plan.isIsReady());

    const task_result = ast.CallExpr{ .func_name = "result", .associated_target = "task", .generics = &.{}, .args = args[0..] };
    const task_result_plan = planTaskRuntimeCall(task_result).?;
    try std.testing.expectEqual(TaskRuntimeCallKind.result, task_result_plan.kind);
    try std.testing.expect(task_result_plan.isResult());

    const state = ast.CallExpr{ .func_name = "state", .associated_target = "task", .generics = &.{}, .args = args[0..] };
    const state_plan = planTaskRuntimeCall(state).?;
    try std.testing.expectEqual(TaskRuntimeCallKind.state, state_plan.kind);
    try std.testing.expect(state_plan.isState());

    const executor_new = ast.CallExpr{ .func_name = "new", .associated_target = "executor", .generics = &.{}, .args = args[0..] };
    const executor_new_plan = planExecutorRuntimeCall(executor_new).?;
    try std.testing.expectEqual(ExecutorRuntimeCallKind.new, executor_new_plan.kind);
    try std.testing.expect(executor_new_plan.isNew());

    const executor_poll_one = ast.CallExpr{ .func_name = "poll_one", .associated_target = "executor", .generics = &.{}, .args = args[0..] };
    const executor_poll_one_plan = planExecutorRuntimeCall(executor_poll_one).?;
    try std.testing.expectEqual(ExecutorRuntimeCallKind.poll_one, executor_poll_one_plan.kind);
    try std.testing.expect(executor_poll_one_plan.isPollOne());

    const executor_poll_ready_count = ast.CallExpr{ .func_name = "poll_ready_count", .associated_target = "executor", .generics = &.{}, .args = args[0..] };
    const executor_poll_ready_count_plan = planExecutorRuntimeCall(executor_poll_ready_count).?;
    try std.testing.expectEqual(ExecutorRuntimeCallKind.poll_ready_count, executor_poll_ready_count_plan.kind);
    try std.testing.expect(executor_poll_ready_count_plan.isPollReadyCount());

    const executor_run_until_complete = ast.CallExpr{ .func_name = "run_until_complete", .associated_target = "executor", .generics = &.{}, .args = args[0..] };
    const executor_run_until_complete_plan = planExecutorRuntimeCall(executor_run_until_complete).?;
    try std.testing.expectEqual(ExecutorRuntimeCallKind.run_until_complete, executor_run_until_complete_plan.kind);
    try std.testing.expect(executor_run_until_complete_plan.isRunUntilComplete());

    const poll_ready = ast.CallExpr{ .func_name = "ready", .associated_target = "poll", .generics = &.{}, .args = args[0..] };
    const poll_ready_plan = planPollRuntimeCall(poll_ready).?;
    try std.testing.expectEqual(PollRuntimeCallKind.ready, poll_ready_plan.kind);
    try std.testing.expect(poll_ready_plan.isReady());

    const poll_pending = ast.CallExpr{ .func_name = "pending", .associated_target = "poll", .generics = generics[0..], .args = &.{} };
    const poll_pending_plan = planPollRuntimeCall(poll_pending).?;
    try std.testing.expectEqual(PollRuntimeCallKind.pending, poll_pending_plan.kind);
    try std.testing.expect(poll_pending_plan.isPending());

    const flat_poll_pending = ast.CallExpr{ .func_name = "poll__pending", .generics = generics[0..], .args = &.{} };
    try std.testing.expect(planPollRuntimeCall(flat_poll_pending).?.isPending());

    const poll_value = ast.CallExpr{ .func_name = "value", .associated_target = "poll", .generics = &.{}, .args = args[0..] };
    const poll_value_plan = planPollRuntimeCall(poll_value).?;
    try std.testing.expectEqual(PollRuntimeCallKind.value, poll_value_plan.kind);
    try std.testing.expect(poll_value_plan.isValue());
}

test "shared async single await continuation plan is defer-ready only" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var value_node = ast.Node{ .literal = .{ .int_val = 41 } };
    const args = [_]*ast.Node{&value_node};
    var defer_call = ast.Node{ .call_expr = .{ .func_name = "defer_ready", .associated_target = "future", .generics = &.{}, .args = args[0..] } };
    var await_node = ast.Node{ .await_expr = .{ .expr = &defer_call } };
    var let_node = ast.Node{ .let_stmt = .{ .name = "value", .ty = null, .value = &await_node } };
    var ident_node = ast.Node{ .identifier = "value" };
    var addend_node = ast.Node{ .literal = .{ .int_val = 1 } };
    var return_expr = ast.Node{ .binary_expr = .{ .left = &ident_node, .op = .add, .right = &addend_node } };
    var return_node = ast.Node{ .return_stmt = .{ .value = &return_expr } };
    const body = [_]*ast.Node{ &let_node, &return_node };
    const func = ast.FuncDecl{ .name = "await_defer", .generics = &.{}, .params = &.{}, .ret_ty = &i32_ty, .body = body[0..], .is_inline = false, .is_async = true };

    const plan = planAsyncSingleAwaitContinuation(&func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", plan.binding_name);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), plan.addend);

    var result_ident = ast.Node{ .identifier = "result" };
    var post_result_expr = ast.Node{ .binary_expr = .{ .left = &ident_node, .op = .add, .right = &addend_node } };
    var post_result_let = ast.Node{ .let_stmt = .{ .name = "result", .ty = null, .value = &post_result_expr } };
    var post_return = ast.Node{ .return_stmt = .{ .value = &result_ident } };
    const post_body = [_]*ast.Node{ &let_node, &post_result_let, &post_return };
    const post_func = ast.FuncDecl{ .name = "await_defer_post_bind", .generics = &.{}, .params = &.{}, .ret_ty = &i32_ty, .body = post_body[0..], .is_inline = false, .is_async = true };

    const post_plan = planAsyncSingleAwaitContinuation(&post_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", post_plan.binding_name);
    try std.testing.expectEqualStrings("result", post_plan.post_binding_name.?);
    try std.testing.expect(post_plan.await_expr == &defer_call);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, post_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), post_plan.addend);

    var ready_call = ast.Node{ .call_expr = .{ .func_name = "ready", .associated_target = "future", .generics = &.{}, .args = args[0..] } };
    await_node.await_expr.expr = &ready_call;
    try std.testing.expect(planAsyncSingleAwaitContinuation(&func) == null);

    var local_defer_call = ast.Node{ .call_expr = .{ .func_name = "defer_ready", .associated_target = "future", .generics = &.{}, .args = args[0..] } };
    var local_state_let = ast.Node{ .let_stmt = .{ .name = "delayed", .ty = null, .value = &local_defer_call } };
    var delayed_ident = ast.Node{ .identifier = "delayed" };
    var local_await = ast.Node{ .await_expr = .{ .expr = &delayed_ident } };
    var local_await_let = ast.Node{ .let_stmt = .{ .name = "ready_value", .ty = null, .value = &local_await } };
    var ready_value_ident = ast.Node{ .identifier = "ready_value" };
    var local_return_expr = ast.Node{ .binary_expr = .{ .left = &addend_node, .op = .add, .right = &ready_value_ident } };
    var local_return = ast.Node{ .return_stmt = .{ .value = &local_return_expr } };
    const local_body = [_]*ast.Node{ &local_state_let, &local_await_let, &local_return };
    const local_func = ast.FuncDecl{ .name = "await_local_defer", .generics = &.{}, .params = &.{}, .ret_ty = &i32_ty, .body = local_body[0..], .is_inline = false, .is_async = true };

    const local_plan = planAsyncSingleAwaitContinuation(&local_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("ready_value", local_plan.binding_name);
    try std.testing.expect(local_plan.await_expr == &local_defer_call);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, local_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), local_plan.addend);

    var local_result_ident = ast.Node{ .identifier = "local_result" };
    var local_result_expr = ast.Node{ .binary_expr = .{ .left = &ready_value_ident, .op = .add, .right = &addend_node } };
    var local_result_let = ast.Node{ .let_stmt = .{ .name = "local_result", .ty = null, .value = &local_result_expr } };
    var local_post_return = ast.Node{ .return_stmt = .{ .value = &local_result_ident } };
    const local_post_body = [_]*ast.Node{ &local_state_let, &local_await_let, &local_result_let, &local_post_return };
    const local_post_func = ast.FuncDecl{ .name = "await_local_defer_post_bind", .generics = &.{}, .params = &.{}, .ret_ty = &i32_ty, .body = local_post_body[0..], .is_inline = false, .is_async = true };

    const local_post_plan = planAsyncSingleAwaitContinuation(&local_post_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("ready_value", local_post_plan.binding_name);
    try std.testing.expectEqualStrings("local_result", local_post_plan.post_binding_name.?);
    try std.testing.expect(local_post_plan.await_expr == &local_defer_call);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, local_post_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), local_post_plan.addend);

    var captured_value_node = ast.Node{ .literal = .{ .int_val = 40 } };
    const captured_args = [_]*ast.Node{&captured_value_node};
    var captured_defer_call = ast.Node{ .call_expr = .{ .func_name = "defer_ready", .associated_target = "future", .generics = &.{}, .args = captured_args[0..] } };
    var captured_await_node = ast.Node{ .await_expr = .{ .expr = &captured_defer_call } };
    var captured_let_node = ast.Node{ .let_stmt = .{ .name = "value", .ty = null, .value = &captured_await_node } };
    var bump_literal = ast.Node{ .literal = .{ .int_val = 2 } };
    var bump_let = ast.Node{ .let_stmt = .{ .name = "bump", .ty = null, .value = &bump_literal } };
    var captured_value_ident = ast.Node{ .identifier = "value" };
    var bump_ident = ast.Node{ .identifier = "bump" };
    var captured_return_expr = ast.Node{ .binary_expr = .{ .left = &captured_value_ident, .op = .add, .right = &bump_ident } };
    var captured_return = ast.Node{ .return_stmt = .{ .value = &captured_return_expr } };
    const captured_body = [_]*ast.Node{ &bump_let, &captured_let_node, &captured_return };
    const captured_func = ast.FuncDecl{ .name = "await_defer_captured", .generics = &.{}, .params = &.{}, .ret_ty = &i32_ty, .body = captured_body[0..], .is_inline = false, .is_async = true };

    const captured_plan = planAsyncSingleAwaitContinuation(&captured_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", captured_plan.binding_name);
    try std.testing.expectEqualStrings("bump", captured_plan.captured_addend_name.?);
    try std.testing.expect(captured_plan.captured_addend_expr == &bump_literal);
    try std.testing.expect(captured_plan.await_expr == &captured_defer_call);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, captured_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 0), captured_plan.addend);

    var captured_immediate_literal = ast.Node{ .literal = .{ .int_val = 1 } };
    var captured_value_plus_bump = ast.Node{ .binary_expr = .{ .left = &captured_value_ident, .op = .add, .right = &bump_ident } };
    var captured_immediate_return_expr = ast.Node{ .binary_expr = .{ .left = &captured_value_plus_bump, .op = .add, .right = &captured_immediate_literal } };
    var captured_immediate_return = ast.Node{ .return_stmt = .{ .value = &captured_immediate_return_expr } };
    const captured_immediate_body = [_]*ast.Node{ &bump_let, &captured_let_node, &captured_immediate_return };
    const captured_immediate_func = ast.FuncDecl{ .name = "await_defer_captured_immediate", .generics = &.{}, .params = &.{}, .ret_ty = &i32_ty, .body = captured_immediate_body[0..], .is_inline = false, .is_async = true };

    const captured_immediate_plan = planAsyncSingleAwaitContinuation(&captured_immediate_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", captured_immediate_plan.binding_name);
    try std.testing.expectEqualStrings("bump", captured_immediate_plan.captured_addend_name.?);
    try std.testing.expect(captured_immediate_plan.captured_addend_expr == &bump_literal);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, captured_immediate_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), captured_immediate_plan.addend);

    var captured_local_defer_call = ast.Node{ .call_expr = .{ .func_name = "defer_ready", .associated_target = "future", .generics = &.{}, .args = captured_args[0..] } };
    var captured_local_state_let = ast.Node{ .let_stmt = .{ .name = "delayed", .ty = null, .value = &captured_local_defer_call } };
    var captured_delayed_ident = ast.Node{ .identifier = "delayed" };
    var captured_local_await = ast.Node{ .await_expr = .{ .expr = &captured_delayed_ident } };
    var captured_local_await_let = ast.Node{ .let_stmt = .{ .name = "ready_value", .ty = null, .value = &captured_local_await } };
    var captured_ready_value_ident = ast.Node{ .identifier = "ready_value" };
    var bump_ident_left = ast.Node{ .identifier = "bump" };
    var captured_local_return_expr = ast.Node{ .binary_expr = .{ .left = &bump_ident_left, .op = .add, .right = &captured_ready_value_ident } };
    var captured_local_return = ast.Node{ .return_stmt = .{ .value = &captured_local_return_expr } };
    const captured_local_body = [_]*ast.Node{ &bump_let, &captured_local_state_let, &captured_local_await_let, &captured_local_return };
    const captured_local_func = ast.FuncDecl{ .name = "await_local_defer_captured", .generics = &.{}, .params = &.{}, .ret_ty = &i32_ty, .body = captured_local_body[0..], .is_inline = false, .is_async = true };

    const captured_local_plan = planAsyncSingleAwaitContinuation(&captured_local_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("ready_value", captured_local_plan.binding_name);
    try std.testing.expectEqualStrings("bump", captured_local_plan.captured_addend_name.?);
    try std.testing.expect(captured_local_plan.captured_addend_expr == &bump_literal);
    try std.testing.expect(captured_local_plan.await_expr == &captured_local_defer_call);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, captured_local_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 0), captured_local_plan.addend);

    var captured_local_immediate_literal = ast.Node{ .literal = .{ .int_val = 1 } };
    var bump_ident_for_sum = ast.Node{ .identifier = "bump" };
    var captured_ready_value_ident_for_sum = ast.Node{ .identifier = "ready_value" };
    var immediate_plus_bump = ast.Node{ .binary_expr = .{ .left = &captured_local_immediate_literal, .op = .add, .right = &bump_ident_for_sum } };
    var captured_local_immediate_return_expr = ast.Node{ .binary_expr = .{ .left = &immediate_plus_bump, .op = .add, .right = &captured_ready_value_ident_for_sum } };
    var captured_local_immediate_return = ast.Node{ .return_stmt = .{ .value = &captured_local_immediate_return_expr } };
    const captured_local_immediate_body = [_]*ast.Node{ &bump_let, &captured_local_state_let, &captured_local_await_let, &captured_local_immediate_return };
    const captured_local_immediate_func = ast.FuncDecl{ .name = "await_local_defer_captured_immediate", .generics = &.{}, .params = &.{}, .ret_ty = &i32_ty, .body = captured_local_immediate_body[0..], .is_inline = false, .is_async = true };

    const captured_local_immediate_plan = planAsyncSingleAwaitContinuation(&captured_local_immediate_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("ready_value", captured_local_immediate_plan.binding_name);
    try std.testing.expectEqualStrings("bump", captured_local_immediate_plan.captured_addend_name.?);
    try std.testing.expect(captured_local_immediate_plan.captured_addend_expr == &bump_literal);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, captured_local_immediate_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), captured_local_immediate_plan.addend);

    var captured_post_result_ident = ast.Node{ .identifier = "result" };
    var captured_post_value_ident = ast.Node{ .identifier = "value" };
    var captured_post_bump_ident = ast.Node{ .identifier = "bump" };
    var captured_post_result_expr = ast.Node{ .binary_expr = .{ .left = &captured_post_value_ident, .op = .add, .right = &captured_post_bump_ident } };
    var captured_post_result_let = ast.Node{ .let_stmt = .{ .name = "result", .ty = null, .value = &captured_post_result_expr } };
    var captured_post_immediate_literal = ast.Node{ .literal = .{ .int_val = 1 } };
    var captured_post_return_expr = ast.Node{ .binary_expr = .{ .left = &captured_post_result_ident, .op = .add, .right = &captured_post_immediate_literal } };
    var captured_post_return = ast.Node{ .return_stmt = .{ .value = &captured_post_return_expr } };
    const captured_post_body = [_]*ast.Node{ &bump_let, &captured_let_node, &captured_post_result_let, &captured_post_return };
    const captured_post_func = ast.FuncDecl{ .name = "await_defer_captured_post_return_addend", .generics = &.{}, .params = &.{}, .ret_ty = &i32_ty, .body = captured_post_body[0..], .is_inline = false, .is_async = true };

    const captured_post_plan = planAsyncSingleAwaitContinuation(&captured_post_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", captured_post_plan.binding_name);
    try std.testing.expectEqualStrings("result", captured_post_plan.post_binding_name.?);
    try std.testing.expectEqualStrings("bump", captured_post_plan.captured_addend_name.?);
    try std.testing.expect(captured_post_plan.captured_addend_expr == &bump_literal);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, captured_post_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), captured_post_plan.addend);

    var captured_local_post_result_ident = ast.Node{ .identifier = "result" };
    var captured_local_post_value_ident = ast.Node{ .identifier = "ready_value" };
    var captured_local_post_bump_ident = ast.Node{ .identifier = "bump" };
    var captured_local_post_result_expr = ast.Node{ .binary_expr = .{ .left = &captured_local_post_value_ident, .op = .add, .right = &captured_local_post_bump_ident } };
    var captured_local_post_result_let = ast.Node{ .let_stmt = .{ .name = "result", .ty = null, .value = &captured_local_post_result_expr } };
    var captured_local_post_immediate_literal = ast.Node{ .literal = .{ .int_val = 1 } };
    var captured_local_post_return_expr = ast.Node{ .binary_expr = .{ .left = &captured_local_post_result_ident, .op = .add, .right = &captured_local_post_immediate_literal } };
    var captured_local_post_return = ast.Node{ .return_stmt = .{ .value = &captured_local_post_return_expr } };
    const captured_local_post_body = [_]*ast.Node{ &bump_let, &captured_local_state_let, &captured_local_await_let, &captured_local_post_result_let, &captured_local_post_return };
    const captured_local_post_func = ast.FuncDecl{ .name = "await_local_defer_captured_post_return_addend", .generics = &.{}, .params = &.{}, .ret_ty = &i32_ty, .body = captured_local_post_body[0..], .is_inline = false, .is_async = true };

    const captured_local_post_plan = planAsyncSingleAwaitContinuation(&captured_local_post_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("ready_value", captured_local_post_plan.binding_name);
    try std.testing.expectEqualStrings("result", captured_local_post_plan.post_binding_name.?);
    try std.testing.expectEqualStrings("bump", captured_local_post_plan.captured_addend_name.?);
    try std.testing.expect(captured_local_post_plan.captured_addend_expr == &bump_literal);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, captured_local_post_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), captured_local_post_plan.addend);
}

test "shared async single await continuation plan recognizes parsed captured addend" {
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\async fn await_defer_ready_with_capture() -> i32 {
        \\    let bump = 1;
        \\    let value = future::defer_ready(40).await;
        \\    return value + bump + 1;
        \\}
        \\async fn await_local_defer_ready_with_capture() -> i32 {
        \\    let bump = 1;
        \\    let delayed = future::defer_ready(40);
        \\    let value = delayed.await;
        \\    return 1 + bump + value;
        \\}
        \\async fn await_defer_ready_with_post_return_addend() -> i32 {
        \\    let bump = 1;
        \\    let value = future::defer_ready(40).await;
        \\    let result = value + bump;
        \\    return result + 1;
        \\}
        \\async fn await_local_defer_ready_with_post_return_addend() -> i32 {
        \\    let bump = 1;
        \\    let delayed = future::defer_ready(40);
        \\    let value = delayed.await;
        \\    let result = value + bump;
        \\    return result + 1;
        \\}
        \\async fn await_defer_ready_sub_capture() -> i32 {
        \\    let bump = 2;
        \\    let value = future::defer_ready(44).await;
        \\    return value - bump;
        \\}
        \\async fn await_local_defer_ready_scaled_capture() -> i32 {
        \\    let bump = 1;
        \\    let delayed = future::defer_ready(20);
        \\    let value = delayed.await;
        \\    return (value + bump) * 2;
        \\}
        \\async fn await_defer_ready_branchy_capture() -> i32 {
        \\    let bump = 2;
        \\    let value = future::defer_ready(40).await;
        \\    return if value > 0 { value + bump } else { bump };
        \\}
        \\async fn await_local_defer_ready_branchy_capture() -> i32 {
        \\    let bump = 2;
        \\    let delayed = future::defer_ready(40);
        \\    let value = delayed.await;
        \\    return if value > 0 { value + bump } else { bump };
        \\}
        \\async fn await_defer_ready_two_post_bindings() -> i32 {
        \\    let bump = 1;
        \\    let value = future::defer_ready(40).await;
        \\    let result = value + bump;
        \\    let final = result + 1;
        \\    return final;
        \\}
        \\async fn await_local_defer_ready_two_post_bindings() -> i32 {
        \\    let bump = 1;
        \\    let delayed = future::defer_ready(40);
        \\    let value = delayed.await;
        \\    let result = value + bump;
        \\    let final = result + 1;
        \\    return final;
        \\}
        \\async fn await_defer_ready_multi_capture() -> i32 {
        \\    let a = 1;
        \\    let b = 2;
        \\    let value = future::defer_ready(39).await;
        \\    return value + a + b;
        \\}
        \\async fn await_local_defer_ready_multi_capture() -> i32 {
        \\    let a = 1;
        \\    let b = 2;
        \\    let delayed = future::defer_ready(39);
        \\    let value = delayed.await;
        \\    return value + a + b;
        \\}
        \\@derive(copy)
        \\struct CaptureBump {
        \\    amount: i32,
        \\}
        \\async fn await_defer_ready_copy_struct_capture() -> i32 {
        \\    let bump = CaptureBump { amount: 3 };
        \\    let value = future::defer_ready(39).await;
        \\    return value + bump.amount;
        \\}
        \\async fn await_local_defer_ready_copy_struct_capture() -> i32 {
        \\    let bump = CaptureBump { amount: 3 };
        \\    let delayed = future::defer_ready(39);
        \\    let value = delayed.await;
        \\    return value + bump.amount;
        \\}
    ;
    var p = parser.Parser.init(arena.allocator(), source);
    const program = try p.parseProgram();
    try std.testing.expect(program.* == .program);
    try std.testing.expectEqual(@as(usize, 15), program.program.decls.len);

    const direct_func = &program.program.decls[0].func_decl;
    const direct_plan = planAsyncSingleAwaitContinuation(direct_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", direct_plan.binding_name);
    try std.testing.expectEqualStrings("bump", direct_plan.captured_addend_name.?);
    try std.testing.expect(direct_plan.captured_addend_expr != null);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, direct_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), direct_plan.addend);

    const local_func = &program.program.decls[1].func_decl;
    const local_plan = planAsyncSingleAwaitContinuation(local_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", local_plan.binding_name);
    try std.testing.expectEqualStrings("bump", local_plan.captured_addend_name.?);
    try std.testing.expect(local_plan.captured_addend_expr != null);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, local_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), local_plan.addend);

    const post_return_func = &program.program.decls[2].func_decl;
    const post_return_plan = planAsyncSingleAwaitContinuation(post_return_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", post_return_plan.binding_name);
    try std.testing.expectEqualStrings("result", post_return_plan.post_binding_name.?);
    try std.testing.expectEqualStrings("bump", post_return_plan.captured_addend_name.?);
    try std.testing.expect(post_return_plan.captured_addend_expr != null);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, post_return_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), post_return_plan.addend);

    const local_post_return_func = &program.program.decls[3].func_decl;
    const local_post_return_plan = planAsyncSingleAwaitContinuation(local_post_return_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", local_post_return_plan.binding_name);
    try std.testing.expectEqualStrings("result", local_post_return_plan.post_binding_name.?);
    try std.testing.expectEqualStrings("bump", local_post_return_plan.captured_addend_name.?);
    try std.testing.expect(local_post_return_plan.captured_addend_expr != null);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, local_post_return_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), local_post_return_plan.addend);

    const sub_func = &program.program.decls[4].func_decl;
    const sub_plan = planAsyncSingleAwaitContinuation(sub_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", sub_plan.binding_name);
    try std.testing.expectEqualStrings("bump", sub_plan.captured_addend_name.?);
    try std.testing.expect(sub_plan.captured_addend_expr != null);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, sub_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), sub_plan.scalar.awaited_coeff);
    try std.testing.expectEqual(@as(i64, -1), sub_plan.scalar.captured_coeff);
    try std.testing.expectEqual(@as(i64, 0), sub_plan.scalar.immediate);

    const scaled_func = &program.program.decls[5].func_decl;
    const scaled_plan = planAsyncSingleAwaitContinuation(scaled_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", scaled_plan.binding_name);
    try std.testing.expectEqualStrings("bump", scaled_plan.captured_addend_name.?);
    try std.testing.expect(scaled_plan.captured_addend_expr != null);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, scaled_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 2), scaled_plan.scalar.awaited_coeff);
    try std.testing.expectEqual(@as(i64, 2), scaled_plan.scalar.captured_coeff);
    try std.testing.expectEqual(@as(i64, 0), scaled_plan.scalar.immediate);

    const branch_func = &program.program.decls[6].func_decl;
    const branch_plan = planAsyncSingleAwaitContinuation(branch_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", branch_plan.binding_name);
    try std.testing.expectEqualStrings("bump", branch_plan.captured_addend_name.?);
    try std.testing.expect(branch_plan.captured_addend_expr != null);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, branch_plan.awaited_kind);
    const branch = branch_plan.branch orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ast.BinaryOp.gt, branch.condition_op);
    try std.testing.expectEqual(@as(i64, 0), branch.threshold);
    try std.testing.expectEqual(@as(i64, 1), branch.then_scalar.awaited_coeff);
    try std.testing.expectEqual(@as(i64, 1), branch.then_scalar.captured_coeff);
    try std.testing.expectEqual(@as(i64, 0), branch.then_scalar.immediate);
    try std.testing.expectEqual(@as(i64, 0), branch.else_scalar.awaited_coeff);
    try std.testing.expectEqual(@as(i64, 1), branch.else_scalar.captured_coeff);
    try std.testing.expectEqual(@as(i64, 0), branch.else_scalar.immediate);

    const local_branch_func = &program.program.decls[7].func_decl;
    const local_branch_plan = planAsyncSingleAwaitContinuation(local_branch_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", local_branch_plan.binding_name);
    try std.testing.expectEqualStrings("bump", local_branch_plan.captured_addend_name.?);
    try std.testing.expect(local_branch_plan.captured_addend_expr != null);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, local_branch_plan.awaited_kind);
    const local_branch = local_branch_plan.branch orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ast.BinaryOp.gt, local_branch.condition_op);
    try std.testing.expectEqual(@as(i64, 0), local_branch.threshold);
    try std.testing.expectEqual(@as(i64, 1), local_branch.then_scalar.awaited_coeff);
    try std.testing.expectEqual(@as(i64, 1), local_branch.then_scalar.captured_coeff);
    try std.testing.expectEqual(@as(i64, 0), local_branch.then_scalar.immediate);
    try std.testing.expectEqual(@as(i64, 0), local_branch.else_scalar.awaited_coeff);
    try std.testing.expectEqual(@as(i64, 1), local_branch.else_scalar.captured_coeff);
    try std.testing.expectEqual(@as(i64, 0), local_branch.else_scalar.immediate);

    const two_post_func = &program.program.decls[8].func_decl;
    const two_post_plan = planAsyncSingleAwaitContinuation(two_post_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", two_post_plan.binding_name);
    try std.testing.expectEqualStrings("final", two_post_plan.post_binding_name.?);
    try std.testing.expectEqualStrings("bump", two_post_plan.captured_addend_name.?);
    try std.testing.expect(two_post_plan.captured_addend_expr != null);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, two_post_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), two_post_plan.scalar.awaited_coeff);
    try std.testing.expectEqual(@as(i64, 1), two_post_plan.scalar.captured_coeff);
    try std.testing.expectEqual(@as(i64, 1), two_post_plan.scalar.immediate);

    const local_two_post_func = &program.program.decls[9].func_decl;
    const local_two_post_plan = planAsyncSingleAwaitContinuation(local_two_post_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", local_two_post_plan.binding_name);
    try std.testing.expectEqualStrings("final", local_two_post_plan.post_binding_name.?);
    try std.testing.expectEqualStrings("bump", local_two_post_plan.captured_addend_name.?);
    try std.testing.expect(local_two_post_plan.captured_addend_expr != null);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, local_two_post_plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), local_two_post_plan.scalar.awaited_coeff);
    try std.testing.expectEqual(@as(i64, 1), local_two_post_plan.scalar.captured_coeff);
    try std.testing.expectEqual(@as(i64, 1), local_two_post_plan.scalar.immediate);

    const multi_capture_func = &program.program.decls[10].func_decl;
    const multi_capture_plan = planAsyncSingleAwaitContinuation(multi_capture_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", multi_capture_plan.binding_name);
    try std.testing.expectEqual(@as(usize, 2), multi_capture_plan.capture_count);
    try std.testing.expectEqualStrings("a", multi_capture_plan.captures[0].?.name);
    try std.testing.expectEqual(@as(usize, 16), multi_capture_plan.captures[0].?.offset);
    try std.testing.expectEqualStrings("b", multi_capture_plan.captures[1].?.name);
    try std.testing.expectEqual(@as(usize, 24), multi_capture_plan.captures[1].?.offset);
    try std.testing.expectEqual(@as(usize, 32), multi_capture_plan.asyncStateSize());
    try std.testing.expectEqual(@as(i64, 1), multi_capture_plan.scalar.awaited_coeff);
    try std.testing.expectEqual(@as(i64, 1), multi_capture_plan.scalar.captured_coeff);
    try std.testing.expectEqual(@as(i64, 1), multi_capture_plan.scalar.captured2_coeff);
    try std.testing.expectEqual(@as(i64, 0), multi_capture_plan.scalar.immediate);

    const local_multi_capture_func = &program.program.decls[11].func_decl;
    const local_multi_capture_plan = planAsyncSingleAwaitContinuation(local_multi_capture_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", local_multi_capture_plan.binding_name);
    try std.testing.expectEqual(@as(usize, 2), local_multi_capture_plan.capture_count);
    try std.testing.expectEqualStrings("a", local_multi_capture_plan.captures[0].?.name);
    try std.testing.expectEqual(@as(usize, 16), local_multi_capture_plan.captures[0].?.offset);
    try std.testing.expectEqualStrings("b", local_multi_capture_plan.captures[1].?.name);
    try std.testing.expectEqual(@as(usize, 24), local_multi_capture_plan.captures[1].?.offset);
    try std.testing.expectEqual(@as(usize, 32), local_multi_capture_plan.asyncStateSize());
    try std.testing.expectEqual(@as(i64, 1), local_multi_capture_plan.scalar.awaited_coeff);
    try std.testing.expectEqual(@as(i64, 1), local_multi_capture_plan.scalar.captured_coeff);
    try std.testing.expectEqual(@as(i64, 1), local_multi_capture_plan.scalar.captured2_coeff);
    try std.testing.expectEqual(@as(i64, 0), local_multi_capture_plan.scalar.immediate);

    const copy_struct_func = &program.program.decls[13].func_decl;
    const copy_struct_plan = planAsyncSingleAwaitContinuation(copy_struct_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", copy_struct_plan.binding_name);
    try std.testing.expectEqual(@as(usize, 1), copy_struct_plan.capture_count);
    try std.testing.expectEqualStrings("bump", copy_struct_plan.captures[0].?.name);
    try std.testing.expectEqual(AsyncContinuationCaptureStorage.copy_struct, copy_struct_plan.captures[0].?.storage);
    try std.testing.expectEqualStrings("amount", copy_struct_plan.scalar.captured_field_name.?);
    try std.testing.expectEqual(@as(i64, 1), copy_struct_plan.scalar.awaited_coeff);
    try std.testing.expectEqual(@as(i64, 1), copy_struct_plan.scalar.captured_coeff);
    try std.testing.expectEqual(@as(i64, 0), copy_struct_plan.scalar.immediate);

    const local_copy_struct_func = &program.program.decls[14].func_decl;
    const local_copy_struct_plan = planAsyncSingleAwaitContinuation(local_copy_struct_func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", local_copy_struct_plan.binding_name);
    try std.testing.expectEqual(@as(usize, 1), local_copy_struct_plan.capture_count);
    try std.testing.expectEqualStrings("bump", local_copy_struct_plan.captures[0].?.name);
    try std.testing.expectEqual(AsyncContinuationCaptureStorage.copy_struct, local_copy_struct_plan.captures[0].?.storage);
    try std.testing.expectEqualStrings("amount", local_copy_struct_plan.scalar.captured_field_name.?);
    try std.testing.expectEqual(@as(i64, 1), local_copy_struct_plan.scalar.awaited_coeff);
    try std.testing.expectEqual(@as(i64, 1), local_copy_struct_plan.scalar.captured_coeff);
    try std.testing.expectEqual(@as(i64, 0), local_copy_struct_plan.scalar.immediate);
}

test "shared async two await continuation plan recognizes defer-ready sequence" {
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\async fn await_two_defer_ready_values() -> i32 {
        \\    let a = future::defer_ready(20).await;
        \\    let b = future::defer_ready(22).await;
        \\    return a + b;
        \\}
        \\async fn await_local_two_defer_ready_values() -> i32 {
        \\    let left = future::defer_ready(20);
        \\    let a = left.await;
        \\    let right = future::defer_ready(22);
        \\    let b = right.await;
        \\    return a + b;
        \\}
        \\async fn await_ready_then_defer_ready_values() -> i32 {
        \\    let a = future::ready(20).await;
        \\    let b = future::defer_ready(22).await;
        \\    return a + b;
        \\}
    ;
    var p = parser.Parser.init(arena.allocator(), source);
    const program = try p.parseProgram();
    try std.testing.expect(program.* == .program);
    try std.testing.expectEqual(@as(usize, 3), program.program.decls.len);

    const direct_plan = planAsyncTwoAwaitContinuation(&program.program.decls[0].func_decl) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("a", direct_plan.first_binding_name);
    try std.testing.expectEqualStrings("b", direct_plan.second_binding_name);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, direct_plan.first_awaited_kind);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, direct_plan.second_awaited_kind);
    try std.testing.expectEqual(@as(usize, 32), direct_plan.asyncStateSize());
    try std.testing.expectEqual(@as(i64, 1), direct_plan.scalar.first_coeff);
    try std.testing.expectEqual(@as(i64, 1), direct_plan.scalar.second_coeff);
    try std.testing.expectEqual(@as(i64, 0), direct_plan.scalar.immediate);

    const local_plan = planAsyncTwoAwaitContinuation(&program.program.decls[1].func_decl) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("a", local_plan.first_binding_name);
    try std.testing.expectEqualStrings("b", local_plan.second_binding_name);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, local_plan.first_awaited_kind);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, local_plan.second_awaited_kind);
    try std.testing.expectEqual(@as(usize, 32), local_plan.asyncStateSize());
    try std.testing.expectEqual(@as(i64, 1), local_plan.scalar.first_coeff);
    try std.testing.expectEqual(@as(i64, 1), local_plan.scalar.second_coeff);
    try std.testing.expectEqual(@as(i64, 0), local_plan.scalar.immediate);

    try std.testing.expect(planAsyncTwoAwaitContinuation(&program.program.decls[2].func_decl) == null);
}

test "shared async join2 await continuation plan recognizes later-ready composite" {
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\async fn await_join2_defer_ready_value() -> i32 {
        \\    let pair = future::join2(future::defer_ready(20), future::ready(22)).await;
        \\    return future::pair_left(pair) + future::pair_right(pair);
        \\}
        \\async fn await_local_join2_defer_ready_value() -> i32 {
        \\    let joined = future::join2(future::ready(20), future::defer_ready(22));
        \\    let pair = joined.await;
        \\    return future::pair_left(pair) + future::pair_right(pair);
        \\}
        \\async fn await_join2_pending_value() -> i32 {
        \\    let pair = future::join2(future::ready(20), future::pending::<i32>()).await;
        \\    return future::pair_left(pair) + future::pair_right(pair);
        \\}
    ;
    var p = parser.Parser.init(arena.allocator(), source);
    const program = try p.parseProgram();
    try std.testing.expect(program.* == .program);
    try std.testing.expectEqual(@as(usize, 3), program.program.decls.len);

    const direct_plan = planAsyncJoin2AwaitContinuation(&program.program.decls[0].func_decl) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("pair", direct_plan.binding_name);
    try std.testing.expectEqual(FutureRuntimeCallKind.join2, direct_plan.awaited_kind);
    try std.testing.expectEqual(@as(usize, 16), direct_plan.asyncStateSize());
    try std.testing.expectEqual(@as(i64, 1), direct_plan.scalar.left_coeff);
    try std.testing.expectEqual(@as(i64, 1), direct_plan.scalar.right_coeff);
    try std.testing.expectEqual(@as(i64, 0), direct_plan.scalar.immediate);

    const local_plan = planAsyncJoin2AwaitContinuation(&program.program.decls[1].func_decl) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("pair", local_plan.binding_name);
    try std.testing.expectEqual(FutureRuntimeCallKind.join2, local_plan.awaited_kind);
    try std.testing.expectEqual(@as(usize, 16), local_plan.asyncStateSize());
    try std.testing.expectEqual(@as(i64, 1), local_plan.scalar.left_coeff);
    try std.testing.expectEqual(@as(i64, 1), local_plan.scalar.right_coeff);
    try std.testing.expectEqual(@as(i64, 0), local_plan.scalar.immediate);

    try std.testing.expect(planAsyncJoin2AwaitContinuation(&program.program.decls[2].func_decl) == null);
}

test "shared result generic inner types" {
    var ok_ty = ast.Type{ .primitive = .i32 };
    var err_ty = ast.Type{ .primitive = .i64 };
    const generics = [_]*ast.Type{ &ok_ty, &err_ty };
    var result_ty = ast.Type{ .user_defined = .{ .name = "Result", .generics = generics[0..] } };
    const vec_generics = [_]*ast.Type{&ok_ty};
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = vec_generics[0..] } };

    try std.testing.expect(resultOkType(&result_ty) == &ok_ty);
    try std.testing.expect(resultErrType(&result_ty) == &err_ty);
    try std.testing.expect(vecElementType(&vec_ty) == &ok_ty);
    try std.testing.expectEqual(@as(usize, 8), vecElementSlotSize(&ok_ty));
}

test "shared dyn trait naming and method slots" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var sprite_ty = ast.Type{ .user_defined = .{ .name = "Sprite", .generics = &.{} } };
    var dyn_draw_ty = ast.Type{ .user_defined = .{ .name = "__dyn_Draw", .generics = &.{} } };
    var borrowed_dyn_draw_ty = ast.Type{ .borrow = &dyn_draw_ty };
    const self_param = ast.Param{ .name = "self", .ty = &sprite_ty, .is_borrow = true };
    const base_methods = [_]ast.TraitMethod{.{ .name = "base", .params = &.{self_param}, .ret_ty = &i32_ty }};
    const draw_methods = [_]ast.TraitMethod{.{ .name = "draw", .params = &.{self_param}, .ret_ty = &i32_ty }};
    const base_trait = ast.TraitDecl{ .name = "Base", .methods = base_methods[0..] };
    const supers = [_][]const u8{"Base"};
    const draw_trait = ast.TraitDecl{ .name = "Draw", .supertraits = supers[0..], .methods = draw_methods[0..] };

    var tc = type_checker.TypeChecker.init(std.testing.allocator);
    defer tc.deinit();
    try tc.traits.put("Base", @constCast(&base_trait));
    try tc.traits.put("Draw", @constCast(&draw_trait));

    try std.testing.expectEqualSlices(u8, "Sprite", concreteTypeName(&sprite_ty).?);
    try std.testing.expectEqualSlices(u8, "Draw", dynTraitName(&borrowed_dyn_draw_ty).?);
    try std.testing.expectEqual(@as(usize, 0), dynMethodSlot(&tc, "Draw", "base").?);
    try std.testing.expectEqual(@as(usize, 8), dynMethodSlot(&tc, "Draw", "draw").?);

    const mangled = try mangleTraitMethodName(std.testing.allocator, "Sprite", "Draw", "draw");
    defer std.testing.allocator.free(mangled);
    try std.testing.expectEqualSlices(u8, "Sprite__Draw_draw", mangled);

    const vt = try vtableName(std.testing.allocator, "Draw", "Sprite");
    defer std.testing.allocator.free(vt);
    try std.testing.expectEqualSlices(u8, "VT_Sprite_Draw", vt);
}

test "shared refcell borrow call plan tracks payload kind and release macro" {
    var i64_ty = ast.Type{ .primitive = .i64 };
    const box_generics = [_]*ast.Type{&i64_ty};
    var box_i64_ty = ast.Type{ .user_defined = .{ .name = "Box", .generics = box_generics[0..] } };
    var payload_ty = ast.Type{ .user_defined = .{ .name = "Payload", .generics = &.{} } };
    const refcell_i64_generics = [_]*ast.Type{&i64_ty};
    var refcell_i64_ty = ast.Type{ .user_defined = .{ .name = "RefCell", .generics = refcell_i64_generics[0..] } };
    const refcell_box_generics = [_]*ast.Type{&box_i64_ty};
    var refcell_box_ty = ast.Type{ .user_defined = .{ .name = "RefCell", .generics = refcell_box_generics[0..] } };
    const refcell_payload_generics = [_]*ast.Type{&payload_ty};
    var refcell_payload_ty = ast.Type{ .user_defined = .{ .name = "RefCell", .generics = refcell_payload_generics[0..] } };
    var cell = ast.Node{ .identifier = "cell" };
    const borrow_args = [_]*ast.Node{&cell};
    const borrow_call = ast.CallExpr{ .func_name = "borrow", .associated_target = null, .generics = &.{}, .args = borrow_args[0..] };
    const borrow_mut_call = ast.CallExpr{ .func_name = "borrow_mut", .associated_target = null, .generics = &.{}, .args = borrow_args[0..] };

    const scalar_plan = planRefCellBorrowCall(borrow_call, &refcell_i64_ty).?;
    try std.testing.expectEqual(RefCellBorrowKind.shared, scalar_plan.kind);
    try std.testing.expectEqual(RefCellBorrowValueKind.scalar_slot, scalar_plan.value_kind);
    try std.testing.expectEqualStrings("REFCELL_U64_TRY_BORROW", scalar_plan.tryBorrowMacroName());
    try std.testing.expectEqualStrings("REFCELL_U64_RELEASE_SHARED", scalar_plan.releaseMacroName());

    const scalar_guard = planRefCellBorrowRuntimeGuard(scalar_plan);
    try std.testing.expect(scalar_guard.release_status_on_conflict);
    try std.testing.expectEqual(@as(i64, 107), scalar_guard.conflict_panic_code);
    try std.testing.expect(scalar_guard.release_status_on_success);

    const scalar_handle_registration = planRefCellBorrowHandleRegistration(scalar_plan);
    try std.testing.expect(!scalar_handle_registration.track_receiver_owner_temp);

    const no_borrow_temp = planBorrowAddressTemps(false, false);
    try std.testing.expect(!no_borrow_temp.track_primary_temp);
    try std.testing.expect(!no_borrow_temp.track_extra_temps);
    try std.testing.expect(!no_borrow_temp.remember);

    const primary_borrow_temp = planBorrowAddressTemps(true, false);
    try std.testing.expect(primary_borrow_temp.track_primary_temp);
    try std.testing.expect(!primary_borrow_temp.track_extra_temps);
    try std.testing.expect(primary_borrow_temp.remember);

    const extra_borrow_temps = planBorrowAddressTemps(false, true);
    try std.testing.expect(!extra_borrow_temps.track_primary_temp);
    try std.testing.expect(extra_borrow_temps.track_extra_temps);
    try std.testing.expect(extra_borrow_temps.remember);

    const full_borrow_temps = planBorrowAddressTemps(true, true);
    try std.testing.expect(full_borrow_temps.track_primary_temp);
    try std.testing.expect(full_borrow_temps.track_extra_temps);
    try std.testing.expect(full_borrow_temps.remember);

    try std.testing.expectEqual(BorrowAddressTempTransferAction.transfer_value_state, planBorrowAddressTempTransfer(false));
    try std.testing.expectEqual(BorrowAddressTempTransferAction.move_borrow_address_temps, planBorrowAddressTempTransfer(true));

    const no_borrow_temp_release = planBorrowAddressTempRelease(false);
    try std.testing.expect(!no_borrow_temp_release.release_borrow_value);
    try std.testing.expect(!no_borrow_temp_release.release_source_temps);

    const borrow_temp_release = planBorrowAddressTempRelease(true);
    try std.testing.expect(borrow_temp_release.release_borrow_value);
    try std.testing.expect(borrow_temp_release.release_source_temps);

    const borrowed_call_arg_release = planPrefixedBorrowAddressCallArgRelease('&', true, true, false);
    try std.testing.expect(borrowed_call_arg_release.emit_arg_prefix);
    try std.testing.expect(!borrowed_call_arg_release.restore_taken_value);
    try std.testing.expect(borrowed_call_arg_release.release_address_value);
    try std.testing.expect(borrowed_call_arg_release.release_source_temps);

    const restored_call_arg = planPrefixedBorrowAddressCallArgRelease('&', true, true, true);
    try std.testing.expect(restored_call_arg.restore_taken_value);
    try std.testing.expect(!restored_call_arg.release_address_value);
    try std.testing.expect(restored_call_arg.release_source_temps);
    try std.testing.expectEqual(
        PrefixedBorrowAddressCallArgRestoreTiming.before_sibling_args,
        planPrefixedBorrowAddressCallArgRestoreTiming('&', true, true),
    );
    try std.testing.expectEqual(
        PrefixedBorrowAddressCallArgRestoreTiming.after_call,
        planPrefixedBorrowAddressCallArgRestoreTiming('&', true, false),
    );
    try std.testing.expectEqual(
        PrefixedBorrowAddressCallArgRestoreTiming.after_call,
        planPrefixedBorrowAddressCallArgRestoreTiming('^', true, true),
    );
    try std.testing.expectEqual(null, prefixedBorrowAddressCallArgOperandPrefix('&', true));
    try std.testing.expectEqual(@as(?u8, '&'), prefixedBorrowAddressCallArgOperandPrefix('&', false));
    try std.testing.expectEqual(@as(?u8, '^'), prefixedBorrowAddressCallArgOperandPrefix('^', true));

    const moved_call_arg_release = planPrefixedBorrowAddressCallArgRelease('^', true, true, false);
    try std.testing.expect(moved_call_arg_release.emit_arg_prefix);
    try std.testing.expect(!moved_call_arg_release.release_address_value);
    try std.testing.expect(moved_call_arg_release.release_source_temps);

    const smart_plan = planRefCellBorrowCall(borrow_call, &refcell_box_ty).?;
    try std.testing.expectEqual(RefCellBorrowValueKind.smart_pointer_payload, smart_plan.value_kind);

    const smart_sa_result = planRefCellBorrowResult(.sa_text, smart_plan.value_kind);
    try std.testing.expectEqual(RefCellBorrowResultAction.load_pointer_payload, smart_sa_result.action);
    try std.testing.expect(smart_sa_result.release_borrow_slot_after_payload);
    try std.testing.expect(!smart_sa_result.track_borrow_slot_release_temp);

    const smart_sab_result = planRefCellBorrowResult(.direct_sab, smart_plan.value_kind);
    try std.testing.expectEqual(RefCellBorrowResultAction.use_borrow_slot, smart_sab_result.action);
    try std.testing.expect(!smart_sab_result.release_borrow_slot_after_payload);
    try std.testing.expect(!smart_sab_result.track_borrow_slot_release_temp);

    const pointer_plan = planRefCellBorrowCall(borrow_mut_call, &refcell_payload_ty).?;
    try std.testing.expectEqual(RefCellBorrowKind.mutable, pointer_plan.kind);
    try std.testing.expectEqual(RefCellBorrowValueKind.pointer_payload, pointer_plan.value_kind);
    try std.testing.expectEqualStrings("REFCELL_U64_TRY_BORROW_MUT", pointer_plan.tryBorrowMacroName());
    try std.testing.expectEqualStrings("REFCELL_U64_RELEASE_MUT", pointer_plan.releaseMacroName());

    const escaped_copy = planEscapedClosureCapture(&i64_ty, true);
    try std.testing.expect(!escaped_copy.consumes_source);

    const escaped_move = planEscapedClosureCapture(&refcell_i64_ty, false);
    try std.testing.expect(escaped_move.consumes_source);

    var borrow_i64_ty = ast.Type{ .borrow = &i64_ty };
    const escaped_borrow = planEscapedClosureCapture(&borrow_i64_ty, false);
    try std.testing.expect(!escaped_borrow.consumes_source);

    const pointer_sa_result = planRefCellBorrowResult(.sa_text, pointer_plan.value_kind);
    try std.testing.expectEqual(RefCellBorrowResultAction.load_pointer_payload, pointer_sa_result.action);
    try std.testing.expect(pointer_sa_result.release_borrow_slot_after_payload);
    try std.testing.expect(!pointer_sa_result.track_borrow_slot_release_temp);

    const pointer_sab_result = planRefCellBorrowResult(.direct_sab, pointer_plan.value_kind);
    try std.testing.expectEqual(RefCellBorrowResultAction.take_pointer_payload, pointer_sab_result.action);
    try std.testing.expect(!pointer_sab_result.release_borrow_slot_after_payload);
    try std.testing.expect(pointer_sab_result.track_borrow_slot_release_temp);

    const scalar_sab_result = planRefCellBorrowResult(.direct_sab, scalar_plan.value_kind);
    try std.testing.expectEqual(RefCellBorrowResultAction.use_borrow_slot, scalar_sab_result.action);
    try std.testing.expect(!scalar_sab_result.release_borrow_slot_after_payload);
    try std.testing.expect(!scalar_sab_result.track_borrow_slot_release_temp);

    try std.testing.expectEqual(RefCellHandleBindingAction.ordinary_binding, planRefCellHandleBinding(false));
    try std.testing.expectEqual(RefCellHandleBindingAction.bind_borrow_handle, planRefCellHandleBinding(true));
    try std.testing.expectEqual(RefCellHandleTransferAction.transfer_value_state, planRefCellHandleTransfer(false));
    try std.testing.expectEqual(RefCellHandleTransferAction.move_borrow_handle, planRefCellHandleTransfer(true));

    const plain_value_transfer = planRefCellValueStateTransfer(false, false);
    try std.testing.expectEqual(RefCellHandleTransferAction.transfer_value_state, plain_value_transfer.handle);
    try std.testing.expectEqual(BorrowAddressTempTransferAction.transfer_value_state, plain_value_transfer.borrow_address_temps);

    const borrow_value_transfer = planRefCellValueStateTransfer(true, true);
    try std.testing.expectEqual(RefCellHandleTransferAction.move_borrow_handle, borrow_value_transfer.handle);
    try std.testing.expectEqual(BorrowAddressTempTransferAction.move_borrow_address_temps, borrow_value_transfer.borrow_address_temps);

    const plain_release = planRefCellHandleRelease(false);
    try std.testing.expect(plain_release.release_dynamic_borrow);
    try std.testing.expect(plain_release.consume_handle_value);
    try std.testing.expect(!plain_release.release_owner_temps);

    const temp_release = planRefCellHandleRelease(true);
    try std.testing.expect(temp_release.release_dynamic_borrow);
    try std.testing.expect(temp_release.consume_handle_value);
    try std.testing.expect(temp_release.release_owner_temps);

    try std.testing.expectEqual(RefCellHandleCellReleaseAction.skip, planRefCellHandleCellRelease(false, false));
    try std.testing.expectEqual(RefCellHandleCellReleaseAction.skip, planRefCellHandleCellRelease(true, true));
    try std.testing.expectEqual(RefCellHandleCellReleaseAction.release_handle, planRefCellHandleCellRelease(true, false));
    try std.testing.expectEqual(RefCellHandleOwnerTransferAction.keep_owner, planRefCellHandleOwnerTransfer(false));
    try std.testing.expectEqual(RefCellHandleOwnerTransferAction.rebind_owner, planRefCellHandleOwnerTransfer(true));

    try std.testing.expectEqual(RefCellCallArgLifecycleAction.keep, planRefCellCallArgLifecycle(false, true));
    try std.testing.expectEqual(RefCellCallArgLifecycleAction.release_value, planRefCellCallArgLifecycle(true, false));
    try std.testing.expectEqual(RefCellCallArgLifecycleAction.release_borrow_handle, planRefCellCallArgLifecycle(true, true));
    try std.testing.expect(!planRefCellCallArgLifecycle(false, true).shouldRelease());
    try std.testing.expect(planRefCellCallArgLifecycle(true, false).shouldRelease());
    try std.testing.expect(!planRefCellCallArgLifecycle(true, false).releasesBorrowHandle());
    try std.testing.expect(planRefCellCallArgLifecycle(true, true).releasesBorrowHandle());
    try std.testing.expectEqual(DerefAssignmentTargetLifecycleAction.keep, planDerefAssignmentTargetLifecycle(false, true));
    try std.testing.expectEqual(DerefAssignmentTargetLifecycleAction.release_value, planDerefAssignmentTargetLifecycle(true, false));
    try std.testing.expectEqual(DerefAssignmentTargetLifecycleAction.release_borrow_handle, planDerefAssignmentTargetLifecycle(true, true));

    const companion_plain = planRefCellCompanionStoreCleanup(false, false, false);
    try std.testing.expect(companion_plain.consume_handle_value);
    try std.testing.expect(!companion_plain.release_owner_temps);
    try std.testing.expect(!companion_plain.release_borrow_address_temps);
    try std.testing.expect(!companion_plain.clear_non_owning_metadata);

    const companion_full = planRefCellCompanionStoreCleanup(true, true, true);
    try std.testing.expect(companion_full.consume_handle_value);
    try std.testing.expect(companion_full.release_owner_temps);
    try std.testing.expect(companion_full.release_borrow_address_temps);
    try std.testing.expect(companion_full.clear_non_owning_metadata);

    const companion_restore = planRefCellCompanionRestore();
    try std.testing.expect(companion_restore.track_loaded_cell_owner_temp);
    try std.testing.expect(companion_restore.release_companion_slot_after_restore);

    try std.testing.expectEqual(RefCellBranchStateMergeAction.keep_current, planRefCellBranchStateMerge(false, false));
    try std.testing.expectEqual(RefCellBranchStateMergeAction.restore_else, planRefCellBranchStateMerge(true, false));
    try std.testing.expectEqual(RefCellBranchStateMergeAction.restore_then, planRefCellBranchStateMerge(false, true));
    try std.testing.expectEqual(RefCellBranchStateMergeAction.restore_pre, planRefCellBranchStateMerge(true, true));
    try std.testing.expectEqual(RefCellBranchHandleOwnerMergeAction.keep_static_owner, planRefCellBranchHandleOwnerMerge(false, true, true, false));
    try std.testing.expectEqual(RefCellBranchHandleOwnerMergeAction.keep_static_owner, planRefCellBranchHandleOwnerMerge(true, true, false, false));
    try std.testing.expectEqual(RefCellBranchHandleOwnerMergeAction.keep_static_owner, planRefCellBranchHandleOwnerMerge(true, true, true, true));
    try std.testing.expectEqual(RefCellBranchHandleOwnerMergeAction.merge_dynamic_owner, planRefCellBranchHandleOwnerMerge(true, true, true, false));
    try std.testing.expectEqual(RefCellLoopStateMergeAction.restore_pre_loop, planRefCellLoopStateMerge());
}

test "shared refcell runtime scanner detects constructor and receiver calls" {
    var tc = type_checker.TypeChecker.init(std.testing.allocator);
    defer tc.deinit();

    var i64_ty = ast.Type{ .primitive = .i64 };
    const refcell_generics = [_]*ast.Type{&i64_ty};
    var refcell_i64_ty = ast.Type{ .user_defined = .{ .name = "RefCell", .generics = refcell_generics[0..] } };

    var value = ast.Node{ .identifier = "value" };
    const new_args = [_]*ast.Node{&value};
    var new_call = ast.Node{ .call_expr = .{ .func_name = "new", .associated_target = "RefCell", .generics = &.{}, .args = new_args[0..] } };
    var new_stmt = ast.Node{ .expr_stmt = &new_call };
    const new_body = [_]*ast.Node{&new_stmt};
    var new_test = ast.Node{ .test_decl = .{ .name = "refcell new", .is_ignored = false, .should_panic = false, .body = new_body[0..] } };
    const new_decls = [_]*ast.Node{&new_test};
    var new_program = ast.Node{ .program = .{ .decls = new_decls[0..] } };

    try std.testing.expect(programNeedsRefCellRuntime(&tc, &new_program));

    var cell = ast.Node{ .identifier = "cell" };
    try tc.expr_types.put(&cell, &refcell_i64_ty);
    const borrow_args = [_]*ast.Node{&cell};
    var borrow_call = ast.Node{ .call_expr = .{ .func_name = "borrow", .associated_target = null, .generics = &.{}, .args = borrow_args[0..] } };
    try std.testing.expect(exprNeedsRefCellRuntime(&tc, &borrow_call));

    var plain_call = ast.Node{ .call_expr = .{ .func_name = "noop", .associated_target = null, .generics = &.{}, .args = &.{} } };
    try std.testing.expect(!exprNeedsRefCellRuntime(&tc, &plain_call));

    var plain_option = ast.Node{ .identifier = "maybe" };
    var chain_value = ast.Node{ .identifier = "chain_value" };
    const chain_new_args = [_]*ast.Node{&chain_value};
    var chain_new_call = ast.Node{ .call_expr = .{ .func_name = "new", .associated_target = "RefCell", .generics = &.{}, .args = chain_new_args[0..] } };
    const some_pattern = ast.EnumPattern{ .enum_name = "Option", .variant_name = "Some", .bindings = &.{} };
    const if_let_chain = [_]ast.IfLetCond{
        .{ .pattern = some_pattern, .value = &plain_option },
        .{ .pattern = some_pattern, .value = &chain_new_call },
    };
    const empty_then = [_]*ast.Node{};
    var if_let_expr = ast.Node{ .if_expr = .{ .cond = &plain_option, .let_chain = if_let_chain[0..], .then_block = empty_then[0..], .else_block = null } };
    try std.testing.expect(exprNeedsRefCellRuntime(&tc, &if_let_expr));
}

test "shared dyn coercion and receiver plans" {
    var concrete_ty = ast.Type{ .user_defined = .{ .name = "Sprite", .generics = &.{} } };
    var i32_ty = ast.Type{ .primitive = .i32 };
    var dyn_ty = ast.Type{ .user_defined = .{ .name = "__dyn_Draw", .generics = &.{} } };
    const box_i32_generics = [_]*ast.Type{&i32_ty};
    const box_concrete_generics = [_]*ast.Type{&concrete_ty};
    var box_i32_ty = ast.Type{ .user_defined = .{ .name = "Box", .generics = box_i32_generics[0..] } };
    const box_box_i32_generics = [_]*ast.Type{&box_i32_ty};
    var box_concrete_ty = ast.Type{ .user_defined = .{ .name = "Box", .generics = box_concrete_generics[0..] } };
    var box_box_i32_ty = ast.Type{ .user_defined = .{ .name = "Box", .generics = box_box_i32_generics[0..] } };
    const rc_generics = [_]*ast.Type{&dyn_ty};
    const box_generics = [_]*ast.Type{&dyn_ty};
    const rc_box_generics = [_]*ast.Type{&box_i32_ty};
    var rc_dyn_ty = ast.Type{ .user_defined = .{ .name = "Rc", .generics = rc_generics[0..] } };
    var box_dyn_ty = ast.Type{ .user_defined = .{ .name = "Box", .generics = box_generics[0..] } };
    var rc_box_ty = ast.Type{ .user_defined = .{ .name = "Rc", .generics = rc_box_generics[0..] } };
    var borrowed_dyn_ty = ast.Type{ .borrow = &dyn_ty };

    const rc_plan = planDynDispatchReceiver(&rc_dyn_ty) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(DynDispatchReceiverKind.rc_get_dyn, rc_plan.kind);
    const box_plan = planDynDispatchReceiver(&box_dyn_ty) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(DynDispatchReceiverKind.direct_dyn, box_plan.kind);
    const borrowed_plan = planDynDispatchReceiver(&borrowed_dyn_ty) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(DynDispatchReceiverKind.direct_dyn, borrowed_plan.kind);
    try std.testing.expect(smartPointerDerefIsDynBox(&box_dyn_ty));
    try std.testing.expect(!smartPointerDerefIsDynBox(&rc_dyn_ty));
    try std.testing.expect(planDynDispatchReceiver(&concrete_ty) == null);
    try std.testing.expectEqual(SmartPointerAddressAction.dyn_box_identity, planSmartPointerAddressAction(&box_dyn_ty));
    try std.testing.expectEqual(SmartPointerAddressAction.as_ptr_slot, planSmartPointerAddressAction(&box_i32_ty));
    try std.testing.expectEqual(SmartPointerAddressAction.as_ptr_take_pointer_backed_value, planSmartPointerAddressAction(&box_concrete_ty));
    try std.testing.expectEqual(SmartPointerAddressAction.as_ptr_slot, planSmartPointerAddressAction(&rc_box_ty));
    try std.testing.expectEqual(SmartPointerAddressAction.unsupported, planSmartPointerAddressAction(&concrete_ty));
    try std.testing.expect(planSmartPointerAddressAction(&box_dyn_ty).isDynBoxIdentity());
    try std.testing.expect(planSmartPointerAddressAction(&box_concrete_ty).isAsPtrTakePointerBackedValue());
    try std.testing.expectEqual(SmartPointerValueSlotAction.as_ptr_slot, planSmartPointerValueSlotAction(&box_box_i32_ty));
    try std.testing.expectEqual(SmartPointerValueSlotAction.unsupported, planSmartPointerValueSlotAction(&box_i32_ty));
    try std.testing.expectEqual(SmartPointerGetAction.dyn_box_identity, planSmartPointerGetAction(&box_dyn_ty));
    try std.testing.expectEqual(SmartPointerGetAction.get_value, planSmartPointerGetAction(&box_i32_ty));
    try std.testing.expectEqual(SmartPointerGetAction.unsupported, planSmartPointerGetAction(&concrete_ty));

    var rc_expr = ast.Node{ .identifier = "make_rc" };
    var box_expr = ast.Node{ .identifier = "make_box" };
    var tc = type_checker.TypeChecker.init(std.testing.allocator);
    defer tc.deinit();
    try tc.dyn_rc_coercions.put(&rc_expr, "Draw");
    try tc.dyn_box_coercions.put(&box_expr, "Draw");

    const rc_coercion = planDynCoercion(&tc, &rc_expr) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(DynCoercionKind.rc_new_to_dyn_rc, rc_coercion.kind);
    try std.testing.expect(rc_coercion.isRcNewToDynRc());
    try std.testing.expect(!rc_coercion.isBoxToDyn());
    try std.testing.expectEqualSlices(u8, "Draw", rc_coercion.trait_name);
    const box_coercion = planDynCoercion(&tc, &box_expr) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(DynCoercionKind.box_to_dyn, box_coercion.kind);
    try std.testing.expect(box_coercion.isBoxToDyn());
    try std.testing.expect(!box_coercion.isRcNewToDynRc());
    try std.testing.expectEqualSlices(u8, "Draw", box_coercion.trait_name);
}

test "shared function tail cleanup transfers only the direct result binding" {
    var result = ast.Node{ .identifier = "result" };
    var other = ast.Node{ .identifier = "other" };
    var moved_result = ast.Node{ .move_expr = .{ .expr = &result } };
    var field = ast.Node{ .field_expr = .{ .expr = &result, .field_name = "value" } };

    try std.testing.expectEqual(FunctionTailCleanupAction.transfer_result, planFunctionTailCleanup("result", &result));
    try std.testing.expectEqual(FunctionTailCleanupAction.transfer_result, planFunctionTailCleanup("result", &moved_result));
    try std.testing.expectEqual(FunctionTailCleanupAction.release, planFunctionTailCleanup("other", &result));
    try std.testing.expectEqual(FunctionTailCleanupAction.release, planFunctionTailCleanup("result", &other));
    try std.testing.expectEqual(FunctionTailCleanupAction.release, planFunctionTailCleanup("result", &field));
}

test "shared repeated let binding scanner isolates sibling loop locals" {
    var zero = ast.Node{ .literal = .{ .int_val = 0 } };
    var first_let = ast.Node{ .let_stmt = .{ .name = "c", .ty = null, .value = &zero } };
    const first_body = [_]*ast.Node{&first_let};
    var first_cond = ast.Node{ .literal = .{ .bool_val = true } };
    var first_loop = ast.Node{ .while_stmt = .{ .cond = &first_cond, .let_pattern = null, .body = first_body[0..] } };

    var second_let = ast.Node{ .let_stmt = .{ .name = "c", .ty = null, .value = &zero } };
    const second_body = [_]*ast.Node{&second_let};
    var second_cond = ast.Node{ .literal = .{ .bool_val = true } };
    var second_loop = ast.Node{ .while_stmt = .{ .cond = &second_cond, .let_pattern = null, .body = second_body[0..] } };

    var unique_let = ast.Node{ .let_stmt = .{ .name = "only_once", .ty = null, .value = &zero } };
    const body = [_]*ast.Node{ &first_loop, &second_loop, &unique_let };
    var repeated = std.StringHashMap(void).init(std.testing.allocator);
    defer repeated.deinit();

    try collectRepeatedLetBindings(std.testing.allocator, body[0..], &repeated);
    try std.testing.expect(repeated.contains("c"));
    try std.testing.expect(!repeated.contains("only_once"));
}

test "shared static call plan preserves namespace alias metadata" {
    var tc = type_checker.TypeChecker.init(std.testing.allocator);
    defer tc.deinit();

    var call_node = ast.Node{ .call_expr = .{
        .func_name = "dep__imported_a",
        .associated_target = null,
        .generics = &.{},
        .args = &.{},
    } };
    try tc.resolved_call_symbols.put(&call_node, "imported_a");
    try tc.resolved_call_alias_metadata.put(&call_node, .{
        .alias = "dep__imported_a",
        .target = "imported_a",
        .namespace = "dep",
        .module_path = "/tmp/dep.sla",
    });

    const plan = planResolvedStaticCall(&tc, &call_node, call_node.call_expr) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("imported_a", plan.target_symbol);
    try std.testing.expectEqual(@as(usize, 0), plan.arg_count);
    try std.testing.expect(plan.alias_metadata != null);
    try std.testing.expectEqualStrings("dep__imported_a", plan.alias_metadata.?.alias);
    try std.testing.expectEqualStrings("imported_a", plan.alias_metadata.?.target);
    try std.testing.expectEqualStrings("dep", plan.alias_metadata.?.namespace.?);
    try std.testing.expectEqualStrings("/tmp/dep.sla", plan.alias_metadata.?.module_path.?);
    try std.testing.expectEqualStrings("dep__imported_a", staticCallEmitSymbol(plan));
    try std.testing.expectEqualStrings("dep__imported_a", resolveStaticCallSymbol(&tc, &call_node, call_node.call_expr).?);

    var void_ty = ast.Type{ .primitive = .void_type };
    const lowering = planStaticCallLowering(&tc, &call_node, call_node.call_expr, &void_ty) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("dep__imported_a", staticCallEmitSymbol(lowering.call));
    try std.testing.expect(lowering.result.returns_void);
}

test "shared scalar binary plan selects unsigned high bit operations" {
    var u64_ty = ast.Type{ .primitive = .u64 };
    var i64_ty = ast.Type{ .primitive = .i64 };

    try std.testing.expectEqual(ScalarBinaryOp.udiv, planScalarBinaryOp(.div, &u64_ty, &u64_ty).?);
    try std.testing.expectEqual(ScalarBinaryOp.urem, planScalarBinaryOp(.mod, &u64_ty, &u64_ty).?);
    try std.testing.expectEqual(ScalarBinaryOp.ult, planScalarBinaryOp(.lt, &u64_ty, &u64_ty).?);
    try std.testing.expectEqual(ScalarBinaryOp.ule, planScalarBinaryOp(.le, &u64_ty, &u64_ty).?);
    try std.testing.expectEqual(ScalarBinaryOp.ugt, planScalarBinaryOp(.gt, &u64_ty, &u64_ty).?);
    try std.testing.expectEqual(ScalarBinaryOp.uge, planScalarBinaryOp(.ge, &u64_ty, &u64_ty).?);
    try std.testing.expectEqual(ScalarBinaryOp.lshr, planScalarBinaryOp(.shr, &u64_ty, &u64_ty).?);

    try std.testing.expectEqual(ScalarBinaryOp.sdiv, planScalarBinaryOp(.div, &i64_ty, &i64_ty).?);
    try std.testing.expectEqual(ScalarBinaryOp.srem, planScalarBinaryOp(.mod, &i64_ty, &i64_ty).?);
    try std.testing.expectEqual(ScalarBinaryOp.ashr, planScalarBinaryOp(.shr, &i64_ty, &i64_ty).?);
    try std.testing.expectEqual(ScalarBinaryOp.ashr, planScalarBinaryOp(.shr, &i64_ty, &u64_ty).?);
    try std.testing.expectEqualStrings("udiv", scalarBinaryOpName(.udiv));
    try std.testing.expectEqualStrings("lshr", scalarBinaryOpName(.lshr));
}

test "shared value-arg ownership and fnptr slot plans" {
    try std.testing.expect(!planValueArgTransfersOwnership(.{
        .param_is_present = false,
        .param_is_borrow = false,
        .param_is_move = false,
        .param_is_by_value_raw_pointer = false,
        .arg_is_borrow_like = false,
        .arg_is_copy_value = false,
    }));
    try std.testing.expect(!planValueArgTransfersOwnership(.{
        .param_is_present = true,
        .param_is_borrow = true,
        .param_is_move = false,
        .param_is_by_value_raw_pointer = false,
        .arg_is_borrow_like = false,
        .arg_is_copy_value = false,
    }));
    try std.testing.expect(!planValueArgTransfersOwnership(.{
        .param_is_present = true,
        .param_is_borrow = false,
        .param_is_move = false,
        .param_is_by_value_raw_pointer = true,
        .arg_is_borrow_like = false,
        .arg_is_copy_value = false,
    }));
    try std.testing.expect(!planValueArgTransfersOwnership(.{
        .param_is_present = true,
        .param_is_borrow = false,
        .param_is_move = false,
        .param_is_by_value_raw_pointer = false,
        .arg_is_borrow_like = false,
        .arg_is_copy_value = true,
    }));
    try std.testing.expect(planValueArgTransfersOwnership(.{
        .param_is_present = true,
        .param_is_borrow = false,
        .param_is_move = false,
        .param_is_by_value_raw_pointer = false,
        .arg_is_borrow_like = false,
        .arg_is_copy_value = false,
    }));
    var plain_ty = ast.Type{ .user_defined = .{ .name = "Owned", .generics = &.{} } };
    const plain_param = ast.Param{ .name = "value", .ty = &plain_ty };
    try std.testing.expect(!valueArgTransfersOwnershipFromParam(null, null, false));
    try std.testing.expect(valueArgTransfersOwnershipFromParam(plain_param, &plain_ty, false));
    try std.testing.expect(!valueArgTransfersOwnershipFromParam(plain_param, &plain_ty, true));
    const borrow_param = ast.Param{ .name = "value", .ty = &plain_ty, .is_borrow = true };
    try std.testing.expect(!valueArgTransfersOwnershipFromParam(borrow_param, &plain_ty, false));

    try std.testing.expect(!planNeedsFnPtrValueArgSlot(.{
        .param_is_present = true,
        .param_is_borrow = false,
        .param_is_move = false,
        .param_ty_is_fn_ptr = false,
        .arg_ty_is_fn_ptr = true,
    }));
    try std.testing.expect(planNeedsFnPtrValueArgSlot(.{
        .param_is_present = true,
        .param_is_borrow = false,
        .param_is_move = false,
        .param_ty_is_fn_ptr = true,
        .arg_ty_is_fn_ptr = true,
    }));
    var fn_ret = ast.Type{ .primitive = .i32 };
    var fn_ty = ast.Type{ .fn_ptr = .{ .abi = null, .params = &.{}, .ret = &fn_ret } };
    const fn_param = ast.Param{ .name = "cb", .ty = &fn_ty };
    var fn_ident = ast.Node{ .identifier = "generated_cb" };
    var local_ident = ast.Node{ .identifier = "local_cb" };
    try std.testing.expect(identifierIsGeneratedFnPtr(&fn_ident, true, true));
    try std.testing.expect(!identifierIsGeneratedFnPtr(&fn_ident, false, true));
    try std.testing.expect(callArgIsGeneratedFnPtrValue(&fn_ident, fn_param, true, true));
    try std.testing.expect(!callArgIsGeneratedFnPtrValue(&fn_ident, fn_param, true, false));
    try std.testing.expect(callArgIsLocalFnPtrValue(&local_ident, fn_param, true, false, true));
    try std.testing.expect(!callArgIsLocalFnPtrValue(&local_ident, fn_param, true, true, true));
    try std.testing.expect(!callArgIsLocalFnPtrValue(&local_ident, fn_param, true, false, false));
    try std.testing.expect(identifierIsGeneratedScalarConst(&fn_ident, true));
    try std.testing.expect(!identifierIsGeneratedScalarConst(&fn_ident, false));
    try std.testing.expect(!identifierIsGeneratedScalarConst(&local_ident, false));

    var i32_ty = ast.Type{ .primitive = .i32 };
    try std.testing.expect(!vecElementPushTransfersOwnership(&i32_ty, true));
    try std.testing.expect(vecElementPushTransfersOwnership(&i32_ty, false));
}

test "shallowCopyCallArgFieldShouldRecurse classifies nested fields" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var gens = [_]*ast.Type{&i32_ty};
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = gens[0..] } };
    var foo_ty = ast.Type{ .user_defined = .{ .name = "Foo", .generics = &.{} } };
    var box_ty = ast.Type{ .user_defined = .{ .name = "Box", .generics = gens[0..] } };
    try std.testing.expect(shallowCopyCallArgFieldShouldRecurse(true, &foo_ty));
    try std.testing.expect(!shallowCopyCallArgFieldShouldRecurse(false, &foo_ty));
    try std.testing.expect(!shallowCopyCallArgFieldShouldRecurse(true, &vec_ty));
    try std.testing.expect(!shallowCopyCallArgFieldShouldRecurse(true, &box_ty));
    // Callers pass field_has_struct_decl=false for primitives; pure helper trusts that fact.
    try std.testing.expect(!shallowCopyCallArgFieldShouldRecurse(false, &i32_ty));
}

test "typeHasNamedDeriveBase classifies pure leaves" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var gens = [_]*ast.Type{&i32_ty};
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = gens[0..] } };
    var foo_ty = ast.Type{ .user_defined = .{ .name = "Foo", .generics = &.{} } };
    try std.testing.expect(typeHasNamedDeriveBase(&i32_ty, true).?);
    try std.testing.expect(!typeHasNamedDeriveBase(&i32_ty, false).?);
    try std.testing.expect(!typeHasNamedDeriveBase(&vec_ty, true).?);
    try std.testing.expect(typeHasNamedDeriveBase(&foo_ty, true) == null);

    var fields = [_]ast.Field{.{ .name = "x", .ty = &i32_ty }};
    var hash_derives = [_][]const u8{"Hash"};
    var good = ast.StructDecl{ .name = "Good", .generics = &.{}, .fields = fields[0..], .derives = hash_derives[0..], .is_union = false, .is_opaque = false };
    var opaque_decl = ast.StructDecl{ .name = "Opaque", .generics = &.{}, .fields = fields[0..], .derives = hash_derives[0..], .is_union = false, .is_opaque = true };
    try std.testing.expect(typeHasNamedDeriveStructGate(&good, "hash"));
    try std.testing.expect(!typeHasNamedDeriveStructGate(&opaque_decl, "hash"));
    try std.testing.expect(!typeHasNamedDeriveStructGate(&good, "debug"));
}

test "typeHasCopyDeriveBase classifies pure leaves" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var void_ty = ast.Type{ .primitive = .void_type };
    var gens = [_]*ast.Type{&i32_ty};
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = gens[0..] } };
    var foo_ty = ast.Type{ .user_defined = .{ .name = "Foo", .generics = &.{} } };
    try std.testing.expect(typeHasCopyDeriveBase(&i32_ty).?);
    try std.testing.expect(!typeHasCopyDeriveBase(&void_ty).?);
    try std.testing.expect(!typeHasCopyDeriveBase(&vec_ty).?);
    try std.testing.expect(typeHasCopyDeriveBase(&foo_ty) == null);

    var fields = [_]ast.Field{.{ .name = "x", .ty = &i32_ty }};
    var copy_derives = [_][]const u8{"Copy"};
    var good = ast.StructDecl{ .name = "Good", .generics = &.{}, .fields = fields[0..], .derives = copy_derives[0..], .is_union = false, .is_opaque = false };
    var opaque_decl = ast.StructDecl{ .name = "Opaque", .generics = &.{}, .fields = fields[0..], .derives = copy_derives[0..], .is_union = false, .is_opaque = true };
    try std.testing.expect(typeHasCopyDeriveStructGate(&good));
    try std.testing.expect(!typeHasCopyDeriveStructGate(&opaque_decl));
}

test "primitiveIsHashable and slotCopyStructTypeFact" {
    try std.testing.expect(primitiveIsHashable(.i32));
    try std.testing.expect(!primitiveIsHashable(.void_type));
    try std.testing.expect(!primitiveIsHashable(.f64));

    var i32_ty = ast.Type{ .primitive = .i32 };
    var user_ty = ast.Type{ .user_defined = .{ .name = "Foo", .generics = &.{} } };
    var ptr_ty = ast.Type{ .pointer = &user_ty };
    try std.testing.expect(slotCopyStructTypeFact(&user_ty, true, null, false) == &user_ty);
    try std.testing.expect(slotCopyStructTypeFact(&ptr_ty, false, &user_ty, true) == &user_ty);
    try std.testing.expect(slotCopyStructTypeFact(&ptr_ty, false, &user_ty, false) == null);
    try std.testing.expect(slotCopyStructTypeFact(&i32_ty, false, null, false) == null);
}

test "typeIsPointerScalarValue scalar slot and debugFormatSuffix" {
    var raw_ptr_ty = ast.Type{ .primitive = .raw_ptr };
    var i32_ty = ast.Type{ .primitive = .i32 };
    var u64_ty = ast.Type{ .primitive = .u64 };
    var f64_ty = ast.Type{ .primitive = .f64 };
    var bool_ty = ast.Type{ .primitive = .boolean };
    var ptr_ty = ast.Type{ .pointer = &i32_ty };
    var user_ty = ast.Type{ .user_defined = .{ .name = "Foo", .generics = &.{} } };

    try std.testing.expect(typeIsPointerScalarValue(&raw_ptr_ty));
    try std.testing.expect(typeIsPointerScalarValue(&ptr_ty));
    try std.testing.expect(!typeIsPointerScalarValue(&i32_ty));
    try std.testing.expect(!typeIsPointerScalarValue(&user_ty));

    try std.testing.expect(typeCanUseScalarReassignSlot(&i32_ty));
    try std.testing.expect(!typeCanUseScalarReassignSlot(&ptr_ty));
    try std.testing.expect(!typeCanUseScalarReassignSlot(&user_ty));

    try std.testing.expectEqualStrings("I64", debugFormatSuffix(&i32_ty).?);
    try std.testing.expectEqualStrings("U64", debugFormatSuffix(&u64_ty).?);
    try std.testing.expectEqualStrings("F64", debugFormatSuffix(&f64_ty).?);
    try std.testing.expectEqualStrings("BOOL", debugFormatSuffix(&bool_ty).?);
    try std.testing.expect(debugFormatSuffix(&raw_ptr_ty) == null);
    try std.testing.expect(debugFormatSuffix(&user_ty) == null);
}

test "abiCapKind and temporary register name facts" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var borrow_ty = ast.Type{ .borrow = &i32_ty };
    try std.testing.expect(abiCapKindFromType(&i32_ty) == .none);
    try std.testing.expect(abiCapKindFromType(&borrow_ty) == .borrow);
    try std.testing.expect(abiCapKindFromRawTypeString("&ptr") == .borrow);
    try std.testing.expect(abiCapKindFromRawTypeString("^ptr") == .move);
    try std.testing.expect(abiCapKindFromRawTypeString("*ptr") == .raw);
    try std.testing.expect(abiCapKindFromRawTypeString("i32") == .none);
    try std.testing.expect(isTemporaryRegisterName("tmp_0"));
    try std.testing.expect(isTemporaryRegisterName("tmp_12"));
    try std.testing.expect(!isTemporaryRegisterName("local"));
    try std.testing.expect(!isTemporaryRegisterName("tm_0"));
    try std.testing.expectEqualStrings("&ptr", abiReturnTypeString(&borrow_ty));
    try std.testing.expectEqualStrings("i32", abiReturnTypeString(&i32_ty));
    try std.testing.expectEqualStrings("u8", abiRawPayloadTypeString("bool"));
    try std.testing.expectEqualStrings("i64", abiRawPayloadTypeString("^int"));
}

test "abiCallArgCapKind and pointerOrBorrowPointee" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var ptr_ty = ast.Type{ .pointer = &i32_ty };
    var borrow_ty = ast.Type{ .borrow = &i32_ty };
    try std.testing.expect(abiCallArgCapKind(true, false) == .borrow);
    try std.testing.expect(abiCallArgCapKind(false, true) == .move);
    try std.testing.expect(abiCallArgCapKind(false, false) == .none);
    try std.testing.expect(abiCallArgCapKind(true, true) == .borrow);
    try std.testing.expect(pointerOrBorrowPointee(&ptr_ty) == &i32_ty);
    try std.testing.expect(pointerOrBorrowPointee(&borrow_ty) == &i32_ty);
    try std.testing.expect(pointerOrBorrowPointee(&i32_ty) == null);
}

test "primitive integer float and pointer value classifiers" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var f64_ty = ast.Type{ .primitive = .f64 };
    var bool_ty = ast.Type{ .primitive = .boolean };
    var raw_ptr_ty = ast.Type{ .primitive = .raw_ptr };
    var void_ty = ast.Type{ .primitive = .void_type };
    var ptr_ty = ast.Type{ .pointer = &i32_ty };

    try std.testing.expect(isPrimitiveType(&i32_ty, .i32));
    try std.testing.expect(!isPrimitiveType(&i32_ty, .u32));
    try std.testing.expect(isIntegerPrimitive(.usize));
    try std.testing.expect(!isIntegerPrimitive(.f32));
    try std.testing.expect(isFloatPrimitive(.float));
    try std.testing.expect(!isFloatPrimitive(.i32));
    try std.testing.expect(isAnyIntegerType(&i32_ty));
    try std.testing.expect(isAnyFloatType(&f64_ty));
    try std.testing.expect(isNumericType(&i32_ty));
    try std.testing.expect(isNumericType(&f64_ty));
    try std.testing.expect(!isNumericType(&bool_ty));
    try std.testing.expect(isCellValueType(&i32_ty));
    try std.testing.expect(isCellValueType(&bool_ty));
    try std.testing.expect(!isCellValueType(&void_ty));
    try std.testing.expect(isPollScalarValueType(&i32_ty));
    try std.testing.expect(!isPollScalarValueType(&bool_ty));
    try std.testing.expect(isPointerValueType(&ptr_ty));
    try std.testing.expect(isPointerValueType(&raw_ptr_ty));
    try std.testing.expect(!isPointerValueType(&void_ty));
    try std.testing.expect(!isPointerValueType(&i32_ty));
    try std.testing.expect(isPointerCarrierCastType(&ptr_ty));
    try std.testing.expect(isPointerCarrierCastType(&raw_ptr_ty));
    try std.testing.expect(!isPointerCarrierCastType(&void_ty));
}

test "structFieldsAllNumeric and comparable" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var void_ty = ast.Type{ .primitive = .void_type };
    var fields = [_]ast.Field{ .{ .name = "x", .ty = &i32_ty }, .{ .name = "y", .ty = &i32_ty } };
    var good = ast.StructDecl{ .name = "Good", .generics = &.{}, .fields = fields[0..], .derives = &.{}, .is_union = false, .is_opaque = false };
    var void_fields = [_]ast.Field{.{ .name = "x", .ty = &void_ty }};
    var with_void = ast.StructDecl{ .name = "Voidish", .generics = &.{}, .fields = void_fields[0..], .derives = &.{}, .is_union = false, .is_opaque = false };
    var opaque_decl = ast.StructDecl{ .name = "Opaque", .generics = &.{}, .fields = fields[0..], .derives = &.{}, .is_union = false, .is_opaque = true };
    try std.testing.expect(structFieldsAllNumeric(&good));
    try std.testing.expect(structFieldsAllComparable(&good));
    try std.testing.expect(!structFieldsAllNumeric(&with_void));
    try std.testing.expect(!structFieldsAllComparable(&with_void));
    try std.testing.expect(!structFieldsAllNumeric(&opaque_decl));
    try std.testing.expect(!structFieldsAllComparable(&opaque_decl));

    var zero = ast.Node{ .literal = .{ .int_val = 0 } };
    var one = ast.Node{ .literal = .{ .int_val = 1 } };
    try std.testing.expect(literalZero(&zero));
    try std.testing.expect(!literalZero(&one));
}

test "isDiscardName and isThreadSpawnCall" {
    try std.testing.expect(isDiscardName("_"));
    try std.testing.expect(!isDiscardName("x"));
    try std.testing.expect(!isDiscardName("__"));

    var dummy: ast.Node = undefined;
    var args = [_]*ast.Node{&dummy};
    const spawn = ast.CallExpr{
        .func_name = "spawn",
        .args = args[0..],
        .associated_target = "thread",
        .generics = &.{},
    };
    try std.testing.expect(isThreadSpawnCall(spawn));
    const not_spawn = ast.CallExpr{
        .func_name = "join",
        .args = args[0..],
        .associated_target = "thread",
        .generics = &.{},
    };
    try std.testing.expect(!isThreadSpawnCall(not_spawn));
    const bare = ast.CallExpr{
        .func_name = "spawn",
        .args = args[0..],
        .associated_target = null,
        .generics = &.{},
    };
    try std.testing.expect(!isThreadSpawnCall(bare));
}

test "isStdMacroTemplate arg classifiers" {
    try std.testing.expect(isStdMacroTemplateIntegerArg("0"));
    try std.testing.expect(isStdMacroTemplateIntegerArg("-12"));
    try std.testing.expect(!isStdMacroTemplateIntegerArg("-"));
    try std.testing.expect(!isStdMacroTemplateIntegerArg("1a"));
    try std.testing.expect(isStdMacroTemplateIdentArg("tmp_0"));
    try std.testing.expect(isStdMacroTemplateIdentArg("_x"));
    try std.testing.expect(!isStdMacroTemplateIdentArg("1x"));
    try std.testing.expect(!isStdMacroTemplateIdentArg("a-b"));
    try std.testing.expect(isStdMacroTemplateArgSafe("42"));
    try std.testing.expect(isStdMacroTemplateArgSafe("foo"));
    try std.testing.expect(!isStdMacroTemplateArgSafe(""));
    try std.testing.expect(!isStdMacroTemplateArgSafe("a b"));
}

test "isIdentChar" {
    try std.testing.expect(isIdentChar('a'));
    try std.testing.expect(isIdentChar('Z'));
    try std.testing.expect(isIdentChar('0'));
    try std.testing.expect(isIdentChar('_'));
    try std.testing.expect(!isIdentChar('-'));
    try std.testing.expect(!isIdentChar(' '));
    try std.testing.expect(!isIdentChar('@'));
}

test "isSwitchDefaultPattern and stack_alloc peels" {
    var default_pat = ast.Node{ .identifier = "default" };
    var other_pat = ast.Node{ .identifier = "x" };
    try std.testing.expect(isSwitchDefaultPattern(&default_pat));
    try std.testing.expect(!isSwitchDefaultPattern(&other_pat));

    const bare = ast.CallExpr{
        .func_name = "stack_alloc",
        .args = &.{},
        .associated_target = null,
        .generics = &.{},
    };
    try std.testing.expect(isStackAllocCall(bare));
    const associated = ast.CallExpr{
        .func_name = "stack_alloc",
        .args = &.{},
        .associated_target = "mem",
        .generics = &.{},
    };
    try std.testing.expect(!isStackAllocCall(associated));
    var node = ast.Node{ .call_expr = bare };
    try std.testing.expect(isStackAllocNode(&node));
    try std.testing.expect(!isStackAllocNode(&default_pat));
}

test "isInternalSymbol and isOrderingName" {
    try std.testing.expect(isInternalSymbol("return_ty_sentinel"));
    try std.testing.expect(!isInternalSymbol("return"));
    try std.testing.expect(isOrderingName("Ordering::SeqCst"));
    try std.testing.expect(isOrderingName("Ordering::AcqRel"));
    try std.testing.expect(!isOrderingName("Ordering"));
    try std.testing.expect(!isOrderingName("SeqCst"));
}

test "isNonOwningPointerCarrierCastArg" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var ptr_ty = ast.Type{ .pointer = &i32_ty };
    var ident = ast.Node{ .identifier = "p" };
    var cast_ok = ast.Node{ .cast_expr = .{ .expr = &ident, .ty = &ptr_ty } };
    var cast_bad = ast.Node{ .cast_expr = .{ .expr = &ident, .ty = &i32_ty } };
    try std.testing.expect(isNonOwningPointerCarrierCastArg(&cast_ok));
    try std.testing.expect(!isNonOwningPointerCarrierCastArg(&cast_bad));
    try std.testing.expect(!isNonOwningPointerCarrierCastArg(&ident));
}

test "isPointerAbiTypeName isIntegerAbiTypeName and isPanicBuiltinCall" {
    try std.testing.expect(isPointerAbiTypeName("^i32"));
    try std.testing.expect(isPointerAbiTypeName(" &u8"));
    try std.testing.expect(isPointerAbiTypeName("*void"));
    try std.testing.expect(!isPointerAbiTypeName("i32"));
    try std.testing.expect(isIntegerAbiTypeName("i32"));
    try std.testing.expect(isIntegerAbiTypeName("usize"));
    try std.testing.expect(!isIntegerAbiTypeName("f64"));
    try std.testing.expect(!isIntegerAbiTypeName("^i32"));

    try std.testing.expect(isPanicBuiltinName("panic"));
    try std.testing.expect(isPanicBuiltinName("panic_msg"));
    try std.testing.expect(!isPanicBuiltinName("println"));
    const panic = ast.CallExpr{
        .func_name = "panic",
        .args = &.{},
        .associated_target = null,
        .generics = &.{},
    };
    try std.testing.expect(isPanicBuiltinCall(panic));
    const panic_msg = ast.CallExpr{
        .func_name = "panic_msg",
        .args = &.{},
        .associated_target = null,
        .generics = &.{},
    };
    try std.testing.expect(isPanicBuiltinCall(panic_msg));
    const associated = ast.CallExpr{
        .func_name = "panic",
        .args = &.{},
        .associated_target = "std",
        .generics = &.{},
    };
    try std.testing.expect(!isPanicBuiltinCall(associated));
}

test "Option and Result constructor peels" {
    try std.testing.expect(isOptionNoneName("None"));
    try std.testing.expect(!isOptionNoneName("Some"));

    const some = ast.CallExpr{
        .func_name = "Some",
        .args = &.{},
        .associated_target = null,
        .generics = &.{},
    };
    try std.testing.expect(isOptionSomeCall(some));
    const ok = ast.CallExpr{
        .func_name = "Ok",
        .args = &.{},
        .associated_target = null,
        .generics = &.{},
    };
    try std.testing.expect(isResultOkCall(ok));
    try std.testing.expect(isResultConstructorCall(ok));
    const err = ast.CallExpr{
        .func_name = "Err",
        .args = &.{},
        .associated_target = null,
        .generics = &.{},
    };
    try std.testing.expect(isResultErrCall(err));
    try std.testing.expect(isResultConstructorCall(err));
    const not_ctor = ast.CallExpr{
        .func_name = "unwrap",
        .args = &.{},
        .associated_target = null,
        .generics = &.{},
    };
    try std.testing.expect(!isResultOkCall(not_ctor));
    try std.testing.expect(!isResultConstructorCall(not_ctor));
    try std.testing.expect(!isOptionSomeCall(not_ctor));
}

test "ptr null and read_volatile peels" {
    try std.testing.expect(isPtrNullBuiltinName("ptr__null"));
    try std.testing.expect(isPtrNullBuiltinName("std__ptr__null"));
    try std.testing.expect(!isPtrNullBuiltinName("null"));
    try std.testing.expect(isPtrReadVolatileBuiltinName("ptr__read_volatile"));
    try std.testing.expect(isPtrReadVolatileBuiltinName("std__ptr__read_volatile"));

    const bare_null = ast.CallExpr{
        .func_name = "ptr__null",
        .args = &.{},
        .associated_target = null,
        .generics = &.{},
    };
    try std.testing.expect(isPtrNullCall(bare_null));
    try std.testing.expect(callNeedsPtrMacros(bare_null));
    const associated_null = ast.CallExpr{
        .func_name = "null",
        .args = &.{},
        .associated_target = "ptr",
        .generics = &.{},
    };
    try std.testing.expect(callNeedsPtrMacros(associated_null));
    const unrelated = ast.CallExpr{
        .func_name = "println",
        .args = &.{},
        .associated_target = null,
        .generics = &.{},
    };
    try std.testing.expect(!callNeedsPtrMacros(unrelated));
}

test "std builtin call peels" {
    const println = ast.CallExpr{
        .func_name = "println",
        .args = &.{},
        .associated_target = null,
        .generics = &.{},
    };
    try std.testing.expect(isPrintlnCall(println));
    try std.testing.expect(isHashCall(.{ .func_name = "hash", .args = &.{}, .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isDebugCall(.{ .func_name = "debug", .args = &.{}, .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isStrEqCall(.{ .func_name = "str_eq", .args = &.{}, .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isBareVecCall(.{ .func_name = "vec", .args = &.{}, .associated_target = null, .generics = &.{} }));
    try std.testing.expect(!isBareVecCall(.{ .func_name = "vec", .args = &.{}, .associated_target = "std", .generics = &.{} }));

    var dummy: ast.Node = undefined;
    var one = [_]*ast.Node{&dummy};
    var two = [_]*ast.Node{ &dummy, &dummy };
    try std.testing.expect(isBareLenUnaryCall(.{ .func_name = "len", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(!isBareLenUnaryCall(.{ .func_name = "len", .args = two[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isBarePushBinaryCall(.{ .func_name = "push", .args = two[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isBarePopUnaryCall(.{ .func_name = "pop", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(!isBarePopUnaryCall(.{ .func_name = "pop", .args = one[0..], .associated_target = "Vec", .generics = &.{} }));
}

test "join unwrap clone and main peels" {
    try std.testing.expect(isMainName("main"));
    try std.testing.expect(!isMainName("Main"));
    var dummy: ast.Node = undefined;
    var one = [_]*ast.Node{&dummy};
    var two = [_]*ast.Node{ &dummy, &dummy };
    try std.testing.expect(isJoinCall(.{ .func_name = "join", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isBareJoinUnaryCall(.{ .func_name = "join", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(!isBareJoinUnaryCall(.{ .func_name = "join", .args = two[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isUnwrapCall(.{ .func_name = "unwrap", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isBareUnwrapUnaryCall(.{ .func_name = "unwrap", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isCloneCall(.{ .func_name = "clone", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isCloneUnaryCall(.{ .func_name = "clone", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(!isCloneUnaryCall(.{ .func_name = "clone", .args = two[0..], .associated_target = null, .generics = &.{} }));
}

test "option and result method peels" {
    var dummy: ast.Node = undefined;
    var one = [_]*ast.Node{&dummy};
    const some = ast.CallExpr{ .func_name = "is_some", .args = one[0..], .associated_target = null, .generics = &.{} };
    const none = ast.CallExpr{ .func_name = "is_none", .args = one[0..], .associated_target = null, .generics = &.{} };
    const ok = ast.CallExpr{ .func_name = "is_ok", .args = one[0..], .associated_target = null, .generics = &.{} };
    const err = ast.CallExpr{ .func_name = "is_err", .args = one[0..], .associated_target = null, .generics = &.{} };
    try std.testing.expect(isIsSomeCall(some));
    try std.testing.expect(isIsNoneCall(none));
    try std.testing.expect(isOptionQueryCall(some));
    try std.testing.expect(isOptionQueryCall(none));
    try std.testing.expect(isIsOkCall(ok));
    try std.testing.expect(isIsErrCall(err));
    try std.testing.expect(isResultQueryCall(ok));
    try std.testing.expect(isResultQueryCall(err));
    try std.testing.expect(isUnwrapOrCall(.{ .func_name = "unwrap_or", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isUnwrapOrElseCall(.{ .func_name = "unwrap_or_else", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isUnwrapOrDefaultCall(.{ .func_name = "unwrap_or_default", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isAndThenCall(.{ .func_name = "and_then", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isCopiedCall(.{ .func_name = "copied", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isMapCall(.{ .func_name = "map", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(!isOptionQueryCall(ok));
    try std.testing.expect(!isResultQueryCall(some));
}

test "collection atomic mpsc method peels" {
    var dummy: ast.Node = undefined;
    var one = [_]*ast.Node{&dummy};
    try std.testing.expect(isGetCall(.{ .func_name = "get", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isInsertCall(.{ .func_name = "insert", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isContainsCall(.{ .func_name = "contains", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isLoadCall(.{ .func_name = "load", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isStoreCall(.{ .func_name = "store", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isFetchAddCall(.{ .func_name = "fetch_add", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isCompareExchangeCall(.{ .func_name = "compare_exchange", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isAsPtrCall(.{ .func_name = "as_ptr", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isSendCall(.{ .func_name = "send", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isRecvCall(.{ .func_name = "recv", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isSetCall(.{ .func_name = "set", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isRemoveCall(.{ .func_name = "remove", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isPushBackCall(.{ .func_name = "push_back", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isPopFrontCall(.{ .func_name = "pop_front", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isMetadataCall(.{ .func_name = "metadata", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isPathMetadataCall(.{ .func_name = "metadata", .args = one[0..], .associated_target = "path", .generics = &.{} }));
    try std.testing.expect(!isPathMetadataCall(.{ .func_name = "metadata", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(!isGetCall(.{ .func_name = "set", .args = one[0..], .associated_target = null, .generics = &.{} }));
}

test "smart pointer mem mpsc iter peels" {
    var dummy: ast.Node = undefined;
    var one = [_]*ast.Node{&dummy};
    try std.testing.expect(isNewCall(.{ .func_name = "new", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isIntoRawCall(.{ .func_name = "into_raw", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isFromRawCall(.{ .func_name = "from_raw", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isIntoInnerCall(.{ .func_name = "into_inner", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isIterCall(.{ .func_name = "iter", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isIntoIterCall(.{ .func_name = "into_iter", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isIterOrIntoIterCall(.{ .func_name = "iter", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isIterOrIntoIterCall(.{ .func_name = "into_iter", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isMemForgetCall(.{ .func_name = "forget", .args = one[0..], .associated_target = "mem", .generics = &.{} }));
    try std.testing.expect(!isMemForgetCall(.{ .func_name = "forget", .args = one[0..], .associated_target = null, .generics = &.{} }));
    try std.testing.expect(isMpscChannelCall(.{ .func_name = "channel", .args = &.{}, .associated_target = "mpsc", .generics = &.{} }));
    try std.testing.expect(isManuallyDropNewCall(.{ .func_name = "new", .args = one[0..], .associated_target = "ManuallyDrop", .generics = &.{} }));
    try std.testing.expect(isManuallyDropIntoInnerCall(.{ .func_name = "into_inner", .args = one[0..], .associated_target = "ManuallyDrop", .generics = &.{} }));
    try std.testing.expect(isBoxNewCall(.{ .func_name = "new", .args = one[0..], .associated_target = "Box", .generics = &.{} }));
    try std.testing.expect(isBoxIntoRawCall(.{ .func_name = "into_raw", .args = one[0..], .associated_target = "Box", .generics = &.{} }));
    try std.testing.expect(isBoxFromRawCall(.{ .func_name = "from_raw", .args = one[0..], .associated_target = "Box", .generics = &.{} }));
    try std.testing.expect(isRcNewCall(.{ .func_name = "new", .args = one[0..], .associated_target = "Rc", .generics = &.{} }));
    try std.testing.expect(isArcNewCall(.{ .func_name = "new", .args = one[0..], .associated_target = "Arc", .generics = &.{} }));
    try std.testing.expect(!isBoxNewCall(.{ .func_name = "new", .args = one[0..], .associated_target = "Rc", .generics = &.{} }));
}

test "typeIsSmallPlainSlotStructDecl classifies small plain structs" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var fields = [_]ast.Field{.{ .name = "x", .ty = &i32_ty }};
    var good = ast.StructDecl{ .name = "Good", .generics = &.{}, .fields = fields[0..], .derives = &.{}, .is_union = false, .is_opaque = false };
    var opaque_decl = ast.StructDecl{ .name = "Opaque", .generics = &.{}, .fields = fields[0..], .derives = &.{}, .is_union = false, .is_opaque = true };
    var gens = [_]*ast.Type{&i32_ty};
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = gens[0..] } };
    var nested_fields = [_]ast.Field{.{ .name = "v", .ty = &vec_ty }};
    var nested = ast.StructDecl{ .name = "Nested", .generics = &.{}, .fields = nested_fields[0..], .derives = &.{}, .is_union = false, .is_opaque = false };
    try std.testing.expect(typeIsSmallPlainSlotStructDecl(&good));
    try std.testing.expect(!typeIsSmallPlainSlotStructDecl(&opaque_decl));
    try std.testing.expect(!typeIsSmallPlainSlotStructDecl(&nested));
}

test "typeIsCopyStructFact classifies composition" {
    try std.testing.expect(typeIsCopyStructFact(true, true));
    try std.testing.expect(!typeIsCopyStructFact(true, false));
    try std.testing.expect(!typeIsCopyStructFact(false, true));
    try std.testing.expect(!typeIsCopyStructFact(false, false));
}

test "typeIsCopyValueBase classifies pure leaves" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var void_ty = ast.Type{ .primitive = .void_type };
    var fn_ty = ast.Type{ .fn_ptr = .{ .abi = null, .params = &.{}, .ret = &i32_ty } };
    var gens = [_]*ast.Type{&i32_ty};
    var tuple_ty = ast.Type{ .tuple = .{ .elems = gens[0..] } };
    var user_ty = ast.Type{ .user_defined = .{ .name = "Foo", .generics = &.{} } };
    try std.testing.expect(typeIsCopyValueBase(&i32_ty).?);
    try std.testing.expect(!typeIsCopyValueBase(&void_ty).?);
    try std.testing.expect(typeIsCopyValueBase(&fn_ty).?);
    try std.testing.expect(typeIsCopyValueBase(&tuple_ty) == null);
    try std.testing.expect(typeIsCopyValueBase(&user_ty) == null);
}

test "shallowCopyCallArgUserDefinedBase classifies owners" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var gens = [_]*ast.Type{&i32_ty};
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = gens[0..] } };
    var box_ty = ast.Type{ .user_defined = .{ .name = "Box", .generics = gens[0..] } };
    var foo_ty = ast.Type{ .user_defined = .{ .name = "Foo", .generics = &.{} } };
    try std.testing.expect(!shallowCopyCallArgUserDefinedBase(&vec_ty, 0).?);
    try std.testing.expect(shallowCopyCallArgUserDefinedBase(&vec_ty, 1).?);
    try std.testing.expect(!shallowCopyCallArgUserDefinedBase(&box_ty, 0).?);
    try std.testing.expect(shallowCopyCallArgUserDefinedBase(&foo_ty, 0) == null);

    var fields = [_]ast.Field{.{ .name = "x", .ty = &i32_ty }};
    var good = ast.StructDecl{ .name = "Good", .generics = &.{}, .fields = fields[0..], .derives = &.{}, .is_union = false, .is_opaque = false };
    var opaque_decl = ast.StructDecl{ .name = "Opaque", .generics = &.{}, .fields = fields[0..], .derives = &.{}, .is_union = false, .is_opaque = true };
    try std.testing.expect(shallowCopyCallArgStructGate(&good));
    try std.testing.expect(!shallowCopyCallArgStructGate(&opaque_decl));
}

test "shallowCopyCallArgValueBase classifies pure leaves" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var ptr_ty = ast.Type{ .pointer = &i32_ty };
    var borrow_ty = ast.Type{ .borrow = &i32_ty };
    var fn_ty = ast.Type{ .fn_ptr = .{ .abi = null, .params = &.{}, .ret = &i32_ty } };
    var gens = [_]*ast.Type{&i32_ty};
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = gens[0..] } };
    var tuple_ty = ast.Type{ .tuple = .{ .elems = gens[0..] } };
    try std.testing.expect(shallowCopyCallArgValueBase(&i32_ty, 0).?);
    try std.testing.expect(shallowCopyCallArgValueBase(&ptr_ty, 0).?);
    try std.testing.expect(shallowCopyCallArgValueBase(&borrow_ty, 0).?);
    try std.testing.expect(shallowCopyCallArgValueBase(&fn_ty, 0).?);
    try std.testing.expect(!shallowCopyCallArgValueBase(&vec_ty, 0).?);
    try std.testing.expect(shallowCopyCallArgValueBase(&vec_ty, 1).?);
    try std.testing.expect(shallowCopyCallArgValueBase(&i32_ty, 9) == false);
    try std.testing.expect(shallowCopyCallArgValueBase(&tuple_ty, 0) == null);
}

test "userDefinedStdOwnerIsNonCopy classifies std owners" {
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = &.{} } };
    var i32_ty = ast.Type{ .primitive = .i32 };
    var foo_ty = ast.Type{ .user_defined = .{ .name = "Foo", .generics = &.{} } };
    try std.testing.expect(userDefinedStdOwnerIsNonCopy(&vec_ty));
    try std.testing.expect(!userDefinedStdOwnerIsNonCopy(&i32_ty));
    try std.testing.expect(!userDefinedStdOwnerIsNonCopy(&foo_ty));
}

test "collection type peelers" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var str_ty = ast.Type{ .primitive = .raw_ptr };
    var gens = [_]*ast.Type{&i32_ty};
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = gens[0..] } };
    var deque_ty = ast.Type{ .user_defined = .{ .name = "VecDeque", .generics = gens[0..] } };
    var set_ty = ast.Type{ .user_defined = .{ .name = "HashSet", .generics = gens[0..] } };
    var bset_ty = ast.Type{ .user_defined = .{ .name = "BTreeSet", .generics = gens[0..] } };
    var slice_ty = ast.Type{ .user_defined = .{ .name = "Slice", .generics = gens[0..] } };
    var map_gens = [_]*ast.Type{ &i32_ty, &str_ty };
    var map_ty = ast.Type{ .user_defined = .{ .name = "HashMap", .generics = map_gens[0..] } };
    var btree_ty = ast.Type{ .user_defined = .{ .name = "BTreeMap", .generics = map_gens[0..] } };
    try std.testing.expect(vecElementType(&vec_ty) == &i32_ty);
    try std.testing.expect(vecDequeElementType(&deque_ty) == &i32_ty);
    try std.testing.expect(hashSetElementType(&set_ty) == &i32_ty);
    try std.testing.expect(btreeSetElementType(&bset_ty) == &i32_ty);
    try std.testing.expect(sliceElementType(&slice_ty) == &i32_ty);
    const hm = hashMapTypes(&map_ty) orelse return error.TestExpectedEqual;
    try std.testing.expect(hm.key == &i32_ty);
    try std.testing.expect(hm.value == &str_ty);
    const bm = btreeMapTypes(&btree_ty) orelse return error.TestExpectedEqual;
    try std.testing.expect(bm.key == &i32_ty);
    try std.testing.expect(bm.value == &str_ty);
}

test "sync type peelers" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var gens = [_]*ast.Type{&i32_ty};
    var cell_ty = ast.Type{ .user_defined = .{ .name = "Cell", .generics = gens[0..] } };
    var mutex_ty = ast.Type{ .user_defined = .{ .name = "Mutex", .generics = gens[0..] } };
    var guard_ty = ast.Type{ .user_defined = .{ .name = "MutexGuard", .generics = gens[0..] } };
    try std.testing.expect(cellInnerType(&cell_ty) == &i32_ty);
    try std.testing.expect(mutexInnerType(&mutex_ty) == &i32_ty);
    try std.testing.expect(mutexGuardInnerType(&guard_ty) == &i32_ty);
}

test "keepsGenericUserDefinedName classifies std containers" {
    try std.testing.expect(keepsGenericUserDefinedName("Vec"));
    try std.testing.expect(keepsGenericUserDefinedName("HashMap"));
    try std.testing.expect(keepsGenericUserDefinedName("__dyn_Trait"));
    try std.testing.expect(!keepsGenericUserDefinedName("MyStruct"));
}

test "isStdCollectionType classifies std collections" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var gens = [_]*ast.Type{&i32_ty};
    var map_gens = [_]*ast.Type{ &i32_ty, &i32_ty };
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = gens[0..] } };
    var map_ty = ast.Type{ .user_defined = .{ .name = "HashMap", .generics = map_gens[0..] } };
    var foo_ty = ast.Type{ .user_defined = .{ .name = "Foo", .generics = &.{} } };
    try std.testing.expect(isStdCollectionType(&vec_ty));
    try std.testing.expect(isStdCollectionType(&map_ty));
    try std.testing.expect(!isStdCollectionType(&i32_ty));
    try std.testing.expect(!isStdCollectionType(&foo_ty));
}

test "primitiveIsCopyValue classifies void as non-copy" {
    try std.testing.expect(primitiveIsCopyValue(.i32));
    try std.testing.expect(primitiveIsCopyValue(.u64));
    try std.testing.expect(!primitiveIsCopyValue(.void_type));
}

test "isSmartPointerTypeName classifies box/rc/arc" {
    try std.testing.expect(isBoxTypeName("Box"));
    try std.testing.expect(isRcTypeName("Rc"));
    try std.testing.expect(isArcTypeName("Arc"));
    try std.testing.expect(isSmartPointerTypeName("Box"));
    try std.testing.expect(!isSmartPointerTypeName("Vec"));
    try std.testing.expectEqualStrings("sa_std/box.sa", smartPointerStdImportPath("Box").?);
}

test "typeBaseName and firstGenericArg peels" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var gens = [_]*ast.Type{&i32_ty};
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = gens[0..] } };
    var borrow = ast.Type{ .borrow = &vec_ty };
    try std.testing.expectEqualStrings("Vec", typeBaseName(&borrow).?);
    try std.testing.expect(firstGenericArg(&borrow) == &i32_ty);
}

test "userDefinedLocalName strips qualified type names" {
    try std.testing.expectEqualStrings("Sprite", userDefinedLocalName("ns.Sprite"));
    try std.testing.expectEqualStrings("Sprite", userDefinedLocalName("pkg::Sprite"));
    try std.testing.expectEqualStrings("Sprite", userDefinedLocalName("Sprite"));
    try std.testing.expectEqualStrings("Inner", userDefinedLocalName("outer.mid::Inner"));
}

test "shared spaceship plan classifies numeric and same-struct" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var u32_ty = ast.Type{ .primitive = .u32 };
    const numeric = planSpaceship(&i32_ty, &i32_ty, null, null) orelse return error.TestExpectedEqual;
    try std.testing.expect(numeric.isNumeric());
    try std.testing.expect(!numeric.isSameStruct());
    try std.testing.expect(!numeric.is_unsigned);
    const unsigned = planSpaceship(&u32_ty, &u32_ty, null, null) orelse return error.TestExpectedEqual;
    try std.testing.expect(unsigned.isNumeric());
    try std.testing.expect(unsigned.is_unsigned);

    var field_ty = ast.Type{ .primitive = .i32 };
    var fields = [_]ast.Field{.{ .name = "x", .ty = &field_ty }};
    var decl = ast.StructDecl{
        .name = "Point",
        .generics = &.{},
        .fields = fields[0..],
        .derives = &.{},
        .is_union = false,
        .is_opaque = false,
    };
    const same = planSpaceship(&i32_ty, &i32_ty, &decl, &decl) orelse return error.TestExpectedEqual;
    // numeric operands still win when both sides are numeric even if struct decls
    // are provided; same-struct requires non-numeric user types.
    try std.testing.expect(same.isNumeric());

    var point_ty = ast.Type{ .user_defined = .{ .name = "Point", .generics = &.{} } };
    const struct_plan = planSpaceship(&point_ty, &point_ty, &decl, &decl) orelse return error.TestExpectedEqual;
    try std.testing.expect(struct_plan.isSameStruct());
    try std.testing.expect(struct_plan.struct_decl == &decl);
    try std.testing.expect(planSpaceship(&point_ty, &point_ty, &decl, null) == null);
}

test "typeIsCopyValueLeaf classifies primitives and fnptrs" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var void_ty = ast.Type{ .primitive = .void_type };
    var fn_ty = ast.Type{ .fn_ptr = .{ .abi = null, .params = &.{}, .ret = &i32_ty } };
    try std.testing.expect(typeIsCopyValueLeaf(&i32_ty).?);
    try std.testing.expect(!typeIsCopyValueLeaf(&void_ty).?);
    try std.testing.expect(typeIsCopyValueLeaf(&fn_ty).?);
}

test "planParamCleanup releases by-value copy scalar params" {
    // By-value scalar params must be released in the epilogue: the SA-text
    // emitter always emits `!param` for them, and skipping the release left
    // SAB registers Active at exit (verifier MemoryLeak 1012) whenever a
    // parameter-taking function was emitted last.
    const by_value_copy = ParamCleanupFacts{
        .is_param = true,
        .capability = .by_value,
        .has_type = true,
        .abi_is_ptr = false,
        .is_copy_value = true,
    };
    try std.testing.expectEqual(ParamCleanupAction.release, planParamCleanup(by_value_copy));

    // By-value pointer-ABI params are still consumed (moved into their slot).
    const by_value_ptr = ParamCleanupFacts{
        .is_param = true,
        .capability = .by_value,
        .has_type = true,
        .abi_is_ptr = true,
        .is_copy_value = true,
    };
    try std.testing.expectEqual(ParamCleanupAction.consume, planParamCleanup(by_value_ptr));

    // Borrowed and raw/unknown-capability params keep their previous plans.
    const borrow_cap = ParamCleanupFacts{
        .is_param = true,
        .capability = .borrow,
        .has_type = true,
    };
    try std.testing.expectEqual(ParamCleanupAction.release, planParamCleanup(borrow_cap));
    const raw_cap = ParamCleanupFacts{
        .is_param = true,
        .capability = .raw,
        .has_type = true,
        .is_copy_value = true,
    };
    try std.testing.expectEqual(ParamCleanupAction.skip, planParamCleanup(raw_cap));
}
