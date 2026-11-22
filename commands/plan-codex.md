---
description: "Claude plans with Opus, Codex re-audits until no findings remain"
argument-hint: "<task description>"
model: claude-opus-4-6
allowed-tools: ["AskUserQuestion", "Task", "Read", "Glob", "Grep", "Write", "Bash"]
---

> **Deprecated**: This command has been converted to a skill (`/plan-codex`).
> The skill version is recommended for new usage and supports eval-based testing.
> This command is retained for backward compatibility (model pinning, tool restrictions).

# Plan-Codex — Claude Plans, Codex Audits

$ARGUMENTS

---

## Core Protocols

- **Code Sovereignty**: Codex has zero filesystem write access during planning — all file operations by Claude only
- **Stop-Loss**: Do not proceed to next phase until current phase output is validated
- **Language**: Use English when calling tools/models; communicate with user in their language
- **Planning Only**: Never modify production code during this command

---

## Execution Workflow

### Phase 1: Plan Creation

Launch a Task agent (subagent_type: "Plan") with the task description.
The Plan agent will research the codebase and return a structured implementation plan.

If requirements are ambiguous before launching the planner, ask clarifying questions first.

Save the returned plan to `.claude/plan/<feature-name>.md`.

### Phase 2: Codex Audit Loop (no iteration cap, no severity floor)

Read `~/.claude/skills/plan-codex/codex-analyzer-role.md` and pass as `--role <file>`. (That file defines the `VERDICT: APPROVED | WARNING | BLOCKED` grammar the parse step below branches on; `prompts/codex/analyzer.md` also exists but predates the verdict contract and defines no grammar, so it must not be used here.)

**MANDATORY Codex availability check**: run `test -x ~/.claude/config/scripts/codex-call.sh && codex --version`. If either fails, **stop and tell the user**: "Codex CLI or codex-call.sh is not available. This command requires Codex." Do NOT skip or bypass this phase. (`codex mcp-server` was removed in Codex CLI 0.154.0, so there are no `mcp__codex__*` tools; every call goes through `codex-call.sh`, which wraps `codex exec`.)

**MANDATORY mid-call failure handling**: a Codex call that errors, times out, exits without a final message (`codex-call.sh` exits non-zero with "UNREVIEWED") or replies without exactly one valid `VERDICT:` line is NOT an approval and NOT a skippable step. Read the error, fix the cause, then retry or switch to another independent reviewer (a fresh Codex thread without `--resume`, or tier S, `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Fallback input paragraph: audit instructions, carried and contested findings, then the current plan text) on the actual current plan file), and validate every answer against the same VERDICT grammar. Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A finding you contest is settled only by an authorized reviewer's concession or verification, recorded in writing with its evidence (a Codex thread when one is available; when a fallback reviewer is the active reviewer, any reviewer authorized for the repo, tier S included, with no Codex thread required). Stop only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker. When that blocker is anything other than a named usage limit: **stop and tell the user**: "Codex audit incomplete: <blocker>. The plan is UNREVIEWED." Never proceed to Phase 3 or to implementation on a dead audit in that case; an unreviewed plan must be labeled as such, out loud, every time. (Added 2026-07-28 after an xhigh audit was silently killed by a 1800s MCP idle timeout and work continued without it. One-retry cutoff removed 2026-11-12.)

**Fallback input (tier S)**: the fallback reviewer sees only the one file you hand it, so every tier S plan audit uses ONE context file, built exactly as below and never the bare plan. It carries what the Codex call carried: the audit instructions you sent to Codex, every carried finding (raised in an earlier round and still open) and every contested finding with your reasoning, then the actual current plan text. Rebuild the file for every round so it holds the CURRENT plan and the current findings.

```
CTX="$(mktemp)"
cat > "$CTX" <<'EOF'
AUDIT INSTRUCTIONS:
<the audit instructions sent to Codex>

OPEN FINDINGS:
<every carried and contested finding with your reasoning, or the word none>

PLAN:
EOF
cat .claude/plan/<feature-name>.md >> "$CTX"
~/.claude/config/scripts/reviewer.sh S "$CTX" <out-file>
```


**Usage limit (never block on quota, owner mandate 2026-08-26: "never block cause codex"; the 2026-08-26 skip carve-out is removed)**: when Codex dies with a quota or usage-limit error (the tool names its own reset time, e.g. "usage limit... try again at <time>"), the audit is NOT skipped and the plan is NOT delivered unreviewed. Switch reviewers in this order, validating every answer against the VERDICT grammar: (1) a fresh Codex thread without `--resume`; (2) `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Fallback input paragraph: audit instructions, carried and contested findings, then the current plan text) run with the actual plan file (`.claude/plan/<feature-name>.md`, the current revision, not a summary of it) as its last section, which reviews the real plan text with Sonnet and uses no Codex quota. Treat that verdict exactly like a Codex verdict: findings at any severity are evaluated, fixed in the plan and re-reviewed (every round reviews the CURRENT plan text), with no attempt cap, and retry and switch again whenever a call dies or returns no valid verdict. The plan stays pending, with no Phase 3, until the current revision gets a clean verdict (exactly the `VERDICT: APPROVED` line alone, as reviewer.sh returns it, or that line plus four `none` severity lines, as Codex returns it, and no other text). A usage limit is transient and never a blocker; stop only on a named non-transient blocker such as missing credentials, and then say so out loud ("Plan audit incomplete: <blocker>. The plan is UNREVIEWED."). A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A reviewer that cannot read the real current plan file does not count.

