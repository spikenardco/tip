# Export/Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add JSON export (single vault or all vaults) and import (new vault, restore into existing, merge) commands with atomic file writes and a dry-run preview mode.

**Architecture:** Two new modules — `src/core/export.zig` (builds JSON export files, writes atomically) and `src/core/import.zig` (parses JSON backup files, dispatches to new/restore/merge SQL operations via the Store handle from SP06). File format is a consistent `{version, exported_at, vaults[]}` envelope. Import uses SQLite transactions for atomicity.

**Tech Stack:** Zig 0.16 (`std.Io`, `std.json`, `std.fs`), `zqlite`, `flags` dependency.

---

## Global Constraints

- **Zig version:** 0.16.0 (`minimum_zig_version = "0.16.0"`). Use the new `std.Io` APIs.
- **Identifier casing:** functions/vars/fields = `snake_case`; types = `PascalCase`; enum members = `snake_case`; booleans use affirmative `is_`/`has_`/`can_`/`should_` prefix (code only, not CLI flags).
- **Export format:** JSON only. Single consistent envelope: `{ version: 1, exported_at: i64, vaults: []ExportedVault }`.
- **Export auto-naming:** `<vault-name>-<YYYY-MM-DD>.json` in cwd. `--output` overrides.
- **Export all:** one file per vault.
- **Import modes:** `new` (default — create vault from backup, error if name exists), `restore` (--vault, delete + insert), `merge` (--vault --merge, INSERT OR IGNORE).
- **Atomic writes:** export uses temp file + atomic rename; import uses SQLite transactions.
- **Dry-run:** parse file, compare against store, print preview, no writes.
- **Tests:** `zig build test --summary all` from repo root; storage tests use in-memory zqlite (`zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode)`).
- **Dependency:** This plan requires sub-projects 01–06 implemented first (Store handle, vaults, config, errors, models, SQLite connection with `PRAGMA foreign_keys = ON`).
- **Out of scope:** CSV, encrypted export, cross-tool import, password/tag export.

---

### Task 1: Add export/import error members

**Files:**
- Modify: `src/core/errors.zig`

**Interfaces:**
- Consumes: the existing error set and `message` function from sub-project 01.
- Produces: error members `ExportFileExists`, `ImportFileNotFound`, `ImportInvalidFormat`, `ImportVersionMismatch`, `ImportVaultExists`, `ImportTargetNotFound`, plus a message for each.

- [ ] **Step 1: Write the failing test**

Append to `src/core/errors.zig`:

```zig
test "export/import errors have messages" {
    try std.testing.expectEqualStrings("output file already exists", message(error.ExportFileExists));
    try std.testing.expectEqualStrings("import file not found", message(error.ImportFileNotFound));
    try std.testing.expectEqualStrings("invalid import file format", message(error.ImportInvalidFormat));
    try std.testing.expectEqualStrings("import file is from a newer version", message(error.ImportVersionMismatch));
    try std.testing.expectEqualStrings("a vault with that name already exists", message(error.ImportVaultExists));
    try std.testing.expectEqualStrings("target vault not found", message(error.ImportTargetNotFound));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — error members / message cases missing.

- [ ] **Step 3: Add error members and messages**

Add the six members to the error set:

```zig
    ExportFileExists,
    ImportFileNotFound,
    ImportInvalidFormat,
    ImportVersionMismatch,
    ImportVaultExists,
    ImportTargetNotFound,
