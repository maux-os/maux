*---------------------------------------------------------------
* cal.s -- print a Gregorian calendar (XSI cal.html).
*
* Usage: cal [[month] year]
*
* No operands: today's month/year, read via SC_CLOCK the same
* way date.s does (same legacy-vs-Extended validity check and
* pivot-78 year window, PRODOS-VERSION.md) -- "no clock" or an
* invalid stamp refuses with a message to fd 2, exit 1, rather
* than print a fabricated date (date.s's own posture).
*
* One operand: YEAR alone (XSI's own reading of a single
* operand -- never a bare month). SHIPPED 2026-09-17: BSD's own
* THREE-COLUMN layout (4 quarters of 3 months, a year header
* line, ONE empty line between quarters), matching this host's
* own /usr/bin/cal YEAR measured live before writing it. Every
* quarter is always 6 week rows, same as PRINTMON's own long-
* standing month-year-form pad-to-6 rule (measured: even a
* quarter where every month fits in 5 still shows a fully blank
* 6th row across all 3 columns, not a shorter block). PRINTMON
* renders each month UNCHANGED; CALEMITC/CALEMITS just redirect
* its output into a scratch buffer (CAL_BUFMODE) so 3 months can
* be re-emitted interleaved -- see CALEMITC/PRINTQTR below for
* the mechanism, PRINTYEARHDR for the year line's own (measured)
* placement formula.
*
* Two operands: MONTH YEAR, 1-12 and 1-9999 -- a value outside
* either range, or a non-digit operand, is a usage error (exit
* 2), matching the house convention for a bad operand rather
* than a runtime diagnostic.
*
* RENDERING MATCHES THIS HOST'S OWN /usr/bin/cal (BSD, macOS)
* FOR THE MONTH-YEAR FORM, measured live before writing this
* file: every line is exactly 22 columns, trailing-space padded
* -- including a fully blank week row when the month needs
* fewer than 6 -- and the title is centred in a 20-column field
* (leftpad = (20-len)/2, rightpad = 20-len-leftpad) with 2 more
* trailing columns always appended. The day-name header
* ("Su Mo Tu We Th Fr Sa  ") is a fixed 22-byte constant.
*
* DAY OF WEEK: Sakamoto's algorithm (day=1 only, so no division
* by the day itself is needed) -- GREGORIAN ONLY, the 1752
* Julian/Gregorian switch is a KNOWN_GAPS row, same as every
* other maux date routine. No divide instruction on 6502, so
* DIV16 below is a 16x16 restoring binary divider, the SAME
* SHAPE PLASMA's own known-gap udiv16 note describes (MEMORY.md
* "PLASMA divmod is still signed") -- unsigned throughout, no
* sign hazard here since a year and its divisors are never
* negative.
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/cal.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

* -- `cal YEAR`'s 3-column layout (SHIPPED 2026-09-17) borrows
* -- PTR2 as its running buffer-write cursor: nothing else in
* -- this file (CALCDOW/DIV16/CKYEAR/PARSENUM) touches it, and
* -- liba's own STRLEN/STRCPY/U2DEC/PUTS/PUTC document PTR2 as
* -- preserved, so it survives untouched across a whole
* -- buffered PRINTMON call.
CAL_BUFPTR  equ   PTR2

START       stz   CAL_BUFMODE       ;dum is NOT zeroed --
                                    ;PRINTMON's own CALEMITC/
                                    ;CALEMITS read this on EVERY
                                    ;call, so month-year/no-args
                                    ;need a real zero, not
                                    ;whatever garbage dum left
            lda   #6                ;month-year/no-args pad-to-6
            sta   CAL_NROWS         ;-- :yearonly sets this per
                                    ;quarter instead (4-6)
            lda   ARGC
            cmp   #1
            bne   :ckyr1
            jmp   :noargs
:ckyr1      cmp   #2
            bne   :ckyr2
            jmp   :yearonly
:ckyr2      cmp   #3
            bne   :ckyr3
            jmp   :monthyr
:ckyr3      jmp   :usage

*-- no operands: today's month/year via the clock, date.s's own
*-- decode/validity rules (skip day/hour/minute -- cal has no
*-- use for them).
:noargs     lda   #<CLKBUF
            sta   PTR0
            lda   #>CLKBUF
            sta   PTR0+1
            jsr   SC_CLOCK
            bcc   :clkok
            jmp   :noclock
:clkok      lda   CLKBUF
            ora   CLKBUF+1
            bne   :haveclk
            jmp   :noclock
