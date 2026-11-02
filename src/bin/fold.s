*---------------------------------------------------------------
* fold.s -- POSIX fold(1): break lines to a maximum width.
*
* Usage: fold [-bs] [-w width] [file...]
*
* Default width 80. -b counts WIDTH in raw bytes; the default
* (column) mode expands a tab to the next multiple-of-8 column
* and a backspace decrements the column by one (never below
* 0), both measured live against this Mac's own /usr/bin/fold
* before writing a byte. maux's own CR ($8D) already IS the
* line terminator (there is no separate LF), so the XCU rule "a
* <carriage-return> resets the column to zero" falls out for
* free here -- CR always ends a physical line and starts a
* fresh one, the same event this file calls a "natural"
* (unforced) line end.
*
* -s: when a FORCED break is needed (the row would exceed
* width), and the buffered row contains a <blank> (space $A0
* or tab $89), the break lands right AFTER the LAST such blank
* instead of at the width boundary -- the blank itself stays
* on the finished row, and whatever followed it in the buffer
* is REPLAYED onto the new row with its column recomputed from
* 0. If the buffered row has no blank at all, -s has no effect
* (plain width-exact break). Measured against a 15-column
* example from this host's own /usr/bin/fold and two synthetic
* ones (a blank landing exactly at the width boundary; several
* trailing blanks spanning the boundary) -- all three needed
* the "cut after the LAST blank, replay the remainder" rule,
* not "cut before the first word that doesn't fit" (which
* gives the wrong byte count on the boundary case).
*
* A TAB THAT WOULD OVERSHOOT THE WIDTH triggers an EARLY forced
* break BEFORE the tab itself, so it starts fresh on the next
* row -- UNLESS the current row is already empty (column 0), in
* which case the overshoot is accepted rather than looping
* forever (measured: a lone tab wider than the whole width still
* prints, alone, then breaks).
*
* MULTIPLE FILES are folded independently, not as one continuous
* column stream -- the column/row state resets at the start of
* each operand (measured: `fold -w5` on a 5-byte file with no
* trailing newline, followed by a second file, does NOT insert a
* break at the join; the two outputs simply abut on one line).
* This falls out of the same rule that governs a single file's
* own unterminated last line: EOF with a nonempty pending row
* flushes it WITHOUT a synthesized CR (measured, matching this
* host) -- so two such flushes back to back, with nothing
* between them, look exactly like one continuous line. A file
* that cannot be opened prints "fold: cannot open NAME" to
* stderr and is skipped, same policy as cut.s/head.s; overall
* exit status is 1 if any operand failed to open.
*
* WIDTH CAP: MAXWIDTH (120) keeps COL and ROWBUF single-byte/
* fixed-size -- generous for an 80-column screen and then some,
* and a single tab's worst-case overshoot (+7) still fits in a
* byte comfortably under 256. -w 0 or -w > MAXWIDTH is a usage
* error, exit 2.
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
            dsk   ../../build/fold.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255
DEFWIDTH    equ   80
MAXWIDTH    equ   120
BUFCAP      equ   140
TABCH       equ   $89
BSCH        equ   $88
BLANKSP     equ   $A0

START       stz   WANT_B
            stz   WANT_S
            lda   #DEFWIDTH
            sta   WIDTH

            lda   #<FOLDOPTS
            ldx   #>FOLDOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$E2                  ;'b'
            bne   :notb
            lda   #1
            sta   WANT_B
            bra   :optlp
:notb       cmp   #$F3                  ;'s'
            bne   :notw
            lda   #1
            sta   WANT_S
            bra   :optlp
:notw       cmp   #$F7                  ;'w'
            bne   :usageerr
            jsr   PARSEW
            bra   :optlp
:usageerr   jmp   USAGEEXIT

:optdone    lda   ARGC
            sec
            sbc   OPTIND
            sta   NARGS
            stz   ERRFLAG
            lda   NARGS
            bne   :havefile
            lda   #FD_STDIN
            sta   SRCFD
            jsr   FOLDFD
            jmp   :donemain

:havefile   lda   OPTIND
            sta   ARGIDX
:looparg    lda   ARGIDX
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :opened
            lda   #<CANTOPEN
            sta   PTR0
            lda   #>CANTOPEN
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG
            bra   :nextarg

:opened     lda   OPARM_REF
            sta   SRCFD
            jsr   FOLDFD
            lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE

:nextarg    inc   ARGIDX
            lda   ARGIDX
            cmp   ARGC
            bcc   :looparg

:donemain   lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* PARSEW -- parse -w's OPTARG (digits, high-bit ASCII) into
* WIDTH, 1..MAXWIDTH. Any non-digit, an empty string, 0, or a
* value over MAXWIDTH is a usage error.
*---------------------------------------------------------------
PARSEW      lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            stz   WACC
            ldy   #0
