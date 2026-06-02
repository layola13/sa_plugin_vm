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
            "vm test <file.sa>",
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

inline fn nowNs() u64 {
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}

inline fn elapsedNs(start: u64) u64 {
    return nowNs() -% start;
}

fn envFlagSet(allocator: std.mem.Allocator, name: []const u8) bool {
    const value = std.process.getEnvVarOwned(allocator, name) catch return false;
    defer allocator.free(value);
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;
    return true;
}

fn parseProfileTop(raw: []const u8) !u16 {
    const value = try std.fmt.parseInt(u16, raw, 10);
    if (value == 0) return error.InvalidProfileLimit;
    return value;
}

fn vmPreprocessCacheRoot(allocator: std.mem.Allocator) !?[]const u8 {
    if (std.process.getEnvVarOwned(allocator, "SA_CACHE")) |cache_root| {
        defer allocator.free(cache_root);
        return try std.fs.path.join(allocator, &.{ cache_root, "vm", "preprocess" });
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return try std.fs.path.join(allocator, &.{ home, ".cache", "sa", "vm", "preprocess" });
    } else |_| {}

    return null;
}

const ParseCacheStatus = enum {
    disabled,
    hit,
    miss,
    clone_failed,
    store_failed,

    fn label(self: ParseCacheStatus) []const u8 {
        return switch (self) {
            .disabled => "disabled",
            .hit => "hit",
            .miss => "miss",
            .clone_failed => "clone_failed",
            .store_failed => "store_failed",
        };
    }
};

const PARSE_CACHE_MAX_ENTRIES = 8;

const ParseCacheEntry = struct {
    key: u64 = 0,
    age: u64 = 0,
    program: ?*parser.Program = null,
};

var parse_cache_mutex: std.Thread.Mutex = .{};
var parse_cache_clock: u64 = 0;
var parse_cache_entries: [PARSE_CACHE_MAX_ENTRIES]ParseCacheEntry = [_]ParseCacheEntry{.{}} ** PARSE_CACHE_MAX_ENTRIES;

fn mixBytes(seed: u64, bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(seed, bytes);
}

fn mixU64(seed: u64, value: u64) u64 {
    var v = value;
    return mixBytes(seed, std.mem.asBytes(&v));
}

fn parseCacheFingerprint(preprocessed: [][]const u8, constants: *std.StringHashMap([]const u8)) u64 {
    var hash = mixBytes(0, "sa-vm-parse-cache-v1");
    hash = mixU64(hash, @as(u64, @intCast(preprocessed.len)));
    for (preprocessed) |line| {
        hash = mixU64(hash, @as(u64, @intCast(line.len)));
        hash = mixBytes(hash, line);
    }

    var const_count: u64 = 0;
    var const_sum: u64 = 0;
    var const_xor: u64 = 0;
    var const_it = constants.iterator();
    while (const_it.next()) |entry| {
        var entry_hash = mixBytes(0x9e3779b97f4a7c15, "const");
        entry_hash = mixU64(entry_hash, @as(u64, @intCast(entry.key_ptr.*.len)));
        entry_hash = mixBytes(entry_hash, entry.key_ptr.*);
        entry_hash = mixU64(entry_hash, @as(u64, @intCast(entry.value_ptr.*.len)));
        entry_hash = mixBytes(entry_hash, entry.value_ptr.*);
        const_count +%= 1;
        const_sum +%= entry_hash;
        const_xor ^= entry_hash;
    }
    hash = mixU64(hash, const_count);
    hash = mixU64(hash, const_sum);
    hash = mixU64(hash, const_xor);
    return hash;
}

fn parseCacheLookupClone(allocator: std.mem.Allocator, key: u64) !?*parser.Program {
    parse_cache_mutex.lock();
    defer parse_cache_mutex.unlock();

    for (&parse_cache_entries) |*entry| {
        if (entry.program) |cached| {
            if (entry.key == key) {
                parse_cache_clock +%= 1;
                entry.age = parse_cache_clock;
                return try parser.cloneProgram(allocator, cached);
            }
        }
    }
    return null;
}

fn parseCacheStore(key: u64, prog: *const parser.Program) !void {
    const cached = try parser.cloneProgram(std.heap.c_allocator, prog);
    errdefer cached.deinit();

    parse_cache_mutex.lock();
    defer parse_cache_mutex.unlock();

    parse_cache_clock +%= 1;
    var target = &parse_cache_entries[0];
    var oldest: u64 = std.math.maxInt(u64);
    for (&parse_cache_entries) |*entry| {
        if (entry.program == null) {
            target = entry;
            break;
        }
        if (entry.key == key) {
            target = entry;
            break;
        }
        if (entry.age < oldest) {
            oldest = entry.age;
            target = entry;
        }
    }
    if (target.program) |old| old.deinit();
    target.* = .{
        .key = key,
        .age = parse_cache_clock,
        .program = cached,
    };
}

