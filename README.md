# zagi

> a better git interface for agents

## Why use zagi?

- 121 git compatible commands
- ~50% smaller output that doesn't overflow context windows
- 1.5-2x faster than git in all implemented commands
- Agent friendly features like `fork`, `prompt` and `guardrails`
- Git passthrough for non implemented commands

## Installation

```bash
curl -fsSL zagi.sh/install | sh
```

This downloads the binary and sets up `git` as an alias to `zagi`. Restart your shell after installation.

### From source

```bash
git clone https://github.com/mattzcarey/zagi.git
cd zagi
zig build -Doptimize=ReleaseFast
./zig-out/bin/zagi alias  # set up the alias
```

## Usage

Use git as normal:

```bash
git status         # compact status
git log            # concise commit history
git diff           # minimal diff format
git add .          # confirms what was staged
git commit -m "x"  # shows commit stats
```

Any commands or flags not yet implemented in zagi pass through to git. zagi also comes with its own set of features for managing code written by agents.

### Easy worktrees

zagi ships with a wrapper around worktrees called `fork`:

```bash
# Create named forks for different approaches your agent could take
git fork nodejs-based
git fork bun-based

# Work in each fork
cd .forks/nodejs-based
# ... make changes, commit ...

cd .forks/bun-based
# ... make changes, commit ...

# Compare results, then pick the winner
cd ../..
git fork                       # list forks with commit counts
git fork --pick bun-based      # merge fork into base (keeps both histories)
git fork --promote bun-based   # replace base with fork (discards base commits)

# Clean up
git fork --delete-all
```

### Agent mode

Agent mode is automatically enabled when running inside AI tools (Claude Code, OpenCode, Cursor, Windsurf, VS Code). You can also enable it manually:

```bash
export ZAGI_AGENT=my-agent
```

This enables:
- **Prompt tracking**: `git commit` requires `--prompt` to record the user request that created the commit
- **AI attribution**: Automatically detects and stores which AI agent made the commit
- **Guardrails**: Blocks destructive commands (`reset --hard`, `checkout .`, `clean -f`, `push --force`) to prevent data loss

```bash
git commit -m "Add feature" --prompt "Add a logout button to the header"
git log --prompts   # view prompts
git log --agent     # view which AI agent made commits
git log --session   # view full session transcript (with pagination)
```

Metadata is stored in git notes (`refs/notes/agent`, `refs/notes/prompt`, `refs/notes/session`) which are local by default and don't affect commit history.

### Environment variables

| Variable | Description | Default | Valid values |
|----------|-------------|---------|--------------|
| `ZAGI_AGENT` | Manually enable agent mode. Auto-detected from `CLAUDECODE`, `OPENCODE`, or IDE environment. | (auto) | Any string enables agent mode. For executors: `claude`, `opencode` |
| `ZAGI_AGENT_CMD` | Custom executor command override. When set, the prompt is appended as the final argument. | (unset) | Any shell command (e.g., `aider --yes`) |
| `ZAGI_STRIP_COAUTHORS` | Strips `Co-Authored-By:` lines from commit messages. | (unset) | `1` to enable |

**Agent detection**: Agent mode is automatically enabled when `CLAUDECODE=1` or `OPENCODE=1` is set (by Claude Code or OpenCode), or when running in VS Code/Cursor/Windsurf terminals.

```bash
# Use Claude Code (default)
ZAGI_AGENT=claude zagi agent run

# Use opencode
ZAGI_AGENT=opencode zagi agent run

# Use a custom command
ZAGI_AGENT_CMD="aider --yes" zagi agent run
```

### Strip co-authors

Remove `Co-Authored-By:` lines that AI tools like Claude Code add to commit messages:

```bash
export ZAGI_STRIP_COAUTHORS=1
git commit -m "Add feature

Co-Authored-By: Claude <claude@anthropic.com>"  # stripped automatically
```

### Git passthrough

Commands zagi doesn't implement pass through to git or use `-g` to force standard git output:

```bash
git -g log         # native git log output
git --git diff     # native git diff output
```

## Output comparison

Standard git log:

```
commit abc123f4567890def1234567890abcdef12345
Author: Alice Smith <alice@example.com>
Date:   Mon Jan 15 14:32:21 2025 -0800

    Add user authentication system
```

zagi log:

```
abc123f (2025-01-15) Alice: Add user authentication system
```

## Development

Requirements: Zig 0.15, Bun

```bash
zig build                           # build
zig build test                      # run zig tests
cd test && bun i && bun run test    # run integration tests
```

See [AGENTS.md](AGENTS.md) for contribution guidelines.

## License

MIT
