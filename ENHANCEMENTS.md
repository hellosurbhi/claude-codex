# Enhancements

LOW findings from push reviews, filed rather than fixed. Each entry records why it
was not fixed on this branch and what would close it. An entry moves to `BUGS.md`
if a later review re-files it at MEDIUM or above. LOW findings that this branch
did fix stay in `BUGS.md` under the section that fixed them, so this file holds
only the deferred ones.

## Low priority enhancements

### Codex (2026-08-26T18:22Z)
- [ ] LOW: BROKEN-REFERENCE The `0a19092` commit body ends with “plus mechanical checks below”, but no checks follow. List the checks or remove the dangling phrase. | Deferred 2026-08-26: the finding is real. `git log -1 --format=%B 0a19092` ends on that phrase with nothing after it. The same sentence closes the body of every `finish(fix/medium-bugs-20260819)` commit on this branch rather than that one commit alone, so it is a lane template artifact and not a one-off slip. It is not fixable from this worktree: the phrase lives in committed history, and nothing in the tree emits it, so the template that does emit it belongs to the finisher lane outside the repository. Rewriting those commit bodies would close the finding but would also rewrite every commit the push reviews ran against, falsifying the audit record the same way editing `reviews/.cache/2a3fc751….diff` would; that exclusion is already recorded twice in `BUGS.md`. Closing action for whoever owns the lane template: either drop the trailing `, plus mechanical checks below` clause or have the body list the checks it promises. Verified: `grep -rIn "mechanical checks"` over the worktree matches only backlog prose that quotes this finding and never a template or script that emits the phrase, which is why the fix does not belong to this repository; every `finish(fix/medium-bugs-20260819)` commit on this branch carries the phrase and the only commit that does not is `b13d958`, which predates the finisher lane and has an unrelated body.
