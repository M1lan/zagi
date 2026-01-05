const std = @import("std");
const git = @import("git.zig");
const c = git.c;

pub const help =
    \\usage: git edit <command> [options]
    \\
    \\Travel to a commit for editing, then return with rebased descendants.
    \\
    \\Commands:
    \\  <commit>                Travel to commit for editing
    \\  --back                  Return to original branch and rebase
    \\  --abort                 Cancel edit and return to original state
    \\  --status                Show current edit state
    \\
    \\Options:
    \\  -h, --help              Show this help message
    \\
    \\Examples:
    \\  git edit abc123         Travel to commit abc123 for editing
    \\  git edit HEAD~3         Travel 3 commits back for editing
    \\  git edit --back         Return and rebase descendants
    \\  git edit --abort        Cancel edit session
    \\  git edit --status       Show if edit is active
    \\
;

pub const Error = git.Error || error{
    EditActive,
    EditNotActive,
    DirtyWorkingTree,
    NotAnAncestor,
    CherryPickConflict,
    DetachedHead,
    InvalidCommit,
    RefReadFailed,
    RefWriteFailed,
    RefDeleteFailed,
    AllocationError,
};

// Ref names for edit state
const REF_EDIT_ORIGIN = "refs/edit/origin";
const REF_EDIT_DESCENDANTS = "refs/edit/descendants";

/// Check if an edit session is currently active
pub fn isEditActive(repo: ?*c.git_repository) bool {
    var ref: ?*c.git_reference = null;
    const result = c.git_reference_lookup(&ref, repo, REF_EDIT_ORIGIN);
    if (result == 0) {
        c.git_reference_free(ref);
        return true;
    }
    return false;
}

/// Get the original HEAD OID from before the edit started
pub fn getOrigin(repo: ?*c.git_repository) ?c.git_oid {
    var ref: ?*c.git_reference = null;
    const result = c.git_reference_lookup(&ref, repo, REF_EDIT_ORIGIN);
    if (result < 0) {
        return null;
    }
    defer c.git_reference_free(ref);

    const target_oid = c.git_reference_target(ref);
    if (target_oid == null) {
        return null;
    }
    return target_oid.*;
}

/// Get the list of descendant commit OIDs to rebase
pub fn getDescendants(repo: ?*c.git_repository, allocator: std.mem.Allocator) Error![]c.git_oid {
    // Look up the descendants ref
    var ref: ?*c.git_reference = null;
    const lookup_result = c.git_reference_lookup(&ref, repo, REF_EDIT_DESCENDANTS);
    if (lookup_result < 0) {
        if (lookup_result == c.GIT_ENOTFOUND) {
            // No descendants stored - return empty slice
            return allocator.alloc(c.git_oid, 0) catch return Error.AllocationError;
        }
        return Error.RefReadFailed;
    }
    defer c.git_reference_free(ref);

    // Get the blob OID the ref points to
    const blob_oid = c.git_reference_target(ref);
    if (blob_oid == null) {
        return Error.RefReadFailed;
    }

    // Look up the blob
    var blob: ?*c.git_blob = null;
    if (c.git_blob_lookup(&blob, repo, blob_oid) < 0) {
        return Error.RefReadFailed;
    }
    defer c.git_blob_free(blob);

    // Get blob content
    const content_ptr = c.git_blob_rawcontent(blob);
    const content_size = c.git_blob_rawsize(blob);

    if (content_ptr == null or content_size == 0) {
        return allocator.alloc(c.git_oid, 0) catch return Error.AllocationError;
    }

    const content = @as([*]const u8, @ptrCast(content_ptr))[0..content_size];

    // Parse newline-separated OID hex strings
    var oids = std.ArrayList(c.git_oid){};
    errdefer oids.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // Skip empty lines
        if (line.len == 0) continue;

        // Parse hex string to OID
        var oid: c.git_oid = undefined;
        if (c.git_oid_fromstr(&oid, line.ptr) == 0) {
            oids.append(allocator, oid) catch return Error.AllocationError;
        }
    }

    return oids.toOwnedSlice(allocator) catch return Error.AllocationError;
}

