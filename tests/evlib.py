# Shared helpers for the event checkers.
import re, shlex

_HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n[ \t]*\2[ \t]*(?=\n|$)", re.S)

def _segments(cmd):
    """Split a shell command into simple-command strings at UNQUOTED separators (; & | ( ) newline),
    also descending into $( ... ) and backtick substitutions, wherever they appear."""
    out, cur, i, q = [], [], 0, None
    while i < len(cmd):
        c = cmd[i]
        if c == "\\" and q != "'" and i + 1 < len(cmd):
            cur.append(cmd[i:i + 2]); i += 2; continue
        if q is None and c in "'\"":
            q = c
        elif q == c:
            q = None
        elif q != "'" and c == "$" and cmd[i + 1:i + 2] == "(":
            depth, j = 1, i + 2
            while j < len(cmd) and depth:
                depth += (cmd[j] == "(") - (cmd[j] == ")"); j += 1
            out.extend(_segments(cmd[i + 2:j - 1])); cur.append(cmd[i:j]); i = j; continue
        elif q != "'" and c == "`":
            j = cmd.find("`", i + 1)
            if j > i:
                out.extend(_segments(cmd[i + 1:j])); cur.append(cmd[i:j + 1]); i = j + 1; continue
        elif q is None and c in ";&|()\n":
            out.append("".join(cur)); cur = []; i += 1; continue
        cur.append(c); i += 1
    out.append("".join(cur))
    return [s for s in out if s.strip()]

_PREFIXES = ("bash", "sh", "zsh", "timeout", "env", "time", "nohup", "exec")

def wrapper_runs(cmd):
    """Return the simple commands in cmd that EXECUTE codex-call.sh: its path is the command word
    (after env assignments, shell/timeout/env/nohup prefixes and their options). Quoted text,
    heredoc bodies and commands that only read the path (cat, echo, grep) are not executions.
    Each run is returned as its shell-split word list joined by newlines-free spaces."""
    cmd = _HEREDOC.sub("<<HEREDOC", re.sub(r"\\\n\s*", " ", cmd))
    runs, wrapper_vars = [], set()
    for seg in _segments(cmd):
        try:
            words = shlex.split(seg, posix=True)
        except ValueError:
            continue
        while words:
            a = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)", words[0])
            base = words[0].rsplit("/", 1)[-1]
            if a:
                # a variable assigned the wrapper path and later used as the command word counts as that wrapper
                if a.group(2).endswith("codex-call.sh"):
                    wrapper_vars.add(a.group(1))
                else:
                    wrapper_vars.discard(a.group(1))  # reassigned to something else: no longer the wrapper
                words = words[1:]
            elif base in _PREFIXES:
                words = words[2:] if base == "timeout" and len(words) > 1 else words[1:]
            elif words[0].startswith("-") and not re.fullmatch(r"-[a-z]*c", words[0]):
                words = words[2:] if words[0] in ("-u", "-C", "-S") and len(words) > 1 else words[1:]
            else:
                break
        if words and re.fullmatch(r"-[a-z]*c", words[0]) and len(words) > 1:
            runs.extend(wrapper_runs(words[1]))
            continue
        if words:
            w = words[0]
            v = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", w)
            if w.endswith("codex-call.sh") or (v and v.group(1) in wrapper_vars):
                runs.append(words)
    return runs

def resume_id(run):
    """The id given to --resume as its own argument token. The prompt is one shell-split token, so
    text inside it can never match, whatever options (--cd, --sandbox, --role ...) come before."""
    for i, w in enumerate(run[1:], 1):
        if w.startswith("--resume="):
            v = w.split("=", 1)[1]
        elif w == "--resume" and i + 1 < len(run):
            v = run[i + 1]
        else:
            continue
        return v if re.fullmatch(r"[0-9a-f-]{8,}", v) else None
    return None

def first_limit_cmd_index(ev):
    """Index of the first codex-call.sh EXECUTION whose own reply reports the usage limit."""
    res = {e["id"]: e for e in ev if e["kind"] == "result"}
    for i, e in enumerate(ev):
        if e["kind"] == "cmd" and wrapper_runs(e["text"]):
            r = res.get(e["id"])
            if r and "usage limit" in r["text"].lower():
                return ev.index(r)  # the reply's position: a reviewer must start after the quota reply, not after the command
    return None
