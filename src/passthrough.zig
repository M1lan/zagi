const std = @import("std");
const guardrails = @import("guardrails.zig");

/// Pass through a command to git CLI
pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Check guardrails (opt-in via ZAGI_GUARDRAILS=1)
    if (std.posix.getenv("ZAGI_GUARDRAILS") != null) {
        // ZAGI_OVERRIDE bypasses guardrails if it matches the stored secret
        const override_active = blk: {
            const override_val = std.posix.getenv("ZAGI_OVERRIDE") orelse break :blk false;
            if (override_val.len == 0) break :blk false;
            const stored_hash = readOverrideHash(allocator) orelse break :blk false;
            defer allocator.free(stored_hash);
            // Hash the provided value and compare to stored hash
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(override_val, &hash, .{});
            var hex: [64]u8 = undefined;
            for (hash, 0..) |byte, i| {
                const digits = "0123456789abcdef";
                hex[i * 2] = digits[byte >> 4];
                hex[i * 2 + 1] = digits[byte & 0x0f];
            }
            break :blk std.mem.eql(u8, &hex, stored_hash);
        };

        if (!override_active) {
            const const_args: []const [:0]const u8 = @ptrCast(args);
            if (guardrails.checkBlocked(const_args)) |reason| {
                stderr.print("error: destructive command blocked (ZAGI_GUARDRAILS is enabled)\n", .{}) catch {};
                stderr.print("reason: {s}\n", .{reason}) catch {};
                stderr.print("hint: set ZAGI_OVERRIDE=<secret> to bypass (see: zagi set-override)\n", .{}) catch {};
                std.process.exit(1);
            }
        }
    }

    var git_args = std.array_list.Managed([]const u8).init(allocator);
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

/// Read the stored override hash from ~/.config/zagi/override
fn readOverrideHash(allocator: std.mem.Allocator) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    const path = std.fmt.allocPrint(allocator, "{s}/.config/zagi/override", .{home}) catch return null;
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    var buf: [256]u8 = undefined;
    const bytes_read = file.read(&buf) catch return null;
    if (bytes_read == 0) return null;

    const content = std.mem.trim(u8, buf[0..bytes_read], " \t\n\r");
    return allocator.dupe(u8, content) catch null;
}
