        org   $2000
        dsk   passone
        xc
BASE    equ   $40
Z       equ   BASE+1
VECTOR  equ   $3456
        dfb   <TAIL,>TAIL,"AB",'cd'
        da    TAIL+1,$abcd,"A"
        ddb   TAIL+2,$1234,'c'
        asc   "ab, cd",8D,00
        str   'xy,z',8D,00
        dci   "last",00
        dum   $80
TMP     ds    2
        dfb   TAIL+3,1+2
        asc   "sixchr"
        dend
        lda   TMP
        lda   Z
        lda   $ff
        lda   $100
        lda   $ff,x
        lda   $100,x
        ldx   $ff,y
        ldx   $100,y
        jmp   TARGET
        jsr   TARGET
        adc   $1234,y
        sty   $20,x
        stx   $21,y
        jmp   (VECTOR)
        jmp   (VECTOR,x)
        lda   #<TAIL
        bne   TARGET
TARGET  rts
TAIL    dfb   $aa
        err   */$BF00
