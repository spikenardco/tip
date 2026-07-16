# Sub-project 03 — Storage Handle API + Tasks Table Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the threaded `(allocator, io, dir, ...)` parameter pattern with a `Vault` handle owning shared context, migrate task CRUD from JSON to SQLite, and remove the JSON storage module.

**Architecture:** A `Vault` handle wraps a `*zqlite.Conn` connection and exposes a `vault.tasks` child handle. Handle methods return data (no printing); the CLI layer in `task.zig` formats output. Platform directory resolution moves to `src/storage/dir.zig` with a comptime config. Ansi rendering helpers extract to `src/utils/ansi.zig`. Tasks table schema in `002_create_tasks.sql`.

**Tech Stack:** Zig 0.16 (`std.Io` async model), `zqlite` dependency, `zqlite` API.

## Global Constraints

- **Zig version:** 0.16.0 (`minimum_zig_version = "0.16.0"`). Use the new `std.Io` APIs.
- **Identifier casing:** functions/vars/fields = `snake_case`; types = `PascalCase`; enum members = `snake_case`.
- **zqlite API:** `zqlite.open(path, flags)` for connections (`zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode`). `conn.exec(sql, params)` for statements (2 args). `conn.row(sql, params)` returns `?Row` for single-row queries. `conn.rows(sql, params)` returns `Rows` for multi-row queries (iterate with `rows.next()`). Column access: `row.int(0)`, `row.text(1)`, `row.nullableText(2)`, `row.get(T, col)`.
- **Environment variables:** use `environ.getPosix(name)` which returns `?[]const u8` with no allocation.
- **Error taxonomy (sub-project 01):** `TaskNotFound`, `AmbiguousPrefix`, `StorageFailure`, `EmptyTitle`. Commands return errors; `main.zig` renders via `errors.describe`/`errors.exit_code`.
- **Tests:** `zig build test --summary all` from repo root. New test files under `src/` are auto-discovered.
- **No global state.** Every function takes allocator/io/environ explicitly.
- **Out of scope:** `complete`/`start` CLI subcommands (04), unified prefix-matcher (04), `--verbose` (05), multi-vault (06), JSON export/import (future).

---

### Task 1: Extract Ansi helpers to `src/utils/ansi.zig`

**Files:**
- Create: `src/utils/ansi.zig`
- Modify: `src/core/task.zig` (remove Ansi enum and helper functions, add import)
- Test: `src/utils/ansi.zig` (tests live in same file)

**Interfaces:**
- Consumes: `models.Task.Status`, `models.Task.Priority` (from `models.zig`).
- Produces:
  - `pub const Ansi = enum { red, green, yellow, cyan, reset };`
  - `pub fn ansi_code(c: Ansi) []const u8`
  - `pub fn priority_glyph(priority: ?models.Task.Priority) []const u8`
  - `pub fn priority_color(priority: ?models.Task.Priority) Ansi`
  - `pub fn status_icon(status: models.Task.Status) []const u8`
  - `pub fn status_color(status: models.Task.Status) Ansi`

- [ ] **Step 1: Create `src/utils/ansi.zig` with tests**

```zig
const std = @import("std");
const models = @import("../core/models.zig");

pub const Ansi = enum {
    red,
    green,
    yellow,
    cyan,
    reset,
};

pub fn ansi_code(c: Ansi) []const u8 {
    return switch (c) {
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .cyan => "\x1b[36m",
        .reset => "\x1b[0m",
    };
}

pub fn priority_glyph(priority: ?models.Task.Priority) []const u8 {
    if (priority) |p| {
        return switch (p) {
            .high => "↑",
            .medium => "-",
            .low => "↓",
        };
    }
    return "";
}

pub fn priority_color(priority: ?models.Task.Priority) Ansi {
    if (priority) |p| {
        return switch (p) {
            .high => .red,
            .medium => .yellow,
            .low => .green,
        };
    }
    return .reset;
}

pub fn status_icon(status: models.Task.Status) []const u8 {
    return switch (status) {
        .pending => "○",
        .in_progress => "⟳",
        .completed => "✓",
    };
}

pub fn status_color(status: models.Task.Status) Ansi {
    return switch (status) {
        .pending => .reset,
        .in_progress => .cyan,
        .completed => .green,
    };
}

test "ansi_code returns escape sequences" {
    try std.testing.expectEqualStrings("\x1b[31m", ansi_code(.red));
    try std.testing.expectEqualStrings("\x1b[0m", ansi_code(.reset));
}

test "priority_glyph maps priorities" {
    try std.testing.expectEqualStrings("↑", priority_glyph(.high));
    try std.testing.expectEqualStrings("-", priority_glyph(.medium));
    try std.testing.expectEqualStrings("↓", priority_glyph(.low));
    try std.testing.expectEqualStrings("", priority_glyph(null));
}

test "status_icon maps statuses" {
    try std.testing.expectEqualStrings("○", status_icon(.pending));
    try std.testing.expectEqualStrings("⟳", status_icon(.in_progress));
    try std.testing.expectEqualStrings("✓", status_icon(.completed));
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS — all three new tests pass.

- [ ] **Step 3: Update `src/core/task.zig` to import from ansi module**

In `src/core/task.zig`, replace the entire local Ansi enum + helper functions block:

```zig
const Ansi = enum {
    red,
    green,
    yellow,
    cyan,
    reset,
};

