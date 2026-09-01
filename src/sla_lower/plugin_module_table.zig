const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const source_expand = @import("source_expand.zig");
const lowering_rules = @import("lowering_rules.zig");
const host_paths = @import("host_paths.zig");
const plugin_imports = @import("plugin_imports.zig");

const ResolvedImport = plugin_imports.ResolvedImport;
const ResolvedModuleImport = plugin_imports.ResolvedModuleImport;
const moduleNamespaceFromImportPath = plugin_imports.moduleNamespaceFromImportPath;
const moduleNamespaceMatchesImportPath = plugin_imports.moduleNamespaceMatchesImportPath;
const resolveImportFiles = plugin_imports.resolveImportFiles;
const splitImportedMangledSymbol = plugin_imports.splitImportedMangledSymbol;

fn moduleTableProfileEnabled() bool {
    // Match SLA_PROFILE used by import-expand / compile stages.
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "SLA_PROFILE") catch return false;
    defer std.heap.page_allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

pub const SlaModuleExports = struct {
    pub const FunctionSignature = struct {
        name: []const u8,
        params: []const ast.Param,
        ret_ty: *ast.Type,
        is_pub: bool,
        is_extern: bool,
        abi: ?[]const u8,
        no_mangle: bool,
        is_async: bool,
        module_path: []const u8,
    };

    pub const TypeKind = enum { struct_decl, enum_decl, trait_decl, type_alias_decl };

    pub const TypeSignature = struct {
        name: []const u8,
        kind: TypeKind,
        generics: []const []const u8,
        module_path: []const u8,
    };

    pub const ConstSignature = struct {
        name: []const u8,
        ty: ?*ast.Type,
        module_path: []const u8,
    };

    pub const MacroSignature = struct {
        name: []const u8,
        params: []const []const u8,
        module_path: []const u8,
    };

    allocator: std.mem.Allocator,
    module_path: []const u8,
    type_decls: std.StringHashMap(*ast.Node),
    type_signatures: std.StringHashMap(TypeSignature),
    function_decls: std.StringHashMap(*ast.Node),
    function_signatures: std.StringHashMap(FunctionSignature),
    associated_function_decls: std.StringHashMap(*ast.Node),
    associated_function_signatures: std.StringHashMap(FunctionSignature),
    const_decls: std.StringHashMap(*ast.Node),
    const_signatures: std.StringHashMap(ConstSignature),
    macro_decls: std.StringHashMap(*ast.Node),
    macro_signatures: std.StringHashMap(MacroSignature),
    impl_decls: std.ArrayList(*ast.Node),
    trait_impl_decls: std.ArrayList(*ast.Node),

    pub fn init(allocator: std.mem.Allocator, module_path: []const u8) SlaModuleExports {
        return .{
            .allocator = allocator,
            .module_path = module_path,
            .type_decls = std.StringHashMap(*ast.Node).init(allocator),
            .type_signatures = std.StringHashMap(TypeSignature).init(allocator),
            .function_decls = std.StringHashMap(*ast.Node).init(allocator),
            .function_signatures = std.StringHashMap(FunctionSignature).init(allocator),
            .associated_function_decls = std.StringHashMap(*ast.Node).init(allocator),
            .associated_function_signatures = std.StringHashMap(FunctionSignature).init(allocator),
            .const_decls = std.StringHashMap(*ast.Node).init(allocator),
            .const_signatures = std.StringHashMap(ConstSignature).init(allocator),
            .macro_decls = std.StringHashMap(*ast.Node).init(allocator),
            .macro_signatures = std.StringHashMap(MacroSignature).init(allocator),
            .impl_decls = std.ArrayList(*ast.Node).init(allocator),
            .trait_impl_decls = std.ArrayList(*ast.Node).init(allocator),
        };
    }

    pub fn deinit(self: *SlaModuleExports) void {
        self.trait_impl_decls.deinit();
        self.impl_decls.deinit();
        self.macro_signatures.deinit();
        self.macro_decls.deinit();
        self.const_signatures.deinit();
        self.const_decls.deinit();
        var associated_key_iter = self.associated_function_decls.keyIterator();
        while (associated_key_iter.next()) |key_ptr| self.allocator.free(key_ptr.*);
        self.associated_function_signatures.deinit();
        self.associated_function_decls.deinit();
        self.function_signatures.deinit();
        self.function_decls.deinit();
        self.type_signatures.deinit();
        self.type_decls.deinit();
    }

    pub fn addDecl(table: *std.StringHashMap(*ast.Node), name: []const u8, decl: *ast.Node) !void {
        try table.put(name, decl);
    }

    pub fn addFunctionSignature(self: *SlaModuleExports, fd: *ast.FuncDecl) !void {
        try self.addFunctionSignatureNamed(&self.function_signatures, fd.name, fd);
    }

    pub fn addFunctionSignatureNamed(self: *SlaModuleExports, table: *std.StringHashMap(FunctionSignature), name: []const u8, fd: *ast.FuncDecl) !void {
        try table.put(name, .{
            .name = name,
            .params = fd.params,
            .ret_ty = fd.ret_ty,
            .is_pub = fd.is_pub,
            .is_extern = fd.is_extern,
            .abi = fd.abi,
            .no_mangle = fd.no_mangle,
            .is_async = fd.is_async,
            .module_path = self.module_path,
        });
    }

    pub fn addAssociatedFunctionDecl(self: *SlaModuleExports, symbol: []const u8, decl: *ast.Node) !void {
        try self.associated_function_decls.put(symbol, decl);
        try self.addFunctionSignatureNamed(&self.associated_function_signatures, symbol, &decl.func_decl);
    }

    pub fn addTypeSignature(self: *SlaModuleExports, name: []const u8, kind: TypeKind, generics: []const []const u8) !void {
        try self.type_signatures.put(name, .{
            .name = name,
            .kind = kind,
            .generics = generics,
            .module_path = self.module_path,
        });
    }

    pub fn addConstSignature(self: *SlaModuleExports, c: *ast.ConstStmt) !void {
        try self.const_signatures.put(c.name, .{
            .name = c.name,
            .ty = c.ty,
            .module_path = self.module_path,
        });
    }

    pub fn addMacroSignature(self: *SlaModuleExports, m: *ast.MacroDecl) !void {
        try self.macro_signatures.put(m.name, .{
            .name = m.name,
            .params = m.params,
            .module_path = self.module_path,
        });
    }

    pub fn buildFromDecls(self: *SlaModuleExports, decls: []const *ast.Node) !void {
        for (decls) |decl| {
            switch (decl.*) {
                .struct_decl => |s| {
                    try addDecl(&self.type_decls, s.name, decl);
                    try self.addTypeSignature(s.name, .struct_decl, s.generics);
                },
                .enum_decl => |e| {
                    try addDecl(&self.type_decls, e.name, decl);
                    try self.addTypeSignature(e.name, .enum_decl, e.generics);
                },
                .trait_decl => |t| {
                    try addDecl(&self.type_decls, t.name, decl);
                    try self.addTypeSignature(t.name, .trait_decl, &.{});
                },
                .type_alias_decl => |a| {
                    try addDecl(&self.type_decls, a.name, decl);
                    try self.addTypeSignature(a.name, .type_alias_decl, &.{});
                },
                .func_decl => |f| {
                    try addDecl(&self.function_decls, f.name, decl);
                    try self.addFunctionSignature(&decl.func_decl);
                },
                .const_stmt => |c| {
                    try addDecl(&self.const_decls, c.name, decl);
                    try self.addConstSignature(&decl.const_stmt);
                },
                .macro_decl => |m| {
                    try addDecl(&self.macro_decls, m.name, decl);
                    try self.addMacroSignature(&decl.macro_decl);
                },
                .impl_decl => |impl| {
                    try self.impl_decls.append(decl);
                    if (impl.trait_name != null) try self.trait_impl_decls.append(decl);
                    const type_name = lowering_rules.concreteTypeName(impl.target_ty) orelse continue;
                    for (impl.methods) |method| {
                        if (method.* != .func_decl) continue;
                        const symbol = if (impl.trait_name) |trait_name|
                            try lowering_rules.mangleTraitMethodName(self.allocator, type_name, trait_name, method.func_decl.name)
                        else
                            try lowering_rules.mangleMethodName(self.allocator, type_name, method.func_decl.name);
                        try self.addAssociatedFunctionDecl(symbol, method);
                    }
                },
                .overload_decl => |overload| {
                    const type_name = lowering_rules.concreteTypeName(overload.target_ty) orelse continue;
                    for (overload.methods) |method| {
                        if (method.* != .func_decl) continue;
                        const symbol = try lowering_rules.mangleMethodName(self.allocator, type_name, method.func_decl.name);
                        try self.addAssociatedFunctionDecl(symbol, method);
                    }
                },
                else => {},
            }
        }
    }

    pub fn exportsType(self: *const SlaModuleExports, name: []const u8) bool {
        return self.type_decls.contains(name);
    }
    pub fn typeSignature(self: *const SlaModuleExports, name: []const u8) ?TypeSignature {
        return self.type_signatures.get(name);
    }
    pub fn exportsFunction(self: *const SlaModuleExports, name: []const u8) bool {
        return self.function_decls.contains(name);
    }
    pub fn functionSignature(self: *const SlaModuleExports, name: []const u8) ?FunctionSignature {
        return self.function_signatures.get(name) orelse self.associated_function_signatures.get(name);
    }
    pub fn exportsConst(self: *const SlaModuleExports, name: []const u8) bool {
        return self.const_decls.contains(name);
    }
    pub fn constSignature(self: *const SlaModuleExports, name: []const u8) ?ConstSignature {
        return self.const_signatures.get(name);
    }
    pub fn exportsMacro(self: *const SlaModuleExports, name: []const u8) bool {
        return self.macro_decls.contains(name);
    }
    pub fn macroSignature(self: *const SlaModuleExports, name: []const u8) ?MacroSignature {
        return self.macro_signatures.get(name);
    }
    pub fn exportsSymbol(self: *const SlaModuleExports, name: []const u8) bool {
        if (self.function_decls.contains(name)) return true;
        if (self.associated_function_decls.contains(name)) return true;
        if (self.const_decls.contains(name)) return true;
        if (self.macro_decls.contains(name)) return true;

        var type_iter = self.type_decls.keyIterator();
        while (type_iter.next()) |type_name_ptr| {
            const type_name = type_name_ptr.*;
            if (std.mem.startsWith(u8, name, type_name)) {
                if (name.len > type_name.len and (name[type_name.len] == '_' or name[type_name.len] == '|')) {
                    return true;
                }
            }
            if (std.mem.indexOf(u8, name, type_name)) |idx| {
                if (idx > 0 and name[idx - 1] == '_') {
                    return true;
                }
            }
        }
        return false;
    }
};

