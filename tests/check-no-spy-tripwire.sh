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
env -u SPY_CONFIG_DIR HOME="$home" PATH="$work/bin:$PATH" CHECKERS_NO_SPY=1 bash "$here/test-checkers.sh" > "$work/log" 2>&1; rc=$?
tail -n 3 "$work/log"
if [ -s "$mark" ]; then echo "FAIL: a NO_SPY run executed code outside the repo:"; sort -u "$mark" | head -n 5; exit 1; fi
if [ "$rc" -ne 0 ] || grep -q '^FAIL' "$work/log"; then echo "FAIL: the NO_SPY suite did not pass in the tripwire home (rc=$rc)"; grep '^FAIL' "$work/log" | head -n 5; exit 1; fi
echo "PASS: the NO_SPY suite passed and no tripwire fired"
