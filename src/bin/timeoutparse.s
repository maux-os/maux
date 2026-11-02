*---------------------------------------------------------------
* timeoutparse.s -- timeout's own duration and signal parsers:
* TO_PARSEDUR (decimal + optional s/m/h suffix -> ticks,
* sleep.s's PARSESECS/MUL10SECS shape) and TO_PARSESIG (a
* decimal signo or one of TERM/KILL/HUP/INT/QUIT by name,
* shtrap.s's TRAP_AS_SIG mechanism). `put` by src/bin/timeout.s
* (NOT a standalone binary -- the same put-module shape as
* cal.s's own calcalc.s), split out for the same reason units
* split anywhere: `as`'s 16,128-byte source window holds the
* resident manifest plus one put file at a time, and
* timeout.s's own text alone was past it (measured 24,421 B
* stripped, over by 8,295). Every symbol here resolves against
* timeout.s's own equates (TO_MAXVAL) and data (TO_DVAL/
* TO_NDIG/TO_UNITIX/TO_MTMP/TO_PERIT/TO_DCNT/TO_PRESULT/
* TO_SIGNO/TO_NMTMP/TO_TENTH/TO_HAVEFRAC/TO_FTMP) and
* timeoutaux.s's PERITAB/SIGNM_* tables -- see timeout.s's own
* header for the design.
*---------------------------------------------------------------
*---------------------------------------------------------------
* TO_PARSEDUR -- IN: PTR0 = operand text (high-bit, NUL-term).
* OUT: carry CLEAR, TO_PRESULT (4 bytes) = the value in TICKS;
* carry SET on empty, a non-digit before any suffix, a bad or
* trailing-garbage suffix, or a raw value over TO_MAXVAL.
*
* FRACTIONAL SECONDS (SHIPPED 2026-09-17): exactly ONE digit
* after a literal '.', and only when the unit resolves to
* SECONDS (an 's' suffix or none) -- "1.5" is 90 ticks (TICKS_HZ
* 60 / 10 tenths = 6 ticks/tenth), but "1.5m"/"1.5h" and a
* SECOND fractional digit ("1.55") are still refused, loud, not
* silently rounded or truncated: this machine's tick resolution
* (1/60 s) cannot represent a fraction of a MINUTE or HOUR as
* a whole tick count without a real multiply-then-divide this
* tool has no budget for, and a dropped second fractional digit
* is exactly the "looks right, isn't" class of bug this house
* rejects on sight (BUMP's own saturate-not-wrap precedent).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
TO_PARSEDUR stz   TO_DVAL
            stz   TO_DVAL+1
            stz   TO_NDIG
            stz   TO_UNITIX
            stz   TO_HAVEFRAC
            ldy   #0
:loop       lda   (PTR0),y
            bne   :lchar
            jmp   :enddig
:lchar      and   #$7F
            cmp   #'0'
            bcc   :dotchk
            cmp   #'9'+1
            bcs   :dotchk
            sec
            sbc   #'0'
            pha
            jsr   TO_MUL10
            pla
            clc
            adc   TO_DVAL
            sta   TO_DVAL
            lda   TO_DVAL+1
            adc   #0
            sta   TO_DVAL+1
            lda   TO_DVAL+1
            cmp   #>TO_MAXVAL
            bcc   :dok
            beq   :dhi                ;the fractional-suffix
            jmp   :bad                ;block grew; :bad is now
:dhi        lda   TO_DVAL             ;out of branch range
            cmp   #<TO_MAXVAL+1
            bcc   :dok
            jmp   :bad
:dok        inc   TO_NDIG
            iny
            bra   :loop
*-- a near trampoline: the fractional-suffix block below grew
*-- past branch range from here, and :bad is on the far side of
*-- it. Nothing falls in -- the `bra` above is unconditional.
:bad2       jmp   :bad
:dotchk     cmp   #'.'
            beq   :dotfrac
            bra   :sfx
:dotfrac    lda   TO_NDIG
            beq   :bad2             ;".5" -- no whole part
            iny
            lda   (PTR0),y
            and   #$7F
            cmp   #'0'
            bcc   :bad2
            cmp   #'9'+1
            bcs   :bad2
            sec
            sbc   #'0'
            sta   TO_TENTH
            iny
            lda   (PTR0),y
            beq   :fracok            ;"1.5" -- ends right here
            and   #$7F
            cmp   #'0'
            bcc   :fracsfx
            cmp   #'9'+1
            bcs   :fracsfx
            bra   :bad               ;a second fractional digit
*-- A FRACTIONAL MINUTE OR HOUR is no harder than a fractional
*-- second: the digit is worth a tenth of ITS OWN unit, and
*-- TENTHTAB (timeoutaux.s) carries all three tenths exactly.
*-- This used to refuse m/h outright.
:fracsfx    cmp   #'s'
            beq   :fsfxs
            cmp   #'m'
            beq   :fsfxm
            cmp   #'h'
            beq   :fsfxh
            bra   :bad
:fsfxs      lda   #0
            bra   :fsfxset
:fsfxm      lda   #1
            bra   :fsfxset
:fsfxh      lda   #2
:fsfxset    sta   TO_FUNIT
            iny
            lda   (PTR0),y
            bne   :bad               ;garbage after "N.Ns"
            lda   #1
            sta   TO_HAVEFRAC
            lda   TO_FUNIT
            sta   TO_UNITIX
            bra   :enddig
*-- "1.5" with no suffix at all: seconds, as before.
:fracok     lda   #1
            sta   TO_HAVEFRAC
            stz   TO_UNITIX
            bra   :enddig
:sfx        cmp   #'s'
            beq   :sfxs
            cmp   #'m'
            beq   :sfxm
            cmp   #'h'
            beq   :sfxh
            bra   :bad
:sfxs       lda   #0
            bra   :sfxset
:sfxm       lda   #1
            bra   :sfxset
:sfxh       lda   #2
:sfxset     sta   TO_UNITIX
            iny
            lda   (PTR0),y
            bne   :bad               ;garbage after the suffix
:enddig     lda   TO_NDIG
            bne   :haveunit
:bad        sec
            rts
:haveunit   lda   TO_UNITIX
            asl   a
            asl   a
            tax
            ldy   #0
:cplp       lda   PERITAB,x
            sta   TO_PERIT,y
            inx
            iny
            cpy   #4
            bne   :cplp

            stz   TO_PRESULT
            stz   TO_PRESULT+1
            stz   TO_PRESULT+2
            stz   TO_PRESULT+3
            lda   TO_DVAL
            sta   TO_DCNT
            lda   TO_DVAL+1
            sta   TO_DCNT+1
:accum      lda   TO_DCNT
            ora   TO_DCNT+1
            beq   :accdone
            clc
            lda   TO_PRESULT
            adc   TO_PERIT
            sta   TO_PRESULT
            lda   TO_PRESULT+1
            adc   TO_PERIT+1
            sta   TO_PRESULT+1
            lda   TO_PRESULT+2
            adc   TO_PERIT+2
            sta   TO_PRESULT+2
            lda   TO_PRESULT+3
            adc   TO_PERIT+3
            sta   TO_PRESULT+3
            lda   TO_DCNT
            bne   :dcok
            dec   TO_DCNT+1
:dcok       dec   TO_DCNT
            bra   :accum
:accdone    lda   TO_HAVEFRAC
            beq   :nofrac
*-- TO_TENTH copies of this unit's tenth, added 32-bit. At most
*-- nine iterations, so a loop is smaller and clearer than any
*-- multiply, and it is exact for all three units.
            lda   TO_UNITIX
            asl   a
            asl   a
            tax
            ldy   #0
:ftlp       lda   TENTHTAB,x
            sta   TO_FT4,y
            inx
            iny
            cpy   #4
            bne   :ftlp
            lda   TO_TENTH
            sta   TO_FCNT
:faddlp     lda   TO_FCNT
            beq   :nofrac
            clc
            lda   TO_PRESULT
            adc   TO_FT4
            sta   TO_PRESULT
            lda   TO_PRESULT+1
            adc   TO_FT4+1
            sta   TO_PRESULT+1
            lda   TO_PRESULT+2
            adc   TO_FT4+2
            sta   TO_PRESULT+2
            lda   TO_PRESULT+3
            adc   TO_FT4+3
            sta   TO_PRESULT+3
            dec   TO_FCNT
            bra   :faddlp
:nofrac     clc
            rts

*---------------------------------------------------------------
* TO_MUL10 -- TO_DVAL *= 10 (sleep.s's own MUL10SECS, renamed).
* CLOBBERS: A.
*---------------------------------------------------------------
TO_MUL10    lda   TO_DVAL
            sta   TO_MTMP
            lda   TO_DVAL+1
            sta   TO_MTMP+1
            asl   TO_DVAL
            rol   TO_DVAL+1
            asl   TO_DVAL
            rol   TO_DVAL+1
            asl   TO_DVAL
            rol   TO_DVAL+1
            clc
            lda   TO_DVAL
            adc   TO_MTMP
            sta   TO_DVAL
            lda   TO_DVAL+1
            adc   TO_MTMP+1
            sta   TO_DVAL+1
            clc
            lda   TO_DVAL
            adc   TO_MTMP
            sta   TO_DVAL
            lda   TO_DVAL+1
            adc   TO_MTMP+1
            sta   TO_DVAL+1
            rts

