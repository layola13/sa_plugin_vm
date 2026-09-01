const std = @import("std");

pub const Param = struct {
    name: []const u8,
    ty: []const u8,
    is_borrow: bool,
    is_move: bool,
};

pub const ExternalFunction = struct {
    name: []const u8,
    params: []const Param,
    ret_ty: []const u8,
    return_fallible: bool = false,
};

pub const LayoutDefine = struct {
    name: []const u8,
    val_str: []const u8,
    val_int: i64,
};

pub const ContractParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ContractParser {
        return .{ .allocator = allocator };
    }

    pub fn parseSai(self: *ContractParser, content: []const u8) ![]const ExternalFunction {
        var functions = std.ArrayList(ExternalFunction).init(self.allocator);
        errdefer {
            for (functions.items) |f| {
                self.allocator.free(f.params);
            }
            functions.deinit();
        }

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;

            if (std.mem.startsWith(u8, line, "@extern")) {
                const func = try self.parseExternLine(line);
                try functions.append(func);
            }
        }

        return try functions.toOwnedSlice();
    }

    fn parseExternLine(self: *ContractParser, line: []const u8) !ExternalFunction {
        // line is like: @extern sa_node_plugin_os_cpus(&out_ptr: ptr, &out_len: ptr) -> u32
        var index: usize = "@extern".len;
        while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
        const name_start = index;
        while (index < line.len and line[index] != '(' and line[index] != ' ' and line[index] != '\t') : (index += 1) {}
        const name = line[name_start..index];

        while (index < line.len and line[index] != '(') : (index += 1) {}
        if (index >= line.len) return error.SaiParseError;
        index += 1; // skip '('

        const params_start = index;
        var paren_count: usize = 1;
        while (index < line.len) : (index += 1) {
            if (line[index] == '(') {
                paren_count += 1;
            } else if (line[index] == ')') {
                paren_count -= 1;
                if (paren_count == 0) break;
            }
        }
        if (index >= line.len) return error.SaiParseError;
        const params_str = line[params_start..index];
        index += 1; // skip ')'

        // Parse return type if there is a '->'
        while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
        var ret_ty: []const u8 = "void";
        var return_fallible = false;
        if (index + 2 <= line.len and std.mem.eql(u8, line[index .. index + 2], "->")) {
            index += 2;
            while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
            ret_ty = std.mem.trim(u8, line[index..], " \t");
            if (ret_ty.len > 0 and ret_ty[ret_ty.len - 1] == '!') {
                return_fallible = true;
                ret_ty = std.mem.trimRight(u8, ret_ty[0 .. ret_ty.len - 1], " \t");
            }
        }

        // Parse parameters list
        var params = std.ArrayList(Param).init(self.allocator);
        errdefer params.deinit();

        var param_split = std.mem.splitScalar(u8, params_str, ',');
        while (param_split.next()) |p_raw| {
            const p_trim = std.mem.trim(u8, p_raw, " \t");
            if (p_trim.len == 0) continue;

            // p_trim is like: &out_ptr: ptr
            var colon_split = std.mem.splitScalar(u8, p_trim, ':');
            const p_name_raw = std.mem.trim(u8, colon_split.next() orelse return error.SaiParseError, " \t");
            const p_ty = std.mem.trim(u8, colon_split.next() orelse return error.SaiParseError, " \t");

            var is_borrow = false;
            var is_move = false;
            var p_name = p_name_raw;

            if (std.mem.startsWith(u8, p_name, "&")) {
                is_borrow = true;
                p_name = p_name[1..];
            } else if (std.mem.startsWith(u8, p_name, "^")) {
                is_move = true;
                p_name = p_name[1..];
            }

            try params.append(.{
                .name = p_name,
                .ty = p_ty,
                .is_borrow = is_borrow,
                .is_move = is_move,
            });
        }

        return ExternalFunction{
            .name = name,
            .params = try params.toOwnedSlice(),
            .ret_ty = ret_ty,
            .return_fallible = return_fallible,
        };
    }

    pub fn parseSal(self: *ContractParser, content: []const u8) ![]const LayoutDefine {
        var defines = std.ArrayList(LayoutDefine).init(self.allocator);
        errdefer defines.deinit();

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;

            if (std.mem.startsWith(u8, line, "#def")) {
                const def = try self.parseDefLine(line);
                try defines.append(def);
            }
        }

        return try defines.toOwnedSlice();
    }

    fn parseDefLine(self: *ContractParser, line: []const u8) !LayoutDefine {
        // line is like: #def RcBox_SIZE = 24
        // or #def RcBox_strong = +0
        _ = self;
        var index: usize = "#def".len;
        while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
        const name_start = index;
        while (index < line.len and line[index] != ' ' and line[index] != '\t' and line[index] != '=') : (index += 1) {}
        const name = line[name_start..index];

        while (index < line.len and line[index] != '=') : (index += 1) {}
        if (index >= line.len) return error.SalParseError;
        index += 1; // skip '='

        const val_str = std.mem.trim(u8, line[index..], " \t");

        // Parse value as integer (ignoring '+' prefix)
        var parse_target = val_str;
        if (std.mem.startsWith(u8, parse_target, "+")) {
            parse_target = parse_target[1..];
        }

        const val_int = std.fmt.parseInt(i64, parse_target, 10) catch 0;

        return LayoutDefine{
            .name = name,
            .val_str = val_str,
            .val_int = val_int,
        };
    }
};

test "parse .sai and .sal" {
    const sai_content =
        \\// Test interface
        \\@extern sa_node_plugin_os_cpus(&out_ptr: ptr, &out_len: ptr) -> u32
        \\@extern sa_node_plugin_free_buffer(ptr: ptr, len: u64) -> u32
        \\@extern sa_time_sleep_ns(ns: u64) -> i32!
    ;

    const sal_content =
        \\#def RcBox_SIZE = 24
        \\#def RcBox_strong = +0
        \\#def RcBox_weak = +8
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = ContractParser.init(allocator);

    const functions = try p.parseSai(sai_content);
    try std.testing.expectEqual(@as(usize, 3), functions.len);
    try std.testing.expectEqualSlices(u8, "sa_node_plugin_os_cpus", functions[0].name);
    try std.testing.expectEqual(@as(usize, 2), functions[0].params.len);
    try std.testing.expect(functions[0].params[0].is_borrow);
    try std.testing.expectEqualSlices(u8, "out_ptr", functions[0].params[0].name);
    try std.testing.expectEqualSlices(u8, "ptr", functions[0].params[0].ty);
    try std.testing.expectEqualSlices(u8, "u32", functions[0].ret_ty);
    try std.testing.expect(!functions[0].return_fallible);
    try std.testing.expectEqualSlices(u8, "i32", functions[2].ret_ty);
    try std.testing.expect(functions[2].return_fallible);

    const defines = try p.parseSal(sal_content);
    try std.testing.expectEqual(@as(usize, 3), defines.len);
    try std.testing.expectEqualSlices(u8, "RcBox_SIZE", defines[0].name);
    try std.testing.expectEqual(@as(i64, 24), defines[0].val_int);
    try std.testing.expectEqualSlices(u8, "RcBox_strong", defines[1].name);
    try std.testing.expectEqual(@as(i64, 0), defines[1].val_int);
}
