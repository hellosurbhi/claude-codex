## Medium priority (auto-fix pending)

### Codex (2026-08-03T04:15Z)
- [ ] MEDIUM: 1. `commands/execute-codex.md:133-155` can silently drop MEDIUM and LOW findings on the no-CRITICAL/HIGH path because its delivery template has no field for them. 2. The execute and TDD eval suites contain no WARNING-path cases. `skills/claude-codex/evals/evals.json:29` also covers remaining MEDIUM/LOW findings only after APPROVED. 3. `README.md:35-36` says Claude fixes all findings while users decide MEDIUM/LOW findings. `README.md:127` calls WARNING outcomes approved. 4. Changed Markdown retains prohibited em dashes and Oxford commas, contrary to the repository copy mandate.


## High priority (from push reviews, fix first)

### Codex (2026-08-03T04:51Z)
- [ ] HIGH: `commands/plan-codex.md:50-53` validates the verdict line but not its consistency with severity findings. `VERDICT: APPROVED` accompanied by `CRITICAL:` or `HIGH:` still reaches Phase 3 and silently drops those findings. Treat contradictory severity and verdict combinations as malformed.

### Codex (2026-08-03T04:51Z)
- [ ] MEDIUM: `commands/plan-codex.md:48-55` does not specify whether a malformed retry uses the saved thread or starts a new one. A new call can return a replacement `threadId`, yet later re-audits may use the original thread.
- [ ] MEDIUM: `commands/plan-codex.md:50` adds the Oxford comma in “no verdict line, multiple verdict lines, or a value,” violating the repository copy mandate.

### Codex (2026-08-03T05:50Z)
- [ ] HIGH: `skills/plan-codex/SKILL.md:51,61,76-87`: The CLI fallback provides no MCP `threadId`. A BLOCKED result or contested finding therefore reaches `mcp__codex__codex-reply` with no valid saved thread. Define a CLI follow-up path for the full audit loop.
  - `commands/plan-codex.md:50-54`: Verdict validation ignores severity consistency. `VERDICT: APPROVED` with CRITICAL or HIGH findings still reaches Phase 3 and drops them.
  - `commands/claude-codex.md:82,91-93` and `commands/plan-codex.md:51,54`: The new gate says rejected findings are not accepted, but later instructions require fixing every CRITICAL and HIGH finding. This defeats the gate on BLOCKED reviews.
  - `SCOPE-CREEP`: `commands/claude-codex.md:82` expands the counterpart’s CRITICAL/HIGH evaluation gate to “ANY finding.” This can discard MEDIUM/LOW findings before the user decision in Step R3 without support in the stated intent.

### Codex (2026-08-03T05:50Z)
- [ ] MEDIUM: `commands/plan-codex.md:48-58`: The malformed-response retry does not specify whether it reuses the thread or replaces the saved `threadId`.
  - `UNASKED-CHANGE`: More than 2,000 lines of derived state under `reviews/.cache`, `reviews/.routed` and `reviews/.verdicts` were committed without a trace to the stated intent. No repository code references these artifacts.
  - `ENHANCEMENTS.md:5,8`: Both new entries are stale. Current `BUGS.md:12` is a heading, while current `commands/plan-codex.md:40` already says the old analyzer exists.
  - Changed Markdown introduces prohibited em dashes and Oxford commas, including `commands/claude-codex.md:82,87`, `commands/plan-codex.md:51` and `skills/plan-codex/SKILL.md:51`.

