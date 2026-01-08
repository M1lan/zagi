const std = @import("std");
const git = @import("git.zig");
const c = git.c;

pub const help =
    \\usage: git agent <command> [options]
    \\
    \\AI agent for automated task execution.
    \\
    \\Commands:
    \\  run      Execute RALPH loop to complete tasks
    \\  plan     Start planning session to create tasks
    \\
    \\Run 'git agent <command> --help' for command-specific options.
    \\
    \\Environment:
    \\  ZAGI_AGENT           Executor: claude (default) or opencode
    \\  ZAGI_AGENT_CMD       Custom command override (e.g., "aider --yes")
    \\
;

const run_help =
    \\usage: git agent run [options]
    \\
    \\Execute RALPH loop to automatically complete tasks.
    \\
    \\Options:
    \\  --model <model>      Model to use (optional, uses executor default)
    \\  --once               Run only one task, then exit
    \\  --dry-run            Show what would run without executing
    \\  --delay <seconds>    Delay between tasks (default: 2)
    \\  --max-tasks <n>      Stop after n tasks (safety limit)
    \\  --parallel <n>       Run n tasks in parallel (default: 1)
    \\  -h, --help           Show this help message
    \\
    \\Examples:
    \\  git agent run
    \\  git agent run --once
    \\  git agent run --dry-run
    \\  git agent run --parallel 3
    \\  ZAGI_AGENT=opencode git agent run
    \\
;

const plan_help =
    \\usage: git agent plan [options] [description]
    \\
    \\Start an interactive planning session with an AI agent.
    \\
    \\The agent will:
    \\1. Ask questions to understand your requirements
    \\2. Explore the codebase to understand the architecture
    \\3. Present a detailed plan for your approval
    \\4. Create tasks only after you confirm
    \\
    \\Options:
    \\  --model <model>      Model to use (optional, uses executor default)
    \\  --dry-run            Show prompt without executing
    \\  -h, --help           Show this help message
    \\
    \\Examples:
    \\  git agent plan                              # Start interactive session
    \\  git agent plan "Add user authentication"   # Start with initial context
    \\
;

pub const Error = git.Error || error{
    InvalidCommand,
    AllocationError,
    OutOfMemory,
    SpawnFailed,
    TaskLoadFailed,
    InvalidExecutor,
};

/// Valid executor values for ZAGI_AGENT
const valid_executors = [_][]const u8{ "claude", "opencode" };

/// Logs a formatted message to a file (if available).
fn logToFile(allocator: std.mem.Allocator, file: ?std.fs.File, comptime fmt: []const u8, log_args: anytype) void {
    if (file) |f| {
        const msg = std.fmt.allocPrint(allocator, fmt, log_args) catch return;
        defer allocator.free(msg);
        f.writeAll(msg) catch {};
    }
}

/// Builds command arguments for the specified executor.
/// Returns an ArrayList that the caller must deinit.
///
/// The `interactive` parameter controls whether the executor runs in interactive
/// mode (user can converse with agent) or headless mode (non-interactive, for
/// autonomous task execution):
/// - interactive=true: Claude runs without -p, opencode uses plain mode
/// - interactive=false: Claude runs with -p (print mode), opencode uses run mode
///
/// The `stream_json` parameter enables streaming JSON output for real-time
/// visibility (Claude's --output-format stream-json).
fn buildExecutorArgs(
    allocator: std.mem.Allocator,
    executor: []const u8,
    model: ?[]const u8,
    agent_cmd: ?[]const u8,
    prompt: []const u8,
    interactive: bool,
    stream_json: bool,
) !std.ArrayList([]const u8) {
    var args = std.ArrayList([]const u8){};
    errdefer args.deinit(allocator);

    if (agent_cmd) |cmd| {
        var parts = std.mem.splitScalar(u8, cmd, ' ');
        while (parts.next()) |part| {
            if (part.len > 0) try args.append(allocator, part);
        }
        try args.append(allocator, prompt);
    } else if (std.mem.eql(u8, executor, "claude")) {
        try args.append(allocator, "claude");
        if (!interactive) {
            // Use -p (print mode) for headless/non-interactive execution
            try args.append(allocator, "-p");
        }
        if (stream_json) {
            // Enable streaming JSON for real-time visibility
            try args.append(allocator, "--output-format");
            try args.append(allocator, "stream-json");
        }
        if (model) |m| {
            try args.append(allocator, "--model");
            try args.append(allocator, m);
        }
        try args.append(allocator, prompt);
    } else if (std.mem.eql(u8, executor, "opencode")) {
        try args.append(allocator, "opencode");
        if (!interactive) {
            // Use 'run' subcommand for headless execution
            try args.append(allocator, "run");
        }
        if (model) |m| {
            try args.append(allocator, "-m");
            try args.append(allocator, m);
        }
        try args.append(allocator, prompt);
    } else {
        // Fallback: split executor as command
        var parts = std.mem.splitScalar(u8, executor, ' ');
        while (parts.next()) |part| {
            if (part.len > 0) try args.append(allocator, part);
        }
        try args.append(allocator, prompt);
    }

    return args;
}

/// Formats the executor command for dry-run display.
/// The `interactive` and `stream_json` parameters mirror buildExecutorArgs behavior.
fn formatExecutorCommand(executor: []const u8, agent_cmd: ?[]const u8, interactive: bool, stream_json: bool) []const u8 {
    if (agent_cmd) |cmd| return cmd;
    if (std.mem.eql(u8, executor, "claude")) {
        if (interactive) return "claude";
        if (stream_json) return "claude -p --output-format stream-json";
        return "claude -p";
    }
    if (std.mem.eql(u8, executor, "opencode")) {
        return if (interactive) "opencode" else "opencode run";
    }
    return executor;
}

