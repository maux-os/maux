*---------------------------------------------------------------
* basename.s -- the last component of a pathname.
*
* Usage: basename string [suffix]
*
* THE XCU ALGORITHM (POSIX.1-2024 basename.html), one operand,
* not the BSD -a/-s multi-string form (host /usr/bin/basename
* accepts more than one bare string as if -a were implied; that
* leniency is out of scope here -- POSIX's own SYNOPSIS is just
* "basename string [suffix]", ONE string, and this machine's own
* -a/-s are KNOWN_GAPS rows, not silently-accepted syntax):
*   1. string is empty -> print an empty line, done.
*   2. string is entirely slashes -> "/" (this build follows the
*      host for "//": both print "/", not "//" -- POSIX leaves
*      that case implementation-defined).
*   3. strip trailing slashes.
*   4. remove everything up to and including the last remaining
*      slash -- what is left is the base.
*   5. if a suffix operand was given, it is not identical to the
*      base, and it is a real trailing suffix of the base, strip
*      it too. An empty suffix, or one at least as long as the
*      base, is never stripped (checked live against this host's
*      /usr/bin/basename: `basename foo.txt ""`, `basename foo
*      .txtlong` and `basename foo.txt foo.txt` all leave the
*      base untouched).
*
* Paths here are ProDOS-style VOLUME/DIR/FILE with the SAME '/'
* separator Unix uses, so the algorithm above applies with no
* translation -- this is text arithmetic, never a filesystem
* lookup (no OPEN, no MLI call of any kind).
*
* 8-BIT LENGTHS. A single argv WORD is bounded by ARG_MAX in
* practice (a handful of bytes), far under 256 -- every offset
* here is one byte, matching src/liba/pathres.s's PRS_BUFSZ (65)
* and mli.s's own path-length convention. A string that reaches
* WBUFSZ (96) bytes after trimming is refused with a diagnostic
* rather than silently truncated.
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
            dsk   ../../build/basename.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

WBUFSZ      equ   96                ;output copy buffer -- see
                                    ;header

START       lda   ARGC
            cmp   #2
            bcs   :havemin           ;need at least STRING
            jmp   :usage
:havemin    cmp   #4
            bcc   :havemax           ;STRING [SUFFIX] only
            jmp   :usage
:havemax    lda   #1
            jsr   GETARG              ;PTR0 = argv[1] (STRING)
            lda   PTR0
            sta   BN_STRP
            lda   PTR0+1
            sta   BN_STRP+1

*-- LEN: scan for the NUL. Capped at 255 (see header).
            ldy   #0
:lenlp      lda   (PTR0),y
            beq   :lendone
            iny
            bne   :lenlp
:lendone    sty   BN_LEN
*-- RELOAD before testing: STY sets no flags on 6502 -- the Z
*-- flag here is still the LOOP'S OWN (always 1, from the `beq`
*-- that got us here), so a bare `bne` after `sty` always took
*-- the empty-string branch regardless of the real length. Found
*-- by check-posixutil: every basename case, not only the empty
*-- one, came back as an empty line.
            lda   BN_LEN
            bne   :nonempty
            jmp   :printnl           ;empty string -> empty line

*-- entirely slashes?
:nonempty   ldy   #0
:allsl      lda   (PTR0),y
            cmp   #$AF               ;'/' high-bit
            bne   :notall
            iny
            cpy   BN_LEN
            bcc   :allsl
            jmp   :rootcase          ;every byte was '/'
:notall

*-- strip trailing slashes: END = LEN, then walk back.
            lda   BN_LEN
            sta   BN_END
:striptr    lda   BN_END
            beq   :stripd
            sec
            sbc   #1
            tay
            lda   (PTR0),y
            cmp   #$AF
            bne   :stripd
            sty   BN_END
            bra   :striptr
:stripd

*-- forward scan [0,END): START = index right after the LAST
*-- slash seen, or 0 if none.
            stz   BN_START
            ldy   #0
