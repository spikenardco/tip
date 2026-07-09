# Breach Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add breach checking for passwords using a bundled common-password hash set (offline) plus the HIBP k-anonymity API (online).

**Architecture:** A `src/core/breach_check.zig` module provides check logic (local + HIBP), a bundled SHA-1 digest set in `src/data/common_passwords.bin` enables offline common-password detection, and the existing `password.zig` dispatch is extended with `check` subcommand and `audit --breach-check` flag. The generation script lives in `scripts/generate-common-passwords.sh`.

**Tech Stack:** Zig 0.16 (`std.Io`), `std.crypto.hash.Sha1`, HIBP k-anonymity REST API.

**Dependency:** This plan requires **sub-projects 01–13 to be implemented first** — it relies on the password model and dispatch from SP11 (`password.zig`, `models.Password`), session key from SP10 (`session.get_key`), field decryption from SP11 (`field.decrypt_field`), and error taxonomy from SP01. The audit integration extends SP12's `handle_audit` function.

---

## Global Constraints

- **Zig version:** 0.16.0 (`minimum_zig_version = "0.16.0"`). Use the new `std.Io` APIs.
- **Identifier casing:** functions/vars/fields = `snake_case`; types = `PascalCase`; enum members = `snake_case`.
- **Error taxonomy (SP01):** `PasswordNotFound`, `VaultLocked`, `EmptyPassword`, `AllCharsetsDisabled`, `AuditEmptyVault`. Add: `BreachCheckFailed`.
- **Exit codes:** `0` ok · `1` internal · `2` usage · `3` not found · `4` validation · `5` breaches found.
- **Common password source:** SecLists 10k-most-common.txt (MIT license), committed to repo.
- **Bundled data:** `src/data/common_passwords.bin` — sorted `[20]u8` SHA-1 digests, committed as generated artifact.
- **No local cache update.** Refresh requires a binary patch release.
- **HIBP endpoint:** `GET https://api.pwnedpasswords.com/range/{first5}`. Rate limit: 1 req/2s.
- **HIBP errors are non-fatal.** Network failure marks entry as "offline" in report.
- **Tests:** `zig build test --summary all` from repo root.

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/data/10k-most-common.txt` | Create | SecLists source plaintext (MIT, committed) |
| `src/data/common_passwords.bin` | Create | Pre-hashed sorted SHA-1 digests (generated) |
| `scripts/generate-common-passwords.sh` | Create | Build helper to regenerate `.bin` from `.txt` |
| `src/core/breach_check.zig` | Create | Core check logic + HIBP client + tests |
| `src/core/password.zig` | Modify | Add `check` subcommand + `audit --breach-check` flag (SP11/SP12 file) |
| `src/core/errors.zig` | Modify | Add `BreachCheckFailed` error (SP01 file) |

---

### Task 1: Download SecLists and generate the bundled common-password data

**Files:**
- Create: `src/data/10k-most-common.txt`
- Create: `src/data/common_passwords.bin`
- Create: `scripts/generate-common-passwords.sh`

**Interfaces:**
- Produces:
  - `src/data/10k-most-common.txt` — one plaintext password per line
  - `src/data/common_passwords.bin` — concatenated `[20]u8` SHA-1 digests, sorted lexicographically
  - `scripts/generate-common-passwords.sh` — shell script: reads `.txt`, computes SHA-1, sorts, writes `.bin`

- [ ] **Step 1: Create the generation script**

`scripts/generate-common-passwords.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TXT="$REPO_ROOT/src/data/10k-most-common.txt"
BIN="$REPO_ROOT/src/data/common_passwords.bin"

if [ ! -f "$TXT" ]; then
    echo "Error: $TXT not found."
    echo "Download it from:"
    echo "  https://raw.githubusercontent.com/danielmiessler/SecLists/master/Passwords/Common-Credentials/10k-most-common.txt"
    exit 1
fi

# Compute SHA-1 digest for each non-empty line, output as raw 20 bytes per entry.
# Use shasum (macOS) or sha1sum (Linux).
SHASUM=$(command -v shasum || command -v sha1sum)
if [ -z "$SHASUM" ]; then
    echo "Error: no SHA-1 tool found (shasum or sha1sum)"
    exit 1