pub const SlaModule = struct {
    path: []const u8,
    output_path: []const u8,
    base_dir: []const u8,
    source: []const u8,
    expanded_source: []const u8,
    known_types: []const []const u8,
    known_enums: []const []const u8,
    program: *ast.Node,
    exports: SlaModuleExports,
    resolved_imports: []const ResolvedImport,
    resolved_module_imports: []const ResolvedModuleImport,
    has_function_bodies: bool,
    has_macro_bodies: bool,
    parsed_function_bodies: std.StringHashMap(void),
    parsed_macro_bodies: std.StringHashMap(void),
    /// Exact `{ ... }` body source slices for top-level and associated functions.
    /// Values borrow into `expanded_source` and are valid for the module lifetime.
    function_body_spans: std.StringHashMap([]const u8),
};

pub const SlaImportExpansionOptions = struct {
    prune_for_test_codegen: bool = false,
    test_filter: ?[]const u8 = null,
    imported_bodies_decl_only: bool = false,
    load_reachable_imported_bodies_from_registry: bool = false,
    lazy_transitive_sla_imports: bool = false,
    /// When true, skip expensive root-body reachability walks and retain every
    /// imported module's declarations (typically decl-only). Used by `sla check`
    /// where correctness does not require selective import pruning.
    include_all_imported_decls: bool = false,
};

