# Sub-project 09 — Tags & Categories Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add tags (many-to-many via join table) and categories (predefined list per vault, single per task) to the task manager.

**Architecture:** New `src/core/category.zig` and `src/core/tag.zig` modules define the types, CLI dispatch, and vault handle integration. `models.zig` gets `Category` and `Tag` types; `Task` gains a `category_id` FK. The `TaskQuery` builder (SP08) gains `category` and `tags` filter fields. A SQLite migration creates `categories`, `tags`, and `task_tags` tables.

**Tech Stack:** Zig 0.16 (`std.Io` async model), `zqlite`, `flags` dependency, SQLite.

**Dependency:** This plan requires **sub-projects 01–08 to be implemented first** — it relies on the `Vault` handle from SP03, `Vault.Tasks` from SP03/SP04, vaults from SP06, config from SP05, SQLite migration runner from SP02, error taxonomy from SP01, and `TaskQuery`/`build_where_clause` from SP08.

---

## Global Constraints

- **Zig version:** 0.16.0 (`minimum_zig_version = "0.16.0"`). Use the new `std.Io` APIs.
- **Identifier casing:** functions/vars/fields = `snake_case`; types = `PascalCase`; enum members = `snake_case`.
- **Error taxonomy (sub-project 01):** `CategoryNotFound`, `TagNotFound`, `DuplicateCategoryName`, `DuplicateTagName`, `InvalidCategoryName`, `InvalidTagName`, `TaskNotFound`, `StorageFailure`. Commands return errors; `main.zig` renders via `errors.describe`/`errors.exit_code`.
- **Exit codes:** `0` ok · `1` internal · `2` usage · `3` not found · `4` validation.
- **Vault handle (SP03):** `Vault.open(allocator, io, .{ .name = name })` → `Vault`, `vault.tasks` → `Tasks` handle, `vault.categories` → `Categories` handle, `vault.tags` → `Tags` handle.
- **zqlite API:** `zqlite.open(path, flags)` for connections, `conn.exec(sql, params)` (2 args), `conn.row(sql, params)` returns `?Row`, `conn.rows(sql, params)` returns `Rows`. Column access: `row.int(0)`, `row.text(1)`, etc.
- **Tests:** `zig build test --summary all` from repo root. Tests use in-memory SQLite.
- **Tags filter composes as AND with other filters.** Multiple `--tag` flags narrow the result (task must have ALL specified tags).
- **Categories are flat** (no nesting). Name must be unique per vault.
- **Tags are global per vault** (shared pool). Name must be unique per vault.
- **Out of scope:** Custom fields (dropped from roadmap), bulk tag operations, tag autocomplete, category/tag colours, nested categories.

---

### Task 1: Extend `models.zig` with `Category` and `Tag` types, update `Task`

**Files:**
- Modify: `src/core/models.zig`

**Interfaces:**
- Consumes: existing `Task` struct.
- Produces:
  - `pub const Category = struct { id: []const u8, name: []const u8, created_at: i64 }`
  - `pub const Tag = struct { id: []const u8, name: []const u8 }`
  - `category_id: ?[]const u8` field added to `Task`

- [ ] **Step 1: Write the failing tests for new types**

Append to `src/core/models.zig`:

```zig
test "Category struct fields" {
    const c = Category{ .id = "cat1", .name = "Work", .created_at = 100 };
    try std.testing.expectEqualStrings("cat1", c.id);
    try std.testing.expectEqualStrings("Work", c.name);
    try std.testing.expectEqual(@as(i64, 100), c.created_at);
}

test "Tag struct fields" {
    const t = Tag{ .id = "tag1", .name = "urgent" };
    try std.testing.expectEqualStrings("tag1", t.id);
    try std.testing.expectEqualStrings("urgent", t.name);
}

test "Task category_id defaults to null" {
    const task = Task{
        .id = "1",
        .title = "test",
        .created_at = 0,
    };
    try std.testing.expect(task.category_id == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `Category`, `Tag` not defined, `category_id` missing

- [ ] **Step 3: Add the type definitions and `category_id` field**

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

Add `category_id: ?[]const u8 = null` to the `Task` struct.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (3 new tests)

- [ ] **Step 5: Commit**

```bash
git add src/core/models.zig
git commit -m "feat: add Category, Tag types and category_id field to Task"
```

---

### Task 2: Create `src/core/category.zig` with CRUD + CLI dispatch

**Files:**
- Create: `src/core/category.zig`

**Interfaces:**
- Consumes: `models.Category`, `Vault.Categories` handle, `generate.generate_id`, `flags` CLI parsing.
- Produces:
  - `pub const CategoryArgs = struct { subcommand: union(enum) { add: struct { name: []const u8 }, list: struct {}, delete: struct { id: []const u8 } } }`
  - `pub fn dispatch_category_command(io: std.Io, args: CategoryArgs) void`
  - `fn add_category(allocator: std.mem.Allocator, io: std.Io, vault: *Vault, name: []const u8) !models.Category`
  - `fn list_categories(allocator: std.mem.Allocator, vault: *Vault) ![]models.Category`
  - `fn delete_category(vault: *Vault, id: []const u8) !void`

- [ ] **Step 1: Write the failing tests for category CLI dispatch**

```zig
const std = @import("std");
const models = @import("models.zig");

