const std = @import("std");
const app = @import("version");
const flags = @import("flags");
const task = @import("core/task.zig");

const Args = struct {
    command: union(enum) {
        task: task.TaskArgs,
    },

    pub const help =
        \\Tip - Password and Task Manager
        \\
        \\Usage:
        \\  tip <command> [args] [flags]
        \\
        \\Options:
        \\  -h, --help            Show help
        \\  -v, --version         Show version
        \\
        \\Commands:
        \\  task                   Task management
        // \\  password               Password management
        // \\  vault                  Vault management
        // \\  config                 Configuration
        // \\  auth                   Authentication
        // \\  sync                   Synchronization
        // \\  export                 Export data
        // \\  import                 Import data
        // \\
        \\Run 'tip <command> --help' for more information on a command.
        \\
    ;
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        std.debug.print("{s}\n", .{flags.usage(Args)});
        return;
    }

    if (std.mem.eql(u8, args[1], "-v") or std.mem.eql(u8, args[1], "--version")) {
        std.debug.print("{s}\n", .{app.version});
        return;
    }

    var diagnostics: flags.Diagnostic = .{};
    const parsed = flags.parse(allocator, args, Args, &diagnostics) catch |err| {
        diagnostics.report();
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };

    switch (parsed.command) {
        .task => |t| task.execute_commands(init.io, init.minimal.environ, t),
    }
}
