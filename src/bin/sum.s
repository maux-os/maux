*---------------------------------------------------------------
* sum.s -- checksum and block count. V6-style.
*
* Usage: sum [file...]
*
* Prints "checksum blocks name" per file to stdout. No file ->
* fd 0, and the name column is omitted (same no-args shape as
* wc.s/cat.s). A file that cannot be opened prints "sum: cannot
* open <name>" to stderr and is SKIPPED, same as wc.s.
*
* ALGORITHM (state exactly which variant, per this task's own
* brief -- V7 changed sum's algorithm, so `sum` output is not
* portable across Unix versions and this header is what defines
* OURS): a 16-bit accumulator, rotated right ONE BIT before each
* byte is added in mod 65536 --
*
*   checksum = ROR16(checksum)
*   checksum = (checksum + byte) & $FFFF
*
* ROR16 means: shift the 16-bit value right one bit, and the bit
* that falls out of bit 0 becomes the new bit 15 (a genuine
* 16-bit rotate, not a plain shift) -- the historical V7/BSD
* `sum` algorithm (`sum -r` in later, multi-algorithm sum(1)s).
* Printed as a zero-padded 5-digit decimal (0-65535).
*
* BLOCKS: ceil(bytes / 512) -- 512 to match a ProDOS block, this
* project's own unit (docs/PROCIO.md's K1). An empty file is 0
* blocks, a 1-byte file is 1, a 513-byte file is 2 (crosses the
* boundary). Printed as a plain (non-padded) decimal via PRNUM.
*
* WHY THIS TOOL MATTERS HERE beyond fidelity: check-dual/check-
* as/check-ld are all "byte-identical or fail", and today that
* check is a HOST-SIDE Python script. `sum` puts that same
* verification on the machine that is supposedly assembling
* itself.
*
* COUNTER WIDTH: byte count saturates at 65535 (wc.s's own
* documented tradeoff -- a 64K file is already bigger than a
* process bank).
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
            dsk   ../../build/sum.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255
BLOCKSZ     equ   512
BLOCKSZM1   equ   511    ;BLOCKSZ-1 -- no parens in Merlin exprs

START       stz   ERRFLAG
            lda   ARGC
            cmp   #1
            bne   :havefile
            ; ARGC==1: only argv[0] (the program name) -- no
            ; FILE args, same convention cat.s uses.
            lda   #FD_STDIN
            sta   SRCFD
            jsr   SUMFD
            stz   NAMEFLG
            jsr   REPORT
            lda   #0
            jsr   EXIT

:havefile   lda   #1
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
            bcs   :openerr
            lda   OPARM_REF
            sta   SRCFD
            jsr   SUMFD
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
            lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* SUMFD -- checksum SRCFD into CKVAL/BYTES.
*---------------------------------------------------------------
SUMFD       stz   CKVAL
            stz   CKVAL+1
            stz   BYTES
            stz   BYTES+1
            stz   BUFPOS
            stz   BUFLEN
:loop       jsr   GETBYTE
            bcs   :done
            jsr   ROTCK
            clc
            adc   CKVAL
            sta   CKVAL
            lda   CKVAL+1
            adc   #0
            sta   CKVAL+1
            jsr   BUMPBYTES
            bra   :loop
:done       rts

*---------------------------------------------------------------
* BUMPBYTES -- BYTES++, saturating at $FFFF rather than
* wrapping (wc.s's BUMP makes the same tradeoff, same reason: a
* wrapped count reads as a plausible wrong answer, a saturated
* one is visibly pinned).
*---------------------------------------------------------------
BUMPBYTES   lda   BYTES
            cmp   #$FF
            bne   :inclo
            lda   BYTES+1
            cmp   #$FF
            beq   :pinned
:inclo      inc   BYTES
            bne   :out
            inc   BYTES+1
:out        rts
:pinned     rts

*---------------------------------------------------------------
* ROTCK -- rotate CKVAL right one bit (16-bit ROR, wrapping bit
* 0 into bit 15). Byte just read from GETBYTE is still in A on
* entry, untouched, so the caller's ADC sees it after this call.
*---------------------------------------------------------------
ROTCK       pha
            lsr   CKVAL+1
            ror   CKVAL
            bcc   :noc
            lda   CKVAL+1
            ora   #$80
            sta   CKVAL+1
:noc        pla
            rts

