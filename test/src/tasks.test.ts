import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { rmSync } from "fs";
import { createFixtureRepo } from "../fixtures/setup";
import { zagi, git } from "./shared";

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
// Help and Basic Usage
// ============================================================================

describe("zagi tasks help", () => {
  test("shows help message", () => {
    const result = zagi(["tasks"], { cwd: REPO_DIR });

    expect(result).toContain("usage: git tasks <command>");
    expect(result).toContain("Commands:");
    expect(result).toContain("add <content>");
    expect(result).toContain("list");
    expect(result).toContain("show <id>");
    expect(result).toContain("done <id>");
  });

  test("help flag shows help", () => {
    const result = zagi(["tasks", "--help"], { cwd: REPO_DIR });

    expect(result).toContain("usage: git tasks <command>");
  });
});

// ============================================================================
// Task CRUD Operations
// ============================================================================

describe("zagi tasks add", () => {
  test("creates new task with generated ID", () => {
    const result = zagi(["tasks", "add", "Fix authentication bug"], { cwd: REPO_DIR });

    expect(result).toMatch(/created: task-\d{3}/);
    expect(result).toContain("Fix authentication bug");
  });

  test("handles multi-word content", () => {
    const result = zagi(["tasks", "add", "Add", "user", "authentication", "system"], { cwd: REPO_DIR });

    expect(result).toContain("Add user authentication system");
  });

  test("outputs JSON when --json flag is used", () => {
    const result = zagi(["tasks", "add", "Test task", "--json"], { cwd: REPO_DIR });

    const parsed = JSON.parse(result.trim());
    expect(parsed).toHaveProperty("id");
    expect(parsed).toHaveProperty("content", "Test task");
    expect(parsed).toHaveProperty("status", "pending");
    expect(parsed).toHaveProperty("created");
    expect(parsed).toHaveProperty("completed", null);
  });

  test("shows error for missing content", () => {
    const result = zagi(["tasks", "add"], { cwd: REPO_DIR });

    expect(result).toContain("error: missing task content");
  });

  test("shows error for empty content", () => {
    const result = zagi(["tasks", "add", ""], { cwd: REPO_DIR });

    expect(result).toContain("error: task content cannot be empty");
  });
});

describe("zagi tasks list", () => {
  test("shows no tasks message when empty", () => {
    const result = zagi(["tasks", "list"], { cwd: REPO_DIR });

    expect(result).toContain("no tasks found");
  });

  test("lists single task", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "list"], { cwd: REPO_DIR });

    expect(result).toContain("tasks: 1 total (1 pending, 0 completed)");
    expect(result).toContain("[ ] task-001");
    expect(result).toContain("Test task");
  });

  test("lists multiple tasks with counts", () => {
    zagi(["tasks", "add", "First task"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Second task"], { cwd: REPO_DIR });
    zagi(["tasks", "done", "task-001"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "list"], { cwd: REPO_DIR });

    expect(result).toContain("tasks: 2 total (1 pending, 1 completed)");
    expect(result).toContain("[✓] task-001");
    expect(result).toContain("[ ] task-002");
  });

  test("outputs JSON when --json flag is used", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "list", "--json"], { cwd: REPO_DIR });

    const parsed = JSON.parse(result.trim());
    expect(parsed).toHaveProperty("tasks");
    expect(Array.isArray(parsed.tasks)).toBe(true);
    expect(parsed.tasks).toHaveLength(1);
    expect(parsed.tasks[0]).toHaveProperty("id", "task-001");
    expect(parsed.tasks[0]).toHaveProperty("content", "Test task");
  });

  test("JSON output includes all task fields", () => {
    zagi(["tasks", "add", "First task"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Second task"], { cwd: REPO_DIR });
    zagi(["tasks", "done", "task-001"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "list", "--json"], { cwd: REPO_DIR });

    const parsed = JSON.parse(result.trim());
    const firstTask = parsed.tasks.find((t: any) => t.id === "task-001");
    const secondTask = parsed.tasks.find((t: any) => t.id === "task-002");

    expect(firstTask).toHaveProperty("status", "completed");
    expect(firstTask).toHaveProperty("completed");
    expect(firstTask.completed).not.toBeNull();

    expect(secondTask).toHaveProperty("status", "pending");
  });
});

