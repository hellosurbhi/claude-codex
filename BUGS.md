- WONTFIX(MEDIUM, 2026-10-27): 1. `commands/execute-codex.md:133-155` can silently drop MEDIUM and LOW findings on the no-CRITICAL/HIGH path because its delivery template has no field for them. 2. The execute and TDD eval suites contain no WARNING-path cases. `skills/claude-codex/evals/evals.json:29` also covers remaining MEDIUM/LOW findings only after APPROVED. 3. `README.md:35-36` says Claude fixes all findings while users decide MEDIUM/LOW findings. `README.md:127` calls WARNING outcomes approved. 4. Changed Markdown retains prohibited em dashes and Oxford commas, contrary to the repository copy mandate. | Reason: Findings 2 and 4 need edits to unnamed files (TDD eval suites, unspecified "changed Markdown") and the cited copy mandate does not exist in the repo, so the entry cannot be fixed whole.
- WONTFIX(HIGH, 2026-10-27): `skills/plan-codex/SKILL.md:51,61,76-87`: The CLI fallback provides no MCP `threadId`. A BLOCKED result or contested finding therefore reaches `mcp__codex__codex-reply` with no valid saved thread. Define a CLI follow-up path for the full audit loop. | Reason: The cited CLI fallback, rejected-findings gate, and "ANY finding" wording do not exist in this tree (the referenced lines belong to a different diff), so the findings are stale and not actionable.

## Medium priority (auto-fix pending)

### Codex (2026-10-28T14:10Z)
- [x] MEDIUM (fixed: execute-codex.md Step B3 now triages MEDIUM/LOW and the delivery template has a "Remaining MEDIUM/LOW issues" field): BUGS.md:1 marks the entire bundled entry WONTFIX because some findings lack context, discarding an independently verifiable bug: commands/execute-codex.md:133 advances to delivery with MEDIUM/LOW findings, but lines 143 onward provide no field to report them. Split the entry and retain this actionable issue in the overnight queue with a remediation plan.


## Critical (round cap reached, push allowed, fix before merge)

### Codex (2026-10-28T14:44Z)
- [ ] CRITICAL (not fixable from files: this is a commit-message claim, and history cannot be rewritten here; `safe_pr_create` is not defined anywhere in this repo, so treat the "Verified" line in 69c0a06 as unverified; the commit only touches `.coderabbit.yaml`, so no code depends on it; reviewer must confirm or reword on merge): FABRICATED-REFERENCE: Commit 69c0a06 still claims verification through `safe_pr_create`, but `git grep -n safe_pr_create HEAD` returns no matches. Commit a6c73c0 neither corrects that claim nor supplies a verifiable reference. The prior critical finding remains unresolved.

