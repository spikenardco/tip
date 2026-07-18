const std = @import("std");
const zqlite = @import("zqlite");
const models = @import("../core/models.zig");
const db = @import("../internal/database/db.zig");
const generate = @import("../utils/generate.zig");
const task = @import("./task.zig");

pub const Vault = struct {
    db: *zqlite.Conn,
    io: std.Io,
    tasks: task.Tasks,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, data_path: []const u8) !Vault {
        try std.Io.Dir.cwd().createDirPath(io, data_path);

        const db_path = try std.fs.path.joinZ(allocator, &.{ data_path, "tip.db" });
        defer allocator.free(db_path);

        const conn = try allocator.create(zqlite.Conn);
        conn.* = try db.open(db_path);

        return Vault{
            .db = conn,
            .io = io,
            .tasks = .{ .db = conn, .io = io },
        };
    }

    pub fn close(self: *Vault) void {
        self.db.close();
    }

    // pub const Tasks = struct {
    //     vault: *Vault,

    //     fn now_seconds(io: std.Io) i64 {
    //         return std.Io.Timestamp.now(io, .real).toSeconds();
    //     }

    //     fn scan_task(row: zqlite.Row) models.Task {
    //         return .{
    //             .id = row.text(0),
    //             .title = row.text(1),
    //             .description = row.nullableText(2),
    //             .status = row.text(3),
    //             .priority = row.nullableText(4),
    //             .due_date = row.get(?i64, 5),
    //             .assigned_to = row.nullableText(6),
    //             .created_at = row.int(7),
    //             .updated_at = row.get(?i64, 8),
    //             .completed_at = row.get(?i64, 9),
    //         };
    //     }

    //     pub fn add(self: *Tasks, args: AddFields) !models.Task {
    //         const id = try generate.generate_id(std.heap.page_allocator, self.vault.io);
    //         defer std.heap.page_allocator.free(id);

    //         const now = now_seconds(self.vault.io);

    //         try self.vault.db.exec(
    //             "INSERT INTO tasks (id, title, description, status, priority, due_date, assigned_to, created_at) VALUES (?, ?, ?, 'pending', ?, ?, ?, ?)",
    //             .{ id, args.title, args.description, args.priority, args.due_date, args.assigned_to, now },
    //         );

    //         // Read back to return a fully populated struct
    //         const row = (try self.vault.db.row("SELECT * FROM tasks WHERE id = ?", .{id})) orelse return error.StorageFailure;
    //         return scan_task(row);
    //     }

    //     pub fn list(self: *Tasks, allocator: std.mem.Allocator) ![]models.Task {
    //         var result = try self.vault.db.rows("SELECT * FROM tasks ORDER BY created_at ASC", .{});
    //         defer result.deinit();

    //         var tasks = std.ArrayList(models.Task).empty;
    //         errdefer tasks.deinit(allocator);

    //         while (try result.next()) |row| {
    //             try tasks.append(allocator, scan_task(row));
    //         }
    //         return try tasks.toOwnedSlice(allocator);
    //     }

    //     pub fn get_by_id(self: *Tasks, allocator: std.mem.Allocator, id: []const u8) !models.Task {
    //         // Exact match first
    //         if (try self.vault.db.row("SELECT * FROM tasks WHERE id = ?", .{id})) |row| {
    //             return scan_task(row);
    //         }

    //         // Prefix match: WHERE id LIKE 'prefix%'
    //         const pattern = try std.mem.concat(allocator, u8, &.{ id, "%" });
    //         defer allocator.free(pattern);

    //         var result = try self.vault.db.rows("SELECT * FROM tasks WHERE id LIKE ? ORDER BY id", .{pattern});
    //         defer result.deinit();

    //         var count: usize = 0;
    //         var first: ?models.Task = null;
    //         while (try result.next()) |row| {
    //             if (count == 0) first = scan_task(row);
    //             count += 1;
    //         }

    //         if (count == 0) return error.TaskNotFound;
    //         if (count > 1) return error.AmbiguousPrefix;
    //         return first.?;
    //     }

    //     pub fn edit(self: *Tasks, id: []const u8, fields: EditFields) !void {
    //         // Check task exists
    //         if ((try self.vault.db.row("SELECT id FROM tasks WHERE id = ?", .{id})) == null)
    //             return error.TaskNotFound;

    //         const now = now_seconds(self.vault.io);

    //         if (fields.title) |v| {
    //             try self.vault.db.exec("UPDATE tasks SET title = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
    //         }
    //         if (fields.description) |v| {
    //             try self.vault.db.exec("UPDATE tasks SET description = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
    //         }
    //         if (fields.priority) |v| {
    //             try self.vault.db.exec("UPDATE tasks SET priority = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
    //         }
    //         if (fields.due_date) |v| {
    //             try self.vault.db.exec("UPDATE tasks SET due_date = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
    //         }
    //         if (fields.assigned_to) |v| {
    //             try self.vault.db.exec("UPDATE tasks SET assigned_to = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
    //         }
    //     }

    //     pub fn delete(self: *Tasks, id: []const u8) !void {
    //         const changes = try self.vault.db.exec(
    //             "DELETE FROM tasks WHERE id = ?",
    //             .{id},
    //         );
    //         if (changes == 0) return error.TaskNotFound;
    //     }

    //     pub fn complete(self: *Tasks, id: []const u8) !void {
    //         const now = now_seconds(self.vault.io);
    //         const changes = try self.vault.db.exec(
    //             "UPDATE tasks SET status = 'completed', updated_at = ?, completed_at = ? WHERE id = ?",
    //             .{ now, now, id },
    //         );
    //         if (changes == 0) return error.TaskNotFound;
    //     }

    //     pub fn start(self: *Tasks, id: []const u8) !void {
    //         const now = now_seconds(self.vault.io);
    //         const changes = try self.vault.db.exec(
    //             "UPDATE tasks SET status = 'in_progress', updated_at = ? WHERE id = ?",
    //             .{ now, id },
    //         );
    //         if (changes == 0) return error.TaskNotFound;
    //     }
    // };
};
