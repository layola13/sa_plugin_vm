//! Unit tests for the capability I/O policy engine (src/policy.zig).
//!
//! Run via `zig build test` (registered in build.zig as its own test target).

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const policy_mod = @import("policy.zig");
const Policy = policy_mod.Policy;
const Verdict = policy_mod.Verdict;

// ----------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------

fn parsePolicy(text: []const u8) !Policy {
    return Policy.parse(testing.allocator, text);
}

fn expectAllow(verdict: Verdict) !void {
    if (verdict != .allow) {
        std.debug.print("expected allow, got deny reason={s}\n", .{verdict.deny.reason.label()});
        return error.TestUnexpectedResult;
    }
}

fn expectDeny(verdict: Verdict, reason: policy_mod.DenyReason) !void {
    if (verdict != .deny) {
        std.debug.print("expected deny({s}), got allow\n", .{reason.label()});
        return error.TestUnexpectedResult;
    }
    if (verdict.deny.reason != reason) {
        std.debug.print("expected deny({s}), got deny({s})\n", .{ reason.label(), verdict.deny.reason.label() });
        return error.TestUnexpectedResult;
    }
}

/// Canonicalized tmp-dir root: patterns and requested paths are both derived
/// from it so Windows `\\?\` prefix handling cannot skew comparisons.
const TestRoot = struct {
    tmp: testing.TmpDir,
    canon_root: []u8,
    alloc_buf: bool,

    fn init() !TestRoot {
        var self = TestRoot{
            .tmp = undefined,
            .canon_root = undefined,
            .alloc_buf = false,
        };
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const raw = try self.tmp.dir.realpathAlloc(testing.allocator, ".");
        defer testing.allocator.free(raw);
        self.canon_root = try canonicalizeForTest(raw);
        self.alloc_buf = true;
        return self;
    }

    fn deinit(self: *TestRoot) void {
        if (self.alloc_buf) testing.allocator.free(self.canon_root);
        self.tmp.cleanup();
    }

    /// Absolute path inside the test root from slash-separated components.
    fn join(self: *const TestRoot, components: []const []const u8) ![]u8 {
        var buf = std.ArrayList(u8).init(testing.allocator);
        errdefer buf.deinit();
        try buf.appendSlice(self.canon_root);
        for (components) |component| {
            try buf.append(std.fs.path.sep);
            try buf.appendSlice(component);
        }
        return buf.toOwnedSlice();
    }

    fn patternAll(self: *const TestRoot) ![]u8 {
        const slashed = try jsonPath(testing.allocator, self.canon_root);
        defer testing.allocator.free(slashed);
        return std.fmt.allocPrint(testing.allocator, "{s}/**", .{slashed});
    }
};

