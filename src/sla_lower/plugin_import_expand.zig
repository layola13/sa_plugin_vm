const std = @import("std");
const ast = @import("ast.zig");
const lowering_rules = @import("lowering_rules.zig");
const source_expand = @import("source_expand.zig");
const type_checker_mod = @import("type_checker.zig");
const plugin_imports = @import("plugin_imports.zig");
const plugin_module_table = @import("plugin_module_table.zig");
const plugin_reachability = @import("plugin_reachability.zig");
const plugin_imported_macros = @import("plugin_imported_macros.zig");
const plugin_compile_options = @import("plugin_compile_options.zig");

const ResolvedImport = plugin_imports.ResolvedImport;
const moduleNamespaceFromImportPath = plugin_imports.moduleNamespaceFromImportPath;
const resolveImportFiles = plugin_imports.resolveImportFiles;
const importPathFromLine = plugin_imports.importPathFromLine;
const expandedSourceMayContainImports = plugin_imports.expandedSourceMayContainImports;
const SlaModule = plugin_module_table.SlaModule;
const SlaModuleTable = plugin_module_table.SlaModuleTable;
const SlaImportExpansionOptions = plugin_module_table.SlaImportExpansionOptions;
const SlaResolvedImportGroup = plugin_module_table.SlaResolvedImportGroup;
const buildReachableSymbols = plugin_reachability.buildReachableSymbols;
const ReachabilitySession = plugin_reachability.ReachabilitySession;
const UnresolvedCallableSet = plugin_reachability.UnresolvedCallableSet;
const associatedCandidateMatchesReceiverType = plugin_reachability.associatedCandidateMatchesReceiverType;
const collectReachableModuleBodyNames = plugin_reachability.collectReachableModuleBodyNames;
const materializeImportedModuleBodiesOneShot = plugin_reachability.materializeImportedModuleBodiesOneShot;
const loadImportedMacrosFromExpandedSource = plugin_imported_macros.loadImportedMacrosFromExpandedSource;

fn profileImportExpandStage(enabled: bool, label: []const u8, start_ns: i128) void {
    if (!enabled) return;
    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - start_ns, std.time.ns_per_ms);
    std.debug.print("[sla-profile] import expand {s}: {d}ms\n", .{ label, elapsed_ms });
}

fn importListCachePath(allocator: std.mem.Allocator, source_path: []const u8, expanded_source: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(source_path);
    hasher.update(&std.mem.toBytes(@as(u64, expanded_source.len)));
    hasher.update(expanded_source);
    const digest = hasher.final();
    const stem = std.fs.path.basename(source_path);
    return try std.fmt.allocPrint(allocator, ".sla-cache/imports/{s}-{x}.lst", .{ stem, digest });
}

fn collectImportPathsFromExpandedSource(allocator: std.mem.Allocator, expanded_source: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    var lines = std.mem.splitScalar(u8, expanded_source, '\n');
    while (lines.next()) |line| {
        if (importPathFromLine(line)) |child_import| {
            try out.append(try allocator.dupe(u8, child_import));
        }
    }
    return try out.toOwnedSlice();
}

fn loadImportListCache(allocator: std.mem.Allocator, cache_path: []const u8) !?[]const []const u8 {
    const bytes = std.fs.cwd().readFileAlloc(allocator, cache_path, 1024 * 1024) catch return null;
    defer allocator.free(bytes);
    var out = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try out.append(try allocator.dupe(u8, line));
    }
    return try out.toOwnedSlice();
}

fn storeImportListCache(cache_path: []const u8, imports: []const []const u8) void {
    const dir = std.fs.path.dirname(cache_path) orelse return;
    std.fs.cwd().makePath(dir) catch return;
    const file = std.fs.cwd().createFile(cache_path, .{}) catch return;
    defer file.close();
    for (imports) |imp| {
        file.writeAll(imp) catch return;
        file.writeAll("\n") catch return;
    }
}

fn scanExpandedSourceImports(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    expanded_source: []const u8,
    import_dir: []const u8,
    exclude_path: ?[]const u8,
    visited: *std.StringHashMap(void),
) anyerror!void {
    if (!expandedSourceMayContainImports(expanded_source)) return;

    // Prefer a content-hash cache of @import paths for large std sources (e.g. vec.sa)
    // so warm compiles skip line-scanning ~200KB+ expanded text.
    var owned_imports: ?[]const []const u8 = null;
    defer if (owned_imports) |imports| {
        for (imports) |item| allocator.free(item);
        allocator.free(imports);
    };
    if (exclude_path) |source_path| {
        if (importListCachePath(allocator, source_path, expanded_source)) |cache_path| {
            defer allocator.free(cache_path);
            if (loadImportListCache(allocator, cache_path) catch null) |cached| {
                owned_imports = cached;
            } else {
                const collected = try collectImportPathsFromExpandedSource(allocator, expanded_source);
                owned_imports = collected;
                storeImportListCache(cache_path, collected);
            }
        } else |_| {}
    }
    if (owned_imports) |imports| {
        for (imports) |child_import| {
            try loadImportContractsRecursive(tc, allocator, import_dir, child_import, exclude_path, visited);
        }
        return;
    }

    var lines = std.mem.splitScalar(u8, expanded_source, '\n');
    while (lines.next()) |line| {
        if (importPathFromLine(line)) |child_import| {
            try loadImportContractsRecursive(tc, allocator, import_dir, child_import, exclude_path, visited);
        }
    }
}

fn appendResolvedNonSlaImportDecl(
    allocator: std.mem.Allocator,
    resolved: ResolvedImport,
    primary_decls: *std.AutoHashMap(*const ast.Node, void),
    out_decls: *std.ArrayList(*ast.Node),
    contract_imports: ?*std.ArrayList(ResolvedImport),
) !void {
    const import_decl = try allocator.create(ast.Node);
    import_decl.* = .{ .import_decl = .{ .path = resolved.output_path } };
    try out_decls.append(import_decl);
    try primary_decls.put(import_decl, {});
    if (contract_imports) |imports| {
        if (resolvedImportNeedsContractLoading(resolved)) try imports.append(resolved);
    }
}

fn resolvedImportNeedsContractLoading(resolved: ResolvedImport) bool {
    if (std.mem.endsWith(u8, resolved.path, ".sai")) return true;
    if (std.mem.endsWith(u8, resolved.path, ".sal")) return true;
    if (!std.mem.endsWith(u8, resolved.path, ".sa")) return false;
    return std.mem.indexOf(u8, resolved.source, "[MACRO]") != null or
        std.mem.indexOf(u8, resolved.source, "@import") != null or
        std.mem.indexOf(u8, resolved.source, "@expand_tuple") != null;
}

fn appendUniqueResolvedContractImport(
    imports: *std.ArrayList(ResolvedImport),
    seen_paths: *std.StringHashMap(void),
    resolved: ResolvedImport,
) !bool {
    if (std.mem.endsWith(u8, resolved.path, ".sla")) return false;
    if (!resolvedImportNeedsContractLoading(resolved)) return false;
    if (seen_paths.contains(resolved.path)) return false;
    try seen_paths.put(resolved.path, {});
    try imports.append(resolved);
    return true;
}

fn firstMacroNameFromLine(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "[MACRO]")) return null;
    var parts = std.mem.tokenizeAny(u8, trimmed["[MACRO]".len..], " \t");
    const raw_name = parts.next() orelse return null;
    return std.mem.trim(u8, raw_name, " \t\r,");
}

