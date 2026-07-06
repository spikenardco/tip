# Password Strength + Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add password strength scoring (individual) and password audit (scan all stored entries for weak/duplicate/stale passwords).

**Architecture:** A `src/core/password_strength.zig` module provides a pure `score()` function returning a numeric 0-100 score with label and flags. A `src/core/password_audit.zig` module consumes the scorer, loads passwords via SP11's storage layer, decrypts via SP11's field crypto, and produces an `AuditReport`. Both are wired as new subcommands in SP11's `password.zig` dispatch.

**Tech Stack:** Zig 0.16 (`std.Io`), `std.crypto.random`, no external deps for the scorer.

**Dependency:** This plan requires **sub-project 11 (Password CRUD + Generation)** to be implemented first. The audit module uses SP11's `field.encrypt_field`/`decrypt_field`, `storage.load_passwords`/`save_passwords`, and the `models.Password` struct. The strength scorer is fully standalone and has no dependencies.

---

## Global Constraints

- **Zig version:** 0.16.0 (`minimum_zig_version = "0.16.0"`). Use the new `std.Io` APIs.
- **Identifier casing:** functions/vars/fields = `snake_case`; types = `PascalCase`; enum members = `snake_case`.
- **Error taxonomy (SP01/SP11):** `EmptyPassword`, `VaultLocked`, `PasswordNotFound`. Plus new: `AuditEmptyVault`.
- **Exit codes:** `0` ok · `1` internal · `2` usage · `3` not found · `4` validation.
- **Scoring thresholds:** 0-39 Weak, 40-64 Fair, 65-84 Strong, 85-100 Very Strong.
- **Scoring breakdown:** Length (30pts), Variety (25pts), Entropy bonus (15pts), Pattern penalties (-30 max).
- **Pattern detection:** sequential runs (3+), keyboard QWERTY rows, repeated adjacent chars (3+).
- **Audit checks:** weak passwords, duplicates (by decrypted plaintext), stale entries (180+ days).
- **Audit requires unlocked vault.** Same constraint as SP11 password commands.
- **Tests:** `zig build test --summary all` from repo root. Tests live at the bottom of each source file.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `src/core/password_strength.zig` | Create | Pure function `score()` + pattern detection + tests |
| `src/core/password_audit.zig` | Create | `audit()` function + report types + display formatting + tests |
| `src/core/password.zig` | Modify | Add `strength` / `audit` subcommands to `PasswordArgs` and dispatch + tests (SP11 file) |
| `src/core/errors.zig` | Modify | Add `AuditEmptyVault` error (SP01 file) |

---

### Task 1: Password strength module

**Files:**
- Create: `src/core/password_strength.zig`

**Interfaces:**
- Produces:
  - `pub const Label = enum { weak, fair, strong, very_strong }`
  - `pub const Flag = union(enum) { length_ok, variety_ok, sequential_pattern: []const u8, repeated_char: u8, keyboard_pattern: []const u8, too_short, no_uppercase, no_lowercase, no_digit, no_symbol }`
  - `pub const StrengthResult = struct { score: u8, label: Label, flags: []const Flag }`
  - `pub fn score(allocator: Allocator, password: []const u8) StrengthResult`

- [ ] **Step 1: Write the failing tests**

Write these at the bottom of a new file `src/core/password_strength.zig`:

