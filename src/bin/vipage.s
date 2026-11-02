*---------------------------------------------------------------
* vipage.s -- the window-sync tail of vimotion.s: VI_TOPSYNC,
* VI_TOPCAP, VI_PAGE and friends. Split out 2026-10-06 (a seam,
* byte-neutral) so vimotion.s and `vi`'s manifest stay under
* real
* Merlin's source buffer (check-dialect rule 3) once the
* register
* arena (virg.s) landed. `put` by vi.s ONLY, after vimotion.s.
*---------------------------------------------------------------
*---------------------------------------------------------------
* VI_TOPSYNC -- adjust VI_TOP so ED_CURLINE is on screen, NO
* painting. Carry SET = it was already visible (VI_TOP
* unchanged); carry CLEAR = VI_TOP moved, the caller must
* repaint. A downward jump BOTTOM-aligns (the target lands on
* the last text row, the lines before it visible above) and an
* upward jump TOP-aligns -- real vi, and what makes `G` show a
* full last page instead of the last line alone (2026-09-04; the
* old top-align-always left `G` sitting one line at row 0).
* textrows = VI_ROWS-1 (the status row is not text). CLOBBERS:
* A, X, VI_TMP, VI_TMP2.
*---------------------------------------------------------------
VI_TOPSYNC  sec
            lda   ED_CURLINE
            sbc   VI_TOP
            sta   VI_TMP
            lda   ED_CURLINE+1
            sbc   VI_TOP+1
            sta   VI_TMP+1
            bmi   :above             ;curline < VI_TOP
            lda   VI_TMP+1
            bne   :below             ;far below (hi byte set)
            lda   VI_LNCNT           ;lines actually PAINTED --
            cmp   VI_TMP             ;with wrap fewer than
            beq   :below             ;textrows may fit
            bcc   :below             ;(viscreen.s, 2026-09-05);
            sec                      ;0 <= delta < painted: on
            rts                      ;screen, VI_TOP unchanged
:below      lda   VI_ROWS            ;VI_TOP=curline-(rows-2):
            sec
            sbc   #2                 ;target on the LAST text
            sta   VI_TMP2            ;row (rows-1 rows, 0-based)
            sec
            lda   ED_CURLINE
            sbc   VI_TMP2
            sta   VI_TOP
            lda   ED_CURLINE+1
            sbc   #0
            sta   VI_TOP+1
            jsr   VI_TOPFLOOR
            clc
            rts
:above      lda   ED_CURLINE
            sta   VI_TOP
            lda   ED_CURLINE+1
            sta   VI_TOP+1
            clc
            rts

* VI_TOPFLOOR -- clamp VI_TOP up to a minimum of 1 (a computed
* top of 0 or negative means the buffer is shorter than a page).
VI_TOPFLOOR lda   VI_TOP+1
            bmi   :one
            bne   :ok
            lda   VI_TOP
            bne   :ok
:one        lda   #1
            sta   VI_TOP
            stz   VI_TOP+1
:ok         rts

* VI_TOPCAP -- clamp VI_TOP DOWN to the highest top that still
* fills the screen: maxtop = NLINES - textrows + 1 (min 1). So a
* forward page at EOF shows a FULL last page, not the last line
* alone at row 0. CLOBBERS: A, VI_TMP2.
VI_TOPCAP   sec                      ;maxtop = NLINES-(rows-2)
            lda   ED_NLINES
            sbc   VI_ROWS
            sta   VI_TMP2
            lda   ED_NLINES+1
            sbc   #0
            sta   VI_TMP2+1
            clc                      ;+2 (rows-1 textrows, +1)
            lda   VI_TMP2
            adc   #2
            sta   VI_TMP2
            lda   VI_TMP2+1
            adc   #0
            sta   VI_TMP2+1
            bmi   :flr1              ;NLINES < a page: top = 1
            lda   VI_TMP2+1
            bne   :cmp               ;maxtop >= 256, VI_TOP < it
            lda   VI_TMP2
            bne   :cmp
:flr1       lda   #1                 ;maxtop <= 0 -> 1
            sta   VI_TMP2
            stz   VI_TMP2+1
