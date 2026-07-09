# Sub-project 07 — Export/Import (DESIGN)

> **Status:** DESIGN APPROVED
> **Date:** 2026-07-04
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 06 (Vaults)
> **Successor:** 08 (Task filters/search/stats)

This sub-project adds export (JSON, single vault or all vaults) and import (new vault,
restore into existing, merge) commands, with atomic file writes and a dry-run preview
mode for import.

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| 07-1 | **Primary use case:** backup & restore (not data portability). CSV deferred. | LOCKED |
| 07-2 | **Export format:** JSON only. Single consistent format with `version`, `exported_at`, `vaults[]` array. Always wrapped in `vaults` array (even for single-vault export). | LOCKED |
| 07-3 | **Scope:** single vault or all vaults (`--all` flag). | LOCKED |
| 07-4 | **Import modes:** `new` (default, creates a new vault from backup), `restore` (--vault, replaces all tasks), `merge` (--vault --merge, skips duplicate IDs). | LOCKED |
| 07-5 | **Dry-run:** `--dry-run` on import — parse file, compare against store, print preview, exit without writing. | LOCKED |
| 07-6 | **Atomic writes:** temp file + rename for export output. Import uses SQLite transactions. | LOCKED |
| 07-7 | **Import default (new vault):** uses vault name from backup. Error if vault with that name already exists. | LOCKED |
| 07-8 | **Import restore:** deletes all existing tasks in target vault, inserts backup tasks. Destructive — wrapped in a transaction. | LOCKED |
| 07-9 | **Import merge:** `INSERT OR IGNORE` — skips tasks where ID already exists. | LOCKED |
| 07-10 | **Export auto-naming:** `<vault-name>-<YYYY-MM-DD>.json` in cwd. `--output` overrides. | LOCKED |
| 07-11 | **Export all:** one file per vault in cwd (or `--output=<dir>`). | LOCKED |

---

## Part A — Export file format

```json
{
  "version": 1,
  "exported_at": 1749043200,
  "vaults": [
    {
      "name": "personal",
      "id": "00000000000000000000000000",
      "created_at": 1749000000,
      "tasks": [
        {
          "id": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
          "vault_id": "00000000000000000000000000",
          "title": "Buy groceries",
          "description": null,
          "status": "pending",
          "priority": null,
          "due_date": null,
          "assigned_to": null,
          "created_at": 1749043000,
          "updated_at": null,
          "completed_at": null
        }
      ]
    }
  ]
}
```

- `version` (integer): schema version for forward compatibility. Import rejects files with
  `version > current`.
- `exported_at` (i64): unix timestamp of export.
- `vaults` (array): always an array, even for single-vault export. Each element has the
  vault's metadata and its full task list.
- Tasks use the same field names as `models.Task` for direct `std.json` deserialization.

---

## Part B — CLI surface

### Export

| Command | Behavior |
|---|---|
| `tip export` | Export active vault → `<name>-<YYYY-MM-DD>.json` in cwd |
| `tip export --vault=<name>` | Export specific vault |
| `tip export --all` | Export all vaults, each to its own file |
| `tip export --output=<path>` | Custom output — file for single vault, directory for `--all` |

### Import

| Command | Behavior |
|---|---|
| `tip import --file=<path>` | Create new vault from backup. Error if vault name already exists. |
| `tip import --file=<path> --vault=<name>` | Restore into existing vault — delete its tasks, insert backup tasks. |
| `tip import --file=<path> --vault=<name> --merge` | Merge into existing vault — skip tasks with duplicate IDs. |
| `tip import --file=<path> --dry-run` | Preview what would be created/modified. No writes. |
| `tip import --file=<path> --vault=<name> --dry-run` | Preview restore/merge without writing. |

### Output messages

| Scenario | Message |
|---|---|
| Export single vault | `Exported <name> to <filename>` |
| Export all vaults | `Exported 3 vaults to <dir>` |
| Import new vault | `Imported <name> (12 tasks) as new vault` |
| Import restore | `Restored <name> (12 tasks replaced)` |
| Import merge | `Merged into <name> (3 added, 1 skipped)` |
| Import dry-run (new) | `Would create vault '<name>' with 12 tasks` |
| Import dry-run (restore) | `Would replace 5 tasks in '<name>' with 12 from backup` |
| Import dry-run (merge) | `Would add 3 tasks to '<name>' (1 skipped as duplicate)` |

