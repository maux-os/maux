*---------------------------------------------------------------
* processtestb2.s -- processtestb.s continued. Split 2026-09-02
* at the PTB_KILLC global label (a byte-neutral put boundary --
* the parent blob is copied whole by PAR_PROC_LEN, and a put
* boundary between two instructions inserts nothing): case 16
* (signals) pushed the single file past real Merlin's 41,215 B
* source buffer. The manifest puts this IMMEDIATELY after
* processtestb.s; every rule there applies unchanged.
*---------------------------------------------------------------

*---------------------------------------------------------------
* PTB_KILLC -- a zone boundary with a JOB: gen_rel_module's
* kernel-main segmenter cuts only at branch-safe GLOBAL labels,
* and the kill gauntlet grew this label-less stretch past the
* 13,000-byte segment window (2026-09-01). No :local crosses
* this line (case 14 ends at :d2rdok above; every :k_* lives
* below), so the cut is safe -- and the label changes no bytes.
*---------------------------------------------------------------
PTB_KILLC
            ;-- 15. SYS_KILL gauntlet (call 13). Each policy arm
            ;-- of PRC_KILL gets a cell; a wrong arm leaves its
            ;-- cell holding the wrong constant, never a maybe.
            ;-- BLOB LAW, relearned here the hard way: failure
            ;-- paths are INLINED at every site because a
            ;-- a jmp-to-:label in this copied blob goes to the
            ;-- ASSEMBLY address -- draft one's jmp-to-:k_fail
            ;-- sent the parent into uncopied bank bytes and the
            ;-- BRK trap (the header said so; believe it).
            ;-- 15a: an unused slot is ERR_SRCH.
            lda   #14
            sta   P_KILLP
            lda   #15
            sta   P_KILLP+1
            lda   #<P_KILLP
            ldx   #>P_KILLP
            ldy   #SYS_KILL
            jsr   $FF00
            bcc   :k_unexpa            ;success = wrong arm
            sta   R_K_ESRCH
            bra   :k_e0
:k_unexpa   lda   #$BB
            sta   R_K_ESRCH
            ;-- 15b: pid 0 is never a target.
:k_e0       stz   P_KILLP
            lda   #15
            sta   P_KILLP+1
            lda   #<P_KILLP
            ldx   #>P_KILLP
            ldy   #SYS_KILL
            jsr   $FF00
            bcc   :k_unexpb
            sta   R_K_E0
            bra   :k_blk
:k_unexpb   lda   #$BB
            sta   R_K_E0

            ;-- 15c: kill a spawned child and reap STATUS_INTR.
            ;-- This image links no timer, so no preemption: the
            ;-- reader has NOT run yet and the kill lands on a
            ;-- READY process, deterministically. (The BLOCKED
            ;-- flavor is ^C's production shape -- PRC_INTR_SWP,
            ;-- the same marking -- exercised by the console
            ;-- gates.) Fresh pipe, reader 'R' with rfd dup'd to
            ;-- fd 0, kill instead of write, then reap.
:k_blk      lda   #<P_KFDS
            sta   P_PIPEPARM
            lda   #>P_KFDS
            sta   P_PIPEPARM+1
            lda   #<P_PIPEPARM
            ldx   #>P_PIPEPARM
            ldy   #SYS_PIPE
            jsr   $FF00
            bcc   :k_pipeok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:k_pipeok   lda   #FDACT_DUP
            sta   P_RFDA
            stz   P_RFDA+1
            lda   P_KFDS
            sta   P_RFDA+2
            lda   #FDACT_CLOSE
            sta   P_RFDA+3
            lda   P_KFDS+1
            sta   P_RFDA+4
            stz   P_RFDA+5
            stz   P_RFDA+6
            lda   #'R'+$80
            sta   P_PATH
            stz   P_PATH+1
            lda   #<P_PATH
            sta   P_ARGV
            lda   #>P_PATH
            sta   P_ARGV+1
            stz   P_ARGV+2
            stz   P_ARGV+3
            lda   #<P_PATH
            sta   P_SPAWN
            lda   #>P_PATH
            sta   P_SPAWN+1
            lda   #<P_ARGV
            sta   P_SPAWN+2
            lda   #>P_ARGV
            sta   P_SPAWN+3
            lda   #<P_RFDA
            sta   P_SPAWN+4
            lda   #>P_RFDA
            sta   P_SPAWN+5
            stz   P_SPAWN+6           ;NULL envp
            stz   P_SPAWN+7
            lda   #<P_SPAWN
            ldx   #>P_SPAWN
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcc   :k_spwok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:k_spwok    sta   R_K_PID
            sta   P_KILLP
            stz   P_KILLP+1           ;signo 0: the liveness
            lda   #<P_KILLP           ;probe -- kills nothing
            ldx   #>P_KILLP
            ldy   #SYS_KILL
            jsr   $FF00
            bcc   :k_alive
            sta   R_K_SIG0            ;errno where $00 belongs
            bra   :k_realk
