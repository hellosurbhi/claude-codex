# Shared reader for the wrapper event log (see evlog.py). Checkers import this and nothing else.
import json, os, re

VERDICT = r"VERDICT: (APPROVED|WARNING|BLOCKED)"  # the only grammar the skills allow (r14)
SEVS = ("CRITICAL", "HIGH", "MEDIUM", "LOW")

def load(path):
    try:
        return [json.loads(l) for l in open(path) if l.strip()]
    except OSError:
        return []

def is_real(e):
    """A genuine wrapper run: logged by the shim under the installed codex-call.sh (provenance record), with this run's nonce,
    the reviewed wrapper hash and the real Codex binary, never the shim. Fails closed when the expectations are unset (r29)."""
    p = e.get("prov") or {}
    n, w, c = os.environ.get("EVNONCE"), os.environ.get("WRAPPER_SHA256"), os.environ.get("EXPECT_CODEX")
    if e.get("wrapper") != "real" or not (n and w and c):
        return False
    return p.get("argv_ok") is True and p.get("nonce") == n and p.get("wrapper_sha256") == w and p.get("codex") == os.path.realpath(c) and "/shim/" not in (p.get("codex") or "")

def reply_text(ev):
    # WHY both streams for a successful spy: the reviewer reply goes to the caller's chosen output path, so a reply routed
    # to /dev/stderr is logged as stderr; a failed spy keeps diagnostics out of the reply (r23).
    if ev["wrapper"] == "spy" and ev["exit"] == 0:
        return ev["stdout"] + ev.get("stderr", "")
    return ev["stdout"]

def verdict_lines(ev):
    return re.findall(r"^VERDICT:.*$", reply_text(ev), re.M)

def valid_verdict(ev):
    """The single valid VERDICT of an event that exited 0, else None."""
    if ev["exit"] != 0:
        return None
    ls = verdict_lines(ev)
    m = re.fullmatch(VERDICT, ls[0].rstrip()) if len(ls) == 1 else None
    if not m:
        return None
    # WHY the severity lines (cc11-main-r2 finding 4): the skills define a Codex reply as the verdict line plus CRITICAL, HIGH, MEDIUM and
    # LOW lines in that order, and treat a bare verdict as a failed audit. A checker that accepted the bare line could not notice a
    # regression of that rule. reviewer.sh replies (spy, model) are verdict-only or verdict plus findings, so only Codex wrappers need it.
    if ev["wrapper"] in ("fake", "real"):
        heads = [l.split(":", 1)[0] for l in verdict_block(ev) if re.match(r"(CRITICAL|HIGH|MEDIUM|LOW):", l)]
        if heads != list(SEVS):
            return None
    return m.group(1)

def verdict_block(ev):
    """The reply minus the THREAD_ID line, as non-blank lines."""
    lines = [l.rstrip() for l in reply_text(ev).splitlines() if l.strip()]
    # WHY only a LEADING transport line, and only for the Codex wrappers: codex-call.sh prints `THREAD_ID: <id>` first; a
    # reviewer (spy) reply has no such line, so any THREAD_ID text inside it is extra text and must break "clean" (r12).
    if ev["wrapper"] in ("fake", "real") and lines and lines[0].startswith("THREAD_ID: "):
        lines = lines[1:]
    return lines

def is_clean(ev):
    """Clean means the block is EXACTLY a clean reply and nothing else: the Codex form (APPROVED plus four `none`
    lines) or the reviewer.sh form (APPROVED alone: it omits empty severity lines and rejects `none` placeholders)."""
    # WHY per wrapper (CodeRabbit r42): each wrapper has exactly one clean form, so the other wrapper's form must not pass.
    block = verdict_block(ev)
    want = ["VERDICT: APPROVED"] if ev["wrapper"] in ("spy", "model") else ["VERDICT: APPROVED"] + [s + ": none" for s in SEVS]
    return ev["exit"] == 0 and block == want

def issued_before(evs, i):
    """Thread ids the wrapper itself issued (new, non-resume, successful calls) before event i."""
    # WHY the earlier reply must itself print the id: a call that exited 0 with an empty or malformed reply never
    # returned a thread id, so it cannot seed a resume (r12).
    return {e["thread_id"] for e in evs[:i]
            if not e["resume"] and e["exit"] == 0 and e["thread_id"] and re.search(r"^THREAD_ID: " + re.escape(e["thread_id"]) + r"\s*$", e["stdout"], re.M)}

def limit_index(evs):
    """Index of the first execution that failed with the usage limit, else None."""
    # WHY the quota sentence at line start: a diagnostic that merely echoes an argument (a thread named "usage limit") is not a quota error (r28).
    # WHY only fake wrappers and real-wrapper executions (r36): a quota reply from a bare `direct` codex call is not the skill's wrapper
    # call, so it must not anchor the "reviewer ran after the limit" ordering.
    for i, e in enumerate(evs):
        if (e["wrapper"] == "fake" or is_real(e)) and e["exit"] != 0 and re.search(r"^\s*(ERROR:\s*)?You(\'ve| have|\u2019ve) hit your usage limit", e["stdout"] + e["stderr"], re.I | re.M):
            return i
    return None