*---------------------------------------------------------------
* REPORT -- print "CCCCC B[..] name", CR-terminated. CCCCC is
* CKVAL zero-padded to 5 digits (PR5); B is BYTES/BLOCKSZ
* rounded up, plain decimal (PRNUM). Name column only if
* NAMEFLG.
*---------------------------------------------------------------
REPORT      ldx   #FD_STDOUT
            jsr   PR5
            jsr   PRSPACE
            jsr   BLOCKS
            lda   BLKVAL
            sta   U2DEC_VAL
            lda   BLKVAL+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            lda   NAMEFLG
            beq   :nonm
            jsr   PRSPACE
            lda   ARGIDX
            jsr   GETARG
            ldx   #FD_STDOUT
            jsr   PUTS
:nonm       lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

PRSPACE     lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* BLOCKS -- BLKVAL = ceil(BYTES / BLOCKSZ), BLOCKSZ = 512 = 2^9.
* (BYTES+511) >> 9, via 9 shifts of the 16-bit pair -- no divide
* instruction on 6502/65C02, same reason num.s's U2DEC is
* subtraction-based.
*---------------------------------------------------------------
BLOCKS      clc
            lda   BYTES
            adc   #<BLOCKSZM1
            sta   BLKVAL
            lda   BYTES+1
            adc   #>BLOCKSZM1
            sta   BLKVAL+1
            ldx   #9
:shift      lsr   BLKVAL+1
            ror   BLKVAL
            dex
            bne   :shift
            rts

*---------------------------------------------------------------
* PR5 -- print CKVAL as 5 zero-padded decimal digits to fd X.
* Same table-driven subtraction as liba's U2DEC (num.s), but
* every digit is emitted -- sum's field never suppresses leading
* zeros, unlike a plain number. CLOBBERS CKVAL (sub'd to 0).
*---------------------------------------------------------------
POW10S      da    10000
            da    1000
            da    100
            da    10
            da    1

PR5         stx   PR5FD
            ldy   #0
:digitloop  stz   PR5DIG
:sub10      lda   POW10S,y
            sta   PR5SUB
            lda   POW10S+1,y
            sta   PR5SUB+1
            lda   CKVAL+1
            cmp   PR5SUB+1
            bcc   :nodig
            bne   :dosub
            lda   CKVAL
            cmp   PR5SUB
            bcc   :nodig
:dosub      sec
            lda   CKVAL
            sbc   PR5SUB
            sta   CKVAL
            lda   CKVAL+1
            sbc   PR5SUB+1
            sta   CKVAL+1
            inc   PR5DIG
            bra   :sub10
:nodig      lda   PR5DIG
            ora   #$B0
            ldx   PR5FD
            jsr   PUTC
            iny
            iny
            cpy   #10
            bne   :digitloop
            rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as wc.s/grep.s.
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

ERRMSG      asc   "sum: cannot open "
            dfb   $00

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
            put   ../liba/num.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* sum's bss -- `dum`/`dend` at the TEXTUAL END, anchored at
* LIBA_BSSEND rather than `*`
* (learning:01M0FNC75R7YSFRNS328WHXMHN). 336 bytes that were
* emitted zeros. The three parmlists stay above as initialised
* data; `da PATHBUF` / `da CBUF` resolve into this arena.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - ERRFLAG: `stz` as START's first instruction.
*  - SRCFD: written on both the stdin and per-file paths.
*  - ARGIDX: `sta` at :havefile. On the stdin path its only
*    reader sits behind `lda NAMEFLG / beq`, and NAMEFLG is
*    `stz`'d first -- so that read is unreachable, not merely
*    unreached.
*  - NAMEFLG: written once per REPORT call.
*  - BUFPOS/BUFLEN: `stz`'d by SUMFD, PER FILE -- which makes
*    the argv loop correct and makes GETBYTE's `pos >= len`
*    refill test a decision rather than an accident.
*  - CKVAL/BYTES: `stz`'d by SUMFD, PER FILE. These are the
*    accumulators, and they are explicitly cleared rather than
*    relying on a zero start.
*  - BLKVAL: `sta`'d by BLOCKS before its own shift loop and
*    before REPORT reads it.
*  - PR5FD/PR5DIG/PR5SUB: PR5 stores each at its head before
*    its own later read.
*  - PATHBUF: MKPATH writes chars then the count byte; the MLI
*    reads only count+1. Untouched on the stdin path.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
SRCFD       ds    1
ARGIDX      ds    1
ERRFLAG     ds    1
NAMEFLG     ds    1
BUFPOS      ds    1
BUFLEN      ds    1

CKVAL       ds    2
BYTES       ds    2
BLKVAL      ds    2

PR5FD       ds    1
PR5DIG      ds    1
PR5SUB      ds    2

PATHBUF     ds    65
CBUF        ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
