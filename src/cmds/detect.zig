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

    // Convert cwd to project hash (replace / with -)
    // e.g., /Users/matt/Documents/Github/zagi -> -Users-matt-Documents-Github-zagi
    var project_hash_buf: [512]u8 = undefined;
    var hash_len: usize = 0;
    for (cwd) |char| {
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
