const std = @import("std");
const lowering_rules = @import("lowering_rules.zig");
const ast = @import("ast.zig");
const type_checker_mod = @import("type_checker.zig");

fn markReachableFunc(
    tc: *const type_checker_mod.TypeChecker,
    reachable: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    name: []const u8,
) anyerror!void {
    if (!tc.funcs.contains(name)) return;
    if (reachable.contains(name)) return;
    try reachable.put(name, {});
    try worklist.append(name);
}

fn markReachableResolvedCallAlias(
    tc: *const type_checker_mod.TypeChecker,
    reachable: *std.StringHashMap(void),
    expr: *const ast.Node,
) anyerror!void {
    const metadata = tc.resolved_call_alias_metadata.get(expr) orelse return;
    if (!reachable.contains(metadata.alias)) try reachable.put(metadata.alias, {});
}

fn associatedReachableFuncKey(
    tc: *const type_checker_mod.TypeChecker,
    target_name: []const u8,
    func_name: []const u8,
) ?[]const u8 {
    var it = tc.funcs.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len != target_name.len + 1 + func_name.len) continue;
        if (!std.mem.startsWith(u8, key, target_name)) continue;
        if (key[target_name.len] != '_') continue;
        if (!std.mem.eql(u8, key[target_name.len + 1 ..], func_name)) continue;
        return key;
    }
    return null;
}

fn markReachableCallTarget(
    tc: *const type_checker_mod.TypeChecker,
    reachable: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    expr: *const ast.Node,
    call: ast.CallExpr,
) anyerror!void {
    if (tc.resolved_call_symbols.get(expr)) |symbol| {
        try markReachableResolvedCallAlias(tc, reachable, expr);
        try markReachableFunc(tc, reachable, worklist, symbol);
        return;
    }
    if (call.associated_target) |target_name| {
        if (associatedReachableFuncKey(tc, target_name, call.func_name)) |symbol| {
            try markReachableFunc(tc, reachable, worklist, symbol);
        }
        return;
    }
    if (tc.macros.get(call.func_name)) |macro| {
        const scan_key = try std.fmt.allocPrint(tc.allocator, "__sla_reachable_macro__{s}", .{call.func_name});
        if (reachable.contains(scan_key)) {
            tc.allocator.free(scan_key);
            return;
        }
        try reachable.put(scan_key, {});
        try collectReachableBlock(tc, reachable, worklist, macro.body);
        return;
    }
    if (tc.imported_macros.get(call.func_name)) |macro| {
        for (macro.direct_callees) |callee| try markReachableFunc(tc, reachable, worklist, callee);
        return;
    }
    try markReachableFunc(tc, reachable, worklist, call.func_name);
}

fn markReachableProtocolMethod(
    tc: *const type_checker_mod.TypeChecker,
    reachable: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    iterable_ty: *ast.Type,
    method_name: []const u8,
) !void {
    const method = @constCast(tc).methodForType(iterable_ty, method_name) orelse return;
    var iter = tc.funcs.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* != method) continue;
        try markReachableFunc(tc, reachable, worklist, entry.key_ptr.*);
        return;
    }
}

