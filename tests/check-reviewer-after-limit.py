# Usage: check-reviewer-after-limit.py <wrapper.jsonl> [--phase implementation] [--plan-file <path>] [--repo <dir>] [--context]
# Exit 0 when a fallback reviewer (spy) was STARTED after the Codex wrapper reported the usage limit,
# and the last such review exited 0 with EXACTLY the five clean lines. With --phase, that review was
# called for that phase (a tests-only call does not satisfy "implementation"). With --plan-file, the
# review input holds the current non-empty plan file's text, so a stale or empty plan fails. With --context the input is the ONE context file the skills prescribe (r9 finding 2):
# its section headings come first, in order, and the plan text (or the diff) comes last.
# WHY only the log: transcripts quote docs and agent text; the wrapper log is what actually ran.
import hashlib, os, re, subprocess, sys, tempfile
import wlog
def changes(lines):
    # (added, removed) line lists from the hunks of ONE file's diff; only the one-character prefix is removed.
    add, rem, inh = [], [], False
    for l in lines:
        if l.startswith("@@"):
            inh = True
        elif inh and l.startswith("+"):
            add.append(l[1:])
        elif inh and l.startswith("-"):
            rem.append(l[1:])
    return add, rem

def reviewed_changes(lines):
    # {path: (added, removed)} for every .py file section of a git diff; sections start at a "diff --git" or "--- " header.
    secs, cur, name = {}, None, None
    for l in lines:
        if l.startswith("diff --git "):
            cur, name = [], None
            secs[id(cur)] = (None, cur)
        elif l.startswith("--- ") and (cur is None or not any(x.startswith("@@") for x in cur)):
            if cur is None:
                cur = []; secs[id(cur)] = (None, cur)
            if l[4:] != "/dev/null":
                secs[id(cur)] = (l[4:].split("\t")[0][2:], cur)
            cur.append(l)
        elif l.startswith("+++ ") and cur is not None and not any(x.startswith("@@") for x in cur):
            if l[4:].strip() != "/dev/null":
                secs[id(cur)] = (l[4:].split("\t")[0][2:], cur)
            cur.append(l)
        elif cur is not None:
            cur.append(l)
    out = {}
    for n, body in secs.values():
        if n and n.endswith(".py"):
            a, r = changes(body)
            pa, pr = out.get(n, ([], []))
            out[n] = (pa + a, pr + r)
    return out

def patch_sections(lines, names):
    # The .py file sections of a git diff, each starting at its "diff --git" line, kept whole (headers, hunks, context).
    # WHY every .py section is validated: a copy/rename-only section never reaches reviewed_changes, so without this it
    # could write outside the temp dir or smuggle a file the final tree does not have. Each section must be a plain
    # same-path edit of a file in the final set, with no copy/rename lines and no traversal (r21). None means reject.
    secs, cur = [], None
    for l in lines:
        if l.startswith("diff --git "):
            cur = [l]; secs.append(cur)
        elif cur is not None:
            cur.append(l)
    out = []
    for sc in secs:
        m = re.fullmatch(r"diff --git a/(.+) b/(.+)", sc[0])
        if not m:
            return None
        a_, b_ = m.groups()
        if not (a_.endswith(".py") or b_.endswith(".py")):
            continue
        if a_ != b_ or b_ not in names or os.path.isabs(b_) or ".." in b_.split("/"):
            return None
        if any(re.match(r"(copy|rename|similarity|dissimilarity) ", x) for x in sc[1:]):
            return None
        out.append(sc)
    return out

def reject(why):
    # WHY a printed reason (round 15 finding 1): a silent nonzero exit lets a negative test pass for any cause, a crash included; the reason is what the test asserts on.
    print("REJECT: " + why, file=sys.stderr)
    sys.exit(1)

args = sys.argv[1:]
evs = wlog.load(args[0])
phase = args[args.index("--phase") + 1] if "--phase" in args else None
plan = args[args.index("--plan-file") + 1] if "--plan-file" in args else None
repo = args[args.index("--repo") + 1] if "--repo" in args else None
context = "--context" in args
non_spy = [e for e in evs if e["wrapper"] != "spy"]
li = wlog.limit_index(non_spy)
if li is None:
    reject('no quota-limit event in the log')