fn canonicalizeForTest(raw: []const u8) ![]u8 {
    // Route through the module's own canonicalizer so prefixes/case agree.
    return policy_mod.canonicalizePath(testing.allocator, null, raw) catch |err| switch (err) {
        error.InvalidPath => error.TestUnexpectedResult,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Windows temp paths contain backslashes, which are invalid inside JSON
/// string literals; policy patterns therefore get the forward-slash form (the
/// matcher normalizes separators before comparing).
fn jsonPath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

// Patterns use forward slashes so the raw Windows temp path can be spliced in
// without JSON-escaping; the matcher normalizes separators before comparing.
const fs_json_fmt =
    \\{{
    \\  "schema": "sa.vm.policy/1",
    \\  "fs": {{ "read": ["{s}/**"], "write": ["{s}/out/**"] }}
    \\}}
;

// ----------------------------------------------------------------------
// Glob matching
// ----------------------------------------------------------------------

test "fs glob doublestar matches any depth and the base itself" {
    const a = testing.allocator;
    const cases = [_]struct { path: []const u8, want: bool }{
        .{ .path = "D:\\factory", .want = true }, // ** matches zero segments
        .{ .path = "D:\\factory\\a.txt", .want = true },
        .{ .path = "D:\\factory\\a\\b\\c.txt", .want = true },
        .{ .path = "D:\\factory_other\\a.txt", .want = false }, // no prefix bleed
        .{ .path = "D:\\factory2\\x", .want = false },
        .{ .path = "E:\\factory\\a.txt", .want = false },
        .{ .path = "D:\\fac", .want = false },
    };
    for (cases) |case| {
        const got = try policy_mod.pathGlobMatch(a, "D:\\factory\\**", case.path);
        try testing.expectEqual(case.want, got);
    }
}

test "fs glob star is confined to one segment" {
    const a = testing.allocator;
    try testing.expect(try policy_mod.pathGlobMatch(a, "D:\\data\\*.txt", "D:\\data\\report.txt"));
    try testing.expect(!try policy_mod.pathGlobMatch(a, "D:\\data\\*.txt", "D:\\data\\sub\\report.txt"));
    try testing.expect(!try policy_mod.pathGlobMatch(a, "D:\\data\\*.txt", "D:\\data\\report.txt.bak"));

    // '*' spanning a whole directory level
    try testing.expect(try policy_mod.pathGlobMatch(a, "D:\\logs\\*\\run.log", "D:\\logs\\2026-08\\run.log"));
    try testing.expect(!try policy_mod.pathGlobMatch(a, "D:\\logs\\*\\run.log", "D:\\logs\\2026-08\\deep\\run.log"));

    // '**' in the middle matches zero or more segments
    try testing.expect(try policy_mod.pathGlobMatch(a, "D:\\data\\**\\tmp\\x.txt", "D:\\data\\tmp\\x.txt"));
    try testing.expect(try policy_mod.pathGlobMatch(a, "D:\\data\\**\\tmp\\x.txt", "D:\\data\\a\\b\\tmp\\x.txt"));
    try testing.expect(!try policy_mod.pathGlobMatch(a, "D:\\data\\**\\tmp\\x.txt", "D:\\data\\tmp\\y.txt"));
}

test "fs glob respects segment boundaries against prefix confusion" {
    const a = testing.allocator;
    // The classic startsWith bug: D:\factory\data must never admit
    // D:\factory\data-evil or D:\factory\database\...
    try testing.expect(!try policy_mod.pathGlobMatch(a, "D:\\factory\\data\\**", "D:\\factory\\data-evil\\steal.txt"));
    try testing.expect(!try policy_mod.pathGlobMatch(a, "D:\\factory\\data\\**", "D:\\factory\\database\\db.sqlite"));
    try testing.expect(!try policy_mod.pathGlobMatch(a, "D:\\factory\\data", "D:\\factory\\data-old"));
    // ...while the true siblings still match / do not match correctly.
    try testing.expect(try policy_mod.pathGlobMatch(a, "D:\\factory\\data\\**", "D:\\factory\\data\\real.txt"));
    try testing.expect(!try policy_mod.pathGlobMatch(a, "D:\\secrets\\key.pem", "D:\\secrets\\key.pem2"));
    try testing.expect(try policy_mod.pathGlobMatch(a, "D:\\secrets\\key.pem", "D:\\secrets\\key.pem"));
}

test "windows glob matching folds ASCII case and separators" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    try testing.expect(try policy_mod.pathGlobMatch(a, "d:/factory/data/**", "D:\\FACTORY\\DATA\\item.TXT"));
    try testing.expect(try policy_mod.pathGlobMatch(a, "D:\\Factory\\Data\\**", "d:\\factory\\data\\item.txt"));
}

test "posix glob matching stays case-sensitive" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    try testing.expect(!try policy_mod.pathGlobMatch(a, "/factory/data/**", "/FACTORY/DATA/item.txt"));
    try testing.expect(try policy_mod.pathGlobMatch(a, "/factory/data/**", "/factory/data/item.txt"));
}

// ----------------------------------------------------------------------
// Path canonicalization
// ----------------------------------------------------------------------

test "canonicalize rejects pathological guest inputs" {
    const a = testing.allocator;
    const bad = [_][]const u8{
        "", // empty
        "C:\\x\x00y", // embedded NUL
        "\x01C:\\x", // control character
        "D:", // bare drive
        "D:reports\\out.txt", // drive-relative (ambiguous root)
        "C:\\logs\\file.txt:hidden", // NTFS alternate data stream
        "C:\\logs\\f:t.txt",
        "\\\\.\\pipe\\evil", // device namespace
        "//./pipe/evil",
        "\\\\?\\C:\\Windows\\system32\\config.sys", // extended prefix typed by guest
        "//?/C:/x",
        "CON", // reserved DOS device names (any case, with/without extension)
        "con",
        "Nul.txt",
        "C:\\dir\\COM1",
        "C:\\dir\\lpt9.log",
        "aux.csv",
        "relative\\path.txt", // relative without base_dir
    };
    for (bad) |input| {
        const result = policy_mod.canonicalizePath(a, null, input);
        try testing.expectError(error.InvalidPath, result);
    }
}

test "canonicalize resolves existing files through realpath" {
    var root = try TestRoot.init();
    defer root.deinit();
    try root.tmp.dir.makePath("sub");
    try root.tmp.dir.writeFile(.{ .sub_path = "sub/item.txt", .data = "hello" });

    const requested = try root.join(&.{ "sub", "ITEM.TXT" });
    defer testing.allocator.free(requested);

    const canon = try policy_mod.canonicalizePath(testing.allocator, null, requested);
    defer testing.allocator.free(canon);

    // No extended prefix may survive; the file must really exist at that name.
    try testing.expect(!std.mem.startsWith(u8, canon, "\\\\?\\"));
    const f = std.fs.cwd().openFile(canon, .{}) catch |err| {
        std.debug.print("openFile({s}) failed: {}\n", .{ canon, err });
        return err;
    };
    defer f.close();
}

test "canonicalize appends remainder lexically for missing write targets" {
    var root = try TestRoot.init();
    defer root.deinit();
    // Only the root exists; a\b\c.txt does not.
    const requested = try root.join(&.{ "a", "b", "c.txt" });
    defer testing.allocator.free(requested);

    const canon = try policy_mod.canonicalizePath(testing.allocator, null, requested);
    defer testing.allocator.free(canon);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\\a\\b\\c.txt", .{root.canon_root});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, canon);
}

