const std = @import("std");
const ast = @import("ast.zig");
const lowering_rules = @import("lowering_rules.zig");
const control_flow_rules = @import("control_flow_rules.zig");
const contract_parser = @import("contract_parser.zig");

pub const TypeError = error{
    UndefinedVariable,
    Redeclaration,
    TypeMismatch,
    UseAfterMove,
    UseBeforeInit,
    InvalidBorrow,
    DereferenceNonPointer,
    FieldNotFound,
    NotAStruct,
    InvalidArgsCount,
    AmbiguousCall,
    CompileError,
    OutOfMemory,
};

pub const ValueState = control_flow_rules.ValueState;

pub const ImportedMacro = struct {
    arity: usize,
    leading_outputs: usize,
    import_path: ?[]const u8 = null,
    borrowed_arg_mask: u64 = 0,
    address_slot_arg_mask: u64 = 0,
    /// Macro params passed plainly to a `call @callee(...)` position whose
    /// extern contract declares that parameter as borrow (`&name: ty`). The
    /// codegen must emit those call args with an explicit `&` capability
    /// prefix so the expansion satisfies the callee contract.
    callee_borrow_prefix_mask: u64 = 0,
    /// Macro params passed plainly to a `call @callee(...)` position whose
    /// extern contract declares a plain pointer parameter (consumed/moved).
    /// Reused caller identifiers forwarded there must be passed as fresh
    /// copies so they stay usable after the expansion.
    callee_consume_ptr_mask: u64 = 0,
    direct_callees: []const []const u8 = &.{},
};

const MacroConsumptionKey = struct {
    macro_decl: *const ast.MacroDecl,
    param_index: usize,
};

pub const Symbol = struct {
    name: []const u8,
    ty: *ast.Type,
    is_const: bool,
    state: ValueState,
    borrow_source: ?[]const u8 = null,
};

pub const InjectedScopeBinding = struct {
    name: []const u8,
    ty: *ast.Type,
    is_const: bool = false,
};

pub const Options = struct {
    injected_scope_bindings: []const InjectedScopeBinding = &.{},
    using_modules: []const []const u8 = &.{},
};

pub const Scope = struct {
    allocator: std.mem.Allocator,
    parent: ?*Scope,
    symbols: std.StringHashMap(Symbol),
    using_modules: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) !*Scope {
        const self = try allocator.create(Scope);
        self.* = .{
            .allocator = allocator,
            .parent = parent,
            .symbols = std.StringHashMap(Symbol).init(allocator),
            .using_modules = std.ArrayList([]const u8).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Scope) void {
        self.using_modules.deinit();
        self.symbols.deinit();
        self.allocator.destroy(self);
    }

    pub fn define(self: *Scope, name: []const u8, ty: *ast.Type, is_const: bool) !void {
        try self.defineWithState(name, ty, is_const, .active);
    }

    pub fn defineWithState(self: *Scope, name: []const u8, ty: *ast.Type, is_const: bool, state: ValueState) !void {
        if (self.symbols.contains(name)) return TypeError.Redeclaration;
        try self.symbols.put(name, .{
            .name = name,
            .ty = ty,
            .is_const = is_const,
            .state = state,
            .borrow_source = null,
        });
    }

    pub fn lookup(self: *Scope, name: []const u8) ?*Symbol {
        var curr: ?*Scope = self;
        while (curr) |s| {
            if (s.symbols.getPtr(name)) |sym| {
                return sym;
            }
            curr = s.parent;
        }
        return null;
    }

    pub fn lookupLocal(self: *Scope, name: []const u8) ?*Symbol {
        return self.symbols.getPtr(name);
    }
};

fn bindingIsLocalToLoop(scope: *Scope, loop_scope: *Scope, name: []const u8) bool {
    var curr: ?*Scope = scope;
    while (curr) |frame| : (curr = frame.parent) {
        if (frame.lookupLocal(name) != null) return true;
        if (frame == loop_scope) return false;
    }
    return false;
}

