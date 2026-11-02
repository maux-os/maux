*---------------------------------------------------------------
* stress.s -- nas L1a stress fixture (docs/AS-PLASMA.md).
*
* Self-contained (ORG'd, no PUT/liba), deliberately >128 source
* lines and >32 symbols so a fixed-cap regression in nas's heap-
* backed source/symbol/line tables overflows visibly. Exercises:
*   - the full 6502 opcode set, every addressing mode (implied,
*     accumulator, immediate, zp, zp,X, zp,Y, abs, abs,X, abs,Y,
*     (zp,X), (zp),Y, relative);
*   - the 65C02 additions under XC ((zp), (abs,X), BRA, PHX/PLX/
*     PHY/PLY, STZ, TRB/TSB, INC A/DEC A, BIT #/zp,X/abs,X);
*   - the expression evaluator: + - * /, `<`/`>` byte selectors,
*     `#` immediate, "x"/'x' char constants (both bit convention
*     `*` (current line's address), and a forward-referencing EQ
*     chain (A depends on B, B defined later -- AS-PLASMA.md sec
*     `01M05519PC55WGJNE4PY5HX4TH`);
*   - every L1a data directive: DFB/DB, ASC, HEX, DCI, STR, DA/D
*     DDB, DS, plus a mixed quoted+numeric ASC/DFB list.
*
* merlin32 assembling this file is the oracle; nas's flat output
* must be byte-identical to build/stress.bin.
*---------------------------------------------------------------
            lst   off
            xc
            org   $2000
*
* ---- EQU chain: forward references, left-to-right expressions
*
BASE        equ   $2000
FWDA        equ   FWDB+1          ;forward-references FWDB (defi
FWDB        equ   5
SUM2        equ   10-3-2          ;left assoc: (10-3)-2 = 5
SUM3        equ   20/2/5          ;left assoc: (20/2)/5 = 2
SUM4        equ   $10-8
C_ONE       equ   1
C_TWO       equ   C_ONE+1
C_THREE     equ   C_TWO+1
C_FOUR      equ   C_THREE+1
C_FIVE      equ   C_FOUR+1
C_SIX       equ   C_FIVE+1
C_SEVEN     equ   C_SIX+1
C_EIGHT     equ   C_SEVEN+1
C_NINE      equ   C_EIGHT+1
C_TEN       equ   C_NINE+1
ZP1         equ   $10
ZP2         equ   $11
ZP3         equ   $12
ZP4         equ   $13
ZP5         equ   $14
ZP6         equ   $15
ZP7         equ   $16
ZP8         equ   $17
NBYTES      equ   3
WBASE       equ   $3000
CONST1      equ   $05
*
* ---- NMOS opcode / addressing-mode sweep ---------------------
*
START       lda   #CONST1         ;immediate
            adc   #$11
            adc   ZP1
            adc   ZP1,x
            adc   DATA1
            adc   DATA1,x
            adc   DATA1,y
            adc   (ZP1,x)
            adc   (ZP1),y
            and   #$0F
            and   ZP1
            and   ZP1,x
            and   DATA1
            and   DATA1,x
            and   DATA1,y
            and   (ZP1,x)
            and   (ZP1),y
            asl   a
            asl   ZP1
            asl   ZP1,x
            asl   DATA1
            asl   DATA1,x
            bcc   FWD1
            bcs   FWD1
            beq   FWD1
            bit   ZP1
            bit   DATA1
            bmi   FWD1
            bne   FWD1
            bpl   FWD1
FWD1        brk
            bvc   FWD1
            bvs   FWD1
            clc
            cld
            cli
            clv
            cmp   #$22
            cmp   ZP1
            cmp   ZP1,x
            cmp   DATA1
            cmp   DATA1,x
            cmp   DATA1,y
            cmp   (ZP1,x)
            cmp   (ZP1),y
            cpx   #$33
            cpx   ZP1
            cpx   DATA1
            cpy   #$44
            cpy   ZP1
            cpy   DATA1
            dec   ZP1
            dec   ZP1,x
            dec   DATA1
            dec   DATA1,x
            dex
            dey
            eor   #$55
            eor   ZP1
            eor   ZP1,x
            eor   DATA1
            eor   DATA1,x
            eor   DATA1,y
            eor   (ZP1,x)
            eor   (ZP1),y
            inc   ZP1
            inc   ZP1,x
            inc   DATA1
            inc   DATA1,x
            inx
            iny
            jmp   NEXT1
NEXT1       jmp   (INDVEC)
            jsr   SUBR1
            lda   ZP1
            lda   ZP1,x
            lda   DATA1
            lda   DATA1,x
            lda   DATA1,y
            lda   (ZP1,x)
            lda   (ZP1),y
            ldx   #$66
            ldx   ZP1
            ldx   ZP1,y
            ldx   DATA1
            ldx   DATA1,y
            ldy   #$77
            ldy   ZP1
            ldy   ZP1,x
            ldy   DATA1
            ldy   DATA1,x
            lsr   a
            lsr   ZP1
            lsr   ZP1,x
            lsr   DATA1
            lsr   DATA1,x
            nop
            ora   #$88
            ora   ZP1
            ora   ZP1,x
            ora   DATA1
            ora   DATA1,x
            ora   DATA1,y
            ora   (ZP1,x)
            ora   (ZP1),y
            pha
            php
            pla
            plp
            rol   a
            rol   ZP1
            rol   ZP1,x
            rol   DATA1
            rol   DATA1,x
            ror   a
            ror   ZP1
            ror   ZP1,x
            ror   DATA1
            ror   DATA1,x
            rti
SUBR1       sbc   #$99
            sbc   ZP1
            sbc   ZP1,x
            sbc   DATA1
            sbc   DATA1,x
            sbc   DATA1,y
            sbc   (ZP1,x)
            sbc   (ZP1),y
            sec
            sed
            sei
            sta   ZP1
            sta   ZP1,x
            sta   DATA1
            sta   DATA1,x
            sta   DATA1,y
            sta   (ZP1,x)
            sta   (ZP1),y
            stx   ZP1
            stx   ZP1,y
            stx   DATA1
            sty   ZP1
            sty   ZP1,x
            sty   DATA1
            tax
            tay
            tsx
            txa
            txs
            tya
            rts
*
* ---- 65C02 additions (gated by XC above) ---------------------
*
CMOS1       inc   a               ;65C02 accumulator inc/dec
            dec   a
            bra   CMOS1           ;backward branch, 65C02 BRA
            stz   ZP2
            stz   DATA1
            stz   ZP2,x
            stz   DATA1,x
            trb   ZP2
            trb   DATA1
            tsb   ZP2
            tsb   DATA1
            phx
            plx
            phy
            ply
            lda   (ZP2)           ;65C02 (zp)
            sta   (ZP2)
            adc   (ZP2)
            and   (ZP2)
            cmp   (ZP2)
            eor   (ZP2)
            ora   (ZP2)
            sbc   (ZP2)
            jmp   (INDVEC,x)      ;65C02 (abs,X) indirect JMP
            bit   #$0F            ;65C02 BIT immediate
            bit   ZP2,x
            bit   DATA1,x
            rts
*
* ---- char constants + `<`/`>` selectors on full expressions --
*
            lda   #"A"            ;high-bit char
            lda   #'A'            ;low-bit char
            lda   #"A"+1
            lda   #"A"+$80        ;silent wrap to low ASCII (mea
            lda   #<DATA1+2       ;low(DATA1+2), NOT low(DATA1)+
            lda   #>DATA1+2       ;high(DATA1+2)
            lda   #*+1            ;`*` = this line's own address
            lda   #FWDA           ;forward-referencing EQU chain
            lda   #SUM2           ;left assoc subtraction (=5)
            lda   #SUM3           ;left assoc division (=2)
            lda   #SUM4           ;($10-8=8)
            lda   #C_TEN          ;10-deep EQU-to-EQU chain (=10
EXTRA1      nop
EXTRA2      nop
EXTRA3      nop
EXTRA4      nop
            rts
*
* ---- data directives -----------------------------------------
*
DATA1       dfb   $11,$22,$33
*  operand expr: left-to-right = 20 (see task report -- EQU defi
*  measured to use normal algebraic precedence instead, unlike o
            dfb   2+3*4
            dfb   "AB",$00        ;quoted DFB item: only 'A' (me
            db    $44,$55         ;DB alias for DFB
            asc   "MAUX ALIVE"
            asc   'lower case'
            asc   "MLIVAL",$8D,$00
            asc   "A",'b',$41     ;mixed delimiters + raw byte
            hex   11,22,33
            hex   aabbccdd
            dci   "HELLO"
            dci   'hello'
            str   "HELLO"
            str   "AB",'cd'
            da    $1234,$5678
            dw    WBASE
            ddb   $1234
            ds    NBYTES
INDVEC      equ   $3000
            dfb   $00
ENDMARK     equ   *-START
            dfb   $00
