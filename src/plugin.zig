const std = @import("std");
const plugin_api = @import("plugin_api");
const parser = @import("parser.zig");
const ffi = @import("ffi.zig");
const vm = @import("vm.zig");
const sab_loader = @import("sab_loader.zig");
const sandbox_mod = @import("sandbox.zig");
const policy_mod = @import("policy.zig");

const skills = [_]plugin_api.SkillSection{
    .{
        .name = "vm",
        .summary = "Dynamic interpreter VM for running SA assembly files directly",
        .items = &.{
            "vm run <file.sa|.sab>",
            "vm test <file.sa|.sab>",
            "Direct interpretation without compilation",
            "Runs SAB v4 bytecode modules (detected by magic bytes)",
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

// --- Sandbox / resource-limit flags -----------------------------------------
//
// Semantics chosen for this milestone: an explicit CLI flag OVERRIDES the
// corresponding `limits` entry of --policy (last writer wins = the operator
// typing the flag). No conflict error; the effective values are echoed in the
// `sa-vm-event: {"event":"start"}` line so overrides are always auditable.
//
// Flag -> env fallback order: CLI flag wins, then SA_VM_* environment variable,
// then policy limits, then disabled.

fn usageText() []const u8 {
    return "Usage: sa vm <run|test> [--allow-ffi] [--sandboxed] [--stats] [--profile=N] [--policy=<file.json>] [--fuel=N] [--deadline-ms=N] [--mem-cap-bytes=N] [--max-call-depth=N] <file.sa|.sab>\n";
}

const VmSandboxOptions = struct {
    policy_path: ?[]const u8 = null,
    fuel: ?u64 = null,
    deadline_ms: ?u64 = null,
    mem_cap_bytes: ?u64 = null,
    max_call_depth: ?u32 = null,
    /// --sandboxed: run under the built-in minimal default-deny profile
    /// (policy_mod.sandboxed_policy_json) instead of a policy file.
    sandboxed: bool = false,
};

fn parseU64Flag(raw: []const u8) !u64 {
    const value = try std.fmt.parseInt(u64, raw, 10);
    return value;
}

/// Parse one sandbox `--name=value` / `--name value` pair. Returns false when
/// `arg` is not a sandbox flag (the caller keeps its unknown-flag handling).
/// The flag name is matched BEFORE the value is consumed so unknown options
/// never swallow the following positional argument.
fn parseSandboxFlag(options: *VmSandboxOptions, arg: []const u8, next: ?[]const u8, consumed_next: *bool, stderr: std.io.AnyWriter) !bool {
    const eq_idx = std.mem.indexOfScalar(u8, arg, '=');
    const name = if (eq_idx) |idx| arg[0..idx] else arg;

    const known = std.mem.eql(u8, name, "--policy") or
        std.mem.eql(u8, name, "--fuel") or
        std.mem.eql(u8, name, "--deadline-ms") or
        std.mem.eql(u8, name, "--mem-cap-bytes") or
        std.mem.eql(u8, name, "--max-call-depth");
    if (!known) return false;

    const value = blk: {
        if (eq_idx) |idx| break :blk arg[idx + 1 ..];
        if (next) |n| {
            consumed_next.* = true;
            break :blk n;
        }
        try stderr.print("Missing value for {s}\n", .{name});
        return error.MissingFlagValue;
    };

    if (std.mem.eql(u8, name, "--policy")) {
        options.policy_path = value;
    } else if (std.mem.eql(u8, name, "--fuel")) {
        options.fuel = parseU64Flag(value) catch {
            try stderr.print("Invalid value for --fuel: {s}\n", .{value});
            return error.InvalidFlagValue;
        };
    } else if (std.mem.eql(u8, name, "--deadline-ms")) {
        options.deadline_ms = parseU64Flag(value) catch {
            try stderr.print("Invalid value for --deadline-ms: {s}\n", .{value});
            return error.InvalidFlagValue;
        };
    } else if (std.mem.eql(u8, name, "--mem-cap-bytes")) {
        options.mem_cap_bytes = parseU64Flag(value) catch {
            try stderr.print("Invalid value for --mem-cap-bytes: {s}\n", .{value});
            return error.InvalidFlagValue;
        };
    } else if (std.mem.eql(u8, name, "--max-call-depth")) {
        const parsed = std.fmt.parseInt(u32, value, 10) catch 0;
        if (parsed == 0) {
            try stderr.print("Invalid value for --max-call-depth: {s}\n", .{value});
            return error.InvalidFlagValue;
        }
        options.max_call_depth = parsed;
    }
    return true;
}

fn envU64(allocator: std.mem.Allocator, name: []const u8) ?u64 {
    const raw = std.process.getEnvVarOwned(allocator, name) catch return null;
    defer allocator.free(raw);
    return std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch null;
}

/// Fill unset members from SA_VM_POLICY / SA_VM_FUEL / SA_VM_DEADLINE_MS /
/// SA_VM_MEM_CAP_BYTES. CLI flags already present win.
fn applySandboxEnvFallbacks(allocator: std.mem.Allocator, options: *VmSandboxOptions) void {
    if (options.policy_path == null) {
        if (std.process.getEnvVarOwned(allocator, "SA_VM_POLICY")) |raw| {
            defer allocator.free(raw);
            if (raw.len != 0) options.policy_path = allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n\"")) catch null;
        } else |_| {}
    }
    if (options.fuel == null) options.fuel = envU64(allocator, "SA_VM_FUEL");
    if (options.deadline_ms == null) options.deadline_ms = envU64(allocator, "SA_VM_DEADLINE_MS");
    if (options.mem_cap_bytes == null) options.mem_cap_bytes = envU64(allocator, "SA_VM_MEM_CAP_BYTES");
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

pub fn runVmCommand(allocator: std.mem.Allocator, ctx: *const plugin_api.Context, argv: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) anyerror!?u8 {
    _ = stdout;
    _ = ctx;
    const total_start = nowNs();
    if (argv.len < 2) return null;
    if (!std.mem.eql(u8, argv[1], "vm")) return null;
    if (argv.len < 4 or (!std.mem.eql(u8, argv[2], "run") and !std.mem.eql(u8, argv[2], "test"))) {
        try stderr.print("{s}", .{usageText()});
        return 1;
    }

    const run_tests = std.mem.eql(u8, argv[2], "test");

    var allow_ffi = false;
    var show_stats = false;
    var profile_top_n: u16 = 0;
    var file_path: ?[]const u8 = null;
    var sandbox_options = VmSandboxOptions{};

    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--allow-ffi")) {
            allow_ffi = true;
        } else if (std.mem.eql(u8, argv[i], "--sandboxed")) {
            sandbox_options.sandboxed = true;
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
            var consumed_next = false;
            const handled = parseSandboxFlag(&sandbox_options, argv[i], if (i + 1 < argv.len) argv[i + 1] else null, &consumed_next, stderr) catch |err| {
                if (err == error.MissingFlagValue or err == error.InvalidFlagValue) return 1;
                try stderr.print("Invalid vm option: {s} ({})\n", .{ argv[i], err });
                return 1;
            };
            if (!handled) {
                try stderr.print("Unknown vm option: {s}\n", .{argv[i]});
                return 1;
            }
            if (consumed_next) i += 1;
        } else {
            file_path = argv[i];
            break; // Stop parsing flags after the file path
        }
    }

    if (file_path == null) {
        try stderr.print("{s}", .{usageText()});
        return 1;
    }

    applySandboxEnvFallbacks(allocator, &sandbox_options);

    var parser_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer parser_arena.deinit();
    const parse_allocator = parser_arena.allocator();

    // SAB bytecode is detected by magic bytes, not by file extension.
    const input_is_sab = blk: {
        const file = std.fs.cwd().openFile(file_path.?, .{}) catch break :blk false;
        defer file.close();
        var magic_buf: [4]u8 = undefined;
        const read_len = file.readAll(&magic_buf) catch break :blk false;
        break :blk sab_loader.isSabMagic(magic_buf[0..read_len]);
    };

    var preprocess_ns: u64 = 0;
    var parse_ns: u64 = 0;
    var preprocess_cache_label: []const u8 = "disabled";
    var parse_cache_label: []const u8 = "disabled";

    const prog = blk: {
        if (input_is_sab) {
            const load_start = nowNs();
            const bytes = std.fs.cwd().readFileAlloc(parse_allocator, file_path.?, 256 * 1024 * 1024) catch |err| {
                try stderr.print("Reading SAB failed: {}\n", .{err});
                return 1;
            };
            const loaded = sab_loader.loadProgram(parse_allocator, bytes) catch |err| {
                try stderr.print("SAB loading failed: {}\n", .{err});
                return 1;
            };
            parse_ns = elapsedNs(load_start);
            break :blk loaded;
        }

        var parser_inst = parser.Parser.init(parse_allocator);
        defer parser_inst.deinit();

        const preprocess_cache_root = if (envFlagSet(allocator, "SA_VM_DISABLE_PREPROCESS_CACHE")) null else try vmPreprocessCacheRoot(allocator);
        defer if (preprocess_cache_root) |root| allocator.free(root);

        const preprocess_start = nowNs();
        const preprocessed = parser_inst.preprocessWithCache(file_path.?, preprocess_cache_root) catch |err| {
            try stderr.print("Preprocessing failed: {}\n", .{err});
            return 1;
        };
        preprocess_ns = elapsedNs(preprocess_start);

        const parse_cache_enabled = !envFlagSet(allocator, "SA_VM_DISABLE_PARSE_CACHE");
        const parse_cache_key = if (parse_cache_enabled) parseCacheFingerprint(preprocessed, &parser_inst.constants) else 0;
        var parse_cache_status: ParseCacheStatus = if (parse_cache_enabled) .miss else .disabled;

        const parse_start = nowNs();
        const parsed = inner_blk: {
            if (parse_cache_enabled) {
                if (parseCacheLookupClone(parse_allocator, parse_cache_key)) |cached| {
                    if (cached) |program| {
                        parse_cache_status = .hit;
                        break :inner_blk program;
                    }
                } else |_| {
                    parse_cache_status = .clone_failed;
                }
            }

            const result = parser_inst.parse(preprocessed) catch |err| {
                try stderr.print("Parsing failed: {}\n", .{err});
                return 1;
            };
            if (parse_cache_enabled and parse_cache_status == .miss) {
                parseCacheStore(parse_cache_key, result) catch {
                    parse_cache_status = .store_failed;
                };
            }
            break :inner_blk result;
        };
        parse_ns = elapsedNs(parse_start);
        preprocess_cache_label = parser_inst.preprocess_cache_status.label();
        parse_cache_label = parse_cache_status.label();
        break :blk parsed;
    };
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

    // --- Sandbox configuration (spec §3.1 / §3.2 / §3.3) -------------------
    // CLI flags override policy limits; both are optional. The policy is
    // parsed BEFORE any VM work so an invalid policy can never execute guest
    // code (exit E_POLICY_INVALID = 105 -> 233).
    const policy_invalid_exit: u8 = 128 +% sandbox_mod.code_policy_invalid;
    const sandbox_misconfig_exit: u8 = 128 +% sandbox_mod.code_sandbox_misconfig;
    var limits = sandbox_mod.Limits{};
    var parsed_policy: ?policy_mod.Policy = null;
    defer if (parsed_policy) |*p| p.deinit();

    // `--sandboxed` is the untrusted-mode shorthand: it installs the built-in
    // minimal default-deny profile and refuses to be combined with anything
    // that would widen it (a policy file, or raw FFI). E_SANDBOX_MISCONFIG.
    if (sandbox_options.sandboxed) {
        if (sandbox_options.policy_path != null) {
            try stderr.print("--sandboxed cannot be combined with --policy (E_SANDBOX_MISCONFIG): the policy file defines its own capability surface\n", .{});
            return sandbox_misconfig_exit;
        }
        if (allow_ffi) {
            try stderr.print("--sandboxed cannot be combined with --allow-ffi (E_SANDBOX_MISCONFIG): the built-in profile denies FFI\n", .{});
            return sandbox_misconfig_exit;
        }
        parsed_policy = policy_mod.parseSandboxed(allocator) catch {
            try stderr.print("Internal error: built-in --sandboxed profile failed validation\n", .{});
            return policy_invalid_exit;
        };
    } else if (sandbox_options.policy_path) |policy_path| {
        const policy_text = std.fs.cwd().readFileAlloc(parse_allocator, policy_path, 4 * 1024 * 1024) catch |err| {
            try stderr.print("Reading policy file failed ({s}): {}\n", .{ policy_path, err });
            return policy_invalid_exit;
        };
        parsed_policy = policy_mod.Policy.parse(allocator, policy_text) catch {
            try stderr.print("Invalid VM run policy ({s}): expected schema \"{s}\"; unknown keys, wrong-typed values and non-absolute fs patterns are rejected (fail closed)\n", .{ policy_path, policy_mod.expected_schema });
            return policy_invalid_exit;
        };
    }

    // Policy limits apply only where no explicit flag overrides them. This
    // covers the --sandboxed profile too: its caps are defaults, not absences.
    if (parsed_policy) |*policy| {
        if (policy.limits.fuel != null) limits.fuel = policy.limits.fuel;
        if (policy.limits.wall_clock_ms != null) limits.wall_clock_ms = policy.limits.wall_clock_ms;
        if (policy.limits.mem_cap_bytes orelse 0 != 0) limits.mem_cap_bytes = policy.limits.mem_cap_bytes;
    }

    // Explicit flags win over the policy (documented semantics).
    if (sandbox_options.fuel) |fuel| limits.fuel = fuel;
    if (sandbox_options.deadline_ms) |ms| limits.wall_clock_ms = ms;
    if (sandbox_options.mem_cap_bytes) |bytes| {
        limits.mem_cap_bytes = if (bytes == 0) null else bytes;
    }
    if (sandbox_options.max_call_depth) |depth| limits.max_call_depth = depth;

    // Memory quota: the plugin owns the QuotaAllocator so its address outlives
    // the VM; the VM sees only the wrapped allocator interface plus a pointer
    // for peak reporting. The parse arena deliberately keeps using the raw
    // c_allocator (spec §3.2).
    var quota_storage: ?sandbox_mod.QuotaAllocator = null;
    var exec_allocator = std.heap.c_allocator;
    if (limits.mem_cap_bytes) |cap| {
        quota_storage = sandbox_mod.QuotaAllocator.init(std.heap.c_allocator, cap);
        exec_allocator = quota_storage.?.allocator();
    }

    var vm_inst = vm.VM.init(exec_allocator, prog, &ffi_mgr);
    vm_inst.setOptions(.{
        .collect_stats = show_stats or profile_top_n != 0,
        .profile_top_n = profile_top_n,
        .enable_call_cache = !envFlagSet(allocator, "SA_VM_DISABLE_CALL_CACHE"),
        .enable_tail_restart = !envFlagSet(allocator, "SA_VM_DISABLE_TAIL_RESTART"),
        .enable_block_fastpath = !envFlagSet(allocator, "SA_VM_DISABLE_BLOCK_FASTPATH"),
        .enable_interpreted_fastpath = !envFlagSet(allocator, "SA_VM_DISABLE_INTERPRETED_FASTPATH"),
    });
    defer vm_inst.deinit();

    if (limits.mem_cap_bytes != null) {
        vm_inst.quota = &quota_storage.?;
    }
    vm_inst.setEventWriter(stderr);

    if (parsed_policy) |*policy| {
        vm_inst.setPolicy(policy);
        // Guest-relative fs paths resolve against the process CWD (the
        // broker's project root). Best effort: when this fails, canonicalize
        // refuses relative paths and they deny (`fs_path_invalid`).
        if (std.fs.cwd().realpathAlloc(parse_allocator, ".")) |cwd_abs| {
            vm_inst.setFsBaseDir(cwd_abs);
        } else |_| {}
    }

    if (limits.anyResourceCap() or parsed_policy != null or sandbox_options.max_call_depth != null) {
        sandbox_mod.writeStartEvent(stderr, limits) catch {};
    }
    vm_inst.configureSandbox(limits);

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
        try vm_inst.writeStats(stderr, preprocess_ns, parse_ns, ffi_load_ns, elapsedNs(total_start), preprocess_cache_label, parse_cache_label);
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

/// Full-argv variant used by the sandbox tests; captures stderr so assertions
/// can check the `sa-vm-event:` protocol lines.
fn runVmArgvForTest(argv: []const []const u8, stderr_out: *std.ArrayList(u8)) !u8 {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();

    const ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const full_argv = try std.testing.allocator.alloc([]const u8, argv.len + 2);
    defer std.testing.allocator.free(full_argv);
    full_argv[0] = "sa";
    full_argv[1] = "vm";
    @memcpy(full_argv[2..], argv);

    const result = try runVmCommand(
        std.testing.allocator,
        &ctx,
        full_argv,
        stdout_buf.writer().any(),
        stderr_out.writer().any(),
    );
    try std.testing.expect(result != null);
    return result.?;
}

// --- Sandbox resource limits (spec §3.1 / §3.2 / §3.6) ----------------------

const sandbox_fuel_exit: u8 = 128 +% sandbox_mod.code_fuel_exhausted;
const sandbox_timeout_exit: u8 = 128 +% sandbox_mod.code_timeout;
const sandbox_mem_quota_exit: u8 = 128 +% sandbox_mod.code_mem_quota;
const sandbox_policy_invalid_exit: u8 = 128 +% sandbox_mod.code_policy_invalid;
const sandbox_stack_overflow_exit: u8 = 128 +% sandbox_mod.code_stack_overflow;

const INFINITE_LOOP_SA =
    \\@main() -> i32:
    \\L_ENTRY:
    \\    jmp L_ENTRY
    \\
;

const MEMHOG_SA =
    \\@main() -> i32:
    \\L_LOOP:
    \\    p = alloc 1048576
    \\    jmp L_LOOP
    \\
;

/// Non-tail self-recursion: `bumped` keeps the caller frame alive so depth
/// really accumulates (a tail-shaped call would compile into a loop).
const DEEP_RECURSION_SA =
    \\@count(i: u64, n: u64) -> u64:
    \\L_ENTRY:
    \\    done = eq i, n
    \\    br done -> L_DONE, L_STEP
    \\L_STEP:
    \\    one = 1 as u64
    \\    ni = add i, one
    \\    r = call @count(ni, n)
    \\    bumped = add r, one
    \\    !one
    \\    !ni
    \\    !r
    \\    !bumped
    \\    !done
    \\    return bumped
    \\L_DONE:
    \\    !done
    \\    return i
    \\
    \\@main() -> i32:
    \\L_ENTRY:
    \\    zero = 0 as u64
    \\    huge = 200000 as u64
    \\    result = call @count(zero, huge)
    \\    !result
    \\    !zero
    \\    !huge
    \\    return 0
    \\
;

test "sandbox: infinite loop dies with E_FUEL_EXHAUSTED and an sa-vm-event line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "infinite.sa", .data = INFINITE_LOOP_SA });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "infinite.sa");
    defer std.testing.allocator.free(path);

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try runVmArgvForTest(&.{ "run", "--fuel=1000", path }, &stderr_buf);
    try std.testing.expectEqual(sandbox_fuel_exit, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"event\":\"start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"code\":101") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"name\":\"E_FUEL_EXHAUSTED\"") != null);
}

