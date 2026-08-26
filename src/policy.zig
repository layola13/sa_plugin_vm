//! Capability I/O policy engine for the VM sandbox (`sa.vm.policy/1`).
//!
//! Self-contained module: no imports from plugin.zig / vm.zig / sab_loader.zig.
//! This file implements the *decision* layer of spec §3.3 (scratch/docs/
//! vm_security_spec.md): parsing + validating a run policy from JSON, Windows
//! path canonicalization BEFORE pattern matching, glob matching over fs paths,
//! host/method/path HTTP matching with per-hop redirect validation, and
//! default-deny decision API returning tagged verdicts.
//!
//! It deliberately does NOT touch the OS beyond `realpathAlloc` probes during
//! canonicalization; opening files, sockets, processes stays with the broker.
//!
//! ## Threats covered (see doc comments on each mechanism)
//!
//! | Threat                              | Mechanism                                   |
//! |-------------------------------------|---------------------------------------------|
//! | `..` traversal                      | lexical resolve before match, `..` rejected |
//! | junction/symlink escape             | realpath (GetFinalPathNameByHandle) first   |
//! | 8.3 short names (`FACTO~1`)         | realpath rewrites to long form              |
//! | case tricks                         | ASCII fold on Windows at compare time only  |
//! | prefix confusion (`data-evil`)      | segment-boundary-aware glob matching        |
//! | NTFS alternate data streams         | reject `:` outside drive position           |
//! | DOS device names / device namespace | reject CON/NUL/COM1../`\\.\`/`\\?\` inputs  |
//! | unknown policy keys silently ignored| fail closed with error.PolicyInvalid        |

const std = @import("std");
const builtin = @import("builtin");

/// Compare paths/hostnames case-insensitively on Windows only. On-disk casing
/// on Windows filesystems is case-preserving but case-insensitive for lookup,
/// so a guest must not gain access by changing letter case. POSIX stays exact.
pub const case_insensitive_fs = builtin.os.tag == .windows;

/// Reserved sandbox panic codes, spec §3.6.1. Distinct reasons below all map
/// onto E_CAPABILITY_DENIED; the reason tells the harness *what* to fix.
pub const panic_code_capability_denied: u8 = 100;
pub const panic_code_policy_invalid: u8 = 105;

pub const expected_schema: []const u8 = "sa.vm.policy/1";

pub const ParseError = error{ PolicyInvalid, OutOfMemory };

/// Distinct denial causes. Every one maps to panic code
/// `panic_code_capability_denied`; `label()` is the machine-readable detail
/// string used in `sa-vm-event:` violation events (spec §3.6.2).
pub const DenyReason = enum {
    fs_not_allowed,
    fs_path_invalid,
    http_bad_target_url,
    http_scheme_unsupported,
    http_host_not_allowed,
    http_method_not_allowed,
    http_path_not_allowed,
    http_port_not_allowed,
    http_ip_literal_not_allowed,
    http_private_address_denied,
    http_redirect_limit,
    http_downgrade_denied,
    env_not_allowed,
    process_spawn_disabled,
    process_exec_not_allowed,
    ffi_denied,
    threads_denied,
    net_raw_denied,
    /// Layer 1: the called extern symbol is not named by `extern.allow`.
    /// Raised BEFORE any FFI/dlopen resolution attempt happens.
    extern_not_allowed,

    pub fn label(self: DenyReason) []const u8 {
        return switch (self) {
            .fs_not_allowed => "fs_not_allowed",
            .fs_path_invalid => "fs_path_invalid",
            .http_bad_target_url => "bad_url",
            .http_scheme_unsupported => "scheme_not_allowed",
            .http_host_not_allowed => "host_not_allowed",
            .http_method_not_allowed => "method_not_allowed",
            .http_path_not_allowed => "path_not_allowed",
            .http_port_not_allowed => "port_not_allowed",
            .http_ip_literal_not_allowed => "ip_literal_not_allowed",
            .http_private_address_denied => "private_address",
            .http_redirect_limit => "redirect_limit",
            .http_downgrade_denied => "https_to_http_downgrade",
            .env_not_allowed => "env_not_allowed",
            .process_spawn_disabled => "process_spawn_disabled",
            .process_exec_not_allowed => "exec_not_allowed",
            .ffi_denied => "ffi_denied",
            .threads_denied => "threads_denied",
            .net_raw_denied => "net_raw_denied",
            .extern_not_allowed => "extern_not_allowed",
        };
    }

    pub fn panicCode(self: DenyReason) u8 {
        _ = self;
        return panic_code_capability_denied;
    }
};

/// Tagged decision: `.allow` or `.deny { reason }`.
pub const Verdict = union(enum) {
    allow,
    deny: struct { reason: DenyReason },

    pub fn isAllowed(self: Verdict) bool {
        return self == .allow;
    }

    pub fn denyReason(self: Verdict) ?DenyReason {
        return switch (self) {
            .allow => null,
            .deny => |d| d.reason,
        };
    }
};

fn deny(reason: DenyReason) Verdict {
    return .{ .deny = .{ .reason = reason } };
}

pub const FsOp = enum { read, write };

pub const HttpMethod = enum { GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS };

pub fn methodBit(method: HttpMethod) u16 {
    return switch (method) {
        .GET => 1 << 0,
        .POST => 1 << 1,
        .PUT => 1 << 2,
        .PATCH => 1 << 3,
        .DELETE => 1 << 4,
        .HEAD => 1 << 5,
        .OPTIONS => 1 << 6,
    };
}

