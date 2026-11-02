            lst   off
            xc
            org   $FF00
            dsk   ld3.bin
MAST_LO     equ   $B400
IDX0_LO     equ   $B600
SLOT_LO     equ   $0E00
RAMRDMAIN   equ   $C002
RAMRDAUX    equ   $C003
BANKSEL     equ   $C073
F_SAVE      equ   $9000
F_REST      equ   $9010
F_ALIVE     equ   $9020

LD_ENTRY    lda   $42
            bne   :io
            ldx   LD_CNT
            ldy   LD_CNT+1
            lda   #0
            clc
            rts
:io         jsr   F_SAVE
            lda   $42
            cmp   #3
            bcs   :e27
            lda   $46
            cmp   LD_CNT
            lda   $47
            sbc   LD_CNT+1
            bcs   :e27
            jsr   F_ALIVE
            bcc   :live
            lda   #$28
            bra   :err
:e27        lda   #$27
:err        sec
            jmp   F_REST
:live       lda   $47
            beq   :i0
            cmp   LD_TAG
            beq   :slot
            tay
            php
            sei
            stz   BANKSEL
            sta   RAMRDAUX
            ldx   MAST_LO,y
            lda   MAST_LO+$100,y
            sta   RAMRDMAIN
            plp
            stx   $46
            sta   $47
            stz   $44
            lda   #>SLOT_LO
            sta   $45
            lda   #1
            sta   $42
            jsr   LD_HOSTC
            bcs   LD_X
            jsr   F_REST
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
            sta   RAMRDMAIN
            plp
:go         stx   $46
            sta   $47
            ora   $46
            beq   :e27
            jsr   LD_HOSTC
LD_X        jmp   F_REST
LD_HOSTC    lda   LD_HOST
            sta   $43
            jmp   (LD_HVEC)
LD_CNT      ds    2
LD_HOST     ds    1
LD_HVEC     ds    2
LD_TAG      ds    1