pub const TypeChecker = struct {
    pub const FunctionSignature = struct {
        params: []const ast.Param,
        ret_ty: *ast.Type,
        is_async: bool = false,
    };

    pub const FunctionAliasMetadata = struct {
        alias: []const u8,
        target: []const u8,
        namespace: ?[]const u8 = null,
        module_path: ?[]const u8 = null,
    };

    allocator: std.mem.Allocator,
    structs: std.StringHashMap(*ast.StructDecl),
    type_aliases: std.StringHashMap(*ast.TypeAliasDecl),
    alias_struct_cache: std.StringHashMap(*ast.StructDecl),
    enums: std.StringHashMap(*ast.EnumDecl),
    traits: std.StringHashMap(*ast.TraitDecl),
    trait_impls: std.StringHashMap(void),
    extern_funcs: std.StringHashMap(contract_parser.ExternalFunction),
    layout_defines: std.StringHashMap(contract_parser.LayoutDefine),
    scope_pool: std.ArrayList(*Scope),

    // Maps a return/block exit node to the variables that need to be dropped
    cleanups: std.AutoHashMap(*const ast.Node, std.ArrayList([]const u8)),
    // Maps await expressions to cleanups used only when codegen emits a
    // generated pending return. Ready paths retain their ordinary state.
    await_cleanups: std.AutoHashMap(*const ast.Node, std.ArrayList([]const u8)),
    macro_call_try_cleanups: std.AutoHashMap(*const ast.CallExpr, std.ArrayList([]const u8)),
    // Maps a branch end to the variables to release for Phi resolution
    phi_cleanups: std.AutoHashMap(*const ast.Node, std.ArrayList([]const u8)),

    // Tracks internal Sla functions for validation
    funcs: std.StringHashMap(*ast.FuncDecl),
    function_aliases: std.StringHashMap([]const u8),
    function_alias_metadata: std.StringHashMap(FunctionAliasMetadata),
    imported_function_signatures: std.StringHashMap(FunctionSignature),
    // Tracks user-defined macros
    macros: std.StringHashMap(*ast.MacroDecl),
    imported_macros: std.StringHashMap(ImportedMacro),
    overloads: std.StringHashMap(std.ArrayList([]const u8)),
    using_modules_input: []const []const u8,
    // Maps expressions to their validated types for use in Codegen layout offsets
    expr_types: std.AutoHashMap(*const ast.Node, *ast.Type),
    dyn_call_traits: std.AutoHashMap(*const ast.Node, []const u8),
    dyn_borrow_args: std.AutoHashMap(*const ast.Node, []const u8),
    dyn_box_coercions: std.AutoHashMap(*const ast.Node, []const u8),
    dyn_rc_coercions: std.AutoHashMap(*const ast.Node, []const u8),
    fn_ptr_calls: std.AutoHashMap(*const ast.Node, void),
    array_to_slice_borrow_args: std.AutoHashMap(*const ast.Node, void),
    resolved_call_symbols: std.AutoHashMap(*const ast.Node, []const u8),
    resolved_call_alias_metadata: std.AutoHashMap(*const ast.Node, FunctionAliasMetadata),
    current_function_name: ?[]const u8,
    current_function_namespace: ?[]const u8,
    current_loop_scope: ?*Scope,
    current_loop_body_terminates: bool,
    global_scope: ?*Scope,
    unsafe_depth: usize,
    injected_scope_bindings: []const InjectedScopeBinding,
    last_error: []const u8,
    last_error_buf: [1024]u8,

    pub fn init(allocator: std.mem.Allocator) TypeChecker {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: Options) TypeChecker {
        return .{
            .allocator = allocator,
            .structs = std.StringHashMap(*ast.StructDecl).init(allocator),
            .type_aliases = std.StringHashMap(*ast.TypeAliasDecl).init(allocator),
            .alias_struct_cache = std.StringHashMap(*ast.StructDecl).init(allocator),
            .enums = std.StringHashMap(*ast.EnumDecl).init(allocator),
            .traits = std.StringHashMap(*ast.TraitDecl).init(allocator),
            .trait_impls = std.StringHashMap(void).init(allocator),
            .extern_funcs = std.StringHashMap(contract_parser.ExternalFunction).init(allocator),
            .layout_defines = std.StringHashMap(contract_parser.LayoutDefine).init(allocator),
            .scope_pool = std.ArrayList(*Scope).init(allocator),
            .cleanups = std.AutoHashMap(*const ast.Node, std.ArrayList([]const u8)).init(allocator),
            .await_cleanups = std.AutoHashMap(*const ast.Node, std.ArrayList([]const u8)).init(allocator),
            .macro_call_try_cleanups = std.AutoHashMap(*const ast.CallExpr, std.ArrayList([]const u8)).init(allocator),
            .phi_cleanups = std.AutoHashMap(*const ast.Node, std.ArrayList([]const u8)).init(allocator),
            .funcs = std.StringHashMap(*ast.FuncDecl).init(allocator),
            .function_aliases = std.StringHashMap([]const u8).init(allocator),
            .function_alias_metadata = std.StringHashMap(FunctionAliasMetadata).init(allocator),
            .imported_function_signatures = std.StringHashMap(FunctionSignature).init(allocator),
            .macros = std.StringHashMap(*ast.MacroDecl).init(allocator),
            .imported_macros = std.StringHashMap(ImportedMacro).init(allocator),
            .overloads = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .using_modules_input = options.using_modules,
            .expr_types = std.AutoHashMap(*const ast.Node, *ast.Type).init(allocator),
            .dyn_call_traits = std.AutoHashMap(*const ast.Node, []const u8).init(allocator),
            .dyn_borrow_args = std.AutoHashMap(*const ast.Node, []const u8).init(allocator),
            .dyn_box_coercions = std.AutoHashMap(*const ast.Node, []const u8).init(allocator),
            .dyn_rc_coercions = std.AutoHashMap(*const ast.Node, []const u8).init(allocator),
            .fn_ptr_calls = std.AutoHashMap(*const ast.Node, void).init(allocator),
            .array_to_slice_borrow_args = std.AutoHashMap(*const ast.Node, void).init(allocator),
            .resolved_call_symbols = std.AutoHashMap(*const ast.Node, []const u8).init(allocator),
            .resolved_call_alias_metadata = std.AutoHashMap(*const ast.Node, FunctionAliasMetadata).init(allocator),
            .current_function_name = null,
            .current_function_namespace = null,
            .current_loop_scope = null,
            .current_loop_body_terminates = false,
            .global_scope = null,
            .unsafe_depth = 0,
            .injected_scope_bindings = options.injected_scope_bindings,
            .last_error = "",
            .last_error_buf = undefined,
        };
    }

    pub fn setError(self: *TypeChecker, comptime fmt: []const u8, args: anytype) void {
        var fba = std.heap.FixedBufferAllocator.init(&self.last_error_buf);
        self.last_error = std.fmt.allocPrint(fba.allocator(), fmt, args) catch "Error formatting diagnostic";
    }

    fn defineSymbol(self: *TypeChecker, scope: *Scope, name: []const u8, ty: *ast.Type, is_const: bool) TypeError!void {
        try self.defineSymbolWithState(scope, name, ty, is_const, .active);
    }

    fn defineSymbolWithState(self: *TypeChecker, scope: *Scope, name: []const u8, ty: *ast.Type, is_const: bool, state: ValueState) TypeError!void {
        scope.defineWithState(name, ty, is_const, state) catch |err| switch (err) {
            TypeError.Redeclaration => {
                self.setError("Redeclaration: symbol `{s}` is already defined", .{name});
                return TypeError.Redeclaration;
            },
            TypeError.OutOfMemory => return TypeError.OutOfMemory,
            else => return err,
        };
    }

    fn consumeBinding(self: *TypeChecker, scope: *Scope, name: []const u8, sym: *Symbol, operation: []const u8) TypeError!void {
        if (self.current_loop_scope) |loop_scope| {
            if (!self.current_loop_body_terminates and !bindingIsLocalToLoop(scope, loop_scope, name)) {
                self.setError("LoopConditionalConsume: binding `{s}` declared before the loop cannot be consumed by {s} inside the loop body", .{ name, operation });
                return TypeError.CompileError;
            }
        }
        sym.state = .consumed;
    }

    fn consumeExternMoveArg(self: *TypeChecker, scope: *Scope, param: contract_parser.Param, arg: *const ast.Node) TypeError!void {
        if (!param.is_move) return;
        if (arg.* == .move_expr) return;
        if (arg.* != .identifier) return;

        const sym = scope.lookup(arg.identifier) orelse return TypeError.UndefinedVariable;
        if (sym.state == .consumed) return TypeError.UseAfterMove;
        if (sym.state == .uninitialized) {
            self.setError("UseBeforeInit: var `{s}` is read before assignment", .{arg.identifier});
            return TypeError.UseBeforeInit;
        }
        try self.consumeBinding(scope, arg.identifier, sym, "extern move argument");
    }

    fn directBorrowSource(expr: *const ast.Node) ?[]const u8 {
        return switch (expr.*) {
            .identifier => |name| name,
            .borrow_expr => |borrow| if (borrow.expr.* == .identifier) borrow.expr.identifier else null,
            else => null,
        };
    }

    fn borrowSourceAliasedByOtherActive(self: *TypeChecker, scope: *Scope, name: []const u8) bool {
        _ = self;
        // issue013: when a borrow value is `let y = x;` (x is a borrow), the borrow
        // handle is carried into y; only y should be released at scope exit.
        // Return true if some *other* active symbol `y` in the same scope (or an
        // ancestor scope) has borrow_source == name -- in that case we skip the
        // source `name` from cleanup, otherwise SA vm gets a double release
        // (UseAfterMove / PhiStateConflict).
        var curr: ?*Scope = scope;
        while (curr) |frame| : (curr = frame.parent) {
            var iter = frame.symbols.valueIterator();
            while (iter.next()) |sym| {
                if (std.mem.eql(u8, sym.name, name)) continue;
                if (sym.state != .active) continue;
                if (sym.borrow_source) |bsrc| {
                    if (std.mem.eql(u8, bsrc, name)) return true;
                }
            }
        }
        return false;
    }

    fn functionExitBindingEscapes(scope: *Scope, result_expr: *const ast.Node, candidate: []const u8) bool {
        const result_name = switch (result_expr.*) {
            .identifier => |name| name,
            .move_expr => |move| if (move.expr.* == .identifier) move.expr.identifier else return false,
            else => return false,
        };
        if (std.mem.eql(u8, candidate, result_name)) return true;

        var current_name = result_name;
        var remaining: usize = 1;
        var current_scope: ?*Scope = scope;
        while (current_scope) |frame| : (current_scope = frame.parent) remaining += frame.symbols.count();
        while (remaining > 0) : (remaining -= 1) {
            const current = scope.lookup(current_name) orelse return false;
            const source = current.borrow_source orelse return false;
            if (std.mem.eql(u8, candidate, source)) return true;
            current_name = source;
        }
        return false;
    }

    fn recordAwaitCleanup(self: *TypeChecker, await_node: *const ast.Node, future_expr: *const ast.Node, scope: *Scope) TypeError!void {
        var cleanup_list = std.ArrayList([]const u8).init(self.allocator);
        var current: ?*Scope = scope;
        while (current) |frame| : (current = frame.parent) {
            var iter = frame.symbols.valueIterator();
            while (iter.next()) |sym| {
                if (sym.state != .active or isInternalSymbol(sym.name)) continue;
                if (functionExitBindingEscapes(scope, future_expr, sym.name)) continue;
                // issue013: skip borrowed source that was aliased.
                if (isBorrowLikeType(sym.ty) and self.borrowSourceAliasedByOtherActive(scope, sym.name)) continue;
                try cleanup_list.append(sym.name);
            }
        }
        if (cleanup_list.items.len == 0) {
            cleanup_list.deinit();
            return;
        }
        try self.await_cleanups.put(await_node, cleanup_list);
    }

    fn ensureTopLevelNameUnused(self: *TypeChecker, name: []const u8, kind: []const u8) TypeError!void {
        if (self.structs.contains(name) or self.enums.contains(name) or self.traits.contains(name) or self.funcs.contains(name) or self.macros.contains(name)) {
            self.setError("Redeclaration: {s} `{s}` is already defined", .{ kind, name });
            return TypeError.Redeclaration;
        }
    }

    /// True when two same-named top-level functions form a legal C-style
    /// prototype/definition pair: exactly one is body-less, both use the extern
    /// ABI surface, and the signatures agree. Anything else stays a redeclaration.
    fn externPrototypePairsWith(a: *const ast.FuncDecl, b: *const ast.FuncDecl) bool {
        if (a.is_decl_only == b.is_decl_only) return false;
        const prototype = if (a.is_decl_only) a else b;
        const definition = if (a.is_decl_only) b else a;
        if (!prototype.is_extern) return false;
        if (!definition.is_extern and !definition.no_mangle) return false;
        if (prototype.abi != null and definition.abi != null and !std.mem.eql(u8, prototype.abi.?, definition.abi.?)) return false;
        if (prototype.params.len != definition.params.len) return false;
        for (prototype.params, definition.params) |p, d| {
            if (!typesStructurallyEqual(p.ty, d.ty)) return false;
        }
        return typesStructurallyEqual(prototype.ret_ty, definition.ret_ty);
    }

    /// Allocation-free structural type comparison used before the checker's type
    /// tables are populated, so it cannot resolve aliases — declarations and
    /// definitions must spell their signature the same way.
    fn typesStructurallyEqual(a: *const ast.Type, b: *const ast.Type) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .infer => true,
            .primitive => |p| p == b.primitive,
            .pointer => typesStructurallyEqual(a.pointer, b.pointer),
            .borrow => typesStructurallyEqual(a.borrow, b.borrow),
            .future => typesStructurallyEqual(a.future, b.future),
            .array => |arr| arr.len == b.array.len and typesStructurallyEqual(arr.elem, b.array.elem),
            .tuple => |tup| blk: {
                if (tup.elems.len != b.tuple.elems.len) break :blk false;
                for (tup.elems, b.tuple.elems) |x, y| {
                    if (!typesStructurallyEqual(x, y)) break :blk false;
                }
                break :blk true;
            },
            .closure => |c| blk: {
                if (c.params.len != b.closure.params.len) break :blk false;
                for (c.params, b.closure.params) |x, y| {
                    if (!typesStructurallyEqual(x, y)) break :blk false;
                }
                break :blk typesStructurallyEqual(c.ret, b.closure.ret);
            },
            .fn_ptr => |f| blk: {
                if (f.params.len != b.fn_ptr.params.len) break :blk false;
                for (f.params, b.fn_ptr.params) |x, y| {
                    if (!typesStructurallyEqual(x, y)) break :blk false;
                }
                break :blk typesStructurallyEqual(f.ret, b.fn_ptr.ret);
            },
            .user_defined => |ud| blk: {
                if (!std.mem.eql(u8, ud.name, b.user_defined.name)) break :blk false;
                if (ud.generics.len != b.user_defined.generics.len) break :blk false;
                for (ud.generics, b.user_defined.generics) |x, y| {
                    if (!typesStructurallyEqual(x, y)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    fn normalizeUsingPath(self: *TypeChecker, using_path: []const u8) TypeError![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        var i: usize = 0;
        while (i < using_path.len) {
            if (i + 1 < using_path.len and using_path[i] == ':' and using_path[i + 1] == ':') {
                try buf.appendSlice("__");
                i += 2;
            } else {
                try buf.append(using_path[i]);
                i += 1;
            }
        }
        return try buf.toOwnedSlice();
    }

    fn usingSymbolPrefix(self: *TypeChecker, using_path: []const u8, method_name: []const u8) TypeError![]const u8 {
        const normalized = try self.normalizeUsingPath(using_path);
        defer self.allocator.free(normalized);
        return try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ normalized, method_name });
    }

    fn overloadKey(self: *TypeChecker, type_name: []const u8, op_name: []const u8) TypeError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ type_name, op_name }) catch return TypeError.OutOfMemory;
    }

    fn operatorToOverloadName(op: ast.BinaryOp) ?[]const u8 {
        return switch (op) {
            .add => "op_add",
            .sub => "op_sub",
            .mul => "op_mul",
            .div => "op_div",
            .spaceship => "op_cmp",
            else => null,
        };
    }

    fn overloadSymbol(self: *TypeChecker, op: ast.BinaryOp, left_ty: *ast.Type, right_ty: *ast.Type) TypeError!?[]const u8 {
        const op_name = operatorToOverloadName(op) orelse return null;
        const left_name = concreteTypeName(left_ty) orelse return null;
        const key = try self.overloadKey(left_name, op_name);
        defer self.allocator.free(key);
        const list = self.overloads.get(key) orelse return null;

        var found: ?[]const u8 = null;
        for (list.items) |symbol| {
            const func = self.funcs.get(symbol) orelse continue;
            if (func.params.len != 2) continue;
            if (!self.typesEqual(func.params[0].ty, left_ty)) continue;
            if (!self.typesEqual(func.params[1].ty, right_ty)) continue;
            if (found) |prev| {
                if (!std.mem.eql(u8, prev, symbol)) {
                    self.setError("Ambiguous overload for operator `{s}` on `{s}`", .{ op_name, left_name });
                    return TypeError.AmbiguousCall;
                }
            } else {
                found = symbol;
            }
        }
        return found;
    }

    fn currentUsingModules(self: *TypeChecker, scope: *Scope) std.ArrayList([]const u8) {
        var mods = std.ArrayList([]const u8).init(self.allocator);
        var curr: ?*Scope = scope;
        while (curr) |s| {
            for (s.using_modules.items) |m| {
                mods.append(m) catch {};
            }
            curr = s.parent;
        }
        return mods;
    }

    fn resolveUsingMethodSymbolForType(
        self: *TypeChecker,
        scope: *Scope,
        recv_ty: *ast.Type,
        method_name: []const u8,
        arg_count: usize,
    ) TypeError!?[]const u8 {
        const recv = unwrappedReceiverType(recv_ty);

        var found_symbol: ?[]const u8 = null;
        var mods = self.currentUsingModules(scope);
        defer mods.deinit();
        for (mods.items) |using_path| {
            const symbol = try self.usingSymbolPrefix(using_path, method_name);
            defer self.allocator.free(symbol);
            if (!self.funcs.contains(symbol)) continue;
            const func = self.funcs.get(symbol) orelse continue;
            if (func.params.len != arg_count) continue;
            if (!self.receiverParamMatches(func.params[0], recv_ty)) continue;
            if (found_symbol) |prev| {
                if (!std.mem.eql(u8, prev, symbol)) {
                    const recv_name = if (recv.* == .user_defined) recv.user_defined.name else @tagName(recv.*);
                    self.setError("Ambiguous static extension call `{s}` for type `{s}`", .{ method_name, recv_name });
                    return TypeError.AmbiguousCall;
                }
            } else {
                found_symbol = try self.allocator.dupe(u8, symbol);
            }
        }
        return found_symbol;
    }

    fn isDiscardName(name: []const u8) bool {
        return std.mem.eql(u8, name, "_");
    }

    pub fn deinit(self: *TypeChecker) void {
        self.structs.deinit();
        self.type_aliases.deinit();
        self.alias_struct_cache.deinit();
        self.enums.deinit();
        self.traits.deinit();
        self.trait_impls.deinit();
        self.extern_funcs.deinit();
        self.layout_defines.deinit();
        self.function_aliases.deinit();
        self.function_alias_metadata.deinit();
        self.imported_function_signatures.deinit();
        self.funcs.deinit();
        self.macros.deinit();
        self.imported_macros.deinit();
        var overload_it = self.overloads.valueIterator();
        while (overload_it.next()) |list| {
            list.deinit();
        }
        self.overloads.deinit();
        self.expr_types.deinit();
        self.dyn_call_traits.deinit();
        self.dyn_borrow_args.deinit();
        self.dyn_box_coercions.deinit();
        self.dyn_rc_coercions.deinit();
        self.fn_ptr_calls.deinit();
        self.array_to_slice_borrow_args.deinit();
        self.resolved_call_symbols.deinit();
        self.resolved_call_alias_metadata.deinit();
        for (self.scope_pool.items) |s| {
            s.deinit();
        }
        self.scope_pool.deinit();

        var cleanup_iter = self.cleanups.valueIterator();
        while (cleanup_iter.next()) |list| {
            list.deinit();
        }
        self.cleanups.deinit();

        var await_cleanup_iter = self.await_cleanups.valueIterator();
        while (await_cleanup_iter.next()) |list| {
            list.deinit();
        }
        self.await_cleanups.deinit();

        var macro_try_cleanup_iter = self.macro_call_try_cleanups.valueIterator();
        while (macro_try_cleanup_iter.next()) |list| list.deinit();
        self.macro_call_try_cleanups.deinit();

        var phi_iter = self.phi_cleanups.valueIterator();
        while (phi_iter.next()) |list| {
            list.deinit();
        }
        self.phi_cleanups.deinit();
    }

    fn isInternalSymbol(name: []const u8) bool {
        return lowering_rules.isInternalSymbol(name);
    }

    fn isPrimitiveType(ty: *const ast.Type, primitive: ast.Primitive) bool {
        return lowering_rules.isPrimitiveType(ty, primitive);
    }

    fn isIntegerPrimitive(primitive: ast.Primitive) bool {
        return lowering_rules.isIntegerPrimitive(primitive);
    }

    fn isFloatPrimitive(primitive: ast.Primitive) bool {
        return lowering_rules.isFloatPrimitive(primitive);
    }

    fn isAnyIntegerType(ty: *const ast.Type) bool {
        return lowering_rules.isAnyIntegerType(ty);
    }

    fn isAnyFloatType(ty: *const ast.Type) bool {
        return lowering_rules.isAnyFloatType(ty);
    }

    fn isStringType(ty: *const ast.Type) bool {
        return lowering_rules.isStringType(ty);
    }

    fn isBorrowLikeType(ty: *const ast.Type) bool {
        return lowering_rules.isBorrowLikeType(ty);
    }

    fn iterableElementType(ty: *ast.Type) ?*ast.Type {
        if (arrayType(ty)) |arr| return arr.elem;
        if (sliceElementType(ty)) |elem| return elem;
        if (vecElementType(ty)) |elem| return elem;
        return null;
    }

    fn unwrappedReceiverType(ty: *ast.Type) *ast.Type {
        return lowering_rules.unwrapPointerLikeType(ty);
    }

    pub fn methodForType(self: *TypeChecker, ty: *ast.Type, method_name: []const u8) ?*ast.FuncDecl {
        const recv = unwrappedReceiverType(ty);
        if (recv.* != .user_defined) return null;
        var method_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&method_buf, "{s}_{s}", .{ recv.user_defined.name, method_name }) catch return null;
        return self.funcs.get(key);
    }

    pub fn registerFunctionAlias(self: *TypeChecker, alias: []const u8, target: []const u8) !void {
        try self.registerFunctionAliasWithMetadata(alias, target, null, null);
    }

    pub fn registerFunctionAliasWithMetadata(self: *TypeChecker, alias: []const u8, target: []const u8, namespace: ?[]const u8, module_path: ?[]const u8) !void {
        try self.function_aliases.put(alias, target);
        try self.function_alias_metadata.put(alias, .{
            .alias = alias,
            .target = target,
            .namespace = namespace,
            .module_path = module_path,
        });
    }

    pub fn resolveFunctionAlias(self: *TypeChecker, name: []const u8) []const u8 {
        return self.function_aliases.get(name) orelse name;
    }

    pub fn resolveFunctionAliasMetadata(self: *TypeChecker, name: []const u8) ?FunctionAliasMetadata {
        return self.function_alias_metadata.get(name);
    }

    fn recordResolvedCallSymbol(self: *TypeChecker, expr: *const ast.Node, call_name: []const u8, resolved_name: []const u8) TypeError!void {
        if (self.resolveFunctionAliasMetadata(call_name)) |metadata| {
            try self.resolved_call_symbols.put(expr, metadata.target);
            try self.resolved_call_alias_metadata.put(expr, metadata);
        } else if (self.resolveFunctionAliasMetadata(resolved_name)) |metadata| {
            try self.resolved_call_symbols.put(expr, metadata.target);
            try self.resolved_call_alias_metadata.put(expr, metadata);
        } else {
            try self.resolved_call_symbols.put(expr, resolved_name);
        }
    }

    pub fn registerImportedFunctionSignature(self: *TypeChecker, name: []const u8, params: []const ast.Param, ret_ty: *ast.Type, is_async: bool) !void {
        try self.imported_function_signatures.put(name, .{
            .params = params,
            .ret_ty = ret_ty,
            .is_async = is_async,
        });
    }

    fn receiverParamMatches(self: *TypeChecker, param: ast.Param, recv_ty: *ast.Type) bool {
        const recv = unwrappedReceiverType(recv_ty);
        if (param.is_borrow) return self.typesEqual(param.ty, recv);
        return self.typesEqual(param.ty, recv_ty) or self.typesEqual(param.ty, recv);
    }

    fn checkCallArgsAgainstFunc(
        self: *TypeChecker,
        func: *ast.FuncDecl,
        args: []const *ast.Node,
        scope: *Scope,
        call_name: []const u8,
        auto_borrow_receiver: bool,
    ) TypeError!void {
        try self.checkCallArgsAgainstSignature(func.params, args, scope, call_name, auto_borrow_receiver);
    }

    fn checkCallArgsAgainstSignature(
        self: *TypeChecker,
        params: []const ast.Param,
        args: []const *ast.Node,
        scope: *Scope,
        call_name: []const u8,
        auto_borrow_receiver: bool,
    ) TypeError!void {
        if (params.len != args.len) return TypeError.InvalidArgsCount;
        for (params, args, 0..) |param, arg, i| {
            if (param.is_move and arg.* != .move_expr) return TypeError.TypeMismatch;
            if (param.is_borrow) {
                if (dynTraitName(param.ty)) |trait_name| {
                    const arg_ty = try self.checkExpr(arg, scope);
                    if (dynDispatchTraitName(arg_ty)) |arg_trait_name| {
                        if (!self.traitExtendsTrait(arg_trait_name, trait_name)) return TypeError.TypeMismatch;
                        continue;
                    }
                    const concrete_ty = switch (arg_ty.*) {
                        .borrow => |inner| inner,
                        else => null,
                    } orelse return TypeError.TypeMismatch;
                    if (!self.typeImplementsTrait(concrete_ty, trait_name)) return TypeError.TypeMismatch;
                    self.dyn_borrow_args.put(arg, trait_name) catch return TypeError.OutOfMemory;
                    continue;
                }
            }
            if (auto_borrow_receiver and i == 0 and param.is_borrow and arg.* != .borrow_expr) {
                const arg_ty = try self.checkExpr(arg, scope);
                const effective_ty = switch (arg_ty.*) {
                    .borrow => |inner| inner,
                    else => unwrapBorrowForCallArg(arg, arg_ty),
                };
                if (dynTraitName(param.ty)) |target_trait| {
                    if (dynDispatchTraitName(effective_ty)) |arg_trait_name| {
                        if (!self.traitExtendsTrait(arg_trait_name, target_trait)) return TypeError.TypeMismatch;
                        continue;
                    }
                }
                if (!self.typesEqual(param.ty, effective_ty)) return TypeError.TypeMismatch;
                continue;
            }
            if (param.ty.* == .borrow) {
                const arg_ty = try self.checkExpr(arg, scope);
                if (canCoerceBorrowArrayToBorrowSlice(self, param.ty, arg_ty)) {
                    self.array_to_slice_borrow_args.put(arg, {}) catch return TypeError.OutOfMemory;
                    continue;
                }
                if (arg_ty.* != .borrow or !self.typesEqual(param.ty.borrow, arg_ty.borrow)) return TypeError.TypeMismatch;
                continue;
            }
            if (param.is_borrow and arg.* != .borrow_expr) {
                const arg_ty = try self.checkExpr(arg, scope);
                if (arg_ty.* != .borrow or !self.typesEqual(param.ty, arg_ty.borrow)) return TypeError.TypeMismatch;
                continue;
            }
            if (!param.is_move and !param.is_borrow and
                (arg.* == .move_expr or (arg.* == .borrow_expr and param.ty.* != .pointer)))
            {
                self.setError("Call to {s} passes capability argument to plain parameter {s}", .{ call_name, param.name });
                return TypeError.TypeMismatch;
            }
            const arg_ty = try self.checkExpr(arg, scope);
            if (!self.plainCallArgMatches(param.ty, arg, arg_ty)) return TypeError.TypeMismatch;
            if ((arg.* == .tuple_literal or arg.* == .array_literal) and
                self.typesEqual(arg_ty, param.ty))
            {
                self.expr_types.put(arg, param.ty) catch return TypeError.OutOfMemory;
            }
        }
    }

    fn checkStaticCallBySymbol(
        self: *TypeChecker,
        expr: *ast.Node,
        symbol: []const u8,
        args: []const *ast.Node,
        scope: *Scope,
        call_name: []const u8,
        auto_borrow_receiver: bool,
    ) TypeError!?*ast.Type {
        if (self.funcs.get(symbol)) |func| {
            try self.checkCallArgsAgainstFunc(func, args, scope, call_name, auto_borrow_receiver);
            self.resolved_call_symbols.put(expr, symbol) catch return TypeError.OutOfMemory;
            if (func.is_async) return try self.makeFutureType(func.ret_ty);
            return func.ret_ty;
        }
        if (self.imported_function_signatures.get(symbol)) |signature| {
            try self.checkCallArgsAgainstSignature(signature.params, args, scope, call_name, auto_borrow_receiver);
            self.resolved_call_symbols.put(expr, symbol) catch return TypeError.OutOfMemory;
            if (signature.is_async) return try self.makeFutureType(signature.ret_ty);
            return signature.ret_ty;
        }
        return null;
    }

    fn protocolIterableElementType(self: *TypeChecker, ty: *ast.Type) ?*ast.Type {
        const len_func = self.methodForType(ty, "iter_len") orelse return null;
        const at_func = self.methodForType(ty, "iter_at") orelse return null;
        if (len_func.params.len != 1 or at_func.params.len != 2) return null;
        if (!self.receiverParamMatches(len_func.params[0], ty)) return null;
        if (!self.receiverParamMatches(at_func.params[0], ty)) return null;
        if (!isNumericType(len_func.ret_ty)) return null;
        if (!isNumericType(at_func.params[1].ty)) return null;
        return at_func.ret_ty;
    }

    fn unwrapBorrowForCallArg(arg: *const ast.Node, arg_ty: *ast.Type) *ast.Type {
        if (arg.* == .borrow_expr and arg_ty.* == .borrow) return arg_ty.borrow;
        return arg_ty;
    }

    fn plainCallArgMatches(self: *TypeChecker, param_ty: *const ast.Type, arg: *const ast.Node, arg_ty: *ast.Type) bool {
        if (self.typesEqual(@constCast(param_ty), unwrapBorrowForCallArg(arg, arg_ty))) return true;
        if (arg.* == .literal and arg.literal == .string_val and isStringType(param_ty)) return true;
        if (arg.* == .borrow_expr and arg_ty.* == .borrow and canCoerceBorrowArrayToBorrowSlice(self, @constCast(param_ty), arg_ty)) {
            self.array_to_slice_borrow_args.put(@constCast(arg), {}) catch return false;
            return true;
        }
        if (arg.* != .borrow_expr or arg_ty.* != .borrow) return false;
        return switch (param_ty.*) {
            .pointer => |inner| self.typesEqual(inner, arg_ty.borrow),
            else => false,
        };
    }

    fn isNumericType(ty: *const ast.Type) bool {
        return lowering_rules.isNumericType(ty);
    }

    fn isCellValueType(ty: *const ast.Type) bool {
        return lowering_rules.isCellValueType(ty);
    }

    fn isPollScalarValueType(ty: *const ast.Type) bool {
        return lowering_rules.isPollScalarValueType(ty);
    }

    fn isRawPtrAliasType(ty: *const ast.Type) bool {
        return lowering_rules.isRawPtrAliasType(ty);
    }

    fn isPointerValueType(ty: *const ast.Type) bool {
        return lowering_rules.isPointerValueType(ty);
    }

    fn valueAssignableTo(self: *TypeChecker, expected: *ast.Type, actual: *ast.Type) bool {
        if (self.typesEqual(expected, actual)) return true;
        return isRawPtrAliasType(expected) and actual.* == .pointer;
    }

    fn isPointerCarrierCastType(ty: *const ast.Type) bool {
        return lowering_rules.isPointerCarrierCastType(ty);
    }

    fn unwrapPointerLikeType(ty: *ast.Type) *ast.Type {
        return lowering_rules.unwrapPointerLikeType(ty);
    }

    fn structDeclForType(self: *TypeChecker, ty: *ast.Type) ?*ast.StructDecl {
        const curr = unwrapPointerLikeType(ty);
        switch (curr.*) {
            .user_defined => |ud| {
                if (self.structs.get(ud.name)) |decl| return decl;
                if (self.type_aliases.get(ud.name)) |alias| return self.syntheticStructDecl(alias);
                return null;
            },
            else => return null,
        }
    }

    fn syntheticStructDecl(self: *TypeChecker, alias: *ast.TypeAliasDecl) ?*ast.StructDecl {
        if (self.alias_struct_cache.get(alias.name)) |cached| return cached;

        const synthetic = self.allocator.create(ast.StructDecl) catch return null;
        synthetic.* = .{ .name = alias.name, .generics = &.{}, .fields = &.{}, .derives = &.{}, .is_union = false, .is_opaque = false };
        self.alias_struct_cache.put(alias.name, synthetic) catch return null;

        var fields = std.ArrayList(ast.Field).init(self.allocator);
        defer fields.deinit();
        for (alias.components) |component| {
            switch (component) {
                .ty => |ty| {
                    if (self.structDeclForType(ty)) |src_decl| {
                        for (src_decl.fields) |field| {
                            fields.append(.{ .name = field.name, .ty = field.ty }) catch return null;
                        }
                    } else {
                        fields.append(.{ .name = alias.name, .ty = ty }) catch return null;
                    }
                },
                .inline_struct => |inline_fields| {
                    for (inline_fields) |field| {
                        fields.append(field) catch return null;
                    }
                },
            }
        }
        synthetic.fields = fields.toOwnedSlice() catch return null;
        return synthetic;
    }

    fn deriveNameMatches(actual: []const u8, wanted: []const u8) bool {
        return lowering_rules.deriveNameMatches(actual, wanted);
    }

    fn structHasDerive(decl: *const ast.StructDecl, name: []const u8) bool {
        return lowering_rules.structHasDerive(decl, name);
    }

    fn typeIsCopy(self: *TypeChecker, ty: *ast.Type) bool {
        // Use derive base (not full Copy-value base) so fn_ptr stays non-Copy in
        // typecheck, matching the pre-share behavior.
        if (lowering_rules.typeHasCopyDeriveBase(ty)) |decision| return decision;
        return switch (ty.*) {
            .user_defined => blk: {
                const decl = self.structDeclForType(ty) orelse break :blk false;
                if (!lowering_rules.typeHasCopyDeriveStructGate(decl)) break :blk false;
                for (decl.fields) |field| {
                    if (!self.typeIsCopy(field.ty)) break :blk false;
                }
                break :blk true;
            },
            .tuple => |tuple| blk: {
                for (tuple.elems) |elem| {
                    if (!self.typeIsCopy(elem)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    fn typeIsEq(self: *TypeChecker, ty: *ast.Type) bool {
        const primitive_ok = if (ty.* == .primitive) lowering_rules.primitiveIsCopyValue(ty.primitive) else false;
        if (lowering_rules.typeHasNamedDeriveBase(ty, primitive_ok)) |decision| return decision;
        if (ty.* != .user_defined) return false;
        const decl = self.structDeclForType(ty) orelse return false;
        if (!lowering_rules.typeHasNamedDeriveStructGate(decl, "eq")) return false;
        for (decl.fields) |field| {
            if (!self.typeIsEq(field.ty)) return false;
        }
        return true;
    }

    fn typeIsOrd(self: *TypeChecker, ty: *ast.Type) bool {
        const primitive_ok = if (ty.* == .primitive) lowering_rules.primitiveIsHashable(ty.primitive) else false;
        if (lowering_rules.typeHasNamedDeriveBase(ty, primitive_ok)) |decision| return decision;
        if (ty.* != .user_defined) return false;
        const decl = self.structDeclForType(ty) orelse return false;
        if (!lowering_rules.typeHasNamedDeriveStructGate(decl, "ord")) return false;
        for (decl.fields) |field| {
            if (!self.typeIsOrd(field.ty)) return false;
        }
        return true;
    }

    fn typeIsHash(self: *TypeChecker, ty: *ast.Type) bool {
        const primitive_ok = if (ty.* == .primitive) lowering_rules.primitiveIsHashable(ty.primitive) else false;
        if (lowering_rules.typeHasNamedDeriveBase(ty, primitive_ok)) |decision| return decision;
        if (ty.* != .user_defined) return false;
        const decl = self.structDeclForType(ty) orelse return false;
        if (!lowering_rules.typeHasNamedDeriveStructGate(decl, "hash")) return false;
        for (decl.fields) |field| {
            if (!self.typeIsHash(field.ty)) return false;
        }
        return true;
    }

    fn typeIsDebug(self: *TypeChecker, ty: *ast.Type) bool {
        const primitive_ok = if (ty.* == .primitive) lowering_rules.primitiveIsCopyValue(ty.primitive) else false;
        if (lowering_rules.typeHasNamedDeriveBase(ty, primitive_ok)) |decision| return decision;
        if (ty.* != .user_defined) return false;
        const decl = self.structDeclForType(ty) orelse return false;
        if (!lowering_rules.typeHasNamedDeriveStructGate(decl, "debug")) return false;
        for (decl.fields) |field| {
            if (!self.typeIsDebug(field.ty)) return false;
        }
        return true;
    }

    fn structFieldsAllNumeric(decl: *const ast.StructDecl) bool {
        return lowering_rules.structFieldsAllNumeric(decl);
    }

    fn structFieldsAllComparable(decl: *const ast.StructDecl) bool {
        return lowering_rules.structFieldsAllComparable(decl);
    }

    fn literalZero(expr: *const ast.Node) bool {
        return lowering_rules.literalZero(expr);
    }

    fn isStringLikeType(ty: *const ast.Type) bool {
        return lowering_rules.isStringLikeType(ty);
    }

    fn dynTraitName(ty: *ast.Type) ?[]const u8 {
        return lowering_rules.dynTraitName(ty);
    }

    fn arrayType(ty: *ast.Type) ?ast.ArrayType {
        return lowering_rules.arrayType(ty);
    }

    fn sliceElementType(ty: *ast.Type) ?*ast.Type {
        return lowering_rules.sliceElementType(ty);
    }

    fn canCoerceBorrowArrayToBorrowSlice(self: *TypeChecker, param_ty: *ast.Type, arg_ty: *ast.Type) bool {
        if (arg_ty.* != .borrow) return false;
        const target_ty = if (param_ty.* == .borrow) param_ty.borrow else param_ty;
        const slice_elem = sliceElementType(target_ty) orelse return false;
        const arr = arrayType(arg_ty.borrow) orelse return false;
        return self.typesEqual(slice_elem, arr.elem);
    }

    fn checkClosureLiteralWithContext(
        self: *TypeChecker,
        expr: *ast.Node,
        scope: *Scope,
        contextual_params: []const *ast.Type,
    ) TypeError!*ast.Type {
        if (expr.* != .closure_literal) return TypeError.TypeMismatch;
        const lit = &expr.closure_literal;
        if (lit.params.len != contextual_params.len) return TypeError.InvalidArgsCount;

        const closure_scope = try Scope.init(self.allocator, scope);
        try self.scope_pool.append(closure_scope);

        var param_types = std.ArrayList(*ast.Type).init(self.allocator);
        for (lit.params, contextual_params) |p, ctx_ty| {
            if (p.ty.* != .infer and !self.typesEqual(p.ty, ctx_ty)) return TypeError.TypeMismatch;
            try self.defineSymbol(closure_scope, p.name, ctx_ty, true);
            try param_types.append(ctx_ty);
        }

        const ret_ty = try self.checkExpr(lit.body, closure_scope);
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .closure = .{ .params = try param_types.toOwnedSlice(), .ret = ret_ty } };
        self.expr_types.put(expr, ty) catch return TypeError.OutOfMemory;
        return ty;
    }

    fn makeFutureType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .future = inner };
        return ty;
    }

    fn makeFuturePairType(self: *TypeChecker, left: *ast.Type, right: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 2);
        generics[0] = left;
        generics[1] = right;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "FuturePair", .generics = generics } };
        return ty;
    }

    fn makeFutureEitherType(self: *TypeChecker, left: *ast.Type, right: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 2);
        generics[0] = left;
        generics[1] = right;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "FutureEither", .generics = generics } };
        return ty;
    }

    fn makeBorrowType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .borrow = inner };
        return ty;
    }

    fn makePointerType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .pointer = inner };
        return ty;
    }

    fn makeFnPtrType(self: *TypeChecker, abi: ?[]const u8, params: []const *ast.Type, ret: *ast.Type) TypeError!*ast.Type {
        const owned_params = try self.allocator.alloc(*ast.Type, params.len);
        for (params, 0..) |param, i| owned_params[i] = param;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .fn_ptr = .{ .abi = abi, .params = owned_params, .ret = ret } };
        return ty;
    }

    fn makeInferType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .infer;
        return ty;
    }

    fn makeOptionType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Option", .generics = generics } };
        return ty;
    }

    fn makeResultType(self: *TypeChecker, ok_ty: *ast.Type, err_ty: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 2);
        generics[0] = ok_ty;
        generics[1] = err_ty;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Result", .generics = generics } };
        return ty;
    }

    fn makeJoinHandleType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "JoinHandle", .generics = generics } };
        return ty;
    }

    fn makeTaskType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Task", .generics = generics } };
        return ty;
    }

    fn makeExecutorType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Executor", .generics = generics } };
        return ty;
    }

    fn makePollType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Poll", .generics = generics } };
        return ty;
    }

    fn makeSenderType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Sender", .generics = generics } };
        return ty;
    }

    fn makeReceiverType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Receiver", .generics = generics } };
        return ty;
    }

    fn makeTupleType(self: *TypeChecker, elems: []const *ast.Type) TypeError!*ast.Type {
        const owned = try self.allocator.alloc(*ast.Type, elems.len);
        for (elems, 0..) |elem, i| owned[i] = elem;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .tuple = .{ .elems = owned } };
        return ty;
    }

    fn makeI32Type(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .i32 };
        return ty;
    }

    fn makeI64Type(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .i64 };
        return ty;
    }

    fn makeRawPtrType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .raw_ptr };
        return ty;
    }

    fn makeBoolType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .boolean };
        return ty;
    }

    fn makeU8Type(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .u8 };
        return ty;
    }

    fn makeU64Type(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .u64 };
        return ty;
    }

    fn makeSliceType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Slice", .generics = generics } };
        return ty;
    }

    fn makePrimitiveType(self: *TypeChecker, primitive: ast.Primitive) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = primitive };
        return ty;
    }

    fn makeImportedMacroExpressionResultType(
        self: *TypeChecker,
        kind: lowering_rules.ImportedMacroExpressionResultKind,
    ) TypeError!*ast.Type {
        return switch (kind) {
            .raw_pointer => try self.makeRawPtrType(),
            .boolean => try self.makeBoolType(),
            .u8 => try self.makeU8Type(),
            .u32 => try self.makePrimitiveType(.u32),
            .u64 => try self.makeU64Type(),
            .i32 => try self.makeI32Type(),
            .i64 => try self.makeI64Type(),
            .f64 => try self.makePrimitiveType(.f64),
            .slice_u8 => try self.makeSliceType(try self.makeU8Type()),
        };
    }

    fn makeStringType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "String", .generics = &.{} } };
        return ty;
    }

    fn makeFileType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "File", .generics = &.{} } };
        return ty;
    }

    fn makeMetadataType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Metadata", .generics = &.{} } };
        return ty;
    }

    fn makeAtomicI32Type(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "AtomicI32", .generics = &.{} } };
        return ty;
    }

    fn makeAtomicUsizeType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "AtomicUsize", .generics = &.{} } };
        return ty;
    }

    fn makeCellType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Cell", .generics = generics } };
        return ty;
    }

    fn makeRefCellType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "RefCell", .generics = generics } };
        return ty;
    }

    fn makeMutexType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Mutex", .generics = generics } };
        return ty;
    }

    fn makeMutexGuardType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "MutexGuard", .generics = generics } };
        return ty;
    }

    fn makeRwLockType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "RwLock", .generics = generics } };
        return ty;
    }

    fn makeRwLockReadGuardType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "RwLockReadGuard", .generics = generics } };
        return ty;
    }

    fn makeRwLockWriteGuardType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "RwLockWriteGuard", .generics = generics } };
        return ty;
    }

    fn makeOrderingType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Ordering", .generics = &.{} } };
        return ty;
    }

    fn makeBoxType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Box", .generics = generics } };
        return ty;
    }

    fn makeManuallyDropType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "ManuallyDrop", .generics = generics } };
        return ty;
    }

    fn makeRcType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Rc", .generics = generics } };
        return ty;
    }

    fn makeArcType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Arc", .generics = generics } };
        return ty;
    }

    fn makeAtomicPtrType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "AtomicPtr", .generics = generics } };
        return ty;
    }

    fn makeVecType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Vec", .generics = generics } };
        return ty;
    }

    fn makeVecDequeType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "VecDeque", .generics = generics } };
        return ty;
    }

    fn makeHashMapType(self: *TypeChecker, key_ty: *ast.Type, value_ty: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 2);
        generics[0] = key_ty;
        generics[1] = value_ty;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "HashMap", .generics = generics } };
        return ty;
    }

    fn makeHashSetType(self: *TypeChecker, key_ty: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = key_ty;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "HashSet", .generics = generics } };
        return ty;
    }

    fn makeBTreeMapType(self: *TypeChecker, key_ty: *ast.Type, value_ty: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 2);
        generics[0] = key_ty;
        generics[1] = value_ty;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "BTreeMap", .generics = generics } };
        return ty;
    }

    fn makeBTreeSetType(self: *TypeChecker, key_ty: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = key_ty;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "BTreeSet", .generics = generics } };
        return ty;
    }

    fn boxInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.boxInnerType(ty);
    }

    fn manuallyDropInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.manuallyDropInnerType(ty);
    }

    fn rcInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.rcInnerType(ty);
    }

    fn arcInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.arcInnerType(ty);
    }

    fn vecElementType(ty: *const ast.Type) ?*ast.Type {
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

    fn atomicPtrInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.atomicPtrInnerType(ty);
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

    fn isOrderingType(ty: *const ast.Type) bool {
        return lowering_rules.isOrderingType(ty);
    }

    fn isFileType(ty: *const ast.Type) bool {
        return lowering_rules.isFileType(ty);
    }

    fn isMetadataType(ty: *const ast.Type) bool {
        return lowering_rules.isMetadataType(ty);
    }

    fn isOrderingName(name: []const u8) bool {
        return lowering_rules.isOrderingName(name);
    }

    const HashMapTypes = struct {
        key: *ast.Type,
        value: *ast.Type,
    };

    fn hashMapTypes(ty: *const ast.Type) ?HashMapTypes {
        const mapped = lowering_rules.hashMapTypes(ty) orelse return null;
        return .{ .key = mapped.key, .value = mapped.value };
    }

    const HashSetTypes = struct {
        key: *ast.Type,
    };

    fn hashSetTypes(ty: *const ast.Type) ?HashSetTypes {
        const key = lowering_rules.hashSetElementType(ty) orelse return null;
        return .{ .key = key };
    }

    const BTreeMapTypes = struct {
        key: *ast.Type,
        value: *ast.Type,
    };

    fn btreeMapTypes(ty: *const ast.Type) ?BTreeMapTypes {
        const mapped = lowering_rules.btreeMapTypes(ty) orelse return null;
        return .{ .key = mapped.key, .value = mapped.value };
    }

    const BTreeSetTypes = struct {
        key: *ast.Type,
    };

    fn btreeSetTypes(ty: *const ast.Type) ?BTreeSetTypes {
        const key = lowering_rules.btreeSetElementType(ty) orelse return null;
        return .{ .key = key };
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

    fn patternBindingType(self: *TypeChecker, pattern: ast.EnumPattern, value_ty: *const ast.Type, comptime context: []const u8) TypeError!?*ast.Type {
        if (optionInnerType(value_ty)) |inner_ty| {
            if (!std.mem.eql(u8, pattern.enum_name, "Option")) {
                self.setError(context ++ " pattern must match Option<T>, got {s}", .{pattern.enum_name});
                return TypeError.TypeMismatch;
            }
            if (std.mem.eql(u8, pattern.variant_name, "Some")) {
                if (pattern.bindings.len != 1) {
                    self.setError("Some pattern requires one binding", .{});
                    return TypeError.InvalidArgsCount;
                }
                return inner_ty;
            }
            if (std.mem.eql(u8, pattern.variant_name, "None")) {
                if (pattern.bindings.len != 0) {
                    self.setError("None pattern requires zero bindings", .{});
                    return TypeError.InvalidArgsCount;
                }
                return null;
            }
            self.setError("unsupported Option variant {s} in " ++ context, .{pattern.variant_name});
            return TypeError.TypeMismatch;
        }

        if (resultOkType(value_ty)) |ok_ty| {
            const err_ty = resultErrType(value_ty) orelse return TypeError.TypeMismatch;
            if (!std.mem.eql(u8, pattern.enum_name, "Result")) {
                self.setError(context ++ " pattern must match Result<T, E>, got {s}", .{pattern.enum_name});
                return TypeError.TypeMismatch;
            }
            if (std.mem.eql(u8, pattern.variant_name, "Ok")) {
                if (pattern.bindings.len != 1) {
                    self.setError("Ok pattern requires one binding", .{});
                    return TypeError.InvalidArgsCount;
                }
                return ok_ty;
            }
            if (std.mem.eql(u8, pattern.variant_name, "Err")) {
                if (pattern.bindings.len != 1) {
                    self.setError("Err pattern requires one binding", .{});
                    return TypeError.InvalidArgsCount;
                }
                return err_ty;
            }
            self.setError("unsupported Result variant {s} in " ++ context, .{pattern.variant_name});
            return TypeError.TypeMismatch;
        }

        self.setError(context ++ " value must be Option<T> or Result<T, E>", .{});
        return TypeError.TypeMismatch;
    }

    fn enumDeclForValueType(self: *TypeChecker, value_ty: *const ast.Type) ?*ast.EnumDecl {
        const curr = lowering_rules.peelBorrowPointerType(value_ty);
        if (curr.* != .user_defined) return null;
        return self.enums.get(curr.user_defined.name);
    }

    fn definePatternBindings(self: *TypeChecker, scope: *Scope, pattern: ast.EnumPattern, value_ty: *const ast.Type, comptime context: []const u8, writable: bool) TypeError!void {
        if (optionInnerType(value_ty) != null or resultOkType(value_ty) != null) {
            const binding_ty = try self.patternBindingType(pattern, value_ty, context);
            if (binding_ty) |ty| {
                try self.defineSymbol(scope, pattern.bindings[0], ty, writable);
            }
            return;
        }

        const decl = self.enumDeclForValueType(value_ty) orelse {
            self.setError(context ++ " value must be Option<T>, Result<T, E>, or enum", .{});
            return TypeError.TypeMismatch;
        };
        if (!enumNameMatchesDecl(pattern.enum_name, decl.name)) {
            self.setError(context ++ " pattern must match enum {s}, got {s}", .{ decl.name, pattern.enum_name });
            return TypeError.TypeMismatch;
        }
        const variant = findEnumVariant(decl, pattern.variant_name) orelse return TypeError.FieldNotFound;
        if (pattern.bindings.len != variant.fields.len) return TypeError.InvalidArgsCount;
        for (pattern.bindings, variant.fields) |binding, field| {
            try self.defineSymbol(scope, binding, field.ty, writable);
        }
    }

    fn joinHandleInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.joinHandleInnerType(ty);
    }

    fn taskInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.taskInnerType(ty);
    }

    fn executorTaskBufferInnerType(ty: *const ast.Type) ?*ast.Type {
        const plan = lowering_rules.executorTaskBufferPlan(ty) orelse return null;
        return plan.inner;
    }

    fn futureInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.futureInnerType(ty);
    }

    const FuturePairInnerTypes = struct {
        left: *ast.Type,
        right: *ast.Type,
    };

    fn futurePairInnerTypes(ty: *const ast.Type) ?FuturePairInnerTypes {
        const mapped = lowering_rules.futurePairInnerTypes(ty) orelse return null;
        return .{ .left = mapped.key, .right = mapped.value };
    }

    fn checkFutureJoin2Call(self: *TypeChecker, call: ast.CallExpr, scope: *Scope) TypeError!*ast.Type {
        if (call.args.len != 2) return TypeError.InvalidArgsCount;
        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
        const left_ty = try self.checkExpr(call.args[0], scope);
        const right_ty = try self.checkExpr(call.args[1], scope);
        const left_inner = futureInnerType(left_ty) orelse return TypeError.TypeMismatch;
        const right_inner = futureInnerType(right_ty) orelse return TypeError.TypeMismatch;
        if (!isPollScalarValueType(left_inner) or !isPollScalarValueType(right_inner)) return TypeError.TypeMismatch;
        const pair_ty = try self.makeFuturePairType(left_inner, right_inner);
        return try self.makeFutureType(pair_ty);
    }

    fn checkFuturePairAccessorCall(self: *TypeChecker, call: ast.CallExpr, scope: *Scope, want_left: bool) TypeError!*ast.Type {
        if (call.args.len != 1) return TypeError.InvalidArgsCount;
        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
        const pair_ty = try self.checkExpr(call.args[0], scope);
        const pair = futurePairInnerTypes(pair_ty) orelse return TypeError.TypeMismatch;
        const out_ty = if (want_left) pair.left else pair.right;
        if (!isPollScalarValueType(out_ty)) return TypeError.TypeMismatch;
        return out_ty;
    }

    const FutureEitherInnerTypes = struct {
        left: *ast.Type,
        right: *ast.Type,
    };

    fn futureEitherInnerTypes(ty: *const ast.Type) ?FutureEitherInnerTypes {
        const mapped = lowering_rules.futureEitherInnerTypes(ty) orelse return null;
        return .{ .left = mapped.key, .right = mapped.value };
    }

    fn checkFutureSelect2Call(self: *TypeChecker, call: ast.CallExpr, scope: *Scope) TypeError!*ast.Type {
        if (call.args.len != 2) return TypeError.InvalidArgsCount;
        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
        const left_ty = try self.checkExpr(call.args[0], scope);
        const right_ty = try self.checkExpr(call.args[1], scope);
        const left_inner = futureInnerType(left_ty) orelse return TypeError.TypeMismatch;
        const right_inner = futureInnerType(right_ty) orelse return TypeError.TypeMismatch;
        if (!isPollScalarValueType(left_inner) or !isPollScalarValueType(right_inner)) return TypeError.TypeMismatch;
        const either_ty = try self.makeFutureEitherType(left_inner, right_inner);
        return try self.makeFutureType(either_ty);
    }

    fn checkFutureEitherSideCall(self: *TypeChecker, call: ast.CallExpr, scope: *Scope) TypeError!*ast.Type {
        if (call.args.len != 1) return TypeError.InvalidArgsCount;
        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
        const either_ty = try self.checkExpr(call.args[0], scope);
        _ = futureEitherInnerTypes(either_ty) orelse return TypeError.TypeMismatch;
        return try self.makeU64Type();
    }

    fn checkFutureEitherAccessorCall(self: *TypeChecker, call: ast.CallExpr, scope: *Scope, want_left: bool) TypeError!*ast.Type {
        if (call.args.len != 1) return TypeError.InvalidArgsCount;
        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
        const either_ty = try self.checkExpr(call.args[0], scope);
        const either = futureEitherInnerTypes(either_ty) orelse return TypeError.TypeMismatch;
        const out_ty = if (want_left) either.left else either.right;
        if (!isPollScalarValueType(out_ty)) return TypeError.TypeMismatch;
        return out_ty;
    }

    fn executorInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.executorInnerType(ty);
    }

    fn pollInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.pollInnerType(ty);
    }

    fn senderInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.senderInnerType(ty);
    }

    fn receiverInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.receiverInnerType(ty);
    }

    fn dynDispatchTraitName(ty: *const ast.Type) ?[]const u8 {
        if (dynTraitName(@constCast(ty))) |name| return name;
        if (boxInnerType(ty)) |inner| {
            return dynTraitName(inner);
        }
        if (rcInnerType(ty)) |inner| {
            return dynTraitName(inner);
        }
        return null;
    }

    fn canCoerceToDynBox(self: *TypeChecker, declared_ty: *const ast.Type, val_ty: *const ast.Type) ?[]const u8 {
        const declared_inner = boxInnerType(declared_ty) orelse return null;
        const trait_name = dynTraitName(declared_inner) orelse return null;
        const val_inner = boxInnerType(val_ty) orelse return null;
        if (!self.typeImplementsTrait(val_inner, trait_name)) return null;
        return trait_name;
    }

    fn canCoerceRcNewToDynRc(self: *TypeChecker, declared_ty: *const ast.Type, val_ty: *const ast.Type, value_expr: *const ast.Node) ?[]const u8 {
        const declared_inner = rcInnerType(declared_ty) orelse return null;
        const trait_name = dynTraitName(declared_inner) orelse return null;
        const val_inner = rcInnerType(val_ty) orelse return null;
        if (!self.typeImplementsTrait(val_inner, trait_name)) return null;
        if (value_expr.* != .call_expr) return null;
        const call = value_expr.call_expr;
        if (!lowering_rules.isRcNewCall(call)) return null;
        return trait_name;
    }

    fn rootIdentifier(expr: *const ast.Node) ?[]const u8 {
        return switch (expr.*) {
            .identifier => |name| name,
            .index_expr => |idx| rootIdentifier(idx.target),
            .field_expr => |field| rootIdentifier(field.expr),
            else => null,
        };
    }

    fn borrowExprRootIdentifier(expr: *const ast.Node) ?[]const u8 {
        return switch (expr.*) {
            .borrow_expr => |borrow| rootIdentifier(borrow.expr),
            else => null,
        };
    }

    fn exprUsesIdentifierValue(expr: *const ast.Node, name: []const u8) bool {
        return switch (expr.*) {
            .identifier => |ident| std.mem.eql(u8, ident, name),
            .await_expr => |aw| exprUsesIdentifierValue(aw.expr, name),
            .move_expr => |mv| exprUsesIdentifierValue(mv.expr, name),
            .cast_expr => |cast| exprUsesIdentifierValue(cast.expr, name),
            .binary_expr => |bin| exprUsesIdentifierValue(bin.left, name) or exprUsesIdentifierValue(bin.right, name),
            .call_expr => |call| blk: {
                for (call.args) |arg| {
                    if (exprUsesIdentifierValue(arg, name)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| blk: {
                if (exprUsesIdentifierValue(ife.cond, name)) break :blk true;
                if (blockUsesIdentifierValue(ife.then_block, name)) break :blk true;
                if (ife.else_block) |else_block| {
                    if (blockUsesIdentifierValue(else_block, name)) break :blk true;
                }
                break :blk false;
            },
            .switch_expr => |swe| blk: {
                if (exprUsesIdentifierValue(swe.val, name)) break :blk true;
                for (swe.cases) |case| {
                    if (blockUsesIdentifierValue(case.body, name)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (exprUsesIdentifierValue(mat.val, name)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| {
                        if (exprUsesIdentifierValue(guard, name)) break :blk true;
                    }
                    if (blockUsesIdentifierValue(case.body, name)) break :blk true;
                }
                break :blk false;
            },
            .try_expr => |trye| exprUsesIdentifierValue(trye.expr, name),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprUsesIdentifierValue(field.value, name)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprUsesIdentifierValue(field.value, name)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprUsesIdentifierValue(elem, name)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprUsesIdentifierValue(elem, name)) break :blk true;
                }
                break :blk false;
            },
            .repeat_array_literal => |lit| exprUsesIdentifierValue(lit.value, name),
            .index_expr => |idx| exprUsesIdentifierValue(idx.index, name),
            .slice_expr => |slc| exprUsesIdentifierValue(slc.start, name) or exprUsesIdentifierValue(slc.end, name),
            else => false,
        };
    }

    fn stmtUsesIdentifierValue(stmt: *const ast.Node, name: []const u8) bool {
        return switch (stmt.*) {
            .let_stmt => |let| exprUsesIdentifierValue(let.value, name),
            .let_else_stmt => |let| exprUsesIdentifierValue(let.value, name) or blockUsesIdentifierValue(let.else_block, name),
            .let_destructure_stmt => |let| exprUsesIdentifierValue(let.value, name),
            .const_stmt => |c| exprUsesIdentifierValue(c.value, name),
            .assign_stmt => |assign| exprUsesIdentifierValue(assign.value, name),
            .expr_stmt => |expr| exprUsesIdentifierValue(expr, name),
            .return_stmt => |ret| if (ret.value) |value| exprUsesIdentifierValue(value, name) else false,
            .for_stmt => |f| exprUsesIdentifierValue(f.start, name) or (if (f.end) |end_expr| exprUsesIdentifierValue(end_expr, name) else false) or blockUsesIdentifierValue(f.body, name),
            .while_stmt => |w| exprUsesIdentifierValue(w.cond, name) or blockUsesIdentifierValue(w.body, name),
            .block_stmt => |blk| blockUsesIdentifierValue(blk.body, name),
            else => false,
        };
    }

    fn blockUsesIdentifierValue(body: []const *ast.Node, name: []const u8) bool {
        for (body) |stmt| {
            if (stmtUsesIdentifierValue(stmt, name)) return true;
        }
        return false;
    }

    fn findEnumVariant(e: *const ast.EnumDecl, name: []const u8) ?ast.EnumVariant {
        for (e.variants) |variant| {
            if (std.mem.eql(u8, variant.name, name)) return variant;
        }
        return null;
    }

    fn enumNameMatchesDecl(pattern_name: []const u8, decl_name: []const u8) bool {
        if (std.mem.eql(u8, pattern_name, decl_name)) return true;
        if (decl_name.len <= pattern_name.len) return false;
        if (!std.mem.startsWith(u8, decl_name, pattern_name)) return false;
        return decl_name[pattern_name.len] == '_';
    }

    fn concreteTypeName(ty: *const ast.Type) ?[]const u8 {
        return lowering_rules.concreteTypeName(ty);
    }

    fn traitExtendsTrait(self: *TypeChecker, trait_name: []const u8, target_trait: []const u8) bool {
        if (std.mem.eql(u8, trait_name, target_trait)) return true;
        const decl = self.traits.get(trait_name) orelse return false;
        for (decl.supertraits) |supertrait| {
            if (self.traitExtendsTrait(supertrait, target_trait)) return true;
        }
        return false;
    }

    fn findTraitMethod(self: *TypeChecker, trait_name: []const u8, method_name: []const u8) ?ast.TraitMethod {
        const decl = self.traits.get(trait_name) orelse return null;
        for (decl.supertraits) |supertrait| {
            if (self.findTraitMethod(supertrait, method_name)) |method| return method;
        }
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, method_name)) return method;
        }
        return null;
    }

    fn findTraitOwnMethod(self: *TypeChecker, trait_name: []const u8, method_name: []const u8) ?ast.TraitMethod {
        const decl = self.traits.get(trait_name) orelse return null;
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, method_name)) return method;
        }
        return null;
    }

    fn findTraitDeclaringMethod(self: *TypeChecker, trait_name: []const u8, method_name: []const u8) ?[]const u8 {
        const decl = self.traits.get(trait_name) orelse return null;
        for (decl.supertraits) |supertrait| {
            if (self.findTraitDeclaringMethod(supertrait, method_name)) |owner| return owner;
        }
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, method_name)) return trait_name;
        }
        return null;
    }

    fn typeDirectlyImplementsTrait(self: *TypeChecker, type_name: []const u8, trait_name: []const u8) bool {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}|{s}", .{ trait_name, type_name }) catch return false;
        return self.trait_impls.contains(key);
    }

    fn traitMethodSymbolAlloc(self: *TypeChecker, impl_trait: []const u8, type_name: []const u8, method_name: []const u8) TypeError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}__{s}_{s}", .{ type_name, impl_trait, method_name }) catch return TypeError.OutOfMemory;
    }

    fn functionOrImportedSignatureParamCount(self: *TypeChecker, symbol: []const u8) ?usize {
        if (self.funcs.get(symbol)) |func| return func.params.len;
        if (self.imported_function_signatures.get(symbol)) |signature| return signature.params.len;
        return null;
    }

    fn resolveTraitMethodSymbolForType(
        self: *TypeChecker,
        type_name: []const u8,
        target_trait: ?[]const u8,
        method_name: []const u8,
        arg_count: usize,
    ) TypeError!?[]const u8 {
        if (target_trait) |trait_name| {
            if (!self.typeDirectlyImplementsTrait(type_name, trait_name) and !self.typeImplementsTraitName(type_name, trait_name)) return null;
            const declaring_trait = self.findTraitDeclaringMethod(trait_name, method_name) orelse return null;
            const symbol = try self.traitMethodSymbolAlloc(declaring_trait, type_name, method_name);
            const param_count = self.functionOrImportedSignatureParamCount(symbol) orelse return null;
            if (param_count != arg_count) return null;
            return symbol;
        }

        var it = self.trait_impls.iterator();
        var found: ?[]const u8 = null;
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const sep = std.mem.indexOfScalar(u8, key, '|') orelse continue;
            const impl_trait = key[0..sep];
            const impl_type = key[sep + 1 ..];
            if (!std.mem.eql(u8, impl_type, type_name)) continue;
            const declaring_trait = self.findTraitDeclaringMethod(impl_trait, method_name) orelse continue;

            const symbol = try self.traitMethodSymbolAlloc(declaring_trait, type_name, method_name);
            const param_count = self.functionOrImportedSignatureParamCount(symbol) orelse continue;
            if (param_count != arg_count) continue;
            if (found) |existing| {
                if (std.mem.eql(u8, existing, symbol)) continue;
                self.setError("Ambiguous trait method `{s}` for type `{s}`", .{ method_name, type_name });
                return TypeError.TypeMismatch;
            }
            found = symbol;
        }
        return found;
    }

    fn typeImplementsTraitName(self: *TypeChecker, type_name: []const u8, trait_name: []const u8) bool {
        if (self.typeDirectlyImplementsTrait(type_name, trait_name)) return true;
        var it = self.trait_impls.iterator();
        while (it.next()) |entry| {
            const impl_key = entry.key_ptr.*;
            const sep = std.mem.indexOfScalar(u8, impl_key, '|') orelse continue;
            const impl_trait = impl_key[0..sep];
            const impl_type = impl_key[sep + 1 ..];
            if (std.mem.eql(u8, impl_type, type_name) and self.traitExtendsTrait(impl_trait, trait_name)) return true;
        }
        return false;
    }

    fn typeImplementsTrait(self: *TypeChecker, ty: *const ast.Type, trait_name: []const u8) bool {
        if (dynTraitName(@constCast(ty))) |dyn_name| {
            return self.traitExtendsTrait(dyn_name, trait_name);
        }
        const type_name = concreteTypeName(ty) orelse return false;
        return self.typeImplementsTraitName(type_name, trait_name);
    }

    fn normalizeAbiTypeName(name: []const u8) []const u8 {
        var ty = std.mem.trim(u8, name, " \t\r");
        while (ty.len > 0 and (ty[0] == '^' or ty[0] == '&' or ty[0] == '*')) {
            ty = ty[1..];
        }
        return ty;
    }

    fn isPointerAbiType(name: []const u8) bool {
        return lowering_rules.isPointerAbiTypeName(name);
    }

    fn isIntegerAbiType(name: []const u8) bool {
        return lowering_rules.isIntegerAbiTypeName(name);
    }

    fn setTypeFromAbiReturn(allocator: std.mem.Allocator, ret: *ast.Type, abi_ret_ty: []const u8) void {
        const name = normalizeAbiTypeName(abi_ret_ty);
        if (isPointerAbiType(abi_ret_ty)) {
            const ty = normalizeAbiTypeName(abi_ret_ty);
            const inner = allocator.create(ast.Type) catch {
                ret.* = .{ .primitive = .void_type };
                return;
            };
            if (std.mem.eql(u8, ty, "u8")) {
                inner.* = .{ .primitive = .u8 };
            } else if (std.mem.eql(u8, ty, "i32")) {
                inner.* = .{ .primitive = .i32 };
            } else if (std.mem.eql(u8, ty, "u32")) {
                inner.* = .{ .primitive = .u32 };
            } else if (std.mem.eql(u8, ty, "i64")) {
                inner.* = .{ .primitive = .i64 };
            } else if (std.mem.eql(u8, ty, "u64")) {
                inner.* = .{ .primitive = .u64 };
            } else if (std.mem.eql(u8, ty, "void") or std.mem.eql(u8, ty, "ptr")) {
                inner.* = .{ .primitive = .void_type };
            } else {
                inner.* = .{ .primitive = .void_type };
            }
            ret.* = .{ .pointer = inner };
        } else if (isIntegerAbiType(name)) {
            if (std.mem.eql(u8, name, "i8")) ret.* = .{ .primitive = .i8 } else if (std.mem.eql(u8, name, "i16")) ret.* = .{ .primitive = .i16 } else if (std.mem.eql(u8, name, "i32")) ret.* = .{ .primitive = .i32 } else if (std.mem.eql(u8, name, "i64")) ret.* = .{ .primitive = .i64 } else if (std.mem.eql(u8, name, "isize")) ret.* = .{ .primitive = .isize } else if (std.mem.eql(u8, name, "u8")) ret.* = .{ .primitive = .u8 } else if (std.mem.eql(u8, name, "u16")) ret.* = .{ .primitive = .u16 } else if (std.mem.eql(u8, name, "u32")) ret.* = .{ .primitive = .u32 } else if (std.mem.eql(u8, name, "u64")) ret.* = .{ .primitive = .u64 } else if (std.mem.eql(u8, name, "usize")) ret.* = .{ .primitive = .usize } else ret.* = .{ .primitive = .integer };
        } else if (std.mem.eql(u8, name, "f32")) {
            ret.* = .{ .primitive = .f32 };
        } else if (std.mem.eql(u8, name, "f64")) {
            ret.* = .{ .primitive = .f64 };
        } else if (std.mem.eql(u8, name, "bool")) {
            ret.* = .{ .primitive = .boolean };
        } else if (std.mem.eql(u8, name, "ptr")) {
            ret.* = .{ .primitive = .raw_ptr };
        } else {
            ret.* = .{ .primitive = .void_type };
        }
    }

    pub fn loadContracts(self: *TypeChecker, sai_content: []const u8, sal_content: []const u8) !void {
        var parser = contract_parser.ContractParser.init(self.allocator);

        const funcs = try parser.parseSai(sai_content);
        for (funcs) |f| {
            try self.extern_funcs.put(f.name, f);
        }

        const layouts = try parser.parseSal(sal_content);
        for (layouts) |l| {
            try self.layout_defines.put(l.name, l);
        }
    }

    pub fn registerImportedMacro(self: *TypeChecker, name: []const u8, arity: usize, leading_outputs: usize, import_path: ?[]const u8, borrowed_arg_mask: u64, address_slot_arg_mask: u64, callee_borrow_prefix_mask: u64, callee_consume_ptr_mask: u64, direct_callees: []const []const u8) !void {
        try self.imported_macros.put(name, .{
            .arity = arity,
            .leading_outputs = leading_outputs,
            .import_path = import_path,
            .borrowed_arg_mask = borrowed_arg_mask,
            .address_slot_arg_mask = address_slot_arg_mask,
            .callee_borrow_prefix_mask = callee_borrow_prefix_mask,
            .callee_consume_ptr_mask = callee_consume_ptr_mask,
            .direct_callees = direct_callees,
        });
    }

    pub fn checkProgram(self: *TypeChecker, program: *ast.Node) !void {
        if (program.* != .program) return TypeError.CompileError;

        const global_scope = try Scope.init(self.allocator, null);
        try self.scope_pool.append(global_scope);
        self.global_scope = global_scope;

        for (self.injected_scope_bindings) |binding| {
            try self.defineSymbol(global_scope, binding.name, binding.ty, binding.is_const);
        }

        for (program.program.decls) |decl| {
            if (decl.* == .using_decl) {
                const normalized = try self.normalizeUsingPath(decl.using_decl.path);
                try global_scope.using_modules.append(normalized);
            }
        }

        // Register structs first
        for (program.program.decls) |decl| {
            if (decl.* == .struct_decl) {
                try self.ensureTopLevelNameUnused(decl.struct_decl.name, "struct");
                try self.structs.put(decl.struct_decl.name, &decl.struct_decl);
            } else if (decl.* == .type_alias_decl) {
                try self.ensureTopLevelNameUnused(decl.type_alias_decl.name, "type alias");
                try self.type_aliases.put(decl.type_alias_decl.name, &decl.type_alias_decl);
            } else if (decl.* == .enum_decl) {
                try self.ensureTopLevelNameUnused(decl.enum_decl.name, "enum");
                try self.enums.put(decl.enum_decl.name, &decl.enum_decl);
            } else if (decl.* == .trait_decl) {
                try self.ensureTopLevelNameUnused(decl.trait_decl.name, "trait");
                try self.traits.put(decl.trait_decl.name, &decl.trait_decl);
            }
        }

        for (program.program.decls) |decl| {
            if (decl.* == .trait_decl) {
                for (decl.trait_decl.supertraits) |supertrait| {
                    if (!self.traits.contains(supertrait)) return TypeError.UndefinedVariable;
                }
            }
        }

        // Register functions first
        for (program.program.decls) |decl| {
            if (decl.* == .func_decl) {
                const fd = &decl.func_decl;
                if (self.funcs.get(fd.name)) |existing| {
                    // C-style forward declaration: an `extern "C" { fn f(...); }` prototype
                    // may be completed by a matching definition in the same program (and the
                    // prototype may equally follow the definition). Keep the definition.
                    if (externPrototypePairsWith(existing, fd)) {
                        if (existing.is_decl_only and !fd.is_decl_only) try self.funcs.put(fd.name, fd);
                        continue;
                    }
                }
                try self.ensureTopLevelNameUnused(fd.name, "function");
                try self.funcs.put(fd.name, fd);
            } else if (decl.* == .overload_decl) {
                const type_name = try self.typeName(decl.overload_decl.target_ty);
                for (decl.overload_decl.methods) |method| {
                    if (method.* != .func_decl) {
                        self.setError("overload `{s}` contains a non-function member", .{type_name});
                        return TypeError.CompileError;
                    }
                    const op_name = switch (method.func_decl.operator orelse {
                        self.setError("overload `{s}` methods must use an operator function", .{type_name});
                        return TypeError.CompileError;
                    }) {
                        .add => "op_add",
                        .sub => "op_sub",
                        .mul => "op_mul",
                        .div => "op_div",
                        else => {
                            self.setError("unsupported overload operator `{s}` in overload `{s}`", .{ method.func_decl.name, type_name });
                            return TypeError.CompileError;
                        },
                    };
                    const key = try std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ type_name, op_name });
                    var list = self.overloads.get(key) orelse std.ArrayList([]const u8).init(self.allocator);
                    const symbol = try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ type_name, op_name });
                    try list.append(symbol);
                    try self.overloads.put(key, list);
                    try self.funcs.put(symbol, &method.func_decl);
                }
            }
        }

        // Register impl methods
        for (program.program.decls) |decl| {
            if (decl.* == .impl_decl) {
                const target_name = try self.typeName(decl.impl_decl.target_ty);
                if (decl.impl_decl.trait_name) |trait_name| {
                    const impl_key = try std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ trait_name, target_name });
                    if (self.trait_impls.contains(impl_key)) {
                        self.setError("Redeclaration: impl `{s}` for `{s}` is already defined", .{ trait_name, target_name });
                        return TypeError.Redeclaration;
                    }
                    try self.trait_impls.put(impl_key, {});
                }
                for (decl.impl_decl.methods) |method| {
                    if (method.* != .func_decl) return TypeError.CompileError;
                    const method_key = if (decl.impl_decl.trait_name) |trait_name|
                        try self.traitMethodSymbolAlloc(trait_name, target_name, method.func_decl.name)
                    else
                        try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ target_name, method.func_decl.name });
                    if (self.funcs.contains(method_key)) {
                        self.setError("Redeclaration: method `{s}` for `{s}` is already defined", .{ method.func_decl.name, target_name });
                        return TypeError.Redeclaration;
                    }
                    try self.funcs.put(method_key, &method.func_decl);
                }
            }
        }

        // Type check overload bodies as regular functions so their internals are validated.
        for (program.program.decls) |decl| {
            if (decl.* == .overload_decl) {
                for (decl.overload_decl.methods) |method| {
                    if (method.* != .func_decl) return TypeError.CompileError;
                    try self.checkFunc(&method.func_decl);
                }
            }
        }

        // Register macros
        for (program.program.decls) |decl| {
            if (decl.* == .macro_decl) {
                try self.ensureTopLevelNameUnused(decl.macro_decl.name, "macro");
                try self.macros.put(decl.macro_decl.name, &decl.macro_decl);
            }
        }

        // Type check macro bodies so codegen can rely on expr_types for
        // lowered macro expressions, especially binary ops inside assignments.
        for (program.program.decls) |decl| {
            if (decl.* == .macro_decl) {
                try self.checkMacro(&decl.macro_decl);
            }
        }

        // Register top-level consts into the global scope so functions/tests can use them.
        for (program.program.decls) |decl| {
            if (decl.* == .const_stmt) {
                const c = &decl.const_stmt;
                try self.ensureTopLevelNameUnused(c.name, "const");
                const val_ty = try self.checkExpr(c.value, global_scope);
                const declared_ty = c.ty orelse val_ty;
                if (c.ty != null and val_ty.* == .array and declared_ty.* == .array) {
                    self.expr_types.put(c.value, declared_ty) catch return TypeError.OutOfMemory;
                }
                if (!self.valueAssignableTo(declared_ty, val_ty)) {
                    self.setError("TypeMismatch in const {s}: declared tag={s}, val tag={s}", .{ c.name, @tagName(declared_ty.*), @tagName(val_ty.*) });
                    return TypeError.TypeMismatch;
                }
                try self.defineSymbol(global_scope, c.name, declared_ty, true);
            }
        }

        // Type check functions
        for (program.program.decls) |decl| {
            if (decl.* == .func_decl) {
                try self.checkFunc(&decl.func_decl);
            } else if (decl.* == .impl_decl) {
                try self.checkImpl(&decl.impl_decl);
            }
        }

        // Type check tests
        for (program.program.decls) |decl| {
            if (decl.* == .test_decl) {
                try self.checkTest(&decl.test_decl);
            }
        }
    }

    fn operatorName(op: ast.BinaryOp) ?[]const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            else => null,
        };
    }

    fn checkMacro(self: *TypeChecker, macro_decl: *ast.MacroDecl) !void {
        const scope = try Scope.init(self.allocator, self.global_scope);
        try self.scope_pool.append(scope);

        const void_ty = try self.allocator.create(ast.Type);
        void_ty.* = .{ .primitive = .void_type };
        try self.defineSymbol(scope, "return_ty_sentinel", void_ty, true);

        const infer_ty = try self.makeInferType();
        for (macro_decl.params) |param| {
            try self.defineSymbol(scope, param, infer_ty, false);
        }

        try self.checkBlock(macro_decl.body, scope, void_ty, null, null);
    }

    fn macroParamConsumption(self: *TypeChecker, macro_decl: *const ast.MacroDecl, param_index: usize) TypeError!control_flow_rules.MacroParamConsumption {
        var visiting = std.AutoHashMap(MacroConsumptionKey, void).init(self.allocator);
        defer visiting.deinit();
        return try self.macroParamConsumptionRecursive(macro_decl, param_index, &visiting);
    }

    fn macroParamIsTrySource(self: *TypeChecker, macro_decl: *const ast.MacroDecl, param_index: usize) TypeError!bool {
        var visiting = std.AutoHashMap(MacroConsumptionKey, void).init(self.allocator);
        defer visiting.deinit();
        return try self.macroParamIsTrySourceRecursive(macro_decl, param_index, &visiting);
    }

    fn macroHasTry(self: *TypeChecker, macro_decl: *const ast.MacroDecl) TypeError!bool {
        var visiting = std.AutoHashMap(*const ast.MacroDecl, void).init(self.allocator);
        defer visiting.deinit();
        return try self.macroHasTryRecursive(macro_decl, &visiting);
    }

    fn macroHasTryRecursive(
        self: *TypeChecker,
        macro_decl: *const ast.MacroDecl,
        visiting: *std.AutoHashMap(*const ast.MacroDecl, void),
    ) TypeError!bool {
        if (visiting.contains(macro_decl)) return false;
        try visiting.put(macro_decl, {});
        defer _ = visiting.remove(macro_decl);
        if (control_flow_rules.macroBodyHasTry(macro_decl.body)) return true;
        for (macro_decl.body) |node| {
            if (try self.macroNodeCallsTryMacro(node, visiting)) return true;
        }
        return false;
    }

    fn macroNodeCallsTryMacro(
        self: *TypeChecker,
        node: *const ast.Node,
        visiting: *std.AutoHashMap(*const ast.MacroDecl, void),
    ) TypeError!bool {
        return switch (node.*) {
            .call_expr => |call| if (self.macros.get(call.func_name)) |nested| self.macroHasTryRecursive(nested, visiting) else false,
            .expr_stmt => |expr| self.macroNodeCallsTryMacro(expr, visiting),
            .assign_stmt => |assign| self.macroNodeCallsTryMacro(assign.value, visiting),
            .let_stmt => |let| self.macroNodeCallsTryMacro(let.value, visiting),
            .return_stmt => |ret| if (ret.value) |value| self.macroNodeCallsTryMacro(value, visiting) else false,
            .block_stmt => |block| blk: {
                for (block.body) |child| if (try self.macroNodeCallsTryMacro(child, visiting)) break :blk true;
                break :blk false;
            },
            .unsafe_expr => |unsafe_expr| blk: {
                for (unsafe_expr.body) |child| if (try self.macroNodeCallsTryMacro(child, visiting)) break :blk true;
                break :blk false;
            },
            .if_expr => |ife| blk: {
                for (ife.then_block) |child| if (try self.macroNodeCallsTryMacro(child, visiting)) break :blk true;
                if (ife.else_block) |else_block| for (else_block) |child| if (try self.macroNodeCallsTryMacro(child, visiting)) break :blk true;
                break :blk false;
            },
            .for_stmt => |for_stmt| blk: {
                for (for_stmt.body) |child| if (try self.macroNodeCallsTryMacro(child, visiting)) break :blk true;
                break :blk false;
            },
            .while_stmt => |while_stmt| blk: {
                for (while_stmt.body) |child| if (try self.macroNodeCallsTryMacro(child, visiting)) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    fn macroParamIsTrySourceRecursive(
        self: *TypeChecker,
        macro_decl: *const ast.MacroDecl,
        param_index: usize,
        visiting: *std.AutoHashMap(MacroConsumptionKey, void),
    ) TypeError!bool {
        if (param_index >= macro_decl.params.len) return false;
        const key = MacroConsumptionKey{ .macro_decl = macro_decl, .param_index = param_index };
        if (visiting.contains(key)) return false;
        try visiting.put(key, {});
        defer _ = visiting.remove(key);
        const name = macro_decl.params[param_index];
        if (control_flow_rules.macroParamIsTrySource(macro_decl.body, name)) return true;
        for (macro_decl.body) |node| {
            if (try self.macroNodeForwardsTrySource(node, name, visiting)) return true;
        }
        return false;
    }

    fn macroNodeForwardsTrySource(
        self: *TypeChecker,
        node: *const ast.Node,
        name: []const u8,
        visiting: *std.AutoHashMap(MacroConsumptionKey, void),
    ) TypeError!bool {
        return switch (node.*) {
            .call_expr => |call| blk: {
                if (self.macros.get(call.func_name)) |nested| {
                    for (call.args, 0..) |arg, index| {
                        const root = rootIdentifier(arg) orelse continue;
                        if (!std.mem.eql(u8, root, name)) continue;
                        if (try self.macroParamIsTrySourceRecursive(nested, index, visiting)) break :blk true;
                    }
                }
                break :blk false;
            },
            .expr_stmt => |expr| self.macroNodeForwardsTrySource(expr, name, visiting),
            .assign_stmt => |assign| self.macroNodeForwardsTrySource(assign.value, name, visiting),
            .let_stmt => |let| self.macroNodeForwardsTrySource(let.value, name, visiting),
            .return_stmt => |ret| if (ret.value) |value| self.macroNodeForwardsTrySource(value, name, visiting) else false,
            .block_stmt => |block| blk: {
                for (block.body) |child| if (try self.macroNodeForwardsTrySource(child, name, visiting)) break :blk true;
                break :blk false;
            },
            .unsafe_expr => |unsafe_expr| blk: {
                for (unsafe_expr.body) |child| if (try self.macroNodeForwardsTrySource(child, name, visiting)) break :blk true;
                break :blk false;
            },
            .if_expr => |ife| blk: {
                for (ife.then_block) |child| if (try self.macroNodeForwardsTrySource(child, name, visiting)) break :blk true;
                if (ife.else_block) |else_block| for (else_block) |child| if (try self.macroNodeForwardsTrySource(child, name, visiting)) break :blk true;
                break :blk false;
            },
            .for_stmt => |for_stmt| blk: {
                for (for_stmt.body) |child| if (try self.macroNodeForwardsTrySource(child, name, visiting)) break :blk true;
                break :blk false;
            },
            .while_stmt => |while_stmt| blk: {
                for (while_stmt.body) |child| if (try self.macroNodeForwardsTrySource(child, name, visiting)) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    fn macroParamConsumptionRecursive(
        self: *TypeChecker,
        macro_decl: *const ast.MacroDecl,
        param_index: usize,
        visiting: *std.AutoHashMap(MacroConsumptionKey, void),
    ) TypeError!control_flow_rules.MacroParamConsumption {
        if (param_index >= macro_decl.params.len) return .never;
        const key = MacroConsumptionKey{ .macro_decl = macro_decl, .param_index = param_index };
        if (visiting.contains(key)) return .never;
        try visiting.put(key, {});
        defer _ = visiting.remove(key);

        const name = macro_decl.params[param_index];
        const direct = control_flow_rules.macroParamConsumption(macro_decl.body, name);
        if (direct != .never) return direct;
        var effect: control_flow_rules.MacroParamConsumption = .never;
        for (macro_decl.body) |node| {
            effect = control_flow_rules.sequenceMacroParamConsumption(effect, try self.macroNodeForwardedConsumption(node, name, visiting));
        }
        return effect;
    }

    fn macroNodeForwardedConsumption(
        self: *TypeChecker,
        node: *const ast.Node,
        name: []const u8,
        visiting: *std.AutoHashMap(MacroConsumptionKey, void),
    ) TypeError!control_flow_rules.MacroParamConsumption {
        return switch (node.*) {
            .call_expr => |call| blk: {
                var effect: control_flow_rules.MacroParamConsumption = .never;
                if (self.macros.get(call.func_name)) |nested| {
                    for (nested.params, call.args, 0..) |_, arg, index| {
                        const root = rootIdentifier(arg) orelse continue;
                        if (!std.mem.eql(u8, root, name)) continue;
                        effect = control_flow_rules.sequenceMacroParamConsumption(effect, try self.macroParamConsumptionRecursive(nested, index, visiting));
                    }
                }
                for (call.args) |arg| effect = control_flow_rules.sequenceMacroParamConsumption(effect, try self.macroNodeForwardedConsumption(arg, name, visiting));
                break :blk effect;
            },
            .expr_stmt => |expr| self.macroNodeForwardedConsumption(expr, name, visiting),
            .assign_stmt => |assign| self.macroNodeForwardedConsumption(assign.value, name, visiting),
            .let_stmt => |let| self.macroNodeForwardedConsumption(let.value, name, visiting),
            .return_stmt => |ret| if (ret.value) |value| self.macroNodeForwardedConsumption(value, name, visiting) else .never,
            .block_stmt => |block| blk: {
                var effect: control_flow_rules.MacroParamConsumption = .never;
                for (block.body) |child| effect = control_flow_rules.sequenceMacroParamConsumption(effect, try self.macroNodeForwardedConsumption(child, name, visiting));
                break :blk effect;
            },
            .if_expr => |ife| blk: {
                const cond = try self.macroNodeForwardedConsumption(ife.cond, name, visiting);
                var then_effect: control_flow_rules.MacroParamConsumption = .never;
                for (ife.then_block) |child| then_effect = control_flow_rules.sequenceMacroParamConsumption(then_effect, try self.macroNodeForwardedConsumption(child, name, visiting));
                var else_effect: control_flow_rules.MacroParamConsumption = .never;
                if (ife.else_block) |else_block| {
                    for (else_block) |child| else_effect = control_flow_rules.sequenceMacroParamConsumption(else_effect, try self.macroNodeForwardedConsumption(child, name, visiting));
                }
                break :blk control_flow_rules.sequenceMacroParamConsumption(cond, control_flow_rules.branchMacroParamConsumption(then_effect, else_effect));
            },
            .binary_expr => |binary| control_flow_rules.sequenceMacroParamConsumption(try self.macroNodeForwardedConsumption(binary.left, name, visiting), try self.macroNodeForwardedConsumption(binary.right, name, visiting)),
            .field_expr => |field| self.macroNodeForwardedConsumption(field.expr, name, visiting),
            .index_expr => |index| control_flow_rules.sequenceMacroParamConsumption(try self.macroNodeForwardedConsumption(index.target, name, visiting), try self.macroNodeForwardedConsumption(index.index, name, visiting)),
            .cast_expr => |cast| self.macroNodeForwardedConsumption(cast.expr, name, visiting),
            .borrow_expr => |borrow| self.macroNodeForwardedConsumption(borrow.expr, name, visiting),
            .move_expr => |move| self.macroNodeForwardedConsumption(move.expr, name, visiting),
            .deref_expr => |deref| self.macroNodeForwardedConsumption(deref.expr, name, visiting),
            .try_expr => |try_expr| self.macroNodeForwardedConsumption(try_expr.expr, name, visiting),
            .await_expr => |await_expr| self.macroNodeForwardedConsumption(await_expr.expr, name, visiting),
            .for_stmt => |for_stmt| blk: {
                var effect = try self.macroNodeForwardedConsumption(for_stmt.start, name, visiting);
                if (for_stmt.end) |end| effect = control_flow_rules.sequenceMacroParamConsumption(effect, try self.macroNodeForwardedConsumption(end, name, visiting));
                var body_effect: control_flow_rules.MacroParamConsumption = .never;
                for (for_stmt.body) |child| body_effect = control_flow_rules.sequenceMacroParamConsumption(body_effect, try self.macroNodeForwardedConsumption(child, name, visiting));
                if (body_effect != .never) body_effect = .conditional;
                break :blk control_flow_rules.sequenceMacroParamConsumption(effect, body_effect);
            },
            .while_stmt => |while_stmt| blk: {
                const cond = try self.macroNodeForwardedConsumption(while_stmt.cond, name, visiting);
                var body_effect: control_flow_rules.MacroParamConsumption = .never;
                for (while_stmt.body) |child| body_effect = control_flow_rules.sequenceMacroParamConsumption(body_effect, try self.macroNodeForwardedConsumption(child, name, visiting));
                if (body_effect != .never) body_effect = .conditional;
                break :blk control_flow_rules.sequenceMacroParamConsumption(cond, body_effect);
            },
            else => .never,
        };
    }

    fn checkTest(self: *TypeChecker, test_decl: *ast.TestDecl) !void {
        var scope = try Scope.init(self.allocator, self.global_scope);
        try self.scope_pool.append(scope);

        const ret_ty = try self.allocator.create(ast.Type);
        ret_ty.* = .{ .primitive = .void_type };

        try self.defineSymbol(scope, "return_ty_sentinel", ret_ty, true);

        try self.checkBlock(test_decl.body, scope, ret_ty, null, null);

        var iter = scope.symbols.valueIterator();
        while (iter.next()) |sym| {
            if (sym.state == .active and !isInternalSymbol(sym.name)) {
                sym.state = .consumed;
            }
        }
    }

    fn checkFunc(self: *TypeChecker, func: *ast.FuncDecl) !void {
        if (func.is_decl_only) return;

        const previous_name = self.current_function_name;
        self.current_function_name = func.name;
        defer self.current_function_name = previous_name;

        const previous_namespace = self.current_function_namespace;
        self.current_function_namespace = if (self.resolveFunctionAliasMetadata(func.name)) |metadata| metadata.namespace else null;
        defer self.current_function_namespace = previous_namespace;

        var scope = try Scope.init(self.allocator, self.global_scope);
        try self.scope_pool.append(scope);

        try self.defineSymbol(scope, "return_ty_sentinel", func.ret_ty, true);

        for (func.params) |p| {
            const local_ty = if (p.is_borrow) try self.makeBorrowType(p.ty) else p.ty;
            try self.defineSymbol(scope, p.name, local_ty, false);
        }

        try self.checkBlock(func.body, scope, func.ret_ty, null, null);

        if (!isPrimitiveType(func.ret_ty, .void_type) and func.body.len > 0) {
            const last = func.body[func.body.len - 1];
            if (last.* == .expr_stmt and !stmtTerminates(last)) {
                const tail_ty = self.expr_types.get(last.expr_stmt) orelse return TypeError.CompileError;
                if (!self.valueAssignableTo(func.ret_ty, tail_ty)) {
                    self.setError("TypeMismatch in function tail expression: expected {s}, actual {s}", .{ typeDesc(func.ret_ty), typeDesc(tail_ty) });
                    return TypeError.TypeMismatch;
                }
            }
        }

        // Verify that all parameters or locals in the function root scope are consumed (or we auto-release them)
        // For parameters/locals remaining active at function exit, compile-time checklist forces release.
        var iter = scope.symbols.valueIterator();
        while (iter.next()) |sym| {
            if (sym.state == .active and isPrimitiveType(func.ret_ty, .void_type) and !isInternalSymbol(sym.name)) {
                // If it returns void, we can auto-release. If it's a value return, return statement handles cleanups.
                sym.state = .consumed;
            }
        }
    }

    fn checkBlock(
        self: *TypeChecker,
        body: []const *ast.Node,
        parent_scope: *Scope,
        ret_ty: *ast.Type,
        loop_node: ?*ast.Node,
        current_loop_scope: ?*Scope,
    ) !void {
        _ = loop_node;
        var scope = try Scope.init(self.allocator, parent_scope);
        try self.scope_pool.append(scope);

        for (body) |stmt| {
            try self.checkStmt(stmt, scope, ret_ty, current_loop_scope);
        }

        // Auto-cleanup for variables local to this block that are still active.
        // Raw pointers are non-owning, but they still need lexical liveness end
        // markers so generated SA does not leave pointer locals Active at exit.
        var cleanup_list = std.ArrayList([]const u8).init(self.allocator);
        var iter = scope.symbols.valueIterator();
        while (iter.next()) |sym| {
            if (sym.state == .active and !isInternalSymbol(sym.name)) {
                // Block-local borrows still need lexical end cleanups so codegen can
                // release tracked borrow handles such as RefCell shared/mut borrows.
                if (sym.ty.* == .primitive and sym.ty.primitive == .raw_ptr) continue;
                // issue013: if another active local has borrow_source == sym.name,
                // the borrow handle was moved into that local; skip the source here
                // so we do not emit a double `!name` release.
                if (isBorrowLikeType(sym.ty) and self.borrowSourceAliasedByOtherActive(scope, sym.name)) continue;
                try cleanup_list.append(sym.name);
                sym.state = .consumed;
            }
        }

        if (cleanup_list.items.len > 0) {
            // Associated cleanup list with the block's last statement, or block node itself
            if (body.len > 0) {
                const last_stmt = body[body.len - 1];
                if (last_stmt.* != .return_stmt and last_stmt.* != .break_stmt and last_stmt.* != .continue_stmt) {
                    try self.cleanups.put(last_stmt, cleanup_list);
                } else {
                    cleanup_list.deinit();
                }
            } else {
                cleanup_list.deinit();
            }
        } else {
            cleanup_list.deinit();
        }
    }

    fn blockTerminates(body: []const *ast.Node) bool {
        if (body.len == 0) return false;
        return stmtTerminates(body[body.len - 1]);
    }

    fn stmtTerminates(stmt: *const ast.Node) bool {
        return switch (stmt.*) {
            .return_stmt, .break_stmt, .continue_stmt => true,
            .expr_stmt => |expr| exprTerminates(expr),
            else => false,
        };
    }

    fn exprTerminates(expr: *const ast.Node) bool {
        return switch (expr.*) {
            .call_expr => |call| lowering_rules.isPanicBuiltinName(call.func_name),
            .unsafe_expr => |ue| blockTerminates(ue.body),
            .if_expr => |ife| blockTerminates(ife.then_block) and if (ife.else_block) |eb| blockTerminates(eb) else false,
            .match_expr => |mat| blk: {
                if (mat.cases.len == 0) break :blk false;
                for (mat.cases) |case| {
                    if (!blockTerminates(case.body)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    fn saveScopeStates(self: *TypeChecker, scope: *Scope) TypeError!std.StringHashMap(ValueState) {
        var states = std.StringHashMap(ValueState).init(self.allocator);
        var curr: ?*Scope = scope;
        while (curr) |s| {
            var iter = s.symbols.iterator();
            while (iter.next()) |entry| {
                try states.put(entry.key_ptr.*, entry.value_ptr.state);
            }
            curr = s.parent;
        }
        return states;
    }

    fn restoreScopeStates(_: *TypeChecker, scope: *Scope, saved: *const std.StringHashMap(ValueState)) void {
        var curr: ?*Scope = scope;
        while (curr) |s| {
            var iter = s.symbols.iterator();
            while (iter.next()) |entry| {
                if (saved.get(entry.key_ptr.*)) |state| entry.value_ptr.state = state;
            }
            curr = s.parent;
        }
    }

    fn mergeMultiBranchScopeStates(
        self: *TypeChecker,
        scope: *Scope,
        saved_states: *const std.StringHashMap(ValueState),
        live_states: []const std.StringHashMap(ValueState),
        live_bodies: []const []const *ast.Node,
    ) TypeError!void {
        switch (control_flow_rules.planMultiBranchStateMerge(live_states.len)) {
            .restore_pre => self.restoreScopeStates(scope, saved_states),
            .restore_single => self.restoreScopeStates(scope, &live_states[0]),
            .intersect_live => {
                var branch_values = try self.allocator.alloc(ValueState, live_states.len);
                defer self.allocator.free(branch_values);

                var curr: ?*Scope = scope;
                while (curr) |s| {
                    var iter = s.symbols.iterator();
                    while (iter.next()) |entry| {
                        const name = entry.key_ptr.*;
                        if (isInternalSymbol(name)) continue;
                        for (live_states, 0..) |states, idx| {
                            branch_values[idx] = states.get(name) orelse .active;
                        }
                        const merged = control_flow_rules.intersectLiveBranchValueStates(branch_values);
                        entry.value_ptr.state = merged;
                        if (merged != .consumed) continue;

                        for (branch_values, live_bodies) |state, body| {
                            if (state != .active or body.len == 0) continue;
                            const last = body[body.len - 1];
                            var list = self.phi_cleanups.get(last) orelse std.ArrayList([]const u8).init(self.allocator);
                            try list.append(name);
                            try self.phi_cleanups.put(last, list);
                        }
                    }
                    curr = s.parent;
                }
            },
        }
    }

    fn restoreUninitializedFromSaved(self: *TypeChecker, scope: *Scope, saved: *const std.StringHashMap(ValueState)) void {
        _ = self;
        var curr: ?*Scope = scope;
        while (curr) |s| {
            var iter = s.symbols.iterator();
            while (iter.next()) |entry| {
                if (saved.get(entry.key_ptr.*)) |state| {
                    if (state == .uninitialized) entry.value_ptr.state = .uninitialized;
                }
            }
            curr = s.parent;
        }
    }

    fn checkStmt(
        self: *TypeChecker,
        stmt: *ast.Node,
        scope: *Scope,
        ret_ty: *ast.Type,
        current_loop_scope: ?*Scope,
    ) TypeError!void {
        self.checkStmtImpl(stmt, scope, ret_ty, current_loop_scope) catch |err| {
            if (self.last_error.len == 0) {
                self.setError("checkStmt failed at node tag {s}", .{@tagName(stmt.*)});
            }
            return err;
        };
    }

    fn checkStmtImpl(
        self: *TypeChecker,
        stmt: *ast.Node,
        scope: *Scope,
        ret_ty: *ast.Type,
        current_loop_scope: ?*Scope,
    ) TypeError!void {
        switch (stmt.*) {
            .using_decl => |u| {
                const normalized = try self.normalizeUsingPath(u.path);
                try scope.using_modules.append(normalized);
            },
            .let_stmt => |let| {
                const val_ty = try self.checkExpr(let.value, scope);
                const declared_ty = let.ty orelse val_ty;
                if (let.ty != null and val_ty.* == .array and declared_ty.* == .array) {
                    self.expr_types.put(let.value, declared_ty) catch return TypeError.OutOfMemory;
                }
                if (!self.valueAssignableTo(declared_ty, val_ty)) {
                    if (declared_ty.* == .user_defined and std.mem.eql(u8, declared_ty.user_defined.name, "Slice") and declared_ty.user_defined.generics.len == 1 and val_ty.* == .borrow) {
                        if (arrayType(val_ty.borrow)) |arr| {
                            if (self.typesEqual(declared_ty.user_defined.generics[0], arr.elem)) {
                                try self.defineSymbol(scope, let.name, declared_ty, false);
                                return;
                            }
                        }
                    }
                    if (self.canCoerceToDynBox(declared_ty, val_ty)) |trait_name| {
                        self.dyn_box_coercions.put(let.value, trait_name) catch return TypeError.OutOfMemory;
                    } else if (self.canCoerceRcNewToDynRc(declared_ty, val_ty, let.value)) |trait_name| {
                        self.dyn_rc_coercions.put(let.value, trait_name) catch return TypeError.OutOfMemory;
                    } else {
                        self.setError("TypeMismatch in let {s}: declared tag={s}, val tag={s}", .{ let.name, @tagName(declared_ty.*), @tagName(val_ty.*) });
                        return TypeError.TypeMismatch;
                    }
                }
                if (let.value.* == .identifier) {
                    if (scope.lookup(let.value.identifier)) |source| {
                        if (!self.typeIsCopy(source.ty) and !isBorrowLikeType(source.ty)) try self.consumeBinding(scope, let.value.identifier, source, "implicit let move");
                    }
                }
                if (!isDiscardName(let.name)) {
                    try self.defineSymbol(scope, let.name, declared_ty, false);
                    if (isBorrowLikeType(declared_ty)) {
                        if (directBorrowSource(let.value)) |source| {
                            scope.lookupLocal(let.name).?.borrow_source = source;
                        }
                    }
                }
            },
            .let_else_stmt => |let| {
                const value_ty = try self.checkExpr(let.value, scope);
                try self.checkBlock(let.else_block, scope, ret_ty, null, current_loop_scope);
                if (!blockTerminates(let.else_block)) {
                    self.setError("let else block must diverge", .{});
                    return TypeError.TypeMismatch;
                }
                try self.definePatternBindings(scope, let.pattern, value_ty, "let else", false);
            },
            .let_destructure_stmt => |let| {
                const val_ty = try self.checkExpr(let.value, scope);
                if (let.is_slice) {
                    const elem_ty = if (arrayType(val_ty)) |arr| arr.elem else if (sliceElementType(val_ty)) |elem| elem else {
                        self.setError("slice destructuring requires array or slice value, actual tag={s}", .{@tagName(val_ty.*)});
                        return TypeError.TypeMismatch;
                    };
                    if (let.rest_name == null) {
                        self.setError("slice destructuring requires a rest binding", .{});
                        return TypeError.InvalidArgsCount;
                    }
                    if (let.names.len > 0 and val_ty.* == .array and val_ty.array.len < let.names.len) {
                        self.setError("slice destructuring arity mismatch: pattern={}, array={}", .{ let.names.len, val_ty.array.len });
                        return TypeError.InvalidArgsCount;
                    }
                    for (let.names) |name| {
                        if (!isDiscardName(name)) {
                            try self.defineSymbol(scope, name, elem_ty, false);
                        }
                    }
                    if (let.rest_name) |rest_name| {
                        if (!isDiscardName(rest_name)) {
                            try self.defineSymbol(scope, rest_name, try self.makeSliceType(elem_ty), false);
                        }
                    }
                    if (let.rest_alias) |rest_alias| {
                        if (!isDiscardName(rest_alias)) {
                            try self.defineSymbol(scope, rest_alias, try self.makeSliceType(elem_ty), false);
                        }
                    }
                } else {
                    if (val_ty.* != .tuple) {
                        self.setError("let destructuring requires tuple value, actual tag={s}", .{@tagName(val_ty.*)});
                        return TypeError.TypeMismatch;
                    }
                    if (let.names.len != val_ty.tuple.elems.len) {
                        self.setError("let destructuring arity mismatch: pattern={}, tuple={}", .{ let.names.len, val_ty.tuple.elems.len });
                        return TypeError.InvalidArgsCount;
                    }
                    for (let.names, val_ty.tuple.elems) |name, elem_ty| {
                        if (!isDiscardName(name)) {
                            try self.defineSymbol(scope, name, elem_ty, false);
                        }
                    }
                }
                if (rootIdentifier(let.value)) |name| {
                    const sym = scope.lookup(name) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    try self.consumeBinding(scope, name, sym, "destructuring move");
                }
            },
            .const_stmt => |c| {
                const val_ty = try self.checkExpr(c.value, scope);
                const declared_ty = c.ty orelse val_ty;
                if (c.ty != null and val_ty.* == .array and declared_ty.* == .array) {
                    self.expr_types.put(c.value, declared_ty) catch return TypeError.OutOfMemory;
                }
                if (!self.valueAssignableTo(declared_ty, val_ty)) {
                    if (self.canCoerceToDynBox(declared_ty, val_ty)) |trait_name| {
                        self.dyn_box_coercions.put(c.value, trait_name) catch return TypeError.OutOfMemory;
                    } else if (self.canCoerceRcNewToDynRc(declared_ty, val_ty, c.value)) |trait_name| {
                        self.dyn_rc_coercions.put(c.value, trait_name) catch return TypeError.OutOfMemory;
                    } else {
                        self.setError("TypeMismatch in const {s}: declared tag={s}, val tag={s}", .{ c.name, @tagName(declared_ty.*), @tagName(val_ty.*) });
                        return TypeError.TypeMismatch;
                    }
                }
                try self.defineSymbol(scope, c.name, declared_ty, true);
            },
            .var_stmt => |v| {
                if (v.ty.* != .primitive) {
                    self.setError("var Phase 1 supports scalar primitive slots only: `{s}`", .{v.name});
                    return TypeError.TypeMismatch;
                }
                try self.defineSymbolWithState(scope, v.name, v.ty, false, .uninitialized);
            },
            .assign_stmt => |assign| {
                if (assign.target.* == .deref_expr) {
                    const deref_target_ty = try self.checkExpr(assign.target.deref_expr.expr, scope);
                    if (rwLockReadGuardInnerType(deref_target_ty) != null) {
                        self.setError("cannot assign through RwLock read guard", .{});
                        return TypeError.TypeMismatch;
                    }
                }
                const target_ty = if (assign.target.* == .identifier) blk: {
                    const sym = scope.lookup(assign.target.identifier) orelse return TypeError.UndefinedVariable;
                    self.expr_types.put(assign.target, sym.ty) catch return TypeError.OutOfMemory;
                    break :blk sym.ty;
                } else try self.checkExpr(assign.target, scope);
                const val_ty = try self.checkExpr(assign.value, scope);
                if (!self.valueAssignableTo(target_ty, val_ty)) {
                    const target_name = if (assign.target.* == .identifier) assign.target.identifier else "<expr>";
                    if (self.current_function_name) |fn_name| {
                        self.setError("TypeMismatch in assign in {s}: target `{s}` tag={s}, val tag={s}", .{ fn_name, target_name, @tagName(target_ty.*), @tagName(val_ty.*) });
                    } else {
                        self.setError("TypeMismatch in assign: target `{s}` tag={s}, val tag={s}", .{ target_name, @tagName(target_ty.*), @tagName(val_ty.*) });
                    }
                    return TypeError.TypeMismatch;
                }
                // let bindings can be reassigned and indexed; const bindings cannot.
                if (rootIdentifier(assign.target)) |root_name| {
                    const sym = scope.lookup(root_name) orelse return TypeError.UndefinedVariable;
                    if (sym.is_const) return TypeError.CompileError;
                    if (sym.state == .uninitialized and assign.target.* != .identifier) {
                        self.setError("UseBeforeInit: var `{s}` must be assigned as a whole before field/index assignment", .{root_name});
                        return TypeError.UseBeforeInit;
                    }
                }
                if (assign.value.* == .identifier) {
                    const value_name = assign.value.identifier;
                    const target_name = rootIdentifier(assign.target);
                    if (target_name == null or !std.mem.eql(u8, target_name.?, value_name)) {
                        const sym = scope.lookup(value_name) orelse return TypeError.UndefinedVariable;
                        if (sym.state == .consumed) return TypeError.UseAfterMove;
                        if (sym.state == .uninitialized) {
                            self.setError("UseBeforeInit: var `{s}` is read before assignment", .{value_name});
                            return TypeError.UseBeforeInit;
                        }
                        if (!self.typeIsCopy(sym.ty) and !isBorrowLikeType(sym.ty)) try self.consumeBinding(scope, value_name, sym, "assignment move");
                    }
                }
                if (assign.target.* == .identifier) {
                    const sym = scope.lookup(assign.target.identifier) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .uninitialized) sym.state = .active;
                }
            },
            .return_stmt => |ret| {
                if (ret.value) |val| {
                    const val_ty = try self.checkExpr(val, scope);
                    if (!self.valueAssignableTo(ret_ty, val_ty)) {
                        self.setError("TypeMismatch in return: expected {s}, actual {s}", .{ typeDesc(ret_ty), typeDesc(val_ty) });
                        return TypeError.TypeMismatch;
                    }
                } else {
                    if (!isPrimitiveType(ret_ty, .void_type)) {
                        self.setError("TypeMismatch in return void: expected tag={s}", .{@tagName(ret_ty.*)});
                        return TypeError.TypeMismatch;
                    }
                }

                // Collect all active variables across all scope frames up to the function root
                var cleanup_list = std.ArrayList([]const u8).init(self.allocator);
                var curr: ?*Scope = scope;
                while (curr) |s| {
                    var iter = s.symbols.valueIterator();
                    while (iter.next()) |sym| {
                        if (sym.state == .active and !isInternalSymbol(sym.name)) {
                            if (ret.value) |val| {
                                if (functionExitBindingEscapes(scope, val, sym.name)) continue;
                            }
                            // issue013: skip borrow source that has been re-aliased.
                            if (isBorrowLikeType(sym.ty) and self.borrowSourceAliasedByOtherActive(scope, sym.name)) continue;
                            try cleanup_list.append(sym.name);
                        }
                    }
                    curr = s.parent;
                }
                if (cleanup_list.items.len > 0) {
                    try self.cleanups.put(stmt, cleanup_list);
                } else {
                    cleanup_list.deinit();
                }
            },
            .for_stmt => |*f| {
                const start_ty = try self.checkExpr(f.start, scope);
                const iter_ty = if (f.end) |end_expr| blk: {
                    const end_ty = try self.checkExpr(end_expr, scope);
                    if (!isNumericType(start_ty) or !isNumericType(end_ty)) {
                        self.setError("for range bounds must be numeric: start tag={s}, end tag={s}", .{ @tagName(start_ty.*), @tagName(end_ty.*) });
                        return TypeError.TypeMismatch;
                    }
                    break :blk start_ty;
                } else blk: {
                    if (arrayType(start_ty)) |arr| break :blk arr.elem;
                    break :blk self.protocolIterableElementType(start_ty) orelse {
                        self.setError("for iterable value must be array or implement Iterable: start tag={s}", .{@tagName(start_ty.*)});
                        return TypeError.TypeMismatch;
                    };
                };

                const loop_scope = try Scope.init(self.allocator, scope);
                try self.scope_pool.append(loop_scope);

                const i_ty = try self.allocator.create(ast.Type);
                i_ty.* = iter_ty.*;
                try self.defineSymbol(loop_scope, f.var_name, i_ty, true);

                var saved_states = try self.saveScopeStates(scope);
                defer saved_states.deinit();

                const prev_loop_scope = self.current_loop_scope;
                const prev_loop_body_terminates = self.current_loop_body_terminates;
                self.current_loop_scope = loop_scope;
                self.current_loop_body_terminates = blockTerminates(f.body);
                defer {
                    self.current_loop_scope = prev_loop_scope;
                    self.current_loop_body_terminates = prev_loop_body_terminates;
                }
                try self.checkBlock(f.body, loop_scope, ret_ty, stmt, loop_scope);
                self.restoreUninitializedFromSaved(scope, &saved_states);
            },
            .while_stmt => |*w| {
                const cond_ty = try self.checkExpr(w.cond, scope);
                const loop_scope = try Scope.init(self.allocator, scope);
                try self.scope_pool.append(loop_scope);
                if (w.let_pattern) |pattern| {
                    try self.definePatternBindings(loop_scope, pattern, cond_ty, "while let", true);
                } else {
                    if (cond_ty.* != .primitive) {
                        self.setError("while condition must be bool/int unless using while let", .{});
                        return TypeError.TypeMismatch;
                    }
                    switch (cond_ty.primitive) {
                        .boolean, .integer => {},
                        else => return TypeError.TypeMismatch,
                    }
                }
                var saved_states = try self.saveScopeStates(scope);
                defer saved_states.deinit();

                const prev_loop_scope = self.current_loop_scope;
                const prev_loop_body_terminates = self.current_loop_body_terminates;
                self.current_loop_scope = loop_scope;
                self.current_loop_body_terminates = blockTerminates(w.body);
                defer {
                    self.current_loop_scope = prev_loop_scope;
                    self.current_loop_body_terminates = prev_loop_body_terminates;
                }
                try self.checkBlock(w.body, loop_scope, ret_ty, stmt, loop_scope);
                self.restoreUninitializedFromSaved(scope, &saved_states);
            },
            .break_stmt, .continue_stmt => {
                const loop_scope = current_loop_scope orelse {
                    self.setError("break/continue used outside loop", .{});
                    return TypeError.CompileError;
                };

                var cleanup_list = std.ArrayList([]const u8).init(self.allocator);
                var curr: ?*Scope = scope;
                while (curr) |s| {
                    var iter = s.symbols.valueIterator();
                    while (iter.next()) |sym| {
                        if (sym.state == .active and !isInternalSymbol(sym.name)) {
                            // issue013: skip borrowed source that was aliased.
                            if (isBorrowLikeType(sym.ty) and self.borrowSourceAliasedByOtherActive(scope, sym.name)) continue;
                            try cleanup_list.append(sym.name);
                        }
                    }
                    if (s == loop_scope) break;
                    curr = s.parent;
                }
                if (cleanup_list.items.len > 0) {
                    try self.cleanups.put(stmt, cleanup_list);
                } else {
                    cleanup_list.deinit();
                }
            },
            .release_stmt => |rel| {
                const sym = scope.lookup(rel.var_name) orelse return TypeError.UndefinedVariable;
                if (sym.state == .consumed) return TypeError.UseAfterMove;
                if (sym.state == .uninitialized) {
                    self.setError("UseBeforeInit: var `{s}` cannot be released before assignment", .{rel.var_name});
                    return TypeError.UseBeforeInit;
                }
                try self.consumeBinding(scope, rel.var_name, sym, "explicit release");
            },
            .expr_stmt => |expr| {
                _ = try self.checkExpr(expr, scope);
            },
            .block_stmt => |blk| {
                const inner_scope = try Scope.init(self.allocator, scope);
                try self.scope_pool.append(inner_scope);
                try self.checkBlock(blk.body, inner_scope, ret_ty, stmt, current_loop_scope);
            },
            else => return TypeError.CompileError,
        }
    }

    fn checkExpr(self: *TypeChecker, expr: *ast.Node, scope: *Scope) TypeError!*ast.Type {
        const ty = self.checkExprImpl(expr, scope) catch |err| {
            if (self.last_error.len == 0) {
                if (expr.* == .call_expr) {
                    const call = expr.call_expr;
                    self.setError("checkExpr failed at call {s}{s}{s} with {} args", .{ if (call.associated_target) |target| target else "", if (call.associated_target != null) "::" else "", call.func_name, call.args.len });
                } else {
                    self.setError("checkExpr failed at node tag {s}", .{@tagName(expr.*)});
                }
            }
            return err;
        };
        self.expr_types.put(expr, ty) catch return TypeError.OutOfMemory;
        return ty;
    }

    fn blockTailExprType(self: *TypeChecker, block: []const *ast.Node) ?*ast.Type {
        if (block.len == 0) return null;
        const last = block[block.len - 1];
        if (last.* != .expr_stmt) return null;
        return self.expr_types.get(last.expr_stmt);
    }

    fn checkExprImpl(self: *TypeChecker, expr: *ast.Node, scope: *Scope) TypeError!*ast.Type {
        switch (expr.*) {
            .literal => |lit| {
                const ty = try self.allocator.create(ast.Type);
                switch (lit) {
                    .int_val => ty.* = .{ .primitive = .i64 },
                    .float_val => ty.* = .{ .primitive = .f64 },
                    .bool_val => ty.* = .{ .primitive = .boolean },
                    .string_val => {
                        // In Sla, string literal evaluates to ptr (pointing to char array)
                        ty.* = .{ .primitive = .raw_ptr };
                    },
                }
                return ty;
            },
            .identifier => |name| {
                if (lowering_rules.isOptionNoneName(name)) {
                    return try self.makeOptionType(try self.makeInferType());
                }
                if (isOrderingName(name)) {
                    return try self.makeOrderingType();
                }
                if (scope.lookup(name)) |sym| {
                    if (sym.state == .consumed) {
                        self.setError("UseAfterMove: identifier `{s}` was already consumed", .{name});
                        return TypeError.UseAfterMove;
                    }
                    if (sym.state == .uninitialized) {
                        self.setError("UseBeforeInit: var `{s}` is read before assignment", .{name});
                        return TypeError.UseBeforeInit;
                    }
                    return sym.ty;
                }
                if (self.funcs.get(name)) |func| {
                    var params = std.ArrayList(*ast.Type).init(self.allocator);
                    for (func.params) |param| {
                        try params.append(param.ty);
                    }
                    return try self.makeFnPtrType(func.abi, try params.toOwnedSlice(), func.ret_ty);
                }
                self.setError("UndefinedVariable: identifier `{s}` is not defined in this scope", .{name});
                return TypeError.UndefinedVariable;
            },
            .generic_func_ref => return TypeError.CompileError,
            .binary_expr => |bin| {
                const l_ty = try self.checkExpr(bin.left, scope);
                const r_ty = try self.checkExpr(bin.right, scope);
                const ty = try self.allocator.create(ast.Type);
                switch (bin.op) {
                    .add, .sub, .mul, .div, .mod => {
                        if (try self.overloadSymbol(bin.op, l_ty, r_ty)) |symbol| {
                            const call_symbol = try self.allocator.dupe(u8, symbol);
                            try self.resolved_call_symbols.put(@as(*const ast.Node, @ptrCast(&bin)), call_symbol);
                            const ret = self.funcs.get(symbol) orelse return TypeError.UndefinedVariable;
                            ty.* = ret.ret_ty.*;
                            return ty;
                        }
                        if (self.structDeclForType(l_ty)) |left_struct| {
                            if (self.structDeclForType(r_ty)) |right_struct| {
                                if (!self.typesEqual(l_ty, r_ty)) return TypeError.TypeMismatch;
                                if ((bin.op == .add or bin.op == .sub) and structFieldsAllNumeric(left_struct) and left_struct == right_struct) {
                                    ty.* = l_ty.*;
                                    return ty;
                                }
                            } else if (bin.op == .mul and isNumericType(r_ty) and structFieldsAllNumeric(left_struct)) {
                                ty.* = l_ty.*;
                                return ty;
                            }
                        } else if (self.structDeclForType(r_ty)) |right_struct| {
                            if (bin.op == .sub and literalZero(bin.left) and structFieldsAllNumeric(right_struct)) {
                                ty.* = r_ty.*;
                                return ty;
                            }
                            if (bin.op == .mul and isNumericType(l_ty) and structFieldsAllNumeric(right_struct)) {
                                ty.* = r_ty.*;
                                return ty;
                            }
                        }
                        if (bin.op == .sub and literalZero(bin.left) and isNumericType(r_ty)) {
                            ty.* = r_ty.*;
                            return ty;
                        }
                        if (!self.typesEqual(l_ty, r_ty)) {
                            self.setError("binary expression type mismatch: op={s}, left tag={s}, right tag={s}", .{ @tagName(bin.op), @tagName(l_ty.*), @tagName(r_ty.*) });
                            return TypeError.TypeMismatch;
                        }
                        if (l_ty.* == .infer) {
                            ty.* = l_ty.*;
                            return ty;
                        }
                        if (!isNumericType(l_ty)) {
                            self.setError("binary expression requires numeric operands: op={s}, operand tag={s}", .{ @tagName(bin.op), @tagName(l_ty.*) });
                            return TypeError.TypeMismatch;
                        }
                        ty.* = l_ty.*;
                    },
                    .bit_and, .bit_or, .bit_xor => {
                        if (!self.typesEqual(l_ty, r_ty)) return TypeError.TypeMismatch;
                        if (l_ty.* == .infer) {
                            ty.* = l_ty.*;
                            return ty;
                        }
                        if (!isAnyIntegerType(l_ty)) return TypeError.TypeMismatch;
                        ty.* = l_ty.*;
                    },
                    .shl, .shr => {
                        if (l_ty.* == .infer) {
                            if (!isAnyIntegerType(r_ty) and r_ty.* != .infer) return TypeError.TypeMismatch;
                            ty.* = l_ty.*;
                            return ty;
                        }
                        if (!isAnyIntegerType(l_ty)) return TypeError.TypeMismatch;
                        if (r_ty.* != .infer and !isAnyIntegerType(r_ty)) return TypeError.TypeMismatch;
                        ty.* = l_ty.*;
                    },
                    .spaceship => {
                        if (try self.overloadSymbol(bin.op, l_ty, r_ty)) |symbol| {
                            const call_symbol = try self.allocator.dupe(u8, symbol);
                            try self.resolved_call_symbols.put(@as(*const ast.Node, @ptrCast(&bin)), call_symbol);
                            const ret = self.funcs.get(symbol) orelse return TypeError.UndefinedVariable;
                            ty.* = ret.ret_ty.*;
                            return ty;
                        }
                        if (self.structDeclForType(l_ty)) |left_struct| {
                            if (self.structDeclForType(r_ty)) |right_struct| {
                                if (!self.typesEqual(l_ty, r_ty) or left_struct != right_struct) return TypeError.TypeMismatch;
                                if (!self.typeIsOrd(l_ty)) return TypeError.TypeMismatch;
                                return try self.makeOrderingType();
                            }
                        }
                        if (!self.typesEqual(l_ty, r_ty)) return TypeError.TypeMismatch;
                        if (!isNumericType(l_ty)) return TypeError.TypeMismatch;
                        return try self.makeOrderingType();
                    },
                    .eq, .ne, .lt, .le, .gt, .ge => {
                        if (self.structDeclForType(l_ty)) |left_struct| {
                            if (self.structDeclForType(r_ty)) |right_struct| {
                                if (!self.typesEqual(l_ty, r_ty) or left_struct != right_struct) return TypeError.TypeMismatch;
                                const supported = switch (bin.op) {
                                    .eq, .ne => self.typeIsEq(l_ty),
                                    .lt, .le, .gt, .ge => self.typeIsOrd(l_ty),
                                    else => false,
                                };
                                if (!supported) return TypeError.TypeMismatch;
                                ty.* = .{ .primitive = .boolean };
                                return ty;
                            }
                        }
                        if (!self.typesEqual(l_ty, r_ty)) return TypeError.TypeMismatch;
                        ty.* = .{ .primitive = .boolean };
                    },
                    .logical_and, .logical_or => {
                        if (!self.typesEqual(l_ty, r_ty)) return TypeError.TypeMismatch;
                        if (l_ty.* == .infer) {
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                        if (!isPrimitiveType(l_ty, .boolean)) return TypeError.TypeMismatch;
                        ty.* = .{ .primitive = .boolean };
                    },
                }
                return ty;
            },
            .borrow_expr => |borrow| {
                const inner_ty = try self.checkExpr(borrow.expr, scope);
                // For borrow, variable must be Active
                if (borrow.expr.* == .identifier) {
                    const sym = scope.lookup(borrow.expr.identifier) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                }
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .borrow = inner_ty };
                return ty;
            },
            .move_expr => |move| {
                const inner_ty = try self.checkExpr(move.expr, scope);
                if (move.expr.* == .identifier) {
                    const sym = scope.lookup(move.expr.identifier) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    try self.consumeBinding(scope, move.expr.identifier, sym, "explicit move");
                }
                return inner_ty;
            },
            .deref_expr => |deref| {
                const inner_ty = try self.checkExpr(deref.expr, scope);
                if (inner_ty.* == .infer) return try self.makeInferType();
                if (rcInnerType(inner_ty)) |rc_inner| return rc_inner;
                if (arcInnerType(inner_ty)) |arc_inner| return arc_inner;
                if (boxInnerType(inner_ty)) |box_inner| return box_inner;
                if (mutexGuardInnerType(inner_ty)) |guard_inner| return guard_inner;
                if (rwLockReadGuardInnerType(inner_ty)) |guard_inner| return guard_inner;
                if (rwLockWriteGuardInnerType(inner_ty)) |guard_inner| return guard_inner;
                return @constCast(lowering_rules.pointerOrBorrowPointee(inner_ty) orelse return TypeError.DereferenceNonPointer);
            },
            .cast_expr => |cast| {
                const src_ty = try self.checkExpr(cast.expr, scope);
                if (isPointerCarrierCastType(src_ty) and isPointerCarrierCastType(cast.ty)) {
                    return cast.ty;
                }
                if (src_ty.* == .infer) return cast.ty;
                if (!isNumericType(src_ty) or !isNumericType(cast.ty)) {
                    self.setError("unsupported cast: only numeric primitive casts are currently allowed", .{});
                    return TypeError.TypeMismatch;
                }
                return cast.ty;
            },
            .field_expr => |field| {
                if (std.mem.eql(u8, field.field_name, "len")) {
                    const recv_ty = try self.checkExpr(field.expr, scope);
                    if (isStringLikeType(recv_ty)) {
                        const ty = try self.allocator.create(ast.Type);
                        ty.* = .{ .primitive = .u64 };
                        return ty;
                    }
                }
                if (field.expr.* == .literal and field.expr.literal == .string_val and std.mem.eql(u8, field.field_name, "len")) {
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .u64 };
                    return ty;
                }
                const struct_ty = try self.checkExpr(field.expr, scope);
                const curr_ty = @constCast(lowering_rules.peelBorrowPointerType(struct_ty));
                switch (curr_ty.*) {
                    .user_defined => |ud| {
                        const decl = self.structDeclForType(curr_ty) orelse {
                            self.setError("field access target `{s}` is not a known struct", .{ud.name});
                            return TypeError.NotAStruct;
                        };
                        if (decl.is_opaque) {
                            self.setError("opaque type field access is not allowed: {s}", .{ud.name});
                            return TypeError.FieldNotFound;
                        }
                        if (decl.is_union and self.unsafe_depth == 0) {
                            self.setError("union field access requires unsafe", .{});
                            return TypeError.CompileError;
                        }
                        for (decl.fields) |f| {
                            if (std.mem.eql(u8, f.name, field.field_name)) {
                                return f.ty;
                            }
                        }
                        self.setError("FieldNotFound: `{s}` has no field `{s}`", .{ ud.name, field.field_name });
                        return TypeError.FieldNotFound;
                    },
                    .tuple => |tuple| {
                        const index = std.fmt.parseInt(usize, field.field_name, 10) catch {
                            self.setError("FieldNotFound: tuple field `{s}` is not a numeric index", .{field.field_name});
                            return TypeError.FieldNotFound;
                        };
                        if (index >= tuple.elems.len) {
                            self.setError("FieldNotFound: tuple index `{s}` out of range {}", .{ field.field_name, tuple.elems.len });
                            return TypeError.FieldNotFound;
                        }
                        return tuple.elems[index];
                    },
                    .infer => return try self.makeInferType(),
                    else => {
                        self.setError("field access `{s}` requires struct/tuple target, got tag={s}", .{ field.field_name, @tagName(curr_ty.*) });
                        return TypeError.NotAStruct;
                    },
                }
            },
            .struct_literal => |lit| {
                if (lit.ty.* != .user_defined) return TypeError.NotAStruct;
                const ud = lit.ty.user_defined;
                const decl = self.structDeclForType(lit.ty) orelse return TypeError.NotAStruct;
                if (decl.is_opaque) {
                    self.setError("cannot construct opaque type {s}", .{ud.name});
                    return TypeError.NotAStruct;
                }

                if (lit.update_expr) |update_expr| {
                    const update_ty = try self.checkExpr(update_expr, scope);
                    if (update_ty.* != .user_defined or !std.mem.eql(u8, update_ty.user_defined.name, ud.name)) {
                        self.setError("struct update expression type mismatch", .{});
                        return TypeError.TypeMismatch;
                    }
                }

                var seen = std.StringHashMap(void).init(self.allocator);
                defer seen.deinit();

                for (lit.fields) |literal_field| {
                    if (seen.contains(literal_field.name)) {
                        self.setError("Duplicate field in struct literal: {s}.{s}", .{ ud.name, literal_field.name });
                        return TypeError.CompileError;
                    }
                    try seen.put(literal_field.name, {});

                    var expected_ty: ?*ast.Type = null;
                    for (decl.fields) |decl_field| {
                        if (std.mem.eql(u8, decl_field.name, literal_field.name)) {
                            expected_ty = decl_field.ty;
                            break;
                        }
                    }

                    const field_ty = expected_ty orelse {
                        self.setError("Field not found in struct literal: {s}.{s}", .{ ud.name, literal_field.name });
                        return TypeError.FieldNotFound;
                    };
                    const value_ty = try self.checkExpr(literal_field.value, scope);
                    if (!self.typesEqual(field_ty, value_ty)) {
                        self.setError("TypeMismatch in struct literal field {s}.{s}: expected {s}, actual {s}", .{ ud.name, literal_field.name, typeDesc(field_ty), typeDesc(value_ty) });
                        return TypeError.TypeMismatch;
                    }
                }

                if (decl.is_union) {
                    if (seen.count() != 1) {
                        self.setError("Union literal must initialize exactly one field: {s}", .{ud.name});
                        return TypeError.CompileError;
                    }
                } else if (lit.update_expr == null and seen.count() != decl.fields.len) {
                    self.setError("Missing field in struct literal: {s}", .{ud.name});
                    return TypeError.FieldNotFound;
                }

                return lit.ty;
            },
            .enum_literal => |lit| {
                const decl = self.enums.get(lit.enum_name) orelse return TypeError.NotAStruct;
                const variant = findEnumVariant(decl, lit.variant_name) orelse return TypeError.FieldNotFound;

                var seen = std.StringHashMap(void).init(self.allocator);
                defer seen.deinit();

                for (lit.fields) |literal_field| {
                    if (seen.contains(literal_field.name)) return TypeError.CompileError;
                    try seen.put(literal_field.name, {});

                    var expected_ty: ?*ast.Type = null;
                    for (variant.fields) |field| {
                        if (std.mem.eql(u8, field.name, literal_field.name)) {
                            expected_ty = field.ty;
                            break;
                        }
                    }
                    const field_ty = expected_ty orelse return TypeError.FieldNotFound;
                    const value_ty = try self.checkExpr(literal_field.value, scope);
                    if (!self.typesEqual(field_ty, value_ty)) return TypeError.TypeMismatch;
                }
                if (seen.count() != variant.fields.len) return TypeError.FieldNotFound;

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .user_defined = .{ .name = lit.enum_name, .generics = &.{} } };
                return ty;
            },
            .tuple_literal => |lit| {
                if (lit.elements.len == 0) {
                    self.setError("Cannot infer empty tuple literal type", .{});
                    return TypeError.TypeMismatch;
                }

                var elems = std.ArrayList(*ast.Type).init(self.allocator);
                for (lit.elements) |elem| {
                    try elems.append(try self.checkExpr(elem, scope));
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .tuple = .{ .elems = try elems.toOwnedSlice() } };
                return ty;
            },
            .array_literal => |lit| {
                if (lit.elements.len == 0) {
                    self.setError("Cannot infer empty array literal type", .{});
                    return TypeError.TypeMismatch;
                }

                const elem_ty = try self.checkExpr(lit.elements[0], scope);
                for (lit.elements[1..]) |elem| {
                    const curr_ty = try self.checkExpr(elem, scope);
                    if (!self.typesEqual(elem_ty, curr_ty)) {
                        self.setError("TypeMismatch in array literal: element tag={s}, actual tag={s}", .{ @tagName(elem_ty.*), @tagName(curr_ty.*) });
                        return TypeError.TypeMismatch;
                    }
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .array = .{ .elem = elem_ty, .len = lit.elements.len } };
                return ty;
            },
            .repeat_array_literal => |lit| {
                const elem_ty = try self.checkExpr(lit.value, scope);
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .array = .{ .elem = elem_ty, .len = lit.len } };
                return ty;
            },
            .index_expr => |idx| {
                const target_ty = try self.checkExpr(idx.target, scope);
                const index_ty = try self.checkExpr(idx.index, scope);

                if (target_ty.* == .infer) return try self.makeInferType();

                if (hashMapTypes(target_ty)) |hm| {
                    if (!self.typesEqual(hm.key, index_ty)) return TypeError.TypeMismatch;
                    return hm.value;
                }

                if (btreeMapTypes(target_ty)) |bm| {
                    if (!self.typesEqual(bm.key, index_ty)) return TypeError.TypeMismatch;
                    return bm.value;
                }

                if (!isNumericType(index_ty)) return TypeError.TypeMismatch;

                if (vecElementType(target_ty)) |elem_ty| return elem_ty;
                if (vecDequeElementType(target_ty)) |elem_ty| return elem_ty;
                if (sliceElementType(target_ty)) |elem_ty| return elem_ty;

                const arr = arrayType(target_ty) orelse return TypeError.TypeMismatch;
                return arr.elem;
            },
            .slice_expr => |slc| {
                const target_ty = try self.checkExpr(slc.target, scope);
                const start_ty = try self.checkExpr(slc.start, scope);
                const end_ty = try self.checkExpr(slc.end, scope);
                if (!isNumericType(start_ty) or !isNumericType(end_ty)) return TypeError.TypeMismatch;

                const arr = arrayType(target_ty) orelse return TypeError.TypeMismatch;
                if (slc.start.* != .literal or slc.start.literal != .int_val or slc.end.* != .literal or slc.end.literal != .int_val) {
                    self.setError("slice ranges currently require integer literal bounds", .{});
                    return TypeError.TypeMismatch;
                }
                const start = slc.start.literal.int_val;
                const end = slc.end.literal.int_val;
                if (start < 0 or end < start or @as(usize, @intCast(end)) > arr.len) {
                    self.setError("slice range out of bounds: {}..{} for len {}", .{ start, end, arr.len });
                    return TypeError.TypeMismatch;
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .array = .{ .elem = arr.elem, .len = @as(usize, @intCast(end - start)) } };
                return ty;
            },
            .await_expr => |aw| {
                const future_ty = try self.checkExpr(aw.expr, scope);
                const inner_ty = switch (future_ty.*) {
                    .future => |inner| inner,
                    else => {
                        self.setError("await requires future<T>, actual tag={s}", .{@tagName(future_ty.*)});
                        return TypeError.TypeMismatch;
                    },
                };
                try self.recordAwaitCleanup(expr, aw.expr, scope);
                if (rootIdentifier(aw.expr)) |name| {
                    const sym = scope.lookup(name) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    try self.consumeBinding(scope, name, sym, "await");
                }
                return inner_ty;
            },
            .inline_asm_expr => |asm_expr| {
                if (self.unsafe_depth == 0) {
                    self.setError("inline asm requires unsafe", .{});
                    return TypeError.CompileError;
                }
                for (asm_expr.operands) |operand| {
                    if (!std.mem.eql(u8, operand.constraint, "inout")) {
                        self.setError("unsupported asm operand constraint: {s}", .{operand.constraint});
                        return TypeError.CompileError;
                    }
                    const sym = scope.lookup(operand.var_name) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    if (!isNumericType(sym.ty)) return TypeError.TypeMismatch;
                }
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .primitive = .void_type };
                return ty;
            },
            .closure_literal => |lit| {
                for (lit.params) |p| {
                    if (p.ty.* == .infer) {
                        self.setError("closure parameter types must be inferred from context; standalone inference is not available", .{});
                        return TypeError.TypeMismatch;
                    }
                }
                const closure_scope = try Scope.init(self.allocator, scope);
                try self.scope_pool.append(closure_scope);

                var param_types = std.ArrayList(*ast.Type).init(self.allocator);
                for (lit.params) |p| {
                    try self.defineSymbol(closure_scope, p.name, p.ty, true);
                    try param_types.append(p.ty);
                }

                const ret_ty = try self.checkExpr(lit.body, closure_scope);
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .closure = .{ .params = try param_types.toOwnedSlice(), .ret = ret_ty } };
                return ty;
            },
            .call_expr => |call| {
                const recv_node_ty = if (call.args.len > 0 and call.args[0].* != .move_expr) try self.checkExpr(call.args[0], scope) else null;

                if (lowering_rules.isOptionSomeCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const inner_ty = try self.checkExpr(call.args[0], scope);
                    return try self.makeOptionType(inner_ty);
                }

                if (lowering_rules.isResultOkCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const ok_ty = try self.checkExpr(call.args[0], scope);
                    return try self.makeResultType(ok_ty, try self.makeInferType());
                }

                if (lowering_rules.isResultErrCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const err_ty = try self.checkExpr(call.args[0], scope);
                    return try self.makeResultType(try self.makeInferType(), err_ty);
                }

                if (lowering_rules.isPtrNullCall(call)) {
                    if (call.args.len != 0) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 1) return TypeError.InvalidArgsCount;
                    return try self.makePointerType(call.generics[0]);
                }

                if (std.mem.eql(u8, call.func_name, "future__pending")) {
                    if (call.args.len != 0) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 1) return TypeError.InvalidArgsCount;
                    return try self.makeFutureType(call.generics[0]);
                }

                if (std.mem.eql(u8, call.func_name, "future__defer_ready")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                    const inner_ty = try self.checkExpr(call.args[0], scope);
                    return try self.makeFutureType(inner_ty);
                }

                if (std.mem.eql(u8, call.func_name, "future__sleep_ms")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                    _ = try self.checkExpr(call.args[0], scope);
                    const u64_inner = try self.makeU64Type();
                    return try self.makeFutureType(u64_inner);
                }

                if (std.mem.eql(u8, call.func_name, "future__join2")) {
                    return try self.checkFutureJoin2Call(call, scope);
                }

                if (std.mem.eql(u8, call.func_name, "future__pair_left")) {
                    return try self.checkFuturePairAccessorCall(call, scope, true);
                }

                if (std.mem.eql(u8, call.func_name, "future__pair_right")) {
                    return try self.checkFuturePairAccessorCall(call, scope, false);
                }

                if (std.mem.eql(u8, call.func_name, "future__select2")) {
                    return try self.checkFutureSelect2Call(call, scope);
                }

                if (std.mem.eql(u8, call.func_name, "future__either_side")) {
                    return try self.checkFutureEitherSideCall(call, scope);
                }

                if (std.mem.eql(u8, call.func_name, "future__either_left")) {
                    return try self.checkFutureEitherAccessorCall(call, scope, true);
                }

                if (std.mem.eql(u8, call.func_name, "future__either_right")) {
                    return try self.checkFutureEitherAccessorCall(call, scope, false);
                }

                if (std.mem.eql(u8, call.func_name, "poll__ready")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                    const inner_ty = try self.checkExpr(call.args[0], scope);
                    if (!isPollScalarValueType(inner_ty)) return TypeError.TypeMismatch;
                    return try self.makePollType(inner_ty);
                }

                if (std.mem.eql(u8, call.func_name, "poll__pending")) {
                    if (call.args.len != 0) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 1) return TypeError.InvalidArgsCount;
                    if (!isPollScalarValueType(call.generics[0])) return TypeError.TypeMismatch;
                    return try self.makePollType(call.generics[0]);
                }

                if (std.mem.eql(u8, call.func_name, "poll__is_ready") or std.mem.eql(u8, call.func_name, "poll__is_pending")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                    const poll_ty = try self.checkExpr(call.args[0], scope);
                    _ = pollInnerType(poll_ty) orelse return TypeError.TypeMismatch;
                    return try self.makeBoolType();
                }

                if (std.mem.eql(u8, call.func_name, "poll__value")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                    const poll_ty = try self.checkExpr(call.args[0], scope);
                    const inner_ty = pollInnerType(poll_ty) orelse return TypeError.TypeMismatch;
                    if (!isPollScalarValueType(inner_ty)) return TypeError.TypeMismatch;
                    return inner_ty;
                }

                if (std.mem.eql(u8, call.func_name, "RAW_WAKER_NEW")) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const data_ty = try self.checkExpr(call.args[0], scope);
                    const vtable_ty = try self.checkExpr(call.args[1], scope);
                    if (!isPointerValueType(data_ty) or !isPointerValueType(vtable_ty)) return TypeError.TypeMismatch;
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .user_defined = .{ .name = "RawWaker", .generics = &.{} } };
                    return ty;
                }

                if (std.mem.eql(u8, call.func_name, "RAW_WAKER_GET_DATA") or
                    std.mem.eql(u8, call.func_name, "RAW_WAKER_GET_VTABLE"))
                {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    _ = try self.checkExpr(call.args[0], scope);
                    return try self.makePointerType(try self.makeInferType());
                }

                if (std.mem.eql(u8, call.func_name, "RAW_WAKER_CLONE")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    _ = try self.checkExpr(call.args[0], scope);
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .user_defined = .{ .name = "RawWaker", .generics = &.{} } };
                    return ty;
                }

                if (std.mem.eql(u8, call.func_name, "WAKER_FROM_RAW") or std.mem.eql(u8, call.func_name, "WAKER_CLONE")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    _ = try self.checkExpr(call.args[0], scope);
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .user_defined = .{ .name = "Waker", .generics = &.{} } };
                    return ty;
                }

                if (std.mem.eql(u8, call.func_name, "WAKER_GET_DATA") or
                    std.mem.eql(u8, call.func_name, "WAKER_GET_VTABLE") or
                    std.mem.eql(u8, call.func_name, "LOCAL_WAKER_GET_DATA") or
                    std.mem.eql(u8, call.func_name, "LOCAL_WAKER_GET_VTABLE"))
                {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    _ = try self.checkExpr(call.args[0], scope);
                    return try self.makePointerType(try self.makeInferType());
                }

                if (std.mem.eql(u8, call.func_name, "WAKER_WILL_WAKE")) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    _ = try self.checkExpr(call.args[0], scope);
                    _ = try self.checkExpr(call.args[1], scope);
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .boolean };
                    return ty;
                }

                if (std.mem.eql(u8, call.func_name, "WAKER_WAKE") or
                    std.mem.eql(u8, call.func_name, "WAKER_WAKE_BY_REF") or
                    std.mem.eql(u8, call.func_name, "RAW_WAKER_WAKE") or
                    std.mem.eql(u8, call.func_name, "RAW_WAKER_WAKE_BY_REF"))
                {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    _ = try self.checkExpr(call.args[0], scope);
                    return try self.makeI32Type();
                }

                if (std.mem.eql(u8, call.func_name, "std__ptr__read_volatile") or std.mem.eql(u8, call.func_name, "ptr__read_volatile")) {
                    if (self.unsafe_depth == 0) {
                        self.setError("ptr::read_volatile requires unsafe", .{});
                        return TypeError.CompileError;
                    }
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const ptr_ty = try self.checkExpr(call.args[0], scope);
                    return @constCast(lowering_rules.pointerOrBorrowPointee(ptr_ty) orelse return TypeError.TypeMismatch);
                }

                if (recv_node_ty) |rt| {
                    if (try self.resolveUsingMethodSymbolForType(scope, rt, call.func_name, call.args.len)) |symbol| {
                        if (try self.checkStaticCallBySymbol(expr, symbol, call.args, scope, call.func_name, false)) |ret_ty| return ret_ty;
                        return TypeError.UndefinedVariable;
                    }
                }

                if (call.associated_target) |target_name| {
                    if (self.traits.contains(target_name)) {
                        if (call.args.len == 0) {
                            self.setError("Trait associated call {s}::{s} needs an implementing value argument", .{ target_name, call.func_name });
                            return TypeError.InvalidArgsCount;
                        }
                        const recv_ty = try self.checkExpr(call.args[0], scope);
                        const concrete_name = concreteTypeName(recv_ty) orelse return TypeError.TypeMismatch;
                        const symbol = (try self.resolveTraitMethodSymbolForType(concrete_name, target_name, call.func_name, call.args.len)) orelse {
                            self.setError("Type `{s}` does not implement trait method `{s}::{s}`", .{ concrete_name, target_name, call.func_name });
                            return TypeError.UndefinedVariable;
                        };
                        const func = self.funcs.get(symbol) orelse return TypeError.UndefinedVariable;
                        try self.checkCallArgsAgainstFunc(func, call.args, scope, call.func_name, false);
                        self.resolved_call_symbols.put(expr, symbol) catch return TypeError.OutOfMemory;
                        if (func.is_async) return try self.makeFutureType(func.ret_ty);
                        return func.ret_ty;
                    }

                    const is_ptr_target = std.mem.eql(u8, target_name, "std__ptr") or std.mem.eql(u8, target_name, "ptr");
                    if (is_ptr_target and std.mem.eql(u8, call.func_name, "null")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 1) return TypeError.InvalidArgsCount;
                        return try self.makePointerType(call.generics[0]);
                    }
                    if (is_ptr_target and std.mem.eql(u8, call.func_name, "read_volatile")) {
                        if (self.unsafe_depth == 0) {
                            self.setError("ptr::read_volatile requires unsafe", .{});
                            return TypeError.CompileError;
                        }
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const ptr_ty = try self.checkExpr(call.args[0], scope);
                        return @constCast(lowering_rules.pointerOrBorrowPointee(ptr_ty) orelse return TypeError.TypeMismatch);
                    }
                    if (lowering_rules.isMemForgetCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        _ = try self.checkExpr(call.args[0], scope);
                        if (rootIdentifier(call.args[0])) |name| {
                            const sym = scope.lookup(name) orelse return TypeError.UndefinedVariable;
                            if (sym.state == .consumed) return TypeError.UseAfterMove;
                            try self.consumeBinding(scope, name, sym, "mem::forget");
                        }
                        const ty = try self.allocator.create(ast.Type);
                        ty.* = .{ .primitive = .void_type };
                        return ty;
                    }
                    if (lowering_rules.isManuallyDropNewCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeManuallyDropType(inner_ty);
                    }
                    if (lowering_rules.isManuallyDropIntoInnerCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const slot_ty = try self.checkExpr(call.args[0], scope);
                        const inner_ty = manuallyDropInnerType(slot_ty) orelse return TypeError.TypeMismatch;
                        if (call.args[0].* == .identifier) {
                            const sym = scope.lookup(call.args[0].identifier) orelse return TypeError.UndefinedVariable;
                            if (sym.state == .consumed) return TypeError.UseAfterMove;
                            try self.consumeBinding(scope, call.args[0].identifier, sym, "ManuallyDrop::into_inner");
                        }
                        return inner_ty;
                    }
                    if (lowering_rules.isMpscChannelCall(call)) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const elem_ty = try self.makeI32Type();
                        const sender_ty = try self.makeSenderType(elem_ty);
                        const receiver_ty = try self.makeReceiverType(elem_ty);
                        return try self.makeTupleType(&.{ sender_ty, receiver_ty });
                    }
                    if (std.mem.eql(u8, target_name, "thread") and std.mem.eql(u8, call.func_name, "spawn")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const closure_ty = try self.checkExpr(call.args[0], scope);
                        if (closure_ty.* != .closure or closure_ty.closure.params.len != 0) return TypeError.TypeMismatch;
                        const ret_ty = if (closure_ty.closure.ret.* == .primitive and closure_ty.closure.ret.primitive == .integer)
                            try self.makeI32Type()
                        else
                            closure_ty.closure.ret;
                        return try self.makeJoinHandleType(ret_ty);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "ready")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeFutureType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "defer_ready")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeFutureType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "sleep_ms")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        _ = try self.checkExpr(call.args[0], scope);
                        const u64_inner = try self.makeU64Type();
                        return try self.makeFutureType(u64_inner);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "pending")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 1) return TypeError.InvalidArgsCount;
                        return try self.makeFutureType(call.generics[0]);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "join2")) {
                        return try self.checkFutureJoin2Call(call, scope);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "pair_left")) {
                        return try self.checkFuturePairAccessorCall(call, scope, true);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "pair_right")) {
                        return try self.checkFuturePairAccessorCall(call, scope, false);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "select2")) {
                        return try self.checkFutureSelect2Call(call, scope);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "either_side")) {
                        return try self.checkFutureEitherSideCall(call, scope);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "either_left")) {
                        return try self.checkFutureEitherAccessorCall(call, scope, true);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "either_right")) {
                        return try self.checkFutureEitherAccessorCall(call, scope, false);
                    }
                    if (std.mem.eql(u8, target_name, "poll") and std.mem.eql(u8, call.func_name, "ready")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        if (!isPollScalarValueType(inner_ty)) return TypeError.TypeMismatch;
                        return try self.makePollType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "poll") and std.mem.eql(u8, call.func_name, "pending")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 1) return TypeError.InvalidArgsCount;
                        if (!isPollScalarValueType(call.generics[0])) return TypeError.TypeMismatch;
                        return try self.makePollType(call.generics[0]);
                    }
                    if (std.mem.eql(u8, target_name, "poll") and (std.mem.eql(u8, call.func_name, "is_ready") or std.mem.eql(u8, call.func_name, "is_pending"))) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const poll_ty = try self.checkExpr(call.args[0], scope);
                        _ = pollInnerType(poll_ty) orelse return TypeError.TypeMismatch;
                        return try self.makeBoolType();
                    }
                    if (std.mem.eql(u8, target_name, "poll") and std.mem.eql(u8, call.func_name, "value")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const poll_ty = try self.checkExpr(call.args[0], scope);
                        const inner_ty = pollInnerType(poll_ty) orelse return TypeError.TypeMismatch;
                        if (!isPollScalarValueType(inner_ty)) return TypeError.TypeMismatch;
                        return inner_ty;
                    }
                    if (std.mem.eql(u8, target_name, "task") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const future_ty = try self.checkExpr(call.args[0], scope);
                        const inner_ty = switch (future_ty.*) {
                            .future => |inner| inner,
                            else => return TypeError.TypeMismatch,
                        };
                        return try self.makeTaskType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "task") and (std.mem.eql(u8, call.func_name, "poll") or std.mem.eql(u8, call.func_name, "is_ready"))) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const task_ty = try self.checkExpr(call.args[0], scope);
                        _ = taskInnerType(task_ty) orelse return TypeError.TypeMismatch;
                        return try self.makeBoolType();
                    }
                    if (std.mem.eql(u8, target_name, "task") and std.mem.eql(u8, call.func_name, "result")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const task_ty = try self.checkExpr(call.args[0], scope);
                        return taskInnerType(task_ty) orelse return TypeError.TypeMismatch;
                    }
                    if (std.mem.eql(u8, target_name, "task") and std.mem.eql(u8, call.func_name, "state")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const task_ty = try self.checkExpr(call.args[0], scope);
                        _ = taskInnerType(task_ty) orelse return TypeError.TypeMismatch;
                        return try self.makeU64Type();
                    }
                    if (std.mem.eql(u8, target_name, "executor") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const tasks_ty = try self.checkExpr(call.args[0], scope);
                        const inner_ty = executorTaskBufferInnerType(tasks_ty) orelse return TypeError.TypeMismatch;
                        return try self.makeExecutorType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "executor") and std.mem.eql(u8, call.func_name, "poll_one")) {
                        if (call.args.len != 2) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const executor_ty = try self.checkExpr(call.args[0], scope);
                        _ = executorInnerType(executor_ty) orelse return TypeError.TypeMismatch;
                        const index_ty = try self.checkExpr(call.args[1], scope);
                        if (!isNumericType(index_ty)) return TypeError.TypeMismatch;
                        return try self.makeBoolType();
                    }
                    if (std.mem.eql(u8, target_name, "executor") and std.mem.eql(u8, call.func_name, "poll_ready_count")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const executor_ty = try self.checkExpr(call.args[0], scope);
                        _ = executorInnerType(executor_ty) orelse return TypeError.TypeMismatch;
                        return try self.makeU64Type();
                    }
                    if (std.mem.eql(u8, target_name, "executor") and std.mem.eql(u8, call.func_name, "run_until_complete")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const executor_ty = try self.checkExpr(call.args[0], scope);
                        _ = executorInnerType(executor_ty) orelse return TypeError.TypeMismatch;
                        return try self.makeU64Type();
                    }
                    if (lowering_rules.isBoxNewCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeBoxType(inner_ty);
                    }
                    if (lowering_rules.isBoxIntoRawCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const box_ty = try self.checkExpr(call.args[0], scope);
                        const inner_ty = boxInnerType(box_ty) orelse return TypeError.TypeMismatch;
                        if (rootIdentifier(call.args[0])) |name| {
                            const sym = scope.lookup(name) orelse return TypeError.UndefinedVariable;
                            if (sym.state == .consumed) return TypeError.UseAfterMove;
                            try self.consumeBinding(scope, name, sym, "Box::into_raw");
                        }
                        return try self.makePointerType(inner_ty);
                    }
                    if (lowering_rules.isBoxFromRawCall(call)) {
                        if (self.unsafe_depth == 0) {
                            self.setError("Box::from_raw requires unsafe", .{});
                            return TypeError.CompileError;
                        }
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const ptr_ty = try self.checkExpr(call.args[0], scope);
                        return switch (ptr_ty.*) {
                            .pointer => |inner| try self.makeBoxType(inner),
                            .borrow => |inner| try self.makeBoxType(inner),
                            else => TypeError.TypeMismatch,
                        };
                    }
                    if (lowering_rules.isRcNewCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeRcType(inner_ty);
                    }
                    if (lowering_rules.isArcNewCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeArcType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "AtomicI32") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        if (!isNumericType(value_ty)) return TypeError.TypeMismatch;
                        return try self.makeAtomicI32Type();
                    }
                    if (std.mem.eql(u8, target_name, "AtomicUsize") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        if (!isNumericType(value_ty)) return TypeError.TypeMismatch;
                        return try self.makeAtomicUsizeType();
                    }
                    if (std.mem.eql(u8, target_name, "AtomicPtr") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        const inner_ty = switch (value_ty.*) {
                            .pointer => |inner| inner,
                            else => return TypeError.TypeMismatch,
                        };
                        return try self.makeAtomicPtrType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "Cell") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        if (!isCellValueType(value_ty)) return TypeError.TypeMismatch;
                        return try self.makeCellType(value_ty);
                    }
                    if (std.mem.eql(u8, target_name, "RefCell") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeRefCellType(value_ty);
                    }
                    if (std.mem.eql(u8, target_name, "Mutex") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        if (!isNumericType(value_ty)) return TypeError.TypeMismatch;
                        const inner_ty = if (call.args[0].* == .literal and call.args[0].literal == .int_val) try self.makeI32Type() else value_ty;
                        if (inner_ty != value_ty) self.expr_types.put(call.args[0], inner_ty) catch return TypeError.OutOfMemory;
                        return try self.makeMutexType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "RwLock") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        if (!isNumericType(value_ty)) return TypeError.TypeMismatch;
                        const inner_ty = if (call.args[0].* == .literal and call.args[0].literal == .int_val) try self.makeI32Type() else value_ty;
                        if (inner_ty != value_ty) self.expr_types.put(call.args[0], inner_ty) catch return TypeError.OutOfMemory;
                        return try self.makeRwLockType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "File") and std.mem.eql(u8, call.func_name, "open")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const path_ty = try self.checkExpr(call.args[0], scope);
                        if (!isStringLikeType(path_ty)) return TypeError.TypeMismatch;
                        return try self.makeResultType(try self.makeFileType(), try self.makeI32Type());
                    }
                    if (std.mem.eql(u8, target_name, "VecDeque") and std.mem.eql(u8, call.func_name, "from")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const array_ty = try self.checkExpr(call.args[0], scope);
                        const arr = arrayType(array_ty) orelse return TypeError.TypeMismatch;
                        return try self.makeVecDequeType(arr.elem);
                    }
                    if (std.mem.eql(u8, target_name, "VecDeque") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const elem_ty = if (call.generics.len == 1) call.generics[0] else try self.makeInferType();
                        return try self.makeVecDequeType(elem_ty);
                    }
                    if (std.mem.eql(u8, target_name, "HashMap") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const key_ty = if (call.generics.len >= 1) call.generics[0] else try self.makeInferType();
                        const value_ty = if (call.generics.len >= 2) call.generics[1] else try self.makeInferType();
                        return try self.makeHashMapType(key_ty, value_ty);
                    }
                    if (std.mem.eql(u8, target_name, "HashSet") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const key_ty = if (call.generics.len >= 1) call.generics[0] else try self.makeInferType();
                        return try self.makeHashSetType(key_ty);
                    }
                    if (std.mem.eql(u8, target_name, "BTreeMap") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const key_ty = if (call.generics.len >= 1) call.generics[0] else try self.makeInferType();
                        const value_ty = if (call.generics.len >= 2) call.generics[1] else try self.makeInferType();
                        return try self.makeBTreeMapType(key_ty, value_ty);
                    }
                    if (std.mem.eql(u8, target_name, "BTreeSet") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const key_ty = if (call.generics.len >= 1) call.generics[0] else try self.makeInferType();
                        return try self.makeBTreeSetType(key_ty);
                    }
                    if (std.mem.eql(u8, target_name, "Vec") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const elem_ty = if (call.generics.len == 1) call.generics[0] else try self.makeInferType();
                        const generics = try self.allocator.alloc(*ast.Type, 1);
                        generics[0] = elem_ty;
                        const ty = try self.allocator.create(ast.Type);
                        ty.* = .{ .user_defined = .{ .name = "Vec", .generics = generics } };
                        return ty;
                    }
                    const method_key = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ target_name, call.func_name });
                    if (self.funcs.get(method_key)) |func| {
                        try self.checkCallArgsAgainstFunc(func, call.args, scope, call.func_name, false);
                        self.resolved_call_symbols.put(expr, method_key) catch return TypeError.OutOfMemory;
                        if (func.is_async) return try self.makeFutureType(func.ret_ty);
                        return func.ret_ty;
                    }
                    if (try self.resolveTraitMethodSymbolForType(target_name, null, call.func_name, call.args.len)) |symbol| {
                        const func = self.funcs.get(symbol) orelse return TypeError.UndefinedVariable;
                        try self.checkCallArgsAgainstFunc(func, call.args, scope, call.func_name, false);
                        self.resolved_call_symbols.put(expr, symbol) catch return TypeError.OutOfMemory;
                        if (func.is_async) return try self.makeFutureType(func.ret_ty);
                        return func.ret_ty;
                    }
                }

                if (std.mem.eql(u8, call.func_name, "vec")) {
                    if (call.args.len == 0) {
                        self.setError("vec requires at least one element", .{});
                        return TypeError.InvalidArgsCount;
                    }
                    const elem_ty = try self.checkExpr(call.args[0], scope);
                    for (call.args[1..]) |arg| {
                        const arg_ty = try self.checkExpr(arg, scope);
                        if (!self.typesEqual(elem_ty, arg_ty)) return TypeError.TypeMismatch;
                    }
                    const generics = try self.allocator.alloc(*ast.Type, 1);
                    generics[0] = elem_ty;
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .user_defined = .{ .name = "Vec", .generics = generics } };
                    return ty;
                }

                if (lowering_rules.isLenCall(call) and call.args.len == 1) {
                    _ = try self.checkExpr(call.args[0], scope);
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .usize };
                    return ty;
                }
                if (lowering_rules.isLenCall(call)) {
                    self.setError("len call arity mismatch: {}", .{call.args.len});
                    return TypeError.InvalidArgsCount;
                }
                if (lowering_rules.isStrEqCall(call)) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const left_ty = try self.checkExpr(call.args[0], scope);
                    const right_ty = try self.checkExpr(call.args[1], scope);
                    if (!isStringLikeType(left_ty) or !isStringLikeType(right_ty)) return TypeError.TypeMismatch;
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .boolean };
                    return ty;
                }
                if (std.mem.eql(u8, call.func_name, "format")) {
                    if (call.args.len == 0 or call.args[0].* != .literal or call.args[0].literal != .string_val) return TypeError.InvalidArgsCount;
                    for (call.args[1..]) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    return try self.makeStringType();
                }
                if (lowering_rules.isHashCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const arg_ty = try self.checkExpr(call.args[0], scope);
                    if (!self.typeIsHash(arg_ty)) return TypeError.TypeMismatch;
                    return try self.makeU64Type();
                }
                if (lowering_rules.isDebugCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const arg_ty = try self.checkExpr(call.args[0], scope);
                    if (!self.typeIsDebug(arg_ty)) return TypeError.TypeMismatch;
                    return try self.makeStringType();
                }
                if (lowering_rules.isPrintlnCall(call)) {
                    for (call.args) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = .void_type };
                    return ret;
                }

                if (lowering_rules.isPanicBuiltinName(call.func_name)) {
                    for (call.args) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = .void_type };
                    return ret;
                }

                if (std.mem.eql(u8, call.func_name, "std__panic__catch_unwind") or
                    (call.associated_target != null and std.mem.eql(u8, call.associated_target.?, "panic") and std.mem.eql(u8, call.func_name, "catch_unwind")))
                {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const closure_expr = call.args[0];
                    const closure_ty = try self.checkExpr(closure_expr, scope);
                    if (closure_ty.* != .closure or closure_ty.closure.params.len != 0) return TypeError.TypeMismatch;
                    if (closure_expr.* != .closure_literal or closure_expr.closure_literal.body.* != .call_expr) {
                        self.setError("catch_unwind currently only supports direct panic bodies", .{});
                        return TypeError.TypeMismatch;
                    }
                    const body_call = closure_expr.closure_literal.body.call_expr;
                    if (!lowering_rules.isPanicBuiltinName(body_call.func_name)) {
                        self.setError("catch_unwind currently only supports direct panic bodies", .{});
                        return TypeError.TypeMismatch;
                    }
                    return try self.makeResultType(try self.makeI32Type(), try self.makeI32Type());
                }

                if (scope.lookup(call.func_name)) |sym| {
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    if (sym.ty.* == .closure) {
                        const closure = sym.ty.closure;
                        if (closure.params.len != call.args.len) return TypeError.InvalidArgsCount;
                        for (closure.params, call.args) |param_ty, arg| {
                            const arg_ty = try self.checkExpr(arg, scope);
                            if (!self.plainCallArgMatches(param_ty, arg, arg_ty)) return TypeError.TypeMismatch;
                        }
                        return closure.ret;
                    }
                    if (sym.ty.* == .fn_ptr) {
                        const fn_ptr = sym.ty.fn_ptr;
                        if (fn_ptr.params.len != call.args.len) return TypeError.InvalidArgsCount;
                        for (fn_ptr.params, call.args) |param_ty, arg| {
                            const arg_ty = try self.checkExpr(arg, scope);
                            if (!self.plainCallArgMatches(param_ty, arg, arg_ty)) return TypeError.TypeMismatch;
                        }
                        self.fn_ptr_calls.put(expr, {}) catch return TypeError.OutOfMemory;
                        return fn_ptr.ret;
                    }
                }

                var module_alias_buf: [512]u8 = undefined;
                const module_local_name = if (self.current_function_namespace) |namespace|
                    std.fmt.bufPrint(&module_alias_buf, "{s}__{s}", .{ namespace, call.func_name }) catch null
                else
                    null;
                const resolved_func_name = if (module_local_name) |alias|
                    if (self.funcs.contains(alias) or self.imported_function_signatures.contains(alias)) alias else self.resolveFunctionAlias(call.func_name)
                else if (self.funcs.contains(call.func_name) or self.imported_function_signatures.contains(call.func_name))
                    call.func_name
                else
                    self.resolveFunctionAlias(call.func_name);
                if (self.funcs.get(resolved_func_name)) |func| {
                    try self.checkCallArgsAgainstFunc(func, call.args, scope, call.func_name, false);
                    if (!std.mem.eql(u8, resolved_func_name, call.func_name) or
                        self.resolveFunctionAliasMetadata(call.func_name) != null or
                        self.resolveFunctionAliasMetadata(resolved_func_name) != null)
                    {
                        try self.recordResolvedCallSymbol(expr, call.func_name, resolved_func_name);
                    }
                    if (func.is_async) {
                        return try self.makeFutureType(func.ret_ty);
                    }
                    return func.ret_ty;
                }

                if (self.imported_function_signatures.get(resolved_func_name)) |signature| {
                    try self.checkCallArgsAgainstSignature(signature.params, call.args, scope, call.func_name, false);
                    if (!std.mem.eql(u8, resolved_func_name, call.func_name) or
                        self.resolveFunctionAliasMetadata(call.func_name) != null or
                        self.resolveFunctionAliasMetadata(resolved_func_name) != null)
                    {
                        try self.recordResolvedCallSymbol(expr, call.func_name, resolved_func_name);
                    }
                    if (signature.is_async) return try self.makeFutureType(signature.ret_ty);
                    return signature.ret_ty;
                }

                if (self.structs.get(call.func_name)) |decl| {
                    if (decl.is_opaque) {
                        self.setError("cannot construct opaque type {s}", .{call.func_name});
                        return TypeError.NotAStruct;
                    }
                    if (decl.fields.len != call.args.len) return TypeError.InvalidArgsCount;
                    for (decl.fields, call.args) |field, arg| {
                        const arg_ty = try self.checkExpr(arg, scope);
                        if (!self.typesEqual(field.ty, unwrapBorrowForCallArg(arg, arg_ty))) return TypeError.TypeMismatch;
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .user_defined = .{ .name = decl.name, .generics = &.{} } };
                    return ret;
                }

                if (call.args.len > 0) {
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    if (optionInnerType(recv_ty)) |inner_ty| {
                        if (lowering_rules.isOptionQueryCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                        if (lowering_rules.isCopiedCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            if (inner_ty.* != .borrow) return TypeError.TypeMismatch;
                            return try self.makeOptionType(inner_ty.borrow);
                        }
                        if (lowering_rules.isMapCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const closure_ty = if (call.args[1].* == .closure_literal)
                                try self.checkClosureLiteralWithContext(call.args[1], scope, &.{inner_ty})
                            else
                                try self.checkExpr(call.args[1], scope);
                            if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                            if (closure_ty.closure.params.len != 1) return TypeError.InvalidArgsCount;
                            if (!self.typesEqual(closure_ty.closure.params[0], inner_ty)) return TypeError.TypeMismatch;
                            return try self.makeOptionType(closure_ty.closure.ret);
                        }
                        if (lowering_rules.isAndThenCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const closure_ty = if (call.args[1].* == .closure_literal)
                                try self.checkClosureLiteralWithContext(call.args[1], scope, &.{inner_ty})
                            else
                                try self.checkExpr(call.args[1], scope);
                            if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                            if (closure_ty.closure.params.len != 1) return TypeError.InvalidArgsCount;
                            if (!self.typesEqual(closure_ty.closure.params[0], inner_ty)) return TypeError.TypeMismatch;
                            if (optionInnerType(closure_ty.closure.ret) == null) return TypeError.TypeMismatch;
                            return closure_ty.closure.ret;
                        }
                        if (lowering_rules.isUnwrapCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return inner_ty;
                        }
                        if (lowering_rules.isUnwrapOrCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const default_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(inner_ty, default_ty)) return TypeError.TypeMismatch;
                            return inner_ty;
                        }
                        if (lowering_rules.isUnwrapOrElseCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const closure_ty = if (call.args[1].* == .closure_literal)
                                try self.checkClosureLiteralWithContext(call.args[1], scope, &.{})
                            else
                                try self.checkExpr(call.args[1], scope);
                            if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                            if (closure_ty.closure.params.len != 0) return TypeError.InvalidArgsCount;
                            if (!self.typesEqual(inner_ty, closure_ty.closure.ret)) return TypeError.TypeMismatch;
                            return inner_ty;
                        }
                        if (lowering_rules.isUnwrapOrDefaultCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return inner_ty;
                        }
                    }

                    if (resultOkType(recv_ty)) |ok_ty| {
                        if (lowering_rules.isResultQueryCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                        if (lowering_rules.isMapCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const err_ty = resultErrType(recv_ty) orelse return TypeError.TypeMismatch;
                            const closure_ty = if (call.args[1].* == .closure_literal)
                                try self.checkClosureLiteralWithContext(call.args[1], scope, &.{ok_ty})
                            else
                                try self.checkExpr(call.args[1], scope);
                            if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                            if (closure_ty.closure.params.len != 1) return TypeError.InvalidArgsCount;
                            if (!self.typesEqual(closure_ty.closure.params[0], ok_ty)) return TypeError.TypeMismatch;
                            return try self.makeResultType(closure_ty.closure.ret, err_ty);
                        }
                        if (lowering_rules.isUnwrapCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return ok_ty;
                        }
                        if (lowering_rules.isUnwrapOrCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const default_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(ok_ty, default_ty)) return TypeError.TypeMismatch;
                            return ok_ty;
                        }
                    }

                    if (isAtomicI32Type(recv_ty)) {
                        if (lowering_rules.isLoadCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const ordering_ty = try self.checkExpr(call.args[1], scope);
                            if (!isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            return try self.makeI32Type();
                        }
                        if (lowering_rules.isStoreCall(call)) {
                            if (call.args.len != 3) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            const ordering_ty = try self.checkExpr(call.args[2], scope);
                            if (!isNumericType(value_ty) or !isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            const ret = try self.allocator.create(ast.Type);
                            ret.* = .{ .primitive = .void_type };
                            return ret;
                        }
                        if (lowering_rules.isFetchAddCall(call)) {
                            if (call.args.len != 3) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            const ordering_ty = try self.checkExpr(call.args[2], scope);
                            if (!isNumericType(value_ty) or !isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            return try self.makeI32Type();
                        }
                        if (lowering_rules.isCompareExchangeCall(call)) {
                            if (call.args.len != 5) return TypeError.InvalidArgsCount;
                            const expected_ty = try self.checkExpr(call.args[1], scope);
                            const new_ty = try self.checkExpr(call.args[2], scope);
                            const success_ty = try self.checkExpr(call.args[3], scope);
                            const failure_ty = try self.checkExpr(call.args[4], scope);
                            if (!isNumericType(expected_ty) or !isNumericType(new_ty) or !isOrderingType(success_ty) or !isOrderingType(failure_ty)) return TypeError.TypeMismatch;
                            const i32_ty = try self.makeI32Type();
                            return try self.makeResultType(i32_ty, i32_ty);
                        }
                    }

                    if (isAtomicUsizeType(recv_ty)) {
                        if (lowering_rules.isLoadCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const ordering_ty = try self.checkExpr(call.args[1], scope);
                            if (!isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .usize };
                            return ty;
                        }
                        if (lowering_rules.isStoreCall(call)) {
                            if (call.args.len != 3) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            const ordering_ty = try self.checkExpr(call.args[2], scope);
                            if (!isNumericType(value_ty) or !isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            const ret = try self.allocator.create(ast.Type);
                            ret.* = .{ .primitive = .void_type };
                            return ret;
                        }
                        if (lowering_rules.isFetchAddCall(call)) {
                            if (call.args.len != 3) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            const ordering_ty = try self.checkExpr(call.args[2], scope);
                            if (!isNumericType(value_ty) or !isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .usize };
                            return ty;
                        }
                    }

                    if (cellInnerType(recv_ty)) |inner_ty| {
                        if (lowering_rules.isGetCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return inner_ty;
                        }
                        if (lowering_rules.isSetCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(inner_ty, value_ty)) {
                                self.setError("Cell::set type mismatch: cell tag={s}, value tag={s}", .{ @tagName(inner_ty.*), @tagName(value_ty.*) });
                                return TypeError.TypeMismatch;
                            }
                            const ret = try self.allocator.create(ast.Type);
                            ret.* = .{ .primitive = .void_type };
                            return ret;
                        }
                    }

                    if (refCellInnerType(recv_ty)) |inner_ty| {
                        if (std.mem.eql(u8, call.func_name, "borrow") or std.mem.eql(u8, call.func_name, "borrow_mut")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeBorrowType(inner_ty);
                        }
                    }

                    if (mutexInnerType(recv_ty)) |inner_ty| {
                        if (std.mem.eql(u8, call.func_name, "lock")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeResultType(try self.makeMutexGuardType(inner_ty), try self.makeI32Type());
                        }
                    }

                    if (rwLockInnerType(recv_ty)) |inner_ty| {
                        if (std.mem.eql(u8, call.func_name, "read")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeResultType(try self.makeRwLockReadGuardType(inner_ty), try self.makeI32Type());
                        }
                        if (std.mem.eql(u8, call.func_name, "write")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeResultType(try self.makeRwLockWriteGuardType(inner_ty), try self.makeI32Type());
                        }
                    }

                    if (isFileType(recv_ty)) {
                        if (std.mem.eql(u8, call.func_name, "as_raw_fd")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeI32Type();
                        }
                    }

                    if (isMetadataType(recv_ty)) {
                        if (std.mem.eql(u8, call.func_name, "is_file") or std.mem.eql(u8, call.func_name, "is_dir") or std.mem.eql(u8, call.func_name, "is_symlink")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                        if (std.mem.eql(u8, call.func_name, "modified_ms") or std.mem.eql(u8, call.func_name, "created_ms")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .i64 };
                            return ty;
                        }
                    }

                    if (lowering_rules.isMetadataCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (isStringLikeType(recv_ty)) {
                            return try self.makeResultType(try self.makeMetadataType(), try self.makeI32Type());
                        }
                    }

                    if (joinHandleInnerType(recv_ty)) |inner_ty| {
                        if (lowering_rules.isJoinCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeResultType(inner_ty, try self.makeI32Type());
                        }
                    }

                    if (senderInnerType(recv_ty)) |inner_ty| {
                        if (lowering_rules.isCloneCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return recv_ty;
                        }
                        if (lowering_rules.isSendCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(inner_ty, value_ty)) return TypeError.TypeMismatch;
                            const void_ty = try self.allocator.create(ast.Type);
                            void_ty.* = .{ .primitive = .void_type };
                            return try self.makeResultType(void_ty, try self.makeI32Type());
                        }
                    }

                    if (receiverInnerType(recv_ty)) |inner_ty| {
                        if (lowering_rules.isRecvCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeResultType(inner_ty, try self.makeI32Type());
                        }
                    }

                    if (rcInnerType(recv_ty) != null and lowering_rules.isCloneCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        return unwrappedReceiverType(recv_ty);
                    }

                    if (arcInnerType(recv_ty) != null and lowering_rules.isCloneCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        return unwrappedReceiverType(recv_ty);
                    }

                    if (atomicPtrInnerType(recv_ty)) |inner_ty| {
                        if (lowering_rules.isLoadCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const ordering_ty = try self.checkExpr(call.args[1], scope);
                            if (!isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            return try self.makePointerType(inner_ty);
                        }
                    }

                    if (vecDequeElementType(recv_ty)) |elem_ty| {
                        if (std.mem.eql(u8, call.func_name, "rotate_left")) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const count_ty = try self.checkExpr(call.args[1], scope);
                            if (!isNumericType(count_ty)) return TypeError.TypeMismatch;
                            const ret = try self.allocator.create(ast.Type);
                            ret.* = .{ .primitive = .void_type };
                            return ret;
                        }
                        if (lowering_rules.isPushBackCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(elem_ty, value_ty)) return TypeError.TypeMismatch;
                            if (elem_ty.* == .infer) {
                                if (rootIdentifier(call.args[0])) |recv_name| {
                                    if (scope.lookup(recv_name)) |sym| {
                                        const concrete_ty = try self.makeVecDequeType(value_ty);
                                        sym.ty = concrete_ty;
                                        self.expr_types.put(call.args[0], concrete_ty) catch return TypeError.OutOfMemory;
                                    }
                                }
                            }
                            const ret = try self.allocator.create(ast.Type);
                            ret.* = .{ .primitive = .void_type };
                            return ret;
                        }
                        if (lowering_rules.isPopFrontCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            if (elem_ty.* == .infer) return TypeError.TypeMismatch;
                            return try self.makeOptionType(elem_ty);
                        }
                    }

                    if (arrayType(recv_ty)) |arr| {
                        if (lowering_rules.isAsPtrCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makePointerType(arr.elem);
                        }
                        if (std.mem.eql(u8, call.func_name, "fill")) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(arr.elem, value_ty)) return TypeError.TypeMismatch;
                            const ret = try self.allocator.create(ast.Type);
                            ret.* = .{ .primitive = .void_type };
                            return ret;
                        }
                    }

                    if (isStringLikeType(recv_ty)) {
                        if (lowering_rules.isAsPtrCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makePointerType(try self.makeU8Type());
                        }
                        if (std.mem.eql(u8, call.func_name, "as_bytes") or std.mem.eql(u8, call.func_name, "bytes")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeSliceType(try self.makeU8Type());
                        }
                        if (std.mem.eql(u8, call.func_name, "try_exists") or
                            std.mem.eql(u8, call.func_name, "is_file") or
                            std.mem.eql(u8, call.func_name, "is_dir") or
                            std.mem.eql(u8, call.func_name, "is_symlink"))
                        {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                    }

                    if (sliceElementType(recv_ty)) |elem_ty| {
                        if (lowering_rules.isAsPtrCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makePointerType(elem_ty);
                        }
                    }

                    if (recv_ty.* == .pointer and std.mem.eql(u8, call.func_name, "add")) {
                        if (call.args.len != 2) return TypeError.InvalidArgsCount;
                        const index_ty = try self.checkExpr(call.args[1], scope);
                        if (!isAnyIntegerType(index_ty)) return TypeError.TypeMismatch;
                        return recv_ty;
                    }

                    if (hashMapTypes(recv_ty)) |hm| {
                        if (lowering_rules.isInsertCall(call)) {
                            if (call.args.len != 3) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            const value_ty = try self.checkExpr(call.args[2], scope);
                            if (!self.typesEqual(hm.key, key_ty) or !self.typesEqual(hm.value, value_ty)) return TypeError.TypeMismatch;
                            if (rootIdentifier(call.args[0])) |recv_name| {
                                if (scope.lookup(recv_name)) |sym| {
                                    if (hm.key.* == .infer or hm.value.* == .infer) {
                                        const concrete_ty = try self.makeHashMapType(key_ty, value_ty);
                                        sym.ty = concrete_ty;
                                        self.expr_types.put(call.args[0], concrete_ty) catch return TypeError.OutOfMemory;
                                    }
                                }
                            }
                            return try self.makeOptionType(value_ty);
                        }
                        if (lowering_rules.isGetCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(hm.key, key_ty)) return TypeError.TypeMismatch;
                            return try self.makeOptionType(try self.makeBorrowType(hm.value));
                        }
                    }

                    if (hashSetTypes(recv_ty)) |hs| {
                        if (lowering_rules.isInsertCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(hs.key, key_ty)) return TypeError.TypeMismatch;
                            if (rootIdentifier(call.args[0])) |recv_name| {
                                if (scope.lookup(recv_name)) |sym| {
                                    if (hs.key.* == .infer) {
                                        const concrete_ty = try self.makeHashSetType(key_ty);
                                        sym.ty = concrete_ty;
                                        self.expr_types.put(call.args[0], concrete_ty) catch return TypeError.OutOfMemory;
                                    }
                                }
                            }
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                        if (lowering_rules.isContainsCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(hs.key, key_ty)) return TypeError.TypeMismatch;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                    }

                    if (btreeMapTypes(recv_ty)) |bm| {
                        if (lowering_rules.isInsertCall(call)) {
                            if (call.args.len != 3) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            const value_ty = try self.checkExpr(call.args[2], scope);
                            if (!self.typesEqual(bm.key, key_ty) or !self.typesEqual(bm.value, value_ty)) return TypeError.TypeMismatch;
                            if (rootIdentifier(call.args[0])) |recv_name| {
                                if (scope.lookup(recv_name)) |sym| {
                                    if (bm.key.* == .infer or bm.value.* == .infer) {
                                        const concrete_ty = try self.makeBTreeMapType(key_ty, value_ty);
                                        sym.ty = concrete_ty;
                                        self.expr_types.put(call.args[0], concrete_ty) catch return TypeError.OutOfMemory;
                                    }
                                }
                            }
                            return try self.makeOptionType(value_ty);
                        }
                        if (lowering_rules.isGetCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(bm.key, key_ty)) return TypeError.TypeMismatch;
                            return try self.makeOptionType(try self.makeBorrowType(bm.value));
                        }
                    }

                    if (btreeSetTypes(recv_ty)) |bs| {
                        if (lowering_rules.isInsertCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(bs.key, key_ty)) return TypeError.TypeMismatch;
                            if (rootIdentifier(call.args[0])) |recv_name| {
                                if (scope.lookup(recv_name)) |sym| {
                                    if (bs.key.* == .infer) {
                                        const concrete_ty = try self.makeBTreeSetType(key_ty);
                                        sym.ty = concrete_ty;
                                        self.expr_types.put(call.args[0], concrete_ty) catch return TypeError.OutOfMemory;
                                    }
                                }
                            }
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                        if (lowering_rules.isContainsCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(bs.key, key_ty)) return TypeError.TypeMismatch;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                    }

                    if (dynDispatchTraitName(recv_ty)) |trait_name| {
                        if (self.findTraitMethod(trait_name, call.func_name)) |method| {
                            if (method.params.len != call.args.len) return TypeError.InvalidArgsCount;
                            for (method.params[1..], call.args[1..]) |param, arg| {
                                const arg_ty = try self.checkExpr(arg, scope);
                                if (!self.typesEqual(param.ty, unwrapBorrowForCallArg(arg, arg_ty))) {
                                    self.setError("dyn method {s} argument mismatch: param tag={s}, arg tag={s}", .{ call.func_name, @tagName(param.ty.*), @tagName(arg_ty.*) });
                                    return TypeError.TypeMismatch;
                                }
                            }
                            self.dyn_call_traits.put(expr, trait_name) catch return TypeError.OutOfMemory;
                            return method.ret_ty;
                        }
                    }
                }

                if (std.mem.eql(u8, call.func_name, "push")) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = vecElementType(recv_ty) orelse return TypeError.TypeMismatch;
                    const arg_ty = try self.checkExpr(call.args[1], scope);
                    if (!self.typesEqual(elem_ty, arg_ty)) return TypeError.TypeMismatch;
                    if (elem_ty.* == .infer) {
                        if (rootIdentifier(call.args[0])) |recv_name| {
                            if (scope.lookup(recv_name)) |sym| {
                                const concrete_ty = try self.makeVecType(arg_ty);
                                sym.ty = concrete_ty;
                                self.expr_types.put(call.args[0], concrete_ty) catch return TypeError.OutOfMemory;
                            }
                        }
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = .void_type };
                    return ret;
                }

                if (std.mem.eql(u8, call.func_name, "pop")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = vecElementType(recv_ty) orelse return TypeError.TypeMismatch;
                    if (elem_ty.* == .infer) return TypeError.TypeMismatch;
                    return try self.makeOptionType(elem_ty);
                }

                if (lowering_rules.isRemoveCall(call)) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = vecElementType(recv_ty) orelse return TypeError.TypeMismatch;
                    const index_ty = try self.checkExpr(call.args[1], scope);
                    if (!isNumericType(index_ty)) return TypeError.TypeMismatch;
                    if (elem_ty.* == .infer) return TypeError.TypeMismatch;
                    return elem_ty;
                }

                // 1. Check Sla internal function calls
                const method_match = blk: {
                    if (call.args.len == 0) break :blk null;
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    const curr = lowering_rules.peelBorrowPointerType(recv_ty);
                    if (curr.* != .user_defined) break :blk null;
                    var method_buf: [256]u8 = undefined;
                    break :blk std.fmt.bufPrint(&method_buf, "{s}_{s}", .{ curr.user_defined.name, call.func_name }) catch null;
                };

                if (method_match) |method_name| {
                    if (self.funcs.get(method_name)) |func| {
                        try self.checkCallArgsAgainstFunc(func, call.args, scope, call.func_name, true);
                        const resolved = std.fmt.allocPrint(self.allocator, "{s}", .{method_name}) catch return TypeError.OutOfMemory;
                        self.resolved_call_symbols.put(expr, resolved) catch return TypeError.OutOfMemory;
                        if (func.is_async) {
                            return try self.makeFutureType(func.ret_ty);
                        }
                        return func.ret_ty;
                    }
                    if (self.imported_function_signatures.get(method_name)) |signature| {
                        try self.checkCallArgsAgainstSignature(signature.params, call.args, scope, call.func_name, true);
                        const resolved = std.fmt.allocPrint(self.allocator, "{s}", .{method_name}) catch return TypeError.OutOfMemory;
                        self.resolved_call_symbols.put(expr, resolved) catch return TypeError.OutOfMemory;
                        if (signature.is_async) return try self.makeFutureType(signature.ret_ty);
                        return signature.ret_ty;
                    }
                }

                if (call.args.len > 0) {
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    if (concreteTypeName(recv_ty)) |type_name| {
                        if (try self.resolveTraitMethodSymbolForType(type_name, null, call.func_name, call.args.len)) |symbol| {
                            if (try self.checkStaticCallBySymbol(expr, symbol, call.args, scope, call.func_name, true)) |ret_ty| return ret_ty;
                            return TypeError.UndefinedVariable;
                        }
                    }
                }

                if (lowering_rules.isIterOrIntoIterCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const target_ty = try self.checkExpr(call.args[0], scope);
                    if (arrayType(target_ty) == null and vecElementType(target_ty) == null and sliceElementType(target_ty) == null) return TypeError.TypeMismatch;
                    return target_ty;
                }

                if (lowering_rules.isCopiedCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const target_ty = try self.checkExpr(call.args[0], scope);
                    if (arrayType(target_ty) == null and vecElementType(target_ty) == null and sliceElementType(target_ty) == null) return TypeError.TypeMismatch;
                    return target_ty;
                }

                if (std.mem.eql(u8, call.func_name, "collect")) {
                    if (call.args.len != 1 or call.generics.len != 1) return TypeError.InvalidArgsCount;
                    if (!isStringType(call.generics[0])) return TypeError.TypeMismatch;
                    const target_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = iterableElementType(target_ty) orelse return TypeError.TypeMismatch;
                    if (!isPrimitiveType(elem_ty, .u8)) return TypeError.TypeMismatch;
                    return try self.makeStringType();
                }

                if (lowering_rules.isJoinCall(call)) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const target_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = iterableElementType(target_ty) orelse return TypeError.TypeMismatch;
                    if (!isStringLikeType(elem_ty) and !isStringType(elem_ty)) return TypeError.TypeMismatch;
                    const sep_ty = try self.checkExpr(call.args[1], scope);
                    if (!isStringLikeType(sep_ty) and !isStringType(sep_ty)) return TypeError.TypeMismatch;
                    return try self.makeStringType();
                }

                if (lowering_rules.isMapCall(call)) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const source_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = if (arrayType(source_ty)) |arr| arr.elem else vecElementType(source_ty) orelse return TypeError.TypeMismatch;
                    const closure_ty = if (call.args[1].* == .closure_literal)
                        try self.checkClosureLiteralWithContext(call.args[1], scope, &.{elem_ty})
                    else
                        try self.checkExpr(call.args[1], scope);
                    if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                    if (closure_ty.closure.params.len != 1) return TypeError.InvalidArgsCount;
                    if (!self.typesEqual(closure_ty.closure.params[0], elem_ty)) return TypeError.TypeMismatch;
                    if (arrayType(source_ty)) |arr| {
                        const ty = try self.allocator.create(ast.Type);
                        ty.* = .{ .array = .{ .elem = closure_ty.closure.ret, .len = arr.len } };
                        return ty;
                    }
                    const generics = try self.allocator.alloc(*ast.Type, 1);
                    generics[0] = closure_ty.closure.ret;
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .user_defined = .{ .name = "Vec", .generics = generics } };
                    return ty;
                }

                if (std.mem.eql(u8, call.func_name, "filter")) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const source_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = if (arrayType(source_ty)) |arr| arr.elem else vecElementType(source_ty) orelse return TypeError.TypeMismatch;
                    const closure_ty = if (call.args[1].* == .closure_literal)
                        try self.checkClosureLiteralWithContext(call.args[1], scope, &.{elem_ty})
                    else
                        try self.checkExpr(call.args[1], scope);
                    if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                    if (closure_ty.closure.params.len != 1) return TypeError.InvalidArgsCount;
                    if (!self.typesEqual(closure_ty.closure.params[0], elem_ty)) return TypeError.TypeMismatch;
                    if (closure_ty.closure.ret.* != .primitive or closure_ty.closure.ret.primitive != .boolean) return TypeError.TypeMismatch;
                    return source_ty;
                }

                if (std.mem.eql(u8, call.func_name, "fold")) {
                    if (call.args.len != 3) return TypeError.InvalidArgsCount;
                    const source_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = if (arrayType(source_ty)) |arr| arr.elem else vecElementType(source_ty) orelse return TypeError.TypeMismatch;
                    const init_ty = try self.checkExpr(call.args[1], scope);
                    const closure_ty = if (call.args[2].* == .closure_literal)
                        try self.checkClosureLiteralWithContext(call.args[2], scope, &.{ init_ty, elem_ty })
                    else
                        try self.checkExpr(call.args[2], scope);
                    if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                    if (closure_ty.closure.params.len != 2) return TypeError.InvalidArgsCount;
                    const acc_ty = closure_ty.closure.params[0];
                    if (!self.typesEqual(acc_ty, init_ty)) return TypeError.TypeMismatch;
                    if (!self.typesEqual(closure_ty.closure.params[1], elem_ty)) return TypeError.TypeMismatch;
                    if (!self.typesEqual(closure_ty.closure.ret, acc_ty)) return TypeError.TypeMismatch;
                    return acc_ty;
                }

                if (std.mem.eql(u8, call.func_name, "sum")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const target_ty = try self.checkExpr(call.args[0], scope);
                    if (arrayType(target_ty)) |arr| {
                        const ret = try self.allocator.create(ast.Type);
                        ret.* = arr.elem.*;
                        return ret;
                    }
                    if (sliceElementType(target_ty)) |elem_ty| {
                        return elem_ty;
                    }
                    if (vecElementType(target_ty)) |elem_ty| {
                        return elem_ty;
                    }
                    return TypeError.TypeMismatch;
                }

                // 2. Check FFI functions
                if (self.extern_funcs.get(call.func_name)) |ext| {
                    if (ext.params.len != call.args.len) return TypeError.InvalidArgsCount;
                    for (ext.params, call.args) |param, arg| {
                        const arg_ty = try self.checkExpr(arg, scope);
                        _ = arg_ty; // bypass signature checks for FFI pointers
                        try self.consumeExternMoveArg(scope, param, arg);
                    }
                    const ret = try self.allocator.create(ast.Type);
                    setTypeFromAbiReturn(self.allocator, ret, ext.ret_ty);
                    return ret;
                }

                // 3. Check if it's a built-in: stack_alloc, panic
                if (std.mem.eql(u8, call.func_name, "stack_alloc") or
                    lowering_rules.isPanicBuiltinName(call.func_name))
                {
                    for (call.args) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = if (std.mem.eql(u8, call.func_name, "stack_alloc")) .raw_ptr else .void_type };
                    return ret;
                }

                // 4. Check user-defined macro calls
                if (self.macros.get(call.func_name)) |mac| {
                    for (call.args) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    var propagated_args = std.StringHashMap(void).init(self.allocator);
                    defer propagated_args.deinit();
                    const has_macro_try = try self.macroHasTry(mac);
                    for (mac.params, call.args, 0..) |_, arg, index| {
                        if (!try self.macroParamIsTrySource(mac, index)) continue;
                        if (rootIdentifier(arg)) |name| try propagated_args.put(name, {});
                    }
                    if (has_macro_try) {
                        var cleanup = std.ArrayList([]const u8).init(self.allocator);
                        errdefer cleanup.deinit();
                        var current: ?*Scope = scope;
                        while (current) |frame| {
                            var symbols = frame.symbols.valueIterator();
                            while (symbols.next()) |sym| {
                                if (sym.state != .active or isInternalSymbol(sym.name) or propagated_args.contains(sym.name)) continue;
                                try cleanup.append(sym.name);
                            }
                            current = frame.parent;
                        }
                        try self.macro_call_try_cleanups.put(&expr.call_expr, cleanup);
                    }
                    for (mac.params, call.args, 0..) |_, arg, index| {
                        const consumption = try self.macroParamConsumption(mac, index);
                        if (consumption == .never) continue;
                        if (consumption == .conditional) {
                            self.setError("MacroConditionalConsume: macro `{s}` consumes parameter `{s}` only on some control-flow paths", .{ call.func_name, mac.params[index] });
                            return TypeError.CompileError;
                        }
                        if (arg.* != .identifier) continue;
                        const sym = scope.lookup(arg.identifier) orelse return TypeError.UndefinedVariable;
                        if (sym.state == .consumed) return TypeError.UseAfterMove;
                        try self.consumeBinding(scope, arg.identifier, sym, "user macro move");
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = .void_type };
                    return ret;
                }

                if (self.imported_macros.get(call.func_name)) |macro| {
                    for (call.args) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    if (call.args.len == macro.arity) {
                        const ret = try self.allocator.create(ast.Type);
                        ret.* = .{ .primitive = .void_type };
                        return ret;
                    }
                    if (lowering_rules.importedMacroUsesExpressionOutput(macro, call.args.len)) {
                        if (lowering_rules.importedMacroExpressionResultKind(call.func_name)) |kind| {
                            return try self.makeImportedMacroExpressionResultType(kind);
                        }
                        return try self.makeInferType();
                    }
                    self.setError("macro {s} expects {} args or {} args when using expression output, got {}", .{ call.func_name, macro.arity, macro.arity - 1, call.args.len });
                    return TypeError.InvalidArgsCount;
                }

                if (call.associated_target) |target_name| {
                    if (std.mem.eql(u8, target_name, "str") and std.mem.eql(u8, call.func_name, "from_utf8")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const bytes_ty = try self.checkExpr(call.args[0], scope);
                        const slice_elem = sliceElementType(bytes_ty) orelse {
                            if (call.args[0].* == .borrow_expr) {
                                const borrowed_ty = try self.checkExpr(call.args[0].borrow_expr.expr, scope);
                                const borrowed_arr = arrayType(borrowed_ty) orelse return TypeError.TypeMismatch;
                                if (!isPrimitiveType(borrowed_arr.elem, .u8)) return TypeError.TypeMismatch;
                                self.array_to_slice_borrow_args.put(call.args[0], {}) catch return TypeError.OutOfMemory;
                                return try self.makeResultType(try self.makeStringType(), try self.makeI32Type());
                            }
                            return TypeError.TypeMismatch;
                        };
                        if (!isPrimitiveType(slice_elem, .u8)) return TypeError.TypeMismatch;
                        return try self.makeResultType(try self.makeStringType(), try self.makeI32Type());
                    }
                }

                self.setError("Undefined call: {s}", .{call.func_name});
                if (call.args.len > 0) {
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    const curr = lowering_rules.peelBorrowPointerType(recv_ty);
                    if (curr.* == .user_defined) {
                        var method_buf: [256]u8 = undefined;
                        const method_key = std.fmt.bufPrint(&method_buf, "{s}_{s}", .{ curr.user_defined.name, call.func_name }) catch null;
                        if (method_key) |mk| {
                            if (self.funcs.get(mk)) |func| {
                                if (func.params.len != call.args.len) return TypeError.InvalidArgsCount;
                                for (func.params, call.args) |param, arg| {
                                    if (param.is_move and arg.* != .move_expr) {
                                        self.setError("Call to {s} requires move argument for parameter {s}", .{ call.func_name, param.name });
                                        return TypeError.TypeMismatch;
                                    }
                                    if (param.is_borrow) {
                                        if (dynTraitName(param.ty)) |trait_name| {
                                            const arg_ty = try self.checkExpr(arg, scope);
                                            if (dynDispatchTraitName(arg_ty)) |arg_trait_name| {
                                                if (!self.traitExtendsTrait(arg_trait_name, trait_name)) {
                                                    self.setError("Type does not implement trait {s} for parameter {s}", .{ trait_name, param.name });
                                                    return TypeError.TypeMismatch;
                                                }
                                                continue;
                                            }
                                            const concrete_ty = switch (arg_ty.*) {
                                                .borrow => |inner| inner,
                                                else => null,
                                            } orelse {
                                                self.setError("Call to {s} requires dyn borrow for parameter {s}", .{ call.func_name, param.name });
                                                return TypeError.TypeMismatch;
                                            };
                                            if (!self.typeImplementsTrait(concrete_ty, trait_name)) {
                                                self.setError("Type does not implement trait {s} for parameter {s}", .{ trait_name, param.name });
                                                return TypeError.TypeMismatch;
                                            }
                                            self.dyn_borrow_args.put(arg, trait_name) catch return TypeError.OutOfMemory;
                                            continue;
                                        }
                                    }
                                    if (param.is_borrow and arg.* != .borrow_expr) {
                                        const arg_ty = try self.checkExpr(arg, scope);
                                        if (dynTraitName(param.ty)) |target_trait| {
                                            if (dynDispatchTraitName(arg_ty)) |arg_trait_name| {
                                                if (!self.traitExtendsTrait(arg_trait_name, target_trait)) {
                                                    self.setError("Type does not implement trait {s} for parameter {s}", .{ target_trait, param.name });
                                                    return TypeError.TypeMismatch;
                                                }
                                                continue;
                                            }
                                        }
                                        if (arg_ty.* != .borrow or !self.typesEqual(param.ty, arg_ty.borrow)) {
                                            self.setError("Call to {s} requires borrow argument for parameter {s}", .{ call.func_name, param.name });
                                            return TypeError.TypeMismatch;
                                        }
                                        continue;
                                    }
                                    if (!param.is_move and !param.is_borrow and arg.* == .move_expr) {
                                        self.setError("Call to {s} passes capability argument to plain parameter {s}", .{ call.func_name, param.name });
                                        return TypeError.TypeMismatch;
                                    }
                                    const arg_ty = try self.checkExpr(arg, scope);
                                    if (!self.plainCallArgMatches(param.ty, arg, arg_ty)) return TypeError.TypeMismatch;
                                }
                                if (func.is_async) return try self.makeFutureType(func.ret_ty);
                                return func.ret_ty;
                            }
                        }
                    }
                }

                // If not found anywhere, undefined function call
                return TypeError.UndefinedVariable;
            },
            .if_expr => |*ife| {
                if (ife.let_chain) |chain| {
                    var saved_states = try self.saveScopeStates(scope);
                    defer saved_states.deinit();

                    const chain_scope = try Scope.init(self.allocator, scope);
                    try self.scope_pool.append(chain_scope);

                    for (chain) |cond| {
                        const value_ty = try self.checkExpr(cond.value, chain_scope);
                        try self.definePatternBindings(chain_scope, cond.pattern, value_ty, "if let", true);
                    }

                    try self.checkBlock(ife.then_block, chain_scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);

                    var then_states = try self.saveScopeStates(scope);
                    defer then_states.deinit();
                    self.restoreScopeStates(scope, &saved_states);

                    if (ife.else_block) |eb| {
                        try self.checkBlock(eb, scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);
                    }

                    const merge_action = control_flow_rules.planBranchStateMerge(
                        blockTerminates(ife.then_block),
                        if (ife.else_block) |eb| blockTerminates(eb) else false,
                    );
                    switch (merge_action) {
                        .restore_pre => self.restoreScopeStates(scope, &saved_states),
                        .restore_then => self.restoreScopeStates(scope, &then_states),
                        .restore_else => {},
                        .keep_current => {
                            var curr: ?*Scope = scope;
                            while (curr) |s| {
                                var iter = s.symbols.iterator();
                                while (iter.next()) |entry| {
                                    const name = entry.key_ptr.*;
                                    if (isInternalSymbol(name)) continue;
                                    const else_state = entry.value_ptr.state;
                                    const then_state = then_states.get(name) orelse .active;

                                    if (then_state != else_state) {
                                        if (then_state == .uninitialized or else_state == .uninitialized) {
                                            entry.value_ptr.state = .uninitialized;
                                            continue;
                                        }
                                        entry.value_ptr.state = .consumed;
                                        if (then_state == .active) {
                                            if (ife.then_block.len > 0) {
                                                const last = ife.then_block[ife.then_block.len - 1];
                                                var list = self.phi_cleanups.get(last) orelse std.ArrayList([]const u8).init(self.allocator);
                                                try list.append(name);
                                                try self.phi_cleanups.put(last, list);
                                            }
                                        } else if (ife.else_block) |eb| {
                                            if (eb.len > 0) {
                                                const last = eb[eb.len - 1];
                                                var list = self.phi_cleanups.get(last) orelse std.ArrayList([]const u8).init(self.allocator);
                                                try list.append(name);
                                                try self.phi_cleanups.put(last, list);
                                            }
                                        }
                                    }
                                }
                                curr = s.parent;
                            }
                        },
                    }

                    const then_ty = self.blockTailExprType(ife.then_block);
                    if (ife.else_block) |eb| {
                        const else_ty = self.blockTailExprType(eb);
                        if (then_ty == null or else_ty == null) {
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .void_type };
                            return ty;
                        }
                        if (!self.typesEqual(then_ty.?, else_ty.?)) {
                            self.setError("if expression branch type mismatch", .{});
                            return TypeError.TypeMismatch;
                        }
                        return then_ty.?;
                    }

                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .void_type };
                    return ty;
                }

                const cond_ty = try self.checkExpr(ife.cond, scope);
                // Comparisons produce integers (0/1) in SA; booleans are also fine.
                if (cond_ty.* == .infer) {
                    // Macro parameter condition; the call site supplies the concrete type.
                } else if (cond_ty.* != .primitive) {
                    return TypeError.TypeMismatch;
                } else switch (cond_ty.primitive) {
                    .boolean, .integer => {},
                    else => return TypeError.TypeMismatch,
                }

                // For branching, save active symbols and states
                var saved_states = std.StringHashMap(ValueState).init(self.allocator);
                defer saved_states.deinit();

                var curr: ?*Scope = scope;
                while (curr) |s| {
                    var iter = s.symbols.iterator();
                    while (iter.next()) |entry| {
                        try saved_states.put(entry.key_ptr.*, entry.value_ptr.state);
                    }
                    curr = s.parent;
                }

                // Check then_block
                try self.checkBlock(ife.then_block, scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);

                // Collect states after then_block
                var then_states = std.StringHashMap(ValueState).init(self.allocator);
                defer then_states.deinit();
                curr = scope;
                while (curr) |s| {
                    var iter = s.symbols.iterator();
                    while (iter.next()) |entry| {
                        try then_states.put(entry.key_ptr.*, entry.value_ptr.state);
                    }
                    curr = s.parent;
                }

                // Restore scope state for else_block check
                curr = scope;
                while (curr) |s| {
                    var iter = s.symbols.iterator();
                    while (iter.next()) |entry| {
                        if (saved_states.get(entry.key_ptr.*)) |st| {
                            entry.value_ptr.state = st;
                        }
                    }
                    curr = s.parent;
                }

                // Check else_block
                if (ife.else_block) |eb| {
                    try self.checkBlock(eb, scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);
                }

                const merge_action = control_flow_rules.planBranchStateMerge(
                    blockTerminates(ife.then_block),
                    if (ife.else_block) |eb| blockTerminates(eb) else false,
                );
                switch (merge_action) {
                    .restore_pre => self.restoreScopeStates(scope, &saved_states),
                    .restore_then => self.restoreScopeStates(scope, &then_states),
                    .restore_else => {},
                    .keep_current => {
                        // Re-align states at merge point (Phi Resolution).
                        // If a variable is active in one branch but consumed in another,
                        // release it in the active branch.
                        curr = scope;
                        while (curr) |s| {
                            var iter = s.symbols.iterator();
                            while (iter.next()) |entry| {
                                const name = entry.key_ptr.*;
                                if (isInternalSymbol(name)) continue;
                                const else_state = entry.value_ptr.state;
                                const then_state = then_states.get(name) orelse .active;

                                if (then_state != else_state) {
                                    if (then_state == .uninitialized or else_state == .uninitialized) {
                                        entry.value_ptr.state = .uninitialized;
                                        continue;
                                    }
                                    entry.value_ptr.state = .consumed;

                                    if (then_state == .active) {
                                        if (ife.then_block.len > 0) {
                                            const last = ife.then_block[ife.then_block.len - 1];
                                            var list = self.phi_cleanups.get(last) orelse std.ArrayList([]const u8).init(self.allocator);
                                            try list.append(name);
                                            try self.phi_cleanups.put(last, list);
                                        }
                                    } else if (ife.else_block) |eb| {
                                        if (eb.len > 0) {
                                            const last = eb[eb.len - 1];
                                            var list = self.phi_cleanups.get(last) orelse std.ArrayList([]const u8).init(self.allocator);
                                            try list.append(name);
                                            try self.phi_cleanups.put(last, list);
                                        }
                                    }
                                }
                            }
                            curr = s.parent;
                        }
                    },
                }

                const then_ty = self.blockTailExprType(ife.then_block);
                if (ife.else_block) |eb| {
                    const else_ty = self.blockTailExprType(eb);
                    if (then_ty == null or else_ty == null) {
                        const ty = try self.allocator.create(ast.Type);
                        ty.* = .{ .primitive = .void_type };
                        return ty;
                    }
                    if (!self.typesEqual(then_ty.?, else_ty.?)) {
                        self.setError("if expression branch type mismatch", .{});
                        return TypeError.TypeMismatch;
                    }
                    return then_ty.?;
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .primitive = .void_type };
                return ty;
            },
            .switch_expr => |*swe| {
                const val_ty = try self.checkExpr(swe.val, scope);
                _ = val_ty;

                var saved_states = try self.saveScopeStates(scope);
                defer saved_states.deinit();
                var live_states = std.ArrayList(std.StringHashMap(ValueState)).init(self.allocator);
                defer {
                    for (live_states.items) |*states| states.deinit();
                    live_states.deinit();
                }
                var live_bodies = std.ArrayList([]const *ast.Node).init(self.allocator);
                defer live_bodies.deinit();

                for (swe.cases) |case| {
                    self.restoreScopeStates(scope, &saved_states);
                    try self.checkBlock(case.body, scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);
                    if (!blockTerminates(case.body)) {
                        var states = try self.saveScopeStates(scope);
                        errdefer states.deinit();
                        try live_bodies.append(case.body);
                        try live_states.append(states);
                    }
                }
                try self.mergeMultiBranchScopeStates(scope, &saved_states, live_states.items, live_bodies.items);

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .primitive = .void_type };
                return ty;
            },
            .match_expr => |*mat| {
                var val_ty = try self.checkExpr(mat.val, scope);
                if (val_ty.* == .infer and mat.cases.len != 0) {
                    const first_pattern = mat.cases[0].pattern;
                    const inferred = if (std.mem.eql(u8, first_pattern.enum_name, "Option") or
                        std.mem.eql(u8, first_pattern.variant_name, "Some") or
                        std.mem.eql(u8, first_pattern.variant_name, "None"))
                        try self.makeOptionType(try self.makeInferType())
                    else if (std.mem.eql(u8, first_pattern.enum_name, "Result") or
                        std.mem.eql(u8, first_pattern.variant_name, "Ok") or
                        std.mem.eql(u8, first_pattern.variant_name, "Err"))
                        try self.makeResultType(try self.makeInferType(), try self.makeInferType())
                    else blk: {
                        const enum_decl = self.enums.get(first_pattern.enum_name) orelse return TypeError.TypeMismatch;
                        const ty = try self.allocator.create(ast.Type);
                        ty.* = .{ .user_defined = .{ .name = enum_decl.name, .generics = &.{} } };
                        break :blk ty;
                    };
                    if (mat.val.* == .identifier) {
                        const sym = scope.lookup(mat.val.identifier) orelse return TypeError.UndefinedVariable;
                        sym.ty = inferred;
                    }
                    self.expr_types.put(mat.val, inferred) catch return TypeError.OutOfMemory;
                    val_ty = inferred;
                }
                if (optionInnerType(val_ty) != null or resultOkType(val_ty) != null) {
                    var saved_states = try self.saveScopeStates(scope);
                    defer saved_states.deinit();
                    var live_states = std.ArrayList(std.StringHashMap(ValueState)).init(self.allocator);
                    defer {
                        for (live_states.items) |*states| states.deinit();
                        live_states.deinit();
                    }
                    var live_bodies = std.ArrayList([]const *ast.Node).init(self.allocator);
                    defer live_bodies.deinit();

                    var result_ty: ?*ast.Type = null;
                    var has_value_cases = true;
                    for (mat.cases) |case| {
                        self.restoreScopeStates(scope, &saved_states);

                        const pattern_scope = try Scope.init(self.allocator, scope);
                        try self.scope_pool.append(pattern_scope);
                        const binding_ty = try self.patternBindingType(case.pattern, val_ty, "match");
                        if (binding_ty) |ty| {
                            try self.defineSymbol(pattern_scope, case.pattern.bindings[0], ty, true);
                        }
                        if (case.guard) |guard| {
                            const guard_ty = try self.checkExpr(guard, pattern_scope);
                            if (guard_ty.* != .primitive) return TypeError.TypeMismatch;
                            switch (guard_ty.primitive) {
                                .boolean, .integer => {},
                                else => return TypeError.TypeMismatch,
                            }
                        }

                        try self.checkBlock(case.body, pattern_scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);
                        const terminated = blockTerminates(case.body);
                        if (!terminated) {
                            var states = try self.saveScopeStates(scope);
                            errdefer states.deinit();
                            try live_bodies.append(case.body);
                            try live_states.append(states);
                        }
                        if (self.blockTailExprType(case.body)) |case_ty| {
                            if (terminated) continue;
                            if (result_ty) |existing| {
                                if (!self.typesEqual(existing, case_ty)) return TypeError.TypeMismatch;
                            } else {
                                result_ty = case_ty;
                            }
                        } else if (!terminated) {
                            has_value_cases = false;
                        }
                    }

                    try self.mergeMultiBranchScopeStates(scope, &saved_states, live_states.items, live_bodies.items);

                    if (has_value_cases) {
                        if (result_ty) |ty| return ty;
                    }
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .void_type };
                    return ty;
                }

                if (val_ty.* != .user_defined) return TypeError.TypeMismatch;
                const decl = self.enums.get(val_ty.user_defined.name) orelse return TypeError.NotAStruct;

                var saved_states = try self.saveScopeStates(scope);
                defer saved_states.deinit();
                var live_states = std.ArrayList(std.StringHashMap(ValueState)).init(self.allocator);
                defer {
                    for (live_states.items) |*states| states.deinit();
                    live_states.deinit();
                }
                var live_bodies = std.ArrayList([]const *ast.Node).init(self.allocator);
                defer live_bodies.deinit();

                var result_ty: ?*ast.Type = null;
                var has_value_cases = true;
                for (mat.cases) |case| {
                    self.restoreScopeStates(scope, &saved_states);

                    if (!enumNameMatchesDecl(case.pattern.enum_name, decl.name)) return TypeError.TypeMismatch;
                    const variant = findEnumVariant(decl, case.pattern.variant_name) orelse return TypeError.FieldNotFound;
                    if (case.pattern.bindings.len != variant.fields.len) return TypeError.InvalidArgsCount;

                    const pattern_scope = try Scope.init(self.allocator, scope);
                    try self.scope_pool.append(pattern_scope);
                    for (case.pattern.bindings, variant.fields) |binding, field| {
                        try self.defineSymbol(pattern_scope, binding, field.ty, true);
                    }
                    if (case.guard) |guard| {
                        const guard_ty = try self.checkExpr(guard, pattern_scope);
                        if (guard_ty.* != .primitive) return TypeError.TypeMismatch;
                        switch (guard_ty.primitive) {
                            .boolean, .integer => {},
                            else => return TypeError.TypeMismatch,
                        }
                    }
                    try self.checkBlock(case.body, pattern_scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);

                    const terminated = blockTerminates(case.body);
                    if (!terminated) {
                        var states = try self.saveScopeStates(scope);
                        errdefer states.deinit();
                        try live_bodies.append(case.body);
                        try live_states.append(states);
                    }
                    const case_ty = self.blockTailExprType(case.body);
                    if (case_ty) |ty| {
                        if (terminated) continue;
                        if (result_ty) |existing| {
                            if (!self.typesEqual(existing, ty)) return TypeError.TypeMismatch;
                        } else {
                            result_ty = ty;
                        }
                    } else {
                        if (!terminated) has_value_cases = false;
                    }
                }

                try self.mergeMultiBranchScopeStates(scope, &saved_states, live_states.items, live_bodies.items);

                if (has_value_cases and result_ty != null) {
                    return result_ty.?;
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .primitive = .void_type };
                return ty;
            },
            .unsafe_expr => |ue| {
                self.unsafe_depth += 1;
                defer self.unsafe_depth -= 1;
                try self.checkBlock(ue.body, scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);
                if (blockTerminates(ue.body)) {
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .void_type };
                    return ty;
                }
                if (self.blockTailExprType(ue.body)) |tail_ty| return tail_ty;
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .primitive = .void_type };
                return ty;
            },
            .try_expr => |trye| {
                const inner_ty = try self.checkExpr(trye.expr, scope);
                if (trye.expr.* == .identifier) {
                    if (scope.lookup(trye.expr.identifier)) |source| {
                        if (!self.typeIsCopy(source.ty) and !isBorrowLikeType(source.ty)) try self.consumeBinding(scope, trye.expr.identifier, source, "try propagation");
                    }
                }

                if (inner_ty.* == .infer) return inner_ty;

                if (optionInnerType(inner_ty)) |unwrapped_ty| {
                    var try_cleanup = std.ArrayList([]const u8).init(self.allocator);
                    var curr: ?*Scope = scope;
                    while (curr) |s| {
                        var iter = s.symbols.valueIterator();
                        while (iter.next()) |sym| {
                            if (sym.state == .active and !isInternalSymbol(sym.name)) {
                                if (exprUsesIdentifierValue(trye.expr, sym.name)) continue;
                                try try_cleanup.append(sym.name);
                            }
                        }
                        curr = s.parent;
                    }
                    if (try_cleanup.items.len > 0) {
                        try self.cleanups.put(expr, try_cleanup);
                    } else {
                        try_cleanup.deinit();
                    }
                    return unwrapped_ty;
                }

                if (resultOkType(inner_ty)) |unwrapped_ty| {
                    var try_cleanup = std.ArrayList([]const u8).init(self.allocator);
                    var curr: ?*Scope = scope;
                    while (curr) |s| {
                        var iter = s.symbols.valueIterator();
                        while (iter.next()) |sym| {
                            if (sym.state == .active and !isInternalSymbol(sym.name)) {
                                if (exprUsesIdentifierValue(trye.expr, sym.name)) continue;
                                try try_cleanup.append(sym.name);
                            }
                        }
                        curr = s.parent;
                    }
                    if (try_cleanup.items.len > 0) {
                        try self.cleanups.put(expr, try_cleanup);
                    } else {
                        try_cleanup.deinit();
                    }
                    return unwrapped_ty;
                }

                // Unwrapped type is the type of the "value" field of the Result struct
                const struct_ty = lowering_rules.peelBorrowPointerType(inner_ty);

                if (struct_ty.* != .user_defined) return TypeError.NotAStruct;
                const struct_decl = self.structs.get(struct_ty.user_defined.name) orelse return TypeError.NotAStruct;
                var value_ty: ?*ast.Type = null;
                for (struct_decl.fields) |f| {
                    if (std.mem.eql(u8, f.name, "value")) {
                        value_ty = f.ty;
                        break;
                    }
                }
                const unwrapped_ty = value_ty orelse return TypeError.FieldNotFound;

                // Collect all currently active variables in the scope chain
                var try_cleanup = std.ArrayList([]const u8).init(self.allocator);
                var curr: ?*Scope = scope;
                while (curr) |s| {
                    var iter = s.symbols.valueIterator();
                    while (iter.next()) |sym| {
                        if (sym.state == .active and !isInternalSymbol(sym.name)) {
                            if (exprUsesIdentifierValue(trye.expr, sym.name)) continue;
                            try try_cleanup.append(sym.name);
                        }
                    }
                    curr = s.parent;
                }
                if (try_cleanup.items.len > 0) {
                    try self.cleanups.put(expr, try_cleanup);
                } else {
                    try_cleanup.deinit();
                }

                return unwrapped_ty;
            },
            else => return TypeError.CompileError,
        }
    }

    fn typesEqual(self: *TypeChecker, a: *ast.Type, b: *ast.Type) bool {
        if (a.* == .infer or b.* == .infer) return true;
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        switch (a.*) {
            .infer => return true,
            .primitive => |pa| {
                if (pa == b.primitive) return true;
                return switch (pa) {
                    .integer => isAnyIntegerType(b),
                    .float => isAnyFloatType(b),
                    .i8, .i16, .i32, .i64, .isize, .u8, .u16, .u32, .u64, .usize => isAnyIntegerType(b),
                    .f32, .f64 => isAnyFloatType(b),
                    else => false,
                };
            },
            .pointer => |pa| return self.typesEqual(pa, b.pointer),
            .borrow => |ba| return self.typesEqual(ba, b.borrow),
            .array => |aa| {
                return aa.len == b.array.len and self.typesEqual(aa.elem, b.array.elem);
            },
            .tuple => |ta| {
                if (ta.elems.len != b.tuple.elems.len) return false;
                for (ta.elems, b.tuple.elems) |ea, eb| {
                    if (!self.typesEqual(ea, eb)) return false;
                }
                return true;
            },
            .future => |fa| return self.typesEqual(fa, b.future),
            .closure => |ca| {
                if (ca.params.len != b.closure.params.len) return false;
                for (ca.params, b.closure.params) |pa, pb| {
                    if (!self.typesEqual(pa, pb)) return false;
                }
                return self.typesEqual(ca.ret, b.closure.ret);
            },
            .fn_ptr => |fa| {
                if (fa.abi == null) {
                    if (b.fn_ptr.abi != null) return false;
                } else if (b.fn_ptr.abi == null or !std.mem.eql(u8, fa.abi.?, b.fn_ptr.abi.?)) {
                    return false;
                }
                if (fa.params.len != b.fn_ptr.params.len) return false;
                for (fa.params, b.fn_ptr.params) |pa, pb| {
                    if (!self.typesEqual(pa, pb)) return false;
                }
                return self.typesEqual(fa.ret, b.fn_ptr.ret);
            },
            .user_defined => |uda| {
                if (!std.mem.eql(u8, uda.name, b.user_defined.name)) return false;
                if (uda.generics.len != b.user_defined.generics.len) return false;
                for (uda.generics, b.user_defined.generics) |ga, gb| {
                    if (!self.typesEqual(ga, gb)) return false;
                }
                return true;
            },
        }
    }

    fn typeName(self: *TypeChecker, ty: *ast.Type) TypeError![]const u8 {
        _ = self;
        return switch (ty.*) {
            .user_defined => |ud| ud.name,
            else => TypeError.CompileError,
        };
    }

    /// Short human-readable label for diagnostics. Unlike `@tagName(ty.*)` this
    /// distinguishes primitive widths and named types, so `expected u32, actual i32`
    /// no longer collapses into `expected primitive, actual primitive`.
    fn typeDesc(ty: *const ast.Type) []const u8 {
        return switch (ty.*) {
            .infer => "infer",
            .primitive => |p| @tagName(p),
            .pointer => "pointer",
            .borrow => "borrow",
            .array => "array",
            .tuple => "tuple",
            .future => "future",
            .closure => "closure",
            .fn_ptr => "fn_ptr",
            .user_defined => |ud| ud.name,
        };
    }

    fn checkImpl(self: *TypeChecker, impl_decl: *ast.ImplDecl) !void {
        if (impl_decl.trait_name) |trait_name| {
            try self.checkTraitImpl(trait_name, impl_decl);
        }
        for (impl_decl.methods) |method| {
            if (method.* != .func_decl) return TypeError.CompileError;
            try self.checkFunc(&method.func_decl);
        }
    }

    fn typeEqualsWithSelf(self: *TypeChecker, actual: *ast.Type, expected: *ast.Type, self_ty: *ast.Type) bool {
        if (expected.* == .user_defined and std.mem.eql(u8, expected.user_defined.name, "Self")) {
            return self.typesEqual(actual, self_ty);
        }
        if (std.meta.activeTag(actual.*) != std.meta.activeTag(expected.*)) return self.typesEqual(actual, expected);
        switch (expected.*) {
            .borrow => |inner| return actual.* == .borrow and self.typeEqualsWithSelf(actual.borrow, inner, self_ty),
            .pointer => |inner| return actual.* == .pointer and self.typeEqualsWithSelf(actual.pointer, inner, self_ty),
            .array => |arr| return actual.* == .array and actual.array.len == arr.len and self.typeEqualsWithSelf(actual.array.elem, arr.elem, self_ty),
            .tuple => |tuple| {
                if (actual.* != .tuple or actual.tuple.elems.len != tuple.elems.len) return false;
                for (actual.tuple.elems, tuple.elems) |a, e| {
                    if (!self.typeEqualsWithSelf(a, e, self_ty)) return false;
                }
                return true;
            },
            .future => |inner| return actual.* == .future and self.typeEqualsWithSelf(actual.future, inner, self_ty),
            .fn_ptr => |fn_ptr| {
                if (actual.* != .fn_ptr) return false;
                if (fn_ptr.params.len != actual.fn_ptr.params.len) return false;
                for (actual.fn_ptr.params, fn_ptr.params) |a, e| {
                    if (!self.typeEqualsWithSelf(a, e, self_ty)) return false;
                }
                return self.typeEqualsWithSelf(actual.fn_ptr.ret, fn_ptr.ret, self_ty);
            },
            .user_defined => |ud| {
                if (actual.* != .user_defined or !std.mem.eql(u8, actual.user_defined.name, ud.name) or actual.user_defined.generics.len != ud.generics.len) return false;
                for (actual.user_defined.generics, ud.generics) |a, e| {
                    if (!self.typeEqualsWithSelf(a, e, self_ty)) return false;
                }
                return true;
            },
            else => return self.typesEqual(actual, expected),
        }
    }

    fn implMethodFor(impl_decl: *ast.ImplDecl, name: []const u8) ?*ast.FuncDecl {
        for (impl_decl.methods) |method| {
            if (method.* == .func_decl and std.mem.eql(u8, method.func_decl.name, name)) return &method.func_decl;
        }
        return null;
    }

    fn checkTraitImpl(self: *TypeChecker, trait_name: []const u8, impl_decl: *ast.ImplDecl) TypeError!void {
        const trait_decl = self.traits.get(trait_name) orelse return TypeError.UndefinedVariable;
        const target_name = try self.typeName(impl_decl.target_ty);
        for (trait_decl.supertraits) |supertrait| {
            if (!self.typeDirectlyImplementsTrait(target_name, supertrait)) {
                self.setError("Trait impl `{s}` for `{s}` requires separate impl of supertrait `{s}`", .{ trait_name, target_name, supertrait });
                return TypeError.UndefinedVariable;
            }
        }
        for (impl_decl.methods) |method| {
            if (method.* != .func_decl) return TypeError.CompileError;
            if (self.findTraitOwnMethod(trait_name, method.func_decl.name) == null) {
                self.setError("Trait impl for `{s}` contains method `{s}` not declared by trait `{s}`", .{ target_name, method.func_decl.name, trait_name });
                return TypeError.TypeMismatch;
            }
        }
        for (trait_decl.methods) |trait_method| {
            const impl_method = implMethodFor(impl_decl, trait_method.name) orelse {
                self.setError("Trait impl missing method `{s}` for trait `{s}`", .{ trait_method.name, trait_name });
                return TypeError.UndefinedVariable;
            };
            if (impl_method.params.len != trait_method.params.len) return TypeError.InvalidArgsCount;
            for (impl_method.params, trait_method.params) |actual, expected| {
                if (actual.is_borrow != expected.is_borrow or actual.is_move != expected.is_move) return TypeError.TypeMismatch;
                if (!self.typeEqualsWithSelf(actual.ty, expected.ty, impl_decl.target_ty)) return TypeError.TypeMismatch;
            }
            if (!self.typeEqualsWithSelf(impl_method.ret_ty, trait_method.ret_ty, impl_decl.target_ty)) return TypeError.TypeMismatch;
        }
    }
};

