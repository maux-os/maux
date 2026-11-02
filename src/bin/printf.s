*---------------------------------------------------------------
* printf.s -- POSIX printf(1) (XCU printf.html).
*
* Usage: printf format [argument...]
*
* FORMAT ESCAPES: \\ \a \b \f \n \r \t \v, and \ddd (1-3 OCTAL
* digits right after the backslash, no leading 0 needed) for an
* arbitrary byte. \n AND \r both emit $8D -- this machine has
* one line-end byte, not two (docs/ANACHRONISMS.md's own
* posture: no CR/LF split to preserve). Every escaped byte, and
* every digit/sign/prefix this program manufactures itself, gets
* bit 7 SET before it is written -- the machine's own text
* convention (every liba string is high-bit ASCII; see
* src/liba/string.s's own header) -- so \101 prints as a plain
* 'A' on the glass, not an inverse-video mystery byte. Argument
* TEXT (a %s/%c/%b operand) is never touched this way: it came
* out of ARGV already in that same convention, and is copied
* through unchanged.
*
* CONVERSIONS: %d %i %o %u %x %X %c %s %% and %b (XSI). Flags
* - + space #; a decimal field WIDTH; a .PRECISION. Standard C
* composition order for the numeric conversions: sign/prefix,
* then zero-fill (0-flag, only when no precision was given),
* then the digits, the whole thing then space-padded to WIDTH
* (left-justified with -, right-justified otherwise). #o forces
* a leading 0 if the digits don't already have one; #x/#X
* prepends "0x"/"0X" unless the value is 0. .0 of a value of 0
* prints NO digits at all (not even "0") for d/i/o/u/x/X, the
* one sharp corner XCU's own examples call out.
*
* ARGUMENTS ARE 16-BIT on this machine (its only integer size).
* A numeric conversion (d/i/o/u/x/X) PARSES its argument into
* one 16-bit register -- 0..65535 unsigned magnitude, or 0..
* 32768 magnitude behind a leading '-' (two's complement encode)
* -- and %d/%i then DISPLAY that same 16-bit bit pattern SIGNED
* while %u/%o/%x/%X display it UNSIGNED, exactly the way a real
* int16_t/uint16_t pun would on any machine: printf '%x' 40000
* (in unsigned range, out of int16 range) prints the bit
* pattern's hex, and printf '%d' 40000 prints it as a NEGATIVE
* decimal number. A magnitude that does not fit either encoding
* at all (over 65535, or over 32768 negated), OR an argument
* that isn't a decimal integer (POSIX's `'c`/`"c` leading-quote
* form is accepted: the following byte's value, low 7 bits) is
* THE SAME diagnosed condition here: a message to stderr, the
* value 0 is used, and the whole run's exit status is 1 -- but
* processing CONTINUES (XCU's own words: "shall continue
* processing any remaining arguments and shall proceed to the
* next format operand" is honoured by NOT aborting immediately).
*
* %b's OWN escapes (its ARGUMENT text, not the format string):
* the same \\\a\b\f\n\r\t\v set, plus \0ddd (a LITERAL '0' then
* up to 3 octal digits -- POSIX's own %b spelling, distinct from
* the format string's plain \ddd), and \c: "ignore any remaining
* characters in the string operand containing it, any remaining
* string operands, and any additional characters in the format
* operand" -- i.e. \c is a full stop, not just the end of one
* %b. PF_STOP below is checked after every directive and at the
* top of the format-reuse loop for exactly that reason.
*
* FORMAT REUSE: "the format operand shall be reused as often as
* necessary to satisfy the argument operands" -- reused only
* while (a) at least one argument remains AND (b) the format
* contains at least one argument-consuming conversion (%%
* itself does not count, nor does one that never appears at
* all) -- so `printf hi\\n a b c` prints "hi" exactly ONCE
* (matching GNU coreutils; this Mac's own /usr/bin/printf prints
* a diagnostic in that exact case instead, a BSD quirk this
* build does not reproduce, and not one the task's own e2e
* corpus exercises). A missing argument for a pass that DOES run
* is the empty string / 0, per the task's own rule.
*
* 3-4 KB target; `put`s printffmt.s/printfnum.s/printfcnv.s (the
* %-directive parser, the numeric parser/formatters and the
* per-conversion handlers/%b engine, respectively) for the
* native assembler's 16128-byte source window, same reason as
* cut.s/cutlist.s and xargs.s/xargstok.s -- THREE pieces here,
* not two, since the whole numeric engine alone ran ~22KB in one
* file (see printffmt.s's own header for the measurement).
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/printf.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

* -- printf-private zero page: $30-$3F, verified clear of zp.equ
* -- the kernel's $F7-$FC and every module this file `put`s, the
* -- same claim (and the same range) src/bin/xargstok.s already
* -- made and cited for this tree's modules -- printf `put`s a
* -- SUBSET of what xargs.s does (no getopt/pathres/env), so
* -- nothing new enters this window either.
PF_FMT      equ   $30            ;2 -- format-string scan cursor
PF_BARG     equ   $32            ;2 -- %b argument scan cursor

*---------------------------------------------------------------
* PER-RUN RESET -- a warm respawn reuses this bank; every flag a
* branch tests before this run writes it must be zeroed here
* (cut.s/xargs.s/grep.s's own START does the identical sweep).
* START MUST BE THE FIRST CODE AT LOAD_BASE (spawn() jumps there
* verbatim) -- a real bug caught here 2026-09-14: USAGEMSG's own
* bytes used to sit between `org LOAD_BASE` and this label, so
* LOAD_BASE held STRING DATA, not `stz BADNUM`, and every spawn
* began by executing that text as 6502 opcodes. It happened to
* fall through harmlessly on most cold loads (default A/X/Y/P
* from reset), which is exactly why it passed casual testing --
* but a WARM RESPAWN inherits the PREVIOUS run's leftover
* registers/flags into that same garbage prefix, and one
* concrete case reproduced it live: `PRINTF "%d\012" abc` (exits
* 1) immediately followed by a warm `PRINTF "A\101B\012C\012"`
* (no `%` at all, should exit 0) exited 1 instead -- correct
* OUTPUT, wrong STATUS, because BADNUM was never actually
* reached by `stz` at the top of that run. Fixed by moving every
* data constant (USAGEMSG included) after all real code, the
* same shape xargs.s's own XAOPTS/DEFECHO/USAGEMSG already keep.
*---------------------------------------------------------------
START       stz   BADNUM
            stz   PF_STOP
            stz   HASCONV
            lda   ARGC
            cmp   #2
            bcs   :haveall
            lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT
:haveall    lda   #1
            sta   ARGIDX            ;consumed argv[0] (the name)
            lda   #1
            jsr   GETARG            ;-> PTR0 = format operand
            lda   PTR0
            sta   FMTBASE
            lda   PTR0+1
            sta   FMTBASE+1
            lda   #2
            sta   ARGIDX          ;argv[2..] are conv args

            jsr   PF_PRESCAN      ;HASCONV, once, over the
                                  ;format (it never changes)

:pass       lda   FMTBASE
            sta   PF_FMT
            lda   FMTBASE+1
            sta   PF_FMT+1
            jsr   FMTSCAN
            lda   PF_STOP
            bne   :alldone        ;%b's \c -- full stop
            lda   HASCONV
            beq   :alldone        ;no conversion consumes an
                                  ;argument -- one pass, done,
                                  ;regardless of extra operands
            lda   ARGIDX
            cmp   ARGC
            bcc   :pass             ;more arguments -- reuse

:alldone    lda   BADNUM
            beq   :ok0
            lda   #1
            jsr   EXIT
:ok0        lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* PF_ADVFMT -- PF_FMT += 1. CLOBBERS: A.
*---------------------------------------------------------------
PF_ADVFMT   inc   PF_FMT
            bne   :rts1
            inc   PF_FMT+1
:rts1       rts

*---------------------------------------------------------------
* PF_EMIT1 -- write the byte in A to stdout via PUTC.
* CLOBBERS: A, X, Y (PUTC's own).
*---------------------------------------------------------------
PF_EMIT1    ldx   #FD_STDOUT
            jmp   PUTC

*---------------------------------------------------------------
* FMTSCAN -- one pass over the format string starting at PF_FMT,
* processing literal text, backslash escapes and %-directives,
* until NUL or PF_STOP. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
FMTSCAN     ldy   #0
            lda   (PF_FMT),y
            beq   :fdone
            cmp   #$DC              ;backslash
            beq   :fesc
            cmp   #$A5              ;'%'
            beq   :fpct
            jsr   PF_EMIT1
            jsr   PF_ADVFMT
            bra   FMTSCAN
:fesc       jsr   PF_ADVFMT       ;consume the backslash itself
            jsr   PF_DOESC
            bra   FMTSCAN
:fpct       jsr   PF_ADVFMT         ;consume '%'
            jsr   PF_DOCONV
            lda   PF_STOP
            bne   :fdone
            bra   FMTSCAN
:fdone      rts

*---------------------------------------------------------------
* PF_DOESC -- one FORMAT-STRING backslash escape; PF_FMT points
* at the byte right after the backslash. \\ \a \b \f \n \r \t \v
* and \ddd (1-3 octal digits, no leading 0 needed). An
* unrecognised letter is left UNCONSUMED (the backslash itself
* was already eaten by FMTSCAN, and the next byte falls through
* to FMTSCAN's own literal-byte path next time round -- this
* prints the backslash and then that byte, the common shell
* fallback for an escape nobody defined). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PF_DOESC    ldy   #0
            lda   (PF_FMT),y
            cmp   #$DC
            bne   :e2
            jsr   PF_ADVFMT
            lda   #$DC
            jmp   PF_EMIT1
:e2         cmp   #$E1              ;'a'
            bne   :e3
            jsr   PF_ADVFMT
            lda   #$87
            jmp   PF_EMIT1
:e3         cmp   #$E2              ;'b'
            bne   :e4
            jsr   PF_ADVFMT
            lda   #$88
            jmp   PF_EMIT1
:e4         cmp   #$E6              ;'f'
            bne   :e5
            jsr   PF_ADVFMT
            lda   #$8C
            jmp   PF_EMIT1
:e5         cmp   #$EE              ;'n'
            bne   :e6
            jsr   PF_ADVFMT
            lda   #$8D
            jmp   PF_EMIT1
:e6         cmp   #$F2              ;'r'
            bne   :e7
            jsr   PF_ADVFMT
            lda   #$8D
            jmp   PF_EMIT1
:e7         cmp   #$F4              ;'t'
            bne   :e8
            jsr   PF_ADVFMT
            lda   #$89
            jmp   PF_EMIT1
:e8         cmp   #$F6              ;'v'
            bne   :e9
            jsr   PF_ADVFMT
            lda   #$8B
            jmp   PF_EMIT1
:e9         cmp   #$B0
            bcc   :eunk
            cmp   #$B8
            bcs   :eunk
            jmp   PF_OCTESC
:eunk       rts

*---------------------------------------------------------------
* PF_OCTESC -- \ddd, up to 3 octal digits, PF_FMT at the first
* one (its char is still in A, already range-checked $B0-$B7 by
* PF_DOESC). Emits (value | $80). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PF_OCTESC   and   #$07
            sta   PF_OVAL
            jsr   PF_ADVFMT
            ldx   #1
:o2         cpx   #3
            beq   :o3
            ldy   #0
            lda   (PF_FMT),y
            cmp   #$B0
            bcc   :o3
            cmp   #$B8
            bcs   :o3
            and   #$07
            sta   PF_TMP
            lda   PF_OVAL
            asl   a
            asl   a
            asl   a
            clc
            adc   PF_TMP
            sta   PF_OVAL
            jsr   PF_ADVFMT
            inx
            bra   :o2
:o3         lda   PF_OVAL
            ora   #$80
            jmp   PF_EMIT1

USAGEMSG    asc   "usage: printf format [arguments ...]"
            dfb   $8D,0

            put   printffmt.s
            put   printfnum.s
            put   printfcnv.s

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/num.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* printf's bss -- `dum`/`dend` at the TEXTUAL END, anchored at
* LIBA_BSSEND (learning:01M0FNC75R7YSFRNS328WHXMHN). NOTHING
* ZEROES THIS ARENA (docs/STICKY.md sec 21): every cell a branch
* tests before this run writes it is zeroed explicitly in
* START/PF_PRESCAN/PF_DOCONV below, not left to a cold load's
* zero fill.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ARGIDX      ds    1
FMTBASE     ds    2
BADNUM      ds    1              ;stz'd in START
PF_STOP     ds    1              ;stz'd in START (%b's \c)
HASCONV     ds    1            ;stz'd in START; PF_PRESCAN sets
PF_OVAL     ds    1
PF_TMP      ds    1
PF_T3       ds    1
PF_MAG      ds    2
PF_HEXUP    ds    1
PF_CCHAR    ds    1
PF_CLEN     ds    1
PF_SLEN     ds    1
PF_ECNT     ds    1
PF_ECHAR    ds    1
PF_BADP     ds    2
PF_B0       ds    1
PF_B1       ds    1
PF_B2       ds    1
PF_NDIG     ds    1
PF_NSIGN    ds    1
PF_ADIG     ds    1
PF_AT0      ds    1
PF_AT1      ds    1
PF_AT2      ds    1
PF_ODIG     ds    6
HADARG      ds    1

* -- one %-directive's own state (stz'd fresh at PF_DOCONV's own
* -- entry -- see printffmt.s -- since a stale flag from a PRIOR
* -- directive in the SAME pass must never leak into the next).
PF_FLNEG    ds    1
PF_FLPLUS   ds    1
PF_FLSPC    ds    1
PF_FLHASH   ds    1
PF_FLZERO   ds    1
PF_WIDTH    ds    1
PF_HASPREC  ds    1
PF_PREC     ds    1
PF_CONVCH   ds    1

PF_NUMVAL   ds    2
PF_NEG      ds    1
PF_DIGZERO  ds    1
PF_SIGNOK   ds    1
PF_PFXMODE  ds    1
PF_PFXCH2   ds    1
PF_SIGNCH   ds    1
PF_PFXLEN   ds    1
PF_PFXBUF   ds    2
PF_DIGLEN   ds    1
PF_ZCOUNT   ds    1
PF_INNERLEN ds    1
PF_WPADZ    ds    1
PF_WPADS    ds    1
PF_TMP2     ds    1

DIGBUF      ds    7              ;up to 6 octal digits + NUL

* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window (cut.s/head.s's own note).
            err   */$BF00
            dend
