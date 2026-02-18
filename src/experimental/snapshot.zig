const std = @import("std");
const chunk = @import("chunk.zig");

// ============================================================
// Snapshot & Restore
//
// Phase 2 of the next-gen VCS: persist manifests, restore from
// store, hardlink cache for disk efficiency.
//
// snapshot: chunk dir -> write manifest -> store chunks
// restore:  read manifest -> assemble from chunks -> hardlink
// ============================================================

const Hash = chunk.Hash;

// --- Manifest Format ---
//
// Binary format for speed and compactness:
//   Header: "ZSNAP\x01" (6 bytes, version 1)
//   u32le: file_count
//   For each file:
//     u16le: path_len
//     [path_len]u8: path (utf-8, forward slashes)
//     u64le: file_size
//     u32le: mode (unix permissions)
//     u16le: chunk_count
//     For each chunk:
//       [32]u8: blake3 hash
//       u32le: chunk_len

const MANIFEST_MAGIC = "ZSNAP\x01";

pub const ManifestEntry = struct {
    path: []const u8,
    size: u64,
    mode: u32,
    chunks: []const ManifestChunk,
};

pub const ManifestChunk = struct {
    hash: Hash,
    len: u32,
};

pub const Manifest = struct {
    entries: []const ManifestEntry,

    pub fn write(self: Manifest, file: std.fs.File) !void {
        const w = file.writer();

        // Header
        try w.writeAll(MANIFEST_MAGIC);

        // File count
        const count: u32 = @intCast(self.entries.len);
        try w.writeInt(u32, count, .little);

        for (self.entries) |entry| {
            // Path
            const path_len: u16 = @intCast(entry.path.len);
            try w.writeInt(u16, path_len, .little);
            try w.writeAll(entry.path);

            // Size + mode
            try w.writeInt(u64, entry.size, .little);
            try w.writeInt(u32, entry.mode, .little);

            // Chunks
            const chunk_count: u16 = @intCast(entry.chunks.len);
            try w.writeInt(u16, chunk_count, .little);

            for (entry.chunks) |c| {
                try w.writeAll(&c.hash);
                try w.writeInt(u32, c.len, .little);
            }
        }
    }

    pub fn read(allocator: std.mem.Allocator, file: std.fs.File) !Manifest {
        const r = file.reader();

        // Verify magic
        var magic: [6]u8 = undefined;
        try r.readNoEof(&magic);
        if (!std.mem.eql(u8, &magic, MANIFEST_MAGIC)) {
            return error.InvalidManifest;
        }

        const file_count = try r.readInt(u32, .little);

        const entries = try allocator.alloc(ManifestEntry, file_count);
        errdefer allocator.free(entries);

        for (entries, 0..) |*entry, i| {
            _ = i;
            // Path
            const path_len = try r.readInt(u16, .little);
            const path = try allocator.alloc(u8, path_len);
            try r.readNoEof(path);
            entry.path = path;

            // Size + mode
            entry.size = try r.readInt(u64, .little);
            entry.mode = try r.readInt(u32, .little);

            // Chunks
            const chunk_count = try r.readInt(u16, .little);
            const chunks = try allocator.alloc(ManifestChunk, chunk_count);

            for (chunks) |*c| {
                try r.readNoEof(&c.hash);
                c.len = try r.readInt(u32, .little);
            }
            entry.chunks = chunks;
        }

        return .{ .entries = entries };
    }

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.chunks);
        }
        allocator.free(self.entries);
    }
};

// --- Snapshot ---

pub const snapshot_help =
    \\usage: zagi -e snapshot [directory] [options]
    \\
    \\Snapshot a directory: chunk all files, store chunks,
    \\write a manifest. Defaults to current directory.
    \\
    \\options:
    \\  --name <n>  Name the snapshot (default: timestamp)
    \\
;

pub const restore_help =
    \\usage: zagi -e restore <manifest> [directory]
    \\
    \\Restore files from a snapshot manifest.
    \\Hardlinks files from the chunk store when possible.
    \\
    \\Defaults to restoring into current directory.
    \\
;

const STORE_PATH = ".zagi/store";
const SNAPSHOT_DIR = ".zagi/snapshots";

