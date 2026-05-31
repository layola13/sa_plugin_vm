const std = @import("std");
const plugin_api = @import("plugin_api");
const parser = @import("parser.zig");
const ffi = @import("ffi.zig");
const vm = @import("vm.zig");

const skills = [_]plugin_api.SkillSection{
    .{
        .name = "vm",
        .summary = "Dynamic interpreter VM for running SA assembly files directly",
        .items = &.{
            "vm run <file.sa>",
            "Direct interpretation without compilation",
            "Full dynamic FFI compatibility with installed plugins",
        },
    },
};

const StreamCtx = struct {
    stream: plugin_api.HostStream,
};

fn writeAll(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
    const self = @as(*const StreamCtx, @ptrCast(@alignCast(ctx)));
    const write_all = self.stream.write_all orelse return error.WriteFailed;
    if (write_all(self.stream.ctx, bytes.ptr, bytes.len) != @intFromEnum(plugin_api.AbiStatus.ok)) return error.WriteFailed;
    return bytes.len;
}

fn cArgvToSlice(argv: []const [*:0]const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(out);
    for (argv, 0..) |arg, idx| {
        out[idx] = std.mem.span(arg);
    }
    return out;
}

fn runVmCommand(allocator: std.mem.Allocator, ctx: *const plugin_api.Context, argv: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) anyerror!?u8 {
    _ = stdout;
    _ = ctx;
    if (argv.len < 2) return null;
    if (!std.mem.eql(u8, argv[1], "vm")) return null;
    if (argv.len < 4 or !std.mem.eql(u8, argv[2], "run")) {
        try stderr.print("Usage: sa vm run [--allow-ffi] <file.sa>\n", .{});
        return 1;
    }

    var allow_ffi = false;
    var file_path: ?[]const u8 = null;

    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--allow-ffi")) {
            allow_ffi = true;
        } else {
            file_path = argv[i];
            break; // Stop parsing flags after the file path
        }
    }

    if (file_path == null) {
        try stderr.print("Usage: sa vm run [--allow-ffi] <file.sa>\n", .{});
        return 1;
    }

    var parser_arena = std.heap.ArenaAllocator.init(allocator);
    defer parser_arena.deinit();
    const parse_allocator = parser_arena.allocator();

    var parser_inst = parser.Parser.init(parse_allocator);
    defer parser_inst.deinit();

    const preprocessed = parser_inst.preprocess(file_path.?) catch |err| {
        try stderr.print("Preprocessing failed: {}\n", .{err});
        return 1;
    };

    const prog = parser_inst.parse(preprocessed) catch |err| {
        try stderr.print("Parsing failed: {}\n", .{err});
        return 1;
    };
    defer {
        prog.deinit();
    }

    var ffi_mgr = ffi.FfiManager.init(parse_allocator);
    ffi_mgr.allow_ffi = allow_ffi;
    defer ffi_mgr.deinit();

    ffi_mgr.loadDeclaredDependencies() catch |err| {
        try stderr.print("Loading plugins failed: {}\n", .{err});
        return 1;
    };

    var vm_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = vm_gpa.deinit();
    const vm_allocator = vm_gpa.allocator();

    var vm_inst = vm.VM.init(vm_allocator, prog, &ffi_mgr);
    defer vm_inst.deinit();
    const code = vm_inst.run() catch |err| {
        try stderr.print("VM Execution failed: {}\n", .{err});
        return 1;
    };

    const code_u32: u32 = @bitCast(code);
    return @truncate(code_u32);
}

fn runVmCommandAbi(ctx: *const plugin_api.Context, argv: [*]const [*:0]const u8, argv_len: usize, stdout: plugin_api.HostStream, stderr: plugin_api.HostStream, out_code: *u8) callconv(.c) u32 {
    out_code.* = 0;
    var stdout_ctx = StreamCtx{ .stream = stdout };
    var stderr_ctx = StreamCtx{ .stream = stderr };
    const stdout_writer = std.io.AnyWriter{ .context = &stdout_ctx, .writeFn = writeAll };
    const stderr_writer = std.io.AnyWriter{ .context = &stderr_ctx, .writeFn = writeAll };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = cArgvToSlice(argv[0..argv_len], allocator) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    defer allocator.free(args);

    const result = runVmCommand(allocator, ctx, args, stdout_writer, stderr_writer) catch |err| {
        stderr_writer.print("error[VM-CLI]: {}\n", .{err}) catch {};
        out_code.* = 1;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    };
    if (result) |code| {
        out_code.* = code;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    }
    return @intFromEnum(plugin_api.AbiStatus.unknown_command);
}

const descriptor = plugin_api.PluginDescriptor{
    .abi_version = plugin_api.abi_version,
    .descriptor_size = @as(u32, @intCast(@sizeOf(plugin_api.PluginDescriptor))),
    .name = "vm",
    .init = null,
    .prebuild = null,
    .postbuild = null,
    .handle_command = runVmCommandAbi,
    .skills_ptr = skills[0..].ptr,
    .skills_len = skills.len,
};

pub export var saasm_plugin_descriptor_v1: plugin_api.PluginDescriptor = descriptor;

pub export fn saasm_plugin_descriptor_v1_fn(out: *plugin_api.PluginDescriptor) callconv(.c) void {
    out.* = saasm_plugin_descriptor_v1;
}