```zig
test "empty string scores 0 weak" {
    const allocator = std.testing.allocator;
    const result = score(allocator, "");
    defer allocator.free(result.flags);
    try std.testing.expectEqual(@as(u8, 0), result.score);
    try std.testing.expectEqual(.weak, result.label);
}

test "very short password is weak" {
    const allocator = std.testing.allocator;
    const result = score(allocator, "Ab1!");
    defer allocator.free(result.flags);
    try std.testing.expect(result.score < 40);
    try std.testing.expectEqual(.weak, result.label);
}

test "long password with variety is very strong" {
    const allocator = std.testing.allocator;
    const result = score(allocator, "CorrectHorseBatteryStaple99!");
    defer allocator.free(result.flags);
    try std.testing.expect(result.score >= 85);
    try std.testing.expectEqual(.very_strong, result.label);
}

test "sequential pattern penalized" {
    const allocator = std.testing.allocator;
    const result = score(allocator, "abcdef1234!XYZ");
    defer allocator.free(result.flags);
    var found_seq = false;
    for (result.flags) |flag| {
        if (flag == .sequential_pattern) found_seq = true;
    }
    try std.testing.expect(found_seq);
}

test "keyboard pattern penalized" {
    const allocator = std.testing.allocator;
    const result = score(allocator, "qwerty12345!");
    defer allocator.free(result.flags);
    var found_kb = false;
    for (result.flags) |flag| {
        if (flag == .keyboard_pattern) found_kb = true;
    }
    try std.testing.expect(found_kb);
}

test "repeated chars penalized" {
    const allocator = std.testing.allocator;
    const result = score(allocator, "aaa1234!XYZ");
    defer allocator.free(result.flags);
    var found_rep = false;
    for (result.flags) |flag| {
        if (flag == .repeated_char) found_rep = true;
    }
    try std.testing.expect(found_rep);
}

test "all charset variety bonuses applied" {
    const allocator = std.testing.allocator;
    const result = score(allocator, "Abcd1234!@#$");
    defer allocator.free(result.flags);
    var found_variety = false;
    for (result.flags) |flag| {
        if (flag == .variety_ok) found_variety = true;
    }
    try std.testing.expect(found_variety);
}

test "only lowercase gets no_uppercase no_digit no_symbol flags" {
    const allocator = std.testing.allocator;
    const result = score(allocator, "abcdefghij");
    defer allocator.free(result.flags);
    var found_no_upper = false;
    var found_no_digit = false;
    var found_no_symbol = false;
    for (result.flags) |flag| {
        switch (flag) {
            .no_uppercase => found_no_upper = true,
            .no_digit => found_no_digit = true,
            .no_symbol => found_no_symbol = true,
            else => {},
        }
    }
    try std.testing.expect(found_no_upper);
    try std.testing.expect(found_no_digit);
    try std.testing.expect(found_no_symbol);
}

test "score thresholds boundaries" {
    const allocator = std.testing.allocator;

    // 39 = Weak
    const r1 = score(allocator, "a");
    defer allocator.free(r1.flags);
    try std.testing.expectEqual(.weak, r1.label);

    // 85+ = Very Strong
    const r2 = score(allocator, "CorrectHorseBatteryStaple99!Xy");
    defer allocator.free(r2.flags);
    try std.testing.expectEqual(.very_strong, r2.label);
}

test "single char input" {
    const allocator = std.testing.allocator;
    const result = score(allocator, "a");
    defer allocator.free(result.flags);
    try std.testing.expectEqual(@as(u8, 0), result.score);
    try std.testing.expectEqual(.weak, result.label);
}

test "unicode non-ascii input" {
    const allocator = std.testing.allocator;
    const result = score(allocator, "héllo wörld 123!");
    defer allocator.free(result.flags);
    try std.testing.expect(result.score > 0);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `score` not defined, `password_strength.zig` not imported

- [ ] **Step 3: Write the implementation**

```zig
const std = @import("std");

pub const Label = enum { weak, fair, strong, very_strong };

pub const Flag = union(enum) {
    length_ok,
    variety_ok,
    sequential_pattern: []const u8,
    repeated_char: u8,
    keyboard_pattern: []const u8,
    too_short,
    no_uppercase,
    no_lowercase,
    no_digit,
    no_symbol,
};

pub const StrengthResult = struct {
    score: u8,
    label: Label,
    flags: []const Flag,
};

