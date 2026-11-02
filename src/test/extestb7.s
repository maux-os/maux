*---------------------------------------------------------------
* extestb7.s -- continuation of extestb6.s's PARENT_PROC (`w`
* truncation bug fix, 2026-09-02, edtestb2.s's own Session 9 --
* same proof, ex's own file). `put` in extest.s BETWEEN
* extestb6.s and extestb8.s. Entry is SESS8START (below),
* reached by an explicit `jmp` from extestb6.s's own session 7
* tail -- extestb6.s's trailing DATA sits between the two files
* in `put` order, so a plain fallthrough would land in the
* middle of it. This file's own EIGHTH session driver ends with
* a `jmp SESS9START` into extestb8.s (the `!` family, 2026-09-
* 06) -- the epilogue (:donepark/PFAIL/:pfailpark) moved THERE,
* same reason it moved here from extestb6.s. extestb3.s's shared
* helpers/scratch/paths/content still stay LAST, `put` after
* extestb8.s.
*---------------------------------------------------------------
* -- Session 8 result addresses, own block $1E00-$1EFF. Proves
* `w` TRUNCATES through ex's swap-file-backed write path (the
* SAME ED_DOWRITE code ed's own edtestb2.s Session 9 exercises
* directly): a long buffer is written to EXFILE8, then a short
* buffer overwrites it via a bare `w` -- if SET_EOF is missing,
* ProDOS's OPEN leaves the old EOF in place and the short write
* leaves a stale tail past the new content. --
R_LEN8      equ   $1E00      ;byte count from EXFILE8 (post-w)
R_STAGE8    equ   $1E10      ;up to 96 bytes -- ends $1E6F
R_LEN8O     equ   $1E70      ;byte count from EXCAP8 (must stay
                             ;empty -- no `,p` in EXSCR8)
R_STAGE8O   equ   $1E78      ;scratch target, 0 bytes expected
R_SPAWN_PID8  equ $1E80
R_SPAWN_STAT8 equ $1E81
R_WAIT_PID8   equ $1E82

*---------------------------------------------------------------
* EIGHTH session -- `w` truncation (bug fix, 2026-09-02): a bare
* `w` onto an EXISTING file must not leave a stale tail when the
* new buffer is SHORTER than what the file already held, through
* ex's swap-file-backed buffer just as much as through ed's RAM
* one -- ED_DOWRITE is the exact same code either way (shared
* src/bin/edfil2.s). One script, one session: build a 6-line
* ("long") buffer with `a` (no `r` -- exbuf supports insert into
* an empty buffer same as edbuf), `w` it to EXFILE8, delete the
* whole buffer, insert a 2-line ("short") one, and `w` again
* with NO filename token (reuses the remembered EXFILE8). See
* EXSCR8_TEXT below for the full trace.
*---------------------------------------------------------------
SESS8START
* -- EXSCR8 is staged on ex.po at build time by scripts/
* -- build_ex_image.py (FIXTURES; extestb.s session 1's own note
* -- has the why) -- content documented below. EXFILE8 is
* -- created by ex's own first `w`, so it is staged by nothing.
* -- RUN_SESSION + DESC8/RBL8 (2026-09-12, table-driven; sit
* -- near the Session 8 paths below). RBL8's own list order --
* -- capture (expected empty, 8-byte buffer) THEN EXFILE8
* -- (96-byte buffer) -- is just list order; RUN_SESSION needs
* -- no special-casing for it.
            lda   #<DESC8
            ldx   #>DESC8
            jsr   RUN_SESSION

            jmp   SESS9START

*---------------------------------------------------------------
* EXSCR8 content (bytes: build_ex_image.py's FIXTURES) -- `w`
* truncation proof (bug fix, 2026-09-02). Per-command trace:
*   a / 6 long lines / .  -> builds a 6-line buffer, .=6 (no `r`
*                           -- exbuf supports fresh insert same
*                           as edbuf)
*   w /mnt/MAUX/EXFILE8 -> (no output) creates EXFILE8 fresh,
*                           writes all 6 long lines through the
*                           swap file
*   1,6d                  -> (no output) deletes the whole
*                           buffer, .=0
*   a / U1 / U2 / .        -> inserts 2 short lines after 0, .=2
*   w! /mnt/MAUX/EXFILE8      -> (no output) REWORKED 2026-09-06
*                           (EX4): `w PATH` no longer rebinds
*                           the remembered filename, so this
*                           session never had a remembered name
*                           at all (no `r`/`e`/launch load) --
*                           name EXFILE8 explicitly, and force
*                           (`!`, EX5's own `w!` guard) since
*                           it's an EXISTING file the guard
*                           doesn't know is "ours". Writes only
*                           6 bytes ("U1"+CR+"U2"+CR). Pre-fix
*                           (2026-09-02):
*                           ProDOS OPEN does not truncate, so
*                           EXFILE8's EOF stayed at its original
*                           length and the file kept stale bytes
*                           past the new content. Post-fix:
*                           SET_EOF(0) right after OPEN (in
*                           ED_DOWRITE, shared with `ed`) leaves
*                           EXFILE8 at exactly 6 bytes.
*   q
*---------------------------------------------------------------

*---------------------------------------------------------------
* Session 8 paths.
*---------------------------------------------------------------
PATH_EXSCR8  dfb 16
             asc '/mnt/MAUX/EXSCR8'
PATH_EXCAP8  dfb 16
             asc '/mnt/MAUX/EXCAP8'
PATH_EXFILE8 dfb 17
             asc '/mnt/MAUX/EXFILE8'

DESC8       da    PATH_EXCAP8,PATH_EXSCR8,0
            da    R_SPAWN_PID8,R_SPAWN_STAT8,R_WAIT_PID8
            dfb   0,9,2
            da    RBL8
RBL8        da    PATH_EXCAP8,R_STAGE8O
            dfb   8,0
            da    R_LEN8O
            da    PATH_EXFILE8,R_STAGE8
            dfb   96,0
            da    R_LEN8

*-- PAR_PROC_LEN stays at extestb3.s's own tail (unchanged) --
*-- extestb3.s is still the LAST put file (`put` order:
*-- extestb.s, extestb2.s, extestb4.s, extestb5.s, extestb6.s,
*-- extestb7.s, extestb3.s), so it is still the textually LAST
*-- thing PARENT_PROC's continuous byte stream emits.
