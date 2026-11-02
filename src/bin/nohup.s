*---------------------------------------------------------------
* nohup.s -- run a utility with the hangup signal ignored.
*
* Usage: nohup utility [argument...]
*
* SIGHUP: inc/sc.proc.equ's SC_SIGNAL takes any signo
* 1-15 except 9, and shtrap.s's own trap name table already
* numbers HUP as signal 1 (V7 numbering) -- but nothing in this
* kernel ever SENDS signal 1: there is no hangup event (no
* controlling-terminal-drop notion, docs/FLEET.md's own
* nohup row: "no job control / hangup signal concept"). So the
* SC_SIGNAL(1, IGN) call below is a REAL syscall that succeeds,
* not a fiction -- it is simply a no-op today because no sender
* exists yet. The substance of this tool, per POSIX, is the
* REDIRECTION.
*
* REDIRECTION. If fd 1 is a terminal (SC_FDSTAT, tty.s's own
* device-name set: FD_TTY0-3 or FD_SER0, NOT FD_NULL), the
* child's stdout is appended to NOHUP.OUT in the current
* directory instead -- CREATE (ignore "already exists") + OPEN +
* lseek(fd,0,SEEK_END), the exact package tee.s's `-a` and sh's
* `>>` (OPEN_REDIR_AP) already use. ProDOS has no mode bits, so
* "0600-equivalent" is simply "whatever CREATE's own
* ACCESS_UNLKD draft-value already grants" -- no narrower access
* byte to ask for. If that create/open fails, $HOME/NOHUP.OUT is
* tried the same way (maux's $HOME is a plain, optional
* environment variable -- nothing sets it, docs/SH-FEATURES.md's
* own row says so -- so this is GETENV, not a fixed name); if
* HOME is unset, or that ALSO fails, this exits 127 ("an error
* occurred in the nohup utility", the POSIX EXIT STATUS text's
* own umbrella for this case) with a diagnostic. If fd 2 is also
* a terminal, it is redirected the SAME way. THE NOTICE (`nohup:
* appending output to nohup.out`, to fd 2) is printed BEFORE
* either destination is even attempted -- on a real Unix nohup
* replaces its OWN stdout/stderr in place before exec; on maux
* nohup never touches its own fd table at all, only the CHILD's
* (via spawn's fdactions, inc/sc.fdact.equ), so nothing
* here is literally "moved" -- but the ORDER is kept anyway,
* both because it is the POSIX-documented sequence and because a
* redirect that later fails should not have skipped the notice.
*
* WHY FDACTIONS AND NOT A SELF DUP2: nohup's OWN fd 1/2 must
* stay the console (or whatever they already are) for the
* notice and for any later diagnostic -- only the CHILD's fd
* table should change. spawn()'s fdactions list (docs/SYSCALL.md
* item 10) is built to do exactly this: FDACT_DUP(target,
* source) resolves `source` against THIS process's table at
* spawn time, so handing the child FD_STDOUT/FD_STDERR = dup(the
* fd this program just opened) needs no change to nohup's own fd
* 1/2 whatsoever.
*
* ENVIRONMENT is passed through UNCHANGED (unlike env(1), which
* rebuilds the list on purpose) -- built once via ENVNTH the
* same way env.s's own pass-2 loop enumerates the current
* environment, just with no shadowing pass since nothing here
* overrides anything.
*
* Spawn shape from env.s (PATHRSLV + SC_SPAWN + SC_WAIT):
* argv[0] is the word AS TYPED (execvp's rule), argv[1..] as is.
* Exit 127 if the utility is not found, 126 if it is found but
* cannot be executed, else the utility's own status (SC_WAIT's
* one-byte value, passed straight to EXIT -- no reinterpreting
* the $80|signo convention here, same as env.s).
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            put   ../../inc/sc.devfd.equ
            put   ../../inc/sc.fdact.equ
            put   ../../inc/errno.spawn.equ
            org   LOAD_BASE
            dsk   ../../build/nohup.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

NH_ENVCAP   equ   48          ;env entries, env.s's own cap
NH_ARGVMAX  equ   32          ;child argv words -- env.s's cap
NH_RAWSZ    equ   96          ;NH_HOMEPTH's scratch buffer size

START       lda   ARGC
            cmp   #2
            bcs   :argsok            ;need at least the utility
            jmp   :usage