test "sandbox: hung program dies with E_TIMEOUT when --deadline-ms elapses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "infinite.sa", .data = INFINITE_LOOP_SA });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "infinite.sa");
    defer std.testing.allocator.free(path);

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try runVmArgvForTest(&.{ "run", "--deadline-ms=40", path }, &stderr_buf);
    try std.testing.expectEqual(sandbox_timeout_exit, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"code\":102") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"name\":\"E_TIMEOUT\"") != null);
}

test "sandbox: allocation churn dies with E_MEM_QUOTA under --mem-cap-bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "memhog.sa", .data = MEMHOG_SA });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "memhog.sa");
    defer std.testing.allocator.free(path);

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try runVmArgvForTest(&.{ "run", "--mem-cap-bytes=8388608", path }, &stderr_buf);
    try std.testing.expectEqual(sandbox_mem_quota_exit, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"code\":103") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"name\":\"E_MEM_QUOTA\"") != null);
}

test "sandbox: runaway recursion dies with E_STACK_OVERFLOW instead of crashing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "deep.sa", .data = DEEP_RECURSION_SA });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "deep.sa");
    defer std.testing.allocator.free(path);

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    // Depth 100000 exceeds both the default frame ceiling and any realistic
    // host stack, so this must come back as a clean panic, not a hard abort.
    const code = try runVmArgvForTest(&.{ "run", path }, &stderr_buf);
    try std.testing.expectEqual(sandbox_stack_overflow_exit, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"code\":107") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"name\":\"E_STACK_OVERFLOW\"") != null);
}

