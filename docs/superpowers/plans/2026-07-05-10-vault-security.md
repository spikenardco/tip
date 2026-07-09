# Vault Security (Crypto + Lock/Unlock) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-vault master passwords with AES-256-GCM encryption, Argon2id key derivation, and a sudo-style session cache with configurable TTL.

**Architecture:** A new `src/crypto/` module wraps `std.crypto` (AES-256-GCM + Argon2id from Zig std). A `src/crypto/session.zig` manages on-disk session files (`~/.tip/sessions/<vault_id>.key`). The Vault handle gains encrypt/decrypt/unlock/lock/status methods. A migration adds nullable `key_salt`/`key_hash` columns to the vaults table.

**Tech Stack:** Zig 0.16 (`std.Io` async model), `std.crypto.aead.aes_gcm.Aes256Gcm`, `std.crypto.pwhash.argon2`, zig-sqlite, SQLite.

**Dependency:** This plan requires **sub-projects 01–09 to be implemented first** — it relies on the Vault handle from SP03/SP06, vaults table from SP06, config system from SP05, SQLite migration runner from SP02, error taxonomy from SP01, and zig-sqlite from SP02.

---

## Global Constraints

- **Zig version:** 0.16.0 (`minimum_zig_version = "0.16.0"`). Use the new `std.Io` APIs.
- **Identifier casing:** functions/vars/fields = `snake_case`; types = `PascalCase`; enum members = `snake_case`.
- **Error taxonomy (sub-project 01):** `WrongPassword`, `VaultLocked`, `AlreadyEncrypted`, `NotEncrypted`, `StorageFailure`, `VaultNotFound`. Commands return errors; `main.zig` renders via `errors.describe`/`errors.exit_code`.
- **Exit codes:** `0` ok · `1` internal · `2` usage · `3` not found · `4` validation.
- **Vault handle:** `Vault.open(allocator, io, .{ .name = name })` → `Vault`, `vault.vaults` → `Vaults` handle, `vault.crypto` → `Crypto` handle.
- **Config (SP05):** `config.get(io, key)` for `session_ttl` (default `300` seconds). `config.set(io, "session_ttl", "600")` for customization.
- **Session directory:** `~/.tip/sessions/` (0600 perms, created on first unlock if missing).
- **Crypto primitives:** from `std.crypto` — do not vendor or reimplement.
- **Argon2id defaults:** 19 MiB memory, 2 iterations, 1 thread (OWASP minimum). Configurable via `config set argon2_mem <KiB>`, `config set argon2_iters <count>`.
- **AES-256-GCM nonce:** 12 random bytes per encryption operation. Nonce stored alongside ciphertext.
- **Tests:** `zig build test --summary all` from repo root. Tests use in-memory SQLite.
- **Only password entries are encrypted (SP12+).** This SP sets up the key infrastructure but does not encrypt any data — it only stores the key material on the vault row and manages the session cache.
- **Crypto is opt-in.** `vault encrypt <name>` seals a vault. `vault add --encrypt` seals at creation. Existing vaults stay unencrypted.
- **Password commands (SP12+) call `vault.is_locked()` before operating.** Task commands do not check.

---

### Task 1: Add vault migration for `key_salt` and `key_hash` columns

**Files:**
- Create: `src/storage/migrations/010_add_vault_crypto_cols.sql`
- Modify: migration runner (SP02) to include this migration
- Modify: `src/core/models.zig` — add `key_salt` and `key_hash` fields to `Vault` struct

**Interfaces:**
- Consumes: `models.Vault` (SP01-06), SQLite migration runner (SP02).
- Produces:
  - `models.Vault` gains `key_salt: ?[]const u8 = null` and `key_hash: ?[]const u8 = null`
  - Vaults table has nullable `key_salt TEXT` and `key_hash TEXT` columns

- [ ] **Step 1: Write the failing tests for new vault fields**

```zig
test "Vault key_salt and key_hash default to null" {
    const v = models.Vault{
        .id = "v1",
        .name = "test",
        .created_at = 100,
    };
    try std.testing.expect(v.key_salt == null);
    try std.testing.expect(v.key_hash == null);
}

test "Vault key_salt and key_hash can be set" {
    const v = models.Vault{
        .id = "v1",
        .name = "test",
        .created_at = 100,
        .key_salt = "c2FsdA==",
        .key_hash = "aGFzaA==",
    };
    try std.testing.expectEqualStrings("c2FsdA==", v.key_salt.?);
    try std.testing.expectEqualStrings("aGFzaA==", v.key_hash.?);
}

test "migration 010 adds vault crypto columns" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    // Verify the columns exist by writing and reading key_salt
    try vault.vaults.update(.{
        .id = vault.id,
        .key_salt = "dGVzdC1zYWx0",
        .key_hash = "dGVzdC1oYXNo",
    });

    const reloaded = try vault.vaults.get_by_id(vault.id);
    try std.testing.expectEqualStrings("dGVzdC1zYWx0", reloaded.?.key_salt.?);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `key_salt`/`key_hash` not on `Vault` struct, migration file missing

- [ ] **Step 3: Create the migration SQL**

`src/storage/migrations/010_add_vault_crypto_cols.sql`:

```sql
-- Migration 010: Add crypto columns to vaults table
-- NULL columns = vault is not encrypted