test "type checker basic validation" {
    // We can write tests here if we want to build it, but user requested 'no rushing to compile'.
    // Let's ensure the semantic correctness.
}

test "type checker classifies loop local release ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var int_ty = ast.Type{ .primitive = .i64 };
    const function_scope = try Scope.init(arena.allocator(), null);
    try function_scope.define("outer", &int_ty, false);
    const loop_scope = try Scope.init(arena.allocator(), function_scope);
    try loop_scope.define("item", &int_ty, false);
    const nested_scope = try Scope.init(arena.allocator(), loop_scope);
    try nested_scope.define("inner", &int_ty, false);

    try std.testing.expect(!bindingIsLocalToLoop(nested_scope, loop_scope, "outer"));
    try std.testing.expect(bindingIsLocalToLoop(nested_scope, loop_scope, "item"));
    try std.testing.expect(bindingIsLocalToLoop(nested_scope, loop_scope, "inner"));
}

test "type checker resolves registered function alias" {
    var tc = TypeChecker.init(std.testing.allocator);
    defer tc.deinit();

    try tc.registerFunctionAliasWithMetadata("dep__imported_a", "imported_a", "dep", "/tmp/dep.sla");
    try std.testing.expectEqualStrings("imported_a", tc.resolveFunctionAlias("dep__imported_a"));
    try std.testing.expectEqualStrings("plain_name", tc.resolveFunctionAlias("plain_name"));

    const metadata = tc.resolveFunctionAliasMetadata("dep__imported_a");
    try std.testing.expect(metadata != null);
    try std.testing.expectEqualStrings("dep__imported_a", metadata.?.alias);
    try std.testing.expectEqualStrings("imported_a", metadata.?.target);
    try std.testing.expect(metadata.?.namespace != null);
    try std.testing.expect(metadata.?.module_path != null);
    try std.testing.expectEqualStrings("dep", metadata.?.namespace.?);
    try std.testing.expectEqualStrings("/tmp/dep.sla", metadata.?.module_path.?);
    try std.testing.expect(tc.resolveFunctionAliasMetadata("plain_name") == null);
}

