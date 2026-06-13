const std = @import("std");
const git = @import("git.zig");
const c = git.c;

/// Outcome of attempting to run a git hook.
pub const HookResult = enum {
    /// Hook ran and exited 0 (approved).
    ok,
    /// Hook file is absent or not executable; nothing ran.
    skipped,
    /// Hook ran and exited non-zero, or died on a signal (rejected).
    rejected,
};

/// Returns true when hook execution should be skipped entirely.
///
/// Mirrors git's `--no-verify`: the explicit flag wins, and the
/// `ZAGI_NO_VERIFY` environment variable provides a global escape hatch
/// (useful for agents and scripted flows that must never block).
pub fn skip(no_verify: bool) bool {
    if (no_verify) return true;
    if (std.posix.getenv("ZAGI_NO_VERIFY") != null) return true;
    return false;
}

/// Trims trailing whitespace and newlines from a hook-rewritten message,
/// matching git's lightweight cleanup of a hook-modified COMMIT_EDITMSG.
pub fn cleanupMessage(raw: []const u8) []const u8 {
    var end = raw.len;
    while (end > 0) {
        const ch = raw[end - 1];
        if (ch != '\n' and ch != '\r' and ch != ' ' and ch != '\t') break;
        end -= 1;
    }
    return raw[0..end];
}

/// Resolves the directory that holds hook scripts for `repo`.
///
/// Precedence matches git: `core.hooksPath` (absolute, or relative to the
/// work tree) when set, otherwise `<gitdir>/hooks`. The returned slice is
/// owned by `allocator` and must be freed by the caller.
pub fn resolveHooksDir(allocator: std.mem.Allocator, repo: ?*c.git_repository) ?[]u8 {
    var cfg: ?*c.git_config = null;
    if (c.git_repository_config(&cfg, repo) == 0) {
        defer c.git_config_free(cfg);
        var buf: c.git_buf = std.mem.zeroes(c.git_buf);
        if (c.git_config_get_string_buf(&buf, cfg, "core.hooksPath") == 0) {
            defer c.git_buf_dispose(&buf);
            if (buf.ptr != null) {
                const val = std.mem.sliceTo(buf.ptr, 0);
                if (val.len > 0) {
                    if (std.fs.path.isAbsolute(val)) {
                        return allocator.dupe(u8, val) catch null;
                    }
                    const workdir = c.git_repository_workdir(repo);
                    if (workdir != null) {
                        const wd = std.mem.sliceTo(workdir, 0);
                        return std.fs.path.join(allocator, &.{ wd, val }) catch null;
                    }
                    return allocator.dupe(u8, val) catch null;
                }
            }
        }
    }

    const gitdir = c.git_repository_path(repo);
    if (gitdir == null) return null;
    const gd = std.mem.sliceTo(gitdir, 0);
    return std.fs.path.join(allocator, &.{ gd, "hooks" }) catch null;
}

/// Runs the named git hook (e.g. "pre-commit", "commit-msg", "post-commit")
/// from the repository's hooks directory.
///
/// `extra_args` are appended after the hook path (commit-msg receives the
/// path to the message file). The hook inherits stdio and runs with the
/// work-tree root as its working directory so that standard hook frameworks
/// (pre-commit, prek, husky) discover the repository normally.
///
/// Returns `.skipped` when the hook is missing or not executable, `.ok` on
/// a zero exit, and `.rejected` otherwise.
pub fn runHook(
    allocator: std.mem.Allocator,
    repo: ?*c.git_repository,
    name: []const u8,
    extra_args: []const []const u8,
) HookResult {
    const hooks_dir = resolveHooksDir(allocator, repo) orelse return .skipped;
    defer allocator.free(hooks_dir);

    const hook_path = std.fs.path.join(allocator, &.{ hooks_dir, name }) catch return .skipped;
    defer allocator.free(hook_path);

    // Skip silently when the hook is absent or not executable (git semantics).
    std.posix.access(hook_path, std.posix.X_OK) catch return .skipped;

    var argv_buf: [4][]const u8 = undefined;
    if (extra_args.len > argv_buf.len - 1) return .skipped;
    argv_buf[0] = hook_path;
    var n: usize = 1;
    for (extra_args) |a| {
        argv_buf[n] = a;
        n += 1;
    }

    var child = std.process.Child.init(argv_buf[0..n], allocator);
    const workdir = c.git_repository_workdir(repo);
    if (workdir != null) child.cwd = std.mem.sliceTo(workdir, 0);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch return .skipped;
    return switch (term) {
        .Exited => |code| if (code == 0) .ok else .rejected,
        else => .rejected,
    };
}

const testing = std.testing;

test "skip respects the explicit no_verify flag" {
    try testing.expect(skip(true));
}

test "cleanupMessage trims trailing newlines and spaces" {
    try testing.expectEqualStrings("fix: thing", cleanupMessage("fix: thing\n\n"));
    try testing.expectEqualStrings("fix: thing", cleanupMessage("fix: thing   \t"));
    try testing.expectEqualStrings("fix: thing", cleanupMessage("fix: thing\r\n"));
}

test "cleanupMessage preserves interior whitespace" {
    try testing.expectEqualStrings("line one\n\nline two", cleanupMessage("line one\n\nline two\n"));
}

test "cleanupMessage handles all-whitespace input" {
    try testing.expectEqualStrings("", cleanupMessage("\n\n  \t"));
}
