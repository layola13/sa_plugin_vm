const std = @import("std");
const parser = @import("parser.zig");
const c = @cImport({
    @cInclude("ffi.h");
});

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

const FfiValue = extern union {
    u8_value: u8,
    i8_value: i8,
    u16_value: u16,
    i16_value: i16,
    u32_value: u32,
    i32_value: i32,
    u64_value: u64,
    i64_value: i64,
    f32_value: f32,
    f64_value: f64,
    ptr_value: ?*anyopaque,
    usize_value: usize,
};

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
pub export fn pthread_spawn_detached(func: ?*anyopaque, arg: ?*anyopaque) callconv(.c) i32 {
    _ = func;
    _ = arg;
    return 0;
}
pub export fn pthread_join(id: i32, out: ?*anyopaque) callconv(.c) i32 {
    _ = id;
    _ = out;
    return 0;
}
pub export fn pthread_drop(id: i32) callconv(.c) void {
    _ = id;
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

pub export fn sa_time_sleep_ms(ms: u64) callconv(.c) i32 {
    std.time.sleep(ms * std.time.ns_per_ms);
    return 0;
}

pub export fn sa_time_sleep_ns(ns: u64) callconv(.c) i32 {
    std.time.sleep(ns);
    return 0;
}

pub const FfiManager = struct {
    allocator: std.mem.Allocator,
    handles: std.ArrayList(*anyopaque),
    dependencies: [][]u8,
    loaded_dependency_count: usize,
    allow_ffi: bool = false,

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
            .allow_ffi = false,
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

    fn ffiTypeFor(ty: parser.PrimType) [*c]c.ffi_type {
        return switch (ty) {
            .void => &c.ffi_type_void,
            .i1, .u8 => &c.ffi_type_uint8,
            .i8 => &c.ffi_type_sint8,
            .u16 => &c.ffi_type_uint16,
            .i16 => &c.ffi_type_sint16,
            .u32 => &c.ffi_type_uint32,
            .i32 => &c.ffi_type_sint32,
            .u64 => &c.ffi_type_uint64,
            .i64 => &c.ffi_type_sint64,
            .f32 => &c.ffi_type_float,
            .f64 => &c.ffi_type_double,
            .ptr => &c.ffi_type_pointer,
        };
    }

    fn writeArgValue(value: *FfiValue, ty: parser.PrimType, raw: usize) void {
        switch (ty) {
            .void => value.* = .{ .u64_value = 0 },
            .i1, .u8 => value.* = .{ .u8_value = @as(u8, @intCast(raw & 0xff)) },
            .i8 => value.* = .{ .i8_value = @as(i8, @bitCast(@as(u8, @intCast(raw & 0xff)))) },
            .u16 => value.* = .{ .u16_value = @as(u16, @intCast(raw & 0xffff)) },
            .i16 => value.* = .{ .i16_value = @as(i16, @bitCast(@as(u16, @intCast(raw & 0xffff)))) },
            .u32 => value.* = .{ .u32_value = @as(u32, @intCast(raw & 0xffffffff)) },
            .i32 => value.* = .{ .i32_value = @as(i32, @bitCast(@as(u32, @intCast(raw & 0xffffffff)))) },
            .u64 => value.* = .{ .u64_value = @as(u64, @intCast(raw)) },
            .i64 => value.* = .{ .i64_value = @as(i64, @bitCast(@as(u64, @intCast(raw)))) },
            .f32 => value.* = .{ .f32_value = @as(f32, @bitCast(@as(u32, @intCast(raw & 0xffffffff)))) },
            .f64 => value.* = .{ .f64_value = @as(f64, @bitCast(@as(u64, @intCast(raw)))) },
            .ptr => value.* = .{ .ptr_value = if (raw == 0) null else @as(?*anyopaque, @ptrFromInt(raw)) },
        }
    }

    fn readReturnValue(value: FfiValue, ty: parser.PrimType) usize {
        return switch (ty) {
            .void => 0,
            .i1, .u8 => @as(usize, @intCast(value.u8_value)),
            .i8 => @as(usize, @bitCast(@as(isize, @intCast(value.i8_value)))),
            .u16 => @as(usize, @intCast(value.u16_value)),
            .i16 => @as(usize, @bitCast(@as(isize, @intCast(value.i16_value)))),
            .u32 => @as(usize, @intCast(value.u32_value)),
            .i32 => @as(usize, @bitCast(@as(isize, @intCast(value.i32_value)))),
            .u64 => @as(usize, @intCast(value.u64_value)),
            .i64 => @as(usize, @bitCast(@as(isize, @intCast(value.i64_value)))),
            .f32 => @as(usize, @intCast(@as(u32, @bitCast(value.f32_value)))),
            .f64 => @as(usize, @intCast(@as(u64, @bitCast(value.f64_value)))),
            .ptr => if (value.ptr_value) |ptr| @intFromPtr(ptr) else 0,
        };
    }

    pub fn callSymbol(self: *FfiManager, symbol_name: []const u8, signature: parser.ExternSignature, args: []const usize) !usize {
        const sym = self.resolveSymbol(symbol_name) orelse return error.SymbolNotFound;
        if (args.len != signature.arg_types.len) return error.FfiArityMismatch;

        var ffi_arg_types = try self.allocator.alloc([*c]c.ffi_type, args.len);
        defer self.allocator.free(ffi_arg_types);

        var ffi_arg_values = try self.allocator.alloc(FfiValue, args.len);
        defer self.allocator.free(ffi_arg_values);

        var ffi_arg_ptrs = try self.allocator.alloc(?*anyopaque, args.len);
        defer self.allocator.free(ffi_arg_ptrs);

        for (args, 0..) |arg, i| {
            ffi_arg_types[i] = ffiTypeFor(signature.arg_types[i]);
            writeArgValue(&ffi_arg_values[i], signature.arg_types[i], arg);
            ffi_arg_ptrs[i] = @ptrCast(&ffi_arg_values[i]);
        }

        var cif: c.ffi_cif = undefined;
        const status = c.ffi_prep_cif(
            &cif,
            c.FFI_DEFAULT_ABI,
            @as(c_uint, @intCast(args.len)),
            ffiTypeFor(signature.return_type),
            ffi_arg_types.ptr,
        );
        if (status != c.FFI_OK) return error.FfiPrepFailed;

        var ret = FfiValue{ .u64_value = 0 };
        const ret_ptr: ?*anyopaque = if (signature.return_type == .void) null else @ptrCast(&ret);
        const fn_ptr: ?*const fn () callconv(.c) void = @ptrCast(sym);
        c.ffi_call(&cif, fn_ptr, ret_ptr, ffi_arg_ptrs.ptr);
        return readReturnValue(ret, signature.return_type);
    }

    pub fn callSymbolLegacy(self: *FfiManager, symbol_name: []const u8, args: []const usize) !usize {
        const sym = self.resolveSymbol(symbol_name) orelse return error.SymbolNotFound;
        const f = @as(FfiFn, @ptrCast(sym));
        var pad = [_]usize{0} ** 9;
        for (args, 0..) |arg, i| if (i < 9) { pad[i] = arg; };
        return f(pad[0], pad[1], pad[2], pad[3], pad[4], pad[5], pad[6], pad[7], pad[8]);
    }

    pub fn callPointerLegacy(_: *FfiManager, ptr: usize, args: []const usize) usize {
        const f = @as(FfiFn, @ptrFromInt(ptr));
        var pad = [_]usize{0} ** 9;
        for (args, 0..) |arg, i| if (i < 9) { pad[i] = arg; };
        return f(pad[0], pad[1], pad[2], pad[3], pad[4], pad[5], pad[6], pad[7], pad[8]);
    }

    pub fn resolveSymbol(self: *FfiManager, symbol_name: []const u8) ?*anyopaque {
        if (std.mem.eql(u8, symbol_name, "fd_open")) return @constCast(@ptrCast(&fd_open));
        if (std.mem.eql(u8, symbol_name, "fd_read")) return @constCast(@ptrCast(&fd_read));
        if (std.mem.eql(u8, symbol_name, "fd_close")) return @constCast(@ptrCast(&fd_close));
        if (std.mem.eql(u8, symbol_name, "mmap")) return @constCast(@ptrCast(&mmap));
        if (std.mem.eql(u8, symbol_name, "munmap")) return @constCast(@ptrCast(&munmap));
        if (std.mem.eql(u8, symbol_name, "signal")) return @constCast(@ptrCast(&signal));
        if (std.mem.eql(u8, symbol_name, "pthread_spawn")) return @constCast(@ptrCast(&pthread_spawn));
        if (std.mem.eql(u8, symbol_name, "pthread_spawn_detached")) return @constCast(@ptrCast(&pthread_spawn_detached));
        if (std.mem.eql(u8, symbol_name, "pthread_join")) return @constCast(@ptrCast(&pthread_join));
        if (std.mem.eql(u8, symbol_name, "pthread_drop")) return @constCast(@ptrCast(&pthread_drop));
        if (std.mem.eql(u8, symbol_name, "sqlite3_prepare")) return @constCast(@ptrCast(&sqlite3_prepare));
        if (std.mem.eql(u8, symbol_name, "sqlite3_step")) return @constCast(@ptrCast(&sqlite3_step));
        if (std.mem.eql(u8, symbol_name, "sqlite3_finalize")) return @constCast(@ptrCast(&sqlite3_finalize));
        if (std.mem.eql(u8, symbol_name, "sa_time_sleep_ms")) return @constCast(@ptrCast(&sa_time_sleep_ms));
        if (std.mem.eql(u8, symbol_name, "sa_time_sleep_ns")) return @constCast(@ptrCast(&sa_time_sleep_ns));
        if (std.mem.eql(u8, symbol_name, "dlopen")) return if (self.allow_ffi) @constCast(@ptrCast(&dlopen)) else null;
        if (std.mem.eql(u8, symbol_name, "dlsym")) return if (self.allow_ffi) @constCast(@ptrCast(&dlsym)) else null;
        if (std.mem.eql(u8, symbol_name, "dlclose")) return if (self.allow_ffi) @constCast(@ptrCast(&dlclose)) else null;
        if (std.mem.eql(u8, symbol_name, "dlerror")) return if (self.allow_ffi) @constCast(@ptrCast(&dlerror)) else null;

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