:argsok
*-- ignore SIGHUP: a real syscall, a no-op today (see header).
*-- Carry is not checked -- best-effort, never fatal.
            lda   #1                 ;signo 1 -- shtrap.s's HUP
            ldx   #SIGA_IGN
            jsr   SC_SIGNAL

            lda   #FD_STDOUT
            jsr   NH_ISTTY
            sta   NH_ISOUT
            lda   #FD_STDERR
            jsr   NH_ISTTY
            sta   NH_ISERR
            lda   NH_ISOUT
            ora   NH_ISERR
            bne   :needred
            jmp   :noredir           ;neither is a tty

:needred    lda   #<NOTICEMSG
            sta   PTR0
            lda   #>NOTICEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC

*-- try NOHUP.OUT in the current directory first.
            lda   #<NHOUTNAME
            sta   PTR0
            lda   #>NHOUTNAME
            sta   PTR0+1
            lda   #<NH_MLIBUF
            sta   PTR1
            lda   #>NH_MLIBUF
            sta   PTR1+1
            jsr   MKPATH             ;a literal name -- cannot
                                     ;overflow; carry ignored
            jsr   NH_APPOPEN
            bcc   :havefd

*-- fall back to $HOME/NOHUP.OUT. Short branches only -- :cant-
*-- creat sits far below; each check jumps out-of-line instead.
            lda   #<HOMENAME
            sta   PTR0
            lda   #>HOMENAME
            sta   PTR0+1
            jsr   GETENV
            bcc   :havehome
            jmp   :cantcreat         ;no $HOME -- exit 127
:havehome   jsr   NH_HOMEPTH         ;NH_RAWBUF = PTR1 + '/' +
                                     ;"NOHUP.OUT"
            bcc   :homefit
            jmp   :cantcreat         ;too long to be a path
:homefit    lda   #<NH_RAWBUF
            sta   PTR0
            lda   #>NH_RAWBUF
            sta   PTR0+1
            lda   #<NH_MLIBUF
            sta   PTR1
            lda   #>NH_MLIBUF
            sta   PTR1+1
            jsr   MKPATH
            bcc   :homemkp
            jmp   :cantcreat
:homemkp    jsr   NH_APPOPEN
            bcc   :havefd
            jmp   :cantcreat

:havefd     sta   NH_SRCFD

*-- fdactions: dup the opened fd onto every stream that needs
*-- it, close the source in the child, terminate.
            stz   NH_FI
            lda   NH_ISOUT
            beq   :fanoout
            jsr   NH_FDADD1
:fanoout    lda   NH_ISERR
            beq   :fanoerr
            lda   #FD_STDERR
            jsr   NH_FDADD2
:fanoerr    ldx   NH_FI
            lda   #FDACT_CLOSE
            sta   FDABUF,x
            lda   NH_SRCFD
            sta   FDABUF+1,x
            stz   FDABUF+2,x
            txa
            clc
            adc   #3
            tax
            lda   #FDACT_END
            sta   FDABUF,x
            lda   #<FDABUF
            sta   NH_FDAP
            lda   #>FDABUF
            sta   NH_FDAP+1
            bra   :spawn

:noredir    stz   NH_FDAP
            stz   NH_FDAP+1

:spawn
*-- build the child's environment: a verbatim copy (docs
*-- header: nohup does not modify it).
            stz   NH_EI
            stz   NH_ECNT
:ecplp      lda   NH_EI
            jsr   ENVNTH
            bcs   :ecdone
            lda   NH_ECNT
            cmp   #NH_ENVCAP
            bcc   :ecroom
            jmp   :envfull
:ecroom     asl   a
            tax
            lda   PTR1
            sta   NH_ENVLST,x
            lda   PTR1+1
            sta   NH_ENVLST+1,x
            inc   NH_ECNT
            inc   NH_EI
            bra   :ecplp
:ecdone     lda   NH_ECNT
            asl   a
            tax
            stz   NH_ENVLST,x
            stz   NH_ENVLST+1,x

            lda   #1
            jsr   GETARG              ;PTR0 = argv[1], as typed
            lda   PTR0
            sta   NH_ORGW
            lda   PTR0+1
            sta   NH_ORGW+1
            jsr   PATHRSLV
            bcc   :found
            jmp   :notfound
:found      lda   PTR0
            sta   NH_PATH
            lda   PTR0+1
            sta   NH_PATH+1

            lda   NH_ORGW
            sta   ARGVLIST
            lda   NH_ORGW+1
            sta   ARGVLIST+1
            lda   #2
            sta   NH_AI2
            lda   #1
            sta   NH_NI
:cvlp       lda   NH_AI2
            cmp   ARGC
            bcs   :cvdone
            lda   NH_NI
            cmp   #NH_ARGVMAX
            bcc   :cvok
            jmp   :toomany
