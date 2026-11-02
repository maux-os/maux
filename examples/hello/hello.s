*---------------------------------------------------------------
* hello.s -- the first maux program, in 6502 assembly.
*
*   nas -o hello.o hello.s
*   ld -o hello hello.o -L /usr/lib -l a
*   ./hello
*
* PUTS and EXIT belong to liba, maux's C-less libc. `ext` names
* them, and `ld -l a` pulls the modules that define them out of
* the library directory /usr/lib/LIBA. Everything else here is
* this file: START is the first byte of the program, and ld puts
* the module you name first, at $0800.
*
* The string is plain 7-bit ASCII (single quotes) ending in CR
* ($0D) and then NUL: PUTS stops at the NUL. maux's console
* takes it in either polarity.
*
* This file is staged on the release disk as MAUX TEXT (high
* bit set, lines ended by $8D), exactly what `vi` writes. nas
* reads that or ProDOS-standard text (low ASCII, $0D) alike, so
* edit it with `vi` and run `nas` on it: nothing to convert.
*---------------------------------------------------------------
            rel
            lst   off
PUTS        ext
EXIT        ext
            put   /usr/inc/sc.fd.equ
            put   /usr/inc/zp.equ

START       lda   #<MSG
            sta   PTR0
            lda   #>MSG
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #0
            jsr   EXIT

MSG         asc   'hello, world',0D,00
