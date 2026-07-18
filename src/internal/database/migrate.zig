const std = @import("std");
const zqlite = @import("zqlite");

pub fn run_migrations(db: *zqlite.Conn) !void {
    try db.exec("CREATE TABLE IF NOT EXISTS _schema_version (version INTEGER NOT NULL)", .{});

    const current_version: i64 = if (db.row(
        "SELECT COALESCE(MAX(version), 0) FROM _schema_version",
        .{},
    ) catch null) |row| row.int(0) else 0;

    if (current_version < 1) {
        try db.exec("INSERT INTO _schema_version (version) VALUES (1)", .{});
    }

    if (current_version < 2) {
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS tasks (
            \\  id           TEXT PRIMARY KEY NOT NULL,
            \\  title        TEXT NOT NULL,
            \\  description  TEXT,
            \\  status       TEXT NOT NULL DEFAULT 'pending',
            \\  priority     TEXT,
            \\  due_date     INTEGER,
            \\  assigned_to  TEXT,
            \\  created_at   INTEGER NOT NULL,
            \\  updated_at   INTEGER,
            \\  completed_at INTEGER
            \\)
        , .{});
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)", .{});
        try db.exec("INSERT INTO _schema_version (version) VALUES (2)", .{});
    }
}

test "migrations run from scratch" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try run_migrations(&conn);

    if (try conn.row("SELECT COALESCE(MAX(version), 0) FROM _schema_version", .{})) |row| {
        const version = row.int(0);
        try std.testing.expectEqual(@as(i64, 2), version);
    }
}

test "migrations are idempotent" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try run_migrations(&conn);
    try run_migrations(&conn);

    if (try conn.row("SELECT COALESCE(MAX(version), 0) FROM _schema_version", .{})) |row| {
        const version = row.int(0);
        try std.testing.expectEqual(@as(i64, 2), version);
    }
}

test "migrations create tasks table" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try run_migrations(&conn);

    try conn.exec(
        "INSERT INTO tasks (id, title, status, created_at) VALUES (?, ?, ?, ?)",
        .{ "test-id", "Test Task", "pending", @as(i64, 1000) },
    );

    if (try conn.row("SELECT title FROM tasks WHERE id = ?", .{"test-id"})) |row| {
        try std.testing.expectEqualStrings("Test Task", row.text(0));
    }
}
