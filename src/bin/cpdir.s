*---------------------------------------------------------------
* cpdir.s -- cp's resolution-and-recursion half: DSTRESOLV,
* CPERR/SRCSLASH/SRCISDIR, COPYDIR and DIRERR. Split from cp.s
* 2026-09-01 at the DSTRESOLV global boundary: multi-into-
* directory grew cp's converted REL main past as's window and
* the L3 sweep skipped it as a NEW tier-2. One assembly stream,
* put by cp.s exactly where the text sat; every manifest-header
* rule applies unchanged.
*---------------------------------------------------------------

*---------------------------------------------------------------
* DSTRESOLV -- resolve a DIRECTORY destination, Unix semantics.
* mv.s carries the same routine and the same reasoning; the only
* difference is the layer. cp builds each MLI path exactly once
* and uses it everywhere, so this works directly on DPATHBUF --
* 7-bit and COUNT-PREFIXED, hence `#'/'` here where mv.s, which
* must rewrite the high-bit liba string its later MKPATHs
* re-read,
* uses `#"/"`.
*
*   DST exists and IS a directory   -> DST := DST/basename(SRC)
*   DST ends "/" and IS a directory -> same
*   DST ends "/" and is absent      -> carry SET (:err)
*   DST ends "/" and is a FILE      -> refuse, exit 1
*   anything else                   -> DPATHBUF untouched, clc
*
* WHY: `cp SRC DIR` copies SRC INTO DIR on every Unix, and the
* operation costs nothing ProDOS cannot do. Refusing it was
* avoidable semantic drift: a shell script that means one thing
* on the host and another here. The MLI's 64-byte pathname cap
* below IS unavoidable, and is reported rather than truncated.
*---------------------------------------------------------------
DSTRESOLV   stz   DSLASHED
            ldy   DPATHBUF          ;count byte = length
            bne   :havedst
:near       clc                     ;:nofix is a routine away --
            rts                     ;out of a BEQ's reach
:havedst    lda   DPATHBUF,y        ;chars are 1-based
            cmp   #'/'
            bne   :stat
            cpy   #1
            beq   :stat             ;"/" alone -- leave it
            lda   #1
            sta   DSLASHED
            dey
            sty   DPATHBUF          ;strip it: stat the DIR

:stat       lda   #<DPATHBUF
            sta   GFIPARM_PATH
            lda   #>DPATHBUF
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :statok
*-- absent: fatal only if a trailing slash promised a directory
            ldx   DSLASHED
            beq   :near
            sec
            rts

:statok     lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :isdir
            cmp   #$0F              ;volume dir, no house
            beq   :isdir            ;constant (ls.s/file.s)
            ldx   DSLASHED
            beq   :near             ;existing FILE -- replace it
            lda   #<NOTDIRMSG
            sta   PTR0
            lda   #>NOTDIRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   PRINTED
            sec
            rts

*-- append "/" + basename(SRC), growing DPATHBUF's count byte
*-- one character at a time so the MLI_PTH_MAXLN check below is
*-- the only bound anything depends on.
:isdir      ldx   #1                ;X = 1-based basename start
            ldy   #1
:bscan      lda   SPATHBUF,y
            cmp   #'/'
            bne   :bnext
            tya
            clc
            adc   #1
            tax
:bnext      cpy   SPATHBUF
            beq   :bfound
            iny
            bne   :bscan
:bfound     ldy   DPATHBUF
            cpy   #MLI_PTH_MAXLN
            bcs   :toolong
            iny
            lda   #'/'
            sta   DPATHBUF,y
            sty   DPATHBUF
:acopy      ldy   DPATHBUF
            cpy   #MLI_PTH_MAXLN
            bcs   :toolong
            iny
            lda   SPATHBUF,x
            sta   DPATHBUF,y
            sty   DPATHBUF
            cpx   SPATHBUF
            beq   :nofix            ;last character copied
            inx
            bra   :acopy

:toolong    lda   #<TOOLONGM
            sta   PTR0
            lda   #>TOOLONGM
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   PRINTED
            sec
            rts

:nofix      clc
            rts

*---------------------------------------------------------------
* CPERR -- "cp: error" to stderr, exit 1. The one shared failure
* exit; a dozen sites above jump here.
*
* IT IS A GLOBAL LABEL, and that is a DIALECT FIX, not a style
* choice. It was `:err`, a LOCAL, referenced from START's zone
* while defined in DSTRESOLV's -- a cross-zone local reference,
* which merlin32 resolved only because `:err` happened to be
* unique in the whole assembly unit. `put`ting cptree.s, which
* has an `:err` of its own, made it ambiguous and the assembly
* failed with "Can't find format for element ':err'". Real
* Merlin-8 scopes locals between global labels too, so the
* construct was never in the dialect INTERSECTION this tree is
* required to stay inside (HACKING.md; the self-hosting
* milestone and check-dual depend on it) -- it simply had not
* been caught, because nothing had ever collided with the name.
*---------------------------------------------------------------
CPERR       lda   PRINTED
            bne   :quiet
            lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
:quiet      sec
            rts

*---------------------------------------------------------------
* SRCSLASH -- strip SRC's own trailing "/", recording that it
* was there. Works on SPATHBUF, which is MLI-shaped, so the
* strip is one `dey`/`sty` on the count byte -- and `#'/'`, not
* `#"/"`, for the polarity reason DSTRESOLV's header gives.
*
* WHY. DSTRESOLV takes basename(SRC) by scanning for the last
* "/" and starting one past it. With a TRAILING slash that start
* index is one PAST the count byte, so :acopy reads bytes that
* are not part of the pathname and walks until it hits the
* 64-character fence -- a garbage destination name from
* `cp A/ B`, silently. mv.s carries the same routine for the
* same reason; there it also turns a move-INTO into a
* move-ONTO. Reachable today, and this is where it is fixed.
*---------------------------------------------------------------
SRCSLASH    stz   SSLASHED
            ldy   SPATHBUF
            beq   :done
            cpy   #1
            beq   :done                ;"/" alone -- leave it
            lda   SPATHBUF,y
            cmp   #'/'
            bne   :done
            lda   #1
            sta   SSLASHED
            dey
            sty   SPATHBUF
:done       rts

*---------------------------------------------------------------
* SRCISDIR -- SRCISDIRF := 1 if SRC names a directory, else 0.
* A stat FAILURE leaves it 0 on purpose: a missing SRC is not
* this routine's error to report, and falling through to the
* ordinary copy reproduces cp's existing "cp: error" exactly.
*---------------------------------------------------------------
SRCISDIR    stz   SRCISDIRF
            lda   #<SPATHBUF
            sta   GFIPARM_PATH
            lda   #>SPATHBUF
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :done
            lda   GFIPARM_STYP
            cmp   #STYP_DIR
            beq   :yes
            cmp   #$0F              ;volume dir, no house
            bne   :done             ;constant (ls.s/file.s)
:yes        lda   #1
            sta   SRCISDIRF
:done       rts