test "sandbox: policy with an unknown key rejects before execution (E_POLICY_INVALID)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "infinite.sa", .data = INFINITE_LOOP_SA });
    const prog_path = try tmp.dir.realpathAlloc(std.testing.allocator, "infinite.sa");
    defer std.testing.allocator.free(prog_path);
    try tmp.dir.writeFile(.{
        .sub_path = "bad_policy.json",
        .data = "{\"schema\":\"sa.vm.policy/1\",\"limits\":{\"fuel\":10},\"not_a_key\":true}",
    });
    const policy_path = try tmp.dir.realpathAlloc(std.testing.allocator, "bad_policy.json");
    defer std.testing.allocator.free(policy_path);

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try runVmArgvForTest(&.{ "run", "--policy", policy_path, prog_path }, &stderr_buf);
    try std.testing.expectEqual(sandbox_policy_invalid_exit, code);
    // Rejected BEFORE any VM work: no lifecycle event, no guest execution.
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"event\":\"start\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "Invalid VM run policy") != null);
}

test "sandbox: policy limits drive enforcement without CLI flags" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "infinite.sa", .data = INFINITE_LOOP_SA });
    const prog_path = try tmp.dir.realpathAlloc(std.testing.allocator, "infinite.sa");
    defer std.testing.allocator.free(prog_path);
    try tmp.dir.writeFile(.{
        .sub_path = "policy.json",
        .data = "{\"schema\":\"sa.vm.policy/1\",\"limits\":{\"fuel\":2000,\"wall_clock_ms\":60000}}",
    });
    const policy_path = try tmp.dir.realpathAlloc(std.testing.allocator, "policy.json");
    defer std.testing.allocator.free(policy_path);

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try runVmArgvForTest(&.{ "run", "--policy", policy_path, prog_path }, &stderr_buf);
    try std.testing.expectEqual(sandbox_fuel_exit, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"fuel\":2000") != null);
}

