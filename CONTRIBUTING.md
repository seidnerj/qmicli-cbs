# Contributing to qmicli-cbs

## Development Setup

```bash
git clone https://github.com/seidnerj/qmicli-cbs.git
cd qmicli-cbs
pre-commit install --hook-type commit-msg --hook-type pre-commit
```

Docker is required for building - the entire toolchain runs inside the Docker image, so host setup is minimal.

## Building

```bash
./build.sh              # Static linking (default, self-contained binary)
./build.sh --dynamic    # Dynamic linking (smaller, needs matching system libs)
```

The resulting binary lands in `output/`.

## Code Style

- 4-space indentation, LF line endings
- No em dashes anywhere - use regular hyphens/dashes (-)
- For `.c`/`.h` edits, match libqmi's existing style (GNU-ish, 4-space)
- Patches in `patches/` must preserve `git format-patch` structure and numeric ordering

## Testing

There's no automated test suite. Verification is manual:

1. Build the binary via `./build.sh`
2. Transfer it to a QMI-capable device
3. Exercise the affected command against a live modem

## Pre-commit Hooks

The following checks run automatically on commit:

- **trailing-whitespace** - Trim trailing whitespace (skipped for `.patch` files)
- **end-of-file-fixer** - Ensure files end with newline (skipped for `.patch` files)
- **mixed-line-ending** - Normalize to LF (skipped for `.patch` files)
- **check-merge-conflict** - Prevent committing unresolved merge conflicts
- **check-added-large-files** - Block files over 1 MB
- **detect-secrets** - Secret detection against baseline
- **check-claude-attribution** - Prevent Claude attribution in commit messages

Run all hooks manually:

```bash
pre-commit run --all-files
```

## Pull Requests

1. Create a feature branch from `main`
2. If the change belongs in upstream libqmi, prefer adding it as a new numbered patch in `patches/` and submitting to [libqmi issue #131](https://gitlab.freedesktop.org/mobile-broadband/libqmi/-/issues/131) rather than forking the tree further
3. Ensure the build still succeeds via `./build.sh`
4. Ensure all pre-commit hooks pass
5. Submit a PR with a clear description of the change

## License

This project inherits libqmi's license (GPL v2). By contributing, you agree that your contributions will be licensed under GPL v2 or later.
