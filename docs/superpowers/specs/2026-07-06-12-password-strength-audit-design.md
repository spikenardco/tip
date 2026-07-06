# Sub-project 12 — Password Strength + Audit (DESIGN)

> **Status:** DESIGN APPROVED
> **Date:** 2026-07-06
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 11 (Password CRUD + Generation)
> **Successor:** TBD

This sub-project adds password strength evaluation (scoring individual passwords)
and password audit (scanning all stored entries for weaknesses, duplicates, and
stale entries). It extends SP11's password module and reuses its encryption layer.

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| 12-1 | **Both strength + audit in one sub-project.** `strength` scores a single password; `audit` scans all stored entries. | LOCKED |
| 12-2 | **Strength criteria:** length + character variety + entropy + common patterns (sequential, keyboard, repeated). Dictionary/breach checking deferred. | LOCKED |
| 12-3 | **Score output:** numeric 0-100 + label (Weak / Fair / Strong / Very Strong). No per-criterion breakdown in v1. | LOCKED |
| 12-4 | **Audit checks:** weak passwords, duplicates, stale entries (not updated in 180+ days). | LOCKED |
| 12-5 | **CLI structure:** `tip password strength --password=<pwd>` for ad-hoc scoring, `tip password show <id> --strength` for stored entries, `tip password audit` for full scan. | LOCKED |
| 12-6 | **Architecture:** modular — `password_strength.zig` (scorer) and `password_audit.zig` (audit consumer). | LOCKED |
| 12-7 | **No HIBP / breach check** in v1. Deferred. | LOCKED |
| 12-8 | **`show --strength` flag.** Appends strength score to `password show` output. | LOCKED |
| 12-9 | **Audit requires unlocked vault.** Same constraint as all password commands (SP11-4, SP11-9). | LOCKED |

---

## Part A — Strength scoring algorithm

### File: `src/core/password_strength.zig`

```zig
pub const StrengthResult = struct {
    score: u8,           // 0-100
    label: Label,        // weak | fair | strong | very_strong
    flags: []const Flag, // what the password has / what was detected
};

pub const Label = enum { weak, fair, strong, very_strong };

pub const Flag = union(enum) {
    length_ok,
    variety_ok,
    sequential_pattern: []const u8,  // e.g. "123", "abc"
    repeated_char: u8,
    keyboard_pattern: []const u8,    // e.g. "qwerty", "asdf"
    too_short,
    no_uppercase,
    no_lowercase,
    no_digit,
    no_symbol,
};
```

### Scoring breakdown

| Category | Max pts | Details |
|---|---|---|
| Length | 30 | 0 pts for <8 chars, 10 for 8-11, 20 for 12-15, 30 for 16+ |
| Character variety | 25 | +7 per class present (upper, lower, digit, symbol), max 25 |
| Entropy bonus | 15 | Scale `log2(charset_size ^ length)` to 0-15 |
| Pattern penalties | -30 max | -10 sequential, -10 keyboard, -10 repeated (capped at -30 total) |

### Label thresholds

| Range | Label |
|---|---|
| 0-39 | Weak |
| 40-64 | Fair |
| 65-84 | Strong |
| 85-100 | Very Strong |

### Pattern detection helpers

All in `password_strength.zig`, package-private:

- `find_sequential(slice)` — detect runs of 3+ consecutive chars ("abc", "123", "bcd", "xyz")
- `find_keyboard_pattern(slice)` — detect QWERTY row patterns ("qwerty", "asdf", "zxcv")
- `find_repeated_chars(slice)` — detect 3+ identical adjacent chars ("aaa", "1111")
- `estimate_entropy(slice)` — estimate charset size and compute bits of entropy

### Interface

```zig
pub fn score(allocator: Allocator, password: []const u8) StrengthResult
```

Pure function — no I/O, no dependencies beyond the standard library.

---

## Part B — Audit module

### File: `src/core/password_audit.zig`

```zig
pub const AuditReport = struct {
    total: usize,
    weak: []const AuditEntry,
    fair: []const AuditEntry,
    duplicates: []const DuplicateGroup,
    stale: []const AuditEntry,
};

pub const AuditEntry = struct {
    id: []const u8,
    title: []const u8,
    score: u8,
    label: Label,
    flags: []const Flag,
    days_since_update: ?i64,
};

pub const DuplicateGroup = struct {
    passwords: []const AuditEntry,
    count: usize,
};
```

### Audit logic

