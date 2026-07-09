# Sub-project 13 — Password Clipboard Copy (DESIGN)

> **Status:** DESIGN APPROVED
> **Date:** 2026-07-08
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 12 (Password strength + audit)
> **Successor:** TBD

This sub-project adds the ability to copy a stored password to the system clipboard
without the secret ever touching the terminal or scrollback, then auto-clear it after a
timeout. It is the safer everyday alternative to `password show --show-password`
(SP11-8): you get the secret into a paste buffer without printing it.

It extends SP11's `password show` command and reuses SP11's decryption path and
`VaultLocked` constraint (SP11-9). It adds one new config key that plugs into the SP05
config system.

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| 13-1 | **`--copy` flag on the existing `password show` command.** No new subcommand; copying is a mode of `show`. | LOCKED |
| 13-2 | **Copies the `password` field only.** No field selector in v1. `show` still prints the entry with the password **masked** (`****`), plus a confirmation line. | LOCKED |
| 13-3 | **Clipboard backend = shell out to the platform tool**, auto-detected at runtime. No GUI-library linking. | LOCKED |
| 13-4 | **Foreground blocking auto-clear.** The process copies, prints a confirmation, sleeps for the timeout, clears, then exits. `tip ... --copy &` is the non-blocking escape hatch. | LOCKED |
| 13-5 | **Timeout:** default 20s; `--timeout=<seconds>` per-run override; `--timeout=0` = copy but do **not** block or auto-clear; config default via new `clipboard_timeout` key. Precedence: flag > config > 20. | LOCKED |
| 13-6 | **Safe clear.** Before clearing, read the clipboard back and only clear if it still equals the copied password. If the user copied something else in the meantime, leave it alone. | LOCKED |
| 13-7 | **Ctrl-C = keep.** SIGINT during the wait exits immediately and leaves the password on the clipboard (default signal behavior; no trap). | LOCKED |
| 13-8 | **Vault must be unlocked.** Reuse SP11-9 `VaultLocked` with the same message/instructions. | LOCKED |
| 13-9 | **No new dependency.** Backend + read-back rely on tools already present on the platform; missing tool → clear install error. | LOCKED |

---

## Part A — CLI surface

### Extended command (`password show`)

```
tip password show <id>
       [--show-password]        # SP11: reveal in terminal
       [--copy]                 # SP13: copy password to clipboard, then auto-clear
       [--timeout=<seconds>]    # SP13: override clear delay (0 = no auto-clear)
```

### Flag rules (additions to SP11's table)

| Flag | Type | Default | Applies to |
|---|---|---|---|
| `--copy` | bool | false | show |
| `--timeout` | integer (seconds) | `clipboard_timeout` config (20) | show (only meaningful with `--copy`) |

Notes:
- `--copy` and `--show-password` are **independent** and may be combined (reveal in terminal
  *and* copy). `--copy` alone keeps the password masked in the printed entry.
- `--timeout` without `--copy` is a no-op (ignored); it only affects the copy path.
- `--timeout=0` copies and returns immediately with no blocking and no scheduled clear.

### Example usage

```bash
# Copy the password, mask it in output, auto-clear after 20s
tip password show github --copy

# Copy but keep the terminal free immediately (no auto-clear)
tip password show github --copy --timeout=0

# Copy with a longer window
tip password show github --copy --timeout=45

# Non-blocking with auto-clear: background the process
tip password show github --copy &
```

### Example output

`password show github --copy`:

```
Title:     github
Username:  ben
Password:  ****
URL:       https://github.com
Updated:   2 min ago

Copied password to clipboard — clearing in 20s (Ctrl-C to keep)
```

`password show github --copy --timeout=0`:

```
Title:     github
Username:  ben
Password:  ****
URL:       https://github.com
Updated:   2 min ago

Copied password to clipboard (no auto-clear)
```

`--quiet` (SP05): suppress the entry block; still print a one-line confirmation
(`Copied password to clipboard — clearing in 20s`) since it is the primary feedback that the
command did anything.

---

## Part B — Clipboard backend (shell-out, auto-detected)