test "type checker resolves imported function signature without function body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tc = TypeChecker.init(arena.allocator());
    defer tc.deinit();

    var ret_ty = ast.Type{ .primitive = .i32 };
    try tc.registerFunctionAliasWithMetadata("dep__imported_a", "imported_a", "dep", "/tmp/dep.sla");
    try tc.registerImportedFunctionSignature("imported_a", &.{}, &ret_ty, false);

    var call_node = ast.Node{ .call_expr = .{
        .func_name = "dep__imported_a",
        .associated_target = null,
        .generics = &.{},
        .args = &.{},
    } };
    var expr_stmt_node = ast.Node{ .expr_stmt = &call_node };
    var test_node = ast.Node{ .test_decl = .{
        .name = "imported signature only",
        .is_ignored = false,
        .should_panic = false,
        .body = &.{&expr_stmt_node},
    } };
    var program = ast.Node{ .program = .{ .decls = &.{&test_node} } };

    try tc.checkProgram(&program);
    const call_ty = tc.expr_types.get(&call_node) orelse return error.TestUnexpectedResult;
    try std.testing.expect(call_ty.* == .primitive);
    try std.testing.expectEqual(ast.Primitive.i32, call_ty.primitive);
    try std.testing.expect(tc.funcs.get("imported_a") == null);
    try std.testing.expectEqualStrings("imported_a", tc.resolved_call_symbols.get(&call_node).?);
    const call_metadata = tc.resolved_call_alias_metadata.get(&call_node);
    try std.testing.expect(call_metadata != null);
    try std.testing.expectEqualStrings("dep__imported_a", call_metadata.?.alias);
    try std.testing.expectEqualStrings("imported_a", call_metadata.?.target);
    try std.testing.expectEqualStrings("dep", call_metadata.?.namespace.?);
    try std.testing.expectEqualStrings("/tmp/dep.sla", call_metadata.?.module_path.?);
}

test "type checker allows raw ptr bindings from pointer abi returns" {
    const parser_mod = @import("parser.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\fn assign_probe(data: ptr, len: u64) -> i32 {
        \\    var node: ptr;
        \\    node = abi_make_ptr(data, len);
        \\    return 0;
        \\}
        \\
        \\fn let_probe(data: ptr, len: u64) -> ptr {
        \\    let node: ptr = abi_make_ptr(data, len);
        \\    return node;
        \\}
        \\
        \\fn return_probe(data: ptr, len: u64) -> ptr {
        \\    return abi_make_ptr(data, len);
        \\}
    ;
    var parser = parser_mod.Parser.init(arena.allocator(), source);
    const program = try parser.parseProgram();

    var tc = TypeChecker.init(arena.allocator());
    defer tc.deinit();
    try tc.loadContracts(
        \\@extern abi_make_ptr(data: ptr, len: u64) -> ^ptr
    , "");
    try tc.checkProgram(program);
}
