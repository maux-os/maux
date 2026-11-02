*---------------------------------------------------------------
* tty.s -- print the terminal attached to standard input.
*
* Usage: tty
*
* CONTRACT (XCU tty, POSIX.1-2024 text -- the obsolescent -s
* option was REMOVED from the current spec, so this ships none):
* write the name of the terminal on fd 0 to stdout; if fd 0 is
* not a terminal, write "not a tty" to stdout instead. Exit 0 if
* fd 0 IS a terminal, 1 if it is not, 2 on error (an invalid/
* closed fd -- the current XCU documents ">1" for that case, and
* a usage-shaped exit is 2 by house convention regardless).
* Operands: the SYNOPSIS has none, and the two hosts disagree
* on what to do with one -- BSD (this Mac) ignores it, GNU
* coreutils (the box) refuses it: "extra operand", exit 2. maux
* refuses it: the tree's uniform rule for a utility with
* no operands (uname.s, the same landing), and it costs three
* instructions on ARGC -- no argv.s, this still reads no argv
* word. Found by the first box sweep (2026-09-14), where a row
* written against BSD's leniency went red against GNU.
*
* SC_FDSTAT (SYS_FDSTAT, maux's isatty -- src/liba/syscalls.s)
* is the whole mechanism: it returns fd 0's kernel fd-table
* type, and a DEVICE byte (>= FD_DEV_BASE) IS a tty by the house
* convention already load-bearing in shlex.s's own interactive
* check. This tool goes one step further and NAMES which device,
* the reverse of procfile5.s's PDEV_TAB (name -> handle): the
* five handles below are that table's own values, and the four
* console names are ONE-BASED while the handles are ZERO-BASED
* by that table's own deliberate rule (FD_TTY0 = /dev/tty1, see
* procfile5.s's comment on why /dev/tty0 does not exist).
*
* /dev/null (FD_NULL) is a DEVICE by the buffering-mode sense
* SIO_MODEOF cares about, but it is not a NAME this tool can
* give as a controlling terminal, and no real Unix calls
* isatty(/dev/null) true either -- so tty reports it as "not a
* tty", the one place this tool's classification is narrower
* than the house isatty shortcut. Uses ONLY liba -- no direct
* syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            put   ../../inc/sc.devfd.equ
            org   LOAD_BASE
            dsk   ../../build/tty.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

START       lda   ARGC
            cmp   #1
            bne   :usage             ;an operand: usage, exit 2
            lda   #FD_STDIN
            jsr   SC_FDSTAT
            bcs   :err
            cmp   #FD_TTY0
            beq   :nm1
            cmp   #FD_TTY1
            beq   :nm2
            cmp   #FD_TTY2
            beq   :nm3
            cmp   #FD_TTY3
            beq   :nm4
            cmp   #FD_SER0
            beq   :nma0
            bra   :notty

:nm1        lda   #<NAME1
            ldx   #>NAME1
            bra   :isatty
:nm2        lda   #<NAME2
            ldx   #>NAME2
            bra   :isatty
:nm3        lda   #<NAME3
            ldx   #>NAME3
            bra   :isatty
:nm4        lda   #<NAME4
            ldx   #>NAME4
            bra   :isatty
:nma0       lda   #<NAMEA0
            ldx   #>NAMEA0
:isatty     sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #0
            jmp   EXIT

:notty      lda   #<NOTTYMSG
            sta   PTR0
            lda   #>NOTTYMSG
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #1
            jmp   EXIT

:err        lda   #2
            jmp   EXIT

:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jmp   EXIT

USAGEMSG    asc   "usage: tty"
            dfb   $8D,$00
NOTTYMSG    asc   "not a tty"
            dfb   $8D,$00
NAME1       asc   "/dev/tty1"
            dfb   $8D,$00
NAME2       asc   "/dev/tty2"
            dfb   $8D,$00
NAME3       asc   "/dev/tty3"
            dfb   $8D,$00
NAME4       asc   "/dev/tty4"
            dfb   $8D,$00
NAMEA0      asc   "/dev/ttya0"
            dfb   $8D,$00

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* tty's bss -- none of its own. `dum`/`dend` runs only the
* arena-end tripwire, anchored at LIBA_BSSEND (the same
* precedent true.s's own trailer uses).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