test "sandbox: explicit --fuel overrides the policy limit (documented semantics)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "infinite.sa", .data = INFINITE_LOOP_SA });
    const prog_path = try tmp.dir.realpathAlloc(std.testing.allocator, "infinite.sa");
    defer std.testing.allocator.free(prog_path);
    try tmp.dir.writeFile(.{
        .sub_path = "policy.json",
        .data = "{\"schema\":\"sa.vm.policy/1\",\"limits\":{\"fuel\":99999999}}",
    });
    const policy_path = try tmp.dir.realpathAlloc(std.testing.allocator, "policy.json");
    defer std.testing.allocator.free(policy_path);

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    // Flag wins over policy: budget is 7, so exhaustion happens immediately
    // even though the policy granted far more.
    const code = try runVmArgvForTest(&.{ "run", "--policy", policy_path, "--fuel=7", prog_path }, &stderr_buf);
    try std.testing.expectEqual(sandbox_fuel_exit, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"fuel\":7") != null);
}

// --- Capability enforcement end-to-end (spec §3.3 / §3.4) -------------------
//
// These fixtures exercise the layers through the real CLI path:
//   Layer 1  extern.allow (default deny, denial BEFORE FFI resolution)
//   Layer 2  fs / http argument routing through the policy engine
//   Mode     --sandboxed shorthand + its misconfiguration exits

const capability_denied_exit: u8 = 128 +% sandbox_mod.code_capability_denied;

/// Guest paths are embedded into `.sa` string constants with forward slashes:
/// they need no JSON/quoting escapes, and canonicalization folds separators.
fn toGuestPath(allocator: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, abs_path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// Write `data` into `dir/name` and return its absolute path.
fn writeTmpFile(dir: std.fs.Dir, name: []const u8, data: []const u8) ![]u8 {
    try dir.writeFile(.{ .sub_path = name, .data = data });
    return dir.realpathAlloc(std.testing.allocator, name);
}

/// `fd_open` is one of the VM's own shims (src/ffi.zig): it always resolves, so
/// an ALLOWED call really executes and @main returns 0.
const FS_PROBE_SA =
    \\@const PATH = utf8:"{s}\x00"
    \\@extern fd_open(path: ptr) -> i32
    \\
    \\@main() -> i32:
    \\L_ENTRY:
    \\    handle = call @fd_open(&PATH)
    \\    !handle
    \\    return 0
    \\
;

test "capability: fs read allowlist admits the inside path and denies the outside path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Allowed subtree: <root>/data/** ; denied sibling: <root>/secrets/**.
    try tmp.dir.makePath("data");
    try tmp.dir.makePath("secrets");
    const probe_abs = try writeTmpFile(tmp.dir, "data/probe.txt", "factory data");
    defer allocator.free(probe_abs);
    const secret_abs = try writeTmpFile(tmp.dir, "secrets/none.txt", "nope");
    defer allocator.free(secret_abs);

    const probe_guest = try toGuestPath(allocator, probe_abs);
    defer allocator.free(probe_guest);
    const secret_guest = try toGuestPath(allocator, secret_abs);
    defer allocator.free(secret_guest);

    const allowed_src = try std.fmt.allocPrint(allocator, FS_PROBE_SA, .{probe_guest});
    defer allocator.free(allowed_src);
    const denied_src = try std.fmt.allocPrint(allocator, FS_PROBE_SA, .{secret_guest});
    defer allocator.free(denied_src);
    const allowed_path = try writeTmpFile(tmp.dir, "allowed.sa", allowed_src);
    defer allocator.free(allowed_path);
    const denied_path = try writeTmpFile(tmp.dir, "denied.sa", denied_src);
    defer allocator.free(denied_path);

    const data_guest = try toGuestPath(allocator, probe_abs[0 .. probe_abs.len - "/probe.txt".len]);
    defer allocator.free(data_guest);
    const policy_text = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"sa.vm.policy/1\",\"fs\":{{\"read\":[\"{s}/**\"]}},\"extern\":{{\"allow\":[\"fd_open\"]}}}}",
        .{data_guest},
    );
    defer allocator.free(policy_text);
    const policy_path = try writeTmpFile(tmp.dir, "policy.json", policy_text);
    defer allocator.free(policy_path);

    // Inside the allowlist: the gate passes and the shim really executes.
    var stderr_ok = std.ArrayList(u8).init(allocator);
    defer stderr_ok.deinit();
    const code_ok = try runVmArgvForTest(&.{ "run", "--policy", policy_path, allowed_path }, &stderr_ok);
    try std.testing.expectEqual(@as(u8, 0), code_ok);
    try std.testing.expect(std.mem.indexOf(u8, stderr_ok.items, "violation") == null);

    // Outside the allowlist: E_CAPABILITY_DENIED naming reason AND target path.
    var stderr_bad = std.ArrayList(u8).init(allocator);
    defer stderr_bad.deinit();
    const code_bad = try runVmArgvForTest(&.{ "run", "--policy", policy_path, denied_path }, &stderr_bad);
    try std.testing.expectEqual(capability_denied_exit, code_bad);
    try std.testing.expect(std.mem.indexOf(u8, stderr_bad.items, "\"code\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_bad.items, "\"name\":\"E_CAPABILITY_DENIED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_bad.items, "fs_not_allowed") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_bad.items, "PANIC[100]") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_bad.items, secret_guest) != null);
}

test "capability: http URL outside the domain allowlist is denied with or without --allow-ffi" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const evil_url = "https://evil.example.com/upload";
    const http_probe_src = std.fmt.comptimePrint(
        \\@const URL = utf8:"{s}"
        \\@extern sa_http_client_req_new(client: ptr, method: u8, &url: ptr, url_len: u64, &out_req: ptr) -> u32
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    out_slot = stack_alloc 8
        \\    status = call @sa_http_client_req_new(0, 1, &URL, {d}, &out_slot)
        \\    !status
        \\    !out_slot
        \\    return 0
        \\
        \\
    , .{ evil_url, evil_url.len });
    const prog_path = try writeTmpFile(tmp.dir, "http_probe.sa", http_probe_src);
    defer allocator.free(prog_path);

    const policy_text =
        \\{"schema":"sa.vm.policy/1","http":{"allow":[{"host":"api.example.com","methods":["GET","POST"]}]},"extern":{"allow":["sa_http_client_*"]}}
    ;
    const policy_path = try writeTmpFile(tmp.dir, "http_policy.json", policy_text);
    defer allocator.free(policy_path);

    const argv_with_ffi = [_][]const u8{ "run", "--allow-ffi", "--policy", policy_path, prog_path };
    const argv_plain = [_][]const u8{ "run", "--policy", policy_path, prog_path };
    const runs = [_][]const []const u8{ argv_with_ffi[0..], argv_plain[0..] };

    // Both runs must produce the SAME pre-call denial: the gate decides on the
    // URL before any FFI machinery matters, so --allow-ffi changes nothing.
    for (runs) |argv| {
        var stderr_buf = std.ArrayList(u8).init(allocator);
        defer stderr_buf.deinit();
        const code = try runVmArgvForTest(argv, &stderr_buf);
        try std.testing.expectEqual(capability_denied_exit, code);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"code\":100") != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "host_not_allowed") != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, evil_url) != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "VM Execution failed") == null);
    }
}

