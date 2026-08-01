const std = @import("std");
const zqlite = @import("zqlite");

/// Opens (or creates) the SQLite database at the given path.
/// WAL mode is enabled for better concurrent-read performance.
pub fn open(db_path: [:0]const u8) !zqlite.Conn {
    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
    var conn = try zqlite.open(db_path, flags);
    errdefer conn.close();

    try conn.execNoArgs("PRAGMA foreign_keys = ON");
    try conn.execNoArgs("PRAGMA busy_timeout = 5000");
    try conn.execNoArgs("PRAGMA journal_mode = WAL");

    return conn;
}

test "open memory returns a working db" {
    const conn = try open(":memory:");
    defer conn.close();

    try conn.exec("CREATE TABLE t (x INTEGER)", .{});
    try conn.exec("INSERT INTO t VALUES (42)", .{});

    const foreign_keys = (try conn.row("PRAGMA foreign_keys", .{})) orelse return error.TestExpectedEqual;
    defer foreign_keys.deinit();
    try std.testing.expectEqual(@as(i64, 1), foreign_keys.int(0));

    const busy_timeout = (try conn.row("PRAGMA busy_timeout", .{})) orelse return error.TestExpectedEqual;
    defer busy_timeout.deinit();
    try std.testing.expectEqual(@as(i64, 5000), busy_timeout.int(0));

    const row = (try conn.row("SELECT x FROM t LIMIT 1", .{})) orelse return error.TestExpectedEqual;
    defer row.deinit();

    try std.testing.expectEqual(@as(i64, 42), row.int(0));
}