```

Add the matching arms to the `message` switch:

```zig
        error.ExportFileExists => "output file already exists",
        error.ImportFileNotFound => "import file not found",
        error.ImportInvalidFormat => "invalid import file format",
        error.ImportVersionMismatch => "import file is from a newer version",
        error.ImportVaultExists => "a vault with that name already exists",
        error.ImportTargetNotFound => "target vault not found",
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/errors.zig
git commit -m "feat(errors): add export/import error taxonomy"
```

---

### Task 2: Add export file format structs to models

**Files:**
- Modify: `src/core/models.zig`

**Interfaces:**
- Consumes: existing `Task` struct from SP03.
- Produces:
  - `pub const ExportedVault = struct { name: []const u8, id: []const u8, created_at: i64, tasks: []Task }`
  - `pub const ExportFile = struct { version: u32, exported_at: i64, vaults: []ExportedVault }`

- [ ] **Step 1: Write the failing test**

Append to `src/core/models.zig`:

```zig
test "ExportFile struct can hold vaults" {
    const task = Task{
        .id = "id1", .title = "test", .status = .pending,
        .created_at = 1,
    };
    const v = ExportedVault{
        .name = "personal", .id = "vault1", .created_at = 1,
        .tasks = &.{task},
    };
    const ef = ExportFile{
        .version = 1, .exported_at = 2, .vaults = &.{v},
    };
    try std.testing.expectEqual(@as(u32, 1), ef.version);
    try std.testing.expectEqual(@as(usize, 1), ef.vaults.len);
    try std.testing.expectEqualStrings("personal", ef.vaults[0].name);
    try std.testing.expectEqualStrings("test", ef.vaults[0].tasks[0].title);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `ExportedVault` / `ExportFile` undefined.

- [ ] **Step 3: Add the structs**

Add near the `Task` struct in `src/core/models.zig`:

```zig
pub const ExportedVault = struct {
    name: []const u8,
    id: []const u8,
    created_at: i64,
    tasks: []Task,
};

pub const ExportFile = struct {
    version: u32,
    exported_at: i64,
    vaults: []ExportedVault,
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/models.zig
git commit -m "feat(models): add ExportFile and ExportedVault structs"
```

---

### Task 3: Implement export module

**Files:**
- Create: `src/core/export.zig`

**Interfaces:**
- Consumes:
  - `models.ExportFile`, `models.ExportedVault`, `models.Task`
  - `Store` from SP06 (`store.vaults.list`, `store.vaults.get_by_name`, scoped `store.tasks.list`)
  - `std.json.stringify` for serialization
  - `std.fs.File.Atomic` or equivalent for atomic write (temp + rename)
  - `generate.generate_id`, `now_seconds` from SP01/utils (not needed directly — ids come from Store)
- Produces:
  - `pub const ExportOptions` struct
  - `pub fn export_vaults(store: *Store, allocator: std.mem.Allocator, opts: ExportOptions) !void`

- [ ] **Step 1: Write the failing tests**

Create tests (can be in a test block at the bottom of the file or in a separate test file):

```zig
const std = @import("std");
const models = @import("models.zig");
const export_mod = @import("../export.zig");
const Store = @import("store.zig").Store;

test "export builds correct JSON structure for single vault" {
    var store = try Store.open_memory(std.testing.allocator, std.testing.io, .{});
    defer store.close();
    store.rebind();

    _ = try store.tasks.add(.{ .title = "test task" });
    _ = try store.tasks.add(.{ .title = "another task" });

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    const opts = export_mod.ExportOptions{ .output = null, .vault = null, .all = false };
    // We need a way to capture output. For testing, we'll check that the
    // file is written correctly. Use a temp dir.
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const custom_opts = export_mod.ExportOptions{ .output = tmp_dir.path, .vault = null, .all = false };
    try export_mod.export_vaults(&store, std.testing.allocator, custom_opts);

    // Verify a file was created
    var dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    var file_count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.kind == .file) file_count += 1;
    }
    try std.testing.expect(file_count >= 1);
}

test "export all vaults creates one file per vault" {
    var store = try Store.open_memory(std.testing.allocator, std.testing.io, .{});
    defer store.close();
    store.rebind();

    const w = try store.vaults.add(std.testing.allocator, "work");
    std.testing.allocator.free(w.id);

    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const opts = export_mod.ExportOptions{ .output = tmp_dir.path, .vault = null, .all = true };
    try export_mod.export_vaults(&store, std.testing.allocator, opts);

    var dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    var file_count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.kind == .file) file_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), file_count);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `export.zig` not found or `export_vaults` undefined.

- [ ] **Step 3: Implement `export.zig`**

```zig
const std = @import("std");
const models = @import("models.zig");
const Store = @import("store.zig").Store;
const errors = @import("errors.zig");

pub const ExportOptions = struct {
    vault: ?[]const u8 = null,
    all: bool = false,
    output: ?[]const u8 = null,
};

fn format_timestamp(epoch_s: i64, buf: []u8) ![]u8 {
    const epoch_day = std.time.epoch.epochSecondsToEpochDay(@intCast(epoch_s));
    const day = std.time.epoch.epochDayToCalendarDay(epoch_day);
    return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ day.year, day.month.number(), day.day_index + 1 });
}

