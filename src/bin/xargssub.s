*---------------------------------------------------------------
* xargssub.s -- xargs's -I replstr substitution (SUBST_ONE,
* TRYMATCH, RLEN, SO_PUT1), split out of xargstok.s 2026-09-21
* for the vendored `as`'s 16,128-byte source window. SECOND
* split of this unit in a day: -E took INVOKE out of xargsrun.s,
* and -L then pushed the manifest up until xargstok.s became the
* binding put. docs/POSIX-GAPS.md sec 6b: the budget is manifest
* plus largest single put, and across the utility set that sum
* now sits close enough that one flag costs one split.
*
* The seam is READING input (above: TOKREAD, FILLPEND, NEXTLINE,
* PARSEDEC) against REWRITING a template word (here). `put` by
* xargs.s at top level -- Merlin cannot nest a put inside a put.
*---------------------------------------------------------------
*---------------------------------------------------------------
* SUBST_ONE -- IN: PTR0 = template word to substitute. Copies it
* into REPLBUF (bump-allocated at REPLCUR), replacing every
* occurrence of REPLPTR's text with LINEBUF's text. OUT: A/X =
* lo/hi of the copy's start (for the caller's argv pointer);
* REPLCUR advanced past the copy's NUL. An empty REPLPTR string
* never matches (guards a runaway copy loop). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SUBST_ONE   lda   REPLCUR
            sta   SO_START
            lda   REPLCUR+1
            sta   SO_START+1
            lda   PTR0
            sta   XA_SRC
            lda   PTR0+1
            sta   XA_SRC+1
:loop       ldy   #0
            lda   (XA_SRC),y
            beq   :endstr
            jsr   TRYMATCH
            bcc   :didmatch
            ldy   #0
            lda   (XA_SRC),y
            jsr   SO_PUT1
            inc   XA_SRC
            bne   :loop
            inc   XA_SRC+1
            bra   :loop
:didmatch   jsr   SO_PUTLN
            jsr   RLEN
:adv        cpx   #0
            beq   :loop
            inc   XA_SRC
            bne   :advno
            inc   XA_SRC+1
:advno      dex
            jmp   :adv
:endstr     jsr   SO_PUT1
            lda   SO_START
            ldx   SO_START+1
            rts

*---------------------------------------------------------------
* TRYMATCH -- does REPLPTR's text occur starting at XA_SRC?
* OUT: carry clear = yes (a nonempty REPLPTR only); carry set =
* no. CLOBBERS: A, Y.
*---------------------------------------------------------------
TRYMATCH    ldy   #0
            lda   (REPLPTR),y
            bne   :chk
            sec
            rts
:chk        lda   XA_SRC
            sta   XA_MSRC
            lda   XA_SRC+1
            sta   XA_MSRC+1
            ldy   #0
:mloop      lda   (REPLPTR),y
            beq   :yes
            cmp   (XA_MSRC),y
            bne   :no
            iny
            bne   :mloop
:no         sec
            rts
:yes        clc
            rts

*---------------------------------------------------------------
* RLEN -- OUT: X = REPLPTR's length (0-255). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
RLEN        ldy   #0
:l          lda   (REPLPTR),y
            beq   :d
            iny
            bra   :l
:d          tya
            tax
            rts

*---------------------------------------------------------------
* SO_PUT1 -- write the byte in A to REPLBUF at REPLCUR (bounds-
* checked against REPLLIM), advance REPLCUR. CLOBBERS: none
* beyond Y.
*---------------------------------------------------------------
SO_PUT1     pha
            lda   REPLCUR+1
            cmp   REPLLIM+1
            bcc   :room
            bne   :full
            lda   REPLCUR
            cmp   REPLLIM
            bcc   :room
:full       pla
            rts
:room       ldy   #0
            lda   REPLCUR
            sta   SOWPTR
            lda   REPLCUR+1
            sta   SOWPTR+1
            pla
            sta   (SOWPTR),y
            inc   REPLCUR
            bne   :done
            inc   REPLCUR+1
:done       rts

*---------------------------------------------------------------
* SO_PUTLN -- copy LINEBUF's whole text through SO_PUT1 (its
* NUL is not copied here -- SUBST_ONE's own :endstr does that
* once, at the very end). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- X, not Y: SO_PUT1 clobbers Y internally (its own store
*-- index), so Y cannot survive the `jsr` as THIS loop's index.
SO_PUTLN    ldx   #0
:l          lda   LINEBUF,x
            beq   :d
            jsr   SO_PUT1
            inx
            bra   :l
:d          rts
