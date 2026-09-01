const std = @import("std");
const ast = @import("ast.zig");
const lowering_rules = @import("lowering_rules.zig");
const type_checker_mod = @import("type_checker.zig");
const plugin_imports = @import("plugin_imports.zig");
const plugin_module_table = @import("plugin_module_table.zig");
const plugin_compile_options = @import("plugin_compile_options.zig");

const moduleNamespaceFromImportPath = plugin_imports.moduleNamespaceFromImportPath;
const moduleNamespaceMatchesImportPath = plugin_imports.moduleNamespaceMatchesImportPath;
const splitImportedMangledSymbol = plugin_imports.splitImportedMangledSymbol;
const SlaModule = plugin_module_table.SlaModule;
const SlaModuleTable = plugin_module_table.SlaModuleTable;
const SlaImportExpansionOptions = plugin_module_table.SlaImportExpansionOptions;

pub const UnresolvedCallableKind = enum {
    direct,
    associated,
    imported_macro,
};

pub const UnresolvedCallable = struct {
    kind: UnresolvedCallableKind,
    name: []const u8,
    caller_name: ?[]const u8,
    receiver_type_name: ?[]const u8,
    resolved: bool = false,
};

pub const UnresolvedCallableSet = struct {
    records: std.ArrayList(UnresolvedCallable),
    record_indices_by_name: std.StringHashMap(std.ArrayList(usize)),

    pub fn init(allocator: std.mem.Allocator) UnresolvedCallableSet {
        return .{
            .records = std.ArrayList(UnresolvedCallable).init(allocator),
            .record_indices_by_name = std.StringHashMap(std.ArrayList(usize)).init(allocator),
        };
    }

    pub fn deinit(self: *UnresolvedCallableSet) void {
        var indices_iter = self.record_indices_by_name.valueIterator();
        while (indices_iter.next()) |indices| indices.deinit();
        self.record_indices_by_name.deinit();
        self.records.deinit();
    }

    fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.mem.eql(u8, a.?, b.?);
    }

    pub fn record(
        self: *UnresolvedCallableSet,
        kind: UnresolvedCallableKind,
        name: []const u8,
        caller_name: ?[]const u8,
        receiver_type_name: ?[]const u8,
    ) !void {
        const entry = try self.record_indices_by_name.getOrPut(name);
        if (!entry.found_existing) entry.value_ptr.* = std.ArrayList(usize).init(self.records.allocator);
        for (entry.value_ptr.items) |record_index| {
            const recorded = self.records.items[record_index];
            if (recorded.kind != kind) continue;
            if (!optionalStringEqual(recorded.caller_name, caller_name)) continue;
            if (!optionalStringEqual(recorded.receiver_type_name, receiver_type_name)) continue;
            return;
        }
        const record_index = self.records.items.len;
        try self.records.append(.{
            .kind = kind,
            .name = name,
            .caller_name = caller_name,
            .receiver_type_name = receiver_type_name,
        });
        try entry.value_ptr.append(record_index);
    }
};

pub const SlaCallableIndex = struct {
    allocator: std.mem.Allocator,
    names: std.StringHashMap(void),
    decls: std.StringHashMap(*ast.FuncDecl),
    const_decls: std.StringHashMap(*ast.ConstStmt),
    macro_decls: std.StringHashMap(*ast.MacroDecl),
    type_decls: std.StringHashMap(*ast.Node),
    module_sources: std.StringHashMap([]const u8),
    associated_candidates: std.StringHashMap(std.ArrayList([]const u8)),
    unresolved_callables: ?*UnresolvedCallableSet,

    pub fn init(allocator: std.mem.Allocator) SlaCallableIndex {
        return .{
            .allocator = allocator,
            .names = std.StringHashMap(void).init(allocator),
            .decls = std.StringHashMap(*ast.FuncDecl).init(allocator),
            .const_decls = std.StringHashMap(*ast.ConstStmt).init(allocator),
            .macro_decls = std.StringHashMap(*ast.MacroDecl).init(allocator),
            .type_decls = std.StringHashMap(*ast.Node).init(allocator),
            .module_sources = std.StringHashMap([]const u8).init(allocator),
            .associated_candidates = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .unresolved_callables = null,
        };
    }

    pub fn deinit(self: *SlaCallableIndex) void {
        var candidates = self.associated_candidates.valueIterator();
        while (candidates.next()) |list| list.deinit();
        self.associated_candidates.deinit();
        self.module_sources.deinit();
        self.type_decls.deinit();
        self.macro_decls.deinit();
        self.const_decls.deinit();
        self.decls.deinit();
        self.names.deinit();
    }

    pub fn recordFunction(self: *SlaCallableIndex, name: []const u8, fd: *ast.FuncDecl, module_path: ?[]const u8) !void {
        try self.names.put(name, {});
        const decl_entry = try self.decls.getOrPut(name);
        if (!decl_entry.found_existing) decl_entry.value_ptr.* = fd;
        if (module_path) |mp| {
            const src_entry = try self.module_sources.getOrPut(name);
            if (!src_entry.found_existing) src_entry.value_ptr.* = mp;
        }
        try self.addFlattenedSuffixCandidates(name);
    }

    pub fn addFunction(self: *SlaCallableIndex, name: []const u8, fd: *ast.FuncDecl) !void {
        try self.recordFunction(name, fd, null);
    }

    pub fn addAssociatedFunctionWithModule(
        self: *SlaCallableIndex,
        method_name: []const u8,
        symbol: []const u8,
        fd: *ast.FuncDecl,
        module_path: ?[]const u8,
    ) !void {
        try self.recordFunction(symbol, fd, module_path);
        try self.addAssociatedCandidate(method_name, symbol);
    }

    pub fn moduleSource(self: *const SlaCallableIndex, name: []const u8) ?[]const u8 {
        return self.module_sources.get(name);
    }

    pub fn addAssociatedFunction(self: *SlaCallableIndex, method_name: []const u8, symbol: []const u8, fd: *ast.FuncDecl) !void {
        try self.addFunction(symbol, fd);
        try self.addAssociatedCandidate(method_name, symbol);
    }

    pub fn addAssociatedCandidate(self: *SlaCallableIndex, method_name: []const u8, symbol: []const u8) !void {
        const entry = try self.associated_candidates.getOrPut(method_name);
        if (!entry.found_existing) entry.value_ptr.* = std.ArrayList([]const u8).init(self.allocator);
        try entry.value_ptr.append(symbol);
    }

    pub fn addFlattenedSuffixCandidates(self: *SlaCallableIndex, symbol: []const u8) !void {
        for (symbol, 0..) |ch, index| {
            if (ch != '_' and ch != ':') continue;
            if (index + 1 >= symbol.len) continue;
            if (symbol[index + 1] == '_' or symbol[index + 1] == ':') continue;
            try self.addAssociatedCandidate(symbol[index + 1 ..], symbol);
        }
    }

    pub fn recordUnresolvedCallable(
        self: *const SlaCallableIndex,
        kind: UnresolvedCallableKind,
        name: []const u8,
        caller_name: ?[]const u8,
        receiver_type_name: ?[]const u8,
    ) !void {
        if (self.unresolved_callables) |records| try records.record(kind, name, caller_name, receiver_type_name);
    }

    pub fn addDecls(self: *SlaCallableIndex, decls: []const *ast.Node) !void {
        try self.addDeclsFromModule(decls, null);
    }

    pub fn addDeclsFromModule(self: *SlaCallableIndex, decls: []const *ast.Node, module: ?*const SlaModule) !void {
        const module_path = if (module) |m| m.path else null;
        const namespace = if (module) |m| try moduleNamespaceFromImportPath(self.allocator, m.output_path) else null;
        for (decls) |decl| {
            switch (decl.*) {
                .func_decl => {
                    try self.recordFunction(decl.func_decl.name, &decl.func_decl, module_path);
                    if (namespace) |ns| {
                        const alias = try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ ns, decl.func_decl.name });
                        try self.recordFunction(alias, &decl.func_decl, module_path);
                    }
                },
                .const_stmt => {
                    const entry = try self.const_decls.getOrPut(decl.const_stmt.name);
                    if (!entry.found_existing) entry.value_ptr.* = &decl.const_stmt;
                },
                .macro_decl => {
                    const entry = try self.macro_decls.getOrPut(decl.macro_decl.name);
                    if (!entry.found_existing) entry.value_ptr.* = &decl.macro_decl;
                },
                .struct_decl => {
                    const entry = try self.type_decls.getOrPut(decl.struct_decl.name);
                    if (!entry.found_existing) entry.value_ptr.* = decl;
                },
                .enum_decl => {
                    const entry = try self.type_decls.getOrPut(decl.enum_decl.name);
                    if (!entry.found_existing) entry.value_ptr.* = decl;
                },
                .trait_decl => {
                    const entry = try self.type_decls.getOrPut(decl.trait_decl.name);
                    if (!entry.found_existing) entry.value_ptr.* = decl;
                },
                .type_alias_decl => {
                    const entry = try self.type_decls.getOrPut(decl.type_alias_decl.name);
                    if (!entry.found_existing) entry.value_ptr.* = decl;
                },
                .impl_decl => |impl_decl| {
                    const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                    for (impl_decl.methods) |method| {
                        if (method.* != .func_decl) continue;
                        const symbol = if (impl_decl.trait_name) |trait_name|
                            try lowering_rules.mangleTraitMethodName(self.allocator, type_name, trait_name, method.func_decl.name)
                        else
                            try lowering_rules.mangleMethodName(self.allocator, type_name, method.func_decl.name);
                        try self.addAssociatedFunctionWithModule(method.func_decl.name, symbol, &method.func_decl, module_path);
                    }
                },
                .overload_decl => |overload_decl| {
                    const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                    for (overload_decl.methods) |method| {
                        if (method.* != .func_decl) continue;
                        const symbol = try lowering_rules.mangleMethodName(self.allocator, type_name, method.func_decl.name);
                        try self.addAssociatedFunctionWithModule(method.func_decl.name, symbol, &method.func_decl, module_path);
                    }
                },
                else => {},
            }
        }
    }

    fn refreshFunctionDecl(self: *SlaCallableIndex, name: []const u8, fd: *ast.FuncDecl, module_path: ?[]const u8) !void {
        if (self.decls.getPtr(name)) |decl_ptr| {
            decl_ptr.* = fd;
            return;
        }
        try self.recordFunction(name, fd, module_path);
    }

    /// A selected-body reparse replaces a module's AST while preserving its
    /// declaration surface. Refresh only the declaration pointers: names,
    /// module ownership, and associated-candidate indexes were already built
    /// from the decl-only parse and do not need to be rebuilt.
    pub fn refreshDeclsFromModule(self: *SlaCallableIndex, module: *const SlaModule) !void {
        const namespace = try moduleNamespaceFromImportPath(self.allocator, module.output_path);
        defer self.allocator.free(namespace);
        for (module.program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => {
                    try self.refreshFunctionDecl(decl.func_decl.name, &decl.func_decl, module.path);
                    const alias = try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ namespace, decl.func_decl.name });
                    if (self.decls.getPtr(alias)) |decl_ptr| {
                        decl_ptr.* = &decl.func_decl;
                        self.allocator.free(alias);
                    } else {
                        try self.recordFunction(alias, &decl.func_decl, module.path);
                    }
                },
                .const_stmt => {
                    if (self.const_decls.getPtr(decl.const_stmt.name)) |decl_ptr| {
                        decl_ptr.* = &decl.const_stmt;
                    } else {
                        try self.const_decls.put(decl.const_stmt.name, &decl.const_stmt);
                    }
                },
                .macro_decl => {
                    if (self.macro_decls.getPtr(decl.macro_decl.name)) |decl_ptr| {
                        decl_ptr.* = &decl.macro_decl;
                    } else {
                        try self.macro_decls.put(decl.macro_decl.name, &decl.macro_decl);
                    }
                },
                .struct_decl => try self.refreshTypeDecl(decl.struct_decl.name, decl),
                .enum_decl => try self.refreshTypeDecl(decl.enum_decl.name, decl),
                .trait_decl => try self.refreshTypeDecl(decl.trait_decl.name, decl),
                .type_alias_decl => try self.refreshTypeDecl(decl.type_alias_decl.name, decl),
                .impl_decl => |impl_decl| {
                    const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                    for (impl_decl.methods) |method| {
                        if (method.* != .func_decl) continue;
                        const symbol = if (impl_decl.trait_name) |trait_name|
                            try lowering_rules.mangleTraitMethodName(self.allocator, type_name, trait_name, method.func_decl.name)
                        else
                            try lowering_rules.mangleMethodName(self.allocator, type_name, method.func_decl.name);
                        defer self.allocator.free(symbol);
                        const decl_ptr = self.decls.getPtr(symbol) orelse return error.InvalidModuleReparseSurface;
                        decl_ptr.* = &method.func_decl;
                    }
                },
                .overload_decl => |overload_decl| {
                    const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                    for (overload_decl.methods) |method| {
                        if (method.* != .func_decl) continue;
                        const symbol = try lowering_rules.mangleMethodName(self.allocator, type_name, method.func_decl.name);
                        defer self.allocator.free(symbol);
                        const decl_ptr = self.decls.getPtr(symbol) orelse return error.InvalidModuleReparseSurface;
                        decl_ptr.* = &method.func_decl;
                    }
                },
                else => {},
            }
        }
    }

    fn refreshTypeDecl(self: *SlaCallableIndex, name: []const u8, decl: *ast.Node) !void {
        if (self.type_decls.getPtr(name)) |decl_ptr| {
            decl_ptr.* = decl;
        } else {
            try self.type_decls.put(name, decl);
        }
    }
};

