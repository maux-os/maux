*---------------------------------------------------------------
* tty3.s -- the virtual-console reset/switch and raw key input.
*
* SPLIT OUT OF tty.s (S9 L4, 2026-08-29): that file's own
* stripped text was 16578 B, past `as`'s 16126 B source window,
* so
* it could never be assembled inside maux as one REL module. The
* cut is at a section boundary and this file is `put`
* immediately
* after its parent, so the emitted bytes are unchanged -- which
* is
* what check-bytes asserts.
*---------------------------------------------------------------
*-- VC_RESET moved to tty8.s (2026-09-03, as's source window:
*-- 22 B over on testevtest after the surface work).

*---------------------------------------------------------------
* VC_SWITCH -- make console A (0..VC_COUNT-1) the active one.
* Saves the active image to its annex slot, then loads the
* target's slot -- or VC_RESETs a console touched for the first
* time. Out-of-range A is ignored. The whole exchange runs
* interrupt-masked (php/sei/plp): the tick hook cooks keys into
* this very struct, and a poll landing between the save and the
* load would cook into a half-switched console.
*
* WHAT THIS DOES NOT DO (docs/CONSOLE.md sec 12, deliberately):
* no redraw -- inactive consoles have no logical screen buffer
* yet, so the glass keeps showing what it showed. State routing
* is per-console as of this block; the SURFACE stays single
* until virtual consoles proper are ruled in scope.
*---------------------------------------------------------------
VC_SWITCH
            cmp   #VC_COUNT
            bcc   :inrange
            rts
:inrange    cmp   VC_ACTIVE
            bne   :switch
            rts
:switch     sta   VC_TARGET
            jsr   TTY_CRSR_HIDE            ;glyph-restore is
                                           ;per-console state --
                                           ;park it first
            ;-- THE SCREEN MOVES OUTSIDE THE MASKED REGION, both
            ;-- ways. A 24x80 blit is on the order of 100,000
            ;-- cycles; running it under sei would drop timer
            ;-- ticks by the handful every switch. Nothing it
            ;-- touches needs that protection -- a key cooked
            ;-- mid-blit lands in an input buffer, not on the
            ;-- glass. The STRUCT exchange still does, and it is
            ;-- as short as it ever was.
            ;-- Carry set from VCS_SAVE_X = UltraTerm, whose
            ;-- VRAM cannot be read back; its image is left
            ;-- stale rather than overwritten with garbage.
            lda   VC_ROW
            pha
            ldx   VC_ACTIVE
            lda   #0
            jsr   VCS_BLIT_X
            pla
            sta   VC_ROW
            php
            sei
            ldx   VC_ACTIVE
            jsr   VC_SAVE_X
            ldx   VC_TARGET
            jsr   VC_MASK_X
            and   VC_INITED
            bne   :warm
            ldx   VC_TARGET
            jsr   VC_MASK_X
            ora   VC_INITED
            sta   VC_INITED
            jsr   VC_RESET                 ;first touch: fresh
                                           ;console, no slot to
                                           ;load
            lda   VC_TARGET
            sta   VC_ACTIVE
            sta   VC_LIVE
            plp
            jsr   TTY_HW_SET               ;VIDMODE V1: the
                                           ;incoming console's
                                           ;backend owns the
                                           ;glass now
            jsr   TTY_CLR_BODY             ;and a blank glass,
                                           ;not the outgoing
                                           ;console's
            lda   VC_TARGET                ;-- which it now OWNS
            jmp   VC_TAKE_A
:warm       ldx   VC_TARGET
            jsr   VC_LOAD_X
            lda   VC_TARGET
            sta   VC_ACTIVE
            sta   VC_LIVE
            plp
            jsr   TTY_HW_SET               ;VIDMODE V1
            lda   VC_TARGET                ;already on its glass
            jsr   VC_OWNS_A                ;(the other surface,
            bcs   :onglass                 ;untouched since): no
            lda   VC_ROW                   ;no blit at all
            pha
            ldx   VC_TARGET
            lda   #1
            jsr   VCS_BLIT_X
            pla
            sta   VC_ROW
            lda   VC_TARGET
            jsr   VC_TAKE_A
:onglass
*-- A LINE THAT ARRIVED WHILE THIS CONSOLE WAS AWAY still needs
*-- its reader woken. The wake at commit time hit
*-- TTY_RD_CHAN+active; if the reader re-blocked after a switch
*-- -away, nothing ever re-wakes it -- TTY_POLL returns early
*-- while a line is pending, so no later tick helps (finding 2nd
*-- review, finding 6). The loaded struct knows: a committed
*-- line or a pending EOF here means wake TTY_RD_CHAN+VC_ACTIVE
*-- (which is this console now).
            lda   VC_IN_POS
            cmp   VC_IN_LEN
            bcc   :wake
            lda   VC_EOF_PEND
            beq   :nowake
