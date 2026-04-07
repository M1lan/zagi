#!/usr/bin/env bash
#
# Conformance tests: verify zagi --compat produces identical output to git
#
# Usage: ./test/conformance.sh [path/to/zagi]
#
set -uo pipefail

ZAGI="${1:-./zig-out/bin/zagi}"
PASS=0
FAIL=0
SKIP=0
FAILURES=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

cleanup() {
    if [ -n "${REPO_DIR:-}" ] && [ -d "$REPO_DIR" ]; then
        rm -rf "$REPO_DIR"
    fi
}
trap cleanup EXIT

# Create a fresh test repo
setup_repo() {
    REPO_DIR=$(mktemp -d)
    cd "$REPO_DIR"
    git init -b main -q
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Initial commit
    echo "# Test" > README.md
    git add .
    git commit -q -m "Initial commit"

    # Second commit with multiple files
    mkdir -p src docs
    echo 'export function main() { console.log("hello"); }' > src/main.ts
    echo 'export function add(a, b) { return a + b; }' > src/utils.ts
    echo '# Docs' > docs/guide.md
    git add .
    git commit -q -m "Add project structure"

    # Third commit
    echo '// updated' >> src/main.ts
    git add src/main.ts
    git commit -q -m "Update main entry point"

    # Fourth commit - rename
    echo 'export const config = {};' > src/config.ts
    git add .
    git commit -q -m "Add configuration"

    # Create some uncommitted state
    echo '// modified' >> src/utils.ts         # unstaged modification
    echo 'new file' > src/new-file.ts          # untracked
    echo '// staged change' >> src/config.ts
    git add src/config.ts                       # staged modification
}

assert_match() {
    local test_name="$1"
    local git_out="$2"
    local zagi_out="$3"

    if [ "$git_out" = "$zagi_out" ]; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}✓${NC} $test_name"
    else
        FAIL=$((FAIL + 1))
        FAILURES="${FAILURES}\n--- FAIL: $test_name ---\n"
        FAILURES="${FAILURES}git output:\n$git_out\n"
        FAILURES="${FAILURES}zagi output:\n$zagi_out\n"
        echo -e "  ${RED}✗${NC} $test_name"
    fi
}

assert_exit_match() {
    local test_name="$1"
    shift
    local git_exit=0
    local zagi_exit=0

    git "$@" >/dev/null 2>&1 || git_exit=$?
    "$ZAGI" --compat "$@" >/dev/null 2>&1 || zagi_exit=$?

    if [ "$git_exit" = "$zagi_exit" ]; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}✓${NC} $test_name (exit=$git_exit)"
    else
        FAIL=$((FAIL + 1))
        FAILURES="${FAILURES}\n--- FAIL: $test_name ---\n"
        FAILURES="${FAILURES}git exit: $git_exit, zagi exit: $zagi_exit\n"
        echo -e "  ${RED}✗${NC} $test_name (git=$git_exit zagi=$zagi_exit)"
    fi
}

# ──────────────────────────────────────────────────────────────
echo "Setting up test repo..."
setup_repo
echo ""

# ──────────────────────────────────────────────────────────────
echo "status conformance:"

git_out=$(git status 2>&1)
zagi_out=$("$ZAGI" --compat status 2>&1)
assert_match "status (default)" "$git_out" "$zagi_out"

git_out=$(git status -s 2>&1)
zagi_out=$("$ZAGI" --compat status -s 2>&1)
assert_match "status -s (short)" "$git_out" "$zagi_out"

git_out=$(git status --porcelain 2>&1)
zagi_out=$("$ZAGI" --compat status --porcelain 2>&1)
assert_match "status --porcelain" "$git_out" "$zagi_out"

git_out=$(git status --porcelain=v2 2>&1)
zagi_out=$("$ZAGI" --compat status --porcelain=v2 2>&1)
assert_match "status --porcelain=v2" "$git_out" "$zagi_out"

git_out=$(git status -sb 2>&1)
zagi_out=$("$ZAGI" --compat status -sb 2>&1)
assert_match "status -sb (short+branch)" "$git_out" "$zagi_out"

