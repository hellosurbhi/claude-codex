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
        items.append([n, hashlib.sha256(open(fp, "rb").read()).hexdigest() if os.path.isfile(fp) else "notfile"])
    # WHY json (cc11 r60): "name:hash" items joined by commas let a hook NAMED like "x:<hash>,y" imitate two hooks; JSON quotes every field, so the text is unambiguous.
    return "config %s\nhooks %s\n" % (cfg, json.dumps(items))

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
    # WHY every construct below is either parsed exactly as bash parses it or refused (cc11 r58 HIGH): this lexer is a second parser of bash, and wherever the two disagree about where a
    # construct ends, the hook skips text bash runs. Found by tests/check-hook-differential.py, which runs every allowed line under real bash with logging stubs: a `<<-` heredoc whose
    # tab-indented terminator ends bash's heredoc early, a `#` comment hiding a heredoc operator, `>&2x` (a file name to bash), a glob bracket in a path, an empty command around `;;`,
    # CR and NUL. What breaks if one is loosened: the differential test fails and a command can run unvalidated.
    if "\r" in cmd or "\x00" in cmd:
        raise Deny("carriage return or NUL in the command")
    cmds, argv, reds = [], [], []
    word, have, i, n = "", False, 0, len(cmd)
    pending_heredocs = []
    need_cmd = False  # set after `&&`, `||` and `|`: a command must follow
    glob_br = False
    def end_word():
        nonlocal word, have, glob_br
        if glob_br and word not in ("[", "]"):
            raise Deny("unquoted [ or ] inside a word is a glob bash expands (the path checked would not be the path opened)")
        if have:
            argv.append(word)
        word, have, glob_br = "", False, False
    def end_cmd(sep=""):
        nonlocal argv, reds, need_cmd
        end_word()
        empty = not (argv or reds)
        if sep not in ("", "\n") and empty:
            raise Deny("empty command before " + sep + " (bash reports a syntax error where the hook would carry on)")
        if need_cmd and empty and sep != "\n":
            raise Deny("operator without a command after it")
        if sep == "\n" and need_cmd and empty:
            raise Deny("operator at the end of a line (bash continues onto the next line, the hook does not)")
        if not empty:
            cmds.append((argv, reds))
        argv, reds = [], []
        need_cmd = sep in ("&&", "||", "|")
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
                end_cmd("&&"); i += 2
            elif cmd.startswith(">&", i - 1) and i > 0 and cmd[i - 1] == ">":
                raise Deny("unexpected &")
            else:
                raise Deny("background or bare &")
        elif c == "|":
            if cmd.startswith("||", i):
                end_cmd("||"); i += 2
            else:
                end_cmd("|"); i += 1
        elif c == ";":
            if cmd.startswith(";;", i):
                raise Deny("case terminator ;;")
            end_cmd(";"); i += 1
        elif c == "\n":
            end_cmd("\n"); i += 1
            if pending_heredocs:
                for delim in pending_heredocs:
                    # WHY an exact line (cc11 r58): bash ends a heredoc only at a line that is the delimiter and nothing else, so trailing blanks or a leading tab do not end it
                    m = re.compile(r"^" + re.escape(delim) + r"$", re.M).search(cmd, i)
                    if not m:
                        raise Deny("heredoc without its terminator")
                    i = m.end() + 1 if m.end() < n else n
                pending_heredocs = []
        elif c in " \t":
            end_word(); i += 1
        elif c == ">" or c == "<" or (c.isdigit() and not have and i + 1 < n and cmd[i + 1] in "<>" and cmd[i - 1:i] in ("", " ", "\t", "\n", ";", "&", "|")):
            fd = ""
            if have and word.isdigit():
                raise Deny("multi-digit file descriptor before a redirect")
            if c.isdigit():
                fd = c; i += 1; c = cmd[i]
            if cmd.startswith("<<<", i):
                raise Deny("here-string")
            if cmd.startswith("<<", i):
                if fd:
                    raise Deny("heredoc on a numbered descriptor")
                i += 2
                if i < n and cmd[i] == "-":
                    raise Deny("<<- strips leading tabs from the terminator, which the hook does not model")
                while i < n and cmd[i] in " \t":
                    i += 1
                m = re.match(r"'([A-Za-z_][A-Za-z0-9_]*)'|\"([A-Za-z_][A-Za-z0-9_]*)\"", cmd[i:])
                if not m:
                    raise Deny("heredoc delimiter must be quoted so its body is plain data")
                if i + m.end() < n and cmd[i + m.end()] not in " \t\n;&|<>":
                    raise Deny("text glued to the heredoc delimiter changes the delimiter bash looks for")
                pending_heredocs.append(m.group(1) or m.group(2)); i += m.end()
                reds.append(("<<", ""))
                continue
            end_word()
            op = c; i += 1
            if op == ">" and i < n and cmd[i] == ">":
                op = ">>"; i += 1
            if i < n and cmd[i] == "&":
                m = re.match(r"&(\d|-)", cmd[i:])
                if op == ">" and m and (i + m.end() >= n or cmd[i + m.end()] in " \t\n;&|"):
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
                elif cmd[i] in "$`\\*?{}[]":
                    raise Deny("substitution, escape or glob in a redirect target")
                else:
                    tw += cmd[i]; th = True; i += 1
            if not th:
                raise Deny("redirect without a target")
            reds.append((op, tw))
        elif c in "*?{}":
            raise Deny("unquoted glob or brace expansion")
        elif c == "#" and not have:
            raise Deny("comment: bash drops the rest of the line, the hook would still read it (a heredoc operator in it would hide the next lines)")
        else:
            if c in "[]":
                glob_br = True
            word += c; have = True; i += 1
    if pending_heredocs:
        raise Deny("heredoc without its terminator")
    end_cmd("\n")
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

