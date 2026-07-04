# `tip upgrade` — Self-Update Command — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `tip upgrade` that checks GitHub for a newer stable release, downloads it, verifies the checksum, and replaces the running binary — with no GitHub API dependency.

**Architecture:** A new `src/upgrade.zig` module holds all upgrade logic. A HEAD request to the GitHub CDN's `/releases/latest/download/` URL returns a 302 whose Location header contains the release tag; we parse the tag, compare semver, and only download the binary + checksums.txt if newer. Binary replacement is atomic on Linux/macOS (rename over running binary) and uses a `.bat` helper on Windows. The `tip upgrade` command is added to the existing Args union in `src/main.zig`.

**Tech Stack:** Zig 0.16.0 stdlib (`std.http.Client`, `std.json`, `std.process.executablePath`, `std.crypto.sha2.Sha256`).

## Global Constraints

- Repo slug: `spikenardco/tip`.
- Release asset pattern: `https://github.com/spikenardco/tip/releases/download/<tag>/<asset>`.
- CDN "latest" shortcut: `https://github.com/spikenardco/tip/releases/latest/download/<asset>` redirects to the tag-specific URL.
- Asset names: `tip-{linux,macos,windows}-{x86_64,arm64}` (`.exe` suffix on Windows).
- `checksums.txt` is standard `sha256sum` format: `<64-hex>  <asset>`.
- Version compiled in via `@import("version").version` (e.g. `"0.0.0-alpha-3"`).
- No GitHub API calls — CDN only.
- Never download a binary just to discover its version.

---

## File Structure

- `src/upgrade.zig` — **Create.** All upgrade logic: platform detection, version comparison, URL tag extraction, HTTP resolution, binary download, checksum verification, binary replacement.
- `src/main.zig` — **Modify.** Add `upgrade` variant to Args union, add import and dispatch case.

`build.zig` and `build.zig.zon` require no changes.

---

## Task 1: Pure utility functions (platform detection, version comparison, tag extraction)

**Files:**
- Create: `src/upgrade.zig`
- Test: inline `test` blocks in `src/upgrade.zig`

**Interfaces:**
- Produces:
  - `fn detectPlatform() struct { os: []const u8, arch: []const u8, asset: []const u8 }` — compile-time platform detection matching `scripts/install.sh` naming.
  - `fn versionCompare(current: []const u8, latest: []const u8) std.math.Order` — semver comparison (strip leading `v`, parse via `std.SemanticVersion`).
  - `fn extractTagFromLocation(location: []const u8) ?[]const u8` — parse tag from redirect URL path.

- [ ] **Step 1: Write the failing tests for platform detection**

```zig
const std = @import("std");
const builtin = @import("builtin");

test "detectPlatform linux x86_64" {
    // Can't test actual compile-time detection without cross-compiling.
    // Instead, test that the returned struct has the expected fields.
    const p = detectPlatform();
    try std.testing.expect(p.os.len > 0);
    try std.testing.expect(p.arch.len > 0);
    try std.testing.expect(p.asset.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, p.asset, p.arch));
}

test "detectPlatform asset name contains os" {
    const p = detectPlatform();
    try std.testing.expect(std.mem.containsAtLeast(u8, p.asset, 1, p.os));
}
```

- [ ] **Step 2: Run tests to verify they fail (no implementation yet)**

Run:
```bash
zig build test -- --test-filter "detectPlatform" 2>&1 || true
```
Expected: error because `detectPlatform` is not defined.

- [ ] **Step 3: Write the failing tests for version comparison**

```zig
test "versionCompare same version" {
    try std.testing.expectEqual(.eq, versionCompare("v0.1.0", "v0.1.0"));
}

test "versionCompare newer version detected" {
    try std.testing.expectEqual(.lt, versionCompare("v0.1.0", "v0.2.0"));
}

test "versionCompare older version detected" {
    try std.testing.expectEqual(.gt, versionCompare("v0.2.0", "v0.1.0"));
}

test "versionCompare with v prefix" {
    try std.testing.expectEqual(.eq, versionCompare("v0.1.0", "v0.1.0"));
}

test "versionCompare without v prefix" {
    try std.testing.expectEqual(.eq, versionCompare("0.1.0", "0.1.0"));
}

test "versionCompare pre-release" {
    try std.testing.expectEqual(.lt, versionCompare("v0.1.0-alpha", "v0.1.0"));
}
```

