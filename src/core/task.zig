const std = @import("std");
const models = @import("models.zig");
const generate = @import("../utils/generate.zig");
const ansi = @import("../utils/ansi.zig");
const zqlite = @import("zqlite");
const migrate = @import("../internal/database/migrate.zig");

fn now_seconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

const AddFields = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    priority: ?models.Task.Priority = .low,
    due_date: ?i64 = null,
    assigned_to: ?[]const u8 = null,
};

const EditFields = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    priority: ?models.Task.Priority = null,
    due_date: ?i64 = null,
    assigned_to: ?[]const u8 = null,
    status: ?models.Task.Status = null,
};

pub const Tasks = struct {
    conn: zqlite.Conn,
    io: std.Io,
    allocator: std.mem.Allocator,

    fn parse_status(text: []const u8) !models.Task.Status {
        return std.meta.stringToEnum(models.Task.Status, text) orelse return error.StorageFailure;
    }

    fn parse_priority(text: []const u8) ?models.Task.Priority {
        return std.meta.stringToEnum(models.Task.Priority, text);
    }

    fn scan_task(self: Tasks, row: zqlite.Row) !models.Task {
        const status = try parse_status(row.text(3));
        const priority = parse_priority(row.text(4));

        return .{
            .id = try self.allocator.dupe(u8, row.text(0)),
            .title = try self.allocator.dupe(u8, row.text(1)),
            .description = if (row.nullableText(2)) |value| try self.allocator.dupe(u8, value) else null,
            .status = status,
            .priority = priority,
            .due_date = row.get(?i64, 5),
            .assigned_to = if (row.nullableText(6)) |value| try self.allocator.dupe(u8, value) else null,
            .created_at = row.int(7),
            .updated_at = row.get(?i64, 8),
            .completed_at = row.get(?i64, 9),
        };
    }

    pub fn add(self: Tasks, args: AddFields) !models.Task {
        if (std.mem.trim(u8, args.title, " \t\n\r").len == 0) return error.EmptyTitle;

        const id = (generate.generate_id(self.io))[0..];
        const now = now_seconds(self.io);

        try self.conn.exec(
            \\INSERT INTO tasks (
            \\    id, title, description, status,
            \\    priority, due_date, assigned_to, created_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ,
            .{
                id,
                args.title,
                args.description,
                @tagName(models.Task.Status.pending),
                @tagName(args.priority orelse .low),
                args.due_date,
                args.assigned_to,
                now,
            },
        );

        const row = (try self.conn.row("SELECT * FROM tasks WHERE id = ?", .{id})) orelse return error.StorageFailure;
        defer row.deinit();

        return try self.scan_task(row);
    }

    pub fn edit(self: Tasks, id: []const u8, fields: EditFields) !void {
        if ((try self.conn.row("SELECT id FROM tasks WHERE id = ?", .{id})) == null)
            return error.TaskNotFound;

        const now = now_seconds(self.io);

        if (fields.title) |v| {
            try self.conn.exec("UPDATE tasks SET title = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
        }
        if (fields.description) |v| {
            try self.conn.exec("UPDATE tasks SET description = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
        }
        if (fields.priority) |v| {
            try self.conn.exec("UPDATE tasks SET priority = ?, updated_at = ? WHERE id = ?", .{ @tagName(v), now, id });
        }
        if (fields.due_date) |v| {
            try self.conn.exec("UPDATE tasks SET due_date = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
        }
        if (fields.assigned_to) |v| {
            try self.conn.exec("UPDATE tasks SET assigned_to = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
        }
        if (fields.status) |v| {
            try self.conn.exec("UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?", .{ @tagName(v), now, id });
        }
    }

    pub fn list(self: Tasks) ![]models.Task {
        var result = try self.conn.rows("SELECT * FROM tasks ORDER BY created_at ASC", .{});
        defer result.deinit();

        var tasks = std.ArrayList(models.Task).empty;
        errdefer tasks.deinit(self.allocator);

        while (result.next()) |row| {
            try tasks.append(self.allocator, try self.scan_task(row));
        }

        if (result.err) |err| return err;
        return try tasks.toOwnedSlice(self.allocator);
    }

    pub fn delete(self: Tasks, id: []const u8) !void {
        try self.conn.exec("DELETE FROM tasks WHERE id = ?", .{id});

        if (self.conn.changes() == 0) return error.TaskNotFound;
    }

    pub fn get(self: *Tasks, id: []const u8) !models.Task {
        if (try self.conn.row("SELECT * FROM tasks WHERE id = ?", .{id})) |row| {
            return scan_task(row);
        }

        return error.TaskNotFound;
    }
};

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
        \\
        \\Examples:
        \\  tip task --list
        \\  tip task add --title="Review code"
        \\
    ;
};

pub fn dispatch(tasks: Tasks, args: TaskArgs) !void {
    if (args.list) {
        const items = try tasks.list();
        return print_task_list(tasks.io, items);
    }

    if (args.subcommand) |subcommand| {
        switch (subcommand) {
            .add => |fields| _ = try tasks.add(.{
                .title = fields.title,
                .description = fields.desc orelse null,
            }),
            .edit => |fields| try tasks.edit(fields.id, .{
                .title = fields.title,
                .description = fields.desc orelse null,
            }),
            .delete => |fields| try tasks.delete(fields.id),
        }
        return;
    }

    std.debug.print("{s}\n", .{TaskArgs.help});
}

fn print_task_list(io: std.Io, tasks: []const models.Task) !void {
    if (tasks.len == 0) {
        std.debug.print("No tasks\n", .{});
        return;
    }

    const Group = struct {
        status: models.Task.Status,
        label: []const u8,
        color: ansi.Ansi,
    };
    const groups = [_]Group{
        .{ .status = .pending, .label = "Pending", .color = .cyan },
        .{ .status = .in_progress, .label = "In Progress", .color = .cyan },
        .{ .status = .completed, .label = "Completed", .color = .green },
    };

    for (groups) |group| {
        var count: usize = 0;
        for (tasks) |item| {
            if (item.status == group.status) count += 1;
        }
        if (count == 0) continue;

        std.debug.print("{s}{s}{s} ({d})\n", .{
            ansi.ansi_code(group.color),
            group.label,
            ansi.ansi_code(.reset),
            count,
        });

        for (tasks) |item| {
            if (item.status == group.status) {
                try print_task_summary(io, item);
            }
        }
        std.debug.print("\n", .{});
    }
}

fn print_task_summary(io: std.Io, task: models.Task) !void {
    const c_status = ansi.status_color(task.status);
    const c_reset = ansi.ansi_code(.reset);
    const compact_id = if (task.id.len > 8) task.id[0..8] else task.id;
    const now = now_seconds(io);

    std.debug.print("  {s}{s}{s} ", .{ ansi.ansi_code(c_status), ansi.status_icon(task.status), c_reset });
    if (task.priority) |p| {
        std.debug.print("{s} ", .{ansi.priority_glyph(p)});
    }
    std.debug.print("{s}\n", .{task.title});

    if (task.description) |desc| {
        std.debug.print("      {s}desc:{s} {s}\n", .{ ansi.ansi_code(.yellow), c_reset, desc });
    }

    if (task.due_date) |due| {
        if (due < now) {
            std.debug.print("      {s}Due: {d} (overdue){s}\n", .{ ansi.ansi_code(.red), due, c_reset });
        } else {
            std.debug.print("      {s}Due: {d}{s}\n", .{ ansi.ansi_code(.yellow), due, c_reset });
        }
    }

    if (task.status == .completed) {
        if (task.completed_at) |completed_at| {
            std.debug.print("      {s}Completed: {d}{s}\n", .{ ansi.ansi_code(.green), completed_at, c_reset });
        }
    }

    std.debug.print("      {s}ID: {s}{s}\n", .{ ansi.ansi_code(.yellow), compact_id, c_reset });
}

// ============== Tests ==============

test "add new task" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try migrate.run_migrations(conn);

    const tasks: Tasks = .{ .io = io, .allocator = allocator, .conn = conn };

    const task = try tasks.add(.{ .title = "first task" });

    try std.testing.expectEqualStrings(task.title, "first task");
    try std.testing.expectEqual(task.status, .pending);
    try std.testing.expect(task.id.len > 0);
    try std.testing.expect(task.created_at > 0);
}

test "update tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try migrate.run_migrations(conn);

    const tasks: Tasks = .{ .io = io, .allocator = allocator, .conn = conn };

    const task = try tasks.add(.{ .title = "first task" });
    try std.testing.expectEqualStrings(task.title, "first task");

    try tasks.edit(task.id, .{ .title = "something new" });
    const tasks2 = try tasks.list();
    try std.testing.expectEqualStrings(tasks2[0].title, "something new");
}

test "delete task" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try migrate.run_migrations(conn);

    const tasks = Tasks{ .conn = conn, .io = io, .allocator = allocator };

    const task1 = try tasks.add(.{ .title = "first" });
    const task2 = try tasks.add(.{ .title = "second" });

    var total_tasks = try tasks.list();
    try std.testing.expectEqual(total_tasks.len, 2);

    try tasks.delete(task1.id);

    total_tasks = try tasks.list();
    try std.testing.expectEqual(total_tasks.len, 1);
    try std.testing.expectEqualStrings(total_tasks[0].id, task2.id);
}

test "delete nonexistent task returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try migrate.run_migrations(conn);

    const tasks = Tasks{ .conn = conn, .io = io, .allocator = allocator };

    try std.testing.expectError(error.TaskNotFound, tasks.delete("000"));
}

