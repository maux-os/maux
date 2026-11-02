*---------------------------------------------------------------
* plasmaop.s -- PLASMA VM compares, branches, call/frame/jump
* opcodes. Ported verbatim from plvm02.s lines 1132-1491 (ISEQ
* through JUMP); dialect syntax only, anonymous +/- labels made
* unique merlin32 :locals. put by plasma.s after plasmals.s.
*---------------------------------------------------------------

*---------------------------------------------------------------
* ISEQ/ISNE/ISFLS/ISTRU/ISGE/ISLE/ISGT/ISLT (1134-1187). The two
* blank "+" defs immediately followed by a "-" def on the very
* next source line (1161/1162, 1178/1179) are the SAME address
* in ACME -- one :local each (L_ISGEB, L_ISGTB) covers both.
*---------------------------------------------------------------
ISEQ        lda   ESTKL,x
            cmp   ESTKL+1,x
            bne   ISFLS
            lda   ESTKH,x
            cmp   ESTKH+1,x
            bne   ISFLS
ISTRU       lda   #$FF
            sta   ESTKL+1,x
            sta   ESTKH+1,x
            jmp   DROP

ISNE        lda   ESTKL,x
            cmp   ESTKL+1,x
            bne   ISTRU
            lda   ESTKH,x
            cmp   ESTKH+1,x
            bne   ISTRU
ISFLS       lda   #$00
            sta   ESTKL+1,x
            sta   ESTKH+1,x
            jmp   DROP

ISGE        lda   ESTKL+1,x
            cmp   ESTKL,x
            lda   ESTKH+1,x
            sbc   ESTKH,x
            bvs   L_ISGEB
            bpl   ISTRU
            bmi   ISFLS
L_ISGEB      bpl   ISFLS
            bmi   ISTRU

ISLE        lda   ESTKL,x
            cmp   ESTKL+1,x
            lda   ESTKH,x
            sbc   ESTKH+1,x
            bvs   L_ISGEB
            bpl   ISTRU
            bmi   ISFLS

ISGT        lda   ESTKL,x
            cmp   ESTKL+1,x
            lda   ESTKH,x
            sbc   ESTKH+1,x
            bvs   L_ISGTB
            bmi   ISTRU
            bpl   ISFLS
L_ISGTB      bmi   ISFLS
            bpl   ISTRU

ISLT        lda   ESTKL+1,x
            cmp   ESTKL,x
            lda   ESTKH+1,x
            sbc   ESTKH,x
            bvs   L_ISGTB
            bmi   ISTRU
            bpl   ISFLS

*---------------------------------------------------------------
* SEL -- case-select branch (plvm02.s 1191-1257)
*---------------------------------------------------------------
SEL         inx
            tya                     ;flatten ip
            sec
            adc   IPL
            sta   TMPL
            lda   #$00
            tay
            adc   IPH
            sta   TMPH              ;add branch offset
            lda   (TMP),y
            adc   TMPL
            sta   IPL
            iny
            lda   (TMP),y
            adc   TMPH
            sta   IPH
            dey
            lda   (IP),y
            sta   TMPL              ;case count
            inc   IPL
            bne   CASELP
            inc   IPH
CASELP      lda   ESTKL-1,x
            cmp   (IP),y
            beq   :SELEQ
            lda   ESTKH-1,x
            iny
            sbc   (IP),y
            bmi   CASEEND
:SELLP      iny
            iny
            dec   TMPL
            beq   FIXNEXT
            iny
            bne   CASELP
            inc   IPH
            bne   CASELP
:SELEQ      lda   ESTKH-1,x
            iny
            sbc   (IP),y
            beq   BRNCH
            bpl   :SELLP
CASEEND     lda   #$00
            sta   TMPH
            dec   TMPL
            lda   TMPL
            asl                     ;skip remaining cases
            rol   TMPH
            asl
            rol   TMPH
            adc   IPL
            sta   IPL
            lda   TMPH
            adc   IPH
            sta   IPH
            iny
            iny
