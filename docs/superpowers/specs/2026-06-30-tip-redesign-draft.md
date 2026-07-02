# Tip — Redesign Brainstorm Draft (WORKING DOC)

> **Status:** DRAFT / in-progress brainstorm. Design only — **no implementation yet.**
> **Date started:** 2026-06-30
> **Resume point:** Sub-project **00 (Naming & Conventions Charter)**, Question 2 — confirming
> the identifier table + two open sub-decisions (boolean prefix rule, constants casing).
> See [Open Questions](#open-questions--resume-here) at the bottom.

This file captures **everything** discussed so far so nothing is lost: the product vision,
the brutal review, the full decomposition into small checkbox plans, every naming suggestion
(code + flags), locked decisions, and where we stopped.

---

## 1. What we're building (the vision, from the docs)

A password + task manager called **Tip**, built in **Zig 0.16** (uses the new `std.Io` async model).

```
                         ╭──────────────╮
                         │    Vault     │  (work / personal / finance)
                         │  + metadata  │  encrypted at rest, auto-lock
                         ╰──────┬───────╯
                  ┌─────────────┴─────────────┐
            ╭─────▼─────╮               ╭──────▼──────╮
            │ Passwords │               │    Tasks    │
            │ +history  │               │ +tags +due  │
            │ +tags     │               │ +assigned   │
            ╰───────────╯               ╰─────────────╯

   Backends:  SQLite (the store)   │   Remote (HTTP server)   │   JSON = export/import ONLY
   Crypto: AES-256-GCM + Argon2id     Audit log + breach checks
```

- Data organized into **vaults**; each vault holds passwords + tasks.
- Encrypted at rest: **AES-256-GCM** + **Argon2id** key derivation; master password never stored.
- **Companion HTTP server** (REST API, JWT/OAuth) for remote mode + team sharing + sync.
- Future: web app, browser extension, TOTP, breach checks, import from 1Password/Bitwarden/LastPass.

### Current reality
- **821 lines of Zig.** Only the **task manager + JSON storage** exists (≈ Phase 2 of a 5-phase plan).
- Files:
  - `src/main.zig` — CLI entry, arg parsing via `flags` dep.
  - `src/core/task.zig` (654 lines) — task CRUD, dispatch, rendering, tests.
  - `src/core/models.zig` — `Task` struct.
  - `src/storage/json.zig` — `open_data_dir`, `load_tasks`, `save_tasks`.
  - `src/utils/generate.zig` — `uuid()` (misnamed; see naming).
  - `build.zig` — version gen from zon, auto-test-runner that globs `src/**/*.zig`.
- Dependency: `flags` (github.com/spikenardco/flags.zig).
- Tests: **11/11 passing** on Zig 0.16 (`zig build test --summary all`).
- `/usr/local/zig` is **0.16.0**.

### Docs present (under `docs/`)
ARCHITECTURE.md, CLI_REFERENCE.md, DOCUMENTATION_INDEX.md, FEATURES.md (1488 lines),
ROADMAP.md, SERVER_API.md, ZIG_IMPLEMENTATION_GUIDE.md (2532 lines).

> ⚠️ **Docs caveat:** ZIG_IMPLEMENTATION_GUIDE.md code uses **old Zig APIs** (`std.fs.cwd()`,
> `std.json.stringify(writer)`, `ArrayList.init(allocator)`) and references `zig-sqlite` loosely.
> The real code uses the new **0.16 `std.Io`** model. **Do not copy-paste the guide.**

---

## 2. Locked decisions

| # | Decision | Status |
|---|----------|--------|
| D1 | **SQLite is THE storage backend.** | LOCKED |
| D2 | **JSON is demoted to export/import ONLY** (no longer a storage mode). | LOCKED |
| D3 | **zig-sqlite supports Zig 0.16** (issue #204 closed via PR #201/master) → depend on zig-sqlite rather than vendoring the amalgamation + hand-writing a wrapper. Still needs SQLite C source + `linkLibC` (handled by its build.zig). | LOCKED |
| D4 | Build **all scopes**, but as **many small implementation plans as possible**, each with checkboxes. | LOCKED |
| D5 | Do sub-project **00 (naming charter) first**, **design only** — no code yet. Flow per item: design → rename-where-needed → redesign → spec → plan → next. | LOCKED |
| D6 | **Identifier casing = snake_case for functions** (option B). User explicitly prefers snake_case. | LOCKED |

### Still proposed / not yet confirmed
- The full identifier convention table (types PascalCase, fields snake_case, etc.) — see §6.
- Boolean prefix rule (`is_`/`has_`/`can_`/`should_`) — OPEN.
- Constants casing: lowercase `snake_case` vs `UPPER_SNAKE_CASE` — OPEN.

---

## 3. Brutal review (the whole product)

### Scope risk (biggest)
Docs describe a Bitwarden-sized product (vaults, E2E crypto, SQLite, HTTP server, web app,
browser extension, breach checks, importers, calendar, burndown, recurring tasks, dependencies,
subtasks, Slack notifications). Code is a **todo list**. **YAGNI ruthlessly**; park everything
non-core until the foundation ships.

### Hard problems the docs hand-wave
1. **Key session across processes.** Every `tip` run is a fresh process. "auto-lock / unlock /
   20s delay between attempts" imply a *session* surviving between invocations → needs a
   background agent, OS keyring, or an encrypted on-disk session token with TTL. **No design exists.**
   This is the hardest part of the whole product.
2. **Encryption + SQLite interaction.** If SQLite is the only store, how is it encrypted? Three
   very different paths:
   - (a) **SQLCipher** — whole-db encryption, needs a special C build.
   - (b) **App-level encrypted BLOB columns** — metadata leaks (row counts, timestamps, names).
   - (c) **Encrypt everything as one blob** — defeats the point of SQLite.
   Undecided; it shapes the entire schema. (Tracked in sub-project 10.)
3. **ID strategy is contradictory.** Docs show `--id=1` (integers); code generates time+random
   hex that **isn't a real UUID** (function misnamed `uuid`). Pick one: SQLite `rowid`, **ULID**,
   or **UUIDv7** (time-sortable). Touches every table + command. (Sub-project 01.)
4. **Schema migrations.** SQLite-only means we own schema evolution forever → need a
   `schema_version` table + migration runner from day one. (Sub-project 02.)
5. **`std.Io` (0.16 async) vs blocking C SQLite.** SQLite is synchronous blocking C; the async Io
   buys nothing there. Fine for a CLI — just be aware.

### Structural / correctness gaps in current code
- **Non-atomic writes.** `save_tasks` truncates then writes `tasks.json` → crash mid-write = data
  loss. (Moot once SQLite, but JSON *export* must still be atomic: temp + rename + fsync.)
- **No concurrency safety** in JSON mode (last-writer-wins). SQLite fixes this.
- **`mark_complete` exists + is tested but has NO `complete` subcommand wired up** — users can't
  complete a task today. Also no `start`.
- **Ambiguous-prefix matching duplicated 3×** (delete/show/edit) and **inconsistent**: `edit_task`
  returns the first prefix match with **no ambiguity check** → can edit the wrong task.
- **`priority: ?Priority = .low`** default contradicts the "no priority" display logic (treats null
  as none, but new tasks serialize as `.low`).
- **Silent error swallowing** everywhere (`catch {}`, `catch continue`, `catch return`).
- **Whole-file rewrite per op** is O(n) (fine small, bad large) — SQLite fixes.

### Missing from the docs entirely
- **Config file** design (referenced by `tip config set`, never specified).
- **Audit log** schema (promised, no model). Folds into sub-projects 06/10.
- **Soft delete / archive** column (you mention archiving completed tasks).
- **Backup/restore** for SQLite (file copy vs `VACUUM INTO` vs export).
- **Error taxonomy** (replace `catch {}` swallowing with a real error set + messages).
- **Testing strategy** — use in-memory SQLite (`:memory:`) per plan; current tests use tmpDir.

---

## 4. Naming analysis — CODE identifiers (brutal)

> Convention chosen: **snake_case functions** (D6). Types stay PascalCase.

| Current | Issue | Suggested |
|---|---|---|
| `generate.uuid()` | **Misleading** — not a UUID (timestamp + random hex concat) | `generate_id()` / `new_short_id()` (final form depends on ID strategy, sub-project 01) |
| `execute_commands()` | Vague verb + plural; actually dispatches one command | `dispatch_task_command()` / `run()` |
| `T: TaskArgs` (param) | `T` reads as a *type* param; it's a value | `args` |
| `color()` | Returns an ANSI escape string, not a `Color` | `ansi_code()` |
| `Color.reset` | `reset` isn't a color — two concepts conflated | rename enum `Ansi`, or split reset out |
| `priority_label()` | Returns a glyph `↑ / - / ↓`, not a label | `priority_glyph()` (mirror `status_icon`) |
| `unix_timestamp()` | OK but verbose | `now_seconds()` |
| `load_tasks` / `save_tasks` | fine as functions; become handle methods once SQLite | `store.load_tasks()` etc. (sub-project 03) |
| `open_data_dir` | fine | keep |

---

## 5. Naming analysis — CLI FLAGS (the real inconsistencies)

| Problem | Today | Decision needed / proposed fix |
|---|---|---|
| Same field, two flag names | `task add --name` vs `task edit --title` | **`--title` everywhere** (matches the model field) |
| Abbrev vs full, inconsistent | code `--desc`, docs `--description` | Standardize **`--desc`** (offer `--description` as alias) |
| Two verbs, one action | code `task show`, docs `task get` | Pick **one** (`show` = CRUD-read, or `get`) — not both |
| Create verb differs per noun | `vault init`, `password add`, `task add` | Use **`add`** (or `new`) consistently across all nouns |
| Switch verb | `vault switch` | `switch` ok; `use` reads better — just be consistent |
| ID semantics | docs `--id=1` vs hex string in code | One ID format, documented (sub-project 01) |
| Negative flags | `--no-numbers`, `--no-symbols`, `--no-ambiguous` | Acceptable CLI idiom; keep but document the pattern |
| Doc copy-paste bug | "tip password category list" appears inside the **Task** Categories section in FEATURES.md | fix docs |

### Global flags already drafted in CLI_REFERENCE.md (review during sub-project 05)
`--config=<path>`, `--mode=<local|remote>`, `--storage=<json|sqlite>` (note: `--storage` becomes
moot/limited once JSON is export-only — D2), `--vault=<name>`, `--verbose`, `--quiet`, `--help`,
`--version`.

---

## 6. Sub-project 00 — Naming & Conventions Charter (IN PROGRESS)

**Goal:** a decisions-only charter (spec) + a small checkbox plan to apply renames to existing
task code. ~30 min of actual work later; zero new behavior.

### Proposed identifier convention table (NOT yet confirmed — Q2)

| Kind | Rule | Example |
|---|---|---|
| Functions | `snake_case` | `add_task`, `load_tasks` |
| Variables / params | `snake_case` | `task_id`, `created_at` |
| Struct fields | `snake_case` | `due_date`, `completed_at` |
| Types (struct/enum/union) | `PascalCase` | `TaskArgs`, `Status` |
| Enum members | `snake_case` | `.in_progress`, `.high` |
| Constants (values) | `snake_case` **or** `UPPER_SNAKE_CASE` | **OPEN** |
| Compile-time/global "type-like" consts | `PascalCase` | `Color`, `Task` |
| Error sets / members | `PascalCase` set + member | `error.EmptyTitle` |
| Booleans | affirmative `is_`/`has_`/`can_`/`should_` prefix | `is_locked`, `has_due_date` — **OPEN** |
| Files / modules | `snake_case.zig` | `task.zig`, `json.zig` |

### Two open sub-decisions inside 00
1. **Boolean prefix rule** — adopt `is_`/`has_`/`can_`/`should_`? (e.g. `T.list` bool → `list_all`,
   or leave CLI-facing bools alone and only apply internally.)
2. **Constants casing** — lowercase `snake_case` (Zig-std-leaning) vs `UPPER_SNAKE_CASE`.

### 00 deliverables (when we resume)
- [ ] Confirm identifier table + 2 open sub-decisions.
- [ ] Lock the flag-naming rules from §5 (title/desc/show-or-get/add verb).
- [ ] Write the charter spec to `docs/superpowers/specs/`.
- [ ] Write a checkbox implementation plan (the renames to apply later).

---

## 7. Full decomposition map (all scopes → tiny checkbox plans)

Each box = one short spec + one checkbox plan. Dependencies flow top-down. Ship one at a time.

```
FOUNDATION (first; unblocks everything)
 00  Naming & conventions charter  (flags + identifiers)        ← IN PROGRESS
 01  ID strategy (ULID / UUIDv7) + error taxonomy
 02  SQLite foundation: dep, build wiring, open, migrations
 03  Storage handle API + Tasks table (kill JSON storage)
 04  Wire complete/start; unified prefix-match + ambiguity

DATA & UX
 05  Config system + global flags (--vault/--config/--verbose...)
 06  Vaults (table, FK, vault cmds, --vault selection, default)
 07  Export/Import (JSON + CSV, atomic, merge, dry-run)
 08  Task filters/search/stats (FTS, list filters)
 09  Tags + categories + custom fields (shared model)

SECURITY (the hard middle)
 10  Crypto core: AES-256-GCM + Argon2id + encrypted columns
 11  Key-session model: unlock/lock/auto-lock across processes

PASSWORDS
 12  Password CRUD + history (5 versions)
 13  Password generation (lengths/passphrase/charsets)
 14  Strength + audit (weak/duplicate/age)
 15  Clipboard copy w/ timeout
 16  Breach check (HIBP k-anonymity)

REMOTE (largest, last)
 17  HTTP server skeleton + JWT auth
 18  REST endpoints (vaults/tasks/passwords)
 19  Sync engine + conflict resolution
 20  OAuth (GitHub/Google)

FUTURE / PARKED (YAGNI until core ships)
 web app, browser extension, TOTP, calendar, recurring tasks,
 dependencies, subtasks, templates, notifications, password sharing
```

Notes:
- **Audit log** folds into 06/10. **Testing** (in-memory SQLite) is a standing requirement in
  every plan, not its own box.
- The handle/`Store` API designed in 03 should be shaped so passwords/vaults slot in later
  *without* re-plumbing `allocator`/`io`/`db`/`vault_id` through every call (the param-bloat fix).

---

## 8. Storage API direction (for sub-project 03, captured now so we don't forget)

Replace threading `(allocator, io, dir, ...)` through every function with a **handle** that owns
context. Target ergonomics:

```zig
// one handle carries context; methods drop allocator/io/db/vault_id params
var vault = try Vault.open(gpa, io, .{ .name = "personal" });  // sqlite-backed
defer vault.close();

try vault.tasks.add(.{ .title = "x", .priority = .high });   // was 5 params → 1
const list = try vault.tasks.list(.{ .status = .pending });  // filter in SQL
try vault.tasks.complete(id);
```

- Unify the 3× duplicated prefix-match into one helper returning a typed result:
  `find_by_prefix(id) -> union { none, one: usize, many }` so ambiguity handling is identical
  across edit/delete/show/complete.
- Index lookups by id (SQLite PK / index) instead of linear scans.
- ⚠️ The `Storage(comptime T)` vtable in ZIG_IMPLEMENTATION_GUIDE.md **re-introduces param bloat**
  (every method takes `allocator` *and* `vault_id`). Prefer the handle shape above.

---

## 9. Reference facts (verified this session)

- **Zig version:** `/usr/local/zig` → **0.16.0**. `minimum_zig_version = "0.16.0"` in build.zig.zon.
- **Tests:** 11/11 pass (`zig build test --summary all`).
- **zig-sqlite + 0.16:** issue [#204](https://github.com/vrischmann/zig-sqlite/issues/204) is
  **CLOSED**; PR #201 / master build on 0.16. Install via
  `zig fetch --save git+https://github.com/vrischmann/zig-sqlite`, then in build.zig:
  `const sqlite = b.dependency("sqlite", .{...}); exe.root_module.addImport("sqlite", sqlite.module("sqlite"));`
- SQLite is **public domain** (vendoring also fine if we ever drop the wrapper).
- zig-sqlite maintainer is on a break but keeps it building for latest Zig; it offers comptime
  bind-param checks + struct row mapping.

---

## 10. Open questions / RESUME HERE

We stopped mid sub-project **00**, at **Question 2**. To resume, answer these:

1. **Confirm the identifier table** in §6 (or adjust).
2. **Boolean prefix rule:** adopt `is_`/`has_`/`can_`/`should_`? Apply to CLI-facing bools too,
   or internal only?
3. **Constants casing:** lowercase `snake_case` or `UPPER_SNAKE_CASE`?
4. **Flag rules (from §5):** confirm `--title` everywhere, `--desc` (with `--description` alias),
   and pick `show` **or** `get` for read, and the create verb (`add` vs `new`).

After those are answered:
- Finalize the 00 charter spec → write to `docs/superpowers/specs/2026-06-30-naming-conventions-charter.md`.
- Write the 00 checkbox plan (renames to apply).
- Move to sub-project **01 (ID strategy + error taxonomy)**.

### Process reminder (how we're working)
Per item: **design → rename-where-needed → redesign → spec → plan → move to next.**
**No implementation yet.** One brainstorming question at a time.