---

## Part C — Import behavior detail

### `new` mode (default)

1. Parse the import file.
2. Check version compatibility (`<= current`).
3. For each vault in the file:
   a. Check if a vault with that `name` already exists. If yes → error `ImportVaultExists`.
   b. Generate a new ULID for the vault (fresh identity — the backup's `id` is preserved
      in the file but not used).
   c. Create the vault row.
   d. Insert each task with its original `id` (ULIDs are globally unique) and the new
      vault's id.
   e. All inserts happen in a single transaction.

### `restore` mode (`--vault=<name>`)

1. Validate the target vault exists → error `ImportTargetNotFound`.
2. Parse the import file.
3. In a transaction:
   a. `DELETE FROM tasks WHERE vault_id = ?`
   b. Insert all tasks from the backup into the target vault.
4. Idempotent: restoring the same backup twice produces the same result.

### `merge` mode (`--vault=<name> --merge`)

1. Validate target vault exists.
2. For each task in the backup, `INSERT OR IGNORE INTO tasks (...)` — if `id` already
   exists in the target vault, skip.
3. Non-destructive.

### Dry-run

1. Parse file, validate.
2. Compare vault names against the store.
3. Print what would happen per vault (new/restore/merge counts).
4. Exit cleanly without writing.

---

## Part D — File layout

| File | Responsibility |
|---|---|
| `src/core/export.zig` (NEW) | `ExportOptions`, `export_vaults(store, allocator, opts)` |
| `src/core/import.zig` (NEW) | `ImportMode`, `ImportOptions`, `import_from_file(store, allocator, opts)` |
| `src/core/models.zig` (MODIFY) | Add `ExportFile` and `ExportedVault` structs for the file format |
| `src/core/errors.zig` (MODIFY) | Add export/import error members |
| `src/main.zig` (MODIFY) | Add `export`/`import` to Args command union + dispatch |

### Module: `src/core/export.zig`

```zig
pub const ExportOptions = struct {
    vault: ?[]const u8 = null,
    all: bool = false,
    output: ?[]const u8 = null,
};

pub fn export_vaults(store: *Store, allocator: std.mem.Allocator, opts: ExportOptions) !void
```

### Module: `src/core/import.zig`

```zig
pub const ImportMode = enum { new, restore, merge };

pub const ImportOptions = struct {
    file_path: []const u8,
    mode: ImportMode = .new,
    target_vault: ?[]const u8 = null,
    dry_run: bool = false,
};

pub fn import_from_file(store: *Store, allocator: std.mem.Allocator, opts: ImportOptions) !void
```

---

## Part E — Error taxonomy

| Error | Raised when |
|---|---|
| `ExportFileExists` | Output file already exists |
| `ImportFileNotFound` | `--file` path doesn't exist |
| `ImportInvalidFormat` | File isn't valid JSON or missing required fields |
| `ImportVersionMismatch` | Export `version > current` (from the future) |
| `ImportVaultExists` | `--mode=new` but vault name already in store |
| `ImportTargetNotFound` | `--vault` specified but vault doesn't exist |

---

## Part F — Testing

| Test | Verifies |
|---|---|
| Export single vault | JSON file created with correct structure |
| Exported JSON round-trips through import (new) | Tasks match after export → import |
| Export all vaults | One file per vault |
| Export with custom `--output` path | File at specified path |
| Import new vault with unique name | Vault created with fresh ULID, all tasks present |
| Import new vault with existing name | `ImportVaultExists` error |
| Import restore replaces tasks | Old tasks gone, backup tasks present |
| Import merge skips duplicates | Existing task unchanged, new tasks added |
| Import dry-run (new) | Preview printed, no rows written |
| Import dry-run (restore) | Preview printed, no DELETE/INSERT |
| Import file not found | `ImportFileNotFound` |
| Import invalid JSON | `ImportInvalidFormat` |
| Export file exists | `ExportFileExists` |

---

## Out of scope

- CSV export/import (future).
- Export of future data types (passwords, tags — deferred).
- Encrypted export (future — ties into crypto sub-project).
- Import from other tools (1Password, Bitwarden).
- `--force` to overwrite existing export files (add if needed, trivial).
- Backup of vault metadata beyond name/id/created_at.

---

## Next step

Write the checkbox implementation plan for this sub-project via the writing-plans skill.
