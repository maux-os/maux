*---------------------------------------------------------------
* man.s -- display a manual page.
*
* Usage: man [section] name
*
* Locates /usr/man/NAME (the name UPPERCASED -- rendered man
* pages are staged there by name.upper(), Makefile's man-pages
* rule/scripts/build_play_image.py's stage_man_pages, and ProDOS
* itself is case-fussy on this build: liba writes 7-bit bytes
* verbatim, it does not fold case for OPEN). A leading numeric
* SECTION argument is accepted and ignored -- this tree ships
* exactly one section, so there is nothing to disambiguate, but
* `man 1 ls` reads the same as real man(1) either way.
*
* PAGED IFF STDOUT IS A TTY (SC_FDSTAT, the same generic device
* test src/bin/tty.s and shlex.s's own SH_INTERACT probe make --
* NOT tty.s's specific /dev/ttyN enumeration, which this does
* not need): the page is spawned through /bin/MORE -A
* (PATHRSLV against "more", ENVPASS, SC_SPAWN, SC_WAIT -- the
* same shape src/bin/findact.s's -exec and src/bin/time.s use),
* and man exits with MORE's own status. -A is more's private
* alternate-screen flag (2026-09-15): the console parks the
* shell's screen for the page and brings it back on quit, the
* way vi does (docs/VI-ALTSCREEN.md). Otherwise the page is
* copied to stdout UNPAGED, straight through, same GETBYTE/
* REFILL shape as od.s/head.s -- `man ls | head` and a redirect
* both take this path, matching more.s's own SC_TTYGEO-gated
* "standard output not a console: copy the file through"
* posture on the OTHER end of a pipe, decided independently here
* since man never opens more's own SC_TTYGEO.
*
* No such page: "man: no manual entry for NAME" to stderr
* (NAME as typed, not uppercased), exit 1. A bad operand count,
* an operand starting with '-', or a non-numeric section is a
* usage error, exit 2. -k/-f (apropos/whatis) are NOT provided
* -- this tree builds no page index to search -- and are named
* as a gap in docs/POSIX-GAPS.md (no suite row: there is no
* conforming output to pin without an index).
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
            dsk   ../../build/man.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255              ;read chunk, see GETBYTE
MANPFXLEN   equ   9                ;strlen("/usr/man/")
NAMEBUFCAP  equ   32               ;prefix + a 20-char name

START       lda   ARGC
            cmp   #2
            bcs   :havenm
            jmp   :usage
:havenm     cmp   #4
            bcc   :cntok
            jmp   :usage
:cntok      lda   #1
            sta   NAMEIDX
            lda   ARGC
            cmp   #3
            bne   :argsdn
            lda   #1
            jsr   GETARG
            jsr   ISDIGITS
            bcc   :secok
            jmp   :usage
:secok      lda   #2
            sta   NAMEIDX
:argsdn     lda   NAMEIDX
            jsr   GETARG
            lda   (PTR0)
            cmp   #"-"
            bne   :nameok
            jmp   :usage
:nameok     jsr   BUILDNAME
            bcc   :havename
            jmp   :noentry

:havename   lda   #<NAMEBUF
            sta   PTR0
            lda   #>NAMEBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :opened
            jmp   :noentry
:opened     lda   OPARM_REF
            sta   SRCFD
            lda   #FD_STDOUT
            jsr   SC_FDSTAT
            bcs   :copy
            ora   #0
            bmi   :page
:copy       stz   BUFPOS
            stz   BUFLEN
:cplp       jsr   GETBYTE
            bcs   :cpdone
            ldx   #FD_STDOUT
            jsr   PUTC
            bra   :cplp
:cpdone     lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            lda   #0
            jsr   EXIT

:page       lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE          ;MORE opens its own copy
            lda   #<MOREWORD
            sta   PTR0
            lda   #>MOREWORD
            sta   PTR0+1
            jsr   PATHRSLV
            bcc   :havemore
            jmp   :nopager
:havemore   jsr   ENVPASS
            bcc   :envok
            jmp   :nopager
:envok      lda   #<MOREWORD
            sta   MANARGV
            lda   #>MOREWORD
            sta   MANARGV+1
            lda   #<ALTOPT               ;more -A: the alternate
            sta   MANARGV+2              ;screen: quitting the
            lda   #>ALTOPT               ;page brings the shell
            sta   MANARGV+3              ;screen back, like vi
            lda   #<NAMEBUF
            sta   MANARGV+4
            lda   #>NAMEBUF
            sta   MANARGV+5
            stz   MANARGV+6
            stz   MANARGV+7
            lda   #<MANARGV
            sta   PTR1
            lda   #>MANARGV
            sta   PTR1+1
            stz   PTR2
            stz   PTR2+1            ;NULL fdactions -- inherit
                                    ;fd 0/1/2
            jsr   SC_SPAWN
            bcc   :spawned
            ldx   #<MANERRPFX            ;A = the errno still
            ldy   #>MANERRPFX
            jsr   SPAWNWHY               ;no bank/file slot: say
            bcs   :nobank
            jmp   :nopager
:nobank     lda   #1
            jsr   EXIT
:spawned    lda   #<WSTATUS
            sta   PTR0
            lda   #>WSTATUS
            sta   PTR0+1
            jsr   SC_WAIT
            lda   WSTATUS           ;transparent, MORE's own
            jsr   EXIT

:nopager    lda   #<PAGERMSG
            sta   PTR0
            lda   #>PAGERMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:noentry    lda   #<NOENT1
            sta   PTR0
            lda   #>NOENT1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   NAMEIDX
            jsr   GETARG            ;PUTS clobbered PTR0
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            jsr   EXIT

:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* BUILDNAME -- IN: PTR0 = the name operand (liba text). OUT:
* NAMEBUF = "/usr/man/" + UPPERCASE(name) + NUL; carry CLEAR
* on success, SET if the name does not fit NAMEBUFCAP (treated
* by the caller as "no such page"). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
BUILDNAME   ldy   #0
:bnpfx      lda   MANPFX,y
            sta   NAMEBUF,y
            iny
            cpy   #MANPFXLEN
            bne   :bnpfx
            ldx   #MANPFXLEN
            ldy   #0
:bnnm       lda   (PTR0),y
            beq   :bndone
            jsr   TOUPPER
            cpx   #NAMEBUFCAP-1
            bcs   :bnbig
            sta   NAMEBUF,x
            inx
            iny
            bne   :bnnm
            bra   :bnbig             ;255 bytes, defensive
:bndone     lda   #0
            sta   NAMEBUF,x
            clc
            rts
:bnbig      sec
            rts

*---------------------------------------------------------------
* TOUPPER -- IN: A = a high-bit source byte. OUT: A = the same
* byte, uppercased if it was a lower-case ASCII letter.
* PRESERVES: X, Y. CLOBBERS: nothing else.
*---------------------------------------------------------------
TOUPPER     sta   MAN_TU
            and   #$7F
            cmp   #'a'
            bcc   :tuno
            cmp   #'z'+1
            bcs   :tuno
            lda   MAN_TU
            and   #$DF
            rts
:tuno       lda   MAN_TU
            rts

*---------------------------------------------------------------
* ISDIGITS -- IN: PTR0 = a word. OUT: carry CLEAR if 1+ bytes,
* every one a decimal digit; SET otherwise (empty, or any
* non-digit byte). CLOBBERS: A, Y.
*---------------------------------------------------------------
ISDIGITS    ldy   #0
:idlp       lda   (PTR0),y
            beq   :idend
            and   #$7F
            cmp   #'0'
            bcc   :idbad
            cmp   #'9'+1
            bcs   :idbad
            iny
            bne   :idlp
            bra   :idbad             ;255 bytes, defensive
:idend      cpy   #0
            beq   :idbad
            clc
            rts
:idbad      sec
            rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as od.s/head.s.
*---------------------------------------------------------------
GETBYTE     ldx   BUFPOS
            cpx   BUFLEN
            bcc   :have
            jsr   REFILL
            bcs   :eof
            ldx   BUFPOS
:have       lda   CBUF,x
            inc   BUFPOS
            clc
            rts
:eof        sec
            rts

REFILL      lda   SRCFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :eof
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :eof
            lda   RPARM_TRANS
            sta   BUFLEN
            stz   BUFPOS
            clc
            rts
:eof        sec
            rts

MANPFX      asc   "/usr/man/"
USAGEMSG    asc   "usage: man [section] name"
            dfb   $8D,$00
NOENT1      asc   "man: no manual entry for "
            dfb   $00
MANERRPFX   asc   'man: '
            dfb   0
PAGERMSG    asc   "man: cannot run pager"
            dfb   $8D,$00
MOREWORD    asc   "more"
            dfb   0
ALTOPT      asc   "-A"
            dfb   $00

OPARM       dfb   PCOUNT_OPEN
OPARM_PATH  da    PATHBUF
OPARM_IOBUF da    $0000
OPARM_REF   dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    CBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/spawnwhy.s
            put   ../liba/pathtab.s
            put   ../liba/pathres.s
            put   ../liba/env.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* man's own scalars, `dum`/`dend` off LIBA_BSSEND -- no `ds`
* zeros needed (docs/STICKY.md sec 21): every cell below is
* write-before-read.
*  - NAMEIDX: written on every path before its first read.
*  - SRCFD: written once OPARM's OPEN succeeds, read on both
*    the copy and page branches.
*  - BUFPOS/BUFLEN: `stz`'d at :copy, the only reader (man
*    opens at most one page).
*  - MAN_TU: TOUPPER's own first store, every call.
*  - WSTATUS: SC_WAIT's own buffer, read right after.
*  - NAMEBUF: BUILDNAME fills it start to NUL every call.
*  - MANARGV: written in full (both pointers + the NULL) right
*    before the one SC_SPAWN that reads it.
*  - PATHBUF/CBUF: MKPATH/SC_READ fill them; read only up to
*    what was written.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
NAMEIDX     ds    1
SRCFD       ds    1
BUFPOS      ds    1
BUFLEN      ds    1
MAN_TU      ds    1
WSTATUS     ds    1
NAMEBUF     ds    NAMEBUFCAP
MANARGV     ds    8              ;more, -A, page, NULL
PATHBUF     ds    65
CBUF        ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window.
            err   */$BF00
            dend
