# Usage: check-resume.py <events.txt>. Exit 0 when a --resume call returned on a thread an earlier
# non-resume call created, with exactly that THREAD_ID and exactly one valid VERDICT line.
import re, sys
ev = re.split(r"\n(?=(?:CMD|OUT) )", open(sys.argv[1]).read())
# pair each command with the next tool result; a backslash-newline continuation is joined first
pairs = []
for i, e in enumerate(ev):
    if e.startswith("CMD "):
        out = next((x for x in ev[i+1:] if x.startswith("OUT ")), "")
        pairs.append((re.sub(r"\\\n\s*", " ", e), out))
initial = set()
for cmd, out in pairs:
    if "codex-call.sh" in cmd and "--resume" not in cmd:
        initial.update(re.findall(r"THREAD_ID: ([0-9a-f-]{8,})", out))
ok = False
for cmd, out in pairs:
    m = re.search(r"codex-call\.sh.* --resume ([0-9a-f-]{8,})", cmd)
    if not m or m.group(1) not in initial: continue
    tids = re.findall(r"THREAD_ID: ([0-9a-f-]{8,})", out)
    verds = re.findall(r"^VERDICT: ([A-Z]+)\s*$", out, re.M)
    if tids == [m.group(1)] and len(verds) == 1 and verds[0] in ("APPROVED","WARNING","BLOCKED","CLEAN","FINDINGS"):
        ok = True
sys.exit(0 if ok else 1)
