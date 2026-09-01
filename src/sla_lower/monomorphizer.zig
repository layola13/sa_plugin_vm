const std = @import("std");
const ast = @import("ast.zig");

pub const MonomorphizeError = error{
    TemplateNotFound,
    MonomorphizeError,
    OutOfMemory,
};

pub const Substitution = struct {
    param: []const u8,
    arg: *ast.Type,
};

pub const Monomorphizer = struct {
    allocator: std.mem.Allocator,
    struct_templates: std.StringHashMap(*ast.StructDecl),
    enum_templates: std.StringHashMap(*ast.EnumDecl),
    func_templates: std.StringHashMap(*ast.FuncDecl),
    impl_templates: std.ArrayList(*ast.ImplDecl),

    // Tracks already specialized structs, enums, impls, and functions to avoid duplicate generation
    specialized_structs: std.StringHashMap([]const u8),
    specialized_enums: std.StringHashMap([]const u8),
    specialized_impls: std.StringHashMap([]const u8),
    specialized_funcs: std.StringHashMap([]const u8),

    // Accumulators for the generated concrete declarations
    new_decls: std.ArrayList(*ast.Node),
    last_missing_template: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) Monomorphizer {
        return .{
            .allocator = allocator,
            .struct_templates = std.StringHashMap(*ast.StructDecl).init(allocator),
            .enum_templates = std.StringHashMap(*ast.EnumDecl).init(allocator),
            .func_templates = std.StringHashMap(*ast.FuncDecl).init(allocator),
            .impl_templates = std.ArrayList(*ast.ImplDecl).init(allocator),
            .specialized_structs = std.StringHashMap([]const u8).init(allocator),
            .specialized_enums = std.StringHashMap([]const u8).init(allocator),
            .specialized_impls = std.StringHashMap([]const u8).init(allocator),
            .specialized_funcs = std.StringHashMap([]const u8).init(allocator),
            .new_decls = std.ArrayList(*ast.Node).init(allocator),
            .last_missing_template = null,
        };
    }

    pub fn deinit(self: *Monomorphizer) void {
        self.struct_templates.deinit();
        self.enum_templates.deinit();
        self.func_templates.deinit();
        self.impl_templates.deinit();

        var struct_val_iter = self.specialized_structs.valueIterator();
        while (struct_val_iter.next()) |v| {
            self.allocator.free(v.*);
        }
        self.specialized_structs.deinit();

        var enum_val_iter = self.specialized_enums.valueIterator();
        while (enum_val_iter.next()) |v| {
            self.allocator.free(v.*);
        }
        self.specialized_enums.deinit();

        var impl_val_iter = self.specialized_impls.valueIterator();
        while (impl_val_iter.next()) |v| {
            self.allocator.free(v.*);
        }
        self.specialized_impls.deinit();

        var func_val_iter = self.specialized_funcs.valueIterator();
        while (func_val_iter.next()) |v| {
            self.allocator.free(v.*);
        }
        self.specialized_funcs.deinit();

        self.new_decls.deinit();
    }

    fn implHasGenericTarget(decl: *const ast.ImplDecl) bool {
        return switch (decl.target_ty.*) {
            .user_defined => |ud| ud.generics.len > 0,
            else => false,
        };
    }

    pub fn missingTemplateName(self: *const Monomorphizer) ?[]const u8 {
        return self.last_missing_template;
    }

    fn templateNotFound(self: *Monomorphizer, name: []const u8) MonomorphizeError {
        self.last_missing_template = name;
        return MonomorphizeError.TemplateNotFound;
    }

    fn genericNamesFromTarget(self: *Monomorphizer, target_ty: *ast.Type) MonomorphizeError![]const []const u8 {
        const ud = switch (target_ty.*) {
            .user_defined => |u| u,
            else => return MonomorphizeError.MonomorphizeError,
        };
        var names = std.ArrayList([]const u8).init(self.allocator);
        for (ud.generics) |generic_ty| {
            const generic_ud = switch (generic_ty.*) {
                .user_defined => |u| u,
                else => return MonomorphizeError.MonomorphizeError,
            };
            if (generic_ud.generics.len != 0) return MonomorphizeError.MonomorphizeError;
            try names.append(generic_ud.name);
        }
        return try names.toOwnedSlice();
    }

    fn instantiateGenericImpls(self: *Monomorphizer, base_name: []const u8, mangled_name: []const u8, args: []const *ast.Type) MonomorphizeError!void {
        for (self.impl_templates.items) |template| {
            const target_ud = switch (template.target_ty.*) {
                .user_defined => |ud| ud,
                else => continue,
            };
            if (!std.mem.eql(u8, target_ud.name, base_name) or target_ud.generics.len != args.len) continue;

            var key_buf = std.ArrayList(u8).init(self.allocator);
            try key_buf.appendSlice(mangled_name);
            try key_buf.appendSlice("|impl|");
            if (template.trait_name) |trait_name| try key_buf.appendSlice(trait_name) else try key_buf.appendSlice("inherent");
            for (template.methods) |method| {
                if (method.* != .func_decl) return MonomorphizeError.MonomorphizeError;
                try key_buf.append('|');
                try key_buf.appendSlice(method.func_decl.name);
            }
            const key = try key_buf.toOwnedSlice();
            if (self.specialized_impls.contains(key)) continue;
            try self.specialized_impls.put(key, try self.allocator.dupe(u8, key));

            const generic_names = try self.genericNamesFromTarget(template.target_ty);
            const substituted_methods = try self.substituteBlock(template.methods, generic_names, args);
            const specialized_methods = try self.specializeBlock(substituted_methods);

            const target = try self.allocator.create(ast.Type);
            target.* = .{ .user_defined = .{ .name = mangled_name, .generics = &.{} } };

            const node = try self.allocator.create(ast.Node);
            node.* = .{ .impl_decl = .{ .trait_name = template.trait_name, .target_ty = target, .methods = specialized_methods } };
            try self.new_decls.append(node);
        }
    }

    pub fn monomorphize(
        self: *Monomorphizer,
        program: *ast.Node,
        original_primary_decls: ?*const std.AutoHashMap(*const ast.Node, void),
        specialized_primary_decls: ?*std.AutoHashMap(*const ast.Node, void),
    ) MonomorphizeError!*ast.Node {
        self.last_missing_template = null;
        if (program.* != .program) return MonomorphizeError.MonomorphizeError;

        var regular_decls = std.ArrayList(*ast.Node).init(self.allocator);
        errdefer regular_decls.deinit();

        // 1. Separate templates from concrete declarations
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .struct_decl => |*s| {
                    if (s.generics.len > 0) {
                        try self.struct_templates.put(s.name, s);
                    } else {
                        try regular_decls.append(decl);
                    }
                },
                .enum_decl => |*e| {
                    if (e.generics.len > 0) {
                        try self.enum_templates.put(e.name, e);
                    } else {
                        try regular_decls.append(decl);
                    }
                },
                .type_alias_decl => {
                    try regular_decls.append(decl);
                },
                .trait_decl => {
                    try regular_decls.append(decl);
                },
                .func_decl => |*f| {
                    if (f.generics.len > 0) {
                        try self.func_templates.put(f.name, f);
                    } else {
                        try regular_decls.append(decl);
                    }
                },
                .impl_decl => |*i| {
                    if (implHasGenericTarget(i)) {
                        try self.impl_templates.append(i);
                    } else {
                        try regular_decls.append(decl);
                    }
                },
                else => try regular_decls.append(decl),
            }
        }

        // 2. Scan all regular declarations for generic instantiations (structs or function calls)
        var i: usize = 0;
        while (i < regular_decls.items.len) : (i += 1) {
            const decl = regular_decls.items[i];
            const updated_decl = try self.specializeNode(decl);
            regular_decls.items[i] = updated_decl;
            if (original_primary_decls) |opd| {
                if (opd.contains(decl)) {
                    if (specialized_primary_decls) |spd| {
                        try spd.put(updated_decl, {});
                    }
                }
            }
        }

        // 3. Append all newly generated specialized declarations
        for (self.new_decls.items) |nd| {
            try regular_decls.append(nd);
            if (specialized_primary_decls) |spd| {
                try spd.put(nd, {});
            }
        }

        const result = try self.allocator.create(ast.Node);
        result.* = .{ .program = .{ .decls = try regular_decls.toOwnedSlice() } };
        return result;
    }

    fn specializeNode(self: *Monomorphizer, node: *ast.Node) MonomorphizeError!*ast.Node {
        switch (node.*) {
            .program => unreachable,
            .struct_decl => |s| {
                var new_fields = std.ArrayList(ast.Field).init(self.allocator);
                for (s.fields) |f| {
                    const new_ty = try self.specializeType(f.ty);
                    try new_fields.append(.{ .name = f.name, .ty = new_ty });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .struct_decl = .{
                        .name = s.name,
                        .derives = s.derives,
                        .generics = &.{},
                        .fields = try new_fields.toOwnedSlice(),
                        .is_union = s.is_union,
                        .is_opaque = s.is_opaque,
                    },
                };
                return res;
            },
            .type_alias_decl => |a| {
                var new_components = std.ArrayList(ast.TypeAliasComponent).init(self.allocator);
                for (a.components) |component| {
                    switch (component) {
                        .ty => |ty| try new_components.append(.{ .ty = try self.specializeType(ty) }),
                        .inline_struct => |fields| {
                            var new_fields = std.ArrayList(ast.Field).init(self.allocator);
                            for (fields) |f| {
                                try new_fields.append(.{ .name = f.name, .ty = try self.specializeType(f.ty) });
                            }
                            try new_components.append(.{ .inline_struct = try new_fields.toOwnedSlice() });
                        },
                    }
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .type_alias_decl = .{ .name = a.name, .components = try new_components.toOwnedSlice() } };
                return res;
            },
            .enum_decl => |e| {
                var new_variants = std.ArrayList(ast.EnumVariant).init(self.allocator);
                for (e.variants) |variant| {
                    var new_fields = std.ArrayList(ast.Field).init(self.allocator);
                    for (variant.fields) |f| {
                        const new_ty = try self.specializeType(f.ty);
                        try new_fields.append(.{ .name = f.name, .ty = new_ty });
                    }
                    try new_variants.append(.{ .name = variant.name, .fields = try new_fields.toOwnedSlice() });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .enum_decl = .{ .name = e.name, .generics = &.{}, .variants = try new_variants.toOwnedSlice() } };
                return res;
            },
            .trait_decl => |t| {
                var new_methods = std.ArrayList(ast.TraitMethod).init(self.allocator);
                for (t.methods) |method| {
                    var new_params = std.ArrayList(ast.Param).init(self.allocator);
                    for (method.params) |p| {
                        const new_ty = try self.specializeType(p.ty);
                        try new_params.append(.{ .name = p.name, .ty = new_ty, .is_borrow = p.is_borrow, .is_move = p.is_move });
                    }
                    const new_ret = try self.specializeType(method.ret_ty);
                    try new_methods.append(.{ .name = method.name, .params = try new_params.toOwnedSlice(), .ret_ty = new_ret });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .trait_decl = .{ .name = t.name, .supertraits = t.supertraits, .methods = try new_methods.toOwnedSlice() } };
                return res;
            },
            .overload_decl => |o| {
                const new_target = try self.specializeType(o.target_ty);
                const new_methods = try self.specializeBlock(o.methods);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .overload_decl = .{ .target_ty = new_target, .methods = new_methods } };
                return res;
            },
            .impl_decl => |i| {
                const new_target = try self.specializeType(i.target_ty);
                const new_methods = try self.specializeBlock(i.methods);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .impl_decl = .{ .trait_name = i.trait_name, .target_ty = new_target, .methods = new_methods } };
                return res;
            },
            .func_decl => |f| {
                var new_params = std.ArrayList(ast.Param).init(self.allocator);
                for (f.params) |p| {
                    const new_ty = try self.specializeType(p.ty);
                    try new_params.append(.{ .name = p.name, .ty = new_ty, .is_borrow = p.is_borrow, .is_move = p.is_move });
                }
                const new_ret = try self.specializeType(f.ret_ty);
                const new_body = try self.specializeBlock(f.body);

                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .func_decl = .{
                        .name = f.name,
                        .is_pub = f.is_pub,
                        .is_extern = f.is_extern,
                        .abi = f.abi,
                        .no_mangle = f.no_mangle,
                        .is_decl_only = f.is_decl_only,
                        .generics = &.{},
                        .params = try new_params.toOwnedSlice(),
                        .ret_ty = new_ret,
                        .body = new_body,
                        .is_inline = f.is_inline,
                        .is_async = f.is_async,
                        .operator = f.operator,
                    },
                };
                return res;
            },
            .macro_decl => |m| {
                const new_body = try self.specializeBlock(m.body);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .macro_decl = .{
                        .name = m.name,
                        .params = m.params,
                        .body = new_body,
                    },
                };
                return res;
            },
            .import_decl => |import| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .import_decl = .{ .path = import.path } };
                return res;
            },
            .using_decl => |u| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .using_decl = .{ .path = u.path } };
                return res;
            },
            .test_decl => |t| {
                const new_body = try self.specializeBlock(t.body);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .test_decl = .{
                        .name = t.name,
                        .is_ignored = t.is_ignored,
                        .should_panic = t.should_panic,
                        .body = new_body,
                    },
                };
                return res;
            },
            .let_stmt => |let| {
                const new_ty = if (let.ty) |ty| try self.specializeType(ty) else null;
                const new_val = if (let.ty) |declared_ty|
                    try self.specializeEnumLiteralForType(let.value, declared_ty, new_ty.?)
                else
                    try self.specializeNode(let.value);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .let_stmt = .{
                        .name = let.name,
                        .ty = new_ty,
                        .value = new_val,
                    },
                };
                return res;
            },
            .let_else_stmt => |let| {
                const new_val = try self.specializeNode(let.value);
                const new_else = try self.specializeBlock(let.else_block);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .let_else_stmt = .{ .pattern = let.pattern, .value = new_val, .else_block = new_else } };
                return res;
            },
            .let_destructure_stmt => |let| {
                const new_val = try self.specializeNode(let.value);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .let_destructure_stmt = .{ .names = let.names, .value = new_val, .rest_name = let.rest_name, .is_slice = let.is_slice } };
                return res;
            },
            .const_stmt => |c| {
                const new_ty = if (c.ty) |ty| try self.specializeType(ty) else null;
                const new_val = if (c.ty) |declared_ty|
                    try self.specializeEnumLiteralForType(c.value, declared_ty, new_ty.?)
                else
                    try self.specializeNode(c.value);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .const_stmt = .{
                        .name = c.name,
                        .ty = new_ty,
                        .value = new_val,
                    },
                };
                return res;
            },
            .var_stmt => |v| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .var_stmt = .{ .name = v.name, .ty = try self.specializeType(v.ty) } };
                return res;
            },
            .assign_stmt => |assign| {
                const new_target = try self.specializeNode(assign.target);
                const new_val = try self.specializeNode(assign.value);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .assign_stmt = .{
                        .target = new_target,
                        .value = new_val,
                    },
                };
                return res;
            },
            .block_stmt => |blk| {
                const new_body = try self.specializeBlock(blk.body);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .block_stmt = .{ .body = new_body } };
                return res;
            },
            .expr_stmt => |expr| {
                const new_expr = try self.specializeNode(expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .expr_stmt = new_expr };
                return res;
            },
            .return_stmt => |ret| {
                const new_val = if (ret.value) |v| try self.specializeNode(v) else null;
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .return_stmt = .{ .value = new_val } };
                return res;
            },
            .for_stmt => |f| {
                const new_start = try self.specializeNode(f.start);
                const new_end = if (f.end) |end_expr| try self.specializeNode(end_expr) else null;
                const new_body = try self.specializeBlock(f.body);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .for_stmt = .{
                        .var_name = f.var_name,
                        .start = new_start,
                        .end = new_end,
                        .body = new_body,
                    },
                };
                return res;
            },
            .while_stmt => |w| {
                const new_cond = try self.specializeNode(w.cond);
                const new_body = try self.specializeBlock(w.body);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .while_stmt = .{
                        .cond = new_cond,
                        .let_pattern = w.let_pattern,
                        .body = new_body,
                    },
                };
                return res;
            },
            .break_stmt => {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .break_stmt = .{} };
                return res;
            },
            .continue_stmt => {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .continue_stmt = .{} };
                return res;
            },
            .release_stmt => |rel| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .release_stmt = .{ .var_name = rel.var_name } };
                return res;
            },
            .literal => |lit| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .literal = lit };
                return res;
            },
            .identifier => |name| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .identifier = name };
                return res;
            },
            .generic_func_ref => |ref| {
                var spec_generics = std.ArrayList(*ast.Type).init(self.allocator);
                for (ref.generics) |g| {
                    try spec_generics.append(try self.specializeType(g));
                }
                const generics = try spec_generics.toOwnedSlice();
                const mangled_name = try self.getMangledFuncName(ref.func_name, generics);
                if (!self.specialized_funcs.contains(mangled_name)) {
                    const template = self.func_templates.get(ref.func_name) orelse return self.templateNotFound(ref.func_name);
                    try self.instantiateFunction(mangled_name, template, generics);
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .identifier = mangled_name };
                return res;
            },
            .if_expr => |ife| {
                const new_cond = try self.specializeNode(ife.cond);
                var new_chain: ?[]const ast.IfLetCond = null;
                if (ife.let_chain) |chain| {
                    var items = std.ArrayList(ast.IfLetCond).init(self.allocator);
                    for (chain) |cond| {
                        try items.append(.{ .pattern = cond.pattern, .value = try self.specializeNode(cond.value) });
                    }
                    new_chain = try items.toOwnedSlice();
                }
                const new_then = try self.specializeBlock(ife.then_block);
                const new_else = if (ife.else_block) |eb| try self.specializeBlock(eb) else null;
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .if_expr = .{
                        .cond = new_cond,
                        .let_chain = new_chain,
                        .then_block = new_then,
                        .else_block = new_else,
                    },
                };
                return res;
            },
            .switch_expr => |swe| {
                const new_val = try self.specializeNode(swe.val);
                var new_cases = std.ArrayList(ast.Case).init(self.allocator);
                for (swe.cases) |case| {
                    const new_pattern = try self.specializeNode(case.pattern);
                    const new_body = try self.specializeBlock(case.body);
                    try new_cases.append(.{ .pattern = new_pattern, .body = new_body });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .switch_expr = .{
                        .val = new_val,
                        .cases = try new_cases.toOwnedSlice(),
                    },
                };
                return res;
            },
            .match_expr => |mat| {
                const new_val = try self.specializeNode(mat.val);
                var new_cases = std.ArrayList(ast.MatchCase).init(self.allocator);
                for (mat.cases) |case| {
                    const new_guard = if (case.guard) |guard| try self.specializeNode(guard) else null;
                    const new_body = try self.specializeBlock(case.body);
                    try new_cases.append(.{ .pattern = case.pattern, .guard = new_guard, .body = new_body });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .match_expr = .{ .val = new_val, .cases = try new_cases.toOwnedSlice() } };
                return res;
            },
            .unsafe_expr => |ue| {
                const new_body = try self.specializeBlock(ue.body);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .unsafe_expr = .{ .body = new_body } };
                return res;
            },
            .await_expr => |aw| {
                const new_expr = try self.specializeNode(aw.expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .await_expr = .{ .expr = new_expr } };
                return res;
            },
            .inline_asm_expr => |asm_expr| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .inline_asm_expr = .{ .template = asm_expr.template, .operands = asm_expr.operands } };
                return res;
            },
            .binary_expr => |bin| {
                const new_left = try self.specializeNode(bin.left);
                const new_right = try self.specializeNode(bin.right);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .binary_expr = .{
                        .op = bin.op,
                        .left = new_left,
                        .right = new_right,
                    },
                };
                return res;
            },
            .borrow_expr => |borrow| {
                const new_expr = try self.specializeNode(borrow.expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .borrow_expr = .{ .expr = new_expr } };
                return res;
            },
            .move_expr => |move| {
                const new_expr = try self.specializeNode(move.expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .move_expr = .{ .expr = new_expr } };
                return res;
            },
            .deref_expr => |deref| {
                const new_expr = try self.specializeNode(deref.expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .deref_expr = .{ .expr = new_expr } };
                return res;
            },
            .cast_expr => |cast| {
                const new_expr = try self.specializeNode(cast.expr);
                const new_ty = try self.specializeType(cast.ty);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .cast_expr = .{ .expr = new_expr, .ty = new_ty } };
                return res;
            },
            .field_expr => |field| {
                const new_expr = try self.specializeNode(field.expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .field_expr = .{
                        .expr = new_expr,
                        .field_name = field.field_name,
                    },
                };
                return res;
            },
            .struct_literal => |lit| {
                const new_ty = try self.specializeType(lit.ty);
                var new_fields = std.ArrayList(ast.StructLiteralField).init(self.allocator);
                for (lit.fields) |field| {
                    try new_fields.append(.{
                        .name = field.name,
                        .value = try self.specializeNode(field.value),
                    });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .struct_literal = .{
                        .ty = new_ty,
                        .fields = try new_fields.toOwnedSlice(),
                        .update_expr = if (lit.update_expr) |update_expr| try self.specializeNode(update_expr) else null,
                    },
                };
                return res;
            },
            .enum_literal => |lit| {
                var new_fields = std.ArrayList(ast.EnumLiteralField).init(self.allocator);
                for (lit.fields) |field| {
                    try new_fields.append(.{ .name = field.name, .value = try self.specializeNode(field.value) });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .enum_literal = .{ .enum_name = lit.enum_name, .variant_name = lit.variant_name, .fields = try new_fields.toOwnedSlice() } };
                return res;
            },
            .closure_literal => |lit| {
                var new_params = std.ArrayList(ast.Param).init(self.allocator);
                for (lit.params) |p| {
                    try new_params.append(.{ .name = p.name, .ty = try self.specializeType(p.ty), .is_borrow = p.is_borrow, .is_move = p.is_move });
                }
                const new_body = try self.specializeNode(lit.body);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .closure_literal = .{ .params = try new_params.toOwnedSlice(), .body = new_body } };
                return res;
            },
            .array_literal => |lit| {
                var new_elements = std.ArrayList(*ast.Node).init(self.allocator);
                for (lit.elements) |elem| {
                    try new_elements.append(try self.specializeNode(elem));
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .array_literal = .{ .elements = try new_elements.toOwnedSlice() } };
                return res;
            },
            .repeat_array_literal => |lit| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .repeat_array_literal = .{ .value = try self.specializeNode(lit.value), .len = lit.len } };
                return res;
            },
            .tuple_literal => |lit| {
                var new_elements = std.ArrayList(*ast.Node).init(self.allocator);
                for (lit.elements) |elem| {
                    try new_elements.append(try self.specializeNode(elem));
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .tuple_literal = .{ .elements = try new_elements.toOwnedSlice() } };
                return res;
            },
            .index_expr => |idx| {
                const new_target = try self.specializeNode(idx.target);
                const new_index = try self.specializeNode(idx.index);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .index_expr = .{ .target = new_target, .index = new_index } };
                return res;
            },
            .slice_expr => |slc| {
                const new_target = try self.specializeNode(slc.target);
                const new_start = try self.specializeNode(slc.start);
                const new_end = try self.specializeNode(slc.end);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .slice_expr = .{ .target = new_target, .start = new_start, .end = new_end } };
                return res;
            },
            .try_expr => |trye| {
                const new_expr = try self.specializeNode(trye.expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .try_expr = .{ .expr = new_expr } };
                return res;
            },
            .call_expr => |call| {
                if (call.generics.len > 0 and !self.func_templates.contains(call.func_name)) {
                    var new_args = std.ArrayList(*ast.Node).init(self.allocator);
                    for (call.args) |arg| {
                        try new_args.append(try self.specializeNode(arg));
                    }
                    var new_generics = std.ArrayList(*ast.Type).init(self.allocator);
                    for (call.generics) |g| {
                        try new_generics.append(try self.specializeType(g));
                    }
                    const res = try self.allocator.create(ast.Node);
                    res.* = .{
                        .call_expr = .{
                            .func_name = call.func_name,
                            .associated_target = call.associated_target,
                            .generics = try new_generics.toOwnedSlice(),
                            .args = try new_args.toOwnedSlice(),
                        },
                    };
                    return res;
                }

                // If this is a generic function call (e.g. unwrap_or<int>(opt, default))
                if (call.generics.len > 0) {
                    const mangled_name = try self.getMangledFuncName(call.func_name, call.generics);

                    // Instantiate if not already done
                    if (!self.specialized_funcs.contains(mangled_name)) {
                        const template = self.func_templates.get(call.func_name) orelse return self.templateNotFound(call.func_name);
                        try self.instantiateFunction(mangled_name, template, call.generics);
                    }

                    var new_args = std.ArrayList(*ast.Node).init(self.allocator);
                    for (call.args) |arg| {
                        try new_args.append(try self.specializeNode(arg));
                    }

                    const res = try self.allocator.create(ast.Node);
                    res.* = .{
                        .call_expr = .{
                            .func_name = mangled_name,
                            .associated_target = call.associated_target,
                            .generics = &.{},
                            .args = try new_args.toOwnedSlice(),
                        },
                    };
                    return res;
                }

                if (self.func_templates.get(call.func_name)) |template| {
                    if (try self.inferGenericArgsForCall(template, call.args)) |inferred_args| {
                        const mangled_name = try self.getMangledFuncName(call.func_name, inferred_args);
                        if (!self.specialized_funcs.contains(mangled_name)) {
                            try self.instantiateFunction(mangled_name, template, inferred_args);
                        }

                        var new_args = std.ArrayList(*ast.Node).init(self.allocator);
                        for (call.args) |arg| {
                            try new_args.append(try self.specializeNode(arg));
                        }

                        const res = try self.allocator.create(ast.Node);
                        res.* = .{
                            .call_expr = .{
                                .func_name = mangled_name,
                                .associated_target = call.associated_target,
                                .generics = &.{},
                                .args = try new_args.toOwnedSlice(),
                            },
                        };
                        return res;
                    }
                }

                // Ordinary function call
                var new_args = std.ArrayList(*ast.Node).init(self.allocator);
                for (call.args) |arg| {
                    try new_args.append(try self.specializeNode(arg));
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .call_expr = .{
                        .func_name = call.func_name,
                        .associated_target = call.associated_target,
                        .generics = &.{},
                        .args = try new_args.toOwnedSlice(),
                    },
                };
                return res;
            },
        }
    }

    fn inferGenericArgsForCall(self: *Monomorphizer, template: *const ast.FuncDecl, args: []const *ast.Node) MonomorphizeError!?[]const *ast.Type {
        if (template.generics.len == 0) return null;
        if (template.params.len != args.len) return null;

        const inferred = try self.allocator.alloc(?*ast.Type, template.generics.len);
        @memset(inferred, null);

        for (template.params, args) |param, arg| {
            const actual_ty = try self.inferNodeTypeShallow(arg) orelse return null;
            if (!try self.collectGenericBindings(template.generics, param.ty, actual_ty, inferred)) {
                return null;
            }
        }

        const final = try self.allocator.alloc(*ast.Type, template.generics.len);
        for (inferred, 0..) |maybe_ty, i| {
            final[i] = maybe_ty orelse return null;
        }
        return final;
    }

    fn inferNodeTypeShallow(self: *Monomorphizer, node: *const ast.Node) MonomorphizeError!?*ast.Type {
        switch (node.*) {
            .literal => |lit| {
                const ty = try self.allocator.create(ast.Type);
                ty.* = switch (lit) {
                    .int_val => .{ .primitive = .i32 },
                    .float_val => .{ .primitive = .f64 },
                    .bool_val => .{ .primitive = .boolean },
                    .string_val => .{ .user_defined = .{ .name = "Slice", .generics = blk: {
                        const generics = try self.allocator.alloc(*ast.Type, 1);
                        const elem = try self.allocator.create(ast.Type);
                        elem.* = .{ .primitive = .u8 };
                        generics[0] = elem;
                        break :blk generics;
                    } } },
                };
                return ty;
            },
            .tuple_literal => |tuple| {
                var elems = std.ArrayList(*ast.Type).init(self.allocator);
                for (tuple.elements) |elem| {
                    try elems.append((try self.inferNodeTypeShallow(elem)) orelse return null);
                }
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .tuple = .{ .elems = try elems.toOwnedSlice() } };
                return ty;
            },
            .array_literal => |array| {
                if (array.elements.len == 0) return null;
                const elem_ty = (try self.inferNodeTypeShallow(array.elements[0])) orelse return null;
                for (array.elements[1..]) |elem| {
                    const next_ty = (try self.inferNodeTypeShallow(elem)) orelse return null;
                    if (!self.typesStructurallyEqual(elem_ty, next_ty)) return null;
                }
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .array = .{ .elem = elem_ty, .len = array.elements.len } };
                return ty;
            },
            .repeat_array_literal => |array| {
                const elem_ty = (try self.inferNodeTypeShallow(array.value)) orelse return null;
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .array = .{ .elem = elem_ty, .len = array.len } };
                return ty;
            },
            .struct_literal => |lit| return lit.ty,
            .borrow_expr => |borrow| {
                const inner_ty = (try self.inferNodeTypeShallow(borrow.expr)) orelse return null;
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .borrow = inner_ty };
                return ty;
            },
            .move_expr => |move| return try self.inferNodeTypeShallow(move.expr),
            .cast_expr => |cast| return cast.ty,
            else => return null,
        }
    }

    fn collectGenericBindings(
        self: *Monomorphizer,
        generic_names: []const []const u8,
        template_ty: *ast.Type,
        actual_ty: *ast.Type,
        inferred: []?*ast.Type,
    ) MonomorphizeError!bool {
        switch (template_ty.*) {
            .user_defined => |ud| {
                for (generic_names, 0..) |name, idx| {
                    if (std.mem.eql(u8, ud.name, name) and ud.generics.len == 0) {
                        if (inferred[idx]) |existing| {
                            return self.typesStructurallyEqual(existing, actual_ty);
                        }
                        inferred[idx] = actual_ty;
                        return true;
                    }
                }
                if (actual_ty.* != .user_defined) return false;
                if (!std.mem.eql(u8, ud.name, actual_ty.user_defined.name)) return false;
                if (ud.generics.len != actual_ty.user_defined.generics.len) return false;
                for (ud.generics, actual_ty.user_defined.generics) |tg, ag| {
                    if (!try self.collectGenericBindings(generic_names, tg, ag, inferred)) return false;
                }
                return true;
            },
            .pointer => |inner| {
                if (actual_ty.* != .pointer) return false;
                return try self.collectGenericBindings(generic_names, inner, actual_ty.pointer, inferred);
            },
            .borrow => |inner| {
                if (actual_ty.* != .borrow) return false;
                return try self.collectGenericBindings(generic_names, inner, actual_ty.borrow, inferred);
            },
            .array => |arr| {
                if (actual_ty.* != .array or arr.len != actual_ty.array.len) return false;
                return try self.collectGenericBindings(generic_names, arr.elem, actual_ty.array.elem, inferred);
            },
            .tuple => |tuple| {
                if (actual_ty.* != .tuple or tuple.elems.len != actual_ty.tuple.elems.len) return false;
                for (tuple.elems, actual_ty.tuple.elems) |te, ae| {
                    if (!try self.collectGenericBindings(generic_names, te, ae, inferred)) return false;
                }
                return true;
            },
            .primitive => return self.typesStructurallyEqual(template_ty, actual_ty),
            .future => |inner| {
                if (actual_ty.* != .future) return false;
                return try self.collectGenericBindings(generic_names, inner, actual_ty.future, inferred);
            },
            .closure => |closure| {
                if (actual_ty.* != .closure or closure.params.len != actual_ty.closure.params.len) return false;
                for (closure.params, actual_ty.closure.params) |tp, ap| {
                    if (!try self.collectGenericBindings(generic_names, tp, ap, inferred)) return false;
                }
                return try self.collectGenericBindings(generic_names, closure.ret, actual_ty.closure.ret, inferred);
            },
            .fn_ptr => |fn_ptr| {
                if (actual_ty.* != .fn_ptr or fn_ptr.params.len != actual_ty.fn_ptr.params.len) return false;
                if (fn_ptr.abi == null) {
                    if (actual_ty.fn_ptr.abi != null) return false;
                } else if (actual_ty.fn_ptr.abi == null or !std.mem.eql(u8, fn_ptr.abi.?, actual_ty.fn_ptr.abi.?)) {
                    return false;
                }
                for (fn_ptr.params, actual_ty.fn_ptr.params) |tp, ap| {
                    if (!try self.collectGenericBindings(generic_names, tp, ap, inferred)) return false;
                }
                return try self.collectGenericBindings(generic_names, fn_ptr.ret, actual_ty.fn_ptr.ret, inferred);
            },
            .infer => return true,
        }
    }

    fn typesStructurallyEqual(self: *Monomorphizer, a: *ast.Type, b: *ast.Type) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        switch (a.*) {
            .infer => return true,
            .primitive => return a.primitive == b.primitive,
            .pointer => return self.typesStructurallyEqual(a.pointer, b.pointer),
            .borrow => return self.typesStructurallyEqual(a.borrow, b.borrow),
            .array => return a.array.len == b.array.len and self.typesStructurallyEqual(a.array.elem, b.array.elem),
            .tuple => {
                if (a.tuple.elems.len != b.tuple.elems.len) return false;
                for (a.tuple.elems, b.tuple.elems) |ta, tb| {
                    if (!self.typesStructurallyEqual(ta, tb)) return false;
                }
                return true;
            },
            .future => return self.typesStructurallyEqual(a.future, b.future),
            .closure => {
                if (a.closure.params.len != b.closure.params.len) return false;
                for (a.closure.params, b.closure.params) |pa, pb| {
                    if (!self.typesStructurallyEqual(pa, pb)) return false;
                }
                return self.typesStructurallyEqual(a.closure.ret, b.closure.ret);
            },
            .fn_ptr => {
                if (a.fn_ptr.abi == null) {
                    if (b.fn_ptr.abi != null) return false;
                } else if (b.fn_ptr.abi == null or !std.mem.eql(u8, a.fn_ptr.abi.?, b.fn_ptr.abi.?)) {
                    return false;
                }
                if (a.fn_ptr.params.len != b.fn_ptr.params.len) return false;
                for (a.fn_ptr.params, b.fn_ptr.params) |pa, pb| {
                    if (!self.typesStructurallyEqual(pa, pb)) return false;
                }
                return self.typesStructurallyEqual(a.fn_ptr.ret, b.fn_ptr.ret);
            },
            .user_defined => {
                if (!std.mem.eql(u8, a.user_defined.name, b.user_defined.name)) return false;
                if (a.user_defined.generics.len != b.user_defined.generics.len) return false;
                for (a.user_defined.generics, b.user_defined.generics) |ga, gb| {
                    if (!self.typesStructurallyEqual(ga, gb)) return false;
                }
                return true;
            },
        }
    }

    fn specializeBlock(self: *Monomorphizer, block: []const *ast.Node) MonomorphizeError![]const *ast.Node {
        var new_block = std.ArrayList(*ast.Node).init(self.allocator);
        for (block) |stmt| {
            try new_block.append(try self.specializeNode(stmt));
        }
        return try new_block.toOwnedSlice();
    }

    fn specializeType(self: *Monomorphizer, ty: *ast.Type) MonomorphizeError!*ast.Type {
        switch (ty.*) {
            .infer => return ty,
            .primitive => return ty,
            .pointer => |inner| {
                const new_inner = try self.specializeType(inner);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .pointer = new_inner };
                return res;
            },
            .borrow => |inner| {
                const new_inner = try self.specializeType(inner);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .borrow = new_inner };
                return res;
            },
            .array => |arr| {
                const new_elem = try self.specializeType(arr.elem);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .array = .{ .elem = new_elem, .len = arr.len } };
                return res;
            },
            .tuple => |tuple| {
                var new_elems = std.ArrayList(*ast.Type).init(self.allocator);
                for (tuple.elems) |elem| {
                    try new_elems.append(try self.specializeType(elem));
                }
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .tuple = .{ .elems = try new_elems.toOwnedSlice() } };
                return res;
            },
            .future => |inner| {
                const new_inner = try self.specializeType(inner);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .future = new_inner };
                return res;
            },
            .closure => |closure| {
                var new_params = std.ArrayList(*ast.Type).init(self.allocator);
                for (closure.params) |p| {
                    try new_params.append(try self.specializeType(p));
                }
                const new_ret = try self.specializeType(closure.ret);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .closure = .{ .params = try new_params.toOwnedSlice(), .ret = new_ret } };
                return res;
            },
            .fn_ptr => |fn_ptr| {
                var new_params = std.ArrayList(*ast.Type).init(self.allocator);
                for (fn_ptr.params) |p| {
                    try new_params.append(try self.specializeType(p));
                }
                const new_ret = try self.specializeType(fn_ptr.ret);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .fn_ptr = .{ .abi = fn_ptr.abi, .params = try new_params.toOwnedSlice(), .ret = new_ret } };
                return res;
            },
            .user_defined => |ud| {
                if (ud.generics.len > 0) {
                    var spec_args = std.ArrayList(*ast.Type).init(self.allocator);
                    for (ud.generics) |g| {
                        try spec_args.append(try self.specializeType(g));
                    }
                    if (!self.struct_templates.contains(ud.name) and !self.enum_templates.contains(ud.name)) {
                        const res = try self.allocator.create(ast.Type);
                        res.* = .{
                            .user_defined = .{
                                .name = ud.name,
                                .generics = try spec_args.toOwnedSlice(),
                            },
                        };
                        return res;
                    }
                    const mangled_name = try self.getMangledStructName(ud.name, ud.generics);

                    if (self.struct_templates.get(ud.name)) |template| {
                        if (!self.specialized_structs.contains(mangled_name)) {
                            try self.instantiateStruct(mangled_name, template, ud.generics);
                        }
                    } else if (self.enum_templates.get(ud.name)) |template| {
                        if (!self.specialized_enums.contains(mangled_name)) {
                            try self.instantiateEnum(mangled_name, template, ud.generics);
                        }
                    } else {
                        return self.templateNotFound(ud.name);
                    }

                    const res = try self.allocator.create(ast.Type);
                    res.* = .{
                        .user_defined = .{
                            .name = mangled_name,
                            .generics = &.{},
                        },
                    };
                    return res;
                }
                return ty;
            },
        }
    }

    fn specializeEnumLiteralForType(
        self: *Monomorphizer,
        value: *ast.Node,
        declared_ty: *ast.Type,
        specialized_ty: *ast.Type,
    ) MonomorphizeError!*ast.Node {
        if (value.* != .enum_literal) {
            return try self.specializeNode(value);
        }
        if (declared_ty.* != .user_defined or specialized_ty.* != .user_defined) {
            return try self.specializeNode(value);
        }
        const declared_ud = declared_ty.user_defined;
        const specialized_ud = specialized_ty.user_defined;
        const lit = value.enum_literal;
        if (!std.mem.eql(u8, lit.enum_name, declared_ud.name)) {
            return try self.specializeNode(value);
        }

        var spec_fields = std.ArrayList(ast.EnumLiteralField).init(self.allocator);
        for (lit.fields) |field| {
            try spec_fields.append(.{
                .name = field.name,
                .value = try self.specializeNode(field.value),
            });
        }

        const res = try self.allocator.create(ast.Node);
        res.* = .{
            .enum_literal = .{
                .enum_name = specialized_ud.name,
                .variant_name = lit.variant_name,
                .fields = try spec_fields.toOwnedSlice(),
            },
        };
        return res;
    }

    fn getMangledStructName(self: *Monomorphizer, base: []const u8, generics: []const *ast.Type) MonomorphizeError![]const u8 {
        var name_buf = std.ArrayList(u8).init(self.allocator);
        try name_buf.appendSlice(base);
        for (generics) |g| {
            try name_buf.append('_');
            try self.appendTypeName(&name_buf, g);
        }
        return try name_buf.toOwnedSlice();
    }

    fn getMangledFuncName(self: *Monomorphizer, base: []const u8, generics: []const *ast.Type) MonomorphizeError![]const u8 {
        var name_buf = std.ArrayList(u8).init(self.allocator);
        try name_buf.appendSlice(base);
        for (generics) |g| {
            try name_buf.append('_');
            try self.appendTypeName(&name_buf, g);
        }
        return try name_buf.toOwnedSlice();
    }

    fn appendTypeName(self: *Monomorphizer, buf: *std.ArrayList(u8), ty: *ast.Type) MonomorphizeError!void {
        switch (ty.*) {
            .infer => try buf.appendSlice("infer"),
            .primitive => |p| {
                switch (p) {
                    .i8 => try buf.appendSlice("i8"),
                    .i16 => try buf.appendSlice("i16"),
                    .i32 => try buf.appendSlice("i32"),
                    .i64 => try buf.appendSlice("i64"),
                    .isize => try buf.appendSlice("isize"),
                    .u8 => try buf.appendSlice("u8"),
                    .u16 => try buf.appendSlice("u16"),
                    .u32 => try buf.appendSlice("u32"),
                    .u64 => try buf.appendSlice("u64"),
                    .usize => try buf.appendSlice("usize"),
                    .f32 => try buf.appendSlice("f32"),
                    .f64 => try buf.appendSlice("f64"),
                    .integer => try buf.appendSlice("int"),
                    .float => try buf.appendSlice("float"),
                    .boolean => try buf.appendSlice("bool"),
                    .raw_ptr => try buf.appendSlice("ptr"),
                    .void_type => try buf.appendSlice("void"),
                }
            },
            .pointer => |inner| {
                try buf.appendSlice("ptr_");
                try self.appendTypeName(buf, inner);
            },
            .borrow => |inner| {
                try buf.appendSlice("ref_");
                try self.appendTypeName(buf, inner);
            },
            .array => |arr| {
                try buf.appendSlice("arr");
                try buf.writer().print("{}", .{arr.len});
                try buf.append('_');
                try self.appendTypeName(buf, arr.elem);
            },
            .tuple => |tuple| {
                try buf.appendSlice("tuple_");
                for (tuple.elems) |elem| {
                    try self.appendTypeName(buf, elem);
                    try buf.append('_');
                }
            },
            .future => |inner| {
                try buf.appendSlice("future_");
                try self.appendTypeName(buf, inner);
            },
            .closure => |closure| {
                try buf.appendSlice("closure_");
                for (closure.params) |p| {
                    try self.appendTypeName(buf, p);
                    try buf.append('_');
                }
                try self.appendTypeName(buf, closure.ret);
            },
            .fn_ptr => |fn_ptr| {
                try buf.appendSlice("fnptr_");
                if (fn_ptr.abi) |abi| {
                    try buf.appendSlice(abi);
                    try buf.append('_');
                }
                for (fn_ptr.params) |p| {
                    try self.appendTypeName(buf, p);
                    try buf.append('_');
                }
                try self.appendTypeName(buf, fn_ptr.ret);
            },
            .user_defined => |ud| {
                try buf.appendSlice(ud.name);
                for (ud.generics) |g| {
                    try buf.append('_');
                    try self.appendTypeName(buf, g);
                }
            },
        }
    }

    fn instantiateStruct(self: *Monomorphizer, mangled_name: []const u8, template: *ast.StructDecl, args: []const *ast.Type) MonomorphizeError!void {
        // Record specialization
        try self.specialized_structs.put(mangled_name, try self.allocator.dupe(u8, mangled_name));

        // Create specialized fields
        var spec_fields = std.ArrayList(ast.Field).init(self.allocator);
        for (template.fields) |f| {
            const spec_ty = try self.substituteType(f.ty, template.generics, args);
            const fully_spec_ty = try self.specializeType(spec_ty);
            try spec_fields.append(.{
                .name = f.name,
                .ty = fully_spec_ty,
            });
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .struct_decl = .{
                .name = mangled_name,
                .derives = template.derives,
                .generics = &.{},
                .fields = try spec_fields.toOwnedSlice(),
                .is_union = template.is_union,
                .is_opaque = template.is_opaque,
            },
        };
        try self.new_decls.append(node);
        try self.instantiateGenericImpls(template.name, mangled_name, args);
    }

    fn instantiateEnum(self: *Monomorphizer, mangled_name: []const u8, template: *ast.EnumDecl, args: []const *ast.Type) MonomorphizeError!void {
        try self.specialized_enums.put(mangled_name, try self.allocator.dupe(u8, mangled_name));

        var spec_variants = std.ArrayList(ast.EnumVariant).init(self.allocator);
        for (template.variants) |variant| {
            var spec_fields = std.ArrayList(ast.Field).init(self.allocator);
            for (variant.fields) |field| {
                const spec_ty = try self.substituteType(field.ty, template.generics, args);
                const fully_spec_ty = try self.specializeType(spec_ty);
                try spec_fields.append(.{
                    .name = field.name,
                    .ty = fully_spec_ty,
                });
            }
            try spec_variants.append(.{
                .name = variant.name,
                .fields = try spec_fields.toOwnedSlice(),
            });
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .enum_decl = .{
                .name = mangled_name,
                .generics = &.{},
                .variants = try spec_variants.toOwnedSlice(),
            },
        };
        try self.new_decls.append(node);
        try self.instantiateGenericImpls(template.name, mangled_name, args);
    }

    fn instantiateFunction(self: *Monomorphizer, mangled_name: []const u8, template: *ast.FuncDecl, args: []const *ast.Type) MonomorphizeError!void {
        // Record specialization
        try self.specialized_funcs.put(mangled_name, try self.allocator.dupe(u8, mangled_name));

        // Create specialized params
        var spec_params = std.ArrayList(ast.Param).init(self.allocator);
        for (template.params) |p| {
            const spec_ty = try self.substituteType(p.ty, template.generics, args);
            const fully_spec_ty = try self.specializeType(spec_ty);
            try spec_params.append(.{
                .name = p.name,
                .ty = fully_spec_ty,
                .is_borrow = p.is_borrow,
                .is_move = p.is_move,
            });
        }

        const spec_ret_ty = try self.substituteType(template.ret_ty, template.generics, args);
        const fully_spec_ret_ty = try self.specializeType(spec_ret_ty);

        // Substitute inside block
        const spec_body = try self.substituteBlock(template.body, template.generics, args);
        const fully_spec_body = try self.specializeBlock(spec_body);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .func_decl = .{
                .name = mangled_name,
                .is_pub = template.is_pub,
                .is_extern = template.is_extern,
                .abi = template.abi,
                .no_mangle = template.no_mangle,
                .is_decl_only = template.is_decl_only,
                .generics = &.{},
                .params = try spec_params.toOwnedSlice(),
                .ret_ty = fully_spec_ret_ty,
                .body = fully_spec_body,
                .is_inline = template.is_inline,
                .is_async = template.is_async,
                .operator = template.operator,
            },
        };
        try self.new_decls.append(node);
    }

    fn substituteType(self: *Monomorphizer, ty: *ast.Type, params: []const []const u8, args: []const *ast.Type) MonomorphizeError!*ast.Type {
        switch (ty.*) {
            .infer => return ty,
            .primitive => return ty,
            .pointer => |inner| {
                const spec_inner = try self.substituteType(inner, params, args);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .pointer = spec_inner };
                return res;
            },
            .borrow => |inner| {
                const spec_inner = try self.substituteType(inner, params, args);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .borrow = spec_inner };
                return res;
            },
            .array => |arr| {
                const spec_elem = try self.substituteType(arr.elem, params, args);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .array = .{ .elem = spec_elem, .len = arr.len } };
                return res;
            },
            .tuple => |tuple| {
                var spec_elems = std.ArrayList(*ast.Type).init(self.allocator);
                for (tuple.elems) |elem| {
                    try spec_elems.append(try self.substituteType(elem, params, args));
                }
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .tuple = .{ .elems = try spec_elems.toOwnedSlice() } };
                return res;
            },
            .future => |inner| {
                const spec_inner = try self.substituteType(inner, params, args);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .future = spec_inner };
                return res;
            },
            .closure => |closure| {
                var spec_params = std.ArrayList(*ast.Type).init(self.allocator);
                for (closure.params) |p| {
                    try spec_params.append(try self.substituteType(p, params, args));
                }
                const spec_ret = try self.substituteType(closure.ret, params, args);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .closure = .{ .params = try spec_params.toOwnedSlice(), .ret = spec_ret } };
                return res;
            },
            .fn_ptr => |fn_ptr| {
                var spec_params = std.ArrayList(*ast.Type).init(self.allocator);
                for (fn_ptr.params) |p| {
                    try spec_params.append(try self.substituteType(p, params, args));
                }
                const spec_ret = try self.substituteType(fn_ptr.ret, params, args);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .fn_ptr = .{ .abi = fn_ptr.abi, .params = try spec_params.toOwnedSlice(), .ret = spec_ret } };
                return res;
            },
            .user_defined => |ud| {
                // Check if this type matches one of the generic parameters
                for (params, args) |p, arg| {
                    if (std.mem.eql(u8, ud.name, p)) {
                        return arg;
                    }
                }

                // If not, recursively substitute its generic arguments
                var spec_args = std.ArrayList(*ast.Type).init(self.allocator);
                for (ud.generics) |g| {
                    try spec_args.append(try self.substituteType(g, params, args));
                }
                const res = try self.allocator.create(ast.Type);
                res.* = .{
                    .user_defined = .{
                        .name = ud.name,
                        .generics = try spec_args.toOwnedSlice(),
                    },
                };
                return res;
            },
        }
    }

    fn substituteBlock(self: *Monomorphizer, block: []const *ast.Node, params: []const []const u8, args: []const *ast.Type) MonomorphizeError![]const *ast.Node {
        var spec_block = std.ArrayList(*ast.Node).init(self.allocator);
        for (block) |stmt| {
            try spec_block.append(try self.substituteNode(stmt, params, args));
        }
        return try spec_block.toOwnedSlice();
    }

    fn substituteNode(self: *Monomorphizer, node: *ast.Node, params: []const []const u8, args: []const *ast.Type) MonomorphizeError!*ast.Node {
        switch (node.*) {
            .program => unreachable,
            .struct_decl => unreachable,
            .enum_decl => unreachable,
            .trait_decl => unreachable,
            .type_alias_decl => unreachable,
            .overload_decl => unreachable,
            .impl_decl => unreachable,
            .func_decl => |f| {
                var spec_params = std.ArrayList(ast.Param).init(self.allocator);
                for (f.params) |p| {
                    try spec_params.append(.{
                        .name = p.name,
                        .ty = try self.substituteType(p.ty, params, args),
                        .is_borrow = p.is_borrow,
                        .is_move = p.is_move,
                    });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .func_decl = .{
                        .name = f.name,
                        .is_pub = f.is_pub,
                        .is_extern = f.is_extern,
                        .abi = f.abi,
                        .no_mangle = f.no_mangle,
                        .is_decl_only = f.is_decl_only,
                        .generics = &.{},
                        .params = try spec_params.toOwnedSlice(),
                        .ret_ty = try self.substituteType(f.ret_ty, params, args),
                        .body = try self.substituteBlock(f.body, params, args),
                        .is_inline = f.is_inline,
                        .is_async = f.is_async,
                        .operator = f.operator,
                    },
                };
                return res;
            },
            .macro_decl => unreachable,
            .import_decl => unreachable,
            .using_decl => unreachable,
            .test_decl => unreachable,
            .let_stmt => |let| {
                const spec_ty = if (let.ty) |ty| try self.substituteType(ty, params, args) else null;
                const spec_val = try self.substituteNode(let.value, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .let_stmt = .{
                        .name = let.name,
                        .ty = spec_ty,
                        .value = spec_val,
                    },
                };
                return res;
            },
            .let_else_stmt => |let| {
                const spec_val = try self.substituteNode(let.value, params, args);
                const spec_else = try self.substituteBlock(let.else_block, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .let_else_stmt = .{ .pattern = let.pattern, .value = spec_val, .else_block = spec_else } };
                return res;
            },
            .let_destructure_stmt => |let| {
                const spec_val = try self.substituteNode(let.value, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .let_destructure_stmt = .{ .names = let.names, .value = spec_val, .rest_name = let.rest_name, .is_slice = let.is_slice } };
                return res;
            },
            .const_stmt => |c| {
                const spec_ty = if (c.ty) |ty| try self.substituteType(ty, params, args) else null;
                const spec_val = try self.substituteNode(c.value, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .const_stmt = .{
                        .name = c.name,
                        .ty = spec_ty,
                        .value = spec_val,
                    },
                };
                return res;
            },
            .var_stmt => |v| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .var_stmt = .{ .name = v.name, .ty = try self.substituteType(v.ty, params, args) } };
                return res;
            },
            .assign_stmt => |assign| {
                const spec_target = try self.substituteNode(assign.target, params, args);
                const spec_val = try self.substituteNode(assign.value, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .assign_stmt = .{
                        .target = spec_target,
                        .value = spec_val,
                    },
                };
                return res;
            },
            .block_stmt => |blk| {
                const spec_body = try self.substituteBlock(blk.body, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .block_stmt = .{ .body = spec_body } };
                return res;
            },
            .expr_stmt => |expr| {
                const spec_expr = try self.substituteNode(expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .expr_stmt = spec_expr };
                return res;
            },
            .return_stmt => |ret| {
                const spec_val = if (ret.value) |v| try self.substituteNode(v, params, args) else null;
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .return_stmt = .{ .value = spec_val } };
                return res;
            },
            .for_stmt => |f| {
                const spec_start = try self.substituteNode(f.start, params, args);
                const spec_end = if (f.end) |end_expr| try self.substituteNode(end_expr, params, args) else null;
                const spec_body = try self.substituteBlock(f.body, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .for_stmt = .{
                        .var_name = f.var_name,
                        .start = spec_start,
                        .end = spec_end,
                        .body = spec_body,
                    },
                };
                return res;
            },
            .while_stmt => |w| {
                const spec_cond = try self.substituteNode(w.cond, params, args);
                const spec_body = try self.substituteBlock(w.body, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .while_stmt = .{
                        .cond = spec_cond,
                        .let_pattern = w.let_pattern,
                        .body = spec_body,
                    },
                };
                return res;
            },
            .break_stmt => {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .break_stmt = .{} };
                return res;
            },
            .continue_stmt => {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .continue_stmt = .{} };
                return res;
            },
            .release_stmt => |rel| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .release_stmt = .{ .var_name = rel.var_name } };
                return res;
            },
            .literal => |lit| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .literal = lit };
                return res;
            },
            .identifier => |name| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .identifier = name };
                return res;
            },
            .generic_func_ref => |ref| {
                var spec_generics = std.ArrayList(*ast.Type).init(self.allocator);
                for (ref.generics) |g| {
                    try spec_generics.append(try self.substituteType(g, params, args));
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .generic_func_ref = .{ .func_name = ref.func_name, .generics = try spec_generics.toOwnedSlice() } };
                return res;
            },
            .if_expr => |ife| {
                const spec_cond = try self.substituteNode(ife.cond, params, args);
                var spec_chain: ?[]const ast.IfLetCond = null;
                if (ife.let_chain) |chain| {
                    var items = std.ArrayList(ast.IfLetCond).init(self.allocator);
                    for (chain) |cond| {
                        try items.append(.{ .pattern = cond.pattern, .value = try self.substituteNode(cond.value, params, args) });
                    }
                    spec_chain = try items.toOwnedSlice();
                }
                const spec_then = try self.substituteBlock(ife.then_block, params, args);
                const spec_else = if (ife.else_block) |eb| try self.substituteBlock(eb, params, args) else null;
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .if_expr = .{
                        .cond = spec_cond,
                        .let_chain = spec_chain,
                        .then_block = spec_then,
                        .else_block = spec_else,
                    },
                };
                return res;
            },
            .switch_expr => |swe| {
                const spec_val = try self.substituteNode(swe.val, params, args);
                var spec_cases = std.ArrayList(ast.Case).init(self.allocator);
                for (swe.cases) |case| {
                    const spec_pattern = try self.substituteNode(case.pattern, params, args);
                    const spec_body = try self.substituteBlock(case.body, params, args);
                    try spec_cases.append(.{ .pattern = spec_pattern, .body = spec_body });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .switch_expr = .{
                        .val = spec_val,
                        .cases = try spec_cases.toOwnedSlice(),
                    },
                };
                return res;
            },
            .match_expr => |mat| {
                const spec_val = try self.substituteNode(mat.val, params, args);
                var spec_cases = std.ArrayList(ast.MatchCase).init(self.allocator);
                for (mat.cases) |case| {
                    const spec_guard = if (case.guard) |guard| try self.substituteNode(guard, params, args) else null;
                    const spec_body = try self.substituteBlock(case.body, params, args);
                    try spec_cases.append(.{ .pattern = case.pattern, .guard = spec_guard, .body = spec_body });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .match_expr = .{ .val = spec_val, .cases = try spec_cases.toOwnedSlice() } };
                return res;
            },
            .unsafe_expr => |ue| {
                const spec_body = try self.substituteBlock(ue.body, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .unsafe_expr = .{ .body = spec_body } };
                return res;
            },
            .await_expr => |aw| {
                const spec_expr = try self.substituteNode(aw.expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .await_expr = .{ .expr = spec_expr } };
                return res;
            },
            .inline_asm_expr => |asm_expr| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .inline_asm_expr = .{ .template = asm_expr.template, .operands = asm_expr.operands } };
                return res;
            },
            .binary_expr => |bin| {
                const spec_left = try self.substituteNode(bin.left, params, args);
                const spec_right = try self.substituteNode(bin.right, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .binary_expr = .{
                        .op = bin.op,
                        .left = spec_left,
                        .right = spec_right,
                    },
                };
                return res;
            },
            .borrow_expr => |borrow| {
                const spec_expr = try self.substituteNode(borrow.expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .borrow_expr = .{ .expr = spec_expr } };
                return res;
            },
            .move_expr => |move| {
                const spec_expr = try self.substituteNode(move.expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .move_expr = .{ .expr = spec_expr } };
                return res;
            },
            .deref_expr => |deref| {
                const spec_expr = try self.substituteNode(deref.expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .deref_expr = .{ .expr = spec_expr } };
                return res;
            },
            .cast_expr => |cast| {
                const spec_expr = try self.substituteNode(cast.expr, params, args);
                const spec_ty = try self.substituteType(cast.ty, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .cast_expr = .{ .expr = spec_expr, .ty = spec_ty } };
                return res;
            },
            .field_expr => |field| {
                const spec_expr = try self.substituteNode(field.expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .field_expr = .{
                        .expr = spec_expr,
                        .field_name = field.field_name,
                    },
                };
                return res;
            },
            .struct_literal => |lit| {
                const spec_ty = try self.substituteType(lit.ty, params, args);
                var spec_fields = std.ArrayList(ast.StructLiteralField).init(self.allocator);
                for (lit.fields) |field| {
                    try spec_fields.append(.{
                        .name = field.name,
                        .value = try self.substituteNode(field.value, params, args),
                    });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .struct_literal = .{
                        .ty = spec_ty,
                        .fields = try spec_fields.toOwnedSlice(),
                        .update_expr = if (lit.update_expr) |update_expr| try self.substituteNode(update_expr, params, args) else null,
                    },
                };
                return res;
            },
            .enum_literal => |lit| {
                var spec_fields = std.ArrayList(ast.EnumLiteralField).init(self.allocator);
                for (lit.fields) |field| {
                    try spec_fields.append(.{ .name = field.name, .value = try self.substituteNode(field.value, params, args) });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .enum_literal = .{ .enum_name = lit.enum_name, .variant_name = lit.variant_name, .fields = try spec_fields.toOwnedSlice() } };
                return res;
            },
            .closure_literal => |lit| {
                var spec_params = std.ArrayList(ast.Param).init(self.allocator);
                for (lit.params) |p| {
                    try spec_params.append(.{ .name = p.name, .ty = try self.substituteType(p.ty, params, args), .is_borrow = p.is_borrow, .is_move = p.is_move });
                }
                const spec_body = try self.substituteNode(lit.body, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .closure_literal = .{ .params = try spec_params.toOwnedSlice(), .body = spec_body } };
                return res;
            },
            .array_literal => |lit| {
                var spec_elements = std.ArrayList(*ast.Node).init(self.allocator);
                for (lit.elements) |elem| {
                    try spec_elements.append(try self.substituteNode(elem, params, args));
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .array_literal = .{ .elements = try spec_elements.toOwnedSlice() } };
                return res;
            },
            .repeat_array_literal => |lit| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .repeat_array_literal = .{ .value = try self.substituteNode(lit.value, params, args), .len = lit.len } };
                return res;
            },
            .tuple_literal => |lit| {
                var spec_elements = std.ArrayList(*ast.Node).init(self.allocator);
                for (lit.elements) |elem| {
                    try spec_elements.append(try self.substituteNode(elem, params, args));
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .tuple_literal = .{ .elements = try spec_elements.toOwnedSlice() } };
                return res;
            },
            .index_expr => |idx| {
                const spec_target = try self.substituteNode(idx.target, params, args);
                const spec_index = try self.substituteNode(idx.index, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .index_expr = .{ .target = spec_target, .index = spec_index } };
                return res;
            },
            .slice_expr => |slc| {
                const spec_target = try self.substituteNode(slc.target, params, args);
                const spec_start = try self.substituteNode(slc.start, params, args);
                const spec_end = try self.substituteNode(slc.end, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .slice_expr = .{ .target = spec_target, .start = spec_start, .end = spec_end } };
                return res;
            },
            .try_expr => |trye| {
                const spec_expr = try self.substituteNode(trye.expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .try_expr = .{ .expr = spec_expr } };
                return res;
            },
            .call_expr => |call| {
                var spec_generics = std.ArrayList(*ast.Type).init(self.allocator);
                for (call.generics) |g| {
                    try spec_generics.append(try self.substituteType(g, params, args));
                }
                var spec_args = std.ArrayList(*ast.Node).init(self.allocator);
                for (call.args) |arg| {
                    try spec_args.append(try self.substituteNode(arg, params, args));
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .call_expr = .{
                        .func_name = call.func_name,
                        .associated_target = call.associated_target,
                        .generics = try spec_generics.toOwnedSlice(),
                        .args = try spec_args.toOwnedSlice(),
                    },
                };
                return res;
            },
        }
    }
};

test "monomorphize generic struct" {
    const source =
        \\struct Option<T> {
        \\    has_value: bool,
        \\    value: T
        \\}
        \\fn process(opt: Option<i32>) -> i32 {
        \\    return opt.value;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser_mod = @import("parser.zig");
    var p = parser_mod.Parser.init(arena.allocator(), source);
    const prog = try p.parseProgram();

    var mono = Monomorphizer.init(arena.allocator());
    defer mono.deinit();

    const specialized_prog = try mono.monomorphize(prog, null, null);

    // Verify that Option_i32 struct decl was generated
    try std.testing.expect(specialized_prog.* == .program);
    var found_option_int = false;
    for (specialized_prog.program.decls) |decl| {
        if (decl.* == .struct_decl) {
            if (std.mem.eql(u8, decl.struct_decl.name, "Option_i32")) {
                found_option_int = true;
                try std.testing.expectEqual(@as(usize, 2), decl.struct_decl.fields.len);
            }
        }
    }
    try std.testing.expect(found_option_int);
}
