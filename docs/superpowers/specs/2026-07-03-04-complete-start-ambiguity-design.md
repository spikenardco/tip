# Sub-project 04 — Wire `complete`/`start` CLI + Ambiguity UX (DESIGN)

> **Status:** IMPLEMENTED WITH DEVIATIONS. Current commands use exact IDs. Prefix matching and ambiguity UX remain planned.
> **Date:** 2026-07-03
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 03 (Storage handle API + tasks table) — design and plan done
> **Successor:** 05 (Config system + global flags)

This sub-project wires the `complete`/`start` handle methods (from sub-project 03) into CLI subcommands, and improves the ambiguous prefix error UX to include a match count.

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| 04-1 | **`complete`/`start` CLI subcommands** use `--id=<id>`. | IMPLEMENTED |
| 04-2 | **Prefix matching** may later return a plain error with a count. | DEFERRED |
| 04-3 | **Exact-ID lookup** uses the active `Tasks.get` API. | IMPLEMENTED |
| 04-4 | **`AmbiguousPrefix`** remains reserved in the error taxonomy. | DEFERRED |

---

## Part A — CLI subcommands: `complete` and `start`

### Flag interface

```
tip task complete --id=<id>
tip task start    --id=<id>
```

The `--id` value is an exact task ID. The active `Tasks.get` method uses `WHERE id = ?`. Prefix matching is not implemented.

### Dispatch behavior

Call the corresponding `Tasks` method (`complete`/`start`). On success, the current dispatcher performs the status operation. Confirmation output remains deferred.

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

The active `Tasks.get` method performs exact-ID lookup. It does not return `error.AmbiguousPrefix` for prefixes.

### New behavior

If prefix lookup is added later, the intended ambiguity message is:

```
Error: 4 tasks match prefix "abc". Be more specific.
```

The exit-code policy will be decided when prefix lookup is implemented.

### Intended future scope

If prefix lookup is implemented, every subcommand that takes `--id` should benefit: `edit`, `delete`, `show`, `complete`, and `start`.

---

## Part C — File changes

| File | Change |
|------|--------|
| `src/core/task.zig` | Add `complete`/`start` to `TaskArgs` union, add dispatch arms, and update help text. Prefix handling remains deferred. |

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
| `prefix ambiguity message` | Future test. Add two tasks with same prefix and verify the message contains the match count. |

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

## Baseline record (2026-08-01)

- `TaskArgs` includes `complete` and `start`, and dispatch calls the corresponding Tasks
  methods.
- The active command contract is exact IDs. This is intentional: no prefix ambiguity exists in
  the current implementation, and no `LIKE` lookup or ambiguity-count UX was added.
- The design's confirmation output and CLI-level ambiguity handling are not current behavior.
- The implementation has a known timestamp/status defect in the underlying `complete`/`start`
  SQL; the two related tests fail in the current baseline.

## Next step

Writing the checkbox implementation plan for this sub-project via the writing-plans skill is
complete; prefix ambiguity remains intentionally unresolved.