fn ansi_code(c: Ansi) []const u8 {
    return switch (c) {
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .cyan => "\x1b[36m",
        .reset => "\x1b[0m",
    };
}

fn priority_glyph(priority: ?models.Task.Priority) []const u8 {
    if (priority) |p| {
        return switch (p) {
            .high => "↑",
            .medium => "-",
            .low => "↓",
        };
    }
    return "";
}

fn priority_color(priority: ?models.Task.Priority) Ansi {
    if (priority) |p| {
        return switch (p) {
            .high => .red,
            .medium => .yellow,
            .low => .green,
        };
    }
    return .reset;
}

fn status_icon(status: models.Task.Status) []const u8 {
    return switch (status) {
        .pending => "○",
        .in_progress => "⟳",
        .completed => "✓",
    };
}

fn status_color(status: models.Task.Status) Ansi {
    return switch (status) {
        .pending => .reset,
        .in_progress => .cyan,
        .completed => .green,
    };
}
```

with:

```zig
const ansi = @import("../utils/ansi.zig");
```

Then replace every call site in the same file:
- `ansi_code(.red)` → `ansi.ansi_code(.red)`
- `ansi_code(.reset)` → `ansi.ansi_code(.reset)`
- `ansi_code(.cyan)` → `ansi.ansi_code(.cyan)`
- `ansi_code(.yellow)` → `ansi.ansi_code(.yellow)`
- `ansi_code(.green)` → `ansi.ansi_code(.green)`
- `status_icon(...)` → `ansi.status_icon(...)`
- `status_color(...)` → `ansi.status_color(...)`
- `priority_glyph(...)` → `ansi.priority_glyph(...)`
- `priority_color(...)` → `ansi.priority_color(...)`
- Type `Ansi` → `ansi.Ansi`

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS — all existing task tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/utils/ansi.zig src/core/task.zig
git commit -m "refactor: extract ansi helpers to src/utils/ansi.zig"
```

---

### Task 2: Create `src/storage/dir.zig` with comptime platform config

**Files:**
- Create: `src/storage/dir.zig`
- Modify: `src/core/task.zig` (update import path for `open_data_dir`)

**Interfaces:**
- Consumes: `allocator`, `io`, `environ` for platform data directory resolution.
- Produces: `pub fn open_data_dir(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !std.Io.Dir`
- Replaces: `src/storage/json.zig`'s `open_data_dir` (the other json functions remain)

- [ ] **Step 1: Create `src/storage/dir.zig`**

```zig
const std = @import("std");
const builtin = @import("builtin");

const DirConfig = struct {
    primary_env: []const u8,
    fallback_env: ?[]const u8,
    primary_subpath: []const u8,
    fallback_subpath: []const u8,
};

const dir_config: DirConfig = switch (builtin.os.tag) {
    .linux => .{
        .primary_env = "XDG_DATA_HOME",
        .fallback_env = "HOME",
        .primary_subpath = "tip",
        .fallback_subpath = ".local/share/tip",
    },
    .macos => .{
        .primary_env = "HOME",
        .fallback_env = null,
        .primary_subpath = "Library/Application Support/tip",
        .fallback_subpath = "",
    },
    .windows => .{
        .primary_env = "APPDATA",
        .fallback_env = null,
        .primary_subpath = "tip",
        .fallback_subpath = "",
    },
    else => @compileError("unsupported OS"),
};

/// Opens (or creates) the platform-specific data directory for storing app data.
/// Uses a comptime config per platform — no runtime OS branches.
pub fn open_data_dir(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !std.Io.Dir {
    if (environ.getPosix(dir_config.primary_env)) |p| {
        const base = try std.fs.path.join(allocator, &.{ p, dir_config.primary_subpath });
        defer allocator.free(base);
        return try std.Io.Dir.cwd().createDirPathOpen(io, base, .{});
    }

    if (dir_config.fallback_env) |fallback| {
        const home = environ.getPosix(fallback) orelse return error.HomeDirMissing;
        const base = try std.fs.path.join(allocator, &.{ home, dir_config.fallback_subpath });
        defer allocator.free(base);
        return try std.Io.Dir.cwd().createDirPathOpen(io, base, .{});
    }

    return error.HomeDirMissing;
}
```

- [ ] **Step 2: Update `src/core/task.zig` import**

