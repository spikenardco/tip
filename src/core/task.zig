const std = @import("std");
const models = @import("models.zig");
const storage = @import("../storage/json.zig");
const generate = @import("../utils/generate.zig");
const ansi = @import("../utils/ansi.zig");
const vault = @import("./vault.zig");
const zqlite = @import("zqlite");

fn now_seconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

pub const AddFields = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    due_date: ?i64 = null,
    assigned_to: ?[]const u8 = null,
};

pub const EditFields = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    due_date: ?i64 = null,
    assigned_to: ?[]const u8 = null,
};

pub const Tasks = struct {
    db: *zqlite.Conn,
    io: std.Io,

    fn parse_status(text: []const u8) models.Task.Status {
        if (std.mem.eql(u8, text, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, text, "completed")) return .completed;
        return .pending;
    }

    fn parse_priority(text: []const u8) ?models.Task.Priority {
        if (std.mem.eql(u8, text, "low")) return .low;
        if (std.mem.eql(u8, text, "medium")) return .medium;
        if (std.mem.eql(u8, text, "high")) return .high;
        return null;
    }

    fn scan_task(row: zqlite.Row) models.Task {
        return .{
            .id = row.text(0),
            .title = row.text(1),
            .description = row.nullableText(2),
            .status = parse_status(row.text(3)),
            .priority = if (row.nullableText(4)) |p| parse_priority(p) else null,
            .due_date = row.get(?i64, 5),
            .assigned_to = row.nullableText(6),
            .created_at = row.int(7),
            .updated_at = row.get(?i64, 8),
            .completed_at = row.get(?i64, 9),
        };
    }

    pub fn add(self: *Tasks, args: AddFields) !models.Task {
        const id = try generate.generate_id(std.heap.page_allocator, self.io);
        defer std.heap.page_allocator.free(id);

        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();

        try self.db.exec(
            "INSERT INTO tasks (id, title, description, status, priority, due_date, assigned_to, created_at) VALUES (?, ?, ?, 'pending', ?, ?, ?, ?)",
            .{ id, args.title, args.description, args.priority, args.due_date, args.assigned_to, now },
        );

        // Read back to return a fully populated struct
        const row = (try self.db.row("SELECT * FROM tasks WHERE id = ?", .{id})) orelse return error.StorageFailure;
        return scan_task(row);
    }

    pub fn list(self: *Tasks, allocator: std.mem.Allocator) ![]models.Task {
        var result = try self.db.rows("SELECT * FROM tasks ORDER BY created_at ASC", .{});
        defer result.deinit();

        var tasks = std.ArrayList(models.Task).empty;
        errdefer tasks.deinit(allocator);

        while (try result.next()) |row| {
            try tasks.append(allocator, scan_task(row));
        }
        return try tasks.toOwnedSlice(allocator);
    }
};

pub const TaskArgs = struct {
    list: bool = false,
    subcommand: ?union(enum) {
        add: struct {
            title: []const u8,
            desc: ?[]const u8 = null,
        },
        // edit: struct {
        //     id: []const u8,
        //     title: []const u8,
        //     desc: ?[]const u8 = null,
        // },
        // delete: struct {
        //     id: []const u8,
        // },
        // show: struct {
        //     id: []const u8,
        // },
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

pub fn dispatch_task_command(io: std.Io, environ: std.process.Environ, args: TaskArgs) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var v = vault.Vault.open(allocator, io, environ) catch return error.StorageFailure;
    defer v.close();

    // var dir = storage.open_data_dir(allocator, io, environ) catch return error.StorageFailure;
    // defer dir.close(io);

    // if (args.list) return list_task(allocator, io, dir);

    if (args.subcommand) |subcommand| {
        switch (subcommand) {
            .add => |a| _ = try v.tasks.add(.{ .title = a.title, .description = a.desc }),
            // .edit => |e| try edit_task(allocator, io, dir, e.id, e.title, e.desc orelse ""),
            // .delete => |del| try delete_task(allocator, io, del.id, dir),
            // .show => |s| try show_task(allocator, io, s.id, dir),
        }
    } else {
        std.debug.print("{s}\n", .{TaskArgs.help});
    }
}

pub fn add_task(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    title: []const u8,
    description: ?[]const u8,
) !void {
    if (title.len == 0) return error.EmptyTitle;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const existing = storage.load_tasks(arena.allocator(), io, dir) catch return error.StorageFailure;

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

    storage.save_tasks(arena.allocator(), io, dir, tasks.items) catch return error.StorageFailure;
}

pub fn list_task(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tasks = storage.load_tasks(arena.allocator(), io, dir) catch return error.StorageFailure;

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
        std.debug.print("{s}Pending{s} ({d})\n", .{ ansi.ansi_code(.cyan), ansi.ansi_code(.reset), pending.items.len });
        for (pending.items) |task| {
            try print_task(io, task, false);
        }
        std.debug.print("\n", .{});
    }

    if (in_progress.items.len > 0) {
        std.debug.print("{s}In Progress{s} ({d})\n", .{ ansi.ansi_code(.cyan), ansi.ansi_code(.reset), in_progress.items.len });
        for (in_progress.items) |task| {
            try print_task(io, task, false);
        }
        std.debug.print("\n", .{});
    }

    if (completed.items.len > 0) {
        std.debug.print("{s}Completed{s} ({d})\n", .{ ansi.ansi_code(.green), ansi.ansi_code(.reset), completed.items.len });
        for (completed.items) |task| {
            try print_task(io, task, false);
        }
    }
}

