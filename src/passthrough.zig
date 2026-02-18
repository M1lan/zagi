const std = @import("std");
const guardrails = @import("guardrails.zig");
const detect = @import("cmds/detect.zig");

/// Pass through a command to git CLI
pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    const stderr = std.io.getStdErr().writer();

    // Check guardrails in agent mode
    if (detect.isAgentMode()) {
        // Cast to const for checkBlocked
        const const_args: []const [:0]const u8 = @ptrCast(args);
        if (guardrails.checkBlocked(const_args)) |reason| {
            stderr.print("error: destructive command blocked\n", .{}) catch {};
            stderr.print("reason: {s}\n", .{reason}) catch {};
            stderr.print("hint: ask the user to run this command themselves, then confirm with you when done\n", .{}) catch {};
            std.process.exit(1);
        }
    }

    var git_args = std.ArrayList([]const u8).init(allocator);
    defer git_args.deinit();

    try git_args.append("git");
    for (args[1..]) |arg| {
        try git_args.append(arg);
    }

    var child = std.process.Child.init(git_args.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        stderr.print("Error executing git: {s}\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };

    switch (term) {
        .Exited => |code| std.process.exit(code),
        .Signal => |sig| {
            stderr.print("Git terminated by signal {d}\n", .{sig}) catch {};
            std.process.exit(1);
        },
        .Stopped => |sig| {
            stderr.print("Git stopped by signal {d}\n", .{sig}) catch {};
            std.process.exit(1);
        },
        .Unknown => |code| {
            stderr.print("Git exited with unknown status {d}\n", .{code}) catch {};
            std.process.exit(1);
        },
    }
}