fn firstExternNameFromLine(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "@extern")) return null;
    var rest = std.mem.trim(u8, trimmed["@extern".len..], " \t\r");
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == ':')) break;
    }
    return if (end > 0) rest[0..end] else null;
}

fn firstLayoutDefineNameFromLine(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "#def")) return null;
    var rest = std.mem.trim(u8, trimmed["#def".len..], " \t\r");
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) break;
    }
    return if (end > 0) rest[0..end] else null;
}

fn layoutDefineMatchesReferencedSymbol(define_name: []const u8, referenced_symbols: *const std.StringHashMap(void)) bool {
    if (referenced_symbols.contains(define_name)) return true;
    var iter = referenced_symbols.keyIterator();
    while (iter.next()) |symbol_ptr| {
        const symbol = symbol_ptr.*;
        if (define_name.len <= symbol.len + 1) continue;
        if (!std.mem.startsWith(u8, define_name, symbol)) continue;
        if (define_name[symbol.len] == '_') return true;
    }
    return false;
}

fn resolvedImportDeclaresReferencedSurface(resolved: ResolvedImport, referenced_symbols: *const std.StringHashMap(void)) bool {
    if (!resolvedImportNeedsContractLoading(resolved)) return false;
    var lines = std.mem.splitScalar(u8, resolved.source, '\n');
    while (lines.next()) |line| {
        if (firstMacroNameFromLine(line)) |name| {
            if (referenced_symbols.contains(name)) return true;
        }
        if (firstExternNameFromLine(line)) |name| {
            if (referenced_symbols.contains(name)) return true;
        }
        if (firstLayoutDefineNameFromLine(line)) |name| {
            if (layoutDefineMatchesReferencedSymbol(name, referenced_symbols)) return true;
        }
    }
    return false;
}

fn resolvedImportNeedsTransitiveContractScan(resolved: ResolvedImport) bool {
    if (!std.mem.endsWith(u8, resolved.path, ".sa")) return false;
    return std.mem.indexOf(u8, resolved.source, "@import") != null or
        std.mem.indexOf(u8, resolved.source, "@expand_tuple") != null;
}

fn shouldRetainResolvedContractImport(
    resolved: ResolvedImport,
    referenced_symbols: *const std.StringHashMap(void),
    module_needs_contracts: bool,
) bool {
    if (resolvedImportDeclaresReferencedSurface(resolved, referenced_symbols)) return true;
    return module_needs_contracts and resolvedImportNeedsTransitiveContractScan(resolved);
}

fn appendUniqueReferencedSurfaceImport(
    imports: *std.ArrayList(ResolvedImport),
    seen_paths: *std.StringHashMap(void),
    resolved: ResolvedImport,
    referenced_symbols: *const std.StringHashMap(void),
) !bool {
    if (!resolvedImportDeclaresReferencedSurface(resolved, referenced_symbols)) return false;
    return try appendUniqueResolvedContractImport(imports, seen_paths, resolved);
}

fn appendRootResolvedContractImports(
    imports: *std.ArrayList(ResolvedImport),
    seen_paths: *std.StringHashMap(void),
    root_import_groups: []const SlaResolvedImportGroup,
) !bool {
    var changed = false;
    for (root_import_groups) |group| {
        for (group.imports) |resolved| {
            if (try appendUniqueResolvedContractImport(imports, seen_paths, resolved)) changed = true;
        }
    }
    return changed;
}

fn appendContributingModuleResolvedContractImports(
    allocator: std.mem.Allocator,
    imports: *std.ArrayList(ResolvedImport),
    seen_paths: *std.StringHashMap(void),
    ordered_modules: []const *SlaModule,
    reachable: *const std.StringHashMap(void),
    referenced_types: *const std.StringHashMap(void),
) !bool {
    var changed = false;
    for (ordered_modules) |module| {
        const needs_contracts = try moduleNeedsContractImportsForReachability(allocator, module, reachable, referenced_types);
        for (module.resolved_imports) |resolved| {
            if (!shouldRetainResolvedContractImport(resolved, referenced_types, needs_contracts)) continue;
            const appended = try appendUniqueResolvedContractImport(imports, seen_paths, resolved);
            if (appended) changed = true;
        }
    }
    return changed;
}

fn isModuleContributing(
    allocator: std.mem.Allocator,
    module: *const SlaModule,
    reachable: *const std.StringHashMap(void),
    referenced_types: *const std.StringHashMap(void),
) !bool {
    // 1. Check if any exported function is reachable
    var func_iter = module.exports.function_decls.keyIterator();
    while (func_iter.next()) |name_ptr| {
        if (reachable.contains(name_ptr.*)) return true;
    }

    // 2. Check if any exported type is referenced
    var type_iter = module.exports.type_decls.keyIterator();
    while (type_iter.next()) |name_ptr| {
        if (referenced_types.contains(name_ptr.*)) return true;
    }

    // 3. Check if any exported constant is referenced
    var const_iter = module.exports.const_decls.keyIterator();
    while (const_iter.next()) |name_ptr| {
        if (referenced_types.contains(name_ptr.*)) return true;
    }

    // 4. Check if any exported macro is referenced
    var macro_iter = module.exports.macro_decls.keyIterator();
    while (macro_iter.next()) |name_ptr| {
        if (referenced_types.contains(name_ptr.*)) return true;
    }

    // 5. Check if any of its inherent/trait impl methods is reachable
    var associated_iter = module.exports.associated_function_decls.keyIterator();
    while (associated_iter.next()) |symbol_ptr| {
        if (reachable.contains(symbol_ptr.*)) return true;
        if (referenced_types.contains(symbol_ptr.*)) return true;
    }

    // Namespace aliases are sparse in focused reachability sets. Scan those
    // keys once instead of allocating one candidate alias per exported func.
    if (module.exports.function_decls.count() != 0) {
        const namespace = try moduleNamespaceFromImportPath(allocator, module.output_path);
        defer allocator.free(namespace);
        const prefix = try std.mem.concat(allocator, u8, &.{ namespace, "__" });
        defer allocator.free(prefix);
        var reachable_iter = reachable.keyIterator();
        while (reachable_iter.next()) |reachable_ptr| {
            const name = reachable_ptr.*;
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            if (module.exports.function_decls.contains(name[prefix.len..])) return true;
        }
    }

    return false;
}

fn moduleNeedsContractImportsForReachability(
    allocator: std.mem.Allocator,
    module: *const SlaModule,
    reachable: *const std.StringHashMap(void),
    referenced_types: *const std.StringHashMap(void),
) !bool {
    var selected_function_bodies = std.StringHashMap(void).init(allocator);
    defer selected_function_bodies.deinit();
    var selected_macro_bodies = std.StringHashMap(void).init(allocator);
    defer selected_macro_bodies.deinit();
    try collectReachableModuleBodyNames(allocator, module, reachable, referenced_types, &selected_function_bodies, &selected_macro_bodies);
    if (selected_function_bodies.count() != 0 or selected_macro_bodies.count() != 0) return true;

    var const_iter = module.exports.const_decls.keyIterator();
    while (const_iter.next()) |name_ptr| {
        if (referenced_types.contains(name_ptr.*)) return true;
    }

    var macro_iter = module.exports.macro_decls.keyIterator();
    while (macro_iter.next()) |name_ptr| {
        if (referenced_types.contains(name_ptr.*)) return true;
    }

    return false;
}

