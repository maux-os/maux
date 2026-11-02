*---------------------------------------------------------------
* false.s -- do nothing, unsuccessfully. Exit 1.
*
* The POSIX no-op that fails: `while false` (run zero times),
* `until false`, `false || echo fallback`. maux `sh` evaluates a
* construct's condition by SPAWNING it, so `true`/`false` must
* be real programs on PATH (/bin), not shell words. The
* sibling of `true` (exit 0); see true.s for the SC_EXIT note.
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
            dsk   ../../build/false.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

START       lda   #1
            jsr   SC_EXIT

            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* No bss of its own; the `dum` arena runs the arena-end tripwire
* (the only guard against liba growing the image past $BF00 that
* check_modules' image-window gate cannot see).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
            err   */$BF00
            dend