pub fn collectReachableExpr(
    tc: *const type_checker_mod.TypeChecker,
    reachable: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    expr: *const ast.Node,
) anyerror!void {
    switch (expr.*) {
        .identifier => |name| try markReachableFunc(tc, reachable, worklist, name),
        .generic_func_ref => |ref| try markReachableFunc(tc, reachable, worklist, ref.func_name),
        .call_expr => |call| {
            try markReachableCallTarget(tc, reachable, worklist, expr, call);
            for (call.args) |arg| try collectReachableExpr(tc, reachable, worklist, arg);
        },
        .if_expr => |ife| {
            try collectReachableExpr(tc, reachable, worklist, ife.cond);
            if (ife.let_chain) |chain| {
                for (chain) |cond| try collectReachableExpr(tc, reachable, worklist, cond.value);
            }
            try collectReachableBlock(tc, reachable, worklist, ife.then_block);
            if (ife.else_block) |else_block| try collectReachableBlock(tc, reachable, worklist, else_block);
        },
        .switch_expr => |swe| {
            try collectReachableExpr(tc, reachable, worklist, swe.val);
            for (swe.cases) |case| {
                try collectReachableExpr(tc, reachable, worklist, case.pattern);
                try collectReachableBlock(tc, reachable, worklist, case.body);
            }
        },
        .match_expr => |mat| {
            try collectReachableExpr(tc, reachable, worklist, mat.val);
            for (mat.cases) |case| {
                if (case.guard) |guard| try collectReachableExpr(tc, reachable, worklist, guard);
                try collectReachableBlock(tc, reachable, worklist, case.body);
            }
        },
        .unsafe_expr => |unsafe_expr| try collectReachableBlock(tc, reachable, worklist, unsafe_expr.body),
        .await_expr => |await_expr| try collectReachableExpr(tc, reachable, worklist, await_expr.expr),
        .try_expr => |try_expr| try collectReachableExpr(tc, reachable, worklist, try_expr.expr),
        .binary_expr => |bin| {
            if (tc.resolved_call_symbols.get(expr)) |symbol| {
                try markReachableResolvedCallAlias(tc, reachable, expr);
                try markReachableFunc(tc, reachable, worklist, symbol);
            }
            try collectReachableExpr(tc, reachable, worklist, bin.left);
            try collectReachableExpr(tc, reachable, worklist, bin.right);
        },
        .closure_literal => |closure| try collectReachableExpr(tc, reachable, worklist, closure.body),
        .borrow_expr => |borrow| try collectReachableExpr(tc, reachable, worklist, borrow.expr),
        .move_expr => |move| try collectReachableExpr(tc, reachable, worklist, move.expr),
        .deref_expr => |deref| try collectReachableExpr(tc, reachable, worklist, deref.expr),
        .cast_expr => |cast| try collectReachableExpr(tc, reachable, worklist, cast.expr),
        .field_expr => |field| try collectReachableExpr(tc, reachable, worklist, field.expr),
        .struct_literal => |lit| for (lit.fields) |field| try collectReachableExpr(tc, reachable, worklist, field.value),
        .enum_literal => |lit| for (lit.fields) |field| try collectReachableExpr(tc, reachable, worklist, field.value),
        .tuple_literal => |lit| for (lit.elements) |elem| try collectReachableExpr(tc, reachable, worklist, elem),
        .array_literal => |lit| for (lit.elements) |elem| try collectReachableExpr(tc, reachable, worklist, elem),
        .repeat_array_literal => |lit| try collectReachableExpr(tc, reachable, worklist, lit.value),
        .index_expr => |idx| {
            try collectReachableExpr(tc, reachable, worklist, idx.target);
            try collectReachableExpr(tc, reachable, worklist, idx.index);
        },
        .slice_expr => |slice| {
            try collectReachableExpr(tc, reachable, worklist, slice.target);
            try collectReachableExpr(tc, reachable, worklist, slice.start);
            try collectReachableExpr(tc, reachable, worklist, slice.end);
        },
        else => {},
    }
}

pub fn collectReachableBlock(
    tc: *const type_checker_mod.TypeChecker,
    reachable: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    block: []const *ast.Node,
) anyerror!void {
    for (block) |stmt| {
        switch (stmt.*) {
            .let_stmt => |let| try collectReachableExpr(tc, reachable, worklist, let.value),
            .let_else_stmt => |let| {
                try collectReachableExpr(tc, reachable, worklist, let.value);
                try collectReachableBlock(tc, reachable, worklist, let.else_block);
            },
            .let_destructure_stmt => |let| try collectReachableExpr(tc, reachable, worklist, let.value),
            .const_stmt => |c| try collectReachableExpr(tc, reachable, worklist, c.value),
            .assign_stmt => |assign| {
                try collectReachableExpr(tc, reachable, worklist, assign.target);
                try collectReachableExpr(tc, reachable, worklist, assign.value);
            },
            .block_stmt => |blk| try collectReachableBlock(tc, reachable, worklist, blk.body),
            .expr_stmt => |expr| try collectReachableExpr(tc, reachable, worklist, expr),
            .return_stmt => |ret| if (ret.value) |value| try collectReachableExpr(tc, reachable, worklist, value),
            .for_stmt => |for_stmt| {
                try collectReachableExpr(tc, reachable, worklist, for_stmt.start);
                if (for_stmt.end) |end_expr| {
                    try collectReachableExpr(tc, reachable, worklist, end_expr);
                } else if (tc.expr_types.get(for_stmt.start)) |iterable_ty| {
                    try markReachableProtocolMethod(tc, reachable, worklist, iterable_ty, "iter_len");
                    try markReachableProtocolMethod(tc, reachable, worklist, iterable_ty, "iter_at");
                }
                try collectReachableBlock(tc, reachable, worklist, for_stmt.body);
            },
            .while_stmt => |while_stmt| {
                try collectReachableExpr(tc, reachable, worklist, while_stmt.cond);
                try collectReachableBlock(tc, reachable, worklist, while_stmt.body);
            },
            else => try collectReachableExpr(tc, reachable, worklist, stmt),
        }
    }
}

