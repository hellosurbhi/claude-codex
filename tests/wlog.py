# Shared reader for the wrapper event log (see evlog.py). Checkers import this and nothing else.
import json, re

VERDICT = r"VERDICT: (APPROVED|WARNING|BLOCKED|CLEAN|FINDINGS)"
SEVS = ("CRITICAL", "HIGH", "MEDIUM", "LOW")

def load(path):
    try:
        return [json.loads(l) for l in open(path) if l.strip()]
    except OSError:
        return []

def verdict_lines(ev):
    return re.findall(r"^VERDICT:.*$", ev["stdout"], re.M)

def valid_verdict(ev):
    """The single valid VERDICT of an event that exited 0, else None."""
    if ev["exit"] != 0:
        return None
    ls = verdict_lines(ev)
    m = re.fullmatch(VERDICT, ls[0].rstrip()) if len(ls) == 1 else None
    return m.group(1) if m else None

def verdict_block(ev):
    """The reply minus the THREAD_ID line, as non-blank lines."""
    return [l.rstrip() for l in ev["stdout"].splitlines() if l.strip() and not l.startswith("THREAD_ID:")]

def is_clean(ev):
    """Clean means the block is EXACTLY the clean lines and nothing else."""
    return ev["exit"] == 0 and verdict_block(ev) == ["VERDICT: APPROVED"] + [s + ": none" for s in SEVS]

def issued_before(evs, i):
    """Thread ids the wrapper itself issued (new, non-resume, successful calls) before event i."""
    return {e["thread_id"] for e in evs[:i] if not e["resume"] and e["exit"] == 0 and e["thread_id"]}

def limit_index(evs):
    """Index of the first execution that failed with the usage limit, else None."""
    for i, e in enumerate(evs):
        if e["exit"] != 0 and re.search(r"usage limit", e["stdout"] + e["stderr"], re.I):
            return i
    return None
