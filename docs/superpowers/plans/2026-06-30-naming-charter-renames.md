# Naming Charter Renames Implementation Plan

> **Status:** COMPLETE (Tasks 0–5). Task 6 pending (draft spec checkbox update).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the sub-project 00 naming charter (D6–D10) to the existing task code as pure renames, changing zero behavior.

**Architecture:** These are mechanical identifier renames across `src/core/task.zig`, `src/main.zig`, and one CLI flag. There is no new logic. The existing 11-test suite is the regression guard: it must stay green (11/11) after every task.

**Tech Stack:** Zig 0.16, `flags` dependency, `zig build test` test runner.

## Global Constraints

- Zig version is **0.16.0** (`minimum_zig_version = "0.16.0"` in build.zig.zon). Do not use pre-0.16 APIs.
- **No behavior changes.** Every task is a rename only. Output, control flow, and data stay identical.
- Naming rules come from the charter in `docs/superpowers/specs/2026-06-30-tip-redesign-draft.md` §6: functions/vars/fields snake_case, types PascalCase, value constants snake_case, affirmative boolean prefixes in code only (CLI flags exempt).
- The full test command is `zig build test --summary all`. Baseline is **11/11 passing**; it must remain 11/11 after each task.
- The `generate.uuid()` rename is **deliberately out of scope** here. Its final name depends on the ID strategy decided in sub-project 01. Do not touch `src/utils/generate.zig` in this plan.
- The CLI-facing `list: bool` field on `TaskArgs` is **exempt** from the boolean prefix rule (D8), so it is not renamed.

---

### Task 0: Establish the green baseline

**Files:**
- None (verification only)

- [x] **Step 1: Run the full suite to confirm the starting state**

Run: `zig build test --summary all`
Expected: PASS, 11/11 tests passing. If it is not green here, stop and report before making any rename.

---

### Task 1: Rename `Color` enum to `Ansi` and `color()` to `ansi_code()`

The enum holds ANSI escape choices (including `reset`, which is not a color), and the function returns an ANSI escape string, not a `Color`. Rename both together since every call site touches both.

**Files:**
- Modify: `src/core/task.zig` (enum decl, function decl, return types, all call sites)

**Interfaces:**
- Produces: `const Ansi = enum {...}`, `fn ansi_code(c: Ansi) []const u8`. `fn priority_color(...) Ansi` and `fn status_color(...) Ansi` now return `Ansi`.

- [x] **Step 1: Rename the enum declaration**

In `src/core/task.zig`, change:

```zig
const Color = enum {
    red,
    green,
    yellow,
    cyan,
    reset,
};
```

to:

```zig
const Ansi = enum {
    red,
    green,
    yellow,
    cyan,
    reset,
};
```

- [x] **Step 2: Rename the function and its parameter type**

Change:

```zig
fn color(c: Color) []const u8 {
    return switch (c) {
```

to:

```zig
fn ansi_code(c: Ansi) []const u8 {
    return switch (c) {
```

- [x] **Step 3: Update the two return types that reference the enum**

Change `fn priority_color(priority: ?models.Task.Priority) Color {` to `fn priority_color(priority: ?models.Task.Priority) Ansi {`.

Change `fn status_color(status: models.Task.Status) Color {` to `fn status_color(status: models.Task.Status) Ansi {`.

- [x] **Step 4: Update every `color(...)` call site**

Replace all remaining calls to `color(` with `ansi_code(` in `src/core/task.zig`. These are on lines around 223, 231, 239, 248, 252, 262, 265, 302, 309, 315, 317, 323, 327. For example `color(.cyan)` becomes `ansi_code(.cyan)`, and `color(c_status)` becomes `ansi_code(c_status)`.

Verify none remain:

Run: `rg -n "\bColor\b|\bcolor\(" src/core/task.zig`
Expected: no matches.

- [x] **Step 5: Run the suite to confirm it still passes**

Run: `zig build test --summary all`
Expected: PASS, 11/11.

- [x] **Step 6: Commit**

```bash
git add src/core/task.zig
git commit -m "refactor: rename Color enum to Ansi and color() to ansi_code()"
```

---

### Task 2: Rename `priority_label()` to `priority_glyph()`

It returns a glyph (`↑ / - / ↓`), not a label. This mirrors the existing `status_icon`.

**Files:**
- Modify: `src/core/task.zig` (function decl + 2 call sites)

**Interfaces:**
- Produces: `fn priority_glyph(priority: ?models.Task.Priority) []const u8`.

- [x] **Step 1: Rename the function declaration**

Change:

```zig
fn priority_label(priority: ?models.Task.Priority) []const u8 {
```

to:

```zig
fn priority_glyph(priority: ?models.Task.Priority) []const u8 {
```

- [x] **Step 2: Update both call sites**

Line ~265: change `priority_label(p)` to `priority_glyph(p)`.
Line ~304: change `priority_label(p)` to `priority_glyph(p)`.

Verify none remain:

Run: `rg -n "priority_label" src/core/task.zig`
Expected: no matches.

- [x] **Step 3: Run the suite**

Run: `zig build test --summary all`
Expected: PASS, 11/11.

- [x] **Step 4: Commit**

```bash
git add src/core/task.zig
git commit -m "refactor: rename priority_label() to priority_glyph()"
```

---

### Task 3: Rename `unix_timestamp()` to `now_seconds()`

Shorter and clearer for a function that returns the current time in seconds.

**Files:**
- Modify: `src/core/task.zig` (function decl + all call sites)

**Interfaces:**
- Produces: `fn now_seconds(io: std.Io) i64`.

