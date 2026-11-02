*---------------------------------------------------------------
* ser.s -- /dev/ttya0: the Super Serial Card's 6551 ACIA.
*
* V1 SCOPE: RAW mode only, no echo, no line discipline, no
* ioctl (SYS_TTYMODE/SYS_TTYGEO stay console-range-only by
* design). Detected once at boot (SER_DETECT, called from
* PRC_INIT); polled once per tick from inside TTY_TICK's own
* save/restore bracket (SER_POLL, tty.s); TX/RX are the new
* FD_SER0 arms in procmli.s/procmli3.s (SER_READ/SER_WRITE).
*
* 6551 register equates are LOCAL to this file on purpose --
* the real-Merlin source-buffer budget (procfile5.s's own
* header) is charged against every `put`, and no other module
* needs them. Offsets off a page-$C0 base computed at boot:
* SER_ACIA_PG,x is DATA, +1 STATUS, +2 COMMAND, +3 CONTROL,
* with X = SER_BASELO (always <= $F8, so +3 never crosses the
* page -- see SER_DETECT's derivation below).
*---------------------------------------------------------------
SER_ACIA_PG equ   $C000
SER_RDRF    equ   $08    ;STATUS bit 3: receiver data full
SER_TDRE    equ   $10    ;STATUS bit 4: transmitter empty
SER_XON     equ   $11    ;DC1 -- resume (flow control)
SER_XOFF    equ   $13    ;DC3 -- pause
SER_HIWATER equ   192    ;ring bytes: stop reading, XOFF
SER_LOWATER equ   64     ;ring bytes: XON again

*---------------------------------------------------------------
* SER_DETECT -- boot-time slot scan (learning:
* 01M27KGKPYZD5HY0TA3FSRDT63): the Pascal-1.1 signature lives
* ONLY in the slot ROM's page 7 ($Cs05/07/0B/0C = $38/18/01/
* 31), so this never touches $C800 and never joins that
* window's last-claimant arbitration. First matching slot wins;
* no card answering leaves SER_PRESENT clear and /dev/ttya0
* unopenable (PRC_DEVOPEN, procfile5.s).
*
* K_PCB_PTR is reused as a scratch indirect pointer -- safe
* here only because PRC_INIT runs before any process or the
* scheduler exists, the same precondition PRC_RAMDIS's own
* global-page reuse leans on.
*---------------------------------------------------------------
SER_DETECT
            stz   SER_PRESENT
            lda   #1
            sta   SER_SLOT
:slp        stz   K_PCB_PTR
            lda   #$C0
            clc
            adc   SER_SLOT
            sta   K_PCB_PTR+1      ;ptr = $C000 + slot*$100
            ldy   #5
            lda   (K_PCB_PTR),y
            cmp   #$38
            bne   :next
            ldy   #7
            lda   (K_PCB_PTR),y
            cmp   #$18
            bne   :next
            ldy   #$0B
            lda   (K_PCB_PTR),y
            cmp   #$01
            bne   :next
            ldy   #$0C
            lda   (K_PCB_PTR),y
            cmp   #$31
            bne   :next
            lda   SER_SLOT         ;found -- base lo = $88 +
            asl   a                ;slot*16 (slot 1..7 -> lo
            asl   a                ;<= $F8, stays on page $C0
            asl   a                ;through CONTROL at +3)
            asl   a
            clc
            adc   #$88
            sta   SER_BASELO
            lda   #1
            sta   SER_PRESENT
            stz   SER_FLOW
            rts
:next       inc   SER_SLOT
            lda   SER_SLOT
            cmp   #8
            bne   :slp
            rts

