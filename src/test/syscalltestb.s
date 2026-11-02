*---------------------------------------------------------------
* syscalltestb.s -- image body for syscalltest.s.
* Split out so the top-level stays a thin MANIFEST: real
* Merlin holds the resident top-level source AND the PUT
* file being read in the same 41215-byte buffer, so every
* byte here would come off every module's budget.
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J)
*---------------------------------------------------------------
*-- Pathname/label data moved to the TOP of this put module
*-- (S9 EQU burn-down, 2026-08-29): the *_LEN equates were used
*-- in immediate operands before their definitions, which real
*-- Merlin-8 refuses ("Illegal forward reference"). A put
*-- module's first bytes are safe for data -- execution enters
*-- via the manifest's own jmp, never by falling in.
RPTLBL      asc   "SYS=$"
RPTLBLLEN   equ   *-RPTLBL
ARITHLBL    asc   "ARITH D0=$"
ARITHLBLLEN equ   *-ARITHLBL



*---------------------------------------------------------------
* Test globals (main memory, kernel-side -- these live in
* ordinary main $0A00+ space, not the LC/ZP kernel-internal
* cells entry.s owns).
*---------------------------------------------------------------
K_SYSC_COUNT ds  2             ;incremented by TCALL_ECHO
                                  ;on every successful round
                                  ;trip
K_IRQCOUNT      ds  2             ;incremented by MOUSE_ISR on
                                  ;every serviced VBL interrupt
K_ARITH_D0      ds  1             ;TCALL_ARITH's result when
                                  ;called with D=0 (expected
                                  ;$7E) -- copied in from the
                                  ;process's $0910 by
                                  ;TCALL_REPORT
K_ARITH_D1      ds  1             ;ditto, called with D=1 SET
                                  ;beforehand (kernel's CLD must
                                  ;still force $7E) -- process's
                                  ;$0911
K_ARITH_DFLAG   ds  1             ;the caller's P right after
                                  ;the D=1 call returned -- bit
                                  ;3 must be SET (D restored) --
                                  ;process's $0912

*---------------------------------------------------------------
* TCALL_ECHO -- call #1. Parms ptr (frame A/X, per the
* register transport ruling) points at a 4-byte payload in the
* CALLING process's own $0200-$BFFF space. Reads it via
* COPYIN_ENTRY into a kernel scratch buffer, writes it back via
* COPYOUT_ENTRY to payload+4 in the SAME process -- proving
* copyin AND copyout both moved real data through the $FFxx
* doors' trapframe-transported pointer. Returns carry clear, A=4
* (bytes moved) on success; carry set, A=ERR_INVAL if
* copyin/copyout refused the address ($C000-$CFFF window).
*---------------------------------------------------------------
TCALL_ECHO
            lda   K_PARMLO
            sta   K_CPY_PROC
            lda   K_PARMHI
            sta   K_CPY_PROC+1
            lda   #<K_ECHO_BUF
            sta   K_CPY_MAIN
            lda   #>K_ECHO_BUF
            sta   K_CPY_MAIN+1
            lda   #4
            sta   K_CPY_LEN
            jsr   COPYIN_ENTRY
            lda   K_CPY_ERR
            bne   :fail

            ;-- write the SAME 4 bytes back to payload+4 in the
            ;process --
            clc
            lda   K_PARMLO
            adc   #4
            sta   K_CPY_PROC
            lda   K_PARMHI
            adc   #0
            sta   K_CPY_PROC+1
            ;-- K_CPY_MAIN/K_CPY_LEN unchanged from the copyin
            ;above --
            jsr   COPYOUT_ENTRY
            lda   K_CPY_ERR
            bne   :fail

            inc   K_SYSC_COUNT
            bne   :nowrap
            inc   K_SYSC_COUNT+1
:nowrap     lda   #4
            sta   K_RESULT
            stz   K_RESULT_ERR
            rts
:fail       lda   #ERR_INVAL
            sta   K_RESULT
            lda   #1
            sta   K_RESULT_ERR
            rts

K_ECHO_BUF  ds    4

* See T.SYSCALLTE.TXT: "TESTCALLARITH -- call #2. Deliberately"
TCALL_ARITH
            lda   #$79
            clc
            adc   #$05
            sta   K_RESULT
            stz   K_RESULT_ERR
            rts