- [ ] **Step 4: Run the version comparison tests to verify they fail**

Run:
```bash
zig build test -- --test-filter "versionCompare" 2>&1 || true
```
Expected: error because `versionCompare` is not defined.

- [ ] **Step 5: Write the failing tests for tag extraction**

```zig
test "extractTagFromLocation typical URL" {
    const url = "https://github.com/spikenardco/tip/releases/download/v0.2.0/tip-linux-x86_64";
    const tag = extractTagFromLocation(url);
    try std.testing.expectEqualStrings("v0.2.0", tag.?);
}

test "extractTagFromLocation with .exe" {
    const url = "https://github.com/spikenardco/tip/releases/download/v1.0.0/tip-windows-x86_64.exe";
    const tag = extractTagFromLocation(url);
    try std.testing.expectEqualStrings("v1.0.0", tag.?);
}

test "extractTagFromLocation no tag returns null" {
    const url = "https://github.com/spikenardco/tip/releases/latest/download/tip-linux-x86_64";
    try std.testing.expect(extractTagFromLocation(url) == null);
}

test "extractTagFromLocation relative path" {
    const url = "/spikenardco/tip/releases/download/v0.2.0/tip-linux-x86_64";
    const tag = extractTagFromLocation(url);
    try std.testing.expectEqualStrings("v0.2.0", tag.?);
}
```

- [ ] **Step 6: Run tag extraction tests to verify they fail**

Run:
```bash
zig build test -- --test-filter "extractTagFromLocation" 2>&1 || true
```
Expected: error because `extractTagFromLocation` is not defined.

- [ ] **Step 7: Implement the pure utility functions**

Add at the top of `src/upgrade.zig`:

```zig
const std = @import("std");
const builtin = @import("builtin");

pub const Platform = struct {
    os: []const u8,
    arch: []const u8,
    asset: []const u8,
};

pub fn detectPlatform() Platform {
    const os: []const u8 = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => @compileError("unsupported OS"),
    };
    const arch: []const u8 = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        else => @compileError("unsupported architecture"),
    };
    const suffix = if (builtin.os.tag == .windows) ".exe" else "";
    const asset = std.fmt.comptimePrint("tip-{s}-{s}{s}", .{ os, arch, suffix });
    return .{ .os = os, .arch = arch, .asset = asset };
}

pub fn versionCompare(current: []const u8, latest: []const u8) std.math.Order {
    const stripV = (s: []const u8) []const u8 {
        if (s.len > 0 and s[0] == 'v') return s[1..];
        return s;
    };
    const cur_ver = std.SemanticVersion.parse(stripV(current)) catch return .lt;
    const lat_ver = std.SemanticVersion.parse(stripV(latest)) catch return .gt;
    return std.math.order(cur_ver.order(lat_ver), .eq);
}

pub fn extractTagFromLocation(location: []const u8) ?[]const u8 {
    const marker = "/download/";
    const start = std.mem.indexOfPos(u8, location, 0, marker) orelse return null;
    const after_download = start + marker.len;
    const end = std.mem.indexOfScalar(u8, location[after_download..], '/') orelse return null;
    if (end == 0) return null;
    return location[after_download..][0..end];
}
```

- [ ] **Step 8: Run all tests to verify they pass**

