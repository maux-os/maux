*---------------------------------------------------------------
* diffcout.s -- diff's -c (context) output: the two sections per
* group, their inclusive ranges, and the rule that a section
* with no changed line of its own prints as its header line
* alone. The -u half, and everything both halves share (the
* grouping pass, the prefix printers, the decimal parser), is
* diffctx.s.
*
* `put` into src/bin/diff.s right after diffctx.s, which it was
* split from for check-dialect's as-window budget: the two
* together measured 12,648 B stripped against a 4,476 B
* manifest, over the 16,128-byte ceiling, and new code is born
* window-fit. One assembly stream; every rule in diff.s's
* manifest header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* OUTC -- context output. Header pair, then per group a stars
* line, the old section and the new section.
*---------------------------------------------------------------
OUTC        lda   #<CHDR1
            ldx   #>CHDR1
            jsr   PRNAME1
            lda   #<CHDR2
            ldx   #>CHDR2
            jsr   PRNAME2
            stz   GS
:cgloop     lda   GS
            cmp   NHUNKS
            bcc   :cgrp
            rts
:cgrp       jsr   GRPSCAN
            lda   #<CSTARS
            ldx   #>CSTARS
            jsr   PRSTR
            jsr   PRCR
            lda   #<CHDR1
            ldx   #>CHDR1
            jsr   PRSTR
            lda   OSTART
            sta   CLN
            lda   OCNT
            sta   CLN2
            jsr   PRRNGC
            lda   #<CSTAR4
            ldx   #>CSTAR4
            jsr   PRSTR
            jsr   PRCR
            jsr   GRPHASD
            bcc   :cnew
            jsr   COLDBODY
:cnew       lda   #<CHDR2
            ldx   #>CHDR2
            jsr   PRSTR
            lda   NSTART
            sta   CLN
            lda   NCNT
            sta   CLN2
            jsr   PRRNGC
            lda   #<CDASH4
            ldx   #>CDASH4
            jsr   PRSTR
            jsr   PRCR
            jsr   GRPHASI
            bcc   :cnext
            jsr   CNEWBODY
:cnext      lda   GE
            clc
            adc   #1
            sta   GS
            bra   :cgloop

*---------------------------------------------------------------
* PRRNGC -- IN: CLN = start, CLN2 = count. Context format's own
* range: "s,e" INCLUSIVE, or "s" when the count is 1, or "s-1"
* alone when it is 0.
*---------------------------------------------------------------
PRRNGC      lda   CLN2
            bne   :cpos
            lda   CLN
            sec
            sbc   #1
            jmp   PRDEC
:cpos       cmp   #1
            beq   :cone
            lda   CLN
            jsr   PRDEC
            lda   #$AC
            jsr   DFPUT1
            clc
            lda   CLN
            adc   CLN2
            sec
            sbc   #1
            jmp   PRDEC
:cone       lda   CLN
            jmp   PRDEC

*---------------------------------------------------------------
* COLDBODY -- the `***` section's lines: context, then each
* hunk's deletions marked '! ' if that hunk also inserts (a
* change) or '- ' if it only deletes.
*---------------------------------------------------------------
COLDBODY    lda   OSTART
            sta   CURA
            lda   GS
            sta   GK
:okloop     lda   GK
            cmp   GE
            beq   :odo
            bcs   :otail
:odo        lda   GK
            jsr   GETHUNK
:octx       lda   CURA
            cmp   HA
            beq   :octxp
            bcs   :ochg
:octxp      lda   #$A0
            sta   CPFX
            lda   #$A0
            sta   CPFX2
            lda   CURA
            jsr   PRPA
            inc   CURA
            bra   :octx
:ochg       lda   HDELS
            beq   :oknext
            sta   GKN
            lda   HINS
            beq   :ominus
            lda   #$A1           ;'!'
            bra   :osetp
:ominus     lda   #$AD           ;'-'
:osetp      sta   CPFX
            lda   #$A0
            sta   CPFX2
:odl        lda   CURA
            jsr   PRPA
            inc   CURA
            dec   GKN
            bne   :odl
:oknext     inc   GK
            bra   :okloop
:otail      lda   CURA
            cmp   OEND
            beq   :otp
            bcs   :otdone
:otp        lda   #$A0
            sta   CPFX
            lda   #$A0
            sta   CPFX2
            lda   CURA
            jsr   PRPA
            inc   CURA
            bra   :otail
:otdone     rts

*---------------------------------------------------------------
* CNEWBODY -- the `---` section's lines, the same shape on the
* B side: '! ' when the hunk also deletes, '+ ' when it only
* inserts.
*---------------------------------------------------------------
CNEWBODY    lda   NSTART
            sta   CURB
            lda   GS
            sta   GK
:nkloop     lda   GK
            cmp   GE
            beq   :ndo
            bcs   :ntail
:ndo        lda   GK
            jsr   GETHUNK
:nctx       lda   CURB
            cmp   HB
            beq   :nctxp
            bcs   :nchg
:nctxp      lda   #$A0
            sta   CPFX
            lda   #$A0
            sta   CPFX2
            lda   CURB
            jsr   PRPB
            inc   CURB
            bra   :nctx
:nchg       lda   HINS
            beq   :nknext
            sta   GKN
            lda   HDELS
            beq   :nplus
            lda   #$A1
            bra   :nsetp
:nplus      lda   #$AB           ;'+'
:nsetp      sta   CPFX
            lda   #$A0
            sta   CPFX2
:nil        lda   CURB
            jsr   PRPB
            inc   CURB
            dec   GKN
            bne   :nil
:nknext     inc   GK
            bra   :nkloop
:ntail      lda   CURB
            cmp   NEND
            beq   :ntp
            bcs   :ntdone
:ntp        lda   #$A0
            sta   CPFX
            lda   #$A0
            sta   CPFX2
            lda   CURB
            jsr   PRPB
            inc   CURB
            bra   :ntail
:ntdone     rts

UHDR1       asc   "--- "
            dfb   0
UHDR2       asc   "+++ "
            dfb   0
UAT         asc   "@@ -"
            dfb   0
UATP        asc   " +"
            dfb   0
UATE        asc   " @@"
            dfb   0
CHDR1       asc   "*** "
            dfb   0
CHDR2       asc   "--- "
            dfb   0
CSTARS      asc   "***************"
            dfb   0
CSTAR4      asc   " ****"
            dfb   0
CDASH4      asc   " ----"
            dfb   0
