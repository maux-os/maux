*---------------------------------------------------------------
* chvt.s -- switch the active virtual console.
*
* Usage: chvt N        (N = 1..4, one-based, as a person counts)
*
* CONTRACT: write `ESC [ N z` to stdout and exit 0. A missing or
* out-of-range argument is a usage error on stderr, exit 2 --
* the
* KERNEL also refuses an out-of-range console (tty2.s
* TTY_CSI_VT), because a terminal must not be steerable by a
* stray byte in a text file, but a user who typos deserves to be
* told rather than silently ignored.
*
* WHY THIS IS A WRITE AND NOT A SYSCALL. maux has no ioctl, and
* console switching is not worth inventing one for on its own.
* The sequence rides the escape parser the tty already has, so
* this program needs no privilege and no new syscall number --
* and it is what makes switching reachable from a shell, which
* is what makes it TESTABLE: the Option-1..4 key trigger cannot
* be exercised from the host at all (verilogapple drives its
* button lines only inside reset), so a keyboard-only trigger
* would have shipped unproven. See docs/CONSOLE.md sec 13.
*
* Uses ONLY liba (src/liba) -- no direct syscalls, no raw gate
* address, no equates; see docs/USERLAND.md.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            put   ../../inc/sc.fdact.equ
            org   LOAD_BASE
            dsk   ../../build/chvt.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

