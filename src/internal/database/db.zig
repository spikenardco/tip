const std = @import("std");
const builtin = @import("builtin");
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

/// Opens (or creates) the SQLite database at the platform data directory.
/// WAL mode is enabled for better concurrent-read performance.
pub fn open(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !zqlite.Conn {
    const base = switch (builtin.os.tag) {
        .linux => blk: {
            if (environ.getPosix("XDG_DATA_HOME")) |xdg| {
                break :blk try std.fs.path.joinZ(allocator, &.{ xdg, "tip" });
            }
            const home = environ.getPosix("HOME") orelse return error.HomeDirMissing;
            break :blk try std.fs.path.joinZ(allocator, &.{ home, ".local", "share", "tip" });
        },
        .macos => blk: {
            const home = environ.getPosix("HOME") orelse return error.HomeDirMissing;
            break :blk try std.fs.path.joinZ(allocator, &.{ home, "Library", "Application Support", "tip" });
        },
        .windows => blk: {
            const appdata = environ.getAlloc(allocator, "APPDATA") catch return error.AppDataDirUnavailable;
            defer allocator.free(appdata);
            break :blk try std.fs.path.joinZ(allocator, &.{ appdata, "tip" });
        },
        else => @compileError("unsupported OS"),
    };
    defer allocator.free(base);

    try std.Io.Dir.cwd().createDirPath(io, base);

    const db_path = try std.fs.path.joinZ(allocator, &.{ base, "tip.db" });
    defer allocator.free(db_path);

    // good idea to pass EXResCode to get extended result codes (more detailed error codes)
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
