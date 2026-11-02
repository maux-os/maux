*---------------------------------------------------------------
* mlival.s -- a PORTABLE ProDOS 8 MLI validator .SYSTEM.
*
* It speaks ONLY the genuine ProDOS 8 MLI (JSR $BF00 with an
* inline command byte and a parmlist pointer) and the monitor's
* COUT/CROUT/PRBYTE -- nothing maux- or proshim-specific -- so
* the SAME binary runs under REAL ProDOS and under proshim, and
* its transcript must come out BYTE-IDENTICAL. That differential
* is what turns proshim's MLI shim from "agrees with a fixture I
* also wrote" into "reproduces real ProDOS" (scripts/
* check_mlival.py; docs/EDASM-SHIM.md).
*
* Determinism rules, so the two runs cannot legitimately differ:
*  - print only ERROR CODES, BYTE COUNTS, the file TYPE we
*    created, and MARK positions -- never a date, MACHID,
*    blocks_used, a prefix string or a volume name (all of
*    which differ between a real machine and the shim).
*  - RELATIVE names (MLIVAL.T1): both images boot with the
*    prefix on the volume root, and a ProDOS program under
*    proshim speaks ProDOS names, which the virtual root
*    (docs/VROOT.md) does not map - a relative one needs no map.
*  - DESTROY the scratch files first (ignoring the error) so a
*    re-run on a write-through image is idempotent.
*  - exercise only the calls maux actually backs: CREATE, OPEN,
*    WRITE, READ, SET_MARK, GET_MARK, SET_EOF, GET_EOF,
*    GET_FILE_INFO, RENAME, CLOSE, DESTROY, NEWLINE. NO ON_LINE
*    (unwired), NO GET_TIME (its value is a clock, not a file
*    fact), NO ALLOC_INTERRUPT (a real call, not a refusal).
*  - end with "DONE" then spin, so the screen is stable to
*    capture under either environment (QUIT is proshim-specific
*    behaviour the toy covers; a real-ProDOS QUIT would clear
*    the glass before capture).
*
* No zero page beyond the monitor's own CSW path; PRINT and the
* buffer dump patch their own absolute operands (this is RAM).
*---------------------------------------------------------------
            lst   off
            xc
            org   $2000
            dsk   ../../build/mlival.bin
            typ   $FF

VMLI         equ   $BF00
HOME        equ   $FC58
COUT        equ   $FDED
CROUT       equ   $FD8E
PRBYTE      equ   $FDDA

START       jsr   HOME           ;clear (real ProDOS splash);
                                 ;a no-op stub under proshim
            jsr   PRINT
            asc   "MLIVAL",8D,00

* -- idempotent: destroy both scratch files, ignore any error --
            jsr   VMLI
            dfb   $C1
            da    DS1PARM
            jsr   VMLI
            dfb   $C1
            da    DS2PARM

* -- CREATE MLIVAL.T1, type $04 (TXT) --
            jsr   VMLI
            dfb   $C0
            da    CRPARM
            jsr   PRINT
            asc   "CREATE ",00
            jsr   PRCODE
* -- OPEN it --
            jsr   VMLI
            dfb   $C8
            da    OPPARM
            jsr   PRINT
            asc   "OPEN ",00
            jsr   PRCODE
            lda   OP_REF
            sta   WR_REF
            sta   RD_REF
            sta   NL_REF
            sta   MK_REF
            sta   EF_REF
            sta   CL_REF
* -- WRITE 17 bytes, print the transferred count --
            jsr   VMLI
            dfb   $CB
            da    WRPARM
            jsr   PRINT
            asc   "WRITE ",00
            jsr   PRCODE2
            lda   WR_TRANS
            jsr   PRBYTE
            jsr   CROUT
* -- GET_EOF, print the 3-byte length (00 00 11) --
            jsr   VMLI
            dfb   $D1
            da    EFPARM
            jsr   PRINT
            asc   "GETEOF ",00
            jsr   PRCODE2
            jsr   PR3
            jsr   CROUT
* -- SET_MARK to $000006, then GET_MARK it back --
            lda   #6
            sta   MK_POS
            lda   #0
            sta   MK_POS+1
            sta   MK_POS+2
            jsr   VMLI
            dfb   $CE
            da    MKPARM
            jsr   PRINT
            asc   "SETMARK ",00
            jsr   PRCODE
            jsr   VMLI
            dfb   $CF
            da    MKPARM
            jsr   PRINT
            asc   "GETMARK ",00
            jsr   PRCODE2
            lda   MK_POS
            jsr   PRBYTE
            jsr   CROUT
* -- plain READ 4 bytes from mark 6 ("BETA") --
            lda   #4
            sta   RD_REQ
            lda   #0
            sta   RD_REQ+1
            jsr   VMLI
            dfb   $CA
            da    RDPARM
            jsr   PRINT
            asc   "READP ",00
            jsr   PRREAD
* -- NEWLINE mode on ($7F/$0D), rewind to 0, READ 64: stops
*    after the first CR ("ALPHA" + CR = 6) --
            lda   #$7F
            sta   NL_MASK
            jsr   VMLI
            dfb   $C9
            da    NLPARM
            jsr   PRINT
            asc   "NEWLINE ",00
            jsr   PRCODE
            lda   #0
            sta   MK_POS
            sta   MK_POS+1
            sta   MK_POS+2
            jsr   VMLI
            dfb   $CE
            da    MKPARM
            lda   #64
            sta   RD_REQ
            lda   #0
            sta   RD_REQ+1
            jsr   VMLI
            dfb   $CA
            da    RDPARM
            jsr   PRINT
            asc   "READNL ",00
            jsr   PRREAD
