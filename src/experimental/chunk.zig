const std = @import("std");

// ============================================================
// Content-Defined Chunking Engine
//
// GearHash rolling hash with ~64KB target chunk size.
// BLAKE3 content-addressed chunk hashing.
// Local chunk store with cross-run deduplication.
// ============================================================

// --- Configuration ---

const MIN_CHUNK: usize = 8 * 1024; // 8KB minimum
const MAX_CHUNK: usize = 256 * 1024; // 256KB maximum
const MASK_BITS: u6 = 16; // 2^16 = 64KB average
const MASK: u64 = (@as(u64, 1) << MASK_BITS) - 1;
pub const MAX_FILE_SIZE: usize = 512 * 1024 * 1024; // 512MB per file

pub const help =
    \\usage: zagi -e chunk <directory> [options]
    \\
    \\Content-defined chunking for directory trees.
    \\Chunks files using GearHash rolling hash (~64KB average)
    \\and BLAKE3 content-addressed hashing.
    \\
    \\Stores chunks in .zagi/store/. Subsequent runs show
    \\deduplication against previously stored chunks.
    \\
    \\options:
    \\  --verify    Verify round-trip (chunk then reassemble and compare)
    \\  --clean     Remove stored chunks before chunking
    \\  --dry-run   Show stats without storing chunks
    \\
;

// --- GearHash Table ---
// Pre-computed via SplitMix64 PRNG with fixed seed for reproducibility.

const GEAR: [256]u64 = blk: {
    var t: [256]u64 = undefined;
    var s: u64 = 0x12345678_9ABCDEF0;
    for (&t) |*e| {
        s +%= 0x9E3779B97F4A7C15;
        var z = s;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        e.* = z ^ (z >> 31);
    }
    break :blk t;
};

// --- Types ---

pub const Hash = [32]u8;

pub const ChunkRef = struct {
    hash: Hash,
    offset: usize,
    len: usize,
};

pub const FileManifest = struct {
    path: []const u8,
    size: usize,
    chunks: []const ChunkRef,
};

pub const ChunkStats = struct {
    total_files: usize,
    total_bytes: u64,
    total_chunks: usize,
    unique_chunks: usize,
    new_chunks: usize,
    reused_chunks: usize,
    stored_bytes: u64,
    skipped_files: usize,

    fn dedupRatio(self: ChunkStats) f64 {
        if (self.total_chunks == 0) return 0;
        const dupes: f64 = @floatFromInt(self.total_chunks - self.unique_chunks);
        const total: f64 = @floatFromInt(self.total_chunks);
        return (dupes / total) * 100.0;
    }

    fn reuseRatio(self: ChunkStats) f64 {
        if (self.total_chunks == 0) return 0;
        const reused: f64 = @floatFromInt(self.reused_chunks);
        const total: f64 = @floatFromInt(self.total_chunks);
        return (reused / total) * 100.0;
    }
};

// --- Core: Content-Defined Chunking ---

/// Chunk a byte slice using GearHash CDC.
/// Returns owned slice of ChunkRefs. Caller owns the memory.
pub fn chunkData(allocator: std.mem.Allocator, data: []const u8) ![]ChunkRef {
    var refs = std.ArrayList(ChunkRef).init(allocator);
    errdefer refs.deinit();

    if (data.len == 0) return try refs.toOwnedSlice();

    if (data.len <= MIN_CHUNK) {
        try refs.append(.{
            .hash = blake3(data),
            .offset = 0,
            .len = data.len,
        });
        return try refs.toOwnedSlice();
    }

    var start: usize = 0;
    while (start < data.len) {
        var end = start + MIN_CHUNK;

        if (end >= data.len) {
            // Remainder is smaller than MIN_CHUNK, single final chunk
            try refs.append(.{
                .hash = blake3(data[start..]),
                .offset = start,
                .len = data.len - start,
            });
            break;
        }

        // Scan for boundary using GearHash
        var gear: u64 = 0;
        while (end < data.len and (end - start) < MAX_CHUNK) {
            gear = (gear << 1) +% GEAR[data[end]];
            end += 1;
            if ((gear & MASK) == 0) break;
        }

        try refs.append(.{
            .hash = blake3(data[start..end]),
            .offset = start,
            .len = end - start,
        });
        start = end;
    }

    return try refs.toOwnedSlice();
}

