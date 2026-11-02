*---------------------------------------------------------------
* extestb9.s -- continuation of extestb8.s's PARENT_PROC: the
* adversarial-review regression cases (EX1/EX2/EX6/EX7,
* 2026-09-06), PLUS sessions 14-16 (EX3/EX4/EX5, 2026-09-06,
* second adversarial pass -- see the design review). `put` in
* extest.s BETWEEN extestb8.s and extestb3.s. Entry is
* SESS10START (below), reached by an explicit `jmp` from
* extestb8.s's own session 9 tail. This file's own SIXTEENTH
* session driver ends with the actual `lda #$AA / sta R_DONE /
* :donepark bra :donepark` epilogue (moved here from extestb8.s)
* -- PFAIL/:pfailpark stay in extestb8.s, reached from here by a
* plain `jmp PFAIL`, same as every other session. extestb3.s's
* shared helpers/scratch/paths/content still stay LAST, `put`
* after this file.
*
* Result addresses: $1200-$1FFF (the "free scratch below
* PARENT_PROC" convention, extestb.s's own header) is FULLY
* SPENT by sessions 1-9 (session 9 ends at $1FE2, 29 bytes shy
* of PARENT_PROC's own code, which starts well above $2000 --
* see build/MAUXEXTEST.SYSTEM_Output.txt, PARENT_PROC resolves
* to $749F and PAR_PROC_LEN's own span ends at $88A9 as of this
* writing). This file's own new sessions use a SEPARATE fixed
* block, $A800-$AEFF (sessions 10-13 at $A800-$ABFF; sessions
* 14-16 EXTEND that same reservation forward to $AC00-$AEFF).
* MOVED UP $1000 on 2026-09-08 (job-control Increment B): the
* block was $9800-$9EFF, "chosen with several hundred bytes of
* headroom above [the image's] end address" -- and two kernel
* increments in one day (A +297 B, B +445 B) walked the image's
* tail to $9C02, THROUGH the block: session 10's first result
* writes landed on this harness's own helpers/parm blocks in
* bank 1 and step 40 died with a $40 (invalid pathname) that
* looked like an ex regression. The image is copied to bank 1
* at ITS OWN addresses (extestb.s BOOT_CPY_PAR), so the block
* must sit above the image's END, not above some fixed number.
* $A800 leaves ~3 KB; scripts/check_ex.py's R_* copies moved
* with it. Rebuild and check the listing's own PARENT_PROC/
* PAR_PROC_LEN-derived end address before pushing either
* boundary further.
*
* /mnt/MAUX/EXR9 subdirectory (measured 2026-09-06): the
* volume's
* ROOT directory is a fixed 4-block ProDOS allocation -- it does
* NOT grow past 51 entries, confirmed empirically (a2til's own
* `put` starts refusing with ENOSPC/"volume directory is full"
* at the 50th file added to a fresh carrier, 2 + 49 = 51). By
* session 9 the root already carries ~36 persistent files from
* sessions 1-9 plus PRODOS/MAUX.SYSTEM/EX/SH/SORT/CAT; adding
* these four sessions' own 15 files there (the first attempt)
* silently starved EX_RBANG's own EX.INxx/EX.OUTxx/EX.CMDxx temp
* files of a free directory slot right when `0r`/`$r` tried to
* create them -- CREATE failed silently (best-effort, per
* CRT_BY_PATH/ED_DOWRITE's own convention) and the subsequent
* OPEN then failed with $46 (file not found), which looked
* exactly like a refusal until traced with a2til/interactively.
* Routing every new file under ONE subdirectory costs the root
* only ONE more entry instead of fifteen, leaving headroom for
* the handful of transient EX_BG_MKNAM temp files any single
* r!/w!/filter call needs at once. 2026-09-08: the subdirectory
* AND every fixture/script below are staged at BUILD time by
* scripts/build_ex_image.py (FIXTURE_DIR/FIXTURES) -- this file
* used to create the directory and write each fixture from
* embedded text via STAGE_WRD, which is what kept
* MAUXEXTEST.SYSTEM over PMLI_IBF_BASE (check_kernel_images.py's
* KNOWN_OVERRUN note). The per-command traces stay here; the
* bytes are in the build script.
*---------------------------------------------------------------

*---------------------------------------------------------------
* Session 10 (EX1, 2026-09-06) -- `r !cmd`'s missing ED_CHECK0N.
* Buffer starts as ONE line ("original"). Trace:
*   a / original / .    -> insert the one line
*   99r !echo NEW        -> REFUSED (out-of-range address) --
*                          silent (ex -s), no mutation
*   %p                   -> "original" (proves untouched)
*   0r !cat EXFIXZ        -> valid boundary: ADDR1=0, inserts
*                          "ZERO" before line 1 (via `cat` on a
*                          staged fixture -- see this file's
*                          fixture-staging comment for why not
*                          `!echo`)
*   $r !cat EXFIXL        -> valid boundary: ADDR1=$=NLINES,
*                          inserts "LAST" after the last line
*   %p                   -> "ZERO","original","LAST"
*   u                    -> undo the last mutation ($r) --
*                          proves the refused 99r above did NOT
*                          corrupt the undo snapshot chain
*   %p                   -> "ZERO","original" (LAST removed)
*   w EXOUT10, q         -> write the 2-line buffer back, quit
*                          (path: /mnt/MAUX/EXR9/EXOUT10)
* Exit status is 1 (EX2): the refused 99r sets ED_ERRSTAT, and
* it stays set through the rest of the (otherwise successful)
* session -- confirmed against this host's own ex (vim's ex
* mode), which behaves identically.
*---------------------------------------------------------------
R_LEN10       equ   $A800    ;byte count from EXCAP10 (all THREE
                             ;%p outputs, concatenated)
R_STAGE10     equ   $A810    ;up to 64 bytes -- ends $A84F
R_LENOUT10    equ   $A860    ;byte count from EXOUT10
R_STAGEOUT10  equ   $A868    ;up to 32 bytes -- ends $A887
R_SPAWN_PID10  equ  $A890
R_SPAWN_STA10 equ  $A891
R_WAIT_PID10   equ  $A892

SESS10START
* -- /mnt/MAUX/EXR9, the two `r!` fixtures `cat` reads (EXFIXZ/
* -- EXFIXL) and EXSCR10 are on ex.po already (build_ex_image.
* -- py, see this file's header). Why `cat` and not `!echo`
* -- (measured 2026-09-06): `!echo` silently produces NOTHING
* -- under fd0/fd1 redirection, NOT an ex bug -- shbltn.s's
* -- CHCK_BLTN_ECH deliberately falls through to an EXTERNAL
* -- echo binary whenever output is redirected (its own header
* -- explains why), and this test image stages sh/sort/cat/ex
* -- only, no echo binary -- so a redirected `!echo` always
* -- fails "not found". `cat` has no such builtin/external
* -- split; use it instead, exactly like session 9's own
* -- `$r !cat`. RUN_SESSION + DESC10/RBL10 (2026-09-12,
* -- table-driven) sit near the Session 10 paths below --
* -- CLOSE_EARLY=1 preserves sessions 10-16's own "close
* -- SINFD/SOUTFD right after spawn, before WAIT_ONE" order
* -- (frees io_buffer slots the spawned sh/cat chain needs).
            lda   #<DESC10
            ldx   #>DESC10
            jsr   RUN_SESSION

            jmp   SESS11START

* -- EXSCR10 (the header comment above has the trace), EXFIXZ
* -- ("ZERO") and EXFIXL ("LAST"): build_ex_image.py's FIXTURES.
PATH_EXSCR10 dfb 22
             asc '/mnt/MAUX/EXR9/EXSCR10'
PATH_EXCAP10 dfb 22
             asc '/mnt/MAUX/EXR9/EXCAP10'
PATH_EXOUT10 dfb 22
             asc '/mnt/MAUX/EXR9/EXOUT10'

DESC10      da    PATH_EXCAP10,PATH_EXSCR10,0
            da    R_SPAWN_PID10,R_SPAWN_STA10,R_WAIT_PID10
            dfb   1,11,2
            da    RBL10
RBL10       da    PATH_EXCAP10,R_STAGE10
            dfb   64,0
            da    R_LEN10
            da    PATH_EXOUT10,R_STAGEOUT10
            dfb   32,0
            da    R_LENOUT10

*---------------------------------------------------------------
* Session 11 (EX2, 2026-09-06) -- a refused command has no exit
* status. TWO spawns, same shape as sessions 5/5n's a/b pair:
*   11A (bad): a/onlyline/. , 999p (refused, silent), q! ->
*     stdout empty, exit status 1
*   11B (good): a/onlyline/. , 1p (succeeds), q! -> stdout
*     "onlyline", exit status 0
* Reproduces the review's own case verbatim (999p then q!,
* checked against $?, not just stdout/files).
*
* XC4 2026-09-06 (second closing pass) PIGGYBACKS on 11B
* rather than spawning a fifth process: MAUXEXTEST.SYSTEM sits
* only 138B under PMLI_IBF_BASE ($9800, check_kernel_images.py's
* ceiling) with NO room for a whole new session's own spawn/
* capture/fixture plumbing (each of sessions 10-16 costs 400-
* 650B just in that overhead). `!exit 7` inserted before 11B's
* own `q!` adds a real shell child that exits nonzero -- EX2's
* own WSTAT->ED_ERRSTAT fold (withdrawn, XC4) would have flipped
* 11B's ALREADY-asserted exit-0 expectation to 1; `!exit 7`
* itself prints nothing, so EXPECT_CAP11B is unchanged.
*---------------------------------------------------------------
R_LEN11A       equ   $A900    ;byte count from EXCAP11A (0
                             ;expected)
R_STAGE11A     equ   $A908    ;up to 16 bytes -- ends $A917
R_PID11A  equ  $A920
R_STA11A equ  $A921
R_WAIT_PID11A   equ  $A922

R_LEN11B       equ   $A930    ;byte count from EXCAP11B
R_STAGE11B     equ   $A938    ;up to 16 bytes -- ends $A947
R_PID11B  equ  $A950
R_STA11B equ  $A951
R_WAIT_PID11B   equ  $A952

SESS11START
* -- 11A (bad) and 11B (the clean/successful control case) --
* -- RUN_SESSION + DESC11A/RBL11A, DESC11B/RBL11B (2026-09-12,
* -- table-driven) sit near the Session 11 paths below.
            lda   #<DESC11A
            ldx   #>DESC11A
            jsr   RUN_SESSION

            lda   #<DESC11B
            ldx   #>DESC11B
            jsr   RUN_SESSION

            jmp   SESS12START

* -- EXSCR11A/EXSCR11B (traced in the header above): the bytes
* -- are build_ex_image.py's FIXTURES.
PATH_EXSCR11A dfb 23
              asc '/mnt/MAUX/EXR9/EXSCR11A'
PATH_EXCAP11A dfb 23
              asc '/mnt/MAUX/EXR9/EXCAP11A'
PATH_EXSCR11B dfb 23
              asc '/mnt/MAUX/EXR9/EXSCR11B'
PATH_EXCAP11B dfb 23
              asc '/mnt/MAUX/EXR9/EXCAP11B'

DESC11A     da    PATH_EXCAP11A,PATH_EXSCR11A,0
            da    R_PID11A,R_STA11A,R_WAIT_PID11A
            dfb   1,12,1
            da    RBL11A
RBL11A      da    PATH_EXCAP11A,R_STAGE11A
            dfb   16,0
            da    R_LEN11A

DESC11B     da    PATH_EXCAP11B,PATH_EXSCR11B,0
            da    R_PID11B,R_STA11B,R_WAIT_PID11B
            dfb   1,13,1
            da    RBL11B
RBL11B      da    PATH_EXCAP11B,R_STAGE11B
            dfb   16,0
            da    R_LEN11B

*---------------------------------------------------------------
* Session 12 (EX6, 2026-09-06) -- `&` shares the prior snapshot.
* Buffer (EXSRC12): two lines, both "aa". Trace:
*   r /mnt/MAUX/EXR9/EXSRC12 -> load "aa","aa"
*   1s/aa/ZZ/         -> "ZZ","aa"
*   2&                -> repeat the last substitution on line 2
*                      -> "ZZ","ZZ"
*   u                 -> WITH the fix, `&` took its OWN
*                      snapshot (of "ZZ","aa", the post-s/
*                      pre-& state), so this undoes ONLY the
*                      `&` -> "ZZ","aa"
*   %p                -> "ZZ","aa"
*   u                 -> a SECOND `u` (single-level undo is
*                      its own inverse, EX_BLKSWAP's own
*                      header) REDOES the `&` -> "ZZ","ZZ" --
*                      verified against this host's own ex
*                      (vim's ex mode): a second `u` here does
*                      NOT reach back past the `&` to the
*                      pre-`s` state, it toggles forward again
*   %p                -> "ZZ","ZZ"
*   w /mnt/MAUX/EXR9/EXOUT12, q -- write 2 lines
* Without the fix, the FIRST `u` above would instead restore
* "aa","aa" (both lines) -- `&` sharing `s`'s own snapshot
* instead of taking its own.
*---------------------------------------------------------------
R_LEN12       equ   $AA00    ;byte count from EXCAP12 (both %p
                             ;outputs, concatenated)
R_STAGE12     equ   $AA10    ;up to 32 bytes -- ends $AA2F
R_LENOUT12    equ   $AA40    ;byte count from EXOUT12
R_STAGEOUT12  equ   $AA48    ;up to 16 bytes -- ends $AA57
R_SPAWN_PID12  equ  $AA60
R_SPAWN_STA12 equ  $AA61
R_WAIT_PID12   equ  $AA62

SESS12START
* -- RUN_SESSION + DESC12/RBL12 (2026-09-12, table-driven) sit
* -- near the Session 12 paths below.
            lda   #<DESC12
            ldx   #>DESC12
            jsr   RUN_SESSION

            jmp   SESS13START

* -- EXSRC12 ("aa","aa") and EXSCR12 (traced in the header
* -- above): build_ex_image.py's FIXTURES.
PATH_EXSCR12 dfb 22
             asc '/mnt/MAUX/EXR9/EXSCR12'
PATH_EXCAP12 dfb 22
             asc '/mnt/MAUX/EXR9/EXCAP12'
PATH_EXOUT12 dfb 22
             asc '/mnt/MAUX/EXR9/EXOUT12'

DESC12      da    PATH_EXCAP12,PATH_EXSCR12,0
            da    R_SPAWN_PID12,R_SPAWN_STA12,R_WAIT_PID12
            dfb   1,14,2
            da    RBL12
RBL12       da    PATH_EXCAP12,R_STAGE12
            dfb   32,0
            da    R_LEN12
            da    PATH_EXOUT12,R_STAGEOUT12
            dfb   16,0
            da    R_LENOUT12

*---------------------------------------------------------------
* Session 13 (EX7, 2026-09-06) -- shell reads inside `g`
* overwrite the global command's undo snapshot. Buffer
* (EXSRC13): "A","B". Trace:
*   r /mnt/MAUX/EXR9/EXSRC13 -> load "A","B"
*   g/[AB]/r !cat EXFIXX -> (no output) BOTH lines match; each
*                         match spawns `sh` -> `cat` on a staged
*                         fixture and inserts "LONGRUN" after it
*                         -> "A","LONGRUN","B","LONGRUN". FF1
*                         2026-09-06: the fixture is 7 chars
*                         (long enough to reach cmds' own start
*                         in CMDBUF for BOTH prefixes below) so
*                         this is now ALSO the FF1 regression --
*                         pre-fix, the first match's read
*                         clobbers the command-list bytes pass 2
*                         needs for the second match.
*   %p                   -> "A","LONGRUN","B","LONGRUN"
*   u                    -> WITH the fix, the pre-global
*                         snapshot (taken once, before pass 1
*                         started) survived both r! calls --
*                         undoes the WHOLE global as ONE unit
*                         -> "A","B"
*   %p                   -> "A","B"
*   u                    -> a second `u` redoes (single-level
*                         undo, same as session 12) -> back to
*                         "A","LONGRUN","B","LONGRUN" --
*                         verified against this host's own ex
*                         (vim's ex mode)
*   %p                   -> "A","LONGRUN","B","LONGRUN"
*   v/Z/r !cat EXR9/EXFIXX -> XC3 2026-09-06 (second
*                           closing pass, PIGGYBACKED onto the
*                           SAME 4-line "A","LONGRUN","B",
*                           "LONGRUN" buffer left by the `g`
*                           case above -- same $9800-ceiling
*                           reason as session 11B's own header,
*                           no need to rebuild a fresh buffer
*                           since none of "A","LONGRUN","B",
*                           "LONGRUN" contains "Z" either:
*                           `v/Z/` (inverse match) matches ALL
*                           FOUR -- reuses the SAME EXFIXX
*                           fixture (relative spelling, cwd
*                           /mnt/MAUX, same as session 15's XC2)
*                           ->
*                           8 lines
*   u                    -> pre-fix, EX_MUTCHECK never listed
*                           `v` as mutating, so `v` took NO
*                           outer snapshot at all (the last one
*                           still in effect was `r`'s own, from
*                           the EMPTY buffer) -- `u` would
*                           restore EMPTY (0 lines), not the 4
*                           lines. Post-fix, `v` gets the same
*                           single outer snapshot `g` does
*                           (EX_MUTCHECK's new `#"v"` case) ->
*                           back to "A","LONGRUN","B","LONGRUN"
*                           (4 lines)
*   %p                   -> "A","LONGRUN","B","LONGRUN"
*   w /mnt/MAUX/EXR9/EXOUT13, q -- write the final 4 lines
* Without the ORIGINAL EX7 fix, the first `u` (of the `g` case,
* above) would undo only the SECOND insert, leaving "A","X","B"
* not "A","B".
*---------------------------------------------------------------
R_LEN13       equ   $AB00    ;byte count from EXCAP13 (all THREE
                             ;%p outputs, concatenated)
R_STAGE13     equ   $AB10    ;up to 64 bytes -- ends $AB4F
R_LENOUT13    equ   $AB50    ;byte count from EXOUT13
R_STAGEOUT13  equ   $AB58    ;up to 32 bytes -- ends $AB77
R_SPAWN_PID13  equ  $AB80
R_SPAWN_STA13 equ  $AB81
R_WAIT_PID13   equ  $AB82

SESS13START
* -- EXFIXX, the `r!` fixture `cat` reads inside the g-pass, is
* -- `cat`-read and not `!echo`-produced for the same reason
* -- session 10's own note explains (no external echo binary
* -- staged; a redirected `echo` falls through to it and fails
* -- "not found"). RUN_SESSION + DESC13/RBL13 (2026-09-12,
* -- table-driven) sit near the Session 13 paths below.
            lda   #<DESC13
            ldx   #>DESC13
            jsr   RUN_SESSION

            jmp   SESS14START

* -- EXSRC13 ("A","B"), EXFIXX ("LONGRUN") and EXSCR13 (traced
* -- in the header above): build_ex_image.py's FIXTURES.
* -- EXFIXX, FF1 2026-09-06 (review): was "X" -- a 1-char
* -- read only ever overwrites CMDBUF[0..1], well short of where
* -- cmds' own text starts (offset 7 for "g/[AB]/", offset 4
* -- for "v/Z/") -- so the ORIGINAL bug (ED_GCMDPTR pointing
* -- INTO CMDBUF, a text-reading sub-command clobbering the
* -- bytes pass 2 still needs to re-parse) was invisible to
* -- this session even before the GCMDBUF fix. 7 chars reaches
* -- (and NUL-terminates) cmds' own start for BOTH prefixes --
* -- long enough to prove the fix, short enough that
* -- EXPECT_CAP13 still fits R_STAGE13's existing window
* -- (above, RMAXLEN bumped 48->64 to match).
PATH_EXSCR13 dfb 22
             asc '/mnt/MAUX/EXR9/EXSCR13'
PATH_EXCAP13 dfb 22
             asc '/mnt/MAUX/EXR9/EXCAP13'
PATH_EXOUT13 dfb 22
             asc '/mnt/MAUX/EXR9/EXOUT13'

DESC13      da    PATH_EXCAP13,PATH_EXSCR13,0
            da    R_SPAWN_PID13,R_SPAWN_STA13,R_WAIT_PID13
            dfb   1,15,2
            da    RBL13
RBL13       da    PATH_EXCAP13,R_STAGE13
            dfb   64,0
            da    R_LEN13
            da    PATH_EXOUT13,R_STAGEOUT13
            dfb   32,0
            da    R_LENOUT13

*---------------------------------------------------------------
* Session 14 (EX4, 2026-09-06, second adversarial pass) --
* `w PATH` was silently rebinding the current filename. Launch
* loads EX14MAIN ("old", one line) via argv (filename-on-launch,
* same shape as session 5). Trace:
*   w /mnt/MAUX/EXR9/EX14COPY -> (no output) writes the CURRENT
*                            buffer ("old") to a NEW path -- NOT
*                            a rebind (the fix)
*   1s/old/new/            -> (no output) buffer -> "new"
*   w                      -> (no output) bare `w` reuses the
*                            REMEMBERED name, which is still
*                            EX14MAIN (launch-set, never touched
*                            by the explicit `w` above) -- write
*                            "new" to EX14MAIN, NOT EX14COPY
*   q!
* Pre-fix: the explicit `w COPY` would have rebound the current
* name to EX14COPY, so the bare `w` would have overwritten
* EX14COPY with "new" and left EX14MAIN untouched at "old" --
* backwards from what's expected below.
*---------------------------------------------------------------
R_LEN14        equ   $1000   ;byte count from EXCAP14 (0
                             ;expected, no `p` in EXSCR14)
R_STAGE14      equ   $1008   ;scratch target, 0 bytes expected
R_LENMAIN14    equ   $1020   ;byte count from EX14MAIN (post-w)
R_STAGEMAIN14  equ   $1028   ;up to 16 bytes -- ends $1037
R_LENCOPY14    equ   $1040   ;byte count from EX14COPY (post-w)
R_STAGECOPY14  equ   $1048   ;up to 16 bytes -- ends $1057
R_SPAWN_PID14  equ   $1060
R_SPAWN_STA14  equ   $1061
R_WAIT_PID14   equ   $1062

SESS14START
* -- RUN_SESSION + DESC14/RBL14 (2026-09-12, table-driven) sit
* -- below, next to the fixture/path data they reference.
* -- ARGV_ARR14 is now static data too (was `ds 6`, filled at
* -- runtime by 6 stores every call -- extestb3.s's own
* -- ARGV_ARR5/ARGV_ARR5N note has the same fix).
            lda   #<DESC14
            ldx   #>DESC14
            jsr   RUN_SESSION

            jmp   SESS15START

* -- EX14MAIN ("old") and EXSCR14 (traced in the header above):
* -- build_ex_image.py's FIXTURES. EX14COPY is created by ex.
AV_EX14MAIN asc   "/mnt/MAUX/EXR9/EX14MAIN"
            dfb   0

ARGV_ARR14  da    AV_EX0,AV_EX14MAIN,0

PATH_EX14MAIN dfb 23
              asc '/mnt/MAUX/EXR9/EX14MAIN'
PATH_EX14COPY dfb 23
              asc '/mnt/MAUX/EXR9/EX14COPY'
PATH_EXSCR14 dfb 22
             asc '/mnt/MAUX/EXR9/EXSCR14'
PATH_EXCAP14 dfb 22
             asc '/mnt/MAUX/EXR9/EXCAP14'

DESC14      da    PATH_EXCAP14,PATH_EXSCR14,ARGV_ARR14
            da    R_SPAWN_PID14,R_SPAWN_STA14,R_WAIT_PID14
            dfb   1,16,3
            da    RBL14
RBL14       da    PATH_EXCAP14,R_STAGE14
            dfb   16,0
            da    R_LEN14
            da    PATH_EX14MAIN,R_STAGEMAIN14
            dfb   16,0
            da    R_LENMAIN14
            da    PATH_EX14COPY,R_STAGECOPY14
            dfb   16,0
            da    R_LENCOPY14

*---------------------------------------------------------------
* Session 15 (EX5, 2026-09-06, second adversarial pass) -- the
* `w!` guard refused a target naming the CURRENT file. Launch
* loads EX15MAIN ("old", one line) via argv; EX15OTHER ("other",
* one line) is pre-staged as a genuinely DIFFERENT existing
* file. Trace:
*   1s/old/new/               -> (no output) buffer -> "new"
*   w /mnt/MAUX/EXR9/EX15MAIN    -> (no output) SAME path as the
*                              launch load -- EX_FNAME_EQ
*                              matches ED_CURFNAME, so the guard
*                              allows this WITHOUT `!` (the fix)
*                              -- EX15MAIN -> "new"
*   1s/new/N2/             -> (no output) buffer -> "N2"
*   w EXR9/EX15MAIN         ->
*                            XC2 2026-09-06 (second
*                            closing pass), PIGGYBACKED here,
*                            same $9800-ceiling reason as
*                            session 11B's own header -- no room
*                            for a dedicated spawn: a RELATIVE
*                            spelling of the SAME current file
*                            (cwd /mnt/MAUX) -- pre-fix,
*                            ED_FNAME_EQ compared raw spellings,
*                            wrongly refused this (MKPATH never
*                            absolutizes a bare relative path);
*                            post-fix both sides canonicalize to
*                            absolute first, so this succeeds
*                            too -- EX15MAIN -> "N2"
*   w /mnt/MAUX/EXR9/EX15OTHER -> REFUSED (silent, script mode)
*                              -- a DIFFERENT existing file
*                              still needs `!`; EX15OTHER stays
*                              "other"
*   q!
* Exit status is 1 (EX2): the refused final `w` sets
* ED_ERRSTAT, same mechanism session 10/11 already exercise.
*---------------------------------------------------------------
R_LEN15         equ   $1070   ;byte count from EXCAP15 (0
                              ;expected, no `p` in EXSCR15)
R_STAGE15       equ   $1078   ;scratch target, 0 bytes expected
R_LENMAIN15     equ   $1090   ;byte count from EX15MAIN (post-w)
R_STAGEMAIN15   equ   $1098   ;up to 16 bytes -- ends $10A7
R_LENOTHER15    equ   $10B0   ;byte count from EX15OTHER
R_STAGOTH15  equ   $10B8   ;up to 16 bytes -- ends $10C7
R_SPAWN_PID15   equ   $10D0
R_SPAWN_STA15   equ   $10D1
R_WAIT_PID15    equ   $10D2

SESS15START
* -- RUN_SESSION + DESC15/RBL15 (2026-09-12, table-driven) sit
* -- below, next to the fixture/path data they reference.
* -- ARGV_ARR15 is now static data too (see session 14's note).
            lda   #<DESC15
            ldx   #>DESC15
            jsr   RUN_SESSION

            jmp   SESS16START

* -- EX15MAIN ("old"), EX15OTHER ("other") and EXSCR15 (traced
* -- in the header above): build_ex_image.py's FIXTURES.
AV_EX15MAIN asc   "/mnt/MAUX/EXR9/EX15MAIN"
            dfb   0

ARGV_ARR15  da    AV_EX0,AV_EX15MAIN,0

PATH_EX15MAIN dfb 23
              asc '/mnt/MAUX/EXR9/EX15MAIN'
PATH_EX15OTH dfb 24
             asc '/mnt/MAUX/EXR9/EX15OTHER'
PATH_EXSCR15 dfb 22
             asc '/mnt/MAUX/EXR9/EXSCR15'
PATH_EXCAP15 dfb 22
             asc '/mnt/MAUX/EXR9/EXCAP15'

DESC15      da    PATH_EXCAP15,PATH_EXSCR15,ARGV_ARR15
            da    R_SPAWN_PID15,R_SPAWN_STA15,R_WAIT_PID15
            dfb   1,17,3
            da    RBL15
RBL15       da    PATH_EXCAP15,R_STAGE15
            dfb   16,0
            da    R_LEN15
            da    PATH_EX15MAIN,R_STAGEMAIN15
            dfb   16,0
            da    R_LENMAIN15
            da    PATH_EX15OTH,R_STAGOTH15
            dfb   16,0
            da    R_LENOTHER15

*---------------------------------------------------------------
* Session 16 (EX3 pipeline REWIRE, 2026-09-06 -- was the
* interim guard's own adversarial pass; the guard it tested is
* now gone, EX_PIPECHK deleted, and `!`/`w !`/`r !` hand `sh` a
* REAL script via argv[1] instead of "cmd < EX.INxx" text, so
* a pipeline attaches to the WHOLE execution, not just its
* last stage).
* EX16SRC: "pear","fig". Trace:
*   r /mnt/MAUX/EXR9/EX16SRC -> load "pear","fig"
*   %!cat | sort          -> REAL pipeline now: `cat` reads the
*                           WHOLE range (fd 0, inherited), pipes
*                           into `sort`, whose stdout is
*                           captured (fd 1) -> "fig","pear"
*   %p                    -> "fig","pear" (proves the FIRST
*                           stage was not starved of input)
*   .=                    -> FF4 2026-09-06 (review): "1"
*                           -- EX_BANG_FILT sets dot to the
*                           FIRST line of the filter's own
*                           replaced text (POSIX), not the LAST
*                           (ED_READLOOP's own generic default,
*                           still right for classic `r`)
*   $a / zebra / apple / . -> appends 2 lines after $ (now 2) ->
*                           "fig","pear","zebra","apple" (4)
*   %!sort | cat          -> REAL pipeline, OTHER direction:
*                           `sort` reorders the WHOLE 4-line
*                           range, `cat` passes it through
*                           unchanged as the LAST stage's own
*                           captured stdout -> "apple","fig",
*                           "pear","zebra" (proves a multi-stage
*                           pipe's LAST stage output is what
*                           lands back in the buffer, not an
*                           earlier stage's)
*   %p                    -> "apple","fig","pear","zebra"
*   1d                    -> delete "apple" -> "fig","pear",
*                           "zebra" (3 lines)
*   3d                    -> delete "zebra" -> "fig","pear" (2
*                           lines) -- back to the SAME content/
*                           shape the rest of this session
*                           (unchanged below) already assumes
*   w! EXR9/EX16SRC        -> XC1 2026-09-06 (second
*                            closing pass, PIGGYBACKED here --
*                            same $9800-ceiling reason as
*                            session 11B's own header): the
*                            buffer is STILL unnamed at this
*                            point (`r` never rebinds), so
*                            EX_FNAME_EQ can't match anything --
*                            `!` is needed since EX16SRC already
*                            EXISTS (EX5's own guard, unrelated
*                            to this fix). This first explicit
*                            `w!` establishes ED_CURFNAME =
*                            EX16SRC (overwriting it with
*                            "fig","pear", its own current
*                            content)
*   1s/f/F/               -> (no output) buffer -> "Fig","pear",
*                           dot=1
*   w                     -> bare `w` reuses the name just
*                            established above -- EX16SRC ->
*                            "Fig","pear". Pre-fix (EX4's
*                            unconditional removal), this bare
*                            `w` found no remembered name and
*                            was refused -- EX16SRC would stay
*                            at "fig","pear" (the first write's
*                            own content), not "Fig","pear"
*   r EXR9/EXFIXZ         -> FF3 2026-09-06 (review):
*                           classic `r FILE` with no address --
*                           POSIX ex (and maux's own `r !cmd`)
*                           inserts at the CURRENT line (dot=1),
*                           not `$` (POSIX ed's own default,
*                           unchanged -- check-ed covers it) --
*                           "ZERO" lands between "Fig" and
*                           "pear" -> "Fig","ZERO","pear"
*   %p                    -> "Fig","ZERO","pear"
*   $a / aa / aa / aa / . -> appends 3 more lines after $ (now
*                           3) -> "Fig","ZERO","pear","aa","aa",
*                           "aa" (6 lines)
*   4s/a/b/g2             -> FF5 2026-09-06 (review): `g`
*                           combined with a line COUNT is no
*                           longer refused in ex (`N` means a
*                           line count here, not ed's Nth-
*                           occurrence, so the two never
*                           actually conflicted) -- globalizes
*                           lines 4-5 ("aa"->"bb" each), line 6
*                           untouched
*   %p                    -> "Fig","ZERO","pear","bb","bb","aa"
*   4,6w !sort | cat      -> Phase E (2026-09-06): `w !` with a
*                           REAL 2-stage pipe -- lines 4-6
*                           ("bb","bb","aa") go to `sort`'s
*                           stdin, its stdout feeds `cat`, whose
*                           output lands on ex's own captured
*                           fd 1 (inherited, same stream as
*                           `%p`/`.=`) -- "aa","bb","bb"
*   q
* Exit status is 0: nothing in this session is refused any more
* (EX_PIPECHK is gone) -- every command above runs for real.
*---------------------------------------------------------------
* -- Grown for FF2/FF3/FF4/FF5 (2026-09-06, review): more
* -- `%p`/`.=` phases land in the SAME capture stream below, so
* -- the whole block moved out to $1140-$11FF (still clear of
* -- session 1's own $1200 floor) to make room.
R_LEN16        equ   $1140   ;byte count from EXCAP16 (all `%p`/
                             ;`.=` outputs, concatenated)
R_STAGE16      equ   $1148   ;up to 80 bytes -- ends $1197
R_LENSRC16     equ   $11A0   ;byte count from EX16SRC, RE-READ
                             ;after the script's own `w` (XC1)
R_STAGESRC16   equ   $11A8   ;up to 16 bytes -- ends $11B7
R_SPAWN_PID16  equ   $11C0
R_SPAWN_STA16  equ   $11C1
R_WAIT_PID16   equ   $11C2

SESS16START
* -- RUN_SESSION + DESC16/RBL16 (2026-09-12, table-driven) sit
* -- below, next to the fixture/path data they reference.
            lda   #<DESC16
            ldx   #>DESC16
            jsr   RUN_SESSION

            lda   #$AA
            sta   R_DONE
:donepark   bra   :donepark

* -- EX16SRC ("pear","fig") and EXSCR16 (traced in the header
* -- above): build_ex_image.py's FIXTURES.
PATH_EX16SRC dfb 22
             asc '/mnt/MAUX/EXR9/EX16SRC'
PATH_EXSCR16 dfb 22
             asc '/mnt/MAUX/EXR9/EXSCR16'
PATH_EXCAP16 dfb 22
             asc '/mnt/MAUX/EXR9/EXCAP16'

DESC16      da    PATH_EXCAP16,PATH_EXSCR16,0
            da    R_SPAWN_PID16,R_SPAWN_STA16,R_WAIT_PID16
            dfb   1,18,2
            da    RBL16
RBL16       da    PATH_EXCAP16,R_STAGE16
            dfb   80,0
            da    R_LEN16
            da    PATH_EX16SRC,R_STAGESRC16
            dfb   16,0
            da    R_LENSRC16

*-- PAR_PROC_LEN stays at extestb3.s's own tail (unchanged) --
*-- extestb3.s is still the LAST put file (`put` order:
*-- extestb.s, extestb2.s, extestb4.s, extestb5.s, extestb6.s,
*-- extestb7.s, extestb8.s, extestb9.s, extestb3.s), so it is
*-- still the textually LAST thing PARENT_PROC's continuous byte
*-- stream emits.