test "canonicalize collapses dot-dot before matching so traversal lands outside allowlist" {
    var root = try TestRoot.init();
    defer root.deinit();

    const read_all = try root.patternAll();
    defer testing.allocator.free(read_all);
    const write_slashed = try jsonPath(testing.allocator, root.canon_root);
    defer testing.allocator.free(write_slashed);
    const json = try std.fmt.allocPrint(testing.allocator, fs_json_fmt, .{ read_all, write_slashed });
    defer testing.allocator.free(json);
    var policy = try parsePolicy(json);
    defer policy.deinit();

    // .. climbs out of the sandbox root: canonicalizes to a sibling of the
    // temp dir, which the allowlist does not cover -> deny (not an error, not
    // an accidental allow).
    const escape = try std.fmt.allocPrint(testing.allocator, "{s}\\..\\..\\secret.txt", .{root.canon_root});
    defer testing.allocator.free(escape);
    const verdict = try policy.checkFsRead(testing.allocator, escape, null);
    try expectDeny(verdict, .fs_not_allowed);

    // .. that resolves back INSIDE the sandbox stays allowed.
    const internal = try std.fmt.allocPrint(testing.allocator, "{s}\\sub\\..\\keep.txt", .{root.canon_root});
    defer testing.allocator.free(internal);
    try expectAllow(try policy.checkFsRead(testing.allocator, internal, null));

    // .. inside a nonexistent write target resolves away before the ancestor
    // walk, so it can never smuggle a component past the matcher.
    const sneaky = try std.fmt.allocPrint(testing.allocator, "{s}\\out\\..\\evil.txt", .{root.canon_root});
    defer testing.allocator.free(sneaky);
    try expectDeny(try policy.checkFsWrite(testing.allocator, sneaky, null), .fs_not_allowed);
}

test "checkFs enforces per-op allowlists on real directories" {
    var root = try TestRoot.init();
    defer root.deinit();
    try root.tmp.dir.makePath("out");

    const read_all = try root.patternAll();
    defer testing.allocator.free(read_all);
    const write_slashed = try jsonPath(testing.allocator, root.canon_root);
    defer testing.allocator.free(write_slashed);
    const json = try std.fmt.allocPrint(testing.allocator, fs_json_fmt, .{ read_all, write_slashed });
    defer testing.allocator.free(json);
    var policy = try parsePolicy(json);
    defer policy.deinit();

    // Reading an existing file inside the tree: allowed.
    try root.tmp.dir.writeFile(.{ .sub_path = "input.bin", .data = "x" });
    const input = try root.join(&.{"input.bin"});
    defer testing.allocator.free(input);
    try expectAllow(try policy.checkFsRead(testing.allocator, input, null));

    // Writing anywhere except <root>\out\**: denied.
    try expectDeny(try policy.checkFsWrite(testing.allocator, input, null), .fs_not_allowed);

    // Writing the not-yet-existing report under out\: allowed (partial
    // canonicalization of the deepest existing ancestor).
    const report = try root.join(&.{ "out", "report.txt" });
    defer testing.allocator.free(report);
    try expectAllow(try policy.checkFsWrite(testing.allocator, report, null));

    // Writing into a sibling directory of out\ whose name merely shares a
    // prefix: denied (segment boundary respected end-to-end).
    const evil_out = try root.join(&.{"out-evil"});
    defer testing.allocator.free(evil_out);
    try expectDeny(try policy.checkFsWrite(testing.allocator, evil_out, null), .fs_not_allowed);

    // Reading when only write is granted elsewhere: denied.
    const wo_slashed = try jsonPath(testing.allocator, root.canon_root);
    defer testing.allocator.free(wo_slashed);
    const json_write_only = try std.fmt.allocPrint(
        testing.allocator,
        "{{ \"fs\": {{ \"write\": [\"{s}/**\"] }} }}",
        .{wo_slashed},
    );
    defer testing.allocator.free(json_write_only);
    var policy_wo = try parsePolicy(json_write_only);
    defer policy_wo.deinit();
    try expectDeny(try policy_wo.checkFsRead(testing.allocator, input, null), .fs_not_allowed);
}

test "checkFs reports invalid paths as denials instead of errors" {
    var root = try TestRoot.init();
    defer root.deinit();
    const read_all = try root.patternAll();
    defer testing.allocator.free(read_all);
    const write_slashed = try jsonPath(testing.allocator, root.canon_root);
    defer testing.allocator.free(write_slashed);
    const json = try std.fmt.allocPrint(testing.allocator, fs_json_fmt, .{ read_all, write_slashed });
    defer testing.allocator.free(json);
    var policy = try parsePolicy(json);
    defer policy.deinit();

    try expectDeny(try policy.checkFsRead(testing.allocator, "C:\\x:fds", null), .fs_path_invalid);
    try expectDeny(try policy.checkFsRead(testing.allocator, "relative.txt", null), .fs_path_invalid);
}