START       lda   ARGC
            cmp   #2
            bne   :usage
            lda   #1
            jsr   GETARG                 ;-> PTR0 = argv[1]
            ldy   #0
            lda   (PTR0),y
            beq   :usage
            iny
            pha
            lda   (PTR0),y               ;exactly one digit: a
            bne   :usage2                ;console number is 1..4
            pla
            and   #$7F                 ;argv may be high-bit
            sec
            sbc   #'0'
            beq   :usagea                ;'0' is not a console
            cmp   #5
            bcs   :usagea                ;1..4 only
            sta   CVT_N
            stz   CVT_ERR                ;bss: warm keeps it
            jsr   CVT_LAZY               ;a console nobody reads
            lda   CVT_N                  ;is not a console
            clc
            adc   #'0'
            ora   #$80                 ;liba writes high-bit set
            pha
            lda   #$9B                 ;ESC
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$DB                 ;[
            ldx   #FD_STDOUT
            jsr   PUTC
            pla
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$FA                 ;z
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   CVT_ERR                ;0, or 1: no shell
            jmp   EXIT
:usage2     pla
:usagea
:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jmp   EXIT

*-- FOUR PUTCs RATHER THAN A PATCHED STRING. The first version
*-- assembled `ESC [ n z` as data and stored the digit into it,
*-- which made chvt's TEXT MUTABLE -- and check_purity refuses
*-- that without a declaration, correctly: lazy free reuses a
*-- bank without recopying its text (STICKY.md sec 29), so a
*-- program that rewrites itself cannot be reused. Emitting the
*-- four bytes directly costs nine bytes and leaves the image
*-- immutable, with no bss at all.
*-- The data CVT_LAZY reads, ABOVE it on purpose: CVT_TTYN is
*-- an `equ`, and real Merlin-8 refuses a forward reference to
*-- one outright (learning:01M05519PC55WGJNE4PY5HX4TH), which
*-- check-modules gates. Immutable text: the digit is appended
*-- into CVT_PATH in bss, never patched into this template.
CVT_TTYT    dfb   9
            asc   '/DEV/TTY'
CVT_TTYN    equ   *-CVT_TTYT
CVT_SHPTH   asc   "/bin/sh"
            dfb   $00
CVT_SHARG   asc   "SH"
            dfb   $00

*---------------------------------------------------------------
* CVT_LAZY -- give console CVT_N a shell if it has none.
*
* LAZY, and that is a ruling (operator, 2026-09-20: "lazy is the
* way. we support 4 at the most, but most people will find 2 or
* 3 plenty"). Spawning four shells at boot would renumber every
* pid and dozens of gates assert pid numbers; spawning one the
* first time a person actually goes to a console costs nothing
* until they do, and leaves the boot topology exactly as it was.
*
* Before this, `chvt 2` was a ONE-WAY TRIP: the display and the
* keyboard moved to a console nobody was reading, it echoed what
* you typed and ran none of it, and `chvt 1` typed there did not
* come back. Recovery was a reboot (docs/COVER-OFF.md).
*
* THE TEST IS ATTACHMENT, NOT BLOCKING, which is why it is a
* syscall (SYS_VCSTAT) and not a PSTAT scan here: a shell is
* asleep on its tty only while it sits at a prompt, and NOT for
* the whole time it is running a command -- which is exactly
* when a person switches away and comes back. Asking the wrong
* question would stack a second shell on a busy console and
* both would then read the same keyboard.
*
* A FAILURE TO GIVE THE CONSOLE A SHELL IS REPORTED, AND THE
* SWITCH STILL HAPPENS. Until 2026-10-31 every failure here was
* deliberately SILENT, on the argument that the switch itself
* still worked and a message on the console being left would be
* gone a moment later. The first half is true and is why the
* switch is NOT skipped (whether to switch back is the
* operator's call); the second half was wrong: the message is
* on the console being left, and it is THERE when the person
* comes back, which is the only time they are asking why the
* other console was dead. SC_SPAWN's refusal was not even
* tested (a full process table left a console with no shell,
* exit 0), and a full file table fails the OPEN the same way.
* Both say the machine's reason (liba/spawnwhy.s) or, for
* anything else,
* `cannot start a shell`; the exit status is 1. A VCSTAT that
* cannot answer stays silent: then nothing is known to be wrong.
*---------------------------------------------------------------
CVT_LAZY    lda   #<CVT_VCS
            sta   PTR0
            lda   #>CVT_VCS
            sta   PTR0+1
            jsr   SC_VCSTAT
            bcs   :lzret                 ;no answer: just switch
            ldx   CVT_N
            dex
            lda   CVT_VCS,x
            beq   :lzopen                ;nobody home: fix that
:lzret      rts                          ;(mid-routine so every
                                         ;early out is a SHORT
                                         ;backward branch)
:lzopen
*-- The path is BUILT IN DATA. Patching the digit into the
*-- template in place would make this program's TEXT mutable,
*-- which lazy free will not reuse -- the same trap the four
*-- PUTCs above exist to avoid.
            ldx   #0
:lzcp       lda   CVT_TTYT,x
            sta   CVT_PATH,x
            inx
            cpx   #CVT_TTYN
            bne   :lzcp
            lda   CVT_N
            clc
            adc   #'0'
            sta   CVT_PATH+CVT_TTYN
            lda   #PCOUNT_OPEN
            sta   CVT_OPRM
            lda   #<CVT_PATH
            sta   CVT_OPRM+1
            lda   #>CVT_PATH
            sta   CVT_OPRM+2
            stz   CVT_OPRM+3
            stz   CVT_OPRM+4
            lda   #<CVT_OPRM
            ldx   #>CVT_OPRM
            jsr   SC_OPEN
            bcs   :lzfail
*-- fdactions: the child's 0, 1 and 2 all become this console.
*-- FDACT_DUP resolves its SOURCE against OUR table, which is
*-- the only reason this works -- spawn zeroes a child's fd
*-- table, so fds are not inherited and cannot simply be left.
            ldx   #0
            ldy   #0
:lzfd       lda   #FDACT_DUP
            sta   CVT_FDA,x
            tya
            sta   CVT_FDA+1,x
            lda   CVT_OPRM+5             ;the refnum OPEN gave
            sta   CVT_FDA+2,x
            inx
            inx
            inx
            iny
            cpy   #3
            bne   :lzfd
            lda   #FDACT_END
            sta   CVT_FDA,x
            lda   #<CVT_SHARG
            sta   CVT_ARGV
            lda   #>CVT_SHARG
            sta   CVT_ARGV+1
            stz   CVT_ARGV+2
            stz   CVT_ARGV+3
            lda   #<CVT_SHPTH
            sta   PTR0
            lda   #>CVT_SHPTH
            sta   PTR0+1
            lda   #<CVT_ARGV
            sta   PTR1
            lda   #>CVT_ARGV
            sta   PTR1+1
            lda   #<CVT_FDA
            sta   PTR2
            lda   #>CVT_FDA
            sta   PTR2+1
            stz   SPWN_ENVP              ;uncleared storage, not
            stz   SPWN_ENVP+1            ;a sticky setting
            jsr   SC_SPAWN
            bcs   :lzfail
*-- our own fd is left open: EXIT closes it, and closing it here
*-- would only ask a refcount question we do not need to ask.
            rts
*-- A = the errno either call refused with. The switch goes on.
:lzfail     ldx   #<CVT_PFX
            ldy   #>CVT_PFX
            jsr   SPAWNWHY
            bcs   :lzbad
            lda   #<CVT_NOSH
            sta   PTR0
            lda   #>CVT_NOSH
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
:lzbad      lda   #1
            sta   CVT_ERR
            rts

USAGEMSG    asc   "usage: chvt N   (N = 1..4)"
            dfb   $00
CVT_PFX     asc   'chvt: '
            dfb   0
CVT_NOSH    asc   'chvt: cannot start a shell'
            dfb   $0D,0

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/spawnwhy.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* chvt's bss. It had none until 2026-09-20, when it learned to
* spawn a shell on a console that has not got one; the escape
* sequence itself is still emitted byte by byte and this
* program's text is still immutable. The arena-end tripwire is
* the only thing that catches liba growing the process image
* past $BF00, which check_modules' image-window gate cannot see
* because a `dum` arena emits no bytes.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
CVT_N       ds    1              ;console 1..4, parsed once
CVT_ERR     ds    1              ;exit status (1: no shell)
CVT_VCS     ds    4              ;SYS_VCSTAT's answer, VC_COUNT
CVT_PATH    ds    10             ;/DEV/TTYn, length-prefixed
CVT_OPRM    ds    6              ;MLI OPEN parm (+5 = ref)
CVT_ARGV    ds    4              ;{ "SH", NULL }
CVT_FDA     ds    10             ;3 x FDACT_DUP + FDACT_END
            err   */$BF00
            dend
