# Plan: Implement git tasks

## Tasks

- [x] Create src/cmds/tasks.zig with basic structure and help text
- [x] Implement git ref storage helpers (read/write refs/tasks/<branch>)
- [x] Implement `git tasks add <content>` - create task with flat ID
- [x] Implement `git tasks list` - list all tasks from ref
- [x] Implement `git tasks show <id>` - show task details
- [x] Implement `git tasks done <id>` - mark task complete
- [x] Implement `git tasks ready` - list pending tasks (no blockers)
- [x] Add --after flag to `git tasks add` for dependencies
- [x] Implement `git tasks pr` - export markdown for PR description
- [x] Add --json flag to all commands
- [x] Block edit/delete when ZAGI_AGENT is set
- [x] Add routing in main.zig for tasks command
- [x] Write integration tests in test/src/tasks.test.ts
