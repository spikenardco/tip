# Tip - Zig Implementation Guide

> **Warning:** This is an aspirational guide describing a planned architecture. The actual implementation is in `src/`. Many code blocks below use pre-0.16 Zig APIs and are not directly compilable. They show intent, not production code.

The task manager currently exists (see `src/core/task.zig`). The rest (vaults, passwords, crypto, HTTP server, remote sync) is planned.

**Project Scope (planned):**
- 5 implementation phases
- ~3,000-5,000 lines of Zig
- 20+ source modules
- CLI with 30+ commands
- HTTP server with REST API
- End-to-end encryption (AES-256-GCM + Argon2id)
- Multiple storage backends (JSON, SQLite, Remote)

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Project Structure](#project-structure)
3. [Phase 1: Core Foundation](#phase-1-core-foundation)
4. [Phase 2: Storage Layer](#phase-2-storage-layer)
5. [Phase 3: CLI Application](#phase-3-cli-application)
6. [Phase 4: HTTP Server](#phase-4-http-server)
7. [Phase 5: Advanced Features](#phase-5-advanced-features)
8. [Dependencies & Build Configuration](#dependencies--build-configuration)
9. [Testing Strategy](#testing-strategy)
10. [Migration from Go](#migration-from-go)

---

## Architecture Overview

### Multi-Tier Architecture in Zig

```
┌─────────────────────────────────────────────────────────────────────┐
│                         CLIENT LAYER                                │
├─────────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │ CLI Tool     │  │ Web Platform │  │ Browser Ext  │              │
│  │ (tip)        │  │ (tip-web)    │  │ (future)     │              │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘              │
│         └─────────────────┼─────────────────┘                       │
│                           │                                         │
│                    ┌──────▼──────┐                                  │
│                    │ HTTP/HTTPS  │                                  │
│                    └──────┬──────┘                                  │
└───────────────────────────┼─────────────────────────────────────────┘
                            │
┌───────────────────────────┼─────────────────────────────────────────┐
│                      SERVER LAYER                                   │
├───────────────────────────┼─────────────────────────────────────────┤
│                    ┌──────▼──────┐                                  │
│                    │ HTTP Server │                                  │
│                    │ (tip-server)│                                  │
│                    └──────┬──────┘                                  │
│                           │                                         │
│              ┌────────────┼────────────┐                           │
│              │            │            │                           │
│         ┌────▼───┐   ┌────▼───┐   ┌────▼───┐                      │
│         │  Auth  │   │  API   │   │  Sync  │                      │
│         │ (JWT)  │   │Handlers│   │Engine  │                      │
│         └────┬───┘   └────┬───┘   └────┬───┘                      │
│              │            │            │                           │
│         ┌────▼────────────▼────────────▼───┐                      │
│         │         Database Layer           │                      │
│         │         (SQLite)                 │                      │
│         └──────────────────────────────────┘                      │
└─────────────────────────────────────────────────────────────────────┘
                            │
┌───────────────────────────┼─────────────────────────────────────────┐
│                     STORAGE LAYER                                   │
├───────────────────────────┼─────────────────────────────────────────┤
│                    ┌──────▼──────┐                                  │
│                    │ Storage     │                                  │
│                    │ Interface   │                                  │
│                    └──────┬──────┘                                  │
│                           │                                         │
│         ┌─────────────────┼─────────────────┐                      │
│         │                 │                 │                      │
│    ┌────▼────┐      ┌────▼────┐      ┌────▼────┐                 │
│    │  JSON   │      │  SQLite │      │  Remote │                 │
│    │ (Local) │      │ (Local/ │      │ (Server)│                 │
│    │         │      │ Server) │      │         │                 │
│    └─────────┘      └─────────┘      └─────────┘                 │
└─────────────────────────────────────────────────────────────────────┘
```

### Operation Modes

#### Local Mode (Offline-First)
```
CLI → Storage Interface → Encryption Layer → JSON/SQLite
```

#### Remote Mode (Collaborative)
```
CLI → Storage Interface → HTTP Client → Server API → Database
```

#### Hybrid Mode
```
CLI → Local Cache ↔ Remote Sync → Conflict Resolution
```

---

## Project Structure

```
tip/
├── build.zig                    # Build configuration
├── build.zig.zon               # Package dependencies
├── README.md                   # Project documentation
├── LICENSE
│
├── src/                        # Source code
│   ├── main.zig               # CLI entry point
│   │
│   ├── core/                  # Core business logic
│   │   ├── types.zig         # Domain models & enums
│   │   ├── vault.zig         # Vault entity
│   │   ├── password.zig      # Password entity
│   │   ├── task.zig          # Task entity
│   │   ├── user.zig          # User entity
│   │   └── errors.zig        # Error types
│   │
│   ├── crypto/                # Cryptography module
│   │   ├── master.zig        # Master password & key derivation
│   │   ├── aes_gcm.zig       # AES-256-GCM encryption
│   │   ├── generator.zig     # Password generation
│   │   └── random.zig        # Secure random utilities
│   │
│   ├── storage/               # Storage abstraction
│   │   ├── interface.zig     # Storage trait definition
│   │   ├── json.zig          # JSON file storage
│   │   ├── sqlite.zig        # SQLite database storage
│   │   └── remote.zig        # HTTP remote storage
│   │
│   ├── cli/                   # Command-line interface
│   │   ├── app.zig           # CLI application setup
│   │   ├── parser.zig        # Command argument parsing
│   │   ├── vault.zig         # Vault subcommands
│   │   ├── password.zig      # Password subcommands
│   │   ├── task.zig          # Task subcommands
│   │   ├── config.zig        # Config subcommands
│   │   ├── auth.zig          # Auth subcommands
│   │   └── sync.zig          # Sync subcommands
│   │
│   ├── config/                # Configuration management
│   │   ├── loader.zig        # Config loading from files/env
│   │   ├── validator.zig     # Config validation
│   │   └── types.zig         # Config data structures
│   │
│   ├── server/                # HTTP server (separate binary)
│   │   ├── main.zig          # Server entry point
│   │   ├── router.zig        # HTTP route definitions
│   │   ├── middleware.zig    # Auth, logging middleware
│   │   ├── handlers/
│   │   │   ├── auth.zig      # Authentication handlers
│   │   │   ├── vault.zig     # Vault API handlers
│   │   │   ├── password.zig  # Password API handlers
│   │   │   ├── task.zig      # Task API handlers
│   │   │   └── sync.zig      # Sync API handlers
│   │   └── database.zig      # Database connection
│   │
│   └── utils/                 # Utility functions
│       ├── strings.zig       # String utilities
│       ├── time.zig          # Time formatting
│       ├── terminal.zig      # Terminal I/O
│       ├── files.zig         # File operations
│       └── logger.zig        # Logging
│
├── tests/                     # Integration tests
│   ├── integration.zig
│   └── fixtures/
│
└── docs/                      # Documentation
    ├── ZIG_ARCHITECTURE.md   # This file
    ├── API_REFERENCE.md      # REST API docs
    └── CLI_REFERENCE.md      # CLI command docs
```

---

## Phase 1: Core Foundation

### 1.1 Domain Models

#### File: `src/core/types.zig`

**Core Enums:**

```zig
pub const TaskStatus = enum {
    pending,
    in_progress,
    completed,
    cancelled,
    
    pub fn toString(self: TaskStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
            .cancelled => "cancelled",
        };
    }
    
    pub fn fromString(s: []const u8) !TaskStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "cancelled")) return .cancelled;
        return error.InvalidTaskStatus;
    }
};

pub const Priority = enum {
    low,
    medium,
    high,
    critical,
    
    pub fn toString(self: Priority) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
            .critical => "critical",
        };
    }
};

pub const StorageBackend = enum {
    json,
    sqlite,
    remote,
};

pub const OperationMode = enum {
    local,
    remote,
    hybrid,
};
```

**Vault Entity:**

```zig
pub const Vault = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    description: ?[]const u8,
    owner_id: []const u8,
    created_at: i64,
    updated_at: i64,
    encryption_key: ?[32]u8, // 256-bit key (only in memory when unlocked)
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, owner_id: []const u8) !Vault {
        const id = try generateUuid(allocator);
        const now = std.Io.Timestamp.now(io, .real).toSeconds();
        
        return .{
            .allocator = allocator,
            .id = id,
            .name = try allocator.dupe(u8, name),
            .description = null,
            .owner_id = try allocator.dupe(u8, owner_id),
            .created_at = now,
            .updated_at = now,
            .encryption_key = null,
        };
    }
    
    pub fn deinit(self: *Vault) void {
        // Securely wipe encryption key from memory
        if (self.encryption_key) |*key| {
            @memset(key, 0);
        }
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        if (self.description) |desc| self.allocator.free(desc);
        self.allocator.free(self.owner_id);
    }
    
    pub fn isLocked(self: Vault) bool {
        return self.encryption_key == null;
    }
    
    pub fn unlock(self: *Vault, master_password: []const u8, salt: [16]u8) !void {
        // Derive key from master password using Argon2id
        var key: [32]u8 = undefined;
        try crypto.deriveKey(master_password, salt, &key);
        self.encryption_key = key;
    }
    
    pub fn lock(self: *Vault) void {
        if (self.encryption_key) |*key| {
            @memset(key, 0);
            self.encryption_key = null;
        }
    }
};
```

**Password Entity:**

```zig
pub const Password = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    vault_id: []const u8,
    title: []const u8,
    username: ?[]const u8,
    encrypted_password: []const u8, // AES-256-GCM encrypted
    url: ?[]const u8,
    notes: ?[]const u8,
    category: ?[]const u8,
    tags: [][]const u8,
    custom_fields: std.StringHashMap([]const u8),
    created_at: i64,
    updated_at: i64,
    last_used_at: ?i64,
    version: u32,
    
    pub fn init(allocator: std.mem.Allocator, vault_id: []const u8, title: []const u8) !Password {
        const id = try generateUuid(allocator);
        const now = std.Io.Timestamp.now(io, .real).toSeconds();
        
        return .{
            .allocator = allocator,
            .id = id,
            .vault_id = try allocator.dupe(u8, vault_id),
            .title = try allocator.dupe(u8, title),
            .username = null,
            .encrypted_password = &.{},
            .url = null,
            .notes = null,
            .category = null,
            .tags = &.{},
            .custom_fields = std.StringHashMap([]const u8).init(allocator),
            .created_at = now,
            .updated_at = now,
            .last_used_at = null,
            .version = 1,
        };
    }
    
    pub fn deinit(self: *Password) void {
        self.allocator.free(self.id);
        self.allocator.free(self.vault_id);
        self.allocator.free(self.title);
        if (self.username) |u| self.allocator.free(u);
        self.allocator.free(self.encrypted_password);
        if (self.url) |u| self.allocator.free(u);
        if (self.notes) |n| self.allocator.free(n);
        if (self.category) |c| self.allocator.free(c);
        for (self.tags) |tag| self.allocator.free(tag);
        self.allocator.free(self.tags);
        
        var it = self.custom_fields.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.custom_fields.deinit();
    }
    
    // Encrypt plaintext password and store
    pub fn setPassword(self: *Password, plaintext: []const u8, key: [32]u8) !void {
        const encrypted = try crypto.encrypt(self.allocator, plaintext, key);
        self.allocator.free(self.encrypted_password);
        self.encrypted_password = encrypted;
        self.updated_at = std.Io.Timestamp.now(io, .real).toSeconds();
        self.version += 1;
    }
    
    // Decrypt and return password (caller must free)
    pub fn getPassword(self: Password, key: [32]u8, allocator: std.mem.Allocator) ![]const u8 {
        return try crypto.decrypt(allocator, self.encrypted_password, key);
    }
};
```

**Task Entity:**

```zig
pub const Task = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    vault_id: []const u8,
    title: []const u8,
    description: ?[]const u8,
    status: TaskStatus,
    priority: Priority,
    due_date: ?i64,
    assigned_to: ?[]const u8,
    tags: [][]const u8,
    created_at: i64,
    updated_at: i64,
    completed_at: ?i64,
    
    pub fn init(allocator: std.mem.Allocator, vault_id: []const u8, title: []const u8) !Task {
        const id = try generateUuid(allocator);
        const now = std.Io.Timestamp.now(io, .real).toSeconds();
        
        return .{
            .allocator = allocator,
            .id = id,
            .vault_id = try allocator.dupe(u8, vault_id),
            .title = try allocator.dupe(u8, title),
            .description = null,
            .status = .pending,
            .priority = .medium,
            .due_date = null,
            .assigned_to = null,
            .tags = &.{},
            .created_at = now,
            .updated_at = now,
            .completed_at = null,
        };
    }
    
    pub fn deinit(self: *Task) void {
        self.allocator.free(self.id);
        self.allocator.free(self.vault_id);
        self.allocator.free(self.title);
        if (self.description) |d| self.allocator.free(d);
        if (self.assigned_to) |a| self.allocator.free(a);
        for (self.tags) |tag| self.allocator.free(tag);
        self.allocator.free(self.tags);
    }
    
    pub fn complete(self: *Task) void {
        self.status = .completed;
        self.completed_at = std.Io.Timestamp.now(io, .real).toSeconds();
        self.updated_at = std.Io.Timestamp.now(io, .real).toSeconds();
    }
    
    pub fn isOverdue(self: Task) bool {
        if (self.due_date) |due| {
            return std.Io.Timestamp.now(io, .real).toSeconds() > due and self.status != .completed;
        }
        return false;
    }
};
```

**User Entity:**

```zig
pub const User = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    username: []const u8,
    email: []const u8,
    password_hash: []const u8, // Argon2id hash (never serialized to JSON)
    created_at: i64,
    updated_at: i64,
    last_login_at: ?i64,
    
    pub fn init(allocator: std.mem.Allocator, username: []const u8, email: []const u8) !User {
        const id = try generateUuid(allocator);
        const now = std.Io.Timestamp.now(io, .real).toSeconds();
        
        return .{
            .allocator = allocator,
            .id = id,
            .username = try allocator.dupe(u8, username),
            .email = try allocator.dupe(u8, email),
            .password_hash = &.{},
            .created_at = now,
            .updated_at = now,
            .last_login_at = null,
        };
    }
    
    pub fn deinit(self: *User) void {
        self.allocator.free(self.id);
        self.allocator.free(self.username);
        self.allocator.free(self.email);
        self.allocator.free(self.password_hash);
    }
    
    pub fn setPassword(self: *User, password: []const u8) !void {
        // Hash password with Argon2id
        const hash = try crypto.hashPassword(self.allocator, password);
        self.allocator.free(self.password_hash);
        self.password_hash = hash;
        self.updated_at = std.Io.Timestamp.now(io, .real).toSeconds();
    }
    
    pub fn verifyPassword(self: User, password: []const u8) !bool {
        return try crypto.verifyPassword(self.password_hash, password);
    }
};
```

### 1.2 Cryptography Module

#### File: `src/crypto/master.zig`

**Master Password & Key Derivation:**

```zig
const std = @import("std");
const crypto = std.crypto;

// Argon2id parameters (OWASP recommended)
const ARGON2_ITERATIONS = 3;
const ARGON2_MEMORY_KB = 65536; // 64 MB
const ARGON2_PARALLELISM = 4;

/// Derive encryption key from master password using Argon2id
/// Returns 32-byte (256-bit) key suitable for AES-256
pub fn deriveKey(
    password: []const u8,
    salt: [16]u8,
    out_key: *[32]u8,
) !void {
    // Use Argon2id from std.crypto
    crypto.pwhash.argon2.argon2id(
        out_key,
        password,
        &salt,
        .{
            .t = ARGON2_ITERATIONS,
            .m = ARGON2_MEMORY_KB,
            .p = ARGON2_PARALLELISM,
        },
        .{}
    );
}

/// Generate random salt for key derivation
pub fn generateSalt() [16]u8 {
    var salt: [16]u8 = undefined;
    io.random(salt);
    return salt;
}

/// Hash password for user authentication (server-side)
pub fn hashPassword(allocator: std.mem.Allocator, password: []const u8) ![]const u8 {
    const salt = generateSalt();
    var hash: [32]u8 = undefined;
    
    try deriveKey(password, salt, &hash);
    
    // Format: $argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>
    const encoded_len = 128; // Sufficient for encoded hash
    const encoded = try allocator.alloc(u8, encoded_len);
    
    // Encode in PHC string format
    const prefix = "$argon2id$v=19$m=65536,t=3,p=4$";
    @memcpy(encoded[0..prefix.len], prefix);
    
    // Base64 encode salt and hash
    const encoder = std.base64.standard.Encoder;
    _ = encoder.encode(encoded[prefix.len..], &salt);
    encoded[prefix.len + 24] = '$';
    _ = encoder.encode(encoded[prefix.len + 25 ..], &hash);
    
    return encoded;
}

/// Verify password against stored hash
pub fn verifyPassword(stored_hash: []const u8, password: []const u8) !bool {
    // Parse PHC format and extract salt
    // Re-derive key and compare
    // Implementation details...
    _ = stored_hash;
    _ = password;
    return true; // Placeholder
}
```

#### File: `src/crypto/aes_gcm.zig`

**AES-256-GCM Encryption:**

```zig
const std = @import("std");
const crypto = std.crypto;

const Aes256Gcm = crypto.aead.aes_gcm.Aes256Gcm;
const KEY_SIZE = 32;  // 256 bits
const NONCE_SIZE = 12; // 96 bits
const TAG_SIZE = 16;   // 128 bits

/// Encrypt plaintext using AES-256-GCM
/// Returns: nonce (12 bytes) || ciphertext || tag (16 bytes)
pub fn encrypt(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    key: [KEY_SIZE]u8,
) ![]const u8 {
    // Generate random nonce
    var nonce: [NONCE_SIZE]u8 = undefined;
    io.random(nonce);
    
    // Allocate output buffer: nonce + ciphertext + tag
    const out_len = NONCE_SIZE + plaintext.len + TAG_SIZE;
    const output = try allocator.alloc(u8, out_len);
    errdefer allocator.free(output);
    
    // Copy nonce to output
    @memcpy(output[0..NONCE_SIZE], &nonce);
    
    // Encrypt: output ciphertext into buffer after nonce
    var tag: [TAG_SIZE]u8 = undefined;
    Aes256Gcm.encrypt(
        output[NONCE_SIZE .. NONCE_SIZE + plaintext.len],
        &tag,
        plaintext,
        &.{}, // associated data (empty)
        nonce,
        key,
    );
    
    // Copy tag to end of output
    @memcpy(output[out_len - TAG_SIZE ..], &tag);
    
    return output;
}

/// Decrypt ciphertext using AES-256-GCM
/// Input format: nonce (12 bytes) || ciphertext || tag (16 bytes)
pub fn decrypt(
    allocator: std.mem.Allocator,
    ciphertext: []const u8,
    key: [KEY_SIZE]u8,
) ![]const u8 {
    if (ciphertext.len < NONCE_SIZE + TAG_SIZE) {
        return error.InvalidCiphertext;
    }
    
    // Extract nonce
    var nonce: [NONCE_SIZE]u8 = undefined;
    @memcpy(&nonce, ciphertext[0..NONCE_SIZE]);
    
    // Extract tag
    var tag: [TAG_SIZE]u8 = undefined;
    @memcpy(&tag, ciphertext[ciphertext.len - TAG_SIZE ..]);
    
    // Extract actual ciphertext (between nonce and tag)
    const enc_data = ciphertext[NONCE_SIZE .. ciphertext.len - TAG_SIZE];
    
    // Allocate plaintext buffer
    const plaintext = try allocator.alloc(u8, enc_data.len);
    errdefer allocator.free(plaintext);
    
    // Decrypt
    try Aes256Gcm.decrypt(
        plaintext,
        enc_data,
        tag,
        &.{}, // associated data (empty)
        nonce,
        key,
    );
    
    return plaintext;
}
```

#### File: `src/crypto/generator.zig`

**Password Generation:**

```zig
const std = @import("std");

pub const GenerationOptions = struct {
    length: usize = 16,
    include_uppercase: bool = true,
    include_lowercase: bool = true,
    include_digits: bool = true,
    include_symbols: bool = true,
    exclude_ambiguous: bool = true, // Exclude 0, O, l, 1, etc.
    min_uppercase: usize = 1,
    min_lowercase: usize = 1,
    min_digits: usize = 1,
    min_symbols: usize = 1,
};

const UPPERCASE = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const LOWERCASE = "abcdefghijklmnopqrstuvwxyz";
const DIGITS = "0123456789";
const SYMBOLS = "!@#$%^&*()_+-=[]{}|;:,.<>?";
const AMBIGUOUS = "0OIl1";

/// Generate a secure random password
pub fn generatePassword(allocator: std.mem.Allocator, options: GenerationOptions) ![]const u8 {
    var charset: [128]u8 = undefined;
    var charset_len: usize = 0;
    
    // Build character set based on options
    if (options.include_uppercase) {
        @memcpy(charset[charset_len..charset_len + UPPERCASE.len], UPPERCASE);
        charset_len += UPPERCASE.len;
    }
    if (options.include_lowercase) {
        @memcpy(charset[charset_len..charset_len + LOWERCASE.len], LOWERCASE);
        charset_len += LOWERCASE.len;
    }
    if (options.include_digits) {
        @memcpy(charset[charset_len..charset_len + DIGITS.len], DIGITS);
        charset_len += DIGITS.len;
    }
    if (options.include_symbols) {
        @memcpy(charset[charset_len..charset_len + SYMBOLS.len], SYMBOLS);
        charset_len += SYMBOLS.len;
    }
    
    if (charset_len == 0) return error.EmptyCharset;
    
    // Generate password
    const password = try allocator.alloc(u8, options.length);
    errdefer allocator.free(password);
    
    var i: usize = 0;
    while (i < options.length) : (i += 1) {
        const random_idx = std.crypto.random.int(usize) % charset_len;
        password[i] = charset[random_idx];
    }
    
    // Ensure minimum requirements are met
    // (implementation for checking and regenerating if needed)
    
    return password;
}

/// Generate a memorable passphrase (diceware style)
pub fn generatePassphrase(allocator: std.mem.Allocator, word_count: usize) ![]const u8 {
    // Use EFF wordlist or similar
    const wordlist = @embedFile("wordlist.txt"); // 7776 words
    
    var words = try allocator.alloc([]const u8, word_count);
    defer allocator.free(words);
    
    // Select random words
    for (0..word_count) |i| {
        const random_idx = std.crypto.random.int(u32) % 7776;
        words[i] = getWordAtIndex(wordlist, random_idx);
    }
    
    // Join with spaces
    return std.mem.join(allocator, " ", words);
}

/// Calculate password entropy in bits
pub fn calculateEntropy(password: []const u8) f64 {
    var charset_size: f64 = 0;
    var has_upper = false;
    var has_lower = false;
    var has_digit = false;
    var has_symbol = false;
    
    for (password) |c| {
        if (!has_upper and std.ascii.isUpper(c)) {
            has_upper = true;
            charset_size += 26;
        }
        if (!has_lower and std.ascii.isLower(c)) {
            has_lower = true;
            charset_size += 26;
        }
        if (!has_digit and std.ascii.isDigit(c)) {
            has_digit = true;
            charset_size += 10;
        }
        if (!has_symbol and !std.ascii.isAlphanumeric(c)) {
            has_symbol = true;
            charset_size += 32;
        }
    }
    
    return @log2(charset_size) * @as(f64, @floatFromInt(password.len));
}

/// Evaluate password strength
pub const Strength = enum {
    very_weak,
    weak,
    moderate,
    strong,
    very_strong,
};

pub fn evaluateStrength(password: []const u8) Strength {
    const entropy = calculateEntropy(password);
    
    return if (entropy < 25) .very_weak
        else if (entropy < 45) .weak
        else if (entropy < 65) .moderate
        else if (entropy < 85) .strong
        else .very_strong;
}
```

---

## Phase 2: Storage Layer

### 2.1 Storage Interface

#### File: `src/storage/interface.zig`

**Storage Trait Definition:**

```zig
const std = @import("std");
const core = @import("../core/types.zig");

/// Storage interface - all storage backends must implement this
pub fn Storage(comptime T: type) type {
    return struct {
        // Vault operations
        createVault: *const fn (self: T, vault: *const core.Vault) anyerror!void,
        getVault: *const fn (self: T, id: []const u8, allocator: std.mem.Allocator) anyerror!?core.Vault,
        updateVault: *const fn (self: T, vault: *const core.Vault) anyerror!void,
        deleteVault: *const fn (self: T, id: []const u8) anyerror!void,
        listVaults: *const fn (self: T, allocator: std.mem.Allocator) anyerror![]core.Vault,
        
        // Password operations
        createPassword: *const fn (self: T, vault_id: []const u8, password: *const core.Password) anyerror!void,
        getPassword: *const fn (self: T, vault_id: []const u8, id: []const u8, allocator: std.mem.Allocator) anyerror!?core.Password,
        updatePassword: *const fn (self: T, vault_id: []const u8, password: *const core.Password) anyerror!void,
        deletePassword: *const fn (self: T, vault_id: []const u8, id: []const u8) anyerror!void,
        listPasswords: *const fn (self: T, vault_id: []const u8, allocator: std.mem.Allocator) anyerror![]core.Password,
        searchPasswords: *const fn (self: T, vault_id: []const u8, query: []const u8, allocator: std.mem.Allocator) anyerror![]core.Password,
        
        // Task operations
        createTask: *const fn (self: T, vault_id: []const u8, task: *const core.Task) anyerror!void,
        getTask: *const fn (self: T, vault_id: []const u8, id: []const u8, allocator: std.mem.Allocator) anyerror!?core.Task,
        updateTask: *const fn (self: T, vault_id: []const u8, task: *const core.Task) anyerror!void,
        deleteTask: *const fn (self: T, vault_id: []const u8, id: []const u8) anyerror!void,
        listTasks: *const fn (self: T, vault_id: []const u8, allocator: std.mem.Allocator) anyerror![]core.Task,
        searchTasks: *const fn (self: T, vault_id: []const u8, query: []const u8, allocator: std.mem.Allocator) anyerror![]core.Task,
        
        // Lifecycle
        close: *const fn (self: T) void,
    };
}
```

### 2.2 JSON Storage Adapter

#### File: `src/storage/json.zig`

**File-Based JSON Storage:**

```zig
const std = @import("std");
const core = @import("../core/types.zig");
const Storage = @import("interface.zig").Storage;

pub const JsonStorage = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,
    file_locks: std.StringHashMap(FileLock),
    
    const FileLock = struct {
        mutex: std.Thread.Mutex,
    };
    
    pub fn init(allocator: std.mem.Allocator, base_path: []const u8) !JsonStorage {
        // Ensure directory exists
        try std.Io.Dir.cwd().makePath(base_path);
        
        return .{
            .allocator = allocator,
            .base_path = try allocator.dupe(u8, base_path),
            .file_locks = std.StringHashMap(FileLock).init(allocator),
        };
    }
    
    pub fn deinit(self: *JsonStorage) void {
        self.allocator.free(self.base_path);
        
        var it = self.file_locks.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.file_locks.deinit();
    }
    
    fn getVaultPath(self: JsonStorage, vault_id: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fs.path.join(allocator, &.{ self.base_path, vault_id, ".json" });
    }
    
    // Implement all Storage interface methods...
    
    pub fn createVault(self: JsonStorage, vault: *const core.Vault) !void {
        const path = try self.getVaultPath(vault.id, self.allocator);
        defer self.allocator.free(path);
        
        // Atomic write: write to temp file, then rename
        const temp_path = try std.mem.concat(self.allocator, u8, &.{ path, ".tmp" });
        defer self.allocator.free(temp_path);
        
        const file = try std.Io.Dir.cwd().createFile(temp_path, .{});
        defer file.close();
        
        // Serialize vault to JSON
        const json_str = try vaultToJson(self.allocator, vault);
        defer self.allocator.free(json_str);
        
        try file.writeAll(json_str);
        try file.sync();
        
        // Atomic rename
        try std.Io.Dir.cwd().rename(temp_path, path);
    }
    
    fn vaultToJson(allocator: std.mem.Allocator, vault: *const core.Vault) ![]const u8 {
        // Serialize using std.json
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit();
        
        try std.json.stringify(.{
            .id = vault.id,
            .name = vault.name,
            .description = vault.description,
            .owner_id = vault.owner_id,
            .created_at = vault.created_at,
            .updated_at = vault.updated_at,
        }, .{ .whitespace = .indent_2 }, buf.writer());
        
        return alloc_writer.written();
    }
    
    // ... implement other methods
};

// Create storage interface implementation
pub fn jsonStorageInterface(storage: *JsonStorage) Storage(*JsonStorage) {
    return .{
        .createVault = JsonStorage.createVault,
        .getVault = JsonStorage.getVault,
        .updateVault = JsonStorage.updateVault,
        .deleteVault = JsonStorage.deleteVault,
        .listVaults = JsonStorage.listVaults,
        // ... other methods
        .close = JsonStorage.close,
    };
}
```

### 2.3 SQLite Storage Adapter

#### File: `src/storage/sqlite.zig`

**SQLite Database Storage:**

```zig
const std = @import("std");
const core = @import("../core/types.zig");
const Storage = @import("interface.zig").Storage;

// Use zig-sqlite wrapper, or addTranslateC + linkSystemLibrary in build.zig
// (0.16 deprecates @cImport; use build system instead)
const sqlite = @import("sqlite");

pub const SqliteStorage = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8, io: std.Io) !SqliteStorage {
        var db = try sqlite.Db.open(db_path);
        errdefer db.close();
        
        var storage = SqliteStorage{
            .allocator = allocator,
            .db = db,
        };
        
        try storage.initSchema();
        
        return storage;
    }
    
    pub fn deinit(self: *SqliteStorage) void {
        self.db.close();
    }
    
    fn initSchema(self: SqliteStorage) !void {
        try self.db.exec(
            \\ CREATE TABLE IF NOT EXISTS vaults (
            \\   id TEXT PRIMARY KEY,
            \\   name TEXT NOT NULL,
            \\   description TEXT,
            \\   owner_id TEXT NOT NULL,
            \\   created_at INTEGER NOT NULL,
            \\   updated_at INTEGER NOT NULL
            \\ );
            \\
            \\ CREATE TABLE IF NOT EXISTS passwords (
            \\   id TEXT PRIMARY KEY,
            \\   vault_id TEXT NOT NULL,
            \\   title TEXT NOT NULL,
            \\   username TEXT,
            \\   encrypted_password BLOB NOT NULL,
            \\   url TEXT,
            \\   notes TEXT,
            \\   category TEXT,
            \\   created_at INTEGER NOT NULL,
            \\   updated_at INTEGER NOT NULL,
            \\   FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE
            \\ );
            \\
            \\ CREATE TABLE IF NOT EXISTS tasks (
            \\   id TEXT PRIMARY KEY,
            \\   vault_id TEXT NOT NULL,
            \\   title TEXT NOT NULL,
            \\   description TEXT,
            \\   status TEXT NOT NULL,
            \\   priority TEXT NOT NULL,
            \\   due_date INTEGER,
            \\   created_at INTEGER NOT NULL,
            \\   updated_at INTEGER NOT NULL,
            \\   FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE
            \\ );
        , .{}, .{});
    }
    
    pub fn createVault(self: SqliteStorage, vault: *const core.Vault) !void {
        try self.db.exec(
            "INSERT INTO vaults (id, name, description, owner_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            .{},
            .{},
        );
    }
    
    // ... implement other methods
};
```

### 2.4 Remote Storage Adapter

#### File: `src/storage/remote.zig`

**HTTP Client for Remote API:**

```zig
> **Note:** `std.http.Client` was removed in Zig 0.16. For remote storage, use raw socket I/O (`std.Io.net`) or a dedicated HTTP library.

```zig
const std = @import("std");
const core = @import("../core/types.zig");

pub const RemoteStorage = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    auth_token: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, auth_token: []const u8) !RemoteStorage {
        return .{
            .allocator = allocator,
            .base_url = try allocator.dupe(u8, base_url),
            .auth_token = try allocator.dupe(u8, auth_token),
        };
    }
    
    pub fn deinit(self: *RemoteStorage) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.auth_token);
    }
    
    // HTTP requests use std.Io.net or an external HTTP library.
    // Implementation depends on the chosen HTTP client approach.
    
    pub fn createVault(self: RemoteStorage, vault: *const core.Vault) !void {
        _ = self;
        _ = vault;
        @panic("not yet implemented");
    }
    
    pub fn listVaults(self: RemoteStorage, allocator: std.mem.Allocator) ![]core.Vault {
        _ = self;
        _ = allocator;
        @panic("not yet implemented");
    }
    
    // ... implement other methods
};
```

---

## Phase 3: CLI Application

### 3.1 Command Structure

#### File: `src/cli/parser.zig`

> **Note:** The actual project uses `flags` (github.com/spikenardco/flags.zig) for argument parsing, not `clap`. The code below uses `clap` syntax for illustration.

**CLI Command Definitions:**

```zig
const std = @import("std");
const clap = @import("clap");

pub const Command = union(enum) {
    // Vault commands
    vault: VaultCommand,
    
    // Password commands
    password: PasswordCommand,
    
    // Task commands
    task: TaskCommand,
    
    // Config commands
    config: ConfigCommand,
    
    // Auth commands
    auth: AuthCommand,
    
    // Sync commands
    sync: SyncCommand,
    
    // Help and version
    help: ?[]const u8,
    version,
};

pub const VaultCommand = union(enum) {
    create: struct { name: []const u8, description: ?[]const u8 },
    open: struct { name: []const u8, master_password: ?[]const u8 },
    close,
    list,
    delete: struct { name: []const u8, force: bool },
    backup: struct { vault: []const u8, path: []const u8 },
    restore: struct { path: []const u8, force: bool },
    info,
};

pub const PasswordCommand = union(enum) {
    add: struct {
        name: []const u8,
        username: ?[]const u8,
        password: ?[]const u8,
        url: ?[]const u8,
        category: ?[]const u8,
        generate: bool,
    },
    get: struct { name: []const u8, show_password: bool },
    list: struct {
        category: ?[]const u8,
        tag: ?[]const u8,
        search: ?[]const u8,
    },
    edit: struct {
        name: []const u8,
        new_name: ?[]const u8,
        username: ?[]const u8,
        password: ?[]const u8,
        url: ?[]const u8,
    },
    delete: struct { name: []const u8, force: bool },
    generate: struct {
        length: usize,
        no_uppercase: bool,
        no_digits: bool,
        no_symbols: bool,
    },
    search: struct { query: []const u8 },
    copy: struct { name: []const u8 },
    share: struct { name: []const u8, user: []const u8 },
};

pub const TaskCommand = union(enum) {
    add: struct {
        title: []const u8,
        description: ?[]const u8,
        priority: ?[]const u8,
        due: ?[]const u8,
        category: ?[]const u8,
    },
    list: struct {
        status: ?[]const u8,
        priority: ?[]const u8,
        due: ?[]const u8,
        category: ?[]const u8,
    },
    complete: struct { id: []const u8 },
    delete: struct { id: []const u8 },
    edit: struct {
        id: []const u8,
        title: ?[]const u8,
        description: ?[]const u8,
        priority: ?[]const u8,
        due: ?[]const u8,
    },
    start: struct { id: []const u8 },
    assign: struct { id: []const u8, user: []const u8 },
};

pub const ConfigCommand = union(enum) {
    init,
    show,
    set: struct { key: []const u8, value: []const u8 },
    get: struct { key: []const u8 },
    reset,
};

pub const AuthCommand = union(enum) {
    login: struct { server: []const u8, method: AuthMethod },
    logout,
    status,
    refresh,
};

pub const AuthMethod = enum {
    oauth_github,
    oauth_google,
    token,
};

pub const SyncCommand = union(enum) {
    sync,
    status,
    force,
};

/// Parse command-line arguments into structured command
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Command {
    const params = comptime clap.parseParamsComptime(
        \\ -h, --help    Display this help and exit.
        \\ -v, --version Display version and exit.
        \\ <command>     Command to run (vault, password, task, config, auth, sync)
        \\ [args...]     Command arguments
    );
    
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
    }) catch |err| {
        diag.report(std.Io.File.stderr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();
    
    if (res.args.help != 0)
        return Command{ .help = null };
    if (res.args.version != 0)
        return Command.version;
    
    // Parse subcommand
    const cmd_str = res.positionals[0] orelse return error.MissingCommand;
    
    if (std.mem.eql(u8, cmd_str, "vault")) {
        return try parseVaultCommand(allocator, res.positionals[1..]);
    } else if (std.mem.eql(u8, cmd_str, "password")) {
        return try parsePasswordCommand(allocator, res.positionals[1..]);
    } else if (std.mem.eql(u8, cmd_str, "task")) {
        return try parseTaskCommand(allocator, res.positionals[1..]);
    } else if (std.mem.eql(u8, cmd_str, "config")) {
        return try parseConfigCommand(allocator, res.positionals[1..]);
    } else if (std.mem.eql(u8, cmd_str, "auth")) {
        return try parseAuthCommand(allocator, res.positionals[1..]);
    } else if (std.mem.eql(u8, cmd_str, "sync")) {
        return try parseSyncCommand(allocator, res.positionals[1..]);
    }
    
    return error.UnknownCommand;
}
```

### 3.2 CLI Application Entry Point

#### File: `src/main.zig`

```zig
const std = @import("std");
const cli = @import("cli/parser.zig");
const commands = @import("cli/commands.zig");
const config = @import("config/loader.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const allocator = init.arena.allocator();
    const io = init.io;
    
    const args = try init.minimal.args.toSlice(allocator);
    
    const command = cli.parse(allocator, args[1..]) catch |err| {
        switch (err) {
            error.MissingCommand => {
                std.log.err("No command specified. Use 'tip --help' for usage.", .{});
                std.process.exit(1);
            },
            error.UnknownCommand => {
                std.log.err("Unknown command. Use 'tip --help' for usage.", .{});
                std.process.exit(1);
            },
            else => return err,
        }
    };
    
    const cfg = try config.load(allocator, io);
    defer config.free(allocator, cfg);
    
    switch (command) {
        .vault => |vc| try commands.handleVault(allocator, io, cfg, vc),
        .password => |pc| try commands.handlePassword(allocator, io, cfg, pc),
        .task => |tc| try commands.handleTask(allocator, io, cfg, tc),
        .config => |cc| try commands.handleConfig(allocator, io, cfg, cc),
        .auth => |ac| try commands.handleAuth(allocator, io, cfg, ac),
        .sync => |sc| try commands.handleSync(allocator, io, cfg, sc),
        .help => |topic| try commands.showHelp(io, topic),
        .version => try commands.showVersion(),
    }
}
```

### 3.3 Command Handlers

#### File: `src/cli/vault.zig`

**Vault Command Implementation:**

```zig
const std = @import("std");
const core = @import("../core/types.zig");
const storage = @import("../storage/interface.zig");
const crypto = @import("../crypto/master.zig");
const terminal = @import("../utils/terminal.zig");

const VaultCommand = @import("parser.zig").VaultCommand;

pub fn handle(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage_backend: anytype,
    cmd: VaultCommand,
) !void {
    switch (cmd) {
        .create => |c| try createVault(allocator, io, storage_backend, c),
        .open => |c| try openVault(allocator, storage_backend, c),
        .close => try closeVault(allocator, storage_backend),
        .list => try listVaults(allocator, storage_backend),
        .delete => |c| try deleteVault(allocator, storage_backend, c),
        .backup => |c| try backupVault(allocator, storage_backend, c),
        .restore => |c| try restoreVault(allocator, storage_backend, c),
        .info => try showVaultInfo(allocator, storage_backend),
    }
}

fn createVault(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage_backend: anytype,
    options: struct { name: []const u8, description: ?[]const u8 },
) !void {
    const password = try terminal.readPassword(allocator, "Enter master password: ");
    defer {
        @memset(password, 0);
        allocator.free(password);
    }
    
    const confirm = try terminal.readPassword(allocator, "Confirm master password: ");
    defer {
        @memset(confirm, 0);
        allocator.free(confirm);
    }
    
    if (!std.mem.eql(u8, password, confirm)) {
        std.log.err("Passwords do not match", .{});
        return error.PasswordMismatch;
    }
    
    var salt: [16]u8 = undefined;
    io.random(&salt);
    var key: [32]u8 = undefined;
    try crypto.deriveKey(password, salt, &key);
    defer @memset(&key, 0);
    
    const owner_id = "local_user";
    var vault = try core.Vault.init(allocator, io, options.name, owner_id);
    defer vault.deinit();
    
    if (options.description) |desc| {
        vault.description = try allocator.dupe(u8, desc);
    }
    
    try storage_backend.createVault(&vault);
    try saveVaultMetadata(allocator, vault.id, salt);
    
    std.log.info("Created vault: {s}", .{vault.name});
}

fn openVault(
    allocator: std.mem.Allocator,
    storage_backend: anytype,
    options: struct { name: []const u8, master_password: ?[]const u8 },
) !void {
    // Find vault by name
    const vault = try findVaultByName(allocator, storage_backend, options.name);
    defer vault.deinit();
    
    // Get master password
    const password = options.master_password orelse try terminal.readPassword(
        allocator,
        "Enter master password: ",
    );
    defer if (options.master_password == null) {
        @memset(password, 0);
        allocator.free(password);
    };
    
    // Load salt from metadata
    const salt = try loadVaultMetadata(allocator, vault.id);
    
    // Derive key and unlock vault
    try vault.unlock(password, salt);
    
    // Store unlocked vault in session
    try setActiveVault(allocator, &vault);
    
    std.log.info("Unlocked vault: {s}", .{vault.name});
}

fn listVaults(allocator: std.mem.Allocator, storage_backend: anytype) !void {
    const vaults = try storage_backend.listVaults(allocator);
    defer {
        for (vaults) |*v| v.deinit();
        allocator.free(vaults);
    }
    
    const stdout = std.io.getStdOut().writer();
    
    try stdout.print("Available vaults:\n", .{});
    try stdout.print("{s:20} {s:30} {s:20}\n", .{ "NAME", "DESCRIPTION", "CREATED" });
    try stdout.print("{s}\n", .{"-" ** 70});
    
    for (vaults) |vault| {
        const desc = vault.description orelse "-";
        const created = try formatTimestamp(allocator, vault.created_at);
        defer allocator.free(created);
        
        try stdout.print("{s:20} {s:30} {s:20}\n", .{
            vault.name,
            desc,
            created,
        });
    }
}

// ... other vault command implementations
```

---

## Phase 4: HTTP Server

### 4.1 Server Setup

#### File: `src/server/main.zig`

**Server Entry Point:**

```zig
const std = @import("std");
const http = std.http;
const router = @import("router.zig");
const middleware = @import("middleware.zig");
const database = @import("database.zig");

const SERVER_PORT = 8080;
const MAX_REQUEST_SIZE = 10 * 1024 * 1024; // 10MB

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Initialize database
    const db = try database.init(allocator, "tip.db");
    defer database.deinit(db);
    
    // Create HTTP server
    const addr = try std.net.Address.parseIp("0.0.0.0", SERVER_PORT);
    var server = try http.Server.init(allocator, .{ .reuse_address = true });
    defer server.deinit();
    
    try server.listen(addr);
    std.log.info("Server listening on port {d}", .{SERVER_PORT});
    
    // Accept connections
    while (true) {
        const conn = try server.accept();
        
        // Spawn handler in new thread (or use async/await)
        const thread = try std.Thread.spawn(.{}, handleConnection, .{
            allocator,
            conn,
            db,
        });
        thread.detach();
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    conn: http.Server.Connection,
    db: *database.Database,
) !void {
    defer conn.stream.close();
    
    var read_buffer: [8192]u8 = undefined;
    var server = http.Server.init(allocator, .{});
    
    // Read request
    var request = try server.receiveHead(conn, &read_buffer);
    
    // Apply middleware
    const context = middleware.Context{
        .allocator = allocator,
        .database = db,
        .request = &request,
    };
    
    if (!try middleware.authenticate(&context)) {
        try sendErrorResponse(conn, .unauthorized, "Authentication required");
        return;
    }
    
    // Route request
    const response = try router.route(context);
    
    // Send response
    try sendResponse(conn, response);
}

fn sendResponse(conn: http.Server.Connection, response: http.Server.Response) !void {
    var writer = conn.stream.writer();
    
    // Write status line
    try writer.print("HTTP/1.1 {d} {s}\r\n", .{
        @intFromEnum(response.status),
        response.status.phrase() orelse "Unknown",
    });
    
    // Write headers
    try writer.writeAll("Content-Type: application/json\r\n");
    try writer.print("Content-Length: {d}\r\n", .{response.body.len});
    try writer.writeAll("\r\n");
    
    // Write body
    try writer.writeAll(response.body);
}

fn sendErrorResponse(
    conn: http.Server.Connection,
    status: http.Status,
    message: []const u8,
) !void {
    const body = try std.fmt.allocPrint(std.heap.page_allocator, 
        \\\{"error": "{s}", "status": {d}}
    , .{ message, @intFromEnum(status) });
    defer std.heap.page_allocator.free(body);
    
    try sendResponse(conn, .{ .status = status, .body = body });
}
```

### 4.2 Router

#### File: `src/server/router.zig`

**API Route Definitions:**

```zig
const std = @import("std");
const http = std.http;
const middleware = @import("middleware.zig");
const handlers = @import("handlers.zig");

pub const Route = struct {
    method: http.Method,
    path: []const u8,
    handler: HandlerFn,
    requires_auth: bool,
};

pub const HandlerFn = *const fn (
    ctx: middleware.Context,
    path_params: []const u8,
    query_params: std.StringHashMap([]const u8),
) anyerror!http.Server.Response;

const routes = [_]Route{
    // Authentication
    .{ .method = .POST, .path = "/api/v1/auth/register", .handler = handlers.auth.register, .requires_auth = false },
    .{ .method = .POST, .path = "/api/v1/auth/login", .handler = handlers.auth.login, .requires_auth = false },
    .{ .method = .POST, .path = "/api/v1/auth/logout", .handler = handlers.auth.logout, .requires_auth = true },
    .{ .method = .POST, .path = "/api/v1/auth/refresh", .handler = handlers.auth.refresh, .requires_auth = true },
    
    // Vaults
    .{ .method = .GET,    .path = "/api/v1/vaults", .handler = handlers.vault.list, .requires_auth = true },
    .{ .method = .POST,   .path = "/api/v1/vaults", .handler = handlers.vault.create, .requires_auth = true },
    .{ .method = .GET,    .path = "/api/v1/vaults/:id", .handler = handlers.vault.get, .requires_auth = true },
    .{ .method = .PUT,    .path = "/api/v1/vaults/:id", .handler = handlers.vault.update, .requires_auth = true },
    .{ .method = .DELETE, .path = "/api/v1/vaults/:id", .handler = handlers.vault.delete, .requires_auth = true },
    .{ .method = .POST,   .path = "/api/v1/vaults/:id/backup", .handler = handlers.vault.backup, .requires_auth = true },
    .{ .method = .POST,   .path = "/api/v1/vaults/:id/restore", .handler = handlers.vault.restore, .requires_auth = true },
    
    // Passwords
    .{ .method = .GET,    .path = "/api/v1/vaults/:vault_id/passwords", .handler = handlers.password.list, .requires_auth = true },
    .{ .method = .POST,   .path = "/api/v1/vaults/:vault_id/passwords", .handler = handlers.password.create, .requires_auth = true },
    .{ .method = .GET,    .path = "/api/v1/vaults/:vault_id/passwords/:id", .handler = handlers.password.get, .requires_auth = true },
    .{ .method = .PUT,    .path = "/api/v1/vaults/:vault_id/passwords/:id", .handler = handlers.password.update, .requires_auth = true },
    .{ .method = .DELETE, .path = "/api/v1/vaults/:vault_id/passwords/:id", .handler = handlers.password.delete, .requires_auth = true },
    .{ .method = .GET,    .path = "/api/v1/vaults/:vault_id/passwords/search", .handler = handlers.password.search, .requires_auth = true },
    .{ .method = .POST,   .path = "/api/v1/vaults/:vault_id/passwords/generate", .handler = handlers.password.generate, .requires_auth = true },
    
    // Tasks
    .{ .method = .GET,    .path = "/api/v1/vaults/:vault_id/tasks", .handler = handlers.task.list, .requires_auth = true },
    .{ .method = .POST,   .path = "/api/v1/vaults/:vault_id/tasks", .handler = handlers.task.create, .requires_auth = true },
    .{ .method = .GET,    .path = "/api/v1/vaults/:vault_id/tasks/:id", .handler = handlers.task.get, .requires_auth = true },
    .{ .method = .PUT,    .path = "/api/v1/vaults/:vault_id/tasks/:id", .handler = handlers.task.update, .requires_auth = true },
    .{ .method = .DELETE, .path = "/api/v1/vaults/:vault_id/tasks/:id", .handler = handlers.task.delete, .requires_auth = true },
    .{ .method = .POST,   .path = "/api/v1/vaults/:vault_id/tasks/:id/complete", .handler = handlers.task.complete, .requires_auth = true },
    
    // Sync
    .{ .method = .GET,    .path = "/api/v1/sync/status", .handler = handlers.sync.status, .requires_auth = true },
    .{ .method = .POST,   .path = "/api/v1/sync/full", .handler = handlers.sync.full, .requires_auth = true },
    .{ .method = .POST,   .path = "/api/v1/sync/incremental", .handler = handlers.sync.incremental, .requires_auth = true },
};

pub fn route(ctx: middleware.Context) !http.Server.Response {
    const request_path = ctx.request.head.target;
    const method = ctx.request.head.method;
    
    // Find matching route
    for (routes) |route_def| {
        if (route_def.method != method) continue;
        
        // Simple path matching (consider using a proper router library)
        if (matchPath(route_def.path, request_path)) |params| {
            if (route_def.requires_auth and !ctx.authenticated) {
                return error.Unauthorized;
            }
            
            // Parse query parameters
            var query_params = std.StringHashMap([]const u8).init(ctx.allocator);
            defer query_params.deinit();
            try parseQueryParams(request_path, &query_params);
            
            return try route_def.handler(ctx, params, query_params);
        }
    }
    
    return error.NotFound;
}

fn matchPath(pattern: []const u8, path: []const u8) ?[]const u8 {
    // Simple path matching with parameter extraction
    // Returns path parameters or null if no match
    _ = pattern;
    _ = path;
    // Implementation...
    return "";
}

fn parseQueryParams(path: []const u8, params: *std.StringHashMap([]const u8)) !void {
    // Parse query string into hash map
    _ = path;
    _ = params;
}
```

### 4.3 Authentication Middleware

#### File: `src/server/middleware.zig`

**JWT Authentication:**

```zig
const std = @import("std");
const http = std.http;
const jwt = @import("zig-jwt"); // External dependency
const database = @import("database.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    database: *database.Database,
    request: *http.Server.Request,
    authenticated: bool = false,
    user_id: ?[]const u8 = null,
};

const JWT_SECRET = "your-secret-key-here"; // Load from env/config

pub fn authenticate(ctx: *Context) !bool {
    const auth_header = ctx.request.headers.get("Authorization") orelse return false;
    
    // Check for Bearer token
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, auth_header, prefix)) {
        return false;
    }
    
    const token = auth_header[prefix.len..];
    
    // Verify JWT
    const claims = jwt.verify(token, JWT_SECRET) catch |err| {
        std.log.warn("JWT verification failed: {s}", .{@errorName(err)});
        return false;
    };
    
    ctx.authenticated = true;
    ctx.user_id = claims.sub;
    
    return true;
}

pub fn requireAuth(ctx: Context) !void {
    if (!ctx.authenticated) {
        return error.Unauthorized;
    }
}

pub fn generateToken(allocator: std.mem.Allocator, user_id: []const u8) ![]const u8 {
    const claims = jwt.Claims{
        .sub = user_id,
        .iat = std.Io.Timestamp.now(io, .real).toSeconds(),
        .exp = std.Io.Timestamp.now(io, .real).toSeconds() + 86400, // 24 hours
    };
    
    return try jwt.encode(allocator, claims, JWT_SECRET);
}
```

---

## Phase 5: Advanced Features

### 5.1 Search and Filtering

#### File: `src/utils/search.zig`

**Fuzzy Search Implementation:**

```zig
const std = @import("std");
const core = @import("../core/types.zig");

pub const SearchOptions = struct {
    query: []const u8,
    category: ?[]const u8 = null,
    tags: ?[][]const u8 = null,
    case_sensitive: bool = false,
    fuzzy: bool = true,
};

pub const SearchResult = struct {
    password: ?core.Password = null,
    task: ?core.Task = null,
    score: f32, // Relevance score
};

/// Fuzzy search through passwords and tasks
pub fn search(
    allocator: std.mem.Allocator,
    passwords: []const core.Password,
    tasks: []const core.Task,
    options: SearchOptions,
) ![]SearchResult {
    var results = std.ArrayList(SearchResult).init(allocator);
    defer results.deinit();
    
    // Search passwords
    for (passwords) |*pwd| {
        const score = scorePassword(pwd, options);
        if (score > 0) {
            try results.append(.{
                .password = pwd.*,
                .score = score,
            });
        }
    }
    
    // Search tasks
    for (tasks) |*task| {
        const score = scoreTask(task, options);
        if (score > 0) {
            try results.append(.{
                .task = task.*,
                .score = score,
            });
        }
    }
    
    // Sort by relevance score
    std.mem.sort(SearchResult, results.items, {}, compareByScore);
    
    return results.toOwnedSlice();
}

fn scorePassword(password: *const core.Password, options: SearchOptions) f32 {
    var score: f32 = 0;
    const query = if (options.case_sensitive) options.query else std.ascii.lowerString;
    
    // Check title
    if (fuzzyMatch(password.title, query)) {
        score += 1.0;
        if (std.mem.indexOf(u8, password.title, query) != null) {
            score += 0.5; // Exact substring match
        }
    }
    
    // Check username
    if (password.username) |username| {
        if (fuzzyMatch(username, query)) {
            score += 0.8;
        }
    }
    
    // Check URL
    if (password.url) |url| {
        if (fuzzyMatch(url, query)) {
            score += 0.6;
        }
    }
    
    // Filter by category
    if (options.category) |cat| {
        if (password.category == null or !std.mem.eql(u8, password.category.?, cat)) {
            return 0; // Doesn't match category filter
        }
    }
    
    return score;
}

fn scoreTask(task: *const core.Task, options: SearchOptions) f32 {
    var score: f32 = 0;
    
    // Check title
    if (fuzzyMatch(task.title, options.query)) {
        score += 1.0;
    }
    
    // Check description
    if (task.description) |desc| {
        if (fuzzyMatch(desc, options.query)) {
            score += 0.7;
        }
    }
    
    return score;
}

/// Simple fuzzy matching (Levenshtein distance)
fn fuzzyMatch(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (text.len == 0) return false;
    
    // Simple implementation: check if all characters of query appear in order
    var query_idx: usize = 0;
    for (text) |c| {
        if (query_idx < query.len and std.ascii.toLower(c) == std.ascii.toLower(query[query_idx])) {
            query_idx += 1;
        }
    }
    
    return query_idx == query.len;
}

fn compareByScore(_: void, a: SearchResult, b: SearchResult) bool {
    return a.score > b.score;
}
```

### 5.2 Password Strength Evaluation

#### File: `src/utils/password_strength.zig`

```zig
const std = @import("std");

pub const Strength = enum {
    very_weak,
    weak,
    moderate,
    strong,
    very_strong,
    
    pub fn toString(self: Strength) []const u8 {
        return switch (self) {
            .very_weak => "Very Weak",
            .weak => "Weak",
            .moderate => "Moderate",
            .strong => "Strong",
            .very_strong => "Very Strong",
        };
    }
    
    pub fn emoji(self: Strength) []const u8 {
        return switch (self) {
            .very_weak => "🔴",
            .weak => "🟠",
            .moderate => "🟡",
            .strong => "🟢",
            .very_strong => "🔵",
        };
    }
};

pub const StrengthAnalysis = struct {
    strength: Strength,
    entropy: f64,
    crack_time_seconds: f64,
    suggestions: [][]const u8,
};

/// Comprehensive password strength analysis
pub fn analyze(password: []const u8, allocator: std.mem.Allocator) !StrengthAnalysis {
    var suggestions = std.ArrayList([]const u8).empty;
    
    // Calculate entropy
    const entropy = calculateEntropy(password);
    
    // Check character variety
    var has_upper = false;
    var has_lower = false;
    var has_digit = false;
    var has_symbol = false;
    var unique_chars: u8 = 0;
    var char_set = std.bit_set.IntegerBitSet(256).initEmpty();
    
    for (password) |c| {
        if (!char_set.isSet(c)) {
            char_set.set(c);
            unique_chars += 1;
        }
        
        if (std.ascii.isUpper(c)) has_upper = true;
        if (std.ascii.isLower(c)) has_lower = true;
        if (std.ascii.isDigit(c)) has_digit = true;
        if (!std.ascii.isAlphanumeric(c)) has_symbol = true;
    }
    
    // Generate suggestions
    if (password.len < 8) {
        try suggestions.append("Use at least 8 characters");
    }
    if (password.len < 12) {
        try suggestions.append("Consider using 12+ characters for better security");
    }
    if (!has_upper) try suggestions.append("Add uppercase letters");
    if (!has_lower) try suggestions.append("Add lowercase letters");
    if (!has_digit) try suggestions.append("Add numbers");
    if (!has_symbol) try suggestions.append("Add special characters (!@#$%^&*)");
    if (unique_chars < password.len / 2) {
        try suggestions.append("Avoid repeating characters");
    }
    
    // Check against common patterns
    if (isCommonPassword(password)) {
        try suggestions.append("This is a commonly used password - avoid it!");
    }
    
    if (hasSequentialPattern(password)) {
        try suggestions.append("Avoid sequential patterns (123, abc)");
    }
    
    // Determine strength based on entropy and checks
    const strength = determineStrength(entropy, password.len, has_upper, has_lower, has_digit, has_symbol);
    
    // Estimate crack time (simplified)
    const crack_time = estimateCrackTime(entropy);
    
    return .{
        .strength = strength,
        .entropy = entropy,
        .crack_time_seconds = crack_time,
        .suggestions = try suggestions.toOwnedSlice(),
    };
}

fn calculateEntropy(password: []const u8) f64 {
    var pool_size: f64 = 0;
    var has_upper = false;
    var has_lower = false;
    var has_digit = false;
    var has_symbol = false;
    
    for (password) |c| {
        if (!has_upper and std.ascii.isUpper(c)) {
            has_upper = true;
            pool_size += 26;
        }
        if (!has_lower and std.ascii.isLower(c)) {
            has_lower = true;
            pool_size += 26;
        }
        if (!has_digit and std.ascii.isDigit(c)) {
            has_digit = true;
            pool_size += 10;
        }
        if (!has_symbol and !std.ascii.isAlphanumeric(c)) {
            has_symbol = true;
            pool_size += 32;
        }
    }
    
    if (pool_size == 0) return 0;
    
    return @log2(pool_size) * @as(f64, @floatFromInt(password.len));
}

fn determineStrength(
    entropy: f64,
    length: usize,
    has_upper: bool,
    has_lower: bool,
    has_digit: bool,
    has_symbol: bool,
) Strength {
    const variety_count = @intFromBool(has_upper) + @intFromBool(has_lower) + 
                         @intFromBool(has_digit) + @intFromBool(has_symbol);
    
    if (entropy < 28 or length < 6) return .very_weak;
    if (entropy < 36 or length < 8 or variety_count < 2) return .weak;
    if (entropy < 60 or variety_count < 3) return .moderate;
    if (entropy < 80 or variety_count < 4) return .strong;
    return .very_strong;
}

fn estimateCrackTime(entropy: f64) f64 {
    // Assume 10 billion guesses per second (powerful attacker)
    const guesses_per_second: f64 = 10_000_000_000;
    const combinations = std.math.pow(f64, 2, entropy);
    return combinations / guesses_per_second;
}

fn isCommonPassword(password: []const u8) bool {
    // Check against common password list
    const common_passwords = @embedFile("common_passwords.txt");
    
    var it = std.mem.splitScalar(u8, common_passwords, '\n');
    while (it.next()) |common| {
        if (std.mem.eql(u8, password, common)) {
            return true;
        }
    }
    return false;
}

fn hasSequentialPattern(password: []const u8) bool {
    // Check for sequential characters like "123", "abc", "qwe"
    if (password.len < 3) return false;
    
    for (0..password.len - 2) |i| {
        const c1 = password[i];
        const c2 = password[i + 1];
        const c3 = password[i + 2];
        
        // Check numeric sequences
        if (std.ascii.isDigit(c1) and std.ascii.isDigit(c2) and std.ascii.isDigit(c3)) {
            if (c2 == c1 + 1 and c3 == c2 + 1) return true;
        }
        
        // Check alphabetic sequences
        if (std.ascii.isAlphabetic(c1) and std.ascii.isAlphabetic(c2) and std.ascii.isAlphabetic(c3)) {
            const lower1 = std.ascii.toLower(c1);
            const lower2 = std.ascii.toLower(c2);
            const lower3 = std.ascii.toLower(c3);
            
            if (lower2 == lower1 + 1 and lower3 == lower2 + 1) return true;
        }
    }
    
    return false;
}

/// Format crack time in human-readable format
pub fn formatCrackTime(seconds: f64, allocator: std.mem.Allocator) ![]const u8 {
    if (seconds < 1) return try allocator.dupe(u8, "instantly");
    if (seconds < 60) return try std.fmt.allocPrint(allocator, "{d:.0} seconds", .{seconds});
    if (seconds < 3600) return try std.fmt.allocPrint(allocator, "{d:.0} minutes", .{seconds / 60});
    if (seconds < 86400) return try std.fmt.allocPrint(allocator, "{d:.0} hours", .{seconds / 3600});
    if (seconds < 31536000) return try std.fmt.allocPrint(allocator, "{d:.0} days", .{seconds / 86400});
    if (seconds < 3153600000) return try std.fmt.allocPrint(allocator, "{d:.0} years", .{seconds / 31536000});
    return try allocator.dupe(u8, "centuries");
}
```

---

## Dependencies & Build Configuration

### build.zig.zon

```zig
.{
    .name = .tip,
    .version = "0.1.0",
    .fingerprint = 0x4883b84ca584213a,
    .minimum_zig_version = "0.15.2",
    
    .dependencies = .{
        // CLI argument parsing
        .clap = .{
            .url = "https://github.com/Hejsil/zig-clap/archive/refs/tags/0.10.0.tar.gz",
            .hash = "1220df9b2701c0ced4d5ce38ce18836b47aabd68bb5ec0fb1d8368b700fa5b89f898",
        },
        
        // YAML configuration parsing
        .yaml = .{
            .url = "https://github.com/kubkon/zig-yaml/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "...",
        },
        
        // JWT token handling
        .jwt = .{
            .url = "https://github.com/jonathro/zig-jwt/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "...",
        },
        
        // SQLite bindings (optional)
        .sqlite = .{
            .url = "https://github.com/vrischmann/zig-sqlite/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "...",
        },
        
        // UUID generation
        .uuid = .{
            .url = "https://github.com/r4gus/zig-uuid/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "...",
        },
        
        // Terminal utilities
        .zigline = .{
            .url = "https://github.com/joachimschmidt557/zigline/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "...",
        },
    },
    
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "README.md",
        "LICENSE",
    },
}
```

### build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // Dependencies
    const clap = b.dependency("clap", .{});
    const yaml = b.dependency("yaml", .{});
    const jwt = b.dependency("jwt", .{});
    const sqlite = b.dependency("sqlite", .{});
    const uuid = b.dependency("uuid", .{});
    
    // Create core module
    const core_module = b.addModule("core", .{
        .root_source_file = b.path("src/core/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Create crypto module
    const crypto_module = b.addModule("crypto", .{
        .root_source_file = b.path("src/crypto/master.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // CLI executable
    const cli_exe = b.addExecutable(.{
        .name = "tip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "yaml", .module = yaml.module("yaml") },
                .{ .name = "core", .module = core_module },
                .{ .name = "crypto", .module = crypto_module },
                .{ .name = "uuid", .module = uuid.module("uuid") },
            },
        }),
    });
    
    // Link SQLite
    cli_exe.linkLibC();
    cli_exe.linkSystemLibrary("sqlite3");
    
    b.installArtifact(cli_exe);
    
    // Server executable
    const server_exe = b.addExecutable(.{
        .name = "tip-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "jwt", .module = jwt.module("jwt") },
                .{ .name = "core", .module = core_module },
                .{ .name = "crypto", .module = crypto_module },
            },
        }),
    });
    
    server_exe.linkLibC();
    server_exe.linkSystemLibrary("sqlite3");
    
    b.installArtifact(server_exe);
    
    // Run steps
    const run_cli = b.addRunArtifact(cli_exe);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cli.addArgs(args);
    }
    
    const run_server = b.addRunArtifact(server_exe);
    run_server.step.dependOn(b.getInstallStep());
    
    b.step("run", "Run the CLI").dependOn(&run_cli.step);
    b.step("server", "Run the server").dependOn(&run_server.step);
    
    // Tests — auto-generated test runner lives in the build cache
    // collect_files() walks src/ iteratively, generate_test_runner()
    // uses addWriteFiles() + addCopyDirectory() so no file is written
    // to the source tree and no cleanup step is needed.
    const auto_test_file = generate_test_runner(b, "src") catch |err| {
        std.log.err("Failed to generate test runner: {}", .{err});
        return;
    };

    const all_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = auto_test_file,
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test", "Run all tests").dependOn(&b.addRunArtifact(all_tests).step);
}
```

---

## Testing Strategy

### Unit Testing Pattern

```zig
const std = @import("std");
const testing = std.testing;
const core = @import("../core/types.zig");
const crypto = @import("../crypto/master.zig");

test "Vault creation and lifecycle" {
    const allocator = testing.allocator;
    
    var vault = try core.Vault.init(allocator, "Test Vault", "user123");
    defer vault.deinit();
    
    try testing.expectEqualStrings("Test Vault", vault.name);
    try testing.expect(vault.isLocked());
    
    // Test unlock
    const salt = crypto.generateSalt();
    try vault.unlock("master_password_123", salt);
    try testing.expect(!vault.isLocked());
    
    // Test lock
    vault.lock();
    try testing.expect(vault.isLocked());
}

test "Password encryption and decryption" {
    const allocator = testing.allocator;
    
    var pwd = try core.Password.init(allocator, "vault123", "GitHub");
    defer pwd.deinit();
    
    // Set password
    const key = [_]u8{0x00} ** 32; // Test key
    try pwd.setPassword("my_secret_password", key);
    
    // Verify we can decrypt
    const decrypted = try pwd.getPassword(key, allocator);
    defer allocator.free(decrypted);
    
    try testing.expectEqualStrings("my_secret_password", decrypted);
}

test "Task completion" {
    const allocator = testing.allocator;
    
    var task = try core.Task.init(allocator, "vault123", "Test Task");
    defer task.deinit();
    
    try testing.expectEqual(core.TaskStatus.pending, task.status);
    try testing.expect(task.completed_at == null);
    
    task.complete();
    
    try testing.expectEqual(core.TaskStatus.completed, task.status);
    try testing.expect(task.completed_at != null);
}

test "Password generation" {
    const allocator = testing.allocator;
    const generator = @import("../crypto/generator.zig");
    
    const pwd = try generator.generatePassword(allocator, .{
        .length = 16,
        .include_uppercase = true,
        .include_lowercase = true,
        .include_digits = true,
        .include_symbols = true,
    });
    defer allocator.free(pwd);
    
    try testing.expectEqual(@as(usize, 16), pwd.len);
    
    // Check entropy
    const entropy = generator.calculateEntropy(pwd);
    try testing.expect(entropy > 50); // Should be reasonably strong
}
```

### Integration Testing

```zig
const std = @import("std");
const testing = std.testing;
const json_storage = @import("../storage/json.zig");
const core = @import("../core/types.zig");

test "JSON storage - full workflow" {
    const allocator = testing.allocator;
    
    // Create temp directory
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    const current_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(current_dir);
    
    // Initialize storage
    var storage = try json_storage.JsonStorage.init(allocator, current_dir);
    defer storage.deinit();
    
    // Create vault
    var vault = try core.Vault.init(allocator, "Personal", "user1");
    defer vault.deinit();
    
    try storage.createVault(&vault);
    
    // Retrieve vault
    const retrieved = try storage.getVault(vault.id, allocator);
    defer if (retrieved) |*v| v.deinit();
    
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings(vault.name, retrieved.?.name);
    
    // Create password
    var pwd = try core.Password.init(allocator, vault.id, "GitHub");
    defer pwd.deinit();
    try pwd.setPassword("secret123", [_]u8{0x01} ** 32);
    
    try storage.createPassword(vault.id, &pwd);
    
    // List passwords
    const passwords = try storage.listPasswords(vault.id, allocator);
    defer {
        for (passwords) |*p| p.deinit();
        allocator.free(passwords);
    }
    
    try testing.expectEqual(@as(usize, 1), passwords.len);
}
```

---

## Migration from Go

### Key Differences

| Aspect | Go | Zig |
|--------|-----|-----|
| **Memory Management** | Garbage collected | Manual + allocators |
| **Error Handling** | `if err != nil` | Error unions `!T` |
| **Interfaces** | Structural typing | Comptime duck typing |
| **Generics** | Type parameters | Comptime parameters |
| **Concurrency** | Goroutines + channels | Threads + async/await |
| **JSON** | Reflection-based | Explicit serialization |
| **Testing** | Built-in test runner | `zig test` |
| **Build** | `go build` | `zig build` |

### Migration Checklist

- [ ] **Domain Models**: Convert Go structs to Zig with proper memory management
- [ ] **Error Handling**: Replace Go errors with Zig error unions
- [ ] **JSON Serialization**: Implement custom JSON stringify/parse
- [ ] **Storage Interface**: Convert Go interface to Zig trait pattern
- [ ] **Cryptography**: Use Zig stdlib crypto instead of golang.org/x/crypto
- [ ] **CLI**: Port Cobra commands to zig-clap
- [ ] **HTTP Server**: Convert from Chi router to std.http.Server
- [ ] **Database**: Replace database/sql with direct SQLite bindings
- [ ] **Tests**: Convert testify assertions to std.testing
- [ ] **Configuration**: Replace Viper with custom YAML loader

---

## Summary

This comprehensive guide provides a complete blueprint for implementing Tip in Zig, covering:

1. **5 Implementation Phases** with clear priorities
2. **27 Detailed Tasks** from core to advanced features
3. **20+ Source Files** with code examples
4. **Production-Ready Patterns** for cryptography, storage, and CLI
5. **Testing Strategy** with unit and integration tests
6. **Migration Guide** from Go to Zig

**Estimated Timeline:**
- Phase 1 (Core): 2-3 weeks
- Phase 2 (Storage): 2 weeks
- Phase 3 (CLI): 2-3 weeks
- Phase 4 (Server): 2-3 weeks
- Phase 5 (Advanced): 2 weeks
- **Total: 10-13 weeks** for full implementation

**Key Zig Advantages:**
- Zero-cost abstractions
- Compile-time code generation
- Memory safety without GC
- Single binary deployment
- Cross-compilation support

This architecture maintains feature parity with the Go design while leveraging Zig's unique strengths for systems programming.
