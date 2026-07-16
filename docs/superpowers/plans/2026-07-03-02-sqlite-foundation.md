# Sub-project 02 — SQLite Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire SQLite into the build, add a `db.zig` connection module, and establish the migration runner with embedded `.sql` files.

**Architecture:** zqlite dependency fetched and wired in `build.zig` for both the exe and test modules. A new `db.zig` opens/creates `tip.db` in the platform data directory with WAL mode. A `migrate.zig` runner applies numbered `.sql` migrations from `src/internal/database/migrations/`, each in its own transaction.

**Tech Stack:** Zig 0.16 (`std.Io` async model), `zqlite` dependency, `zqlite.open()` API.

## Global Constraints

- **Zig version:** 0.16.0 (`minimum_zig_version = "0.16.0"`). Use the new `std.Io` APIs.
- **Identifier casing:** functions/vars/fields = `snake_case`; types = `PascalCase`; enum members = `snake_case`.
- **zqlite API:** `zqlite.open(path, flags)` for connections, `conn.exec(sql, params)` for statements (2 args), `conn.row(sql, params)` returns `?Row` for single-row queries, `conn.rows(sql, params)` returns `Rows` for multi-row queries. Row column access: `row.int(0)`, `row.text(1)`, `row.nullableInt(2)`, etc.
- **Exit codes from sub-project 01:** `0` ok · `1` internal · `2` usage · `3` not found · `4` validation — not yet used here; these modules return errors, `main.zig` will render them.
- **Tests:** `zig build test --summary all` from repo root. New test files under `src/` are auto-discovered by the build system.
- **No global state.** Every function takes the allocator/io/db explicitly.
- **Out of scope:** Tasks table schema (03), Store handle API (03), JSON storage removal (03), prefix matching (04).

---

### Task 1: Add zqlite dependency and wire into build

**Files:**
- Modify: `build.zig.zon`
- Modify: `build.zig`

**Interfaces:**
- Consumes: none (pure build system)
- Produces: `@import("zqlite")` available in all test files and the exe

- [x] **Step 1: Add zqlite to the dependency manifest**

Run (from repo root):

```bash
zig fetch --save git+https://github.com/karlseguin/zqlite.zig
```

This adds a `.dependencies.zqlite` entry to `build.zig.zon`. There is no hash known ahead of time — `zig fetch` computes and saves it. The resulting entry will look similar to:

```zon
.zqlite = .{
    .url = "git+https://github.com/karlseguin/zqlite.zig#946d77c526258760b52836187af32d1a192c5d36",
    .hash = "...",
},
```

