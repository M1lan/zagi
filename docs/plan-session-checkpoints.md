# Session Checkpoints & Markdown Formatting

## Problem

Currently, `git commit --prompt` dumps the **entire** session transcript (often 3+ MB) for every commit. If a session has multiple commits, each commit stores redundant data and doesn't show what specifically led to that commit.

## Goal

1. **Delta storage**: Only store session entries since the last commit
2. **Markdown formatting**: Format transcripts as collapsible GitHub-flavored markdown
3. **Git-native**: No hooks required, use git notes for checkpointing

## Design

### Checkpoint Storage

After each `git commit --prompt`, store the last message UUID in a checkpoint note:

```
refs/notes/session-checkpoint
  └── <commit-oid> → "<last-message-uuid>"
```

On the next commit:
1. Get parent commit's checkpoint (last message UUID)
2. Read session entries from checkpoint → current
3. Store only the delta in `refs/notes/session`
4. Update checkpoint with new last message UUID

### Session JSONL Structure (Claude Code)

Each line in `~/.claude/projects/{hash}/{session}.jsonl`:

```json
{
  "uuid": "ce822e5e-189e-4a89-9013-25cb3fecda16",
  "timestamp": "2026-01-02T20:02:03.191Z",
  "type": "user",
  "message": {
    "role": "user",
    "content": "Add a logout button..."
  }
}
```

Entry types to include:
- `user` - user messages (always include)
- `assistant` - assistant responses (include text content)
- Tool use results can be summarized (e.g., "Read 5 files, Edited 3 files")

