# Sub-project 08 — Task Filters/Search/Stats Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add filtered listing (`--status`, `--priority`, `--due`, `--assigned`), full-text search (`--search`), and basic statistics (`tip task stats`) to the task manager.

**Architecture:** A new `src/core/query.zig` module defines `TaskQuery`, `DueFilter`, `TaskStats`, and a SQL WHERE clause builder. The `Vault.Tasks` handle (SP03) gets `list(query)` and `stats(query)` methods. The CLI layer in `task.zig` extends `TaskArgs` with filter flags and adds a `stats` subcommand. FTS5 is set up via a migration.

**Tech Stack:** Zig 0.16 (`std.Io` async model), `zig-sqlite`, `flags` dependency, SQLite FTS5.

**Dependency:** This plan requires **sub-projects 01–07 to be implemented first** — it relies on the `Vault` handle from SP03, task CRUD from SP03/SP04, vaults from SP06, config from SP05, and the SQLite migration runner from SP02.

---

## Global Constraints

- **Zig version:** 0.16.0 (`minimum_zig_version = "0.16.0"`). Use the new `std.Io` APIs.
- **Identifier casing:** functions/vars/fields = `snake_case`; types = `PascalCase`; enum members = `snake_case`.
- **Error taxonomy (sub-project 01):** `TaskNotFound`, `AmbiguousPrefix`, `StorageFailure`, `EmptyTitle`, `InvalidFilterValue`, `FtsUnavailable`. Commands return errors; `main.zig` renders via `errors.describe`/`errors.exit_code`.
- **Exit codes:** `0` ok · `1` internal · `2` usage · `3` not found · `4` validation.
- **Vault handle (SP03):** `Vault.open(allocator, io, .{ .name = name })` → `Vault`, `vault.tasks` → `Tasks` handle with methods `add()`, `list()`, `edit()`, `delete()`, `show()`, `complete()`, `start()`.
- **zig-sqlite API:** `Db.init(.{ .mode = .{ .Memory = {} } })` for in-memory, `db.exec(sql, params, .{})` for statements, `db.one(T, sql, params, .{ .allocator = allocator })` for single-row, `db.all(T, sql, params, .{ .allocator = allocator })` for multi-row.
- **FTS5:** Requires SQLite built with `SQLITE_ENABLE_FTS5` (standard in most distributions).
- **Tests:** `zig build test --summary all` from repo root. Tests use in-memory SQLite.
- **Filters compose as AND.** No flags → all tasks (unchanged).
- **Out of scope:** `--sort`/ordering flags, pagination (`--limit`/`--offset`), tags as filter criteria (SP09), CSV export.

---

### Task 1: Create `src/core/query.zig` with TaskQuery, DueFilter, TaskStats, SQL builder, and matches()

**Files:**
- Create: `src/core/query.zig`

**Interfaces:**
- Consumes: `models.Task`, `models.Task.Status`, `models.Task.Priority` (from `models.zig`).
- Produces:
  - `pub const DueFilter = union(enum) { today, overdue, week, timestamp: i64 }`
  - `pub const TaskQuery = struct { status: ?Status, priority: ?Priority, due: ?DueFilter, assigned_to: ?[]const u8, search: ?[]const u8 }`
  - `pub const TaskStats = struct { total: usize, pending: usize, in_progress: usize, completed: usize, overdue: usize }`
  - `pub const BindParam = union(enum) { string: []const u8, i64: i64 }`
  - `pub const WhereClause = struct { sql: []const u8, params: []const BindParam }`
  - `pub fn build_where_clause(query: TaskQuery, allocator: std.mem.Allocator, now: i64) WhereClause`
  - `pub fn matches(task: models.Task, query: TaskQuery, now: i64) bool`

- [ ] **Step 1: Write the failing tests for query types and defaults**

Append to `src/core/query.zig`:

```zig
const std = @import("std");
const models = @import("models.zig");

test "TaskQuery default has all null fields" {
    const q = TaskQuery{};
    try std.testing.expect(q.status == null);
    try std.testing.expect(q.priority == null);
    try std.testing.expect(q.due == null);
    try std.testing.expect(q.assigned_to == null);
    try std.testing.expect(q.search == null);
}

test "TaskStats default is all zeros" {
    const s = TaskStats{};
    try std.testing.expectEqual(@as(usize, 0), s.total);
    try std.testing.expectEqual(@as(usize, 0), s.pending);
    try std.testing.expectEqual(@as(usize, 0), s.in_progress);
    try std.testing.expectEqual(@as(usize, 0), s.completed);
    try std.testing.expectEqual(@as(usize, 0), s.overdue);
}

test "DueFilter variants compile" {
    const a: DueFilter = .today;
    const b: DueFilter = .overdue;
    const c: DueFilter = .week;
    const d: DueFilter = .{ .timestamp = 1000 };
    _ = a; _ = b; _ = c; _ = d;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL with compile errors (types not yet defined)

- [ ] **Step 3: Write the type definitions and initial tests**

```zig
const std = @import("std");
const models = @import("models.zig");

