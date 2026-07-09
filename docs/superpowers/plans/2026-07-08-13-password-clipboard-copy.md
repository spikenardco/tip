# Password Clipboard Copy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `password show <id> --copy` to copy a stored password to the system clipboard (never printed) and auto-clear it after a timeout.

**Architecture:** A new `src/core/clipboard.zig` shells out to the platform clipboard tool (auto-detected: `pbcopy` on macOS; `wl-copy`, `xclip`, or `xsel` on Linux) with pure, unit-testable `candidates`/argv builders and thin `copy`/`read`/`clear` wrappers over `std.process`. `password.zig` gains `--copy`/`--timeout` on the `show` subcommand: it decrypts (SP11 path), copies, prints the masked entry plus a confirmation, then foreground-blocks for the timeout and does a safe clear (only clears if the clipboard still holds our value). Config gains a `clipboard_timeout` default; errors gain a clipboard group.

**Tech Stack:** Zig 0.16 (`std.Io`, `std.process.spawn`/`run`, `std.Io.sleep`). No external dependencies — relies on platform clipboard tools present at runtime.

**Dependencies:** This plan requires **SP11 (Password CRUD + Generation)** and **SP05 (Config System)** and **SP01 (Error taxonomy)** to be implemented first. It consumes:
- `password.zig`: `PasswordArgs` (union of subcommands incl. `show`), `dispatch_password_command(io: std.Io, environ: std.process.Environ, args: PasswordArgs)`, and SP11's existing decrypt-on-show path (`field.decrypt_field` + the active vault key).
- `errors.zig`: `AppError`, `describe(anyerror) []const u8`, `exit_code(anyerror) u8`.
- `config.zig`: `Config` struct with `std.zon.parse` load/serialize.

---

## Global Constraints

- **Zig version:** 0.16.0 (`minimum_zig_version = "0.16.0"`). Use the new `std.Io` APIs. Sleep via `std.Io.sleep(io, std.Io.Duration.fromSeconds(n), .awake)`.
- **Identifier casing:** functions/vars/fields = `snake_case`; types = `PascalCase`; enum members = `snake_case`.
- **Targets:** macOS + Linux only (Windows dropped from the project). `candidates` returns empty for other OS tags.
- **Backend detection order:** macOS → `pbcopy`. Linux with `$WAYLAND_DISPLAY` set → `wl-copy`, then `xclip`, then `xsel`. Linux without Wayland → `xclip`, then `xsel`.
- **No new dependency.** Missing tool → `ClipboardToolNotFound` with an install hint.
- **Timeout precedence (high→low):** `--timeout` flag > `clipboard_timeout` config > `20`. `--timeout=0` = copy, no block, no clear.
- **Safe clear:** before clearing, read the clipboard back; only clear if it still equals the copied plaintext.
- **Ctrl-C = keep:** no SIGINT trap; interrupting the wait leaves the password on the clipboard.
- **Secrets never printed:** the copy path prints `****`, never the plaintext. Zero the plaintext buffer before returning.
- **Error taxonomy (SP01):** commands return typed errors; `main.zig` renders via `errors.describe`/`errors.exit_code`. New members: `ClipboardToolNotFound`, `ClipboardCommandFailed`.
- **Exit codes:** `0` ok · `1` internal/environment · `2` usage · `3` not found · `4` validation. Clipboard errors → `1`.
- **Tests:** `zig build test --summary all` from repo root. Tests live at the bottom of each source file. Integration tests that touch the real clipboard are gated: on `ClipboardToolNotFound` they `return error.SkipZigTest`.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `src/core/errors.zig` | Modify | Add `ClipboardError` set; wire `describe`/`exit_code` (SP01 file) |
| `src/core/config.zig` | Modify | Add `clipboard_timeout: u32 = 20` field (SP05 file) |
| `src/core/clipboard.zig` | Create | `Backend`, `candidates`, argv builders, `copy`/`read`/`clear`, `has_wayland` + tests |
| `src/core/password.zig` | Modify | `--copy`/`--timeout` on `show`; `resolve_timeout`; `should_clear`; auto-clear flow (SP11 file) |

---

### Task 1: Clipboard error taxonomy

**Files:**
- Modify: `src/core/errors.zig`

