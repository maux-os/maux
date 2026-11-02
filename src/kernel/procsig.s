*---------------------------------------------------------------
* procsig.s -- held-signal state and the two signal syscalls
* (docs/SIGNALS.md; SYS_KILL's carried-signo ABI staged this).
*
* State: SIG_TBL in the annex (mm.annex.equ), stride 8 by
* pid: +0/+1 CATCH mask, +2/+3 IGN mask, +4/+5 PEND mask --
* 16-bit LE, bit = signo-1. Reads ride PCB_RD_FIELDS (generic
* over K_PCB_PTR); writes use the PCB write bracket. Senders
* (PRC_KILL, the ^C sweep) consult the TARGET's masks; the one
* ERR_INTR delivery point is PRC_BLCK_RTRY's entry
* (procspawn.s). No handler addresses in v1 -- the upgrade
* trigger is named in docs/SIGNALS.md sec 1.
*---------------------------------------------------------------

*---------------------------------------------------------------
* PRC_SIGROW -- A = pid. K_PCB_PTR := &SIG_TBL[pid] (annex
* address; BANKSEL is the CALLER's job, as with PCB_PTR_FOR).
* CLOBBERS: A. Preserves X, Y.
*---------------------------------------------------------------
PRC_SIGROW  stz   K_PCB_PTR+1
            asl   a                    ;pid*8, 16-bit -- pid<=47
            rol   K_PCB_PTR+1          ;so *8 <= 376
            asl   a
            rol   K_PCB_PTR+1
            asl   a
            rol   K_PCB_PTR+1
            clc
            adc   #<SIG_TBL_ADDR
            sta   K_PCB_PTR
            lda   K_PCB_PTR+1
            adc   #>SIG_TBL_ADDR
            sta   K_PCB_PTR+1
            rts

*---------------------------------------------------------------
* PRC_SIGBIT -- A = signo (1-15). K_SIGB_LO/HI := the 16-bit
* mask with bit signo-1 set (table-driven; entry 0 is 0 so a
* stray signo 0 yields an empty mask, never a wrong bit).
* CLOBBERS: A, Y. Preserves X.
*---------------------------------------------------------------
PRC_SIGBIT  tay
            lda   PSGBT_LO,y
            sta   K_SIGB_LO
            lda   PSGBT_HI,y
            sta   K_SIGB_HI
            rts

PSGBT_LO    dfb   $00,$01,$02,$04,$08,$10,$20,$40
            dfb   $80,$00,$00,$00,$00,$00,$00,$00
PSGBT_HI    dfb   $00,$00,$00,$00,$00,$00,$00,$00
            dfb   $00,$01,$02,$04,$08,$10,$20,$40

*---------------------------------------------------------------
* PRC_SIG_RD -- A = pid: copy that pid's 6 live SIG bytes into
* K_PCB_SCRATCH (+0/1 catch, +2/3 ign, +4/5 pend) and leave
* K_PCB_PTR on the row for a follow-up write. Sets BANKSEL 0 --
* the caller restores the current bank if it is on a path that
* returns to a process (every syscall return does; the tick
* sweep's :done does).
*---------------------------------------------------------------
PRC_SIG_RD  jsr   PRC_SIGROW
            lda   #0
            sta   BANKSEL
            lda   #0
            ldx   #6
            jmp   PCB_RD_FIELDS

*---------------------------------------------------------------
* PRC_SIGWRB -- A = value, Y = row offset: one byte into the
* SIG row at K_PCB_PTR, PCB write-bracket discipline (BANKSEL
* is already 0 on every path here -- PRC_SIG_RD set it).
*---------------------------------------------------------------
PRC_SIGWRB  pha
            sta   RAMWRTAUX
            pla
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN
            rts

*---------------------------------------------------------------
* PRC_SIG_SND -- A = target pid, X = signo: set the pending bit
* and, if the target is BLOCKED, make it runnable so its retried
* syscall reaches the ERR_INTR check. Caller has already
* determined the disposition is CATCH. Safe from tick context
* (annex writes + RUNQ_PUSH, both already done there by the ^C
* sweep's own machinery).
*---------------------------------------------------------------
PRC_SIG_SND sta   PSG_PID
            txa
            jsr   PRC_SIGBIT
            lda   PSG_PID
            jsr   PRC_SIG_RD
            lda   K_PCB_SCRATCH+4
            ora   K_SIGB_LO
            ldy   #4
            jsr   PRC_SIGWRB
            lda   K_PCB_SCRATCH+5
            ora   K_SIGB_HI
            ldy   #5
            jsr   PRC_SIGWRB
            lda   PSG_PID
            jsr   PCB_PTR_FOR
            lda   #PCB_STATE
            ldx   #2
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH
            cmp   #PCB_BLOCKED
            bne   :nowake
            sta   RAMWRTAUX
            lda   #PCB_RUNNABLE
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
            lda   #0
            ldy   #PCB_WCHAN
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN
            ldx   PSG_PID                ;wait shadow (main):
            sta   K_WAIT_SHD,x           ;after the bracket
            txa
            jsr   RUNQ_PUSH
:nowake     rts

*---------------------------------------------------------------
* PRC_SIG_TST -- carry SET iff the CURRENT process holds a
* pending CAUGHT signal. The whole ERR_INTR decision
* (docs/SIGNALS.md "the one delivery point"); called by
* PRC_BLCK_RTRY before it sleeps. A pending bit whose
* disposition has since left CATCH does not fire -- IGN never
* pends and DFL kills at the sender, so the mask pair is the
* truth.
*---------------------------------------------------------------
PRC_SIG_TST lda   K_CURPID
            jsr   PRC_SIG_RD
            lda   K_PCB_SCRATCH+0
            and   K_PCB_SCRATCH+4
            bne   :yes
            lda   K_PCB_SCRATCH+1
            and   K_PCB_SCRATCH+5
            bne   :yes
            clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* PRC_SIG_ZRO -- A = pid: zero the whole SIG row. SCH_CREATE's
* hook, so a reused pid can never inherit a dead process's
* traps (the same reason SCH_CREATE zeroes PCB_BRK).
*---------------------------------------------------------------
PRC_SIG_ZRO jsr   PRC_SIGROW
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            ldy   #SIG_ENT_SIZE-1
            lda   #0
:loop       sta   (K_PCB_PTR),y
            dey
            bpl   :loop
            sta   RAMWRTMAIN
            rts

*---------------------------------------------------------------
* PRC_SIG_INH -- A = parent pid, X = child pid: V7 inheritance.
* Y=0 on entry selects spawn's rule (exec semantics: IGN copied,
* CATCH reset to DFL); Y=1 selects fork's (CATCH+IGN both).
* Pending starts empty in every child either way (SCH_CREATE
* zeroed the row; this only ORs the inherited masks in).
*---------------------------------------------------------------
PRC_SIG_INH sta   PSG_PID              ;parent, briefly
            stx   PSG_TGT
            sty   PSG_MODE
            lda   PSG_PID
            jsr   PRC_SIG_RD           ;parent row -> scratch
            lda   PSG_TGT
            jsr   PRC_SIGROW           ;K_PCB_PTR = child row
            lda   K_PCB_SCRATCH+2      ;IGN, both modes
            ldy   #2
            jsr   PRC_SIGWRB
            lda   K_PCB_SCRATCH+3
            ldy   #3
            jsr   PRC_SIGWRB
            lda   PSG_MODE
            beq   :out                 ;spawn: CATCH stays DFL
            lda   K_PCB_SCRATCH+0      ;fork: CATCH copies too
            ldy   #0
            jsr   PRC_SIGWRB
            lda   K_PCB_SCRATCH+1
            ldy   #1
            jsr   PRC_SIGWRB
:out        rts

PSG_PID     ds    1
PSG_TGT     ds    1
PSG_MODE    ds    1
PSG_OLD     ds    1
PSG_NLO     ds    1
PSG_NHI     ds    1
K_SIGB_LO   ds    1
K_SIGB_HI   ds    1
