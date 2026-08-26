//! Layer-2 semantic classification of extern symbol names for the VM sandbox.
//!
//! Guest code performs I/O exclusively by calling extern functions. Layer 1
//! (policy `extern.allow`) decides WHETHER a symbol may be called at all;
//! THIS module decides what the call's ARGUMENTS mean so the policy engine can
//! check the actual I/O target (`policy.checkFs`, `checkHttp`, `checkEnv`,
//! `checkProcessSpawn`, `checkNetRaw`).
//!
//! The table below is THE single source of truth for that mapping. Adding an
//! entry is one line: `{ .pattern = "sa_fs_...", .kind = .fs_read,
//! .spec = .{ .path = 0, .path_len = 1 } }`. Argument indices are positions in
//! the guest call's argument vector (0-based), taken from the contracts in
//! `sci/sa_std/*.sai` and the sibling plugins' `.sai` files.
//!
//! Matching rules:
//!   * a pattern is an exact symbol name, or a name ending in a single `*`
//!     (prefix match),
//!   * when several patterns match, the LONGEST one wins, so a specific entry
//!     can never be shadowed by a general family rule regardless of order,
//!   * a symbol with no matching entry classifies as `.none`: it still has to
//!     be allowlisted by name (Layer 1), and its arguments are then trusted to
//!     the operator who listed it — that is the documented contract.
//!
//! Everything here is pure: no allocator, no OS access, no imports from
//! vm.zig/plugin.zig, so it is unit-testable in isolation.

const std = @import("std");

/// What kind of capability a symbol's arguments carry.
pub const Kind = enum {
    /// Allowlisted by name only; no argument semantics are known.
    none,
    /// First path argument is read from disk.
    fs_read,
    /// First path argument is created/modified/removed.
    fs_write,
    /// Two paths: source is read, destination is written (copy/rename/link).
    fs_transfer,
    /// A URL (+ optional method) is fetched.
    http_request,
    /// Reads an environment variable by name.
    env_get,
    /// Sets/removes an environment variable by name.
    env_set,
    /// Spawns/runs/captures a child process; argv travels as a JSON string.
    process_spawn,
    /// Raw socket surface (TCP/UDP/Unix), no URL semantics.
    net_raw,
};

/// Which argument slots hold the I/O target for one table entry.
pub const Spec = struct {
    /// Arg index holding the primary path pointer.
    path: ?u8 = null,
    /// Arg index holding its byte length; null => NUL-terminated string.
    path_len: ?u8 = null,
    /// Second path (destination of copy/rename, link/target of symlink).
    path2: ?u8 = null,
    path2_len: ?u8 = null,
    url: ?u8 = null,
    url_len: ?u8 = null,
    /// Method as a length-prefixed string ("GET", ...).
    method_str: ?u8 = null,
    method_str_len: ?u8 = null,
    /// Method as an integer enum (sa_plugin_http_client HttpMethod:
    /// 1=GET 2=POST 3=PUT 4=DELETE — see methodNameFromEnum).
    method_enum: ?u8 = null,
    /// Env var name / argv JSON blob pointer + length.
    name: ?u8 = null,
    name_len: ?u8 = null,
    /// Fixed literal checked instead of an argument (e.g. "*").
    name_literal: ?[]const u8 = null,
};

pub const Entry = struct {
    pattern: []const u8,
    kind: Kind,
    spec: Spec = .{},
};