test "dispatch_category_command add creates category" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    const cat = try add_category(allocator, io, &vault, "Work");
    try std.testing.expectEqualStrings("Work", cat.name);
}

test "add_category rejects duplicate name" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    _ = try add_category(allocator, io, &vault, "Work");
    try std.testing.expectError(error.DuplicateCategoryName, add_category(allocator, io, &vault, "Work"));
}

test "list_categories returns all categories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    _ = try add_category(allocator, io, &vault, "Work");
    _ = try add_category(allocator, io, &vault, "Personal");

    const cats = try list_categories(allocator, &vault);
    defer allocator.free(cats);
    try std.testing.expectEqual(@as(usize, 2), cats.len);
}

test "delete_category removes category" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    const cat = try add_category(allocator, io, &vault, "Work");
    try delete_category(&vault, cat.id);

    const cats = try list_categories(allocator, &vault);
    defer allocator.free(cats);
    try std.testing.expectEqual(@as(usize, 0), cats.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `Vault.open` not available, functions not defined

- [ ] **Step 3: Implement CategoryArgs, dispatch, add_category, list_categories, delete_category**

```zig
const std = @import("std");
const models = @import("models.zig");
const Vault = @import("vault.zig").Vault;
const generate = @import("../utils/generate.zig");

pub const CategoryArgs = struct {
    subcommand: union(enum) {
        add: struct { name: []const u8 },
        list: struct {},
        delete: struct { id: []const u8 },
    },

    pub const help =
        \\Usage:
        \\  tip category <subcommand> [args]
        \\
        \\Commands:
        \\  add --name=<name>         Create a new category
        \\  list                      List all categories
        \\  delete --id=<id>          Delete a category
        \\
        \\Examples:
        \\  tip category add --name=Work
        \\  tip category list
        \\
    ;
};

pub fn dispatch_category_command(io: std.Io, args: CategoryArgs) void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var vault = Vault.open(allocator, io, .{ .name = "default" }) catch {
        std.debug.print("Failed to open vault\n", .{});
        return;
    };
    defer vault.close();

    switch (args.subcommand) {
        .add => |a| {
            const cat = add_category(allocator, io, &vault, a.name) catch |err| switch (err) {
                error.DuplicateCategoryName => {
                    std.debug.print("Category '{s}' already exists\n", .{a.name});
                    return;
                },
                else => {
                    std.debug.print("Failed to add category\n", .{});
                    return;
                },
            };
            std.debug.print("Category added: {s} ({s})\n", .{ cat.name, cat.id });
        },
        .list => {
            const cats = list_categories(allocator, &vault) catch {
                std.debug.print("Failed to list categories\n", .{});
                return;
            };
            defer allocator.free(cats);
            if (cats.len == 0) {
                std.debug.print("No categories\n", .{});
                return;
            }
            for (cats) |cat| {
                std.debug.print("  {s}\n", .{cat.name});
            }
        },
        .delete => |del| {
            delete_category(&vault, del.id) catch |err| switch (err) {
                error.CategoryNotFound => {
                    std.debug.print("Category not found: {s}\n", .{del.id});
                    return;
                },
                else => {
                    std.debug.print("Failed to delete category\n", .{});
                    return;
                },
            };
            std.debug.print("Category deleted\n", .{});
        },
    }
}

fn add_category(allocator: std.mem.Allocator, io: std.Io, vault: *Vault, name: []const u8) !models.Category {
    if (name.len == 0) return error.InvalidCategoryName;
    // Check for duplicate via vault handle
    const existing = try vault.categories.list();
    defer allocator.free(existing);
    for (existing) |cat| {
        if (std.mem.eql(u8, cat.name, name)) return error.DuplicateCategoryName;
    }

    const id = try generate.generate_id(allocator, io);
    defer allocator.free(id);

    const category = models.Category{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .created_at = std.Io.Timestamp.now(io, .real).toSeconds(),
    };

    try vault.categories.add(category);
    return category;
}

fn list_categories(allocator: std.mem.Allocator, vault: *Vault) ![]models.Category {
    return try vault.categories.list(allocator);
}

fn delete_category(vault: *Vault, id: []const u8) !void {
    try vault.categories.delete(id);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/category.zig
git commit -m "feat: add category CRUD and CLI dispatch"
```

---

### Task 3: Create `src/core/tag.zig` with CRUD + CLI dispatch

**Files:**
- Create: `src/core/tag.zig`

**Interfaces:**
- Consumes: `models.Tag`, `Vault.Tags` handle, `generate.generate_id`, `flags` CLI parsing.
- Produces:
  - `pub const TagArgs = struct { subcommand: union(enum) { add: struct { name: []const u8 }, list: struct {}, delete: struct { id: []const u8 } } }`
  - `pub fn dispatch_tag_command(io: std.Io, args: TagArgs) void`
  - `fn add_tag(allocator: std.mem.Allocator, io: std.Io, vault: *Vault, name: []const u8) !models.Tag`
  - `fn list_tags(allocator: std.mem.Allocator, vault: *Vault) ![]models.Tag`
  - `fn delete_tag(vault: *Vault, id: []const u8) !void`

- [ ] **Step 1: Write the failing tests for tag CLI dispatch**

```zig
const std = @import("std");
const models = @import("models.zig");

test "dispatch_tag_command add creates tag" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    const tag = try add_tag(allocator, io, &vault, "urgent");
    try std.testing.expectEqualStrings("urgent", tag.name);
}

test "add_tag rejects duplicate name" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    _ = try add_tag(allocator, io, &vault, "urgent");
    try std.testing.expectError(error.DuplicateTagName, add_tag(allocator, io, &vault, "urgent"));
}

test "list_tags returns all tags" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    _ = try add_tag(allocator, io, &vault, "urgent");
    _ = try add_tag(allocator, io, &vault, "backend");

    const tags = try list_tags(allocator, &vault);
    defer allocator.free(tags);
    try std.testing.expectEqual(@as(usize, 2), tags.len);
}

test "delete_tag removes tag" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    const tag = try add_tag(allocator, io, &vault, "urgent");
    try delete_tag(&vault, tag.id);

    const tags = try list_tags(allocator, &vault);
    defer allocator.free(tags);
    try std.testing.expectEqual(@as(usize, 0), tags.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — functions not defined

- [ ] **Step 3: Implement TagArgs, dispatch, add_tag, list_tags, delete_tag**

```zig
const std = @import("std");
const models = @import("models.zig");
const Vault = @import("vault.zig").Vault;
const generate = @import("../utils/generate.zig");

pub const TagArgs = struct {
    subcommand: union(enum) {
        add: struct { name: []const u8 },
        list: struct {},
        delete: struct { id: []const u8 },
    },

    pub const help =
        \\Usage:
        \\  tip tag <subcommand> [args]
        \\
        \\Commands:
        \\  add --name=<name>         Create a new tag
        \\  list                      List all tags
        \\  delete --id=<id>          Delete a tag
        \\
        \\Examples:
        \\  tip tag add --name=urgent
        \\  tip tag list
        \\
    ;
};

pub fn dispatch_tag_command(io: std.Io, args: TagArgs) void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var vault = Vault.open(allocator, io, .{ .name = "default" }) catch {
        std.debug.print("Failed to open vault\n", .{});
        return;
    };
    defer vault.close();

    switch (args.subcommand) {
        .add => |a| {
            const tag = add_tag(allocator, io, &vault, a.name) catch |err| switch (err) {
                error.DuplicateTagName => {
                    std.debug.print("Tag '{s}' already exists\n", .{a.name});
                    return;
                },
                else => {
                    std.debug.print("Failed to add tag\n", .{});
                    return;
                },
            };
            std.debug.print("Tag added: {s} ({s})\n", .{ tag.name, tag.id });
        },
        .list => {
            const tags = list_tags(allocator, &vault) catch {
                std.debug.print("Failed to list tags\n", .{});
                return;
            };
            defer allocator.free(tags);
            if (tags.len == 0) {
                std.debug.print("No tags\n", .{});
                return;
            }
            for (tags) |tag| {
                std.debug.print("  {s}\n", .{tag.name});
            }
        },
        .delete => |del| {
            delete_tag(&vault, del.id) catch |err| switch (err) {
                error.TagNotFound => {
                    std.debug.print("Tag not found: {s}\n", .{del.id});
                    return;
                },
                else => {
                    std.debug.print("Failed to delete tag\n", .{});
                    return;
                },
            };
            std.debug.print("Tag deleted\n", .{});
        },
    }
}