limit_done = non_spy[li]["ts"]
# WHY the shared decision over EVERY attempt (r25): the last review attempt of any kind decides. Filtering to fallback reviewers only let quota failure, clean fallback review, then a later FAILED Codex
# attempt (or a wrapper-failed event) still pass. That last attempt must be a fallback reviewer call that STARTED after the quota reply (a review that began before it was not a reaction to it) and was clean.
# WHY only the production argument vector (tier E/R/S, input, output): `diagnose` or a malformed call is not a review (r29); a malformed review call after a clean one is a newer failed attempt and decides (r44).
valid_spy = lambda e: len(e["argv"]) >= 3 and e["argv"][0] in ("E", "R", "S") and bool(e["argv"][1]) and bool(e["argv"][2])
fin = wlog.final_review_state(evs)
last = fin["last"]
if last is None or last["wrapper"] != "spy" or wlog.started(last)[0] < limit_done or not valid_spy(last) or not fin["approved"]:
    reject('no valid reviewer call after the quota hit, or the last one is not clean')
spies = [last]
if phase is not None and spies[-1]["phase"] != phase:
    reject('the last reviewer call ran in another phase')
# WHY production decides validity (r38): the launcher ran the REAL reviewer.sh, which already rejected a bad tier, a missing
# base, an unusable input or an outage (non-zero exit, no clean verdict). This checker only joins the launcher event to the fake
# model binaries production called (same run id) and asserts WHICH model accepted, with which tier, base and reviewed content.
run = (spies[-1].get("meta") or {}).get("run")
models = [e for e in evs if e["wrapper"] == "model" and run and (e.get("meta") or {}).get("run") == run and e["exit"] == 0 and (e.get("meta") or {}).get("bin") in ("claude", "coderabbit")]
if len(models) != 1:
    reject('not exactly one accepted model call for the launcher run')
model = models[0]
mm = model.get("meta") or {}
tier = spies[-1]["argv"][0]
spy_in = spies[-1].get("input_text") or ""
if mm.get("tier") != tier:
    reject('the model call used another tier than the launcher')
# WHY argv (r41): the fake answers whatever it is called with, so a non-review call must be rejected from what production passed.
margv = model.get("argv") or []
if any(a in ("--version", "-v", "--help", "-h") for a in margv) or (mm["bin"] == "claude" and "-p" not in margv):
    reject('the model call was not a review (version or help probe, or claude without -p)')
if mm["bin"] == "claude":
    # Sonnet reviewed the input file itself, so its prompt must carry the whole input verbatim.
    # WHY rstrip: reviewer.sh builds the prompt with command substitution, which drops trailing newlines.
    if not spy_in.strip() or spy_in.rstrip("\n") not in (model.get("input_text") or ""):
        reject('the review prompt does not carry the input file verbatim')
def heads_in_order(text, heads):
    # each heading alone on its own line, in this order, and the first section after the first heading holds some text
    pos = -1
    for h in heads:
        m = re.search(r"^" + re.escape(h) + r"[ \t]*$", text[pos + 1:], re.M)
        if not m:
            return False
        pos = pos + 1 + m.end()
    return True
if context and plan is None and not (heads_in_order(spy_in, ["TASK REQUIREMENTS:", "REVIEW INSTRUCTIONS:", "OPEN FINDINGS:", "DIFF:"]) and re.search(r"^TASK REQUIREMENTS:[ \t]*\n[ \t]*[^\s<]", spy_in, re.M)):
    # WHY a non-empty requirements text that is not the angle-bracket template placeholder: a context file whose requirements were left as the template carries no requirement at all
    reject('the context input lacks the required sections in order or has a template requirements text')
