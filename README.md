# nytgames-cli

[![CI](https://github.com/ph8n/nytgames-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/ph8n/nytgames-cli/actions/workflows/ci.yml)

Play NYT Games in your terminal, with local stats tracking.

**Games**
- Wordle (daily)
- Wordle Unlimited (offline)
- Connections (daily)

Not affiliated with The New York Times.

## Install

### Homebrew (macOS + Linux)

This project publishes a self-contained Homebrew formula as a release asset.

```bash
brew install --formula https://github.com/ph8n/nytgames-cli/releases/latest/download/nytgames-cli.rb
```

### Curl (macOS + Linux)

Installs the prebuilt binary from GitHub Releases.

```bash
curl -fsSL https://raw.githubusercontent.com/ph8n/nytgames-cli/main/scripts/install.sh | bash
```

Options:
- Pin a version:
  - `curl -fsSL https://raw.githubusercontent.com/ph8n/nytgames-cli/main/scripts/install.sh | NYTGAMES_CLI_VERSION=X.Y.Z bash`
- Choose install dir: `NYTGAMES_CLI_INSTALL_DIR=~/.local/bin`

### Linux packages

Download the package from the GitHub Release page:
- Debian/Ubuntu (`.deb`): `sudo apt install ./nytgames-cli_X.Y.Z_linux_amd64.deb`
- Fedora/RHEL (`.rpm`): `sudo dnf install ./nytgames-cli_X.Y.Z_linux_amd64.rpm`

Arch:
- AUR template: `packaging/aur/nytgames-cli-bin/PKGBUILD`

## Usage

```bash
nytgames --help
nytgames --version
```

Run the menu:
```bash
nytgames
```

Direct launch:
```bash
nytgames wordle
nytgames unlimited          # (or: nytgames wordle unlimited)
nytgames connections
```

Dev mode (bypasses the “already played today” screen):
```bash
nytgames --dev
```

## Controls

Menu:
- Left/Right or `h/l`: change game
- Up/Down or `j/k`: choose Play vs Stats
- Enter/Space: confirm
- Ctrl+C: quit

Stats:
- Left/Right or `h/l`: change month
- `q`/Esc: back
- Ctrl+C: quit

Wordle:
- Type letters, Backspace, Enter to submit
- `q`/Esc: menu
- Ctrl+C: quit

Connections:
- Arrow keys or `h/j/k/l`: move focus
- Space: select
- Enter: submit
- `s`: shuffle
- `d`: deselect all
- `q`/Esc: menu
- Ctrl+C: quit

## Stats & data

- Stats are stored locally in a SQLite DB: `<app data dir>/nytg-cli/stats.db`.
- Typical locations:
  - macOS: `~/Library/Application Support/nytg-cli/stats.db`
  - Linux: `${XDG_DATA_HOME:-~/.local/share}/nytg-cli/stats.db`
- To reset stats: delete `stats.db`.
- No telemetry; the only network requests are to fetch daily puzzles:
  - `https://www.nytimes.com/svc/wordle/v2/YYYY-MM-DD.json`
  - `https://www.nytimes.com/svc/connections/v2/YYYY-MM-DD.json`

Tip: your terminal needs a Unicode-capable font (the UI uses box-drawing chars and `✓`).

## Build from source

Requires Zig `0.15.1`.

```bash
zig build
zig build test
zig build run
```

Build with a version string (used by `nytgames --version`):
```bash
zig build -Dversion=0.1.0
```

## Uninstall

- Remove the binary (wherever you installed it, e.g. `~/.local/bin/nytgames` or `/usr/local/bin/nytgames`).
- Optional: remove your local stats DB (`nytg-cli/stats.db`).

## License

MIT — see `LICENSE`.
