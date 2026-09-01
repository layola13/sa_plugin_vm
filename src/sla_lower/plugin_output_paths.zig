const std = @import("std");
const host_paths = @import("host_paths.zig");
const ast = @import("ast.zig");
const plugin_imports = @import("plugin_imports.zig");

const isSaStdImport = plugin_imports.isSaStdImport;
const isSlaStdImport = plugin_imports.isSlaStdImport;
const resolveImportFile = plugin_imports.resolveImportFile;

fn replaceSlaWithSa(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, path, ".sla")) {
        const base = path[0 .. path.len - 4];
        return try std.fmt.allocPrint(allocator, "{s}.sa", .{base});
    }
    return try allocator.dupe(u8, path);
}

fn normalizedSaStdImportPath(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (isSaStdImport(path)) return try allocator.dupe(u8, path);
    if (std.mem.indexOf(u8, path, ".sa/std/")) |idx| {
        const suffix = path[idx + ".sa/std/".len ..];
        return try std.fmt.allocPrint(allocator, "sa_std/{s}", .{suffix});
    }
    if (std.mem.indexOf(u8, path, "sci/sa_std/")) |idx| {
        const suffix = path[idx + "sci/sa_std/".len ..];
        return try std.fmt.allocPrint(allocator, "sa_std/{s}", .{suffix});
    }
    if (std.mem.indexOf(u8, path, "sa_std/")) |idx| {
        return try allocator.dupe(u8, path[idx..]);
    }
    return null;
}

fn normalizedSlaStdImportPath(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (isSlaStdImport(path)) return try allocator.dupe(u8, path);
    if (std.mem.indexOf(u8, path, "sa_plugin_sla/sla_std/")) |idx| {
        const suffix = path[idx + "sa_plugin_sla/sla_std/".len ..];
        return try std.fmt.allocPrint(allocator, "sla_std/{s}", .{suffix});
    }
    if (std.mem.indexOf(u8, path, "sla_std/")) |idx| {
        return try allocator.dupe(u8, path[idx..]);
    }
    return null;
}

fn absoluteDirForOutput(allocator: std.mem.Allocator, output_file: []const u8) ![]const u8 {
    const output_dir = std.fs.path.dirname(output_file) orelse ".";
    if (std.fs.path.isAbsolute(output_dir)) return try allocator.dupe(u8, output_dir);
    return std.fs.cwd().realpathAlloc(allocator, output_dir) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
            break :blk try std.fs.path.join(allocator, &.{ cwd, output_dir });
        },
        else => return err,
    };
}

fn rewriteImportPathForOutput(
    allocator: std.mem.Allocator,
    source_file: []const u8,
    output_file: []const u8,
    raw_import_path: []const u8,
) ![]const u8 {
    if (try normalizedSlaStdImportPath(allocator, raw_import_path)) |std_path| return std_path;
    if (try normalizedSaStdImportPath(allocator, raw_import_path)) |std_path| return std_path;

    const source_dir = std.fs.path.dirname(source_file) orelse ".";
    const resolved = try resolveImportFile(allocator, source_dir, raw_import_path);
    if (try normalizedSlaStdImportPath(allocator, resolved.path)) |std_path| return std_path;
    if (try normalizedSaStdImportPath(allocator, resolved.path)) |std_path| return std_path;

    const target_path = try replaceSlaWithSa(allocator, resolved.path);
    if (!std.fs.path.isAbsolute(target_path)) {
        const normed = try host_paths.normalizePathSlashes(allocator, target_path);
        return normed;
    }

    const output_dir = try absoluteDirForOutput(allocator, output_file);
    const relative = try std.fs.path.relative(allocator, output_dir, target_path);
    return try host_paths.normalizePathSlashes(allocator, relative);
}

pub fn rewriteProgramImportsForOutput(
    allocator: std.mem.Allocator,
    program: *ast.Node,
    source_file: []const u8,
    output_file: ?[]const u8,
) !void {
    const out = output_file orelse return;
    if (program.* != .program) return error.InvalidProgram;

    for (program.program.decls) |decl| {
        if (decl.* != .import_decl) continue;
        decl.import_decl.path = try rewriteImportPathForOutput(allocator, source_file, out, decl.import_decl.path);
    }
}
