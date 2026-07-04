# Output Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ANSI-colored ad-hoc `print_task` with generic table renderer (list) and key-value renderer (detail). Add `--sort` and `--borders` flags. Provide `format_timestamp` for epoch conversion.

**Architecture:** New `src/output/` module with three focused files (table, detail, time) plus barrel `src/output.zig`. Existing `src/core/task.zig` stripped of ANSI and reworked to call these renderers.

**Tech Stack:** Zig 0.16.0, flags parser

## Global Constraints

- ANSI escape codes removed from all output
- Status icons (`○`, `⟳`, `✓`) and priority glyphs (`↑`, `-`, `↓`) kept as plain-text
- `--sort` default: `-created` (newest first)
- `--borders` default: `false`
- Timestamps: UTC date only (`YYYY-MM-DD`), relative mode reserved as TODO

---
### File structure

```
src/
  output/
    table.zig      — Column, Options, render_table
    detail.zig     — Field, render_detail
    time.zig       — format_timestamp
  output.zig       — barrel (re-exports table, detail, time)
  core/
    task.zig       — stripped of ANSI, uses output/, adds --sort/--borders
```

---

### Task 1: `src/output/time.zig` — timestamp formatter

**Files:**
- Create: `src/output/time.zig`

**Interfaces:**
- Produces: `pub const TimeFormat = enum { iso_8601, relative, raw }`
- Produces: `pub fn format_timestamp(epoch_s: i64, fmt: TimeFormat, alloc: std.mem.Allocator) ![]const u8`

- [ ] **Step 1: Write `src/output/time.zig`**

```zig
const std = @import("std");

pub const TimeFormat = enum {
    iso_8601,
    /// TODO: relative — "2h ago", "yesterday", "3d ago"
    relative,
    raw,
};

pub fn format_timestamp(epoch_s: i64, fmt: TimeFormat, alloc: std.mem.Allocator) ![]const u8 {
    return switch (fmt) {
        .iso_8601 => blk: {
            const epoch_day = std.time.epoch.epochSecondsToEpochDay(@as(u64, @intCast(epoch_s)));
            const day = std.time.epoch.EpochDay{ .day = epoch_day };
            const ymd = day.calculateYearDay();
            break :blk try std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}", .{
                ymd.year, ymd.month(), ymd.monthDay(),
            });
        },
        .relative => try alloc.dupe(u8, "TODO"),
        .raw => try std.fmt.allocPrint(alloc, "{d}", .{epoch_s}),
    };
}

test "format_timestamp iso_8601 dawn of epoch" {
    const result = try format_timestamp(0, .iso_8601, std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1970-01-01", result);
}

test "format_timestamp raw" {
    const result = try format_timestamp(1749043200, .raw, std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1749043200", result);
}

test "format_timestamp relative is TODO placeholder" {
    const result = try format_timestamp(0, .relative, std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("TODO", result);
}
```

- [ ] **Step 2: Run tests**

```bash
zig build test 2>&1 | tail -10
```
Expected: all 3 `time.zig` tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/output/time.zig
git commit -m "feat(output): add format_timestamp with iso_8601 and raw modes"
```

---

### Task 2: `src/output/table.zig` — generic table renderer

**Files:**
- Create: `src/output/table.zig`

**Interfaces:**
- Produces: `pub const Column = struct { header: []const u8, width: usize = 0 }`
- Produces: `pub const Options = struct { borders: bool = false }`
- Produces: `pub fn render_table(columns: []const Column, rows: []const []const []const u8, options: Options) void`

- [ ] **Step 1: Write `src/output/table.zig`**

```zig
const std = @import("std");

pub const Column = struct {
    header: []const u8,
    width: usize = 0,
};

pub const Options = struct {
    borders: bool = false,
};

/// Render a table of pre-formatted cell strings to stdout.
/// `rows` is row-major: rows[row][col].
/// Every row must have exactly `columns.len` cells.
pub fn render_table(
    columns: []const Column,
    rows: []const []const []const u8,
    options: Options,
) void {
    if (columns.len == 0) return;

    // Compute column widths from headers + cell content
    var widths: [32]usize = undefined;
    for (columns, 0..) |col, i| {
        widths[i] = if (col.width > 0) col.width else col.header.len;
    }
    for (rows) |row| {
        for (row, 0..) |cell, ci| {
            if (ci < columns.len and cell.len > widths[ci]) {
                widths[ci] = cell.len;
            }
        }
    }

    const sep = if (options.borders) " │ " else "  ";

    // Header row
    for (columns, 0..) |col, i| {
        if (i > 0) std.debug.print("{s}", .{sep});
        std.debug.print("{s: <{w}}", .{ col.header, widths[i] });
    }
    std.debug.print("\n", .{});

    // Underline row
    for (0..columns.len) |i| {
        if (i > 0) std.debug.print("{s}", .{sep});
        std.debug.print("{s:─<{w}}", .{ "", widths[i] });
    }
    std.debug.print("\n", .{});

    // Data rows
    for (rows) |row| {
        for (row, 0..) |cell, ci| {
            if (ci > 0) std.debug.print("{s}", .{sep});
            std.debug.print("{s: <{w}}", .{ cell, widths[ci] });
        }
        std.debug.print("\n", .{});
    }
}