pub const SyntacticFactSet = struct {
    allocator: std.mem.Allocator,
    no_import_sources: std.StringHashMap(void),
    zero_import_scans: std.StringHashMap(void),
    known_int_fields: std.StringHashMap(i64),
    known_bool_fields: std.StringHashMap(bool),
    local_types: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) SyntacticFactSet {
        return .{
            .allocator = allocator,
            .no_import_sources = std.StringHashMap(void).init(allocator),
            .zero_import_scans = std.StringHashMap(void).init(allocator),
            .known_int_fields = std.StringHashMap(i64).init(allocator),
            .known_bool_fields = std.StringHashMap(bool).init(allocator),
            .local_types = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *SyntacticFactSet) void {
        self.no_import_sources.deinit();
        self.zero_import_scans.deinit();
        var int_iter = self.known_int_fields.iterator();
        while (int_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.known_int_fields.deinit();
        var bool_iter = self.known_bool_fields.iterator();
        while (bool_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.known_bool_fields.deinit();
        self.local_types.deinit();
    }

    pub fn clone(self: *const SyntacticFactSet) !SyntacticFactSet {
        var out = SyntacticFactSet.init(self.allocator);
        errdefer out.deinit();
        var source_iter = self.no_import_sources.keyIterator();
        while (source_iter.next()) |key| try out.no_import_sources.put(key.*, {});
        var scan_iter = self.zero_import_scans.keyIterator();
        while (scan_iter.next()) |key| try out.zero_import_scans.put(key.*, {});
        var int_iter = self.known_int_fields.iterator();
        while (int_iter.next()) |entry| {
            const key = try out.allocator.dupe(u8, entry.key_ptr.*);
            errdefer out.allocator.free(key);
            try out.putKnownIntKey(key, entry.value_ptr.*);
        }
        var bool_iter = self.known_bool_fields.iterator();
        while (bool_iter.next()) |entry| {
            const key = try out.allocator.dupe(u8, entry.key_ptr.*);
            errdefer out.allocator.free(key);
            try out.putKnownBoolKey(key, entry.value_ptr.*);
        }
        var type_iter = self.local_types.iterator();
        while (type_iter.next()) |entry| try out.local_types.put(entry.key_ptr.*, entry.value_ptr.*);
        return out;
    }

    pub fn clearName(self: *SyntacticFactSet, name: []const u8) void {
        _ = self.no_import_sources.remove(name);
        _ = self.zero_import_scans.remove(name);
        _ = self.local_types.remove(name);
        self.clearKnownFieldsForName(name);
    }

    pub fn fieldKey(self: *SyntacticFactSet, name: []const u8, field_name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, field_name });
    }

    pub fn clearKnownFieldsForName(self: *SyntacticFactSet, name: []const u8) void {
        while (true) {
            var removed = false;
            var int_iter = self.known_int_fields.iterator();
            while (int_iter.next()) |entry| {
                if (!fieldFactKeyMatchesName(entry.key_ptr.*, name)) continue;
                const key = entry.key_ptr.*;
                _ = self.known_int_fields.remove(key);
                self.allocator.free(key);
                removed = true;
                break;
            }
            if (!removed) break;
        }
        while (true) {
            var removed = false;
            var bool_iter = self.known_bool_fields.iterator();
            while (bool_iter.next()) |entry| {
                if (!fieldFactKeyMatchesName(entry.key_ptr.*, name)) continue;
                const key = entry.key_ptr.*;
                _ = self.known_bool_fields.remove(key);
                self.allocator.free(key);
                removed = true;
                break;
            }
            if (!removed) break;
        }
    }

    pub fn clearKnownField(self: *SyntacticFactSet, name: []const u8, field_name: []const u8) !void {
        const key = try self.fieldKey(name, field_name);
        defer self.allocator.free(key);
        if (self.known_int_fields.fetchRemove(key)) |entry| self.allocator.free(entry.key);
        if (self.known_bool_fields.fetchRemove(key)) |entry| self.allocator.free(entry.key);
    }

    pub fn putKnownIntField(self: *SyntacticFactSet, name: []const u8, field_name: []const u8, value: i64) !void {
        const key = try self.fieldKey(name, field_name);
        errdefer self.allocator.free(key);
        try self.putKnownIntKey(key, value);
    }

    pub fn putKnownBoolField(self: *SyntacticFactSet, name: []const u8, field_name: []const u8, value: bool) !void {
        const key = try self.fieldKey(name, field_name);
        errdefer self.allocator.free(key);
        try self.putKnownBoolKey(key, value);
    }

    pub fn putKnownIntKey(self: *SyntacticFactSet, owned_key: []const u8, value: i64) !void {
        if (self.known_bool_fields.fetchRemove(owned_key)) |entry| self.allocator.free(entry.key);
        const entry = try self.known_int_fields.getOrPut(owned_key);
        if (entry.found_existing) self.allocator.free(owned_key);
        entry.value_ptr.* = value;
    }

    pub fn putKnownBoolKey(self: *SyntacticFactSet, owned_key: []const u8, value: bool) !void {
        if (self.known_int_fields.fetchRemove(owned_key)) |entry| self.allocator.free(entry.key);
        const entry = try self.known_bool_fields.getOrPut(owned_key);
        if (entry.found_existing) self.allocator.free(owned_key);
        entry.value_ptr.* = value;
    }

    pub fn getKnownIntField(self: *const SyntacticFactSet, name: []const u8, field_name: []const u8) ?i64 {
        const key = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, field_name }) catch return null;
        defer self.allocator.free(key);
        return self.known_int_fields.get(key);
    }

    pub fn getKnownBoolField(self: *const SyntacticFactSet, name: []const u8, field_name: []const u8) ?bool {
        const key = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, field_name }) catch return null;
        defer self.allocator.free(key);
        return self.known_bool_fields.get(key);
    }

    pub fn copyKnownFieldsInto(self: *const SyntacticFactSet, dest: *SyntacticFactSet, target_name: []const u8, source_name: []const u8) !void {
        var int_iter = self.known_int_fields.iterator();
        while (int_iter.next()) |entry| {
            if (!fieldFactKeyMatchesName(entry.key_ptr.*, source_name)) continue;
            const field_name = entry.key_ptr.*[source_name.len + 1 ..];
            try dest.putKnownIntField(target_name, field_name, entry.value_ptr.*);
        }
        var bool_iter = self.known_bool_fields.iterator();
        while (bool_iter.next()) |entry| {
            if (!fieldFactKeyMatchesName(entry.key_ptr.*, source_name)) continue;
            const field_name = entry.key_ptr.*[source_name.len + 1 ..];
            try dest.putKnownBoolField(target_name, field_name, entry.value_ptr.*);
        }
    }

    pub fn putLocalType(self: *SyntacticFactSet, name: []const u8, type_name: []const u8) !void {
        try self.local_types.put(name, type_name);
    }

    pub fn getLocalType(self: *const SyntacticFactSet, name: []const u8) ?[]const u8 {
        return self.local_types.get(name);
    }
};

pub fn fieldFactKeyMatchesName(key: []const u8, name: []const u8) bool {
    return key.len > name.len + 1 and
        std.mem.startsWith(u8, key, name) and
        key[name.len] == '.';
}

pub const FunctionSyntacticFacts = struct {
    initialized: bool = false,
    facts: SyntacticFactSet,

    pub fn init(allocator: std.mem.Allocator) FunctionSyntacticFacts {
        return .{ .facts = SyntacticFactSet.init(allocator) };
    }

    pub fn deinit(self: *FunctionSyntacticFacts) void {
        self.facts.deinit();
    }
};

pub const ReachabilityAnalysis = struct {
    allocator: std.mem.Allocator,
    function_facts: std.StringHashMap(FunctionSyntacticFacts),
    current_facts: ?*const SyntacticFactSet = null,
    prune_known_branches: bool,

    pub fn init(allocator: std.mem.Allocator, prune_known_branches: bool) ReachabilityAnalysis {
        return .{
            .allocator = allocator,
            .function_facts = std.StringHashMap(FunctionSyntacticFacts).init(allocator),
            .prune_known_branches = prune_known_branches,
        };
    }

    pub fn deinit(self: *ReachabilityAnalysis) void {
        var iter = self.function_facts.valueIterator();
        while (iter.next()) |entry| entry.deinit();
        self.function_facts.deinit();
    }

    pub fn retainOnly(self: *ReachabilityAnalysis, set: *std.StringHashMap(void), incoming: *const std.StringHashMap(void)) !bool {
        var removed = std.ArrayList([]const u8).init(self.allocator);
        defer removed.deinit();
        var iter = set.keyIterator();
        while (iter.next()) |key_ptr| {
            if (!incoming.contains(key_ptr.*)) try removed.append(key_ptr.*);
        }
        for (removed.items) |key| _ = set.remove(key);
        return removed.items.len != 0;
    }

    pub fn retainMatchingInts(self: *ReachabilityAnalysis, facts: *std.StringHashMap(i64), incoming: *const std.StringHashMap(i64)) !bool {
        var removed = std.ArrayList([]const u8).init(self.allocator);
        defer removed.deinit();
        var iter = facts.iterator();
        while (iter.next()) |entry| {
            const incoming_value = incoming.get(entry.key_ptr.*) orelse {
                try removed.append(entry.key_ptr.*);
                continue;
            };
            if (incoming_value != entry.value_ptr.*) try removed.append(entry.key_ptr.*);
        }
        for (removed.items) |key| {
            if (facts.fetchRemove(key)) |entry| self.allocator.free(entry.key);
        }
        return removed.items.len != 0;
    }

    pub fn retainMatchingBools(self: *ReachabilityAnalysis, facts: *std.StringHashMap(bool), incoming: *const std.StringHashMap(bool)) !bool {
        var removed = std.ArrayList([]const u8).init(self.allocator);
        defer removed.deinit();
        var iter = facts.iterator();
        while (iter.next()) |entry| {
            const incoming_value = incoming.get(entry.key_ptr.*) orelse {
                try removed.append(entry.key_ptr.*);
                continue;
            };
            if (incoming_value != entry.value_ptr.*) try removed.append(entry.key_ptr.*);
        }
        for (removed.items) |key| {
            if (facts.fetchRemove(key)) |entry| self.allocator.free(entry.key);
        }
        return removed.items.len != 0;
    }

    pub fn retainMatchingTypes(self: *ReachabilityAnalysis, facts: *std.StringHashMap([]const u8), incoming: *const std.StringHashMap([]const u8)) !bool {
        var removed = std.ArrayList([]const u8).init(self.allocator);
        defer removed.deinit();
        var iter = facts.iterator();
        while (iter.next()) |entry| {
            const incoming_value = incoming.get(entry.key_ptr.*) orelse {
                try removed.append(entry.key_ptr.*);
                continue;
            };
            if (!std.mem.eql(u8, incoming_value, entry.value_ptr.*)) try removed.append(entry.key_ptr.*);
        }
        for (removed.items) |key| _ = facts.remove(key);
        return removed.items.len != 0;
    }

    pub fn mergeFunctionFacts(self: *ReachabilityAnalysis, function_name: []const u8, incoming_opt: ?*const SyntacticFactSet) !bool {
        var empty = SyntacticFactSet.init(self.allocator);
        defer empty.deinit();
        const incoming = incoming_opt orelse &empty;

        const entry = try self.function_facts.getOrPut(function_name);
        if (!entry.found_existing) {
            entry.value_ptr.* = FunctionSyntacticFacts.init(self.allocator);
        }
        if (!entry.value_ptr.initialized) {
            entry.value_ptr.facts.deinit();
            entry.value_ptr.facts = try incoming.clone();
            entry.value_ptr.initialized = true;
            return true;
        }

        var changed = false;
        changed = (try self.retainOnly(&entry.value_ptr.facts.no_import_sources, &incoming.no_import_sources)) or changed;
        changed = (try self.retainOnly(&entry.value_ptr.facts.zero_import_scans, &incoming.zero_import_scans)) or changed;
        changed = (try self.retainMatchingInts(&entry.value_ptr.facts.known_int_fields, &incoming.known_int_fields)) or changed;
        changed = (try self.retainMatchingBools(&entry.value_ptr.facts.known_bool_fields, &incoming.known_bool_fields)) or changed;
        changed = (try self.retainMatchingTypes(&entry.value_ptr.facts.local_types, &incoming.local_types)) or changed;
        return changed;
    }
};