* -- NEWLINE off, read the rest plainly from where we are --
            lda   #0
            sta   NL_MASK
            jsr   VMLI
            dfb   $C9
            da    NLPARM
            jsr   VMLI
            dfb   $CA
            da    RDPARM
            jsr   PRINT
            asc   "READR ",00
            jsr   PRREAD
* -- CLOSE --
            jsr   VMLI
            dfb   $CC
            da    CLPARM
            jsr   PRINT
            asc   "CLOSE ",00
            jsr   PRCODE
* -- GET_FILE_INFO, print the file TYPE only ($04) --
            jsr   VMLI
            dfb   $C4
            da    GFPARM
            jsr   PRINT
            asc   "GFI ",00
            jsr   PRCODE2
            lda   GF_TYPE
            jsr   PRBYTE
            jsr   CROUT
* -- RENAME T1 -> T2 --
            jsr   VMLI
            dfb   $C2
            da    RNPARM
            jsr   PRINT
            asc   "RENAME ",00
            jsr   PRCODE
* -- GFI on T2 (now exists) and T1 (now gone: $46) --
            jsr   VMLI
            dfb   $C4
            da    GF2PARM
            jsr   PRINT
            asc   "GFIT2 ",00
            jsr   PRCODE
            jsr   VMLI
            dfb   $C4
            da    GFPARM
            jsr   PRINT
            asc   "GFIT1 ",00
            jsr   PRCODE
* -- DESTROY T2 --
            jsr   VMLI
            dfb   $C1
            da    DS2PARM
            jsr   PRINT
            asc   "DESTROY ",00
            jsr   PRCODE

            jsr   PRINT
            asc   "DONE",8D,00
:spin       jmp   :spin

*---------------------------------------------------------------
* PRCODE -- print the MLI result (saved by PRINT in PRSAVE) as
* two hex digits + CR.
PRCODE      lda   PRSAVE
            jsr   PRBYTE
            jmp   CROUT
* PRCODE2 -- same, then a trailing space (a field follows).
PRCODE2     lda   PRSAVE
            jsr   PRBYTE
            lda   #$A0
            jmp   COUT
* PRREAD -- "cc tt " then the bytes (CR shown "|") + CR.
PRREAD      lda   PRSAVE
            jsr   PRBYTE
            lda   #$A0
            jsr   COUT
            lda   RD_TRANS
            jsr   PRBYTE
            lda   #$A0
            jsr   COUT
            ldx   #0
:lp         cpx   RD_TRANS
            bcs   :done
            lda   RDBUF,x
            and   #$7F              ;data high-bit; fold
            cmp   #$0D
            bne   :ch
            lda   #"|"
:ch         ora   #$80
            jsr   COUT
            inx
            bne   :lp
:done       jmp   CROUT

* PR3 -- print the 3-byte GET_EOF result high-to-low.
PR3         lda   EF_EOF+2
            jsr   PRBYTE
            lda   EF_EOF+1
            jsr   PRBYTE
            lda   EF_EOF
            jmp   PRBYTE

* PRINT -- inline NUL-terminated string after the JSR. Preserves
* A (the MLI result), which PRCODE/PRCODE2/PRREAD then print.
PRINT       sta   PRSAVE
            pla
            sta   PRLD+1
            pla
            sta   PRLD+2
            ldy   #1
PRLD        lda   $FFFF,y
            beq   :end
            ora   #$80
            jsr   COUT
            iny
            bne   PRLD
:end        tya
            clc
            adc   PRLD+1
            sta   PRLD+1
            lda   PRLD+2
            adc   #0
            pha
            lda   PRLD+1
            pha
            lda   PRSAVE
            rts
PRSAVE      dfb   0

* -- parmlists --------------------------------------------
DS1PARM     dfb   1
            da    T1PATH
DS2PARM     dfb   1
            da    T2PATH
CRPARM      dfb   7
            da    T1PATH
            dfb   $C3            ;access = full
            dfb   $04            ;file_type = TXT
            da    0              ;aux_type
            dfb   1              ;storage_type = seedling
            da    0              ;create_date
            da    0              ;create_time
OPPARM      dfb   3
            da    T1PATH
            da    IOBUF
OP_REF      dfb   0
WRPARM      dfb   4
WR_REF      dfb   0
            da    WDATA
            da    WDATA_END-WDATA
WR_TRANS    da    0
RDPARM      dfb   4
RD_REF      dfb   0
            da    RDBUF
RD_REQ      da    0
RD_TRANS    da    0
EFPARM      dfb   2
EF_REF      dfb   0
EF_EOF      ds    3
MKPARM      dfb   2
MK_REF      dfb   0
MK_POS      ds    3
NLPARM      dfb   3
NL_REF      dfb   0
NL_MASK     dfb   $7F
            dfb   $0D
CLPARM      dfb   1
CL_REF      dfb   0
GFPARM      dfb   10
            da    T1PATH
GF_ACC      dfb   0
GF_TYPE     dfb   0
            ds    13
GF2PARM     dfb   10
            da    T2PATH
            ds    15
RNPARM      dfb   2
            da    T1PATH
            da    T2PATH

T1PATH      dfb   T1END-T1PATH-1
            asc   "MLIVAL.T1"
T1END
T2PATH      dfb   T2END-T2PATH-1
            asc   "MLIVAL.T2"
T2END
WDATA       asc   "ALPHA",8D,"BETA",8D,"GAMMA",8D
WDATA_END
IOBUF       equ   $1C00          ;1K VMLI io_buffer (real ProDOS
                                 ;uses it; the shim ignores it)
RDBUF       equ   $1000          ;64-byte read landing, below
                                 ;the image, clear of IOBUF)
