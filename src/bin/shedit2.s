*---------------------------------------------------------------
* shedit2.s -- the line editor's HISTORY half, `put` by
* src/bin/sh.s right after shedit.s. Split from it at a global
* label (SH-SEQ C): check-dialect's source-buffer budget is the
* manifest plus the largest put, and shedit.s was it. This is
* the tail of shedit.s, in order; the image bytes are where
* they were.
*---------------------------------------------------------------
*---------------------------------------------------------------
* HISTORY. Per shell, in the dead copy (sh.s, ED_HRING): a
* stash for the line in progress (arena), then a ring of
* entries [len][text],
* NEWEST FIRST from the ring's base (a walk hops by each
* length; a new entry goes in at the base, the rest slide up,
* the oldest are dropped to make room). Eight entries, fewer
* if they do not fit; a line is never truncated. Initialised
* by ED_INIT. Like the kernel's: a non-empty line is added on
* Return, no dedup; a
* walk stashes the line once, stepping past the newest restores
* it, and edits to a recalled line die with the next step.
*---------------------------------------------------------------

*-- PTR1 := entry A (0 = newest): hop A entries from the top.
ED_HFIND    tax
            lda   #<ED_HRING
            sta   PTR1
            lda   #>ED_HRING
            sta   PTR1+1
:lp         dex
            bmi   :done
            sec
            lda   (PTR1)
            adc   PTR1               ;PTR1 += len + 1
            sta   PTR1
            bcc   :lp
            inc   PTR1+1
            bra   :lp
:done       rts

*-- Replace the line with the entry at PTR1.
ED_SETLN    ldy   #0
            lda   (PTR1),y
            sta   ED_LEN
            beq   :pn
:cp         iny
            lda   (PTR1),y
            sta   LINEBUF-1,y
            cpy   ED_LEN
            bne   :cp
:pn         lda   ED_LEN
            jsr   ED_PAINT
            lda   ED_LEN
            sta   ED_POS
            rts

ED_HLOAD    pha
            jsr   ED_WIPE
            pla
            jsr   ED_HFIND
            jmp   ED_SETLN

ED_HPRV     lda   ED_HN
            beq   :nop
            lda   ED_HCUR
            cmp   #$FF
            bne   :deeper
            ldx   #0                 ;stash the line in progress
:st         cpx   ED_LEN
            beq   :sd
            lda   LINEBUF,x
            sta   ED_STASH+1,x
            inx
            bra   :st
:sd         lda   ED_LEN
            sta   ED_STASH
            lda   #0
            bra   :load
:deeper     inc   a
            cmp   ED_HN
            bcs   :nop
:load       sta   ED_HCUR
            jsr   ED_HLOAD
:nop        clc
            rts

ED_HNXT     lda   ED_HCUR
            cmp   #$FF
            beq   :nop
            cmp   #0
            beq   :un
            dec   a
            sta   ED_HCUR
            jsr   ED_HLOAD
            clc
            rts
:un         lda   #$FF
            sta   ED_HCUR
            jsr   ED_WIPE
            lda   #<ED_STASH
            sta   PTR1
            lda   #>ED_STASH
            sta   PTR1+1
            jsr   ED_SETLN
:nop        clc
            rts

*-- Return: record the line. Newest first, so a new entry slides
*-- the rest up; the oldest entries are dropped until it fits
*-- (eight entries, ED_RINGSZ bytes).
ED_HADD     stz   ED_HCUR
            lda   ED_LEN
            bne   :go
            rts
:go         inc   a
            sta   ED_T3              ;this entry's size
:chk        lda   ED_HN
            cmp   #8
            bcs   :ev
            clc
            lda   ED_HUSED
            adc   ED_T3
            tax
            lda   ED_HUSED+1
            adc   #0
            cmp   #>ED_RINGP1
            bcc   :fit
            bne   :ev
            cpx   #<ED_RINGP1
            bcc   :fit
:ev         lda   ED_HN              ;drop the oldest entry
            dec   a
            sta   ED_HN
            jsr   ED_HFIND
            clc
            lda   ED_HUSED
            sbc   (PTR1)             ;- len - 1 (carry clear)
            sta   ED_HUSED
            lda   ED_HUSED+1
            sbc   #0
            sta   ED_HUSED+1
            bra   :chk
:fit        lda   ED_HUSED           ;slide ED_HUSED bytes up
            ora   ED_HUSED+1
            beq   :put
            clc
            lda   #<ED_HRING
            adc   ED_HUSED
            sta   PTR1
            lda   #>ED_HRING
            adc   ED_HUSED+1
            sta   PTR1+1
            clc
            lda   PTR1
            adc   ED_T3
            sta   PTR2
            lda   PTR1+1
            adc   #0
            sta   PTR2+1
            lda   ED_HUSED
            sta   ED_T1
            lda   ED_HUSED+1
            sta   ED_T2
:mv         lda   PTR1
            bne   :a
            dec   PTR1+1
:a          dec   PTR1
            lda   PTR2
            bne   :b
            dec   PTR2+1
:b          dec   PTR2
            lda   (PTR1)
            sta   (PTR2)
            lda   ED_T1
            bne   :c
            dec   ED_T2
:c          dec   ED_T1
            lda   ED_T1
            ora   ED_T2
            bne   :mv
:put        lda   ED_LEN
            sta   ED_HRING
            tay
            beq   :pd
:cp         lda   LINEBUF-1,y
            sta   ED_HRING,y
            dey
            bne   :cp
:pd         clc
            lda   ED_HUSED
            adc   ED_T3
            sta   ED_HUSED
            bcc   :nc
            inc   ED_HUSED+1
:nc         inc   ED_HN
            rts
