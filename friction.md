# Friction Log

Issues encountered while developing zagi agent functionality.

## Critical Issues

### 1. Segfault in consecutive_failures hashmap
**Status:** Fixed in commit 955d70d
**Issue:** Use-after-free bug in `agent.zig` when storing task IDs in hashmap
**Root cause:** `task.id` memory was freed in defer block but hashmap kept reference
**Fix:** Duplicate the key before storing in hashmap

### 2. ZAGI_AGENT=1 treated as executor name
**Status:** Open
**Issue:** When ZAGI_AGENT is set to "1" (boolean-style), it's used literally as executor name
**Expected:** Should error or default to "claude"
**Workaround:** Set `ZAGI_AGENT=claude` explicitly

### 3. Agent run internally uses relative path `./zig-out/bin/zagi`
**Status:** Open
**Issue:** `getPendingTasks()` shells out to `./zig-out/bin/zagi tasks list --json` with relative path
**Impact:** Agent can only run from repo root directory
**Impact:** Integration tests fail when running from fixture directories
**Fix needed:** Use absolute path or find binary relative to executable

## Test Infrastructure Issues

### 4. Tests reference removed features
**Status:** Partially fixed
**Issue:** Tests still reference `--after` flag and `ready` command which were removed
**Fix:** Update tests to match current implementation

### 5. Memory leaks in tasks.zig
**Status:** Open
**Issue:** Tests show memory leaks in `runAdd` when allocating task content
**Location:** `_cmds.tasks.runAdd` → `_fmt.allocPrint` → `toOwnedSlice`
**Impact:** Memory leaks during task creation

## API Design Issues

### 6. No validation of ZAGI_AGENT values
**Status:** Open
**Issue:** Invalid executor values like "1" silently used as custom command
**Expected:** Validate against known executors or error clearly

### 7. Agent prompt path hardcoded
**Status:** Open
**Issue:** Task completion instruction uses `./zig-out/bin/zagi tasks done`
**Impact:** Won't work if binary is installed elsewhere

## Suggestions

1. **Use absolute paths:** Resolve binary path at startup
2. **Validate env vars:** Check ZAGI_AGENT is "claude", "opencode", or empty
3. **Better error messages:** Indicate what went wrong with task loading
4. **Memory management:** Audit allocations in tasks.zig