/// Case-insensitive method-name parse; unknown methods yield null so callers
/// deny rather than guess (fail closed).
pub fn parseMethod(text: []const u8) ?HttpMethod {
    inline for (@typeInfo(HttpMethod).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub const HttpRule = struct {
    /// Lowercased host as written in the policy (IP literals allowed only when
    /// spelled as an IP literal here — see checkHttp).
    host: []const u8,
    /// Bitmask of permitted methods; empty means NO method is allowed (a rule
    /// with an explicit `"methods": []` denies everything — fail closed).
    methods_mask: u16 = 0,
    /// Optional path patterns; empty slice means any path on this host.
    paths: []const []const u8 = &.{},
    /// Optional explicit port. When null, both implied ports 80 and 443 are
    /// accepted (spec §3.3.4: default ports implied).
    port: ?u16 = null,
};

pub const ProcessExecRule = struct {
    path: []const u8,
    /// Exact argv tail; the single entry `"*"` matches any single argument.
    args: []const []const u8 = &.{},
};

pub const Limits = struct {
    fuel: ?u64 = null,
    wall_clock_ms: ?u64 = null,
    mem_cap_bytes: ?u64 = null,
};

/// Parsed `sa.vm.policy/1`. All strings/slices live in an internal arena so
/// `deinit` releases everything at once and callers may hand any allocator in.
/// Semantics: every section that is absent grants nothing (default deny).
pub const Policy = struct {
    arena: *std.heap.ArenaAllocator,

    schema: []const u8 = "",
    fs_read: []const []const u8 = &.{},
    fs_write: []const []const u8 = &.{},
    http_rules: []const HttpRule = &.{},
    http_max_redirects: u32 = 5,
    /// SSRF pragmatics, spec §3.3.4(4): deny IP-literal loopback/private/
    /// link-local targets unless explicitly relaxed by the policy author.
    deny_private_addresses: bool = true,
    env_allow: []const []const u8 = &.{},
    /// Layer 1 extern allowlist (spec §3.4): exact symbol names or names with a
    /// single trailing `*`. Absent/empty section => EVERY extern call is denied
    /// before FFI resolution (default deny). VM builtins (`sa_print_bytes`,
    /// `sa_fmt_i64`, time builtins, ...) are implemented inside the interpreter
    /// and never reach this gate.
    extern_allow: []const []const u8 = &.{},
    process_spawn: bool = false,
    process_exec: []const ProcessExecRule = &.{},
    net_raw: bool = false,
    ffi: bool = false,
    threads: bool = false,
    limits: Limits = .{},

    /// Parse + validate. Unknown keys anywhere in the document are a parse
    /// error (never silently ignored), wrong-typed values likewise: the whole
    /// point of a capability policy is that typos must not widen access.
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Policy {
        var arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const alloc = arena.allocator();
        // Leak-check note: on parse failure the errdefers unwind the arena.
        const root_value = std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{}) catch
            return error.PolicyInvalid;
        const root = jsonObject(root_value) catch return error.PolicyInvalid;

        var policy = Policy{ .arena = arena };

        var it = root.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (std.mem.eql(u8, key, "schema")) {
                policy.schema = try jsonString(value);
                if (!std.mem.eql(u8, policy.schema, expected_schema)) return error.PolicyInvalid;
            } else if (std.mem.eql(u8, key, "fs")) {
                try parseFsSection(alloc, value, &policy);
            } else if (std.mem.eql(u8, key, "http")) {
                try parseHttpSection(alloc, value, &policy);
            } else if (std.mem.eql(u8, key, "env")) {
                const obj = try jsonObject(value);
                var env_it = obj.iterator();
                while (env_it.next()) |env_entry| {
                    const env_key = env_entry.key_ptr.*;
                    if (!std.mem.eql(u8, env_key, "allow")) return error.PolicyInvalid;
                    policy.env_allow = try stringArrayField(alloc, obj, "allow");
                    for (policy.env_allow) |pattern| try validateEnvPattern(pattern);
                }
            } else if (std.mem.eql(u8, key, "process")) {
                try parseProcessSection(alloc, value, &policy);
            } else if (std.mem.eql(u8, key, "extern")) {
                try parseExternSection(alloc, value, &policy);
            } else if (std.mem.eql(u8, key, "net_raw")) {
                policy.net_raw = try jsonBool(value);
            } else if (std.mem.eql(u8, key, "ffi")) {
                policy.ffi = try jsonBool(value);
            } else if (std.mem.eql(u8, key, "threads")) {
                policy.threads = try jsonBool(value);
            } else if (std.mem.eql(u8, key, "limits")) {
                try parseLimitsSection(value, &policy);
            } else {
                return error.PolicyInvalid;
            }
        }
        return policy;
    }

    /// Releases all memory owned by the policy (the internal arena). Safe to
    /// call on a policy parsed against any injected allocator.
    pub fn deinit(self: *Policy) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    // ------------------------------------------------------------------
    // Filesystem
    // ------------------------------------------------------------------

    /// Canonicalize then glob-match one fs operation. Never fails except for
    /// OOM: anything wrong with the requested path becomes a denial
    /// (`.fs_path_invalid`), because a canonicalization failure must fail
    /// closed, not bypass the gate.
    ///
    /// `base_dir` resolves relative guest paths (pass the broker's project
    /// root); pass null only for guaranteed-absolute inputs.
    pub fn checkFs(
        self: *const Policy,
        allocator: std.mem.Allocator,
        op: FsOp,
        raw_path: []const u8,
        base_dir: ?[]const u8,
    ) error{OutOfMemory}!Verdict {
        const canon = canonicalizePath(allocator, base_dir, raw_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPath => return deny(.fs_path_invalid),
        };
        defer allocator.free(canon);

        const patterns = switch (op) {
            .read => self.fs_read,
            .write => self.fs_write,
        };
        // No allowlist entries for this op => default deny.
        var verdict = deny(.fs_not_allowed);
        for (patterns) |pattern| {
            if (!validPattern(pattern)) continue;
            if (try pathGlobMatch(allocator, pattern, canon)) {
                verdict = .allow;
                break;
            }
        }
        return verdict;
    }

    pub fn checkFsRead(self: *const Policy, allocator: std.mem.Allocator, raw_path: []const u8, base_dir: ?[]const u8) error{OutOfMemory}!Verdict {
        return self.checkFs(allocator, .read, raw_path, base_dir);
    }

    pub fn checkFsWrite(self: *const Policy, allocator: std.mem.Allocator, raw_path: []const u8, base_dir: ?[]const u8) error{OutOfMemory}!Verdict {
        return self.checkFs(allocator, .write, raw_path, base_dir);
    }

    // ------------------------------------------------------------------
    // Environment variables
    // ------------------------------------------------------------------

    /// Trailing-`*` prefix matcher, mirroring the sap.json semantics of
    /// `matchesAnyEnvPattern` (sci/src/plugins.zig:982-991). Byte-exact
    /// otherwise (no case folding: env lookups differ per platform).
    pub fn checkEnv(self: *const Policy, name: []const u8) Verdict {
        for (self.env_allow) |pattern| {
            if (std.mem.endsWith(u8, pattern, "*")) {
                const stem = pattern[0 .. pattern.len - 1];
                if (std.mem.startsWith(u8, name, stem)) return .allow;
                continue;
            }
            if (std.mem.eql(u8, name, pattern)) return .allow;
        }
        return deny(.env_not_allowed);
    }

    // ------------------------------------------------------------------
    // Extern symbol allowlist (Layer 1)
    // ------------------------------------------------------------------

    /// Exact-name or single-trailing-`*` prefix match over `extern.allow`,
    /// mirroring checkEnv. `"*"` alone allows every symbol (explicit operator
    /// choice; Layer 2 argument checks still apply to classified symbols).
    pub fn checkExtern(self: *const Policy, symbol: []const u8) Verdict {
        for (self.extern_allow) |pattern| {
            if (std.mem.endsWith(u8, pattern, "*")) {
                const stem = pattern[0 .. pattern.len - 1];
                if (std.mem.startsWith(u8, symbol, stem)) return .allow;
                continue;
            }
            if (std.mem.eql(u8, symbol, pattern)) return .allow;
        }
        return deny(.extern_not_allowed);
    }

    // ------------------------------------------------------------------
    // HTTP
    // ------------------------------------------------------------------

    /// Validate one request (method + URL) against the allow rules. Scheme is
    /// limited to http/https; hosts compare lowercase; effective ports use
    /// implied 80/443; IP-literal targets must be explicitly allowlisted as
    /// such and are subject to the private-address deny list.
    pub fn checkHttp(
        self: *const Policy,
        allocator: std.mem.Allocator,
        method_text: []const u8,
        url: []const u8,
    ) error{OutOfMemory}!Verdict {
        const method = parseMethod(method_text) orelse return deny(.http_method_not_allowed);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const uri = std.Uri.parse(url) catch return deny(.http_bad_target_url);
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https"))
            return deny(.http_scheme_unsupported);
        const host_component = uri.host orelse return deny(.http_bad_target_url);
        const host = normalizeHost(alloc, host_component) catch return deny(.http_bad_target_url);
        if (host.len == 0) return deny(.http_bad_target_url);

        // IP-literal hosts never fall through to hostname rules (fail closed:
        // a guest cannot smuggle `http://127.0.0.1/x` past an
        // api.example.com allowlist). SSRF pragmatics (spec §3.3.4 step 4):
        // plain-text IP literals skip DNS; DNS-resolved address validation
        // lives with the connector via isDeniedPrivateAddress.
        const is_ip_target = isIpLiteral(host);

        const eff_port = effectivePort(uri) orelse return deny(.http_scheme_unsupported);
        const req_path = try normalizedUrlPath(alloc, uri);

        var saw_host = false;
        var saw_host_method = false;
        var saw_host_method_port = false;
        var fully_matched = false;
        for (self.http_rules) |rule| {
            if (!std.ascii.eqlIgnoreCase(rule.host, host)) continue;
            saw_host = true;
            if ((rule.methods_mask & methodBit(method)) == 0) continue;
            saw_host_method = true;
            if (!rulePortsAllow(rule, eff_port)) continue;
            saw_host_method_port = true;
            if (!(try ruleAllowsPath(alloc, rule, req_path))) continue;
            fully_matched = true;
        }
        // Diagnose the *narrowest* failed constraint so the harness can tell
        // "wrong host" from "right host, wrong method/port/path".
        if (!fully_matched) {
            if (!saw_host)
                return deny(if (is_ip_target) .http_ip_literal_not_allowed else .http_host_not_allowed);
            if (!saw_host_method) return deny(.http_method_not_allowed);
            if (!saw_host_method_port) return deny(.http_port_not_allowed);
            return deny(.http_path_not_allowed);
        }
        if (is_ip_target and self.deny_private_addresses and isPrivateIpLiteral(host))
            return deny(.http_private_address_denied);
        return .allow;
    }

    /// Validate one redirect hop (spec §3.3.4 step 3): callers fetch with
    /// redirect behavior `.unhandled`, then feed each `Location` through here
    /// together with the (possibly downgraded) method of that hop.
    ///
    /// * hop count cap -> `.http_redirect_limit`
    /// * https->http downgrade -> `.http_downgrade_denied` (always denied)
    /// * otherwise the new URL gets the full checkHttp treatment, including
    ///   the method mask of that hop.
    pub fn checkRedirect(
        self: *const Policy,
        allocator: std.mem.Allocator,
        method_text: []const u8,
        previous_url: []const u8,
        location_url: []const u8,
        redirects_done: u32,
    ) error{OutOfMemory}!Verdict {
        if (redirects_done >= self.http_max_redirects) return deny(.http_redirect_limit);

        const prev_uri = std.Uri.parse(previous_url) catch return deny(.http_bad_target_url);
        const next_uri = std.Uri.parse(location_url) catch return deny(.http_bad_target_url);
        if (std.ascii.eqlIgnoreCase(prev_uri.scheme, "https") and std.ascii.eqlIgnoreCase(next_uri.scheme, "http"))
            return deny(.http_downgrade_denied);
        return self.checkHttp(allocator, method_text, location_url);
    }

    /// Resolve a `Location` header value against the previous hop. Absolute
    /// URLs pass through unchanged; root-relative (`/next`) and scheme-less
    /// protocol-relative (`//host/next`) forms are joined; anything else
    /// (bare-relative refs) errors so callers deny rather than guess.
    pub fn absolutizeRedirect(
        allocator: std.mem.Allocator,
        previous_url: []const u8,
        location: []const u8,
    ) error{ OutOfMemory, BadRedirectLocation }![]u8 {
        if (location.len == 0) return error.BadRedirectLocation;

        if (hasSchemePrefix(location)) return allocator.dupe(u8, location);

        // Protocol-relative: keep only the previous scheme.
        if (std.mem.startsWith(u8, location, "//")) {
            const prev_scheme_end = std.mem.indexOf(u8, previous_url, "://") orelse return error.BadRedirectLocation;
            return std.fmt.allocPrint(allocator, "{s}:{s}", .{ previous_url[0..prev_scheme_end], location });
        }

        // Root-relative: reuse the full authority (host + optional port).
        if (location[0] != '/') return error.BadRedirectLocation;
        const prev = std.Uri.parse(previous_url) catch return error.BadRedirectLocation;
        if (prev.host == null) return error.BadRedirectLocation;
        const authority = renderAuthority(allocator, previous_url, prev) orelse return error.BadRedirectLocation;
        defer allocator.free(authority);
        if (authority.len == 0) return error.BadRedirectLocation;
        return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ prev.scheme, authority, location });
    }

    // ------------------------------------------------------------------
    // Process / FFI / threads / raw networking gates
    // ------------------------------------------------------------------

    pub fn checkFfi(self: *const Policy) Verdict {
        return if (self.ffi) .allow else deny(.ffi_denied);
    }

    pub fn checkThreads(self: *const Policy) Verdict {
        return if (self.threads) .allow else deny(.threads_denied);
    }

    pub fn checkNetRaw(self: *const Policy) Verdict {
        return if (self.net_raw) .allow else deny(.net_raw_denied);
    }

    /// Spawn gate: `process.spawn` must be true; when `process.exec` lists
    /// rules, the executable + argv must match one exactly (`*` wildcards a
    /// single argument). With spawn=true and no exec rules, any spawn under
    /// the granted flag is allowed (documented operator choice).
    pub fn checkProcessSpawn(
        self: *const Policy,
        allocator: std.mem.Allocator,
        executable: []const u8,
        argv: []const []const u8,
    ) error{OutOfMemory}!Verdict {
        if (!self.process_spawn) return deny(.process_spawn_disabled);
        if (self.process_exec.len == 0) return .allow;
        for (self.process_exec) |rule| {
            if (!(try normalizedEql(allocator, rule.path, executable))) continue;
            if (rule.args.len != argv.len) continue;
            var ok = true;
            for (rule.args, argv) |want, got| {
                if (std.mem.eql(u8, want, "*")) continue;
                if (!std.mem.eql(u8, want, got)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return .allow;
        }
        return deny(.process_exec_not_allowed);
    }
};

// ----------------------------------------------------------------------
// Path canonicalization (spec §3.3.3)
// ----------------------------------------------------------------------
//
// Order of operations, per operation:
//   1. reject pathological input up front (see validateRawPath),
//   2. lexical resolve (collapses `.`/`..`, unifies separators),
//   3. realpath resolve via std.fs.Dir.realpathAlloc — on Windows this goes
//      through GetFinalPathNameByHandle, which fully expands symlinks AND
//      junctions and rewrites 8.3 short names (FACTO~1) to long form, so the
//      string we pattern-match is the object the OS would actually touch,
//   4. strip the `\\?\` / `\\?\UNC\` prefix GetFinalPathNameByHandle adds,
//   5. nonexistent targets (the common write case): canonicalize the deepest
//      existing ancestor and append the remaining components lexically —
//      those components came out of the lexically-resolved path, so they can
//      contain no links and no `..`,
//   6. final paranoia: refuse any result still containing a `..` component.
//
// Residual risk (accepted, spec §6): between the ancestor realpath probe and
// the actual open a parent directory component could be swapped for a
// junction; the broker re-canonicalizes after open (step 7 of the spec) which
// is integration-side.

pub const CanonicalizeError = error{ InvalidPath, OutOfMemory };

/// Canonicalize `raw_path` (absolute or relative to `base_dir`) into a form
/// safe to compare against policy patterns.
pub fn canonicalizePath(
    allocator: std.mem.Allocator,
    base_dir: ?[]const u8,
    raw_path: []const u8,
) CanonicalizeError![]u8 {
    try validateRawPath(raw_path);

    var lexical: []u8 = undefined;
    if (std.fs.path.isAbsolute(raw_path) or std.fs.path.isAbsoluteWindows(raw_path)) {
        lexical = try std.fs.path.resolve(allocator, &.{raw_path});
    } else {
        const base = base_dir orelse return error.InvalidPath;
        if (base.len == 0) return error.InvalidPath;
        lexical = try std.fs.path.resolve(allocator, &.{ base, raw_path });
    }
    defer allocator.free(lexical);

    // The lexically-resolved path must be free of `..`: resolve() collapses
    // them against real components, but if a guest crafts something resolve
    // leaves behind we refuse rather than pattern-match a traversal.
    var seg_it = std.mem.splitAny(u8, lexical, "\\/");
    while (seg_it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return error.InvalidPath;
    }

    if (std.fs.cwd().realpathAlloc(allocator, lexical)) |resolved| {
        defer allocator.free(resolved);
        return stripExtendedPrefix(allocator, resolved);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return error.InvalidPath,
    }

    // Nonexistent target: walk up to the deepest existing ancestor.
    var cur: []const u8 = lexical;
    while (true) {
        cur = std.fs.path.dirname(cur) orelse return error.InvalidPath;
        if (cur.len == 0) return error.InvalidPath;
        if (std.fs.cwd().realpathAlloc(allocator, cur)) |resolved| {
            defer allocator.free(resolved);
            const base = try stripExtendedPrefix(allocator, resolved);
            defer allocator.free(base);
            // Append the remainder of the lexically-resolved path. Both sides
            // share separators after resolve(); guard the join anyway.
            var remainder = lexical[cur.len..];
            while (remainder.len > 0 and (remainder[0] == '\\' or remainder[0] == '/')) remainder = remainder[1..];
            if (remainder.len == 0) return allocator.dupe(u8, base);
            return joinCanonical(allocator, base, remainder);
        } else |walk_err| switch (walk_err) {
            error.FileNotFound => continue,
            else => return error.InvalidPath,
        }
    }
}

/// Join ancestor + remainder, normalizing separators, refusing any leftover
/// `..` or `.` component (they cannot appear — remainder is post-resolve —
/// but this keeps the function independently safe).
fn joinCanonical(allocator: std.mem.Allocator, base: []const u8, remainder: []const u8) CanonicalizeError![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(base);
    if (out.items.len > 0 and out.items[out.items.len - 1] != '/' and out.items[out.items.len - 1] != '\\')
        try out.append(std.fs.path.sep);
    try out.appendSlice(remainder);
    for (out.items) |*c| {
        if (c.* == '/') c.* = std.fs.path.sep;
    }
    var it = std.mem.splitScalar(u8, out.items, std.fs.path.sep);
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return error.InvalidPath;
    }
    return out.toOwnedSlice();
}

