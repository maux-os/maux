*---------------------------------------------------------------
* string.s -- length/compare/copy and the high-bit boundary
* conversion.
* Full design notes: L.STRING.TXT (docs/a2/)
*---------------------------------------------------------------

*---------------------------------------------------------------
* STRLEN -- length of a NUL-terminated liba string, SIXTEEN BIT.
* Walks with Y and counts whole pages in X, so a string of 256
* bytes or more returns its real length. The old 8-bit walk fell
* out of `iny / bne` on the 255->0 wrap and returned ZERO -- not
* the length modulo 256, and not a saturated 255: it stopped
* walking at the wrap, so EVERY string of 256 bytes or more
* measured 0 no matter how long it really was. PUTS wrote that
* answer as its MLI request_count, so a 900-character line
* printed as an EMPTY line (docs/STICKY.md sec 23, docs/PLAN.md
* wave 6 item 6).
*
* IN:  PTR0/PTR0+1 = string
* OUT: A = length low byte, X = length high byte, Y = A.
* CLOBBERS: A, X, Y. PRESERVES: PTR0/PTR0+1 (the walk advances
* PTR0+1 a page at a time and hands it back intact -- PUTS reads
* those same cells back as its own buffer argument AFTER the
* call), PTR1, PTR2.
*
* A CALLER THAT WANTS A BYTE MUST TEST X FIRST. Comparing the
* low byte alone against a small limit is the identical silent
* truncation one layer up: a 300-character word has a low byte
* of 44 and would sail through a `cmp #FORWORDLEN` that has to
* reject it. Silent truncation must be unreachable at EVERY
* layer, not just the one that was audited last
* (learning:01M07V2D0T25FYD6ASCMPJYNWQ). Three of the four
* non-PUTS callers wanted a byte all along and test X now --
* sh.s's two `for` limits reject, ls.s's PRPAD8 declines to pad.
* The fourth, ed.s's file writer, wants all sixteen and stores X
* straight into its own MLI request_count.
*
* STRCMP/STRCMPI/STRCPY BELOW ARE 16-BIT TOO as of 2026-08-22
* (docs/STICKY.md sec 29). The whole file walks the same way
* now; there is one convention here, not two.
*---------------------------------------------------------------
STRLEN      lda   PTR0+1
            pha
            ldx   #0
            ldy   #0
:loop       lda   (PTR0),y
            beq   :done
            iny
            bne   :loop
            inc   PTR0+1         ;next page; X counts them, and
            inx                  ;X IS the length's high byte
            bra   :loop
:done       pla
            sta   PTR0+1
            tya
            rts

*---------------------------------------------------------------
* STRCMP -- compare two NUL-terminated liba strings, byte for
* byte. Because both operands share the high-bit-set convention,
* a plain unsigned byte compare gives correct ASCII collation
* order (bit 7 is constant across both sides for any two well-
* formed liba strings, so it never flips the comparison
* outcome).
*
* SIXTEEN BIT since 2026-08-22. It used to walk with `iny / bne`
* and fall out of the loop at the 255->0 wrap straight into its
* own :eq -- so two strings sharing a 255-byte prefix compared
* EQUAL however far they diverged after it. That was reachable:
* sort's -u pass (sort.s:544) and diff's LCS cells (diff.s:643,
* :737) both hold whole file lines in a heap arena with no
* per-line cap at all, and both treat "equal" as an ACTION --
* sort -u drops the line, diff calls the files unchanged. A
* wrong order would have been loud; silently deleting a distinct
* line is not.
*
* Now the walk carries the page into PTR0+1/PTR1+1 and the
* routine hands BOTH pointers back, which is load-bearing for
* the same reason STRLEN's PTR0 restore is: the 8-bit version
* never touched either pointer, so every caller in the tree may
* already assume they survive (sort.s:540 reads PTR1 back as
* SRT_PREV). The result travels home in Y, not A, because the
* restore has to happen after the compare and `pla` would
* clobber A -- `pla` leaves CARRY alone, which is what lets
* :diff decide lt/gt on the far side of it.
*
* IN:  PTR0/PTR0+1 = string A, PTR1/PTR1+1 = string B
* OUT: A = 0 if equal, A = $FF if A<B, A = 1 if A>B
* CLOBBERS: A, Y. PRESERVES: X, PTR0/PTR0+1, PTR1/PTR1+1.
*---------------------------------------------------------------
STRCMP      lda   PTR0+1
            pha
            lda   PTR1+1
            pha
            ldy   #0
:loop       lda   (PTR0),y
            cmp   (PTR1),y
            bne   :diff
            cmp   #0
            beq   :eq            ;both hit NUL together -> equal
            iny
            bne   :loop
            inc   PTR0+1         ;same byte offset, next page --
            inc   PTR1+1         ;both operands advance together
            bra   :loop
:diff       bcc   :lt            ;carry is from the cmp and
            ldy   #1             ;survives the pla's in :rest
            bra   :rest
:lt         ldy   #$FF
            bra   :rest
:eq         ldy   #0
:rest       pla
            sta   PTR1+1
            pla
            sta   PTR0+1
            tya
            rts