*---------------------------------------------------------------
* TCALL_REPORT -- call #3. Prints K_SYSC_COUNT/K_IRQCOUNT
* (hex) and the D-flag test's two results to the text page. Runs
* kernel-side (RAMWRT already main throughout kernel
* processing), so these writes land in the REAL, visible bank-0
* video memory even though the CALLER is running in bank 1.
*---------------------------------------------------------------
TCALL_REPORT
            ;-- copy in the process's 3 stashed ARITH-probe
            ;bytes
            ;-- ($0910-$0912) before printing -- see
            ;FKP_SRC. --
            lda   #<$0910
            sta   K_CPY_PROC
            lda   #>$0910
            sta   K_CPY_PROC+1
            lda   #<K_ARITH_D0
            sta   K_CPY_MAIN
            lda   #>K_ARITH_D0
            sta   K_CPY_MAIN+1
            lda   #3
            sta   K_CPY_LEN
            jsr   COPYIN_ENTRY

            ldy   #0
:banner     lda   RPTLBL,y
            sta   $0500,y
            iny
            cpy   #RPTLBLLEN
            bne   :banner

            lda   K_SYSC_COUNT+1
            jsr   PrintHexY2
            lda   K_SYSC_COUNT
            jsr   PrintHexY2
            ;-- Y is now 9 ("SYS=$" is 5 cols + 4 hex digits) --
            ;room for
            ;-- "IRQ=$" (5 more cols) + 4 more hex digits =
            ;column 18,
            ;-- comfortably inside the 40-column row (a fixed
            ;`ldy #$28`
            ;-- = column 40 here previously was an out-of-bounds
            ;bug,
            ;-- found by testing -- it wrote past the row and
            ;the "IRQ="
            ;-- label was never actually printed at all, just
            ;one stray
            ;-- 'I' character; fixed to explicit column-9-based
            ;writes
            ;-- instead of a reused loop, to avoid a second
            ;index
            ;-- register mismatch). --
            lda   #'I'+$80
            sta   $0509
            lda   #'R'+$80
            sta   $050A
            lda   #'Q'+$80
            sta   $050B
            lda   #'='+$80
            sta   $050C
            lda   #'$'+$80
            sta   $050D
            ldy   #14                          ;column right
                                               ;after "IRQ=$"
            lda   K_IRQCOUNT+1
            jsr   PrintHexY2
            lda   K_IRQCOUNT
            jsr   PrintHexY2

            ;-- row: D-flag arithmetic proof --
            ldy   #0
:aline      lda   ARITHLBL,y
            sta   $0580,y
            iny
            cpy   #ARITHLBLLEN
            bne   :aline
            lda   K_ARITH_D0
            jsr   PrintHexY3
            lda   K_ARITH_D1
            jsr   PrintHexY3
            lda   K_ARITH_DFLAG
            jsr   PrintHexY3

            stz   K_RESULT
            stz   K_RESULT_ERR
            rts

BANNER0     asc   "MAUX SYSCALL"
BANNER0LEN  equ   *-BANNER0
*---------------------------------------------------------------
* PrintHexY2 -- A = byte, prints 2 hex digits at $0500+Y,+1, Y
* += 2. PrintHexY3 -- same, at $0580+Y,+1, Y += 2 (separate row,
* separate running Y so ARITHLBLLEN's own column math isn't
* shared/clobbered). Both preserve X (PHX/PLX bracket -- see
* src/test/probetest.s's PrintHexY header for why this bracket
* matters to a caller keeping its own index live in X across the
* call).
*---------------------------------------------------------------
PrintHexY2  phx
            pha
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            tax
            lda   HEXDIGITS,x
            sta   $0500,y
            iny
            pla
            and   #$0F
            tax
            lda   HEXDIGITS,x
            sta   $0500,y
            iny
            plx
            rts

PrintHexY3  phx
            pha
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            tax
            lda   HEXDIGITS,x
            sta   $0580,y
            iny
            pla
            and   #$0F
            tax
            lda   HEXDIGITS,x
            sta   $0580,y
            iny
            plx
            rts

HEXDIGITS   asc   "0123456789ABCDEF"

*---------------------------------------------------------------
* K_DISP_LO/HI -- the dispatch table entry.s's KRN_ENTRY
* indexes (1-based call number -> 0-based table index).
*---------------------------------------------------------------
K_DISP_LO
            dfb   <TCALL_ECHO
            dfb   <TCALL_ARITH
            dfb   <TCALL_REPORT
K_DISP_HI
            dfb   >TCALL_ECHO
            dfb   >TCALL_ARITH
            dfb   >TCALL_REPORT

