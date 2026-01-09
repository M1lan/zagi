import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { writeFileSync, mkdirSync } from "fs";
import { resolve } from "path";
import { zagi, git, createTestRepo, cleanupTestRepo } from "./shared";

let REPO_DIR: string;

// Use lightweight repo - these tests don't need multiple commits
beforeEach(() => {
  REPO_DIR = createTestRepo();
  // Create an untracked file for testing
  mkdirSync(resolve(REPO_DIR, "src"), { recursive: true });
  writeFileSync(resolve(REPO_DIR, "src/new-file.ts"), "// New file\n");
});

afterEach(() => {
  cleanupTestRepo(REPO_DIR);
});

describe("zagi add", () => {
  test("shows confirmation after adding file", () => {
    const result = zagi(["add", "src/new-file.ts"], { cwd: REPO_DIR });

    expect(result).toContain("staged:");
    expect(result).toContain("A ");
    expect(result).toContain("new-file.ts");
  });

  test("shows count of staged files", () => {
    const result = zagi(["add", "src/new-file.ts"], { cwd: REPO_DIR });

    expect(result).toMatch(/staged: \d+ file/);
  });

  test("error message is concise for missing file", () => {
    const result = zagi(["add", "nonexistent.txt"], { cwd: REPO_DIR });

    expect(result).toBe("error: file not found\n");
  });

  test("git add is silent on success", () => {
    const result = git(["add", "src/new-file.ts"], { cwd: REPO_DIR });

    expect(result).toBe("");
  });

  test("zagi add provides feedback", () => {
    const result = zagi(["add", "src/new-file.ts"], { cwd: REPO_DIR });

    expect(result.length).toBeGreaterThan(0);
  });
});
