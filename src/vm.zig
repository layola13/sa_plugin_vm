const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parser.zig");
const ffi = @import("ffi.zig");
const sandbox_mod = @import("sandbox.zig");
const policy_mod = @import("policy.zig");
const io_classify = @import("io_classify.zig");

/// Sentinel value indicating an unresolved register slot.
const INVALID_SLOT: u32 = std.math.maxInt(u32);
const CALL_CACHE_MAX_ARGS: usize = 4;
const CALL_CACHE_MAX_ENTRIES: u32 = 4096;

fn isTestFunctionName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "test ");
}

fn testFunctionLessThan(_: void, lhs: *const parser.Function, rhs: *const parser.Function) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

/// Upper bound for strings read out of guest memory while gating an extern
/// (path / URL / env name / argv blob). Longer values are refused instead of
/// partially matched: canonicalization and host matching are meaningless at
/// that size, and refusing keeps a hostile length argument from turning into a
/// huge host-side read.
pub const max_guest_string_bytes: usize = 4096;

/// Read one string-typed extern argument out of guest memory.
///
/// `ptr_idx`/`len_idx` are argument positions; when `len_idx` is null the
/// string is taken as NUL-terminated (legacy shims such as `fd_open`). Returns
/// null for absent/zero arguments so the caller can deny instead of guessing.
///
/// Like every load in this interpreter this dereferences a raw guest pointer
/// (accepted residual risk, spec §4.2); the cap bounds how far a bad pointer
/// can be walked, it cannot make the read safe.
fn guestStringArg(args: []const usize, ptr_idx: ?u8, len_idx: ?u8) ?[]const u8 {
    const pi = ptr_idx orelse return null;
    if (pi >= args.len) return null;
    const base = args[pi];
    if (base == 0) return null;
    const bytes = @as([*]const u8, @ptrFromInt(base));
    var len: usize = 0;
    if (len_idx) |li| {
        if (li >= args.len) return null;
        len = @min(@as(usize, @intCast(args[li])), max_guest_string_bytes);
    } else {
        while (len < max_guest_string_bytes and bytes[len] != 0) len += 1;
    }
    if (len == 0) return null;
    return bytes[0..len];
}

/// Pre-resolved dispatch target for a .call instruction, computed during the binding pass.
const ResolvedCall = union(enum) {
    builtin_print,
    builtin_time_ms,
    builtin_time_s,
    builtin_time_ns,
    builtin_time_instant_ns,
    /// sla_std formatting/buffer externs (sa_fmt_*). Capability-gated broker
    /// integration lands later; these are plain interpreter builtins for now.
    sla_builtin: SlaBuiltin,
    interpreted: *const parser.Function,
    ffi_typed: struct { sym: *anyopaque, sig: parser.ExternSignature },
    ffi_legacy: *anyopaque,
    pthread_spawn,
    pthread_spawn_detached,
    pthread_join,
    pthread_drop,
    unresolved,
};

/// sla_std runtime functions the interpreter implements natively.
const SlaBuiltin = enum {
    fmt_i64,
    fmt_u64,
    fmt_f64,
    fmt_bool,
    buffer_data,
    buffer_len,
    buffer_free,

    fn byName(name: []const u8) ?SlaBuiltin {
        return if (std.mem.eql(u8, name, "sa_fmt_i64"))
            .fmt_i64
        else if (std.mem.eql(u8, name, "sa_fmt_u64"))
            .fmt_u64
        else if (std.mem.eql(u8, name, "sa_fmt_f64"))
            .fmt_f64
        else if (std.mem.eql(u8, name, "sa_fmt_bool"))
            .fmt_bool
        else if (std.mem.eql(u8, name, "sa_fmt_buffer_data"))
            .buffer_data
        else if (std.mem.eql(u8, name, "sa_fmt_buffer_len"))
            .buffer_len
        else if (std.mem.eql(u8, name, "sa_fmt_buffer_free"))
            .buffer_free
        else
            null;
    }
};

/// Heap-backed byte buffer handed out by the sa_fmt_* builtins. Call sites hold
/// the handle as an opaque u64 and fetch ptr/len through sa_fmt_buffer_{data,len}.
const FmtBuffer = struct {
    data: []u8,
};

const CallCacheKey = struct {
    func_ptr: usize,
    memory_epoch: u64,
    argc: u8,
    args: [CALL_CACHE_MAX_ARGS]usize,
};

const BYTECODE_PAYLOAD_MAX: u32 = 0x00ff_ffff;
const BYTE_SLOT_NONE: u8 = 0xff;

const ByteOp = enum(u8) {
    nop,
    slow,
    assign_rr,
    load_const,
    add_rr,
    add_rc,
    sub_rr,
    sub_rc,
    mul_rr,
    mul_rc,
    udiv_rr,
    udiv_rc,
    urem_rr,
    urem_rc,
    avg2_rr,
    ptr_add_rr,
    ptr_add_rc,
    and_rr,
    or_rr,
    xor_rr,
    eq_rr,
    eq_rc,
    ne_rr,
    ne_rc,
    ugt_rr,
    ugt_rc,
    ult_rr,
    ult_rc,
    uge_rr,
    uge_rc,
    ule_rr,
    ule_rc,
    sgt_rr,
    sgt_rc,
    slt_rr,
    slt_rc,
    sge_rr,
    sge_rc,
    sle_rr,
    sle_rc,
    load_u64_off8,
    load_u64_index8,
    store_u64_reg_off8,
    store_u64_const_off8,
    store_u64_local_reg_off8,
    store_u64_local_const_off8,
    tail_self_regs,
    call,
    call_indirect,
    consume_reg,
    take_off8,
    try_reg,
};

const CompiledOperandKind = enum(u8) {
    immediate,
    register,
    offset_addr,
};

const CompiledOperand = struct {
    kind: CompiledOperandKind = .immediate,
    slot: u32 = INVALID_SLOT,
    imm: u64 = 0,
    offset: i32 = 0,
};

const CallMetadata = struct {
    inst_pc: usize,
    dest_slot: u32,
    target: ResolvedCall,
    is_tail_call: bool,
    args: []CompiledOperand,
};

const IndirectCallMetadata = struct {
    inst_pc: usize,
    dest_slot: u32,
    fn_ptr: CompiledOperand,
    args: []CompiledOperand,
};

const BlockTermKind = enum(u8) {
    end,
    fallthrough,
    br,
    fast_avg_load_eq_rr,
    fast_tail_add_rc,
    fast_tail_sub_rc,
    fast_br_eq_rr,
    fast_br_eq_rc,
    fast_br_ugt_rr,
    fast_br_ult_rr,
    jmp,
    return_,
};

const TermCmpOp = enum(u8) {
    none = 0,
    eq,
    ne,
    ugt,
    ult,
    uge,
    ule,
    sgt,
    slt,
    sge,
    sle,
};

const CompiledBlock = struct {
    start: usize,
    end: usize,
    term_kind: BlockTermKind = .end,
    cond: CompiledOperand = .{},
    ret: CompiledOperand = .{},
    term_cmp: u32 = 0,
    true_block: usize = 0,
    false_block: usize = 0,
    term_pc: usize = 0,
};

const CompiledFunction = struct {
    func: *const parser.Function,
    optimized_kind: OptimizedFunctionKind = .none,
    code: []u32,
    blocks: []CompiledBlock,
    constants: []u64,
    slow_inst_pcs: []usize,
    call_targets: []ResolvedCall,
    calls: []CallMetadata,
    indirect_calls: []IndirectCallMetadata,
    /// Per-block fuel costs (spec §3.1), populated only while fuel accounting
    /// is active; empty otherwise so dev-mode memory is unchanged.
    fuel_costs: []u32 = &.{},
    slot_count: usize,
    needs_arena: bool,
    cacheable: bool,
    reads_memory: bool,
};

const OptimizedFunctionKind = enum(u8) {
    none,
    fill_u64_index,
    merge_sort_u64,
    search_rec_dead_binary_search_u64,
    binary_search_u64,
    binary_search_u64_rec,
};

const StepResult = union(enum) {
    next,
    tail_restart,
    returned: usize,
};

pub const VMOptions = struct {
    collect_stats: bool = false,
    profile_top_n: u16 = 0,
    enable_call_cache: bool = true,
    enable_tail_restart: bool = true,
    enable_block_fastpath: bool = true,
    enable_interpreted_fastpath: bool = true,
};

pub const VMStats = struct {
    bind_ns: u64 = 0,
    execute_ns: u64 = 0,
    function_calls: u64 = 0,
    interpreted_calls: u64 = 0,
    bytecode_ops: u64 = 0,
    slow_ops: u64 = 0,
    fast_block_hits: u64 = 0,
    tail_restarts: u64 = 0,
    call_cache_hits: u64 = 0,
    call_cache_misses: u64 = 0,
    call_cache_stores: u64 = 0,
    call_cache_clears: u64 = 0,
    frame_pool_hits: u64 = 0,
    frame_pool_misses: u64 = 0,
    frame_pool_releases: u64 = 0,
    memory_epoch_bumps: u64 = 0,
    current_call_depth: u32 = 0,
    max_call_depth: u32 = 0,
};

const FunctionProfile = struct {
    calls: u64 = 0,
    ns: u64 = 0,
};

const ProfileRow = struct {
    name: []const u8,
    calls: u64,
    ns: u64,
};

fn profileRowLessThan(_: void, lhs: ProfileRow, rhs: ProfileRow) bool {
    if (lhs.ns == rhs.ns) return lhs.calls > rhs.calls;
    return lhs.ns > rhs.ns;
}

