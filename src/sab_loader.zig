const std = @import("std");
const sab = @import("sab");
const parser = @import("parser.zig");

const sci_inst = sab.instruction;
const sci_sig = sab.signature;
const sci_const = sab.const_decl;

pub const SabLoaderError = error{
    InvalidSabSymbol,
    MalformedSabOperand,
    MalformedSabCallBody,
    MalformedSabPanicMsg,
    UnsupportedSabInstruction,
    UnsupportedSabOpKind,
    UnsupportedSabFloatOp,
    UnsupportedSabSimdOp,
    UnsupportedSabAtomicRmwOp,
    UnsupportedSabNativeInst,
    UnsupportedSabPrimType,
};

/// SAB modules start with the literal bytes "SAB\x00" (see sci/src/sab.zig).
pub fn isSabMagic(bytes: []const u8) bool {
    return bytes.len >= sab.magic.len and std.mem.eql(u8, bytes[0..sab.magic.len], sab.magic);
}

const Ctx = struct {
    allocator: std.mem.Allocator,
    symbols: []const []const u8,
    constants: *std.StringHashMap([]const u8),
};

fn symbolName(ctx: Ctx, id: u64) ![]const u8 {
    const idx: usize = @intCast(id);
    if (idx >= ctx.symbols.len) return error.InvalidSabSymbol;
    return ctx.symbols[idx];
}

