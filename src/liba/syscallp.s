*---------------------------------------------------------------
* syscallp.s -- maux's own PROCESS calls (spawn/exit/wait/pipe/
* brk/pstat/clock -- concepts the ProDOS MLI has no equivalent
* for), dispatched through the kernel's K_DISP_LO/K_DISP_HI
* table (src/kernel/entry.s), call numbers from
* inc/sc.proc.equ. Split out of syscalls.s
* (docs/FAT.md sec 12's split ruling, measured 2026-08-21):
* only a program that actually invokes a process call needs to
* `put` this file -- file-only utilities never did, and paid
* for it anyway when this code lived in syscalls.s.
*
* SC_EXIT is NOT here even though SYS_EXIT is a process call by
* the same kernel boundary (K_DISP, not PRC_FILECALL) -- it
* stayed in syscalls.s. stdio.s's EXIT calls it directly and
* every program links stdio.s, so SC_EXIT is the one
* universally-needed exception; see syscalls.s's header for the
* reasoning.
*
* PROCPARM (the shared process-call scratch parameter block) is
* declared in syscalls.s, not here -- SC_EXIT needs it there,
* and check_modules.py's check_userland() forbids a symbol
* defined in two liba modules. Every consumer of this file also
* `put`s syscalls.s (SC_EXIT alone would require it even if
* nothing else did), so PROCPARM is always in scope by the time
* these routines reference it.
*
* Full design notes: L.SYSCALLS.TXT (docs/a2/)
*---------------------------------------------------------------

* See L.SYSCALLS.TXT: "SCSPAWN -- spawn(path argv fdactions). f"
*-- FOURTH ARGUMENT, 2026-08-22 (docs/SYSCALL.md item 13c): the
*-- environment. It comes from SPWN_ENVP (src/liba/libabss.s)
*-- rather than a fourth ZP pointer pair -- PTR0-PTR2 are the
*-- whole of liba's pointer window and SC_SPAWN needs no
*-- indirect addressing through this one, it just hands the
*-- address to the kernel.
*--
*-- EVERY CALLER MUST WRITE SPWN_ENVP (zero for "no
*-- environment") immediately before the call, exactly as it
*-- writes PTR0-PTR2. It is uncleared storage, not a sticky
*-- setting: leaving it unwritten is the same bug as leaving
*-- PTR1 unwritten, and a stale value from a previous spawn is
*-- the same bug as a stale PTR1.
SC_SPAWN    lda   PTR0
            sta   PROCPARM+0
            lda   PTR0+1
            sta   PROCPARM+1
            lda   PTR1
            sta   PROCPARM+2
            lda   PTR1+1
            sta   PROCPARM+3
            lda   PTR2
            sta   PROCPARM+4
            lda   PTR2+1
            sta   PROCPARM+5
            lda   SPWN_ENVP
            sta   PROCPARM+6
            lda   SPWN_ENVP+1
            sta   PROCPARM+7
            lda   #<PROCPARM     ; parms pointer, low byte, in A
            ldx   #>PROCPARM     ;parms pointer, high byte, in X
            ldy   #SYS_SPAWN     ; call number in Y
            jsr   $FF00          ; THE gate
            rts

*---------------------------------------------------------------
* SC_TICK -- elapsed time. IN: PTR0 = a 5-byte buffer. OUT:
* carry CLEAR and the buffer filled --
*   +0      timer mode: 1 mouse VBL, 2 Mockingboard, 3 COOP
*   +1..+4  32-bit little-endian serviced-tick count
*
* MODE 3 MEANS THE COUNT NEVER CHANGES. Callers that measure
* elapsed time must check the mode FIRST and refuse, not poll --
* see src/kernel/procfile3.s's PRC_TICK header, and docs/
* SHELL-GAPS.md sec 5 for why a clock is not a substitute.
*---------------------------------------------------------------
* SC_VCSTAT -- vcstat(bufout). PTR0 = a VC_COUNT-byte buffer;
* on return byte N holds the pid attached to console N+1, or 0.
* Lazy consoles (docs/COVER-OFF.md): `chvt` asks this before it
* decides whether the console it is about to show anyone needs
* a shell spawned on it first.
SC_VCSTAT   lda   PTR0
            sta   PROCPARM+0
            lda   PTR0+1
            sta   PROCPARM+1
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_VCSTAT
            jsr   $FF00
            rts

*---------------------------------------------------------------
* SC_HALT -- halt(mode). A = the mode byte (HALT_DOWN).
*
* IT DOES NOT RETURN, so there is no `rts` below and the `jsr`
* is a formality the caller never comes back from. Say whatever
* you have to say and flush it BEFORE calling: by the time the
* kernel has read the mode byte every open file is closed and
* the glass belongs to the motherboard again, so a later write
* has no console to reach and no file to land in.
*
* This lives in syscallp.s rather than in `shutdown` itself for
* the reason the file exists: it is a PROCESS call, it is opt-in
* (a utility that never halts never pays for it), and `bye` will
* want the same door.
*---------------------------------------------------------------
SC_HALT     sta   PROCPARM+0
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_HALT
            jsr   $FF00
            rts                   ;only reachable if the kernel
                                  ;REFUSED the call

*---------------------------------------------------------------
* SC_BYE -- bye(path). docs/BYE.md "Slice 2 launch". IN: PTR0 =
* 0/0 for a bare `bye` (docs/BYE-SLICE1.md, slice 1 --
* unchanged), or a pointer to an MLI-format, length-prefixed
* pathname (bye.s builds it with MKPATH) naming a .SYSTEM to
* launch. Reuses
* PROCPARM (syscalls.s, 6 B, idle between syscalls) at offsets
* +1/+2 -- PRC_BYE (procbye.s) reads them at the SAME offsets
* MLI_PATHLO/MLI_PATHHI use, so its own PCPY_MLI_PATH needs no
* special-casing for this call.
*
* Unlike SC_HALT, THIS ONE RETURNS -- through a real MLI QUIT
* and back, but the caller cannot tell: it comes back with A = 0
* like any other syscall, or with carry set and A = a real
* errno -- ERR_BYEPIN + an OFT index (1-15) names a pinned open
* file the launch could not park (bye.s decodes the range).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SC_BYE      lda   PTR0
            sta   PROCPARM+1
            lda   PTR0+1
            sta   PROCPARM+2
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_BYE
            jsr   $FF00
            rts

SC_TICK     lda   PTR0
            sta   PROCPARM+0
            lda   PTR0+1
            sta   PROCPARM+1
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_TICK
            jsr   $FF00
            rts

* See L.SYSCALLS.TXT: "SCWAIT -- wait(statusout). Scoped to the"
SC_WAIT     lda   PTR0
            sta   PROCPARM+0
            lda   PTR0+1
            sta   PROCPARM+1
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

*---------------------------------------------------------------
* SC_PIPE -- pipe(&fds_out). Kernel writes two bytes to fds_out:
* [0] = read-end fd, [1] = write-end fd (V6/Unix ordering).
* IN:  PTR0/PTR0+1 = pointer to a 2-byte output buffer
* OUT: carry clear/set, A = errno on failure
*---------------------------------------------------------------
SC_PIPE     lda   PTR0
            sta   PROCPARM+0
            lda   PTR0+1
            sta   PROCPARM+1
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_PIPE
            jsr   $FF00
            rts

* SC_BRK MOVED to src/liba/brk.s (2026-08-22), together with
* its new sibling SC_SBRK. It sat here unused from task #3
* until then -- PRC_BRK was an ERR_NOSYS stub, so no program
* had ever called it -- and only `sort` and `ed` have a heap.
* A liba module is linked WHOLE (docs/REL-LIBA-SPIKE.md), so
* leaving the heap calls here would have charged those two for
* SC_SPAWN/SC_WAIT/SC_PIPE/SC_PSTAT/SC_CLOCK as well.

* See L.SYSCALLS.TXT: "FILE CALLS -- bare gates. The"
*-- SC_PSTAT -- pstat(slot, buf). IN: A = slot index,
*-- PTR0 = 6-byte record buffer. Process calls carry NO
*-- param_count byte; the parmlist is just the arguments.
SC_PSTAT    sta   PROCPARM+0     ;slot index
            lda   PTR0
            sta   PROCPARM+1
            lda   PTR0+1
            sta   PROCPARM+2
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_PSTAT
            jsr   $FF00
            rts

*-- SC_FORK -- fork(). One call, two returns: parent gets the
*-- child's pid in A (never 0), child gets 0, carry clear on
*-- both; carry set + A = ERR_AGAIN when no bank is free
*-- (docs/FORK.md). fork() takes NO parameters and the kernel
*-- ignores the parms pointer entirely, so A/X carry a literal
*-- $FF -- BY CONSTRUCTION nonzero, not by the accident of
*-- PROCPARM's address byte: with A = 0 going in, a kernel
*-- that forgot to patch the child's frame-A would hand the
*-- child a 0 that reads as success (the exact vacuous-
*-- sabotage shape docs/FORK.md records), and PROCPARM's low
*-- byte would be one liba layout shift away from being that
*-- 0. CLOBBERS: X, Y.
SC_FORK     lda   #$FF
            tax
            ldy   #SYS_FORK
            jsr   $FF00
            rts

*-- SC_KILL -- kill(pid, signo). IN: A = target pid, X = signo
*-- (0 = V7's liveness probe: validate, kill nothing). OUT:
*-- carry clear on success; carry set and A = ERR_SRCH (no such
*-- live process) or ERR_INVAL (root tier refused). DELIVERY
*-- honours the TARGET's disposition since 2026-09-02
*-- (docs/SIGNALS.md): IGN discards, CATCH holds the signo for
*-- the target's own SC_SIGPEND (and fails its blocked syscall
*-- out with ERR_INTR), DFL terminates with wait status
*-- $80|signo (kill's default 15 reaps $8F; ^C's own lane is
*-- $82). Signo 9 force-kills regardless. Process call -- no
*-- param_count byte. CLOBBERS: X, Y.
SC_KILL     sta   PROCPARM+0
            stx   PROCPARM+1
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_KILL
            jsr   $FF00
            rts

*-- SC_SIGNAL -- signal(signo, action). IN: A = signo (1-15,
*-- not 9), X = SIGA_DFL/SIGA_IGN/SIGA_CATCH. OUT: carry clear,
*-- A = the PREVIOUS action; carry set, A = ERR_INVAL. Held-
*-- signal model: CATCH pends the signal for SC_SIGPEND rather
*-- than jumping anywhere -- docs/SIGNALS.md sec 1 names the
*-- async upgrade trigger. Dispositions are sticky (A12).
*-- CLOBBERS: X, Y.
SC_SIGNAL   sta   PROCPARM+0
            stx   PROCPARM+1
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_SIGNAL
            jsr   $FF00
            rts

*-- SC_SIGPEND -- sigpend(): pop the lowest pending held signo.
*-- OUT: carry clear, A = signo (0 = none pending). Drain in a
*-- loop; V7 trap's "executed in order of signal number" is the
*-- lowest-first order this returns. CLOBBERS: X, Y.
SC_SIGPEND  ldy   #SYS_SIGPEND
            jsr   $FF00
            rts

*-- SC_CLOCK -- clock(&buf4_out). Kernel writes the raw ProDOS
*-- Global Page date/time words ($BF90-$BF93) to buf4_out,
*-- uninterpreted (docs/PROCIO.md sec 1). IN: PTR0 = pointer to
*-- a 4-byte output buffer. Process call -- NO param_count byte,
*-- same as SC_PIPE above.
SC_CLOCK    lda   PTR0
            sta   PROCPARM+0
            lda   PTR0+1
            sta   PROCPARM+1
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_CLOCK
            jsr   $FF00
            rts

*---------------------------------------------------------------
* SC_DUP2 -- dup2(oldfd, newfd). Point one of THIS process's fd
* slots at an object another of its slots already holds.
*
* IN:  A = oldfd, X = newfd.
* OUT: carry clear, A = newfd. Carry set, A = errno.
*
* Process call, so a two-byte parameter block with NO
* param_count byte -- same shape as SC_PIPE/SC_CLOCK above.
*
* Register-passed rather than pointer-passed because both
* arguments are single bytes and every caller has them in
* registers already; building a block in the caller to have the
* kernel read it straight back out would be two stores and a
* pointer for nothing.
*
* THE ONE SEMANTIC WORTH KNOWING AT THE CALL SITE: dup2(fd, fd)
* on an OPEN fd is a no-op that returns fd -- it does NOT close
* and reopen it. On a CLOSED fd it is an error. That asymmetry
* is POSIX's and it is deliberate; see PRC_DUP2's header.
* CLOBBERS: X, Y.
*---------------------------------------------------------------
SC_DUP2     sta   PROCPARM+0     ;oldfd
            stx   PROCPARM+1     ;newfd
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_DUP2
            jsr   $FF00
            rts

*---------------------------------------------------------------
* SC_TTYGEO -- ttygeo(buf, fd): the console geometry behind a
* tty fd (docs/VIDMODE.md sec 2). IN: PTR0 = a 4-byte buffer,
* A = fd. OUT: carry clear and the buffer filled --
*   +0 cols   +1 rows   +2 backend id   +3 discipline
* Carry set, A = errno -- ERR_INVAL for any fd that is not a
* console (files and pipes have no geometry). CLOBBERS: X, Y.
*---------------------------------------------------------------
SC_TTYGEO   sta   PROCPARM+2     ;fd
            lda   PTR0
            sta   PROCPARM+0
            lda   PTR0+1
            sta   PROCPARM+1
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_TTYGEO
            jsr   $FF00
            rts

*---------------------------------------------------------------
* SC_TTYMODE -- ttymode(fd, newflags): SET the console behind a
* tty fd's mode flags (TMD_ICANON/TMD_ECHO, inc/syscall-
* proc.equ -- stty(1) seed). IN: A = fd, X = newflags. OUT:
* carry clear, A = the PREVIOUS flags (save-and-restore, the
* SC_SIGNAL shape); carry set, A = ERR_INVAL for a non-console
* fd. CLOBBERS: X, Y.
*---------------------------------------------------------------
SC_TTYMODE  sta   PROCPARM+0     ;fd
            stx   PROCPARM+1     ;newflags
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_TTYMODE
            jsr   $FF00
            rts

*-- SC_TCSETFG -- tcsetfg(&job): declare the caller's console's
*-- FOREGROUND JOB (docs/JOB-CONTROL.md Increment A). IN: PTR0 =
*-- pointer to {count, pid0, pid1, pid2}, count 0..TCSETFG_MAX
*-- (0 = nothing is foreground, the idle prompt). The block is
*-- handed to the kernel AS the parameter block -- it is already
*-- the shape PRC_TCSETFG copies in, so no PROCPARM staging.
*-- OUT: carry clear; carry set, A = ERR_INVAL (fd 0 not a
*-- console, count too large, or a pid that is not the caller's
*-- child). CLOBBERS: A, X, Y.
SC_TCSETFG  lda   PTR0
            ldx   PTR0+1
            ldy   #SYS_TCSETFG
            jsr   $FF00
            rts

*-- SC_CONT -- cont(pid): resume a STOPPED child (docs/JOB-
*-- CONTROL.md Increment B, the SIGCONT equivalent). IN: A =
*-- pid. OUT: carry clear; carry set, A = ERR_INVAL (not the
*-- caller's child, or not stopped). CLOBBERS: X, Y.
SC_CONT     sta   PROCPARM+0
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_CONT
            jsr   $FF00
            rts

*-- SC_WAITJOB -- waitjob(&status2, flags): the job-control
*-- wait. IN: PTR0 = a 2-byte buffer, A = WJ_NOHANG/WJ_UNTRACED
*-- bits. OUT: carry clear, A = the child's pid and the buffer
*-- holds {kind, code} (WJ_EXITED + status / WJ_SIGNALED + signo
*-- / WJ_STOPPED + 0); A = 0 when WJ_NOHANG found nothing ready
*-- (buffer untouched). Carry set, A = ERR_CHILD: no children,
*-- or every child is stopped and WJ_UNTRACED was not asked.
*-- CLOBBERS: X, Y.
SC_WAITJOB  sta   PROCPARM+2     ;flags
            lda   PTR0
            sta   PROCPARM+0
            lda   PTR0+1
            sta   PROCPARM+1
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_WAITJOB
            jsr   $FF00
            rts

*-- SC_STOP -- stop(): park the caller until a SYS_CONT resumes
*-- it (docs/JOB-CONTROL.md Increment E). No parameters; returns
*-- 0 when continued. vi's cooperative-^Z half calls it between
*-- rmcup and smcup. CLOBBERS: A, X, Y.
SC_STOP     ldy   #SYS_STOP
            jsr   $FF00
            rts