/// Strip the extended-length prefixes Win32 prepends, so `\\?\D:\factory` can
/// ever equal the policy's `D:\factory`; `\\?\UNC\server\share` maps back to
/// plain UNC form.
fn stripExtendedPrefix(allocator: std.mem.Allocator, path: []const u8) CanonicalizeError![]u8 {
    if (std.mem.startsWith(u8, path, "\\\\?\\UNC\\")) {
        return std.fmt.allocPrint(allocator, "\\\\{s}", .{path["\\\\?\\UNC\\".len..]});
    }
    if (std.mem.startsWith(u8, path, "\\\\?\\")) {
        return allocator.dupe(u8, path["\\\\?\\".len..]);
    }
    return allocator.dupe(u8, path);
}

fn hasSchemePrefix(path: []const u8) bool {
    // scheme:// — scheme chars are ALPHA / DIGIT / + - .
    const idx = std.mem.indexOf(u8, path, "://") orelse return false;
    if (idx == 0) return false;
    for (path[0..idx]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

/// Up-front rejection of pathological inputs (spec §3.3.3 step 1):
///  - empty strings and embedded NUL/control characters,
///  - UNC device namespace `\\.\` and extended prefix typed by the guest
///    (`\\?\` lets a caller bypass our own normalization, e.g. ADS syntax),
///  - drive-relative paths (`D:` / `D:foo`) whose root is ambiguous,
///  - any colon outside position 1 (NTFS alternate data streams such as
///    `log.txt:secret` must never reach an open call),
///  - reserved DOS device name components (CON, NUL, COM1..9, LPT1..9, ...)
///    matched on the stem before any extension, case-insensitively.
fn validateRawPath(raw: []const u8) CanonicalizeError!void {
    if (raw.len == 0) return error.InvalidPath;
    for (raw) |c| {
        if (c == 0 or c < 0x20) return error.InvalidPath;
    }
    for ([_][]const u8{ "\\\\.\\", "//./", "\\\\?\\", "//?/" }) |prefix| {
        if (std.mem.startsWith(u8, raw, prefix)) return error.InvalidPath;
    }
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != ':') continue;
        if (i == 1 and raw.len > 1 and (raw[0] >= 'A' and raw[0] <= 'Z' or raw[0] >= 'a' and raw[0] <= 'z')) {
            // Drive designator — legal, but "D:" and "D:foo" (drive-relative)
            // stay ambiguous and are rejected outright.
            if (raw.len == 2) return error.InvalidPath;
            if (raw[2] != '\\' and raw[2] != '/') return error.InvalidPath;
            continue;
        }
        return error.InvalidPath;
    }
    var comp_it = std.mem.splitAny(u8, raw, "\\/");
    while (comp_it.next()) |component| {
        if (component.len == 0) continue;
        const stem_end = std.mem.indexOfScalar(u8, component, '.') orelse component.len;
        const stem = component[0..stem_end];
        if (isReservedDeviceName(stem)) return error.InvalidPath;
    }
}

