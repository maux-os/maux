*---------------------------------------------------------------
* seekwr.s -- `make check-seek` gate, half 1: a REAL liba-linked
* userland program (not a raw $FF00 harness -- the point is to
* prove liba's own LSEEK, src/liba/seek.s, not a hand-rolled
* imitation of it) that exercises SEEK_SET/SEEK_CUR/SEEK_END and
* independently re-verifies each landing with a RAW SC_GETMARK
* call (bypassing LSEEK's own result copyback, which only echoes
* the value it INTENDED to set -- see this file's own comments
* below for why that distinction matters to the gate's teeth).
*
* Sequence on /mnt/MAUX/SEEKF (freshly CREATEd, so mark starts
* at
* 0):
*   WRITE "0123456789" (10 bytes)   -- mark now 10, EOF now 10
*   LSEEK(fd, 3, SEEK_SET)          -- expect mark  3
*   LSEEK(fd, 2, SEEK_CUR)          -- expect mark  5  (3+2)
*   LSEEK(fd, 0, SEEK_END)          -- expect mark 10  (EOF+0)
* Each landing is read back with an INDEPENDENT SC_GETMARK call
* (not LSEEK's own return) and the three 3-byte marks (9 bytes)
* plus a 1-byte error-flags summary are written to
* /mnt/MAUX/SEEKRES for src/test/seektest.s's parent process /
* scripts/check_seek.py to read back.
*---------------------------------------------------------------

            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/seekwr.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

PAYLOAD_LEN equ   10

START
* -- CREATE + OPEN /mnt/MAUX/SEEKF.
            lda   #<CRT_PARM
            ldx   #>CRT_PARM
            jsr   SC_CREAT
            bcc   :created          ;can't create -- nothing to
            jmp   :done             ;test, exit anyway (parent's
                                    ;read-back/step budget will
                                    ;show the miss) -- `jmp`,
                                    ;not `bcs`/`bra`: :done is
                                    ;too far to branch to here
:created    lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :opened
            jmp   :done
:opened     lda   OPARM_REF
            sta   WFD

* -- WRITE the 10-byte payload. Mark advances to 10 (== EOF)
* -- per the MLI's own WRITE contract (TRM ch. 4).
            lda   WFD
            sta   WPARM_REF
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            bcc   :wrote
            jmp   :done
:wrote

* -- LSEEK(fd, 3, SEEK_SET) -- expect mark 3.
            stz   OFFBUF
            stz   OFFBUF+1
            stz   OFFBUF+2
            lda   #3
            sta   OFFBUF
            lda   #<OFFBUF
            sta   PTR0
            lda   #>OFFBUF
            sta   PTR0+1
            lda   WFD
            ldy   #SEEK_SET
            jsr   LSEEK
            bcc   :setok
            lda   ERRFLAGS
            ora   #1
            sta   ERRFLAGS
:setok      jsr   RAW_GETMARK
            ldx   #0
            jsr   STASH_MARK

* -- LSEEK(fd, 2, SEEK_CUR) -- expect mark 5 (3+2).
            stz   OFFBUF+1
            stz   OFFBUF+2
            lda   #2
            sta   OFFBUF
            lda   #<OFFBUF
            sta   PTR0
            lda   #>OFFBUF
            sta   PTR0+1
            lda   WFD
            ldy   #SEEK_CUR
            jsr   LSEEK
            bcc   :curok
            lda   ERRFLAGS
            ora   #2
            sta   ERRFLAGS
:curok      jsr   RAW_GETMARK
            ldx   #3
            jsr   STASH_MARK

* -- LSEEK(fd, 0, SEEK_END) -- expect mark 10 (EOF+0).
            stz   OFFBUF
            stz   OFFBUF+1
            stz   OFFBUF+2
            lda   #<OFFBUF
            sta   PTR0
            lda   #>OFFBUF
            sta   PTR0+1
            lda   WFD
            ldy   #SEEK_END
            jsr   LSEEK
            bcc   :endok
            lda   ERRFLAGS
            ora   #4
            sta   ERRFLAGS
:endok      jsr   RAW_GETMARK
            ldx   #6
            jsr   STASH_MARK

            lda   WFD
            jsr   CLOSE_A

* -- Write RESULT (9 marks) + ERRFLAGS (1 byte) = 10 bytes to
* -- /mnt/MAUX/SEEKRES.
            lda   #<RCRT_PARM
            ldx   #>RCRT_PARM
            jsr   SC_CREAT
            bcs   :done
            lda   #<ROPARM
            ldx   #>ROPARM
            jsr   SC_OPEN
            bcs   :done
            lda   ROPARM_REF
            sta   RWPARM_REF
            lda   ERRFLAGS
            sta   RESULT+9
            lda   #<RWPARM
            ldx   #>RWPARM
            jsr   SC_WRITE
            lda   ROPARM_REF
            jsr   CLOSE_A

:done       lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* RAW_GETMARK -- independent SC_GETMARK call, bypassing LSEEK's
* own result copyback entirely (see file header: LSEEK's OUT
* value is an ECHO of what it asked SET_MARK to do, not a fresh
* read -- if SET_MARK silently drops the offset, LSEEK would
* still report the INTENDED mark. Only a real GET_MARK proves
* the mark actually landed). IN: WFD = fd. OUT: GMPARM_VAL[0..2]
* = the real mark. CLOBBERS: A, X.
*---------------------------------------------------------------
RAW_GETMARK lda   WFD
            sta   GMPARM_REF
            lda   #<GMPARM
            ldx   #>GMPARM
            jsr   SC_GETMARK
            rts

*---------------------------------------------------------------
* STASH_MARK -- copy GMPARM_VAL[0..2] into RESULT+X..X+2.
* IN: X = dest offset in RESULT. CLOBBERS: A, Y.
*---------------------------------------------------------------
STASH_MARK  ldy   #0
:cp         lda   GMPARM_VAL,y
            sta   RESULT,x
            inx
            iny
            cpy   #3
            bne   :cp
            rts

*---------------------------------------------------------------
* CLOSE_A -- IN: A = fd. CLOBBERS: A, X.
*---------------------------------------------------------------
CLOSE_A     sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            rts

WFD         ds    1
ERRFLAGS    dfb   0
OFFBUF      ds    3
RESULT      ds    10             ;3 marks x 3 bytes + errflags

PAYLOAD     asc   "0123456789"   ;10 bytes, high-bit-set liba
                                 ;string convention

CRT_PARM       dfb   PCOUNT_CREATE
CRT_PATH       da    SEEKF_PATH
CRT_ACCESS     dfb   ACCESS_UNLKD
CRT_FTYPE      dfb   FTYPE_BIN
CRT_AUXTYP     da    0
CRT_STYPE      dfb   STYP_SEEDLING
CRT_CDATE      da    0
CRT_CTIME      da    0

OPARM       dfb   PCOUNT_OPEN
OPARM_PATH  da    SEEKF_PATH
OPARM_IOBUF da    $0000
OPARM_REF   dfb   0

WPARM       dfb   PCOUNT_WRITE
WPARM_REF   dfb   0
WPARM_BUF   da    PAYLOAD
WPARM_REQ   da    PAYLOAD_LEN
WPARM_TRN   da    0

GMPARM      dfb   2
GMPARM_REF  dfb   0
GMPARM_VAL  dfb   0,0,0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0

SEEKF_PATH  dfb   15
            asc   "/mnt/MAUX/SEEKF"

RCRT_PARM      dfb   PCOUNT_CREATE
RCRT_PATH      da    RESPATH
RCRT_ACCESS    dfb   ACCESS_UNLKD
RCRT_FTYPE     dfb   FTYPE_BIN
RCRT_AUXTYP    da    0
RCRT_STYPE     dfb   STYP_SEEDLING
RCRT_CDATE     da    0
RCRT_CTIME     da    0

ROPARM      dfb   PCOUNT_OPEN
ROPARM_PATH da    RESPATH
ROPARM_IOBF da    $0000
ROPARM_REF  dfb   0

RWPARM      dfb   PCOUNT_WRITE
RWPARM_REF  dfb   0
RWPARM_BUF  da    RESULT
RWPARM_REQ  da    10
RWPARM_TRN  da    0

RESPATH     dfb   17
            asc   "/mnt/MAUX/SEEKRES"

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/seek.s
            put   ../liba/libabss.s
