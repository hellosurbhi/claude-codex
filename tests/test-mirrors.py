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
CLAUSE = "`git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it, so those and other unrelated untracked files do not reach the reviewer; the reviewer is read-only and cannot update the index, so new files reach the diff only this way; a modified tracked secret file such as `.env.production` is also left out of the diff with an exclude pathspec like `-- . ':(exclude).env*' ':(exclude)*.pem' ':(exclude)*.key'`)"
# a line that (re)calls a reviewer on a diff or on test files must carry the clause itself
CALL = re.compile(r"^\s*(- )?(Run `git diff|Re-call Codex via|Call Codex via)|re-calls? `codex-call\.sh --resume|re-run (the )?`?code-reviewer`?|re-audits? via", re.I)
# (regex, workflows that must contain it); every snippet must also appear equally often in a skill and its command
SNIPPETS = [
    (r"any reviewer authorized for the repo, tier S included", NAMES),
    (r"no Codex thread is required", []),
    (r"reviewer\.sh S <(?:diff|plan)-file> <out-file>", NAMES),
    (r"REVIEW_BASE_SHA=<base commit> ~/\.claude/config/scripts/reviewer\.sh R", DIFF_NAMES),
    (r"End the final report with exactly one machine-readable line, `AUDIT-STATUS: APPROVED reviewer=<name>`", NAMES),
    (r"Never conclude the reviewer is stuck, never report that no clean round was reached", []),
    (r"There is no iteration cap and no stop to ask the user after N rounds", []),
]
bad = []
for n in DIFF_NAMES:
    for f in files(n):
        for i, l in prose(f):
            if "git add -N ." in l or "git add -N`" in l and "<each file" not in l:
                bad.append("%s:%d adds every untracked file (git add -N .); name the task's own files" % (os.path.relpath(f, root), i))
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
# whole-clause equality: every occurrence of each mirrored clause, in every file, must be the same text (r21)
CLAUSES = [
    r"\(the active reviewer is the Codex thread or.{0,400}?no Codex thread is required\)",
    r"\(a fresh Codex thread without `--resume`.{0,900}?on the current head\)",
    r"End the final report with exactly one machine-readable line.{0,400}?last non-blank line of the report\.",
    # r26: the stop rule (usage limit or unavailable CodeRabbit is never a blocker while tier S can run) lives in the folded failure paragraphs too
    r"\(a call that merely died.{0,600}?while tier S can run\)",
    r"Never conclude the reviewer is stuck, never report that no clean round was reached, and never hand the user a keep-going-or-drop-it decision; a doubt about a finding goes through",
    r"There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity",
]
# WHY per occurrence: the middle of the no-stop clause legitimately names each skill's own discussion path, so the whole
# clause cannot be compared across copies, but every copy must still end in the same exit rule (r25b).
for n in NAMES:
    for f in files(n):
        t = open(f, encoding="utf-8").read()
        for m in re.finditer(r"Never conclude the reviewer is stuck", t):
            if "and the only other exit is the failed-review rule." not in t[m.start():m.start() + 600].split("\n")[0]:
                bad.append("%s: no-stop clause does not end with the failed-review exit rule" % os.path.relpath(f, root))
for rx in CLAUSES:
    seen = {}
    for n in NAMES:
        for f in files(n):
            for m in re.findall(rx, open(f, encoding="utf-8").read(), re.S):
                seen.setdefault(re.sub(r"\s+", " ", m), []).append(os.path.relpath(f, root))
    # WHY per workflow: a command whose clause was rewritten matches zero times while its skill still matches, which the
    # cross-copy text comparison alone cannot see (r36); a skill and its command must hold the same number of occurrences.
    # (the last two clauses legitimately differ in count per workflow and have their own per-occurrence rules above)
    for n in NAMES if rx in CLAUSES[:4] else []:
        sk, cm = files(n)
        a, b = len(re.findall(rx, open(sk, encoding="utf-8").read(), re.S)), len(re.findall(rx, open(cm, encoding="utf-8").read(), re.S))
        if a != b:
            bad.append("%s: clause %r appears %d times in the skill and %d in the command" % (n, rx[:40], a, b))
    if len(seen) > 1:
        bad.append("clause %r differs between copies: %s" % (rx[:40], " | ".join("%d copies like %r" % (len(v), k[:60]) for k, v in seen.items())))
    if not seen:
        bad.append("clause %r found in no file" % rx[:40])
# whole-paragraph equality for the quota and failure paragraphs: a skill and its command must hold the same text (r22)
PARAS = ["If Codex hit its usage limit", "**Codex availability check**", "**Usage limit (never block", "**MANDATORY mid-call failure handling**", "**Failed review**", "**Failed audit**"]
def paras(path, anchor):
    out = []
    for l in open(path, encoding="utf-8").read().split("\n"):
        t = re.sub(r"\s+", " ", re.sub(r"^\s*(\d+\.|-)\s*", "", l)).strip()
        if t.startswith(anchor):
            out.append(t)
    return out
for n in NAMES:
    sk, cm = files(n)
    for a in PARAS:
        x, y = paras(sk, a), paras(cm, a)
        # WHY exempt: these commands fold the failure rules into their no-iteration-cap paragraph, whose chain and dispute
        # clauses are already compared clause by clause above; the other paragraphs are compared whole
        if x != y and (n, a) not in [(m, b) for m in ("claude-codex", "tdd-claude-codex", "tdd-execute-codex") for b in ("**Failed review**", "**Failed audit**")]:
            bad.append("%s: paragraph %r differs between skill and command" % (n, a[:40]))
# WHY (CodeRabbit r48): the reviewer must not read tracked secret files either, so every reviewer diff command carries the exclude pathspec.
EXCL = "-- . ':(exclude).env*' ':(exclude)*.pem' ':(exclude)*.key'"
for n in NAMES:
    for f in files(n):
        for m in re.finditer(r"(?:Run |output of )`git diff (?:HEAD|\$START_SHA)([^`]*)`", open(f, encoding="utf-8").read()):
            if EXCL not in m.group(0):
                bad.append("%s: reviewer diff command lacks the secret exclude pathspec: %s" % (os.path.relpath(f, root), m.group(0)))
print("\n".join(bad))
sys.exit(1 if bad else 0)
