#!/usr/bin/env python3
# PreToolUse hook that confines the real-proof Claude session (tests/review-loop-proof.sh) to its scratch repo. DENY BY DEFAULT.
# Reads one hook JSON object on stdin, prints one hook decision JSON on stdout, and appends one line per decision to $PROOF_HOOK_LOG.
# Needs PROOF_SCRATCH_ROOT (the scratch repo). Without it, or on ANY internal error, everything is denied (fail closed).
#
# WHY this exists (cc11 bypass review): a headless `claude -p` run denies edits to an existing .claude/plan file in every other permission mode, so the proof runs with
# prompts off (bypassPermissions). Probed with claude 2.1.323: a PreToolUse hook still runs, and still denies, under bypassPermissions. This hook is then the ONLY
# gate, so it allows exactly what the skills and the proof need and nothing else: reads and edits whose resolved real path is inside the scratch repo, whole Bash
# commands made of the prescribed wrapper scripts and a few read-only helpers, and the Skill/Task/Agent tools (no interpreter or runner such as python, bash <file>, node, make, env, xargs or find -exec).
# WHY Agent/Task are allowed: probed with claude 2.1.323 under bypassPermissions that a subagent's own Read and Bash calls reach this hook (payload carries agent_id and
# agent_type; evidence review-work/cc11-allow-probe/agentprobe/hook.log), so a subagent is confined exactly like the main session. If a CLI update stops that, deny Agent/Task here. What breaks if it is loosened: the agent runs unprompted
# on the owner's machine with nothing between it and the home directory. The start-up probe in review-loop-proof.sh feeds an out-of-bounds call straight to this file.
import hashlib, json, os, re, sys

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

GITNAMES = (".git", ".gitattributes", ".gitmodules")
PYLOAD = (".py", ".pyw", ".pyc", ".pyo", ".pth", ".so", ".pyd", ".dylib")

def writable(p):
    # WHY no component named .git, .gitattributes or .gitmodules at ANY depth (cc11 r37 CRITICAL): git status/diff read the config of every repo they touch and may run programs it
    # names (core.fsmonitor, diff.<driver>.textconv, core.pager, hooks), so a nested `nested/.git/config` written by the agent turned the allowed `git status` into code execution
    # (the old rule only protected the root .git). .gitattributes names diff and filter drivers and .gitmodules names submodule commands, so they are closed the same way.
    r = real(p)
    if os.path.basename(r).lower().endswith(PYLOAD) or os.path.basename(r) == "pyvenv.cfg":
        # WHY (cc11 r40 CRITICAL, defense in depth): the sandbox-excluded wrapper runs python with the scratch repo as its working directory. The shipped wrapper now uses `python3 -I`,
        # but the installed copy the proof runs is a separate file this repo does not control, so a planted json.py, os.py, sitecustomize.py, a .pth or an extension module must be unwritable
        # as well. plan-codex needs only .claude/plan/*.md. What breaks if this goes: a planted module executes outside the OS sandbox on the next wrapper call.
        return False
    return inside(r, ROOT) and not any(c in GITNAMES for c in os.path.relpath(r, ROOT).split(os.sep))

def git_state(root):
    # The two things an allowed git command trusts in the root repo: its config file and its hooks directory. One line per item, comparable as plain text.
    try:
        cfg = hashlib.sha256(open(os.path.join(root, ".git", "config"), "rb").read()).hexdigest()
    except OSError:
        cfg = "missing"
    hd, items = os.path.join(root, ".git", "hooks"), []
    for n in sorted(os.listdir(hd)) if os.path.isdir(hd) else []:
        fp = os.path.join(hd, n)
        items.append("%s:%s" % (n, hashlib.sha256(open(fp, "rb").read()).hexdigest() if os.path.isfile(fp) else "notfile"))
    return "config %s\nhooks %s\n" % (cfg, ",".join(items))

def nested_git(root):
    # any `.git` entry (directory or gitlink file) below the root other than the root's own
    for dp, dns, fns in os.walk(root):
        if dp == root and ".git" in dns:
            dns.remove(".git")
        for n in dns + fns:
            if n == ".git":
                return os.path.join(dp, n)
    return None

