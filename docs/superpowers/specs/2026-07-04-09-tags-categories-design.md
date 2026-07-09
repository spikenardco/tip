# Sub-project 09 — Tags & Categories (DESIGN)

> **Status:** DESIGN APPROVED
> **Date:** 2026-07-04
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 08 (Task filters/search/stats)
> **Successor:** _(none — custom fields cancelled)_

This sub-project adds tags (many-to-many on tasks) and categories (predefined list per
vault, single per task) to the task manager. Tags and categories share the same SQLite
migration and are designed as one unit. Custom fields were dropped from the roadmap.

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| 09-1 | **Categories are a predefined list per vault.** Users create categories with `tip category add`, then assign one per task. | LOCKED |
| 09-2 | **Tags are many-to-many** via a `task_tags` join table. A shared tag pool (per vault). | LOCKED |
| 09-3 | **`--tag` is a repeatable flag** (e.g. `--tag=urgent --tag=backend`), not comma-separated. | LOCKED |
| 09-4 | **Tag filter composes as AND** with other filters and with multiple tags (task must have ALL specified tags). Consistent with SP08. | LOCKED |
| 09-5 | **Category has no display colour hint.** Name only. Colour can be added later. | LOCKED |
| 09-6 | **Categories and tags get their own top-level commands** (`tip category`, `tip tag`) plus flags on `tip task`. | LOCKED |
| 09-7 | **Task list/show output** shows category as `[Name]` prefix and tags as `#tag1 #tag2` inline. | LOCKED |
| 09-8 | **Custom fields dropped from roadmap.** No key-value field support. | LOCKED |

---

## Part A — CLI Surface

### New `tip category` commands

```
tip category add --name=<name>
tip category list
tip category delete --id=<id>
```

### New `tip tag` commands

```
tip tag add --name=<name>
tip tag list
tip tag delete --id=<id>
```

### Extended `tip task add / edit`

```
tip task add --title=... [--category=<name>] [--tag=<t> ...]
tip task edit --id=<id> [--category=<name>] [--tag=<t> ...]
```

Omitting `--category` leaves the task uncategorised. Omitting `--tag` leaves existing tags unchanged (edit) or empty (add).

### Extended `tip task list` / `tip task stats`

```
tip task list [--category=<name>] [--tag=<t> ...]   [other SP08 flags]
tip task stats [--category=<name>] [--tag=<t> ...]   [other SP08 flags]
```

### Output format

**List:**
```
[Work] Buy groceries  #shopping #urgent
[Personal] Fix bike   #home
(No category) Review PR  #dev
```

**Show (detail):**
```
=== Task Details ===

ID:          abc12345
Title:       Buy groceries
Category:    Work
Tags:        shopping, urgent
Status:      ○ Pending
...
```

---

## Part B — Internal architecture

### New types in `models.zig`

```zig
pub const Category = struct {
    id: []const u8,
    name: []const u8,
    created_at: i64,
};

pub const Tag = struct {
    id: []const u8,
    name: []const u8,
};
```

### Updated `Task` struct

```zig
pub const Task = struct {
    id: []const u8,
    title: []const u8,
    description: ?[]const u8 = null,
    status: Status = .pending,
    priority: ?Priority = .low,
    category_id: ?[]const u8 = null,     // NEW
    due_date: ?i64 = null,
    assigned_to: ?[]const u8 = null,
    created_at: i64,
    updated_at: ?i64 = null,
    completed_at: ?i64 = null,
};
```

Tags are not a field on `Task` directly — they live in the join table and are loaded via a separate query (or a JOIN + collect in the handle layer).

### SQLite schema (migration)

```sql
CREATE TABLE categories (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL
);

CREATE TABLE tags (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE task_tags (
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (task_id, tag_id)
);
```

Plus: `ALTER TABLE tasks ADD COLUMN category_id TEXT REFERENCES categories(id);`

### SQL query integration (SP08 `build_where_clause`)

`TaskQuery` gains:

```zig
category: ?[]const u8 = null,    // category name (not ID)
tags: ?[]const []const u8 = null, // tag names — AND logic
```

SQL clauses:

| Query field | SQL |
|---|---|
| `category` | `category_id IN (SELECT id FROM categories WHERE name = ?)` |
| `tags` (AND) | `id IN (SELECT task_id FROM task_tags WHERE tag_id IN (SELECT id FROM tags WHERE name = ?) GROUP BY task_id HAVING COUNT(DISTINCT tag_id) = ?)` — repeated per tag, joined with AND |

For the `matches()` in-memory path: `category` matches by name, `tags` checks that every specified tag exists in the task's tag list.

### New handle layer methods

On the SP03 `Vault.Categories` / `Vault.Tags` handles:

```zig
pub fn add(self: *Categories, name: []const u8) !models.Category;
pub fn list(self: *Categories) ![]models.Category;
pub fn delete(self: *Categories, id: []const u8) !void;

pub fn add(self: *Tags, name: []const u8) !models.Tag;
pub fn list(self: *Tags) ![]models.Tag;
pub fn delete(self: *Tags, id: []const u8) !void;
```

On `Vault.Tasks` (extended):

```zig
// Existing methods unchanged
pub fn add(self: *Tasks, task: TaskArgs.AddArgs) !models.Task;
    // Accepts optional category_id and tags: ?[]const []const u8 (tag names)

pub fn list(self: *Tasks, query: TaskQuery, allocator: Allocator) ![]models.Task;
    // JOINs category name and collects tags per task

pub fn show(self: *Tasks, id: []const u8) !models.TaskDetail;
    // Returns task + resolved category name + tag list
```

### New modules

| Module | Responsibility |
|---|---|
| `src/core/category.zig` | Category struct, CLI args, dispatch (`category_add`, `category_list`, `category_delete`), Vault.Categories handle integration |
| `src/core/tag.zig` | Tag struct, CLI args, dispatch (`tag_add`, `tag_list`, `tag_delete`), Vault.Tags handle integration |

---

## Part C — Out of scope

- **Custom fields on tasks** — dropped from roadmap.
- **Bulk tag operations** (rename, merge, re-tag all) — deferred.
- **Category/Tag colours and icons** — deferred.
- **Nested categories** — flat list only.
- **Tag autocomplete / suggest** — deferred.
- **Import/export of categories and tags** — belongs in the SP07 export format update.

---

## Part D — Testing

- Unit tests for category CRUD (add, list, delete, duplicate name error)
- Unit tests for tag CRUD (add, list, delete, duplicate name error)
- Integration test: create category, add task with category, assert category appears in list/show
- Integration test: create tags, add task with multiple tags, assert tags appear in list/show
- Integration test: `--category` filter on list returns only tasks in that category
- Integration test: `--tag` filter (single and multiple, AND logic)
- Integration test: edit task category/tags
- Integration test: delete category — tasks become uncategorised (FK set null)
- Integration test: delete tag — removed from all tasks (CASCADE)
- Edge cases: no category (null), empty tag set, duplicate tag names, unknown category name