pub fn score(allocator: std.mem.Allocator, password: []const u8) StrengthResult {
    if (password.len == 0) return .{ .score = 0, .label = .weak, .flags = &.{} };

    var flag_list = std.ArrayList(Flag).empty;
    defer flag_list.deinit(allocator);

    // --- Length scoring (30 pts max) ---
    const length_score: u8 = if (password.len >= 16) 30
        else if (password.len >= 12) 20
        else if (password.len >= 8) 10
        else 0;

    if (length_score >= 10) {
        flag_list.append(allocator, .length_ok) catch {};
    } else {
        flag_list.append(allocator, .too_short) catch {};
    }

    // --- Character variety (25 pts max, +7 per class) ---
    var has_upper = false;
    var has_lower = false;
    var has_digit = false;
    var has_symbol = false;

    for (password) |ch| {
        if (std.ascii.isUpper(ch)) has_upper = true;
        else if (std.ascii.isLower(ch)) has_lower = true;
        else if (std.ascii.isDigit(ch)) has_digit = true;
        else has_symbol = true;
    }

    var variety_count: u8 = 0;
    if (has_upper) variety_count += 1;
    if (has_lower) variety_count += 1;
    if (has_digit) variety_count += 1;
    if (has_symbol) variety_count += 1;

    const variety_score: u8 = @min(25, variety_count * 7);

    if (variety_count == 4) {
        flag_list.append(allocator, .variety_ok) catch {};
    }
    if (!has_upper) flag_list.append(allocator, .no_uppercase) catch {};
    if (!has_lower) flag_list.append(allocator, .no_lowercase) catch {};
    if (!has_digit) flag_list.append(allocator, .no_digit) catch {};
    if (!has_symbol) flag_list.append(allocator, .no_symbol) catch {};

    // --- Entropy bonus (15 pts max) ---
    const charset_size: usize = charset_estimate(password);
    const entropy_bonus: u8 = if (charset_size > 1) blk: {
        const bits = @log2(@as(f64, @floatFromInt(charset_size))) * @as(f64, @floatFromInt(password.len));
        break :blk @min(15, @as(u8, @intFromFloat(bits * 1.5)));
    } else 0;

    // --- Pattern penalties (30 pts max) ---
    var penalty: u8 = 0;

    if (find_sequential(password)) |seq| {
        penalty += 10;
        flag_list.append(allocator, .{ .sequential_pattern = seq }) catch {};
    }
    if (find_keyboard_pattern(password)) |kb| {
        penalty += 10;
        flag_list.append(allocator, .{ .keyboard_pattern = kb }) catch {};
    }
    if (find_repeated_chars(password)) |ch| {
        penalty += 10;
        flag_list.append(allocator, .{ .repeated_char = ch }) catch {};
    }

    penalty = @min(penalty, 30);

    const raw_score = length_score + variety_score + entropy_bonus - penalty;
    const clamped = if (raw_score > 100) 100 else raw_score;

    const label: Label = if (clamped >= 85) .very_strong
        else if (clamped >= 65) .strong
        else if (clamped >= 40) .fair
        else .weak;

    // Move flags to heap-owned slice
    const flags = allocator.alloc(Flag, flag_list.items.len) catch &.{};
    for (flag_list.items, 0..) |f, i| {
        flags[i] = f;
    }

    return .{ .score = clamped, .label = label, .flags = flags };
}

fn charset_estimate(s: []const u8) usize {
    var has_lower = false;
    var has_upper = false;
    var has_digit = false;
    var has_symbol = false;
    for (s) |ch| {
        if (std.ascii.isUpper(ch)) has_upper = true;
        else if (std.ascii.isLower(ch)) has_lower = true;
        else if (std.ascii.isDigit(ch)) has_digit = true;
        else has_symbol = true;
    }
    var size: usize = 0;
    if (has_lower) size += 26;
    if (has_upper) size += 26;
    if (has_digit) size += 10;
    if (has_symbol) size += 24;
    return if (size == 0) 1 else size;
}

fn find_sequential(s: []const u8) ?[]const u8 {
    if (s.len < 3) return null;
    for (0..s.len - 2) |i| {
        const a = s[i];
        const b = s[i + 1];
        const c = s[i + 2];
        if (std.ascii.isAlphanumeric(a) and std.ascii.isAlphanumeric(b) and std.ascii.isAlphanumeric(c)) {
            if ((b == a + 1 and c == b + 1) or (b == a - 1 and c == b - 1)) {
                return s[i..@min(i + 5, s.len)];
            }
        }
    }
    return null;
}

const keyboard_rows = [_][]const u8{
    "qwertyuiop",
    "asdfghjkl",
    "zxcvbnm",
};

