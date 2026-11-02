*---------------------------------------------------------------
* extestb5.s -- continuation of extestb4.s's PARENT_PROC ("last
* regular expression" task, 2026-09-02). `put` in extest.s
* BETWEEN extestb4.s and extestb6.s: extestb4.s's own session-5b
* tail falls straight through into this file's SIXTH session
* driver (no jmp needed; `put` is textual inclusion, one
* continuous instruction stream). 2026-09-02 (widened g/v
* task): the epilogue (:donepark/PFAIL/:pfailpark) and
* PAR_PROC_LEN moved OUT of this file to extestb6.s -- this
* file's own trailing DATA (EXSRC6_TEXT etc, below) sits
* between this file's own CODE and extestb6.s's session 7
* driver in the `put` order, so a plain fallthrough would run
* into it as instructions; the session 6 driver below ends
* with an explicit `jmp SESS7START` (extestb6.s's own
* entry label) instead. extestb3.s's shared helpers/scratch/
* paths/content (reached only via `jsr`/`lda #<label`, never
* by fallthrough) stay LAST, `put` after extestb6.s.
*---------------------------------------------------------------
* -- Session 6 result addresses, own block $1C00-$1CFF (fifth
* -- session's own block was $1A00-$1BFF). --
R_LEN6      equ   $1C00      ;byte count from EXCAP6 (the whole
                             ;command-by-command stdout capture)
R_STAGE6    equ   $1C10      ;up to 96 bytes
R_LENOUT6   equ   $1C70      ;byte count from EXSRC6, RE-READ
                             ;after the script's own `wq`
R_STAGEOUT6 equ   $1C80      ;up to 96 bytes
R_SPAWN_PID6  equ $1CE0
R_SPAWN_STAT6 equ $1CE1
R_WAIT_PID6   equ $1CE2

*---------------------------------------------------------------
* SIXTH session -- "last regular expression" task (2026-09-02,
* learning:01M1FX8HT89CKR9CB8T8VKCW1S): `?re?` backward search
* repeats via a bare `??` exactly as forward `/re/` does via a
* bare `//` (edparse.s's ED_SEARCHFWD, SHARED with `ed`), and
* BOTH directions consult the SAME LASTPAT store -- the load-
* bearing "one last regular expression" property, proven here by
* a forward `/re/` search feeding a LATER backward `??`. See
* EXSCR6_TEXT below (this file, after the epilogue) for the full
* per-command trace.
*---------------------------------------------------------------
* -- EXSRC6/EXSCR6 are staged on ex.po at build time by
* -- scripts/build_ex_image.py (FIXTURES; extestb.s session 1's
* -- own note has the why) -- the content itself is documented
* -- below, where its bytes used to live. RUN_SESSION + DESC6/
* -- RBL6 (2026-09-12, table-driven) sit near the Session 6
* -- paths below, this file's own existing data/jmp-chain shape
* -- (matches extestb9.s's own per-session pattern).
            lda   #<DESC6
            ldx   #>DESC6
            jsr   RUN_SESSION

            jmp   SESS7START  ;2026-09-02: NOT `lda #$AA /
                                  ;sta R_DONE` here any more --
                                  ;session 6 is no longer the
                                  ;LAST session, and setting
                                  ;R_DONE early makes the host-
                                  ;side poller (check_ex.py)
                                  ;stop stepping and read stale
                                  ;results before session 7 gets
                                  ;to run. Only extestb6.s's own
                                  ;tail sets R_DONE now. The
                                  ;epilogue (:donepark/PFAIL/
                                  ;:pfailpark) moved to
                                  ;extestb6.s, whose session 7
                                  ;driver is put
                                  ;right after this file's own
                                  ;trailing DATA (the PATH_*
                                  ;labels below) -- an ordinary
                                  ;fallthrough would run INTO
                                  ;that data as instructions,
                                  ;so this jumps straight to
                                  ;extestb6.s's own entry label
                                  ;instead (a forward reference
                                  ;across put files,
                                  ;same as edparse.s's own
                                  ;MAINLOOP->ED_CMD_G)

*---------------------------------------------------------------
* EXSRC6 content (bytes: build_ex_image.py's FIXTURES) -- the
* file the SIXTH `ex` session loads via `r`, through the swap
* file same as every prior session. Six lines, "BANK" on 1 and
* 3, "OLD..." on 5 and 6 -- same shape as edtestb2.s's own
* EDSCR7_TEXT fixture (the `ed` side of this task), adapted for
* `?re?`/`??` instead of `/re/`/`//`.
*---------------------------------------------------------------

*---------------------------------------------------------------
* EXSCR6 content (bytes: build_ex_image.py's FIXTURES) -- r
* (load, dot ends at 6, the last loaded line). Per-command
* trace:
*   ??             -> "?"   no prior RE yet (dot stays 6 -- NOT
*                    a crash, NOT "empty pattern matches
*                    everything")
*   ?BANK?p        -> "BANK three"   backward search from dot=6
*                    wraps down to line 3; dot=3, LASTPAT="BANK"
*   ??             -> "BANK one"     bare repeat reuses LASTPAT=
*                    "BANK", finds the NEXT one going backward
*                    from dot=3; dot=1 (PROVES backward `??`
*                    repeat)
*   /yyyyy/        -> "yyyyy four"   FORWARD search from dot=1;
*                    dot=4, LASTPAT="yyyyy"
*   ??             -> "yyyyy four"   bare BACKWARD repeat reuses
*                    the pattern the FORWARD search just set --
*                    the full backward cycle from dot=4 wraps
*                    all the way around and matches "yyyyy" on
*                    line 4 itself, since that is the ONLY line
*                    containing it (PROVES forward and backward
*                    share ONE last-RE store)
*   5s/OLD/NEW/    -> (no output) line5 "OLDthing here" ->
*                    "NEWthing here"; dot=5, LASTPAT="OLD"
*   5p             -> "NEWthing here"
*   6s//XXX/       -> (no output) empty search field reuses
*                    LASTPAT="OLD"; line6 "OLDthing again" ->
*                    "XXXthing again"; dot=6 (PROVES `s//` reuse
*                    on the `ex` side too -- SHARED code with
*                    `ed`)
*   6p             -> "XXXthing again"
*   w! /mnt/MAUX/EXSRC6 -> writes the buffer back to EXSRC6. `r`
*   no
*                    longer rebinds the name (2026-09-06), so
*                    name the target explicitly; `!` forces the
*                    overwrite of the existing file.
*   q              -> quit
*---------------------------------------------------------------

*---------------------------------------------------------------
* Session 6 paths.
*---------------------------------------------------------------
PATH_EXSRC6  dfb 16
             asc '/mnt/MAUX/EXSRC6'
PATH_EXSCR6  dfb 16
             asc '/mnt/MAUX/EXSCR6'
PATH_EXCAP6  dfb 16
             asc '/mnt/MAUX/EXCAP6'

*-- Session 6's RUN_SESSION descriptor + readback list
*-- (2026-09-12: table-driven, extestb3.s's own RUN_SESSION
*-- header has the why).
DESC6       da    PATH_EXCAP6,PATH_EXSCR6,0
            da    R_SPAWN_PID6,R_SPAWN_STAT6,R_WAIT_PID6
            dfb   0,7,2
            da    RBL6
RBL6        da    PATH_EXCAP6,R_STAGE6
            dfb   96,0
            da    R_LEN6
            da    PATH_EXSRC6,R_STAGEOUT6
            dfb   96,0
            da    R_LENOUT6

*-- PAR_PROC_LEN stays at extestb3.s's own tail (unchanged) --
*-- extestb3.s is still the LAST put file (`put` order: extestb.
*-- s, extestb2.s, extestb4.s, extestb5.s, extestb3.s), so it is
*-- still the textually LAST thing PARENT_PROC's continuous byte
*-- stream emits.
