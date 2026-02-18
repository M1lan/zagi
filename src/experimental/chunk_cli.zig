// Standalone CLI wrapper for the chunk command (for testing without full zagi build).
// Usage: zig build-exe src/chunk_cli.zig && ./chunk_cli <dir> [--verify] [--clean] [--dry-run]
const std = @import("std");
const chunk = @import("chunk.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Skip the binary name (args[0]) and pass the rest
    const cmd_args: []const [:0]const u8 = @ptrCast(if (args.len > 1) args[1..] else args[0..0]);
    try chunk.run(allocator, cmd_args);
}