fn find_keyboard_pattern(s: []const u8) ?[]const u8 {
    if (s.len < 3) return null;
    // Convert to lowercase on stack for case-insensitive matching
    var lower_buf: [128]u8 = undefined;
    const lower = lower_buf[0..@min(s.len, lower_buf.len)];
    for (s[0..lower.len], 0..) |ch, i| {
        lower[i] = std.ascii.toLower(ch);
    }
    for (0..lower.len - 2) |i| {
        const chunk = lower[i..@min(i + 5, lower.len)];
        for (keyboard_rows) |row| {
            if (std.mem.indexOf(u8, row, chunk)) |_| {
                // Return original string slice for the matched range
                const end = @min(i + 5, s.len);
                return s[i..end];
            }
        }
    }
    return null;
}

fn find_repeated_chars(s: []const u8) ?u8 {
    if (s.len < 3) return null;
    var count: u8 = 1;
    for (1..s.len) |i| {
        if (s[i] == s[i - 1]) {
            count += 1;
            if (count >= 3) return s[i];
        } else {
            count = 1;
        }
    }
    return null;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (11 new tests)

- [ ] **Step 5: Commit**

```bash
git add src/core/password_strength.zig
git commit -m "feat: add password strength scoring module"
```

---

### Task 2: Password audit module

**Files:**
- Create: `src/core/password_audit.zig`

**Interfaces:**
- Consumes: `password_strength.score()`, `models.Password` (SP11), `field.decrypt_field` (SP11), `storage.load_passwords` / `save_passwords` (SP11)
- Produces:
  - `pub const AuditEntry = struct { id, title, score, label, flags, days_since_update }`
  - `pub const DuplicateGroup = struct { entries: []const AuditEntry, count: usize }`
  - `pub const AuditReport = struct { total, weak, fair, duplicates, stale }`
  - `pub fn audit(allocator, io, dir, vault_id, key) !AuditReport`
  - `pub fn print_audit_report(io, report: AuditReport) void`

**Dependency note:** This task requires the SP11 modules (`crypto/field.zig`, `storage/json_password.zig`, `core/models.zig` with `Password` struct). The test setup creates encrypted test data using `field.encrypt_field`.

- [ ] **Step 1: Write the failing tests**

```zig
const password_audit = @import("../core/password_audit.zig");
const password_strength = @import("../core/password_strength.zig");
const models = @import("../core/models.zig");
const field = @import("../crypto/field.zig");

fn test_key() [32]u8 {
    return [_]u8{0x42} ** 32;
}

fn write_password_json(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, entries: []const models.Password) !void {
    const string = try std.json.Stringify.valueAlloc(allocator, .{ .passwords = entries }, .{ .whitespace = .indent_2 });
    defer allocator.free(string);
    try dir.writeFile(io, .{ .sub_path = "passwords.json", .data = string });
}

test "audit empty vault returns report with no issues" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const key = test_key();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write empty passwords file
    try write_password_json(allocator, io, tmp_dir.dir, &.{});

    const report = try password_audit.audit(allocator, io, tmp_dir.dir, "v1", &key);
    defer {
        allocator.free(report.weak);
        allocator.free(report.fair);
        allocator.free(report.duplicates);
        allocator.free(report.stale);
    }
    try std.testing.expectEqual(@as(usize, 0), report.total);
    try std.testing.expectEqual(@as(usize, 0), report.weak.len);
    try std.testing.expectEqual(@as(usize, 0), report.duplicates.len);
}

test "audit detects weak password" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const key = test_key();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const weak_pwd = try field.encrypt_field("abc", &key, allocator);
    defer allocator.free(weak_pwd);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    try write_password_json(allocator, io, tmp_dir.dir, &.{
        .{ .id = "p1", .vault_id = "v1", .title = "weak_test", .password = weak_pwd, .created_at = now, .updated_at = now },
    });

    const report = try password_audit.audit(allocator, io, tmp_dir.dir, "v1", &key);
    defer {
        allocator.free(report.weak);
        allocator.free(report.fair);
        allocator.free(report.duplicates);
        allocator.free(report.stale);
    }
    try std.testing.expectEqual(@as(usize, 1), report.total);
    try std.testing.expectEqual(@as(usize, 1), report.weak.len);
    try std.testing.expectEqualStrings("weak_test", report.weak[0].title);
}

test "audit detects duplicate passwords" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const key = test_key();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const pwd = try field.encrypt_field("shared_secret_99!", &key, allocator);
    defer allocator.free(pwd);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    try write_password_json(allocator, io, tmp_dir.dir, &.{
        .{ .id = "p1", .vault_id = "v1", .title = "github", .password = pwd, .created_at = now, .updated_at = now },
        .{ .id = "p2", .vault_id = "v1", .title = "aws", .password = pwd, .created_at = now, .updated_at = now },
    });

    const report = try password_audit.audit(allocator, io, tmp_dir.dir, "v1", &key);
    defer {
        allocator.free(report.weak);
        allocator.free(report.fair);
        allocator.free(report.duplicates);
        allocator.free(report.stale);
    }
    try std.testing.expectEqual(@as(usize, 1), report.duplicates.len);
    try std.testing.expectEqual(@as(usize, 2), report.duplicates[0].count);
}

test "audit detects stale entries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const key = test_key();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const pwd = try field.encrypt_field("StrongPass99!", &key, allocator);
    defer allocator.free(pwd);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const stale_time = now - (200 * 86400); // 200 days ago
    try write_password_json(allocator, io, tmp_dir.dir, &.{
        .{ .id = "p1", .vault_id = "v1", .title = "old_entry", .password = pwd, .created_at = stale_time, .updated_at = stale_time },
    });

    const report = try password_audit.audit(allocator, io, tmp_dir.dir, "v1", &key);
    defer {
        allocator.free(report.weak);
        allocator.free(report.fair);
        allocator.free(report.duplicates);
        allocator.free(report.stale);
    }
    try std.testing.expectEqual(@as(usize, 1), report.stale.len);
    try std.testing.expectEqualStrings("old_entry", report.stale[0].title);
}

test "audit mixes all checks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const key = test_key();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const strong_pwd = try field.encrypt_field("CorrectHorseBattery99!", &key, allocator);
    defer allocator.free(strong_pwd);
    const weak_pwd = try field.encrypt_field("abc", &key, allocator);
    defer allocator.free(weak_pwd);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const stale_time = now - (200 * 86400);
    try write_password_json(allocator, io, tmp_dir.dir, &.{
        .{ .id = "p1", .vault_id = "v1", .title = "strong1", .password = strong_pwd, .created_at = now, .updated_at = now },
        .{ .id = "p2", .vault_id = "v1", .title = "weak1", .password = weak_pwd, .created_at = now, .updated_at = now },
        .{ .id = "p3", .vault_id = "v1", .title = "stale1", .password = strong_pwd, .created_at = stale_time, .updated_at = stale_time },
    });

    const report = try password_audit.audit(allocator, io, tmp_dir.dir, "v1", &key);
    defer {
        allocator.free(report.weak);
        allocator.free(report.fair);
        allocator.free(report.duplicates);
        allocator.free(report.stale);
    }
    try std.testing.expectEqual(@as(usize, 3), report.total);
    try std.testing.expectEqual(@as(usize, 1), report.weak.len);
    try std.testing.expectEqual(@as(usize, 0), report.duplicates.len);
    try std.testing.expectEqual(@as(usize, 1), report.stale.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `password_audit.zig` not found

- [ ] **Step 3: Write the implementation**

```zig
const std = @import("std");
const models = @import("../core/models.zig");
const password_strength = @import("../core/password_strength.zig");
const field = @import("../crypto/field.zig");

const stale_days: i64 = 180;

pub const AuditEntry = struct {
    id: []const u8,
    title: []const u8,
    score: u8,
    label: password_strength.Label,
    flags: []const password_strength.Flag,
    days_since_update: ?i64,
};

pub const DuplicateGroup = struct {
    entries: []const AuditEntry,
    count: usize,
};

pub const AuditReport = struct {
    total: usize,
    weak: []const AuditEntry,
    fair: []const AuditEntry,
    duplicates: []const DuplicateGroup,
    stale: []const AuditEntry,
};

pub fn audit(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    vault_id: []const u8,
    key: *const [32]u8,
) !AuditReport {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const storage = @import("../storage/json_password.zig");
    const all_passwords = try storage.load_passwords(arena_alloc, io, dir);

    // Filter by vault_id
    var vault_entries = std.ArrayList(models.Password).empty;
    defer vault_entries.deinit(allocator);
    for (all_passwords) |p| {
        if (std.mem.eql(u8, p.vault_id, vault_id)) {
            try vault_entries.append(allocator, p);
        }
    }

    if (vault_entries.items.len == 0) {
        return AuditReport{
            .total = 0,
            .weak = &.{},
            .fair = &.{},
            .duplicates = &.{},
            .stale = &.{},
        };
    }

    // Score all entries
    var scored = std.ArrayList(AuditEntry).empty;
    defer scored.deinit(allocator);

    const now_sec = std.Io.Timestamp.now(io, .real).toSeconds();

    for (vault_entries.items) |entry| {
        const decrypted = try field.decrypt_field(entry.password, key, allocator);
        defer allocator.free(decrypted);

        const result = password_strength.score(allocator, decrypted);
        defer allocator.free(result.flags);

        const days_since: ?i64 = if (entry.updated_at) |u| blk: {
            const diff_sec = now_sec - u;
            break :blk if (diff_sec < 0) 0 else @divFloor(diff_sec, 86400);
        } else null;

        try scored.append(allocator, .{
            .id = entry.id,
            .title = entry.title,
            .score = result.score,
            .label = result.label,
            .flags = result.flags,
            .days_since_update = days_since,
        });
    }

    // Categorize
    var weak_list = std.ArrayList(AuditEntry).empty;
    defer weak_list.deinit(allocator);
    var fair_list = std.ArrayList(AuditEntry).empty;
    defer fair_list.deinit(allocator);
    var stale_list = std.ArrayList(AuditEntry).empty;
    defer stale_list.deinit(allocator);

    for (scored.items) |entry| {
        if (entry.label == .weak) try weak_list.append(allocator, entry);
        if (entry.label == .fair) try fair_list.append(allocator, entry);
        if (entry.days_since_update) |d| {
            if (d >= stale_days) try stale_list.append(allocator, entry);
        }
    }

    // Find duplicates by decrypted plaintext
    var dupe_groups = std.ArrayList(DuplicateGroup).empty;
    defer dupe_groups.deinit(allocator);
    {
        var seen = std.StringHashMap(std.ArrayList(usize)).empty;
        defer {
            var it = seen.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.deinit(allocator);
            }
            seen.deinit(allocator);
        }

        for (vault_entries.items, 0..) |entry, idx| {
            const decrypted = try field.decrypt_field(entry.password, key, allocator);
            defer allocator.free(decrypted);
            const gop = try seen.getOrPut(allocator, decrypted);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(usize).empty;
            }
            try gop.value_ptr.*.append(allocator, idx);
        }

        var it = seen.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.items.len > 1) {
                var group_entries = std.ArrayList(AuditEntry).empty;
                defer group_entries.deinit(allocator);
                for (kv.value_ptr.items) |idx| {
                    try group_entries.append(allocator, scored.items[idx]);
                }
                try dupe_groups.append(allocator, .{
                    .entries = try allocator.dupe(AuditEntry, group_entries.items),
                    .count = kv.value_ptr.items.len,
                });
            }
        }
    }

    return AuditReport{
        .total = vault_entries.items.len,
        .weak = try allocator.dupe(AuditEntry, weak_list.items),
        .fair = try allocator.dupe(AuditEntry, fair_list.items),
        .duplicates = try allocator.dupe(DuplicateGroup, dupe_groups.items),
        .stale = try allocator.dupe(AuditEntry, stale_list.items),
    };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (5 new tests)

