*---------------------------------------------------------------
* shtabc2.s -- the TAB lister, LOW image (TAB-A3-NOTES sec 3).
* Split from shtabc.s because the $E000 segment's hard wall is
* ALI_BASE and the low image still had tripwire room: the window
* cost is the same either way. Called from TC_TAB (shtabc.s).
*---------------------------------------------------------------
*---------------------------------------------------------------
* TC_LIST -- TAB TAB: the stored candidates sorted, in columns
* sized by the console width (row by row), a `/` after a
* directory, a final `...` row when there were more than were
* stored; then the prompt and the line again, the cursor where
* it was (ED_REDRAW is ^L's tail).
*---------------------------------------------------------------
TC_LIST     lda   TC_N
            sta   GLOBN
            jsr   GLOB_SORT
            lda   ED_LEN
            jsr   ED_MOVETO          ;cursor to the line end
            lda   #$8D               ;and a fresh row
            jsr   ED_OUTB
            stz   TC_MAXW
            stz   TC_I
:w          ldx   TC_I
            cpx   TC_N
            bcs   :wd
            jsr   TC_REC
            jsr   TC_LEN
            cmp   TC_MAXW
            bcc   :wn
            sta   TC_MAXW
:wn         inc   TC_I
            bra   :w
:wd         lda   TC_MAXW
            clc
            adc   #2
            sta   TC_CW
            ldx   #0
            lda   ED_W
:dv         cmp   TC_CW
            bcc   :dd
            sbc   TC_CW
            inx
            bra   :dv
:dd         txa
            bne   :cs
            inx
:cs         stx   TC_COLS
            stz   TC_I
            stz   TC_COL
:pr         ldx   TC_I
            cpx   TC_N
            bcs   :prd
            jsr   TC_REC
            stz   TC_J
:pn         ldx   TC_J
            lda   TC_CAND,x
            beq   :pnd
            jsr   ED_OUTB
            inc   TC_J
            bra   :pn
:pnd        lda   TC_DIRF
            beq   :p1
            lda   #ALC_AF
            jsr   ED_OUTB
:p1         inc   TC_I
            inc   TC_COL
            lda   TC_COL
            cmp   TC_COLS
            beq   :eol
            lda   TC_I
            cmp   TC_N
            beq   :eol
            jsr   TC_LEN             ;pad to the column width
            sta   TC_J
:pad        lda   TC_J
            cmp   TC_CW
            bcs   :pr
            lda   #ALC_A0
            jsr   ED_OUTB
            inc   TC_J
            bra   :pad
:eol        lda   #$8D
            jsr   ED_OUTB
            stz   TC_COL
            bra   :pr
:prd        lda   TC_COL             ;close a partial row
            beq   :more
            lda   #$8D
            jsr   ED_OUTB
:more       lda   TC_CNT             ;more than were kept
            cmp   TC_N
            beq   :out
            ldx   #3
:dots       phx
            lda   #TCC_DOT
            jsr   ED_OUTB
            plx
            dex
            bne   :dots
            lda   #$8D
            jsr   ED_OUTB
:out        jmp   ED_REDRAW

* TC_REC -- X = a position in the sorted order. TC_CAND := that
* record's name, TC_DIRF := 1 iff it is a directory.
TC_REC      lda   GLOBIDX,x
            sta   GSLOT
            tax
            lda   GLOBTYP,x
            tax
            jsr   TC_ISDIR
            lda   #0
            rol   a
            sta   TC_DIRF
            jsr   GLOB_SLOTX
            ldy   #15
:l          lda   (PTR0),y
            sta   TC_CAND,y
            dey
            bpl   :l
            lda   #0
            sta   TC_CAND+15
            rts

* TC_LEN -- A := strlen(TC_CAND) + TC_DIRF.
TC_LEN      ldy   #0
:l          lda   TC_CAND,y
            beq   :d
            iny
            bra   :l
:d          tya
            clc
            adc   TC_DIRF
            rts
