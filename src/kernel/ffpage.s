*---------------------------------------------------------------
* ffpage.s -- the $FFxx kernel page TEMPLATE (task #3,
* docs/MEMMAP.md #3.3, docs/SYSCALL.md).
* Full design notes: K.FFPAGE.TXT (docs/a2/)
*---------------------------------------------------------------

FFP_SYSC_ENT
            php                              ;1  caller P FIRST
                                             ;(incl. D) --
                                             ;before anything
                                             ;else touches
                                             ;flags; matches the
                                             ;trapframe
                                             ;contract's "PHP
                                             ;first" rule
            sei                               ;1  mask IRQ for
                                              ;the rest of the
                                              ;syscall (no re-
                                              ;entrant nesting
                                              ;past this point)
            cld                               ;1  kernel
                                              ;arithmetic is
                                              ;always binary
                                              ;regardless of
                                              ;caller's D
            pha                               ;1  save A
                                              ;(frame-A: parms
                                              ;ptr lo, per the
                                              ;register-
                                              ;transport ruling,
                                              ;docs/SYSCALL.md
                                              ;item 1)
            txa                               ;1
            pha                               ;1  save X
                                              ;(frame-X: parms
                                              ;ptr hi)
            tya                               ;1
            pha                               ;1  save Y
                                              ;(frame-Y: call
                                              ;number)
            sta   RAMRDMAIN                   ;3  RAMRD -> main
                                              ;(A irrelevant --
                                              ;softswitch
                                              ;triggers on
                                              ;address)
            sta   RAMWRTMAIN                  ;3  RAMWRT -> main
            jmp   KRN_ENTRY                ;3  -> main-side
                                              ;syscall dispatch
                                              ;-- 17 bytes of
                                              ;real code; pad to
                                              ;the full 20-byte
                                              ;budget so --
                                              ;IRQ_ENTRY lands
                                              ;exactly at $FF14
                                              ;regardless of
                                              ;future edits --
                                              ;here (same `ds
                                              ;SECTION+BUDGET-*`
                                              ;idiom as
                                              ;bootblock.s).
            ds    FFP_SYSC_ENT+20-*

*===== IRQ_ENTRY -- $FF14, 14-byte budget =====*
FFP_IRQ_ENTRY
            ;-- Hardware already pushed PCH/PCL/P and set I as
            ;part of taking
            ;-- the interrupt (or executing BRK -- same vector,
            ;same push
            ;-- shape, B flag differs); 65C02 auto-clears D. No
            ;PHP/SEI/CLD.
            pha                               ;1  frame-A: parms
                                              ;ptr lo (stale/
                                              ;irrelevant for a
                                              ;real async IRQ,
                                              ;but the frame
                                              ;shape must stay
                                              ;uniform for
                                              ;EXIT_TAIL)
            txa                               ;1
            pha                               ;1  frame-X: parms
                                              ;ptr hi
            tya                               ;1
            pha                               ;1  frame-Y: call
                                              ;number (ditto)
            sta   RAMRDMAIN                   ;3
            sta   RAMWRTMAIN                  ;3
            jmp   KRN_IRQ_ENTRY            ;3  -> main-side
                                              ;IRQ/BRK entry --
                                              ;14 bytes exactly
                                              ;-- pad is a no-op
                                              ;but kept for
                                              ;consistency --
                                              ;and as a tripwire
                                              ;if this section
                                              ;ever grows.
            ds    FFP_IRQ_ENTRY+14-*

* ===== EXIT_TAIL -- $FF22, 12-byte budget =====* Shared unwind
* for BOTH doors -- valid because SYSCALL_ENTRY and IRQ_ENTRY
* produce byte-identical frame shapes (see header). Also the
* target of a SPAWNED process's very first "return":
* docs/SYSCALL.md's process-entry ruling (item 11) has spawn()
* synthesize a fake frame at the top of a fresh process's stack
* so this SAME tail launches a brand new process with zero
* special-casing.
FFP_EXIT_TAIL
            sta   RAMRDAUX                    ;3  RAMRD -> aux:
                                              ;process code
                                              ;resumes in ITS
                                              ;OWN memory
            sta   RAMWRTAUX                   ;3  RAMWRT -> aux
            pla                                ;1
            tay                                ;1  restore Y
                                               ;(call number
                                               ;slot)
            pla                                ;1
            tax                                ;1  restore X
                                               ;(parms ptr hi
                                               ;slot)
            pla                                ;1  restore A
                                               ;(parms ptr lo
                                               ;slot,
                                               ;overwritten with
                                               ;the syscall's
                                               ;RETURN VALUE by
                                               ;the kernel's
                                               ;frame patch
                                               ;before this ran
                                               ;-- see src/kerne
                                               ;l/entry.s)
            rti                                ;1  pulls P
                                               ;(carry patched
                                               ;by the kernel =
                                               ;success/failure;
                                               ;every OTHER
                                               ;flag, incl. D,
                                               ;is the caller's
                                               ;own, untouched
                                               ;since its
                                               ;PHP/the hardware
                                               ;push) then
                                               ;PCL/PCH --
                                               ;resumes the
                                               ;caller
            ds    FFP_EXIT_TAIL+12-*

* ===== BANK_ID -- $FF2E, 1 byte =====* Per-bank self-identity
* (docs/MEMMAP.md #3.3): $C073 is write-only, so each bank must
* keep its own number somewhere IT can read. Stamped with the
* real value at bank-creation time; the template ships a
* placeholder.
FFP_BANK_ID ds    1

* ===== FFXX_SCRATCH -- $FF2F, 5 bytes =====* Reserved
* (docs/MEMMAP.md: "future use -- e.g. a saved-SP slot"). Left
* genuinely unused by task #3 -- not borrowed for test-harness
* purposes, so a future task's real use of these 5 bytes never
* has to un-teach a test-only convention.
FFP_SCRATCH ds    5

* ===== NMI_TRAP -- $FF34, 2 bytes =====* NMI is ruled out
* architecture-wide as a timer source (ARCHITECTURE.md,
* HACKING.md: "the NMI vector parks (BRA *) per MEMMAP -- do not
* get creative with NMI"). Parks for debugger visibility instead
* of silently corrupting state -- same DoS class as the already-
* conceded SEI-forever hazard, but at least inspectable via the
* emulator's `regs`/`peek`.
FFP_NMI_TRAP
            bra   *                           ;2  (65C02 BRA,
                                              ;opcode $80 + a -2
                                              ;relative offset
                                              ;-- parks)
            ds    FFP_NMI_TRAP+2-*

* ===== RESET_STUB -- $FF36, 6 bytes =====* Defensive-only
* (docs/MEMMAP.md): guards a hardware RESET landing here
* directly with this bank's LC still mapped. NOT the real
* recovery path (that's main's $03F2 intercept,
* docs/ARCHITECTURE.md/MEMMAP.md #1.1).
FFP_RST_STUB
            sei                                ;1
            lda   #0                            ;2
            sta   BANKSEL                       ;3  reassert
                                                ;bank 0 (the AE-
                                                ;manual-
                                                ;documented
                                                ;$C073-reset-
                                                ;persistence
                                                ;intercept
                                                ;pattern)
            ds    FFP_RST_STUB+6-*

* ===== slack -- fills to offset 250 (the hardware vector table
* starts at offset 250, i.e. $FF00+250 = $FFFA) =====* Budget
* check (docs/MEMMAP.md #3.3): 20+14+12+1+5+2+6 = 60 stub bytes
* + 190 slack = 250 usable + 6 hardware-vector bytes = 256 = the
* whole page.
            ds    FFP_SYSC_ENT+250-*

* ===== hardware vectors -- offset 250-255 ($FFFA-$FFFF), 6
* bytes, hardware-fixed. TARGET-RELATIVE LITERALS, not `da
* LABEL` -- see the header's "VECTOR TABLE IS NOT `da LABEL`"
* note for why. Each *_OFF below is a page-relative offset (a
* label subtraction -- independent of this file's actual
* assembly-time base address); adding it to the literal $FF00
* target gives the correct final vector value in BOTH contexts
* this file is assembled in. =====*
NMI_TRAP_OFF    equ   FFP_NMI_TRAP-FFP_SYSC_ENT
RESET_STB_OFF  equ   FFP_RST_STUB-FFP_SYSC_ENT
IRQ_ENTRY_OFF   equ   FFP_IRQ_ENTRY-FFP_SYSC_ENT

NMI_TRAP_ADDR   equ   $FF00+NMI_TRAP_OFF
RST_STB_ADDR equ   $FF00+RESET_STB_OFF
IRQ_ENT_ADDR  equ   $FF00+IRQ_ENTRY_OFF

            dfb   <NMI_TRAP_ADDR              ;$FFFA NMI vector
                                              ;lo
            dfb   >NMI_TRAP_ADDR              ;$FFFB NMI vector
                                              ;hi
            dfb   <RST_STB_ADDR            ;$FFFC RESET
                                              ;vector lo
            dfb   >RST_STB_ADDR            ;$FFFD RESET
                                              ;vector hi
            dfb   <IRQ_ENT_ADDR             ;$FFFE IRQ/BRK
                                              ;vector lo
            dfb   >IRQ_ENT_ADDR             ;$FFFF IRQ/BRK
                                              ;vector hi