pub fn literalHasNoImportKeyword(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "import") == null;
}

pub fn nodeIsNoImportSource(expr: *const ast.Node, facts: ?*const SyntacticFactSet) bool {
    return switch (expr.*) {
        .literal => |lit| switch (lit) {
            .string_val => |value| literalHasNoImportKeyword(value),
            else => false,
        },
        .identifier => |name| if (facts) |f| f.no_import_sources.contains(name) else false,
        .call_expr => |call| blk: {
            if (std.mem.eql(u8, call.func_name, "STR_PTR") and call.args.len == 1) {
                break :blk nodeIsNoImportSource(call.args[0], facts);
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn nodeIsZeroImportScan(expr: *const ast.Node, facts: ?*const SyntacticFactSet) bool {
    return switch (expr.*) {
        .identifier => |name| if (facts) |f| f.zero_import_scans.contains(name) else false,
        .call_expr => |call| std.mem.eql(u8, call.func_name, "parse_import_specifiers") and
            call.args.len >= 1 and
            nodeIsNoImportSource(call.args[0], facts),
        else => false,
    };
}

pub fn evalSyntacticInt(expr: *const ast.Node, facts: ?*const SyntacticFactSet) ?i64 {
    return switch (expr.*) {
        .literal => |lit| switch (lit) {
            .int_val => |value| value,
            else => null,
        },
        .binary_expr => |bin| blk: {
            const left = evalSyntacticInt(bin.left, facts) orelse break :blk null;
            const right = evalSyntacticInt(bin.right, facts) orelse break :blk null;
            break :blk switch (bin.op) {
                .add => left + right,
                .sub => left - right,
                .mul => left * right,
                .div => if (right != 0) @divTrunc(left, right) else null,
                .mod => if (right != 0) @mod(left, right) else null,
                else => null,
            };
        },
        .field_expr => |field| blk: {
            if (std.mem.eql(u8, field.field_name, "import_count") and nodeIsZeroImportScan(field.expr, facts)) break :blk 0;
            if (field.expr.* == .identifier) {
                if (facts) |f| {
                    if (f.getKnownIntField(field.expr.identifier, field.field_name)) |value| break :blk value;
                }
            }
            break :blk null;
        },
        else => null,
    };
}

pub fn evalSyntacticBool(expr: *const ast.Node, facts: ?*const SyntacticFactSet) ?bool {
    return switch (expr.*) {
        .literal => |lit| switch (lit) {
            .bool_val => |value| value,
            else => null,
        },
        .field_expr => |field| blk: {
            if (field.expr.* == .identifier) {
                if (facts) |f| {
                    if (f.getKnownBoolField(field.expr.identifier, field.field_name)) |value| break :blk value;
                }
            }
            break :blk null;
        },
        .binary_expr => |bin| blk: {
            switch (bin.op) {
                .eq, .ne => {
                    if (evalSyntacticInt(bin.left, facts)) |left| {
                        const right = evalSyntacticInt(bin.right, facts) orelse break :blk null;
                        break :blk if (bin.op == .eq) left == right else left != right;
                    }
                    if (evalSyntacticBool(bin.left, facts)) |left| {
                        const right = evalSyntacticBool(bin.right, facts) orelse break :blk null;
                        break :blk if (bin.op == .eq) left == right else left != right;
                    }
                    break :blk null;
                },
                .lt, .le, .gt, .ge => {
                    const left = evalSyntacticInt(bin.left, facts) orelse break :blk null;
                    const right = evalSyntacticInt(bin.right, facts) orelse break :blk null;
                    break :blk switch (bin.op) {
                        .lt => left < right,
                        .le => left <= right,
                        .gt => left > right,
                        .ge => left >= right,
                        else => unreachable,
                    };
                },
                .logical_and => {
                    const left = evalSyntacticBool(bin.left, facts);
                    if (left != null and left.? == false) break :blk false;
                    const right = evalSyntacticBool(bin.right, facts);
                    if (right != null and right.? == false) break :blk false;
                    if (left != null and right != null) break :blk left.? and right.?;
                    break :blk null;
                },
                .logical_or => {
                    const left = evalSyntacticBool(bin.left, facts);
                    if (left != null and left.? == true) break :blk true;
                    const right = evalSyntacticBool(bin.right, facts);
                    if (right != null and right.? == true) break :blk true;
                    if (left != null and right != null) break :blk left.? or right.?;
                    break :blk null;
                },
                else => break :blk null,
            }
        },
        else => null,
    };
}

pub fn buildCallFactsForDecl(
    allocator: std.mem.Allocator,
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    fd: *const ast.FuncDecl,
    call: *const ast.CallExpr,
    current_facts: ?*const SyntacticFactSet,
    depth: usize,
) anyerror!SyntacticFactSet {
    var facts = SyntacticFactSet.init(allocator);
    errdefer facts.deinit();

    const count = @min(fd.params.len, call.args.len);
    for (0..count) |i| {
        const param_name = fd.params[i].name;
        const arg = call.args[i];
        if (lowering_rules.concreteTypeName(fd.params[i].ty)) |type_name| try facts.putLocalType(param_name, type_name);
        if (nodeIsNoImportSource(arg, current_facts)) try facts.no_import_sources.put(param_name, {});
        if (nodeIsZeroImportScan(arg, current_facts)) try facts.zero_import_scans.put(param_name, {});
        try recordKnownFieldsFromExpr(&facts, current_facts, funcs, modules, param_name, arg, depth);
    }

    return facts;
}

pub fn syntacticFuncDeclForCall(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    name: []const u8,
) ?*ast.FuncDecl {
    if (funcs.decls.get(name)) |fd| return fd;
    if (modules) |mod_table| {
        if (mod_table.functionSignatureForImportedMangledNameByNamespace(name)) |signature| {
            if (funcs.decls.get(signature.name)) |fd| return fd;
        }
    }
    if (splitImportedMangledSymbol(name)) |imported| {
        if (funcs.decls.get(imported.name)) |fd| return fd;
    }
    if (funcs.associated_candidates.get(name)) |candidates| {
        if (candidates.items.len == 1) {
            if (funcs.decls.get(candidates.items[0])) |fd| return fd;
        }
    }
    return null;
}

pub fn moduleQualifiedCallableForCaller(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    caller_name: ?[]const u8,
    name: []const u8,
) !?[]const u8 {
    _ = modules;
    if (splitImportedMangledSymbol(name) != null) return null;
    const caller = caller_name orelse return null;
    const imported_caller = splitImportedMangledSymbol(caller) orelse return null;
    const alias = try std.fmt.allocPrint(funcs.allocator, "{s}__{s}", .{ imported_caller.namespace, name });
    if (funcs.names.contains(alias)) return alias;
    funcs.allocator.free(alias);
    return null;
}

pub fn syntacticFuncDeclForCallFromCaller(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    caller_name: ?[]const u8,
    name: []const u8,
) !?*ast.FuncDecl {
    if (try moduleQualifiedCallableForCaller(funcs, modules, caller_name, name)) |qualified| {
        defer funcs.allocator.free(qualified);
        if (funcs.decls.get(qualified)) |fd| return fd;
    }
    return syntacticFuncDeclForCall(funcs, modules, name);
}

pub fn singleReturnValue(fd: *const ast.FuncDecl) ?*const ast.Node {
    if (fd.body.len != 1) return null;
    const stmt = fd.body[0];
    if (stmt.* != .return_stmt) return null;
    return stmt.return_stmt.value;
}

pub fn recordKnownFieldsFromStructLiteral(
    dest: *SyntacticFactSet,
    source_facts: ?*const SyntacticFactSet,
    funcs: ?*const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    target_name: []const u8,
    lit: ast.StructLiteral,
    depth: usize,
) anyerror!void {
    if (lit.update_expr) |update_expr| {
        try recordKnownFieldsFromExpr(dest, source_facts, funcs, modules, target_name, update_expr, depth);
    }
    for (lit.fields) |field| {
        if (evalSyntacticInt(field.value, source_facts)) |value| {
            try dest.putKnownIntField(target_name, field.name, value);
        } else if (evalSyntacticBool(field.value, source_facts)) |value| {
            try dest.putKnownBoolField(target_name, field.name, value);
        } else {
            try dest.clearKnownField(target_name, field.name);
        }
    }
}

pub fn recordKnownFieldsFromCall(
    dest: *SyntacticFactSet,
    source_facts: ?*const SyntacticFactSet,
    funcs: ?*const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    target_name: []const u8,
    call: ast.CallExpr,
    depth: usize,
) anyerror!void {
    if (depth == 0) return;
    const callable_index = funcs orelse return;
    const fd = syntacticFuncDeclForCall(callable_index, modules, call.func_name) orelse return;
    if (fd.params.len != 0) return;
    const ret = singleReturnValue(fd) orelse return;
    var call_facts = try buildCallFactsForDecl(dest.allocator, callable_index, modules, fd, &call, source_facts, depth - 1);
    defer call_facts.deinit();
    try recordKnownFieldsFromExpr(dest, &call_facts, funcs, modules, target_name, ret, depth - 1);
}

pub fn recordKnownFieldsFromExpr(
    dest: *SyntacticFactSet,
    source_facts: ?*const SyntacticFactSet,
    funcs: ?*const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    target_name: []const u8,
    value: *const ast.Node,
    depth: usize,
) anyerror!void {
    switch (value.*) {
        .identifier => |source_name| if (source_facts) |facts| try facts.copyKnownFieldsInto(dest, target_name, source_name),
        .struct_literal => |lit| try recordKnownFieldsFromStructLiteral(dest, source_facts, funcs, modules, target_name, lit, depth),
        .call_expr => |call| try recordKnownFieldsFromCall(dest, source_facts, funcs, modules, target_name, call, depth),
        else => {},
    }
}

pub fn syntacticConcreteTypeNameFromExpr(value: *const ast.Node) ?[]const u8 {
    return switch (value.*) {
        .struct_literal => |lit| lowering_rules.concreteTypeName(lit.ty),
        .borrow_expr => |borrow| syntacticConcreteTypeNameFromExpr(borrow.expr),
        .move_expr => |move| syntacticConcreteTypeNameFromExpr(move.expr),
        else => null,
    };
}

pub fn updateFactsForLetBinding(
    facts: *SyntacticFactSet,
    funcs: ?*const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    name: []const u8,
    declared_ty: ?*const ast.Type,
    value: *const ast.Node,
) anyerror!void {
    facts.clearName(name);
    if (nodeIsNoImportSource(value, facts)) try facts.no_import_sources.put(name, {});
    if (nodeIsZeroImportScan(value, facts)) try facts.zero_import_scans.put(name, {});
    if (if (declared_ty) |ty| lowering_rules.concreteTypeName(ty) else syntacticConcreteTypeNameFromExpr(value)) |type_name| {
        try facts.putLocalType(name, type_name);
    }
    try recordKnownFieldsFromExpr(facts, facts, funcs, modules, name, value, 4);
}

pub fn pruneKnownFalseBranchesInBlock(
    allocator: std.mem.Allocator,
    block: []const *ast.Node,
    incoming_facts: *const SyntacticFactSet,
) !void {
    var facts = try incoming_facts.clone();
    defer facts.deinit();

    for (block, 0..) |stmt, idx| {
        // The last statement of a block can be its tail value, so an `if` there is
        // in value position and must keep both branches (see pruneKnownFalseBranchesInExpr).
        const is_tail = idx + 1 == block.len;
        switch (stmt.*) {
            .let_stmt => |let| {
                try pruneKnownFalseBranchesInExpr(allocator, let.value, &facts);
                try updateFactsForLetBinding(&facts, null, null, let.name, let.ty, let.value);
            },
            .const_stmt => |c| {
                try pruneKnownFalseBranchesInExpr(allocator, c.value, &facts);
                try updateFactsForLetBinding(&facts, null, null, c.name, c.ty, c.value);
            },
            .let_else_stmt => |let| {
                try pruneKnownFalseBranchesInExpr(allocator, let.value, &facts);
                try pruneKnownFalseBranchesInBlock(allocator, let.else_block, &facts);
            },
            .let_destructure_stmt => |let| {
                try pruneKnownFalseBranchesInExpr(allocator, let.value, &facts);
                for (let.names) |name| facts.clearName(name);
                if (let.rest_name) |name| facts.clearName(name);
                if (let.rest_alias) |name| facts.clearName(name);
            },
            .assign_stmt => |assign| {
                try pruneKnownFalseBranchesInExpr(allocator, assign.target, &facts);
                try pruneKnownFalseBranchesInExpr(allocator, assign.value, &facts);
                if (assign.target.* == .identifier) facts.clearName(assign.target.identifier);
            },
            .block_stmt => |blk| try pruneKnownFalseBranchesInBlock(allocator, blk.body, &facts),
            .expr_stmt => |expr| try pruneKnownFalseBranchesInExprPos(allocator, expr, &facts, is_tail),
            .return_stmt => |ret| if (ret.value) |value| try pruneKnownFalseBranchesInExpr(allocator, value, &facts),
            .for_stmt => |for_stmt| {
                try pruneKnownFalseBranchesInExpr(allocator, for_stmt.start, &facts);
                if (for_stmt.end) |end_expr| try pruneKnownFalseBranchesInExpr(allocator, end_expr, &facts);
                try pruneKnownFalseBranchesInBlock(allocator, for_stmt.body, &facts);
            },
            .while_stmt => |while_stmt| {
                try pruneKnownFalseBranchesInExpr(allocator, while_stmt.cond, &facts);
                try pruneKnownFalseBranchesInBlock(allocator, while_stmt.body, &facts);
            },
            else => try pruneKnownFalseBranchesInExprPos(allocator, stmt, &facts, is_tail),
        }
    }
}

/// Recurse into `expr` in value position: an `if` reached this way may be the
/// operand of a `let`, a struct-literal field, a `return`, a block tail, ... so
/// its branches must survive even when the condition folds to a constant.
pub fn pruneKnownFalseBranchesInExpr(
    allocator: std.mem.Allocator,
    expr: *ast.Node,
    facts: *const SyntacticFactSet,
) anyerror!void {
    return pruneKnownFalseBranchesInExprPos(allocator, expr, facts, true);
}

fn pruneKnownFalseBranchesInExprPos(
    allocator: std.mem.Allocator,
    expr: *ast.Node,
    facts: *const SyntacticFactSet,
    value_position: bool,
) anyerror!void {
    switch (expr.*) {
        .if_expr => |*ife| {
            try pruneKnownFalseBranchesInExpr(allocator, ife.cond, facts);
            if (ife.let_chain) |chain| {
                for (chain) |cond| try pruneKnownFalseBranchesInExpr(allocator, cond.value, facts);
            }
            if (!value_position and evalSyntacticBool(ife.cond, facts) == false) {
                ife.then_block = &.{};
            } else {
                try pruneKnownFalseBranchesInBlock(allocator, ife.then_block, facts);
            }
            if (ife.else_block) |else_block| try pruneKnownFalseBranchesInBlock(allocator, else_block, facts);
        },
        .switch_expr => |swe| {
            try pruneKnownFalseBranchesInExpr(allocator, swe.val, facts);
            for (swe.cases) |case| {
                try pruneKnownFalseBranchesInExpr(allocator, case.pattern, facts);
                try pruneKnownFalseBranchesInBlock(allocator, case.body, facts);
            }
        },
        .match_expr => |mat| {
            try pruneKnownFalseBranchesInExpr(allocator, mat.val, facts);
            for (mat.cases) |case| {
                if (case.guard) |guard| try pruneKnownFalseBranchesInExpr(allocator, guard, facts);
                try pruneKnownFalseBranchesInBlock(allocator, case.body, facts);
            }
        },
        .unsafe_expr => |unsafe_expr| try pruneKnownFalseBranchesInBlock(allocator, unsafe_expr.body, facts),
        .await_expr => |await_expr| try pruneKnownFalseBranchesInExpr(allocator, await_expr.expr, facts),
        .try_expr => |try_expr| try pruneKnownFalseBranchesInExpr(allocator, try_expr.expr, facts),
        .binary_expr => |bin| {
            try pruneKnownFalseBranchesInExpr(allocator, bin.left, facts);
            try pruneKnownFalseBranchesInExpr(allocator, bin.right, facts);
        },
        .closure_literal => |closure| try pruneKnownFalseBranchesInExpr(allocator, closure.body, facts),
        .borrow_expr => |borrow| try pruneKnownFalseBranchesInExpr(allocator, borrow.expr, facts),
        .move_expr => |move| try pruneKnownFalseBranchesInExpr(allocator, move.expr, facts),
        .deref_expr => |deref| try pruneKnownFalseBranchesInExpr(allocator, deref.expr, facts),
        .cast_expr => |cast| try pruneKnownFalseBranchesInExpr(allocator, cast.expr, facts),
        .field_expr => |field| try pruneKnownFalseBranchesInExpr(allocator, field.expr, facts),
        .struct_literal => |lit| {
            for (lit.fields) |field| try pruneKnownFalseBranchesInExpr(allocator, field.value, facts);
            if (lit.update_expr) |update| try pruneKnownFalseBranchesInExpr(allocator, update, facts);
        },
        .enum_literal => |lit| {
            for (lit.fields) |field| try pruneKnownFalseBranchesInExpr(allocator, field.value, facts);
        },
        .tuple_literal => |lit| for (lit.elements) |elem| try pruneKnownFalseBranchesInExpr(allocator, elem, facts),
        .array_literal => |lit| for (lit.elements) |elem| try pruneKnownFalseBranchesInExpr(allocator, elem, facts),
        .repeat_array_literal => |lit| try pruneKnownFalseBranchesInExpr(allocator, lit.value, facts),
        .index_expr => |idx| {
            try pruneKnownFalseBranchesInExpr(allocator, idx.target, facts);
            try pruneKnownFalseBranchesInExpr(allocator, idx.index, facts);
        },
        .slice_expr => |slice| {
            try pruneKnownFalseBranchesInExpr(allocator, slice.target, facts);
            try pruneKnownFalseBranchesInExpr(allocator, slice.start, facts);
            try pruneKnownFalseBranchesInExpr(allocator, slice.end, facts);
        },
        .call_expr => |call| {
            for (call.args) |arg| try pruneKnownFalseBranchesInExpr(allocator, arg, facts);
            if (std.mem.endsWith(u8, call.func_name, "program_resolve_import_scan_for_file") and call.args.len >= 4 and nodeIsZeroImportScan(call.args[call.args.len - 1], facts)) {
                expr.* = call.args[0].*;
            }
        },
        else => {},
    }
}

pub fn reachabilityNodeBindsIdentifier(node: *const ast.Node, name: []const u8) bool {
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

pub fn reachabilityClosureShadowsIdentifier(closure: ast.ClosureLiteral, name: []const u8) bool {
    for (closure.params) |param| {
        if (std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

pub fn reachabilityBlockUsesIdentifier(body: []const *ast.Node, name: []const u8) bool {
    for (body) |stmt| {
        if (reachabilityNodeUsesIdentifier(stmt, name)) return true;
        if (reachabilityNodeBindsIdentifier(stmt, name)) return false;
    }
    return false;
}

pub fn reachabilityNodeUsesIdentifier(node: *const ast.Node, name: []const u8) bool {
    return switch (node.*) {
        .program => |program| reachabilityBlockUsesIdentifier(program.decls, name),
        .func_decl => |func| reachabilityBlockUsesIdentifier(func.body, name),
        .macro_decl => |macro| reachabilityBlockUsesIdentifier(macro.body, name),
        .test_decl => |test_decl| reachabilityBlockUsesIdentifier(test_decl.body, name),
        .impl_decl => |impl_decl| reachabilityBlockUsesIdentifier(impl_decl.methods, name),
        .let_stmt => |let| reachabilityNodeUsesIdentifier(let.value, name),
        .let_else_stmt => |let| reachabilityNodeUsesIdentifier(let.value, name) or reachabilityBlockUsesIdentifier(let.else_block, name),
        .let_destructure_stmt => |let| reachabilityNodeUsesIdentifier(let.value, name),
        .const_stmt => |constant| reachabilityNodeUsesIdentifier(constant.value, name),
        .assign_stmt => |assign| reachabilityNodeUsesIdentifier(assign.target, name) or reachabilityNodeUsesIdentifier(assign.value, name),
        .release_stmt => |release| std.mem.eql(u8, release.var_name, name),
        .block_stmt => |block| reachabilityBlockUsesIdentifier(block.body, name),
        .expr_stmt => |expr| reachabilityNodeUsesIdentifier(expr, name),
        .return_stmt => |ret| if (ret.value) |value| reachabilityNodeUsesIdentifier(value, name) else false,
        .for_stmt => |for_stmt| blk: {
            if (reachabilityNodeUsesIdentifier(for_stmt.start, name)) break :blk true;
            if (for_stmt.end) |end| {
                if (reachabilityNodeUsesIdentifier(end, name)) break :blk true;
            }
            if (std.mem.eql(u8, for_stmt.var_name, name)) break :blk false;
            break :blk reachabilityBlockUsesIdentifier(for_stmt.body, name);
        },
        .while_stmt => |while_stmt| reachabilityNodeUsesIdentifier(while_stmt.cond, name) or reachabilityBlockUsesIdentifier(while_stmt.body, name),
        .identifier => |ident| std.mem.eql(u8, ident, name),
        .generic_func_ref => false,
        .if_expr => |ife| blk: {
            if (reachabilityNodeUsesIdentifier(ife.cond, name)) break :blk true;
            if (ife.let_chain) |chain| {
                for (chain) |item| {
                    if (reachabilityNodeUsesIdentifier(item.value, name)) break :blk true;
                }
            }
            if (reachabilityBlockUsesIdentifier(ife.then_block, name)) break :blk true;
            if (ife.else_block) |else_block| {
                if (reachabilityBlockUsesIdentifier(else_block, name)) break :blk true;
            }
            break :blk false;
        },
        .switch_expr => |switch_expr| blk: {
            if (reachabilityNodeUsesIdentifier(switch_expr.val, name)) break :blk true;
            for (switch_expr.cases) |case| {
                if (reachabilityBlockUsesIdentifier(case.body, name)) break :blk true;
            }
            break :blk false;
        },
        .match_expr => |match_expr| blk: {
            if (reachabilityNodeUsesIdentifier(match_expr.val, name)) break :blk true;
            for (match_expr.cases) |case| {
                if (case.guard) |guard| {
                    if (reachabilityNodeUsesIdentifier(guard, name)) break :blk true;
                }
                if (reachabilityBlockUsesIdentifier(case.body, name)) break :blk true;
            }
            break :blk false;
        },
        .unsafe_expr => |unsafe_expr| reachabilityBlockUsesIdentifier(unsafe_expr.body, name),
        .await_expr => |await_expr| reachabilityNodeUsesIdentifier(await_expr.expr, name),
        .binary_expr => |bin| reachabilityNodeUsesIdentifier(bin.left, name) or reachabilityNodeUsesIdentifier(bin.right, name),
        .call_expr => |call| blk: {
            if (call.associated_target == null and std.mem.eql(u8, call.func_name, name)) break :blk true;
            for (call.args) |arg| {
                if (reachabilityNodeUsesIdentifier(arg, name)) break :blk true;
            }
            break :blk false;
        },
        .closure_literal => |closure| if (reachabilityClosureShadowsIdentifier(closure, name)) false else reachabilityNodeUsesIdentifier(closure.body, name),
        .borrow_expr => |borrow| reachabilityNodeUsesIdentifier(borrow.expr, name),
        .move_expr => |move| reachabilityNodeUsesIdentifier(move.expr, name),
        .deref_expr => |deref| reachabilityNodeUsesIdentifier(deref.expr, name),
        .cast_expr => |cast| reachabilityNodeUsesIdentifier(cast.expr, name),
        .field_expr => |field| reachabilityNodeUsesIdentifier(field.expr, name),
        .struct_literal => |lit| blk: {
            if (lit.update_expr) |update| {
                if (reachabilityNodeUsesIdentifier(update, name)) break :blk true;
            }
            for (lit.fields) |field| {
                if (reachabilityNodeUsesIdentifier(field.value, name)) break :blk true;
            }
            break :blk false;
        },
        .enum_literal => |lit| blk: {
            for (lit.fields) |field| {
                if (reachabilityNodeUsesIdentifier(field.value, name)) break :blk true;
            }
            break :blk false;
        },
        .tuple_literal => |tuple| blk: {
            for (tuple.elements) |elem| {
                if (reachabilityNodeUsesIdentifier(elem, name)) break :blk true;
            }
            break :blk false;
        },
        .array_literal => |array| blk: {
            for (array.elements) |elem| {
                if (reachabilityNodeUsesIdentifier(elem, name)) break :blk true;
            }
            break :blk false;
        },
        .repeat_array_literal => |repeat| reachabilityNodeUsesIdentifier(repeat.value, name),
        .index_expr => |idx| reachabilityNodeUsesIdentifier(idx.target, name) or reachabilityNodeUsesIdentifier(idx.index, name),
        .slice_expr => |slice| reachabilityNodeUsesIdentifier(slice.target, name) or reachabilityNodeUsesIdentifier(slice.start, name) or reachabilityNodeUsesIdentifier(slice.end, name),
        .try_expr => |try_expr| reachabilityNodeUsesIdentifier(try_expr.expr, name),
        else => false,
    };
}

pub fn pruneDeadZeroImportScanLetsInBlock(
    allocator: std.mem.Allocator,
    block: []const *ast.Node,
    incoming_facts: *const SyntacticFactSet,
) ![]const *ast.Node {
    var facts = try incoming_facts.clone();
    defer facts.deinit();

    var out = std.ArrayList(*ast.Node).init(allocator);
    for (block, 0..) |stmt, idx| {
        var keep = true;
        switch (stmt.*) {
            .let_stmt => |let| {
                keep = !(nodeIsZeroImportScan(let.value, &facts) and !reachabilityBlockUsesIdentifier(block[idx + 1 ..], let.name));
                try updateFactsForLetBinding(&facts, null, null, let.name, let.ty, let.value);
            },
            .const_stmt => |constant| {
                keep = !(nodeIsZeroImportScan(constant.value, &facts) and !reachabilityBlockUsesIdentifier(block[idx + 1 ..], constant.name));
                try updateFactsForLetBinding(&facts, null, null, constant.name, constant.ty, constant.value);
            },
            .assign_stmt => |assign| {
                if (assign.target.* == .identifier) facts.clearName(assign.target.identifier);
            },
            .let_destructure_stmt => |let| {
                for (let.names) |name| facts.clearName(name);
                if (let.rest_name) |name| facts.clearName(name);
                if (let.rest_alias) |name| facts.clearName(name);
            },
            else => {},
        }
        if (keep) try out.append(stmt);
    }
    return try out.toOwnedSlice();
}

pub fn pruneKnownFalseBranchesInReachableDecls(
    allocator: std.mem.Allocator,
    program: *ast.Node,
    analysis: *ReachabilityAnalysis,
    reachable: *const std.StringHashMap(void),
) !void {
    if (program.* != .program) return;
    for (program.program.decls) |decl| {
        switch (decl.*) {
            .func_decl => |*fd| {
                if (!reachable.contains(fd.name)) continue;
                if (analysis.function_facts.get(fd.name)) |entry| {
                    try pruneKnownFalseBranchesInBlock(allocator, fd.body, &entry.facts);
                    fd.body = try pruneDeadZeroImportScanLetsInBlock(allocator, fd.body, &entry.facts);
                }
            },
            .impl_decl => |impl_decl| {
                const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                for (impl_decl.methods) |method| {
                    if (method.* != .func_decl) continue;
                    const symbol = if (impl_decl.trait_name) |trait_name|
                        try lowering_rules.mangleTraitMethodName(allocator, type_name, trait_name, method.func_decl.name)
                    else
                        try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    defer allocator.free(symbol);
                    if (!reachable.contains(symbol)) continue;
                    if (analysis.function_facts.get(symbol)) |entry| {
                        try pruneKnownFalseBranchesInBlock(allocator, method.func_decl.body, &entry.facts);
                        method.func_decl.body = try pruneDeadZeroImportScanLetsInBlock(allocator, method.func_decl.body, &entry.facts);
                    }
                }
            },
            .overload_decl => |overload_decl| {
                const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                for (overload_decl.methods) |method| {
                    if (method.* != .func_decl) continue;
                    const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    defer allocator.free(symbol);
                    if (!reachable.contains(symbol)) continue;
                    if (analysis.function_facts.get(symbol)) |entry| {
                        try pruneKnownFalseBranchesInBlock(allocator, method.func_decl.body, &entry.facts);
                        method.func_decl.body = try pruneDeadZeroImportScanLetsInBlock(allocator, method.func_decl.body, &entry.facts);
                    }
                }
            },
            else => {},
        }
    }
}

pub fn collectSyntacticReachableRootsFromDecls(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    analysis: ?*ReachabilityAnalysis,
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    decls: []const *ast.Node,
    test_filter: ?[]const u8,
    saw_test: *bool,
) !void {
    for (decls) |decl| {
        switch (decl.*) {
            .test_decl => |test_decl| {
                if (!testMatchesFilter(&test_decl, test_filter)) continue;
                saw_test.* = true;
                try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, null, reachable, referenced_types, worklist, test_decl.body);
            },
            .const_stmt => |const_stmt| {
                if (const_stmt.ty) |ty| try recordReferencedType(referenced_types, ty);
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, null, reachable, referenced_types, worklist, const_stmt.value);
            },
            .impl_decl => |impl_decl| {
                try recordReferencedType(referenced_types, impl_decl.target_ty);
                if (impl_decl.trait_name) |tn| try referenced_types.put(tn, {});
                if (impl_decl.trait_name != null) {
                    for (impl_decl.methods) |method| {
                        if (method.* == .func_decl) {
                            const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                            const symbol = try lowering_rules.mangleTraitMethodName(funcs.allocator, type_name, impl_decl.trait_name.?, method.func_decl.name);
                            defer funcs.allocator.free(symbol);
                            try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, symbol, reachable, referenced_types, worklist, method.func_decl.body);
                        }
                    }
                }
            },
            .overload_decl => |overload_decl| {
                try recordReferencedType(referenced_types, overload_decl.target_ty);
                for (overload_decl.methods) |method| {
                    if (method.* == .func_decl) {
                        const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                        const symbol = try lowering_rules.mangleMethodName(funcs.allocator, type_name, method.func_decl.name);
                        defer funcs.allocator.free(symbol);
                        try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, symbol, reachable, referenced_types, worklist, method.func_decl.body);
                    }
                }
            },
            else => {},
        }
    }
}

pub fn scanReferencedSymbolRoots(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    analysis: ?*ReachabilityAnalysis,
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
    scanned_symbol_roots: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
) !bool {
    // Every referenced root is inserted into this set when scanned. If counts
    // match, no root can be pending and we can avoid walking the whole hash map.
    // Explicit invalidation removes entries, making the counts differ again.
    if (referenced_types.count() == scanned_symbol_roots.count()) return false;

    var pending = std.ArrayList([]const u8).init(funcs.allocator);
    defer pending.deinit();

    var referenced_iter = referenced_types.keyIterator();
    while (referenced_iter.next()) |ref_name_ptr| {
        const ref_name = ref_name_ptr.*;
        if (scanned_symbol_roots.contains(ref_name)) continue;
        try scanned_symbol_roots.put(ref_name, {});
        try pending.append(ref_name);
    }

    for (pending.items) |ref_name| {
        if (funcs.const_decls.get(ref_name)) |const_decl| {
            if (const_decl.ty) |ty| try recordReferencedType(referenced_types, ty);
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, null, reachable, referenced_types, worklist, const_decl.value);
        }
        if (funcs.macro_decls.get(ref_name)) |macro_decl| {
            try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, macro_decl.name, reachable, referenced_types, worklist, macro_decl.body);
        }
    }

    return pending.items.len != 0;
}

const ReachabilityBuildState = struct {
    allocator: std.mem.Allocator,
    callable_index: SlaCallableIndex,
    worklist: std.ArrayList([]const u8),
    scanned_symbol_roots: std.StringHashMap(void),
    scanned_type_roots: std.StringHashMap(void),
    analysis: ReachabilityAnalysis,
    unresolved_callables: UnresolvedCallableSet,
    scanned_function_bodies: std.StringHashMap(void),
    worklist_index: usize = 0,

    fn init(allocator: std.mem.Allocator) ReachabilityBuildState {
        return .{
            .allocator = allocator,
            .callable_index = SlaCallableIndex.init(allocator),
            .worklist = std.ArrayList([]const u8).init(allocator),
            .scanned_symbol_roots = std.StringHashMap(void).init(allocator),
            .scanned_type_roots = std.StringHashMap(void).init(allocator),
            .scanned_function_bodies = std.StringHashMap(void).init(allocator),
            .analysis = ReachabilityAnalysis.init(allocator, false),
            .unresolved_callables = UnresolvedCallableSet.init(allocator),
        };
    }

    fn deinit(self: *ReachabilityBuildState) void {
        self.unresolved_callables.deinit();
        self.analysis.deinit();
        self.scanned_type_roots.deinit();
        self.scanned_function_bodies.deinit();
        self.scanned_symbol_roots.deinit();
        self.worklist.deinit();
        self.callable_index.deinit();
    }
};

fn collectInitialReachabilityRoots(
    state: *ReachabilityBuildState,
    root_program: *ast.Node,
    module_table: *SlaModuleTable,
    options: SlaImportExpansionOptions,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    out_reachable: *std.StringHashMap(void),
    out_referenced_types: *std.StringHashMap(void),
) !void {
    if (options.prune_for_test_codegen) {
        var saw_test = false;
        try collectSyntacticReachableRootsFromDecls(&state.callable_index, module_table, imported_macros, &state.analysis, out_reachable, out_referenced_types, &state.worklist, root_program.program.decls, options.test_filter, &saw_test);
    } else {
        // If not pruning for test, everything in the root program is a root!
        for (root_program.program.decls) |decl| {
            switch (decl.*) {
                .test_decl => |test_decl| {
                    try collectSyntacticReachableBlock(&state.callable_index, module_table, null, null, null, out_reachable, out_referenced_types, &state.worklist, test_decl.body);
                },
                .func_decl => |fd| {
                    try markSyntacticReachableFunc(&state.callable_index, module_table, null, null, null, out_reachable, out_referenced_types, &state.worklist, fd.name);
                },
                .const_stmt => |c| {
                    if (c.ty) |ty| try recordReferencedType(out_referenced_types, ty);
                    try collectSyntacticReachableExpr(&state.callable_index, module_table, null, null, null, out_reachable, out_referenced_types, &state.worklist, c.value);
                },
                .macro_decl => |m| {
                    try collectSyntacticReachableBlock(&state.callable_index, module_table, null, null, m.name, out_reachable, out_referenced_types, &state.worklist, m.body);
                },
                .impl_decl => |impl_decl| {
                    try recordReferencedType(out_referenced_types, impl_decl.target_ty);
                    if (impl_decl.trait_name) |tn| try out_referenced_types.put(tn, {});
                    for (impl_decl.methods) |method| {
                        if (method.* == .func_decl) {
                            const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                            const symbol = if (impl_decl.trait_name) |trait_name|
                                try lowering_rules.mangleTraitMethodName(state.allocator, type_name, trait_name, method.func_decl.name)
                            else
                                try lowering_rules.mangleMethodName(state.allocator, type_name, method.func_decl.name);
                            defer state.allocator.free(symbol);
                            try markSyntacticReachableFunc(&state.callable_index, module_table, null, null, null, out_reachable, out_referenced_types, &state.worklist, symbol);
                        }
                    }
                },
                .overload_decl => |overload_decl| {
                    try recordReferencedType(out_referenced_types, overload_decl.target_ty);
                    for (overload_decl.methods) |method| {
                        if (method.* == .func_decl) {
                            const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                            const symbol = try lowering_rules.mangleMethodName(state.allocator, type_name, method.func_decl.name);
                            defer state.allocator.free(symbol);
                            try markSyntacticReachableFunc(&state.callable_index, module_table, null, null, null, out_reachable, out_referenced_types, &state.worklist, symbol);
                        }
                    }
                },
                else => {},
            }
        }
    }
}

fn drainReachabilityBuildState(
    state: *ReachabilityBuildState,
    module_table: *SlaModuleTable,
    options: SlaImportExpansionOptions,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    out_reachable: *std.StringHashMap(void),
    out_referenced_types: *std.StringHashMap(void),
) !void {
    const profile = plugin_compile_options.slaProfileEnabled(state.allocator);
    var outer_passes: usize = 0;
    var work_items: usize = 0;
    var scan_sym_ns: i128 = 0;
    var scan_ty_ns: i128 = 0;
    var body_walk_ns: i128 = 0;
    var non_empty_bodies: usize = 0;
    while (true) {
        outer_passes += 1;
        while (state.worklist_index < state.worklist.items.len) : (state.worklist_index += 1) {
            work_items += 1;
            const name = state.worklist.items[state.worklist_index];
            const fd = state.callable_index.decls.get(name) orelse continue;
            for (fd.params) |param| {
                try recordReferencedType(out_referenced_types, param.ty);
            }
            try recordReferencedType(out_referenced_types, fd.ret_ty);
            const prev_facts = state.analysis.current_facts;
            if (options.prune_for_test_codegen) {
                if (state.analysis.function_facts.get(name)) |entry| {
                    state.analysis.current_facts = &entry.facts;
                } else {
                    state.analysis.current_facts = null;
                }
            }
            // Decl-only imported stubs have empty bodies; skip the walk entirely.
            if (fd.body.len != 0) {
                // Non-test drains never use fact-sensitive branch pruning, so each
                // function body only needs a single syntactic walk.
                if (!options.prune_for_test_codegen and state.scanned_function_bodies.contains(name)) {
                    // already walked
                } else {
                    if (profile) non_empty_bodies += 1;
                    const body_start = if (profile) std.time.nanoTimestamp() else 0;
                    try collectSyntacticReachableBlock(&state.callable_index, module_table, imported_macros, if (options.prune_for_test_codegen) &state.analysis else null, name, out_reachable, out_referenced_types, &state.worklist, fd.body);
                    if (profile) body_walk_ns += std.time.nanoTimestamp() - body_start;
                    if (!options.prune_for_test_codegen) {
                        try state.scanned_function_bodies.put(name, {});
                    }
                }
            }
            state.analysis.current_facts = prev_facts;
        }
        const scan_sym_start = if (profile) std.time.nanoTimestamp() else 0;
        const scanned_symbols = try scanReferencedSymbolRoots(&state.callable_index, module_table, imported_macros, if (options.prune_for_test_codegen) &state.analysis else null, out_reachable, out_referenced_types, &state.scanned_symbol_roots, &state.worklist);
        if (profile) scan_sym_ns += std.time.nanoTimestamp() - scan_sym_start;
        const scan_ty_start = if (profile) std.time.nanoTimestamp() else 0;
        const scanned_types = try scanReferencedExportedTypeSignatures(&state.callable_index, out_referenced_types, &state.scanned_type_roots);
        if (profile) scan_ty_ns += std.time.nanoTimestamp() - scan_ty_start;
        if (!scanned_symbols and !scanned_types) break;
    }
    if (profile) {
        std.debug.print(
            "[sla-profile] reachability drain: passes={d} work_items={d} non_empty_bodies={d} reachable={d} types={d} body_walk={d}ms scan_sym={d}ms scan_ty={d}ms\n",
            .{ outer_passes, work_items, non_empty_bodies, out_reachable.count(), out_referenced_types.count(), @divTrunc(body_walk_ns, std.time.ns_per_ms), @divTrunc(scan_sym_ns, std.time.ns_per_ms), @divTrunc(scan_ty_ns, std.time.ns_per_ms) },
        );
    }
}

fn initializeReachabilityBuildState(
    state: *ReachabilityBuildState,
    root_program: *ast.Node,
    modules: []const *SlaModule,
    module_table: *SlaModuleTable,
    options: SlaImportExpansionOptions,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    out_reachable: *std.StringHashMap(void),
    out_referenced_types: *std.StringHashMap(void),
) !void {
    if (root_program.* != .program) return error.InvalidProgram;
    const profile = plugin_compile_options.slaProfileEnabled(state.allocator);
    state.callable_index.unresolved_callables = &state.unresolved_callables;
    const index_start = if (profile) std.time.nanoTimestamp() else 0;
    try state.callable_index.addDecls(root_program.program.decls);
    for (modules) |module| try state.callable_index.addDeclsFromModule(module.program.program.decls, module);
    const index_ns = if (profile) std.time.nanoTimestamp() - index_start else 0;
    const roots_start = if (profile) std.time.nanoTimestamp() else 0;
    try collectInitialReachabilityRoots(state, root_program, module_table, options, imported_macros, out_reachable, out_referenced_types);
    const roots_ns = if (profile) std.time.nanoTimestamp() - roots_start else 0;
    const drain_start = if (profile) std.time.nanoTimestamp() else 0;
    try drainReachabilityBuildState(state, module_table, options, imported_macros, out_reachable, out_referenced_types);
    if (profile) {
        std.debug.print(
            "[sla-profile] reachability init: index={d}ms roots={d}ms drain={d}ms modules={d}\n",
            .{
                @divTrunc(index_ns, std.time.ns_per_ms),
                @divTrunc(roots_ns, std.time.ns_per_ms),
                @divTrunc(std.time.nanoTimestamp() - drain_start, std.time.ns_per_ms),
                modules.len,
            },
        );
    }
}

fn unresolvedCallableCanResolve(
    funcs: *const SlaCallableIndex,
    modules: *SlaModuleTable,
    record: UnresolvedCallable,
) !bool {
    if (record.kind == .imported_macro) return false;
    if (try syntacticFuncDeclForCallFromCaller(funcs, modules, record.caller_name, record.name) != null) return true;
    if (record.kind == .direct) return false;
    const candidates = funcs.associated_candidates.get(record.name) orelse return false;
    return candidates.items.len != 0;
}

pub const ReachabilitySession = struct {
    state: ReachabilityBuildState,
    root_program: *ast.Node,
    module_table: *SlaModuleTable,
    options: SlaImportExpansionOptions,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),

    pub fn init(
        allocator: std.mem.Allocator,
        root_program: *ast.Node,
        initial_modules: []const *SlaModule,
        module_table: *SlaModuleTable,
        options: SlaImportExpansionOptions,
        imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
        reachable: *std.StringHashMap(void),
        referenced_types: *std.StringHashMap(void),
    ) !ReachabilitySession {
        reachable.clearRetainingCapacity();
        referenced_types.clearRetainingCapacity();
        var session = ReachabilitySession{
            .state = ReachabilityBuildState.init(allocator),
            .root_program = root_program,
            .module_table = module_table,
            .options = options,
            .imported_macros = imported_macros,
            .reachable = reachable,
            .referenced_types = referenced_types,
        };
        errdefer session.state.deinit();
        try initializeReachabilityBuildState(&session.state, root_program, initial_modules, module_table, options, imported_macros, reachable, referenced_types);
        return session;
    }

    pub fn deinit(self: *ReachabilitySession) void {
        self.state.deinit();
    }

    pub fn unresolvedCallables(self: *const ReachabilitySession) *const UnresolvedCallableSet {
        return &self.state.unresolved_callables;
    }

    fn queueCallerForRescan(
        self: *ReachabilitySession,
        caller_name: ?[]const u8,
        queued_callers: *std.StringHashMap(void),
        rescan_roots: *bool,
    ) !void {
        if (caller_name) |caller| {
            if (self.reachable.getKey(caller)) |reachable_caller| {
                if (!queued_callers.contains(reachable_caller)) {
                    try queued_callers.put(reachable_caller, {});
                    try self.state.worklist.append(reachable_caller);
                }
            } else {
                _ = self.state.scanned_symbol_roots.remove(caller);
            }
        } else {
            rescan_roots.* = true;
        }
    }

    fn drainRescannedCallers(
        self: *ReachabilitySession,
        all_modules: []const *SlaModule,
        rescan_roots: bool,
    ) !void {
        _ = all_modules;
        if (rescan_roots) {
            try collectInitialReachabilityRoots(
                &self.state,
                self.root_program,
                self.module_table,
                self.options,
                self.imported_macros,
                self.reachable,
                self.referenced_types,
            );
        }
        try drainReachabilityBuildState(
            &self.state,
            self.module_table,
            self.options,
            self.imported_macros,
            self.reachable,
            self.referenced_types,
        );
    }

    pub fn addModules(
        self: *ReachabilitySession,
        new_modules: []const *SlaModule,
        all_modules: []const *SlaModule,
    ) !void {
        if (new_modules.len == 0) return;
        self.state.callable_index.unresolved_callables = &self.state.unresolved_callables;
        for (new_modules) |module| try self.state.callable_index.addDeclsFromModule(module.program.program.decls, module);

        var rescan_roots = false;
        var queued_callers = std.StringHashMap(void).init(self.state.allocator);
        defer queued_callers.deinit();
        for (self.state.unresolved_callables.records.items) |*record| {
            if (record.resolved) continue;
            if (!try unresolvedCallableCanResolve(&self.state.callable_index, self.module_table, record.*)) continue;
            record.resolved = true;
            try self.queueCallerForRescan(record.caller_name, &queued_callers, &rescan_roots);
        }

        var referenced_iter = self.referenced_types.keyIterator();
        while (referenced_iter.next()) |name_ptr| {
            _ = self.state.scanned_symbol_roots.remove(name_ptr.*);
            _ = self.state.scanned_type_roots.remove(name_ptr.*);
        }
        try self.drainRescannedCallers(all_modules, rescan_roots);
    }

    pub fn refreshImportedMacros(self: *ReachabilitySession, all_modules: []const *SlaModule) !bool {
        const imported_macros = self.imported_macros orelse return false;
        self.state.callable_index.unresolved_callables = &self.state.unresolved_callables;
        var changed = false;
        var rescan_roots = false;
        var queued_callers = std.StringHashMap(void).init(self.state.allocator);
        defer queued_callers.deinit();
        for (self.state.unresolved_callables.records.items) |*record| {
            if (record.resolved or record.kind != .imported_macro or !imported_macros.contains(record.name)) continue;
            record.resolved = true;
            changed = true;
            try self.queueCallerForRescan(record.caller_name, &queued_callers, &rescan_roots);
        }
        if (!changed) return false;
        try self.drainRescannedCallers(all_modules, rescan_roots);
        return true;
    }

    pub fn materialize(self: *ReachabilitySession, ordered_modules: []const *SlaModule) !ReachabilityMaterializationStats {
        self.state.callable_index.unresolved_callables = &self.state.unresolved_callables;
        return try materializeReachableImportedModuleBodiesWithState(
            &self.state,
            self.state.allocator,
            ordered_modules,
            self.module_table,
            self.options,
            self.imported_macros,
            self.reachable,
            self.referenced_types,
        );
    }
};

pub fn buildReachableSymbols(
    allocator: std.mem.Allocator,
    root_program: *ast.Node,
    modules: []const *SlaModule,
    module_table: *SlaModuleTable,
    options: SlaImportExpansionOptions,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    out_reachable: *std.StringHashMap(void),
    out_referenced_types: *std.StringHashMap(void),
) !void {
    var state = ReachabilityBuildState.init(allocator);
    defer state.deinit();
    try initializeReachabilityBuildState(&state, root_program, modules, module_table, options, imported_macros, out_reachable, out_referenced_types);
}

pub fn collectReachableModuleBodyNames(
    allocator: std.mem.Allocator,
    module: *const SlaModule,
    reachable: *const std.StringHashMap(void),
    referenced_types: *const std.StringHashMap(void),
    selected_function_bodies: *std.StringHashMap(void),
    selected_macro_bodies: *std.StringHashMap(void),
) !void {
    var needs_alias_scan = false;
    var func_iter = module.exports.function_decls.keyIterator();
    while (func_iter.next()) |name_ptr| {
        if (reachable.contains(name_ptr.*)) {
            try selected_function_bodies.put(name_ptr.*, {});
            continue;
        }
        needs_alias_scan = true;
    }

    if (needs_alias_scan) {
        const namespace = try moduleNamespaceFromImportPath(allocator, module.output_path);
        defer allocator.free(namespace);
        const prefix = try std.mem.concat(allocator, u8, &.{ namespace, "__" });
        defer allocator.free(prefix);
        var reachable_iter = reachable.keyIterator();
        while (reachable_iter.next()) |reachable_ptr| {
            const name = reachable_ptr.*;
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            const raw_name = name[prefix.len..];
            if (module.exports.function_decls.contains(raw_name)) {
                try selected_function_bodies.put(raw_name, {});
            }
        }
    }

    var macro_iter = module.exports.macro_decls.keyIterator();
    while (macro_iter.next()) |name_ptr| {
        if (referenced_types.contains(name_ptr.*)) try selected_macro_bodies.put(name_ptr.*, {});
    }

    var associated_iter = module.exports.associated_function_decls.keyIterator();
    while (associated_iter.next()) |symbol_ptr| {
        if (reachable.contains(symbol_ptr.*)) try selected_function_bodies.put(symbol_ptr.*, {});
    }
}

pub fn stringSetContainsAll(haystack: *const std.StringHashMap(void), needles: *const std.StringHashMap(void)) bool {
    var iter = needles.keyIterator();
    while (iter.next()) |name_ptr| {
        if (!haystack.contains(name_ptr.*)) return false;
    }
    return true;
}

pub fn stringSetsEqual(a: *const std.StringHashMap(void), b: *const std.StringHashMap(void)) bool {
    return a.count() == b.count() and stringSetContainsAll(a, b);
}

pub const ReachabilityMaterializationStats = struct {
    passes: usize = 0,
    reparses: usize = 0,
    incremental_extensions: usize = 0,
};

fn enqueueMaterializedFunctionBodies(
    state: *ReachabilityBuildState,
    module: *const SlaModule,
    names: []const []const u8,
    reachable: *const std.StringHashMap(void),
) !void {
    const namespace = try moduleNamespaceFromImportPath(state.allocator, module.output_path);
    defer state.allocator.free(namespace);
    for (names) |name| {
        if (reachable.getKey(name)) |reachable_name| try state.worklist.append(reachable_name);
        if (!module.exports.function_decls.contains(name)) continue;
        const alias = try std.fmt.allocPrint(state.allocator, "{s}__{s}", .{ namespace, name });
        defer state.allocator.free(alias);
        if (reachable.getKey(alias)) |reachable_alias| try state.worklist.append(reachable_alias);
    }
}

pub fn materializeReachableImportedModuleBodiesWithState(
    state: *ReachabilityBuildState,
    allocator: std.mem.Allocator,
    ordered_modules: []const *SlaModule,
    modules: *SlaModuleTable,
    options: SlaImportExpansionOptions,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
) !ReachabilityMaterializationStats {
    const profile_enabled = plugin_compile_options.slaProfileEnabled(allocator);
    var stats = ReachabilityMaterializationStats{};
    var select_ns: i128 = 0;
    var reparse_ns: i128 = 0;
    var extend_ns: i128 = 0;
    while (true) {
        stats.passes += 1;
        var changed = false;
        for (ordered_modules) |module| {
            if (module.has_function_bodies and module.has_macro_bodies) continue;
            {
                const select_start = std.time.nanoTimestamp();
                var selected_functions = std.StringHashMap(void).init(allocator);
                defer selected_functions.deinit();
                var selected_macros = std.StringHashMap(void).init(allocator);
                defer selected_macros.deinit();
                var parsed_func_iter = module.parsed_function_bodies.keyIterator();
                while (parsed_func_iter.next()) |name_ptr| try selected_functions.put(name_ptr.*, {});
                var parsed_macro_iter = module.parsed_macro_bodies.keyIterator();
                while (parsed_macro_iter.next()) |name_ptr| try selected_macros.put(name_ptr.*, {});
                try collectReachableModuleBodyNames(allocator, module, reachable, referenced_types, &selected_functions, &selected_macros);
                const unchanged = stringSetsEqual(&selected_functions, &module.parsed_function_bodies) and
                    stringSetsEqual(&selected_macros, &module.parsed_macro_bodies);
                select_ns += std.time.nanoTimestamp() - select_start;
                if (unchanged) continue;

                var newly_materialized_functions = std.ArrayList([]const u8).init(allocator);
                defer {
                    for (newly_materialized_functions.items) |name| allocator.free(name);
                    newly_materialized_functions.deinit();
                }
                var selected_func_iter = selected_functions.keyIterator();
                while (selected_func_iter.next()) |name_ptr| {
                    if (!module.parsed_function_bodies.contains(name_ptr.*)) {
                        try newly_materialized_functions.append(try allocator.dupe(u8, name_ptr.*));
                    }
                }
                var newly_materialized_macros = std.ArrayList([]const u8).init(allocator);
                defer {
                    for (newly_materialized_macros.items) |name| allocator.free(name);
                    newly_materialized_macros.deinit();
                }
                var selected_macro_iter = selected_macros.keyIterator();
                while (selected_macro_iter.next()) |name_ptr| {
                    if (!module.parsed_macro_bodies.contains(name_ptr.*)) {
                        try newly_materialized_macros.append(try allocator.dupe(u8, name_ptr.*));
                    }
                }

                const reparse_start = std.time.nanoTimestamp();
                const reparse_stats = try modules.reparseModuleWithSelectedBodies(module, &selected_functions, &selected_macros);
                const reparse_elapsed_ns = std.time.nanoTimestamp() - reparse_start;
                reparse_ns += reparse_elapsed_ns;
                stats.reparses += 1;
                if (profile_enabled) {
                    std.debug.print(
                        "[sla-profile] import reparse module={s} source={d} pass={d} new_functions={d} new_macros={d} selected_functions={d} selected_macros={d} parse={d}ms exports={d}ms commit={d}ms elapsed={d}ms\n",
                        .{
                            module.output_path,
                            module.expanded_source.len,
                            stats.passes,
                            newly_materialized_functions.items.len,
                            newly_materialized_macros.items.len,
                            selected_functions.count(),
                            selected_macros.count(),
                            @divTrunc(reparse_stats.parse_ns, std.time.ns_per_ms),
                            @divTrunc(reparse_stats.exports_ns, std.time.ns_per_ms),
                            @divTrunc(reparse_stats.commit_ns, std.time.ns_per_ms),
                            @divTrunc(reparse_elapsed_ns, std.time.ns_per_ms),
                        },
                    );
                }
                try state.callable_index.refreshDeclsFromModule(module);
                try enqueueMaterializedFunctionBodies(state, module, newly_materialized_functions.items, reachable);
                for (newly_materialized_macros.items) |name| _ = state.scanned_symbol_roots.remove(name);
            }
            changed = true;
        }
        if (!changed) break;

        const extend_start = std.time.nanoTimestamp();
        try drainReachabilityBuildState(state, modules, options, imported_macros, reachable, referenced_types);
        extend_ns += std.time.nanoTimestamp() - extend_start;
        stats.incremental_extensions += 1;
    }
    if (profile_enabled) {
        std.debug.print(
            "[sla-profile] import materialize passes={d} reparses={d} extensions={d} select={d}ms reparse={d}ms extend={d}ms\n",
            .{
                stats.passes,
                stats.reparses,
                stats.incremental_extensions,
                @divTrunc(select_ns, std.time.ns_per_ms),
                @divTrunc(reparse_ns, std.time.ns_per_ms),
                @divTrunc(extend_ns, std.time.ns_per_ms),
            },
        );
    }
    return stats;
}

pub fn buildAndMaterializeReachableImportedModuleBodies(
    allocator: std.mem.Allocator,
    root_program: *ast.Node,
    ordered_modules: []const *SlaModule,
    modules: *SlaModuleTable,
    options: SlaImportExpansionOptions,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
) !ReachabilityMaterializationStats {
    reachable.clearRetainingCapacity();
    referenced_types.clearRetainingCapacity();
    var state = ReachabilityBuildState.init(allocator);
    defer state.deinit();
    try initializeReachabilityBuildState(&state, root_program, ordered_modules, modules, options, imported_macros, reachable, referenced_types);
    return try materializeReachableImportedModuleBodiesWithState(&state, allocator, ordered_modules, modules, options, imported_macros, reachable, referenced_types);
}

/// Materialize imported bodies for an already-populated reachable set.
/// Does not clear or recompute reachability (used by warm plan-cache hits).
/// One-shot materialize for warm plan-cache hits: select all currently reachable
/// bodies once, reparse each module once, then drain once.
pub fn materializeImportedModuleBodiesOneShot(
    allocator: std.mem.Allocator,
    ordered_modules: []const *SlaModule,
    modules: *SlaModuleTable,
    options: SlaImportExpansionOptions,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
) !ReachabilityMaterializationStats {
    var stats = ReachabilityMaterializationStats{};
    stats.passes = 1;

    var any_reparse = false;
    var state = ReachabilityBuildState.init(allocator);
    defer state.deinit();

    for (ordered_modules) |module| {
        if (module.has_function_bodies and module.has_macro_bodies) continue;
        var selected_functions = std.StringHashMap(void).init(allocator);
        defer selected_functions.deinit();
        var selected_macros = std.StringHashMap(void).init(allocator);
        defer selected_macros.deinit();
        var parsed_func_iter = module.parsed_function_bodies.keyIterator();
        while (parsed_func_iter.next()) |name_ptr| try selected_functions.put(name_ptr.*, {});
        var parsed_macro_iter = module.parsed_macro_bodies.keyIterator();
        while (parsed_macro_iter.next()) |name_ptr| try selected_macros.put(name_ptr.*, {});
        try collectReachableModuleBodyNames(allocator, module, reachable, referenced_types, &selected_functions, &selected_macros);
        if (selected_functions.count() == 0 and selected_macros.count() == 0) continue;
        if (stringSetsEqual(&selected_functions, &module.parsed_function_bodies) and
            stringSetsEqual(&selected_macros, &module.parsed_macro_bodies)) continue;
        if (!any_reparse) {
            // Lazily seed the callable index only if we will need drain multipass.
            for (ordered_modules) |m| {
                try state.callable_index.addDeclsFromModule(m.program.program.decls, m);
            }
        }
        _ = try modules.reparseModuleWithSelectedBodies(module, &selected_functions, &selected_macros);
        stats.reparses += 1;
        any_reparse = true;
        try state.callable_index.refreshDeclsFromModule(module);
    }

    if (!any_reparse) return stats;

    try drainReachabilityBuildState(&state, modules, options, imported_macros, reachable, referenced_types);
    stats.incremental_extensions = 1;
    const more = try materializeReachableImportedModuleBodiesWithState(&state, allocator, ordered_modules, modules, options, imported_macros, reachable, referenced_types);
    stats.passes += more.passes;
    stats.reparses += more.reparses;
    stats.incremental_extensions += more.incremental_extensions;
    return stats;
}

pub fn materializeImportedModuleBodiesForReachableSet(
    allocator: std.mem.Allocator,
    ordered_modules: []const *SlaModule,
    modules: *SlaModuleTable,
    options: SlaImportExpansionOptions,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
) !ReachabilityMaterializationStats {
    var state = ReachabilityBuildState.init(allocator);
    defer state.deinit();
    // Seed callable index from already-loaded modules so selection can resolve symbols.
    for (ordered_modules) |module| {
        try state.callable_index.addDeclsFromModule(module.program.program.decls, module);
    }
    return try materializeReachableImportedModuleBodiesWithState(&state, allocator, ordered_modules, modules, options, imported_macros, reachable, referenced_types);
}

pub fn materializeReachableImportedModuleBodies(
    allocator: std.mem.Allocator,
    root_program: *ast.Node,
    ordered_modules: []const *SlaModule,
    modules: *SlaModuleTable,
    options: SlaImportExpansionOptions,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
) !void {
    _ = try buildAndMaterializeReachableImportedModuleBodies(allocator, root_program, ordered_modules, modules, options, imported_macros, reachable, referenced_types);
}

pub fn testMatchesFilter(test_decl: *const ast.TestDecl, filter: ?[]const u8) bool {
    const pattern = filter orelse return true;
    if (pattern.len == 0) return true;
    return std.mem.indexOf(u8, test_decl.name, pattern) != null;
}

pub fn recordReferencedType(referenced_types: *std.StringHashMap(void), ty: *const ast.Type) anyerror!void {
    const curr = lowering_rules.peelBorrowPointerType(ty);
    switch (curr.*) {
        .array => |arr| try recordReferencedType(referenced_types, arr.elem),
        .tuple => |tup| {
            for (tup.elems) |t| try recordReferencedType(referenced_types, t);
        },
        .future => |f| try recordReferencedType(referenced_types, f),
        .closure => |cl| {
            for (cl.params) |t| try recordReferencedType(referenced_types, t);
            try recordReferencedType(referenced_types, cl.ret);
        },
        .fn_ptr => |fp| {
            for (fp.params) |t| try recordReferencedType(referenced_types, t);
            try recordReferencedType(referenced_types, fp.ret);
        },
        .user_defined => |ud| {
            try referenced_types.put(ud.name, {});
            for (ud.generics) |g| try recordReferencedType(referenced_types, g);
        },
        else => {},
    }
}

pub fn recordReferencedTypesFromTypeDecl(referenced_types: *std.StringHashMap(void), decl: *const ast.Node) !void {
    switch (decl.*) {
        .struct_decl => |sd| {
            for (sd.fields) |field| try recordReferencedType(referenced_types, field.ty);
        },
        .enum_decl => |ed| {
            for (ed.variants) |variant| {
                for (variant.fields) |field| try recordReferencedType(referenced_types, field.ty);
            }
        },
        .trait_decl => |td| {
            for (td.supertraits) |supertrait| try referenced_types.put(supertrait, {});
            for (td.methods) |method| {
                for (method.params) |param| try recordReferencedType(referenced_types, param.ty);
                try recordReferencedType(referenced_types, method.ret_ty);
            }
        },
        .type_alias_decl => |alias| {
            for (alias.components) |component| {
                switch (component) {
                    .ty => |ty| try recordReferencedType(referenced_types, ty),
                    .inline_struct => |fields| for (fields) |field| try recordReferencedType(referenced_types, field.ty),
                }
            }
        },
        else => {},
    }
}

pub fn scanReferencedExportedTypeSignatures(
    funcs: *const SlaCallableIndex,
    referenced_types: *std.StringHashMap(void),
    scanned_type_roots: *std.StringHashMap(void),
) !bool {
    if (referenced_types.count() == scanned_type_roots.count()) return false;

    var pending = std.ArrayList(*ast.Node).init(funcs.allocator);
    defer pending.deinit();

    var referenced_iter = referenced_types.keyIterator();
    while (referenced_iter.next()) |name_ptr| {
        const name = name_ptr.*;
        if (scanned_type_roots.contains(name)) continue;
        try scanned_type_roots.put(name, {});
        if (funcs.type_decls.get(name)) |decl| try pending.append(decl);
    }

    for (pending.items) |decl| try recordReferencedTypesFromTypeDecl(referenced_types, decl);
    return pending.items.len != 0;
}

pub fn markSyntacticReachableFunc(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    analysis: ?*ReachabilityAnalysis,
    call_facts: ?*const SyntacticFactSet,
    caller_name: ?[]const u8,
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    name: []const u8,
) !void {
    if (try moduleQualifiedCallableForCaller(funcs, modules, caller_name, name)) |qualified| {
        defer funcs.allocator.free(qualified);
        return try markSyntacticReachableFunc(funcs, modules, analysis, call_facts, caller_name, reachable, referenced_types, worklist, qualified);
    }
    if (!funcs.names.contains(name)) {
        if (modules) |mod_table| {
            if (mod_table.functionSignatureForImportedMangledNameByNamespace(name)) |signature| {
                return try markSyntacticReachableFunc(funcs, modules, analysis, call_facts, caller_name, reachable, referenced_types, worklist, signature.name);
            }
        }
        if (splitImportedMangledSymbol(name)) |imported| {
            if (funcs.names.contains(imported.name)) {
                return try markSyntacticReachableFunc(funcs, modules, analysis, call_facts, caller_name, reachable, referenced_types, worklist, imported.name);
            }
        }
        try funcs.recordUnresolvedCallable(.direct, name, caller_name, null);
        return;
    }
    const reachable_name = funcs.names.getKey(name) orelse return;

    if (funcs.moduleSource(reachable_name)) |callee_mp| {
        const caller_mp = if (caller_name) |c| funcs.moduleSource(c) else null;
        const same_module = if (caller_mp) |caller_path| std.mem.eql(u8, callee_mp, caller_path) else false;
        if (!same_module) {
            if (modules) |mod_table| {
                if (mod_table.modules.get(callee_mp)) |mod| {
                    var exported = mod.exports.exportsSymbol(reachable_name);
                    if (!exported) {
                        if (splitImportedMangledSymbol(reachable_name)) |imported| {
                            exported = moduleNamespaceMatchesImportPath(mod.output_path, imported.namespace) and
                                mod.exports.exportsSymbol(imported.name);
                        }
                    }
                    if (!exported) {
                        return;
                    }
                }
            }
        }
    }

    const facts_changed = if (analysis) |a|
        try a.mergeFunctionFacts(reachable_name, call_facts)
    else
        false;

    if (reachable.contains(reachable_name)) {
        if (facts_changed) try worklist.append(reachable_name);
        return;
    }

    try reachable.put(reachable_name, {});
    try worklist.append(reachable_name);
}

pub fn associatedCandidateMatchesReceiverType(candidate: []const u8, type_name: []const u8, method_name: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, type_name)) return false;
    if (candidate.len == type_name.len + 1 + method_name.len and
        candidate[type_name.len] == '_' and
        std.mem.eql(u8, candidate[type_name.len + 1 ..], method_name))
    {
        return true;
    }

    if (candidate.len <= type_name.len + 3 + method_name.len) return false;
    if (candidate[type_name.len] != '_' or candidate[type_name.len + 1] != '_') return false;
    if (!std.mem.endsWith(u8, candidate, method_name)) return false;
    return candidate[candidate.len - method_name.len - 1] == '_';
}