:cmp        lda   VI_TOP+1           ;VI_TOP > maxtop ?
            cmp   VI_TMP2+1
            bcc   :ok
            bne   :setmax
            lda   VI_TOP
            cmp   VI_TMP2
            bcc   :ok
            beq   :ok
:setmax     lda   VI_TMP2
            sta   VI_TOP
            lda   VI_TMP2+1
            sta   VI_TOP+1
:ok         jmp   VI_TOPFLOOR

*---------------------------------------------------------------
* VI_PAGE_F/B/D/U -- ^F/^B (full page, 2-line overlap) and
* ^D/^U (half page), 2026-09-04. Each shifts VI_TOP by the
* signed delta in A, clamps VI_TOP to [1, NLINES], lands the
* cursor at the new top, and repaints. Simple and predictable
* for v1; real vi keeps the cursor's screen row on ^D/^U, which
* a later pass can add. CLOBBERS: A, X, Y, VI_TMP, VI_TMP2, PTR0
* (+ VI_REPAINT's).
*---------------------------------------------------------------
VI_PAGE_F   jsr   VI_PGSTEP          ;textrows-2, forward
            bra   VI_PAGE
VI_PAGE_B   jsr   VI_PGSTEP
            eor   #$FF               ;negate (two's complement)
            clc
            adc   #1
            bra   VI_PAGE
VI_PAGE_D   jsr   VI_HALFSTEP
            bra   VI_PAGE
VI_PAGE_U   jsr   VI_HALFSTEP
            eor   #$FF
            clc
            adc   #1
VI_PAGE     sta   VI_TMP             ;signed delta
            bmi   :up
            clc                      ;down: VI_TOP += delta
            lda   VI_TOP
            adc   VI_TMP
            sta   VI_TOP
            lda   VI_TOP+1
            adc   #0
            sta   VI_TOP+1
            jsr   VI_TOPCAP          ;cap at the last full page
            bra   :setc
:up         clc                      ;up: VI_TOP += (neg) delta
            lda   VI_TOP
            adc   VI_TMP
            sta   VI_TOP
            lda   VI_TOP+1
            adc   #$FF               ;sign-extend the byte
            sta   VI_TOP+1
            jsr   VI_TOPFLOOR
:setc       lda   VI_TOP             ;cursor to the new top
            sta   ED_CURLINE
            lda   VI_TOP+1
            sta   ED_CURLINE+1
            stz   VI_CURCOL
            jsr   VI_CLAMP_COL
            jmp   VI_REPAINT

* VI_PGSTEP -- A = textrows-2 (page, 2-row overlap), min 1.
VI_PGSTEP   lda   VI_ROWS
            sec
            sbc   #3                 ;textrows-2 (rows-1-2)
            bcs   :ok
            lda   #1
:ok         cmp   #1
            bcs   :done
            lda   #1
:done       rts

* VI_HALFSTEP -- A = textrows/2, min 1.
VI_HALFSTEP lda   VI_ROWS
            sec
            sbc   #1                 ;textrows
            lsr
            bne   :ok
            lda   #1
:ok         rts

*---------------------------------------------------------------
* VI_GOMOTION -- command-mode wrapper (vicmd.s's VI_MOTKEY calls
* this): run VI_DOMOTION for the key in A, then actually MOVE
* the cursor there -- the "command mode moves there" half of the
* shared-computation directive (VI_DOMOTION itself never touches
* ED_CURLINE/VI_CURCOL). On an invalid motion (carry set), the
* cursor is left untouched (v1's existing silent-ignore
* convention). CLOBBERS: A, X, Y, PTR0, ED_TMP16, ED_TMP16B,
* VI_TMP, VI_TMP2, VI_LLEN, VI_BIGF (+ VI_CLAMP_COL/VI_RESYNC's
* own clobbers on success).
*---------------------------------------------------------------
VI_GOMOTION jsr   VI_DOMOTION
            bcs   :bell
            lda   VI_MO_L1
            sta   ED_CURLINE
            lda   VI_MO_L1+1
            sta   ED_CURLINE+1
            lda   VI_MO_C1
            sta   VI_CURCOL
            jsr   VI_CLAMP_COL
            jmp   VI_RESYNC
:bell       rts
