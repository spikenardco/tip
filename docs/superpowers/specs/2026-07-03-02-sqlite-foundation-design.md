# Sub-project 02 — SQLite Foundation (DESIGN)

> **Status:** DESIGN APPROVED
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
| F3 | **Simple version-counter** in `_schema_version` table (`INTEGER`). | LOCKED |
| F4 | **Migrations numbered `NNN_*.sql`** in `src/internal/database/migrations/`. | LOCKED |
| F5 | **Each migration gets its own transaction.** No cross-migration wrapping. | LOCKED |
| F6 | **In-memory SQLite** for tests (`zqlite.open(":memory:", flags)`). | LOCKED |
| F7 | **WAL mode** enabled on open (`PRAGMA journal_mode=WAL`). | LOCKED |

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

- `run_migrations(db)` checks `SELECT version FROM _schema_version` (returns 0 if table missing).
- Collects embedded SQL files ordered by filename prefix: `@embedFile("migrations/001_create_tasks.sql")`, etc.
- The 3-digit prefix is the version number.
- Applies each where `version > current_version`, one per transaction.
- After each migration, updates `_schema_version.version` to the applied number.
- Fails hard on error — partial state is contained within one failed migration.

### `001_create_tasks.sql` content

Placeholder for this sub-project — enough to prove the runner works:

```sql
CREATE TABLE IF NOT EXISTS _schema_version (version INTEGER NOT NULL);
INSERT INTO _schema_version (version) VALUES (1);
```

The Tasks table schema and real data migrations are added in sub-project 03.

---

## Part D — Testing

All tests use `zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode)`:

- **`migrations run from scratch`** — open in-memory, run migrations, verify `_schema_version.version == 1`.
- **`migrations are idempotent`** — run twice, no error, version stays 1.
- **`migration ordering`** — if 001 and 002 .sql files exist, verify both applied, version = 2.

---

## Out of scope

- **Tasks table schema and CRUD** — sub-project 03.
- **Storage handle / Store API** — sub-project 03.
- **JSON storage removal** — sub-project 03.
- **Prefix matching, complete/start** — sub-project 04.
- **Config system, global flags** — sub-project 05.

---

## Next step

Write the checkbox implementation plan for this sub-project via the writing-plans skill. **No implementation yet.**