fn print_task(io: std.Io, task: models.Task, detailed: bool) !void {
    const c_status = ansi.status_color(task.status);
    const c_reset = ansi.ansi_code(.reset);
    const compact_id = if (task.id.len > 8) task.id[0..8] else task.id;

    if (detailed) {
        std.debug.print("{s}=== Task Details ==={s}\n\n", .{ ansi.ansi_code(.cyan), c_reset });
        std.debug.print("ID:          {s}\n", .{task.id});
        std.debug.print("Title:       {s}\n", .{task.title});

        if (task.description) |desc| {
            std.debug.print("Description: {s}\n", .{desc});
        } else {
            std.debug.print("Description: -\n", .{});
        }

        std.debug.print("Status:      {s}{s}{s}\n", .{ ansi.ansi_code(c_status), ansi.status_icon(task.status), c_reset });

        if (task.priority) |p| {
            std.debug.print("Priority:    {s}{s}{s}\n", .{ ansi.ansi_code(ansi.priority_color(task.priority)), ansi.priority_glyph(p), c_reset });
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
        std.debug.print("  {s}{s}{s} ", .{ ansi.ansi_code(c_status), ansi.status_icon(task.status), c_reset });
        if (task.priority) |p| {
            std.debug.print("{s} ", .{ansi.priority_glyph(p)});
        }
        std.debug.print("{s}\n", .{task.title});

        if (task.description) |desc| {
            std.debug.print("      {s}desc:{s} {s}\n", .{ ansi.ansi_code(.yellow), c_reset, desc });
        }

        if (task.due_date) |due| {
            const now = now_seconds(io);
            if (due < now) {
                std.debug.print("      {s}Due: {d} (overdue){s}\n", .{ ansi.ansi_code(.red), due, c_reset });
            } else {
                std.debug.print("      {s}Due: {d}{s}\n", .{ ansi.ansi_code(.yellow), due, c_reset });
            }
        }

        if (task.status == .completed) {
            if (task.completed_at) |completed| {
                std.debug.print("      {s}Completed: {d}{s}\n", .{ ansi.ansi_code(.green), completed, c_reset });
            }
        }

        std.debug.print("      {s}ID: {s}{s}\n", .{ ansi.ansi_code(.yellow), compact_id, c_reset });
    }
}

pub fn mark_complete(allocator: std.mem.Allocator, io: std.Io, task_id: []const u8, dir: std.Io.Dir) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tasks = storage.load_tasks(arena.allocator(), io, dir) catch return error.StorageFailure;

    for (tasks) |*task| {
        if (std.mem.eql(u8, task.id, task_id)) {
            task.status = .completed;
            task.updated_at = now_seconds(io);
            task.completed_at = now_seconds(io);
            storage.save_tasks(arena.allocator(), io, dir, tasks) catch return error.StorageFailure;
            return;
        }
    }

    return error.TaskNotFound;
}

pub fn edit_task(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    task_id: []const u8,
    title: []const u8,
    desc: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const existing = storage.load_tasks(arena.allocator(), io, dir) catch return error.StorageFailure;

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
            storage.save_tasks(arena.allocator(), io, dir, existing) catch return error.StorageFailure;
            return;
        }
    }

    return error.TaskNotFound;
}

pub fn delete_task(allocator: std.mem.Allocator, io: std.Io, task_id: []const u8, dir: std.Io.Dir) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_alloc = arena.allocator();

    const tasks = storage.load_tasks(arena_alloc, io, dir) catch return error.StorageFailure;

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

    if (found_indices.items.len == 0) return error.TaskNotFound;

    if (found_indices.items.len > 1) return error.AmbiguousPrefix;

    storage.save_tasks(arena_alloc, io, dir, remaining.items) catch return error.StorageFailure;
    std.debug.print("Task deleted: {s}\n", .{tasks[found_indices.items[0]].title});
}

/// Displays full details of a task by ID. Supports partial ID matching (min 4 chars).
fn show_task(allocator: std.mem.Allocator, io: std.Io, task_id: []const u8, dir: std.Io.Dir) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_alloc = arena.allocator();

    const tasks = storage.load_tasks(arena_alloc, io, dir) catch return error.StorageFailure;

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

    if (found_indices.items.len == 0) return error.TaskNotFound;

    if (found_indices.items.len > 1) return error.AmbiguousPrefix;

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

    try std.testing.expectError(error.TaskNotFound, delete_task(allocator, io, "999", tmp_dir.dir));
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

    try std.testing.expectError(error.TaskNotFound, mark_complete(allocator, io, "nonexistent-id", tmp_dir.dir));
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
