# Contributing

Thanks for helping make `nytgames-cli` better.

## Getting Started

- Install Zig `0.15.1`.
- Build: `zig build`
- Run: `zig build run`
- Tests: `zig build test`

## Conventions

- Keep changes focused and small; avoid unrelated refactors in the same PR.
- Format Zig code with `zig fmt` on files you touch.
- Prefer clear, explicit control flow over cleverness.
- Keep the app cross-platform; guard OS-specific code with `builtin.os.tag`.
- Avoid adding new dependencies unless there is a strong reason.

## Documentation

- Update `README.md` for user-facing changes.
- If you change install behavior, update the installer scripts and docs together.

## Commits & PRs

- Use short, imperative commit messages (e.g. "Fix stats date parsing").
- Include a concise summary of the change and how it was tested.
- If tests are not run, say why.

## Release Notes (Maintainers)

- Releases are built by GitHub Actions when a tag `vX.Y.Z` is pushed.
- Packaging and installers are in `.github/workflows/release.yml` and `scripts/`.