In `src/core/task.zig`, change:

```zig
const storage = @import("../storage/json.zig");
```

to:

```zig
const storage = @import("../storage/dir.zig");
```

Note: `dispatch_task_command` uses `storage.open_data_dir(...)`, which now resolves to `dir.zig`. The individual command functions (`add_task`, `list_task`, etc.) won't compile until Task 4 creates the vault — this is fine since Task 5 rewrites the dispatch. After Task 2, `zig build` will fail on missing `load_tasks`/`save_tasks` imports. That's expected.

- [ ] **Step 3: Run tests to verify storage tests pass**

Run: `zig build test --summary all`
Expected: some tests may fail because `task.zig` still references `storage.load_tasks`/`save_tasks` from the old json module. This is expected — the test suite is in a broken state until Task 5.

Despite the build failure, verify that `src/storage/dir.zig` compiled without errors by checking the compiler output (errors should only mention missing `load_tasks`/`save_tasks`).

- [ ] **Step 4: Commit**

```bash
git add src/storage/dir.zig src/core/task.zig
git commit -m "feat: add storage/dir.zig with comptime platform config"
```

---

### Task 3: Create `002_create_tasks.sql` migration

**Files:**
- Create: `src/internal/database/migrations/002_create_tasks.sql`

**Interfaces:**
- Consumes: `001_create_tasks.sql` (sub-project 02) must exist with `_schema_version` table.
- Produces: tasks table and version 2 in `_schema_version`.

- [ ] **Step 1: Create the migration file**

Create `src/internal/database/migrations/002_create_tasks.sql`:

```sql
CREATE TABLE IF NOT EXISTS tasks (
    id           TEXT PRIMARY KEY NOT NULL,
    title        TEXT NOT NULL,
    description  TEXT,
    status       TEXT NOT NULL DEFAULT 'pending',
    priority     TEXT,
    due_date     INTEGER,
    assigned_to  TEXT,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER,
    completed_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);

INSERT OR IGNORE INTO _schema_version (version) VALUES (2);
```

- [ ] **Step 2: Commit**

```bash
git add src/internal/database/migrations/002_create_tasks.sql
git commit -m "feat: add tasks table migration"
```

---

### Task 4: Create Vault handle (`src/core/vault.zig`)

**Files:**
- Create: `src/core/vault.zig`
- Test: `src/core/vault.zig` (tests live in same file)

**Interfaces:**
- Consumes:
  - `zqlite.open(path, flags)` / `db.exec(sql, params)` / `db.row(sql, params)` / `db.rows(sql, params)` from zqlite
  - `src/storage/dir.zig::open_data_dir`
  - `src/utils/generate.zig::generate_id`
  - `src/core/models.zig::Task`
  - `src/core/errors.zig::TaskNotFound`, `AmbiguousPrefix`, `StorageFailure`
  - `src/internal/database/migrate.zig::run_migrations`
- Produces:
  - `pub const Vault` — open/close
  - `pub const Vault.Tasks` — add/list/get_by_id/edit/delete/complete/start
  - `pub const AddFields` / `pub const EditFields` — input structs

- [ ] **Step 1: Create `src/core/vault.zig` with full implementation and tests**