/// Symbol -> capability map. Sources for signatures: `sci/sa_std/fs.sai`,
/// `env.sai`, `process.sai`, `http2.sai`, `io.sai` and
/// `sa_plugin_http_client/sa_http_client.sai`.
///
/// Deliberately conservative choices, each documented inline:
///   * openers whose mode flag is not decoded (`sa_fs_file_open`,
///     `sa_std_fs_open_options`) require WRITE permission — fail closed;
///   * multi-path operations require read on the source AND write on the
///     destination;
///   * `sa_env_set_current_dir` is treated as a write against the target
///     directory: chdir would otherwise re-anchor relative paths behind the
///     policy's back.
pub const entries = [_]Entry{
    // --- filesystem: reads -------------------------------------------------
    .{ .pattern = "sa_fs_read_file", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_read_to_string", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_read_file_base64", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_read_dir_json", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_read_dir_entries", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_metadata", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },

    // sa_std_* mirror family (sci/sa_std/fs.sai second block).
    .{ .pattern = "sa_std_fs_read_file", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_std_fs_read_to_string", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_std_fs_read_file_base64", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_std_fs_read_dir_json", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_std_fs_read_dir_entries", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_std_fs_exists", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_std_fs_try_exists", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_std_fs_len", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_std_fs_metadata", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_std_fs_metadata_json", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_std_fs_canonicalize", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_std_fs_read_link", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_std_fs_open_read", .kind = .fs_read, .spec = .{ .path = 0, .path_len = 1 } },

    // Legacy VM shim (src/ffi.zig): fd_open(path) takes no mode flags, so it
    // is classified as a read; granting it means "may probe this path".
    .{ .pattern = "fd_open", .kind = .fs_read, .spec = .{ .path = 0 } },

    // --- filesystem: writes ------------------------------------------------
    .{ .pattern = "sa_fs_write_file", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_write_file_base64", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_file_create", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    // Mode flags ignored => require write (fail closed).
    .{ .pattern = "sa_fs_file_open", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_create_dir", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_make_dir", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_remove_file", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_remove_path", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_remove_dir", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_remove_dir_all", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_chown", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_lchown", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_chroot", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_mkfifo", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_set_permissions", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_fs_set_times_ms", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },

    .{ .pattern = "sa_std_fs_open_write", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    // Mode flags ignored => require write (fail closed).
    .{ .pattern = "sa_std_fs_open_options", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },
    .{ .pattern = "sa_std_fs_remove", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },

    // chdir re-anchors relative paths: gate it as a write on the target dir.
    .{ .pattern = "sa_env_set_current_dir", .kind = .fs_write, .spec = .{ .path = 0, .path_len = 1 } },

    // --- filesystem: two-path transfers ------------------------------------
    .{ .pattern = "sa_fs_copy_file", .kind = .fs_transfer, .spec = .{ .path = 0, .path_len = 1, .path2 = 2, .path2_len = 3 } },
    .{ .pattern = "sa_fs_rename", .kind = .fs_transfer, .spec = .{ .path = 0, .path_len = 1, .path2 = 2, .path2_len = 3 } },
    .{ .pattern = "sa_fs_hard_link", .kind = .fs_transfer, .spec = .{ .path = 0, .path_len = 1, .path2 = 2, .path2_len = 3 } },
    .{ .pattern = "sa_fs_symlink", .kind = .fs_transfer, .spec = .{ .path = 0, .path_len = 1, .path2 = 2, .path2_len = 3 } },

    // --- HTTP --------------------------------------------------------------
    // sa_plugin_http_client: (client, method: u8 enum, &url, url_len, &out)
    .{ .pattern = "sa_http_client_req_new_v2", .kind = .http_request, .spec = .{ .url = 2, .url_len = 3, .method_enum = 1 } },
    .{ .pattern = "sa_http_client_req_new_joined", .kind = .http_request, .spec = .{ .url = 2, .url_len = 3, .method_enum = 1 } },
    .{ .pattern = "sa_http_client_req_new", .kind = .http_request, .spec = .{ .url = 2, .url_len = 3, .method_enum = 1 } },
    // sa_std http2: (&url, url_len, &method, method_len, &body, body_len, &out)
    .{ .pattern = "sa_std_http2_client_request", .kind = .http_request, .spec = .{ .url = 0, .url_len = 1, .method_str = 2, .method_str_len = 3 } },

    // --- environment -------------------------------------------------------
    .{ .pattern = "sa_env_get", .kind = .env_get, .spec = .{ .name = 0, .name_len = 1 } },
    .{ .pattern = "sa_env_has", .kind = .env_get, .spec = .{ .name = 0, .name_len = 1 } },
    // Dumps every variable: only grantable by explicitly allowlisting "*".
    .{ .pattern = "sa_env_vars_json", .kind = .env_get, .spec = .{ .name_literal = "*" } },
    .{ .pattern = "sa_env_set_var", .kind = .env_set, .spec = .{ .name = 0, .name_len = 1 } },
    .{ .pattern = "sa_env_remove_var", .kind = .env_set, .spec = .{ .name = 0, .name_len = 1 } },

    // --- processes (argv travels as a JSON array-of-strings blob) ----------
    // Every spawn/run/capture variant in sci/sa_std/process.sai carries argv
    // first (&argv, argv_len), including the _cwd/_command_ext_* forms.
    .{ .pattern = "sa_std_process_spawn*", .kind = .process_spawn, .spec = .{ .name = 0, .name_len = 1 } },
    .{ .pattern = "sa_std_process_run*", .kind = .process_spawn, .spec = .{ .name = 0, .name_len = 1 } },
    .{ .pattern = "sa_std_process_exec_capture*", .kind = .process_spawn, .spec = .{ .name = 0, .name_len = 1 } },
};

pub const Classification = struct {
    kind: Kind,
    spec: Spec,
    /// The pattern that matched (for diagnostics/tests).
    pattern: []const u8,
};

/// Exact or single-trailing-`*` prefix match (same shape as the policy's
/// extern/env allowlist matchers).
pub fn matchesPattern(pattern: []const u8, symbol: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "*")) {
        return std.mem.startsWith(u8, symbol, pattern[0 .. pattern.len - 1]);
    }
    return std.mem.eql(u8, pattern, symbol);
}

/// Longest-matching-pattern-wins lookup. The table is small (~50 entries) and
/// only consulted for I/O-class calls, so linear scan is fine.
pub fn classify(symbol: []const u8) Classification {
    var best: ?*const Entry = null;
    for (&entries) |*entry| {
        if (!matchesPattern(entry.pattern, symbol)) continue;
        if (best == null or entry.pattern.len > best.?.pattern.len) best = entry;
    }
    const entry = best orelse return .{ .kind = .none, .spec = .{}, .pattern = "" };
    return .{ .kind = entry.kind, .spec = entry.spec, .pattern = entry.pattern };
}

/// True for the raw socket families (`sa_net_*`, `sa_std_net_*`). These have
/// per-address rather than per-URL semantics; the policy gates them wholesale
/// through `net_raw`.
pub fn isNetRawFamily(symbol: []const u8) bool {
    return std.mem.startsWith(u8, symbol, "sa_net_") or std.mem.startsWith(u8, symbol, "sa_std_net_");
}

/// Map the `method: u8` argument of sa_plugin_http_client's request builders
/// (HttpMethod enum: get=1 post=2 put=3 delete=4) onto a policy method name.
/// Unknown codes return null so the caller denies instead of guessing.
pub fn methodNameFromEnum(code: u64) ?[]const u8 {
    return switch (code) {
        1 => "GET",
        2 => "POST",
        3 => "PUT",
        4 => "DELETE",
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "classify routes known file/http/env/process symbols" {
    const fs_read = classify("sa_fs_read_file");
    try testing.expectEqual(Kind.fs_read, fs_read.kind);
    try testing.expectEqual(@as(u8, 0), fs_read.spec.path.?);
    try testing.expectEqual(@as(u8, 1), fs_read.spec.path_len.?);

    try testing.expectEqual(Kind.fs_write, classify("sa_fs_write_file").kind);
    try testing.expectEqual(Kind.fs_write, classify("sa_std_fs_open_options").kind);
    try testing.expectEqual(Kind.fs_read, classify("fd_open").kind);

    const transfer = classify("sa_fs_copy_file");
    try testing.expectEqual(Kind.fs_transfer, transfer.kind);
    try testing.expectEqual(@as(u8, 2), transfer.spec.path2.?);

    const http = classify("sa_http_client_req_new");
    try testing.expectEqual(Kind.http_request, http.kind);
    try testing.expectEqual(@as(u8, 1), http.spec.method_enum.?);

    const http2 = classify("sa_std_http2_client_request");
    try testing.expectEqual(Kind.http_request, http2.kind);
    try testing.expectEqual(@as(u8, 2), http2.spec.method_str.?);

    try testing.expectEqual(Kind.env_get, classify("sa_env_get").kind);
    try testing.expectEqual(Kind.env_set, classify("sa_env_remove_var").kind);
    try testing.expectEqual(Kind.process_spawn, classify("sa_std_process_run").kind);
    try testing.expectEqual(Kind.process_spawn, classify("sa_std_process_spawn_cwd").kind);
    try testing.expectEqual(Kind.process_spawn, classify("sa_std_process_run_command_ext_uid_gid").kind);
}

test "longest matching pattern wins regardless of table order" {
    // Both "sa_std_process_spawn*" style specifics and the plain form exist;
    // argv sits at args 0..1 in every case, but the specific entry must win.
    const joined = classify("sa_http_client_req_new_joined");
    try testing.expectEqualStrings("sa_http_client_req_new_joined", joined.pattern);

    const plain = classify("sa_http_client_req_new");
    try testing.expectEqualStrings("sa_http_client_req_new", plain.pattern);

    // Unknown symbols classify as none.
    try testing.expectEqual(Kind.none, classify("sa_fmt_i64_into").kind);
    try testing.expectEqual(Kind.none, classify("totally_unknown_fn").kind);
}

test "net raw family detection covers both prefixes only" {
    try testing.expect(isNetRawFamily("sa_net_tcp_connect"));
    try testing.expect(isNetRawFamily("sa_std_net_udp_bind"));
    try testing.expect(!isNetRawFamily("sa_std_http2_client_request"));
    try testing.expect(!isNetRawFamily("sa_env_get"));
}

test "http method enum decodes exactly the documented codes" {
    try testing.expectEqualStrings("GET", methodNameFromEnum(1).?);
    try testing.expectEqualStrings("POST", methodNameFromEnum(2).?);
    try testing.expectEqualStrings("PUT", methodNameFromEnum(3).?);
    try testing.expectEqualStrings("DELETE", methodNameFromEnum(4).?);
    try testing.expect(methodNameFromEnum(0) == null);
    try testing.expect(methodNameFromEnum(5) == null);
}
