import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { writeFileSync, rmSync, chmodSync, existsSync } from "fs";
import { resolve } from "path";
import { createFixtureRepo } from "../fixtures/setup";
import { zagi } from "./shared";

let REPO_DIR: string;

beforeEach(() => {
  REPO_DIR = createFixtureRepo();
});

afterEach(() => {
  if (REPO_DIR) {
    rmSync(REPO_DIR, { recursive: true, force: true });
  }
});

// ============================================================================
// Helper: Create mock executor scripts
// ============================================================================

/**
 * Creates a mock executor script that always succeeds.
 * Returns the path to the script.
 */
function createSuccessExecutor(repoDir: string): string {
  const scriptPath = resolve(repoDir, "mock-success.sh");
  writeFileSync(scriptPath, "#!/bin/bash\nexit 0\n");
  chmodSync(scriptPath, 0o755);
  return scriptPath;
}

/**
 * Creates a mock executor script that always fails.
 * Returns the path to the script.
 */
function createFailureExecutor(repoDir: string): string {
  const scriptPath = resolve(repoDir, "mock-failure.sh");
  writeFileSync(scriptPath, "#!/bin/bash\nexit 1\n");
  chmodSync(scriptPath, 0o755);
  return scriptPath;
}

/**
 * Creates a mock executor script that fails N times, then succeeds.
 * Uses a counter file to track invocations.
 */
function createFlakeyExecutor(repoDir: string, failCount: number): string {
  const scriptPath = resolve(repoDir, "mock-flakey.sh");
  const counterPath = resolve(repoDir, "invoke-counter.txt");

  // Initialize counter
  writeFileSync(counterPath, "0");

  // Script increments counter and fails if count <= failCount
  const script = `#!/bin/bash
COUNTER_FILE="${counterPath}"
COUNT=$(cat "$COUNTER_FILE")
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER_FILE"
if [ "$COUNT" -le ${failCount} ]; then
  exit 1
fi
exit 0
`;
  writeFileSync(scriptPath, script);
  chmodSync(scriptPath, 0o755);
  return scriptPath;
}

/**
 * Creates a mock executor that marks the task as done.
 * This simulates a real agent completing its work.
 */
function createTaskCompletingExecutor(repoDir: string, zagiPath: string): string {
  const scriptPath = resolve(repoDir, "mock-complete.sh");
  // The prompt contains the task ID - extract and mark done
  // Format: "You are working on: task-XXX\n..."
  const script = `#!/bin/bash
PROMPT="$1"
TASK_ID=$(echo "$PROMPT" | head -1 | sed 's/You are working on: //')
${zagiPath} tasks done "$TASK_ID" > /dev/null 2>&1
exit 0
`;
  writeFileSync(scriptPath, script);
  chmodSync(scriptPath, 0o755);
  return scriptPath;
}

// ============================================================================
// Agent Run: Basic RALPH Loop Behavior
// ============================================================================