if plan is not None:
    # WHY tier S and the full file content: production tier R reviews committed repository state, not a plan file.
    if tier != "S" or mm["bin"] != "claude":
        reject('a plan review must be tier S through claude')
    if not os.path.isfile(plan) or os.path.getsize(plan) == 0:
        reject('the plan file is missing or empty')
    data = open(plan, "rb").read()
    # WHY containment, not a digest of the whole input (r9 finding 2): the prescribed fallback input is the audit instructions and open findings FOLLOWED BY the plan, so the input is
    # never byte-equal to the plan file; the plan text must still appear in full (a stale, edited or truncated plan is not contained) and the spy must have logged the same text.
    ptxt = data.decode("utf-8", "surrogateescape").rstrip("\n")
    if ptxt not in spy_in or ptxt not in (model.get("input_text") or ""):
        reject('the reviewed input does not contain the current plan text')
    if context and not (heads_in_order(spy_in, ["AUDIT INSTRUCTIONS:", "OPEN FINDINGS:", "PLAN:"]) and spy_in.rstrip("\n").endswith(ptxt)):
        reject('the plan context input lacks its sections in order or the plan is not last')
# WHY a checked git helper (r12 finding 3): an unchecked failing git call prints nothing, and that empty result (no root commit, no head, no status lines) is accepted by the comparisons below as if it were a real answer.
# A repo with no commit yet legitimately has no root commit, so only a repo that HAS a HEAD must answer rev-list.
def G(*a, text=True):
    r = subprocess.run(["git", "-C", repo] + list(a), capture_output=True, text=text)
    if r.returncode != 0:
        reject('a git call failed')
    return r.stdout