fn clearParseCacheForTest() void {
    parse_cache_mutex.lock();
    defer parse_cache_mutex.unlock();
    for (&parse_cache_entries) |*entry| {
        if (entry.program) |cached| cached.deinit();
        entry.* = .{};
    }
    parse_cache_clock = 0;
}

fn runVmCommand(allocator: std.mem.Allocator, ctx: *const plugin_api.Context, argv: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) anyerror!?u8 {
    _ = stdout;
    _ = ctx;
    const total_start = nowNs();
    if (argv.len < 2) return null;
    if (!std.mem.eql(u8, argv[1], "vm")) return null;
    if (argv.len < 4 or (!std.mem.eql(u8, argv[2], "run") and !std.mem.eql(u8, argv[2], "test"))) {
        try stderr.print("Usage: sa vm <run|test> [--allow-ffi] [--stats] [--profile=N] <file.sa>\n", .{});
        return 1;
    }

    const run_tests = std.mem.eql(u8, argv[2], "test");

    var allow_ffi = false;
    var show_stats = false;
    var profile_top_n: u16 = 0;
    var file_path: ?[]const u8 = null;

    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--allow-ffi")) {
            allow_ffi = true;
        } else if (std.mem.eql(u8, argv[i], "--stats")) {
            show_stats = true;
        } else if (std.mem.startsWith(u8, argv[i], "--profile=")) {
            profile_top_n = parseProfileTop(argv[i]["--profile=".len..]) catch |err| {
                try stderr.print("Invalid --profile value: {}\n", .{err});
                return 1;
            };
        } else if (std.mem.eql(u8, argv[i], "--profile")) {
            i += 1;
            if (i >= argv.len) {
                try stderr.print("Missing value for --profile\n", .{});
                return 1;
            }
            profile_top_n = parseProfileTop(argv[i]) catch |err| {
                try stderr.print("Invalid --profile value: {}\n", .{err});
                return 1;
            };
        } else if (std.mem.startsWith(u8, argv[i], "--")) {
            try stderr.print("Unknown vm option: {s}\n", .{argv[i]});
            return 1;
        } else {
            file_path = argv[i];
            break; // Stop parsing flags after the file path
        }
    }

    if (file_path == null) {
        try stderr.print("Usage: sa vm <run|test> [--allow-ffi] [--stats] [--profile=N] <file.sa>\n", .{});
        return 1;
    }

    var parser_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer parser_arena.deinit();
    const parse_allocator = parser_arena.allocator();

    var parser_inst = parser.Parser.init(parse_allocator);
    defer parser_inst.deinit();

    const preprocess_cache_root = if (envFlagSet(allocator, "SA_VM_DISABLE_PREPROCESS_CACHE")) null else try vmPreprocessCacheRoot(allocator);
    defer if (preprocess_cache_root) |root| allocator.free(root);

    const preprocess_start = nowNs();
    const preprocessed = parser_inst.preprocessWithCache(file_path.?, preprocess_cache_root) catch |err| {
        try stderr.print("Preprocessing failed: {}\n", .{err});
        return 1;
    };
    const preprocess_ns = elapsedNs(preprocess_start);

    const parse_cache_enabled = !envFlagSet(allocator, "SA_VM_DISABLE_PARSE_CACHE");
    const parse_cache_key = if (parse_cache_enabled) parseCacheFingerprint(preprocessed, &parser_inst.constants) else 0;
    var parse_cache_status: ParseCacheStatus = if (parse_cache_enabled) .miss else .disabled;

    const parse_start = nowNs();
    const prog = blk: {
        if (parse_cache_enabled) {
            if (parseCacheLookupClone(parse_allocator, parse_cache_key)) |cached| {
                if (cached) |program| {
                    parse_cache_status = .hit;
                    break :blk program;
                }
            } else |_| {
                parse_cache_status = .clone_failed;
            }
        }

        const parsed = parser_inst.parse(preprocessed) catch |err| {
            try stderr.print("Parsing failed: {}\n", .{err});
            return 1;
        };
        if (parse_cache_enabled and parse_cache_status == .miss) {
            parseCacheStore(parse_cache_key, parsed) catch {
                parse_cache_status = .store_failed;
            };
        }
        break :blk parsed;
    };
    const parse_ns = elapsedNs(parse_start);
    defer {
        prog.deinit();
    }

    var ffi_mgr = ffi.FfiManager.init(parse_allocator);
    ffi_mgr.allow_ffi = allow_ffi;
    defer ffi_mgr.deinit();

    var ffi_load_ns: u64 = 0;
    if (allow_ffi or prog.externs.count() != 0) {
        const ffi_start = nowNs();
        ffi_mgr.loadDeclaredDependencies() catch |err| {
            try stderr.print("Loading plugins failed: {}\n", .{err});
            return 1;
        };
        ffi_load_ns = elapsedNs(ffi_start);
    }

    var vm_inst = vm.VM.init(std.heap.c_allocator, prog, &ffi_mgr);
    vm_inst.setOptions(.{
        .collect_stats = show_stats or profile_top_n != 0,
        .profile_top_n = profile_top_n,
        .enable_call_cache = !envFlagSet(allocator, "SA_VM_DISABLE_CALL_CACHE"),
        .enable_tail_restart = !envFlagSet(allocator, "SA_VM_DISABLE_TAIL_RESTART"),
        .enable_block_fastpath = !envFlagSet(allocator, "SA_VM_DISABLE_BLOCK_FASTPATH"),
        .enable_interpreted_fastpath = !envFlagSet(allocator, "SA_VM_DISABLE_INTERPRETED_FASTPATH"),
    });
    defer vm_inst.deinit();
    const code = (if (run_tests) vm_inst.runTests() else vm_inst.run()) catch |err| {
        if (err == error.Panic) {
            if (vm_inst.panic_code) |panic_code| {
                if (vm_inst.panic_message) |msg| {
                    try stderr.print("PANIC[{d}]: {s}\n", .{ panic_code, msg });
                } else {
                    try stderr.print("PANIC: code={d}\n", .{panic_code});
                }
                return 128 +% (panic_code & 0x7f);
            }
        }
        try stderr.print("VM Execution failed: {}\n", .{err});
        return 1;
    };

    if (show_stats or profile_top_n != 0) {
        try vm_inst.writeStats(stderr, preprocess_ns, parse_ns, ffi_load_ns, elapsedNs(total_start), parser_inst.preprocess_cache_status.label(), parse_cache_status.label());
    }

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

