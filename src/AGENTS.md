<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-16 | Updated: 2026-03-16 -->

# src

## Purpose
Main Zig source tree for the zagi binary. Contains the entry point, command router, passthrough layer, and guardrails. All commands are implemented in `cmds/` and registered here.

## Key Files

| File | Description |
|------|-------------|
| `main.zig` | Entry point and command router. Dispatches to `cmds/` modules; centralises error handling and exit codes. Never call `std.process.exit()` outside this file. |
| `passthrough.zig` | Forwards unknown commands to the system `git` binary. Checks guardrails before forwarding when agent mode is active. |
| `guardrails.zig` | Blocklist of destructive git commands (reset --hard, push --force, clean -f, etc.) enforced in agent mode. Pattern-matching logic with unit tests. |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `cmds/` | One file per implemented zagi command (see `cmds/AGENTS.md`) |

## For AI Agents

### Working In This Directory
- `main.zig` owns all `std.process.exit()` calls. Command modules must `return error.Foo` instead.
- To add a new command: implement in `cmds/<name>.zig`, import in `main.zig`, add a `Command` enum variant, and add a routing branch in `run()`.
- `passthrough.zig` delegates to system `git` — only modify it if guardrail or passthrough behaviour needs to change.
- `guardrails.zig` is the single source of truth for blocked patterns. Add new patterns there when new destructive commands are identified.

### Testing Requirements
- Unit tests live inside each `.zig` file (see `testing` blocks at the bottom of each file).
- Run: `zig build test` from the repo root.
- `guardrails.zig` has extensive pattern tests — verify all existing tests still pass after any change.

### Common Patterns
- `build_options.version` is injected at build time via `build.zig`; read with `@import("build_options")`.
- Use `std.fs.File.stdout().deprecatedWriter()` / `stderr()` for output (Zig 0.15 API).
- All libgit2 access is done through `cmds/git.zig`; never `@cImport` git2.h directly in this directory.

## Dependencies

### Internal
- `cmds/` — all command implementations
- `cmds/git.zig` — shared error type, libgit2 helpers

### External
- `libgit2` (via `build.zig.zon` dependency, linked via `build.zig`)

<!-- MANUAL: -->