pub fn appendModuleDeclsSelective(
    allocator: std.mem.Allocator,
    modules: *SlaModuleTable,
    module: *SlaModule,
    emitted: *std.StringHashMap(void),
    primary_decls: *std.AutoHashMap(*const ast.Node, void),
    out_decls: *std.ArrayList(*ast.Node),
    reachable: *const std.StringHashMap(void),
    referenced_types: *const std.StringHashMap(void),
    options: SlaImportExpansionOptions,
    contract_imports: ?*std.ArrayList(ResolvedImport),
) !void {
    if (emitted.contains(module.path)) return;
    try emitted.put(module.path, {});

    if (!options.lazy_transitive_sla_imports) {
        for (module.resolved_imports) |child_resolved| {
            if (!std.mem.endsWith(u8, child_resolved.path, ".sla")) continue;
            const child_module = try modules.getOrParse(child_resolved);
            try appendModuleDeclsSelective(allocator, modules, child_module, emitted, primary_decls, out_decls, reachable, referenced_types, options, contract_imports);
        }
    }

    // A non-contributing wrapper module can still lead to an already-discovered
    // contributing child through a bare transitive reference. Walk discovered
    // children before deciding whether this module contributes declarations;
    // each child applies its own contribution filter.
    if (options.lazy_transitive_sla_imports) {
        for (module.resolved_imports) |child_resolved| {
            if (!std.mem.endsWith(u8, child_resolved.path, ".sla")) continue;
            const child_module = modules.modules.get(child_resolved.path) orelse continue;
            try appendModuleDeclsSelective(allocator, modules, child_module, emitted, primary_decls, out_decls, reachable, referenced_types, options, contract_imports);
        }
    }

    const is_contributing = options.include_all_imported_decls or try isModuleContributing(allocator, module, reachable, referenced_types);
    if (!is_contributing) {
        for (module.resolved_imports) |child_resolved| {
            if (std.mem.endsWith(u8, child_resolved.path, ".sla")) continue;
            if (!shouldRetainResolvedContractImport(child_resolved, referenced_types, false)) continue;
            try appendResolvedNonSlaImportDecl(allocator, child_resolved, primary_decls, out_decls, contract_imports);
        }
        return;
    }

    const module_namespace = try moduleNamespaceFromImportPath(allocator, module.output_path);
    defer allocator.free(module_namespace);
    const needs_contract_imports = try moduleNeedsContractImportsForReachability(allocator, module, reachable, referenced_types);

    for (module.program.program.decls) |decl| {
        if (decl.* == .import_decl) {
            for (module.resolved_imports) |child_resolved| {
                if (std.mem.endsWith(u8, child_resolved.path, ".sla")) continue;
                if (!shouldRetainResolvedContractImport(child_resolved, referenced_types, needs_contract_imports)) continue;
                try appendResolvedNonSlaImportDecl(allocator, child_resolved, primary_decls, out_decls, contract_imports);
            }
        } else {
            const before = out_decls.items.len;
            switch (decl.*) {
                .func_decl => |fd| {
                    if (options.include_all_imported_decls) {
                        // Keep raw decls (needed for bare exported names/templates).
                        // Namespaced aliases are registered later via
                        // registerImportedFunctionAliasesFromResolvedImports for check.
                        const func_node = try maybeDeclOnlyFuncNode(allocator, decl, options.imported_bodies_decl_only);
                        try out_decls.append(func_node);
                        try primary_decls.put(func_node, {});
                    } else {
                        if (try importedFuncNodeForReachability(allocator, decl, fd.name, module_namespace, reachable, options)) |func_node| {
                            try out_decls.append(func_node);
                            try primary_decls.put(func_node, {});
                        }
                        if (try reachableImportedAlias(allocator, module_namespace, fd.name, reachable)) |alias| {
                            defer allocator.free(alias);
                            const alias_node = try makeAliasedFuncNode(allocator, &decl.func_decl, alias, options);
                            try out_decls.append(alias_node);
                            try primary_decls.put(alias_node, {});
                        }
                    }
                },
                .impl_decl => {
                    try appendFilteredImplDeclWithOptions(allocator, decl, reachable, out_decls, options);
                },
                .overload_decl => {
                    try appendFilteredOverloadDeclWithOptions(allocator, decl, reachable, out_decls, options);
                },
                .macro_decl => |macro_decl| {
                    if (options.include_all_imported_decls or referenced_types.contains(macro_decl.name)) try out_decls.append(decl);
                },
                .const_stmt => |const_stmt| {
                    if (options.include_all_imported_decls or !options.prune_for_test_codegen or referenced_types.contains(const_stmt.name)) try out_decls.append(decl);
                },
                .test_decl => {},
                else => {
                    // Flatten type declarations needed by the reachable surface.
                    try out_decls.append(decl);
                },
            }
            if (out_decls.items.len != before) try primary_decls.put(out_decls.items[out_decls.items.len - 1], {});
        }
    }
}

fn collectSlaModulesRecursive(
    modules: *SlaModuleTable,
    module: *SlaModule,
    visited: *std.StringHashMap(void),
    ordered: *std.ArrayList(*SlaModule),
) !void {
    if (visited.contains(module.path)) return;
    try visited.put(module.path, {});

    for (module.resolved_imports) |child_resolved| {
        if (!std.mem.endsWith(u8, child_resolved.path, ".sla")) continue;
        const child_module = try modules.getOrParse(child_resolved);
        try collectSlaModulesRecursive(modules, child_module, visited, ordered);
    }

    try ordered.append(module);
}

fn appendSlaModuleIfNew(
    module: *SlaModule,
    visited: *std.StringHashMap(void),
    ordered: *std.ArrayList(*SlaModule),
) !bool {
    if (visited.contains(module.path)) return false;
    try visited.put(module.path, {});
    try ordered.append(module);
    return true;
}

fn symbolSetReferencesImportNamespace(set: *const std.StringHashMap(void), namespace: []const u8) bool {
    var iter = set.keyIterator();
    while (iter.next()) |key_ptr| {
        const key = key_ptr.*;
        if (key.len <= namespace.len + 2) continue;
        if (!std.mem.startsWith(u8, key, namespace)) continue;
        if (key[namespace.len] == '_' and key[namespace.len + 1] == '_') return true;
    }
    return false;
}

fn resolvedSlaImportNamespaceIsReferenced(
    allocator: std.mem.Allocator,
    resolved: ResolvedImport,
    reachable: *const std.StringHashMap(void),
    referenced_types: *const std.StringHashMap(void),
) !bool {
    const namespace = try moduleNamespaceFromImportPath(allocator, resolved.output_path);
    defer allocator.free(namespace);
    return symbolSetReferencesImportNamespace(reachable, namespace) or
        symbolSetReferencesImportNamespace(referenced_types, namespace);
}