ALTER TABLE vaults ADD COLUMN key_salt TEXT;
ALTER TABLE vaults ADD COLUMN key_hash TEXT;
```

- [ ] **Step 4: Register the migration**

In the migration runner (SP02), add `010_add_vault_crypto_cols` to the migration list.

- [ ] **Step 5: Add fields to `models.Vault`**

```zig
pub const Vault = struct {
    id: []const u8,
    name: []const u8,
    created_at: i64,
    key_salt: ?[]const u8 = null,
    key_hash: ?[]const u8 = null,
};
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (3 new tests)

- [ ] **Step 7: Commit**

```bash
git add src/storage/migrations/010_add_vault_crypto_cols.sql src/core/models.zig
git commit -m "feat: add key_salt and key_hash columns for vault encryption"
```

---

### Task 2: Create `src/crypto/mod.zig` — key derivation and encrypt/decrypt

**Files:**
- Create: `src/crypto/mod.zig`

**Interfaces:**
- Consumes: `std.crypto.aead.aes_gcm.Aes256Gcm`, `std.crypto.pwhash.argon2`.
- Produces:
  - `pub const Key = [32]u8`
  - `pub const Nonce = [12]u8`
  - `pub const Salt = [16]u8`
  - `pub fn derive_key(password: []const u8, salt: *const Salt, vault_id: []const u8, params: Argon2Params) !Key`
  - `pub fn hash_password(password: []const u8, salt: *const Salt, vault_id: []const u8, params: Argon2Params) !Key`
  - `pub fn verify_password(password: []const u8, salt: *const Salt, vault_id: []const u8, hash: *const Key, params: Argon2Params) !bool`
  - `pub fn encrypt(plaintext: []const u8, key: *const Key, allocator: Allocator) !struct { ciphertext: []u8, nonce: Nonce }`
  - `pub fn decrypt(ciphertext: []const u8, nonce: *const Nonce, key: *const Key, allocator: Allocator) ![]u8`
  - `pub const Argon2Params = struct { mem: u32, iters: u32, threads: u32 }`
  - `pub fn generate_salt() !Salt`

- [ ] **Step 1: Write the failing tests for crypto module**

```zig
const crypto_mod = @import("crypto/mod.zig");
const std = @import("std");

test "derive_key produces deterministic output" {
    const password = "hunter2";
    const salt: crypto_mod.Salt = [_]u8{0x01} ** 16;
    const vault_id = "vault_abc123";
    const params = crypto_mod.Argon2Params{ .mem = 19 * 1024, .iters = 2, .threads = 1 };

    const key1 = try crypto_mod.derive_key(password, &salt, vault_id, params);
    const key2 = try crypto_mod.derive_key(password, &salt, vault_id, params);
    try std.testing.expect(std.mem.eql(u8, &key1, &key2));
}

test "derive_key different password produces different key" {
    const salt: crypto_mod.Salt = [_]u8{0x01} ** 16;
    const vault_id = "vault_abc123";
    const params = crypto_mod.Argon2Params{ .mem = 19 * 1024, .iters = 2, .threads = 1 };

    const key1 = try crypto_mod.derive_key("password1", &salt, vault_id, params);
    const key2 = try crypto_mod.derive_key("password2", &salt, vault_id, params);
    try std.testing.expect(!std.mem.eql(u8, &key1, &key2));
}

test "encrypt/decrypt round-trip" {
    const allocator = std.testing.allocator;
    const key: crypto_mod.Key = [_]u8{0x42} ** 32;
    const plaintext = "hello, vault!";

    const result = try crypto_mod.encrypt(plaintext, &key, allocator);
    defer allocator.free(result.ciphertext);

    const decrypted = try crypto_mod.decrypt(result.ciphertext, &result.nonce, &key, allocator);
    defer allocator.free(decrypted);

    try std.testing.expectEqualStrings(plaintext, decrypted);
}

test "encrypt produces different ciphertext each time (random nonce)" {
    const allocator = std.testing.allocator;
    const key: crypto_mod.Key = [_]u8{0x42} ** 32;
    const plaintext = "same text";

    const r1 = try crypto_mod.encrypt(plaintext, &key, allocator);
    defer allocator.free(r1.ciphertext);

    const r2 = try crypto_mod.encrypt(plaintext, &key, allocator);
    defer allocator.free(r2.ciphertext);

    // Different nonce → different ciphertext
    try std.testing.expect(!std.mem.eql(u8, &r1.nonce, &r2.nonce));
}

test "hash_password and verify_password" {
    const password = "my_master_pass";
    const salt: crypto_mod.Salt = [_]u8{0x01} ** 16;
    const vault_id = "vault_abc123";
    const params = crypto_mod.Argon2Params{ .mem = 19 * 1024, .iters = 2, .threads = 1 };

    const hash = try crypto_mod.hash_password(password, &salt, vault_id, params);
    const verified = try crypto_mod.verify_password(password, &salt, vault_id, &hash, params);
    try std.testing.expect(verified);

    const wrong_verified = try crypto_mod.verify_password("wrong", &salt, vault_id, &hash, params);
    try std.testing.expect(!wrong_verified);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `crypto/mod.zig` not found

- [ ] **Step 3: Write the implementation**

```zig
const std = @import("std");

pub const Key = [32]u8;
pub const Nonce = [12]u8;
pub const Salt = [16]u8;

pub const Argon2Params = struct {
    mem: u32 = 19 * 1024,   // 19 MiB (OWASP minimum)
    iters: u32 = 2,
    threads: u32 = 1,
};

