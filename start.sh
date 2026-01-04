#!/bin/bash
# RALPH loop - run Claude over zagi tasks
#
# Usage: ./start.sh [options]
#   Options:
#     --delay <secs>    Delay between tasks (default: 2)
#     --once            Run only one task then exit
#     --dry-run         Show what would run without executing
#     --help            Show this help

set -e

# Defaults
DELAY="${DELAY:-2}"
ONCE=false
DRY_RUN=false

# Auto-detect git tasks command
if [ -x "./zig-out/bin/zagi" ]; then
  ZAGI="./zig-out/bin/zagi"
else
  echo "error: ./zig-out/bin/zagi not found. Build with 'zig build' first."
  exit 1
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --delay)
      DELAY="$2"
      shift 2
      ;;
    --once)
      ONCE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      sed -n '2,10p' "$0" | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "error: not a git repository"
  exit 1
fi

echo "RALPH loop starting..."
if [ "$DRY_RUN" = true ]; then
  echo "(dry-run mode)"
fi
echo ""

# Show current tasks
$ZAGI tasks list 2>/dev/null || echo "No tasks found."
echo ""

while true; do
  # Get all tasks as JSON and find first pending
  TASKS_JSON=$($ZAGI tasks list --json 2>/dev/null || echo '{"tasks":[]}')

  # Extract first pending task using basic parsing
  # Look for pending tasks in the JSON
  TASK_LINE=$(echo "$TASKS_JSON" | tr ',' '\n' | grep -A5 '"status":"pending"' | head -6)

  if [ -z "$TASK_LINE" ]; then
    echo ""
    echo "=== All tasks complete! ==="
    exit 0
  fi

  # Extract task ID and content
  TASK_ID=$(echo "$TASKS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('tasks', []):
    if t.get('status') == 'pending':
        print(t['id'])
        break
" 2>/dev/null || echo "")

  TASK_CONTENT=$(echo "$TASKS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('tasks', []):
    if t.get('status') == 'pending':
        print(t['content'])
        break
" 2>/dev/null || echo "")

  if [ -z "$TASK_ID" ]; then
    echo ""
    echo "=== All tasks complete! ==="
    exit 0
  fi

  echo "=== Working on $TASK_ID ==="
  echo "$TASK_CONTENT"
  echo ""

  # Build the prompt
  PROMPT="You are working on: $TASK_ID

Task: $TASK_CONTENT

Instructions:
1. Read AGENTS.md for project context and build instructions
2. Complete this ONE task only
3. Verify your work (run tests, check build)
4. Commit your changes with: git commit -m \"<message>\"
5. Mark the task done: $ZAGI tasks done $TASK_ID
6. If you learn critical operational details, update AGENTS.md

Rules:
- NEVER git push (only commit)
- ONLY work on this one task
- Exit when done so the next task can start"

  if [ "$DRY_RUN" = true ]; then
    echo "Would execute:"
    echo "  claude -p \"<prompt>\""
    echo ""
    echo "Prompt preview:"
    echo "$PROMPT" | head -10
    echo "..."
    echo ""
  else
    # Run Claude in headless mode
    export ZAGI_AGENT=claude
    claude -p "$PROMPT"
  fi

  echo ""
  echo "=== Task iteration complete ==="
  echo ""

  if [ "$ONCE" = true ]; then
    echo "Exiting after one task (--once flag)"
    exit 0
  fi

  if [ "$DRY_RUN" = false ]; then
    sleep "$DELAY"
  fi
done
