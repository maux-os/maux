*---------------------------------------------------------------
* joinio.s -- join's per-side line/field readers, `put` by
* src/bin/join.s (NOT a standalone binary -- the same put-module
* shape as cut.s's cutlist.s), split out purely to fit as's
* 16,128-byte source window (join.s alone measured well over it,
* stripped -- house heavy commenting counts fully against that
* budget, since strip_comments.py only blanks WHOLE-line
* comments, never a trailing `;` one). Every symbol here
* resolves against join.s's own equates/bss (FD1/FD2, BUFPOS1/
* BUFLEN1, L1BUF, FOFF1/FLEN1/NFLD1, TMODE/SEPCH, etc.)
* unchanged.
*---------------------------------------------------------------
GETFLD1     tax
            dex
            cpx   NFLD1
            bcc   :ok
            stz   JFLEN
            rts
:ok         lda   FOFF1,x
            sta   JFOFF
            lda   FLEN1,x
            sta   JFLEN
            rts

GETFLD2     tax
            dex
            cpx   NFLD2
            bcc   :ok
            stz   JFLEN
            rts
:ok         lda   FOFF2,x
            sta   JFOFF
            lda   FLEN2,x
            sta   JFLEN
            rts

*---------------------------------------------------------------
* CMPFLD -- IN: PTR0/CFALEN = field A, PTR1/CFBLEN = field B.
* OUT: A = 0/1/$FF (STRCMP's own encoding, prefix-then-length).
*---------------------------------------------------------------
CMPFLD      ldy   #0
:lp         cpy   CFALEN
            beq   :aend
            cpy   CFBLEN
            beq   :bend
            lda   (PTR0),y
            cmp   (PTR1),y
            bne   :diff
            iny
            bra   :lp
:aend       cpy   CFBLEN
            beq   :eq
            lda   #$FF
            rts
:bend       lda   #1
            rts
:diff       bcc   :lt
            lda   #1
            rts
:lt         lda   #$FF
            rts
:eq         lda   #0
            rts

*---------------------------------------------------------------
* GETLN1/GETLN2 -- next line into L1BUF/L2BUF, then
* field-split it. HAVE1/HAVE2 = 1 iff a line is buffered.
*---------------------------------------------------------------
GETLN1      stz   LEN1
:next       lda   LEN1
            cmp   #LINEMAX
            bcs   :haveln
            jsr   GETB1
            bcs   :eofhit
            cmp   #$8D
            beq   :haveln
            cmp   #$0D             ;either terminator ends a
            beq   :haveln        ;line -- a foreign file
            ldy   LEN1
            sta   L1BUF,y
            inc   LEN1
            bra   :next
:haveln     ldy   LEN1
            lda   #0
            sta   L1BUF,y
            lda   #1
            sta   HAVE1
            lda   #<L1BUF
            sta   PTR0
            lda   #>L1BUF
            sta   PTR0+1
            jmp   FLDSPLIT1
:eofhit     lda   LEN1
            beq   :nothing
            ldy   LEN1
            lda   #0
            sta   L1BUF,y
            lda   #1
            sta   HAVE1
            lda   #<L1BUF
            sta   PTR0
            lda   #>L1BUF
            sta   PTR0+1
            jmp   FLDSPLIT1
:nothing    stz   HAVE1
            rts

GETLN2      stz   LEN2
:next       lda   LEN2
            cmp   #LINEMAX
            bcs   :haveln
            jsr   GETB2
            bcs   :eofhit
            cmp   #$8D
            beq   :haveln
            cmp   #$0D             ;either terminator ends a
            beq   :haveln        ;line -- a foreign file
            ldy   LEN2
            sta   L2BUF,y
            inc   LEN2
            bra   :next
:haveln     ldy   LEN2
            lda   #0
            sta   L2BUF,y
            lda   #1
            sta   HAVE2
            lda   #<L2BUF
            sta   PTR0
            lda   #>L2BUF
            sta   PTR0+1
            jmp   FLDSPLIT2
:eofhit     lda   LEN2
            beq   :nothing
            ldy   LEN2
            lda   #0
            sta   L2BUF,y
            lda   #1
            sta   HAVE2
            lda   #<L2BUF
            sta   PTR0
            lda   #>L2BUF
            sta   PTR0+1
            jmp   FLDSPLIT2
:nothing    stz   HAVE2
            rts

*---------------------------------------------------------------
* GETB1/REFIL1, GETB2/REFIL2 -- buffered per-fd input, comm.s's
* own duplicated shape (liba has no generic per-fd reader).
*---------------------------------------------------------------
GETB1       ldx   BUFPOS1
            cpx   BUFLEN1
            bcc   :hv
            jsr   REFIL1
            bcs   :eo
            ldx   BUFPOS1
:hv         lda   CBUF1,x
            inc   BUFPOS1
            clc
            rts
:eo         sec
            rts

REFIL1      lda   FD1
            sta   R1PARM_REF
            lda   #<R1PARM
            ldx   #>R1PARM
            jsr   SC_READ
            bcs   :er
            lda   R1PARM_TRANS
            ora   R1PARM_TRANS+1
            beq   :er
            lda   R1PARM_TRANS
            sta   BUFLEN1
            stz   BUFPOS1
            clc
            rts
:er         sec
            rts

GETB2       ldx   BUFPOS2
            cpx   BUFLEN2
            bcc   :hv
            jsr   REFIL2
            bcs   :eo
            ldx   BUFPOS2
:hv         lda   CBUF2,x
            inc   BUFPOS2
            clc
            rts
:eo         sec
            rts

REFIL2      lda   FD2
            sta   R2PARM_REF
            lda   #<R2PARM
            ldx   #>R2PARM
            jsr   SC_READ
            bcs   :er
            lda   R2PARM_TRANS
            ora   R2PARM_TRANS+1
            beq   :er
            lda   R2PARM_TRANS
            sta   BUFLEN2
            stz   BUFPOS2
            clc
            rts
:er         sec
            rts

*---------------------------------------------------------------
* FLDSPLIT1/FLDSPLIT2 -- IN: PTR0 = NUL-terminated line. Fills
* FOFFn/FLENn[0..NFLDn-1]. TMODE=0: blanks separate, leading
* blanks and runs collapse. TMODE=1: SEPCH separates, every
* field (incl. empty ones) counts.
*---------------------------------------------------------------
FLDSPLIT1   lda   TMODE
            bne   :c1
            ldy   #0
            stz   NFLD1
:s1skip     lda   (PTR0),y
            beq   :s1done
            jsr   ISBLANK
            bcc   :s1start
            iny
            bra   :s1skip
:s1start    sty   FSTART
:s1scan     iny
            lda   (PTR0),y
            beq   :s1emit
            jsr   ISBLANK
            bcs   :s1emit
            bra   :s1scan
:s1emit     jsr   EMIT1
            lda   (PTR0),y
            beq   :s1done
            bra   :s1skip
:s1done     rts
:c1         ldy   #0
            stz   NFLD1
            sty   FSTART
:c1scan     lda   (PTR0),y
            beq   :c1emit
            and   #$7F             ;SEPCH was masked at -t, so
            cmp   SEPCH            ;mask the file byte to match
            beq   :c1emit
            iny
            bra   :c1scan
:c1emit     jsr   EMIT1
            lda   (PTR0),y
            beq   :c1done
            iny
            sty   FSTART
            bra   :c1scan
:c1done     rts

FLDSPLIT2   lda   TMODE
            bne   :c2
            ldy   #0
            stz   NFLD2
:s2skip     lda   (PTR0),y
            beq   :s2done
            jsr   ISBLANK
            bcc   :s2start
            iny
            bra   :s2skip
:s2start    sty   FSTART
:s2scan     iny
            lda   (PTR0),y
            beq   :s2emit
            jsr   ISBLANK
            bcs   :s2emit
            bra   :s2scan
:s2emit     jsr   EMIT2
            lda   (PTR0),y
            beq   :s2done
            bra   :s2skip
:s2done     rts
:c2         ldy   #0
            stz   NFLD2
            sty   FSTART
:c2scan     lda   (PTR0),y
            beq   :c2emit
            and   #$7F             ;SEPCH was masked at -t, so
            cmp   SEPCH            ;mask the file byte to match
            beq   :c2emit
            iny
            bra   :c2scan
:c2emit     jsr   EMIT2
            lda   (PTR0),y
            beq   :c2done
            iny
            sty   FSTART
            bra   :c2scan
:c2done     rts

EMIT1       lda   NFLD1
            cmp   #MAXFLD
            bcs   :full
            tax
            lda   FSTART
            sta   FOFF1,x
            tya
            sec
            sbc   FSTART
            sta   FLEN1,x
            inc   NFLD1
:full       rts

EMIT2       lda   NFLD2
            cmp   #MAXFLD
            bcs   :full
            tax
            lda   FSTART
            sta   FOFF2,x
            tya
            sec
            sbc   FSTART
            sta   FLEN2,x
            inc   NFLD2
:full       rts

ISBLANK     cmp   #$A0
            beq   :yes
            cmp   #TAB
            beq   :yes
            cmp   #$20             ;the LOW twins, from a file
            beq   :yes             ;that came from outside maux
            cmp   #$09
            beq   :yes
            clc
            rts
:yes        sec
            rts
