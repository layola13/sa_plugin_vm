const std = @import("std");
const type_checker_mod = @import("type_checker.zig");
const source_expand = @import("source_expand.zig");
const contract_parser = @import("contract_parser.zig");

pub fn expandedSourceMayContainImportedMacros(expanded_source: []const u8) bool {
    return std.mem.indexOf(u8, expanded_source, "[MACRO]") != null;
}

pub fn macroParamName(raw: []const u8) []const u8 {
    var param = std.mem.trim(u8, raw, " \t\r,");
    if (param.len > 0 and param[0] == '%') param = param[1..];
    return param;
}

pub fn isLeadingOutputMacroParam(raw: []const u8) bool {
    const param = macroParamName(raw);
    return std.mem.startsWith(u8, param, "out") or
        std.mem.eql(u8, param, "nonnull_ptr") or
        std.mem.eql(u8, param, "type_id") or
        std.mem.eql(u8, param, "any_ref") or
        std.mem.eql(u8, param, "cursor") or
        std.mem.eql(u8, param, "take") or
        std.mem.eql(u8, param, "repeat");
}

pub fn macroParamIndex(param_names: []const []const u8, name: []const u8) ?usize {
    for (param_names, 0..) |param, idx| {
        if (std.mem.eql(u8, param, name)) return idx;
    }
    return null;
}

pub fn markBorrowedParam(mask: *u64, param_names: []const []const u8, raw_name: []const u8) void {
    const name = macroParamName(raw_name);
    if (macroParamIndex(param_names, name)) |idx| {
        if (idx < 64) mask.* |= (@as(u64, 1) << @intCast(idx));
    }
}

pub fn markDirectBorrowedMacroParams(allocator: std.mem.Allocator, mask: *u64, param_names: []const []const u8, line: []const u8) !void {
    for (param_names) |param| {
        const needle = try std.fmt.allocPrint(allocator, "&%{s}", .{param});
        defer allocator.free(needle);
        if (std.mem.indexOf(u8, line, needle) != null) markBorrowedParam(mask, param_names, param);
    }
}

pub fn markDirectAddressSlotMacroParams(allocator: std.mem.Allocator, mask: *u64, param_names: []const []const u8, line: []const u8) !void {
    for (param_names) |param| {
        const needle = try std.fmt.allocPrint(allocator, "%{s}+", .{param});
        defer allocator.free(needle);
        if (std.mem.indexOf(u8, line, needle) != null) markBorrowedParam(mask, param_names, param);
    }
}

/// Call-site capability requirements of one extern contract, indexed by
/// parameter position.
const ExternForwardCaps = struct {
    /// Positions declared `&name: ty`: expanded call args need a `&` prefix.
    borrow_mask: u64 = 0,
    /// Positions declared plain `name: ptr`-ish: the callee consumes (moves)
    /// the operand, so reused caller values must be forwarded as a copy.
    move_ptr_mask: u64 = 0,
};

fn externContractIsPointerTy(ty: []const u8) bool {
    return std.mem.eql(u8, ty, "ptr") or std.mem.endsWith(u8, ty, "*");
}

fn externForwardCaps(contracts: []const contract_parser.ExternalFunction, callee_name: []const u8) ?ExternForwardCaps {
    for (contracts) |f| {
        if (!std.mem.eql(u8, f.name, callee_name)) continue;
        var caps = ExternForwardCaps{};
        for (f.params, 0..) |p, i| {
            if (i >= 64) break;
            const bit = @as(u64, 1) << @intCast(i);
            if (p.is_borrow) {
                caps.borrow_mask |= bit;
            } else if (externContractIsPointerTy(p.ty)) {
                caps.move_ptr_mask |= bit;
            }
        }
        return caps;
    }
    return null;
}

