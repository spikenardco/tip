const std = @import("std");
const models = @import("../core/models.zig");

/// Loads tasks from the JSON file. Parsed data is owned by the given allocator
/// (pass an arena allocator for batch-free cleanup).
pub fn load_tasks(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]models.Task {
    const contents = dir.readFileAlloc(io, "tasks.json", arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return &[_]models.Task{},
        else => |e| return e,
    };
    if (contents.len == 0) return &[_]models.Task{};

    const parsed = try std.json.parseFromSliceLeaky(struct { tasks: []models.Task }, arena, contents, .{});
    return parsed.tasks;
}

/// Writes tasks to the JSON file, replacing any existing content.
pub fn save_tasks(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, tasks: []const models.Task) !void {
    const string = try std.json.Stringify.valueAlloc(
        allocator,
        .{ .tasks = tasks },
        .{ .whitespace = .indent_2 },
    );
    defer allocator.free(string);

    try dir.writeFile(io, .{ .sub_path = "tasks.json", .data = string });
}
