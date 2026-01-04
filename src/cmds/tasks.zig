const std = @import("std");
const git = @import("git.zig");
const c = git.c;
const json = std.json;

/// Escape a string for JSON output (escapes quotes, backslashes, newlines, etc.)
fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    for (input) |char| {
        switch (char) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (char < 0x20) {
                    // Control characters - output as \u00XX
                    var buf: [6]u8 = undefined;
                    const len = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{char}) catch unreachable;
                    try result.appendSlice(allocator, len);
                } else {
                    try result.append(allocator, char);
                }
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

pub const help =
    \\usage: git tasks <command> [options]
    \\
    \\Task management for git repositories.
    \\
    \\Commands:
    \\  add <content>           Add a new task
    \\  list                    List all tasks
    \\  show <id>               Show task details
    \\  edit <id> <content>     Edit task content
    \\  delete <id>             Delete a task
    \\  done <id>               Mark task as complete
    \\  pr                      Export tasks as markdown for PR description
    \\
    \\Options:
    \\  --json                 Output in JSON format
    \\  -h, --help             Show this help message
    \\
    \\Examples:
    \\  git tasks add "Fix authentication bug"
    \\  git tasks list
    \\  git tasks show task-001
    \\  git tasks edit task-001 "Fix authentication and authorization bug"
    \\  git tasks delete task-001
    \\  git tasks done task-001
    \\  git tasks pr
    \\
;

pub const Error = git.Error || error{
    InvalidCommand,
    MissingTaskContent,
    InvalidTaskId,
    TaskNotFound,
    RefReadFailed,
    RefWriteFailed,
    RefNotFound,
    BranchNameTooLong,
    AllocationError,
    JsonParseError,
    JsonWriteError,
    OutOfMemory,
};

/// Represents a single task
const Task = struct {
    id: []const u8,
    content: []const u8,
    status: []const u8 = "pending",
    created: i64,
    completed: ?i64 = null,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.content);
        allocator.free(self.status);
    }
};


/// Container for all tasks in a branch
const TaskList = struct {
    tasks: std.ArrayList(Task),
    next_id: u32 = 1,

    const Self = @This();

    pub fn init(_: std.mem.Allocator) Self {
        return Self{
            .tasks = std.ArrayList(Task){},
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.tasks.items) |*task| {
            task.deinit(allocator);
        }
        self.tasks.deinit(allocator);
    }

    pub fn generateId(self: *Self, allocator: std.mem.Allocator) Error![]u8 {
        const id = std.fmt.allocPrint(allocator, "task-{:03}", .{self.next_id}) catch return Error.OutOfMemory;
        self.next_id += 1;
        return id;
    }

    /// Serialize TaskList to simple text format
    pub fn toJson(self: Self, allocator: std.mem.Allocator) Error![]u8 {
        // Use a simple line-based format for now to avoid JSON complexity
        var lines = std.ArrayList([]const u8){};
        defer {
            for (lines.items) |line| {
                allocator.free(line);
            }
            lines.deinit(allocator);
        }

        // First line: next_id
        const next_id_line = std.fmt.allocPrint(allocator, "next_id:{}", .{self.next_id}) catch return Error.OutOfMemory;
        lines.append(allocator, next_id_line) catch return Error.OutOfMemory;

        // Task lines: id|content|status|created|completed
        for (self.tasks.items) |task| {
            const completed_str = if (task.completed) |comp_time| std.fmt.allocPrint(allocator, "{}", .{comp_time}) catch return Error.OutOfMemory else allocator.dupe(u8, "") catch return Error.OutOfMemory;

            const task_line = std.fmt.allocPrint(allocator, "task:{s}|{s}|{s}|{}|{s}",
                .{ task.id, task.content, task.status, task.created, completed_str }
            ) catch return Error.OutOfMemory;
            lines.append(allocator, task_line) catch return Error.OutOfMemory;

            if (task.completed != null) {
                allocator.free(completed_str);
            }
        }

        // Join lines with newlines
        var total_len: usize = 0;
        for (lines.items) |line| {
            total_len += line.len + 1; // +1 for newline
        }

        if (total_len == 0) return allocator.dupe(u8, "") catch return Error.OutOfMemory;

        var result = allocator.alloc(u8, total_len - 1) catch return Error.OutOfMemory; // -1 to avoid trailing newline
        var pos: usize = 0;
        for (lines.items, 0..) |line, i| {
            @memcpy(result[pos..pos + line.len], line);
            pos += line.len;
            if (i < lines.items.len - 1) {
                result[pos] = '\n';
                pos += 1;
            }
        }

        return result;
    }

    /// Deserialize TaskList from simple text format
    pub fn fromJson(allocator: std.mem.Allocator, data_str: []const u8) Error!Self {
        var task_list = TaskList.init(allocator);

        var lines = std.mem.splitSequence(u8, data_str, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "next_id:")) {
                const id_str = line[8..];
                task_list.next_id = std.fmt.parseInt(u32, id_str, 10) catch 1;
            } else if (std.mem.startsWith(u8, line, "task:")) {
                const task_data = line[5..];
                var parts = std.mem.splitSequence(u8, task_data, "|");

                var task = Task{
                    .id = "",
                    .content = "",
                    .status = "pending",
                    .created = 0,
                };

                const id = parts.next() orelse continue; // Skip malformed lines without ID
                if (id.len == 0) continue; // Skip tasks with empty IDs

                const content = parts.next() orelse continue; // Skip malformed lines without content

                task.id = allocator.dupe(u8, id) catch return Error.AllocationError;
                task.content = allocator.dupe(u8, content) catch {
                    allocator.free(task.id);
                    return Error.AllocationError;
                };

                if (parts.next()) |status| {
                    if (status.len > 0) {
                        task.status = allocator.dupe(u8, status) catch {
                            allocator.free(task.id);
                            allocator.free(task.content);
                            return Error.AllocationError;
                        };
                    } else {
                        task.status = allocator.dupe(u8, "pending") catch {
                            allocator.free(task.id);
                            allocator.free(task.content);
                            return Error.AllocationError;
                        };
                    }
                } else {
                    task.status = allocator.dupe(u8, "pending") catch {
                        allocator.free(task.id);
                        allocator.free(task.content);
                        return Error.AllocationError;
                    };
                }

                if (parts.next()) |created| {
                    task.created = std.fmt.parseInt(i64, created, 10) catch 0;
                }
                if (parts.next()) |completed| {
                    if (completed.len > 0) {
                        task.completed = std.fmt.parseInt(i64, completed, 10) catch null;
                    }
                }
                // Skip any remaining fields (legacy 'after' field for backwards compatibility)
                _ = parts.next();

                task_list.tasks.append(allocator, task) catch {
                    allocator.free(task.id);
                    allocator.free(task.content);
                    allocator.free(task.status);
                    return Error.AllocationError;
                };
            }
        }

        return task_list;
    }
};

