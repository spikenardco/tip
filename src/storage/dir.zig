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

/// Opens (or creates) the platform-specific data directory for storing app data.
/// Uses a comptime config per platform — no runtime OS branches.
pub fn open_data_dir(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !std.Io.Dir {
    if (environ.getPosix(dir_config.primary_env)) |p| {
        const base = try std.fs.path.joinZ(allocator, &.{ p, dir_config.primary_subpath });
        defer allocator.free(base);
        return try std.Io.Dir.cwd().createDirPath(io, base);
    }

    if (dir_config.fallback_env) |fallback| {
        const home = environ.getPosix(fallback) orelse return error.HomeDirMissing;
        const base = try std.fs.path.joinZ(allocator, &.{ home, dir_config.fallback_subpath });
        defer allocator.free(base);
        return try std.Io.Dir.cwd().createDirPath(io, base);
    }

    return error.HomeDirMissing;
}