TC_ECHO     equ   1
TC_ARITH    equ   2
TC_REPORT   equ   3

* See T.SYSCALLTE.TXT: "MOUSEISR -- KIRQHOOKs target. ARCHITECT"
*-- MOUSE_PRA/CRA/PRB/CRB used to be defined here. They moved to
*-- inc/memmap.equ when the duplicate-definition ratchet
*-- retired them (one owner per symbol, so a REL build cannot
*-- collide). This harness gets them from there now.

*---------------------------------------------------------------
* MOUSE_SND_CMD -- shared by boot-time bring-up (MAIN_ENTRY)
* AND the IRQ path (MOUSE_ISR): writes A as a command byte to
* the controller via the PRA-write + PRB-bit5-strobe protocol
* (mouse_card.h's on_portb() falling- edge latch). Preserves
* every OTHER live Port B bit (ROM-bank select, the bit6/7
* handshake-ready flags) -- reads PRB first rather than writing
* a blind constant, same "acknowledge one thing, disturb nothing
* else" discipline as ClearMouse's own narrow clear
* (learning:01KWK8F6HFGRWS8SPPQ9MHC6GS). Clobbers A; assumes
* CRA/CRB bit2 already select PRA/PRB (MAIN_ENTRY's one-time
* bring-up sets this; this routine never re-touches CRA/CRB).
*---------------------------------------------------------------
MOUSE_SND_CMD
            sta   MOUSE_PRA
            lda   MOUSE_PRB                     ;live Port B
                                                ;value first --
                                                ;preserve every
                                                ;bit we don't
                                                ;mean to touch
            ora   #$20                          ;write-clock
                                                ;HIGH
            sta   MOUSE_PRB
            and   #$DF                          ;same value,
                                                ;write-clock LOW
            sta   MOUSE_PRB                     ;falling edge --
                                                ;controller
                                                ;latches PRA
                                                ;into its
                                                ;command buffer
                                                ;and dispatches
                                                ;it
            rts

*---------------------------------------------------------------
* MOUSE_ISR -- K_IRQ_HOOK's target. Sends M_SERV ($20) directly
* via MOUSE_SND_CMD -- see that routine's header and
* MAIN_ENTRY's bring-up comment for the full architect-ruling
* rationale (docs/SYSCALL.md #7.5): no ROM/firmware call
* anywhere in the mouse card's handling, IRQ path or boot,
* because this task found firmware's internal PIA handshake
* transiently re-enabling interrupts at BOTH call sites tried.
* mouse_card.h's on_command() (case M_SERV) sets `irq=false`
* synchronously once the command byte is latched -- no response
* byte needs reading.
*---------------------------------------------------------------
MOUSE_ISR   lda   #$20                          ;M_SERV command
                                                ;nibble
            jsr   MOUSE_SND_CMD
            inc   K_IRQCOUNT
            bne   :nowrap
            inc   K_IRQCOUNT+1
:nowrap     rts

*---------------------------------------------------------------
* STAMP_BANK1 -- copies the ffpage.s template (256 bytes
* starting at FFP_SYSC_ENT) into aux bank 1's $FF00, via
* the RAMWRT+BANKSEL bounce -- the same mechanism the real exec
* loader/spawn's argv staging will use (docs/SYSCALL.md item
* 13). Bank 1 is hardcoded here (no allocator wired up -- out of
* scope for task #3; task #5 owns the real free-list).
*---------------------------------------------------------------
* CORRECTNESS NOTE (found by testing): $FF00-$FFFF is LANGUAGE
* CARD space, not the flat $0200-$BFFF range -- it is ALTZP-
* governed (MEMMAP.md #3.4: "ALTZP selects WHICH LC's physical
* RAM is currently behind $D000-$FFFF"), NOT RAMRD/RAMWRT-
* governed. An earlier version of this routine used
* RAMWRTAUX/RAMWRTMAIN (the flat-range switches) and the stamp
* silently no-op'd -- $FF00 in bank 1 read back as zero forever
* after, because RAMWRT has no effect on the LC region at all.
* Also needs the LC write-enable double-read (same protocol as
* INSTALL_COPY) -- $FF00 falls in the LC COMMON region
* ($E000-$FFFF, shared by bank 1 and bank 2), so no bank-1/2
* select matters here, only read/write-enable.
STAMP_BANK1 lda   #1
            sta   BANKSEL
            lda   LCBANK2_RAM                    ;write-enable
                                                 ;(idempotent
            lda   LCBANK2_RAM                    ;if
                                                 ;INSTALL_COPY
                                                 ;already did
                                                 ;this --
                                                 ;defensive)
            sta   ALTZPAUX                        ;LC -> bank
                                                  ;1's own (A's
                                                  ;value
                                                  ;irrelevant to
                                                  ;the switch
                                                  ;trigger)
            ldy   #0
:cp1        lda   FFP_SYSC_ENT,y           ;Y sweeps 0..255
                                                ;then wraps
            sta   $FF00,y                       ;to 0 -- exactly
                                                ;256 bytes,
            iny                                  ;the whole
                                                 ;page, one loop
            bne   :cp1
            sta   ALTZPMAIN
            rts

*---------------------------------------------------------------
* EFP_STUB -- position-independent (page-1-relocated,
* per learning:01KW1GTYGVYAPQRGS5P7J66RWD's prescribed pattern
* -- RAMRD governs instruction fetch in $0200-$BFFF; this stub's
* OWN fetch must be immune to the RAMRD flip it performs).
* Copied to $0190 by MAIN_START's boot sequence, then JMP'd into
* (never JSR'd -- there is no "back"). Final act: JMP $0800,
* handing control to the copied fake-process code now visible at
* that address (RAMRD/RAMWRT already flipped to aux by this same
* stub, immediately before the jump).
*---------------------------------------------------------------
EFP_STUB
            sta   RAMRDAUX
            sta   RAMWRTAUX
            jmp   $0800
EFP_STUB_END
EFP_STUB_LEN equ EFP_STUB_END-EFP_STUB
STUBHOME    equ   $0190

*---------------------------------------------------------------
* FKP_SRC -- the fake process's own program, copied
* VERBATIM to bank 1's $0800 (docs/SYSCALL.md item 11's spawn-
* frame discussion covers the REAL mechanism; this test enters
* more directly -- see docs/SYSCALL.md's test-scope note).
* POSITION-INDEPENDENT BY CONSTRUCTION: no internal absolute
* self-reference (only PC-relative branches, hardcoded literal
* scratch addresses that match where the copy LANDS at $0800+,
* and externally-fixed addresses like $FF00) -- so it is correct
* wherever THIS assembly happens to place these bytes, exactly
* like ffpage.s's own template. Scratch payload lives at
* hardcoded $0900-$0907 (comfortably past this routine's own
* ~80-byte footprint once copied to $0800).
*---------------------------------------------------------------
FKP_SRC
            cli                                ;process posture:
                                               ;interruptible
            lda   #$11
            sta   $0900
            lda   #$22
            sta   $0901
            lda   #$33
            sta   $0902
            lda   #$44
            sta   $0903

            ;-- TCALL_ARITH with D=0. Right after `jsr $FF00`
            ;returns,
            ;-- A already holds the kernel's frame-A patch (the
            ;arithmetic
            ;-- result, via EXIT_TAIL's final PLA) -- expect $7E
            ;($79+$05
            ;-- binary). Stash at $0910 for TCALL_REPORT to
            ;copy in. --
            cld
            lda   #<$0000
            ldx   #>$0000
            ldy   #TC_ARITH
            jsr   $FF00
            sta   $0910

            ;-- TCALL_ARITH with D=1 SET -- proves the
            ;kernel's CLD
            ;-- (in SYSCALL_ENTRY, before ANY kernel code runs)
            ;makes the
            ;-- call's arithmetic identical regardless ($0911
            ;should ALSO
            ;-- read back $7E), AND that D=1 is restored to THIS
            ;process
            ;-- afterward ($0912's bit 3 should be SET). --
            sed
            lda   #<$0000
            ldx   #>$0000
            ldy   #TC_ARITH
            jsr   $FF00
            sta   $0911                        ;arithmetic
                                               ;result (expect
                                               ;$7E)
            php
            pla
            sta   $0912                        ;caller's P right
                                               ;after return --
                                               ;bit 3 (D) must
                                               ;be SET here
            cld                                ;done with the
                                               ;SED probe; the
                                               ;syscall loop
                                               ;below wants D=0

            ;-- syscall loop: TCALL_ECHO, many iterations,
            ;several
            ;-- seconds of simulated time so mouse VBL IRQs (60
            ;Hz) land
            ;-- inside entry/exit windows statistically. --
            lda   #<LOOPCOUNT
            sta   $0920
            lda   #>LOOPCOUNT
            sta   $0921
:loop       lda   #<$0900
            ldx   #>$0900
            ldy   #TC_ECHO
            jsr   $FF00
            lda   $0920
            bne   :dec
            dec   $0921
:dec        dec   $0920
            lda   $0920
            ora   $0921
            bne   :loop

            ;-- one TCALL_REPORT: prints SYS=/IRQ= counts +
            ;the two
            ;-- ARITH results to the screen. --
            lda   #<$0000
            ldx   #>$0000
            ldy   #TC_REPORT
            jsr   $FF00

            ;-- (f): BRK must reach the debugger trap, not the
            ;syscall
            ;-- dispatch path. --
            brk
            dfb   $00
FKP_SRC_END
FKP_SRC_LEN equ FKP_SRC_END-FKP_SRC
LOOPCOUNT   equ   20000

*---------------------------------------------------------------
* MAIN_START -- boot sequence: install copyin/copyout into main
* LC, wire the IRQ hook, bring up the mouse card's VBL
* interrupt, stamp bank 1's $FFxx page, copy the fake-process
* program into bank 1, enter it.
*---------------------------------------------------------------
* DEFENSIVE: stamp MAIN's own $FF00-$FFFF with the SAME ffpage.s
* template (found necessary by testing -- see docs/SYSCALL.md's
* "rig finding" section). If ANY interrupt is ever recognized
* while ALTZP=main (kernel processing) -- whether from a genuine
* bug or from firmware called by a handler doing its own
* internal CLI -- the CPU vectors through MAIN's $FFFE.
* docs/MEMMAP.md #1.2 specifies main's real page as "vector
* table only," built by a later task; leaving it completely
* unstamped in the meantime means that vector is whatever the LC
* happens to contain (uninitialized/ROM), and a nested interrupt
* lands in garbage. Stamping the SAME generic template here is a
* pragmatic safety net for this test, not a claim about the real
* page's final shape.
STAMP_MAIN  lda   LCBANK2_RAM
            lda   LCBANK2_RAM
            ldy   #0
:cpm        lda   FFP_SYSC_ENT,y
            sta   $FF00,y
            iny
            bne   :cpm
            rts

MAIN_ENTRY  ldy   #0                            ;boot banner --
                                                ;proves items
:banner0    lda   BANNER0,y                     ;(a)/(b) reached
                                                ;this point
            sta   $0400,y                       ;before anything
                                                ;else runs
            iny
            cpy   #BANNER0LEN
            bne   :banner0

            jsr   INSTALL_COPY
            jsr   STAMP_MAIN

            lda   #<MOUSE_ISR
            sta   K_IRQ_HOOK
            lda   #>MOUSE_ISR
            sta   K_IRQ_HOOK+1

            ;-- Bring up the mouse card entirely via DIRECT PIA
            ;register
            ;-- pokes -- NO firmware call at all, not even at
            ;boot.
            ;--
            ;-- REVISED FINDING (this round): the architect's
            ;ruling sanc-
            ;-- tioned calling InitMouse/SetMouse firmware at
            ;boot "with
            ;-- interrupts masked around the call" -- SEI
            ;already covers
            ;-- boot (never CLI'd until the fake process's own
            ;`cli`), so
            ;-- that should have been safe. Testing this round
            ;found it
            ;-- ISN'T: with the IRQ-path firmware call removed
            ;(MOUSE_ISR
            ;-- below), the FIRST hardware IRQ was STILL
            ;observed landing
            ;-- during MAIN_ENTRY's SetMouse call and corrupting
            ;boot's own
            ;-- stack (single-instruction-stepped: IRQ_ENTRY ->
            ;KERNEL_
            ;-- IRQ_ENTRY -> misrouted to KRN_BRK_TRAP within
            ;~150
            ;-- cycles of entering the fake process, before it
            ;could have
            ;-- run any real iterations) -- consistent with
            ;SetMouse's own
            ;-- internal PIA handshake ALSO transiently CLI-ing,
            ;the same
            ;-- root cause as #7.5, just at a different call
            ;site: MAIN_
            ;-- ENTRY's boot-time stack shares the SAME fixed
            ;$FF value
            ;-- KRN_IRQ_ENTRY resets to, so a nested entry
            ;mid-SetMouse
            ;-- collides with boot's own in-flight JSR return
            ;addresses
            ;-- exactly like #7.5 described for ServeMouse mid-
            ;IRQ-service.
            ;--
            ;-- The architect's ruling explicitly leaves init's
            ;mechanism
            ;-- to this task's judgment ("firmware... or direct
            ;register
            ;-- setup -- your call, documented"). Given
            ;firmware's internal
            ;-- CLI behavior isn't under this kernel's control
            ;at ANY call
            ;-- site (not just the IRQ path), direct register
            ;setup is the
            ;-- only choice that doesn't depend on auditing ROM
            ;internals
            ;-- this task can't verify -- so it's used here too,
            ;not just
            ;-- in MOUSE_ISR. See docs/SYSCALL.md #7.5 for the
            ;full account.
            ;--
            ;-- PIA bring-up (register model per mouse_card.h,
            ;read
            ;-- directly for this fix): DDRA=$FF (all output --
            ;write()
            ;-- doesn't actually gate on DDRA in this model, set
            ;for
            ;-- correctness anyway), DDRB=$30 (bits 4-5, the
            ;read/write
            ;-- clocks, as outputs -- the only bits this kernel
            ;drives; ROM-
            ;-- bank-select bits 1-3 are left as inputs since
            ;this kernel
            ;-- never re-banks the ROM), then CRA/CRB=$04
            ;(bit2=1) selects
            ;-- PRA/PRB for ALL subsequent register-0/2
            ;accesses, INCLUDING
            ;-- MOUSE_ISR's later ones -- this is a one-time
            ;mode switch,
            ;-- not re-armed per interrupt. --
            lda   #$FF
            sta   MOUSE_PRA                    ;CRA bit2=0 still
                                               ;(post-reset
                                               ;default) -- this
                                               ;hits DDRA
            lda   #$30
            sta   MOUSE_PRB                    ;CRB bit2=0 still
                                               ;-- hits DDRB
            lda   #$04
            sta   MOUSE_CRA                    ;NOW select PRA
                                               ;(bit2=1)
            sta   MOUSE_CRB                    ;NOW select PRB
                                               ;(bit2=1)
            lda   #$09                         ;M_SET command,
                                               ;mode=$09 (on +
                                               ;VBL interrupt
                                               ;enable -- same
                                               ;mode byte
                                               ;SetMouse used)
            jsr   MOUSE_SND_CMD

            jsr   STAMP_BANK1

            ;-- copy the fake-process program into bank 1 at
            ;$0800 (the
            ;-- same RAMWRT+BANKSEL bounce as STAMP_BANK1, main-
            ;side, no
            ;-- RAMRD hazard since we're not flipping RAMRD here
            ;-- only
            ;-- RAMWRT, and only WRITES are affected by RAMWRT).
            ;--
            lda   #1
            sta   BANKSEL
            sta   RAMWRTAUX
            ldy   #0
:cpf        lda   FKP_SRC,y
            sta   $0800,y
            iny
            cpy   #FKP_SRC_LEN
            bne   :cpf
            sta   RAMWRTMAIN

            ;-- Enter bank 1: BANKSEL already =1 from above.
            ;Flip ALTZP to
            ;-- aux FIRST -- BEFORE relocating the stub -- so
            ;the
            ;-- relocation copy below writes to BANK 1's OWN
            ;page 1 (where
            ;-- the eventual `jmp STUBHOME` will actually fetch
            ;from, since
            ;-- that JMP also executes with ALTZP=aux). Doing
            ;the copy
            ;-- before this flip was a real bug caught by
            ;testing: it wrote
            ;-- the stub into MAIN's page 1 instead, leaving
            ;bank 1's own
            ;-- $0190 as uninitialized garbage for the later JMP
            ;to crash
            ;-- into. Fresh SP right after the flip, no pushes
            ;before it or
            ;-- between it and the final JMP -- same "no pushes"
            ;discipline
            ;-- as the exit-critical-section argument in
            ;docs/SYSCALL.md
            ;-- (page 1 is ALTZP-governed for BOTH data and
            ;instruction
            ;-- fetch, so the relocation copy and the stub's own
            ;execution
            ;-- are both immune to RAMRD, matching
            ;-- learning:01KW1GTYGVYAPQRGS5P7J66RWD's "safe
            ;regions" list).
            sta   ALTZPAUX
            ldx   #$FF
            txs
            ldy   #EFP_STUB_LEN-1
:cps        lda   EFP_STUB,y
            sta   STUBHOME,y
            dey
            bpl   :cps
            jmp   STUBHOME

            ds    $0800+4096-*                  ;pad the whole
                                                ;image to a
                                                ;fixed 4096
                                                ;bytes (8
                                                ;blocks) --
                                                ;NBLOCKS above
                                                ;must match