test "render_table empty columns prints nothing" {
    render_table(&.{}, &.{}, .{});
}

test "render_table basic" {
    const columns = [_]Column{
        .{ .header = "Name" },
        .{ .header = "Age" },
    };
    const rows = [_][]const []const u8{
        &[_][]const u8{ "Alice", "30" },
        &[_][]const u8{ "Bob", "25" },
    };
    render_table(&columns, &rows, .{});
}

test "render_table with borders" {
    const columns = [_]Column{
        .{ .header = "Name" },
        .{ .header = "Age" },
    };
    const rows = [_][]const []const u8{
        &[_][]const u8{ "Alice", "30" },
    };
    render_table(&columns, &rows, .{ .borders = true });
}
```

- [ ] **Step 2: Run tests**

```bash
zig build test 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add src/output/table.zig
git commit -m "feat(output): add generic table renderer"
```

---

### Task 3: `src/output/detail.zig` — key-value detail renderer

**Files:**
- Create: `src/output/detail.zig`

**Interfaces:**
- Produces: `pub const Field = struct { label: []const u8, value: []const u8 }`
- Produces: `pub fn render_detail(fields: []const Field) void`

- [ ] **Step 1: Write `src/output/detail.zig`**

```zig
const std = @import("std");

pub const Field = struct {
    label: []const u8,
    value: []const u8,
};

/// Render label-value pairs with right-aligned labels, 2-space indent, `: ` separator.
pub fn render_detail(fields: []const Field) void {
    if (fields.len == 0) return;

    var max_label: usize = 0;
    for (fields) |f| {
        if (f.label.len > max_label) max_label = f.label.len;
    }

    for (fields) |f| {
        std.debug.print("  {s:<{w}}  {s}\n", .{ f.label ++ ":", max_label + 1, f.value });
    }
}

test "render_detail empty prints nothing" {
    render_detail(&.{});
}

test "render_detail basic" {
    const fields = [_]Field{
        .{ .label = "ID", .value = "abc123" },
        .{ .label = "Title", .value = "Buy groceries" },
    };
    render_detail(&fields);
}
```

- [ ] **Step 2: Run tests**

```bash
zig build test 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add src/output/detail.zig
git commit -m "feat(output): add key-value detail renderer"
```

---

### Task 4: `src/output.zig` — barrel file

**Files:**
- Create: `src/output.zig`

- [ ] **Step 1: Write `src/output.zig`**

```zig
pub const table = @import("output/table.zig");
pub const detail = @import("output/detail.zig");
pub const time = @import("output/time.zig");
```

- [ ] **Step 2: Verify compilation**

```bash
zig build test 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add src/output.zig
git commit -m "feat(output): add barrel module for @import('output')"
```

---

### Task 5: Rewrite `src/core/task.zig` — strip ANSI, wire output module, add sort/borders

**Files:**
- Modify: `src/core/task.zig`

**Interfaces:**
- Consumes: `out.table.render_table`, `out.detail.render_detail`, `out.time.format_timestamp`
- Consumes: `flags` parser for new `sort` and `borders` fields
- Modifies: `TaskArgs` struct, `list_task`, `show_task`, `print_task`
- Removes: `Ansi` enum, `ansi_code`, `priority_color`, `status_color`

- [ ] **Step 1: Add `out` import**

Insert after existing imports:
```zig
const out = @import("output");
```

- [ ] **Step 2: Remove ANSI types and helpers**

Delete `Ansi` enum (lines ~6-12), `ansi_code()` (lines ~14-22), `priority_color()` (lines ~35-44), `status_color()` (lines ~54-60).

Keep `priority_glyph()` and `status_icon()` unchanged.

- [ ] **Step 3: Add sort types before `TaskArgs`**

```zig
const SortField = enum {
    created,
    due,
    priority,
    title,
    status,
    updated,
    completed,
};

const SortKey = struct {
    field: SortField,
    direction: enum { asc, desc },
};
```

- [ ] **Step 4: Add `sort` and `borders` to `TaskArgs`**

```zig
sort: []const []const u8 = &.{"-created"},
borders: bool = false,
```

Update the `pub const help` to document both flags:

```zig
pub const help =
    \\Usage:
    \\  tip task <subcommand> [args] [flags]
    \\
    \\Options:
    \\  --list                    List all tasks
    \\  --sort=<field>            Sort by: created, due, priority, title, status
    \\                            (prefix with - for desc, comma for multi-key)
    \\  --borders                 Show column separators in table
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
    \\  tip task --list --sort=due --borders
    \\  tip task add --title="Review code"
    \\
