# Tip

A task manager built with Zig.

## Quick Start

```bash
# Add a task
tip task add --title="Review code" --desc="Review PR #42"

# List tasks
tip task --list

# Run tests
zig build test --summary all
```

## Documentation

- **[Roadmap](docs/ROADMAP.md)** - Development timeline and milestones
- **[Architecture](docs/ARCHITECTURE.md)** - System design and technical details

## Installation

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

### Build from source

```bash
git clone https://github.com/spikenardco/tip
cd tip
zig build
```

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