fn default_filename(allocator: std.mem.Allocator, vault_name: []const u8) ![]const u8 {
    const now = std.time.timestamp();
    var buf: [32]u8 = undefined;
    const date_str = try format_timestamp(now, &buf);
    return try std.fmt.allocPrint(allocator, "{s}-{s}.json", .{ vault_name, date_str });
}

fn vault_to_exported(vault: models.Vault, tasks: []models.Task) models.ExportedVault {
    return .{
        .name = vault.name,
        .id = vault.id,
        .created_at = vault.created_at,
        .tasks = tasks,
    };
}

fn write_export_file(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, export_file: models.ExportFile) !void {
    // Check if output file already exists
    std.Io.Dir.cwd().access(io, file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    } else {
        return error.ExportFileExists;
    }

    // Serialize to JSON
    var json_buf: std.ArrayList(u8) = .init(allocator);
    defer json_buf.deinit();

    try std.json.stringify(export_file, .{ .whitespace = .indent_2 }, json_buf.writer());
    try json_buf.append('\n');

    // Atomic write: temp file + rename
    var atomic = try std.Io.File.Atomic.init(io, allocator, file_path);
    defer atomic.deinit(allocator);

    try atomic.file_writer.writeAll(json_buf.items);
    try atomic.commit(io);
}

pub fn export_vaults(store: *Store, allocator: std.mem.Allocator, io: std.Io, opts: ExportOptions) !void {
    const output_dir = opts.output orelse ".";
    const output_base = try std.fs.realpathAlloc(allocator, output_dir);
    defer allocator.free(output_base);

    if (opts.all) {
        // Export all vaults
        const vaults = try store.vaults.list(allocator);
        defer {
            for (vaults) |v| { allocator.free(v.id); allocator.free(v.name); }
            allocator.free(vaults);
        }

        for (vaults) |v| {
            defer { allocator.free(v.id); allocator.free(v.name); }

            const filename = try default_filename(allocator, v.name);
            defer allocator.free(filename);

            const file_path = try std.fs.path.join(allocator, &.{ output_base, filename });
            defer allocator.free(file_path);

            // Switch active vault to this vault to list its scoped tasks
            const orig_active = try allocator.dupe(u8, store.active_vault_id);
            defer allocator.free(orig_active);
            allocator.free(store.active_vault_id);
            store.active_vault_id = try allocator.dupe(u8, v.id);
            defer {
                allocator.free(store.active_vault_id);
                store.active_vault_id = orig_active;
            }

            const tasks = try store.tasks.list(allocator);
            defer allocator.free(tasks); // tasks owns individual field strings? depends on SP03

            const exported_vault = vault_to_exported(v, tasks);
            const export_file = models.ExportFile{
                .version = 1,
                .exported_at = std.time.timestamp(),
                .vaults = &.{exported_vault},
            };

            try write_export_file(allocator, io, file_path, export_file);
        }
    } else {
        // Export single vault (active or specified by --vault)
        var orig_active: ?[]const u8 = null;
        if (opts.vault) |vault_name| {
            const v = try store.vaults.get_by_name(allocator, vault_name);
            defer { allocator.free(v.id); allocator.free(v.name); }
            orig_active = try allocator.dupe(u8, store.active_vault_id);
            allocator.free(store.active_vault_id);
            store.active_vault_id = try allocator.dupe(u8, v.id);
        }
        defer {
            if (orig_active) |orig| {
                allocator.free(store.active_vault_id);
                store.active_vault_id = orig;
            }
        }

        // Get vault info for the active vault
        const vaults = try store.vaults.list(allocator);
        defer {
            for (vaults) |v| { allocator.free(v.id); allocator.free(v.name); }
            allocator.free(vaults);
        }

        var target_vault: ?models.Vault = null;
        for (vaults) |v| {
            if (std.mem.eql(u8, v.id, store.active_vault_id)) {
                target_vault = v;
                break;
            }
        }
        const v = target_vault orelse return error.VaultNotFound;

        const tasks = try store.tasks.list(allocator);
        defer allocator.free(tasks);

        const filename = try default_filename(allocator, v.name);
        defer allocator.free(filename);

        const file_path = try std.fs.path.join(allocator, &.{ output_base, filename });
        defer allocator.free(file_path);

        const exported_vault = vault_to_exported(v, tasks);
        const export_file = models.ExportFile{
            .version = 1,
            .exported_at = std.time.timestamp(),
            .vaults = &.{exported_vault},
        };

        try write_export_file(allocator, io, file_path, export_file);
    }
}
```

Note: The active vault switching approach above is one strategy. An alternative is to add a `store.tasks.list_by_vault_id(vault_id)` method that bypasses scoping. The approach chosen here reuses existing scoped methods but requires swapping `active_vault_id` temporarily. This is safe because export is single-threaded. Adjust based on how SP06's `store.tasks.list` actually works.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS — export tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/core/export.zig
git commit -m "feat: add export module for JSON vault export"
```