:wloop      lda   (PTR0),y
            beq   :wend
            and   #$7F
            cmp   #'0'
            bcc   :usageerr4
            cmp   #'9'+1
            bcs   :usageerr4
            and   #$0F
            sta   WDIGIT
            lda   WACC
            cmp   #26
            bcs   :usageerr4
            asl   a
            sta   WTMP2
            lda   WACC
            asl   a
            asl   a
            asl   a
            clc
            adc   WTMP2
            clc
            adc   WDIGIT
            sta   WACC
            iny
            bra   :wloop
:wend       cpy   #0
            beq   :usageerr4
            lda   WACC
            beq   :usageerr4
            cmp   #MAXWIDTH+1
            bcs   :usageerr4
            sta   WIDTH
            rts
:usageerr4  jmp   USAGEEXIT

*---------------------------------------------------------------
* USAGEEXIT -- usage banner to stderr, exit 2.
*---------------------------------------------------------------
USAGEEXIT   lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* FOLDFD -- fold SRCFD to stdout. Resets ALL per-file state
* itself (BUFPOS/BUFLEN/RLEN/COL) -- a `dum` arena is not
* zeroed, and a warm respawn (or the NEXT operand in this same
* invocation) must never see a previous file's leftovers, same
* reasoning as cut.s's own CUTFD.
*---------------------------------------------------------------
FOLDFD      stz   BUFPOS
            stz   BUFLEN
            stz   RLEN
            stz   COL
:floop      jsr   GETBYTE
            bcs   :feof
            cmp   #$8D
            beq   :fcr
            cmp   #$0D             ;either terminator ends a
            beq   :fcr           ;line -- a foreign file
            jsr   APPEND1
            bra   :floop
:fcr        lda   RLEN
            jsr   EMITN
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            stz   RLEN
            stz   COL
            bra   :floop
:feof       lda   RLEN
            beq   :fdone
            lda   RLEN
            jsr   EMITN
            stz   RLEN
            stz   COL
:fdone      rts