**Interfaces:**
- Consumes: existing `AppError`, `describe(anyerror) []const u8`, `exit_code(anyerror) u8` (SP01).
- Produces:
  - `pub const ClipboardError = error{ ClipboardToolNotFound, ClipboardCommandFailed };`
  - `ClipboardError` folded into `AppError`; both members handled by `describe`/`exit_code`.

- [ ] **Step 1: Write the failing tests**

Add at the bottom of `src/core/errors.zig`:

```zig
test "describe returns clean messages for clipboard errors" {
    try std.testing.expectEqualStrings(
        "no clipboard tool found; install wl-clipboard, xclip, or xsel",
        describe(error.ClipboardToolNotFound),
    );
    try std.testing.expectEqualStrings(
        "failed to access the system clipboard",
        describe(error.ClipboardCommandFailed),
    );
}

test "exit_code maps clipboard errors to internal (1)" {
    try std.testing.expectEqual(@as(u8, 1), exit_code(error.ClipboardToolNotFound));
    try std.testing.expectEqual(@as(u8, 1), exit_code(error.ClipboardCommandFailed));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `error.ClipboardToolNotFound` not referenced anywhere / messages missing.

- [ ] **Step 3: Write the implementation**

Add the error set near the other sets and fold it into `AppError`:

```zig
pub const ClipboardError = error{ ClipboardToolNotFound, ClipboardCommandFailed };

// extend the existing union, e.g.:
// pub const AppError = ValidationError || TaskError || StorageError || ... || ClipboardError;
```

Add the two arms to `describe` (before the `else` fallback):

```zig
error.ClipboardToolNotFound => "no clipboard tool found; install wl-clipboard, xclip, or xsel",
error.ClipboardCommandFailed => "failed to access the system clipboard",
```

Add the two arms to `exit_code` (both map to internal `1`; if `1` is the `else` default you may rely on the fallback, but list them explicitly for clarity):

```zig
error.ClipboardToolNotFound => 1,
error.ClipboardCommandFailed => 1,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/errors.zig
git commit -m "feat(errors): add clipboard error taxonomy (SP13)"
```

---

### Task 2: Config `clipboard_timeout` default

**Files:**
- Modify: `src/core/config.zig`

**Interfaces:**
- Consumes: SP05 `Config` struct + `std.zon.parse.fromSliceAlloc`.
- Produces: `Config` gains `clipboard_timeout: u32 = 20`, readable/writable via existing `tip config get/set`.

- [ ] **Step 1: Write the failing tests**

Add at the bottom of `src/core/config.zig`:

```zig
test "config defaults clipboard_timeout to 20" {
    const c = Config{};
    try std.testing.expectEqual(@as(u32, 20), c.clipboard_timeout);
}

