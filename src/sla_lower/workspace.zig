const std = @import("std");
const host_paths = @import("host_paths.zig");

pub const ResolveError = error{
    OutOfMemory,
    FileNotFound,
    InvalidFormat,
    InvalidPath,
    DuplicateEntry,
    UnknownPackage,
    MissingDefaultMember,
};

pub const PackageSelection = struct {
    request: ?[]const u8 = null,
};

pub const WorkspaceDecl = struct {
    members: []const []const u8,
    default_member: ?[]const u8,

    pub fn deinit(self: *WorkspaceDecl, allocator: std.mem.Allocator) void {
        for (self.members) |member| allocator.free(member);
        allocator.free(self.members);
        if (self.default_member) |member| allocator.free(member);
        self.* = undefined;
    }
};

pub const Manifest = struct {
    package_name: ?[]const u8 = null,
    workspace: ?WorkspaceDecl = null,

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        if (self.package_name) |name| allocator.free(name);
        if (self.workspace) |*workspace| workspace.deinit(allocator);
        self.* = undefined;
    }
};

pub const PackageResolution = struct {
    workspace_root: []u8,
    member_root: []u8,
    workspace_manifest_path: []u8,
    member_manifest_path: []u8,
    workspace_manifest: ?Manifest,
    member_manifest: ?Manifest,
    selected_package: ?[]u8,
    workspace_rel_member_path: ?[]u8,

    pub fn deinit(self: *PackageResolution, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_root);
        allocator.free(self.member_root);
        allocator.free(self.workspace_manifest_path);
        allocator.free(self.member_manifest_path);
        if (self.workspace_manifest) |*m| m.deinit(allocator);
        if (self.member_manifest) |*m| m.deinit(allocator);
        if (self.selected_package) |name| allocator.free(name);
        if (self.workspace_rel_member_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const WorkspaceMember = struct {
    rel_path: []u8,
    member_root: []u8,
    package_name: ?[]u8,

    pub fn deinit(self: *WorkspaceMember, allocator: std.mem.Allocator) void {
        allocator.free(self.rel_path);
        allocator.free(self.member_root);
        if (self.package_name) |name| allocator.free(name);
        self.* = undefined;
    }
};

pub fn freeWorkspaceMembers(allocator: std.mem.Allocator, members: []WorkspaceMember) void {
    for (members) |*member| member.deinit(allocator);
    allocator.free(members);
}

const SelectedMember = struct {
    member_root: []u8,
    rel_path: []u8,
    package_name: ?[]u8,
};

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn startsWithWord(text: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, text, word)) return false;
    if (text.len == word.len) return true;
    const next = text[word.len];
    return std.ascii.isWhitespace(next) or next == '[' or next == '{';
}

fn stripInlineComment(line: []const u8) []const u8 {
    var in_string = false;
    var escape = false;
    var i: usize = 0;
    while (i + 1 < line.len) : (i += 1) {
        const c = line[i];
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            switch (c) {
                '\\' => escape = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }

        switch (c) {
            '"' => in_string = true,
            '/' => {
                if (line[i + 1] == '/') {
                    const prev = if (i == 0) ' ' else line[i - 1];
                    if (i == 0 or std.ascii.isWhitespace(prev)) return line[0..i];
                }
            },
            else => {},
        }
    }
    return line;
}

fn cleanLine(raw: []const u8) []const u8 {
    return trim(stripInlineComment(raw));
}

fn nextToken(text: []const u8, pos: *usize) ?[]const u8 {
    while (pos.* < text.len and std.ascii.isWhitespace(text[pos.*])) : (pos.* += 1) {}
    if (pos.* >= text.len) return null;
    const start = pos.*;
    while (pos.* < text.len and !std.ascii.isWhitespace(text[pos.*])) : (pos.* += 1) {}
    return text[start..pos.*];
}

fn parseTextValue(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = trim(text);
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]);
    }
    if (trimmed.len == 0) return error.InvalidFormat;
    return allocator.dupe(u8, trimmed);
}

