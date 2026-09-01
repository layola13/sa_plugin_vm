const std = @import("std");

pub const SourceExpandError = error{
    InvalidExpandTuple,
    OutOfMemory,
};

const Directive = struct {
    args_start: usize,
    args_end: usize,
    body_start: usize,
    body_end: usize,
    end: usize,
};

const TupleContext = struct {
    arity: usize,
    type_prefix: []const u8,
    current_index: ?usize = null,

    fn currentTypeName(self: TupleContext, allocator: std.mem.Allocator) SourceExpandError![]const u8 {
        const index = self.current_index orelse return SourceExpandError.InvalidExpandTuple;
        return std.fmt.allocPrint(allocator, "{s}{}", .{ self.type_prefix, index }) catch return SourceExpandError.OutOfMemory;
    }

    fn typeList(self: TupleContext, allocator: std.mem.Allocator) SourceExpandError![]const u8 {
        var out = std.ArrayList(u8).init(allocator);
        for (0..self.arity) |i| {
            if (i != 0) try out.appendSlice(", ");
            out.writer().print("{s}{}", .{ self.type_prefix, i }) catch return SourceExpandError.OutOfMemory;
        }
        return out.toOwnedSlice() catch return SourceExpandError.OutOfMemory;
    }
};

pub fn expand(allocator: std.mem.Allocator, source: []const u8) SourceExpandError![]const u8 {
    if (std.mem.indexOf(u8, source, "@expand_tuple") == null) {
        return allocator.dupe(u8, source) catch return SourceExpandError.OutOfMemory;
    }

    var out = std.ArrayList(u8).init(allocator);
    // Large ECS modules use many @expand_tuple blocks; avoid geometric realloc churn.
    try out.ensureTotalCapacity(source.len * 2);
    var i: usize = 0;
    while (i < source.len) {
        if (startsWithAt(source, i, "@expand_tuple")) {
            const directive = try parseDirective(source, i, "@expand_tuple");
            const args = source[directive.args_start..directive.args_end];
            const spec = try parseExpandTupleArgs(args);
            const body = source[directive.body_start..directive.body_end];
            var n = spec.min;
            while (n <= spec.max) : (n += 1) {
                const ctx = TupleContext{ .arity = n, .type_prefix = spec.type_prefix };
                const expanded = try expandTemplate(allocator, body, ctx);
                try out.appendSlice(expanded);
                if (expanded.len == 0 or expanded[expanded.len - 1] != '\n') try out.append('\n');
                allocator.free(expanded);
            }
            i = directive.end;
            continue;
        }
        try out.append(source[i]);
        i += 1;
    }
    return out.toOwnedSlice() catch return SourceExpandError.OutOfMemory;
}

pub fn expandForModulePath(allocator: std.mem.Allocator, module_path: []const u8, source: []const u8) SourceExpandError![]const u8 {
    if (std.mem.indexOf(u8, source, "@expand_tuple") == null) {
        return expand(allocator, source);
    }
    const cache_path = expandCachePath(allocator, module_path, source) catch return expand(allocator, source);
    defer allocator.free(cache_path);
    if (loadExpandedSourceCache(allocator, cache_path) catch null) |cached| {
        return cached;
    }
    const expanded = try expand(allocator, source);
    storeExpandedSourceCache(cache_path, expanded);
    return expanded;
}

fn expandCachePath(allocator: std.mem.Allocator, module_path: []const u8, source: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(module_path);
    hasher.update(&std.mem.toBytes(@as(u64, source.len)));
    hasher.update(source);
    const digest = hasher.final();
    const stem = std.fs.path.basename(module_path);
    return try std.fmt.allocPrint(allocator, ".sla-cache/expand/{s}-{x}.sla", .{ stem, digest });
}

