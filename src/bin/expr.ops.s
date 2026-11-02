*---------------------------------------------------------------
* expr.ops.s -- expr's string-prep and arithmetic engines,
* split from
* expr.eval.s at a GLOBAL boundary for the as source
* window (S9-PLAN sec 6, tier 2). One assembly stream:
* ALWAYS put immediately after its predecessor; every
* rule in the original header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* EX_STRPREP -- ensure EX_SV_PTR/EX_RV_PTR both address real
* strings, stringifying whichever side is still numeric (EX_CMP
* only calls this when NOT both are numeric, so at most ONE side
* needs it -- one shared scratch buffer, EX_SBUFA, suffices).
*---------------------------------------------------------------
EX_STRPREP  lda   EX_SV_ISNM
            beq   :rvchk
            lda   EX_SV_NUM
            sta   U2DEC_VAL
            lda   EX_SV_NUM+1
            sta   U2DEC_VAL+1
            lda   #<EX_SBUFA
            sta   PTR1
            lda   #>EX_SBUFA
            sta   PTR1+1
            jsr   U2DEC
            lda   #<EX_SBUFA
            sta   EX_SV_PTR
            lda   #>EX_SBUFA
            sta   EX_SV_PTR+1
:rvchk      lda   EX_RV_ISNM
            beq   :done
            lda   EX_RV_NUM
            sta   U2DEC_VAL
            lda   EX_RV_NUM+1
            sta   U2DEC_VAL+1
            lda   #<EX_SBUFA
            sta   PTR1
            lda   #>EX_SBUFA
            sta   PTR1+1
            jsr   U2DEC
            lda   #<EX_SBUFA
            sta   EX_RV_PTR
            lda   #>EX_SBUFA
            sta   EX_RV_PTR+1
:done       rts

*---------------------------------------------------------------
* EX_DOCMP -- apply the comparison in EX_CMPOP to EX_SV (left)
* and EX_RV (right); result (always numeric 0/1) replaces EX_RV.
* Numeric path if both sides are numeric, else lexicographic
* (string) after EX_STRPREP.
*---------------------------------------------------------------
EX_DOCMP    lda   EX_SV_ISNM
            beq   :strmode
            lda   EX_RV_ISNM
            beq   :strmode
            jsr   EX_CMPNUM
            beq   :ceq
            bcs   :cgt
            lda   #EX_REL_LT
            bra   :setrel
:strmode    jsr   EX_STRPREP
            lda   EX_SV_PTR
            sta   PTR0
            lda   EX_SV_PTR+1
            sta   PTR0+1
            lda   EX_RV_PTR
            sta   PTR1
            lda   EX_RV_PTR+1
            sta   PTR1+1
            jsr   STRCMP
            cmp   #0
            beq   :ceq
            cmp   #1
            beq   :cgt
            lda   #EX_REL_LT
            bra   :setrel
:cgt        lda   #EX_REL_GT
            bra   :setrel
:ceq        lda   #EX_REL_EQ
:setrel     sta   EX_REL
            lda   EX_CMPOP
            cmp   #0
            beq   :ceqop
            cmp   #1
            beq   :cneop
            cmp   #2
            beq   :cltop
            cmp   #3
            beq   :cleop
            cmp   #4
            beq   :cgtop
            ;-- else 5 = '>='
            lda   EX_REL
            cmp   #EX_REL_LT
            beq   :false
            bra   :true
:ceqop      lda   EX_REL
            cmp   #EX_REL_EQ
            beq   :true
            bra   :false
:cneop      lda   EX_REL
            cmp   #EX_REL_EQ
            beq   :false
            bra   :true
:cltop      lda   EX_REL
            cmp   #EX_REL_LT
            beq   :true
            bra   :false
:cleop      lda   EX_REL
            cmp   #EX_REL_GT
            beq   :false
            bra   :true
:cgtop      lda   EX_REL
            cmp   #EX_REL_GT
            beq   :true
            bra   :false
:false      lda   #1
            sta   EX_RV_ISNM
            stz   EX_RV_NUM
            stz   EX_RV_NUM+1
            rts
:true       lda   #1
            sta   EX_RV_ISNM
            lda   #1
            sta   EX_RV_NUM
            stz   EX_RV_NUM+1
            rts

*---------------------------------------------------------------
* EX_DOADD -- EX_SV + EX_RV -> EX_RV. Both operands must be
* numeric (else status 2); a carry out of bit 15 is status 2
* (overflow), never a silent wrap.
*---------------------------------------------------------------
EX_DOADD    lda   EX_SV_ISNM
            beq   :nonnum
            lda   EX_RV_ISNM
            beq   :nonnum
            clc
            lda   EX_SV_NUM
            adc   EX_RV_NUM
            sta   EX_TMP
            lda   EX_SV_NUM+1
            adc   EX_RV_NUM+1
            sta   EX_TMP+1
            bcs   :nonnum           ;overflow -> same status as
                                    ;a non-numeric operand (2)
            lda   #1
            sta   EX_RV_ISNM
            lda   EX_TMP
            sta   EX_RV_NUM
            lda   EX_TMP+1
            sta   EX_RV_NUM+1
            rts