fn constLikeName(ctx: Ctx, name: []const u8) bool {
    if (ctx.constants.contains(name)) return true;
    inline for ([_][]const u8{ "STR_", "KEY_", "VAL_", "FS_", "LIB_", "DEMO_" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

/// Classify a folded SA operand name into a VM operand, mirroring
/// Parser.parseOperand in parser.zig ("&CONST"/"*ptr"/"^x"/"reg+8"/immediates).
fn operandFromName(ctx: Ctx, raw_in: []const u8) anyerror!parser.Operand {
    const allocator = ctx.allocator;
    const raw = std.mem.trim(u8, raw_in, " \t\r\n");
    if (raw.len == 0) return error.MalformedSabOperand;
    if (std.mem.startsWith(u8, raw, "*")) {
        const inner = raw[1..];
        if (constLikeName(ctx, inner)) {
            return parser.Operand{ .kind = .constant_addr, .name = try allocator.dupe(u8, inner) };
        }
        return operandFromName(ctx, inner);
    }
    if (std.mem.startsWith(u8, raw, "^")) {
        return operandFromName(ctx, raw[1..]);
    }
    if (std.mem.startsWith(u8, raw, "&")) {
        const inner = raw[1..];
        if (constLikeName(ctx, inner)) {
            return parser.Operand{ .kind = .constant_addr, .name = try allocator.dupe(u8, inner) };
        }
        return parser.Operand{ .kind = .stack_addr, .name = try allocator.dupe(u8, inner) };
    }
    // A bare '+N' token is a pure immediate value.
    if (raw[0] == '+' and raw.len > 1 and std.ascii.isDigit(raw[1])) {
        const val = try std.fmt.parseInt(u64, raw[1..], 10);
        return parser.Operand{ .kind = .immediate, .name = try allocator.dupe(u8, raw), .imm_val = val };
    }
    if (std.mem.indexOfScalarPos(u8, raw, 1, '+')) |plus_idx| {
        const base_reg = raw[0..plus_idx];
        const offset_str = raw[plus_idx + 1 ..];
        const offset = try std.fmt.parseInt(i32, offset_str, 10);
        return parser.Operand{ .kind = .offset_addr, .name = try allocator.dupe(u8, base_reg), .offset = offset };
    }
    if (std.ascii.isDigit(raw[0]) or (raw[0] == '-' and raw.len > 1 and std.ascii.isDigit(raw[1]))) {
        const val = if (std.fmt.parseInt(i64, raw, 10)) |v|
            @as(u64, @bitCast(v))
        else |_|
            try std.fmt.parseInt(u64, raw, 10);
        return parser.Operand{ .kind = .immediate, .name = try allocator.dupe(u8, raw), .imm_val = val };
    }
    return parser.Operand{ .kind = .register, .name = try allocator.dupe(u8, raw) };
}

/// Convert a structured SAB operand into a VM operand.
fn operandFromSci(ctx: Ctx, op: sci_inst.Operand) anyerror!parser.Operand {
    switch (op) {
        .none => return error.MalformedSabOperand,
        .reg, .symbol, .func => {
            const id = switch (op) {
                .reg => |v| v,
                .symbol => |v| v,
                .func => |v| v,
                else => unreachable,
            };
            return operandFromName(ctx, try symbolName(ctx, id));
        },
        .label => |v| {
            return parser.Operand{
                .kind = .label,
                .name = try ctx.allocator.dupe(u8, try symbolName(ctx, v)),
            };
        },
        .imm_i64 => |v| {
            return parser.Operand{
                .kind = .immediate,
                .name = try std.fmt.allocPrint(ctx.allocator, "{d}", .{v}),
                .imm_val = @as(u64, @bitCast(v)),
            };
        },
        .imm_int => |v| {
            return parser.Operand{
                .kind = .immediate,
                .name = try std.fmt.allocPrint(ctx.allocator, "{d}", .{v}),
                .imm_val = @as(u64, @bitCast(v)),
            };
        },
        .imm_u64 => |v| {
            return parser.Operand{
                .kind = .immediate,
                .name = try std.fmt.allocPrint(ctx.allocator, "{d}", .{v}),
                .imm_val = v,
            };
        },
        .imm_float => |v| {
            // SAB carries every float immediate as f64; the VM stores it as the
            // raw IEEE-754 bit pattern of that f64 (see vm.zig float policy).
            return parser.Operand{
                .kind = .immediate,
                .name = try std.fmt.allocPrint(ctx.allocator, "{d}", .{v}),
                .imm_val = @as(u64, @bitCast(v)),
            };
        },
        .text => |text| return operandFromName(ctx, text),
        .native_text => return error.UnsupportedSabNativeInst,
        .op_code, .cap_prefix, .offset, .ty => return error.MalformedSabOperand,
    }
}

/// Size operands (alloc/stack_alloc) only allow non-negative immediates or regs.
fn sizeOperandFromSci(ctx: Ctx, op: sci_inst.Operand) anyerror!parser.Operand {
    switch (op) {
        .imm_i64, .imm_int => |v| {
            if (v < 0) return error.MalformedSabOperand;
        },
        .imm_u64, .reg, .symbol, .text => {},
        else => return error.MalformedSabOperand,
    }
    return operandFromSci(ctx, op);
}

fn mapPrimType(ty: sci_sig.PrimType) !parser.PrimType {
    return switch (ty) {
        .void => .void,
        .i1 => .i1,
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .u64 => .u64,
        .f32 => .f32,
        .f64 => .f64,
        .ptr => .ptr,
        // 64-bit opaque plugin handles behave like u64 in this interpreter.
        .blob_handle => .u64,
        .v128 => error.UnsupportedSabPrimType,
    };
}

fn destTypeFromTyOperand(op: sci_inst.Operand) !parser.PrimType {
    switch (op) {
        .ty => |tag| {
            const sci_ty = std.meta.intToEnum(sci_sig.PrimType, @as(u8, @intCast(tag))) catch return error.UnsupportedSabPrimType;
            return mapPrimType(sci_ty);
        },
        else => return error.MalformedSabOperand,
    }
}

fn atomicValueType(item: *const sci_inst.Instruction) !parser.PrimType {
    if (item.atomic_value_ty) |tag| {
        const sci_ty = std.meta.intToEnum(sci_sig.PrimType, @as(u8, @intCast(tag))) catch return error.UnsupportedSabPrimType;
        return mapPrimType(sci_ty);
    }
    return .u64;
}

/// "base reg + offset" pairs (load/store/atomics). The textual pipeline encodes
/// these as a single register/stack/offset operand; rebuild that shape here.
fn addrOperand(ctx: Ctx, base_op: sci_inst.Operand, offset_op: ?sci_inst.Operand) anyerror!parser.Operand {
    const base_name_raw = switch (base_op) {
        .reg, .symbol => |id| try symbolName(ctx, id),
        .text => |text| text,
        else => return error.MalformedSabOperand,
    };
    var offset: i64 = 0;
    if (offset_op) |off| {
        switch (off) {
            .none => {},
            .imm_u64 => |v| {
                if (v > std.math.maxInt(i64)) return error.MalformedSabOperand;
                offset = @intCast(v);
            },
            .imm_i64, .imm_int => |v| offset = v,
            .offset => |v| offset = @intCast(v),
            else => return error.MalformedSabOperand,
        }
    }

    // Preserve &CONST / *ptr / ^x classification of the bare address first.
    if (offset == 0) return operandFromName(ctx, base_name_raw);

    const stripped = std.mem.trimLeft(u8, base_name_raw, "&*^");
    if (offset < -std.math.maxInt(i32) or offset > std.math.maxInt(i32)) return error.MalformedSabOperand;
    return parser.Operand{
        .kind = .offset_addr,
        .name = try ctx.allocator.dupe(u8, stripped),
        .offset = @intCast(offset),
    };
}

/// Map a sci OpKind to a VM OpCode for binary `.op` instructions.
/// Division semantics mirror the VM dispatch exactly:
///   div/rem are UNSIGNED aliases (vm.zig maps .div/.rem onto udiv/urem),
///   sdiv/udiv/srem/urem keep their signedness.
/// gt/lt are the signed compat aliases; lshr/shr both map to logical shr.
/// Float ops compute in f64 (see vm.zig float policy); f32 operands are
/// widened back to f64 by the typed loads that produced them.
fn binaryOpCode(kind: sci_inst.OpKind) ?parser.OpCode {
    return switch (kind) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .rem => .rem,
        .sdiv => .sdiv,
        .udiv => .udiv,
        .srem => .srem,
        .urem => .urem,
        .@"and" => .and_,
        .@"or" => .or_,
        .xor => .xor_,
        .shl => .shl,
        .lshr, .shr => .shr,
        .ashr => .ashr,
        .eq => .eq,
        .ne => .ne,
        .sgt, .gt => .sgt,
        .slt, .lt => .slt,
        .sge => .sge,
        .sle => .sle,
        .ugt => .ugt,
        .ult => .ult,
        .uge => .uge,
        .ule => .ule,
        .fadd => .fadd,
        .fsub => .fsub,
        .fmul => .fmul,
        .fdiv => .fdiv,
        .fcmp_eq => .fcmp_eq,
        .fcmp_ne => .fcmp_ne,
        .fcmp_lt => .fcmp_lt,
        .fcmp_le => .fcmp_le,
        .fcmp_gt => .fcmp_gt,
        .fcmp_ge => .fcmp_ge,
        else => null,
    };
}

/// Map a sci OpKind to a VM OpCode for unary `.op` instructions. These carry a
/// single source operand; the VM executes them on the slow path.
fn unaryOpCode(kind: sci_inst.OpKind) ?parser.OpCode {
    return switch (kind) {
        .neg => .neg,
        .not => .not,
        .fneg => .fneg,
        else => null,
    };
}

/// Map a sci OpKind to a VM OpCode for int <-> int conversion instructions.
fn intConversionOpCode(kind: sci_inst.OpKind) ?parser.OpCode {
    return switch (kind) {
        .trunc => .trunc,
        .zext => .zext,
        .sext => .sext,
        .bitcast => .bitcast,
        else => null,
    };
}

/// Map a sci OpKind to a VM OpCode for float <-> int conversion instructions.
fn floatConversionOpCode(kind: sci_inst.OpKind) ?parser.OpCode {
    return switch (kind) {
        .fptosi => .fptosi,
        .sitofp => .sitofp,
        .uitofp => .uitofp,
        .fptrunc => .fptrunc,
        .fpext => .fpext,
        else => null,
    };
}

fn unsupportedOpKind(kind: sci_inst.OpKind) anyerror {
    std.debug.print("sab_loader: unsupported op kind '{s}' (v128/SIMD ops are not interpreted)\n", .{@tagName(kind)});
    return switch (kind) {
        .add_v128, .sub_v128, .mul_v128, .shuffle_v128, .extract_lane, .insert_lane => error.UnsupportedSabSimdOp,
        else => error.UnsupportedSabOpKind,
    };
}

fn labelOperandFromSci(ctx: Ctx, candidates: []const sci_inst.Operand) anyerror!parser.Operand {
    for (candidates) |op| {
        switch (op) {
            .label => |id| {
                return parser.Operand{
                    .kind = .label,
                    .name = try ctx.allocator.dupe(u8, try symbolName(ctx, id)),
                };
            },
            else => {},
        }
    }
    return error.MalformedSabOperand;
}

fn splitTopLevelCommas(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var parts = std.ArrayList([]const u8).init(allocator);
    errdefer parts.deinit();
    var depth: usize = 0;
    var start: usize = 0;
    for (text, 0..) |c, idx| {
        switch (c) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth > 0) depth -= 1;
            },
            ',' => {
                if (depth == 0) {
                    try parts.append(std.mem.trim(u8, text[start..idx], " \t"));
                    start = idx + 1;
                }
            },
            else => {},
        }
    }
    const tail = std.mem.trim(u8, text[start..], " \t");
    if (tail.len != 0 or parts.items.len == 0) try parts.append(tail);
    return try parts.toOwnedSlice();
}

fn stripOuterParens(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')') {
        return std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    }
    return trimmed;
}

/// Parse a call body like "@sink(&arg, value)" into target + argument operands.
fn callBodyParts(body: []const u8) !struct { target: []const u8, args_text: []const u8 } {
    const trimmed = std.mem.trim(u8, body, " \t");
    const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return error.MalformedSabCallBody;
    const close = std.mem.lastIndexOfScalar(u8, trimmed, ')') orelse return error.MalformedSabCallBody;
    if (close < open) return error.MalformedSabCallBody;
    if (std.mem.trim(u8, trimmed[close + 1 ..], " \t").len != 0) return error.MalformedSabCallBody;
    var target = std.mem.trim(u8, trimmed[0..open], " \t");
    if (std.mem.startsWith(u8, target, "@")) target = target[1..];
    if (target.len == 0) return error.MalformedSabCallBody;
    return .{ .target = target, .args_text = trimmed[open + 1 .. close] };
}