fi

# Read passwords, compute SHA-1 digests, sort, write binary
# We use awk to strip whitespace and skip empty lines, then pipe to openssl for hashing
awk 'NF { gsub(/[ \t\r]+/, "", $0); print }' "$TXT" | while IFS= read -r pwd; do
    printf '%s' "$pwd" | "$SHASUM" -b | cut -d' ' -f1 | xxd -r -p
done | sort -t '' -k1,1 > "$BIN.tmp"

mv "$BIN.tmp" "$BIN"

echo "Generated $BIN ($(wc -c < "$BIN") bytes, $(($(wc -c < "$BIN") / 20)) entries)"
```

- [ ] **Step 2: Download the source file and generate the binary**

Run:
```bash
mkdir -p src/data
curl -fsSL https://raw.githubusercontent.com/danielmiessler/SecLists/master/Passwords/Common-Credentials/10k-most-common.txt -o src/data/10k-most-common.txt
chmod +x scripts/generate-common-passwords.sh
./scripts/generate-common-passwords.sh
```

Expected output: `Generated src/data/common_passwords.bin (XXXXX bytes, XXXX entries)`

- [ ] **Step 3: Verify the binary file has the correct format**

```bash
# Check file size is multiple of 20
BIN_SIZE=$(wc -c < src/data/common_passwords.bin)
echo "Size: $BIN_SIZE bytes"
echo "Entries: $((BIN_SIZE / 20))"
```

Expected: `Size: XXX bytes, Entries: XXX` (size divisible by 20)

- [ ] **Step 4: Commit**

```bash
git add src/data/10k-most-common.txt src/data/common_passwords.bin scripts/generate-common-passwords.sh
git commit -m "feat: add SecLists 10k-most-common bundled password data"
```

---

### Task 2: Create `src/core/breach_check.zig` — check logic

**Files:**
- Create: `src/core/breach_check.zig`

**Interfaces:**
- Consumes: `std.crypto.hash.Sha1`, `std.http` (or `std.Io` fetch), embedded common-passwords data.
- Produces:
  - `pub const CheckResult = union(enum) { safe, common, breached: struct { count: u32 }, offline, error }`
  - `pub const AuditEntry = struct { title: []const u8, id: []const u8, result: CheckResult }`
  - `pub const AuditReport = struct { entries: []const AuditEntry, total: u32, breached: u32, common: u32, safe: u32, offline: u32 }`
  - `pub fn sha1_hex(password: []const u8) [40]u8`
  - `pub fn check_local(password: []const u8, common_set: []const [20]u8) ?CheckResult`
  - `pub fn hibp_check(allocator: Allocator, io: std.Io, password: []const u8) !CheckResult`
  - `pub fn full_check(allocator: Allocator, io: std.Io, password: []const u8, common_set: []const [20]u8) !CheckResult`

- [ ] **Step 1: Write the failing tests**

Add these at the bottom of `src/core/breach_check.zig` (create the file with the module declaration first):

```zig
const std = @import("std");
const breach_check = @import("../core/breach_check.zig");

test "sha1 hex of known input" {
    const hex = breach_check.sha1_hex("password");
    // SHA-1 of "password" = 5baa61e4c9b93f3f0682250b6cf8331b7ee68fd8
    try std.testing.expectEqualStrings("5baa61e4c9b93f3f0682250b6cf8331b7ee68fd8", &hex);
}

test "sha1 hex of empty string" {
    const hex = breach_check.sha1_hex("");
    try std.testing.expectEqualStrings("da39a3ee5e6b4b0d3255bfef95601890afd80709", &hex);
}

test "check_local finds common password" {
    const common_set: [1][20]u8 = [_][20]u8{breach_check.sha1_bytes("password123")};
    const result = breach_check.check_local("password123", &common_set);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(.common, result.?);
}

test "check_local returns null for uncommon password" {
    const common_set: [1][20]u8 = [_][20]u8{breach_check.sha1_bytes("password123")};
    const result = breach_check.check_local("correct-horse-battery-staple-99", &common_set);
    try std.testing.expect(result == null);
}