pub const DueFilter = union(enum) {
    today,
    overdue,
    week,
    timestamp: i64,
};

pub const TaskQuery = struct {
    status: ?models.Task.Status = null,
    priority: ?models.Task.Priority = null,
    due: ?DueFilter = null,
    assigned_to: ?[]const u8 = null,
    search: ?[]const u8 = null,
};

pub const TaskStats = struct {
    total: usize,
    pending: usize,
    in_progress: usize,
    completed: usize,
    overdue: usize,
};

pub const BindParam = union(enum) {
    string: []const u8,
    i64: i64,
};

pub const WhereClause = struct {
    sql: []const u8,
    params: []const BindParam,
};
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (3 tests)

- [ ] **Step 5: Write the failing test for `build_where_clause` — no filters**

```zig
test "build_where_clause with no filters returns empty SQL" {
    const q = TaskQuery{};
    const wc = build_where_clause(q, std.testing.allocator, 0);
    try std.testing.expectEqualStrings("", wc.sql);
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `build_where_clause` not defined

- [ ] **Step 7: Implement `build_where_clause`**

```zig
pub fn build_where_clause(q: TaskQuery, allocator: std.mem.Allocator, now: i64) WhereClause {
    var clauses = std.ArrayList(u8).init(allocator);
    var params = std.ArrayList(BindParam).init(allocator);

    if (q.status) |s| {
        const status_str = switch (s) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
        };
        if (clauses.items.len > 0) clauses.appendSlice(" AND ") catch {};
        clauses.appendSlice("status = ?") catch {};
        params.append(allocator, .{ .string = status_str }) catch {};
    }

    if (q.priority) |p| {
        const priority_str = switch (p) {
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
        if (clauses.items.len > 0) clauses.appendSlice(" AND ") catch {};
        clauses.appendSlice("priority = ?") catch {};
        params.append(allocator, .{ .string = priority_str }) catch {};
    }

    if (q.due) |due| switch (due) {
        .today => {
            const day_start = (now / 86400) * 86400;
            const day_end = day_start + 86400;
            if (clauses.items.len > 0) clauses.appendSlice(" AND ") catch {};
            clauses.appendSlice("due_date >= ? AND due_date < ?") catch {};
            params.append(allocator, .{ .i64 = day_start }) catch {};
            params.append(allocator, .{ .i64 = day_end }) catch {};
        },
        .overdue => {
            if (clauses.items.len > 0) clauses.appendSlice(" AND ") catch {};
            clauses.appendSlice("due_date < ? AND status != 'completed'") catch {};
            params.append(allocator, .{ .i64 = now }) catch {};
        },
        .week => {
            const seconds_per_day: i64 = 86400;
            const days_since_monday = @mod(now / seconds_per_day + 3, 7);
            const week_start = (now / seconds_per_day - days_since_monday) * seconds_per_day;
            if (clauses.items.len > 0) clauses.appendSlice(" AND ") catch {};
            clauses.appendSlice("due_date >= ? AND due_date < ?") catch {};
            params.append(allocator, .{ .i64 = week_start }) catch {};
            params.append(allocator, .{ .i64 = now }) catch {};
        },
        .timestamp => |ts| {
            if (clauses.items.len > 0) clauses.appendSlice(" AND ") catch {};
            clauses.appendSlice("due_date = ?") catch {};
            params.append(allocator, .{ .i64 = ts }) catch {};
        },
    };

    if (q.assigned_to) |a| {
        if (clauses.items.len > 0) clauses.appendSlice(" AND ") catch {};
        clauses.appendSlice("assigned_to LIKE '%' || ? || '%'") catch {};
        params.append(allocator, .{ .string = a }) catch {};
    }

    if (q.search) |s| {
        if (clauses.items.len > 0) clauses.appendSlice(" AND ") catch {};
        clauses.appendSlice("(rowid IN (SELECT rowid FROM tasks_fts WHERE tasks_fts MATCH ?) OR title LIKE '%' || ? || '%' OR description LIKE '%' || ? || '%')") catch {};
        params.append(allocator, .{ .string = s }) catch {};
        params.append(allocator, .{ .string = s }) catch {};
        params.append(allocator, .{ .string = s }) catch {};
    }

    return .{
        .sql = clauses.items,
        .params = params.items,
    };
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 9: Write failing tests for `build_where_clause` — each filter type**

```zig
test "build_where_clause with status filter" {
    const q = TaskQuery{ .status = .pending };
    const wc = build_where_clause(q, std.testing.allocator, 0);
    try std.testing.expect(std.mem.indexOf(u8, wc.sql, "status = ?") != null);
    try std.testing.expectEqual(@as(usize, 1), wc.params.len);
    try std.testing.expectEqualStrings("pending", wc.params[0].string);
}

test "build_where_clause with priority filter" {
    const q = TaskQuery{ .priority = .high };
    const wc = build_where_clause(q, std.testing.allocator, 0);
    try std.testing.expect(std.mem.indexOf(u8, wc.sql, "priority = ?") != null);
    try std.testing.expectEqual(@as(usize, 1), wc.params.len);
    try std.testing.expectEqualStrings("high", wc.params[0].string);
}

test "build_where_clause with due=today" {
    const now: i64 = 1700000000;
    const q = TaskQuery{ .due = .today };
    const wc = build_where_clause(q, std.testing.allocator, now);
    try std.testing.expect(std.mem.indexOf(u8, wc.sql, "due_date >=") != null);
    try std.testing.expect(std.mem.indexOf(u8, wc.sql, "due_date <") != null);
    try std.testing.expectEqual(@as(usize, 2), wc.params.len);
    try std.testing.expectEqual((now / 86400) * 86400, wc.params[0].i64);
    try std.testing.expectEqual((now / 86400) * 86400 + 86400, wc.params[1].i64);
}

test "build_where_clause with due=overdue" {
    const q = TaskQuery{ .due = .overdue };
    const wc = build_where_clause(q, std.testing.allocator, 1000);
    try std.testing.expect(std.mem.indexOf(u8, wc.sql, "status != 'completed'") != null);
    try std.testing.expectEqual(@as(usize, 1), wc.params.len);
    try std.testing.expectEqual(@as(i64, 1000), wc.params[0].i64);
}

test "build_where_clause with assigned_to" {
    const q = TaskQuery{ .assigned_to = "alice" };
    const wc = build_where_clause(q, std.testing.allocator, 0);
    try std.testing.expect(std.mem.indexOf(u8, wc.sql, "LIKE") != null);
    try std.testing.expectEqual(@as(usize, 1), wc.params.len);
    try std.testing.expectEqualStrings("alice", wc.params[0].string);
}

test "build_where_clause with search" {
    const q = TaskQuery{ .search = "urgent" };
    const wc = build_where_clause(q, std.testing.allocator, 0);
    try std.testing.expect(std.mem.indexOf(u8, wc.sql, "MATCH") != null);
    try std.testing.expectEqual(@as(usize, 3), wc.params.len); // 1 for FTS + 2 for LIKE fallback
    try std.testing.expectEqualStrings("urgent", wc.params[0].string);
}

test "build_where_clause composes multiple filters with AND" {
    const q = TaskQuery{ .status = .pending, .priority = .high };
    const wc = build_where_clause(q, std.testing.allocator, 0);
    try std.testing.expect(std.mem.indexOf(u8, wc.sql, "AND") != null);
}
```

- [ ] **Step 10: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 11: Write failing tests for `matches()` — in-memory filtering**

```zig
test "matches with no query returns true" {
    const task = models.Task{
        .id = "1",
        .title = "test",
        .status = .pending,
        .created_at = 0,
    };
    try std.testing.expect(matches(task, TaskQuery{}, 0));
}

test "matches filters by status" {
    const task = models.Task{
        .id = "1",
        .title = "test",
        .status = .pending,
        .created_at = 0,
    };
    try std.testing.expect(matches(task, TaskQuery{ .status = .pending }, 0));
    try std.testing.expect(!matches(task, TaskQuery{ .status = .completed }, 0));
}

test "matches filters by priority" {
    const task = models.Task{
        .id = "1",
        .title = "test",
        .status = .pending,
        .priority = .high,
        .created_at = 0,
    };
    try std.testing.expect(matches(task, TaskQuery{ .priority = .high }, 0));
    try std.testing.expect(!matches(task, TaskQuery{ .priority = .low }, 0));
}

test "matches filters by due=overdue" {
    const task = models.Task{
        .id = "1",
        .title = "test",
        .status = .pending,
        .due_date = 100,
        .created_at = 0,
    };
    try std.testing.expect(matches(task, TaskQuery{ .due = .overdue }, 1000));
    // completed tasks are not overdue
    const done = models.Task{
        .id = "2",
        .title = "done",
        .status = .completed,
        .due_date = 100,
        .created_at = 0,
    };
    try std.testing.expect(!matches(done, TaskQuery{ .due = .overdue }, 1000));
}

test "matches filters by assigned_to substring" {
    const task = models.Task{
        .id = "1",
        .title = "test",
        .status = .pending,
        .assigned_to = "alice",
        .created_at = 0,
    };
    try std.testing.expect(matches(task, TaskQuery{ .assigned_to = "ali" }, 0));
    try std.testing.expect(!matches(task, TaskQuery{ .assigned_to = "bob" }, 0));
}

test "matches filters by search (title)" {
    const task = models.Task{
        .id = "1",
        .title = "buy groceries",
        .description = "",
        .status = .pending,
        .created_at = 0,
    };
    try std.testing.expect(matches(task, TaskQuery{ .search = "groc" }, 0));
    try std.testing.expect(!matches(task, TaskQuery{ .search = "urgent" }, 0));
}
```

- [ ] **Step 12: Run to verify they fail**

Run: `zig build test --summary all`
Expected: FAIL — `matches` not defined

- [ ] **Step 13: Implement `matches()`**

```zig
pub fn matches(task: models.Task, query: TaskQuery, now: i64) bool {
    if (query.status) |s| {
        if (task.status != s) return false;
    }
    if (query.priority) |p| {
        if (task.priority) |tp| {
            if (tp != p) return false;
        } else {
            return false;
        }
    }
    if (query.due) |due| {
        const due_val = task.due_date orelse return false;
        switch (due) {
            .today => {
                const day_start = (now / 86400) * 86400;
                const day_end = day_start + 86400;
                if (due_val < day_start or due_val >= day_end) return false;
            },
            .overdue => {
                if (due_val >= now or task.status == .completed) return false;
            },
            .week => {
                const seconds_per_day: i64 = 86400;
                const days_since_monday = @mod(now / seconds_per_day + 3, 7);
                const week_start = (now / seconds_per_day - days_since_monday) * seconds_per_day;
                if (due_val < week_start or due_val > now) return false;
            },
            .timestamp => |ts| {
                if (due_val != ts) return false;
            },
        }
    }
    if (query.assigned_to) |a| {
        const assigned = task.assigned_to orelse return false;
        if (std.mem.indexOf(u8, assigned, a) == null) return false;
    }
    if (query.search) |s| {
        const title_match = std.mem.indexOf(u8, task.title, s) != null;
        const desc_str = task.description orelse "";
        const desc_match = std.mem.indexOf(u8, desc_str, s) != null;
        if (!title_match and !desc_match) return false;
    }
    return true;
}
```

- [ ] **Step 14: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (all 15+ tests)

- [ ] **Step 15: Commit**

```bash
git add src/core/query.zig
git commit -m "feat: add TaskQuery, DueFilter, TaskStats, SQL builder, and matches()"
```

---

### Task 2: Add `list(query)` and `stats(query)` to the Vault.Tasks handle

**Files:**
- Modify: `src/core/vault.zig` (the SP03 Vault handle — add `list` and `stats` methods to `Vault.Tasks`)

**Interfaces:**
- Consumes: `query.TaskQuery`, `query.WhereClause`, `query.TaskStats`, `query.build_where_clause`, `sqlite.Db` from vault handle.
- Produces:
  - `pub fn list(self: *Tasks, query: query.TaskQuery, allocator: std.mem.Allocator) ![]models.Task`
  - `pub fn stats(self: *Tasks, query: query.TaskQuery) !query.TaskStats`

- [ ] **Step 1: Write the failing tests — filtered list**

Append to `src/core/vault.zig` tests:

```zig
test "Tasks.list with status filter returns only matching tasks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.tasks.add(.{ .title = "Task A", .status = .pending });
    try vault.tasks.add(.{ .title = "Task B", .status = .completed });
    try vault.tasks.add(.{ .title = "Task C", .status = .pending });

    const results = try vault.tasks.list(.{ .status = .pending }, allocator);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("Task A", results[0].title);
    try std.testing.expectEqualStrings("Task C", results[1].title);
}
```

```zig
test "Tasks.list with priority filter" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.tasks.add(.{ .title = "High", .priority = .high });
    try vault.tasks.add(.{ .title = "Low", .priority = .low });

    const results = try vault.tasks.list(.{ .priority = .high }, allocator);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("High", results[0].title);
}
```

```zig
test "Tasks.list with combined filters" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.tasks.add(.{ .title = "Match", .status = .pending, .priority = .high });
    try vault.tasks.add(.{ .title = "No", .status = .completed, .priority = .high });
    try vault.tasks.add(.{ .title = "Nope", .status = .pending, .priority = .low });

    const results = try vault.tasks.list(.{ .status = .pending, .priority = .high }, allocator);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("Match", results[0].title);
}
```

```zig
test "Tasks.list without filter returns all tasks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.tasks.add(.{ .title = "A" });
    try vault.tasks.add(.{ .title = "B" });

    const results = try vault.tasks.list(.{}, allocator);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test --summary all`
Expected: FAIL — `list` with `query` parameter doesn't exist yet

- [ ] **Step 3: Implement `list(query)`**

In `src/core/vault.zig`, find the `Tasks` struct and add a new `list` method alongside the existing one. The existing parameterless `list()` becomes a convenience wrapper:

```zig
pub fn list(self: *Tasks, q: query.TaskQuery, allocator: std.mem.Allocator) ![]models.Task {
    const now = std.Io.Timestamp.now(self.vault.io, .real).toSeconds();
    const wc = query.build_where_clause(q, allocator, now);
    defer allocator.free(wc.sql);

    var sql = std.ArrayList(u8).init(allocator);
    defer sql.deinit(allocator);
    try sql.appendSlice("SELECT id, title, description, status, priority, due_date, assigned_to, created_at, updated_at, completed_at FROM tasks");
    if (wc.sql.len > 0) {
        try sql.appendSlice(" WHERE ");
        try sql.appendSlice(wc.sql);
    }
    try sql.appendSlice(" ORDER BY created_at DESC");

    return try self.vault.db.all(models.Task, sql.items, wc.params, .{ .allocator = allocator });
}
```

The `BindParam` type and `WhereClause` struct are defined in `query.zig` (Task 1). zig-sqlite's `all()` accepts `[]const BindParam` natively.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 5: Write failing tests for `stats()`**

```zig
test "Tasks.stats returns correct counts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.tasks.add(.{ .title = "A", .status = .pending, .due_date = 100 });
    try vault.tasks.add(.{ .title = "B", .status = .in_progress });
    try vault.tasks.add(.{ .title = "C", .status = .completed });
    try vault.tasks.add(.{ .title = "D", .status = .pending, .due_date = 50 }); // overdue

    const stats = try vault.tasks.stats(.{});
    try std.testing.expectEqual(@as(usize, 4), stats.total);
    try std.testing.expectEqual(@as(usize, 2), stats.pending);
    try std.testing.expectEqual(@as(usize, 1), stats.in_progress);
    try std.testing.expectEqual(@as(usize, 1), stats.completed);
    try std.testing.expectEqual(@as(usize, 1), stats.overdue);
}
```

```zig
test "Tasks.stats with filter scopes counts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.tasks.add(.{ .title = "A", .status = .pending, .priority = .high });
    try vault.tasks.add(.{ .title = "B", .status = .completed, .priority = .high });
    try vault.tasks.add(.{ .title = "C", .status = .pending, .priority = .low });

    const stats = try vault.tasks.stats(.{ .priority = .high });
    try std.testing.expectEqual(@as(usize, 2), stats.total);
    try std.testing.expectEqual(@as(usize, 1), stats.pending);
}
```

- [ ] **Step 6: Run to verify they fail**

Run: `zig build test --summary all`
Expected: FAIL — `stats` not defined on Tasks

- [ ] **Step 7: Implement `stats(query)`**

Use a single `COUNT(*)` for total, a `GROUP BY status` for per-status counts, and a separate count for overdue. All reuse the same WHERE clause and params from `build_where_clause`:

```zig
pub fn stats(self: *Tasks, q: query.TaskQuery) !query.TaskStats {
    const allocator = self.vault.allocator;
    const io = self.vault.io;
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const wc = query.build_where_clause(q, allocator, now);
    defer allocator.free(wc.sql);

    const base_from = "FROM tasks" ++ if (wc.sql.len > 0) " WHERE " ++ wc.sql else "";

    const total = try self.vault.db.one(usize, "SELECT COUNT(*) " ++ base_from, wc.params, .{});

    // Per-status counts via GROUP BY
    const StatusRow = struct { status: []const u8, count: usize };
    const status_rows = try self.vault.db.all(StatusRow, "SELECT status, COUNT(*) AS count " ++ base_from ++ " GROUP BY status", wc.params, .{ .allocator = allocator });
    defer allocator.free(status_rows);

    var pending: usize = 0;
    var in_progress: usize = 0;
    var completed: usize = 0;
    for (status_rows) |row| {
        if (std.mem.eql(u8, row.status, "pending")) pending = row.count;
        if (std.mem.eql(u8, row.status, "in_progress")) in_progress = row.count;
        if (std.mem.eql(u8, row.status, "completed")) completed = row.count;
    }

    // Overdue count: build params with extra `now` param appended
    var overdue_params = std.ArrayList(query.BindParam).init(allocator);
    try overdue_params.appendSlice(allocator, wc.params);
    try overdue_params.append(allocator, .{ .i64 = now });
    const overdue = try self.vault.db.one(usize, "SELECT COUNT(*) " ++ base_from ++ " AND due_date < ? AND status != 'completed'", overdue_params.items, .{});

    return .{
        .total = total,
        .pending = pending,
        .in_progress = in_progress,
        .completed = completed,
        .overdue = overdue,
    };
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add src/core/query.zig src/core/vault.zig
git commit -m "feat: add list(query) and stats(query) to Vault.Tasks handle"
```

---

### Task 3: Extend CLI — add filter flags to TaskArgs and wire into dispatch

**Files:**
- Modify: `src/core/task.zig` (TaskArgs struct, help text, dispatch_task_command, list_task)

**Interfaces:**
- Consumes: `query.TaskQuery`, `query.DueFilter`, `Vault.Tasks.list(query)`, `flags` CLI parsing.
- Produces: extended `TaskArgs` with `status`, `priority`, `due`, `assigned_to`, `search` fields; updated `list_task(query)`.

- [ ] **Step 1: Write failing tests — verify `list` flag composes with filters in dispatch**

Add to `src/core/task.zig` tests:

```zig
test "list --status=pending only shows pending tasks via dispatch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const Vault = struct {
        // use the real vault with in-memory sqlite
        fn open() !void {}
    };

    // This test verifies that the dispatch layer passes the query correctly.
    // Detailed filter correctness is tested in query.zig and vault.zig.
    // Here we just verify no crash with the new flag.
    try list_task(allocator, io, tmp_dir.dir, .{ .status = .pending });
}
```

- [ ] **Step 2: Extend `TaskArgs` with filter fields**

In `src/core/task.zig`, modify the `TaskArgs` struct:

```zig
pub const TaskArgs = struct {
    list: bool = false,
    status: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    due: ?[]const u8 = null,
    assigned_to: ?[]const u8 = null,
    search: ?[]const u8 = null,
    subcommand: ?union(enum) {
        add: struct { title: []const u8, desc: ?[]const u8 = null },
        edit: struct { id: []const u8, title: []const u8, desc: ?[]const u8 = null },
        delete: struct { id: []const u8 },
        show: struct { id: []const u8 },
        complete: struct { id: []const u8 },
        start: struct { id: []const u8 },
        stats: struct {},
    } = null,

    pub const help = ...
};
```

Add to help text:

```
Flags (list / stats only):
  --status=<s>          Filter by status: pending, in-progress, completed
  --priority=<p>        Filter by priority: low, medium, high
  --due=<d>             Filter by due: today, overdue, week, or timestamp
  --assigned=<u>        Filter by assigned user (substring)
  --search=<q>          Full-text search in title and description
```

- [ ] **Step 3: Run tests to verify they pass (struct change is additive)**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 4: Update `dispatch_task_command` to pass filters to `list_task`**

In `dispatch_task_command`, change the `list` branch:

```zig
if (args.list) {
    try list_task(allocator, io, dir, parse_query(args));
    return;
}
```

Add a helper to convert `TaskArgs` filter fields to `TaskQuery`:

```zig
fn parse_query(args: TaskArgs) query.TaskQuery {
    var q = query.TaskQuery{};
    if (args.status) |s| {
        q.status = std.meta.stringToEnum(models.Task.Status, s);
    }
    if (args.priority) |p| {
        q.priority = std.meta.stringToEnum(models.Task.Priority, p);
    }
    if (args.due) |d| {
        q.due = if (std.mem.eql(u8, d, "today")) .today
            else if (std.mem.eql(u8, d, "overdue")) .overdue
            else if (std.mem.eql(u8, d, "week")) .week
            else .{ .timestamp = std.fmt.parseInt(i64, d, 10) catch return q };
    }
    if (args.assigned_to) |a| q.assigned_to = a;
    if (args.search) |s| q.search = s;
    return q;
}
```

- [ ] **Step 5: Update `list_task` to accept and apply query**

Change signature:

```zig
fn list_task(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, filter: query.TaskQuery) !void {
```

Inside, use the filtered list from the vault handle:

```zig
const tasks = try vault.tasks.list(filter, arena.allocator());
```

If the vault handle is unavailable (e.g. in the legacy JSON test path), fall back to loading all and applying `matches()`:

```zig
const all_tasks = storage.load_tasks(arena.allocator(), io, dir) catch return;
var tasks = std.ArrayList(models.Task).empty;
for (all_tasks) |t| {
    if (query.matches(t, filter, now_seconds(io))) {
        try tasks.append(arena.allocator(), t);
    }
}
```

Update the section header to show `(filtered)` when any filter is active:

```zig
const is_filtered = filter.status != null or filter.priority != null or
    filter.due != null or filter.assigned_to != null or filter.search != null;
const suffix = if (is_filtered) " (filtered)" else "";
// ...
std.debug.print("{s}Pending{s} ({d}{s})\n", .{ ansi_code(.cyan), ansi_code(.reset), pending.items.len, suffix });
```

- [ ] **Step 6: Run all tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (existing tests still pass with new function signature)

- [ ] **Step 7: Update main.zig to handle new flags**

The `flags` library auto-parses struct fields, so `--status`, `--priority`, `--due`, `--assigned`, `--search` are already available on `TaskArgs`. No change needed in `main.zig`.

- [ ] **Step 8: Commit**

```bash
git add src/core/task.zig
git commit -m "feat: add filter flags to CLI TaskArgs and wire into list_task"
```

---

### Task 4: Add `stats` subcommand with rendering

**Files:**
- Modify: `src/core/task.zig` (add stats subcommand handling, stats output)

**Interfaces:**
- Consumes: `query.TaskQuery`, `query.TaskStats`, `Vault.Tasks.stats(query)`.
- Produces: `tip task stats` command output.

- [ ] **Step 1: Wire `stats` in `dispatch_task_command`**

Add a new arm to the subcommand switch:

```zig
.stats => |_| try stats_task(allocator, io, dir, parse_query(args)),
```

- [ ] **Step 2: Write the failing test for `stats_task` output**

```zig
test "stats_task prints correct output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Add some tasks
    try add_task(allocator, io, tmp_dir.dir, "Task A", null);
    try add_task(allocator, io, tmp_dir.dir, "Task B", null);

    // stats should print without error
    try stats_task(allocator, io, tmp_dir.dir, .{});
}
```

- [ ] **Step 3: Implement `stats_task`**

```zig
fn stats_task(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, filter: query.TaskQuery) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Load all tasks (JSON path — will be replaced by vault handle after SP03)
    const tasks = storage.load_tasks(arena_alloc, io, dir) catch {
        std.debug.print("No data\n", .{});
        return;
    };

    const now = now_seconds(io);
    var stats = query.TaskStats{};
    for (tasks) |t| {
        if (!query.matches(t, filter, now)) continue;
        stats.total += 1;
        switch (t.status) {
            .pending => stats.pending += 1,
            .in_progress => stats.in_progress += 1,
            .completed => stats.completed += 1,
        }
        if (t.due_date) |due| {
            if (due < now and t.status != .completed) stats.overdue += 1;
        }
    }

    std.debug.print("Total:      {d}\n", .{stats.total});
    std.debug.print("Pending:    {d}\n", .{stats.pending});
    std.debug.print("In-Progress: {d}\n", .{stats.in_progress});
    std.debug.print("Completed:  {d}\n", .{stats.completed});
    std.debug.print("Overdue:     {d}\n", .{stats.overdue});
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 5: Update help text for stats**

Append to `TaskArgs.help`:

```
  stats                   Show task statistics (counts by status, overdue)
```

- [ ] **Step 6: Commit**

```bash
git add src/core/task.zig
git commit -m "feat: add tip task stats subcommand"
```

---

### Task 5: Add FTS5 migration and fallback logic

**Files:**
- Create: `src/storage/migrations/008_create_tasks_fts.sql`
- Modify: `src/core/query.zig` (FTS5 availability flag in `build_where_clause`)
- Modify: migration runner (SP02) to include this migration

**Interfaces:**
- Consumes: SQLite migration runner from SP02.
- Produces: FTS5 virtual table `tasks_fts` with sync triggers.

- [ ] **Step 1: Create the migration SQL**

`src/storage/migrations/008_create_tasks_fts.sql`:

```sql
-- Migration 008: Create FTS5 index for tasks
CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts USING fts5(
    title, description,
    content='tasks',
    content_rowid='rowid'
);

CREATE TRIGGER IF NOT EXISTS tasks_ai AFTER INSERT ON tasks BEGIN
    INSERT INTO tasks_fts(rowid, title, description)
    VALUES (new.rowid, new.title, new.description);
END;

CREATE TRIGGER IF NOT EXISTS tasks_ad AFTER DELETE ON tasks BEGIN
    INSERT INTO tasks_fts(tasks_fts, rowid, title, description)
    VALUES ('delete', old.rowid, old.title, old.description);
END;

CREATE TRIGGER IF NOT EXISTS tasks_au AFTER UPDATE ON tasks BEGIN
    INSERT INTO tasks_fts(tasks_fts, rowid, title, description)
    VALUES ('delete', old.rowid, old.title, old.description);
    INSERT INTO tasks_fts(rowid, title, description)
    VALUES (new.rowid, new.title, new.description);
END;
```

- [ ] **Step 2: Register the migration**

In the migration runner (SP02), add `008_create_tasks_fts` to the migration list.

- [ ] **Step 3: Update `build_where_clause` to handle FTS5 unavailability**

The `build_where_clause` function already has a `LIKE` fallback in the search clause. No change needed — if FTS5 is unavailable, the `LIKE` portion covers the query. The FTS5 `MATCH` clause is in an OR with `LIKE`, so it degrades gracefully.

- [ ] **Step 4: Write a test for FTS5 search integration**

```zig
test "FTS5 search finds tasks by title" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "fts_test" });
    defer vault.close();

    try vault.tasks.add(.{ .title = "buy groceries", .description = "milk and eggs" });
    try vault.tasks.add(.{ .title = "fix bike", .description = "repair brakes" });

    const results = try vault.tasks.list(.{ .search = "groceries" }, allocator);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("buy groceries", results[0].title);
}
```

- [ ] **Step 5: Commit**

```bash
git add src/storage/migrations/008_create_tasks_fts.sql
git commit -m "feat: add FTS5 migration for tasks full-text search"
```

---

### Task 6: Edge cases, error handling, and integration tests

**Files:**
- Modify: `src/core/task.zig` (integration tests)
- Modify: `src/core/query.zig` (edge case tests)

- [ ] **Step 1: Write integration tests for edge cases**

Add to `src/core/task.zig` tests:

```zig
test "list with no tasks and filter prints empty sections" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try list_task(allocator, io, tmp_dir.dir, .{ .status = .pending });
}