test "list tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try migrate.run_migrations(conn);

    const tasks = Tasks{ .conn = conn, .io = io, .allocator = allocator };

    var total_tasks = try tasks.list();
    try std.testing.expectEqual(total_tasks.len, 0);

    _ = try tasks.add(.{ .title = "adding" });

    total_tasks = try tasks.list();
    try std.testing.expectEqual(total_tasks.len, 1);
}

test "mark complete and timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try migrate.run_migrations(conn);

    const tasks = Tasks{ .conn = conn, .io = io, .allocator = allocator };

    const task1 = try tasks.add(.{ .title = "complete me" });
    try std.testing.expectEqual(task1.status, .pending);

    try tasks.edit(task1.id, .{ .status = .completed });

    const all_tasks = try tasks.list();
    try std.testing.expectEqual(all_tasks.len, 1);

    try std.testing.expectEqual(all_tasks[0].status, .completed);
    try std.testing.expect(all_tasks[0].updated_at.? > task1.updated_at orelse 0);
}

test "mark complete nonexistent task returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try migrate.run_migrations(conn);

    const tasks = Tasks{ .conn = conn, .io = io, .allocator = allocator };

    try std.testing.expectError(error.TaskNotFound, tasks.edit("000", .{ .status = .completed }));
}

test "add empty task title returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try migrate.run_migrations(conn);

    const tasks = Tasks{ .conn = conn, .io = io, .allocator = allocator };

    try std.testing.expectError(error.EmptyTitle, tasks.add(.{ .title = "" }));
    try std.testing.expectError(error.EmptyTitle, tasks.add(.{ .title = "  " }));
}
