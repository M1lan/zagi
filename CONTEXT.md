# Context

Ephemeral working context for this PR. Delete before merging to main.

## Mission

Build git-native task management and autonomous agent execution for zagi.

## What is zagi?

A Zig + libgit2 wrapper that makes git output concise and agent-friendly:
- Smaller output (agents pay per token)
- Guardrails block destructive commands when `ZAGI_AGENT` is set
- Prompt provenance via `git commit --prompt "why this change"`
- Task management via `zagi tasks` (stored in `refs/tasks/<branch>`)

## Current Focus

Implementing RALPH-driven development for autonomous agent execution.

**RALPH**: https://lukeparker.dev/stop-chatting-with-ai-start-loops-ralph-driven-development

The loop:
1. `zagi agent plan` - Interactive planning session with user
2. `zagi agent run` - Autonomous execution of tasks
3. Tasks stored as git objects (`refs/tasks/<branch>`)
4. Agent picks pending task, completes it, marks done
5. Loop continues until all tasks complete

## Work Streams

### 1. Agent Execution (tasks 001-012) - DONE
- Subcommand refactor (plan/run)
- Executor config (ZAGI_AGENT, ZAGI_AGENT_CMD)
- Validation and bug fixes

### 2. Cleanup & Polish (tasks 013-023)
- Memory leaks in tasks.zig
- Hardcoded paths
- Documentation updates
- Style conformance

### 3. Testing (tasks 024-030)
- Agent plan/run tests
- Error condition coverage
- Full test suite pass

### 4. git edit Feature (tasks 037-062)
- jj-style mid-stack editing
- Lets agents fix commits from earlier in history
- Auto-rebases descendants after edit

### 5. Interactive Planning (tasks 032-036)
- Make `zagi agent plan` interactive (stdin/stdout passthrough)
- Agent explores codebase, asks questions, builds plan with user
- Convert approved plan to tasks

### 6. Observability (tasks 064-067)
- Streaming JSON output for debugging
- CONTEXT.md generation during planning

## Key Files

- `src/cmds/tasks.zig` - Task CRUD operations
- `src/cmds/agent.zig` - Agent plan/run subcommands
- `start.sh` - Independent RALPH loop runner
- `friction.md` - Issues encountered during development

## Constraints

- No external dependencies (everything in git)
- Concise output (agents pay per token)
- No emojis in code or output
- Agents cannot edit/delete tasks (guardrail)
- Always use `--prompt` when committing
- Never `git push` (only commit)

## Build & Test

```bash
zig build              # Build
zig build test         # Zig unit tests
cd test && bun run test  # Integration tests
```

## Environment

- `ZAGI_AGENT=claude|opencode` - Executor, enables guardrails
- `ZAGI_AGENT_CMD` - Custom command override