fn add_tag(allocator: std.mem.Allocator, io: std.Io, vault: *Vault, name: []const u8) !models.Tag {
    if (name.len == 0) return error.InvalidTagName;
    const existing = try vault.tags.list();
    defer allocator.free(existing);
    for (existing) |tag| {
        if (std.mem.eql(u8, tag.name, name)) return error.DuplicateTagName;
    }

    const id = try generate.generate_id(allocator, io);
    defer allocator.free(id);

    const tag = models.Tag{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
    };

    try vault.tags.add(tag);
    return tag;
}

fn list_tags(allocator: std.mem.Allocator, vault: *Vault) ![]models.Tag {
    return try vault.tags.list(allocator);
}

fn delete_tag(vault: *Vault, id: []const u8) !void {
    try vault.tags.delete(id);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/tag.zig
git commit -m "feat: add tag CRUD and CLI dispatch"
```

---

### Task 4: Extend `TaskQuery` and `build_where_clause` for category/tag filters

**Files:**
- Modify: `src/core/query.zig`

**Interfaces:**
- Consumes: `models.Category`, `models.Tag`, existing `TaskQuery`, `build_where_clause`, `matches()`.
- Produces:
  - `category: ?[]const u8` and `tags: ?[]const []const u8` added to `TaskQuery`
  - Updated `build_where_clause` with category/tag SQL clauses
  - Updated `matches()` with category/tag predicates

- [ ] **Step 1: Write failing tests for category/tag query fields**

```zig
test "TaskQuery category and tags default to null" {
    const q = TaskQuery{};
    try std.testing.expect(q.category == null);
    try std.testing.expect(q.tags == null);
}

test "build_where_clause with category filter" {
    const q = TaskQuery{ .category = "Work" };
    const wc = build_where_clause(q, std.testing.allocator, 0);
    try std.testing.expect(std.mem.indexOf(u8, wc.sql, "categories.name") != null);
    try std.testing.expectEqual(@as(usize, 1), wc.params.len);
}

test "build_where_clause with single tag filter" {
    const q = TaskQuery{ .tags = &.{"urgent"} };
    const wc = build_where_clause(q, std.testing.allocator, 0);
    try std.testing.expect(std.mem.indexOf(u8, wc.sql, "task_tags") != null);
}

test "build_where_clause with multiple tags (AND)" {
    const q = TaskQuery{ .tags = &.{"urgent", "backend"} };
    const wc = build_where_clause(q, std.testing.allocator, 0);
    try std.testing.expect(std.mem.indexOf(u8, wc.sql, "GROUP BY") != null);
    try std.testing.expect(std.mem.indexOf(u8, wc.sql, "HAVING") != null);
}

test "build_where_clause composes category and tags with other filters" {
    const q = TaskQuery{ .category = "Work", .tags = &.{"urgent"}, .status = .pending };
    const wc = build_where_clause(q, std.testing.allocator, 0);
    // Should have multiple AND clauses
    try std.testing.expect(std.mem.indexOf(u8, wc.sql, "AND") != null);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test --summary all`
Expected: FAIL — `category`/`tags` fields missing from `TaskQuery`

- [ ] **Step 3: Add `category` and `tags` fields to `TaskQuery`**

```zig
pub const TaskQuery = struct {
    status: ?models.Task.Status = null,
    priority: ?models.Task.Priority = null,
    due: ?DueFilter = null,
    assigned_to: ?[]const u8 = null,
    search: ?[]const u8 = null,
    category: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
};
```

- [ ] **Step 4: Update `build_where_clause` with category/tag clauses**

Add before the return statement in `build_where_clause`:

```zig
if (q.category) |cat| {
    if (clauses.items.len > 0) clauses.appendSlice(" AND ") catch {};
    clauses.appendSlice("category_id IN (SELECT id FROM categories WHERE name = ?)") catch {};
    params.append(allocator, .{ .string = cat }) catch {};
}

if (q.tags) |tags| {
    if (tags.len > 0) {
        if (clauses.items.len > 0) clauses.appendSlice(" AND ") catch {};
        // AND logic: task must have ALL specified tags
        clauses.appendSlice("id IN (SELECT task_id FROM task_tags WHERE tag_id IN (SELECT id FROM tags WHERE name = ?) GROUP BY task_id HAVING COUNT(DISTINCT tag_id) = ?)") catch {};
        for (tags) |t| {
            params.append(allocator, .{ .string = t }) catch {};
        }
        // Add the count parameter for HAVING
        params.append(allocator, .{ .i64 = @as(i64, @intCast(tags.len)) }) catch {};
    }
}
```

**Important:** The `tags` SQL clause above generates a single `?` placeholder for all tag names via the `IN (SELECT ... WHERE name = ?)` subquery. Since the `flags` library passes `[]const []const u8` as individual params, we need one `?` per tag. Replace the clause with repeated `?` placeholders when building the SQL string. The step implementer should loop over `tags` to create `name = ? OR name = ?` inside the subquery or use a single comma-separated approach compatible with zqlite's bind param system.

Implementation approach — build the tag-name placeholders dynamically:

```zig
if (q.tags) |tags| {
    if (tags.len > 0) {
        if (clauses.items.len > 0) try clauses.appendSlice(" AND ");
        try clauses.appendSlice("id IN (SELECT task_id FROM task_tags tt ");
        try clauses.appendSlice("JOIN tags t ON tt.tag_id = t.id WHERE ");
        for (tags, 0..) |tag, i| {
            if (i > 0) try clauses.appendSlice(" OR ");
            try clauses.appendSlice("t.name = ?");
            try params.append(.{ .string = tag });
        }
        try clauses.appendSlice(" GROUP BY tt.task_id HAVING COUNT(DISTINCT tt.tag_id) = ?");
        try params.append(.{ .i64 = @intCast(tags.len) });
        try clauses.appendSlice(")");
    }
}
```

- [ ] **Step 5: Update `matches()` with category/tag predicates**

Add before the `return true` in `matches()`:

```zig
if (query.category) |cat| {
    // In-memory path: category match by comparing category_id → name
    // This requires the caller to resolve category names, or we match by ID.
    // For the in-memory path, we assume category is already resolved to an ID
    // or we do a simple check. Here we match by ID only if the category param
    // looks like an ID. In practice the SQL path is preferred.
    // For simplicity, if category is provided, compare directly.
    // Since we don't have the category map here, we skip in-memory check
    // and defer to the SQL path. In tests using JSON storage, this falls
    // through and the SQL path handles it.
}

if (query.tags) |tags| {
    if (tags.len > 0) {
        // In-memory path: task.tags must contain ALL specified tags
        const task_tags = task.tags orelse return false;
        for (tags) |t| {
            var found = false;
            for (task_tags) |tt| {
                if (std.mem.eql(u8, tt, t)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 7: Add `tags` field to the Task struct for in-memory path**

The `matches()` function needs a tags field on `Task`. Add to `models.zig`:

```zig
tags: ?[]const []const u8 = null,
```

Update the existing `Task` struct in `models.zig` to include this field.

- [ ] **Step 8: Commit**

```bash
git add src/core/query.zig src/core/models.zig
git commit -m "feat: add category and tag filter support to TaskQuery"
```

---

### Task 5: Extend task CLI — add `--category`, `--tag` flags and show category/tags in output

**Files:**
- Modify: `src/core/task.zig`

**Interfaces:**
- Consumes: `TaskArgs` (existing), `models.Task`, `models.Category`, `models.Tag`, `Vault.Tasks` with tag/category support.
- Produces:
  - `category: ?[]const u8` and `tag: ?[]const []const u8` added to `TaskArgs`
  - Updated `add_task` to accept category and tags
  - Updated `edit_task` to accept category and tags
  - Updated `list_task` to show category/tags in output
  - Updated `show_task` to show category/tags in detail

- [ ] **Step 1: Write failing tests for new TaskArgs fields**

```zig
test "TaskArgs category and tag fields default to null" {
    const args = TaskArgs{};
    try std.testing.expect(args.category == null);
    try std.testing.expect(args.tag == null);
}

test "add_task with category assigns category_id" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    // Create a category
    const cat = try vault.categories.add("Work");

    // Add task with category name
    const task = try vault.tasks.add(.{
        .title = "Test Task",
        .category = "Work",
    });
    try std.testing.expectEqualStrings(cat.id, task.category_id.?);
}

test "add_task with tags creates task_tags entries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    _ = try vault.tags.add("urgent");
    _ = try vault.tags.add("backend");

    const task = try vault.tasks.add(.{
        .title = "Test Task",
        .tags = &.{"urgent", "backend"},
    });
    // Verify tags were attached
    const tags = try vault.tasks.get_tags(task.id, allocator);
    defer allocator.free(tags);
    try std.testing.expectEqual(@as(usize, 2), tags.len);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test --summary all`
Expected: FAIL — `category`/`tag` not on TaskArgs

- [ ] **Step 3: Extend `TaskArgs` with `--category` and `--tag`**

```zig
pub const TaskArgs = struct {
    list: bool = false,
    status: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    due: ?[]const u8 = null,
    assigned_to: ?[]const u8 = null,
    search: ?[]const u8 = null,
    category: ?[]const u8 = null,
    tag: ?[]const []const u8 = null,
    subcommand: ?union(enum) {
        add: struct {
            title: []const u8,
            desc: ?[]const u8 = null,
            category: ?[]const u8 = null,
            tag: ?[]const []const u8 = null,
        },
        edit: struct {
            id: []const u8,
            title: ?[]const u8 = null,
            desc: ?[]const u8 = null,
            category: ?[]const u8 = null,
            tag: ?[]const []const u8 = null,
        },
        delete: struct { id: []const u8 },
        show: struct { id: []const u8 },
        complete: struct { id: []const u8 },
        start: struct { id: []const u8 },
        stats: struct {},
    } = null,
    // ...
};
```

Add to help text:

```
  --category=<name>     Category name (list/stats filter or add/edit assignment)
  --tag=<name>          Tag name (repeatable; list/stats filter or add/edit assignment)
```

- [ ] **Step 4: Update `parse_query` to include `--category` and `--tag`**

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
    if (args.category) |c| q.category = c;
    if (args.tag) |t| q.tags = t;
    return q;
}
```

- [ ] **Step 5: Update `list_task` output to show category and tags**

In `list_task`, after loading tasks, resolve category names and tag lists. Modify the task display to show:

```
[Category] title  #tag1 #tag2
```

When a task has no category, show nothing (not `[No category]`). When a task has no tags, show nothing.

```zig
// Resolve category names for display
const category_names = resolve_category_names(arena_alloc, vault, tasks) catch blk: {
    break :blk std.AutoHashMap([]const u8, []const u8).empty;
};
```

Update `print_task` to accept category name and tag list:

```zig
fn print_task(task: models.Task, category_name: ?[]const u8, tag_names: ?[]const []const u8, detailed: bool) !void {
    if (detailed) {
        // existing detail output, add:
        if (category_name) |cn| {
            std.debug.print("Category:    {s}\n", .{cn});
        } else {
            std.debug.print("Category:    -\n", .{});
        }
        if (tag_names) |tns| {
            std.debug.print("Tags:        ", .{});
            for (tns, 0..) |tn, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{tn});
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("Tags:        -\n", .{});
        }
    } else {
        // compact output
        if (category_name) |cn| {
            std.debug.print("{s}[{s}]{s} ", .{ ansi_code(.yellow), cn, ansi_code(.reset) });
        }
        std.debug.print("{s}{s}{s} ", .{ ansi_code(status_color(task.status)), status_icon(task.status), ansi_code(.reset) });
        // ... existing title output ...
        if (tag_names) |tns| {
            for (tns) |tn| {
                std.debug.print(" {s}#{s}{s}", .{ ansi_code(.cyan), tn, ansi_code(.reset) });
            }
        }
        std.debug.print("\n", .{});
    }
}
```

- [ ] **Step 6: Update `dispatch_task_command` to pass --category and --tag to add/edit**

In the `add` subcommand handler, pass `a.category` and `a.tag` to `add_task`. In the `edit` handler, pass `e.category` and `e.tag`.

```zig
.add => |a| add_task(allocator, io, dir, a.title, a.desc, a.category, a.tag) catch {
    std.debug.print("Failed to add task\n", .{});
    return;
},
```

- [ ] **Step 7: Implement `add_task` and `edit_task` with category/tag support**

In `add_task`, after creating the task, resolve category name to ID and insert task_tags:

```zig
// If category specified, resolve name → ID
if (category_name) |cn| {
    const categories = vault.categories.list(arena_alloc) catch {
        std.debug.print("Warning: could not load categories\n", .{});
        return;
    };
    for (categories) |cat| {
        if (std.mem.eql(u8, cat.name, cn)) {
            task.category_id = try arena_alloc.dupe(u8, cat.id);
            break;
        }
    }
}

// If tags specified, resolve names → IDs and insert into task_tags
if (tag_names) |tns| {
    const all_tags = vault.tags.list(arena_alloc) catch {
        std.debug.print("Warning: could not load tags\n", .{});
        return;
    };
    for (tns) |tn| {
        for (all_tags) |t| {
            if (std.mem.eql(u8, t.name, tn)) {
                try vault.tasks.add_tag(task.id, t.id);
                break;
            }
        }
    }
}
```

- [ ] **Step 8: Run all tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add src/core/task.zig
git commit -m "feat: add --category and --tag flags to task CLI, show in output"
```

---

### Task 6: Update `main.zig` to register category and tag commands

**Files:**
- Modify: `src/main.zig`

**Interfaces:**
- Consumes: `category.CategoryArgs`, `category.dispatch_category_command`, `tag.TagArgs`, `tag.dispatch_tag_command`.
- Produces: `tip category` and `tip tag` commands available at top level.

- [ ] **Step 1: Write a failing test for the new commands**

```zig
test "main accepts category and tag commands" {
    // Smoke test: verify the command enum compiles with new variants
    const args = Args{ .category = .{ .subcommand = .list = .{} } };
    _ = args;
    const args2 = Args{ .tag = .{ .subcommand = .list = .{} } };
    _ = args2;
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `category`/`tag` not in `Args`

- [ ] **Step 3: Update `Args` in `main.zig`**

```zig
const Args = struct {
    command: union(enum) {
        task: task.TaskArgs,
        category: category.CategoryArgs,
        tag: tag.TagArgs,
    },
    // help text unchanged...
};
```

Add to help text:

```
  category              Category management (add, list, delete)
  tag                   Tag management (add, list, delete)
```

- [ ] **Step 4: Update main dispatch**

```zig
switch (parsed.command) {
    .task => |t| task.dispatch_task_command(init.io, init.minimal.environ, t),
    .category => |c| category.dispatch_category_command(init.io, c),
    .tag => |t| tag.dispatch_tag_command(init.io, t),
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/main.zig
git commit -m "feat: register tip category and tip tag top-level commands"
```

---

### Task 7: Add SQLite migration for categories, tags, and task_tags tables

**Files:**
- Create: `src/storage/migrations/009_create_categories_tags.sql`
- Modify: migration runner (SP02) to include this migration

- [ ] **Step 1: Create the migration SQL**

`src/storage/migrations/009_create_categories_tags.sql`:

```sql
-- Migration 009: Create categories, tags, and task_tags tables

CREATE TABLE IF NOT EXISTS categories (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tags (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS task_tags (
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (task_id, tag_id)
);
```

- [ ] **Step 2: Register the migration**

In the migration runner (SP02), add `009_create_categories_tags` to the migration list after the FTS5 migration (008).

- [ ] **Step 3: Add the `category_id` column to existing tasks**

Add a second SQL file or append to the same migration:

```sql
-- Add category_id to tasks if not present
ALTER TABLE tasks ADD COLUMN category_id TEXT REFERENCES categories(id);
```

Wrap in `ALTER TABLE ... ADD COLUMN` with `IF NOT EXISTS` — SQLite does not support `IF NOT EXISTS` for `ALTER TABLE ADD COLUMN`. Instead, the migration runner should catch the "duplicate column" error and ignore it, or use a separate migration step that checks the table schema first.

- [ ] **Step 4: Write a test for the migration**

```zig
test "migration 009 creates tables and supports CRUD" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    // Verify categories table works
    const cat = try vault.categories.add("Work");
    try std.testing.expectEqualStrings("Work", cat.name);

    // Verify tags table works
    const tag = try vault.tags.add("urgent");
    try std.testing.expectEqualStrings("urgent", tag.name);

    // Verify task_tags join works
    const task = try vault.tasks.add(.{ .title = "Test", .category = "Work", .tags = &.{"urgent"} });
    const tags = try vault.tasks.get_tags(task.id, allocator);
    defer allocator.free(tags);
    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqualStrings("urgent", tags[0].name);
}
```

- [ ] **Step 5: Commit**

```bash
git add src/storage/migrations/009_create_categories_tags.sql
git commit -m "feat: add migration 009 for categories, tags, and task_tags"
```

---

### Task 8: Edge cases, error handling, and integration tests

**Files:**
- Modify: `src/core/category.zig` (edge case tests)
- Modify: `src/core/tag.zig` (edge case tests)
- Modify: `src/core/task.zig` (integration tests)

- [ ] **Step 1: Write category edge case tests**

```zig
test "add_category with empty name returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try std.testing.expectError(error.InvalidCategoryName, add_category(allocator, io, &vault, ""));
}

test "delete_category nonexistent returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try std.testing.expectError(error.CategoryNotFound, delete_category(&vault, "nonexistent"));
}

test "delete_category sets tasks category_id to null" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    const cat = try vault.categories.add("Work");
    const task = try vault.tasks.add(.{ .title = "Test", .category = "Work" });
    try std.testing.expectEqualStrings(cat.id, task.category_id.?);

    try vault.categories.delete(cat.id);

    const reloaded = try vault.tasks.show(task.id);
    try std.testing.expect(reloaded.category_id == null);
}
```

- [ ] **Step 2: Write tag edge case tests**

```zig
test "add_tag with empty name returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try std.testing.expectError(error.InvalidTagName, add_tag(allocator, io, &vault, ""));
}

test "delete_tag nonexistent returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try std.testing.expectError(error.TagNotFound, delete_tag(&vault, "nonexistent"));
}

test "delete_tag removes task_tags entries (CASCADE)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    const tag = try vault.tags.add("urgent");
    const task = try vault.tasks.add(.{ .title = "Test", .tags = &.{"urgent"} });

    try vault.tags.delete(tag.id);

    // Verify task no longer has tags
    const tags = try vault.tasks.get_tags(task.id, allocator);
    defer allocator.free(tags);
    try std.testing.expectEqual(@as(usize, 0), tags.len);
}

test "add task with nonexistent category name falls through silently" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    const task = try vault.tasks.add(.{ .title = "Test", .category = "DoesNotExist" });
    try std.testing.expect(task.category_id == null);
}
```

- [ ] **Step 3: Write integration tests for task list with category/tag filters**

```zig
test "list with --category filter returns only tasks in that category" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    _ = try vault.categories.add("Work");
    _ = try vault.categories.add("Personal");

    _ = try vault.tasks.add(.{ .title = "Task A", .category = "Work" });
    _ = try vault.tasks.add(.{ .title = "Task B", .category = "Personal" });
    _ = try vault.tasks.add(.{ .title = "Task C", .category = "Work" });

    const results = try vault.tasks.list(.{ .category = "Work" }, allocator);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "list with --tag filter returns only tasks with that tag" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    _ = try vault.tags.add("urgent");
    _ = try vault.tags.add("backend");

    _ = try vault.tasks.add(.{ .title = "Task A", .tags = &.{"urgent"} });
    _ = try vault.tasks.add(.{ .title = "Task B", .tags = &.{"backend"} });
    _ = try vault.tasks.add(.{ .title = "Task C", .tags = &.{"urgent", "backend"} });

    const results = try vault.tasks.list(.{ .tags = &.{"urgent"} }, allocator);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "list with multiple --tag filters (AND) requires all tags" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    _ = try vault.tags.add("urgent");
    _ = try vault.tags.add("backend");
    _ = try vault.tags.add("frontend");

    _ = try vault.tasks.add(.{ .title = "Task A", .tags = &.{"urgent", "backend"} });
    _ = try vault.tasks.add(.{ .title = "Task B", .tags = &.{"urgent"} });
    _ = try vault.tasks.add(.{ .title = "Task C", .tags = &.{"urgent", "backend", "frontend"} });

    const results = try vault.tasks.list(.{ .tags = &.{"urgent", "backend"} }, allocator);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "show task displays category name and tags" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    _ = try vault.categories.add("Work");
    _ = try vault.tags.add("urgent");
    _ = try vault.tags.add("backend");

    const task = try vault.tasks.add(.{ .title = "Test", .category = "Work", .tags = &.{"urgent", "backend"} });

    // show_task prints — verify it runs without error
    try show_task(allocator, io, task.id, vault);
}

test "edit task changes category" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    _ = try vault.categories.add("Work");
    _ = try vault.categories.add("Personal");

    const task = try vault.tasks.add(.{ .title = "Test", .category = "Work" });
    try std.testing.expect(task.category_id != null);

    const updated = try vault.tasks.edit(.{ .id = task.id, .category = "Personal" });
    // Reload to verify
    const reloaded = try vault.tasks.show(task.id);
    // Category should now be Personal
    const cat_name = try vault.categories.resolve_name(reloaded.category_id.?);
    try std.testing.expectEqualStrings("Personal", cat_name);
}
```

- [ ] **Step 4: Run full test suite**

Run: `zig build test --summary all`
Expected: All 50+ tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/category.zig src/core/tag.zig src/core/task.zig
git commit -m "test: add edge case and integration tests for tags and categories"
```