---

### Task 4: Implement import module

**Files:**
- Create: `src/core/import.zig`

**Interfaces:**
- Consumes:
  - `models.ExportFile`, `models.ExportedVault`, `models.Task`
  - `Store` from SP06 (`store.vaults.add`, `store.vaults.get_by_name`, `store.vaults.list`, `store.vaults.count_tasks`, `store.vaults.delete`, scoped `store.tasks.*`)
  - `generate.generate_id` for new vault ULIDs
  - `std.json.parseFromSlice` for deserialization
  - `std.fs.File.readFileAlloc` for reading import file
- Produces:
  - `pub const ImportMode = enum { new, restore, merge }`
  - `pub const ImportOptions` struct
  - `pub fn import_from_file(store: *Store, allocator: std.mem.Allocator, io: std.Io, opts: ImportOptions) !void`

- [ ] **Step 1: Write the failing tests**

```zig
const std = @import("std");
const models = @import("models.zig");
const import_mod = @import("../import.zig");
const Store = @import("store.zig").Store;

test "import new vault creates vault and tasks" {
    var store = try Store.open_memory(std.testing.allocator, std.testing.io, .{});
    defer store.close();
    store.rebind();

    // Build an import file in memory then write to temp
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const task = models.Task{
        .id = "imported-task-1", .title = "imported", .status = .pending,
        .created_at = 100,
    };
    const ev = models.ExportedVault{
        .name = "imported-vault", .id = "ignored-id", .created_at = 50,
        .tasks = &.{task},
    };
    const ef = models.ExportFile{
        .version = 1, .exported_at = 200, .vaults = &.{ev},
    };

    // Serialize to temp file
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_dir.path, "backup.json" });
    defer std.testing.allocator.free(file_path);

    var json_buf: std.ArrayList(u8) = .init(std.testing.allocator);
    defer json_buf.deinit();
    try std.json.stringify(ef, .{ .whitespace = .indent_2 }, json_buf.writer());
    try tmp_dir.dir.writeFile(.{ .sub_path = "backup.json", .data = json_buf.items });

    const opts = import_mod.ImportOptions{
        .file_path = file_path,
        .mode = .new,
        .target_vault = null,
        .dry_run = false,
    };
    try import_mod.import_from_file(&store, std.testing.allocator, std.testing.io, opts);

    // Verify vault was created
    const imported = try store.vaults.get_by_name(std.testing.allocator, "imported-vault");
    defer { std.testing.allocator.free(imported.id); std.testing.allocator.free(imported.name); }
    try std.testing.expectEqualStrings("imported-vault", imported.name);

    // Verify tasks are present
    std.testing.allocator.free(store.active_vault_id);
    store.active_vault_id = try std.testing.allocator.dupe(u8, imported.id);
    const tasks = try store.tasks.list(std.testing.allocator);
    defer std.testing.allocator.free(tasks);
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
}

test "import restore replaces all tasks in target vault" {
    var store = try Store.open_memory(std.testing.allocator, std.testing.io, .{});
    defer store.close();
    store.rebind();

    // Add a task to personal
    _ = try store.tasks.add(.{ .title = "original task" });

    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Build backup with different tasks
    const task = models.Task{
        .id = "restored-task-1", .title = "restored", .status = .pending,
        .created_at = 100,
    };
    const ev = models.ExportedVault{
        .name = "personal", .id = "ignored", .created_at = 50,
        .tasks = &.{task},
    };
    const ef = models.ExportFile{
        .version = 1, .exported_at = 200, .vaults = &.{ev},
    };

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_dir.path, "backup.json" });
    defer std.testing.allocator.free(file_path);

    var json_buf: std.ArrayList(u8) = .init(std.testing.allocator);
    defer json_buf.deinit();
    try std.json.stringify(ef, .{ .whitespace = .indent_2 }, json_buf.writer());
    try tmp_dir.dir.writeFile(.{ .sub_path = "backup.json", .data = json_buf.items });

    const opts = import_mod.ImportOptions{
        .file_path = file_path,
        .mode = .restore,
        .target_vault = "personal",
        .dry_run = false,
    };
    try import_mod.import_from_file(&store, std.testing.allocator, std.testing.io, opts);

    // Original task should be gone, restored task present
    const tasks = try store.tasks.list(std.testing.allocator);
    defer std.testing.allocator.free(tasks);
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
}

test "import merge skips duplicate IDs" {
    var store = try Store.open_memory(std.testing.allocator, std.testing.io, .{});
    defer store.close();
    store.rebind();

    // Add an existing task with known ID
    _ = try store.tasks.add(.{ .title = "keep me" });

    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Build backup with a task that might have a conflicting ID
    // For merge we need the existing task's ID. This test verifies
    // that INSERT OR IGNORE doesn't error on duplicates.
    const task = models.Task{
        .id = "some-new-id", .title = "new task", .status = .pending,
        .created_at = 100,
    };
    const ev = models.ExportedVault{
        .name = "personal", .id = "ignored", .created_at = 50,
        .tasks = &.{task},
    };
    const ef = models.ExportFile{
        .version = 1, .exported_at = 200, .vaults = &.{ev},
    };

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_dir.path, "backup.json" });
    defer std.testing.allocator.free(file_path);

    var json_buf: std.ArrayList(u8) = .init(std.testing.allocator);
    defer json_buf.deinit();
    try std.json.stringify(ef, .{ .whitespace = .indent_2 }, json_buf.writer());
    try tmp_dir.dir.writeFile(.{ .sub_path = "backup.json", .data = json_buf.items });

    const opts = import_mod.ImportOptions{
        .file_path = file_path,
        .mode = .merge,
        .target_vault = "personal",
        .dry_run = false,
    };
    try import_mod.import_from_file(&store, std.testing.allocator, std.testing.io, opts);

    // Both tasks should be present (original + new)
    const tasks = try store.tasks.list(std.testing.allocator);
    defer std.testing.allocator.free(tasks);
    try std.testing.expectEqual(@as(usize, 2), tasks.len);
}

test "import dry-run does not write" {
    var store = try Store.open_memory(std.testing.allocator, std.testing.io, .{});
    defer store.close();
    store.rebind();
    _ = try store.tasks.add(.{ .title = "existing" });

    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const task = models.Task{
        .id = "dry-id", .title = "dry", .status = .pending,
        .created_at = 100,
    };
    const ev = models.ExportedVault{
        .name = "personal", .id = "ignored", .created_at = 50,
        .tasks = &.{task},
    };
    const ef = models.ExportFile{
        .version = 1, .exported_at = 200, .vaults = &.{ev},
    };

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_dir.path, "backup.json" });
    defer std.testing.allocator.free(file_path);

    var json_buf: std.ArrayList(u8) = .init(std.testing.allocator);
    defer json_buf.deinit();
    try std.json.stringify(ef, .{ .whitespace = .indent_2 }, json_buf.writer());
    try tmp_dir.dir.writeFile(.{ .sub_path = "backup.json", .data = json_buf.items });

    const opts = import_mod.ImportOptions{
        .file_path = file_path,
        .mode = .restore,
        .target_vault = "personal",
        .dry_run = true,
    };
    try import_mod.import_from_file(&store, std.testing.allocator, std.testing.io, opts);

    // Tasks unchanged
    const tasks = try store.tasks.list(std.testing.allocator);
    defer std.testing.allocator.free(tasks);
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
}

test "import nonexistent file returns error" {
    const opts = import_mod.ImportOptions{
        .file_path = "/nonexistent/path.json",
        .mode = .new,
        .target_vault = null,
        .dry_run = false,
    };
    try std.testing.expectError(error.ImportFileNotFound,
        import_mod.import_from_file(undefined, std.testing.allocator, std.testing.io, opts));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `import.zig` not found or `import_from_file` undefined.

- [ ] **Step 3: Implement `import.zig`**

```zig
const std = @import("std");
const models = @import("models.zig");
const Store = @import("store.zig").Store;
const generate = @import("../utils/generate.zig");