test "checkFs resolves guest-relative paths against the broker base dir" {
    var root = try TestRoot.init();
    defer root.deinit();
    const slashed = try jsonPath(testing.allocator, root.canon_root);
    defer testing.allocator.free(slashed);
    const json = try std.fmt.allocPrint(testing.allocator, fs_json_fmt, .{ slashed, slashed });
    defer testing.allocator.free(json);
    var policy = try parsePolicy(json);
    defer policy.deinit();

    try expectAllow(try policy.checkFsRead(testing.allocator, "sub\\dir\\file.txt", root.canon_root));
    // Relative escape attempts still resolve to real absolute paths first.
    try expectDeny(try policy.checkFsRead(testing.allocator, "..\\outside.txt", root.canon_root), .fs_not_allowed);
}

// ----------------------------------------------------------------------
// Policy parsing (fail closed)
// ----------------------------------------------------------------------

test "policy parse rejects malformed JSON" {
    const bad = [_][]const u8{
        "",
        "not json",
        "{",
        "[1,2,3]", // non-object root
        "\"string\"",
        "{ \"fs\": }",
    };
    for (bad) |text| {
        try testing.expectError(error.PolicyInvalid, parsePolicy(text));
    }
}

test "policy parse rejects unknown keys at every level" {
    const bad = [_][]const u8{
        "{ \"net_raw\": false, \"surprise\": 1 }",
        "{ \"fs\": { \"read\": [], \"writ\": [] } }",
        "{ \"http\": { \"allow\": [], \"maxRedirects\": 3 } }",
        "{ \"env\": { \"allow\": [], \"deny\": [\"X\"] } }",
        "{ \"extern\": { \"allow\": [], \"block\": [\"evil\"] } }",
        "{ \"process\": { \"spawn\": false, \"exec_list\": [] } }",
        "{ \"limits\": { \"fuel\": 1, \"steps\": 2 } }",
        "{ \"http\": { \"allow\": [ { \"host\": \"a.com\", \"scheme\": \"https\" } ] } }",
        "{ \"process\": { \"exec\": [ { \"path\": \"x.exe\", \"argv\": [] } ] } }",
    };
    for (bad) |text| {
        try testing.expectError(error.PolicyInvalid, parsePolicy(text));
    }
}

test "policy parse validates schema string, types and pattern shapes" {
    const bad = [_][]const u8{
        "{ \"schema\": \"sa.vm.policy/2\" }",
        "{ \"schema\": 1 }",
        "{ \"fs\": { \"read\": \"D:\\\\**\" } }", // string instead of array
        "{ \"fs\": { \"read\": [\"relative/path\"] } }", // non-absolute pattern
        "{ \"fs\": { \"read\": [\"C:\\\\a\\\\..\\\\b\\\\**\"] } }", // '..' in pattern
        "{ \"fs\": { \"read\": [\"\"] } }",
        "{ \"ffi\": \"yes\" }",
        "{ \"http\": { \"allow\": [ { \"methods\": [\"GET\"] } ] } }", // host required
        "{ \"http\": { \"allow\": [ { \"host\": \"a.com\", \"methods\": [\"BREW\"] } ] } }",
        "{ \"http\": { \"allow\": [ { \"host\": \"a.com\", \"port\": 0 } ] } }",
        "{ \"env\": { \"allow\": [\"A*B\"] } }", // wildcard only allowed trailing
        "{ \"extern\": { \"allow\": [\"sa_fmt_*_into\"] } }", // ditto
        "{ \"extern\": { \"allow\": [\"\"] } }",
        "{ \"extern\": { \"allow\": [42] } }", // wrong element type
        "{ \"extern\": { \"allow\": \"sa_print_bytes\" } }", // string instead of array
        "{ \"limits\": { \"fuel\": -5 } }",
        "{ \"process\": { \"spawn\": false, \"exec\": [{}] } }",
    };
    for (bad) |text| {
        try testing.expectError(error.PolicyInvalid, parsePolicy(text));
    }
}

test "policy accepts the documented example shape" {
    const text =
        \\{
        \\  "schema": "sa.vm.policy/1",
        \\  "fs": { "read": ["D:\\factory\\data\\**"], "write": ["D:\\factory\\out\\**"] },
        \\  "http": { "allow": [ { "host": "api.example.com", "methods": ["GET","POST"] } ],
        \\            "max_redirects": 3 },
        \\  "env": { "allow": ["FACTORY_ID"] },
        \\  "process": { "spawn": false },
        \\  "ffi": false
        \\}
    ;
    var policy = try parsePolicy(text);
    defer policy.deinit();
    try testing.expectEqual(@as(u32, 3), policy.http_max_redirects);
    try testing.expectEqual(@as(usize, 1), policy.http_rules.len);
    try testing.expectEqualStrings("sa.vm.policy/1", policy.schema);
}