/// Get current branch name
fn getCurrentBranch(repo: ?*c.git_repository, allocator: std.mem.Allocator) Error![]u8 {
    var head_ref: ?*c.git_reference = null;
    if (c.git_repository_head(&head_ref, repo) < 0) {
        return Error.RefReadFailed;
    }
    defer c.git_reference_free(head_ref);

    const ref_name = c.git_reference_name(head_ref);
    if (ref_name == null) {
        return Error.RefReadFailed;
    }

    const full_name = std.mem.sliceTo(ref_name, 0);
    const prefix = "refs/heads/";
    if (!std.mem.startsWith(u8, full_name, prefix)) {
        return Error.RefReadFailed;
    }

    const branch_name = full_name[prefix.len..];
    return allocator.dupe(u8, branch_name) catch return Error.OutOfMemory;
}

/// Build a ref name like "refs/tasks/main" from a branch name
fn buildTaskRefName(branch: []const u8, allocator: std.mem.Allocator) Error![]u8 {
    const prefix = "refs/tasks/";
    const total_len = prefix.len + branch.len;

    if (total_len > 256) { // reasonable limit
        return Error.BranchNameTooLong;
    }

    var ref_name = allocator.alloc(u8, total_len) catch return Error.AllocationError;
    @memcpy(ref_name[0..prefix.len], prefix);
    @memcpy(ref_name[prefix.len..], branch);

    return ref_name;
}

/// Read task data from refs/tasks/<branch>
fn readRef(repo: ?*c.git_repository, allocator: std.mem.Allocator) Error!?[]u8 {
    // Get current branch name
    const branch = getCurrentBranch(repo, allocator) catch return Error.RefReadFailed;
    defer allocator.free(branch);

    // Build ref name like "refs/tasks/main"
    const ref_name = buildTaskRefName(branch, allocator) catch return Error.RefReadFailed;
    defer allocator.free(ref_name);

    // Create null-terminated string for libgit2
    const ref_name_z = allocator.allocSentinel(u8, ref_name.len, 0) catch return Error.AllocationError;
    defer allocator.free(ref_name_z);
    @memcpy(ref_name_z, ref_name);

    // Look up the reference
    var tasks_ref: ?*c.git_reference = null;
    const lookup_result = c.git_reference_lookup(&tasks_ref, repo, ref_name_z.ptr);
    if (lookup_result < 0) {
        if (lookup_result == c.GIT_ENOTFOUND) {
            return null; // Ref doesn't exist yet, not an error
        }
        return Error.RefReadFailed;
    }
    defer c.git_reference_free(tasks_ref);

    // Get the target OID
    const target_oid = c.git_reference_target(tasks_ref);
    if (target_oid == null) {
        return Error.RefReadFailed;
    }

    // Look up the blob object
    var blob: ?*c.git_blob = null;
    if (c.git_blob_lookup(&blob, repo, target_oid) < 0) {
        return Error.RefReadFailed;
    }
    defer c.git_blob_free(blob);

    // Get blob content
    const content_ptr = c.git_blob_rawcontent(blob);
    const content_size = c.git_blob_rawsize(blob);

    if (content_ptr == null or content_size == 0) {
        const empty = allocator.dupe(u8, "") catch return Error.OutOfMemory; // Empty content
        return empty;
    }

    const content_slice = @as([*]const u8, @ptrCast(content_ptr))[0..content_size];
    const result = allocator.dupe(u8, content_slice) catch return Error.OutOfMemory;
    return result;
}

