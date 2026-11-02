*---------------------------------------------------------------
* bankcopy.s -- the bank-clone / exec-loader copy core (task #4,
* docs/TASKS.md #4; docs/ARCHITECTURE.md "fork() [v2]" and
* "exec()").
* Full design notes: K.BANKCOPY.TXT (docs/a2/)
*---------------------------------------------------------------


* -- error codes -- SAME numbering as entry.s's K_CPY_ERR, see
* REFUSAL -- CODES above. --
BC_ERR_OK        equ   0
BC_ERR_FORBID equ   1
BC_ERR_NOWIRE  equ   2

* -- bytes per $C073-selection window -- see CYCLE ESTIMATE
* above for -- why 128 (half of K_CPY_LEN's 255-byte ceiling and
* K_BOUNCEBUF's -- 256-byte size, chosen for the VBL-latency
* bound, not for either of -- those ceilings). --
* -- docs/PROCIO.md 2026-08-20: measured bank-to-bank BankCopy
* -- at ~39 cyc/B, 2x the ~20 doc'd single-window rate -- BOTH
* -- windows run (one $C073 selection live at a time), inherent,
* -- not chunk-size-fixable. Chunk size only taxes the FIXED
* -- per-chunk setup (php/sei/BANKSEL/plp, paid 2x/chunk).
* -- Raised 128->254 (not 255: K_CPY_LEN is ONE zp byte, 0
* -- there means "empty" per CPILC_SRC's `beq :emptyok`, and
* -- BC_LOOP's own `cmp #BC_CHUNK+1` needs that +1 to fit a
* -- byte too -- 255 wraps to 0 both ways, silently mis-
* -- copying) -- halves $C073-selection windows, ~1.6% off
* -- BankCopy's own time (measured, not the ~3-4% first
* -- guessed -- real per-window fixed overhead is smaller).
* -- Worst-case SEI-masked span per window: ~128->254B, ~2.3ms->
* -- ~4.5ms @1MHz -- still well under the 60Hz (16.7ms VBL)
* -- VBL period, and IRQs are re-enabled between windows/chunks
* -- (SEI/CLI brackets one window, not the whole call), so ^C/
* -- tick response during a big warm-spawn copy stays sub-10ms.
BC_CHUNK         equ   254

* -- docs/STICKY.md sec 21: the one region the system zeroes.
* -- 256, not 16: the cost is already noise and a round region
* -- absorbs growth. The fill loop below is unrolled EIGHT deep
* -- and uses Y's own 0->255 wrap as its terminator, so the
* -- constant is not free to change -- it is 256 by
* -- construction, and this equ exists to be NAMED (by the
* -- gate, by the docs), not to be tuned.
BC_ZPG_LEN       equ   256

* -- caller-set parameters + BankCopy's own working state.
* Ordinary main -- memory (`ds`, assembler-placed -- same idiom
* as entry.s's cross-flip -- cells), NOT zero page: BankCopy
* itself never flips RAMRD/RAMWRT/ -- ALTZP (only
* COPYIN_ENTRY/COPYOUT_ENTRY do, internally, already --
* correct), so none of this state needs the ALTZP-immunity zero
* page -- buys -- only K_CPY_PROC/K_CPY_MAIN (entry.s's own
* cells, used for -- (zp),y indirect addressing) genuinely
* require zero page, and this -- file reuses those rather than
* declaring its own. --
K_BC_SRCKIND  ds    1        ;BC_KIND_MAIN or BC_KIND_BANK
K_BC_SRCADDR  ds    2        ;current source address (advances
                             ;each chunk)
K_BC_SRCBANK  ds    1        ;source bank # (meaningful iff
                             ;SRCKIND=BANK)
K_BC_DSTKIND  ds    1
K_BC_DSTADDR  ds    2
K_BC_DSTBANK  ds    1
K_BC_LEN      ds    2        ;remaining byte count, 16-bit,
                             ;caller-set
K_BC_THISLEN  ds    1        ;this chunk's byte count,
                             ;1..BC_CHUNK
K_BC_ERR      ds    1        ;0/1/2 -- see REFUSAL CODES above
K_BC_SAVE80   ds    1        ;incoming RD80STORE bit (nonzero =
                             ;was ON)
K_BC_SAVEP2   ds    1        ;incoming RDPAGE2 bit (captured,
                             ;never acted on -- see CONTRACT
                             ;above)
