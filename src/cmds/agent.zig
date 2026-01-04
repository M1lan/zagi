const std = @import("std");
const git = @import("git.zig");
const c = git.c;

pub const help =
    \\usage: zagi agent [options]
    \\
    \\Execute RALPH loop to automatically complete tasks.
    \\
    \\Options:
    \\  --model <model>      Model to use (optional, uses executor default)
    \\  --once               Run only one task, then exit
    \\  --dry-run            Show what would run without executing
    \\  --delay <seconds>    Delay between tasks (default: 2)
    \\  --max-tasks <n>      Stop after n tasks (safety limit)
    \\  -h, --help           Show this help message
    \\
    \\Environment:
    \\  ZAGI_AGENT           Executor: claude (default) or opencode
    \\  ZAGI_AGENT_CMD       Custom command override (e.g., "aider --yes")
    \\
    \\Examples:
    \\  zagi agent
    \\  ZAGI_AGENT=opencode zagi agent
    \\  ZAGI_AGENT_CMD="aider --yes" zagi agent
    \\  zagi agent --once --dry-run
    \\
;

pub const Error = git.Error || error{
    InvalidCommand,
    AllocationError,
    OutOfMemory,
    SpawnFailed,
    TaskLoadFailed,
};

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Parse command options
    var model: ?[]const u8 = null;
    var once = false;
    var dry_run = false;
    var delay: u32 = 2; // default 2 seconds
    var max_tasks: ?u32 = null;

    var i: usize = 2; // Start after "zagi agent"
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
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            stdout.print("{s}", .{help}) catch {};
            return;
        } else {
            stdout.print("error: unknown option '{s}'\n", .{arg}) catch {};
            return Error.InvalidCommand;
        }
        i += 1;
    }

    // Check ZAGI_AGENT_CMD for custom command override
    const agent_cmd = std.posix.getenv("ZAGI_AGENT_CMD");

    // Get executor from ZAGI_AGENT env var, default to "claude"
    const executor = std.posix.getenv("ZAGI_AGENT") orelse "claude";

    // Note: model is only used if explicitly set via --model flag
    // Executors use their own defaults when model is null

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
    var log_file: ?std.fs.File = std.fs.cwd().createFile("agent.log", .{
        .truncate = false,
    }) catch null;
    if (log_file) |*f| {
        f.seekFromEnd(0) catch {};
    }
    defer if (log_file) |f| f.close();

    // Simple log function - writes to file using allocator for formatting
    const logToFile = struct {
        fn write(alloc: std.mem.Allocator, file: ?std.fs.File, comptime fmt: []const u8, log_args: anytype) void {
            if (file) |f| {
                const msg = std.fmt.allocPrint(alloc, fmt, log_args) catch return;
                defer alloc.free(msg);
                f.writeAll(msg) catch {};
            }
        }
    }.write;

    var tasks_completed: u32 = 0;
    var consecutive_failures = std.StringHashMap(u32).init(allocator);
    defer consecutive_failures.deinit();

    stdout.print("Starting RALPH loop...\n", .{}) catch {};
    logToFile(allocator, log_file, "=== RALPH loop started ===\n", .{});
    if (dry_run) {
        stdout.print("(dry-run mode - no commands will be executed)\n", .{}) catch {};
    }
    stdout.print("Executor: {s}", .{executor}) catch {};
    if (model) |m| {
        stdout.print(" (model: {s})", .{m}) catch {};
    }
    stdout.print("\n\n", .{}) catch {};

    while (true) {
        // Check max_tasks limit
        if (max_tasks) |max| {
            if (tasks_completed >= max) {
                stdout.print("Reached maximum task limit ({})\n", .{max}) catch {};
                break;
            }
        }

        // Get pending tasks by calling zagi tasks list --json
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

        // Filter out tasks that have failed too many times
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
            if (agent_cmd) |cmd| {
                stdout.print("  {s} \"<prompt>\"\n", .{cmd}) catch {};
            } else if (std.mem.eql(u8, executor, "claude")) {
                stdout.print("  claude -p \"<prompt>\"\n", .{}) catch {};
            } else if (std.mem.eql(u8, executor, "opencode")) {
                stdout.print("  opencode run \"<prompt>\"\n", .{}) catch {};
            } else {
                stdout.print("  {s} \"<prompt>\"\n", .{executor}) catch {};
            }
            stdout.print("\n", .{}) catch {};
            tasks_completed += 1;
        } else {
            // Execute the task
            const success = executeTask(allocator, executor, model, agent_cmd, task.id, task.content) catch false;

            if (success) {
                // Reset failure count on success - need to dupe key since task.id will be freed
                const key = allocator.dupe(u8, task.id) catch task.id;
                consecutive_failures.put(key, 0) catch {};
                tasks_completed += 1;
                stdout.print("Task completed successfully\n\n", .{}) catch {};
                logToFile(allocator, log_file, "Task {s} completed successfully\n", .{task.id});
            } else {
                // Increment failure count - need to dupe key since task.id will be freed
                const current_failures = consecutive_failures.get(task.id) orelse 0;
                const new_failures = current_failures + 1;
                const key = allocator.dupe(u8, task.id) catch task.id;
                consecutive_failures.put(key, new_failures) catch {};

                stdout.print("Task failed ({} consecutive failures)\n", .{new_failures}) catch {};
                logToFile(allocator, log_file, "Task {s} failed ({} consecutive failures)\n", .{ task.id, new_failures });
                if (new_failures >= 3) {
                    stdout.print("Skipping task after 3 consecutive failures\n", .{}) catch {};
                }
                stdout.print("\n", .{}) catch {};
            }
        }

        // If --once flag is set, exit after first task
        if (once) {
            stdout.print("Exiting after one task (--once flag set)\n", .{}) catch {};
            break;
        }

        // Delay between tasks
        if (!dry_run and delay > 0) {
            stdout.print("Waiting {} seconds before next task...\n\n", .{delay}) catch {};
            std.Thread.sleep(delay * std.time.ns_per_s);
        }
    }

    stdout.print("RALPH loop completed. {} tasks processed.\n", .{tasks_completed}) catch {};
    logToFile(allocator, log_file, "=== RALPH loop completed: {} tasks processed ===\n\n", .{tasks_completed});
}

