const std = @import("std");
const models = @import("models.zig");
const storage = @import("../storage/json.zig");
const generate = @import("../utils/generate.zig");

const Color = enum {
    red,
    green,
    yellow,
    cyan,
    reset,
};

fn color(c: Color) []const u8 {
    return switch (c) {
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .cyan => "\x1b[36m",
        .reset => "\x1b[0m",
    };
}

fn priority_label(priority: ?models.Task.Priority) []const u8 {
    if (priority) |p| {
        return switch (p) {
            .high => "↑",
            .medium => "-",
            .low => "↓",
        };
    }
    return "";
}

fn priority_color(priority: ?models.Task.Priority) Color {
    if (priority) |p| {
        return switch (p) {
            .high => .red,
            .medium => .yellow,
            .low => .green,
        };
    }
    return .reset;
}

fn status_icon(status: models.Task.Status) []const u8 {
    return switch (status) {
        .pending => "○",
        .in_progress => "⟳",
        .completed => "✓",
    };
}

fn status_color(status: models.Task.Status) Color {
    return switch (status) {
        .pending => .reset,
        .in_progress => .cyan,
        .completed => .green,
    };
}

fn unix_timestamp(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

pub const TaskArgs = struct {
    list: bool = false,
    subcommand: ?union(enum) {
        add: struct {
            name: []const u8,
            desc: ?[]const u8 = null,
        },
        delete: struct {
            id: []const u8,
        },
        show: struct {
            id: []const u8,
        },
    } = null,

    pub const help =
        \\Task Management Commands
        \\
        \\Usage:
        \\  tip task <subcommand> [args] [flags]
        \\
        \\Options:
        \\  --list                        List all tasks
        \\
        \\Commands:
        \\  add
        \\      --name=<name>              Add new task
        \\      --desc=<description>       The description of the task
        \\  delete
        \\      --id=<id>                  delete task id.
        \\  show
        \\      --id=<id>                  Show task details
        \\
        \\
        \\Examples:
        \\  tip task --list
        \\  tip task add --name="Review code"
        \\
    ;
};

/// Dispatches the appropriate task operation based on the parsed CLI arguments.
pub fn execute_commands(io: std.Io, environ: std.process.Environ, T: TaskArgs) void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dir = storage.open_data_dir(allocator, io, environ) catch {
        std.debug.print("Failed to open config directory\n", .{});
        return;
    };
    defer dir.close(io);

    if (T.list) {
        list_task(allocator, io, dir) catch {};
        return;
    }

    if (T.subcommand) |subcommand| {
        switch (subcommand) {
            .add => |add| add_task(allocator, io, add.name, dir) catch {
                std.debug.print("Failed to add task\n", .{});
                return;
            },
            .delete => |del| delete_task(allocator, io, del.id, dir) catch {
                std.debug.print("Failed to delete task with id: {s}\n", .{del.id});
                return;
            },
            .show => |s| show_task(allocator, io, s.id, dir) catch {
                std.debug.print("Failed to show task with id: {s}\n", .{s.id});
                return;
            },
        }
    } else {
        std.debug.print("{s}\n", .{TaskArgs.help});
    }
}

/// Creates a new task with the given title and persists it to storage.
fn add_task(allocator: std.mem.Allocator, io: std.Io, title: []const u8, dir: std.Io.Dir) !void {
    if (title.len == 0) return error.EmptyTitle;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const existing = storage.load_tasks(arena.allocator(), io, dir) catch &[_]models.Task{};

    var tasks: std.ArrayList(models.Task) = .empty;
    defer tasks.deinit(allocator);
    for (existing) |task| {
        tasks.append(allocator, task) catch continue;
    }

    const id = try generate.uuid(allocator, io);
    defer allocator.free(id);
    try tasks.append(allocator, .{
        .status = .pending,
        .id = id[0..],
        .title = title[0..],
        .created_at = unix_timestamp(io),
    });
    std.debug.print("Adding task: {s}\n", .{title});

    try storage.save_tasks(arena.allocator(), io, dir, tasks.items);
}

