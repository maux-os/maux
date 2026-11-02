*---------------------------------------------------------------
* reset.s -- reinitialise a wedged terminal.
*
* Usage: reset          (no arguments)
*
* CONTRACT: put the console back to a sane state after a program
* left it raw -- a crashed or killed vi, or anything that set
* cbreak/noecho and did not restore it (SIGTERM is not
* trappable, so it cannot). Two steps, both best-effort:
*   1. SC_TTYMODE(stdout, ICANON+ECHO+OPOST) -- cooked line +
*      echo + CR-is-a-newline, so the shell's own line editing
*      works again (same value `stty sane` writes).
*   2. write ESC c (RIS) -- the tty's own TTY_TRM_RESET clears
*      VC_ATTR (normal video), clears the body, and homes the
*      cursor (tty2.s), so a screen left mid-repaint comes back
*      clean.
* Always exits 0: reset's whole job is to recover, so a stdout
* that is not a tty (redirected) is not worth failing over --
* the mode call simply no-ops and the ESC c lands harmlessly.
*
* WHY A WRITE + ONE SYSCALL, NOT A NEW SYSCALL. The display half
* rides the escape parser the tty already has (like chvt.s), and
* the mode half is the SC_TTYMODE `stty` already uses -- so
* reset needs no privilege and no new syscall number. ESC c is
* RIS, the classic terminal reset; maux's console honours it
* (tty2.s :notrestore).
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
            org   LOAD_BASE
            dsk   ../../build/reset.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

START       lda   #FD_STDOUT
            ldx   #TMD_ICANON+TMD_ECHO+TMD_OPOST
            jsr   SC_TTYMODE            ;cooked+echo+opost;
                                        ;ignore err (not a tty)
            lda   #$9B                  ;ESC
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$E3                  ;'c' (high-bit) -- RIS
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #0
            jmp   EXIT

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* reset has no bss of its own. The `dum` arena is still declared
* so the arena-end tripwire runs -- the only thing that catches
* liba growing the process image past $BF00 (a `dum` arena emits
* no bytes, so check_modules' image-window gate cannot see it).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
            err   */$BF00
            dend
