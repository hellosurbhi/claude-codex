## Medium priority (auto-fix pending)

### Codex (2026-08-03T02:38Z)
- [ ] MEDIUM: `skills/plan-codex/SKILL.md:51` invokes `codex exec --sandbox read-only` without a prompt or analyzer instructions. The CLI reads stdin when the prompt is omitted, so the mandatory fallback can wait, fail or produce an invalid audit.
  - `commands/claude-codex.md:84`, `commands/plan-codex.md:52` and both TDD command audit paths refer to accepted findings without defining the critical-evaluation process present in their skill counterparts.
  - The execute and TDD eval suites add no WARNING-path cases, leaving the changed no-re-review behavior unenforced.
  - Added copy uses prohibited em dashes and Oxford commas throughout the changed Markdown.