/// For each `call @callee(...)` in a macro body line, mark macro params that
/// are substituted plainly into an argument position whose callee contract
/// requires borrow or consumes a pointer. Borrow positions must be emitted
/// with an explicit `&` prefix; pointer-consuming positions must receive a
/// fresh copy of the caller value so a reused identifier stays usable —
/// otherwise SA/SAB verification rejects the expansion (CapabilityMismatch /
/// UseAfterMove).
pub fn markCalleeForwardedParamCaps(
    allocator: std.mem.Allocator,
    contracts: []const contract_parser.ExternalFunction,
    borrow_prefix_mask: *u64,
    move_ptr_mask: *u64,
    param_names: []const []const u8,
    line: []const u8,
) void {
    var rest = line;
    while (std.mem.indexOf(u8, rest, "call @")) |idx| {
        const name_start = idx + "call @".len;
        var name_end = name_start;
        while (name_end < rest.len) : (name_end += 1) {
            const c = rest[name_end];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == ':')) break;
        }
        if (name_end == name_start) {
            rest = rest[name_start..];
            if (rest.len == 0) return;
            continue;
        }
        const callee_name = importedMacroCalleeName(allocator, rest[name_start..name_end]) catch {
            rest = rest[name_end..];
            continue;
        };
        defer allocator.free(callee_name);
        const after_name = rest[name_end..];
        const paren_rel = std.mem.indexOfScalar(u8, after_name, '(') orelse {
            rest = after_name;
            if (after_name.len == 0) return;
            continue;
        };
        var depth: usize = 1;
        var scan = paren_rel + 1;
        while (scan < after_name.len and depth > 0) : (scan += 1) {
            if (after_name[scan] == '(') {
                depth += 1;
            } else if (after_name[scan] == ')') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (depth != 0 or scan >= after_name.len) {
            rest = after_name[paren_rel..];
            continue;
        }
        const args_str = after_name[paren_rel + 1 .. scan];
        if (externForwardCaps(contracts, callee_name)) |caps| {
            var arg_idx: usize = 0;
            var args = std.mem.splitScalar(u8, args_str, ',');
            while (args.next()) |raw| : (arg_idx += 1) {
                if (arg_idx >= 64) break;
                const tok = std.mem.trim(u8, raw, " \t\r");
                if (tok.len < 2 or tok[0] != '%') continue;
                const bit = @as(u64, 1) << @intCast(arg_idx);
                if ((caps.borrow_mask & bit) != 0) markBorrowedParam(borrow_prefix_mask, param_names, tok);
                if ((caps.move_ptr_mask & bit) != 0) markBorrowedParam(move_ptr_mask, param_names, tok);
            }
        }
        rest = after_name[scan..];
        if (rest.len == 0) return;
    }
}

/// Propagate callee-forwarding caps through nested `EXPAND other_macro ...`
/// body lines: if the expanded macro needs a borrow prefix or a consuming
/// copy at some param position and this macro forwards one of its own params
/// there, mark this macro's param accordingly.
pub fn markExpandedImportedMacroForwardedCaps(
    tc: *type_checker_mod.TypeChecker,
    borrow_prefix_mask: *u64,
    move_ptr_mask: *u64,
    param_names: []const []const u8,
    line: []const u8,
) void {
    if (!std.mem.startsWith(u8, line, "EXPAND")) return;
    var parts = std.mem.tokenizeAny(u8, line["EXPAND".len..], " \t,");
    const expanded_name = parts.next() orelse return;
    const expanded = tc.imported_macros.get(expanded_name) orelse return;

    var arg_idx: usize = 0;
    while (parts.next()) |raw_arg| : (arg_idx += 1) {
        if (arg_idx >= 64) continue;
        const trimmed = std.mem.trim(u8, raw_arg, " \t\r,");
        if (trimmed.len == 0 or trimmed[0] != '%') continue;
        const arg_bit = @as(u64, 1) << @intCast(arg_idx);
        if ((expanded.callee_borrow_prefix_mask & arg_bit) != 0) markBorrowedParam(borrow_prefix_mask, param_names, trimmed);
        if ((expanded.callee_consume_ptr_mask & arg_bit) != 0) markBorrowedParam(move_ptr_mask, param_names, trimmed);
    }
}

pub fn markExpandedImportedMacroParamMasks(
    tc: *type_checker_mod.TypeChecker,
    borrowed_mask: *u64,
    address_slot_mask: *u64,
    param_names: []const []const u8,
    line: []const u8,
) void {
    if (!std.mem.startsWith(u8, line, "EXPAND")) return;
    var parts = std.mem.tokenizeAny(u8, line["EXPAND".len..], " \t,");
    const expanded_name = parts.next() orelse return;
    const expanded = tc.imported_macros.get(expanded_name) orelse return;

    var arg_idx: usize = 0;
    while (parts.next()) |raw_arg| : (arg_idx += 1) {
        if (arg_idx >= 64) continue;
        const trimmed = std.mem.trim(u8, raw_arg, " \t\r,");
        if (trimmed.len == 0 or trimmed[0] != '%') continue;
        const arg_bit = @as(u64, 1) << @intCast(arg_idx);
        if ((expanded.borrowed_arg_mask & arg_bit) != 0) markBorrowedParam(borrowed_mask, param_names, trimmed);
        if ((expanded.address_slot_arg_mask & arg_bit) != 0) markBorrowedParam(address_slot_mask, param_names, trimmed);
    }
}

pub fn importedMacroCalleeName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\"");
    const without_at = if (std.mem.startsWith(u8, trimmed, "@")) trimmed[1..] else trimmed;
    const source_name = if (std.mem.startsWith(u8, without_at, "sla__")) without_at["sla__".len..] else without_at;
    return try allocator.dupe(u8, source_name);
}

