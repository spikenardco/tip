# Install Scripts & Raw-Binary Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship raw, arch-named release binaries plus `curl | sh` / `irm | iex` installers that verify checksums and install `tip` on `PATH`, while keeping manual download working.

**Architecture:** Revert the release/prerelease workflows to publish flat, arch-named executables (via the existing `-Dexe-name` flag) with a `checksums.txt` that hashes the executables. Add two self-contained installer scripts under `scripts/` that detect OS/arch, resolve the release version, download + checksum-verify the binary, and drop it into an install dir. Update README + `docs/DISTRIBUTION.md`.

**Tech Stack:** GitHub Actions (`softprops/action-gh-release@v3`), Zig build, POSIX `sh`, PowerShell, `shellcheck`.

## Global Constraints

- Repo slug: `spikenardco/tip`. Default branch: `main`.
- Release asset names (exact): `tip-macos-x86_64`, `tip-macos-arm64`, `tip-linux-x86_64`, `tip-linux-arm64`, `tip-windows-x86_64.exe`, plus `checksums.txt` and `LICENSE`.
- Download URL: `https://github.com/spikenardco/tip/releases/download/<tag>/<asset>`.
- Latest-version API: `https://api.github.com/repos/spikenardco/tip/releases/latest` → `tag_name`.
- `checksums.txt` is standard `sha256sum` output: `<64-hex>  <asset>`.
- Installer env overrides: `TIP_VERSION`, `TIP_INSTALL_DIR`, `TIP_BASE_URL`, `TIP_API_URL`.
- `install.sh` MUST be POSIX `sh` (no bashisms) and pass `shellcheck`.
- Default install dir: `~/.local/bin` (no sudo), fallback `/usr/local/bin` (sudo).
- No signing/notarization, no Homebrew, no macOS CI runner.

---

## File Structure

- `.github/workflows/release.yml` — publish raw binaries on `v*` tags (revert packaging).
- `.github/workflows/prerelease.yml` — same for the `nightly` prerelease on `main`.
- `scripts/install.sh` — macOS/Linux installer.
- `scripts/install.ps1` — Windows installer.
- `scripts/test-install.sh` — local smoke test harness for `install.sh` (dev-only).
- `README.md` — Quick install + Manual download sections.
- `docs/DISTRIBUTION.md` — tick To-do checkboxes.

---

## Task 1: Revert workflows to raw arch-named binaries

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `.github/workflows/prerelease.yml`

**Interfaces:**
- Produces: release assets `tip-<os>-<arch>[.exe]`, `checksums.txt`, `LICENSE` at the URL pattern in Global Constraints. The installer tasks consume these names.

- [ ] **Step 1: Replace the `Package` step with a `Generate checksums` step in `release.yml`**

Find the step that begins with `- name: Package` (the block that makes `dist/`, tars, and zips) and replace the entire step with:

```yaml
      - name: Generate checksums
        run: |
          cd ./zig-out/bin
          sha256sum tip-windows-x86_64.exe tip-macos-x86_64 tip-macos-arm64 tip-linux-x86_64 tip-linux-arm64 > checksums.txt
```

- [ ] **Step 2: Fix the `files:` list in the `Create release` step of `release.yml`**

Replace the `files: |` block with the raw-asset list:

```yaml
          files: |
            ./zig-out/bin/tip-windows-x86_64.exe
            ./zig-out/bin/tip-macos-x86_64
            ./zig-out/bin/tip-macos-arm64
            ./zig-out/bin/tip-linux-x86_64
            ./zig-out/bin/tip-linux-arm64
            ./zig-out/bin/checksums.txt
            LICENSE
```

- [ ] **Step 3: Apply the same two replacements in `prerelease.yml`**

Replace its `- name: Package` step with the identical `Generate checksums` step from Step 1, and replace its `files: |` block (in the `Create prerelease` step) with the identical list from Step 2.

- [ ] **Step 4: Verify both workflows are valid YAML and match the pre-packaging shape**

