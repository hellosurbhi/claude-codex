#!/usr/bin/env python3
# Usage: evlog.py <log> <wrapper> <exit> <resume-id-or-empty> <thread-id-or-empty> <phase-source-file> <stdout-file> <stderr-file> -- <argv...>
# Appends ONE JSON line describing one real execution of a stand-in wrapper (fake-codex-call.sh,
# shim/codex, spy-reviewer.sh). The checkers assert on this log only.
#
# WHY a wrapper-side log instead of parsing the transcript: the wrapper is the only place that
# knows what was really executed (argv after shell expansion, the thread id it issued or was
# asked to resume, the exact reply). Parsing the model's shell text guessed at all of that and
# every round found a new quoting or continuation form that fooled it. `bash -n` and quoted
# documentation never reach the wrapper, so they never log.
import fcntl, hashlib, json, os, re, sys, time

def phase_of(text):
    # Phase comes from what the wrapper actually received: a diff or plan file for the reviewer
    # spy, the prompt for the Codex wrappers. Implementation wins over tests: a diff holding
    # both the tests and `def add` is the implementation phase.
    if re.search(r"def add\(|return\s+\w+\s*\+\s*\w+", text):
        return "implementation"
    if re.search(r"\.claude/plan|<!--\s*review-fix|^#{1,3} .*\bplan\b", text, re.I | re.M) and not re.search(r"^diff --git|^\+\+\+ ", text, re.M):
        return "plan"
    if re.search(r"\btests?\b|assert|test_", text, re.I):
        return "tests"
    return "unknown"

def main(a):
    i = a.index("--")
    log, wrapper, code, resume, tid, phase_file, out_file, err_file = a[:8]
    argv = a[i + 1:]
    rd = lambda p: open(p, errors="replace").read() if p and p != "-" else ""
    phase_text = rd(phase_file)
    # WHY a lock around reading the count and appending: concurrent wrappers must not get the same
    # sequence number (r12). ts_start is when the wrapper began (EVSTART), ts when it finished, so a
    # checker can order a review against a quota failure by START, not by completion.
    with open(log, "a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        n = sum(1 for _ in f)
        ev = {"seq": n + 1, "wrapper": wrapper, "argv": argv, "exit": int(code),
              "resume": resume or None, "thread_id": tid or None,
              "phase": phase_of(phase_text), "stdout": rd(out_file), "stderr": rd(err_file),
              "input_sha256": hashlib.sha256(phase_text.encode()).hexdigest(), "input_bytes": len(phase_text.encode()),
              "ts_start": float(os.environ.get("EVSTART") or time.time()), "ts": time.time()}
        f.write(json.dumps(ev) + "\n")
        f.flush()
        fcntl.flock(f, fcntl.LOCK_UN)

if __name__ == "__main__":
    main(sys.argv[1:])