:k_alive    stz   R_K_SIG0
:k_realk    lda   #15                 ;now the TERM lane
            sta   P_KILLP+1
            lda   #<P_KILLP
            ldx   #>P_KILLP
            ldy   #SYS_KILL
            jsr   $FF00
            bcc   :k_retok
            sta   R_K_RET             ;errno where $00 belongs
            bra   :k_reap
:k_retok    stz   R_K_RET
:k_reap     lda   #<R_K_WSTAT
            sta   P_WAIT
            lda   #>R_K_WSTAT
            sta   P_WAIT+1
            lda   #<P_WAIT
            ldx   #>P_WAIT
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :k_wtok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:k_wtok     sta   R_K_WPID
            ;-- drop the parent's pipe ends before the next case
            lda   #1
            sta   P_CLOSE
            lda   P_KFDS
            sta   P_CLOSE+1
            lda   #<P_CLOSE
            ldx   #>P_CLOSE
            ldy   #SYS_CLOSE
            jsr   $FF00
            lda   #1
            sta   P_CLOSE
            lda   P_KFDS+1
            sta   P_CLOSE+1
            lda   #<P_CLOSE
            ldx   #>P_CLOSE
            ldy   #SYS_CLOSE
            jsr   $FF00

            ;-- 15d: the root tier is refused -- from a CHILD,
            ;-- because from here kill(1) is kill(self). 'Q'
            ;-- tries kill(1) and exits with the errno it got.
            lda   #'Q'+$80
            sta   P_PATH
            stz   P_PATH+1
            stz   P_SPAWN+4           ;no fdactions
            stz   P_SPAWN+5
            lda   #<P_SPAWN
            ldx   #>P_SPAWN
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcc   :k_qok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:k_qok      lda   #<R_K_ROOT
            sta   P_WAIT
            lda   #>R_K_ROOT
            sta   P_WAIT+1
            lda   #<P_WAIT
            ldx   #>P_WAIT
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :k_self
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *

            ;-- 15e: kill(self) is exit(STATUS_INTR). 'K' reads
            ;-- its OWN pid off a pipe (spawn returns it only to
            ;-- us) and kills it; the reap must say $82.
:k_self     lda   #<P_KFDS
            sta   P_PIPEPARM
            lda   #>P_KFDS
            sta   P_PIPEPARM+1
            lda   #<P_PIPEPARM
            ldx   #>P_PIPEPARM
            ldy   #SYS_PIPE
            jsr   $FF00
            bcc   :k_pipe2
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:k_pipe2    lda   #FDACT_DUP
            sta   P_RFDA
            stz   P_RFDA+1
            lda   P_KFDS
            sta   P_RFDA+2
            lda   #FDACT_CLOSE
            sta   P_RFDA+3
            lda   P_KFDS+1
            sta   P_RFDA+4
            stz   P_RFDA+5
            stz   P_RFDA+6
            lda   #'K'+$80
            sta   P_PATH
            stz   P_PATH+1
            lda   #<P_RFDA
            sta   P_SPAWN+4
            lda   #>P_RFDA
            sta   P_SPAWN+5
            lda   #<P_SPAWN
            ldx   #>P_SPAWN
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcc   :k_kok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:k_kok      sta   P_D2BUF             ;the child's pid, by pipe
            lda   #4
            sta   P_D2IO
            lda   P_KFDS+1
            sta   P_D2IO+1
            lda   #<P_D2BUF
            sta   P_D2IO+2
            lda   #>P_D2BUF
            sta   P_D2IO+3
            lda   #1
            sta   P_D2IO+4
            stz   P_D2IO+5
            stz   P_D2IO+6
            stz   P_D2IO+7
            lda   #<P_D2IO
            ldx   #>P_D2IO
            ldy   #SYS_WRITE
            jsr   $FF00
            bcc   :k_fed
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:k_fed      lda   #<R_K_SELF
            sta   P_WAIT
            lda   #>R_K_SELF
            sta   P_WAIT+1
            lda   #<P_WAIT
            ldx   #>P_WAIT
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :k_done
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:k_done     lda   #1                  ;drop the case's pipes
            sta   P_CLOSE
            lda   P_KFDS
            sta   P_CLOSE+1
            lda   #<P_CLOSE
            ldx   #>P_CLOSE
            ldy   #SYS_CLOSE
            jsr   $FF00
            lda   #1
            sta   P_CLOSE
            lda   P_KFDS+1
            sta   P_CLOSE+1
            lda   #<P_CLOSE
            ldx   #>P_CLOSE
            ldy   #SYS_CLOSE
            jsr   $FF00

