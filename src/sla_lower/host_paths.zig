const std = @import("std");

/// Resolve the user home directory on the current host.
/// On Windows returns USERPROFILE; on Unix-like hosts returns HOME. The
/// returned slice is owned by the allocator and must be freed by the caller.
pub fn homeDirectory(allocator: std.mem.Allocator) ?[]u8 {
    // USERPROFILE is the canonical Windows home location.
    if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |home| {
        if (home.len > 0) return home;
        allocator.free(home);
    } else |_| {}
    // HOME is honored on POSIX and by some Windows shells (Git Bash, WSL).
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        if (home.len > 0) return home;
        allocator.free(home);
    } else |_| {}
    return null;
}
/// Normalize all backslash path separators to forward slashes.
/// On Windows the canonical separator is '\', but the compiler/tests
/// express workspace/import paths with forward slashes. Forward slash
/// paths are accepted by Windows file APIs and by std.fs.path.dirname/
/// basename (which match either separator), so normalizing produces
/// platform-consistent strings without breaking file I/O.
/// On POSIX this is a no-op copy because '\' is never a separator.
pub fn normalizePathSlashes(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, path.len);
    for (path, 0..) |ch, i| out[i] = if (ch == '\\') '/' else ch;
    return out;
}

/// Resolve the host `sa` executable that this plugin should shell out to when
/// delegating to `sa build-exe` / `sa test` / `sa run` subcommands.
///
/// On Windows, `CreateProcessW` does NOT search PATH for a bare argv[0] like
/// `"sa"`; we must hand it an absolute (or at least qualified) path.  This helper
/// mirrors the search order the user expects and is the single seam every
/// delegated sla command goes through so behavior stays consistent:
///
///   1. `SA_EXE` env var (explicit override).
///   2. `SCI_ROOT/zig-out/bin/sa<exe>` (local dev build of the sibling sci repo).
///   3. `selfExePath` dir + sibling `sa<exe>` (the installed `sa.exe` that loaded
///      this plugin DLL — works once `sa` is on the global PATH).
///   4. walk `PATH` entries for `sa<exe>` (generic global-`sa` resolution).
///   5. fall back to the bare `"sa"` name and let the OS error out
///      (preserves prior behavior / helpful diagnostics).
///
/// `exe` is `.exe` on Windows and empty elsewhere, matching Zig's platform exe
/// suffix.  The returned slice is owned by `allocator` (except for the `"sa"`
/// fallback literal).
const is_windows_build = @import("builtin").os.tag == .windows;
const sa_exe_suffix: []const u8 = if (is_windows_build) ".exe" else "";

fn probeExists(allocator: std.mem.Allocator, dir: []const u8, base: []const u8) ?[]u8 {
    const full = std.fs.path.join(allocator, &.{ dir, base }) catch return null;
    std.fs.cwd().access(full, .{}) catch {
        allocator.free(full);
        return null;
    };
    return full;
}

fn accessOk(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn resolveSaExecutable(allocator: std.mem.Allocator) []const u8 {
    const exe = sa_exe_suffix;
    const sa_base = std.fmt.allocPrint(allocator, "sa{0s}", .{exe}) catch return "sa";

    // 1. explicit override (SA_EXE)
    if (std.process.getEnvVarOwned(allocator, "SA_EXE")) |override_path| {
        if (override_path.len > 0 and accessOk(override_path)) return override_path;
        allocator.free(override_path);
    } else |_| {}

    // 2. SCI_ROOT/zig-out/bin/sa<exe> (dev layout)
    if (std.process.getEnvVarOwned(allocator, "SCI_ROOT")) |sci_root| {
        defer allocator.free(sci_root);
        const dev_bin = std.fs.path.join(allocator, &.{ sci_root, "zig-out", "bin" }) catch return "sa";
        defer allocator.free(dev_bin);
        if (probeExists(allocator, dev_bin, sa_base)) |hit| return hit;
    } else |_| {}

    // 3. directory of the sa.exe that loaded this plugin DLL
    if (std.fs.selfExePathAlloc(allocator)) |self_path| {
        defer allocator.free(self_path);
        if (std.fs.path.dirname(self_path)) |self_dir| {
            if (probeExists(allocator, self_dir, sa_base)) |hit| return hit;
        }
    } else |_| {}

    // 4. walk PATH (Account for both `;` on Windows and `:`/newline elsewhere.)
    if (std.process.getEnvVarOwned(allocator, "PATH")) |path_val| {
        defer allocator.free(path_val);
        const sep: []const u8 = if (is_windows_build) ";" else ":;\x0a";
        var it = std.mem.tokenizeAny(u8, path_val, sep);
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            if (probeExists(allocator, entry, sa_base)) |hit| return hit;
        }
    } else |_| {}

    // 5. fall back to bare name
    return "sa";
}