test "capability: extern not on the allowlist is denied before FFI resolution" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // sa_exfil_tool does not exist in any dependency DLL: without a policy this
    // run dies during symbol resolution ("VM Execution failed"); with a policy
    // the denial happens first and names the symbol instead.
    const EXFIL_SA =
        \\@const BUF = utf8:"stolen"
        \\@extern sa_exfil_tool(&buf: ptr, len: u64) -> i32
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    status = call @sa_exfil_tool(&BUF, 6)
        \\    !status
        \\    return 0
        \\
    ;
    const prog_path = try writeTmpFile(tmp.dir, "exfil.sa", EXFIL_SA);
    defer allocator.free(prog_path);

    const policy_text =
        \\{"schema":"sa.vm.policy/1","extern":{"allow":["sa_print_bytes","sa_fmt_*"]}}
    ;
    const policy_path = try writeTmpFile(tmp.dir, "exfil_policy.json", policy_text);
    defer allocator.free(policy_path);

    const argv_with_ffi = [_][]const u8{ "run", "--allow-ffi", "--policy", policy_path, prog_path };
    const argv_plain = [_][]const u8{ "run", "--policy", policy_path, prog_path };
    const runs = [_][]const []const u8{ argv_with_ffi[0..], argv_plain[0..] };

    for (runs) |argv| {
        var stderr_buf = std.ArrayList(u8).init(allocator);
        defer stderr_buf.deinit();
        const code = try runVmArgvForTest(argv, &stderr_buf);
        try std.testing.expectEqual(capability_denied_exit, code);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "extern_not_allowed") != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "sa_exfil_tool denied by run policy") != null);
        // Pre-resolution proof: neither resolution failure nor plugin loading
        // output may appear; the policy refused the call before either ran.
        try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "VM Execution failed") == null);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "Symbol not found") == null);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "Loading plugins failed") == null);
    }
}

test "capability: --sandboxed denies unlisted externs but keeps printing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const SANDBOXED_SA =
        \\@const HELLO = utf8:"hello\n"
        \\@extern fd_open(path: ptr) -> i32
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    call @sa_print_bytes(&HELLO, 6)
        \\    handle = call @fd_open(&HELLO)
        \\    !handle
        \\    return 0
        \\
    ;
    const prog_path = try writeTmpFile(tmp.dir, "sandboxed.sa", SANDBOXED_SA);
    defer allocator.free(prog_path);

    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();
    const code = try runVmArgvForTest(&.{ "run", "--sandboxed", prog_path }, &stderr_buf);
    try std.testing.expectEqual(capability_denied_exit, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "extern_not_allowed") != null);
    // The implied profile defaults resource caps instead of leaving them off.
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "\"fuel\":1000000000") != null);
}

test "capability: --sandboxed conflicts with --allow-ffi and --policy" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const prog_path = try writeTmpFile(tmp.dir, "tiny.sa", INFINITE_LOOP_SA);
    defer allocator.free(prog_path);
    const policy_path = try writeTmpFile(
        tmp.dir,
        "p.json",
        "{\"schema\":\"sa.vm.policy/1\",\"limits\":{\"fuel\":100}}",
    );
    defer allocator.free(policy_path);

    var stderr_ffi = std.ArrayList(u8).init(allocator);
    defer stderr_ffi.deinit();
    const code_ffi = try runVmArgvForTest(&.{ "run", "--sandboxed", "--allow-ffi", prog_path }, &stderr_ffi);
    try std.testing.expectEqual(@as(u8, 128 +% sandbox_mod.code_sandbox_misconfig), code_ffi);
    try std.testing.expect(std.mem.indexOf(u8, stderr_ffi.items, "E_SANDBOX_MISCONFIG") != null);

    var stderr_policy = std.ArrayList(u8).init(allocator);
    defer stderr_policy.deinit();
    const code_policy = try runVmArgvForTest(&.{ "run", "--sandboxed", "--policy", policy_path, prog_path }, &stderr_policy);
    try std.testing.expectEqual(@as(u8, 128 +% sandbox_mod.code_sandbox_misconfig), code_policy);
    try std.testing.expect(std.mem.indexOf(u8, stderr_policy.items, "E_SANDBOX_MISCONFIG") != null);
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

// --- SAB bytecode input -----------------------------------------------------

const sab = @import("sab");
const sci_sig = sab.signature;
const sci_inst = sab.instruction;

fn writeSabFixture(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, bytes: []const u8) ![]u8 {
    try dir.writeFile(.{ .sub_path = name, .data = bytes });
    return try dir.realpathAlloc(allocator, name);
}