fn moduleExportsReferencedBareSymbol(
    module: *const SlaModule,
    reachable: *const std.StringHashMap(void),
    referenced_types: *const std.StringHashMap(void),
) bool {
    // A cross-module call can be written bare (unqualified), e.g. a wrapper in
    // one module calling `program_new_single_file` defined in a transitively
    // imported module. Such references land in `reachable`/`referenced_types`
    // as the plain exported name (no `ns__` prefix), so namespace-prefix
    // matching alone would miss them and the defining module would never be
    // discovered on the lazy-transitive path. Detect a bare exported name that
    // is already referenced so the child module is pulled in.
    // A bare cross-module call whose target module has not yet been discovered
    // will not resolve in the callable index, so it is recorded in
    // `referenced_types` (as an unresolved call name) rather than `reachable`.
    // Check both sets against exported function/method names.
    var func_iter = module.exports.function_decls.keyIterator();
    while (func_iter.next()) |name_ptr| {
        if (reachable.contains(name_ptr.*) or referenced_types.contains(name_ptr.*)) return true;
    }
    var assoc_iter = module.exports.associated_function_decls.keyIterator();
    while (assoc_iter.next()) |symbol_ptr| {
        if (reachable.contains(symbol_ptr.*) or referenced_types.contains(symbol_ptr.*)) return true;
    }
    var const_iter = module.exports.const_decls.keyIterator();
    while (const_iter.next()) |name_ptr| {
        if (referenced_types.contains(name_ptr.*)) return true;
    }
    var macro_iter = module.exports.macro_decls.keyIterator();
    while (macro_iter.next()) |name_ptr| {
        if (referenced_types.contains(name_ptr.*)) return true;
    }
    var type_iter = module.exports.type_decls.keyIterator();
    while (type_iter.next()) |name_ptr| {
        if (referenced_types.contains(name_ptr.*)) return true;
    }
    return false;
}

fn associatedSymbolMatchesMethod(symbol: []const u8, method_name: []const u8) bool {
    if (symbol.len <= method_name.len) return false;
    if (!std.mem.endsWith(u8, symbol, method_name)) return false;
    return symbol[symbol.len - method_name.len - 1] == '_';
}

fn moduleExportsUnresolvedCallable(module: *const SlaModule, unresolved: ?*const UnresolvedCallableSet) bool {
    const records = unresolved orelse return false;
    for (records.records.items) |record| {
        if (record.resolved) continue;
        if (record.kind == .direct and module.exports.function_decls.contains(record.name)) return true;
        if (record.kind != .associated) continue;
        var associated_iter = module.exports.associated_function_decls.keyIterator();
        while (associated_iter.next()) |symbol_ptr| {
            if (record.receiver_type_name) |type_name| {
                if (associatedCandidateMatchesReceiverType(symbol_ptr.*, type_name, record.name)) return true;
            } else if (associatedSymbolMatchesMethod(symbol_ptr.*, record.name)) {
                return true;
            }
        }
    }
    return false;
}

fn discoverContributingChildSlaModules(
    allocator: std.mem.Allocator,
    modules: *SlaModuleTable,
    visited: *std.StringHashMap(void),
    ordered: *std.ArrayList(*SlaModule),
    reachable: *const std.StringHashMap(void),
    referenced_types: *const std.StringHashMap(void),
    unresolved_callables: ?*const UnresolvedCallableSet,
) !bool {
    var changed = false;
    var module_index: usize = 0;
    while (module_index < ordered.items.len) : (module_index += 1) {
        const module = ordered.items[module_index];
        for (module.resolved_imports) |child_resolved| {
            if (!std.mem.endsWith(u8, child_resolved.path, ".sla")) continue;
            if (try resolvedSlaImportNamespaceIsReferenced(allocator, child_resolved, reachable, referenced_types)) {
                const child_module = try modules.getOrParse(child_resolved);
                changed = (try appendSlaModuleIfNew(child_module, visited, ordered)) or changed;
                continue;
            }
            // Namespace not referenced. The child may still be needed through a
            // bare (unqualified) cross-module call, which requires inspecting its
            // exports even when the parent itself contributes no declaration.
            // Parse defensively: a genuinely dead child can be syntactically
            // invalid (the lazy path exists partly to skip such files), so on any
            // parse failure we skip it rather than failing the whole compile.
            // Only pull it in when it actually exports a bare symbol that is
            // already referenced.
            const child_module = modules.getOrParse(child_resolved) catch continue;
            if (!moduleExportsReferencedBareSymbol(child_module, reachable, referenced_types) and
                !moduleExportsUnresolvedCallable(child_module, unresolved_callables)) continue;
            changed = (try appendSlaModuleIfNew(child_module, visited, ordered)) or changed;
        }
    }
    return changed;
}

fn advanceReachabilitySessionWithLazyModuleDiscovery(
    allocator: std.mem.Allocator,
    session: *ReachabilitySession,
    modules: *SlaModuleTable,
    ordered_modules: *std.ArrayList(*SlaModule),
    visited_modules: *std.StringHashMap(void),
    options: SlaImportExpansionOptions,
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
) !void {
    while (true) {
        _ = try session.materialize(ordered_modules.items);
        if (!options.lazy_transitive_sla_imports) break;
        const previous_module_count = ordered_modules.items.len;
        if (!try discoverContributingChildSlaModules(allocator, modules, visited_modules, ordered_modules, reachable, referenced_types, session.unresolvedCallables())) break;
        try session.addModules(ordered_modules.items[previous_module_count..], ordered_modules.items);
    }
}

fn buildReachableWithoutMaterializedSession(
    allocator: std.mem.Allocator,
    program: *ast.Node,
    modules: *SlaModuleTable,
    ordered_modules: *std.ArrayList(*SlaModule),
    visited_modules: *std.StringHashMap(void),
    options: SlaImportExpansionOptions,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
) !void {
    while (true) {
        try buildReachableSymbols(allocator, program, ordered_modules.items, modules, options, imported_macros, reachable, referenced_types);
        if (!options.lazy_transitive_sla_imports) break;
        if (!try discoverContributingChildSlaModules(allocator, modules, visited_modules, ordered_modules, reachable, referenced_types, null)) break;
        reachable.clearRetainingCapacity();
        referenced_types.clearRetainingCapacity();
    }
}

fn appendFilteredFunctionDecl(
    decl: *ast.Node,
    reachable: *const std.StringHashMap(void),
    out_decls: *std.ArrayList(*ast.Node),
) !void {
    if (decl.func_decl.is_decl_only or reachable.contains(decl.func_decl.name)) try out_decls.append(decl);
}

fn makeDeclOnlyFuncNode(allocator: std.mem.Allocator, func: *const ast.FuncDecl) !*ast.Node {
    var stub_func = func.*;
    stub_func.is_decl_only = true;
    stub_func.body = &.{};
    const stub = try allocator.create(ast.Node);
    stub.* = .{ .func_decl = stub_func };
    return stub;
}

fn makeAliasedFuncNode(allocator: std.mem.Allocator, func: *const ast.FuncDecl, alias: []const u8, options: SlaImportExpansionOptions) !*ast.Node {
    var alias_func = func.*;
    alias_func.name = try allocator.dupe(u8, alias);
    if (options.imported_bodies_decl_only and !shouldKeepReachableImportedBody(options)) {
        alias_func.is_decl_only = true;
        alias_func.body = &.{};
    }
    const node = try allocator.create(ast.Node);
    node.* = .{ .func_decl = alias_func };
    return node;
}

fn maybeDeclOnlyFuncNode(allocator: std.mem.Allocator, method: *ast.Node, force_decl_only: bool) !*ast.Node {
    if (!force_decl_only or method.func_decl.is_decl_only) return method;
    return try makeDeclOnlyFuncNode(allocator, &method.func_decl);
}

fn shouldKeepReachableImportedBody(options: SlaImportExpansionOptions) bool {
    return options.imported_bodies_decl_only and options.load_reachable_imported_bodies_from_registry;
}