pub const SlaResolvedImportGroup = struct {
    decl: *const ast.Node,
    imports: []const ResolvedImport,
};

pub const SlaModuleReparseStats = struct {
    parse_ns: i128 = 0,
    exports_ns: i128 = 0,
    commit_ns: i128 = 0,
};

pub const SlaModuleTable = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(*SlaModule),
    import_type_scan_cache: parser_mod.ImportTypeScanCache,
    import_type_scan_cache_hits: usize,
    resolved_import_source_cache_hits: usize,
    expanded_source_cache_hits: usize,
    parse_options: parser_mod.Parser.Options,
    capture_body_spans: bool = true,

    pub fn init(allocator: std.mem.Allocator) SlaModuleTable {
        return initWithParserOptions(allocator, .{
            .parse_test_bodies = false,
            // Module-table import discovery already walks @import via getOrParse.
            // Recursive parser prescanning would re-expand/reparse large dependencies
            // (e.g. schedule_table_erased -> world_table_erased) before getOrParse.
            .prescan_sla_import_types = false,
        });
    }

    pub fn initWithParserOptions(allocator: std.mem.Allocator, parse_options: parser_mod.Parser.Options) SlaModuleTable {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(*SlaModule).init(allocator),
            .import_type_scan_cache = parser_mod.ImportTypeScanCache.init(allocator),
            .import_type_scan_cache_hits = 0,
            .resolved_import_source_cache_hits = 0,
            .expanded_source_cache_hits = 0,
            .parse_options = parse_options,
            .capture_body_spans = true,
        };
    }

    pub fn deinit(self: *SlaModuleTable) void {
        var module_iter = self.modules.valueIterator();
        while (module_iter.next()) |module_ptr| {
            const module = module_ptr.*;
            for (module.resolved_module_imports) |resolved_import| {
                self.allocator.free(resolved_import.namespace);
            }
            self.allocator.free(module.resolved_module_imports);
            self.allocator.free(module.resolved_imports);
            self.allocator.free(module.known_enums);
            self.allocator.free(module.known_types);
            var span_key_iter = module.function_body_spans.keyIterator();
            while (span_key_iter.next()) |key_ptr| self.allocator.free(key_ptr.*);
            module.function_body_spans.deinit();
            module.parsed_macro_bodies.deinit();
            module.parsed_function_bodies.deinit();
            module.exports.deinit();
            self.allocator.destroy(module);
        }
        self.modules.deinit();
        self.import_type_scan_cache.deinit();
    }

    pub fn buildModuleImportNamespaces(self: *SlaModuleTable, resolved_imports: []const ResolvedImport) ![]const ResolvedModuleImport {
        var imports = std.ArrayList(ResolvedModuleImport).init(self.allocator);
        try imports.ensureTotalCapacity(resolved_imports.len);
        for (resolved_imports) |resolved| {
            if (!std.mem.endsWith(u8, resolved.path, ".sla")) continue;
            try imports.append(.{
                .namespace = try moduleNamespaceFromImportPath(self.allocator, resolved.output_path),
                .resolved = resolved,
            });
        }
        return try imports.toOwnedSlice();
    }

    pub fn importTypeScanCacheCount(self: *const SlaModuleTable) usize {
        return self.import_type_scan_cache.count();
    }

    pub fn importTypeScanCacheHitCount(self: *const SlaModuleTable) usize {
        return self.import_type_scan_cache_hits;
    }

    pub fn resolvedImportSourceCacheHitCount(self: *const SlaModuleTable) usize {
        return self.resolved_import_source_cache_hits;
    }

    pub fn expandedSourceCacheHitCount(self: *const SlaModuleTable) usize {
        return self.expanded_source_cache_hits;
    }

    fn cachedPlainSlaImport(self: *SlaModuleTable, base_dir: []const u8, import_path: []const u8, exclude_path: []const u8) !?ResolvedImport {
        if (!std.mem.endsWith(u8, import_path, ".sla") or
            plugin_imports.isGlobImportPath(import_path) or
            plugin_imports.isSlaStdImport(import_path) or
            plugin_imports.isSaStdImport(import_path)) return null;

        const candidate = if (std.fs.path.isAbsolute(import_path))
            try self.allocator.dupe(u8, import_path)
        else
            try std.fs.path.join(self.allocator, &.{ base_dir, import_path });
        const canonical_path_raw = std.fs.cwd().realpathAlloc(self.allocator, candidate) catch return null;
        const canonical_path = host_paths.normalizePathSlashes(self.allocator, canonical_path_raw) catch canonical_path_raw;
        if (!std.mem.eql(u8, canonical_path, canonical_path_raw)) self.allocator.free(canonical_path_raw);
        if (std.mem.eql(u8, canonical_path, exclude_path)) return null;
        const surface = self.import_type_scan_cache.get(canonical_path) orelse return null;
        if (!surface.complete) return null;
        self.resolved_import_source_cache_hits += 1;
        return .{
            .path = canonical_path,
            .output_path = candidate,
            .source = surface.source,
        };
    }

    pub fn resolveModuleImports(self: *SlaModuleTable, module_path: []const u8, base_dir: []const u8, decls: []const *ast.Node) ![]const ResolvedImport {
        var imports = std.ArrayList(ResolvedImport).init(self.allocator);
        // Most modules have few imports; pre-size for the upper bound of import_decl
        // nodes so getOrParse resolve-roots avoids repeated ArrayList growth.
        try imports.ensureTotalCapacity(decls.len);
        for (decls) |decl| {
            if (decl.* != .import_decl) continue;
            if (try self.cachedPlainSlaImport(base_dir, decl.import_decl.path, module_path)) |cached| {
                try imports.append(cached);
                continue;
            }
            const resolved = try resolveImportFiles(self.allocator, base_dir, decl.import_decl.path, module_path);
            try imports.appendSlice(resolved);
        }
        return try imports.toOwnedSlice();
    }

    pub fn getOrParse(self: *SlaModuleTable, resolved: ResolvedImport) !*SlaModule {
        if (self.modules.get(resolved.path)) |module| return module;

        const profile = moduleTableProfileEnabled();
        const total_start = if (profile) std.time.nanoTimestamp() else 0;
        const base_dir = std.fs.path.dirname(resolved.path) orelse ".";
        const expand_start = if (profile) std.time.nanoTimestamp() else 0;
        const cache_lookup_path = blk: {
            const raw = std.fs.cwd().realpathAlloc(self.allocator, resolved.path) catch break :blk resolved.path;
            const normed = host_paths.normalizePathSlashes(self.allocator, raw) catch {
                break :blk raw;
            };
            self.allocator.free(raw);
            break :blk normed;
        };
        const expanded_source = if (self.import_type_scan_cache.get(cache_lookup_path) orelse self.import_type_scan_cache.get(resolved.path)) |surface| blk: {
            if (!surface.complete) break :blk try source_expand.expandForModulePath(self.allocator, resolved.path, resolved.source);
            self.expanded_source_cache_hits += 1;
            break :blk surface.expanded_source;
        } else try source_expand.expandForModulePath(self.allocator, resolved.path, resolved.source);
        const expand_ns = if (profile) std.time.nanoTimestamp() - expand_start else 0;
        const parse_start = if (profile) std.time.nanoTimestamp() else 0;
        var parser = parser_mod.Parser.initWithDirAndOptions(self.allocator, expanded_source, base_dir, self.parse_options);
        parser.seedImportTypeScanCache(self.import_type_scan_cache);
        const parsed = try parser.parseProgram();
        self.import_type_scan_cache = parser.importTypeScanCache();
        self.import_type_scan_cache_hits += parser.importTypeScanCacheHitCount();
        if (parsed.* != .program) return error.InvalidProgram;
        const parse_ns = if (profile) std.time.nanoTimestamp() - parse_start else 0;

        const exports_start = if (profile) std.time.nanoTimestamp() else 0;
        var exports = SlaModuleExports.init(self.allocator, resolved.path);
        try exports.buildFromDecls(parsed.program.decls);
        const resolved_imports = try self.resolveModuleImports(resolved.path, base_dir, parsed.program.decls);
        const resolved_module_imports = try self.buildModuleImportNamespaces(resolved_imports);
        const exports_ns = if (profile) std.time.nanoTimestamp() - exports_start else 0;
        if (profile) {
            const total_ms = @divTrunc(std.time.nanoTimestamp() - total_start, std.time.ns_per_ms);
            const expand_ms = @divTrunc(expand_ns, std.time.ns_per_ms);
            const parse_ms = @divTrunc(parse_ns, std.time.ns_per_ms);
            const exports_ms = @divTrunc(exports_ns, std.time.ns_per_ms);
            const base_name = std.fs.path.basename(resolved.path);
            std.debug.print("[sla-profile] getOrParse {s}: total={d}ms expand={d}ms parse={d}ms exports+imports={d}ms\n", .{ base_name, total_ms, expand_ms, parse_ms, exports_ms });
        }

        const module = try self.allocator.create(SlaModule);
        module.* = .{
            .path = resolved.path,
            .output_path = resolved.output_path,
            .base_dir = base_dir,
            .source = resolved.source,
            .expanded_source = expanded_source,
            .known_types = try self.allocator.dupe([]const u8, parser.knownTypeNames()),
            .known_enums = try self.allocator.dupe([]const u8, parser.knownEnumNames()),
            .program = parsed,
            .exports = exports,
            .resolved_imports = resolved_imports,
            .resolved_module_imports = resolved_module_imports,
            .has_function_bodies = self.parse_options.parse_function_bodies and self.parse_options.function_body_names == null,
            .has_macro_bodies = self.parse_options.parse_macro_bodies and self.parse_options.macro_body_names == null,
            .parsed_function_bodies = std.StringHashMap(void).init(self.allocator),
            .parsed_macro_bodies = std.StringHashMap(void).init(self.allocator),
            .function_body_spans = std.StringHashMap([]const u8).init(self.allocator),
        };
        const spans_start = if (profile) std.time.nanoTimestamp() else 0;
        if (self.capture_body_spans) {
            try captureModuleFunctionBodySpans(self.allocator, module, &parser);
        }
        if (profile) {
            const spans_ms = @divTrunc(std.time.nanoTimestamp() - spans_start, std.time.ns_per_ms);
            if (spans_ms > 0) {
                std.debug.print("[sla-profile] getOrParse {s}: body_spans={d}ms\n", .{ std.fs.path.basename(module.path), spans_ms });
            }
        }
        if (self.parse_options.parse_function_bodies) {
            if (self.parse_options.function_body_names) |selected| {
                var selected_iter = selected.keyIterator();
                while (selected_iter.next()) |name_ptr| try module.parsed_function_bodies.put(name_ptr.*, {});
            }
        }
        if (self.parse_options.parse_macro_bodies) {
            if (self.parse_options.macro_body_names) |selected| {
                var selected_iter = selected.keyIterator();
                while (selected_iter.next()) |name_ptr| try module.parsed_macro_bodies.put(name_ptr.*, {});
            }
        }
        try self.modules.put(module.path, module);

        // Publish this module's type surface into the shared import-type scan
        // cache so later parsers that `@import` it (e.g. tiny table_erased_access
        // depending on huge world_table_erased) hit mergeKnownTypeSurface instead
        // of re-expanding and re-parsing the whole file during prescan.
        const cache_path = blk: {
            const raw = std.fs.cwd().realpathAlloc(self.allocator, module.path) catch break :blk module.path;
            const normed = host_paths.normalizePathSlashes(self.allocator, raw) catch {
                break :blk raw;
            };
            self.allocator.free(raw);
            break :blk normed;
        };
        if (self.import_type_scan_cache.get(cache_path)) |existing| {
            if (!existing.complete) {
                try self.import_type_scan_cache.put(cache_path, .{
                    .types = module.known_types,
                    .enums = module.known_enums,
                    .source = module.source,
                    .expanded_source = module.expanded_source,
                    .complete = true,
                });
            }
        } else {
            try self.import_type_scan_cache.put(cache_path, .{
                .types = module.known_types,
                .enums = module.known_enums,
                .source = module.source,
                .expanded_source = module.expanded_source,
                .complete = true,
            });
        }
        // Also key by the unresolved path form used by some callers.
        if (!std.mem.eql(u8, cache_path, module.path)) {
            if (self.import_type_scan_cache.get(module.path) == null) {
                try self.import_type_scan_cache.put(module.path, .{
                    .types = module.known_types,
                    .enums = module.known_enums,
                    .source = module.source,
                    .expanded_source = module.expanded_source,
                    .complete = true,
                });
            }
        }

        return module;
    }

    pub fn reparseModuleWithSelectedBodies(
        self: *SlaModuleTable,
        module: *SlaModule,
        selected_function_bodies: ?*const std.StringHashMap(void),
        selected_macro_bodies: ?*const std.StringHashMap(void),
    ) !SlaModuleReparseStats {
        if (module.has_function_bodies and module.has_macro_bodies) return .{};

        // Prefer exact function-body span materialization when the module already
        // has a decl-only AST and no newly selected macros require a full reparse.
        // Macros still fall back to the full selected-body reparse path.
        if (try self.tryMaterializeSelectedFunctionBodiesInPlace(module, selected_function_bodies, selected_macro_bodies)) |stats| {
            return stats;
        }

        const parse_start = std.time.nanoTimestamp();
        var parser = parser_mod.Parser.initWithDirAndOptions(self.allocator, module.expanded_source, module.base_dir, .{
            .parse_function_bodies = true,
            .function_body_names = selected_function_bodies,
            .parse_macro_bodies = true,
            .macro_body_names = selected_macro_bodies,
            .parse_test_bodies = self.parse_options.parse_test_bodies,
            .prescan_sla_import_types = false,
        });
        try parser.seedKnownTypeNames(module.known_types, module.known_enums);
        const parsed = try parser.parseProgram();
        if (parsed.* != .program) return error.InvalidProgram;
        const parse_ns = std.time.nanoTimestamp() - parse_start;

        const exports_start = std.time.nanoTimestamp();
        var exports = SlaModuleExports.init(self.allocator, module.path);
        try exports.buildFromDecls(parsed.program.decls);
        const exports_ns = std.time.nanoTimestamp() - exports_start;

        const commit_start = std.time.nanoTimestamp();
        // Record the selected body-name sets into the module's persistent
        // tracking maps BEFORE freeing the old exports. Some selected names
        // (mangled method symbols such as `Type_method`) are strings owned by
        // the old `module.exports` and would be freed by `module.exports.deinit()`
        // below; storing the borrowed pointers directly would leave
        // `parsed_function_bodies` holding dangling keys, so the materialize
        // fixpoint's `stringSetsEqual` comparison would read corrupted memory,
        // never converge, and reparse unboundedly (OOM). Duping into
        // `self.allocator`-owned copies keeps the tracking keys valid and stable.
        module.parsed_function_bodies.clearRetainingCapacity();
        if (selected_function_bodies) |selected| {
            var selected_iter = selected.keyIterator();
            while (selected_iter.next()) |name_ptr| {
                const owned = try self.allocator.dupe(u8, name_ptr.*);
                try module.parsed_function_bodies.put(owned, {});
            }
        }
        module.parsed_macro_bodies.clearRetainingCapacity();
        if (selected_macro_bodies) |selected| {
            var selected_iter = selected.keyIterator();
            while (selected_iter.next()) |name_ptr| {
                const owned = try self.allocator.dupe(u8, name_ptr.*);
                try module.parsed_macro_bodies.put(owned, {});
            }
        }

        // Full reparses rebuild the AST; refresh body spans from the new parser
        // so later in-place materialization can resume from the updated surface.
        var span_key_iter = module.function_body_spans.keyIterator();
        while (span_key_iter.next()) |key_ptr| self.allocator.free(key_ptr.*);
        module.function_body_spans.clearRetainingCapacity();

        module.exports.deinit();
        module.program = parsed;
        module.exports = exports;
        try captureModuleFunctionBodySpans(self.allocator, module, &parser);
        module.has_function_bodies = selected_function_bodies == null;
        module.has_macro_bodies = selected_macro_bodies == null;
        return .{
            .parse_ns = parse_ns,
            .exports_ns = exports_ns,
            .commit_ns = std.time.nanoTimestamp() - commit_start,
        };
    }

    fn tryMaterializeSelectedFunctionBodiesInPlace(
        self: *SlaModuleTable,
        module: *SlaModule,
        selected_function_bodies: ?*const std.StringHashMap(void),
        selected_macro_bodies: ?*const std.StringHashMap(void),
    ) !?SlaModuleReparseStats {
        // Macro bodies still require a full reparse for now.
        if (selected_macro_bodies) |selected| {
            if (!stringSetsEqual(selected, &module.parsed_macro_bodies)) return null;
        } else if (!module.has_macro_bodies and module.parsed_macro_bodies.count() != 0) {
            return null;
        }

        const selected_functions = selected_function_bodies orelse return null;
        if (module.function_body_spans.count() == 0) return null;

        var new_function_count: usize = 0;
        var selected_iter = selected_functions.keyIterator();
        while (selected_iter.next()) |name_ptr| {
            if (module.parsed_function_bodies.contains(name_ptr.*)) continue;
            if (!module.function_body_spans.contains(name_ptr.*)) return null;
            new_function_count += 1;
        }
        // Nothing new to materialize for functions either.
        if (new_function_count == 0 and stringSetsEqual(selected_functions, &module.parsed_function_bodies)) {
            return .{};
        }
        if (new_function_count == 0) {
            // Selection shrank or only already-materialized bodies remain; keep
            // tracking set in sync without touching the AST.
            const commit_start = std.time.nanoTimestamp();
            try replaceParsedFunctionBodySet(self.allocator, module, selected_functions);
            return .{ .commit_ns = std.time.nanoTimestamp() - commit_start };
        }

        const parse_start = std.time.nanoTimestamp();
        selected_iter = selected_functions.keyIterator();
        while (selected_iter.next()) |name_ptr| {
            if (module.parsed_function_bodies.contains(name_ptr.*)) continue;
            const span = module.function_body_spans.get(name_ptr.*) orelse return null;
            const func_decl = moduleFunctionDeclBySymbol(module, name_ptr.*) orelse return null;
            if (func_decl.body.len != 0 and !func_decl.is_decl_only) continue;
            const body = try parser_mod.Parser.parseFunctionBodySpan(
                self.allocator,
                span,
                module.known_types,
                module.known_enums,
            );
            func_decl.body = body;
            func_decl.is_decl_only = false;
        }
        const parse_ns = std.time.nanoTimestamp() - parse_start;

        const commit_start = std.time.nanoTimestamp();
        try replaceParsedFunctionBodySet(self.allocator, module, selected_functions);
        // Preserve the historical null-selection meaning used by full reparses:
        // null means "all bodies of this kind are present".
        module.has_function_bodies = false;
        if (selected_macro_bodies == null) module.has_macro_bodies = true;
        return .{
            .parse_ns = parse_ns,
            .exports_ns = 0,
            .commit_ns = std.time.nanoTimestamp() - commit_start,
        };
    }

    pub fn moduleImportByNamespace(self: *const SlaModuleTable, module_path: []const u8, namespace: []const u8) ?ResolvedModuleImport {
        const module = self.modules.get(module_path) orelse return null;
        for (module.resolved_module_imports) |resolved_import| {
            if (std.mem.eql(u8, resolved_import.namespace, namespace)) return resolved_import;
        }
        return null;
    }

    pub fn exportsForModule(self: *const SlaModuleTable, module_path: []const u8) ?*const SlaModuleExports {
        const module = self.modules.get(module_path) orelse return null;
        return &module.exports;
    }

    pub fn functionSignature(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?SlaModuleExports.FunctionSignature {
        const exports = self.exportsForModule(module_path) orelse return null;
        return exports.functionSignature(name);
    }

    pub fn functionBody(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?*ast.FuncDecl {
        const exports = self.exportsForModule(module_path) orelse return null;
        const decl = exports.function_decls.get(name) orelse return null;
        if (decl.* != .func_decl) return null;
        return &decl.func_decl;
    }

    pub fn associatedFunctionBody(self: *const SlaModuleTable, module_path: []const u8, symbol: []const u8) ?*ast.FuncDecl {
        const module = self.modules.get(module_path) orelse return null;
        const decl = module.exports.associated_function_decls.get(symbol) orelse return null;
        if (decl.* != .func_decl) return null;
        return &decl.func_decl;
    }

    pub fn typeSignature(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?SlaModuleExports.TypeSignature {
        const exports = self.exportsForModule(module_path) orelse return null;
        return exports.typeSignature(name);
    }

    pub fn constSignature(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?SlaModuleExports.ConstSignature {
        const exports = self.exportsForModule(module_path) orelse return null;
        return exports.constSignature(name);
    }

    pub fn macroSignature(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?SlaModuleExports.MacroSignature {
        const exports = self.exportsForModule(module_path) orelse return null;
        return exports.macroSignature(name);
    }

    pub fn functionSignatureForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?SlaModuleExports.FunctionSignature {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.functionSignature(resolved_import.resolved.path, name);
    }

    pub fn functionBodyForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?*ast.FuncDecl {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.functionBody(resolved_import.resolved.path, name) orelse self.associatedFunctionBody(resolved_import.resolved.path, name);
    }

    pub fn typeSignatureForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?SlaModuleExports.TypeSignature {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.typeSignature(resolved_import.resolved.path, name);
    }

    pub fn constSignatureForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?SlaModuleExports.ConstSignature {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.constSignature(resolved_import.resolved.path, name);
    }

    pub fn macroSignatureForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?SlaModuleExports.MacroSignature {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.macroSignature(resolved_import.resolved.path, name);
    }

    pub fn functionSignatureForImportedMangledName(self: *SlaModuleTable, module_path: []const u8, symbol: []const u8) !?SlaModuleExports.FunctionSignature {
        const imported = splitImportedMangledSymbol(symbol) orelse return null;
        return try self.functionSignatureForImportNamespace(module_path, imported.namespace, imported.name);
    }

    pub fn functionBodyForImportedMangledName(self: *SlaModuleTable, module_path: []const u8, symbol: []const u8) !?*ast.FuncDecl {
        const imported = splitImportedMangledSymbol(symbol) orelse return null;
        return try self.functionBodyForImportNamespace(module_path, imported.namespace, imported.name);
    }

    pub fn functionSignatureForImportedMangledNameByNamespace(self: *const SlaModuleTable, symbol: []const u8) ?SlaModuleExports.FunctionSignature {
        const imported = splitImportedMangledSymbol(symbol) orelse return null;
        var module_iter = self.modules.valueIterator();
        while (module_iter.next()) |module_ptr| {
            const module = module_ptr.*;
            if (!moduleNamespaceMatchesImportPath(module.output_path, imported.namespace)) continue;
            if (module.exports.functionSignature(imported.name)) |signature| return signature;
        }
        return null;
    }
};

fn stringSetContainsAll(haystack: *const std.StringHashMap(void), needles: *const std.StringHashMap(void)) bool {
    var iter = needles.keyIterator();
    while (iter.next()) |name_ptr| {
        if (!haystack.contains(name_ptr.*)) return false;
    }
    return true;
}

fn stringSetsEqual(a: *const std.StringHashMap(void), b: *const std.StringHashMap(void)) bool {
    return a.count() == b.count() and stringSetContainsAll(a, b);
}

fn replaceParsedFunctionBodySet(
    allocator: std.mem.Allocator,
    module: *SlaModule,
    selected_function_bodies: *const std.StringHashMap(void),
) !void {
    module.parsed_function_bodies.clearRetainingCapacity();
    var selected_iter = selected_function_bodies.keyIterator();
    while (selected_iter.next()) |name_ptr| {
        const owned = try allocator.dupe(u8, name_ptr.*);
        try module.parsed_function_bodies.put(owned, {});
    }
}

fn moduleFunctionDeclBySymbol(module: *SlaModule, symbol: []const u8) ?*ast.FuncDecl {
    if (module.exports.function_decls.get(symbol)) |decl| {
        if (decl.* == .func_decl) return &decl.func_decl;
    }
    if (module.exports.associated_function_decls.get(symbol)) |decl| {
        if (decl.* == .func_decl) return &decl.func_decl;
    }
    return null;
}

fn captureModuleFunctionBodySpans(
    allocator: std.mem.Allocator,
    module: *SlaModule,
    parser: *const parser_mod.Parser,
) !void {
    var top_iter = module.exports.function_decls.iterator();
    while (top_iter.next()) |entry| {
        try putFunctionBodySpan(allocator, &module.function_body_spans, entry.key_ptr.*, parser.functionBodySpanFor(entry.value_ptr.*));
    }
    var associated_iter = module.exports.associated_function_decls.iterator();
    while (associated_iter.next()) |entry| {
        try putFunctionBodySpan(allocator, &module.function_body_spans, entry.key_ptr.*, parser.functionBodySpanFor(entry.value_ptr.*));
    }
}

fn putFunctionBodySpan(
    allocator: std.mem.Allocator,
    spans: *std.StringHashMap([]const u8),
    symbol: []const u8,
    span: ?[]const u8,
) !void {
    const body_span = span orelse return;
    if (spans.contains(symbol)) return;
    const owned_symbol = try allocator.dupe(u8, symbol);
    errdefer allocator.free(owned_symbol);
    try spans.put(owned_symbol, body_span);
}