/// Reassemble original data from chunks using stored chunk data.
pub fn reassemble(allocator: std.mem.Allocator, chunks: []const ChunkRef, store_dir: std.fs.Dir) ![]u8 {
    var total_len: usize = 0;
    for (chunks) |c| {
        total_len += c.len;
    }

    var result = try allocator.alloc(u8, total_len);
    var offset: usize = 0;

    for (chunks) |c| {
        const hex = hashToHex(c.hash);
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

// --- BLAKE3 Hashing ---

pub fn blake3_pub(data: []const u8) Hash {
    return blake3(data);
}

fn blake3(data: []const u8) Hash {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(data);
    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

// --- Hex Encoding ---

const hex_chars = "0123456789abcdef";

pub fn hashToHex(hash: Hash) [64]u8 {
    var hex: [64]u8 = undefined;
    for (hash, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return hex;
}

// --- Chunk Store ---

const StoreError = error{
    ChunkNotFound,
    ChunkCorrupted,
    StoreCreateFailed,
};

fn ensureStoreDir(base_path: []const u8) !std.fs.Dir {
    const cwd = std.fs.cwd();
    cwd.makePath(base_path) catch {};
    return cwd.openDir(base_path, .{}) catch return error.StoreCreateFailed;
}

pub fn storeChunk(store_dir: std.fs.Dir, hash: Hash, data: []const u8) !bool {
    const hex = hashToHex(hash);
    const prefix = hex[0..2];
    const filename = hex[2..];

    // Create prefix directory
    store_dir.makeDir(prefix) catch |e| {
        if (e != error.PathAlreadyExists) return false;
    };

    var sub_dir = store_dir.openDir(prefix, .{}) catch return false;
    defer sub_dir.close();

    // Check if chunk already exists
    if (sub_dir.access(filename, .{})) |_| {
        return false; // Already exists, not new
    } else |_| {}

    // Write chunk
    var file = sub_dir.createFile(filename, .{}) catch return false;
    defer file.close();
    file.writeAll(data) catch return false;

    return true; // New chunk stored
}

fn chunkExistsInStore(store_dir: std.fs.Dir, hash: Hash) bool {
    const hex = hashToHex(hash);
    const prefix = hex[0..2];
    const filename = hex[2..];

    var sub_dir = store_dir.openDir(prefix, .{}) catch return false;
    defer sub_dir.close();

    sub_dir.access(filename, .{}) catch return false;
    return true;
}

// --- Directory Walking ---

fn chunkDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    store_dir: ?std.fs.Dir,
    dry_run: bool,
) !struct { stats: ChunkStats, manifests: std.ArrayList(FileManifest) } {
    var stats = ChunkStats{
        .total_files = 0,
        .total_bytes = 0,
        .total_chunks = 0,
        .unique_chunks = 0,
        .new_chunks = 0,
        .reused_chunks = 0,
        .stored_bytes = 0,
        .skipped_files = 0,
    };

    var manifests = std.ArrayList(FileManifest).init(allocator);
    var seen_hashes = std.AutoHashMap(Hash, void).init(allocator);
    defer seen_hashes.deinit();

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |e| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("error: cannot open directory '{s}': {}\n", .{ dir_path, e }) catch {};
        return .{ .stats = stats, .manifests = manifests };
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        // Read file
        const file = dir.openFile(entry.path, .{}) catch {
            stats.skipped_files += 1;
            continue;
        };
        defer file.close();

        const file_stat = file.stat() catch {
            stats.skipped_files += 1;
            continue;
        };

        if (file_stat.size > MAX_FILE_SIZE) {
            stats.skipped_files += 1;
            continue;
        }

        const data = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
            stats.skipped_files += 1;
            continue;
        };
        defer allocator.free(data);

        if (data.len == 0) continue;

        // Chunk the file
        const chunks = try chunkData(allocator, data);

        stats.total_files += 1;
        stats.total_bytes += data.len;
        stats.total_chunks += chunks.len;

        for (chunks) |chunk| {
            const is_new_in_run = !seen_hashes.contains(chunk.hash);
            if (is_new_in_run) {
                seen_hashes.put(chunk.hash, {}) catch {};
                stats.unique_chunks += 1;
            }

            if (store_dir) |sd| {
                if (!dry_run) {
                    const chunk_data = data[chunk.offset .. chunk.offset + chunk.len];
                    const was_new = storeChunk(sd, chunk.hash, chunk_data) catch false;
                    if (was_new) {
                        stats.new_chunks += 1;
                        stats.stored_bytes += chunk.len;
                    } else {
                        stats.reused_chunks += 1;
                    }
                } else {
                    // Dry run: check if it exists in store
                    if (chunkExistsInStore(sd, chunk.hash)) {
                        stats.reused_chunks += 1;
                    } else {
                        stats.new_chunks += 1;
                        stats.stored_bytes += chunk.len;
                    }
                }
            }
        }

        // Save manifest entry (path needs to be duped since walker reuses buffer)
        const path_copy = try allocator.dupe(u8, entry.path);
        try manifests.append(.{
            .path = path_copy,
            .size = data.len,
            .chunks = chunks,
        });
    }

    return .{ .stats = stats, .manifests = manifests };
}

// --- Verify Round-Trip ---

fn verifyRoundTrip(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    manifests: []const FileManifest,
    store_dir: std.fs.Dir,
) !bool {
    const stdout = std.io.getStdOut().writer();
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    var verified: usize = 0;
    var failed: usize = 0;

    for (manifests) |manifest| {
        // Read original file
        const file = dir.openFile(manifest.path, .{}) catch {
            try stdout.print("  SKIP {s} (cannot reopen)\n", .{manifest.path});
            failed += 1;
            continue;
        };
        defer file.close();

        const original = try file.readToEndAlloc(allocator, MAX_FILE_SIZE);
        defer allocator.free(original);

        // Reassemble from chunks
        const reassembled = reassemble(allocator, manifest.chunks, store_dir) catch {
            try stdout.print("  FAIL {s} (reassembly failed)\n", .{manifest.path});
            failed += 1;
            continue;
        };
        defer allocator.free(reassembled);

        // Compare
        if (std.mem.eql(u8, original, reassembled)) {
            verified += 1;
        } else {
            try stdout.print("  FAIL {s} (content mismatch)\n", .{manifest.path});
            failed += 1;
        }
    }

    try stdout.print("\nverify: {d} ok, {d} failed\n", .{ verified, failed });
    return failed == 0;
}

// --- Formatting ---

pub fn formatBytes(bytes: u64) struct { val: f64, unit: []const u8 } {
    if (bytes >= 1024 * 1024 * 1024) {
        return .{
            .val = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0),
            .unit = "GB",
        };
    } else if (bytes >= 1024 * 1024) {
        return .{
            .val = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0),
            .unit = "MB",
        };
    } else if (bytes >= 1024) {
        return .{
            .val = @as(f64, @floatFromInt(bytes)) / 1024.0,
            .unit = "KB",
        };
    } else {
        return .{
            .val = @as(f64, @floatFromInt(bytes)),
            .unit = "B",
        };
    }
}

