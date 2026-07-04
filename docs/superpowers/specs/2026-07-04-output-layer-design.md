# Sub-project 03-amendment — Terminal Output Layer (DESIGN)

> **Status:** DESIGN DRAFT
> **Date:** 2026-07-04
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 03 (Storage Handle + Tasks Table) — this amends SP03's rendering decisions
> **Ripple:** SP04 (completion confirms), SP05 (verbose/quiet), SP06 (vault list)
> **Slot:** Interleaved between SP03 design and SP03 implementation

## Rationale

SP03's current spec locks S4 ("Ansi helpers extracted to `src/utils/ansi.zig`") and S5 ("print_task stays in task.zig"). This amendment replaces both with a cleaner output layer that future entities (passwords, vaults, audit logs, tags) reuse without per-entity ad-hoc formatting.

**Key changes from SP03:**
- ANSI is removed entirely, not extracted
- `print_task` is replaced by a generic table renderer (list) and field renderer (detail)
- Rendering moves to `src/output/`, not `src/utils/ansi.zig`

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| O1 | **ANSI escape codes removed** from all output. No colors or text styling. | LOCKED |
| O2 | **Status icons** (`○` `⟳` `✓`) and **priority glyphs** (`↑` `-` `↓`) kept as plain-text markers. | LOCKED |
| O3 | **Generic table renderer** for list views — column-defined, entity-agnostic. | LOCKED |
| O4 | **Generic key-value renderer** for detail views — label-value pairs. | LOCKED |
| O5 | **`src/output/` module** owns all terminal rendering. | LOCKED |
| O6 | **`--sort` flag** on task list, default `-created`. | LOCKED |
| O7 | **`--borders` flag** on task list, adds `|` column separators. | LOCKED |
| O8 | **Epoch→human timestamp function** in output module, UTC date only, relative mode reserved for future. | LOCKED |

---

## File layout

```
src/
  output/
    table.zig      — render_table (generic column renderer)
    detail.zig     — render_detail (key-value field renderer)
    time.zig       — format_timestamp (epoch → human)
  core/
    task.zig       — stripped of ANSI, uses output/ module, adds --sort/--borders
    models.zig     — unchanged
    errors.zig     — error taxonomy (sub-project 01, unchanged)
  utils/
    generate.zig   — unchanged
    (no ansi.zig — ANSI is deleted, not extracted)
  storage/
    dir.zig        — from SP03
    json.zig       — temporal until SP03 migration
  main.zig         — unchanged
```

---

## Part A — `src/output/table.zig`

### API

```zig
pub const Column = struct {
    header: []const u8,
    width: usize,          // 0 = auto-compute
    fmt: *const fn (?[]const u8) []const u8,  // null = no value
};

pub const Options = struct {
    borders: bool = false,
};

pub fn render_table(
    columns: []const Column,
    rows: []const []const []const u8,  // [row_idx][col_idx] = formatted cell
) void
```

- `columns` defines headers and type-erased formatters
- `rows` is pre-formatted cell strings (row-major)
- Auto-width: column width = max(header.len, max cell len), right-padded with spaces
- Header uses `────` underline per column

### Border mode

Without borders (default):
```
ID        Status  Title          Due
────────  ──────  ─────────────  ──────────
abc12345  ○       Buy groceries  2026-07-10
```

With `--borders`:
```
ID        │ Status  │ Title          │ Due
────────  │ ──────  │ ─────────────  │ ──────────
abc12345  │ ○       │ Buy groceries  │ 2026-07-10
```

### Render steps

1. Compute column widths (max of header and all cell strings in that column)
2. Print header row with labels
3. Print underline row (repeat `─` per column; with borders: add ` │ ` between underlines)
4. Print each data row, cells right-padded to column width; with borders: ` │ ` between cells

---

## Part B — `src/output/detail.zig`

### API

```zig
pub const Field = struct {
    label: []const u8,
    value: []const u8,
};

pub fn render_detail(fields: []const Field) void
```

