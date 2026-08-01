# Tip

Tip is a local task manager for the terminal. It stores tasks in SQLite and
lets you add, edit, list, complete, and restart them without a server or
account.

## Install

**macOS, Linux, or Windows with Git Bash/WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/spikenardco/tip/main/scripts/install.sh | sh
```

The installer downloads the latest release for your platform. Set
`TIP_VERSION=vX.Y.Z` to install a specific version. You can also download
binaries from the [releases page](https://github.com/spikenardco/tip/releases).

To build from source, install [Zig 0.16](https://ziglang.org/download/) or
newer:

```bash
git clone https://github.com/spikenardco/tip
cd tip
zig build
```

## Usage

```bash
tip --version
tip task add --title="Review code" --desc="Review PR #42"
tip task --list
tip task edit --id=<id> --title="Review the code"
tip task complete --id=<id>
tip task start --id=<id>
tip task delete --id=<id>
```

Use `tip --help` and `tip task --help` for the full command reference. Task
commands use exact IDs. The list output shows each task's ID, status, title,
description, priority, due date, and completion time when available.

## Storage

Tip is local-only. It stores tasks in `tip.db` under the platform data
directory:

- Linux: `$XDG_DATA_HOME/tip`, or `~/.local/share/tip`
- macOS: `~/Library/Application Support/tip`
- Windows: `%APPDATA%/tip`

The database uses SQLite WAL mode and applies migrations when Tip starts.

## Development

```bash
zig build
zig build run
zig build test --summary all
```

## License

MIT. See [LICENSE](LICENSE).