# Path filtering
git_out=$(git status src/ 2>&1)
zagi_out=$("$ZAGI" --compat status src/ 2>&1)
assert_match "status src/ (path filter)" "$git_out" "$zagi_out"

echo ""

# ──────────────────────────────────────────────────────────────
echo "log conformance:"

git_out=$(git log --oneline -5 2>&1)
zagi_out=$("$ZAGI" --compat log --oneline -5 2>&1)
assert_match "log --oneline -5" "$git_out" "$zagi_out"

git_out=$(git log -3 2>&1)
zagi_out=$("$ZAGI" --compat log -3 2>&1)
assert_match "log -3" "$git_out" "$zagi_out"

git_out=$(git log --oneline --author="Test" 2>&1)
zagi_out=$("$ZAGI" --compat log --oneline --author="Test" 2>&1)
assert_match "log --oneline --author=Test" "$git_out" "$zagi_out"

git_out=$(git log --oneline --grep="Add" 2>&1)
zagi_out=$("$ZAGI" --compat log --oneline --grep="Add" 2>&1)
assert_match "log --oneline --grep=Add" "$git_out" "$zagi_out"

git_out=$(git log --format="%H" -3 2>&1)
zagi_out=$("$ZAGI" --compat log --format="%H" -3 2>&1)
assert_match "log --format=%H -3" "$git_out" "$zagi_out"

git_out=$(git log --format="%h %s" -3 2>&1)
zagi_out=$("$ZAGI" --compat log --format="%h %s" -3 2>&1)
assert_match "log --format='%h %s' -3" "$git_out" "$zagi_out"

git_out=$(git log --oneline -- src/ 2>&1)
zagi_out=$("$ZAGI" --compat log --oneline -- src/ 2>&1)
assert_match "log --oneline -- src/" "$git_out" "$zagi_out"

git_out=$(git log --stat -2 2>&1)
zagi_out=$("$ZAGI" --compat log --stat -2 2>&1)
assert_match "log --stat -2" "$git_out" "$zagi_out"

echo ""

# ──────────────────────────────────────────────────────────────
echo "diff conformance:"

git_out=$(git diff 2>&1)
zagi_out=$("$ZAGI" --compat diff 2>&1)
assert_match "diff (unstaged)" "$git_out" "$zagi_out"

git_out=$(git diff --staged 2>&1)
zagi_out=$("$ZAGI" --compat diff --staged 2>&1)
assert_match "diff --staged" "$git_out" "$zagi_out"

git_out=$(git diff --cached 2>&1)
zagi_out=$("$ZAGI" --compat diff --cached 2>&1)
assert_match "diff --cached" "$git_out" "$zagi_out"

git_out=$(git diff --stat 2>&1)
zagi_out=$("$ZAGI" --compat diff --stat 2>&1)
assert_match "diff --stat" "$git_out" "$zagi_out"

git_out=$(git diff --name-only 2>&1)
zagi_out=$("$ZAGI" --compat diff --name-only 2>&1)
assert_match "diff --name-only" "$git_out" "$zagi_out"

git_out=$(git diff --name-status 2>&1)
zagi_out=$("$ZAGI" --compat diff --name-status 2>&1)
assert_match "diff --name-status" "$git_out" "$zagi_out"

git_out=$(git diff HEAD~1..HEAD 2>&1)
zagi_out=$("$ZAGI" --compat diff HEAD~1..HEAD 2>&1)
assert_match "diff HEAD~1..HEAD" "$git_out" "$zagi_out"

git_out=$(git diff HEAD~2..HEAD --stat 2>&1)
zagi_out=$("$ZAGI" --compat diff HEAD~2..HEAD --stat 2>&1)
assert_match "diff HEAD~2..HEAD --stat" "$git_out" "$zagi_out"

git_out=$(git diff -- src/utils.ts 2>&1)
zagi_out=$("$ZAGI" --compat diff -- src/utils.ts 2>&1)
assert_match "diff -- src/utils.ts (path filter)" "$git_out" "$zagi_out"

