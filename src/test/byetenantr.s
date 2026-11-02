*---------------------------------------------------------------
* byetenantr.s -- a `bye PATH.SYSTEM` tenant that REWRITES a
* program (KFIX2 item 4, check-tenant). A real ProDOS 8 .SYSTEM,
* org $2000, type $FF, the shape of byetenant.s/byetenantd.s:
* real MLI (`JSR $BF00`), plain 7-bit pathnames. OPENs
* /MAUX/RWT, SET_EOFs it to 0, CLOSEs it (the close stamps a new
* mod time) and QUITs. Raw MLI calls like these never reach
* maux's PRC_WRITE/PRC_SETEOF/PRC_CREAT, so a program maux had
* run and retained is rewritten behind the kernel's back -- in
* the same minute, where the mtime compare is blind. Zero length
* is the rewrite because the spawn must then be REFUSED
* (ERR_NOEXEC): a retained image that survives the round trip
* would instead run, and print.
*---------------------------------------------------------------
            lst   off
            xc
            org   $2000
            dsk   ../../build/byetenantr.bin
            typ   $FF

TMLI        equ   $BF00
IOBUF       equ   $9000        ;1 KB io_buffer for the MLI
STACKTOP    equ   $FF

START       ldx   #STACKTOP
            txs
            cld
            jsr   TMLI
            dfb   $C8                      ;OPEN
            da    OPPARM
            lda   OP_REF
            sta   EOF_REF
            sta   CL_REF
            jsr   TMLI
            dfb   $D0                      ;SET_EOF
            da    EOFPARM
            jsr   TMLI
            dfb   $CC                      ;CLOSE
            da    CLPARM
            jsr   TMLI
            dfb   $65                      ;QUIT
            da    QUITPARM

OPPARM      dfb   3
            da    RPATH
            da    IOBUF
OP_REF      dfb   0
EOFPARM     dfb   2
EOF_REF     dfb   0
            dfb   0,0,0                    ;EOF = 0
CLPARM      dfb   1
CL_REF      dfb   0
QUITPARM    dfb   4
            dfb   0
            da    0
            dfb   0
            da    0
RPATH       dfb   REND-RPATH-1
            asc   '/MAUX/RWT'
REND