/// Encodes `@main() -> i32` calling `@dbl` in a loop-free program that returns 42.
fn buildSabE2E(allocator: std.mem.Allocator) ![]u8 {
    // symbols: 0=main 1=x 2=y 3=L_ENTRY 4=dbl 5=v 6=r 7=arg 8=L_DBL
    var main_decl = sab.instruction.makeInstruction(.func_decl, 1, 0, null, "");
    main_decl.operands[0] = .{ .symbol = 0 };
    main_decl.operands[1] = .{ .func = 0 };

    var entry_label = sab.instruction.makeInstruction(.label, 2, 0, null, "");
    entry_label.operands[0] = .{ .symbol = 3 };
    entry_label.operands[1] = .{ .label = 3 };

    var assign = sab.instruction.makeInstruction(.assign, 3, 0, null, "");
    assign.operands[0] = .{ .reg = 1 };
    assign.operands[1] = .{ .imm_i64 = 20 };

    var call = sab.instruction.makeInstruction(.call, 4, 0, null, "");
    call.operands[0] = .{ .reg = 2 };
    call.operands[1] = .{ .text = "@dbl(x)" };

    var add = sab.instruction.makeInstruction(.op, 5, 0, null, "");
    add.op_kind = .add;
    add.operands[0] = .{ .reg = 6 };
    add.operands[1] = .{ .reg = 2 };
    add.operands[2] = .{ .imm_i64 = 2 };

    var ret = sab.instruction.makeInstruction(.return_, 6, 0, null, "");
    ret.operands[0] = .{ .reg = 6 };

    var dbl_decl = sab.instruction.makeInstruction(.func_decl, 7, 0, null, "");
    dbl_decl.operands[0] = .{ .symbol = 4 };
    dbl_decl.operands[1] = .{ .func = 4 };

    var dbl_label = sab.instruction.makeInstruction(.label, 8, 0, null, "");
    dbl_label.operands[0] = .{ .symbol = 8 };
    dbl_label.operands[1] = .{ .label = 8 };

    var dbl_op = sab.instruction.makeInstruction(.op, 9, 0, null, "");
    dbl_op.op_kind = .add;
    dbl_op.operands[0] = .{ .reg = 5 };
    dbl_op.operands[1] = .{ .reg = 7 };
    dbl_op.operands[2] = .{ .reg = 7 };

    var dbl_ret = sab.instruction.makeInstruction(.return_, 10, 0, null, "");
    dbl_ret.operands[0] = .{ .reg = 5 };

    const symbols = [_][]const u8{ "main", "x", "y", "L_ENTRY", "dbl", "v", "r", "arg", "L_DBL" };
    const params = [_]sci_sig.ParamSpec{
        .{ .name = "arg", .ty = .u64, .cap = .by_value },
    };
    const sigs = [_]sci_sig.FunctionSig{
        .{
            .id = 0,
            .name = "main",
            .params = &.{},
            .kind = .normal,
            .return_cap = null,
            .return_ty = .i32,
            .entry_inst_idx = 0,
            .is_ffi_wrapper = false,
        },
        .{
            .id = 1,
            .name = "dbl",
            .params = @constCast(params[0..]),
            .kind = .normal,
            .return_cap = null,
            .return_ty = .u64,
            .entry_inst_idx = 6,
            .is_ffi_wrapper = false,
        },
    };
    const insts = [_]sci_inst.Instruction{ main_decl, entry_label, assign, call, add, ret, dbl_decl, dbl_label, dbl_op, dbl_ret };
    return sab.encodeProgramWithConsts(allocator, symbols[0..], &.{}, sigs[0..], insts[0..]);
}

// --- SAB float execution -----------------------------------------------------

const FLOAT_REG_SYMBOLS = [_][]const u8{
    "main", "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
    "v8",   "v9", "v10", "v11", "v12", "v13", "v14", "v15",
};

/// Wraps `body` into a `@main() -> i32` SAB module whose virtual registers are
/// named "v0".."v15" (register ids index FLOAT_REG_SYMBOLS).
fn encodeFloatMainProgram(allocator: std.mem.Allocator, body: []const sci_inst.Instruction) ![]u8 {
    var insts = std.ArrayList(sci_inst.Instruction).init(allocator);
    defer insts.deinit();

    var decl = sci_inst.makeInstruction(.func_decl, 1, 0, null, "");
    decl.operands[0] = .{ .symbol = 0 };
    decl.operands[1] = .{ .func = 0 };
    try insts.append(decl);
    try insts.appendSlice(body);

    const sigs = [_]sci_sig.FunctionSig{.{
        .id = 0,
        .name = "main",
        .params = &.{},
        .kind = .normal,
        .return_cap = null,
        .return_ty = .i32,
        .entry_inst_idx = 0,
        .is_ffi_wrapper = false,
    }};
    return sab.encodeProgramWithConsts(allocator, FLOAT_REG_SYMBOLS[0..], &.{}, sigs[0..], insts.items);
}

fn sabAssignFloat(dest: u32, value: f64) sci_inst.Instruction {
    var item = sci_inst.makeInstruction(.assign, 2, 0, null, "");
    item.operands[0] = .{ .reg = dest };
    item.operands[1] = .{ .imm_float = value };
    return item;
}

fn sabBinOp(kind: sci_inst.OpKind, dest: u32, lhs: u32, rhs: u32) sci_inst.Instruction {
    var item = sci_inst.makeInstruction(.op, 3, 0, null, "");
    item.op_kind = kind;
    item.operands[0] = .{ .reg = dest };
    item.operands[1] = .{ .reg = lhs };
    item.operands[2] = .{ .reg = rhs };
    return item;
}

/// Unary op form: only the source operand (operands[1]) is populated.
fn sabUnaryOp(kind: sci_inst.OpKind, dest: u32, src: u32) sci_inst.Instruction {
    var item = sabBinOp(kind, dest, src, src);
    item.operands[2] = .{ .none = {} };
    return item;
}

/// Conversion op form: source operand plus a trailing result-type operand.
fn sabConvertOp(kind: sci_inst.OpKind, dest: u32, src: u32, ty: sci_sig.PrimType) sci_inst.Instruction {
    var item = sci_inst.makeInstruction(.op, 3, 0, null, "");
    item.op_kind = kind;
    item.operands[0] = .{ .reg = dest };
    item.operands[1] = .{ .reg = src };
    item.operands[2] = .{ .ty = @intFromEnum(ty) };
    return item;
}

fn sabReturn(reg: u32) sci_inst.Instruction {
    var item = sci_inst.makeInstruction(.return_, 1, 0, null, "");
    item.operands[0] = .{ .reg = reg };
    return item;
}

test "vm run executes SAB float arithmetic end to end" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // r3 = 2.5 + 4.0 = 6.5; r4 = r3 * r3 = 42.25; r5 = fptosi(r4) = 42;
    // r6 = fcmp_gt(r3, 6.0) = 1; r8 = sitofp(r5) = 42.0; r9 = fcmp_eq(r8, 42.0)
    // = 1; return 42 * 1 * 1 -> exit code 42.
    const body = [_]sci_inst.Instruction{
        sabAssignFloat(1, 2.5),
        sabAssignFloat(2, 4.0),
        sabBinOp(.fadd, 3, 1, 2),
        sabBinOp(.fmul, 4, 3, 3),
        sabConvertOp(.fptosi, 5, 4, .i32),
        sabAssignFloat(7, 6.0),
        sabBinOp(.fcmp_gt, 6, 3, 7),
        sabBinOp(.mul, 8, 5, 6),
        sabConvertOp(.sitofp, 9, 5, .f64),
        sabAssignFloat(10, 42.0),
        sabBinOp(.fcmp_eq, 11, 9, 10),
        sabBinOp(.mul, 12, 8, 11),
        sabReturn(12),
    };

    const bytes = try encodeFloatMainProgram(allocator, body[0..]);
    defer allocator.free(bytes);
    const sab_path = try writeSabFixture(allocator, tmp.dir, "float_arith.sab", bytes);
    defer allocator.free(sab_path);

    try std.testing.expectEqual(@as(u8, 42), try runVmCommandForTest("run", sab_path));
}

