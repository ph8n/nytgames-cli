# New York Times Game cli

A CLI tool to play NYT Games in your terminal.

## Build

- `zig build`
- Run: `zig build run` (or `./zig-out/bin/nytgames`)

## Usage

- Menu: `nytgames`
- Wordle (daily): `nytgames wordle`
- Wordle Unlimited: `nytgames unlimited` (or `nytgames wordle unlimited`)
- Connections: `nytgames connections`
- Spelling Bee: `nytgames spelling-bee` (or `nytgames bee`)

### Spelling Bee controls

- Type letters (must be from the hive)
- `Backspace`: delete
- `Enter`: submit word
- `Space`: shuffle outer letters
- `↑/↓`: scroll word list
- `q`/`Esc`: back (or quit on direct launch)
