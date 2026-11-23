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
    "diff": ([("-X", "--exclude-from"), ("-S", "--starting-file"), (None, "--from-file"), (None, "--to-file")], ["app.py", "app.py"], "r"),
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
for prog in ("grep", "diff", "wc", "cat", "head", "tail", "ls", "file", "stat"):
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
if not only or "diff" in only:
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
print("hook option cases: %d, failures: %d" % (n, len(bad)))
for b in bad[:40]:
    print("FAIL " + b)
sys.exit(1 if bad else 0)