/// Loads and prints all tasks from storage.
fn list_task(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tasks = storage.load_tasks(arena.allocator(), io, dir) catch return;

    if (tasks.len == 0) {
        std.debug.print("No tasks\n", .{});
        return;
    }

    var pending: std.ArrayList(models.Task) = .empty;
    var in_progress: std.ArrayList(models.Task) = .empty;
    var completed: std.ArrayList(models.Task) = .empty;
    defer {
        pending.deinit(allocator);
        in_progress.deinit(allocator);
        completed.deinit(allocator);
    }

    for (tasks) |task| {
        switch (task.status) {
            .pending => try pending.append(allocator, task),
            .in_progress => try in_progress.append(allocator, task),
            .completed => try completed.append(allocator, task),
        }
    }

    if (pending.items.len > 0) {
        std.debug.print("{s}Pending{s} ({d})\n", .{ color(.cyan), color(.reset), pending.items.len });
        for (pending.items) |task| {
            try print_task(io, task, false);
        }
        std.debug.print("\n", .{});
    }

    if (in_progress.items.len > 0) {
        std.debug.print("{s}In Progress{s} ({d})\n", .{ color(.cyan), color(.reset), in_progress.items.len });
        for (in_progress.items) |task| {
            try print_task(io, task, false);
        }
        std.debug.print("\n", .{});
    }

    if (completed.items.len > 0) {
        std.debug.print("{s}Completed{s} ({d})\n", .{ color(.green), color(.reset), completed.items.len });
        for (completed.items) |task| {
            try print_task(io, task, false);
        }
    }
}

fn print_task(io: std.Io, task: models.Task, detailed: bool) !void {
    const c_status = status_color(task.status);
    const c_reset = color(.reset);
    const compact_id = if (task.id.len > 8) task.id[0..8] else task.id;

    if (detailed) {
        std.debug.print("{s}=== Task Details ==={s}\n\n", .{ color(.cyan), c_reset });
        std.debug.print("ID:          {s}\n", .{task.id});
        std.debug.print("Title:       {s}\n", .{task.title});

        if (task.description) |desc| {
            std.debug.print("Description: {s}\n", .{desc});
        } else {
            std.debug.print("Description: -\n", .{});
        }

        std.debug.print("Status:      {s}{s}{s}\n", .{ color(c_status), status_icon(task.status), c_reset });

        if (task.priority) |p| {
            std.debug.print("Priority:    {s}{s}{s}\n", .{ color(priority_color(task.priority)), priority_label(p), c_reset });
        } else {
            std.debug.print("Priority:    -\n", .{});
        }

        if (task.due_date) |due| {
            const now = unix_timestamp(io);
            if (due < now) {
                std.debug.print("Due Date:    {d} (overdue)\n", .{due});
            } else {
                std.debug.print("Due Date:    {d}\n", .{due});
            }
        } else {
            std.debug.print("Due Date:    -\n", .{});
        }

        if (task.assigned_to) |assigned| {
            std.debug.print("Assigned To: {s}\n", .{assigned});
        } else {
            std.debug.print("Assigned To: -\n", .{});
        }

        std.debug.print("\n", .{});
        std.debug.print("Created:     {d}\n", .{task.created_at});

        if (task.updated_at) |updated| {
            std.debug.print("Updated:     {d}\n", .{updated});
        } else {
            std.debug.print("Updated:     -\n", .{});
        }

        if (task.completed_at) |completed| {
            std.debug.print("Completed:   {d}\n", .{completed});
        } else {
            std.debug.print("Completed:   -\n", .{});
        }
    } else {
        std.debug.print("  {s}{s}{s} ", .{ color(c_status), status_icon(task.status), c_reset });
        if (task.priority) |p| {
            std.debug.print("{s} ", .{priority_label(p)});
        }
        std.debug.print("{s}\n", .{task.title});

        if (task.description) |desc| {
            std.debug.print("      {s}📝{s} {s}\n", .{ color(.yellow), c_reset, desc });
        }

        if (task.due_date) |due| {
            const now = unix_timestamp(io);
            if (due < now) {
                std.debug.print("      {s}📅 Due: {d} (overdue){s}\n", .{ color(.red), due, c_reset });
            } else {
                std.debug.print("      {s}📅 Due: {d}{s}\n", .{ color(.yellow), due, c_reset });
            }
        }

        if (task.status == .completed) {
            if (task.completed_at) |completed| {
                std.debug.print("      {s}✓ Completed: {d}{s}\n", .{ color(.green), completed, c_reset });
            }
        }

        std.debug.print("      {s}ID: {s}{s}\n", .{ color(.yellow), compact_id, c_reset });
    }
}