1. Load all passwords in the active vault (via SP11's storage layer)
2. For each entry, decrypt and run `password_strength.score()`
3. Group by decrypted plaintext to find duplicates (encrypted values differ due to random nonces)
4. Flag entries where `updated_at` is >180 days ago as stale
5. Return sorted report (weakest first)

**Constraint:** Audit requires the vault to be unlocked (same as SP11's `password show`). If locked, return `VaultLocked` error.

### Interface

```zig
pub fn audit(allocator: Allocator, io: std.Io, dir: std.Io.Dir, vault_id: []const u8) !AuditReport
```

---

## Part C — CLI surface

### New subcommands (extending SP11's `PasswordArgs`)

```
tip password strength --password=<pwd>    Score a password
       [--verbose]                        Show flags/pattern details

tip password show <id> --strength         Score a stored password
                                          (appends score to show output)

tip password audit                        Scan all entries in active vault
       [--min-score=weak|fair]
       [--vault=<name>]
```

### Example output

**`password strength --password="Hello123!"`**
```
Score: 72/100 — Strong
```

**`password strength --password="Hello123!" --verbose`**
```
Score: 72/100 — Strong
Flags: length_ok, variety_ok, no_sequential, no_keyboard_pattern, no_repeated
```

**`password show <id> --strength`** (appends to normal show output):
```
Title:     github
Username:  ben
Password:  ****
URL:       https://github.com
Updated:   2 min ago

Password strength: 72/100 — Strong
```

**`password audit`**
```
Audit Report - Vault: personal
─────────────────────────────────────
Weak passwords:   3
Fair passwords:   5
Strong passwords: 12
Duplicate groups: 2
Stale entries:    4

Weak passwords:
  abc1234  github         score: 32 (Weak)
  def5678  bank_login     score: 18 (Weak)

Duplicate passwords:
  github, aws-console     same password
  email, slack            same password

Stale (not updated in 180+ days):
  old_blog                last updated 342 days ago
```

---

## Part D — File architecture

### New files

| File | Responsibility |
|---|---|
| `src/core/password_strength.zig` | `score()` function, `StrengthResult`, pattern detection |
| `src/core/password_audit.zig` | `audit()` function, `AuditReport`, display formatting |

### Modified files

| File | Change |
|---|---|
| `src/core/password.zig` | Add `strength` subcommand + `--strength` flag on `show`; add `audit` subcommand to `PasswordArgs` and dispatch |
| `src/core/models.zig` | No changes needed |

### Dependency graph

```
password.zig (CLI dispatch)
  ├── password_strength.zig (scoring)
  └── password_audit.zig (scanning)
        └── password_strength.zig (scoring, imported)
```

---

## Part E — Error taxonomy (extends SP01/SP11)

| Error | Raised when |
|---|---|
| `EmptyPassword` | `strength` command with empty password |
| `AuditEmptyVault` | `audit` on a vault with no passwords |
| `PasswordNotFound` | `show --strength` with nonexistent id |

---

## Part F — Testing

### Strength tests (in `password_strength.zig`)

| Test | Verifies |
|---|---|
| Empty string | Score 0, label Weak |
| Very short (<8 chars) | Score in Weak range |
| Long with all character classes | Score in Very Strong range |
| Sequential pattern "abcdef" | Flag detected, score penalized |
| Keyboard pattern "qwerty" | Flag detected, score penalized |
| Repeated chars "aaa" | Flag detected, score penalized |
| All character classes present | Variety bonus applied |
| Only lowercase | Missing uppercase/digit/symbol flags |
| Score threshold boundaries | 39=Weak, 40=Fair, 64=Fair, 65=Strong, 84=Strong, 85=Very Strong |
| Single char input | Handles edge case |
| Unicode/non-ASCII input | Skips pattern detection gracefully |

### Audit tests (in `password_audit.zig`)

| Test | Verifies |
|---|---|
| Audit empty vault | Report with zero entries |
| Audit with weak + strong passwords | Correct counts and grouping |
| Duplicate detection | Same encrypted value grouped |
| Stale detection | Entry with old updated_at flagged |
| `--min-score` filter | Only entries below threshold returned |
| Integration: add passwords → audit → verify report | Full end-to-end workflow |

### Integration tests

| Test | Verifies |
|---|---|
| Add weak password, audit, verify in weak list | End-to-end scoring + audit |
| Add duplicate passwords, audit, verify grouped | End-to-end duplicate detection |
| Add stale password, audit, verify flagged | End-to-end stale detection |

---

## Out of scope

- **HIBP / breach checking** — deferred (requires network call).
- **Dictionary word detection** — deferred (requires embedded word list).
- **Per-criterion score breakdown** in `strength` output — deferred (v1 shows score + label only).
- **Export audit report** to JSON/CSV — deferred.
- **Auto-remediate** (force password change for weak entries) — deferred.
- **Audit history** (tracking scores over time) — deferred.

---

## Next step

Write the checkbox implementation plan for this sub-project via the writing-plans skill.
No implementation yet.
