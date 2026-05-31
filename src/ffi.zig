const std = @import("std");

extern fn dlopen(filename: ?[*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, symbol: ?[*:0]const u8) ?*anyopaque;
extern fn dlclose(handle: ?*anyopaque) c_int;
extern fn dlerror() ?[*:0]const u8;

pub const FfiFn = *const fn (
    arg0: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
    arg5: usize,
    arg6: usize,
    arg7: usize,
    arg8: usize,
) callconv(.c) usize;

pub export fn fd_open(path: ?[*]const u8) callconv(.c) i32 {
    _ = path;
    return 3;
}
pub export fn fd_read(fd: i32) callconv(.c) i32 {
    _ = fd;
    return 3;
}
pub export fn fd_close(fd: i32) callconv(.c) i32 {
    _ = fd;
    return 0;
}
pub export fn mmap(fd: i32, len: usize) callconv(.c) ?*anyopaque {
    _ = fd;
    // Real mmap would be better, but for Rosetta shim this is often enough
    const ptr = std.heap.page_allocator.alloc(u8, len) catch return null;
    return ptr.ptr;
}
pub export fn munmap(ptr: ?*anyopaque, len: usize) callconv(.c) i32 {
    _ = ptr;
    _ = len;
    return 0;
}
pub export fn signal(sig: i32, handler: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = sig;
    _ = handler;
    return null;
}
pub export fn pthread_spawn(func: ?*anyopaque, arg: ?*anyopaque) callconv(.c) i32 {
    _ = func;
    _ = arg;
    return 0;
}
pub export fn pthread_join(id: i32) callconv(.c) i32 {
    _ = id;
    return 0;
}
pub export fn sqlite3_prepare(db: ?*anyopaque, sql: ?[*]const u8, sql_len: i32, stmt_out: ?*anyopaque) callconv(.c) i32 {
    _ = db; _ = sql; _ = sql_len; _ = stmt_out;
    return 0;
}
pub export fn sqlite3_step(stmt: ?*anyopaque) callconv(.c) i32 {
    _ = stmt;
    return 100; // SQLITE_DONE
}
pub export fn sqlite3_finalize(stmt: ?*anyopaque) callconv(.c) i32 {
    _ = stmt;
    return 0;
}

pub const FfiManager = struct {
    allocator: std.mem.Allocator,
    handles: std.ArrayList(*anyopaque),
    dependencies: [][]u8,
    loaded_dependency_count: usize,

    pub fn init(allocator: std.mem.Allocator) FfiManager {
        var handles = std.ArrayList(*anyopaque).init(allocator);
        // Load the global namespace (the sa binary itself and its dependencies)
        if (dlopen(null, 2)) |global_handle| {
            handles.append(global_handle) catch {};
        }

        return .{
            .allocator = allocator,
            .handles = handles,
            .dependencies = &.{},
            .loaded_dependency_count = 0,
        };
    }


    pub fn deinit(self: *FfiManager) void {
        for (self.handles.items) |handle| {
            _ = dlclose(handle);
        }
        self.handles.deinit();
        self.freeDependencyNames(self.dependencies);
    }

    fn pluginsHome(self: *FfiManager) ![]u8 {
        if (std.posix.getenv("SA_PLUGINS_HOME")) |home| {
            return try self.allocator.dupe(u8, home);
        }
        const home_dir = std.posix.getenv("HOME") orelse "/home/vscode";
        return try std.fmt.allocPrint(self.allocator, "{s}/.local/share/sa_plugins", .{home_dir});
    }

    fn readDeclaredDependencyNames(self: *FfiManager, plugins_home: []const u8) ![][]u8 {
        const manifest_path = try std.fs.path.join(self.allocator, &.{ plugins_home, "installed", "vm", "current", "sap.json" });
        defer self.allocator.free(manifest_path);

        const source = std.fs.cwd().readFileAlloc(self.allocator, manifest_path, 1 << 20) catch |err| {
            std.debug.print("VM manifest not readable at {s}: {}\n", .{ manifest_path, err });
            return try self.allocator.alloc([]u8, 0);
        };
        defer self.allocator.free(source);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, source, .{}) catch |err| {
            std.debug.print("VM manifest JSON parse failed at {s}: {}\n", .{ manifest_path, err });
            return try self.allocator.alloc([]u8, 0);
        };
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return try self.allocator.alloc([]u8, 0),
        };
        const deps_value = root.get("dependencies") orelse return try self.allocator.alloc([]u8, 0);
        const deps = switch (deps_value) {
            .object => |obj| obj,
            else => return try self.allocator.alloc([]u8, 0),
        };

        var names = std.ArrayList([]u8).init(self.allocator);
        errdefer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit();
        }

        var it = deps.iterator();
        while (it.next()) |entry| {
            try names.append(try self.allocator.dupe(u8, entry.key_ptr.*));
        }
        return try names.toOwnedSlice();
    }

    fn freeDependencyNames(self: *FfiManager, names: [][]u8) void {
        for (names) |name| self.allocator.free(name);
        if (names.len != 0) self.allocator.free(names);
    }

    fn loadInstalledPlugin(self: *FfiManager, plugins_home: []const u8, plugin_name: []const u8) !?*anyopaque {
        const lib_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/installed/{s}/current/lib{s}.so",
            .{ plugins_home, plugin_name, plugin_name },
        );
        defer self.allocator.free(lib_path);

        const path_z = try self.allocator.dupeZ(u8, lib_path);
        defer self.allocator.free(path_z);

        // RTLD_NOW is 2.
        if (dlopen(path_z, 2)) |handle| {
            return handle;
        } else if (dlerror()) |err_msg| {
            std.debug.print("Declared FFI dependency not loaded ({s}): {s}\n", .{ lib_path, err_msg });
        } else {
            std.debug.print("Declared FFI dependency not loaded ({s})\n", .{lib_path});
        }
        return null;
    }

    pub fn loadDeclaredDependencies(self: *FfiManager) !void {
        const plugins_home = try self.pluginsHome();
        defer self.allocator.free(plugins_home);

        self.freeDependencyNames(self.dependencies);
        self.dependencies = try self.readDeclaredDependencyNames(plugins_home);
        self.loaded_dependency_count = 0;
    }

    pub fn loadAllInstalledPlugins(self: *FfiManager) !void {
        const plugins_home = try self.pluginsHome();
        defer self.allocator.free(plugins_home);
        const plugins_installed_path = try std.fs.path.join(self.allocator, &.{ plugins_home, "installed" });
        defer self.allocator.free(plugins_installed_path);

        var dir = std.fs.openDirAbsolute(plugins_installed_path, .{ .iterate = true }) catch |err| {
            std.debug.print("Failed to open installed plugins dir: {s}, error: {}\n", .{ plugins_installed_path, err });
            return;
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .directory) {
                const plugin_name = entry.name;
                // E.g., ~/.local/share/sa_plugins/installed/deno/current/libdeno.so
                var lib_path_buf: [1024]u8 = undefined;
                const lib_path = try std.fmt.bufPrint(&lib_path_buf, "{s}/{s}/current/lib{s}.so", .{ plugins_installed_path, plugin_name, plugin_name });

                // Try to load
                const path_z = try self.allocator.dupeZ(u8, lib_path);
                defer self.allocator.free(path_z);

                // RTLD_NOW is 2
                if (dlopen(path_z, 2)) |handle| {
                    try self.handles.append(handle);
                } else {
                    if (dlerror()) |err_msg| {
                        std.debug.print("Failed to dlopen {s}: {s}\n", .{ lib_path, err_msg });
                    }
                }
            }
        }
    }

    pub fn resolveSymbol(self: *FfiManager, symbol_name: []const u8) ?*anyopaque {
        if (std.mem.eql(u8, symbol_name, "fd_open")) return @constCast(@ptrCast(&fd_open));
        if (std.mem.eql(u8, symbol_name, "fd_read")) return @constCast(@ptrCast(&fd_read));
        if (std.mem.eql(u8, symbol_name, "fd_close")) return @constCast(@ptrCast(&fd_close));
        if (std.mem.eql(u8, symbol_name, "mmap")) return @constCast(@ptrCast(&mmap));
        if (std.mem.eql(u8, symbol_name, "munmap")) return @constCast(@ptrCast(&munmap));
        if (std.mem.eql(u8, symbol_name, "signal")) return @constCast(@ptrCast(&signal));
        if (std.mem.eql(u8, symbol_name, "pthread_spawn")) return @constCast(@ptrCast(&pthread_spawn));
        if (std.mem.eql(u8, symbol_name, "pthread_join")) return @constCast(@ptrCast(&pthread_join));
        if (std.mem.eql(u8, symbol_name, "sqlite3_prepare")) return @constCast(@ptrCast(&sqlite3_prepare));
        if (std.mem.eql(u8, symbol_name, "sqlite3_step")) return @constCast(@ptrCast(&sqlite3_step));
        if (std.mem.eql(u8, symbol_name, "sqlite3_finalize")) return @constCast(@ptrCast(&sqlite3_finalize));

        const symbol_name_z = self.allocator.dupeZ(u8, symbol_name) catch return null;
        defer self.allocator.free(symbol_name_z);

        for (self.handles.items) |handle| {
            if (dlsym(handle, symbol_name_z)) |sym| {
                return sym;
            }
        }

        const plugins_home = self.pluginsHome() catch return null;
        defer self.allocator.free(plugins_home);

        while (self.loaded_dependency_count < self.dependencies.len) {
            const plugin_name = self.dependencies[self.loaded_dependency_count];
            self.loaded_dependency_count += 1;
            const handle = self.loadInstalledPlugin(plugins_home, plugin_name) catch continue;
            if (handle) |loaded_handle| {
                self.handles.append(loaded_handle) catch {
                    _ = dlclose(loaded_handle);
                    continue;
                };
                if (dlsym(loaded_handle, symbol_name_z)) |sym| {
                    return sym;
                }
            }
        }
        return null;
    }
};
