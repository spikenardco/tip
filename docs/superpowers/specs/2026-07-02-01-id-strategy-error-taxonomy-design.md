# Sub-project 01 — ID Strategy + Error Taxonomy (DESIGN)

> **Status:** DESIGN APPROVED. Design only — **no implementation yet.**
> **Date:** 2026-07-02
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 00 (Naming & Conventions Charter) — DONE; renames already
> applied in code (`generate_id`, `ansi_code`, `priority_glyph`, `now_seconds`, `TaskArgs`,
> enum `Ansi`).
> **Successors this unblocks:** 02 (SQLite foundation / migrations), 03 (Storage handle +
> Tasks table), 04 (unified prefix-match + ambiguity).

This sub-project settles two foundational questions that touch every table and command:
**what identity rows carry**, and **how errors are modeled, rendered, and exited on**.

---

## Locked decisions (this sub-project)

| # | Decision | Status |
|---|----------|--------|
| E1 | **IDs are ULIDs** (48-bit ms timestamp + 80 bits randomness), Crockford base32, 26 chars. | LOCKED |
| E2 | **Stored as SQLite `TEXT` `PRIMARY KEY`.** Lexicographic sort = chronological. | LOCKED |
| E3 | **One id per call, CSPRNG randomness, no monotonic counter.** `created_at` breaks display ties. | LOCKED |
| E4 | **Prefix matching via `WHERE id LIKE 'prefix%'`,** resolved by the unified prefix-matcher (sub-project 04). | LOCKED |
| E5 | **Error sets are domain-grouped** (`ValidationError`, `TaskError`, `StorageError`, …), merged with `||`. | LOCKED |
| E6 | **User vs internal split:** expected errors print a clean one-liner; internal errors print a terse fixed line (detail behind `--verbose` later). | LOCKED |
| E7 | **Semantic exit codes:** `0` ok · `1` internal · `2` usage · `3` not found · `4` validation/conflict. | LOCKED |
| E8 | **Central error handling in `main.zig`;** commands only `return error.X`. Replaces all `catch {}` / `catch continue` / `catch return`. | LOCKED |

---

## Part A — ID strategy

### Format
- **ULID**: 48-bit millisecond Unix timestamp + 80 bits of randomness.
- Encoded as **Crockford base32**, fixed **26 characters**, uppercase, case-insensitive on read.
- Chosen over SQLite `rowid` (not globally unique, ids reused after delete, leaks row counts —
  bad for the eventual sync/remote work in 17–19) and over UUIDv7 hex (harder to type/read in a
  terminal). ULID keeps global uniqueness + time-sortability while being the most typeable option.

### Storage
- SQLite column: `id TEXT PRIMARY KEY`.
- Base32 lexicographic order equals chronological order, so `ORDER BY id` yields creation order
  with no separate sort key.
- Readable in the `sqlite3` shell (debuggability) and directly usable with `LIKE` for prefix
  matching.
- Size (26 bytes/row + index) is irrelevant at this scale. A future BLOB (16-byte) migration
  stays possible via the schema versioning that lands in sub-project 02, if a large remote
  deployment ever justifies it.

### Generation
- One id generated per `tip` invocation in the common case.
- Randomness from a **CSPRNG** (`io.random` / `std.crypto`), never a seeded PRNG — ids partly
  gate password-manager objects later, so do it right from day one.
- **No monotonic mode.** 80 random bits make same-millisecond collisions astronomically unlikely
  even during bulk import; where creation order matters for display within the same ms, `created_at`
  is the tie-break. Revisit only if bulk import (sub-project 07) ever shows ordering artifacts.
- `generate_id` is redesigned from its current `{millis:x}{rand64:x}` concat into a real ULID
  encoder.

### CLI ergonomics
- Users rarely type a full 26-char id. Lookups accept a **prefix**, matched with
  `WHERE id LIKE 'prefix%'`.
- Prefix resolution (unique vs none vs ambiguous) is owned by the **unified prefix-matcher**
  designed in sub-project 04, which returns a typed result (`none` / `one` / `many`). This
  sub-project only commits to the id format and the `LIKE`-friendly storage that makes it work.
- Display shows a short id prefix; the ambiguous case surfaces the `many` result for formatting.

### Migration note
- Existing hex ids live only in pre-SQLite JSON data. Converting/importing them is handled by the
  JSON→SQLite move in **sub-project 03**, not here. This sub-project changes only the generator and
  the id contract.

---

## Part B — Error taxonomy

### Structure
- **Domain-grouped error sets** that merge with `||` as needed:
  - `ValidationError` — user input problems (`EmptyTitle`, …).
  - `TaskError` — task-domain outcomes (`TaskNotFound`, `AmbiguousPrefix`, …).
  - `StorageError` — the internal/unexpected bucket (`StorageFailure`, IO/SQLite failures, …).
  - Reserved for later sub-projects: `CryptoError`, `VaultError`, `ServerError`.
- Each domain owns a `describe(err) -> []const u8` (clean user message) and contributes to a
  shared `exit_code` mapping. Domain-local `switch`es stay exhaustive and don't rot into a
  grab-bag as the product grows.

### Expected (user) vs unexpected (internal)
- **Expected/user errors** (`EmptyTitle`, `TaskNotFound`, `AmbiguousPrefix`): print a clean
  one-line message to stderr, no Zig internals. e.g. `error: no task matches "3f"`.
- **Unexpected/internal errors** (`StorageFailure`, OOM, SQLite/IO): print a fixed terse
  "something went wrong" line now. Raw detail is gated behind `--verbose` **later** (sub-project
  05); until that flag exists, internal errors always print terse.
- A `kind(err)` predicate (or simply "is it in the internal domain") lets `main` choose behavior
  and reserves exit code `1` for the internal bucket.

### Exit codes (semantic)
| Code | Meaning | Example triggers |
|------|---------|------------------|
| `0` | success | — |
| `1` | internal / unexpected | `StorageFailure`, OOM, SQLite/IO |
| `2` | usage / bad args | unknown flag/subcommand, missing required arg |
| `3` | not found | `TaskNotFound` |
| `4` | validation / conflict | `EmptyTitle`, `AmbiguousPrefix` |

Codes line up with the domain groups so the mapping is mechanical.

### Central handling
- Commands only ever `return error.X` — they do not print or exit.
- A single top-level handler in `main.zig` does `switch (err)` → `describe` → write to stderr →
  set `exit_code(err)`.
- This is the mechanism that eliminates every scattered `catch {}` / `catch continue` /
  `catch return` currently in the code.

---

## Out of scope (deferred on purpose)
- **`Diagnostic` context struct** (rich messages like "`3f` matches 4 tasks") — revisit in
  sub-project 04 if the prefix-matcher's typed result isn't enough to format good messages.
- **`--verbose` detail plumbing** — sub-project 05.
- **Concrete SQLite error surface** — sub-projects 02/03.
- **JSON→SQLite id data migration** — sub-project 03.

---

## Next step
Per the working process (design → rename-where-needed → redesign → spec → **plan** → next),
the next action is to write the checkbox implementation plan for this sub-project via the
writing-plans skill. **No implementation yet.**
