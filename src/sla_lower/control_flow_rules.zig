const std = @import("std");
const ast = @import("ast.zig");

pub const BranchStateMergeAction = enum {
    restore_pre,
    restore_then,
    restore_else,
    keep_current,

    pub fn restoresPre(self: BranchStateMergeAction) bool {
        return self == .restore_pre;
    }

    pub fn restoresThen(self: BranchStateMergeAction) bool {
        return self == .restore_then;
    }

    pub fn restoresElse(self: BranchStateMergeAction) bool {
        return self == .restore_else;
    }
};

pub const FunctionExitCleanupAction = enum {
    release,
    transfer_result,

    pub fn releasesValue(self: FunctionExitCleanupAction) bool {
        return self == .release;
    }

    pub fn transfersResult(self: FunctionExitCleanupAction) bool {
        return self == .transfer_result;
    }
};

pub fn planFunctionExitCleanup(cleanup_name: []const u8, result_expr: *const ast.Node) FunctionExitCleanupAction {
    const result_name = switch (result_expr.*) {
        .identifier => |name| name,
        .move_expr => |move| if (move.expr.* == .identifier) move.expr.identifier else return .release,
        else => return .release,
    };
    return if (std.mem.eql(u8, cleanup_name, result_name)) .transfer_result else .release;
}

pub const MacroParamConsumption = enum {
    never,
    always,
    conditional,
};

pub fn sequenceMacroParamConsumption(left: MacroParamConsumption, right: MacroParamConsumption) MacroParamConsumption {
    if (left == .always or right == .always) return .always;
    if (left == .conditional or right == .conditional) return .conditional;
    return .never;
}

pub fn branchMacroParamConsumption(left: MacroParamConsumption, right: MacroParamConsumption) MacroParamConsumption {
    if (left == right) return left;
    return .conditional;
}

pub fn macroParamConsumption(body: []const *ast.Node, name: []const u8) MacroParamConsumption {
    var effect: MacroParamConsumption = .never;
    for (body) |node| {
        effect = sequenceMacroParamConsumption(effect, macroNodeConsumption(node, name));
    }
    return effect;
}

pub fn macroParamConsumesValue(body: []const *ast.Node, name: []const u8) bool {
    return macroParamConsumption(body, name) != .never;
}

pub fn macroParamIsTrySource(body: []const *ast.Node, name: []const u8) bool {
    for (body) |node| {
        if (macroNodeHasTrySource(node, name)) return true;
    }
    return false;
}

pub fn macroBodyHasTry(body: []const *ast.Node) bool {
    for (body) |node| if (macroNodeHasTry(node)) return true;
    return false;
}

fn macroNodeHasTry(node: *const ast.Node) bool {
    return switch (node.*) {
        .try_expr => true,
        .block_stmt => |block| macroBodyHasTry(block.body),
        .unsafe_expr => |unsafe_expr| macroBodyHasTry(unsafe_expr.body),
        .if_expr => |ife| macroNodeHasTry(ife.cond) or macroBodyHasTry(ife.then_block) or
            (if (ife.else_block) |else_block| macroBodyHasTry(else_block) else false),
        .for_stmt => |for_stmt| macroBodyHasTry(for_stmt.body),
        .while_stmt => |while_stmt| macroBodyHasTry(while_stmt.body),
        .expr_stmt => |expr| macroNodeHasTry(expr),
        .assign_stmt => |assign| macroNodeHasTry(assign.value),
        .let_stmt => |let| macroNodeHasTry(let.value),
        .return_stmt => |ret| if (ret.value) |value| macroNodeHasTry(value) else false,
        else => false,
    };
}

fn macroNodeHasTrySource(node: *const ast.Node, name: []const u8) bool {
    return switch (node.*) {
        .try_expr => |try_expr| try_expr.expr.* == .identifier and std.mem.eql(u8, try_expr.expr.identifier, name),
        .block_stmt => |block| macroParamIsTrySource(block.body, name),
        .unsafe_expr => |unsafe_expr| macroParamIsTrySource(unsafe_expr.body, name),
        .if_expr => |ife| macroNodeHasTrySource(ife.cond, name) or macroParamIsTrySource(ife.then_block, name) or
            (if (ife.else_block) |else_block| macroParamIsTrySource(else_block, name) else false),
        .for_stmt => |for_stmt| macroParamIsTrySource(for_stmt.body, name),
        .while_stmt => |while_stmt| macroParamIsTrySource(while_stmt.body, name),
        .expr_stmt => |expr| macroNodeHasTrySource(expr, name),
        .assign_stmt => |assign| macroNodeHasTrySource(assign.value, name),
        .let_stmt => |let| macroNodeHasTrySource(let.value, name),
        .return_stmt => |ret| if (ret.value) |value| macroNodeHasTrySource(value, name) else false,
        else => false,
    };
}

