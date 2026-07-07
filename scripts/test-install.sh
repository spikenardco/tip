#!/bin/sh
# Local smoke test for install.sh.
# Serves a fake release over HTTP, tests the happy path and a tampered-binary rejection.
set -eu

PORT=8765
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"; [ -n "${srv_pid:-}" ] && kill "$srv_pid" 2>/dev/null || true' EXIT INT TERM

os=$(uname -s); case "$os" in Linux) o=linux ;; Darwin) o=macos ;; *) echo "unsupported"; exit 1 ;; esac
arch=$(uname -m); case "$arch" in x86_64|amd64) a=x86_64 ;; aarch64|arm64) a=arm64 ;; *) echo "unsupported"; exit 1 ;; esac
asset="tip-$o-$a"

# Fake release tree: <work>/download/v9.9.9/<asset> and checksums.txt
rel="$work/download/v9.9.9"
mkdir -p "$rel"
printf '#!/bin/sh\necho fake-tip 9.9.9\n' > "$rel/$asset"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$rel" && sha256sum "$asset" > checksums.txt)
elif command -v shasum >/dev/null 2>&1; then
  (cd "$rel" && shasum -a 256 "$asset" > checksums.txt)
else
  echo "FAIL: need sha256sum or shasum"; exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "FAIL: need python3"; exit 1; }

# Start server on loopback only. Use exec so $! is the python process.
( cd "$work" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
srv_pid=$!

# Poll until the server is listening (max ~5 seconds).
i=0
while true; do
  if command -v curl >/dev/null 2>&1; then
    curl -sf "http://127.0.0.1:$PORT/download/v9.9.9/$asset" >/dev/null 2>&1 && break
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "http://127.0.0.1:$PORT/download/v9.9.9/$asset" >/dev/null 2>&1 && break
  else
    echo "FAIL: need curl or wget"; exit 1
  fi
  i=$((i + 1))
  if [ "$i" -ge 10 ]; then
    echo "FAIL: server did not start in time"
    exit 1
  fi
  sleep 0.5
done

export TIP_VERSION=v9.9.9
export TIP_BASE_URL="http://127.0.0.1:$PORT/download"

# ---- Happy path ----
dest="$work/bin"
TIP_INSTALL_DIR="$dest" sh "$here/install.sh"
[ -x "$dest/tip" ] || { echo "FAIL: tip not installed/executable"; exit 1; }
out=$("$dest/tip"); [ "$out" = "fake-tip 9.9.9" ] || { echo "FAIL: bad output: $out"; exit 1; }
echo "PASS: happy path"

# ---- Negative: tampered binary must be rejected ----
printf 'tampered\n' >> "$rel/$asset"
dest2="$work/bin2"
if TIP_INSTALL_DIR="$dest2" sh "$here/install.sh" 2>/dev/null; then
  echo "FAIL: installer accepted a tampered binary"; exit 1
fi
echo "PASS: tampered binary rejected"

echo "PASS: install.sh smoke test"
