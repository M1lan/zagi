# PRD: git tasks

## Overview

`git tasks` is a git-native task tracking system for AI agents. It enables structured, immutable task management that integrates directly with version control and PR workflows.

**Key insight**: Unlike Beads (which is a separate database synced via git), `git tasks` stores tasks *as git objects*. This makes them truly immutable and atomic with the repository state.

---

## Problem Statement

### Current Pain Points

1. **Agent Memory Loss**: AI agents lose context between sessions (~10 minute windows). Plans written to markdown files proliferate and decay.

2. **Unstructured Planning**: Agents dump plans into markdown that becomes stale, inconsistent, and hard to query.

3. **No Audit Trail**: When an agent completes work, there's no record of what tasks led to that work or how they were resolved.

4. **PR Disconnect**: Task context is lost when code is submitted. Reviewers see commits but not the reasoning graph that produced them.

5. **Mutable Plans**: Agents can modify their own plans mid-execution, hiding mistakes and making debugging difficult.

### Why Not Beads?

Beads is excellent for complex multi-agent orchestration, but:
- It's a separate tool with its own database (JSONL + SQLite cache)
- Designed for long-running projects with 200+ issues
- Requires a daemon and sync mechanism
- Adds complexity for simple agent loops

`git tasks` is lighter weight, designed for single-session agent loops where:
- Tasks are immutable once filed
- The task list accompanies the PR
- Everything is stored as git objects (no external state)

---

## Core Principles

### 1. Immutability

Once a task is created, its content **cannot be modified**. An agent can only:
- Mark a task as `done`
- Add a note/comment (appended, not edited)

This prevents agents from "covering their tracks" and provides a reliable audit trail.

### 2. Git-Native Storage

Tasks are stored as git refs, not tracked files:
- **Ref**: `refs/tasks/<branch>` points to a tree object
- **Tree object**: Contains task blobs (JSONL format)
- **No working directory pollution**: Tasks don't appear in `git status`

This means:
- Tasks are versioned but don't clutter the working tree
- Clean separation from application code
- Refs are pushed/pulled with the branch
- `git tasks pr` exports tasks for PR descriptions

### 3. Agent Constraints

When `ZAGI_AGENT` is set:
- `git tasks add` works (create new tasks)
- `git tasks done <id>` works (mark complete)
- `git tasks edit` is **blocked** (immutable)
- `git tasks delete` is **blocked** (immutable)
- `git tasks note <id> <message>` works (append-only)

Humans can still edit/delete tasks when not in agent mode.

### 4. PR Integration

When creating a PR, the task list is automatically included:
- Shows all tasks for the branch
- Indicates completion status
- Links tasks to commits that closed them
- Provides reviewers with the "why" behind changes

---

## User Stories

### As an AI Agent

1. **File a task**: When I discover work to be done, I can record it immediately so it won't be forgotten across sessions.
   ```bash
   git tasks add "Refactor auth middleware to use JWT"
   # Output: task-a3f8: Refactor auth middleware to use JWT
   ```

2. **File a dependent task**: When work must happen after another task, I can specify the dependency.
   ```bash
   git tasks add "Write tests for JWT auth" --after task-a3f8
   # Output: task-b4c9: Write tests for JWT auth (after task-a3f8)
   ```

3. **Complete a task**: When I finish work, I mark the task done. The next commit auto-links.
   ```bash
   git tasks done task-a3f8
   # Output: task-a3f8: done
   git commit -m "Implement JWT auth" --prompt "..."
   # task-a3f8.closed_commit = abc1234
   ```

4. **Query ready work**: Start a session by asking what tasks are available (not blocked by dependencies).
   ```bash
   git tasks ready
   # Output:
   # task-b4c9: Add input validation to /api/users endpoint
   # (task-c5d0 blocked by task-a3f8)
   ```

5. **View task details**: Understand what a specific task requires.
   ```bash
   git tasks show task-a3f8
   # Output:
   # task-a3f8: Refactor auth middleware to use JWT
   # status: done
   # created: 2025-01-02T10:30:00Z
   # closed: 2025-01-02T11:45:00Z
   # commit: abc1234
   ```

### As a Human Developer

1. **Review agent work**: See what tasks the agent filed and completed.
   ```bash
   git tasks list --all
   ```

