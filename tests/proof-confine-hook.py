#!/usr/bin/env python3
# PreToolUse hook that confines the real-proof Claude session (tests/review-loop-proof.sh) to its scratch repo. DENY BY DEFAULT.
# Reads one hook JSON object on stdin, prints one hook decision JSON on stdout, and appends one line per decision to $PROOF_HOOK_LOG.
# Needs PROOF_SCRATCH_ROOT (the scratch repo). Without it, or on ANY internal error, everything is denied (fail closed).
#
# WHY this exists (cc11 bypass review): a headless `claude -p` run denies edits to an existing .claude/plan file in every other permission mode, so the proof runs with
# prompts off (bypassPermissions). Probed with claude 2.1.323: a PreToolUse hook still runs, and still denies, under bypassPermissions. This hook is then the ONLY
# gate, so it allows exactly what the skills and the proof need and nothing else: reads and edits whose resolved real path is inside the scratch repo, whole Bash
# commands made of the prescribed wrapper scripts and a few read-only helpers, and the Skill/Task/Agent tools. What breaks if it is loosened: the agent runs unprompted
# on the owner's machine with nothing between it and the home directory. The start-up probe in review-loop-proof.sh feeds an out-of-bounds call straight to this file.
import json, os, re, sys

ROOT = ""
HOME = os.path.realpath(os.path.expanduser("~"))
SCRIPTS = os.path.join(HOME, ".claude", "config", "scripts")
# the wrappers the skills prescribe (codex-call, reviewer, review-snapshot, redact-diff); arguments after them are the skill's own
WRAPPERS = {os.path.join(SCRIPTS, n) for n in ("codex-call.sh", "reviewer.sh", "review-snapshot.sh", "redact-diff.sh")}
READ_ONLY_EXTRA = [os.path.join(HOME, ".claude", "skills"), os.path.join(SCRIPTS, "codex-call.sh")]
READERS = {"cat", "head", "tail", "ls", "wc", "test", "[", "grep", "diff", "file", "stat"}
GIT_READ = {"status", "diff", "log", "show", "rev-parse", "ls-files", "branch", "cat-file", "rev-list"}

class Deny(Exception):
    pass

def real(p):
    # the real path with every symlink resolved; a not-yet-existing tail is resolved through its existing parent
    p = os.path.expanduser(p)
    if not os.path.isabs(p):
        p = os.path.join(CWD, p)
    return os.path.realpath(p)

def inside(p, base):
    return p == base or p.startswith(base.rstrip(os.sep) + os.sep)

def in_root(p):
    return bool(ROOT) and inside(real(p), ROOT)

def readable(p):
    r = real(p)
    return inside(r, ROOT) or any(inside(r, real(x)) for x in READ_ONLY_EXTRA)

