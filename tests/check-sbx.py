# Usage: check-sbx.py [<dir holding sbx.py>]   Exit 0 only when the sandbox keeps generated code away from processes outside it and still lets it manage its own children.
# WHY (cc11 r60 HIGH): sbx.py once used a bare (allow default), so generated code could signal any process of the same user (the harness, other apps). Each probe below runs through sbx.run,
# the one function every checker uses, and a sleeper started OUTSIDE the sandbox must survive. The same-process-group probe runs in its own session so a failed sandbox cannot kill this checker.
import importlib.util, os, signal, subprocess, sys, time
d = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("sbx", os.path.join(d, "sbx.py")); sbx = importlib.util.module_from_spec(spec); spec.loader.exec_module(sbx)
fails, lines = [], []
# WHY (cc11 r60): the caller shows only the first 240 characters of this output, so a FAIL used to be cut off behind the PASS lines. FAIL and SKIP lines are printed first, each short.
def check(ok, what, detail=""):
    lines.append(("PASS " if ok else "FAIL ") + what + ("" if ok else " [" + detail[:120] + "]"))
    if not ok: fails.append(what)
def skip(what, why): lines.append("SKIP " + what + " (control: " + why + ")")
def report():
    for pre in ("FAIL", "SKIP", "PASS"):
        for l in lines:
            if l.startswith(pre): print(l)
def alive(p): return p.poll() is None
def sleeper(group=False):
    return subprocess.Popen(["sleep", "60"], start_new_session=not group)
if len(sys.argv) > 2 and sys.argv[2] == "pg":  # worker: own session, so a sandbox that fails to confine the group signal only costs this worker
    s = sleeper(group=True)  # same process group as the sandboxed run below
    sbx.run([sys.executable, "-I", "-c", "import os, signal; os.killpg(os.getpgrp(), signal.SIGKILL)"])
    time.sleep(0.5); print("SLEEPER_ALIVE" if alive(s) else "SLEEPER_DEAD"); s.kill(); sys.exit(0)
s = sleeper()
r = sbx.run([sys.executable, "-I", "-c", "import os, signal, sys\ntry:\n    os.kill(int(sys.argv[1]), signal.SIGKILL); print('SIGNALLED')\nexcept PermissionError:\n    print('DENIED')", str(s.pid)])
time.sleep(0.3)
check(b"DENIED" in r.stdout and alive(s), "sandboxed code cannot signal a process started outside the sandbox (the sleeper survives)", repr(r.stdout[-60:]) + repr(r.stderr[-60:]))
s.kill()
r = sbx.run([sys.executable, "-I", "-c", "import subprocess, time\nc = subprocess.Popen(['sleep', '30']); time.sleep(0.2)\nc.terminate(); print('CHILD_RC', c.wait(5))"])
check(b"CHILD_RC -15" in r.stdout, "sandboxed code can still spawn and signal its own child", repr(r.stdout[-60:]) + repr(r.stderr[-60:]))
r = sbx.run([sys.executable, "-I", "-c", "import subprocess\nprint(subprocess.run(['/bin/echo', 'hi'], capture_output=True).stdout)"])
check(b"b'hi\\n'" in r.stdout, "sandboxed code can still run a subprocess and read its output", repr(r.stdout[-60:]) + repr(r.stderr[-60:]))
w = subprocess.run([sys.executable, os.path.abspath(__file__), d, "pg"], capture_output=True, text=True, start_new_session=True, timeout=60)
check("SLEEPER_ALIVE" in w.stdout, "a process-group kill from sandboxed code does not reach an outside process in the same group", (w.stdout + w.stderr)[-120:])
# WHY a control run (cc11 r60): "return 41 + 1" sends no Apple event, so it proved nothing, and a headless runner may have no session or permission for any app. The probe sends a real event to System Events;
# when the same action cannot succeed UNSANDBOXED here, the environment cannot show a block, so it is reported as SKIP with the reason, never PASS or FAIL.
ev = ["/usr/bin/osascript", "-e", 'tell application "System Events" to return name of first process']
try:
    c = subprocess.run(ev, capture_output=True, timeout=20)
    ctl_ok = c.returncode == 0 and c.stdout.strip() != b""
    why = "osascript rc=%d, no Apple event possible here" % c.returncode
except (OSError, subprocess.TimeoutExpired) as e:
    ctl_ok, why = False, "osascript unavailable or blocked: " + type(e).__name__
if ctl_ok:
    r = sbx.run(ev, timeout=30)
    check(not (r.returncode == 0 and r.stdout.strip() != b""), "sandboxed code cannot send Apple events to other applications", "rc=%d out=%r" % (r.returncode, r.stdout[:40]))
else:
    skip("sandboxed code cannot send Apple events to other applications", why)
report()
sys.exit(1 if fails else 0)
