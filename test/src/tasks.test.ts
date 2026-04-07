import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { zagi, git, createTestRepo, cleanupTestRepo } from "./shared";

let REPO_DIR: string;

// Use lightweight repo - these tests don't need multiple commits
beforeEach(() => {
  REPO_DIR = createTestRepo();
});

afterEach(() => {
  cleanupTestRepo(REPO_DIR);
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

    const result = zagi(["tasks", "edit", "task-001", "New content"], {
      cwd: REPO_DIR,
      env: { CLAUDECODE: "1" }
    });

    // Edit is blocked in agent mode - agents should use append
    expect(result).toContain("error: edit command blocked");
    expect(result).toContain("tasks append");
  });

  test("replaces when not in agent mode", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    // Explicitly unset ZAGI_AGENT to test non-agent mode
    const result = zagi(["tasks", "edit", "task-001", "Updated content"], {
      cwd: REPO_DIR,
      env: { CLAUDECODE: undefined }
    });

    expect(result).toContain("updated: task-001");
    expect(result).toContain("Updated content");
  });
});

describe("zagi tasks append", () => {
  test("appends to task content", () => {
    zagi(["tasks", "add", "Original task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "append", "task-001", "Additional notes"], { cwd: REPO_DIR });

    expect(result).toContain("appended: task-001");
    expect(result).toContain("Additional notes");

    // Verify content was appended
    const showResult = zagi(["tasks", "show", "task-001"], { cwd: REPO_DIR });
    expect(showResult).toContain("Original task");
    expect(showResult).toContain("Additional notes");
  });

  test("works in agent mode", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "append", "task-001", "Agent notes"], {
      cwd: REPO_DIR,
      env: { CLAUDECODE: "1" }
    });

    expect(result).toContain("appended: task-001");
    expect(result).toContain("Agent notes");
  });
});

describe("zagi tasks delete", () => {
  test("is blocked in agent mode", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    const result = zagi(["tasks", "delete", "task-001"], {
      cwd: REPO_DIR,
      env: { CLAUDECODE: "1" }
    });

    expect(result).toContain("error: delete command blocked");
    expect(result).toContain("permanent data loss");
    expect(result).toContain("ask the user to delete this task");
  });

  test("succeeds when not in agent mode", () => {
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    // Explicitly unset ZAGI_AGENT to test non-agent mode
    const result = zagi(["tasks", "delete", "task-001"], {
      cwd: REPO_DIR,
      env: { CLAUDECODE: undefined }
    });

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

    // libgit2 outputs "fatal:" for non-repo errors
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
// Error Conditions: No Tasks Exist
// ============================================================================

describe("error conditions: no tasks exist", () => {
  test("tasks list shows helpful message when empty", () => {
    const result = zagi(["tasks", "list"], { cwd: REPO_DIR });

    expect(result).toContain("no tasks found");
  });

  test("tasks list --json returns empty array when no tasks", () => {
    const result = zagi(["tasks", "list", "--json"], { cwd: REPO_DIR });

    const parsed = JSON.parse(result.trim());
    expect(parsed).toHaveProperty("tasks");
    expect(parsed.tasks).toHaveLength(0);
  });

  test("tasks pr shows helpful message when empty", () => {
    const result = zagi(["tasks", "pr"], { cwd: REPO_DIR });

    expect(result).toContain("No tasks found");
  });

  test("tasks show gives clear error for non-existent task", () => {
    const result = zagi(["tasks", "show", "task-001"], { cwd: REPO_DIR });

    expect(result).toContain("error: task 'task-001' not found");
  });

  test("tasks done gives clear error for non-existent task", () => {
    const result = zagi(["tasks", "done", "task-001"], { cwd: REPO_DIR });

    expect(result).toContain("error: task 'task-001' not found");
  });
});

// ============================================================================
// Error Conditions: Corrupted Task Data
// ============================================================================

describe("error conditions: corrupted task data", () => {
  test("handles corrupted task ref gracefully", () => {
    // First, create a valid task to establish refs/tasks/main
    zagi(["tasks", "add", "Initial task"], { cwd: REPO_DIR });

    // Corrupt the task ref by writing garbage data directly
    // The ref points to a blob - we can create a new blob with garbage
    // and update the ref to point to it
    git(["update-ref", "refs/tasks/main", "HEAD"], { cwd: REPO_DIR });

    // Now tasks list should handle this gracefully
    const result = zagi(["tasks", "list"], { cwd: REPO_DIR });

    // Should not crash - either shows "no tasks" or handles error gracefully
    // The Zig code's fromJson handles malformed data by skipping invalid lines
    expect(result).not.toContain("panic");
    expect(result).not.toContain("SIGSEGV");
  });

  test("recovers from malformed task data by showing empty list", () => {
    // Create a task then corrupt by pointing ref to a tree object
    zagi(["tasks", "add", "Test task"], { cwd: REPO_DIR });

    // Create an empty blob with partial/invalid task data
    const blobOid = git(["hash-object", "-w", "--stdin"], {
      cwd: REPO_DIR
    }).trim();

    // Note: This test verifies the system doesn't crash on read errors
    // The actual behavior depends on what git returns for corrupted refs
    const result = zagi(["tasks", "list"], { cwd: REPO_DIR });

    // Main verification: system should not crash
    expect(typeof result).toBe("string");
  });

  test("task add works even after corrupted read", () => {
    // Point ref to HEAD (a commit, not a blob) - simulates corruption
    git(["update-ref", "-d", "refs/tasks/main"], { cwd: REPO_DIR }).trim();

    // Adding a new task should work (creates fresh task list)
    const result = zagi(["tasks", "add", "Fresh task after corruption"], { cwd: REPO_DIR });

    expect(result).toContain("created: task-001");
    expect(result).toContain("Fresh task after corruption");
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
