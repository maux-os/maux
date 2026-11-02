*---------------------------------------------------------------
* hello.s -- HELLO.SYSTEM, a ProDOS 8 program built on maux.
*
*   nas -o hello.o hello.s
*   ld -t FF -a 2000 -o HELLO.SYSTEM hello.o
*   bye HELLO.SYSTEM
*
* This knows nothing of maux. It calls the real ProDOS MLI at
* $BF00 and the monitor ROM's COUT, and runs on any ProDOS 8
* machine; `bye` suspends maux, runs it on a freshly booted
* ProDOS, and brings maux back when it QUITs. It writes a file,
* RESULT, so you can check from maux that it really ran.
*
* A SYSTEM file loads flat at $2000, so everything the program
* allocates above itself is its size limit. The MLI's 1 KB
* io_buffer goes at $9000, high and out of the way.
*
* Pathnames in raw MLI calls are plain 7-bit ASCII (single
* quotes). COUT wants the high bit set, so the message is stored
* as plain ASCII and the loop ORs HIBIT in as it prints.
*
* This file is staged on the release disk as MAUX TEXT (high
* bit set, lines ended by $8D), exactly what `vi` writes. nas
* reads that or ProDOS-standard text (low ASCII, $0D) alike, so
* edit it with `vi` and run `nas` on it: nothing to convert.
*---------------------------------------------------------------
            rel
            lst   off
TMLI        equ   $BF00
COUT        equ   $FDED
IOBUF       equ   $9000
STACKTOP    equ   $FF
HIBIT       equ   $80

START       ldx   #STACKTOP
            txs
            cld
            ldy   #0
:say        lda   MSG,y
            beq   :said
            ora   #HIBIT
            jsr   COUT
            iny
            bne   :say
:said       jsr   TMLI
            dfb   $C0              ;CREATE (fails if it exists)
            da    CRPARM
            jsr   TMLI
            dfb   $C8              ;OPEN
            da    OPPARM
            lda   OPREF
            sta   WRREF
            sta   CLREF
            jsr   TMLI
            dfb   $CB              ;WRITE
            da    WRPARM
            jsr   TMLI
            dfb   $CC              ;CLOSE
            da    CLPARM
            jsr   TMLI
            dfb   $65              ;QUIT: maux comes back
            da    QUPARM

CRPARM      dfb   7
            da    PATH
            dfb   $C3
            dfb   $04
            da    0
            dfb   1
            da    0
            da    0
OPPARM      dfb   3
            da    PATH
            da    IOBUF
OPREF       dfb   0
WRPARM      dfb   4
WRREF       dfb   0
            da    DATA
            da    6
            da    0
CLPARM      dfb   1
CLREF       dfb   0
QUPARM      dfb   4
            dfb   0
            da    0
            dfb   0
            da    0

PATH        dfb   12
            asc   '/MAUX/RESULT'
DATA        asc   'HELLO',0D
MSG         asc   'HELLO FROM PRODOS',0D,00