Run:
```bash
python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in ['.github/workflows/release.yml','.github/workflows/prerelease.yml']]; print('yaml ok')"
git diff HEAD -- .github/workflows/release.yml .github/workflows/prerelease.yml
```
Expected: prints `yaml ok`, and the diff against `HEAD` is empty for both files (this task restores them to the committed pre-packaging version).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml .github/workflows/prerelease.yml
git commit -m "ci: publish raw arch-named binaries instead of archives"
```

---

## Task 2: macOS/Linux installer (`scripts/install.sh`)

**Files:**
- Create: `scripts/install.sh`
- Create: `scripts/test-install.sh`

**Interfaces:**
- Consumes: release assets from Task 1.
- Produces: an executable `tip` in the install dir. No other task depends on its internals.

- [ ] **Step 1: Write the smoke test harness `scripts/test-install.sh`**

This is the failing test — it serves a fake release locally and runs `install.sh` against it.

```sh
#!/bin/sh
# Local smoke test for install.sh. Serves a fake release over HTTP and installs it.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"; [ -n "${srv_pid:-}" ] && kill "$srv_pid" 2>/dev/null || true' EXIT

os=$(uname -s); case "$os" in Linux) o=linux ;; Darwin) o=macos ;; *) echo "unsupported"; exit 1 ;; esac
arch=$(uname -m); case "$arch" in x86_64|amd64) a=x86_64 ;; aarch64|arm64) a=arm64 ;; *) echo "unsupported"; exit 1 ;; esac
asset="tip-$o-$a"

# Fake release tree: <work>/download/v9.9.9/<asset> and checksums.txt
rel="$work/download/v9.9.9"
mkdir -p "$rel"
printf '#!/bin/sh\necho fake-tip 9.9.9\n' > "$rel/$asset"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$rel" && sha256sum "$asset" > checksums.txt)
else
  (cd "$rel" && shasum -a 256 "$asset" > checksums.txt)
fi

# Serve <work> so /download/v9.9.9/<asset> resolves.
( cd "$work" && python3 -m http.server 8765 >/dev/null 2>&1 ) &
srv_pid=$!
sleep 1

dest="$work/bin"
TIP_VERSION=v9.9.9 \
TIP_BASE_URL="http://127.0.0.1:8765/download" \
TIP_INSTALL_DIR="$dest" \
  sh "$here/install.sh"

# Assertions.
[ -x "$dest/tip" ] || { echo "FAIL: tip not installed/executable"; exit 1; }
out=$("$dest/tip"); [ "$out" = "fake-tip 9.9.9" ] || { echo "FAIL: bad output: $out"; exit 1; }
echo "PASS: install.sh smoke test"
```

- [ ] **Step 2: Run the harness to verify it fails (no installer yet)**

Run:
```bash
chmod +x scripts/test-install.sh
sh scripts/test-install.sh
```
Expected: FAIL — `install.sh` does not exist yet, so `sh: .../install.sh: No such file or directory`.

- [ ] **Step 3: Write `scripts/install.sh`**

```sh
#!/bin/sh
# tip installer for macOS and Linux.
#   curl -fsSL https://raw.githubusercontent.com/spikenardco/tip/main/scripts/install.sh | sh
# Env overrides: TIP_VERSION, TIP_INSTALL_DIR, TIP_BASE_URL, TIP_API_URL
set -eu

REPO="spikenardco/tip"
BASE_URL="${TIP_BASE_URL:-https://github.com/${REPO}/releases/download}"
API_URL="${TIP_API_URL:-https://api.github.com/repos/${REPO}/releases/latest}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$1" >&2; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || err "required command not found: $1"; }

detect_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo macos ;;
    *) err "unsupported OS: $(uname -s). Use the Windows installer or download manually." ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo arm64 ;;
    *) err "unsupported architecture: $(uname -m)" ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    err "need sha256sum or shasum to verify the download"
  fi
}

resolve_version() {
  if [ -n "${TIP_VERSION:-}" ]; then
    echo "$TIP_VERSION"
    return
  fi
  tag=$(curl -fsSL "$API_URL" \
    | grep '"tag_name"' | head -n1 \
    | sed -E 's/.*"tag_name" *: *"([^"]+)".*/\1/')
  [ -n "$tag" ] || err "could not determine latest version; set TIP_VERSION"
  echo "$tag"
}

choose_dir() {
  if [ -n "${TIP_INSTALL_DIR:-}" ]; then
    echo "$TIP_INSTALL_DIR"
  else
    echo "$HOME/.local/bin"
  fi
}

