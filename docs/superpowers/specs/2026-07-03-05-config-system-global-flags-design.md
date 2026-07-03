# Sub-project 05 — Config System + Global Flags (DESIGN)

> **Status:** DESIGN APPROVED
> **Date:** 2026-07-03
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 04 (Wire `complete`/`start` CLI + ambiguity UX)
> **Successor:** 06 (Vaults)

This sub-project adds a ZON-based config file, `tip config` commands to manage it, and global flags (`--verbose`, `--quiet`, `--config`, `--vault`, `--mode`) that override config values. The config is loaded at startup and threaded through dispatch.

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| 05-1 | **Config format:** ZON (Zig Object Notation), parsed at runtime via `std.zon.parse.fromSliceAlloc`. Zero dependencies. | LOCKED |
| 05-2 | **Config location:** Platform config dir (XDG_CONFIG_HOME on Linux, `~/Library/Application Support` on macOS, `%APPDATA%` on Windows) with `--config=<path>` override. | LOCKED |
| 05-3 | **Global flags:** `--verbose`, `--quiet`, `--config=<path>`, `--vault=<name>`, `--mode=<local\|remote>`. | LOCKED |
| 05-4 | **Precedence:** CLI flag > config file > default. | LOCKED |
| 05-5 | **Config commands:** `init`, `show`, `get`, `set`, `reset`. | LOCKED |
| 05-6 | **`--verbose`/`--quiet` wired to output** in this sub-project. `--vault` and `--mode` are schema-only (deferred to 06, 17+). | LOCKED |

---

## Part A — Config file format and location

### File: `tip.zon`

```zon
.{
    .verbose = false,
    .quiet = false,
    .default_vault = "personal",
    .mode = "local",
}
```

### Platform config directory resolution

Added to `src/storage/dir.zig` as a new function alongside `open_data_dir`:

| OS | Primary | Fallback |
|---|---|---|
| Linux | `$XDG_CONFIG_HOME/tip/` | `~/.config/tip/` |
| macOS | `~/Library/Application Support/tip/` | — |
| Windows | `%APPDATA%/tip/` | — |

### Config struct

```zig
const Config = struct {
    verbose: bool = false,
    quiet: bool = false,
    default_vault: ?[]const u8 = null,
    mode: []const u8 = "local",
};
```

---

## Part B — Global flags

Added to `Args` in `main.zig`:

| Flag | Type | Config key | Default |
|---|---|---|---|
| `--verbose` | bool | overrides `verbose` | `false` |
| `--quiet` | bool | overrides `quiet` | `false` |
| `--config=<path>` | `[]const u8` | — | platform config dir |
| `--vault=<name>` | `?[]const u8` | overrides `default_vault` | `null` |
| `--mode=<local\|remote>` | `[]const u8` | overrides `mode` | `"local"` |

Order of precedence (high to low): CLI flag > config file > struct default.

---

## Part C — Config commands

Implemented as a new command variant in `main.zig` `Args.command`:

### `tip config init`
- If config exists, error with "Config already exists at <path>"
- If not, write default config struct serialized as ZON
- Print "Config initialized at <path>"

### `tip config show`
- Load and parse config file
- Serialize back to ZON and print to stdout

### `tip config get --key=<key>`
- Load config, find key by name, print value
- Error if key not found

### `tip config set --key=<key> --value=<value>`
- Load config, update key, save config atomically (write temp + rename)
- Error if key not found

### `tip config reset`
- Overwrite config file with defaults (same as `init` but overwrites)
- Print "Config reset to defaults"

---

## Part D — File layout

| File | Responsibility |
|---|---|
| `src/core/config.zig` (NEW) | `Config` struct, `load`/`save`/`get`/`set`/`init`/`reset` functions |
| `src/storage/dir.zig` (MODIFY) | Add `open_config_dir` alongside `open_data_dir` |
| `src/core/task.zig` (MODIFY) | Accept `Config` in dispatch, use `verbose`/`quiet` for output |
| `src/main.zig` (MODIFY) | Add global flags to `Args`, load config before dispatch |

---

## Part E — Startup flow

```
1. Parse --config from raw args (if present)
2. Resolve config path: --config or platform config dir + "tip.zon"
3. Try to load and parse ZON config file; on ENOENT use defaults
4. Parse all CLI args (including global flags)
5. Apply CLI flag overrides on top of loaded config
6. Pass resolved Config to dispatch_task_command
```

---

## Part F — Testing

| Test | What it verifies |
|------|------------------|
| Parse config from ZON string | `std.zon.parse.fromSliceAlloc` correctly deserializes all fields |
| Serialize config to ZON | `std.zon.stringify.serialize` produces valid output |
| Config file not found uses defaults | Loading non-existent file returns default Config |
| CLI flag overrides config | `--verbose` sets `config.verbose = true` even if file says `false` |
| config init creates file | Running `tip config init` writes a valid ZON file |
| config set updates key | Running `tip config set --key=verbose --value=true` updates the file |
| config get reads key | Running `tip config get --key=verbose` prints the value |
| --verbose affects task output | Dispatch with verbose=true includes extra detail in print_task |
| --quiet suppresses output | Dispatch with quiet=true suppresses non-error output |

---

## Out of scope

- **Vaults** (multi-vault, vault FK, `--vault` behavior) — sub-project 06.
- **Mode switching** (`--mode=remote`) — sub-project 17+.
- **JSON export/import** — future sub-project.
- **SSO / secrets in config** — future sub-project 10+.
- **Config validation** (schema checks beyond struct typing) — future.

---

## Next step

Write the checkbox implementation plan for this sub-project via the writing-plans skill. No implementation yet.
