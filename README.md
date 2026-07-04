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

### Download a release

Grab the archive for your platform from the [releases page](https://github.com/spikenardco/tip/releases), then extract it. The binary inside is named `tip` and is already executable.

```bash
# macOS / Linux (example: Apple Silicon)
tar -xzf tip-macos-arm64.tar.gz
./tip-macos-arm64/tip --version
```

On Windows, extract `tip-windows-x86_64.zip` and run `tip.exe`.

Verify a download against `checksums.txt`:

```bash
sha256sum -c checksums.txt
```

#### macOS: first launch

macOS may show an "unidentified developer" warning for a downloaded binary. It is safe to run — either **right-click the binary → Open** once, or clear the quarantine flag:

```bash
xattr -d com.apple.quarantine ./tip
```

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