*---------------------------------------------------------------
* PTB_SIGC -- a byte-neutral REL segment cut point, same job as
* PTB_KILLC (2026-09-02): case 15 + case 16 form one label-less
* zone that outgrew gen_rel_module's 13,000B kernel-main segment
* window. No :local crosses this line (case 15's :k_* all sit
* above; case 16's :s_* all below), so the cut is safe and the
* label emits nothing.
*---------------------------------------------------------------
PTB_SIGC
            ;-- 16. SYS_SIGNAL/SIGPEND/EINTR (docs/SIGNALS.md).
            ;-- First free the fd table: 3-14 left pipe/dup2
            ;-- fds 3-7 open, and 16e's ready+data pipes need 4
            ;-- free slots at once. CLOSE of an unused fd errors
            ;-- harmlessly (ignored). No preemption here,
            ;-- so 16e's parent MUST block (read the ready pipe)
            ;-- to let 'C' run to its own block point -- a busy
            ;-- PSTAT poll would starve the child forever.
            ldx   #3
:s_fdswp    stx   P_CLOSE+1
            lda   #1
            sta   P_CLOSE
            phx
            lda   #<P_CLOSE
            ldx   #>P_CLOSE
            ldy   #SYS_CLOSE
            jsr   $FF00
            plx
            inx
            cpx   #8
            bne   :s_fdswp
            ;-- 16a: install CATCH on 2; previous must be DFL.
            lda   #2
            sta   P_KILLP
            lda   #SIGA_CATCH
            sta   P_KILLP+1
            lda   #<P_KILLP
            ldx   #>P_KILLP
            ldy   #SYS_SIGNAL
            jsr   $FF00
            bcc   :s_in1
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:s_in1      sta   R_S_OLD1
            ;-- 16b: kill(self,2) pends; sigpend pops 2, then 0.
            lda   #1
            sta   P_KILLP
            lda   #2
            sta   P_KILLP+1
            lda   #<P_KILLP
            ldx   #>P_KILLP
            ldy   #SYS_KILL
            jsr   $FF00
            bcc   :s_pn1
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:s_pn1      ldy   #SYS_SIGPEND
            jsr   $FF00
            sta   R_S_PEND1
            ldy   #SYS_SIGPEND
            jsr   $FF00
            sta   R_S_PEND0
            lda   #2                  ;restore DFL on 2
            sta   P_KILLP
            stz   P_KILLP+1
            lda   #<P_KILLP
            ldx   #>P_KILLP
            ldy   #SYS_SIGNAL
            jsr   $FF00
            ;-- 16c: IGN discards at the sender -- kill(self,15)
            ;-- under IGN returns and we live to say so.
            lda   #15
            sta   P_KILLP
            lda   #SIGA_IGN
            sta   P_KILLP+1
            lda   #<P_KILLP
            ldx   #>P_KILLP
            ldy   #SYS_SIGNAL
            jsr   $FF00
            lda   #1
            sta   P_KILLP
            lda   #15
            sta   P_KILLP+1
            lda   #<P_KILLP
            ldx   #>P_KILLP
            ldy   #SYS_KILL
            jsr   $FF00
            bcc   :s_alive
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:s_alive    lda   #$77
            sta   R_S_IGN
            lda   #15                 ;restore DFL on 15
            sta   P_KILLP
            stz   P_KILLP+1
            lda   #<P_KILLP
            ldx   #>P_KILLP
            ldy   #SYS_SIGNAL
            jsr   $FF00
            ;-- 16d: signal(9, anything) is refused.
            lda   #9
            sta   P_KILLP
            lda   #SIGA_CATCH
            sta   P_KILLP+1
            lda   #<P_KILLP
            ldx   #>P_KILLP
            ldy   #SYS_SIGNAL
            jsr   $FF00
            bcs   :s_e9ok
            lda   #$BB                ;accepted = wrong arm
:s_e9ok     sta   R_S_E9
            ;-- 16e: the EINTR lane. DATA pipe + READY pipe (the
            ;-- sweep above freed room). 'C' installs CATCH(15),
            ;-- writes a ready byte on fd1, then blocks reading
            ;-- fd0; the parent BLOCKS on the ready pipe (so
            ;-- 'C' gets to run), then kills -15. 'C's read must
            ;-- fail ERR_INTR and its sigpend must pop 15.
            lda   #<P_KFDS
            sta   P_PIPEPARM
            lda   #>P_KFDS
            sta   P_PIPEPARM+1
            lda   #<P_PIPEPARM
            ldx   #>P_PIPEPARM
            ldy   #SYS_PIPE
            jsr   $FF00
            bcc   :s_pipe1
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:s_pipe1    lda   #<P_RFDS
            sta   P_PIPEPARM
            lda   #>P_RFDS
            sta   P_PIPEPARM+1
            lda   #<P_PIPEPARM
            ldx   #>P_PIPEPARM
            ldy   #SYS_PIPE
            jsr   $FF00
            bcc   :s_pipe2
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:s_pipe2    lda   #FDACT_DUP          ;child fd0 = data read
            sta   P_RFDA
            stz   P_RFDA+1
            lda   P_KFDS
            sta   P_RFDA+2
            lda   #FDACT_DUP          ;child fd1 = ready write
            sta   P_RFDA+3
            lda   #1
            sta   P_RFDA+4
            lda   P_RFDS+1
            sta   P_RFDA+5
            stz   P_RFDA+6
            lda   #'C'+$80
            sta   P_PATH
            stz   P_PATH+1
            lda   #<P_RFDA
            sta   P_SPAWN+4
            lda   #>P_RFDA
            sta   P_SPAWN+5
            lda   #<P_SPAWN
            ldx   #>P_SPAWN
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcc   :s_cok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:s_cok      sta   P_D2BUF             ;child pid
            lda   #4                  ;block until 'C' is ready
            sta   P_D2IO
            lda   P_RFDS
            sta   P_D2IO+1
            lda   #<C_BUF
            sta   P_D2IO+2
            lda   #>C_BUF
            sta   P_D2IO+3
            lda   #1
            sta   P_D2IO+4
            stz   P_D2IO+5
            stz   P_D2IO+6
            stz   P_D2IO+7
            lda   #<P_D2IO
            ldx   #>P_D2IO
            ldy   #SYS_READ
            jsr   $FF00
            bcc   :s_ready
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:s_ready    lda   P_D2BUF
            sta   P_KILLP
            lda   #15
            sta   P_KILLP+1
            lda   #<P_KILLP
            ldx   #>P_KILLP
            ldy   #SYS_KILL
            jsr   $FF00
            bcc   :s_reap
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:s_reap     lda   #<R_S_EINTR
            sta   P_WAIT
            lda   #>R_S_EINTR
            sta   P_WAIT+1
            lda   #<P_WAIT
            ldx   #>P_WAIT
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :s_dclose
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:s_dclose   ldx   #0                  ;drop 16e's four pipe fds
:s_dcl      lda   P_KFDS,x
            beq   :s_dcln
            sta   P_CLOSE+1
            lda   #1
            sta   P_CLOSE
            phx
            lda   #<P_CLOSE
            ldx   #>P_CLOSE
            ldy   #SYS_CLOSE
            jsr   $FF00
            plx
:s_dcln     inx
            cpx   #2
            bne   :s_dcl
            ldx   #0
:s_dcl2     lda   P_RFDS,x
            beq   :s_dcl2n
            sta   P_CLOSE+1
            lda   #1
            sta   P_CLOSE
            phx
            lda   #<P_CLOSE
            ldx   #>P_CLOSE
            ldy   #SYS_CLOSE
            jsr   $FF00
            plx
:s_dcl2n    inx
            cpx   #2
            bne   :s_dcl2
:s_inh      lda   #3
            sta   P_KILLP
            lda   #SIGA_IGN
            sta   P_KILLP+1
            lda   #<P_KILLP
            ldx   #>P_KILLP
            ldy   #SYS_SIGNAL
            jsr   $FF00
            lda   #'I'+$80
            sta   P_PATH
            stz   P_PATH+1
            stz   P_SPAWN+4           ;no fdactions
            stz   P_SPAWN+5
            lda   #<P_SPAWN
            ldx   #>P_SPAWN
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcc   :s_iok
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:s_iok      lda   #<R_S_INH
            sta   P_WAIT
            lda   #>R_S_INH
            sta   P_WAIT+1
            lda   #<P_WAIT
            ldx   #>P_WAIT
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :s_restor
            sta   R_ERR
            lda   #$EE
            sta   R_DONE
            bra   *
:s_restor   lda   #3                  ;restore DFL on 3
            sta   P_KILLP
            stz   P_KILLP+1
            lda   #<P_KILLP
            ldx   #>P_KILLP
            ldy   #SYS_SIGNAL
            jsr   $FF00

            lda   #$AA
            sta   R_DONE
:halt       bra   :halt
PAR_PROC_END
PAR_PROC_LEN equ PAR_PROC_END-PARENT_PROC

SIMG_EXIT
            lda   $0200
            cmp   #1
            bne   :bad
            lda   $0201
            cmp   #<PRC_ARGV_STR
            bne   :bad
            lda   $0202
            cmp   #>PRC_ARGV_STR
            bne   :bad
            lda   PRC_ARGV_STR
            and   #$7F
            cmp   #'E'
            bne   :bad
            lda   #7
            bra   :exit
:bad        lda   #$E7
:exit       sta   C_PARML
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_EXIT
            jsr   $FF00
            bra   *
SIMG_EXIT_END

SIMG_READER
            lda   #4
            sta   C_PARML
            stz   C_PARML+1
            lda   #<C_BUF
            sta   C_PARML+2
            lda   #>C_BUF
            sta   C_PARML+3
            lda   #1
            sta   C_PARML+4
            stz   C_PARML+5
            stz   C_PARML+6
            stz   C_PARML+7
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_READ
            jsr   $FF00
            bcc   :readok
            lda   #$E1
            bra   :exit
:readok     lda   C_PARML+6
            cmp   #1
            bne   :badcnt
            lda   C_BUF
            cmp   #$42
            beq   :good
:badcnt     lda   #$E2
            bra   :exit
:good       lda   #$42
:exit       sta   C_PARML
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_EXIT
            jsr   $FF00
            bra   *
SIMG_RDR_END

SIMG_WRITER
            lda   #$42
            sta   C_BUF
            lda   #4
            sta   C_PARML
            lda   #1
            sta   C_PARML+1
            lda   #<C_BUF
            sta   C_PARML+2
            lda   #>C_BUF
            sta   C_PARML+3
            lda   #1
            sta   C_PARML+4
            stz   C_PARML+5
            stz   C_PARML+6
            stz   C_PARML+7
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_WRITE
            jsr   $FF00
            bcc   :writeok
            lda   #$E3
            bra   :exit
:writeok    lda   C_PARML+6
            cmp   #1
            beq   :good
            lda   #$E4
            bra   :exit
:good       lda   #$24
:exit       sta   C_PARML
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_EXIT
            jsr   $FF00
            bra   *
SIMG_WRTR_END

*---------------------------------------------------------------
* SIMG_BRK -- the 'B' child. Runs its own brk sequence to prove
* the break is PER-PROCESS state: it must see NO break at all
* (its parent has one, live, at the moment of the spawn), set
* one of its own, and read it back. Exits $B1 on success. If
* PCB_BRK were shared, or if a reused pid inherited the last
* occupant's break, the first call here would SUCCEED and this
* child would exit $BE.
*---------------------------------------------------------------
SIMG_BRK
            stz   C_PARML
            stz   C_PARML+1
            lda   #1
            sta   C_PARML+2         ;GROW 0, no break yet
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_BRK
            jsr   $FF00
            bcc   :bad              ;must be REFUSED
            cmp   #ERR_INVAL
            bne   :bad
            stz   C_PARML           ;SET $9000
            lda   #$90
            sta   C_PARML+1
            stz   C_PARML+2
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_BRK
            jsr   $FF00
            bcs   :bad
            stz   C_PARML           ;GROW 0 -- read it back
            stz   C_PARML+1
            lda   #1
            sta   C_PARML+2
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_BRK
            jsr   $FF00
            bcs   :bad
            lda   C_PARML+1
            cmp   #$90
            bne   :bad
            lda   #$B1
            bra   :exit
:bad        lda   #$BE
:exit       sta   C_PARML
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_EXIT
            jsr   $FF00
            bra   *
SIMG_BRK_END

* -- SYS_KILL gauntlet children (case 15). 'Q' proves the
* -- root-tier refusal from a pid that is NOT the root (from
* -- pid 1 itself, kill(1) would be kill(self)); 'K' proves
* -- kill(self), learning its own pid off fd 0 -- spawn hands
* -- the pid only to the parent, so the parent pipes it in.
SIMG_KROOT
            lda   #1
            sta   C_PARML             ;kill(1): root, refused
            lda   #15
            sta   C_PARML+1           ;signo 15 -- 0 would probe
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_KILL
            jsr   $FF00
            bcs   :exit               ;A = errno; exit with it
            lda   #$E6                ;unexpected success marker
:exit       sta   C_PARML
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_EXIT
            jsr   $FF00
            bra   *
SIMG_KRT_END

SIMG_KSELF
            lda   #4                  ;read my pid from fd 0
            sta   C_PARML
            stz   C_PARML+1
            lda   #<C_BUF
            sta   C_PARML+2
            lda   #>C_BUF
            sta   C_PARML+3
            lda   #1
            sta   C_PARML+4
            stz   C_PARML+5
            stz   C_PARML+6
            stz   C_PARML+7
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_READ
            jsr   $FF00
            bcs   :cantread
            lda   C_BUF
            sta   C_PARML             ;kill(my own pid)
            lda   #15
            sta   C_PARML+1           ;the TERM lane, explicitly
                                      ;-- a leftover 0 would be
                                      ;the probe and RETURN
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_KILL
            jsr   $FF00
*-- kill(self) must NOT return; reaching the next line is the
*-- failure, and it says so in the exit status.
            lda   #$E5
            bra   :exit
:cantread   lda   #$E4
:exit       sta   C_PARML
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_EXIT
            jsr   $FF00
            bra   *
SIMG_KSF_END

*-- 'C' (case 16e): install CATCH(15), announce readiness on
*-- fd1, block reading fd0. The read MUST come back ERR_INTR
*-- after the parent's kill -15, and sigpend must pop 15.
*-- Exit $45 = both true; every wrong lane exits distinctly.
SIMG_CATCH
            lda   #15
            sta   C_PARML
            lda   #SIGA_CATCH
            sta   C_PARML+1
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_SIGNAL
            jsr   $FF00
            bcc   :armed
            lda   #$E1
            bra   :exit
:armed      lda   #$C3               ;ready byte on fd1
            sta   C_BUF
            lda   #4
            sta   C_PARML
            lda   #1
            sta   C_PARML+1
            lda   #<C_BUF
            sta   C_PARML+2
            lda   #>C_BUF
            sta   C_PARML+3
            lda   #1
            sta   C_PARML+4
            stz   C_PARML+5
            stz   C_PARML+6
            stz   C_PARML+7
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_WRITE
            jsr   $FF00
            lda   #4                 ;block reading fd0 (data)
            sta   C_PARML
            stz   C_PARML+1
            lda   #<C_BUF
            sta   C_PARML+2
            lda   #>C_BUF
            sta   C_PARML+3
            lda   #1
            sta   C_PARML+4
            stz   C_PARML+5
            stz   C_PARML+6
            stz   C_PARML+7
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_READ
            jsr   $FF00
            bcs   :failed
            lda   #$E3               ;read SUCCEEDED = wrong
            bra   :exit
:failed     cmp   #ERR_INTR
            bne   :exit
            ldy   #SYS_SIGPEND
            jsr   $FF00
            cmp   #15
            beq   :good
            lda   #$E4
            bra   :exit
:good       lda   #$45
:exit       sta   C_PARML
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_EXIT
            jsr   $FF00
            bra   *
SIMG_CAT_END

*-- 'I' (case 16f): the spawn-inheritance probe. Parent set
*-- IGN(3) before spawning; signal(3, CATCH) must hand back
*-- the INHERITED old action -- $50+SIGA_IGN = $51.
SIMG_INHER
            lda   #3
            sta   C_PARML
            lda   #SIGA_CATCH
            sta   C_PARML+1
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_SIGNAL
            jsr   $FF00
            bcc   :asked
            lda   #$E5
            bra   :exit
:asked      clc
            adc   #$50
:exit       sta   C_PARML
            lda   #<C_PARML
            ldx   #>C_PARML
            ldy   #SYS_EXIT
            jsr   $FF00
            bra   *
SIMG_INH_END

* -- the pad places the verifier at a fixed block
* -- boundary; NBLOCKS below must equal ($XXXX-$0800)/512.
* -- History: $3800/24 -> $4000/28 (task #15, sticky.s) ->
* -- $4800/32 (2026-08-20, seek grew procfile.s+procfd2.s)
* -- -> $5000/36 (2026-08-23, S3: VC per-console state +
* -- native 80-col backend in tty.s/tty2.s) -> $5800/40
* -- (2026-08-31, per-fd console routing: TTY_WR_ENTER/LEAVE,
* -- VCS_SCROLL, the store row tables, /DEV/TTY1..4) ->
* -- $6000/44 (2026-09-01, VIDMODE V1: SYS_TTYGEO, the mode
* -- escape, TTY_ST_RFLW, the N8 blit hooks -- 437 B over).
* -- and procfd2.s past $4000 by 509B). merlin32 ERRORS on a
* -- negative ds; real Merlin-8 SILENTLY EMITS NOTHING and
* -- lets the next PUT overwrite -- see the commons,
* -- learning:01M0EDXWRX43PTQNR2WC0JT07F. Keep merlin32
* -- assembling FIRST so the loud failure always wins.
            ds    $8A00-*   ;65 (2026-10-22, OPEN-RW-2 +DUPFD-1:
                                  ;12 B over $8800); 64
                                  ;(2026-09-25: found already
                                  ;684 B over before this
                                  ;session; this session's own
                                  ;kernel growth -- procbye.s's
                                  ;PCB_SAVEDSP publish -- added
                                  ;~66B more, to 750 over; two
                                  ;blocks clears it);
                                  ;62 (SYS_VCSTAT, lazy
                                  ;consoles); 61 (wake-preempt);
                                  ;60 (sl5:
                                  ;XON/XOFF); 58->59 (sl 2:
                                  ;DCH/IRM/
                                     ;xenl, 351B over $7C00);
                                     ;57->58
                                     ;(VT102 sl 1: tty9.s,
                                     ;325B over $7A00); 56->57
                                     ;(ser.s ttya0; 56 IL/DL
                                     ;scroll: TTY_SCRL_REV
                                     ;et al, 349 B over $7400);
                                     ;53->54 (2026-09-08 jobctl
                                     ;B: PCB_STOPPED, the ^Z
                                     ;sweep, SYS_CONT/WAITJOB,
                                     ;the orphan reap -- 207 B
                                     ;over $7200);
                                     ;52 -> 53 (2026-09-08, job-
                                     ;control A: TCSETFG + the
                                     ;foreground ^C sweep,
                                     ;procspawn2.s -- 274 B over
                                     ;$7000);
                                     ;51 -> 52 (2026-09-08, alt
                                     ;screen: tty2.s private
                                     ;CSI + tty5.s VCA_*/
                                     ;PRC_ALT_RST -- kernel grew
                                     ;431 B past $6E00);
                                     ;50 -> 51 (2026-09-07,
                                     ;io_buffer
                                     ;LENDING in procfd2.s +
                                     ;the LRU/park tables in
                                     ;process.s: kernel grew
                                     ;228 B past $6C00);
                                     ;49 -> 50 (2026-09-04,
                                     ;UT_PUT_SPAN/TTY_UT_RUN/
                                     ;VCS_ST_SPAN: kernel grew
                                     ;105 B past $6A00);
                                     ;48 -> 49 (surfaces);
                                     ;47 -> 48 blocks, same day:
                                     ;VIDMODE V2.0 (tty8.s) grew
                                     ;the kernel 329 B past
                                     ;$6600. Before: 44 -> 47
                                     ;blocks 2026-09-02:
                                     ;procsig grew the kernel,
                                     ;then case 16 the harness