git_out=$(git diff --shortstat 2>&1)
zagi_out=$("$ZAGI" --compat diff --shortstat 2>&1)
assert_match "diff --shortstat" "$git_out" "$zagi_out"

echo ""

# ──────────────────────────────────────────────────────────────
echo "add conformance:"

# Create a temp file and test add
echo 'test' > /tmp/zagi_add_test.txt
cp /tmp/zagi_add_test.txt add_test_git.txt
cp /tmp/zagi_add_test.txt add_test_zagi.txt

git_out=$(git add add_test_git.txt 2>&1)
zagi_out=$("$ZAGI" --compat add add_test_zagi.txt 2>&1)
assert_match "add single file (silent)" "$git_out" "$zagi_out"

# git add .
git_out=$(git add . 2>&1)
zagi_out=$("$ZAGI" --compat add . 2>&1)
assert_match "add . (all)" "$git_out" "$zagi_out"

echo ""

# ──────────────────────────────────────────────────────────────
echo "commit conformance:"

git add .
git_out=$(git commit -m "Test commit from conformance" 2>&1)
# Reset and replay with zagi
git reset --soft HEAD~1 >/dev/null 2>&1
git add .
zagi_out=$("$ZAGI" --compat commit -m "Test commit from conformance" 2>&1)
# Can't compare exactly (different hashes), but check format matches
# Just verify both succeed
if [ -n "$git_out" ] && [ -n "$zagi_out" ]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} commit -m (both produce output)"
else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} commit -m"
fi

echo ""

# ──────────────────────────────────────────────────────────────
echo "exit code conformance:"

assert_exit_match "status in repo" status
assert_exit_match "log in repo" log --oneline -1

# Error cases
cd /tmp
assert_exit_match "status outside repo" status
assert_exit_match "log outside repo" log --oneline -1
cd "$REPO_DIR"

echo ""

# ──────────────────────────────────────────────────────────────
echo "edge cases:"

# Empty diff
git stash -q 2>/dev/null || true
git_out=$(git diff 2>&1)
zagi_out=$("$ZAGI" --compat diff 2>&1)
assert_match "diff (no changes)" "$git_out" "$zagi_out"
git stash pop -q 2>/dev/null || true

# Status with no changes
git add . && git commit -q -m "temp" 2>/dev/null || true
git_out=$(git status 2>&1)
zagi_out=$("$ZAGI" --compat status 2>&1)
assert_match "status (clean)" "$git_out" "$zagi_out"

echo ""

# ──────────────────────────────────────────────────────────────
# JSON output validation
echo "json output validation:"

cd "$REPO_DIR"
# Make some changes for testing
echo '// json test' >> src/main.ts

json_out=$("$ZAGI" --json status 2>&1)
if echo "$json_out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} status --json is valid JSON"
else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} status --json is NOT valid JSON: $json_out"
fi

json_out=$("$ZAGI" --json log -n 3 2>&1)
if echo "$json_out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d,list)" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} log --json is valid JSON array"
else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} log --json is NOT valid JSON array: $json_out"
fi

json_out=$("$ZAGI" --json diff 2>&1)
if echo "$json_out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'files' in d" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} diff --json is valid JSON with files"
else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} diff --json is NOT valid JSON: $json_out"
fi

# Validate JSON status has expected fields
json_out=$("$ZAGI" --json status 2>&1)
if echo "$json_out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'branch' in d
assert 'clean' in d
assert 'staged' in d
assert 'modified' in d
assert 'untracked' in d
" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} status --json has all expected fields"
else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} status --json missing fields"
fi

# Validate log JSON has expected fields
json_out=$("$ZAGI" --json log -n 1 2>&1)
if echo "$json_out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert len(d) > 0
c = d[0]
assert 'hash' in c
assert 'date' in c
assert 'author' in c
assert 'subject' in c
" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} log --json entries have all expected fields"
else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} log --json entries missing fields"
fi

echo ""

# ──────────────────────────────────────────────────────────────
# Summary
echo "════════════════════════════════════════"
echo -e "  ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"
echo "════════════════════════════════════════"

if [ -n "$FAILURES" ]; then
    echo -e "\nFailure details:$FAILURES"
fi

exit $FAIL