Verify the file parses: `zig build` (will fail on missing module — expected, that's next).

- [x] **Step 2: Wire zqlite module into exe build**

In `build.zig`, after the `flags` dependency block, add:

```zig
const zqlite = b.dependency("zqlite", .{
    .target = target,
    .optimize = optimize,
}).module("zqlite");
```

In the exe root module, add zqlite to the imports:

```zig
.imports = &.{
    .{ .name = "flags", .module = flags },
    .{ .name = "version", .module = version_module },
    .{ .name = "zqlite", .module = zqlite },
},
```

- [x] **Step 3: Wire zqlite module into test build**

The test module currently has no imports. Change it to include zqlite:

```zig
const all_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = test_entry,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zqlite", .module = zqlite },
        },
    }),
});
```

- [x] **Step 4: Verify build**

```bash
zig build
```

Expected: builds `tip` binary with no errors (zqlite is linked, no source references it yet).

```bash
zig build test --summary all
```

Expected: PASS — all existing tests still pass (no new tests yet).

- [x] **Step 5: Commit**

```bash
git add build.zig.zon build.zig
git commit -m "build: add zqlite dependency"
```

---

### Task 2: Database module (`db.zig`)

**Files:**
- Create: `src/internal/database/db.zig`
- Test: `src/internal/database/db.zig` (tests live in same file)

**Interfaces:**
- Consumes: `allocator`, `io`, `environ` for platform data directory resolution; `zqlite` import for `zqlite.open`.
- Produces: `pub fn open(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !zqlite.Conn`

- [x] **Step 1: Write the failing tests**

Create `src/internal/database/db.zig` with ONLY the tests:
 
```zig
const std = @import("std");
const zqlite = @import("zqlite");

test "open memory returns a working db" {
    var db = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer db.deinit();

    // Prove it works
    try db.exec("CREATE TABLE t (x INTEGER)", .{});
    try db.exec("INSERT INTO t VALUES (42)", .{});
    const row = (try db.row("SELECT x FROM t LIMIT 1", .{})) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 42), row.int(0));
}
```

- [x] **Step 2: Run tests to verify they fail**

```bash
zig build test --summary all
```

Expected: the test PASSES (it doesn't use `open` yet, just the zqlite API directly). Note: if it fails with a linker error, ensure `libsqlite3` is available or zqlite bundles its own C source.

- [ ] **Step 3: Write the `open` function and a dedicated test**

Replace the file contents with the implementation AND tests:

```zig
const std = @import("std");
const zqlite = @import("zqlite");
const builtin = @import("builtin");

/// Opens (or creates) the SQLite database at the platform data directory.
/// WAL mode is enabled for better concurrent-read performance.
pub fn open(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !zqlite.Conn {
    var env_map = try std.process.Environ.createMap(environ, allocator);
    defer env_map.deinit();

    const base = switch (builtin.os.tag) {
        .linux => blk: {
            if (env_map.get("XDG_DATA_HOME")) |xdg| {
                break :blk try std.fs.path.join(allocator, &.{ xdg, "tip" });
            }
            const home = env_map.get("HOME") orelse return error.HomeDirMissing;
            break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share", "tip" });
        },
        .macos => blk: {
            const home = env_map.get("HOME") orelse return error.HomeDirMissing;
            break :blk try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "tip" });
        },
        .windows => blk: {
            const appdata = env_map.get("APPDATA") orelse return error.AppDataDirUnavailable;
            break :blk try std.fs.path.join(allocator, &.{ appdata, "tip" });
        },
        else => @compileError("unsupported OS"),
    };
    defer allocator.free(base);

    // Ensure directory exists
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, base, .{});
    defer dir.close(io);

    const db_path = try std.fs.path.join(allocator, &.{ base, "tip.db" });
    defer allocator.free(db_path);

    // Convert to C string for sqlite
    const c_path = try allocator.dupeZ(u8, db_path);
    defer allocator.free(c_path);

    var db = try zqlite.open(c_path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);

    try db.exec("PRAGMA journal_mode = WAL", .{});
    return db;
}

test "open memory returns a working db" {
    var db = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer db.deinit();

    try db.exec("CREATE TABLE t (x INTEGER)", .{});
    try db.exec("INSERT INTO t VALUES (42)", .{});
    const row = (try db.row("SELECT x FROM t LIMIT 1", .{})) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 42), row.int(0));
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
zig build test --summary all
```

Expected: PASS — both db tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/internal/database/db.zig
git commit -m "feat: add sqlite database connection module"
```

---

### Task 3: Migration runner + first `.sql` migration

**Files:**
- Create: `src/internal/database/migrations/001_create_tasks.sql`
- Create: `src/internal/database/migrate.zig`
- Test: `src/internal/database/migrate.zig` (tests live in same file)

**Interfaces:**
- Consumes: `*zqlite.Conn` from Task 2, `@embedFile("migrations/001_create_tasks.sql")`.
- Produces: `pub fn run_migrations(db: *zqlite.Conn) !void`
- Data: `001_create_tasks.sql` contains the `_schema_version` table setup (placeholder for sub-project 03).

- [ ] **Step 1: Create the first migration file**

Create `src/internal/database/migrations/001_create_tasks.sql`:

```sql
CREATE TABLE IF NOT EXISTS _schema_version (version INTEGER NOT NULL);
INSERT INTO _schema_version (version) VALUES (1);
```

This is intentionally minimal — it proves the runner works. The Tasks table and real schema land in sub-project 03.

- [ ] **Step 2: Write the failing tests**

Create `src/internal/database/migrate.zig` with ONLY tests first:

```zig
const std = @import("std");
const zqlite = @import("zqlite");
const migrate = @import("migrate.zig");

test "migrations run from scratch" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.deinit();

    try migrate.run_migrations(&conn);

    const version_row = (try conn.row("SELECT version FROM _schema_version", .{})) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), version_row.int(0));
}

test "migrations are idempotent" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.deinit();

    try migrate.run_migrations(&conn);
    try migrate.run_migrations(&conn);

    const version_row = (try conn.row("SELECT version FROM _schema_version", .{})) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), version_row.int(0));
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
zig build test --summary all
```

Expected: compile error — `run_migrations` not defined yet.

- [ ] **Step 4: Write the migration runner**

Prepend the implementation above the tests in `src/internal/database/migrate.zig` (keep `const std` and `const zqlite` at top):

```zig
const std = @import("std");
const zqlite = @import("zqlite");

/// Ordered list of migration SQL embedded at compile time.
/// Each migration is a numbered `.sql` file in the migrations directory.
const migrations = struct {
    const v1 = @embedFile("migrations/001_create_tasks.sql");
};

/// Runs pending migrations in order. Each migration runs in its own
/// transaction. Idempotent — safe to call on every app startup.
pub fn run_migrations(db: *zqlite.Conn) !void {
    const current_version: i64 = if (db.row(
        "SELECT COALESCE(MAX(version), 0) FROM _schema_version",
        .{},
    ) catch null) |row| row.int(0) else 0;

    if (current_version < 1) {
        try db.exec(migrations.v1, .{});
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
zig build test --summary all
```

Expected: PASS — both migration tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/internal/database/migrations/001_create_tasks.sql src/internal/database/migrate.zig
git commit -m "feat: add migration runner with embedded sql files"
```

---

## Self-Review

**Spec coverage (against [2026-07-03-02 design](../specs/2026-07-03-02-sqlite-foundation-design.md)):**
- F1 zqlite dependency → Task 1 Step 1.
- F2 embedded `.sql` files → Task 3 (via `@embedFile`).
- F3 version counter in `_schema_version` → Task 3 Step 4 (`SELECT COALESCE(MAX(version), 0)`).
- F4 numbered `NNN_*.sql` files → Task 3 Step 1 (`001_create_tasks.sql`).
- F5 each migration its own transaction → Task 3 Step 4 (each version block is a separate `db.exec`).
- F6 in-memory tests → Task 3 Steps 2/5 (`zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode)`).
- F7 WAL mode → Task 2 Step 3 (`PRAGMA journal_mode = WAL`).

**Placeholder scan:** none — every code step contains full code and exact commands.

**Type consistency:** `open(allocator, io, environ) !zqlite.Conn` consistent across Task 2. `run_migrations(db: *zqlite.Conn) !void` consistent across Task 3. `zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode)` used identically in all test steps.
