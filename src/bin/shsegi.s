*---------------------------------------------------------------
* shsegi.s -- SEG_INIT, the one LOW-resident routine the second
* code segment needs: it installs the segment into the process
* language card's COMMON region ($E000-$FEFF, PRC_LC_COMMON --
* inc/mm.procbnk2.equ) before anything can call into
* it.  `put` by src/bin/sh.s immediately BEFORE that manifest's
* `org PRC_LC_COMMON` block, so the three labels it reads
* (SH_SEG_LOW / SH_SEG_BEG / SH_SEG_END) are ordinary forward
* label references -- never `equ` forward references, which
* real Merlin-8 refuses (learning:01M05519PC55WGJNE4PY5HX4TH).
* docs/SH-SUBSET.md ruling 7.6 is the design; this is the code.
*
* THE SOURCE.  merlin32 emits a mid-file `org` block
* CONTIGUOUSLY into the flat binary (measured 2026-09-16: a
* two-org file with `jsr FAR` encodes $E000 and the output
* stays 9 bytes), so the segment's bytes are simply the tail of
* sh.bin and the spawn loader's ONE copy lands them at
* SH_SEG_LOW -- immediately above the low image.  sh.s puts the
* bss arena back ABOVE that low copy (its third `org`), so
* nothing the shell ever writes overwrites it and this copy is
* correct on a COLD spawn and on a WARM respawn alike.  That is
* the whole reason the low copy is not simply overlaid by bss:
* a warm respawn re-enters at LOAD_BASE with NO reload, and a
* process cannot learn LZ_WARM -- it is kernel-private state
* (src/kernel/lazyfree.s), exposed by no syscall.
*
* THE BRACKET, and the bug it used to carry.  `lda
* LCBANK2_RAM` twice is the house write-enable idiom
* (src/kernel/mli.s, src/bin/excmd.s EX_SNAPSHOT,
* src/bin/mld.s).  ALTZP already points the LC at the
* process's own bank (learning:01KW1GTYGVYAPQRGS5P7J66RWD),
* so this writes the PROCESS's language card, not main's, and
* bank 1 vs bank 2 IS irrelevant above $E000 -- the LC's two
* banks alias $D000-$DFFF only.
*
* What that reasoning missed, for four days, is that the
* BANK is not the only global here.  WRITE-ENABLE is one
* latch for the whole machine too.  This copy is 4 KB, about
* 70,000 cycles; it is preempted; and when liba stdio closed
* its own LC bracket in another process with a write-PROTECT,
* every remaining store here was dropped by the hardware
* WITHOUT A FAULT -- this machine has no memory protection to
* fault with.  The tail of the segment never arrived, the
* shell's first `jsr` into it landed on $00 $00, and the
* kernel's BRK trap parked the machine with interrupts
* masked.  Measured 2026-09-20: the copy stalled at $ECD1 and
* resumed at $ECD2, and everything from there to $EFFF --
* SB_T0CAP at $ED39 included -- went nowhere.
*
* The fix is not here.  Nothing in this routine can defend
* against it, because the state it needs cannot be read back
* and so cannot be checked.  Write-enable is now the
* machine-wide steady state and nothing in the tree protects:
* docs/LANGUAGE-CARD.md, gate check-lc.
*
* WHOLE PAGES.  The copy is page-granular: the destination is
* page-aligned by construction ($E000) and reading a few bytes
* past the low copy costs nothing (the bytes above it are the
* uninitialised bss arena).  That buys a 2-byte page compare
* instead of a 16-bit length, and needs no `<`/`>` prefix on a
* multi-term expression -- merlin32 has no operator precedence
* and no parentheses (learning:01M051DJW89KV4JYM1EC9SDZ5Y), so
* `#>SH_SEG_END` standing alone is the unambiguous spelling.
* A WARM respawn (SEGSTAMP = SEG_MAGIC) skips the copy entirely:
* the language card keeps the segments, and the low copy they
* came from may already be overwritten.
* CLOBBERS: A, X, Y, PTR1, PTR2.  Called once, from START.
*---------------------------------------------------------------
SEG_INIT    lda   SEGSTAMP           ;warm respawn: the card
            cmp   #SEG_MAGIC         ;still holds both
            beq   :warm              ;segments (see below)
            lda   LCBANK2_RAM        ;write-enable process LC
            lda   LCBANK2_RAM        ;(double read -- house
                                     ;idiom)
            lda   #<SH_SEG_LOW
            sta   PTR1
            lda   #>SH_SEG_LOW
            sta   PTR1+1
            stz   PTR2               ;$E000 -- page-aligned, so
            lda   #>PRC_LC_COMMON    ;the low byte is 0
            sta   PTR2+1
            ldx   #>SH_SEG_END
            jsr   :copy
            lda   #<SH_SEG2_SRC      ;the $D000 segment: its
            sta   PTR1               ;bytes follow the first's
            lda   #>SH_SEG2_SRC      ;in the file; PTR2 is still
            sta   PTR1+1             ;on a page boundary
            lda   #>PRC_LC_BANK2
            sta   PTR2+1
            ldx   #>SH_SEG2_END
            jsr   :copy
*-- NO re-protect, and this is the routine that proved why:
*-- holding write-enable across this copy lost the tail
*-- of it whenever another process closed its own LC bracket
*-- in between. docs/LANGUAGE-CARD.md.
*-- The stamp is the LAST thing, after BOTH copies: a sh killed
*-- between them must not leave a stamped, half-copied bank
*-- (KFIX3 review B2).
            lda   #SEG_MAGIC
            sta   SEGSTAMP
:warm       rts
:copy       ldy   #0
:byte       lda   (PTR1),y
            sta   (PTR2),y
            iny
            bne   :byte
            inc   PTR1+1
            inc   PTR2+1
            cpx   PTR2+1             ;copy the page CONTAINING
            bcs   :copy              ;the end too -- one spare
                                     ;page, never short
            rts
*-- SEGSTAMP -- one EMITTED byte of the low image, which is the
*-- whole mechanism (KFIX3 item 0). A cold spawn loads the file,
*-- so it arrives 0; a warm respawn reloads nothing, so it still
*-- holds SEG_MAGIC from the run that copied the segments, and
*-- the process language card (retained with the bank) still
*-- holds them. Nothing else can make a COLD spawn read
*-- SEG_MAGIC: the loader has just rewritten the whole low
*-- image. This is what lets the bss arena's two biggest tables
*-- sit in the tails' low copies (sh.s, "TRAPTAB and
*-- CSFORWORDS"): on a warm respawn the copies are no longer
*-- read, so they are free.
SEGSTAMP    ds    1