fn stringListContains(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn parseStringListInto(allocator: std.mem.Allocator, text: []const u8, list: *std.ArrayList([]const u8)) !void {
    const trimmed = trim(text);
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.InvalidFormat;
    const body = trim(trimmed[1 .. trimmed.len - 1]);
    if (body.len == 0) return;

    var it = std.mem.splitScalar(u8, body, ',');
    while (it.next()) |fragment| {
        const token = trim(fragment);
        if (token.len == 0) return error.InvalidFormat;
        try list.append(try parseTextValue(allocator, token));
    }
}

fn parseUniqueStringListInto(allocator: std.mem.Allocator, text: []const u8, list: *std.ArrayList([]const u8)) !void {
    const before_len = list.items.len;
    errdefer {
        while (list.items.len > before_len) allocator.free(list.pop().?);
    }

    try parseStringListInto(allocator, text, list);
    for (list.items[before_len..]) |item| {
        if (stringListContains(list.items[0..before_len], item)) return error.DuplicateEntry;
    }
    var i = before_len;
    while (i < list.items.len) : (i += 1) {
        var j = i + 1;
        while (j < list.items.len) : (j += 1) {
            if (std.mem.eql(u8, list.items[i], list.items[j])) return error.DuplicateEntry;
        }
    }
}

fn parsePackageDecl(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var pos: usize = 0;
    const keyword = nextToken(line, &pos) orelse return error.InvalidFormat;
    if (!std.mem.eql(u8, keyword, "package")) return error.InvalidFormat;
    return parseTextValue(allocator, trim(line[pos..]));
}

fn parseWorkspaceHeader(line: []const u8) !void {
    var pos: usize = 0;
    const keyword = nextToken(line, &pos) orelse return error.InvalidFormat;
    if (!std.mem.eql(u8, keyword, "workspace")) return error.InvalidFormat;
    if (!std.mem.eql(u8, trim(line[pos..]), "{")) return error.InvalidFormat;
}

fn parseManifestWithFile(allocator: std.mem.Allocator, source: []const u8) !Manifest {
    var package_name: ?[]u8 = null;
    errdefer if (package_name) |name| allocator.free(name);

    var workspace_members = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (workspace_members.items) |member| allocator.free(member);
        workspace_members.deinit();
    }
    var workspace_default_member: ?[]u8 = null;
    errdefer if (workspace_default_member) |member| allocator.free(member);

    var workspace_present = false;
    var in_workspace = false;

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        const line = cleanLine(raw_line);
        if (line.len == 0) continue;

        if (in_workspace) {
            if (std.mem.eql(u8, line, "}")) {
                in_workspace = false;
                continue;
            }

            var pos: usize = 0;
            const key = nextToken(line, &pos) orelse return error.InvalidFormat;
            const value = trim(line[pos..]);
            if (std.mem.eql(u8, key, "members")) {
                try parseUniqueStringListInto(allocator, value, &workspace_members);
                continue;
            }
            if (std.mem.eql(u8, key, "default_member")) {
                if (workspace_default_member != null) return error.DuplicateEntry;
                workspace_default_member = try parseTextValue(allocator, value);
                continue;
            }
            return error.InvalidFormat;
        }

        if (startsWithWord(line, "workspace")) {
            if (workspace_present) return error.DuplicateEntry;
            try parseWorkspaceHeader(line);
            workspace_present = true;
            in_workspace = true;
            continue;
        }

        if (startsWithWord(line, "package")) {
            if (package_name != null) return error.DuplicateEntry;
            package_name = try parsePackageDecl(allocator, line);
            continue;
        }
    }

    if (in_workspace) return error.InvalidFormat;

    return .{
        .package_name = package_name,
        .workspace = if (workspace_present)
            WorkspaceDecl{
                .members = try workspace_members.toOwnedSlice(),
                .default_member = workspace_default_member,
            }
        else blk: {
            workspace_members.deinit();
            break :blk null;
        },
    };
}

fn pathJoinAlloc(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

fn realpathAllocResolved(allocator: std.mem.Allocator, path: []const u8) ResolveError![]u8 {
    return std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.FileNotFound,
        else => error.InvalidPath,
    };
}

fn realpathAllocIfExists(allocator: std.mem.Allocator, path: []const u8) ResolveError!?[]u8 {
    return std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => null,
        else => error.InvalidPath,
    };
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn readManifestTextFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 1024 * 1024);
}

fn readManifestFile(allocator: std.mem.Allocator, path: []const u8) ResolveError!?Manifest {
    const source = readManifestTextFileAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.InvalidPath,
    };
    defer allocator.free(source);
    return parseManifestWithFile(allocator, source) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidFormat => error.InvalidFormat,
        error.DuplicateEntry => error.DuplicateEntry,
    };
}

fn manifestPathForRoot(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    return pathJoinAlloc(allocator, &.{ root_path, "sa.mod" });
}