fn convertInstruction(ctx: Ctx, item: *const sci_inst.Instruction, out: *std.ArrayList(parser.Instruction)) anyerror!void {
    const allocator = ctx.allocator;
    var args = std.ArrayList(parser.Operand).init(allocator);
    errdefer args.deinit();

    var op: parser.OpCode = .assign;
    var dest: ?[]const u8 = null;
    var dest_type: parser.PrimType = .void;
    errdefer if (dest) |d| allocator.free(d);

    switch (item.kind) {
        .alloc, .stack_alloc => {
            op = if (item.kind == .alloc) .alloc else .stack_alloc;
            dest = try allocator.dupe(u8, try regDestName(ctx, item.operands[0]));
            try args.append(try sizeOperandFromSci(ctx, item.operands[1]));
        },
        .load, .take => {
            op = if (item.kind == .load) .load else .take;
            dest = try allocator.dupe(u8, try regDestName(ctx, item.operands[0]));
            try args.append(try addrOperand(ctx, item.operands[1], item.operands[2]));
            if (item.operands[3] != .none) {
                dest_type = try destTypeFromTyOperand(item.operands[3]);
            } else if (item.kind == .load) {
                dest_type = .u64;
            }
        },
        .store => {
            op = .store;
            const value = try operandFromSci(ctx, item.operands[2]);
            const addr = try addrOperand(ctx, item.operands[0], item.operands[1]);
            try args.append(value);
            try args.append(addr);
            if (item.operands[3] != .none) {
                dest_type = try destTypeFromTyOperand(item.operands[3]);
            } else {
                dest_type = .u64;
            }
        },
        .atomic_load => {
            op = .atomic_load;
            dest = try allocator.dupe(u8, try regDestName(ctx, item.operands[0]));
            try args.append(try addrOperand(ctx, item.operands[1], item.operands[2]));
            dest_type = try atomicValueType(item);
        },
        .atomic_store => {
            op = .atomic_store;
            const value = try operandFromSci(ctx, item.operands[2]);
            const addr = try addrOperand(ctx, item.operands[0], item.operands[1]);
            try args.append(value);
            try args.append(addr);
            dest_type = try atomicValueType(item);
        },
        .cmpxchg => {
            op = .cmpxchg;
            // SAB order: [0]=old-value dst, [1]=ok flag, [2]=base, [3]=offset.
            // The VM expects dest "old, ok" so slot0 gets the old value and
            // slot2 the success flag (see vm.zig cmpxchg slow path).
            const old_name = try regDestName(ctx, item.operands[0]);
            const ok_name = try regDestName(ctx, item.operands[1]);
            dest = try std.fmt.allocPrint(allocator, "{s}, {s}", .{ old_name, ok_name });
            try args.append(try addrOperand(ctx, item.operands[2], item.operands[3]));
            const expected = item.atomic_expected_text orelse return error.MalformedSabOperand;
            const new_value = item.atomic_new_text orelse return error.MalformedSabOperand;
            try args.append(try operandFromName(ctx, expected));
            try args.append(try operandFromName(ctx, new_value));
            dest_type = try atomicValueType(item);
        },
        .atomic_rmw => {
            const rmw_op = item.atomic_rmw_op orelse return error.MalformedSabOperand;
            if (rmw_op != .add) {
                std.debug.print("sab_loader: unsupported atomic_rmw op '{s}' (only add is interpreted)\n", .{@tagName(rmw_op)});
                return error.UnsupportedSabAtomicRmwOp;
            }
            op = .atomic_rmw_add;
            dest = try allocator.dupe(u8, try regDestName(ctx, item.operands[0]));
            try args.append(try addrOperand(ctx, item.operands[1], item.operands[2]));
            try args.append(try operandFromSci(ctx, item.operands[3]));
            dest_type = try atomicValueType(item);
        },
        .borrow => {
            op = .assume_borrow;
            dest = try allocator.dupe(u8, try regDestName(ctx, item.operands[0]));
            try args.append(try operandFromSci(ctx, item.operands[1]));
        },
        .move_, .release, .fence => {
            // Ownership bookkeeping markers and fences have no interpreter
            // effect. An assign without dest or args is a no-op on every VM
            // path (quickened code skips it; the slow path guards dest_slot).
            op = .assign;
        },
        .assign => {
            op = .assign;
            dest = try allocator.dupe(u8, try regDestName(ctx, item.operands[0]));
            try args.append(try operandFromSci(ctx, item.operands[1]));
        },
        .op => {
            const kind = item.op_kind orelse return error.MalformedSabOperand;
            dest = try allocator.dupe(u8, try regDestName(ctx, item.operands[0]));
            if (binaryOpCode(kind)) |mapped| {
                op = mapped;
                try args.append(try operandFromSci(ctx, item.operands[1]));
                try args.append(try operandFromSci(ctx, item.operands[2]));
            } else if (unaryOpCode(kind)) |mapped| {
                // Unary ops only carry a source operand; operands[2] is .none.
                op = mapped;
                try args.append(try operandFromSci(ctx, item.operands[1]));
            } else if (intConversionOpCode(kind)) |mapped| {
                op = mapped;
                try args.append(try operandFromSci(ctx, item.operands[1]));
                if (item.operands[2] != .none) {
                    dest_type = try destTypeFromTyOperand(item.operands[2]);
                }
            } else if (floatConversionOpCode(kind)) |mapped| {
                // Conversions are unary plus a trailing `ty:` result type.
                op = mapped;
                try args.append(try operandFromSci(ctx, item.operands[1]));
                if (item.operands[2] == .ty) {
                    dest_type = try destTypeFromTyOperand(item.operands[2]);
                }
            } else {
                return unsupportedOpKind(kind);
            }
        },
        .ptr_add => {
            op = .ptr_add;
            dest = try allocator.dupe(u8, try regDestName(ctx, item.operands[0]));
            try args.append(try operandFromSci(ctx, item.operands[1]));
            try args.append(try operandFromSci(ctx, item.operands[2]));
        },
        .jmp => {
            op = .jmp;
            try args.append(try labelOperandFromSci(ctx, item.operands[0..2]));
        },
        .br => {
            op = .br;
            try args.append(try operandFromSci(ctx, item.operands[0]));
            // SAB stores the true label twice (operands[1] and [2]) and the
            // false label last (operands[3]).
            try args.append(try labelOperandFromSci(ctx, item.operands[1..3]));
            try args.append(try labelOperandFromSci(ctx, item.operands[3..4]));
        },
        .call, .call_indirect => {
            op = if (item.kind == .call) .call else .call_indirect;
            var body: []const u8 = undefined;
            if (item.operands[0] == .reg) {
                dest = try allocator.dupe(u8, try regDestName(ctx, item.operands[0]));
                body = switch (item.operands[1]) {
                    .text => |text| text,
                    else => return error.MalformedSabCallBody,
                };
            } else {
                body = switch (item.operands[0]) {
                    .text => |text| text,
                    else => return error.MalformedSabCallBody,
                };
            }
            const parts = try callBodyParts(body);
            if (item.kind == .call) {
                try args.append(parser.Operand{ .kind = .label, .name = try allocator.dupe(u8, parts.target) });
            } else {
                // Indirect calls keep the callee expression as args[0]: the VM
                // resolves it to a function pointer at run time (vm.executeSlow
                // `.call_indirect` / appendIndirectCall both read inst.args[0]
                // as the callee). Dropping it used to leave the first *argument*
                // in that slot, so the interpreter called through an arbitrary
                // data pointer and crashed (rosetta 007/032/114/163).
                try args.append(try operandFromName(ctx, parts.target));
            }
            const arg_texts = try splitTopLevelCommas(allocator, parts.args_text);
            defer allocator.free(arg_texts);
            for (arg_texts) |arg_text| {
                if (arg_text.len == 0) continue;
                try args.append(try operandFromName(ctx, arg_text));
            }
            if (item.kind == .call_indirect and args.items.len == 0) return error.MalformedSabCallBody;
        },
        .try_ => {
            op = .try_;
            dest = try allocator.dupe(u8, try regDestName(ctx, item.operands[0]));
            try args.append(try operandFromSci(ctx, item.operands[1]));
        },
        .panic => {
            op = .panic;
            switch (item.operands[0]) {
                .reg => |id| try args.append(parser.Operand{
                    .kind = .register,
                    .name = try allocator.dupe(u8, try symbolName(ctx, id)),
                }),
                .text => |text| try args.append(try operandFromName(ctx, stripOuterParens(text))),
                else => try args.append(parser.Operand{ .kind = .immediate, .name = try allocator.dupe(u8, "1"), .imm_val = 1 }),
            }
        },
        .panic_msg => {
            op = .panic_msg;
            const inner = switch (item.operands[0]) {
                .text => |text| stripOuterParens(text),
                .reg => |id| try symbolName(ctx, id),
                else => return error.MalformedSabPanicMsg,
            };
            const arg_texts = try splitTopLevelCommas(allocator, inner);
            defer allocator.free(arg_texts);
            if (arg_texts.len < 3) return error.MalformedSabPanicMsg;
            for (arg_texts) |arg_text| {
                if (arg_text.len == 0) continue;
                try args.append(try operandFromName(ctx, arg_text));
            }
            if (args.items.len < 3) return error.MalformedSabPanicMsg;
        },
        .return_ => {
            op = .return_;
            switch (item.operands[0]) {
                .none => {},
                else => try args.append(try operandFromSci(ctx, item.operands[0])),
            }
        },
        .raw_cast, .assume_safe, .assume_borrow => {
            op = switch (item.kind) {
                .raw_cast => .raw_cast,
                .assume_safe => .assume_safe,
                else => .assume_borrow,
            };
            dest = try allocator.dupe(u8, try regDestName(ctx, item.operands[0]));
            try args.append(try operandFromSci(ctx, item.operands[1]));
        },
        .br_null => {
            std.debug.print("sab_loader: unsupported instruction 'br_null'\n", .{});
            return error.UnsupportedSabInstruction;
        },
        .early_return => {
            std.debug.print("sab_loader: unsupported instruction 'early_return'\n", .{});
            return error.UnsupportedSabInstruction;
        },
        .native => {
            std.debug.print("sab_loader: unsupported instruction 'native' (inline native escapes are not interpreted)\n", .{});
            return error.UnsupportedSabNativeInst;
        },
        .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl, .label => {
            // Handled by the function-body walker, never reaches here.
            std.debug.print("sab_loader: unexpected declaration/label instruction inside function body\n", .{});
            return error.UnsupportedSabInstruction;
        },
    }

    try out.append(.{
        .op = op,
        .dest = dest,
        .args = try args.toOwnedSlice(),
        .dest_type = dest_type,
    });
}