/// Updates the failure count for a task in the consecutive_failures tracking map.
///
/// Called after each task execution attempt:
/// - On success: pass new_count = 0 to reset the counter (task proved it can work)
/// - On failure: pass the incremented count (previous + 1)
///
/// The map uses duplicated keys because task_id strings are freed after each
/// loop iteration. If the key doesn't exist yet, we allocate a copy.
fn updateFailureCount(allocator: std.mem.Allocator, map: *std.StringHashMap(u32), task_id: []const u8, new_count: u32) void {
    const gop = map.getOrPut(task_id) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = allocator.dupe(u8, task_id) catch task_id;
    }
    gop.value_ptr.* = new_count;
}

/// Validates ZAGI_AGENT env var. Returns validated executor or error.
/// If not set, returns "claude" as default.
/// If set to invalid value (like "1"), returns error.
fn getValidatedExecutor(stdout: anytype) Error![]const u8 {
    const env_value = std.posix.getenv("ZAGI_AGENT") orelse return "claude";

    // Check if it's a valid executor
    for (valid_executors) |valid| {
        if (std.mem.eql(u8, env_value, valid)) {
            return env_value;
        }
    }

    // Invalid value - show error with valid options
    stdout.print("error: invalid ZAGI_AGENT value '{s}'\n", .{env_value}) catch {};
    stdout.print("  valid values: claude, opencode (or unset for default)\n", .{}) catch {};
    stdout.print("  note: use ZAGI_AGENT_CMD for custom executors\n", .{}) catch {};
    return Error.InvalidExecutor;
}

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Need at least "zagi agent <subcommand>"
    if (args.len < 3) {
        stdout.print("{s}", .{help}) catch {};
        return;
    }

    const subcommand = std.mem.sliceTo(args[2], 0);

    if (std.mem.eql(u8, subcommand, "run")) {
        return runRun(allocator, args);
    } else if (std.mem.eql(u8, subcommand, "plan")) {
        return runPlan(allocator, args);
    } else if (std.mem.eql(u8, subcommand, "-h") or std.mem.eql(u8, subcommand, "--help")) {
        stdout.print("{s}", .{help}) catch {};
        return;
    } else {
        stdout.print("error: unknown command '{s}'\n\n{s}", .{ subcommand, help }) catch {};
        return Error.InvalidCommand;
    }
}

/// Planning prompt template for the `zagi agent plan` subcommand.
///
/// This prompt instructs an AI agent to conduct an INTERACTIVE planning session
/// where it explores the codebase first, then asks clarifying questions about
/// scope, constraints, and preferences before drafting any plan. The session is
/// collaborative - the agent understands the architecture, asks targeted questions
/// to gather requirements, and only creates tasks after user approval.
///
/// Template placeholders:
/// - {0s}: Optional initial context from the user (may be empty)
/// - {1s}: Absolute path to the zagi binary (for task creation commands)
///
/// The planning agent follows a strict protocol:
/// 1. EXPLORE: Read the codebase to understand architecture FIRST
/// 2. ASK: Ask clarifying questions about scope, constraints, preferences
/// 3. PROPOSE: Present a numbered plan referencing specific files/patterns
/// 4. CONFIRM: Only create tasks after explicit approval
const planning_prompt_template =
    \\You are an interactive planning agent. Your job is to collaboratively design
    \\an implementation plan with the user through conversation.
    \\
    \\INITIAL CONTEXT: {0s}
    \\
    \\=== INTERACTIVE PLANNING PROTOCOL ===
    \\
    \\PHASE 1: EXPLORE CODEBASE (do this FIRST, before asking questions)
    \\Before asking any questions, silently explore the codebase to understand:
    \\- Read AGENTS.md for project conventions, build commands, and patterns
    \\- Examine the directory structure to understand the project layout
    \\- Identify key files and their purposes
    \\- Understand the current architecture and patterns in use
    \\- Find existing code related to the initial context (if provided)
    \\- Note any relevant tests, configs, or documentation
    \\
    \\This exploration helps you ask informed questions and propose realistic plans.
    \\
    \\PHASE 2: ASK CLARIFYING QUESTIONS (critical - do not skip)
    \\DO NOT draft a plan yet. First, engage the user with clarifying questions.
    \\Ask about these areas before proposing any implementation:
    \\
    \\SCOPE questions:
    \\- What specific functionality should be included/excluded?
    \\- Are there edge cases or error scenarios to consider?
    \\- What's the minimum viable version vs nice-to-haves?
    \\
    \\CONSTRAINTS questions:
    \\- Are there performance requirements?
    \\- Any dependencies or compatibility concerns?
    \\- Time/effort budget considerations?
    \\
    \\PREFERENCES questions:
    \\- Preferred approach or patterns? (e.g., "should this use X or Y?")
    \\- How should this integrate with existing code?
    \\- Testing requirements or coverage expectations?
    \\
    \\ACCEPTANCE CRITERIA questions:
    \\- How will we know when this is done?
    \\- What does success look like?
    \\
    \\Guidelines:
    \\- Ask 2-4 focused questions at a time, not a wall of questions
    \\- Reference what you found in the codebase to make questions specific
    \\- Keep asking until you have clarity on scope, constraints, and preferences
    \\- If context was provided, acknowledge it and ask clarifying follow-ups
    \\- If no context, start by asking "What would you like to build?"
    \\
    \\PHASE 3: PROPOSE PLAN (only after clarifying questions answered)
    \\Present a detailed, numbered implementation plan:
    \\- Reference specific files and patterns discovered in Phase 1
    \\- Break work into small, self-contained tasks
    \\- Each task should be completable in one session
    \\- Include acceptance criteria for each task
    \\- Order tasks by dependencies (foundations first)
    \\- Format as a numbered list the user can review
    \\
    \\Example plan format:
    \\  "Based on our discussion and my exploration, here's my proposed plan:
    \\
    \\   1. Add user model - create src/models/user.zig following the struct
    \\      patterns I found in src/cmds/git.zig
    \\   2. Add auth endpoint - POST /api/login, integrating with your existing
    \\      error handling in src/cmds/git.zig
    \\   3. Add middleware - JWT validation following your existing patterns
    \\   4. Add tests - unit tests matching your test/ structure
    \\
    \\   Does this look good? Should I adjust anything before creating tasks?"
    \\
    \\PHASE 4: CREATE TASKS (only after approval)
    \\Wait for explicit user confirmation before creating any tasks.
    \\When approved, you have two options:
    \\
    \\Option A - Write plan to file, then import:
    \\  1. Write plan to plan.md with numbered list (1. Task one, 2. Task two, ...)
    \\  2. Run: {1s} tasks import plan.md
    \\  This creates all tasks at once from the markdown file.
    \\
    \\Option B - Add tasks individually:
    \\  {1s} tasks add "<task description with acceptance criteria>"
    \\
    \\After creating all tasks, show the final list:
    \\  {1s} tasks list
    \\
    \\=== RULES ===
    \\- ALWAYS explore the codebase BEFORE asking questions
    \\- ALWAYS ask clarifying questions BEFORE drafting a plan
    \\- Ask informed questions that reference what you found
    \\- NEVER create tasks without explicit user approval
    \\- NEVER git push (only commit)
    \\- Keep the conversation focused and productive
    \\- If the user wants to change the plan, update it and confirm again
    \\
