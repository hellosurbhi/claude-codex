# Usage (library): import sbx; sbx.run(argv, cwd=None, timeout=10) -> subprocess.CompletedProcess (bytes). Raises OSError when sandbox-exec is unavailable.
# WHY (cc11 r39 CRITICAL): the proof's post-run checkers imported or ran model-written python (app.py, test_app.py, the four modules) with the user's full permissions,
# so a file the agent could write became arbitrary execution after the agent exited. Anything that executes generated code goes through this one function:
# macOS sandbox-exec with default-deny writes (only a fresh private temp dir, and /dev/null and the tty devices), no network, and the owner's credential
# directories unreadable. Fail closed: no sandbox-exec means OSError, which every caller reports as a rejected check, never as a pass.
# WHAT breaks if this is loosened or bypassed: a planted app.py writes outside the scratch dir or spawns a subprocess that does (tests/test-checkers.sh plants both).
import os, shutil, subprocess, sys, tempfile
def run(argv, cwd=None, timeout=10):
    sx = shutil.which("sandbox-exec") or ("/usr/bin/sandbox-exec" if os.access("/usr/bin/sandbox-exec", os.X_OK) else None)
    if not sx:
        raise OSError("sandbox-exec is not available, refusing to run generated code unsandboxed")
    scratch = os.path.realpath(tempfile.mkdtemp(prefix="sbx-run-"))
    home = os.path.realpath(os.path.expanduser("~"))
    prof = ('(version 1)(allow default)(deny network*)(deny file-write*)'
            '(allow file-write* (subpath "%s") (literal "/dev/null") (literal "/dev/tty") (regex #"^/dev/ttys[0-9]+$"))'
            '(deny file-read* (subpath "%s/.ssh") (subpath "%s/.aws") (subpath "%s/.gnupg"))') % (scratch, home, home, home)
    env = dict(os.environ, TMPDIR=scratch, PYTHONDONTWRITEBYTECODE="1")
    try:
        return subprocess.run([sx, "-p", prof] + list(argv), cwd=cwd, timeout=timeout, capture_output=True, env=env)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
