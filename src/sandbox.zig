//! Resource-limit layer for the VM sandbox (spec §3.1 fuel / wall clock,
//! §3.2 memory quota, §3.6 violation codes and `sa-vm-event:` line protocol).
//!
//! Self-contained: no imports from vm.zig / plugin.zig / policy.zig, so both
//! can use it freely. The *policy decision* layer lives in policy.zig; this
//! module only enforces numeric resource caps and reports violations.
//!
//! ## Violation codes (reserved sandbox range 100-107, spec §3.6.1)
//!
//! All of them travel through the ordinary VM panic channel (`panic_code` +
//! `error.Panic`) so host-side handling stays unchanged. Exit mapping in
//! plugin.zig is `128 + code & 0x7f`; every code below is <= 127, so each
//! maps to a distinct process exit code.
const std = @import("std");

pub const code_capability_denied: u8 = 100;
pub const code_fuel_exhausted: u8 = 101;
pub const code_timeout: u8 = 102;
pub const code_mem_quota: u8 = 103;
pub const code_verify_failed: u8 = 104;
pub const code_policy_invalid: u8 = 105;
pub const code_sandbox_misconfig: u8 = 106;
/// Not in the spec's original table (its reserved band is 90-119); used for a
/// clean call-depth / host-stack-guard abort instead of a 0xC0000005 crash.
pub const code_stack_overflow: u8 = 107;

/// Machine-readable name for a reserved code (grep target for harnesses).
pub fn nameForCode(code: u8) []const u8 {
    return switch (code) {
        code_capability_denied => "E_CAPABILITY_DENIED",
        code_fuel_exhausted => "E_FUEL_EXHAUSTED",
        code_timeout => "E_TIMEOUT",
        code_mem_quota => "E_MEM_QUOTA",
        code_verify_failed => "E_VERIFY_FAILED",
        code_policy_invalid => "E_POLICY_INVALID",
        code_sandbox_misconfig => "E_SANDBOX_MISCONFIG",
        code_stack_overflow => "E_STACK_OVERFLOW",
        else => "E_UNKNOWN",
    };
}

/// Wall-clock checks are lazy: once every this many charged blocks, plus a
/// forced checkpoint around every FFI/pthread/broker/builtin call (spec §3.1
/// step 4).
pub const clock_check_interval_blocks: u32 = 1024;

/// Host-stack headroom kept below the deepest guest call frame. When a guest
/// call entry would leave less than this many bytes of thread stack, the VM
/// raises E_STACK_OVERFLOW instead of hitting a guard page.
///
/// 256 KiB is comfortably above the deepest native call chain inside one VM
/// dispatch step (compile/dispatch helpers are shallow) while costing legit
/// programs only a few hundred frames of depth on a 1 MiB Windows main stack.
pub const default_stack_headroom_bytes: usize = 256 * 1024;

/// Explicit --max-call-depth ceiling. On Windows the TEB-based stack guard
/// above binds first on typical 1-8 MiB stacks (measured ~2.7k frames for the
/// deep_recursion corpus case on a 1 MiB stack); this counter only matters on
/// runtimes with very large stacks. Depth-1000 programs pass with >30x margin.
pub const default_max_call_depth: u32 = 100_000;

/// Effective limits for one VM run. Zero/null members mean "cap disabled"
/// (dev ergonomics unchanged when no flags/policy are given).
pub const Limits = struct {
    /// Total block-cost units (spec §3.1). null => no fuel accounting.
    fuel: ?u64 = null,
    /// Wall-clock cap in milliseconds. null => no deadline.
    wall_clock_ms: ?u64 = null,
    /// Heap cap in bytes enforced by QuotaAllocator. null/0 => unlimited.
    mem_cap_bytes: ?u64 = null,
    max_call_depth: u32 = default_max_call_depth,
    stack_headroom_bytes: usize = default_stack_headroom_bytes,

    pub fn anyResourceCap(self: Limits) bool {
        return self.fuel != null or self.wall_clock_ms != null or
            (self.mem_cap_bytes != null and self.mem_cap_bytes.? != 0);
    }
};