### Render steps

1. Find max label width across all fields
2. For each field: `  {label}{padding}  {value}\n`
   - 2-space indent
   - label right-padded to max width
   - `: ` separator
   - value printed as-is

### Example

```
  ID:        abc12345
  Title:     Buy groceries
  Status:    ○ Pending
  Priority:  ↑ High
```

No decoration, no ANSI, no boxes.

---

## Part C — `src/output/time.zig`

### API

```zig
pub const TimeFormat = enum {
    iso_8601,     // "2026-07-04"
    /// TODO: relative — "2h ago", "yesterday", "3d ago"
    relative,
    raw,          // "1749043200"
};

pub fn format_timestamp(epoch_s: i64, fmt: TimeFormat) []const u8
```

- `iso_8601`: UTC date from epoch seconds via `std.time.epoch.epochSecondsToEpochDay` → YYYY-MM-DD
- `raw`: `std.fmt.formatInt` as decimal string
- `relative`: reserved, returns `"TODO"` for now

---

## Part D — `src/core/task.zig` changes

### TaskArgs additions

```zig
sort: []const []const u8 = &.{"-created"},
borders: bool = false,
```

### Removed

- `Ansi` enum
- `ansi_code()` function
- `status_color()` function
- `priority_color()` function

### Kept (plain text, no ANSI)

- `status_icon()` — `○` / `⟳` / `✓`
- `priority_glyph()` — `↑` / `-` / `↓`

### `list_task` rework

1. Load tasks (unchanged)
2. If `--sort` provided, sort task slice in-place using multi-key comparator
3. Format rows: for each task, build `[]const u8` cells via column formatters
4. Call `out.render_table(task_columns, rows, .{ .borders = args.borders })`

### `show_task` rework

1. Find task (unchanged)
2. Build `[]Field` from task fields
3. Call `out.render_detail(fields)`

### Sort implementation

```zig
const SortField = enum { created, due, priority, title, status, updated, completed };

const SortKey = struct {
    field: SortField,
    direction: enum { asc, desc },
};

fn parse_sort_keys(raw: []const []const u8) []SortKey
fn sort_tasks(tasks: []Task, keys: []const SortKey) void
```

- `parse_sort_keys`: for each flag value, split on `,`, strip leading `-` for desc, match field name
- `sort_tasks`: in-place sort using `std.sort.insertion` with a comparator that iterates keys
- Priority sort order: high=2, medium=1, low=0
- Status sort order: pending=0, in_progress=1, completed=2

---

## Ripple effects

### SP04 — Complete/start confirms

Before: `"{s}✓{s} Completed: {s}"` (green ANSI wrappers)
After: `"✓ Completed: {s}"` (plain text)

### SP05 — Verbose/quiet

Unchanged. `--verbose` and `--quiet` just control whether non-error output prints. The format itself is unaffected.

### SP06 — Vault list

Before: ad-hoc `"* personal (5 tasks)"` format
After: uses same `out.render_table()` — columns: `NAME`, `TASK_COUNT`, `ACTIVE`

---

## Future considerations (not implemented)

| Feature | Notes |
|---------|-------|
| Relative timestamps | `format_timestamp` has the slot, needs calculation |
| `--format=json` | Reserved, needs serializer |
| `--format=csv` | Near-trivial with column widths = 0, no padding |
| `--no-headers` | Omit header row for piping |
| Custom column selection | `--columns=title,due,status` — requires column name registry |
| ANSI config option | If added later, lives in the output module, not scattered in formatters |

---

## What this replaces in SP03

| SP03 decision | Old plan | New plan |
|---|---|---|
| S4 | Extract ANSI helpers to `src/utils/ansi.zig` | Delete ANSI entirely; create `src/output/` |
| (implied) | `print_task` stays in `task.zig` | `print_task` replaced by generic renderers in `src/output/` |
| S6 | CLI owns rendering (unchanged) | Unchanged — CLI still calls renderers |
