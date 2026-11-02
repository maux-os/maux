*---------------------------------------------------------------
* extestb8.s -- continuation of extestb7.s's PARENT_PROC (the
* `!` shell-escape/filter family, 2026-09-06). `put` in
* extest.s BETWEEN extestb7.s and extestb9.s. Entry is
* SESS9START (below),
* reached by an explicit `jmp` from extestb7.s's own session 8
* tail -- extestb7.s's trailing DATA sits between the two files
* in `put` order, so a plain fallthrough would land in the
* middle of it. This file's own NINTH session driver ends with
* an explicit `jmp SESS10START` into extestb9.s (the review
* review regression cases, 2026-09-06) -- PFAIL/:pfailpark stay
* HERE (moved here from extestb7.s) since every session, incl.
* extestb9.s's, reaches them by a plain `jmp PFAIL`.
* extestb3.s's shared helpers/scratch/paths/content still stay
* LAST, `put` after extestb9.s.
*
* Drives ex through a REAL spawned `sh` (build_ex_image.py now
* also stages sh.bin/sort.bin/cat.bin at /bin/sh,SORT,CAT):
* `1,$!sort` (the FILTER form) sorts a range in place through a
* REAL spawned `sh` -> `sort`; `$r !cat` (the r! form) appends a
* second fixture's text read through `cat`; `1,2w !cat` (the w!
* form) writes a range to `cat`'s stdin with no read-back;
* `!cat` (the shell-escape ESC form) runs a bare command with no
* buffer interaction. Proves ALL FOUR `!` forms end to end, the
* read-back plumbing (EX_WRR_FD/ED_DLT_RANGE/ED_READLOOP) shared
* by the filter and r! forms.
*
* THE FILTER FORM NEEDED A REAL FIX, not just a script: `sort`/
* `cat` spawned as `sh`'s own child (ex -> sh -> filter, three
* process levels) produced NO output on EX.OUTxx even though
* every byte ex itself wrote (the script, the input file) was
* independently confirmed correct on disk -- the classic silent
* iobuf-exhaustion symptom (docs handoff, 2026-09-06). Root
* cause: the filter is the ONE `!` form whose grandchild needs
* TWO files open at once (EX.INxx via `<`, EX.OUTxx via
* fdactions fd 1), and ex's OWN swap file (EXSW_FD) stays open
* the whole session too -- one iobuf too many against the
* kernel-wide pool. EX_BANG_FILT now closes EXSW_FD across the
* spawn+wait (EX_BG_SWCLOSE) and reopens it before ED_READLOOP's
* first insert (EX_BG_SWOPEN) -- see those routines' own header
* for why this is safe (the swap file's own bytes are untouched;
* only the fd is transient).
*---------------------------------------------------------------
* -- Session 9 result addresses, own block $1F00-$1FFF. --
R_LEN9      equ   $1F00      ;byte count from EXCAP9 (all FOUR
                             ;console outputs, concatenated)
R_STAGE9    equ   $1F10      ;up to 96 bytes -- ends $1F6F
R_LENOUT9   equ   $1F70      ;byte count from EXOUT9
R_STAGEOUT9 equ   $1F78      ;up to 96 bytes -- ends $1FD7
R_SPAWN_PID9  equ $1FE0
R_SPAWN_STAT9 equ $1FE1
R_WAIT_PID9   equ $1FE2

*---------------------------------------------------------------
* NINTH session -- the `!` family (2026-09-06). Script trace:
*   r /mnt/MAUX/EXSRC9       -> load "pear"/"kiwi"/"fig"/"mango"
*   1,$!sort              -> (no output) FILTER: spawns sh ->
*                           `sort`, replaces the 4 lines with
*                           "fig"/"kiwi"/"mango"/"pear"
*   %p                    -> prints those 4 sorted lines
*   $r !cat /mnt/MAUX/EXSRC9B -> (no output) r!: spawns sh ->
*   cat,
*                           appends "X1"/"X2" after line 4
*   %p                    -> prints all 6 lines
*   1,2w !cat             -> w!: spawns sh -> cat, writes "fig"/
*                           "kiwi" to its stdin; cat echoes them
*                           to the INHERITED console fd (EXCAP9)
*                           -- no buffer change
*   !cat /mnt/MAUX/EXSRC9B   -> ESC: spawns sh -> cat, prints
*                           "X1"/"X2" straight to the console
*                           (EXCAP9) -- no buffer change
*   w /mnt/MAUX/EXOUT9 -> writes the still-6-line buffer back
*   q                     -> quit
* All FOUR console-bound outputs land in one captured EXCAP9
* file; EXOUT9 is read back separately. check_ex.py compares
* both, byte-exact including CR ($8D) line endings.
*---------------------------------------------------------------
SESS9START
* -- EXSRC9/EXSRC9B/EXSCR9 are staged on ex.po at build time by
* -- scripts/build_ex_image.py (FIXTURES; extestb.s session 1's
* -- own note has the why) -- content documented below.
* -- RUN_SESSION + DESC9/RBL9 (2026-09-12, table-driven; sit
* -- near the Session 9 paths below).
            lda   #<DESC9
            ldx   #>DESC9
            jsr   RUN_SESSION

            jmp   SESS10START

PFAIL       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:pfailpark  bra   :pfailpark

*---------------------------------------------------------------
* EXSRC9 (the file the NINTH session loads via `r`, deliberately
* unsorted: pear/kiwi/fig/mango), EXSRC9B (the second fixture,
* read through `cat` by the `$r !cat` sub-case: X1/X2) and
* EXSCR9 (the script -- the header comment above has the full
* per-command trace) are all staged at build time; their bytes
* are build_ex_image.py's FIXTURES.
*---------------------------------------------------------------

*---------------------------------------------------------------
* Session 9 paths.
*---------------------------------------------------------------
PATH_EXSCR9  dfb 16
             asc '/mnt/MAUX/EXSCR9'
PATH_EXCAP9  dfb 16
             asc '/mnt/MAUX/EXCAP9'
PATH_EXOUT9  dfb 16
             asc '/mnt/MAUX/EXOUT9'

DESC9       da    PATH_EXCAP9,PATH_EXSCR9,0
            da    R_SPAWN_PID9,R_SPAWN_STAT9,R_WAIT_PID9
            dfb   0,10,2
            da    RBL9
RBL9        da    PATH_EXCAP9,R_STAGE9
            dfb   96,0
            da    R_LEN9
            da    PATH_EXOUT9,R_STAGEOUT9
            dfb   96,0
            da    R_LENOUT9

*-- PAR_PROC_LEN stays at extestb3.s's own tail (unchanged) --
*-- extestb3.s is still the LAST put file (`put` order:
*-- extestb.s, extestb2.s, extestb4.s, extestb5.s, extestb6.s,
*-- extestb7.s, extestb8.s, extestb3.s), so it is still the
*-- textually LAST thing PARENT_PROC's continuous byte stream
*-- emits.
