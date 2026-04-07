const std = @import("std");
const git = @import("git.zig");

pub const help =
    \\usage: git set-override <secret>
    \\
    \\Set a secret passphrase that can bypass guardrails.
    \\
    \\When ZAGI_GUARDRAILS=1 is set, destructive commands are blocked.
    \\To bypass, set ZAGI_OVERRIDE=<secret> in your environment.
    \\
    \\The secret is hashed before storage — agents cannot read it.
    \\
    \\Examples:
    \\  git set-override pineapples
    \\  ZAGI_OVERRIDE=pineapples git reset --hard HEAD~1
    \\
;

pub fn run(args: [][:0]u8) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (args.len < 3) {
        stderr.print("{s}", .{help}) catch {};
        return git.Error.UsageError;
    }

    const secret = std.mem.sliceTo(args[2], 0);
    if (secret.len == 0) {
        stderr.print("error: secret cannot be empty\n", .{}) catch {};
        return git.Error.UsageError;
    }

    const home = std.posix.getenv("HOME") orelse {
        stderr.print("error: HOME not set\n", .{}) catch {};
        return git.Error.WriteFailed;
    };

    // Create ~/.config/zagi/ directory
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.config/zagi", .{home}) catch return git.Error.WriteFailed;
    std.fs.cwd().makePath(dir_path) catch return git.Error.WriteFailed;

    // Hash the secret with SHA-256 and store the hex digest
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(secret, &hash, .{});

    var hex: [64]u8 = undefined;
    for (hash, 0..) |byte, i| {
        const digits = "0123456789abcdef";
        hex[i * 2] = digits[byte >> 4];
        hex[i * 2 + 1] = digits[byte & 0x0f];
    }

    // Write hash to ~/.config/zagi/override
    var path_buf: [512]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/.config/zagi/override", .{home}) catch return git.Error.WriteFailed;

    const file = std.fs.cwd().createFile(file_path, .{}) catch return git.Error.WriteFailed;
    defer file.close();
    file.writeAll(&hex) catch return git.Error.WriteFailed;

    stdout.print("override secret set\n", .{}) catch {};
    stdout.print("usage: ZAGI_OVERRIDE={s} git <destructive command>\n", .{secret}) catch {};
}
