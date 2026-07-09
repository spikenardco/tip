# Sub-project 11 — Password CRUD + Generation (DESIGN)

> **Status:** DESIGN APPROVED
> **Date:** 2026-07-05
> **Parent doc:** [2026-06-30-tip-redesign-draft.md](2026-06-30-tip-redesign-draft.md)
> **Predecessor:** Sub-project 10 (Vault Security)
> **Successor:** 12 (Password strength + audit)

This sub-project adds password entry CRUD (`add` / `list` / `show` / `edit` / `delete`),
password generation (`generate`), and integrates with SP10's vault encryption so that
password values are encrypted with AES-256-GCM at rest using the vault's derived key.

---

## Locked decisions

| # | Decision | Status |
|---|----------|--------|
| 11-1 | **Password fields:** title, username, password, url, notes. No custom fields, no TOTP, no folder/icon for v1. | LOCKED |
| 11-2 | **Only the `password` field is encrypted.** Title, username, url, notes are plaintext. Title + username are searchable without decryption. | LOCKED |
| 11-3 | **No password history.** Each entry has one current password. History can be added later without migration (new table). | LOCKED |
| 11-4 | **Encrypted from day one.** `password` column stores `base64(12-byte-nonce || AES-256-GCM-ciphertext)`. Vault must be unlocked for all password operations. | LOCKED |
| 11-5 | **Password generation included.** `password generate` standalone command + `--generate` flag on `add` / `edit`. | LOCKED |
| 11-6 | **One table, one DB.** `passwords` table with `vault_id` FK in the shared `tip.db`. Same storage architecture as tasks (SP06). | LOCKED |
| 11-7 | **Vault scoping.** Password operations are scoped to the active vault (like tasks). `password list` only shows entries in the current vault. `--vault` override works. | LOCKED |
| 11-8 | **Password hidden by default.** `password show` masks the actual value (`****`). `--show-password` flag reveals it. | LOCKED |
| 11-9 | **VaultLocked error on all password commands.** If the vault is not unlocked, every password command returns a clear `VaultLocked` error with instructions. | LOCKED |

---

## Part A — Schema

### Migration `004_create_passwords.sql`

```sql
CREATE TABLE IF NOT EXISTS passwords (
    id         TEXT PRIMARY KEY NOT NULL,   -- ULID
    vault_id   TEXT NOT NULL REFERENCES vaults(id),
    title      TEXT NOT NULL,
    username   TEXT,
    password   TEXT NOT NULL,               -- base64(nonce[12] || ciphertext[varies])
    url        TEXT,
    notes      TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_passwords_vault ON passwords(vault_id);
CREATE INDEX IF NOT EXISTS idx_passwords_title ON passwords(title);
```

NULL semantics: `username`, `url`, `notes` are nullable. `title` and `password` are NOT NULL.

### Password entry format

```
password column = base64_urlsafe_no_pad(nonce[12] || ciphertext)
```

Where `ciphertext` = AES-256-GCM output (plaintext_len + 16 bytes tag). The nonce is 12 random
bytes generated per encryption operation. Decryption extracts nonce from bytes 0..12 and
ciphertext from bytes 12..end, then calls `crypto.decrypt`.

---

## Part B — CLI surface

### New commands

```
tip password add <title>
       [--username=<u>] [--url=<u>] [--notes=<n>]
       [--generate] [--length=N]
       [--no-symbols] [--no-numbers] [--no-ambiguous]

tip password list [--vault=<name>]

tip password show <id>
       [--show-password]

tip password edit <id>
       [--title=<t>] [--username=<u>] [--password=<p>]
       [--url=<u>] [--notes=<n>]
       [--generate] [--length=N]

tip password delete <id> [--force]

tip password generate
       [--length=20] [--count=1]
       [--no-symbols] [--no-numbers] [--no-ambiguous]
       [--quiet]                         # just print the password, no label
```

### Flag rules