;

fn runPlan(allocator: std.mem.Allocator, args: [][:0]u8) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var model: ?[]const u8 = null;
    var dry_run = false;
    var initial_context: ?[]const u8 = null;

    var i: usize = 3; // Start after "zagi agent plan"
    while (i < args.len) {
        const arg = std.mem.sliceTo(args[i], 0);

        if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) {
                stdout.print("error: --model requires a model name\n", .{}) catch {};
                return Error.InvalidCommand;
            }
            model = std.mem.sliceTo(args[i], 0);
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            stdout.print("{s}", .{plan_help}) catch {};
            return;
        } else if (arg[0] == '-') {
            stdout.print("error: unknown option '{s}'\n", .{arg}) catch {};
            return Error.InvalidCommand;
        } else {
            initial_context = arg;
        }
        i += 1;
    }

    // Check ZAGI_AGENT_CMD for custom command override
    const agent_cmd = std.posix.getenv("ZAGI_AGENT_CMD");
    const executor = if (agent_cmd != null)
        std.posix.getenv("ZAGI_AGENT") orelse "claude" // Custom cmd bypasses validation
    else
        try getValidatedExecutor(stdout);

    // Get absolute path to current executable
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch {
        stderr.print("error: failed to resolve executable path\n", .{}) catch {};
        return Error.SpawnFailed;
    };

    // Use provided context or indicate none was given
    const context_str = initial_context orelse "(none - start by asking what the user wants to build)";

    // Create the planning prompt with dynamic path
    const prompt = std.fmt.allocPrint(allocator, planning_prompt_template, .{ context_str, exe_path }) catch return Error.OutOfMemory;
    defer allocator.free(prompt);

    if (dry_run) {
        stdout.print("=== Interactive Planning Session (dry-run) ===\n\n", .{}) catch {};
        if (initial_context) |ctx| {
            stdout.print("Initial context: {s}\n\n", .{ctx}) catch {};
        } else {
            stdout.print("Initial context: (none - will ask user)\n\n", .{}) catch {};
        }
        stdout.print("Would execute:\n", .{}) catch {};
        stdout.print("  {s} \"<planning prompt>\"\n", .{formatExecutorCommand(executor, agent_cmd, true, false)}) catch {};
        stdout.print("\n--- Prompt Preview ---\n{s}\n", .{prompt}) catch {};
        return;
    }

    // Open log file
    var log_file: ?std.fs.File = std.fs.cwd().createFile("agent.log", .{ .truncate = false }) catch null;
    if (log_file) |*f| f.seekFromEnd(0) catch {};
    defer if (log_file) |f| f.close();

    stdout.print("=== Starting Interactive Planning Session ===\n", .{}) catch {};
    if (initial_context) |ctx| {
        stdout.print("Initial context: {s}\n", .{ctx}) catch {};
    }
    stdout.print("Executor: {s}\n", .{executor}) catch {};
    stdout.print("\nThe agent will ask questions to understand your requirements,\n", .{}) catch {};
    stdout.print("then propose a plan for your approval before creating tasks.\n\n", .{}) catch {};
    logToFile(allocator, log_file, "=== Interactive planning session started ===\n", .{});
    if (initial_context) |ctx| {
        logToFile(allocator, log_file, "Initial context: {s}\n", .{ctx});
    }

    // Build and execute command in interactive mode (user converses with agent)
    // No stream-json for interactive mode since user needs human-readable output
    var runner_args = buildExecutorArgs(allocator, executor, model, agent_cmd, prompt, true, false) catch return Error.OutOfMemory;
    defer runner_args.deinit(allocator);

    var child = std.process.Child.init(runner_args.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        stderr.print("Error executing agent: {s}\n", .{@errorName(err)}) catch {};
        return Error.SpawnFailed;
    };

    const success = term == .Exited and term.Exited == 0;

    if (success) {
        stdout.print("\n=== Planning session completed ===\n", .{}) catch {};
        stdout.print("Run 'zagi tasks list' to see created tasks\n", .{}) catch {};
        stdout.print("Run 'zagi agent run' to execute tasks\n", .{}) catch {};
        logToFile(allocator, log_file, "=== Planning session completed ===\n\n", .{});
    } else {
        stdout.print("\n=== Planning session ended ===\n", .{}) catch {};
        logToFile(allocator, log_file, "=== Planning session ended ===\n\n", .{});
    }
}

