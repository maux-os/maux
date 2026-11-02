*---------------------------------------------------------------
* patchapp.s -- patch's APPLY half: where a hunk goes, whether
* it goes there at all, and what happens when it does not.
*
* `put` into src/bin/patch.s; one assembly stream, every rule in
* that manifest's header applies unchanged.
*
* THE GUESS. A hunk states the line it began at in the ORIGINAL
* file. The file being patched has already gained and lost
* lines from every hunk before this one, so the stated number
* is not where to look. Two cursors carry the correction with
* no signed arithmetic at all:
*
*   CURT     the next line of the target still to be written
*   PREVEND  the original-file line just past the previous hunk
*
* The unchanged run between the two hunks is the same length in
* both files, so GAP = OSTART - PREVEND is exactly how far past
* CURT this hunk's text should start. That is the guess; the
* offset search only runs when it misses.
*---------------------------------------------------------------

*---------------------------------------------------------------
* APPLYALL -- every hunk, in order. Each one either applies
* (its NEW lines are written in place of its OLD ones) or is
* rejected (nothing changes and its raw text goes to the reject
* file). Both paths advance PREVEND, so a later hunk's guess is
* still right after a rejected one.
*---------------------------------------------------------------
APPLYALL    jsr   PARSEHUNK
            bcs   :done
            jsr   FINDHUNK
            bcs   :reject
            sta   HMATCH
:copy       lda   CURT              ;target lines before it
            cmp   HMATCH
            bcs   :subst
            lda   CURT
            jsr   EMITT
            inc   CURT
            bra   :copy
:subst      stz   TIDX              ;the hunk's NEW lines
:sl         lda   TIDX
            cmp   NNEW
            bcs   :sdone
            lda   TIDX
            ldx   NEWTBL
            ldy   NEWTBL+1
            jsr   LPGET
            lda   PT_LP2
            sta   PTR0
            lda   PT_LP2+1
            sta   PTR0+1
            ldx   OFD
            jsr   EMITLN
            inc   TIDX
            bra   :sl
:sdone      clc                     ;and skip its OLD ones
            lda   HMATCH
            adc   NOLD
            sta   CURT
            inc   NHOK
            bra   :next
:reject     inc   NHFAIL
            jsr   REJPUT
:next       clc
            lda   OSTART
            adc   NOLD
            sta   PREVEND
            jmp   APPLYALL
:done       rts

*---------------------------------------------------------------
* FINDHUNK -- where this hunk's OLD lines really are. OUT: A =
* a 1-based target line, carry CLEAR; carry SET = nowhere, and
* the hunk is rejected.
*
* The guess first, then +1, -1, +2, -2... until both directions
* leave the file. The search never looks BEFORE CURT: text
* already written cannot be patched, and a hunk that matched
* only there would produce output with its lines out of order.
*---------------------------------------------------------------
FINDHUNK    lda   OSTART            ;guess = CURT + (OSTART -
            cmp   PREVEND           ;PREVEND), floored at CURT
            bcc   :atcur
            sec
            sbc   PREVEND
            clc
            adc   CURT
            bcs   :atend            ;wrapped: past the file
            sta   TIDX2
            bra   :clamp
:atcur      lda   CURT
            sta   TIDX2
            bra   :clamp
:atend      jsr   LASTPOS
            sta   TIDX2
:clamp      lda   TIDX2             ;an insertion may land one
            cmp   CURT              ;past the last line, never
            bcs   :hi               ;further
            lda   CURT
            sta   TIDX2
:hi         jsr   LASTPOS
            cmp   TIDX2
            bcs   :try
            sta   TIDX2
:try        lda   TIDX2
            sta   CAND
            jsr   MATCHAT
            bcc   :hitc
            stz   SRCH
:sloop      inc   SRCH
            beq   :miss             ;255 steps covers the file
            stz   INRANGE
            clc                     ;forward: guess + SRCH
            lda   TIDX2
            adc   SRCH
            bcs   :bwd
            sta   CAND
            jsr   LASTPOS
            cmp   CAND
            bcc   :bwd
            inc   INRANGE
            lda   CAND
            jsr   MATCHAT
            bcc   :hitc
:bwd        lda   TIDX2             ;backward: guess - SRCH
            sec
            sbc   SRCH
            bcc   :chk
            beq   :chk              ;line 0 is not a line
            cmp   CURT
            bcc   :chk
            sta   CAND
            inc   INRANGE
            jsr   MATCHAT
            bcc   :hitc
:chk        lda   INRANGE
            bne   :sloop
:miss       sec
            rts
:hitc       lda   CAND
            clc
            rts

* LASTPOS -- A = the highest position a hunk may start at:
* NT+1, one past the last line, which is where an insertion at
* the very end of the file lands.
LASTPOS     lda   NT
            clc
            adc   #1
            rts

*---------------------------------------------------------------
* MATCHAT -- IN: A = a 1-based target line. Carry CLEAR if this
* hunk's OLD lines sit there, whole line for whole line. An
* EMPTY old list (a pure insertion) matches anywhere in range,
* which is what makes an insertion land on its guess.
*---------------------------------------------------------------
MATCHAT     sta   TIDX
            lda   NOLD
            beq   :fits
            clc                     ;does the run fit at all?
            lda   TIDX              ;last line used is
            adc   NOLD              ;TIDX+NOLD-1
            bcs   :nofit
            sec
            sbc   #1
            cmp   NT
            beq   :inrange
            bcc   :inrange
:nofit      sec                     ;TIDX+NOLD-1 > NT
            rts
:inrange    stz   MIDX
:ml         lda   MIDX
            cmp   NOLD
            bcs   :fits
            clc
            lda   TIDX
            adc   MIDX
            jsr   TGTLINE           ;-> PTR0
            lda   MIDX
            ldx   OLDTBL
            ldy   OLDTBL+1
            jsr   LPGET
            lda   PT_LP2
            sta   PTR1
            lda   PT_LP2+1
            sta   PTR1+1
            jsr   STRCMP
            bne   :nomatch
            inc   MIDX
            bra   :ml
:fits       clc
            rts
:nomatch    sec
            rts
