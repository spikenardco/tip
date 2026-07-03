# Sub-project 01 — ID Strategy + Error Taxonomy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fake-UUID id generator with real ULIDs, and replace scattered ad-hoc errors + silent `catch {}` swallowing with a domain-grouped error taxonomy rendered by a single central handler.

**Architecture:** `generate_id` becomes a ULID encoder (48-bit ms timestamp + 80-bit CSPRNG randomness → 26-char Crockford base32). A new `src/core/errors.zig` owns domain-grouped error sets plus `describe`/`exit_code`. Task command functions return typed errors instead of printing; `dispatch_task_command` returns `!void`; `main.zig` catches, renders one line to stderr, and exits with a semantic code.

**Tech Stack:** Zig 0.16 (`std.Io` async model), `flags` dependency, JSON storage (SQLite arrives in sub-projects 02/03).

## Global Constraints

- **Zig version:** 0.16.0 (`minimum_zig_version = "0.16.0"`). Use the new `std.Io` APIs, not the old `std.fs.cwd()` / `ArrayList.init` forms.
- **Identifier casing:** functions/vars/fields = `snake_case`; types = `PascalCase`; enum members = `snake_case`; error sets + members = `PascalCase`.
- **No new dependencies.** Randomness comes from `std.crypto.random`; timestamp from `std.Io.Timestamp`.
- **ID format:** ULID, 26-char uppercase Crockford base32, alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ` (no I, L, O, U).
- **Exit codes:** `0` ok · `1` internal/unexpected · `2` usage/bad args · `3` not found · `4` validation/conflict.
- **Tests:** run the whole suite with `zig build test --summary all` from the repo root (`/home/ben/Desktop/tip`). The `build.zig` auto-test-runner globs `src/**/*.zig`, so tests in new files are picked up automatically — no build.zig changes needed.
- **Out of scope (do NOT touch):** unified prefix-matcher + rich ambiguity listing (sub-project 04), `complete`/`start` subcommand wiring (04), SQLite + storage error surface (02/03), `--verbose` detail plumbing (05), `Diagnostic` context struct (04). `edit_task`'s first-match-wins behavior stays as-is this sub-project.

---

### Task 1: ULID id generator

Replace the timestamp+random hex concat in `generate_id` with a real ULID encoder. Signature stays `generate_id(allocator, io) ![]u8` so callers are unaffected; it now returns a 26-byte slice.

**Files:**
- Modify: `src/utils/generate.zig` (full rewrite of the file body)
- Test: `src/utils/generate.zig` (tests live in the same file)

**Interfaces:**
- Consumes: `std.Io.Timestamp.now(io, .real).toMilliseconds()`, `std.crypto.random.bytes`.
- Produces: `pub fn generate_id(allocator: std.mem.Allocator, io: std.Io) ![]u8` returning a 26-char ULID string owned by `allocator` (caller frees). Internal `fn encode_ulid(ts_ms: u64, rand: [10]u8, out: *[26]u8) void`.

- [ ] **Step 1: Write the failing tests**

Append to `src/utils/generate.zig`:

```zig
test "encode_ulid all zero" {
    var out: [26]u8 = undefined;
    encode_ulid(0, [_]u8{0} ** 10, &out);
    try std.testing.expectEqualStrings("00000000000000000000000000", &out);
}

test "encode_ulid timestamp one sets tenth char" {
    var out: [26]u8 = undefined;
    encode_ulid(1, [_]u8{0} ** 10, &out);
    try std.testing.expectEqualStrings("00000000010000000000000000", &out);
}

test "encode_ulid low randomness bit sets last char" {
    var out: [26]u8 = undefined;
    var rand = [_]u8{0} ** 10;
    rand[9] = 1;
    encode_ulid(0, rand, &out);
    try std.testing.expectEqualStrings("00000000000000000000000001", &out);
}

