*---------------------------------------------------------------
* kill.s -- terminate a process by pid (FLEET friction audit
* item 1: "a job you can see but not signal is the single most
* un-Unix feel in the system").
*
* Usage: kill [-signo | -s signal_name | -l] pid ...
*
* SHIPPED 2026-09-17: -l (list every signal_name this
* implementation knows) and -s signal_name (the symbolic form of
* -signo). Both ride the SAME 5-entry name table timeout.s's own
* -s already established (TO_PARSESIG/timeoutaux.s's SIGNM_*):
* HUP=1, INT=2, QUIT=3, KILL=9, TERM=15 -- kill.s did not have
* one of its own before this, so this is the first table shared
* BY CONVENTION (same names/numbers, independently declared;
* merlin32 has no cross-file EQU sharing without a put, and a
* 5-entry table is not worth a new inc/ header). -l lists just
* those five, in signal-number order, one line, space-separated
* -- real BSD kill -l lists 30+ signals this machine's kernel
* does not have (docs/SIGNALS.md's own numbers/names: EXIT INT
* TERM HUP QUIT KILL -- EXIT is shtrap.s's own pseudo-signal,
* not a real signo, so it is not in kill.s's list either), so
* this row is hand-authored to maux's own reduced set, not
* host-oracled.
*
* THE SIGNAL NUMBER IS CARRIED, NOT DELIVERED: maux has no
* trap/handler machinery yet, so every nonzero signo
* terminates -- but the signo travels into the victim's wait
* status as $80|signo (the STATUS_INTR encoding; ^C's own lane
* is signal 2 = $82), so the default here is V7's 15 (TERM,
* reaps $8F), `kill -9` reaps $89, and `kill -0 pid` is the
* V7 liveness probe -- exit status says whether the pid lives,
* nothing dies. When `trap` lands, the default lane becomes
* catchable with no change here
* (src/kernel/procspawn2.s PRC_KILL; policy in
* inc/sc.proc.equ's SYS_KILL note).
*
* Exit 0 if every named pid was killed, 1 if any failed -- and
* that includes a run where EVERY pid failed (`kill 99`: the
* diagnostic, exit 1, no usage line; it used to count only the
* successes and fell through to USAGE, exit 2). Exit 2 stays for
* the usage errors: no pid operand, or none well-formed (the
* host's /bin/kill agrees). Each
* failure names its operand: `kill: N: no such process` for a
* free or zombie slot, `kill: N: cannot kill` for the root
* tier (pid 1, idle). The console shell is killable since
* RULINGS-1 (2026-10-18): init respawns it. Before that a
* 2026-09-14 rule refused it, for want of an init.
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            put   ../../inc/errno.krn.equ
            org   LOAD_BASE
            dsk   ../../build/kill.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

START       lda   ARGC
            cmp   #2
            bcs   :argsok                ;inverted + jmp: USAGE
            jmp   USAGE                  ;outgrew a branch when
:argsok                                  ;the signo parse landed
            lda   #1
            sta   ARGIDX
            stz   ERRFLAG
            stz   NPIDS
            lda   #15                    ;default: the TERM lane
            sta   SIGNO

*-- a first operand starting '-' is the signo, -l, or -s NAME
            lda   ARGIDX
            jsr   GETARG
            ldy   #0
            lda   (PTR0),y
            cmp   #"-"
            bne   :pids
            lda   #<S_DASHL
            sta   PTR1
            lda   #>S_DASHL
            sta   PTR1+1
            jsr   STRCMP
            cmp   #0
            bne   :notl
            jmp   LISTSIGS               ;-l: list, then exit
:notl       lda   #<S_DASHS
            sta   PTR1
            lda   #>S_DASHS
            sta   PTR1+1
            jsr   STRCMP
            cmp   #0
            bne   :notdashs
            lda   ARGIDX                 ;-s NAME: NAME is the
            clc                          ;next operand
            adc   #1
            cmp   ARGC
            bcs   :dsusage               ;-s with no NAME
            tax
            inc   ARGIDX
            inc   ARGIDX
            txa
            jsr   GETARG
            jsr   MATCHSIG
            bcs   :dsusage
            lda   SIGVAL
            sta   SIGNO
            bra   :pids
:dsusage    jmp   USAGE
:notdashs   inc   PTR0                   ;past the '-'
            bne   :nc0
            inc   PTR0+1
:nc0        jsr   PARSEPID               ;same digits-to-byte
            bcc   :sigok                 ;`kill -x` is a usage
            jmp   USAGE                  ;  error, not a pid
:sigok      lda   PIDVAL
            sta   SIGNO
            inc   ARGIDX

:pids       lda   ARGIDX
            cmp   ARGC
            bcs   :done
            lda   ARGIDX
            jsr   GETARG
            jsr   PARSEPID
            bcs   :badpid
            inc   NPIDS                  ;a well-formed pid,
            lda   PIDVAL                 ;whatever becomes of it
            ldx   SIGNO
            jsr   SC_KILL
            bcs   :failed
:next       inc   ARGIDX
            bra   :pids

:badpid     jsr   SAYOPRND
            lda   #<M_BADPID
            ldx   #>M_BADPID
            jsr   SAYERR
            bra   :next
:failed     cmp   #ERR_SRCH
            bne   :cantkill
            jsr   SAYOPRND
            lda   #<M_NOSUCH
            ldx   #>M_NOSUCH
            jsr   SAYERR
            bra   :next
:cantkill   jsr   SAYOPRND
            lda   #<M_CANT
            ldx   #>M_CANT
            jsr   SAYERR
            bra   :next

:done       lda   NPIDS                  ;no well-formed pid
            bne   :status                ;(`kill -9` alone, or
            jmp   USAGE                  ;only junk) is a usage
                                         ;error, not a nop; pids
                                         ;that FAILED still
                                         ;count: exit 1 and no
                                         ;usage line (KFIX 4)
:status     lda   ERRFLAG
            jsr   EXIT

USAGE       lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* PARSEPID -- IN: PTR0 = operand text. OUT: carry clear and
* PIDVAL = its 8-bit value; carry set on empty, non-digit, or
* > 255. The kernel does the liveness/range policing -- this
* only has to turn digits into a byte without wrapping.
*---------------------------------------------------------------
PARSEPID    stz   PIDVAL
            ldy   #0
            lda   (PTR0),y
            beq   :bad                   ;empty operand
:loop       lda   (PTR0),y
            beq   :ok
            and   #$7F                   ;liba text is high-bit
            cmp   #'0'
            bcc   :bad
            cmp   #'9'+1
            bcs   :bad
            sec
            sbc   #'0'
            pha
            lda   PIDVAL                 ;PIDVAL *= 10, refusing
            asl   a                      ;overflow: `kill 300`
            bcs   :badp                  ;must not become
            asl   a                      ;`kill 44`
            bcs   :badp
            adc   PIDVAL
            bcs   :badp
            asl   a
            bcs   :badp
            sta   PIDVAL
            pla
            clc
            adc   PIDVAL
            bcs   :bad
            sta   PIDVAL
            iny
            bra   :loop
:badp       pla
:bad        sec
            rts
:ok         clc
            rts

*---------------------------------------------------------------
* MATCHSIG -- IN: PTR0 = operand text (-s's argument). OUT:
* carry CLEAR, SIGVAL = the value, on a decimal number 0-255
* (PARSEPID, unchanged) or one of HUP/INT/QUIT/KILL/TERM (case-
* insensitive, timeoutparse.s's TO_PARSESIG/TO_NAMEIS shape --
* see this file's header for why the table is duplicated rather
* than shared). Carry SET otherwise. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
MATCHSIG    ldy   #0
            lda   (PTR0),y
            and   #$7F
            cmp   #'0'
            bcc   :byname
            cmp   #'9'+1
            bcs   :byname
            jsr   PARSEPID
            bcs   :bad
            lda   PIDVAL
            sta   SIGVAL
            clc
            rts
:byname     lda   #1
            sta   SIGVAL
            lda   #<SN_HUP
            ldx   #>SN_HUP
            jsr   SIGNAMEIS
            bcs   :match
            lda   #2
            sta   SIGVAL
            lda   #<SN_INT
            ldx   #>SN_INT
            jsr   SIGNAMEIS
            bcs   :match
            lda   #3
            sta   SIGVAL
            lda   #<SN_QUIT
            ldx   #>SN_QUIT
            jsr   SIGNAMEIS
            bcs   :match
            lda   #9
            sta   SIGVAL
            lda   #<SN_KILL
            ldx   #>SN_KILL
            jsr   SIGNAMEIS
            bcs   :match
            lda   #15
            sta   SIGVAL
            lda   #<SN_TERM
            ldx   #>SN_TERM
            jsr   SIGNAMEIS
            bcs   :match
:bad        sec
            rts
:match      clc
            rts

*---------------------------------------------------------------
* SIGNAMEIS -- A/X = a name. Carry SET iff PTR0's operand equals
* it (case-insensitive). Preserves PTR0.
*---------------------------------------------------------------
SIGNAMEIS   sta   PTR1
            stx   PTR1+1
            lda   PTR0
            pha
            lda   PTR0+1
            pha
            jsr   STRCMPI
            sta   SG_TMP
            pla
            sta   PTR0+1
            pla
            sta   PTR0
            lda   SG_TMP
            bne   :ne
            sec
            rts
:ne         clc
            rts

*---------------------------------------------------------------
* LISTSIGS -- `kill -l`: print the 5 names this kernel's kill
* ABI supports, space-separated, one line, exit 0. Does not
* return. CLOBBERS: everything PUTS/PUTC do.
*---------------------------------------------------------------
LISTSIGS    stz   LSIDX
:lslp       ldx   LSIDX
            lda   SNAMLO,x
            sta   PTR0
            lda   SNAMHI,x
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   LSIDX
            cmp   #4
            beq   :lsdone
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   LSIDX
            bra   :lslp
:lsdone     lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* SAYOPRND -- `kill: ` + the current operand, to stderr. The
* operand TEXT is echoed, not the parsed value -- `kill 3x`
* names `3x`.
*---------------------------------------------------------------
SAYOPRND    lda   PTR0                   ;operand ptr, saved
            sta   OPSAVE                 ;across the prefix PUTS
            lda   PTR0+1
            sta   OPSAVE+1
            lda   #<M_PREFIX
            sta   PTR0
            lda   #>M_PREFIX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   OPSAVE
            sta   PTR0
            lda   OPSAVE+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            rts

*---------------------------------------------------------------
* SAYERR -- A/X = message tail; print to stderr + CR, set
* ERRFLAG.
*---------------------------------------------------------------
SAYERR      sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG
            rts

USAGEMSG    asc   "usage: kill [-s name | -signo] pid ... | "
            asc   "kill -l"
            dfb   $8D,0
M_PREFIX    asc   "kill: "
            dfb   0
M_NOSUCH    asc   ": no such process"
            dfb   0
M_CANT      asc   ": cannot kill"
            dfb   0
M_BADPID    asc   ": bad pid"
            dfb   0
S_DASHL     asc   "-l"
            dfb   0
S_DASHS     asc   "-s"
            dfb   0
SN_HUP      asc   "HUP"
            dfb   0
SN_INT      asc   "INT"
            dfb   0
SN_QUIT     asc   "QUIT"
            dfb   0
SN_KILL     asc   "KILL"
            dfb   0
SN_TERM     asc   "TERM"
            dfb   0
SNAMLO      dfb   <SN_HUP,<SN_INT,<SN_QUIT,<SN_KILL,<SN_TERM
SNAMHI      dfb   >SN_HUP,>SN_INT,>SN_QUIT,>SN_KILL,>SN_TERM

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/argv.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* kill's own arena -- dum/dend at the textual end, chained onto
* liba's block (the house idiom).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ERRFLAG     ds    1
ARGIDX      ds    1
NPIDS       ds    1
PIDVAL      ds    1
SIGNO       ds    1
OPSAVE      ds    2
SIGVAL      ds    1              ;MATCHSIG's own output
SG_TMP      ds    1              ;SIGNAMEIS's STRCMPI stash
LSIDX       ds    1              ;LISTSIGS' own loop index
            err   */$BF00
            dend