:haveclk    lda   CLKBUF+3
            cmp   #24
            bcc   :hourok
            jmp   :noclock
:hourok     lda   CLKBUF+2
            cmp   #60
            bcc   :minok
            jmp   :noclock
:minok      lda   CLKBUF
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            and   #$07
            sta   CAL_MON
            lda   CLKBUF+1
            and   #$01
            asl   a
            asl   a
            asl   a
            ora   CAL_MON
            sta   CAL_MON
            lda   CLKBUF+1
            lsr   a
            and   #$7F
            sta   CLKY7
            cmp   #78
            bcc   :y2k
            lda   #<1900
            sta   CAL_YEAR
            lda   #>1900
            sta   CAL_YEAR+1
            bra   :addy7
:y2k        lda   #<2000
            sta   CAL_YEAR
            lda   #>2000
            sta   CAL_YEAR+1
:addy7      clc
            lda   CAL_YEAR
            adc   CLKY7
            sta   CAL_YEAR
            lda   CAL_YEAR+1
            adc   #0
            sta   CAL_YEAR+1
            jmp   :havemy

*-- one operand: YEAR only, XSI's own reading -- BSD's own
*-- 3-column layout (SHIPPED 2026-09-17), matching this host's
*-- own /usr/bin/cal YEAR measured live before writing this:
*-- a year header line, then 4 quarters of 3 months each,
*-- rendered into MBUFS0/1/2 via PRINTMON's own CALEMITC/
*-- CALEMITS funnel (CAL_BUFMODE=1) and re-emitted interleaved,
*-- one row of all 3 months at a time, separated by ONE empty
*-- line between quarters. PRINTMON's own bytes are UNCHANGED by
*-- any of this -- only where they land is.
:yearonly   lda   #1
            jsr   GETARG
            jsr   PARSENUM
            bcc   :yrnumok
            jmp   :usage
:yrnumok    jsr   CKYEAR
            bcc   :yrckok
            jmp   :usage
:yrckok     jsr   PRINTYEARHDR
            stz   CAL_QTR
*-- EVERY quarter is always exactly 6 week rows (PRINTMON's own
*-- long-standing pad-to-6 rule, UNCHANGED for the year form --
*-- measured live: 2020's Q1 and Q4 both show a fully blank 6th
*-- row across all 3 months, same as a single month-year block
*-- would). CAL_NROWS/CAL_TROWS stay at START's own defaults
*-- (6/8) -- set again here only for the reader, not because
*-- anything could have changed them.
:qtrlp      lda   #6
            sta   CAL_NROWS
            lda   #8
            sta   CAL_TROWS
            stz   CAL_SLOT
:slotlp     jsr   QTRMON            ;CAL_MON = QTR*3+SLOT+1
            lda   CAL_SLOT
            jsr   SLOTBASE          ;CAL_BUFPTR = slot base
            lda   #1
            sta   CAL_BUFMODE
            jsr   PRINTMON
            inc   CAL_SLOT
            lda   CAL_SLOT
            cmp   #3
            bne   :slotlp
            stz   CAL_BUFMODE
            jsr   PRINTQTR
            inc   CAL_QTR
            lda   CAL_QTR
            cmp   #4
            beq   :fydone
            jsr   PRINTQSEP
            bra   :qtrlp
:fydone     lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* QTRMON -- CAL_MON = CAL_QTR*3 + CAL_SLOT + 1.
*---------------------------------------------------------------
QTRMON      lda   CAL_QTR
            asl   a
            clc
            adc   CAL_QTR
            clc
            adc   CAL_SLOT
            clc
            adc   #1
            sta   CAL_MON
            rts

*-- two operands: MONTH YEAR.
:monthyr    lda   #1
            jsr   GETARG
            jsr   PARSENUM
            bcs   :usage
            lda   ACCHI
            bne   :usage
            lda   ACCLO
            beq   :usage
            cmp   #13
            bcs   :usage
            sta   CAL_MON
            lda   #2
            jsr   GETARG
            jsr   PARSENUM
            bcs   :usage
            jsr   CKYEAR
            bcs   :usage

:havemy     jsr   PRINTMON
            lda   #0
            jsr   EXIT

:noclock    lda   #<NOCLKMSG
            sta   PTR0
            lda   #>NOCLKMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* CALEMITC/CALEMITS -- PRINTMON's own output funnel. CAL_BUFMODE
