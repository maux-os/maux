*---------------------------------------------------------------
* edsubst.s -- ed's substitute engine and the commands built
* on it: `s`, `g`, `m`, `t`, `j`. `put` by src/bin/ed.s. See
* edparse.s's header for the put-module shape and why this
* unit is split at all.
*---------------------------------------------------------------
*---------------------------------------------------------------
* ED_COPYDELIM -- copy a `/`-delimited token at ED_CMDPTR into
* the buffer ED_DST already points at, backslash-escape aware (a
* backslash and whatever follows it are always copied as a pair,
* never treated as the terminator -- so `\/` inside the token
* doesn't end it early). Stops at an unescaped `/` or NUL
* (lenient: a missing closing delimiter just ends at end of
* line). NUL-terminates the destination. Advances ED_CMDPTR past
* everything consumed, including the closing `/` if one was
* found.
*---------------------------------------------------------------
ED_COPYDELIM
            ldy   #0
:loop       lda   (ED_CMDPTR),y
            beq   :end
            cmp   #"/"
            beq   :end
            cmp   #"\"
            bne   :plain
            sta   (ED_DST)
            jsr   ED_BUMPDST
            iny
            lda   (ED_CMDPTR),y
            beq   :end
            sta   (ED_DST)
            jsr   ED_BUMPDST
            iny
            bra   :loop
:plain      sta   (ED_DST)
            jsr   ED_BUMPDST
            iny
            bra   :loop
:end        lda   (ED_CMDPTR),y
            beq   :noskip
            iny
:noskip     lda   #0
            sta   (ED_DST)
            tya
            clc
            adc   ED_CMDPTR
            sta   ED_CMDPTR
            bcc   :nc
            inc   ED_CMDPTR+1
:nc         rts

*---------------------------------------------------------------
* ED_LASTRE -- the shared "last regular expression" helper
* (Ex Reference Manual v1.1,
* learning:01M1FX8HT89CKR9CB8T8VKCW1S: "null-re repeats the
* last search (`//`, `??`)" -- the SAME
* last-RE is reused by `s//repl/` and by `g//`). Call this right
* after a call site has already copied its freshly-parsed,
* possibly-empty token into PATBUF (ED_COPYDELIM's own callers,
* or ED_SEARCHFWD's/EX_SEARCHBACK's own copy loops).
*
* IN: PATBUF holds the just-parsed token (NUL at PATBUF means an
* empty `//`/`??`/`s//`/`g//`).
* OUT: carry set = PATBUF now holds a real pattern to search or
* substitute with -- either the fresh non-empty token (and
* LASTPAT is updated to match, becoming the new last-RE), or,
* when the fresh token was empty, LASTPAT copied INTO PATBUF (a
* prior RE existed). carry clear = the fresh token was empty AND
* no prior RE exists (LASTPAT itself empty too) -- callers treat
* this exactly like any other parse failure (`?`, no crash, no
* empty-matches-everything).
* CLOBBERS: A, X, Y, PTR0, PTR1 (STRCPY itself PRESERVES PTR0/
* PTR1's values across the copy, but this routine sets them
* fresh either way, so callers must treat them as clobbered).
*---------------------------------------------------------------
ED_LASTRE   lda   PATBUF
            bne   :lr_have
            lda   LASTPAT
            bne   :lr_uselast
            clc                      ;no fresh token, no prior
                                     ;RE
            rts
:lr_uselast lda   #<LASTPAT
            sta   PTR0
            lda   #>LASTPAT
            sta   PTR0+1
            lda   #<PATBUF
            sta   PTR1
            lda   #>PATBUF
            sta   PTR1+1
            jsr   STRCPY
            sec
            rts
:lr_have    lda   #<PATBUF
            sta   PTR0
            lda   #>PATBUF
            sta   PTR0+1
            lda   #<LASTPAT
            sta   PTR1
            lda   #>LASTPAT
            sta   PTR1+1
            jsr   STRCPY
            sec
            rts

*---------------------------------------------------------------
* Substitution engine (`s` and `g...` do not share verbs beyond
* both using RE_MATCH -- only `s` uses the routines below).
*---------------------------------------------------------------

* write A into SUBSCR at the running ED_SUBOUT cursor; silently
* stops growing past 254 bytes -- ED_SUBOUT is used as an 8-bit
* Y index into SUBSCR here, which is this routine's OWN limit
* (SUBSCR itself is SUBSCR_MAXLEN=512). It used to be blamed on
* liba's STRLEN 255-byte cap; that cap is gone since 2026-08-22
* and this one is not, so the two are not the same limit and
* never were.
ED_SUBPUTCHAR
            ldy   ED_SUBOUT
            cpy   #254
            bcs   :capped
            sta   SUBSCR,y
            inc   ED_SUBOUT
:capped     rts

* copy (ED_SUBCUR) forward until ED_SUBCUR == ED_TMP16B
* (exclusive)
ED_SBCPY_VERB
:loop       lda   ED_SUBCUR
            cmp   ED_TMP16B
            bne   :go
            lda   ED_SUBCUR+1
            cmp   ED_TMP16B+1
            bne   :go
            rts
:go         ldy   #0
            lda   (ED_SUBCUR),y
            jsr   ED_SUBPUTCHAR
            inc   ED_SUBCUR
            bne   :loop
            inc   ED_SUBCUR+1
            bra   :loop

* copy (ED_SUBCUR) forward until its own NUL (not copied)
ED_SBCPY_TND
:loop       ldy   #0
            lda   (ED_SUBCUR),y
            beq   :done
            jsr   ED_SUBPUTCHAR
            inc   ED_SUBCUR
            bne   :loop
            inc   ED_SUBCUR+1
            bra   :loop
:done       rts

* expand REPLBUF (raw, with escapes undecoded) into SUBSCR: '&'
* -> the matched substring [RE_MSTART,RE_MEND); '\X' -> literal
* X (so '\&' is a literal ampersand, '\\' a literal backslash);
* anything else, verbatim.
ED_SBXPND_RPL
            lda   #<REPLBUF
            sta   PTR1
            lda   #>REPLBUF
            sta   PTR1+1
:loop       ldy   #0
            lda   (PTR1),y
            beq   :done
            cmp   #"&"
            beq   :doamp
            cmp   #"\"
            beq   :doesc
            jsr   ED_SUBPUTCHAR
            inc   PTR1
            bne   :loop
            inc   PTR1+1
            bra   :loop
:doamp      lda   RE_MSTART
            sta   PTR2
            lda   RE_MSTART+1
            sta   PTR2+1
:amploop    lda   PTR2
            cmp   RE_MEND
            bne   :ampgo
            lda   PTR2+1
            cmp   RE_MEND+1
            bne   :ampgo
            bra   :ampdone
:ampgo      ldy   #0
            lda   (PTR2),y
            jsr   ED_SUBPUTCHAR
            inc   PTR2
            bne   :amploop
            inc   PTR2+1
            bra   :amploop
:ampdone    inc   PTR1
            bne   :loop
            inc   PTR1+1
            bra   :loop
:doesc      ldy   #1
            lda   (PTR1),y
            beq   :escend
            jsr   ED_SUBPUTCHAR
            clc
            lda   PTR1
            adc   #2
            sta   PTR1
            lda   PTR1+1
            adc   #0
            sta   PTR1+1
            bra   :loop
:escend     lda   #"\"
            jsr   ED_SUBPUTCHAR
            inc   PTR1
            bne   :loop
            inc   PTR1+1
            bra   :loop
:done       rts

*---------------------------------------------------------------
* ED_DO_SUBST -- attempt (per current PATBUF/REPLBUF/ED_SFLAGG)
* a substitution on line ED_TMP16 (preserved across this call).
* OUT: carry set = the line matched and was rewritten
* (ED_CURLINE updated, printed if ED_SFLAGP); carry clear = no
* match on this line (untouched).
*---------------------------------------------------------------
ED_DO_SUBST jsr   ED_LINETEXT
            lda   ED_TMP16
            sta   ED_SUBLINE
            lda   ED_TMP16+1
            sta   ED_SUBLINE+1
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            lda   PTR0
            sta   ED_SUBCUR
            lda   PTR0+1
            sta   ED_SUBCUR+1
            lda   #<SUBSCR
            sta   ED_DST
            lda   #>SUBSCR
            sta   ED_DST+1
            stz   ED_SUBOUT
            stz   ED_SUBOUT+1
            stz   ED_SUBHIT
            stz   ED_SUBOCC          ;ed s///N: per-line
            stz   ED_SUBOCC+1        ;occurrence counter
            lda   ED_SRC
            sta   PTR2
            lda   ED_SRC+1
            sta   PTR2+1

:searchagain
            lda   ED_SRC
            sta   PTR0
            lda   ED_SRC+1
            sta   PTR0+1
            lda   #<PATBUF
            sta   PTR1
            lda   #>PATBUF
            sta   PTR1+1
            jsr   RE_MATCH
            bcs   :nomorematch
            lda   RE_MSTART
            sta   ED_TMP16B
            lda   RE_MSTART+1
            sta   ED_TMP16B+1
            jsr   ED_SBCPY_VERB       ;copy the gap up to the
                                      ;match verbatim (both
                                      ;modes)
            lda   #ED_SNUM_LINES      ;ex/vi: a trailing N is a
            bne   :sub_doit           ;LINE COUNT (range set in
                                      ;ED_S_APPLY) -- every line
                                      ;does a normal first-match
                                      ;sub here. ed: N is the
                                      ;Nth OCCURRENCE in a line,
                                      ;counted below.
            lda   ED_SFLAGN
            beq   :sub_doit           ;ed, no N -- always
                                      ;substitute
            inc   ED_SUBOCC
            bne   :socc_nc
            inc   ED_SUBOCC+1
:socc_nc    lda   ED_SUBOCC
            cmp   ED_SNUM
            bne   :sub_skip
            lda   ED_SUBOCC+1
            cmp   ED_SNUM+1
            beq   :sub_doit           ;this IS the Nth match

:sub_skip   ;not yet the Nth -- copy the match text verbatim
            ;(leave the line unchanged) and keep scanning
            lda   RE_MEND
            sta   ED_TMP16B
            lda   RE_MEND+1
            sta   ED_TMP16B+1
            jsr   ED_SBCPY_VERB
            bra   :zladvance
:sub_doit   lda   #1
            sta   ED_SUBHIT
            jsr   ED_SBXPND_RPL
            lda   RE_MEND
            sta   ED_SUBCUR
            lda   RE_MEND+1
            sta   ED_SUBCUR+1
            lda   ED_SFLAGG
            beq   :nomorematch        ;no g (and N, if set, is
                                      ;mutually exclusive with g
                                      ;-- ED_CMD_S enforces
                                      ;that) -- stop after this
                                      ;one

:zladvance  lda   RE_MEND
            cmp   RE_MSTART
            bne   :advancepos
            lda   RE_MEND+1
            cmp   RE_MSTART+1
            bne   :advancepos
            ldy   #0
            lda   (RE_MEND),y
            beq   :nomorematch
            jsr   ED_SUBPUTCHAR
            inc   ED_SUBCUR
            bne   :advancepos
            inc   ED_SUBCUR+1
:advancepos lda   ED_SUBCUR
            sta   PTR2
            lda   ED_SUBCUR+1
            sta   PTR2+1
            jmp   :searchagain

:nomorematch
            lda   ED_SUBHIT
            bne   :hadhit
            clc
            rts
:hadhit     jsr   ED_SBCPY_TND
            ldy   ED_SUBOUT
            lda   #0
            sta   SUBSCR,y
            lda   #<SUBSCR
            sta   ED_SRC
            lda   #>SUBSCR
            sta   ED_SRC+1
            lda   ED_SUBOUT
            jsr   ED_BUMP_ALLOC
            lda   ED_SUBLINE
            sta   ED_TMP16
            lda   ED_SUBLINE+1
            sta   ED_TMP16+1
            bcs   :oomsub
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            jsr   ED_SETSLOT
            lda   ED_TMP16
            sta   ED_CURLINE
            lda   ED_TMP16+1
            sta   ED_CURLINE+1
            lda   ED_SFLAGP
            beq   :noprint
            jsr   ED_LINETEXT
            jsr   ED_PUTLINE
:noprint    sec
            rts
:oomsub     jsr   ED_ERR
            clc
            rts

*---------------------------------------------------------------
* ED_CMD_S -- s/re/repl/[flags]. `/` is the only delimiter (v1
* -- header).
*---------------------------------------------------------------
*---------------------------------------------------------------
* ED_CMD_AMP -- `&`: repeat the last substitution (POSIX ex) on
* addressed line (default `.`), reusing the last RE (LASTPAT),
* last replacement (REPLBUF, still held from the last `s`), and
* last flags. `?` if there is no prior substitution (LASTPAT
* (2026-09-05, check_posixex.)
*---------------------------------------------------------------
ED_CMD_AMP  lda   LASTPAT
            bne   :amp_have
            jmp   ED_ERR_JMP
:amp_have   ldy   #0                  ;LASTPAT -> PATBUF
:amp_cp     lda   LASTPAT,y
            sta   PATBUF,y
            beq   :amp_done
            iny
            bra   :amp_cp
:amp_done   jmp   ED_S_APPLY

ED_CMD_S    ldy   #0
            lda   (ED_CMDPTR),y
            cmp   #"/"
            beq   :toerr17
            jmp   ED_ERR_JMP
:toerr17
            inc   ED_CMDPTR
            bne   :s1
            inc   ED_CMDPTR+1
:s1         lda   #<PATBUF
            sta   ED_DST
            lda   #>PATBUF
            sta   ED_DST+1
            jsr   ED_COPYDELIM
            jsr   ED_LASTRE           ;empty search field ->
                                     ;reuse LASTPAT, or `?` if
                                     ;there is none (2026-09-02)
            bcs   :toerr17b
            jmp   ED_ERR_JMP
:toerr17b   lda   #<REPLBUF
            sta   ED_DST
            lda   #>REPLBUF
            sta   ED_DST+1
            jsr   ED_COPYDELIM
            stz   ED_SFLAGG
            stz   ED_SFLAGP
            stz   ED_SFLAGN           ;2026-08-19: finding 1
:flagloop   ldy   #0
            lda   (ED_CMDPTR),y
            beq   :flagsdone
            cmp   #"g"
            bne   :sfnotg
            lda   #1
            sta   ED_SFLAGG
            bra   :flagnext
:sfnotg     cmp   #"p"
            bne   :sfnotp
            lda   #1
            sta   ED_SFLAGP
            bra   :flagnext
:sfnotp     cmp   #"0"
            bcc   :sflagbad
            cmp   #"9"+1
            bcs   :sflagbad
            jsr   ED_PARSENUM         ;advances ED_CMDPTR itself
                                      ;past every digit -- don't
                                      ;also fall into
                                      ;:flagnext's own increment
            lda   ED_TMP16
            sta   ED_SNUM
            lda   ED_TMP16+1
            sta   ED_SNUM+1
            lda   #1
            sta   ED_SFLAGN
            bra   :flagloop
:sflagbad   ;2026-08-19: an unrecognized flag character used to
            ;be silently skipped (the audit's finding 1) -- any
            ;byte here that isn't g/p/a digit is now a hard `?`.
            jmp   ED_ERR_JMP
:flagnext   inc   ED_CMDPTR
            bne   :fnb
            inc   ED_CMDPTR+1
:fnb        bra   :flagloop
:flagsdone  lda   #ED_SNUM_LINES      ;FF5 2026-09-06: ex/vi's N
            bne   :sf_gnok            ;is a LINE COUNT, not the
                                      ;Nth-occurrence N ed means
                                      ;-- g and a line count
                                      ;compose fine (ED_DO_SUBST
                                      ;globalizes WITHIN each
                                      ;line regardless of N), so
                                      ;only ed keeps the mutual-
                                      ;exclusion refusal below
            lda   ED_SFLAGG            ;ed: g and N are mutually
            beq   :sf_gnok             ;exclusive (finding 1)
            lda   ED_SFLAGN
            beq   :sf_gnok
            jmp   ED_ERR_JMP
:sf_gnok
* ED_S_APPLY -- the substitute APPLY tail (default address,
* check, per-line ED_DO_SUBST loop). Entered by ED_CMD_S after
* parses pattern/replacement/flags, and by ED_CMD_AMP (`&`)
* it reuses the last RE + replacement + flags. IN:
* ED_SFLAG* set; ADDR from the command line (defaults to `.`).
ED_S_APPLY  jsr   ED_DFLT_DTDT
            lda   #ED_SNUM_LINES      ;ed: N is Nth-occurrence,
            beq   :sa_norange         ;handled per-line in
                                      ;ED_DO_SUBST -- no range
                                      ;change here
            lda   ED_SFLAGN           ;ex/vi s///N: a trailing
            beq   :sa_norange         ;number is a LINE COUNT --
                                      ;run the substitution over
                                      ;N lines from the LAST
                                      ;addressed line
            lda   ED_ADDR2
            sta   ED_ADDR1
            lda   ED_ADDR2+1
            sta   ED_ADDR1+1
            lda   ED_SNUM
            sta   ED_TMP16
            lda   ED_SNUM+1
            sta   ED_TMP16+1
            jsr   ED_ENDFROMCNT
:sa_norange jsr   ED_CHC_RNG12N
            bcc   :toerr18
            jmp   ED_ERR_JMP
:toerr18
            stz   ED_DIDANY
            lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
:sloop      jsr   ED_DO_SUBST
            bcc   :nohit2
            lda   #1
            sta   ED_DIDANY
:nohit2     lda   ED_TMP16
            cmp   ED_ADDR2
            bne   :snext
            lda   ED_TMP16+1
            cmp   ED_ADDR2+1
            bne   :snext
            bra   :sdone
:snext      inc   ED_TMP16
            bne   :snb
            inc   ED_TMP16+1
:snb        bra   :sloop
:sdone      lda   ED_DIDANY
            bne   :shappy
            jsr   ED_ERR
:shappy     jmp   MAINLOOP

*---------------------------------------------------------------
* ED_ENDFROMCNT -- IN: ED_ADDR1 = start line, ED_TMP16 = a line
* COUNT (0 is treated as 1). OUT: ED_ADDR2 = start+count-1,
* clamped to ED_NLINES (so a count past EOF stops at `$`, not a
* range error). Shared by s///N (ED_S_APPLY) and z (excmd.s's
* EX_CWIN). CLOBBERS: A.
*---------------------------------------------------------------
ED_ENDFROMCNT
            lda   ED_TMP16
            ora   ED_TMP16+1
            bne   :ec_pos
            lda   #1                 ;a 0 count means 1 line
            sta   ED_TMP16
:ec_pos     clc                      ;ADDR2 = ADDR1 + count
            lda   ED_ADDR1
            adc   ED_TMP16
            sta   ED_ADDR2
            lda   ED_ADDR1+1
            adc   ED_TMP16+1
            sta   ED_ADDR2+1
            lda   ED_ADDR2           ;   - 1
            bne   :ec_dec
            dec   ED_ADDR2+1
:ec_dec     dec   ED_ADDR2
            lda   ED_ADDR2+1         ;clamp to ED_NLINES
            cmp   ED_NLINES+1
            bcc   :ec_ok
            bne   :ec_clamp
            lda   ED_ADDR2
            cmp   ED_NLINES
            bcc   :ec_ok
            beq   :ec_ok
:ec_clamp   lda   ED_NLINES
            sta   ED_ADDR2
            lda   ED_NLINES+1
            sta   ED_ADDR2+1
:ec_ok      rts

*---------------------------------------------------------------
* ED_GDFLT_RNG -- like ED_DFLT_DTDT but the 0-address
* default is `1,$` (the whole buffer), per `g`'s own classic
* default.
*---------------------------------------------------------------
ED_GDFLT_RNG
            lda   ED_ADDRCNT
            bne   :have1g
            lda   #1
            sta   ED_ADDR1
            stz   ED_ADDR1+1
            lda   ED_NLINES
            sta   ED_ADDR2
            lda   ED_NLINES+1
            sta   ED_ADDR2+1
            rts
:have1g     cmp   #1
            bne   :have2g
            lda   ED_ADDR1
            sta   ED_ADDR2
            lda   ED_ADDR1+1
            sta   ED_ADDR2+1
:have2g     rts