**Call `codex-call.sh`** (iteration 1):
- prompt: "Read the plan file at `.claude/plan/<feature-name>.md` and audit it for correctness, completeness, security and edge cases. Return the structured verdict (VERDICT: APPROVED | WARNING | BLOCKED) with severity-prefixed findings per your instructions."
- flag: `--sandbox read-only`
- append to prompt: (`--role ~/.claude/skills/plan-codex/codex-analyzer-role.md`) "\nBe concise. Output result only, no reasoning process."

Save the returned `THREAD_ID`.

**Validate the response**: never accept a verdict on a substring match. The first non-blank line must be exactly `VERDICT: APPROVED`, `VERDICT: WARNING` or `VERDICT: BLOCKED`. A second `VERDICT:` line is no verdict, and "NOT APPROVED", "APPROVED once you fix ..." or any other qualified verdict word inside other text is no verdict. The severity lines (`CRITICAL:`, `HIGH:`, `MEDIUM:`, `LOW:`) are optional: a severity header with empty text takes the next non-blank line that is not a severity header as its text, a header with no such line (end of the output, or another severity header next) makes the whole output no verdict and never a clean round, and the placeholder text `none` or `n/a` (any case, optional trailing period) is ignored, not a finding. Any real finding at any severity means findings, whatever the verdict word: `VERDICT: APPROVED` beside a real CRITICAL or HIGH finding is findings, never a clean round, so evaluate, fix and re-review it, and never drop it. `VERDICT: APPROVED` with no real finding (the bare line, or the line plus only placeholder severity lines) is clean. Empty output, or anything else that does not parse, is no verdict: treat the call as a failed review and re-ask the same reviewer (the same Codex thread through the wrapper, or the active fallback reviewer) for one unambiguous verdict.

**Parse the exact `VERDICT:` line** (line-anchored; exactly one must be present). The word APPROVED appearing inside prose or a finding is NOT approval. A response with no verdict line, multiple verdict lines or a value other than APPROVED, WARNING or BLOCKED is malformed, which is a failed call: handle it with the mid-call failure rules above (fix the cause and retry or switch reviewer until a valid verdict arrives). The same grammar applies to every reviewer, the reviewer.sh fallback included (see Validate the response above).
**Critical evaluation gate** (before acting on ANY finding): assess whether it is technically accurate against the actual codebase, whether the reviewer had full context for intentional decisions and whether it improves the plan or is a preference/false positive. Contest doubtful findings via `codex-call.sh --resume <THREAD_ID>` with specific reasoning; a finding is dropped only when the reviewer explicitly concedes it in a written reply (the active reviewer is the Codex thread or, when a fallback reviewer is active, any reviewer authorized for the repo, tier S included; it must record its evidence and its concession or verification in writing, and no Codex thread is required); a reviewer that maintains it, or a reply with no clear concession, leaves it accepted and it gets fixed, and your own disagreement never drops a finding. Only findings that survive this gate are "accepted" below.
- Any accepted finding at any severity (BLOCKED, WARNING or APPROVED with MEDIUM/LOW findings) → fix every accepted finding, revise the plan, update `.claude/plan/<feature-name>.md`, re-audit
- A round with no findings, or whose every finding was dropped through the gate's discussion path → go to Phase 3

**Call `codex-call.sh --resume <THREAD_ID>`** (iteration 2 onward):
- THREAD_ID: {saved THREAD_ID}
- prompt: "The plan has been revised to address your feedback. Re-read the plan file at `.claude/plan/<feature-name>.md` and audit it again for correctness, completeness, security and edge cases. Return the structured verdict (VERDICT: APPROVED | WARNING | BLOCKED) with severity-prefixed findings per your instructions."

There is no iteration cap and no stop to ask the user: keep revising and re-auditing until a round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). This matches `skills/plan-codex/SKILL.md`. Every re-review or re-audit round goes to the reviewer that is active: while a fallback reviewer is active (see the usage-limit paragraph), send the revised plan or diff to that same fallback reviewer, never `--resume` a Codex thread that cannot answer and return to `--resume` only once Codex answers again.

### Phase 3: Deliver

End the final report with exactly one machine-readable line, `AUDIT-STATUS: APPROVED reviewer=<name>` when the last review of the final state was clean, or `AUDIT-STATUS: UNREVIEWED reviewer=<name or none>` when it was not; no other line may start with `AUDIT-STATUS:`, and this line is the last non-blank line of the report.

Present the final plan and output:

---
**Plan saved to `.claude/plan/<feature-name>.md`**

Review the plan above. When ready, start a new session and run:
```
/execute-codex .claude/plan/<feature-name>.md
```
---

**Stop here. Do not auto-execute.**