- [x] **Step 1: Rename the function declaration**

Change:

```zig
fn unix_timestamp(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}
```

to:

```zig
fn now_seconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}
```

- [x] **Step 2: Update every call site**

Replace all `unix_timestamp(io)` with `now_seconds(io)` in `src/core/task.zig`. These are on lines around 185, 271, 313, 344, 345, 378.

Verify none remain:

Run: `rg -n "unix_timestamp" src/core/task.zig`
Expected: no matches.

- [x] **Step 3: Run the suite**

Run: `zig build test --summary all`
Expected: PASS, 11/11.

- [x] **Step 4: Commit**

```bash
git add src/core/task.zig
git commit -m "refactor: rename unix_timestamp() to now_seconds()"
```

---

### Task 4: Rename `execute_commands()` to `dispatch_task_command()` and param `T` to `args`

The function dispatches one command, so the plural verb is misleading. The parameter `T` reads like a type parameter but is a value.

**Files:**
- Modify: `src/core/task.zig` (function decl + uses of `T` inside it)
- Modify: `src/main.zig` (call site)

**Interfaces:**
- Consumes: `main.zig` calls this function.
- Produces: `pub fn dispatch_task_command(io: std.Io, environ: std.process.Environ, args: TaskArgs) void`.

- [x] **Step 1: Rename the function declaration and parameter**

In `src/core/task.zig`, change:

```zig
pub fn execute_commands(io: std.Io, environ: std.process.Environ, T: TaskArgs) void {
```

to:

```zig
pub fn dispatch_task_command(io: std.Io, environ: std.process.Environ, args: TaskArgs) void {
```

- [x] **Step 2: Update uses of `T` inside the function body**

Change `if (T.list) {` to `if (args.list) {`.
Change `if (T.subcommand) |subcommand| {` to `if (args.subcommand) |subcommand| {`.

Verify no stray `T.` uses remain in the function:

Run: `rg -n "\bT\." src/core/task.zig`
Expected: no matches.

- [x] **Step 3: Update the call site in main.zig**

In `src/main.zig`, change:

```zig
        .task => |t| task.execute_commands(init.io, init.minimal.environ, t),
```

to:

```zig
        .task => |t| task.dispatch_task_command(init.io, init.minimal.environ, t),
```

- [x] **Step 4: Run the suite**

Run: `zig build test --summary all`
Expected: PASS, 11/11.

- [x] **Step 5: Commit**

```bash
git add src/core/task.zig src/main.zig
git commit -m "refactor: rename execute_commands() to dispatch_task_command() and param T to args"
```

---

### Task 5: Rename the `task add --name` flag to `--title`

The model field is `title`, and `task edit` already uses `--title`. This makes the flag consistent across add and edit (D10).

**Files:**
- Modify: `src/core/task.zig` (the `add` variant of the `TaskArgs.subcommand` union, its dispatch use, and the help text)

**Interfaces:**
- Produces: `TaskArgs.subcommand.add` field is now `title: []const u8` (was `name`).

- [x] **Step 1: Rename the field in the `add` union variant**

In `src/core/task.zig`, change:

```zig
        add: struct {
            name: []const u8,
            desc: ?[]const u8 = null,
        },
```

to:

```zig
        add: struct {
            title: []const u8,
            desc: ?[]const u8 = null,
        },
```

- [x] **Step 2: Update the dispatch use of the field**

Change:

```zig
            .add => |add| add_task(allocator, io, dir, add.name, add.desc) catch {
```

to:

```zig
            .add => |add| add_task(allocator, io, dir, add.title, add.desc) catch {
```

- [x] **Step 3: Update the help text**

In the `TaskArgs.help` block, change the add line:

```
        \\      --name=<name>              Add new task
```

to:

```
        \\      --title=<title>            Add new task
```

And change the example:

```
        \\  tip task add --name="Review code"
```

to:

```
        \\  tip task add --title="Review code"
```

- [x] **Step 4: Confirm no `name` flag references remain**

Run: `rg -n "add.name|--name|name=" src/core/task.zig`
Expected: no matches.

- [x] **Step 5: Run the suite**

Run: `zig build test --summary all`
Expected: PASS, 11/11. (The tests call `add_task` directly and are unaffected by the flag rename, so they confirm nothing else broke.)

- [x] **Step 6: Manually confirm the new flag works end to end**

Run: `zig build run -- task add --title="Review code"`
Expected: prints `Adding task: Review code` with no parse error.

- [x] **Step 7: Commit**

```bash
git add src/core/task.zig
git commit -m "refactor: rename task add --name flag to --title"
```

---

### Task 6: Mark sub-project 00 done in the draft

Record that the renames are applied so the working draft stays accurate.

**Files:**
- Modify: `docs/superpowers/specs/2026-06-30-tip-redesign-draft.md` (§6 deliverables checkbox)

- [ ] **Step 1: Check off the last 00 deliverable**

In §6, change:

```
- [ ] Write a checkbox implementation plan for the renames above (next, via writing-plans).
```

to:

```
- [x] Write and execute the rename plan (`docs/superpowers/plans/2026-06-30-naming-charter-renames.md`).
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-06-30-tip-redesign-draft.md
git commit -m "docs: mark sub-project 00 rename plan complete"
```

---

## Deferred (not in this plan)

- `generate.uuid()` rename: decided in sub-project 01 (ID strategy), since the final name depends on whether we pick ULID, UUIDv7, or SQLite rowid.
- `src/utils/README.md` references a Go-style `GenerateUUID()`; leave it until the ID strategy lands, then rewrite that doc alongside the id rename.