fn loadExpandedSourceCache(allocator: std.mem.Allocator, cache_path: []const u8) !?[]u8 {
    return std.fs.cwd().readFileAlloc(allocator, cache_path, 64 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

fn storeExpandedSourceCache(cache_path: []const u8, expanded: []const u8) void {
    const dir = std.fs.path.dirname(cache_path) orelse return;
    std.fs.cwd().makePath(dir) catch return;
    const file = std.fs.cwd().createFile(cache_path, .{}) catch return;
    defer file.close();
    file.writeAll(expanded) catch {};
}

const ExpandTupleSpec = struct {
    min: usize,
    max: usize,
    type_prefix: []const u8,
};

fn parseExpandTupleArgs(args: []const u8) SourceExpandError!ExpandTupleSpec {
    var parts = std.mem.splitScalar(u8, args, ',');
    const min_part = trim(parts.next() orelse return SourceExpandError.InvalidExpandTuple);
    const max_part = trim(parts.next() orelse return SourceExpandError.InvalidExpandTuple);
    const prefix_part = trim(parts.next() orelse return SourceExpandError.InvalidExpandTuple);
    if (parts.next() != null) return SourceExpandError.InvalidExpandTuple;
    if (prefix_part.len == 0 or !isIdentStart(prefix_part[0])) return SourceExpandError.InvalidExpandTuple;
    for (prefix_part[1..]) |c| if (!isIdentContinue(c)) return SourceExpandError.InvalidExpandTuple;
    const min = std.fmt.parseInt(usize, min_part, 10) catch return SourceExpandError.InvalidExpandTuple;
    const max = std.fmt.parseInt(usize, max_part, 10) catch return SourceExpandError.InvalidExpandTuple;
    if (min > max) return SourceExpandError.InvalidExpandTuple;
    return .{ .min = min, .max = max, .type_prefix = prefix_part };
}

fn expandTemplate(allocator: std.mem.Allocator, template: []const u8, ctx: TupleContext) SourceExpandError![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    while (i < template.len) {
        if (startsWithAt(template, i, "@each")) {
            const directive = try parseDirective(template, i, "@each");
            const name = trim(template[directive.args_start..directive.args_end]);
            if (!std.mem.eql(u8, name, ctx.type_prefix)) return SourceExpandError.InvalidExpandTuple;
            const body = template[directive.body_start..directive.body_end];
            for (0..ctx.arity) |idx| {
                const child_ctx = TupleContext{ .arity = ctx.arity, .type_prefix = ctx.type_prefix, .current_index = idx };
                const expanded = try expandTemplate(allocator, body, child_ctx);
                try out.appendSlice(expanded);
                allocator.free(expanded);
            }
            i = directive.end;
            continue;
        }
        if (startsWithAt(template, i, "@join")) {
            const directive = try parseDirective(template, i, "@join");
            const join_args = template[directive.args_start..directive.args_end];
            const join = try parseJoinArgs(join_args);
            if (!std.mem.eql(u8, join.name, ctx.type_prefix)) return SourceExpandError.InvalidExpandTuple;
            const body = template[directive.body_start..directive.body_end];
            for (0..ctx.arity) |idx| {
                if (idx != 0) try out.appendSlice(join.separator);
                const child_ctx = TupleContext{ .arity = ctx.arity, .type_prefix = ctx.type_prefix, .current_index = idx };
                const expanded = try expandTemplate(allocator, body, child_ctx);
                try out.appendSlice(trim(expanded));
                allocator.free(expanded);
            }
            i = directive.end;
            continue;
        }

        const replaced = try appendPlaceholder(&out, template, &i, ctx);
        if (!replaced) {
            try out.append(template[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice() catch return SourceExpandError.OutOfMemory;
}

fn appendPlaceholder(out: *std.ArrayList(u8), text: []const u8, index: *usize, ctx: TupleContext) SourceExpandError!bool {
    const i = index.*;
    if (text[i] != '$') return false;
    if (startsWithAt(text, i, "$TYPE_PARAMS") or startsWithAt(text, i, "$TYPES")) {
        for (0..ctx.arity) |type_index| {
            if (type_index != 0) try out.appendSlice(", ");
            out.writer().print("{s}{}", .{ ctx.type_prefix, type_index }) catch return SourceExpandError.OutOfMemory;
        }
        index.* += if (startsWithAt(text, i, "$TYPE_PARAMS")) "$TYPE_PARAMS".len else "$TYPES".len;
        return true;
    }
    if (startsWithAt(text, i, "$N")) {
        out.writer().print("{}", .{ctx.arity}) catch return SourceExpandError.OutOfMemory;
        index.* += 2;
        return true;
    }
    if (startsWithAt(text, i, "$I")) {
        const idx = ctx.current_index orelse return SourceExpandError.InvalidExpandTuple;
        out.writer().print("{}", .{idx}) catch return SourceExpandError.OutOfMemory;
        index.* += 2;
        return true;
    }
    if (startsWithAt(text, i, "$ORD")) {
        const idx = ctx.current_index orelse return SourceExpandError.InvalidExpandTuple;
        try out.appendSlice(ordinalName(idx) orelse return SourceExpandError.InvalidExpandTuple);
        index.* += "$ORD".len;
        return true;
    }
    if (startsWithAt(text, i + 1, ctx.type_prefix) and placeholderBoundary(text, i + 1 + ctx.type_prefix.len)) {
        const type_index = ctx.current_index orelse return SourceExpandError.InvalidExpandTuple;
        out.writer().print("{s}{}", .{ ctx.type_prefix, type_index }) catch return SourceExpandError.OutOfMemory;
        index.* += 1 + ctx.type_prefix.len;
        return true;
    }
    if (startsWithAt(text, i, "$T")) {
        const type_index = ctx.current_index orelse return SourceExpandError.InvalidExpandTuple;
        out.writer().print("{s}{}", .{ ctx.type_prefix, type_index }) catch return SourceExpandError.OutOfMemory;
        index.* += 2;
        return true;
    }
    return false;
}

const JoinArgs = struct {
    name: []const u8,
    separator: []const u8,
};

fn parseJoinArgs(args: []const u8) SourceExpandError!JoinArgs {
    const comma = std.mem.indexOfScalar(u8, args, ',') orelse return SourceExpandError.InvalidExpandTuple;
    const name = trim(args[0..comma]);
    const raw_sep = trim(args[comma + 1 ..]);
    if (raw_sep.len < 2 or raw_sep[0] != '"' or raw_sep[raw_sep.len - 1] != '"') return SourceExpandError.InvalidExpandTuple;
    return .{ .name = name, .separator = raw_sep[1 .. raw_sep.len - 1] };
}

fn parseDirective(source: []const u8, start: usize, name: []const u8) SourceExpandError!Directive {
    var i = start + name.len;
    i = skipWhitespace(source, i);
    if (i >= source.len or source[i] != '(') return SourceExpandError.InvalidExpandTuple;
    const args_start = i + 1;
    const args_end = findMatchingParen(source, i) orelse return SourceExpandError.InvalidExpandTuple;
    i = skipWhitespace(source, args_end + 1);
    if (i >= source.len or source[i] != '{') return SourceExpandError.InvalidExpandTuple;
    const body_end = findMatchingBrace(source, i) orelse return SourceExpandError.InvalidExpandTuple;
    return .{
        .args_start = args_start,
        .args_end = args_end,
        .body_start = i + 1,
        .body_end = body_end,
        .end = body_end + 1,
    };
}

fn findMatchingParen(source: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < source.len) : (i += 1) {
        switch (source[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            '"' => i = skipString(source, i) orelse return null,
            else => {},
        }
    }
    return null;
}

fn findMatchingBrace(source: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < source.len) : (i += 1) {
        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '/') {
            i = skipLine(source, i + 2);
            continue;
        }
        switch (source[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            '"' => i = skipString(source, i) orelse return null,
            else => {},
        }
    }
    return null;
}

fn skipString(source: []const u8, quote: usize) ?usize {
    var i = quote + 1;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\\') {
            i += 1;
            continue;
        }
        if (source[i] == '"') return i;
    }
    return null;
}

fn skipLine(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and source[i] != '\n') : (i += 1) {}
    return i;
}

fn skipWhitespace(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and std.ascii.isWhitespace(source[i])) : (i += 1) {}
    return i;
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

fn startsWithAt(source: []const u8, index: usize, needle: []const u8) bool {
    return index + needle.len <= source.len and std.mem.eql(u8, source[index .. index + needle.len], needle);
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn placeholderBoundary(source: []const u8, index: usize) bool {
    return index >= source.len or !isIdentContinue(source[index]);
}

fn ordinalName(index: usize) ?[]const u8 {
    return switch (index) {
        0 => "first",
        1 => "second",
        2 => "third",
        3 => "fourth",
        4 => "fifth",
        5 => "sixth",
        6 => "seventh",
        7 => "eighth",
        8 => "ninth",
        9 => "tenth",
        10 => "eleventh",
        11 => "twelfth",
        12 => "thirteenth",
        13 => "fourteenth",
        14 => "fifteenth",
        15 => "sixteenth",
        else => null,
    };
}

test "expand tuple arity template" {
    const source =
        \\@expand_tuple(2, 3, T) {
        \\struct Generated$N<$TYPES> {
        \\@each(T) {
        \\    value_$I: $T,
        \\}
        \\}
        \\fn make$N<@join(T, ", ") { $T }>(@join(T, ", ") { value_$I: $T }) -> i64 {
        \\    let sum = 0;
        \\@each(T) {
        \\    sum = sum + value_$I;
        \\}
        \\    return sum;
        \\}
        \\}
    ;
    const expanded = try expand(std.testing.allocator, source);
    defer std.testing.allocator.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "struct Generated2<T0, T1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "value_2: T2") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "fn make3<T0, T1, T2>") != null);
}

test "expand without tuple directive returns owned copy" {
    const source = "fn main() -> i32 { return 1; }";
    const expanded = try expand(std.testing.allocator, source);
    defer std.testing.allocator.free(expanded);

    try std.testing.expectEqualStrings(source, expanded);
    try std.testing.expect(expanded.ptr != source.ptr);
}

test "expand tuple ordinal placeholder" {
    const source =
        \\@expand_tuple(2, 3, T) {
        \\struct Ordinal$N<$TYPES> {
        \\@each(T) {
        \\    $ORD: $T,
        \\}
        \\}
        \\}
    ;
    const expanded = try expand(std.testing.allocator, source);
    defer std.testing.allocator.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "first: T0") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "second: T1") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "third: T2") != null);
}