### File: `src/core/clipboard.zig` (NEW)

Detects the platform tool once, then exposes copy / read / clear over it.

```zig
pub const Backend = enum { pbcopy, wl_copy, xclip, xsel };

pub const Tool = struct {
    backend: Backend,
    // argv builders return the command + args for each op
};

pub const Error = error{
    ClipboardToolNotFound,
    ClipboardCommandFailed,
};

/// Detect the available clipboard tool for the current platform/session.
pub fn detect(allocator: Allocator) Error!Backend;

/// Copy bytes to the clipboard via the detected backend.
pub fn copy(allocator: Allocator, io: std.Io, backend: Backend, data: []const u8) Error!void;

/// Read the current clipboard contents back (for safe-clear comparison).
/// Returns an owned slice the caller frees.
pub fn read(allocator: Allocator, io: std.Io, backend: Backend) Error![]u8;

/// Clear the clipboard (write empty).
pub fn clear(allocator: Allocator, io: std.Io, backend: Backend) Error!void;
```

### Detection order

| Condition | Backend | Copy cmd | Read cmd | Clear cmd |
|---|---|---|---|---|
| macOS (`builtin.os.tag == .macos`) | `pbcopy` | `pbcopy` (stdin) | `pbpaste` | `pbcopy` with empty stdin |
| Linux, `$WAYLAND_DISPLAY` set | `wl_copy` | `wl-copy` (stdin) | `wl-paste --no-newline` | `wl-copy --clear` |
| Linux, X11 (`xclip` present) | `xclip` | `xclip -selection clipboard` (stdin) | `xclip -selection clipboard -o` | `xclip -selection clipboard` with empty stdin |
| Linux, X11 (`xsel` present) | `xsel` | `xsel --clipboard --input` | `xsel --clipboard --output` | `xsel --clipboard --clear` |
| none found | — | → `ClipboardToolNotFound` | | |

Tool presence is probed by attempting to spawn the process; ENOENT means "not installed".
On Linux, prefer Wayland when `$WAYLAND_DISPLAY` is set, otherwise try `xclip` then `xsel`.

### X11 ownership note (implementation caveat, not a decision)

X11 selections are owned by a live process: `xclip`/`xsel` fork and hold the selection until
another app takes ownership or they are killed. This is fine for our model — we spawn the copy
tool (which persists the selection), and our foreground `tip` process independently blocks and
later clears by taking ownership with an empty write. On macOS the pasteboard server persists
independently of `pbcopy`.

---

## Part C — Config integration (SP05)

Add one field to the flat `Config` struct in `src/core/config.zig`:

```zig
const Config = struct {
    verbose: bool = false,
    quiet: bool = false,
    default_vault: ?[]const u8 = null,
    mode: []const u8 = "local",
    clipboard_timeout: u32 = 20,   // SP13: seconds before clipboard auto-clear
};
```

- Readable/writable via existing `tip config get --key=clipboard_timeout` /
  `tip config set --key=clipboard_timeout --value=30`.
- Resolution precedence (high → low): `--timeout` flag > `clipboard_timeout` config > `20`.

---

## Part D — Execution flow (`show --copy`)

```
1. Resolve active vault; require unlocked (SP11-9) → else VaultLocked.
2. Look up entry by id/prefix (SP11 / SP04 prefix-match) → else PasswordNotFound.
3. Decrypt the password (SP11 crypto path).
4. clipboard.detect() → backend, or ClipboardToolNotFound.
5. clipboard.copy(backend, plaintext).
6. Print the entry (password masked) unless --quiet; print confirmation line.
7. Resolve timeout = flag ?? config.clipboard_timeout ?? 20.
8. If timeout == 0: return immediately (no clear).
   Else:
     a. Sleep `timeout` seconds (blocking). Ctrl-C here just kills the process (keep).
     b. Safe clear:
          current = clipboard.read(backend)
          if current == plaintext: clipboard.clear(backend)
          else: leave it (user copied something else)
     c. Exit.
9. Zero the plaintext buffer before exit (secure wipe, consistent with SP10/SP11).
```

