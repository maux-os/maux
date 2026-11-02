*---------------------------------------------------------------
* virep.s -- vi's delete/change REDISPLAY helpers (docs/VI-
* DESIGN.md sec 2.2, 2026-09-11). `put` by vi.s ONLY, after
* viop.s. Split out of viop.s so that file's source buffer stays
* under the real-Merlin-8 budget (check-dialect step 3); these
* routines are pure redisplay -- they size a delete by its
* ACTUAL line-count delta (VI_DNL captured before the delete)
* and hand it to viscreen.s's VI_RPDEL / VI_RPT_LN / VI_INS_
* SHOWN, rather than the old full repaint. CLOBBERS as noted per
* routine. Depends on: VI_RPDEL/VI_RPT_LN/VI_INS_SHOWN
* (viscreen.s/viinsert.s), ED_ADDR1/ED_CURLINE/ED_NLINES.
*---------------------------------------------------------------

*---------------------------------------------------------------
* VI_RP_LWD -- redisplay after a LINEWISE delete of ED_ADDR1..
* ED_ADDR2 (both still the deleted range: ED_DLT_RANGE leaves
* them). IN: X = VI_RPDEL's "cursor line changed too" flag (0
* for dd/d-motion; J passes 1 -- there ADDR1 already names the
* first folded line and the cursor sits above it).
* VI_RP_CWD -- after a CHARWISE delete/change (or cc/S) spanning
* ED_ADDR1..ED_ADDR2: the cursor line ADDR1 changed, the lines
* ADDR1+1..ADDR2 are gone (none when ADDR1 == ADDR2).
* Both: CLOBBERS A, X, Y + VI_RPDEL's. (2026-09-11)
*---------------------------------------------------------------
VI_RP_LWD   lda   VI_DA1               ;first deleted line (the
            sta   ED_TMP16B           ;cursor moved off it)
            lda   VI_DA1+1
            sta   ED_TMP16B+1
            jsr   VI_DELCNT            ;lines removed
            jmp   VI_RPDEL
VI_RP_CWD   lda   ED_CURLINE          ;first line below the
            clc                         ;changed cursor line
            adc   #1
            sta   ED_TMP16B
            lda   ED_CURLINE+1
            adc   #0
            sta   ED_TMP16B+1
            jsr   VI_DELCNT
            ldx   #1                    ;the cursor line changed
            jmp   VI_RPDEL

* VI_SAVESPAN -- before the delete, stash ED_ADDR1 (a linewise
* delete's first line) and ED_NLINES (to measure the delete by
* its ACTUAL line delta, not the span: a no-join `dw` leaves
* ADDR2 on a line it does not remove). Called after the span is
* computed / after VI_OP_DDSPAN / at the J landing. CLOBBERS: A.
VI_SAVESPAN lda   ED_ADDR1
            sta   VI_DA1
            lda   ED_ADDR1+1
            sta   VI_DA1+1
VI_SAVENL   lda   ED_NLINES
            sta   VI_DNL
            lda   ED_NLINES+1
            sta   VI_DNL+1
            rts

* VI_DELCNT -- A = VI_DNL - ED_NLINES, the lines the delete
* removed (0 when it only changed text in place), pinned at 254.
* Preserves X.
VI_DELCNT   sec
            lda   VI_DNL
            sbc   ED_NLINES
            tay
            lda   VI_DNL+1
            sbc   ED_NLINES+1
            beq   :dcok
            ldy   #254
:dcok       tya
            rts

*---------------------------------------------------------------
* VI_OP_CWCHG -- the change operators' entry into insert (c +
* motion, C, and cc/S via VI_OP_LWCT): show the delete the way
* VI_RP_CWD does, then run the insert session on the shown
* screen (viinsert.s VI_INS_SHOWN; VI_INS_STRUCT = 2 so ESC
* redraws the one line). Never returns here.
*---------------------------------------------------------------
VI_OP_CWCHG jsr   VI_RP_CWD
            lda   #2
            sta   VI_INS_STRUCT
            jmp   VI_INS_SHOWN
