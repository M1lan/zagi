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

// ============================================================================
// Agent Run: ZAGI_AGENT_CMD Override
// ============================================================================

/**
 * Creates a mock executor that logs all arguments to a file.
 * This allows us to verify exactly what arguments were passed.
 */
function createArgLoggingExecutor(repoDir: string): { script: string; logFile: string } {
  const scriptPath = resolve(repoDir, "mock-log-args.sh");
  const logFile = resolve(repoDir, "args.log");

  const script = `#!/bin/bash
# Log each argument on a separate line
for arg in "$@"; do
  echo "$arg" >> "${logFile}"
done
echo "---END---" >> "${logFile}"
exit 0
`;
  writeFileSync(scriptPath, script);
  chmodSync(scriptPath, 0o755);

  return { script: scriptPath, logFile };
}

/**
 * Creates an executor with multiple arguments that logs them.
 * Returns both the base command path and the args log file.
 */
function createMultiArgExecutor(repoDir: string): { script: string; logFile: string } {
  const scriptPath = resolve(repoDir, "mock-multi-arg.sh");
  const logFile = resolve(repoDir, "multi-args.log");

  // Script logs: the script name ($0), all args ($@), and arg count ($#)
  const script = `#!/bin/bash
echo "ARG_COUNT: $#" >> "${logFile}"
for arg in "$@"; do
  echo "ARG: $arg" >> "${logFile}"
done
exit 0
`;
  writeFileSync(scriptPath, script);
  chmodSync(scriptPath, 0o755);

  return { script: scriptPath, logFile };
}

describe("zagi agent run ZAGI_AGENT_CMD override", () => {
  test("uses custom command instead of default executor", () => {
    const { script, logFile } = createArgLoggingExecutor(REPO_DIR);

    zagi(["tasks", "add", "Test custom command"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--once"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: script }
    });

    expect(result).toContain("Task completed successfully");

    // Verify the custom script was called (log file exists and has content)
    const { readFileSync } = require("fs");
    const logContent = readFileSync(logFile, "utf-8");
    expect(logContent).toContain("---END---"); // Script was executed

    // The prompt should be passed as the argument
    expect(logContent).toContain("You are working on: task-001");
  });

  test("handles command with spaces and multiple arguments", () => {
    const { script, logFile } = createMultiArgExecutor(REPO_DIR);

    zagi(["tasks", "add", "Test multi-arg command"], { cwd: REPO_DIR });

    // Command with multiple space-separated arguments
    const result = zagi(["agent", "run", "--once"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: `${script} --yes --model gpt-4` }
    });

    expect(result).toContain("Task completed successfully");

    // Verify all arguments were passed correctly
    const { readFileSync } = require("fs");
    const logContent = readFileSync(logFile, "utf-8");

    // Should have: --yes, --model, gpt-4, and the prompt = 4 args
    expect(logContent).toContain("ARG_COUNT: 4");
    expect(logContent).toContain("ARG: --yes");
    expect(logContent).toContain("ARG: --model");
    expect(logContent).toContain("ARG: gpt-4");
    // The prompt is the last argument
    expect(logContent).toMatch(/ARG:.*You are working on: task-001/);
  });

  test("prompt is appended as final argument", () => {
    const { script, logFile } = createMultiArgExecutor(REPO_DIR);

    zagi(["tasks", "add", "Test prompt positioning"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--once"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: `${script} --first --second` }
    });

    expect(result).toContain("Task completed successfully");

    // Parse log to verify argument order
    const { readFileSync } = require("fs");
    const logContent = readFileSync(logFile, "utf-8");
    const lines = logContent.split("\n").filter((l: string) => l.startsWith("ARG: "));

    // Arguments should be: --first, --second, <prompt>
    expect(lines.length).toBe(3);
    expect(lines[0]).toBe("ARG: --first");
    expect(lines[1]).toBe("ARG: --second");
    expect(lines[2]).toContain("You are working on: task-001"); // Prompt is last
  });

  test("dry-run shows ZAGI_AGENT_CMD in output", () => {
    zagi(["tasks", "add", "Test dry-run display"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--dry-run", "--once"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: "my-custom-agent --verbose --timeout 30" }
    });

    expect(result).toContain("dry-run mode");
    expect(result).toContain("Would execute:");
    expect(result).toContain("my-custom-agent --verbose --timeout 30");
  });

  test("custom command overrides ZAGI_AGENT completely", () => {
    const { script, logFile } = createArgLoggingExecutor(REPO_DIR);

    zagi(["tasks", "add", "Test override"], { cwd: REPO_DIR });

    // Set both ZAGI_AGENT and ZAGI_AGENT_CMD - CMD should win
    const result = zagi(["agent", "run", "--once"], {
      cwd: REPO_DIR,
      env: {
        ZAGI_AGENT: "opencode",
        ZAGI_AGENT_CMD: script
      }
    });

    expect(result).toContain("Task completed successfully");

    // Verify our custom script was used (not opencode)
    const { readFileSync } = require("fs");
    const logContent = readFileSync(logFile, "utf-8");
    expect(logContent).toContain("---END---"); // Our script ran
    expect(logContent).toContain("You are working on:"); // Got the prompt
  });
});

