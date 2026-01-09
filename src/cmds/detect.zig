const std = @import("std");

/// Known AI agents/tools
pub const Agent = enum {
    claude,
    opencode,
    windsurf,
    cursor,
    vscode,
    vscode_fork,
    terminal,

    /// Returns the string name for this agent
    pub fn name(self: Agent) []const u8 {
        return switch (self) {
            .claude => "claude",
            .opencode => "opencode",
            .windsurf => "windsurf",
            .cursor => "cursor",
            .vscode => "vscode",
            .vscode_fork => "vscode-fork",
            .terminal => "terminal",
        };
    }
};

/// Agent mode detection (for guardrails + --prompt requirement)
/// Checks signals that are set by parent process and hard to bypass
pub fn isAgentMode() bool {
    // Native agent signals (set by IDE/CLI parent process)
    if (std.posix.getenv("CLAUDECODE") != null) return true;
    if (std.posix.getenv("OPENCODE") != null) return true;
    // Custom agent signal (must be non-empty to enable agent mode)
    if (std.posix.getenv("ZAGI_AGENT")) |v| {
        if (v.len > 0) return true;
    }
    return false;
}

/// Detect the AI agent/tool from environment
pub fn detectAgent() Agent {
    // CLI tools - most specific signals
    if (std.posix.getenv("CLAUDECODE") != null) return .claude;
    if (std.posix.getenv("OPENCODE") != null) return .opencode;

    // VSCode forks - check app path in VSCODE_GIT_ASKPASS_NODE
    if (std.posix.getenv("VSCODE_GIT_ASKPASS_NODE")) |path| {
        if (std.mem.indexOf(u8, path, "Windsurf") != null) return .windsurf;
        if (std.mem.indexOf(u8, path, "Cursor") != null) return .cursor;
        if (std.mem.indexOf(u8, path, "Code") != null) return .vscode;
        return .vscode_fork;
    }

    return .terminal;
}

// TODO: Extract model from session transcript when surfacing agent metadata
// The model info is available in the session JSONL files and could be parsed
// from there for display in `git log --prompts`

/// Session data for transcript storage
pub const Session = struct {
    path: []const u8,
    transcript: []const u8,
};

/// Read current session transcript
pub fn readCurrentSession(allocator: std.mem.Allocator, agent: Agent, cwd: []const u8) ?Session {
    return switch (agent) {
        .claude => readClaudeCodeSession(allocator, cwd),
        .opencode => readOpenCodeSession(allocator),
        else => null,
    };
}

/// Read Claude Code session from ~/.claude/projects/{project-hash}/
fn readClaudeCodeSession(allocator: std.mem.Allocator, cwd: []const u8) ?Session {
    const home = std.posix.getenv("HOME") orelse return null;

    // Resolve to main repo path (handles worktrees)
    const project_path = resolveMainRepoPath(allocator, cwd) orelse return null;
    defer allocator.free(project_path);

    // Convert to project hash (replace / with -)
    // e.g., /Users/matt/Documents/Github/zagi -> -Users-matt-Documents-Github-zagi
    var project_hash_buf: [512]u8 = undefined;
    var hash_len: usize = 0;
    for (project_path) |char| {
        if (hash_len >= project_hash_buf.len) break;
        project_hash_buf[hash_len] = if (char == '/') '-' else char;
        hash_len += 1;
    }
    const project_hash = project_hash_buf[0..hash_len];

    // Build project directory path
    const project_dir = std.fmt.allocPrint(allocator, "{s}/.claude/projects/{s}", .{ home, project_hash }) catch return null;
    defer allocator.free(project_dir);

    // Find most recent .jsonl file
    var dir = std.fs.cwd().openDir(project_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var most_recent_path: ?[]const u8 = null;
    var most_recent_mtime: i128 = 0;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        // Get file stat for modification time
        const stat = dir.statFile(entry.name) catch continue;
        const mtime = stat.mtime;

        if (most_recent_path == null or mtime > most_recent_mtime) {
            if (most_recent_path) |old| allocator.free(old);
            most_recent_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, entry.name }) catch continue;
            most_recent_mtime = mtime;
        }
    }

    if (most_recent_path) |path| {
        // Read file content
        const file = std.fs.cwd().openFile(path, .{}) catch {
            allocator.free(path);
            return null;
        };
        defer file.close();

        // Read up to 10MB of transcript
        const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
            allocator.free(path);
            return null;
        };

        // Convert JSONL to JSON array
        const transcript = convertJsonlToArray(allocator, content) catch {
            allocator.free(content);
            allocator.free(path);
            return null;
        };
        allocator.free(content);

        return Session{
            .path = path,
            .transcript = transcript,
        };
    }

    return null;
}