fn dynConcreteTypeName(ty: *const ast.Type) ?[]const u8 {
    if (lowering_rules.dynTraitName(ty) != null) return null;
    const curr = lowering_rules.peelBorrowPointerType(ty);
    if (curr.* != .user_defined) return null;
    if (std.mem.startsWith(u8, curr.user_defined.name, "__dyn_")) return null;
    if (lowering_rules.smartPointerType(curr)) |smart| {
        return dynConcreteTypeName(smart.inner);
    }
    return curr.user_defined.name;
}

fn markNeededTraitImplForExpr(
    allocator: std.mem.Allocator,
    tc: *const type_checker_mod.TypeChecker,
    needed: *std.StringHashMap(void),
    expr: *const ast.Node,
    trait_name: []const u8,
) !void {
    const source_expr = if (expr.* == .borrow_expr) expr.borrow_expr.expr else expr;
    const source_ty = tc.expr_types.get(source_expr) orelse tc.expr_types.get(expr) orelse return;
    const type_name = dynConcreteTypeName(source_ty) orelse return;
    const key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ trait_name, type_name });
    try needed.put(key, {});
}

pub fn collectNeededTraitImplsExpr(
    allocator: std.mem.Allocator,
    tc: *const type_checker_mod.TypeChecker,
    needed: *std.StringHashMap(void),
    expr: *const ast.Node,
) anyerror!void {
    if (tc.dyn_borrow_args.get(expr)) |trait_name| try markNeededTraitImplForExpr(allocator, tc, needed, expr, trait_name);
    if (tc.dyn_box_coercions.get(expr)) |trait_name| try markNeededTraitImplForExpr(allocator, tc, needed, expr, trait_name);
    if (tc.dyn_rc_coercions.get(expr)) |trait_name| try markNeededTraitImplForExpr(allocator, tc, needed, expr, trait_name);

    switch (expr.*) {
        .call_expr => |call| for (call.args) |arg| try collectNeededTraitImplsExpr(allocator, tc, needed, arg),
        .if_expr => |ife| {
            try collectNeededTraitImplsExpr(allocator, tc, needed, ife.cond);
            if (ife.let_chain) |chain| {
                for (chain) |cond| try collectNeededTraitImplsExpr(allocator, tc, needed, cond.value);
            }
            try collectNeededTraitImplsBlock(allocator, tc, needed, ife.then_block);
            if (ife.else_block) |else_block| try collectNeededTraitImplsBlock(allocator, tc, needed, else_block);
        },
        .switch_expr => |swe| {
            try collectNeededTraitImplsExpr(allocator, tc, needed, swe.val);
            for (swe.cases) |case| {
                try collectNeededTraitImplsExpr(allocator, tc, needed, case.pattern);
                try collectNeededTraitImplsBlock(allocator, tc, needed, case.body);
            }
        },
        .match_expr => |mat| {
            try collectNeededTraitImplsExpr(allocator, tc, needed, mat.val);
            for (mat.cases) |case| {
                if (case.guard) |guard| try collectNeededTraitImplsExpr(allocator, tc, needed, guard);
                try collectNeededTraitImplsBlock(allocator, tc, needed, case.body);
            }
        },
        .unsafe_expr => |unsafe_expr| try collectNeededTraitImplsBlock(allocator, tc, needed, unsafe_expr.body),
        .await_expr => |await_expr| try collectNeededTraitImplsExpr(allocator, tc, needed, await_expr.expr),
        .try_expr => |try_expr| try collectNeededTraitImplsExpr(allocator, tc, needed, try_expr.expr),
        .binary_expr => |bin| {
            try collectNeededTraitImplsExpr(allocator, tc, needed, bin.left);
            try collectNeededTraitImplsExpr(allocator, tc, needed, bin.right);
        },
        .closure_literal => |closure| try collectNeededTraitImplsExpr(allocator, tc, needed, closure.body),
        .borrow_expr => |borrow| try collectNeededTraitImplsExpr(allocator, tc, needed, borrow.expr),
        .move_expr => |move| try collectNeededTraitImplsExpr(allocator, tc, needed, move.expr),
        .deref_expr => |deref| try collectNeededTraitImplsExpr(allocator, tc, needed, deref.expr),
        .cast_expr => |cast| try collectNeededTraitImplsExpr(allocator, tc, needed, cast.expr),
        .field_expr => |field| try collectNeededTraitImplsExpr(allocator, tc, needed, field.expr),
        .struct_literal => |lit| {
            for (lit.fields) |field| try collectNeededTraitImplsExpr(allocator, tc, needed, field.value);
            if (lit.update_expr) |update| try collectNeededTraitImplsExpr(allocator, tc, needed, update);
        },
        .enum_literal => |lit| for (lit.fields) |field| try collectNeededTraitImplsExpr(allocator, tc, needed, field.value),
        .tuple_literal => |lit| for (lit.elements) |elem| try collectNeededTraitImplsExpr(allocator, tc, needed, elem),
        .array_literal => |lit| for (lit.elements) |elem| try collectNeededTraitImplsExpr(allocator, tc, needed, elem),
        .repeat_array_literal => |lit| try collectNeededTraitImplsExpr(allocator, tc, needed, lit.value),
        .index_expr => |idx| {
            try collectNeededTraitImplsExpr(allocator, tc, needed, idx.target);
            try collectNeededTraitImplsExpr(allocator, tc, needed, idx.index);
        },
        .slice_expr => |slice| {
            try collectNeededTraitImplsExpr(allocator, tc, needed, slice.target);
            try collectNeededTraitImplsExpr(allocator, tc, needed, slice.start);
            try collectNeededTraitImplsExpr(allocator, tc, needed, slice.end);
        },
        else => {},
    }
}