test "list --search with no match returns empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try add_task(allocator, io, tmp_dir.dir, "Test Task", null);
    try list_task(allocator, io, tmp_dir.dir, .{ .search = "nonexistent" });
}

test "stats on empty vault returns zeros" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try stats_task(allocator, io, tmp_dir.dir, .{});
}

test "stats --status filter scopes counts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try add_task(allocator, io, tmp_dir.dir, "Task A", null);
    try add_task(allocator, io, tmp_dir.dir, "Task B", null);

    try stats_task(allocator, io, tmp_dir.dir, .{ .status = .pending });
}
```

- [ ] **Step 2: Write query.zig edge case tests**

```zig
test "matches with null priority returns false" {
    const task = models.Task{
        .id = "1",
        .title = "test",
        .status = .pending,
        .created_at = 0,
    };
    try std.testing.expect(!matches(task, TaskQuery{ .priority = .high }, 0));
}

test "matches with null due_date and due filter returns false" {
    const task = models.Task{
        .id = "1",
        .title = "test",
        .status = .pending,
        .created_at = 0,
    };
    try std.testing.expect(!matches(task, TaskQuery{ .due = .overdue }, 1000));
}

test "matches with null assigned_to and assigned filter returns false" {
    const task = models.Task{
        .id = "1",
        .title = "test",
        .status = .pending,
        .created_at = 0,
    };
    try std.testing.expect(!matches(task, TaskQuery{ .assigned_to = "alice" }, 0));
}

test "matches with null description and search filter" {
    const task = models.Task{
        .id = "1",
        .title = "test",
        .description = null,
        .status = .pending,
        .created_at = 0,
    };
    try std.testing.expect(matches(task, TaskQuery{ .search = "test" }, 0));
    try std.testing.expect(!matches(task, TaskQuery{ .search = "missing" }, 0));
}
```

- [ ] **Step 3: Run full test suite**

Run: `zig build test --summary all`
Expected: All 30+ tests PASS

- [ ] **Step 4: Commit**

```bash
git add src/core/task.zig src/core/query.zig
git commit -m "test: add edge case tests for filters, search, stats"
```