/// Convert JSONL (newline-delimited JSON) to a JSON array
fn convertJsonlToArray(allocator: std.mem.Allocator, jsonl: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    try result.append('[');

    var first = true;
    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (!first) {
            try result.append(',');
        }
        first = false;
        try result.appendSlice(trimmed);
    }

    try result.append(']');
    return result.toOwnedSlice();
}

/// Read OpenCode session
fn readOpenCodeSession(allocator: std.mem.Allocator) ?Session {
    const home = std.posix.getenv("HOME") orelse return null;

    // OpenCode stores sessions in ~/.local/share/opencode/storage/session/
    const base_dir = std.fmt.allocPrint(allocator, "{s}/.local/share/opencode/storage/message", .{home}) catch return null;
    defer allocator.free(base_dir);

    // Find most recent session directory
    var dir = std.fs.cwd().openDir(base_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var most_recent_dir: ?[]const u8 = null;
    var most_recent_mtime: i128 = 0;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        const stat = dir.statFile(entry.name) catch continue;
        const mtime = stat.mtime;

        if (most_recent_dir == null or mtime > most_recent_mtime) {
            if (most_recent_dir) |old| allocator.free(old);
            most_recent_dir = allocator.dupe(u8, entry.name) catch continue;
            most_recent_mtime = mtime;
        }
    }

    if (most_recent_dir) |session_id| {
        defer allocator.free(session_id);

        // Read all message files in this session
        const session_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, session_id }) catch return null;

        var messages_dir = std.fs.cwd().openDir(session_dir, .{ .iterate = true }) catch {
            allocator.free(session_dir);
            return null;
        };
        defer messages_dir.close();

        // Collect all messages into an array
        var messages = std.array_list.Managed(u8).init(allocator);
        errdefer messages.deinit();

        messages.append('[') catch return null;

        var first = true;
        var msg_iter = messages_dir.iterate();
        while (msg_iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            const msg_content = messages_dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch continue;
            defer allocator.free(msg_content);

            if (!first) {
                messages.append(',') catch continue;
            }
            first = false;
            messages.appendSlice(msg_content) catch continue;
        }

        messages.append(']') catch return null;

        return Session{
            .path = session_dir,
            .transcript = messages.toOwnedSlice() catch return null,
        };
    }

    return null;
}

// ============================================================================
// Session Checkpoint Support - Structured JSONL Parsing & Markdown Formatting
// ============================================================================

/// Parsed session entry for checkpoint tracking
pub const SessionEntry = struct {
    uuid: []const u8,
    timestamp: []const u8,
    entry_type: []const u8, // "user", "assistant", "tool_result", etc.
    role: ?[]const u8, // "user" or "assistant" for message types
    content: ?[]const u8, // message content (may be truncated)
    tool_name: ?[]const u8, // for tool_use entries
};

/// Result of reading session entries
pub const SessionEntriesResult = struct {
    entries: []SessionEntry,
    last_uuid: ?[]const u8, // UUID of last entry (for checkpoint)
    session_path: []const u8,
};

/// Read session entries after a checkpoint UUID (or all if null)
/// Returns structured entries for markdown formatting
pub fn readSessionEntriesAfter(
    allocator: std.mem.Allocator,
    agent: Agent,
    cwd: []const u8,
    after_uuid: ?[]const u8,
) ?SessionEntriesResult {
    return switch (agent) {
        .claude => readClaudeEntriesAfter(allocator, cwd, after_uuid),
        // TODO: .opencode => readOpenCodeEntriesAfter(allocator, after_uuid),
        else => null,
    };
}