fn isReservedDeviceName(stem: []const u8) bool {
    if (stem.len == 0) return false;
    const names = [_][]const u8{
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(stem, name)) return true;
    }
    return false;
}

// ----------------------------------------------------------------------
// Glob matching for fs patterns (`**` = any depth, `*` = within one segment)
// ----------------------------------------------------------------------

/// A pattern is valid when absolute, free of `..` components (a policy that
/// needs `..` is expressing something else than an allowlist), non-empty and
/// NUL-free. Relative patterns are refused at parse time already; this double
/// check protects direct users of the matcher.
pub fn validPattern(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    for (pattern) |c| {
        if (c == 0) return false;
    }
    var it = std.mem.splitAny(u8, pattern, "\\/");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return std.fs.path.isAbsolute(pattern) or std.fs.path.isAbsoluteWindows(pattern);
}

/// Match `path` against `pattern` honoring segment boundaries:
///   - `**` matches zero or more whole segments (any depth),
///   - `*` matches anything within a single segment (never crosses `/`),
///   - everything else compares literally (case-folded on Windows).
///
/// Because comparison happens segment-by-segment, `D:\\factory\\data\\**` does
/// NOT match `D:\\factory\\data-evil\\x` — the classic startsWith-prefix bug
/// (sci matchesPathPermissionPattern guards the same boundary at its
/// `normalized_abs_path[base.len] == '/'` check).
pub fn pathGlobMatch(allocator: std.mem.Allocator, pattern: []const u8, path: []const u8) error{OutOfMemory}!bool {
    const pat_n = try normalizeForMatch(allocator, pattern);
    defer allocator.free(pat_n);
    const path_n = try normalizeForMatch(allocator, path);
    defer allocator.free(path_n);
    return matchSegments(pat_n, path_n);
}

