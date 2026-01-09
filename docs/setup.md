# Setup

## Requirements

- Zig 0.15+
- Bun (for integration tests)

## Building

```bash
zig build
```

The binary will be at `./zig-out/bin/zagi`.

## Executor Configuration

zagi agent commands (`agent plan`, `agent run`) use AI agents to execute tasks. Configure which agent to use with environment variables.

### ZAGI_AGENT

Select a built-in executor for `zagi agent` commands:

```bash
# Use Claude Code (default)
ZAGI_AGENT=claude zagi agent run

# Use opencode
ZAGI_AGENT=opencode zagi agent run
```

Valid values for executors: `claude`, `opencode`

Note: Agent mode (guardrails, `--prompt` requirement) is auto-detected from the environment. Setting `ZAGI_AGENT` also enables agent mode, but this is primarily for selecting the executor.

Built-in executors automatically handle mode flags:
- `claude`: adds `-p` for headless mode (`agent run`)
- `opencode`: adds `run` for headless mode (`agent run`)

### ZAGI_AGENT_CMD

Override the command used to invoke the agent:

```bash
# Use a custom Claude binary with extra flags
ZAGI_AGENT=claude
ZAGI_AGENT_CMD="~/my-claude --dangerously-skip-permissions"
zagi agent run
# → Executes: ~/my-claude --dangerously-skip-permissions -p "<prompt>"
```

When both `ZAGI_AGENT` and `ZAGI_AGENT_CMD` are set:
- `ZAGI_AGENT_CMD` provides the base command
- `ZAGI_AGENT` determines what mode flags to add (`-p` for claude, `run` for opencode)

### Custom Tools

For tools that aren't claude or opencode, just set `ZAGI_AGENT_CMD`:

```bash
# Use aider (no auto flags added)
ZAGI_AGENT_CMD="aider --yes" zagi agent run
# → Executes: aider --yes "<prompt>"
```

When only `ZAGI_AGENT_CMD` is set (no `ZAGI_AGENT`), the command is used as-is with no automatic flags.

### Examples

| ZAGI_AGENT | ZAGI_AGENT_CMD | agent run executes |
|------------|----------------|-------------------|
| `claude` | (not set) | `claude -p "<prompt>"` |
| `opencode` | (not set) | `opencode run "<prompt>"` |
| `claude` | `myclaude --flag` | `myclaude --flag -p "<prompt>"` |
| `opencode` | `myopencode --flag` | `myopencode --flag run "<prompt>"` |
| (not set) | `aider --yes` | `aider --yes "<prompt>"` |

### Agent Mode Safety

Agent mode is automatically enabled when running inside AI tools (Claude Code, OpenCode, Cursor, Windsurf, VS Code) or when `ZAGI_AGENT` is set. When active, destructive git commands are blocked to prevent data loss. See [AGENTS.md](../AGENTS.md#blocked-commands-in-agent-mode) for the full list.

## Log Files

Task execution logs are written to `/tmp/zagi/<repo-name>/<task-id>.log`. Output is streamed in real-time to both the console and log file.