/// Load TaskList from refs/tasks/<branch>
fn loadTaskList(repo: ?*c.git_repository, allocator: std.mem.Allocator) Error!TaskList {
    const content = readRef(repo, allocator) catch |err| switch (err) {
        Error.RefNotFound => return TaskList.init(allocator),
        else => return err,
    };

    if (content == null) {
        return TaskList.init(allocator);
    }

    defer if (content) |json_content| allocator.free(json_content);

    if (content.?.len == 0) {
        return TaskList.init(allocator);
    }

    return TaskList.fromJson(allocator, content.?);
}

/// Save TaskList to refs/tasks/<branch>
fn saveTaskList(repo: ?*c.git_repository, task_list: TaskList, allocator: std.mem.Allocator) Error!void {
    const json_content = try task_list.toJson(allocator);
    defer allocator.free(json_content);

    try writeRef(repo, json_content, allocator);
}

/// Write task data to refs/tasks/<branch>
fn writeRef(repo: ?*c.git_repository, content: []const u8, allocator: std.mem.Allocator) Error!void {
    // Get current branch name
    const branch = getCurrentBranch(repo, allocator) catch return Error.RefWriteFailed;
    defer allocator.free(branch);

    // Build ref name like "refs/tasks/main"
    const ref_name = buildTaskRefName(branch, allocator) catch return Error.RefWriteFailed;
    defer allocator.free(ref_name);

    // Create null-terminated string for libgit2
    const ref_name_z = allocator.allocSentinel(u8, ref_name.len, 0) catch return Error.AllocationError;
    defer allocator.free(ref_name_z);
    @memcpy(ref_name_z, ref_name);

    // Create blob from content
    var blob_oid: c.git_oid = undefined;
    if (c.git_blob_create_from_buffer(&blob_oid, repo, content.ptr, content.len) < 0) {
        return Error.RefWriteFailed;
    }

    // Create or update the reference to point to the blob
    var tasks_ref: ?*c.git_reference = null;
    if (c.git_reference_create(&tasks_ref, repo, ref_name_z.ptr, &blob_oid, 1, null) < 0) {
        return Error.RefWriteFailed;
    }
    defer c.git_reference_free(tasks_ref);
}

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (args.len < 3) {
        stdout.print("{s}", .{help}) catch {};
        return;
    }

    const subcommand = std.mem.sliceTo(args[2], 0);

    // Handle help flags
    if (std.mem.eql(u8, subcommand, "-h") or std.mem.eql(u8, subcommand, "--help")) {
        stdout.print("{s}", .{help}) catch {};
        return;
    }

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

    // Route to subcommands
    if (std.mem.eql(u8, subcommand, "add")) {
        try runAdd(allocator, args, repo);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        try runList(allocator, args, repo);
    } else if (std.mem.eql(u8, subcommand, "show")) {
        try runShow(allocator, args, repo);
    } else if (std.mem.eql(u8, subcommand, "edit")) {
        try runEdit(allocator, args, repo);
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        try runDelete(allocator, args, repo);
    } else if (std.mem.eql(u8, subcommand, "done")) {
        try runDone(allocator, args, repo);
    } else if (std.mem.eql(u8, subcommand, "pr")) {
        try runPr(allocator, args, repo);
    } else {
        stdout.print("error: unknown command '{s}'\n\n{s}", .{ subcommand, help }) catch {};
        return Error.InvalidCommand;
    }
}

