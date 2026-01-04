# Friction Log

Issues encountered while developing zagi agent functionality.

## Critical Issues

### 1. Segfault in consecutive_failures hashmap
**Status:** Fixed in commit b12ab5c
**Issue:** Use-after-free bug in `agent.zig` when storing task IDs in hashmap
**Root cause:** `task.id` memory was freed in defer block but hashmap kept reference
**Fix:** Duplicate the key before storing in hashmap
**Location:** `src/cmds/agent.zig:429-438`

### 2. ZAGI_AGENT=1 treated as executor name
**Status:** Fixed
**Issue:** When ZAGI_AGENT is set to "1" (boolean-style), it's used literally as executor name
**Fix:** Added `getValidatedExecutor()` that validates against known values ("claude", "opencode")
**Location:** `src/cmds/agent.zig:74-89`

### 3. Agent run internally uses relative path `./zig-out/bin/zagi`
**Status:** Open (task-012)
**Issue:** `getPendingTasks()` shells out to `./zig-out/bin/zagi tasks list --json` with relative path
**Impact:** Agent can only run from repo root directory
**Impact:** Integration tests fail when running from fixture directories
**Fix needed:** Use absolute path or find binary relative to executable
**Location:** `src/cmds/agent.zig:476`

## Memory Management Issues

### 4. Memory leaks in tasks.zig
**Status:** Open (task-013)
**Issue:** Memory leaks in `runAdd` when allocating task content
**Location:** `src/cmds/tasks.zig` - allocations via `toOwnedSlice` not properly freed
**Impact:** Memory leaks during repeated task creation

### 5. Hashmap key ownership
**Status:** Fixed
**Issue:** Keys stored in hashmap must outlive their usage
**Learning:** In Zig, always `allocator.dupe()` strings before storing in containers that outlive the source

## API Design Issues

### 6. No validation of ZAGI_AGENT values
**Status:** Fixed (see #2)
**Issue:** Invalid executor values like "1" silently used as custom command
**Fix:** `getValidatedExecutor()` validates and returns clear error for invalid values

### 7. Agent prompt path hardcoded
**Status:** Open (task-014)
**Issue:** Task completion instruction uses `./zig-out/bin/zagi tasks done`
**Impact:** Won't work if binary is installed elsewhere
**Location:** `src/cmds/agent.zig:108,118,518`
**Also:** Planning prompt at line 108, 118

### 8. JSON escaping was broken
**Status:** Fixed in commit be3156a
**Issue:** Task content with special characters (quotes, newlines) broke JSON output
**Fix:** Added `escapeJsonString()` function in tasks.zig
**Location:** `src/cmds/tasks.zig:7-32`

## Test Infrastructure Issues

### 9. Tests referenced removed features
**Status:** Fixed
**Issue:** Tests still referenced `--after` flag and `ready` command which were removed
**Fix:** Updated tests to match current implementation

### 10. Slow bun test performance
**Status:** Open (task-064)
**Issue:** Test suite takes too long - process spawning overhead
**Suggestion:** Migrate more tests to native Zig tests (task-065)

## Suggestions for Future Work

1. **Use absolute paths:** Resolve binary path at startup using `std.fs.selfExePath()`
2. **Validate env vars:** Check ZAGI_AGENT is "claude", "opencode", or empty
3. **Better error messages:** Indicate what went wrong with task loading
4. **Memory management audit:** Review all `toOwnedSlice` calls for proper cleanup
5. **Integration test isolation:** Run tests in temp directories with absolute paths