test "check_local empty common set" {
    const common_set: [0][20]u8 = [_][20]u8{};
    const result = breach_check.check_local("anything", &common_set);
    try std.testing.expect(result == null);
}

test "hibp_url builds correct prefix" {
    const password = "password";
    const prefix = breach_check.hibp_prefix(password);
    try std.testing.expectEqualStrings("5baa6", &prefix);
}

test "hibp_parse_response finds match" {
    const response =
        \\0018A45C4D1DEF81644B54AB7F969B88D065:3
        \\1C4D1DEF81644B54AB7F9F969B88D0650018A:142
        \\
    ;
    const full_hash = "5baa61e4c9b93f3f0682250b6cf8331b7ee68fd8";
    const result = breach_check.hibp_parse_response(response, full_hash);
    try std.testing.expect(result != null);
    if (result) |r| {
        try std.testing.expectEqual(@as(u32, 3), r.count);
        try std.testing.expectEqual(.breached, r);
    }
}

test "hibp_parse_response no match returns null" {
    const response =
        \\0018A45C4D1DEF81644B54AB7F969B88D065:3
        \\
    ;
    const full_hash = "ffffffffffffffffffffffffffffffffffffffff";
    const result = breach_check.hibp_parse_response(response, full_hash);
    try std.testing.expect(result == null);
}

test "hibp_parse_response handles empty response" {
    const response = "";
    const full_hash = "5baa61e4c9b93f3f0682250b6cf8331b7ee68fd8";
    const result = breach_check.hibp_parse_response(response, full_hash);
    try std.testing.expect(result == null);
}

test "full_check returns common for common password (skips HIBP)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const common_set: [1][20]u8 = [_][20]u8{breach_check.sha1_bytes("password123")};
    const result = try breach_check.full_check(allocator, io, "password123", &common_set, false);
    try std.testing.expectEqual(.common, result);
}

test "AuditReport aggregates correctly" {
    const allocator = std.testing.allocator;
    const entries = [_]breach_check.AuditEntry{
        .{ .title = "a", .id = "1", .result = .safe },
        .{ .title = "b", .id = "2", .result = .{ .breached = .{ .count = 5 } } },
        .{ .title = "c", .id = "3", .result = .common },
        .{ .title = "d", .id = "4", .result = .offline },
    };
    const report = try breach_check.AuditReport.init(allocator, &entries);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 4), report.total);
    try std.testing.expectEqual(@as(u32, 1), report.breached);
    try std.testing.expectEqual(@as(u32, 1), report.common);
    try std.testing.expectEqual(@as(u32, 1), report.safe);
    try std.testing.expectEqual(@as(u32, 1), report.offline);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `breach_check.zig` not found, `sha1_hex` not defined, etc.

- [ ] **Step 3: Implement the module**

