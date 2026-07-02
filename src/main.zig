const std = @import("std");
const version_mod = @import("version");
const flags = @import("flags");
const task = @import("core/task.zig");

const Args = struct {
    command: union(enum) {
        task: task.TaskArgs,
    },

    pub const help =
        \\Tip - task manager
        \\
        \\Usage:
        \\  tip <command> [args] [flags]
        \\
        \\Options:
        \\  -h, --help            Show help
        \\  -v, --version         Show version
        \\
        \\Commands:
        \\  task                  Task management
        \\
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
        std.debug.print("{s}\n", .{version_mod.version});
        return;
    }

    var diag: flags.Diagnostic = .{};
    const parsed = flags.parse(allocator, args, Args, &diag) catch |err| {
        diag.report();
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };

    switch (parsed.command) {
        .task => |t| task.dispatch_task_command(init.io, init.minimal.environ, t),
    }
}