/// Live runtime counters for one VM instance. Owned inline by `VM`; a pointer
/// to it sits in `VM.sandbox` only while at least one resource cap is active,
/// mirroring the `stats_enabled` null-gate idiom so the hot block loop pays a
/// single predicted branch when limits are off.
pub const State = struct {
    /// Total budget; 0 disables fuel accounting.
    fuel_total: u64 = 0,
    fuel_remaining: u64 = 0,
    /// Absolute wall-clock deadline (std.time.nanoTimestamp() domain).
    deadline_ns: ?i128 = null,
    blocks_since_clock_check: u32 = 0,
    mem_cap_bytes: u64 = 0,
    /// Run start in the same clock domain as deadline_ns; used for reporting.
    run_start_ns: i128 = 0,

    pub fn fuelEnabled(self: *const State) bool {
        return self.fuel_total != 0;
    }

    pub fn fuelUsed(self: *const State) u64 {
        // The raise path zeroes fuel_remaining on exhaustion, so this is
        // exact both mid-run and at the violation point.
        return self.fuel_total -| self.fuel_remaining;
    }

    pub fn wallMsElapsed(self: *const State) u64 {
        const now = std.time.nanoTimestamp();
        const elapsed = now - self.run_start_ns;
        if (elapsed <= 0) return 0;
        return @intCast(@divTrunc(elapsed, std.time.ns_per_ms));
    }

    pub fn deadlineExceeded(self: *const State) bool {
        const deadline = self.deadline_ns orelse return false;
        return std.time.nanoTimestamp() >= deadline;
    }
};

/// Point-in-time numbers embedded into violation events so harnesses can tune
/// caps without re-running under a profiler.
pub const Snapshot = struct {
    fuel_used: u64 = 0,
    wall_ms: u64 = 0,
    mem_peak_bytes: u64 = 0,
};

fn writeEventCommon(writer: anytype, event: []const u8, code: u8, detail: []const u8, snap: Snapshot) !void {
    try writer.writeAll("sa-vm-event: {\"v\":1,\"event\":\"");
    try writer.writeAll(event);
    try writer.print("\",\"code\":{d},\"name\":\"{s}\"", .{ code, nameForCode(code) });
    if (detail.len != 0) {
        try writer.writeAll(",\"detail\":");
        try std.json.encodeJsonString(detail, .{}, writer);
    }
    try writer.print(",\"fuel_used\":{d},\"wall_ms\":{d},\"mem_peak_bytes\":{d}}}", .{
        snap.fuel_used, snap.wall_ms, snap.mem_peak_bytes,
    });
    try writer.writeByte('\n');
}

/// One grep-friendly JSON line describing a violation (spec §3.6.2).
pub fn writeViolationEvent(writer: anytype, code: u8, detail: []const u8, snap: Snapshot) !void {
    try writeEventCommon(writer, "violation", code, detail, snap);
}

/// Lifecycle event echoing the effective limits before guest code runs.
/// Shape: `sa-vm-event: {"v":1,"event":"start","fuel":N|null,...}`.
pub fn writeStartEvent(writer: anytype, limits: Limits) !void {
    try writer.writeAll("sa-vm-event: {\"v\":1,\"event\":\"start\"");
    if (limits.fuel) |n| {
        try writer.print(",\"fuel\":{d}", .{n});
    } else {
        try writer.writeAll(",\"fuel\":null");
    }
    if (limits.wall_clock_ms) |ms| {
        try writer.print(",\"wall_clock_ms\":{d}", .{ms});
    } else {
        try writer.writeAll(",\"wall_clock_ms\":null");
    }
    if (limits.mem_cap_bytes) |b| {
        if (b == 0) {
            try writer.writeAll(",\"mem_cap_bytes\":null");
        } else {
            try writer.print(",\"mem_cap_bytes\":{d}", .{b});
        }
    } else {
        try writer.writeAll(",\"mem_cap_bytes\":null");
    }
    try writer.print(",\"max_call_depth\":{d},\"stack_headroom_bytes\":{d}}}\n", .{
        limits.max_call_depth, limits.stack_headroom_bytes,
    });
}