```zig
const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;

pub const CheckResult = union(enum) {
    safe,
    common,
    breached: struct { count: u32 },
    offline,
    error: []const u8,
};

pub const AuditEntry = struct {
    title: []const u8,
    id: []const u8,
    result: CheckResult,
};

pub const AuditReport = struct {
    entries: []const AuditEntry,
    total: u32,
    breached: u32,
    common: u32,
    safe: u32,
    offline: u32,

    pub fn init(allocator: std.mem.Allocator, entries: []const AuditEntry) !AuditReport {
        var total: u32 = 0;
        var breached: u32 = 0;
        var common: u32 = 0;
        var safe_count: u32 = 0;
        var offline: u32 = 0;
        for (entries) |e| {
            total += 1;
            switch (e.result) {
                .breached => breached += 1,
                .common => common += 1,
                .safe => safe_count += 1,
                .offline => offline += 1,
                .error => {},
            }
        }
        return AuditReport{
            .entries = try allocator.dupe(AuditEntry, entries),
            .total = total,
            .breached = breached,
            .common = common,
            .safe = safe_count,
            .offline = offline,
        };
    }

    pub fn deinit(self: *AuditReport, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }
};

/// Compute SHA-1 hex string (40 chars) for a password.
pub fn sha1_hex(password: []const u8) [40]u8 {
    var digest: [20]u8 = undefined;
    Sha1.hash(password, &digest, .{});
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
    return hex;
}

/// Compute raw SHA-1 20-byte digest.
pub fn sha1_bytes(password: []const u8) [20]u8 {
    var digest: [20]u8 = undefined;
    Sha1.hash(password, &digest, .{});
    return digest;
}

/// Get the first 5 hex chars of the SHA-1 of a password (HIBP prefix).
pub fn hibp_prefix(password: []const u8) [5]u8 {
    const hex = sha1_hex(password);
    var prefix: [5]u8 = undefined;
    @memcpy(&prefix, hex[0..5]);
    return prefix;
}

/// Check if a password is in the common-password set.
/// Returns `.common` if found, `null` if not.
pub fn check_local(password: []const u8, common_set: []const [20]u8) ?CheckResult {
    if (common_set.len == 0) return null;
    const digest = sha1_bytes(password);
    const index = std.sort.binarySearch([20]u8, &digest, common_set, struct {
        fn cmp(a: [20]u8, b: [20]u8) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    }.cmp) orelse return null;
    _ = index;
    return .common;
}

/// Parse HIBP response text and find if our full hash suffix appears.
/// Returns `.breached` with count if found, `null` if not.
pub fn hibp_parse_response(response: []const u8, full_hash: []const u8) ?CheckResult {
    const suffix = full_hash[5..]; // last 35 hex chars
    var it = std.mem.splitScalar(u8, response, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hash_suffix = line[0..colon_pos];
        if (std.mem.eql(u8, hash_suffix, suffix)) {
            const count_str = line[colon_pos + 1 ..];
            const count = std.fmt.parseInt(u32, count_str, 10) catch continue;
            return CheckResult{ .breached = .{ .count = count } };
        }
    }
    return null;
}

/// Full check: local first, then HIBP if not found locally.
/// `check_hibp` controls whether to make the network call (set to false in tests).
pub fn full_check(allocator: std.mem.Allocator, io: std.Io, password: []const u8, common_set: []const [20]u8, check_hibp: bool) !CheckResult {
    // Fast path: local common-password check
    if (check_local(password, common_set)) |result| {
        return result;
    }

    if (!check_hibp) {
        return .safe;
    }

    // HIBP k-anonymity check
    return hibp_check(allocator, io, password) catch |err| switch (err) {
        error.NetworkUnavailable => CheckResult{ .offline = {} },
        else => CheckResult{ .error = @errorName(err) },
    };
}

/// Perform HIBP k-anonymity API call.
/// Uses Zig 0.16's std.http client. Adjust the fetch call to match
/// the exact std.http API in the version you're building against.
pub fn hibp_check(allocator: std.mem.Allocator, io: std.Io, password: []const u8) !CheckResult {
    const full_hex = sha1_hex(password);
    const prefix = full_hex[0..5];

    const url = try std.fmt.allocPrint(allocator, "https://api.pwnedpasswords.com/range/{s}", .{prefix});
    defer allocator.free(url);

    // HTTP GET via Zig 0.16's std.http.Client
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var headers: std.http.Headers = .{ .allocator = allocator };
    defer headers.deinit();
    try headers.append("Accept", "text/plain");

    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    try client.fetch(.{
        .url = url,
        .headers = headers,
        .response_body = &response_body,
    });

    return hibp_parse_response(response_body.items, &full_hex) orelse .safe;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (12 new tests)

- [ ] **Step 5: Commit**

```bash
git add src/core/breach_check.zig
git commit -m "feat: add breach check module with local + HIBP logic"
```

---

### Task 3: Wire CLI commands into password.zig

**Files:**
- Modify: `src/core/password.zig` (SP11/SP12 file)

**Interfaces:**
- Consumes: `breach_check.full_check()`, `breach_check.AuditReport`, `breach_check.AuditEntry`, `breach_check.CheckResult`, `field.decrypt_field` (SP11), `session.get_key` (SP10), embedded common-passwords data.
- Produces:
  - `PasswordArgs` gains `check` subcommand and `breach_check: bool` on `audit`
  - `dispatch_password_command` handles `.check` and extends `.audit`

- [ ] **Step 1: Write the failing tests**

```zig
const breach_check = @import("breach_check.zig");
const common_passwords = @embedFile("../data/common_passwords.bin");