fn reachableImportedAlias(allocator: std.mem.Allocator, namespace: ?[]const u8, name: []const u8, reachable: *const std.StringHashMap(void)) !?[]const u8 {
    const ns = namespace orelse return null;
    const alias = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ ns, name });
    if (reachable.contains(alias)) return alias;
    allocator.free(alias);
    return null;
}

fn importedFuncNodeForReachability(
    allocator: std.mem.Allocator,
    node: *ast.Node,
    reachable_symbol: []const u8,
    namespace: ?[]const u8,
    reachable: *const std.StringHashMap(void),
    options: SlaImportExpansionOptions,
) !?*ast.Node {
    _ = namespace;
    if (node.* != .func_decl) return null;
    if (!reachable.contains(reachable_symbol)) return null;
    if (shouldKeepReachableImportedBody(options)) return node;
    if (options.imported_bodies_decl_only) return try makeDeclOnlyFuncNode(allocator, &node.func_decl);
    return node;
}

fn appendFilteredImplDecl(
    allocator: std.mem.Allocator,
    decl: *ast.Node,
    reachable: *const std.StringHashMap(void),
    out_decls: *std.ArrayList(*ast.Node),
) !void {
    try appendFilteredImplDeclWithOptions(allocator, decl, reachable, out_decls, .{});
}

fn appendFilteredImplDeclWithOptions(
    allocator: std.mem.Allocator,
    decl: *ast.Node,
    reachable: *const std.StringHashMap(void),
    out_decls: *std.ArrayList(*ast.Node),
    options: SlaImportExpansionOptions,
) !void {
    const impl_decl = decl.impl_decl;
    const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse {
        try out_decls.append(decl);
        return;
    };

    var methods = std.ArrayList(*ast.Node).init(allocator);
    var changed = false;
    for (impl_decl.methods) |method| {
        if (method.* != .func_decl) {
            try methods.append(method);
            continue;
        }
        const symbol = if (impl_decl.trait_name) |trait_name|
            try lowering_rules.mangleTraitMethodName(allocator, type_name, trait_name, method.func_decl.name)
        else
            try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
        if (options.include_all_imported_decls or method.func_decl.is_decl_only or reachable.contains(symbol)) {
            const keep_body = !options.include_all_imported_decls and reachable.contains(symbol) and shouldKeepReachableImportedBody(options);
            try methods.append(try maybeDeclOnlyFuncNode(allocator, method, options.imported_bodies_decl_only and !keep_body));
            if (options.imported_bodies_decl_only and !keep_body and !method.func_decl.is_decl_only) changed = true;
        } else if (impl_decl.trait_name != null) {
            try methods.append(try makeDeclOnlyFuncNode(allocator, &method.func_decl));
            changed = true;
        } else {
            changed = true;
        }
    }
    if (!changed and methods.items.len == impl_decl.methods.len) {
        try out_decls.append(decl);
    } else if (methods.items.len > 0) {
        const pruned = try allocator.create(ast.Node);
        pruned.* = .{ .impl_decl = .{
            .trait_name = impl_decl.trait_name,
            .target_ty = impl_decl.target_ty,
            .methods = try methods.toOwnedSlice(),
        } };
        try out_decls.append(pruned);
    }
}

fn appendFilteredOverloadDecl(
    allocator: std.mem.Allocator,
    decl: *ast.Node,
    reachable: *const std.StringHashMap(void),
    out_decls: *std.ArrayList(*ast.Node),
) !void {
    try appendFilteredOverloadDeclWithOptions(allocator, decl, reachable, out_decls, .{});
}

fn appendFilteredOverloadDeclWithOptions(
    allocator: std.mem.Allocator,
    decl: *ast.Node,
    reachable: *const std.StringHashMap(void),
    out_decls: *std.ArrayList(*ast.Node),
    options: SlaImportExpansionOptions,
) !void {
    const overload_decl = decl.overload_decl;
    const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse {
        try out_decls.append(decl);
        return;
    };

    var methods = std.ArrayList(*ast.Node).init(allocator);
    for (overload_decl.methods) |method| {
        if (method.* != .func_decl) {
            try methods.append(method);
            continue;
        }
        const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
        if (options.include_all_imported_decls or method.func_decl.is_decl_only or reachable.contains(symbol)) {
            const keep_body = !options.include_all_imported_decls and reachable.contains(symbol) and shouldKeepReachableImportedBody(options);
            try methods.append(try maybeDeclOnlyFuncNode(allocator, method, options.imported_bodies_decl_only and !keep_body));
        }
    }
    if (methods.items.len == overload_decl.methods.len and !options.imported_bodies_decl_only) {
        try out_decls.append(decl);
    } else if (methods.items.len > 0) {
        const pruned = try allocator.create(ast.Node);
        pruned.* = .{ .overload_decl = .{
            .target_ty = overload_decl.target_ty,
            .methods = try methods.toOwnedSlice(),
        } };
        try out_decls.append(pruned);
    }
}

fn appendDeclWithReachableFilter(
    allocator: std.mem.Allocator,
    decl: *ast.Node,
    reachable: ?*const std.StringHashMap(void),
    referenced_types: ?*const std.StringHashMap(void),
    out_decls: *std.ArrayList(*ast.Node),
) !void {
    const filter = reachable orelse {
        try out_decls.append(decl);
        return;
    };
    switch (decl.*) {
        .func_decl => try appendFilteredFunctionDecl(decl, filter, out_decls),
        .impl_decl => try appendFilteredImplDecl(allocator, decl, filter, out_decls),
        .overload_decl => try appendFilteredOverloadDecl(allocator, decl, filter, out_decls),
        .macro_decl => |macro_decl| {
            if (referenced_types) |refs| {
                if (refs.contains(macro_decl.name)) try out_decls.append(decl);
            }
        },
        else => try out_decls.append(decl),
    }
}

fn resolvedImportGroupForDecl(groups: []const SlaResolvedImportGroup, decl: *const ast.Node) ?[]const ResolvedImport {
    for (groups) |group| {
        if (group.decl == decl) return group.imports;
    }
    return null;
}

fn reachablePlanCachePath(
    allocator: std.mem.Allocator,
    source_file: []const u8,
    root_source: []const u8,
    ordered_modules: []const *SlaModule,
    options: SlaImportExpansionOptions,
) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(source_file);
    hasher.update(&std.mem.toBytes(@as(u64, root_source.len)));
    hasher.update(root_source);
    const option_bits: u8 =
        (@as(u8, @intFromBool(options.prune_for_test_codegen)) << 0) |
        (@as(u8, @intFromBool(options.imported_bodies_decl_only)) << 1) |
        (@as(u8, @intFromBool(options.load_reachable_imported_bodies_from_registry)) << 2) |
        (@as(u8, @intFromBool(options.lazy_transitive_sla_imports)) << 3) |
        (@as(u8, @intFromBool(options.include_all_imported_decls)) << 4);
    hasher.update(&.{option_bits});
    if (options.test_filter) |filter| {
        hasher.update(&std.mem.toBytes(@as(u64, filter.len)));
        hasher.update(filter);
    } else {
        hasher.update(&std.mem.toBytes(std.math.maxInt(u64)));
    }
    for (ordered_modules) |module| {
        hasher.update(module.path);
        hasher.update(&std.mem.toBytes(@as(u64, module.expanded_source.len)));
        // Content already expanded; length + path is a cheap invalidation proxy with expand caches.
        hasher.update(module.expanded_source);
    }
    const digest = hasher.final();
    const stem = std.fs.path.basename(source_file);
    return try std.fmt.allocPrint(allocator, ".sla-cache/reachable/{s}-{x}.plan", .{ stem, digest });
}

