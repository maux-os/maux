*---------------------------------------------------------------
* plasmals.s -- PLASMA VM load/store opcode handlers (LB/LW
* through DAW). Split out of plasmavm.s purely for the `as`
* source-window budget (top manifest + largest single put,
* scripts/strip_comments.py) -- plasmavm.s alone stripped to
* 20149 bytes, well over the 16128 ceiling; LB onward is a clean
* half-split. Ported verbatim from plvm02.s lines 733-1130;
* dialect syntax + unique :locals only, same as plasmavm.s.
* put by plasma.s after plasmavm.s.
*---------------------------------------------------------------

*---------------------------------------------------------------
* LB/LW -- load value from address tag (plvm02.s 733-754)
*---------------------------------------------------------------
LB          lda   ESTKL,x
            sta   ESTKH-1,x
            lda   (ESTKH-1,x)
            sta   ESTKL,x
            lda   #$00
            sta   ESTKH,x
            jmp   NEXTOP

LW          lda   ESTKL,x
            sta   ESTKH-1,x
            lda   (ESTKH-1,x)
            sta   ESTKL,x
            inc   ESTKH-1,x
            beq   :LWHI
            lda   (ESTKH-1,x)
            sta   ESTKH,x
            jmp   NEXTOP
:LWHI       inc   ESTKH,x
            lda   (ESTKH-1,x)
            sta   ESTKH,x
            jmp   NEXTOP

*---------------------------------------------------------------
* LLA/LLB/LLW -- local frame offset addr/load (plvm02.s 756-801)
*---------------------------------------------------------------
L_LLARENRM   tya                     ;renormalize ip
            clc
            adc   IPL
            sta   IPL
            bcc   :LLAY
            inc   IPH
:LLAY       ldy   #$FF
LLA         iny                     ;+inc_ip
            bmi   L_LLARENRM
            lda   (IP),y
            dex
            clc
            adc   IFPL
            sta   ESTKL,x
            lda   #$00
            adc   IFPH
            sta   ESTKH,x
            jmp   NEXTOP

LLB         iny                     ;+inc_ip
            lda   (IP),y
            sty   IPY
            tay
            dex
            lda   (IFP),y
            sta   ESTKL,x
            lda   #$00
            sta   ESTKH,x
            ldy   IPY
            jmp   NEXTOP

LLW         iny                     ;+inc_ip
            lda   (IP),y
            sty   IPY
            tay
            dex
            lda   (IFP),y
            sta   ESTKL,x
            iny
            lda   (IFP),y
            sta   ESTKH,x
            ldy   IPY
            jmp   NEXTOP

*---------------------------------------------------------------
* ADDLB/ADDLW/IDXLB/IDXLW -- local frame add/index
* (plvm02.s 803-870)
*---------------------------------------------------------------
ADDLB       iny                     ;+inc_ip
            lda   (IP),y
            sty   IPY
            tay
            lda   (IFP),y
            clc
            adc   ESTKL,x
            sta   ESTKL,x
            bcc   :ADDLBX
            inc   ESTKH,x
:ADDLBX     ldy   IPY
            jmp   NEXTOP

ADDLW       iny                     ;+inc_ip
            lda   (IP),y
            sty   IPY
            tay
            lda   (IFP),y
            clc
            adc   ESTKL,x
            sta   ESTKL,x
            iny
            lda   (IFP),y
            adc   ESTKH,x
            sta   ESTKH,x
            ldy   IPY
            jmp   NEXTOP

IDXLB       iny                     ;+inc_ip
            lda   (IP),y
            sty   IPY
            tay
            lda   (IFP),y
            ldy   #$00
            asl
            bcc   :IDXLBX
            iny
            clc
:IDXLBX     adc   ESTKL,x
            sta   ESTKL,x
            tya
            adc   ESTKH,x
            sta   ESTKH,x
            ldy   IPY
            jmp   NEXTOP