fn regDestName(ctx: Ctx, op: sci_inst.Operand) ![]const u8 {
    switch (op) {
        .reg, .symbol => |v| {
            const id: u64 = if (op == .reg) op.reg else v;
            return symbolName(ctx, id);
        },
        else => return error.MalformedSabOperand,
    }
}

fn constValueBytes(allocator: std.mem.Allocator, value: sci_const.ConstValue) anyerror!?[]u8 {
    switch (value) {
        .hex, .utf8, .repeat => |literal| return try allocator.dupe(u8, literal.bytes),
        .struct_ => |literal| {
            var out = std.ArrayList(u8).init(allocator);
            errdefer out.deinit();
            for (literal.fields) |field| {
                const field_bytes = (try constValueBytes(allocator, field.value)) orelse return null;
                defer allocator.free(field_bytes);
                try out.appendSlice(field_bytes);
            }
            return try out.toOwnedSlice();
        },
        .vtable => return null,
    }
}

/// VTable constants stay textual: vm.initFunctionsAndVtables parses values that
/// begin with "vtable {" into pointer arrays resolved against program functions.
fn vtableLiteralText(allocator: std.mem.Allocator, literal: sci_const.VTableLiteral) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice("vtable { ");
    for (literal.slots, 0..) |slot, idx| {
        if (idx != 0) try out.appendSlice(", ");
        try out.writer().print("{s} = @{s}", .{ slot.name, slot.func_name });
    }
    try out.appendSlice(" }");
    return try out.toOwnedSlice();
}

fn loadConstants(ctx: Ctx, module: *const sab.Module) !void {
    for (module.const_decls) |*decl| {
        if (ctx.constants.contains(decl.name)) continue;
        if (try constValueBytes(ctx.allocator, decl.value)) |bytes| {
            const key = try ctx.allocator.dupe(u8, decl.name);
            try ctx.constants.put(key, bytes);
        } else {
            const text = try vtableLiteralText(ctx.allocator, decl.value.vtable);
            const key = try ctx.allocator.dupe(u8, decl.name);
            try ctx.constants.put(key, text);
        }
    }
}

const FunctionSigRange = struct {
    sig: *const sci_sig.FunctionSig,
    end: usize,
};

fn functionNameKey(allocator: std.mem.Allocator, sig: *const sci_sig.FunctionSig) ![]u8 {
    // The textual pipeline keys test functions as `test "<name>"` (the header
    // minus '@' and trailing ':'); vm.runTests matches on that "test " prefix.
    if (sig.kind == .test_func) {
        return try std.fmt.allocPrint(allocator, "test {s}", .{sig.name});
    }
    return try allocator.dupe(u8, sig.name);
}

