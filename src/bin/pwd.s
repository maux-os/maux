*---------------------------------------------------------------
* pwd.s -- print the working directory.
*
* Usage: pwd
*
* CONTRACT: write the current ProDOS prefix to stdout, followed
* by a CR. Exit 0 on success, 1 if the prefix cannot be read.
*
* The MLI hands GET_PREFIX's answer back as a LENGTH-PREFIXED
* string (a count byte, then that many characters) -- the same
* shape MKPATH builds for the other direction. liba's PUTS wants
* a NUL-terminated string, so this converts rather than printing
* the count byte as a character.
*
* An empty prefix is legal and means "no prefix set"; ProDOS
* returns a zero count. That prints as an empty line rather than
* being treated as an error, because it is a real state and not
* a failure.
*
* SEMANTIC NOTE: the prefix is per-MACHINE, not per-process --
* ProDOS keeps exactly one. So this reports the system's working
* directory, which coincides with the shell's only while there
* is one shell. See PRC_SETPFX in the kernel.
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
            dsk   ../../build/pwd.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

START       lda   #<GPPARM
            ldx   #>GPPARM
            jsr   SC_GETPFX
            bcs   :failed

*-- Two conversions, not one. The MLI answers with a
*-- LENGTH-PREFIXED, LOW-ASCII string; liba strings are
*-- NUL-terminated and HIGH-bit. Printing the raw bytes would
*-- put the path on screen in inverse video, since low ASCII is
*-- how the //e encodes inverse -- so set the high bit too.
            ldy   PFXBUF                 ;count byte
            beq   :terminate             ;empty prefix is legal
:hibit      lda   PFXBUF,y
            ora   #$80
            sta   PFXBUF,y
            dey
            bne   :hibit
:terminate  ldy   PFXBUF
            lda   #0
            sta   PFXBUF+1,y      ;terminate after last
            lda   #<PFXBUF+1
            sta   PTR0
            lda   #>PFXBUF+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #0
            jsr   EXIT

:failed     lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

ERRMSG      asc   "pwd: cannot read prefix"
            dfb   $8D,$00

GPPARM      dfb   1              ;param_count for GET_PREFIX
GPPARM_BUF  da    PFXBUF

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* pwd's bss -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at LIBA_BSSEND rather than `*`.
* Anything emitted after `dend` would silently overlay it
* (learning:01M0FNC75R7YSFRNS328WHXMHN).
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - PFXBUF: written by SC_GETPFX, and read only on the
*    carry-CLEAR path (`bcs :failed` guards every reader).
*    Checked against the kernel rather than assumed:
*    PRC_GETPFX (src/kernel/procfile.s) does `stz
*    PRC_PATHBUF` before the MLI call and then copies back
*    count+1 bytes, so on success the count byte and exactly
*    that many characters are always written. pwd reads
*    PFXBUF[0..count] and appends its own NUL; count is capped
*    at 64, so the 80 bytes are never overrun.
*
* GPPARM stays emitted above -- it is a 3-byte parmlist of two
* nonzero constants, i.e. real initialised data, and its
* `da PFXBUF` still resolves to this arena's address.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
PFXBUF      ds    80             ;count byte + up to 64 chars +
                                 ;room for the NUL we append
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