/// Allocator wrapper enforcing a hard byte cap (spec §3.2). Every alloc /
/// resize / remap that would push live bytes past the cap fails with
/// error.OutOfMemory, which vm.zig translates into an E_MEM_QUOTA panic at
/// the two catch points that matter (.alloc/.stack_alloc op, acquireFrame).
///
/// Byte tracking is exact for the allocations that flow through it because
/// free() receives the slice length and arena resets never release memory
/// behind our back (retain_capacity keeps the buffers alive and counted).
pub const QuotaAllocator = struct {
    child_allocator: std.mem.Allocator,
    cap_bytes: u64,
    live_bytes: u64 = 0,
    peak_bytes: u64 = 0,

    pub fn init(child_allocator: std.mem.Allocator, cap_bytes: u64) QuotaAllocator {
        return .{ .child_allocator = child_allocator, .cap_bytes = cap_bytes };
    }

    pub fn allows(self: *const QuotaAllocator, additional: u64) bool {
        return self.live_bytes + additional <= self.cap_bytes;
    }

    fn addBytes(self: *QuotaAllocator, n: usize) void {
        self.live_bytes += @intCast(n);
        if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
    }

    fn removeBytes(self: *QuotaAllocator, n: usize) void {
        self.live_bytes -|= @intCast(n);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *QuotaAllocator = @ptrCast(@alignCast(ctx));
        if (!self.allows(len)) return null;
        const ptr = self.child_allocator.rawAlloc(len, alignment, ret_addr);
        if (ptr != null) self.addBytes(len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *QuotaAllocator = @ptrCast(@alignCast(ctx));
        if (!self.allows(new_len -| memory.len)) return false;
        if (!self.child_allocator.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len >= memory.len) {
            self.addBytes(new_len - memory.len);
        } else {
            self.removeBytes(memory.len - new_len);
        }
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *QuotaAllocator = @ptrCast(@alignCast(ctx));
        if (!self.allows(new_len -| memory.len)) return null;
        const ptr = self.child_allocator.rawRemap(memory, alignment, new_len, ret_addr);
        if (ptr != null) {
            if (new_len >= memory.len) {
                self.addBytes(new_len - memory.len);
            } else {
                self.removeBytes(memory.len - new_len);
            }
        }
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *QuotaAllocator = @ptrCast(@alignCast(ctx));
        self.removeBytes(memory.len);
        self.child_allocator.rawFree(memory, alignment, ret_addr);
    }

    pub fn allocator(self: *QuotaAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }
};

/// Per-block fuel cost model (spec §3.1 step 1):
///   cost = body_words * 1 + slow_words * 15 + call_words * 31 + terminator(1)
/// Fast-path superinstruction arms have empty bodies; they execute a fixed
/// handful of machine-level operations plus a branch, priced at 4 units.
pub const block_cost_base: u32 = 1;
pub const block_cost_slow_op: u32 = 15;
pub const block_cost_call: u32 = 31;
pub const block_cost_fast_arm: u32 = 4;

pub fn blockCost(body_words: usize, slow_words: usize, call_words: usize, fast_arm: bool) u32 {
    if (fast_arm) return block_cost_fast_arm;
    const words: u32 = @intCast(body_words);
    const slows: u32 = @intCast(slow_words);
    const calls: u32 = @intCast(call_words);
    // Every dispatched block costs at least one unit: an empty-bodied block
    // (e.g. a bare `jmp` back-edge forming an infinite loop) must still burn
    // fuel or `while(true){}` would be free.
    const raw = words +% (block_cost_base - 1) +% slows *% block_cost_slow_op +% calls *% block_cost_call;
    return if (raw == 0) 1 else raw;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "quota allocator admits under cap and rejects over cap" {
    var quota = QuotaAllocator.init(std.heap.page_allocator, 4096);
    const alloc = quota.allocator();

    const ok = try alloc.alloc(u8, 1024);
    defer alloc.free(ok);
    try testing.expectEqual(@as(u64, 1024), quota.live_bytes);

    try testing.expectError(error.OutOfMemory, alloc.alloc(u8, 8192));

    // Exactly filling the remaining budget is allowed.
    const rest = try alloc.alloc(u8, 3072);
    try testing.expectEqual(@as(u64, 4096), quota.live_bytes);
    try testing.expectEqual(@as(u64, 4096), quota.peak_bytes);
    try testing.expectError(error.OutOfMemory, alloc.alloc(u8, 1));

    alloc.free(rest);
    try testing.expectEqual(@as(u64, 1024), quota.live_bytes);

    // Re-allocating the freed budget succeeds again.
    const again = try alloc.alloc(u8, 3072);
    defer alloc.free(again);
    try testing.expectEqual(@as(u64, 4096), quota.live_bytes);
}

test "quota allocator tracks resize growth and shrink" {
    var quota = QuotaAllocator.init(std.heap.c_allocator, 1024);
    const alloc = quota.allocator();

    const buf = try alloc.alloc(u8, 128);
    defer alloc.free(buf);
    try testing.expectEqual(@as(u64, 128), quota.live_bytes);

    // Over-cap resizes are refused by the quota itself, before the child
    // allocator is consulted, and never disturb the accounting.
    try testing.expect(!alloc.resize(buf, 2048));
    try testing.expectEqual(@as(u64, 128), quota.live_bytes);
    try testing.expect(alloc.remap(buf, 2048) == null);
    try testing.expectEqual(@as(u64, 128), quota.live_bytes);

    // Shrinks are within cap; whether the child can satisfy them in place is
    // its own decision, but any success must be reflected in live bytes.
    if (alloc.resize(buf, 64)) {
        try testing.expectEqual(@as(u64, 64), quota.live_bytes);
    }
    // Single free via the defer above releases the accounted bytes exactly.
}

test "violation events render stable single-line json" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try writeViolationEvent(buf.writer(), code_fuel_exhausted, "budget 42 exceeded \"here\"", .{
        .fuel_used = 43,
        .wall_ms = 7,
        .mem_peak_bytes = 2048,
    });
    const line = buf.items;
    try testing.expect(std.mem.startsWith(u8, line, "sa-vm-event: {"));
    try testing.expect(line[line.len - 1] == '\n');
    try testing.expect(std.mem.indexOfScalar(u8, line[0 .. line.len - 1], '\n') == null);
    try testing.expect(std.mem.indexOf(u8, line, "\"code\":101") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"name\":\"E_FUEL_EXHAUSTED\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\\\"here\\\"") != null);
}

