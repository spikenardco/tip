#!/bin/sh
# tip installer - macOS, Linux, Windows (Git Bash/MSYS2/Cygwin)
#   curl -fsSL https://raw.githubusercontent.com/spikenardco/tip/main/scripts/install.sh | sh
#   or: wget -qO- https://raw.githubusercontent.com/spikenardco/tip/main/scripts/install.sh | sh
# Env overrides: TIP_VERSION, TIP_INSTALL_DIR, TIP_BASE_URL, TIP_API_URL
set -eu

REPO="spikenardco/tip"
BASE_URL="${TIP_BASE_URL:-https://github.com/${REPO}/releases/download}"
API_URL="${TIP_API_URL:-https://api.github.com/repos/${REPO}/releases/latest}"

if [ -t 2 ]; then
  info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
  warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$1" >&2; }
  err()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }
else
  info() { printf '==> %s\n' "$1"; }
  warn() { printf 'warning: %s\n' "$1" >&2; }
  err()  { printf 'error: %s\n' "$1" >&2; exit 1; }
fi

# --- Download helpers ---

download() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    set -- -fsSL --connect-timeout 30 --max-time 300 \
      --retry 3 --retry-delay 2
    case "$url" in
      https://*) set -- "$@" --proto '=https' --tlsv1.2 ;;
    esac
    curl "$@" "$url" -o "$out" || return 1
  elif command -v wget >/dev/null 2>&1; then
    set -- -qO "$out" --timeout=30 --dns-timeout=30 --connect-timeout=30
    case "$url" in
      https://*) set -- "$@" --https-only --secure-protocol=TLSv1_2 ;;
    esac
    wget "$@" "$url" || return 1
  else
    err "need curl or wget"
  fi
}

fetch() {
  url="$1"
  if command -v curl >/dev/null 2>&1; then
    set -- -fsSL --connect-timeout 30 --max-time 30 \
      --retry 2 --retry-delay 2
    case "$url" in
      https://*) set -- "$@" --proto '=https' --tlsv1.2 ;;
    esac
    curl "$@" "$url" || return 1
  elif command -v wget >/dev/null 2>&1; then
    set -- -qO- --timeout=30
    case "$url" in
      https://*) set -- "$@" --https-only --secure-protocol=TLSv1_2 ;;
    esac
    wget "$@" "$url" || return 1
  else
    err "need curl or wget"
  fi
}

# --- Platform detection ---

detect_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo macos ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) err "unsupported OS: $(uname -s). Use the Windows PowerShell installer or download manually." ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo arm64 ;;
    *) err "unsupported architecture: $(uname -m)" ;;
  esac
}

# --- Checksum ---

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    err "need sha256sum or shasum to verify the download"
  fi
}

# --- Version resolution ---

resolve_version() {
  if [ -n "${TIP_VERSION:-}" ]; then
    echo "$TIP_VERSION"
    return
  fi
  resp=$(fetch "$API_URL") || {
    err "could not determine latest version from GitHub API (rate limit?); set TIP_VERSION to bypass"
  }
  tag=$(echo "$resp" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
  if [ -z "$tag" ]; then
    err "could not determine latest version from GitHub API; set TIP_VERSION"
  fi
  echo "$tag"
}

# --- Install dir ---

choose_dir() {
  if [ -n "${TIP_INSTALL_DIR:-}" ]; then
    echo "$TIP_INSTALL_DIR"
    return
  fi
  case "${1:-}" in
    windows) echo "$HOME/AppData/Local/tip/bin" ;;
    *) echo "$HOME/.local/bin" ;;
  esac
}

# --- Main ---

main() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || err "need curl or wget"

  umask 077

  tmpdir="${TMPDIR:-/tmp}"
  tmp=$(mktemp -d "${tmpdir}/tip.XXXXXXXX") || err "failed to create temp dir"
  trap 'rm -rf "$tmp"' EXIT INT TERM

  os=$(detect_os)
  arch=$(detect_arch)
  asset="tip-${os}-${arch}"
  case "$os" in
    windows) asset="${asset}.exe" ;;
  esac
  version=$(resolve_version)

  info "Installing tip ${version} (${asset})"
  download "${BASE_URL}/${version}/${asset}" "$tmp/tip" \
    || err "download failed: ${BASE_URL}/${version}/${asset}"
  download "${BASE_URL}/${version}/checksums.txt" "$tmp/checksums.txt" \
    || err "could not fetch checksums.txt"

  expected=$(grep -F " ${asset}" "$tmp/checksums.txt" | awk '{print $1}')
  [ -n "$expected" ] || err "no checksum for ${asset} in checksums.txt"
  actual=$(sha256_of "$tmp/tip")
  [ "$expected" = "$actual" ] || err "checksum mismatch for ${asset} (expected ${expected}, got ${actual})"
  info "Checksum verified (integrity check; release authenticity not verified without GPG)"

  if command -v gpg >/dev/null 2>&1; then
    sig_url="${BASE_URL}/${version}/checksums.txt.sig"
    if download "$sig_url" "$tmp/checksums.txt.sig" 2>/dev/null; then
      if gpg --verify "$tmp/checksums.txt.sig" "$tmp/checksums.txt" 2>/dev/null; then
        info "GPG signature verified"
      else
        err "GPG signature verification failed for checksums.txt"
      fi
    fi
  fi

  dir=$(choose_dir "$os")
  if ! mkdir -p "$dir" 2>/dev/null && [ ! -d "$dir" ]; then
    err "cannot create directory ${dir}. Set TIP_INSTALL_DIR to a writable directory on your PATH."
  fi
  if [ ! -w "$dir" ]; then
    err "cannot write to ${dir}. Set TIP_INSTALL_DIR to a writable directory on your PATH, or install manually with sudo."
  fi

  bin="tip"
  case "$os" in
    windows) bin="${bin}.exe" ;;
  esac
  chmod +x "$tmp/tip"
  cp "$tmp/tip" "${dir}/${bin}.tmp"
  mv "${dir}/${bin}.tmp" "${dir}/${bin}"
  info "Installed tip to ${dir}/${bin}"

  case ":${PATH}:" in
    *":${dir}"*) ;;
    *) warn "${dir} is not on your PATH. Add it, e.g.: export PATH=\"${dir}:\$PATH\"" ;;
  esac
}

main "$@"