test "absent sections default to deny" {
    var policy = try parsePolicy("{}");
    defer policy.deinit();

    try expectDeny(try policy.checkFsRead(testing.allocator, "C:\\anything.txt", null), .fs_not_allowed);
    try expectDeny(policy.checkEnv("PATH"), .env_not_allowed);
    // Layer 1: no `extern` section => every extern symbol is denied.
    try expectDeny(policy.checkExtern("sa_fs_read_file"), .extern_not_allowed);
    try expectDeny(policy.checkExtern("fd_open"), .extern_not_allowed);
    try expectDeny(policy.checkFfi(), .ffi_denied);
    try expectDeny(policy.checkThreads(), .threads_denied);
    try expectDeny(policy.checkNetRaw(), .net_raw_denied);
    try expectDeny(try policy.checkProcessSpawn(testing.allocator, "cmd.exe", &.{}), .process_spawn_disabled);

    const verdict = try policy.checkHttp(testing.allocator, "GET", "https://api.example.com/");
    try expectDeny(verdict, .http_host_not_allowed);
}

test "empty http allow list denies every host" {
    var policy = try parsePolicy("{ \"http\": { \"allow\": [] } }");
    defer policy.deinit();
    const verdict = try policy.checkHttp(testing.allocator, "GET", "https://api.example.com/");
    try expectDeny(verdict, .http_host_not_allowed);
}

// ----------------------------------------------------------------------
// HTTP matching
// ----------------------------------------------------------------------

const http_json =
    \\{
    \\  "http": {
    \\    "allow": [
    \\      { "host": "api.example.com", "methods": ["GET", "POST"] },
    \\      { "host": "cdn.example.com", "methods": ["GET"], "paths": ["/v1/**"] },
    \\      { "host": "legacy.example.com", "methods": ["GET"], "port": 8080 }
    \\    ]
    \\  }
    \\}
;

fn httpPolicy() !Policy {
    return parsePolicy(http_json);
}

test "http allows listed hosts with masked methods" {
    var policy = try httpPolicy();
    defer policy.deinit();

    try expectAllow(try policy.checkHttp(testing.allocator, "GET", "https://api.example.com/v1/items"));
    try expectAllow(try policy.checkHttp(testing.allocator, "POST", "https://api.example.com/v1/items"));
    try expectDeny(try policy.checkHttp(testing.allocator, "DELETE", "https://api.example.com/v1"), .http_method_not_allowed);
}

test "http denies unlisted hosts and subdomain spoofs" {
    var policy = try httpPolicy();
    defer policy.deinit();

    try expectDeny(try policy.checkHttp(testing.allocator, "GET", "https://internal.corp/x"), .http_host_not_allowed);
    try expectDeny(try policy.checkHttp(testing.allocator, "GET", "https://api.example.com.evil.test/x"), .http_host_not_allowed);
    try expectDeny(try policy.checkHttp(testing.allocator, "GET", "https://evil-api.example.com/x"), .http_host_not_allowed);
    // Host compare is case-insensitive always (DNS names are).
    try expectAllow(try policy.checkHttp(testing.allocator, "GET", "https://API.EXAMPLE.COM/v1/items"));
}

test "http ports default to implied 80/443 unless pinned" {
    var policy = try httpPolicy();
    defer policy.deinit();

    try expectAllow(try policy.checkHttp(testing.allocator, "GET", "http://api.example.com/v1"));
    try expectAllow(try policy.checkHttp(testing.allocator, "GET", "https://api.example.com:443/v1"));
    try expectDeny(try policy.checkHttp(testing.allocator, "GET", "http://api.example.com:8080/v1"), .http_port_not_allowed);

    try expectAllow(try policy.checkHttp(testing.allocator, "GET", "http://legacy.example.com:8080/x"));
    try expectDeny(try policy.checkHttp(testing.allocator, "GET", "http://legacy.example.com/x"), .http_port_not_allowed);
    // Right host+port, wrong method.
    try expectDeny(try policy.checkHttp(testing.allocator, "POST", "http://legacy.example.com:8080/x"), .http_method_not_allowed);
}

test "http path rules respect segment boundaries" {
    var policy = try httpPolicy();
    defer policy.deinit();

    try expectAllow(try policy.checkHttp(testing.allocator, "GET", "https://cdn.example.com/v1/a/b.js"));
    try expectAllow(try policy.checkHttp(testing.allocator, "GET", "https://cdn.example.com/v1"));
    try expectDeny(try policy.checkHttp(testing.allocator, "GET", "https://cdn.example.com/v1x/y"), .http_path_not_allowed);
    try expectDeny(try policy.checkHttp(testing.allocator, "GET", "https://cdn.example.com/admin/x"), .http_path_not_allowed);
    try expectDeny(try policy.checkHttp(testing.allocator, "POST", "https://cdn.example.com/v1/a"), .http_method_not_allowed);
}

test "http rejects non-http schemes" {
    var policy = try httpPolicy();
    defer policy.deinit();

    try expectDeny(try policy.checkHttp(testing.allocator, "GET", "ftp://api.example.com/file"), .http_scheme_unsupported);
    try expectDeny(try policy.checkHttp(testing.allocator, "GET", "file:///etc/passwd"), .http_scheme_unsupported);
    try expectDeny(try policy.checkHttp(testing.allocator, "GET", "not a url at all"), .http_bad_target_url);
}

