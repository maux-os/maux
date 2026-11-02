*---------------------------------------------------------------
* extestb4.s -- continuation of extestb.s/extestb2.s (M3,
* filename-on-launch task, 2026-09-02). Split out purely for
* as's OWN source window (docs/S9-PLAN.md sec 5's "3b" gate,
* scripts/check_dialect.py) -- extestb2.s carrying this session
* on top of sessions 3/4 pushed extest.s's own "resident +
* largest put" past as's 16128-byte ceiling (merlin32's larger
* 41215-byte budget was unaffected). `put` in extest.s BETWEEN
* extestb2.s and extestb5.s -- PARENT_PROC's own code is one
* continuous fallthrough stream, and extestb2.s's session 4
* driver falls straight into this file's session 5 driver, which
* now falls straight into extestb5.s's session 6 driver ("last
* regular expression" task, 2026-09-02) and ITS OWN epilogue
* (`:donepark`/PFAIL, moved there -- see that file's header);
* extestb3.s's helpers/scratch/paths/content, reached only via
* `jsr`, never by fallthrough, must stay AFTER extestb5.s's own
* infinite park loop, not before it.
*---------------------------------------------------------------
* FIFTH session -- filename-on-launch task, 2026-09-02: `ex
* FILE` loads FILE through the swap file at STARTUP instead of a
* bare launch + `r`. 5a is the positive case (a real fixture,
* loaded via argv, `,p`/bare `w` prove the load AND the
* remembered filename, exactly the SAME shape as edtestb.s's own
* Session 6a for `ed`); 5b is the negative case (a path that
* does NOT exist -- must stay `?`, no crash, filename not
* remembered). EXFILE5/EXSCR5 are staged on ex.po at build time
* by scripts/build_ex_image.py (FIXTURES; extestb.s session 1's
* own note has the why). EXNOSUCH5 (5b) is staged by NOTHING.
* RUN_SESSION + DESC5/RBL5 (5a) and DESC5N/RBL5N (5b) --
* extestb3.s, table-driven since 2026-09-12; ARGV_ARR5/
* ARGV_ARR5N are static data there too now (were runtime-
* filled here).
*---------------------------------------------------------------
            lda   #<DESC5
            ldx   #>DESC5
            jsr   RUN_SESSION

            lda   #<DESC5N
            ldx   #>DESC5N
            jsr   RUN_SESSION

*-- PARENT_PROC's own epilogue (:donepark/PFAIL/:pfailpark) now
*-- lives at the tail of extestb5.s (SIXTH session, "last
*-- regular expression" task, 2026-09-02) -- this file's own
*-- tail falls straight through into it, same split precedent as
*-- extestb2.s->extestb4.s above. `put` in extest.s right after
*-- this file.
