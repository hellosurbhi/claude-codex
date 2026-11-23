# Usage: check-hook-options.py <proof-confine-hook.py> [reader ...]   Exit 0 only when every case below got the expected decision from the hook.
# WHY (cc11 r56 HIGH): the hook used to skip validation for every dash-prefixed reader argument, so `grep -f/outside/file app.py` read outside the scratch repo. This table is an
# INDEPENDENT oracle (it does not import the hook's grammar): for every reader and every option that opens a file it builds the command in each way a value can be attached
# (separate, attached, =form, bundled with other flags) against four paths (inside, outside absolute, ../ escape, symlink to outside) and demands deny for the three outside paths.
# Options that read a LIST of further paths (wc --files0-from, file -f) must be denied even for an inside path. Unknown options must be denied, legit commands allowed.
import json, os, subprocess, sys, tempfile
hook = os.path.abspath(sys.argv[1])
only = set(sys.argv[2:])
base = os.path.realpath(tempfile.mkdtemp(prefix="hookopts"))
root, outside = os.path.join(base, "repo"), os.path.join(base, "outside")
os.makedirs(root); os.makedirs(outside)
open(os.path.join(root, "app.py"), "w").write("x\n"); open(os.path.join(root, "in.txt"), "w").write("x\n")
open(os.path.join(outside, "secret"), "w").write("x\n")
os.symlink(outside, os.path.join(root, "link"))
subprocess.run(["git", "init", "-q", root], check=True)
gb = os.path.join(base, "gitbase")
subprocess.run([sys.executable, hook, "--record-baseline", root, gb], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
env = dict(os.environ, PROOF_SCRATCH_ROOT=root, PROOF_GIT_BASELINE=gb)
def decide(cmd):
    p = subprocess.run([sys.executable, hook], input=json.dumps({"tool_name": "Bash", "cwd": root, "tool_input": {"command": cmd}}), capture_output=True, text=True, env=env)
    return json.loads(p.stdout)["hookSpecificOutput"]["permissionDecision"]
PATHS = {"inside": "in.txt", "outside": os.path.join(outside, "secret"), "escape": "../outside/secret", "symlink": "link/secret"}
# reader -> (options whose value is opened, other args every command needs, flag letters that take no value and may be bundled before the option)
FILEOPTS = {
    "grep": ([("-f", "--file"), (None, "--exclude-from")], ["app.py"], "r"),
    "diff": ([("-X", "--exclude-from"), ("-S", "--starting-file"), (None, "--from-file"), (None, "--to-file")], ["app.py", "app.py"], "r"),  # canon-exempt: the diff reader command, not git diff
    "wc": ([(None, "--files0-from")], ["app.py"], "l"),
    "file": ([("-f", "--files-from"), ("-m", "--magic-file")], ["app.py"], "b"),
}
LISTREADERS = {("wc", "--files0-from"), ("file", "-f"), ("file", "--files-from"), ("file", "-m"), ("file", "--magic-file")}
# every other reader must refuse any path glued to a flag it does not know takes a file
NOFILE = {"cat": ["-n", "-A"], "head": ["-n", "-c"], "tail": ["-n", "-c"], "ls": ["-l", "-a"], "stat": ["-x"], "test": []}
bad, n = [], 0
def want(cmd, exp, why):
    global n
    n += 1
    got = decide(cmd)
    if got != exp:
        bad.append("%s: %r expected %s got %s" % (why, cmd, exp, got))
for prog, (opts, extra, bundle) in FILEOPTS.items():
    if only and prog not in only:
        continue
    for short, long_ in opts:
        for pk, pv in PATHS.items():
            exp = "allow" if pk == "inside" and (prog, short) not in LISTREADERS and (prog, long_) not in LISTREADERS else "deny"
            forms = []
            if short:
                forms += ["%s %s %s %s" % (prog, short, pv, " ".join(extra)), "%s %s%s %s" % (prog, short, pv, " ".join(extra)), "%s -%s%s%s %s" % (prog, bundle, short[1:], pv, " ".join(extra))]
            forms += ["%s %s=%s %s" % (prog, long_, pv, " ".join(extra)), "%s %s %s %s" % (prog, long_, pv, " ".join(extra))]
            for f in forms:
                want(f, exp, "file option, path " + pk)
# options never seen before, in any glued form, are refused
for prog in ("grep", "diff", "wc", "cat", "head", "tail", "ls", "file", "stat"):  # canon-exempt: the diff reader command, not git diff
    if only and prog not in only:
        continue
    for opt in ("--no-such-option", "--no-such=/etc/hosts", "-Q/etc/hosts", "-Q", "--fil=/etc/hosts", "--exclude-fro=/etc/hosts"):
        want("%s %s app.py" % (prog, opt), "deny", "unknown option")
for prog, flags in NOFILE.items():
    if only and prog not in only:
        continue
    for fl in flags:
        for pk in ("outside", "escape", "symlink"):
            want("%s %s%s" % (prog, fl, PATHS[pk]), "deny", "numeric or flag option glued to a path")
            want("%s %s %s" % (prog, fl, PATHS[pk]), "deny", "numeric or flag option then a path")
# the rest of the options that do not open a file must not be refused for being options, and operands after -- are still paths
if not only or "grep" in only:
    for pk in ("outside", "escape", "symlink"):
        want("grep -- x %s" % PATHS[pk], "deny", "operand after --")
        want("grep -e x %s" % PATHS[pk], "deny", "-e pattern then an outside operand")
        want("grep -r x %s" % PATHS[pk], "deny", "recursive operand")
    want("grep -r x .", "allow", "legit"); want("grep -rn x app.py", "allow", "legit"); want("grep -e x -e y app.py", "allow", "legit"); want("grep -- x app.py", "allow", "legit")
    want("grep --include='*.py' -rn x .", "allow", "legit"); want("grep -A 2 -B2 x app.py", "allow", "legit"); want("grep -f in.txt app.py", "allow", "legit")
    want("grep -c x", "allow", "legit"); want("grep -R x .", "deny", "-R follows symlinks")
if not only or "diff" in only:  # canon-exempt: the diff reader command, not git diff
    want("diff -u app.py in.txt", "allow", "legit"); want("diff -r app.py in.txt", "allow", "legit"); want("diff -q app.py in.txt", "allow", "legit"); want("diff -o /tmp/x app.py in.txt", "deny", "diff output")
if not only or "head" in only:
    for c in ("head -n 5 app.py", "head -5 app.py", "head -n5 app.py", "head -c 10 app.py", "tail -n +2 app.py", "tail -3 app.py", "tail -f app.py"):
        want(c, "deny" if c.startswith("tail -f") else "allow", "legit")
if not only or "ls" in only:
    for c in ("ls", "ls -la", "ls -1 .", "ls -R .claude", "cat app.py", "cat -n app.py", "wc -l app.py", "file app.py", "file -b app.py", "stat app.py", "test -f app.py", "[ -f app.py ]"):
        want(c, "allow", "legit")
# programs that read a script or file list through an option are not readers at all: refused whatever the option
if not only:
    for c in ("sed -f in.txt app.py", "sed -f/etc/hosts app.py", "sed -n p app.py", "sed --file=in.txt app.py", "awk -f in.txt app.py", "awk -f/etc/hosts app.py", "awk 1 app.py",
              "find . -name x", "find / -name x", "xargs -a /etc/hosts ls", "python3 -I in.txt", "sort -o in.txt app.py", "sort app.py", "tee in.txt", "cut -f1 app.py"):
        want(c, "deny", "not a reader")
# ---- cc11 r57: every OTHER allowed command has a grammar too, and nothing that evaluates a string as a name, subscript, arithmetic or code gets through ----
# WHY: `printf -v 'a[$(cat /outside >&2)0]' '%s' x` runs the embedded command although it is single-quoted (bash evaluates the array subscript of a variable NAME). The hook's lexer
# only sees one quoted word, so the construct has to be refused by name: every command the hook allows is listed below with its refused forms, and every bash form that evaluates
# a string is listed with the payload inside single quotes. The payload is never run by this test: it only asks the hook for a decision.
P = "'a[$(cat /outside >&2)0]'"
if not only or "cmds" in only:
    ev = []
    ev += ["printf -v %s '%%s' x" % P, "printf -v x '%s' y", "printf -- '%s' x", "printf -x '%s' x", "printf -v"]
    ev += ["read %s" % P, "read -r x", "read -a %s" % P, "read -p x y", "mapfile -t %s" % P, "readarray %s" % P, "getopts ab %s" % P, "wait -n -p %s" % P, "wait -n"]
    ev += ["declare %s=1" % P, "declare -n x=%s" % P, "typeset -n x=%s" % P, "local %s" % P, "export %s" % P, "unset %s" % P, "readonly %s" % P, "let %s" % P, "let x=1",
           "eval %s" % P, "eval 'id'", "source in.txt", ". in.txt", "source /etc/hosts", "alias x=id", "trap id EXIT", "exec id", "command id", "builtin id", "type %s" % P, "hash -p /x y"]
    ev += ["test -v %s" % P, "[ -v %s ]" % P, "test -R %s" % P, "[ -R %s ]" % P, "test %s -eq 1" % P, "[ %s -eq 1 ]" % P, "[ 1 -lt %s ]" % P, "test -z %s -a -v %s" % (P, P)]
    ev += ["[[ -v %s ]]" % P, "[[ %s -eq 1 ]]" % P, "(( %s ))" % P, "(( x=1 ))", "echo $(( %s ))" % P, "echo $((1+1))", "echo ${!x}", "echo ${x[%s]}" % P, "echo ${x}", "echo $x", 'echo "$x"', 'echo "${!x}"',
           'echo "$(( 1 ))"', "echo `id`", "echo <(id)", "a=1", "a=1 true", "a[%s]=1" % P, "a[$(cat /outside >&2)0]=1", "x+=1", "for x in 1; do true; done", "if true; then true; fi", "{ true; }", "( true )",
           "function f { true; }", "f() { true; }", "echo x &", "coproc id", "! true", "true || id", "true && id", "echo x | id"]
    for c in ev:
        want(c, "deny", "evaluates a string or is not a prescribed command")
    # lexer constructs bash and the hook could read differently (cc11 r58): refused, the differential test (check-hook-differential.py) proves the rest agree with real bash
    for c in ("cat <<-'EOF'\n\tEOF\nid\nEOF", "cat <<'EOF'x\nb\nEOFx\nEOF", "cat <<'EOF'\nb\nEOF \n", "echo a # b", "# b", "echo a ;; echo b", "echo a ; ; echo b", "echo a &&", "&& echo a", "echo a |",
              "echo a >&2x", "echo a >&10", "echo a 12>out.txt", "cat l[i]nk/secret", "cat [a]pp.py", "echo a\rb", "echo a\\\nb", "3<<'EOF' cat\nb\nEOF", "cat <<<x", "echo a > f[1]"):
        want(c, "deny", "lexer disagreement refused")
    # allowed commands: refused forms
    refused = ["echo -z x", "echo -ne -z x", "echo -- x", "printf", "printf -", "true x", ": x", "pwd -x", "pwd x", "sleep", "sleep 1 2", "sleep -1", "sleep 1000", "sleep abc", "sleep 1s",
               "mkdir -m 777 x", "mkdir -v x", "mkdir /etc/x", "mkdir ../x", "mkdir link/x", "mkdir -p .git/x", "codex", "codex exec x", "codex --version x", "codex -V", "cd .", "cd /",
               "git", "git status --bogus", "git -c core.pager=id log", "git -C / status", "git --git-dir=/x status", "git commit", "git config -l", "git remote -v", "git stash", "git checkout x",
               "git grep x", "git blame app.py", "git branch -D x", "git branch x", "git tag x", "git fetch", "git push", "git apply x", "git show-ref", "git log --output=out.txt", "git log -O in.txt",
               "git diff -O/etc/hosts", "git diff --no-index /etc/hosts in.txt", "git diff --ext-diff", "git diff --textconv", "git show --textconv HEAD", "git log --follow-x", "git ls-files --exclude-from=/etc/hosts",  # canon-exempt: command text under test, not a diff taken here
               "git ls-files -X /etc/hosts", "git ls-files --exclude-per-directory=x", "git rev-parse --git-dir", "git rev-parse --resolve-git-dir /x", "git rev-list --stdin", "git cat-file --filters HEAD:app.py",
               "git cat-file --path=x -p HEAD", "git cat-file --textconv HEAD:app.py", "git log --exec-path=/tmp", "git log -c", "git log --paginate", "git log --open-files-in-pager", "git log --format=%x --bogus",
               "git status -z --bogus", "git log -- /etc/hosts", "git log -- ../x", "git ls-files /etc"]
    for c in refused:
        want(c, "deny", "command form refused")
    # every git read subcommand with an option no grammar lists, in each glued form
    for sub in ("status", "diff", "log", "show", "rev-parse", "ls-files", "branch", "cat-file", "rev-list"):  # canon-exempt: command text under test, not a diff taken here
        for o in ("--no-such", "--no-such=/etc/hosts", "-Q", "-Q/etc/hosts", "--out=/etc/hosts", "-X/etc/hosts"):
            want("git %s %s" % (sub, o), "deny", "git %s unknown option" % sub)
    legit = ["echo x", "echo -n x", "echo -e 'a\\nb'", "echo -ne x", "printf '%s\\n' x", "printf 'plain'", "printf '%d %s' 1 two", "true", ":", "pwd", "pwd -P", "sleep 5", "mkdir -p .claude/plan", "mkdir out",
             "codex --version", "git status", "git status -s", "git status --short --branch", "git diff", "git diff --stat", "git diff --cached --name-only", "git diff HEAD~1 -- app.py", "git log --oneline -n 5",  # canon-exempt: command text under test, not a diff taken here
             "git log -5 --oneline", "git log --format=%H -n1", "git log --pretty=format:%h --since=1.day", "git show HEAD", "git show --stat HEAD", "git rev-parse HEAD", "git rev-parse --show-toplevel",
             "git ls-files", "git ls-files -o --exclude-standard", "git branch", "git branch -a", "git branch --show-current", "git branch -vv", "git cat-file -p HEAD", "git cat-file -t HEAD", "git rev-list --count HEAD",
             "git rev-list -n 3 HEAD", "test -f app.py", "test -d .claude", "[ -f app.py ]", "[ -n x ]", "cat -n app.py", "cat > .claude/plan/x.md <<'EOF'\n$(not run)\nEOF"]
    for c in legit:
        want(c, "allow", "legit command")  # the hook judges the command line only, so a revision that does not exist yet is still allowed
print("hook option cases: %d, failures: %d" % (n, len(bad)))
for b in bad[:200]:
    print("FAIL " + b)
sys.exit(1 if bad else 0)