pub fn runSnapshot(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var dir_path: []const u8 = ".";
    var name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = std.mem.sliceTo(args[i], 0);
        if (std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i < args.len) {
                name = std.mem.sliceTo(args[i], 0);
            }
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try stdout.print("{s}", .{snapshot_help});
            return;
        } else if (!std.mem.startsWith(u8, a, "-")) {
            dir_path = a;
        }
    }

    // Ensure store and snapshot directories exist
    const cwd = std.fs.cwd();
    cwd.makePath(STORE_PATH) catch {};
    cwd.makePath(SNAPSHOT_DIR) catch {};

    var store_dir = cwd.openDir(STORE_PATH, .{}) catch {
        try stderr.print("error: cannot open store at {s}\n", .{STORE_PATH});
        std.process.exit(1);
    };
    defer store_dir.close();

    try stdout.print("snapshotting {s}...\n\n", .{dir_path});

    // Walk directory and chunk all files
    var dir = cwd.openDir(dir_path, .{ .iterate = true }) catch {
        try stderr.print("error: cannot open directory '{s}'\n", .{dir_path});
        std.process.exit(1);
    };
    defer dir.close();

    var entries = std.ArrayList(ManifestEntry).init(allocator);
    defer {
        for (entries.items) |e| {
            allocator.free(e.path);
            allocator.free(e.chunks);
        }
        entries.deinit();
    }

    var total_files: usize = 0;
    var total_bytes: u64 = 0;
    var total_chunks: usize = 0;
    var new_chunks: usize = 0;
    var stored_bytes: u64 = 0;

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        // Skip .zagi directory
        if (std.mem.startsWith(u8, entry.path, ".zagi/") or
            std.mem.startsWith(u8, entry.path, ".zagi\\"))
            continue;

        const file = dir.openFile(entry.path, .{}) catch continue;
        defer file.close();

        const stat = file.stat() catch continue;
        if (stat.size > chunk.MAX_FILE_SIZE) continue;

        const data = file.readToEndAlloc(allocator, chunk.MAX_FILE_SIZE) catch continue;
        defer allocator.free(data);

        if (data.len == 0) continue;

        // Chunk the file
        const chunk_refs = try chunk.chunkData(allocator, data);

        // Convert to manifest chunks and store
        var manifest_chunks = try allocator.alloc(ManifestChunk, chunk_refs.len);
        for (chunk_refs, 0..) |cr, ci| {
            manifest_chunks[ci] = .{
                .hash = cr.hash,
                .len = @intCast(cr.len),
            };

            // Store chunk
            const chunk_data = data[cr.offset .. cr.offset + cr.len];
            const was_new = chunk.storeChunk(store_dir, cr.hash, chunk_data) catch false;
            if (was_new) {
                new_chunks += 1;
                stored_bytes += cr.len;
            }
            total_chunks += 1;
        }
        allocator.free(chunk_refs);

        const path_copy = try allocator.dupe(u8, entry.path);
        // Get file mode (unix permissions)
        const mode: u32 = @intCast(stat.mode & 0o7777);

        try entries.append(.{
            .path = path_copy,
            .size = stat.size,
            .mode = mode,
            .chunks = manifest_chunks,
        });

        total_files += 1;
        total_bytes += stat.size;
    }

    // Generate snapshot name
    var snap_name_buf: [64]u8 = undefined;
    const snap_name = if (name) |n| n else blk: {
        // Use a hash of the manifest content as the name
        var hasher = std.crypto.hash.Blake3.init(.{});
        for (entries.items) |e| {
            hasher.update(e.path);
            for (e.chunks) |c| {
                hasher.update(&c.hash);
            }
        }
        var hash_out: [32]u8 = undefined;
        hasher.final(&hash_out);
        const hex = chunk.hashToHex(hash_out);
        @memcpy(snap_name_buf[0..12], hex[0..12]);
        break :blk snap_name_buf[0..12];
    };

    // Write manifest
    const manifest = Manifest{ .entries = entries.items };

    var manifest_path_buf: [256]u8 = undefined;
    const manifest_path = std.fmt.bufPrint(&manifest_path_buf, "{s}/{s}.manifest", .{ SNAPSHOT_DIR, snap_name }) catch {
        try stderr.print("error: snapshot name too long\n", .{});
        std.process.exit(1);
    };

    const manifest_file = cwd.createFile(manifest_path, .{}) catch {
        try stderr.print("error: cannot create manifest at {s}\n", .{manifest_path});
        std.process.exit(1);
    };
    defer manifest_file.close();

    try manifest.write(manifest_file);

    // Print stats
    const logical = chunk.formatBytes(total_bytes);
    const stored_fmt = chunk.formatBytes(stored_bytes);
    try stdout.print("  manifest: {s}\n", .{manifest_path});
    try stdout.print("  files:    {d}\n", .{total_files});
    try stdout.print("  size:     {d:.1} {s}\n", .{ logical.val, logical.unit });
    try stdout.print("  chunks:   {d} ({d} new)\n", .{ total_chunks, new_chunks });
    try stdout.print("  stored:   {d:.1} {s}\n", .{ stored_fmt.val, stored_fmt.unit });
}

// --- Restore ---