:findsl     cpy   BN_END
            bcs   :findsd
            lda   (PTR0),y
            cmp   #$AF
            bne   :fsnext
            iny
            sty   BN_START
            bra   :findsl
:fsnext     iny
            bra   :findsl
:findsd

*-- optional suffix, argv[2]. GETARG clobbers PTR0 -- BN_STRP
*-- already holds the base string's pointer for restoring.
            lda   ARGC
            cmp   #3
            bcc   :dostrip           ;no suffix operand
            lda   #2
            jsr   GETARG
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
            lda   BN_STRP
            sta   PTR0
            lda   BN_STRP+1
            sta   PTR0+1

*-- suffix length
            ldy   #0
:suflp      lda   (PTR1),y
            beq   :sufdone
            iny
            bne   :suflp
:sufdone    sty   BN_SUFLEN
*-- Same STY-sets-no-flags reload as :lendone above.
            lda   BN_SUFLEN
            beq   :dostrip           ;empty suffix -> no strip

*-- BASELEN = END - START; a suffix must be strictly shorter to
*-- ever be "not identical to the remaining characters".
            lda   BN_END
            sec
            sbc   BN_START
            sta   BN_BASELN
            lda   BN_SUFLEN
            cmp   BN_BASELN
            bcs   :dostrip           ;SUFLEN >= BASELEN: no

*-- compare the base's last SUFLEN bytes against the suffix.
            lda   BN_END
            sec
            sbc   BN_SUFLEN
            sta   BN_CMPPOS
            stz   BN_SUFI
:cmplp      lda   BN_SUFI
            cmp   BN_SUFLEN
            bcs   :cmpok
            clc
            adc   BN_CMPPOS
            tay
            lda   (PTR0),y
            ldy   BN_SUFI
            cmp   (PTR1),y
            bne   :dostrip           ;mismatch -- no strip
            inc   BN_SUFI
            bra   :cmplp
:cmpok      lda   BN_END
            sec
            sbc   BN_SUFLEN
            sta   BN_END

:dostrip
*-- copy [START,END) to WORKBUF, NUL-terminate, print + CR.
            ldy   BN_START
            ldx   #0
:cpylp      cpy   BN_END
            bcs   :cpyd
            cpx   #WBUFSZ-1
            bcs   :toolong
            lda   (PTR0),y
            sta   WORKBUF,x
            iny
            inx
            bra   :cpylp
:cpyd       stz   WORKBUF,x
            lda   #<WORKBUF
            sta   PTR0
            lda   #>WORKBUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
:printnl    lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #0
            jsr   EXIT

:rootcase   lda   #$AF               ;'/' high-bit
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #0
            jsr   EXIT

:toolong    lda   #<TOOLONGMS
            sta   PTR0
            lda   #>TOOLONGMS
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

USAGEMSG    asc   "usage: basename string [suffix]"
            dfb   $8D,$00
TOOLONGMS   asc   "basename: string too long"
            dfb   $8D,$00

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* basename's own scalars, `dum`/`dend` off LIBA_BSSEND -- no
* `ds` zeros needed (docs/STICKY.md sec 21): every cell below is
* write-before-read.
*  - BN_STRP: START's own first store, before anything reads it.
*  - BN_LEN/BN_END/BN_START: each written before its own first
*    read (the length scan, the strip loop, the forward scan).
*  - BN_SUFLEN/BN_BASELN/BN_CMPPOS/BN_SUFI: written on the
*    suffix path only, each before its own reader.
*  - WORKBUF: filled byte-by-byte by :cpylp, indexed only up to
*    the NUL :cpyd writes.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
BN_STRP     ds    2
BN_LEN      ds    1
BN_END      ds    1
BN_START    ds    1
BN_SUFLEN   ds    1
BN_BASELN   ds    1
BN_CMPPOS   ds    1
BN_SUFI     ds    1
WORKBUF     ds    WBUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window.
            err   */$BF00
            dend