pub fn appendUniqueDirectCallee(callees: *std.ArrayList([]const u8), name: []const u8) !void {
    for (callees.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try callees.append(name);
}

pub fn collectDirectSlaMacroCallees(allocator: std.mem.Allocator, callees: *std.ArrayList([]const u8), line: []const u8) !void {
    var rest = line;
    while (std.mem.indexOf(u8, rest, "call @")) |idx| {
        const start = idx + "call @".len;
        var end = start;
        while (end < rest.len) : (end += 1) {
            const c = rest[end];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == ':')) break;
        }
        if (end > start) {
            const name = try importedMacroCalleeName(allocator, rest[start..end]);
            try appendUniqueDirectCallee(callees, name);
        }
        rest = rest[end..];
    }
}

pub fn appendExpandedImportedMacroDirectCallees(
    tc: *type_checker_mod.TypeChecker,
    callees: *std.ArrayList([]const u8),
    line: []const u8,
) !void {
    if (!std.mem.startsWith(u8, line, "EXPAND")) return;
    var parts = std.mem.tokenizeAny(u8, line["EXPAND".len..], " \t,");
    const expanded_name = parts.next() orelse return;
    const expanded = tc.imported_macros.get(expanded_name) orelse return;
    for (expanded.direct_callees) |callee| try appendUniqueDirectCallee(callees, callee);
}

fn macroIndexCachePath(allocator: std.mem.Allocator, import_path: []const u8, expanded_source: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    // Record format version: bump to invalidate on-disk caches written by
    // builds whose record line had fewer fields.
    hasher.update("idx-v3-callee-forward-caps");
    hasher.update(import_path);
    hasher.update(&std.mem.toBytes(@as(u64, expanded_source.len)));
    hasher.update(expanded_source);
    const digest = hasher.final();
    const stem = std.fs.path.basename(import_path);
    return try std.fmt.allocPrint(allocator, ".sla-cache/macros/{s}-{x}.idx", .{ stem, digest });
}

fn tryLoadImportedMacrosFromCache(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    cache_path: []const u8,
    import_path: ?[]const u8,
) !bool {
    const bytes = std.fs.cwd().readFileAlloc(allocator, cache_path, 16 * 1024 * 1024) catch return false;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        var parts = std.mem.splitScalar(u8, raw, '|');
        const name = parts.next() orelse continue;
        const arity_s = parts.next() orelse continue;
        const leading_s = parts.next() orelse continue;
        const borrow_s = parts.next() orelse continue;
        const address_s = parts.next() orelse continue;
        const callee_borrow_s = parts.next() orelse continue;
        const callee_consume_s = parts.next() orelse continue;
        const callees_s = parts.next() orelse "";
        const arity = std.fmt.parseInt(usize, arity_s, 10) catch continue;
        const leading = std.fmt.parseInt(usize, leading_s, 10) catch continue;
        const borrowed = std.fmt.parseInt(u64, borrow_s, 10) catch continue;
        const address = std.fmt.parseInt(u64, address_s, 10) catch continue;
        const callee_borrow = std.fmt.parseInt(u64, callee_borrow_s, 10) catch continue;
        const callee_consume = std.fmt.parseInt(u64, callee_consume_s, 10) catch continue;
        var callee_list = std.ArrayList([]const u8).init(allocator);
        defer callee_list.deinit();
        if (callees_s.len != 0) {
            var cparts = std.mem.splitScalar(u8, callees_s, ',');
            while (cparts.next()) |c| {
                if (c.len == 0) continue;
                try callee_list.append(try allocator.dupe(u8, c));
            }
        }
        const owned_import = if (import_path) |path| try allocator.dupe(u8, path) else null;
        try tc.registerImportedMacro(try allocator.dupe(u8, name), arity, leading, owned_import, borrowed, address, callee_borrow, callee_consume, try callee_list.toOwnedSlice());
    }
    return true;
}

fn storeImportedMacrosCache(cache_path: []const u8, records: []const []const u8) void {
    const dir = std.fs.path.dirname(cache_path) orelse return;
    std.fs.cwd().makePath(dir) catch return;
    const file = std.fs.cwd().createFile(cache_path, .{}) catch return;
    defer file.close();
    for (records) |line| {
        file.writeAll(line) catch return;
        file.writeAll("\n") catch return;
    }
}