test "http ip-literal targets require explicit ip allowlisting" {
    var policy = try httpPolicy();
    defer policy.deinit();

    // Not covered by any hostname rule -> hard deny even though a hostname
    // rule exists (no fall-through).
    try expectDeny(try policy.checkHttp(testing.allocator, "GET", "http://127.0.0.1/admin"), .http_ip_literal_not_allowed);
    try expectDeny(try policy.checkHttp(testing.allocator, "GET", "http://10.0.0.5/x"), .http_ip_literal_not_allowed);

    // Explicitly allowlisted IP + private-address deny (default on).
    const text = "{ \"http\": { \"allow\": [ { \"host\": \"127.0.0.1\", \"methods\": [\"GET\"] } ] } }";
    var p2 = try parsePolicy(text);
    defer p2.deinit();
    try expectDeny(try p2.checkHttp(testing.allocator, "GET", "http://127.0.0.1/x"), .http_private_address_denied);

    // Operator relaxes the SSRF guard for intranet use -> allowed.
    const text3 = "{ \"http\": { \"deny_private_addresses\": false, \"allow\": [ { \"host\": \"127.0.0.1\", \"methods\": [\"GET\"] } ] } }";
    var p3 = try parsePolicy(text3);
    defer p3.deinit();
    try expectAllow(try p3.checkHttp(testing.allocator, "GET", "http://127.0.0.1/x"));
    try expectDeny(try p3.checkHttp(testing.allocator, "POST", "http://127.0.0.1/x"), .http_method_not_allowed);
}

test "private-address classification covers the ssrf deny list" {
    const private4 = [_][]const u8{
        "127.0.0.1",       "127.255.0.3",   "10.1.2.3",     "172.16.0.1",
        "172.31.255.255",  "192.168.1.1",   "169.254.169.254", "100.64.0.7",
        "100.127.255.255", "0.0.0.0",       "255.255.255.255",
    };
    for (private4) |ip| try testing.expect(policy_mod.isPrivateIpLiteral(ip));

    const public4 = [_][]const u8{ "8.8.8.8", "172.32.0.1", "100.128.0.1", "9.9.9.9" };
    for (public4) |ip| try testing.expect(!policy_mod.isPrivateIpLiteral(ip));

    const private6 = [_][]const u8{ "::1", "fe80::1", "fc00::abcd", "fd12::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1" };
    for (private6) |ip| try testing.expect(policy_mod.isPrivateIpLiteral(ip));

    const public6 = [_][]const u8{ "2606:4700::1111", "::ffff:8.8.8.8", "2001:db8::1" };
    for (public6) |ip| try testing.expect(!policy_mod.isPrivateIpLiteral(ip));

    try testing.expect(policy_mod.isIpLiteral("8.8.8.8"));
    try testing.expect(policy_mod.isIpLiteral("::1"));
    try testing.expect(!policy_mod.isIpLiteral("api.example.com"));
    try testing.expect(!policy_mod.isIpLiteral("999.1.1.1"));
}

// ----------------------------------------------------------------------
// Redirect validation
// ----------------------------------------------------------------------

test "redirect hops are capped, downgrades denied and methods re-checked" {
    var policy = try httpPolicy();
    defer policy.deinit();
    try testing.expectEqual(@as(u32, 5), policy.http_max_redirects); // spec default

    // Hop 0: api -> cdn, GET survives the method mask on the new host.
    try expectAllow(try policy.checkRedirect(
        testing.allocator,
        "GET",
        "https://api.example.com/v1/file",
        "https://cdn.example.com/v1/file",
        0,
    ));
    // Same hop but POST: cdn only allows GET -> denied per hop.
    try expectDeny(try policy.checkRedirect(
        testing.allocator,
        "POST",
        "https://api.example.com/v1/file",
        "https://cdn.example.com/v1/file",
        0,
    ), .http_method_not_allowed);
    // Redirect to a host that is not allowlisted at all.
    try expectDeny(try policy.checkRedirect(
        testing.allocator,
        "GET",
        "https://api.example.com/x",
        "https://evil.test/x",
        0,
    ), .http_host_not_allowed);

    // https -> http downgrade: always denied, even to an allowlisted host+port.
    try expectDeny(try policy.checkRedirect(
        testing.allocator,
        "GET",
        "https://api.example.com/x",
        "http://api.example.com/x",
        0,
    ), .http_downgrade_denied);

    // Hop cap: max_redirects=5 means hop index 5 is one too many.
    try expectDeny(try policy.checkRedirect(
        testing.allocator,
        "GET",
        "https://api.example.com/x",
        "https://cdn.example.com/v1/x",
        5,
    ), .http_redirect_limit);
    try expectAllow(try policy.checkRedirect(
        testing.allocator,
        "GET",
        "https://api.example.com/x",
        "https://cdn.example.com/v1/x",
        4,
    ));

    // max_redirects is author-configurable.
    const small = "{ \"http\": { \"max_redirects\": 0, \"allow\": [] } }";
    var p2 = try parsePolicy(small);
    defer p2.deinit();
    try expectDeny(try p2.checkRedirect(
        testing.allocator,
        "GET",
        "https://api.example.com/x",
        "https://cdn.example.com/x",
        0,
    ), .http_redirect_limit);
}

