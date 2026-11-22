# Codex Reference: Detailed Patterns (codex-call.sh)

All calls run through `~/.claude/config/scripts/codex-call.sh` with Bash. The removed `codex mcp-server` tools are not used anywhere.

## Starting a Review Session

```bash
~/.claude/config/scripts/codex-call.sh --sandbox read-only --cd "$PWD" \
  --role ~/.claude/skills/plan-codex/codex-analyzer-role.md \
  "Review the plan at .claude/plan/<feature>.md for correctness, completeness,
security and edge cases. Return exactly one line VERDICT: APPROVED | WARNING | BLOCKED,
then severity-prefixed findings (CRITICAL, HIGH, MEDIUM, LOW), omitting any severity with no findings.
Be concise. Output result only, no reasoning process."
```

Save the `THREAD_ID:` value from the first output line.

## Starting an Implementation Session

```bash
~/.claude/config/scripts/codex-call.sh --sandbox workspace-write --cd "$PWD" \
  --role ~/.claude/skills/execute-codex/codex-architect-role.md \
  "Implement the following task. Write production-quality code.
Follow existing project conventions. Do not modify unrelated files.
Be concise. Output result only, no reasoning process.

<task description or plan content>"
```

## Continuing with Feedback

```bash
~/.claude/config/scripts/codex-call.sh --resume "$THREAD_ID" --sandbox workspace-write --cd "$PWD" \
  "Fix these issues from code review:
- auth.ts:42: missing null check on user.email
- api.ts:15: no rate limiting on /login endpoint
Reimplement with these fixes."
```

Pass the same `--sandbox` and `--cd` as the first call: the wrapper applies them (and the `review` profile) to the resumed turn, and `--sandbox` defaults to `read-only`.

## Loop Termination Signals

| Loop Type | Termination Signal | Who Decides |
|-----------|-------------------|-------------|
| Plan review | A Codex round replies exactly `VERDICT: APPROVED` with zero findings at any severity (a BLOCKED or WARNING reply that lists no finding is not clean) | Codex verdict plus Claude's evaluation gate |
| Execute review | A reviewer round replies exactly `VERDICT: APPROVED` with zero findings at any severity (a BLOCKED or WARNING reply that lists no finding is not clean) | Reviewer plus Claude's evaluation gate |

