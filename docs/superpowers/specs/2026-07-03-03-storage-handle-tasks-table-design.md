# Sub-project 03 — Storage Handle API + Tasks Table (DESIGN)

> **Status:** DESIGN APPROVED
> **Date:** 2026-07-03
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 02 (SQLite foundation) — design and plan done
> **Successor:** 04 (complete/start, unified prefix-match + ambiguity)

This sub-project creates the `Vault` handle that replaces the threaded `(allocator, io, dir, ...)` parameter pattern with a single struct that owns shared context. It adds the `tasks` SQLite table, migrates all task CRUD from JSON to SQLite, and removes the JSON storage module.

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| S1 | **`Vault` handle** wraps `*zqlite.Conn` and exposes `vault.tasks` child handle. | LOCKED |
| S2 | **`Vault.capture(io)`** at open time — methods don't thread `io`. | LOCKED |
| S3 | **`Task` struct stays in `models.zig`** — shared between vault and CLI. | LOCKED |
| S4 | **Ansi helpers extracted** to `src/utils/ansi.zig`. | LOCKED |
| S5 | **Platform dir resolution stays in storage** — `src/storage/dir.zig`. | LOCKED |
| S6 | **Handle methods return data** — no printing in vault. CLI owns rendering. | LOCKED |
| S7 | **Prefix match** via `LIKE ? || '%'` (basic; sub-project 04 owns rich ambiguity UX). | LOCKED |
| S8 | **`complete`/`start` methods** on the handle (storage ops); CLI subcommands wire in 04. | LOCKED |
| S9 | **JSON storage deleted** — demoted to future export/import sub-project. | LOCKED |
| S10 | **Status/priority stored as TEXT** — self-documenting, no magic integers. | LOCKED |

---

## File layout (after changes)

```
src/
  core/
    models.zig       - Task struct (unchanged body)
    vault.zig        - Vault + Tasks handles (NEW)
    task.zig         - TaskArgs, dispatch_task_command, print_task (slimmed)
    errors.zig       - error taxonomy (sub-project 01)
  utils/
    ansi.zig         - Ansi enum, ansi_code, priority_glyph, etc. (NEW, extracted)
    generate.zig     - ULID generator
  storage/
    dir.zig          - open_data_dir (MOVED from json.zig, no CRUD)
    json.zig         - (DELETED)
  internal/
    database/
      db.zig         - raw connection (sub-project 02)
      migrate.zig    - migration runner (sub-project 02)
      migrations/
        001_create_tasks.sql   - _schema_version (sub-project 02)
        002_create_tasks.sql   - tasks table (NEW)
  main.zig
```

---

## Part A — Storage dir

Move `open_data_dir` from `src/storage/json.zig` into `src/storage/dir.zig` with no behavioral changes. Same platform path resolution:
- Linux: `$XDG_DATA_HOME/tip` or `~/.local/share/tip`
- macOS: `~/Library/Application Support/tip`
- Windows: `%APPDATA%/tip`

Signature:

```zig
pub fn open_data_dir(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !std.Io.Dir
```

### Implementation: comptime platform config

Since `builtin.os.tag` is comptime-known, the OS switch is distilled into a config struct, then runtime follows a single fallthrough path — no env-map allocation, no runtime OS branches:

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

### Alternatives considered

| Approach | What | Trade-off |
|----------|------|-----------|
| **A (chosen)** | Comptime config + `getPosix` | No allocation for env map, one comptime switch, uniform runtime path. Slightly more lines but clearer. |
| **B** | Accept base path from caller | Pushes XDG/HOME/APPDATA logic up to every call site. Doesn't simplify the system, just moves it. |
| **C** | Single env var override (`TIP_DATA_DIR`) with fallback | Flexible but adds a new env var contract. Could revisit in sub-project 05 (config system). |
| **D** | Relative path `./.tip/` | Trivially simple but breaks standard expectations. Not portable across OS conventions. |

---

## Part B — Tasks table schema (`002_create_tasks.sql`)

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

### Column rationale
- `id TEXT PK` — ULID stored as text (lexicographic sort = chronological, `LIKE`-friendly for prefix matching).
- `status TEXT` — `'pending'`, `'in_progress'`, `'completed'`. Readable in sqlite3 shell.
- `priority TEXT` — `'low'`, `'medium'`, `'high'`, or NULL.
- `due_date` / `created_at` / `updated_at` / `completed_at` — INTEGER (Unix seconds, `i64`).
- No foreign keys yet (vaults arrive in sub-project 06).

---

## Part C — Vault handle (`src/core/vault.zig`)