fn tryLoadReachablePlan(
    allocator: std.mem.Allocator,
    cache_path: []const u8,
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
) !bool {
    const bytes = std.fs.cwd().readFileAlloc(allocator, cache_path, 8 * 1024 * 1024) catch return false;
    defer allocator.free(bytes);
    var reachable_count: usize = 0;
    var type_count: usize = 0;
    var section: enum { reachable, types } = .reachable;
    var count_lines = std.mem.splitScalar(u8, bytes, '\n');
    while (count_lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "[reachable]")) {
            section = .reachable;
            continue;
        }
        if (std.mem.eql(u8, line, "[types]")) {
            section = .types;
            continue;
        }
        switch (section) {
            .reachable => reachable_count += 1,
            .types => type_count += 1,
        }
    }
    try reachable.ensureTotalCapacity(@intCast(reachable_count));
    try referenced_types.ensureTotalCapacity(@intCast(type_count));
    section = .reachable;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "[reachable]")) {
            section = .reachable;
            continue;
        }
        if (std.mem.eql(u8, line, "[types]")) {
            section = .types;
            continue;
        }
        const owned = try allocator.dupe(u8, line);
        switch (section) {
            .reachable => reachable.putAssumeCapacity(owned, {}),
            .types => referenced_types.putAssumeCapacity(owned, {}),
        }
    }
    return reachable.count() != 0;
}

fn storeReachablePlan(
    allocator: std.mem.Allocator,
    cache_path: []const u8,
    reachable: *const std.StringHashMap(void),
    referenced_types: *const std.StringHashMap(void),
) void {
    _ = allocator;
    const dir = std.fs.path.dirname(cache_path) orelse return;
    std.fs.cwd().makePath(dir) catch return;
    const file = std.fs.cwd().createFile(cache_path, .{}) catch return;
    defer file.close();
    file.writeAll("[reachable]\n") catch return;
    var r_iter = reachable.keyIterator();
    while (r_iter.next()) |k| {
        file.writeAll(k.*) catch return;
        file.writeAll("\n") catch return;
    }
    file.writeAll("[types]\n") catch return;
    var t_iter = referenced_types.keyIterator();
    while (t_iter.next()) |k| {
        file.writeAll(k.*) catch return;
        file.writeAll("\n") catch return;
    }
}