IDXLW       iny                     ;+inc_ip
            lda   (IP),y
            sty   IPY
            tay
            lda   (IFP),y
            asl
            sta   TMPL
            iny
            lda   (IFP),y
            rol
            sta   TMPH
            lda   TMPL
            clc
            adc   ESTKL,x
            sta   ESTKL,x
            lda   TMPH
            adc   ESTKH,x
            sta   ESTKH,x
            ldy   IPY
            jmp   NEXTOP

*---------------------------------------------------------------
* LAB/LAW -- load value from absolute address (plvm02.s 872-901)
*---------------------------------------------------------------
LAB         iny                     ;+inc_ip
            lda   (IP),y
            sta   ESTKH-2,x
            iny                     ;+inc_ip
            lda   (IP),y
            sta   ESTKH-1,x
            lda   (ESTKH-2,x)
            dex
            sta   ESTKL,x
            lda   #$00
            sta   ESTKH,x
            jmp   NEXTOP

LAW         iny                     ;+inc_ip
            lda   (IP),y
            sta   TMPL
            iny                     ;+inc_ip
            lda   (IP),y
            sta   TMPH
            sty   IPY
            ldy   #$00
            lda   (TMP),y
            dex
            sta   ESTKL,x
            iny
            lda   (TMP),y
            sta   ESTKH,x
            ldy   IPY
            jmp   NEXTOP

*---------------------------------------------------------------
* ADDAB/ADDAW/IDXAB/IDXAW -- absolute add/index (plvm02.s 903+)
*---------------------------------------------------------------
ADDAB       iny                     ;+inc_ip
            lda   (IP),y
            sta   ESTKH-2,x
            iny                     ;+inc_ip
            lda   (IP),y
            sta   ESTKH-1,x
            lda   (ESTKH-2,x)
            clc
            adc   ESTKL,x
            sta   ESTKL,x
            bcc   :ADDABX
            inc   ESTKH,x
:ADDABX     jmp   NEXTOP

ADDAW       iny                     ;+inc_ip
            lda   (IP),y
            sta   SRCL
            iny                     ;+inc_ip
            lda   (IP),y
            sta   SRCH
            sty   IPY
            ldy   #$00
            lda   (SRC),y
            clc
            adc   ESTKL,x
            sta   ESTKL,x
            iny
            lda   (SRC),y
            adc   ESTKH,x
            sta   ESTKH,x
            ldy   IPY
            jmp   NEXTOP

IDXAB       iny                     ;+inc_ip
            lda   (IP),y
            sta   ESTKH-2,x
            iny                     ;+inc_ip
            lda   (IP),y
            sta   ESTKH-1,x
            lda   (ESTKH-2,x)
            sty   IPY
            ldy   #$00
            asl
            bcc   :IDXABX
            iny
            clc
:IDXABX     adc   ESTKL,x
            sta   ESTKL,x
            tya
            adc   ESTKH,x
            sta   ESTKH,x
            ldy   IPY
            jmp   NEXTOP

IDXAW       iny                     ;+inc_ip
            lda   (IP),y
            sta   SRCL
            iny                     ;+inc_ip
            lda   (IP),y
            sta   SRCH
            sty   IPY
            ldy   #$00
            lda   (SRC),y
            asl
            sta   TMPL
            iny
            lda   (SRC),y
            rol
            sta   TMPH
            lda   TMPL
            clc
            adc   ESTKL,x
            sta   ESTKL,x
            lda   TMPH
            adc   ESTKH,x
            sta   ESTKH,x
            ldy   IPY
            jmp   NEXTOP

*---------------------------------------------------------------
* SB/SW/DROP2 -- store value to address (plvm02.s 984-1008)
*---------------------------------------------------------------
SB          lda   ESTKL,x
            sta   ESTKH-1,x
            lda   ESTKL+1,x
            sta   (ESTKH-1,x)
            inx
            jmp   DROP