:nonnum     lda   #2
            sta   EX_STATUS
            rts

*---------------------------------------------------------------
* EX_DOSUB -- EX_SV - EX_RV -> EX_RV, unsigned. RV>SV (would go
* negative) is status 2 -- no two's-complement wraparound.
*---------------------------------------------------------------
EX_DOSUB    lda   EX_SV_ISNM
            beq   :nonnum
            lda   EX_RV_ISNM
            beq   :nonnum
            jsr   EX_CMPNUM
            bcc   :nonnum           ;SV<RV -> would underflow
            sec
            lda   EX_SV_NUM
            sbc   EX_RV_NUM
            sta   EX_TMP
            lda   EX_SV_NUM+1
            sbc   EX_RV_NUM+1
            sta   EX_TMP+1
            lda   #1
            sta   EX_RV_ISNM
            lda   EX_TMP
            sta   EX_RV_NUM
            lda   EX_TMP+1
            sta   EX_RV_NUM+1
            rts
:nonnum     lda   #2
            sta   EX_STATUS
            rts

*---------------------------------------------------------------
* EX_DOMUL -- EX_SV * EX_RV -> EX_RV, a real 16x16->32 shift-add
* product (EX_MSHA the shifted multiplicand, EX_MPR the 32-bit
* accumulator) so a nonzero high 16 bits is a DETECTED overflow
* (status 2), not a truncated low-16 wrong answer.
*---------------------------------------------------------------
EX_DOMUL    lda   EX_SV_ISNM
            bne   :svnum
            jmp   :nonnum
:svnum      lda   EX_RV_ISNM
            bne   :rvnum
            jmp   :nonnum
:rvnum      lda   EX_SV_NUM
            sta   EX_MSHA
            lda   EX_SV_NUM+1
            sta   EX_MSHA+1
            stz   EX_MSHA+2
            stz   EX_MSHA+3
            stz   EX_MPR
            stz   EX_MPR+1
            stz   EX_MPR+2
            stz   EX_MPR+3
            lda   EX_RV_NUM
            sta   EX_MB
            lda   EX_RV_NUM+1
            sta   EX_MB+1
            ldx   #16
:mloop      lsr   EX_MB+1
            ror   EX_MB
            bcc   :noadd
            clc
            lda   EX_MPR
            adc   EX_MSHA
            sta   EX_MPR
            lda   EX_MPR+1
            adc   EX_MSHA+1
            sta   EX_MPR+1
            lda   EX_MPR+2
            adc   EX_MSHA+2
            sta   EX_MPR+2
            lda   EX_MPR+3
            adc   EX_MSHA+3
            sta   EX_MPR+3
:noadd      asl   EX_MSHA
            rol   EX_MSHA+1
            rol   EX_MSHA+2
            rol   EX_MSHA+3
            dex
            bne   :mloop
            lda   EX_MPR+2
            ora   EX_MPR+3
            bne   :nonnum           ;hi word set -> overflow
            lda   #1
            sta   EX_RV_ISNM
            lda   EX_MPR
            sta   EX_RV_NUM
            lda   EX_MPR+1
            sta   EX_RV_NUM+1
            rts
:nonnum     lda   #2
            sta   EX_STATUS
            rts

*---------------------------------------------------------------
* EX_DIV16 -- 16-bit unsigned restoring division. IN: EX_SV_NUM
* (dividend), EX_RV_NUM (divisor). OUT: carry SET if divisor is
* 0 (caller reports status 3); carry CLEAR + EX_DN = quotient,
* EX_DR = remainder otherwise.
*---------------------------------------------------------------
EX_DIV16    lda   EX_RV_NUM
            ora   EX_RV_NUM+1
            bne   :nz
            sec
            rts
:nz         stz   EX_DR
            stz   EX_DR+1
            lda   EX_SV_NUM
            sta   EX_DN
            lda   EX_SV_NUM+1
            sta   EX_DN+1
            ldx   #16
:dloop      asl   EX_DN
            rol   EX_DN+1
            rol   EX_DR
            rol   EX_DR+1
            lda   EX_DR
            sec
            sbc   EX_RV_NUM
            tay
            lda   EX_DR+1
            sbc   EX_RV_NUM+1
            bcc   :dskip
            sty   EX_DR
            sta   EX_DR+1
            inc   EX_DN
