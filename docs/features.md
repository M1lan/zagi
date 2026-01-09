# Features

## Implemented commands

### git status

Shows repository state in compact form.

```
branch: main (+2/-1 origin/main)

staged: 2 files
  A  new-file.txt
  M  modified.txt

modified: 1 file
  M  unstaged.txt

untracked: 3 files
```

Options:
- `<path>...` - filter to specific paths (e.g. `git status src/`)

### git log

Shows commit history, default 10 commits.

```
abc123f (2025-01-15) Alice: Add authentication
def456a (2025-01-14) Bob: Fix connection pool

[8 more commits, use -n to see more]
```

Options:
- `-n <count>` - number of commits to show
- `--author=<pattern>` - filter by author name or email
- `--grep=<pattern>` - filter by commit message
- `--since=<date>` - commits after date (e.g. "2025-01-01", "1 week ago")
- `--until=<date>` - commits before date
- `--prompts` - show AI prompts attached to commits
- `--agent` - show which AI agent made the commit
- `--session` - show session transcript (first 20k bytes)
- `--session-offset=N` - start session display at byte N
- `--session-limit=N` - limit session display to N bytes
- `-- <path>...` - filter to commits affecting paths

### git diff

Shows changes in minimal format.

```
src/main.zig:42
+ const new_line = true;
- const old_line = false;

src/other.zig:10-15
+ added block
+ of code
```

Options:
- `--staged` - show staged changes
- `--stat` - show diffstat (files changed, insertions, deletions)
- `--name-only` - show only names of changed files
- `<commit>` - diff against commit
- `<commit>..<commit>` - diff between commits
- `-- <path>` - filter to specific paths

### git add

Stages files and confirms what was staged.

```
staged: 3 files
  A  new-file.txt
  M  changed-file.txt
  M  another.txt
```

### git commit

Creates commit and shows stats.

```
committed: abc123f "Add new feature"
  3 files, +45 -12
```

Options:
- `-m <message>` - commit message (required)
- `-a` - stage modified tracked files
- `--amend` - amend previous commit
- `--prompt <text>` - store AI prompt (see Agent features)

## Agent features

### git fork

Manage parallel working copies for experimentation.

```bash
git fork feature-a          # create fork in .forks/feature-a/
git fork                     # list forks with commit counts
git fork --pick feature-a    # merge fork into base (safe)
git fork --promote feature-a # hard checkout fork to base (destructive)
git fork --delete feature-a
git fork --delete-all
```

Forks are git worktrees. The `.forks/` directory is auto-added to `.gitignore`.

**Picking vs Promoting:**
- `--pick` performs a proper git merge, preserving both base and fork history
- `--promote` moves HEAD to the fork's commit, discarding any base-only commits (stash uncommitted changes first)

### --prompt (AI Attribution)

Store the user prompt and AI metadata with a commit:

```bash
git commit -m "Add feature" --prompt "Add a logout button to the header"
```

When `--prompt` is used, zagi stores metadata in git notes:
- `refs/notes/agent` - detected AI agent (claude, opencode, cursor, etc.)
- `refs/notes/prompt` - the user prompt text
- `refs/notes/session` - full session transcript (Claude Code, OpenCode)

View with log flags:
```bash
git log --prompts   # show prompts (truncated to 200 chars)
git log --agent     # show agent name
git log --session   # show session transcript (paginated)
git log --session --session-limit=1000  # first 1000 bytes
git log --session --session-offset=1000 # start at byte 1000
```

Git notes are local by default and don't modify commit history.

### Agent Mode

Agent mode is automatically enabled when running inside AI tools:
- Claude Code (`CLAUDECODE=1`)
- OpenCode (`OPENCODE=1`)
- VS Code, Cursor, Windsurf (detected from `VSCODE_GIT_ASKPASS_NODE`)

You can also enable it manually:
```bash
export ZAGI_AGENT=my-agent
```

When agent mode is active:
- `git commit` requires `--prompt` to record the user request
- Destructive commands are blocked (guardrails)

```bash
git commit -m "x"  # error: --prompt required in agent mode
```

### ZAGI_STRIP_COAUTHORS

Remove `Co-Authored-By:` lines from commit messages:

```bash
export ZAGI_STRIP_COAUTHORS=1
git commit -m "Add feature

Co-Authored-By: Claude <claude@anthropic.com>"
# commits as: "Add feature"
```

## Passthrough

Any command not implemented passes through to git:

```bash
git push           # runs git push
git pull           # runs git pull
git rebase -i      # runs git rebase -i
```

Use `-g` to force passthrough for implemented commands:

```bash
git -g log         # runs git log (full output)
git -g status      # runs git status (full output)
```

## Shell alias

The `zagi alias` command sets up git as an alias:

```bash
zagi alias         # adds alias to shell config
zagi alias --print # prints alias without adding
```

Supported shells: bash, zsh, fish, powershell