/// Save edit state to refs
pub fn saveState(repo: ?*c.git_repository, origin: c.git_oid, descendants: []const c.git_oid, allocator: std.mem.Allocator) Error!void {
    // Save origin ref - points directly to the commit OID
    var origin_ref: ?*c.git_reference = null;
    if (c.git_reference_create(&origin_ref, repo, REF_EDIT_ORIGIN, &origin, 1, null) < 0) {
        return Error.RefWriteFailed;
    }
    c.git_reference_free(origin_ref);

    // Save descendants ref - points to a blob containing newline-separated OIDs
    // Build content: one hex OID per line
    var content = std.ArrayList(u8){};
    defer content.deinit(allocator);

    for (descendants) |oid| {
        var hex: [40]u8 = undefined;
        _ = c.git_oid_fmt(&hex, &oid);
        content.appendSlice(allocator, &hex) catch return Error.AllocationError;
        content.append(allocator, '\n') catch return Error.AllocationError;
    }

    // Create blob from content
    var blob_oid: c.git_oid = undefined;
    if (c.git_blob_create_from_buffer(&blob_oid, repo, content.items.ptr, content.items.len) < 0) {
        return Error.RefWriteFailed;
    }

    // Create the reference pointing to the blob
    var descendants_ref: ?*c.git_reference = null;
    if (c.git_reference_create(&descendants_ref, repo, REF_EDIT_DESCENDANTS, &blob_oid, 1, null) < 0) {
        return Error.RefWriteFailed;
    }
    c.git_reference_free(descendants_ref);
}

/// Clear edit state by deleting refs
pub fn clearState(repo: ?*c.git_repository) Error!void {
    // Delete origin ref
    var origin_ref: ?*c.git_reference = null;
    if (c.git_reference_lookup(&origin_ref, repo, REF_EDIT_ORIGIN) == 0) {
        if (c.git_reference_delete(origin_ref) < 0) {
            c.git_reference_free(origin_ref);
            return Error.RefDeleteFailed;
        }
        c.git_reference_free(origin_ref);
    }

    // Delete descendants ref
    var descendants_ref: ?*c.git_reference = null;
    if (c.git_reference_lookup(&descendants_ref, repo, REF_EDIT_DESCENDANTS) == 0) {
        if (c.git_reference_delete(descendants_ref) < 0) {
            c.git_reference_free(descendants_ref);
            return Error.RefDeleteFailed;
        }
        c.git_reference_free(descendants_ref);
    }
}

/// Collect all commits between target (exclusive) and HEAD (inclusive).
/// Returns OIDs in oldest-first order (ready for rebasing).
/// These are the commits that will need to be rebased after editing the target.
pub fn collectDescendants(repo: ?*c.git_repository, target: c.git_oid, head: c.git_oid, allocator: std.mem.Allocator) Error![]c.git_oid {
    // Create revwalk
    var walk: ?*c.git_revwalk = null;
    if (c.git_revwalk_new(&walk, repo) < 0) {
        return Error.NotAnAncestor;
    }
    defer c.git_revwalk_free(walk);

    // Sort topologically and reverse to get oldest-first order
    _ = c.git_revwalk_sorting(walk, c.GIT_SORT_TOPOLOGICAL | c.GIT_SORT_REVERSE);

    // Start from HEAD
    if (c.git_revwalk_push(walk, &head) < 0) {
        return Error.NotAnAncestor;
    }

    // Hide the target commit and its ancestors - we only want descendants
    if (c.git_revwalk_hide(walk, &target) < 0) {
        return Error.NotAnAncestor;
    }

    // Collect all commits in the walk
    var oids = std.ArrayList(c.git_oid){};
    errdefer oids.deinit(allocator);

    var oid: c.git_oid = undefined;
    while (c.git_revwalk_next(&oid, walk) == 0) {
        oids.append(allocator, oid) catch return Error.AllocationError;
    }

    return oids.toOwnedSlice(allocator) catch return Error.AllocationError;
}