2. **Export for PR**: Generate markdown for PR description.
   ```bash
   git tasks pr
   # Output: (markdown formatted task list with checkboxes and commits)
   ```

3. **Edit task** (when not in agent mode): Fix typos or clarify requirements.
   ```bash
   git tasks edit task-a3f8 --content "Refactor auth to use JWT (not sessions)"
   ```

4. **Delete stale tasks**: Remove tasks that are no longer relevant.
   ```bash
   git tasks delete task-a3f8
   ```

### As a PR Reviewer

1. **Understand intent**: See the tasks that drove the changes.
2. **Verify completeness**: Check that all filed tasks are addressed.
3. **Audit trail**: Trace from task → commits → final code.

---

## Technical Design

### Data Model

```jsonl
{"id":"task-a3f8","content":"Refactor auth middleware to use JWT","status":"pending","created_at":"2025-01-02T10:30:00Z","created_by":"claude-code","after":null,"closed_at":null,"closed_commit":null,"notes":[]}
```

Fields:
- `id`: Flat task ID (e.g., `task-a3f8`)
- `content`: Task description (immutable after creation)
- `status`: `pending` | `done`
- `created_at`: ISO timestamp
- `created_by`: Value of `ZAGI_AGENT` env var
- `after`: Task ID this depends on (null if none)
- `closed_at`: ISO timestamp when marked done
- `closed_commit`: Commit hash that closed this task (auto-linked)
- `notes`: Append-only array of strings

### Task ID Generation

Short hash (4 chars) from content + timestamp:
- `task-` prefix for clarity
- Flat IDs only (no hierarchical subtasks)
- Collision-resistant within a branch
- Human-readable and typeable

### Commands

| Command | Description | Agent Mode |
|---------|-------------|------------|
| `git tasks add <content> [--after <id>]` | Create new task, optionally dependent on another | Allowed |
| `git tasks list [--status]` | List tasks | Allowed |
| `git tasks ready` | List pending tasks with no blockers | Allowed |
| `git tasks show <id>` | Show task details | Allowed |
| `git tasks done <id> [--note]` | Mark complete, auto-links next commit | Allowed |
| `git tasks note <id> <msg>` | Append note | Allowed |
| `git tasks pr` | Export tasks as markdown for PR description | Allowed |
| `git tasks run [--claude\|--opencode\|--runner]` | Run headless agent loop over tasks | N/A (human runs this) |
| `git tasks edit <id>` | Modify task | **Blocked** |
| `git tasks delete <id>` | Remove task | **Blocked** |

### Commit Linking

When `git tasks done <id>` is called, the next `git commit` automatically links to that task:
1. Agent marks task done: `git tasks done task-a3f8`
2. Agent commits: `git commit -m "Implement JWT auth" --prompt "..."`
3. The commit hash is stored in `task-a3f8.closed_commit`

This creates a bidirectional link:
- Task → Commit (stored in task data)
- Commit → Task (via `git log --tasks` which shows linked tasks)

### Storage: Git Refs

Tasks are stored in custom git refs:

```
refs/tasks/<branch-name>
  └── tree object
        └── tasks.jsonl (blob containing all tasks)
```

**How it works:**
1. `git tasks add` reads current tree from `refs/tasks/<branch>`, appends task, writes new tree
2. Tasks are JSONL (one JSON object per line) for append-friendly operations
3. `git tasks pr` reads the ref and formats for PR description
4. Refs are pushed with `git push origin refs/tasks/*:refs/tasks/*`