fn macroNodeConsumption(node: *const ast.Node, name: []const u8) MacroParamConsumption {
    return switch (node.*) {
        .move_expr => |move| if (move.expr.* == .identifier and std.mem.eql(u8, move.expr.identifier, name)) .always else macroNodeConsumption(move.expr, name),
        .release_stmt => |release| if (std.mem.eql(u8, release.var_name, name)) .always else .never,
        .block_stmt => |block| macroParamConsumption(block.body, name),
        .if_expr => |ife| blk: {
            const cond = macroNodeConsumption(ife.cond, name);
            const then_effect = macroParamConsumption(ife.then_block, name);
            const else_effect = if (ife.else_block) |else_block| macroParamConsumption(else_block, name) else .never;
            break :blk sequenceMacroParamConsumption(cond, branchMacroParamConsumption(then_effect, else_effect));
        },
        .switch_expr => |swe| blk: {
            if (swe.cases.len == 0) break :blk .never;
            var effect = macroParamConsumption(swe.cases[0].body, name);
            for (swe.cases[1..]) |case| effect = branchMacroParamConsumption(effect, macroParamConsumption(case.body, name));
            break :blk effect;
        },
        .match_expr => |mat| blk: {
            if (mat.cases.len == 0) break :blk .never;
            var effect = macroParamConsumption(mat.cases[0].body, name);
            for (mat.cases[1..]) |case| effect = branchMacroParamConsumption(effect, macroParamConsumption(case.body, name));
            break :blk effect;
        },
        .unsafe_expr => |unsafe_expr| macroParamConsumption(unsafe_expr.body, name),
        .for_stmt => |for_stmt| if (macroParamConsumption(for_stmt.body, name) == .never) .never else .conditional,
        .while_stmt => |while_stmt| if (macroParamConsumption(while_stmt.body, name) == .never) .never else .conditional,
        .expr_stmt => |expr| macroNodeConsumption(expr, name),
        .call_expr => |call| blk: {
            var effect: MacroParamConsumption = .never;
            for (call.args) |arg| effect = sequenceMacroParamConsumption(effect, macroNodeConsumption(arg, name));
            break :blk effect;
        },
        .struct_literal => |lit| blk: {
            var effect: MacroParamConsumption = if (lit.update_expr) |update| macroNodeConsumption(update, name) else .never;
            for (lit.fields) |field| effect = sequenceMacroParamConsumption(effect, macroNodeConsumption(field.value, name));
            break :blk effect;
        },
        .enum_literal => |lit| blk: {
            var effect: MacroParamConsumption = .never;
            for (lit.fields) |field| effect = sequenceMacroParamConsumption(effect, macroNodeConsumption(field.value, name));
            break :blk effect;
        },
        .tuple_literal => |lit| blk: {
            var effect: MacroParamConsumption = .never;
            for (lit.elements) |element| effect = sequenceMacroParamConsumption(effect, macroNodeConsumption(element, name));
            break :blk effect;
        },
        .array_literal => |lit| blk: {
            var effect: MacroParamConsumption = .never;
            for (lit.elements) |element| effect = sequenceMacroParamConsumption(effect, macroNodeConsumption(element, name));
            break :blk effect;
        },
        .repeat_array_literal => |lit| macroNodeConsumption(lit.value, name),
        .binary_expr => |binary| sequenceMacroParamConsumption(macroNodeConsumption(binary.left, name), macroNodeConsumption(binary.right, name)),
        .field_expr => |field| macroNodeConsumption(field.expr, name),
        .index_expr => |index| sequenceMacroParamConsumption(macroNodeConsumption(index.target, name), macroNodeConsumption(index.index, name)),
        .slice_expr => |slice| sequenceMacroParamConsumption(
            macroNodeConsumption(slice.target, name),
            sequenceMacroParamConsumption(macroNodeConsumption(slice.start, name), macroNodeConsumption(slice.end, name)),
        ),
        .cast_expr => |cast| macroNodeConsumption(cast.expr, name),
        .borrow_expr => |borrow| macroNodeConsumption(borrow.expr, name),
        .deref_expr => |deref| macroNodeConsumption(deref.expr, name),
        .try_expr => |try_expr| if (try_expr.expr.* == .identifier and std.mem.eql(u8, try_expr.expr.identifier, name)) .always else macroNodeConsumption(try_expr.expr, name),
        .await_expr => |await_expr| macroNodeConsumption(await_expr.expr, name),
        .assign_stmt => |assign| macroNodeConsumption(assign.value, name),
        .let_stmt => |let| macroNodeConsumption(let.value, name),
        .return_stmt => |ret| if (ret.value) |value| macroNodeConsumption(value, name) else .never,
        else => .never,
    };
}