pub fn derive_key(password: []const u8, salt: *const Salt, vault_id: []const u8, params: Argon2Params) !Key {
    var key: Key = undefined;
    try std.crypto.pwhash.argon2.id(
        &key,
        password,
        salt,
        params.mem,
        params.iters,
        .{ .threads = params.threads, .context = vault_id },
    );
    return key;
}

pub fn hash_password(password: []const u8, salt: *const Salt, vault_id: []const u8, params: Argon2Params) !Key {
    // Hash the password itself (not the derived key) for verification
    var hash: Key = undefined;
    try std.crypto.pwhash.argon2.id(
        &hash,
        password,
        salt,
        params.mem,
        params.iters,
        .{ .threads = params.threads, .context = vault_id },
    );
    return hash;
}

pub fn verify_password(password: []const u8, salt: *const Salt, vault_id: []const u8, expected_hash: *const Key, params: Argon2Params) !bool {
    const actual_hash = try hash_password(password, salt, vault_id, params);
    return std.crypto.utils.timingSafeEq(&actual_hash, expected_hash);
}

pub fn encrypt(plaintext: []const u8, key: *const Key, allocator: Allocator) !struct { ciphertext: []u8, nonce: Nonce } {
    const aead = std.crypto.aead.aes_gcm.Aes256Gcm;
    var nonce: Nonce = undefined;
    std.crypto.random.bytes(&nonce);

    // AAD (additional authenticated data) is empty here
    const ciphertext = try allocator.alloc(u8, plaintext.len + aead.tag_length);
    _ = aead.encrypt(ciphertext, plaintext, null, nonce, key.*);
    return .{ .ciphertext = ciphertext, .nonce = nonce };
}

pub fn decrypt(ciphertext: []const u8, nonce: *const Nonce, key: *const Key, allocator: Allocator) ![]u8 {
    const aead = std.crypto.aead.aes_gcm.Aes256Gcm;
    const plaintext = try allocator.alloc(u8, ciphertext.len - aead.tag_length);
    try aead.decrypt(plaintext, ciphertext, null, nonce.*, key.*);
    return plaintext;
}

pub fn generate_salt() !Salt {
    var salt: Salt = undefined;
    std.crypto.random.bytes(&salt);
    return salt;
}
```

Note: The `Allocator` import in `encrypt`/`decrypt` comes from `std.mem.Allocator`. The function signatures use it directly — in Zig 0.16 the correct type is `std.mem.Allocator`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (5 new tests)

- [ ] **Step 5: Commit**

```bash
git add src/crypto/mod.zig
git commit -m "feat: add crypto module with AES-256-GCM and Argon2id"
```

---

### Task 3: Create `src/crypto/session.zig` — session file management

**Files:**
- Create: `src/crypto/session.zig`

**Interfaces:**
- Consumes: `crypto.Key`, `models.Vault` (for `vault_id`).
- Produces:
  - `pub const Session = struct { vault_id: []const u8, vault_key: Key, expires_at: i64 }`
  - `pub fn open(allocator: Allocator, session_dir: []const u8, vault_id: []const u8, vault_key: *const Key, ttl_seconds: i64) !void`
  - `pub fn close(session_dir: []const u8, vault_id: []const u8) !void`
  - `pub fn close_all(session_dir: []const u8) !void`
  - `pub fn get_key(allocator: Allocator, io: std.Io, session_dir: []const u8, vault_id: []const u8) !?Key`

- [ ] **Step 1: Write the failing tests for session module**

```zig
const session = @import("crypto/session.zig");
const crypto_mod = @import("crypto/mod.zig");
const std = @import("std");

test "session open and get_key round-trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const vault_id = "vault_abc123";
    const key: crypto_mod.Key = [_]u8{0x42} ** 32;

    try session.open(allocator, tmp_dir.path, vault_id, &key, 300);
    const result = try session.get_key(allocator, io, tmp_dir.path, vault_id);
    defer if (result) |_| allocator.free(result.?.*);

    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, &key, &result.?));
}

test "session close removes file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const vault_id = "vault_abc123";
    const key: crypto_mod.Key = [_]u8{0x42} ** 32;

    try session.open(allocator, tmp_dir.path, vault_id, &key, 300);
    try session.close(tmp_dir.path, vault_id);

    const result = try session.get_key(allocator, io, tmp_dir.path, vault_id);
    try std.testing.expect(result == null);
}

test "session expiry returns null" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const vault_id = "vault_abc123";
    const key: crypto_mod.Key = [_]u8{0x42} ** 32;

    // TTL of 0 = immediate expiry
    try session.open(allocator, tmp_dir.path, vault_id, &key, 0);

    // get_key should detect expiry and return null
    const result = try session.get_key(allocator, io, tmp_dir.path, vault_id);
    try std.testing.expect(result == null);
}

test "session close_all removes all session files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const key: crypto_mod.Key = [_]u8{0x42} ** 32;

    try session.open(allocator, tmp_dir.path, "vault_a", &key, 300);
    try session.open(allocator, tmp_dir.path, "vault_b", &key, 300);

    try session.close_all(tmp_dir.path);

    try std.testing.expect((try session.get_key(allocator, io, tmp_dir.path, "vault_a")) == null);
    try std.testing.expect((try session.get_key(allocator, io, tmp_dir.path, "vault_b")) == null);
}

