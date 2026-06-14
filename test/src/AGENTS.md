<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-16 | Updated: 2026-03-16 -->

# test/src

## Purpose
Vitest test and benchmark files — one per implemented zagi command. Tests run the compiled binary against ephemeral fixture repositories and assert both correctness and output conciseness.

## Key Files

| File | Description |
|------|-------------|
| `shared.ts` | Shared test utilities (binary path resolution, helper wrappers) |
| `add.test.ts` | Integration tests for `zagi add` |
| `commit.test.ts` | Integration tests for `zagi commit` |
| `diff.test.ts` | Integration tests for `zagi diff` |
| `log.test.ts` | Integration tests for `zagi log` |
| `status.test.ts` | Integration tests for `zagi status` |
| `fork.test.ts` | Integration tests for `zagi fork` |
| `agent.test.ts` | Integration tests for `zagi agent` subcommands |
| `tasks.test.ts` | Integration tests for `zagi tasks` |
| `add.bench.ts` | Benchmark: zagi add vs git add |
| `commit.bench.ts` | Benchmark: zagi commit vs git commit |
| `diff.bench.ts` | Benchmark: zagi diff vs git diff |
| `log.bench.ts` | Benchmark: zagi log vs git log |
| `status.bench.ts` | Benchmark: zagi status vs git status |

## For AI Agents

### Working In This Directory
- Every new command needs both a `<command>.test.ts` and optionally a `<command>.bench.ts`.
- Import `createFixtureRepo` from `../fixtures/setup` to get an isolated git repo.
- Assert output is smaller than git's equivalent (core zagi design goal).
- Use `execFileSync` with `stdio: "pipe"` to capture output; check both stdout and exit code.

### Testing Requirements
- Tests run via: `cd test && bun run test`
- Benchmarks run via: `cd test && bun run bench`
- All tests must be deterministic — use fixture repos, never the real zagi repo.

### Common Patterns
```typescript
import { createFixtureRepo } from "../fixtures/setup";
import { execFileSync } from "child_process";
import { resolve } from "path";

const ZAGI = resolve(__dirname, "../../../zig-out/bin/zagi");

describe("zagi <command>", () => {
  test("produces smaller output than git", () => {
    const repoDir = createFixtureRepo();
    const zagiOut = execFileSync(ZAGI, ["<command>"], { cwd: repoDir, stdio: "pipe" }).toString();
    const gitOut  = execFileSync("git", ["<command>"], { cwd: repoDir, stdio: "pipe" }).toString();
    expect(zagiOut.length).toBeLessThan(gitOut.length);
  });
});
```

## Dependencies

### Internal
- `../fixtures/setup` — `createFixtureRepo()`, `cleanupFixtures()`

### External
- `vitest` — test runner

<!-- MANUAL: -->