def git_guard():
    # WHY these checks (cc11 r37): an allowed git command runs whatever the repo's config names, so it is only allowed when (a) the tool cwd is the repo root (no `cd nested`),
    # (b) root .git/config and .git/hooks are byte for byte what the proof recorded before launch (baseline file outside the repo, path in PROOF_GIT_BASELINE) and (c) no other
    # repo exists anywhere below the root (Codex in workspace-write can create one, and the hook cannot see what Codex writes). The proof also launches claude with GIT_CONFIG_*
    # forcing the dangerous keys off; this is the second layer for the case that environment is not what was intended. What breaks if (c) is dropped: a nested repo's config runs.
    if os.path.realpath(CWD) != ROOT:
        raise Deny("git needs the tool cwd to be the scratch repo root, got " + CWD)
    bf = os.environ.get("PROOF_GIT_BASELINE", "")
    try:
        base = open(bf).read() if bf else None
    except OSError:
        base = None
    if base is None:
        raise Deny("git is not allowed without the baseline file the proof recorded")
    if base != git_state(ROOT):
        raise Deny("git is not allowed: .git/config or .git/hooks changed since the baseline")
    n = nested_git(ROOT)
    if n:
        raise Deny("git is not allowed while another repository exists below the root: " + os.path.relpath(n, ROOT))

def readable(p):
    r = real(p)
    if inside(r, ROOT) or any(inside(r, real(x)) for x in READ_ONLY_EXTRA):
        return True
    # WHY the lexical path under the skills dir too: each ~/.claude/skills/<name> is a symlink into the owner's checkout of the skills (here a worktree), so its real path
    # is outside the skills dir and the check above refused the skill's own role file. normpath collapses `..` first, so skills/../x is not accepted. Read-only, owner-installed.
    ex = os.path.expanduser(p)
    if not os.path.isabs(ex):
        ex = os.path.join(CWD, ex)
    return inside(os.path.normpath(ex), os.path.join(HOME, ".claude", "skills"))

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
                if cmd[j] == "\\" and j + 1 < n and cmd[j + 1] in '"\\':
                    buf += cmd[j + 1]; j += 2; continue
                if cmd[j] == "\\":
                    raise Deny("backslash escape inside double quotes")
                if cmd[j] == "`" or (cmd[j] == "$" and not cmd.startswith("$?", j)):
                    raise Deny("command, parameter or variable expansion inside double quotes")
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
                reds.append(("<<", ""))
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
                if cmd[i] == "'":
                    j = cmd.find("'", i + 1)
                    if j < 0:
                        raise Deny("unterminated quote")
                    tw += cmd[i + 1:j]; th = True; i = j + 1
                elif cmd[i] == '"':
                    j = cmd.find('"', i + 1)
                    if j < 0:
                        raise Deny("unterminated quote")
                    inner = cmd[i + 1:j]
                    # WHY the same rule as a double-quoted word (cc11 r36 CRITICAL): bash still expands $( ), ${ }, $NAME and backticks inside double quotes, so a target
                    # like "$(touch /tmp/x)" is not the literal file name the path check would see.
                    if "`" in inner or "\\" in inner or re.search(r"\$(?!\?)", inner):
                        raise Deny("expansion in a double-quoted redirect target")
                    tw += inner; th = True; i = j + 1
                elif cmd[i] in "$`\\*?{}":
                    raise Deny("substitution, escape or glob in a redirect target")
                else:
                    tw += cmd[i]; th = True; i += 1
            if not th:
                raise Deny("redirect without a target")
            reds.append((op, tw))
        elif c in "*?{}":
            raise Deny("unquoted glob or brace expansion")
        else:
            word += c; have = True; i += 1
    if pending_heredocs:
        raise Deny("heredoc without its terminator")
    end_cmd()
    return cmds

TILDE_OK = ("~/.claude/skills/", "~/.claude/config/scripts/")

