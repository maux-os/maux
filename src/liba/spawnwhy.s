*---------------------------------------------------------------
* spawnwhy.s -- say WHY a refused SC_SPAWN was refused, for the
* caller that has already decided to print "prog: ..." itself.
*
* WHY THIS EXISTS. spawn() answers ERR_NOMEM when the bank pool
* is empty and ERR_NFILE when the file table is, and since
* da84271c ERR_NOMEM means that and NOTHING ELSE (an image that
* cannot be loaded is ERR_NOEXEC). The shell has said so since
* dcc16dc5 (`sh: no more processes`); the utilities that spawn
* on their own behalf kept printing a verdict about THE FILE --
* `cannot execute`, `exec failed`, `cannot run pager` -- on a
* machine whose file was fine and whose process table was full,
* and a user told "cannot execute" goes and looks at the file.
* V7's exec(2) makes the caller diagnose; this is its half.
*
* THE CONTRACT IS DELIBERATELY NARROW. It names only the two
* conditions that are about the MACHINE and says nothing about
* any other errno: every program keeps its own words (and its
* own exit status) for "this file is not a program", "not found"
* and "argument list too long", which are its existing, tested
* behaviour. A program that wants the machine's reason calls
* this first and falls through to its old message on carry
* clear.
*
* THE CODES ARE RESTATED, NOT PUT. ERR_NOMEM ($E0) and ERR_NFILE
* ($E9) live in inc/errno.krn.equ, which also defines ERR_SRCH
* at $E7 -- the same byte as errno.spawn.equ's ERR_2BIG. A
* utility that already puts errno.spawn.equ would be one
* `cmp #ERR_...` away from testing both codes as one, so the
* whole table is not pulled into a dozen programs for two
* bytes. check-spawnfail compares the two values below with
* errno.krn.equ, so the restatement cannot drift without a red.
*
* Uses PUTS (print.s), PTR0 (zp.equ) and FD_STDERR (sc.fd.equ);
* the including program must put all three -- the list is a
* precondition, so an incomplete one is how the next caller
* earns an undefined symbol or worse. Put it at the TOP LEVEL
* like every liba file.
*---------------------------------------------------------------
SPW_NOMEM   equ   $E0               ;errno.krn.equ ERR_NOMEM
SPW_NFILE   equ   $E9               ;errno.krn.equ ERR_NFILE

*---------------------------------------------------------------
* SPAWNWHY -- IN: A = the errno SC_SPAWN refused with,
*                  X/Y = lo/hi of the NUL-terminated prefix to
*                  print first (e.g. "env: ").
* OUT: carry SET   -> A was ERR_NOMEM or ERR_NFILE and
*                     "<prefix>no more processes" or
*                     "<prefix>file table full", CR, has been
*                     written to stderr.
*      carry CLEAR -> nothing was written; the caller says its
*                     own words.
* CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
SPAWNWHY    stx   PTR0
            sty   PTR0+1
            ldx   #<SPW_NOPROC
            ldy   #>SPW_NOPROC
            cmp   #SPW_NOMEM
            beq   :say
            ldx   #<SPW_NFILEM
            ldy   #>SPW_NFILEM
            cmp   #SPW_NFILE
            beq   :say
            clc
            rts
:say        phy
            phx
            ldx   #FD_STDERR
            jsr   PUTS
            pla
            sta   PTR0
            pla
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            sec
            rts

*-- Single-quoted: low ASCII with a $0D, as sh's own spawn words
*-- are (shpath.s NOPROC_MSG); check-encoding's literal pin.
SPW_NOPROC  asc   'no more processes'
            dfb   $0D,0
SPW_NFILEM  asc   'file table full'
            dfb   $0D,0
