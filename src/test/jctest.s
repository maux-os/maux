*---------------------------------------------------------------
* jctest.s -- job-control Increment B, the SYSCALL-LEVEL harness
* (docs/JOB-CONTROL.md; scripts/check_jobctl_b.py drives it on
* build/jobctl.po, a play.po clone with this program staged at
* /bin/JCTEST). No shell UX exists yet -- this program IS
* the "shell": it spawns a child, declares it the console's
* foreground job, and then exercises the three kernel pieces the
* gate asserts on the glass and in the annex PCB table:
*
*   1. ^Z (typed by the gate) STOPS the child -- SYS_WAITJOB
*      with WJ_UNTRACED returns {WJ_STOPPED, 0}; SYS_PSTAT reads
*      PCB_STOPPED (5); the console, put into RAW mode here
*      before the spawn, is back to cooked+echo (PRC_TMD_RST).
*   2. SYS_CONT resumes it (RUNNABLE/RUNNING/BLOCKED again);
*      SYS_WAITJOB with WJ_NOHANG then returns 0 -- running, not
*      stopped, nothing to report.
*   3. a SECOND ^Z reports Stopped again (the report-once
*      invariant lives with the consumer, not the kernel).
*   4. the LEGACY SYS_WAIT, with the only child stopped and
*      WJ_UNTRACED unavailable to it, returns ERR_CHILD instead
*      of sleeping forever.
*   5. this program EXITS with the child still STOPPED: the
*      orphan reap (PRC_REAP_ORPH) must free the child's slot
*      and bank -- the gate proves no bank leaks.
*
* THE PAUSES: after each report the program waits for a line
* holding a `G` before moving on, so the gate can peek the
* annex between steps. Not "any line": ^Z, like ^C, completes
* an EMPTY line on the console (tty3.s TTY_INTR_TL), which a
* plain "wait for return" would swallow as its go signal.
*
* Every line printed starts `JC ` so the gate can grep the
* glass; numbers are two hex digits (pids are < 48).
*   6. SYS_TCSETFG ABI rows (TAB-A2): the caller may name ITSELF
*      (so a raw-mode shell can receive the ^C/^Z it would
*      otherwise read as a bare CR), a pid that is neither a
*      child nor the caller is still ERR_INVAL with the set
*      untouched, a mixed {self, child} set is accepted, and
*      {0} clears. Each row prints `JC TCxxx rc=nn` and waits
*      for a G so the gate can peek VC_FGJOB.
*
* Uses liba only; the one child is `sleep 200`, a polling,
* never-exiting job (check_jobctl_a.py's own choice).
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/mm.procbnk2.equ ;BANK_ID = our pid
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            put   ../../inc/errno.krn.equ
            org   LOAD_BASE
            dsk   ../../build/jctest.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

START
*-- 0a. Wait for the gate's first G BEFORE declaring anything:
*-- the shell declares its foreground job (this program) AFTER
*-- spawning it, so a declaration made here straight away can
*-- be OVERWRITTEN by the shell's own when it next runs (the
*-- spawn window docs/CONSOLE.md sec 4 names). The gate sends G
*-- once VC_FGJOB[0] names this pid.
            lda   #<M_READY
            jsr   PUTMSG
            jsr   PUTCR
            jsr   WAITGO