- [ ] **Step 5: Commit**

```bash
git add src/core/password_audit.zig
git commit -m "feat: add password audit module"
```

---

### Task 3: Wire strength + audit into CLI dispatch

**Files:**
- Modify: `src/core/password.zig` (SP11 file)

**Interfaces:**
- Consumes: `password_strength.score()`, `password_audit.audit()`, `field.decrypt_field` (SP11), `session.get_key` (SP10)
- Produces: `strength` and `audit` subcommands in `PasswordArgs`, dispatch handlers

- [ ] **Step 1: Write the failing tests**

```zig
const password_strength = @import("password_strength.zig");
const password_audit = @import("password_audit.zig");

test "strength subcommand scores a password" {
    const allocator = std.testing.allocator;
    const result = password_strength.score(allocator, "Test1234!");
    defer allocator.free(result.flags);
    try std.testing.expect(result.score >= 40);
    try std.testing.expect(result.label == .fair or result.label == .strong);
}

test "PasswordArgs includes strength subcommand" {
    const args = password.PasswordArgs{ .subcommand = .{ .strength = .{ .password = "test" } } };
    try std.testing.expectEqualStrings("test", args.subcommand.?.strength.password);
}

test "PasswordArgs includes audit subcommand" {
    const args = password.PasswordArgs{ .subcommand = .{ .audit = .{} } };
    _ = args;
}

test "PasswordArgs show subcommand accepts --strength flag" {
    const args = password.PasswordArgs{ .subcommand = .{ .show = .{ .id = "abc", .show_password = false, .strength = true } } };
    try std.testing.expect(args.subcommand.?.show.strength);
}

test "dispatch_strength handles empty password" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const result = password_strength.score(allocator, "");
    defer allocator.free(result.flags);
    try std.testing.expectEqual(@as(u8, 0), result.score);
    try std.testing.expectEqual(.weak, result.label);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `strength` not in `PasswordArgs.subcommand` union

- [ ] **Step 3: Extend `PasswordArgs` in password.zig**

Add these types to the existing `PasswordArgs`:

```zig
strength: struct {
    password: []const u8,
    verbose: bool = false,
},
audit: struct {
    min_score: ?[]const u8 = null,
    vault: ?[]const u8 = null,
},
```

Update the `show` struct to add `strength` field:

```zig
show: struct {
    id: []const u8,
    show_password: bool = false,
    strength: bool = false,
},
```

Add to the help text:

```zig
pub const help =
    \\Usage:
    \\  tip password <subcommand> [args] [flags]
    \\
    \\Commands:
    \\  add <title>              Add a password entry
    \\  ...
    \\  strength                 Score a password
    \\      --password=<pwd>     Password to evaluate
    \\      [--verbose]          Show flag details
    \\  audit                    Scan all passwords in active vault
    \\      [--vault=<name>]
    \\  show <id>                Show entry details
    \\      [--show-password]    Reveal the actual password
    \\      [--strength]         Show password strength score
    \\
