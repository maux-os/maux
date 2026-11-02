*---------------------------------------------------------------
* globtest.s -- acceptance gate for src/liba/glob.s
* (`make check-glob`).
*
* GLOBMATCH is a backtracking matcher, which is exactly the kind
* of code that looks right and is not: writing it produced two
* bugs caught only by re-reading (a dead compare in the class
* scan, and `]` advancing the pattern cursor twice). So it gets
* a table of cases run on the real 6502 before anything depends
* on it.
*
* Each case writes 1 (pass) or 0 (fail) to RESULTS+n, and the
* case count to NCASES, where scripts/check_glob.py peeks them.
* A case that never runs leaves $EE, which reads as neither.
*---------------------------------------------------------------

*-- Hoisted above first use (S9 EQU burn-down 2026-08-29).
NCASE       equ   18

            lst   off
            xc
            org   $2000
            dsk   ../../build/MAUXGLOB.SYSTEM
            typ   $FF

RESULTS     equ   $0300              ;one byte per case
NCASES      equ   $0340

START       sei
            ldx   #$FF
            txs
            cld

            ldx   #0                 ;pre-fill "did not run"
            lda   #$EE
:fill       sta   RESULTS,x
            inx
            cpx   #64
            bne   :fill

            stz   CASEI
:caselp     lda   CASEI
            cmp   #NCASE
            bcs   :done

            sta   TMP                ;each table row is 5 bytes:
            asl   a                  ;pat lo/hi, name lo/hi,
                                     ;want
            asl   a                  ;so index = n*4 + n
            clc
            adc   TMP
            tax
            lda   CASES,x
            sta   PTR0
            lda   CASES+1,x
            sta   PTR0+1
            lda   CASES+2,x
            sta   PTR1
            lda   CASES+3,x
            sta   PTR1+1
            lda   CASES+4,x
            sta   WANT

            jsr   GLOBMATCH
            lda   #0                 ;carry clear = matched
            rol   a                  ;A = 1 if NO match
            eor   #1                 ;A = 1 if matched
            cmp   WANT
            beq   :pass
            lda   #0
            bra   :store
:pass       lda   #1
:store      ldx   CASEI
            sta   RESULTS,x
            inc   CASEI
            bra   :caselp

:done       lda   #NCASE
            sta   NCASES
SPIN        jmp   SPIN

CASEI       ds    1
TMP         ds    1
WANT        ds    1

*---------------------------------------------------------------
* The battery. `want` is 1 for match, 0 for no match.
*---------------------------------------------------------------
CASES
            da    P_STAR,N_FOO
            dfb   1                  ;*        vs foo
            da    P_STAR,N_EMPTY
            dfb   1                  ;* vs "" (empty)
            da    P_STXT,N_UPTXT
            dfb   1                  ;*.txt vs NOTES.TXT fold
            da    P_STXT,N_BIN
            dfb   0                  ;*.txt    vs notes.bin
            da    P_QTXT,N_ATXT
            dfb   1                  ;?.txt    vs a.txt
            da    P_QTXT,N_ABTXT
            dfb   0                  ;?.txt    vs ab.txt
            da    P_AB,N_AB
            dfb   1                  ;a*b vs ab (star empty)
            da    P_AB,N_AXXXB
            dfb   1                  ;a*b      vs axxxb
            da    P_AB,N_AXXX
            dfb   0                  ;a*b      vs axxx
            da    P_CLS,N_BX
            dfb   1                  ;[abc]x   vs bx
            da    P_CLS,N_DX
            dfb   0                  ;[abc]x   vs dx
            da    P_RNG,N_QX
            dfb   1                  ;[a-z]x   vs Qx      fold
            da    P_NEG,N_BX
            dfb   1                  ;[!a]x    vs bx
            da    P_NEG,N_AX
            dfb   0                  ;[!a]x    vs ax
            da    P_2STAR,N_AXBY
            dfb   1                  ;*x*y     vs axby
            da    P_FOO,N_FOO
            dfb   1                  ;foo      vs foo
            da    P_FOO,N_FOOBAR
            dfb   0                  ;foo      vs foobar
            da    P_STARB,N_AXXXB
            dfb   1                  ;*b vs axxxb backtrack
*-- NCASE: hoisted above its first use (EQU burn-down).

P_STAR      asc   "*"
            dfb   0
P_STXT      asc   "*.txt"
            dfb   0
P_QTXT      asc   "?.txt"
            dfb   0
P_AB        asc   "a*b"
            dfb   0
P_CLS       asc   "[abc]x"
            dfb   0
P_RNG       asc   "[a-z]x"
            dfb   0
P_NEG       asc   "[!a]x"
            dfb   0
P_2STAR     asc   "*x*y"
            dfb   0
P_FOO       asc   "foo"
            dfb   0
P_STARB     asc   "*b"
            dfb   0

N_FOO       asc   "foo"
            dfb   0
N_EMPTY     dfb   0
N_UPTXT     asc   "NOTES.TXT"
            dfb   0
N_BIN       asc   "notes.bin"
            dfb   0
N_ATXT      asc   "a.txt"
            dfb   0
N_ABTXT     asc   "ab.txt"
            dfb   0
N_AB        asc   "ab"
            dfb   0
N_AXXXB     asc   "axxxb"
            dfb   0
N_AXXX      asc   "axxx"
            dfb   0
N_BX        asc   "bx"
            dfb   0
N_DX        asc   "dx"
            dfb   0
N_QX        asc   "Qx"
            dfb   0
N_AX        asc   "ax"
            dfb   0
N_AXBY      asc   "axby"
            dfb   0
N_FOOBAR    asc   "foobar"
            dfb   0

            put   ../../inc/zp.equ
            put   ../liba/glob.s
* -- glob.s's cursor bytes live in liba's shared `dum` arena
* -- now (docs/STICKY.md sec 25), so this manifest has to carry
* -- the arena too -- and it must stay the LAST `put`, with
* -- nothing emitted after it (scripts/check_purity.py checks).
            put   ../liba/libabss.s
