const std = @import("std");
const workspace = @import("workspace.zig");
const host_paths = @import("host_paths.zig");

pub const max_import_bytes = 16 * 1024 * 1024;

pub const ResolvedImport = struct {
    path: []const u8,
    output_path: []const u8,
    source: []const u8,
};

pub const ResolvedModuleImport = struct {
    namespace: []const u8,
    resolved: ResolvedImport,
};

pub fn moduleNamespaceFromImportPath(allocator: std.mem.Allocator, import_path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(import_path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    return try allocator.dupe(u8, stem);
}

pub fn moduleNamespaceMatchesImportPath(import_path: []const u8, namespace: []const u8) bool {
    const base = std.fs.path.basename(import_path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    return std.mem.eql(u8, stem, namespace);
}

pub const ImportedMangledSymbol = struct {
    namespace: []const u8,
    name: []const u8,
};

pub fn splitImportedMangledSymbol(symbol: []const u8) ?ImportedMangledSymbol {
    const sep = std.mem.indexOf(u8, symbol, "__") orelse return null;
    if (sep == 0 or sep + 2 >= symbol.len) return null;
    return .{
        .namespace = symbol[0..sep],
        .name = symbol[sep + 2 ..],
    };
}

pub fn stringSliceLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn resolvedImportLessThan(_: void, a: ResolvedImport, b: ResolvedImport) bool {
    return std.mem.lessThan(u8, a.output_path, b.output_path);
}

pub fn isGlobImportPath(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '*') != null;
}

pub fn globNameMatches(pattern: []const u8, name: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, name);
    if (std.mem.indexOfScalarPos(u8, pattern, star + 1, '*') != null) return false;
    const prefix = pattern[0..star];
    const suffix = pattern[star + 1 ..];
    if (name.len < prefix.len + suffix.len) return false;
    return std.mem.startsWith(u8, name, prefix) and std.mem.endsWith(u8, name, suffix);
}

pub fn isSaStdImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "sa_std") or std.mem.startsWith(u8, path, "sa_std/");
}

pub fn isSlaStdImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "sla_std") or std.mem.startsWith(u8, path, "sla_std/");
}

pub fn readImportFileIfExistsWithOutputPath(allocator: std.mem.Allocator, path: []const u8, output_path: []const u8) !?ResolvedImport {
    const source = std.fs.cwd().readFileAlloc(allocator, path, max_import_bytes) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir or err == error.IsDir) return null;
        return err;
    };
    const real_path_raw = std.fs.cwd().realpathAlloc(allocator, path) catch try allocator.dupe(u8, path);
    const real_path = try host_paths.normalizePathSlashes(allocator, real_path_raw);
    allocator.free(real_path_raw);
    return .{ .path = real_path, .output_path = try allocator.dupe(u8, output_path), .source = source };
}

pub fn readImportFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?ResolvedImport {
    return try readImportFileIfExistsWithOutputPath(allocator, path, path);
}

pub fn readImportFromRoot(allocator: std.mem.Allocator, root: []const u8, rel_path: []const u8, output_path: []const u8) !?ResolvedImport {
    if (rel_path.len == 0) return null;
    const candidate = try std.fs.path.join(allocator, &.{ root, rel_path });
    defer allocator.free(candidate);
    return try readImportFileIfExistsWithOutputPath(allocator, candidate, output_path);
}