/// True when `needle` occurs in `text` with non-identifier characters (or the
/// string boundaries) on both sides.
fn containsIdentifier(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or text.len < needle.len) return false;
    var idx: usize = 0;
    while (idx + needle.len <= text.len) : (idx += 1) {
        if (!std.mem.eql(u8, text[idx .. idx + needle.len], needle)) continue;
        const before_ok = idx == 0 or !isIdentChar(text[idx - 1]);
        const after_idx = idx + needle.len;
        const after_ok = after_idx == text.len or !isIdentChar(text[after_idx]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The VM binds call arguments positionally into the first N register slots,
/// so Function.params must use the exact register names the body reads. SLA
/// codegen scopes parameter registers as "<fn>__param_<i>_<name>"; textual SA
/// uses the bare parameter name. Resolve each parameter against the body.
fn resolveParamNames(ctx: Ctx, sig: *const sci_sig.FunctionSig, body: []const sci_inst.Instruction) ![]const []const u8 {
    const allocator = ctx.allocator;
    const params = try allocator.alloc([]const u8, sig.params.len);
    var initialized: usize = 0;
    errdefer {
        for (params[0..initialized]) |param| allocator.free(param);
        allocator.free(params);
    }
    for (sig.params, 0..) |param, idx| {
        const scoped = try std.fmt.allocPrint(allocator, "{s}__param_{d}_{s}", .{ sig.name, idx, param.name });
        defer allocator.free(scoped);
        var scoped_used = false;
        for (body) |*item| {
            for (item.operands) |op| {
                switch (op) {
                    .reg, .symbol => |id| {
                        const name = symbolName(ctx, id) catch continue;
                        if (std.mem.eql(u8, name, scoped)) scoped_used = true;
                    },
                    // Call bodies and other folded text reference registers by
                    // name inside e.g. "@sla__double(sla__f__param_0_a)".
                    .text => |text| {
                        if (containsIdentifier(text, scoped)) scoped_used = true;
                    },
                    else => {},
                }
            }
        }
        // The scoped form wins whenever it appears because it cannot collide
        // with another function's locals.
        params[idx] = try allocator.dupe(u8, if (scoped_used) scoped else param.name);
        initialized += 1;
    }
    return params;
}

fn convertFunction(ctx: Ctx, key: []u8, sig: *const sci_sig.FunctionSig, params: []const []const u8, body: []const sci_inst.Instruction) !parser.Function {
    const allocator = ctx.allocator;
    var instructions = std.ArrayList(parser.Instruction).init(allocator);
    errdefer {
        for (instructions.items) |inst| {
            if (inst.dest) |d| allocator.free(d);
            for (inst.args) |arg| allocator.free(arg.name);
            allocator.free(inst.args);
        }
        instructions.deinit();
    }
    var blocks = std.ArrayList(parser.BasicBlock).init(allocator);
    errdefer {
        for (blocks.items) |block| allocator.free(block.label);
        blocks.deinit();
    }

    var param_list = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (param_list.items) |param| allocator.free(param);
        param_list.deinit();
    }
    for (params) |param| {
        try param_list.append(try allocator.dupe(u8, param));
    }

    var open_block: ?usize = null; // index into blocks of the block being filled
    var saw_label = false;
    for (body) |*item| {
        switch (item.kind) {
            .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                // Declaration marker at the head of the body range.
                continue;
            },
            .label => {
                if (open_block) |block_idx| {
                    blocks.items[block_idx].end_inst = instructions.items.len;
                }
                const label_name = try symbolName(ctx, labelIdOf(item) orelse return error.InvalidSabSymbol);
                try blocks.append(.{
                    .label = try allocator.dupe(u8, label_name),
                    .start_inst = instructions.items.len,
                    .end_inst = 0,
                });
                open_block = blocks.items.len - 1;
                saw_label = true;
            },
            else => {
                if (!saw_label) {
                    try blocks.append(.{
                        .label = try allocator.dupe(u8, "__implicit_entry"),
                        .start_inst = instructions.items.len,
                        .end_inst = 0,
                    });
                    open_block = blocks.items.len - 1;
                    saw_label = true;
                }
                try convertInstruction(ctx, item, &instructions);
            },
        }
    }
    if (open_block) |block_idx| {
        blocks.items[block_idx].end_inst = instructions.items.len;
    }

    return .{
        .name = key,
        .params = try param_list.toOwnedSlice(),
        .instructions = try instructions.toOwnedSlice(),
        .blocks = try blocks.toOwnedSlice(),
        .returns_result = sig.return_fallible,
    };
}

fn labelIdOf(item: *const sci_inst.Instruction) ?u64 {
    switch (item.operands[0]) {
        .symbol => |id| return id,
        .label => |id| return id,
        else => return null,
    }
}

fn externSignatureFromSig(allocator: std.mem.Allocator, sig: *const sci_sig.FunctionSig) !parser.ExternSignature {
    var arg_types = std.ArrayList(parser.PrimType).init(allocator);
    errdefer arg_types.deinit();
    for (sig.params) |param| {
        try arg_types.append(try mapPrimType(param.ty));
    }
    // Borrowed/raw returns arrive as pointers at the FFI boundary.
    const return_type: parser.PrimType = switch (sig.return_ty) {
        .void => .void,
        else => switch (sig.return_cap orelse .by_value) {
            .borrow, .raw => .ptr,
            else => try mapPrimType(sig.return_ty),
        },
    };
    return .{
        .arg_types = try arg_types.toOwnedSlice(),
        .return_type = return_type,
        .returns_result = sig.return_fallible,
    };
}