/// Executes the RALPH (Recursive Agent Loop Pattern for Humans) loop.
///
/// The RALPH loop is an autonomous task execution pattern:
///
/// ```
/// ┌─────────────────────────────────────────────────────────┐
/// │  RALPH Loop Algorithm                                   │
/// ├─────────────────────────────────────────────────────────┤
/// │  1. Load pending tasks from git refs                    │
/// │  2. Find next task with < 3 consecutive failures        │
/// │  3. If no eligible task found → exit loop               │
/// │  4. Execute task with configured AI agent               │
/// │  5. On success: reset failure counter, increment count  │
/// │     On failure: increment failure counter               │
/// │  6. If --once flag set → exit loop                      │
/// │  7. Wait delay seconds, goto step 1                     │
/// └─────────────────────────────────────────────────────────┘
/// ```
///
/// Key behaviors:
/// - **Failure tolerance**: Tasks are skipped after 3 consecutive failures
///   to prevent infinite loops on broken tasks
/// - **Safety limits**: Optional --max-tasks prevents runaway execution
/// - **Observability**: All actions logged to agent.log
/// - **Graceful completion**: Exits when all tasks done or all remaining
///   tasks have exceeded failure threshold
fn runRun(allocator: std.mem.Allocator, args: [][:0]u8) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Parse command options
    var model: ?[]const u8 = null;
    var once = false;
    var dry_run = false;
    var delay: u32 = 2;
    var max_tasks: ?u32 = null;
    var parallel: u32 = 1;

    var i: usize = 3; // Start after "zagi agent run"
    while (i < args.len) {
        const arg = std.mem.sliceTo(args[i], 0);

        if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) {
                stdout.print("error: --model requires a model name\n", .{}) catch {};
                return Error.InvalidCommand;
            }
            model = std.mem.sliceTo(args[i], 0);
        } else if (std.mem.eql(u8, arg, "--once")) {
            once = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--delay")) {
            i += 1;
            if (i >= args.len) {
                stdout.print("error: --delay requires a number of seconds\n", .{}) catch {};
                return Error.InvalidCommand;
            }
            const delay_str = std.mem.sliceTo(args[i], 0);
            delay = std.fmt.parseInt(u32, delay_str, 10) catch {
                stdout.print("error: invalid delay value '{s}'\n", .{delay_str}) catch {};
                return Error.InvalidCommand;
            };
        } else if (std.mem.eql(u8, arg, "--max-tasks")) {
            i += 1;
            if (i >= args.len) {
                stdout.print("error: --max-tasks requires a number\n", .{}) catch {};
                return Error.InvalidCommand;
            }
            const max_str = std.mem.sliceTo(args[i], 0);
            max_tasks = std.fmt.parseInt(u32, max_str, 10) catch {
                stdout.print("error: invalid max-tasks value '{s}'\n", .{max_str}) catch {};
                return Error.InvalidCommand;
            };
        } else if (std.mem.eql(u8, arg, "--parallel")) {
            i += 1;
            if (i >= args.len) {
                stdout.print("error: --parallel requires a number\n", .{}) catch {};
                return Error.InvalidCommand;
            }
            const parallel_str = std.mem.sliceTo(args[i], 0);
            parallel = std.fmt.parseInt(u32, parallel_str, 10) catch {
                stdout.print("error: invalid parallel value '{s}'\n", .{parallel_str}) catch {};
                return Error.InvalidCommand;
            };
            if (parallel == 0) {
                stdout.print("error: --parallel must be at least 1\n", .{}) catch {};
                return Error.InvalidCommand;
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            stdout.print("{s}", .{run_help}) catch {};
            return;
        } else {
            stdout.print("error: unknown option '{s}'\n", .{arg}) catch {};
            return Error.InvalidCommand;
        }
        i += 1;
    }

    const agent_cmd = std.posix.getenv("ZAGI_AGENT_CMD");
    const executor = if (agent_cmd != null)
        std.posix.getenv("ZAGI_AGENT") orelse "claude" // Custom cmd bypasses validation
    else
        try getValidatedExecutor(stdout);

    // Get absolute path to current executable
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch {
        stderr.print("error: failed to resolve executable path\n", .{}) catch {};
        return Error.SpawnFailed;
    };

    // Initialize libgit2
    if (c.git_libgit2_init() < 0) {
        return git.Error.InitFailed;
    }
    defer _ = c.git_libgit2_shutdown();

    // Open repository
    var repo: ?*c.git_repository = null;
    if (c.git_repository_open_ext(&repo, ".", 0, null) < 0) {
        return git.Error.NotARepository;
    }
    defer c.git_repository_free(repo);

    // Open log file for append
    var log_file: ?std.fs.File = std.fs.cwd().createFile("agent.log", .{ .truncate = false }) catch null;
    if (log_file) |*f| f.seekFromEnd(0) catch {};
    defer if (log_file) |f| f.close();

    var tasks_completed: u32 = 0;

    // Consecutive failure tracking map: task_id -> failure_count
    //
    // This map tracks how many times each task has failed IN A ROW. The key
    // insight is "consecutive" - a task that succeeds resets its counter to 0.
    //
    // Why track consecutive failures instead of total failures?
    // - Transient errors (network issues, race conditions) shouldn't permanently
    //   disqualify a task
    // - If a task succeeds once, it proves the task CAN work
    // - 3 consecutive failures strongly suggests the task itself is broken
    //
    // Memory management: Keys are duplicated because task IDs come from
    // getPendingTasks() which frees its memory after each iteration. The
    // deferred cleanup frees all duplicated keys before map deinit.
    var consecutive_failures = std.StringHashMap(u32).init(allocator);
    defer {
        // Free all the duplicated keys before deiniting the map
        var key_iter = consecutive_failures.keyIterator();
        while (key_iter.next()) |key_ptr| {
            allocator.free(key_ptr.*);
        }
        consecutive_failures.deinit();
    }

    stdout.print("Starting RALPH loop...\n", .{}) catch {};
    logToFile(allocator, log_file, "=== RALPH loop started ===\n", .{});
    if (dry_run) {
        stdout.print("(dry-run mode - no commands will be executed)\n", .{}) catch {};
    }
    stdout.print("Executor: {s}", .{executor}) catch {};
    if (model) |m| {
        stdout.print(" (model: {s})", .{m}) catch {};
    }
    if (parallel > 1) {
        stdout.print(" (parallel: {})", .{parallel}) catch {};
    }
    stdout.print("\n\n", .{}) catch {};

    if (parallel > 1) {
        // Parallel execution: run multiple tasks concurrently
        tasks_completed = runParallelLoop(
            allocator,
            executor,
            model,
            agent_cmd,
            exe_path,
            &consecutive_failures,
            log_file,
            parallel,
            max_tasks,
            delay,
            dry_run,
            once,
        ) catch |err| {
            stderr.print("error: parallel execution failed: {s}\n", .{@errorName(err)}) catch {};
            return Error.TaskLoadFailed;
        };
    } else {
        // Sequential execution: original single-task loop
        while (true) {
            if (max_tasks) |max| {
                if (tasks_completed >= max) {
                    stdout.print("Reached maximum task limit ({})\n", .{max}) catch {};
                    break;
                }
            }

            const pending = getPendingTasks(allocator) catch {
                stderr.print("error: failed to load tasks\n", .{}) catch {};
                return Error.TaskLoadFailed;
            };
            defer allocator.free(pending.tasks);
            defer for (pending.tasks) |t| {
                allocator.free(t.id);
                allocator.free(t.content);
            };

            if (pending.tasks.len == 0) {
                stdout.print("No pending tasks remaining. All tasks complete!\n", .{}) catch {};
                stdout.print("Run: zagi tasks pr\n", .{}) catch {};
                break;
            }

            var next_task: ?PendingTask = null;
            for (pending.tasks) |task| {
                const failure_count = consecutive_failures.get(task.id) orelse 0;
                if (failure_count < 3) {
                    next_task = task;
                    break;
                }
            }

            if (next_task == null) {
                stdout.print("All remaining tasks have failed 3+ times. Stopping.\n", .{}) catch {};
                break;
            }

            const task = next_task.?;
            stdout.print("Starting task: {s}\n", .{task.id}) catch {};
            stdout.print("  {s}\n\n", .{task.content}) catch {};
            logToFile(allocator, log_file, "Starting task: {s} - {s}\n", .{ task.id, task.content });

            if (dry_run) {
                stdout.print("Would execute:\n", .{}) catch {};
                stdout.print("  {s} \"<prompt>\"\n", .{formatExecutorCommand(executor, agent_cmd, false, false)}) catch {};
                stdout.print("\n", .{}) catch {};
                tasks_completed += 1;
            } else {
                const success = executeTaskStreaming(allocator, executor, model, agent_cmd, exe_path, task.id, task.content, false) catch false;

                if (success) {
                    updateFailureCount(allocator, &consecutive_failures, task.id, 0);
                    tasks_completed += 1;
                    stdout.print("Task completed successfully\n\n", .{}) catch {};
                    logToFile(allocator, log_file, "Task {s} completed successfully\n", .{task.id});
                } else {
                    const new_failures = (consecutive_failures.get(task.id) orelse 0) + 1;
                    updateFailureCount(allocator, &consecutive_failures, task.id, new_failures);
                    stdout.print("Task failed ({} consecutive failures)\n", .{new_failures}) catch {};
                    logToFile(allocator, log_file, "Task {s} failed ({} consecutive failures)\n", .{ task.id, new_failures });
                    if (new_failures >= 3) {
                        stdout.print("Skipping task after 3 consecutive failures\n", .{}) catch {};
                    }
                    stdout.print("\n", .{}) catch {};
                }
            }

            if (once) {
                stdout.print("Exiting after one task (--once flag set)\n", .{}) catch {};
                break;
            }

            if (!dry_run and delay > 0) {
                stdout.print("Waiting {} seconds before next task...\n\n", .{delay}) catch {};
                std.Thread.sleep(delay * std.time.ns_per_s);
            }
        }
    }

    stdout.print("RALPH loop completed. {} tasks processed.\n", .{tasks_completed}) catch {};
    logToFile(allocator, log_file, "=== RALPH loop completed: {} tasks processed ===\n\n", .{tasks_completed});
}