// ============================================================================
// Agent Plan: ZAGI_AGENT_CMD Override
// ============================================================================

describe("zagi agent plan ZAGI_AGENT_CMD override", () => {
  test("dry-run shows custom command", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Test planning"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: "my-planner --interactive" }
    });

    expect(result).toContain("Planning Session (dry-run)");
    expect(result).toContain("Would execute:");
    expect(result).toContain("my-planner --interactive");
  });

  test("dry-run shows custom command with multiple args", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Build feature X"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: "aider --yes --model claude-3" }
    });

    expect(result).toContain("Would execute:");
    expect(result).toContain("aider --yes --model claude-3");
  });

  test("custom command is used instead of default", () => {
    const { script, logFile } = createArgLoggingExecutor(REPO_DIR);

    // This will actually execute the mock script
    const result = zagi(["agent", "plan", "Test planning execution"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: script }
    });

    expect(result).toContain("Starting Planning Session");
    expect(result).toContain("Planning session completed");

    // Verify script received the planning prompt
    const { readFileSync } = require("fs");
    const logContent = readFileSync(logFile, "utf-8");
    expect(logContent).toContain("You are a planning agent");
    expect(logContent).toContain("Test planning execution"); // The description
  });
});

// ============================================================================
// Error Conditions: Executor Not Found
// ============================================================================

describe("error conditions: executor not found", () => {
  test("agent run shows error when executor command not found", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    // Use a non-existent command
    const result = zagi(["agent", "run", "--once"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: "/nonexistent/command/that/does/not/exist" }
    });

    // Should show error about execution failure
    expect(result).toMatch(/error|fail|unable/i);
  });

  test("agent plan shows error when executor command not found", () => {
    // Use a non-existent command
    const result = zagi(["agent", "plan", "Test plan"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: "/nonexistent/command/that/does/not/exist" }
    });

    // Should show error about execution failure
    expect(result).toMatch(/error|fail/i);
  });

  test("agent run handles executor that exits with error code", () => {
    const failScript = createFailureExecutor(REPO_DIR);
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--once"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: failScript }
    });

    expect(result).toContain("Task failed (1 consecutive failures)");
  });

  test("agent run continues after executor failure with remaining tasks", () => {
    const failScript = createFailureExecutor(REPO_DIR);
    zagi(["tasks", "add", "Task 1"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Task 2"], { cwd: REPO_DIR });

    const result = zagi(["agent", "run", "--max-tasks", "4", "--delay", "0"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: failScript }
    });

    // Should attempt multiple tasks even when failing
    expect(result).toContain("Starting task:");
    expect(result).toContain("Task failed");
  });

  test("dry-run mode works even with non-existent executor", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    // Dry-run should succeed without trying to execute
    const result = zagi(["agent", "run", "--dry-run", "--once"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: "/nonexistent/command" }
    });

    expect(result).toContain("dry-run mode");
    expect(result).toContain("Would execute:");
    expect(result).toContain("Starting task: task-001");
    expect(result).not.toContain("error");
  });
});

// ============================================================================
// Error Conditions: No Tasks Exist (Agent Run)
// ============================================================================

describe("error conditions: no tasks exist (agent run)", () => {
  test("agent run shows helpful message when no tasks", () => {
    const executor = createSuccessExecutor(REPO_DIR);

    const result = zagi(["agent", "run"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    expect(result).toContain("No pending tasks remaining");
    expect(result).toContain("All tasks complete");
  });

  test("agent run with --once shows clear message when no tasks", () => {
    const executor = createSuccessExecutor(REPO_DIR);

    const result = zagi(["agent", "run", "--once"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    expect(result).toContain("No pending tasks remaining");
    expect(result).toContain("All tasks complete");
  });

  test("agent run suggests next action when no tasks", () => {
    const executor = createSuccessExecutor(REPO_DIR);

    const result = zagi(["agent", "run"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: executor }
    });

    // Should suggest viewing tasks with pr command
    expect(result).toContain("zagi tasks pr");
  });

  test("agent run dry-run shows no tasks message", () => {
    const result = zagi(["agent", "run", "--dry-run"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: "echo" }
    });

    expect(result).toContain("No pending tasks remaining");
  });
});
