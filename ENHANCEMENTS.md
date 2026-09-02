# Enhancement backlog

Findings from the automated triage passes that a pass rates LOW. Severity is
what routes a finding here rather than what the finding is about, so a MEDIUM
raised against this file is recorded in `BUGS.md` while the text fix it calls
for lands here. Resolved entries stay here as a record of what was changed or
dismissed and why. The pending queue below is empty when every triaged finding
has been closed out.

The Mechanical checks section of `BUGS.md` reaches this file through three of
its eight checks rather than through one. Checks 1 plus 2 grep every tracked
Markdown file together with every tracked JSON file at the pinned branch tip, a
set this file has belonged to since `07a2d4b` made it tracked. Check 8 greps
this file by name in the working copy, which is what puts the edit a pass is
still holding uncommitted inside the record. All three look for the same two
punctuation patterns: the em dash pattern plus the serial comma pattern. That is
the whole of the coverage. No other figure published here is backed by that
section, so each one carries its own command beside it rather than deferring
there.

One condition travels with that coverage into this file. The em dash half of
each of the three greps passes `-P`, which is an optional feature of a `git`
build rather than a property of every `git`, so a reader whose build lacks
libpcre2 gets an error in place of the result recorded there. The serial comma
half passes `-E` plus carries no such condition. `BUGS.md` records the
substitution that lets a reader in that position run the check anyway, together
with why that substitution cannot itself be published as the command. This is
stated here rather than left in `BUGS.md` for the reason the entry below
records: a scope that reaches into a second file has to be readable from that
file.

This file was created by the pass of 2026-08-31 that closed the finding below.
Two of the three WONTFIX entries in `BUGS.md` dated 2026-08-29 say that
`ENHANCEMENTS.md` does not exist in this repository. They are the second entry
of that run together with the third, sitting at `BUGS.md:37-38` as the file
stood at `07a2d4b`, cited by position as well as by line because a later edit to
that file moves the lines while the positions hold. The first of the three says
no such thing: it dismisses a quotation that matches nothing in the tree, naming
neither file. What the other two say was true when they were written. It is no
longer true, so those two are read as the record of a finding dismissed against
the tree as it then stood rather than as a standing claim about the tree.

## Resolved (2026-08-31)

- FIXED(LOW, 2026-08-31): INCOMPLETE-CITATION: the NONREPRODUCIBLE-CHECK entry at `BUGS.md:11` enumerated six locations, the preamble to the mechanical checks together with checks 1, 2, 5, 6 plus 7, while citing three line numbers: `BUGS.md:57-58`, `BUGS.md:69` plus `BUGS.md:71`. Checks 1, 2 plus 6 sit at lines 65, 66 plus 70 in the parent commit `6733c80`, which the entry measures its line numbers against, so three of the six enumerated locations resolved to no citation at all. A reader checking the entry against its own evidence could confirm half of it. | Fix: the entry now cites each of the six separately, naming `6733c80` as the revision the line numbers are read at so the citations stay checkable after this file moves again. The preamble citation is widened from `BUGS.md:57-58` to `BUGS.md:56-58`, because the sentence carrying the endpoint claim begins on line 56 while only its literal fell inside the old range. This is the smaller half of the same defect the FALSE-UNIVERSAL entry in `BUGS.md` records against the same line: an enumeration published wider than the evidence attached to it. The difference is that the citation list was short rather than wrong, which is why it is filed here at LOW rather than there. Raised by the Codex pass of 2026-08-31T20:01Z.

## Low priority (pending)

Empty. The one finding from the Codex pass of 2026-08-31T20:01Z is closed out
under Resolved (2026-08-31) above. Two later passes raised MEDIUM severity
findings against the preamble of this file, the pass of 2026-08-31T20:55Z
against the coverage claim it carried then plus the pass of 2026-09-01T19:00Z
against the sentence that replaced it. Both are closed out under
Resolved (2026-09-01) in `BUGS.md` rather than here, because severity rather
than location decides which file records a finding. The edits they called for
landed above.

The build condition paragraph above landed under the same rule, from a CRITICAL
raised against `BUGS.md` by the Codex pass of 2026-09-02T07:05Z plus closed out
under Resolved (2026-09-02) there. No finding was raised against this file that
time. The paragraph is here because the condition qualifies a figure this file
would otherwise appear to stand behind unconditionally, which is the same
reason the coverage sentence above had to be corrected twice.
