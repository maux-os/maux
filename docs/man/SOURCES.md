# Manual source register

Updated 2026-09-19. Follow [the manual policy](../MAN.md), not an imitation
of historical style. These pages retain historical descriptions and useful
examples, adapted to current maux syntax, limits and diagnostics.

Each adapted page records its exact archive URL/path, SHA-256 of the
retrieved response, modification date and source-selection decision.
TUHS responses wrap roff in HTML; the V1 witness is the First Edition
transcription at man.cat-v.org. Checksums identify retrieved witnesses,
not modified maux text. Archive navigation may change independently of text.

## Sources selected for this coverage repair

| Witness | Pages based on it |
| --- | --- |
| Research UNIX V1 (1971) | cat, chmod, cmp, cp, date, df, du, ed, ls, mkdir, mv, nm, od, rm, sum, wc |
| Research UNIX V6 (1975) | comm, dd, echo, file, find, grep, kill, ps, pwd, sleep, sort, stty, tee, time, tr, uniq |
| Research UNIX V7 (1979) | expr, false (from true.1), sh, tail, touch, true |
| 4.3BSD-Reno (1990), file-local permissive notice | ex, reset (from tset.1), tip |
| 4.4BSD (1993), file-local permissive notice | vi |
| Original house pages, rationale in each header | as, bpatch, chvt, ld, nas, plasma, proshim, vidmode |

The search was bounded: First Edition, then V6/V7 for Research commands;
2BSD, 4.3BSD and subsequent file-local grants for Berkeley commands.
V1 find has a whole-filesystem name/inode interface, so V6's pathname/
expression description is the useful basis. V1/V6 sh describe the Thompson
shell; V7 is the first applicable Bourne manual. For other V6/V7 selections,
no suitable earlier page was located in that search. This is not a claim
to have exhausted every surviving intermediate edition.

The 2BSD ex/vi/reset pages were located and read, but had no explicit
permissive notice in the files. The 4.3BSD ex/vi pages referred to a separate
Berkeley Software License Agreement. Rather than assume public availability
cleared those versions, this batch selects later file-local grants:
Reno ex/tset/tip, and 4.4BSD vi (Reno vi still had the older agreement
reference). Earlier cleared witnesses remain welcome replacements.
Original file notices and SCCS revisions are retained in the derived pages.
No BSD page is attributed to the Caldera grant.

The house-tool exceptions are substantive: Research as/ld describe PDP-11
syntax and objects, not Merlin REL; the others expose maux-specific
runtimes, patch specifications and display protocols.

## Licence distribution

Research UNIX text uses the [Caldera Ancient UNIX grant](CALDERA-LICENSE),
which names V1-V7 and 32V. Berkeley file-local grants are collected in
[BSD-LICENSE](BSD-LICENSE). Imported text is not relabelled as maux MIT text.
Street-library `learning:01M282XCWWYYNJYVRJ3JA7GDM1` guided the Research
UNIX licence check: it identifies the grant's scope and the documentation
notice requirement; the retained grant is the primary evidence.

[licenses(1)](licenses.1) carries notices, conditions, disclaimers and
acknowledgements in rendered form on disk. Source-only roff comments would
not satisfy that packaging obligation. Read it with `man licenses`.
The original Berkeley notices are retained, including advertising wording;
we do not need to rely on the 1999 deletion of that condition to distribute
these pages with acknowledgements intact.

This product includes software developed or owned by Caldera International,
Inc. This product includes software developed by the University of
California, Berkeley and its contributors.

## Existing pages and scope

The skeletal cp/mv/ls/rm pages were rebuilt on V1 bases without dropping
their implemented options. Other existing pages retain recorded provenance;
sed already acknowledges a V7 derivation. This repair does not invent
ancestry for existing original pages or claim that their entire prose
has been re-audited.

All 83 Makefile utilities plus separately built nas and ld now have pages.
Shell builtins are documented in sh(1), rather than pretending punctuation
commands such as `[` can have ProDOS file names. There are also 63
unavailable-command stubs and one licence page: 149 pages total.
Development-image-only commands state that boundary; an installed manual
does not imply its executable is on the play disk.

`make check-man-image` derives coverage from the build roster, checks current
renders and compares every staged page's bytes and TXT metadata. It does
not prove arbitrary prose claims; command changes still need page review.
