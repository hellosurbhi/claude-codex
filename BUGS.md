
## Medium priority (auto-fix pending)

### Codex (2026-10-28T13:08Z)
- [x] MEDIUM: commands/plan-codex.md:53 accepts APPROVED responses containing MEDIUM/LOW findings and proceeds directly to delivery without addressing or queueing them. Add an explicit step to resolve in-scope findings and record beyond-scope findings in the backlog before Phase 3 so accepted findings are not silently lost.

### Codex (2026-10-28T14:09Z)
- [x] MEDIUM: `commands/plan-codex.md:53` records beyond-scope findings only inside the plan with a one-line reason. This does not satisfy the required overnight backlog deferral with a full plan. Add a `BUGS.md` or `ENHANCEMENTS.md` entry with actionable follow-up details and link it from the plan before delivery.

