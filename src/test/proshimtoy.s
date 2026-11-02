*---------------------------------------------------------------
* proshimtoy.s -- a hand-written ProDOS 8 .SYSTEM program that
* exercises proshim's shim (TASKS.md #19 P1 gate, scripts/
* check_proshim.py). Assembled at $2000 like any system
* program, staged on the gate image as /mnt/MAUX/SHIM/TOY.SYSTEM
* (type $FF), run as `proshim /mnt/MAUX/shim/toy.system`.
*
* It speaks ONLY the ProDOS contract: `JSR $BF00` with inline
* command + parmlist, the monitor's COUT/CROUT/PRBYTE/GETLN1,
* and the global page.s MACHID. Every call prints its name and
* the returned error code in hex, so the transcript is the
* assertion. Sequence, with the expected line:
*   GET_TIME 00 / MACHID B0 / CREATE 00 / OPEN 00 / WRITE 00 11
*   CLOSE 00 / OPEN 00 / NEWLINE 00 / READ1 00 06 ALPHA| /
*   READ2 00 05 BETA| / NEWLINE 00 / READ3 00 06 GAMMA| /
*   EOF 00 11 / CLOSE 00 / GFI 00 04 / BAD 01 / BADCNT 04 /
*   DESTROY 00 / GONE 46 / PERSIST 00 / GOT: <line> / BYE
* then QUIT. READ1/READ2 prove NEWLINE mode (the file holds
* "ALPHA\rBETA\rGAMMA\r"); READ3 proves it switches off; BAD
* and BADCNT are the refusal branches; PERSIST leaves
* /mnt/MAUX/SHIM/T2 on the volume for a byte-level check.
*
* CR inside a read buffer prints as "|" so each line stays one
* screen row. No zero page; PRINT and the buffer dump patch
* their own absolute,Y operands (this is RAM at $2000).
*---------------------------------------------------------------
            lst   off
            xc
            org   $2000
            dsk   ../../build/proshim-toy.bin
            typ   $FF

TMLI         equ   $BF00
TMACHID      equ   $BF98
COUT        equ   $FDED
CROUT       equ   $FD8E
PRBYTE      equ   $FDDA
GETLN1      equ   $FD6F
INBUF       equ   $0200

START       jsr   PRINT
            asc   "PROSHIM TOY",8D,00
            jsr   TMLI
            dfb   $82
            da    NOPARM
            jsr   PRINT
            asc   "GET_TIME ",00
            jsr   PRCODE
            jsr   PRINT
            asc   "MACHID ",00
            lda   TMACHID
            jsr   PRBYTE
            jsr   CROUT

            jsr   TMLI
            dfb   $C0
            da    CRPARM
            jsr   PRINT
            asc   "CREATE ",00
            jsr   PRCODE
            jsr   TMLI
            dfb   $C8
            da    OPPARM
            jsr   PRINT
            asc   "OPEN ",00
            jsr   PRCODE
            lda   OP_REF
            sta   WR_REF
            sta   CL_REF
            jsr   TMLI
            dfb   $CB
            da    WRPARM
            jsr   PRINT
            asc   "WRITE ",00
            jsr   PRCODE2
            lda   WR_TRANS
            jsr   PRBYTE
            jsr   CROUT
            jsr   TMLI
            dfb   $CC
            da    CLPARM
            jsr   PRINT
            asc   "CLOSE ",00
            jsr   PRCODE

            jsr   TMLI
            dfb   $C8
            da    OPPARM
            jsr   PRINT
            asc   "OPEN ",00
            jsr   PRCODE
            lda   OP_REF
            sta   NL_REF
            sta   RD_REF
            sta   EF_REF
            sta   CL_REF
            lda   #$7F
            sta   NL_MASK
            jsr   TMLI
            dfb   $C9
            da    NLPARM
            jsr   PRINT
            asc   "NEWLINE ",00
            jsr   PRCODE
            jsr   TMLI
            dfb   $CA
            da    RDPARM
            jsr   PRINT
            asc   "READ1 ",00
            jsr   PRREAD
            jsr   TMLI
            dfb   $CA
            da    RDPARM
            jsr   PRINT
            asc   "READ2 ",00
            jsr   PRREAD
            lda   #0
            sta   NL_MASK
            jsr   TMLI
            dfb   $C9
            da    NLPARM
            jsr   PRINT
            asc   "NEWLINE ",00
            jsr   PRCODE
            jsr   TMLI
            dfb   $CA
            da    RDPARM
            jsr   PRINT
            asc   "READ3 ",00
            jsr   PRREAD
            jsr   TMLI
            dfb   $D1
            da    EFPARM
            jsr   PRINT
            asc   "EOF ",00
            jsr   PRCODE2
            lda   EF_EOF
            jsr   PRBYTE
            jsr   CROUT
            jsr   TMLI
            dfb   $CC
            da    CLPARM
            jsr   PRINT
            asc   "CLOSE ",00
            jsr   PRCODE

            jsr   TMLI
            dfb   $C4
            da    GFPARM
            jsr   PRINT
            asc   "GFI ",00
            jsr   PRCODE2
            lda   GF_TYPE
            jsr   PRBYTE
            jsr   CROUT
            jsr   TMLI
            dfb   $40                    ;ALLOC_INTERRUPT: below
            da    NOPARM                 ;the floor, refused
            jsr   PRINT
            asc   "BAD ",00
            jsr   PRCODE
            jsr   TMLI
            dfb   $C9
            da    NLBAD                  ;param_count 2
            jsr   PRINT
            asc   "BADCNT ",00
            jsr   PRCODE
            jsr   TMLI
            dfb   $C1
            da    DSPARM
            jsr   PRINT
            asc   "DESTROY ",00
            jsr   PRCODE
            jsr   TMLI
            dfb   $C4
            da    GFPARM
            jsr   PRINT
            asc   "GONE ",00
            jsr   PRCODE

            jsr   TMLI
            dfb   $C1                    ;DESTROY T2, ignore err
            da    DS2PARM                ;-> idempotent create
            jsr   TMLI
            dfb   $C0
            da    C2PARM
            bcs   :p2
            jsr   TMLI
            dfb   $C8
            da    O2PARM
            bcs   :p2
            lda   O2_REF
            sta   W2_REF
            sta   CL_REF
            jsr   TMLI
            dfb   $CB
            da    W2PARM
            bcs   :p2
            jsr   TMLI
            dfb   $CC
            da    CLPARM