test "config parses clipboard_timeout from ZON" {
    const allocator = std.testing.allocator;
    const src =
        \\.{
        \\    .verbose = false,
        \\    .quiet = false,
        \\    .default_vault = "personal",
        \\    .mode = "local",
        \\    .clipboard_timeout = 45,
        \\}
    ;
    var status: std.zon.parse.Status = .{};
    defer status.deinit(allocator);
    const parsed = try std.zon.parse.fromSliceAlloc(Config, allocator, src, &status, .{});
    defer std.zon.parse.free(allocator, parsed);
    try std.testing.expectEqual(@as(u32, 45), parsed.clipboard_timeout);
}
```

> Note: match the exact `std.zon.parse` call form used elsewhere in `config.zig` (SP05). If SP05 wraps parsing in a helper (e.g. `config.load_from_slice`), call that helper instead of `std.zon.parse.fromSliceAlloc` directly, keeping the assertion on `clipboard_timeout` the same.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `clipboard_timeout` is not a field of `Config`.

- [ ] **Step 3: Write the implementation**

Add the field to the `Config` struct (keep the existing fields):

```zig
const Config = struct {
    verbose: bool = false,
    quiet: bool = false,
    default_vault: ?[]const u8 = null,
    mode: []const u8 = "local",
    clipboard_timeout: u32 = 20, // SP13: seconds before clipboard auto-clear
};
```

No other change is required: SP05's `get`/`set` operate over struct fields by name, so `tip config get --key=clipboard_timeout` / `--value=30` work automatically. If SP05's `set` parses values per-field type, ensure the `u32` branch parses via `std.fmt.parseInt(u32, value, 10)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/config.zig
git commit -m "feat(config): add clipboard_timeout default (SP13)"
```

---

### Task 3: Clipboard backend module

**Files:**
- Create: `src/core/clipboard.zig`

**Interfaces:**
- Consumes: `std.process` (`spawn`, `run`, `Child`), `std.Io`, `std.process.Environ`, `errors.ClipboardError`.
- Produces:
  - `pub const Backend = enum { pbcopy, wl_copy, xclip, xsel };`
  - `pub const Error = error{ ClipboardToolNotFound, ClipboardCommandFailed };`
  - `pub fn candidates(os_tag: std.Target.Os.Tag, has_wayland_display: bool) []const Backend`
  - `pub fn copy_argv(b: Backend) []const []const u8`
  - `pub fn read_argv(b: Backend) []const []const u8`
  - `pub fn has_wayland(environ: std.process.Environ) bool`
  - `pub fn copy(io: std.Io, cand: []const Backend, data: []const u8) Error!Backend`
  - `pub fn read(gpa: Allocator, io: std.Io, b: Backend) Error![]u8` (caller owns the returned slice)
  - `pub fn clear(gpa: Allocator, io: std.Io, b: Backend) Error!void`

- [ ] **Step 1: Write the failing tests**

Create `src/core/clipboard.zig` with only the tests first (plus the imports):

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

test "candidates: macOS returns pbcopy only" {
    const c = candidates(.macos, false);
    try std.testing.expectEqual(@as(usize, 1), c.len);
    try std.testing.expectEqual(Backend.pbcopy, c[0]);
}

test "candidates: linux with wayland prefers wl_copy" {
    const c = candidates(.linux, true);
    try std.testing.expectEqual(@as(usize, 3), c.len);
    try std.testing.expectEqual(Backend.wl_copy, c[0]);
    try std.testing.expectEqual(Backend.xclip, c[1]);
    try std.testing.expectEqual(Backend.xsel, c[2]);
}

test "candidates: linux without wayland is xclip then xsel" {
    const c = candidates(.linux, false);
    try std.testing.expectEqual(@as(usize, 2), c.len);
    try std.testing.expectEqual(Backend.xclip, c[0]);
    try std.testing.expectEqual(Backend.xsel, c[1]);
}

test "candidates: unknown OS is empty" {
    try std.testing.expectEqual(@as(usize, 0), candidates(.freestanding, true).len);
}

test "copy_argv builds expected commands" {
    try std.testing.expectEqualStrings("pbcopy", copy_argv(.pbcopy)[0]);
    try std.testing.expectEqualStrings("wl-copy", copy_argv(.wl_copy)[0]);
    try std.testing.expectEqualStrings("xclip", copy_argv(.xclip)[0]);
    try std.testing.expectEqualStrings("-selection", copy_argv(.xclip)[1]);
    try std.testing.expectEqualStrings("clipboard", copy_argv(.xclip)[2]);
    try std.testing.expectEqualStrings("xsel", copy_argv(.xsel)[0]);
}

test "read_argv builds expected commands" {
    try std.testing.expectEqualStrings("pbpaste", read_argv(.pbcopy)[0]);
    try std.testing.expectEqualStrings("wl-paste", read_argv(.wl_copy)[0]);
    try std.testing.expectEqualStrings("-o", read_argv(.xclip)[3]);
    try std.testing.expectEqualStrings("--output", read_argv(.xsel)[2]);
}

test "copy: empty candidate list returns ClipboardToolNotFound" {
    const io = std.testing.io;
    try std.testing.expectError(error.ClipboardToolNotFound, copy(io, &[_]Backend{}, "secret"));
}

// Gated integration test: needs a real clipboard tool + display.
test "copy then read round-trips, clear empties" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cand = candidates(@import("builtin").os.tag, false);
    const used = copy(io, cand, "sp13-roundtrip") catch |err| switch (err) {
        error.ClipboardToolNotFound => return error.SkipZigTest,
        else => return err,
    };
    const got = try read(gpa, io, used);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("sp13-roundtrip", got);

    try clear(gpa, io, used);
    const after = try read(gpa, io, used);
    defer gpa.free(after);
    try std.testing.expectEqualStrings("", after);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `candidates`, `Backend`, `copy`, etc. are not defined.

- [ ] **Step 3: Write the implementation**

Add above the tests in `src/core/clipboard.zig`:

```zig
pub const Backend = enum { pbcopy, wl_copy, xclip, xsel };

