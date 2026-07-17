const std = @import("std");
const zqlite = @import("zqlite");

// pub const Database = struct {
//     conn: zqlite.Conn,

//     pub fn init() !Database {
//         const flags =
//             zqlite.OpenFlags.Create |
//             zqlite.OpenFlags.EXResCode;

//         return .{
//             .conn = try zqlite.open("notes.db", flags),
//         };
//     }

//     pub fn deinit(self: *Database) void {
//         self.conn.close();
//     }
// };

/// Opens (or creates) the SQLite database at the given path.
/// WAL mode is enabled for better concurrent-read performance.
pub fn open(db_path: [:0]const u8) !zqlite.Conn {
    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
    var conn = try zqlite.open(db_path, flags);

    try conn.exec("PRAGMA journal_mode = WAL", .{});
    return conn;
}

test "open memory returns a working db" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try conn.exec("CREATE TABLE t (x INTEGER)", .{});
    try conn.exec("INSERT INTO t VALUES (42)", .{});

    if (try conn.row("SELECT x FROM t LIMIT 1", .{})) |row| {
        defer row.deinit();
        try std.testing.expectEqual(42, row.int(0));
    }
}
