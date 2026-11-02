*---------------------------------------------------------------
* wc.s -- count lines, words and bytes.
*
* Usage: wc [-lwc] [FILE...]
*
* CONTRACT: for each FILE, print
* "<lines> <words> <bytes> <name>" to stdout. With no FILE
* arguments, count stdin and print
* "<lines> <words> <bytes>" with no name -- the classic no-args
* shape, same as cat.s. A FILE that cannot be opened prints
* "wc: cannot open <name>" to stderr and is SKIPPED.
*
* Definitions, stated because they are the ones that matter:
*   lines = number of CR ($8D) bytes. A final unterminated line
*           is NOT counted, which is what V7 wc does and what
*           makes `wc -l` agree with the number of `\n`s.
*   words = maximal runs of non-whitespace. Whitespace is space
*           ($A0), CR ($8D) and tab ($89).
*   bytes = every byte read.
*
* FLAGS: -l, -w and -c, singly or combined; any subset selects
* exactly those columns, in the fixed l/w/c order, and no flag
* means all three. STALE UNTIL 2026-08-25: this line read "no
* -l/-w/-c flags" and the Usage line above read "wc [FILE...]"
* long after WCOPTS/`getopt` implemented all three -- a header
* that denies its own code. Caught by an inventory sweep, not by
* a gate; nothing checks a header against its option string.
*
* -m: chars in the C locale == bytes, so -m just sets WANT_C
* (the same cell -c does); there is no separate "chars" concept
* on this machine.
*
* SHIPPED 2026-09-17: a totals line for 2+ file operands -- a
* fourth line "<lines> <words> <bytes> total" summing every
* opened file, 16-bit-saturating the same way per-file counts
* do. Only counts successfully opened files; the line prints
* whenever 2+ operands were GIVEN (matching real wc even when
* one of them failed to open). Column WIDTH still does not
* match BSD/GNU wc's padding (see WC_REASON in
* scripts/posixutil_cases2.py) -- that divergence is accepted
* project-wide, not something this change reopens.
*
* COUNTER WIDTH: the counters are 16-bit, so this saturates
* at 65535 rather than wrapping -- a 64K file is already larger
* than a process bank, so the limit is documented rather than
* fixed. A wrapped count is a wrong answer that looks right; a
* saturated one is visibly pinned.
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
            dsk   ../../build/wc.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255
CNT_BYTES   equ   0              ;byte offsets into COUNTS
CNT_LINES   equ   2
CNT_WORDS   equ   4

START       stz   ERRFLAG
            stz   WANT_L
            stz   WANT_W
            stz   WANT_C

            ;-- Options first. With none given, wc prints all
            ;-- three columns, which is what it always did.
            lda   #<WCOPTS
            ldx   #>WCOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$EC                  ;'l' high-bit-set
            bne   :not_l
            sta   WANT_L
            bra   :optlp
:not_l      cmp   #$F7                  ;'w'
            bne   :not_w
            sta   WANT_W
            bra   :optlp
:not_w      cmp   #$E3                  ;'c'
            bne   :not_c
            sta   WANT_C
            bra   :optlp
:not_c      cmp   #$ED                  ;'m': chars==bytes
            bne   :badopt
            sta   WANT_C
            bra   :optlp
:badopt     lda   #<USAGE
            sta   PTR0
            lda   #>USAGE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT
:optdone    lda   WANT_L
            ora   WANT_W
            ora   WANT_C
            bne   :haveopts
            lda   #1                    ;no flags: all three
            sta   WANT_L
            sta   WANT_W
            sta   WANT_C
:haveopts
            lda   ARGC
            cmp   OPTIND
            bne   :havefile
            lda   #FD_STDIN
            sta   SRCFD
            jsr   COUNTFD
            stz   NAMEFLG              ;stdin: no name column
            jsr   REPORT
            lda   #0
            jsr   EXIT

:havefile   lda   OPTIND
            sta   ARGIDX
            ldx   #5
:tzero      stz   TOTALS,x
            dex
            bpl   :tzero
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
            bcs   :openerr
            lda   OPARM_REF
            sta   SRCFD
            jsr   COUNTFD
            jsr   ADDTOT
            ldx   SRCFD
            stx   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            lda   #1
            sta   NAMEFLG
            jsr   REPORT
            bra   :nextarg