```zig
const std = @import("std");
const zqlite = @import("zqlite");
const models = @import("models.zig");
const generate = @import("../utils/generate.zig");
const dir = @import("../storage/dir.zig");
const migrate = @import("../internal/database/migrate.zig");

pub const AddFields = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    due_date: ?i64 = null,
    assigned_to: ?[]const u8 = null,
};

pub const EditFields = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    due_date: ?i64 = null,
    assigned_to: ?[]const u8 = null,
};

pub const Vault = struct {
    db: *zqlite.Conn,
    io: std.Io,
    tasks: Tasks,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !Vault {
        var data_dir = try dir.open_data_dir(allocator, io, environ);
        defer data_dir.close(io);

        const db_path = try std.fs.path.join(allocator, &.{ data_dir.path, "tip.db" });
        defer allocator.free(db_path);

        const c_path = try allocator.dupeZ(u8, db_path);
        defer allocator.free(c_path);

        errdefer allocator.free(c_path);

        var db = try allocator.create(zqlite.Conn);
        errdefer allocator.destroy(db);

        db.* = try zqlite.open(c_path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
        errdefer db.deinit();

        try db.exec("PRAGMA journal_mode = WAL", .{});
        try migrate.run_migrations(db);

        return Vault{
            .db = db,
            .io = io,
            .tasks = .{ .vault = undefined },
        };
    }

    pub fn close(self: *Vault) void {
        self.db.deinit();
    }

    pub const Tasks = struct {
        vault: *Vault,

        fn now_seconds(io: std.Io) i64 {
            return std.Io.Timestamp.now(io, .real).toSeconds();
        }

        fn scanTask(row: zqlite.Row) models.Task {
            return .{
                .id = row.text(0),
                .title = row.text(1),
                .description = row.nullableText(2),
                .status = row.text(3),
                .priority = row.nullableText(4),
                .due_date = row.get(?i64, 5),
                .assigned_to = row.nullableText(6),
                .created_at = row.int(7),
                .updated_at = row.get(?i64, 8),
                .completed_at = row.get(?i64, 9),
            };
        }

        pub fn add(self: *Tasks, args: AddFields) !models.Task {
            const id = try generate.generate_id(std.testing.allocator, self.vault.io);
            defer std.testing.allocator.free(id);

            const now = now_seconds(self.vault.io);

            try self.vault.db.exec(
                "INSERT INTO tasks (id, title, description, status, priority, due_date, assigned_to, created_at) VALUES (?, ?, ?, 'pending', ?, ?, ?, ?)",
                .{ id, args.title, args.description, args.priority, args.due_date, args.assigned_to, now },
            );

            // Read back to return a fully populated struct
            const row = (try self.vault.db.row("SELECT * FROM tasks WHERE id = ?", .{id})) orelse return error.StorageFailure;
            return scanTask(row);
        }

        pub fn list(self: *Tasks, allocator: std.mem.Allocator) ![]models.Task {
            var result = try self.vault.db.rows("SELECT * FROM tasks ORDER BY created_at ASC", .{});
            defer result.deinit();

            var list = std.ArrayList(models.Task).empty;
            errdefer list.deinit(allocator);

            while (try result.next()) |row| {
                try list.append(allocator, scanTask(row));
            }
            return try list.toOwnedSlice(allocator);
        }

        pub fn get_by_id(self: *Tasks, allocator: std.mem.Allocator, id: []const u8) !models.Task {
            // Exact match first
            if (try self.vault.db.row("SELECT * FROM tasks WHERE id = ?", .{id})) |row| {
                return scanTask(row);
            }

            // Prefix match: WHERE id LIKE 'prefix%'
            const pattern = try std.mem.concat(allocator, u8, &.{ id, "%" });
            defer allocator.free(pattern);

            var result = try self.vault.db.rows("SELECT * FROM tasks WHERE id LIKE ? ORDER BY id", .{pattern});
            defer result.deinit();

            var count: usize = 0;
            var first: ?models.Task = null;
            while (try result.next()) |row| {
                if (count == 0) first = scanTask(row);
                count += 1;
            }

            if (count == 0) return error.TaskNotFound;
            if (count > 1) return error.AmbiguousPrefix;
            return first.?;
        }

        pub fn edit(self: *Tasks, id: []const u8, fields: EditFields) !void {
            // Check task exists
            if ((try self.vault.db.row("SELECT id FROM tasks WHERE id = ?", .{id})) == null)
                return error.TaskNotFound;

            const now = now_seconds(self.vault.io);

            if (fields.title) |v| {
                try self.vault.db.exec("UPDATE tasks SET title = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
            }
            if (fields.description) |v| {
                try self.vault.db.exec("UPDATE tasks SET description = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
            }
            if (fields.priority) |v| {
                try self.vault.db.exec("UPDATE tasks SET priority = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
            }
            if (fields.due_date) |v| {
                try self.vault.db.exec("UPDATE tasks SET due_date = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
            }
            if (fields.assigned_to) |v| {
                try self.vault.db.exec("UPDATE tasks SET assigned_to = ?, updated_at = ? WHERE id = ?", .{ v, now, id });
            }
        }

        pub fn delete(self: *Tasks, id: []const u8) !void {
            const changes = try self.vault.db.exec(
                "DELETE FROM tasks WHERE id = ?",
                .{id},
            );
            if (changes == 0) return error.TaskNotFound;
        }

        pub fn complete(self: *Tasks, id: []const u8) !void {
            const now = now_seconds(self.vault.io);
            const changes = try self.vault.db.exec(
                "UPDATE tasks SET status = 'completed', updated_at = ?, completed_at = ? WHERE id = ?",
                .{ now, now, id },
            );
            if (changes == 0) return error.TaskNotFound;
        }

        pub fn start(self: *Tasks, id: []const u8) !void {
            const now = now_seconds(self.vault.io);
            const changes = try self.vault.db.exec(
                "UPDATE tasks SET status = 'in_progress', updated_at = ? WHERE id = ?",
                .{ now, id },
            );
            if (changes == 0) return error.TaskNotFound;
        }
    };
};
```

- [ ] **Step 2: Run tests to verify the file compiles and all tests pass**

