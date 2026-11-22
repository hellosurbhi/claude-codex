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
CLAUSE = "`git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it, so those and other unrelated untracked files do not reach the reviewer; the reviewer is read-only and cannot update the index, so new files reach the diff only this way; a modified tracked secret file such as `.env.production` is also left out of the diff with an exclude pathspec like `-- . ':(exclude,glob,icase)**/.env*' ':(exclude,glob,icase)**/*secret*' ':(exclude,glob,icase)**/*credential*' ':(exclude,glob,icase)**/*.pem' ':(exclude,glob,icase)**/*.key'`)"
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
    # cc11-main-r1: a nonzero reviewer.sh exit is no verdict whatever it printed (the installed script discards the model's exit status)
    (r"a nonzero exit is no verdict whatever it printed", NAMES),
    # cc11-main-r2 finding 1: a result counts only with exit 0 AND a complete verdict block
    (r"A reviewer result counts only when the command exited 0 AND the output is a complete verdict block\. Anything else is no verdict\.", NAMES),
    # cc11-main-r1: only a named non-transient blocker ends the quota fallback chain; transient failures retry with no cap
    (r"a named non-transient blocker ends the chain", ["execute-codex", "tdd-execute-codex"]),
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
EXCL = "-- . ':(exclude,glob,icase)**/.env*' ':(exclude,glob,icase)**/*secret*' ':(exclude,glob,icase)**/*credential*' ':(exclude,glob,icase)**/*.pem' ':(exclude,glob,icase)**/*.key'"
for n in NAMES:
    for f in files(n):
        for m in re.finditer(r"`git diff (?:HEAD|\$START_SHA)([^`]*)`", open(f, encoding="utf-8").read()):
            if EXCL not in m.group(0):
                bad.append("%s: reviewer diff command lacks the secret exclude pathspec: %s" % (os.path.relpath(f, root), m.group(0)))
# WHY (P3 matrix on 134faf7): codex-mcp's no-cap paragraph offered only tier R (committed changes) as a reviewer fallback, so in 2 of 7
# usage-limit runs the model sent an uncommitted tree to tier R, which answers "Review complete" on an empty diff and is not a review.
# Both codex-mcp copies must also offer tier S and say an uncommitted tree is never sent to tier R.
for f in (os.path.join(root, "skills", "codex-mcp", "SKILL.md"), os.path.join(root, "skills", "codex-mcp", "reference.md")):
    t = open(f, encoding="utf-8").read()
    if "reviewer.sh S <diff-file> <out-file>" not in t or "never an uncommitted tree" not in t:
        bad.append("%s: no-cap paragraph lacks the tier S fallback or the uncommitted-tree-never-tier-R rule" % os.path.relpath(f, root))
# cc11-main-r1: the pathspec must work, not just be spelled the same everywhere. Build a repo with root and nested secret files and run EXCL.
import subprocess, tempfile, shlex
def leaked(spec):
    with tempfile.TemporaryDirectory() as d:
        g = lambda *a: subprocess.run(("git", "-C", d, "-c", "user.email=a@b", "-c", "user.name=n") + a, capture_output=True, text=True, check=True).stdout
        # WHY: plumbing (commit-tree) instead of `git commit`, so the global pre-commit hooks never run inside a throwaway fixture repo.
        g("init", "-q"); open(os.path.join(d, "README"), "w").write("r")
        g("add", "README"); g("update-ref", "HEAD", g("commit-tree", g("write-tree").strip(), "-m", "i").strip())
        names = [".env", "app/.env.local", "app/sub/.env.production", "cfg/Secrets.json", "deploy_credentials.yml", "k/id.pem", "a.key", "app/sub/b.KEY", "ok.py", "app/okay.py"]
        for n in names:
            os.makedirs(os.path.dirname(os.path.join(d, n)) or d, exist_ok=True); open(os.path.join(d, n), "w").write("1")
        g("add", "-N", "-f", *names)
        out = g("diff", "HEAD", "--name-only", *shlex.split(spec))
        return sorted(set(out.split()) - {"ok.py", "app/okay.py"})
if leaked(EXCL):
    bad.append("EXCL pathspec still lets secret-named files through: %s" % leaked(EXCL))
if not leaked("-- . ':(exclude).env*' ':(exclude)*.pem' ':(exclude)*.key'"):
    bad.append("the old pathspec no longer leaks, so the functional check proves nothing")
# cc11-main-r1: the failed review/audit paragraph of every Codex-using workflow must say a verdict line without the four severity lines is a failed audit.
# WHY a per-file check instead of a SNIPPETS row: SNIPPETS demands equal counts in skill and command, but the skills also carry a frontmatter-adjacent summary the commands lack.
for n in ("claude-codex", "tdd-claude-codex", "tdd-execute-codex", "execute-codex"):
    for f in files(n):
        t = open(f, encoding="utf-8").read()
        paras = [q for q in t.split("\n\n") if q.startswith(("**Failed review**", "**Failed audit**"))]
        for q in paras:
            if not re.search(r"severity lines|`LOW:` lines", q):
                bad.append("%s: failed review/audit paragraph does not treat a missing severity block as failed" % os.path.relpath(f, root))
        if not paras and not re.search(r"`LOW:` lines, is a failed review|without the four severity lines", t):
            bad.append("%s: no failed review/audit rule for an incomplete Codex block" % os.path.relpath(f, root))
print("\n".join(bad))
sys.exit(1 if bad else 0)
