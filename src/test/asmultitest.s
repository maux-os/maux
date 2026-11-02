            org   $2000
START       lda   #$01
            sta   $2010
            ldx   #$00
:loop       inx
            cpx   #$05
            bne   :loop
            jmp   NEXT
NEXT        lda   DATA
            sta   $2011
            rts
DATA        dfb   $42