fn readImportFromAncestorRoots(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    rel_path: []const u8,
    output_path: []const u8,
    roots: []const []const u8,
) !?ResolvedImport {
    var current = std.fs.cwd().realpathAlloc(allocator, base_dir) catch try allocator.dupe(u8, base_dir);
    defer allocator.free(current);
    while (true) {
        for (roots) |root| {
            const root_path = try std.fs.path.join(allocator, &.{ current, root });
            defer allocator.free(root_path);
            if (try readImportFromRoot(allocator, root_path, rel_path, output_path)) |resolved| return resolved;
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    return null;
}

pub fn resolveSaStdImport(allocator: std.mem.Allocator, import_path: []const u8) !?ResolvedImport {
    return resolveSaStdImportFromBase(allocator, ".", import_path);
}

fn resolveSaStdImportFromBase(allocator: std.mem.Allocator, base_dir: []const u8, import_path: []const u8) !?ResolvedImport {
    if (!isSaStdImport(import_path)) return null;
    if (std.mem.eql(u8, import_path, "sa_std")) return null;

    const rel_path = import_path["sa_std/".len..];
    const ancestor_roots = [_][]const u8{ "sa_std", "sci/sa_std" };
    if (try readImportFromAncestorRoots(allocator, base_dir, rel_path, import_path, &ancestor_roots)) |resolved| return resolved;

    if (std.process.getEnvVarOwned(allocator, "SA_STD_DIR")) |env_root| {
        if (try readImportFromRoot(allocator, env_root, rel_path, import_path)) |resolved| return resolved;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "SCI_ROOT")) |sci_root| {
        defer allocator.free(sci_root);
        const sci_sa_std_root = try std.fs.path.join(allocator, &.{ sci_root, "sa_std" });
        if (try readImportFromRoot(allocator, sci_sa_std_root, rel_path, import_path)) |resolved| return resolved;
    } else |_| {}

    if (host_paths.homeDirectory(allocator)) |home| {
        defer allocator.free(home);
        const home_std_root = try std.fs.path.join(allocator, &.{ home, "projects", "sci", "sa_std" });
        if (try readImportFromRoot(allocator, home_std_root, rel_path, import_path)) |resolved| return resolved;
    }

    const candidate_roots = [_][]const u8{
        "sa_std",
        "sci/sa_std",
        "../sa_std",
        "../sci/sa_std",
        "../../sa_std",
        "../../sci/sa_std",
        "/home/vscode/projects/sci/sa_std",
    };

    for (candidate_roots) |root| {
        if (try readImportFromRoot(allocator, root, rel_path, import_path)) |resolved| return resolved;
    }

    return null;
}

pub fn resolveSlaStdImport(allocator: std.mem.Allocator, import_path: []const u8) !?ResolvedImport {
    return resolveSlaStdImportFromBase(allocator, ".", import_path);
}

fn resolveSlaStdImportFromBase(allocator: std.mem.Allocator, base_dir: []const u8, import_path: []const u8) !?ResolvedImport {
    if (!isSlaStdImport(import_path)) return null;
    if (std.mem.eql(u8, import_path, "sla_std")) return null;

    const rel_path = import_path["sla_std/".len..];
    const ancestor_roots = [_][]const u8{ "sla_std", "sa_plugin_sla/sla_std", "sa_plugins/sa_plugin_sla/sla_std" };
    if (try readImportFromAncestorRoots(allocator, base_dir, rel_path, import_path, &ancestor_roots)) |resolved| return resolved;

    if (std.process.getEnvVarOwned(allocator, "SLA_STD_DIR")) |env_root| {
        if (try readImportFromRoot(allocator, env_root, rel_path, import_path)) |resolved| return resolved;
    } else |_| {}

    if (host_paths.homeDirectory(allocator)) |home| {
        defer allocator.free(home);
        const home_std_root = try std.fs.path.join(allocator, &.{ home, "projects", "sa_plugins", "sa_plugin_sla", "sla_std" });
        if (try readImportFromRoot(allocator, home_std_root, rel_path, import_path)) |resolved| return resolved;
    }

    const candidate_roots = [_][]const u8{
        "sla_std",
        "sa_plugin_sla/sla_std",
        "../sa_plugin_sla/sla_std",
        "../sa_plugins/sa_plugin_sla/sla_std",
        "../../sa_plugins/sa_plugin_sla/sla_std",
        "/home/vscode/projects/sa_plugins/sa_plugin_sla/sla_std",
    };

    for (candidate_roots) |root| {
        if (try readImportFromRoot(allocator, root, rel_path, import_path)) |resolved| return resolved;
    }

    return null;
}

fn isExplicitFileImportPath(path: []const u8) bool {
    return std.fs.path.isAbsolute(path) or
        std.mem.startsWith(u8, path, "./") or
        std.mem.startsWith(u8, path, "../") or
        std.mem.eql(u8, path, ".") or
        std.mem.eql(u8, path, "..");
}

fn resolveWorkspacePackageImport(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    import_path: []const u8,
) !?ResolvedImport {
    if (isExplicitFileImportPath(import_path)) return null;
    if (isGlobImportPath(import_path)) return null;
    if (isSaStdImport(import_path) or isSlaStdImport(import_path)) return null;

    const slash = std.mem.indexOfScalar(u8, import_path, '/') orelse return null;
    if (slash == 0 or slash + 1 >= import_path.len) return null;

    const package_name = import_path[0..slash];
    const rel_path = import_path[slash + 1 ..];

    var resolved_workspace = workspace.resolveFromRootPath(allocator, base_dir, .{}) catch |err| switch (err) {
        error.FileNotFound,
        error.InvalidFormat,
        error.InvalidPath,
        error.DuplicateEntry,
        error.UnknownPackage,
        error.MissingDefaultMember,
        => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer resolved_workspace.deinit(allocator);

    if (resolved_workspace.workspace_manifest == null) return null;
    const members = try workspace.listWorkspaceMembers(
        allocator,
        resolved_workspace.workspace_root,
        &resolved_workspace.workspace_manifest.?,
    );
    defer workspace.freeWorkspaceMembers(allocator, members);

    for (members) |member| {
        const member_package = member.package_name orelse continue;
        if (!std.mem.eql(u8, member_package, package_name)) continue;
        if (try readImportFromRoot(allocator, member.member_root, rel_path, import_path)) |resolved| return resolved;
        return null;
    }

    return null;
}

pub fn resolveImportFile(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    raw_import_path: []const u8,
) !ResolvedImport {
    const import_path = raw_import_path;

    if (try resolveSlaStdImportFromBase(allocator, base_dir, import_path)) |resolved| return resolved;
    if (try resolveSaStdImportFromBase(allocator, base_dir, import_path)) |resolved| return resolved;
    if (try resolveWorkspacePackageImport(allocator, base_dir, import_path)) |resolved| return resolved;

    const candidate = if (std.fs.path.isAbsolute(import_path))
        try allocator.dupe(u8, import_path)
    else
        try std.fs.path.join(allocator, &.{ base_dir, import_path });

    if (try readImportFileIfExists(allocator, candidate)) |resolved| return resolved;
    if (!std.fs.path.isAbsolute(import_path)) {
        if (try readImportFileIfExists(allocator, import_path)) |resolved| return resolved;
    }
    return error.FileNotFound;
}

pub fn appendResolvedImportFiles(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    raw_import_path: []const u8,
    exclude_path: ?[]const u8,
    out: *std.ArrayList(ResolvedImport),
) !void {
    if (!isGlobImportPath(raw_import_path)) {
        const resolved = try resolveImportFile(allocator, base_dir, raw_import_path);
        if (exclude_path) |exclude| {
            if (std.mem.eql(u8, resolved.path, exclude)) return;
        }
        try out.append(resolved);
        return;
    }

    if (isSaStdImport(raw_import_path) or isSlaStdImport(raw_import_path)) return error.FileNotFound;

    const pattern_path = if (std.fs.path.isAbsolute(raw_import_path))
        try allocator.dupe(u8, raw_import_path)
    else
        try std.fs.path.join(allocator, &.{ base_dir, raw_import_path });

    const dir_path = std.fs.path.dirname(pattern_path) orelse ".";
    const pattern_name = std.fs.path.basename(pattern_path);

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var matched_paths = std.ArrayList([]const u8).init(allocator);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!globNameMatches(pattern_name, entry.name)) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        try matched_paths.append(candidate);
    }

    std.mem.sort([]const u8, matched_paths.items, {}, stringSliceLessThan);

    var matched_count: usize = 0;
    for (matched_paths.items) |candidate| {
        if (try readImportFileIfExists(allocator, candidate)) |resolved| {
            if (exclude_path) |exclude| {
                if (std.mem.eql(u8, resolved.path, exclude)) continue;
            }
            try out.append(resolved);
            matched_count += 1;
        }
    }
    if (matched_count == 0) return error.FileNotFound;
}