test "block cost model prices slow ops and calls above plain words" {
    try testing.expect(blockCost(4, 0, 0, false) == 4 + (block_cost_base - 1));
    try testing.expect(blockCost(0, 0, 0, true) == block_cost_fast_arm);
    const with_slow = blockCost(4, 1, 0, false);
    const with_call = blockCost(4, 0, 1, false);
    try testing.expect(with_call > with_slow);
    try testing.expect(blockCost(0, 2, 1, false) == 2 * block_cost_slow_op + block_cost_call + (block_cost_base - 1));
}

test "empty blocks still cost fuel" {
    // A bare `jmp L_ENTRY` back-edge compiles to an empty-bodied block; it must
    // never be free or infinite loops become unkillable by fuel.
    try testing.expectEqual(@as(u32, 1), blockCost(0, 0, 0, false));
}

test "start event renders limits with nulls for unlimited" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try writeStartEvent(buf.writer(), .{ .fuel = 500_000, .mem_cap_bytes = 0 });
    const line = buf.items;
    try testing.expect(std.mem.startsWith(u8, line, "sa-vm-event: {\"v\":1,\"event\":\"start\""));
    try testing.expect(std.mem.indexOf(u8, line, "\"fuel\":500000") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"wall_clock_ms\":null") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"mem_cap_bytes\":null") != null);
}

test "state tracks fuel usage against total" {
    var state = State{ .fuel_total = 100, .fuel_remaining = 60 };
    try testing.expect(state.fuelEnabled());
    try testing.expectEqual(@as(u64, 40), state.fuelUsed());

    var exhausted = State{ .fuel_total = 100, .fuel_remaining = 0 };
    try testing.expectEqual(@as(u64, 100), exhausted.fuelUsed());

    var off = State{};
    try testing.expect(!off.fuelEnabled());
    try testing.expectEqual(@as(u64, 0), off.fuelUsed());

    var deadline_state = State{ .deadline_ns = 0 };
    try testing.expect(deadline_state.deadlineExceeded());
}
