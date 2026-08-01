const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sqlite_optimize_flag = switch (optimize) {
        .Debug => "-O0",
        .ReleaseSafe => "-O2",
        .ReleaseFast => "-O3",
        .ReleaseSmall => "-Oz",
    };

    const flags = b.dependency("flags", .{
        .target = target,
        .optimize = optimize,
    }).module("flags");

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
        .sqlite3 = &[_][]const u8{
            "-std=c17",
            sqlite_optimize_flag,
            "-DSQLITE_OMIT_JSON",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_OMIT_PROGRESS_CALLBACK",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-DSQLITE_THREADSAFE=0",
            "-DSQLITE_DQS=0",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_UTF16",
            "-DSQLITE_OMIT_COMPILEOPTION_DIAGS",
        },
    }).module("zqlite");

    const manifest = std.zon.parse.fromSliceAlloc(
        struct { version: []const u8 },
        b.allocator,
        @embedFile("build.zig.zon"),
        null,
        .{ .ignore_unknown_fields = true },
    ) catch @panic("bad zon");

    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", manifest.version);

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "flags", .module = flags },
        .{ .name = "version", .module = version_options.createModule() },
        .{ .name = "zqlite", .module = zqlite },
    };

    const exe_name = b.option([]const u8, "exe-name", "Custom executable name") orelse "tip";

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });

    exe.root_module.strip = optimize != .Debug;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const all_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });

    b.step("test", "Run all tests").dependOn(&b.addRunArtifact(all_tests).step);
}
