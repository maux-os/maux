*---------------------------------------------------------------
* dirname.s -- everything but the last component of a pathname.
*
* Usage: dirname string
*
* THE XCU ALGORITHM (POSIX.1-2024 dirname.html), ONE operand --
* host /usr/bin/dirname also accepts more than one bare string
* (one line each), a BSD leniency this build does not follow:
* POSIX's own SYNOPSIS is "dirname string", singular, and a
* second operand here is a usage error rather than silently
* accepted syntax (same posture as basename.s's own header).
*   1. string is entirely slashes -> "/" (host-matched: "//" and
*      "///" both print "/", not "//" -- POSIX leaves that case
*      implementation-defined).
*   2. strip trailing slashes.
*   3. if no slash remains -> "." (this also covers the empty
*      string: checked live, host /usr/bin/dirname prints "."
*      for "").
*   4. remove the trailing non-slash characters (the last
*      component).
*   5. strip trailing slashes again.
*   6. if nothing is left -> "/"; otherwise print what remains.
*
* Paths here are ProDOS-style VOLUME/DIR/FILE with the SAME '/'
* separator Unix uses, so the algorithm applies with no
* translation -- text arithmetic only, never a filesystem lookup
* (no OPEN, no MLI call of any kind).
*
* 8-BIT LENGTHS -- same convention and the same reasoning as
* src/bin/basename.s's own header (ARG_MAX bounds one argv word
* far under 256; src/liba/pathres.s's PRS_BUFSZ is 65).
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
            dsk   ../../build/dirname.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

WBUFSZ      equ   96                ;output copy buffer

START       lda   ARGC
            cmp   #2
            beq   :haveone           ;exactly one operand
            jmp   :usage
:haveone    lda   #1
            jsr   GETARG              ;PTR0 = argv[1] (STRING)

*-- LEN: scan for the NUL. Capped at 255 (see header).
            ldy   #0
:lenlp      lda   (PTR0),y
            beq   :lendone
            iny
            bne   :lenlp
:lendone    sty   DN_LEN
*-- RELOAD before testing: STY sets no flags on 6502 -- see
*-- src/bin/basename.s's own :lendone comment for the bug this
*-- fixes (found by check-posixutil: every dirname case, not
*-- only the no-slash one, came back as ".").
            lda   DN_LEN
            bne   :nonempty
            jmp   :dotcase           ;empty string -> "."

*-- entirely slashes?
:nonempty   ldy   #0
:allsl      lda   (PTR0),y
            cmp   #$AF               ;'/' high-bit
            bne   :notall
            iny
            cpy   DN_LEN
            bcc   :allsl
            jmp   :rootcase          ;every byte was '/'
:notall

*-- strip trailing slashes: END = LEN, then walk back.
            lda   DN_LEN
            sta   DN_END
:strip1     lda   DN_END
            beq   :strip1d
            sec
            sbc   #1
            tay
            lda   (PTR0),y
            cmp   #$AF
            bne   :strip1d
            sty   DN_END
            bra   :strip1
:strip1d

*-- any slash left in [0,END)? If not, "."
            ldy   #0
            stz   DN_HAVESL
:hassl      cpy   DN_END
            bcs   :hassld
            lda   (PTR0),y
            cmp   #$AF
            bne   :hsnext
            lda   #1
            sta   DN_HAVESL
:hsnext     iny
            bra   :hassl
:hassld     lda   DN_HAVESL
            bne   :haveslash
            jmp   :dotcase

*-- find the LAST slash in [0,END); cut there (component removed
*-- keeps the slash itself, stripped again below).
:haveslash  ldy   #0
:findsl     cpy   DN_END
            bcs   :findsd
            lda   (PTR0),y
            cmp   #$AF
            bne   :fsnext
            iny
            sty   DN_END2
:fsnext     iny
            bra   :findsl
:findsd

*-- strip trailing slashes from [0,END2).
:strip2     lda   DN_END2
            beq   :strip2d
            sec
            sbc   #1
            tay
            lda   (PTR0),y
            cmp   #$AF
            bne   :strip2d
            sty   DN_END2
            bra   :strip2
:strip2d    lda   DN_END2
            bne   :emit
            jmp   :rootcase          ;nothing left -> "/"

*-- print [0,END2), a CR, exit 0.
:emit       ldy   #0
            ldx   #0
:cpylp      cpy   DN_END2
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
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #0
            jsr   EXIT

:dotcase    lda   #$AE               ;'.' high-bit
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$8D
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

USAGEMSG    asc   "usage: dirname string"
            dfb   $8D,$00
TOOLONGMS   asc   "dirname: string too long"
            dfb   $8D,$00

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* dirname's own scalars, `dum`/`dend` off LIBA_BSSEND -- no `ds`
* zeros needed (docs/STICKY.md sec 21): every cell below is
* write-before-read.
*  - DN_LEN/DN_END/DN_END2/DN_HAVESL: each written before its
*    own first read (the length scan, the two strip loops, the
*    has-a-slash-left check).
*  - WORKBUF: filled byte-by-byte by :cpylp, indexed only up to
*    the NUL :cpyd writes.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
DN_LEN      ds    1
DN_END      ds    1
DN_END2     ds    1
DN_HAVESL   ds    1
WORKBUF     ds    WBUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window.
            err   */$BF00
            dend