test "absolutizeRedirect joins locations without losing authority" {
    const a = testing.allocator;

    // Absolute Location passes through unchanged.
    {
        const got = try Policy.absolutizeRedirect(a, "https://api.example.com/a", "https://other.example.com/b");
        defer a.free(got);
        try testing.expectEqualStrings("https://other.example.com/b", got);
    }
    // Root-relative keeps scheme, host AND explicit port.
    {
        const got = try Policy.absolutizeRedirect(a, "https://api.example.com:8443/a", "/next?id=2");
        defer a.free(got);
        try testing.expectEqualStrings("https://api.example.com:8443/next?id=2", got);
    }
    // Root-relative with implied port adds none.
    {
        const got = try Policy.absolutizeRedirect(a, "https://cdn.example.com/v1/x", "/v2/x");
        defer a.free(got);
        try testing.expectEqualStrings("https://cdn.example.com/v2/x", got);
    }
    // Protocol-relative redirects change host within the scheme.
    {
        const got = try Policy.absolutizeRedirect(a, "https://api.example.com/a", "//cdn.example.com/b");
        defer a.free(got);
        try testing.expectEqualStrings("https://cdn.example.com/b", got);
    }
    // Bare-relative and empty Locations are refused (callers deny).
    try testing.expectError(error.BadRedirectLocation, Policy.absolutizeRedirect(a, "https://api.example.com/a", "rel/page"));
    try testing.expectError(error.BadRedirectLocation, Policy.absolutizeRedirect(a, "https://api.example.com/a", ""));
}

// ----------------------------------------------------------------------
// env / process / ffi gates
// ----------------------------------------------------------------------

test "env allowlist supports exact names and trailing wildcard only" {
    const text = "{ \"env\": { \"allow\": [\"FACTORY_ID\", \"TMP_*\"] } }";
    var policy = try parsePolicy(text);
    defer policy.deinit();

    try expectAllow(policy.checkEnv("FACTORY_ID"));
    try expectAllow(policy.checkEnv("TMP_123"));
    try expectDeny(policy.checkEnv("FACTORY_SECRET"), .env_not_allowed);
    try expectDeny(policy.checkEnv("HOME"), .env_not_allowed);
    // Byte-exact: no silent case folding (documented platform behavior).
    try expectDeny(policy.checkEnv("factory_id"), .env_not_allowed);
}

test "process spawn gate honors flag and exec rules" {
    const strict = "{ \"process\": { \"spawn\": false } }";
    var p1 = try parsePolicy(strict);
    defer p1.deinit();
    try expectDeny(try p1.checkProcessSpawn(testing.allocator, "C:\\tools\\gen.exe", &.{"x"}), .process_spawn_disabled);

    const loose = "{ \"process\": { \"spawn\": true } }";
    var p2 = try parsePolicy(loose);
    defer p2.deinit();
    try expectAllow(try p2.checkProcessSpawn(testing.allocator, "C:\\tools\\gen.exe", &.{"x"}));

    const listed =
        \\{ "process": { "spawn": true, "exec": [
        \\  { "path": "C:\\tools\\gen.exe", "args": ["--batch", "*"] }
        \\] } }
    ;
    var p3 = try parsePolicy(listed);
    defer p3.deinit();
    try expectAllow(try p3.checkProcessSpawn(testing.allocator, "C:\\tools\\gen.exe", &.{ "--batch", "42" }));
    try expectDeny(try p3.checkProcessSpawn(testing.allocator, "C:\\tools\\gen.exe", &.{"--batch"}), .process_exec_not_allowed);
    try expectDeny(try p3.checkProcessSpawn(testing.allocator, "C:\\windows\\system32\\cmd.exe", &.{"/c"}), .process_exec_not_allowed);
}

test "ffi threads and net_raw flags gate their capabilities" {
    const text = "{ \"ffi\": true, \"threads\": false, \"net_raw\": true }";
    var policy = try parsePolicy(text);
    defer policy.deinit();

    try expectAllow(policy.checkFfi());
    try expectDeny(policy.checkThreads(), .threads_denied);
    try expectAllow(policy.checkNetRaw());
}

// ----------------------------------------------------------------------
// Extern allowlist (Layer 1) + --sandboxed profile
// ----------------------------------------------------------------------