**Benefits:**
- No working directory pollution (tasks don't show in `git status`)
- Clean separation from application code
- Survives branch switches
- Can be pushed to remote for collaboration

**PR Export (`git tasks pr`):**
```markdown
## Tasks

- [x] task-a3f8: Refactor auth middleware to use JWT (abc1234)
- [x] task-b4c9: Add input validation (def5678)
- [ ] task-c5d0: Write tests for auth middleware

### Dependency Graph
task-b4c9 → task-c5d0 (blocked)
```

---

## Integration with RALPH Workflow

The RALPH (iterative loop) workflow becomes:

```
┌────────────────────���────────────────────────────┐
│  1. PLAN PHASE                                  │
│  - Human dictates requirements                  │
│  - Agent files tasks via `git tasks add`        │
│  - Human reviews task list                      │
└─────────────────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────┐
│  2. LOOP PHASE                                  │
│  git tasks run                                  │
│    - Picks next ready task                      │
│    - Spawns claude code with task               │
│    - Agent completes, commits, marks done       │
│    - Loop continues until all done              │
└─────────────────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────┐
│  3. REVIEW PHASE                                │
│  - Human reviews commits                        │
│  - git tasks pr for PR description              │
│  - Audit trail preserved                        │
└─────────────────────────────────────────────────┘
```

---

## The `git tasks run` Command

The killer feature: a built-in RALPH loop runner that integrates with Claude Code.

### Basic Usage

```bash
git tasks run
```

This:
1. Gets the next ready task (`git tasks ready | head -1`)
2. Spawns Claude Code with a structured prompt
3. Waits for completion
4. Loops until all tasks are done
5. Never pushes, only commits

### Options

| Flag | Description |
|------|-------------|
| `--claude` | Use Claude Code as runner (default) |
| `--opencode` | Use OpenCode as runner |
| `--runner <cmd>` | Use custom runner command |
| `--model <model>` | Model to use (default: `claude-sonnet-4-20250514`) |
| `--once` | Run only one task, then exit |
| `--dry-run` | Show what would run without executing |
| `--delay <seconds>` | Delay between tasks (default: 2s) |
| `--max-tasks <n>` | Stop after n tasks (safety limit) |

### Examples

```bash
# Claude Code (default)
git tasks run
git tasks run --claude
git tasks run --claude --model claude-opus-4-20250514
git tasks run --claude --model claude-sonnet-4-20250514

# OpenCode
git tasks run --opencode
git tasks run --opencode --model anthropic/claude-sonnet-4
git tasks run --opencode --model openai/gpt-4o

# Custom runner (aider, etc.)
git tasks run --runner "aider --yes"
git tasks run --runner "goose run"

# Safety options
git tasks run --once              # Run one task, then exit
git tasks run --dry-run           # Show what would run
git tasks run --max-tasks 5       # Stop after 5 tasks
git tasks run --delay 5           # 5 second delay between tasks
```

### The Agent Prompt

When `git tasks run` spawns Claude Code, it passes this prompt:

```
You are working on task {task_id}: {task_content}

Instructions:
1. Read AGENTS.md for project context
2. Complete this ONE task only
3. Verify your work (run tests, check output)
4. Commit your changes with: git commit -m "<message>" --prompt "{task_content}"
5. Mark the task done: git tasks done {task_id}
6. If you learn critical operational details, update AGENTS.md

Rules:
- NEVER git push (only commit)
- ONLY work on this one task
- If blocked, add a note: git tasks note {task_id} "blocked: <reason>"
```

### How It Works Internally

```
┌─────────────────────────────────────────────────┐
│  git tasks run                                  │
└─────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────┐
│  while true:                                    │
│    task = git tasks ready --json | .[0]         │
│    if task is null: break                       │
│                                                 │
│    spawn: claude -p "$PROMPT" --model $MODEL    │
│    wait for exit                                │
│                                                 │
│    # Agent should have:                         │
│    # - Committed changes                        │
│    # - Called `git tasks done $task_id`         │
│    # - Task now has closed_commit set           │
│                                                 │
│    sleep $DELAY                                 │
│  done                                           │
│                                                 │
│  print "All tasks complete!"                    │
│  print "Run: git tasks pr"                      │
└─────────────────────────────────────────────────┘
```

### Failure Handling

If the agent crashes or exits without completing:
- Task remains `pending` (not marked done)
- Next loop iteration picks it up again
- After 3 consecutive failures on same task, adds a note and skips

```bash
# If agent keeps failing on task-a3f8:
git tasks note task-a3f8 "skipped: agent failed 3 times"
# Task is NOT marked done, just skipped for this run
```

### Runner Integration (Headless Mode)

All runners are invoked in **headless/non-interactive mode**:

**Claude Code (`--claude`, default):**
```bash
claude --print --model "$MODEL" "$PROMPT"
```

**OpenCode (`--opencode`):**
```bash
opencode run -m "$MODEL" "$PROMPT"
```

**Custom (`--runner`):**
```bash
$RUNNER "$PROMPT"
# e.g., aider --yes "$PROMPT"
```

For custom runners, the command receives the prompt as a single argument. The runner must:
1. Accept the prompt and execute it
2. Exit when complete (no interactive session)
3. Have `git` available to call `git tasks done`

### Why Headless?

The loop runs unattended - no human interaction expected:
- Output streams to terminal for monitoring
- Each task is independent (stateless)
- Failures are logged and skipped after retries
- Human reviews results after loop completes

---

## Comparison with Beads

| Feature | git tasks | Beads |
|---------|-----------|-------|
| Storage | Git refs (JSONL blob) | JSONL files + SQLite cache |
| Complexity | Single command | Full CLI + daemon |
| Scope | Single session/PR | Multi-project |
| Dependencies | Single `--after` link | 4 dependency types |
| Task IDs | Flat (`task-xxxx`) | Hierarchical (`bd-xxxx.1.1`) |
| Immutability | Enforced in agent mode | Not enforced |
| Commit Linking | Automatic | Manual |
| PR Integration | `git tasks pr` | Manual export |
| Multi-agent | No | Yes |
| Best for | Simple loops | Complex orchestration |

### When to Use Each

**Use git tasks when:**
- Running single-agent loops
- Want task context in PRs
- Need enforced immutability
- Prefer simplicity

**Use Beads when:**
- Managing large projects (100+ issues)
- Running multiple agents
- Need complex dependency graphs
- Want query capabilities

---

## Implementation Plan

### Phase 1: Core Storage & Commands
1. Implement git ref storage (`refs/tasks/<branch>`)
2. `git tasks add <content>` - Create task with flat ID
3. `git tasks list` - List all tasks
4. `git tasks done <id>` - Mark complete
5. `git tasks show <id>` - Show details

### Phase 2: Dependencies & Commit Linking
1. Add `--after <id>` flag to `git tasks add`
2. Implement `git tasks ready` (filters by dependency resolution)
3. Auto-link commits to tasks via `closed_commit` field
4. Add `git log --tasks` to show linked tasks

### Phase 3: Agent Integration & PR Export
1. Block `edit` and `delete` when `ZAGI_AGENT` is set
2. Add `--json` output format for all commands
3. Implement `git tasks pr` - markdown export for PR descriptions
4. Add `git tasks note` for append-only comments

### Phase 4: The Runner (`git tasks run`)
1. Implement basic loop: get ready task → spawn agent → wait → repeat
2. Add `--claude` runner (headless: `claude --print`)
3. Add `--opencode` runner (headless: `opencode run`)
4. Add `--runner` for custom commands (e.g., `aider --yes`)
5. Add `--model`, `--once`, `--dry-run`, `--delay`, `--max-tasks` flags
6. Implement failure tracking (skip after 3 failures)

### Phase 5: Polish
1. Push/pull refs with `git push origin refs/tasks/*:refs/tasks/*`
2. Handle branch deletion (cleanup orphan refs)
3. Add to AGENTS.md documentation

---

## Resolved Decisions

| Question | Decision |
|----------|----------|
| Dependencies | Yes, via `--after <id>` (single dependency per task) |
| Task IDs | Flat only (`task-xxxx`), no hierarchical subtasks |
| Commit linking | Automatic via `git tasks done` → next `git commit` |
| Storage | Git refs (`refs/tasks/<branch>`), not tracked files |
| PR export | `git tasks pr` command outputs markdown |

## Open Questions

1. **Cross-branch tasks**: Should tasks be branch-specific or shared across branches?

2. **Task cleanup**: When should completed tasks be archived/removed?

3. **Multiple dependencies**: Should we support multiple `--after` flags, or just one?

---

## Success Metrics

1. **Adoption**: Agents naturally use `git tasks` when given the command
2. **Immutability**: No agent modifications to task content observed
3. **PR Quality**: Reviewers report better context from task lists
4. **Loop Reliability**: Agent loops complete more tasks without losing context

---

## References

- [Beads by Steve Yegge](https://github.com/steveyegge/beads)
- [RALPH Driven Development by Luke Parker](https://lukeparker.dev/stop-chatting-with-ai-start-loops-ralph-driven-development)
- [Geoffrey Huntley's Ralph Wiggum Technique](https://ghuntley.com/ralph/)