:cvok       lda   NH_AI2
            jsr   GETARG
            lda   NH_NI
            asl   a
            tax
            lda   PTR0
            sta   ARGVLIST,x
            lda   PTR0+1
            sta   ARGVLIST+1,x
            inc   NH_NI
            inc   NH_AI2
            bra   :cvlp
:cvdone     lda   NH_NI
            asl   a
            tax
            stz   ARGVLIST,x
            stz   ARGVLIST+1,x

            lda   NH_PATH
            sta   PTR0
            lda   NH_PATH+1
            sta   PTR0+1
            lda   #<ARGVLIST
            sta   PTR1
            lda   #>ARGVLIST
            sta   PTR1+1
            lda   NH_FDAP
            sta   PTR2
            lda   NH_FDAP+1
            sta   PTR2+1
            lda   #<NH_ENVLST
            sta   SPWN_ENVP
            lda   #>NH_ENVLST
            sta   SPWN_ENVP+1
            jsr   SC_SPAWN
            bcs   :spawnerr
            lda   #<WSTATUS
            sta   PTR0
            lda   #>WSTATUS
            sta   PTR0+1
            jsr   SC_WAIT
            lda   WSTATUS
            jsr   EXIT

:spawnerr   cmp   #ERR_2BIG
            beq   :toolarge
            ldx   #<NHSPFX
            ldy   #>NHSPFX
            jsr   SPAWNWHY               ;A = the errno still
            bcc   :cantexec              ;no bank, no file slot:
            lda   #126                   ;say so. 126: found,
            jsr   EXIT                   ;could not be run (man)
:cantexec   lda   #<CANTEXEC1
            sta   PTR0
            lda   #>CANTEXEC1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   NH_ORGW
            sta   PTR0
            lda   NH_ORGW+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<CANTEXEC2
            sta   PTR0
            lda   #>CANTEXEC2
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #126
            jsr   EXIT

:notfound   lda   #<NOTFOUND1
            sta   PTR0
            lda   #>NOTFOUND1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   NH_ORGW
            sta   PTR0
            lda   NH_ORGW+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<NOTFOUND2
            sta   PTR0
            lda   #>NOTFOUND2
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #127
            jsr   EXIT

:toolarge   lda   #<TOOLARGEM
            sta   PTR0
            lda   #>TOOLARGEM
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:toomany    lda   #<TOOMANYMS
            sta   PTR0
            lda   #>TOOMANYMS
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:envfull    lda   #<ENVFULLMS
            sta   PTR0
            lda   #>ENVFULLMS
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:cantcreat  lda   #<CANTCREATM
            sta   PTR0
            lda   #>CANTCREATM
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #127
            jsr   EXIT

:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

            put   nohupfd.s


            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/spawnwhy.s
            put   ../liba/seek.s
            put   ../liba/pathtab.s
            put   ../liba/pathres.s
            put   ../liba/env.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* nohup's own bss -- `dum`/`dend` off LIBA_BSSEND, no zero
* fills needed (docs/STICKY.md sec 21): every cell below is
* write-before-read on the path that reads it.
*  - NH_ISOUT/NH_ISERR: NH_ISTTY's own return value, written
*    before the `ora` that reads both.
*  - NH_FI: `stz`'d before the redirect fan-out ever adds to it.
*  - NH_SRCFD/NH_FDAP: written on the :needred path only, before
*    :spawn reads either.
*  - NH_EI/NH_ECNT: the environment-copy loop's own counters.
*  - NH_ORGW/NH_PATH/NH_AI2/NH_NI: the argv-build loop, same
*    shape as env.s's own ENV_ORGW/ENV_PATH/ENV_AI2/ENV_NI.
*  - NH_TMPFD/NH_SEEKOF: NH_APPOPEN's own scratch.
*  - NH_RAWBUF: NH_HOMEPTH fills it whole before any reader.
*  - NH_MLIBUF/FDABUF/NH_ENVLST/ARGVLIST/WSTATUS: filled
*    byte-by-byte or entry-by-entry before being read back.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
NH_ISOUT    ds    1
NH_ISERR    ds    1
NH_FI       ds    1
NH_SRCFD    ds    1
NH_FDAP     ds    2
NH_EI       ds    1
NH_ECNT     ds    1
NH_ORGW     ds    2
NH_PATH     ds    2
NH_AI2      ds    1
NH_NI       ds    1
NH_TMPFD    ds    1
NH_SEEKOF   ds    3
WSTATUS     ds    1
NH_RAWBUF   ds    NH_RAWSZ
NH_MLIBUF   ds    65
FDABUF      ds    10
NH_ENVLST   ds    NH_ENVCAP*2+2
ARGVLIST    ds    NH_ARGVMAX*2+2
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window.
            err   */$BF00
            dend
