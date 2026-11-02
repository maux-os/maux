*---------------------------------------------------------------
* bankprobe.s -- boot-time RamWorks bank probe + free-list
* allocator.
* Full design notes: K.BANKPROBE.TXT (docs/a2/)
*---------------------------------------------------------------


PROBEADDR   equ   $9000     ;signature byte address -- inside
                            ;$6000-$BFFF, clear of video
                            ;apertures ($0400-$0BFF text/ lores,
                            ;$2000-$5FFF HIRES/DHIRES) on every
                            ;bank, so no 80STORE bracket is
                            ;needed (see header note)
PROBEMAX    equ   128       ;bank numbers probed: $00-$7F (task
                            ;contract: "probe all 128 bank
                            ;numbers")
RESERVED0   equ   0         ;bank 0 is always reserved (kernel
                            ;annex/video owner per
                            ;ARCHITECTURE.md's "Memory
                            ;ownership" table) -- never placed
                            ;on the free list

AUXRD       equ   $0180     ;page-1 destination for the
                            ;relocated aux-read stub (ALTZP-
                            ;governed, RAMRD-immune to itself;
                            ;see header note). Low end of page
                            ;1, far below this module's shallow
                            ;(<=2-deep) JSR nesting.

*---------------------------------------------------------------
* Free-list output (deliverable: "free-list + count in a fixed
* table"). Fixed-size, no dynamic allocation -- worst case is
* 127 entries (128 bank numbers minus the mandatory bank-0
* reservation). See the reconcile note above for why these stay
* module-local $9xxx addresses rather than a memmap.equ symbol
* (K_BNKTBL_SIZE covers the BUDGET, not a placement).
*
* These are RUNTIME-ONLY main-memory locations, like AUXRD above
* -- NOT reserved inline in the code stream with `ds`. A single-
* block SmartPort boot (src/test/probetest.s, cribbing
* src/bootblock.s) loads exactly 512 bytes to $0800; a 128-byte-
* plus table declared inline would blow past that budget and
* this module has no multi-block loader (out of scope -- the
* free list is kernel bookkeeping, not boot-image payload, so it
* belongs in plain unloaded RAM anyway; BankProbe zeroes
* FREECOUNT itself on entry, and FREELIST entries beyond
* FREECOUNT are never read, so nothing needs to be pre-loaded
* from disk). Placed in the same $9xxx safe zone as PROBEADDR
* (outside both video holes, no 80STORE dependency), immediately
* after it and clear of its one byte.
*---------------------------------------------------------------

*---------------------------------------------------------------
* BankProbe -- entry point. No arguments. Clobbers A/X/Y. On
* return, FREECOUNT/FREELIST hold the result. Must be called
* with ALTZP off (this module never touches ALTZP and assumes
* zero page + page 1 are MAIN, matching every boot image in this
* tree so far).
*
*---------------------------------------------------------------
* RDAUX_SRC -- position-independent source for the relocated
* aux-read stub (see header note; pattern confirmed in
* production by ~/src/malisp/src/bank.s's RDAUX_SRC). Copied to
* AUXRD ($0180) once by BankProbe before probing starts, then
* JSR'd from there on every readback so the RAMRD flip never
* redirects this module's OWN instruction fetch.
*---------------------------------------------------------------
RDAUX_SRC   sta   RAMRDAUX    ;A's value is irrelevant -- these
                              ;switches
            lda   PROBEADDR   ;trigger on address, not data
            sta   RAMRDMAIN
            rts
RDAUX_SRC_END
RDAUX_LEN   equ   RDAUX_SRC_END-RDAUX_SRC
*-- (Moved ABOVE BankProbe 2026-08-29, S9 EQU burn-down:
*-- RDAUX_LEN was used in BankProbe's immediate before this
*-- definition, which real Merlin-8 refuses. The module's first
*-- bytes are now this template -- safe, its one includer
*-- (probetest.s) reaches BankProbe by name and the text before
*-- its `put` ends in data after an rts, never a fall-through.)

* TWO EXPLICIT PHASES -- see the header's CORRECTNESS NOTE for
* why a single combined write+immediate-read loop (an earlier,
* buggy version of this routine) does NOT dedupe aliases: it
* reads bank A back before bank B ever gets a chance to clobber
* the shared cell, so both pass. Phase 1 below writes every one
* of the 128 signatures, in ascending order, with NO reads at
* all; only once phase 1 is completely finished does phase 2
* begin reading them back. That gap between "last write" and
* "first read" is what makes the alias argument in the header
* true of this code, not just of the prose describing it.
*---------------------------------------------------------------
BankProbe   ldy   #RDAUX_LEN-1
:relocate   lda   RDAUX_SRC,y     ;copy the position-independent
                                  ;read stub
            sta   AUXRD,y         ;to its safe page-1 home, once
            dey
            bpl   :relocate

            ;-- PHASE 1: write every signature, ascending N, no
            ;reads. --
            ldx   #0              ;X = bank number under test,
                                  ;0..127
:write      txa
            sta   BANKSEL         ;select bank X -- I/O write,
                                  ;safe from anywhere; per learn
                                  ;ing:01KYYPR1CB9H9JK88W5QF56QW
                                  ;Q this is the ONLY $C07x
                                  ;address touched
            sta   RAMWRTAUX       ;A is still X here (STA
                                  ;doesn't affect A)
            sta   PROBEADDR       ;write the bank number as its
                                  ;own signature
            sta   RAMWRTMAIN
            inx
            cpx   #PROBEMAX
            bne   :write          ;phase 1 complete: every live
                                  ;bank's PROBEADDR now holds
                                  ;its highest alias member's
                                  ;number (see header)

            ;-- PHASE 2: read every signature back, ascending N,
            ;no writes.
            ;-- (Ascending order isn't load-bearing here the way
            ;it is in
            ;-- phase 1 -- the shared cell's content is already
            ;fixed by
            ;-- the time phase 2 starts -- but matching phase
            ;1's order
            ;-- keeps the free list in ascending bank-number
            ;order, which
            ;-- probetest.s's display and the header's argument
            ;both
            ;-- assume.) --
            lda   #0
            sta   FREECOUNT
            ldx   #0
:read       txa
            sta   BANKSEL         ;re-select bank X -- $C073 is
                                  ;write-only and UNKNOWN at
                                  ;every entry
                                  ;(ARCHITECTURE.md); phase 1's
                                  ;last write moved it, so this
                                  ;is not redundant
            jsr   AUXRD           ;A = signature read back (via
                                  ;safe stub)
            stx   BANKTMP         ;BANKTMP = expected value (=
                                  ;X)
            cmp   BANKTMP
            bne   :next           ;mismatch -> alias-clobbered
                                  ;or unpopulated
            cpx   #RESERVED0
            beq   :next           ;bank 0 always reserved, never
                                  ;free-listed
            ldy   FREECOUNT
            txa
            sta   FREELIST,y
            inc   FREECOUNT
:next       inx
            cpx   #PROBEMAX
            bne   :read
            rts

BANKTMP     equ   $9180     ;scratch: expected signature during
                            ;self-check (runtime-only, same
                            ;rationale as FREELIST above; $9180
                            ;= one past FREELIST's last possible
                            ;byte, $9101+126=$917F, so no
                            ;overlap)

