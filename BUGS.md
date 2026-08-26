- WONTFIX(HIGH, 2026-08-19): `skills/plan-codex/SKILL.md:51,61,76-87`: The CLI fallback provides no MCP `threadId`. A BLOCKED result or contested finding therefore reaches `mcp__codex__codex-reply` with no valid saved thread. Define a CLI follow-up path for the full audit loop. | Reason: False positive — no CLI fallback exists in this tree (SKILL.md:49 mandates stopping when Codex MCP is absent) and `commands/claude-codex.md` has no "ANY finding" evaluation gate to contradict or over-broaden, so the entry's head finding and two of its three continuations describe text that is not present.
- WONTFIX(HIGH, 2026-08-19): 1. `skills/plan-codex/SKILL.md:51,61,76-87` provides no MCP `threadId` after a successful CLI fallback. BLOCKED results and contested findings cannot continue through `mcp__codex__codex-reply`. | Reason: Findings 1-3 are false positives (no CLI fallback and no "ANY finding" gate exist in this tree), so the entry cannot be fixed whole, though its real parts — findings 4 (verdict/severity consistency) and 5 (explicit fail-closed after the iteration cap in all four cited locations) — were fixed.

## Critical priority (from push reviews, fix first)

### Codex (2026-08-26, pending verdict `reviews/.verdicts/pending-f3b724efe75bac5d`)
- [x] CRITICAL: FABRICATED-REFERENCE `reviews/retry-queue.md:1` names `retry-skipped-reviews.sh`, but that script does not exist anywhere in the repository or its declared dependencies. | Fixed 2026-08-26: the header no longer names a drainer script. It now states that there is no automated drainer and documents the manual drain procedure (re-run the review for each queued commit/diff_sha, then delete the row and its matching `REVIEW-OUTAGE-*.md`). The two 2026-08-26 outages that claimed to be queued but had no row were also added, so every `REVIEW-OUTAGE-*.md` claim now matches a queue entry.


## High priority (from push reviews, fix first)

### Codex (2026-08-26T13:33Z)
- [x] HIGH: INCOMPLETE-FIX `README.md:213` claims every loop fails closed, but the Route A paths still proceed to delivery after capped re-reviews without requiring approval: `commands/execute-codex.md:72-73`, `skills/execute-codex/SKILL.md:87-88`, `commands/tdd-execute-codex.md:149-154` and `skills/tdd-execute-codex/SKILL.md:181-186`. | Fixed 2026-08-26: an explicit fail-closed step was added to all four Route A review loops (stop, report the unresolved findings, ask the user; do not proceed to delivery without an explicit instruction), matching the wording already used on the Route B and Codex-review loops. `README.md:213` was also corrected: it previously claimed "max 3 iterations on all loops" when the test audits and the Route A code review cap at 2 rounds, so the note now states the per-loop caps.


## Medium priority (auto-fix pending)

### Codex (2026-08-26T13:33Z)
- [x] MEDIUM: COPY-VOICE Newly added prose repeatedly uses prohibited em dash characters, including `README.md:213`, `commands/claude-codex.md:88` and `skills/codex-mcp/SKILL.md:42-45`. | Fixed 2026-08-26: em dashes removed from the prose added on this branch (`README.md:213`, `commands/claude-codex.md:88`, `skills/codex-mcp/SKILL.md:42,45`, `skills/codex-mcp/reference.md:60-74`) and from the fail-closed steps added for the HIGH item above. Pre-existing em dashes elsewhere in the repository were left alone, since the finding is scoped to newly added prose.

