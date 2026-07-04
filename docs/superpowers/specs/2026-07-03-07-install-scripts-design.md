# Install Scripts & Raw-Binary Distribution — Design Spec

**Status:** Draft
**Date:** 2026-07-03
**Related:** [docs/DISTRIBUTION.md](../../DISTRIBUTION.md)

## Problem

`tip` ships prebuilt binaries via GitHub Releases. We want a low-friction
install with two supported paths, and specifically we want macOS users to avoid
the Gatekeeper "unidentified developer" prompt **without** a post-download
command and **without** paying for Apple Developer ID signing/notarization.

An in-progress change wrapped each binary in a per-target folder + `.tar.gz`/
`.zip` archive with a normalized `tip` name. We are reverting that: the project
prefers the simpler "one raw, arch-named executable per platform" layout produced
by the existing `-Dexe-name` build flag.

## Key insight

Files downloaded with `curl`/`wget` are **not** tagged with
`com.apple.quarantine`; only browser downloads (and some apps) set it. A
`curl | sh` installer therefore runs on macOS with no Gatekeeper warning and no
extra user command — no Apple account, no notarization, no macOS CI runner.

## Goals

1. Release assets are raw, arch-named executables plus `checksums.txt` + `LICENSE`.
2. A `curl | sh` installer for macOS/Linux and an `irm | iex` installer for
   Windows, both fetched from raw GitHub.
3. Manual download from the releases page remains fully supported.
4. Installers verify the downloaded binary against `checksums.txt`.

## Non-goals

- Developer ID signing / notarization (`.pkg`/`.dmg`).
- Homebrew tap or any package-manager integration.
- Building on a macOS CI runner (keep cross-compiling on Ubuntu).
- Auto-update / self-update of an installed `tip`.

## Release artifacts (the contract installers depend on)

Published to each GitHub Release (tag `vX.Y.Z`, and `nightly` for prereleases):

```
tip-macos-x86_64
tip-macos-arm64
tip-linux-x86_64
tip-linux-arm64
tip-windows-x86_64.exe
checksums.txt
LICENSE
```

- Binaries are built with `zig build -Dtarget=<t> -Doptimize=ReleaseSafe -Dexe-name=<name>`
  (Linux adds `-Dcpu=baseline`), landing in `zig-out/bin/`.
- `checksums.txt` format is standard `sha256sum` output — one line per asset:
  `<64-hex-hash>  <asset-filename>`.
- Download URL pattern:
  `https://github.com/spikenardco/tip/releases/download/<tag>/<asset>`

## Installer behavior (macOS/Linux — `install.sh`)

**Invocation:**
```bash
curl -fsSL https://raw.githubusercontent.com/spikenardco/tip/main/scripts/install.sh | sh
```

**Steps:**
1. Detect OS via `uname -s` (`Linux`→`linux`, `Darwin`→`macos`; anything else is
   a hard error pointing users to the Windows installer / manual download).
2. Detect arch via `uname -m` (`x86_64`/`amd64`→`x86_64`, `aarch64`/`arm64`→`arm64`;
   otherwise hard error).
3. Resolve version: use `$TIP_VERSION` if set; otherwise query
   `https://api.github.com/repos/spikenardco/tip/releases/latest` and parse
   `tag_name`.
4. Compose asset name `tip-<os>-<arch>` and download it + `checksums.txt` to a
   temp dir.
5. Verify: compute sha256 of the binary and compare to the matching line in
   `checksums.txt`. Mismatch is a hard error (delete temp, exit non-zero).
6. Install: `chmod +x` and move the binary to the install dir as `tip`.
7. Warn if the install dir is not on `PATH`.

**Install location (the "common choice"):**
- Default `~/.local/bin`, created if missing, no `sudo`.
- Fallback to `/usr/local/bin` using `sudo` only when `~/.local/bin` cannot be
  created/written.
- Override with `$TIP_INSTALL_DIR`.

**Environment overrides:**
- `TIP_VERSION` — install a specific tag (e.g. `v1.2.3`) instead of latest.
- `TIP_INSTALL_DIR` — target directory.
- `TIP_BASE_URL` / `TIP_API_URL` — override download/API roots (mirrors + tests).

**Dependencies:** `curl`, and one of `sha256sum` (Linux) or `shasum` (macOS).
Missing required tools are a hard error.

**Robustness:** `set -eu`, POSIX `sh` (no bashisms), temp dir cleaned via `trap`
on exit, all failures print a clear `error:` line and exit non-zero.

## Installer behavior (Windows — `install.ps1`)

**Invocation:**
```powershell
irm https://raw.githubusercontent.com/spikenardco/tip/main/scripts/install.ps1 | iex
```

- `$ErrorActionPreference = 'Stop'`.
- Version: `$env:TIP_VERSION` or `tag_name` from the GitHub API.
- Asset: `tip-windows-x86_64.exe`, downloaded via `Invoke-WebRequest`.
- Verify sha256 via `Get-FileHash` against `checksums.txt`; mismatch throws.
- Install dir: `$env:TIP_INSTALL_DIR` or `$env:LOCALAPPDATA\tip\bin`, created if
  missing; installed as `tip.exe`.
- Warn (don't fail) if the dir is not on the user `PATH`.
- Same `TIP_BASE_URL`/`TIP_API_URL` overrides.

## Documentation

- `README.md`: replace the archive-oriented "Download a release" copy with
  (a) a "Quick install" block containing both one-liners, and (b) a
  "Manual download" block naming the raw arch binaries, keeping the macOS
  `xattr -d com.apple.quarantine` note for browser downloads only.
- `docs/DISTRIBUTION.md`: tick the To-do checkboxes as items land.

## Verification strategy

Shell/PowerShell aren't covered by the Zig test suite, so:
- `install.sh`: `sh -n` (syntax) + `shellcheck` (lint) + a local smoke test that
  serves a fake binary and matching `checksums.txt` over `python3 -m http.server`,
  driven with `TIP_BASE_URL`/`TIP_API_URL`/`TIP_VERSION`/`TIP_INSTALL_DIR`.
- `install.ps1`: `PSScriptAnalyzer` if available; otherwise a syntax parse check.
- Workflows: confirm the reverted YAML matches the pre-packaging layout and the
  `files:` lists reference raw assets.

## Risks / edge cases

- **GitHub API rate limits** on unauthenticated `releases/latest`. Mitigation:
  `TIP_VERSION` bypasses the API entirely; document it.
- **macOS sha tool differences** (`shasum -a 256` vs `sha256sum`). Handled by
  probing for both.
- **`~/.local/bin` not on PATH** on fresh systems. We warn with the exact line to
  add; we do not edit shell profiles.
- **Old-format archive assets** in the current README/diff must be removed so the
  installers and docs agree on raw-binary names.