SW          lda   ESTKL,x
            sta   ESTKH-1,x
            lda   ESTKL+1,x
            sta   (ESTKH-1,x)
            lda   ESTKH+1,x
            inc   ESTKH-1,x
            beq   :SWHI
            sta   (ESTKH-1,x)
            inx
            jmp   DROP
:SWHI       inc   ESTKH,x
            sta   (ESTKH-1,x)
* -- falls through to DROP2 --
DROP2       inx
            jmp   DROP

*---------------------------------------------------------------
* SLB/SLW/FIXDROP -- store to local frame offset (1010-1040)
* FIXDROP is a GLOBAL (SAW below jumps to it too).
*---------------------------------------------------------------
SLB         iny                     ;+inc_ip
            lda   (IP),y
            sty   IPY
            tay
            lda   ESTKL,x
            sta   (IFP),y
            ldy   IPY
            bmi   FIXDROP
            jmp   DROP

SLW         iny                     ;+inc_ip
            lda   (IP),y
            sty   IPY
            tay
            lda   ESTKL,x
            sta   (IFP),y
            iny
            lda   ESTKH,x
            sta   (IFP),y
            ldy   IPY
            bmi   FIXDROP
            jmp   DROP

FIXDROP     tya
            ldy   #$00
            clc
            adc   IPL
            sta   IPL
            bcc   :FIXDX
            inc   IPH
:FIXDX      jmp   DROP

*---------------------------------------------------------------
* DLB/DLW -- store to local frame offset, no pop (1042-1064)
*---------------------------------------------------------------
DLB         iny                     ;+inc_ip
            lda   (IP),y
            sty   IPY
            tay
            lda   ESTKL,x
            sta   (IFP),y
            lda   #$00
            sta   ESTKH,x
            ldy   IPY
            jmp   NEXTOP

DLW         iny                     ;+inc_ip
            lda   (IP),y
            sty   IPY
            tay
            lda   ESTKL,x
            sta   (IFP),y
            iny
            lda   ESTKH,x
            sta   (IFP),y
            ldy   IPY
            jmp   NEXTOP

*---------------------------------------------------------------
* SAB/SAW/DAB/DAW -- store to absolute address (1066-1130)
*---------------------------------------------------------------
L_SABRENRM   tya                     ;renormalize ip
            clc
            adc   IPL
            sta   IPL
            bcc   :SABY
            inc   IPH
:SABY       ldy   #$FF
SAB         iny                     ;+inc_ip
            bmi   L_SABRENRM
            lda   (IP),y
            sta   ESTKH-2,x
            iny                     ;+inc_ip
            lda   (IP),y
            sta   ESTKH-1,x
            lda   ESTKL,x
            sta   (ESTKH-2,x)
            jmp   DROP

SAW         iny                     ;+inc_ip
            lda   (IP),y
            sta   TMPL
            iny                     ;+inc_ip
            lda   (IP),y
            sta   TMPH
            sty   IPY
            ldy   #$00
            lda   ESTKL,x
            sta   (TMP),y
            iny
            lda   ESTKH,x
            sta   (TMP),y
            ldy   IPY
            bmi   :SAWX
            jmp   DROP
:SAWX       jmp   FIXDROP

DAB         iny                     ;+inc_ip
            lda   (IP),y
            sta   ESTKH-2,x
            iny                     ;+inc_ip
            lda   (IP),y
            sta   ESTKH-1,x
            lda   ESTKL,x
            sta   (ESTKH-2,x)
            lda   #$00
            sta   ESTKH,x
            jmp   NEXTOP

DAW         iny                     ;+inc_ip
            lda   (IP),y
            sta   TMPL
            iny                     ;+inc_ip
            lda   (IP),y
            sta   TMPH
            sty   IPY
            ldy   #$00
            lda   ESTKL,x
            sta   (TMP),y
            iny
            lda   ESTKH,x
            sta   (TMP),y
            ldy   IPY
            jmp   NEXTOP