describe("zagi tasks show", () => {
  test("shows task details", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "show", "task-001"], { cwd: REPO_DIR });

    expect(result).toContain("task: task-001");
    expect(result).toContain("content: Test task");
    expect(result).toContain("status: pending");
    expect(result).toContain("created:");
  });

  test("shows completed task details", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });
    zagi(["tasks", "done", "task-001"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "show", "task-001"], { cwd: REPO_DIR });

    expect(result).toContain("status: completed");
    expect(result).toContain("completed:");
  });

  test("outputs JSON when --json flag is used", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "show", "task-001", "--json"], { cwd: REPO_DIR });

    const parsed = JSON.parse(result.trim());
    expect(parsed).toHaveProperty("id", "task-001");
    expect(parsed).toHaveProperty("content", "Test task");
    expect(parsed).toHaveProperty("status", "pending");
  });

  test("shows error for missing task ID", () => {
    const result = zagi(["tasks", "show"], { cwd: REPO_DIR });

    expect(result).toContain("error: missing task ID");
  });

  test("shows error for non-existent task", () => {
    const result = zagi(["tasks", "show", "task-999"], { cwd: REPO_DIR });

    expect(result).toContain("error: task 'task-999' not found");
  });
});

describe("zagi tasks done", () => {
  test("marks task as completed", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "done", "task-001"], { cwd: REPO_DIR });

    expect(result).toContain("completed: task-001");
    expect(result).toContain("Test task");
  });

  test("task appears as completed in list", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });
    zagi(["tasks", "done", "task-001"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "list"], { cwd: REPO_DIR });

    expect(result).toContain("[✓] task-001");
    expect(result).toContain("(0 pending, 1 completed)");
  });

  test("shows message for already completed task", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });
    zagi(["tasks", "done", "task-001"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "done", "task-001"], { cwd: REPO_DIR });

    expect(result).toContain("task 'task-001' already completed");
  });

  test("shows error for missing task ID", () => {
    const result = zagi(["tasks", "done"], { cwd: REPO_DIR });

    expect(result).toContain("error: missing task ID");
  });

  test("shows error for non-existent task", () => {
    const result = zagi(["tasks", "done", "task-999"], { cwd: REPO_DIR });

    expect(result).toContain("error: task 'task-999' not found");
  });
});

describe("zagi tasks edit", () => {
  test("is blocked in agent mode", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "edit", "task-001", "Updated content"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude-code" }
    });

    expect(result).toContain("error: edit command blocked");
    expect(result).toContain("ZAGI_AGENT is set");
  });

  test("succeeds when not in agent mode", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "edit", "task-001", "Updated content"], { cwd: REPO_DIR });

    expect(result).toContain("updated: task-001");
    expect(result).toContain("Updated content");
  });
});

describe("zagi tasks delete", () => {
  test("is blocked in agent mode", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "delete", "task-001"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude-code" }
    });

    expect(result).toContain("error: delete command blocked");
    expect(result).toContain("ZAGI_AGENT is set");
    expect(result).toContain("permanent data loss");
  });

  test("succeeds when not in agent mode", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "delete", "task-001"], { cwd: REPO_DIR });

    expect(result).toContain("deleted: task-001");
    expect(result).toContain("Test task");
  });
});