/// Tracks a running task for parallel execution.
const RunningTask = struct {
    id: []const u8,
    content: []const u8,
    child: std.process.Child,
};

/// Runs the parallel execution loop with N concurrent tasks.
///
/// This spawns up to `parallel` tasks simultaneously, streaming their output
/// to individual JSON log files. When any task completes, it spawns a new one
/// to maintain the parallelism level until all tasks are done.
///
/// Returns the total number of tasks completed.
fn runParallelLoop(
    allocator: std.mem.Allocator,
    executor: []const u8,
    model: ?[]const u8,
    agent_cmd: ?[]const u8,
    exe_path: []const u8,
    consecutive_failures: *std.StringHashMap(u32),
    main_log: ?std.fs.File,
    parallel: u32,
    max_tasks: ?u32,
    delay: u32,
    dry_run: bool,
    once: bool,
) !u32 {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    var tasks_completed: u32 = 0;
    var running = std.ArrayList(RunningTask){};
    defer running.deinit(allocator);

    // Track processed tasks for dry-run mode (prevents infinite loop)
    var processed_tasks = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = processed_tasks.keyIterator();
        while (key_iter.next()) |key_ptr| {
            allocator.free(key_ptr.*);
        }
        processed_tasks.deinit();
    }

    // Ensure logs directory exists
    std.fs.cwd().makeDir("logs") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    while (true) {
        // Check max tasks limit
        if (max_tasks) |max| {
            if (tasks_completed >= max) {
                stdout.print("Reached maximum task limit ({})\n", .{max}) catch {};
                break;
            }
        }

        // Get pending tasks
        const pending = try getPendingTasks(allocator);
        defer allocator.free(pending.tasks);
        defer for (pending.tasks) |t| {
            allocator.free(t.id);
            allocator.free(t.content);
        };

        // Get list of currently running task IDs
        var running_ids = std.StringHashMap(void).init(allocator);
        defer running_ids.deinit();
        for (running.items) |r| {
            running_ids.put(r.id, {}) catch {};
        }

        // Find eligible tasks (not running, not failed 3x, not processed in dry-run)
        var eligible = std.ArrayList(PendingTask){};
        defer eligible.deinit(allocator);
        for (pending.tasks) |task| {
            // Skip if already running
            if (running_ids.contains(task.id)) continue;
            // Skip if failed 3+ times
            const failure_count = consecutive_failures.get(task.id) orelse 0;
            if (failure_count >= 3) continue;
            // Skip if already processed (dry-run mode tracking)
            if (processed_tasks.contains(task.id)) continue;
            eligible.append(allocator, task) catch continue;
        }

        // Check termination conditions
        if (running.items.len == 0 and eligible.items.len == 0) {
            if (pending.tasks.len == 0) {
                stdout.print("No pending tasks remaining. All tasks complete!\n", .{}) catch {};
                stdout.print("Run: zagi tasks pr\n", .{}) catch {};
            } else {
                stdout.print("All remaining tasks have failed 3+ times. Stopping.\n", .{}) catch {};
            }
            break;
        }

        // Spawn new tasks up to parallel limit
        const slots_available = parallel - @as(u32, @intCast(running.items.len));
        const to_spawn = @min(slots_available, @as(u32, @intCast(eligible.items.len)));

        for (eligible.items[0..to_spawn]) |task| {
            stdout.print("Starting task: {s}\n", .{task.id}) catch {};
            stdout.print("  {s}\n", .{task.content}) catch {};
            logToFile(allocator, main_log, "Starting task: {s} - {s}\n", .{ task.id, task.content });

            if (dry_run) {
                stdout.print("Would execute:\n", .{}) catch {};
                stdout.print("  {s} \"<prompt>\" > logs/{s}.json\n", .{ formatExecutorCommand(executor, agent_cmd, false, true), task.id }) catch {};
                stdout.print("\n", .{}) catch {};
                tasks_completed += 1;
                // Track this task as processed to avoid re-selecting it
                const task_id_dupe = allocator.dupe(u8, task.id) catch continue;
                processed_tasks.put(task_id_dupe, {}) catch allocator.free(task_id_dupe);
                continue;
            }

            // Create prompt
            const prompt = createPrompt(allocator, executor, exe_path, task.id, task.content) catch continue;

            // Build args with streaming enabled
            var runner_args = buildExecutorArgs(allocator, executor, model, agent_cmd, prompt, false, true) catch {
                allocator.free(prompt);
                continue;
            };

            // Create log file for this task
            const log_filename = std.fmt.allocPrint(allocator, "logs/{s}.json", .{task.id}) catch {
                runner_args.deinit(allocator);
                allocator.free(prompt);
                continue;
            };
            defer allocator.free(log_filename);

            var task_log = std.fs.cwd().createFile(log_filename, .{}) catch {
                runner_args.deinit(allocator);
                allocator.free(prompt);
                continue;
            };

            stdout.print("  Streaming to: {s}\n\n", .{log_filename}) catch {};

            // Build shell command with redirection to log file
            // Join args into a single command string
            var cmd_builder = std.ArrayList(u8){};
            defer cmd_builder.deinit(allocator);
            for (runner_args.items, 0..) |arg, idx| {
                if (idx > 0) cmd_builder.append(allocator, ' ') catch continue;
                // Quote the argument
                cmd_builder.append(allocator, '\'') catch continue;
                for (arg) |char| {
                    if (char == '\'') {
                        cmd_builder.appendSlice(allocator, "'\\''") catch continue;
                    } else {
                        cmd_builder.append(allocator, char) catch continue;
                    }
                }
                cmd_builder.append(allocator, '\'') catch continue;
            }
            cmd_builder.appendSlice(allocator, " > ") catch continue;
            cmd_builder.appendSlice(allocator, log_filename) catch continue;

            const shell_cmd = cmd_builder.items;

            // Spawn through shell to handle redirection
            var child = std.process.Child.init(&.{ "/bin/sh", "-c", shell_cmd }, allocator);
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;

            child.spawn() catch {
                task_log.close();
                runner_args.deinit(allocator);
                allocator.free(prompt);
                continue;
            };

            // Close our handle to the log file - the shell will write to it
            task_log.close();

            // Track running task - duplicate the id and content since pending will be freed
            const id_dupe = allocator.dupe(u8, task.id) catch continue;
            const content_dupe = allocator.dupe(u8, task.content) catch {
                allocator.free(id_dupe);
                continue;
            };

            running.append(allocator, .{
                .id = id_dupe,
                .content = content_dupe,
                .child = child,
            }) catch {
                allocator.free(id_dupe);
                allocator.free(content_dupe);
            };

            // Clean up args and prompt (child has inherited what it needs)
            runner_args.deinit(allocator);
            allocator.free(prompt);

            if (once) break;
        }

        if (dry_run and eligible.items.len > 0) {
            // In dry run, we counted tasks above, now check if done
            if (once or (max_tasks != null and tasks_completed >= max_tasks.?)) {
                break;
            }
            continue;
        }

        // Wait for any running task to complete
        if (running.items.len > 0) {
            // Poll all running tasks to find completed ones
            var i: usize = 0;
            while (i < running.items.len) {
                var task_entry = &running.items[i];

                // Try non-blocking wait
                const result = task_entry.child.wait() catch null;

                if (result) |term| {
                    // Task completed
                    const success = term == .Exited and term.Exited == 0;

                    if (success) {
                        updateFailureCount(allocator, consecutive_failures, task_entry.id, 0);
                        tasks_completed += 1;
                        stdout.print("Task {s} completed successfully\n", .{task_entry.id}) catch {};
                        logToFile(allocator, main_log, "Task {s} completed successfully\n", .{task_entry.id});
                    } else {
                        const new_failures = (consecutive_failures.get(task_entry.id) orelse 0) + 1;
                        updateFailureCount(allocator, consecutive_failures, task_entry.id, new_failures);
                        stdout.print("Task {s} failed ({} consecutive failures)\n", .{ task_entry.id, new_failures }) catch {};
                        logToFile(allocator, main_log, "Task {s} failed ({} consecutive failures)\n", .{ task_entry.id, new_failures });
                    }

                    // Clean up
                    allocator.free(task_entry.id);
                    allocator.free(task_entry.content);

                    // Remove from running list
                    _ = running.swapRemove(i);
                    // Don't increment i, we swapped in a new element
                } else {
                    i += 1;
                }
            }

            // If still have running tasks, sleep briefly before polling again
            if (running.items.len > 0 and running.items.len >= parallel) {
                std.Thread.sleep(100 * std.time.ns_per_ms); // 100ms poll interval
            }
        }

        if (once and tasks_completed > 0) {
            stdout.print("Exiting after one task (--once flag set)\n", .{}) catch {};
            break;
        }

        // Delay between spawning batches
        if (!dry_run and delay > 0 and running.items.len == 0 and eligible.items.len == 0) {
            stdout.print("Waiting {} seconds before checking for new tasks...\n\n", .{delay}) catch {};
            std.Thread.sleep(delay * std.time.ns_per_s);
        }
    }

    // Clean up any still-running tasks
    for (running.items) |*task_entry| {
        _ = task_entry.child.kill() catch {};
        allocator.free(task_entry.id);
        allocator.free(task_entry.content);
    }

    return tasks_completed;
}