pub fn collectNeededTraitImplsBlock(
    allocator: std.mem.Allocator,
    tc: *const type_checker_mod.TypeChecker,
    needed: *std.StringHashMap(void),
    block: []const *ast.Node,
) anyerror!void {
    for (block) |stmt| {
        switch (stmt.*) {
            .let_stmt => |let| try collectNeededTraitImplsExpr(allocator, tc, needed, let.value),
            .let_else_stmt => |let| {
                try collectNeededTraitImplsExpr(allocator, tc, needed, let.value);
                try collectNeededTraitImplsBlock(allocator, tc, needed, let.else_block);
            },
            .let_destructure_stmt => |let| try collectNeededTraitImplsExpr(allocator, tc, needed, let.value),
            .const_stmt => |c| try collectNeededTraitImplsExpr(allocator, tc, needed, c.value),
            .assign_stmt => |assign| {
                try collectNeededTraitImplsExpr(allocator, tc, needed, assign.target);
                try collectNeededTraitImplsExpr(allocator, tc, needed, assign.value);
            },
            .block_stmt => |blk| try collectNeededTraitImplsBlock(allocator, tc, needed, blk.body),
            .expr_stmt => |expr| try collectNeededTraitImplsExpr(allocator, tc, needed, expr),
            .return_stmt => |ret| if (ret.value) |value| try collectNeededTraitImplsExpr(allocator, tc, needed, value),
            .for_stmt => |for_stmt| {
                try collectNeededTraitImplsExpr(allocator, tc, needed, for_stmt.start);
                if (for_stmt.end) |end_expr| try collectNeededTraitImplsExpr(allocator, tc, needed, end_expr);
                try collectNeededTraitImplsBlock(allocator, tc, needed, for_stmt.body);
            },
            .while_stmt => |while_stmt| {
                try collectNeededTraitImplsExpr(allocator, tc, needed, while_stmt.cond);
                try collectNeededTraitImplsBlock(allocator, tc, needed, while_stmt.body);
            },
            else => {},
        }
    }
}
