# Tip

A task manager built with Zig.

## Installation

### Quick install

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/spikenardco/tip/main/scripts/install.sh | sh
```

**Windows (Git Bash / WSL):**

```bash
curl -fsSL https://raw.githubusercontent.com/spikenardco/tip/main/scripts/install.sh | sh
```

The installer downloads the right binary for your platform, verifies its
integrity against `checksums.txt`, and installs `tip` to `~/.local/bin`
(macOS/Linux) or `$HOME/AppData/Local/tip/bin` (Windows Git Bash).
Set `TIP_VERSION=vX.Y.Z` to pin a version.

**Windows (PowerShell):** Use [Git Bash](https://git-scm.com) or
[WSL](https://learn.microsoft.com/en-us/windows/wsl/install) to run the shell
installer above, or download the binary manually (see below).

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

If you download the binary in a browser, macOS may show an "unidentified
developer" warning. Right-click the binary and choose Open, or clear the
quarantine flag:

```bash
xattr -d com.apple.quarantine ./tip-macos-arm64
```

The quick-install script avoids this, since files fetched with `curl` are not
quarantined.

### Build from source

```bash
git clone https://github.com/spikenardco/tip
cd tip
zig build
```

## Quick Start

```bash
# Verify installation
tip --version

# Add a task
tip task add --title="Review code" --desc="Review PR #42"

# List tasks
tip task --list

# Complete a task by its exact ID
tip task complete --id=<id>

# Start a task again
tip task start --id=<id>
```

## Commands

```text
tip --help
tip --version
tip task --help
tip task --list
tip task add --title=<title> [--desc=<description>]
tip task edit --id=<id> --title=<title> [--desc=<description>]
tip task delete --id=<id>
tip task complete --id=<id>
tip task start --id=<id>
```

Task commands use exact IDs. Prefix matching is not supported.

## Storage

Tip stores tasks in a SQLite database named `tip.db` inside its platform data
directory:

- Linux: `$XDG_DATA_HOME/tip`, or `~/.local/share/tip` when `XDG_DATA_HOME` is unset
- macOS: `~/Library/Application Support/tip`
- Windows: `%APPDATA%/tip`

The database uses SQLite WAL mode and applies embedded migrations on startup.

## Current limits

- Tip currently manages local tasks only.
- The CLI exposes task title and description fields. Priority, due date, and assignee are model fields but are not currently CLI options.
- `complete` and `start` are status operations. Timestamp updates are not currently part of their reliable behavior.
- Password management, encryption, multiple vaults, configuration, synchronization, remote storage, import/export, and server APIs are not implemented.

## Documentation

- [Superpowers plans](docs/superpowers/plans/) - Implementation plans and status
- [Superpowers specs](docs/superpowers/specs/) - Design records and decisions

## Development

### Prerequisites
- Zig 0.16+

### Running Tests
```bash
# Run all tests
zig build test --summary all
```

### Build
```bash
# Build CLI
zig build

# Run the CLI
zig build run
```

## License

MIT License - See [LICENSE](LICENSE)
