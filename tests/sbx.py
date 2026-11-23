# Usage (library): import sbx; sbx.run(argv, cwd=None, timeout=10) -> subprocess.CompletedProcess (bytes). Raises OSError when sandbox-exec is unavailable.
# WHY (cc11 r39 CRITICAL): the proof's post-run checkers imported or ran model-written python (app.py, test_app.py, the four modules) with the user's full permissions,
# so a file the agent could write became arbitrary execution after the agent exited. Anything that executes generated code goes through this one function:
# macOS sandbox-exec with default-deny writes (only a fresh private temp dir, and /dev/null and the tty devices), no network, and the owner's credential
# directories unreadable. Fail closed: no sandbox-exec means OSError, which every caller reports as a rejected check, never as a pass.
# WHAT breaks if this is loosened or bypassed: a planted app.py writes outside the scratch dir or spawns a subprocess that does (tests/test-checkers.sh plants both).
import os, shutil, subprocess, sys, tempfile
# WHY (cc11 r60 HIGH): (allow default) also leaves open everything that reaches OTHER processes or the desktop, so generated code could kill the harness or any app of the same user (os.kill, os.killpg).
# Tried first: only denying file-write and network, which looked complete but is not, because signals are not file operations. Fix: deny the classes below, each probed on this macOS to leave
# a plain python, a subprocess and unittest working (tests/check-sbx.py proves the signal cases, and tests/test-checkers.sh runs the real checkers through it).
# DENIED: signal to anything outside the sandbox (same-sandbox targets stay allowed, so the code can still spawn and terminate its own children, and a group kill cannot leave the sandbox),
#   process-info of other processes, sysctl-write, iokit-open and iokit-set-properties, system-socket, SysV and POSIX shared memory, mach-register, nvram, preference writes, Apple events,
#   lsopen (launching apps), hid-control, job-creation (launchd jobs), file-mount, authorization rights.
# STAYS OPEN, and why: mach-lookup (python, getpwuid and DNS-free libc paths need a dozen system services and the list changes per macOS release, so an allowlist would break legitimate runs
#   on the next update; the one thing it could reach, launchctl submit, is covered by job-creation and was verified to start nothing), file-read outside the credential dirs (the checkers read the repo),
#   process-exec and fork (the code runs subprocesses by design, and they inherit this same profile).
# WHAT breaks if this is loosened: a planted app.py signals the harness process group or a user app. If a deny is added that breaks a run, extend tests/check-sbx.py with that run first.
OUTSIDE_DENIES = ('(deny signal)(allow signal (target same-sandbox))(deny process-info* (target others))(deny sysctl-write)(deny iokit-open)(deny iokit-set-properties)'
                  '(deny system-socket)(deny ipc-posix-shm*)(deny ipc-sysv*)(deny mach-register)(deny nvram*)(deny user-preference-write)(deny appleevent-send)(deny lsopen)'
                  '(deny hid-control)(deny job-creation)(deny file-mount)(deny authorization-right-obtain)')
def run(argv, cwd=None, timeout=10):
    sx = shutil.which("sandbox-exec") or ("/usr/bin/sandbox-exec" if os.access("/usr/bin/sandbox-exec", os.X_OK) else None)
    if not sx:
        raise OSError("sandbox-exec is not available, refusing to run generated code unsandboxed")
    scratch = os.path.realpath(tempfile.mkdtemp(prefix="sbx-run-"))
    home = os.path.realpath(os.path.expanduser("~"))
    prof = ('(version 1)(allow default)(deny network*)(deny file-write*)'
            '(allow file-write* (subpath "%s") (literal "/dev/null") (literal "/dev/tty") (regex #"^/dev/ttys[0-9]+$"))'
            '(deny file-read* (subpath "%s/.ssh") (subpath "%s/.aws") (subpath "%s/.gnupg"))' + OUTSIDE_DENIES) % (scratch, home, home, home)
    env = dict(os.environ, TMPDIR=scratch, PYTHONDONTWRITEBYTECODE="1")
    try:
        return subprocess.run([sx, "-p", prof] + list(argv), cwd=cwd, timeout=timeout, capture_output=True, env=env)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
