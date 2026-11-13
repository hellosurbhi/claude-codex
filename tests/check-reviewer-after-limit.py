# Usage: check-reviewer-after-limit.py <wrapper.jsonl> [--phase implementation] [--agent <events.jsonl>]
# Exit 0 when, AFTER the Codex wrapper reported the usage limit, the last fallback review was a
# clean one for the right phase.
#   Default: the last spy-reviewer execution after the limit exited 0, returned a block that is
#   EXACTLY the five clean lines (no extra finding text), and, with --phase, was called for that
#   phase (a tests-only call does not satisfy "implementation").
#   --agent: for workflows whose final review is a Claude code-reviewer Task agent (it cannot log
#   to the wrapper). The log still proves the quota hit; the LAST review agent started after the
#   quota reply must have been given the implementation and returned exactly the five clean lines.
import json, re, sys
import wlog
args = sys.argv[1:]
evs = wlog.load(args[0])
phase = args[args.index("--phase") + 1] if "--phase" in args else None
li = wlog.limit_index([e for e in evs if e["wrapper"] != "spy"])
if li is None:
    sys.exit(1)
if "--agent" not in args:
    spies = [e for e in evs if e["wrapper"] == "spy"]
    # WHY after the limit by sequence: the shared log orders every execution, so a spy run that
    # happened before the quota hit cannot count.
    limit_seq = [e for e in evs if e["wrapper"] != "spy"][li]["seq"]
    spies = [e for e in spies if e["seq"] > limit_seq]
    sys.exit(0 if spies and wlog.is_clean(spies[-1]) and (phase is None or spies[-1]["phase"] == phase) else 1)
tr = [json.loads(l) for l in open(args[args.index("--agent") + 1]) if l.strip()]
# Position of the first tool RESULT (never a command) that carries the quota error.
cut = next((i for i, e in enumerate(tr) if e["kind"] == "result" and re.search(r"usage limit", e["text"], re.I)), None)
if cut is None:
    sys.exit(1)
last_ok = None
for i, e in enumerate(tr):
    if i <= cut or e["kind"] != "agent":
        continue
    try:
        inp = json.loads(e["text"])
    except ValueError:
        continue
    if "review" not in str(inp.get("subagent_type", "")).lower():
        continue
    gets_impl = re.search(r"app\.py|def add|implementation", json.dumps(inp), re.I) is not None
    res = next((r for r in tr[i + 1:] if r["kind"] == "result" and r["id"] == e["id"] and not r.get("error")), None)
    lines = [l.strip() for l in (res["text"].splitlines() if res else []) if l.strip()]
    last_ok = gets_impl and lines == ["VERDICT: APPROVED"] + [s + ": none" for s in wlog.SEVS]
sys.exit(0 if last_ok else 1)
