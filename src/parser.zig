const std = @import("std");

pub const PrimType = enum {
    void,
    i1,
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,
    i64,
    u64,
    f32,
    f64,
    ptr,
};

pub fn parseType(name: []const u8) PrimType {
    if (std.mem.eql(u8, name, "void")) return .void;
    if (std.mem.eql(u8, name, "i1")) return .i1;
    if (std.mem.eql(u8, name, "i8")) return .i8;
    if (std.mem.eql(u8, name, "u8")) return .u8;
    if (std.mem.eql(u8, name, "i16")) return .i16;
    if (std.mem.eql(u8, name, "u16")) return .u16;
    if (std.mem.eql(u8, name, "i32")) return .i32;
    if (std.mem.eql(u8, name, "u32")) return .u32;
    if (std.mem.eql(u8, name, "i64")) return .i64;
    if (std.mem.eql(u8, name, "u64")) return .u64;
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "f64")) return .f64;
    if (std.mem.indexOf(u8, name, "ptr") != null) return .ptr;
    return .u64;
}

pub const OperandKind = enum {
    register,
    immediate,
    constant_addr,
    stack_addr,
    offset_addr, // e.g. reg+offset
    label,
};

pub const Operand = struct {
    kind: OperandKind,
    name: []const u8,
    imm_val: u64 = 0,
    offset: i32 = 0,
};

pub const OpCode = enum {
    stack_alloc,
    alloc,
    ptr_add,
    add,
    sub,
    mul,
    div,
    rem,
    and_,
    or_,
    xor_,
    sdiv,
    udiv,
    srem,
    urem,
    shl,
    shr,
    gt,
    lt,
    assume_borrow,
    assume_safe,
    call,
    call_indirect,
    load,
    store,
    atomic_load,
    atomic_store,
    cmpxchg,
    atomic_rmw_add,
    eq,
    ne,
    sgt,
    slt,
    sge,
    sle,
    ugt,
    ult,
    uge,
    ule,
    br,
    jmp,
    consume,
    assign,
    raw_cast,
    bitcast,
    sext,
    zext,
    trunc,
    panic,
    panic_msg,
    return_,
    take,
    try_,
};

pub const Instruction = struct {
    op: OpCode,
    dest: ?[]const u8 = null,
    args: []const Operand,
    dest_type: PrimType = .void,
};

pub const BasicBlock = struct {
    label: []const u8,
    start_inst: usize,
    end_inst: usize,
};

pub const Function = struct {
    name: []const u8,
    params: []const []const u8,
    instructions: []const Instruction,
    blocks: []const BasicBlock,
    returns_result: bool = false,
};

pub const ExternSignature = struct {
    arg_types: []const PrimType,
    return_type: PrimType,
    returns_result: bool = false,
};

const ExternDecl = struct {
    name: []const u8,
    signature: ExternSignature,
};

pub const Program = struct {
    constants: std.StringHashMap([]const u8),
    functions: std.StringHashMap(Function),
    externs: std.StringHashMap(ExternSignature),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Program) void {
        var const_it = self.constants.iterator();
        while (const_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.constants.deinit();

        var func_it = self.functions.iterator();
        while (func_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            const func = entry.value_ptr.*;
            for (func.params) |p| self.allocator.free(p);
            self.allocator.free(func.params);
            for (func.instructions) |inst| {
                if (inst.dest) |d| self.allocator.free(d);
                for (inst.args) |arg| {
                    self.allocator.free(arg.name);
                }
                self.allocator.free(inst.args);
            }
            self.allocator.free(func.instructions);
            for (func.blocks) |blk| {
                self.allocator.free(blk.label);
            }
            self.allocator.free(func.blocks);
        }
        self.functions.deinit();

        var extern_it = self.externs.iterator();
        while (extern_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.arg_types);
        }
        self.externs.deinit();
        self.allocator.destroy(self);
    }
};

const Macro = struct {
    name: []const u8,
    params: [][]const u8,
    body: [][]const u8,
};

const TokenCursor = struct {
    tokens: []const []const u8,
    index: usize = 0,

    fn peek(self: *TokenCursor) ?[]const u8 {
        if (self.index >= self.tokens.len) return null;
        return self.tokens[self.index];
    }

    fn next(self: *TokenCursor) ?[]const u8 {
        const tok = self.peek() orelse return null;
        self.index += 1;
        return tok;
    }
};

fn isInlineExprOp(token: []const u8) bool {
    return std.mem.eql(u8, token, "ptr_add") or
        std.mem.eql(u8, token, "add") or
        std.mem.eql(u8, token, "sub") or
        std.mem.eql(u8, token, "mul") or
        std.mem.eql(u8, token, "div") or
        std.mem.eql(u8, token, "rem") or
        std.mem.eql(u8, token, "and") or
        std.mem.eql(u8, token, "or") or
        std.mem.eql(u8, token, "xor") or
        std.mem.eql(u8, token, "sdiv") or
        std.mem.eql(u8, token, "udiv") or
        std.mem.eql(u8, token, "srem") or
        std.mem.eql(u8, token, "urem") or
        std.mem.eql(u8, token, "shl") or
        std.mem.eql(u8, token, "shr") or
        std.mem.eql(u8, token, "gt") or
        std.mem.eql(u8, token, "lt") or
        std.mem.eql(u8, token, "eq") or
        std.mem.eql(u8, token, "ne") or
        std.mem.eql(u8, token, "sgt") or
        std.mem.eql(u8, token, "slt") or
        std.mem.eql(u8, token, "sge") or
        std.mem.eql(u8, token, "sle") or
        std.mem.eql(u8, token, "ugt") or
        std.mem.eql(u8, token, "ult") or
        std.mem.eql(u8, token, "uge") or
        std.mem.eql(u8, token, "ule") or
        std.mem.eql(u8, token, "load") or
        std.mem.eql(u8, token, "atomic_load") or
        std.mem.eql(u8, token, "raw_cast") or
        std.mem.eql(u8, token, "bitcast") or
        std.mem.eql(u8, token, "sext") or
        std.mem.eql(u8, token, "zext") or
        std.mem.eql(u8, token, "trunc") or
        std.mem.eql(u8, token, "take") or
        std.mem.eql(u8, token, "assume_safe") or
        std.mem.eql(u8, token, "assume_borrow");
}

