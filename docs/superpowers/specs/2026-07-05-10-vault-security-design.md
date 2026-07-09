# Sub-project 10 — Vault Security (DESIGN)

> **Status:** DESIGN APPROVED
> **Date:** 2026-07-05
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 09 (Tags & categories)
> **Successor:** 11 (Password CRUD + history)

This sub-project adds per-vault master passwords, AES-256-GCM encryption keyed by
Argon2id-derived keys, and a sudo-style session cache with configurable TTL. Encrypted
vaults are opt-in (`tip vault encrypt <name>`). Tasks remain plaintext — this is
infrastructure for password entries (SP12+).

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| 10-1 | **One master password per vault.** Each vault has its own Argon2id-derived key. | LOCKED |
| 10-2 | **Only password entries are encrypted.** Tasks stay plaintext. | LOCKED |
| 10-3 | **Crypto is opt-in via `vault encrypt`.** Existing vaults are not migrated. `vault add` gets a `--encrypt` flag. | LOCKED |
| 10-4 | **Session key cached on disk** (`~/.tip/sessions/<vault_id>.key`, 0600). No OS keyring. | LOCKED |
| 10-5 | **Default session TTL: 5 minutes.** Configurable via `config set session_ttl <duration>`. | LOCKED |
| 10-6 | **Auto-lock on expiry only.** No screen-lock detection, no idle detection. | LOCKED |
| 10-7 | **AES-256-GCM** from `std.crypto.aead.aes_gcm.Aes256Gcm`. **Argon2id** from `std.crypto.pwhash.argon2`. | LOCKED |
| 10-8 | **Argon2id default params:** OWASP minimum (19 MiB, 2 iterations, 1 thread). Configurable. | LOCKED |
| 10-9 | **Locked vault returns a clear error** on any password command: `VaultLocked`. Task commands are unaffected. | LOCKED |
| 10-10 | **Vault table gains nullable columns** `key_salt TEXT` and `key_hash TEXT`. NULL = unencrypted. | LOCKED |

---

## Part A — CLI Surface

### New `tip vault` subcommands

```
tip vault encrypt <name>              Prompt for password, derive key, store salt+hash
tip vault decrypt <name>              Prompt for password, clear salt+hash, delete session
tip vault unlock <name>               Prompt for password, verify hash, write session file
tip vault lock <name>                 Delete session file (error if already locked)
tip vault lock --all                  Delete all session files
tip vault status [<name>]             Show locked/unlocked + time remaining
```

### Modified `tip vault add`

```
tip vault add <name> [--encrypt]      --encrypt prompts for master password immediately
```

### Error message for locked vault

```
Vault "work" is locked. Run: tip vault unlock work
```

Existing vault commands (list, rename, merge, switch) work on locked or unlocked vaults.

---

## Part B — Internal architecture

### Vault table migration

```sql
ALTER TABLE vaults ADD COLUMN key_salt TEXT;   -- base64, 16 bytes
ALTER TABLE vaults ADD COLUMN key_hash TEXT;   -- base64, 32 bytes
```

NULL in both columns = vault is not encrypted. Non-NULL = encrypted.

### New modules

| Module | Responsibility |
|---|---|
| `src/crypto/mod.zig` | Re-exports, top-level crypto constants/params |
| `src/crypto/session.zig` | Session file read/write/expiry check |
| `src/core/vault_crypto.zig` | `vault encrypt/decrypt/unlock/lock` CLI dispatch + handle integration |

`src/crypto/mod.zig` wraps `std.crypto` — the actual AES-256-GCM and Argon2id primitives are
used directly from Zig's standard library, not reimplemented.

### Key derivation

```
derived_key = Argon2id(
    password = master_password,
    salt     = random_16_bytes,
    context  = vault_id,       -- bound to vault identity
    mem      = 19 MiB,
    iters    = 2,
    threads  = 1,
    output   = 32 bytes,
)
```

The key is used for:
- **Encryption/decryption** of password entry fields (future SP12+).
- **Password verification** — a `key_hash` is stored (Argon2id of the password itself, not
  the derived key), used to verify the password on `vault unlock` without decrypting anything.

### Session file

Location: `~/.tip/sessions/<vault_id>.key`

Format: JSON with 0600 permissions.

```json
{
    "vault_id": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
    "vault_key": "<base64 32-byte derived key>",
    "expires_at": 1749120000
}
```

The session module exposes:

