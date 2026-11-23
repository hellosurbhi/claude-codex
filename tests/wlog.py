# Shared reader for the wrapper event log (see evlog.py). Checkers import this and nothing else.
import json, os, re

VERDICT = r"VERDICT: (APPROVED|WARNING|BLOCKED)"  # the only grammar the skills allow (r14)

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

def is_wrapper_failure(e):
    """An event the real codex-call.sh wrote for an exit that never reached codex (CODEX_CALL_EVENT_LOG). Carries this run's nonce when one is set."""
    n = os.environ.get("EVNONCE")
    return e.get("wrapper") == "wrapper-failed" and (not n or (e.get("meta") or {}).get("nonce") == n)

# WHY the production fallback banner is dropped, and only from the START of a spy's stdout: reviewer.sh log_fallback prints one loud
# "!!! REVIEWER FALLBACK: <primary> FAILED (<reason>) - this review was produced by <model> (tier <T>)" line on STDOUT whenever a later
# reviewer in the chain answers after Codex failed. The installed script puts CodeRabbit first for tier R, so no banner appeared; the
# consolidated script runs Codex, Gemini, CodeRabbit for E and R alike, so every tier R review after a quota hit carries it. The verdict
# itself is still the file production wrote, and it must still be the only remaining content. What breaks if this is widened: a banner
# in the middle of a reply, or any other prose before the verdict, would stop counting as extra text. Hence anchored, one line, once.
FALLBACK_BANNER = re.compile(r"\A!!! REVIEWER FALLBACK: \S+ FAILED \([^()\n]*\) \u2014 this review was produced by \S+ \(tier [ERS]\)\n")

def reply_text(ev):
    # WHY both streams for a successful spy: the reviewer reply goes to the caller's chosen output path, so a reply routed
    # to /dev/stderr is logged as stderr; a failed spy keeps diagnostics out of the reply (r23).
    if ev["wrapper"] == "spy" and ev["exit"] == 0:
        return FALLBACK_BANNER.sub("", ev["stdout"], count=1) + ev.get("stderr", "")
    return ev["stdout"]

def verdict_lines(ev):
    return re.findall(r"^VERDICT:.*$", reply_text(ev), re.M)

SEV_HEAD = re.compile(r"(CRITICAL|HIGH|MEDIUM|LOW):[ \t]*(.*)")
PLACEHOLDER = re.compile(r"(none|n/a)\.?", re.I)

def verdict_state(text):
    """THE verdict grammar (one function, used by every checker). Returns "clean", "findings" or "no-verdict".
    The first non-blank line must be exactly VERDICT: APPROVED, WARNING or BLOCKED; any other VERDICT: line is no verdict, and so is
    empty or unparseable output. Severity lines are optional; a header with empty text takes the next non-blank NON-HEADER line as its
    text, and with none (end of output, or another header comes next) the whole output is no verdict; the placeholder text none or n/a
    (any case, optional trailing period) is ignored. Any real finding, or any verdict word but APPROVED, is "findings". Only APPROVED
    with no real finding is "clean"."""
    # WHY (round 3 finding 1): the global review contract tells the reviewer to OMIT empty severity lines and to answer a clean review as exactly
    # `VERDICT: APPROVED`, so requiring four severity lines made every compliant reviewer look broken. Tolerating `none` keeps older replies valid.
    # WHY an empty header with nothing after it is NO VERDICT, not clean (round 4 finding 3): it is neither an omitted severity line nor an explicit
    # placeholder, and it can be a finding cut off mid-reply, so certifying clean would approve what was never read. Re-asking costs one call.
    # The two other choices stay conservative on purpose: a verdict word but APPROVED is "findings" and prose no header consumed is "findings", both fail toward "not clean".
    # WHY real findings beat the verdict word (finding 2): `VERDICT: APPROVED` beside a populated CRITICAL or HIGH must never read as a clean round.
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    if not lines:
        return "no-verdict"
    m = re.fullmatch(VERDICT, lines[0])
    if not m or any(l.startswith("VERDICT:") for l in lines[1:]):
        return "no-verdict"
    found = False
    i = 1
    while i < len(lines):
        h = SEV_HEAD.fullmatch(lines[i])
        if h:
            body = h.group(2).strip()
            if not body:
                if i + 1 >= len(lines) or SEV_HEAD.fullmatch(lines[i + 1]):
                    return "no-verdict"
                i += 1
                body = lines[i]
            if body and not PLACEHOLDER.fullmatch(body):
                found = True
        else:
            found = True  # prose or a continuation line that no placeholder header consumed is content, never clean
        i += 1
    return "findings" if found or m.group(1) != "APPROVED" else "clean"

