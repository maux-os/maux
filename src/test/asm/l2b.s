*---------------------------------------------------------------
* l2b.s -- nas L2 fixture: DUM/DEND, ERR, . ! & ops, DSK, TYP
* (task #21 gap batch). merlin32 is the oracle; nas's flat
* output must be byte-identical to build/l2b.bin.
*---------------------------------------------------------------
        dsk   l2b.bin
        typ   $00

        org   $2000

A       equ   $0F
B       equ   $F0
C       equ   $3C

START   lda   #A.B          ;OR -> #$FF
        sta   FOO
        lda   #2
        sta   BAR
        dfb   A.B            ;$FF
        dfb   A!$FF          ;$F0
        dfb   $0F.$F0&C      ;left-to-right -> $3C
        jmp   AFTER

        dum   $9000
FOO     ds    4
BAR     ds    2
BSSEND
        err   */$9010        ;satisfied: inside the arena
        dend

        err   BSSEND-$9006   ;satisfied: BSSEND == $9006

AFTER   lda   #3
        rts