:p2         jsr   PRINT
            asc   "PERSIST ",00
            jsr   PRCODE

            jsr   GETLN1
            jsr   PRINT
            asc   "GOT: ",00
            ldx   #0
:gl         lda   INBUF,x
            cmp   #$8D
            beq   :gd
            jsr   COUT
            inx
            bne   :gl
:gd         jsr   CROUT
            jsr   PRINT
            asc   "BYE",8D,00
            jsr   TMLI
            dfb   $65
            da    NOPARM
:hang       jmp   :hang

* PRCODE -- print the TMLI result in A as two hex digits + CR
PRCODE      jsr   PRBYTE
            jmp   CROUT
* PRCODE2 -- same, then a space (a second field follows)
PRCODE2     jsr   PRBYTE
            lda   #$A0
            jmp   COUT

* PRREAD -- after a READ: "cc tt " + buffer[0..trans) + CR,
* CR bytes shown as "|"
PRREAD      jsr   PRCODE2
            lda   RD_TRANS
            jsr   PRBYTE
            lda   #$A0
            jsr   COUT
            ldx   #0
:lp         cpx   RD_TRANS
            bcs   :done
            lda   RDBUF,x
            cmp   #$0D
            bne   :ch
            lda   #"|"
:ch         ora   #$80
            jsr   COUT
            inx
            bne   :lp
:done       jmp   CROUT

* PRINT -- inline NUL-terminated string after the JSR, high
* bit forced on the way out
PRINT       sta   PRSAVE                 ;save the MLI result
            pla                          ;caller prints next
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

NOPARM      dfb   0
CRPARM      dfb   7
            da    T1PATH
            dfb   $C3
            dfb   $04
            da    0
            dfb   1
            da    0
            da    0
OPPARM      dfb   3
            da    T1PATH
            da    $1C00
OP_REF      dfb   0
WRPARM      dfb   4
WR_REF      dfb   0
            da    WDATA
            da    WDATA_END-WDATA
WR_TRANS    da    0
CLPARM      dfb   1
CL_REF      dfb   0
NLPARM      dfb   3
NL_REF      dfb   0
NL_MASK     dfb   $7F
            dfb   $0D
NLBAD       dfb   2
            dfb   1
            dfb   $7F
            dfb   $0D
RDPARM      dfb   4
RD_REF      dfb   0
            da    RDBUF
            da    64
RD_TRANS    da    0
EFPARM      dfb   2
EF_REF      dfb   0
EF_EOF      ds    3
GFPARM      dfb   10
            da    T1PATH
GF_ACC      dfb   0
GF_TYPE     dfb   0
            ds    13
DSPARM      dfb   1
            da    T1PATH
DS2PARM     dfb   1
            da    T2PATH
C2PARM      dfb   7
            da    T2PATH
            dfb   $C3
            dfb   $04
            da    0
            dfb   1
            da    0
            da    0
O2PARM      dfb   3
            da    T2PATH
            da    $1C00
O2_REF      dfb   0
W2PARM      dfb   4
W2_REF      dfb   0
            da    W2DATA
            da    W2DATA_END-W2DATA
            da    0

T1PATH      dfb   T1END-T1PATH-1
            asc   '/mnt/MAUX/SHIM/T1'
T1END
T2PATH      dfb   T2END-T2PATH-1
            asc   '/mnt/MAUX/SHIM/T2'
T2END
WDATA       asc   'ALPHA',0D,'BETA',0D,'GAMMA',0D
WDATA_END
W2DATA      asc   'PERSIST',0D
W2DATA_END
RDBUF       ds    64