fn runAdd(allocator: std.mem.Allocator, args: [][:0]u8, repo: ?*c.git_repository) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Need at least: tasks add <content>
    if (args.len < 4) {
        stdout.print("error: missing task content\n\nusage: git tasks add <content>\n", .{}) catch {};
        return Error.MissingTaskContent;
    }

    // Parse arguments for content and --json flag
    var content: ?[]const u8 = null;
    var use_json = false;
    var i: usize = 3; // Start after "git tasks add"

    while (i < args.len) {
        const arg = std.mem.sliceTo(args[i], 0);

        if (std.mem.eql(u8, arg, "--json")) {
            use_json = true;
        } else if (content == null) {
            // First non-flag argument is the content
            content = arg;
        } else {
            // Multiple content arguments - concatenate with spaces
            const existing = content.?;
            const combined = std.fmt.allocPrint(allocator, "{s} {s}", .{ existing, arg }) catch return Error.AllocationError;
            // Note: we're not tracking these allocations, but they're short-lived
            content = combined;
        }
        i += 1;
    }

    if (content == null or content.?.len == 0) {
        stdout.print("error: task content cannot be empty\n", .{}) catch {};
        return Error.MissingTaskContent;
    }

    // Load existing tasks
    var task_list = loadTaskList(repo, allocator) catch |err| {
        stdout.print("error: failed to load tasks: {}\n", .{err}) catch {};
        return err;
    };
    defer task_list.deinit(allocator);

    // Generate new task ID
    const task_id = task_list.generateId(allocator) catch return Error.AllocationError;

    // Get current timestamp (Unix seconds)
    const now = std.time.timestamp();

    // Create the new task - allocate fields with proper cleanup on failure
    const task_content = allocator.dupe(u8, content.?) catch {
        allocator.free(task_id);
        return Error.AllocationError;
    };

    const task_status = allocator.dupe(u8, "pending") catch {
        allocator.free(task_id);
        allocator.free(task_content);
        return Error.AllocationError;
    };

    const new_task = Task{
        .id = task_id,
        .content = task_content,
        .status = task_status,
        .created = now,
    };

    // Add task to list - after this, task_list owns the allocations
    task_list.tasks.append(allocator, new_task) catch {
        allocator.free(task_id);
        allocator.free(task_content);
        allocator.free(task_status);
        return Error.AllocationError;
    };

    // Save updated task list
    // Note: After append succeeds, task_list.deinit handles cleanup on any error path
    saveTaskList(repo, task_list, allocator) catch |err| {
        stdout.print("error: failed to save tasks: {}\n", .{err}) catch {};
        return err;
    };

    // Output confirmation
    if (use_json) {
        // Manually construct JSON output
        const json_output = try std.fmt.allocPrint(allocator,
            "{{\"id\":\"{s}\",\"content\":\"{s}\",\"status\":\"pending\",\"created\":{},\"completed\":null}}",
            .{ task_id, content.?, now }
        );
        defer allocator.free(json_output);

        stdout.print("{s}\n", .{json_output}) catch {};
    } else {
        stdout.print("created: {s}\n  {s}\n", .{ task_id, content.? }) catch {};
    }
}

fn runList(allocator: std.mem.Allocator, args: [][:0]u8, repo: ?*c.git_repository) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Parse --json flag
    var use_json = false;
    for (args[3..]) |arg| {
        const a = std.mem.sliceTo(arg, 0);
        if (std.mem.eql(u8, a, "--json")) {
            use_json = true;
            break;
        }
    }

    // Load task list from git ref
    var task_list = loadTaskList(repo, allocator) catch |err| {
        stdout.print("error: failed to load tasks: {}\n", .{err}) catch {};
        return err;
    };
    defer task_list.deinit(allocator);

    if (use_json) {
        // JSON output using std.json
        const JsonTask = struct {
            id: []const u8,
            content: []const u8,
            status: []const u8,
            created: i64,
            completed: ?i64,
        };


        // Convert tasks to JSON-compatible format
        var json_tasks = std.ArrayList(JsonTask){};
        defer json_tasks.deinit(allocator);

        for (task_list.tasks.items) |task| {
            json_tasks.append(allocator, JsonTask{
                .id = task.id,
                .content = task.content,
                .status = task.status,
                .created = task.created,
                .completed = task.completed,
            }) catch return Error.AllocationError;
        }

        // Manually construct JSON array
        var json_output = std.ArrayList(u8){};
        defer json_output.deinit(allocator);

        try json_output.appendSlice(allocator, "{\"tasks\":[");

        for (json_tasks.items, 0..) |task, i| {
            if (i > 0) try json_output.appendSlice(allocator, ",");

            const completed_str = if (task.completed) |comp| try std.fmt.allocPrint(allocator, "{}", .{comp}) else allocator.dupe(u8, "null") catch return Error.AllocationError;
            defer allocator.free(completed_str);

            // Escape content for JSON (handles quotes, newlines, etc.)
            const escaped_content = escapeJsonString(allocator, task.content) catch return Error.AllocationError;
            defer allocator.free(escaped_content);

            const task_json = try std.fmt.allocPrint(allocator,
                "{{\"id\":\"{s}\",\"content\":\"{s}\",\"status\":\"{s}\",\"created\":{},\"completed\":{s}}}",
                .{ task.id, escaped_content, task.status, task.created, completed_str }
            );
            defer allocator.free(task_json);

            try json_output.appendSlice(allocator, task_json);
        }

        try json_output.appendSlice(allocator, "]}");

        stdout.print("{s}\n", .{json_output.items}) catch {};
        return;
    }

    // If no tasks, show empty state
    if (task_list.tasks.items.len == 0) {
        stdout.print("no tasks found\n", .{}) catch {};
        return;
    }

    // Display task count summary
    var pending_count: usize = 0;
    var completed_count: usize = 0;
    for (task_list.tasks.items) |task| {
        if (std.mem.eql(u8, task.status, "completed")) {
            completed_count += 1;
        } else {
            pending_count += 1;
        }
    }

    stdout.print("tasks: {} total ({} pending, {} completed)\n\n",
        .{ task_list.tasks.items.len, pending_count, completed_count }) catch {};

    // List all tasks with compact format
    for (task_list.tasks.items) |task| {
        const status_mark = if (std.mem.eql(u8, task.status, "completed")) "✓" else " ";
        stdout.print("[{s}] {s}\n  {s}\n",
            .{ status_mark, task.id, task.content }) catch {};
    }
}