const PendingTask = struct {
    id: []const u8,
    content: []const u8,
};

const PendingTasks = struct {
    tasks: []PendingTask,
};

fn getPendingTasks(allocator: std.mem.Allocator) !PendingTasks {
    // Get absolute path to current executable to avoid relative path issues
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch return error.SpawnFailed;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ exe_path, "tasks", "list", "--json" },
    }) catch return error.SpawnFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const parsed = std.json.parseFromSlice(struct {
        tasks: []const struct {
            id: []const u8,
            content: []const u8,
            status: []const u8,
            created: i64,
            completed: ?i64,
        },
    }, allocator, result.stdout, .{}) catch {
        return PendingTasks{ .tasks = &.{} };
    };
    defer parsed.deinit();

    var pending = std.ArrayList(PendingTask){};
    for (parsed.value.tasks) |task| {
        if (!std.mem.eql(u8, task.status, "completed")) {
            const id_dupe = allocator.dupe(u8, task.id) catch continue;
            const content_dupe = allocator.dupe(u8, task.content) catch {
                allocator.free(id_dupe); // Free id if content alloc fails
                continue;
            };
            pending.append(allocator, .{
                .id = id_dupe,
                .content = content_dupe,
            }) catch {
                allocator.free(id_dupe);
                allocator.free(content_dupe);
                continue;
            };
        }
    }

    return PendingTasks{ .tasks = pending.toOwnedSlice(allocator) catch &.{} };
}