/// Decode a SAB v4 module into a VM Program. All memory is owned by the
/// returned Program and released by its deinit(); caller keeps ownership of
/// nothing from `bytes`.
pub fn loadProgram(allocator: std.mem.Allocator, bytes: []const u8) anyerror!*parser.Program {
    var module = try sab.decodeModule(allocator, bytes);
    defer module.deinit(allocator);

    const prog = try allocator.create(parser.Program);
    // Frees every constant/function/extern inserted below plus the Program.
    errdefer prog.deinit();
    prog.* = .{
        .constants = std.StringHashMap([]const u8).init(allocator),
        .functions = std.StringHashMap(parser.Function).init(allocator),
        .externs = std.StringHashMap(parser.ExternSignature).init(allocator),
        .allocator = allocator,
    };

    const ctx = Ctx{
        .allocator = allocator,
        .symbols = module.symbols,
        .constants = &prog.constants,
    };
    try loadConstants(ctx, &module);

    // Function bodies are delimited by entry_inst_idx in the flat stream.
    const ranges = try allocator.alloc(FunctionSigRange, module.function_sigs.len);
    defer allocator.free(ranges);
    for (module.function_sigs, 0..) |*sig, idx| {
        ranges[idx] = .{ .sig = sig, .end = module.instructions.len };
    }
    for (ranges, 0..) |range, idx| {
        for (ranges[idx + 1 ..]) |other| {
            if (other.sig.entry_inst_idx < range.end) {
                ranges[idx].end = other.sig.entry_inst_idx;
            }
        }
        if (range.sig.entry_inst_idx > range.end) return error.TruncatedSab;
    }

    for (ranges) |range| {
        const sig = range.sig;
        const body = module.instructions[sig.entry_inst_idx..range.end];
        switch (sig.kind) {
            .external => {
                const key = try allocator.dupe(u8, sig.name);
                errdefer allocator.free(key);
                const signature = try externSignatureFromSig(allocator, sig);
                errdefer allocator.free(signature.arg_types);
                try prog.externs.put(key, signature);
            },
            .normal, .exported, .test_func, .ffi_wrapper => {
                const key = try functionNameKey(allocator, sig);
                errdefer allocator.free(key);
                const params = try resolveParamNames(ctx, sig, body);
                errdefer {
                    for (params) |param| allocator.free(param);
                    allocator.free(params);
                }
                const func = try convertFunction(ctx, key, sig, params, body);
                // convertFunction dupes the resolved names; release ours.
                for (params) |param| allocator.free(param);
                allocator.free(params);
                // func.name must alias the map key: Program.deinit frees the
                // key but not Function.name.
                try prog.functions.put(key, func);
            },
        }
    }

    return prog;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testSig(id: u32, name: []const u8, kind: sci_sig.FunctionKind, entry: u32, params: []const sci_sig.ParamSpec) sci_sig.FunctionSig {
    return .{
        .id = id,
        .name = name,
        .params = @constCast(params),
        .kind = kind,
        .return_cap = null,
        .return_ty = .void,
        .return_fallible = false,
        .entry_inst_idx = entry,
        .is_ffi_wrapper = false,
    };
}

fn testInst(kind: sci_inst.InstKind) sci_inst.Instruction {
    return sci_inst.makeInstruction(kind, 1, 0, null, "");
}

test "sab magic detection" {
    try testing.expect(isSabMagic("SAB\x00rest"));
    try testing.expect(!isSabMagic("SABX"));
    try testing.expect(!isSabMagic("SA"));
    try testing.expect(!isSabMagic("// not bytecode"));
}

test "loadProgram converts assign, arithmetic, branches and blocks" {
    const allocator = testing.allocator;
    const symbols = [_][]const u8{ "main", "x", "y", "L_ENTRY", "L_EXIT" };
    var decl = testInst(.func_decl);
    decl.operands[0] = .{ .symbol = 0 };
    decl.operands[1] = .{ .func = 0 };

    var label = testInst(.label);
    label.operands[0] = .{ .symbol = 3 };
    label.operands[1] = .{ .label = 3 };

    var assign = testInst(.assign);
    assign.operands[0] = .{ .reg = 1 };
    assign.operands[1] = .{ .imm_i64 = 7 };

    var add = testInst(.op);
    add.op_kind = .add;
    add.operands[0] = .{ .reg = 2 };
    add.operands[1] = .{ .reg = 1 };
    add.operands[2] = .{ .imm_i64 = 3 };

    var branch = testInst(.br);
    branch.operands[0] = .{ .reg = 2 };
    branch.operands[1] = .{ .label = 4 };
    branch.operands[2] = .{ .label = 4 };
    branch.operands[3] = .{ .label = 3 };

    var ret = testInst(.return_);
    ret.operands[0] = .{ .reg = 2 };

    var jmp = testInst(.jmp);
    jmp.operands[0] = .{ .symbol = 4 };
    jmp.operands[1] = .{ .label = 4 };

    var exit_label = testInst(.label);
    exit_label.operands[0] = .{ .symbol = 4 };
    exit_label.operands[1] = .{ .label = 4 };

    const sigs = [_]sci_sig.FunctionSig{testSig(0, "main", .normal, 0, &.{})};
    const insts = [_]sci_inst.Instruction{ decl, label, assign, add, branch, ret, exit_label, jmp };
    const bytes = try sab.encodeProgramWithConsts(allocator, symbols[0..], &.{}, sigs[0..], insts[0..]);
    defer allocator.free(bytes);

    const prog = try loadProgram(allocator, bytes);
    defer prog.deinit();

    const func = prog.functions.get("main") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 5), func.instructions.len);
    try testing.expectEqual(parser.OpCode.assign, func.instructions[0].op);
    try testing.expectEqualStrings("x", func.instructions[0].dest.?);
    try testing.expectEqual(@as(u64, 7), func.instructions[0].args[0].imm_val);

    try testing.expectEqual(parser.OpCode.add, func.instructions[1].op);
    try testing.expectEqualStrings("y", func.instructions[1].dest.?);
    try testing.expectEqualStrings("x", func.instructions[1].args[0].name);
    try testing.expectEqual(@as(u64, 3), func.instructions[1].args[1].imm_val);

    const br_inst = func.instructions[2];
    try testing.expectEqual(parser.OpCode.br, br_inst.op);
    try testing.expectEqualStrings("L_EXIT", br_inst.args[1].name);
    try testing.expectEqualStrings("L_ENTRY", br_inst.args[2].name);

    try testing.expectEqual(parser.OpCode.return_, func.instructions[3].op);
    try testing.expectEqual(parser.OpCode.jmp, func.instructions[4].op);
    try testing.expectEqualStrings("L_EXIT", func.instructions[4].args[0].name);

    try testing.expectEqual(@as(usize, 2), func.blocks.len);
    try testing.expectEqualStrings("L_ENTRY", func.blocks[0].label);
    try testing.expectEqual(@as(usize, 0), func.blocks[0].start_inst);
    try testing.expectEqual(@as(usize, 4), func.blocks[0].end_inst);
    try testing.expectEqualStrings("L_EXIT", func.blocks[1].label);
    try testing.expectEqual(@as(usize, 4), func.blocks[1].start_inst);
    try testing.expectEqual(@as(usize, 5), func.blocks[1].end_inst);
}

test "loadProgram re-parses call bodies and splits function bodies" {
    const allocator = testing.allocator;
    // symbols: 0=main 1=out 2=addf 3=L_ENTRY 4=a 5=b 6=sum 7=arg_a 8=arg_b 9=L_BODY
    const symbols = [_][]const u8{ "main", "out", "addf", "L_ENTRY", "a", "b", "sum", "arg_a", "arg_b", "L_BODY" };
    var main_decl = testInst(.func_decl);
    main_decl.operands[0] = .{ .symbol = 0 };
    main_decl.operands[1] = .{ .func = 0 };

    var main_label = testInst(.label);
    main_label.operands[0] = .{ .symbol = 3 };
    main_label.operands[1] = .{ .label = 3 };

    var call = testInst(.call);
    call.operands[0] = .{ .reg = 1 };
    call.operands[1] = .{ .text = "@addf(&arg_a, arg_b)" };

    var main_ret = testInst(.return_);
    main_ret.operands[0] = .{ .reg = 1 };

    var addf_decl = testInst(.func_decl);
    addf_decl.operands[0] = .{ .symbol = 2 };
    addf_decl.operands[1] = .{ .func = 2 };

    var addf_label = testInst(.label);
    addf_label.operands[0] = .{ .symbol = 9 };
    addf_label.operands[1] = .{ .label = 9 };

    var sum_op = testInst(.op);
    sum_op.op_kind = .add;
    sum_op.operands[0] = .{ .reg = 6 };
    sum_op.operands[1] = .{ .reg = 4 };
    sum_op.operands[2] = .{ .reg = 5 };

    var addf_ret = testInst(.return_);
    addf_ret.operands[0] = .{ .reg = 6 };

    var param_a = [_]sci_sig.ParamSpec{
        .{ .name = "a", .ty = .u64, .cap = .borrow },
        .{ .name = "b", .ty = .u64, .cap = .by_value },
    };
    const sigs = [_]sci_sig.FunctionSig{
        testSig(0, "main", .normal, 0, &.{}),
        testSig(1, "addf", .normal, 4, param_a[0..]),
    };
    const insts = [_]sci_inst.Instruction{ main_decl, main_label, call, main_ret, addf_decl, addf_label, sum_op, addf_ret };
    const bytes = try sab.encodeProgramWithConsts(allocator, symbols[0..], &.{}, sigs[0..], insts[0..]);
    defer allocator.free(bytes);

    const prog = try loadProgram(allocator, bytes);
    defer prog.deinit();

    try testing.expectEqual(@as(usize, 2), prog.functions.count());

    const main_func = prog.functions.get("main") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), main_func.instructions.len);
    const call_inst = main_func.instructions[0];
    try testing.expectEqual(parser.OpCode.call, call_inst.op);
    try testing.expectEqualStrings("out", call_inst.dest.?);
    try testing.expectEqual(parser.OperandKind.label, call_inst.args[0].kind);
    try testing.expectEqualStrings("addf", call_inst.args[0].name);
    try testing.expectEqual(parser.OperandKind.stack_addr, call_inst.args[1].kind);
    try testing.expectEqualStrings("arg_a", call_inst.args[1].name);
    try testing.expectEqualStrings("arg_b", call_inst.args[2].name);

    const addf = prog.functions.get("addf") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), addf.params.len);
    try testing.expectEqualStrings("a", addf.params[0]);
    try testing.expectEqualStrings("b", addf.params[1]);
    try testing.expectEqual(@as(usize, 1), addf.blocks.len);
    try testing.expectEqualStrings("L_BODY", addf.blocks[0].label);
}