pub fn markSyntacticAssociatedCallCandidates(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    analysis: ?*ReachabilityAnalysis,
    direct_call_facts: ?*const SyntacticFactSet,
    caller_name: ?[]const u8,
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    method_name: []const u8,
    target_type_name: ?[]const u8,
) !void {
    if (funcs.associated_candidates.get(method_name)) |candidates| {
        if (target_type_name) |type_name| {
            var marked_typed_candidate = false;
            for (candidates.items) |name| {
                if (!associatedCandidateMatchesReceiverType(name, type_name, method_name)) continue;
                marked_typed_candidate = true;
                try markSyntacticReachableFunc(funcs, modules, analysis, direct_call_facts, caller_name, reachable, referenced_types, worklist, name);
            }
            if (marked_typed_candidate) return;
        }
        try markSyntacticReachableFunc(funcs, modules, analysis, direct_call_facts, caller_name, reachable, referenced_types, worklist, method_name);
        for (candidates.items) |name| try markSyntacticReachableFunc(funcs, modules, analysis, direct_call_facts, caller_name, reachable, referenced_types, worklist, name);
        return;
    }
    try funcs.recordUnresolvedCallable(.associated, method_name, caller_name, target_type_name);
    try markSyntacticReachableFunc(funcs, modules, analysis, direct_call_facts, caller_name, reachable, referenced_types, worklist, method_name);
}

