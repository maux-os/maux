*---------------------------------------------------------------
* extestb2.s -- continuation of extestb.s's PARENT_PROC (M2,
* 2026-09-02). Split purely for the `as` self-host source
* window (docs/S9-PLAN.md sec 5, scripts/check_dialect.py's
* "3b" gate -- the SAME "resident + largest put" ceiling that
* binds `as`, not merlin32's own 41215-byte budget): extestb.s
* alone grew past 16128 bytes stripped once sessions 3 and 4
* landed, so this file carries the THIRD and FOURTH sessions'
* driver code, extestb4.s the FIFTH (2026-09-02, filename-on-
* launch) plus PARENT_PROC's own epilogue, and extestb3.s the
* shared call helpers, scratch, and all staged file content.
* This file's own tail falls straight through into extestb4.s
* -- no epilogue here anymore. One assembly stream throughout --
* PARENT_PROC's own code and every label it references (PATH_*,
* *_TEXT, *_TXTLEN, OPEN_BY_PATH and friends) are unaffected by
* which put file they live in.
*---------------------------------------------------------------
* THIRD session -- M2 items 2 (marks: set/'x'/shift-on-insert/
* shift-on-delete/invalidate-on-delete), 4 (u undo, single-
* level, "its own inverse"), 5 (#-print, n reserved). See
* check_ex.py's own header comment for the full command-by-
* command trace this script's expected bytes were derived
* against. -- EXSRC3/EXSCR3 staged by build_ex_image.py
* (extestb.s session 1's own note has the why). RUN_SESSION +
* DESC3/RBL3 (extestb3.s, table-driven since 2026-09-12).
*---------------------------------------------------------------
            lda   #<DESC3
            ldx   #>DESC3
            jsr   RUN_SESSION

*---------------------------------------------------------------
* FOURTH session -- M2 items 1 (wq), 3 (?re? backward search,
* incl. a wrap-through-everything no-match), 6 (e/e! incl. the
* dirty-buffer guard). See check_ex.py's own header comment for
* the full command-by-command trace. EXSRC4/EXSRC4B/EXSCR4
* staged by build_ex_image.py. RUN_SESSION + DESC4/RBL4
* (extestb3.s) -- the second readback re-opens PATH_EXSRC4B (the
* file `e!`/`wq` end up naming), not a plain EXOUT path.
*---------------------------------------------------------------
            lda   #<DESC4
            ldx   #>DESC4
            jsr   RUN_SESSION

