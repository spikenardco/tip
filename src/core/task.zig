const std = @import("std");
const models = @import("models.zig");
const storage = @import("../storage/json.zig");
const generate = @import("../utils/generate.zig");

const Ansi = enum {
    red,
    green,
    yellow,
    cyan,
    reset,
};

fn ansi_code(c: Ansi) []const u8 {
    return switch (c) {
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .cyan => "\x1b[36m",
        .reset => "\x1b[0m",
    };
}

fn priority_glyph(priority: ?models.Task.Priority) []const u8 {
    if (priority) |p| {
        return switch (p) {
            .high => "↑",
            .medium => "-",
            .low => "↓",
        };
    }
    return "";
}

fn priority_color(priority: ?models.Task.Priority) Ansi {
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

fn status_color(status: models.Task.Status) Ansi {
    return switch (status) {
        .pending => .reset,
        .in_progress => .cyan,
        .completed => .green,
    };
}

fn now_seconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

pub const TaskArgs = struct {
    list: bool = false,
    subcommand: ?union(enum) {
        add: struct {
            title: []const u8,
            desc: ?[]const u8 = null,
        },
        edit: struct {
            id: []const u8,
            title: []const u8,
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
        \\Usage:
        \\  tip task <subcommand> [args] [flags]
        \\
        \\Options:
        \\  --list                    List all tasks
        \\
        \\Commands:
        \\  add
        \\      --title=<title>       Add a new task
        \\      --desc=<description>  Task description
        \\  edit
        \\      --id=<id>             Task ID to edit
        \\      --title=<title>       New title
        \\      --desc=<description>  New description
        \\  delete
        \\      --id=<id>             Task ID to delete
        \\  show
        \\      --id=<id>             Show task details
        \\
        \\Examples:
        \\  tip task --list
        \\  tip task add --title="Review code"
        \\
    ;
};

pub fn dispatch_task_command(io: std.Io, environ: std.process.Environ, args: TaskArgs) void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dir = storage.open_data_dir(allocator, io, environ) catch {
        std.debug.print("Failed to open config directory\n", .{});
        return;
    };
    defer dir.close(io);

    if (args.list) {
        list_task(allocator, io, dir) catch {};
        return;
    }

    if (args.subcommand) |subcommand| {
        switch (subcommand) {
            .add => |a| add_task(allocator, io, dir, a.title, a.desc) catch {
                std.debug.print("Failed to add task\n", .{});
                return;
            },
            .edit => |e| edit_task(allocator, io, dir, e.id, e.title, e.desc orelse "") catch {
                std.debug.print("Failed to update task\n", .{});
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

fn add_task(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    title: []const u8,
    description: ?[]const u8,
) !void {
    if (title.len == 0) return error.EmptyTitle;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const existing = storage.load_tasks(arena.allocator(), io, dir) catch &[_]models.Task{};

    var tasks: std.ArrayList(models.Task) = .empty;
    defer tasks.deinit(allocator);
    for (existing) |t| {
        tasks.append(allocator, t) catch continue;
    }

    const id = try generate.generate_id(allocator, io);
    defer allocator.free(id);
    try tasks.append(allocator, .{
        .status = .pending,
        .id = id[0..],
        .title = title,
        .description = description orelse "",
        .created_at = now_seconds(io),
    });

    try storage.save_tasks(arena.allocator(), io, dir, tasks.items);
}

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
        std.debug.print("{s}Pending{s} ({d})\n", .{ ansi_code(.cyan), ansi_code(.reset), pending.items.len });
        for (pending.items) |task| {
            try print_task(io, task, false);
        }
        std.debug.print("\n", .{});
    }

    if (in_progress.items.len > 0) {
        std.debug.print("{s}In Progress{s} ({d})\n", .{ ansi_code(.cyan), ansi_code(.reset), in_progress.items.len });
        for (in_progress.items) |task| {
            try print_task(io, task, false);
        }
        std.debug.print("\n", .{});
    }

    if (completed.items.len > 0) {
        std.debug.print("{s}Completed{s} ({d})\n", .{ ansi_code(.green), ansi_code(.reset), completed.items.len });
        for (completed.items) |task| {
            try print_task(io, task, false);
        }
    }
}

fn print_task(io: std.Io, task: models.Task, detailed: bool) !void {
    const c_status = status_color(task.status);
    const c_reset = ansi_code(.reset);
    const compact_id = if (task.id.len > 8) task.id[0..8] else task.id;

    if (detailed) {
        std.debug.print("{s}=== Task Details ==={s}\n\n", .{ ansi_code(.cyan), c_reset });
        std.debug.print("ID:          {s}\n", .{task.id});
        std.debug.print("Title:       {s}\n", .{task.title});

        if (task.description) |desc| {
            std.debug.print("Description: {s}\n", .{desc});
        } else {
            std.debug.print("Description: -\n", .{});
        }

        std.debug.print("Status:      {s}{s}{s}\n", .{ ansi_code(c_status), status_icon(task.status), c_reset });

        if (task.priority) |p| {
            std.debug.print("Priority:    {s}{s}{s}\n", .{ ansi_code(priority_color(task.priority)), priority_glyph(p), c_reset });
        } else {
            std.debug.print("Priority:    -\n", .{});
        }

        if (task.due_date) |due| {
            const now = now_seconds(io);
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
        std.debug.print("  {s}{s}{s} ", .{ ansi_code(c_status), status_icon(task.status), c_reset });
        if (task.priority) |p| {
            std.debug.print("{s} ", .{priority_glyph(p)});
        }
        std.debug.print("{s}\n", .{task.title});

        if (task.description) |desc| {
            std.debug.print("      {s}desc:{s} {s}\n", .{ ansi_code(.yellow), c_reset, desc });
        }

        if (task.due_date) |due| {
            const now = now_seconds(io);
            if (due < now) {
                std.debug.print("      {s}Due: {d} (overdue){s}\n", .{ ansi_code(.red), due, c_reset });
            } else {
                std.debug.print("      {s}Due: {d}{s}\n", .{ ansi_code(.yellow), due, c_reset });
            }
        }

        if (task.status == .completed) {
            if (task.completed_at) |completed| {
                std.debug.print("      {s}Completed: {d}{s}\n", .{ ansi_code(.green), completed, c_reset });
            }
        }

        std.debug.print("      {s}ID: {s}{s}\n", .{ ansi_code(.yellow), compact_id, c_reset });
    }
}

fn mark_complete(allocator: std.mem.Allocator, io: std.Io, task_id: []const u8, dir: std.Io.Dir) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tasks = storage.load_tasks(arena.allocator(), io, dir) catch {
        return error.InvalidItem;
    };

    for (tasks) |*task| {
        if (std.mem.eql(u8, task.id, task_id)) {
            task.status = .completed;
            task.updated_at = now_seconds(io);
            task.completed_at = now_seconds(io);
            try storage.save_tasks(arena.allocator(), io, dir, tasks);
            return;
        }
    }

    std.debug.print("Item {s} does not exist!\n", .{task_id});
    return error.InvalidItem;
}

fn edit_task(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    task_id: []const u8,
    title: []const u8,
    desc: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const existing = try storage.load_tasks(arena.allocator(), io, dir);

    for (0..existing.len) |i| {
        const id = existing[i].id;
        const match = if (task_id.len >= 4 and id.len >= task_id.len)
            std.mem.eql(u8, id[0..task_id.len], task_id)
        else
            std.mem.eql(u8, id, task_id);

        if (match) {
            existing[i].title = title;
            existing[i].description = desc;
            existing[i].updated_at = now_seconds(io);
            try storage.save_tasks(arena.allocator(), io, dir, existing);
            return;
        }
    }

    std.debug.print("No task found matching '{s}'\n", .{task_id});
    return error.InvalidItem;
}

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

    try add_task(allocator, io, tmp_dir.dir, "Test Task", null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tasks = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
    try std.testing.expectEqual(tasks.len, 1);
    try std.testing.expectEqualStrings(tasks[0].title, "Test Task");
    try std.testing.expectEqual(tasks[0].status, .pending);
    try std.testing.expect(tasks[0].id.len > 0);
    try std.testing.expect(tasks[0].created_at > 0);
}

test "update tasks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try add_task(allocator, io, tmp_dir.dir, "Test Task", null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tasks = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
    try std.testing.expectEqual(tasks.len, 1);
    try std.testing.expectEqualStrings(tasks[0].title, "Test Task");

    // edit task
    try edit_task(allocator, io, tmp_dir.dir, tasks[0].id, "something new", "blank desc");
    // load all new tasks.
    const tasks2 = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
    try std.testing.expectEqualStrings(tasks2[0].description.?, "blank desc");
}

test "delete task" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try add_task(allocator, io, tmp_dir.dir, "Test Task", null);

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

    try add_task(allocator, io, tmp_dir.dir, "Complete Me", null);

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

    try add_task(allocator, io, tmp_dir.dir, "Some Task", null);

    try std.testing.expectError(error.InvalidItem, mark_complete(allocator, io, "nonexistent-id", tmp_dir.dir));
}

test "add empty task name returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try std.testing.expectError(error.EmptyTitle, add_task(allocator, io, tmp_dir.dir, "", null));
}

test "multiple tasks have unique ids" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try add_task(allocator, io, tmp_dir.dir, "First", null);
    try add_task(allocator, io, tmp_dir.dir, "Second", null);
    try add_task(allocator, io, tmp_dir.dir, "Third", null);

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

    try add_task(allocator, io, tmp_dir.dir, "Pending Task", null);
    try add_task(allocator, io, tmp_dir.dir, "Done Task", null);

    const tasks = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
    try mark_complete(allocator, io, tasks[1].id, tmp_dir.dir);

    const updated = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
    try std.testing.expectEqual(updated[0].status, .pending);
    try std.testing.expectEqual(updated[1].status, .completed);
}