/// Marks the task matching `task_id` as completed. Returns `error.InvalidItem`
/// if no task with that id exists.
fn mark_complete(allocator: std.mem.Allocator, io: std.Io, task_id: []const u8, dir: std.Io.Dir) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit(); // frees everything at once

    const tasks = storage.load_tasks(arena.allocator(), io, dir) catch {
        return error.InvalidItem;
    };

    for (tasks) |*task| {
        if (std.mem.eql(u8, task.id, task_id)) {
            task.status = .completed;
            task.updated_at = unix_timestamp(io);
            task.completed_at = unix_timestamp(io);
            try storage.save_tasks(arena.allocator(), io, dir, tasks);
            return;
        }
    }

    std.debug.print("Item {s} does not exist!\n", .{task_id});
    return error.InvalidItem;
}

/// Removes the task matching `task_id` from storage. Returns `error.InvalidItem`
/// if no task with that id exists. Supports partial ID matching (min 4 chars).
fn delete_task(allocator: std.mem.Allocator, io: std.Io, task_id: []const u8, dir: std.Io.Dir) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_alloc = arena.allocator();

    const tasks = storage.load_tasks(arena_alloc, io, dir) catch {
        return error.InvalidItem;
    };

    var remaining: std.ArrayList(models.Task) = .empty;
    defer remaining.deinit(arena_alloc);

    var found_indices: std.ArrayList(usize) = .empty;
    defer found_indices.deinit(arena_alloc);

    for (tasks, 0..) |task, i| {
        const match = if (task_id.len >= 4 and task.id.len >= task_id.len)
            std.mem.eql(u8, task.id[0..task_id.len], task_id)
        else
            std.mem.eql(u8, task.id, task_id);

        if (match) {
            try found_indices.append(arena_alloc, i);
        } else {
            try remaining.append(arena_alloc, task);
        }
    }

    if (found_indices.items.len == 0) {
        std.debug.print("No task found matching '{s}'\n", .{task_id});
        return error.InvalidItem;
    }

    if (found_indices.items.len > 1) {
        std.debug.print("Multiple tasks match '{s}':\n", .{task_id});
        for (found_indices.items) |idx| {
            const task = tasks[idx];
            std.debug.print("  - {s} [{s}]\n", .{ task.id[0..@min(8, task.id.len)], task.title });
        }
        std.debug.print("Use a longer ID to disambiguate.\n", .{});
        return error.AmbiguousMatch;
    }

    try storage.save_tasks(arena_alloc, io, dir, remaining.items);
    std.debug.print("Task deleted: {s}\n", .{tasks[found_indices.items[0]].title});
}