/// Resolve the main repository path (handles worktrees)
/// For worktrees, returns the main repo path instead of the worktree path
fn resolveMainRepoPath(allocator: std.mem.Allocator, cwd: []const u8) ?[]const u8 {
    // Check if .git is a file (worktree) or directory (main repo)
    const git_path = std.fmt.allocPrint(allocator, "{s}/.git", .{cwd}) catch return null;
    defer allocator.free(git_path);

    const stat = std.fs.cwd().statFile(git_path) catch {
        // No .git found, return cwd as-is
        return allocator.dupe(u8, cwd) catch null;
    };

    if (stat.kind == .file) {
        // Worktree: .git is a file containing "gitdir: /path/to/.git/worktrees/name"
        const git_file = std.fs.cwd().openFile(git_path, .{}) catch return null;
        defer git_file.close();

        var buf: [1024]u8 = undefined;
        const bytes_read = git_file.readAll(&buf) catch return null;
        const content = std.mem.trim(u8, buf[0..bytes_read], " \t\r\n");

        // Parse "gitdir: /path/to/.git/worktrees/name"
        if (std.mem.startsWith(u8, content, "gitdir: ")) {
            const gitdir = content[8..];
            // Find the main .git directory (remove /worktrees/name suffix)
            if (std.mem.indexOf(u8, gitdir, "/worktrees/")) |idx| {
                const main_git_dir = gitdir[0..idx];
                // Remove /.git suffix to get main repo path
                if (std.mem.endsWith(u8, main_git_dir, "/.git")) {
                    return allocator.dupe(u8, main_git_dir[0 .. main_git_dir.len - 5]) catch null;
                }
            }
        }
    }

    // Regular repo or couldn't parse worktree, return cwd
    return allocator.dupe(u8, cwd) catch null;
}

/// Read Claude Code session entries after a checkpoint
fn readClaudeEntriesAfter(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    after_uuid: ?[]const u8,
) ?SessionEntriesResult {
    const home = std.posix.getenv("HOME") orelse return null;

    // Resolve to main repo path (handles worktrees)
    const project_path = resolveMainRepoPath(allocator, cwd) orelse return null;
    defer allocator.free(project_path);

    // Convert to project hash
    var project_hash_buf: [512]u8 = undefined;
    var hash_len: usize = 0;
    for (project_path) |char| {
        if (hash_len >= project_hash_buf.len) break;
        project_hash_buf[hash_len] = if (char == '/') '-' else char;
        hash_len += 1;
    }
    const project_hash = project_hash_buf[0..hash_len];

    // Build project directory path
    const project_dir = std.fmt.allocPrint(allocator, "{s}/.claude/projects/{s}", .{ home, project_hash }) catch return null;
    defer allocator.free(project_dir);

    // Find most recent .jsonl file
    var dir = std.fs.cwd().openDir(project_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var most_recent_path: ?[]const u8 = null;
    var most_recent_mtime: i128 = 0;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const stat = dir.statFile(entry.name) catch continue;
        const mtime = stat.mtime;

        if (most_recent_path == null or mtime > most_recent_mtime) {
            if (most_recent_path) |old| allocator.free(old);
            most_recent_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, entry.name }) catch continue;
            most_recent_mtime = mtime;
        }
    }

    const session_path = most_recent_path orelse return null;

    // Read file content
    const file = std.fs.cwd().openFile(session_path, .{}) catch {
        allocator.free(session_path);
        return null;
    };
    defer file.close();

    // Use a large limit - session files can grow to hundreds of MB
    const content = file.readToEndAlloc(allocator, 500 * 1024 * 1024) catch {
        allocator.free(session_path);
        return null;
    };
    defer allocator.free(content);

    // Parse JSONL lines into entries
    var entries = std.array_list.AlignedManaged(SessionEntry, null).init(allocator);
    var found_checkpoint = after_uuid == null; // If no checkpoint, include all
    var last_uuid: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const entry = parseJsonlEntry(allocator, trimmed) catch continue;

        // Check if we've passed the checkpoint
        if (!found_checkpoint) {
            if (after_uuid) |checkpoint| {
                if (std.mem.eql(u8, entry.uuid, checkpoint)) {
                    found_checkpoint = true;
                }
            }
            // Free entry since we're skipping it
            allocator.free(entry.uuid);
            allocator.free(entry.timestamp);
            allocator.free(entry.entry_type);
            if (entry.role) |r| allocator.free(r);
            if (entry.content) |c| allocator.free(c);
            if (entry.tool_name) |t| allocator.free(t);
            continue;
        }

        // Skip internal entry types
        if (std.mem.eql(u8, entry.entry_type, "summary") or
            std.mem.eql(u8, entry.entry_type, "queue-operation"))
        {
            allocator.free(entry.uuid);
            allocator.free(entry.timestamp);
            allocator.free(entry.entry_type);
            if (entry.role) |r| allocator.free(r);
            if (entry.content) |c| allocator.free(c);
            if (entry.tool_name) |t| allocator.free(t);
            continue;
        }

        // Track last UUID for checkpoint
        if (last_uuid) |old| allocator.free(old);
        last_uuid = allocator.dupe(u8, entry.uuid) catch null;

        entries.append(entry) catch continue;
    }

    if (entries.items.len == 0) {
        entries.deinit();
        if (last_uuid) |u| allocator.free(u);
        allocator.free(session_path);
        return null;
    }

    return SessionEntriesResult{
        .entries = entries.toOwnedSlice() catch {
            entries.deinit();
            if (last_uuid) |u| allocator.free(u);
            allocator.free(session_path);
            return null;
        },
        .last_uuid = last_uuid,
        .session_path = session_path,
    };
}

