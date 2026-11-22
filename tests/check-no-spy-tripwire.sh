#!/usr/bin/env bash
# Usage: check-no-spy-tripwire.sh   runs the public-CI suite (CHECKERS_NO_SPY=1) against a HOME full of tripwires. Exit 0 only when the suite passes
# AND no tripwire fired.
# WHY (r32): CHECKERS_NO_SPY=1 promises that nothing outside the repo is executed or read from ~/.claude (the private reviewer.sh, its installed helper
# scripts) and that no real model CLI runs. A run in an EMPTY home cannot prove that, because there is nothing there to execute: a stray call just fails
# quietly, which is how a direct reviewer.sh call survived one round. Here the home holds scripts that record themselves and exit 99, and codex, gemini,
# coderabbit and claude tripwires sit first on PATH (the suite's own fake-model directories are put in front of them where a test needs a fake).
# Breaking this check means a NO_SPY run may execute private code on a machine that has it.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/nospy-trip.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
home="$work/home"; mark="$work/marker"; : > "$mark"
mkdir -p "$home/.claude/config/scripts/lib" "$work/bin"
trip() { printf '#!/bin/sh\necho "$0 $*" >> "%s"\nexit 99\n' "$mark" > "$1"; chmod +x "$1"; }
for f in reviewer.sh codex-call.sh redact-diff.sh review-snapshot.sh; do trip "$home/.claude/config/scripts/$f"; done
for b in codex gemini coderabbit claude; do trip "$work/bin/$b"; done
env -u SPY_CONFIG_DIR HOME="$home" PATH="$work/bin:$PATH" CHECKERS_NO_SPY=1 bash "$here/test-checkers.sh" > "$work/log" 2>&1 < /dev/null; rc=$?  # WHY < /dev/null (cc11 r36): the suite must never wait on the caller's stdin
tail -n 3 "$work/log"
if [ -s "$mark" ]; then echo "FAIL: a NO_SPY run executed code outside the repo:"; sort -u "$mark" | head -n 5; exit 1; fi
if [ "$rc" -ne 0 ] || grep -q '^FAIL' "$work/log"; then echo "FAIL: the NO_SPY suite did not pass in the tripwire home (rc=$rc)"; grep '^FAIL' "$work/log" | head -n 5; exit 1; fi
# WHY the crash scan (r34): a setup helper that dies (an IndexError in a python snippet that read an event the skipped spy never wrote) printed a traceback to stderr and the suite still exited 0, because only assertions count. The suite's whole output must hold no Python crash.
if grep -Eq 'Traceback \(most recent call last\)|^(IndexError|KeyError|TypeError|ValueError|AttributeError|NameError)\b|^FAIL - setup' "$work/log"; then echo "FAIL: the NO_SPY suite output holds a crash or a failed setup step:"; grep -En -m5 -B1 'Traceback \(most recent call last\)|^(IndexError|KeyError|TypeError|ValueError|AttributeError|NameError)\b|^FAIL - setup' "$work/log" | head -n 12; exit 1; fi
echo "PASS: the NO_SPY suite passed and no tripwire fired"