pub fn expandSlaImportsWithModuleTableUsingContractTypeChecker(
    allocator: std.mem.Allocator,
    program: *ast.Node,
    source_file: []const u8,
    primary_decls: *std.AutoHashMap(*const ast.Node, void),
    options: SlaImportExpansionOptions,
    modules: *SlaModuleTable,
    root_import_groups: *std.ArrayList(SlaResolvedImportGroup),
    contract_imports: *std.ArrayList(ResolvedImport),
    contract_type_checker: ?*type_checker_mod.TypeChecker,
) !*ast.Node {
    if (program.* != .program) return error.InvalidProgram;
    const profile_enabled = plugin_compile_options.slaProfileEnabled(allocator);
    var profile_start = std.time.nanoTimestamp();

    var effective_options = options;
    const root_source_size = blk: {
        const stat = std.fs.cwd().statFile(source_file) catch break :blk @as(u64, 0);
        break :blk stat.size;
    };
    // Historical small filtered-test root path. Larger registry-driven check/compile
    // roots still eagerly collect the transitive diamond in resolve-roots because
    // lazy discovery currently inflates reachable materialize on real ECS graphs.
    effective_options.lazy_transitive_sla_imports = options.lazy_transitive_sla_imports or
        (options.prune_for_test_codegen and
            program.program.decls.len <= 64 and
            root_source_size <= 32 * 1024);

    var emitted = std.StringHashMap(void).init(allocator);
    defer emitted.deinit();

    var decls = std.ArrayList(*ast.Node).init(allocator);
    const source_dir = std.fs.path.dirname(source_file) orelse ".";
    const source_abs = std.fs.cwd().realpathAlloc(allocator, source_file) catch source_file;

    var ordered_modules = std.ArrayList(*SlaModule).init(allocator);
    defer ordered_modules.deinit();
    var visited_modules = std.StringHashMap(void).init(allocator);
    defer visited_modules.deinit();
    // Upper-bound pre-size for root import_decl fan-out. Real ECS graphs still grow
    // beyond this during recursive discovery; the reservation only cuts early churn.
    try root_import_groups.ensureTotalCapacity(root_import_groups.items.len + program.program.decls.len);
    try ordered_modules.ensureTotalCapacity(32);
    try visited_modules.ensureTotalCapacity(32);

    for (program.program.decls) |decl| {
        if (decl.* != .import_decl) continue;
        const resolved_imports = try resolveImportFiles(allocator, source_dir, decl.import_decl.path, source_abs);
        try root_import_groups.append(.{ .decl = decl, .imports = resolved_imports });
        for (resolved_imports) |resolved| {
            if (!std.mem.endsWith(u8, resolved.path, ".sla")) continue;
            const module = try modules.getOrParse(resolved);
            if (effective_options.lazy_transitive_sla_imports) {
                _ = try appendSlaModuleIfNew(module, &visited_modules, &ordered_modules);
            } else {
                try collectSlaModulesRecursive(modules, module, &visited_modules, &ordered_modules);
            }
        }
    }
    profileImportExpandStage(profile_enabled, "resolve roots", profile_start);
    if (profile_enabled) {
        std.debug.print("[sla-profile] import expand ordered modules={d}\n", .{ordered_modules.items.len});
    }
    profile_start = std.time.nanoTimestamp();

    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();
    var referenced_types = std.StringHashMap(void).init(allocator);
    defer referenced_types.deinit();

    var owned_imported_macro_tc = type_checker_mod.TypeChecker.init(allocator);
    defer owned_imported_macro_tc.deinit();
    const imported_macro_tc = contract_type_checker orelse &owned_imported_macro_tc;
    var imported_macro_contract_paths = std.StringHashMap(void).init(allocator);
    defer imported_macro_contract_paths.deinit();
    if (options.prune_for_test_codegen) {
        var imported_macro_contract_imports = std.ArrayList(ResolvedImport).init(allocator);
        defer imported_macro_contract_imports.deinit();
        _ = try appendRootResolvedContractImports(&imported_macro_contract_imports, &imported_macro_contract_paths, root_import_groups.items);
        try loadImportedContractsFromResolvedImports(imported_macro_tc, allocator, imported_macro_contract_imports.items);
    }
    const imported_macros = if (options.prune_for_test_codegen) &imported_macro_tc.imported_macros else null;

    var reachability_session: ?ReachabilitySession = null;
    defer if (reachability_session) |*session| session.deinit();
    var used_reachable_plan_cache = false;
    if (effective_options.include_all_imported_decls) {
        if (profile_enabled) {
            std.debug.print("[sla-profile] import expand buildReachable skipped (include_all_imported_decls)\n", .{});
        }
    } else if (shouldKeepReachableImportedBody(effective_options)) {
        const root_source = std.fs.cwd().readFileAlloc(allocator, source_file, 16 * 1024 * 1024) catch null;
        if (root_source) |root_bytes| {
            defer allocator.free(root_bytes);
            if (reachablePlanCachePath(allocator, source_file, root_bytes, ordered_modules.items, effective_options)) |plan_path| {
                defer allocator.free(plan_path);
                if (try tryLoadReachablePlan(allocator, plan_path, &reachable, &referenced_types)) {
                    used_reachable_plan_cache = true;
                    if (profile_enabled) {
                        std.debug.print(
                            "[sla-profile] import expand reachable plan cache hit symbols={d} types={d}\n",
                            .{ reachable.count(), referenced_types.count() },
                        );
                    }
                    _ = try materializeImportedModuleBodiesOneShot(
                        allocator,
                        ordered_modules.items,
                        modules,
                        effective_options,
                        imported_macros,
                        &reachable,
                        &referenced_types,
                    );
                }
            } else |_| {}
        }
        if (!used_reachable_plan_cache) {
            reachability_session = try ReachabilitySession.init(
                allocator,
                program,
                ordered_modules.items,
                modules,
                effective_options,
                imported_macros,
                &reachable,
                &referenced_types,
            );
            try advanceReachabilitySessionWithLazyModuleDiscovery(
                allocator,
                &reachability_session.?,
                modules,
                &ordered_modules,
                &visited_modules,
                effective_options,
                &reachable,
                &referenced_types,
            );
            const root_source2 = std.fs.cwd().readFileAlloc(allocator, source_file, 16 * 1024 * 1024) catch null;
            if (root_source2) |root_bytes| {
                defer allocator.free(root_bytes);
                if (reachablePlanCachePath(allocator, source_file, root_bytes, ordered_modules.items, effective_options)) |plan_path| {
                    defer allocator.free(plan_path);
                    storeReachablePlan(allocator, plan_path, &reachable, &referenced_types);
                } else |_| {}
            }
        }
    } else {
        const reachable_start = std.time.nanoTimestamp();
        try buildReachableWithoutMaterializedSession(
            allocator,
            program,
            modules,
            &ordered_modules,
            &visited_modules,
            effective_options,
            imported_macros,
            &reachable,
            &referenced_types,
        );
        if (profile_enabled) {
            std.debug.print("[sla-profile] import expand buildReachable symbols={d} types={d} modules={d} elapsed={d}ms\n", .{ reachable.count(), referenced_types.count(), ordered_modules.items.len, @divTrunc(std.time.nanoTimestamp() - reachable_start, std.time.ns_per_ms) });
        }
    }
    profileImportExpandStage(profile_enabled, "reachable materialize", profile_start);
    profile_start = std.time.nanoTimestamp();
    if (options.prune_for_test_codegen) {
        while (true) {
            var imported_macro_contract_imports = std.ArrayList(ResolvedImport).init(allocator);
            defer imported_macro_contract_imports.deinit();
            _ = try appendContributingModuleResolvedContractImports(
                allocator,
                &imported_macro_contract_imports,
                &imported_macro_contract_paths,
                ordered_modules.items,
                &reachable,
                &referenced_types,
            );
            if (imported_macro_contract_imports.items.len == 0) break;
            try loadImportedContractsFromResolvedImports(imported_macro_tc, allocator, imported_macro_contract_imports.items);
            if (reachability_session) |*session| {
                _ = try session.refreshImportedMacros(ordered_modules.items);
                try advanceReachabilitySessionWithLazyModuleDiscovery(
                    allocator,
                    session,
                    modules,
                    &ordered_modules,
                    &visited_modules,
                    effective_options,
                    &reachable,
                    &referenced_types,
                );
            } else {
                try buildReachableWithoutMaterializedSession(
                    allocator,
                    program,
                    modules,
                    &ordered_modules,
                    &visited_modules,
                    effective_options,
                    imported_macros,
                    &reachable,
                    &referenced_types,
                );
            }
        }
    }
    profileImportExpandStage(profile_enabled, "macro contracts", profile_start);
    profile_start = std.time.nanoTimestamp();
    if (profile_enabled) {
        std.debug.print(
            "[sla-profile] import type scan cache entries={d} hits={d}\n",
            .{ modules.importTypeScanCacheCount(), modules.importTypeScanCacheHitCount() },
        );
        std.debug.print(
            "[sla-profile] import source reuse hits={d}\n",
            .{modules.resolvedImportSourceCacheHitCount()},
        );
        std.debug.print(
            "[sla-profile] import expanded source reuse hits={d}\n",
            .{modules.expandedSourceCacheHitCount()},
        );
    }

    // Avoid geometric growth while flattening imported decls.
    try decls.ensureTotalCapacity(decls.items.len + ordered_modules.items.len * 64 + program.program.decls.len);
    try primary_decls.ensureTotalCapacity(@intCast(ordered_modules.items.len * 64 + program.program.decls.len));
    try emitted.ensureTotalCapacity(@intCast(ordered_modules.items.len + 8));
    for (program.program.decls) |decl| {
        if (decl.* == .import_decl) {
            const resolved_imports = resolvedImportGroupForDecl(root_import_groups.items, decl) orelse &.{};
            for (resolved_imports) |resolved| {
                if (std.mem.endsWith(u8, resolved.path, ".sla")) {
                    const module = try modules.getOrParse(resolved);
                    try appendModuleDeclsSelective(allocator, modules, module, &emitted, primary_decls, &decls, &reachable, &referenced_types, effective_options, contract_imports);
                } else {
                    try appendResolvedNonSlaImportDecl(allocator, resolved, primary_decls, &decls, contract_imports);
                }
            }
        } else {
            const before = decls.items.len;
            if (effective_options.prune_for_test_codegen) {
                try appendDeclWithReachableFilter(allocator, decl, &reachable, &referenced_types, &decls);
            } else {
                try decls.append(decl);
            }
            if (decls.items.len != before) try primary_decls.put(decls.items[decls.items.len - 1], {});
        }
    }
    profileImportExpandStage(profile_enabled, "selective append", profile_start);
    if (profile_enabled) {
        std.debug.print("[sla-profile] import expand selective append decls={d} primary={d}\n", .{ decls.items.len, primary_decls.count() });
    }

    const expanded = try allocator.create(ast.Node);
    expanded.* = .{ .program = .{ .decls = try decls.toOwnedSlice() } };
    return expanded;
}

pub fn expandSlaImportsWithModuleTable(
    allocator: std.mem.Allocator,
    program: *ast.Node,
    source_file: []const u8,
    primary_decls: *std.AutoHashMap(*const ast.Node, void),
    options: SlaImportExpansionOptions,
    modules: *SlaModuleTable,
    root_import_groups: *std.ArrayList(SlaResolvedImportGroup),
    contract_imports: *std.ArrayList(ResolvedImport),
) !*ast.Node {
    return try expandSlaImportsWithModuleTableUsingContractTypeChecker(
        allocator,
        program,
        source_file,
        primary_decls,
        options,
        modules,
        root_import_groups,
        contract_imports,
        null,
    );
}

pub fn expandSlaImports(
    allocator: std.mem.Allocator,
    program: *ast.Node,
    source_file: []const u8,
    primary_decls: *std.AutoHashMap(*const ast.Node, void),
    options: SlaImportExpansionOptions,
) !*ast.Node {
    var modules = if (shouldKeepReachableImportedBody(options))
        SlaModuleTable.initWithParserOptions(allocator, .{
            .parse_function_bodies = false,
            .parse_macro_bodies = false,
            .parse_test_bodies = false,
            .prescan_sla_import_types = false,
        })
    else
        SlaModuleTable.init(allocator);
    defer modules.deinit();
    var root_import_groups = std.ArrayList(SlaResolvedImportGroup).init(allocator);
    defer root_import_groups.deinit();
    var contract_imports = std.ArrayList(ResolvedImport).init(allocator);
    defer contract_imports.deinit();
    return try expandSlaImportsWithModuleTable(allocator, program, source_file, primary_decls, options, &modules, &root_import_groups, &contract_imports);
}