:openerr    lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
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

:nextarg    inc   ARGIDX
            lda   ARGIDX
            cmp   ARGC
            bcc   :looparg
            lda   ARGC
            sec
            sbc   OPTIND
            cmp   #2
            bcc   :notot               ;fewer than 2 operands
            jsr   TOTAL
:notot      lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* COUNTFD -- count SRCFD into COUNTS.
*---------------------------------------------------------------
COUNTFD     ldx   #5
:zero       stz   COUNTS,x
            dex
            bpl   :zero
            stz   INWORD
            stz   BUFPOS
            stz   BUFLEN
:loop       jsr   GETBYTE
            bcs   :done
            pha
            ldx   #CNT_BYTES
            jsr   BUMP
            pla
*-- EITHER TERMINATOR ends a line. maux writes $8D; a file that
*-- arrived from outside -- over `tip`, from a2til, out of a
*-- NuFX archive -- carries ProDOS semantics, ending its
*-- lines with $0D. Testing only $8D made `wc` report ZERO
*-- lines and ONE word for an ordinary text file, with the
*-- byte count right -- the shape of the whole class: tools
*-- that only move bytes worked, tools that looked at one did
*-- not.
            cmp   #$8D
            beq   :iseol
            cmp   #$0D
            bne   :notcr
:iseol      pha
            ldx   #CNT_LINES
            jsr   BUMP
            pla
:notcr      jsr   ISSPACE
            bcc   :word
            stz   INWORD               ;whitespace ends a word
            bra   :loop
:word       lda   INWORD
            bne   :loop                ;already inside one
            lda   #1
            sta   INWORD
            ldx   #CNT_WORDS
            jsr   BUMP
            bra   :loop
:done       rts

*---------------------------------------------------------------
* ISSPACE -- carry SET if A is whitespace, clear otherwise.
*---------------------------------------------------------------
*-- Both encodings of each, for the reason above. The low twins
*-- cost nothing on a maux-written file: its text bytes are all
*-- >= $80 and can never equal one of them.
ISSPACE     cmp   #$A0                ;space
            beq   :yes
            cmp   #$20
            beq   :yes
            cmp   #$8D                ;end of line
            beq   :yes
            cmp   #$0D
            beq   :yes
            cmp   #$89                ;tab
            beq   :yes
            cmp   #$09
            beq   :yes
            clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* BUMP -- increment COUNTS[X] as a 16-bit value, saturating at