/// Parse a single JSONL line into a SessionEntry
/// Uses std.json.Value for flexible content parsing (content can be string or array)
fn parseJsonlEntry(allocator: std.mem.Allocator, line: []const u8) !SessionEntry {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.ParseError;

    const obj = root.object;

    // Extract uuid (required)
    const uuid_val = obj.get("uuid") orelse return error.MissingUuid;
    const uuid = switch (uuid_val) {
        .string => |s| s,
        else => return error.MissingUuid,
    };

    // Extract timestamp (required)
    const timestamp_val = obj.get("timestamp") orelse return error.MissingTimestamp;
    const timestamp = switch (timestamp_val) {
        .string => |s| s,
        else => return error.MissingTimestamp,
    };

    // Extract type
    const entry_type_val = obj.get("type");
    const entry_type = if (entry_type_val) |v| switch (v) {
        .string => |s| s,
        else => "unknown",
    } else "unknown";

    // Extract content from message
    var content_text: ?[]const u8 = null;
    var role: ?[]const u8 = null;
    var tool_name: ?[]const u8 = null;

    if (obj.get("message")) |msg_val| {
        if (msg_val == .object) {
            const msg = msg_val.object;

            // Get role
            if (msg.get("role")) |role_val| {
                if (role_val == .string) {
                    role = try allocator.dupe(u8, role_val.string);
                }
            }

            // Get content (can be string or array)
            if (msg.get("content")) |content_val| {
                switch (content_val) {
                    .string => |s| {
                        // User messages typically have string content
                        const max_len: usize = 2000;
                        if (s.len > max_len) {
                            content_text = try allocator.dupe(u8, s[0..max_len]);
                        } else {
                            content_text = try allocator.dupe(u8, s);
                        }
                    },
                    .array => |blocks| {
                        // Assistant messages have array of content blocks
                        for (blocks.items) |block_val| {
                            if (block_val != .object) continue;
                            const block = block_val.object;

                            // Get block type
                            const block_type_val = block.get("type") orelse continue;
                            if (block_type_val != .string) continue;
                            const block_type = block_type_val.string;

                            if (std.mem.eql(u8, block_type, "text")) {
                                // Extract text content
                                if (block.get("text")) |text_val| {
                                    if (text_val == .string) {
                                        const text = text_val.string;
                                        const max_len: usize = 2000;
                                        if (text.len > max_len) {
                                            content_text = try allocator.dupe(u8, text[0..max_len]);
                                        } else {
                                            content_text = try allocator.dupe(u8, text);
                                        }
                                        break;
                                    }
                                }
                            } else if (std.mem.eql(u8, block_type, "tool_use")) {
                                // Extract tool name
                                if (block.get("name")) |name_val| {
                                    if (name_val == .string) {
                                        tool_name = try allocator.dupe(u8, name_val.string);
                                    }
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    return SessionEntry{
        .uuid = try allocator.dupe(u8, uuid),
        .timestamp = try allocator.dupe(u8, timestamp),
        .entry_type = try allocator.dupe(u8, entry_type),
        .role = role,
        .content = content_text,
        .tool_name = tool_name,
    };
}

/// Format session entries as GitHub-flavored markdown
pub fn formatSessionMarkdown(
    allocator: std.mem.Allocator,
    entries: []const SessionEntry,
) ![]const u8 {
    if (entries.len == 0) {
        return try allocator.dupe(u8, "_No new session activity_");
    }

    var result = std.array_list.AlignedManaged(u8, null).init(allocator);
    errdefer result.deinit();

    // Get time range from first and last entries
    const first_time = formatTimestamp(entries[0].timestamp);
    const last_time = formatTimestamp(entries[entries.len - 1].timestamp);

    // Count message types for summary
    var user_count: usize = 0;
    var assistant_count: usize = 0;
    var tool_count: usize = 0;
    for (entries) |entry| {
        if (entry.role) |role| {
            if (std.mem.eql(u8, role, "user")) {
                user_count += 1;
            } else if (std.mem.eql(u8, role, "assistant")) {
                assistant_count += 1;
            }
        }
        if (entry.tool_name != null) {
            tool_count += 1;
        }
    }

    // Write header
    try result.appendSlice("<details>\n<summary>Session (");
    var count_buf: [32]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d} user, {d} assistant", .{ user_count, assistant_count }) catch "messages";
    try result.appendSlice(count_str);
    if (tool_count > 0) {
        const tool_str = std.fmt.bufPrint(&count_buf, ", {d} tools", .{tool_count}) catch "";
        try result.appendSlice(tool_str);
    }
    try result.appendSlice(" | ");
    try result.appendSlice(&first_time);
    try result.appendSlice(" - ");
    try result.appendSlice(&last_time);
    try result.appendSlice(")</summary>\n\n");

    // Write each entry
    var current_tools = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer current_tools.deinit();

    for (entries) |entry| {
        // Collect tool names for assistant messages
        if (entry.tool_name) |tool| {
            current_tools.append(tool) catch {};
            continue;
        }

        if (entry.role) |role| {
            const time_str = formatTimestamp(entry.timestamp);

            if (std.mem.eql(u8, role, "user")) {
                // Flush any pending tools before user message
                if (current_tools.items.len > 0) {
                    try result.appendSlice("**Tools:** ");
                    for (current_tools.items, 0..) |tool, i| {
                        if (i > 0) try result.appendSlice(", ");
                        try result.appendSlice(tool);
                    }
                    try result.appendSlice("\n\n");
                    current_tools.clearRetainingCapacity();
                }

                try result.appendSlice("### User _");
                try result.appendSlice(&time_str);
                try result.appendSlice("_\n");
                if (entry.content) |content| {
                    try result.appendSlice(content);
                    if (content.len == 2000) {
                        try result.appendSlice("...");
                    }
                }
                try result.appendSlice("\n\n");
            } else if (std.mem.eql(u8, role, "assistant")) {
                try result.appendSlice("### Assistant _");
                try result.appendSlice(&time_str);
                try result.appendSlice("_\n");
                if (entry.content) |content| {
                    try result.appendSlice(content);
                    if (content.len == 2000) {
                        try result.appendSlice("...");
                    }
                }
                try result.appendSlice("\n\n");
            }
        }
    }

    // Flush any remaining tools
    if (current_tools.items.len > 0) {
        try result.appendSlice("**Tools:** ");
        for (current_tools.items, 0..) |tool, i| {
            if (i > 0) try result.appendSlice(", ");
            try result.appendSlice(tool);
        }
        try result.appendSlice("\n\n");
    }

    try result.appendSlice("</details>");

    return result.toOwnedSlice();
}

/// Format ISO timestamp to short time string (HH:MM)
fn formatTimestamp(timestamp: []const u8) [5]u8 {
    // ISO format: 2026-01-09T13:18:32.503Z
    // Extract HH:MM starting at position 11
    var result: [5]u8 = "??:??".*;
    if (timestamp.len >= 16) {
        result[0] = timestamp[11];
        result[1] = timestamp[12];
        result[2] = ':';
        result[3] = timestamp[14];
        result[4] = timestamp[15];
    }
    return result;
}

// Tests
test "isAgentMode returns false when no env vars set" {
    // Note: This test assumes env vars are not set in test environment
    // In practice, we can't easily unset env vars in Zig tests
    const result = isAgentMode();
    _ = result; // Just verify it compiles and runs
}

test "detectAgent returns based on env vars" {
    const agent = detectAgent();
    // Without mocking, this will return based on actual env
    _ = agent.name();
}