test "loadProgram keeps div semantics and maps externs and consts" {
    const allocator = testing.allocator;
    const symbols = [_][]const u8{ "main", "q", "sa_print_bytes", "STR_HELLO", "&STR_HELLO", "n" };
    var decl = testInst(.func_decl);
    decl.operands[0] = .{ .symbol = 0 };
    decl.operands[1] = .{ .func = 0 };

    var sdiv_op = testInst(.op);
    sdiv_op.op_kind = .sdiv;
    sdiv_op.operands[0] = .{ .reg = 1 };
    sdiv_op.operands[1] = .{ .imm_i64 = -7 };
    sdiv_op.operands[2] = .{ .reg = 5 };

    var udiv_op = testInst(.op);
    udiv_op.op_kind = .udiv;
    udiv_op.operands[0] = .{ .reg = 1 };
    udiv_op.operands[1] = .{ .imm_u64 = 9 };
    udiv_op.operands[2] = .{ .reg = 5 };

    var load_const = testInst(.load);
    load_const.operands[0] = .{ .reg = 1 };
    load_const.operands[1] = .{ .reg = 4 }; // "&STR_HELLO" folded reg name
    load_const.operands[2] = .{ .imm_u64 = 0 };
    load_const.operands[3] = .{ .ty = @intFromEnum(sci_sig.PrimType.u8) };

    var store = testInst(.store);
    store.operands[0] = .{ .reg = 1 };
    store.operands[1] = .{ .imm_u64 = 4 };
    store.operands[2] = .{ .text = "n" };
    store.operands[3] = .{ .ty = @intFromEnum(sci_sig.PrimType.i32) };

    var ret = testInst(.return_);
    ret.operands[0] = .{ .none = {} };

    const sigs = [_]sci_sig.FunctionSig{
        testSig(0, "main", .normal, 0, &.{}),
        testSig(1, "sa_print_bytes", .external, 6, &.{
            .{ .name = "ptr", .ty = .ptr, .cap = .borrow },
            .{ .name = "len", .ty = .u64, .cap = .by_value },
        }),
    };
    const insts = [_]sci_inst.Instruction{ decl, sdiv_op, udiv_op, load_const, store, ret };
    const bytes = try sab.encodeProgramWithConsts(allocator, symbols[0..], &.{}, sigs[0..], insts[0..]);
    defer allocator.free(bytes);

    const prog = try loadProgram(allocator, bytes);
    defer prog.deinit();

    const func = prog.functions.get("main") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(parser.OpCode.sdiv, func.instructions[0].op);
    try testing.expectEqual(parser.OpCode.udiv, func.instructions[1].op);

    const load_inst = func.instructions[2];
    try testing.expectEqual(parser.OpCode.load, load_inst.op);
    try testing.expectEqual(parser.PrimType.u8, load_inst.dest_type);
    try testing.expectEqual(parser.OperandKind.constant_addr, load_inst.args[0].kind);
    try testing.expectEqualStrings("STR_HELLO", load_inst.args[0].name);

    const store_inst = func.instructions[3];
    try testing.expectEqual(parser.OpCode.store, store_inst.op);
    try testing.expectEqual(parser.PrimType.i32, store_inst.dest_type);
    try testing.expectEqual(parser.OperandKind.register, store_inst.args[0].kind);
    try testing.expectEqualStrings("n", store_inst.args[0].name);
    try testing.expectEqual(@as(i32, 4), store_inst.args[1].offset);

    try testing.expectEqual(@as(usize, 1), prog.externs.count());
    const ext = prog.externs.get("sa_print_bytes") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), ext.arg_types.len);
    try testing.expectEqual(parser.PrimType.ptr, ext.arg_types[0]);
    try testing.expectEqual(parser.PrimType.u64, ext.arg_types[1]);
}

test "loadProgram decodes const decls including vtables" {
    const allocator = testing.allocator;
    const symbols = [_][]const u8{ "main", "vt", "&VT", "Shape_draw", "draw" };
    var decl = testInst(.func_decl);
    decl.operands[0] = .{ .symbol = 0 };
    decl.operands[1] = .{ .func = 0 };

    var assign = testInst(.assign);
    assign.operands[0] = .{ .reg = 1 };
    assign.operands[1] = .{ .reg = 2 }; // folded name "&VT"

    var ret = testInst(.return_);
    ret.operands[0] = .{ .none = {} };

    var slots = try allocator.alloc(sci_const.VTableSlot, 1);
    slots[0] = .{
        .name = try allocator.dupe(u8, "draw"),
        .func_name = try allocator.dupe(u8, "Shape_draw"),
    };

    // Released through ConstDecl.deinit below.
    const utf8_bytes = try allocator.dupe(u8, "hi");

    var consts = [_]sci_const.ConstDecl{
        .{
            .source_line = 1,
            .expanded_line = 1,
            .upstream_loc = null,
            .raw_text = try allocator.dupe(u8, "@const STR_HELLO = utf8:\"hi\""),
            .name = try allocator.dupe(u8, "STR_HELLO"),
            .literal_text = try allocator.dupe(u8, "utf8:\"hi\""),
            .value = .{ .utf8 = .{ .kind = .utf8, .bytes = utf8_bytes } },
        },
        .{
            .source_line = 2,
            .expanded_line = 2,
            .upstream_loc = null,
            .raw_text = try allocator.dupe(u8, "@const VT = vtable { draw = @Shape_draw }"),
            .name = try allocator.dupe(u8, "VT"),
            .literal_text = try allocator.dupe(u8, "vtable { draw = @Shape_draw }"),
            .value = .{ .vtable = .{ .slots = slots } },
        },
    };
    defer for (consts[0..]) |*c| c.deinit(allocator);

    const sigs = [_]sci_sig.FunctionSig{testSig(0, "main", .normal, 0, &.{})};
    const insts = [_]sci_inst.Instruction{ decl, assign, ret };
    const bytes = try sab.encodeProgramWithConsts(allocator, symbols[0..], consts[0..], sigs[0..], insts[0..]);
    defer allocator.free(bytes);

    const prog = try loadProgram(allocator, bytes);
    defer prog.deinit();

    try testing.expectEqualStrings("hi", prog.constants.get("STR_HELLO").?);
    const vt_value = prog.constants.get("VT").?;
    try testing.expect(std.mem.startsWith(u8, vt_value, "vtable { "));
    try testing.expect(std.mem.indexOf(u8, vt_value, "draw = @Shape_draw") != null);

    const func = prog.functions.get("main") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(parser.OperandKind.constant_addr, func.instructions[0].args[0].kind);
    try testing.expectEqualStrings("VT", func.instructions[0].args[0].name);
}