test "generate_id length alphabet and uniqueness" {
    const a = try generate_id(std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(a);
    const b = try generate_id(std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqual(@as(usize, 26), a.len);
    const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    for (a) |c| try std.testing.expect(std.mem.indexOfScalar(u8, alphabet, c) != null);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test --summary all`
Expected: compile error / failure — `encode_ulid` is not defined yet.

- [ ] **Step 3: Rewrite the implementation**

Replace the entire contents of `src/utils/generate.zig` with (keep the tests you added in Step 1 at the bottom):

```zig
const std = @import("std");

const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Encodes a ULID: 48-bit millisecond timestamp (first 10 chars) plus
/// 80 bits of randomness (last 16 chars) into 26 Crockford base32 chars.
fn encode_ulid(ts_ms: u64, rand: [10]u8, out: *[26]u8) void {
    // Timestamp: low 48 bits -> chars [0..10), most significant first.
    var t: u64 = ts_ms & 0xFFFF_FFFF_FFFF;
    var i: usize = 10;
    while (i > 0) {
        i -= 1;
        out[i] = alphabet[@intCast(t & 0x1F)];
        t >>= 5;
    }

    // Randomness: 80 bits -> chars [10..26), most significant first.
    var r: u128 = 0;
    for (rand) |b| r = (r << 8) | b;
    var j: usize = 26;
    while (j > 10) {
        j -= 1;
        out[j] = alphabet[@intCast(r & 0x1F)];
        r >>= 5;
    }
}

/// Generates a new ULID as a 26-char Crockford base32 string.
/// The returned slice is owned by `allocator`; the caller must free it.
pub fn generate_id(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts_ms: u64 = @intCast(std.Io.Timestamp.now(io, .real).toMilliseconds());

    var rand: [10]u8 = undefined;
    std.crypto.random.bytes(&rand);

    const buf = try allocator.alloc(u8, 26);
    encode_ulid(ts_ms, rand, buf[0..26]);
    return buf;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS — all four new tests pass and the existing task tests (which assert `id.len > 0` and id uniqueness) still pass.

- [ ] **Step 5: Commit**

```bash
git add src/utils/generate.zig
git commit -m "feat: generate real ULIDs for task ids"
```

---

### Task 2: Error taxonomy module

Create the domain-grouped error sets and the central `describe`/`exit_code` mapping used by `main.zig`. Both functions take `anyerror`: known members get clean messages + semantic codes; anything else is treated as internal (generic message, exit 1).

**Files:**
- Create: `src/core/errors.zig`
- Test: `src/core/errors.zig` (tests live in the same file)

**Interfaces:**
- Produces:
  - `pub const ValidationError = error{EmptyTitle};`
  - `pub const TaskError = error{ TaskNotFound, AmbiguousPrefix };`
  - `pub const StorageError = error{StorageFailure};`
  - `pub const AppError = ValidationError || TaskError || StorageError;`
  - `pub fn describe(err: anyerror) []const u8`
  - `pub fn exit_code(err: anyerror) u8`

- [ ] **Step 1: Write the failing tests**

Create `src/core/errors.zig` containing ONLY the tests first (so the run fails on missing symbols):

```zig
const std = @import("std");

test "describe returns clean messages for known errors" {
    try std.testing.expectEqualStrings("task title cannot be empty", describe(error.EmptyTitle));
    try std.testing.expectEqualStrings("no task found matching that id", describe(error.TaskNotFound));
    try std.testing.expectEqualStrings("id matches multiple tasks; use more characters", describe(error.AmbiguousPrefix));
    try std.testing.expectEqualStrings("could not read or write task data", describe(error.StorageFailure));
}

test "describe falls back to generic for unknown errors" {
    try std.testing.expectEqualStrings("an unexpected error occurred", describe(error.OutOfMemory));
}

test "exit_code maps errors to semantic codes" {
    try std.testing.expectEqual(@as(u8, 4), exit_code(error.EmptyTitle));
    try std.testing.expectEqual(@as(u8, 4), exit_code(error.AmbiguousPrefix));
    try std.testing.expectEqual(@as(u8, 3), exit_code(error.TaskNotFound));
    try std.testing.expectEqual(@as(u8, 1), exit_code(error.StorageFailure));
    try std.testing.expectEqual(@as(u8, 1), exit_code(error.OutOfMemory));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test --summary all`
Expected: compile error / failure — `describe` and `exit_code` are not defined yet.

- [ ] **Step 3: Write the implementation**

Prepend the implementation above the tests in `src/core/errors.zig` (keep the `const std` import at the top):

```zig
const std = @import("std");

/// User-input problems. Rendered as clean one-line messages.
pub const ValidationError = error{EmptyTitle};

/// Task-domain outcomes the user can act on.
pub const TaskError = error{ TaskNotFound, AmbiguousPrefix };

/// Internal / unexpected failures (I/O, storage). The "something went wrong" bucket.
pub const StorageError = error{StorageFailure};

/// The full application error set. Later sub-projects add CryptoError, VaultError, etc.
pub const AppError = ValidationError || TaskError || StorageError;

/// Maps an error to a clean, user-facing one-line message.
/// Unknown errors are treated as internal and get a generic message.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyTitle => "task title cannot be empty",
        error.TaskNotFound => "no task found matching that id",
        error.AmbiguousPrefix => "id matches multiple tasks; use more characters",
        error.StorageFailure => "could not read or write task data",
        else => "an unexpected error occurred",
    };
}

/// Maps an error to a process exit code:
/// 1 internal · 2 usage · 3 not found · 4 validation/conflict.
/// Unknown errors are treated as internal (1).
pub fn exit_code(err: anyerror) u8 {
    return switch (err) {
        error.EmptyTitle, error.AmbiguousPrefix => 4,
        error.TaskNotFound => 3,
        error.StorageFailure => 1,
        else => 1,
    };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS — all three error tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/core/errors.zig
git commit -m "feat: add domain-grouped error taxonomy"
```

---

### Task 3: Adopt typed errors in task command functions

Replace `error.InvalidItem`/`error.AmbiguousMatch` with the taxonomy's errors, map storage-boundary failures to `error.StorageFailure`, and remove the error-message `std.debug.print` calls from command functions (rendering moves to `main.zig` in Task 4). Keep genuine *output* prints (task listings, "Task deleted: …"). `dispatch_task_command` still returns `void` and keeps its `catch { print; return }` blocks after this task — that is rewired in Task 4.

**Files:**
- Modify: `src/core/task.zig` (command functions + their tests)

**Interfaces:**
- Consumes: `error.StorageFailure`, `error.TaskNotFound`, `error.AmbiguousPrefix`, `error.EmptyTitle` (from Task 2; referenced as bare `error.X`, no import needed).
- Produces: command functions now return only taxonomy errors — `add_task` → `EmptyTitle`/`StorageFailure`; `edit_task`/`delete_task`/`show_task`/`mark_complete` → `TaskNotFound`/`AmbiguousPrefix`/`StorageFailure`.

- [ ] **Step 1: Update the tests to expect the new error values**

In `src/core/task.zig`, change the two tests that assert `error.InvalidItem`:

Replace:
```zig
    try std.testing.expectError(error.InvalidItem, delete_task(allocator, io, "999", tmp_dir.dir));
```
with:
```zig
    try std.testing.expectError(error.TaskNotFound, delete_task(allocator, io, "999", tmp_dir.dir));
```

Replace:
```zig
    try std.testing.expectError(error.InvalidItem, mark_complete(allocator, io, "nonexistent-id", tmp_dir.dir));
```
with:
```zig
    try std.testing.expectError(error.TaskNotFound, mark_complete(allocator, io, "nonexistent-id", tmp_dir.dir));
```

Leave the `error.EmptyTitle` test unchanged.

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test --summary all`
Expected: FAIL — `delete_task`/`mark_complete` still return `error.InvalidItem`, so the two updated tests fail.

- [ ] **Step 3: Update `add_task` storage boundaries**

In `add_task`, replace the swallowing load and the plain save:

Replace:
```zig
    const existing = storage.load_tasks(arena.allocator(), io, dir) catch &[_]models.Task{};
```
with:
```zig
    const existing = storage.load_tasks(arena.allocator(), io, dir) catch return error.StorageFailure;
```

Replace:
```zig
    try storage.save_tasks(arena.allocator(), io, dir, tasks.items);
```
with:
```zig
    storage.save_tasks(arena.allocator(), io, dir, tasks.items) catch return error.StorageFailure;
```

(`if (title.len == 0) return error.EmptyTitle;` stays unchanged. `load_tasks` already returns an empty slice for a missing file, so a fresh install still works.)

- [ ] **Step 4: Update `mark_complete`**

Replace:
```zig
    const tasks = storage.load_tasks(arena.allocator(), io, dir) catch {
        return error.InvalidItem;
    };

    for (tasks) |*task| {
        if (std.mem.eql(u8, task.id, task_id)) {
            task.status = .completed;
            task.updated_at = now_seconds(io);
            task.completed_at = now_seconds(io);
            try storage.save_tasks(arena.allocator(), io, dir, tasks);
            return;
        }
    }

    std.debug.print("Item {s} does not exist!\n", .{task_id});
    return error.InvalidItem;
```
with:
```zig
    const tasks = storage.load_tasks(arena.allocator(), io, dir) catch return error.StorageFailure;

    for (tasks) |*task| {
        if (std.mem.eql(u8, task.id, task_id)) {
            task.status = .completed;
            task.updated_at = now_seconds(io);
            task.completed_at = now_seconds(io);
            storage.save_tasks(arena.allocator(), io, dir, tasks) catch return error.StorageFailure;
            return;
        }
    }

    return error.TaskNotFound;
```

- [ ] **Step 5: Update `edit_task`**

Replace:
```zig
    const existing = try storage.load_tasks(arena.allocator(), io, dir);
```
with:
```zig
    const existing = storage.load_tasks(arena.allocator(), io, dir) catch return error.StorageFailure;
```

Replace:
```zig
            existing[i].updated_at = now_seconds(io);
            try storage.save_tasks(arena.allocator(), io, dir, existing);
            return;
        }
    }

    std.debug.print("No task found matching '{s}'\n", .{task_id});
    return error.InvalidItem;
```
with:
```zig
            existing[i].updated_at = now_seconds(io);
            storage.save_tasks(arena.allocator(), io, dir, existing) catch return error.StorageFailure;
            return;
        }
    }

    return error.TaskNotFound;