*---------------------------------------------------------------
* APPEND1 -- append one non-CR byte (in A) to the current row,
* forcing a break first if it would overshoot WIDTH (see this
* file's header for the column rules and the -b/-s variants).
*---------------------------------------------------------------
APPEND1     sta   AP_BYTE
:retry      lda   WANT_B
            bne   :asbyte
            lda   AP_BYTE
            cmp   #TABCH
            beq   :tab
            cmp   #BSCH
            beq   :bs
:asbyte     lda   COL
            clc
            adc   #1
            sta   AP_NEWCOL
            bra   :check
:tab        lda   COL
            and   #$F8
            clc
            adc   #8
            sta   AP_NEWCOL
            bra   :check
:bs         lda   COL
            beq   :bsz
            dec   COL
:bsz        jsr   PLACEBYTE
            rts

:check      lda   AP_NEWCOL
            cmp   WIDTH
            bcc   :fits
            beq   :fits
            lda   COL
            bne   :mustflush
            lda   AP_NEWCOL
            sta   COL
            jsr   PLACEBYTE
            rts
:mustflush  jsr   FLUSHROW
            lda   AP_BYTE
            jmp   :retry
:fits       lda   AP_NEWCOL
            sta   COL
            jsr   PLACEBYTE
            rts

*---------------------------------------------------------------
* PLACEBYTE -- append AP_BYTE to ROWBUF (COL already updated by
* the caller). Silently drops on the defensive BUFCAP overflow
* check -- WIDTH<=MAXWIDTH<BUFCAP keeps this from ever firing.
*---------------------------------------------------------------
PLACEBYTE   ldy   RLEN
            cpy   #BUFCAP
            bcs   :full
            lda   AP_BYTE
            sta   ROWBUF,y
            inc   RLEN
:full       rts

*---------------------------------------------------------------
* RECOL -- IN: A = byte. Applies the SAME column rule as
* APPEND1's classifier, unconditionally (no width check) -- used
* by CARRYOVER to recompute a replayed byte's column effect on
* the fresh row it is joining.
*---------------------------------------------------------------
RECOL       pha
            lda   WANT_B
            bne   :rbyte
            pla
            cmp   #TABCH
            beq   :rtab
            cmp   #BSCH
            beq   :rbs
            bra   :rbyte2
:rbyte      pla
:rbyte2     inc   COL
            rts
:rtab       lda   COL
            and   #$F8
            clc
            adc   #8
            sta   COL
            rts
:rbs        lda   COL
            beq   :rbsdone
            dec   COL
:rbsdone    rts

*---------------------------------------------------------------
* FLUSHROW -- a FORCED break (the row is full). Plain: emit
* ROWBUF[0..RLEN) + CR. -s with a blank present: emit up to and
* including the LAST blank, + CR, then CARRYOVER replays what
* is left onto a fresh row.
*---------------------------------------------------------------
FLUSHROW    lda   WANT_S
            beq   :plain
            jsr   FINDBLANK
            lda   FB_FOUND
            beq   :plain
            lda   FB_POS
            clc
            adc   #1
            jsr   EMITN
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   CARRYOVER
            rts
:plain      lda   RLEN
            jsr   EMITN
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            stz   RLEN
            stz   COL
            rts

*---------------------------------------------------------------
* FINDBLANK -- scan ROWBUF[0..RLEN) for the LAST space/tab.
* OUT: FB_FOUND (0/1), FB_POS (index, valid only if found).
*---------------------------------------------------------------
FINDBLANK   stz   FB_FOUND
            ldy   #0
:fbloop     cpy   RLEN
            bcs   :fbdone
            lda   ROWBUF,y
            cmp   #BLANKSP
            beq   :fbmark
            cmp   #TABCH
            bne   :fbnext
:fbmark     sty   FB_POS
            lda   #1
            sta   FB_FOUND
:fbnext     iny
            bra   :fbloop
:fbdone     rts

*---------------------------------------------------------------
* CARRYOVER -- shift ROWBUF[FR_CUT..RLEN) down to ROWBUF[0..),
* recomputing COL from 0 as each byte is replayed through RECOL
* (a left shift with the destination index always behind the
* source index -- safe, no aliasing). FR_CUT is EMITN's own last
* count, still valid here (see FLUSHROW's call order).
*---------------------------------------------------------------
CARRYOVER   stz   COL
            ldy   FR_CUT
            ldx   #0
:cloop      cpy   RLEN
            bcs   :cdone
            lda   ROWBUF,y
            sta   ROWBUF,x
            jsr   RECOL
            inx
            iny
            bra   :cloop
:cdone      stx   RLEN
            rts

*---------------------------------------------------------------
* EMITN -- IN: A = count. Print ROWBUF[0..count), no CR. Also
* leaves the count in FR_CUT for a caller that needs it again
* (CARRYOVER's own source index).
*---------------------------------------------------------------
EMITN       sta   FR_CUT
            ldy   #0
:eloop      cpy   FR_CUT
            bcs   :edone
            lda   ROWBUF,y
            phy
            ldx   #FD_STDOUT
            jsr   PUTC
            ply
            iny
            bra   :eloop
:edone      rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as cut.s.
*---------------------------------------------------------------
GETBYTE     ldx   BUFPOS
            cpx   BUFLEN
            bcc   :have
            jsr   REFILL
            bcs   :eof
            ldx   BUFPOS
:have       lda   CBUF,x
            inc   BUFPOS
            clc
            rts
:eof        sec
            rts

REFILL      lda   SRCFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :eof
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :eof
            lda   RPARM_TRANS
            sta   BUFLEN
            stz   BUFPOS
            clc
            rts
:eof        sec
            rts

USAGEMSG    asc   "usage: fold [-bs] [-w width] [file ...]"
            dfb   $8D,$00
CANTOPEN    asc   "fold: cannot open "
            dfb   $00
FOLDOPTS    asc   "bsw:"
            dfb   0

OPARM       dfb   PCOUNT_OPEN
OPARM_PATH  da    PATHBUF
OPARM_IOBUF da    $0000
OPARM_REF   dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    CBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* fold's bss -- `dum`/`dend` off LIBA_BSSEND (docs/STICKY.md
* sec 21, learning:01M0FNC75R7YSFRNS328WHXMHN). NOTHING ZEROES
* THIS ARENA:
*  - WANT_B/WANT_S/WIDTH: START's opening run stores all three
*    before GETOPT can read any of them.
*  - NARGS/ERRFLAG/ARGIDX/SRCFD: written right after option
*    parsing or at :havefile/:opened, before any read.
*  - WACC/WDIGIT/WTMP2: PARSEW's own stores, before their own
*    later reads, every call.
*  - BUFPOS/BUFLEN/RLEN/COL: `stz`'d by FOLDFD itself, first
*    thing, on EVERY call -- per file, same reasoning as cut.s's
*    own CUTFD.
*  - AP_BYTE/AP_NEWCOL: APPEND1's own stores before its own
*    later reads, every call.
*  - FB_FOUND/FB_POS: FINDBLANK's own stores, every call, before
*    FLUSHROW ever reads them.
*  - FR_CUT: EMITN's own store, before CARRYOVER (its only other
*    reader) runs -- always called right after EMITN in
*    FLUSHROW's own -s path.
*  - PATHBUF: MKPATH writes chars then the count byte.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*  - ROWBUF: filled by PLACEBYTE/CARRYOVER, indexed only below
*    RLEN.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
WANT_B      ds    1
WANT_S      ds    1
WIDTH       ds    1
NARGS       ds    1
ERRFLAG     ds    1
ARGIDX      ds    1
SRCFD       ds    1
BUFPOS      ds    1
BUFLEN      ds    1
WACC        ds    1
WDIGIT      ds    1
WTMP2       ds    1
RLEN        ds    1
COL         ds    1
AP_BYTE     ds    1
AP_NEWCOL   ds    1
FB_FOUND    ds    1
FB_POS      ds    1
FR_CUT      ds    1

PATHBUF     ds    65
CBUF        ds    BUFSZ
ROWBUF      ds    BUFCAP
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window (see src/bin/cut.s for the
* -- full note).
            err   */$BF00
            dend