pub fn loadImportedMacrosFromExpandedSource(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    expanded_source: []const u8,
    import_path: ?[]const u8,
) !void {
    if (!expandedSourceMayContainImportedMacros(expanded_source)) return;
    if (import_path) |path| {
        const cache_path = macroIndexCachePath(allocator, path, expanded_source) catch null;
        if (cache_path) |cp| {
            defer allocator.free(cp);
            if (try tryLoadImportedMacrosFromCache(tc, allocator, cp, import_path)) return;
        }
    }
    var cache_records = std.ArrayList([]const u8).init(allocator);
    defer {
        for (cache_records.items) |line| allocator.free(line);
        cache_records.deinit();
    }
    // Extern contracts declared in the same file: macro bodies may call them,
    // and their borrow parameters dictate where expanded call args need an
    // explicit `&` capability prefix.
    var extern_parser = contract_parser.ContractParser.init(allocator);
    const extern_contracts = extern_parser.parseSai(expanded_source) catch &[_]contract_parser.ExternalFunction{};
    defer {
        for (extern_contracts) |f| allocator.free(f.params);
        allocator.free(extern_contracts);
    }
    var lines = std.mem.splitScalar(u8, expanded_source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "[MACRO]")) continue;

        var parts = std.mem.tokenizeAny(u8, line["[MACRO]".len..], " \t");
        const raw_name = parts.next() orelse continue;
        const name = try allocator.dupe(u8, std.mem.trim(u8, raw_name, " \t\r,"));

        var param_names = std.ArrayList([]const u8).init(allocator);
        defer param_names.deinit();
        var arity: usize = 0;
        var leading_outputs: usize = 0;
        var still_leading = true;
        while (parts.next()) |raw_param| {
            const param = macroParamName(raw_param);
            if (param.len == 0) continue;
            try param_names.append(param);
            if (still_leading and isLeadingOutputMacroParam(raw_param)) {
                leading_outputs += 1;
            } else {
                still_leading = false;
            }
            arity += 1;
        }

        var borrowed_arg_mask: u64 = 0;
        var address_slot_arg_mask: u64 = 0;
        var callee_borrow_prefix_mask: u64 = 0;
        var callee_consume_ptr_mask: u64 = 0;
        var direct_callees = std.ArrayList([]const u8).init(allocator);
        defer direct_callees.deinit();
        while (lines.next()) |body_raw_line| {
            const body_line = std.mem.trim(u8, body_raw_line, " \t\r");
            if (std.mem.startsWith(u8, body_line, "[END_MACRO]")) break;
            try markDirectBorrowedMacroParams(allocator, &borrowed_arg_mask, param_names.items, body_line);
            try markDirectAddressSlotMacroParams(allocator, &address_slot_arg_mask, param_names.items, body_line);
            markExpandedImportedMacroParamMasks(tc, &borrowed_arg_mask, &address_slot_arg_mask, param_names.items, body_line);
            markCalleeForwardedParamCaps(allocator, extern_contracts, &callee_borrow_prefix_mask, &callee_consume_ptr_mask, param_names.items, body_line);
            markExpandedImportedMacroForwardedCaps(tc, &callee_borrow_prefix_mask, &callee_consume_ptr_mask, param_names.items, body_line);
            try collectDirectSlaMacroCallees(allocator, &direct_callees, body_line);
            try appendExpandedImportedMacroDirectCallees(tc, &direct_callees, body_line);
        }

        const owned_import_path = if (import_path) |path| try allocator.dupe(u8, path) else null;
        const owned_callees = try direct_callees.toOwnedSlice();
        // Cache line: name|arity|leading|borrow|address|callee_borrow|callee_consume|callee1,callee2
        var callee_joined = std.ArrayList(u8).init(allocator);
        defer callee_joined.deinit();
        for (owned_callees, 0..) |callee, idx| {
            if (idx != 0) try callee_joined.append(',');
            try callee_joined.appendSlice(callee);
        }
        const record = try std.fmt.allocPrint(allocator, "{s}|{d}|{d}|{d}|{d}|{d}|{d}|{s}", .{ name, arity, leading_outputs, borrowed_arg_mask, address_slot_arg_mask, callee_borrow_prefix_mask, callee_consume_ptr_mask, callee_joined.items });
        try cache_records.append(record);
        try tc.registerImportedMacro(name, arity, leading_outputs, owned_import_path, borrowed_arg_mask, address_slot_arg_mask, callee_borrow_prefix_mask, callee_consume_ptr_mask, owned_callees);
    }
    if (import_path) |path| {
        const cache_path = macroIndexCachePath(allocator, path, expanded_source) catch null;
        if (cache_path) |cp| {
            defer allocator.free(cp);
            storeImportedMacrosCache(cp, cache_records.items);
        }
    }
}

pub fn loadImportedMacros(tc: *type_checker_mod.TypeChecker, allocator: std.mem.Allocator, source: []const u8, import_path: ?[]const u8) !void {
    const expanded_source = try source_expand.expand(allocator, source);
    try loadImportedMacrosFromExpandedSource(tc, allocator, expanded_source, import_path);
}