describe("zagi agent run RALPH loop", () => {
  test("exits immediately when no pending tasks", () => {
    const executor = createSuccessExecutor(REPO_DIR);

    const result = zagi(["agent", "run", "--once"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    expect(result).toContain("No pending tasks remaining");
    expect(result).toContain("All tasks complete");
  });

  test("runs single task with --once flag", () => {
    const executor = createSuccessExecutor(REPO_DIR);

    // Add a task
    zagi(["tasks", "add", "Test task one"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--once"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    expect(result).toContain("Starting task: task-001");
    expect(result).toContain("Task completed successfully");
    expect(result).toContain("Exiting after one task (--once flag set)");
  });

  test("processes multiple tasks in sequence", () => {
    // Use an executor that marks tasks done
    const zagiPath = resolve(__dirname, "../../zig-out/bin/zagi");
    const executor = createTaskCompletingExecutor(REPO_DIR, zagiPath);

    // Add multiple tasks
    zagi(["tasks", "add", "Task one"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Task two"], { cwd: REPO_DIR });

    // Tasks will be marked done, so both should be processed
    const result = zagi(["agent", "run", "--delay", "0"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    expect(result).toContain("Starting task: task-001");
    expect(result).toContain("Starting task: task-002");
    expect(result).toContain("2 tasks processed");
  });

  test("respects --max-tasks safety limit", () => {
    const executor = createSuccessExecutor(REPO_DIR);

    // Add more tasks than max
    zagi(["tasks", "add", "Task one"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Task two"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Task three"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--max-tasks", "2", "--delay", "0"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    expect(result).toContain("Reached maximum task limit (2)");
    expect(result).toContain("2 tasks processed");
  });
});

// ============================================================================
// Agent Run: Consecutive Failure Tracking
// ============================================================================

describe("zagi agent run consecutive failure counting", () => {
  test("tracks consecutive failures for same task", () => {
    const executor = createFailureExecutor(REPO_DIR);

    zagi(["tasks", "add", "Failing task"], { cwd: REPO_DIR });

    // Run with --max-tasks to limit iterations
    const result = zagi(["agent", "run", "--max-tasks", "5", "--delay", "0"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    // Should show increasing failure counts
    expect(result).toContain("Task failed (1 consecutive failures)");
    expect(result).toContain("Task failed (2 consecutive failures)");
    expect(result).toContain("Task failed (3 consecutive failures)");
    expect(result).toContain("Skipping task after 3 consecutive failures");
  });

  test("increments failure counter on each failure", () => {
    const executor = createFailureExecutor(REPO_DIR);

    zagi(["tasks", "add", "Will fail"], { cwd: REPO_DIR });

    // Run with enough iterations to see 3 failures
    const result = zagi(["agent", "run", "--max-tasks", "4", "--delay", "0"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    // Count failure messages
    const failureMatches = result.match(/Task failed \(\d+ consecutive failures\)/g);
    expect(failureMatches).toBeTruthy();
    expect(failureMatches!.length).toBe(3);
  });

  test("resets failure counter on success", () => {
    // Create a flakey executor that fails twice, then succeeds
    const executor = createFlakeyExecutor(REPO_DIR, 2);

    zagi(["tasks", "add", "Flakey task"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--max-tasks", "4", "--delay", "0"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    // Should fail twice, then succeed
    expect(result).toContain("Task failed (1 consecutive failures)");
    expect(result).toContain("Task failed (2 consecutive failures)");
    expect(result).toContain("Task completed successfully");

    // Should NOT show 3 failures - it recovered
    expect(result).not.toContain("Task failed (3 consecutive failures)");
  });
});

// ============================================================================
// Agent Run: Max Failures Exit Condition
// ============================================================================

describe("zagi agent run max failures exit condition", () => {
  test("skips task after 3 consecutive failures", () => {
    const executor = createFailureExecutor(REPO_DIR);

    zagi(["tasks", "add", "Broken task"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--delay", "0"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    expect(result).toContain("Skipping task after 3 consecutive failures");
    expect(result).toContain("All remaining tasks have failed 3+ times");
  });

  test("exits when all tasks exceed failure threshold", () => {
    const executor = createFailureExecutor(REPO_DIR);

    // Add multiple tasks - all will fail
    zagi(["tasks", "add", "Task one"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Task two"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--delay", "0"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    // Each task should fail 3 times
    expect(result).toContain("All remaining tasks have failed 3+ times");
    expect(result).toContain("RALPH loop completed");
  });

  test("continues with other tasks when one exceeds failure threshold", () => {
    // First task always fails, second task succeeds
    const failScript = createFailureExecutor(REPO_DIR);
    const successScript = createSuccessExecutor(REPO_DIR);

    // Create a script that fails for task-001 but succeeds for task-002
    const smartScript = resolve(REPO_DIR, "mock-smart.sh");
    writeFileSync(smartScript, `#!/bin/bash
PROMPT="$1"
if echo "$PROMPT" | grep -q "task-001"; then
  exit 1
fi
exit 0
`);
    chmodSync(smartScript, 0o755);

    zagi(["tasks", "add", "Will always fail"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Will succeed"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--max-tasks", "10", "--delay", "0"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: smartScript }
    });

    // First task should fail 3 times
    expect(result).toContain("Skipping task after 3 consecutive failures");

    // Second task should eventually be attempted and succeed
    expect(result).toContain("Starting task: task-002");
    expect(result).toContain("Task completed successfully");
  });

  test("uses exactly 3 as the failure threshold", () => {
    // Executor fails exactly twice, then succeeds
    const executor = createFlakeyExecutor(REPO_DIR, 2);

    zagi(["tasks", "add", "Recovers after 2 failures"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--max-tasks", "4", "--delay", "0"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    // Should succeed on third attempt (2 failures is below threshold)
    expect(result).toContain("Task completed successfully");
    expect(result).not.toContain("Skipping task after 3 consecutive failures");
  });
});

// ============================================================================
// Agent Run: Dry Run Mode
// ============================================================================

describe("zagi agent run --dry-run", () => {
  test("shows what would run without executing", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    // Use ZAGI_AGENT_CMD to avoid trying to run actual claude command
    const result = zagi(["agent", "run", "--dry-run", "--once"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: "echo" }
    });

    expect(result).toContain("dry-run mode");
    expect(result).toContain("Starting task: task-001");
    expect(result).toContain("Would execute:");
  });

  test("dry-run shows custom executor command", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--dry-run", "--once"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: "aider --yes" }
    });

    expect(result).toContain("Would execute:");
    expect(result).toContain("aider --yes");
  });

  test("dry-run respects --max-tasks", () => {
    zagi(["tasks", "add", "Task one"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Task two"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Task three"], { cwd: REPO_DIR });

    // Use ZAGI_AGENT_CMD to avoid validation issues
    const result = zagi(["agent", "run", "--dry-run", "--max-tasks", "2"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: "echo" }
    });

    // In dry-run mode without marking tasks done, it will keep looping on the same task
    // until max-tasks is reached
    expect(result).toContain("Starting task: task-001");
    expect(result).toContain("Reached maximum task limit (2)");
    expect(result).toContain("2 tasks processed");
  });
});

// ============================================================================
// Agent Run: Task Completion Integration
// ============================================================================

describe("zagi agent run task completion", () => {
  test("loops until tasks are marked done", () => {
    // Get the zagi binary path
    const zagiPath = resolve(__dirname, "../../zig-out/bin/zagi");
    const executor = createTaskCompletingExecutor(REPO_DIR, zagiPath);

    zagi(["tasks", "add", "Complete me"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--delay", "0"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    expect(result).toContain("Starting task: task-001");
    expect(result).toContain("Task completed successfully");
    expect(result).toContain("No pending tasks remaining");
    expect(result).toContain("All tasks complete");

    // Verify task is actually marked done (uses checkmark symbol)
    const listResult = zagi(["tasks", "list"], { cwd: REPO_DIR });
    expect(listResult).toContain("[✓] task-001");
    expect(listResult).toContain("(0 pending, 1 completed)");
  });

  test("processes all tasks until completion", () => {
    const zagiPath = resolve(__dirname, "../../zig-out/bin/zagi");
    const executor = createTaskCompletingExecutor(REPO_DIR, zagiPath);

    zagi(["tasks", "add", "First task"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Second task"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--delay", "0"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    expect(result).toContain("Starting task: task-001");
    expect(result).toContain("Starting task: task-002");
    expect(result).toContain("No pending tasks remaining");
    expect(result).toContain("2 tasks processed");

    // Verify both tasks done
    const listResult = zagi(["tasks", "list"], { cwd: REPO_DIR });
    expect(listResult).toContain("(0 pending, 2 completed)");
  });
});

// ============================================================================
// Agent Run: Error Handling
// ============================================================================

describe("zagi agent run error handling", () => {
  test("invalid ZAGI_AGENT value shows error", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "invalid-executor" }
    });

    expect(result).toContain("error: invalid ZAGI_AGENT value");
    expect(result).toContain("valid values: claude, opencode");
    expect(result).toContain("use ZAGI_AGENT_CMD for custom executors");
  });

  test("ZAGI_AGENT_CMD bypasses ZAGI_AGENT validation", () => {
    const executor = createSuccessExecutor(REPO_DIR);
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    // Even with invalid ZAGI_AGENT, custom cmd should work
    const result = zagi(["agent", "run", "--once"], {
      cwd: REPO_DIR,
      env: {
        ZAGI_AGENT: "invalid",
        ZAGI_AGENT_CMD: executor
      }
    });

    expect(result).toContain("Task completed successfully");
    expect(result).not.toContain("error: invalid ZAGI_AGENT");
  });
});
