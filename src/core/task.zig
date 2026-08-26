const std = @import("std");
const models = @import("models.zig");
const generate = @import("../utils/generate.zig");
const output = @import("../utils/output.zig");
const zqlite = @import("zqlite");
const migrate = @import("../internal/database/migrate.zig");

fn now_seconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

fn status_icon(status: models.Task.Status) []const u8 {
    return switch (status) {
        .pending => "○",
        .in_progress => "⟳",
        .completed => "✓",
    };
}

fn status_label(status: models.Task.Status) []const u8 {
    return switch (status) {
        .pending => "Pending",
        .in_progress => "In Progress",
        .completed => "Completed",
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

fn priority_label(priority: models.Task.Priority) []const u8 {
    return switch (priority) {
        .high => "High",
        .medium => "Medium",
        .low => "Low",
    };
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
            \\    priority, due_date, assigned_to, created_at, updated_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, unixepoch())
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

        const row = (try self.conn.row(
            \\SELECT id, title, description, status, priority,
            \\       due_date, assigned_to, created_at, updated_at, completed_at
            \\FROM tasks WHERE id = ?
        , .{id})) orelse return error.StorageFailure;
        defer row.deinit();

        return try self.scan_task(row);
    }

    pub fn edit(self: Tasks, id: []const u8, fields: EditFields) !void {
        if (try self.conn.row("SELECT id FROM tasks WHERE id = ?", .{id})) |row| {
            row.deinit();
        } else return error.TaskNotFound;

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
        var result = try self.conn.rows(
            \\SELECT id, title, description, status, priority,
            \\       due_date, assigned_to, created_at, updated_at, completed_at
            \\FROM tasks ORDER BY created_at ASC
        , .{});
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

    pub fn get(self: Tasks, id: []const u8) !models.Task {
        if (try self.conn.row(
            \\SELECT id, title, description, status, priority,
            \\       due_date, assigned_to, created_at, updated_at, completed_at
            \\FROM tasks WHERE id = ?
        , .{id})) |row| {
            defer row.deinit();
            return self.scan_task(row);
        }

        return error.TaskNotFound;
    }

    pub fn complete(self: Tasks, id: []const u8) !void {
        try self.conn.exec("UPDATE tasks SET status = 'completed', updated_at = unixepoch() WHERE id = ?", .{id});

        if (self.conn.changes() == 0) return error.TaskNotFound;
    }

    pub fn start(self: Tasks, id: []const u8) !void {
        try self.conn.exec("UPDATE tasks SET status = 'in_progress', updated_at = unixepoch() WHERE id = ?", .{id});

        if (self.conn.changes() == 0) return error.TaskNotFound;
    }

    pub fn show(self: Tasks, id: []const u8) !void {
        if (try self.conn.row("SELECT * FROM tasks WHERE id = ?", .{id})) |row| {
            defer row.deinit();
            const task = try self.scan_task(row);
            try self.print_task_detail(task);
        } else {
            return error.TaskNotFound;
        }
    }

    fn print_task_list(self: Tasks, tasks: []const models.Task) !void {
        if (tasks.len == 0) {
            std.debug.print("No tasks\n", .{});
            return;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const columns = [_]output.Column{
            .{ .header = "ID" },
            .{ .header = "Status" },
            .{ .header = "Priority" },
            .{ .header = "Title" },
            .{ .header = "Created" },
        };

        var rows = std.ArrayList([]const []const u8).empty;
        defer rows.deinit(allocator);

        for (tasks) |t| {
            const status_str = try std.fmt.allocPrint(allocator, "{s} {s}", .{ status_icon(t.status), status_label(t.status) });
            const priority_str = if (t.priority) |p|
                try std.fmt.allocPrint(allocator, "{s} {s}", .{ priority_glyph(p), priority_label(p) })
            else
                "";
            const created_str = try std.fmt.allocPrint(allocator, "{d}", .{t.created_at});
            const row = try allocator.alloc([]const u8, 5);
            row[0] = t.id;
            row[1] = status_str;
            row[2] = priority_str;
            row[3] = t.title;
            row[4] = created_str;
            try rows.append(allocator, row);
        }

        output.render_table(&columns, rows.items);
    }

    fn print_task_detail(self: Tasks, task: models.Task) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var fields = std.ArrayList(output.Field).empty;
        defer fields.deinit(allocator);

        try fields.append(allocator, .{ .label = "ID", .value = task.id });
        try fields.append(allocator, .{ .label = "Title", .value = task.title });

        if (task.description) |d| {
            try fields.append(allocator, .{ .label = "Description", .value = d });
        }

        const status_str = try std.fmt.allocPrint(allocator, "{s} {s}", .{ status_icon(task.status), status_label(task.status) });
        try fields.append(allocator, .{ .label = "Status", .value = status_str });

        if (task.priority) |p| {
            const priority_str = try std.fmt.allocPrint(allocator, "{s} {s}", .{ priority_glyph(p), priority_label(p) });
            try fields.append(allocator, .{ .label = "Priority", .value = priority_str });
        }

        if (task.due_date) |due| {
            const due_str = try std.fmt.allocPrint(allocator, "{d}", .{due});
            try fields.append(allocator, .{ .label = "Due", .value = due_str });
        }

        if (task.assigned_to) |a| {
            try fields.append(allocator, .{ .label = "Assigned To", .value = a });
        }

        const created_str = try std.fmt.allocPrint(allocator, "{d}", .{task.created_at});
        try fields.append(allocator, .{ .label = "Created", .value = created_str });

        if (task.updated_at) |u| {
            const updated_str = try std.fmt.allocPrint(allocator, "{d}", .{u});
            try fields.append(allocator, .{ .label = "Updated", .value = updated_str });
        }

        if (task.completed_at) |c| {
            const completed_str = try std.fmt.allocPrint(allocator, "{d}", .{c});
            try fields.append(allocator, .{ .label = "Completed", .value = completed_str });
        }

        output.render_detail(fields.items);
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
        complete: struct {
            id: []const u8,
        },
        start: struct {
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
        \\  complete
        \\      --id=<id>             Task ID to complete
        \\  start
        \\      --id=<id>             Task ID to start
        \\  show
        \\      --id=<id>             Show task details
        \\Examples:
        \\  tip task --list
        \\  tip task add --title="Review code"
        \\
    ;
};

pub fn dispatch(tasks: Tasks, args: TaskArgs) !void {
    if (args.list) {
        const items = try tasks.list();
        return tasks.print_task_list(items);
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
            .complete => |fields| try tasks.complete(fields.id),
            .start => |fields| try tasks.start(fields.id),
            .show => |fields| try tasks.show(fields.id),
        }
        return;
    }

    std.debug.print("{s}\n", .{TaskArgs.help});
}

// ============== Tests ==============

const TestTasks = struct {
    arena: *std.heap.ArenaAllocator,
    conn: zqlite.Conn,
    tasks: Tasks,

    fn init() !TestTasks {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        errdefer std.testing.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();

        const allocator = arena.allocator();
        const conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
        errdefer conn.close();

        try migrate.run_migrations(conn);

        return .{
            .arena = arena,
            .conn = conn,
            .tasks = .{
                .conn = conn,
                .io = std.testing.io,
                .allocator = allocator,
            },
        };
    }

    fn deinit(self: *TestTasks) void {
        self.conn.close();
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }
};

test "add new task" {
    var fixture = try TestTasks.init();
    defer fixture.deinit();

    const task = try fixture.tasks.add(.{ .title = "first task" });

    try std.testing.expectEqualStrings(task.title, "first task");
    try std.testing.expectEqual(task.status, .pending);
    try std.testing.expect(task.id.len > 0);
    try std.testing.expect(task.created_at > 0);
}

test "update tasks" {
    var fixture = try TestTasks.init();
    defer fixture.deinit();

    const task = try fixture.tasks.add(.{ .title = "first task" });
    try std.testing.expectEqualStrings(task.title, "first task");

    try fixture.tasks.edit(task.id, .{ .title = "something new" });
    const tasks2 = try fixture.tasks.list();
    try std.testing.expectEqualStrings(tasks2[0].title, "something new");
}

test "delete task" {
    var fixture = try TestTasks.init();
    defer fixture.deinit();

    const task1 = try fixture.tasks.add(.{ .title = "first" });
    const task2 = try fixture.tasks.add(.{ .title = "second" });

    var total_tasks = try fixture.tasks.list();
    try std.testing.expectEqual(total_tasks.len, 2);

    try fixture.tasks.delete(task1.id);

    total_tasks = try fixture.tasks.list();
    try std.testing.expectEqual(total_tasks.len, 1);
    try std.testing.expectEqualStrings(total_tasks[0].id, task2.id);
}

test "delete nonexistent task returns error" {
    var fixture = try TestTasks.init();
    defer fixture.deinit();

    try std.testing.expectError(error.TaskNotFound, fixture.tasks.delete("000"));
}

test "list tasks" {
    var fixture = try TestTasks.init();
    defer fixture.deinit();

    var total_tasks = try fixture.tasks.list();
    try std.testing.expectEqual(total_tasks.len, 0);

    _ = try fixture.tasks.add(.{ .title = "adding" });

    total_tasks = try fixture.tasks.list();
    try std.testing.expectEqual(total_tasks.len, 1);
}

test "explicit task columns scan every model field" {
    var fixture = try TestTasks.init();
    defer fixture.deinit();

    try fixture.conn.exec(
        "INSERT INTO tasks (id, title, description, status, priority, due_date, assigned_to, created_at, updated_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        .{ "001", "Task", "Details", "in_progress", "high", @as(i64, 2000), "Ben", @as(i64, 1000), @as(i64, 1500), @as(i64, 1800) },
    );

    const task = try fixture.tasks.get("001");
    try std.testing.expectEqualStrings("001", task.id);
    try std.testing.expectEqualStrings("Task", task.title);
    try std.testing.expectEqualStrings("Details", task.description.?);
    try std.testing.expectEqual(task.status, .in_progress);
    try std.testing.expectEqual(task.priority.?, .high);
    try std.testing.expectEqual(@as(i64, 2000), task.due_date.?);
    try std.testing.expectEqualStrings("Ben", task.assigned_to.?);
    try std.testing.expectEqual(@as(i64, 1000), task.created_at);
    try std.testing.expectEqual(@as(i64, 1500), task.updated_at.?);
    try std.testing.expectEqual(@as(i64, 1800), task.completed_at.?);
}

test "mark complete and timestamps" {
    var fixture = try TestTasks.init();
    defer fixture.deinit();

    const task1 = try fixture.tasks.add(.{ .title = "complete me" });
    try std.testing.expectEqual(task1.status, .pending);

    try fixture.tasks.edit(task1.id, .{ .status = .completed });

    const all_tasks = try fixture.tasks.list();
    try std.testing.expectEqual(all_tasks.len, 1);

    try std.testing.expectEqual(all_tasks[0].status, .completed);
    try std.testing.expect(all_tasks[0].updated_at.? >= task1.updated_at orelse 0);
}

test "mark complete nonexistent task returns error" {
    var fixture = try TestTasks.init();
    defer fixture.deinit();

    try std.testing.expectError(error.TaskNotFound, fixture.tasks.edit("000", .{ .status = .completed }));
}

test "add empty task title returns error" {
    var fixture = try TestTasks.init();
    defer fixture.deinit();

    try std.testing.expectError(error.EmptyTitle, fixture.tasks.add(.{ .title = "" }));
    try std.testing.expectError(error.EmptyTitle, fixture.tasks.add(.{ .title = "  " }));
}

test "complete task" {
    var fixture = try TestTasks.init();
    defer fixture.deinit();

    const task1 = try fixture.tasks.add(.{ .title = "Test Task" });
    try fixture.tasks.complete(task1.id);

    const all_tasks = try fixture.tasks.list();
    try std.testing.expectEqual(all_tasks[0].status, .completed);
}

test "start task" {
    var fixture = try TestTasks.init();
    defer fixture.deinit();

    const task1 = try fixture.tasks.add(.{ .title = "Test Task" });
    try fixture.tasks.start(task1.id);

    const all_tasks = try fixture.tasks.list();
    try std.testing.expectEqual(all_tasks[0].status, .in_progress);
}

test "show task" {
    var fixture = try TestTasks.init();
    defer fixture.deinit();

    const task1 = try fixture.tasks.add(.{ .title = "Test Task" });
    try fixture.tasks.show(task1.id);

    try std.testing.expectError(error.TaskNotFound, fixture.tasks.show("001"));
}