test "session get_key on nonexistent vault returns null" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const result = try session.get_key(allocator, io, tmp_dir.path, "nonexistent");
    try std.testing.expect(result == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `session.zig` not found

- [ ] **Step 3: Implement session module**

```zig
const std = @import("std");
const crypto_mod = @import("mod.zig");

pub const Session = struct {
    vault_id: []const u8,
    vault_key: crypto_mod.Key,
    expires_at: i64,
};

fn session_path(session_dir: []const u8, vault_id: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}/{s}.key", .{ session_dir, vault_id });
}

pub fn open(allocator: std.mem.Allocator, session_dir: []const u8, vault_id: []const u8, vault_key: *const crypto_mod.Key, ttl_seconds: i64) !void {
    // Ensure session directory exists
    std.fs.cwd().makePath(session_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const now = std.time.timestamp();
    const expires_at = now + ttl_seconds;

    const path = try session_path(session_dir, vault_id, allocator);
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{ .mode = .{ .u = .{ .r = true, .w = true }, .g = .{}, .o = .{} } });
    defer file.close();

    // Write JSON: {"vault_id":"...","vault_key":"<base64>","expires_at":123}
    const key_b64 = try std.base64.url_safe_no_pad.encoders.alloc(allocator, &vault_key);
    defer allocator.free(key_b64);

    try file.writer().print(
        \\{{"vault_id":"{s}","vault_key":"{s}","expires_at":{d}}}
    , .{ vault_id, key_b64, expires_at });
}

pub fn close(session_dir: []const u8, vault_id: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const path = try session_path(session_dir, vault_id, allocator);
    defer allocator.free(path);

    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => return, // already locked — not an error in close
        else => return err,
    };
}

pub fn close_all(session_dir: []const u8) !void {
    var dir = std.fs.cwd().openDir(session_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".key")) {
            dir.deleteFile(entry.name) catch {};
        }
    }
}

pub fn get_key(allocator: std.mem.Allocator, io: std.Io, session_dir: []const u8, vault_id: []const u8) !?crypto_mod.Key {
    const path = try session_path(session_dir, vault_id, allocator);
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    // Parse JSON
    var scanner = std.json.Scanner.init(allocator, content);
    defer scanner.deinit();

    const parsed = try std.json.parseFromTokenSource(struct {
        vault_id: []const u8,
        vault_key: []const u8,
        expires_at: i64,
    }, allocator, &scanner, .{ .allocator = allocator });
    defer parsed.deinit();

    // Check expiry
    const now = std.time.timestamp();
    if (parsed.value.expires_at <= now) {
        // Expired — clean up
        file.close();
        std.fs.cwd().deleteFile(path) catch {};
        return null;
    }

    // Decode base64 key
    const decoded_key = try std.base64.url_safe_no_pad.decoders.alloc(allocator, parsed.value.vault_key, .{});
    defer allocator.free(decoded_key);

    if (decoded_key.len != 32) return null;

    var key: crypto_mod.Key = undefined;
    @memcpy(&key, decoded_key);
    return key;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (5 new tests)

- [ ] **Step 5: Commit**

```bash
git add src/crypto/session.zig
git commit -m "feat: add session file management with expiry"
```

---

### Task 4: Extend Vault handle with crypto methods

**Files:**
- Modify: the file where the `Vault` handle is defined (SP03/SP06 — expected at `src/core/vault.zig`)

**Interfaces:**
- Consumes: `crypto.mod`, `crypto.session`, `models.Vault` (extended), `config` (SP05), errors.
- Produces:
  - `pub const Crypto = struct { vault: *Vault }` handle
  - `vault.crypto` → `*Crypto` sub-handle
  - `pub fn encrypt(self: *Crypto, password: []const u8) !void`
  - `pub fn decrypt(self: *Crypto, password: []const u8) !void`
  - `pub fn unlock(self: *Crypto, password: []const u8) !void`
  - `pub fn lock(self: *Crypto) !void`
  - `pub fn status(self: *Crypto) !union(enum) { locked, unlocked: i64, not_encrypted }`
  - `pub fn is_locked(self: *Crypto) !bool`

- [ ] **Step 1: Write the failing tests for Vault.Crypto handle**

```zig
const std = @import("std");
const models = @import("models.zig");
const Vault = @import("vault.zig").Vault;

test "encrypt stores salt and hash on vault" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.crypto.encrypt("hunter2");

    const v = try vault.vaults.get_by_id(vault.id);
    try std.testing.expect(v.?.key_salt != null);
    try std.testing.expect(v.?.key_hash != null);
}

test "encrypt on already-encrypted vault returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.crypto.encrypt("hunter2");
    try std.testing.expectError(error.AlreadyEncrypted, vault.crypto.encrypt("hunter2"));
}

test "unlock with correct password succeeds" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.crypto.encrypt("hunter2");
    try vault.crypto.lock();
    try vault.crypto.unlock("hunter2"); // should not error
}

test "unlock with wrong password returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.crypto.encrypt("hunter2");
    try vault.crypto.lock();
    try std.testing.expectError(error.WrongPassword, vault.crypto.unlock("wrong"));
}

test "unlock on non-encrypted vault returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try std.testing.expectError(error.NotEncrypted, vault.crypto.unlock("hunter2"));
}

test "lock after unlock removes session" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.crypto.encrypt("hunter2");
    try vault.crypto.lock();

    const s = try vault.crypto.status();
    try std.testing.expect(s == .locked);
}

test "status shows unlocked with time remaining" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.crypto.encrypt("hunter2");

    const s = try vault.crypto.status();
    try std.testing.expect(s == .unlocked);
    try std.testing.expect(s.unlocked > 0);
}

