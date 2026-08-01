const std = @import("std");
const zqlite = @import("zqlite");

const migrations = [_][*:0]const u8{
    @embedFile("migrations/001_create_tasks.sql"),
};

fn read_schema_version(conn: zqlite.Conn) !usize {
    const row = (try conn.row("PRAGMA user_version", .{})) orelse return error.StorageFailure;
    defer row.deinit();

    const version = row.int(0);
    if (version < 0) return error.UnsupportedSchemaVersion;

    return @intCast(version);
}

pub fn run_migrations(conn: zqlite.Conn) !void {
    try conn.execNoArgs("BEGIN IMMEDIATE");
    errdefer conn.rollback();

    const current_version = try read_schema_version(conn);

    if (current_version > migrations.len) {
        return error.UnsupportedSchemaVersion;
    }

    for (current_version..migrations.len) |version| {
        try conn.execNoArgs(migrations[version]);

        if (try read_schema_version(conn) != version + 1) {
            return error.InvalidMigrationVersion;
        }
    }

    try conn.commit();
}

test "migrations run from scratch" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try run_migrations(conn);

    try std.testing.expectEqual(@as(usize, 1), try read_schema_version(conn));
}

test "migrations are idempotent" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try run_migrations(conn);
    try run_migrations(conn);

    try std.testing.expectEqual(@as(usize, 1), try read_schema_version(conn));

    if (try conn.row(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '_schema_version'",
        .{},
    )) |row| {
        row.deinit();
        return error.TestExpectedEqual;
    }
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
        defer row.deinit();
        try std.testing.expectEqualStrings("Test Task", row.text(0));
    }
}

test "task schema constraints reject invalid values" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try run_migrations(conn);

    try std.testing.expectError(error.ConstraintCheck, conn.exec(
        "INSERT INTO tasks (id, title, status, created_at) VALUES (?, ?, ?, ?)",
        .{ "001", "", "pending", @as(i64, 1000) },
    ));
    try std.testing.expectError(error.ConstraintCheck, conn.exec(
        "INSERT INTO tasks (id, title, status, created_at) VALUES (?, ?, ?, ?)",
        .{ "002", "Valid", "unknown", @as(i64, 1000) },
    ));
    try std.testing.expectError(error.ConstraintCheck, conn.exec(
        "INSERT INTO tasks (id, title, priority, created_at) VALUES (?, ?, ?, ?)",
        .{ "003", "Valid", "urgent", @as(i64, 1000) },
    ));
    try conn.exec(
        "INSERT INTO tasks (id, title, description, priority, created_at) VALUES (?, ?, ?, ?, ?)",
        .{ "004", "Valid", null, null, @as(i64, 1000) },
    );
}

test "future schema versions are rejected" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try conn.execNoArgs("PRAGMA user_version = 2");
    try std.testing.expectError(error.UnsupportedSchemaVersion, run_migrations(conn));
    try std.testing.expectEqual(@as(usize, 2), try read_schema_version(conn));
}

test "failed migration rolls back schema changes" {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try conn.execNoArgs("CREATE TABLE tasks (id TEXT)");

    try std.testing.expectError(error.Error, run_migrations(conn));
    try std.testing.expectEqual(@as(usize, 0), try read_schema_version(conn));
}

test "legacy schema is not repaired" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try conn.execNoArgs(
        \\CREATE TABLE _schema_version (version INTEGER NOT NULL);
        \\INSERT INTO _schema_version VALUES (2);
        \\CREATE TABLE tasks (id TEXT);
    );

    try std.testing.expectError(error.Error, run_migrations(conn));
    try std.testing.expectEqual(@as(usize, 0), try read_schema_version(conn));
}
