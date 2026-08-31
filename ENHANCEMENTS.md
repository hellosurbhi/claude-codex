# Enhancement backlog

Findings from the automated triage passes that are not defects in the shipped
copy or in a published figure, so they do not belong in `BUGS.md`. Resolved
entries stay here as a record of what was changed or dismissed and why. The
pending queue below is empty when every triaged finding has been closed out.

Severity here is LOW by definition. Anything a pass rates MEDIUM or above goes
to `BUGS.md`, whose Mechanical checks section carries the commands behind every
figure either file publishes. Check 8 there covers this file.

This file was created by the pass of 2026-08-31 that closed the finding below.
The three WONTFIX entries in `BUGS.md` dated 2026-08-29 say that
`ENHANCEMENTS.md` does not exist in this repository. That was true when they
were written. It is no longer true, so those entries are read as the record of a
finding dismissed against the tree as it then stood rather than as a standing
claim about the tree.

## Resolved (2026-08-31)

- FIXED(LOW, 2026-08-31): INCOMPLETE-CITATION: the NONREPRODUCIBLE-CHECK entry at `BUGS.md:11` enumerated six locations, the preamble to the mechanical checks together with checks 1, 2, 5, 6 plus 7, while citing three line numbers: `BUGS.md:57-58`, `BUGS.md:69` plus `BUGS.md:71`. Checks 1, 2 plus 6 sit at lines 65, 66 plus 70 in the parent commit `6733c80`, which the entry measures its line numbers against, so three of the six enumerated locations resolved to no citation at all. A reader checking the entry against its own evidence could confirm half of it. | Fix: the entry now cites each of the six separately, naming `6733c80` as the revision the line numbers are read at so the citations stay checkable after this file moves again. The preamble citation is widened from `BUGS.md:57-58` to `BUGS.md:56-58`, because the sentence carrying the endpoint claim begins on line 56 while only its literal fell inside the old range. This is the smaller half of the same defect the FALSE-UNIVERSAL entry in `BUGS.md` records against the same line: an enumeration published wider than the evidence attached to it. The difference is that the citation list was short rather than wrong, which is why it is filed here at LOW rather than there. Raised by the Codex pass of 2026-08-31T20:01Z.

## Low priority (pending)

Empty. The one finding from the Codex pass of 2026-08-31T20:01Z is closed out
under Resolved (2026-08-31) above.