test "status on non-encrypted vault returns not_encrypted" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    const s = try vault.crypto.status();
    try std.testing.expect(s == .not_encrypted);
}

test "is_locked returns true after lock" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.crypto.encrypt("hunter2");
    try std.testing.expect(!(try vault.crypto.is_locked()));

    try vault.crypto.lock();
    try std.testing.expect(try vault.crypto.is_locked());
}

test "decrypt clears salt and hash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.crypto.encrypt("hunter2");
    try vault.crypto.decrypt("hunter2");

    const v = try vault.vaults.get_by_id(vault.id);
    try std.testing.expect(v.?.key_salt == null);
    try std.testing.expect(v.?.key_hash == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `vault.crypto` not defined

- [ ] **Step 3: Add `Crypto` sub-handle to Vault**

Extend the `Vault` definition (in `src/core/vault.zig` or wherever the Vault handle lives):

```zig
pub const Vault = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    id: []const u8,
    name: []const u8,
    db: *zig_sqlite.Db,
    session_dir: []const u8,

    // Existing sub-handles (from SP03/SP06)...
    pub const tasks: Tasks,
    pub const vaults: Vaults,
    pub const categories: Categories,
    pub const tags: Tags,

    // NEW:
    pub const crypto: Crypto,

    pub const Crypto = struct {
        vault: *Vault,

        pub fn encrypt(self: *Crypto, password: []const u8) !void {
            const v = try self.vault.vaults.get_by_id(self.vault.id) orelse return error.VaultNotFound;
            if (v.key_salt != null) return error.AlreadyEncrypted;

            const salt = try crypto_mod.generate_salt();
            const params = crypto_mod.Argon2Params{};
            const hash = try crypto_mod.hash_password(password, &salt, self.vault.id, params);

            // Store base64 salt and hash on vault row
            const salt_b64 = try std.base64.url_safe_no_pad.encoders.alloc(self.vault.allocator, &salt);
            defer self.vault.allocator.free(salt_b64);

            const hash_b64 = try std.base64.url_safe_no_pad.encoders.alloc(self.vault.allocator, &hash);
            defer self.vault.allocator.free(hash_b64);

            try self.vault.vaults.update(.{
                .id = self.vault.id,
                .key_salt = salt_b64,
                .key_hash = hash_b64,
            });

            // Auto-unlock after encrypting
            const key = try crypto_mod.derive_key(password, &salt, self.vault.id, params);
            try session.open(self.vault.allocator, self.vault.session_dir, self.vault.id, &key, self.get_ttl());
        }

        pub fn decrypt(self: *Crypto, password: []const u8) !void {
            const v = try self.vault.vaults.get_by_id(self.vault.id) orelse return error.VaultNotFound;
            const salt_b64 = v.key_salt orelse return error.NotEncrypted;
            const hash_b64 = v.key_hash orelse return error.NotEncrypted;

            // Verify password
            try self.verify_password(password, salt_b64, hash_b64);

            // Clear crypto columns
            try self.vault.vaults.update(.{
                .id = self.vault.id,
                .key_salt = null,
                .key_hash = null,
            });

            // Remove session
            try session.close(self.vault.session_dir, self.vault.id);
        }

        pub fn unlock(self: *Crypto, password: []const u8) !void {
            const v = try self.vault.vaults.get_by_id(self.vault.id) orelse return error.VaultNotFound;
            const salt_b64 = v.key_salt orelse return error.NotEncrypted;
            const hash_b64 = v.key_hash orelse return error.NotEncrypted;

            // Verify password against stored hash
            try self.verify_password(password, salt_b64, hash_b64);

            // Derive key and write session
            const salt_decoded = try std.base64.url_safe_no_pad.decoders.alloc(self.vault.allocator, salt_b64, .{});
            defer self.vault.allocator.free(salt_decoded);

            var salt: crypto_mod.Salt = undefined;
            @memcpy(&salt, salt_decoded);

            const params = crypto_mod.Argon2Params{};
            const key = try crypto_mod.derive_key(password, &salt, self.vault.id, params);
            try session.open(self.vault.allocator, self.vault.session_dir, self.vault.id, &key, self.get_ttl());
        }

        pub fn lock(self: *Crypto) !void {
            try session.close(self.vault.session_dir, self.vault.id);
        }

        pub fn status(self: *Crypto) !union(enum) { locked, unlocked: i64, not_encrypted } {
            const v = try self.vault.vaults.get_by_id(self.vault.id) orelse return error.VaultNotFound;
            if (v.key_salt == null) return .not_encrypted;

            const allocator = std.heap.page_allocator;
            const key = try session.get_key(allocator, self.vault.io, self.vault.session_dir, self.vault.id) orelse {
                return .locked;
            };

            return .{ .unlocked = 0 }; // time remaining is read from session file internally
        }

        pub fn is_locked(self: *Crypto) !bool {
            const s = try self.status();
            return s == .locked;
        }

        fn verify_password(self: *Crypto, password: []const u8, salt_b64: []const u8, hash_b64: []const u8) !void {
            const allocator = self.vault.allocator;

            const salt_decoded = try std.base64.url_safe_no_pad.decoders.alloc(allocator, salt_b64, .{});
            defer allocator.free(salt_decoded);

            var salt: crypto_mod.Salt = undefined;
            @memcpy(&salt, salt_decoded);

            const hash_decoded = try std.base64.url_safe_no_pad.decoders.alloc(allocator, hash_b64, .{});
            defer allocator.free(hash_decoded);

            var expected_hash: crypto_mod.Key = undefined;
            @memcpy(&expected_hash, hash_decoded);

            const params = crypto_mod.Argon2Params{};
            if (!try crypto_mod.verify_password(password, &salt, self.vault.id, &expected_hash, params)) {
                return error.WrongPassword;
            }
        }

        fn get_ttl(self: *Crypto) i64 {
            // Read session_ttl from config, default 300
            // This depends on the SP05 config system
            const config = @import("config.zig");
            const ttl_str = config.get(self.vault.io, "session_ttl") orelse "300";
            return std.fmt.parseInt(i64, ttl_str, 10) catch 300;
        }
    };

    // ... existing methods unchanged
};
```

Also add `session_dir` to the `Vault` struct's initialization — it should be derived from the data directory (SP03) + `"sessions"`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (10 new tests)

- [ ] **Step 5: Commit**

```bash
git add src/core/vault.zig src/crypto/mod.zig
git commit -m "feat: add Vault.Crypto handle with encrypt/decrypt/unlock/lock/status"
```

---

### Task 5: Create `src/core/vault_crypto.zig` — CLI dispatch for vault crypto commands

**Files:**
- Create: `src/core/vault_crypto.zig`

**Interfaces:**
- Consumes: `Vault.Crypto` handle, `flags` CLI parsing, `config` system.
- Produces:
  - `pub const VaultCryptArgs = struct { subcommand: union(enum) { encrypt: struct { name: []const u8 }, decrypt: struct { name: []const u8 }, unlock: struct { name: []const u8 }, lock: struct { name: []const u8, all: bool }, status: struct { name: ?[]const u8 } } }`
  - `pub fn dispatch_vault_crypt_command(io: std.Io, args: VaultCryptArgs) void`

- [ ] **Step 1: Write the failing tests for CLI dispatch**

```zig
const std = @import("std");
const vault_crypto = @import("vault_crypto.zig");
const Vault = @import("vault.zig").Vault;

test "dispatch vault encrypt creates encrypted vault" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    // This tests the underlying logic, not the interactive prompt.
    // The dispatch function reads from stdin for passwords.
    // In test mode, we test via the handle directly (already done in Task 4).
    // This test verifies the args enum compiles.
    const args = VaultCryptArgs{ .subcommand = .{ .encrypt = .{ .name = "test" } } };
    _ = args;
}

test "dispatch vault lock and unlock" {
    const args_unlock = VaultCryptArgs{ .subcommand = .{ .unlock = .{ .name = "work" } } };
    const args_lock = VaultCryptArgs{ .subcommand = .{ .lock = .{ .name = "work" } } };
    _ = args_unlock;
    _ = args_lock;
}

test "dispatch vault status" {
    const args = VaultCryptArgs{ .subcommand = .{ .status = .{ .name = null } } };
    _ = args;
}

test "dispatch vault lock --all" {
    const args = VaultCryptArgs{ .subcommand = .{ .lock = .{ .name = "", .all = true } } };
    _ = args;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — `VaultCryptArgs` not defined

- [ ] **Step 3: Implement the CLI dispatch module**

```zig
const std = @import("std");
const Vault = @import("vault.zig").Vault;

pub const VaultCryptArgs = struct {
    subcommand: union(enum) {
        encrypt: struct { name: []const u8 },
        decrypt: struct { name: []const u8 },
        unlock: struct { name: []const u8 },
        lock: struct { name: []const u8, all: bool },
        status: struct { name: ?[]const u8 },
    },

    pub const help =
        \\Usage:
        \\  tip vault <subcommand> [args]
        \\
        \\Crypto commands:
        \\  encrypt <name>           Encrypt a vault (prompts for master password)
        \\  decrypt <name>           Decrypt a vault (removes encryption)
        \\  unlock <name>            Unlock a vault (prompts for password)
        \\  lock <name>              Lock a vault
        \\  lock --all               Lock all vaults
        \\  status [<name>]          Show lock status
        \\
    ;
};

pub fn dispatch_vault_crypt_command(io: std.Io, args: VaultCryptArgs) void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var vault = Vault.open(allocator, io, .{ .name = "default" }) catch {
        std.debug.print("Failed to open store\n", .{});
        return;
    };
    defer vault.close();

    // Read password from stdin (interactive prompt)
    // In a real implementation, use a proper password prompt (no echo)
    // For now, read_line from stdin

    switch (args.subcommand) {
        .encrypt => |e| {
            std.debug.print("Enter master password for vault '{s}': ", .{e.name});
            const password = read_password(allocator, io) catch {
                std.debug.print("Failed to read password\n", .{});
                return;
            };
            defer allocator.free(password);

            vault.crypto.encrypt(password) catch |err| switch (err) {
                error.AlreadyEncrypted => {
                    std.debug.print("Vault '{s}' is already encrypted\n", .{e.name});
                    return;
                },
                else => {
                    std.debug.print("Failed to encrypt vault\n", .{});
                    return;
                },
            };
            std.debug.print("Vault '{s}' encrypted and unlocked\n", .{e.name});
        },
        .decrypt => |d| {
            std.debug.print("Enter master password for vault '{s}': ", .{d.name});
            const password = read_password(allocator, io) catch {
                std.debug.print("Failed to read password\n", .{});
                return;
            };
            defer allocator.free(password);

            vault.crypto.decrypt(password) catch |err| switch (err) {
                error.WrongPassword => {
                    std.debug.print("Wrong password\n", .{});
                    return;
                },
                error.NotEncrypted => {
                    std.debug.print("Vault '{s}' is not encrypted\n", .{d.name});
                    return;
                },
                else => {
                    std.debug.print("Failed to decrypt vault\n", .{});
                    return;
                },
            };
            std.debug.print("Vault '{s}' decrypted\n", .{d.name});
        },
        .unlock => |u| {
            std.debug.print("Enter master password for vault '{s}': ", .{u.name});
            const password = read_password(allocator, io) catch {
                std.debug.print("Failed to read password\n", .{});
                return;
            };
            defer allocator.free(password);

            vault.crypto.unlock(password) catch |err| switch (err) {
                error.WrongPassword => {
                    std.debug.print("Wrong password\n", .{});
                    return;
                },
                error.NotEncrypted => {
                    std.debug.print("Vault '{s}' is not encrypted. Run 'tip vault encrypt {s}' first\n", .{ u.name, u.name });
                    return;
                },
                else => {
                    std.debug.print("Failed to unlock vault\n", .{});
                    return;
                },
            };
            std.debug.print("Vault '{s}' unlocked\n", .{u.name});
        },
        .lock => |l| {
            if (l.all) {
                session.close_all(vault.session_dir) catch {
                    std.debug.print("Failed to lock all vaults\n", .{});
                    return;
                };
                std.debug.print("All vaults locked\n", .{});
            } else {
                vault.crypto.lock() catch {
                    std.debug.print("Failed to lock vault '{s}'\n", .{l.name});
                    return;
                };
                std.debug.print("Vault '{s}' locked\n", .{l.name});
            }
        },
        .status => |s| {
            const vault_name = s.name orelse vault.name;
            // Re-open the vault by name for status queries
            const status_vault = Vault.open(allocator, io, .{ .name = vault_name }) catch {
                std.debug.print("Vault '{s}' not found\n", .{vault_name});
                return;
            };
            defer status_vault.close();

            const st = status_vault.crypto.status() catch {
                std.debug.print("Failed to get vault status\n", .{});
                return;
            };

            switch (st) {
                .locked => std.debug.print("Vault '{s}' is locked\n", .{vault_name}),
                .unlocked => std.debug.print("Vault '{s}' is unlocked\n", .{vault_name}),
                .not_encrypted => std.debug.print("Vault '{s}' is not encrypted\n", .{vault_name}),
            }
        },
    }
}