FIXNEXT     tya
            ldy   #$00
            sec
            adc   IPL
            sta   IPL
            bcc   :SELFIN
            inc   IPH
:SELFIN     jmp   FETCHOP

*---------------------------------------------------------------
* BRAND/BROR/BREQ/BRNE/BRTRU/NOBRNCH/BRFLS/BRNCH (1258-1315)
*---------------------------------------------------------------
BRAND       lda   ESTKL,x
            ora   ESTKH,x
            beq   BRNCH
            inx                     ;drop left half of and
            bne   NOBRNCH
BROR        lda   ESTKL,x
            ora   ESTKH,x
            bne   BRNCH
            inx                     ;drop left half of or
            bne   NOBRNCH
BREQ        inx
            inx
            lda   ESTKL-2,x
            cmp   ESTKL-1,x
            bne   NOBRNCH
            lda   ESTKH-2,x
            cmp   ESTKH-1,x
            beq   BRNCH
            bne   NOBRNCH
BRNE        inx
            inx
            lda   ESTKL-2,x
            cmp   ESTKL-1,x
            bne   BRNCH
            lda   ESTKH-2,x
            cmp   ESTKH-1,x
            bne   BRNCH
            beq   NOBRNCH
BRTRU       inx
            lda   ESTKH-1,x
            ora   ESTKL-1,x
            bne   BRNCH
NOBRNCH     iny                     ;+inc_ip
            iny
            bmi   FIXNEXT
            jmp   NEXTOP
BRFLS       inx
            lda   ESTKH-1,x
            ora   ESTKL-1,x
            bne   NOBRNCH
BRNCH       tya                     ;flatten ip
            sec
            adc   IPL
            sta   TMPL
            lda   #$00
            tay
            adc   IPH
            sta   TMPH              ;add branch offset
            lda   (TMP),y
            adc   TMPL
            sta   IPL
            iny
            lda   (TMP),y
            adc   TMPH
            sta   IPH
            dey
            jmp   FETCHOP

*---------------------------------------------------------------
* BRGT/BRLT/DECBRGE/INCBRLE/SUBBRGE/ADDBRLE -- FOR-loop compares
* (plvm02.s 1317-1376). L_BRGE/L_BRLE are reused ACROSS routines
* (SUBBRGE jumps into DECBRGE's body, ADDBRLE into INCBRLE's) --
* that reuse is in the original, not a porting shortcut. They
* are GLOBAL labels (L_ prefix), like L_ISGEB/L_ISGTB/L_BRCMPA/
* L_BRCMPB above: a :local referenced from another global's zone
* is "Unknown label" on real Merlin-8 (merlin32 resolves it by
* whole-file uniqueness) -- the self-host sweep found all six
* 2026-09-13. L_DBGECHK went global with L_BRGE, which would
* otherwise have split its zone from its reference.
*---------------------------------------------------------------
BRGT        lda   ESTKL+1,x
            cmp   ESTKL,x
            lda   ESTKH+1,x
            sbc   ESTKH,x
            bvs   L_BRCMPA
            bpl   NOBRNCH
            bmi   BRNCH
BRLT        lda   ESTKL,x
            cmp   ESTKL+1,x
            lda   ESTKH,x
            sbc   ESTKH+1,x
            bvs   L_BRCMPA
            bpl   NOBRNCH
            bmi   BRNCH
L_BRCMPA     bmi   NOBRNCH
            bpl   BRNCH
DECBRGE     dec   ESTKL,x
            lda   ESTKL,x
            cmp   #$FF
            bne   L_DBGECHK
            dec   ESTKH,x
L_BRGE       lda   ESTKL,x
L_DBGECHK    cmp   ESTKL+1,x
            lda   ESTKH,x
            sbc   ESTKH+1,x
            bvs   L_BRCMPB
            bpl   BRNCH
            bmi   NOBRNCH
