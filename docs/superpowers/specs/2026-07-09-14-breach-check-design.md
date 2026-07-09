# Sub-project 14 — Breach Check (DESIGN)

> **Status:** DESIGN APPROVED
> **Date:** 2026-07-09
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 13 (Password Clipboard Copy)
> **Successor:** 15 (HTTP Server Skeleton + JWT Auth)

This sub-project adds breach checking to Tip's password manager using a dual approach:
a local common-password hash set (bundled, offline) plus the Have I Been Pwned
k-anonymity API (online). Rejected in SP12 (decision 12-7) as deferred; now it ships.

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| 14-1 | **Dual check: local common-password set + HIBP k-anonymity.** Local is first (fast path, offline). HIBP is second (network, full coverage). | LOCKED |
| 14-2 | **Local list source:** SecLists 10k-most-common.txt (MIT license). Pre-hashed into SHA-1 digests at build time. | LOCKED |
| 14-3 | **Bundled data is committed to the repo** as `src/data/common_passwords.bin` (sorted `[20]u8` SHA-1 array). Source `.txt` committed alongside for traceability. | LOCKED |
| 14-4 | **No local cache update.** To refresh the common-password list, ship a new binary (patch release). No on-disk data directory. | LOCKED |
| 14-5 | **HIBP k-anonymity protocol:** send first 5 hex chars of SHA-1, get back suffix:count pairs, match locally. | LOCKED |
| 14-6 | **HIBP errors are non-fatal.** Network failure/timeout/rate-limit → skip HIBP for that password, mark as offline in report. | LOCKED |
| 14-7 | **Vault locked → VaultLocked error.** Same behavior as all password commands. | LOCKED |
| 14-8 | **No `--prompt` flag in v1.** Checking an unsaved password against breaches is deferred. Flagged for future. | LOCKED |
| 14-9 | **No periodic/background scanning.** Breach check is on-demand only. | LOCKED |

---

## Part A — CLI Surface

### Commands

**`tip password audit --breach-check`**

Batch checks all password entries in the active vault. Each password is checked
against the local common set, then (if not found) against HIBP. Results printed
as a table.

**`tip password check <name>`**

Single-entry breach check. Prints one line of output.

### Output format

Single check:
```
✓ github — not found in any breaches
✗ aws-root — found in 3 breaches (HIBP)
✗ password123 — common password (weak)
- aws-root — breach check unavailable (offline)
```

Batch audit:
```
 Breach Check Results — Vault "personal"
  Entry          | Local  | HIBP   | Breaches
 ────────────────┼────────┼────────┼─────────
  github         | ✓      | ✓      | 0
  aws-root       | —      | ✗      | 3
  password123    | ✗      | —      | common
  home-router    | —      | —      | offline
 ────────────────┼────────┴────────┴─────────
  4 checked · 2 breached · 1 common · 1 safe
```

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | All safe (no breaches found) |
| 1 | At least one password breached or common |
| 2 | No entries to check, or vault locked |

---

## Part B — Per-password check algorithm

```
1. Decrypt password field using vault session key (SP10)

2. Compute SHA-1 of plaintext password → full_hash (40 hex chars)

3. LOCAL CHECK:
   Binary search full_hash (as raw 20-byte digest) in bundled common_passwords.bin
   → FOUND    → mark "common password", output result (skip HIBP)
   → NOT FOUND → proceed to step 4

4. HIBP CHECK:
   a. Take first 5 hex chars of full_hash → prefix
   b. GET https://api.pwnedpasswords.com/range/{prefix}
   c. Parse response: each line is {suffix}:{count}
   d. Does full_hash suffix (last 35 chars) match any line?
      → FOUND    → mark "breached" with breach count
      → NOT FOUND → mark "safe"

5. Append result to report
```

---

## Part C — Bundled common-password data

### Source

**SecLists 10k-most-common.txt** (MIT license):
- `https://github.com/danielmiessler/SecLists`
- `Passwords/Common-Credentials/10k-most-common.txt`

### Generation

`scripts/generate-common-passwords.sh`:
1. Reads `src/data/10k-most-common.txt`
2. Computes SHA-1 digest (raw 20 bytes) per line
3. Sorts digests lexicographically
4. Writes concatenated `[20]u8` × N entries to `src/data/common_passwords.bin`

### Format

Sorted array of `[20]u8` SHA-1 digests, no header. ~200KB for 10K entries.

### Usage

```zig
const common_passwords = @embedFile("data/common_passwords.bin");
```

### Update procedure

1. Replace `src/data/10k-most-common.txt`
2. Run `scripts/generate-common-passwords.sh`
3. Commit both, bump patch version

---

## Part D — HIBP API

```
GET https://api.pwnedpasswords.com/range/{first5}
```

Response: `text/plain`, lines of `{suffix}:{count}`. Rate limit: 1 req/2s minimum.
Errors are non-fatal — network failure marks that entry as "offline".

---

## Part E — Module layout

| File | Role |
|------|------|
| `src/core/breach_check.zig` | Check logic + CLI dispatch + report formatting |
| `src/data/common_passwords.bin` | Bundled SHA-1 digests (generated, committed) |
| `src/data/10k-most-common.txt` | Source plaintext (MIT, committed) |
| `scripts/generate-common-passwords.sh` | Regenerate `.bin` from `.txt` |

---

## Part F — Testing

| Test | Verifies |
|------|----------|
| SHA-1 of known input | Deterministic hashing |
| Local match | Password in fixture → common |
| Local no-match | Password not in fixture → passes |
| HIBP URL construction | First 5 chars extracted |
| HIBP response parsing | Suffix:count parsed |
| HIBP match | Breach detected with correct count |
| HIBP no-match | Safe |
| Network failure | Offline status (not error) |
| Rate limit retry | Mock 429 → retry once |
| Full audit mixed results | 4 outcomes → correct report |
| Vault locked | VaultLocked error |
| No entries | Exit code 2 |

Tests use a small fixture `.bin` (5 entries) and mocked HTTP responses.

---

## Part G — Out of scope

- `--prompt` flag for unsaved passwords (flagged for future)
- Background/periodic scanning
- Non-HIBP breach databases
- Custom breach endpoints
- Breach check during import
