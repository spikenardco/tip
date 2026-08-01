# Sub-project 02 — SQLite Foundation (DESIGN)

> **Status:** IMPLEMENTED WITH DEVIATIONS. Original design preserved; see the baseline record.
> **Date:** 2026-07-03
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 01 (ID Strategy + Error Taxonomy) — design and plan done
> **Successors:** 03 (Storage handle API + Tasks table), 04 (complete/start, prefix-match)

This sub-project wires SQLite into the build, adds the `db.zig` connection module, and establishes the migration runner. No task-domain schema yet — that lands in sub-project 03.

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| F1 | **zqlite** is the dependency — [karlseguin/zqlite.zig](https://github.com/karlseguin/zqlite.zig), which bundles its own `sqlite3.c` amalgamation. | LOCKED |
| F2 | **Embedded `.sql` files** via `@embedFile`, not read from disk. | LOCKED |
| F3 | **SQLite `PRAGMA user_version`** is the single schema version source. | IMPLEMENTED |
| F4 | **Migrations numbered `NNN_*.sql`** in `src/internal/database/migrations/`. | LOCKED |
| F5 | **Migration transaction behavior.** The original design used one transaction per migration; the active runner uses one transaction for the migration batch. | IMPLEMENTED WITH DEVIATIONS |
| F6 | **In-memory SQLite** for tests (`zqlite.open(":memory:", flags)`). | LOCKED |
| F7 | **WAL mode** enabled on open (`PRAGMA journal_mode=WAL`). | IMPLEMENTED |
| F8 | **Foreign keys and busy timeout** configured on every opened connection. | IMPLEMENTED |

---

## Part A — Dependency & Build Wiring

### Dependency

- Run `zig fetch --save git+https://github.com/karlseguin/zqlite.zig` to add to `build.zig.zon`.
- Import the `sqlite` module in `build.zig` and add it to the exe root module imports.
- zqlite bundles its own `sqlite3.c` amalgamation and compiles it as a static library. No system sqlite3 dependency needed.

### Test wiring

- The auto-test-runner already globs `src/**/*.zig` — new files under `src/internal/database/` are picked up automatically.
- Tests use `zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode)` — no temp files needed.

---

## Part B — Database Module (`src/internal/database/db.zig`)

Single function:

```zig
pub fn open(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !zqlite.Conn
```

- Resolves the platform data directory (same pattern as `storage.json.open_data_dir`):
  - Linux: `$XDG_DATA_HOME/tip` or `~/.local/share/tip`
  - macOS: `~/Library/Application Support/tip`
  - Windows: `%APPDATA%/tip`
- Database file: `tip.db`
- Opens with `zqlite.open(path, flags)`, enables WAL mode via `PRAGMA journal_mode=WAL`.
- Returns `zqlite.Conn` — caller owns and must `db.deinit()`.
- No connection pooling (single-process CLI).

---

## Part C — Migration Runner (`src/internal/database/migrate.zig`)

### File layout

```
src/internal/database/
  db.zig
  migrate.zig
  migrations/
    001_create_tasks.sql
```

### Runner behavior

- `run_migrations(conn)` reads `PRAGMA user_version` after `BEGIN IMMEDIATE`.
- Applies explicitly embedded migrations in numeric order. The active set contains only `001_create_tasks.sql`.
- The 3-digit prefix is the version number.
- Applies every pending migration inside one transaction.
- Each migration ends by setting `PRAGMA user_version` and the runner verifies the resulting version.
- Rejects future, negative, or non-contiguous versions and rolls back every pre-commit error.

### `001_create_tasks.sql` content

Current version-one migration:

```sql
CREATE TABLE tasks (
    id           TEXT PRIMARY KEY NOT NULL,
    title        TEXT NOT NULL CHECK (length(trim(title)) > 0),
    description  TEXT,
    status       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'in_progress', 'completed')),
    priority     TEXT CHECK (priority IS NULL OR priority IN ('low', 'medium', 'high')),
    due_date     INTEGER,
    assigned_to  TEXT,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER,
    completed_at INTEGER
);

PRAGMA user_version = 1;
```

Future schema changes must use additional numbered migration files.

---

## Part D — Testing

All tests use `zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode)`:

- **`migrations run from scratch`** — open in-memory, run migrations, verify `PRAGMA user_version == 1` and the tasks table exists.
- **`migrations are idempotent`** — run twice, no error, version stays 1, and no `_schema_version` table exists.
- **`constraints`** — empty titles and invalid status/priority values are rejected.
- **`future versions`** — a database with a higher `user_version` is rejected without schema changes.
- **`rollback`** — a conflicting object causes migration failure without changing schema or version.
- **`legacy databases`** — databases using `_schema_version` are rejected rather than repaired.

---

## Out of scope

- **Tasks table schema and CRUD** — sub-project 03.
- **Storage handle / Store API** — sub-project 03.
- **JSON storage removal** — sub-project 03.
- **Prefix matching, complete/start** — sub-project 04.
- **Config system, global flags** — sub-project 05.

---

## Baseline record (2026-08-01)

- zqlite, WAL mode, embedded SQL, and in-memory migration tests are present.
- `db.open` accepts a NUL-terminated database path. Platform data-directory resolution is
  outside this module, not part of its public API.
- The active migration set is `001_create_tasks.sql`.
  The runner reads and writes `PRAGMA user_version`, applies pending SQL in one `BEGIN IMMEDIATE`
  transaction, and commits version 1.
- Existing `_schema_version` databases are an intentional clean break and must be recreated.

## Next step

Writing the checkbox implementation plan for this sub-project via the writing-plans skill is
complete; this document is now a baseline record.
