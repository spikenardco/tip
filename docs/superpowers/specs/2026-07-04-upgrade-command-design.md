# `tip upgrade` — Self-Update Command — Design Spec

**Status:** Draft
**Date:** 2026-07-04
**Depends on:** [2026-07-03-07-install-scripts-design.md](./2026-07-03-07-install-scripts-design.md)

## Problem

`tip` is distributed as prebuilt binaries via GitHub Releases. There is currently
no way to update an installed binary short of manually downloading or re-running
the install script. Users need `tip upgrade` to check for and apply updates.

## Goals

1. `tip upgrade` checks for a newer stable release and installs it.
2. Version is compared **before** downloading — no unnecessary bandwidth.
3. No external dependencies beyond what Zig 0.16 stdlib provides.
4. No dependency on the GitHub API (avoids rate limits).
5. Downloaded binary is verified against `checksums.txt` before replacing.
6. Works on Linux, macOS, and Windows.

## Non-goals

- Auto-update checks on every invocation (only explicit `tip upgrade`).
- Nightly/prerelease tracking (stable releases only).
- Rolling back to a previous version.
- Package-manager integration (Homebrew, apt, etc.).

## Approach

Use a **HEAD request** with redirect inspection against the GitHub CDN:

1. HEAD the platform-specific latest download URL.
2. Follow the redirect manually — the final URL contains the release tag.
3. Parse the tag from the URL path.
4. Compare against the compiled-in version.
5. If newer: download binary + checksums.txt from the tag-specific URLs, verify,
   replace.
6. If same: print "Already up-to-date" and exit cleanly.

This avoids the GitHub API entirely (no rate limits) while still checking the
version before downloading.

## Release artifact contract

`tip upgrade` assumes the same asset layout from the install-scripts design:

```
https://github.com/spikenardco/tip/releases/latest/download/tip-{os}-{arch}
  → redirects to:
  https://github.com/spikenardco/tip/releases/download/{tag}/tip-{os}-{arch}
```

`checksums.txt` lives alongside the asset:
```
https://github.com/spikenardco/tip/releases/download/{tag}/checksums.txt
```

Format: `<64-hex-sha256>  <asset-filename>`.

## Detailed flow

### 1. Detect platform

Same logic as `scripts/install.sh`:

| `uname -s` | OS value    | `uname -m`      | Arch value |
|------------|-------------|-----------------|------------|
| `Linux`    | `linux`     | `x86_64`/`amd64`| `x86_64`   |
| `Darwin`   | `macos`     | `aarch64`/`arm64`| `arm64`    |
| Windows    | `windows`   | (compile-time)  | `x86_64`   |

Compose asset name: `tip-{os}-{arch}` (`.exe` suffix for Windows).

### 2. Resolve latest version via HEAD + redirect

```
HEAD /spikenardco/tip/releases/latest/download/tip-{os}-{arch}
Host: github.com
```

`std.http.Client` with `redirect_behavior = .unhandled` returns the first 302
response without following further redirects. Read the `Location` header (e.g.
`/spikenardco/tip/releases/download/v0.2.0/tip-linux-x86_64`).

The first redirect goes from the "latest" alias to the versioned URL; we do not
follow the second redirect (to the CDN). Extract the tag from the URL path:
the segment immediately after `/download/`.

### 3. Compare versions

Compare the extracted tag (e.g. `v0.2.0`) with the compiled-in version
(`@import("version").version`).

Use `std.SemanticVersion.parse` for proper semver comparison (strip leading `v`).

### 4. Download + verify

If newer:

1. Download binary from the resolved URL (the one from the Location header).
2. Download `checksums.txt` from `../../releases/download/{tag}/checksums.txt`.
3. Compute SHA-256 of downloaded binary.
4. Find matching line in checksums.txt and compare.
5. On mismatch: delete temp files, print error, exit non-zero.

### 5. Replace binary

**Linux/macOS:**
1. Determine current binary directory via `std.process.executableDirPath`.
2. Write downloaded binary to a temp file in the same directory.
3. `chmod +x` the temp file.
4. Rename temp file over the current binary using `std.Io.File.rename`.

**Windows:**
1. Determine current binary directory.
2. Write downloaded binary to `<exe-dir>/tip.new.exe`.
3. Write a `.bat` script that loops until `tip.exe` is no longer locked,
   renames `tip.new.exe` → `tip.exe`, then deletes itself.
4. Spawn the `.bat` and exit the current process.

### 6. Output

| Scenario | Message |
|----------|---------|
| Already up-to-date | `tip is already up-to-date (v0.1.0)` |
| Updated | `Updated tip from v0.1.0 to v0.2.0` |
| No release found | `No releases found.` |
| Network error | `Could not reach GitHub. Check your connection.` |
| Checksum mismatch | `Download corrupted. Checksum mismatch.` |
| Permission denied | `Cannot write to {path}. Try with sudo or move tip to a writable directory.` |

## Implementation

### New file: `src/upgrade.zig`

```
fn detectPlatform(allocator) OS, Arch
fn resolveLatestVersion(client, os, arch) !?[]const u8  // HEAD + redirect
fn versionCompare(current, latest) enum { newer, same }
fn downloadAndVerify(client, tag, os, arch, temp_dir) !void
fn replaceBinary(temp_path, exe_path) !void
pub fn upgrade(io, allocator, environ, current_version) !void
```

### Changes to `src/main.zig`

Add `upgrade: bool = false` to the `Args` struct:

```zig
const Args = struct {
    command: union(enum) {
        task: task.TaskArgs,
        upgrade,
    },
```

Dispatch in the main switch:
```zig
.upgrade => try upgrade.upgrade(init.io, init.arena.allocator(), init.minimal.environ, version_mod.version),
```

### No changes to `build.zig`

The version string is already injected at build time via the `version` module.

## Error handling

- All network errors produce a user-friendly message, not a stack trace.
- Partial downloads (connection drop mid-download) are detected and cleaned up.
- If the binary replacement fails (e.g. permission denied), the temp file is
  preserved with a message telling the user where it is.

## Risks and edge cases

- **Symlinked installations:** `executablePath` follows symlinks, so if `tip` is
  installed via a symlink in `~/.local/bin` pointing elsewhere, the replacement
  targets the real file. This is correct behavior.
- **Binary deleted while running:** `executablePath` may return a path with
  " (deleted)" suffix on Linux. We should detect this and error out.
- **Permission denied on rename:** If tip is installed in `/usr/local/bin` without
  write access, the rename will fail. We print a message suggesting `sudo`.
- **Windows file locking:** The running `.exe` cannot be renamed/deleted. The
  `.bat` helper works around this by retrying in a loop.
- **No checksums.txt for the release:** If checksums.txt is missing, we skip
  verification and print a warning.
- **HEAD request returns non-302:** If the download URL returns 200 (no redirect),
  there's no tag to parse. We print an error and exit — we never download a
  binary just to discover its version.

## Testing

- Unit tests for `versionCompare`: same version, newer, older, invalid strings.
- Unit tests for `detectPlatform`: verify mapping.
- Test for GitHub redirect URL parsing: extract tag from various URL shapes.
- Integration test (manual): run `tip upgrade` against a test release.