fn createPrompt(allocator: std.mem.Allocator, executor: []const u8, exe_path: []const u8, task_id: []const u8, task_content: []const u8) ![]u8 {
    // Determine which documentation file this executor should update
    const is_claude = std.mem.eql(u8, executor, "claude");
    const docs_file = if (is_claude) "CLAUDE.md" else "AGENTS.md";

    return std.fmt.allocPrint(allocator,
        \\You are working on: {0s}
        \\
        \\Task: {1s}
        \\
        \\Instructions:
        \\1. Read AGENTS.md for project context and build instructions
        \\2. Complete this ONE task only
        \\3. Verify your work (run tests, check build)
        \\4. Commit your changes with: git commit -m "<message>"
        \\5. Mark the task done: {2s} tasks done {0s}
        \\
        \\Knowledge Persistence:
        \\If you discover important structural insights during this task, update {3s}:
        \\- Build commands that work (or gotchas that don't)
        \\- Key file locations and their purposes
        \\- Project conventions not documented elsewhere
        \\- Common errors and their solutions
        \\Only add genuinely useful operational knowledge, not task-specific details.
        \\
        \\Rules:
        \\- NEVER git push (only commit)
        \\- ONLY work on this one task
        \\- Exit when done so the next task can start
    , .{ task_id, task_content, exe_path, docs_file });
}

/// Executes a single task with optional streaming JSON output.
///
/// When stream_json is true:
/// - Enables --output-format stream-json for real-time visibility
/// - Streams output directly to logs/<task-id>.json
/// - Provides better debugging for parallel execution
///
/// When stream_json is false:
/// - Uses legacy capture mode where output is buffered in memory
/// - Output is written to log file only on failure
fn executeTaskStreaming(allocator: std.mem.Allocator, executor: []const u8, model: ?[]const u8, agent_cmd: ?[]const u8, exe_path: []const u8, task_id: []const u8, task_content: []const u8, stream_json: bool) !bool {
    const stderr_writer = std.fs.File.stderr().deprecatedWriter();
    const stdout_writer = std.fs.File.stdout().deprecatedWriter();

    const prompt = try createPrompt(allocator, executor, exe_path, task_id, task_content);
    defer allocator.free(prompt);

    // Use headless mode (interactive=false) for autonomous task execution
    var runner_args = try buildExecutorArgs(allocator, executor, model, agent_cmd, prompt, false, stream_json);
    defer runner_args.deinit(allocator);

    if (stream_json) {
        // Streaming mode: redirect stdout to a JSON log file for real-time visibility
        // Ensure logs directory exists
        std.fs.cwd().makeDir("logs") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Create task-specific JSON log file path
        const log_filename = try std.fmt.allocPrint(allocator, "logs/{s}.json", .{task_id});
        defer allocator.free(log_filename);

        stdout_writer.print("Streaming to: {s}\n", .{log_filename}) catch {};

        // Build shell command with redirection to log file
        var cmd_builder = std.ArrayList(u8){};
        defer cmd_builder.deinit(allocator);
        for (runner_args.items, 0..) |arg, idx| {
            if (idx > 0) cmd_builder.append(allocator, ' ') catch continue;
            cmd_builder.append(allocator, '\'') catch continue;
            for (arg) |char| {
                if (char == '\'') {
                    cmd_builder.appendSlice(allocator, "'\\''") catch continue;
                } else {
                    cmd_builder.append(allocator, char) catch continue;
                }
            }
            cmd_builder.append(allocator, '\'') catch continue;
        }
        cmd_builder.appendSlice(allocator, " > ") catch {};
        cmd_builder.appendSlice(allocator, log_filename) catch {};

        const shell_cmd = cmd_builder.items;

        // Spawn through shell to handle redirection
        var child = std.process.Child.init(&.{ "/bin/sh", "-c", shell_cmd }, allocator);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        const term = child.spawnAndWait() catch |err| {
            stderr_writer.print("Error executing runner: {s}\n", .{@errorName(err)}) catch {};
            return false;
        };

        return term == .Exited and term.Exited == 0;
    } else {
        // Legacy capture mode: buffer output in memory
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = runner_args.items,
        }) catch |err| {
            stderr_writer.print("Error executing runner: {s}\n", .{@errorName(err)}) catch {};
            logTaskOutput(allocator, task_id, null, null, err) catch {};
            return false;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const success = result.term == .Exited and result.term.Exited == 0;

        if (!success) {
            logTaskOutput(allocator, task_id, result.stdout, result.stderr, null) catch {};

            const exit_info = switch (result.term) {
                .Exited => |code| blk: {
                    var buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "exit code {}", .{code}) catch "exit code ?";
                    break :blk s;
                },
                .Signal => |sig| blk: {
                    var buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "signal {}", .{sig}) catch "signal ?";
                    break :blk s;
                },
                .Stopped => |sig| blk: {
                    var buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "stopped {}", .{sig}) catch "stopped ?";
                    break :blk s;
                },
                .Unknown => |val| blk: {
                    var buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "unknown {}", .{val}) catch "unknown ?";
                    break :blk s;
                },
            };
            stdout_writer.print("Process terminated: {s}\n", .{exit_info}) catch {};
            stdout_writer.print("Output logged to: logs/{s}.log\n", .{task_id}) catch {};
        }

        return success;
    }
}