;
```

- [ ] **Step 5: Add sort helper functions**

```zig
fn parse_sort_keys(raw: []const []const u8, alloc: std.mem.Allocator) ![]SortKey {
    var keys = std.ArrayList(SortKey).empty;
    errdefer keys.deinit(alloc);

    for (raw) |part| {
        var it = std.mem.splitScalar(u8, part, ',');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;
            const descending = segment[0] == '-';
            const field_name = if (descending) segment[1..] else segment;
            const field = std.meta.stringToEnum(SortField, field_name) orelse return error.InvalidSortField;
            try keys.append(alloc, .{
                .field = field,
                .direction = if (descending) .desc else .asc,
            });
        }
    }
    return keys.items;
}

fn sort_tasks(tasks: []models.Task, keys: []const SortKey) void {
    if (keys.len == 0) return;

    std.sort.block(models.Task, tasks, SortContext{ .keys = keys }, SortContext.lessThan);
}

const SortContext = struct {
    keys: []const SortKey,

    fn lessThan(ctx: @This(), a: models.Task, b: models.Task) bool {
        for (ctx.keys) |k| {
            const cmp = switch (k.field) {
                .created => std.math.order(a.created_at, b.created_at),
                .due => std.math.order(
                    a.due_date orelse std.math.maxInt(i64),
                    b.due_date orelse std.math.maxInt(i64),
                ),
                .priority => blk: {
                    const pa: u2 = if (a.priority) |p| switch (p) { .high => 2, .medium => 1, .low => 0 } else 0;
                    const pb: u2 = if (b.priority) |p| switch (p) { .high => 2, .medium => 1, .low => 0 } else 0;
                    break :blk std.math.order(pa, pb);
                },
                .title => std.mem.order(u8, a.title, b.title),
                .status => blk: {
                    const sa: u2 = switch (a.status) { .pending => 0, .in_progress => 1, .completed => 2 };
                    const sb: u2 = switch (b.status) { .pending => 0, .in_progress => 1, .completed => 2 };
                    break :blk std.math.order(sa, sb);
                },
                .updated => std.math.order(
                    a.updated_at orelse std.math.maxInt(i64),
                    b.updated_at orelse std.math.maxInt(i64),
                ),
                .completed => std.math.order(
                    a.completed_at orelse std.math.maxInt(i64),
                    b.completed_at orelse std.math.maxInt(i64),
                ),
            };
            if (cmp != .eq) {
                return if (k.direction == .asc) cmp == .lt else cmp == .gt;
            }
        }
        return false;
    }
};
```

- [ ] **Step 6: Update `dispatch_task_command` signature and calls**

The function already takes `args: TaskArgs`. Update calls to pass sort/borders:

Replace `if (args.list) { list_task(allocator, io, dir) catch {}; return; }` with:
```zig
if (args.list) {
    list_task(allocator, io, dir, args.sort, args.borders) catch {};
    return;
}
```

- [ ] **Step 7: Rewrite `list_task`**

Replace the body of `list_task`:

```zig
fn list_task(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sort_raw: []const []const u8, borders: bool) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const tasks = storage.load_tasks(arena_alloc, io, dir) catch return;
    if (tasks.len == 0) {
        std.debug.print("No tasks\n", .{});
        return;
    }

    // Sort
    const sort_keys = try parse_sort_keys(sort_raw, arena_alloc);
    sort_tasks(tasks, sort_keys);

    // Define columns
    const columns = [_]out.table.Column{
        .{ .header = "ID", .width = 8 },
        .{ .header = "St", .width = 2 },
        .{ .header = "Title" },
        .{ .header = "Due" },
    };

    // Format rows
    var rows = std.ArrayList([]const []const u8).empty;
    defer rows.deinit(arena_alloc);

    for (tasks) |t| {
        const id_str = if (t.id.len > 8) t.id[0..8] else t.id;
        const status_str = status_icon(t.status);
        const due_str = if (t.due_date) |d|
            out.time.format_timestamp(d, .iso_8601, arena_alloc) catch ""
        else
            "";
        try rows.append(arena_alloc, &.{ id_str, status_str, t.title, due_str });
    }

    out.table.render_table(&columns, rows.items, .{ .borders = borders });
}
```

- [ ] **Step 8: Rewrite `show_task` to use detail renderer**

```zig
fn show_task(allocator: std.mem.Allocator, io: std.Io, task_id: []const u8, dir: std.Io.Dir) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const tasks = storage.load_tasks(arena_alloc, io, dir) catch return error.InvalidItem;

    var found: ?models.Task = null;
    for (tasks) |t| {
        const match = if (task_id.len >= 4 and t.id.len >= task_id.len)
            std.mem.eql(u8, t.id[0..task_id.len], task_id)
        else
            std.mem.eql(u8, t.id, task_id);
        if (match) {
            if (found != null) {
                std.debug.print("Multiple tasks match '{s}'. Use a longer ID.\n", .{task_id});
                return error.AmbiguousMatch;
            }
            found = t;
        }
    }

    const t = found orelse {
        std.debug.print("No task found matching '{s}'\n", .{task_id});
        return error.InvalidItem;
    };

    var fields = std.ArrayList(out.detail.Field).empty;
    defer fields.deinit(arena_alloc);

    try fields.append(arena_alloc, .{ .label = "ID", .value = t.id });
    try fields.append(arena_alloc, .{ .label = "Title", .value = t.title });

    if (t.description) |d| {
        try fields.append(arena_alloc, .{ .label = "Description", .value = d });
    }

    try fields.append(arena_alloc, .{ .label = "Status", .value = status_icon(t.status) });

    if (t.priority) |p| {
        try fields.append(arena_alloc, .{ .label = "Priority", .value = priority_glyph(p) });
    }

    if (t.due_date) |due| {
        const due_str = try out.time.format_timestamp(due, .iso_8601, arena_alloc);
        try fields.append(arena_alloc, .{ .label = "Due", .value = due_str });
    }

    if (t.assigned_to) |a| {
        try fields.append(arena_alloc, .{ .label = "Assigned To", .value = a });
    }

    const created_str = try out.time.format_timestamp(t.created_at, .iso_8601, arena_alloc);
    try fields.append(arena_alloc, .{ .label = "Created", .value = created_str });

    if (t.updated_at) |u| {
        const updated_str = try out.time.format_timestamp(u, .iso_8601, arena_alloc);
        try fields.append(arena_alloc, .{ .label = "Updated", .value = updated_str });
    }

    if (t.completed_at) |c| {
        const completed_str = try out.time.format_timestamp(c, .iso_8601, arena_alloc);
        try fields.append(arena_alloc, .{ .label = "Completed", .value = completed_str });
    }

    out.detail.render_detail(fields.items);
}
```

- [ ] **Step 9: Remove or slim `print_task`**

Since `print_task` is no longer used by `list_task` or `show_task`, remove it entirely.

- [ ] **Step 10: Run tests**

```bash
zig build test 2>&1 | tail -20
```
Expected: all tests pass. Some existing tests that called `print_task` indirectly may fail — fix them in Task 6.

- [ ] **Step 11: Commit**

```bash
git add src/core/task.zig
git commit -m "feat(task): strip ANSI, add table renderer, --sort, --borders"
```

---

### Task 6: Update tests

**Files:**
- Modify: `src/core/task.zig` (tests at bottom)

- [ ] **Step 1: Verify all existing tests still compile and pass**

```bash
zig build test 2>&1 | tail -20
```

Fix any test that relied on ANSI output or the old `list_task` signature.

**Tests that may need fixes:**
- `test "list task with no file"` — calls `list_task` which now takes sort+borders. Update call.
- Any test that depended on old `print_task` formatting — may need to be removed or updated.

- [ ] **Step 2: Add sort tests**

Append to the test section:
```zig
test "sort tasks by title ascending" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try add_task(allocator, io, tmp_dir.dir, "Zebra", null);
    try add_task(allocator, io, tmp_dir.dir, "Alpha", null);
    try add_task(allocator, io, tmp_dir.dir, "Beta", null);

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const tasks = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
        const sort_keys = try parse_sort_keys(&.{"title"}, arena.allocator());
        sort_tasks(tasks, sort_keys);
        try std.testing.expectEqualStrings("Alpha", tasks[0].title);
        try std.testing.expectEqualStrings("Beta", tasks[1].title);
        try std.testing.expectEqualStrings("Zebra", tasks[2].title);
    }
}

test "sort tasks by created descending (default)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try add_task(allocator, io, tmp_dir.dir, "First", null);
    try add_task(allocator, io, tmp_dir.dir, "Second", null);

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const tasks = try storage.load_tasks(arena.allocator(), io, tmp_dir.dir);
        const sort_keys = try parse_sort_keys(&.{"-created"}, arena.allocator());
        sort_tasks(tasks, sort_keys);
        // Second was added later, so it should come first in desc order
        try std.testing.expectEqualStrings("Second", tasks[0].title);
        try std.testing.expectEqualStrings("First", tasks[1].title);
    }
}
```

- [ ] **Step 3: Run all tests**

```bash
zig build test 2>&1 | tail -20
```
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/core/task.zig
git commit -m "test(task): add sort tests and fix existing test signatures"
```