Run:
```bash
zig build test -- --test-filter "detectPlatform|versionCompare|extractTagFromLocation" 2>&1
```
Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
git add src/upgrade.zig
git commit -m "feat(upgrade): add platform detection, version comparison, and URL tag extraction"
```

---

## Task 2: HTTP resolution, binary download, checksum verification, and binary replacement

**Files:**
- Modify: `src/upgrade.zig` (add functions below the utilities from Task 1)
- Test: manual verification via `zig build run -- upgrade`

**Interfaces:**
- Consumes: `Platform`, `versionCompare`, `extractTagFromLocation` from Task 1.
- Produces:
  - `pub fn resolveLatestTag(io: std.Io, allocator: Allocator, platform: Platform) !?[]const u8` — HEAD request to CDN, follow redirect, extract tag. Returns `null` if no release exists.
  - `pub fn downloadAndVerify(io: std.Io, allocator: Allocator, tag: []const u8, platform: Platform, temp_dir_path: []const u8) ![]const u8` — download binary + checksums.txt, verify SHA-256, return path to verified binary.
  - `pub fn replaceBinary(io: std.Io, allocator: Allocator, new_bin_path: []const u8) !void` — find current binary, rename temp file over it.
  - `pub fn upgrade(io: std.Io, allocator: Allocator, current_version: []const u8) !void` — orchestrator: resolve tag, compare, download, replace, print messages.

- [ ] **Step 1: Write the HTTP client helper to resolve the latest release tag**

Add after the utility functions in `src/upgrade.zig`:

```zig
pub fn resolveLatestTag(io: std.Io, allocator: Allocator, platform: Platform) !?[]const u8 {
    var client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const latest_uri_str = std.fmt.allocPrint(allocator,
        "https://github.com/spikenardco/tip/releases/latest/download/{s}",
        .{platform.asset},
    );
    defer allocator.free(latest_uri_str);

    const uri = try std.Uri.parse(latest_uri_str);
    var req = try client.request(.HEAD, uri, .{
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();

    try req.sendBodiless();
    var redirect_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const response = try req.receiveHead(&redirect_buffer);

    if (response.head.status.class() != .redirect) return null;

    const location = response.head.location orelse return null;
    const tag = extractTagFromLocation(location) orelse return null;
    return try allocator.dupe(u8, tag);
}
```

- [ ] **Step 2: Write the download + checksum verification function**

```zig
pub fn downloadAndVerify(io: std.Io, allocator: Allocator, tag: []const u8, platform: Platform, temp_dir_path: []const u8) ![]const u8 {
    var client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const tag_dir = std.fmt.allocPrint(allocator,
        "https://github.com/spikenardco/tip/releases/download/{s}",
        .{tag},
    );
    defer allocator.free(tag_dir);

    const bin_url = std.fmt.allocPrint(allocator, "{s}/{s}", .{ tag_dir, platform.asset });
    defer allocator.free(bin_url);

    const checksums_url = std.fmt.allocPrint(allocator, "{s}/checksums.txt", .{tag_dir});
    defer allocator.free(checksums_url);

    const bin_path = try std.fs.path.join(allocator, &.{ temp_dir_path, "tip_new" });
    defer allocator.free(bin_path);

    const checksums_path = try std.fs.path.join(allocator, &.{ temp_dir_path, "checksums.txt" });
    defer allocator.free(checksums_path);

    const cwd = std.Io.Dir.cwd();

    // Download binary
    {
        const bin_uri = try std.Uri.parse(bin_url);
        var req = try client.request(.GET, bin_uri, .{});
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        if (response.head.status != .ok) return error.DownloadFailed;

        var tmp = try cwd.createFile(io, bin_path, .{ .read = true });
        defer tmp.close(io);
        var write_buf: [8192]u8 = undefined;
        var file_writer = tmp.writer(io, &write_buf);

        var transfer_buffer: [8192]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
        try body_reader.streamRemaining(&file_writer.interface);
    }

    // Download checksums.txt
    {
        const checksums_uri = try std.Uri.parse(checksums_url);
        var req = try client.request(.GET, checksums_uri, .{});
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        if (response.head.status != .ok) return error.ChecksumsNotFound;

        var tmp = try cwd.createFile(io, checksums_path, .{ .read = true });
        defer tmp.close(io);
        var write_buf: [8192]u8 = undefined;
        var file_writer = tmp.writer(io, &write_buf);

        var transfer_buffer: [8192]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
        try body_reader.streamRemaining(&file_writer.interface);
    }

    // Verify SHA-256
    {
        const bin_contents = try cwd.readFileAlloc(io, bin_path, allocator, .max);
        defer allocator.free(bin_contents);

        var hash: [32]u8 = undefined;
        std.crypto.sha2.Sha256.hash(bin_contents, &hash, .{});

        const checksums_contents = try cwd.readFileAlloc(io, checksums_path, allocator, .max);
        defer allocator.free(checksums_contents);

        const hex_hash = std.fmt.bytesToHex(hash, .lower);
        const expected_line = findChecksumLine(checksums_contents, platform.asset) orelse return error.ChecksumNotFound;
        if (!std.mem.eql(u8, hex_hash[0..], expected_line)) return error.ChecksumMismatch;
    }

    return allocator.dupe(u8, bin_path);
}

fn findChecksumLine(contents: []const u8, asset: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (std.mem.endsWith(u8, trimmed, "  " ++ asset) or
            std.mem.endsWith(u8, trimmed, " *" ++ asset))
        {
            const space_idx = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue;
            return trimmed[0..space_idx];
        }
    }
    return null;
}
```

- [ ] **Step 3: Write the binary replacement function**

```zig
pub fn replaceBinary(io: std.Io, allocator: Allocator, new_bin_path: []const u8) !void {
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_path_len = try std.process.executablePath(io, &exe_buf);
    const exe_path = exe_buf[0..exe_path_len];

    // Check for " (deleted)" suffix on Linux
    if (std.mem.endsWith(u8, exe_path, " (deleted)")) {
        return error.ExeDeleted;
    }

    const cwd = std.Io.Dir.cwd();

    if (builtin.os.tag == .windows) {
        // Windows: running .exe is locked, use .bat helper
        const new_path = try std.mem.concat(allocator, u8, &.{ exe_path, ".new" });
        defer allocator.free(new_path);

        try cwd.rename(new_bin_path, cwd, new_path, io);

        const bat_path = try std.mem.concat(allocator, u8, &.{ exe_path, ".bat" });
        defer allocator.free(bat_path);

        const bat_contents = try std.fmt.allocPrint(allocator,
            \\@echo off
            \\:loop
            \\ren "{s}" "tip.exe" 2>nul
            \\if not exist "{s}" (
            \\  del "%~f0"
            \\  exit /b
            \\)
            \\ping -n 2 127.0.0.1 >nul
            \\goto loop
        , .{ new_path, new_path });
        defer allocator.free(bat_contents);

        try cwd.writeFile(io, .{ .sub_path = bat_path, .data = bat_contents });
        // Spawn .bat and exit
        _ = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{bat_path},
        });
        std.process.exit(0);
    } else {
        // Unix: set executable, then rename over running binary
        try cwd.setFilePermissions(io, new_bin_path, @enumFromInt(0o755), .{});
        try cwd.rename(new_bin_path, cwd, exe_path, io);
    }
}
```

- [ ] **Step 4: Write the orchestrator function**

```zig
pub const UpgradeError = error{
    DownloadFailed,
    ChecksumsNotFound,
    ChecksumNotFound,
    ChecksumMismatch,
    ExeDeleted,
    NoReleaseFound,
    AlreadyUpToDate,
} || std.mem.Allocator.Error || std.http.Client.RequestError || std.http.Client.Request.ReceiveHeadError || std.Io.Dir.Error || std.Io.File.Error || std.process.ExecutablePathError;