```

(Leave `edit_task`'s first-match-wins prefix logic as-is — ambiguity handling is sub-project 04.)

- [ ] **Step 6: Update `delete_task`**

Replace:
```zig
    const tasks = storage.load_tasks(arena_alloc, io, dir) catch {
        return error.InvalidItem;
    };
```
with:
```zig
    const tasks = storage.load_tasks(arena_alloc, io, dir) catch return error.StorageFailure;
```

Replace:
```zig
    if (found_indices.items.len == 0) {
        std.debug.print("No task found matching '{s}'\n", .{task_id});
        return error.InvalidItem;
    }

    if (found_indices.items.len > 1) {
        std.debug.print("Multiple tasks match '{s}':\n", .{task_id});
        for (found_indices.items) |idx| {
            const task = tasks[idx];
            std.debug.print("  - {s} [{s}]\n", .{ task.id[0..@min(8, task.id.len)], task.title });
        }
        std.debug.print("Use a longer ID to disambiguate.\n", .{});
        return error.AmbiguousMatch;
    }

    try storage.save_tasks(arena_alloc, io, dir, remaining.items);
    std.debug.print("Task deleted: {s}\n", .{tasks[found_indices.items[0]].title});
```
with:
```zig
    if (found_indices.items.len == 0) {
        return error.TaskNotFound;
    }

    if (found_indices.items.len > 1) {
        return error.AmbiguousPrefix;
    }

    storage.save_tasks(arena_alloc, io, dir, remaining.items) catch return error.StorageFailure;
    std.debug.print("Task deleted: {s}\n", .{tasks[found_indices.items[0]].title});