K_BC_SAVEHI   ds    1        ;incoming RDHIRES bit (ditto)

* -- docs/STICKY.md sec 21's fixed zeroed page. Nonzero = after
* -- the copy loop ends, zero BC_ZPG_LEN bytes at the FINAL
* -- K_BC_DSTADDR -- which, because BC_LOOP advances DSTADDR by
* -- every chunk it moves, is EXACTLY dest+len with no
* -- arithmetic and no metadata. Set by BankCopyZ, CLEARED by
* -- BankCopy, so the ~50 existing callers never learn this
* -- field exists. DSTKIND must be BANK (both spawn call sites
* -- are); a main-side dest would need no bank window at all.
K_BC_ZPAGE    ds    1

* -- the bank<->bank staging page (docs/MEMMAP.md K_BNCBF_SIZE).
* -- K_BOUNCEBUF is NOT assembled here: it is a 256-byte
* -- scratch cell homed in low main RAM by inc/mm.kbss.equ
* -- (docs/KSPACE.md), costing no flat-image bytes. Its
* -- contents are never assumed zero.

*---------------------------------------------------------------
* BankCopy -- the one routine (see file header). Caller sets
* K_BC_SRCKIND/SRCADDR/SRCBANK, K_BC_DSTKIND/DSTADDR/DSTBANK,
* K_BC_LEN (16-bit, low byte first), then `jsr BankCopy`.
* Returns K_BC_ERR (0/1/2, see REFUSAL CODES). Clobbers A/X/Y
* and every K_BC_*/K_CPY_* cell; no syscall frame involved (this
* is the exec-loader's internal primitive, not yet wired to a
* syscall ABI -- that is a future task's job).
*
* BankCopyZ -- BankCopy, plus docs/STICKY.md sec 21's zeroed
* page. Same parameters; after the copy completes, 256 bytes at
* dest+len are zeroed in the SAME 80STORE bracket, so the fill
* is part of the load rather than a second pass over the bank.
* A zero-length call is legal and fills only -- that is how the
* file loader (which copies chunk by chunk and cannot know
* which chunk is last) reaches the fill.
*---------------------------------------------------------------
BankCopyZ   lda   #1
            sta   K_BC_ZPAGE
            bra   BC_ENTRY

BankCopy    stz   K_BC_ZPAGE     ;every OTHER caller in the tree
BC_ENTRY
            ;-- capture incoming switch state (contract:
            ;restore-exact,
            ;-- see CONTRACT above) BEFORE touching anything --
            lda   RD80STORE
            and   #$80
            sta   K_BC_SAVE80
            lda   RDPAGE2
            and   #$80
            sta   K_BC_SAVEP2
            lda   RDHIRES
            and   #$80
            sta   K_BC_SAVEHI

            ;-- force 80STORE off for the WHOLE call (see "WHY
            ;THE
            ;-- 80STORE BRACKET SPANS THE WHOLE CALL" above).
            ;A's value
            ;-- (RDHIRES's AND result) is irrelevant -- STA
            ;triggers on
            ;-- address, not data, same convention as every
            ;other switch
            ;-- write in this tree. --
            sta   CLR80STORE
            stz   K_BC_ERR

            lda   K_BC_LEN
            ora   K_BC_LEN+1
            bne   :haswork
            jmp   BC_ZPAGE              ;len=0 -- nothing to
                                        ;copy, but a
                                        ;BankCopyZ caller still
                                        ;wants its page, and
                                        ;80STORE still needs
                                        ;restoring
:haswork

*---------------------------------------------------------------
BC_LOOP     ;-- this chunk's size = min(BC_CHUNK, remaining) --
            lda   K_BC_LEN+1
            bne   :full
            lda   K_BC_LEN
            cmp   #BC_CHUNK+1
            bcc   :partial
:full       lda   #BC_CHUNK
            bra   :havelen
:partial    lda   K_BC_LEN
:havelen    sta   K_BC_THISLEN

            ;-- window 1: source side, ONLY if SRCKIND=BANK. A
            ;main-side
            ;-- source needs no $C073 selection and no SEI/CLI
            ;bracket
            ;-- at all -- COPYOUT_ENTRY (window 2, below) will
            ;read it
            ;-- directly. --
            lda   K_BC_SRCKIND
            bne   :dowin1
            jmp   BC_SKIP1
:dowin1     php
            sei
            lda   K_BC_SRCBANK
            sta   BANKSEL
            lda   K_BC_SRCADDR
            sta   K_CPY_PROC
            lda   K_BC_SRCADDR+1
            sta   K_CPY_PROC+1
            ;-- K_CPY_MAIN: the bounce buffer if the dest is
            ;ALSO a bank
            ;-- (data must stage through main), else the
            ;caller's real
            ;-- main dest address directly (dstkind=main -- no
            ;bounce
            ;-- needed, this IS the bank->main copy). --
            lda   K_BC_DSTKIND
            beq   :direct1
            lda   #<K_BOUNCEBUF
            sta   K_CPY_MAIN
            lda   #>K_BOUNCEBUF
            sta   K_CPY_MAIN+1
            bra   :go1
:direct1    lda   K_BC_DSTADDR
            sta   K_CPY_MAIN
            lda   K_BC_DSTADDR+1
            sta   K_CPY_MAIN+1
:go1        lda   K_BC_THISLEN
            sta   K_CPY_LEN
            jsr   COPYIN_ENTRY
            plp
            lda   K_CPY_ERR
            beq   BC_SKIP1
            sta   K_BC_ERR
            jmp   BC_RESTORE             ;refused -- stop, still
                                         ;restore
BC_SKIP1

            ;-- window 2: dest side, ONLY if DSTKIND=BANK.
            ;Symmetric to
            ;-- window 1: a main-side dest needs no
            ;selection/bracket at
            ;-- all -- window 1 already wrote it directly. --
            lda   K_BC_DSTKIND
            bne   :dowin2
            jmp   BC_SKIP2
:dowin2     php
            sei
            lda   K_BC_DSTBANK
            sta   BANKSEL
            lda   K_BC_DSTADDR
            sta   K_CPY_PROC
            lda   K_BC_DSTADDR+1
            sta   K_CPY_PROC+1
            ;-- K_CPY_MAIN: the bounce buffer (window 1 staged
            ;the
            ;-- source bank's bytes there) if the source was
            ;ALSO a
            ;-- bank, else the caller's real main source address
            ;-- directly (srckind=main -- this IS the main->bank
            ;copy,
            ;-- window 1 never ran). --
            lda   K_BC_SRCKIND
            beq   :direct2
            lda   #<K_BOUNCEBUF
            sta   K_CPY_MAIN
            lda   #>K_BOUNCEBUF
            sta   K_CPY_MAIN+1
            bra   :go2
:direct2    lda   K_BC_SRCADDR
            sta   K_CPY_MAIN
            lda   K_BC_SRCADDR+1
            sta   K_CPY_MAIN+1
:go2        lda   K_BC_THISLEN
            sta   K_CPY_LEN
            jsr   COPYOUT_ENTRY
            plp
            lda   K_CPY_ERR
            beq   BC_SKIP2
            sta   K_BC_ERR
            jmp   BC_RESTORE             ;refused -- stop, still
                                         ;restore
BC_SKIP2

            ;-- advance both addresses + remaining length by
            ;THISLEN.
            ;-- Both addresses always advance regardless of kind
            ;-- even
            ;-- a "main" side is a real moving pointer across
            ;chunks. --
            lda   K_BC_SRCADDR
            clc
            adc   K_BC_THISLEN
            sta   K_BC_SRCADDR
            bcc   :s1
            inc   K_BC_SRCADDR+1
:s1         lda   K_BC_DSTADDR
            clc
            adc   K_BC_THISLEN
            sta   K_BC_DSTADDR
            bcc   :s2
            inc   K_BC_DSTADDR+1
:s2         lda   K_BC_LEN
            sec
            sbc   K_BC_THISLEN
            sta   K_BC_LEN
            bcs   :s3
            dec   K_BC_LEN+1
:s3         lda   K_BC_LEN
            ora   K_BC_LEN+1
            beq   :bcdone                ;nothing left -- fall
                                         ;through
            jmp   BC_LOOP                ;more to do -- next
                                         ;chunk (JMP, not BNE --
                                         ;BC_LOOP can be out of
                                         ;branch range once the
                                         ;includer's own code
                                         ;precedes this module)
:bcdone     ;-- K_BC_ERR already 0 (stz at entry, never touched
            ;on the -- success path) --

*---------------------------------------------------------------
* BC_ZPAGE -- docs/STICKY.md sec 21's fixed 256-byte zeroed
* page, reached ONLY on a clean completion (every refusal above
* jumps straight to BC_RESTORE, and a spawn whose load failed
* frees the bank anyway). Falls through to BC_RESTORE, so the
* 80STORE bracket this fill runs inside is the SAME one the
* copy opened -- with 80STORE set, RAMWRT is ignored for
* $0400-$07FF and, with HIRES, $2000-$3FFF too
* (learning:01KW1GTYHGXMBZNR6DMQB2F712), and a real image end
* lands in that second window often (ls's does), so the fill
* MUST be inside the bracket, not beside it.
*
* WHY NOT `stz`: the 65C02 has no STZ (zp),y at all, and STZ
* abs,x would need the base address patched into the
* instruction -- self-modifying code, the one thing this
* project is removing. So `sta (zp),y` with A=0.
*
* THE UNROLL AND THE TERMINATOR. `sta (zp),y` (6) + `iny` (2)
* is 8 cycles with no branch; eight of them plus one `bne` is
* 67 cycles per 8 bytes = 8.375 cyc/byte, against 11.375
* un-unrolled (the extra `dex`+`bne` per byte). Y's own wrap
* from $FF back to $00 IS the loop terminator -- no counter, no
* compare -- which is why BC_ZPG_LEN is 256 by construction.
* (zp),y carries across a page boundary by itself, so the page
* start needs no alignment.
*
* THE $C000 GUARD. The page starts at dest+len, and a write
* into $C0xx with RAMWRT=aux would hit the soft switches, not
* memory. Refused loudly (BC_ERR_FORBID, the same code
* copyin/copyout uses for the same region) rather than
* silently skipped: an image within 512 bytes of the top of
* the process window has no room for its own storage either.
*
* SEI SPAN: ~2,150 cycles ~= 2.2ms at 1MHz -- under BankCopy's
* own per-window worst case (~4.5ms) and well under the 16.7ms
* VBL period, same argument as BC_CHUNK's above.
*---------------------------------------------------------------
BC_ZPAGE    lda   K_BC_ZPAGE
            beq   BC_RESTORE           ;plain BankCopy -- done
            lda   K_BC_DSTADDR+1
            cmp   #$BE                 ;$BE00+ -- the page would
            bcc   :fillok              ;reach $BF00/$C000
            lda   #BC_ERR_FORBID
            sta   K_BC_ERR
            bra   BC_RESTORE
:fillok     lda   K_BC_DSTADDR
            sta   K_CPY_PROC
            lda   K_BC_DSTADDR+1
            sta   K_CPY_PROC+1
            php
            sei
            lda   K_BC_DSTBANK
            sta   BANKSEL
            sta   RAMWRTAUX            ;writes -> the child's
                                       ;bank (RAMRD untouched,
                                       ;so THIS code keeps
                                       ;fetching from main --
                                       ;learning:01KW1GTYGVYAPQ
                                       ;RGS5P7J66RWD)
            lda   #0
            ldy   #0
BC_ZFILL    sta   (K_CPY_PROC),y
            iny
            sta   (K_CPY_PROC),y
            iny
            sta   (K_CPY_PROC),y
            iny
            sta   (K_CPY_PROC),y
            iny
            sta   (K_CPY_PROC),y
            iny
            sta   (K_CPY_PROC),y
            iny
            sta   (K_CPY_PROC),y
            iny
            sta   (K_CPY_PROC),y
            iny
            bne   BC_ZFILL             ;Y wrapped to 0 -> 256 B
            sta   RAMWRTMAIN
            plp
            ;-- falls through to BC_RESTORE --

*---------------------------------------------------------------
BC_RESTORE  ;-- restore-exact tail (CONTRACT above): 80STORE
            ;back to -- EXACTLY what K_BC_SAVE80 captured on
            ;entry, on every -- path -- success, empty-length,
            ;OR either refusal code. -- $C073 is intentionally
            ;NOT touched here (write-only, -- "UNKNOWN at every
            ;entry" per docs/ARCHITECTURE.md -- the -- next code
            ;to depend on a selection writes it itself, -- same
            ;discipline as entry.s's own KRN_EXIT/ --
            ;KRN_IRQ_SVC never writing BANKSEL).
            ;PAGE2/HIRES -- need no restore -- never touched,
            ;see CONTRACT above. --
            lda   K_BC_SAVE80
            beq   :off
            sta   SET80STORE
            bra   :done
:off        sta   CLR80STORE
:done       rts