:wake       jsr   TTY_WAKE_RDRS
:nowake     rts

*-- VC_SAVE_X/VC_LOAD_X/VC_BC_COMM/VC_MASK_X moved to
*-- tty6.s 2026-08-31 (as-window rebalance; flat namespace).


*---------------------------------------------------------------
* TTY_OUTBUF -- kernel-side staging buffer for bulk TTY_WRITE
* (docs/PROCIO.md "Bulk TTY_WRITE", 2026-08-20). One BankCopy
* fills this from the caller's bank; TTY_WRITE's parser loop
* then reads it as plain main memory. TTY_OWBUF_SZ=254, well
* under P_COUNT's 255-byte per-call ceiling -- a request over
* this loops TTY_WRITE's own chunk loop rather than growing the
* buffer to match: static kernel footprint (this buffer plus
* the call's own new code) was the difference between passing
* and failing check-dual's $4000 pad budget (src/test/
* processtestb.s); 96 clears it with room to spare rather than
* a tight fit. NOT part of the VC struct -- this is pure
* staging scratch, dead between TTY_WRITE calls, so consoles
* can share the one buffer. SIZE NOTE (2026-08-23): tty.s is
* now the tree's LARGEST put file (~33.3K, past process.s's
* ~29.3K); peak real-Merlin buffer use is source + manifest
* together against the 41,215-byte ceiling, measured ~38.3K by
* the S3 review -- check-dual is the gate that sees it. Grow
* tty2.s in preference to this file.
*---------------------------------------------------------------
*-- TTY_OUTBUF (TTY_OWBUF_SZ B): inc/mm.kbss.equ, low main.
*-- Interrupt islands (tty.s TTY_ISLAND, AC1 stage 1,
*-- 2026-09-13):
VC_HOTREQ   ds 1                  ;Option-1..4 asked for a
                                  ;console, 1-based; 0 = none.
                                  ;SET in TTY_KEYIN, which runs
                                  ;from the TICK as well as from
                                  ;a read -- so the switch it
                                  ;asks for is PERFORMED
                                  ;elsewhere, in process context
                                  ;(TTY_VC_PEND's header)
TTY_WR_BUSY ds 1                  ;a tty WRITE is mid-flight:
                                  ;the tick captures keys but
                                  ;does not cook, echo or run
                                  ;^C/^Z
TTY_CTL_PEND ds 1                 ;a ^C ($83) or ^Z ($9A) that
                                  ;arrived during a write, run
                                  ;when the write ends
TTY_ISLAT   ds 1                  ;TTY_OUTBUF index at which
                                  ;the next island opens
*-- TTY_KEYIN's CSI final byte. Staging scratch like the
*-- buffer above, dead between calls, so consoles share it.
TTY_CSI_CH  ds 1

*---------------------------------------------------------------
* TTY_KEYIN -- drain the one-key hardware latch into the raw
* ring. ALWAYS safe to call, from any poll path including the
* main-context IRQ shim: it touches only the latch and the ring
* indexes, never the cooked state. A full ring drops the newest
* key (the latch is cleared regardless -- holding it would just
* lose the NEXT key instead). Clobbers A/X/Y.
*---------------------------------------------------------------
TTY_KEYIN
            lda   KBD_DATA
            bmi   :key                    ;strobe: a key (bpl
            rts                           ;:none went out of
:key        tax                           ;range, 2026-09-13)
            bit   KBD_STROBE
*-- OPTION (Solid Apple) folds a key to its CONTROL code --
*-- how ^H/^U/^J/^K stay reachable once the arrows below stop
*-- producing them. It is a PUSHBUTTON, not a keyboard bit, so
*-- it is sampled here or not at all (mm.hw.equ cites
*-- Sather).
*-- `and #$9F` does both cases at once: 'H' $C8 -> $88, 'h' $E8
*-- -> $88.
            lda   BUTN1
            bpl   :plain
*-- OPTION-1..4 SWITCHES CONSOLES (operator, 2026-09-20: "chvt
*-- needs to be a shortcut key"). It cannot strand anyone: this
*-- is kernel code and needs no process, and console 1 always
*-- has a shell (pid 1 guarantees it), so Option-1 always comes
*-- back even from a console nobody is reading. CREATING a
*-- console is still `chvt N`.
            cpx   #$B1                    ;'1'
            bcc   :optoth
            cpx   #$B5                    ;past '4'
            bcs   :optoth
            txa
            sec
            sbc   #$B0                    ;'1'..'4' -> 1..4
            sta   VC_HOTREQ
*-- AND WAKE SOMEBODY TO DO IT. The request is performed in
*-- process context (TTY_VC_PEND), and the only process-context
*-- path that runs on its own is a reader coming back from
*-- TTY_READ -- which is woken by a COMPLETED LINE. A swallowed
*-- hotkey completes nothing, so without this the switch waited
*-- for the user's next Return: measured 2026-09-20, the chord
*-- was detected and the key consumed and the screen did not
*-- move. Same call the cook makes, from the same context.
            jsr   TTY_WAKE_RDRS
            rts                           ;key consumed
*-- THE FOLD IS FOR LETTERS, and only letters. Its own note
*-- above says so -- "both cases at once: 'H' $C8 -> $88, 'h'
*-- $E8 -> $88" is upper and lower CASE -- but the `and #$9F`
*-- was applied to whatever was held down, so a digit folded
*-- too: Option-1 quietly meant ^Q. That was an accident of a
*-- blanket mask, not a binding anyone chose, and it is the
*-- only reason the console hotkey above looked like it was
*-- taking something. Scoped 2026-09-20 (operator: "option
*-- 1,2,3,4 has nothing to do with QRST or JKUH"): letters
*-- fold, everything else falls through and types itself, so
*-- Option-5 is now a 5 and the four codes the fold actually
*-- exists for -- ^H/^U/^J/^K, unreachable otherwise because on
*-- this keyboard they ARE the arrow keys -- are still
*-- Option-h/u/j/k.
:optoth     cpx   #$C1                    ;'A'
            bcc   :plain
            cpx   #$DB                    ;past 'Z'
            bcc   :ctlfld
            cpx   #$E1                    ;'a'
            bcc   :plain
            cpx   #$FB                    ;past 'z'
            bcs   :plain
:ctlfld     txa
            and   #$9F
            tax
            bra   :single
*-- THE FOUR ARROWS ARE ^H/^U/^J/^K ON THIS KEYBOARD -- Sather:
*-- "left arrow, right arrow, down arrow and up arrow produce
*-- code that is identical to that of CONTROL-H, CONTROL-U,
*-- CONTROL-J and CONTROL-K". Emitting them as VT/ANSI CSI frees
*-- those four control codes for their real meanings AND stops
*-- the RIGHT arrow reading as ^U, which cooked mode treats as
*-- line-kill -- pressing it used to erase the line.
:plain      cpx   #$88                    ;left
            beq   :csiD
            cpx   #$95                    ;right
            beq   :csiC
            cpx   #$8A                    ;down
            beq   :csiB
            cpx   #$8B                    ;up
            beq   :csiA
:single     txa
*-- Inside a write's interrupt island (tty.s TTY_ISLAND) the
*-- ^C/^Z handlers must NOT run: they render (^C, a CR, the
*-- line-editor's end) on a glass the write owns. The key is
*-- parked in TTY_CTL_PEND and run when the write ends (tty.s
*-- TTY_WRITE's :done). Every other key is captured into the
*-- ring as usual -- that is the island's point.
            ldy   TTY_WR_BUSY
            beq   :live
            cmp   #$83
            beq   :defer
            cmp   #$9A
            bne   :notstop
:defer      sta   TTY_CTL_PEND
            rts
:live       cmp   #$83                    ;^C -- the interrupt
            bne   :notintr                ;character never
            jmp   TTY_INTR                ;enters the ring (jmp,
                                          ;not beq -- VT102
                                          ;slice 1 pushed this
                                          ;out of beq's range)
:notintr    cmp   #$9A                    ;^Z -- the suspend
            bne   :notstop                ;character, likewise
            jmp   TTY_STOP
:notstop
*-- META IS OPEN APPLE (docs/CONSOLE.md sec 4b): OA held at the
*-- moment the key comes off the latch pushes ESC ahead of it --
*-- OA+f reaches the cook as ESC f, the encoding terminals have
*-- always used for Meta, so the cook's lone-ESC dispatch serves
*-- the button and a typed ESC prefix with one path. Sampled
*-- at CAPTURE, not cook: the ring can lag the press by ticks.
*-- Arrows never get here (CSI above) and ^C is intercepted
*-- above, so neither can be prefixed. Room for BOTH bytes is
*-- checked first -- a prefix without its key would arm the ESC
*-- state for whatever arrives next. TTY_RAWROOM's check is for
*-- 3 (its arrow-CSI sizing), one stricter than the 2 needed:
*-- at exactly-two-free the whole chord is dropped, which is
*-- the ring's normal degradation, not a new failure mode.
            sta   ED_MKEY               ;PUSHKEY/RAWROOM clobber
                                        ;A, X and Y -- a cell,
                                        ;not a register, carries
                                        ;the key across the
                                        ;prefix push
            lda   BUTN0
            bpl   :nometa
            jsr   TTY_RAWROOM
            bcs   :nopush
            lda   #$9B                    ;ESC
            jsr   TTY_PUSHKEY
:nometa     lda   ED_MKEY
            jmp   TTY_PUSHKEY
:nopush     rts
:csiA       lda   #$C1
            bra   :csi
:csiB       lda   #$C2
            bra   :csi
:csiC       lda   #$C3
            bra   :csi
:csiD       lda   #$C4
*-- Three bytes or none: a ring that takes ESC and `[` but not
*-- the final byte hands the reader a truncated escape, and
*-- a truncated escape is indistinguishable from someone typing
*-- ESC [. Check room for all three first.
*-- DECCKM (VT102 slice 1, docs/CONSOLE-VT102.md sec 2): when
*-- set, the middle byte is 'O' ($CF, high bit) instead of '['
*-- ($DB) -- application cursor keys, ESC O A..D instead of
*-- ESC [ A..D. TTY_KEYIN never claims the modern serial-tty
*-- raw-
*-- read re-framing (tty7.s TTY_COOK_RAW's own :echo path checks
*-- for a literal $DB) tracks this: maux's own vi never enables
*-- DECCKM, so that path is unaffected in practice.
:csi        sta   TTY_CSI_CH
            jsr   TTY_RAWROOM
            bcs   :none
            lda   #$9B                    ;ESC
            jsr   TTY_PUSHKEY
            lda   VC_DECCKM
            beq   :ansi
            lda   #$CF                    ;'O' -- DECCKM: SS3
            bra   :mid
:ansi       lda   #$DB                    ;'['
:mid        jsr   TTY_PUSHKEY
            lda   TTY_CSI_CH
            jmp   TTY_PUSHKEY
:none       rts

*---------------------------------------------------------------
* TTY_RAWROOM -- carry CLEAR if the raw ring can take 3 more
* bytes. Clobbers A, Y.
*---------------------------------------------------------------
TTY_RAWROOM ldy   #3
            lda   VC_RAW_TL
:loop       clc
            adc   #1
            and   #VC_RAW_MASK
            cmp   VC_RAW_HD
            beq   :full
            dey
            bne   :loop
            clc
            rts
:full       sec
            rts

*---------------------------------------------------------------
* TTY_PUSHKEY -- push A into the raw ring; drop it if full.
* Clobbers A, Y.
*---------------------------------------------------------------
TTY_PUSHKEY tay
            lda   VC_RAW_TL
            clc
            adc   #1
            and   #VC_RAW_MASK
            cmp   VC_RAW_HD
            beq   :full                   ;full: drop
            tax
            tya
            ldy   VC_RAW_TL
            sta   VC_RAW_BUF,y
            stx   VC_RAW_TL
:full       rts

*---------------------------------------------------------------
* TTY_INTR -- ^C (docs/CONSOLE.md section 4). Reached from
* TTY_KEYIN, so from ANY poll context including the mid-MLI
* shim -- which is why it only marks and tidies: K_INTR_PEND is
* consumed by SCH_TICK's kill sweep (PRC_INTR_SWP), the only
* context where killing is legal. Locally: echo ^C, throw away
* the half-typed line and any type-ahead, and complete an EMPTY
* line -- so a shell blocked in read wakes and reprompts even
* when there was no foreground process to kill.
* K_INTR_PEND CARRIES THE TYPING CONSOLE (docs/JOB-CONTROL.md
* Increment A): VC_ACTIVE+1, 0 = none, so the sweep aims at that
* console's foreground job and no other. The key came off the
* glass, so VC_ACTIVE is the console it was typed on. Two ^Cs
* on two consoles inside one tick: the second overwrites the
* first (one cell, deliberately -- a queue for a case a human
* cannot produce).
*
* TTY_STOP is ^Z (docs/JOB-CONTROL.md Increment B): the same
* routine with the other cell -- K_STOP_PEND, consumed by
* SCH_TICK's suspend sweep (PRC_STOP_SWP) -- and the other
* echo letter. Everything from the cursor park down is shared:
* ^Z also discards the half-typed line and completes an EMPTY
* one, so a shell whose foreground job just stopped, or that
* had nothing to stop, wakes and reprompts exactly as it does
* for ^C. Intercepted upstream of the ring like ^C, so it is a
* suspend in EVERY tty mode -- a raw-mode program cannot eat it.
*---------------------------------------------------------------
TTY_STOP
            lda   VC_ACTIVE
            inc
            sta   K_STOP_PEND
            lda   #'Z'
            bra   TTY_INTR_TL
TTY_INTR
            lda   VC_ACTIVE
            inc
            sta   K_INTR_PEND
            lda   #'C'
*-- Park the painted cursor and anchor at line END before the
*-- ^C echo: with readline the cursor can sit mid-line, and
*-- echoing ^C + CR there overwrites the tail and leaves a
*-- stale VC_CRSR_SAV glyph (readline finding 3). Both
*-- helpers are tick-context safe -- the poll path already
*-- calls them. TTY_CSI_CH carries the echo letter across them
*-- (staging scratch, dead between calls; see its declaration).
TTY_INTR_TL sta   TTY_CSI_CH
            jsr   TTY_CRSR_HIDE
            jsr   TTY_ED_END
            lda   VC_RAW_HD              ;drop type-ahead
            sta   VC_RAW_TL
            stz   VC_ESC_STATE           ;abandon a half-open
                                          ;escape sequence
            lda   #'^'
            jsr   TTY_PUT_BYTE
            lda   TTY_CSI_CH
            jsr   TTY_PUT_BYTE
* -- Deliver an EMPTY completed line (the :cr path specialized
* -- to a discarded edit buffer -- a global label mid-TTY_POLL
* -- would sever its local-label scope, so inline it): a shell
* -- blocked in read wakes and reprompts even when there was
* -- nothing to kill.
            stz   VC_EDIT_LEN
            stz   VC_EDIT_POS             ;sec 4b: the cursor
            lda   #$FF                    ;and any history walk
            sta   VC_HIST_CUR             ;die with the line
            lda   #$8D
            sta   VC_INBUF
            lda   #1
            sta   VC_IN_LEN
            lda   #$8D
            jsr   TTY_PUT_BYTE            ;echo the CR (TT9_CR
                                          ;resets the ^L shadow)
            stz   VC_IN_POS
*-- RETRACT THE LINE IF NOBODY WAS IN read (2026-10-07, TTY-
*-- TYPEAHEAD-BELL Part 3). A shell in WAIT on a killed child is
*-- not a reader: it reprompts when the wait returns, and its
*-- next READLINE would find this phantom empty line and
*-- reprompt a second time on the same row (`$ $`). Nothing was
*-- woken -> nothing consumes it -> take it back. A shell
*-- blocked in read was woken (K_WAKE_COUNT > 0) and keeps it.
            jsr   TTY_WAKE_RDRS
            lda   K_WAKE_COUNT
            bne   :woke
            stz   VC_IN_LEN
:woke       rts

*---------------------------------------------------------------
* TTY_VC_PEND -- perform a console switch Option-1..4 asked for.
* OUT: carry SET if a switch happened (the caller's idea of
* which console owns the glass is now stale), clear if not.
*
* WHY THE KEY DOES NOT DO THIS ITSELF. TTY_KEYIN runs from
* TTY_TICK, i.e. from the interrupt, and VC_SWITCH blits a
* 24x80 screen -- on the order of 100,000 cycles. Doing that in
* the ISR would cost ticks by the handful on every switch, for
* the same reason VC_SWITCH already moves its own blit outside
* its masked region. So the key records the request and the
* first process-context tty path to notice carries it out.
*
* Serviced from TWO places on purpose: TTY_READ's poll (the
* shell sitting at a prompt, which is when a person reaches for
* the hotkey) and TTY_WR_LEAVE (a program producing output,
* which is the other time they do -- watching a build and
* wanting the other console). A process that neither reads nor
* writes delays its own switch until it does one or the other.
*---------------------------------------------------------------
TTY_VC_PEND
            lda   VC_HOTREQ
            beq   :vpno
            stz   VC_HOTREQ
            sec
            sbc   #1                      ;1..4 -> 0..3
*-- REFUSE A CONSOLE WITH NO SHELL. Measured 2026-09-20 by the
*-- operator, on the first thing anyone tries: Option-2 before
*-- any `chvt 2` moved the glass to a console nobody reads --
*-- and then Option-1 could not come back, because the switch
*-- is PERFORMED by a reader on the ACTIVE console and an empty
*-- one has none. Nothing was awake to service the request, so
*-- the machine looked wedged. It was not (the tick ran, the
*-- key was taken), but that is no comfort to whoever is
*-- holding the keyboard. The claim in this file's first
*-- version -- "it cannot strand anyone, console 1 always has a
*-- shell" -- was wrong: what matters is whether the console
*-- you are ON has a reader, not whether console 1 does.
*-- The scan is safe HERE, in process context; it is exactly
*-- what the ISR could not afford and the reason this routine
*-- exists at all.
            pha
            jsr   PRC_VCSCAN
            jsr   PRC_SEL_CRBNK           ;scan parks BANKSEL on
            plx                           ;the annex
            lda   PRC_VCSBUF,x
            beq   :vpno                   ;no shell there: stay
            txa
            jsr   VC_SWITCH
            sec
            rts
:vpno       clc
            rts

TTY_POLL
            jsr   TTY_KEYIN               ;capture FIRST -- the
                                          ;latch holds one key
                                          ;whatever the cooked
                                          ;state below decides
            lda   TTY_WR_BUSY             ;a write's island:
            beq   :drain                  ;capture only -- the
            rts                           ;cook renders
* -- Drain: cook ring keys until a line completes or the ring
* -- empties. One-key-per-poll made delivery tick-bound (~60
* -- keys/s) and a scripted typist outran it.
:drain      lda   VC_IN_POS
            cmp   VC_IN_LEN
            bcs   :more
            rts                           ;line pending: keys
                                          ;wait in the ring
:more       ldx   VC_RAW_HD
            cpx   VC_RAW_TL
            bne   :cook
            jmp   TTY_CRSR_SHOW           ;ring empty: idle at
                                          ;the prompt -- keep
                                          ;the cursor painted
:cook       jsr   TTY_COOK1
            bra   :drain

TTY_COOK1
            jsr   TTY_CRSR_SHOW
            ldx   VC_RAW_HD
            lda   VC_RAW_BUF,x
            sta   PRC_BYTE
            txa
            clc
            adc   #1
            and   #VC_RAW_MASK
            sta   VC_RAW_HD
            jsr   TTY_CRSR_HIDE
*-- RAW FORK (stty seed, 2026-09-02, docs/VI-DESIGN.md): !ICANON
*-- skips the whole line discipline below -- every ring byte is
*-- committed as its own 1-byte "line" (TTY_COOK_RAW, tty7.s),
*-- so a blocked read() sees it the instant it is typed, no CR
*-- required. ^C never reaches here either way -- TTY_KEYIN
*-- intercepts it upstream of the ring, unconditionally.
            lda   VC_TMODE
            and   #TMD_ICANON
            bne   :cooked
            jmp   TTY_COOK_RAW
:cooked     lda   PRC_BYTE
            and   #$7F
*-- SWALLOW ESC [ <final> IN COOKED MODE. TTY_KEYIN emits the
*-- arrows as CSI now, and a line editor that does not know that
*-- inserts `[` and the final letter as ordinary printables --
*-- left-arrow would type "[D" into your line. Three states:
*-- 0 idle, 1 saw ESC, 2 saw ESC [. A lone ESC followed by
*-- anything else falls through and is handled normally, so
*-- typing ESC by hand still behaves.
            ldx   VC_KESC
            beq   :esc0
            cpx   #1
            bne   :escfin                 ;state 2: final byte
            cmp   #$5B                    ;'[' continues it
            bne   :escdrop
            ldx   #2
            stx   VC_KESC
            rts
*-- COOKED MODE INTERPRETS THE ARROWS, it does not discard them.
*-- ESC [ D is the LEFT arrow. Translating it to CSI and then
*-- swallowing it took the primary erase key away and left only
*-- DEL, so the final byte is dispatched, not dropped: A/B/C/D
*-- all reach readline-lite motion/history now.
*-- LEFT IS MOTION, NOT ERASE (fixed 2026-09-02 -- a prior cut
*-- left it aliased to :bs, so left-arrow erased instead of
*-- moving the cursor; check_play.py's own readline-lite suite
*-- already binds ^B, the identical motion, to TTY_ED_LEFT, so
*-- this makes the arrow agree with its own C-h muscle memory
*-- instead of fighting it). $88 (left-arrow) and C-h are the
*-- SAME wire on this keyboard (Sather) and TTY_KEYIN converts
*-- either to this CSI before cook ever sees a bare byte, so
*-- BOTH now move -- cooked-mode erase comes only from DEL
*-- ($7F, the :n7f -> :bs path below) and ^U line-kill ($15).
:escfin     stz   VC_KESC
            cmp   #$44                    ;'D' -- left arrow
            bne   :nescD
            jmp   TTY_ED_LEFT
:nescD      cmp   #$43                    ;'C' -- right arrow
            bne   :nescC
            jmp   TTY_ED_RIGHT
:nescC      cmp   #$41                    ;'A' -- up arrow
            bne   :nescA
            jmp   TTY_ED_HPRV
:nescA      cmp   #$42                    ;'B' -- down arrow
            bne   :nescB
            jmp   TTY_ED_HNXT
:nescB      rts
*-- Lone ESC + letter is META (sec 4b) -- typed ESC f, or OA+f
*-- through TTY_KEYIN's capture-time prefix. Unbound pairs keep
*-- falling through as typed, so ESC-by-hand still behaves.
:escdrop    stz   VC_KESC                 ;lone ESC + this key
            cmp   #$66                    ;'f' -- M-f word fwd
            beq   :mwf
            cmp   #$46                    ;'F'
            beq   :mwf
            cmp   #$62                    ;'b' -- M-b word back
            beq   :mwb
            cmp   #$42                    ;'B'
            beq   :mwb
*-- M-k is kill-to-end's HOME on this keyboard: ^K cannot reach
*-- the cook -- the up arrow produces the identical code
*-- (Sather) and TTY_KEYIN folds $8B to CSI A, history-prev.
*-- The raw $0B binding below stays for input paths with a real
*-- ^K (a future serial tty).
            cmp   #$6B                    ;'k' -- M-k kill line
            beq   :mkl                    ;tail
            cmp   #$4B                    ;'K'
            beq   :mkl
            bra   :esc1
:mwf        jmp   TTY_ED_WDF
:mwb        jmp   TTY_ED_WDB
:mkl        jmp   TTY_ED_KEOL
:esc0       cmp   #$1B
            bne   :esc1
            ldx   #1
            stx   VC_KESC
            rts
:esc1
            cmp   #$0D
            bne   :not_cr                 ;`beq :cr` no longer
            jmp   :cr                     ;reaches -- the ^L
:not_cr                                   ;handler sits between
            cmp   #$04
            bne   :n04
            jmp   :eof
:n04        cmp   #$08                    ;IIe left-arrow is
            bne   :n08                    ;real BS.
            jmp   :bs
:n08        cmp   #$7F                    ;IIe DEL key is ASCII
            bne   :n7f                    ;DEL.
            jmp   :bs
:n7f        cmp   #$15                    ;^U line kill for
            bne   :n15                    ;cooked mode.
            jmp   :kill
:n15        cmp   #$0C                    ;^L clear screen
            bne   :n0c
            jmp   :clrscr
:n0c
*-- Readline-lite bindings (sec 4b). jmp, not beq: this zone's
*-- branch budget is long spent (see the ^L note above).
            cmp   #$01                    ;^A line start
            bne   :n01
            jmp   TTY_ED_HOME
:n01        cmp   #$05                    ;^E line end
            bne   :n05
            jmp   TTY_ED_END
:n05        cmp   #$02                    ;^B back one char
            bne   :n02
            jmp   TTY_ED_LEFT
:n02        cmp   #$06                    ;^F fwd one char
            bne   :n06
            jmp   TTY_ED_RIGHT
:n06        cmp   #$0B                    ;^K kill to end
            bne   :n0b
            jmp   TTY_ED_KEOL
:n0b        cmp   #$10                    ;^P history back
            bne   :n10
            jmp   TTY_ED_HPRV
:n10        cmp   #$0E                    ;^N history fwd
            bne   :n0e
            jmp   TTY_ED_HNXT
:n0e        cmp   #$20
            bcs   :ge_space
            rts
:ge_space
            cmp   #$7F
            bcc   :printable
            rts
:printable
            ldx   VC_EDIT_LEN
            cpx   #127                    ;reserve room for the
                                          ;CR
            bcc   :room
            rts
:room
            ora   #$80
            jmp   TTY_ED_INS               ;insert AT THE CURSOR
                                           ;(sec 4b) -- appends
                                           ;when the cursor is
                                           ;at the end, which is
                                           ;the old behaviour
:bs         ;Cooked mode accepts both physical erase keys. The
            ;original byte remains available to the future
            ;raw/noecho path.
            jmp   TTY_ED_DEL               ;delete BEFORE the
                                           ;cursor (sec 4b)
:kill       jmp   TTY_ED_KILL              ;whole-line kill from
                                           ;any cursor position

* ^L -- clear the screen and redraw the uncommitted input.
*
* In real Unix this is the READLINE binding, not a tty one: the
* driver passes ^L through and the application redraws. maux has
* no line editor yet (raw mode is deferred, docs/CONSOLE.md
* section 4), and cooked mode hands nothing to sh until Return,
* so the line discipline is the only layer that can respond
* while the user is still typing. Move this to the userland
* editor when raw mode lands.
*
* The edit buffer is re-echoed so ^L does not swallow a half-
* typed command. Since 2026-08-19 the prompt IS redrawn too:
* VC_OUTSHDW records printable bytes the PROCESS WRITE path
* (sh's prompt, command output) has emitted since the last CR,
* and ^L replays that shadow through TTY_PUT_BYTE before the
* edit-buffer re-echo. Limits: only $A0-$FE printable bytes are
* recorded -- control/escape bytes, and anything written while
* an escape sequence is mid-parse, are not (TTY_SHDW_TAP's
* header has the full rule and the reason -- replay must never
* be able to inject a partial escape into TTY_PUT_BYTE from this
* tick-context path). The shadow caps at 80 bytes; past that,
* recording stops until the next CR and replay is truncated
* rather than corrupted. A prompt that itself contains escape
* sequences (a colored prompt, say) will not replay correctly --
* not handled here.
:clrscr     jsr   TTY_CLR_SCRN           ;the SAME command
                                          ;`ESC [ 2 J` runs
            ldx   #0
:replay     cpx   VC_OSHDW_LEN        ;replay the shadowed
                                          ;output line first
            beq   :reecho0
            lda   VC_OUTSHDW,x
            phx                           ;TTY_PUT_BYTE reaches
            jsr   TTY_PUT_BYTE            ;TTY_WR_CELL, which
            plx                           ;loads X with VC_ROW
            inx
            bra   :replay
:reecho0    ldx   #0
:reecho     cpx   VC_EDIT_LEN
            beq   :rewalk
            lda   VC_INBUF,x
            phx                           ;TTY_ED_ECHO reaches
            jsr   TTY_ED_ECHO             ;TTY_WR_CELL, which
            plx                           ;loads X with VC_ROW
            inx
            bra   :reecho
*-- ^L re-echo leaves the glass cursor at line end; walk it back
*-- to where the EDIT cursor actually is (sec 4b). TTY_ED_ECHO
*-- (tty6.s), not bare TTY_PUT_BYTE: :rewalk's TTY_ED_BWK steps
*-- back with an IMMEDIATE-wrap model (TTY_ED_CLF, unchanged
*-- since before xenl), so the forward pass that funds it must
*-- resolve its own pending wrap on the spot too (VT102 slice 3,
*-- docs/CONSOLE-VT102.md sec 2/4 -- see TTY_ED_ECHO's header).
:rewalk     lda   VC_EDIT_LEN
            sec
            sbc   VC_EDIT_POS
            beq   :done
            jsr   TTY_ED_BWK
            jmp   :done
:eof        jsr   TTY_ED_END              ;anchor the SCREEN
                                          ;cursor at line end
                                          ;FIRST -- committing
                                          ;from a mid-wrapped-
                                          ;line cursor lands the
                                          ;next output on the
                                          ;tail row (review
                                          ;readline finding 2)
            jsr   TTY_ED_CMIT             ;history commit +
                                          ;cursor reset (sec 4b)
            lda   VC_EDIT_LEN
            beq   :empty_eof
            sta   VC_IN_LEN
            stz   VC_EDIT_LEN
            stz   VC_IN_POS
            jsr   TTY_WAKE_RDRS
            bra   :done
:empty_eof  stz   VC_IN_POS
            lda   #1
            sta   VC_EOF_PEND
            jsr   TTY_WAKE_RDRS
            bra   :done
:cr         jsr   TTY_ED_END              ;screen cursor to line
                                          ;end first -- the CR
                                          ;echo must come AFTER
                                          ;the whole line (per
                                          ;readline finding 2)
            jsr   TTY_ED_CMIT             ;history commit +
                                          ;cursor reset, BEFORE
                                          ;the CR lands in the
                                          ;buffer (sec 4b)
            ldx   VC_EDIT_LEN
            lda   #$8D
            sta   VC_INBUF,x
            inx
            stx   VC_IN_LEN
            stz   VC_EDIT_LEN
            jsr   TTY_PUT_BYTE            ;the echoed CR ends
                                          ;the ^L shadow's line
                                          ;in TT9_CR (a blank
                                          ;Enter has no output
                                          ;CR; prompts stacked
                                          ;until 42dd395)
            stz   VC_IN_POS
            jsr   TTY_WAKE_RDRS
:done       rts

*-- The woken channel is the ACTIVE console's: keys cook into
*-- VC_STATE, which is the active console's struct, so the line
*-- that just completed belongs to it -- and TTY_READ sleeps on
*-- TTY_RD_CHAN+target now. Waking the bare base channel left a
*-- /dev/tty2 reader asleep on $A1 forever while every Return
*-- woke $A0 (review finding 3, 2026-08-31).
TTY_WAKE_RDRS
            clc
            lda   #TTY_RD_CHAN
            adc   VC_ACTIVE
            jsr   SCH_WAKEUP
            jsr   PRC_SEL_CRBNK
            rts