fn printStats(stdout: anytype, stats: ChunkStats, has_store: bool) !void {
    const total = formatBytes(stats.total_bytes);
    try stdout.print("  files:   {d}", .{stats.total_files});
    if (stats.skipped_files > 0) {
        try stdout.print(" ({d} skipped)", .{stats.skipped_files});
    }
    try stdout.print("\n", .{});
    try stdout.print("  size:    {d:.1} {s}\n", .{ total.val, total.unit });
    try stdout.print("  chunks:  {d}\n", .{stats.total_chunks});
    try stdout.print("  unique:  {d} (dedup: {d:.1}%)\n", .{ stats.unique_chunks, stats.dedupRatio() });

    if (has_store) {
        if (stats.reused_chunks > 0 or stats.new_chunks > 0) {
            try stdout.print("  reused:  {d} ({d:.1}% from store)\n", .{ stats.reused_chunks, stats.reuseRatio() });
            try stdout.print("  new:     {d}\n", .{stats.new_chunks});
        }
        const stored = formatBytes(stats.stored_bytes);
        try stdout.print("  stored:  {d:.1} {s}\n", .{ stored.val, stored.unit });
    }
}

// --- CLI ---

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var dir_path: ?[]const u8 = null;
    var verify = false;
    var clean = false;
    var dry_run = false;

    for (args) |arg| {
        const a = std.mem.sliceTo(arg, 0);
        if (std.mem.eql(u8, a, "--verify")) {
            verify = true;
        } else if (std.mem.eql(u8, a, "--clean")) {
            clean = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try stdout.print("{s}", .{help});
            return;
        } else if (!std.mem.startsWith(u8, a, "-")) {
            dir_path = a;
        }
    }

    if (dir_path == null) {
        try stderr.print("error: no directory specified\n\n{s}", .{help});
        std.process.exit(1);
    }

    // Clean store if requested
    if (clean) {
        std.fs.cwd().deleteTree(".zagi/store") catch {};
        try stdout.print("cleaned .zagi/store/\n\n", .{});
    }

    // Open or create store
    const store_dir = ensureStoreDir(".zagi/store") catch |e| {
        try stderr.print("error: cannot create store: {}\n", .{e});
        std.process.exit(1);
    };
    // Can't defer close on a returned dir easily, but it'll be cleaned up on exit

    try stdout.print("chunking {s}...\n\n", .{dir_path.?});

    const result = try chunkDirectory(allocator, dir_path.?, store_dir, dry_run);
    const stats = result.stats;
    var manifests = result.manifests;
    defer {
        for (manifests.items) |m| {
            allocator.free(m.path);
            allocator.free(m.chunks);
        }
        manifests.deinit();
    }

    try printStats(stdout, stats, true);

    // Verify round-trip if requested
    if (verify and !dry_run) {
        try stdout.print("\nverifying round-trip...\n", .{});
        const ok = verifyRoundTrip(allocator, dir_path.?, manifests.items, store_dir) catch |e| {
            try stderr.print("error: verify failed: {}\n", .{e});
            std.process.exit(1);
        };
        if (!ok) {
            std.process.exit(1);
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "GEAR table has 256 unique entries" {
    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();

    for (GEAR) |val| {
        try seen.put(val, {});
    }
    try testing.expectEqual(@as(usize, 256), seen.count());
}

test "GEAR table is deterministic" {
    // Re-compute and verify matches
    const expected: [256]u64 = comptime blk: {
        var t: [256]u64 = undefined;
        var s: u64 = 0x12345678_9ABCDEF0;
        for (&t) |*e| {
            s +%= 0x9E3779B97F4A7C15;
            var z = s;
            z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
            e.* = z ^ (z >> 31);
        }
        break :blk t;
    };

    for (GEAR, expected) |actual, exp| {
        try testing.expectEqual(exp, actual);
    }
}

test "blake3 produces correct hash length" {
    const data = "hello world";
    const hash = blake3(data);
    try testing.expectEqual(@as(usize, 32), hash.len);
}

test "blake3 same input produces same hash" {
    const data = "deterministic hashing test";
    const h1 = blake3(data);
    const h2 = blake3(data);
    try testing.expectEqualSlices(u8, &h1, &h2);
}

test "blake3 different input produces different hash" {
    const h1 = blake3("input one");
    const h2 = blake3("input two");
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "hashToHex produces 64 hex characters" {
    const hash = blake3("test");
    const hex = hashToHex(hash);
    for (hex) |ch| {
        try testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    }
}

test "chunkData empty input returns empty" {
    const chunks = try chunkData(testing.allocator, "");
    defer testing.allocator.free(chunks);
    try testing.expectEqual(@as(usize, 0), chunks.len);
}

test "chunkData small input returns single chunk" {
    const data = "small file content";
    const chunks = try chunkData(testing.allocator, data);
    defer testing.allocator.free(chunks);

    try testing.expectEqual(@as(usize, 1), chunks.len);
    try testing.expectEqual(@as(usize, 0), chunks[0].offset);
    try testing.expectEqual(data.len, chunks[0].len);
}

test "chunkData preserves all bytes" {
    // Generate data larger than MIN_CHUNK but smaller than MAX_CHUNK
    const size = MIN_CHUNK * 4;
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);

    // Fill with pseudo-random data to trigger chunk boundaries
    var rng = std.Random.DefaultPrng.init(42);
    rng.fill(data);

    const chunks = try chunkData(testing.allocator, data);
    defer testing.allocator.free(chunks);

    // Verify chunks cover all bytes
    var total_len: usize = 0;
    var expected_offset: usize = 0;
    for (chunks) |chunk| {
        try testing.expectEqual(expected_offset, chunk.offset);
        total_len += chunk.len;
        expected_offset += chunk.len;
    }
    try testing.expectEqual(size, total_len);
}

test "chunkData respects MIN_CHUNK" {
    const size = MIN_CHUNK * 10;
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);

    var rng = std.Random.DefaultPrng.init(123);
    rng.fill(data);

    const chunks = try chunkData(testing.allocator, data);
    defer testing.allocator.free(chunks);

    // All chunks except possibly the last must be >= MIN_CHUNK
    for (chunks[0 .. chunks.len - 1]) |chunk| {
        try testing.expect(chunk.len >= MIN_CHUNK);
    }
}

test "chunkData respects MAX_CHUNK" {
    const size = MAX_CHUNK * 3;
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);

    // Fill with zeros (unlikely to trigger gear hash boundaries)
    @memset(data, 0);

    const chunks = try chunkData(testing.allocator, data);
    defer testing.allocator.free(chunks);

    for (chunks) |chunk| {
        try testing.expect(chunk.len <= MAX_CHUNK);
    }
}

