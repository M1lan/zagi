const std = @import("std");
const git = @import("git.zig");

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
};