:dskip      dex
            bne   :dloop
            clc
            rts

*---------------------------------------------------------------
* EX_DODIV / EX_DOMOD -- `/` and `%`, sharing EX_DIV16. Both
* operands must be numeric (status 2); divisor 0 is status 3.
*---------------------------------------------------------------
EX_DODIV    lda   EX_SV_ISNM
            beq   :nonnum
            lda   EX_RV_ISNM
            beq   :nonnum
            jsr   EX_DIV16
            bcs   :divzero
            lda   #1
            sta   EX_RV_ISNM
            lda   EX_DN
            sta   EX_RV_NUM
            lda   EX_DN+1
            sta   EX_RV_NUM+1
            rts
:nonnum     lda   #2
            sta   EX_STATUS
            rts
:divzero    lda   #3
            sta   EX_STATUS
            rts

EX_DOMOD    lda   EX_SV_ISNM
            beq   :nonnum
            lda   EX_RV_ISNM
            beq   :nonnum
            jsr   EX_DIV16
            bcs   :divzero
            lda   #1
            sta   EX_RV_ISNM
            lda   EX_DR
            sta   EX_RV_NUM
            lda   EX_DR+1
            sta   EX_RV_NUM+1
            rts
:nonnum     lda   #2
            sta   EX_STATUS
            rts
:divzero    lda   #3
            sta   EX_STATUS
            rts

*---------------------------------------------------------------
* EX_NPARSE -- classify one token: unsigned decimal integer, or
* not. IN: PTR1 = NUL-terminated token. OUT: carry CLEAR +
* EX_TMP = 16-bit value on success; carry SET if the string is
* empty, has any non-digit byte, OR would overflow 16 bits (see
* file header) -- caller then treats it as an opaque string.
*
* Overflow is caught BY A PRECHECK before each *10+digit step
* (threshold 6553 = $1999, the largest value for which *10+9
* still fits) rather than by inspecting carries after a wide
* shift-chain -- simpler to get right, and the accumulator never
* actually holds a wrapped value at any point.
*---------------------------------------------------------------
EX_NPARSE   stz   EX_TMP
            stz   EX_TMP+1
            ldy   #0
            lda   (PTR1),y
            beq   :bad              ;empty
:loop       lda   (PTR1),y
            beq   :ok
            cmp   #$B0
            bcc   :bad
            cmp   #$BA
            bcs   :bad
            and   #$0F
            sta   EX_DIGIT
            lda   EX_TMP+1
            cmp   #$19
            bcc   :safe
            bne   :bad
            lda   EX_TMP
            cmp   #$99
            bcc   :safe
            bne   :bad
            lda   EX_DIGIT
            cmp   #6
            bcs   :bad
:safe       asl   EX_TMP
            rol   EX_TMP+1          ;*2
            lda   EX_TMP
            sta   EX_V2
            lda   EX_TMP+1
            sta   EX_V2+1
            asl   EX_TMP
            rol   EX_TMP+1          ;*4
            asl   EX_TMP
            rol   EX_TMP+1          ;*8
            clc
            lda   EX_TMP
            adc   EX_V2
            sta   EX_TMP
            lda   EX_TMP+1
            adc   EX_V2+1
            sta   EX_TMP+1          ;*10
            lda   EX_DIGIT
            clc
            adc   EX_TMP
            sta   EX_TMP
            lda   #0
            adc   EX_TMP+1
            sta   EX_TMP+1
            iny
            bra   :loop
:ok         clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* Working storage. Ordinary memory, same reasoning as
* testeval.s's own TE_* block (GETTOK-family needs a ZERO-PAGE
* pointer to dereference the array; the array's home does not).
*---------------------------------------------------------------
EX_ARGC     ds    1
EX_AVBASE   ds    2
EX_POS      ds    1
EX_STATUS   ds    1
EX_CMPOP    ds    1
EX_REL      ds    1
EX_TMPCH    ds    1

EX_RV_ISNM  ds    1
EX_RV_NUM   ds    2
EX_RV_PTR   ds    2
EX_SV_ISNM  ds    1
EX_SV_NUM   ds    2
EX_SV_PTR   ds    2

EX_SP       ds    1        ;EX_PUSHRV/EX_POPSV software-stack
                           ;index -- real max depth 5, so 8
                           ;slots (40B) is headroom, not a cap
EX_STK      ds    40

EX_TMP      ds    2
EX_V2       ds    2
EX_DIGIT    ds    1

EX_MSHA     ds    4
EX_MPR      ds    4
EX_MB       ds    2

EX_DN       ds    2
EX_DR       ds    2

EX_SBUFA    ds    7        ;stringify scratch -- "65535"+NUL=6,
                           ;1 byte spare