;
```

- [ ] **Step 4: Add dispatch cases in `dispatch_password_command`**

```zig
.strength => |s| handle_strength(allocator, io, s) catch |err| {
    handle_password_error(err, "strength");
},
.audit => |a| handle_audit(allocator, io, dir, a) catch |err| {
    handle_password_error(err, "audit");
},
```

- [ ] **Step 5: Implement handler functions**

```zig
fn handle_strength(allocator: std.mem.Allocator, io: std.Io, args: anytype) !void {
    if (args.password.len == 0) return error.EmptyPassword;
    const result = password_strength.score(allocator, args.password);
    defer allocator.free(result.flags);

    if (args.verbose) {
        std.debug.print("Score: {d}/100 — {s}\n", .{ result.score, @tagName(result.label) });
        std.debug.print("Flags:", .{});
        for (result.flags) |flag| {
            std.debug.print(" {s}", .{@tagName(flag)});
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("Score: {d}/100 — {s}\n", .{ result.score, @tagName(result.label) });
    }
}

fn handle_audit(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, args: anytype) !void {
    // Resolve vault
    const vault_id = args.vault orelse "v1"; // SP06 will wire proper vault resolution

    // Get vault key (SP10 session integration)
    // For now, placeholder key — similar to SP11's add_password
    var placeholder_key: [32]u8 = [_]u8{0x42} ** 32;

    const report = try password_audit.audit(allocator, io, dir, vault_id, &placeholder_key);
    defer {
        allocator.free(report.weak);
        allocator.free(report.fair);
        allocator.free(report.duplicates);
        allocator.free(report.stale);
    }

    // Print report header
    std.debug.print("Audit Report - Vault: {s}\n", .{vault_id});
    std.debug.print("──────────────────────────────────────\n", .{});
    std.debug.print("Total passwords:  {d}\n", .{report.total});
    std.debug.print("Weak:             {d}\n", .{report.weak.len});
    std.debug.print("Fair:             {d}\n", .{report.fair.len});
    std.debug.print("Strong+:          {d}\n", .{if (report.total > report.weak.len + report.fair.len) report.total - report.weak.len - report.fair.len else 0});
    std.debug.print("Duplicate groups: {d}\n", .{report.duplicates.len});
    std.debug.print("Stale entries:    {d}\n", .{report.stale.len});

    if (report.weak.len > 0) {
        std.debug.print("\nWeak passwords:\n", .{});
        for (report.weak) |entry| {
            const compact_id = if (entry.id.len > 8) entry.id[0..8] else entry.id;
            std.debug.print("  {s}  {s:<20}  score: {d} ({s})\n", .{ compact_id, entry.title, entry.score, @tagName(entry.label) });
        }
    }

    if (report.duplicates.len > 0) {
        std.debug.print("\nDuplicate passwords:\n", .{});
        for (report.duplicates) |group| {
            std.debug.print("  ", .{});
            for (group.entries, 0..) |entry, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{entry.title});
            }
            std.debug.print("  (same password)\n", .{});
        }
    }

    if (report.stale.len > 0) {
        std.debug.print("\nStale (not updated in 180+ days):\n", .{});
        for (report.stale) |entry| {
            const compact_id = if (entry.id.len > 8) entry.id[0..8] else entry.id;
            std.debug.print("  {s}  {s:<20}  last updated {d} days ago\n", .{ compact_id, entry.title, entry.days_since_update orelse 0 });
        }
    }
}
```

Update `show_password` to handle the `--strength` flag. Change the function signature and body:

**Change signature from:**
```zig
fn show_password(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, id: []const u8, show_pwd: bool) !void {
```

**To:**
```zig
fn show_password(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, id: []const u8, show_pwd: bool, show_strength: bool) !void {
```

Update the dispatch call from:
```zig
.show => |s| show_password(allocator, io, dir, s.id, s.show_password) catch |err| ...
```
To:
```zig
.show => |s| show_password(allocator, io, dir, s.id, s.show_password, s.strength) catch |err| ...
```

At the end of `show_password`, after the `if (!show_pwd)` hint, add:
```zig
if (show_strength) {
    var placeholder_key: [32]u8 = [_]u8{0x42} ** 32;
    const decrypted = try field.decrypt_field(entry.password, &placeholder_key, allocator);
    defer allocator.free(decrypted);
    const result = password_strength.score(allocator, decrypted);
    defer allocator.free(result.flags);
    std.debug.print("Password strength: {d}/100 — {s}\n", .{ result.score, @tagName(result.label) });
}
```

Add to imports at top of password.zig:

```zig
const password_strength = @import("password_strength.zig");
const password_audit = @import("password_audit.zig");
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (4 new tests)

- [ ] **Step 7: Commit**

```bash
git add src/core/password.zig src/core/password_strength.zig src/core/password_audit.zig
git commit -m "feat: wire password strength and audit CLI commands"
```

---

### Task 4: Add AuditEmptyVault error to error taxonomy

**Files:**
- Modify: `src/core/errors.zig` (SP01, create if not exists)

- [ ] **Step 1: Add error to error taxonomy**

If `src/core/errors.zig` exists, add `AuditEmptyVault` to the error set. If it doesn't exist, create it:

```zig
const std = @import("std");

pub const Error = error{
    PasswordNotFound,
    VaultLocked,
    EmptyPassword,
    AllCharsetsDisabled,
    AuditEmptyVault,
};
```

- [ ] **Step 2: Commit**

```bash
git add src/core/errors.zig
git commit -m "feat: add AuditEmptyVault error to taxonomy"
```

---

### Self-review notes

- The strength scorer (`password_strength.zig`) is fully standalone and can be implemented and tested independently of SP11.
- The audit module (`password_audit.zig`) depends on SP11's `field.encrypt_field`/`decrypt_field` and `storage.json_password.load_passwords`. These interfaces are well-defined in SP11's spec.
- The CLI wiring (`password.zig`) extends SP11's file. If SP11 hasn't been implemented yet, this task should be deferred until SP11's `PasswordArgs` and dispatch exist.
- All pattern detection helpers (`find_sequential`, `find_keyboard_pattern`, `find_repeated_chars`) are package-private in `password_strength.zig` and tested implicitly through the `score()` tests.
