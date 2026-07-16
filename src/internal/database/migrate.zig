const std = @import("std");
const zqlite = @import("zqlite");

const migrations = struct {
    const v1 = @embedFile("migrations/001_create_schema_version.sql");
};

pub fn run_migrations(db: *zqlite.Conn) !void {
    try db.exec("CREATE TABLE IF NOT EXISTS _schema_version (version INTEGER NOT NULL)", .{});

    const current_version: i64 = if (db.row(
        "SELECT COALESCE(MAX(version), 0) FROM _schema_version",
        .{},
    ) catch null) |row| row.int(0) else 0;

    if (current_version < 1) {
        try db.exec(migrations.v1, .{});
    }
}

test "migrations run from scratch" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try run_migrations(&conn);

    if (try conn.row("SELECT version FROM _schema_version", .{})) |row| {
        const version = row.int(0);
        try std.testing.expectEqual(@as(i64, 1), version);
    }
}

test "migrations are idempotent" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try run_migrations(&conn);
    try run_migrations(&conn);

    if (try conn.row("SELECT version FROM _schema_version", .{})) |row| {
        const version = row.int(0);
        try std.testing.expectEqual(@as(i64, 1), version);
    }
}
