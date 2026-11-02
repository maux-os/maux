*---------------------------------------------------------------
* true.s -- do nothing, successfully. Exit 0.
*
* The POSIX no-op: `while true`, `if true`, `x=${y:-$(true)}`.
* maux `sh` evaluates a construct's condition by SPAWNING it, so
* `true`/`false` must be real programs on PATH (/bin), not
* shell words -- without them `if true` spawned nothing and said
* "command not found". A sibling of `false` (exit 1).
*
* No output, so it exits through SC_EXIT directly rather than
* liba's EXIT (which exists to flush stdio and surface a
* deferred write error -- neither applies with nothing written).
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
            dsk   ../../build/true.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

START       lda   #0
            jsr   SC_EXIT

            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* No bss of its own; the `dum` arena runs the arena-end tripwire
* (the only guard against liba growing the image past $BF00 that
* check_modules' image-window gate cannot see -- a `dum` arena
* emits no bytes).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
            err   */$BF00
            dend