```

(The multi-line "which tasks matched" listing is deferred to sub-project 04, which owns the typed prefix-matcher. The success message stays — it is output, not an error.)

- [ ] **Step 7: Update `show_task`**

Replace:
```zig
    const tasks = storage.load_tasks(arena_alloc, io, dir) catch {
        return error.InvalidItem;
    };
```
with:
```zig
    const tasks = storage.load_tasks(arena_alloc, io, dir) catch return error.StorageFailure;
```

Replace:
```zig
    if (found_indices.items.len == 0) {
        std.debug.print("No task found matching '{s}'\n", .{task_id});
        return error.InvalidItem;
    }

    if (found_indices.items.len > 1) {
        std.debug.print("Multiple tasks match '{s}':\n", .{task_id});
        for (found_indices.items) |idx| {
            const task = tasks[idx];
            std.debug.print("  - {s} [{s}]\n", .{ task.id[0..@min(8, task.id.len)], task.title });
        }
        std.debug.print("Use a longer ID to disambiguate.\n", .{});
        return error.AmbiguousMatch;
    }

    const task = tasks[found_indices.items[0]];
    try print_task(io, task, true);
```
with:
```zig
    if (found_indices.items.len == 0) {
        return error.TaskNotFound;
    }

    if (found_indices.items.len > 1) {
        return error.AmbiguousPrefix;
    }

    const task = tasks[found_indices.items[0]];
    try print_task(io, task, true);
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS — the updated `TaskNotFound` tests pass, the `EmptyTitle` test still passes, and no reference to `error.InvalidItem` or `error.AmbiguousMatch` remains. Confirm with:

Run: `rg -n "InvalidItem|AmbiguousMatch" src/`
Expected: no matches.

- [ ] **Step 9: Commit**

```bash
git add src/core/task.zig
git commit -m "refactor: return typed taxonomy errors from task commands"
```

---

### Task 4: Central error handling in main

Make `dispatch_task_command` propagate errors (`!void`) instead of swallowing them, and render them once in `main.zig` via the taxonomy. Also upgrade the flags-parse failure exit code to `2` (usage).

**Files:**
- Modify: `src/core/task.zig` (`dispatch_task_command`)
- Modify: `src/main.zig`

**Interfaces:**
- Consumes: `errors.describe(anyerror) []const u8`, `errors.exit_code(anyerror) u8` (Task 2).
- Produces: `pub fn dispatch_task_command(io: std.Io, environ: std.process.Environ, args: TaskArgs) !void`.

- [ ] **Step 1: Rewrite `dispatch_task_command` to propagate errors**

In `src/core/task.zig`, replace the whole function:

```zig
pub fn dispatch_task_command(io: std.Io, environ: std.process.Environ, args: TaskArgs) void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dir = storage.open_data_dir(allocator, io, environ) catch {
        std.debug.print("Failed to open config directory\n", .{});
        return;
    };
    defer dir.close(io);

    if (args.list) {
        list_task(allocator, io, dir) catch {};
        return;
    }

    if (args.subcommand) |subcommand| {
        switch (subcommand) {
            .add => |a| add_task(allocator, io, dir, a.title, a.desc) catch {
                std.debug.print("Failed to add task\n", .{});
                return;
            },
            .edit => |e| edit_task(allocator, io, dir, e.id, e.title, e.desc orelse "") catch {
                std.debug.print("Failed to update task\n", .{});
                return;
            },
            .delete => |del| delete_task(allocator, io, del.id, dir) catch {
                std.debug.print("Failed to delete task with id: {s}\n", .{del.id});
                return;
            },
            .show => |s| show_task(allocator, io, s.id, dir) catch {
                std.debug.print("Failed to show task with id: {s}\n", .{s.id});
                return;
            },
        }
    } else {
        std.debug.print("{s}\n", .{TaskArgs.help});
    }
}
```
with:
```zig
pub fn dispatch_task_command(io: std.Io, environ: std.process.Environ, args: TaskArgs) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dir = storage.open_data_dir(allocator, io, environ) catch return error.StorageFailure;
    defer dir.close(io);

    if (args.list) return list_task(allocator, io, dir);

    if (args.subcommand) |subcommand| {
        switch (subcommand) {
            .add => |a| try add_task(allocator, io, dir, a.title, a.desc),
            .edit => |e| try edit_task(allocator, io, dir, e.id, e.title, e.desc orelse ""),
            .delete => |del| try delete_task(allocator, io, del.id, dir),
            .show => |s| try show_task(allocator, io, s.id, dir),
        }
    } else {
        std.debug.print("{s}\n", .{TaskArgs.help});
    }
}
```

