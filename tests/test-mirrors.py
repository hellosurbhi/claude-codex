# Usage: test-mirrors.py [repo-root]   exit 0 when every mirrored review-loop instruction is identical in every copy.
# WHY a manifest test: the same instruction lives in skills/<n>/SKILL.md and commands/<n>.md (and several times per file);
# hand-checking copies kept missing one per review round (r17 to r20). Here a copy that differs or is missing fails (r20).
import os, re, sys
root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
NAMES = ["claude-codex", "execute-codex", "plan-codex", "tdd-claude-codex", "tdd-execute-codex"]
DIFF_NAMES = [n for n in NAMES if n != "plan-codex"]
def files(n):
    return [os.path.join(root, "skills", n, "SKILL.md"), os.path.join(root, "commands", n + ".md")]
def prose(path):
    # (lineno, text) of every line outside code fences
    out, fence = [], False
    for i, l in enumerate(open(path, encoding="utf-8").read().splitlines(), 1):
        if l.lstrip().startswith("```"):
            fence = not fence
            continue
        if not fence:
            out.append((i, l))
    return out
CLAUSE = "`git add -N .` in your own shell first (the reviewer is read-only and cannot update the index, so new files reach the diff only this way)"
# a line that (re)calls a reviewer on a diff or on test files must carry the clause itself
CALL = re.compile(r"^\s*(- )?(Run `git diff|Re-call Codex via|Call Codex via)|re-calls? `codex-call\.sh --resume|re-run (the )?`?code-reviewer`?|re-audits? via", re.I)
# (regex, workflows that must contain it); every snippet must also appear equally often in a skill and its command
SNIPPETS = [
    (r"any reviewer authorized for the repo, tier S included", NAMES),
    (r"no Codex thread is required", []),
    (r"reviewer\.sh S <(?:diff|plan)-file> <out-file>", NAMES),
    (r"REVIEW_BASE_SHA=<base commit> ~/\.claude/config/scripts/reviewer\.sh R", DIFF_NAMES),
    (r"End the final report with exactly one machine-readable line, `AUDIT-STATUS: APPROVED reviewer=<name>`", NAMES),
]
bad = []
for n in DIFF_NAMES:
    for f in files(n):
        for i, l in prose(f):
            if "git add -N" in l and CLAUSE not in l:
                bad.append("%s:%d git add -N line lacks the canonical clause" % (os.path.relpath(f, root), i))
            if CALL.search(l) and "git add -N" not in l and "codex-call.sh --resume <THREAD_ID> --sandbox" not in l and "no shared" not in l:
                bad.append("%s:%d reviewer call/re-review line lacks `git add -N`" % (os.path.relpath(f, root), i))
for n in NAMES:
    sk, cm = files(n)
    ts, tc = open(sk, encoding="utf-8").read(), open(cm, encoding="utf-8").read()
    for rx, need in SNIPPETS:
        a, b = len(re.findall(rx, ts)), len(re.findall(rx, tc))
        if a != b or (n in need and a == 0):
            bad.append("%s: %r appears %d times in the skill and %d in the command" % (n, rx[:55], a, b))
print("\n".join(bad))
sys.exit(1 if bad else 0)