/// Format Unix timestamp to human-readable date string
fn formatTimestamp(timestamp: i64, allocator: std.mem.Allocator) Error![]u8 {
    // For now, show relative time (seconds ago, minutes ago, etc.)
    const now = std.time.timestamp();
    const diff = now - timestamp;

    if (diff < 60) {
        return std.fmt.allocPrint(allocator, "{} seconds ago", .{diff}) catch return Error.AllocationError;
    } else if (diff < 3600) {
        const minutes = @divTrunc(diff, 60);
        return std.fmt.allocPrint(allocator, "{} minutes ago", .{minutes}) catch return Error.AllocationError;
    } else if (diff < 86400) {
        const hours = @divTrunc(diff, 3600);
        return std.fmt.allocPrint(allocator, "{} hours ago", .{hours}) catch return Error.AllocationError;
    } else {
        const days = @divTrunc(diff, 86400);
        return std.fmt.allocPrint(allocator, "{} days ago", .{days}) catch return Error.AllocationError;
    }
}

fn runShow(allocator: std.mem.Allocator, args: [][:0]u8, repo: ?*c.git_repository) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Need at least: tasks show <id>
    if (args.len < 4) {
        stdout.print("error: missing task ID\n\nusage: git tasks show <id> [--json]\n", .{}) catch {};
        return Error.InvalidTaskId;
    }

    // Parse arguments for task ID and --json flag
    var task_id: ?[]const u8 = null;
    var use_json = false;

    for (args[3..]) |arg| {
        const a = std.mem.sliceTo(arg, 0);
        if (std.mem.eql(u8, a, "--json")) {
            use_json = true;
        } else if (task_id == null) {
            task_id = a;
        }
    }

    if (task_id == null) {
        stdout.print("error: missing task ID\n\nusage: git tasks show <id> [--json]\n", .{}) catch {};
        return Error.InvalidTaskId;
    }

    // Load task list
    var task_list = loadTaskList(repo, allocator) catch |err| {
        stdout.print("error: failed to load tasks: {}\n", .{err}) catch {};
        return err;
    };
    defer task_list.deinit(allocator);

    // Find the task by ID
    var found_task: ?Task = null;
    for (task_list.tasks.items) |task| {
        if (std.mem.eql(u8, task.id, task_id.?)) {
            found_task = task;
            break;
        }
    }

    if (found_task == null) {
        stdout.print("error: task '{s}' not found\n", .{task_id.?}) catch {};
        return Error.TaskNotFound;
    }

    const task = found_task.?;

    if (use_json) {
        // JSON output
        const completed_str = if (task.completed) |comp| try std.fmt.allocPrint(allocator, "{}", .{comp}) else allocator.dupe(u8, "null") catch return Error.AllocationError;
        defer allocator.free(completed_str);

        const json_output = try std.fmt.allocPrint(allocator,
            "{{\"id\":\"{s}\",\"content\":\"{s}\",\"status\":\"{s}\",\"created\":{},\"completed\":{s}}}",
            .{ task.id, task.content, task.status, task.created, completed_str }
        );
        defer allocator.free(json_output);

        stdout.print("{s}\n", .{json_output}) catch {};
        return;
    }

    // Format created timestamp
    const created_time = formatTimestamp(task.created, allocator) catch return Error.AllocationError;
    defer allocator.free(created_time);

    // Format completed timestamp if present
    var completed_time: ?[]u8 = null;
    if (task.completed) |comp| {
        completed_time = formatTimestamp(comp, allocator) catch return Error.AllocationError;
    }
    defer if (completed_time) |ct| allocator.free(ct);

    // Display task details
    stdout.print("task: {s}\n", .{task.id}) catch {};
    stdout.print("content: {s}\n", .{task.content}) catch {};
    stdout.print("status: {s}\n", .{task.status}) catch {};
    stdout.print("created: {s}\n", .{created_time}) catch {};

    if (completed_time) |ct| {
        stdout.print("completed: {s}\n", .{ct}) catch {};
    }
}

fn runDone(allocator: std.mem.Allocator, args: [][:0]u8, repo: ?*c.git_repository) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Need at least: tasks done <id>
    if (args.len < 4) {
        stdout.print("error: missing task ID\n\nusage: git tasks done <id>\n", .{}) catch {};
        return Error.InvalidTaskId;
    }

    const task_id = std.mem.sliceTo(args[3], 0);

    // Load task list
    var task_list = loadTaskList(repo, allocator) catch |err| {
        stdout.print("error: failed to load tasks: {}\n", .{err}) catch {};
        return err;
    };
    defer task_list.deinit(allocator);

    // Find the task by ID and mark as completed
    var found_task: ?*Task = null;
    for (task_list.tasks.items) |*task| {
        if (std.mem.eql(u8, task.id, task_id)) {
            found_task = task;
            break;
        }
    }

    if (found_task == null) {
        stdout.print("error: task '{s}' not found\n", .{task_id}) catch {};
        return Error.TaskNotFound;
    }

    const task = found_task.?;

    // Check if task is already completed
    if (std.mem.eql(u8, task.status, "completed")) {
        stdout.print("task '{s}' already completed\n", .{task_id}) catch {};
        return;
    }

    // Mark task as completed
    allocator.free(task.status); // Free old status string
    task.status = allocator.dupe(u8, "completed") catch return Error.AllocationError;
    task.completed = std.time.timestamp(); // Set completion timestamp

    // Save updated task list
    saveTaskList(repo, task_list, allocator) catch |err| {
        stdout.print("error: failed to save tasks: {}\n", .{err}) catch {};
        return err;
    };

    // Output confirmation
    stdout.print("completed: {s}\n  {s}\n", .{ task_id, task.content }) catch {};
}