| Flag | Type | Default | Applies to |
|---|---|---|---|
| `--username` | string | — | add, edit |
| `--url` | string | — | add, edit |
| `--notes` | string | — | add, edit |
| `--generate` | bool | false | add, edit |
| `--length` | integer | 20 | add, edit, generate |
| `--no-symbols` | bool | false | add (with --generate), generate |
| `--no-numbers` | bool | false | add (with --generate), generate |
| `--no-ambiguous` | bool | false | add (with --generate), generate |
| `--show-password` | bool | false | show |
| `--force` | bool | false | delete |
| `--count` | integer | 1 | generate |
| `--quiet` | bool | false | generate |

### Example usage

```bash
# Add a password entry
tip password add github --username=ben --url=https://github.com --generate --length=24

# List passwords in active vault (shows title, username, updated_at)
tip password list

# Show a specific entry (password masked)
tip password show abc1234

# Show with password revealed
tip password show abc1234 --show-password

# Edit fields
tip password edit abc1234 --username=ben2 --generate

# Delete
tip password delete abc1234

# Standalone generation
tip password generate --length=32 --no-ambiguous
tip password generate --count=5 --length=16 --no-symbols
```

### Output styles

`password list`:
```
ID        Title     Username  Updated
abc1234   github    ben       2 min ago
def5678   aws       admin     1 hour ago
```

`password show` (without `--show-password`):
```
Title:     github
Username:  ben
Password:  ****
URL:       https://github.com
Notes:     personal account
Updated:   2 min ago

Run with --show-password to reveal.
```

`password show` (with `--show-password`):
```
Title:     github
Username:  ben
Password:  Zr4u7x!Kp9mQ2wVn8LbJ
URL:       https://github.com
Notes:     personal account
Updated:   2 min ago
```

---

## Part C — Encryption integration with SP10

### Flow for `add` / `edit` (when password changes)

```
1. vault.crypto.is_locked() → if true, return error.VaultLocked
   ("Vault 'work' is locked. Run: tip vault unlock work")

2. key = session.get_key(allocator, io, session_dir, vault.id)
   → returns ?[32]u8 (null = locked, should not happen after is_locked check)

3. nonce = std.crypto.random.bytes(12)
   ciphertext = aes_gcm.encrypt(password_plaintext, null, nonce, key)
   stored = base64_urlsafe_no_pad(nonce ++ ciphertext)

4. INSERT/UPDATE passwords SET password = stored, ...
```

### Flow for `show`

```
1. vault.crypto.is_locked() → error if locked

2. key = session.get_key(...)

3. raw = base64_urlsafe_no_pad.decode(stored_password)
   nonce = raw[0..12]
   ciphertext = raw[12..]
   password_plaintext = aes_gcm.decrypt(ciphertext, null, nonce, key)
```

### Flow for `list`

No decryption needed — title, username are plaintext columns in the database.

### Vault scoping

All password queries include `AND vault_id = active_vault_id` (same pattern as tasks from SP06).
The active vault is resolved at `Store.open` time from `--vault` flag > `config.default_vault` > `"personal"`.

---

## Part D — Password generation

### `src/core/password_gen.zig`

```zig
pub const GenOptions = struct {
    length: usize = 20,
    use_lower: bool = true,
    use_upper: bool = true,
    use_digits: bool = true,
    use_symbols: bool = true,
    no_ambiguous: bool = false,
};

pub fn generate(allocator: Allocator, opts: GenOptions) ![]const u8
pub fn generate_multiple(allocator: Allocator, count: usize, opts: GenOptions) ![][]const u8
pub fn estimate_entropy(length: usize, charset_size: usize) f64
```

### Character sets

| Set | Characters | Size |
|---|---|---|
| Lowercase | `abcdefghijklmnopqrstuvwxyz` | 26 |
| Uppercase | `ABCDEFGHIJKLMNOPQRSTUVWXYZ` | 26 |
| Digits | `0123456789` | 10 |
| Symbols | `!@#$%^&*()_+-=[]{}|;:,.<>?/~` | 24 |

When `no_ambiguous` is true, exclude `i`, `l`, `1`, `I`, `O`, `0` from their respective sets.

Algorithm:
1. Build charset from enabled sets
2. Fill each byte with `charset[std.crypto.random.int_range(0, charset.len)]`
3. Shuffle result to avoid predictable prefix patterns

