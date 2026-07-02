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
