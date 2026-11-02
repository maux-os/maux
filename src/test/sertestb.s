*---------------------------------------------------------------
* sertestb.s -- image body for sertest.s (`make check-ser`).
*
* Same shape as argvtest.s/shtest.s: PID 1 runs directly, no
* spawn. Proves FD_SER0 end to end against verilogapple's
* simulated SSC (ssc_tx_read/ssc_rx_write, scripts/check_ser.py)
* with a REAL tick source (TIMER_PROBE -> the mouse-card VBL
* path, same as playtestb.s) -- unlike argvtest/shtest's NOIRQ
* shortcut, this gate's whole point is the tick-driven
* SER_POLL, so it cannot take that shortcut. PARENT_PROC also
* runs its own `cli`: real ticks land only "across MLI calls"
* (timer.s's MAIN_IRQ_SHIM header) and a /DEV path never calls
* MLI, so TIMER_PROBE's mouse-card wiring alone is not enough.
*
* TX: three separate one-byte writes (TXBYTES), drained by the
* host on every poll step (no FIFO, so no inter-write delay is
* safe -- see scripts/check_ser.py's header). RX: three separate
* one-byte reads, each preceded by a real SER_SPIN delay (NOT a
* blocking read) so the tick-driven SER_POLL has a genuine VBL
* period to land the byte before maux reads it -- this v1
* scheduler has no idle process (sched.s's own :deadlock
* comment), so a read that found the ring empty and genuinely
* blocked (PRC_BLCK_RTRY/SCH_SLEEP) would never be woken with
* only one process in the system. The host still withholds
* byte i until R_RCOUNT proves byte i-1 was consumed (the 6551
* model is single-byte-deep in both directions, no FIFO either
* way, so overlapping transfers would silently overwrite rather
* than queue).
*---------------------------------------------------------------

* Result addresses, parent process bank (aux bank 1), page $12.
R_OPENFD    equ $1200
R_STEP      equ $1201
R_TXCOUNT   equ $1202        ;bytes written so far (0..3)
R_RCOUNT    equ $1203        ;bytes read back so far (0..3)
R_RDATA     equ $1204        ;3 bytes read back
R_DONE      equ $1290
R_ERR       equ $1291
R_SYSERR    equ $1292        ;diagnostic: the kernel's real
                              ;errno (A) on any $FF00 failure

DEV_PATH    equ $1300        ;/DEV/TTYA0, MLI pathname
OPEN_PARM   equ $1310
RW_PARM     equ $1320
CLOSE_PARM  equ $1330
IO_BYTE     equ $1340        ;one-byte TX/RX staging cell

MAIN_ENTRY  sei
            cld
            ldx   #$FF
            txs

            jsr   INSTALL_COPY
            jsr   SCH_INIT
            jsr   TIMER_PROBE     ;wires K_IRQ_HOOK -> TIMER_ISR
                                  ;off the mouse card's VBL IRQ
                                  ;(reset's mouse default is on)
                                  ;-> K_TICK_HOOK -> TTY_TICK,
                                  ;the ONLY path SER_POLL runs
            lda   #1              ;gates pin 40 cols
            sta   TTY_BKND_REQ
            jsr   PRC_INIT

            lda   #1
            jsr   PRC_STMP_BANK
            lda   #1
            jsr   PRC_SYNTH_FRM
            jsr   PATCH_PAR_FRM
            jsr   BOOT_CPY_PAR

            lda   #1
            ldx   #1
            jsr   SCH_CREATE
            jsr   SCH_START

BOOT_CPY_PAR
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PARENT_PROC
            sta   K_BC_SRCADDR
            lda   #>PARENT_PROC
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #<PARENT_PROC
            sta   K_BC_DSTADDR
            lda   #>PARENT_PROC
            sta   K_BC_DSTADDR+1
            lda   #1
            sta   K_BC_DSTBANK
            lda   #<PAR_PROC_LEN
            sta   K_BC_LEN
            lda   #>PAR_PROC_LEN
            sta   K_BC_LEN+1
            jsr   BankCopy
            rts

PATCH_PAR_FRM
            lda   #1
            sta   BANKSEL
            sta   ALTZPAUX
            lda   #<PARENT_PROC
            sta   $01FE
            lda   #>PARENT_PROC
            sta   $01FF
            sta   ALTZPMAIN
            rts

*---------------------------------------------------------------
* PARENT_PROC -- runs in bank 1 (PID 1), copied verbatim there
* by BOOT_CPY_PAR -- same reason every other harness's copy is:
* absolute JSR/JMP operands to the helpers below are valid only
* once the whole span is resident at this same address in bank
* 1 (it was ASSEMBLED here).
*---------------------------------------------------------------
PARENT_PROC
            cli                 ;real ticks land ONLY "across
                                ;MLI calls" (timer.s's own
                                ;MAIN_IRQ_SHIM header) -- a /DEV
                                ;path never calls MLI, so this
                                ;raw one-process gate enables
                                ;interrupts itself, the one
                                ;thing TIMER_PROBE does not do
            stz   R_ERR
            stz   R_DONE
            stz   R_STEP
            stz   R_TXCOUNT
            stz   R_RCOUNT
            stz   R_SYSERR

            lda   #10
            sta   DEV_PATH
            ldx   #0
:pcp        lda   DEVPTH_TXT,x
            sta   DEV_PATH+1,x
            inx
            cpx   #10
            bne   :pcp

            lda   #3
            sta   OPEN_PARM
            lda   #<DEV_PATH
            sta   OPEN_PARM+1
            lda   #>DEV_PATH
            sta   OPEN_PARM+2
            stz   OPEN_PARM+3
            stz   OPEN_PARM+4
            stz   OPEN_PARM+5
            lda   #<OPEN_PARM
            ldx   #>OPEN_PARM
            ldy   #SYS_OPEN
            jsr   $FF00
            bcc   :opened
            sta   R_SYSERR
            lda   #1                    ;SSC undetected (or
            sta   R_ERR                 ;other open failure) --
            jmp   :alldone              ;the teeth-demo red path
:opened     lda   OPEN_PARM+5
            sta   R_OPENFD

*-- TX: TXBYTES one at a time. The host drains ssc_tx_read
*-- every poll step, so no inter-write delay is needed -- see
*-- scripts/check_ser.py's header.
            ldx   #0
:txloop     cpx   #3
            beq   :txdone
            lda   TXBYTES,x
            sta   IO_BYTE
            lda   #4
            sta   RW_PARM
            lda   R_OPENFD
            sta   RW_PARM+1
            lda   #<IO_BYTE
            sta   RW_PARM+2
            lda   #>IO_BYTE
            sta   RW_PARM+3
            lda   #1
            sta   RW_PARM+4
            stz   RW_PARM+5
            stz   RW_PARM+6
            stz   RW_PARM+7
            lda   #<RW_PARM
            ldx   #>RW_PARM
            ldy   #SYS_WRITE
            jsr   $FF00
            bcc   :txok
            sta   R_SYSERR
            lda   #2
            sta   R_ERR
            jmp   :alldone
:txok       inc   R_TXCOUNT
            ldx   R_TXCOUNT
            bra   :txloop
:txdone

*-- RX: three one-byte reads, each preceded by SER_SPIN so the
*-- host's ssc_rx_write + the tick-driven SER_POLL have a real
*-- VBL period to land the byte in the ring BEFORE the read --
*-- this v1 scheduler has no idle process (sched.s's own
*-- :deadlock comment), so a read that actually found the ring
*-- empty and blocked (PRC_BLCK_RTRY/SCH_SLEEP) would never be
*-- woken: nothing else is runnable to give the CPU to while
*-- waiting. The host still withholds byte i until R_RCOUNT
*-- proves byte i-1 was consumed (single-byte-deep card model,
*-- no FIFO either direction) -- SER_SPIN is what makes that
*-- handoff race-free instead of a hopeful guess at cadence.
            ldx   #0
:rxloop     cpx   #3
            beq   :rxdone
            jsr   SER_SPIN
            lda   #4
            sta   RW_PARM
            lda   R_OPENFD
            sta   RW_PARM+1
            lda   #<IO_BYTE
            sta   RW_PARM+2
            lda   #>IO_BYTE
            sta   RW_PARM+3
            lda   #1
            sta   RW_PARM+4
            stz   RW_PARM+5
            stz   RW_PARM+6
            stz   RW_PARM+7
            lda   #<RW_PARM
            ldx   #>RW_PARM
            ldy   #SYS_READ
            jsr   $FF00
            bcc   :rxok
            sta   R_SYSERR
            lda   #3
            sta   R_ERR
            jmp   :alldone
:rxok       lda   IO_BYTE
            ldx   R_RCOUNT
            sta   R_RDATA,x
            inc   R_RCOUNT
            ldx   R_RCOUNT
            bra   :rxloop
:rxdone

            lda   R_OPENFD
            sta   CLOSE_PARM+1
            lda   #1
            sta   CLOSE_PARM
            lda   #<CLOSE_PARM
            ldx   #>CLOSE_PARM
            ldy   #SYS_CLOSE
            jsr   $FF00

:alldone    lda   #$AA
            sta   R_DONE
:halt       bra   :halt

*-- ~330,000 cycles (X outer x Y inner, 256x256, ~5 cyc/inner
*-- iteration): comfortably more than one ~17,066-cycle VBL
*-- period, so interrupts (enabled once by PARENT_PROC's own
*-- `cli` -- real ticks otherwise land only "across MLI calls",
*-- timer.s's MAIN_IRQ_SHIM header, and a /DEV path never calls
*-- MLI) get several real chances to drain the ACIA here.
SER_SPIN    ldx   #0
:oloop      ldy   #0
:iloop      dey
            bne   :iloop
            dex
            bne   :oloop
            rts

DEVPTH_TXT  asc   "/DEV/TTYA0"
TXBYTES     dfb   $41,$42,$43     ;'A','B','C' -- plain bytes,
                                  ;no high bit (RAW mode, not
                                  ;Apple screen-text convention)

PAR_PROC_LEN equ *-PARENT_PROC

            ds    $8000-*   ;+3 blk 2026-09-25: found already
                                     ;920B over $7600 before
                                     ;this session touched
                                     ;anything; this session's
                                     ;own kernel growth
                                     ;(procbye.s's PCB_SAVEDSP
                                     ;publish) added ~66B more,
                                     ;to 1052 over; +2 blk
                                     ;2026-09-21: SYS_HALT plus
                                     ;accumulated kernel growth,
                                     ;920B over $7600 -- this
                                     ;image links
                                     ;timer.s, so it also
                                     ;carries TMR_QUIESCE;
                                     ;+1 blk: XON/XOFF
                                     ;(2026-09-12);
