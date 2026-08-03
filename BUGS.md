## Medium priority (auto-fix pending)

### Codex (2026-08-03T02:38Z)
- [ ] MEDIUM: `skills/plan-codex/SKILL.md:51` invokes `codex exec --sandbox read-only` without a prompt or analyzer instructions. The CLI reads stdin when the prompt is omitted, so the mandatory fallback can wait, fail or produce an invalid audit.
  - `commands/claude-codex.md:84`, `commands/plan-codex.md:52` and both TDD command audit paths refer to accepted findings without defining the critical-evaluation process present in their skill counterparts.
  - The execute and TDD eval suites add no WARNING-path cases, leaving the changed no-re-review behavior unenforced.
  - Added copy uses prohibited em dashes and Oxford commas throughout the changed Markdown.
### Codex (2026-08-03T03:20Z)
- [ ] MEDIUM: `commands/execute-codex.md:133` can still drop MEDIUM/LOW findings on the no-CRITICAL/HIGH path. Line 136 preserves them only for HIGH-only reviews and the Phase 3 template has no field for them.
  - `README.md:35` says Claude fixes all “findings,” conflicting with line 36 where users decide on MEDIUM/LOW issues. `README.md:117` still calls the result “approved” although WARNING now exits without approval.
  - `README.md:149` and `skills/plan-codex/SKILL.md:3` retain prohibited em dashes. The skill description also retains an Oxford comma.

### Codex (2026-08-03T04:15Z)
- [ ] MEDIUM: `skills/plan-codex/SKILL.md:51` invokes `codex exec` without a prompt, plan path or analyzer instructions. Local CLI help confirms an omitted prompt reads stdin, so the mandatory fallback cannot reliably perform the audit.
  2. `commands/claude-codex.md:84`, `commands/plan-codex.md:52` and both TDD command audit paths refer to “accepted” findings without defining the critical-evaluation process.
  3. `commands/execute-codex.md:133-155` can silently drop MEDIUM and LOW findings on the no-CRITICAL/HIGH path because its delivery template has no field for them.
  4. The execute and TDD eval suites contain no WARNING-path cases. `skills/claude-codex/evals/evals.json:29` also covers remaining MEDIUM/LOW findings only after APPROVED.
  5. `README.md:35-36` says Claude fixes all findings while users decide MEDIUM/LOW findings. `README.md:127` calls WARNING outcomes approved.
  6. Changed Markdown retains prohibited em dashes and Oxford commas, contrary to the repository copy mandate.

