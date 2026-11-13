#!/usr/bin/env python3
# Usage: evlog.py <log> <wrapper> <exit> <resume-id-or-empty> <thread-id-or-empty> <phase-source-file> <stdout-file> <stderr-file> -- <argv...>
# Appends ONE JSON line describing one real execution of a stand-in wrapper (fake-codex-call.sh,
# recording-codex-call.sh, spy-reviewer.sh). The checkers assert on this log only.
#
# WHY a wrapper-side log instead of parsing the transcript: the wrapper is the only place that
# knows what was really executed (argv after shell expansion, the thread id it issued or was
# asked to resume, the exact reply). Parsing the model's shell text guessed at all of that and
# every round found a new quoting or continuation form that fooled it. `bash -n` and quoted
# documentation never reach the wrapper, so they never log.
import json, re, sys, time

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
    try:
        n = sum(1 for _ in open(log))
    except OSError:
        n = 0
    ev = {"seq": n + 1, "wrapper": wrapper, "argv": argv, "exit": int(code),
          "resume": resume or None, "thread_id": tid or None,
          "phase": phase_of(rd(phase_file)), "stdout": rd(out_file), "stderr": rd(err_file),
          "ts": time.time()}
    with open(log, "a") as f:
        f.write(json.dumps(ev) + "\n")

if __name__ == "__main__":
    main(sys.argv[1:])