test "extern allowlist matches exact names and trailing wildcard" {
    const text = "{ \"extern\": { \"allow\": [\"sa_print_bytes\", \"sa_fmt_*\", \"fd_open\"] } }";
    var policy = try parsePolicy(text);
    defer policy.deinit();

    try expectAllow(policy.checkExtern("sa_print_bytes"));
    try expectAllow(policy.checkExtern("sa_fmt_i64"));
    try expectAllow(policy.checkExtern("sa_fmt_buffer_free"));
    try expectAllow(policy.checkExtern("fd_open"));
    // Symbols are matched byte-exactly (C names are case-sensitive).
    try expectDeny(policy.checkExtern("SA_PRINT_BYTES"), .extern_not_allowed);
    // A prefix match must not leak into a different family.
    try expectDeny(policy.checkExtern("sa_fmtx_evil"), .extern_not_allowed);
    try expectDeny(policy.checkExtern("dlopen"), .extern_not_allowed);
}

test "extern wildcard star alone allows every symbol" {
    var policy = try parsePolicy("{ \"extern\": { \"allow\": [\"*\"] } }");
    defer policy.deinit();
    try expectAllow(policy.checkExtern("anything_at_all"));
    try expectAllow(policy.checkExtern("dlsym"));
}

test "extern section absent denies every symbol including shims" {
    var policy = try parsePolicy("{ \"limits\": { \"fuel\": 1000 } }");
    defer policy.deinit();
    try expectDeny(policy.checkExtern("sa_time_sleep_ms"), .extern_not_allowed);
    try expectDeny(policy.checkExtern("malloc"), .extern_not_allowed);
}

test "built-in sandboxed profile parses and is default deny beyond print/fmt" {
    var policy = try parsePolicy(policy_mod.sandboxed_policy_json);
    defer policy.deinit();

    // Interpreter-internal formatting/printing stays available.
    try expectAllow(policy.checkExtern("sa_print_bytes"));
    try expectAllow(policy.checkExtern("sa_fmt_u64"));
    // Everything else - including legacy VM shims and libc names - is denied.
    try expectDeny(policy.checkExtern("fd_open"), .extern_not_allowed);
    try expectDeny(policy.checkExtern("sa_fs_read_file"), .extern_not_allowed);
    try expectDeny(policy.checkExtern("sa_http_client_req_new"), .extern_not_allowed);
    try expectDeny(policy.checkExtern("dlopen"), .extern_not_allowed);

    try expectDeny(try policy.checkFsRead(testing.allocator, "D:\\factory\\data\\a.txt", null), .fs_not_allowed);
    try expectDeny(try policy.checkHttp(testing.allocator, "GET", "https://api.example.com/"), .http_host_not_allowed);
    try expectDeny(policy.checkEnv("HOME"), .env_not_allowed);
    try expectDeny(try policy.checkProcessSpawn(testing.allocator, "cmd.exe", &.{}), .process_spawn_disabled);
    try expectDeny(policy.checkFfi(), .ffi_denied);
    try expectDeny(policy.checkThreads(), .threads_denied);
    try expectDeny(policy.checkNetRaw(), .net_raw_denied);

    // Resource caps are defaulted, not unlimited, so an untrusted program can
    // never run without a bound.
    try testing.expectEqual(@as(u64, 1_000_000_000), policy.limits.fuel.?);
    try testing.expectEqual(@as(u64, 10_000), policy.limits.wall_clock_ms.?);
    try testing.expectEqual(@as(u64, 268_435_456), policy.limits.mem_cap_bytes.?);
}

// ----------------------------------------------------------------------
// Verdict plumbing
// ----------------------------------------------------------------------

test "every deny reason maps to E_CAPABILITY_DENIED with a unique label" {
    const fields = @typeInfo(policy_mod.DenyReason).@"enum".fields;
    try testing.expect(fields.len >= 17);
    inline for (fields) |field| {
        const reason: policy_mod.DenyReason = @enumFromInt(field.value);
        try testing.expectEqual(policy_mod.panic_code_capability_denied, reason.panicCode());
        try testing.expect(reason.label().len > 0);
    }
    // Labels are distinct so harnesses can branch on them without parsing prose.
    comptime var pairs: usize = 0;
    inline for (fields, 0..) |outer, i| {
        inline for (fields[i + 1 ..]) |inner| {
            const a: policy_mod.DenyReason = @enumFromInt(outer.value);
            const b: policy_mod.DenyReason = @enumFromInt(inner.value);
            std.debug.assert(!std.mem.eql(u8, a.label(), b.label()));
            pairs += 1;
        }
    }
    try testing.expect(pairs > 0);
    try testing.expectEqual(@as(u8, 105), policy_mod.panic_code_policy_invalid);
}

test "policy memory is released through deinit" {
    const text =
        \\{ "fs": {"read": ["C:\\a\\**","C:\\b\\**"]},
        \\  "http": {"allow":[{"host":"a.com","methods":["GET"],"paths":["/x/**"]}]},
        \\  "env": {"allow":["A","B","C"]} }
    ;
    var policy = try parsePolicy(text);
    try expectAllow(try policy.checkFsRead(testing.allocator, "C:\\a\\deep\\f.txt", null));
    policy.deinit();
    // Leak detection happens automatically in the testing allocator on exit;
    // reaching this point means no leaks were reported for this test's scope.
}
