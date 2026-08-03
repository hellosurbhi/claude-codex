
## Medium priority (auto-fix pending)

### Codex (2026-08-03T02:06Z)
- [ ] MEDIUM: `skills/plan-codex/SKILL.md:51` gives `codex exec --sandbox read-only` as the mandatory fallback without supplying a prompt or analyzer instructions. The CLI reads stdin when no prompt is supplied, so this retry can hang or return output that does not follow the required verdict grammar.
  - New copy throughout the diff uses em dashes despite the repository copy-voice mandate prohibiting them.

## High priority (from push reviews, fix first)

### Codex (2026-08-03T02:17Z)
- [ ] HIGH: `commands/execute-codex.md:134` and `commands/tdd-execute-codex.md:233` still route CRITICAL/HIGH findings on the 3+ task path through re-review, contradicting their HIGH-only branches and the BLOCKED-only policy. Lines 138 and 237 also retain the approval-based iteration stop.
- [ ] HIGH: `skills/plan-codex/evals/evals.json:7` still expects iteration until APPROVED. `skills/plan-codex/SKILL.md:3` and `commands/plan-codex.md:2` repeat that obsolete contract even though WARNING now exits without approval.
- [ ] HIGH: `skills/tdd-execute-codex/SKILL.md:301` and `commands/tdd-execute-codex.md:235` proceed after fixing HIGHs without collecting and routing remaining MEDIUM/LOW findings as the no-HIGH branch does.

### Codex (2026-08-03T02:17Z)
- [ ] MEDIUM: New copy still violates the repository’s em-dash prohibition, including `commands/claude-codex.md:84`, `commands/tdd-claude-codex.md:163`, `skills/claude-codex/SKILL.md:96` and `skills/tdd-claude-codex/SKILL.md:196`.