pub fn upgrade(io: std.Io, allocator: Allocator, current_version: []const u8) !void {
    const platform = detectPlatform();

    const tag = try resolveLatestTag(io, allocator, platform) orelse {
        std.debug.print("No releases found.\n", .{});
        return error.NoReleaseFound;
    };
    defer allocator.free(tag);

    if (versionCompare(current_version, tag) != .lt) {
        std.debug.print("tip is already up-to-date ({s})\n", .{current_version});
        return error.AlreadyUpToDate;
    }

    // Create temp directory in system temp
    const tmp_base = switch (builtin.os.tag) {
        .windows => "C:\\Windows\\Temp",
        else => "/tmp",
    };
    var rand_buf: [8]u8 = undefined;
    io.random(&rand_buf);
    const tmp_dir_name = try std.fmt.allocPrint(allocator, "tip-upgrade-{s}", .{std.fmt.bytesToHex(rand_buf, .lower)});
    defer allocator.free(tmp_dir_name);
    const tmp_path = try std.fs.path.join(allocator, &.{ tmp_base, tmp_dir_name });
    defer allocator.free(tmp_path);

    try std.Io.Dir.cwd().createDirPath(io, tmp_path);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    std.debug.print("Fetching tip {s}...\n", .{tag});

    const verified_path = try downloadAndVerify(io, allocator, tag, platform, tmp_path);
    defer allocator.free(verified_path);

    std.debug.print("Checksum verified. Installing...\n", .{});

    try replaceBinary(io, allocator, verified_path);

    std.debug.print("Updated tip from {s} to {s}\n", .{ current_version, tag });
}
```

- [ ] **Step 5: Verify the build compiles**

Run:
```bash
zig build
```
Expected: builds successfully.

- [ ] **Step 6: Test manually by running against a real release**

Run:
```bash
zig build run -- -- -- upgrade
```
Expected: prints either "Already up-to-date" or fetches an update. The important thing is the program compiles and runs without crashing. Actual HTTP results depend on network and current version.

- [ ] **Step 7: Commit**

```bash
git add src/upgrade.zig
git commit -m "feat(upgrade): add HTTP version resolution, download, checksum verification, and binary replacement"
```

---

## Task 3: Wire up the `tip upgrade` command in `src/main.zig`

**Files:**
- Modify: `src/main.zig`
- Test: manual verification via `zig build run -- upgrade`

**Interfaces:**
- Consumes: `upgrade.upgrade` from Task 2.
- Produces: `tip upgrade` CLI command.

- [ ] **Step 1: Add import and update the Args struct**

In `src/main.zig`:

```zig
const upgrade = @import("upgrade.zig");
```

And change the Args command union:

```zig
const Args = struct {
    command: union(enum) {
        task: task.TaskArgs,
        upgrade,
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
        \\  upgrade               Check for and apply updates
        \\
        \\Run 'tip <command> --help' for more information on a command.
        \\
    ;
};
```

- [ ] **Step 2: Add the dispatch case**

In the `main` function's switch statement:

```zig
    switch (parsed.command) {
        .task => |t| task.dispatch_task_command(init.io, init.minimal.environ, t),
        .upgrade => upgrade.upgrade(init.io, init.arena.allocator(), version_mod.version) catch |err| switch (err) {
            error.AlreadyUpToDate => {},
            error.NoReleaseFound => std.process.exit(1),
            error.DownloadFailed => {
                std.debug.print("Download failed. Check your connection.\n", .{});
                std.process.exit(1);
            },
            error.ChecksumsNotFound => {
                std.debug.print("Could not fetch checksums.txt.\n", .{});
                std.process.exit(1);
            },
            error.ChecksumMismatch => {
                std.debug.print("Download corrupted. Checksum mismatch.\n", .{});
                std.process.exit(1);
            },
            error.ExeDeleted => {
                std.debug.print("Cannot determine current executable path (binary may have been deleted).\n", .{});
                std.process.exit(1);
            },
            else => |e| return e,
        },
    }
```

- [ ] **Step 3: Verify build compiles and the command is recognized**

Run:
```bash
zig build
zig build run -- upgrade --help
```

Expected: builds, and `--help` shows the `upgrade` command in the command list.

- [ ] **Step 4: Verify `tip --version` still works and other commands are unaffected**

Run:
```bash
zig build run -- -- --version
zig build run -- -- task --list
```
Expected: version prints, task list still works.

- [ ] **Step 5: Run full test suite**

Run:
```bash
zig build test --summary all
```
Expected: all tests pass (including the upgrade utility tests from Task 1).

- [ ] **Step 6: Commit**

```bash
git add src/main.zig
git commit -m "feat(cli): wire up tip upgrade command"
```

---

## Self-Review

**Spec coverage:**
- HEAD + redirect tag resolution → Task 2, Step 1. ✓
- Version comparison before download → Task 1, Step 7 (versionCompare). ✓
- No GitHub API → Task 2, Step 1 (uses CDN URL directly). ✓
- No download just to check version → no fallback code exists. ✓
- Binary download + checksums.txt → Task 2, Step 2. ✓
- SHA-256 verification → Task 2, Step 2 (Sha256 hash + findChecksumLine). ✓
- Binary replacement (Linux/macOS rename, Windows .bat) → Task 2, Step 3. ✓
- User-facing messages ("Already up-to-date", "Updated X → Y") → Task 2, Step 4. ✓
- Error handling (network, checksum, permission) → Task 3, Step 2. ✓

**Placeholder scan:** No TBD/TODO; all Zig code shown in full.

**Type consistency:** `Platform`, `versionCompare`, `extractTagFromLocation`, `resolveLatestTag`, `downloadAndVerify`, `replaceBinary`, `upgrade` — same names and signatures across all tasks.
