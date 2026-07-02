const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const flags = b.dependency("flags", .{
        .target = target,
        .optimize = optimize,
    }).module("flags");

    const manifest = std.zon.parse.fromSliceAlloc(
        struct { version: []const u8 },
        b.allocator,
        @embedFile("build.zig.zon"),
        null,
        .{ .ignore_unknown_fields = true },
    ) catch @panic("bad zon");

    const version_module = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("version.zig",
            b.fmt("pub const version = \"{s}\";\n", .{manifest.version})),
    });

    const exe_name = b.option([]const u8, "exe-name", "Custom executable name") orelse "tip";

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "flags", .module = flags },
                .{ .name = "version", .module = version_module },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const test_entry = generate_test_entry(b, "src") catch |err| {
        std.log.err("Failed to generate test entry: {}", .{err});
        return;
    };

    const all_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = test_entry,
            .target = target,
            .optimize = optimize,
        }),
    });

    b.step("test", "Run all tests").dependOn(&b.addRunArtifact(all_tests).step);
}

fn generate_test_entry(b: *std.Build, src_dir: []const u8) !std.Build.LazyPath {
    const allocator = b.allocator;
    const source_files = try find_zig_sources(b, src_dir);

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    const writer = &alloc_writer.writer;
    try writer.writeAll("test {\n");
    for (source_files) |f|
        try writer.print("    _ = @import(\"{s}\");\n", .{f});
    try writer.writeAll("}\n");

    const build_root_path = b.build_root.path orelse ".";
    var dir = try std.Io.Dir.openDirAbsolute(b.graph.io, build_root_path, .{});
    defer dir.close(b.graph.io);
    try dir.writeFile(b.graph.io, .{ .sub_path = "auto_test_runner.zig", .data = alloc_writer.written() });

    return b.path("auto_test_runner.zig");
}

fn find_zig_sources(b: *std.Build, dir: []const u8) ![]const []const u8 {
    const allocator = b.allocator;
    var source_files = std.ArrayList([]const u8).empty;
    var dirs = std.ArrayList([]const u8).empty;
    try dirs.append(allocator, dir);
    var i: usize = 0;

    while (i < dirs.items.len) : (i += 1) {
        const current = dirs.items[i];
        const absolute_path = try std.fs.path.join(allocator, &.{ b.build_root.path orelse ".", current });
        defer allocator.free(absolute_path);

        var d = std.Io.Dir.openDirAbsolute(b.graph.io, absolute_path, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => |err| return err,
        };
        defer d.close(b.graph.io);

        var it = d.iterate();
        while (try it.next(b.graph.io)) |entry| {
            if (entry.name[0] == '.') continue;
            const joined = try std.fs.path.join(allocator, &.{ current, entry.name });
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
                try source_files.append(allocator, joined);
            } else if (entry.kind == .directory and
                !std.mem.startsWith(u8, entry.name, "zig-cache") and
                !std.mem.startsWith(u8, entry.name, "zig-pkg"))
            {
                try dirs.append(allocator, joined);
            }
        }
    }
    return source_files.items;
}
