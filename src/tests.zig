test {
    _ = @import("internal/database/migrate.zig");
    _ = @import("internal/database/db.zig");
    _ = @import("core/task.zig");
    _ = @import("utils/generate.zig");
    _ = @import("utils/output.zig");
    _ = @import("core/errors.zig");
    _ = @import("core/config.zig");
}