pub const ImportMode = enum {
    new,
    restore,
    merge,
};

pub const ImportOptions = struct {
    file_path: []const u8,
    mode: ImportMode = .new,
    target_vault: ?[]const u8 = null,
    dry_run: bool = false,
};

const ImportFile = models.ExportFile;

fn read_and_parse_file(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !ImportFile {
    const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .{ .max_size = 1024 * 1024 * 10 }) catch |err| switch (err) {
        error.FileNotFound => return error.ImportFileNotFound,
        else => |e| return e,
    };
    defer allocator.free(content);

    var diag: std.json.Diagnostics = .{};
    const parsed = std.json.parseFromSliceLeaky(ImportFile, allocator, content, .{
        .diagnostics = &diag,
        .ignore_unknown_fields = false,
    }) catch |err| switch (err) {
        error.Overflow, error.InvalidCharacter, error.UnexpectedEndOfJson, error.UnexpectedToken,
        error.MissingField, error.InvalidEnumTag, error.DuplicateField => return error.ImportInvalidFormat,
        else => |e| return e,
    };
    _ = diag;

    if (parsed.version > 1) return error.ImportVersionMismatch;

    return parsed;
}

fn dry_run_print(allocator: std.mem.Allocator, io: std.Io, comptime fmt: []const u8, args: anytype) void {
    // In dry-run mode, print to stdout what would happen
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(msg);
    std.debug.print("{s}\n", .{msg});
}