def valid_verdict(ev):
    """The verdict word of an event that exited 0 and holds a verdict (clean or findings), else None."""
    if ev["exit"] != 0:
        return None
    text = "\n".join(verdict_block(ev))
    return re.match(VERDICT, text.lstrip()).group(1) if verdict_state(text) != "no-verdict" else None

def verdict_block(ev):
    """The reply minus the THREAD_ID line, as non-blank lines."""
    lines = [l.rstrip() for l in reply_text(ev).splitlines() if l.strip()]
    # WHY only a LEADING transport line, and only for the Codex wrappers: codex-call.sh prints `THREAD_ID: <id>` first; a
    # reviewer (spy) reply has no such line, so any THREAD_ID text inside it is extra text and must break "clean" (r12).
    if ev["wrapper"] in ("fake", "real") and lines and lines[0].startswith("THREAD_ID: "):
        lines = lines[1:]
    return lines

def is_clean(ev):
    """Clean means the grammar says clean: APPROVED with no real finding, whichever wrapper produced it, and the call exited 0."""
    return ev["exit"] == 0 and verdict_state("\n".join(verdict_block(ev))) == "clean"

def started(e):
    """THE ordering key of an event: (start time, log position). Every writer takes its start time from the same source, the wall clock of python's time.time()
    (evlog.py via EVSTART for the shim, the fake and the spy; codex-call.sh's wrapper-failed event from python3 time.time(), `date` only when python3 itself is missing),
    so events of different kinds are comparable; the log position (seq) only breaks ties."""
    return (e.get("ts_start", e["ts"]), e.get("seq", 0))

def review_attempts(events):
    """EVERY review attempt of every authenticated kind, in start order: the scripted fake, the genuine real-codex shim events, a wrapper-failed event of the real wrapper,
    and the fallback reviewer (spy, `diagnose` excluded: it is not a review). A bare `direct` codex call, the model stand-ins and anything else are not attempts.
    WHY no mode here (r26): a flag that dropped a kind of attempt let a failed REAL review after a clean fallback leave the approval standing."""
    def attempt(e):
        w = e["wrapper"]
        if w == "spy":
            return (e.get("argv") or [""])[0] != "diagnose"
        return is_wrapper_failure(e) or w == "fake" or is_real(e)
    return sorted((e for e in events if attempt(e)), key=started)

def final_review_state(events, real=False):
    """The ONE decision "this run ended approved": the LAST review attempt of any kind exited 0 with a clean verdict, and that attempt is valid approving evidence. Returns {"approved": bool, "last": event or None}.
    Every checker that decides approval calls this and then adds its own binding (state, phase, tree) on `last`; none may filter attempts itself.
    WHY all kinds in one list (r25, r26): choosing the final review inside a filtered list (spy only, Codex only) let an earlier clean review stand after a LATER failed attempt of another kind.
    `real` only chooses which clean attempt may be the approval: the spy fallback always may; a scripted fake only when real is False; a genuine real-codex event only when real is True.
    It never hides a failure: every kind is in the list that decides which attempt is last."""
    att = review_attempts(events)
    last = att[-1] if att else None
    evidence = bool(last) and (last["wrapper"] == "spy" or (is_real(last) if real else last["wrapper"] == "fake"))
    return {"approved": bool(last and evidence and is_clean(last)), "last": last}

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