/// Backslash->slash, collapse duplicate separators, drop trailing separators
/// ("/" becomes "" and "D:/" becomes "D:" — both sides get the same transform
/// so equality is preserved), ASCII-fold when `case_insensitive_fs`.
fn normalizeForMatch(allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (path) |c_raw| {
        var c = c_raw;
        if (c == '\\') c = '/';
        if (case_insensitive_fs) c = std.ascii.toLower(c);
        if (c == '/' and out.items.len > 0 and out.items[out.items.len - 1] == '/') continue;
        try out.append(c);
    }
    while (out.items.len > 1 and out.items[out.items.len - 1] == '/')
        _ = out.pop();
    if (out.items.len == 1 and out.items[0] == '/') _ = out.pop();
    return out.toOwnedSlice();
}

fn matchSegments(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;

    const p_sep = std.mem.indexOfScalar(u8, pattern, '/') orelse pattern.len;
    const p_seg = pattern[0..p_sep];
    const p_rest = if (p_sep < pattern.len) pattern[p_sep + 1 ..] else "";

    if (std.mem.eql(u8, p_seg, "**")) {
        if (p_rest.len == 0) return true; // trailing ** absorbs the rest
        var rest = path;
        while (true) {
            if (matchSegments(p_rest, rest)) return true;
            const sep = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
            rest = rest[sep + 1 ..];
        }
    }

    if (path.len == 0) return false;
    const s_sep = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    const s_seg = path[0..s_sep];
    const s_rest = if (s_sep < path.len) path[s_sep + 1 ..] else "";

    if (!matchSegment(p_seg, s_seg)) return false;
    return matchSegments(p_rest, s_rest);
}