main() {
  need curl
  os=$(detect_os)
  arch=$(detect_arch)
  asset="tip-${os}-${arch}"
  version=$(resolve_version)

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  info "Installing tip ${version} (${asset})"
  curl -fsSL "${BASE_URL}/${version}/${asset}" -o "$tmp/tip" \
    || err "download failed: ${BASE_URL}/${version}/${asset}"
  curl -fsSL "${BASE_URL}/${version}/checksums.txt" -o "$tmp/checksums.txt" \
    || err "could not fetch checksums.txt"

  expected=$(grep " ${asset}\$" "$tmp/checksums.txt" | awk '{print $1}')
  [ -n "$expected" ] || err "no checksum for ${asset} in checksums.txt"
  actual=$(sha256_of "$tmp/tip")
  [ "$expected" = "$actual" ] || err "checksum mismatch for ${asset} (expected ${expected}, got ${actual})"
  info "Checksum verified"

  dir=$(choose_dir)
  chmod +x "$tmp/tip"
  if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then
    mv "$tmp/tip" "$dir/tip"
  else
    warn "cannot write to ${dir}; falling back to /usr/local/bin (sudo)"
    dir=/usr/local/bin
    sudo mkdir -p "$dir"
    sudo mv "$tmp/tip" "$dir/tip"
  fi

  info "Installed tip to ${dir}/tip"
  case ":${PATH}:" in
    *":${dir}:"*) ;;
    *) warn "${dir} is not on your PATH. Add it, e.g.: export PATH=\"${dir}:\$PATH\"" ;;
  esac
}

main "$@"
```

- [ ] **Step 4: Lint and run the smoke test to verify it passes**

Run:
```bash
sh -n scripts/install.sh
shellcheck scripts/install.sh
sh scripts/test-install.sh
```
Expected: `sh -n` silent (valid syntax), `shellcheck` reports no warnings, and the smoke test prints `PASS: install.sh smoke test`. (If `shellcheck` is not installed, install it or note it was skipped.)

- [ ] **Step 5: Make executable and commit**

```bash
chmod +x scripts/install.sh scripts/test-install.sh
git add scripts/install.sh scripts/test-install.sh
git commit -m "feat: add curl|sh installer for macOS and Linux"
```

---

## Task 3: Windows installer (`scripts/install.ps1`)

**Files:**
- Create: `scripts/install.ps1`

**Interfaces:**
- Consumes: `tip-windows-x86_64.exe` + `checksums.txt` from Task 1.
- Produces: `tip.exe` in the install dir.

- [ ] **Step 1: Write `scripts/install.ps1`**

```powershell
# tip installer for Windows.
#   irm https://raw.githubusercontent.com/spikenardco/tip/main/scripts/install.ps1 | iex
# Env overrides: TIP_VERSION, TIP_INSTALL_DIR, TIP_BASE_URL, TIP_API_URL
$ErrorActionPreference = 'Stop'

$Repo    = 'spikenardco/tip'
$BaseUrl = if ($env:TIP_BASE_URL) { $env:TIP_BASE_URL } else { "https://github.com/$Repo/releases/download" }
$ApiUrl  = if ($env:TIP_API_URL)  { $env:TIP_API_URL }  else { "https://api.github.com/repos/$Repo/releases/latest" }
$Asset   = 'tip-windows-x86_64.exe'

$Version = if ($env:TIP_VERSION) {
    $env:TIP_VERSION
} else {
    (Invoke-RestMethod -Uri $ApiUrl -Headers @{ 'User-Agent' = 'tip-installer' }).tag_name
}
if (-not $Version) { throw 'could not determine version; set TIP_VERSION' }

$Dir = if ($env:TIP_INSTALL_DIR) { $env:TIP_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'tip\bin' }
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
try {
    Write-Host "==> Installing tip $Version ($Asset)"
    $binPath = Join-Path $Tmp 'tip.exe'
    Invoke-WebRequest -Uri "$BaseUrl/$Version/$Asset" -OutFile $binPath
    $sumPath = Join-Path $Tmp 'checksums.txt'
    Invoke-WebRequest -Uri "$BaseUrl/$Version/checksums.txt" -OutFile $sumPath

    $line = Get-Content $sumPath | Where-Object { $_ -match [regex]::Escape($Asset) } | Select-Object -First 1
    if (-not $line) { throw "no checksum for $Asset in checksums.txt" }
    $expected = ($line -split '\s+')[0].ToLower()
    $actual   = (Get-FileHash -Algorithm SHA256 $binPath).Hash.ToLower()
    if ($expected -ne $actual) { throw "checksum mismatch (expected $expected, got $actual)" }
    Write-Host '==> Checksum verified'

    Copy-Item -Force $binPath (Join-Path $Dir 'tip.exe')
    Write-Host "==> Installed tip to $Dir\tip.exe"

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$Dir*") {
        Write-Warning "$Dir is not on your PATH. Add it via: setx PATH `"$Dir;`$env:PATH`""
    }
} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2: Verify the script parses**