Run: `zig build test --summary all`
Expected: PASS — no new test failures. The vault module has no tests yet (they're added in the next step).

- [ ] **Step 3: Add vault tests**

Append these tests at the bottom of `src/core/vault.zig`:

```zig
test "add and get_by_id" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    // Use env with HOME set for platform dir resolution
    // For in-memory testing, we bypass open and create the vault manually
    var db = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer db.deinit();

    try db.exec("CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, description TEXT, status TEXT NOT NULL DEFAULT 'pending', priority TEXT, due_date INTEGER, assigned_to TEXT, created_at INTEGER NOT NULL, updated_at INTEGER, completed_at INTEGER)", .{});
    try db.exec("CREATE INDEX idx_tasks_status ON tasks(status)", .{});

    var vault = Vault{ .db = &db, .io = io, .tasks = .{ .vault = undefined } };
    vault.tasks = .{ .vault = &vault };

    const task = try vault.tasks.add(.{ .title = "Test Task", .description = "A description" });
    defer allocator.free(task.id);

    try std.testing.expectEqualStrings("Test Task", task.title);
    try std.testing.expectEqualStrings("A description", task.description.?);
    try std.testing.expectEqualStrings("pending", task.status);
    try std.testing.expect(task.id.len > 0);

    // Retrieve by id
    const retrieved = try vault.tasks.get_by_id(allocator, task.id);
    try std.testing.expectEqualStrings(task.id, retrieved.id);
    try std.testing.expectEqualStrings(task.title, retrieved.title);
}

test "add and list returns all tasks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var db = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer db.deinit();

    try db.exec("CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, description TEXT, status TEXT NOT NULL DEFAULT 'pending', priority TEXT, due_date INTEGER, assigned_to TEXT, created_at INTEGER NOT NULL, updated_at INTEGER, completed_at INTEGER)", .{});
    try db.exec("CREATE INDEX idx_tasks_status ON tasks(status)", .{});

    var vault = Vault{ .db = &db, .io = io, .tasks = .{ .vault = undefined } };
    vault.tasks = .{ .vault = &vault };

    _ = try vault.tasks.add(.{ .title = "First" });
    _ = try vault.tasks.add(.{ .title = "Second" });
    _ = try vault.tasks.add(.{ .title = "Third" });

    const tasks = try vault.tasks.list(allocator);
    defer allocator.free(tasks);

    try std.testing.expectEqual(@as(usize, 3), tasks.len);
    try std.testing.expectEqualStrings("First", tasks[0].title);
    try std.testing.expectEqualStrings("Second", tasks[1].title);
    try std.testing.expectEqualStrings("Third", tasks[2].title);
}

test "list empty returns empty slice" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var db = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer db.deinit();

    try db.exec("CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, description TEXT, status TEXT NOT NULL DEFAULT 'pending', priority TEXT, due_date INTEGER, assigned_to TEXT, created_at INTEGER NOT NULL, updated_at INTEGER, completed_at INTEGER)", .{});

    var vault = Vault{ .db = &db, .io = io, .tasks = .{ .vault = undefined } };
    vault.tasks = .{ .vault = &vault };

    const tasks = try vault.tasks.list(allocator);
    try std.testing.expectEqual(@as(usize, 0), tasks.len);
}

test "edit updates fields" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var db = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer db.deinit();

    try db.exec("CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, description TEXT, status TEXT NOT NULL DEFAULT 'pending', priority TEXT, due_date INTEGER, assigned_to TEXT, created_at INTEGER NOT NULL, updated_at INTEGER, completed_at INTEGER)", .{});
    try db.exec("CREATE INDEX idx_tasks_status ON tasks(status)", .{});

    var vault = Vault{ .db = &db, .io = io, .tasks = .{ .vault = undefined } };
    vault.tasks = .{ .vault = &vault };

    const task = try vault.tasks.add(.{ .title = "Original", .description = "Original desc" });
    defer allocator.free(task.id);

    try vault.tasks.edit(task.id, .{ .title = "Updated", .description = "Updated desc" });

    const retrieved = try vault.tasks.get_by_id(allocator, task.id);
    try std.testing.expectEqualStrings("Updated", retrieved.title);
    try std.testing.expectEqualStrings("Updated desc", retrieved.description.?);
}

test "delete removes task" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var db = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer db.deinit();

    try db.exec("CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, description TEXT, status TEXT NOT NULL DEFAULT 'pending', priority TEXT, due_date INTEGER, assigned_to TEXT, created_at INTEGER NOT NULL, updated_at INTEGER, completed_at INTEGER)", .{});
    try db.exec("CREATE INDEX idx_tasks_status ON tasks(status)", .{});

    var vault = Vault{ .db = &db, .io = io, .tasks = .{ .vault = undefined } };
    vault.tasks = .{ .vault = &vault };

    const task = try vault.tasks.add(.{ .title = "Delete me" });
    try vault.tasks.delete(task.id);

    const tasks = try vault.tasks.list(allocator);
    try std.testing.expectEqual(@as(usize, 0), tasks.len);
}

test "delete nonexistent returns TaskNotFound" {
    const io = std.testing.io;

    var db = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer db.deinit();

    try db.exec("CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, description TEXT, status TEXT NOT NULL DEFAULT 'pending', priority TEXT, due_date INTEGER, assigned_to TEXT, created_at INTEGER NOT NULL, updated_at INTEGER, completed_at INTEGER)", .{});

    var vault = Vault{ .db = &db, .io = io, .tasks = .{ .vault = undefined } };
    vault.tasks = .{ .vault = &vault };

    try std.testing.expectError(error.TaskNotFound, vault.tasks.delete("nonexistent"));
}

test "get_by_id prefix match" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var db = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer db.deinit();

    try db.exec("CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, description TEXT, status TEXT NOT NULL DEFAULT 'pending', priority TEXT, due_date INTEGER, assigned_to TEXT, created_at INTEGER NOT NULL, updated_at INTEGER, completed_at INTEGER)", .{});
    try db.exec("CREATE INDEX idx_tasks_status ON tasks(status)", .{});

    var vault = Vault{ .db = &db, .io = io, .tasks = .{ .vault = undefined } };
    vault.tasks = .{ .vault = &vault };

    const task = try vault.tasks.add(.{ .title = "Prefix test" });
    defer allocator.free(task.id);

    // Use first 4 chars as prefix
    const prefix = task.id[0..@min(@as(usize, 4), task.id.len)];
    const retrieved = try vault.tasks.get_by_id(allocator, prefix);
    try std.testing.expectEqualStrings(task.id, retrieved.id);
}

test "get_by_id not found returns TaskNotFound" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var db = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer db.deinit();

    try db.exec("CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, description TEXT, status TEXT NOT NULL DEFAULT 'pending', priority TEXT, due_date INTEGER, assigned_to TEXT, created_at INTEGER NOT NULL, updated_at INTEGER, completed_at INTEGER)", .{});

    var vault = Vault{ .db = &db, .io = io, .tasks = .{ .vault = undefined } };
    vault.tasks = .{ .vault = &vault };

    try std.testing.expectError(error.TaskNotFound, vault.tasks.get_by_id(allocator, "0000"));
}

test "complete and start set status" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var db = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer db.deinit();

    try db.exec("CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, description TEXT, status TEXT NOT NULL DEFAULT 'pending', priority TEXT, due_date INTEGER, assigned_to TEXT, created_at INTEGER NOT NULL, updated_at INTEGER, completed_at INTEGER)", .{});
    try db.exec("CREATE INDEX idx_tasks_status ON tasks(status)", .{});

    var vault = Vault{ .db = &db, .io = io, .tasks = .{ .vault = undefined } };
    vault.tasks = .{ .vault = &vault };

    const task = try vault.tasks.add(.{ .title = "Status test" });
    defer allocator.free(task.id);

    try vault.tasks.start(task.id);
    const started = try vault.tasks.get_by_id(allocator, task.id);
    try std.testing.expectEqualStrings("in_progress", started.status);

    try vault.tasks.complete(task.id);
    const completed = try vault.tasks.get_by_id(allocator, task.id);
    try std.testing.expectEqualStrings("completed", completed.status);
    try std.testing.expect(completed.completed_at != null);
}
```

Note: these tests create the tasks table manually (using `db.exec` with DDL) since they use in-memory sqlite rather than the full `Vault.open` path. This avoids needing to set up platform directory resolution in tests.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS — all vault tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/core/vault.zig
git commit -m "feat: add Vault handle with Tasks CRUD methods"
```

---

### Task 5: Rewrite CLI dispatch in `src/core/task.zig`

**Files:**
- Modify: `src/core/task.zig` (replace command functions with vault-based dispatch)
- Note: `print_task` and `now_seconds` stay

**Interfaces:**
- Consumes: `Vault.open()`, `Vault.close()`, `Vault.Tasks.*` methods (Task 4).
- Produces: `pub fn dispatch_task_command(io: std.Io, environ: std.process.Environ, args: TaskArgs) !void`

- [ ] **Step 1: Replace `dispatch_task_command` and remove old CRUD functions**

In `src/core/task.zig`, replace the entire file contents:

```zig
const std = @import("std");
const models = @import("models.zig");
const ansi = @import("../utils/ansi.zig");
const Vault = @import("vault.zig").Vault;

fn now_seconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

pub const TaskArgs = struct {
    list: bool = false,
    subcommand: ?union(enum) {
        add: struct { title: []const u8, desc: ?[]const u8 = null },
        edit: struct { id: []const u8, title: []const u8, desc: ?[]const u8 = null },
        delete: struct { id: []const u8 },
        show: struct { id: []const u8 },
    } = null,

    pub const help =
        \\Usage:
        \\  tip task <subcommand> [args] [flags]
        \\
        \\Options:
        \\  --list                    List all tasks
        \\
        \\Commands:
        \\  add
        \\      --title=<title>       Add a new task
        \\      --desc=<description>  Task description
        \\  edit
        \\      --id=<id>             Task ID to edit
        \\      --title=<title>       New title
        \\      --desc=<description>  New description
        \\  delete
        \\      --id=<id>             Task ID to delete
        \\  show
        \\      --id=<id>             Show task details
        \\
        \\Examples:
        \\  tip task --list
        \\  tip task add --title="Review code"
        \\
    ;
};

pub fn dispatch_task_command(io: std.Io, environ: std.process.Environ, args: TaskArgs) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var vault = try Vault.open(allocator, io, environ);
    defer vault.close();

    if (args.list) {
        const tasks = try vault.tasks.list(allocator);
        if (tasks.len == 0) {
            std.debug.print("No tasks\n", .{});
            return;
        }

        var pending: std.ArrayList(models.Task) = .empty;
        var in_progress: std.ArrayList(models.Task) = .empty;
        var completed: std.ArrayList(models.Task) = .empty;
        defer {
            pending.deinit(allocator);
            in_progress.deinit(allocator);
            completed.deinit(allocator);
        }

        for (tasks) |task| {
            switch (task.status) {
                "pending" => try pending.append(allocator, task),
                "in_progress" => try in_progress.append(allocator, task),
                "completed" => try completed.append(allocator, task),
                else => {},
            }
        }

        if (pending.items.len > 0) {
            std.debug.print("{s}Pending{s} ({d})\n", .{ ansi.ansi_code(.cyan), ansi.ansi_code(.reset), pending.items.len });
            for (pending.items) |task| try print_task(io, task, false);
            std.debug.print("\n", .{});
        }

        if (in_progress.items.len > 0) {
            std.debug.print("{s}In Progress{s} ({d})\n", .{ ansi.ansi_code(.cyan), ansi.ansi_code(.reset), in_progress.items.len });
            for (in_progress.items) |task| try print_task(io, task, false);
            std.debug.print("\n", .{});
        }

        if (completed.items.len > 0) {
            std.debug.print("{s}Completed{s} ({d})\n", .{ ansi.ansi_code(.green), ansi.ansi_code(.reset), completed.items.len });
            for (completed.items) |task| try print_task(io, task, false);
        }
        return;
    }

    if (args.subcommand) |cmd| switch (cmd) {
        .add => |a| {
            const task = try vault.tasks.add(.{
                .title = a.title,
                .description = a.desc,
            });
            std.debug.print("Created task: {s}\n", .{task.title});
        },
        .edit => |e| try vault.tasks.edit(e.id, .{
            .title = e.title,
            .description = e.desc,
        }),
        .delete => |del| try vault.tasks.delete(del.id),
        .show => |s| {
            const task = try vault.tasks.get_by_id(allocator, s.id);
            try print_task(io, task, true);
        },
    };
}