*---------------------------------------------------------------
* SER_POLL -- per-tick drain: a LOOP while RDRF (2026-09-11,
* for tip -- one byte per 60 Hz tick is a 600-baud ceiling; a
* real card at 9600 baud hands over 16 a tick). Called from
* TTY_TICK inside its existing save/restore bracket (tty.s);
* the IRQ path saves Y (timer.s). Uses A/X/Y and
* SCH_WAKEUP, same as TTY_POLL's own wake of TTY_RD_CHAN -- no
* new P_* zero-page cell needs protecting across the interrupt.
*
* FLOW CONTROL (2026-09-12, found by host vim over tip: a 1.2 KB
* burst outran the console and the old ring-full-drop rule lost
* bytes): at SER_HIWATER the poll STOPS reading -- the byte
* stays in the card's receive register -- and sends XOFF once;
* SER_READ
* sends XON when the ring drains to SER_LOWATER. The host pty's
* IXON honours them, as any 1981 host did for a VT102. On a real
* 6551 an unread byte plus one more is a receiver overrun; the
* XOFF is what prevents that, and it goes out before the ring's
* last 63 bytes are spoken for.
*---------------------------------------------------------------
SER_POLL
            lda   SER_PRESENT
            beq   :done
            ldy   #0               ;Y = bytes taken this tick
:more       lda   SER_BYTES
            cmp   #SER_HIWATER
            bcs   :xoff            ;ring near full: STOP
                                  ;reading (the byte stays
                                  ;in the card), say XOFF
            ldx   SER_BASELO
            lda   SER_ACIA_PG+1,x   ;STATUS
            and   #SER_RDRF
            beq   :took
            lda   SER_ACIA_PG,x     ;DATA -- clears RDRF
            ldx   SER_WRP
            sta   SER_RING,x
            inc   SER_WRP
            inc   SER_BYTES
            iny
            bne   :more            ;drain while RDRF: one byte
                                  ;per 60 Hz tick would be a
                                  ;600-baud ceiling (<=255/tick)
:xoff       lda   SER_FLOW
            bne   :took            ;XOFF already out
            lda   #SER_XOFF
            jsr   SER_TXBYTE       ;tell the host to pause --
            lda   #1               ;a VT102's own xon/xoff
            sta   SER_FLOW         ;handshake (terminfo `xon`)
:took       cpy   #0
            beq   :done            ;nothing new: no wake
            lda   #SER_RD_CHAN
            jsr   SCH_WAKEUP       ;ONE wake per tick, not per
                                  ;byte (a PCB scan each)
            jsr   PRC_SEL_CRBNK    ;SCH_WAKEUP's own PCB scan
                                  ;leaves BANKSEL=0 (annex) --
                                  ;restore it, same as
                                  ;TTY_WAKE_RDRS's call site
                                  ;(tty3.s), or the tick-hook's
                                  ;return to the interrupted
                                  ;process wild-jumps
                                  ;(learning:01M28001EKW3KDXM
                                  ;109P97AJHH)
:done       rts

* SER_TXBYTE -- A -> the line (TDRE poll + DATA). Shared by
* SER_WRITE and the flow-control bytes.
SER_TXBYTE  pha
            jsr   SER_TXWAIT
            ldx   SER_BASELO
            pla
            sta   SER_ACIA_PG,x
            rts

*---------------------------------------------------------------
* SER_TXWAIT -- busy-poll STATUS until TDRE. No timeout: V1
* scope is a polled-only SSC, same posture the 1981 manual
* documents for the II/II+ with SW2-6 (IRQ forwarding) off
* (learning:01M27HT1E4QBBFKGARYWBMMGRE).
*---------------------------------------------------------------
SER_TXWAIT
            ldx   SER_BASELO
:wait       lda   SER_ACIA_PG+1,x
            and   #SER_TDRE
            beq   :wait
            rts

*---------------------------------------------------------------
* SER_WRITE -- PRC_WRITE's FD_SER0 arm (procmli3.s :isser).
* Entry: PRC_PARM already holds the 8-byte parmlist (PRC_WRITE
* ran PCPI_CALLPARM/PRC_CUR_FDOBJ before dispatching here).
* One byte at a time: COPYIN_ENTRY pulls it from the caller's
* bank (PRC_CUR_FDOBJ left BANKSEL at 0 -- PRC_SEL_CRBNK below
* restores it, the same bracket PCPO_MLIPARM uses), SER_TXWAIT
* polls TDRE, then the byte goes straight to DATA.
*---------------------------------------------------------------
SER_WRITE
            jsr   PPP_REQ_LIMIT    ;P_COUNT = min(request,255)
            jsr   PRC_SEL_CRBNK
            lda   PRC_PARM+MLI_BUFLO
            sta   SER_PTR
            lda   PRC_PARM+MLI_BUFHI
            sta   SER_PTR+1
            stz   P_IDX
