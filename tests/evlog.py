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
# WHY the explicit path: the wrappers run this file as `python3 -I evlog.py`, and -I drops the script's folder from sys.path, so a bare `from gitpath import` failed and no event was logged.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gitpath import diff_git_paths

def _is_test_path(path):
    base = os.path.basename(path)
    return bool(re.match(r"test_|tests?\.py$", base) or base.endswith("_test.py") or "/tests/" in "/" + path or "/test/" in "/" + path)

def phase_of(text):
    # Phase comes from what the wrapper actually received: a diff or plan file for the reviewer
    # spy, the prompt for the Codex wrappers.
    # WHY the changed paths decide for a diff, not code text: a diff that touches a non-test .py file is the implementation
    # phase however the function is written (`def add (a, b)`, a lambda, ...), and a diff of test files only is the tests
    # phase even when a test body contains `return a + b` (r24).
    # WHY both sides (CodeRabbit r42): a rename test_app.py -> app.py has a test old path but an implementation new path.
    # WHY the same-path form first (r27): a path with spaces ("my mod.py") is not \S+, so its diff was classified "unknown"; a same-path edit names one path twice, which the backreference matches.
    # WHY decoded through gitpath (r51): a quoted header ("a/caf\303\251.py") matched neither form above, so a diff of that file beside test_app.py was classified tests-only.
    lines = text.split("\n")
    paths = [p for i, l in enumerate(lines) for pair in [diff_git_paths(l, lines[i + 1:])] if pair for p in pair if p.endswith(".py")]
    if paths:
        return "implementation" if any(not _is_test_path(x) for x in paths) else "tests"
    # WHY the plan marker is checked BEFORE the signature (CodeRabbit thread 7): a plan that quotes `def add(a, b):` was classified as the
    # implementation, so a later --phase plan check rejected a correct plan review. Diff-path classification above stays first.
    if re.search(r"\.claude/plan|<!--\s*review-fix|^#{1,3} .*\bplan\b", text, re.I | re.M) and not re.search(r"^diff --git|^\+\+\+ ", text, re.M):
        return "plan"
    if re.search(r"def\s+add\s*\(", text):
        return "implementation"
    if re.search(r"\btests?\b|assert|test_", text, re.I):
        return "tests"
    return "unknown"

def main(a):
    i = a.index("--")
    log, wrapper, code, resume, tid, phase_file, out_file, err_file = a[:8]
    argv = a[i + 1:]
    def rb(p):
        # WHY tolerant of a missing file: a failed call (for example a missing input) must still be logged, or an
        # earlier approval would stand as if the failed call never happened (r14).
        try:
            return open(p, "rb").read() if p and p != "-" else b""
        except OSError:
            return b""
    rd = lambda p: rb(p).decode(errors="replace")
    phase_raw = rb(phase_file)
    # WHY surrogateescape (r27): errors="replace" turned a non-UTF-8 byte into U+FFFD, so the logged reviewer input could never equal the bytes the reviewer was given; the checker maps it back with the same codec.
    phase_text = phase_raw.decode("utf-8", "surrogateescape")
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
              # WHY raw bytes: the plan checker hashes the file as written, so CRLF or odd bytes must not change the digest (r14).
              "input_sha256": hashlib.sha256(phase_raw).hexdigest(), "input_bytes": len(phase_raw),
              "input_text": phase_text if wrapper in ("spy", "model") else None,
              "prov": json.loads(os.environ["EV_PROV"]) if os.environ.get("EV_PROV") else None,
              "tree_sha256": os.environ.get("TREE_SHA256") or None,
              "meta": dict(kv.split("=", 1) for kv in (os.environ.get("EV_META") or "").split() if "=" in kv),
              "ts_start": float(os.environ.get("EVSTART") or time.time()), "ts": time.time()}
        f.write(json.dumps(ev) + "\n")
        f.flush()
        fcntl.flock(f, fcntl.LOCK_UN)

if __name__ == "__main__":
    main(sys.argv[1:])
