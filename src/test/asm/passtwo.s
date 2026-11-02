            org   $2000
            ds    509
            lda   #$11
            lda   $1234
            ds    508
            lda   #$22
            ds    507
            lda   $2345
            nop
            ds    509
            lda   $3456
            str   "A,B",'cd',$00
            hex   0123,456789,abCDef
            dum   $80
TEMP        ds    1
            str   "DUMMY",$55
            hex   010203
            lda   TEMP
            dend
            str   "",'Z'
            hex   00,FF
BACK        nop
            bne   BACK
            rts
