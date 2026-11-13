# Shared reader for the wrapper event log (see evlog.py). Checkers import this and nothing else.
import json, re

VERDICT = r"VERDICT: (APPROVED|WARNING|BLOCKED)"  # the only grammar the skills allow (r14)
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
    lines = [l.rstrip() for l in ev["stdout"].splitlines() if l.strip()]
    # WHY only a LEADING transport line, and only for the Codex wrappers: codex-call.sh prints `THREAD_ID: <id>` first; a
    # reviewer (spy) reply has no such line, so any THREAD_ID text inside it is extra text and must break "clean" (r12).
    if ev["wrapper"] in ("fake", "real") and lines and lines[0].startswith("THREAD_ID: "):
        lines = lines[1:]
    return lines

def is_clean(ev):
    """Clean means the block is EXACTLY a clean reply and nothing else: the Codex form (APPROVED plus four `none`
    lines) or the reviewer.sh form (APPROVED alone: it omits empty severity lines and rejects `none` placeholders)."""
    return ev["exit"] == 0 and verdict_block(ev) in (["VERDICT: APPROVED"], ["VERDICT: APPROVED"] + [s + ": none" for s in SEVS])

def issued_before(evs, i):
    """Thread ids the wrapper itself issued (new, non-resume, successful calls) before event i."""
    # WHY the earlier reply must itself print the id: a call that exited 0 with an empty or malformed reply never
    # returned a thread id, so it cannot seed a resume (r12).
    return {e["thread_id"] for e in evs[:i]
            if not e["resume"] and e["exit"] == 0 and e["thread_id"] and re.search(r"^THREAD_ID: " + re.escape(e["thread_id"]) + r"\s*$", e["stdout"], re.M)}

def limit_index(evs):
    """Index of the first execution that failed with the usage limit, else None."""
    for i, e in enumerate(evs):
        if e["exit"] != 0 and re.search(r"usage limit", e["stdout"] + e["stderr"], re.I):
            return i
    return None