def _g(none="", **kinds):
    # none: space-separated long options without a value; the keyword arguments name the others (a hyphen is written as an underscore)
    d = {k: "none" for k in none.split()}
    d.update({k.replace("_", "-"): v for k, v in kinds.items()})
    return d

# WHY an option grammar per reader (cc11 r56 HIGH): the old loop `continue`d on every dash-prefixed token, so `grep -f/outside/file app.py`, `grep --exclude-from=/outside`,
# `diff -X/outside a b` or `wc --files0-from=/outside` read a file the path check never saw (the OS sandbox read exclusions cover only three credential directories, not the disk).
# Fixing the known options would leave every other reader option a bypass, so the rule is inverted: an option is allowed only when it is listed here with the way it takes its
# value. Entry = (short flags without a value that may be bundled, {short option: kind}, {exact long name: kind}). Kinds: none, num (digits only), str (a pattern or label that
# is never opened), file (an operand that IS opened: checked with readable()), opt (long only, optional =value that is never opened). Anything unlisted is refused; long names
# must match exactly (no getopt abbreviations). Options that read a LIST of further paths (wc --files0-from, file -f) are absent on purpose: checking the list file would not
# check the paths inside it. -R, -S and tail -f are absent too (follow symlinks, hang). What breaks if an entry is added carelessly: that option becomes an unchecked read.
GRAMMAR = {
    "cat": ("AbeEnstTuv", {}, _g("show-all number-nonblank show-ends number squeeze-blank show-tabs show-nonprinting")),
    "head": ("qvz", {"n": "num", "c": "num"}, _g("quiet silent verbose zero-terminated", lines="num", bytes="num")),
    "tail": ("qvz", {"n": "num", "c": "num"}, _g("quiet silent verbose zero-terminated", lines="num", bytes="num")),
    "ls": ("1aAdFhiklnprRsStG", {}, _g("all almost-all human-readable recursive directory classify")),
    "wc": ("lwcmL", {}, _g("lines words bytes chars max-line-length")),
    "file": ("bhiIkLnNpvz", {}, _g("brief mime mime-type mime-encoding")),
    "stat": ("xsl", {}, {}),
    "grep": ("EFGPiIvwxcLlnoqsHhbTUaZzr0123456789", {"e": "str", "f": "file", "m": "num", "A": "num", "B": "num", "C": "num"},
             _g("extended-regexp fixed-strings basic-regexp perl-regexp ignore-case no-ignore-case invert-match word-regexp line-regexp count files-without-match files-with-matches "
                "line-number only-matching quiet silent no-messages with-filename no-filename byte-offset initial-tab null-data null text recursive",
                regexp="str", file="file", exclude_from="file", include="str", exclude="str", exclude_dir="str", label="str", binary_files="str",
                max_count="num", after_context="num", before_context="num", context="num", color="opt", colour="opt")),
    "diff": ("qsuyacrNiwbBEZtp", {"U": "num", "C": "num", "x": "str", "F": "str", "L": "str", "I": "str", "X": "file", "S": "file"},
             _g("brief recursive new-file ignore-case ignore-all-space ignore-space-change ignore-blank-lines text report-identical-files side-by-side show-c-function strip-trailing-cr",
                unified="opt", context="opt", color="opt", exclude="str", label="str", ignore_matching_lines="str", show_function_line="str",
                exclude_from="file", from_file="file", to_file="file", starting_file="file")),
}