def check_wrapper(name, args):
    # WHY the wrapper's own option grammar (cc11 r36 CRITICAL): codex-call.sh forwards --sandbox and --cd straight to `codex exec`, so an allowed call could pick
    # workspace-write or an outside directory. Each wrapper is parsed exactly as its script parses it (codex-call.sh v3: options while more than one argument is left,
    # then the one prompt; verified sandbox default is read-only) and anything the script would treat differently from the hook (unknown option, `--`, a repeated option,
    # `--opt=value`, extra arguments) is denied. Re-check this if the script's option set changes.
    if name == "codex-call.sh":
        a, seen, sandbox, cd, pf = list(args), set(), "read-only", None, None
        # WHY --prompt-file is an option here (cc11 r37 HIGH): the prescribed review and implementation calls pass the prompt as a file inside the repo, and the script
        # reads it itself, so the file must resolve (symlinks followed) inside the scratch repo; it replaces the positional prompt, never accompanies it.
        while a:
            o = a[0]
            if o not in ("--sandbox", "--role", "--resume", "--cd", "--prompt-file"):
                break
            if o in seen:
                raise Deny("codex-call.sh option given twice: " + o)
            seen.add(o)
            if len(a) < 2 or a[1].startswith("-") or not a[1]:
                raise Deny("codex-call.sh option without a value: " + o)
            v = a[1]
            if o == "--sandbox":
                if v != "read-only":
                    raise Deny("codex-call.sh --sandbox must be read-only, got " + v)
                sandbox = v
            if o == "--role" and not readable(v):
                raise Deny("codex-call.sh --role file outside the scratch repo and the skills dir: " + v)
            if o == "--resume" and not re.fullmatch(r"[A-Za-z0-9-]{8,64}", v):
                raise Deny("codex-call.sh --resume is not a thread id: " + v)
            if o == "--cd":
                if not in_root(v) or ".." in v.split("/"):
                    raise Deny("codex-call.sh --cd must be inside the scratch repo with no .. component: " + v)
                cd = v
            if o == "--prompt-file":
                if not in_root(v) or not os.path.isfile(real(v)):
                    raise Deny("codex-call.sh --prompt-file must be an existing file inside the scratch repo: " + v)
                pf = v
            a = a[2:]
        if pf is not None:
            if a:
                raise Deny("codex-call.sh takes a prompt file or a prompt, not both (extra argument: " + a[0] + ")")
        elif len(a) != 1 or a[0].startswith("-") or not a[0]:
            raise Deny("codex-call.sh needs known options then exactly one prompt (an option-looking, extra or missing argument is refused)")
        # WHY workspace-write is denied again (cc11 r38 CRITICAL): codex-call.sh is exempt from the OS sandbox, so a write-capable Codex is only as confined as the directory the
        # script picks (--cd, else the git toplevel of the cwd). The `real` proof is plan-codex only, which is read-only, so the surface is removed rather than tracked. Widening
        # `real` to a skill that needs workspace-write requires revisiting this check, the sole-segment rule in check_bash and the sandbox exclusions together.
        return
    if name == "reviewer.sh":
        if len(args) != 3 or args[0] not in ("E", "R", "S") or not readable(args[1]) or not writable(args[2]):
            raise Deny("reviewer.sh must be: <tier E|R|S> <input inside the repo> <output inside the repo>")
        return
    if name == "review-snapshot.sh":
        if args not in ([], ["HEAD"]):
            raise Deny("review-snapshot.sh takes no argument or HEAD")
        return
    if name == "redact-diff.sh":
        if args not in ([], ["--text"]):
            raise Deny("redact-diff.sh takes no argument or --text")
        return
    raise Deny("unknown wrapper: " + name)