pub fn syntacticAssociatedTargetTypeName(call: ast.CallExpr, facts: ?*const SyntacticFactSet) ?[]const u8 {
    const target_name = call.associated_target orelse return null;
    if (facts) |f| {
        if (f.getLocalType(target_name)) |type_name| return type_name;
    }
    return target_name;
}

pub fn syntacticReceiverExprTypeName(expr: *const ast.Node, facts: ?*const SyntacticFactSet) ?[]const u8 {
    return switch (expr.*) {
        .identifier => |name| if (facts) |f| f.getLocalType(name) else null,
        .struct_literal => |lit| lowering_rules.concreteTypeName(lit.ty),
        .borrow_expr => |borrow| syntacticReceiverExprTypeName(borrow.expr, facts),
        .move_expr => |move| syntacticReceiverExprTypeName(move.expr, facts),
        else => null,
    };
}

pub fn syntacticMethodCallReceiverTypeName(call: ast.CallExpr, facts: ?*const SyntacticFactSet) ?[]const u8 {
    if (call.args.len == 0) return null;
    return syntacticReceiverExprTypeName(call.args[0], facts);
}

pub fn collectSyntacticReachableExpr(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    analysis: ?*ReachabilityAnalysis,
    caller_name: ?[]const u8,
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    expr: *const ast.Node,
) anyerror!void {
    switch (expr.*) {
        .identifier => |name| {
            try markSyntacticReachableFunc(funcs, modules, analysis, null, caller_name, reachable, referenced_types, worklist, name);
            try referenced_types.put(name, {});
        },
        .generic_func_ref => |ref| {
            try markSyntacticReachableFunc(funcs, modules, analysis, null, caller_name, reachable, referenced_types, worklist, ref.func_name);
            // The defining transitive module may not have been lazily
            // discovered yet. Keep the bare template name as a discovery root
            // just like an unresolved ordinary call.
            try referenced_types.put(ref.func_name, {});
            for (ref.generics) |ty| try recordReferencedType(referenced_types, ty);
        },
        .call_expr => |call| {
            var direct_call_facts: ?SyntacticFactSet = null;
            defer if (direct_call_facts) |*facts| facts.deinit();
            if (analysis) |a| {
                if (try syntacticFuncDeclForCallFromCaller(funcs, modules, caller_name, call.func_name)) |fd| {
                    direct_call_facts = try buildCallFactsForDecl(a.allocator, funcs, modules, fd, &call, a.current_facts, 4);
                }
            }
            const call_facts_ptr: ?*const SyntacticFactSet = if (direct_call_facts) |*facts| facts else null;
            if (call.associated_target == null and !funcs.macro_decls.contains(call.func_name)) {
                const imported_macro_loaded = if (imported_macros) |macros| macros.contains(call.func_name) else false;
                if (!imported_macro_loaded) try funcs.recordUnresolvedCallable(.imported_macro, call.func_name, caller_name, null);
            }
            if (call.associated_target != null) {
                const target_type_name = syntacticAssociatedTargetTypeName(call, if (analysis) |a| a.current_facts else null);
                try markSyntacticAssociatedCallCandidates(funcs, modules, analysis, call_facts_ptr, caller_name, reachable, referenced_types, worklist, call.func_name, target_type_name);
            } else {
                if (imported_macros) |macros| {
                    if (macros.get(call.func_name)) |macro| {
                        for (macro.direct_callees) |callee| {
                            try markSyntacticReachableFunc(funcs, modules, analysis, null, caller_name, reachable, referenced_types, worklist, callee);
                        }
                    }
                }
                try markSyntacticReachableFunc(funcs, modules, analysis, call_facts_ptr, caller_name, reachable, referenced_types, worklist, call.func_name);
                const receiver_type_name = syntacticMethodCallReceiverTypeName(call, if (analysis) |a| a.current_facts else null);
                try markSyntacticAssociatedCallCandidates(funcs, modules, analysis, call_facts_ptr, caller_name, reachable, referenced_types, worklist, call.func_name, receiver_type_name);
                if (funcs.macro_decls.contains(call.func_name)) {
                    try referenced_types.put(call.func_name, {});
                } else if (syntacticFuncDeclForCall(funcs, modules, call.func_name) == null) {
                    try referenced_types.put(call.func_name, {});
                }
            }
            for (call.generics) |ty| try recordReferencedType(referenced_types, ty);
            for (call.args) |arg| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, arg);
        },
        .if_expr => |ife| {
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, ife.cond);
            if (ife.let_chain) |chain| {
                for (chain) |cond| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, cond.value);
            }
            const condition_value = if (analysis) |a|
                if (a.prune_known_branches) evalSyntacticBool(ife.cond, a.current_facts) else null
            else
                null;
            if (condition_value) |known| {
                if (known) {
                    try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, ife.then_block);
                } else if (ife.else_block) |else_block| {
                    try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, else_block);
                }
            } else {
                try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, ife.then_block);
                if (ife.else_block) |else_block| try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, else_block);
            }
        },
        .switch_expr => |swe| {
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, swe.val);
            for (swe.cases) |case| {
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, case.pattern);
                try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, case.body);
            }
        },
        .match_expr => |mat| {
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, mat.val);
            for (mat.cases) |case| {
                if (case.guard) |guard| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, guard);
                try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, case.body);
            }
        },
        .unsafe_expr => |unsafe_expr| try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, unsafe_expr.body),
        .await_expr => |await_expr| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, await_expr.expr),
        .try_expr => |try_expr| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, try_expr.expr),
        .binary_expr => |bin| {
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, bin.left);
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, bin.right);
        },
        .closure_literal => |closure| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, closure.body),
        .borrow_expr => |borrow| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, borrow.expr),
        .move_expr => |move| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, move.expr),
        .deref_expr => |deref| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, deref.expr),
        .cast_expr => |cast| {
            try recordReferencedType(referenced_types, cast.ty);
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, cast.expr);
        },
        .field_expr => |field| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, field.expr),
        .struct_literal => |lit| {
            try recordReferencedType(referenced_types, lit.ty);
            for (lit.fields) |field| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, field.value);
            if (lit.update_expr) |update| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, update);
        },
        .enum_literal => |lit| {
            try referenced_types.put(lit.enum_name, {});
            for (lit.fields) |field| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, field.value);
        },
        .tuple_literal => |lit| for (lit.elements) |elem| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, elem),
        .array_literal => |lit| for (lit.elements) |elem| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, elem),
        .repeat_array_literal => |lit| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, lit.value),
        .index_expr => |idx| {
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, idx.target);
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, idx.index);
        },
        .slice_expr => |slice| {
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, slice.target);
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, slice.start);
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, slice.end);
        },
        else => {},
    }
}