test "expand tuple current type placeholder follows prefix" {
    const source =
        \\@expand_tuple(1, 2, P) {
        \\struct ParamSet$N<@join(P, ", ") { $P }> {
        \\@each(P) {
        \\    p$I: $P,
        \\}
        \\}
        \\}
    ;
    const expanded = try expand(std.testing.allocator, source);
    defer std.testing.allocator.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "struct ParamSet1<P0>") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "p0: P0") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "struct ParamSet2<P0, P1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "p1: P1") != null);
}

test "expand tuple processes multiple top level directives" {
    const source =
        \\@expand_tuple(2, 2, T) {
        \\struct First$N<$TYPES> {}
        \\}
        \\@expand_tuple(3, 3, T) {
        \\struct Second$N<$TYPES> {}
        \\}
    ;
    const expanded = try expand(std.testing.allocator, source);
    defer std.testing.allocator.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "struct First2<T0, T1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "struct Second3<T0, T1, T2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "@expand_tuple") == null);
}
test "expandForModulePath uses disk cache for expand_tuple" {
    const source =
        \\@expand_tuple(1, 2, T) {
        \\fn f_$N() -> i32 { return $N; }
        \\}
    ;
    const path = "unit_expand_cache_mod.sla";
    const first = try expandForModulePath(std.testing.allocator, path, source);
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "fn f_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "fn f_2") != null);
    const second = try expandForModulePath(std.testing.allocator, path, source);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}