pub const ValueState = enum {
    uninitialized,
    active,
    consumed,
};

pub const MultiBranchStateMergeAction = enum {
    restore_pre,
    restore_single,
    intersect_live,

    pub fn restoresPre(self: MultiBranchStateMergeAction) bool {
        return self == .restore_pre;
    }

    pub fn restoresSingle(self: MultiBranchStateMergeAction) bool {
        return self == .restore_single;
    }

    pub fn intersectsLive(self: MultiBranchStateMergeAction) bool {
        return self == .intersect_live;
    }
};

pub fn planBranchStateMerge(then_terminated: bool, else_terminated: bool) BranchStateMergeAction {
    if (then_terminated and else_terminated) return .restore_pre;
    if (then_terminated) return .restore_else;
    if (else_terminated) return .restore_then;
    return .keep_current;
}

pub fn planMultiBranchStateMerge(live_branch_count: usize) MultiBranchStateMergeAction {
    return switch (live_branch_count) {
        0 => .restore_pre,
        1 => .restore_single,
        else => .intersect_live,
    };
}

pub fn intersectLiveBranchValueStates(states: []const ValueState) ValueState {
    if (states.len == 0) return .active;
    const first = states[0];
    var all_same = true;
    var has_uninitialized = first == .uninitialized;
    for (states[1..]) |state| {
        if (state != first) all_same = false;
        if (state == .uninitialized) has_uninitialized = true;
    }
    if (all_same) return first;
    if (has_uninitialized) return .uninitialized;
    return .consumed;
}

test "user macro value consumption follows nested move expressions" {
    var value = ast.Node{ .identifier = "value" };
    var moved = ast.Node{ .move_expr = .{ .expr = &value } };
    var target = ast.Node{ .identifier = "out" };
    var assign = ast.Node{ .assign_stmt = .{ .target = &target, .value = &moved } };
    var block = ast.Node{ .block_stmt = .{ .body = &.{&assign} } };
    var call = ast.Node{ .call_expr = .{ .func_name = "consume", .generics = &.{}, .args = &.{&moved} } };
    var tuple = ast.Node{ .tuple_literal = .{ .elements = &.{&moved} } };
    var deref = ast.Node{ .deref_expr = .{ .expr = &moved } };
    var try_value = ast.Node{ .try_expr = .{ .expr = &value } };

    try std.testing.expect(macroParamConsumesValue(&.{&block}, "value"));
    try std.testing.expectEqual(MacroParamConsumption.always, macroParamConsumption(&.{&call}, "value"));
    try std.testing.expectEqual(MacroParamConsumption.always, macroParamConsumption(&.{&tuple}, "value"));
    try std.testing.expectEqual(MacroParamConsumption.always, macroParamConsumption(&.{&deref}, "value"));
    try std.testing.expect(!macroParamConsumesValue(&.{&block}, "out"));
    try std.testing.expect(macroParamIsTrySource(&.{&try_value}, "value"));
}

test "user macro consumption distinguishes conditional branches and loops" {
    var value = ast.Node{ .identifier = "value" };
    var moved = ast.Node{ .move_expr = .{ .expr = &value } };
    var moved_stmt = ast.Node{ .expr_stmt = &moved };
    var cond = ast.Node{ .identifier = "cond" };
    var conditional = ast.Node{ .if_expr = .{ .cond = &cond, .then_block = &.{&moved_stmt}, .else_block = null } };
    var both = ast.Node{ .if_expr = .{ .cond = &cond, .then_block = &.{&moved_stmt}, .else_block = &.{&moved_stmt} } };
    var loop = ast.Node{ .while_stmt = .{ .cond = &cond, .body = &.{&moved_stmt} } };

    try std.testing.expectEqual(MacroParamConsumption.conditional, macroParamConsumption(&.{&conditional}, "value"));
    try std.testing.expectEqual(MacroParamConsumption.always, macroParamConsumption(&.{&both}, "value"));
    try std.testing.expectEqual(MacroParamConsumption.conditional, macroParamConsumption(&.{&loop}, "value"));
}
