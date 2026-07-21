const std = @import("std");
const builtin = @import("builtin");

const DirConfig = struct {
    primary_env: []const u8,
    fallback_env: ?[]const u8,
    primary_subpath: []const u8,
    fallback_subpath: []const u8,
};

const dir_config: DirConfig = switch (builtin.os.tag) {
    .linux => .{
        .primary_env = "XDG_DATA_HOME",
        .fallback_env = "HOME",
        .primary_subpath = "tip",
        .fallback_subpath = ".local/share/tip",
    },
    .macos => .{
        .primary_env = "HOME",
        .fallback_env = null,
        .primary_subpath = "Library/Application Support/tip",
        .fallback_subpath = "",
    },
    .windows => .{
        .primary_env = "APPDATA",
        .fallback_env = null,
        .primary_subpath = "tip",
        .fallback_subpath = "",
    },
    else => @compileError("unsupported OS"),
};

/// Returns the platform-specific data directory path for storing app data.
/// Uses a comptime config per platform — no runtime OS branches.
/// Caller owns the returned memory.
pub fn data_dir_path(allocator: std.mem.Allocator, environ: std.process.Environ) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const appdata = environ.getAlloc(allocator, dir_config.primary_env) catch |err| switch (err) {
            error.EnvironmentVariableMissing => return error.HomeDirMissing,
            else => return err,
        };
        defer allocator.free(appdata);

        return std.fs.path.join(allocator, &.{ appdata, dir_config.primary_subpath });
    }

    if (environ.getPosix(dir_config.primary_env)) |p| {
        return std.fs.path.join(allocator, &.{ p, dir_config.primary_subpath });
    }

    if (dir_config.fallback_env) |fallback| {
        const home = environ.getPosix(fallback) orelse return error.HomeDirMissing;
        return std.fs.path.join(allocator, &.{ home, dir_config.fallback_subpath });
    }

    return error.HomeDirMissing;
}
