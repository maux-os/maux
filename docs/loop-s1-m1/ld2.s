            lst   off
            xc
            org   $FF00
            dsk   ld2.bin
MAST_LO     equ   $1400
IDX0_LO     equ   $1600
SLOT_LO     equ   $0E00
RAMRDMAIN   equ   $C002
RAMRDAUX    equ   $C003
BANKSEL     equ   $C073
DEVCNT      equ   $BF31
DEVLST      equ   $BF32

LD_ENTRY    lda   $42
            bne   :io
            ldx   LD_CNT
            ldy   LD_CNT+1
            lda   #0
            clc
            rts
:io         ldx   #5
:sv         lda   $42,x
            sta   LD_SV,x
            dex
            bpl   :sv
            lda   $42
            cmp   #3
            bcs   :e27
            lda   $46
            cmp   LD_CNT
            lda   $47
            sbc   LD_CNT+1
            bcs   :e27
            ldx   DEVCNT
:al         lda   DEVLST,x
            and   #$F0
            cmp   LD_HOST
            beq   :live
            dex
            bpl   :al
            lda   #$28
            bra   :err
:e27        lda   #$27
:err        sec
LD_REST     tay
            ldx   #5
:rs         lda   LD_SV,x
            sta   $42,x
            dex
            bpl   :rs
            tya
            rts
:live       lda   $47
            beq   :i0
            cmp   LD_TAG
            beq   :slot
            tay
            ldx   MAST_LO,y
            lda   MAST_LO+$100,y
            stx   $46
            sta   $47
            stz   $44
            lda   #>SLOT_LO
            sta   $45
            lda   #1
            sta   $42
            jsr   LD_HOSTC
            bcs   LD_REST
            jsr   LD_REST
            lda   $47
            sta   LD_TAG
:slot       ldy   $46
            ldx   SLOT_LO,y
            lda   SLOT_LO+$100,y
            bra   :go
:i0         php
            sei
            stz   BANKSEL
            sta   RAMRDAUX
            ldy   $46
            ldx   IDX0_LO,y
            lda   IDX0_LO+$100,y
:go         stx   $46
            sta   $47
            ora   $46
            beq   :e27
            jsr   LD_HOSTC
            bra   LD_REST
LD_HOSTC    lda   LD_HOST
            sta   $43
            jmp   (LD_HVEC)
LD_CNT      ds    2
LD_HOST     ds    1
LD_HVEC     ds    2
LD_TAG      ds    1
LD_SV       ds    6