/// Start an edit session - travel to a commit for editing.
/// Preconditions: repo is clean, not already in edit mode, HEAD is on a branch, target is an ancestor of HEAD.
pub fn startEdit(repo: ?*c.git_repository, target_str: []const u8, allocator: std.mem.Allocator) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Check if edit is already active
    if (isEditActive(repo)) {
        return Error.EditActive;
    }

    // Check for uncommitted changes
    if (git.countUncommitted(repo)) |counts| {
        if (counts.total() > 0) {
            return Error.DirtyWorkingTree;
        }
    }

    // Check that HEAD is on a branch (not detached)
    var head_ref: ?*c.git_reference = null;
    if (c.git_repository_head(&head_ref, repo) < 0) {
        return Error.DetachedHead;
    }
    defer c.git_reference_free(head_ref);

    if (c.git_reference_is_branch(head_ref) == 0) {
        return Error.DetachedHead;
    }

    // Get HEAD OID
    const head_oid_ptr = c.git_reference_target(head_ref);
    if (head_oid_ptr == null) {
        return Error.DetachedHead;
    }
    const head_oid = head_oid_ptr.*;

    // Resolve target commit-ish to OID
    var target_obj: ?*c.git_object = null;
    const target_cstr = @as([*c]const u8, @ptrCast(target_str.ptr));
    if (c.git_revparse_single(&target_obj, repo, target_cstr) < 0) {
        return Error.InvalidCommit;
    }
    defer c.git_object_free(target_obj);

    // Peel to commit if needed
    var target_commit: ?*c.git_commit = null;
    if (c.git_object_peel(@ptrCast(&target_commit), target_obj, c.GIT_OBJECT_COMMIT) < 0) {
        return Error.InvalidCommit;
    }
    defer c.git_commit_free(target_commit);

    const target_oid = c.git_commit_id(target_commit).*;

    // Check that target is an ancestor of HEAD
    var merge_base: c.git_oid = undefined;
    if (c.git_merge_base(&merge_base, repo, &target_oid, &head_oid) < 0) {
        return Error.NotAnAncestor;
    }

    // Target must be the merge base (i.e., an ancestor of HEAD)
    if (c.git_oid_cmp(&merge_base, &target_oid) != 0) {
        return Error.NotAnAncestor;
    }

    // Collect descendants from target to HEAD
    const descendants = try collectDescendants(repo, target_oid, head_oid, allocator);
    defer allocator.free(descendants);

    // Save state to refs
    try saveState(repo, head_oid, descendants, allocator);

    // Checkout target commit's tree
    var target_tree: ?*c.git_tree = null;
    if (c.git_commit_tree(&target_tree, target_commit) < 0) {
        // Clean up state if checkout fails
        clearState(repo) catch {};
        return Error.InvalidCommit;
    }
    defer c.git_tree_free(target_tree);

    // Set up checkout options
    var checkout_opts: c.git_checkout_options = undefined;
    _ = c.git_checkout_options_init(&checkout_opts, c.GIT_CHECKOUT_OPTIONS_VERSION);
    checkout_opts.checkout_strategy = c.GIT_CHECKOUT_SAFE;

    if (c.git_checkout_tree(repo, @ptrCast(target_tree), &checkout_opts) < 0) {
        // Clean up state if checkout fails
        clearState(repo) catch {};
        return Error.InvalidCommit;
    }

    // Update HEAD to point to target commit (detached HEAD)
    if (c.git_repository_set_head_detached(repo, &target_oid) < 0) {
        clearState(repo) catch {};
        return Error.InvalidCommit;
    }

    // Output: 'edit: <short-hash> (<subject>)'
    var short_hash: [8]u8 = undefined;
    _ = c.git_oid_tostr(&short_hash, short_hash.len, &target_oid);

    const subject = c.git_commit_summary(target_commit);
    const subject_str = if (subject) |s| std.mem.sliceTo(s, 0) else "(no message)";

    stdout.print("edit: {s} ({s})\n", .{ short_hash[0..7], subject_str }) catch return Error.AllocationError;

    // Output: 'from: <original-head>'
    var origin_short: [8]u8 = undefined;
    _ = c.git_oid_tostr(&origin_short, origin_short.len, &head_oid);
    stdout.print("from: {s}\n", .{origin_short[0..7]}) catch return Error.AllocationError;

    // Output: 'descendants: N commits'
    stdout.print("descendants: {d} commits\n", .{descendants.len}) catch return Error.AllocationError;
}

/// Main entry point for the edit command
pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Parse arguments
    var target: ?[]const u8 = null;

    for (args[2..]) |arg| {
        const a = std.mem.sliceTo(arg, 0);
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            stdout.print("{s}", .{help}) catch {};
            return;
        } else if (std.mem.eql(u8, a, "--back")) {
            // TODO: Implement comeBack()
            return git.Error.UsageError;
        } else if (std.mem.eql(u8, a, "--abort")) {
            // TODO: Implement abortEdit()
            return git.Error.UsageError;
        } else if (std.mem.eql(u8, a, "--status")) {
            // TODO: Implement showStatus()
            return git.Error.UsageError;
        } else if (!std.mem.startsWith(u8, a, "-")) {
            target = a;
        } else {
            return git.Error.UsageError;
        }
    }

    // Require a target commit
    if (target == null) {
        return git.Error.UsageError;
    }

    // Initialize libgit2
    if (c.git_libgit2_init() < 0) {
        return git.Error.InitFailed;
    }
    defer _ = c.git_libgit2_shutdown();

    // Open repository
    var repo: ?*c.git_repository = null;
    if (c.git_repository_open_ext(&repo, ".", 0, null) < 0) {
        return git.Error.NotARepository;
    }
    defer c.git_repository_free(repo);

    // Start the edit session
    try startEdit(repo, target.?, allocator);
}