/// Logs task output to a task-specific log file for debugging.
///
/// Creates logs/<task-id>.log with stdout, stderr, and error information.
/// This enables post-mortem analysis of crashed or failed agent runs.
fn logTaskOutput(allocator: std.mem.Allocator, task_id: []const u8, stdout_output: ?[]const u8, stderr_output: ?[]const u8, spawn_err: ?anyerror) !void {
    // Ensure logs directory exists
    std.fs.cwd().makeDir("logs") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Create task-specific log file
    const log_filename = std.fmt.allocPrint(allocator, "logs/{s}.log", .{task_id}) catch return;
    defer allocator.free(log_filename);

    var log_file = std.fs.cwd().createFile(log_filename, .{}) catch return;
    defer log_file.close();

    // Write timestamp header
    const timestamp = std.time.timestamp();
    const header = std.fmt.allocPrint(allocator, "=== Task {s} failed at {d} ===\n\n", .{ task_id, timestamp }) catch return;
    defer allocator.free(header);
    log_file.writeAll(header) catch return;

    // Write spawn error if any
    if (spawn_err) |err| {
        const err_msg = std.fmt.allocPrint(allocator, "Spawn error: {s}\n\n", .{@errorName(err)}) catch return;
        defer allocator.free(err_msg);
        log_file.writeAll(err_msg) catch return;
    }

    // Write stdout if captured
    if (stdout_output) |out| {
        if (out.len > 0) {
            const stdout_header = std.fmt.allocPrint(allocator, "=== STDOUT ({d} bytes) ===\n", .{out.len}) catch return;
            defer allocator.free(stdout_header);
            log_file.writeAll(stdout_header) catch return;
            log_file.writeAll(out) catch return;
            if (out[out.len - 1] != '\n') {
                log_file.writeAll("\n") catch return;
            }
            log_file.writeAll("\n") catch return;
        } else {
            log_file.writeAll("=== STDOUT (empty) ===\n\n") catch return;
        }
    }

    // Write stderr if captured
    if (stderr_output) |err_out| {
        if (err_out.len > 0) {
            const stderr_header = std.fmt.allocPrint(allocator, "=== STDERR ({d} bytes) ===\n", .{err_out.len}) catch return;
            defer allocator.free(stderr_header);
            log_file.writeAll(stderr_header) catch return;
            log_file.writeAll(err_out) catch return;
            if (err_out[err_out.len - 1] != '\n') {
                log_file.writeAll("\n") catch return;
            }
            log_file.writeAll("\n") catch return;
        } else {
            log_file.writeAll("=== STDERR (empty) ===\n\n") catch return;
        }
    }
}
