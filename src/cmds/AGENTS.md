<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-16 | Updated: 2026-03-16 -->

# src/cmds

## Purpose
One Zig file per implemented zagi command, plus shared utilities. Each file exposes a `run(allocator, args)` function and a `help` string constant. Shared libgit2 bindings and the error type live in `git.zig`.

## Key Files

| File | Description |
|------|-------------|
| `git.zig` | Shared error type (`Error`), libgit2 C import (`c`), status marker helpers (`indexMarker`, `workdirMarker`), `countUncommitted` utility |
| `log.zig` | `zagi log` — compact one-line commit history using libgit2 revwalk |
| `status.zig` | `zagi status` — concise staged/unstaged/untracked summary |
| `add.zig` | `zagi add` — stages files and prints a confirmation list |
| `commit.zig` | `zagi commit` — creates commits; handles `--prompt` flag to write git notes (`refs/notes/prompt`, `refs/notes/agent`, `refs/notes/session`); strips `Co-Authored-By` when `ZAGI_STRIP_COAUTHORS=1` |
| `diff.zig` | `zagi diff` — minimal diff output |
| `fork.zig` | `zagi fork` — ephemeral worktree management (`--pick`, `--promote`, `--delete`, `--delete-all`) stored under `.forks/` |
| `tasks.zig` | `zagi tasks` — task management stored in git notes (`refs/notes/tasks`); supports add/list/show/edit/append/delete/done/import/pr; JSON output via `--json` |
| `agent.zig` | `zagi agent` — RALPH loop (`agent run`) and interactive planner (`agent plan`); spawns AI executor (claude/opencode); validates `ZAGI_AGENT`/`ZAGI_AGENT_CMD` env vars |
| `alias.zig` | `zagi alias` — creates `git` shell alias pointing to zagi |
| `detect.zig` | `isAgentMode()` helper — detects `CLAUDECODE`, `OPENCODE`, IDE terminal env vars, or `ZAGI_AGENT` |

## For AI Agents

### Working In This Directory
- Every command file follows the same contract: export `pub const help: []const u8` and `pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) Error!void`.
- Errors flow up to `main.zig`; never call `std.process.exit()` here.
- Use `git.c` for all libgit2 calls (`git.zig` re-exports the C import).
- Agent-mode detection: call `detect.isAgentMode()` (already used by `passthrough.zig` and `commit.zig`).
- Tasks are stored as git notes — see `tasks.zig` for the note-ref convention (`refs/notes/tasks`).

### Testing Requirements
- Each file has inline Zig unit tests at the bottom.
- Register new test binaries in `build.zig` — follow the existing pattern (addTest → linkLibrary → addRunArtifact → test_step.dependOn).
- Integration tests for commands live in `test/src/<command>.test.ts`.

### Common Patterns
- Parse args with a manual `while (i < args.len)` loop; return `git.Error.UsageError` for bad input.
- Output is always compact and machine-readable — no decorations, no colour codes.
- For git notes: use `refs/notes/<namespace>` as the note ref; `tasks.zig` is the reference implementation.
- `fork.zig` uses `git worktree add` via the `passthrough` / child-process pattern.

## Dependencies

### Internal
- `git.zig` — all commands import this for the shared error set and libgit2 C bindings
- `detect.zig` — imported by `commit.zig` and `agent.zig` for agent-mode detection

### External
- `libgit2` — C library linked via `build.zig`

<!-- MANUAL: -->