test "chunkData identical content produces identical hashes" {
    const data = "a" ** (MIN_CHUNK + 100);
    const chunks1 = try chunkData(testing.allocator, data);
    defer testing.allocator.free(chunks1);
    const chunks2 = try chunkData(testing.allocator, data);
    defer testing.allocator.free(chunks2);

    try testing.expectEqual(chunks1.len, chunks2.len);
    for (chunks1, chunks2) |c1, c2| {
        try testing.expectEqualSlices(u8, &c1.hash, &c2.hash);
        try testing.expectEqual(c1.offset, c2.offset);
        try testing.expectEqual(c1.len, c2.len);
    }
}

test "chunkData content-defined boundaries are stable" {
    // Inserting data at the beginning should only affect the first chunk(s)
    const size = MIN_CHUNK * 8;
    const data1 = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data1);
    var rng1 = std.Random.DefaultPrng.init(999);
    rng1.fill(data1);

    // Create data2 with 100 different bytes at the start, same content after
    const data2 = try testing.allocator.alloc(u8, size + 100);
    defer testing.allocator.free(data2);
    @memset(data2[0..100], 0xFF);
    @memcpy(data2[100..], data1);

    const chunks1 = try chunkData(testing.allocator, data1);
    defer testing.allocator.free(chunks1);
    const chunks2 = try chunkData(testing.allocator, data2);
    defer testing.allocator.free(chunks2);

    // After the insertion point, later chunks should share hashes
    // (this is the key property of content-defined chunking)
    // Count how many chunk hashes from data1 appear in data2's chunks
    var shared: usize = 0;
    for (chunks1) |c1| {
        for (chunks2) |c2| {
            if (std.mem.eql(u8, &c1.hash, &c2.hash)) {
                shared += 1;
                break;
            }
        }
    }
    // At least some chunks should be shared (content-defined property)
    // With random data and a 100-byte prefix, most chunks after the first
    // boundary should be identical
    try testing.expect(shared > 0);
}