pub fn runRestore(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var manifest_path: ?[]const u8 = null;
    var target_dir: []const u8 = ".";

    var positional: u8 = 0;
    for (args) |arg| {
        const a = std.mem.sliceTo(arg, 0);
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try stdout.print("{s}", .{restore_help});
            return;
        } else if (!std.mem.startsWith(u8, a, "-")) {
            if (positional == 0) {
                manifest_path = a;
            } else if (positional == 1) {
                target_dir = a;
            }
            positional += 1;
        }
    }

    if (manifest_path == null) {
        try stderr.print("error: no manifest specified\n\n{s}", .{restore_help});
        std.process.exit(1);
    }

    const cwd = std.fs.cwd();

    // Open store
    var store_dir = cwd.openDir(STORE_PATH, .{}) catch {
        try stderr.print("error: chunk store not found at {s}\n", .{STORE_PATH});
        std.process.exit(1);
    };
    defer store_dir.close();

    // Read manifest
    const manifest_file = cwd.openFile(manifest_path.?, .{}) catch {
        try stderr.print("error: cannot open manifest '{s}'\n", .{manifest_path.?});
        std.process.exit(1);
    };
    defer manifest_file.close();

    var manifest = Manifest.read(allocator, manifest_file) catch {
        try stderr.print("error: invalid manifest format\n", .{});
        std.process.exit(1);
    };
    defer manifest.deinit(allocator);

    try stdout.print("restoring to {s}...\n\n", .{target_dir});

    // Ensure we have a flat extracted-file cache directory in the store.
    // For each chunk, we store the chunk data. For hardlinking, we need
    // assembled files. We'll assemble into a cache dir and hardlink from there.
    const cache_path = STORE_PATH ++ "/cache";
    cwd.makePath(cache_path) catch {};

    var cache_dir = cwd.openDir(cache_path, .{}) catch {
        try stderr.print("error: cannot open cache directory\n", .{});
        std.process.exit(1);
    };
    defer cache_dir.close();

    // Ensure target directory exists
    cwd.makePath(target_dir) catch {};
    var target = cwd.openDir(target_dir, .{}) catch {
        try stderr.print("error: cannot open target directory '{s}'\n", .{target_dir});
        std.process.exit(1);
    };
    defer target.close();

    var restored: usize = 0;
    var hardlinked: usize = 0;
    var failed: usize = 0;

    for (manifest.entries) |entry| {
        // Compute a cache key for this file (hash of all chunk hashes)
        var file_hasher = std.crypto.hash.Blake3.init(.{});
        for (entry.chunks) |c| {
            file_hasher.update(&c.hash);
        }
        var file_key: Hash = undefined;
        file_hasher.final(&file_key);
        const cache_name = chunk.hashToHex(file_key);

        // Ensure parent directory exists
        if (std.fs.path.dirname(entry.path)) |parent| {
            target.makePath(parent) catch {};
        }

        // Try to hardlink from cache first
        const cache_exists = blk: {
            cache_dir.access(&cache_name, .{}) catch break :blk false;
            break :blk true;
        };

        if (cache_exists) {
            // Hardlink from cache -> target
            cache_dir.copyFile(&cache_name, target, entry.path, .{}) catch {
                // Fall back: try hardlink
                const hardlink_result = hardlinkFile(cache_dir, &cache_name, target, entry.path);
                if (!hardlink_result) {
                    failed += 1;
                    continue;
                }
                hardlinked += 1;
                restored += 1;
                continue;
            };
            restored += 1;
            continue;
        }

        // Assemble from chunks
        const file_data = assembleFromStore(allocator, entry.chunks, store_dir) catch {
            failed += 1;
            continue;
        };
        defer allocator.free(file_data);

        // Write to cache
        if (cache_dir.createFile(&cache_name, .{})) |cache_file| {
            cache_file.writeAll(file_data) catch {};
            cache_file.close();
        } else |_| {}

        // Write to target (try hardlink from cache first, fall back to write)
        const did_hardlink = hardlinkFile(cache_dir, &cache_name, target, entry.path);
        if (did_hardlink) {
            hardlinked += 1;
        } else {
            // Direct write
            if (target.createFile(entry.path, .{})) |out_file| {
                out_file.writeAll(file_data) catch {
                    failed += 1;
                    out_file.close();
                    continue;
                };
                out_file.close();
            } else |_| {
                failed += 1;
                continue;
            }
        }

        // Set permissions (preserve execute bits)
        if (entry.mode & 0o111 != 0) {
            const target_file = target.openFile(entry.path, .{ .mode = .read_write }) catch continue;
            defer target_file.close();
            target_file.chmod(entry.mode) catch {};
        }

        restored += 1;
    }

    try stdout.print("  restored:   {d} files\n", .{restored});
    if (hardlinked > 0) {
        try stdout.print("  hardlinked: {d}\n", .{hardlinked});
    }
    if (failed > 0) {
        try stdout.print("  failed:     {d}\n", .{failed});
    }
}

