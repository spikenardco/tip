const std = @import("std");
const builtin = @import("builtin");

/// Where an app directory lives on each OS: an env var base plus a sub-path.
const DirSpec = struct {
    primary_env: []const u8,
    fallback_env: ?[]const u8,
    primary_subpath: []const u8,
    fallback_subpath: []const u8,
};

const DirRole = enum {
    data,
    config,
};

/// Only Linux splits data from config; macOS and Windows share one directory.
fn dir_spec_for(comptime role: DirRole) DirSpec {
    return switch (builtin.os.tag) {
        .linux => switch (role) {
            .data => .{
                .primary_env = "XDG_DATA_HOME",
                .fallback_env = "HOME",
                .primary_subpath = "tip",
                .fallback_subpath = ".local/share/tip",
            },
            .config => .{
                .primary_env = "XDG_CONFIG_HOME",
                .fallback_env = "HOME",
                .primary_subpath = "tip",
                .fallback_subpath = ".config/tip",
            },
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
}

/// Windows reads its env var with `getAlloc`; other platforms use `getPosix`.
/// Caller owns the result.
fn resolve_dir_path(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    spec: DirSpec,
) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const base = environ.getAlloc(allocator, spec.primary_env) catch |err| switch (err) {
            error.EnvironmentVariableMissing => return error.HomeDirMissing,
            else => return err,
        };
        defer allocator.free(base);

        return std.fs.path.join(allocator, &.{ base, spec.primary_subpath });
    }

    if (environ.getPosix(spec.primary_env)) |p| {
        return std.fs.path.join(allocator, &.{ p, spec.primary_subpath });
    }

    if (spec.fallback_env) |fallback| {
        const home = environ.getPosix(fallback) orelse return error.HomeDirMissing;
        return std.fs.path.join(allocator, &.{ home, spec.fallback_subpath });
    }

    return error.HomeDirMissing;
}

/// Where tip stores its data. Caller owns the result.
pub fn data_dir_path(allocator: std.mem.Allocator, environ: std.process.Environ) ![]const u8 {
    return resolve_dir_path(allocator, environ, dir_spec_for(.data));
}

/// Where tip keeps its config files. Caller owns the result.
pub fn config_dir_path(allocator: std.mem.Allocator, environ: std.process.Environ) ![]const u8 {
    return resolve_dir_path(allocator, environ, dir_spec_for(.config));
}