test "formatBytes formats correctly" {
    const b = formatBytes(500);
    try testing.expectApproxEqAbs(@as(f64, 500.0), b.val, 0.01);
    try testing.expectEqualStrings("B", b.unit);

    const kb = formatBytes(10 * 1024);
    try testing.expectApproxEqAbs(@as(f64, 10.0), kb.val, 0.01);
    try testing.expectEqualStrings("KB", kb.unit);

    const mb = formatBytes(50 * 1024 * 1024);
    try testing.expectApproxEqAbs(@as(f64, 50.0), mb.val, 0.01);
    try testing.expectEqualStrings("MB", mb.unit);

    const gb = formatBytes(2 * 1024 * 1024 * 1024);
    try testing.expectApproxEqAbs(@as(f64, 2.0), gb.val, 0.01);
    try testing.expectEqualStrings("GB", gb.unit);
}

test "ChunkStats dedupRatio with no duplicates" {
    const stats = ChunkStats{
        .total_files = 10,
        .total_bytes = 1000,
        .total_chunks = 100,
        .unique_chunks = 100,
        .new_chunks = 100,
        .reused_chunks = 0,
        .stored_bytes = 1000,
        .skipped_files = 0,
    };
    try testing.expectApproxEqAbs(@as(f64, 0.0), stats.dedupRatio(), 0.01);
}