fn print_task(io: std.Io, task: models.Task, detailed: bool) !void {
    const c_status = ansi.status_color(task.status);
    const c_reset = ansi.ansi_code(.reset);
    const compact_id = if (task.id.len > 8) task.id[0..8] else task.id;

    if (detailed) {
        std.debug.print("{s}=== Task Details ==={s}\n\n", .{ ansi.ansi_code(.cyan), c_reset });
        std.debug.print("ID:          {s}\n", .{task.id});
        std.debug.print("Title:       {s}\n", .{task.title});

        if (task.description) |desc| {
            std.debug.print("Description: {s}\n", .{desc});
        } else {
            std.debug.print("Description: -\n", .{});
        }

        std.debug.print("Status:      {s}{s}{s}\n", .{ ansi.ansi_code(c_status), ansi.status_icon(task.status), c_reset });

        if (task.priority) |p| {
            std.debug.print("Priority:    {s}{s}{s}\n", .{ ansi.ansi_code(ansi.priority_color(task.priority)), ansi.priority_glyph(p), c_reset });
        } else {
            std.debug.print("Priority:    -\n", .{});
        }

        if (task.due_date) |due| {
            const now = now_seconds(io);
            if (due < now) {
                std.debug.print("Due Date:    {d} (overdue)\n", .{due});
            } else {
                std.debug.print("Due Date:    {d}\n", .{due});
            }
        } else {
            std.debug.print("Due Date:    -\n", .{});
        }

        if (task.assigned_to) |assigned| {
            std.debug.print("Assigned To: {s}\n", .{assigned});
        } else {
            std.debug.print("Assigned To: -\n", .{});
        }

        std.debug.print("\n", .{});
        std.debug.print("Created:     {d}\n", .{task.created_at});

        if (task.updated_at) |updated| {
            std.debug.print("Updated:     {d}\n", .{updated});
        } else {
            std.debug.print("Updated:     -\n", .{});
        }

        if (task.completed_at) |completed| {
            std.debug.print("Completed:   {d}\n", .{completed});
        } else {
            std.debug.print("Completed:   -\n", .{});
        }
    } else {
        std.debug.print("  {s}{s}{s} ", .{ ansi.ansi_code(c_status), ansi.status_icon(task.status), c_reset });
        if (task.priority) |p| {
            std.debug.print("{s} ", .{ansi.priority_glyph(p)});
        }
        std.debug.print("{s}\n", .{task.title});

        if (task.description) |desc| {
            std.debug.print("      {s}desc:{s} {s}\n", .{ ansi.ansi_code(.yellow), c_reset, desc });
        }

        if (task.due_date) |due| {
            const now = now_seconds(io);
            if (due < now) {
                std.debug.print("      {s}Due: {d} (overdue){s}\n", .{ ansi.ansi_code(.red), due, c_reset });
            } else {
                std.debug.print("      {s}Due: {d}{s}\n", .{ ansi.ansi_code(.yellow), due, c_reset });
            }
        }

        if (task.status) |s| {
            if (std.mem.eql(u8, s, "completed")) {
                if (task.completed_at) |completed| {
                    std.debug.print("      {s}Completed: {d}{s}\n", .{ ansi.ansi_code(.green), completed, c_reset });
                }
            }
        }

        std.debug.print("      {s}ID: {s}{s}\n", .{ ansi.ansi_code(.yellow), compact_id, c_reset });
    }
}
```

Note: The existing tests in `task.zig` tested the old CRUD functions (`add_task`, `edit_task`, `delete_task`, `list_task`, `mark_complete`). These tests are replaced by the vault tests in Task 4. The old tests are removed since the functions they tested no longer exist.

- [ ] **Step 2: Run tests to verify the build**

Run: `zig build test --summary all`
Expected: PASS — vault tests pass, no more references to old JSON-based functions.

- [ ] **Step 3: Verify the binary builds**

Run: `zig build`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add src/core/task.zig
git commit -m "refactor: wire CLI dispatch to Vault handle, remove old JSON CRUD"
```