test "vm run SAB float division, NaN and signed zero match IEEE semantics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // r3 = 1.0 / 0.0 = +inf; r7 = -1.0 / 0.0 = -inf; r9 = +inf - +inf = NaN.
    // Checks: (+inf == inf), (-inf < 0.0), (fptosi(NaN) == 0) and
    // (-0.0 == 0.0). Sum of all four truth results -> exit code 4.
    const body = [_]sci_inst.Instruction{
        sabAssignFloat(1, 1.0),
        sabAssignFloat(2, 0.0),
        sabBinOp(.fdiv, 3, 1, 2), // +inf
        sabAssignFloat(4, std.math.inf(f64)),
        sabBinOp(.fcmp_eq, 5, 3, 4), // 1
        sabUnaryOp(.fneg, 6, 1), // -1.0
        sabBinOp(.fdiv, 7, 6, 2), // -inf
        sabBinOp(.fcmp_lt, 8, 7, 2), // 1
        sabBinOp(.fsub, 9, 3, 3), // NaN
        sabConvertOp(.fptosi, 10, 9, .i64), // 0 (NaN clamps to zero)
        sabAssignFloat(11, 0.0),
        sabConvertOp(.fptosi, 12, 11, .i64), // 0
        sabBinOp(.eq, 13, 10, 12), // 1
        sabUnaryOp(.fneg, 14, 2), // -0.0
        sabBinOp(.fcmp_eq, 15, 14, 2), // 1 (signed zero compares equal)
        sabBinOp(.add, 5, 5, 8),
        sabBinOp(.add, 5, 5, 13),
        sabBinOp(.add, 16, 5, 15),
        sabReturn(16),
    };

    const bytes = try encodeFloatMainProgram(allocator, body[0..]);
    defer allocator.free(bytes);
    const sab_path = try writeSabFixture(allocator, tmp.dir, "float_ieee.sab", bytes);
    defer allocator.free(sab_path);

    try std.testing.expectEqual(@as(u8, 4), try runVmCommandForTest("run", sab_path));
}


test "vm run executes a SAB bytecode file end to end" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try buildSabE2E(allocator);
    defer allocator.free(bytes);
    const sab_path = try writeSabFixture(allocator, tmp.dir, "e2e.sab", bytes);
    defer allocator.free(sab_path);

    try std.testing.expectEqual(@as(u8, 42), try runVmCommandForTest("run", sab_path));
}

test "vm run still prefers the text pipeline for .sa sources" {
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{"tests/vm_parse_cache.sa"});
    defer std.testing.allocator.free(file_path);
    try std.testing.expectEqual(@as(u8, 42), try runVmCommandForTest("run", file_path));
}

// --- F6.1: folded str_eq over two string literals ---------------------------

const sci_const = sab.const_decl;

/// Encodes the SAB shape that sla's sab_codegen emits for `str_eq` of two
/// string literals (see probes/f6/vm_streq.sab): the comparison folds to
///
///     borrow tmp_lhs, CONST_LEFT           // bare const name: register operand
///     eq     tmp_out, tmp_lhs, &CONST_RIGHT
///     return tmp_out                       // main returns the boolean
///
/// so the result is pointer identity between the two literal constants.
/// `same_literal` picks the right-hand constant: true reuses CONST_ALPHA,
/// false uses a second const with different contents.
fn encodeFoldedStrEqProgram(allocator: std.mem.Allocator, same_literal: bool) ![]u8 {
    // 0=main 1=tmp_lhs 2=tmp_out 3=bare const name 4/5="&CONST" address forms.
    const symbols = [_][]const u8{
        "main",          "tmp_lhs",       "tmp_out",
        "SLA_STR_ALPHA", "&SLA_STR_ALPHA", "&SLA_STR_BETA",
    };
    const rhs_symbol: u32 = if (same_literal) 4 else 5;

    var decl = sci_inst.makeInstruction(.func_decl, 1, 0, null, "");
    decl.operands[0] = .{ .symbol = 0 };
    decl.operands[1] = .{ .func = 0 };

    var borrow = sci_inst.makeInstruction(.borrow, 2, 0, null, "");
    borrow.operands[0] = .{ .reg = 1 };
    borrow.operands[1] = .{ .symbol = 3 }; // bare const name -> .register

    var cmp = sci_inst.makeInstruction(.op, 3, 0, null, "");
    cmp.op_kind = .eq;
    cmp.operands[0] = .{ .reg = 2 };
    cmp.operands[1] = .{ .reg = 1 };
    cmp.operands[2] = .{ .symbol = rhs_symbol };

    var ret = sci_inst.makeInstruction(.return_, 4, 0, null, "");
    ret.operands[0] = .{ .reg = 2 };

    const alpha_bytes = try allocator.dupe(u8, "alpha\x00");
    errdefer allocator.free(alpha_bytes);
    const beta_bytes = try allocator.dupe(u8, "beta\x00");
    errdefer allocator.free(beta_bytes);
    var consts = [_]sci_const.ConstDecl{
        .{
            .source_line = 1,
            .expanded_line = 1,
            .upstream_loc = null,
            .raw_text = try allocator.dupe(u8, "@const SLA_STR_ALPHA = utf8:\"alpha\\0\""),
            .name = try allocator.dupe(u8, "SLA_STR_ALPHA"),
            .literal_text = try allocator.dupe(u8, "utf8:\"alpha\\0\""),
            .value = .{ .utf8 = .{ .kind = .utf8, .bytes = alpha_bytes } },
        },
        .{
            .source_line = 2,
            .expanded_line = 2,
            .upstream_loc = null,
            .raw_text = try allocator.dupe(u8, "@const SLA_STR_BETA = utf8:\"beta\\0\""),
            .name = try allocator.dupe(u8, "SLA_STR_BETA"),
            .literal_text = try allocator.dupe(u8, "utf8:\"beta\\0\""),
            .value = .{ .utf8 = .{ .kind = .utf8, .bytes = beta_bytes } },
        },
    };
    defer for (consts[0..]) |*c| c.deinit(allocator);

    const sigs = [_]sci_sig.FunctionSig{.{
        .id = 0,
        .name = "main",
        .params = &.{},
        .kind = .normal,
        .return_cap = null,
        .return_ty = .i32,
        .entry_inst_idx = 0,
        .is_ffi_wrapper = false,
    }};
    const insts = [_]sci_inst.Instruction{ decl, borrow, cmp, ret };
    return sab.encodeProgramWithConsts(allocator, symbols[0..], consts[0..], sigs[0..], insts[0..]);
}

