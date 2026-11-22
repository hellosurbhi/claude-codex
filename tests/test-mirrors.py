# Usage: test-mirrors.py [repo-root]   exit 0 when every mirrored review-loop instruction is identical in every copy.
# WHY a manifest test: the same instruction lives in skills/<n>/SKILL.md and commands/<n>.md (and several times per file);
# hand-checking copies kept missing one per review round (r17 to r20). Here a copy that differs or is missing fails (r20).
import json, os, re, sys
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
CLAUSE = "`git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it, so those and other unrelated untracked files do not reach the reviewer; the reviewer is read-only and cannot update the index, so new files reach the diff only this way; a modified tracked secret file such as `.env.production` is also left out of the diff with an exclude pathspec like `-- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'`)"
# a line that (re)calls a reviewer on a diff or on test files must carry the clause itself
CALL = re.compile(r"^\s*(- )?(Run `git diff|Re-call Codex via|Call Codex via)|re-calls? `codex-call\.sh --resume|re-run (the )?`?code-reviewer`?|re-audits? via", re.I)
# (regex, workflows that must contain it); every snippet must also appear equally often in a skill and its command
SNIPPETS = [
    (r"any reviewer authorized for the repo, tier S included", NAMES),
    (r"no Codex thread is required", []),
    (r"reviewer\.sh S <context-file> <out-file>", NAMES),
    (r"End the final report with exactly one machine-readable line, `AUDIT-STATUS: APPROVED reviewer=<name>`", NAMES),
    (r"Never conclude the reviewer is stuck, never report that no clean round was reached", []),
    (r"There is no iteration cap and no stop to ask the user after N rounds", []),
    # cc11-main-r1: a nonzero reviewer.sh exit is no verdict whatever it printed (the installed script discards the model's exit status)
    (r"a nonzero exit is no verdict whatever it printed", NAMES),
    # cc11-main-r2 finding 1: a result counts only with exit 0 AND an output that parses under the one verdict grammar
    (r"A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar\. Anything else is no verdict\.", NAMES),
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
    r"\(a fresh Codex thread without `--resume`.{0,2500}?on the current head\)",
    r"End the final report with exactly one machine-readable line.{0,400}?last non-blank line of the report\.",
    # r26: the stop rule (a usage limit is never a blocker while tier S can run) lives in the folded failure paragraphs too
    r"\(a call that merely died.{0,600}?while tier S can run\)",
    r"Never conclude the reviewer is stuck, never report that no clean round was reached and never hand the user a keep-going-or-drop-it decision; a doubt about a finding goes through",
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
# WHY per occurrence from the stable prefix (CodeRabbit thread 9): the full-clause regex stops matching a copy whose tail was edited
# (`any severity` -> `CRITICAL severity`), so that copy dropped out of `seen` and the cross-copy comparison never saw it.
NOCAP_PREFIX = "There is no iteration cap and no stop to ask the user"
for n in NAMES:
    for f in files(n):
        t = open(f, encoding="utf-8").read()
        for m in re.finditer(re.escape(NOCAP_PREFIX), t):
            # WHY not NOCAP_FULL itself: some workflows legitimately end the sentence "until a round has no accepted findings (owner mandate ...)",
            # so the stable invariant is: same round-count lead, ends on "no accepted findings", and no severity word narrows it.
            whole = t[m.start():m.start() + 400]
            sent = re.split(r"\. |\(", whole)[0]
            if "until a" not in sent or "no accepted findings" not in sent \
                    or re.search(r"\b(CRITICAL|HIGH|MEDIUM|LOW|only)\b", sent):
                bad.append("%s: a no-cap clause does not carry the canonical text (round 6, 10 or 20 ... no accepted findings, no severity limit)" % os.path.relpath(f, root))
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
PARAS = ["**Fallback input (tier S)**", "If Codex hit its usage limit", "**Codex availability check**", "**Usage limit (never block", "**MANDATORY mid-call failure handling**", "**Failed review**", "**Failed audit**"]
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
EXCL = "-- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'"
for n in NAMES:
    for f in files(n):
        for m in re.finditer(r"`git diff (?:HEAD|\$START_SHA)([^`]*)`", open(f, encoding="utf-8").read()):
            if EXCL not in m.group(0):
                bad.append("%s: reviewer diff command lacks the secret exclude pathspec: %s" % (os.path.relpath(f, root), m.group(0)))
for n in NAMES:
    for f in files(n):
        for ln, l in enumerate(open(f, encoding="utf-8"), 1):
            if re.match(r"git diff (HEAD|\$START_SHA) ", l) and EXCL not in l:
                bad.append("%s:%d: fenced reviewer diff command lacks the secret exclude pathspec" % (os.path.relpath(f, root), ln))
# WHY (P3 matrix on 134faf7): codex-mcp's no-cap paragraph once offered only a committed-diff reviewer as fallback, which answered "Review complete" on an uncommitted tree.
# Both codex-mcp copies must offer tier S (it reviews whatever diff file it is given).
for f in (os.path.join(root, "skills", "codex-mcp", "SKILL.md"), os.path.join(root, "skills", "codex-mcp", "reference.md")):
    t = open(f, encoding="utf-8").read()
    if "reviewer.sh S <context-file> <out-file>" not in t:
        bad.append("%s: no-cap paragraph lacks the tier S fallback" % os.path.relpath(f, root))
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
# cc11-main-r8 (design change): skills and commands NEVER call an outside reviewer. A skill cannot prove a diff is free of credentials (a pattern scan failed five reviews in a row:
# unscanned permission-only changes, names with the keyword not before the delimiter, and more), so the only fallback when Codex gives no verdict is tier S with the sanitized diff.
# WHY a line-level check: the prescribed text is one explanatory sentence; every other line of every skill, command and reference file must name no outside reviewer, so a re-added call fails here.
OUTSIDE = "Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain."
FORBIDDEN = re.compile(r"reviewer\.sh R\b|reviewer\.sh E\b|coderabbit|gemini|content scan|SCAN_CMD|REVIEW_BASE_SHA", re.I)
FALLBACK = re.compile(r"switch to another independent reviewer|fallback chain instead|Switch reviewers in this order")
for f in sorted(set(f for n in NAMES for f in files(n)) | set(os.path.join(root, "skills", "codex-mcp", x) for x in ("SKILL.md", "reference.md"))):
    for ln, line in enumerate(open(f, encoding="utf-8"), 1):
        rest = line.replace(OUTSIDE, "")
        if FORBIDDEN.search(rest):
            bad.append("%s:%d: names an outside reviewer or a content scan outside the one explanatory sentence: %s" % (os.path.relpath(f, root), ln, FORBIDDEN.search(rest).group(0)))
        if FALLBACK.search(line) and "reviewer.sh S <" not in line:
            bad.append("%s:%d: a reviewer fallback that does not name tier S (reviewer.sh S)" % (os.path.relpath(f, root), ln))
    if OUTSIDE not in open(f, encoding="utf-8").read() and os.path.basename(os.path.dirname(f)) != "tests" and "codex-analyzer" not in f:
        bad.append("%s: lacks the mirrored sentence about outside reviewers" % os.path.relpath(f, root))
# cc11-main-r9 finding 2: the tier S fallback must receive the SAME context the Codex call received, not only a diff. A bare diff loses the task requirements (so a test audit cannot check
# requirement coverage), the review or audit instructions and the carried and contested findings (so a fallback round cannot verify a fix or settle a dispute). Every fallback line therefore
# names the context file and what it carries, and every file with a fallback holds the ONE prescribed command sequence that builds it (the fenced block is mirrored skill to command).
CTXKEY = "built by the Fallback input paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff"
CTXPKEY = "built by the Fallback input paragraph: audit instructions, carried and contested findings, then the current plan text"
CTXFILES = sorted(set(f for n in NAMES for f in files(n)) | set(os.path.join(root, "skills", "codex-mcp", x) for x in ("SKILL.md", "reference.md")))
def block_of(path):
    t = open(path, encoding="utf-8").read()
    m = re.search(r"\*\*Fallback input \(tier S\)\*\*:.*?\n```\n.*?\n```\n", t, re.S)
    return m.group(0) if m else None
for f in CTXFILES:
    rel, plan = os.path.relpath(f, root), os.path.basename(os.path.dirname(f)) == "plan-codex" or os.path.basename(f) == "plan-codex.md"
    text = open(f, encoding="utf-8").read()
    for ln, line in enumerate(text.split("\n"), 1):
        if "reviewer.sh S <" in line and (CTXPKEY if plan else CTXKEY) not in line:
            bad.append("%s:%d: a tier S fallback line does not name the context it must include (%s)" % (rel, ln, "plan" if plan else "task requirements, instructions, findings, diff"))
        if re.search(r"reviewer\.sh S <(diff|plan)-file>", line):
            bad.append("%s:%d: a tier S fallback still passes a bare diff or plan file" % (rel, ln))
    if "reviewer.sh S <" in text:
        b = block_of(f)
        if not b:
            bad.append("%s: has a tier S fallback but no Fallback input paragraph with its command sequence" % rel)
            continue
        base = "$START_SHA" if "tdd-" in rel else "HEAD"
        need = ['reviewer.sh S "$CTX" <out-file>', 'CTX="$(mktemp)"', "OPEN FINDINGS:"] + (["AUDIT INSTRUCTIONS:", 'cat .claude/plan/<feature-name>.md >> "$CTX"', "PLAN:"] if plan else
                ["TASK REQUIREMENTS:", "REVIEW INSTRUCTIONS:", "DIFF:", "(set -o pipefail; git diff %s %s | ~/.claude/config/scripts/redact-diff.sh >> \"$CTX\")" % (base, EXCL), "|| { rm -f \"$CTX\"", "[ -f \"$CTX\" ] && ~/.claude/config/scripts/reviewer.sh S", "best-effort mask", "no context is sent"])
        for k in need:
            if k not in b:
                bad.append("%s: the Fallback input sequence lacks %r" % (rel, k[:50]))
        if len(re.findall(r"\*\*Fallback input \(tier S\)\*\*", text)) != 1:
            bad.append("%s: expected exactly one Fallback input paragraph" % rel)
for n in NAMES:
    sk, cm = files(n)
    if block_of(sk) != block_of(cm):
        bad.append("%s: the Fallback input paragraph and command sequence differ between skill and command" % n)
if "one context file" not in open(os.path.join(root, "README.md"), encoding="utf-8").read():
    bad.append("README.md: the tier S fallback statement does not name the context file")
# Round 3 finding 1: ONE verdict grammar everywhere (it must agree with the global review contract, which omits empty severity lines and
# calls a clean review exactly `VERDICT: APPROVED`). No file may demand severity lines, a `none` placeholder or a "complete verdict block".
# WHY a per-file check instead of a SNIPPETS row: SNIPPETS demands equal counts in skill and command, but the skills also carry a frontmatter-adjacent summary the commands lack.
OLD_GRAMMAR = ("<list or 'none'>", "(`none` when empty", "`none` when empty", "four severity lines", "complete verdict block", "is not followed by the", "(`none` on every severity line)", "only the reviewer.sh fallback may answer", "contradicts itself and is no verdict")
for f in sorted(set(f for n in NAMES for f in files(n)) | set(os.path.join(root, "skills", "codex-mcp", x) for x in ("SKILL.md", "reference.md")) | set(os.path.join(root, "skills", n, "codex-analyzer-role.md") for n in ("plan-codex", "tdd-claude-codex"))):
    t = open(f, encoding="utf-8").read()
    for k in OLD_GRAMMAR:
        if k in t:
            bad.append("%s: still carries the pre-round-3 verdict grammar text %r" % (os.path.relpath(f, root), k))
for n in ("claude-codex", "tdd-claude-codex", "tdd-execute-codex", "execute-codex"):
    for f in files(n):
        t = open(f, encoding="utf-8").read()
        paras = [q for q in t.split("\n\n") if q.startswith(("**Failed review**", "**Failed audit**"))]
        for q in paras:
            if "Validate the response" not in q or "second `VERDICT:` line" not in q:
                bad.append("%s: failed review/audit paragraph does not point at the single verdict grammar" % os.path.relpath(f, root))
# WHY (CodeRabbit thread 2): the TDD test audit received only a diff and generic questions, so a task given as direct text (not saved in the repo)
# could never be checked for coverage. Both TDD workflows, skill and command, must put the sanitized task requirements in the audit prompt.
for n in ("tdd-claude-codex", "tdd-execute-codex"):
    for f in files(n):
        t = open(f, encoding="utf-8").read()
        i = t.find("Test Audit")
        if "<TASK_REQUIREMENTS>" not in t[i:i + 6000].split("Return ONLY a structured verdict")[0]:
            bad.append("%s: the test-audit prompt does not include the sanitized <TASK_REQUIREMENTS>" % os.path.relpath(f, root))
# WHY (CodeRabbit thread 4): on the 3+ task path an accepted review finding dispatched a Claude subagent with feedback but never told it to
# go through codex-call.sh, so Route B's "implementation goes through Codex" broke exactly on fixes. Each fix subagent starts or resumes ITS task's thread.
for n in ("execute-codex", "tdd-execute-codex"):
    for f in files(n):
        t = open(f, encoding="utf-8").read()
        for m in re.finditer(r"3\+ task path .{0,40}dispatch a Claude subagent[^\n]*", t):
            if not ("codex-call.sh" in m.group(0) and "that task's own" in m.group(0)):
                bad.append("%s: the 3+ task fix path does not make each fix subagent call codex-call.sh on its own task's Codex thread" % os.path.relpath(f, root))
# WHY (CodeRabbit thread 6): the re-audit/re-review step said to resume the Codex thread unconditionally, so after a quota fallback the revised
# plan or diff went back to a thread that cannot answer. Every no-cap paragraph must route re-review to the ACTIVE reviewer.
ACTIVE = "send the revised plan or diff to that same fallback reviewer"
for n in NAMES:
    for f in files(n):
        for ln in open(f, encoding="utf-8").read().split("\n"):
            if ln.startswith("There is no iteration cap and no stop to ask the user") and ACTIVE not in ln:
                bad.append("%s: a no-cap paragraph does not route re-review to the active fallback reviewer" % os.path.relpath(f, root))
# C3 (PR 10, rewritten for codex-call.sh): a verdict is validated, never substring-matched.
VALID_KEYS = ("first non-blank line must be exactly `VERDICT: APPROVED`", "NOT APPROVED", "APPROVED once you fix", "second `VERDICT:` line is no verdict", "takes the next non-blank line that is not a severity header as its text", "makes the whole output no verdict and never a clean round", "`none` or `n/a`", "real finding at any severity means findings", "never a clean round", "mpty output")
PARSE_ANCHOR = re.compile(r"^(Classify the verdict\.|\*\*Parse response\*\*|\*\*Parse the exact|Parse reviewer response)")
for n in NAMES:
    for f in files(n):
        L = open(f, encoding="utf-8").read().split("\n")
        for i, l in enumerate(L):
            if PARSE_ANCHOR.match(l):
                prev = L[i - 2] if i > 1 else ""
                if not (prev.startswith("**Validate the response**") and all(k in prev for k in VALID_KEYS)):
                    bad.append("%s:%d verdict parse step is not preceded by the canonical Validate the response block" % (os.path.relpath(f, root), i + 1))
ref = open(os.path.join(root, "skills/codex-mcp/reference.md"), encoding="utf-8").read()
for k in VALID_KEYS:
    if k not in ref:
        bad.append("skills/codex-mcp/reference.md lacks verdict validation text: %r" % k)
for n in ("plan-codex", "tdd-claude-codex"):
    r = open(os.path.join(root, "skills/%s/codex-analyzer-role.md" % n), encoding="utf-8").read()
    if "Emit exactly one verdict line" not in r or "the caller fixes and re-audits every finding you list at any severity" not in r.lower():
        bad.append("skills/%s/codex-analyzer-role.md lacks the one-verdict-line sentence merged with the any-severity sentence" % n)
for n in NAMES:
    ev = open(os.path.join(root, "skills/%s/evals/evals.json" % n), encoding="utf-8").read()
    if "mcp__codex" in ev or '"id": 9' not in ev:
        bad.append("skills/%s/evals/evals.json lacks the invalid-verdict eval (id 9) or still names mcp__codex__" % n)
    # Round 4 finding 2: read EVERY text field of the id 9 eval (prompt, expected_output, files, every expectation), not one field. APPROVED beside a real CRITICAL or HIGH finding is FINDINGS
    # (fix and re-review) in the two evals that model it; a doubled or qualified verdict is no verdict in the other three. Neither may borrow the other's wording.
    def texts(x):
        return [x] if isinstance(x, str) else [y for v in (x.values() if isinstance(x, dict) else x if isinstance(x, list) else []) for y in texts(v)]
    e9 = [e for e in json.loads(ev)["evals"] if e.get("id") == 9]
    t9 = " ".join(texts(e9)).lower() if e9 else ""
    if n in ("claude-codex", "tdd-claude-codex"):
        for banned in ("no verdict", "unambiguous verdict", "contradictory", "contradiction", "re-asks"):
            if banned in t9:
                bad.append("skills/%s/evals/evals.json id 9 still says %r although APPROVED with a real finding is findings (fix and re-review)" % (n, banned))
        for need in ("findings", "re-review"):
            if need not in t9:
                bad.append("skills/%s/evals/evals.json id 9 does not say %r" % (n, need))
    elif "no verdict" not in t9:
        bad.append("skills/%s/evals/evals.json id 9 does not say a doubled or qualified verdict is no verdict" % n)
# cc11-main-r4 finding 3: every reviewer prompt that says to omit empty severity lines also forbids a header with no text (the grammar treats one as no verdict).
for f in sorted(set(f for n in NAMES for f in files(n)) | set(os.path.join(root, "skills", n, "codex-analyzer-role.md") for n in ("plan-codex", "tdd-claude-codex"))):
    t = open(f, encoding="utf-8").read()
    if t.count("Omit any severity line with no findings") != t.count("and never a severity header with no text after it"):
        bad.append("%s: a reviewer prompt omits the 'never a severity header with no text after it' clause" % os.path.relpath(f, root))
for f in files("plan-codex"):
    if "reviewer.sh S <context-file> <out-file>" not in open(f, encoding="utf-8").read():
        bad.append("%s: the plan fallback does not name tier S on the actual plan file" % os.path.relpath(f, root))
for dp, _, fs in os.walk(root):
    if "/.git" in dp or "/tests" in dp: continue
    for fn in fs:
        if fn.endswith((".md", ".json")) and "max iteration count (default" in open(os.path.join(dp, fn), encoding="utf-8", errors="ignore").read():
            bad.append("%s ports a capped iteration count, which contradicts the no-cap rule" % os.path.relpath(os.path.join(dp, fn), root))
# r10 finding 1: every exit-to-delivery condition names an explicit `VERDICT: APPROVED` AND zero findings; a bare BLOCKED or WARNING with
# no findings listed is neither clean nor actionable (one follow-up asking for the findings, a repeat is no verdict).
# WHY a per-line scan: the exit lines read "Done", "approved, go to Phase N" or "-> go to Phase N", so a reworded or reverted line must still be found by its destination.
EXITRX = re.compile(r"^- \*\*Done\*\* →|→ (approved, )?(go to|proceed to) Phase|^- (A round (with no|whose reply)|No findings at any severity|Exactly `VERDICT: APPROVED`)")
EXIT_COUNT = {"claude-codex": 1, "execute-codex": 1, "plan-codex": 1, "tdd-claude-codex": 2, "tdd-execute-codex": 2}
NEED = ["`VERDICT: APPROVED`", "zero findings", "lists no finding", "asking it to list its findings", "a repeat that still lists none as no verdict"]
for n in NAMES:
    for f in files(n):
        ex = [(i, l) for i, l in prose(f) if EXITRX.search(l) and "Any " not in l[:12]]
        if len(ex) != EXIT_COUNT[n]:
            bad.append("%s: %d delivery-exit lines found, expected %d" % (os.path.relpath(f, root), len(ex), EXIT_COUNT[n]))
        for i, l in ex:
            for k in NEED:
                if k not in l:
                    bad.append("%s:%d delivery exit lacks %r (APPROVED plus zero findings, bare BLOCKED/WARNING is not clean)" % (os.path.relpath(f, root), i, k))
for f in [os.path.join(root, "skills", "codex-mcp", "SKILL.md"), os.path.join(root, "skills", "codex-mcp", "reference.md")]:
    t = open(f, encoding="utf-8").read()
    if "`VERDICT: APPROVED` with zero findings" not in t or "lists no finding is not clean" not in t:
        bad.append("%s: the loop exit does not require VERDICT: APPROVED with zero findings" % os.path.relpath(f, root))
# r10 finding 2: execute-codex and tdd-execute-codex review the implementation with a Claude code-reviewer agent, whose verdict never reaches the wrapper log. The skill therefore prescribes ONE
# command sequence that saves each reviewer reply with the hash of the exact diff it reviewed (.claude/review/final-review.txt); the proof validates that file. Mirrored skill to command.
RECHEAD = "**Review record (every reviewer round)**"
def rec_of(path):
    t = open(path, encoding="utf-8").read()
    m = re.search(re.escape(RECHEAD) + r".*?\n```\n.*?\n```\n.*?(?:\n\n|$)", t, re.S)
    return (m.group(0), t.count(RECHEAD)) if m else (None, t.count(RECHEAD))
for n in ("execute-codex", "tdd-execute-codex"):
    base = "$START_SHA" if n.startswith("tdd-") else "HEAD"
    got = []
    for f in files(n):
        rel = os.path.relpath(f, root)
        b, cnt = rec_of(f)
        got.append(b)
        if cnt != 1 or not b:
            bad.append("%s: expected exactly one Review record paragraph with its command sequence (found %d)" % (rel, cnt)); continue
        for k in ["mkdir -p .claude/review", "printf 'REVIEWED-DIFF: %s\\n'", "git diff %s %s | shasum -a 256 | cut -d' ' -f1" % (base, EXCL), "> .claude/review/final-review.txt", "<the reviewer's reply, verbatim>", "makes the record stale", "AUDIT-STATUS: UNREVIEWED"]:
            if k not in b:
                bad.append("%s: the Review record sequence lacks %r" % (rel, k[:60]))
    if got[0] != got[1]:
        bad.append("%s: the Review record paragraph differs between skill and command" % n)
print("\n".join(bad))
sys.exit(1 if bad else 0)