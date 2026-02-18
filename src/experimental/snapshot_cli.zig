// Standalone CLI for snapshot/restore testing.
const std = @import("std");
const snapshot = @import("snapshot.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("usage: snapshot_cli <snapshot|restore> [args...]\n", .{});
        return;
    }

    const cmd = std.mem.sliceTo(args[1], 0);
    const cmd_args: []const [:0]const u8 = @ptrCast(if (args.len > 2) args[2..] else args[0..0]);

    if (std.mem.eql(u8, cmd, "snapshot")) {
        try snapshot.runSnapshot(allocator, cmd_args);
    } else if (std.mem.eql(u8, cmd, "restore")) {
        try snapshot.runRestore(allocator, cmd_args);
    } else {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("unknown command: {s}\n", .{cmd});
    }
}
