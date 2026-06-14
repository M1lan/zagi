<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-16 | Updated: 2026-03-16 -->

# test

## Purpose
Integration and benchmark test suite for zagi commands. Written in TypeScript, run with Bun + Vitest. Tests call the compiled `zig-out/bin/zagi` binary against ephemeral git repos created by the fixture helpers.

## Key Files

| File | Description |
|------|-------------|
| `package.json` | Bun project manifest for the test suite |
| `tsconfig.json` | TypeScript config |
| `vitest.config.ts` | Vitest configuration — includes `src/**/*.test.ts`, global setup/teardown |
| `globalSetup.ts` | Runs before all tests — calls `cleanupFixtures()` to remove leftover repos from prior runs |
| `globalTeardown.ts` | Runs after all tests — calls `cleanupFixtures()` to remove temp fixture repos |
| `setup.ts` | Per-test setup helpers (imported by individual test files) |
| `bun.lock` | Locked dependency versions |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `src/` | Test and benchmark files, one per command (see `src/AGENTS.md`) |
| `fixtures/` | Fixture repo factory (see `fixtures/AGENTS.md`) |

## For AI Agents

### Working In This Directory
- Always build the binary before running tests: `zig build && cd test && bun run test`.
- To run only a specific command's tests: `bun run test src/<command>.test.ts`.
- Benchmarks use Vitest's bench runner: `bun run bench` (or `bun run test --reporter=verbose`).
- Fixture repos are created fresh per-test via `createFixtureRepo()` and cleaned up automatically.

### Testing Requirements
- Each new zagi command needs a corresponding `src/<command>.test.ts`.
- Tests must cover: happy path, error cases, and output size comparison against `git`.
- Benchmarks in `src/<command>.bench.ts` compare zagi vs git timing.

### Common Patterns
- Use `execFileSync(zagiPath, args, { cwd: repoDir })` to call the binary under test.
- `zagiPath` is typically `resolve(__dirname, "../../zig-out/bin/zagi")`.
- Each test gets its own isolated repo from `createFixtureRepo()` — never share repos across tests.

## Dependencies

### Internal
- `fixtures/setup.ts` — repo factory used by all tests

### External
- `vitest` — test runner and benchmark framework
- `bun` — runtime

<!-- MANUAL: -->