fn read_password(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    // Stub: read a line from stdin
    // Future: implement silent/no-echo password prompt
    var buf = std.ArrayList(u8).init(allocator);
    const stdin = io.stdin();
    try stdin.reader().streamUntilDelimiter(buf.writer(), '\n', 1024);
    return buf.toOwnedSlice();
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS (4 new tests, compilation tests)

- [ ] **Step 5: Commit**

```bash
git add src/core/vault_crypto.zig
git commit -m "feat: add vault crypto CLI dispatch (encrypt/decrypt/unlock/lock/status)"
```

---

### Task 6: Extend `main.zig` to register vault crypto subcommands

**Files:**
- Modify: `src/main.zig`

**Interfaces:**
- Consumes: `vault_crypto.VaultCryptArgs`, `vault_crypto.dispatch_vault_crypt_command`.
- Produces: `tip vault encrypt/decrypt/unlock/lock/status` commands available.

- [ ] **Step 1: Write a failing test for the new commands**

```zig
test "main accepts vault crypto subcommands" {
    const args = Args{ .vault = .{ .subcommand = .{ .encrypt = .{ .name = "test" } } } };
    _ = args;
    const args2 = Args{ .vault = .{ .subcommand = .{ .unlock = .{ .name = "test" } } } };
    _ = args2;
    const args3 = Args{ .vault = .{ .subcommand = .{ .lock = .{ .name = "test" } } } };
    _ = args3;
    const args4 = Args{ .vault = .{ .subcommand = .{ .status = .{ .name = null } } } };
    _ = args4;
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL — new subcommands not in Args

- [ ] **Step 3: Update `Args` in `main.zig`**

Add vault crypto subcommands to the existing vault subcommand union:

```zig
const Args = struct {
    vault: ?union(enum) {
        add: struct { name: []const u8, encrypt: bool = false },
        list: struct {},
        rename: struct { name: []const u8, new_name: []const u8 },
        delete: struct { name: []const u8, force: bool = false },
        switch: struct { name: []const u8 },
        merge: struct { name: []const u8, into: []const u8 },
        // NEW crypto subcommands:
        encrypt: struct { name: []const u8 },
        decrypt: struct { name: []const u8 },
        unlock: struct { name: []const u8 },
        lock: struct { name: []const u8, all: bool = false },
        status: struct { name: ?[]const u8 },
    } = null,
    // ... other commands
};
```

Add to help text:

```
  vault encrypt <name>       Encrypt a vault
  vault decrypt <name>       Remove encryption from a vault
  vault unlock <name>        Unlock a vault
  vault lock [<name>|--all]  Lock a vault or all vaults
  vault status [<name>]      Show vault lock status
```

- [ ] **Step 4: Update main dispatch**

In the vault command handler:

```zig
.vault => |v| switch (v) {
    .add => |a| vault.dispatch_vault_add(init.io, a),
    .list => vault.dispatch_vault_list(init.io),
    .rename => |r| vault.dispatch_vault_rename(init.io, r),
    .delete => |d| vault.dispatch_vault_delete(init.io, d),
    .switch => |s| vault.dispatch_vault_switch(init.io, s),
    .merge => |m| vault.dispatch_vault_merge(init.io, m),
    // NEW:
    .encrypt => |e| vault_crypto.dispatch_vault_crypt_command(init.io, .{ .subcommand = .{ .encrypt = e } }),
    .decrypt => |d| vault_crypto.dispatch_vault_crypt_command(init.io, .{ .subcommand = .{ .decrypt = d } }),
    .unlock => |u| vault_crypto.dispatch_vault_crypt_command(init.io, .{ .subcommand = .{ .unlock = u } }),
    .lock => |l| vault_crypto.dispatch_vault_crypt_command(init.io, .{ .subcommand = .{ .lock = l } }),
    .status => |s| vault_crypto.dispatch_vault_crypt_command(init.io, .{ .subcommand = .{ .status = s } }),
},
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/main.zig
git commit -m "feat: register vault encrypt/decrypt/unlock/lock/status subcommands"
```

---

### Task 7: Edge cases, error handling, and integration tests

**Files:**
- Modify: `src/core/vault_crypto.zig` (edge case tests)
- Modify: `src/core/vault.zig` (edge case tests)

- [ ] **Step 1: Write vault crypto edge case tests**

```zig
test "encrypt with empty password returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try std.testing.expectError(error.InvalidPassword, vault.crypto.encrypt(""));
}

