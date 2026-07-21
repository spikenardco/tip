const std = @import("std");
const zqlite = @import("zqlite");

/// Opens (or creates) the SQLite database at the given path.
/// WAL mode is enabled for better concurrent-read performance.
pub fn open(db_path: [:0]const u8) !zqlite.Conn {
    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
    var conn = try zqlite.open(db_path, flags);
    errdefer conn.close();

    try conn.exec("PRAGMA journal_mode = WAL", .{});
    return conn;
}

test "open memory returns a working db" {
    const conn = try open(":memory:");
    defer conn.close();

    try conn.exec("CREATE TABLE t (x INTEGER)", .{});
    try conn.exec("INSERT INTO t VALUES (42)", .{});

    const row = (try conn.row("SELECT x FROM t LIMIT 1", .{})) orelse return error.TestExpectedEqual;
    defer row.deinit();

    try std.testing.expectEqual(@as(i64, 42), row.int(0));
}
