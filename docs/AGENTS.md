<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-16 | Updated: 2026-03-16 -->

# docs

## Purpose
Supplementary documentation for zagi: architecture decisions, feature specs, motivation, and setup guides. Intended for contributors and advanced users; the quick-start is in the root README.

## Key Files

| File | Description |
|------|-------------|
| `architecture.md` | System architecture overview |
| `features.md` | Feature list and status |
| `motivation.md` | Why zagi exists — design philosophy and goals |
| `next-gen-vcs.md` | Exploration of next-generation VCS ideas |
| `prd-git-tasks.md` | Product requirements document for the git tasks feature |
| `setup.md` | Installation and configuration guide; executor environment variables (`ZAGI_AGENT`, `ZAGI_AGENT_CMD`) |
| `style.md` | Output style guidelines — compact, no decorations, agent-optimised |

## For AI Agents

### Working In This Directory
- Update `setup.md` when new environment variables or installation steps are added.
- Update `features.md` when new commands are implemented or existing ones change behaviour.
- Do not add task-specific or session-specific notes here — this is reference documentation.

### Common Patterns
- All docs are Markdown.
- Code examples use `bash` fenced blocks.
- No emojis (project-wide style rule).

## Dependencies
None — pure documentation.

<!-- MANUAL: -->