- [ ] **Step 2: Also make `list_task` propagate storage errors**

In `src/core/task.zig`, in `list_task`, replace:
```zig
    const tasks = storage.load_tasks(arena.allocator(), io, dir) catch return;
```
with:
```zig
    const tasks = storage.load_tasks(arena.allocator(), io, dir) catch return error.StorageFailure;
```
(A missing file still yields an empty slice → "No tasks"; only real read/parse failures now surface.)

- [ ] **Step 3: Wire the central handler in `main.zig`**

In `src/main.zig`, add the errors import near the top imports:
```zig
const errors = @import("core/errors.zig");
```

Change the flags-parse failure exit from `1` to `2`. Replace:
```zig
    const parsed = flags.parse(allocator, args, Args, &diag) catch |err| {
        diag.report();
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };
```
with:
```zig
    const parsed = flags.parse(allocator, args, Args, &diag) catch |err| {
        diag.report();
        std.process.exit(if (err == error.HelpRequested) 0 else 2);
    };
```

Replace the dispatch switch:
```zig
    switch (parsed.command) {
        .task => |t| task.dispatch_task_command(init.io, init.minimal.environ, t),
    }
```
with:
```zig
    switch (parsed.command) {
        .task => |t| task.dispatch_task_command(init.io, init.minimal.environ, t) catch |err| {
            std.debug.print("error: {s}\n", .{errors.describe(err)});
            std.process.exit(errors.exit_code(err));
        },
    }
```

- [ ] **Step 4: Verify the build and full test suite**

Run: `zig build test --summary all`
Expected: PASS — all existing tests (11 + the new ones from Tasks 1–2) pass.

Run: `zig build`
Expected: builds `tip` with no errors.

- [ ] **Step 5: Manually verify runtime behavior + exit codes**

Run:
```bash
zig build run -- task add --title="Plan check"
zig build run -- task --list
zig build run -- task show --id=zzzzzzzz ; echo "exit=$?"
```
Expected: the add succeeds; `--list` shows the task with a ULID prefix under `ID:`; the bad `show` prints `error: no task found matching that id` and reports `exit=3`.

- [ ] **Step 6: Commit**

```bash
git add src/core/task.zig src/main.zig
git commit -m "feat: centralize error rendering and exit codes in main"
```

---

## Self-Review

**Spec coverage (against [2026-07-02-01 design](../specs/2026-07-02-01-id-strategy-error-taxonomy-design.md)):**
- E1 ULID format → Task 1. E2 TEXT PK → forward decision, realized in 03 (noted out-of-scope). E3 CSPRNG, no monotonic → Task 1 (`std.crypto.random.bytes`, no counter). E4 prefix `LIKE` → sub-project 04 (out of scope; current linear prefix match untouched). E5 domain-grouped sets → Task 2. E6 user/internal split → Task 2 (`describe` generic fallback = internal bucket). E7 semantic exit codes → Task 2 + Task 4 (usage=2). E8 central handling, kill `catch {}` → Tasks 3–4.
- Deferred items (Diagnostic, `--verbose`, SQLite errors, JSON→SQLite migration, complete/start, prefix-matcher) are all explicitly out of scope and left untouched.

**Placeholder scan:** none — every code step contains full code and exact commands.

**Type consistency:** `generate_id(allocator, io) ![]u8` and `encode_ulid(u64, [10]u8, *[26]u8)` consistent across Task 1. `describe(anyerror) []const u8` / `exit_code(anyerror) u8` used identically in Tasks 2 and 4. Error members `EmptyTitle`/`TaskNotFound`/`AmbiguousPrefix`/`StorageFailure` used consistently across Tasks 2–4. `dispatch_task_command` signature `!void` matches its Task 4 call site.