* $FFFF rather than wrapping. X is a byte offset: CNT_BYTES,
* CNT_LINES or CNT_WORDS.
*
* Indexed into one array rather than three named cells because
* an indirect would need a zero-page pointer pair, and liba has
* none to spare (see grep.s's GETBYTE for the same trade).
*---------------------------------------------------------------
BUMP        lda   COUNTS,x
            cmp   #$FF
            bne   :inclo
            lda   COUNTS+1,x
            cmp   #$FF
            beq   :pinned            ;already $FFFF, stay
:inclo      inc   COUNTS,x
            bne   :out
            inc   COUNTS+1,x
:out        rts
:pinned     rts

*---------------------------------------------------------------
* REPORT -- print the three counts, then the name if NAMEFLG.
*---------------------------------------------------------------
REPORT      lda   WANT_L
            beq   :nol
            lda   COUNTS+CNT_LINES
            sta   U2DEC_VAL
            lda   COUNTS+CNT_LINES+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
:nol        lda   WANT_W
            beq   :now
            lda   WANT_L
            beq   :now2
            jsr   PRSPACE
:now2       lda   COUNTS+CNT_WORDS
            sta   U2DEC_VAL
            lda   COUNTS+CNT_WORDS+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
:now        lda   WANT_C
            beq   :noc
            lda   WANT_L
            ora   WANT_W
            beq   :noc2
            jsr   PRSPACE
:noc2       lda   COUNTS+CNT_BYTES
            sta   U2DEC_VAL
            lda   COUNTS+CNT_BYTES+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
:noc
            lda   NAMEFLG
            beq   :nonm
            jsr   PRSPACE
            lda   NAMEFLG
            cmp   #2
            beq   :prtot
            lda   ARGIDX
            jsr   GETARG
            bra   :prnm
:prtot      lda   #<TOTALMSG
            sta   PTR0
            lda   #>TOTALMSG
            sta   PTR0+1
:prnm       ldx   #FD_STDOUT
            jsr   PUTS
:nonm       lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* ADDTOT -- add COUNTS into TOTALS, 16-bit, saturating at $FFFF
* on overflow. Same 0/2/4 offset scheme as BUMP.
*---------------------------------------------------------------
ADDTOT      ldx   #4
:aloop      clc
            lda   TOTALS,x
            adc   COUNTS,x
            sta   TOTALS,x
            lda   TOTALS+1,x
            adc   COUNTS+1,x
            sta   TOTALS+1,x
            bcc   :nosat
            lda   #$FF
            sta   TOTALS,x
            sta   TOTALS+1,x
:nosat      dex
            dex
            bpl   :aloop
            rts

*---------------------------------------------------------------
* TOTAL -- print the "total" line: copy TOTALS over COUNTS (the
* array REPORT already knows how to print) and set NAMEFLG to
* the "total" literal, not an argv name.
*---------------------------------------------------------------
TOTAL       ldx   #5
:tcp        lda   TOTALS,x
            sta   COUNTS,x
            dex
            bpl   :tcp
            lda   #2
            sta   NAMEFLG
            jsr   REPORT
            rts

*-- Fields are separated, not terminated: a trailing space
*-- before the CR is sloppiness that shows up in a diff.
PRSPACE     lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as grep.s.
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

USAGE       asc   "usage: wc [-lwc] [FILE...]"
            dfb   $8D,$00
ERRMSG      asc   "wc: cannot open "
            dfb   $00
TOTALMSG    asc   "total"
            dfb   $00

WCOPTS      asc   "lwcm"
            dfb   0

OPARM       dfb   OPEN_RO
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
            put   ../liba/num.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* wc's bss -- `dum`/`dend` at the TEXTUAL END, anchored at
* LIBA_BSSEND rather than `*`
* (learning:01M0FNC75R7YSFRNS328WHXMHN). 336 bytes that were
* emitted zeros. WCOPTS and the three parmlists stay above as
* initialised data; `da PATHBUF` / `da CBUF` resolve into this
* arena.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - ERRFLAG: `stz` as START's first instruction.
*  - WANT_L/WANT_W/WANT_C: `stz`'d in START's opening run.
*  - SRCFD: written on both the stdin and per-file paths.
*  - ARGIDX: `sta` at :havefile (from OPTIND). On the stdin
*    path its only reader sits behind `lda NAMEFLG / beq`, and
*    NAMEFLG is `stz`'d first.
*  - NAMEFLG: written once per REPORT call.
*  - INWORD: `stz` by COUNTFD, PER FILE -- the word-state
*    machine starts outside a word by a store, not by luck.
*  - BUFPOS/BUFLEN: `stz`'d by COUNTFD, PER FILE.
*  - COUNTS: COUNTFD clears ALL SIX bytes with an explicit
*    `ldx #5 / stz COUNTS,x / dex / bpl` loop, per file. These
*    are the three 16-bit accumulators and they do not rely on
*    a zero start.
*  - TOTALS: zeroed ONCE at :havefile (`:tzero`), before the
*    file loop starts, then only ever added into (ADDTOT).
*  - PATHBUF: MKPATH writes chars then the count byte.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
SRCFD       ds    1
ARGIDX      ds    1
WANT_L      ds    1              ;-l  selected
WANT_W      ds    1              ;-w
WANT_C      ds    1              ;-c  (bytes)
ERRFLAG     ds    1
NAMEFLG     ds    1
INWORD      ds    1
BUFPOS      ds    1
BUFLEN      ds    1

COUNTS      ds    6              ;bytes, lines, words -- 16-bit
TOTALS      ds    6              ;running sum for the total line

PATHBUF     ds    65
CBUF        ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