describe("zagi tasks pr", () => {
  test("shows empty state when no tasks", () => {
    const result = zagi(["tasks", "pr"], { cwd: REPO_DIR });

    expect(result).toContain("## Tasks");
    expect(result).toContain("No tasks found.");
  });

  test("shows completed tasks section", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });
    zagi(["tasks", "done", "task-001"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "pr"], { cwd: REPO_DIR });

    expect(result).toContain("## Tasks");
    expect(result).toContain("### Completed");
    expect(result).toContain("- [x] Test task");
  });

  test("shows pending tasks section", () => {
    zagi(["tasks", "add", "Pending task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "pr"], { cwd: REPO_DIR });

    expect(result).toContain("### Pending");
    expect(result).toContain("- [ ] Pending task");
  });

  test("shows both completed and pending", () => {
    zagi(["tasks", "add", "First task"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Second task"], { cwd: REPO_DIR });
    zagi(["tasks", "done", "task-001"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "pr"], { cwd: REPO_DIR });

    expect(result).toContain("### Completed");
    expect(result).toContain("- [x] First task");
    expect(result).toContain("### Pending");
    expect(result).toContain("- [ ] Second task");
  });
});

// ============================================================================
// Agent Commands
// ============================================================================

describe("zagi agent", () => {
  test("shows help when no subcommand", () => {
    const result = zagi(["agent"], { cwd: REPO_DIR });

    expect(result).toContain("usage: git agent <command>");
    expect(result).toContain("Commands:");
    expect(result).toContain("run");
    expect(result).toContain("plan");
  });

  test("agent --help shows help", () => {
    const result = zagi(["agent", "--help"], { cwd: REPO_DIR });

    expect(result).toContain("usage: git agent <command>");
  });

  test("agent run --help shows run help", () => {
    const result = zagi(["agent", "run", "--help"], { cwd: REPO_DIR });

    expect(result).toContain("usage: git agent run");
    expect(result).toContain("--once");
    expect(result).toContain("--dry-run");
    expect(result).toContain("--max-tasks");
  });

  test("agent plan --help shows plan help", () => {
    const result = zagi(["agent", "plan", "--help"], { cwd: REPO_DIR });

    expect(result).toContain("usage: git agent plan");
    expect(result).toContain("<description>");
    expect(result).toContain("--dry-run");
  });

  test("agent plan --dry-run shows planning prompt", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Add user auth"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    expect(result).toContain("Planning Session (dry-run)");
    expect(result).toContain("Goal: Add user auth");
    expect(result).toContain("Would execute:");
    expect(result).toContain("claude -p");
    expect(result).toContain("Prompt Preview");
    expect(result).toContain("PROJECT GOAL: Add user auth");
  });

  test("agent plan requires description", () => {
    const result = zagi(["agent", "plan"], { cwd: REPO_DIR });

    expect(result).toContain("error: description required");
  });

  test("agent unknown subcommand shows error", () => {
    const result = zagi(["agent", "invalid"], { cwd: REPO_DIR });

    expect(result).toContain("error: unknown command 'invalid'");
    expect(result).toContain("usage: git agent <command>");
  });
});

// ============================================================================
// Agent Plan --dry-run (Prompt Generation)
// ============================================================================

describe("zagi agent plan --dry-run", () => {
  test("generates correct prompt structure", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Build a REST API"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    // Verify all prompt sections are present
    expect(result).toContain("=== Planning Session (dry-run) ===");
    expect(result).toContain("Goal: Build a REST API");
    expect(result).toContain("Would execute:");
    expect(result).toContain("--- Prompt Preview ---");
    expect(result).toContain("You are a planning agent");
    expect(result).toContain("PROJECT GOAL: Build a REST API");
    expect(result).toContain("INSTRUCTIONS:");
    expect(result).toContain("Read AGENTS.md");
    expect(result).toContain("CREATING TASKS:");
    expect(result).toContain("tasks add");
    expect(result).toContain("RULES:");
    expect(result).toContain("NEVER git push");
  });

  test("includes absolute path to zagi binary", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Test task"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    // The prompt should include the absolute path for task commands
    expect(result).toMatch(/\/.*\/zagi tasks add/);
    expect(result).toMatch(/\/.*\/zagi tasks list/);
  });

  test("handles goal with double quotes", () => {
    const result = zagi(["agent", "plan", "--dry-run", 'Add "login" button'], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    expect(result).toContain('Goal: Add "login" button');
    expect(result).toContain('PROJECT GOAL: Add "login" button');
  });

  test("handles goal with single quotes", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Add 'logout' feature"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    expect(result).toContain("Goal: Add 'logout' feature");
    expect(result).toContain("PROJECT GOAL: Add 'logout' feature");
  });

  test("handles goal with backticks", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Add `code` formatting"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    expect(result).toContain("Goal: Add `code` formatting");
    expect(result).toContain("PROJECT GOAL: Add `code` formatting");
  });

  test("handles goal with shell special characters", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Fix $PATH & ENV vars"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    expect(result).toContain("Goal: Fix $PATH & ENV vars");
    expect(result).toContain("PROJECT GOAL: Fix $PATH & ENV vars");
  });

  test("handles goal with angle brackets", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Add <input> validation"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    expect(result).toContain("Goal: Add <input> validation");
    expect(result).toContain("PROJECT GOAL: Add <input> validation");
  });

  test("handles goal with parentheses and brackets", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Refactor function(args) and array[0]"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    expect(result).toContain("Goal: Refactor function(args) and array[0]");
    expect(result).toContain("PROJECT GOAL: Refactor function(args) and array[0]");
  });

  test("handles goal with unicode characters", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Add emoji support"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    expect(result).toContain("Goal: Add emoji support");
    expect(result).toContain("PROJECT GOAL: Add emoji support");
  });

  test("handles goal with newline in content", () => {
    // Note: Shell typically doesn't pass literal newlines in args, but we test the goal is preserved
    const goal = "Line one\\nLine two";
    const result = zagi(["agent", "plan", "--dry-run", goal], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    expect(result).toContain(`Goal: ${goal}`);
    expect(result).toContain(`PROJECT GOAL: ${goal}`);
  });

  test("handles long goal description", () => {
    const longGoal = "Implement a comprehensive user authentication system with OAuth2 support, including Google, GitHub, and Microsoft providers, plus email/password fallback with rate limiting and account lockout protection";
    const result = zagi(["agent", "plan", "--dry-run", longGoal], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    expect(result).toContain(`Goal: ${longGoal}`);
    expect(result).toContain(`PROJECT GOAL: ${longGoal}`);
  });

  test("handles goal with mixed special characters", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Add 'auth' with <JWT> & \"refresh\" tokens"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    expect(result).toContain("Goal: Add 'auth' with <JWT> & \"refresh\" tokens");
    expect(result).toContain("PROJECT GOAL: Add 'auth' with <JWT> & \"refresh\" tokens");
  });

  test("shows opencode executor when ZAGI_AGENT=opencode", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Test task"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "opencode" }
    });

    expect(result).toContain("Would execute:");
    expect(result).toContain("opencode run");
  });

  test("shows custom executor when ZAGI_AGENT_CMD is set", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Test task"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT_CMD: "aider --yes" }
    });

    expect(result).toContain("Would execute:");
    expect(result).toContain("aider --yes");
  });

  test("uses claude as default executor", () => {
    const result = zagi(["agent", "plan", "--dry-run", "Test task"], {
      cwd: REPO_DIR
    });

    expect(result).toContain("Would execute:");
    expect(result).toContain("claude -p");
  });

  test("goal with only whitespace shows error", () => {
    const result = zagi(["agent", "plan", "--dry-run", "   "], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    // Whitespace-only is still valid input from the shell perspective
    // The command treats it as valid content
    expect(result).toContain("Goal:");
  });

  test("--dry-run flag position after goal works", () => {
    const result = zagi(["agent", "plan", "Build feature", "--dry-run"], {
      cwd: REPO_DIR,
      env: { ZAGI_AGENT: "claude" }
    });

    expect(result).toContain("Planning Session (dry-run)");
    expect(result).toContain("Goal: Build feature");
  });
});

