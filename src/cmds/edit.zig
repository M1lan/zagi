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
    var oids = std.ArrayList(c.git_oid).init(allocator);
    errdefer oids.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // Skip empty lines
        if (line.len == 0) continue;

        // Parse hex string to OID
        var oid: c.git_oid = undefined;
        if (c.git_oid_fromstr(&oid, line.ptr) == 0) {
            oids.append(oid) catch return Error.AllocationError;
        }
    }

    return oids.toOwnedSlice() catch return Error.AllocationError;
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
    var content = std.ArrayList(u8).init(allocator);
    defer content.deinit();

    for (descendants) |oid| {
        var hex: [40]u8 = undefined;
        _ = c.git_oid_fmt(&hex, &oid);
        content.appendSlice(&hex) catch return Error.AllocationError;
        content.append('\n') catch return Error.AllocationError;
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