if repo is not None:
    # WHY an exact digest of the final .py files: the review must cover exactly the code that remains (all modules, paths,
    # indentation and deletions included), so any edit after the approval fails (r15).
    final = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "treehash.py"), repo], capture_output=True, text=True).stdout.strip()
    if not final or spies[-1].get("tree_sha256") != final:
        reject('the code tree changed after the reviewed state')
    # WHY exact per-file changes: the digest pins the code state at review time, but a stale or partial diff would still be
    # "approved". The reviewed input must hold, for every changed .py file and for no other, exactly the added and removed
    # lines (order, indentation and operators intact, only the one-character diff prefix removed) that turn the first
    # commit's file into the file that remains (r16, r17).
    root = (G("rev-list", "--max-parents=0", "HEAD").split() if subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q", "HEAD"], capture_output=True).returncode == 0 else [])
    # WHY recursive, with the tree digest's exclusions: a nested module must be covered like a root one (r18).
    names = set()
    for dp, dn, fn in os.walk(repo):
        dn[:] = [d for d in dn if d not in (".git", ".claude", "__pycache__", ".pytest_cache", "node_modules")]
        names |= {os.path.relpath(os.path.join(dp, f), repo) for f in fn if f.endswith(".py")}
    if root:
        names |= {f for f in G("ls-tree", "-r", "--name-only", root[0]).splitlines() if f.endswith(".py")}
    expected = {}
    for name in sorted(names):
        base = b""
        if root:
            r = subprocess.run(["git", "-C", repo, "show", root[0] + ":" + name], capture_output=True)
            base = r.stdout if r.returncode == 0 else b""
        p2 = os.path.join(repo, name)
        cur = open(p2, "rb").read() if os.path.isfile(p2) else b""
        if base == cur:
            continue
        with tempfile.TemporaryDirectory() as d:
            a, b = os.path.join(d, "a"), os.path.join(d, "b")
            open(a, "wb").write(base); open(b, "wb").write(cur)
            out = subprocess.run(["git", "diff", "--no-index", "--no-color", "--no-ext-diff", "-U0", a, b], capture_output=True).stdout.decode("utf-8", "surrogateescape")
        expected[name] = changes(out.split("\n"))
    if mm["bin"] == "coderabbit":
        # WHY the logged argv (r40): the fake models whatever it is asked for, so the mode must be proven from what production passed:
        # `review -t committed --base <ref>`. Any other review type (uncommitted, all) leaves the committed code unreviewed.
        av = model.get("argv") or []
        kind = av[av.index("-t") + 1] if "-t" in av[:-1] else None
        if "review" not in av or kind != "committed" or "--base" not in av:
            reject('the coderabbit call was not a committed review against a base')
        # WHY committed state (r38): production tier R/E reviewed `git diff <base> HEAD`, never the input file. It must have run on a
        # clean tracked tree, at the repo's current HEAD, against a base that adds no .py change beyond the root commit's.
        head = G("rev-parse", "HEAD").strip()
        rootc = root[0] if root else ""
        # WHY re-checked here and not only in the fake: an untracked or modified .py file now is code no commit holds, so the
        # committed diff cannot have covered it (r39).
        if [l for l in G("status", "--porcelain", "--ignored", "-uall", "--", "*.py").splitlines() if l[:2] in ("??", "!!") and not re.search(r"(^|/)(node_modules|\.claude|__pycache__|\.pytest_cache)/", l[3:])] or \
           G("status", "--porcelain", "--untracked-files=no").strip():
            reject('the repo has untracked or modified python files the committed review could not cover')
        # WHY the model-time digest (CodeRabbit r47): the launcher digest is taken at call start, so the code state CodeRabbit really saw must match it too.
        if mm.get("tree") in (None, "none", "") or mm.get("tree") != spies[-1].get("tree_sha256"):
            reject('the coderabbit tree digest does not match the launcher digest')
        if mm.get("dirty") != "0" or mm.get("head") != head or mm.get("base") in (None, "none", "") or not rootc:
            reject('the coderabbit call was dirty, at another head or had no base')
        if subprocess.run(["git", "-C", repo, "diff", "--quiet", rootc, mm["base"], "--", "*.py"]).returncode != 0:
            reject('the coderabbit base adds python changes beyond the root commit')
        # WHY bytes (r41): text=True would turn CRLF into LF while the model event keeps the carriage returns.
        want = G("diff", "--no-color", mm["base"], head, text=False).decode("utf-8", "surrogateescape")
        if want != (model.get("input_text") or ""):
            reject('the coderabbit input is not the committed diff')
        sys.exit(0)
    got = reviewed_changes((spies[-1].get("input_text") or "").split("\n"))
    if set(got) != set(expected) or any(got[n] != expected[n] for n in expected):
        reject('the reviewed changes differ from the code that remains')
    # WHY apply the reviewed patch: matching added/removed lines alone accepts a stale patch whose lines sit at other
    # locations or in other context. Applying the full patch (hunk headers and context included) to the baseline must
    # reproduce every final .py file exactly (r20).
    secs = patch_sections((spies[-1].get("input_text") or "").split("\n"), names)
    if secs is None:
        reject('the reviewed patch is malformed or names files outside the repo')
    with tempfile.TemporaryDirectory() as d:
        for name in names:
            base = b""
            if root:
                r = subprocess.run(["git", "-C", repo, "show", root[0] + ":" + name], capture_output=True)
                base = r.stdout if r.returncode == 0 else b""
            # WHY by existence, not content: an unchanged empty baseline file (an empty __init__.py) must be restored too (r23).
            if root and subprocess.run(["git", "-C", repo, "cat-file", "-e", root[0] + ":" + name], capture_output=True).returncode == 0:
                os.makedirs(os.path.dirname(os.path.join(d, name)) or d, exist_ok=True)
                open(os.path.join(d, name), "wb").write(base)
        patch = "\n".join(l for sec in secs for l in sec)
        patch += "" if patch.endswith("\n") else "\n"
        if secs:
            # WHY --unidiff-zero: a reviewer may legitimately be shown a -U0 diff; the byte comparison below still guards the result (r25b).
            r = subprocess.run(["git", "apply", "-p1", "--whitespace=nowarn", "--unidiff-zero", "-"], input=patch.encode("utf-8", "surrogateescape"), cwd=d, capture_output=True)
            if r.returncode != 0:
                reject('the reviewed patch does not apply to the baseline')
        for name in names:
            p2 = os.path.join(repo, name)
            q = os.path.join(d, name)
            if os.path.isfile(p2) != os.path.isfile(q) or (os.path.isfile(p2) and open(p2, "rb").read() != open(q, "rb").read()):
                reject('the patched baseline differs from the final files')
sys.exit(0)
