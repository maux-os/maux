*---------------------------------------------------------------
* regexbss.s -- regex.s's \( \) \1-\9 capture storage (W5,
* docs/ANACHRONISMS.md -- grouping + backreferences).
*
* A SEPARATE module from libabss.s ON PURPOSE, and check-
* modules enforces the reason from the other direction too (a
* liba module may not reference a symbol only a PROGRAM
* defines, so these cells cannot live inline in ed.s/ex.s/
* grep.s/sed.s either -- regex.s itself reads and writes them).
* libabss.s is `put` by EVERY program in the tree, including
* ones that never link regex.s at all (as.s among them);
* growing it by 36 bytes cost as.s exactly the margin it did
* not have (measured 2026-09-02: as.s's own `err */SYMADR`
* tripwire, src/bin/as.s line 885, had 26 bytes of headroom
* before this feature and needs 36). Chaining a SECOND `dum
* LIBA_BSSEND` block here -- the same technique ed.s already
* uses for its own ED_ZPGRSV/ED_HEAP (that file's "sec 21"
* comment) -- costs nothing in any program that does not `put`
* this file.
*
* `put` this AFTER libabss.s in every program that also `put`s
* regex.s + regex2.s (ed.s, ex.s, grep.s, sed.s -- no other unit
* reaches regex.s), and repoint that program's OWN trailing
* `dum` from `LIBA_BSSEND` to `REGEX_BSSEND` so the two arenas
* CHAIN instead of aliasing (two `dum` blocks anchored at the
* same symbol are the same bytes -- ed.s's own header comment on
* its ED_HEAP block says so already). regex.s's AND regex2.s's
* references to RE_GRPST/RE_GRPEND (the 2026-09-02 split put
* RE_GSSAVE/RE_BKMATCH in the latter) are forward references to
* a `ds` LABEL, not an EQU -- the Merlin-8 forward-reference
* trap this tree works around everywhere else applies only to
* EQU operands.
*
* RE_GRPST's hi bytes are the write-before-read: RE_MATCH's own
* entry unconditionally sets every one to $FF (the "never
* captured" sentinel RE_BKMATCH checks) before any group can be
* opened or any backref read, on EVERY call -- so garbage here
* is never observed. RE_GRPEND is read only through an index
* RE_MATCH's own bookkeeping just wrote. X-indexed absolute
* addressing only (RE_GRPST,x etc), never (ptr),y -- so neither
* array needs zero page.
*---------------------------------------------------------------
*
* POSIX leftmost-longest (W5d, 2026-09-11): RE_MATCH sets
* RE_PATEND (the pattern's own NUL) and RE_LONGEST (1 when the
* pattern holds a \( -- the only shape where greedy-first can
* come up shorter than the longest match) on EVERY call before
* any read, and clears RE_BESTSET per start position; RE_BEST
* and the RE_BGRP* snapshot are read only after RE_BESTSET was
* set by the write that filled them. Absolute cells, never
* (ptr),y -- no zero page.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
RE_GRPST    ds    18        ;9 groups x 2 bytes -- start ptr
RE_GRPEND   ds    18        ;9 groups x 2 bytes -- end ptr
RE_PATEND   ds    2         ;ptr to the pattern's NUL
RE_LONGEST  ds    1         ;1 = explore all, keep the longest
RE_BESTSET  ds    1         ;1 = RE_BEST holds a match end
RE_BEST     ds    2         ;longest match end so far
RE_BGRPST   ds    18        ;captures at the best match
RE_BGRPEND  ds    18
RE_GSACT    ds    1         ;1 while RE_GSTAR's NUL is planted
RE_GSS      ds    2         ;RE_GSTAR's private RE_GS
RE_GCC      ds    2         ;.. RE_GCONT
RE_GNN      ds    1         ;.. RE_GNUM
REGEX_BSSEND
            dend
