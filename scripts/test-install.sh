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