# git: the same deny-by-default grammar per read subcommand (cc11 r57). The old code refused a list of known-bad options, so every option not on that list passed. Only options that
# take no file operand are listed; --output, -O, --no-index, --ext-diff, --textconv, --exclude-from, -X, --stdin, --filters, --git-dir and every config option stay absent.
_GD = ("pusRzwbaM", {"U": "num", "S": "str", "G": "str", "n": "num"},
       _g("cached staged stat shortstat numstat name-only name-status raw patch no-patch no-color no-ext-diff no-textconv minimal patience histogram summary check full-index binary "
          "ignore-space-change ignore-all-space ignore-blank-lines text exit-code quiet oneline graph all decorate no-decorate abbrev-commit no-abbrev-commit first-parent merges "
          "no-merges reverse follow all-match no-renames", unified="num", abbrev="opt", color="opt", word_diff="opt", find_renames="opt", max_count="num", skip="num", since="str",
          until="str", after="str", before="str", author="str", committer="str", grep="str", format="str", pretty="opt", date="str", diff_filter="str"))
GIT_GRAMMAR = {
    "status": ("sbvz", {}, _g("short branch porcelain long verbose no-renames ahead-behind no-ahead-behind", untracked_files="opt", ignored="opt")),
    "diff": _GD, "log": _GD, "show": _GD,
    "rev-parse": ("q", {}, _g("show-toplevel is-inside-work-tree is-bare-repository show-prefix show-cdup verify quiet symbolic-full-name", abbrev_ref="opt", short="opt")),
    "ls-files": ("cdmoskzt", {"x": "str"}, _g("cached deleted modified others stage unmerged killed ignored exclude-standard error-unmatch full-name no-empty-directory", exclude="str")),
    "branch": ("arv", {}, _g("list show-current all remotes verbose")),
    "cat-file": ("tspe", {}, _g("batch-all-objects", batch="opt", batch_check="opt")),
    "rev-list": ("n", {"n": "num"}, _g("all count reverse first-parent merges no-merges oneline left-right", max_count="num", skip="num", since="str", until="str", after="str", before="str", author="str",
                                      committer="str", grep="str")),
}
TEST_OPS = {"-a", "-o", "-b", "-c", "-d", "-e", "-f", "-g", "-G", "-h", "-k", "-L", "-n", "-N", "-O", "-p", "-r", "-s", "-S", "-t", "-u", "-w", "-x", "-z",
            "-nt", "-ot", "-ef"}
# WHY no -v, -R, -eq, -ne, -gt, -ge, -lt, -le (cc11 r57): bash evaluates the operand of `test -v NAME` as a variable name WITH an array subscript, so `-v 'a[$(cmd)]'` runs cmd although
# the word is single-quoted; the integer comparisons are the same family (and [[ ]] and (( )) evaluate arithmetic outright). Nothing the skills need compares numbers.