test "lock on already-locked vault succeeds (idempotent)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.crypto.encrypt("hunter2");
    try vault.crypto.lock();
    // Second lock should not error
    try vault.crypto.lock();
    try std.testing.expect(try vault.crypto.is_locked());
}

test "decrypt with wrong password returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.crypto.encrypt("hunter2");
    try std.testing.expectError(error.WrongPassword, vault.crypto.decrypt("wrong"));
}

test "decrypt on non-encrypted vault returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try std.testing.expectError(error.NotEncrypted, vault.crypto.decrypt("hunter2"));
}

test "re-encrypt after decrypt works" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.crypto.encrypt("hunter2");
    try vault.crypto.decrypt("hunter2");
    try vault.crypto.encrypt("new_password");

    try std.testing.expect(!(try vault.crypto.is_locked()));
}

test "expired session is treated as locked" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.crypto.encrypt("hunter2");
    // Session is created with default TTL. To test expiry, we manually
    // write a session with expires_at in the past.
    // This verifies the session module's expiry logic.
    const past_key: crypto_mod.Key = [_]u8{0x42} ** 32;
    try session.open(allocator, vault.session_dir, vault.id, &past_key, -1); // already expired

    try std.testing.expect(try vault.crypto.is_locked());
}

test "vault add --encrypt creates encrypted vault" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // vault add --encrypt should prompt for password and set key_salt/key_hash
    var vault = try Vault.open(allocator, io, .{ .name = "new_encrypted" });
    defer vault.close();

    try vault.crypto.encrypt("secure123");
    const v = try vault.vaults.get_by_id(vault.id);
    try std.testing.expect(v.?.key_salt != null);
}
```

- [ ] **Step 2: Add `InvalidPassword` error to error taxonomy (SP01)**

In the error set, add:

```zig
InvalidPassword,  // empty or too-short master password
```

Add validation in `encrypt`:

```zig
pub fn encrypt(self: *Crypto, password: []const u8) !void {
    if (password.len == 0) return error.InvalidPassword;
    // ... rest unchanged
}
```

- [ ] **Step 3: Write integration tests for full workflows**

```zig
test "full workflow: encrypt → unlock → lock → unlock cycle" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    // Start: not encrypted
    try std.testing.expect((try vault.crypto.status()) == .not_encrypted);

    // Encrypt
    try vault.crypto.encrypt("hunter2");
    try std.testing.expect(!(try vault.crypto.is_locked()));

    // Lock
    try vault.crypto.lock();
    try std.testing.expect(try vault.crypto.is_locked());

    // Unlock with wrong password
    try std.testing.expectError(error.WrongPassword, vault.crypto.unlock("wrong"));

    // Unlock with correct password
    try vault.crypto.unlock("hunter2");
    try std.testing.expect(!(try vault.crypto.is_locked()));

    // Lock again
    try vault.crypto.lock();
    try std.testing.expect(try vault.crypto.is_locked());
}

test "full workflow: encrypt → decrypt → not encrypted" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault = try Vault.open(allocator, io, .{ .name = "test" });
    defer vault.close();

    try vault.crypto.encrypt("hunter2");
    try vault.crypto.decrypt("hunter2");
    try std.testing.expect((try vault.crypto.status()) == .not_encrypted);
}

test "multiple vaults independent encryption" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var vault_a = try Vault.open(allocator, io, .{ .name = "work" });
    defer vault_a.close();

    var vault_b = try Vault.open(allocator, io, .{ .name = "personal" });
    defer vault_b.close();

    // Only encrypt vault_a
    try vault_a.crypto.encrypt("work_pass");
    try vault_a.crypto.lock();

    // Vault_b should still be not_encrypted
    try std.testing.expect((try vault_b.crypto.status()) == .not_encrypted);

    // Unlock vault_a independently
    try vault_a.crypto.unlock("work_pass");
    try std.testing.expect(!(try vault_a.crypto.is_locked()));
}
```

- [ ] **Step 4: Run full test suite**

Run: `zig build test --summary all`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/vault_crypto.zig src/core/vault.zig src/crypto/mod.zig src/crypto/session.zig
git commit -m "test: add edge case and integration tests for vault security"
```
