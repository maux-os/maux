*---------------------------------------------------------------
* patchprs.s -- the three hunk parsers themselves (unified,
* context, normal) and the one wrapper that dispatches on the
* detected form, applies -R's swap and the empty-range bump.
*
* `put` into src/bin/patch.s after patchhnk.s (split from it for
* check-dialect's as-window budget); one assembly stream, every
* rule in that manifest's header applies unchanged.
*---------------------------------------------------------------
* PARSEHUNK -- the next hunk of whichever form this patch is,
* or carry SET when there are no more. On a carry-clear return
* OSTART, NOLD/OLDTBL and NNEW/NEWTBL describe it.
*
* -R is applied HERE, once, for all three forms: swap the two
* lists and the two start numbers. The empty-range bump is
* applied AFTER that swap, so it reads the hunk that is
* actually about to be applied.
*---------------------------------------------------------------
PARSEHUNK   jsr   HUNKINIT
            lda   FORM
            cmp   #FORM_U
            bne   :notu
            jsr   PARSEU
            bra   :tail
:notu       cmp   #FORM_C
            bne   :isn
            jsr   PARSEC
            bra   :tail
:isn        jsr   PARSEN
:tail       bcc   :have
            rts                     ;carry set: no more hunks
:have       lda   #1
            sta   HADHUNK
            lda   WANTR
            bne   :rev
            lda   #<OLDLP
            sta   OLDTBL
            lda   #>OLDLP
            sta   OLDTBL+1
            lda   #<NEWLP
            sta   NEWTBL
            lda   #>NEWLP
            sta   NEWTBL+1
            bra   :bump
:rev        lda   #<NEWLP
            sta   OLDTBL
            lda   #>NEWLP
            sta   OLDTBL+1
            lda   #<OLDLP
            sta   NEWTBL
            lda   #>OLDLP
            sta   NEWTBL+1
            lda   NOLD
            ldx   NNEW
            sta   NNEW
            stx   NOLD
            lda   OSTART
            ldx   NSTART
            sta   NSTART
            stx   OSTART
:bump       lda   NOLD
            bne   :done
            inc   OSTART            ;see patch.s's header: the
:done       clc                     ;one rule for all three
            rts                     ;forms' empty range

*---------------------------------------------------------------
* PARSEU -- "@@ -l,s +l,s @@". The header's two counts say how
* many lines of each side to read; a ' ' line spends one of
* each, which is what makes them a correct terminator even
* though the body is interleaved.
*---------------------------------------------------------------
PARSEU      jsr   PGETLN
            bcc   :have
:nomore     sec
            rts
:bad        jmp   MALFORMED
:notat      lda   HADHUNK
            beq   :bad
            jsr   PUSHBACK
            bra   :nomore
:have       lda   (PT_LP)
            cmp   #$C0              ;'@'
            bne   :notat
            lda   #1
            jsr   LINECH
            cmp   #$C0
            bne   :notat
            jsr   HRAW
            lda   #2
            jsr   SETSCAN
            lda   #$AD              ;'-'
            jsr   SCANTO
            bcs   :bad
            jsr   GETNUM
            bcs   :bad
            sta   OSTART
            jsr   UCOUNT
            sta   OCNT
            lda   #$AB              ;'+'
            jsr   SCANTO
            bcs   :bad
            jsr   GETNUM
            bcs   :bad
            sta   NSTART
            jsr   UCOUNT
            sta   NCNT
            bra   :bloop
:bad2       jmp   MALFORMED         ;a second trampoline: the
                                    ;body's own branches cannot
                                    ;reach :bad above it
:bloop      lda   OCNT
            ora   NCNT
            beq   :bdone
            jsr   PGETLN
            bcs   :bad2
            jsr   HRAW
            lda   #1
            jsr   SKIPPFX
            lda   (PT_LP)
            beq   :both             ;an empty line is context
            cmp   #$DC              ;'\' -- "No newline at end
            beq   :bloop            ;of file" -- neither side
            cmp   #$AD              ;'-'
            beq   :isdel
            cmp   #$AB              ;'+'
            beq   :isins
            cmp   #$A0              ;' '
            bne   :bad2
:both       jsr   HOLD
            jsr   HNEW
            lda   OCNT
            beq   :b2
            dec   OCNT
:b2         lda   NCNT
            beq   :bloop
            dec   NCNT
            bra   :bloop
:isdel      jsr   HOLD
            lda   OCNT
            beq   :bloop
            dec   OCNT
            bra   :bloop
:isins      jsr   HNEW
            lda   NCNT
            beq   :bloop
            dec   NCNT
            bra   :bloop
:bdone      clc
            rts

* UCOUNT -- the ",s" after a unified range's line number, or 1
* when it is absent (POSIX: an omitted count is exactly one
* line).
UCOUNT      lda   (PT_SCAN)
            cmp   #$AC              ;','
            beq   :have
            lda   #1
            rts
:have       jsr   SCANADV
            jsr   GETNUM
            bcs   :bad
            rts
:bad        jmp   MALFORMED

*---------------------------------------------------------------
* PARSEC -- the context form. Both sections are read into the
* two lists with a KIND byte each, and then the one rule that
* makes the format work: a section printed as its header line
* ALONE (no body) means "this side has no changed line", and
* its content is the OTHER section's context lines.
*---------------------------------------------------------------
PARSEC      stz   NSTART
            jsr   PGETLN
            bcc   :have
:nomore     sec
            rts
:bad        jmp   MALFORMED
:notstar    lda   HADHUNK
            beq   :bad
            jsr   PUSHBACK
            bra   :nomore
:have       lda   (PT_LP)
            cmp   #$AA              ;'*'
            bne   :notstar
            lda   #3
            jsr   LINECH
            cmp   #$AA
            bne   :notstar
            jsr   HRAW
            jsr   PGETLN            ;"*** l,l ****"
            bcs   :bad
            jsr   HRAW
            lda   #4
            jsr   SETSCAN
            jsr   GETNUM
            bcs   :bad
            sta   OSTART
:oldl       jsr   PGETLN
            bcc   :oldk
            jmp   :nonew
:oldk       lda   (PT_LP)
            cmp   #$AD              ;'-'
            bne   :oldk2
            lda   #1
            jsr   LINECH
            cmp   #$AD              ;"---" ends the old section
            beq   :newhdr
:oldk2      lda   (PT_LP)
            beq   :oldctx
            cmp   #$A0              ;'  ' context
            beq   :oldctx
            cmp   #$AD              ;'- ' deleted
            beq   :oldchg
            cmp   #$A1              ;'! ' changed
            beq   :oldchg
            jsr   PUSHBACK          ;not a section line at all
            jmp   :nonew
:oldctx     lda   #0
            bra   :oldst
:oldchg     lda   #1
:oldst      ldx   NOLD
            sta   OKIND,x
            jsr   HRAW
            lda   #2
            jsr   SKIPPFX
            jsr   HOLD
            bra   :oldl

:newhdr     jsr   HRAW
            lda   #4
            jsr   SETSCAN
            jsr   GETNUM
            bcc   :nhok
            jmp   MALFORMED
:nhok       sta   NSTART
:newl       jsr   PGETLN
            bcc   :nl2
            jmp   :cdone
:nl2        lda   (PT_LP)
            beq   :newctx
            cmp   #$AA              ;the next hunk's stars line
            beq   :npush
            cmp   #$A0              ;'  ' context
            beq   :newctx
            cmp   #$AB              ;'+ ' added
            beq   :newchg
            cmp   #$A1              ;'! ' changed
            beq   :newchg
:npush      jsr   PUSHBACK
            jmp   :cdone
:newctx     lda   #0
            bra   :newst
:newchg     lda   #1
:newst      ldx   NNEW
            sta   NKIND,x
            jsr   HRAW
            lda   #2
            jsr   SKIPPFX
            jsr   HNEW
            bra   :newl

:nonew      stz   NNEW              ;no "---" section at all
:cdone      lda   NOLD
            bne   :havold
            jsr   RECONOLD
:havold     lda   NNEW
            bne   :done
            jsr   RECONNEW
:done       clc
            rts

* RECONOLD -- the old section was header-only: its content is
* every CONTEXT line of the new section, in order.
RECONOLD    stz   TIDX
:rl         lda   TIDX
            cmp   NNEW
            bcs   :rdone
            tax
            lda   NKIND,x
            bne   :rnext
            lda   TIDX
            ldx   #<NEWLP
            ldy   #>NEWLP
            jsr   LPGET
            jsr   HOLD
:rnext      inc   TIDX
            bra   :rl
:rdone      rts

* RECONNEW -- and the mirror image, for a header-only new
* section (a hunk that only deletes).
RECONNEW    stz   TIDX
:rl         lda   TIDX
            cmp   NOLD
            bcs   :rdone
            tax
            lda   OKIND,x
            bne   :rnext
            lda   TIDX
            ldx   #<OLDLP
            ldy   #>OLDLP
            jsr   LPGET
            jsr   HNEW
:rnext      inc   TIDX
            bra   :rl
:rdone      rts

*---------------------------------------------------------------
* PARSEN -- the normal form: a command line, then "< " lines,
* an optional "---" separator, then "> " lines. The body ends
* at the first line that is none of those.
*---------------------------------------------------------------
PARSEN      jsr   PGETLN
            bcs   :nomore
            jsr   NORMCMD
            bcs   :notcmd
            jsr   HRAW
:nl         jsr   PGETLN
            bcs   :ndone
            lda   (PT_LP)
            cmp   #$BC              ;'<'
            beq   :isold
            cmp   #$BE              ;'>'
            beq   :isnew
            cmp   #$AD              ;'-'
            bne   :npush
            lda   #1
            jsr   LINECH
            cmp   #$AD              ;"---" separator
            bne   :npush
            jsr   HRAW
            bra   :nl
:isold      jsr   HRAW
            lda   #2
            jsr   SKIPPFX
            jsr   HOLD
            bra   :nl
:isnew      jsr   HRAW
            lda   #2
            jsr   SKIPPFX
            jsr   HNEW
            bra   :nl
:npush      jsr   PUSHBACK
:ndone      clc
            rts
:notcmd     lda   HADHUNK
            beq   :bad
            jsr   PUSHBACK
:nomore     sec
            rts
:bad        jmp   MALFORMED