/// Displays full details of a task by ID. Supports partial ID matching (min 4 chars).
fn show_task(allocator: std.mem.Allocator, io: std.Io, task_id: []const u8, dir: std.Io.Dir) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_alloc = arena.allocator();

    const tasks = storage.load_tasks(arena_alloc, io, dir) catch {
        return error.InvalidItem;
    };

    var found_indices: std.ArrayList(usize) = .empty;
    defer found_indices.deinit(arena_alloc);

    for (tasks, 0..) |task, i| {
        const match = if (task_id.len >= 4 and task.id.len >= task_id.len)
            std.mem.eql(u8, task.id[0..task_id.len], task_id)
        else
            std.mem.eql(u8, task.id, task_id);

        if (match) {
            try found_indices.append(arena_alloc, i);
        }
    }

    if (found_indices.items.len == 0) {
        std.debug.print("No task found matching '{s}'\n", .{task_id});
        return error.InvalidItem;
    }

    if (found_indices.items.len > 1) {
        std.debug.print("Multiple tasks match '{s}':\n", .{task_id});
        for (found_indices.items) |idx| {
            const task = tasks[idx];
            std.debug.print("  - {s} [{s}]\n", .{ task.id[0..@min(8, task.id.len)], task.title });
        }
        std.debug.print("Use a longer ID to disambiguate.\n", .{});
        return error.AmbiguousMatch;
    }

    const task = tasks[found_indices.items[0]];
    try print_task(io, task, true);
}

test "add and list tasks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try add_task(allocator, io, "Test Task", tmp_dir.dir);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tasks = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
    try std.testing.expectEqual(tasks.len, 1);
    try std.testing.expectEqualStrings(tasks[0].title, "Test Task");
    try std.testing.expectEqual(tasks[0].status, .pending);
    try std.testing.expect(tasks[0].id.len > 0);
    try std.testing.expect(tasks[0].created_at > 0);
}

test "delete task" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try add_task(allocator, io, "To Delete", tmp_dir.dir);

    const task_id = blk: {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const tasks = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
        try std.testing.expectEqual(tasks.len, 1);
        break :blk try allocator.dupe(u8, tasks[0].id);
    };
    defer allocator.free(task_id);

    try delete_task(allocator, io, task_id, tmp_dir.dir);

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const tasks = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
        try std.testing.expectEqual(tasks.len, 0);
    }
}

test "delete nonexistent task returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try std.testing.expectError(error.InvalidItem, delete_task(allocator, io, "999", tmp_dir.dir));
}

test "list task with no file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Should not error — just prints "No tasks"
    try list_task(allocator, io, tmp_dir.dir);
}

test "mark_complete sets status and timestamps" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try add_task(allocator, io, "Complete Me", tmp_dir.dir);

    const tasks = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
    try mark_complete(allocator, io, tasks[0].id, tmp_dir.dir);

    const updated = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
    try std.testing.expectEqual(updated[0].status, .completed);
    try std.testing.expect(updated[0].updated_at != null);
    try std.testing.expect(updated[0].completed_at != null);
}

test "mark_complete nonexistent task returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try add_task(allocator, io, "Some Task", tmp_dir.dir);

    try std.testing.expectError(error.InvalidItem, mark_complete(allocator, io, "nonexistent-id", tmp_dir.dir));
}

test "add empty task name returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try std.testing.expectError(error.EmptyTitle, add_task(allocator, io, "", tmp_dir.dir));
}

test "multiple tasks have unique ids" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try add_task(allocator, io, "First", tmp_dir.dir);
    try add_task(allocator, io, "Second", tmp_dir.dir);
    try add_task(allocator, io, "Third", tmp_dir.dir);

    const tasks = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
    try std.testing.expectEqual(tasks.len, 3);
    try std.testing.expect(!std.mem.eql(u8, tasks[0].id, tasks[1].id));
    try std.testing.expect(!std.mem.eql(u8, tasks[1].id, tasks[2].id));
    try std.testing.expect(!std.mem.eql(u8, tasks[0].id, tasks[2].id));
}

test "list tasks with mixed statuses" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try add_task(allocator, io, "Pending Task", tmp_dir.dir);
    try add_task(allocator, io, "Done Task", tmp_dir.dir);

    const tasks = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
    try mark_complete(allocator, io, tasks[1].id, tmp_dir.dir);

    const updated = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
    try std.testing.expectEqual(updated[0].status, .pending);
    try std.testing.expectEqual(updated[1].status, .completed);
}