// Folded `str_eq` of two literals emits `borrow tmp, CONST` with the constant
// name as a BARE symbol (no '&' marker), which must stay a .register operand
// here; vm.zig's binding pass resolves it to the constant address (mirroring
// sci/src/interp.zig readValue). If the loader ever started rewriting it into
// .constant_addr itself, that fallback would silently stop being exercised.
test "loadProgram keeps bare const names as register operands" {
    const allocator = testing.allocator;
    const symbols = [_][]const u8{ "main", "tmp_1", "tmp_2", "SLA_STR_A", "&SLA_STR_A" };

    var decl = testInst(.func_decl);
    decl.operands[0] = .{ .symbol = 0 };
    decl.operands[1] = .{ .func = 0 };

    var borrow = testInst(.borrow);
    borrow.operands[0] = .{ .reg = 1 };
    borrow.operands[1] = .{ .symbol = 3 }; // bare const name

    var cmp = testInst(.op);
    cmp.op_kind = .eq;
    cmp.operands[0] = .{ .reg = 2 };
    cmp.operands[1] = .{ .reg = 1 };
    cmp.operands[2] = .{ .symbol = 4 }; // '&'-marked const address

    var ret = testInst(.return_);
    ret.operands[0] = .{ .none = {} };

    const utf8_bytes = try allocator.dupe(u8, "alpha\x00");
    var consts = [_]sci_const.ConstDecl{.{
        .source_line = 1,
        .expanded_line = 1,
        .upstream_loc = null,
        .raw_text = try allocator.dupe(u8, "@const SLA_STR_A = utf8:\"alpha\\0\""),
        .name = try allocator.dupe(u8, "SLA_STR_A"),
        .literal_text = try allocator.dupe(u8, "utf8:\"alpha\\0\""),
        .value = .{ .utf8 = .{ .kind = .utf8, .bytes = utf8_bytes } },
    }};
    defer for (consts[0..]) |*c| c.deinit(allocator);

    const sigs = [_]sci_sig.FunctionSig{testSig(0, "main", .normal, 0, &.{})};
    const insts = [_]sci_inst.Instruction{ decl, borrow, cmp, ret };
    const bytes = try sab.encodeProgramWithConsts(allocator, symbols[0..], consts[0..], sigs[0..], insts[0..]);
    defer allocator.free(bytes);

    const prog = try loadProgram(allocator, bytes);
    defer prog.deinit();

    try testing.expectEqualStrings("alpha\x00", prog.constants.get("SLA_STR_A").?);

    const func = prog.functions.get("main") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(parser.OpCode.assume_borrow, func.instructions[0].op);
    try testing.expectEqual(parser.OperandKind.register, func.instructions[0].args[0].kind);
    try testing.expectEqualStrings("SLA_STR_A", func.instructions[0].args[0].name);

    try testing.expectEqual(parser.OpCode.eq, func.instructions[1].op);
    try testing.expectEqual(parser.OperandKind.constant_addr, func.instructions[1].args[1].kind);
    try testing.expectEqualStrings("SLA_STR_A", func.instructions[1].args[1].name);
}

test "loadProgram rejects unsupported instructions with descriptive errors" {
    const allocator = testing.allocator;

    const buildAndLoad = struct {
        fn run(alloc: std.mem.Allocator, item: sci_inst.Instruction) !*parser.Program {
            var decl = testInst(.func_decl);
            decl.operands[0] = .{ .symbol = 0 };
            decl.operands[1] = .{ .func = 0 };
            var ret = testInst(.return_);
            ret.operands[0] = .{ .none = {} };
            const syms = [_][]const u8{"main"};
            const sigs = [_]sci_sig.FunctionSig{testSig(0, "main", .normal, 0, &.{})};
            const insts = [_]sci_inst.Instruction{ decl, item, ret };
            const data = try sab.encodeProgramWithConsts(alloc, syms[0..], &.{}, sigs[0..], insts[0..]);
            defer alloc.free(data);
            return loadProgram(alloc, data);
        }
    }.run;

    var fadd_op = testInst(.op);
    fadd_op.op_kind = .fadd;
    fadd_op.operands[0] = .{ .reg = 0 };
    fadd_op.operands[1] = .{ .reg = 0 };
    fadd_op.operands[2] = .{ .reg = 0 };

    var fneg_op = testInst(.op);
    fneg_op.op_kind = .fneg;
    fneg_op.operands[0] = .{ .reg = 0 };
    fneg_op.operands[1] = .{ .reg = 0 };

    var fptrunc_op = testInst(.op);
    fptrunc_op.op_kind = .fptrunc;
    fptrunc_op.operands[0] = .{ .reg = 0 };
    fptrunc_op.operands[1] = .{ .reg = 0 };
    fptrunc_op.operands[2] = .{ .ty = @intFromEnum(sci_sig.PrimType.f32) };

    var ashr_op = testInst(.op);
    ashr_op.op_kind = .ashr;
    ashr_op.operands[0] = .{ .reg = 0 };
    ashr_op.operands[1] = .{ .reg = 0 };
    ashr_op.operands[2] = .{ .imm_i64 = 1 };

    // Float arithmetic/comparison, unary ops and conversions are interpreted.
    {
        const prog = try buildAndLoad(allocator, fadd_op);
        defer prog.deinit();
        const func = prog.functions.get("main") orelse return error.TestUnexpectedResult;
        try testing.expectEqual(parser.OpCode.fadd, func.instructions[0].op);
        try testing.expectEqual(@as(usize, 2), func.instructions[0].args.len);
    }
    {
        const prog = try buildAndLoad(allocator, fneg_op);
        defer prog.deinit();
        const func = prog.functions.get("main") orelse return error.TestUnexpectedResult;
        try testing.expectEqual(parser.OpCode.fneg, func.instructions[0].op);
        // Unary ops keep only their single source operand.
        try testing.expectEqual(@as(usize, 1), func.instructions[0].args.len);
    }
    {
        const prog = try buildAndLoad(allocator, fptrunc_op);
        defer prog.deinit();
        const func = prog.functions.get("main") orelse return error.TestUnexpectedResult;
        try testing.expectEqual(parser.OpCode.fptrunc, func.instructions[0].op);
        try testing.expectEqual(parser.PrimType.f32, func.instructions[0].dest_type);
    }
    {
        const prog = try buildAndLoad(allocator, ashr_op);
        defer prog.deinit();
        const func = prog.functions.get("main") orelse return error.TestUnexpectedResult;
        try testing.expectEqual(parser.OpCode.ashr, func.instructions[0].op);
    }

    var simd_op = testInst(.op);
    simd_op.op_kind = .add_v128;
    simd_op.operands[0] = .{ .reg = 0 };
    simd_op.operands[1] = .{ .reg = 0 };
    simd_op.operands[2] = .{ .reg = 0 };
    try testing.expectError(error.UnsupportedSabSimdOp, buildAndLoad(allocator, simd_op));

    // fence is a no-op in the single-threaded interpreter and must load fine.
    {
        const prog = try buildAndLoad(allocator, testInst(.fence));
        prog.deinit();
    }
    try testing.expectError(error.UnsupportedSabInstruction, buildAndLoad(allocator, testInst(.br_null)));
    try testing.expectError(error.UnsupportedSabInstruction, buildAndLoad(allocator, testInst(.early_return)));
    try testing.expectError(error.UnsupportedSabNativeInst, buildAndLoad(allocator, testInst(.native)));

    // Float immediates decode to the raw IEEE-754 bits of the f64 value.
    var float_assign = testInst(.assign);
    float_assign.operands[0] = .{ .reg = 0 };
    float_assign.operands[1] = .{ .imm_float = 1.5 };
    {
        const prog = try buildAndLoad(allocator, float_assign);
        defer prog.deinit();
        const func = prog.functions.get("main") orelse return error.TestUnexpectedResult;
        const arg = func.instructions[0].args[0];
        try testing.expectEqual(parser.OperandKind.immediate, arg.kind);
        try testing.expectEqual(@as(u64, @bitCast(@as(f64, 1.5))), arg.imm_val);
    }
}