pub const Error = error{ ClipboardToolNotFound, ClipboardCommandFailed };

pub fn candidates(os_tag: std.Target.Os.Tag, has_wayland_display: bool) []const Backend {
    return switch (os_tag) {
        .macos => &[_]Backend{.pbcopy},
        .linux => if (has_wayland_display)
            &[_]Backend{ .wl_copy, .xclip, .xsel }
        else
            &[_]Backend{ .xclip, .xsel },
        else => &[_]Backend{},
    };
}

pub fn copy_argv(b: Backend) []const []const u8 {
    return switch (b) {
        .pbcopy => &[_][]const u8{"pbcopy"},
        .wl_copy => &[_][]const u8{"wl-copy"},
        .xclip => &[_][]const u8{ "xclip", "-selection", "clipboard" },
        .xsel => &[_][]const u8{ "xsel", "--clipboard", "--input" },
    };
}

pub fn read_argv(b: Backend) []const []const u8 {
    return switch (b) {
        .pbcopy => &[_][]const u8{"pbpaste"},
        .wl_copy => &[_][]const u8{ "wl-paste", "--no-newline" },
        .xclip => &[_][]const u8{ "xclip", "-selection", "clipboard", "-o" },
        .xsel => &[_][]const u8{ "xsel", "--clipboard", "--output" },
    };
}

const ClearMethod = union(enum) {
    command: []const []const u8, // dedicated clear command (no stdin)
    empty_stdin: []const []const u8, // copy an empty string
};

fn clear_method(b: Backend) ClearMethod {
    return switch (b) {
        .pbcopy => .{ .empty_stdin = &[_][]const u8{"pbcopy"} },
        .xclip => .{ .empty_stdin = &[_][]const u8{ "xclip", "-selection", "clipboard" } },
        .wl_copy => .{ .command = &[_][]const u8{ "wl-copy", "--clear" } },
        .xsel => .{ .command = &[_][]const u8{ "xsel", "--clipboard", "--clear" } },
    };
}

pub fn has_wayland(environ: std.process.Environ) bool {
    if (@import("builtin").os.tag == .windows) return false;
    const prefix = "WAYLAND_DISPLAY=";
    for (environ.block.view().slice) |entry| {
        const s = std.mem.span(entry);
        if (std.mem.startsWith(u8, s, prefix) and s.len > prefix.len) return true;
    }
    return false;
}

const SpawnWriteError = error{ tool_missing, failed };

fn spawn_write(io: std.Io, argv: []const []const u8, data: []const u8) SpawnWriteError!void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.tool_missing,
        else => return error.failed,
    };
    if (child.stdin) |stdin_file| {
        stdin_file.writeStreamingAll(io, data) catch {
            _ = child.wait(io) catch {};
            return error.failed;
        };
        stdin_file.close(io);
        child.stdin = null;
    }
    const term = child.wait(io) catch return error.failed;
    switch (term) {
        .exited => |code| if (code != 0) return error.failed,
        else => return error.failed,
    }
}

pub fn copy(io: std.Io, cand: []const Backend, data: []const u8) Error!Backend {
    for (cand) |b| {
        spawn_write(io, copy_argv(b), data) catch |err| switch (err) {
            error.tool_missing => continue,
            error.failed => return error.ClipboardCommandFailed,
        };
        return b;
    }
    return error.ClipboardToolNotFound;
}

pub fn read(gpa: Allocator, io: std.Io, b: Backend) Error![]u8 {
    const result = std.process.run(gpa, io, .{ .argv = read_argv(b) }) catch |err| switch (err) {
        error.FileNotFound => return error.ClipboardToolNotFound,
        else => return error.ClipboardCommandFailed,
    };
    gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            gpa.free(result.stdout);
            return error.ClipboardCommandFailed;
        },
        else => {
            gpa.free(result.stdout);
            return error.ClipboardCommandFailed;
        },
    }
    return result.stdout;
}

