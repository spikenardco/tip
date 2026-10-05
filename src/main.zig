const std = @import("std");
const version_mod = @import("version");
const flags = @import("flags");
const task = @import("core/task.zig");
const errors = @import("core/errors.zig");
const storage = @import("storage/dir.zig");
const config_mod = @import("core/config.zig");
const Vault = @import("./core/vault.zig").Vault;

const Args = struct {
    verbose: bool = false,
    quiet: bool = false,
    config: ?[]const u8 = null,
    vault: ?[]const u8 = null,
    command: union(enum) {
        task: task.TaskArgs,
        config: config_mod.ConfigArgs,
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
        \\  --verbose             Verbose output
        \\  --quiet               Minimal output
        \\  --config=<path>       Configuration file path
        \\  --vault=<name>        Vault name
        \\
        \\Commands:
        \\  task                  Task management
        \\  config                Configuration management
        \\
        \\Run 'tip <command> --help' for more information on a command.
        \\
    ;
};

fn exit_with_error(err: anyerror) noreturn {
    std.debug.print("error: {s}\n", .{errors.describe(err)});
    std.process.exit(errors.exit_code(err));
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const environ = init.minimal.environ;
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
        std.process.exit(if (err == error.HelpRequested) 0 else 2);
    };

    // Load config from file, then apply CLI flag overrides (CLI wins).
    const config_store = config_mod.ConfigStore{
        .allocator = allocator,
        .io = io,
        .environ = environ,
        .config_path = parsed.config,
    };
    var config = config_store.load() catch |err|
        exit_with_error(err);
    if (parsed.verbose) config.verbose = true;
    if (parsed.quiet) config.quiet = true;
    if (parsed.vault) |v| config.default_vault = try allocator.dupe(u8, v);

    switch (parsed.command) {
        .task => |t| {
            const data_path = try storage.data_dir_path(allocator, environ);
            var vault = Vault.open(
                allocator,
                io,
                data_path,
            ) catch exit_with_error(error.StorageFailure);
            defer vault.close();

            task.dispatch(vault.tasks, t) catch |err|
                exit_with_error(err);
        },
        .config => |c| config_mod.dispatch(config_store, config, c) catch |err|
            exit_with_error(err),
    }
}
