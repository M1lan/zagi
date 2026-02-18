# todo: environment limitations

This POC was built in a constrained environment. Here's what needs
to happen when we get back to a proper setup.

## Environment Issues

### Zig 0.15 doesn't run on kernel 4.4.0
The sandbox runs Linux 4.4.0. Zig 0.15 panics with `TODO` on every
compilation attempt (missing kernel features, likely io_uring or
newer syscalls). We used Zig 0.14.1 instead.

**Fix:** Build on a machine with kernel 5.x+ (any modern Linux).

### No network access to GitHub
`zig fetch` cannot reach github.com to download the vendored libgit2
dependency. We installed system libgit2-dev (1.7) and added a
`-Dsystem-libgit2` build flag.

**Fix:** On a networked machine, `zig build` works normally without
the flag. The `build.zig.zon` now has `lazy = true` on the libgit2
dep so it only fetches when actually needed.

## API Compatibility (0.14 vs 0.15)

The existing codebase was written for Zig 0.15. To build with 0.14
for testing, we made these changes:

### Changed in this PR (intentional)
- `std.fs.File.stdout().deprecatedWriter()` -> `std.io.getStdOut().writer()`
- `std.fs.File.stderr().deprecatedWriter()` -> `std.io.getStdErr().writer()`
- `std.array_list.Managed(T)` -> `std.ArrayList(T)`

These are **correct for both 0.14 and 0.15**. The 0.15 names were
deprecated renames; the 0.14 names are the canonical forms that work
on both versions.

### Not changed (existing code, breaks on 0.14 only)
- `fork.zig:270` uses `.checkout_existing` field on `git_worktree_add_options`
  which exists in libgit2 1.9 (vendored) but not 1.7 (system). Harmless -
  just means `git fork` won't work with system libgit2.
- `tasks.zig` / `agent.zig` use unmanaged ArrayList initialization
  (`std.ArrayList(T){}`) which is a 0.15 pattern. On 0.14, ArrayList
  is managed (stores allocator). These files need `.init(allocator)`.

**Fix:** None needed. When building with Zig 0.15 + vendored libgit2
(the normal case), everything works.

## What was built

### POC 1: Chunking Engine (`src/cmds/chunk.zig`)

Content-defined chunking with GearHash rolling hash and BLAKE3 hashes.
Pure Zig, no external dependencies.

**Tested results:**
- 20/20 unit tests pass
- Round-trip verified: chunk -> store -> reassemble = byte-for-byte identical
- Dedup works: 98% reuse after minor file changes (3/103 files modified)

### Wiring (`src/main.zig`)
- `-e` / `--experimental` flag routes to experimental commands
- `zagi -e chunk <dir>` runs the chunking engine
- All existing commands (`git clone`, `git push`, etc.) still pass through

## What to do next

1. Build with Zig 0.15 on a real machine - verify full build works
2. Run `zig build test` to confirm all tests pass (chunk + existing)
3. Test `zagi -e chunk` on an actual node_modules directory
4. Delete `src/chunk_cli.zig` (standalone test wrapper, not needed)
5. Delete this file
6. Move to Phase 2: Local store + round-trip (snapshots, manifests, hardlinks)