*-- 0b. RAW console (no ICANON, no ECHO) so the ^Z sweep's
*-- cooked+echo restore is an observable transition, not a
*-- no-op. The child inherits fd 0 = this console.
            lda   #FD_STDIN
            ldx   #TMD_OPOST            ;raw = ICANON/ECHO
            jsr   SC_TTYMODE            ;clear, OPOST kept (vi's
                                        ;(VT102 slice 1) -- the
                                        ;^Z echo's CR must still
                                        ;newline
            bcs   :tmfail
            sta   SAVEMODE
*-- 1. spawn the child.
            lda   #<PATH_SLEEP
            sta   PTR0
            lda   #>PATH_SLEEP
            sta   PTR0+1
            lda   #<ARGV_BLK
            sta   PTR1
            lda   #>ARGV_BLK
            sta   PTR1+1
            stz   PTR2                   ;no fdactions: inherit
            stz   PTR2+1
            stz   SPWN_ENVP
            stz   SPWN_ENVP+1
            jsr   SC_SPAWN
            bcs   :spfail
            sta   CHILD
*-- 2. declare it THE foreground job of this console.
            lda   #1
            sta   FGBLK
            lda   CHILD
            sta   FGBLK+1
            stz   FGBLK+2
            stz   FGBLK+3
            lda   #<FGBLK
            sta   PTR0
            lda   #>FGBLK
            sta   PTR0+1
            jsr   SC_TCSETFG
            bcs   :fgfail
*-- 3. block in waitjob(WUNTRACED) until the gate's ^Z.
            lda   #<M_WAIT
            jsr   PUTMSG
            lda   CHILD
            jsr   PUTHEX2
            jsr   PUTCR
            jsr   WAITJOB_UT
            bcs   :wjfail
            lda   #<M_STOP
            jsr   REPORT
            jsr   WAITGO
            bra   :cont
:tmfail     ldx   #'T'
            jmp   FAIL
:spfail     ldx   #'S'
            jmp   FAIL
:fgfail     ldx   #'F'
            jmp   FAIL
:wjfail     ldx   #'W'
            jmp   FAIL
*-- 4. continue it, report its state, pause.
:cont       lda   CHILD
            jsr   SC_CONT
            bcs   :ctfail
            jsr   PSTAT_CHILD
            lda   #<M_CONT
            jsr   PUTMSG
            lda   PSBUF+1
            jsr   PUTHEX2
            jsr   PUTCR
            jsr   WAITGO
*-- 5. waitjob(WNOHANG): a running child is not ready -> 0.
            lda   #<WJBUF
            sta   PTR0
            lda   #>WJBUF
            sta   PTR0+1
            lda   #WJ_NOHANG
            jsr   SC_WAITJOB
            bcs   :nhfail
            pha
            lda   #<M_NOHANG
            jsr   PUTMSG
            pla
            jsr   PUTHEX2
            jsr   PUTCR
*-- 6. second stop: block again until the gate's second ^Z.
            lda   #<M_WAIT2
            jsr   PUTMSG
            jsr   PUTCR
            jsr   WAITJOB_UT
            bcs   :wj2fail
            lda   #<M_STOP2
            jsr   REPORT
            jsr   WAITGO
            bra   :legacy
:ctfail     ldx   #'C'
            jmp   FAIL
:nhfail     ldx   #'N'
            jmp   FAIL
:wj2fail    ldx   #'X'
            jmp   FAIL
*-- 7. the legacy wait must NOT sleep on an all-stopped set.
:legacy     lda   #<WSTAT
            sta   PTR0
            lda   #>WSTAT
            sta   PTR0+1
            jsr   SC_WAIT
            bcs   :legerr
            pha
            lda   #<M_LEGRC
            jsr   PUTMSG
            pla
            jsr   PUTHEX2
            jsr   PUTCR
            bra   :tcrows
:legerr     pha
            lda   #<M_LEGERR
            jsr   PUTMSG
            pla
            jsr   PUTHEX2
            jsr   PUTCR
*-- 7b. SYS_TCSETFG ABI rows. The child is STOPPED, still ours.
:tcrows     lda   #1                     ;{self}: accepted
            sta   FGBLK
            lda   BANK_ID
            sta   FGBLK+1
            stz   FGBLK+2
            stz   FGBLK+3
            lda   #<M_TCSELF
            jsr   TCROW
            lda   #1                     ;{pid 1}: no child, not
            sta   FGBLK                  ;us: refused, set stays
            lda   #1                     ;{self}
            sta   FGBLK+1
            lda   #<M_TCNONE
            jsr   TCROW
            lda   #2                     ;{self, child}: ok
            sta   FGBLK
            lda   BANK_ID
            sta   FGBLK+1
            lda   CHILD
            sta   FGBLK+2
            lda   #<M_TCTWO
            jsr   TCROW
            stz   FGBLK                  ;{0}: clears
            lda   #<M_TCCLR
            jsr   TCROW
*-- 7c. a SELF set matches only itself (R1 of the review): the
*-- child RUNS again, the caller catches INT and declares
*-- {self}, and the gate types ^C. The caller must get the INT;
*-- the child, a child of the declarer and not a member, must
*-- not be swept.
            lda   CHILD
            jsr   SC_CONT
            lda   #2
            ldx   #SIGA_CATCH
            jsr   SC_SIGNAL
            lda   #1
            sta   FGBLK
            lda   BANK_ID
            sta   FGBLK+1
            stz   FGBLK+2
            stz   FGBLK+3
            lda   #<M_TCSUBA
            jsr   TCROW
            ldx   #FD_STDIN              ;block until the ^C
            jsr   GETC
            jsr   SC_SIGPEND
            sta   SIGSAVE
            jsr   PSTAT_CHILD
            lda   #<M_TCSUB
            jsr   PUTMSG
            lda   SIGSAVE
            jsr   PUTHEX2
            lda   #<M_ST
            jsr   PUTMSG
            lda   PSBUF+1
            jsr   PUTHEX2
            jsr   PUTCR
            jsr   WAITGO
            lda   CHILD                  ;it runs: kill it,
            ldx   #9                     ;nothing live at exit
            jsr   SC_KILL
*-- 8. leave (the orphan reap frees the dead child's slot).
:exit       lda   #<M_EXIT
            jsr   PUTMSG
            jsr   PUTCR
            lda   #0
            jsr   SC_EXIT

*---------------------------------------------------------------
* TCROW -- A = low byte of a `JC TCxxx rc=` message: declare
* FGBLK with SYS_TCSETFG, print the message and the result (00,
* or the errno), then wait for the gate's G.
*---------------------------------------------------------------
TCROW       pha
            lda   #<FGBLK
            sta   PTR0
            lda   #>FGBLK
            sta   PTR0+1
            jsr   SC_TCSETFG
            bcs   :err
            lda   #0
:err        sta   ERRSAVE
            pla
            jsr   PUTMSG
            lda   ERRSAVE
            jsr   PUTHEX2
            jsr   PUTCR
            jmp   WAITGO

*---------------------------------------------------------------
* FAIL -- X = a step letter, A = the errno. Prints `JC FAIL x
* err=nn`, restores the console mode this program changed, exits
* 1. The gate treats any `JC FAIL` line as the verdict.
*---------------------------------------------------------------
FAIL        sta   ERRSAVE
            stx   STEP
            lda   #<M_FAIL
            jsr   PUTMSG
            lda   STEP
            ora   #$80
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #<M_ERR
            jsr   PUTMSG
            lda   ERRSAVE
            jsr   PUTHEX2
            jsr   PUTCR
            lda   #FD_STDIN
            ldx   #TMD_ICANON+TMD_ECHO+TMD_OPOST
            jsr   SC_TTYMODE
            lda   #1
            jsr   SC_EXIT

*---------------------------------------------------------------
* WAITJOB_UT -- waitjob(WJBUF, WJ_UNTRACED); A = pid, carry as
* the kernel's. Then PSTAT the child so REPORT has both.
*---------------------------------------------------------------
WAITJOB_UT  lda   #<WJBUF
            sta   PTR0
            lda   #>WJBUF
            sta   PTR0+1
            lda   #WJ_UNTRACED
            jsr   SC_WAITJOB
            bcs   :out
            sta   WJPID
            jsr   PSTAT_CHILD
            clc
:out        rts

*---------------------------------------------------------------
* PSTAT_CHILD -- SYS_PSTAT(CHILD) into PSBUF (6 bytes: pid,
* state, wchan, bank, parent, exitstat). A failure is fatal.
*---------------------------------------------------------------
PSTAT_CHILD lda   #<PSBUF
            sta   PTR0
            lda   #>PSBUF
            sta   PTR0+1
            lda   CHILD
            jsr   SC_PSTAT
            bcs   :psfail
            rts
:psfail     ldx   #'P'
            jmp   FAIL

*---------------------------------------------------------------
* REPORT -- A = low byte of a `JC STOPn ` message (high byte is
* the same page as every message here): print it, then
* `pid=xx kind=xx code=xx st=xx` from WJPID/WJBUF/PSBUF.
*---------------------------------------------------------------
REPORT      jsr   PUTMSG
            lda   #<M_PID
            jsr   PUTMSG
            lda   WJPID
            jsr   PUTHEX2
            lda   #<M_KIND
            jsr   PUTMSG
            lda   WJBUF
            jsr   PUTHEX2
            lda   #<M_CODE
            jsr   PUTMSG
            lda   WJBUF+1
            jsr   PUTHEX2
            lda   #<M_ST
            jsr   PUTMSG
            lda   PSBUF+1
            jsr   PUTHEX2
            jmp   PUTCR

*---------------------------------------------------------------
* WAITGO -- read console bytes until a `G` arrives, then through
* the end of that line. See the header for why not "any line".
*---------------------------------------------------------------
WAITGO      ldx   #FD_STDIN
            jsr   GETC
            bcs   WAITGO
            and   #$7F
            cmp   #'G'
            bne   WAITGO
:eol        ldx   #FD_STDIN
            jsr   GETC
            bcs   :done
            and   #$7F
            cmp   #$0D
            bne   :eol
:done       rts

*---------------------------------------------------------------
* Output helpers. PUTMSG: A = low byte of a message (all
* messages sit in one page, MSGPAGE). PUTHEX2: A as two hex
* digits. PUTCR: end the line (PUTC flushes the console fd on
* CR). All to FD_STDOUT.
*---------------------------------------------------------------
PUTMSG      sta   PTR0
            lda   #>M_WAIT
            sta   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS

PUTHEX2     pha
            lsr
            lsr
            lsr
            lsr
            jsr   PUTNYB
            pla
            and   #$0F
PUTNYB      cmp   #10
            bcc   :digit
            adc   #6                     ;carry set: +7 -> 'A'
:digit      adc   #'0'
            ora   #$80
            ldx   #FD_STDOUT
            jmp   PUTC

PUTCR       lda   #$8D
            ldx   #FD_STDOUT
            jmp   PUTC

*---------------------------------------------------------------
* Constants. The spawn path is absolute (the lazy-free tag key
* needs one; sh's own PATHTAB is spelled the same way). The
* messages all live in one 256-byte page so PUTMSG can pass a
* low byte -- `ds \` aligns MSGPAGE and the `err` proves the
* page holds them.
*---------------------------------------------------------------
PATH_SLEEP  asc   "/bin/SLEEP"
            dfb   0
AV_NAME     asc   "sleep"
            dfb   0
AV_SECS     asc   "200"
            dfb   0
ARGV_BLK    da    AV_NAME
            da    AV_SECS
            da    0

            ds    \
MSGPAGE
M_WAIT      asc   "JC WAIT pid="
            dfb   0
M_READY     asc   "JC READY"
            dfb   0
M_STOP      asc   "JC STOP"
            dfb   0
M_STOP2     asc   "JC STOP2"
            dfb   0
M_CONT      asc   "JC CONT st="
            dfb   0
M_NOHANG    asc   "JC NOHANG rc="
            dfb   0
M_WAIT2     asc   "JC WAIT2"
            dfb   0
M_LEGRC     asc   "JC LEGACY rc="
            dfb   0
M_LEGERR    asc   "JC LEGACY err="
            dfb   0
M_EXIT      asc   "JC EXIT"
            dfb   0
M_FAIL      asc   "JC FAIL "
            dfb   0
M_ERR       asc   " err="
            dfb   0
M_PID       asc   " pid="
            dfb   0
M_KIND      asc   " kind="
            dfb   0
M_CODE      asc   " code="
            dfb   0
M_ST        asc   " st="
            dfb   0
M_TCSELF    dfb   $CA,$C3,$A0,$D4,$C3,$D3,$C5,$CC
            dfb   $C6,$A0,$F2,$E3,$BD
            dfb   0
M_TCNONE    dfb   $CA,$C3,$A0,$D4,$C3,$CE,$CF,$CE
            dfb   $C5,$A0,$F2,$E3,$BD
            dfb   0
M_TCTWO     dfb   $CA,$C3,$A0,$D4,$C3,$D4,$D7,$CF
            dfb   $A0,$F2,$E3,$BD
            dfb   0
M_TCCLR     dfb   $CA,$C3,$A0,$D4,$C3,$C3,$CC,$D2
            dfb   $A0,$F2,$E3,$BD
            dfb   0
M_TCSUBA    dfb   $CA,$C3,$A0,$D4,$C3,$D3,$D5,$C2
            dfb   $C1,$A0,$F2,$E3,$BD
            dfb   0
M_TCSUB     dfb   $CA,$C3,$A0,$D4,$C3,$D3,$D5,$C2
            dfb   $A0,$F3,$E9,$E7,$BD
            dfb   0
MSGEND
            err   MSGEND-MSGPAGE-1/256   ;all on MSGPAGE's page

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/argv.s
            put   ../liba/libabss.s

            dum   LIBA_BSSEND
CHILD       ds    1
SAVEMODE    ds    1
STEP        ds    1
ERRSAVE     ds    1
WJPID       ds    1
WJBUF       ds    2
WSTAT       ds    1
FGBLK       ds    4
SIGSAVE     ds    1
PSBUF       ds    6
JC_BSSEND
            dend