fn hardlinkFile(
    src_dir: std.fs.Dir,
    src_name: []const u8,
    dst_dir: std.fs.Dir,
    dst_name: []const u8,
) bool {
    // Delete existing target file first (hardlink fails if target exists)
    dst_dir.deleteFile(dst_name) catch {};
    // Use the OS-level hardlink through Zig's Dir API
    // src_dir.hardLink(src_name, dst_dir, dst_name) - not available in 0.14
    // Use std.posix.linkat instead
    const src_fd = src_dir.fd;
    const dst_fd = dst_dir.fd;
    const result = std.posix.linkat(src_fd, src_name, dst_fd, dst_name, 0);
    if (result) |_| {
        return true;
    } else |_| {
        return false;
    }
}

fn assembleFromStore(allocator: std.mem.Allocator, chunks: []const ManifestChunk, store_dir: std.fs.Dir) ![]u8 {
    var total_len: usize = 0;
    for (chunks) |c| {
        total_len += c.len;
    }

    var result = try allocator.alloc(u8, total_len);
    errdefer allocator.free(result);
    var offset: usize = 0;

    for (chunks) |c| {
        const hex = chunk.hashToHex(c.hash);
        const prefix = hex[0..2];
        const filename = hex[2..];

        var sub_dir = store_dir.openDir(prefix, .{}) catch return error.ChunkNotFound;
        defer sub_dir.close();

        var file = sub_dir.openFile(filename, .{}) catch return error.ChunkNotFound;
        defer file.close();

        const bytes_read = try file.readAll(result[offset .. offset + c.len]);
        if (bytes_read != c.len) return error.ChunkCorrupted;
        offset += c.len;
    }

    return result;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "manifest write and read round-trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const hash1 = chunk.blake3_pub("hello");
    const hash2 = chunk.blake3_pub("world");

    const entries = [_]ManifestEntry{
        .{
            .path = "src/main.zig",
            .size = 1234,
            .mode = 0o644,
            .chunks = &[_]ManifestChunk{
                .{ .hash = hash1, .len = 800 },
                .{ .hash = hash2, .len = 434 },
            },
        },
        .{
            .path = "README.md",
            .size = 42,
            .mode = 0o644,
            .chunks = &[_]ManifestChunk{
                .{ .hash = hash1, .len = 42 },
            },
        },
    };

    const manifest = Manifest{ .entries = &entries };

    // Write
    const file = try tmp.dir.createFile("test.manifest", .{});
    try manifest.write(file);
    file.close();

    // Read back
    const read_file = try tmp.dir.openFile("test.manifest", .{});
    defer read_file.close();
    var read_manifest = try Manifest.read(testing.allocator, read_file);
    defer read_manifest.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), read_manifest.entries.len);
    try testing.expectEqualStrings("src/main.zig", read_manifest.entries[0].path);
    try testing.expectEqual(@as(u64, 1234), read_manifest.entries[0].size);
    try testing.expectEqual(@as(u32, 0o644), read_manifest.entries[0].mode);
    try testing.expectEqual(@as(usize, 2), read_manifest.entries[0].chunks.len);
    try testing.expectEqualStrings("README.md", read_manifest.entries[1].path);
    try testing.expectEqual(@as(usize, 1), read_manifest.entries[1].chunks.len);
}

test "manifest preserves chunk hashes exactly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const hash = chunk.blake3_pub("test data for hash verification");

    const entries = [_]ManifestEntry{.{
        .path = "file.txt",
        .size = 100,
        .mode = 0o755,
        .chunks = &[_]ManifestChunk{
            .{ .hash = hash, .len = 100 },
        },
    }};

    const manifest = Manifest{ .entries = &entries };
    const file = try tmp.dir.createFile("test.manifest", .{});
    try manifest.write(file);
    file.close();

    const read_file = try tmp.dir.openFile("test.manifest", .{});
    defer read_file.close();
    var read = try Manifest.read(testing.allocator, read_file);
    defer read.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, &hash, &read.entries[0].chunks[0].hash);
    try testing.expectEqual(@as(u32, 0o755), read.entries[0].mode);
}

test "manifest empty entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]ManifestEntry{};
    const manifest = Manifest{ .entries = &entries };

    const file = try tmp.dir.createFile("empty.manifest", .{});
    try manifest.write(file);
    file.close();

    const read_file = try tmp.dir.openFile("empty.manifest", .{});
    defer read_file.close();
    var read = try Manifest.read(testing.allocator, read_file);
    defer read.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), read.entries.len);
}
