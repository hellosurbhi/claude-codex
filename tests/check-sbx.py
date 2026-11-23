# Usage: check-sbx.py [<dir holding sbx.py>]   Exit 0 only when the sandbox keeps generated code away from processes outside it and still lets it manage its own children.
# WHY (cc11 r60 HIGH): sbx.py once used a bare (allow default), so generated code could signal any process of the same user (the harness, other apps). Each probe below runs through sbx.run,
# the one function every checker uses, and a sleeper started OUTSIDE the sandbox must survive. The same-process-group probe runs in its own session so a failed sandbox cannot kill this checker.
import importlib.util, os, signal, subprocess, sys, time
d = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("sbx", os.path.join(d, "sbx.py")); sbx = importlib.util.module_from_spec(spec); spec.loader.exec_module(sbx)
fails = []
def check(ok, what):
    print(("PASS " if ok else "FAIL ") + what)
    if not ok: fails.append(what)
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
check(b"DENIED" in r.stdout and alive(s), "sandboxed code cannot signal a process started outside the sandbox (the sleeper survives)")
s.kill()
r = sbx.run([sys.executable, "-I", "-c", "import subprocess, time\nc = subprocess.Popen(['sleep', '30']); time.sleep(0.2)\nc.terminate(); print('CHILD_RC', c.wait(5))"])
check(b"CHILD_RC -15" in r.stdout, "sandboxed code can still spawn and signal its own child")
r = sbx.run([sys.executable, "-I", "-c", "import subprocess\nprint(subprocess.run(['/bin/echo', 'hi'], capture_output=True).stdout)"])
check(b"b'hi\\n'" in r.stdout, "sandboxed code can still run a subprocess and read its output")
w = subprocess.run([sys.executable, os.path.abspath(__file__), d, "pg"], capture_output=True, text=True, start_new_session=True, timeout=60)
check("SLEEPER_ALIVE" in w.stdout, "a process-group kill from sandboxed code does not reach an outside process in the same group")
if os.path.exists("/usr/bin/osascript"):
    r = sbx.run(["/usr/bin/osascript", "-e", "return 41 + 1"])
    check(r.stdout.strip() != b"42", "sandboxed code cannot drive other applications through AppleScript (Apple events)")
sys.exit(1 if fails else 0)
