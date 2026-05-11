const std = @import("std");
const models = @import("../core/models.zig");
const builtin = @import("builtin");

/// Opens (and creates if needed) a cross-platform application data directory
/// suitable for storing runtime data (not config).
///
/// Platform paths:
///   Linux   — $XDG_DATA_HOME/tip  or  ~/.local/share/tip
///   macOS   — ~/Library/Application Support/tip
///   Windows — %APPDATA%/tip
pub fn open_data_dir(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) !std.Io.Dir {
    var env_map = try std.process.Environ.createMap(environ, allocator);
    defer env_map.deinit();

    const base = switch (builtin.os.tag) {
        .linux => blk: {
            if (env_map.get("XDG_DATA_HOME")) |xdg| {
                break :blk try std.fs.path.join(allocator, &.{ xdg, "tip" });
            }
            const home = env_map.get("HOME") orelse return error.HomeDirMissing;
            break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share", "tip" });
        },
        .macos => blk: {
            const home = env_map.get("HOME") orelse return error.HomeDirMissing;
            break :blk try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "tip" });
        },
        .windows => blk: {
            const appdata = env_map.get("APPDATA") orelse return error.AppDataDirUnavailable;
            break :blk try std.fs.path.join(allocator, &.{ appdata, "tip" });
        },
        else => @compileError("unsupported OS"),
    };
    defer allocator.free(base);

    return try std.Io.Dir.cwd().createDirPathOpen(io, base, .{});
}

/// Loads all tasks from the JSON storage file within the given directory.
/// Uses `parseFromSliceLeaky` so all parsed data (including string fields) is owned
/// by the provided allocator. Callers should pass an arena allocator so everything
/// is freed at once when the arena is torn down.
pub fn load_tasks(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]models.Task {
    const contents = dir.readFileAlloc(io, "tasks.json", arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return &[_]models.Task{},
        else => |e| return e,
    };
    if (contents.len == 0) return &[_]models.Task{};

    const parsed = try std.json.parseFromSliceLeaky(struct { tasks: []models.Task }, arena, contents, .{});
    return parsed.tasks;
}

/// Serializes the given tasks to JSON and writes them to the storage file
/// within the given directory, replacing any existing content.
pub fn save_tasks(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, tasks: []const models.Task) !void {
    const string = try std.json.Stringify.valueAlloc(
        allocator,
        .{ .tasks = tasks },
        .{ .whitespace = .indent_2 },
    );
    defer allocator.free(string);

    try dir.writeFile(io, .{ .sub_path = "tasks.json", .data = string });
}
