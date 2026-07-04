# Sub-project 08 — Task filters/search/stats (DESIGN)

> **Status:** DESIGN APPROVED
> **Date:** 2026-07-04
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 07 (Export/Import)
> **Successor:** 09 (Tags + categories + custom fields)

This sub-project adds filtered listing, full-text search, and basic statistics to the
task manager. Filters, search, and stats share a common `TaskQuery` engine and are
designed as one unit.

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| 08-1 | **One sub-project.** Filters, search, and stats share the query engine; design + implement together. | LOCKED |
| 08-2 | **SQL-native query builder** (Approach A). By implementation time SQLite is the store (SP02/SP03). `TaskQuery` maps directly to SQL WHERE clauses. | LOCKED |
| 08-3 | **`--search` is a flag on `list`, not a separate command.** Composes with other filters. | LOCKED |
| 08-4 | **Stats shows basic counts only:** total, by status (`pending`/`in-progress`/`completed`), and overdue. | LOCKED |
| 08-5 | **All model fields get filter flags:** `--status`, `--priority`, `--due`, `--assigned`, `--search`. | LOCKED |
| 08-6 | **Stats reuses the same filter flags** to scope the aggregation. | LOCKED |
| 08-7 | **Filters compose as AND.** Multiple flags narrow the result set. | LOCKED |
| 08-8 | **FTS setup** (FTS5 virtual table with triggers) added as a migration in the SP02/SP03 migration runner or an SP08-specific migration. | LOCKED |

---

## Part A — CLI Surface

### Extended `tip task list`

```
tip task list [--status=<s>] [--priority=<p>] [--due=<d>]
              [--assigned=<u>] [--search=<q>]
```

| Flag | Values | Behaviour |
|------|--------|-----------|
| `--status` | `pending`, `in-progress`, `completed` (alias `done`) | Filter by exact status |
| `--priority` | `low`, `medium`, `high` | Filter by exact priority |
| `--due` | `today`, `overdue`, `week`, or Unix timestamp | `today` = start-of-day to end-of-day; `week` = start of current ISO Monday to now; `overdue` = `due_date < now AND status != completed`; timestamp = exact `due_date` match |
| `--assigned` | username string | Substring match on `assigned_to` (`LIKE '%<val>%'`) |
| `--search` | free-text query | FTS5 `MATCH` (or `LIKE '%<val>%'` fallback) on title + description |

No flags = all tasks (current behaviour). Multiple flags = AND.

### New `tip task stats`

```
tip task stats [--status=<s>] [--priority=<p>] [--due=<d>]
               [--assigned=<u>] [--search=<q>]
```

Same flags as `list`. Output:

```
Total:      42
Pending:    15
In-Progress: 5
Completed:  22
Overdue:     3
```

Filtered:

```
$ tip task stats --priority=high
Total:      8
Pending:    3
In-Progress: 2
Completed:  3
Overdue:     1
```

---

## Part B — Internal architecture

### `TaskQuery` struct

```zig
pub const TaskQuery = struct {
    status: ?models.Task.Status = null,
    priority: ?models.Task.Priority = null,
    due: ?DueFilter = null,
    assigned_to: ?[]const u8 = null,
    search: ?[]const u8 = null,
};

pub const DueFilter = union(enum) {
    today,
    overdue,
    week,
    timestamp: i64,
};
```

### `TaskStats` struct

```zig
pub const TaskStats = struct {
    total: usize,
    pending: usize,
    in_progress: usize,
    completed: usize,
    overdue: usize,
};
```

### Storage handle methods (added to the SP03 `Handle`)

```zig
/// Returns tasks matching query, ordered by created_at desc.
pub fn list(self: *Handle, query: TaskQuery, allocator: std.mem.Allocator) ![]models.Task;

/// Returns aggregate counts scoped by the same query filters.
pub fn stats(self: *Handle, query: TaskQuery) !TaskStats;
```

### SQL mapping

`list()` builds a `SELECT ... FROM tasks WHERE ...`:

| Query field | SQL clause |
|-------------|------------|
| `status` | `status = ?` |
| `priority` | `priority = ?` |
| `due.today` | `due_date >= ? AND due_date < ?` (start/end of current day) |
| `due.overdue` | `due_date < ? AND status != 'completed'` |
| `due.week` | `due_date >= ? AND due_date < ?` (start/end of current week) |
| `due.timestamp` | `due_date = ?` |
| `assigned_to` | `assigned_to LIKE '%' || ? || '%'` (substring match) |
| `search` | `rowid IN (SELECT rowid FROM tasks_fts WHERE tasks_fts MATCH ?)` (FTS5) or fallback `(title LIKE '%' || ? || '%' OR description LIKE '%' || ? || '%')` |

`stats()` runs parallel `SELECT COUNT(*)` queries or a single `SELECT status, COUNT(*) FROM tasks WHERE ... GROUP BY status`, plus a separate overdue count.

### FTS5 setup

Migration (runs once):

```sql
CREATE VIRTUAL TABLE tasks_fts USING fts5(
    title, description,
    content='tasks',
    content_rowid='rowid'
);

-- Triggers to keep FTS in sync with tasks table
CREATE TRIGGER tasks_ai AFTER INSERT ON tasks BEGIN
    INSERT INTO tasks_fts(rowid, title, description)
    VALUES (new.rowid, new.title, new.description);
END;

CREATE TRIGGER tasks_ad AFTER DELETE ON tasks BEGIN
    INSERT INTO tasks_fts(tasks_fts, rowid, title, description)
    VALUES ('delete', old.rowid, old.title, old.description);
END;

CREATE TRIGGER tasks_au AFTER UPDATE ON tasks BEGIN
    INSERT INTO tasks_fts(tasks_fts, rowid, title, description)
    VALUES ('delete', old.rowid, old.title, old.description);
    INSERT INTO tasks_fts(rowid, title, description)
    VALUES (new.rowid, new.title, new.description);
END;
```

### List output with filters

Current group-by-status layout is preserved. Active filters are shown in the section header:

```
Pending (3 — filtered)
  ○ Buy groceries
  ...

Completed (1 — filtered)
  ✓ ...
```

If `--search` is used, matching terms are highlighted via ANSI codes.

---

## Part C — Out of scope

- **`--sort` / ordering flags** — deferred. Default ordering is `created_at DESC`.
- **Pagination** (`--limit`, `--offset`) — deferred until task counts grow.
- **Tags/categories as filter criteria** — belongs in SP09.
- **CSV export** — belongs in SP07 or later.
- **Interactive filter prompts** — CLI flags only.

---

## Part D — Testing

- Unit tests for `TaskQuery` → SQL clause construction (if the builder is isolated)
- Unit tests for `matches()` predicate logic (in-memory variant)
- Integration tests via in-memory SQLite: insert tasks, query with each filter flag, assert result set
- FTS5 test: insert tasks with known text, search, assert correct match
- Stats test: insert varied tasks, call `stats()`, verify counts
- Edge cases: empty result sets, null `due_date`, no search match, all filters together