INCBRLE     inc   ESTKL,x
            bne   L_BRLE
            inc   ESTKH,x
L_BRLE       lda   ESTKL+1,x
            cmp   ESTKL,x
            lda   ESTKH+1,x
            sbc   ESTKH,x
            bvs   L_BRCMPB
            bpl   BRNCH
            bmi   NOBRNCH
L_BRCMPB     bmi   BRNCH
            bpl   NOBRNCH
SUBBRGE     lda   ESTKL+1,x
            sec
            sbc   ESTKL,x
            sta   ESTKL+1,x
            lda   ESTKH+1,x
            sbc   ESTKH,x
            sta   ESTKH+1,x
            inx
            bne   L_BRGE
ADDBRLE     lda   ESTKL,x
            clc
            adc   ESTKL+1,x
            sta   ESTKL+1,x
            lda   ESTKH,x
            adc   ESTKH+1,x
            sta   ESTKH+1,x
            inx
            bne   L_BRLE

*---------------------------------------------------------------
* CALL/ICAL -- native-code call, direct and indirect (1378-1421)
*---------------------------------------------------------------
CALL        iny                     ;+inc_ip
            lda   (IP),y
            sta   TMPL
            iny                     ;+inc_ip
            lda   (IP),y
            sta   TMPH
            tya
            sec
            adc   IPL
            pha
            lda   IPH
            adc   #$00
            pha
            jsr   JMPTMP
            pla
            sta   IPH
            pla
            sta   IPL
            ldy   #$00
            jmp   FETCHOP

ICAL        lda   ESTKL,x
            sta   TMPL
            lda   ESTKH,x
            sta   TMPH
            inx
            tya
            sec
            adc   IPL
            pha
            lda   IPH
            adc   #$00
            pha
            jsr   JMPTMP
            pla
            sta   IPH
            pla
            sta   IPL
            ldy   #$00
            jmp   FETCHOP

*---------------------------------------------------------------
* ENTER -- allocate a call frame (plvm02.s 1423-1446)
*---------------------------------------------------------------
ENTER       lda   IFPL              ;allocate frame
            iny
            sec
            sbc   (IP),y
            sta   IFPL
            bcs   :ENTA
            dec   IFPH
:ENTA       iny
            lda   (IP),y
            beq   :ENTC
            asl
            tay
:ENTB       lda   ESTKH,x
            dey
            sta   (IFP),y
            lda   ESTKL,x
            inx
            dey
            sta   (IFP),y
            bne   :ENTB
:ENTC       ldy   #$03
            jmp   FETCHOP

*---------------------------------------------------------------
* LEAVE/RET -- deallocate frame / return (plvm02.s 1448-1458)
*---------------------------------------------------------------
LEAVE       lda   IFPL
            iny                     ;+inc_ip
            clc
            adc   (IP),y
            sta   IFPL
            bcs   :LVHI
            rts
:LVHI       inc   IFPH
RET         rts

*---------------------------------------------------------------
* NATV -- return to native code (plvm02.s 1460-1469)
*---------------------------------------------------------------
NATV        tya                     ;flatten ip
            sec
            adc   IPL
            sta   IPL
            bcs   :NATVHI
            jmp   (IP)
:NATVHI     inc   IPH
            jmp   (IP)

*---------------------------------------------------------------
* JUMPZ/JUMP -- unconditional/conditional jumps for the Forth
* compiler (plvm02.s 1471-1491)
*---------------------------------------------------------------
JUMPZ       inx
            lda   ESTKH-1,x
            ora   ESTKL-1,x
            beq   JUMP
            iny                     ;+inc_ip
            iny
            bmi   :JMPZFIX
            jmp   NEXTOP
:JMPZFIX    jmp   FIXNEXT
JUMP        iny
            lda   (IP),y
            pha
            iny
            lda   (IP),y
            sta   IPH
            pla
            sta   IPL
            ldy   #$00
            jmp   FETCHOP