pub fn collectSyntacticReachableBlock(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    analysis: ?*ReachabilityAnalysis,
    caller_name: ?[]const u8,
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    block: []const *ast.Node,
) anyerror!void {
    var local_facts: ?SyntacticFactSet = null;
    const previous_facts = if (analysis) |a| a.current_facts else null;
    if (analysis) |a| {
        local_facts = if (a.current_facts) |facts| try facts.clone() else SyntacticFactSet.init(a.allocator);
        a.current_facts = &local_facts.?;
    }
    defer {
        if (analysis) |a| a.current_facts = previous_facts;
        if (local_facts) |*facts| facts.deinit();
    }

    for (block) |stmt| {
        switch (stmt.*) {
            .let_stmt => |let| {
                if (let.ty) |ty| try recordReferencedType(referenced_types, ty);
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, let.value);
                if (local_facts) |*facts| try updateFactsForLetBinding(facts, funcs, modules, let.name, let.ty, let.value);
            },
            .let_else_stmt => |let| {
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, let.value);
                try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, let.else_block);
            },
            .let_destructure_stmt => |let| {
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, let.value);
                if (local_facts) |*facts| {
                    for (let.names) |name| facts.clearName(name);
                    if (let.rest_name) |name| facts.clearName(name);
                    if (let.rest_alias) |name| facts.clearName(name);
                }
            },
            .const_stmt => |c| {
                if (c.ty) |ty| try recordReferencedType(referenced_types, ty);
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, c.value);
                if (local_facts) |*facts| try updateFactsForLetBinding(facts, funcs, modules, c.name, c.ty, c.value);
            },
            .assign_stmt => |assign| {
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, assign.target);
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, assign.value);
                if (local_facts) |*facts| {
                    if (assign.target.* == .identifier) facts.clearName(assign.target.identifier);
                }
            },
            .block_stmt => |blk| try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, blk.body),
            .expr_stmt => |expr| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, expr),
            .return_stmt => |ret| if (ret.value) |value| try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, value),
            .for_stmt => |for_stmt| {
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, for_stmt.start);
                if (for_stmt.end) |end_expr| {
                    try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, end_expr);
                } else {
                    const iterable_type_name = syntacticReceiverExprTypeName(for_stmt.start, if (analysis) |a| a.current_facts else null);
                    try markSyntacticAssociatedCallCandidates(funcs, modules, analysis, null, caller_name, reachable, referenced_types, worklist, "iter_len", iterable_type_name);
                    try markSyntacticAssociatedCallCandidates(funcs, modules, analysis, null, caller_name, reachable, referenced_types, worklist, "iter_at", iterable_type_name);
                }
                try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, for_stmt.body);
            },
            .while_stmt => |while_stmt| {
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, while_stmt.cond);
                try collectSyntacticReachableBlock(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, while_stmt.body);
            },
            else => try collectSyntacticReachableExpr(funcs, modules, imported_macros, analysis, caller_name, reachable, referenced_types, worklist, stmt),
        }
    }
}
