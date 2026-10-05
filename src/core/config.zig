const std = @import("std");
const storage = @import("../storage/dir.zig");

pub const ConfigArgs = struct {
    subcommand: ?union(enum) {
        init: void,
        show: void,
        get: struct { key: []const u8 },
        set: struct { key: []const u8, value: []const u8 },
        reset: void,
    } = null,

    pub const help =
        \\Manage configuration
        \\
        \\Usage:
        \\  tip config <subcommand> [flags]
        \\
        \\Options:
        \\  -h, --help            Show help
        \\
        \\Commands:
        \\  init                  Create default config file
        \\  show                  Show current config
        \\  get --key=<key>       Get a config value
        \\  set --key=<key> --value=<value>  Set a config value
        \\  reset                 Reset config to defaults
        \\
    ;
};

pub fn dispatch(
    store: ConfigStore,
    config: Config,
    args: ConfigArgs,
) !void {
    const subcommand = args.subcommand orelse {
        std.debug.print("{s}\n", .{ConfigArgs.help});
        return;
    };

    switch (subcommand) {
        .init => {
            try store.init();
            std.debug.print("Config initialized\n", .{});
        },
        .show => {
            var writer: std.Io.Writer.Allocating = .init(store.allocator);
            defer writer.deinit();
            try std.zon.stringify.serialize(config, .{}, &writer.writer);
            try writer.writer.writeByte('\n');
            std.debug.print("{s}", .{writer.writer.buffered()});
        },
        .get => |g| {
            const value = try config.get(g.key);
            std.debug.print("{s}\n", .{value});
        },
        .set => |s| {
            _ = try store.set(s.key, s.value);
            std.debug.print("Set {s} = {s}\n", .{ s.key, s.value });
        },
        .reset => {
            try store.reset();
            std.debug.print("Config reset to defaults\n", .{});
        },
    }
}

/// Application configuration, read from or written to a ZON file.
/// Defaults match a fresh install; a config file only overrides what the
/// user has explicitly set.
pub const Config = struct {
    verbose: bool = false,
    quiet: bool = false,
    default_vault: ?[]const u8 = null,

    /// Read a single config value as a string.
    pub fn get(self: Config, key: []const u8) ![]const u8 {
        if (std.mem.eql(u8, key, "verbose")) return if (self.verbose) "true" else "false";
        if (std.mem.eql(u8, key, "quiet")) return if (self.quiet) "true" else "false";
        if (std.mem.eql(u8, key, "default_vault")) return self.default_vault orelse "";
        return error.UnknownConfigKey;
    }
};

/// Handle for reading and writing the config file. Holds the I/O context so
/// config operations don't thread allocator/io/environ/path through every call.
pub const ConfigStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    config_path: ?[]const u8,

    /// Load config from file, falling back to defaults when no file exists.
    /// The returned `Config` owns its allocations; free with `zon.parse.free`.
    pub fn load(self: ConfigStore) !Config {
        const path = try self.resolve_path();
        defer self.allocator.free(path);

        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return Config{},
            else => |e| return e,
        };
        defer file.close(self.io);

        // One pre-sized, sentinel-terminated buffer. Config files are tiny and
        // never exceed this, so a single read into the sentinel buffer avoids a
        // stat + extra allocation + copy.
        const max = 16 * 1024;
        const buf = try self.allocator.allocSentinel(u8, max, 0);
        defer self.allocator.free(buf);

        const content = try file.readStreaming(self.io, &.{buf});
        const sentineled = buf[0..content :0];

        var diag: std.zon.parse.Diagnostics = .{};
        defer diag.deinit(self.allocator);

        return std.zon.parse.fromSliceAlloc(Config, self.allocator, sentineled, &diag, .{ .free_on_error = true });
    }

    /// Serialize config to ZON and write it atomically (temp file + rename),
    /// creating parent directories as needed.
    pub fn save(self: ConfigStore, config: Config) !void {
        const path = try self.resolve_path();
        defer self.allocator.free(path);

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();

        try std.zon.stringify.serialize(config, .{}, &writer.writer);
        try writer.writer.writeByte('\n');

        const data = writer.writer.buffered();

        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(self.io);

        try atomic.file.writeStreamingAll(self.io, data);
        try atomic.replace(self.io);
    }

    /// Create a default config file. Errors if one already exists.
    pub fn init(self: ConfigStore) !void {
        const path = try self.resolve_path();
        defer self.allocator.free(path);

        if (std.Io.Dir.cwd().access(self.io, path, .{})) {
            return error.ConfigAlreadyExists;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }

        try self.save(.{});
    }

    /// Overwrite config file with defaults.
    pub fn reset(self: ConfigStore) !void {
        try self.save(.{});
    }

    /// Set a config value, persist to file, and return the updated config.
    /// The returned `Config` owns its allocations; free with `zon.parse.free`.
    pub fn set(self: ConfigStore, key: []const u8, value: []const u8) !Config {
        var config = try self.load();
        errdefer std.zon.parse.free(self.allocator, config);

        if (std.mem.eql(u8, key, "verbose")) {
            config.verbose = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "quiet")) {
            config.quiet = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "default_vault")) {
            const duped = try self.allocator.dupe(u8, value);
            if (config.default_vault) |old| self.allocator.free(old);
            config.default_vault = duped;
        } else {
            return error.UnknownConfigKey;
        }

        try self.save(config);

        return config;
    }

    /// Resolve the config file path. If `config_path` is given, use it as-is;
    /// otherwise use `<config dir>/tip.zon`. Caller owns the result.
    fn resolve_path(self: ConfigStore) ![]const u8 {
        if (self.config_path) |path| return try self.allocator.dupe(u8, path);

        const dir_path = try storage.config_dir_path(self.allocator, self.environ);
        defer self.allocator.free(dir_path);
        return std.fs.path.join(self.allocator, &.{ dir_path, "tip.zon" });
    }
};