* 0 (month-year/no-args forms): straight to stdout, exactly what
* PRINTMON always did. CAL_BUFMODE 1 (year form): writes through
* CAL_BUFPTR instead, advancing it byte by byte, so 3 months can
* be rendered into scratch and re-emitted interleaved -- see
* PRINTQTR below. CALEMITC CLOBBERS: A, X, Y (buffered: A only).
* CALEMITS CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- BUG FOUND ON THE BOX 2026-09-17: `lda CAL_BUFMODE` here used
*-- to clobber A -- the very byte CALEMITC exists to print --
*-- BEFORE the branch that decides where it goes, so every
*-- single-byte call (pad spaces, CALPR2's digits, row CRs) sent
*-- PUTC/the buffer CAL_BUFMODE's own value (0 or 1) instead of
*-- the caller's byte. Caught by check-posixutil's cal rows
*-- (month-year AND year forms both printed NUL/$01 padding).
*-- PHA/PLA around the CAL_BUFMODE peek fixes it; X survives
*-- the peek already (only A was ever at risk).
CALEMITC    pha
            lda   CAL_BUFMODE
            bne   :buf
            pla
            ldx   #FD_STDOUT
            jsr   PUTC
            rts
:buf        pla
            ldy   #0
            sta   (CAL_BUFPTR),y
            inc   CAL_BUFPTR
            bne   :ok
            inc   CAL_BUFPTR+1
:ok         rts

CALEMITS    lda   CAL_BUFMODE
            bne   :bufs
            ldx   #FD_STDOUT
            jsr   PUTS
            rts
:bufs       ldy   #0
:bslp       lda   (PTR0),y
            beq   :bsdone
            phy
            jsr   CALEMITC
            ply
            iny
            bra   :bslp
:bsdone     rts

*---------------------------------------------------------------
* PRINTYEARHDR -- IN: CAL_YEAR. Prints the year line ABOVE the
* 3-column grid: (60-digits)/2 leading spaces (NO trailing pad),
* then the decimal year, then CR. 60 = 3 * 20, the SAME 20-col
* title field PRINTMON's own per-month title centers in -- this
* is not a separate convention, just that field's width times
* three. Measured live against this host's own cal for 1/2/3/4-
* digit years (leadpad 29/29/28/28) before writing this, since
* the XCU text says nothing about the year line's own placement.
*---------------------------------------------------------------
PRINTYEARHDR
            lda   CAL_YEAR
            sta   U2DEC_VAL
            lda   CAL_YEAR+1
            sta   U2DEC_VAL+1
            lda   #<YRHDRBUF
            sta   PTR1
            lda   #>YRHDRBUF
            sta   PTR1+1
            jsr   U2DEC             ;A = digit count
            sta   CAL_TLEN
            lda   #60
            sec
            sbc   CAL_TLEN
            lsr   a                 ;(60-digits)/2, truncated
            sta   CAL_I
:yhlp       lda   CAL_I
            beq   :yhd
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            dec   CAL_I
            bra   :yhlp
:yhd        lda   #<YRHDRBUF
            sta   PTR0
            lda   #>YRHDRBUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

            put   calmon.s

DAYSTAB     dfb   31,28,31,30,31,30,31,31,30,31,30,31
SAKTAB      dfb   0,3,2,5,0,3,5,1,4,6,2,4

MONNAMES    da    JANNM
            da    FEBNM
            da    MARNM
            da    APRNM
            da    MAYNM
            da    JUNNM
            da    JULNM
            da    AUGNM
            da    SEPNM
            da    OCTNM
            da    NOVNM
            da    DECNM
JANNM       asc   "January"
            dfb   0
FEBNM       asc   "February"
            dfb   0
MARNM       asc   "March"
            dfb   0
APRNM       asc   "April"
            dfb   0
MAYNM       asc   "May"
            dfb   0
JUNNM       asc   "June"
            dfb   0
JULNM       asc   "July"
            dfb   0
AUGNM       asc   "August"
            dfb   0
SEPNM       asc   "September"
            dfb   0
OCTNM       asc   "October"
            dfb   0
NOVNM       asc   "November"
            dfb   0
DECNM       asc   "December"
            dfb   0

DOWHDR      asc   "Su Mo Tu We Th Fr Sa  "
            dfb   0
USAGEMSG    asc   "usage: cal [[month] year]"
            dfb   $8D,$00
NOCLKMSG    asc   "cal: no valid clock reading"
            dfb   $8D,$00

            put   calcalc.s

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* cal's own scalars, `dum`/`dend` off LIBA_BSSEND -- no `ds`
* zeros needed (docs/STICKY.md sec 21): every cell below is
* write-before-read.
*  - CAL_MON/CAL_YEAR: written on every path before PRINTMON.
*  - CLKBUF/CLKY7: SC_CLOCK's own buffer and the :noargs decode
*    scratch, see date.s's own note on why the carry is checked
*    before CLKBUF is ever read.
*  - ACCLO/ACCHI/AC_*: PARSENUM's own first stores.
*  - CAL_TLEN/CAL_PAD/CAL_LPAD/CAL_RPAD/CAL_I: PRINTMON's own
*    centering scratch, each written before its own reader.
*  - CAL_MDAYS/CAL_MDAY1/CAL_DOW/CAL_CELL/CAL_ROW/CAL_COL: set
*    by CALCDOW or PRINTMON before the grid loop reads them.
*  - CAL_PRU: CALPR2's own units-digit stash.
*  - NUM/DEN/REM: DIV16's own operands, written by every caller
*    before the call.
*  - LP_R4/LP_R100/LP_R400/CAL_LEAP: CALCDOW's own leap-test
*    scratch.
*  - CD_YY/CD_Y4/CD_Y100/CD_Y400/CD_SUM: CALCDOW's own Sakamoto
*    scratch.
*  - TITLEBUF: BUILDTTL fills it start to NUL every call.
*  - CAL_BUFMODE: `stz` as START's OWN first instruction (every
*    path reaches PRINTMON's CALEMITC/CALEMITS downstream of
*    it), then explicitly re-set 0/1 around each :yearonly
*    PRINTMON call.
*  - CAL_QTR/CAL_SLOT/CAL_QROW: `stz`'d by :yearonly/PRINTQTR
*    before their own loops read them.
*  - CAL_NROWS/CAL_TROWS: `lda #6/#8 / sta` in START's opening
*    run, re-set to the SAME 6/8 at each :yearonly quarter --
*    every quarter is always 6 week rows (measured live: even
*    2020's Q1/Q4 show a fully blank 6th row, PRINTMON's own
*    month-year-form pad-to-6 rule, same for the year form).
*  - YRHDRBUF: U2DEC fills it (digits + NUL) before PUTS reads
*    it, every PRINTYEARHDR call.
*  - MBUFS0/1/2: CALEMITC's buffered arm writes every byte
*    PRINTQTR later reads -- PRINTMON emits exactly 8*23 bytes
*    per call
*    (verified: title/header/each week row are all exactly 22
*    content bytes + 1 CR, the same invariant the month-year
*    form's own header already establishes), so all 3*184 bytes
*    PRINTQTR indexes were written by that quarter's 3 PRINTMON
*    calls, never a stale slot from an earlier quarter.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
CAL_MON     ds    1
CAL_YEAR    ds    2
CLKBUF      ds    4
CLKY7       ds    1
ACCLO       ds    1
ACCHI       ds    1
AC_DIGIT    ds    1
AC_TWOLO    ds    1
AC_TWOHI    ds    1
CAL_TLEN    ds    1
CAL_PAD     ds    1
CAL_LPAD    ds    1
CAL_RPAD    ds    1
CAL_I       ds    1
CAL_MDAYS   ds    1
CAL_MDAY1   ds    1
CAL_DOW     ds    1
CAL_CELL    ds    1
CAL_ROW     ds    1
CAL_COL     ds    1
CAL_PRU     ds    1
NUM         ds    2
DEN         ds    2
REM         ds    2
LP_R4       ds    1
LP_R100     ds    1
LP_R400     ds    1
CAL_LEAP    ds    1
CD_YY       ds    2
CD_Y4       ds    2
CD_Y100     ds    2
CD_Y400     ds    2
CD_SUM      ds    2
TITLEBUF    ds    24
CAL_BUFMODE ds    1              ;0 stdout, 1 buffered (year)
CAL_QTR     ds    1              ;0-3, which quarter
CAL_SLOT    ds    1              ;0-2, month of the quarter
CAL_QROW    ds    1              ;PRINTQTR's own out-row index
CAL_NROWS   ds    1              ;week rows PRINTMON pads to
CAL_TROWS   ds    1              ;CAL_NROWS+2, PRINTQTR's bound
YRHDRBUF    ds    6              ;PRINTYEARHDR's U2DEC target
MBUFS0      ds    184            ;slot 0 -- 8 rows * 23B (max)
MBUFS1      ds    184            ;slot 1
MBUFS2      ds    184            ;slot 2
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window.
            err   */$BF00
            dend
