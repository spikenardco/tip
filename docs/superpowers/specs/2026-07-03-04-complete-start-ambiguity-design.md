# Sub-project 04 — Wire `complete`/`start` CLI + Ambiguity UX (DESIGN)

> **Status:** DESIGN APPROVED
> **Date:** 2026-07-03
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 03 (Storage handle API + tasks table) — design and plan done
> **Successor:** 05 (Config system + global flags)

This sub-project wires the `complete`/`start` handle methods (from sub-project 03) into CLI subcommands, and improves the ambiguous prefix error UX to include a match count.

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| 04-1 | **`complete`/`start` CLI subcommands** use `--id=<prefix>` flag, matching edit/delete/show pattern. | LOCKED |
| 04-2 | **Ambiguous prefix** returns a plain error with a count in the message. No interactive selection, no rich listing. | LOCKED |
| 04-3 | **Prefix match lives in `get_by_id`** — no extraction into a shared helper. | LOCKED |
| 04-4 | **Error message** formatted in the CLI layer (dispatch), not in the error taxonomy. `AmbiguousPrefix` stays as-is. | LOCKED |

---

## Part A — CLI subcommands: `complete` and `start`

### Flag interface

```
tip task complete --id=<prefix>
tip task start    --id=<prefix>
```

The `--id` value is a prefix; `get_by_id` resolves it (exact match first, then `LIKE 'prefix%'`). This is identical to how edit/delete/show resolve their `--id`.

### Dispatch behavior

Call the corresponding `Vault.Tasks` method (`complete`/`start`). On success, print a confirmation:

```
✓ Completed: Review code
⟳ Started: Review code
```

On `error.TaskNotFound`: "Task not found" (standard error path via `describe`/`exit_code`).
On `error.AmbiguousPrefix`: caught inline, formatted message described below.

### Help text update

Append to `TaskArgs.help`:

```
  complete
      --id=<id>             Mark a task as completed
  start
      --id=<id>             Mark a task as in progress
```

---

## Part B — Ambiguity UX

### Current state

`Vault.Tasks.get_by_id` returns `error.AmbiguousPrefix` when >1 task matches. The error taxonomy maps this to exit code 3 (not found) with a generic message.

### New behavior

When `get_by_id` returns `AmbiguousPrefix`, the CLI dispatch catches it and prints:

```
Error: 4 tasks match prefix "abc". Be more specific.
```

Exit code stays 3 (`NotFound` category). The error is caught at the CLI layer, not in the handle.

### Where this matters

Every subcommand that takes `--id` benefits: `edit`, `delete`, `show`, `complete`, `start`.

---

## Part C — File changes

| File | Change |
|------|--------|
| `src/core/task.zig` | Add `complete`/`start` to `TaskArgs` union; add dispatch arms; catch `AmbiguousPrefix` in dispatch; update help text |

No changes to:
- `src/core/vault.zig` (handle methods already exist from 03)
- `src/core/errors.zig` (error taxonomy unchanged)
- `src/core/models.zig`
- `src/utils/ansi.zig`

No new files.

---

## Part D — Testing

| Test | What it verifies |
|------|------------------|
| `complete dispatch` | Call `complete` with a full id, verify status changes to `completed` |
| `start dispatch` | Call `start` with a full id, verify status changes to `in_progress` |
| `prefix ambiguity message` | Add two tasks with same prefix, call any subcommand with short prefix, verify error message contains count |

These tests live in `src/core/task.zig` (alongside existing dispatch tests) or in `src/core/vault.zig` (alongside existing vault tests). The vault tests already cover `complete`/`start` at the handle level; this adds CLI-level integration tests.

---

## Out of scope

- **Config system** (`--verbose`, `--quiet`) — sub-project 05.
- **Vaults** (multi-vault, vault FK) — sub-project 06.
- **JSON export/import** — future sub-project.
- **Rich interactive selection** on ambiguity — consciously deferred. Just an error with count.
- **Extracting prefix matcher** — stays inside `get_by_id`.
- **`list --status` filter** — sub-project 08.

---

## Next step

Write the checkbox implementation plan for this sub-project via the writing-plans skill. No implementation yet.
