*---------------------------------------------------------------
* envprobe.s -- the `make check-env` gate's child process
* (docs/SYSCALL.md item 13c). Reads its own environment through
* src/liba/env.s's GETENV and reports, one line per argument:
*
*   NAME=VALUE   the variable reached this process
*   NAME?        no such variable in this process
*
* BOTH answers are printed, on purpose. The gate that matters is
* not "an exported variable arrives" -- it is "an exported one
* arrives AND an unexported one does not", and a probe that
* printed only what it found would let the second half pass by
* printing nothing at all, which is also what a probe with a
* broken GETENV prints.
*
* A src/test program, not a src/bin one: `env` as a COMMAND is
* explicitly out of scope in ruling 13c, and this is a test
* fixture in the same class as src/test/bufwriter.s and
* src/test/seekwr.s -- real liba-linked programs that exist to
* be spawned by a gate.
*
* Exit status: 0 always. The bytes are the verdict; a status
* would only be a second, weaker copy of them.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/envprobe.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

START       lda   #1
            sta   EPIDX
:loop       lda   EPIDX
            cmp   ARGC
            bcs   :done
            jsr   EP_ONE
            inc   EPIDX
            bra   :loop
:done       lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* EP_ONE -- one argument: look it up, then print the name and
* either "=VALUE" or "?". The lookup runs FIRST because GETENV
* needs PTR0 to still be the name, and printing it would be the
* one thing between them that could disturb it.
*---------------------------------------------------------------
EP_ONE      lda   EPIDX
            jsr   GETARG                 ;-> PTR0 = the name
            jsr   GETENV                 ;-> PTR1 = the value
            bcs   :unset
            lda   PTR1                   ;hold it: PUTS is about
            sta   EPVAL                  ;to use PTR0, and the
            lda   PTR1+1                 ;name has to go first
            sta   EPVAL+1
            lda   EPIDX
            jsr   GETARG
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$BD                   ;'='
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   EPVAL
            sta   PTR0
            lda   EPVAL+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            bra   :eol

:unset      lda   EPIDX
            jsr   GETARG
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$BF                   ;'?' -- "no such
            ldx   #FD_STDOUT             ;variable", which is
            jsr   PUTC                   ;NOT the same answer as
                                         ;an empty value
:eol        lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

EPIDX       ds    1
EPVAL       ds    2

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/env.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s