fn runReady(allocator: std.mem.Allocator, args: [][:0]u8, repo: ?*c.git_repository) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Parse --json flag
    var use_json = false;
    for (args[3..]) |arg| {
        const a = std.mem.sliceTo(arg, 0);
        if (std.mem.eql(u8, a, "--json")) {
            use_json = true;
            break;
        }
    }

    // Load task list from git ref
    var task_list = loadTaskList(repo, allocator) catch |err| {
        stdout.print("error: failed to load tasks: {}\n", .{err}) catch {};
        return err;
    };
    defer task_list.deinit(allocator);

    // If no tasks, show empty state
    if (task_list.tasks.items.len == 0) {
        stdout.print("no tasks found\n", .{}) catch {};
        return;
    }

    // Find pending tasks (all pending tasks are ready without dependencies)
    var ready_tasks = std.ArrayList(Task){};
    defer ready_tasks.deinit(allocator);

    for (task_list.tasks.items) |task| {
        if (!std.mem.eql(u8, task.status, "completed")) {
            ready_tasks.append(allocator, task) catch return Error.AllocationError;
        }
    }

    // If no ready tasks, show empty state
    if (ready_tasks.items.len == 0) {
        if (use_json) {
            stdout.print("[]\n", .{}) catch {};
        } else {
            stdout.print("no pending tasks\n", .{}) catch {};
        }
        return;
    }

    if (use_json) {
        // JSON output - array of tasks
        stdout.print("[", .{}) catch {};
        for (ready_tasks.items, 0..) |task, i| {
            const completed_str = if (task.completed) |comp| try std.fmt.allocPrint(allocator, "{}", .{comp}) else allocator.dupe(u8, "null") catch return Error.AllocationError;
            defer allocator.free(completed_str);

            const json_output = try std.fmt.allocPrint(allocator,
                "{{\"id\":\"{s}\",\"content\":\"{s}\",\"status\":\"{s}\",\"created\":{},\"completed\":{s}}}",
                .{ task.id, task.content, task.status, task.created, completed_str }
            );
            defer allocator.free(json_output);

            if (i > 0) {
                stdout.print(",", .{}) catch {};
            }
            stdout.print("{s}", .{json_output}) catch {};
        }
        stdout.print("]\n", .{}) catch {};
    } else {
        // Display ready task count
        stdout.print("ready: {} task{s}\n\n", .{ ready_tasks.items.len, if (ready_tasks.items.len == 1) "" else "s" }) catch {};

        // List ready tasks with compact format
        for (ready_tasks.items) |task| {
            stdout.print("[ ] {s}\n  {s}\n", .{ task.id, task.content }) catch {};
        }
    }
}

fn runPr(allocator: std.mem.Allocator, args: [][:0]u8, repo: ?*c.git_repository) Error!void {
    _ = args; // No additional args needed for pr
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Load task list from git ref
    var task_list = loadTaskList(repo, allocator) catch |err| {
        stdout.print("error: failed to load tasks: {}\n", .{err}) catch {};
        return err;
    };
    defer task_list.deinit(allocator);

    // If no tasks, show empty state
    if (task_list.tasks.items.len == 0) {
        stdout.print("## Tasks\n\nNo tasks found.\n", .{}) catch {};
        return;
    }

    // Separate tasks by status
    var completed_tasks = std.ArrayList(Task){};
    var pending_tasks = std.ArrayList(Task){};
    defer completed_tasks.deinit(allocator);
    defer pending_tasks.deinit(allocator);

    for (task_list.tasks.items) |task| {
        if (std.mem.eql(u8, task.status, "completed")) {
            completed_tasks.append(allocator, task) catch return Error.AllocationError;
        } else {
            pending_tasks.append(allocator, task) catch return Error.AllocationError;
        }
    }

    // Generate PR markdown
    stdout.print("## Tasks\n\n", .{}) catch {};

    // Show completed tasks
    if (completed_tasks.items.len > 0) {
        stdout.print("### Completed\n\n", .{}) catch {};
        for (completed_tasks.items) |task| {
            stdout.print("- [x] {s}\n", .{task.content}) catch {};
        }
        stdout.print("\n", .{}) catch {};
    }

    // Show pending tasks
    if (pending_tasks.items.len > 0) {
        stdout.print("### Pending\n\n", .{}) catch {};
        for (pending_tasks.items) |task| {
            stdout.print("- [ ] {s}\n", .{task.content}) catch {};
        }
        stdout.print("\n", .{}) catch {};
    }
}

