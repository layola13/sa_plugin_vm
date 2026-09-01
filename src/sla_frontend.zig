const std = @import("std");
const ast = @import("sla_lower/ast.zig");
const parser_mod = @import("sla_lower/parser.zig");
const monomorphizer_mod = @import("sla_lower/monomorphizer.zig");
const type_checker_mod = @import("sla_lower/type_checker.zig");
const codegen_mod = @import("sla_lower/codegen.zig");
const source_expand = @import("sla_lower/source_expand.zig");
const plugin_import_expand = @import("sla_lower/plugin_import_expand.zig");
const plugin_imports = @import("sla_lower/plugin_imports.zig");
const plugin_module_table = @import("sla_lower/plugin_module_table.zig");

pub const CompileOptions = struct {
    include_all_imported_decls: bool = false,
    load_reachable_imported_bodies_from_registry: bool = true,
    parse_test_bodies: bool = true,
};

/// Compile one SLA source file to the SA text consumed by the VM parser.
///
/// This deliberately keeps the SLA compiler front-end separate from the VM
/// parser: the former owns imports, generic specialization, contracts, and
/// async lowering; the latter remains responsible only for SA execution.
pub fn compileToSa(
    allocator: std.mem.Allocator,
    file: []const u8,
    stderr: std.io.AnyWriter,
    options: CompileOptions,
) !?[]const u8 {
    const content = std.fs.cwd().readFileAlloc(allocator, file, 32 * 1024 * 1024) catch |err| {
        try stderr.print("SLA frontend: failed to read {s}: {}\n", .{ file, err });
        return null;
    };
    const expanded_content = source_expand.expandForModulePath(allocator, file, content) catch |err| {
        try stderr.print("SLA frontend: source expansion failed for {s}: {}\n", .{ file, err });
        return null;
    };

    const base_dir = std.fs.path.dirname(file) orelse ".";
    var parser = parser_mod.Parser.initWithDirAndOptions(allocator, expanded_content, base_dir, .{
        .parse_test_bodies = options.parse_test_bodies,
    });
    const parsed = parser.parseProgram() catch |err| {
        try parser.printDiagnostic(stderr, file, err);
        return null;
    };

    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    var modules = if (options.load_reachable_imported_bodies_from_registry)
        plugin_module_table.SlaModuleTable.initWithParserOptions(allocator, .{
            .parse_function_bodies = false,
            .parse_macro_bodies = false,
            .parse_test_bodies = false,
            .prescan_sla_import_types = false,
        })
    else
        plugin_module_table.SlaModuleTable.init(allocator);
    defer modules.deinit();
    var root_import_groups = std.ArrayList(plugin_module_table.SlaResolvedImportGroup).init(allocator);
    defer root_import_groups.deinit();
    var contract_imports = std.ArrayList(plugin_imports.ResolvedImport).init(allocator);
    defer contract_imports.deinit();

    const expanded_program = plugin_import_expand.expandSlaImportsWithModuleTableUsingContractTypeChecker(
        allocator,
        parsed,
        file,
        &primary_decls,
        .{
            .include_all_imported_decls = options.include_all_imported_decls,
            .imported_bodies_decl_only = options.load_reachable_imported_bodies_from_registry,
            .load_reachable_imported_bodies_from_registry = options.load_reachable_imported_bodies_from_registry,
        },
        &modules,
        &root_import_groups,
        &contract_imports,
        null,
    ) catch |err| {
        try stderr.print("SLA frontend: import expansion failed for {s}: {}\n", .{ file, err });
        return null;
    };

    var mono = monomorphizer_mod.Monomorphizer.init(allocator);
    defer mono.deinit();
    var specialized_primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const specialized_program = mono.monomorphize(expanded_program, &primary_decls, &specialized_primary_decls) catch |err| {
        if (mono.missingTemplateName()) |name| {
            try stderr.print("SLA frontend: monomorphization failed: {} ({s})\n", .{ err, name });
        } else {
            try stderr.print("SLA frontend: monomorphization failed: {}\n", .{err});
        }
        return null;
    };

    if (specialized_program.* != .program) return error.InvalidProgram;
    var filtered_decls = std.ArrayList(*ast.Node).init(allocator);
    try filtered_decls.ensureTotalCapacity(specialized_program.program.decls.len);
    for (specialized_program.program.decls) |decl| {
        if (specialized_primary_decls.contains(decl)) try filtered_decls.append(decl);
    }
    specialized_program.program.decls = try filtered_decls.toOwnedSlice();

    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    plugin_import_expand.loadImportedContractsFromResolvedImports(&tc, allocator, contract_imports.items) catch |err| {
        try stderr.print("SLA frontend: contract loading failed: {}\n", .{err});
        return null;
    };
    plugin_import_expand.registerImportedFunctionAliasesFromResolvedImports(&tc, allocator, root_import_groups.items, &modules) catch |err| {
        try stderr.print("SLA frontend: import alias registration failed: {}\n", .{err});
        return null;
    };
    tc.checkProgram(specialized_program) catch |err| {
        try stderr.print("SLA frontend: type checking failed: {s} ({})\n", .{ tc.last_error, err });
        return null;
    };

    var codegen = codegen_mod.Codegen.init(allocator, &tc);
    defer codegen.deinit();
    const sa_code = codegen.generate(specialized_program) catch |err| {
        try stderr.print("SLA frontend: SA code generation failed: {}\n", .{err});
        if (codegen.errorDetail()) |detail| try stderr.print("  {s}\n", .{detail});
        return null;
    };
    return sa_code;
}
