*---------------------------------------------------------------
* shutdown.s -- stop maux cleanly.
*
* Usage: shutdown
*
* WHAT IT IS FOR. Until this existed there was no way to stop
* this machine that was not a reset or a power switch, and both
* of those leave whatever ProDOS had not written back unwritten.
* `shutdown` closes every open file first, which is the whole
* point: ProDOS flushes dirty index and directory blocks on
* CLOSE, and a volume that missed that looks fine until the next
* `ls` of a directory somebody wrote to.
*
* THE SPLIT WITH THE KERNEL. This program owns the words and
* nothing else. Every resource that has to be given up -- the
* open files, the periodic interrupt source, the display
* switches -- belongs to the kernel, so SYS_HALT (PRC_HALT,
* src/kernel/procfile3.s) does the work and this does the
* announcing. Same shape as `chvt`: the verb is a program, the
* mechanism is a call.
*
* ORDER MATTERS HERE, not just in the kernel. The message is
* printed AND FLUSHED before SC_HALT, because after the call
* there is no console to print to -- the glass has gone back to
* the motherboard and the kernel is spinning with interrupts
* masked. A `shutdown` that announced itself afterwards would be
* silent, and would look like a hang.
*
* NO OPERANDS, NO OPTIONS, deliberately. POSIX does not specify
* shutdown at all; the Unix ones take a time argument and a
* -r/-h choice, and both of those mean something here that maux
* cannot yet do. A time argument implies warning logged-in users
* on a single-user machine with nobody to warn. `-r` (reboot)
* needs the ROM back at $FFFC, which means a read-ROM language-
* card select, which docs/LANGUAGE-CARD.md's ratchet reserves
* for exactly two addresses that are not it -- that window is
* `bye`'s to open (docs/BYE.md), and `-r` should land with it
* rather than buying a gate exemption on its own. Until then
* Ctrl-Reset is the reboot, and it works from the halted state
* because maux never took $03F2.
*
* An operand is refused with usage and exit 2, the tree's
* uniform rule for a utility whose SYNOPSIS has none (tty.s,
* uname.s -- and see tty.s's note on the two hosts disagreeing).
*
* EXIT STATUS. There isn't one on the success path and cannot
* be: SC_HALT does not return, so nothing is left to exit. The
* only `jmp EXIT` below is the refusal.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/shutdown.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

START       lda   ARGC
            cmp   #1
            bne   :usage
            lda   #<DOWNMSG
            sta   PTR0
            lda   #>DOWNMSG
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            jsr   SIO_FLUSHALL    ;SAY IT BEFORE YOU DO IT --
                                  ;see the header. EXIT would
                                  ;have done this and there is
                                  ;no EXIT on this path.
            lda   #HALT_DOWN
            jsr   SC_HALT
*-- Only reachable if the kernel refused the call, which on a
*-- kernel that has SYS_HALT it cannot. Exit loudly rather than
*-- falling into whatever follows.
            lda   #<FAILMSG
            sta   PTR0
            lda   #>FAILMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jmp   EXIT

:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jmp   EXIT

DOWNMSG     asc   "System halted -- it is safe to reset."
            dfb   $8D,$00
FAILMSG     asc   "shutdown: kernel refused SYS_HALT"
            dfb   $8D,$00
USAGEMSG    asc   "usage: shutdown"
            dfb   $8D,$00

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* shutdown's bss -- none of its own. `dum`/`dend` runs only the
* arena-end tripwire, anchored at LIBA_BSSEND (tty.s's trailer,
* verbatim, for a utility with the same shape).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