def check_simple(argv, reds):
    for op, target in reds:
        if op in (">", ">>"):
            if target == "/dev/null":
                continue
            if not writable(target):
                raise Deny("redirect target outside the scratch repo or inside .git: " + target)
        elif op == "<":
            if not readable(target):
                raise Deny("redirect source outside the scratch repo: " + target)
        elif op == "<<":
            if not argv or argv[0] != "cat":
                raise Deny("a heredoc may only feed cat")
    if not argv:
        return
    prog, args = argv[0], argv[1:]
    if "=" in prog.split("/")[0] and not prog.startswith("/"):
        raise Deny("environment assignment before a command")
    for a in argv:
        if a.startswith("~") and not (a.startswith(TILDE_OK) or a == "~"):
            raise Deny("~ expansion other than the two read-only prefixes: " + a)
    if prog.startswith("~") or prog.startswith("/") or "/" in prog:
        for w in WRAPPERS:
            if real(prog) == real(w):
                check_wrapper(os.path.basename(w), args)
                return
        raise Deny("program is not one of the prescribed wrapper scripts: " + prog)
    if prog == "cd":
        # WHY denied outright (cc11 r38): every path argument is checked against the tool cwd the call STARTED in; a `cd` earlier on the line would silently change what later relative
        # paths mean. No recorded plan-codex run uses cd (hook.log and stream.jsonl of the passing runs), so the surface is removed instead of tracked.
        raise Deny("cd is not allowed (paths are resolved against the tool cwd, which must not move mid-command)")
    if prog in ("echo", "printf", "true", "pwd", ":"):
        return
    if prog == "sleep":
        if len(args) != 1 or not re.fullmatch(r"\d{1,3}", args[0]):
            raise Deny("sleep needs one small number")
        return
    if prog == "mkdir":
        for a in args:
            if not a.startswith("-") and not writable(a):
                raise Deny("mkdir outside the scratch repo or inside .git")
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
    if prog in ("export", "unset", "declare", "typeset", "readonly", "set", "setenv"):
        raise Deny("changing the shell environment is not allowed (the git configuration is pinned from outside): " + prog)
    if prog == "git":
        git_guard()
        if not args or args[0] not in GIT_READ:
            raise Deny("git subcommand not allowed: " + (args[0] if args else ""))
        if args[0] == "branch" and any(not a.startswith("-") or a not in ("-a", "-r", "-v", "-vv", "--list", "--show-current") for a in args[1:]):
            raise Deny("git branch may only list")
        for a in args[1:]:
            if a in ("-c", "-o", "-C") or a.startswith(("--output", "--git-dir", "--work-tree", "-C", "-c", "-o", "--exec-path", "--ext-diff", "--no-index", "--upload-pack", "--config", "--textconv", "--open-files-in-pager", "--paginate", "-O")):
                raise Deny("git option not allowed: " + a)
            if not a.startswith("-") and (a.startswith(("/", "~")) or ".." in a.split("/")) and not in_root(a):
                raise Deny("git path outside the scratch repo: " + a)
        return
    if prog == "codex":
        if args == ["--version"]:
            return
        raise Deny("only `codex --version` may be run directly")
    raise Deny("command not allowed: " + prog)

def is_exempt(argv):
    prog = argv[0]
    if prog == "codex":
        return True
    if "/" in prog or prog.startswith("~"):
        return os.path.basename(prog) == "codex-call.sh" or real(prog) == real("~/.claude/config/scripts/codex-call.sh")
    return False

def check_bash(cmd):
    segs = lex(cmd)
    # WHY: a `cd` earlier on the line moves git into another repo whose config the baseline does not cover; the tool cwd check alone sees only where the call STARTED.
    if any(a and a[0] == "cd" for a, _ in segs) and any(a and a[0] == "git" for a, _ in segs):
        raise Deny("cd and git on one command line")
    # WHY (cc11 r38 CRITICAL): codex-call.sh and `codex --version` are exempt from the OS sandbox, so they must be the ONLY thing on their command line (no `&&`, `;`, `|`, redirect
    # or heredoc around them) and run from the repo root, where every relative argument (--cd, --prompt-file, --role) resolves against the root. Path arguments of the other commands
    # resolve against the tool cwd at call start (cd is denied): reads and writes through real(path), git through the root-cwd check, wrappers through readable()/writable().
    for argv, reds in segs:
        if argv and is_exempt(argv) and (len(segs) != 1 or reds or os.path.realpath(CWD) != ROOT):
            raise Deny("a command exempt from the OS sandbox must be alone on its line, with no redirect, and run from the scratch repo root")
    for argv, reds in segs:
        check_simple(argv, reds)

def decide(d):
    global CWD, ROOT
    if not ROOT:
        raise Deny("PROOF_SCRATCH_ROOT is not set")
    CWD = d.get("cwd") or ROOT
    tool, ti = d.get("tool_name", ""), d.get("tool_input") or {}
    if tool in ("Skill", "Task", "Agent", "TaskOutput", "TodoWrite"):
        return
    if tool in ("Read", "Glob", "Grep"):
        p = ti.get("file_path") or ti.get("path") or CWD
        if not readable(p):
            raise Deny(tool + " outside the scratch repo: " + str(p))
        return
    if tool in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
        p = ti.get("file_path") or ti.get("notebook_path")
        if not p or not writable(p):
            raise Deny(tool + " target outside the scratch repo or inside .git: " + str(p))
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
        tool = d.get("tool_name", "?") + (" [subagent %s]" % d["agent_id"] if d.get("agent_id") else "")
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
    if len(sys.argv) == 4 and sys.argv[1] == "--record-baseline":
        # used by the proof (before launch) and by the tests: writes the baseline the hook compares against, to a file outside the repo
        open(sys.argv[3], "w").write(git_state(os.path.realpath(sys.argv[2])))
    else:
        main()
