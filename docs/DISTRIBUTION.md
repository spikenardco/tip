# Distribution & Install

How `tip` binaries are built, published, and installed. This is a design note
capturing the decisions behind the release workflows and install scripts.

## Decisions

### Ship raw, arch-named binaries (not folder/archive bundles)

Each release publishes a flat set of executables, named by target using the
`-Dexe-name` build flag:

```
tip-macos-x86_64
tip-macos-arm64
tip-linux-x86_64
tip-linux-arm64
tip-windows-x86_64.exe
checksums.txt
LICENSE
```

We deliberately do **not** wrap each binary in a per-target folder + `.tar.gz`/
`.zip` with a normalized `tip` name. The rename-via-flag approach is simpler:
one file per platform, no extraction step, and the install script can `curl` a
binary directly.

### Two ways to install, user's choice

1. **Install script (recommended).** A `curl | sh` one-liner for macOS/Linux and
   an `irm | iex` one-liner for Windows. The script detects OS + arch, downloads
   the matching binary, verifies its checksum, and puts `tip` on `PATH`.
2. **Manual download.** Users can grab any binary straight from the
   [releases page](https://github.com/spikenardco/tip/releases) and run it.

### Why the install script sidesteps macOS Gatekeeper

Files downloaded via `curl`/`wget` are **not** tagged with
`com.apple.quarantine` — only browser downloads (and some apps) set that flag.
So a script-based install runs with no Gatekeeper warning and **no post-install
command**, with no Apple Developer account and no notarization.

Manual browser downloads still carry quarantine. Those users either right-click
→ Open once, or clear the flag:

```bash
xattr -d com.apple.quarantine ./tip-macos-arm64
```

We are **not** doing Developer ID signing + notarization (would cost $99/yr and
require a macOS CI runner). The script path covers the frictionless case; manual
download remains available for anyone who wants the raw file.

## Scripts location

The install scripts live in the repo's [`scripts/`](../scripts) folder and are
fetched directly from raw GitHub by the install one-liners — no build step, no
separate hosting:

```
scripts/
  install.sh    # macOS / Linux (curl | sh)
  install.ps1   # Windows (irm | iex)
```

Because `curl` pulls them straight from `main`, whatever is on `main` is what
users run. Keep these scripts self-contained and backward-compatible.

## Checksums

With raw arch-named binaries, `checksums.txt` hashes the **executables**
themselves, not archives:

```
sha256sum tip-macos-x86_64 tip-macos-arm64 tip-linux-x86_64 tip-linux-arm64 tip-windows-x86_64.exe > checksums.txt
```

The install script verifies the downloaded binary against this file before
placing it on `PATH`. (This restores the pre-packaging behavior; the folder +
`.tar.gz`/`.zip` step hashed archive files instead.)

## Install script behavior

- **Source:** served from raw GitHub, no separate domain:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/spikenardco/tip/main/scripts/install.sh | sh
  ```
- **Install location:** defaults to `~/.local/bin` (no `sudo`); falls back to
  `/usr/local/bin` with `sudo` when `~/.local/bin` is unavailable. Warns if the
  chosen directory is not on `PATH`.
- **Version:** installs the latest release by default; override with
  `TIP_VERSION=v1.2.3`.
- **Integrity:** verifies the downloaded binary against `checksums.txt` before
  installing.

## To do

- [x] Revert release/prerelease workflows to publish raw arch-named binaries
      (drop the folder + tar/zip packaging step).
- [x] Add `scripts/install.sh` (macOS/Linux).
- [x] Add `scripts/install.ps1` (Windows).
- [x] Update README with the quick-install one-liners + manual-download section.