A `VERDICT: BLOCKED` or `VERDICT: WARNING` reply that lists no finding is not clean and not actionable: send ONE follow-up asking it to list its findings, and treat a repeat that still lists none as no verdict. There is no iteration cap and no severity floor: keep fixing and re-reviewing while any accepted CRITICAL, HIGH, MEDIUM or LOW finding remains, in round 6 and beyond. Disputed findings are settled through discussion with the active reviewer (`--resume` when Codex is the reviewer), never by stopping after N rounds. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry or switch to another independent reviewer (a fresh Codex thread without `--resume`, or, when Codex is over its usage limit or returns no verdict, `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Fallback input paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff), a Sonnet review that needs no Codex quota; the work stays pending until some reviewer returns a clean verdict on the current head). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A finding you contest is settled only by an authorized reviewer's concession or verification, recorded in writing with its evidence (a Codex thread when one is available; when a fallback reviewer is the active reviewer, any reviewer authorized for the repo, tier S included, with no Codex thread required). Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do. A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict.

**Review input (every reviewer call)**: every reviewer, the Codex call above and the tier S fallback below alike, is handed ONE input, built exactly as below after the intent-to-add step for the files this task created, and never the output of a fresh `git diff` run by the reviewer or by you. The diff goes through `~/.claude/config/scripts/redact-diff.sh`, a best-effort mask of inline credential values (private key blocks, cloud and API tokens, Bearer tokens, JWTs, password and secret assignments) on top of the path exclusions, not a guarantee, and the paths stay excluded. Only the masked output `.claude/review/review-input.diff` is ever placed in a prompt or a context file. Codex runs locally with read access to the working tree, so redaction governs what we put in the prompt, not what a local tool could open, so redaction governs what we put in the prompt, not what a local tool could open. If the script is missing or exits non-zero, or the diff is empty, the file is removed and nothing is dispatched to any reviewer, Codex or fallback: there is no verdict and the work stays unreviewed. Rebuild it before every round so it holds the CURRENT diff. Run it unchanged:

```
if R="$(git rev-parse --show-toplevel)" && [ -n "$R" ]; then (cd "$R" || exit 1
mkdir -p .claude/review; rm -f .claude/review/review-input.diff
(set -o pipefail; git diff HEAD -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key' ':(top,exclude).claude/review' | ~/.claude/config/scripts/redact-diff.sh > .claude/review/review-input.diff) && [ -s .claude/review/review-input.diff ] && echo "review input ready: send the contents of .claude/review/review-input.diff to every reviewer" || { rm -f .claude/review/review-input.diff; echo "no review input (the diff or its redaction failed, or the diff is empty): do NOT dispatch any reviewer, fix the cause and run this again"; }
); else echo "no repo root (git rev-parse --show-toplevel failed): do NOT dispatch any reviewer, run this again from inside the repository"; fi
```

**Fallback input (tier S)**: the fallback reviewer sees only the one file you hand it, so every tier S call uses ONE context file, built exactly as below and never a bare diff. It carries what the Codex call carried: the sanitized task requirements (the task or plan text, every task of a multi-task run, with any secret, credential or `.env` value removed), the review or audit instructions you sent to Codex (for a test audit, its Evaluate list), every carried finding (raised in an earlier round and still open) and every contested finding with your reasoning, then the review input: the contents of `.claude/review/review-input.diff` (the Review input paragraph), the same masked bytes the Codex call received, never a second `git diff` and never the raw diff. Rebuild the file for every round so it holds the CURRENT diff and the current findings. The best-effort mask is the one the Review input paragraph describes. If the review input is missing or empty, the context file is deleted and no context is sent, so there is no verdict from the fallback and the work stays unreviewed.

```
CTX="$(mktemp)"
cat > "$CTX" <<'EOF'
TASK REQUIREMENTS:
<the sanitized task requirements>

REVIEW INSTRUCTIONS:
<the review or audit instructions sent to Codex>

OPEN FINDINGS:
<every carried and contested finding with your reasoning, or the word none>

DIFF:
EOF
if R="$(git rev-parse --show-toplevel)" && [ -s "$R/.claude/review/review-input.diff" ] && cat "$R/.claude/review/review-input.diff" >> "$CTX"; then :
else rm -f "$CTX"; echo "the review input .claude/review/review-input.diff is missing or empty: no context is sent"; fi
[ -f "$CTX" ] && ~/.claude/config/scripts/reviewer.sh S "$CTX" <out-file>
```


## Validating a Verdict

never accept a verdict on a substring match. The first non-blank line must be exactly `VERDICT: APPROVED`, `VERDICT: WARNING` or `VERDICT: BLOCKED`. A second `VERDICT:` line is no verdict, and "NOT APPROVED", "APPROVED once you fix ..." or any other qualified verdict word inside other text is no verdict. The severity lines (`CRITICAL:`, `HIGH:`, `MEDIUM:`, `LOW:`) are optional: a severity header with empty text takes the next non-blank line that is not a severity header as its text, a header with no such line (end of the output, or another severity header next) makes the whole output no verdict and never a clean round, and the placeholder text `none` or `n/a` (any case, optional trailing period) is ignored, not a finding. Any real finding at any severity means findings, whatever the verdict word: `VERDICT: APPROVED` beside a real CRITICAL or HIGH finding is findings, never a clean round, so evaluate, fix and re-review it, and never drop it. `VERDICT: APPROVED` with no real finding (the bare line, or the line plus only placeholder severity lines) is clean. Empty output, or anything else that does not parse, is no verdict: treat the call as a failed review and re-ask the same reviewer (the same Codex thread through the wrapper, or the active fallback reviewer) for one unambiguous verdict.

The wrapper prints `THREAD_ID:` and the reply, so the check runs on the reply text after that line; a nonzero wrapper exit is no verdict whatever it printed.

## Anti-Patterns

- **Don't start new sessions per iteration**: wastes context and loses conversation history; use `--resume`
- **Don't summarize reviewer feedback**: Codex needs exact file:line references to fix issues
- **Don't use `danger-full-access`**: `workspace-write` is sufficient for implementation
- **Don't skip `--role`**: the role file shapes response quality significantly
- **Don't omit the conciseness instruction**: Codex may include lengthy reasoning that wastes context tokens
- **Don't exit a loop on a substring match for "APPROVED"**: "NOT APPROVED", "APPROVED once you fix ...", two verdict lines or `VERDICT: APPROVED` beside a real CRITICAL or HIGH finding is findings, never a clean round, and dropping the findings silently loses them
- **Don't treat a non-zero exit as an answer**: the wrapper prints "UNREVIEWED" when the turn died; read the error, fix the cause and retry or switch reviewer until a verdict arrives; report the review as not run (UNREVIEWED) only for a named blocker Claude cannot clear

## Parameter Quick Reference

| Parameter | Plan Review | Implementation |
|-----------|------------|----------------|
| `--sandbox` | `read-only` | `workspace-write` |
| `--role` | `~/.claude/skills/plan-codex/codex-analyzer-role.md` | `~/.claude/skills/execute-codex/codex-architect-role.md` |
| `--cd` | Project root | Project root |
| model and effort | `review` profile in `~/.codex/review.config.toml` | same |
