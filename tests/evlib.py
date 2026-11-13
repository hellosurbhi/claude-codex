# Shared helpers for the event checkers.
import re, shlex

_HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n[ \t]*\2[ \t]*(?=\n|$)", re.S)

def wrapper_runs(cmd):
    """Return the simple commands in cmd that EXECUTE codex-call.sh: its path is the command word
    (optionally after env assignments, bash/sh/timeout/env/nohup). Quoted text, heredoc bodies and
    commands that only read the path (cat, echo, grep) are not executions. Backslash continuations
    are joined first and shell separators are honored only outside quotes."""
    cmd = re.sub(r"\\\n\s*", " ", cmd)
    cmd = _HEREDOC.sub("<<HEREDOC", cmd).replace("\n", " ; ")
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=";&|()")
    lex.whitespace_split = True
    lex.commenters = ""
    try:
        toks = list(lex)
    except ValueError:
        return []
    simple, cur = [], []
    for t in toks:
        if t and all(c in ";&|()" for c in t):
            simple.append(cur); cur = []
        else:
            cur.append(t)
    simple.append(cur)
    runs, wrapper_vars = [], set()
    prefixes = ("bash", "sh", "timeout", "env", "time", "nohup", "exec")
    for words in simple:
        while words:
            a = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)", words[0])
            if a:
                # a variable assigned the wrapper path and later used as the command word counts as that wrapper
                if a.group(2).endswith("codex-call.sh"):
                    wrapper_vars.add(a.group(1))
                words = words[1:]
            elif words[0] in prefixes:
                words = words[2:] if words[0] == "timeout" and len(words) > 1 else words[1:]
            elif words[0].startswith("-") and words[0] != "-c":
                # env/bash options such as -u NAME, -i, --
                words = words[2:] if words[0] in ("-u", "-C", "-S") and len(words) > 1 else words[1:]
            else:
                break
        if words and words[0] == "-c" and len(words) > 1:
            runs.extend(wrapper_runs(words[1]))
            continue
        if words:
            w = words[0]
            v = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", w)
            if w.endswith("codex-call.sh") or (v and v.group(1) in wrapper_vars):
                runs.append(" ".join(words))
    return runs

def resume_id(run):
    m = re.search(r"--resume[ =]([0-9a-f-]{8,})", run)
    return m.group(1) if m else None

def first_limit_cmd_index(ev):
    """Index of the first codex-call.sh EXECUTION whose own reply reports the usage limit."""
    res = {e["id"]: e for e in ev if e["kind"] == "result"}
    for i, e in enumerate(ev):
        if e["kind"] == "cmd" and wrapper_runs(e["text"]):
            r = res.get(e["id"])
            if r and "usage limit" in r["text"].lower():
                return ev.index(r)  # the reply's position: a reviewer must start after the quota reply, not after the command
    return None

def good_reply(r):
    """A reply usable as evidence: present and not a failed tool result."""
    return bool(r) and not r.get("error")