def lex(cmd):
    """Split a bash command into simple commands. Returns [(argv, redirects)] and raises Deny on anything not understood.
    Understood: single and double quotes, `;` `&&` `||` `|` newline, `>` `>>` `<` with a word target, `2>&1`, quoted-delimiter heredocs.
    Never understood (denied): $( ) ${ } backticks, process substitution, background `&`, unquoted heredoc delimiter, unterminated quotes."""
    cmds, argv, reds = [], [], []
    word, have, i, n = "", False, 0, len(cmd)
    pending_heredocs = []
    def end_word():
        nonlocal word, have
        if have:
            argv.append(word)
        word, have = "", False
    def end_cmd():
        nonlocal argv, reds
        end_word()
        if argv or reds:
            cmds.append((argv, reds))
        argv, reds = [], []
    while i < n:
        c = cmd[i]
        if c == "'":
            j = cmd.find("'", i + 1)
            if j < 0:
                raise Deny("unterminated single quote")
            word += cmd[i + 1:j]; have = True; i = j + 1
        elif c == '"':
            j = i + 1; buf = ""
            while j < n and cmd[j] != '"':
                if cmd[j] == "\\" and j + 1 < n and cmd[j + 1] in '"\\$`':
                    buf += cmd[j + 1]; j += 2; continue
                if cmd[j] == "`" or cmd.startswith("$(", j) or cmd.startswith("${", j):
                    raise Deny("command or variable substitution inside double quotes")
                buf += cmd[j]; j += 1
            if j >= n:
                raise Deny("unterminated double quote")
            word += buf; have = True; i = j + 1
        elif c == "\\":
            if i + 1 < n and cmd[i + 1] != "\n":
                word += cmd[i + 1]; have = True; i += 2
            else:
                raise Deny("line continuation or trailing backslash")
        elif c in "`":
            raise Deny("backtick substitution")
        elif c == "$":
            if cmd.startswith("$?", i) and not have:
                word += "0"; have = True; i += 2
            else:
                raise Deny("variable or command substitution")
        elif c in "()":
            raise Deny("subshell or process substitution")
        elif c == "&":
            if cmd.startswith("&&", i):
                end_cmd(); i += 2
            elif cmd.startswith(">&", i - 1) and i > 0 and cmd[i - 1] == ">":
                raise Deny("unexpected &")
            else:
                raise Deny("background or bare &")
        elif c == "|":
            end_cmd(); i += 2 if cmd.startswith("||", i) else 1
        elif c == ";":
            end_cmd(); i += 1
        elif c == "\n":
            end_cmd(); i += 1
            if pending_heredocs:
                for delim in pending_heredocs:
                    m = re.compile(r"^" + re.escape(delim) + r"[ \t]*$", re.M).search(cmd, i)
                    if not m:
                        raise Deny("heredoc without its terminator")
                    i = m.end() + 1 if m.end() < n else n
                pending_heredocs = []
        elif c in " \t":
            end_word(); i += 1
        elif c == ">" or c == "<" or (c.isdigit() and not have and i + 1 < n and cmd[i + 1] in "<>" and cmd[i - 1:i] in ("", " ", "\t", "\n", ";", "&", "|")):
            fd = ""
            if c.isdigit():
                fd = c; i += 1; c = cmd[i]
            if cmd.startswith("<<<", i):
                raise Deny("here-string")
            if cmd.startswith("<<", i):
                i += 2
                if i < n and cmd[i] == "-":
                    i += 1
                while i < n and cmd[i] in " \t":
                    i += 1
                m = re.match(r"'([A-Za-z_][A-Za-z0-9_]*)'|\"([A-Za-z_][A-Za-z0-9_]*)\"", cmd[i:])
                if not m:
                    raise Deny("heredoc delimiter must be quoted so its body is plain data")
                pending_heredocs.append(m.group(1) or m.group(2)); i += m.end()
                continue
            end_word()
            op = c; i += 1
            if op == ">" and i < n and cmd[i] == ">":
                op = ">>"; i += 1
            if i < n and cmd[i] == "&":
                m = re.match(r"&(\d|-)", cmd[i:])
                if op == ">" and m:
                    i += m.end()
                    continue  # 2>&1 and friends duplicate a descriptor, no file involved
                raise Deny("unsupported redirect")
            if i < n and cmd[i] == "|":
                raise Deny("unsupported redirect")
            while i < n and cmd[i] in " \t":
                i += 1
            tw, th = "", False
            while i < n and cmd[i] not in " \t\n;&|()<>":
                if cmd[i] in "'\"":
                    q = cmd[i]; j = cmd.find(q, i + 1)
                    if j < 0:
                        raise Deny("unterminated quote")
                    tw += cmd[i + 1:j]; th = True; i = j + 1
                elif cmd[i] in "$`\\":
                    raise Deny("substitution in a redirect target")
                else:
                    tw += cmd[i]; th = True; i += 1
            if not th:
                raise Deny("redirect without a target")
            reds.append((op, tw))
        else:
            word += c; have = True; i += 1
    if pending_heredocs:
        raise Deny("heredoc without its terminator")
    end_cmd()
    return cmds

