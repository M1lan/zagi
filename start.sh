#!/bin/bash
# Generic RALPH loop - run Claude Code over tasks from plan.md
#
# Usage: ./start.sh [options]
#   Options:
#     --plan <file>     Plan file to use (default: plan.md)
#     --model <model>   Model to use (default: claude-sonnet-4-20250514)
#     --delay <secs>    Delay between tasks (default: 2)
#     --once            Run only one task then exit
#     --dry-run         Show what would run without executing
#     --import          Import tasks from plan.md into git tasks
#     --help            Show this help

set -e

# Defaults
PLAN_FILE="${PLAN_FILE:-plan.md}"
MODEL="${MODEL:-claude-sonnet-4-20250514}"
DELAY="${DELAY:-2}"
ONCE=false
DRY_RUN=false
IMPORT=false

# Auto-detect git tasks command
# Use local build if available, otherwise try git tasks
if [ -x "./zig-out/bin/zagi" ]; then
  GIT_TASKS="./zig-out/bin/zagi tasks"
elif command -v zagi &> /dev/null; then
  GIT_TASKS="zagi tasks"
elif git tasks --help &> /dev/null 2>&1; then
  GIT_TASKS="git tasks"
else
  echo "error: zagi not found. Build with 'zig build' or install zagi."
  exit 1
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --plan)
      PLAN_FILE="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
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
    --import)
      IMPORT=true
      shift
      ;;
    --help|-h)
      sed -n '2,12p' "$0" | sed 's/^# //' | sed 's/^#//'
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

# Import tasks from plan.md if requested
if [ "$IMPORT" = true ]; then
  if [ ! -f "$PLAN_FILE" ]; then
    echo "error: plan file not found: $PLAN_FILE"
    exit 1
  fi

  echo "Importing tasks from $PLAN_FILE..."

  # Parse markdown checkboxes: - [ ] task content
  grep -E '^\s*- \[ \]' "$PLAN_FILE" | sed 's/^\s*- \[ \] //' | while read -r task; do
    if [ -n "$task" ]; then
      echo "  Adding: $task"
      $GIT_TASKS add "$task" 2>/dev/null || echo "    (skipped - may already exist)"
    fi
  done

  echo ""
  echo "Import complete. Run without --import to start the loop."
  exit 0
fi

echo "RALPH loop starting..."
echo "Model: $MODEL"
if [ "$DRY_RUN" = true ]; then
  echo "(dry-run mode)"
fi
echo ""

# Show current tasks
$GIT_TASKS list 2>/dev/null || echo "No tasks found. Use --import to import from $PLAN_FILE"
echo ""

while true; do
  # Get first ready task as JSON for reliable parsing
  READY_JSON=$($GIT_TASKS ready --json 2>/dev/null || echo "[]")

  # Parse first task from JSON array
  TASK_ID=$(echo "$READY_JSON" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')
  TASK_CONTENT=$(echo "$READY_JSON" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//;s/"//')

  if [ -z "$TASK_ID" ]; then
    echo ""
    echo "=== All tasks complete! ==="
    echo ""
    $GIT_TASKS pr 2>/dev/null || echo "No tasks to export."
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
4. Commit your changes with: git commit -m \"<message>\" --prompt \"$TASK_CONTENT\"
5. Mark the task done: git tasks done $TASK_ID
6. If you learn critical operational details, update AGENTS.md

Rules:
- NEVER git push (only commit)
- ONLY work on this one task
- Exit when done so the next task can start"

  if [ "$DRY_RUN" = true ]; then
    echo "Would execute:"
    echo "  claude --print --model $MODEL \"<prompt>\""
    echo ""
    echo "Prompt:"
    echo "$PROMPT" | sed 's/^/  /'
    echo ""
  else
    # Run Claude Code in headless mode
    export ZAGI_AGENT=claude-code
    claude --print --dangerously-skip-permissions --model "$MODEL" "$PROMPT"
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
