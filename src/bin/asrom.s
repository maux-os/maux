*---------------------------------------------------------------
* asrom.s -- `as`'s P6 ROM-compat stubs (docs/AS-DESIGN.md P6),
* assembled STANDALONE at their REAL target addresses ($FCA8-
* $FDFF). as.s cannot ORG there itself -- a single flat `dsk`
* image loaded at $0800 cannot also cover $FCA8 (the loader
* copies bytes starting at $0800 only; an ORG jump that far
* would just mean ~62KB of padding, not a second load site). So
* this file is built separately (as-stubs.bin) and as.s embeds
* it via `putbin`, copying the bytes verbatim to $FCA8 at
* startup -- every address here is already correct once landed,
* no relocation needed.
*
* Preserves X/Y across every entry (the real ROM COUT/PRBYTE/
* CROUT contract the assembler's print loops rely on) and uses
* NO zero page -- the core owns all of $00-$FF; a stub scratch
* byte there would corrupt assembler state mid-run. PRBYTE/
* PRHEX/COUT are laid out to fall through into each other byte-
* exactly (the real Apple II ROM's own trick), which is WHY
* PRBYTE ($FDDA) is only 9 bytes from PRHEX ($FDE3) -- see the
* per-routine comments below.
*---------------------------------------------------------------
            lst   off
            xc
            org   $FCA8
            dsk   ../../build/as-stubs.bin
            typ   $00

* as.s's own char-output helper. Fixed at $08A0 -- the first
* byte past as.s's own $800-$89F exclusion zone (MACASS.S's
* macro-state DUM block sits AT LOAD_BASE and gets zeroed by
* ASM's own entry; see as.s's header) -- so this file can JSR
* it without seeing as.s's source.
AS_PUTCH    equ   $08A0

* `ds` targets below are LITERAL addresses, not label refs --
* merlin32 cannot evaluate a forward label in a `ds` expression
* (real Merlin's own `DS $F7D0-*` idiom, patches.py's ASEXIT
* pad, uses a literal too, for the same reason).
MONWAIT     rts
            ds    $FD6F-*
* GETLN2 -- interactive KBD directive only (v1 `as` has none):
* report an empty line, never park on real hardware.
GETLN2      ldx   #0
            rts
            ds    $FD8E-*
CROUT       lda   #$8D
            jmp   COUT
            ds    $FDDA-*
* PRBYTE -- prints A as 2 hex digits. High nibble via JSR PRHEX,
* then PLA + fall through into PRHEX's own body for the low
* nibble (the real ROM's own density trick -- must be EXACTLY 9
* bytes to land PRHEX at its fixed $FDE3).
PRBYTE      pha
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            jsr   PRHEX
            pla
* PRHEX -- prints the low nibble of A as one hex digit, then
* falls through into COUT (no jump -- must be exactly 10 bytes
* to land COUT at its fixed $FDED).
PRHEX       and   #$0F
            ora   #$30
            cmp   #$3A
            bcc   COUT
            adc   #6
* COUT -- the mandatory stub: char in A, write it via as.s's
* AS_PUTCH (which gates on -l and calls liba's PUTC).
COUT        phx
            phy
            jsr   AS_PUTCH
            ply
            plx
            rts

* SENDMSG_IMPL -- replaces $E033 (poked in by as.s, see that
* file's SENDMSG_STUB note). NOT a bare RTS: SENDMSG is an
* INLINE-STRING call, the same idiom as the real ROM's COUT/
* string routines -- every embedded-chain caller (ASS.BNK1.S,
* GETLINE.S, SYMPRINT.S, PRINTENT.S) does `JSR SENDMSG` followed
* IMMEDIATELY by a NUL-terminated, high-bit-set ASC/HEX/DFB
* literal, e.g. GETLINE.S:121 `DONE JSR SENDMSG / HEX A08DA08D /
* ASC "--End assembly, "00`. A bare-RTS stub returns to the
* FIRST BYTE OF THAT STRING and the CPU executes it as code --
* this is what the $E033/$E035 BRK and the later $F5D5 BRK both
* were: $F5D5 is literally the NUL terminator of DONE's own
* "--End assembly, " string (byte-verified against
* build/ascore-as.obj: PRDEC/ERCOUNT/DUPCNT/PRDEC+2 pattern at
* $F5B5-$F5BD identifies BYTPRN's tail immediately before it,
* and the 16-char string "--End assembly, " plus its NUL lands
* EXACTLY on $F5C5-$F5D5). So this is the SAME bug surfacing
* twice, not two different bugs -- the P6 recon's "meaningless
* display side effect" reasoning for the bare-RTS stub was
* wrong about SENDMSG's calling convention, not just incomplete.
*
* This routine prints the inline string (via COUT, so it also
* respects -l through AS_PUTCH) then patches the return address
* on the hardware stack to land just past the string's NUL, so
* the final RTS resumes real code -- exactly what the real
* MACED.S SENDMSG's TXTP-driven printing achieves, minus the
* tab/cursor machinery a headless front end has no use for
* (same "correct, not merely expedient" reasoning P6 already
* uses for MONWAIT/GETLN2). Uses NO zero page (self-modified
* operand bytes only, matching this whole file's own header
* discipline) -- the core owns $00-$FF and PTR0/liba's own
* $E0-$E1 collides with the assembler's own STARTFL/WASORG.
SENDMSG_IMPL
* -- Y IS PRESERVED (2026-08-20). Merlin's FIXEXT calls SENDMSG
* -- with an inline string and then IMMEDIATELY does `TYA / STA
* -- (DICPNT),Y` to mark the end of the dictionary -- so it
* -- depends on Y across the call, as both the written VALUE and
* -- the index. This stub's string walk clobbered Y, which wrote
* -- a garbage marker at a garbage offset; the external-symbol
* -- walk then never matched, FIXCODE never ran, and unresolved
* -- placeholder bytes reached the linked output. Third instance
* -- in this project of a stub clobbering a register its caller
* -- relied on (the ROM's $45 stomp, NMGETC's Y, this): a stub
* -- standing in for firmware must preserve what the original
* -- preserved, not merely do the original's visible work.
            pla                     ;low byte of (JSR ret - 1)
            sta   :fetch+1
            pla                     ;high byte
            sta   :fetch+2
            phy                     ;save AFTER the pulls: the
                                    ;JSR return address is on
                                    ;top until here, so saving
                                    ;earlier would make the
                                    ;pulls read Y instead
            ldy   #1                ;string starts at (pulled+1)
:loop
:fetch      lda   $FFFF,y           ;self-modified base address
            beq   :done
            jsr   COUT
            iny
            bne   :loop
            inc   :fetch+2
            bra   :loop
:done                     ;Y = offset of the NUL byte from
                          ;the pulled base; resume at
                          ;(base+Y+1) -- RTS adds 1, so
                          ;push (base+Y).
            tya
            clc
            adc   :fetch+1
            tax                     ;X = new low byte
            lda   :fetch+2
            adc   #0                ;carry into high byte
            ply                     ;Y restored here, not
                                    ;earlier: the tya/adc above
                                    ;still needed the NUL
                                    ;offset. PLY touches N/Z
                                    ;only, never A or carry.
            pha                     ;push HIGH first (RTS order)
            txa
            pha                     ;push LOW second
            rts