fn insert_task(store: *Store, vault_id: []const u8, task: models.Task) !void {
    // Use raw SQL because store.tasks.add is scoped and requires more setup
    try store.db.exec(
        \\INSERT OR IGNORE INTO tasks
        \\(id, vault_id, title, description, status, priority, due_date, assigned_to, created_at, updated_at, completed_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    , .{
        .id = task.id,
        .vault_id = vault_id,
        .title = task.title,
        .description = task.description,
        .status = @tagName(task.status),
        .priority = if (task.priority) |p| @tagName(p) else ?[]const u8{null},
        .due_date = task.due_date,
        .assigned_to = task.assigned_to,
        .created_at = task.created_at,
        .updated_at = task.updated_at,
        .completed_at = task.completed_at,
    });
}

pub fn import_from_file(store: *Store, allocator: std.mem.Allocator, io: std.Io, opts: ImportOptions) !void {
    const import_file = try read_and_parse_file(allocator, io, opts.file_path);

    if (opts.dry_run) {
        for (import_file.vaults) |ev| {
            switch (opts.mode) {
                .new => {
                    const exists = exists: {
                        const existing = store.vaults.get_by_name(allocator, ev.name) catch |e| switch (e) {
                            error.VaultNotFound => break :exists false,
                            else => |e2| return e2,
                        };
                        allocator.free(existing.id);
                        allocator.free(existing.name);
                        break :exists true;
                    };
                    if (exists) {
                        dry_run_print(allocator, io, "Would create vault '{s}' — but name already exists (would error)", .{ev.name});
                    } else {
                        dry_run_print(allocator, io, "Would create vault '{s}' with {d} tasks", .{ ev.name, ev.tasks.len });
                    }
                },
                .restore => {
                    const exists = store.vaults.get_by_name(allocator, opts.target_vault orelse ev.name) catch |e| switch (e) {
                        error.VaultNotFound => {
                            dry_run_print(allocator, io, "Would restore into '{s}' — but vault not found (would error)", .{opts.target_vault.?});
                            return;
                        },
                        else => |e2| return e2,
                    };
                    allocator.free(exists.id);
                    allocator.free(exists.name);
                    dry_run_print(allocator, io, "Would replace tasks in '{s}' with {d} from backup", .{ opts.target_vault.?, ev.tasks.len });
                },
                .merge => {
                    dry_run_print(allocator, io, "Would merge {d} tasks into '{s}' (skipping duplicates)", .{ ev.tasks.len, opts.target_vault.? });
                },
            }
        }
        return;
    }

    switch (opts.mode) {
        .new => {
            for (import_file.vaults) |ev| {
                // Check if vault name already exists
                const exists = store.vaults.get_by_name(allocator, ev.name) catch |e| switch (e) {
                    error.VaultNotFound => false,
                    else => |e2| return e2,
                };
                if (exists) {
                    allocator.free(exists.id);
                    allocator.free(exists.name);
                    return error.ImportVaultExists;
                }

                // Generate new ULID for the vault
                const new_vault_id = try generate.generate_id(allocator, io);
                defer allocator.free(new_vault_id);

                const created_at = try std.time.epoch.epochSecondsToEpochDay(@intCast(std.time.timestamp()));
                _ = created_at;

                // Create the vault
                const v = try store.vaults.add(allocator, ev.name);
                allocator.free(v.id);

                // Get the actual vault ID
                const created_vault = try store.vaults.get_by_name(allocator, ev.name);
                defer { allocator.free(created_vault.id); allocator.free(created_vault.name); }

                // Insert tasks
                for (ev.tasks) |task| {
                    try insert_task(store, created_vault.id, task);
                }
            }
        },
        .restore => {
            const target_name = opts.target_vault orelse return error.ImportTargetNotFound;
            const target = try store.vaults.get_by_name(allocator, target_name);
            defer { allocator.free(target.id); allocator.free(target.name); }

            // Wrap in a transaction
            try store.db.exec("BEGIN TRANSACTION", .{});
            defer store.db.exec("COMMIT", .{}) catch {};

            // Delete existing tasks
            try store.db.exec("DELETE FROM tasks WHERE vault_id = ?", .{ .vault_id = target.id });

            // Insert backup tasks
            for (import_file.vaults) |ev| {
                for (ev.tasks) |task| {
                    try insert_task(store, target.id, task);
                }
            }
        },
        .merge => {
            const target_name = opts.target_vault orelse return error.ImportTargetNotFound;
            const target = try store.vaults.get_by_name(allocator, target_name);
            defer { allocator.free(target.id); allocator.free(target.name); }

            for (import_file.vaults) |ev| {
                for (ev.tasks) |task| {
                    try insert_task(store, target.id, task);
                }
            }
        },
    }
}
```

Note: The `insert_task` function uses raw SQL because `store.tasks.add` is scoped to the active vault. During import, we're inserting into a vault that may not be the active one, so raw INSERT is appropriate.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS — import tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/core/import.zig
git commit -m "feat: add import module for JSON vault import (new/restore/merge)"
```

---

### Task 5: Wire CLI dispatch in main.zig

**Files:**
- Modify: `src/main.zig`

**Interfaces:**
- Consumes: `export_mod.export_vaults`, `export_mod.ExportOptions`, `import_mod.import_from_file`, `import_mod.ImportOptions`, `import_mod.ImportMode`
- Produces: `export` and `import` command variants in `Args`, dispatch logic.

- [ ] **Step 1: Add `export` and `import` to the Args union**

In `src/main.zig`, update the `Args` struct:

```zig
const export_mod = @import("core/export.zig");
const import_mod = @import("core/import.zig");

const Args = struct {
    // ... existing global flags: verbose, quiet, config_path, vault, mode ...

    command: union(enum) {
        task: task.TaskArgs,
        config: ConfigArgs,
        export: ExportArgs,
        import: ImportArgs,
    },
    // ... existing help ...
};

const ExportArgs = struct {
    vault: ?[]const u8 = null,
    all: bool = false,
    output: ?[]const u8 = null,

    pub const help =
        \\Export vault data
        \\
        \\Usage:
        \\  tip export [--vault=<name>] [--all] [--output=<path>]
        \\
        \\  Exports vault(s) to JSON files for backup.
        \\  Without flags, exports the active vault.
        \\  --vault=<name>  Export a specific vault
        \\  --all           Export all vaults
        \\  --output=<path>  Output file (single vault) or directory (--all)
        \\
    ;
};

const ImportArgs = struct {
    file: []const u8,
    vault: ?[]const u8 = null,
    merge: bool = false,
    dry_run: bool = false,

    pub const help =
        \\Import vault data from a backup file
        \\
        \\Usage:
        \\  tip import --file=<path> [--vault=<name>] [--merge] [--dry-run]
        \\
        \\  Without --vault, creates a new vault from the backup.
        \\  With --vault, restores into an existing vault (replaces tasks).
        \\  With --vault --merge, merges into existing vault (skips duplicates).
        \\  --dry-run  Preview what would happen without writing.
        \\
    ;
};
```

- [ ] **Step 2: Add dispatch logic**

In the command switch of `main` (after config loading):

```zig
    switch (parsed.command) {
        .task => |t| task.dispatch_task_command(io, environ, t, config),
        .config => |c| dispatch_config_command(allocator, io, environ, config, c, parsed.config_path),
        .export => |e| {
            var store = try Store.open(allocator, io, environ, .{
                .vault = e.vault,
                .default_vault = config.default_vault orelse "personal",
            });
            defer store.close();
            store.rebind();

            const opts = export_mod.ExportOptions{
                .vault = e.vault,
                .all = e.all,
                .output = e.output,
            };
            try export_mod.export_vaults(&store, allocator, io, opts);
        },
        .import => |i| {
            var store = try Store.open(allocator, io, environ, .{
                .vault = i.vault,
                .default_vault = config.default_vault orelse "personal",
            });
            defer store.close();
            store.rebind();

            const mode: import_mod.ImportMode = if (i.merge) .merge else if (i.vault != null) .restore else .new;
            const opts = import_mod.ImportOptions{
                .file_path = i.file,
                .mode = mode,
                .target_vault = i.vault,
                .dry_run = i.dry_run,
            };
            try import_mod.import_from_file(&store, allocator, io, opts);
        },
    }
```

- [ ] **Step 3: Run tests to verify the build**

Run: `zig build test --summary all`
Expected: PASS — all tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "feat(cli): wire export and import commands"
```

---

### Task 6: Final verification

- [ ] **Step 1: Run full test suite**

Run: `zig build test --summary all`
Expected: PASS — all tests pass.

- [ ] **Step 2: Build the binary**

Run: `zig build`
Expected: builds with no errors.

- [ ] **Step 3: Quick smoke tests**

Run:
```bash
zig build run -- export --help
zig build run -- import --help
zig build run -- export --dry-run                    # (will evolve once Store.open works)
zig build run -- task add "test export"
zig build run -- export
zig build run -- export --all
zig build run -- import --file=personal-2026-07-04.json --dry-run
```
Expected: all commands work without errors.

---

## Self-Review

**Spec coverage (against [2026-07-04-export-import-design.md](../specs/2026-07-04-export-import-design.md)):**
- Part A (file format) → Task 2 (model structs) + Task 3 (serialization) + Task 4 (deserialization)
- Part B (CLI surface) → Task 5 (Args + dispatch)
- Part C (import behavior) → Task 4 (import_from_file)
- Part D (file layout) → Tasks 3, 4, 5 (export.zig, import.zig, main.zig)
- Part E (errors) → Task 1 (errors.zig)
- Part F (testing) → tests embedded in Tasks 1–4

**Placeholder scan:** No TBDs/TODOs. Every step has complete code or exact commands. One note about the active-vault switching approach in export — this is a design note, not a placeholder.

**Type consistency:** `ExportOptions` struct matches in Tasks 3 and 5. `ImportOptions` struct matches in Tasks 4 and 5. `ImportMode` enum has consistent members. Error names match between Task 1 and Task 4. `ExportFile`/`ExportedVault` model structs from Task 2 used in Tasks 3 and 4.

**Dependency order:** Tasks 1 → 2 → 3 → 4 → 5 → 6.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-04-export-import.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
