import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { writeFileSync, mkdirSync, appendFileSync } from "fs";
import { resolve } from "path";
import { zagi, git, createTestRepo, cleanupTestRepo } from "./shared";

let REPO_DIR: string;

// Use lightweight repo - these tests don't need multiple commits
beforeEach(() => {
  REPO_DIR = createTestRepo();
  // Create test files similar to createFixtureRepo
  mkdirSync(resolve(REPO_DIR, "src"), { recursive: true });
  writeFileSync(resolve(REPO_DIR, "src/main.ts"), 'export function main() {\n  console.log("hello");\n}\n');
  git(["add", "src/main.ts"], { cwd: REPO_DIR });
  git(["commit", "-m", "Add main.ts"], { cwd: REPO_DIR });
  // Create uncommitted changes for status tests
  writeFileSync(resolve(REPO_DIR, "src/new-file.ts"), "// New file\n");
  appendFileSync(resolve(REPO_DIR, "src/main.ts"), "\n// Modified\n");
});

afterEach(() => {
  cleanupTestRepo(REPO_DIR);
});

describe("zagi status", () => {
  test("produces smaller output than git status", () => {
    const zagiOut = zagi(["status"], { cwd: REPO_DIR });
    const gitOut = git(["status"], { cwd: REPO_DIR });

    expect(zagiOut.length).toBeLessThan(gitOut.length);
  });

  test("shows branch name", () => {
    const result = zagi(["status"], { cwd: REPO_DIR });
    expect(result).toMatch(/^branch: \w+/);
  });

  test("detects modified files", () => {
    const zagiOut = zagi(["status"], { cwd: REPO_DIR });
    const gitOut = git(["status", "--porcelain"], { cwd: REPO_DIR });

    const gitHasModified = gitOut.includes(" M ");
    const zagiHasModified = zagiOut.includes("modified:");

    expect(zagiHasModified).toBe(gitHasModified);
  });

  test("detects untracked files", () => {
    const zagiOut = zagi(["status"], { cwd: REPO_DIR });
    const gitOut = git(["status", "--porcelain"], { cwd: REPO_DIR });

    const gitHasUntracked = gitOut.includes("??");
    const zagiHasUntracked = zagiOut.includes("untracked:");

    expect(zagiHasUntracked).toBe(gitHasUntracked);
  });
});

describe("zagi status path filtering", () => {
  test("filters by specific file path", () => {
    const all = zagi(["status"], { cwd: REPO_DIR });
    const filtered = zagi(["status", "src/main.ts"], { cwd: REPO_DIR });

    // Both should show the modified file
    expect(all).toContain("src/main.ts");
    expect(filtered).toContain("src/main.ts");
  });

  test("filters by directory path", () => {
    const result = zagi(["status", "src/"], { cwd: REPO_DIR });
    expect(result).toContain("src/main.ts");
  });

  test("shows nothing when path has no changes", () => {
    // Create and commit a file, then check status for it
    git(["checkout", "--", "src/main.ts"], { cwd: REPO_DIR });

    const result = zagi(["status", "src/main.ts"], { cwd: REPO_DIR });
    expect(result).toContain("nothing to commit");
  });

  test("filters out files not matching path", () => {
    // Check status for a path that doesn't have changes
    const result = zagi(["status", "nonexistent/"], { cwd: REPO_DIR });
    expect(result).toContain("nothing to commit");
  });

  test("multiple paths work", () => {
    const result = zagi(["status", "src/", "README.md"], { cwd: REPO_DIR });
    // Should show src/main.ts (modified in fixture)
    expect(result).toContain("src/main.ts");
  });
});