Entry types to skip:
- `summary` - internal summaries (Claude's context compression)
- `queue-operation` - internal operations

### Markdown Output Format

```markdown
<details>
<summary>Session transcript (12 messages, 2026-01-09 13:18 - 14:32)</summary>

### User _(13:18)_
Add a logout button to the header. When clicked it should clear the session and redirect to /login.

### Assistant _(13:19)_
I'll add a logout button to the header component. Let me first read the current Header implementation.

**Tools used:** Read `src/Header.tsx`

### User _(13:22)_
Make it red

### Assistant _(13:23)_
I'll update the button styling to use red.

**Tools used:** Edit `src/Header.tsx`

</details>
```

Features:
- Collapsible by default (doesn't clutter PR descriptions)
- Human-readable timestamps
- User/Assistant clearly labeled
- Tool calls summarized (not full input/output)
- Time range in summary

### Data Flow

```
git commit -m "msg" --prompt "user prompt"
    │
    ▼
┌─────────────────────────────────────────────┐
│ 1. Get parent commit's checkpoint UUID      │
│    (from refs/notes/session-checkpoint)     │
└─────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────┐
│ 2. Read session file, filter entries:       │
│    - Skip entries before checkpoint UUID    │
│    - Skip summary/queue-operation types     │
│    - Keep user/assistant messages           │
└─────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────┐
│ 3. Format as markdown:                      │
│    - Wrap in <details> tag                  │
│    - Format each message with role/time     │
│    - Summarize tool calls                   │
└─────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────┐
│ 4. Store in git notes:                      │
│    - refs/notes/session → markdown          │
│    - refs/notes/session-checkpoint → UUID   │
└─────────────────────────────────────────────┘
```

### Edge Cases

| Case | Handling |
|------|----------|
| First commit (no parent) | Store entire session from start |
| No checkpoint on parent | Store entire session from start |
| Checkpoint UUID not found in session | Session was cleared/rotated; store from start |
| Empty delta (no new messages) | Store minimal note: "No new session activity" |
| Very long messages | Truncate to 2000 chars with "..." |
| Multiple commits same second | UUID-based, not timestamp-based, so fine |

### File Changes

#### 1. `src/cmds/detect.zig`

Add new functions:

```zig
/// Session entry for checkpoint tracking
pub const SessionEntry = struct {
    uuid: []const u8,
    timestamp: []const u8,
    entry_type: []const u8,  // "user", "assistant", "tool_use", etc.
    role: ?[]const u8,       // "user" or "assistant"
    content: ?[]const u8,    // message content
    tool_name: ?[]const u8,  // for tool_use entries
};

/// Read session entries as structured data (not raw JSON)
pub fn readSessionEntries(
    allocator: std.mem.Allocator,
    agent: Agent,
    cwd: []const u8,
) ?[]SessionEntry;

/// Read session entries after a specific UUID checkpoint
pub fn readSessionEntriesAfter(
    allocator: std.mem.Allocator,
    agent: Agent,
    cwd: []const u8,
    after_uuid: ?[]const u8,  // null = from start
) ?[]SessionEntry;

/// Format session entries as GitHub-flavored markdown
pub fn formatSessionMarkdown(
    allocator: std.mem.Allocator,
    entries: []const SessionEntry,
) ![]const u8;
```

#### 2. `src/cmds/commit.zig`

Update session storage logic:

```zig
// Current (stores raw JSON array):
const session = detect.readCurrentSession(allocator, agent, cwd);
// Store session.transcript in refs/notes/session

// New (stores markdown delta):
const checkpoint_uuid = readCheckpointUuid(repo, parent_commit);
const entries = detect.readSessionEntriesAfter(allocator, agent, cwd, checkpoint_uuid);
const markdown = detect.formatSessionMarkdown(allocator, entries);
// Store markdown in refs/notes/session
// Store last entry's UUID in refs/notes/session-checkpoint
```

#### 3. `src/cmds/log.zig`

Update `--session` display:
- If content starts with `<details>`, it's already markdown - display as-is
- Otherwise (legacy raw JSON), display with byte pagination as before

### Implementation Steps

1. **Parse JSONL to structured entries** (~100 lines)
   - Add `SessionEntry` struct to detect.zig
   - Add `parseSessionEntry()` to extract fields from JSON line
   - Add `readSessionEntries()` to read all entries

2. **Filter entries by checkpoint** (~50 lines)
   - Add `readSessionEntriesAfter()`
   - Find entry with matching UUID, return entries after it
   - Handle "not found" by returning all entries

3. **Format as markdown** (~150 lines)
   - Add `formatSessionMarkdown()`
   - Generate `<details>` wrapper with summary
   - Format user/assistant messages
   - Summarize tool calls (count by type)

4. **Checkpoint storage in commit.zig** (~30 lines)
   - Read parent's checkpoint from `refs/notes/session-checkpoint`
   - After commit, write new checkpoint with last entry UUID

5. **Update log.zig for markdown** (~20 lines)
   - Detect markdown format (starts with `<details>`)
   - Display markdown directly (it's already human-readable)

6. **Tests** (~100 lines)
   - Test JSONL parsing
   - Test checkpoint filtering
   - Test markdown formatting
   - Integration test: multiple commits show deltas

### Estimated Complexity

| Component | Lines | Complexity |
|-----------|-------|------------|
| JSONL parsing | ~100 | Medium (JSON parsing in Zig) |
| Entry filtering | ~50 | Low |
| Markdown formatting | ~150 | Medium |
| Checkpoint read/write | ~30 | Low |
| Log.zig updates | ~20 | Low |
| Tests | ~100 | Low |
| **Total** | **~450** | **Medium** |

### JSON Parsing Approach

Zig's `std.json` can parse arbitrary JSON. For each JSONL line:

```zig
const parsed = std.json.parseFromSlice(
    struct {
        uuid: []const u8,
        timestamp: []const u8,
        type: []const u8,
        message: ?struct {
            role: ?[]const u8,
            content: ?[]const u8,
        },
    },
    allocator,
    line,
    .{ .ignore_unknown_fields = true },
);
```

### OpenCode Support

OpenCode uses a different storage format (individual JSON files per message). The same pattern applies:
1. Parse each message file
2. Filter by timestamp or message ID
3. Format as markdown

This can be implemented as a follow-up since Claude Code is the priority.

### Migration / Backwards Compatibility

- **Reading**: `git log --session` detects format:
  - Starts with `<details>` → new markdown format, display as-is
  - Starts with `[` → old JSON array format, use byte pagination
- **Writing**: Always writes new markdown format
- **Checkpoints**: Missing checkpoint = store full session (safe default)

### Future Enhancements (Not in this PR)

1. **Model extraction**: Parse model name from session and add to markdown header
2. **Cost tracking**: Sum token usage from session entries
3. **PR description integration**: Command to copy session markdown to clipboard
4. **Configurable verbosity**: `--session=full` vs `--session=summary`