:wloop      lda   P_IDX
            cmp   P_COUNT
            beq   :wdone
            lda   SER_PTR
            sta   K_CPY_PROC
            lda   SER_PTR+1
            sta   K_CPY_PROC+1
            lda   #<SER_BYTE
            sta   K_CPY_MAIN
            lda   #>SER_BYTE
            sta   K_CPY_MAIN+1
            lda   #1
            sta   K_CPY_LEN
            jsr   COPYIN_ENTRY
            lda   K_CPY_ERR
            beq   :wok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:wok        lda   SER_BYTE
            jsr   SER_TXBYTE
            inc   SER_PTR
            bne   :wnohi
            inc   SER_PTR+1
:wnohi      inc   P_IDX
            bra   :wloop
:wdone      lda   P_IDX
            sta   PRC_PARM+MLI_TRANSLO
            stz   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts

*---------------------------------------------------------------
* SER_READ -- PRC_READ's FD_SER0 arm (procmli.s :isser). A
* zero-length request never blocks (mirrors PRC_READ's own
* pipe branch); otherwise blocks on SER_RD_CHAN until the ring
* holds at least one byte, then returns min(avail, requested)
* WITHOUT blocking further -- same short-read contract pipes
* already give callers. COPYOUT_ENTRY pushes each ring byte
* straight into the caller's bank.
*---------------------------------------------------------------
SER_READ
            lda   PRC_PARM+MLI_REQLO
            ora   PRC_PARM+MLI_REQHI
            bne   :want
            stz   PRC_PARM+MLI_TRANSLO
            stz   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts
:want       lda   SER_BYTES
            bne   :havedata
            lda   #SER_RD_CHAN
            jsr   PRC_BLCK_RTRY
            rts
:havedata   jsr   PPP_REQ_LIMIT     ;P_COUNT = min(request,255)
            lda   SER_BYTES
            cmp   P_COUNT
            bcs   :ravail           ;avail>=requested: as asked
            sta   P_COUNT           ;avail<requested: use avail
:ravail     jsr   PRC_SEL_CRBNK
            lda   PRC_PARM+MLI_BUFLO
            sta   SER_PTR
            lda   PRC_PARM+MLI_BUFHI
            sta   SER_PTR+1
            stz   P_IDX
:rloop      lda   P_IDX
            cmp   P_COUNT
            beq   :rdone
            ldx   SER_RDP
            lda   SER_RING,x
            sta   SER_BYTE
            inc   SER_RDP
            dec   SER_BYTES
            lda   SER_PTR
            sta   K_CPY_PROC
            lda   SER_PTR+1
            sta   K_CPY_PROC+1
            lda   #<SER_BYTE
            sta   K_CPY_MAIN
            lda   #>SER_BYTE
            sta   K_CPY_MAIN+1
            lda   #1
            sta   K_CPY_LEN
            jsr   COPYOUT_ENTRY
            lda   K_CPY_ERR
            beq   :rok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:rok        inc   SER_PTR
            bne   :rnohi
            inc   SER_PTR+1
:rnohi      inc   P_IDX
            bra   :rloop
:rdone      lda   SER_FLOW
            beq   :noxon
            lda   SER_BYTES
            cmp   #SER_LOWATER
            bcs   :noxon           ;still above low water
            lda   #SER_XON
            jsr   SER_TXBYTE       ;room again: resume the host
            stz   SER_FLOW
:noxon      lda   P_IDX
            sta   PRC_PARM+MLI_TRANSLO
            stz   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts

*-- State. SER_RING is plain low main memory, indexed with
*-- 8-bit wraparound (INC SER_WRP/SER_RDP wraps at 256 for
*-- free) -- no page-alignment trick needed, unlike the pipe
*-- rings' BankCopy-addressed pages (procmli.s/procmli3.s).
SER_PRESENT ds    1
SER_BASELO  ds    1
SER_SLOT    ds    1     ;SER_DETECT scratch only
SER_RDP     ds    1
SER_WRP     ds    1
SER_BYTES   ds    1
SER_PTR     ds    2
SER_BYTE    ds    1
SER_FLOW    ds    1     ;1 = XOFF sent, XON owed
*-- SER_RING (256 B): inc/mm.kbss.equ, low main.
