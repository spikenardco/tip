# Documentation Reconciliation Plan

## Overview

Bring the records under `docs/superpowers/**` into alignment with the current implementation and verified Zig 0.16.0 APIs. This is a documentation-only change: no product features or source behavior will be added while this plan is executed.

Current baseline:

- Tip is a local SQLite-backed task CLI.
- Implemented commands are `--help`, `--version`, `task --help`, `task --list`, `task add`, `task edit`, `task delete`, `task complete`, and `task start`.
- Storage uses a platform data directory and `<data path>/tip.db` with WAL and migrations.
- SP00-SP02 are implemented with documented API deviations; SP03 is partial; SP04 has `complete`/`start`, while exact ID lookup is intentional and prefix ambiguity handling is rejected as unnecessary complexity; SP05-SP14 are not implemented.
- Top-level docs are outside this change except for `README.md`, which is now explicitly included. Other top-level docs will not be touched, even when they contain the same drift.

## Documentation Policy

- Current behavior is authoritative from `src/`, `build.zig`, `build.zig.zon`, migrations, tests, and recent commits.
- Plans and specs remain historical design records, but their status, deviations, superseded decisions, and dependencies will be explicit.
- Future functionality stays documented only as planned, never as implemented.
- No source-code refactor is included.
- No new API or feature promises are introduced during documentation cleanup.
- Zig examples and statements will be checked against `/usr/local/zig` version `0.16.0`, `zig env`, and local standard-library source before being retained.

## Architecture Decisions

- Document the current architecture as `CLI -> platform data directory -> SQLite -> migration-managed tasks`.
- Describe `Vault` as the current database/service wrapper, not as a multi-vault domain model. Mark the planned `Store`/multi-vault architecture as future work.
- Treat `src/internal/database/migrations` as the current migration location.
- Record actual migration behavior: `_schema_version` is created by `migrate.zig`, migrations `001` and `002` are registered explicitly, and the current runner uses one transaction around the migration run.
- Document exact task IDs as the intentional behavior. Do not plan prefix lookup, ambiguity detection, match counts, or prefix-specific UX.
- Document that `complete` and `start` currently change status only; do not claim timestamp updates that source does not perform.
- Keep ANSI output documentation tied to current behavior. Mark the later output-layer ANSI-removal proposal as superseding future work, not current behavior.

## Work Plan

### Phase 1: Establish Current Baseline

1. Update `README.md` with the implemented command surface, exact-ID behavior, storage locations, current limits, and links to superpowers records.
2. Add a current-baseline/status section to the relevant redesign and sub-project records under `docs/superpowers/**`.
3. Leave all other top-level docs unchanged.

### Phase 2: Correct Zig 0.16 Guidance Inside Superpowers Records

1. Audit Zig-specific examples and claims inside `docs/superpowers/**` against project source and local Zig 0.16 source.
2. Correct examples that conflict with Zig 0.16, especially `std.process.Init`, `std.Io`, `std.Io.Dir`, `std.ArrayList`, `std.testing.io`, build APIs, `addTranslateC`, and deprecated `std.fs.path` guidance.
3. Add verified Zig 0.16 notes only to affected superpowers records; do not edit `docs/ZIG_IMPLEMENTATION_GUIDE.md`.

### Phase 3: Reconcile Superpowers Specs and Plans

For each record, retain original intent but add status and deviations based on current source.

1. Update the 2026-06-30 redesign draft: mark completed foundation work, replace obsolete “no implementation yet” text, update current files/tests, change `vault init` to `vault add` where superseded, change SP07 to JSON-only, and update the resume point.
2. Update SP01 ID/error plan and spec: actual `generate_id(io) [26]u8`, actual dispatch API, current error taxonomy, and incomplete raw-storage-error mapping.
3. Update SP02 SQLite plan and spec: actual migration filenames, ownership of `_schema_version`, actual `db.open` signature, explicit migration registration, and current transaction semantics.
4. Update SP03 storage plan and spec: current `Vault`/`Tasks` split, value ownership, removed JSON storage, exact-ID limitation, timestamp limitation, priority behavior, and partial completion status.
5. Update SP04 complete/start plan and spec: mark `complete`/`start` implemented, record exact ID lookup as the deliberate simplification, remove prefix matching and ambiguity requirements, and reconcile remaining help-text, confirmation-output, and exit-code documentation.
6. Mark SP05-SP14 as future/unimplemented and add a consistent “depends on current baseline” note. Correct only contradictions that would mislead future implementation, including migration paths, Store versus Vault assumptions, SQLite versus JSON password storage, exit-code ownership, checksum policy, lock semantics, session location, and API signature conflicts.
7. Mark the output-layer amendment as superseding the older ANSI extraction decision, while keeping implementation status unstarted.

### Phase 4: Verification and Quality Review

1. Run repository-wide searches for unsupported “implemented/current/complete” claims and stale paths such as `src/task.zig`, `pkg/`, `cmd/`, `PROJECT_OVERVIEW.md`, and nonexistent modules.
2. Check every command example against `src/main.zig` and `src/core/task.zig`.
3. Check every source-file link and heading index.
4. Validate code snippets and Zig API names against `/usr/local/zig/lib/std` and `zig version`.
5. Run `zig build test` to confirm documentation edits did not affect source/build state.
6. Review `git diff` and preserve the pre-existing unrelated modification in `docs/superpowers/plans/2026-07-03-03-storage-handle-tasks-table.md` unless the user explicitly requests its contents be reconciled in this pass. If that file is updated, preserve its unrelated user changes carefully.

## Acceptance Criteria

- No current documentation claims unavailable commands, server endpoints, encryption, password storage, multi-vault behavior, remote storage, or configuration support.
- Current command and architecture docs match source and migrations.
- Every superpowers plan/spec has an accurate implementation status and records material deviations or superseded decisions.
- Documentation consistently states that task commands require exact IDs; no prefix-ambiguity feature is promised.
- Zig documentation targets Zig `0.16.0` and does not recommend verified-deprecated APIs without warning.
- Broken links, stale source paths, contradictory status labels, and unsupported “production-ready” claims are removed or labeled.
- `zig build test` passes.
- No source files are changed by this documentation update.

## Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Historical specs are rewritten too aggressively | Future design context is lost | Preserve intent; add status/deviation sections instead of deleting history wholesale |
| Aspirational docs remain mistaken for current behavior | Users implement against false APIs | Use explicit “planned/unimplemented” labels and a current capability matrix |
| Contradictions across later plans remain | Future implementation repeats incompatible decisions | Normalize shared terms, migration paths, storage architecture, and error/exit-code ownership |
| Zig guidance drifts from installed compiler | Examples fail or teach deprecated APIs | Verify against `/usr/local/zig` source and run project tests |
| Existing user edit is overwritten | Unrelated work is lost | Inspect and preserve the dirty worktree change before touching that file |

## Files Expected To Change

- `README.md`
- `docs/superpowers/specs/*.md`
- `docs/superpowers/plans/*.md`
- `tasks/plan.md`
- `tasks/todo.md`

No files outside `README.md`, `docs/superpowers/**`, and `tasks/**` should change. In particular, do not edit any other top-level `docs/*.md`, files under `src/`, `build.zig`, `build.zig.zon`, migrations, or tests.

## Open Decision

This plan assumes the massive update is a reconciliation pass, not an implementation pass: future specs stay in `docs/superpowers/**` but are clearly marked future and internally consistent. Exact task IDs are intentional; prefix ambiguity handling is out of scope. Only `README.md` and `docs/superpowers/**` documentation may change; all other docs remain untouched.
