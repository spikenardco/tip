# Tip

A task manager built with Zig.


## Quick Start

```bash
# Add a task
tip task add --name=github --desc="Review code"

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

## Use Cases

**Individual Users**
- Secure personal password vault
- Task and todo list management
- Offline-first operation

**Teams**
- Shared password management
- Collaborative task tracking
- Team member permissions
- Audit trails and compliance

**Developers**
- CLI-based automation
- REST API integration
- Custom field support
- Git-friendly configuration

## Security Notes

- Master password never stored, only derived key
- All sensitive data encrypted at rest and in transit
- Uses industry-standard cryptographic algorithms
- Comprehensive audit logging
- Regular security assessments recommended

## Self-Hosted Deployment

Tip is designed for self-hosted deployment:

## License

MIT License - See [LICENSE](LICENSE)

## Contributing

Contributions welcome! Please see the development roadmap in [docs/ROADMAP.md](docs/ROADMAP.md)

## Support

- Documentation: [docs/](docs/)
- Issues: GitHub Issues