fn runEdit(allocator: std.mem.Allocator, args: [][:0]u8, repo: ?*c.git_repository) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Check if we should block this operation in agent mode
    const guardrails = @import("../guardrails.zig");
    if (guardrails.isAgentMode()) {
        stdout.print("error: edit command blocked (ZAGI_AGENT is set)\n", .{}) catch {};
        stdout.print("reason: modifying tasks could cause data loss\n", .{}) catch {};
        return Error.InvalidCommand;
    }

    // Need at least: tasks edit <id> <content>
    if (args.len < 5) {
        stdout.print("error: missing task ID or content\n\nusage: git tasks edit <id> <content>\n", .{}) catch {};
        return Error.InvalidTaskId;
    }

    const task_id = std.mem.sliceTo(args[3], 0);

    // Parse content arguments (everything from args[4] onwards)
    var content_parts = std.ArrayList([]const u8){};
    defer content_parts.deinit(allocator);

    for (args[4..]) |arg| {
        const arg_str = std.mem.sliceTo(arg, 0);
        if (!std.mem.eql(u8, arg_str, "--json")) { // Skip --json flag for content
            content_parts.append(allocator, arg_str) catch return Error.AllocationError;
        }
    }

    if (content_parts.items.len == 0) {
        stdout.print("error: task content cannot be empty\n", .{}) catch {};
        return Error.MissingTaskContent;
    }

    // Join content parts with spaces
    var content_buffer = std.ArrayList(u8){};
    defer content_buffer.deinit(allocator);

    for (content_parts.items, 0..) |part, i| {
        if (i > 0) {
            content_buffer.append(allocator, ' ') catch return Error.AllocationError;
        }
        content_buffer.appendSlice(allocator, part) catch return Error.AllocationError;
    }

    const new_content = content_buffer.toOwnedSlice(allocator) catch return Error.AllocationError;
    defer allocator.free(new_content);

    // Check for --json flag
    var use_json = false;
    for (args[3..]) |arg| {
        const a = std.mem.sliceTo(arg, 0);
        if (std.mem.eql(u8, a, "--json")) {
            use_json = true;
            break;
        }
    }

    // Load task list
    var task_list = loadTaskList(repo, allocator) catch |err| {
        stdout.print("error: failed to load tasks: {}\n", .{err}) catch {};
        return err;
    };
    defer task_list.deinit(allocator);

    // Find the task by ID
    var found_task: ?*Task = null;
    for (task_list.tasks.items) |*task| {
        if (std.mem.eql(u8, task.id, task_id)) {
            found_task = task;
            break;
        }
    }

    if (found_task == null) {
        stdout.print("error: task '{s}' not found\n", .{task_id}) catch {};
        return Error.TaskNotFound;
    }

    const task = found_task.?;

    // Update task content
    allocator.free(task.content); // Free old content
    task.content = allocator.dupe(u8, new_content) catch return Error.AllocationError;

    // Save updated task list
    saveTaskList(repo, task_list, allocator) catch |err| {
        stdout.print("error: failed to save tasks: {}\n", .{err}) catch {};
        return err;
    };

    // Output confirmation
    if (use_json) {
        // JSON output
        const completed_str = if (task.completed) |comp| try std.fmt.allocPrint(allocator, "{}", .{comp}) else allocator.dupe(u8, "null") catch return Error.AllocationError;
        defer allocator.free(completed_str);

        const json_output = try std.fmt.allocPrint(allocator,
            "{{\"id\":\"{s}\",\"content\":\"{s}\",\"status\":\"{s}\",\"created\":{},\"completed\":{s}}}",
            .{ task.id, task.content, task.status, task.created, completed_str }
        );
        defer allocator.free(json_output);

        stdout.print("{s}\n", .{json_output}) catch {};
    } else {
        stdout.print("updated: {s}\n  {s}\n", .{ task_id, new_content }) catch {};
    }
}

fn runDelete(allocator: std.mem.Allocator, args: [][:0]u8, repo: ?*c.git_repository) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Check if we should block this operation in agent mode
    const guardrails = @import("../guardrails.zig");
    if (guardrails.isAgentMode()) {
        stdout.print("error: delete command blocked (ZAGI_AGENT is set)\n", .{}) catch {};
        stdout.print("reason: deleting tasks causes permanent data loss\n", .{}) catch {};
        return Error.InvalidCommand;
    }

    // Need at least: tasks delete <id>
    if (args.len < 4) {
        stdout.print("error: missing task ID\n\nusage: git tasks delete <id>\n", .{}) catch {};
        return Error.InvalidTaskId;
    }

    const task_id = std.mem.sliceTo(args[3], 0);

    // Check for --json flag
    var use_json = false;
    for (args[3..]) |arg| {
        const a = std.mem.sliceTo(arg, 0);
        if (std.mem.eql(u8, a, "--json")) {
            use_json = true;
            break;
        }
    }

    // Load task list
    var task_list = loadTaskList(repo, allocator) catch |err| {
        stdout.print("error: failed to load tasks: {}\n", .{err}) catch {};
        return err;
    };
    defer task_list.deinit(allocator);

    // Find the task by ID and get its content for confirmation
    var found_index: ?usize = null;
    var task_content: []const u8 = "";
    for (task_list.tasks.items, 0..) |task, i| {
        if (std.mem.eql(u8, task.id, task_id)) {
            found_index = i;
            task_content = task.content;
            break;
        }
    }

    if (found_index == null) {
        stdout.print("error: task '{s}' not found\n", .{task_id}) catch {};
        return Error.TaskNotFound;
    }

    // Remove the task
    var removed_task = task_list.tasks.swapRemove(found_index.?);

    // Save updated task list
    saveTaskList(repo, task_list, allocator) catch |err| {
        stdout.print("error: failed to save tasks: {}\n", .{err}) catch {};
        removed_task.deinit(allocator);
        return err;
    };

    // Output confirmation (must happen before deinit frees task_content)
    if (use_json) {
        stdout.print("{{\"deleted\":\"{s}\"}}\n", .{task_id}) catch {};
    } else {
        stdout.print("deleted: {s}\n  {s}\n", .{ task_id, task_content }) catch {};
    }

    removed_task.deinit(allocator);
}