Secrets are never written to stdout/stderr on the copy path (only `****`). The plaintext lives
only in the process buffer and the clipboard.

---

## Part E — File architecture

### New files

| File | Responsibility |
|---|---|
| `src/core/clipboard.zig` | Backend detection + `copy` / `read` / `clear` over the platform tool. Pure shell-out; no secret logging. |

### Modified files

| File | Change |
|---|---|
| `src/core/password.zig` | Add `--copy` and `--timeout` flags to `show`; wire the copy/auto-clear flow; import `clipboard`. |
| `src/core/config.zig` | Add `clipboard_timeout: u32 = 20` field. |
| `src/core/models.zig` | No changes needed. |

### Dependency graph

```
password.zig (CLI dispatch: show --copy)
  ├── clipboard.zig   (detect / copy / read / clear)
  ├── crypto (SP10/SP11 decrypt)
  └── config.zig      (clipboard_timeout default)
```

---

## Part F — Error taxonomy (extends SP01 / SP11)

| Error | Raised when |
|---|---|
| `VaultLocked` | `show --copy` while the active vault is locked (reused from SP11-9). |
| `PasswordNotFound` | `show --copy` with a nonexistent id/prefix (reused from SP11). |
| `ClipboardToolNotFound` | No supported clipboard tool detected. Message names the package to install (`pbcopy` builtin on macOS; `wl-clipboard`, `xclip`, or `xsel` on Linux). |
| `ClipboardCommandFailed` | The spawned tool exited non-zero or could not be executed for a reason other than ENOENT. |

Error messages are actionable, e.g.:

```
error: no clipboard tool found
  install one of: wl-clipboard (Wayland), xclip or xsel (X11)
```

---

## Part G — Testing

Clipboard I/O shells out to external tools, so tests avoid touching the real system clipboard.
Split into unit tests (pure logic) and gated integration tests.

### Unit tests (`clipboard.zig`)

| Test | Verifies |
|---|---|
| Backend detection on macOS | Returns `pbcopy` under `builtin.os.tag == .macos`. |
| Backend detection prefers Wayland | With `$WAYLAND_DISPLAY` set, returns `wl_copy` before X11 tools. |
| Backend detection X11 fallback | `xclip` chosen; `xsel` when `xclip` absent. |
| No tool found | Returns `ClipboardToolNotFound`. |
| argv builders | Each backend produces the expected command + args for copy/read/clear. |

### Unit tests (`password.zig` / config resolution)

| Test | Verifies |
|---|---|
| Timeout precedence: flag wins | `--timeout=45` overrides config and default. |
| Timeout precedence: config wins | No flag → uses `clipboard_timeout` config. |
| Timeout precedence: default | No flag, no config → 20. |
| `--timeout=0` skips clear | Resolution yields the "no auto-clear" path (no blocking scheduled). |
| `--copy` masks output | Printed entry still shows `****`; plaintext never in stdout. |

### Integration tests (gated; require a clipboard tool + display)

Guarded so CI without a display/tool skips them cleanly.

| Test | Verifies |
|---|---|
| copy → read round-trip | `copy` then `read` returns the same bytes. |
| safe clear when unchanged | After copy, `clear` empties the clipboard. |
| safe clear leaves changed content | Copy, then externally overwrite, then safe-clear leaves the new content. |
| end-to-end `show --copy --timeout=0` | Password lands on the clipboard; command returns without blocking. |

---

## Out of scope (v1)

- **Restoring previous clipboard contents** after auto-clear — deferred (needs save/restore and
  interacts poorly with safe-clear; revisit if requested).
- **Field selection** (copying username/url) — deferred; v1 copies the password only.
- **A standalone `tip password copy` subcommand** — deferred; `show --copy` covers the need.
- **Detached/background clearer process** — deferred; foreground blocking + `&` covers it.
- **TOTP/OTP copy** — out of the password-manager MVP entirely.
- **Clipboard history managers interaction** (e.g. suppressing entry in KDE Klipper) — not
  handled; documented as a known caveat.

---

## Next step

Write the checkbox implementation plan for this sub-project via the writing-plans skill.
No implementation yet.