/// Single-segment wildcard match: `*` matches any (possibly empty) run inside
/// one segment; never crosses separators because callers split beforehand.
fn matchSegment(pattern: []const u8, s: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star: ?usize = null;
    var backtrack_si: usize = 0;
    while (si < s.len) {
        if (pi < pattern.len and (pattern[pi] == '*' or pattern[pi] == s[si])) {
            if (pattern[pi] == '*') {
                star = pi;
                backtrack_si = si;
                pi += 1;
                continue;
            }
            pi += 1;
            si += 1;
            continue;
        }
        if (star) |st| {
            pi = st + 1;
            backtrack_si += 1;
            si = backtrack_si;
            continue;
        }
        return false;
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

fn normalizedEql(allocator: std.mem.Allocator, a: []const u8, b: []const u8) error{OutOfMemory}!bool {
    const na = try normalizeForMatch(allocator, a);
    defer allocator.free(na);
    const nb = try normalizeForMatch(allocator, b);
    defer allocator.free(nb);
    return std.mem.eql(u8, na, nb);
}

// ----------------------------------------------------------------------
// HTTP internals
// ----------------------------------------------------------------------

fn normalizedUrlPath(allocator: std.mem.Allocator, uri: std.Uri) error{OutOfMemory}![]const u8 {
    const raw = uri.path.toRawMaybeAlloc(allocator) catch return error.OutOfMemory;
    if (raw.len == 0) return "";
    return trimTrailingSlash(raw);
}

fn trimTrailingSlash(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') : (end -= 1) {}
    if (end == 1 and path[0] == '/') return "";
    return path[0..end];
}

fn normalizeHost(allocator: std.mem.Allocator, component: std.Uri.Component) ![]const u8 {
    const raw = try component.toRawMaybeAlloc(allocator);
    // IPv6 literals arrive bracketed; store/compare bare.
    if (raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']') return raw[1 .. raw.len - 1];
    return raw;
}

/// Effective port with implied defaults (spec §3.3.4 / sci effectiveUriPort):
/// explicit port wins, else 443 for https and 80 for http.
fn effectivePort(uri: std.Uri) ?u16 {
    if (uri.port) |port| return port;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    return null;
}

fn rulePortsAllow(rule: HttpRule, eff_port: u16) bool {
    // No explicit port in the policy -> only the implied defaults 80/443 are
    // accepted; a pinned rule accepts exactly its own port.
    if (rule.port) |p| return eff_port == p;
    return eff_port == 80 or eff_port == 443;
}

fn ruleAllowsPath(allocator: std.mem.Allocator, rule: HttpRule, req_path: []const u8) error{OutOfMemory}!bool {
    if (rule.paths.len == 0) return true;
    const req_norm = trimTrailingSlash(req_path);
    for (rule.paths) |pat_raw| {
        const pat = try normalizeForMatch(allocator, pat_raw);
        defer allocator.free(pat);
        if (pat.len == 0) return true; // "/" in the policy means any path
        if (matchSegments(pat, req_norm)) return true;
    }
    return false;
}

pub fn isIpLiteral(host_lowercased_or_any: []const u8) bool {
    if (host_lowercased_or_any.len == 0) return false;
    if (std.net.Address.parseIp4(host_lowercased_or_any, 0)) |_| {
        return true;
    } else |_| {}
    if (mappedIpv4Part(host_lowercased_or_any) != null) return true;
    if (std.net.Address.parseIp6(host_lowercased_or_any, 0)) |_| {
        return true;
    } else |_| {}
    return false;
}

/// `::ffff:a.b.c.d` dotted tail — std's parseIp6 does not accept the
/// dotted-quad form, so extract and judge the embedded IPv4 ourselves.
fn mappedIpv4Part(host: []const u8) ?[4]u8 {
    if (!std.ascii.startsWithIgnoreCase(host, "::ffff:")) return null;
    const rest = host["::ffff:".len..];
    const addr = std.net.Address.parseIp4(rest, 0) catch return null;
    return @bitCast(addr.in.sa.addr);
}

/// SSRF deny list (spec §3.3.4 step 4): IPv4 loopback/RFC1918/link-local/
/// CGNAT/broadcast/this-network plus IPv6 ::1, fe80::/10, fc00::/7, ff00::/8
/// and IPv4-mapped ::ffff:0:0/96 (re-evaluated as embedded IPv4).
pub fn isPrivateIpLiteral(host: []const u8) bool {
    if (mappedIpv4Part(host)) |bytes| return privateIpv4(bytes);
    if (std.net.Address.parseIp4(host, 0)) |addr| {
        const bytes: [4]u8 = @bitCast(addr.in.sa.addr);
        return privateIpv4(bytes);
    } else |_| {}
    if (std.net.Address.parseIp6(host, 0)) |addr| {
        const bytes: [16]u8 = addr.in6.sa.addr;
        // IPv4-mapped in hex form (::ffff:7f00:1): judge embedded IPv4.
        if (std.mem.eql(u8, bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }))
            return privateIpv4(bytes[12..16].*);
        // ::1
        if (std.mem.allEqual(u8, bytes[0..15], 0) and bytes[15] == 1) return true;
        // fe80::/10 link-local
        if (bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0x80) return true;
        // fc00::/7 unique-local
        if ((bytes[0] & 0xfe) == 0xfc) return true;
        // ff00::/8 multicast
        if (bytes[0] == 0xff) return true;
        return false;
    } else |_| {}
    return false;
}

fn privateIpv4(b: [4]u8) bool {
    if (b[0] == 127) return true; // loopback 127/8
    if (b[0] == 10) return true; // RFC1918 10/8
    if (b[0] == 172 and (b[1] & 0xf0) == 16) return true; // 172.16/12
    if (b[0] == 192 and b[1] == 168) return true; // 192.168/16
    if (b[0] == 169 and b[1] == 254) return true; // link-local incl. metadata svc
    if (b[0] == 100 and (b[1] & 0xc0) == 64) return true; // CGNAT 100.64/10
    if (b[0] == 0) return true; // 0.0.0.0/8
    if (b[0] == 255 and b[1] == 255 and b[2] == 255 and b[3] == 255) return true;
    return false;
}

/// Classify a resolved socket address for the broker's connect-time check
/// (`deny_private_addresses`). Pure function so DNS-independent parts are
/// unit-testable without network access.
pub fn isDeniedPrivateAddress(address: std.net.Address) bool {
    switch (address.any.family) {
        std.posix.AF.INET => {
            const bytes: [4]u8 = @bitCast(address.in.sa.addr);
            return privateIpv4(bytes);
        },
        std.posix.AF.INET6 => {
            const bytes: [16]u8 = address.in6.sa.addr;
            if (std.mem.eql(u8, bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }))
                return privateIpv4(bytes[12..16].*);
            if (std.mem.allEqual(u8, bytes[0..15], 0) and bytes[15] == 1) return true;
            if (bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0x80) return true;
            if ((bytes[0] & 0xfe) == 0xfc) return true;
            if (bytes[0] == 0xff) return true;
            return false;
        },
        else => return true, // unfamiliar family: deny
    }
}

