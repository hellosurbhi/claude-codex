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
# COVERED (the value is replaced, the rest of the line is kept):
#   - private key blocks (PEM, OpenSSH, PGP), including a block that starts and ends on one line;
#   - AKIA and ASIA access keys, ghp_ gho_ ghu_ ghs_ ghr_ and github_pat_ tokens, sk- keys, xoxa xoxb xoxp xoxs xoxr xoxo tokens and JWTs
#     (these prefixed shapes are masked from a short length up; they are matched only when not glued to a preceding letter or digit);
#   - whatever follows "Bearer " (any length, any characters, up to a quote or whitespace), and whatever follows "Basic " or "Token " after an
#     Authorization header or key (this labeled form uses no shape test at all);
#   - the password in a URL of the form scheme://user:password@host;
#   - the value of a password, passwd, passphrase, secret, token, api key, private key, access key or credential assignment (name may carry a prefix or
#     suffix such as DB_PASSWORD or client_secret_id) written with : or = or =>, quoted (escaped quotes honored, unterminated quote masks to the end of the
#     line) or unquoted (an unquoted value runs to the next whitespace, quote or ampersand; a trailing , ; ) } ] stays).
# NOT COVERED, and passing through unchanged:
#   - any credential in a shape not listed (Stripe, Google, Twilio, Azure and other vendor keys, a bare password with no name beside it, Authorization schemes other
#     than Bearer Basic and Token, a secret in a URL query under a name this list does not know);
#   - an unquoted multi-word value (the words after the first space), or a value split across lines or across a hunk boundary (the lines of a private
#     key that lie outside the hunk that holds its BEGIN line);
#   - values that look like code, left alone on purpose: ${VAR}, $VAR, <placeholder>, {placeholder}, true/false/null and anything shaped like name( or name[ as in
#     get_token() or os.environ["X"] (a real password that happens to look like that also passes);
#   - obfuscated or encoded secrets (base64 of a key, a key split into string pieces).
# Treat the output as "fewer secrets", never as "no secrets".
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
# a value that is a placeholder or ordinary code, never a credential: ${VAR} $VAR <name> {name}, an already-masked value, a boolean or null and name( or name[ (a call or an index)
function placeholder(v) {
  return (v == "" || v ~ /^[$<{]/ || v ~ /^\[REDACTED/ || tolower(v) ~ /^(true|false|null|none|nil|undefined)["\047]?$/ || v ~ /^[A-Za-z_][A-Za-z0-9_.]*[(\[]/)
}
# WHY no shape test here: a value that follows an explicit label (Bearer, or Basic and Token after an Authorization header) is a credential whatever it looks like,
# so it is masked at any length with any characters up to the next quote or whitespace. The old digit-and-12-characters test let "Bearer abcdefghijklmnop" through.
# rx is matched against a lowercase copy (the label is case-insensitive); the same offsets are used on the original text (LC_ALL=C keeps lengths equal).
function labeled(s, rx, hrx, tag,   ls, out, rs, rl, pre, m, head, val, prevc) {
  out = ""
  while (1) {
    ls = tolower(s)
    if (!match(ls, rx)) break
    rs = RSTART; rl = RLENGTH
    pre = substr(s, 1, rs - 1); m = substr(s, rs, rl)
    prevc = (pre != "") ? substr(pre, length(pre), 1) : ((out != "") ? substr(out, length(out), 1) : "")
    match(tolower(m), hrx); head = substr(m, 1, RLENGTH); val = substr(m, RLENGTH + 1)
    if (prevc ~ /[A-Za-z0-9]/ || placeholder(val)) { out = out pre substr(m, 1, 1); s = substr(s, rs + 1) }
    else { out = out pre head tag; s = substr(s, rs + rl) }
  }
  return out s
}
# scheme://user:password@host, the password only
function url(s,   out, rs, rl, pre, m, h, v) {
  out = ""
  while (match(s, "://[^/[:space:]:@\"\047]+:[^/[:space:]@\"\047]+@")) {
    rs = RSTART; rl = RLENGTH; pre = substr(s, 1, rs - 1); m = substr(s, rs, rl)
    match(m, "^://[^:]+:"); h = substr(m, 1, RLENGTH); v = substr(m, RLENGTH + 1, length(m) - RLENGTH - 1)
    out = out pre h (placeholder(v) ? v : "[REDACTED]") "@"
    s = substr(s, rs + rl)
  }
  return out s
}
function assign(s,   k, ch, ls, out, hs, hl, head, rest, c, q, e, val, tail, lead, trail, quoted, skip) {
  out = ""
  while (1) {
    ls = tolower(s)
    if (!match(ls, KW)) break
    hs = RSTART; hl = RLENGTH
    head = substr(s, 1, hs + hl - 1); rest = substr(s, hs + hl)
    c = substr(rest, 1, 1); lead = ""; trail = ""; quoted = 0; val = ""; tail = ""
    if (c == "\"" || c == "\047") {
      # WHY a character scan and not index(): a backslash escapes the next character, so an escaped quote inside the value is not the closing quote (index() ended the value at the escaped
      # quote and left the rest of the secret in the diff); an escaped backslash (two of them) does not escape the quote after it. No closing quote: the value runs to the end of the line.
      quoted = 1; q = c; e = 0
      for (k = 2; k <= length(rest); k++) {
        ch = substr(rest, k, 1)
        if (ch == "\\") { k++; continue }
        if (ch == q) { e = k; break }
      }
      if (e == 0) { val = substr(rest, 2); tail = "" } else { val = substr(rest, 2, e - 2); tail = substr(rest, e + 1); trail = q }
      lead = q
    } else if (match(rest, /^[^"\047[:space:]&]+/)) {
      # WHY the value runs past , ; ) } ] (only a TRAILING run of them is split off): a password may contain them, and stopping at the first one left the rest of the secret in the diff.
      val = substr(rest, 1, RLENGTH); tail = substr(rest, RLENGTH + 1)
      if (match(val, /[,;)}\]]+$/)) { tail = substr(val, RSTART) tail; val = substr(val, 1, RSTART - 1) }
    } else { tail = rest }
    skip = quoted ? (val == "" || tolower(val) ~ /^(true|false|null|none|nil|undefined)["\047]?$/ || val ~ /^\[REDACTED/ || val ~ /^[$]/) : placeholder(val)
    out = out head lead (skip ? val : "[REDACTED]") trail
    s = tail
  }
  return out s
}
BEGIN {
  KW = "(password|passwd|passphrase|secret|token|api[_-]?key|private[_-]?key|access[_-]?key|credential)[a-z0-9_-]*[\"\047]?[[:space:]]*[:=]+>?[[:space:]]*"
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
  line = tok(line, "(AKIA|ASIA)[0-9A-Z]+", "", "[REDACTED:aws-key]", 16, 0)
  line = tok(line, "gh[pousr]_[A-Za-z0-9]+", "", "[REDACTED:github-token]", 12, 0)
  line = tok(line, "github_pat_[A-Za-z0-9_]+", "", "[REDACTED:github-token]", 20, 0)
  line = tok(line, "sk-[A-Za-z0-9_-]+", "", "[REDACTED:api-key]", 12, 0)
  line = tok(line, "xox[abposr]-[A-Za-z0-9-]+", "", "[REDACTED:slack-token]", 10, 0)
  line = tok(line, "eyJ[A-Za-z0-9_-]+[.][A-Za-z0-9_-]+[.][A-Za-z0-9_-]*", "", "[REDACTED:jwt]", 16, 0)
  line = labeled(line, "bearer[[:space:]]+[^\"\047[:space:]]+", "^bearer[[:space:]]+", "[REDACTED:bearer]")
  line = labeled(line, "authorization[\"\047]?[[:space:]]*[:=][[:space:]]*[\"\047]?(basic|token)[[:space:]]+[^\"\047[:space:]]+", "^.*(basic|token)[[:space:]]+", "[REDACTED:auth]")
  line = url(line)
  line = assign(line)
  print line
}
'