def check_simple(argv, reds):
    for op, target in reds:
        if op in (">", ">>"):
            if target == "/dev/null":
                continue
            if not in_root(target):
                raise Deny("redirect target outside the scratch repo: " + target)
        elif op == "<":
            if not readable(target):
                raise Deny("redirect source outside the scratch repo: " + target)
    if not argv:
        return
    prog, args = argv[0], argv[1:]
    if "=" in prog.split("/")[0] and not prog.startswith("/"):
        raise Deny("environment assignment before a command")
    if prog.startswith("~") or prog.startswith("/") or "/" in prog:
        if real(prog) in {real(w) for w in WRAPPERS}:
            return
        raise Deny("program is not one of the prescribed wrapper scripts: " + prog)
    if prog == "cd":
        if len(args) != 1 or not in_root(args[0]):
            raise Deny("cd outside the scratch repo")
        return
    if prog in ("echo", "printf", "true", "pwd", ":"):
        return
    if prog == "sleep":
        if len(args) != 1 or not re.fullmatch(r"\d{1,3}", args[0]):
            raise Deny("sleep needs one small number")
        return
    if prog == "mkdir":
        for a in args:
            if not a.startswith("-") and not in_root(a):
                raise Deny("mkdir outside the scratch repo")
        if any(a.startswith("-") and a != "-p" for a in args):
            raise Deny("mkdir option not allowed")
        return
    if prog in READERS:
        for a in args:
            if a.startswith("-"):
                if a.startswith(("--output", "-o")) and prog == "diff":
                    raise Deny("diff output option")
                continue
            if prog in ("head", "tail") and re.fullmatch(r"\d+", a):
                continue
            if prog == "grep" and a is args[0] and not any(not x.startswith("-") for x in args[1:]):
                continue  # the pattern when it is the only operand is read from stdin
            if prog in ("test", "[") and (a in ("]", "!", "=") or not a.startswith(("/", "~", "."))):
                continue
            if not readable(a):
                raise Deny("reads outside the scratch repo: " + a)
        return
    if prog == "git":
        if not args or args[0] not in GIT_READ:
            raise Deny("git subcommand not allowed: " + (args[0] if args else ""))
        for a in args[1:]:
            if a.startswith(("--output", "--git-dir", "--work-tree", "-C", "--exec-path", "--ext-diff", "--no-index")) or a in ("-c",):
                raise Deny("git option not allowed: " + a)
            if not a.startswith("-") and (a.startswith(("/", "~")) or ".." in a.split("/")) and not in_root(a):
                raise Deny("git path outside the scratch repo: " + a)
        return
    if prog == "codex":
        if args == ["--version"]:
            return
        raise Deny("only `codex --version` may be run directly")
    if prog == "python3":
        if len(args) >= 2 and args[0] == "-m" and args[1] in ("unittest", "doctest"):
            return
        if len(args) >= 1 and not args[0].startswith("-") and args[0].endswith(".py") and in_root(args[0]):
            return
        raise Deny("python3 may only run unittest, doctest or a .py file inside the scratch repo")
    raise Deny("command not allowed: " + prog)

def check_bash(cmd):
    for argv, reds in lex(cmd):
        check_simple(argv, reds)

def decide(d):
    global CWD, ROOT
    if not ROOT:
        raise Deny("PROOF_SCRATCH_ROOT is not set")
    CWD = d.get("cwd") or ROOT
    tool, ti = d.get("tool_name", ""), d.get("tool_input") or {}
    if tool in ("Skill", "Task", "Agent", "TodoWrite", "TaskOutput", "SendMessage"):
        return
    if tool in ("Read", "Glob", "Grep"):
        p = ti.get("file_path") or ti.get("path") or CWD
        if not readable(p):
            raise Deny(tool + " outside the scratch repo: " + str(p))
        return
    if tool in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
        p = ti.get("file_path") or ti.get("notebook_path")
        if not p or not in_root(p):
            raise Deny(tool + " target outside the scratch repo: " + str(p))
        return
    if tool == "Bash":
        if ti.get("run_in_background"):
            raise Deny("background Bash")
        check_bash(ti.get("command", ""))
        return
    raise Deny("tool not allowed: " + tool)

def main():
    global ROOT, CWD
    CWD = ""
    ROOT = os.path.realpath(os.environ["PROOF_SCRATCH_ROOT"]) if os.environ.get("PROOF_SCRATCH_ROOT") else ""
    tool = "?"
    try:
        d = json.load(sys.stdin)
        tool = d.get("tool_name", "?")
        decide(d)
        verdict, why = "allow", ""
    except Deny as e:
        verdict, why = "deny", str(e)
    except Exception as e:  # fail closed on anything unexpected
        verdict, why = "deny", "internal error: %r" % (e,)
    log = os.environ.get("PROOF_HOOK_LOG")
    if log:
        try:
            with open(log, "a") as f:
                f.write("%s %s %s\n" % (verdict.upper(), tool, why.replace("\n", " ")))
        except OSError:
            pass
    out = {"hookEventName": "PreToolUse", "permissionDecision": verdict}
    if why:
        out["permissionDecisionReason"] = "proof confinement: " + why
    print(json.dumps({"hookSpecificOutput": out}))

if __name__ == "__main__":
    main()