def parse_args(prog, args, grammar):
    """Split args into operands with an explicit option grammar (see GRAMMAR). Returns (operands, pattern_given, recursive); raises Deny on any option the grammar does not list."""
    ops, pattern_given, recursive, done = [], False, False, False
    short_none, short_arg, long_opts = grammar
    def value(kind, v, opt):
        nonlocal pattern_given
        if kind == "num":
            if not re.fullmatch(r"[+-]?\d+[A-Za-z]{0,2}", v):
                raise Deny("option %s needs a number: %s" % (opt, v))
        elif kind == "file":
            if not readable(v):
                raise Deny("option %s reads outside the scratch repo: %s" % (opt, v))
        if prog == "grep" and opt in ("-f", "--file", "-e", "--regexp"):
            pattern_given = True
    i = 0
    while i < len(args):
        a = args[i]
        i += 1
        if done or a == "-" or not a.startswith("-"):
            ops.append(a)
            continue
        if a == "--":
            done = True
            continue
        if a.startswith("--"):
            name, eq, v = a[2:].partition("=")
            kind = long_opts.get(name)
            if kind is None:
                raise Deny("%s option not allowed: %s" % (prog, a))
            if kind == "none" and eq:
                raise Deny("option takes no value: " + a)
            if kind in ("num", "str", "file"):
                if not eq:
                    if i >= len(args):
                        raise Deny("option needs a value: " + a)
                    v, i = args[i], i + 1
                value(kind, v, "--" + name)
            if name == "recursive":
                recursive = True
            continue
        if prog in ("head", "tail", "grep", "git log", "git rev-list") and re.fullmatch(r"-\d+", a):
            continue
        j = 1
        while j < len(a):
            ch = a[j]
            j += 1
            if ch in short_none:
                recursive = recursive or ch == "r"
                continue
            kind = short_arg.get(ch)
            if kind is None:
                raise Deny("%s option not allowed: -%s" % (prog, ch))
            v = a[j:]
            if not v:
                if i >= len(args):
                    raise Deny("option needs a value: -" + ch)
                v, i = args[i], i + 1
            value(kind, v, "-" + ch)
            break
    return ops, pattern_given, recursive

def check_reader(prog, args):
    """Parse a reader's arguments with its explicit option grammar, validate every operand and every file-taking option value with readable(), refuse the unknown."""
    if prog in ("test", "["):
        for a in args:
            if a.startswith("-") and len(a) > 1 and a not in TEST_OPS:
                raise Deny("test operator not allowed: " + a)
            if a in ("]", "!", "=") or a.startswith("-") or not a.startswith(("/", "~", ".")):
                continue
            if not readable(a):
                raise Deny("reads outside the scratch repo: " + a)
        return
    ops, pattern_given, recursive = parse_args(prog, args, GRAMMAR[prog])
    if prog == "grep" and not pattern_given and ops:
        ops = ops[1:]  # the pattern is never opened
    for a in ops:
        if not readable(a):
            raise Deny("reads outside the scratch repo: " + a)
    if prog == "grep" and recursive and not ops and not readable("."):
        raise Deny("recursive grep with no operand reads the working directory, which is outside the scratch repo")


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
    if prog == "echo":
        # WHY: echo only knows -n -e -E; any other dash word would be printed, but an unlisted option is refused like everywhere else (cc11 r57, one grammar for every command)
        for a in args:
            if not a.startswith("-"):
                break
            if not re.fullmatch(r"-[neE]+", a):
                raise Deny("echo option not allowed: " + a)
        return
    if prog == "printf":
        # WHY (cc11 r57 HIGH): `printf -v 'a[$(cmd)0]' '%s' x` assigns to a variable NAME and bash evaluates the array subscript in it, running cmd although the word is single-quoted. Only a
        # literal format with literal arguments is allowed and no option at all (the lexer already refuses every expansion), so -v, -- and any other leading dash word are refused.
        if not args or args[0].startswith("-"):
            raise Deny("printf needs a literal format and takes no options")
        return
    if prog in ("true", ":"):
        if args:
            raise Deny(prog + " takes no arguments here")
        return
    if prog == "pwd":
        if any(a not in ("-L", "-P") for a in args):
            raise Deny("pwd takes only -L or -P")
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
        check_reader(prog, args)
        return
    if prog in ("export", "unset", "declare", "typeset", "readonly", "set", "setenv"):
        raise Deny("changing the shell environment is not allowed (the git configuration is pinned from outside): " + prog)
    if prog == "git":
        git_guard()
        if not args or args[0] not in GIT_READ:
            raise Deny("git subcommand not allowed: " + (args[0] if args else ""))
        ops, _, _ = parse_args("git " + args[0], args[1:], GIT_GRAMMAR[args[0]])
        if args[0] == "branch" and ops and "--list" not in args[1:]:
            raise Deny("git branch with an operand creates a branch unless --list is given")
        for a in ops:
            if (a.startswith(("/", "~")) or ".." in a.split("/")) and not in_root(a):
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
