# Usage: check-reviewer-after-limit.py <wrapper.jsonl> [--phase implementation] [--plan-file <path>] [--repo <dir>]
# Exit 0 when a fallback reviewer (spy) was STARTED after the Codex wrapper reported the usage limit,
# and the last such review exited 0 with EXACTLY the five clean lines. With --phase, that review was
# called for that phase (a tests-only call does not satisfy "implementation"). With --plan-file, the
# review input is the current non-empty plan file (sha256 equal), so a stale or empty plan fails.
# WHY only the log: transcripts quote docs and agent text; the wrapper log is what actually ran.
import hashlib, os, subprocess, sys, tempfile
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

def patch_sections(lines):
    # The .py file sections of a git diff, each starting at its "diff --git" line, kept whole (headers, hunks, context).
    secs, cur = [], None
    for l in lines:
        if l.startswith("diff --git "):
            cur = [l]; secs.append(cur)
        elif cur is not None:
            cur.append(l)
    return [sc for sc in secs if sc[0].split(" b/")[-1].endswith(".py")]

args = sys.argv[1:]
evs = wlog.load(args[0])
phase = args[args.index("--phase") + 1] if "--phase" in args else None
plan = args[args.index("--plan-file") + 1] if "--plan-file" in args else None
repo = args[args.index("--repo") + 1] if "--repo" in args else None
non_spy = [e for e in evs if e["wrapper"] != "spy"]
li = wlog.limit_index(non_spy)
if li is None:
    sys.exit(1)
limit_done = non_spy[li]["ts"]
# WHY by start time: a review that began before the quota reply was not a reaction to it, even if it finished later.
# WHY the LAST review by START time decides: an older approval that merely finished later must not override a newer
# review that blocked or failed (r14).
spies = sorted((e for e in evs if e["wrapper"] == "spy" and e.get("ts_start", e["ts"]) >= limit_done), key=lambda e: e.get("ts_start", e["ts"]))
if not spies or not wlog.is_clean(spies[-1]):
    sys.exit(1)
if phase is not None and spies[-1]["phase"] != phase:
    sys.exit(1)
if plan is not None:
    if not os.path.isfile(plan) or os.path.getsize(plan) == 0:
        sys.exit(1)
    if hashlib.sha256(open(plan, "rb").read()).hexdigest() != spies[-1].get("input_sha256"):
        sys.exit(1)
if repo is not None:
    # WHY an exact digest of the final .py files: the review must cover exactly the code that remains (all modules, paths,
    # indentation and deletions included), so any edit after the approval fails (r15).
    final = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "treehash.py"), repo], capture_output=True, text=True).stdout.strip()
    if not final or spies[-1].get("tree_sha256") != final:
        sys.exit(1)
    # WHY exact per-file changes: the digest pins the code state at review time, but a stale or partial diff would still be
    # "approved". The reviewed input must hold, for every changed .py file and for no other, exactly the added and removed
    # lines (order, indentation and operators intact, only the one-character diff prefix removed) that turn the first
    # commit's file into the file that remains (r16, r17).
    root = subprocess.run(["git", "-C", repo, "rev-list", "--max-parents=0", "HEAD"], capture_output=True, text=True).stdout.split()
    # WHY recursive, with the tree digest's exclusions: a nested module must be covered like a root one (r18).
    names = set()
    for dp, dn, fn in os.walk(repo):
        dn[:] = [d for d in dn if d not in (".git", ".claude", "__pycache__", ".pytest_cache", "node_modules")]
        names |= {os.path.relpath(os.path.join(dp, f), repo) for f in fn if f.endswith(".py")}
    if root:
        names |= {f for f in subprocess.run(["git", "-C", repo, "ls-tree", "-r", "--name-only", root[0]], capture_output=True, text=True).stdout.splitlines() if f.endswith(".py")}
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
            out = subprocess.run(["git", "diff", "--no-index", "--no-color", "--no-ext-diff", "-U0", a, b], capture_output=True, text=True, errors="replace").stdout
        expected[name] = changes(out.splitlines())
    got = reviewed_changes((spies[-1].get("input_text") or "").splitlines())
    if set(got) != set(expected) or any(got[n] != expected[n] for n in expected):
        sys.exit(1)
    # WHY apply the reviewed patch: matching added/removed lines alone accepts a stale patch whose lines sit at other
    # locations or in other context. Applying the full patch (hunk headers and context included) to the baseline must
    # reproduce every final .py file exactly (r20).
    secs = patch_sections((spies[-1].get("input_text") or "").splitlines())
    with tempfile.TemporaryDirectory() as d:
        for name in names:
            base = b""
            if root:
                r = subprocess.run(["git", "-C", repo, "show", root[0] + ":" + name], capture_output=True)
                base = r.stdout if r.returncode == 0 else b""
            if base or name in got:
                os.makedirs(os.path.dirname(os.path.join(d, name)) or d, exist_ok=True)
                if root and subprocess.run(["git", "-C", repo, "cat-file", "-e", root[0] + ":" + name], capture_output=True).returncode == 0:
                    open(os.path.join(d, name), "wb").write(base)
        patch = "\n".join(l for sec in secs for l in sec) + "\n"
        if secs:
            r = subprocess.run(["git", "apply", "--unsafe-paths", "--directory", "", "-p1", "--whitespace=nowarn", "-"], input=patch.encode(), cwd=d, capture_output=True)
            if r.returncode != 0:
                sys.exit(1)
        for name in names:
            p2 = os.path.join(repo, name)
            q = os.path.join(d, name)
            if os.path.isfile(p2) != os.path.isfile(q) or (os.path.isfile(p2) and open(p2, "rb").read() != open(q, "rb").read()):
                sys.exit(1)
sys.exit(0)
