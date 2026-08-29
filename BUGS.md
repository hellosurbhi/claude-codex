# Bug backlog

Findings from the automated MEDIUM priority triage passes. Resolved entries stay
here as a record of what was fixed or dismissed and why. The pending queue below
is empty when every triaged finding has been closed out.

## Resolved (2026-08-29)

- FIXED(MEDIUM, 2026-08-29): the third WONTFIX entry below asserted that "BUGS.md and ENHANCEMENTS.md do not exist in this repository", but BUGS.md does exist. | Fix: the entry now names only ENHANCEMENTS.md as missing and records that BUGS.md was created by this same triage pass in commit fd5938b. The rest of that entry was re-verified and still holds.
- WONTFIX(MEDIUM, 2026-08-29): `commands/plan-codex.md:50` adds the Oxford comma in “no verdict line, multiple verdict lines, or a value,” violating the repository copy mandate. | Reason: False positive: the quoted string does not exist anywhere in the repository (grep for "verdict line" returns no matches), and commands/plan-codex.md:50 is "**Parse response**:".
- WONTFIX(MEDIUM, 2026-08-29): `commands/plan-codex.md:48-58`: The malformed-response retry does not specify whether it reuses the thread or replaces the saved `threadId`. | Reason: Stale/false positive: commands/plan-codex.md has no malformed-response retry (its only retry already specifies `threadId: {saved threadId}` at line 55), and the continuation findings reference artifacts that do not exist here (no reviews/.cache, no ENHANCEMENTS.md) plus em dashes/Oxford commas absent from the cited lines.
- WONTFIX(MEDIUM, 2026-08-29): 1. `commands/plan-codex.md:50-58` does not define whether a malformed retry reuses the saved thread or creates and saves a replacement `threadId`. | Reason: Stale/false positive: no malformed-retry path exists in commands/plan-codex.md (line 55 already reuses the saved threadId), ENHANCEMENTS.md does not exist in this repository (BUGS.md does exist: it was created by this same triage pass), and the cited lines in skills/plan-codex/SKILL.md, commands/plan-codex.md and commands/claude-codex.md contain no em dashes or Oxford commas.

## Medium priority (auto-fix pending)

_Empty. Every triaged finding is recorded under Resolved above._
