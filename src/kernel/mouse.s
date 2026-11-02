*---------------------------------------------------------------
* mouse.s -- AppleMouse II direct-PIA command primitive.
* Full design notes: K.MOUSE.TXT (docs/a2/)
*
* PROTOCOL CORRECTED 2026-08-18 against the real card (MAME
* runs the actual 68705 MCU ROM; the A2USB project's reverse
* engineering documents the same contract): a command byte is
* not latched by a blind clock pulse -- it is a four-phase
* handshake over PIA port B:
*
*   PB5 (out) = WRREQUEST   PB7 (in) = WRACK
*
*   1. data on PRA; raise WRREQUEST
*   2. wait for WRACK=1 (the MCU has read PRA)
*   3. drop WRREQUEST
*   4. wait for WRACK=0
*
* The old code pulsed PB5 high-then-low in ~12 cycles with no
* waits. That worked only because verilogapple's behavioral
* model latches synchronously on the falling edge; the real
* MCU polls its port at its own pace and missed the pulse
* entirely -- armed VBL mode never engaged, zero ticks, and the
* scheduler starved (found on MAME, TIMER:MOUSE-VBL with
* K_VBL_TICKS stuck at 0). verilogapple also models the
* handshake bits (rising request sets PB7 "ready" at once,
* falling edge latches and clears it), so the waits below pass
* instantly there and genuinely wait on MAME/iron. The two
* models latch PRA at different phases -- request-high vs
* falling edge -- which is harmless because the data byte sits
* on PRA across the whole exchange.
*
* No timeout: the real ROM firmware has none either (it wedges
* if the MCU dies), and adding one would turn a broken mouse
* into a silent no-tick system instead of a visible hang.
*---------------------------------------------------------------

MOUSE_SND_CMD
            sta   MOUSE_PRA
            lda   MOUSE_PRB
            ora   #$20                          ;WRREQUEST high
            sta   MOUSE_PRB
:ackhi      lda   MOUSE_PRB
            bpl   :ackhi                        ;until WRACK
                                                ;(bit7) = 1
            and   #$DF                          ;WRREQUEST low
            sta   MOUSE_PRB
:acklo      lda   MOUSE_PRB
            bmi   :acklo                        ;until WRACK = 0
            rts

*---------------------------------------------------------------
* MOUSE_RD_BYTE -- the read half of the protocol: accept one
* reply byte from the controller. Returns it in A.
*
*   PB6 (in) = RDREADY   PB4 (out) = RDACK
*
*   1. wait RDREADY=1 (controller has put the byte on port A)
*   2. read PRA
*   3. raise RDACK; wait RDREADY=0
*   4. drop RDACK
*
* The PIA's port A must be INPUTS for the read -- the 68705
* drives the byte from its side (SERVEMOUSE's handler does
* LDA #$FF / STA DDRA before presenting, MCU ROM $4DE) -- so
* DDRA is flipped to $00 around the exchange and back to $FF
* after, keeping MOUSE_SND_CMD's write path unchanged. On
* verilogapple RDREADY idles HIGH (pb_q resets to $40 and each
* PB4 falling edge re-presents), so every wait below passes
* immediately; on the real MCU they genuinely wait.
*
* WHY THIS EXISTS (2026-08-18): SERVEMOUSE is not fire-and-
* forget. The real firmware deasserts IRQ and then BLOCKS at
* MCU ROM $4EB presenting its interrupt-status byte until the
* host completes this handshake -- an ISR that only sends
* M_SERV wedges the controller's main loop after the first
* tick and no further command is ever processed. verilogapple's
* model (M_SERV data_len=2) never blocks, which is how the
* read-free ISR ran green for weeks.
*---------------------------------------------------------------
MOUSE_RD_BYTE
            stz   MOUSE_CRA                     ;select DDRA
            stz   MOUSE_PRA                     ;port A = inputs
            lda   #$04
            sta   MOUSE_CRA                     ;back to PRA
:rdy        lda   MOUSE_PRB
            and   #$40
            beq   :rdy                          ;until RDREADY=1
            lda   MOUSE_PRA                     ;the byte
            pha
            lda   MOUSE_PRB
            ora   #$10                          ;RDACK high
            sta   MOUSE_PRB
:drop       lda   MOUSE_PRB
            and   #$40
            bne   :drop                         ;until RDREADY=0
            lda   MOUSE_PRB
            and   #$EF                          ;RDACK low
            sta   MOUSE_PRB
            stz   MOUSE_CRA
            lda   #$FF
            sta   MOUSE_PRA                     ;DDRA=$FF again
            lda   #$04
            sta   MOUSE_CRA
            pla
            rts
