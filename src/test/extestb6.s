*---------------------------------------------------------------
* extestb6.s -- continuation of extestb5.s's PARENT_PROC
* (widened g/v task, 2026-09-02,
* learning:01M1FX8HT89CKR9CB8T8VKCW1S).
* `put` in extest.s BETWEEN extestb5.s and extestb3.s. Entry is
* SESS7START (below), reached by an explicit `jmp` from
* extestb5.s's own session 6 tail -- extestb5.s's trailing DATA
* sits between the two files in `put` order, so a plain
* fallthrough would land in the middle of it. This file's own
* SEVENTH session driver ends with a `jmp SESS8START` into
* extestb7.s (2026-09-02, `w` truncation bug fix) -- the
* epilogue (:donepark/PFAIL/:pfailpark) has moved AGAIN, to
* extestb7.s, same reason as every prior hop: session 7 is no
* longer the last one. extestb3.s's shared helpers/scratch/
* paths/content still stay LAST, `put` after extestb7.s.
*---------------------------------------------------------------
* -- Session 7 result addresses, own block $1D00-$1DFF. --
R_LEN7      equ   $1D00      ;byte count from EXCAP7
R_STAGE7    equ   $1D10      ;up to 96 bytes
R_LENOUT7   equ   $1D70      ;byte count from EXSRC7, RE-READ
                             ;after the script's own `wq`
R_STAGEOUT7 equ   $1D80      ;up to 96 bytes
R_SPAWN_PID7  equ $1DE0
R_SPAWN_STAT7 equ $1DE1
R_WAIT_PID7   equ $1DE2

*---------------------------------------------------------------
* SEVENTH session -- widened g/v task (2026-09-02): `g/BANK/
* s/BANK/GONE/` runs the substitute command -- not p or d -- on
* every matching line, proving the general dispatch path works
* against exbuf's swap-file-backed {offset,len} descriptors, not
* just edbuf's RAM pointers (`ed`'s own edtestb3.s carries the
* p/d/s/refusal proof in full; this ex session's own job is just
* to prove the SAME general path also survives ex's swap-file
* fork). See EXSCR7_TEXT below (this file, after the epilogue)
* for the full per-command trace.
*---------------------------------------------------------------
SESS7START
* -- EXSRC7/EXSCR7 are staged on ex.po at build time by
* -- scripts/build_ex_image.py (FIXTURES; extestb.s session 1's
* -- own note has the why) -- content documented below.
* -- RUN_SESSION + DESC7/RBL7 (2026-09-12, table-driven; sit
* -- near the Session 7 paths below).
            lda   #<DESC7
            ldx   #>DESC7
            jsr   RUN_SESSION

            jmp   SESS8START
                                 ;2026-09-02: NOT `lda #$AA /
                                 ;sta R_DONE` here any more --
                                 ;session 7 is no longer the
                                 ;LAST session; only extestb7.
                                 ;s's own tail sets R_DONE now.
                                 ;The epilogue moved to
                                 ;extestb7.s, whose truncation-
                                 ;proof session driver is put
                                 ;right after this file's own
                                 ;trailing DATA (the PATH_*
                                 ;labels below) -- an ordinary
                                 ;fallthrough would run INTO
                                 ;that data as instructions, so
                                 ;this jumps straight to
                                 ;extestb7.s's own entry label.

*---------------------------------------------------------------
* EXSRC7 content (bytes: build_ex_image.py's FIXTURES) -- the
* file the SEVENTH `ex` session loads via `r`, through the swap
* file same as every prior session. Four lines, "BANK" on 1 and
* 3.
*---------------------------------------------------------------

*---------------------------------------------------------------
* EXSCR7 (bytes: build_ex_image.py's FIXTURES) -- the widened-
* g/v proof: `s`, not p or d, on every matching line. Per-
* command trace:
*   r /mnt/MAUX/EXSRC7    -> (no output) loads the 4 lines above
*   g/BANK/s/BANK/GONE/ -> (no output) the general dispatch
*                         path runs `s/BANK/GONE/` against EACH
*                         marked line (1 and 3), through exbuf's
*                         own swap-file descriptors -- line1
*                         "BANK one" -> "GONE one", line3 "BANK
*                         three" -> "GONE three"; lines 2,4
*                         untouched
*   ,p                  -> "GONE one","plain two","GONE
*                         three","plain four"
*   w! /mnt/MAUX/EXSRC7 -> (no output) writes the buffer back to
*                         EXSRC7. `r` no longer rebinds the name
*                         (2026-09-06), so name it explicitly;
*                         `!` forces the overwrite.
*   q                   -> quit
*---------------------------------------------------------------

*---------------------------------------------------------------
* Session 7 paths.
*---------------------------------------------------------------
PATH_EXSRC7  dfb 16
             asc '/mnt/MAUX/EXSRC7'
PATH_EXSCR7  dfb 16
             asc '/mnt/MAUX/EXSCR7'
PATH_EXCAP7  dfb 16
             asc '/mnt/MAUX/EXCAP7'

DESC7       da    PATH_EXCAP7,PATH_EXSCR7,0
            da    R_SPAWN_PID7,R_SPAWN_STAT7,R_WAIT_PID7
            dfb   0,8,2
            da    RBL7
RBL7        da    PATH_EXCAP7,R_STAGE7
            dfb   96,0
            da    R_LEN7
            da    PATH_EXSRC7,R_STAGEOUT7
            dfb   96,0
            da    R_LENOUT7

*-- PAR_PROC_LEN stays at extestb3.s's own tail (unchanged) --
*-- extestb3.s is still the LAST put file (`put` order: extestb.
*-- s, extestb2.s, extestb4.s, extestb5.s, extestb6.s, extestb7.
*-- s, extestb3.s), so it is still the textually LAST thing
*-- PARENT_PROC's continuous byte stream emits.