fn runFoldedStrEq(same_literal: bool) !u8 {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try encodeFoldedStrEqProgram(allocator, same_literal);
    defer allocator.free(bytes);
    const sab_path = try writeSabFixture(allocator, tmp.dir, "str_eq.sab", bytes);
    defer allocator.free(sab_path);

    return try runVmCommandForTest("run", sab_path);
}

// Equal literals fold to the SAME constant, so pointer identity must hold and
// main returns 1. Before the fix the bare `borrow tmp_lhs, CONST` operand read
// a never-written register slot (always 0), so every literal comparison was 0.
test "vm run folded str_eq of equal string literals compares const pointers" {
    try std.testing.expectEqual(@as(u8, 1), try runFoldedStrEq(true));
}

test "vm run folded str_eq of distinct string literals stays unequal" {
    try std.testing.expectEqual(@as(u8, 0), try runFoldedStrEq(false));
}

// --- F6.3: ownership bookkeeping must stay diagnostic-silent on the VM path --
//
// The corpus notes record a misleading `UseAfterMove(1009)` report for a value
// that is consumed by value twice ("state: expected Consumed, actual
// Consumed"). That text is produced entirely by the NATIVE verifier during
// `sla build-exe` (sci/src/verifier.zig passes maskOf(.consumed) as BOTH the
// expected and the actual mask; sci/src/cli.zig printMaskState renders it
// verbatim). The VM never emits move-state diagnostics: sab_loader maps
// .move_/.release/.fence to no-op assigns (sab_loader.zig, "Ownership
// bookkeeping markers"). This pins that contract: reusing a value after its
// move marker executes normally and prints no trap/ownership text.

/// `v = 20`; first use `a = v + 1`; `.move_` marker; second use
/// `b = v + a` -> 41. Returns 41 so the exit code proves both uses ran.
fn buildMoveMarkerReuseProgram(allocator: std.mem.Allocator) ![]u8 {
    // 0=main 1=v 2=a 3=b 4=L_ENTRY
    const symbols = [_][]const u8{ "main", "v", "a", "b", "L_ENTRY" };

    var decl = sci_inst.makeInstruction(.func_decl, 1, 0, null, "");
    decl.operands[0] = .{ .symbol = 0 };
    decl.operands[1] = .{ .func = 0 };

    var label = sci_inst.makeInstruction(.label, 2, 0, null, "");
    label.operands[0] = .{ .symbol = 4 };
    label.operands[1] = .{ .label = 4 };

    var assign = sci_inst.makeInstruction(.assign, 3, 0, null, "");
    assign.operands[0] = .{ .reg = 1 };
    assign.operands[1] = .{ .imm_i64 = 20 };

    var first_use = sci_inst.makeInstruction(.op, 4, 0, null, "");
    first_use.op_kind = .add;
    first_use.operands[0] = .{ .reg = 2 };
    first_use.operands[1] = .{ .reg = 1 };
    first_use.operands[2] = .{ .imm_i64 = 1 };

    var move_marker = sci_inst.makeInstruction(.move_, 5, 0, null, "");
    move_marker.operands[0] = .{ .reg = 1 };

    var release_marker = sci_inst.makeInstruction(.release, 6, 0, null, "");
    release_marker.operands[0] = .{ .reg = 2 };

    const fence = sci_inst.makeInstruction(.fence, 7, 0, null, "");

    var second_use = sci_inst.makeInstruction(.op, 8, 0, null, "");
    second_use.op_kind = .add;
    second_use.operands[0] = .{ .reg = 3 };
    second_use.operands[1] = .{ .reg = 1 };
    second_use.operands[2] = .{ .reg = 2 };

    var ret = sci_inst.makeInstruction(.return_, 9, 0, null, "");
    ret.operands[0] = .{ .reg = 3 };

    const sigs = [_]sci_sig.FunctionSig{.{
        .id = 0,
        .name = "main",
        .params = &.{},
        .kind = .normal,
        .return_cap = null,
        .return_ty = .i32,
        .entry_inst_idx = 0,
        .is_ffi_wrapper = false,
    }};
    const insts = [_]sci_inst.Instruction{
        decl,      label,      assign,     first_use,
        move_marker, release_marker, fence,  second_use,
        ret,
    };
    return sab.encodeProgramWithConsts(allocator, symbols[0..], &.{}, sigs[0..], insts[0..]);
}

test "vm run applies no use-after-move diagnostics to reused values" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try buildMoveMarkerReuseProgram(allocator);
    defer allocator.free(bytes);
    const sab_path = try writeSabFixture(allocator, tmp.dir, "move_reuse.sab", bytes);
    defer allocator.free(sab_path);

    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();
    const code = try runVmArgvForTest(&.{ "run", sab_path }, &stderr_buf);
    const err_text = stderr_buf.items;

    try std.testing.expectEqual(@as(u8, 41), code);
    // No ownership/move-state reporting may appear on the VM path.
    try testing_expectNoSubstring(err_text, "UseAfterMove");
    try testing_expectNoSubstring(err_text, "use_after_move");
    try testing_expectNoSubstring(err_text, "\"trap\":");
    try testing_expectNoSubstring(err_text, "expected ");
    try testing_expectNoSubstring(err_text, "Consumed");
}

fn testing_expectNoSubstring(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle)) |idx| {
        std.debug.print("unexpected substring \"{s}\" at {d} in:\n{s}\n", .{ needle, idx, haystack });
        return error.TestUnexpectedResult;
    }
}

test "vm test mode discovers SAB @test functions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // symbols: 0=main-decl unused, 1="ok" 2=L_PASS 3=L_FAIL 4=test decl name
    var decl = sab.instruction.makeInstruction(.func_decl, 1, 0, null, "");
    decl.operands[0] = .{ .symbol = 1 };
    decl.operands[1] = .{ .func = 1 };

    var label = sab.instruction.makeInstruction(.label, 2, 0, null, "");
    label.operands[0] = .{ .symbol = 2 };
    label.operands[1] = .{ .label = 2 };

    var ret = sab.instruction.makeInstruction(.return_, 3, 0, null, "");
    ret.operands[0] = .{ .none = {} };

    const symbols = [_][]const u8{ "main", "\"loader smoke\"", "L_PASS", "L_FAIL" };
    const sigs = [_]sci_sig.FunctionSig{
        .{
            .id = 0,
            .name = symbols[1],
            .params = &.{},
            .kind = .test_func,
            .return_cap = null,
            .return_ty = .void,
            .entry_inst_idx = 0,
            .is_ffi_wrapper = false,
        },
    };
    const insts = [_]sab.instruction.Instruction{ decl, label, ret };
    const bytes = try sab.encodeProgramWithConsts(allocator, symbols[0..], &.{}, sigs[0..], insts[0..]);
    defer allocator.free(bytes);
    const sab_path = try writeSabFixture(allocator, tmp.dir, "test_mode.sab", bytes);
    defer allocator.free(sab_path);

    // No @main -> falls back to running all @test functions; they pass silently.
    try std.testing.expectEqual(@as(u8, 0), try runVmCommandForTest("test", sab_path));
}