```zig
pub const Session = struct {
    vault_id: []const u8,
    vault_key: [32]u8,
    expires_at: i64,
};

pub fn open(allocator: Allocator, io: std.Io, session_dir: []const u8, vault_id: []const u8, vault_key: *const [32]u8, ttl_seconds: i64) !void;
pub fn close(allocator: Allocator, session_dir: []const u8, vault_id: []const u8) !void;
pub fn close_all(allocator: Allocator, session_dir: []const u8) !void;
pub fn get_key(allocator: Allocator, io: std.Io, session_dir: []const u8, vault_id: []const u8) !?[32]u8;
```

`get_key` checks `expires_at` — if expired, deletes the file and returns null.

### Vault.Crypto handle methods

Extended onto the SP06 `Vault` handle (or `Store`):

```zig
pub fn encrypt(self: *Vault, password: []const u8) !void;
    // Generates random salt, derives key, stores salt+hash on vault row.
    // Creates session file.

pub fn decrypt(self: *Vault, password: []const u8) !void;
    // Verifies password, sets salt+hash to NULL, deletes session file.

pub fn unlock(self: *Vault, password: []const u8) !void;
    // Verifies password hash, writes session file.

pub fn lock(self: *Vault) !void;
    // Deletes session file. No-op if already locked.

pub fn status(self: *Vault) !union(enum) { locked, unlocked: i64 };
    // Checks session file. Returns locked or unlocked + seconds remaining.
```

### Vault handle — `is_locked` check

Password commands (SP12+) call a helper before operating:

```zig
if (vault.is_locked()) return error.VaultLocked;
```

This check only applies to password entries. Task commands do not check it.

---

## Part C — Locked decisions (rationale)

| Decision | Rationale |
|---|---|
| Per-vault passwords (10-1) | Vaults are independent — different passwords reinforce isolation. Sharing one vault doesn't expose others. |
| Tasks stay plaintext (10-2) | Task titles, descriptions, etc. aren't secrets. Encrypting them would block FTS search with no real security benefit. |
| Opt-in (10-3) | Avoids migrating existing vaults. The codebase has no `if (is_encrypted)` branches during development — crypto is a clean layer. |
| Session on disk (10-4) | OS keyrings add fragile per-platform deps. A 0600 file in `~/.tip/sessions/` is simple, predictable, and survives process boundaries. |
| Default 5 min TTL (10-5) | Matches sudo's default timestamp_timeout. Long enough for a burst of commands, short enough that walking away from the terminal is safe. |
| Timer-only auto-lock (10-6) | Screen-lock / idle detection adds OS-specific hooks with no clear CLI benefit. Pragmatic. |
| std.crypto (10-7) | Zig std ships audited AES-256-GCM + Argon2id. No C dependency, no binding risk. |
| OWASP minimum (10-8) | Safe defaults for interactive use. Users can raise mem/iters for higher security if desired. |
| Clear locked error (10-9) | Users shouldn't guess why a command failed. The error message tells them exactly what to do. |
| Nullable columns (10-10) | NULL = unencrypted avoids a separate `is_encrypted` flag and keeps the schema backwards-compatible. |

---

## Part D — Out of scope

- **Encryption of task fields** — tasks stay plaintext.
- **OS keyring integration** — session on disk only.
- **Password entry encryption** — SP12 handles that using the keys this SP10 sets up.
- **Key rotation** — changing a vault's master password. Deferred (needs re-encrypt of all entries).
- **Recovery codes / password reset** — deferred.
- **Multi-factor unlock** — deferred.
- **`vault encrypt --all`** (batch) — deferred, can be added later.

---

## Part E — Testing

| Test | Verifies |
|---|---|
| Key derivation produces deterministic output | Same password + salt + vault_id → same key |
| Encrypt/decrypt round-trip | AES-256-GCM encrypt then decrypt returns original plaintext |
| Session file write/read | `session.open` → `session.get_key` returns the key |
| Session expiry | Expired session returns null, file is cleaned up |
| Vault encrypt command | `vault encrypt` stores salt+hash, creates session |
| Vault decrypt command | `vault decrypt` clears salt+hash, deletes session |
| Vault unlock/lock cycle | `unlock` → `status` shows unlocked → `lock` → `status` shows locked |
| Vault unlock wrong password | Wrong password returns error, no session written |
| Vault lock on already-locked | Returns error (not silently a no-op) |
| Double-encrypt rejected | Already-encrypted vault returns error |
| Vault add --encrypt | New vault created with salt+hash, prompted for password |
| Vault status on unencrypted vault | Returns "not encrypted" (not locked) |
| Locked error on password command | Simulated password command on locked vault → `VaultLocked` |
| Session TTL config | `config set session_ttl 60` → session expires after 60s |