pub const Parser = struct {
    allocator: std.mem.Allocator,
    macros: std.StringHashMap(Macro),
    constants: std.StringHashMap([]const u8),
    def_macros: std.StringHashMap([]const u8),
    macro_counter: usize = 0,
    expansion_counter: u64 = 0,
    expr_counter: u64 = 0,
    main_root_dir: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .allocator = allocator,
            .macros = std.StringHashMap(Macro).init(allocator),
            .constants = std.StringHashMap([]const u8).init(allocator),
            .def_macros = std.StringHashMap([]const u8).init(allocator),
            .macro_counter = 0,
            .expansion_counter = 0,
            .expr_counter = 0,
            .main_root_dir = null,
        };
    }

    pub fn deinit(self: *Parser) void {
        if (self.main_root_dir) |dir| {
            self.allocator.free(dir);
        }
        var mac_it = self.macros.iterator();
        while (mac_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            const mac = entry.value_ptr.*;
            for (mac.params) |p| self.allocator.free(p);
            self.allocator.free(mac.params);
            for (mac.body) |b| self.allocator.free(b);
            self.allocator.free(mac.body);
        }
        self.macros.deinit();

        var const_it = self.constants.iterator();
        while (const_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.constants.deinit();

        var def_it = self.def_macros.iterator();
        while (def_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.def_macros.deinit();
    }

    fn readLines(self: *Parser, file_path: []const u8) ![][]const u8 {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            if (err == error.FileNotFound and self.main_root_dir != null) {
                const resolved = std.fs.path.resolve(self.allocator, &.{ self.main_root_dir.?, file_path }) catch return err;
                defer self.allocator.free(resolved);
                const file_fallback = std.fs.cwd().openFile(resolved, .{}) catch {
                    std.debug.print("Failed to open file: {s}, error: {}\n", .{ file_path, err });
                    return err;
                };
                return try self.readLinesFromFile(file_fallback);
            }
            std.debug.print("Failed to open file: {s}, error: {}\n", .{ file_path, err });
            return err;
        };
        return try self.readLinesFromFile(file);
    }

    fn readLinesFromFile(self: *Parser, file: std.fs.File) ![][]const u8 {
        defer file.close();
        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (lines.items) |l| self.allocator.free(l);
            lines.deinit();
        }

        var it = std.mem.splitAny(u8, content, "\r\n");
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//") or (std.mem.startsWith(u8, trimmed, "#") and !std.mem.startsWith(u8, trimmed, "#def"))) {
                continue;
            }
            const line_copy = try self.allocator.dupe(u8, trimmed);
            try lines.append(line_copy);
        }
        return try lines.toOwnedSlice();
    }

    fn resolveImportPath(self: *Parser, base_dir: []const u8, import_val: []const u8) ![]const u8 {
        if (std.mem.startsWith(u8, import_val, "sa_std/")) {
            const std_root = "/home/vscode/.sa/std/";
            const sub_path = import_val["sa_std/".len..];
            return try std.fs.path.join(self.allocator, &.{ std_root, sub_path });
        }
        const rel_path = try std.fs.path.resolve(self.allocator, &.{ base_dir, import_val });
        const file = std.fs.cwd().openFile(rel_path, .{});
        if (file) |f| {
            f.close();
            return rel_path;
        } else |_| {
            self.allocator.free(rel_path);
            if (self.main_root_dir) |main_root| {
                const root_path = try std.fs.path.resolve(self.allocator, &.{ main_root, import_val });
                const file_root = std.fs.cwd().openFile(root_path, .{});
                if (file_root) |f| {
                    f.close();
                    return root_path;
                } else |_| {
                    self.allocator.free(root_path);
                }
                if (std.mem.startsWith(u8, import_val, "../")) {
                    var trimmed = import_val;
                    while (std.mem.startsWith(u8, trimmed, "../")) {
                        trimmed = trimmed["../".len..];
                    }
                    if (trimmed.len > 0) {
                        const root_trimmed = try std.fs.path.join(self.allocator, &.{ main_root, trimmed });
                        const file_trimmed = std.fs.cwd().openFile(root_trimmed, .{});
                        if (file_trimmed) |f| {
                            f.close();
                            return root_trimmed;
                        } else |_| {
                            self.allocator.free(root_trimmed);
                        }
                    }
                }
            }
            return try std.fs.path.resolve(self.allocator, &.{ base_dir, import_val });
        }
    }

    pub fn preprocess(self: *Parser, main_file: []const u8) ![][]const u8 {
        const canonical_main = try std.fs.path.resolve(self.allocator, &.{main_file});
        defer self.allocator.free(canonical_main);

        const base_dir = std.fs.path.dirname(canonical_main) orelse ".";
        self.main_root_dir = try self.allocator.dupe(u8, base_dir);

        var all_lines = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (all_lines.items) |l| self.allocator.free(l);
            all_lines.deinit();
        }

        try self.preprocessFile(base_dir, main_file, &all_lines);

        // Second pass: substitute #def macros
        var final_lines = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (final_lines.items) |l| self.allocator.free(l);
            final_lines.deinit();
        }
        for (all_lines.items) |line| {
            var replaced: []const u8 = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(replaced);

            var def_it = self.def_macros.iterator();
            while (def_it.next()) |entry| {
                replaced = try self.replaceToken(replaced, entry.key_ptr.*, entry.value_ptr.*);
            }
            try final_lines.append(replaced);
        }

        for (all_lines.items) |l| self.allocator.free(l);
        all_lines.deinit();

        return try final_lines.toOwnedSlice();
    }

    fn collectDefinedNames(self: *Parser, body: [][]const u8, defined_names: *std.StringHashMap(void)) !void {
        _ = self;
        for (body) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "#")) {
                continue;
            }

            if (std.mem.endsWith(u8, trimmed, ":")) {
                const label = trimmed[0 .. trimmed.len - 1];
                if (std.mem.startsWith(u8, label, "L_")) {
                    const label_copy = try defined_names.allocator.dupe(u8, label);
                    try defined_names.put(label_copy, {});
                }
            } else if (std.mem.indexOf(u8, trimmed, "=")) |eq_idx| {
                const lhs = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
                if (std.mem.startsWith(u8, lhs, "_")) {
                    const reg_copy = try defined_names.allocator.dupe(u8, lhs);
                    try defined_names.put(reg_copy, {});
                }
            }
        }
    }

    fn replaceSubstring(self: *Parser, source: []const u8, target: []const u8, replacement: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < source.len) {
            if (i + target.len <= source.len and std.mem.eql(u8, source[i .. i + target.len], target)) {
                try result.appendSlice(replacement);
                i += target.len;
            } else {
                try result.append(source[i]);
                i += 1;
            }
        }
        return try result.toOwnedSlice();
    }

    fn preprocessFile(self: *Parser, base_dir: []const u8, file_path: []const u8, out_lines: *std.ArrayList([]const u8)) !void {
        // std.debug.print("Preprocessing file: {s} (base: {s})\n", .{file_path, base_dir});
        const raw_lines = try self.readLines(file_path);
        defer {
            for (raw_lines) |l| self.allocator.free(l);
            self.allocator.free(raw_lines);
        }

        try self.preprocessLines(base_dir, raw_lines, out_lines);
    }

    /// First-pass scan: register all [MACRO] definitions and #def constants from raw_lines
    /// so that forward references (EXPAND before [MACRO]) work correctly.
    fn prescanMacrosAndDefs(self: *Parser, raw_lines: [][]const u8) anyerror!void {
        var idx: usize = 0;
        while (idx < raw_lines.len) {
            const line = raw_lines[idx];
            if (std.mem.startsWith(u8, line, "[MACRO]")) {
                const parts_str = line["[MACRO]".len..];
                var token_it = std.mem.tokenizeAny(u8, parts_str, " \t,");
                const macro_name_raw = token_it.next() orelse { idx += 1; continue; };
                // Skip if already registered
                if (self.macros.contains(macro_name_raw)) { idx += 1; continue; }
                const macro_name = try self.allocator.dupe(u8, macro_name_raw);
                errdefer self.allocator.free(macro_name);

                var params = std.ArrayList([]const u8).init(self.allocator);
                errdefer { for (params.items) |p| self.allocator.free(p); params.deinit(); }
                while (token_it.next()) |param| {
                    try params.append(try self.allocator.dupe(u8, param));
                }

                var body = std.ArrayList([]const u8).init(self.allocator);
                errdefer { for (body.items) |b| self.allocator.free(b); body.deinit(); }

                idx += 1;
                while (idx < raw_lines.len) {
                    const body_line = raw_lines[idx];
                    if (std.mem.startsWith(u8, body_line, "[END_MACRO]")) break;
                    try body.append(try self.allocator.dupe(u8, body_line));
                    idx += 1;
                }
                const m = Macro{
                    .name = macro_name,
                    .params = try params.toOwnedSlice(),
                    .body = try body.toOwnedSlice(),
                };
                try self.macros.put(macro_name, m);
                idx += 1;
            } else if (std.mem.startsWith(u8, line, "#def")) {
                const eq_idx = std.mem.indexOf(u8, line, "=") orelse { idx += 1; continue; };
                const name_raw = std.mem.trim(u8, line["#def".len..eq_idx], " \t");
                const val_raw = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
                if (!self.def_macros.contains(name_raw)) {
                    try self.def_macros.put(try self.allocator.dupe(u8, name_raw), try self.allocator.dupe(u8, val_raw));
                }
                idx += 1;
            } else {
                idx += 1;
            }
        }
    }

    fn preprocessLines(self: *Parser, base_dir: []const u8, raw_lines: [][]const u8, out_lines: *std.ArrayList([]const u8)) anyerror!void {
        // Pre-scan to collect all macro definitions and #defs before processing EXPANDs
        try self.prescanMacrosAndDefs(raw_lines);
        var idx: usize = 0;
        while (idx < raw_lines.len) {
            const line = raw_lines[idx];

            if (std.mem.startsWith(u8, line, "@import")) {
                const quote_start = std.mem.indexOf(u8, line, "\"") orelse {
                    idx += 1;
                    continue;
                };
                const quote_end = std.mem.lastIndexOf(u8, line, "\"") orelse {
                    idx += 1;
                    continue;
                };
                if (quote_end > quote_start) {
                    const import_val = line[quote_start + 1 .. quote_end];
                    const resolved = try self.resolveImportPath(base_dir, import_val);
                    defer self.allocator.free(resolved);
                    const resolved_dir = std.fs.path.dirname(resolved) orelse ".";
                    try self.preprocessFile(resolved_dir, resolved, out_lines);
                }
                idx += 1;
            } else if (std.mem.startsWith(u8, line, "[MACRO]")) {
                const parts_str = line["[MACRO]".len..];
                var token_it = std.mem.tokenizeAny(u8, parts_str, " \t,");
                const macro_name_raw = token_it.next() orelse return error.InvalidMacroName;
                const macro_name = try self.allocator.dupe(u8, macro_name_raw);
                errdefer self.allocator.free(macro_name);

                var params = std.ArrayList([]const u8).init(self.allocator);
                errdefer {
                    for (params.items) |p| self.allocator.free(p);
                    params.deinit();
                }
                while (token_it.next()) |param| {
                    try params.append(try self.allocator.dupe(u8, param));
                }

                var body = std.ArrayList([]const u8).init(self.allocator);
                errdefer {
                    for (body.items) |b| self.allocator.free(b);
                    body.deinit();
                }

                idx += 1;
                while (idx < raw_lines.len) {
                    const body_line = raw_lines[idx];
                    if (std.mem.startsWith(u8, body_line, "[END_MACRO]")) {
                        break;
                    }
                    try body.append(try self.allocator.dupe(u8, body_line));
                    idx += 1;
                }

                const m = Macro{
                    .name = macro_name,
                    .params = try params.toOwnedSlice(),
                    .body = try body.toOwnedSlice(),
                };
                try self.macros.put(macro_name, m);
                idx += 1;
            } else if (std.mem.startsWith(u8, line, "#def")) {
                const eq_idx = std.mem.indexOf(u8, line, "=") orelse {
                    idx += 1;
                    continue;
                };
                const name_raw = std.mem.trim(u8, line["#def".len..eq_idx], " \t");
                const val_raw = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");

                const name_copy = try self.allocator.dupe(u8, name_raw);
                const val_copy = try self.allocator.dupe(u8, val_raw);
                try self.def_macros.put(name_copy, val_copy);
                idx += 1;
            } else if (std.mem.startsWith(u8, line, "@const") and std.mem.indexOf(u8, line, "=") != null) {
                const eq_idx = std.mem.indexOf(u8, line, "=").?;
                const name_raw = std.mem.trim(u8, line["@const".len..eq_idx], " \t");
                const val_raw = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");

                const decoded = try self.decodeConstValue(val_raw);
                errdefer self.allocator.free(decoded);

                const name_copy = try self.allocator.dupe(u8, name_raw);
                errdefer self.allocator.free(name_copy);

                // Add _len constant for strings
                const name_len = try std.fmt.allocPrint(self.allocator, "{s}_len", .{name_raw});
                const val_len = try std.fmt.allocPrint(self.allocator, "{d}", .{decoded.len});
                try self.def_macros.put(name_len, val_len);

                try self.constants.put(name_copy, decoded);
                idx += 1;
            } else if (std.mem.startsWith(u8, line, "@extern") or std.mem.startsWith(u8, line, "@const")) {
                // If it's @extern or @const without '=', treat it as a potential function name for now (passed to out_lines)
                try out_lines.append(try self.allocator.dupe(u8, line));
                idx += 1;
            } else if (std.mem.startsWith(u8, line, "EXPAND")) {
                const parts_str = line["EXPAND".len..];
                var token_it = std.mem.tokenizeAny(u8, parts_str, " \t,");
                const macro_name = token_it.next() orelse return error.InvalidMacroExpansion;
                
                var args = std.ArrayList([]const u8).init(self.allocator);
                defer {
                    for (args.items) |a| self.allocator.free(a);
                    args.deinit();
                }
                while (token_it.next()) |arg| {
                    try args.append(try self.allocator.dupe(u8, arg));
                }

                if (self.macros.get(macro_name)) |mac| {
                    self.expansion_counter += 1;

                    // 1. Collect defined names in macro body
                    var defined_names = std.StringHashMap(void).init(self.allocator);
                    defer {
                        var name_it = defined_names.iterator();
                        while (name_it.next()) |entry| {
                            self.allocator.free(entry.key_ptr.*);
                        }
                        defined_names.deinit();
                    }
                    try self.collectDefinedNames(mac.body, &defined_names);

                    // 2. Build hygiene replacements list
                    var hygiene_repls = std.ArrayList(struct { needle: []const u8, replacement: []const u8 }).init(self.allocator);
                    defer {
                        for (hygiene_repls.items) |r| {
                            self.allocator.free(r.needle);
                            self.allocator.free(r.replacement);
                        }
                        hygiene_repls.deinit();
                    }

                    var name_it = defined_names.iterator();
                    while (name_it.next()) |entry| {
                        const name = entry.key_ptr.*;
                        const repl = try std.fmt.allocPrint(self.allocator, "{s}__sa_hyg{d}", .{ name, self.expansion_counter });
                        try hygiene_repls.append(.{ .needle = try self.allocator.dupe(u8, name), .replacement = repl });
                    }

                    // 3. Process macro body
                    for (mac.body) |body_line| {
                        var expanded_line: []const u8 = try self.allocator.dupe(u8, body_line);
                        errdefer self.allocator.free(expanded_line);

                        // 3.1 Apply hygiene replacements first
                        for (hygiene_repls.items) |r| {
                            expanded_line = try self.replaceToken(expanded_line, r.needle, r.replacement);
                        }

                        // 3.2 Replace parameters with arguments second
                        for (mac.params, args.items) |param, arg| {
                            const temp = try self.replaceSubstring(expanded_line, param, arg);
                            self.allocator.free(expanded_line);
                            expanded_line = temp;
                        }

                        // Recursively preprocess the line
                        if (std.mem.startsWith(u8, expanded_line, "EXPAND") or std.mem.startsWith(u8, expanded_line, "[REP") or std.mem.startsWith(u8, expanded_line, "@import") or std.mem.startsWith(u8, expanded_line, "#def") or std.mem.startsWith(u8, expanded_line, "@const")) {
                            var single_slice = [_][]const u8{expanded_line};
                            try self.preprocessLines(base_dir, &single_slice, out_lines);
                            self.allocator.free(expanded_line);
                        } else {
                            try out_lines.append(expanded_line);
                        }
                    }
                }
                idx += 1;
            } else if (std.mem.startsWith(u8, line, "[REP")) {
                const space_idx = std.mem.indexOf(u8, line, " ") orelse return error.InvalidRepSyntax;
                const rbracket_idx = std.mem.indexOf(u8, line, "]") orelse return error.InvalidRepSyntax;
                const count_str = std.mem.trim(u8, line[space_idx + 1 .. rbracket_idx], " \t");
                const count = try std.fmt.parseInt(u64, count_str, 10);

                var rep_nesting: usize = 1;
                var body_lines = std.ArrayList([]const u8).init(self.allocator);
                defer {
                    for (body_lines.items) |b| self.allocator.free(b);
                    body_lines.deinit();
                }

                idx += 1;
                while (idx < raw_lines.len) {
                    const body_line = raw_lines[idx];
                    if (std.mem.startsWith(u8, body_line, "[REP")) {
                        rep_nesting += 1;
                    } else if (std.mem.startsWith(u8, body_line, "[END_REP]")) {
                        rep_nesting -= 1;
                        if (rep_nesting == 0) {
                            idx += 1;
                            break;
                        }
                    }
                    try body_lines.append(try self.allocator.dupe(u8, body_line));
                    idx += 1;
                }

                var step: u64 = 0;
                while (step < count) : (step += 1) {
                    self.expansion_counter += 1;

                    var defined_names = std.StringHashMap(void).init(self.allocator);
                    defer {
                        var name_it = defined_names.iterator();
                        while (name_it.next()) |entry| {
                            self.allocator.free(entry.key_ptr.*);
                        }
                        defined_names.deinit();
                    }
                    try self.collectDefinedNames(body_lines.items, &defined_names);

                    var hygiene_repls = std.ArrayList(struct { needle: []const u8, replacement: []const u8 }).init(self.allocator);
                    defer {
                        for (hygiene_repls.items) |r| {
                            self.allocator.free(r.needle);
                            self.allocator.free(r.replacement);
                        }
                        hygiene_repls.deinit();
                    }

                    var name_it = defined_names.iterator();
                    while (name_it.next()) |entry| {
                        const name = entry.key_ptr.*;
                        const repl = try std.fmt.allocPrint(self.allocator, "{s}__sa_hyg{d}", .{ name, self.expansion_counter });
                        try hygiene_repls.append(.{ .needle = try self.allocator.dupe(u8, name), .replacement = repl });
                    }

                    for (body_lines.items) |body_line| {
                        var expanded_line: []const u8 = try self.allocator.dupe(u8, body_line);
                        errdefer self.allocator.free(expanded_line);

                        // 1. Apply hygiene replacements
                        for (hygiene_repls.items) |r| {
                            expanded_line = try self.replaceToken(expanded_line, r.needle, r.replacement);
                        }

                        // 2. Replace %i with current step index
                        var index_buf: [32]u8 = undefined;
                        const index_str = try std.fmt.bufPrint(&index_buf, "{d}", .{step});
                        
                        const temp_line = try self.replaceSubstring(expanded_line, "%i", index_str);
                        self.allocator.free(expanded_line);
                        expanded_line = temp_line;

                        // Recursively preprocess the line
                        if (std.mem.startsWith(u8, expanded_line, "EXPAND") or std.mem.startsWith(u8, expanded_line, "[REP") or std.mem.startsWith(u8, expanded_line, "@import") or std.mem.startsWith(u8, expanded_line, "#def") or std.mem.startsWith(u8, expanded_line, "@const")) {
                            var single_slice = [_][]const u8{expanded_line};
                            try self.preprocessLines(base_dir, &single_slice, out_lines);
                            self.allocator.free(expanded_line);
                        } else {
                            try out_lines.append(expanded_line);
                        }
                    }
                }
            } else if (std.mem.startsWith(u8, line, "@extern")) {
                idx += 1;
            } else {
                try out_lines.append(try self.allocator.dupe(u8, line));
                idx += 1;
            }
        }
    }

    fn replaceToken(self: *Parser, source: []const u8, target: []const u8, replacement: []const u8) ![]const u8 {
        defer self.allocator.free(source);
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < source.len) {
            if (i + target.len <= source.len and std.mem.eql(u8, source[i .. i + target.len], target)) {
                // Verify boundary to prevent partial replacements
                const before_ok = (i == 0 or !std.ascii.isAlphanumeric(source[i - 1]) and source[i - 1] != '_');
                const after_ok = (i + target.len == source.len or !std.ascii.isAlphanumeric(source[i + target.len]) and source[i + target.len] != '_');
                if (before_ok and after_ok) {
                    try result.appendSlice(replacement);
                    i += target.len;
                    continue;
                }
            }
            try result.append(source[i]);
            i += 1;
        }
        return try result.toOwnedSlice();
    }

    fn decodeConstValue(self: *Parser, raw: []const u8) ![]const u8 {
        if (std.mem.startsWith(u8, raw, "utf8:\"")) {
            const quote_end = std.mem.lastIndexOf(u8, raw, "\"") orelse return error.InvalidStringLiteral;
            const content = raw["utf8:\"".len..quote_end];
            
            var result = std.ArrayList(u8).init(self.allocator);
            errdefer result.deinit();

            var i: usize = 0;
            while (i < content.len) {
                if (content[i] == '\\' and i + 1 < content.len) {
                    switch (content[i + 1]) {
                        'n' => { try result.append('\n'); i += 2; },
                        't' => { try result.append('\t'); i += 2; },
                        'r' => { try result.append('\r'); i += 2; },
                        '0' => { try result.append(0); i += 2; },
                        '\\' => { try result.append('\\'); i += 2; },
                        '"' => { try result.append('"'); i += 2; },
                        'x' => {
                            if (i + 3 < content.len) {
                                const hex = content[i + 2 .. i + 4];
                                const val = try std.fmt.parseInt(u8, hex, 16);
                                try result.append(val);
                                i += 4;
                            } else {
                                try result.append(content[i]);
                                i += 1;
                            }
                        },
                        else => {
                            try result.append(content[i]);
                            i += 1;
                        }
                    }
                } else {
                    try result.append(content[i]);
                    i += 1;
                }
            }
            return try result.toOwnedSlice();
        }

        if (std.mem.startsWith(u8, raw, "hex:")) {
            const content = raw["hex:".len..];
            var result = std.ArrayList(u8).init(self.allocator);
            errdefer result.deinit();

            var i: usize = 0;
            while (i < content.len) {
                if (content[i] == '\\' and i + 1 < content.len and content[i + 1] == 'x') {
                    if (i + 3 < content.len) {
                        const hex = content[i + 2 .. i + 4];
                        const val = try std.fmt.parseInt(u8, hex, 16);
                        try result.append(val);
                        i += 4;
                    } else {
                        try result.append(content[i]);
                        i += 1;
                    }
                } else {
                    try result.append(content[i]);
                    i += 1;
                }
            }
            return try result.toOwnedSlice();
        }

        // Handle struct literal: struct { fieldname: SIZE = hex:\xNN\xNN..., ... }
        // Decode by extracting all hex:\xNN... segments in order.
        if (std.mem.startsWith(u8, raw, "struct")) {
            var result = std.ArrayList(u8).init(self.allocator);
            errdefer result.deinit();

            var search = raw;
            while (std.mem.indexOf(u8, search, "hex:")) |hex_pos| {
                search = search[hex_pos + "hex:".len..];
                // Parse \xNN sequences until non-hex-escape
                var i: usize = 0;
                while (i + 1 < search.len and search[i] == '\\' and search[i + 1] == 'x') {
                    if (i + 4 <= search.len) {
                        const hex = search[i + 2 .. i + 4];
                        const val = std.fmt.parseInt(u8, hex, 16) catch break;
                        try result.append(val);
                        i += 4;
                    } else break;
                }
                search = search[i..];
            }
            return try result.toOwnedSlice();
        }

        return try self.allocator.dupe(u8, raw);
    }

    fn parseSignatureType(raw: []const u8) PrimType {
        var ty = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.endsWith(u8, ty, "!")) ty = std.mem.trim(u8, ty[0 .. ty.len - 1], " \t");
        while (ty.len > 0 and (ty[0] == '&' or ty[0] == '^' or ty[0] == '*')) {
            ty = std.mem.trim(u8, ty[1..], " \t");
        }
        return parseType(ty);
    }

    fn parseExternDecl(self: *Parser, line: []const u8) !ExternDecl {
        const body = std.mem.trim(u8, line["@extern".len..], " \t");
        const paren_start = std.mem.indexOf(u8, body, "(") orelse return error.InvalidExternSignature;
        const paren_end = std.mem.lastIndexOf(u8, body, ")") orelse return error.InvalidExternSignature;
        if (paren_end < paren_start) return error.InvalidExternSignature;

        const name_raw = std.mem.trim(u8, body[0..paren_start], " \t");
        if (name_raw.len == 0) return error.InvalidExternSignature;

        var arg_types = std.ArrayList(PrimType).init(self.allocator);
        errdefer arg_types.deinit();

        const params_str = body[paren_start + 1 .. paren_end];
        var param_it = std.mem.tokenizeAny(u8, params_str, ",");
        while (param_it.next()) |param| {
            const cleaned_param = std.mem.trim(u8, param, " \t");
            if (cleaned_param.len == 0) continue;
            const type_raw = if (std.mem.indexOf(u8, cleaned_param, ":")) |colon_idx|
                cleaned_param[colon_idx + 1 ..]
            else
                cleaned_param;
            try arg_types.append(parseSignatureType(type_raw));
        }

        var return_type = PrimType.void;
        var returns_result = false;
        if (std.mem.indexOf(u8, body[paren_end + 1 ..], "->")) |arrow_rel| {
            const return_raw = std.mem.trim(u8, body[paren_end + 1 + arrow_rel + "->".len ..], " \t");
            returns_result = std.mem.endsWith(u8, return_raw, "!");
            return_type = parseSignatureType(return_raw);
        }

        return .{
            .name = try self.allocator.dupe(u8, name_raw),
            .signature = .{
                .arg_types = try arg_types.toOwnedSlice(),
                .return_type = return_type,
                .returns_result = returns_result,
            },
        };
    }

    fn tokenizeExprTokens(self: *Parser, raw: []const u8) ![][]const u8 {
        var tokens = std.ArrayList([]const u8).init(self.allocator);
        errdefer tokens.deinit();

        var it = std.mem.tokenizeAny(u8, raw, " \t,");
        while (it.next()) |tok| {
            try tokens.append(tok);
        }
        return try tokens.toOwnedSlice();
    }

    fn makeTempName(self: *Parser) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "__sa_expr{d}", .{self.expr_counter});
        self.expr_counter += 1;
        return name;
    }

    fn appendInstruction(self: *Parser, out: *std.ArrayList(Instruction), op: OpCode, dest: ?[]const u8, args: []const Operand, dest_type: PrimType) !void {
        const args_copy = try self.allocator.dupe(Operand, args);
        errdefer self.allocator.free(args_copy);
        try out.append(.{
            .op = op,
            .dest = dest,
            .args = args_copy,
            .dest_type = dest_type,
        });
    }

    fn emitTempInstruction(self: *Parser, out: *std.ArrayList(Instruction), op: OpCode, args: []const Operand, dest_type: PrimType) !Operand {
        const dest_name = try self.makeTempName();
        errdefer self.allocator.free(dest_name);
        try self.appendInstruction(out, op, dest_name, args, dest_type);
        return Operand{ .kind = .register, .name = try self.allocator.dupe(u8, dest_name) };
    }

    fn parseExprOperand(self: *Parser, cursor: *TokenCursor, out: *std.ArrayList(Instruction)) !Operand {
        const tok = cursor.next() orelse return error.EmptyOperand;

        if (std.mem.eql(u8, tok, "load") or std.mem.eql(u8, tok, "atomic_load")) {
            const addr = try self.parseExprOperand(cursor, out);
            const as_tok = cursor.next() orelse return error.MissingLoadAs;
            if (!std.mem.eql(u8, as_tok, "as")) return error.MissingLoadAs;
            const type_str = cursor.next() orelse return error.MissingLoadType;
            const op = if (std.mem.eql(u8, tok, "atomic_load")) OpCode.atomic_load else OpCode.load;
            return try self.emitTempInstruction(out, op, &.{ addr }, parseType(type_str));
        }

        if (std.mem.eql(u8, tok, "raw_cast") or std.mem.eql(u8, tok, "bitcast") or std.mem.eql(u8, tok, "sext") or std.mem.eql(u8, tok, "zext") or std.mem.eql(u8, tok, "trunc")) {
            const arg = try self.parseExprOperand(cursor, out);
            const as_tok = cursor.next() orelse return error.MissingCastAs;
            if (!std.mem.eql(u8, as_tok, "as")) return error.MissingCastAs;
            const type_str = cursor.next() orelse return error.MissingCastType;
            const op = if (std.mem.eql(u8, tok, "bitcast")) OpCode.bitcast else if (std.mem.eql(u8, tok, "sext")) OpCode.sext else if (std.mem.eql(u8, tok, "zext")) OpCode.zext else if (std.mem.eql(u8, tok, "trunc")) OpCode.trunc else OpCode.raw_cast;
            return try self.emitTempInstruction(out, op, &.{ arg }, parseType(type_str));
        }

        if (std.mem.eql(u8, tok, "take")) {
            const arg = try self.parseExprOperand(cursor, out);
            return try self.emitTempInstruction(out, .take, &.{ arg }, .void);
        }

        if (std.mem.eql(u8, tok, "assume_safe")) {
            const arg = try self.parseExprOperand(cursor, out);
            return try self.emitTempInstruction(out, .assume_safe, &.{ arg }, .void);
        }

        if (std.mem.eql(u8, tok, "assume_borrow")) {
            const arg = try self.parseExprOperand(cursor, out);
            return try self.emitTempInstruction(out, .assume_borrow, &.{ arg }, .void);
        }

        if (std.mem.eql(u8, tok, "stack_alloc") or std.mem.eql(u8, tok, "alloc")) {
            const size = try self.parseExprOperand(cursor, out);
            const op = if (std.mem.eql(u8, tok, "stack_alloc")) OpCode.stack_alloc else OpCode.alloc;
            return try self.emitTempInstruction(out, op, &.{ size }, .void);
        }

        if (isInlineExprOp(tok)) {
            const left = try self.parseExprOperand(cursor, out);
            const right = try self.parseExprOperand(cursor, out);
            const op = if (std.mem.eql(u8, tok, "ptr_add")) OpCode.ptr_add else if (std.mem.eql(u8, tok, "add")) OpCode.add else if (std.mem.eql(u8, tok, "sub")) OpCode.sub else if (std.mem.eql(u8, tok, "mul")) OpCode.mul else if (std.mem.eql(u8, tok, "div")) OpCode.div else if (std.mem.eql(u8, tok, "rem")) OpCode.rem else if (std.mem.eql(u8, tok, "and")) OpCode.and_ else if (std.mem.eql(u8, tok, "or")) OpCode.or_ else if (std.mem.eql(u8, tok, "xor")) OpCode.xor_ else if (std.mem.eql(u8, tok, "sdiv")) OpCode.sdiv else if (std.mem.eql(u8, tok, "udiv")) OpCode.udiv else if (std.mem.eql(u8, tok, "srem")) OpCode.srem else if (std.mem.eql(u8, tok, "urem")) OpCode.urem else if (std.mem.eql(u8, tok, "shl")) OpCode.shl else if (std.mem.eql(u8, tok, "shr")) OpCode.shr else if (std.mem.eql(u8, tok, "gt")) OpCode.gt else if (std.mem.eql(u8, tok, "lt")) OpCode.lt else if (std.mem.eql(u8, tok, "sgt")) OpCode.sgt else if (std.mem.eql(u8, tok, "slt")) OpCode.slt else if (std.mem.eql(u8, tok, "sge")) OpCode.sge else if (std.mem.eql(u8, tok, "sle")) OpCode.sle else if (std.mem.eql(u8, tok, "ugt")) OpCode.ugt else if (std.mem.eql(u8, tok, "ult")) OpCode.ult else if (std.mem.eql(u8, tok, "uge")) OpCode.uge else if (std.mem.eql(u8, tok, "ule")) OpCode.ule else if (std.mem.eql(u8, tok, "eq")) OpCode.eq else OpCode.ne;
            return try self.emitTempInstruction(out, op, &.{ left, right }, .void);
        }

        return try self.parseOperand(tok);
    }

    pub fn parse(self: *Parser, preprocessed: [][]const u8) !*Program {
        const prog = try self.allocator.create(Program);
        errdefer self.allocator.destroy(prog);

        prog.* = .{
            .constants = std.StringHashMap([]const u8).init(self.allocator),
            .functions = std.StringHashMap(Function).init(self.allocator),
            .externs = std.StringHashMap(ExternSignature).init(self.allocator),
            .allocator = self.allocator,
        };

        // Copy constants from parser
        var const_it = self.constants.iterator();
        while (const_it.next()) |entry| {
            try prog.constants.put(try self.allocator.dupe(u8, entry.key_ptr.*), try self.allocator.dupe(u8, entry.value_ptr.*));
        }

        var current_func_name: ?[]const u8 = null;
        var current_func_params: []const []const u8 = &.{};
        var current_instructions = std.ArrayList(Instruction).init(self.allocator);
        var current_blocks = std.ArrayList(BasicBlock).init(self.allocator);
        var current_func_returns_result = false;

        var idx: usize = 0;
        while (idx < preprocessed.len) {
            const line = std.mem.trim(u8, preprocessed[idx], " \t\r");
            if (line.len == 0) {
                idx += 1;
                continue;
            }
            // std.debug.print("Parsing line {d}: '{s}'\n", .{idx, line});

            if (std.mem.startsWith(u8, line, "@extern")) {
                const decl = try self.parseExternDecl(line);
                if (prog.externs.getPtr(decl.name)) |existing| {
                    self.allocator.free(existing.arg_types);
                    existing.* = decl.signature;
                    self.allocator.free(decl.name);
                } else {
                    try prog.externs.put(decl.name, decl.signature);
                }
                idx += 1;
            } else if (std.mem.startsWith(u8, line, "@") and std.mem.indexOf(u8, line, "(") != null and std.mem.indexOf(u8, line, ")") != null and std.mem.endsWith(u8, line, ":")) {
                if (current_func_name) |func_name| {
                    const func = Function{
                        .name = func_name,
                        .params = current_func_params,
                        .instructions = try current_instructions.toOwnedSlice(),
                        .blocks = try current_blocks.toOwnedSlice(),
                        .returns_result = current_func_returns_result,
                    };
                    try prog.functions.put(func_name, func);
                }

                const paren_start = std.mem.indexOf(u8, line, "(").?;
                const paren_end = std.mem.lastIndexOf(u8, line, ")").?;
                current_func_returns_result = if (std.mem.indexOf(u8, line[paren_end..], "!")) |_| true else false;
                const name = std.mem.trim(u8, line[1..paren_start], " \t");

                var params_list = std.ArrayList([]const u8).init(self.allocator);
                errdefer {
                    for (params_list.items) |p| self.allocator.free(p);
                    params_list.deinit();
                }

                const params_str = line[paren_start + 1 .. paren_end];
                var param_it = std.mem.tokenizeAny(u8, params_str, ",");
                while (param_it.next()) |param| {
                    const cleaned_param = std.mem.trim(u8, param, " \t");
                    if (cleaned_param.len == 0) continue;
                    const colon_idx = std.mem.indexOf(u8, cleaned_param, ":") orelse cleaned_param.len;
                    var param_name = std.mem.trim(u8, cleaned_param[0..colon_idx], " \t");
                    while (std.mem.startsWith(u8, param_name, "&") or std.mem.startsWith(u8, param_name, "^") or std.mem.startsWith(u8, param_name, "*")) {
                        param_name = param_name[1..];
                    }
                    try params_list.append(try self.allocator.dupe(u8, param_name));
                }

                var real_name = name;
                while (true) {
                    if (std.mem.startsWith(u8, real_name, "export ")) {
                        real_name = std.mem.trim(u8, real_name["export ".len..], " \t");
                    } else if (std.mem.startsWith(u8, real_name, "extern ")) {
                        real_name = std.mem.trim(u8, real_name["extern ".len..], " \t");
                    } else if (std.mem.startsWith(u8, real_name, "ffi_wrapper ")) {
                        real_name = std.mem.trim(u8, real_name["ffi_wrapper ".len..], " \t");
                    } else if (std.mem.startsWith(u8, real_name, "pub ")) {
                        real_name = std.mem.trim(u8, real_name["pub ".len..], " \t");
                    } else break;
                }
                // std.debug.print("Parsed function name: '{s}' (from '{s}')\n", .{real_name, name});
                current_func_name = try self.allocator.dupe(u8, real_name);
                current_func_params = try params_list.toOwnedSlice();
                current_instructions = std.ArrayList(Instruction).init(self.allocator);
                current_blocks = std.ArrayList(BasicBlock).init(self.allocator);
                idx += 1;
            } else if (std.mem.endsWith(u8, line, ":")) {
                // Basic block label, e.g. L_ENTRY:
                const label = line[0 .. line.len - 1];
                const block = BasicBlock{
                    .label = try self.allocator.dupe(u8, label),
                    .start_inst = current_instructions.items.len,
                    .end_inst = 0, // Fill later
                };
                if (current_blocks.items.len > 0) {
                    current_blocks.items[current_blocks.items.len - 1].end_inst = current_instructions.items.len;
                }
                try current_blocks.append(block);
                idx += 1;
            } else {
                // Instruction line
                if (current_func_name != null) {
                    if (try self.tryAddInlineUtf8Constant(line, &prog.constants)) {
                        idx += 1;
                        continue;
                    }
                    self.parseInstruction(line, &current_instructions) catch |err| {
                        std.debug.print("Failed to parse instruction at line {d}: '{s}', error: {}\n", .{ idx + 1, line, err });
                        return err;
                    };
                }
                idx += 1;
            }
        }

        if (current_func_name) |func_name| {
            if (current_blocks.items.len > 0) {
                current_blocks.items[current_blocks.items.len - 1].end_inst = current_instructions.items.len;
            }
            const func = Function{
                .name = func_name,
                .params = current_func_params,
                .instructions = try current_instructions.toOwnedSlice(),
                .blocks = try current_blocks.toOwnedSlice(),
                .returns_result = current_func_returns_result,
            };
            try prog.functions.put(func_name, func);
        }

        return prog;
    }

    fn tryAddInlineUtf8Constant(self: *Parser, line: []const u8, constants: *std.StringHashMap([]const u8)) !bool {
        const eq_idx = std.mem.indexOf(u8, line, "=") orelse return false;
        const name = std.mem.trim(u8, line[0..eq_idx], " \t");
        const value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
        if (name.len == 0 or !std.mem.startsWith(u8, value, "utf8:\"")) return false;
        if (constants.contains(name)) return error.DuplicateConstant;

        const decoded = try self.decodeConstValue(value);
        errdefer self.allocator.free(decoded);
        try constants.put(try self.allocator.dupe(u8, name), decoded);

        // Keep parser-level constant lookup in sync so later &name operands are
        // classified as constant addresses instead of stack addresses.
        try self.constants.put(try self.allocator.dupe(u8, name), try self.allocator.dupe(u8, decoded));
        return true;
    }

    fn parseInstruction(self: *Parser, line: []const u8, out: *std.ArrayList(Instruction)) !void {
        var op = OpCode.consume;
        var dest: ?[]const u8 = null;
        var dest_type = PrimType.void;
        var args_raw: []const u8 = line;

        if (std.mem.startsWith(u8, line, "!") or std.mem.startsWith(u8, line, "^")) {
            op = .consume;
            const reg = std.mem.trim(u8, line[1..], " \t");
            if (reg.len == 0) return error.EmptyRegisterInConsume;
            var args = try self.allocator.alloc(Operand, 1);
            args[0] = Operand{ .kind = .register, .name = try self.allocator.dupe(u8, reg) };
            try out.append(.{ .op = op, .args = args });
            return;
        }

        // Check for assignment: reg = op args...
        if (std.mem.indexOf(u8, line, "=")) |eq_idx| {
            const dest_part = std.mem.trim(u8, line[0..eq_idx], " \t");
            dest = try self.allocator.dupe(u8, dest_part);
            args_raw = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
        }

        var token_it = std.mem.tokenizeAny(u8, args_raw, " \t");
        const first_token = token_it.next() orelse return error.EmptyInstruction;

        var args_list = std.ArrayList(Operand).init(self.allocator);
        errdefer {
            for (args_list.items) |a| self.allocator.free(a.name);
            args_list.deinit();
        }

        if (isInlineExprOp(first_token) or std.mem.eql(u8, first_token, "stack_alloc") or std.mem.eql(u8, first_token, "alloc") or std.mem.eql(u8, first_token, "store") or std.mem.eql(u8, first_token, "atomic_store") or std.mem.eql(u8, first_token, "cmpxchg") or std.mem.eql(u8, first_token, "atomic_rmw_add") or std.mem.eql(u8, first_token, "raw_cast") or std.mem.eql(u8, first_token, "bitcast") or std.mem.eql(u8, first_token, "sext") or std.mem.eql(u8, first_token, "zext") or std.mem.eql(u8, first_token, "trunc") or std.mem.eql(u8, first_token, "take") or std.mem.eql(u8, first_token, "assume_safe") or std.mem.eql(u8, first_token, "assume_borrow")) {
            const expr_tokens = try self.tokenizeExprTokens(args_raw);
            defer self.allocator.free(expr_tokens);
            var cursor = TokenCursor{ .tokens = expr_tokens };
            _ = cursor.next() orelse return error.EmptyInstruction;

            if (std.mem.eql(u8, first_token, "stack_alloc") or std.mem.eql(u8, first_token, "alloc")) {
                op = if (std.mem.eql(u8, first_token, "stack_alloc")) .stack_alloc else .alloc;
                try args_list.append(try self.parseExprOperand(&cursor, out));
            } else if (std.mem.eql(u8, first_token, "load") or std.mem.eql(u8, first_token, "atomic_load")) {
                op = if (std.mem.eql(u8, first_token, "atomic_load")) .atomic_load else .load;
                try args_list.append(try self.parseExprOperand(&cursor, out));
                const as_token = cursor.next() orelse return error.MissingLoadAs;
                if (!std.mem.eql(u8, as_token, "as")) return error.MissingLoadAs;
                const type_str = cursor.next() orelse return error.MissingLoadType;
                dest_type = parseType(type_str);
            } else if (std.mem.eql(u8, first_token, "store")) {
                op = .store;
                if (std.mem.indexOf(u8, args_raw, "into") != null) {
                    try args_list.append(try self.parseExprOperand(&cursor, out));
                    const into_token = cursor.next() orelse return error.MissingStoreInto;
                    if (!std.mem.eql(u8, into_token, "into")) return error.MissingStoreInto;
                    try args_list.append(try self.parseExprOperand(&cursor, out));
                } else {
                    const ptr = try self.parseExprOperand(&cursor, out);
                    try args_list.append(try self.parseExprOperand(&cursor, out));
                    const as_token = cursor.next() orelse return error.InvalidStoreSyntax;
                    if (!std.mem.eql(u8, as_token, "as")) return error.InvalidStoreSyntax;
                    const type_str = cursor.next() orelse return error.InvalidStoreSyntax;
                    dest_type = parseType(type_str);
                    try args_list.append(ptr);
                }
            } else if (std.mem.eql(u8, first_token, "atomic_store")) {
                op = .atomic_store;
                try args_list.append(try self.parseExprOperand(&cursor, out));
                try args_list.append(try self.parseExprOperand(&cursor, out));
                const as_token = cursor.next() orelse return error.InvalidStoreSyntax;
                if (!std.mem.eql(u8, as_token, "as")) return error.InvalidStoreSyntax;
                const type_str = cursor.next() orelse return error.InvalidStoreSyntax;
                dest_type = parseType(type_str);
            } else if (std.mem.eql(u8, first_token, "cmpxchg")) {
                op = .cmpxchg;
                try args_list.append(try self.parseExprOperand(&cursor, out));
                try args_list.append(try self.parseExprOperand(&cursor, out));
                try args_list.append(try self.parseExprOperand(&cursor, out));
                const as_token = cursor.next() orelse return error.InvalidCmpxchgSyntax;
                if (!std.mem.eql(u8, as_token, "as")) return error.InvalidCmpxchgSyntax;
                const type_str = cursor.next() orelse return error.InvalidCmpxchgSyntax;
                dest_type = parseType(type_str);
            } else if (std.mem.eql(u8, first_token, "atomic_rmw_add")) {
                op = .atomic_rmw_add;
                try args_list.append(try self.parseExprOperand(&cursor, out));
                try args_list.append(try self.parseExprOperand(&cursor, out));
                const as_token = cursor.next() orelse return error.InvalidAtomicRmwSyntax;
                if (!std.mem.eql(u8, as_token, "as")) return error.InvalidAtomicRmwSyntax;
                const type_str = cursor.next() orelse return error.InvalidAtomicRmwSyntax;
                dest_type = parseType(type_str);
            } else if (std.mem.eql(u8, first_token, "raw_cast") or std.mem.eql(u8, first_token, "bitcast") or std.mem.eql(u8, first_token, "sext") or std.mem.eql(u8, first_token, "zext") or std.mem.eql(u8, first_token, "trunc")) {
                if (std.mem.eql(u8, first_token, "bitcast")) {
                    op = .bitcast;
                } else if (std.mem.eql(u8, first_token, "sext")) {
                    op = .sext;
                } else if (std.mem.eql(u8, first_token, "zext")) {
                    op = .zext;
                } else if (std.mem.eql(u8, first_token, "trunc")) {
                    op = .trunc;
                } else {
                    op = .raw_cast;
                }
                try args_list.append(try self.parseExprOperand(&cursor, out));
                const as_token = cursor.next() orelse return error.MissingCastAs;
                if (!std.mem.eql(u8, as_token, "as")) return error.MissingCastAs;
                const type_str = cursor.next() orelse return error.MissingCastType;
                dest_type = parseType(type_str);
            } else if (std.mem.eql(u8, first_token, "take")) {
                op = .take;
                try args_list.append(try self.parseExprOperand(&cursor, out));
            } else if (std.mem.eql(u8, first_token, "assume_safe")) {
                op = .assume_safe;
                try args_list.append(try self.parseExprOperand(&cursor, out));
            } else if (std.mem.eql(u8, first_token, "assume_borrow")) {
                op = .assume_borrow;
                try args_list.append(try self.parseExprOperand(&cursor, out));
            } else {
                op = if (std.mem.eql(u8, first_token, "ptr_add")) .ptr_add else if (std.mem.eql(u8, first_token, "add")) .add else if (std.mem.eql(u8, first_token, "sub")) .sub else if (std.mem.eql(u8, first_token, "mul")) .mul else if (std.mem.eql(u8, first_token, "div")) .div else if (std.mem.eql(u8, first_token, "rem")) .rem else if (std.mem.eql(u8, first_token, "and")) .and_ else if (std.mem.eql(u8, first_token, "or")) .or_ else if (std.mem.eql(u8, first_token, "xor")) .xor_ else if (std.mem.eql(u8, first_token, "sgt")) .sgt else if (std.mem.eql(u8, first_token, "slt")) .slt else if (std.mem.eql(u8, first_token, "sge")) .sge else if (std.mem.eql(u8, first_token, "sle")) .sle else if (std.mem.eql(u8, first_token, "ugt")) .ugt else if (std.mem.eql(u8, first_token, "ult")) .ult else if (std.mem.eql(u8, first_token, "uge")) .uge else if (std.mem.eql(u8, first_token, "ule")) .ule else if (std.mem.eql(u8, first_token, "eq")) .eq else if (std.mem.eql(u8, first_token, "ne")) .ne else if (std.mem.eql(u8, first_token, "sdiv")) .sdiv else if (std.mem.eql(u8, first_token, "udiv")) .udiv else if (std.mem.eql(u8, first_token, "srem")) .srem else .urem;
                try args_list.append(try self.parseExprOperand(&cursor, out));
                try args_list.append(try self.parseExprOperand(&cursor, out));
            }

            try out.append(.{
                .op = op,
                .dest = dest,
                .args = try args_list.toOwnedSlice(),
                .dest_type = dest_type,
            });
            return;
        }

        if (std.mem.eql(u8, first_token, "stack_alloc")) {
            op = .stack_alloc;
            const size_str = token_it.next() orelse return error.MissingStackAllocSize;
            try args_list.append(try self.parseOperand(size_str));
        } else if (std.mem.eql(u8, first_token, "call")) {
            op = .call;
            const lparen = std.mem.indexOf(u8, args_raw, "(") orelse return error.InvalidCallSyntax;
            const rparen = std.mem.lastIndexOf(u8, args_raw, ")") orelse return error.InvalidCallSyntax;
            
            const call_idx = std.mem.indexOf(u8, args_raw, "call") orelse return error.InvalidCallSyntax;
            var func_name_raw = std.mem.trim(u8, args_raw[call_idx + "call".len .. lparen], " \t");
            if (std.mem.startsWith(u8, func_name_raw, "@")) {
                func_name_raw = func_name_raw[1..];
            }
            try args_list.append(Operand{ .kind = .label, .name = try self.allocator.dupe(u8, func_name_raw) });

            const args_str = args_raw[lparen + 1 .. rparen];
            var arg_it = std.mem.tokenizeAny(u8, args_str, ", \t");
            while (arg_it.next()) |arg| {
                const cleaned_arg = std.mem.trim(u8, arg, " \t");
                if (cleaned_arg.len == 0) continue;
                try args_list.append(try self.parseOperand(cleaned_arg));
            }
        } else if (std.mem.eql(u8, first_token, "call_indirect")) {
            op = .call_indirect;
            const lparen = std.mem.indexOf(u8, args_raw, "(") orelse return error.InvalidCallSyntax;
            const rparen = std.mem.lastIndexOf(u8, args_raw, ")") orelse return error.InvalidCallSyntax;
            
            const call_idx = std.mem.indexOf(u8, args_raw, "call_indirect") orelse return error.InvalidCallSyntax;
            const func_ptr_str = std.mem.trim(u8, args_raw[call_idx + "call_indirect".len .. lparen], " \t");
            try args_list.append(try self.parseOperand(func_ptr_str));

            const args_str = args_raw[lparen + 1 .. rparen];
            var arg_it = std.mem.tokenizeAny(u8, args_str, ", \t");
            while (arg_it.next()) |arg| {
                const cleaned_arg = std.mem.trim(u8, arg, " \t");
                if (cleaned_arg.len == 0) continue;
                try args_list.append(try self.parseOperand(cleaned_arg));
            }
        } else if (std.mem.eql(u8, first_token, "assume_safe")) {
            op = .assume_safe;
            const arg = token_it.next() orelse return error.MissingAssumeSafeArg;
            try args_list.append(try self.parseOperand(arg));
        } else if (std.mem.eql(u8, first_token, "assume_borrow")) {
            op = .assume_borrow;
            const arg = token_it.next() orelse return error.MissingAssumeBorrowArg;
            try args_list.append(try self.parseOperand(arg));
        } else if (std.mem.eql(u8, first_token, "panic") or std.mem.startsWith(u8, first_token, "panic(")) {
            op = .panic;
            const lparen = std.mem.indexOf(u8, args_raw, "(") orelse return error.InvalidPanicSyntax;
            const rparen = std.mem.lastIndexOf(u8, args_raw, ")") orelse return error.InvalidPanicSyntax;
            const code_str = std.mem.trim(u8, args_raw[lparen + 1 .. rparen], " \t");
            try args_list.append(try self.parseOperand(code_str));
        } else if (std.mem.eql(u8, first_token, "panic_msg") or std.mem.startsWith(u8, first_token, "panic_msg(")) {
            op = .panic_msg;
            const lparen = std.mem.indexOf(u8, args_raw, "(") orelse return error.InvalidPanicSyntax;
            const rparen = std.mem.lastIndexOf(u8, args_raw, ")") orelse return error.InvalidPanicSyntax;
            const args_str = args_raw[lparen + 1 .. rparen];
            var arg_it = std.mem.tokenizeAny(u8, args_str, ", \t");
            while (arg_it.next()) |arg| {
                const cleaned_arg = std.mem.trim(u8, arg, " \t");
                if (cleaned_arg.len == 0) continue;
                try args_list.append(try self.parseOperand(cleaned_arg));
            }
        } else if (std.mem.eql(u8, first_token, "load")) {
            op = .load;
            // e.g. load __h_ptr_slot+0 as ptr
            const addr_str = token_it.next() orelse return error.MissingLoadAddress;
            const as_token = token_it.next() orelse return error.MissingLoadAs;
            _ = as_token; // "as"
            const type_str = token_it.next() orelse return error.MissingLoadType;
            dest_type = parseType(type_str);

            try args_list.append(try self.parseOperand(addr_str));
        } else if (std.mem.eql(u8, first_token, "alloc")) {
            op = .alloc;
            const size_str = token_it.next() orelse return error.MissingAllocSize;
            try args_list.append(try self.parseOperand(size_str));
        } else if (std.mem.eql(u8, first_token, "ptr_add")) {
            op = .ptr_add;
            const arg1 = token_it.next() orelse return error.MissingPtrAddArg1;
            const arg2 = token_it.next() orelse return error.MissingPtrAddArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "add")) {
            op = .add;
            const arg1 = token_it.next() orelse return error.MissingAddArg1;
            const arg2 = token_it.next() orelse return error.MissingAddArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "sub")) {
            op = .sub;
            const arg1 = token_it.next() orelse return error.MissingSubArg1;
            const arg2 = token_it.next() orelse return error.MissingSubArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "mul")) {
            op = .mul;
            const arg1 = token_it.next() orelse return error.MissingMulArg1;
            const arg2 = token_it.next() orelse return error.MissingMulArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "div")) {
            op = .div;
            const arg1 = token_it.next() orelse return error.MissingDivArg1;
            const arg2 = token_it.next() orelse return error.MissingDivArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "rem")) {
            // 'rem' is an alias for unsigned remainder (urem)
            op = .rem;
            const arg1 = token_it.next() orelse return error.MissingRemArg1;
            const arg2 = token_it.next() orelse return error.MissingRemArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "and")) {
            op = .and_;
            const arg1 = token_it.next() orelse return error.MissingAndArg1;
            const arg2 = token_it.next() orelse return error.MissingAndArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "or")) {
            op = .or_;
            const arg1 = token_it.next() orelse return error.MissingOrArg1;
            const arg2 = token_it.next() orelse return error.MissingOrArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "xor")) {
            op = .xor_;
            const arg1 = token_it.next() orelse return error.MissingXorArg1;
            const arg2 = token_it.next() orelse return error.MissingXorArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "sgt")) {
            op = .sgt;
            const arg1 = token_it.next() orelse return error.MissingSgtArg1;
            const arg2 = token_it.next() orelse return error.MissingSgtArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "slt")) {
            op = .slt;
            const arg1 = token_it.next() orelse return error.MissingSltArg1;
            const arg2 = token_it.next() orelse return error.MissingSltArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "sge")) {
            op = .sge;
            const arg1 = token_it.next() orelse return error.MissingSgeArg1;
            const arg2 = token_it.next() orelse return error.MissingSgeArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "sle")) {
            op = .sle;
            const arg1 = token_it.next() orelse return error.MissingSleArg1;
            const arg2 = token_it.next() orelse return error.MissingSleArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "ugt")) {
            op = .ugt;
            const arg1 = token_it.next() orelse return error.MissingUgtArg1;
            const arg2 = token_it.next() orelse return error.MissingUgtArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "ult")) {
            op = .ult;
            const arg1 = token_it.next() orelse return error.MissingUltArg1;
            const arg2 = token_it.next() orelse return error.MissingUltArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "uge")) {
            op = .uge;
            const arg1 = token_it.next() orelse return error.MissingUgeArg1;
            const arg2 = token_it.next() orelse return error.MissingUgeArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "ule")) {
            op = .ule;
            const arg1 = token_it.next() orelse return error.MissingUleArg1;
            const arg2 = token_it.next() orelse return error.MissingUleArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "sdiv")) {
            op = .sdiv;
            const arg1 = token_it.next() orelse return error.MissingSdivArg1;
            const arg2 = token_it.next() orelse return error.MissingSdivArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "udiv")) {
            op = .udiv;
            const arg1 = token_it.next() orelse return error.MissingUdivArg1;
            const arg2 = token_it.next() orelse return error.MissingUdivArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "srem")) {
            op = .srem;
            const arg1 = token_it.next() orelse return error.MissingSremArg1;
            const arg2 = token_it.next() orelse return error.MissingSremArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "urem")) {
            op = .urem;
            const arg1 = token_it.next() orelse return error.MissingUremArg1;
            const arg2 = token_it.next() orelse return error.MissingUremArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "shl")) {
            op = .shl;
            const arg1 = token_it.next() orelse return error.MissingShlArg1;
            const arg2 = token_it.next() orelse return error.MissingShlArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "shr")) {
            op = .shr;
            const arg1 = token_it.next() orelse return error.MissingShrArg1;
            const arg2 = token_it.next() orelse return error.MissingShrArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "gt")) {
            op = .gt;
            const arg1 = token_it.next() orelse return error.MissingGtArg1;
            const arg2 = token_it.next() orelse return error.MissingGtArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "lt")) {
            op = .lt;
            const arg1 = token_it.next() orelse return error.MissingLtArg1;
            const arg2 = token_it.next() orelse return error.MissingLtArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "atomic_load")) {
            op = .atomic_load;
            const addr_str = token_it.next() orelse return error.MissingLoadAddress;
            const as_token = token_it.next() orelse return error.MissingLoadAs;
            _ = as_token;
            const type_str = token_it.next() orelse return error.MissingLoadType;
            dest_type = parseType(type_str);
            try args_list.append(try self.parseOperand(addr_str));
        } else if (std.mem.eql(u8, first_token, "atomic_store")) {
            op = .atomic_store;
            const comma_idx = std.mem.indexOf(u8, args_raw, ",") orelse return error.InvalidStoreSyntax;
            const rest = std.mem.trim(u8, args_raw[comma_idx + 1 ..], " \t");
            var rest_it = std.mem.tokenizeAny(u8, rest, " \t");
            const val_str = rest_it.next() orelse return error.InvalidStoreSyntax;
            const as_tok = rest_it.next() orelse return error.InvalidStoreSyntax;
            _ = as_tok;
            const type_str = rest_it.next() orelse return error.InvalidStoreSyntax;
            dest_type = parseType(type_str);
            const ptr_str = std.mem.trim(u8, args_raw["atomic_store".len..comma_idx], " \t");
            try args_list.append(try self.parseOperand(val_str));
            try args_list.append(try self.parseOperand(ptr_str));
        } else if (std.mem.eql(u8, first_token, "cmpxchg")) {
            op = .cmpxchg;
            const first_comma = std.mem.indexOf(u8, args_raw, ",") orelse return error.InvalidCmpxchgSyntax;
            const second_comma = std.mem.indexOfPos(u8, args_raw, first_comma + 1, ",") orelse return error.InvalidCmpxchgSyntax;
            const addr_str = std.mem.trim(u8, args_raw["cmpxchg".len..first_comma], " \t");
            const expected_str = std.mem.trim(u8, args_raw[first_comma + 1 .. second_comma], " \t");
            const rest = std.mem.trim(u8, args_raw[second_comma + 1 ..], " \t");
            var rest_it = std.mem.tokenizeAny(u8, rest, " \t");
            const new_val_str = rest_it.next() orelse return error.InvalidCmpxchgSyntax;
            const as_tok = rest_it.next() orelse return error.InvalidCmpxchgSyntax;
            _ = as_tok;
            const type_str = rest_it.next() orelse return error.InvalidCmpxchgSyntax;
            dest_type = parseType(type_str);
            try args_list.append(try self.parseOperand(addr_str));
            try args_list.append(try self.parseOperand(expected_str));
            try args_list.append(try self.parseOperand(new_val_str));
        } else if (std.mem.eql(u8, first_token, "atomic_rmw_add")) {
            op = .atomic_rmw_add;
            const comma_idx = std.mem.indexOf(u8, args_raw, ",") orelse return error.InvalidAtomicRmwSyntax;
            const addr_str = std.mem.trim(u8, args_raw["atomic_rmw_add".len..comma_idx], " \t");
            const rest = std.mem.trim(u8, args_raw[comma_idx + 1 ..], " \t");
            var rest_it = std.mem.tokenizeAny(u8, rest, " \t");
            const val_str = rest_it.next() orelse return error.InvalidAtomicRmwSyntax;
            const as_tok = rest_it.next() orelse return error.InvalidAtomicRmwSyntax;
            _ = as_tok;
            const type_str = rest_it.next() orelse return error.InvalidAtomicRmwSyntax;
            dest_type = parseType(type_str);
            try args_list.append(try self.parseOperand(addr_str));
            try args_list.append(try self.parseOperand(val_str));
        } else if (std.mem.eql(u8, first_token, "raw_cast") or std.mem.eql(u8, first_token, "bitcast") or std.mem.eql(u8, first_token, "sext") or std.mem.eql(u8, first_token, "zext") or std.mem.eql(u8, first_token, "trunc")) {
            if (std.mem.eql(u8, first_token, "bitcast")) {
                op = .bitcast;
            } else if (std.mem.eql(u8, first_token, "sext")) {
                op = .sext;
            } else if (std.mem.eql(u8, first_token, "zext")) {
                op = .zext;
            } else if (std.mem.eql(u8, first_token, "trunc")) {
                op = .trunc;
            } else {
                op = .raw_cast;
            }
            const arg = token_it.next() orelse return error.MissingCastArg;
            const as_token = token_it.next() orelse return error.MissingCastAs;
            _ = as_token;
            const type_str = token_it.next() orelse return error.MissingCastType;
            dest_type = parseType(type_str);
            try args_list.append(try self.parseOperand(arg));
        } else if (std.mem.eql(u8, first_token, "take")) {
            op = .take;
            const addr_str = token_it.next() orelse return error.MissingTakeAddress;
            try args_list.append(try self.parseOperand(addr_str));
        } else if (std.mem.eql(u8, first_token, "?")) {
            op = .try_;
            const src_str = token_it.next() orelse return error.MissingTrySource;
            try args_list.append(try self.parseOperand(src_str));
        } else if (std.mem.eql(u8, first_token, "store")) {
            op = .store;
            if (std.mem.indexOf(u8, args_raw, "into") != null) {
                const val_str = token_it.next() orelse return error.MissingStoreValue;
                const into_token = token_it.next() orelse return error.MissingStoreInto;
                _ = into_token;
                const ptr_str = token_it.next() orelse return error.MissingStorePtr;

                try args_list.append(try self.parseOperand(val_str));
                try args_list.append(try self.parseOperand(ptr_str));
            } else {
                const comma_idx = std.mem.indexOf(u8, args_raw, ",") orelse return error.InvalidStoreSyntax;
                const as_idx = std.mem.lastIndexOf(u8, args_raw, " as ") orelse return error.InvalidStoreSyntax;
                const ptr_str = std.mem.trim(u8, args_raw["store".len..comma_idx], " \t");
                const val_str = std.mem.trim(u8, args_raw[comma_idx + 1 .. as_idx], " \t");
                const type_str = std.mem.trim(u8, args_raw[as_idx + " as ".len ..], " \t");
                dest_type = parseType(type_str);

                try args_list.append(try self.parseOperand(val_str));
                try args_list.append(try self.parseOperand(ptr_str));
            }
        } else if (std.mem.eql(u8, first_token, "eq")) {
            op = .eq;
            const arg1 = token_it.next() orelse return error.MissingEqArg1;
            const arg2 = token_it.next() orelse return error.MissingEqArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "ne")) {
            op = .ne;
            const arg1 = token_it.next() orelse return error.MissingNeArg1;
            const arg2 = token_it.next() orelse return error.MissingNeArg2;
            const cleaned_arg1 = std.mem.trimRight(u8, arg1, ",");
            try args_list.append(try self.parseOperand(cleaned_arg1));
            try args_list.append(try self.parseOperand(arg2));
        } else if (std.mem.eql(u8, first_token, "br")) {
            op = .br;
            // br is_h_ok -> L_OS_RELEASE, L_FAIL_H
            const cond = token_it.next() orelse return error.MissingBrCond;
            try args_list.append(try self.parseOperand(cond));

            const arrow = token_it.next() orelse return error.MissingBrArrow;
            _ = arrow; // "->"

            const dest1_raw = token_it.next() orelse return error.MissingBrDest1;
            const dest1 = std.mem.trimRight(u8, dest1_raw, ",");
            try args_list.append(Operand{ .kind = .label, .name = try self.allocator.dupe(u8, dest1) });

            const dest2 = token_it.next() orelse return error.MissingBrDest2;
            try args_list.append(Operand{ .kind = .label, .name = try self.allocator.dupe(u8, dest2) });
        } else if (std.mem.eql(u8, first_token, "jmp")) {
            op = .jmp;
            const dest_label = token_it.next() orelse return error.MissingJmpDest;
            try args_list.append(Operand{ .kind = .label, .name = try self.allocator.dupe(u8, dest_label) });
        } else if (std.mem.eql(u8, first_token, "return")) {
            op = .return_;
            if (token_it.next()) |ret_val| {
                try args_list.append(try self.parseOperand(ret_val));
            }
        } else {
            if (dest != null) {
                op = .assign;
                try args_list.append(try self.parseOperand(first_token));
            } else {
                std.debug.print("Unsupported instruction/opcode: {s}\n", .{first_token});
                return error.UnsupportedOpcode;
            }
        }

        try out.append(.{
            .op = op,
            .dest = dest,
            .args = try args_list.toOwnedSlice(),
            .dest_type = dest_type,
        });
    }

    fn parseOperand(self: *Parser, raw_in: []const u8) !Operand {
        const raw = std.mem.trim(u8, raw_in, " \t\r\n");
        if (raw.len == 0) {
            return error.EmptyOperand;
        }
        if (std.mem.startsWith(u8, raw, "*")) {
            const inner = raw[1..];
            if (self.constants.contains(inner) or std.mem.startsWith(u8, inner, "STR_") or std.mem.startsWith(u8, inner, "KEY_") or std.mem.startsWith(u8, inner, "VAL_") or std.mem.startsWith(u8, inner, "FS_") or std.mem.startsWith(u8, inner, "LIB_") or std.mem.startsWith(u8, inner, "DEMO_")) {
                return Operand{ .kind = .constant_addr, .name = try self.allocator.dupe(u8, inner) };
            }
            return self.parseOperand(inner);
        }

        if (std.mem.startsWith(u8, raw, "^")) {
            const inner = raw[1..];
            return self.parseOperand(inner);
        }

        if (std.mem.startsWith(u8, raw, "&")) {
            const inner = raw[1..];
            if (self.constants.contains(inner) or std.mem.startsWith(u8, inner, "STR_") or std.mem.startsWith(u8, inner, "KEY_") or std.mem.startsWith(u8, inner, "VAL_") or std.mem.startsWith(u8, inner, "FS_")) {
                return Operand{ .kind = .constant_addr, .name = try self.allocator.dupe(u8, inner) };
            }
            return Operand{ .kind = .stack_addr, .name = try self.allocator.dupe(u8, inner) };
        }

        // A bare '+N' token (e.g. from a #def offset macro) is a pure immediate value.
        if (raw[0] == '+' and raw.len > 1 and std.ascii.isDigit(raw[1])) {
            const val = try std.fmt.parseInt(u64, raw[1..], 10);
            return Operand{ .kind = .immediate, .name = try self.allocator.dupe(u8, raw), .imm_val = val };
        }

        if (std.mem.indexOf(u8, raw, "+")) |plus_idx| {
            const base_reg = raw[0..plus_idx];
            const offset_str = raw[plus_idx + 1 ..];
            const offset = try std.fmt.parseInt(i32, offset_str, 10);
            return Operand{ .kind = .offset_addr, .name = try self.allocator.dupe(u8, base_reg), .offset = offset };
        }

        if (std.ascii.isDigit(raw[0]) or (raw[0] == '-' and raw.len > 1 and std.ascii.isDigit(raw[1]))) {
            const val = if (std.fmt.parseInt(i64, raw, 10)) |v|
                @as(u64, @bitCast(v))
            else |_|
                try std.fmt.parseInt(u64, raw, 10);
            return Operand{ .kind = .immediate, .name = try self.allocator.dupe(u8, raw), .imm_val = val };
        }

        return Operand{ .kind = .register, .name = try self.allocator.dupe(u8, raw) };
    }
};
