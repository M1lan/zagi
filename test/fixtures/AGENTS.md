<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-16 | Updated: 2026-03-16 -->

# test/fixtures

## Purpose
Factory functions for creating isolated, ephemeral git repositories used as test fixtures. Each call to `createFixtureRepo()` produces a uniquely-named, fully-initialised repo with 20 commits and some uncommitted changes — ready for integration tests.

## Key Files

| File | Description |
|------|-------------|
| `setup.ts` | `createFixtureRepo()` — creates a repo under `fixtures/repos/<uid>/`; `cleanupFixtures()` — removes the entire `repos/` directory |

## For AI Agents

### Working In This Directory
- `createFixtureRepo()` returns an absolute path to the new repo. Always use this for isolated testing.
- Repos are created in `test/fixtures/repos/` (gitignored). Never commit them.
- `cleanupFixtures()` is called by `globalSetup.ts` (before suite) and `globalTeardown.ts` (after suite). Do not call it mid-test.
- Unique IDs (`Date.now() + random`) ensure parallel test safety.

### Testing Requirements
- Fixture repos always start on `main` branch with 20 commits.
- Pre-existing uncommitted changes: `src/new-file.ts` (untracked), `src/main.ts` (modified).

### Common Patterns
- Each test should call `createFixtureRepo()` independently to avoid state leakage between tests.
- Repos contain `src/`, `tests/`, and `docs/` directories plus a `README.md`.

## Dependencies

### External
- Node `child_process` — `execFileSync` for git operations during setup
- Node `fs` / `fs/promises` — directory and file creation

<!-- MANUAL: -->