// Tests
const testing = std.testing;

test "buildTaskRefName - basic branch name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ref_name = try buildTaskRefName("main", allocator);
    try testing.expectEqualStrings("refs/tasks/main", ref_name);
}

test "buildTaskRefName - feature branch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ref_name = try buildTaskRefName("feature/auth", allocator);
    try testing.expectEqualStrings("refs/tasks/feature/auth", ref_name);
}

test "buildTaskRefName - long branch name fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a branch name that makes the total ref name > 256 chars
    var long_name: [300]u8 = undefined;
    @memset(&long_name, 'x');

    const result = buildTaskRefName(&long_name, allocator);
    try testing.expectError(Error.BranchNameTooLong, result);
}

test "TaskList.fromJson - handles malformed data gracefully" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test empty string
    {
        var task_list = try TaskList.fromJson(allocator, "");
        defer task_list.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), task_list.tasks.items.len);
        try testing.expectEqual(@as(u32, 1), task_list.next_id);
    }

    // Test garbage data - should skip invalid lines
    {
        var task_list = try TaskList.fromJson(allocator, "random garbage\nmore junk\n");
        defer task_list.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), task_list.tasks.items.len);
    }

    // Test malformed task line with empty ID - should skip
    {
        var task_list = try TaskList.fromJson(allocator, "task:||pending|0|");
        defer task_list.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), task_list.tasks.items.len);
    }

    // Test malformed task line missing fields - should skip
    {
        var task_list = try TaskList.fromJson(allocator, "task:");
        defer task_list.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), task_list.tasks.items.len);
    }

    // Test valid data mixed with invalid
    {
        var task_list = try TaskList.fromJson(allocator, "next_id:5\ngarbage\ntask:task-001|Valid task|pending|1234567890|\ntask:||bad|0|\n");
        defer task_list.deinit(allocator);
        try testing.expectEqual(@as(u32, 5), task_list.next_id);
        try testing.expectEqual(@as(usize, 1), task_list.tasks.items.len);
        try testing.expectEqualStrings("task-001", task_list.tasks.items[0].id);
        try testing.expectEqualStrings("Valid task", task_list.tasks.items[0].content);
    }

    // Test invalid next_id - should default to 1
    {
        var task_list = try TaskList.fromJson(allocator, "next_id:invalid");
        defer task_list.deinit(allocator);
        try testing.expectEqual(@as(u32, 1), task_list.next_id);
    }

    // Test invalid timestamps - should default to 0
    {
        var task_list = try TaskList.fromJson(allocator, "task:task-001|Content|pending|not_a_number|");
        defer task_list.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), task_list.tasks.items.len);
        try testing.expectEqual(@as(i64, 0), task_list.tasks.items[0].created);
    }
}

test "TaskList.generateId - collision free" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var task_list = TaskList.init(allocator);
    defer task_list.deinit(allocator);

    // Generate several IDs and ensure they're unique
    const id1 = try task_list.generateId(allocator);
    const id2 = try task_list.generateId(allocator);
    const id3 = try task_list.generateId(allocator);

    try testing.expectEqualStrings("task-001", id1);
    try testing.expectEqualStrings("task-002", id2);
    try testing.expectEqualStrings("task-003", id3);

    // Verify next_id was incremented
    try testing.expectEqual(@as(u32, 4), task_list.next_id);

    allocator.free(id1);
    allocator.free(id2);
    allocator.free(id3);
}

test "TaskList.generateId - continues from loaded state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Simulate loading a task list that already has tasks
    var task_list = try TaskList.fromJson(allocator, "next_id:42\ntask:task-041|Existing task|pending|0|");
    defer task_list.deinit(allocator);

    // Generate new ID should continue from 42
    const new_id = try task_list.generateId(allocator);
    defer allocator.free(new_id);

    try testing.expectEqualStrings("task-042", new_id);
    try testing.expectEqual(@as(u32, 43), task_list.next_id);
}