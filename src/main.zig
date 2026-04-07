const std = @import("std");
const build_options = @import("build_options");
const passthrough = @import("passthrough.zig");
const log = @import("cmds/log.zig");
const status = @import("cmds/status.zig");
const add = @import("cmds/add.zig");
const alias = @import("cmds/alias.zig");
const commit = @import("cmds/commit.zig");
const diff = @import("cmds/diff.zig");
const fork = @import("cmds/fork.zig");
const tasks = @import("cmds/tasks.zig");
const override = @import("cmds/override.zig");
const git = @import("cmds/git.zig");

const version = build_options.version;

const Command = enum {
    log_cmd,
    status_cmd,
    add_cmd,
    alias_cmd,
    commit_cmd,
    diff_cmd,
    fork_cmd,
    tasks_cmd,
    other,
};

var current_command: Command = .other;

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = std.process.argsAlloc(allocator) catch {
        std.process.exit(1);
    };
    defer std.process.argsFree(allocator, args);

    run(allocator, args) catch |err| {
        // UnsupportedFlag: pass through to git
        if (err == git.Error.UnsupportedFlag) {
            passthrough.run(allocator, args) catch {};
            return;
        }
        handleError(err, current_command);
    };
}

fn run(allocator: std.mem.Allocator, args: [][:0]u8) !void {

    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (args.len < 2) {
        printHelp(stdout) catch {};
        return;
    }

    const cmd = args[1];

    // Handle global flags
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        printHelp(stdout) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        stdout.print("zagi {s}\n", .{version}) catch {};
        return;
    }

    // Detect global output format flags (--compat, --json)
    // Both flags are stripped from args. --compat triggers passthrough.
    // --json sets format for format-aware commands; for others (tasks), it's re-added.
    var format = git.OutputFormat.succinct;
    var filtered_args = std.array_list.Managed([:0]u8).init(allocator);
    defer filtered_args.deinit();

    for (args) |arg| {
        const a = std.mem.sliceTo(arg, 0);
        if (std.mem.eql(u8, a, "--compat")) {
            format = .compat;
        } else if (std.mem.eql(u8, a, "--json")) {
            format = .json;
        } else {
            try filtered_args.append(arg);
        }
    }

    var fargs = filtered_args.items;

    // --compat mode: passthrough to git for all commands
    if (format == .compat) {
        try passthrough.run(allocator, fargs);
        return;
    }

    if (fargs.len < 2) {
        printHelp(stdout) catch {};
        return;
    }

    const subcmd = std.mem.sliceTo(fargs[1], 0);

    // For commands that handle --json themselves (tasks), re-add the flag to args
    var args_with_json = std.array_list.Managed([:0]u8).init(allocator);
    defer args_with_json.deinit();

    if (format == .json) {
        const handles_own_json = std.mem.eql(u8, subcmd, "tasks");
        if (handles_own_json) {
            for (fargs) |arg| {
                try args_with_json.append(arg);
            }
            // Find the position after the subcommand to insert --json
            // Just append it at the end
            const json_flag = @as([:0]u8, @constCast("--json"));
            try args_with_json.append(json_flag);
            fargs = args_with_json.items;
        }
    }

    // Zagi commands
    if (std.mem.eql(u8, subcmd, "log")) {
        current_command = .log_cmd;
        try log.run(allocator, fargs, format);
    } else if (std.mem.eql(u8, subcmd, "status")) {
        current_command = .status_cmd;
        try status.run(allocator, fargs, format);
    } else if (std.mem.eql(u8, subcmd, "add")) {
        current_command = .add_cmd;
        try add.run(allocator, fargs, format);
    } else if (std.mem.eql(u8, subcmd, "alias")) {
        current_command = .alias_cmd;
        try alias.run(allocator, fargs);
    } else if (std.mem.eql(u8, subcmd, "commit")) {
        current_command = .commit_cmd;
        try commit.run(allocator, fargs, format);
    } else if (std.mem.eql(u8, subcmd, "diff")) {
        current_command = .diff_cmd;
        try diff.run(allocator, fargs, format);
    } else if (std.mem.eql(u8, subcmd, "fork")) {
        current_command = .fork_cmd;
        try fork.run(allocator, fargs);
    } else if (std.mem.eql(u8, subcmd, "tasks")) {
        current_command = .tasks_cmd;
        try tasks.run(allocator, fargs);
    } else if (std.mem.eql(u8, subcmd, "set-override")) {
        try override.run(fargs);
    } else {
        // Unknown command: pass through to git
        current_command = .other;
        try passthrough.run(allocator, fargs);
    }
}

fn printHelp(stdout: anytype) !void {
    try stdout.print(
        \\zagi - git for agents
        \\
        \\usage: zagi <command> [args...]
        \\usage: git <command> [args...] (when aliased)
        \\
        \\commands:
        \\  status    Show working tree status
        \\  log       Show commit history
        \\  diff      Show changes
        \\  add       Stage files for commit
        \\  commit    Create a commit
        \\  fork      Manage parallel worktrees
        \\  tasks     Task management for git repositories
        \\  alias     Create an alias to git
        \\  set-override  Set guardrails bypass secret
        \\
        \\options:
        \\  -h, --help     Show this help
        \\  -v, --version  Show version
        \\  --compat       Output identical to git CLI
        \\  --json         Output in JSON format
        \\
        \\Unrecognized commands are passed through to git.
        \\
        \\
    , .{});
}

fn handleError(err: anyerror, cmd: Command) void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const exit_code: u8 = switch (err) {
        git.Error.NotARepository => blk: {
            stderr.print("fatal: not a git repository\n", .{}) catch {};
            break :blk 128;
        },
        git.Error.InitFailed => blk: {
            stderr.print("fatal: failed to initialize libgit2\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.IndexOpenFailed => blk: {
            stderr.print("fatal: failed to open index\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.IndexWriteFailed => blk: {
            stderr.print("fatal: failed to write index\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.StatusFailed => blk: {
            stderr.print("fatal: failed to get status\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.FileNotFound => blk: {
            stderr.print("error: file not found\n", .{}) catch {};
            break :blk 128;
        },
        git.Error.AddFailed => blk: {
            stderr.print("error: failed to add files\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.RevwalkFailed => blk: {
            stderr.print("fatal: failed to walk commits\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.UsageError => blk: {
            printUsageHelp(stderr, cmd);
            break :blk 1;
        },
        git.Error.WriteFailed => blk: {
            stderr.print("fatal: write failed\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.NothingToCommit => blk: {
            stderr.print("error: nothing to commit\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.CommitFailed => blk: {
            stderr.print("error: commit failed\n", .{}) catch {};
            break :blk 1;
        },
        error.OutOfMemory => blk: {
            stderr.print("fatal: out of memory\n", .{}) catch {};
            break :blk 1;
        },
        else => blk: {
            stderr.print("error: {}\n", .{err}) catch {};
            break :blk 1;
        },
    };

    std.process.exit(exit_code);
}

fn printUsageHelp(stderr: anytype, cmd: Command) void {
    const help_text = switch (cmd) {
        .add_cmd => add.help,
        .commit_cmd => commit.help,
        .status_cmd => status.help,
        .log_cmd => log.help,
        .alias_cmd => alias.help,
        .diff_cmd => diff.help,
        .fork_cmd => fork.help,
        .tasks_cmd => tasks.help,
        .other => "usage: git <command> [args...]\n",
    };

    stderr.print("{s}", .{help_text}) catch {};
}