pub fn clear(gpa: Allocator, io: std.Io, b: Backend) Error!void {
    switch (clear_method(b)) {
        .command => |argv| {
            const result = std.process.run(gpa, io, .{ .argv = argv }) catch return error.ClipboardCommandFailed;
            gpa.free(result.stdout);
            gpa.free(result.stderr);
            switch (result.term) {
                .exited => |code| if (code != 0) return error.ClipboardCommandFailed,
                else => return error.ClipboardCommandFailed,
            }
        },
        .empty_stdin => |argv| {
            spawn_write(io, argv, "") catch return error.ClipboardCommandFailed;
        },
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all`
Expected: PASS (the round-trip integration test passes if a clipboard tool + display are available, otherwise it is skipped).

- [ ] **Step 5: Commit**

```bash
git add src/core/clipboard.zig
git commit -m "feat(clipboard): add cross-platform clipboard backend (SP13)"
```

---

### Task 4: Wire `--copy` / `--timeout` into `password show`

**Files:**
- Modify: `src/core/password.zig`

**Interfaces:**
- Consumes: `clipboard` (Task 3), `errors.ClipboardError` (Task 1), `config.Config.clipboard_timeout` (Task 2), SP11 `PasswordArgs`/`dispatch_password_command` + SP11 decrypt-on-show path.
- Produces:
  - `show` subcommand struct gains `copy: bool = false` and `timeout: ?u32 = null`.
  - `pub fn resolve_timeout(flag: ?u32, config_value: u32) u32`
  - `pub fn should_clear(current: []const u8, copied: []const u8) bool`

- [ ] **Step 1: Write the failing tests**

Add at the bottom of `src/core/password.zig` (alongside the SP11 tests):

```zig
test "resolve_timeout: flag overrides config" {
    try std.testing.expectEqual(@as(u32, 45), resolve_timeout(45, 20));
}

test "resolve_timeout: falls back to config when no flag" {
    try std.testing.expectEqual(@as(u32, 30), resolve_timeout(null, 30));
}

test "resolve_timeout: zero flag is honored (no auto-clear)" {
    try std.testing.expectEqual(@as(u32, 0), resolve_timeout(0, 20));
}

test "should_clear: true only when clipboard still holds our value" {
    try std.testing.expect(should_clear("secret", "secret"));
    try std.testing.expect(!should_clear("something-else", "secret"));
    try std.testing.expect(!should_clear("", "secret"));
}

test "PasswordArgs show carries copy and timeout" {
    const a = PasswordArgs{ .subcommand = .{ .show = .{ .id = "abc", .copy = true, .timeout = 45 } } };
    try std.testing.expect(a.subcommand.show.copy);
    try std.testing.expectEqual(@as(?u32, 45), a.subcommand.show.timeout);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `resolve_timeout`/`should_clear` undefined; `show` has no `copy`/`timeout` fields.

- [ ] **Step 3: Write the implementation**

Add the imports (top of file, matching SP11's import style):

```zig
const clipboard = @import("clipboard.zig");
const config_mod = @import("config.zig");
```

Add the two fields to the `show` variant of `PasswordArgs` (keep the SP11 fields like `id`, `show_password`):

```zig
show: struct {
    id: []const u8,
    show_password: bool = false,
    copy: bool = false,     // SP13: copy password to clipboard
    timeout: ?u32 = null,   // SP13: override auto-clear delay (0 = no clear)
},
```

Add the two pure helpers:

```zig
pub fn resolve_timeout(flag: ?u32, config_value: u32) u32 {
    return flag orelse config_value;
}

pub fn should_clear(current: []const u8, copied: []const u8) bool {
    return std.mem.eql(u8, current, copied);
}
```

In the `show` handler, after SP11 has produced the decrypted `plaintext` (owned slice) and rendered the entry (password masked unless `--show-password`), add the copy branch. The handler needs `io`, `environ`, a general allocator (`gpa`), and the resolved `Config`; thread these from `dispatch_password_command` as SP11 already does for other subcommands. Zero the plaintext before returning.

```zig
// `args` is the show subcommand struct; `plaintext` is the decrypted password (owned).
// `gpa`, `io`, `environ`, and `cfg: config_mod.Config` are in scope from dispatch.
defer std.crypto.secureZero(u8, plaintext); // wipe before the buffer is freed

if (args.copy) {
    const cand = clipboard.candidates(@import("builtin").os.tag, clipboard.has_wayland(environ));
    const used = try clipboard.copy(io, cand, plaintext); // errors.ClipboardToolNotFound / ...CommandFailed

    const timeout = resolve_timeout(args.timeout, cfg.clipboard_timeout);
    if (timeout == 0) {
        std.debug.print("Copied password to clipboard (no auto-clear)\n", .{});
        return;
    }

    std.debug.print(
        "Copied password to clipboard \u{2014} clearing in {d}s (Ctrl-C to keep)\n",
        .{timeout},
    );

    // Foreground block. Ctrl-C here just kills the process (keep behavior).
    std.Io.sleep(io, std.Io.Duration.fromSeconds(@intCast(timeout)), .awake) catch {};

    // Safe clear: only wipe if the clipboard still holds our value.
    const current = clipboard.read(gpa, io, used) catch return; // best-effort
    defer gpa.free(current);
    if (should_clear(current, plaintext)) {
        clipboard.clear(gpa, io, used) catch {};
    }
    return;
}
```

Notes for the implementer:
- `--copy` and `--show-password` are independent; when both are set, print the revealed entry (SP11) and still copy. When only `--copy` is set, keep the entry masked.
- Honor SP05 `--quiet`: when quiet, skip the entry block but still print the one-line "Copied password to clipboard …" confirmation.
- Register the `--copy` and `--timeout` flags on the `show` command in whatever flag-parsing layer SP11 uses (the `flags` dependency), so `tip password show <id> --copy --timeout=45` parses into the struct above.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Manual verification (real clipboard)**

On a machine with a clipboard tool:

```bash
# copy + auto-clear
tip password show <id> --copy --timeout=3
# within 3s: paste somewhere → password present; after 3s: paste → empty
# copy without clearing
tip password show <id> --copy --timeout=0
# paste → password present, terminal returned immediately
```

Expected: masked entry printed, confirmation line printed, clipboard behaves per timeout.

- [ ] **Step 6: Commit**

```bash
git add src/core/password.zig
git commit -m "feat(password): add show --copy with auto-clear timeout (SP13)"
```

---

## Self-Review

**1. Spec coverage** (against `2026-07-08-13-password-clipboard-copy-design.md`):
- 13-1 `--copy` on `show` → Task 4 (field + handler).
- 13-2 copies password only, entry stays masked → Task 4 (masking note; no field selector).
- 13-3 shell-out, auto-detected backends → Task 3 (`candidates`, argv builders).
- 13-4 foreground blocking auto-clear → Task 4 (`std.Io.sleep` then clear).
- 13-5 timeout default/flag/config, `--timeout=0` disables → Task 2 (config field) + Task 4 (`resolve_timeout`, zero path).
- 13-6 safe clear → Task 3 (`read`/`clear`) + Task 4 (`should_clear`).
- 13-7 Ctrl-C keep → Task 4 (no SIGINT trap; comment).
- 13-8 vault unlocked → reuses SP11 decrypt path (dependency stated); no new work.
- 13-9 no new dependency + install error → Task 1 (`ClipboardToolNotFound` message) + Task 3 (detection).
- Errors (Part F) → Task 1. File architecture (Part E) → matches File Structure table. Testing (Part G): unit tests (candidates/argv/resolve/should_clear) + gated integration (round-trip) + manual e2e → Tasks 3–4.

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". All steps contain concrete code and exact commands.

**3. Type consistency:** `Backend`, `candidates(std.Target.Os.Tag, bool)`, `copy(io, []const Backend, []const u8) Error!Backend`, `read(gpa, io, Backend) Error![]u8`, `clear(gpa, io, Backend) Error!void`, `has_wayland(std.process.Environ) bool`, `resolve_timeout(?u32, u32) u32`, `should_clear([]const u8, []const u8) bool` are used identically in tests and call sites. `Error` members match `errors.ClipboardError` members from Task 1. `clipboard_timeout: u32` consistent across Tasks 2 and 4.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-08-13-password-clipboard-copy.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
