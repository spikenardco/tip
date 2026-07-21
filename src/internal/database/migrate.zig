const std = @import("std");
const zqlite = @import("zqlite");

const migration_001 = @embedFile("migrations/001_create_schema_version.sql");
const migration_002 = @embedFile("migrations/002_create_tasks.sql");

fn read_schema_version(conn: zqlite.Conn) !i64 {
    const row = (try conn.row(
        "SELECT COALESCE(MAX(version), 0) FROM _schema_version",
        .{},
    )) orelse return error.StorageFailure;
    defer row.deinit();

    return row.int(0);
}

pub fn run_migrations(conn: zqlite.Conn) !void {
    try conn.execNoArgs("BEGIN IMMEDIATE");
    errdefer conn.rollback();

    try conn.execNoArgs("CREATE TABLE IF NOT EXISTS _schema_version (version INTEGER NOT NULL)");
    const current_version = try read_schema_version(conn);

    if (current_version < 1) try conn.execNoArgs(migration_001);
    if (current_version < 2) try conn.execNoArgs(migration_002);

    try conn.commit();
}

test "migrations run from scratch" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try run_migrations(conn);

    try std.testing.expectEqual(@as(i64, 2), try read_schema_version(conn));
}

test "migrations are idempotent" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try run_migrations(conn);
    try run_migrations(conn);

    try std.testing.expectEqual(@as(i64, 2), try read_schema_version(conn));
}

test "migrations create tasks table" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try run_migrations(conn);

    try conn.exec(
        "INSERT INTO tasks (id, title, status, created_at) VALUES (?, ?, ?, ?)",
        .{ "001", "Test Task", "pending", @as(i64, 1000) },
    );

    if (try conn.row("SELECT title FROM tasks WHERE id = ?", .{"001"})) |row| {
        try std.testing.expectEqualStrings("Test Task", row.text(0));
    }
}

test "failed migration rolls back its version row" {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try conn.execNoArgs(
        \\CREATE TABLE _schema_version (version INTEGER NOT NULL);
        \\CREATE TABLE tasks (id TEXT);
    );

    try std.testing.expectError(error.Error, run_migrations(conn));
    try std.testing.expectEqual(@as(i64, 0), try read_schema_version(conn));
}
