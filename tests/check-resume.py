# Usage: check-resume.py <wrapper.jsonl> [--no-verdict]. Exit 0 when the wrapper log holds a --resume
# execution that exited 0, returned the same thread id it was asked to resume, and that id was
# issued by the wrapper itself in an EARLIER non-resume execution of this run. Unless --no-verdict
# (execute-codex: Codex implements, so a follow-up reply has no verdict), the reply must carry
# exactly one valid VERDICT line. Quoted examples, `bash -n` and variable-held ids never matter:
# only what the wrapper really executed is in the log.
import re, sys
import wlog
evs = wlog.load(sys.argv[1])
noverdict = "--no-verdict" in sys.argv
for i, e in enumerate(evs):
    if not e["resume"] or e["exit"] != 0 or e["wrapper"] not in ("fake", "real"):
        continue
    tids = re.findall(r"^THREAD_ID: (\S+)", e["stdout"], re.M)
    if tids != [e["resume"]] or e["resume"] not in wlog.issued_before(evs, i):
        continue
    if noverdict:
        # WHY optional, not forbidden: a follow-up reply may carry one valid verdict or none, but never an invalid or repeated one.
        if (not wlog.verdict_lines(e) and wlog.verdict_block(e)) or wlog.valid_verdict(e):
            sys.exit(0)
    elif wlog.valid_verdict(e):
        sys.exit(0)
sys.exit(1)
