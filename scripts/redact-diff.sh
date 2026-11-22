#!/usr/bin/env bash
# contract: redact-diff v1 (source of truth: hellosurbhi/claude-codex scripts/redact-diff.sh)
# Usage: redact-diff.sh < raw.diff > masked.diff
# Masks the VALUE part of common credential shapes in a unified diff while keeping its structure (the +, - and space prefixes, @@ hunks, file headers).
# WHY a best-effort mask, not a guarantee: the skills already keep secret-named FILES out of the reviewer's diff with exclude pathspecs, but an inline
# credential in an ordinary source file (an added line or a deleted one) would still reach an outside reviewer. This script masks the shapes below, the ones
# that account for most accidental commits. A secret in a shape this script does not know passes through unchanged, so the pathspec exclusions stay
# in place and nothing here proves a diff is credential-free. Do not delete either layer on the strength of the other.
# WHY the callers treat a missing or failing script as "send nothing": a reviewer call that silently skipped redaction would send the raw diff.
# WHY awk with explicit boundary checks: awk (POSIX, present on macOS and Linux) has no lookbehind, so a token shape such as sk- is checked by hand
# for a non-alphanumeric character before it (otherwise "task-description-long-enough" would be mangled); bash 3.2 and BSD awk compatible (no
# interval expressions, no gawk extensions).
# Shapes: PEM/OpenSSH/PGP private key blocks, AKIA/ASIA keys, ghp_ gho_ ghu_ ghs_ ghr_ and github_pat_ tokens, sk- keys, xoxa/xoxb/xoxp tokens,
# Bearer <token>, JWTs, and (password|passwd|secret|token|api_key|apikey|api-key|credential) assignments with : or =.
export LC_ALL=C
exec awk '
function rep(c, n,   s, i) { s = ""; for (i = 0; i < n; i++) s = s c; return s }
# mask the value part of every match of rx (head: leading part of the match kept as is, "" for none) when it is long enough and sits on a word boundary
function tok(s, rx, headrx, tag, minlen, needdigit,   out, pre, m, head, val, prevc, ok, rs, rl) {
  out = ""
  while (match(s, rx)) {
    rs = RSTART; rl = RLENGTH
    pre = substr(s, 1, rs - 1); m = substr(s, rs, rl)
    prevc = (pre != "") ? substr(pre, length(pre), 1) : ((out != "") ? substr(out, length(out), 1) : "")
    head = ""; val = m
    if (headrx != "") { match(m, headrx); head = substr(m, 1, RLENGTH); val = substr(m, RLENGTH + 1) }
    ok = (prevc !~ /[A-Za-z0-9]/) && (length(val) >= minlen) && (!needdigit || val ~ /[0-9]/)
    if (ok) { out = out pre head tag; s = substr(s, rs + rl) }
    else { out = out pre substr(m, 1, 1); s = substr(s, rs + 1) }
  }
  return out s
}
function assign(s,   ls, out, hs, hl, head, rest, c, q, e, val, tail, lead, trail, quoted, skip) {
  out = ""
  while (1) {
    ls = tolower(s)
    if (!match(ls, KW)) break
    hs = RSTART; hl = RLENGTH
    head = substr(s, 1, hs + hl - 1); rest = substr(s, hs + hl)
    c = substr(rest, 1, 1); lead = ""; trail = ""; quoted = 0; val = ""; tail = ""
    if (c == "\"" || c == "\047") {
      quoted = 1; q = c; e = index(substr(rest, 2), q)
      if (e == 0) { val = substr(rest, 2); tail = "" } else { val = substr(rest, 2, e - 1); tail = substr(rest, e + 2); trail = q }
      lead = q
    } else if (match(rest, /^[^[:space:],;)}\]]+/)) {
      val = substr(rest, 1, RLENGTH); tail = substr(rest, RLENGTH + 1)
    } else { tail = rest }
    skip = (val == "" || tolower(val) ~ /^(true|false|null|none|nil|undefined)["\047]?$/ || val ~ /^\[REDACTED/ || val ~ /^[$]/ || (!quoted && (val ~ /^[<{]/ || val ~ /[(\[]/)))
    out = out head lead (skip ? val : "[REDACTED]") trail
    s = tail
  }
  return out s
}
BEGIN {
  KW = "(password|passwd|secret|token|api[_-]?key|credential)[a-z0-9_-]*[\"\047]?[[:space:]]*[:=]+[[:space:]]*"
  KEYB = "-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----"
  KEYE = "-----END [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----"
  inkey = 0; inhdr = 0
}
{
  line = $0
  if (line ~ /^diff --git /) { inhdr = 1; inkey = 0; print line; next }
  if (line ~ /^@@/) { inhdr = 0; inkey = 0 }
  if (inhdr) { print line; next }
  pfx = (substr(line, 1, 1) ~ /[-+ ]/) ? substr(line, 1, 1) : ""
  if (inkey) {
    if (line ~ KEYE) inkey = 0
    print pfx "[REDACTED:private-key]"; next
  }
  if (match(line, KEYB)) {
    if (match(line, KEYB ".*" KEYE)) { line = substr(line, 1, RSTART - 1) "[REDACTED:private-key]" substr(line, RSTART + RLENGTH) }
    else { match(line, KEYB); line = substr(line, 1, RSTART - 1) "[REDACTED:private-key]"; inkey = 1 }
    print line; next
  }
  line = tok(line, "(AKIA|ASIA)[0-9A-Z]+", "", "[REDACTED:aws-key]", 20, 0)
  line = tok(line, "gh[pousr]_[A-Za-z0-9]+", "", "[REDACTED:github-token]", 20, 0)
  line = tok(line, "github_pat_[A-Za-z0-9_]+", "", "[REDACTED:github-token]", 20, 0)
  line = tok(line, "sk-[A-Za-z0-9_-]+", "", "[REDACTED:api-key]", 20, 0)
  line = tok(line, "xox[abp]-[A-Za-z0-9-]+", "", "[REDACTED:slack-token]", 14, 0)
  line = tok(line, "eyJ[A-Za-z0-9_-]+[.][A-Za-z0-9_-]+[.][A-Za-z0-9_-]+", "", "[REDACTED:jwt]", 20, 0)
  line = tok(line, "[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]+", "^[Bb]earer[[:space:]]+", "[REDACTED:bearer]", 12, 1)
  line = assign(line)
  print line
}
'
