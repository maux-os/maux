*---------------------------------------------------------------
* procsig2.s -- the two SIGNAL SYSCALL handlers, split from
* procsig.s 2026-09-02. These need process.s's syscall plumbing
* (PCPI_CALLPARM / PRC_RET_OK* / PRC_FAIL_A), so a scheduler
* unit test (schedtest_*) that puts procsig.s for SCH_CREATE's
* PRC_SIG_ZRO hook must NOT drag them in. Full kernels put both;
* the primitives in procsig.s use only PCB_*/RUNQ_* and stand
* alone. One assembly stream, put immediately after procsig.s.
*---------------------------------------------------------------

*---------------------------------------------------------------
* PRC_SIGNAL -- SYS_SIGNAL(signo, action), syscall context.
* Returns the previous action (docs/SIGNALS.md sec 2). Setting
* any action other than CATCH also clears the signal's pending
* bit -- an ignored-away signal must not fire a stale trap the
* moment CATCH comes back.
*---------------------------------------------------------------
PRC_SIGNAL  lda   #2
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+0
            beq   :badsig              ;signo 0
            cmp   #9
            beq   :badsig              ;SIGKILL: never
            cmp   #16
            bcs   :badsig
            lda   PRC_PARM+1
            cmp   #SIGA_CATCH+1
            bcc   :argsok              ;incl. handler addresses:
                                       ;refused, not stored --
                                       ;see the header
:badsig     jmp   :inval               ;body outgrew the beq's
:argsok
            lda   PRC_PARM+0
            jsr   PRC_SIGBIT
            lda   K_CURPID
            jsr   PRC_SIG_RD
            ;-- previous action, from which mask holds the bit
            lda   #SIGA_CATCH
            sta   PSG_OLD
            lda   K_PCB_SCRATCH+0
            and   K_SIGB_LO
            bne   :haveold
            lda   K_PCB_SCRATCH+1
            and   K_SIGB_HI
            bne   :haveold
            lda   #SIGA_IGN
            sta   PSG_OLD
            lda   K_PCB_SCRATCH+2
            and   K_SIGB_LO
            bne   :haveold
            lda   K_PCB_SCRATCH+3
            and   K_SIGB_HI
            bne   :haveold
            lda   #SIGA_DFL
            sta   PSG_OLD
:haveold    ;-- the complement masks, for clearing
            lda   K_SIGB_LO
            eor   #$FF
            sta   PSG_NLO
            lda   K_SIGB_HI
            eor   #$FF
            sta   PSG_NHI
            ;-- CATCH bytes: clear, then set iff action=CATCH
            lda   K_PCB_SCRATCH+0
            and   PSG_NLO
            ldx   PRC_PARM+1
            cpx   #SIGA_CATCH
            bne   :nc0
            ora   K_SIGB_LO
:nc0        ldy   #0
            jsr   PRC_SIGWRB
            lda   K_PCB_SCRATCH+1
            and   PSG_NHI
            cpx   #SIGA_CATCH
            bne   :nc1
            ora   K_SIGB_HI
:nc1        ldy   #1
            jsr   PRC_SIGWRB
            ;-- IGN bytes: clear, then set iff action=IGN
            lda   K_PCB_SCRATCH+2
            and   PSG_NLO
            cpx   #SIGA_IGN
            bne   :ni0
            ora   K_SIGB_LO
:ni0        ldy   #2
            jsr   PRC_SIGWRB
            lda   K_PCB_SCRATCH+3
            and   PSG_NHI
            cpx   #SIGA_IGN
            bne   :ni1
            ora   K_SIGB_HI
:ni1        ldy   #3
            jsr   PRC_SIGWRB
            ;-- PEND bytes: leaving CATCH discards what was held
            cpx   #SIGA_CATCH
            beq   :pendok
            lda   K_PCB_SCRATCH+4
            and   PSG_NLO
            ldy   #4
            jsr   PRC_SIGWRB
            lda   K_PCB_SCRATCH+5
            and   PSG_NHI
            ldy   #5
            jsr   PRC_SIGWRB
:pendok     lda   PSG_OLD
            jmp   PRC_RET_OK_A
:inval      lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts

*---------------------------------------------------------------
* PRC_SIGPEND -- SYS_SIGPEND(), syscall context. Pop the lowest
* pending signo (fetch-and-clear one bit); 0 = none. No
* parameter block -- the register-carried parms pointer is
* ignored, SYS_FORK's own precedent.
*---------------------------------------------------------------
PRC_SIGPEND lda   K_CURPID
            jsr   PRC_SIG_RD
            ldx   #1
:scan       cpx   #16
            beq   :none
            txa
            jsr   PRC_SIGBIT
            lda   K_SIGB_LO
            and   K_PCB_SCRATCH+4
            bne   :hit
            lda   K_SIGB_HI
            and   K_PCB_SCRATCH+5
            bne   :hit
            inx
            bra   :scan
:none       jmp   PRC_RET_OK0
:hit        lda   K_SIGB_LO
            eor   #$FF
            and   K_PCB_SCRATCH+4
            ldy   #4
            jsr   PRC_SIGWRB
            lda   K_SIGB_HI
            eor   #$FF
            and   K_PCB_SCRATCH+5
            ldy   #5
            jsr   PRC_SIGWRB
            txa
            jmp   PRC_RET_OK_A


*---------------------------------------------------------------
* PRC_SIG_DSP -- A = target pid (parm signo already in
* PRC_PARM+1): the SENDER's disposition question, for PRC_KILL.
* OUT: A = SIGA_DFL/SIGA_IGN/SIGA_CATCH for that target+signo.
* Clobbers K_PCB_PTR (the caller re-derives its PCB pointer).
*---------------------------------------------------------------
PRC_SIG_DSP sta   PSG_TGT
            lda   PRC_PARM+1
            jsr   PRC_SIGBIT
            lda   PSG_TGT
            jsr   PRC_SIG_RD
            lda   K_PCB_SCRATCH+2
            and   K_SIGB_LO
            bne   :ign
            lda   K_PCB_SCRATCH+3
            and   K_SIGB_HI
            bne   :ign
            lda   K_PCB_SCRATCH+0
            and   K_SIGB_LO
            bne   :catch
            lda   K_PCB_SCRATCH+1
            and   K_SIGB_HI
            bne   :catch
            lda   #SIGA_DFL
            rts
:ign        lda   #SIGA_IGN
            rts
:catch      lda   #SIGA_CATCH
            rts