fn sourcePathForRoot(allocator: std.mem.Allocator, root_path: []const u8) ResolveError![]u8 {
    const src_path = try pathJoinAlloc(allocator, &.{ root_path, "src", "main.sla" });
    if (pathExists(src_path)) return src_path;
    allocator.free(src_path);

    const fallback = try pathJoinAlloc(allocator, &.{ root_path, "main.sla" });
    if (pathExists(fallback)) return fallback;
    allocator.free(fallback);
    return error.FileNotFound;
}

fn pathContains(path: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, path, prefix)) return true;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (prefix.len == 0) return true;
    if (prefix[prefix.len - 1] == std.fs.path.sep) return true;
    return path.len > prefix.len and path[prefix.len] == std.fs.path.sep;
}

fn memberRootPath(allocator: std.mem.Allocator, workspace_root: []const u8, member_rel_path: []const u8) ResolveError![]u8 {
    const joined = try pathJoinAlloc(allocator, &.{ workspace_root, member_rel_path });
    errdefer allocator.free(joined);
    if (try realpathAllocIfExists(allocator, joined)) |real_member_root| {
        allocator.free(joined);
        return real_member_root;
    }
    return joined;
}

fn findNearestManifestRoot(allocator: std.mem.Allocator, start_path: []const u8) ResolveError![]u8 {
    var current = try realpathAllocResolved(allocator, start_path);
    errdefer allocator.free(current);
    const fallback = try allocator.dupe(u8, current);
    errdefer allocator.free(fallback);

    while (true) {
        const manifest_path = try pathJoinAlloc(allocator, &.{ current, "sa.mod" });
        defer allocator.free(manifest_path);
        if (pathExists(manifest_path)) {
            allocator.free(fallback);
            return current;
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    allocator.free(current);
    return fallback;
}

pub fn listWorkspaceMembers(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    workspace_manifest: *const Manifest,
) ResolveError![]WorkspaceMember {
    var members = std.ArrayList(WorkspaceMember).init(allocator);
    errdefer {
        for (members.items) |*member| member.deinit(allocator);
        members.deinit();
    }

    if (workspace_manifest.workspace) |workspace_decl| {
        for (workspace_decl.members) |member_rel_path| {
            const member_root = try memberRootPath(allocator, workspace_root, member_rel_path);
            errdefer allocator.free(member_root);

            const member_manifest_path = try pathJoinAlloc(allocator, &.{ member_root, "sa.mod" });
            defer allocator.free(member_manifest_path);
            const maybe_member_manifest = try readManifestFile(allocator, member_manifest_path);

            const package_name = if (maybe_member_manifest != null and maybe_member_manifest.?.package_name != null)
                try allocator.dupe(u8, maybe_member_manifest.?.package_name.?)
            else
                null;

            if (maybe_member_manifest) |member_manifest| {
                var owned = member_manifest;
                owned.deinit(allocator);
            }

            try members.append(.{
                .rel_path = try allocator.dupe(u8, member_rel_path),
                .member_root = member_root,
                .package_name = package_name,
            });
        }
    } else {
        try members.append(.{
            .rel_path = try allocator.dupe(u8, "."),
            .member_root = try allocator.dupe(u8, workspace_root),
            .package_name = if (workspace_manifest.package_name) |package_name| try allocator.dupe(u8, package_name) else null,
        });
    }

    return members.toOwnedSlice();
}

fn findMemberIndexByPath(members: []const WorkspaceMember, path: []const u8) ?usize {
    var match_index: ?usize = null;
    var match_len: usize = 0;
    for (members, 0..) |member, idx| {
        if (!pathContains(path, member.member_root)) continue;
        if (member.member_root.len < match_len) continue;
        match_index = idx;
        match_len = member.member_root.len;
    }
    return match_index;
}

fn selectWorkspaceMember(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    workspace_manifest: *const Manifest,
    selection: PackageSelection,
    preferred_member_path: ?[]const u8,
) ResolveError!SelectedMember {
    const members = try listWorkspaceMembers(allocator, workspace_root, workspace_manifest);
    defer freeWorkspaceMembers(allocator, members);

    const requested = if (selection.request) |request| trim(request) else null;
    const workspace_decl = workspace_manifest.workspace;

    var selected_index: ?usize = null;
    if (requested) |req| {
        for (members, 0..) |member, idx| {
            if (std.mem.eql(u8, member.rel_path, req)) {
                selected_index = idx;
                break;
            }
            if (member.package_name) |package_name| {
                if (std.mem.eql(u8, package_name, req)) {
                    selected_index = idx;
                    break;
                }
            }
        }
        if (selected_index == null) return error.UnknownPackage;
    } else if (preferred_member_path) |path| {
        selected_index = findMemberIndexByPath(members, path);
    }

    if (selected_index == null) {
        if (workspace_decl) |decl| {
            if (decl.default_member) |default_member| {
                for (members, 0..) |member, idx| {
                    if (std.mem.eql(u8, member.rel_path, default_member)) {
                        selected_index = idx;
                        break;
                    }
                    if (member.package_name) |package_name| {
                        if (std.mem.eql(u8, package_name, default_member)) {
                            selected_index = idx;
                            break;
                        }
                    }
                }
                if (selected_index == null) return error.MissingDefaultMember;
            } else if (members.len == 1) {
                selected_index = 0;
            } else {
                return error.MissingDefaultMember;
            }
        } else {
            selected_index = 0;
        }
    }

    const selected = members[selected_index.?];
    return .{
        .member_root = try allocator.dupe(u8, selected.member_root),
        .rel_path = try allocator.dupe(u8, selected.rel_path),
        .package_name = if (selected.package_name) |package_name| try allocator.dupe(u8, package_name) else null,
    };
}

fn workspaceContainsPath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    workspace_manifest: *const Manifest,
    candidate_path: []const u8,
) ResolveError!bool {
    const members = try listWorkspaceMembers(allocator, workspace_root, workspace_manifest);
    defer freeWorkspaceMembers(allocator, members);
    return findMemberIndexByPath(members, candidate_path) != null;
}

fn findAncestorWorkspaceRoot(allocator: std.mem.Allocator, member_root: []const u8) ResolveError!?[]u8 {
    var current = std.fs.path.dirname(member_root) orelse return null;

    while (true) {
        if (std.mem.eql(u8, current, member_root)) break;

        const manifest_path = try manifestPathForRoot(allocator, current);
        defer allocator.free(manifest_path);
        const maybe_manifest = try readManifestFile(allocator, manifest_path);
        if (maybe_manifest) |workspace_manifest| {
            var owned = workspace_manifest;
            defer owned.deinit(allocator);
            if (owned.workspace != null and try workspaceContainsPath(allocator, current, &owned, member_root)) {
                const duped = try allocator.dupe(u8, current);
                return duped;
            }
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }

    return null;
}

pub fn resolveFromCurrentDir(allocator: std.mem.Allocator, selection: PackageSelection) ResolveError!PackageResolution {
    return resolveFromRootPath(allocator, ".", selection);
}

pub fn resolveFromRootPath(allocator: std.mem.Allocator, root_path: []const u8, selection: PackageSelection) ResolveError!PackageResolution {
    const start_real = try realpathAllocResolved(allocator, root_path);
    defer allocator.free(start_real);

    const anchor_root = try findNearestManifestRoot(allocator, start_real);
    const ancestor_workspace_root = try findAncestorWorkspaceRoot(allocator, anchor_root);
    errdefer if (ancestor_workspace_root == null) allocator.free(anchor_root);
    defer if (ancestor_workspace_root != null) allocator.free(anchor_root);

    const workspace_root = if (ancestor_workspace_root) |root| root else anchor_root;
    errdefer if (ancestor_workspace_root != null) allocator.free(workspace_root);

    const workspace_manifest_path = try manifestPathForRoot(allocator, workspace_root);
    errdefer allocator.free(workspace_manifest_path);
    const workspace_manifest = try readManifestFile(allocator, workspace_manifest_path);
    errdefer if (workspace_manifest) |manifest_value| {
        var owned = manifest_value;
        owned.deinit(allocator);
    };

    const selected: SelectedMember = if (workspace_manifest) |*workspace_manifest_value|
        try selectWorkspaceMember(
            allocator,
            workspace_root,
            workspace_manifest_value,
            selection,
            if (ancestor_workspace_root != null) anchor_root else start_real,
        )
    else
        SelectedMember{
            .member_root = try allocator.dupe(u8, workspace_root),
            .rel_path = try allocator.dupe(u8, "."),
            .package_name = null,
        };
    errdefer {
        allocator.free(selected.member_root);
        allocator.free(selected.rel_path);
        if (selected.package_name) |name| allocator.free(name);
    }

    const member_manifest_path = try manifestPathForRoot(allocator, selected.member_root);
    errdefer allocator.free(member_manifest_path);
    const member_manifest = try readManifestFile(allocator, member_manifest_path);
    errdefer if (member_manifest) |manifest_value| {
        var owned = manifest_value;
        owned.deinit(allocator);
    };

    return .{
        .workspace_root = workspace_root,
        .member_root = selected.member_root,
        .workspace_manifest_path = workspace_manifest_path,
        .member_manifest_path = member_manifest_path,
        .workspace_manifest = workspace_manifest,
        .member_manifest = member_manifest,
        .selected_package = selected.package_name,
        .workspace_rel_member_path = selected.rel_path,
    };
}

pub fn selectedSourcePath(allocator: std.mem.Allocator, resolved: *const PackageResolution) ResolveError![]u8 {
    const raw = try sourcePathForRoot(allocator, resolved.member_root);
    defer allocator.free(raw);
    return host_paths.normalizePathSlashes(allocator, raw);
}

test "workspace resolver selects default member by package name" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("members/app/src");
    try tmp.dir.makePath("members/tool/src");
    try tmp.dir.writeFile(.{ .sub_path = "sa.mod", .data = 
        \\workspace {
        \\  members ["members/app", "members/tool"]
        \\  default_member "app"
        \\}
    });
    try tmp.dir.writeFile(.{ .sub_path = "members/app/sa.mod", .data = "package \"app\"\n" });
    try tmp.dir.writeFile(.{ .sub_path = "members/app/src/main.sla", .data = "fn main() -> i32 {\n    return 0;\n};\n" });
    try tmp.dir.writeFile(.{ .sub_path = "members/tool/sa.mod", .data = "package \"tool\"\n" });
    try tmp.dir.writeFile(.{ .sub_path = "members/tool/src/main.sla", .data = "fn main() -> i32 {\n    return 1;\n};\n" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var resolved = try resolveFromRootPath(std.testing.allocator, root, .{});
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("members/app", resolved.workspace_rel_member_path.?);
    try std.testing.expectEqualStrings("app", resolved.selected_package.?);

    const source_path = try selectedSourcePath(std.testing.allocator, &resolved);
    defer std.testing.allocator.free(source_path);
    try std.testing.expect(std.mem.endsWith(u8, source_path, "members/app/src/main.sla"));
}

test "workspace resolver selects explicit member by relative path" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("members/tool/src");
    try tmp.dir.writeFile(.{ .sub_path = "sa.mod", .data = 
        \\workspace {
        \\  members ["members/tool"]
        \\  default_member "members/tool"
        \\}
    });
    try tmp.dir.writeFile(.{ .sub_path = "members/tool/sa.mod", .data = "package \"tool\"\n" });
    try tmp.dir.writeFile(.{ .sub_path = "members/tool/src/main.sla", .data = "fn main() -> i32 {\n    return 1;\n};\n" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var resolved = try resolveFromRootPath(std.testing.allocator, root, .{ .request = "members/tool" });
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("members/tool", resolved.workspace_rel_member_path.?);
    try std.testing.expectEqualStrings("tool", resolved.selected_package.?);
}

test "workspace resolver climbs from member manifest to ancestor workspace root" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("members/app/src");
    try tmp.dir.makePath("members/tool/src");
    try tmp.dir.writeFile(.{ .sub_path = "sa.mod", .data = 
        \\workspace {
        \\  members ["members/app", "members/tool"]
        \\  default_member "tool"
        \\}
    });
    try tmp.dir.writeFile(.{ .sub_path = "members/app/sa.mod", .data = "package \"app\"\n" });
    try tmp.dir.writeFile(.{ .sub_path = "members/app/src/main.sla", .data = "fn main() -> i32 {\n    return 7;\n};\n" });
    try tmp.dir.writeFile(.{ .sub_path = "members/tool/sa.mod", .data = "package \"tool\"\n" });
    try tmp.dir.writeFile(.{ .sub_path = "members/tool/src/main.sla", .data = "fn main() -> i32 {\n    return 9;\n};\n" });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var resolved = try resolveFromRootPath(std.testing.allocator, "members/app/src", .{});
    defer resolved.deinit(std.testing.allocator);

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const member_root = try tmp.dir.realpathAlloc(std.testing.allocator, "members/app");
    defer std.testing.allocator.free(member_root);

    try std.testing.expectEqualStrings(root, resolved.workspace_root);
    try std.testing.expectEqualStrings(member_root, resolved.member_root);
    try std.testing.expectEqualStrings("members/app", resolved.workspace_rel_member_path.?);
    try std.testing.expectEqualStrings("app", resolved.selected_package.?);
}