*---------------------------------------------------------------
* STRCMPI -- case-insensitive STRCMP: folds 'a'-'z' (high-bit)
* to 'A'-'Z' before comparing; digits/punctuation pass through
* unchanged -- same fold rule as glob.s's GFOLD, duplicated here
* rather than PUT from glob.s (neither merlin32 nor real Merlin
* nests PUT, docs/TOOLCHAIN.md) since glob.s is sh's/find's own
* file, not every STRCMPI caller's.
*
* Needed by ls.s's SORTENTRIES once src/liba/readdir.s hands
* back a case-DECODED name (docs/FLEET.md's readdir ruling):
* sorting the decoded bytes with a case-SENSITIVE compare would
* misplace any mixed-case name relative to its all-uppercase
* siblings (ASCII lowercase > uppercase). Folding a decoded name
* back to upper always reproduces the STORED bytes exactly (case
* flags only ever touch letters, and folding undoes exactly that
* transform) -- so STRCMPI on decoded names sorts identically to
* plain STRCMP on the old raw-stored names. check-ls's byte-
* identical requirement is the proof.
* IN/OUT/CLOBBERS: same contract as STRCMP, INCLUDING the 16-bit
* walk and the pointer restore. Its one caller today (ls.s:528)
* compares ProDOS directory names, which cannot exceed 15 bytes,
* so this widening is unreachable in the tree as it stands -- it
* is here because two compare routines in one file with two
* different widths is how the next `sort -f` inherits the bug
* without anyone deciding to. One convention per file.
*---------------------------------------------------------------
STRCMPI     lda   PTR0+1
            pha
            lda   PTR1+1
            pha
            ldy   #0
:loop       lda   (PTR1),y
            jsr   SIFOLD
            sta   SCI_B
            lda   (PTR0),y
            jsr   SIFOLD
            cmp   SCI_B
            bne   :diff
            cmp   #0
            beq   :eq
            iny
            bne   :loop
            inc   PTR0+1
            inc   PTR1+1
            bra   :loop
:diff       bcc   :lt
            ldy   #1
            bra   :rest
:lt         ldy   #$FF
            bra   :rest
:eq         ldy   #0
:rest       pla
            sta   PTR1+1
            pla
            sta   PTR0+1
            tya
            rts

SIFOLD      cmp   #$E1
            bcc   :done
            cmp   #$FB
            bcs   :done
            sec
            sbc   #$20
:done       rts

* -- SCI_B moved to src/liba/libabss.s (docs/STICKY.md sec 21):
* -- one emitted-and-written byte, but text is immutable or it
* -- is not. `sta SCI_B` before `cmp SCI_B`, so no zero start.

*---------------------------------------------------------------
* STRCPY -- copy a NUL-terminated liba string, terminator and
* all. See L.STRING.TXT: "STRCPY -- copy a NUL-terminated liba".
*
* SIXTEEN BIT since 2026-08-22, same walk and same pointer
* restore as STRCMP above. The 8-bit version stopped at the
* 255->0 wrap having written 256 bytes and NO TERMINATOR, then
* returned 0 -- so the destination was left unterminated and the
* caller was told it had copied nothing.
*
* THIS ROUTINE HAS NO BOUND AND NEVER HAD ONE. It is `strcpy`,
* not `strncpy`: the length lives in the source, so the only
* place that can know the destination's size is the caller. FOUR
* callers were getting that wrong on 2026-08-22 -- mv's SRCBUF
* and DSTBUF, find's and du's PATHBUF, and sh's `export` name --
* and all four check before they call now. None of the four was
* a 256-byte bug; they are 80-, 65- and 16-byte ones that the
* same missing bound produced.
*
* IN:  PTR0/PTR0+1 = source, PTR1/PTR1+1 = destination
* OUT: A = length low byte, X = length high byte, Y = A.
* CLOBBERS: A, X, Y. PRESERVES: PTR0/PTR0+1, PTR1/PTR1+1.
*
* A CALLER THAT STORES THE RETURN IN A BYTE MUST TEST X FIRST,
* exactly as STRLEN's header says -- find.s and du.s both do
* `sta PATHLEN` on it (learning:01M07V2D0T25FYD6ASCMPJYNWQ).
* X CHANGED MEANING HERE: the 8-bit version PRESERVED X, so a
* caller holding an index in it across the call now loses it.
* ONE DID -- sh's VARSET keeps the variable slot in X across
* both of its copies, and reading the twelve call sites did not
* find it, because the reliance was written as a comment two
* lines BELOW the call rather than as code near it. The symptom
* was not a crash: assignments still looked fine and every later
* expansion came back EMPTY. check-shlang and check-env caught
* it; VARSET brackets both copies with phx/plx now. If you add a
* caller, the question is not "does the next instruction use X"
* -- it is "is anything in this routine still holding X".
*---------------------------------------------------------------
STRCPY      lda   PTR0+1
            pha
            lda   PTR1+1
            pha
            ldx   #0
            ldy   #0
:loop       lda   (PTR0),y
            sta   (PTR1),y
            beq   :done          ;the NUL is copied, then stop
            iny
            bne   :loop
            inc   PTR0+1         ;next page both sides; X counts
            inc   PTR1+1         ;them and IS the high byte
            inx
            bra   :loop
:done       pla
            sta   PTR1+1
            pla
            sta   PTR0+1
            tya
            rts

*---------------------------------------------------------------
* MAKEHI -- set bit 7 (low-bit-ASCII -> liba-string byte). See
* file header. IN/OUT: A. CLOBBERS: nothing but A.
*---------------------------------------------------------------
MAKEHI      ora   #$80
            rts

*---------------------------------------------------------------
* STRIPHI -- clear bit 7 (liba-string byte -> 7-bit-clean, for
* whatever boundary eventually needs it -- see docs/USERLAND.md
* "ABI FRICTION"). IN/OUT: A. CLOBBERS: nothing but A.
*---------------------------------------------------------------
STRIPHI     and   #$7F
            rts
