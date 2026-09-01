
## Medium priority (auto-fix pending)

### Codex (2026-08-30T07:55Z)
- [x] MEDIUM: `ENHANCEMENTS.md:1` uses an em dash, violating the repository copy voice mandate.
  - Fixed: the em dash in `ENHANCEMENTS.md:1` is now a sentence break ("False positive. Line 40 ...").
  - Note: no repository copy voice mandate exists. Em dashes are used in `README.md` and 13 other tracked files, so the stated rationale is a false premise and no other file was rewritten.


## High priority (from push reviews, fix first)

### Codex (2026-08-30T15:14Z)
- [x] HIGH: SCOPE-CREEP: `.gitignore:26-29` uses unanchored patterns, so Git ignores matching files and `reviews/` directories anywhere in the repository. `git check-ignore` confirms nested paths are affected despite the comment describing root review-loop state. Anchor these patterns with leading `/`.
  - Fixed: the three remaining patterns are now anchored (`/reviews/`, `/.claude-fixed-items.validated.txt`, `/.claude-wontfix-items.txt`), so they only match at the repository root as the comment describes.
- [x] HIGH: Ignoring `BUGS.md` prevents the mandated bug backlog from being tracked, allowing deferred findings to disappear when a worktree is removed. Use a separate name for transient review-loop state.
  - Fixed: `BUGS.md` was removed from `.gitignore` and stays in version control. Only genuinely transient loop state (`reviews/`, the fixed/wontfix scratch lists) is ignored, and the comment now names both tracked backlogs.

### Codex (pending verdict, resolved in this pass)
- [x] CRITICAL: FABRICATED-REFERENCE: `ENHANCEMENTS.md:1` claims the local analyzer is a reviewed symlink. `ls -l` shows it is a regular file, `readlink` returns no target and `cmp` confirms it differs from `prompts/codex/analyzer.md`.
  - Fixed: the unverifiable "and the reviewed local symlink resolves it" clause was dropped from `ENHANCEMENTS.md:1` and from the matching `.claude-wontfix-items.txt` record. The clause was not load-bearing — the WONTFIX rationale rests only on `prompts/codex/analyzer.md` being tracked and `README.md:76` (`cp -r prompts/*  ~/.claude/prompts/`) installing it, both of which were re-verified.

