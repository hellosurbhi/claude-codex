# Bug backlog

Findings from the automated MEDIUM priority triage passes. Resolved entries stay
here as a record of what was fixed or dismissed and why. The pending queue below
is empty when every triaged finding has been closed out.

## Resolved (2026-08-29)

- FIXED(MEDIUM, 2026-08-29): the third WONTFIX entry below asserted that "BUGS.md and ENHANCEMENTS.md do not exist in this repository", but BUGS.md does exist. | Fix: the entry now names only ENHANCEMENTS.md as missing and records that BUGS.md was created by this same triage pass in commit fd5938b. The rest of that entry was re-verified; the one clause that did not survive re-verification is corrected in the FALSE-RESOLUTION entry below.
- FIXED(MEDIUM, 2026-08-29): FALSE-RESOLUTION: the second and third WONTFIX entries below claimed that the cited lines contain "no em dashes or Oxford commas". That clause is false. `commands/plan-codex.md:56`, inside the cited `50-58` range, reads "correctness, completeness, security, and edge cases", and em dashes appear at `commands/plan-codex.md:12` and `:20`, `commands/claude-codex.md:12`, and `skills/plan-codex/SKILL.md:6`. | Fix: the false clause has been struck from both entries. Their WONTFIX verdicts stand on the remaining, re-verified grounds: `commands/plan-codex.md` has no malformed-response retry path, and its only retry already reuses the saved thread (`- threadId: {saved threadId}` at line 55). No source file was changed, because the "repository copy mandate" the original findings invoke does not exist: the repo has no CLAUDE.md, style guide, or contributing doc, and em dashes are used deliberately throughout README.md and the shipped command and skill docs. The punctuation at `commands/plan-codex.md:56` is therefore house style, not a defect.
- WONTFIX(MEDIUM, 2026-08-29): `commands/plan-codex.md:50` adds the Oxford comma in “no verdict line, multiple verdict lines, or a value,” violating the repository copy mandate. | Reason: False positive: the quoted string does not exist anywhere in the repository (grep for "verdict line" returns no matches), and commands/plan-codex.md:50 is "**Parse response**:".
- WONTFIX(MEDIUM, 2026-08-29): `commands/plan-codex.md:48-58`: The malformed-response retry does not specify whether it reuses the thread or replaces the saved `threadId`. | Reason: Stale/false positive: commands/plan-codex.md has no malformed-response retry (its only retry already specifies `threadId: {saved threadId}` at line 55), and the continuation findings reference artifacts that do not exist here (no reviews/.cache, no ENHANCEMENTS.md).
- WONTFIX(MEDIUM, 2026-08-29): 1. `commands/plan-codex.md:50-58` does not define whether a malformed retry reuses the saved thread or creates and saves a replacement `threadId`. | Reason: Stale/false positive: no malformed-retry path exists in commands/plan-codex.md (line 55 already reuses the saved threadId), and ENHANCEMENTS.md does not exist in this repository (BUGS.md does exist: it was created by this same triage pass).

## Medium priority (auto-fix pending)

_Empty. Every triaged finding is recorded under Resolved above._