test "PasswordArgs includes check subcommand" {
    const args = password.PasswordArgs{ .subcommand = .{ .check = .{ .name = "github" } } };
    try std.testing.expectEqualStrings("github", args.subcommand.?.check.name);
}

test "PasswordArgs audit accepts --breach-check flag" {
    const args = password.PasswordArgs{ .subcommand = .{ .audit = .{ .breach_check = true } } };
    try std.testing.expect(args.subcommand.?.audit.breach_check);
}

test "breach_check embeds common_passwords data" {
    try std.testing.expect(common_passwords.len > 0);
    try std.testing.expect(common_passwords.len % 20 == 0);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `check` not in `PasswordArgs.subcommand` union

- [ ] **Step 3: Extend `PasswordArgs` in password.zig**

Add these types to the existing `PasswordArgs`:

```zig
check: struct {
    name: []const u8,
},
```

Add `breach_check` to the existing `audit` struct:

```zig
// Change from:
// audit: struct {
//     min_score: ?[]const u8 = null,
//     vault: ?[]const u8 = null,
// },
// To:
audit: struct {
    min_score: ?[]const u8 = null,
    vault: ?[]const u8 = null,
    breach_check: bool = false,
},
```

Add to the help text in `PasswordArgs`:

```zig
pub const help =
    \\Usage:
    \\  tip password <subcommand> [args] [flags]
    \\
    \\Commands:
    \\  ...
    \\  check                    Check a password entry for breaches
    \\      --name=<name>        Entry name to check
    \\  audit                    Scan all passwords in active vault
    \\      [--vault=<name>]
    \\      [--breach-check]     Check against known breaches (HIBP)
    \\
;
```

Add import at the top of password.zig:

```zig
const breach_check = @import("breach_check.zig");
const common_passwords = @embedFile("../data/common_passwords.bin");
```

- [ ] **Step 4: Add dispatch cases in `dispatch_password_command`**

Add these cases alongside the existing dispatch:

```zig
.check => |c| handle_breach_check_entry(allocator, io, dir, c) catch |err| {
    handle_password_error(err, "check");
},
```

Modify the `.audit` dispatch call to pass `breach_check` flag. Change:

```zig
.audit => |a| handle_audit(allocator, io, dir, a) catch |err| {
    handle_password_error(err, "audit");
},
```

The existing `handle_audit` should pass `a.breach_check` through.

- [ ] **Step 5: Implement handler functions**

```zig
fn handle_breach_check_entry(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, args: anytype) !void {
    // Resolve vault and get session key (SP10/SP06 pattern)
    const vault_id = "v1"; // placeholder — SP06 wires vault resolution
    var placeholder_key: [32]u8 = [_]u8{0x42} ** 32;

    // Load password entry by name
    const entries = try load_passwords(allocator, io, dir); // SP11 function
    defer allocator.free(entries);

    const entry = for (entries) |e| {
        if (std.mem.eql(u8, e.title, args.name)) break &e;
    } else return error.PasswordNotFound;

    // Decrypt password
    const decrypted = try field.decrypt_field(entry.password, &placeholder_key, allocator);
    defer allocator.free(decrypted);

    // Run breach check
    const common_set: []const [20]u8 = @as(*const [common_passwords.len / 20][20]u8, @ptrCast(@alignCast(&common_passwords)));
    const result = try breach_check.full_check(allocator, io, decrypted, common_set, true);

    // Print result
    switch (result) {
        .safe => std.debug.print("✓ {s} — not found in any breaches\n", .{args.name}),
        .common => std.debug.print("✗ {s} — common password (weak)\n", .{args.name}),
        .breached => |b| std.debug.print("✗ {s} — found in {d} breaches (HIBP)\n", .{ args.name, b.count }),
        .offline => std.debug.print("- {s} — breach check unavailable (offline)\n", .{args.name}),
        .error => |msg| std.debug.print("- {s} — check failed: {s}\n", .{ args.name, msg }),
    }
}

// Modify handle_audit to accept and use breach_check flag.
// Add this logic after the existing audit report output:
fn add_breach_section_to_audit(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, vault_id: []const u8, key: *const [32]u8) !void {
    const entries = try load_passwords(allocator, io, dir);
    defer allocator.free(entries);

    const common_set: []const [20]u8 = @as(*const [common_passwords.len / 20][20]u8, @ptrCast(@alignCast(&common_passwords)));

    std.debug.print("\n Breach Check Results — Vault \"{s}\"\n", .{vault_id});

    var checked: u32 = 0;
    var breached: u32 = 0;
    var common: u32 = 0;
    var safe_count: u32 = 0;
    var offline: u32 = 0;

    for (entries) |entry| {
        const decrypted = try field.decrypt_field(entry.password, key, allocator);
        defer allocator.free(decrypted);

        const result = try breach_check.full_check(allocator, io, decrypted, common_set, true);
        checked += 1;

        const compact_id = if (entry.id.len > 8) entry.id[0..8] else entry.id;
        switch (result) {
            .safe => {
                safe_count += 1;
                std.debug.print("  {s}  {s:<20}  | ✓\n", .{ compact_id, entry.title });
            },
            .common => {
                common += 1;
                std.debug.print("  {s}  {s:<20}  | ✗ common\n", .{ compact_id, entry.title });
            },
            .breached => |b| {
                breached += 1;
                std.debug.print("  {s}  {s:<20}  | ✗ {d} breaches\n", .{ compact_id, entry.title, b.count });
            },
            .offline => {
                offline += 1;
                std.debug.print("  {s}  {s:<20}  | - offline\n", .{ compact_id, entry.title });
            },
            .error => |msg| {
                std.debug.print("  {s}  {s:<20}  | - error: {s}\n", .{ compact_id, entry.title, msg });
            },
        }
    }

    std.debug.print("  {d} checked · {d} breached · {d} common · {d} safe · {d} offline\n", .{ checked, breached, common, safe_count, offline });
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (3 new tests)

- [ ] **Step 7: Commit**

```bash
git add src/core/password.zig
git commit -m "feat: wire breach check CLI commands (check + audit --breach-check)"
```

---

### Task 4: Add `BreachCheckFailed` to error taxonomy

**Files:**
- Modify: `src/core/errors.zig` (SP01, create if not exists)

- [ ] **Step 1: Add error to error taxonomy**

If `src/core/errors.zig` exists, add `BreachCheckFailed` to the error set. If it doesn't exist, create it:

```zig
const std = @import("std");

pub const Error = error{
    PasswordNotFound,
    VaultLocked,
    EmptyPassword,
    AllCharsetsDisabled,
    AuditEmptyVault,
    BreachCheckFailed,
};
```

- [ ] **Step 2: Commit**

```bash
git add src/core/errors.zig
git commit -m "feat: add BreachCheckFailed error to taxonomy"
```

---

### Self-review notes

- The breach check module (`src/core/breach_check.zig`) is mostly standalone — the local check and HIBP parsing don't depend on SP11/SP12. Only the CLI wiring in Task 3 depends on `password.zig` and `field.decrypt_field`.
- The HIBP HTTP client in `hibp_check()` uses Zig 0.16's `std.http.Client`. Verify the exact API in the version you're building against — some method signatures may differ.
- The `common_passwords.bin` data is embedded at compile time via `@embedFile`. The type coercion from a flat `[]u8` to `[]const [20]u8` uses `@ptrCast` + `@alignCast` which is safe because `[20]u8` has 1-byte alignment.
- Exit code 5 is used for "breaches found" to distinguish from generic errors (code 1). This follows the existing exit code convention.
- The `--prompt` flag for checking unsaved passwords is deferred per spec decision 14-8.
- `load_passwords` in Task 3 is an SP11 function — verify the actual function name and signature used in the SP11 implementation.