### Flag combinations

`--no-symbols` disables the symbols set. `--no-numbers` disables digits. `--no-ambiguous` filters
ambiguous characters from all enabled sets. At least one character set must remain enabled
(error if all disabled).

---

## Part E — Architecture

### New files

| File | Responsibility |
|---|---|
| `src/core/password.zig` | `Password` handle, CRUD methods, CLI dispatch, tests |
| `src/core/password_gen.zig` | Password generation logic, tests |
| `src/storage/migrations/011_create_passwords.sql` | Passwords table migration |

### Modified files

| File | Change |
|---|---|
| `src/core/models.zig` | Add `Password` struct (`id`, `vault_id`, `title`, `username`, `password`, `url`, `notes`, `created_at`, `updated_at`) |
| `src/core/store.zig` | Add `store.passwords` sub-handle (parallel to `store.tasks` and `store.vaults`) |
| `src/crypto/mod.zig` | Add `encrypt_field` / `decrypt_field` convenience helpers that handle nonce-prepend + base64 format |
| `src/main.zig` | Add `password` subcommand to `Args` union, wire dispatch |
| Migration runner | Register `011_create_passwords` migration |

### Store.Passwords handle

```zig
pub const Passwords = struct {
    store: *Store,

    pub fn add(self: *Passwords, fields: AddFields) !models.Password
    pub fn list(self: *Passwords, allocator: Allocator) ![]models.Password
    pub fn get_by_id(self: *Passwords, allocator: Allocator, id: []const u8) !models.Password
    pub fn edit(self: *Passwords, id: []const u8, fields: EditFields) !void
    pub fn delete(self: *Passwords, id: []const u8) !void
};
```

All methods check vault unlocked status before operating. `add` and `edit` encrypt the password
field. `get_by_id` does **not** auto-decrypt — the caller (CLI layer) decrypts explicitly to
control when the plaintext is in memory.

---

## Part F — Error taxonomy (extends SP01)

| Error | Raised when |
|---|---|
| `PasswordNotFound` | `show` / `edit` / `delete` target id doesn't exist |
| `VaultLocked` | Any password command on a locked vault |
| `EmptyPassword` | `add` or `edit` with an empty password (explicit `--password=""`) |
| `AllCharsetsDisabled` | `generate` with all `--no-*` flags set |

---

## Part G — Testing

| Test | Verifies |
|---|---|
| Add password creates entry | INSERT succeeds, entry appears in list |
| Add with --generate | Password generated, stored encrypted |
| List shows entries in active vault | Scoped by vault_id |
| List does not show other vault entries | Vault isolation |
| Show returns decrypted password | Encryption round-trip |
| Show without --show-password masks | Display behavior |
| Show on locked vault | `VaultLocked` |
| Edit updates title | Field modification |
| Edit with new password re-encrypts | Old encrypted value replaced |
| Edit on locked vault | `VaultLocked` |
| Delete removes entry | Row gone, list no longer includes it |
| Delete on nonexistent id | `PasswordNotFound` |
| Generate produces correct length | Generation |
| Generate --no-symbols | Symbol exclusion |
| Generate --no-numbers | Digit exclusion |
| Generate --no-ambiguous | Ambiguous char exclusion |
| Generate all charsets disabled | `AllCharsetsDisabled` |
| Prefix match for id | Partial id resolves (reuses SP04 helper) |
| Add with explicit --password | Provided password stored encrypted |
| Multiple vaults, passwords scoped | Vault A entries invisible in vault B |
| Migration creates table | Schema version incremented, table exists |
| Empty title rejected | Validation at CLI layer |

---

## Out of scope

- **Password history** — deferred (new table, no migration needed).
- **Custom fields** — deferred.
- **TOTP / OTP** — deferred.
- **Password strength evaluation** — SP12.
- **Clipboard integration** — SP13 (or later).
- **Breach check (HIBP)** — deferred.
- **Favicon / icon / color** on entries — deferred.
- **Import from other managers** — deferred.
- **Bulk operations** (batch delete, export) — deferred.

---

## Next step

Write the checkbox implementation plan for this sub-project via the writing-plans skill.
No implementation yet.