---

### Task 6: Delete JSON storage module

**Files:**
- Delete: `src/storage/json.zig`

- [ ] **Step 1: Verify no remaining references to `json.zig`**

Run: `rg "storage/json" src/`
Expected: no matches — `task.zig` no longer imports it, `vault.zig` uses `storage/dir.zig`.

- [ ] **Step 2: Delete the file**

```bash
rm src/storage/json.zig
```

- [ ] **Step 3: Run tests to verify everything still passes**

Run: `zig build test --summary all`
Expected: PASS — all tests pass without json.zig.

- [ ] **Step 4: Commit**

```bash
git rm src/storage/json.zig
git commit -m "refactor: remove JSON storage module"
```

---

### Task 7: Final verification

- [ ] **Step 1: Run full test suite**

Run: `zig build test --summary all`
Expected: PASS — all tests pass.

- [ ] **Step 2: Build the binary**

Run: `zig build`
Expected: builds with no errors.

- [ ] **Step 3: Quick smoke test**

Run: `zig build run -- task add --title="Smoke test"`
Run: `zig build run -- task --list`
Expected: both work without errors, the list shows the added task.

---

## Self-Review

**Spec coverage (against [2026-07-03-03 design](../specs/2026-07-03-03-storage-handle-tasks-table-design.md)):**
- S1 Vault handle → Task 4 (`Vault` + `Tasks` structs)
- S2 Vault captures io → Task 4 (`self.vault.io` in methods)
- S3 Task struct in models.zig → unchanged (imported by both vault and CLI)
- S4 Ansi extraction → Task 1 (`src/utils/ansi.zig`)
- S5 Platform dir in storage → Task 2 (`src/storage/dir.zig`)
- S6 Handle methods return data → Task 4 (add/list/get_by_id return data, no printing)
- S7 Prefix match via LIKE → Task 4 (`get_by_id` uses `LIKE ? || '%'`)
- S8 complete/start methods → Task 4 (`Tasks.complete`/`Tasks.start`)
- S9 JSON deleted → Task 6
- S10 TEXT status/priority → Task 3 (migration) + Task 4 (handle methods)

**Placeholder scan:** No TBDs/TODOs. Every step has complete code or exact commands. No "add appropriate error handling" patterns.

**Type consistency:** `Vault.open(allocator, io, environ) !Vault` in Task 4 matches the dispatch call in Task 5. `Tasks.get_by_id(allocator, id) !Task` consistent. `Tasks.edit(id, fields)` consistent with `EditFields` struct. Task enum statuses stored as TEXT strings in SQLite, compared as `[]const u8`.

**Dependency order:** Task 1 → 2 → 3 → 4 → 5 → 6. Each task produces a working intermediate state (build may temporarily break between 2 and 4, noted in Task 2).