pub fn resolveImportFiles(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    raw_import_path: []const u8,
    exclude_path: ?[]const u8,
) ![]ResolvedImport {
    var out = std.ArrayList(ResolvedImport).init(allocator);
    try appendResolvedImportFiles(allocator, base_dir, raw_import_path, exclude_path, &out);
    std.mem.sort(ResolvedImport, out.items, {}, resolvedImportLessThan);
    return try out.toOwnedSlice();
}

pub fn importPathFromLine(raw_line: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw_line, " \t\r");
    if (!std.mem.startsWith(u8, line, "@import")) return null;

    var rest = std.mem.trim(u8, line["@import".len..], " \t");
    if (rest.len == 0) return null;
    if (rest[0] != '"') {
        if (std.mem.indexOf(u8, rest, "//")) |comment_idx| rest = rest[0..comment_idx];
        rest = std.mem.trim(u8, rest, " \t\r;");
        if (rest.len == 0) return null;
        return rest;
    }
    if (rest.len < 2) return null;
    rest = rest[1..];

    var idx: usize = 0;
    while (idx < rest.len) : (idx += 1) {
        if (rest[idx] == '\\') {
            idx += 1;
            continue;
        }
        if (rest[idx] == '"') return rest[0..idx];
    }
    return null;
}

pub fn expandedSourceMayContainImports(expanded_source: []const u8) bool {
    return std.mem.indexOf(u8, expanded_source, "@import") != null;
}

test "resolve import by workspace package name" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("members/app/src");
    try tmp.dir.makePath("members/protocol/src");
    const workspace_manifest =
        \\workspace {
        \\  members ["members/app", "members/protocol"]
        \\  default_member "app"
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "sa.mod", .data = workspace_manifest });
    try tmp.dir.writeFile(.{ .sub_path = "members/app/sa.mod", .data = "package \"scodex-cli\"\n" });
    try tmp.dir.writeFile(.{ .sub_path = "members/protocol/sa.mod", .data = "package \"scodex-protocol\"\n" });
    try tmp.dir.writeFile(.{ .sub_path = "members/protocol/src/protocol.sla", .data = "fn protocol_ok() -> i32 { return 1; }\n" });

    const tmp_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_root);
    const app_src = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "members", "app", "src" });
    defer std.testing.allocator.free(app_src);

    const resolved = try resolveImportFile(std.testing.allocator, app_src, "scodex-protocol/src/protocol.sla");
    defer std.testing.allocator.free(resolved.path);
    defer std.testing.allocator.free(resolved.output_path);
    defer std.testing.allocator.free(resolved.source);

    try std.testing.expect(std.mem.endsWith(u8, resolved.path, "members/protocol/src/protocol.sla"));
    try std.testing.expectEqualStrings("scodex-protocol/src/protocol.sla", resolved.output_path);
    try std.testing.expect(std.mem.indexOf(u8, resolved.source, "protocol_ok") != null);
}
