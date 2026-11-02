*---------------------------------------------------------------
* echo.s -- print arguments.
*
* CONTRACT: print every argument (argv[1]..argv[argc-1]),
* separated by a single space, followed by one CR, to stdout (fd
* 1). No arguments beyond the program name -> just a CR.
*
* -n (FLEET F.2, 2026-09-01): a FIRST argument of exactly "-n"
* suppresses the trailing CR and is not printed -- the one flag
* scripts prompt with (`echo -n 'ok? '`). Only argv[1], only
* exactly "-n": `echo a -n` prints "a -n", and `echo -n` alone
* prints nothing at all, both the reference's behaviour
* (measured, /bin/echo). No escape processing -- that stays out
* of scope (docs/ARCHITECTURE.md "V1 userland").
*
* Uses ONLY liba (src/liba) -- no direct syscalls, no raw gate
* address, no equates; see docs/USERLAND.md and syscalls.s's
* header for why.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
                                              ;LOAD_BASE etc.
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE              ;ratified:
                                         ;docs/MEMMAP.md #3.1
            dsk   ../../build/echo.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

*---------------------------------------------------------------
* Entry: spawn() JMPs to the first byte of the loaded image (see
* docs/inc/startup.equ and docs/USERLAND.md "process entry").
* No stack/ interrupt setup here -- assumed established by
* spawn() per the trapframe/ exit-tail contract in
* ARCHITECTURE.md; flagged as an open question in
* docs/USERLAND.md "ABI FRICTION" since nothing has actually
* ruled on it.
*---------------------------------------------------------------
START       stz   NFLAG
            lda   ARGC
            cmp   #1
            bne   :chkflag
            bra   :printnl               ;no args beyond argv[0]

*-- exactly "-n" in argv[1], nothing else, is the flag.
:chkflag    lda   #1
            jsr   GETARG
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD                   ;'-' high-bit
            bne   :haveargs
            iny
            lda   (PTR0),y
            cmp   #$EE                   ;'n' high-bit
            bne   :haveargs
            iny
            lda   (PTR0),y
            bne   :haveargs              ;"-nx": an operand
            lda   #1
            sta   NFLAG
            lda   ARGC
            cmp   #2
            beq   :nonl                  ;`echo -n` alone: print
                                         ;NOTHING, not a CR
            lda   #2
            sta   ARGIDX
            bra   :looparg

:haveargs   lda   #1
            sta   ARGIDX
:looparg    lda   ARGIDX
            jsr   GETARG                 ;-> PTR0 = argv[ARGIDX]
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   ARGIDX
            clc
            adc   #1
            cmp   ARGC
            bcs   :printnl               ;just printed the last
                                         ;argument
            sta   ARGIDX
            lda   #$A0                   ; space, high-bit-set
            ldx   #FD_STDOUT
            jsr   PUTC
            bra   :looparg

:printnl    lda   NFLAG                  ;-n: stop before the CR
            bne   :nonl
            lda   #$8D                   ;CR, high-bit-set
                                         ;(Apple II line end)
            ldx   #FD_STDOUT
            jsr   PUTC
:nonl       lda   #0
            jsr   EXIT

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* echo's bss -- one byte, but it goes through the same door as
* everything else: `dum`/`dend` at the TEXTUAL END, anchored at
* LIBA_BSSEND rather than `*`
* (learning:01M0FNC75R7YSFRNS328WHXMHN).
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - ARGIDX: `lda #1 / sta ARGIDX` at :haveargs, before the
*    first :looparg read. The other path (ARGC == 1, straight
*    to :printnl) neither reads nor writes it.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ARGIDX      ds    1
NFLAG       ds    1              ;-n: no trailing CR (stz in
                                 ;START's first instruction)
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
