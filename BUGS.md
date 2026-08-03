## Medium priority (auto-fix pending)

### Codex (2026-08-03T04:15Z)
- [ ] MEDIUM: `skills/plan-codex/SKILL.md:51` invokes `codex exec` without a prompt, plan path or analyzer instructions. Local CLI help confirms an omitted prompt reads stdin, so the mandatory fallback cannot reliably perform the audit.
  2. `commands/claude-codex.md:84`, `commands/plan-codex.md:52` and both TDD command audit paths refer to “accepted” findings without defining the critical-evaluation process.
  3. `commands/execute-codex.md:133-155` can silently drop MEDIUM and LOW findings on the no-CRITICAL/HIGH path because its delivery template has no field for them.
  4. The execute and TDD eval suites contain no WARNING-path cases. `skills/claude-codex/evals/evals.json:29` also covers remaining MEDIUM/LOW findings only after APPROVED.
  5. `README.md:35-36` says Claude fixes all findings while users decide MEDIUM/LOW findings. `README.md:127` calls WARNING outcomes approved.
  6. Changed Markdown retains prohibited em dashes and Oxford commas, contrary to the repository copy mandate.