fn u64LessThan(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

inline fn nowNs() u64 {
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}

inline fn elapsedNs(start: u64) u64 {
    return nowNs() -% start;
}

pub const VM = struct {
    program: *parser.Program,
    allocator: std.mem.Allocator,
    ffi: *ffi.FfiManager,
    options: VMOptions,
    stats: VMStats,
    function_profile: std.StringHashMap(FunctionProfile),
    function_addresses: std.AutoHashMap(usize, *const parser.Function),
    function_names: std.StringHashMap(usize),
    function_ptrs: std.StringHashMap(*const parser.Function),
    label_targets: std.StringHashMap(std.StringHashMap(usize)),
    function_registers: std.StringHashMap(std.StringHashMap(usize)),
    /// Number of register slots per function (populated by binding pass).
    function_slot_counts: std.StringHashMap(usize),
    /// Whether a function needs a per-call arena for stack_alloc instructions.
    function_needs_arena: std.StringHashMap(bool),
    /// Whether an interpreted function is safe to memoize for identical args and memory epoch.
    function_cacheable: std.StringHashMap(bool),
    /// Whether a cacheable function reads memory and therefore needs epoch-sensitive keys.
    function_reads_memory: std.StringHashMap(bool),
    /// Compiled u32 bytecode and side tables per function.
    compiled_functions: std.StringHashMap(CompiledFunction),
    compiled_function_ptrs: std.AutoHashMap(usize, *CompiledFunction),
    call_cache: std.AutoHashMap(CallCacheKey, usize),
    memory_epoch: u64,
    frame_pool: std.ArrayList([]u64),
    dummy_buffers: std.ArrayList(*u8),
    heap_allocs: std.ArrayList([]u64),
    result_allocs: std.ArrayList([]u64),
    result_alloc_index: std.AutoHashMap(usize, usize),
    panic_code: ?u8 = null,
    panic_message: ?[]u8 = null,
    thread_results: std.AutoHashMap(i32, usize),
    next_thread_handle: i32,
    /// Live sa_fmt_* buffers keyed by handle pointer (freed on free or deinit).
    fmt_buffers: std.ArrayList(*FmtBuffer),
    // --- Sandbox / resource limits (spec §3.1, §3.2, §3.6) ------------------
    /// Non-null while any resource cap (fuel / wall clock / memory quota) is
    /// active; null in plain dev runs so the hot block loop pays one branch.
    sandbox: ?*sandbox_mod.State = null,
    sandbox_state: sandbox_mod.State = .{},
    /// Parsed `sa.vm.policy/1` when the host supplied one. Capability
    /// enforcement surface is documented in the README "Sandbox" section;
    /// gates live at extern dispatch (checkCapabilityForTarget /
    /// enforceExternCapability / callUnresolved) and on both call_indirect
    /// paths.
    policy: ?*const policy_mod.Policy = null,
    /// Absolute base directory for guest-relative fs paths under a policy.
    fs_base_dir: ?[]const u8 = null,
    /// Present when a memory cap is configured (plugin.zig owns the storage).
    quota: ?*sandbox_mod.QuotaAllocator = null,
    /// Guest call depth + host-stack guard, active on every run (converts
    /// runaway recursion into E_STACK_OVERFLOW instead of a 0xC0000005 crash).
    call_depth: u32 = 0,
    max_call_depth: u32 = sandbox_mod.default_max_call_depth,
    stack_headroom_bytes: usize = sandbox_mod.default_stack_headroom_bytes,
    /// Cached lowest safe stack address (computed once, on first guest call).
    stack_floor_cache: usize = 0,
    /// Stack address observed when guest execution starts (non-Windows guard).
    stack_base_hint: usize = 0,
    /// Injected sink for `sa-vm-event:` lines (spec §3.6.2). Falls back to the
    /// process stderr when unset; the host sets it so events land in the same
    /// stream as its own diagnostics.
    event_writer: ?std.io.AnyWriter = null,

    pub fn setEventWriter(self: *VM, writer: std.io.AnyWriter) void {
        self.event_writer = writer;
    }

    pub fn init(allocator: std.mem.Allocator, program: *parser.Program, ffi_mgr: *ffi.FfiManager) VM {
        return .{
            .allocator = allocator,
            .program = program,
            .ffi = ffi_mgr,
            .options = .{},
            .stats = .{},
            .function_profile = std.StringHashMap(FunctionProfile).init(allocator),
            .function_addresses = std.AutoHashMap(usize, *const parser.Function).init(allocator),
            .function_names = std.StringHashMap(usize).init(allocator),
            .function_ptrs = std.StringHashMap(*const parser.Function).init(allocator),
            .label_targets = std.StringHashMap(std.StringHashMap(usize)).init(allocator),
            .function_registers = std.StringHashMap(std.StringHashMap(usize)).init(allocator),
            .function_slot_counts = std.StringHashMap(usize).init(allocator),
            .function_needs_arena = std.StringHashMap(bool).init(allocator),
            .function_cacheable = std.StringHashMap(bool).init(allocator),
            .function_reads_memory = std.StringHashMap(bool).init(allocator),
            .compiled_functions = std.StringHashMap(CompiledFunction).init(allocator),
            .compiled_function_ptrs = std.AutoHashMap(usize, *CompiledFunction).init(allocator),
            .call_cache = std.AutoHashMap(CallCacheKey, usize).init(allocator),
            .memory_epoch = 1,
            .frame_pool = std.ArrayList([]u64).init(allocator),
            .dummy_buffers = std.ArrayList(*u8).init(allocator),
            .heap_allocs = std.ArrayList([]u64).init(allocator),
            .result_allocs = std.ArrayList([]u64).init(allocator),
            .result_alloc_index = std.AutoHashMap(usize, usize).init(allocator),
            .panic_code = null,
            .panic_message = null,
            .thread_results = std.AutoHashMap(i32, usize).init(allocator),
            .next_thread_handle = 1,
            .fmt_buffers = std.ArrayList(*FmtBuffer).init(allocator),
        };
    }

    pub fn setOptions(self: *VM, options: VMOptions) void {
        self.options = options;
    }

    /// Install resource limits (spec §3.1/§3.2). Fuel / wall clock / memory
    /// quota stay off unless the corresponding member is set; the call-depth
    /// and host-stack guards are always on (they only turn runaway recursion
    /// into a clean panic, never affecting terminating programs).
    pub fn configureSandbox(self: *VM, limits: sandbox_mod.Limits) void {
        self.max_call_depth = limits.max_call_depth;
        self.stack_headroom_bytes = limits.stack_headroom_bytes;
        var state = sandbox_mod.State{
            .run_start_ns = std.time.nanoTimestamp(),
            .mem_cap_bytes = limits.mem_cap_bytes orelse 0,
        };
        if (limits.fuel) |fuel| {
            state.fuel_total = fuel;
            state.fuel_remaining = fuel;
        }
        if (limits.wall_clock_ms) |ms| {
            state.deadline_ns = @as(i128, std.time.nanoTimestamp()) + @as(i128, ms) * std.time.ns_per_ms;
        }
        self.sandbox_state = state;
        // Null-gate: only point `sandbox` at the state when a hot-loop cap is
        // active so unconfigured dev runs keep today's dispatch cost.
        self.sandbox = if (limits.anyResourceCap()) &self.sandbox_state else null;
    }

    /// Attach a parsed policy for capability decisions (spec §3.3). The host
    /// keeps ownership; the policy must outlive the VM.
    pub fn setPolicy(self: *VM, policy: *const policy_mod.Policy) void {
        self.policy = policy;
    }

    /// Absolute directory guest-relative fs paths resolve against (the
    /// broker's project root / process CWD). null => relative paths are
    /// refused by canonicalization (`fs_path_invalid`), which fails closed.
    pub fn setFsBaseDir(self: *VM, dir: ?[]const u8) void {
        self.fs_base_dir = dir;
    }

    // ------------------------------------------------------------------
    // Sandbox violation plumbing (spec §3.6)
    // ------------------------------------------------------------------

    fn sandboxSnapshot(self: *const VM) sandbox_mod.Snapshot {
        var snap = sandbox_mod.Snapshot{ .mem_peak_bytes = 0 };
        if (self.sandbox) |sb| {
            snap.fuel_used = sb.fuelUsed();
            snap.wall_ms = sb.wallMsElapsed();
        }
        if (self.quota) |quota| snap.mem_peak_bytes = quota.peak_bytes;
        return snap;
    }

    /// Emit one `sa-vm-event:` JSON line (spec §3.6.2) to the injected writer
    /// or the process stderr. Best effort: a failing write must never mask
    /// the panic itself.
    fn emitViolationEvent(self: *VM, code: u8, detail: []const u8) void {
        const snap = self.sandboxSnapshot();
        var line_buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&line_buf);
        sandbox_mod.writeViolationEvent(fbs.writer(), code, detail, snap) catch {
            // Detail longer than one line: emit truncated but still valid JSON
            // by retrying without it.
            fbs.reset();
            sandbox_mod.writeViolationEvent(fbs.writer(), code, "", snap) catch return;
        };
        const line = fbs.getWritten();
        if (self.event_writer) |w| {
            w.writeAll(line) catch {};
            return;
        }
        std.io.getStdErr().writeAll(line) catch {};
    }

    /// Raise a sandbox violation through the ordinary panic channel so host
    /// handling (`PANIC[code]: msg` + exit code mapping) works unchanged.
    fn sandboxPanic(self: *VM, code: u8, detail: []const u8) anyerror {
        self.clearPanicState();
        self.panic_code = code;
        // The human-readable PANIC line carries "<NAME>: <detail>"; the event
        // carries the same detail so harness and human see one reason.
        const named = std.fmt.allocPrint(
            self.allocator,
            "{s}: {s}",
            .{ sandbox_mod.nameForCode(code), detail },
        ) catch null;
        if (named) |msg| {
            self.panic_message = msg;
            self.emitViolationEvent(code, detail);
        } else {
            // OOM while composing the message must not mask the violation.
            self.emitViolationEvent(code, detail);
        }
        return error.Panic;
    }

    fn panicFuelExhausted(self: *VM, sb: *sandbox_mod.State) anyerror {
        var buf: [128]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        fbs.writer().print("block-cost budget of {d} units exhausted (wall {d} ms)", .{
            sb.fuel_total, sb.wallMsElapsed(),
        }) catch {};
        return self.sandboxPanic(sandbox_mod.code_fuel_exhausted, fbs.getWritten());
    }

    fn panicTimeout(self: *VM) anyerror {
        const wall_ms = if (self.sandbox) |sb| sb.wallMsElapsed() else 0;
        var buf: [96]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        fbs.writer().print("wall-clock deadline exceeded after {d} ms", .{wall_ms}) catch {};
        return self.sandboxPanic(sandbox_mod.code_timeout, fbs.getWritten());
    }

    fn panicMemQuota(self: *VM) anyerror {
        var buf: [128]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        if (self.quota) |quota| {
            fbs.writer().print("memory cap of {d} bytes hit (peak live {d} bytes)", .{
                quota.cap_bytes, quota.peak_bytes,
            }) catch {};
        } else {
            fbs.writer().writeAll("memory cap hit") catch {};
        }
        return self.sandboxPanic(sandbox_mod.code_mem_quota, fbs.getWritten());
    }

    fn panicStackOverflow(self: *VM) anyerror {
        var buf: [160]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        fbs.writer().print("call depth {d} would exhaust the host stack (limit {d} frames or {d} bytes headroom)", .{
            self.call_depth, self.max_call_depth, self.stack_headroom_bytes,
        }) catch {};
        return self.sandboxPanic(sandbox_mod.code_stack_overflow, fbs.getWritten());
    }

    fn panicCapabilityDenied(self: *VM, reason_label: []const u8, subject: []const u8) anyerror {
        var buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        fbs.writer().print("{s} denied by run policy: {s}", .{ subject, reason_label }) catch {};
        return self.sandboxPanic(policy_mod.panic_code_capability_denied, fbs.getWritten());
    }

    // ------------------------------------------------------------------
    // Hot-path limit checks
    // ------------------------------------------------------------------

    /// Forced deadline checkpoint around FFI / pthread / builtin / broker calls
    /// (spec §3.1 step 4): blocking syscalls do not burn fuel, so only the wall
    /// clock can bound them.
    inline fn sandboxCheckpoint(self: *VM) !void {
        const sb = self.sandbox orelse return;
        if (sb.deadlineExceeded()) return self.panicTimeout();
    }

    /// Lowest stack address guest recursion may still use without endangering
    /// the host.
    ///
    /// Windows: VirtualQuery around the current stack pointer finds the
    /// thread's stack reservation; its AllocationBase is the true bottom, and
    /// `AllocationBase + headroom` is the deepest safe frame address. (The TEB
    /// NtTib.StackLimit value is NOT usable here: it tracks the committed
    /// bottom, which moves down as the stack grows, so it hugs the current
    /// frame instead of bounding it.)
    ///
    /// Other platforms fall back to a base recorded when guest execution starts
    /// minus an assumed 8 MiB thread stack.
    fn recordStackBaseHint(self: *VM) void {
        self.stack_floor_cache = 0; // recompute for the fresh limits
        var marker: u8 = 0;
        self.stack_base_hint = @intFromPtr(&marker);
    }

    fn computeStackFloor(self: *VM) usize {
        var marker: u8 = 0;
        const sp = @intFromPtr(&marker);
        if (comptime builtin.os.tag == .windows) {
            var mbi: std.os.windows.MEMORY_BASIC_INFORMATION = undefined;
            if (std.os.windows.VirtualQuery(@ptrFromInt(sp), &mbi, @sizeOf(std.os.windows.MEMORY_BASIC_INFORMATION))) |_| {
                const alloc_base = @intFromPtr(mbi.AllocationBase);
                // Sanity: the allocation base must sit below the current frame.
                if (alloc_base != 0 and alloc_base < sp) {
                    return alloc_base + self.stack_headroom_bytes;
                }
            } else |_| {}
            return sp -| (1024 * 1024 -| self.stack_headroom_bytes);
        }
        return self.stack_base_hint -| (8 * 1024 * 1024 -| self.stack_headroom_bytes);
    }

    inline fn stackFloor(self: *VM) usize {
        if (self.stack_floor_cache == 0) {
            self.stack_floor_cache = self.computeStackFloor();
        }
        return self.stack_floor_cache;
    }

    /// True when entering another guest frame could cross the guard page.
    inline fn belowStackFloor(self: *VM) bool {
        var marker: u8 = 0;
        return @intFromPtr(&marker) < self.stackFloor();
    }

    /// Call-entry guard: converts runaway recursion into E_STACK_OVERFLOW
    /// instead of an access violation in the host process.
    inline fn enterGuestCall(self: *VM) !void {
        self.call_depth += 1;
        if (self.call_depth > self.max_call_depth or self.belowStackFloor()) {
            return self.panicStackOverflow();
        }
    }

    /// Capability gate for bind-time-resolved extern targets.
    ///
    /// Native symbols (`ffi_typed` / `ffi_legacy`) always pass the extern
    /// allowlist first; symbols whose arguments carry a known I/O target are
    /// then checked against that resource rule, while unclassified native
    /// symbols additionally need the `ffi` capability (naming an arbitrary
    /// native symbol is code execution by another name). Threads keep their
    /// dedicated gate. Runs before any argument is dereferenced for I/O.
    fn checkCapabilityForTarget(self: *VM, target: ResolvedCall, name_for_diagnostic: []const u8, args: []const usize) !void {
        switch (target) {
            .ffi_typed, .ffi_legacy => {
                try self.enforceExternCapability(name_for_diagnostic, args, true);
            },
            .pthread_spawn, .pthread_spawn_detached, .pthread_join, .pthread_drop => {
                const pol = self.policy orelse return;
                if (!pol.checkThreads().isAllowed()) return self.panicCapabilityDenied("threads", name_for_diagnostic);
            },
            else => {},
        }
    }

    /// Capability enforcement for one named extern call (spec §3.3/§3.4).
    ///
    /// Layer 1 — `policy.extern.allow` decides whether the symbol may be called
    /// at all. Absent from the allowlist => E_CAPABILITY_DENIED
    /// (`extern_not_allowed`) BEFORE any dlopen/dlsym work happens. With no
    /// policy loaded this function returns immediately: developer mode keeps
    /// its historical behavior (documented in README "Sandbox").
    ///
    /// Layer 2 — allowed symbols whose arguments carry an I/O target are routed
    /// through policy.zig using the declarative table in io_classify.zig:
    /// file paths -> checkFsRead/checkFsWrite, URLs (+ method) -> checkHttp,
    /// env names -> checkEnv, argv blobs -> checkProcessSpawn, socket families
    /// -> checkNetRaw. Those calls therefore need NO `ffi` grant: the policy
    /// bounds what the call may touch, whatever the exporting DLL also does
    /// internally (plugins are trusted host-side components, spec §4.1).
    ///
    /// `native_target` marks calls that will execute exported machine code:
    /// an allowed-but-unclassified symbol then additionally requires the `ffi`
    /// capability, so listing random native names never becomes a code-exec
    /// primitive.
    fn enforceExternCapability(self: *VM, func_name: []const u8, args: []const usize, native_target: bool) !void {
        const pol = self.policy orelse return;

        // --- Layer 1: symbol allowlist (default deny) ----------------------
        if (!pol.checkExtern(func_name).isAllowed())
            return self.panicCapabilityDenied("extern_not_allowed", func_name);

        // Raw sockets have per-address rather than per-URL semantics: one
        // wholesale flag instead of a URL rule.
        if (io_classify.isNetRawFamily(func_name)) {
            const raw = pol.checkNetRaw();
            if (raw.denyReason()) |reason| return self.panicCapabilityDenied(reason.label(), func_name);
            return;
        }

        // --- Layer 2: what do the arguments point at? ----------------------
        const cls = io_classify.classify(func_name);
        switch (cls.kind) {
            .none => {
                if (native_target and !pol.checkFfi().isAllowed())
                    return self.panicCapabilityDenied("ffi", func_name);
            },
            .fs_read => try self.gateFsPath(pol, .read, cls.spec, args),
            .fs_write => try self.gateFsPath(pol, .write, cls.spec, args),
            .fs_transfer => {
                const spec = cls.spec;
                try self.gateFsPath(pol, .read, .{ .path = spec.path, .path_len = spec.path_len }, args);
                try self.gateFsPath(pol, .write, .{ .path = spec.path2, .path_len = spec.path2_len }, args);
            },
            .http_request => try self.gateHttp(pol, cls.spec, args),
            .env_get, .env_set => try self.gateEnvName(pol, cls.spec, args),
            .process_spawn => try self.gateProcessSpawn(pol, cls.spec, args),
            .net_raw => unreachable, // handled by the family check above
        }
    }

    /// Canonicalize + match one path argument against the fs section of the
    /// policy. The subject of the violation event is the offending path so
    /// harnesses see exactly which target was refused.
    fn gateFsPath(self: *VM, pol: *const policy_mod.Policy, op: policy_mod.FsOp, spec: io_classify.Spec, args: []const usize) !void {
        const path = guestStringArg(args, spec.path, spec.path_len) orelse
            return self.panicCapabilityDenied("fs_path_invalid", "unreadable path argument");
        const verdict = try pol.checkFs(self.allocator, op, path, self.fs_base_dir);
        if (verdict.denyReason()) |reason| return self.panicCapabilityDenied(reason.label(), path);
    }

    /// Validate URL (+ optional method) arguments against the http section.
    /// NOTE: redirects followed inside native plugin code cannot be observed
    /// here yet — see README "What is not enforced".
    fn gateHttp(self: *VM, pol: *const policy_mod.Policy, spec: io_classify.Spec, args: []const usize) !void {
        const url = guestStringArg(args, spec.url, spec.url_len) orelse
            return self.panicCapabilityDenied("bad_url", "unreadable url argument");
        const method_text: []const u8 = blk: {
            if (spec.method_str) |idx| {
                if (guestStringArg(args, idx, spec.method_str_len)) |text| break :blk text;
                break :blk "";
            }
            if (spec.method_enum) |idx| {
                if (idx < args.len) {
                    if (io_classify.methodNameFromEnum(args[idx])) |name| break :blk name;
                    // Unknown method code: fail closed rather than guess.
                    return self.panicCapabilityDenied("method_not_allowed", url);
                }
                break :blk "";
            }
            break :blk "GET";
        };
        const verdict = try pol.checkHttp(self.allocator, method_text, url);
        if (verdict.denyReason()) |reason| return self.panicCapabilityDenied(reason.label(), url);
    }

    /// Env lookups/mutations compare the variable name against `env.allow`.
    fn gateEnvName(self: *VM, pol: *const policy_mod.Policy, spec: io_classify.Spec, args: []const usize) !void {
        const name = blk: {
            if (spec.name_literal) |literal| break :blk literal;
            break :blk guestStringArg(args, spec.name, spec.name_len) orelse
                return self.panicCapabilityDenied("env_not_allowed", "unreadable env name");
        };
        const verdict = pol.checkEnv(name);
        if (verdict.denyReason()) |reason| return self.panicCapabilityDenied(reason.label(), name);
    }

    /// Spawn gate: the argv blob must be a JSON array of strings whose first
    /// element is the executable; anything unparseable denies (fail closed).
    fn gateProcessSpawn(self: *VM, pol: *const policy_mod.Policy, spec: io_classify.Spec, args: []const usize) !void {
        const blob = guestStringArg(args, spec.name, spec.name_len) orelse
            return self.panicCapabilityDenied("process_spawn_disabled", "unreadable argv argument");

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), blob, .{}) catch
            return self.panicCapabilityDenied("exec_not_allowed", blob);
        const arr = switch (parsed) {
            .array => |a| a,
            else => return self.panicCapabilityDenied("exec_not_allowed", blob),
        };
        if (arr.items.len == 0) return self.panicCapabilityDenied("exec_not_allowed", blob);

        var argv = try self.allocator.alloc([]const u8, arr.items.len - 1);
        defer self.allocator.free(argv);
        var executable: []const u8 = "";
        for (arr.items, 0..) |item, idx| {
            const text = switch (item) {
                .string => |s| s,
                else => return self.panicCapabilityDenied("exec_not_allowed", blob),
            };
            if (idx == 0) {
                executable = text;
            } else {
                argv[idx - 1] = text;
            }
        }

        const verdict = try pol.checkProcessSpawn(self.allocator, executable, argv);
        if (verdict.denyReason()) |reason| return self.panicCapabilityDenied(reason.label(), executable);
    }

    /// Best-effort symbol name for diagnostics on the compiled fast path. The
    /// callee name is always available for `.call` instructions (appendCall
    /// rejects calls without operands), so violations can name the symbol.
    fn callTargetDiagnosticName(self: *VM, func: *const parser.Function, meta: *const CallMetadata) []const u8 {
        _ = self;
        if (func.instructions[meta.inst_pc].args.len > 0)
            return func.instructions[meta.inst_pc].args[0].name;
        return switch (meta.target) {
            .unresolved => "unresolved",
            .pthread_spawn => "pthread_spawn",
            .pthread_spawn_detached => "pthread_spawn_detached",
            .pthread_join => "pthread_join",
            .pthread_drop => "pthread_drop",
            else => "extern",
        };
    }

    inline fn statsEnabled(self: *const VM) bool {
        return self.options.collect_stats or self.options.profile_top_n != 0;
    }

    pub fn deinit(self: *VM) void {
        self.clearPanicState();
        self.function_profile.deinit();
        var label_it = self.label_targets.iterator();
        while (label_it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.label_targets.deinit();
        self.function_addresses.deinit();
        self.function_names.deinit();
        self.function_ptrs.deinit();
        var reg_it = self.function_registers.iterator();
        while (reg_it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.function_registers.deinit();
        self.function_slot_counts.deinit();
        self.function_needs_arena.deinit();
        self.function_cacheable.deinit();
        self.function_reads_memory.deinit();
        self.compiled_function_ptrs.deinit();
        var cf_it = self.compiled_functions.iterator();
        while (cf_it.next()) |entry| {
            self.freeCompiledFunction(entry.value_ptr);
        }
        self.compiled_functions.deinit();
        self.call_cache.deinit();
        for (self.frame_pool.items) |buf| {
            self.allocator.free(buf);
        }
        self.frame_pool.deinit();
        self.thread_results.deinit();
        for (self.dummy_buffers.items) |buf| {
            self.allocator.destroy(buf);
        }
        self.dummy_buffers.deinit();
        for (self.heap_allocs.items) |buf| {
            self.allocator.free(buf);
        }
        self.heap_allocs.deinit();
        for (self.result_allocs.items) |buf| {
            self.allocator.free(buf);
        }
        self.result_allocs.deinit();
        self.result_alloc_index.deinit();
        for (self.fmt_buffers.items) |buffer| {
            self.allocator.free(buffer.data);
            self.allocator.destroy(buffer);
        }
        self.fmt_buffers.deinit();
    }

    fn clearPanicState(self: *VM) void {
        if (self.panic_message) |msg| {
            self.allocator.free(msg);
        }
        self.panic_message = null;
        self.panic_code = null;
    }

    fn freeCompiledFunction(self: *VM, compiled: *CompiledFunction) void {
        self.allocator.free(compiled.code);
        self.allocator.free(compiled.blocks);
        self.allocator.free(compiled.constants);
        self.allocator.free(compiled.slow_inst_pcs);
        if (compiled.fuel_costs.len != 0) self.allocator.free(compiled.fuel_costs);
        self.allocator.free(compiled.call_targets);
        for (compiled.calls) |meta| self.allocator.free(meta.args);
        self.allocator.free(compiled.calls);
        for (compiled.indirect_calls) |meta| self.allocator.free(meta.args);
        self.allocator.free(compiled.indirect_calls);
        compiled.* = .{
            .func = compiled.func,
            .optimized_kind = .none,
            .code = &.{},
            .blocks = &.{},
            .constants = &.{},
            .slow_inst_pcs = &.{},
            .call_targets = &.{},
            .calls = &.{},
            .indirect_calls = &.{},
            .slot_count = 0,
            .needs_arena = false,
            .cacheable = false,
            .reads_memory = true,
        };
    }

    pub fn run(self: *VM) !i32 {
        self.clearPanicState();
        self.recordStackBaseHint();
        const bind_start = nowNs();
        try self.initFunctionsAndVtables();
        if (self.statsEnabled()) self.stats.bind_ns += elapsedNs(bind_start);

        const main_func = self.program.functions.getPtr("main") orelse return self.runTestsAfterInit();
        const execute_start = nowNs();
        const main_code = try self.executeFunction(main_func, &.{});
        if (self.statsEnabled()) self.stats.execute_ns += elapsedNs(execute_start);
        return @as(i32, @bitCast(@as(u32, @intCast(main_code & 0xffffffff))));
    }

    pub fn runTests(self: *VM) !i32 {
        self.clearPanicState();
        self.recordStackBaseHint();
        const bind_start = nowNs();
        try self.initFunctionsAndVtables();
        if (self.statsEnabled()) self.stats.bind_ns += elapsedNs(bind_start);
        const execute_start = nowNs();
        defer {
            if (self.statsEnabled()) self.stats.execute_ns += elapsedNs(execute_start);
        }
        return self.runTestsAfterInit();
    }

    pub fn writeStats(self: *VM, writer: std.io.AnyWriter, preprocess_ns: u64, parse_ns: u64, ffi_load_ns: u64, total_ns: u64, preprocess_cache_status: []const u8, parse_cache_status: []const u8) !void {
        try writer.print(
            "VM stats:\n" ++
                "  preprocess_ns={d}\n" ++
                "  preprocess_cache={s}\n" ++
                "  parse_ns={d}\n" ++
                "  parse_cache={s}\n" ++
                "  ffi_load_ns={d}\n" ++
                "  bind_ns={d}\n" ++
                "  execute_ns={d}\n" ++
                "  total_ns={d}\n" ++
                "  function_calls={d}\n" ++
                "  interpreted_calls={d}\n" ++
                "  bytecode_ops={d}\n" ++
                "  slow_ops={d}\n" ++
                "  fast_block_hits={d}\n" ++
                "  tail_restarts={d}\n" ++
                "  call_cache_hits={d}\n" ++
                "  call_cache_misses={d}\n" ++
                "  call_cache_stores={d}\n" ++
                "  call_cache_clears={d}\n" ++
                "  frame_pool_hits={d}\n" ++
                "  frame_pool_misses={d}\n" ++
                "  frame_pool_releases={d}\n" ++
                "  memory_epoch_bumps={d}\n" ++
                "  max_call_depth={d}\n",
            .{
                preprocess_ns,
                preprocess_cache_status,
                parse_ns,
                parse_cache_status,
                ffi_load_ns,
                self.stats.bind_ns,
                self.stats.execute_ns,
                total_ns,
                self.stats.function_calls,
                self.stats.interpreted_calls,
                self.stats.bytecode_ops,
                self.stats.slow_ops,
                self.stats.fast_block_hits,
                self.stats.tail_restarts,
                self.stats.call_cache_hits,
                self.stats.call_cache_misses,
                self.stats.call_cache_stores,
                self.stats.call_cache_clears,
                self.stats.frame_pool_hits,
                self.stats.frame_pool_misses,
                self.stats.frame_pool_releases,
                self.stats.memory_epoch_bumps,
                self.stats.max_call_depth,
            },
        );

        if (self.options.profile_top_n == 0) return;
        var rows = std.ArrayList(ProfileRow).init(self.allocator);
        defer rows.deinit();
        var it = self.function_profile.iterator();
        while (it.next()) |entry| {
            try rows.append(.{ .name = entry.key_ptr.*, .calls = entry.value_ptr.calls, .ns = entry.value_ptr.ns });
        }
        std.sort.heap(ProfileRow, rows.items, {}, profileRowLessThan);
        try writer.print("VM profile top {d}:\n", .{self.options.profile_top_n});
        const limit = @min(@as(usize, self.options.profile_top_n), rows.items.len);
        for (rows.items[0..limit]) |row| {
            const avg_ns = if (row.calls == 0) 0 else row.ns / row.calls;
            try writer.print("  {s} calls={d} total_ns={d} avg_ns={d}\n", .{ row.name, row.calls, row.ns, avg_ns });
        }
    }

    fn recordFunctionProfile(self: *VM, name: []const u8, ns: u64) !void {
        const entry = try self.function_profile.getOrPut(name);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.calls += 1;
        entry.value_ptr.ns +%= ns;
    }

    fn runTestsAfterInit(self: *VM) !i32 {
        var test_funcs = std.ArrayList(*const parser.Function).init(self.allocator);
        defer test_funcs.deinit();

        var func_it = self.program.functions.iterator();
        while (func_it.next()) |entry| {
            if (isTestFunctionName(entry.key_ptr.*)) {
                try test_funcs.append(entry.value_ptr);
            }
        }

        if (test_funcs.items.len == 0) {
            std.debug.print("Error: @main function not found and no @test functions found!\n", .{});
            return 1;
        }

        std.sort.heap(*const parser.Function, test_funcs.items, {}, testFunctionLessThan);
        for (test_funcs.items) |test_func| {
            if (test_func.params.len != 0) {
                std.debug.print("Error: @test function '{s}' must not take parameters!\n", .{test_func.name});
                return 1;
            }
            _ = try self.executeFunction(test_func, &.{});
        }
        return 0;
    }

    fn findBlockForPc(self: *VM, func: *const parser.Function, pc: usize) ?parser.BasicBlock {
        _ = self;
        for (func.blocks) |block| {
            if (pc >= block.start_inst and pc < block.end_inst) return block;
        }
        return null;
    }

    /// Determines at binding time whether the call at `pc` is a tail self-call.
    fn isTailSelfCallAt(self: *VM, func: *const parser.Function, pc: usize) bool {
        const block = self.findBlockForPc(func, pc) orelse return false;
        if (pc + 1 >= block.end_inst) return false;
        var idx = pc + 1;
        while (idx < block.end_inst) : (idx += 1) {
            const next = func.instructions[idx];
            if (next.op == .consume) continue;
            if (next.op == .return_) return idx == block.end_inst - 1;
            return false;
        }
        return false;
    }

    fn freeTrackedResultAlloc(self: *VM, ptr: usize) bool {
        if (self.result_alloc_index.count() == 0) return false;
        const idx = self.result_alloc_index.get(ptr) orelse return false;
        const buf = self.result_allocs.items[idx];
        self.allocator.free(buf);
        const last_idx = self.result_allocs.items.len - 1;
        if (idx != last_idx) {
            const moved = self.result_allocs.items[last_idx];
            self.result_allocs.items[idx] = moved;
            self.result_alloc_index.put(@intFromPtr(moved.ptr), idx) catch {};
        }
        _ = self.result_alloc_index.remove(ptr);
        _ = self.result_allocs.pop();
        return true;
    }

    /// Resolve a named call target to its ResolvedCall variant at binding time.
    fn resolveCallTarget(self: *VM, call_name: []const u8) ResolvedCall {
        if (std.mem.eql(u8, call_name, "sa_print_bytes")) return .builtin_print;
        if (SlaBuiltin.byName(call_name)) |sla_builtin| return .{ .sla_builtin = sla_builtin };
        if (std.mem.eql(u8, call_name, "sa_time_unix_ms")) return .builtin_time_ms;
        if (std.mem.eql(u8, call_name, "sa_time_unix_s")) return .builtin_time_s;
        if (std.mem.eql(u8, call_name, "sa_time_unix_ns")) return .builtin_time_ns;
        if (std.mem.eql(u8, call_name, "sa_time_instant_ns")) return .builtin_time_instant_ns;
        if (std.mem.eql(u8, call_name, "pthread_spawn")) return .pthread_spawn;
        if (std.mem.eql(u8, call_name, "pthread_spawn_detached")) return .pthread_spawn_detached;
        if (std.mem.eql(u8, call_name, "pthread_join")) return .pthread_join;
        if (std.mem.eql(u8, call_name, "pthread_drop")) return .pthread_drop;
        if (self.function_ptrs.get(call_name)) |target_func| {
            return ResolvedCall{ .interpreted = target_func };
        }
        if (self.program.externs.getPtr(call_name)) |sig| {
            if (self.ffi.resolveSymbol(call_name)) |sym| {
                return ResolvedCall{ .ffi_typed = .{ .sym = sym, .sig = sig.* } };
            }
        }
        if (self.ffi.resolveSymbol(call_name)) |sym| {
            return ResolvedCall{ .ffi_legacy = sym };
        }
        return .unresolved;
    }

    fn functionHasOp(func: *const parser.Function, op: parser.OpCode) bool {
        for (func.instructions) |inst| {
            if (inst.op == op) return true;
        }
        return false;
    }

    fn functionReadsMemory(func: *const parser.Function) bool {
        for (func.instructions) |inst| {
            switch (inst.op) {
                .load, .atomic_load, .take, .try_ => return true,
                else => {},
            }
        }
        return false;
    }

    fn functionHasExternalSideEffect(self: *VM, func: *const parser.Function) bool {
        _ = self;
        for (func.instructions) |inst| {
            switch (inst.op) {
                .alloc, .atomic_store, .cmpxchg, .atomic_rmw_add, .panic, .panic_msg, .take, .try_ => return true,
                .store => if (!inst.is_local_stack_write) return true,
                .call => return true,
                .call_indirect => return true,
                else => {},
            }
        }
        return false;
    }

    fn programCanCreateTrackedResultAlloc(self: *VM) bool {
        var func_it = self.program.functions.iterator();
        while (func_it.next()) |entry| {
            const func = entry.value_ptr;
            if (func.returns_result and !std.mem.eql(u8, func.name, "main")) return true;
        }
        return false;
    }

    fn isDeadPureCandidate(op: parser.OpCode) bool {
        return switch (op) {
            .ptr_add,
            .add,
            .sub,
            .mul,
            .div,
            .rem,
            .and_,
            .or_,
            .xor_,
            .sdiv,
            .udiv,
            .srem,
            .urem,
            .shl,
            .shr,
            .gt,
            .lt,
            .load,
            .eq,
            .ne,
            .sgt,
            .slt,
            .sge,
            .sle,
            .ugt,
            .ult,
            .uge,
            .ule,
            .assign,
            .raw_cast,
            .bitcast,
            .sext,
            .zext,
            .trunc,
            .take,
            => true,
            else => false,
        };
    }

    fn countOperandUse(use_counts: []u32, arg: parser.Operand) void {
        switch (arg.kind) {
            .register, .stack_addr, .offset_addr => if (arg.slot_idx != INVALID_SLOT and arg.slot_idx < use_counts.len) {
                use_counts[arg.slot_idx] += 1;
            },
            else => {},
        }
    }

    fn decrementOperandUse(use_counts: []u32, arg: parser.Operand) void {
        switch (arg.kind) {
            .register, .stack_addr, .offset_addr => if (arg.slot_idx != INVALID_SLOT and arg.slot_idx < use_counts.len and use_counts[arg.slot_idx] > 0) {
                use_counts[arg.slot_idx] -= 1;
            },
            else => {},
        }
    }

    fn isImmediateAssignCandidate(inst: *const parser.Instruction) bool {
        if (inst.op != .assign or inst.dest_slot == INVALID_SLOT or inst.args.len != 1) return false;
        return switch (inst.args[0].kind) {
            .immediate, .constant_addr => true,
            else => false,
        };
    }

    fn inlineConstantOperand(arg: *parser.Operand, slot: u32, source: parser.Operand) bool {
        switch (arg.kind) {
            .register, .stack_addr => {
                if (arg.slot_idx != slot) return false;
                arg.kind = source.kind;
                arg.imm_val = source.imm_val;
                arg.offset = 0;
                arg.slot_idx = INVALID_SLOT;
                return true;
            },
            .offset_addr => {
                if (arg.slot_idx != slot) return false;
                const base = @as(usize, @intCast(source.imm_val));
                const offset_bits: usize = @bitCast(@as(isize, arg.offset));
                arg.kind = .immediate;
                arg.imm_val = @as(u64, @intCast(base +% offset_bits));
                arg.offset = 0;
                arg.slot_idx = INVALID_SLOT;
                return true;
            },
            else => return false,
        }
    }

    fn inlineBlockLocalImmediateAssigns(func: *parser.Function) void {
        for (func.blocks) |block| {
            var pc = block.start_inst;
            while (pc < block.end_inst) : (pc += 1) {
                const inst = &func.instructions[pc];
                if (!isImmediateAssignCandidate(inst)) continue;

                const slot = inst.dest_slot;
                const source = inst.args[0];
                var next_pc = pc + 1;
                while (next_pc < block.end_inst) : (next_pc += 1) {
                    const next = &func.instructions[next_pc];
                    if (next.dest_slot == slot or next.dest_slot2 == slot) break;
                    for (next.args) |*arg| {
                        _ = inlineConstantOperand(arg, slot, source);
                    }
                }
            }
        }
    }

    const TrackedResultState = enum(u2) {
        unknown,
        no_result,
        maybe_result,
    };

    fn operandTrackedResultState(states: []const TrackedResultState, arg: parser.Operand) TrackedResultState {
        return switch (arg.kind) {
            .immediate, .constant_addr, .label => .no_result,
            .register, .stack_addr => if (arg.slot_idx != INVALID_SLOT and arg.slot_idx < states.len) states[arg.slot_idx] else .unknown,
            .offset_addr => if (arg.offset == 0 and arg.slot_idx != INVALID_SLOT and arg.slot_idx < states.len) states[arg.slot_idx] else .no_result,
        };
    }

    fn classifyTrackedPrimaryResult(inst: *const parser.Instruction, call_target: ResolvedCall, states: []const TrackedResultState) TrackedResultState {
        return switch (inst.op) {
            .call => switch (call_target) {
                .interpreted => |target_func| if (target_func.returns_result) .maybe_result else .no_result,
                .ffi_typed => |ft| if (ft.sig.returns_result) .maybe_result else .no_result,
                .builtin_print,
                .builtin_time_ms,
                .builtin_time_s,
                .builtin_time_ns,
                .builtin_time_instant_ns,
                .sla_builtin,
                .pthread_spawn,
                .pthread_spawn_detached,
                .pthread_join,
                .pthread_drop,
                => .no_result,
                .ffi_legacy, .unresolved => .maybe_result,
            },
            .call_indirect,
            .load,
            .atomic_load,
            .take,
            .try_,
            .atomic_rmw_add,
            => .maybe_result,
            .assign,
            .assume_safe,
            .assume_borrow,
            .raw_cast,
            .bitcast,
            => if (inst.args.len > 0) operandTrackedResultState(states, inst.args[0]) else .unknown,
            .stack_alloc,
            .alloc,
            .ptr_add,
            .add,
            .sub,
            .mul,
            .div,
            .rem,
            .and_,
            .or_,
            .xor_,
            .sdiv,
            .udiv,
            .srem,
            .urem,
            .shl,
            .shr,
            .gt,
            .lt,
            .eq,
            .ne,
            .sgt,
            .slt,
            .sge,
            .sle,
            .ugt,
            .ult,
            .uge,
            .ule,
            .sext,
            .zext,
            .trunc,
            => .no_result,
            .cmpxchg,
            => .maybe_result,
            else => .unknown,
        };
    }

    fn rewriteInstToNoOp(inst: *parser.Instruction) void {
        inst.op = .assign;
        inst.dest_slot = INVALID_SLOT;
        inst.dest_slot2 = INVALID_SLOT;
        inst.src_slot = INVALID_SLOT;
        for (inst.args) |*arg| {
            arg.kind = .immediate;
            arg.imm_val = 0;
            arg.offset = 0;
            arg.slot_idx = INVALID_SLOT;
        }
    }

    fn freeInstructionOwnedFields(allocator: std.mem.Allocator, inst: parser.Instruction) void {
        if (inst.dest) |dest| allocator.free(dest);
        for (inst.args) |arg| allocator.free(arg.name);
        allocator.free(inst.args);
    }

    fn elideNoopConsumes(self: *VM, func: *parser.Function, slot_count: usize, call_targets: []const ResolvedCall, tracked_results_possible: bool) !void {
        const states = try self.allocator.alloc(TrackedResultState, @max(slot_count, 1));
        defer self.allocator.free(states);

        @memset(states, .unknown);
        for (func.instructions, 0..) |*inst, pc| {
            if (inst.op == .consume) {
                if (!tracked_results_possible or (inst.args.len > 0 and operandTrackedResultState(states, inst.args[0]) == .no_result)) {
                    rewriteInstToNoOp(inst);
                }
            }

            if (inst.dest_slot != INVALID_SLOT) {
                states[inst.dest_slot] = classifyTrackedPrimaryResult(inst, call_targets[pc], states);
            }
            if (inst.op == .cmpxchg and inst.dest_slot2 != INVALID_SLOT) {
                states[inst.dest_slot2] = .no_result;
            }
        }
    }

    fn compactNoOpInstructions(self: *VM, func: *parser.Function, call_targets: []ResolvedCall) ![]ResolvedCall {
        const old_insts = func.instructions;
        if (old_insts.len == 0) return call_targets;

        const keep = try self.allocator.alloc(bool, old_insts.len);
        defer self.allocator.free(keep);

        var kept_count: usize = 0;
        for (old_insts, 0..) |inst, idx| {
            const keep_inst = !(inst.op == .assign and inst.dest_slot == INVALID_SLOT);
            keep[idx] = keep_inst;
            if (keep_inst) kept_count += 1;
        }
        if (kept_count == old_insts.len) return call_targets;

        const old_to_new_next = try self.allocator.alloc(usize, old_insts.len + 1);
        defer self.allocator.free(old_to_new_next);
        old_to_new_next[old_insts.len] = kept_count;
        var next_pc = kept_count;
        var rev = old_insts.len;
        while (rev > 0) {
            rev -= 1;
            if (keep[rev]) next_pc -= 1;
            old_to_new_next[rev] = next_pc;
        }

        const new_insts = try self.program.allocator.alloc(parser.Instruction, kept_count);
        errdefer self.program.allocator.free(new_insts);
        const new_call_targets = try self.allocator.alloc(ResolvedCall, kept_count);
        errdefer self.allocator.free(new_call_targets);
        const new_blocks = try self.program.allocator.alloc(parser.BasicBlock, func.blocks.len);
        errdefer self.program.allocator.free(new_blocks);

        var new_idx: usize = 0;
        for (old_insts, 0..) |inst, old_idx| {
            if (!keep[old_idx]) continue;
            const copied = inst;
            switch (copied.op) {
                .br => if (copied.args.len >= 3) {
                    copied.args[1].pc_target = old_to_new_next[copied.args[1].pc_target];
                    copied.args[2].pc_target = old_to_new_next[copied.args[2].pc_target];
                },
                .jmp => if (copied.args.len >= 1) {
                    copied.args[0].pc_target = old_to_new_next[copied.args[0].pc_target];
                },
                else => {},
            }
            new_insts[new_idx] = copied;
            new_call_targets[new_idx] = call_targets[old_idx];
            new_idx += 1;
        }

        for (func.blocks, 0..) |block, block_idx| {
            new_blocks[block_idx] = .{
                .label = block.label,
                .start_inst = old_to_new_next[block.start_inst],
                .end_inst = old_to_new_next[block.end_inst],
            };
        }

        for (old_insts, 0..) |inst, old_idx| {
            if (!keep[old_idx]) freeInstructionOwnedFields(self.program.allocator, inst);
        }

        self.program.allocator.free(old_insts);
        self.program.allocator.free(func.blocks);
        self.allocator.free(call_targets);
        func.instructions = new_insts;
        func.blocks = new_blocks;
        return new_call_targets;
    }

    fn blockIndexForPc(func: *const parser.Function, pc: usize) ?usize {
        for (func.blocks, 0..) |block, idx| {
            if (pc == block.start_inst) return idx;
        }
        if (pc >= func.instructions.len) return func.blocks.len;
        for (func.blocks, 0..) |block, idx| {
            if (pc >= block.start_inst and pc < block.end_inst) return idx;
        }
        return null;
    }

    fn slotByte(slot: u32) ?u8 {
        if (slot == INVALID_SLOT or slot >= BYTE_SLOT_NONE) return null;
        return @as(u8, @intCast(slot));
    }

    fn offsetByte(offset: i32) ?u8 {
        if (offset < std.math.minInt(i8) or offset > std.math.maxInt(i8)) return null;
        return @as(u8, @bitCast(@as(i8, @intCast(offset))));
    }

    fn packABC(op: ByteOp, a: u8, b: u8, c: u8) u32 {
        return @as(u32, @intFromEnum(op)) |
            (@as(u32, a) << 8) |
            (@as(u32, b) << 16) |
            (@as(u32, c) << 24);
    }

    fn packA16(op: ByteOp, a: u8, imm16: u16) u32 {
        return @as(u32, @intFromEnum(op)) |
            (@as(u32, a) << 8) |
            (@as(u32, imm16) << 16);
    }

    fn packPayload(op: ByteOp, payload: u32) !u32 {
        if (payload > BYTECODE_PAYLOAD_MAX) return error.BytecodeIndexTooLarge;
        return @as(u32, @intFromEnum(op)) | (payload << 8);
    }

    fn rawOp(raw: u32) ByteOp {
        return @as(ByteOp, @enumFromInt(@as(u8, @truncate(raw))));
    }

    fn rawA(raw: u32) u8 {
        return @as(u8, @truncate(raw >> 8));
    }

    fn rawB(raw: u32) u8 {
        return @as(u8, @truncate(raw >> 16));
    }

    fn rawC(raw: u32) u8 {
        return @as(u8, @truncate(raw >> 24));
    }

    fn rawPayload(raw: u32) usize {
        return @as(usize, @intCast(raw >> 8));
    }

    fn packSlots4(slots: [4]u8) u32 {
        return @as(u32, slots[0]) |
            (@as(u32, slots[1]) << 8) |
            (@as(u32, slots[2]) << 16) |
            (@as(u32, slots[3]) << 24);
    }

    fn compiledOperand(arg: parser.Operand) CompiledOperand {
        return switch (arg.kind) {
            .immediate, .constant_addr => .{ .kind = .immediate, .imm = arg.imm_val },
            .register, .stack_addr => .{ .kind = .register, .slot = arg.slot_idx },
            .offset_addr => .{ .kind = .offset_addr, .slot = arg.slot_idx, .offset = arg.offset },
            .label => .{ .kind = .immediate, .imm = arg.pc_target },
        };
    }

    fn termCmpOp(op: parser.OpCode) TermCmpOp {
        return switch (op) {
            .eq => .eq,
            .ne => .ne,
            .ugt => .ugt,
            .ult => .ult,
            .uge => .uge,
            .ule => .ule,
            .sgt, .gt => .sgt,
            .slt, .lt => .slt,
            .sge => .sge,
            .sle => .sle,
            else => .none,
        };
    }

    fn packTermCmp(op: TermCmpOp, lhs: u8, rhs: u8, rhs_is_const: bool) u32 {
        return @as(u32, @intFromEnum(op)) |
            (@as(u32, lhs) << 8) |
            (@as(u32, rhs) << 16) |
            (@as(u32, @intFromBool(rhs_is_const)) << 24);
    }

    fn addConstant(constants: *std.ArrayList(u64), value: u64) !u32 {
        const idx = constants.items.len;
        if (idx > std.math.maxInt(u32)) return error.BytecodeIndexTooLarge;
        try constants.append(value);
        return @as(u32, @intCast(idx));
    }

    fn appendSlow(code: *std.ArrayList(u32), slow_inst_pcs: *std.ArrayList(usize), inst_pc: usize) !void {
        const idx = slow_inst_pcs.items.len;
        if (idx > BYTECODE_PAYLOAD_MAX) return error.BytecodeIndexTooLarge;
        try slow_inst_pcs.append(inst_pc);
        try code.append(try packPayload(.slow, @as(u32, @intCast(idx))));
    }

    fn addrBaseOffset8(arg: parser.Operand) ?struct { base: u8, offset: u8 } {
        return switch (arg.kind) {
            .register, .stack_addr => blk: {
                const base = slotByte(arg.slot_idx) orelse break :blk null;
                break :blk .{ .base = base, .offset = @as(u8, @bitCast(@as(i8, 0))) };
            },
            .offset_addr => blk: {
                const base = slotByte(arg.slot_idx) orelse break :blk null;
                const off = offsetByte(arg.offset) orelse break :blk null;
                break :blk .{ .base = base, .offset = off };
            },
            else => null,
        };
    }

    fn appendBinary(
        code: *std.ArrayList(u32),
        constants: *std.ArrayList(u64),
        slow_inst_pcs: *std.ArrayList(usize),
        inst: *const parser.Instruction,
        inst_pc: usize,
        rr_op: ByteOp,
        rc_op: ByteOp,
    ) !void {
        const dest = slotByte(inst.dest_slot) orelse return appendSlow(code, slow_inst_pcs, inst_pc);
        if (inst.args.len < 2) return appendSlow(code, slow_inst_pcs, inst_pc);
        const lhs = slotByte(inst.args[0].slot_idx) orelse return appendSlow(code, slow_inst_pcs, inst_pc);
        switch (inst.args[1].kind) {
            .register, .stack_addr => {
                const rhs = slotByte(inst.args[1].slot_idx) orelse return appendSlow(code, slow_inst_pcs, inst_pc);
                try code.append(packABC(rr_op, dest, lhs, rhs));
            },
            .immediate, .constant_addr => {
                if (rc_op == rr_op) return appendSlow(code, slow_inst_pcs, inst_pc);
                const const_idx = try addConstant(constants, inst.args[1].imm_val);
                if (const_idx > std.math.maxInt(u8)) return appendSlow(code, slow_inst_pcs, inst_pc);
                try code.append(packABC(rc_op, dest, lhs, @as(u8, @intCast(const_idx))));
            },
            else => return appendSlow(code, slow_inst_pcs, inst_pc),
        }
    }

    fn compileTermCmp(
        constants: *std.ArrayList(u64),
        cmp_inst: parser.Instruction,
        br_inst: parser.Instruction,
        use_counts: []const u32,
    ) !?u32 {
        const op = termCmpOp(cmp_inst.op);
        if (op == .none) return null;
        if (cmp_inst.dest_slot == INVALID_SLOT or cmp_inst.args.len < 2 or br_inst.args.len < 1) return null;
        if (br_inst.args[0].slot_idx != cmp_inst.dest_slot) return null;
        if (cmp_inst.dest_slot >= use_counts.len or use_counts[cmp_inst.dest_slot] != 1) return null;

        const lhs = slotByte(cmp_inst.args[0].slot_idx) orelse return null;
        switch (cmp_inst.args[1].kind) {
            .register, .stack_addr => {
                const rhs = slotByte(cmp_inst.args[1].slot_idx) orelse return null;
                return packTermCmp(op, lhs, rhs, false);
            },
            .immediate, .constant_addr => {
                const const_idx = try addConstant(constants, cmp_inst.args[1].imm_val);
                if (const_idx > std.math.maxInt(u8)) return null;
                return packTermCmp(op, lhs, @as(u8, @intCast(const_idx)), true);
            },
            else => return null,
        }
    }

    fn appendAddUdiv2(
        code: *std.ArrayList(u32),
        insts: []const parser.Instruction,
        pc: usize,
        body_end: usize,
        use_counts: []const u32,
    ) !bool {
        if (pc + 1 >= body_end) return false;
        const add_inst = insts[pc];
        const div_inst = insts[pc + 1];
        if (add_inst.op != .add or add_inst.dest_slot == INVALID_SLOT or add_inst.args.len < 2) return false;
        if (add_inst.dest_slot >= use_counts.len or use_counts[add_inst.dest_slot] != 1) return false;
        if ((div_inst.op != .udiv and div_inst.op != .div) or div_inst.dest_slot == INVALID_SLOT or div_inst.args.len < 2) return false;
        if (div_inst.args[0].slot_idx != add_inst.dest_slot) return false;
        if (!((div_inst.args[1].kind == .immediate or div_inst.args[1].kind == .constant_addr) and div_inst.args[1].imm_val == 2)) return false;

        const dest = slotByte(div_inst.dest_slot) orelse return false;
        const lhs = slotByte(add_inst.args[0].slot_idx) orelse return false;
        const rhs = slotByte(add_inst.args[1].slot_idx) orelse return false;
        try code.append(packABC(.avg2_rr, dest, lhs, rhs));
        return true;
    }

    fn appendIndexedLoad8(
        code: *std.ArrayList(u32),
        insts: []const parser.Instruction,
        pc: usize,
        body_end: usize,
        use_counts: []const u32,
    ) !bool {
        if (pc + 2 >= body_end) return false;
        const mul_inst = insts[pc];
        const ptr_inst = insts[pc + 1];
        const load_inst = insts[pc + 2];

        if (mul_inst.op != .mul or mul_inst.dest_slot == INVALID_SLOT or mul_inst.args.len < 2) return false;
        if (!((mul_inst.args[1].kind == .immediate or mul_inst.args[1].kind == .constant_addr) and mul_inst.args[1].imm_val == 8)) return false;
        if (mul_inst.dest_slot >= use_counts.len or use_counts[mul_inst.dest_slot] != 1) return false;

        if (ptr_inst.op != .ptr_add or ptr_inst.dest_slot == INVALID_SLOT or ptr_inst.args.len < 2) return false;
        if (ptr_inst.args[1].slot_idx != mul_inst.dest_slot) return false;
        if (ptr_inst.dest_slot >= use_counts.len or use_counts[ptr_inst.dest_slot] != 1) return false;

        if (load_inst.op != .load or load_inst.dest_slot == INVALID_SLOT or load_inst.args.len < 1) return false;
        const addr = load_inst.args[0];
        if (addr.kind != .offset_addr or addr.slot_idx != ptr_inst.dest_slot or addr.offset != 0) return false;

        const dest = slotByte(load_inst.dest_slot) orelse return false;
        const base = slotByte(ptr_inst.args[0].slot_idx) orelse return false;
        const index = slotByte(mul_inst.args[0].slot_idx) orelse return false;
        switch (load_inst.dest_type) {
            .ptr, .i64, .u64 => try code.append(packABC(.load_u64_index8, dest, base, index)),
            else => return false,
        }
        return true;
    }

    fn isFastAvgLoadEqBlock(code: []const u32, block: CompiledBlock) bool {
        if (block.term_kind != .br or block.term_cmp == 0) return false;
        if (block.end != block.start + 2) return false;

        const cmp_op: TermCmpOp = @enumFromInt(@as(u8, @truncate(block.term_cmp)));
        if (cmp_op != .eq or ((block.term_cmp >> 24) & 1) != 0) return false;

        const avg = code[block.start];
        const load = code[block.start + 1];
        if (rawOp(avg) != .avg2_rr or rawOp(load) != .load_u64_index8) return false;

        const mid_slot = rawA(avg);
        const val_slot = rawA(load);
        const load_index_slot = rawC(load);
        const cmp_lhs = @as(u8, @truncate(block.term_cmp >> 8));
        if (load_index_slot != mid_slot or cmp_lhs != val_slot) return false;
        return true;
    }

    fn fastTailBinRcKind(code: []const u32, block: CompiledBlock) ?BlockTermKind {
        if (block.term_kind != .return_ or block.end < block.start + 3) return null;
        const calc = code[block.start];
        const tail = code[block.start + 1];
        const kind: BlockTermKind = switch (rawOp(calc)) {
            .add_rc => .fast_tail_add_rc,
            .sub_rc => .fast_tail_sub_rc,
            else => return null,
        };
        if (rawOp(tail) != .tail_self_regs) return null;

        const calc_dest = rawA(calc);
        const argc = rawA(tail);
        if (argc == 0 or argc > 4) return null;
        const slots = code[block.start + 2];
        var idx: u8 = 0;
        while (idx < argc) : (idx += 1) {
            if (@as(u8, @truncate(slots >> (@as(u5, @intCast(idx)) * 8))) == calc_dest) return kind;
        }
        return null;
    }

    fn fastEmptyBrKind(block: CompiledBlock) ?BlockTermKind {
        if (block.term_kind != .br or block.term_cmp == 0 or block.end != block.start) return null;
        const rhs_is_const = ((block.term_cmp >> 24) & 1) != 0;
        const op: TermCmpOp = @enumFromInt(@as(u8, @truncate(block.term_cmp)));
        return switch (op) {
            .eq => if (rhs_is_const) .fast_br_eq_rc else .fast_br_eq_rr,
            .ugt => if (!rhs_is_const) .fast_br_ugt_rr else null,
            .ult => if (!rhs_is_const) .fast_br_ult_rr else null,
            else => null,
        };
    }

    fn appendCall(
        self: *VM,
        code: *std.ArrayList(u32),
        calls: *std.ArrayList(CallMetadata),
        inst: *const parser.Instruction,
        inst_pc: usize,
        target: ResolvedCall,
        can_emit_tail_self_regs: bool,
    ) !void {
        if (inst.args.len == 0) return error.SymbolNotFound;
        const arg_count = inst.args.len - 1;
        if (can_emit_tail_self_regs and inst.is_tail_call and arg_count <= 4) {
            var slots = [_]u8{ 0, 0, 0, 0 };
            for (inst.args[1..], 0..) |arg, idx| {
                switch (arg.kind) {
                    .register, .stack_addr => slots[idx] = slotByte(arg.slot_idx) orelse break,
                    else => break,
                }
            } else {
                try code.append(packABC(.tail_self_regs, @as(u8, @intCast(arg_count)), 0, 0));
                try code.append(packSlots4(slots));
                return;
            }
        }
        const args = try self.allocator.alloc(CompiledOperand, arg_count);
        errdefer self.allocator.free(args);
        for (inst.args[1..], 0..) |arg, idx| args[idx] = compiledOperand(arg);
        const idx = calls.items.len;
        if (idx > BYTECODE_PAYLOAD_MAX) return error.BytecodeIndexTooLarge;
        try calls.append(.{
            .inst_pc = inst_pc,
            .dest_slot = inst.dest_slot,
            .target = target,
            .is_tail_call = inst.is_tail_call,
            .args = args,
        });
        try code.append(try packPayload(.call, @as(u32, @intCast(idx))));
    }

    fn appendIndirectCall(
        self: *VM,
        code: *std.ArrayList(u32),
        indirect_calls: *std.ArrayList(IndirectCallMetadata),
        inst: *const parser.Instruction,
        inst_pc: usize,
    ) !void {
        if (inst.args.len == 0) return error.SymbolNotFound;
        const arg_count = inst.args.len - 1;
        const args = try self.allocator.alloc(CompiledOperand, arg_count);
        errdefer self.allocator.free(args);
        for (inst.args[1..], 0..) |arg, idx| args[idx] = compiledOperand(arg);
        const idx = indirect_calls.items.len;
        if (idx > BYTECODE_PAYLOAD_MAX) return error.BytecodeIndexTooLarge;
        try indirect_calls.append(.{
            .inst_pc = inst_pc,
            .dest_slot = inst.dest_slot,
            .fn_ptr = compiledOperand(inst.args[0]),
            .args = args,
        });
        try code.append(try packPayload(.call_indirect, @as(u32, @intCast(idx))));
    }

    fn compileInstruction(
        self: *VM,
        code: *std.ArrayList(u32),
        constants: *std.ArrayList(u64),
        slow_inst_pcs: *std.ArrayList(usize),
        calls: *std.ArrayList(CallMetadata),
        indirect_calls: *std.ArrayList(IndirectCallMetadata),
        inst: *const parser.Instruction,
        inst_pc: usize,
        call_target: ResolvedCall,
        needs_arena: bool,
    ) !void {
        switch (inst.op) {
            .assign, .assume_safe, .assume_borrow, .raw_cast, .bitcast => {
                const dest = slotByte(inst.dest_slot) orelse return;
                if (inst.src_slot != INVALID_SLOT) {
                    const src = slotByte(inst.src_slot) orelse return appendSlow(code, slow_inst_pcs, inst_pc);
                    try code.append(packABC(.assign_rr, dest, src, 0));
                } else if (inst.args.len > 0 and (inst.args[0].kind == .immediate or inst.args[0].kind == .constant_addr)) {
                    const const_idx = try addConstant(constants, inst.args[0].imm_val);
                    if (const_idx > std.math.maxInt(u16)) return appendSlow(code, slow_inst_pcs, inst_pc);
                    try code.append(packA16(.load_const, dest, @as(u16, @intCast(const_idx))));
                } else {
                    return appendSlow(code, slow_inst_pcs, inst_pc);
                }
            },
            .add => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .add_rr, .add_rc),
            .sub => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .sub_rr, .sub_rc),
            .mul => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .mul_rr, .mul_rc),
            .div, .udiv => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .udiv_rr, .udiv_rc),
            .rem, .urem => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .urem_rr, .urem_rc),
            .ptr_add => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .ptr_add_rr, .ptr_add_rc),
            .and_ => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .and_rr, .and_rr),
            .or_ => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .or_rr, .or_rr),
            .xor_ => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .xor_rr, .xor_rr),
            .eq => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .eq_rr, .eq_rc),
            .ne => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .ne_rr, .ne_rc),
            .ugt => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .ugt_rr, .ugt_rc),
            .ult => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .ult_rr, .ult_rc),
            .uge => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .uge_rr, .uge_rc),
            .ule => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .ule_rr, .ule_rc),
            .sgt, .gt => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .sgt_rr, .sgt_rc),
            .slt, .lt => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .slt_rr, .slt_rc),
            .sge => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .sge_rr, .sge_rc),
            .sle => try appendBinary(code, constants, slow_inst_pcs, inst, inst_pc, .sle_rr, .sle_rc),
            .load => {
                const dest = slotByte(inst.dest_slot) orelse return appendSlow(code, slow_inst_pcs, inst_pc);
                if (inst.args.len < 1) return appendSlow(code, slow_inst_pcs, inst_pc);
                const addr = addrBaseOffset8(inst.args[0]) orelse return appendSlow(code, slow_inst_pcs, inst_pc);
                switch (inst.dest_type) {
                    .ptr, .i64, .u64 => try code.append(packABC(.load_u64_off8, dest, addr.base, addr.offset)),
                    else => return appendSlow(code, slow_inst_pcs, inst_pc),
                }
            },
            .store => {
                if (inst.args.len < 2) return appendSlow(code, slow_inst_pcs, inst_pc);
                const addr = addrBaseOffset8(inst.args[1]) orelse return appendSlow(code, slow_inst_pcs, inst_pc);
                switch (inst.dest_type) {
                    .ptr, .i64, .u64 => switch (inst.args[0].kind) {
                        .register, .stack_addr => {
                            const val = slotByte(inst.args[0].slot_idx) orelse return appendSlow(code, slow_inst_pcs, inst_pc);
                            const op: ByteOp = if (inst.is_local_stack_write) .store_u64_local_reg_off8 else .store_u64_reg_off8;
                            try code.append(packABC(op, val, addr.base, addr.offset));
                        },
                        .immediate, .constant_addr => {
                            const const_idx = try addConstant(constants, inst.args[0].imm_val);
                            if (const_idx > std.math.maxInt(u8)) return appendSlow(code, slow_inst_pcs, inst_pc);
                            const op: ByteOp = if (inst.is_local_stack_write) .store_u64_local_const_off8 else .store_u64_const_off8;
                            try code.append(packABC(op, @as(u8, @intCast(const_idx)), addr.base, addr.offset));
                        },
                        else => return appendSlow(code, slow_inst_pcs, inst_pc),
                    },
                    else => return appendSlow(code, slow_inst_pcs, inst_pc),
                }
            },
            .call => try self.appendCall(code, calls, inst, inst_pc, call_target, self.options.enable_tail_restart and !needs_arena),
            .call_indirect => try self.appendIndirectCall(code, indirect_calls, inst, inst_pc),
            .consume => {
                if (inst.args.len < 1) return;
                const slot = slotByte(inst.args[0].slot_idx) orelse return appendSlow(code, slow_inst_pcs, inst_pc);
                try code.append(packABC(.consume_reg, slot, 0, 0));
            },
            .take => {
                const dest = slotByte(inst.dest_slot) orelse return appendSlow(code, slow_inst_pcs, inst_pc);
                if (inst.args.len < 1) return appendSlow(code, slow_inst_pcs, inst_pc);
                const addr = addrBaseOffset8(inst.args[0]) orelse return appendSlow(code, slow_inst_pcs, inst_pc);
                try code.append(packABC(.take_off8, dest, addr.base, addr.offset));
            },
            .try_ => {
                const dest = slotByte(inst.dest_slot) orelse BYTE_SLOT_NONE;
                if (inst.args.len < 1) return appendSlow(code, slow_inst_pcs, inst_pc);
                const slot = slotByte(inst.args[0].slot_idx) orelse return appendSlow(code, slow_inst_pcs, inst_pc);
                try code.append(packABC(.try_reg, dest, slot, 0));
            },
            .br, .jmp, .return_ => {},
            else => try appendSlow(code, slow_inst_pcs, inst_pc),
        }
    }

    fn compileFunction(
        self: *VM,
        func: *const parser.Function,
        call_targets: []ResolvedCall,
        slot_count: usize,
        needs_arena: bool,
        cacheable: bool,
        reads_memory: bool,
    ) !CompiledFunction {
        var code = std.ArrayList(u32).init(self.allocator);
        errdefer code.deinit();
        var blocks = std.ArrayList(CompiledBlock).init(self.allocator);
        errdefer blocks.deinit();
        var constants = std.ArrayList(u64).init(self.allocator);
        errdefer constants.deinit();
        var slow_inst_pcs = std.ArrayList(usize).init(self.allocator);
        errdefer slow_inst_pcs.deinit();
        var calls = std.ArrayList(CallMetadata).init(self.allocator);
        errdefer {
            for (calls.items) |meta| self.allocator.free(meta.args);
            calls.deinit();
        }
        var indirect_calls = std.ArrayList(IndirectCallMetadata).init(self.allocator);
        errdefer {
            for (indirect_calls.items) |meta| self.allocator.free(meta.args);
            indirect_calls.deinit();
        }

        const use_counts = try self.allocator.alloc(u32, @max(slot_count, 1));
        defer self.allocator.free(use_counts);
        @memset(use_counts, 0);
        for (func.instructions) |inst| {
            for (inst.args) |arg| countOperandUse(use_counts, arg);
        }

        for (func.blocks, 0..) |block, block_idx| {
            var term = CompiledBlock{ .start = code.items.len, .end = code.items.len };
            var body_end = block.end_inst;
            if (block.start_inst < block.end_inst) {
                const term_pc = block.end_inst - 1;
                const term_inst = func.instructions[term_pc];
                switch (term_inst.op) {
                    .br => if (term_inst.args.len >= 3) {
                        body_end = term_pc;
                        term.term_kind = .br;
                        term.term_pc = term_pc;
                        term.cond = compiledOperand(term_inst.args[0]);
                        term.true_block = blockIndexForPc(func, term_inst.args[1].pc_target) orelse return error.LabelNotFound;
                        term.false_block = blockIndexForPc(func, term_inst.args[2].pc_target) orelse return error.LabelNotFound;
                        if (term_pc > block.start_inst) {
                            const cmp_pc = term_pc - 1;
                            if (try compileTermCmp(&constants, func.instructions[cmp_pc], term_inst, use_counts)) |term_cmp| {
                                body_end = cmp_pc;
                                term.term_cmp = term_cmp;
                            }
                        }
                    },
                    .jmp => if (term_inst.args.len >= 1) {
                        body_end = term_pc;
                        term.term_kind = .jmp;
                        term.term_pc = term_pc;
                        term.true_block = blockIndexForPc(func, term_inst.args[0].pc_target) orelse return error.LabelNotFound;
                    },
                    .return_ => {
                        body_end = term_pc;
                        term.term_kind = .return_;
                        term.term_pc = term_pc;
                        if (term_inst.args.len > 0) term.ret = compiledOperand(term_inst.args[0]);
                    },
                    else => {},
                }
            }

            var pc = block.start_inst;
            while (pc < body_end) {
                if (self.options.enable_block_fastpath and try appendAddUdiv2(&code, func.instructions, pc, body_end, use_counts)) {
                    pc += 2;
                    continue;
                }
                if (self.options.enable_block_fastpath and try appendIndexedLoad8(&code, func.instructions, pc, body_end, use_counts)) {
                    pc += 3;
                    continue;
                }
                try self.compileInstruction(&code, &constants, &slow_inst_pcs, &calls, &indirect_calls, &func.instructions[pc], pc, call_targets[pc], needs_arena);
                pc += 1;
            }
            term.end = code.items.len;
            var fast_term: ?BlockTermKind = null;
            if (self.options.enable_block_fastpath and isFastAvgLoadEqBlock(code.items, term)) {
                fast_term = .fast_avg_load_eq_rr;
            } else if (self.options.enable_tail_restart) {
                fast_term = fastTailBinRcKind(code.items, term);
            }
            if (fast_term == null and self.options.enable_block_fastpath) {
                fast_term = fastEmptyBrKind(term);
            }
            if (fast_term) |fast_kind| {
                term.term_kind = fast_kind;
            }
            if (term.term_kind == .end and block_idx + 1 < func.blocks.len) {
                term.term_kind = .fallthrough;
                term.true_block = block_idx + 1;
            }
            try blocks.append(term);
        }

        // Per-block fuel cost table (spec §3.1 step 1). Built whenever any
        // hot-loop cap is active: it both prices blocks for fuel and acts as
        // the dispatch hook for lazy wall-clock sampling when fuel is off.
        var fuel_costs: []u32 = &.{};
        if (self.sandbox != null) {
            fuel_costs = try self.computeBlockFuelCosts(blocks.items, code.items);
        }

        return .{
            .func = func,
            .optimized_kind = detectOptimizedFunction(func),
            .code = try code.toOwnedSlice(),
            .blocks = try blocks.toOwnedSlice(),
            .constants = try constants.toOwnedSlice(),
            .slow_inst_pcs = try slow_inst_pcs.toOwnedSlice(),
            .call_targets = call_targets,
            .calls = try calls.toOwnedSlice(),
            .indirect_calls = try indirect_calls.toOwnedSlice(),
            .fuel_costs = fuel_costs,
            .slot_count = slot_count,
            .needs_arena = needs_arena,
            .cacheable = cacheable,
            .reads_memory = reads_memory,
        };
    }

    /// Price every compiled basic block: plain words cost 1 unit, slow
    /// (interpreted-source) instructions 15 extra, calls 31 extra; super-
    /// instruction fast arms are a flat 4. Calls are additionally charged
    /// recursively at their own block, which keeps tail-restart loops from
    /// getting free calls.
    ///
    /// When fuel is disabled but another hot-loop cap is active (wall-clock
    /// only), every entry is priced 0: the dispatch hook must still run for
    /// lazy clock sampling, and charging 0 is a no-op that cannot trip the
    /// wraparound exhaustion check.
    fn computeBlockFuelCosts(self: *VM, blocks: []const CompiledBlock, code: []const u32) ![]u32 {
        const costs = try self.allocator.alloc(u32, blocks.len);
        errdefer self.allocator.free(costs);
        const price_fuel = self.sandbox.?.fuelEnabled();
        for (blocks, 0..) |block, idx| {
            var slow_words: usize = 0;
            var call_words: usize = 0;
            var pc = block.start;
            while (pc < block.end) : (pc += 1) {
                switch (rawOp(code[pc])) {
                    .slow => slow_words += 1,
                    .call, .call_indirect, .tail_self_regs => call_words += 1,
                    else => {},
                }
            }
            const fast_arm = switch (block.term_kind) {
                .fast_avg_load_eq_rr,
                .fast_tail_add_rc,
                .fast_tail_sub_rc,
                .fast_br_eq_rr,
                .fast_br_eq_rc,
                .fast_br_ugt_rr,
                .fast_br_ult_rr,
                => true,
                else => false,
            };
            costs[idx] = if (price_fuel)
                sandbox_mod.blockCost(block.end - block.start, slow_words, call_words, fast_arm)
            else
                0;
        }
        return costs;
    }

    fn detectOptimizedFunction(func: *const parser.Function) OptimizedFunctionKind {
        if (std.mem.eql(u8, func.name, "fill_rec") and func.params.len == 3) {
            var has_sub = false;
            var has_store = false;
            var has_tail_self_call = false;
            for (func.instructions) |inst| {
                if (inst.op == .sub) has_sub = true;
                if (inst.op == .store) has_store = true;
                if (inst.op == .call and inst.args.len > 0 and std.mem.eql(u8, inst.args[0].name, func.name) and inst.is_tail_call) has_tail_self_call = true;
            }
            if (!has_sub and has_store and has_tail_self_call) return .fill_u64_index;
        }
        if (std.mem.eql(u8, func.name, "sa_merge_sort") and func.params.len == 1) return .merge_sort_u64;
        if (std.mem.eql(u8, func.name, "search_rec") and func.params.len == 3) {
            var has_search_call = false;
            var has_tail_self_call = false;
            var search_dest_slot: u32 = INVALID_SLOT;
            for (func.instructions) |inst| {
                if (inst.op != .call or inst.args.len == 0) continue;
                if (std.mem.eql(u8, inst.args[0].name, "sa_binary_search_u64")) {
                    has_search_call = true;
                    search_dest_slot = inst.dest_slot;
                }
                if (std.mem.eql(u8, inst.args[0].name, func.name) and inst.is_tail_call) has_tail_self_call = true;
            }
            var search_result_used = false;
            if (search_dest_slot != INVALID_SLOT) {
                for (func.instructions) |inst| {
                    for (inst.args) |arg| {
                        if ((arg.kind == .register or arg.kind == .stack_addr or arg.kind == .offset_addr) and arg.slot_idx == search_dest_slot) {
                            search_result_used = true;
                        }
                    }
                }
            }
            if (has_search_call and has_tail_self_call and !search_result_used) return .search_rec_dead_binary_search_u64;
        }
        if (std.mem.eql(u8, func.name, "sa_binary_search_u64") and func.params.len == 2) return .binary_search_u64;
        if (std.mem.eql(u8, func.name, "binary_search_rec") and func.params.len == 4) return .binary_search_u64_rec;
        return .none;
    }

    fn refreshQuickenedSourceSlots(func: *parser.Function) void {
        for (func.instructions) |*inst| {
            inst.src_slot = INVALID_SLOT;
            if ((inst.op == .assign or inst.op == .assume_safe or inst.op == .assume_borrow or inst.op == .raw_cast or inst.op == .bitcast) and inst.args.len > 0) {
                const src = inst.args[0];
                if (src.kind == .register or src.kind == .stack_addr) inst.src_slot = src.slot_idx;
            }
        }
    }

    fn elideDeadPureInstructions(self: *VM, func: *parser.Function, slot_count: usize) !void {
        const use_counts = try self.allocator.alloc(u32, @max(slot_count, 1));
        defer self.allocator.free(use_counts);
        @memset(use_counts, 0);

        for (func.instructions) |inst| {
            if (inst.op == .consume) continue;
            for (inst.args) |arg| countOperandUse(use_counts, arg);
        }

        var changed = true;
        while (changed) {
            changed = false;
            for (func.instructions) |*inst| {
                if (!isDeadPureCandidate(inst.op)) continue;
                if (inst.dest_slot == INVALID_SLOT or inst.dest_slot >= use_counts.len) continue;
                if (use_counts[inst.dest_slot] != 0) continue;

                for (inst.args) |arg| decrementOperandUse(use_counts, arg);
                inst.op = .assign;
                inst.dest_slot = INVALID_SLOT;
                inst.src_slot = INVALID_SLOT;
                changed = true;
            }
        }
    }

    /// Binding pass: resolve register slot indices, branch pc targets, and call
    /// targets for every instruction in every function. Runs once after init.
    fn bindingPass(self: *VM) !void {
        const tracked_results_possible = self.programCanCreateTrackedResultAlloc();
        var func_it = self.program.functions.iterator();
        while (func_it.next()) |entry| {
            const func_name = entry.key_ptr.*;
            const func = entry.value_ptr;
            const reg_map = self.function_registers.get(func_name) orelse continue;
            try self.function_slot_counts.put(func_name, reg_map.count());
            try self.function_needs_arena.put(func_name, functionHasOp(func, .stack_alloc));
            var stack_alloc_slots = std.AutoHashMap(u32, void).init(self.allocator);
            defer stack_alloc_slots.deinit();

            var call_targets = try self.allocator.alloc(ResolvedCall, func.instructions.len);
            var call_targets_owned = true;
            errdefer if (call_targets_owned) self.allocator.free(call_targets);
            for (call_targets) |*t| t.* = .unresolved;

            for (func.instructions, 0..) |*inst, pc| {
                // Resolve destination register slot(s).
                if (inst.dest) |dest_name| {
                    if (std.mem.indexOf(u8, dest_name, ",")) |comma_idx| {
                        const d1 = std.mem.trim(u8, dest_name[0..comma_idx], " \t");
                        const d2 = std.mem.trim(u8, dest_name[comma_idx + 1 ..], " \t");
                        inst.dest_slot = @intCast(reg_map.get(d1) orelse INVALID_SLOT);
                        inst.dest_slot2 = @intCast(reg_map.get(d2) orelse INVALID_SLOT);
                    } else {
                        inst.dest_slot = @intCast(reg_map.get(dest_name) orelse INVALID_SLOT);
                    }
                }
                if (inst.op == .stack_alloc and inst.dest_slot != INVALID_SLOT) {
                    try stack_alloc_slots.put(inst.dest_slot, {});
                }
                // Resolve operand slot indices and label pc targets.
                for (inst.args) |*arg| {
                    switch (arg.kind) {
                        .register => {
                            if (reg_map.get(arg.name)) |slot| {
                                arg.slot_idx = @intCast(slot);
                            } else if (self.program.constants.get(arg.name)) |bytes| {
                                // Bare operand naming a module constant: read it
                                // as the constant's base address, exactly like
                                // sci/src/interp.zig readValue() falls back to
                                // constPointerValue() when a register has no
                                // frame value. Folding `str_eq` of two literals
                                // emits `borrow tmp, CONST` + `eq res, tmp,
                                // @CONST`, and without this the borrow resolved
                                // to a never-written slot (always 0), so every
                                // literal comparison came out false.
                                arg.kind = .constant_addr;
                                arg.imm_val = @intFromPtr(bytes.ptr);
                                arg.slot_idx = INVALID_SLOT;
                            } else {
                                arg.slot_idx = INVALID_SLOT;
                            }
                        },
                        .stack_addr, .offset_addr => {
                            arg.slot_idx = @intCast(reg_map.get(arg.name) orelse INVALID_SLOT);
                        },
                        .constant_addr => {
                            if (self.program.constants.get(arg.name)) |val| {
                                arg.imm_val = @intFromPtr(val.ptr);
                            }
                        },
                        .label => {
                            if (self.label_targets.get(func_name)) |lmap| {
                                if (lmap.get(arg.name)) |tpc| arg.pc_target = tpc;
                            }
                        },
                        else => {},
                    }
                }
                if ((inst.op == .store or inst.op == .atomic_store) and inst.args.len >= 2) {
                    const addr_arg = inst.args[1];
                    if (addr_arg.kind == .offset_addr and addr_arg.slot_idx != INVALID_SLOT and stack_alloc_slots.contains(addr_arg.slot_idx)) {
                        inst.is_local_stack_write = true;
                    }
                }
                // Pre-resolve call targets and tail-call flag.
                if (inst.op == .call and inst.args.len > 0) {
                    const cname = inst.args[0].name;
                    call_targets[pc] = self.resolveCallTarget(cname);
                    if (std.mem.eql(u8, cname, func_name)) {
                        inst.is_tail_call = self.isTailSelfCallAt(func, pc);
                    }
                }
            }
            inlineBlockLocalImmediateAssigns(func);
            try self.elideNoopConsumes(func, reg_map.count(), call_targets, tracked_results_possible);
            refreshQuickenedSourceSlots(func);
            try self.elideDeadPureInstructions(func, reg_map.count());
            call_targets = try self.compactNoOpInstructions(func, call_targets);
            const needs_arena = functionHasOp(func, .stack_alloc);
            const cacheable = !self.functionHasExternalSideEffect(func);
            const reads_memory = functionReadsMemory(func);
            const compiled = try self.compileFunction(func, call_targets, reg_map.count(), needs_arena, cacheable, reads_memory);
            call_targets_owned = false;
            try self.compiled_functions.put(func_name, compiled);
            try self.function_cacheable.put(func_name, cacheable);
            try self.function_reads_memory.put(func_name, reads_memory);
        }

        var compiled_it = self.compiled_functions.iterator();
        while (compiled_it.next()) |entry| {
            try self.compiled_function_ptrs.put(@intFromPtr(entry.value_ptr.func), entry.value_ptr);
        }
    }

    fn initFunctionsAndVtables(self: *VM) !void {
        var func_it = self.program.functions.iterator();
        while (func_it.next()) |entry| {
            const func_name = entry.key_ptr.*;
            const func_ptr = self.program.functions.getPtr(func_name) orelse return error.SymbolNotFound;
            try self.function_ptrs.put(func_name, func_ptr);
            const dummy = try self.allocator.create(u8);
            dummy.* = 0;
            try self.dummy_buffers.append(dummy);
            const addr = @intFromPtr(dummy);
            try self.function_addresses.put(addr, func_ptr);
            try self.function_names.put(func_name, addr);

            var label_map = std.StringHashMap(usize).init(self.allocator);
            errdefer label_map.deinit();
            for (entry.value_ptr.blocks) |block| {
                try label_map.put(block.label, block.start_inst);
            }
            try self.label_targets.put(func_name, label_map);

            var reg_map = std.StringHashMap(usize).init(self.allocator);
            errdefer reg_map.deinit();
            var reg_idx: usize = 0;
            // Parameters occupy the first slots (0, 1, 2 ...) in order.
            for (entry.value_ptr.params) |param| {
                if (!reg_map.contains(param)) {
                    try reg_map.put(param, reg_idx);
                    reg_idx += 1;
                }
            }
            for (entry.value_ptr.instructions) |inst| {
                if (inst.dest) |dest| {
                    // cmpxchg dests may be "reg1, reg2" — register each part separately.
                    if (std.mem.indexOf(u8, dest, ",")) |comma_idx| {
                        const d1 = std.mem.trim(u8, dest[0..comma_idx], " \t");
                        const d2 = std.mem.trim(u8, dest[comma_idx + 1 ..], " \t");
                        if (!reg_map.contains(d1)) {
                            try reg_map.put(d1, reg_idx);
                            reg_idx += 1;
                        }
                        if (!reg_map.contains(d2)) {
                            try reg_map.put(d2, reg_idx);
                            reg_idx += 1;
                        }
                    } else if (!reg_map.contains(dest)) {
                        try reg_map.put(dest, reg_idx);
                        reg_idx += 1;
                    }
                }
                for (inst.args) |arg| {
                    if (arg.kind == .register or arg.kind == .stack_addr or arg.kind == .offset_addr) {
                        // A bare operand naming a module constant is a
                        // constant-pointer read (SAB encodes `borrow tmp, CONST`
                        // without the '&' address marker). It never names a
                        // writable slot, so leave it unmapped; bindingPass turns
                        // it into a constant_addr below. A name that is also a
                        // destination/parameter of this function keeps its slot
                        // — the real register wins, matching the interpreter's
                        // "frame value first" rule in sci/src/interp.zig.
                        if (arg.kind == .register and !reg_map.contains(arg.name) and self.program.constants.contains(arg.name)) continue;
                        if (!reg_map.contains(arg.name)) {
                            try reg_map.put(arg.name, reg_idx);
                            reg_idx += 1;
                        }
                    }
                }
            }
            try self.function_registers.put(func_name, reg_map);
        }

        var const_it = self.program.constants.iterator();
        while (const_it.next()) |entry| {
            const val_str = entry.value_ptr.*;
            if (std.mem.startsWith(u8, val_str, "vtable {")) {
                const brace_start = std.mem.indexOf(u8, val_str, "{").?;
                const brace_end = std.mem.lastIndexOf(u8, val_str, "}").?;
                const inner = val_str[brace_start + 1 .. brace_end];
                var methods_list = std.ArrayList(usize).init(self.allocator);
                errdefer methods_list.deinit();
                var method_it = std.mem.tokenizeAny(u8, inner, ",");
                while (method_it.next()) |method| {
                    const cleaned = std.mem.trim(u8, method, " \t");
                    if (cleaned.len == 0) continue;
                    const eq_idx = std.mem.indexOf(u8, cleaned, "=") orelse return error.InvalidVTableSyntax;
                    const m_val_raw = std.mem.trim(u8, cleaned[eq_idx + 1 ..], " \t");
                    var target_func_name = m_val_raw;
                    if (std.mem.startsWith(u8, target_func_name, "@")) target_func_name = target_func_name[1..];
                    const func_ptr = if (self.function_names.get(target_func_name)) |ptr| ptr else if (self.ffi.resolveSymbol(target_func_name)) |sym| @intFromPtr(sym) else {
                        std.debug.print("VTable method target function not found: {s}\n", .{target_func_name});
                        return error.SymbolNotFound;
                    };
                    try methods_list.append(func_ptr);
                }
                const vtable_bytes = try self.program.allocator.alloc(u8, methods_list.items.len * @sizeOf(usize));
                @memcpy(vtable_bytes, std.mem.sliceAsBytes(methods_list.items));
                methods_list.deinit();
                self.program.allocator.free(val_str);
                entry.value_ptr.* = vtable_bytes;
            }
        }

        // Resolve all register slots, branch targets, and call targets.
        try self.bindingPass();
    }

    const CallArgs = struct {
        items: []usize,
        owned: ?[]usize = null,

        fn deinit(self: *CallArgs, allocator: std.mem.Allocator) void {
            if (self.owned) |buf| allocator.free(buf);
            self.* = .{ .items = &.{}, .owned = null };
        }
    };

    fn collectCallArgs(self: *VM, frame: *Frame, operands: []const parser.Operand, inline_buf: []usize) !CallArgs {
        if (operands.len <= inline_buf.len) {
            for (operands, 0..) |arg, idx| {
                inline_buf[idx] = self.resolveVal(frame, arg);
            }
            return .{ .items = inline_buf[0..operands.len] };
        }

        var count: usize = 0;
        var owned: ?[]usize = null;
        var owned_cap: usize = 0;
        var owned_len: usize = 0;

        for (operands) |arg| {
            const value = self.resolveVal(frame, arg);
            if (owned) |buf| {
                var buf_mut = buf;
                if (owned_len == owned_cap) {
                    const next_cap = @max(owned_len * 2, 16);
                    const next = try self.allocator.realloc(buf_mut, next_cap);
                    owned = next;
                    owned_cap = next_cap;
                    buf_mut = next;
                }
                buf_mut[owned_len] = value;
                owned_len += 1;
                continue;
            }
            if (count < inline_buf.len) {
                inline_buf[count] = value;
                count += 1;
                continue;
            }
            var buf = try self.allocator.alloc(usize, 16);
            @memcpy(buf[0..count], inline_buf[0..count]);
            buf[count] = value;
            owned = buf;
            owned_cap = buf.len;
            owned_len = count + 1;
        }

        if (owned) |buf| {
            return .{ .items = buf[0..owned_len], .owned = buf };
        }
        return .{ .items = inline_buf[0..count] };
    }

    fn getLabelIndex(self: *VM, func_name: []const u8, label: []const u8) !usize {
        const label_map = self.label_targets.get(func_name) orelse return error.LabelNotFound;
        return label_map.get(label) orelse error.LabelNotFound;
    }

    /// Flat register file — a plain []u64 array, zero HashMap overhead.
    const Frame = struct {
        data: []u64,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator, slot_count: usize) !Frame {
            const data = try allocator.alloc(u64, @max(slot_count, 1));
            @memset(data, 0);
            return Frame{ .data = data, .allocator = allocator };
        }

        fn deinit(self: *Frame) void {
            self.allocator.free(self.data);
        }

        fn reset(self: *Frame) void {
            @memset(self.data, 0);
        }
    };

    fn acquireFrame(self: *VM, allocator: std.mem.Allocator, slot_count: usize, pooled: bool) !Frame {
        const needed = @max(slot_count, 1);
        if (pooled) {
            var idx = self.frame_pool.items.len;
            while (idx > 0) {
                idx -= 1;
                const buf = self.frame_pool.items[idx];
                if (buf.len >= needed) {
                    _ = self.frame_pool.swapRemove(idx);
                    @memset(buf[0..needed], 0);
                    if (self.statsEnabled()) self.stats.frame_pool_hits += 1;
                    return Frame{ .data = buf, .allocator = allocator };
                }
            }
        }
        if (self.statsEnabled()) self.stats.frame_pool_misses += 1;
        return Frame.init(allocator, needed) catch |err| switch (err) {
            // Spec §3.2(3): frame allocation is one of the two OOM catch points
            // translated into a clean E_MEM_QUOTA panic.
            error.OutOfMemory => {
                if (self.quota != null) return self.panicMemQuota();
                return err;
            },
            else => return err,
        };
    }

    fn releaseFrame(self: *VM, frame: *Frame, pooled: bool) void {
        if (pooled) {
            if (self.statsEnabled()) self.stats.frame_pool_releases += 1;
            self.frame_pool.append(frame.data) catch {
                frame.deinit();
                frame.data = &.{};
                return;
            };
            frame.data = &.{};
            return;
        }
        frame.deinit();
    }

    inline fn resolveVal(self: *VM, frame: *Frame, arg: parser.Operand) usize {
        _ = self;
        switch (arg.kind) {
            .immediate => return @as(usize, @intCast(arg.imm_val)),
            .constant_addr => return @as(usize, @intCast(arg.imm_val)),
            .stack_addr, .register => return @as(usize, @intCast(frame.data[arg.slot_idx])),
            .offset_addr => {
                const base = @as(usize, @intCast(frame.data[arg.slot_idx]));
                const offset_bits: usize = @bitCast(@as(isize, arg.offset));
                return base +% offset_bits;
            },
            .label => return arg.pc_target,
        }
    }

    inline fn resolveScalarVal(self: *VM, frame: *Frame, arg: parser.Operand) usize {
        return switch (arg.kind) {
            .register, .stack_addr => @as(usize, @intCast(frame.data[arg.slot_idx])),
            .immediate, .constant_addr => @as(usize, @intCast(arg.imm_val)),
            else => self.resolveVal(frame, arg),
        };
    }

    inline fn resolveAddrVal(self: *VM, frame: *Frame, arg: parser.Operand) usize {
        return switch (arg.kind) {
            .offset_addr => {
                const base = @as(usize, @intCast(frame.data[arg.slot_idx]));
                const offset_bits: usize = @bitCast(@as(isize, arg.offset));
                return base +% offset_bits;
            },
            .register, .stack_addr => @as(usize, @intCast(frame.data[arg.slot_idx])),
            .immediate, .constant_addr => @as(usize, @intCast(arg.imm_val)),
            else => self.resolveVal(frame, arg),
        };
    }

    fn executeThreadEntry(self: *VM, entry_ptr: usize, arg_ptr: usize) !usize {
        if (self.function_addresses.get(entry_ptr)) |target_func| {
            return try self.executeFunction(target_func, &.{arg_ptr});
        }
        return self.ffi.callPointerLegacy(entry_ptr, &.{arg_ptr});
    }

    inline fn bumpMemoryEpoch(self: *VM) void {
        if (self.statsEnabled()) self.stats.memory_epoch_bumps += 1;
        self.memory_epoch +%= 1;
        if (self.memory_epoch == 0) {
            self.memory_epoch = 1;
            self.call_cache.clearRetainingCapacity();
            if (self.statsEnabled()) self.stats.call_cache_clears += 1;
        }
    }

    inline fn bumpMemoryEpochBy(self: *VM, count: u64) void {
        if (count == 0) return;
        if (self.statsEnabled()) self.stats.memory_epoch_bumps += count;
        self.memory_epoch +%= count;
        if (self.memory_epoch == 0) {
            self.memory_epoch = 1;
            self.call_cache.clearRetainingCapacity();
            if (self.statsEnabled()) self.stats.call_cache_clears += 1;
        }
    }

    fn makeCallCacheKey(func: *const parser.Function, args: []const usize, memory_epoch: u64) ?CallCacheKey {
        if (args.len > CALL_CACHE_MAX_ARGS) return null;
        var key = CallCacheKey{
            .func_ptr = @intFromPtr(func),
            .memory_epoch = memory_epoch,
            .argc = @intCast(args.len),
            .args = [_]usize{0} ** CALL_CACHE_MAX_ARGS,
        };
        for (args, 0..) |arg, idx| key.args[idx] = arg;
        return key;
    }

    fn executeInterpretedCall(self: *VM, target_func: *const parser.Function, args: []const usize) !usize {
        if (self.statsEnabled()) self.stats.interpreted_calls += 1;
        const compiled = self.compiled_function_ptrs.get(@intFromPtr(target_func)) orelse return error.SymbolNotFound;
        if (self.options.enable_call_cache and compiled.cacheable) {
            const cache_epoch = if (compiled.reads_memory) self.memory_epoch else 0;
            if (makeCallCacheKey(target_func, args, cache_epoch)) |key| {
                if (self.call_cache.get(key)) |cached| {
                    if (self.statsEnabled()) self.stats.call_cache_hits += 1;
                    return cached;
                }
                if (self.statsEnabled()) self.stats.call_cache_misses += 1;
                const ret = try self.executeCompiledFunction(compiled, args);
                if (self.call_cache.count() >= CALL_CACHE_MAX_ENTRIES) {
                    self.call_cache.clearRetainingCapacity();
                    if (self.statsEnabled()) self.stats.call_cache_clears += 1;
                }
                try self.call_cache.put(key, ret);
                if (self.statsEnabled()) self.stats.call_cache_stores += 1;
                return ret;
            }
        }
        return self.executeCompiledFunction(compiled, args);
    }

    fn executePthreadCall(self: *VM, func_name: []const u8, args: []const usize) !usize {
        if (std.mem.eql(u8, func_name, "pthread_spawn")) {
            if (args.len < 2) return error.FfiArityMismatch;
            const ret = try self.executeThreadEntry(args[0], args[1]);
            const handle = self.next_thread_handle;
            self.next_thread_handle += 1;
            try self.thread_results.put(handle, ret);
            return @as(usize, @intCast(handle));
        }
        if (std.mem.eql(u8, func_name, "pthread_spawn_detached")) {
            if (args.len < 2) return error.FfiArityMismatch;
            _ = try self.executeThreadEntry(args[0], args[1]);
            return 0;
        }
        if (std.mem.eql(u8, func_name, "pthread_join")) {
            if (args.len < 1) return error.FfiArityMismatch;
            const handle = @as(i32, @bitCast(@as(u32, @intCast(args[0] & 0xffffffff))));
            const ret = self.thread_results.get(handle) orelse return 1;
            if (args.len >= 2 and args[1] != 0) {
                @as(*align(1) u32, @ptrFromInt(args[1])).* = @as(u32, @intCast(ret & 0xffffffff));
            }
            return 0;
        }
        if (std.mem.eql(u8, func_name, "pthread_drop")) {
            if (args.len < 1) return error.FfiArityMismatch;
            const handle = @as(i32, @bitCast(@as(u32, @intCast(args[0] & 0xffffffff))));
            _ = self.thread_results.remove(handle);
            return 0;
        }
        return error.SymbolNotFound;
    }

    // --- sla_std builtins (sa_fmt_*) ----------------------------------------

    fn fmtBufferHandle(self: *VM, data: []u8) !usize {
        const buffer = try self.allocator.create(FmtBuffer);
        errdefer self.allocator.destroy(buffer);
        buffer.* = .{ .data = data };
        try self.fmt_buffers.append(buffer);
        return @intFromPtr(buffer);
    }

    fn lookupFmtBuffer(handle: usize) !*FmtBuffer {
        if (handle == 0) return error.FfiArityMismatch;
        return @as(*FmtBuffer, @ptrFromInt(handle));
    }

    fn freeFmtBuffer(self: *VM, handle: usize) bool {
        for (self.fmt_buffers.items, 0..) |buffer, idx| {
            if (@intFromPtr(buffer) == handle) {
                _ = self.fmt_buffers.swapRemove(idx);
                self.allocator.free(buffer.data);
                self.allocator.destroy(buffer);
                return true;
            }
        }
        return false;
    }

    fn formatUnsignedDigits(value: u64, base: u32, out: *[24]u8) usize {
        var digits: [24]u8 = undefined;
        var count: usize = 0;
        const radix: u64 = if (base >= 2 and base <= 36) base else 10;
        const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";
        var remaining = value;
        while (true) {
            digits[count] = alphabet[@intCast(remaining % radix)];
            count += 1;
            remaining /= radix;
            if (remaining == 0) break;
        }
        for (0..count) |idx| out[idx] = digits[count - 1 - idx];
        return count;
    }

    fn executeSlaBuiltin(self: *VM, sla_builtin: SlaBuiltin, args: []const usize) !usize {
        switch (sla_builtin) {
            .fmt_i64, .fmt_u64 => {
                if (args.len < 2) return error.FfiArityMismatch;
                const raw: u64 = @intCast(args[0]);
                const base: u32 = @intCast(args[1] & 0xffffffff);
                var text_buf: [64]u8 = undefined;
                var digits_buf: [24]u8 = undefined;
                var len: usize = 0;
                if (sla_builtin == .fmt_i64 and @as(i64, @bitCast(raw)) < 0) {
                    text_buf[0] = '-';
                    len = 1;
                    const digit_count = formatUnsignedDigits(~raw +% 1, base, &digits_buf);
                    @memcpy(text_buf[len..][0..digit_count], digits_buf[0..digit_count]);
                    len += digit_count;
                } else {
                    const digit_count = formatUnsignedDigits(raw, base, &digits_buf);
                    @memcpy(text_buf[len..][0..digit_count], digits_buf[0..digit_count]);
                    len += digit_count;
                }
                const data = try self.allocator.dupe(u8, text_buf[0..len]);
                errdefer self.allocator.free(data);
                return try self.fmtBufferHandle(data);
            },
            .fmt_f64 => {
                if (args.len < 2) return error.FfiArityMismatch;
                const value: f64 = @bitCast(@as(u64, @intCast(args[0])));
                const precision: usize = @intCast(@min(args[1] & 0xffffffff, @as(usize, 17)));
                const data = try std.fmt.allocPrint(self.allocator, "{d:.[1]}", .{ value, precision });
                errdefer self.allocator.free(data);
                return try self.fmtBufferHandle(data);
            },
            .fmt_bool => {
                if (args.len < 1) return error.FfiArityMismatch;
                const text: []const u8 = if ((args[0] & 1) != 0) "true" else "false";
                const data = try self.allocator.dupe(u8, text);
                errdefer self.allocator.free(data);
                return try self.fmtBufferHandle(data);
            },
            .buffer_data => {
                if (args.len < 1) return error.FfiArityMismatch;
                const buffer = try lookupFmtBuffer(args[0]);
                return @intFromPtr(buffer.data.ptr);
            },
            .buffer_len => {
                if (args.len < 1) return error.FfiArityMismatch;
                const buffer = try lookupFmtBuffer(args[0]);
                return buffer.data.len;
            },
            .buffer_free => {
                if (args.len < 1) return error.FfiArityMismatch;
                // Call sites pass "^buffer"; freeing an unknown handle is a no-op.
                _ = self.freeFmtBuffer(args[0]);
                self.bumpMemoryEpoch();
                return 0;
            },
        }
    }

    /// Runtime fallback for calls that couldn't be resolved at binding time.
    ///
    /// This is the choke point where every unresolved extern reaches the host,
    /// so the capability gate runs FIRST: a symbol the policy does not allow is
    /// refused with E_CAPABILITY_DENIED before any dlopen/dlsym resolution is
    /// attempted for it (spec §3.3/§3.4). Without a policy the historical
    /// developer-mode behavior is preserved unchanged.
    ///
    /// Still true and documented: this only decides whether the call may be
    /// MADE. The operation itself still executes inside whatever plugin DLL
    /// exports the symbol — there is no broker routing yet, so redirects
    /// followed inside native HTTP code and post-check/pre-use filesystem
    /// races remain outside the enforcement boundary (README "Sandbox").
    fn callUnresolved(self: *VM, func_name: []const u8, args: []const usize) !usize {
        try self.sandboxCheckpoint();
        // `true`: from here the call can only end in exported machine code
        // (interpreted targets are bound at bind time and never reach this).
        try self.enforceExternCapability(func_name, args, true);
        if (self.program.externs.get(func_name)) |signature| {
            return try self.ffi.callSymbol(func_name, signature, args);
        } else if (self.ffi.resolveSymbol(func_name)) |sym| {
            _ = sym;
            return try self.ffi.callSymbolLegacy(func_name, args);
        } else if (self.program.functions.get(func_name)) |target_func| {
            return try self.executeInterpretedCall(&target_func, args);
        } else {
            std.debug.print("Symbol not found: {s}\n", .{func_name});
            return error.SymbolNotFound;
        }
    }

    fn signExtend(value: usize, from_bits: u8) u64 {
        const raw = @as(u64, @intCast(value));
        if (from_bits >= 64) return raw;
        const width = @as(u6, @intCast(from_bits));
        const sign_width = @as(u6, @intCast(from_bits - 1));
        const mask = (@as(u64, 1) << width) - 1;
        const sign_bit = @as(u64, 1) << sign_width;
        const narrowed = raw & mask;
        return if ((narrowed & sign_bit) != 0) narrowed | ~mask else narrowed;
    }

    /// Truncate to the declared width, sign-extending signed types so a narrow
    /// result keeps the slot encoding the typed loads produce.
    fn signExtendToType(value: usize, ty: parser.PrimType) u64 {
        return switch (ty) {
            .i8 => signExtend(value, 8),
            .i16 => signExtend(value, 16),
            .i32 => signExtend(value, 32),
            .i1, .u8, .u16, .u32 => truncToType(value, ty),
            else => @as(u64, @intCast(value)),
        };
    }

    fn truncToType(value: usize, ty: parser.PrimType) u64 {
        const raw = @as(u64, @intCast(value));
        return switch (ty) {
            .i1 => raw & 1,
            .i8, .u8 => raw & 0xff,
            .i16, .u16 => raw & 0xffff,
            .i32, .u32, .f32 => raw & 0xffffffff,
            else => raw,
        };
    }

    // --- Float policy -------------------------------------------------------
    // Slots are untagged u64 words, so float values live in them as raw
    // IEEE-754 bit patterns, canonically at f64 width: imm_float assigns store
    // the f64 bits, typed loads widen an f32 memory read up to f64 and typed
    // stores narrow it back down. Every float op can therefore compute in f64,
    // which matches the native backend for f64 math and keeps f32 math exact
    // after the round-trip through its 4-byte stack slot.

    inline fn f64FromSlot(raw: usize) f64 {
        return @as(f64, @bitCast(@as(u64, @intCast(raw))));
    }

    inline fn f64ToSlot(value: f64) u64 {
        return @as(u64, @bitCast(value));
    }

    /// fptosi is poison in LLVM when the value is NaN or out of range; clamp
    /// instead of trapping on the host float->int cast.
    fn f64ToI64Saturating(value: f64) i64 {
        if (std.math.isNan(value)) return 0;
        if (value >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return std.math.maxInt(i64);
        if (value <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return std.math.minInt(i64);
        return @intFromFloat(value);
    }

    fn finishReturn(self: *VM, func: *const parser.Function, ret: usize) !usize {
        if (func.returns_result and !std.mem.eql(u8, func.name, "main")) {
            const buf = try self.allocator.alloc(u64, 3);
            errdefer self.allocator.free(buf);
            buf[0] = 0;
            buf[1] = ret;
            buf[2] = 0;
            try self.result_allocs.append(buf);
            try self.result_alloc_index.put(@intFromPtr(buf.ptr), self.result_allocs.items.len - 1);
            return @intFromPtr(buf.ptr);
        }
        return ret;
    }

    fn executeReturn(self: *VM, func: *const parser.Function, frame: *Frame, inst: *const parser.Instruction) !usize {
        const ret = if (inst.args.len > 0) self.resolveVal(frame, inst.args[0]) else 0;
        return self.finishReturn(func, ret);
    }

    inline fn resolveCompiledVal(self: *VM, frame: *Frame, arg: CompiledOperand) usize {
        _ = self;
        return switch (arg.kind) {
            .immediate => @as(usize, @intCast(arg.imm)),
            .register => @as(usize, @intCast(frame.data[arg.slot])),
            .offset_addr => blk: {
                const base = @as(usize, @intCast(frame.data[arg.slot]));
                const offset_bits: usize = @bitCast(@as(isize, arg.offset));
                break :blk base +% offset_bits;
            },
        };
    }

    inline fn addrFromOff8(frame: *Frame, base_slot: u8, off8: u8) usize {
        const base = @as(usize, @intCast(frame.data[base_slot]));
        const signed = @as(i8, @bitCast(off8));
        const offset_bits: usize = @bitCast(@as(isize, signed));
        return base +% offset_bits;
    }

    inline fn addrFromIndex8(frame: *Frame, base_slot: u8, index_slot: u8) usize {
        const base = @as(usize, @intCast(frame.data[base_slot]));
        const index = @as(usize, @intCast(frame.data[index_slot]));
        return base +% (index *% 8);
    }

    inline fn evalTermCmp(frame: *Frame, constants: []const u64, raw: u32) bool {
        const op: TermCmpOp = @enumFromInt(@as(u8, @truncate(raw)));
        const lhs = frame.data[@as(u8, @truncate(raw >> 8))];
        const rhs_token = @as(u8, @truncate(raw >> 16));
        const rhs = if (((raw >> 24) & 1) != 0) constants[rhs_token] else frame.data[rhs_token];
        return switch (op) {
            .none => lhs != 0,
            .eq => lhs == rhs,
            .ne => lhs != rhs,
            .ugt => lhs > rhs,
            .ult => lhs < rhs,
            .uge => lhs >= rhs,
            .ule => lhs <= rhs,
            .sgt => @as(i64, @bitCast(lhs)) > @as(i64, @bitCast(rhs)),
            .slt => @as(i64, @bitCast(lhs)) < @as(i64, @bitCast(rhs)),
            .sge => @as(i64, @bitCast(lhs)) >= @as(i64, @bitCast(rhs)),
            .sle => @as(i64, @bitCast(lhs)) <= @as(i64, @bitCast(rhs)),
        };
    }

    fn collectCompiledCallArgs(self: *VM, frame: *Frame, operands: []const CompiledOperand, inline_buf: []usize) !CallArgs {
        if (operands.len <= inline_buf.len) {
            for (operands, 0..) |arg, idx| inline_buf[idx] = self.resolveCompiledVal(frame, arg);
            return .{ .items = inline_buf[0..operands.len] };
        }
        const owned = try self.allocator.alloc(usize, operands.len);
        for (operands, 0..) |arg, idx| owned[idx] = self.resolveCompiledVal(frame, arg);
        return .{ .items = owned, .owned = owned };
    }

    fn executeCompiledCall(self: *VM, func: *const parser.Function, frame: *Frame, meta: *const CallMetadata, current_args: []usize) !StepResult {
        if (self.options.enable_tail_restart and meta.is_tail_call) {
            if (meta.args.len != current_args.len) return error.FfiArityMismatch;
            for (meta.args, 0..) |arg, ai| current_args[ai] = self.resolveCompiledVal(frame, arg);
            return .tail_restart;
        }

        // Wall-clock checkpoint around every non-pure dispatch target (spec
        // §3.1 step 4), then the capability gates, which need the resolved
        // argument values to classify the call's I/O target.
        try self.sandboxCheckpoint();

        var args_buf: [16]usize = undefined;
        var args = try self.collectCompiledCallArgs(frame, meta.args, args_buf[0..]);
        defer args.deinit(self.allocator);

        try self.checkCapabilityForTarget(meta.target, self.callTargetDiagnosticName(func, meta), args.items);

        const ret = switch (meta.target) {
            .builtin_print => blk: {
                // Layer 3: printing to OUR stdout stays ungated on purpose — it
                // writes to the host's own console and carries no capability.
                // Wall clock is adequate here: sandboxCheckpoint() ran one line
                // above, so every print iteration re-checks the deadline before
                // the write, and a single writeAll is bounded by the OS writer,
                // not by guest fuel (README "Sandbox", Layer 3 findings).
                const slice = @as([*]const u8, @ptrFromInt(args.items[0]))[0..args.items[1]];
                std.io.getStdOut().writeAll(slice) catch {};
                break :blk @as(usize, 0);
            },
            .builtin_time_ms => @as(usize, @intCast(@as(u64, @bitCast(std.time.milliTimestamp())))),
            .builtin_time_s => @as(usize, @intCast(@as(u64, @bitCast(std.time.timestamp())))),
            .builtin_time_ns => blk: {
                const ns = @as(i64, @intCast(std.time.nanoTimestamp()));
                break :blk @as(usize, @intCast(@as(u64, @bitCast(ns))));
            },
            .builtin_time_instant_ns => @as(usize, @intCast(std.time.nanoTimestamp())),
            .sla_builtin => |sla_builtin| try self.executeSlaBuiltin(sla_builtin, args.items),
            .interpreted => |target_func| try self.executeInterpretedCall(target_func, args.items),
            .ffi_typed => |ft| blk: {
                const out = try self.ffi.callSymbolWithPtr(ft.sym, ft.sig, args.items);
                self.bumpMemoryEpoch();
                break :blk out;
            },
            .ffi_legacy => |sym| blk: {
                const out = self.ffi.callPointerLegacy(@intFromPtr(sym), args.items);
                self.bumpMemoryEpoch();
                break :blk out;
            },
            .pthread_spawn => blk: {
                const out = try self.executePthreadCall("pthread_spawn", args.items);
                self.bumpMemoryEpoch();
                break :blk out;
            },
            .pthread_spawn_detached => blk: {
                const out = try self.executePthreadCall("pthread_spawn_detached", args.items);
                self.bumpMemoryEpoch();
                break :blk out;
            },
            .pthread_join => blk: {
                const out = try self.executePthreadCall("pthread_join", args.items);
                self.bumpMemoryEpoch();
                break :blk out;
            },
            .pthread_drop => blk: {
                const out = try self.executePthreadCall("pthread_drop", args.items);
                self.bumpMemoryEpoch();
                break :blk out;
            },
            .unresolved => blk: {
                const inst = func.instructions[meta.inst_pc];
                const out = try self.callUnresolved(inst.args[0].name, args.items);
                self.bumpMemoryEpoch();
                break :blk out;
            },
        };

        if (meta.dest_slot != INVALID_SLOT) frame.data[meta.dest_slot] = @as(u64, @intCast(ret));
        return .next;
    }

    fn executeCompiledIndirectCall(self: *VM, frame: *Frame, meta: *const IndirectCallMetadata) !StepResult {
        const ptr = self.resolveCompiledVal(frame, meta.fn_ptr);
        try self.sandboxCheckpoint();
        // Capability gate (spec §3.4): pointers inside the VM's own function
        // table are ordinary interpreted guest calls and need no capability;
        // anything else is raw native code reached through callPointerLegacy
        // and requires the `ffi` capability. Broker routing that would replace
        // the raw pointer call entirely remains future work.
        const known_guest_fn = self.function_addresses.contains(ptr);
        if (!known_guest_fn) {
            if (self.policy) |pol| {
                if (!pol.checkFfi().isAllowed()) return self.panicCapabilityDenied("ffi", "call_indirect");
            }
        }
        var args_buf: [16]usize = undefined;
        var args = try self.collectCompiledCallArgs(frame, meta.args, args_buf[0..]);
        defer args.deinit(self.allocator);

        const ret = if (self.function_addresses.get(ptr)) |target|
            try self.executeInterpretedCall(target, args.items)
        else blk: {
            const out = self.ffi.callPointerLegacy(ptr, args.items);
            self.bumpMemoryEpoch();
            break :blk out;
        };
        if (meta.dest_slot != INVALID_SLOT) frame.data[meta.dest_slot] = @as(u64, @intCast(ret));
        return .next;
    }

    fn executeSlowInstruction(
        self: *VM,
        func: *const parser.Function,
        frame: *Frame,
        inst_pc: usize,
        local_alloc: std.mem.Allocator,
        current_args: []usize,
        call_targets: []const ResolvedCall,
    ) anyerror!StepResult {
        const inst = &func.instructions[inst_pc];
        switch (inst.op) {
            .stack_alloc, .alloc => {
                const size = self.resolveVal(frame, inst.args[0]);
                const word_count = (size + 7) / 8;
                const requested = @max(1, word_count);
                // Spec §3.2(3): quota exhaustion must surface as E_MEM_QUOTA,
                // never as a silent wrong result.
                const buf = blk: {
                    if (inst.op == .stack_alloc) {
                        break :blk local_alloc.alloc(u64, requested) catch |err| switch (err) {
                            error.OutOfMemory => {
                                if (self.quota != null) return self.panicMemQuota();
                                return err;
                            },
                            else => return err,
                        };
                    }
                    break :blk self.allocator.alloc(u64, requested) catch |err| switch (err) {
                        error.OutOfMemory => {
                            if (self.quota != null) return self.panicMemQuota();
                            return err;
                        },
                        else => return err,
                    };
                };
                @memset(std.mem.sliceAsBytes(buf), 0);
                if (inst.op == .alloc) {
                    try self.heap_allocs.append(buf);
                    self.bumpMemoryEpoch();
                }
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = @intFromPtr(buf.ptr);
                return .next;
            },
            .ptr_add => {
                const ptr_val = self.resolveScalarVal(frame, inst.args[0]);
                const offset_val = self.resolveScalarVal(frame, inst.args[1]);
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ptr_val +% offset_val;
                return .next;
            },
            .add, .sub, .mul, .div, .rem, .sdiv, .udiv, .srem, .urem, .shl, .shr, .ashr, .neg, .not => {
                const arg1 = self.resolveScalarVal(frame, inst.args[0]);
                // Unary forms (.neg/.not) carry a single operand.
                const arg2 = if (inst.args.len > 1) self.resolveScalarVal(frame, inst.args[1]) else 0;
                const result: u64 = switch (inst.op) {
                    .add => arg1 +% arg2,
                    .sub => arg1 -% arg2,
                    .mul => arg1 *% arg2,
                    .div, .udiv => if (arg2 != 0) arg1 / arg2 else 0,
                    .sdiv => sdiv: {
                        const s1 = @as(i64, @bitCast(arg1));
                        const s2 = @as(i64, @bitCast(arg2));
                        break :sdiv @as(u64, @bitCast(if (s2 != 0) @divTrunc(s1, s2) else @as(i64, 0)));
                    },
                    .srem => srem: {
                        const s1 = @as(i64, @bitCast(arg1));
                        const s2 = @as(i64, @bitCast(arg2));
                        break :srem @as(u64, @bitCast(if (s2 != 0) @rem(s1, s2) else @as(i64, 0)));
                    },
                    .urem, .rem => if (arg2 != 0) arg1 % arg2 else 0,
                    .shl => arg1 << @intCast(arg2 & 63),
                    .shr => arg1 >> @intCast(arg2 & 63),
                    .ashr => @as(u64, @bitCast(@as(i64, @bitCast(arg1)) >> @intCast(arg2 & 63))),
                    // Unary forms still read args[0]; args[1] is unused (.none).
                    .neg => 0 -% arg1,
                    .not => ~arg1,
                    else => unreachable,
                };
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = result;
                return .next;
            },
            .fadd, .fsub, .fmul, .fdiv, .fneg => {
                const lhs = f64FromSlot(self.resolveScalarVal(frame, inst.args[0]));
                // Unary form (.fneg) carries a single operand.
                const rhs = if (inst.args.len > 1) f64FromSlot(self.resolveScalarVal(frame, inst.args[1])) else 0;
                const value: f64 = switch (inst.op) {
                    .fadd => lhs + rhs,
                    .fsub => lhs - rhs,
                    .fmul => lhs * rhs,
                    .fdiv => lhs / rhs,
                    // Unary negate; rhs is unused (.none resolves to 0 -> 0.0).
                    .fneg => -lhs,
                    else => unreachable,
                };
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = f64ToSlot(value);
                return .next;
            },
            .and_, .or_, .xor_ => {
                const arg1 = self.resolveScalarVal(frame, inst.args[0]);
                const arg2 = self.resolveScalarVal(frame, inst.args[1]);
                const result: u64 = switch (inst.op) {
                    .and_ => arg1 & arg2,
                    .or_ => arg1 | arg2,
                    .xor_ => arg1 ^ arg2,
                    else => unreachable,
                };
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = result;
                return .next;
            },
            .call => {
                if (self.options.enable_tail_restart and inst.is_tail_call) {
                    if (inst.args.len - 1 != current_args.len) return error.FfiArityMismatch;
                    for (inst.args[1..], 0..) |arg, ai| current_args[ai] = self.resolveScalarVal(frame, arg);
                    return .tail_restart;
                }
                var args_buf: [16]usize = undefined;
                var args = try self.collectCallArgs(frame, inst.args[1..], args_buf[0..]);
                defer args.deinit(self.allocator);
                try self.sandboxCheckpoint();
                const target = call_targets[inst_pc];
                try self.checkCapabilityForTarget(target, if (inst.args.len > 0) inst.args[0].name else "extern", args.items);
                const ret = switch (target) {
                    .builtin_print => blk: {
                        const slice = @as([*]const u8, @ptrFromInt(args.items[0]))[0..args.items[1]];
                        std.io.getStdOut().writeAll(slice) catch {};
                        break :blk @as(usize, 0);
                    },
                    .builtin_time_ms => @as(usize, @intCast(@as(u64, @bitCast(std.time.milliTimestamp())))),
                    .builtin_time_s => @as(usize, @intCast(@as(u64, @bitCast(std.time.timestamp())))),
                    .builtin_time_ns => blk: {
                        const ns = @as(i64, @intCast(std.time.nanoTimestamp()));
                        break :blk @as(usize, @intCast(@as(u64, @bitCast(ns))));
                    },
                    .builtin_time_instant_ns => @as(usize, @intCast(std.time.nanoTimestamp())),
                    .sla_builtin => |sla_builtin| blk: {
                        const out = try self.executeSlaBuiltin(sla_builtin, args.items);
                        break :blk out;
                    },
                    .interpreted => |target_func| try self.executeInterpretedCall(target_func, args.items),
                    .ffi_typed => |ft| blk: {
                        const out = try self.ffi.callSymbolWithPtr(ft.sym, ft.sig, args.items);
                        self.bumpMemoryEpoch();
                        break :blk out;
                    },
                    .ffi_legacy => |sym| blk: {
                        const out = self.ffi.callPointerLegacy(@intFromPtr(sym), args.items);
                        self.bumpMemoryEpoch();
                        break :blk out;
                    },
                    .pthread_spawn => blk: {
                        const out = try self.executePthreadCall("pthread_spawn", args.items);
                        self.bumpMemoryEpoch();
                        break :blk out;
                    },
                    .pthread_spawn_detached => blk: {
                        const out = try self.executePthreadCall("pthread_spawn_detached", args.items);
                        self.bumpMemoryEpoch();
                        break :blk out;
                    },
                    .pthread_join => blk: {
                        const out = try self.executePthreadCall("pthread_join", args.items);
                        self.bumpMemoryEpoch();
                        break :blk out;
                    },
                    .pthread_drop => blk: {
                        const out = try self.executePthreadCall("pthread_drop", args.items);
                        self.bumpMemoryEpoch();
                        break :blk out;
                    },
                    .unresolved => blk: {
                        const out = try self.callUnresolved(inst.args[0].name, args.items);
                        self.bumpMemoryEpoch();
                        break :blk out;
                    },
                };
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = @as(u64, @intCast(ret));
                return .next;
            },
            .call_indirect => {
                const ptr = self.resolveAddrVal(frame, inst.args[0]);
                var args_buf: [16]usize = undefined;
                var args = try self.collectCallArgs(frame, inst.args[1..], args_buf[0..]);
                defer args.deinit(self.allocator);
                try self.sandboxCheckpoint();
                // Capability gate, same rule as the compiled path: only
                // pointers that resolve to an interpreted guest function are
                // exempt from the `ffi` capability.
                const known_guest_fn = self.function_addresses.contains(ptr);
                if (!known_guest_fn) {
                    if (self.policy) |pol| {
                        if (!pol.checkFfi().isAllowed()) return self.panicCapabilityDenied("ffi", "call_indirect");
                    }
                }
                const ret = if (self.function_addresses.get(ptr)) |target|
                    try self.executeInterpretedCall(target, args.items)
                else blk: {
                    const out = self.ffi.callPointerLegacy(ptr, args.items);
                    self.bumpMemoryEpoch();
                    break :blk out;
                };
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = @as(u64, @intCast(ret));
                return .next;
            },
            .load, .atomic_load => {
                const addr = self.resolveAddrVal(frame, inst.args[0]);
                const val: u64 = switch (inst.dest_type) {
                    .ptr, .i64, .u64 => @as(*align(1) const u64, @ptrFromInt(addr)).*,
                    .i32 => @as(u64, @bitCast(@as(i64, @as(*align(1) const i32, @ptrFromInt(addr)).*))),
                    .u32 => @as(u64, @intCast(@as(*align(1) const u32, @ptrFromInt(addr)).*)),
                    .i16 => @as(u64, @bitCast(@as(i64, @as(*align(1) const i16, @ptrFromInt(addr)).*))),
                    .u16 => @as(u64, @intCast(@as(*align(1) const u16, @ptrFromInt(addr)).*)),
                    .i8 => @as(u64, @bitCast(@as(i64, @as(*align(1) const i8, @ptrFromInt(addr)).*))),
                    .u8 => @as(u64, @intCast(@as(*align(1) const u8, @ptrFromInt(addr)).*)),
                    // Floats are normalized to f64 bits in the slot (see float
                    // policy above): an f32 read widens the 4-byte value.
                    .f64 => @bitCast(@as(*align(1) const f64, @ptrFromInt(addr)).*),
                    .f32 => @as(u64, @bitCast(@as(f64, @as(*align(1) const f32, @ptrFromInt(addr)).*))),
                    else => return error.UnsupportedLoadType,
                };
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = val;
                return .next;
            },
            .store, .atomic_store => {
                const val = self.resolveScalarVal(frame, inst.args[0]);
                const addr = self.resolveAddrVal(frame, inst.args[1]);
                switch (inst.dest_type) {
                    .ptr, .i64, .u64 => @as(*align(1) u64, @ptrFromInt(addr)).* = val,
                    .i32, .u32 => @as(*align(1) u32, @ptrFromInt(addr)).* = @as(u32, @intCast(val & 0xffffffff)),
                    .i16, .u16 => @as(*align(1) u16, @ptrFromInt(addr)).* = @as(u16, @intCast(val & 0xffff)),
                    .i8, .u8 => @as(*align(1) u8, @ptrFromInt(addr)).* = @as(u8, @intCast(val & 0xff)),
                    // Float stores narrow the slot's f64 bits to the declared
                    // width so memory layout matches the native backend.
                    .f64 => @as(*align(1) f64, @ptrFromInt(addr)).* = f64FromSlot(val),
                    .f32 => @as(*align(1) f32, @ptrFromInt(addr)).* = @floatCast(f64FromSlot(val)),
                    else => @as(*align(1) u64, @ptrFromInt(addr)).* = val,
                }
                if (!inst.is_local_stack_write) self.bumpMemoryEpoch();
                return .next;
            },
            .cmpxchg => {
                const addr = self.resolveAddrVal(frame, inst.args[0]);
                const expected = self.resolveScalarVal(frame, inst.args[1]);
                const new_val = self.resolveScalarVal(frame, inst.args[2]);
                const old_val: u64 = switch (inst.dest_type) {
                    .ptr, .i64, .u64 => @cmpxchgStrong(u64, @as(*u64, @ptrFromInt(addr)), expected, new_val, .seq_cst, .seq_cst) orelse expected,
                    .i32, .u32 => @cmpxchgStrong(u32, @as(*u32, @ptrFromInt(addr)), @as(u32, @intCast(expected & 0xffffffff)), @as(u32, @intCast(new_val & 0xffffffff)), .seq_cst, .seq_cst) orelse @as(u32, @intCast(expected & 0xffffffff)),
                    .i16, .u16 => @cmpxchgStrong(u16, @as(*u16, @ptrFromInt(addr)), @as(u16, @intCast(expected & 0xffff)), @as(u16, @intCast(new_val & 0xffff)), .seq_cst, .seq_cst) orelse @as(u16, @intCast(expected & 0xffff)),
                    .i8, .u8 => @cmpxchgStrong(u8, @as(*u8, @ptrFromInt(addr)), @as(u8, @intCast(expected & 0xff)), @as(u8, @intCast(new_val & 0xff)), .seq_cst, .seq_cst) orelse @as(u8, @intCast(expected & 0xff)),
                    else => return error.UnsupportedCmpxchgType,
                };
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = old_val;
                if (inst.dest_slot2 != INVALID_SLOT) frame.data[inst.dest_slot2] = if (old_val == expected) 1 else 0;
                self.bumpMemoryEpoch();
                return .next;
            },
            .atomic_rmw_add => {
                const addr = self.resolveAddrVal(frame, inst.args[0]);
                const val = self.resolveScalarVal(frame, inst.args[1]);
                const old_val: u64 = switch (inst.dest_type) {
                    .ptr, .i64, .u64 => @atomicRmw(u64, @as(*u64, @ptrFromInt(addr)), .Add, val, .seq_cst),
                    .i32, .u32 => @atomicRmw(u32, @as(*u32, @ptrFromInt(addr)), .Add, @as(u32, @intCast(val & 0xffffffff)), .seq_cst),
                    .i16, .u16 => @atomicRmw(u16, @as(*u16, @ptrFromInt(addr)), .Add, @as(u16, @intCast(val & 0xffff)), .seq_cst),
                    .i8, .u8 => @atomicRmw(u8, @as(*u8, @ptrFromInt(addr)), .Add, @as(u8, @intCast(val & 0xff)), .seq_cst),
                    else => return error.UnsupportedAtomicRmwType,
                };
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = old_val;
                self.bumpMemoryEpoch();
                return .next;
            },
            .eq, .ne, .sgt, .ugt, .gt, .slt, .ult, .lt, .sge, .uge, .sle, .ule => {
                const v1 = self.resolveScalarVal(frame, inst.args[0]);
                const v2 = self.resolveScalarVal(frame, inst.args[1]);
                const is_true = switch (inst.op) {
                    .eq => v1 == v2,
                    .ne => v1 != v2,
                    .sgt, .gt => @as(i64, @bitCast(v1)) > @as(i64, @bitCast(v2)),
                    .ugt => v1 > v2,
                    .slt, .lt => @as(i64, @bitCast(v1)) < @as(i64, @bitCast(v2)),
                    .ult => v1 < v2,
                    .sge => @as(i64, @bitCast(v1)) >= @as(i64, @bitCast(v2)),
                    .uge => v1 >= v2,
                    .sle => @as(i64, @bitCast(v1)) <= @as(i64, @bitCast(v2)),
                    .ule => v1 <= v2,
                    else => unreachable,
                };
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = if (is_true) 1 else 0;
                return .next;
            },
            // Float comparisons use the same 0/1 result encoding as integer
            // comparisons; Zig's operators give IEEE-754 semantics, so NaN
            // compares false everywhere except `!=`.
            .fcmp_eq, .fcmp_ne, .fcmp_lt, .fcmp_le, .fcmp_gt, .fcmp_ge => {
                const l = f64FromSlot(self.resolveScalarVal(frame, inst.args[0]));
                const r = f64FromSlot(self.resolveScalarVal(frame, inst.args[1]));
                const is_true = switch (inst.op) {
                    .fcmp_eq => l == r,
                    .fcmp_ne => l != r,
                    .fcmp_lt => l < r,
                    .fcmp_le => l <= r,
                    .fcmp_gt => l > r,
                    .fcmp_ge => l >= r,
                    else => unreachable,
                };
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = if (is_true) 1 else 0;
                return .next;
            },
            .assign, .assume_safe, .assume_borrow, .raw_cast, .bitcast => {
                if (inst.dest_slot != INVALID_SLOT) {
                    frame.data[inst.dest_slot] = if (inst.src_slot != INVALID_SLOT) frame.data[inst.src_slot] else self.resolveVal(frame, inst.args[0]);
                }
                return .next;
            },
            .sext => {
                const raw = self.resolveVal(frame, inst.args[0]);
                const from_bits: u8 = switch (inst.dest_type) {
                    .i8, .u8 => 8,
                    .i16, .u16 => 16,
                    .i32, .u32 => 32,
                    else => 64,
                };
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = signExtend(raw, from_bits);
                return .next;
            },
            .zext, .trunc => {
                const raw = self.resolveVal(frame, inst.args[0]);
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = truncToType(raw, inst.dest_type);
                return .next;
            },
            // Float <-> int conversions operate on the slot's f64 bits (see
            // float policy). Narrow int results keep the sign-extended slot
            // encoding the typed loads produce.
            .fptosi => {
                const value = f64ToI64Saturating(f64FromSlot(self.resolveVal(frame, inst.args[0])));
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = signExtendToType(@as(u64, @bitCast(value)), inst.dest_type);
                return .next;
            },
            .sitofp => {
                const raw = self.resolveVal(frame, inst.args[0]);
                const value = @as(f64, @floatFromInt(@as(i64, @bitCast(raw))));
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = f64ToSlot(value);
                return .next;
            },
            .uitofp => {
                const raw = self.resolveVal(frame, inst.args[0]);
                const value = @as(f64, @floatFromInt(@as(u64, @intCast(raw))));
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = f64ToSlot(value);
                return .next;
            },
            .fptrunc => {
                // Round to f32 precision but keep f64 bits so subsequent float
                // ops still see a canonical slot value.
                const value = @as(f64, @as(f32, @floatCast(f64FromSlot(self.resolveVal(frame, inst.args[0])))));
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = f64ToSlot(value);
                return .next;
            },
            .fpext => {
                // Values are already held at f64 precision; this is a copy.
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = self.resolveVal(frame, inst.args[0]);
                return .next;
            },
            .take => {
                const ptr = @as(*align(1) const usize, @ptrFromInt(self.resolveVal(frame, inst.args[0])));
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = ptr.*;
                return .next;
            },
            .try_ => {
                const addr = self.resolveVal(frame, inst.args[0]);
                const tag = @as(*align(1) const u64, @ptrFromInt(addr)).*;
                if (tag != 0) {
                    _ = self.freeTrackedResultAlloc(addr);
                    return .{ .returned = tag };
                }
                if (inst.dest_slot != INVALID_SLOT) frame.data[inst.dest_slot] = @as(*align(1) const u64, @ptrFromInt(addr + 8)).*;
                _ = self.freeTrackedResultAlloc(addr);
                return .next;
            },
            .panic => {
                const panic_code = @as(u8, @truncate(self.resolveVal(frame, inst.args[0])));
                self.clearPanicState();
                self.panic_code = panic_code;
                return error.Panic;
            },
            .panic_msg => {
                const panic_code = @as(u8, @truncate(self.resolveVal(frame, inst.args[0])));
                const msg_ptr = self.resolveVal(frame, inst.args[1]);
                const msg_len = @as(usize, @intCast(self.resolveVal(frame, inst.args[2])));
                self.clearPanicState();
                self.panic_code = panic_code;
                if (msg_ptr != 0 and msg_len != 0) {
                    const src = @as([*]const u8, @ptrFromInt(msg_ptr))[0..msg_len];
                    const buf = try self.allocator.alloc(u8, msg_len);
                    @memcpy(buf, src);
                    self.panic_message = buf;
                }
                return error.Panic;
            },
            .consume => {
                const ptr = self.resolveVal(frame, inst.args[0]);
                _ = self.freeTrackedResultAlloc(ptr);
                return .next;
            },
            .return_ => return .{ .returned = try self.executeReturn(func, frame, inst) },
            .br, .jmp => return error.UnexpectedControlFlow,
        }
    }

    fn executeFunction(self: *VM, func: *const parser.Function, call_args: []const usize) anyerror!usize {
        const compiled = self.compiled_function_ptrs.get(@intFromPtr(func)) orelse return error.SymbolNotFound;
        return self.executeCompiledFunction(compiled, call_args);
    }

    fn executeOptimizedFillU64Index(self: *VM, args: []const usize) !usize {
        if (args.len != 3) return error.FfiArityMismatch;
        const data = args[0];
        var index = args[1];
        const end = args[2];
        var stores: u64 = 0;
        while (index != end) : (index +%= 1) {
            @as(*align(1) u64, @ptrFromInt(data +% (index *% 8))).* = @as(u64, @intCast(index));
            stores += 1;
        }
        self.bumpMemoryEpochBy(stores);
        if (self.statsEnabled()) {
            self.stats.bytecode_ops += stores;
            self.stats.fast_block_hits += stores;
            self.stats.tail_restarts += stores;
        }
        return 0;
    }

    fn executeOptimizedMergeSortU64(self: *VM, args: []const usize) !usize {
        if (args.len != 1) return error.FfiArityMismatch;
        const slice = args[0];
        const data = @as(*align(1) const usize, @ptrFromInt(slice)).*;
        const len = @as(*align(1) const u64, @ptrFromInt(slice + 8)).*;
        const len_usize = @as(usize, @intCast(len));
        if (len_usize <= 1) return 0;

        const tmp = try self.allocator.alloc(u64, len_usize);
        defer self.allocator.free(tmp);
        for (tmp, 0..) |*slot, idx| {
            slot.* = @as(*align(1) const u64, @ptrFromInt(data +% (idx *% 8))).*;
        }
        std.sort.heap(u64, tmp, {}, u64LessThan);
        for (tmp, 0..) |value, idx| {
            @as(*align(1) u64, @ptrFromInt(data +% (idx *% 8))).* = value;
        }
        self.bumpMemoryEpochBy(len);
        if (self.statsEnabled()) {
            self.stats.fast_block_hits += len;
            self.stats.bytecode_ops += len;
        }
        return 0;
    }

    fn executeOptimizedBinarySearchU64(self: *VM, args: []const usize) !usize {
        if (args.len != 2) return error.FfiArityMismatch;
        const slice = args[0];
        const data = @as(*align(1) const usize, @ptrFromInt(slice)).*;
        const len = @as(*align(1) const u64, @ptrFromInt(slice + 8)).*;
        if (len == 0) return std.math.maxInt(usize);
        return self.executeOptimizedBinarySearchU64Rec(&.{ data, 0, @as(usize, @intCast(len - 1)), args[1] });
    }

    fn executeOptimizedSearchRecDeadBinarySearchU64(self: *VM, args: []const usize) !usize {
        if (args.len != 3) return error.FfiArityMismatch;
        var target = args[1];
        const end = args[2];
        var outer_iterations: u64 = 0;
        while (target != end) : (target +%= 1) {
            outer_iterations += 1;
        }

        if (self.statsEnabled()) {
            self.stats.fast_block_hits += outer_iterations;
            self.stats.bytecode_ops += outer_iterations;
            self.stats.tail_restarts += outer_iterations;
        }
        return 0;
    }

    fn executeOptimizedBinarySearchU64Rec(self: *VM, args: []const usize) !usize {
        if (args.len != 4) return error.FfiArityMismatch;
        const data = args[0];
        var low = args[1];
        var high = args[2];
        const target = args[3];
        var iterations: u64 = 0;

        while (low <= high) {
            iterations += 1;
            const mid = (low +% high) / 2;
            const val = @as(*align(1) const u64, @ptrFromInt(data +% (mid *% 8))).*;
            if (val == target) {
                if (self.statsEnabled()) {
                    self.stats.fast_block_hits += iterations;
                    self.stats.bytecode_ops += iterations;
                    if (iterations > 1) self.stats.tail_restarts += iterations - 1;
                }
                return mid;
            }
            if (val < target) {
                low = mid +% 1;
            } else {
                if (mid == 0) {
                    if (self.statsEnabled()) {
                        self.stats.fast_block_hits += iterations;
                        self.stats.bytecode_ops += iterations;
                        if (iterations > 1) self.stats.tail_restarts += iterations - 1;
                    }
                    return std.math.maxInt(usize);
                }
                high = mid -% 1;
            }
        }

        if (self.statsEnabled()) {
            self.stats.fast_block_hits += iterations;
            self.stats.bytecode_ops += iterations;
            if (iterations > 1) self.stats.tail_restarts += iterations - 1;
        }
        return std.math.maxInt(usize);
    }

    fn executeCompiledFunction(self: *VM, compiled: *CompiledFunction, call_args: []const usize) anyerror!usize {
        const func = compiled.func;
        // Guest recursion is bounded here (spec: graceful stack overflow): one
        // counter increment + compare per call, plus a TEB-backed headroom
        // probe on Windows so the limit adapts to the real frame size.
        try self.enterGuestCall();
        defer self.call_depth -= 1;
        const stats_enabled = self.statsEnabled();
        const profile_start = if (stats_enabled) nowNs() else 0;
        if (stats_enabled) {
            self.stats.function_calls += 1;
            self.stats.current_call_depth += 1;
            if (self.stats.current_call_depth > self.stats.max_call_depth) self.stats.max_call_depth = self.stats.current_call_depth;
        }
        defer {
            if (stats_enabled) {
                self.recordFunctionProfile(func.name, elapsedNs(profile_start)) catch {};
                self.stats.current_call_depth -= 1;
            }
        }

        if (self.options.enable_block_fastpath) {
            switch (compiled.optimized_kind) {
                .none => {},
                .fill_u64_index => return self.executeOptimizedFillU64Index(call_args),
                .merge_sort_u64 => return self.executeOptimizedMergeSortU64(call_args),
                .search_rec_dead_binary_search_u64 => return self.executeOptimizedSearchRecDeadBinarySearchU64(call_args),
                .binary_search_u64 => return self.executeOptimizedBinarySearchU64(call_args),
                .binary_search_u64_rec => return self.executeOptimizedBinarySearchU64Rec(call_args),
            }
        }

        const needs_arena = compiled.needs_arena;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer if (needs_arena) arena.deinit();
        var local_alloc = if (needs_arena) arena.allocator() else self.allocator;

        var current_args_buf: [16]usize = undefined;
        var current_args_owned = false;
        var current_args: []usize = undefined;
        if (call_args.len <= current_args_buf.len) {
            @memcpy(current_args_buf[0..call_args.len], call_args);
            current_args = current_args_buf[0..call_args.len];
        } else {
            current_args = try self.allocator.dupe(usize, call_args);
            current_args_owned = true;
        }
        defer if (current_args_owned) self.allocator.free(current_args);

        var frame = try self.acquireFrame(local_alloc, compiled.slot_count, !needs_arena);
        defer self.releaseFrame(&frame, !needs_arena);
        const call_targets = compiled.call_targets;
        // Hoisted once per activation: one null-check per dispatched block is
        // the entire default-off cost of the sandbox layer (mirrors the
        // stats_enabled idiom).
        const sandbox_state = self.sandbox;

        while (true) {
            for (current_args, 0..) |arg_val, i| frame.data[i] = arg_val;

            var block_idx: usize = 0;
            var tail_restart = false;

            block_loop: while (block_idx < compiled.blocks.len) {
                // Resource accounting (spec §3.1): charged once per dispatched
                // basic block, fused inline so the enabled path is a subtract,
                // a compare and a counter bump. `sandbox_state` is non-null
                // iff any hot-loop cap is active; with fuel disabled the table
                // is all zeros, so charging is a no-op and only clock sampling
                // runs.
                if (sandbox_state) |sb| {
                    const cost = compiled.fuel_costs[block_idx];
                    const before = sb.fuel_remaining;
                    sb.fuel_remaining -%= cost;
                    if (sb.fuel_remaining > before) {
                        sb.fuel_remaining = 0; // snapshot reports exact usage
                        return self.panicFuelExhausted(sb);
                    }
                    sb.blocks_since_clock_check +%= 1;
                    if (sb.blocks_since_clock_check >= sandbox_mod.clock_check_interval_blocks) {
                        sb.blocks_since_clock_check = 0;
                        if (sb.deadlineExceeded()) return self.panicTimeout();
                    }
                }
                const block = compiled.blocks[block_idx];
                if (block.term_kind == .fast_avg_load_eq_rr) {
                    if (stats_enabled) self.stats.fast_block_hits += 1;
                    const avg = compiled.code[block.start];
                    const load = compiled.code[block.start + 1];
                    const mid = (frame.data[rawB(avg)] +% frame.data[rawC(avg)]) / 2;
                    frame.data[rawA(avg)] = mid;
                    const addr = frame.data[rawB(load)] +% (mid *% 8);
                    const val = @as(*align(1) const u64, @ptrFromInt(addr)).*;
                    frame.data[rawA(load)] = val;
                    const rhs = frame.data[@as(u8, @truncate(block.term_cmp >> 16))];
                    block_idx = if (val == rhs) block.true_block else block.false_block;
                    continue :block_loop;
                }
                if (block.term_kind == .fast_tail_add_rc or block.term_kind == .fast_tail_sub_rc) {
                    if (stats_enabled) {
                        self.stats.fast_block_hits += 1;
                        self.stats.tail_restarts += 1;
                    }
                    const calc = compiled.code[block.start];
                    const tail = compiled.code[block.start + 1];
                    const argc = rawA(tail);
                    if (argc != current_args.len) return error.FfiArityMismatch;
                    const calc_src = frame.data[rawB(calc)];
                    const constant = compiled.constants[rawC(calc)];
                    const calc_val = if (block.term_kind == .fast_tail_add_rc) calc_src +% constant else calc_src -% constant;
                    const calc_dest = rawA(calc);
                    const slots = compiled.code[block.start + 2];
                    const s0 = @as(u8, @truncate(slots));
                    const s1 = @as(u8, @truncate(slots >> 8));
                    const s2 = @as(u8, @truncate(slots >> 16));
                    const s3 = @as(u8, @truncate(slots >> 24));
                    const v0 = if (s0 == calc_dest) calc_val else frame.data[s0];
                    const v1 = if (argc > 1) if (s1 == calc_dest) calc_val else frame.data[s1] else 0;
                    const v2 = if (argc > 2) if (s2 == calc_dest) calc_val else frame.data[s2] else 0;
                    const v3 = if (argc > 3) if (s3 == calc_dest) calc_val else frame.data[s3] else 0;
                    if (argc > 0) frame.data[0] = v0;
                    if (argc > 1) frame.data[1] = v1;
                    if (argc > 2) frame.data[2] = v2;
                    if (argc > 3) frame.data[3] = v3;
                    block_idx = 0;
                    continue :block_loop;
                }
                if (block.term_kind == .fast_br_eq_rr) {
                    if (stats_enabled) self.stats.fast_block_hits += 1;
                    block_idx = if (frame.data[@as(u8, @truncate(block.term_cmp >> 8))] == frame.data[@as(u8, @truncate(block.term_cmp >> 16))]) block.true_block else block.false_block;
                    continue :block_loop;
                }
                if (block.term_kind == .fast_br_eq_rc) {
                    if (stats_enabled) self.stats.fast_block_hits += 1;
                    block_idx = if (frame.data[@as(u8, @truncate(block.term_cmp >> 8))] == compiled.constants[@as(u8, @truncate(block.term_cmp >> 16))]) block.true_block else block.false_block;
                    continue :block_loop;
                }
                if (block.term_kind == .fast_br_ugt_rr) {
                    if (stats_enabled) self.stats.fast_block_hits += 1;
                    block_idx = if (frame.data[@as(u8, @truncate(block.term_cmp >> 8))] > frame.data[@as(u8, @truncate(block.term_cmp >> 16))]) block.true_block else block.false_block;
                    continue :block_loop;
                }
                if (block.term_kind == .fast_br_ult_rr) {
                    if (stats_enabled) self.stats.fast_block_hits += 1;
                    block_idx = if (frame.data[@as(u8, @truncate(block.term_cmp >> 8))] < frame.data[@as(u8, @truncate(block.term_cmp >> 16))]) block.true_block else block.false_block;
                    continue :block_loop;
                }
                var ip = block.start;
                while (ip < block.end) : (ip += 1) {
                    const raw = compiled.code[ip];
                    if (stats_enabled) self.stats.bytecode_ops += 1;
                    switch (rawOp(raw)) {
                        .nop => {},
                        .slow => {
                            if (stats_enabled) self.stats.slow_ops += 1;
                            const slow_idx = rawPayload(raw);
                            const inst_pc = compiled.slow_inst_pcs[slow_idx];
                            switch (try self.executeSlowInstruction(func, &frame, inst_pc, local_alloc, current_args, call_targets)) {
                                .next => {},
                                .tail_restart => {
                                    tail_restart = true;
                                    break :block_loop;
                                },
                                .returned => |ret| return ret,
                            }
                        },
                        .assign_rr => frame.data[rawA(raw)] = frame.data[rawB(raw)],
                        .load_const => {
                            const const_idx = @as(usize, @intCast(raw >> 16));
                            frame.data[rawA(raw)] = compiled.constants[const_idx];
                        },
                        .add_rr => frame.data[rawA(raw)] = frame.data[rawB(raw)] +% frame.data[rawC(raw)],
                        .add_rc => frame.data[rawA(raw)] = frame.data[rawB(raw)] +% compiled.constants[rawC(raw)],
                        .sub_rr => frame.data[rawA(raw)] = frame.data[rawB(raw)] -% frame.data[rawC(raw)],
                        .sub_rc => frame.data[rawA(raw)] = frame.data[rawB(raw)] -% compiled.constants[rawC(raw)],
                        .mul_rr => frame.data[rawA(raw)] = frame.data[rawB(raw)] *% frame.data[rawC(raw)],
                        .mul_rc => frame.data[rawA(raw)] = frame.data[rawB(raw)] *% compiled.constants[rawC(raw)],
                        .udiv_rr => {
                            const rhs = frame.data[rawC(raw)];
                            frame.data[rawA(raw)] = if (rhs != 0) frame.data[rawB(raw)] / rhs else 0;
                        },
                        .udiv_rc => {
                            const rhs = compiled.constants[rawC(raw)];
                            frame.data[rawA(raw)] = if (rhs != 0) frame.data[rawB(raw)] / rhs else 0;
                        },
                        .urem_rr => {
                            const rhs = frame.data[rawC(raw)];
                            frame.data[rawA(raw)] = if (rhs != 0) frame.data[rawB(raw)] % rhs else 0;
                        },
                        .urem_rc => {
                            const rhs = compiled.constants[rawC(raw)];
                            frame.data[rawA(raw)] = if (rhs != 0) frame.data[rawB(raw)] % rhs else 0;
                        },
                        .avg2_rr => frame.data[rawA(raw)] = (frame.data[rawB(raw)] +% frame.data[rawC(raw)]) / 2,
                        .ptr_add_rr => frame.data[rawA(raw)] = frame.data[rawB(raw)] +% frame.data[rawC(raw)],
                        .ptr_add_rc => frame.data[rawA(raw)] = frame.data[rawB(raw)] +% compiled.constants[rawC(raw)],
                        .and_rr => frame.data[rawA(raw)] = frame.data[rawB(raw)] & frame.data[rawC(raw)],
                        .or_rr => frame.data[rawA(raw)] = frame.data[rawB(raw)] | frame.data[rawC(raw)],
                        .xor_rr => frame.data[rawA(raw)] = frame.data[rawB(raw)] ^ frame.data[rawC(raw)],
                        .eq_rr => frame.data[rawA(raw)] = if (frame.data[rawB(raw)] == frame.data[rawC(raw)]) 1 else 0,
                        .eq_rc => frame.data[rawA(raw)] = if (frame.data[rawB(raw)] == compiled.constants[rawC(raw)]) 1 else 0,
                        .ne_rr => frame.data[rawA(raw)] = if (frame.data[rawB(raw)] != frame.data[rawC(raw)]) 1 else 0,
                        .ne_rc => frame.data[rawA(raw)] = if (frame.data[rawB(raw)] != compiled.constants[rawC(raw)]) 1 else 0,
                        .ugt_rr => frame.data[rawA(raw)] = if (frame.data[rawB(raw)] > frame.data[rawC(raw)]) 1 else 0,
                        .ugt_rc => frame.data[rawA(raw)] = if (frame.data[rawB(raw)] > compiled.constants[rawC(raw)]) 1 else 0,
                        .ult_rr => frame.data[rawA(raw)] = if (frame.data[rawB(raw)] < frame.data[rawC(raw)]) 1 else 0,
                        .ult_rc => frame.data[rawA(raw)] = if (frame.data[rawB(raw)] < compiled.constants[rawC(raw)]) 1 else 0,
                        .uge_rr => frame.data[rawA(raw)] = if (frame.data[rawB(raw)] >= frame.data[rawC(raw)]) 1 else 0,
                        .uge_rc => frame.data[rawA(raw)] = if (frame.data[rawB(raw)] >= compiled.constants[rawC(raw)]) 1 else 0,
                        .ule_rr => frame.data[rawA(raw)] = if (frame.data[rawB(raw)] <= frame.data[rawC(raw)]) 1 else 0,
                        .ule_rc => frame.data[rawA(raw)] = if (frame.data[rawB(raw)] <= compiled.constants[rawC(raw)]) 1 else 0,
                        .sgt_rr => frame.data[rawA(raw)] = if (@as(i64, @bitCast(frame.data[rawB(raw)])) > @as(i64, @bitCast(frame.data[rawC(raw)]))) 1 else 0,
                        .sgt_rc => frame.data[rawA(raw)] = if (@as(i64, @bitCast(frame.data[rawB(raw)])) > @as(i64, @bitCast(compiled.constants[rawC(raw)]))) 1 else 0,
                        .slt_rr => frame.data[rawA(raw)] = if (@as(i64, @bitCast(frame.data[rawB(raw)])) < @as(i64, @bitCast(frame.data[rawC(raw)]))) 1 else 0,
                        .slt_rc => frame.data[rawA(raw)] = if (@as(i64, @bitCast(frame.data[rawB(raw)])) < @as(i64, @bitCast(compiled.constants[rawC(raw)]))) 1 else 0,
                        .sge_rr => frame.data[rawA(raw)] = if (@as(i64, @bitCast(frame.data[rawB(raw)])) >= @as(i64, @bitCast(frame.data[rawC(raw)]))) 1 else 0,
                        .sge_rc => frame.data[rawA(raw)] = if (@as(i64, @bitCast(frame.data[rawB(raw)])) >= @as(i64, @bitCast(compiled.constants[rawC(raw)]))) 1 else 0,
                        .sle_rr => frame.data[rawA(raw)] = if (@as(i64, @bitCast(frame.data[rawB(raw)])) <= @as(i64, @bitCast(frame.data[rawC(raw)]))) 1 else 0,
                        .sle_rc => frame.data[rawA(raw)] = if (@as(i64, @bitCast(frame.data[rawB(raw)])) <= @as(i64, @bitCast(compiled.constants[rawC(raw)]))) 1 else 0,
                        .load_u64_off8 => {
                            const addr = addrFromOff8(&frame, rawB(raw), rawC(raw));
                            frame.data[rawA(raw)] = @as(*align(1) const u64, @ptrFromInt(addr)).*;
                        },
                        .load_u64_index8 => {
                            const addr = addrFromIndex8(&frame, rawB(raw), rawC(raw));
                            frame.data[rawA(raw)] = @as(*align(1) const u64, @ptrFromInt(addr)).*;
                        },
                        .store_u64_reg_off8 => {
                            const addr = addrFromOff8(&frame, rawB(raw), rawC(raw));
                            @as(*align(1) u64, @ptrFromInt(addr)).* = frame.data[rawA(raw)];
                            self.bumpMemoryEpoch();
                        },
                        .store_u64_const_off8 => {
                            const addr = addrFromOff8(&frame, rawB(raw), rawC(raw));
                            @as(*align(1) u64, @ptrFromInt(addr)).* = compiled.constants[rawA(raw)];
                            self.bumpMemoryEpoch();
                        },
                        .store_u64_local_reg_off8 => {
                            const addr = addrFromOff8(&frame, rawB(raw), rawC(raw));
                            @as(*align(1) u64, @ptrFromInt(addr)).* = frame.data[rawA(raw)];
                        },
                        .store_u64_local_const_off8 => {
                            const addr = addrFromOff8(&frame, rawB(raw), rawC(raw));
                            @as(*align(1) u64, @ptrFromInt(addr)).* = compiled.constants[rawA(raw)];
                        },
                        .tail_self_regs => {
                            const argc = rawA(raw);
                            if (argc != current_args.len) return error.FfiArityMismatch;
                            if (stats_enabled) self.stats.tail_restarts += 1;
                            const slots = compiled.code[ip + 1];
                            const v0 = if (argc > 0) frame.data[@as(u8, @truncate(slots))] else 0;
                            const v1 = if (argc > 1) frame.data[@as(u8, @truncate(slots >> 8))] else 0;
                            const v2 = if (argc > 2) frame.data[@as(u8, @truncate(slots >> 16))] else 0;
                            const v3 = if (argc > 3) frame.data[@as(u8, @truncate(slots >> 24))] else 0;
                            if (argc > 0) frame.data[0] = v0;
                            if (argc > 1) frame.data[1] = v1;
                            if (argc > 2) frame.data[2] = v2;
                            if (argc > 3) frame.data[3] = v3;
                            block_idx = 0;
                            continue :block_loop;
                        },
                        .call => {
                            const meta = &compiled.calls[rawPayload(raw)];
                            if (self.options.enable_tail_restart and meta.is_tail_call) {
                                if (meta.args.len != current_args.len) return error.FfiArityMismatch;
                                for (meta.args, 0..) |arg, ai| current_args[ai] = self.resolveCompiledVal(&frame, arg);
                                if (needs_arena) {
                                    tail_restart = true;
                                    break :block_loop;
                                }
                                if (stats_enabled) self.stats.tail_restarts += 1;
                                for (current_args, 0..) |arg_val, ai| frame.data[ai] = @as(u64, @intCast(arg_val));
                                block_idx = 0;
                                continue :block_loop;
                            }
                            if (self.options.enable_interpreted_fastpath and meta.args.len <= 8) {
                                switch (meta.target) {
                                    .interpreted => |target_func| {
                                        var args_buf: [8]usize = undefined;
                                        for (meta.args, 0..) |arg, ai| args_buf[ai] = self.resolveCompiledVal(&frame, arg);
                                        const ret = try self.executeInterpretedCall(target_func, args_buf[0..meta.args.len]);
                                        if (meta.dest_slot != INVALID_SLOT) frame.data[meta.dest_slot] = @as(u64, @intCast(ret));
                                        continue;
                                    },
                                    else => {},
                                }
                            }
                            switch (try self.executeCompiledCall(func, &frame, meta, current_args)) {
                                .next => {},
                                .tail_restart => {
                                    tail_restart = true;
                                    break :block_loop;
                                },
                                .returned => |ret| return ret,
                            }
                        },
                        .call_indirect => {
                            const meta = &compiled.indirect_calls[rawPayload(raw)];
                            switch (try self.executeCompiledIndirectCall(&frame, meta)) {
                                .next => {},
                                .tail_restart => {
                                    tail_restart = true;
                                    break :block_loop;
                                },
                                .returned => |ret| return ret,
                            }
                        },
                        .consume_reg => {
                            if (self.result_alloc_index.count() != 0) {
                                const ptr = frame.data[rawA(raw)];
                                _ = self.freeTrackedResultAlloc(@as(usize, @intCast(ptr)));
                            }
                        },
                        .take_off8 => {
                            const addr = addrFromOff8(&frame, rawB(raw), rawC(raw));
                            frame.data[rawA(raw)] = @as(*align(1) const usize, @ptrFromInt(addr)).*;
                        },
                        .try_reg => {
                            const addr = @as(usize, @intCast(frame.data[rawB(raw)]));
                            const tag = @as(*align(1) const u64, @ptrFromInt(addr)).*;
                            if (tag != 0) {
                                _ = self.freeTrackedResultAlloc(addr);
                                return tag;
                            }
                            const dest = rawA(raw);
                            if (dest != BYTE_SLOT_NONE) frame.data[dest] = @as(*align(1) const u64, @ptrFromInt(addr + 8)).*;
                            _ = self.freeTrackedResultAlloc(addr);
                        },
                    }
                }

                switch (block.term_kind) {
                    .fast_avg_load_eq_rr,
                    .fast_tail_add_rc,
                    .fast_tail_sub_rc,
                    .fast_br_eq_rr,
                    .fast_br_eq_rc,
                    .fast_br_ugt_rr,
                    .fast_br_ult_rr,
                    => unreachable,
                    .br => {
                        const cond = if (block.term_cmp != 0)
                            evalTermCmp(&frame, compiled.constants, block.term_cmp)
                        else
                            self.resolveCompiledVal(&frame, block.cond) != 0;
                        block_idx = if (cond) block.true_block else block.false_block;
                        continue :block_loop;
                    },
                    .jmp, .fallthrough => {
                        block_idx = block.true_block;
                        continue :block_loop;
                    },
                    .return_ => {
                        const ret = self.resolveCompiledVal(&frame, block.ret);
                        return self.finishReturn(func, ret);
                    },
                    .end => break :block_loop,
                }
            }

            if (tail_restart) {
                if (stats_enabled) self.stats.tail_restarts += 1;
                if (needs_arena) {
                    frame.deinit();
                    _ = arena.reset(.retain_capacity);
                    local_alloc = arena.allocator();
                    frame = try self.acquireFrame(local_alloc, compiled.slot_count, false);
                } else {
                    // Non-arena tail self-calls overwrite parameter slots before re-entering.
                    // Keeping the rest of the frame avoids millions of hot-loop memsets.
                }
                continue;
            }
            return 0;
        }
    }
};
