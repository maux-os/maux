*---------------------------------------------------------------
* byetenant.s -- the `bye PATH.SYSTEM` launch's own worked
* example and gate fixture (docs/BYE.md "Slice 2 launch": "small
* enough to read in one sitting, because it is also the worked
* example of what a tenant is owed"). A REAL ProDOS 8 .SYSTEM
* program, org $2000, type $FF -- runs on the machine `bye`
* hands over, through the REAL MLI (`JSR $BF00`), NOT maux's own
* syscall gate: no kernel, no liba, nothing but the ProDOS
* contract and the monitor ROM, same shape as src/test/
* proshimtoy.s (that file's own header names the convention this
* one follows: inline command+parmlist, ROM COUT, plain 7-bit
* ASCII pathnames -- ProDOS masks the high bit when it parses a
* pathname, so this differs from maux's OWN high-bit convention
* on purpose, matching the precedent rather than this tree's
* internal one).
*
* On entry: `ldx #$FF / txs` (a fresh stack -- ProDOS hands
* control over with no promises about S); verify $280 (the
* stamped system-program name) at least LOOKS stamped (nonzero
* length) -- not gated on an exact match, since bye's own $280
* convention is maux's high-bit pathname copied verbatim
* (byelaunch.s BL2_PATH), and this fixture's job is to prove the
* launch ran, not to re-validate byelaunch.s's own copy;
* CREATE+WRITE one byte to /MAUX/BYE.MARK and one to
* /RAM/RAM.MARK (proving a REAL ProDOS write, through the
* reconnected-and-formatted /RAM volume, docs/BYE.md's own
* 2026-09-26 ruling); print "TENANT RAN" via ROM COUT ($FDED);
* MLI QUIT (the ordinary return path -- byeres.s's own
* BYE_START/BYE_BACK take it from there, exactly as a bare `bye`
* would).
*---------------------------------------------------------------
            lst   off
            xc
            org   $2000
            dsk   ../../build/byetenant.bin
            typ   $FF

TMLI        equ   $BF00
COUT        equ   $FDED
SYSNAME280  equ   $0280
IOBUF       equ   $9000        ;1 KB scratch for the MLI's own
                               ;io_buffer -- reused for BOTH
                               ;opens below, sequentially, never
                               ;concurrently (same idiom as
                               ;proshimtoy.s's shared $1C00)
* -- named per check-encoding (a bare #$FF is flagged even
* -- though it is a stack-pointer reset, not TEXT).
STACKTOP    equ   $FF

START       ldx   #STACKTOP
            txs
            cld

* -- verify $280 at least LOOKS stamped -- see header. A zero
* -- length byte here is the one thing worth a diagnostic; a
* -- populated one just proceeds (this program has no better
* -- use for the name than proving it arrived).
            lda   SYSNAME280
            bne   :sysnok
            jsr   PRINT
            asc   "NO SYSNAME",8D,00
:sysnok

* -- CREATE+WRITE one byte to /MAUX/BYE.MARK.
            jsr   TMLI
            dfb   $C0                      ;CREATE
            da    CR1PARM
            jsr   TMLI
            dfb   $C8                      ;OPEN
            da    OP1PARM
            lda   OP1_REF
            sta   WR1_REF
            sta   CL1_REF
            jsr   TMLI
            dfb   $CB                      ;WRITE
            da    WR1PARM
            jsr   TMLI
            dfb   $CC                      ;CLOSE
            da    CL1PARM

* -- CREATE+WRITE one byte to /RAM/RAM.MARK.
            jsr   TMLI
            dfb   $C0
            da    CR2PARM
            jsr   TMLI
            dfb   $C8
            da    OP2PARM
            lda   OP2_REF
            sta   WR2_REF
            sta   CL2_REF
            jsr   TMLI
            dfb   $CB
            da    WR2PARM
            jsr   TMLI
            dfb   $CC
            da    CL2PARM

* -- print TENANT RAN.
            jsr   PRINT
            asc   "TENANT RAN",8D,00

* -- MLI QUIT -- the ordinary return path; see header.
            jsr   TMLI
            dfb   $65
            da    QUITPARM

*---------------------------------------------------------------
* PRINT -- print an inline, null-terminated, PLAIN-ASCII string
* immediately following the `jsr PRINT` (proshimtoy.s's own
* idiom, copied verbatim): pull the return address, walk it
* OR-ing in $80 for COUT, then push back the address just past
* the terminator so RTS resumes after the text.
*---------------------------------------------------------------
PRINT       pla
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
            rts

*---------------------------------------------------------------
* MLI parameter lists -- proshimtoy.s's own CREATE/OPEN/WRITE/
* CLOSE field shapes, copied verbatim.
*---------------------------------------------------------------
CR1PARM     dfb   7
            da    P1PATH
            dfb   $C3
            dfb   $04
            da    0
            dfb   1
            da    0
            da    0
OP1PARM     dfb   3
            da    P1PATH
            da    IOBUF
OP1_REF     dfb   0
WR1PARM     dfb   4
WR1_REF     dfb   0
            da    W1DATA
            da    1
WR1_TRANS   da    0
CL1PARM     dfb   1
CL1_REF     dfb   0

CR2PARM     dfb   7
            da    P2PATH
            dfb   $C3
            dfb   $04
            da    0
            dfb   1
            da    0
            da    0
OP2PARM     dfb   3
            da    P2PATH
            da    IOBUF
OP2_REF     dfb   0
WR2PARM     dfb   4
WR2_REF     dfb   0
            da    W2DATA
            da    1
WR2_TRANS   da    0
CL2PARM     dfb   1
CL2_REF     dfb   0

QUITPARM    dfb   4
            dfb   0
            da    0
            dfb   0
            da    0

P1PATH      dfb   P1END-P1PATH-1
            asc   '/MAUX/BYE.MARK'
P1END
P2PATH      dfb   P2END-P2PATH-1
            asc   '/RAM/RAM.MARK'
P2END
W1DATA      dfb   $59                     ;'Y' -- one byte
W2DATA      dfb   $59