Run (on any machine with PowerShell; skip with a note if unavailable):
```bash
pwsh -NoProfile -Command "\$null = [System.Management.Automation.Language.Parser]::ParseFile('scripts/install.ps1', [ref]\$null, [ref]\$null); Write-Host 'parse ok'"
```
Expected: prints `parse ok`. If `PSScriptAnalyzer` is present, also run `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer scripts/install.ps1"` and expect no errors.

- [ ] **Step 3: Commit**

```bash
git add scripts/install.ps1
git commit -m "feat: add PowerShell installer for Windows"
```

---

## Task 4: README install docs

**Files:**
- Modify: `README.md` (the "Download a release" section added in the working tree)

**Interfaces:**
- Consumes: installer one-liners (Tasks 2–3) and raw asset names (Task 1).

- [ ] **Step 1: Replace the archive-based "Download a release" section**

Find the current `### Download a release` block (it references `.tar.gz`/`.zip`) and replace everything from `### Download a release` up to (but not including) `### Build from source` with:

```markdown
### Quick install

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/spikenardco/tip/main/scripts/install.sh | sh
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/spikenardco/tip/main/scripts/install.ps1 | iex
```

The installer downloads the right binary for your platform, verifies its
checksum, and installs `tip` to `~/.local/bin` (macOS/Linux) or
`%LOCALAPPDATA%\tip\bin` (Windows). Set `TIP_VERSION=vX.Y.Z` to pin a version.

### Manual download

Grab the binary for your platform from the
[releases page](https://github.com/spikenardco/tip/releases):

| Platform | File |
| --- | --- |
| macOS (Apple Silicon) | `tip-macos-arm64` |
| macOS (Intel) | `tip-macos-x86_64` |
| Linux (x86_64) | `tip-linux-x86_64` |
| Linux (ARM64) | `tip-linux-arm64` |
| Windows (x86_64) | `tip-windows-x86_64.exe` |

Make it executable and run it:

```bash
chmod +x tip-macos-arm64
./tip-macos-arm64 --version
```

Verify a download against `checksums.txt`:

```bash
sha256sum -c checksums.txt      # or: shasum -a 256 -c checksums.txt
```

#### macOS: browser downloads only

If you download the binary in a **browser**, macOS may show an "unidentified
developer" warning. Either right-click the binary → **Open** once, or clear the
quarantine flag:

```bash
xattr -d com.apple.quarantine ./tip-macos-arm64
```

The quick-install script above avoids this entirely — files fetched with `curl`
are not quarantined.
```

- [ ] **Step 2: Verify the README references no archive names**

Run:
```bash
grep -nE "tar\.gz|\.zip|dist/" README.md || echo "no archive references"
```
Expected: prints `no archive references`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document quick-install scripts and manual download"
```

---

## Task 5: Close out the distribution note

**Files:**
- Modify: `docs/DISTRIBUTION.md`

**Interfaces:**
- Consumes: completion state of Tasks 1–4.

- [ ] **Step 1: Tick the To-do checkboxes**

In the `## To do` section, change each `- [ ]` to `- [x]` for the four completed items (revert workflows, add `install.sh`, add `install.ps1`, update README).

- [ ] **Step 2: Verify no unchecked boxes remain**

Run:
```bash
grep -n "\- \[ \]" docs/DISTRIBUTION.md || echo "all done"
```
Expected: prints `all done`.

- [ ] **Step 3: Commit**

```bash
git add docs/DISTRIBUTION.md
git commit -m "docs: mark distribution to-do complete"
```

---

## Self-Review

**Spec coverage:**
- Raw arch-named assets + checksums → Task 1. ✓
- `curl | sh` installer w/ detect, version resolve, checksum verify, install dir, PATH warn → Task 2. ✓
- `irm | iex` Windows installer → Task 3. ✓
- Manual download preserved + macOS xattr note (browser-only) → Task 4. ✓
- Env overrides `TIP_VERSION`/`TIP_INSTALL_DIR`/`TIP_BASE_URL`/`TIP_API_URL` → Tasks 2–3. ✓
- Verification (shellcheck, smoke test, ps parse, yaml, README grep) → each task's verify step. ✓
- Non-goals (signing, Homebrew, macOS runner) → not introduced. ✓

**Placeholder scan:** No TBD/TODO; all scripts and YAML shown in full.

**Type/name consistency:** Asset names, URL pattern (`.../releases/download/<tag>/<asset>`), and env var names are identical across the spec, workflows, `install.sh`, `install.ps1`, and README. `checksums.txt` parsing matches the `sha256sum` output format produced in Task 1.
