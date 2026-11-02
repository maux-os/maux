*---------------------------------------------------------------
* byetenantd.s -- a `bye PATH.SYSTEM` tenant that DELETES the
* loop
* image (docs/LOOP-S2.md S4: "the tenant may have changed or
* deleted it"). A real ProDOS 8 .SYSTEM, org $2000, type $FF,
* the
* shape of byetenant.s: real MLI (`JSR $BF00`), plain 7-bit
* pathnames, ROM COUT. DESTROYs /HOST/LOOPD.PO -- which only
* works
* because `bye` closed the image and detached the loop first
* (an open file refuses DESTROY) -- prints the verdict, QUITs.
*---------------------------------------------------------------
            lst   off
            xc
            org   $2000
            dsk   ../../build/byetenantd.bin
            typ   $FF

TMLI        equ   $BF00
COUT        equ   $FDED
STACKTOP    equ   $FF

START       ldx   #STACKTOP
            txs
            cld
            jsr   TMLI
            dfb   $C1                      ;DESTROY
            da    DPARM
            bcs   :bad
            ldx   #0
            bra   :say
:bad        ldx   #MSGBAD-MSGOK
:say        lda   MSGOK,x
            beq   :quit
            ora   #$80
            jsr   COUT
            inx
            bra   :say
:quit       jsr   TMLI
            dfb   $65
            da    QUITPARM

DPARM       dfb   1
            da    DPATH
QUITPARM    dfb   4
            dfb   0
            da    0
            dfb   0
            da    0
DPATH       dfb   DEND-DPATH-1
            asc   '/HOST/LOOPD.PO'
DEND
MSGOK       asc   'TENANT DESTROYED'
            dfb   $0D,0
MSGBAD      asc   'TENANT DESTROY FAILED'
            dfb   $0D,0
