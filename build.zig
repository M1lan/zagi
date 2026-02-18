const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_system_libgit2 = b.option(bool, "system-libgit2", "Use system libgit2 instead of vendored") orelse false;

    const exe = b.addExecutable(.{
        .name = "zagi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    linkGit2(b, exe, target, optimize, use_system_libgit2);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const log_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmds/log.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const git_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmds/git.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const alias_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmds/alias.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const add_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmds/add.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const commit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmds/commit.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const diff_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmds/diff.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const agent_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmds/agent.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Experimental tests (pure Zig, no libgit2)
    const chunk_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/experimental/chunk.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const snapshot_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/experimental/snapshot.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link libgit2 for tests that need it
    const libgit2_test_modules = [_]*std.Build.Step.Compile{ log_tests, git_tests, add_tests, commit_tests, diff_tests };
    for (libgit2_test_modules) |t| {
        linkGit2(b, t, target, optimize, use_system_libgit2);
    }

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_log_tests = b.addRunArtifact(log_tests);
    const run_git_tests = b.addRunArtifact(git_tests);
    const run_alias_tests = b.addRunArtifact(alias_tests);
    const run_add_tests = b.addRunArtifact(add_tests);
    const run_commit_tests = b.addRunArtifact(commit_tests);
    const run_diff_tests = b.addRunArtifact(diff_tests);
    const run_agent_tests = b.addRunArtifact(agent_tests);
    const run_chunk_tests = b.addRunArtifact(chunk_tests);
    const run_snapshot_tests = b.addRunArtifact(snapshot_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_log_tests.step);
    test_step.dependOn(&run_git_tests.step);
    test_step.dependOn(&run_alias_tests.step);
    test_step.dependOn(&run_add_tests.step);
    test_step.dependOn(&run_commit_tests.step);
    test_step.dependOn(&run_diff_tests.step);
    test_step.dependOn(&run_agent_tests.step);
    test_step.dependOn(&run_chunk_tests.step);
    test_step.dependOn(&run_snapshot_tests.step);
}

fn linkGit2(
    b: *std.Build,
    step: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_system: bool,
) void {
    if (use_system) {
        step.root_module.linkSystemLibrary("git2", .{});
        step.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
        step.linkLibC();
    } else {
        if (b.lazyDependency("libgit2", .{
            .target = target,
            .optimize = optimize,
        })) |libgit2_dep| {
            step.root_module.linkLibrary(libgit2_dep.artifact("git2"));
        }
    }
}
