*---------------------------------------------------------------
* date.s -- print the current ProDOS date and time.
*
* Usage: date
*
* Reads the raw ProDOS Global Page date/time words via SC_CLOCK
* (syscall SYS_CLOCK, inc/sc.proc.equ) -- the ONE
* kernel addition this tool needed (docs/FLEET.md's "date --
* MISSING KERNEL FEATURE" line). The kernel hands back the four
* raw bytes UNINTERPRETED (docs/PROCIO.md sec 1's "pragmatic
* kernel, elegant library" ruling); this tool does every bit of
* the decode -- the SAME legacy-vs-Extended validity check and
* pivot-78 year window src/bin/ls.s's PRINTDATE already
* established (docs/PRODOS-VERSION.md), reused rather than
* re-derived, so there is only one date policy in this tree.
*
* If the clock is ABSENT (no clock card ever stamped the global
* page -- reads all zero) or the stamp fails the legacy validity
* check (hour<=23 AND minute<=59 on the RAW, unmasked byte -- an
* Extended 2.5 stamp fails this on purpose, same discriminator
* PRODOS-VERSION.md gives), `date` refuses to print a garbage
* date: a message goes to fd 2 and it exits 1. ls -l's "-"
* placeholder is right for a TABLE column; it is wrong for a
* program whose entire output IS the date.
*
* Output format matches ls -l's date column: "YYYY-MM-DD HH:MM",
* CR-terminated, to fd 1, with NO operand.
*
* +FORMAT (SHIPPED 2026-09-17): PROCFMT interprets the strftime
* subset this machine's clock can honour: %Y (4-digit year, no
* leading zero -- U2DEC, not PR2DIG, since a year is not fixed-
* width), %m %d %H %M %y (2-digit zero-padded, PR2DIG, same as
* the fixed format above), %S (constant "00" -- this machine's
* clock has MINUTE resolution, no seconds field to read, same
* truncation touch.s's own -t/-r document), %n (newline, CR),
* %t (tab), %% (a literal '%'), and the four composites %D
* (%m/%d/%y), %T (%H:%M:%S), %R (%H:%M), %F (%Y-%m-%d) --
* built from the same PR2DIG/U2DEC calls, not re-derived. An
* unrecognised conversion, or a trailing lone '%', is a usage
* error (exit 2), the same loud-not-silent posture the rest of
* this tree takes on a bad option value.
*
* NOT SHIPPED: %a/%b (weekday/month name) and %j (day of year)
* -- both need a day-of-week/day-of-year calendar computation
* this file has never had (cal.s's own CALCDOW/Sakamoto/DAYSTAB
* machinery, ~80 lines, duplicated rather than shared per house
* convention -- "no shared module between src/bin programs",
* PR2DIG's own comment below). The priced motivating use case
* ("date +%Y%m%d for temp names and logs", docs/POSIX-GAPS.md)
* needs none of the three; left as a named, sized gap rather
* than rushed. KNOWN_GAPS row: scripts/posixutil_cases2.py.
*
* TESTING NOTE: check_posixutil's `reset(clock=...)` is a
* BOOLEAN (present/absent) -- it cannot pin a SPECIFIC wall-
* clock value, so no batch-harness row can assert exact +FORMAT
* output content; only the clock-ABSENT refusal path (unchanged
* by this work: PROCFMT is never reached) is hand-authored
* there. Proving the live-clock formatting byte-exact needs
* check_sumdate.py's own mechanism (peek the raw SYS_CLOCK bytes
* right after date reads them, decode independently in Python,
* compare) extended to a +FORMAT invocation -- not done here,
* out of this task's scope, and named so the next reader does
* not assume it already happened.
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
            dsk   ../../build/date.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

* -- +FORMAT's own running text cursor MUST be zero page
* -- ((FMTPTR),y addressing) and MUST survive every PUTC/PUTS/
* -- U2DEC call a handler makes (PTR0/PTR1 do not -- they are
* -- exactly what those calls use) -- PTR2 is free in this file,
* -- same reasoning cal.s's own CAL_BUFPTR gives for the same
* -- register.
FMTPTR      equ   PTR2

START       lda   ARGC
            cmp   #2
            beq   :hasfmt
            cmp   #1
            beq   :nofmt
            jmp   :usage
:hasfmt     lda   #1
            jsr   GETARG            ;PTR0 = argv[1]
            ldy   #0
            lda   (PTR0),y
            cmp   #$AB              ;'+' high-bit-set
            bne   :usage
            inc   PTR0
            bne   :fmtok
            inc   PTR0+1
:fmtok      lda   PTR0
            sta   FMTPTR
            lda   PTR0+1
            sta   FMTPTR+1
            jsr   READCLOCK
            jsr   PROCFMT
            lda   #0
            jsr   EXIT

:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

:nofmt      jsr   READCLOCK
            lda   YEAR7
            cmp   #78
            bcc   :y2k
            lda   #<CENT19
            ldx   #>CENT19
            jmp   :prcent
:y2k        lda   #<CENT20
            ldx   #>CENT20
:prcent     sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   YEAR7
            jsr   PR2DIG
            jsr   PUTDASH
            lda   MONTHV
            jsr   PR2DIG
            jsr   PUTDASH
            lda   DAYV
            jsr   PR2DIG
            lda   #<SPACECH
            sta   PTR0
            lda   #>SPACECH
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   HOURV
            jsr   PR2DIG
            lda   #<COLONCH
            sta   PTR0
            lda   #>COLONCH
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   MINUTEV
            jsr   PR2DIG
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* READCLOCK -- read+validate SC_CLOCK, filling HOURV/MINUTEV/
* DAYV/MONTHV/YEAR7/FULLYEAR. Does NOT return on any failure --
* jumps straight to NOCLOCK, same posture the inline code always
* had, just shared by both the fixed and +FORMAT paths now.
*---------------------------------------------------------------
READCLOCK   lda   #<CLKBUF
            sta   PTR0
            lda   #>CLKBUF
            sta   PTR0+1
            jsr   SC_CLOCK
* -- CHECK THE CARRY. PRC_CLOCK (src/kernel/procfile3.s)
* -- returns WITHOUT writing the caller's buffer when its
* -- parameter copy-in or its BankCopy fails, so on that path
* -- CLKBUF holds whatever was there before. That used to be
* -- the emitted zeros, which happened to land on the
* -- "clock absent" branch below -- the right answer by
* -- accident. With CLKBUF in `dum` it is bank garbage, and
* -- the hour<24/minute<60 validity test would pass often
* -- enough to print a FABRICATED date and exit 0. One
* -- instruction, and it is correct independently of the
* -- storage change. See docs/STICKY.md sec 28.
            bcc   :clkok
            jmp   NOCLOCK
:clkok
            lda   CLKBUF
            ora   CLKBUF+1
            bne   :haveclk
            jmp   NOCLOCK
* -- validity check on the RAW bytes, never masked -- same
* -- reasoning as ls.s's PRINTDATE: masking first would let a
* -- 2.5 Extended stamp decode as plausible garbage instead of
* -- being caught.
:haveclk    lda   CLKBUF+3          ;hour, RAW (high byte)
            sta   HOURV
            cmp   #24
            bcc   :hourok
            jmp   NOCLOCK
:hourok     lda   CLKBUF+2          ;minute, RAW (low byte)
            sta   MINUTEV
            cmp   #60
            bcc   :minok
            jmp   NOCLOCK
:minok

            lda   CLKBUF
            and   #$1F
            sta   DAYV
            lda   CLKBUF
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            and   #$07
            sta   MONTHV
            lda   CLKBUF+1
            and   #$01
            asl   a
            asl   a
            asl   a
            ora   MONTHV
            sta   MONTHV
            lda   CLKBUF+1
            lsr   a
            and   #$7F
            sta   YEAR7
            cmp   #78
            bcc   :fy2k
            clc
            lda   YEAR7
            adc   #<1900
            sta   FULLYEAR
            lda   #>1900
            adc   #0
            sta   FULLYEAR+1
            rts
:fy2k       clc
            lda   YEAR7
            adc   #<2000
            sta   FULLYEAR
            lda   #>2000
            adc   #0
            sta   FULLYEAR+1
            rts

*---------------------------------------------------------------
* PROCFMT -- IN: FMTPTR = format text (past the leading '+').
* Copies literal bytes straight through; '%' + a recognised
* conversion letter calls the matching print routine; '%' +
* anything else, or a '%' with nothing after it, is a usage
* error (exit 2) -- does not return in that case.
*---------------------------------------------------------------
PROCFMT     ldy   #0
:pflp       lda   (FMTPTR),y
            bne   :pfmore
            rts
:pfmore     cmp   #$A5              ;'%' high-bit-set
            beq   :pfpct
            ldx   #FD_STDOUT
            jsr   PUTC
            iny
            bra   :pflp
:pfpct      iny
            lda   (FMTPTR),y
            beq   :pfusage
            jsr   PFDISPATCH        ;prints, or jmp's to :usage
            iny
            bra   :pflp
:pfusage    jmp   :usage

*---------------------------------------------------------------
* PFDISPATCH -- IN: A = the char right after '%'. Linear-scans
* SPECCHARS (14 entries -- MATCH_UOP's own shape scaled up would
* need 14 far branches, out of 65C02 branch range end to end, so
* this dispatches through JTABLE instead -- sedparse.s's own
* own `asl a / tax / jmp (TABLE,x)` idiom). Each handler prints
* its own conversion and RETURNS: since this whole routine was
* reached by JSR, a handler's own `rts` pops PROCFMT's return
* address, same as any other tail-jumped call. An unrecognised
* char jumps straight to :usage (does not return).
*---------------------------------------------------------------
PFDISPATCH  ldy   #0
:pdlp       cpy   #14
            beq   :pdbad
            cmp   SPECCHARS,y
            beq   :pdfound
            iny
            bra   :pdlp
:pdbad      jmp   :usage
:pdfound    tya
            asl   a
            tax
            jmp   (JTABLE,x)

HND_Y       jmp   PRYEAR4           ;tail jmp: PRYEAR4's own rts
                                    ;pops PFDISPATCH's caller
HND_m       lda   MONTHV
            jmp   PR2DIG
HND_d       lda   DAYV
            jmp   PR2DIG
HND_H       lda   HOURV
            jmp   PR2DIG
HND_M       lda   MINUTEV
            jmp   PR2DIG
HND_S       jmp   PRZSEC
HND_y       lda   YEAR7
            jmp   PR2DIG
HND_n       lda   #$8D
            ldx   #FD_STDOUT
            jmp   PUTC
HND_t       lda   #$89
            ldx   #FD_STDOUT
            jmp   PUTC
HND_pct     lda   #$A5
            ldx   #FD_STDOUT
            jmp   PUTC
HND_D       lda   MONTHV            ;%D -- %m/%d/%y
            jsr   PR2DIG
            jsr   PUTSLASH
            lda   DAYV
            jsr   PR2DIG
            jsr   PUTSLASH
            lda   YEAR7
            jmp   PR2DIG
HND_T       lda   HOURV             ;%T -- %H:%M:%S
            jsr   PR2DIG
            jsr   PUTCOLON
            lda   MINUTEV
            jsr   PR2DIG
            jsr   PUTCOLON
            jmp   PRZSEC
HND_R       lda   HOURV             ;%R -- %H:%M
            jsr   PR2DIG
            jsr   PUTCOLON
            lda   MINUTEV
            jmp   PR2DIG
HND_F       jsr   PRYEAR4           ;%F -- %Y-%m-%d
            jsr   PUTDASH
            lda   MONTHV
            jsr   PR2DIG
            jsr   PUTDASH
            lda   DAYV
            jmp   PR2DIG

SPECCHARS   dfb   $D9,$ED,$E4,$C8,$CD,$D3,$F9,$EE,$F4,$A5
            dfb   $C4,$D4,$D2,$C6
JTABLE      da    HND_Y,HND_m,HND_d,HND_H,HND_M,HND_S,HND_y
            da    HND_n,HND_t,HND_pct,HND_D,HND_T,HND_R,HND_F

*---------------------------------------------------------------
* PRYEAR4 -- print FULLYEAR (16-bit) as plain decimal, no
* padding -- a year is not fixed-width the way %m/%d/%y are.
*---------------------------------------------------------------
PRYEAR4     lda   FULLYEAR
            sta   U2DEC_VAL
            lda   FULLYEAR+1
            sta   U2DEC_VAL+1
            lda   #<YEARBUF
            sta   PTR1
            lda   #>YEARBUF
            sta   PTR1+1
            jsr   U2DEC
            lda   #<YEARBUF
            sta   PTR0
            lda   #>YEARBUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            rts

*---------------------------------------------------------------
* PRZSEC -- print "00": this clock has minute resolution, no
* seconds field to read (documented truncation, file header).
*---------------------------------------------------------------
PRZSEC      lda   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

PUTSLASH    lda   #$AF
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

PUTCOLON    lda   #<COLONCH
            sta   PTR0
            lda   #>COLONCH
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            rts

NOCLOCK     lda   #<NOCLKMSG
            sta   PTR0
            lda   #>NOCLKMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

PUTDASH     lda   #<DASH
            sta   PTR0
            lda   #>DASH
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            rts

*---------------------------------------------------------------
* PR2DIG -- IN A = 0-99; prints two zero-padded high-bit digits.
* Same routine as ls.s's own (independent copy -- no shared
* module between src/bin programs).
*---------------------------------------------------------------
PR2DIG      ldy   #0
:tens       cmp   #10
            bcc   :ones
            sec
            sbc   #10
            iny
            bra   :tens
:ones       sta   PR2DONE
            tya
            ora   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   PR2DONE
            ora   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

NOCLKMSG    asc   "date: no valid clock reading"
            dfb   $8D,$00
USAGEMSG    asc   "usage: date [+format]"
            dfb   $8D,$00

CENT19      asc   "19"
            dfb   0
CENT20      asc   "20"
            dfb   0
DASH        asc   "-"
            dfb   0
SPACECH     asc   " "
            dfb   0
COLONCH     asc   ":"
            dfb   0

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s     ;U2DEC, %Y's own print
            put   ../liba/argv.s    ;GETARG, the +fmt operand
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s    ;SC_CLOCK -- date's own
            put   ../liba/libabss.s
                                        ;raw Global Page read

*---------------------------------------------------------------
* date's bss -- `dum`/`dend` at the TEXTUAL END, anchored at
* LIBA_BSSEND rather than `*`
* (learning:01M0FNC75R7YSFRNS328WHXMHN).
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - CLKBUF: written by SC_CLOCK, and read only on the
*    carry-CLEAR path now that START checks it -- SEE THE NOTE
*    AT THAT `bcs`. Before that check this cell was a genuine
*    read-before-write and only the emitted zeros hid it.
*  - HOURV/MINUTEV/DAYV/MONTHV/YEAR7: each `sta`'d during the
*    decode before its own later read; the paths that skip the
*    store jump to the "-" field and read none of them.
*  - PR2DONE: not a "printed already" flag despite the name --
*    it is PR2DIG's units-digit stash across the tens-digit
*    PUTC, `sta` then `lda` six instructions apart.
*  - FULLYEAR: READCLOCK's own last two stores, on both the
*    19xx and 20xx paths, before PRYEAR4 (its only reader) is
*    ever reached.
*  - FMTPTR: `sta`'d right after the leading '+' is skipped, in
*    :hasfmt, before PROCFMT (its only reader) is called.
*  - YEARBUF: U2DEC fills it (digits + NUL) before PUTS reads
*    it, every PRYEAR4 call.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
CLKBUF      ds    4
HOURV       ds    1
MINUTEV     ds    1
DAYV        ds    1
MONTHV      ds    1
YEAR7       ds    1
PR2DONE     ds    1
FULLYEAR    ds    2              ;READCLOCK's own 4-digit year
YEARBUF     ds    6              ;PRYEAR4's own U2DEC target
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
