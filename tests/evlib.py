# Shared helpers for the event checkers.
import re, shlex

def wrapper_runs(cmd):
    """Return the simple commands in cmd that EXECUTE codex-call.sh (command word, optionally after
    env assignments, bash/sh/timeout), joined across backslash continuations. Commands that only
    read or quote the path (cat, echo, grep, ls) are not executions."""
    cmd = re.sub(r"\\\n\s*", " ", cmd)
    runs = []
    for part in re.split(r"\n|;|&&|\|\||\||\(|\)", cmd):
        try:
            words = shlex.split(part, posix=True)
        except ValueError:
            words = part.split()
        while words and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]) or words[0] in ("bash", "sh", "timeout", "env", "time", "nohup", "exec")):
            if words[0] == "timeout" and len(words) > 1:
                words = words[2:]
            else:
                words = words[1:]
        if words and words[0].endswith("codex-call.sh"):
            runs.append(part)
    return runs

def resume_id(run):
    m = re.search(r"--resume[ =][\"']?([0-9a-f-]{8,})", re.sub(r"\\\n\s*", " ", run))
    return m.group(1) if m else None