/// Render `host[:port]` from the original URL text so redirects keep the
/// authority (including explicit port) of their predecessor.
fn renderAuthority(allocator: std.mem.Allocator, url: []const u8, uri: std.Uri) ?[]u8 {
    const host_comp = uri.host orelse return null;
    // Both Component variants store slices into the originally-parsed text.
    const host_span = switch (host_comp) {
        .percent_encoded => |s| s,
        .raw => |s| s,
    };
    const start = host_span.ptr - url.ptr;
    var end = start + host_span.len;
    if (uri.port) |port| {
        // Extend across ":port" when it directly follows the host component.
        if (end < url.len and url[end] == ':') {
            var cursor = end + 1;
            while (cursor < url.len and std.ascii.isDigit(url[cursor])) : (cursor += 1) {}
            if (cursor > end + 1) end = cursor;
            _ = port;
        }
    }
    return allocator.dupe(u8, url[start..end]) catch null;
}

// ----------------------------------------------------------------------
// JSON schema walking (`sa.vm.policy/1`)
//
// Hand-rolled over std.json.Value so that *every* deviation from the schema
// (unknown key, wrong type, wrong schema string) is a hard parse error rather
// than a silently-ignored field: fail closed.
// ----------------------------------------------------------------------

fn jsonObject(value: std.json.Value) ParseError!std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => error.PolicyInvalid,
    };
}

fn jsonArray(value: std.json.Value) ParseError!std.json.Array {
    return switch (value) {
        .array => |arr| arr,
        else => error.PolicyInvalid,
    };
}

fn jsonString(value: std.json.Value) ParseError![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.PolicyInvalid,
    };
}

fn jsonBool(value: std.json.Value) ParseError!bool {
    return switch (value) {
        .bool => |b| b,
        else => error.PolicyInvalid,
    };
}

fn jsonUint(value: std.json.Value) ParseError!u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else error.PolicyInvalid,
        else => error.PolicyInvalid,
    };
}

/// Read an optional string-array field. Absent field -> empty slice (default
/// deny); present-but-wrong-typed field -> PolicyInvalid.
fn stringArrayField(
    alloc: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) ParseError![]const []const u8 {
    const value = obj.get(key) orelse return &.{};
    const arr = try jsonArray(value);
    const out = try alloc.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        out[i] = try jsonString(item);
        try validatePlainString(out[i]);
    }
    return out;
}

fn plainStringOk(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c == 0 or c < 0x20) return false;
    }
    return true;
}

fn validatePlainString(s: []const u8) ParseError!void {
    if (!plainStringOk(s)) return error.PolicyInvalid;
}

/// fs patterns must be absolute, `..`-free and well-formed; anything else is
/// refused at parse time so a typo can never widen access.
fn validateFsPattern(pattern: []const u8) ParseError!void {
    try validatePlainString(pattern);
    if (!validPattern(pattern)) return error.PolicyInvalid;
}

/// env / extern patterns are exact names or a single trailing `*`; any other
/// wildcard placement would be silently treated literally by the matcher, so
/// reject (fail closed).
fn validateTrailingStarPattern(pattern: []const u8) ParseError!void {
    try validatePlainString(pattern);
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return;
    if (star != pattern.len - 1) return error.PolicyInvalid;
}

fn validateEnvPattern(pattern: []const u8) ParseError!void {
    try validateTrailingStarPattern(pattern);
}

/// `extern.allow` entries follow the same shape as env patterns. Symbols are
/// matched byte-exactly (no case folding: C symbol names are case-sensitive),
/// so a typo here narrows access instead of widening it.
fn parseExternSection(alloc: std.mem.Allocator, value: std.json.Value, policy: *Policy) ParseError!void {
    const obj = try jsonObject(value);
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "allow")) return error.PolicyInvalid;
        policy.extern_allow = try stringArrayField(alloc, obj, "allow");
        for (policy.extern_allow) |pattern| try validateTrailingStarPattern(pattern);
    }
}