test "ChunkStats dedupRatio with 50% duplicates" {
    const stats = ChunkStats{
        .total_files = 10,
        .total_bytes = 1000,
        .total_chunks = 100,
        .unique_chunks = 50,
        .new_chunks = 50,
        .reused_chunks = 50,
        .stored_bytes = 500,
        .skipped_files = 0,
    };
    try testing.expectApproxEqAbs(@as(f64, 50.0), stats.dedupRatio(), 0.01);
}

test "ChunkStats reuseRatio" {
    const stats = ChunkStats{
        .total_files = 10,
        .total_bytes = 1000,
        .total_chunks = 100,
        .unique_chunks = 80,
        .new_chunks = 25,
        .reused_chunks = 75,
        .stored_bytes = 250,
        .skipped_files = 0,
    };
    try testing.expectApproxEqAbs(@as(f64, 75.0), stats.reuseRatio(), 0.01);
}

test "store and retrieve chunk round-trip" {
    // Create a temporary directory for the store
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const data = "hello world chunk data";
    const hash = blake3(data);

    // Store the chunk
    const was_new = try storeChunk(tmp_dir.dir, hash, data);
    try testing.expect(was_new);

    // Store again - should not be new
    const was_new2 = try storeChunk(tmp_dir.dir, hash, data);
    try testing.expect(!was_new2);

    // Verify it exists
    try testing.expect(chunkExistsInStore(tmp_dir.dir, hash));

    // Read it back
    const hex = hashToHex(hash);
    var sub_dir = try tmp_dir.dir.openDir(hex[0..2], .{});
    defer sub_dir.close();

    var file = try sub_dir.openFile(hex[2..], .{});
    defer file.close();

    var buf: [100]u8 = undefined;
    const n = try file.readAll(&buf);
    try testing.expectEqualStrings(data, buf[0..n]);
}

test "reassemble from stored chunks" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const data = "this is test data for reassembly verification";
    const chunks = try chunkData(testing.allocator, data);
    defer testing.allocator.free(chunks);

    // Store all chunks
    for (chunks) |chunk| {
        _ = try storeChunk(tmp_dir.dir, chunk.hash, data[chunk.offset .. chunk.offset + chunk.len]);
    }

    // Reassemble
    const reassembled = try reassemble(testing.allocator, chunks, tmp_dir.dir);
    defer testing.allocator.free(reassembled);

    try testing.expectEqualStrings(data, reassembled);
}

test "reassemble large data round-trip" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Generate data that will produce multiple chunks (need > MAX_CHUNK)
    const size = MAX_CHUNK * 3;
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    var rng = std.Random.DefaultPrng.init(7777);
    rng.fill(data);

    const chunks = try chunkData(testing.allocator, data);
    defer testing.allocator.free(chunks);

    // Must produce multiple chunks
    try testing.expect(chunks.len > 1);

    // Store all chunks
    for (chunks) |chunk| {
        _ = try storeChunk(tmp_dir.dir, chunk.hash, data[chunk.offset .. chunk.offset + chunk.len]);
    }

    // Reassemble and verify
    const reassembled = try reassemble(testing.allocator, chunks, tmp_dir.dir);
    defer testing.allocator.free(reassembled);

    try testing.expectEqualSlices(u8, data, reassembled);
}