const PendingTask = struct {
    id: []const u8,
    content: []const u8,
};

const PendingTasks = struct {
    tasks: []PendingTask,
};

fn getPendingTasks(allocator: std.mem.Allocator) !PendingTasks {
    // Shell out to zagi tasks list --json
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "./zig-out/bin/zagi", "tasks", "list", "--json" },
    }) catch return error.SpawnFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse JSON output
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

    // Filter to pending tasks
    var pending = std.ArrayList(PendingTask){};
    for (parsed.value.tasks) |task| {
        if (!std.mem.eql(u8, task.status, "completed")) {
            pending.append(allocator, .{
                .id = allocator.dupe(u8, task.id) catch continue,
                .content = allocator.dupe(u8, task.content) catch continue,
            }) catch continue;
        }
    }

    return PendingTasks{ .tasks = pending.toOwnedSlice(allocator) catch &.{} };
}

fn createPrompt(allocator: std.mem.Allocator, task_id: []const u8, task_content: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\You are working on: {s}
        \\
        \\Task: {s}
        \\
        \\Instructions:
        \\1. Read AGENTS.md for project context and build instructions
        \\2. Complete this ONE task only
        \\3. Verify your work (run tests, check build)
        \\4. Commit your changes with: git commit -m "<message>"
        \\5. Mark the task done: ./zig-out/bin/zagi tasks done {s}
        \\6. If you learn critical operational details, update AGENTS.md
        \\
        \\Rules:
        \\- NEVER git push (only commit)
        \\- ONLY work on this one task
        \\- Exit when done so the next task can start
    , .{ task_id, task_content, task_id });
}

fn executeTask(allocator: std.mem.Allocator, executor: []const u8, model: ?[]const u8, agent_cmd: ?[]const u8, task_id: []const u8, task_content: []const u8) !bool {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const prompt = try createPrompt(allocator, task_id, task_content);
    defer allocator.free(prompt);

    var runner_args = std.ArrayList([]const u8){};
    defer runner_args.deinit(allocator);

    // Build command based on agent_cmd override or executor
    if (agent_cmd) |cmd| {
        // Custom command from ZAGI_AGENT_CMD - split by spaces
        var parts = std.mem.splitScalar(u8, cmd, ' ');
        while (parts.next()) |part| {
            if (part.len > 0) {
                try runner_args.append(allocator, part);
            }
        }
        try runner_args.append(allocator, prompt);
    } else if (std.mem.eql(u8, executor, "claude")) {
        try runner_args.append(allocator, "claude");
        try runner_args.append(allocator, "-p");
        if (model) |m| {
            try runner_args.append(allocator, "--model");
            try runner_args.append(allocator, m);
        }
        try runner_args.append(allocator, prompt);
    } else if (std.mem.eql(u8, executor, "opencode")) {
        try runner_args.append(allocator, "opencode");
        try runner_args.append(allocator, "run");
        if (model) |m| {
            try runner_args.append(allocator, "-m");
            try runner_args.append(allocator, m);
        }
        try runner_args.append(allocator, prompt);
    } else {
        // Custom executor from ZAGI_AGENT - split by spaces
        var parts = std.mem.splitScalar(u8, executor, ' ');
        while (parts.next()) |part| {
            if (part.len > 0) {
                try runner_args.append(allocator, part);
            }
        }
        try runner_args.append(allocator, prompt);
    }

    // Execute the command with inherited stdio
    // Note: Child inherits environment from parent, including ZAGI_AGENT if set
    var child = std.process.Child.init(runner_args.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        stderr.print("Error executing runner: {s}\n", .{@errorName(err)}) catch {};
        return false;
    };

    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}