```zig
pub const Vault = struct {
    db: *zqlite.Conn,
    io: std.Io,
    tasks: Tasks,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !Vault
    pub fn close(self: *Vault) void

    pub const Tasks = struct {
        vault: *Vault,

        pub fn add(self: *Tasks, args: AddFields) !models.Task
        pub fn list(self: *Tasks, allocator: std.mem.Allocator) ![]models.Task
        pub fn get_by_id(self: *Tasks, allocator: std.mem.Allocator, id: []const u8) !models.Task
        pub fn edit(self: *Tasks, id: []const u8, fields: EditFields) !void
        pub fn delete(self: *Tasks, id: []const u8) !void
        pub fn complete(self: *Tasks, id: []const u8) !void
        pub fn start(self: *Tasks, id: []const u8) !void
    };
};
```

### Implementation notes

- **`open`**: calls `storage.dirs.open_data_dir` to get the platform directory, builds `tip.db` path, calls `db.open(...)` from sub-project 02, runs `migrate.run_migrations`, returns a `Vault` with `.tasks.vault` pointing at `self`.
- **`close`**: calls `db.deinit()`.
- **`Tasks.add`**: generates ULID via `generate.generate_id(allocator, vault.io)`, inserts row, returns the inserted task. `created_at` from `now_seconds(vault.io)`.
- **`Tasks.get_by_id`**: exact match `WHERE id = ?` first. If no match, prefix match `WHERE id LIKE ? || '%' ORDER BY id`. 0 rows → `TaskNotFound`, >1 → `AmbiguousPrefix`, 1 → return it.
- **`Tasks.edit`**: partial update — only non-null `EditFields` become `SET` clauses. Exact `WHERE id = ?`. Returns `TaskNotFound` if no match.
- **`Tasks.delete`**: `DELETE WHERE id = ?`. Returns `TaskNotFound` if no match.
- **`Tasks.complete` / `Tasks.start`**: `UPDATE status = 'completed'|'in_progress'`, set `updated_at`, set `completed_at` (for complete only). Exact `WHERE id = ?`.

---

## Part D — CLI layer changes (`src/core/task.zig`)

`dispatch_task_command` opens a `Vault`, delegates to handle methods, and formats output:

```zig
pub fn dispatch_task_command(io: std.Io, environ: std.process.Environ, args: TaskArgs) !void {
    var vault = try Vault.open(arena.allocator(), io, environ);
    defer vault.close();

    if (args.list) {
        const tasks = try vault.tasks.list(arena.allocator());
        // render grouped listing (calls print_task)
        return;
    }

    if (args.subcommand) |cmd| switch (cmd) {
        .add => |a| {
            const task = try vault.tasks.add(.{
                .title = a.title, .description = a.desc,
            });
            std.debug.print("Created task: {s}\n", .{task.title});
        },
        .edit => |e| try vault.tasks.edit(e.id, .{
            .title = e.title, .description = e.desc,
        }),
        .delete => |del| try vault.tasks.delete(del.id),
        .show => |s| {
            const task = try vault.tasks.get_by_id(arena.allocator(), s.id);
            print_task(io, task, true);
        },
    };
}
```

`print_task` stays in `task.zig` — it's rendering logic, not storage logic. `Ansi` enum and helper functions (`ansi_code`, `priority_glyph`, `status_icon`, etc.) move to `src/utils/ansi.zig`.

---

## Part E — Remove JSON storage

- Delete `src/storage/json.zig`.
- Remove `const storage = @import("../storage/json.zig")` from `task.zig`.
- The JSON export/import feature will be added back in a later sub-project using proper atomic write patterns.

---

## Part F — Testing

All tests use `zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode)`:

| Test | What it verifies |
|------|------------------|
| `add + get_by_id` | add a task, retrieve by full id, assert all fields match |
| `add + list` | add 3 tasks, list returns all in creation order |
| `list empty` | no tasks → empty slice, not error |
| `edit` | add then edit title and description, verify update |
| `delete` | add then delete, verify gone |
| `delete not found` | expect `TaskNotFound` |
| `get_by_id prefix` | add task, retrieve by 4-char prefix |
| `get_by_id not found` | expect `TaskNotFound` |
| `get_by_id ambiguous` | add two tasks with same prefix, expect `AmbiguousPrefix` |
| `complete` | verify status + timestamps |
| `start` | verify status + timestamp |

---

## Out of scope

- **`complete`/`start` CLI subcommands** — sub-project 04.
- **Unified prefix-matcher with rich ambiguity listing** — sub-project 04.
- **`--verbose` error detail** — sub-project 05.
- **Vaults (multi-vault support, vault FK)** — sub-project 06.
- **JSON export/import** — future sub-project.
- **Config system, global flags** — sub-project 05.
- **Naming refinements** — can be done inline during plan execution.

---

## Next step

Write the checkbox implementation plan for this sub-project via the writing-plans skill. **No implementation yet.**