fn parseFsSection(alloc: std.mem.Allocator, value: std.json.Value, policy: *Policy) ParseError!void {
    const obj = try jsonObject(value);
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "read")) {
            policy.fs_read = try stringArrayField(alloc, obj, "read");
            for (policy.fs_read) |pattern| try validateFsPattern(pattern);
        } else if (std.mem.eql(u8, key, "write")) {
            policy.fs_write = try stringArrayField(alloc, obj, "write");
            for (policy.fs_write) |pattern| try validateFsPattern(pattern);
        } else {
            return error.PolicyInvalid;
        }
    }
}

fn parseHttpSection(alloc: std.mem.Allocator, value: std.json.Value, policy: *Policy) ParseError!void {
    const obj = try jsonObject(value);
    var rules: []const HttpRule = &.{};
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const field = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "allow")) {
            const arr = try jsonArray(field);
            const parsed_rules = try alloc.alloc(HttpRule, arr.items.len);
            for (arr.items, 0..) |item, i| {
                parsed_rules[i] = try parseHttpRule(alloc, item);
            }
            rules = parsed_rules;
        } else if (std.mem.eql(u8, key, "max_redirects")) {
            const n = try jsonUint(field);
            if (n > std.math.maxInt(u32)) return error.PolicyInvalid;
            policy.http_max_redirects = @intCast(n);
        } else if (std.mem.eql(u8, key, "deny_private_addresses")) {
            policy.deny_private_addresses = try jsonBool(field);
        } else {
            return error.PolicyInvalid;
        }
    }
    policy.http_rules = rules;
}

fn parseHttpRule(alloc: std.mem.Allocator, value: std.json.Value) ParseError!HttpRule {
    const obj = try jsonObject(value);
    var rule = HttpRule{ .host = undefined };

    const host_value = obj.get("host") orelse return error.PolicyInvalid;
    rule.host = try jsonString(host_value);
    try validatePlainString(rule.host);
    if (rule.host.len >= 2 and rule.host[0] == '[' and rule.host[rule.host.len - 1] == ']')
        rule.host = rule.host[1 .. rule.host.len - 1];

    if (obj.get("methods")) |methods_value| {
        const arr = try jsonArray(methods_value);
        for (arr.items) |item| {
            const name = try jsonString(item);
            const method = parseMethod(name) orelse return error.PolicyInvalid;
            rule.methods_mask |= methodBit(method);
        }
    }
    rule.paths = try stringArrayField(alloc, obj, "paths");
    for (rule.paths) |path_pattern| {
        if (path_pattern.len == 0 or path_pattern[0] != '/') return error.PolicyInvalid;
    }
    if (obj.get("port")) |port_value| {
        const n = try jsonUint(port_value);
        if (n == 0 or n > std.math.maxInt(u16)) return error.PolicyInvalid;
        rule.port = @intCast(n);
    }

    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "host") and !std.mem.eql(u8, key, "methods") and
            !std.mem.eql(u8, key, "paths") and !std.mem.eql(u8, key, "port"))
        {
            return error.PolicyInvalid;
        }
    }
    return rule;
}


fn parseProcessSection(alloc: std.mem.Allocator, value: std.json.Value, policy: *Policy) ParseError!void {
    const obj = try jsonObject(value);
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const field = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "spawn")) {
            policy.process_spawn = try jsonBool(field);
        } else if (std.mem.eql(u8, key, "exec")) {
            const arr = try jsonArray(field);
            const rules = try alloc.alloc(ProcessExecRule, arr.items.len);
            for (arr.items, 0..) |item, i| {
                const exec_obj = try jsonObject(item);
                const path_value = exec_obj.get("path") orelse return error.PolicyInvalid;
                rules[i] = .{
                    .path = try jsonString(path_value),
                    .args = try stringArrayField(alloc, exec_obj, "args"),
                };
                try validatePlainString(rules[i].path);
                var exec_it = exec_obj.iterator();
                while (exec_it.next()) |exec_entry| {
                    const exec_key = exec_entry.key_ptr.*;
                    if (!std.mem.eql(u8, exec_key, "path") and !std.mem.eql(u8, exec_key, "args"))
                        return error.PolicyInvalid;
                }
            }
            policy.process_exec = rules;
        } else {
            return error.PolicyInvalid;
        }
    }
}

fn parseLimitsSection(value: std.json.Value, policy: *Policy) ParseError!void {
    const obj = try jsonObject(value);
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const field = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "fuel")) {
            policy.limits.fuel = try jsonUint(field);
        } else if (std.mem.eql(u8, key, "wall_clock_ms")) {
            policy.limits.wall_clock_ms = try jsonUint(field);
        } else if (std.mem.eql(u8, key, "mem_cap_bytes")) {
            policy.limits.mem_cap_bytes = try jsonUint(field);
        } else {
            return error.PolicyInvalid;
        }
    }
}

// ----------------------------------------------------------------------
// `--sandboxed` shorthand (minimal default-deny run profile)
// ----------------------------------------------------------------------

/// The policy implied by `sa vm run --sandboxed`: no filesystem, no network,
/// no environment, no processes, no FFI, no threads and NO extern symbols
/// beyond the interpreter-internal formatting/printing surface. Resource caps
/// are defaulted rather than unlimited so an untrusted program can never run
/// without *some* bound; explicit --fuel/--deadline-ms/--mem-cap-bytes flags
/// override these values (documented flag-wins semantics).
///
/// Parsed through the ordinary `parse` path so the profile can never drift
/// out of sync with schema validation.
pub const sandboxed_policy_json =
    \\{
    \\  "schema": "sa.vm.policy/1",
    \\  "extern": { "allow": ["sa_print_bytes", "sa_fmt_*"] },
    \\  "fs": { "read": [], "write": [] },
    \\  "http": { "allow": [] },
    \\  "env": { "allow": [] },
    \\  "process": { "spawn": false, "exec": [] },
    \\  "net_raw": false,
    \\  "ffi": false,
    \\  "threads": false,
    \\  "limits": { "fuel": 1000000000, "wall_clock_ms": 10000, "mem_cap_bytes": 268435456 }
    \\}
;

pub fn parseSandboxed(allocator: std.mem.Allocator) ParseError!Policy {
    return Policy.parse(allocator, sandboxed_policy_json);
}