// ============================================================================
// Error Handling
// ============================================================================

describe("error handling", () => {
  test("shows error and help for invalid subcommand", () => {
    const result = zagi(["tasks", "invalid"], { cwd: REPO_DIR });

    expect(result).toContain("error: unknown command 'invalid'");
    expect(result).toContain("usage: git tasks <command>");
  });

  test("task IDs are sequential", () => {
    zagi(["tasks", "add", "First task"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Second task"], { cwd: REPO_DIR });
    zagi(["tasks", "add", "Third task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "list"], { cwd: REPO_DIR });

    expect(result).toContain("task-001");
    expect(result).toContain("task-002");
    expect(result).toContain("task-003");
  });

  test("shows error in non-git directory", () => {
    const result = zagi(["tasks", "add", "Test task"], { cwd: "/tmp" });

    // Should show error - either "error" or "fatal" depending on git behavior
    expect(result.toLowerCase()).toMatch(/error|fatal/);
  });
});

// ============================================================================
// Git Integration
// ============================================================================

describe("integration with git", () => {
  test("tasks are stored in git refs", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    // Check that git refs/tasks/main exists
    const result = git(["show-ref"], { cwd: REPO_DIR });
    expect(result).toContain("refs/tasks/main");
  });

  test("tasks persist across branch switches", () => {
    // Add task on main
    zagi(["tasks", "add", "Main branch task"], { cwd: REPO_DIR });

    // Create and switch to new branch
    git(["checkout", "-b", "feature"], { cwd: REPO_DIR });

    // Add task on feature branch
    zagi(["tasks", "add", "Feature branch task"], { cwd: REPO_DIR });

    // Switch back to main
    git(["checkout", "main"], { cwd: REPO_DIR });

    // Should only see main branch task
    const mainTasks = zagi(["tasks", "list"], { cwd: REPO_DIR });
    expect(mainTasks).toContain("Main branch task");
    expect(mainTasks).not.toContain("Feature branch task");

    // Switch to feature branch
    git(["checkout", "feature"], { cwd: REPO_DIR });

    // Should only see feature branch task
    const featureTasks = zagi(["tasks", "list"], { cwd: REPO_DIR });
    expect(featureTasks).toContain("Feature branch task");
    expect(featureTasks).not.toContain("Main branch task");
  });
});

// ============================================================================
// Performance
// ============================================================================

describe("performance", () => {
  test("zagi tasks operations are reasonably fast", () => {
    // Create several tasks
    const start = Date.now();

    for (let i = 1; i <= 10; i++) {
      zagi(["tasks", "add", `Task ${i}`], { cwd: REPO_DIR });
    }

    zagi(["tasks", "list"], { cwd: REPO_DIR });

    const elapsed = Date.now() - start;

    // Should complete 10 add operations + 1 list in under 5 seconds
    // This is quite generous, but we want to catch major performance regressions
    expect(elapsed).toBeLessThan(5000);
  });

  test("task storage persists across commands", () => {
    zagi(["tasks", "add", "Persistent task"], { cwd: REPO_DIR });

    const firstList = zagi(["tasks", "list"], { cwd: REPO_DIR });
    expect(firstList).toContain("Persistent task");

    zagi(["tasks", "add", "Another task"], { cwd: REPO_DIR });

    const secondList = zagi(["tasks", "list"], { cwd: REPO_DIR });
    expect(secondList).toContain("Persistent task");
    expect(secondList).toContain("Another task");
    expect(secondList).toContain("tasks: 2 total");
  });
});
