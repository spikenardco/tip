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