pub fn registerImportedFunctionAliasesFromResolvedImports(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    root_import_groups: []const SlaResolvedImportGroup,
    modules: *SlaModuleTable,
) !void {
    for (root_import_groups) |group| {
        for (group.imports) |resolved| {
            if (!std.mem.endsWith(u8, resolved.path, ".sla")) continue;
            const namespace = try moduleNamespaceFromImportPath(allocator, resolved.output_path);
            const module = try modules.getOrParse(resolved);
            var fn_iter = module.exports.function_signatures.iterator();
            while (fn_iter.next()) |entry| {
                const name = entry.key_ptr.*;
                const signature = entry.value_ptr.*;
                const alias = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ namespace, name });
                try tc.registerFunctionAliasWithMetadata(alias, name, namespace, module.path);
                try tc.registerImportedFunctionSignature(name, signature.params, signature.ret_ty, signature.is_async);
                try tc.registerImportedFunctionSignature(alias, signature.params, signature.ret_ty, signature.is_async);
            }
            for (module.exports.impl_decls.items) |impl_node| {
                const impl_decl = impl_node.impl_decl;
                const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                for (impl_decl.methods) |method| {
                    if (method.* != .func_decl) continue;
                    const symbol = if (impl_decl.trait_name) |trait_name|
                        try lowering_rules.mangleTraitMethodName(allocator, type_name, trait_name, method.func_decl.name)
                    else
                        try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    try tc.registerImportedFunctionSignature(symbol, method.func_decl.params, method.func_decl.ret_ty, method.func_decl.is_async);
                }
            }
        }
    }
}

pub fn registerImportedFunctionAliases(tc: *type_checker_mod.TypeChecker, allocator: std.mem.Allocator, program: *ast.Node, source_file: []const u8) !void {
    if (program.* != .program) return error.InvalidProgram;

    var modules = SlaModuleTable.init(allocator);
    defer modules.deinit();
    var root_import_groups = std.ArrayList(SlaResolvedImportGroup).init(allocator);
    defer root_import_groups.deinit();

    const source_dir = std.fs.path.dirname(source_file) orelse ".";
    const source_abs = std.fs.cwd().realpathAlloc(allocator, source_file) catch source_file;

    for (program.program.decls) |decl| {
        if (decl.* != .import_decl) continue;
        const resolved_imports = try resolveImportFiles(allocator, source_dir, decl.import_decl.path, source_abs);
        try root_import_groups.append(.{ .decl = decl, .imports = resolved_imports });
    }

    try registerImportedFunctionAliasesFromResolvedImports(tc, allocator, root_import_groups.items, &modules);
}

fn loadImportContractsRecursive(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    import_path: []const u8,
    exclude_path: ?[]const u8,
    visited: *std.StringHashMap(void),
) !void {
    const resolved_imports = try resolveImportFiles(allocator, base_dir, import_path, exclude_path);
    for (resolved_imports) |resolved| {
        if (visited.contains(resolved.path)) continue;
        try visited.put(resolved.path, {});

        const import_dir = std.fs.path.dirname(resolved.path) orelse base_dir;
        const expanded_source = try source_expand.expandForModulePath(allocator, resolved.path, resolved.source);
        try scanExpandedSourceImports(tc, allocator, expanded_source, import_dir, resolved.path, visited);

        if (std.mem.endsWith(u8, resolved.path, ".sai")) {
            try tc.loadContracts(expanded_source, "");
        } else if (std.mem.endsWith(u8, resolved.path, ".sal")) {
            try tc.loadContracts("", expanded_source);
        }
        try loadImportedMacrosFromExpandedSource(tc, allocator, expanded_source, resolved.output_path);
    }
}

fn loadResolvedImportContractsRecursive(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    resolved: ResolvedImport,
    base_dir: []const u8,
    visited: *std.StringHashMap(void),
) !void {
    if (visited.contains(resolved.path)) return;
    try visited.put(resolved.path, {});

    const import_dir = std.fs.path.dirname(resolved.path) orelse base_dir;
    const expanded_source = try source_expand.expandForModulePath(allocator, resolved.path, resolved.source);
    const profile = plugin_compile_options.slaProfileEnabled(allocator);
    const t0 = if (profile) std.time.nanoTimestamp() else 0;
    try scanExpandedSourceImports(tc, allocator, expanded_source, import_dir, resolved.path, visited);
    const t1 = if (profile) std.time.nanoTimestamp() else 0;
    if (std.mem.endsWith(u8, resolved.path, ".sai")) {
        try tc.loadContracts(expanded_source, "");
    } else if (std.mem.endsWith(u8, resolved.path, ".sal")) {
        try tc.loadContracts("", expanded_source);
    }
    const t2 = if (profile) std.time.nanoTimestamp() else 0;
    try loadImportedMacrosFromExpandedSource(tc, allocator, expanded_source, resolved.output_path);
    if (profile and plugin_compile_options.slaProfileContractsEnabled(allocator)) {
        std.debug.print(
            "[sla-profile] contract detail {s}: scan={d}ms contracts={d}ms macros={d}ms\n",
            .{
                std.fs.path.basename(resolved.path),
                @divTrunc(t1 - t0, std.time.ns_per_ms),
                @divTrunc(t2 - t1, std.time.ns_per_ms),
                @divTrunc(std.time.nanoTimestamp() - t2, std.time.ns_per_ms),
            },
        );
    }
}

pub fn loadImportedContractsFromResolvedImports(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    imports: []const ResolvedImport,
) !void {
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();
    const profile = plugin_compile_options.slaProfileEnabled(allocator);
    var loaded: usize = 0;
    const start = if (profile) std.time.nanoTimestamp() else 0;

    for (imports) |resolved| {
        if (std.mem.endsWith(u8, resolved.path, ".sla")) continue;
        if (visited.contains(resolved.path)) continue;
        const base_dir = std.fs.path.dirname(resolved.path) orelse ".";
        if (profile and plugin_compile_options.slaProfileContractsEnabled(allocator)) {
            std.debug.print("[sla-profile] load contract {s}\n", .{std.fs.path.basename(resolved.path)});
        }
        try loadResolvedImportContractsRecursive(tc, allocator, resolved, base_dir, &visited);
        loaded += 1;
    }
    if (profile) {
        std.debug.print(
            "[sla-profile] load contracts summary: roots={d} visited={d} elapsed={d}ms\n",
            .{ loaded, visited.count(), @divTrunc(std.time.nanoTimestamp() - start, std.time.ns_per_ms) },
        );
    }
}

pub fn loadImportedContracts(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    program: *ast.Node,
    source_file: []const u8,
) !void {
    if (program.* != .program) return error.InvalidProgram;

    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    const source_dir = std.fs.path.dirname(source_file) orelse ".";
    const source_abs = std.fs.cwd().realpathAlloc(allocator, source_file) catch source_file;
    for (program.program.decls) |decl| {
        if (decl.* == .import_decl) {
            try loadImportContractsRecursive(tc, allocator, source_dir, decl.import_decl.path, source_abs, &visited);
        }
    }
}