fn runVmCommandForTest(mode: []const u8, file_path: []const u8) !u8 {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const argv = [_][]const u8{ "sa", "vm", mode, file_path };
    const result = try runVmCommand(std.testing.allocator, &ctx, &argv, stdout_buf.writer().any(), stderr_buf.writer().any());
    try std.testing.expect(result != null);
    return result.?;
}

test "vm run falls back to @test functions when @main is absent" {
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{"tests/vm_test_mode.sa"});
    defer std.testing.allocator.free(file_path);

    const code = try runVmCommandForTest("run", file_path);
    try std.testing.expectEqual(@as(u8, 0), code);
}

test "vm run handles dead pure load chains without touching invalid memory" {
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{"tests/vm_dead_pure.sa"});
    defer std.testing.allocator.free(file_path);

    const code = try runVmCommandForTest("run", file_path);
    try std.testing.expectEqual(@as(u8, 0), code);
}

test "vm test mode handles dead pure load chains without touching invalid memory" {
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{"tests/vm_dead_pure_test_mode.sa"});
    defer std.testing.allocator.free(file_path);

    const code = try runVmCommandForTest("test", file_path);
    try std.testing.expectEqual(@as(u8, 0), code);
}

test "vm block-local immediate inlining stops at redefinition" {
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{"tests/vm_immediate_inline.sa"});
    defer std.testing.allocator.free(file_path);

    const code = try runVmCommandForTest("run", file_path);
    try std.testing.expectEqual(@as(u8, 10), code);
}

test "vm tail self-call with arena frame does not recurse on host stack" {
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{"tests/vm_tail_arena.sa"});
    defer std.testing.allocator.free(file_path);

    const code = try runVmCommandForTest("run", file_path);
    try std.testing.expectEqual(@as(u8, 0), code);
}

test "vm stats option prints runtime counters" {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{"tests/vm_dead_pure.sa"});
    defer std.testing.allocator.free(file_path);

    const ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const argv = [_][]const u8{ "sa", "vm", "run", "--stats", file_path };
    const result = try runVmCommand(std.testing.allocator, &ctx, &argv, stdout_buf.writer().any(), stderr_buf.writer().any());
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 0), result.?);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "VM stats:") != null);
}

test "vm parse cache hits repeated command in one process" {
    if (envFlagSet(std.testing.allocator, "SA_VM_DISABLE_PARSE_CACHE")) return error.SkipZigTest;
    clearParseCacheForTest();
    defer clearParseCacheForTest();

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_first = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_first.deinit();
    var stderr_second = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_second.deinit();

    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{"tests/vm_parse_cache.sa"});
    defer std.testing.allocator.free(file_path);

    const ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const argv = [_][]const u8{ "sa", "vm", "run", "--stats", file_path };

    const first = try runVmCommand(std.testing.allocator, &ctx, &argv, stdout_buf.writer().any(), stderr_first.writer().any());
    try std.testing.expectEqual(@as(u8, 42), first.?);
    stdout_buf.clearRetainingCapacity();

    const second = try runVmCommand(std.testing.allocator, &ctx, &argv, stdout_buf.writer().any(), stderr_second.writer().any());
    try std.testing.expectEqual(@as(u8, 42), second.?);

    try std.testing.expect(std.mem.indexOf(u8, stderr_first.items, "parse_cache=miss") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_second.items, "parse_cache=hit") != null);
}
