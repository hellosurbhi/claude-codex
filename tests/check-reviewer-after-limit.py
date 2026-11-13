# Usage: check-reviewer-after-limit.py <wrapper.jsonl> [--phase implementation] [--plan-file <path>]
# Exit 0 when a fallback reviewer (spy) was STARTED after the Codex wrapper reported the usage limit,
# and the last such review exited 0 with EXACTLY the five clean lines. With --phase, that review was
# called for that phase (a tests-only call does not satisfy "implementation"). With --plan-file, the
# review input is the current non-empty plan file (sha256 equal), so a stale or empty plan fails.
# WHY only the log: transcripts quote docs and agent text; the wrapper log is what actually ran.
import hashlib, os, sys
import wlog
args = sys.argv[1:]
evs = wlog.load(args[0])
phase = args[args.index("--phase") + 1] if "--phase" in args else None
plan = args[args.index("--plan-file") + 1] if "--plan-file" in args else None
non_spy = [e for e in evs if e["wrapper"] != "spy"]
li = wlog.limit_index(non_spy)
if li is None:
    sys.exit(1)
limit_done = non_spy[li]["ts"]
# WHY by start time: a review that began before the quota reply was not a reaction to it, even if it finished later.
spies = sorted((e for e in evs if e["wrapper"] == "spy" and e.get("ts_start", e["ts"]) >= limit_done), key=lambda e: e["ts"])
if not spies or not wlog.is_clean(spies[-1]):
    sys.exit(1)
if phase is not None and spies[-1]["phase"] != phase:
    sys.exit(1)
if plan is not None:
    if not os.path.isfile(plan) or os.path.getsize(plan) == 0:
        sys.exit(1)
    if hashlib.sha256(open(plan, "rb").read()).hexdigest() != spies[-1].get("input_sha256"):
        sys.exit(1)
sys.exit(0)
