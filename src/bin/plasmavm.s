*---------------------------------------------------------------
* plasmavm.s -- PLASMA VM core: OPTBL, DINTRP/IINTRP, the page-0
* inner-loop template, and the arithmetic/logic opcode handlers
* through CS (load/store handlers LB..DAW moved to plasmals.s --
* the `as` source-window budget: plasmavm.s as ONE file stripped
* to 20149 bytes, well over the 16128 ceiling; CS is the natural
* split point, plvm02.s's own comment boundary). Ported verbatim
* (same instruction sequences, dialect syntax only) from
* ~/src/PLASMA/src/vmsrc/apple/plvm02.s lines 127-174
* (table+entry) and 306-731 (ADD..CS). put by plasma.s
* immediately after the $0900 pad -- this must be the FIRST
* thing in this file so OPTBL lands exactly at $0900.
*
* Anonymous ACME +/- labels became unique merlin32 :locals here;
* see the final report for the def/reference map. A few
* underscore-prefixed ACME helper labels (_NEG/_DIV/_DIV1/
* _DIVLP/_DIVEX, _MULLPL/_MULLPH) became :locals too (MULLPL/
* MULLPH/DNEG/DIVCORE/DIV1/DIVLP/DIVEX) -- merlin32 has no
* zone-local scoping (HACKING.md dialect note), so plain
* whole-file-unique :locals are the correct substitute.
*---------------------------------------------------------------
OPTBL       da    ZERO,CN,CN,CN,CN,CN,CN,CN
            da    CN,CN,CN,CN,CN,CN,CN,CN
            da    MINUS1,BREQ,BRNE,LA,LLA,CB,CW,CS
            da    DROP,DROP2,DUP,DIVMOD,ADDI,SUBI,ANDI,ORI
            da    ISEQ,ISNE,ISGT,ISLT,ISGE,ISLE,BRFLS,BRTRU
            da    BRNCH,SEL,CALL,ICAL,ENTER,LEAVE,RET,CFFB
            da    LB,LW,LLB,LLW,LAB,LAW,DLB,DLW
            da    SB,SW,SLB,SLW,SAB,SAW,DAB,DAW
            da    LNOT,ADD,SUB,MUL,DIV,MOD,INCR,DECR
            da    NEG,COMP,BAND,IOR,XOR,SHL,SHR,IDXW
            da    BRGT,BRLT,INCBRLE,ADDBRLE,DECBRGE,SUBBRGE
            da    BRAND,BROR
            da    ADDLB,ADDLW,ADDAB,ADDAW,IDXLB,IDXLW,IDXAB
            da    IDXAW
            da    NATV,JUMPZ,JUMP

* -- direct interpreter entry (return-address = bytecode-1) --
DINTRP      pla
            clc
            adc   #$01
            sta   IPL
            pla
            adc   #$00
            sta   IPH
            ldy   #$00
            jmp   FETCHOP

* -- indirect interpreter entry: caller's JSR is followed by a
* -- 2-byte bytecode address (the "def thunk" shape) --
IINTRP      pla
            sta   TMPL
            pla
            sta   TMPH
            ldy   #$02
            lda   (TMP),y
            sta   IPH
            dey
            lda   (TMP),y
            sta   IPL
            dey
            jmp   FETCHOP

*---------------------------------------------------------------
* INNERTMP -- the page-0 bytecode inner loop, copied VERBATIM
* (as data) to $EF at START. Self-modifying by design: STA
* OPIDX's own zero-page operand ($F7) and JMP (OPTBL)'s own
* literal operand bytes ($F7/$F8) are the SAME two cells, so
* writing the fetched opcode into OPIDX changes the JMP-
* indirect instruction's own low operand byte, dispatching
* through OPTBL+opcode. Emitted as literal bytes (not `inx`/
* `iny`/etc mnemonics assembled here) because this block's
* REAL home is $EF, not wherever it lands in this image --
* merlin32 would compute branch/operand bytes for the WRONG
* origin if assembled as code at this address.
*   $EF inx        ; DROP
*   $F0 iny        ; NEXTOP
*   $F1 lda $FFFF,y ; FETCHOP; operand ($F2/$F3) = IP/IPL/IPH
*   $F4 sta $F7     ; STA OPIDX
*   $F6 jmp ($0900) ; operand ($F7/$F8) = OPIDX/OPPAGE
*---------------------------------------------------------------
INNERTMP    dfb   $E8,$C8,$B9,$FF,$FF,$85,$F7,$6C,$00,$09
TMPLEN      equ   *-INNERTMP

*---------------------------------------------------------------
* ADD/SUB/IDXW -- TOS/TOS-1 arithmetic (plvm02.s 306-341)
*---------------------------------------------------------------
ADD         lda   ESTKL,x
            clc
            adc   ESTKL+1,x
            sta   ESTKL+1,x
            lda   ESTKH,x
            adc   ESTKH+1,x
            sta   ESTKH+1,x
            jmp   DROP

SUB         lda   ESTKL+1,x
            sec
            sbc   ESTKL,x
            sta   ESTKL+1,x
            lda   ESTKH+1,x
            sbc   ESTKH,x
            sta   ESTKH+1,x
            jmp   DROP

IDXW        lda   ESTKL,x
            asl
            rol   ESTKH,x
            clc
            adc   ESTKL+1,x
            sta   ESTKL+1,x
            lda   ESTKH,x
            adc   ESTKH+1,x
            sta   ESTKH+1,x
            jmp   DROP

*---------------------------------------------------------------
* MUL -- TOS-1 *= TOS (plvm02.s 344-391)
*---------------------------------------------------------------
MUL         sty   IPY
            lda   ESTKH,x
            cmp   ESTKH+1,x
            bcs   :MULSW
            tay                     ;swap multiplr/multiplicand
            lda   ESTKH+1,x         ;so multiplier is smaller
            sta   ESTKH,x
            sty   ESTKH+1,x
            ldy   ESTKL,x
            lda   ESTKL+1,x
            sta   ESTKL,x
            sty   ESTKL+1,x
:MULSW      lda   ESTKL+1,x
            eor   #$FF
            sta   TMPL
            lda   #$00
            sta   ESTKL+1,x         ;prodl
            ldy   #$08
:MULLPL     lsr   TMPL              ;~multplrl
            bcs   :MULA
            sta   TMPH              ;prodh
            lda   ESTKL+1,x         ;prodl
            adc   ESTKL,x           ;+multplndl
            sta   ESTKL+1,x         ;=prodl
            lda   TMPH              ;prodh
            adc   ESTKH,x           ;+multplndh
:MULA       asl   ESTKL,x           ;multplndl
            rol   ESTKH,x           ;multplndh
            dey
            bne   :MULLPL
            beq   :MULC
:MULLPH     clc
            tay                     ;prodh
            lda   ESTKL+1,x         ;prodl
            adc   ESTKL,x           ;+multplndl
            sta   ESTKL+1,x         ;=prodl
            tya                     ;prodh
            adc   ESTKH,x           ;+multplndh
:MULB       asl   ESTKL,x           ;multplndl
            rol   ESTKH,x           ;multplndh
:MULC       lsr   ESTKH+1,x         ;multplrh
            bcs   :MULLPH
            bne   :MULB
            sta   ESTKH+1,x         ;prodh
            ldy   IPY
            jmp   DROP

*---------------------------------------------------------------
* L_DNEG/L_DIVCORE -- shared division primitive (plvm02.s
* 395-444). L_DIVCORE leaves the remainder in TMPL/TMPH and the
* quotient's sign parity in DVSIGN; DIV/MOD/DIVMOD below finish
* the job. Global labels (L_ prefix, with L_LARENRM/L_MINUS1B
* here and L_LLARENRM/L_SABRENRM in plasmals.s): a :local
* referenced from another global's zone is "Unknown label" on
* real Merlin-8; merlin32 resolves it by whole-file uniqueness.
*---------------------------------------------------------------
L_DNEG       lda   #$00
            sec
            sbc   ESTKL,x
            sta   ESTKL,x
            lda   #$00
            sbc   ESTKH,x
            sta   ESTKH,x
            rts
L_DIVCORE    sty   IPY
            ldy   #$11              ;#bits+1
            lda   #$00
            sta   TMPL              ;remndrl
            sta   TMPH              ;remndrh
            sta   DVSIGN
            lda   ESTKH+1,x
            bpl   :DIVA
            inx
            jsr   L_DNEG
            dex
            lda   #$81
            sta   DVSIGN
:DIVA       ora   ESTKL+1,x         ;dvdndl
            beq   :DIVEX
            lda   ESTKH,x
            bpl   :DIV1
            jsr   L_DNEG
            inc   DVSIGN
:DIV1       asl   ESTKL+1,x         ;dvdndl
            rol   ESTKH+1,x         ;dvdndh
            dey
            bcc   :DIV1
:DIVLP      rol   TMPL              ;remndrl
            rol   TMPH              ;remndrh
            lda   TMPL              ;remndrl
            cmp   ESTKL,x           ;dvsrl
            lda   TMPH              ;remndrh
            sbc   ESTKH,x           ;dvsrh
            bcc   :DIVB
            sta   TMPH              ;remndrh
            lda   TMPL              ;remndrl
            sbc   ESTKL,x           ;dvsrl
            sta   TMPL              ;remndrl
            sec
:DIVB       rol   ESTKL+1,x         ;dvdndl
            rol   ESTKH+1,x         ;dvdndh
            dey
            bne   :DIVLP
:DIVEX      inx
            ldy   IPY
            rts

*---------------------------------------------------------------
* NEG/DIV/MOD/DIVMOD (plvm02.s 446-488)
*---------------------------------------------------------------
NEG         lda   #$00
            sec
            sbc   ESTKL,x
            sta   ESTKL,x
            lda   #$00
            sbc   ESTKH,x
            sta   ESTKH,x
            jmp   NEXTOP

DIV         jsr   L_DIVCORE
            lsr   DVSIGN            ;sign(result)=sign(dividend)
            bcs   NEG               ; +sign(divisor), bit 0
            jmp   NEXTOP

MOD         jsr   L_DIVCORE
            lda   TMPL
            sta   ESTKL,x
            lda   TMPH
            sta   ESTKH,x
            lda   DVSIGN            ;remainder=sign of dividend
            bmi   NEG
            jmp   NEXTOP

DIVMOD      jsr   L_DIVCORE
            lsr   DVSIGN
            bcc   :DMFIX
            jsr   L_DNEG
:DMFIX      dex
            lda   TMPL
            sta   ESTKL,x
            lda   TMPH
            sta   ESTKH,x
            asl   DVSIGN            ;remainder=sign of dividend
            bmi   NEG
            jmp   NEXTOP

*---------------------------------------------------------------
* INCR/DECR/COMP/BAND/IOR/XOR (plvm02.s 490-546)
*---------------------------------------------------------------
INCR        inc   ESTKL,x
            beq   :INCRHI
            jmp   NEXTOP
:INCRHI     inc   ESTKH,x
            jmp   NEXTOP

DECR        lda   ESTKL,x
            beq   :DECRHI
            dec   ESTKL,x
            jmp   NEXTOP
:DECRHI     dec   ESTKL,x
            dec   ESTKH,x
            jmp   NEXTOP

COMP        lda   #$FF
            eor   ESTKL,x
            sta   ESTKL,x
            lda   #$FF
            eor   ESTKH,x
            sta   ESTKH,x
            jmp   NEXTOP

BAND        lda   ESTKL+1,x
            and   ESTKL,x
            sta   ESTKL+1,x
            lda   ESTKH+1,x
            and   ESTKH,x
            sta   ESTKH+1,x
            jmp   DROP

IOR         lda   ESTKL+1,x
            ora   ESTKL,x
            sta   ESTKL+1,x
            lda   ESTKH+1,x
            ora   ESTKH,x
            sta   ESTKH+1,x
            jmp   DROP

XOR         lda   ESTKL+1,x
            eor   ESTKL,x
            sta   ESTKL+1,x
            lda   ESTKH+1,x
            eor   ESTKH,x
            sta   ESTKH+1,x
            jmp   DROP

*---------------------------------------------------------------
* SHL/SHR (plvm02.s 548-595)
*---------------------------------------------------------------
SHL         sty   IPY
            lda   ESTKL,x
            cmp   #$08
            bcc   :SHLA
            ldy   ESTKL+1,x
            sty   ESTKH+1,x
            ldy   #$00
            sty   ESTKL+1,x
            sbc   #$08
:SHLA       tay
            beq   :SHLC
            lda   ESTKL+1,x
:SHLB       asl
            rol   ESTKH+1,x
            dey
            bne   :SHLB
            sta   ESTKL+1,x
:SHLC       ldy   IPY
            jmp   DROP

SHR         sty   IPY
            lda   ESTKL,x
            cmp   #$08
            bcc   :SHRB
            ldy   ESTKH+1,x
            sty   ESTKL+1,x
            cpy   #$80
            ldy   #$00
            bcc   :SHRA
            dey
:SHRA       sty   ESTKH+1,x
            sec
            sbc   #$08
:SHRB       tay
            beq   :SHRC
            lda   ESTKH+1,x
:SHRD       cmp   #$80
            ror
            ror   ESTKL+1,x
            dey
            bne   :SHRD
            sta   ESTKH+1,x
:SHRC       ldy   IPY
            jmp   DROP

*---------------------------------------------------------------
* DUP/ADDI/SUBI/ANDI/ORI (plvm02.s 597-644)
*---------------------------------------------------------------
DUP         dex
            lda   ESTKL+1,x
            sta   ESTKL,x
            lda   ESTKH+1,x
            sta   ESTKH,x
            jmp   NEXTOP

ADDI        iny                     ;+inc_ip
            lda   (IP),y
            clc
            adc   ESTKL,x
            sta   ESTKL,x
            bcc   :ADDIX
            inc   ESTKH,x
:ADDIX      jmp   NEXTOP

SUBI        iny                     ;+inc_ip
            lda   ESTKL,x
            sec
            sbc   (IP),y
            sta   ESTKL,x
            bcs   :SUBIX
            dec   ESTKH,x
:SUBIX      jmp   NEXTOP

ANDI        iny                     ;+inc_ip
            lda   (IP),y
            and   ESTKL,x
            sta   ESTKL,x
            lda   #$00
            sta   ESTKH,x
            jmp   NEXTOP

ORI         iny                     ;+inc_ip
            lda   (IP),y
            ora   ESTKL,x
            sta   ESTKL,x
            jmp   NEXTOP

*---------------------------------------------------------------
* LNOT/MINUS1/ZERO/CN/CB/CFFB (plvm02.s 646-686). LNOT's BEQ
* falls into MINUS1's own body ($FF fill) -- reused verbatim,
* not a coincidence in the original either.
*---------------------------------------------------------------
LNOT        lda   ESTKL,x
            ora   ESTKH,x
            beq   L_MINUS1B
            lda   #$00
            sta   ESTKL,x
            sta   ESTKH,x
            jmp   NEXTOP

MINUS1      dex
L_MINUS1B    lda   #$FF
            sta   ESTKL,x
            sta   ESTKH,x
            jmp   NEXTOP

ZERO        dex
            sta   ESTKL,x
            sta   ESTKH,x
            jmp   NEXTOP

CN          dex
            lsr                     ;a = const*2
            sta   ESTKL,x
            lda   #$00
            sta   ESTKH,x
            jmp   NEXTOP

CB          dex
            lda   #$00
            sta   ESTKH,x
            iny                     ;+inc_ip
            lda   (IP),y
            sta   ESTKL,x
            jmp   NEXTOP

CFFB        dex
            lda   #$FF
            sta   ESTKH,x
            iny                     ;+inc_ip
            lda   (IP),y
            sta   ESTKL,x
            jmp   NEXTOP

*---------------------------------------------------------------
* LA/CW/CS -- load address & constant word/string
* (plvm02.s 688-731)
*---------------------------------------------------------------
L_LARENRM    tya                     ;renormalize ip
            clc
            adc   IPL
            sta   IPL
            bcc   :LAY
            inc   IPH
:LAY        ldy   #$FF
LA          iny                     ;+inc_ip
            bmi   L_LARENRM
            dex
            lda   (IP),y
            sta   ESTKL,x
            iny
            lda   (IP),y
            sta   ESTKH,x
            jmp   NEXTOP

CW          dex
            iny                     ;+inc_ip
            lda   (IP),y
            sta   ESTKL,x
            iny
            lda   (IP),y
            sta   ESTKH,x
            jmp   NEXTOP

CS          dex
            tya                     ;normalize ip, save string
            sec                     ;addr on estk
            adc   IPL
            sta   IPL
            sta   ESTKL,x
            lda   #$00
            tay
            adc   IPH
            sta   IPH
            sta   ESTKH,x
            lda   (IP),y
            tay
            jmp   NEXTOP
