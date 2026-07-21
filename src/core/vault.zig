const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("../internal/database/db.zig");
const task = @import("./task.zig");
const migrations = @import("../internal/database/migrate.zig");

pub const Vault = struct {
    conn: zqlite.Conn,
    io: std.Io,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, data_path: []const u8) !Vault {
        try std.Io.Dir.cwd().createDirPath(io, data_path);

        const db_path = try std.fs.path.joinZ(allocator, &.{ data_path, "tip.db" });
        defer allocator.free(db_path);

        const conn = try db.open(db_path);
        try migrations.run_migrations(conn);

        return Vault{
            .conn = conn,
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn close(self: *Vault) void {
        self.conn.close();
    }

    pub fn tasks(self: *const Vault) task.Tasks {
        return .{
            .conn = self.conn,
            .allocator = self.allocator,
            .io = self.io,
        };
    }
};
