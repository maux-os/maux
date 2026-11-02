*---------------------------------------------------------------
* visearch.s -- vi's `/` `?` `n` `N` search (docs/VI-DESIGN.md
* sec 4.1). `put` by vi.s ONLY, after vicmd.s. Prompts on the
* status line (VI_READPAT, the SAME echo-it-yourself idiom
* VI_COLON already uses -- tty echo is off), then matches
* CHARACTER-precise, wrapping the whole buffer by default (the
* primary source's `wrap` option, default ON --
* learning:01M1FX8HT89CKR9CB8T8VKCW1S), directly against
* RE_MATCH over ED_LINETEXT lines. The typed/reused pattern
* goes through edsubst.s's ED_LASTRE/LASTPAT -- the SAME "last
* regular expression" `:s//` and ex's own `/re/`/`?re?` address
* tokens already share, so a search typed here is immediately
* the `//` target of a later `:s//x/` and vice versa.
*
* Depends on: ED_LINETEXT (exbuf.s, read-only), RE_MATCH
* (liba/regex.s -- PTR0/PTR1/PTR2 in, RE_MSTART/RE_MEND out),
* ED_LASTRE (edsubst.s), PATBUF/LASTPAT (vi.s bss, unchanged),
* VI_RAWKEY/VI_CSI_POS/VI_ERSLN/VI_STATUS_MSG/VI_PLACE_CUR/
* VI_REPAINT (vicmd.s/viscreen.s). Does NOT touch vimotion.s --
* VI_SRCH_LAND below is its own small window-visibility check,
* not a reuse of VI_SCROLL_DN/UP (those assume a KNOWN
* direction; a search can land anywhere).
*---------------------------------------------------------------

*---------------------------------------------------------------
* VI_LMATCH_FWD -- try PATBUF against line ED_TMP16's own text,
* scanning forward from column A (0-based; A == the line's own
* length is safe -- lands on the NUL, RE_MATCH's own "no more
* room" case). OUT: carry clear + VI_MCOL = the match's 0-based
* start column; carry set = no match on this one line.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2 (+ RE_MATCH's own
* regex.equ scratch).
*---------------------------------------------------------------
VI_LMATCH_FWD
            sta   VI_SCOL                ;survive ED_LINETEXT's
                                        ;own A/X/Y clobber
            jsr   ED_LINETEXT           ;PTR0 = line text
            lda   #<PATBUF
            sta   PTR1
            lda   #>PATBUF
            sta   PTR1+1
            clc
            lda   PTR0
            adc   VI_SCOL
            sta   PTR2
            lda   PTR0+1
            adc   #0
            sta   PTR2+1                 ;PTR2 = PTR0+VI_SCOL --
                                        ;PTR0 stays the TRUE
                                        ;line start, so a `^` in
                                        ;the pattern still
                                        ;anchors correctly even
                                        ;when the scan itself
                                        ;starts mid-line
            jsr   RE_MATCH
            bcs   :nf
            sec
            lda   RE_MSTART
            sbc   PTR0                   ;RE_MATCH never writes
            sta   VI_MCOL                ;PTR0 (regex.s: read-
                                        ;only) -- still the line
                                        ;start here
            clc
            rts
:nf         sec
            rts

*---------------------------------------------------------------
* VI_LMATCH_BK -- rightmost match of PATBUF within line
* ED_TMP16's own text, at a start column STRICTLY LESS than A
* (the boundary, 0-254; pass 255 for "anywhere in the line", the
* full-wrap case). Regex has no backward primitive, so this
* calls RE_MATCH repeatedly, advancing past each hit, keeping
* the last one before the boundary -- the same "call it as many
* times as it takes" shape excmd.s's own g/v pass already uses
* for a whole-buffer scan. OUT: carry clear + VI_MCOL = that
* match's 0-based start column; carry set = none strictly before
* the boundary. CLOBBERS: A, X, Y, PTR0, PTR1, PTR2, VI_MFLAG
* (+ RE_MATCH's own scratch).
*---------------------------------------------------------------
VI_LMATCH_BK
            sta   VI_SCOL                ;boundary (exclusive)
            jsr   ED_LINETEXT           ;PTR0 = line text
            lda   #<PATBUF
            sta   PTR1
            lda   #>PATBUF
            sta   PTR1+1
            lda   PTR0
            sta   PTR2
            lda   PTR0+1
            sta   PTR2+1                 ;scan starts at col 0
            stz   VI_MFLAG
:loop       jsr   RE_MATCH
            bcs   :done
            sec
            lda   RE_MSTART
            sbc   PTR0
            cmp   VI_SCOL
            bcs   :done                  ;this hit, and every
                                        ;later one (scan only
                                        ;moves forward), is >=
                                        ;the boundary -- stop,
                                        ;keep whatever was found
            sta   VI_MCOL                ;rightmost-so-far
            lda   #1
            sta   VI_MFLAG
            lda   RE_MEND                ;advance past this
            sta   PTR2                   ;hit's END, so a LONGER
            lda   RE_MEND+1              ;match makes progress
            sta   PTR2+1
            lda   RE_MEND
            cmp   RE_MSTART
            bne   :adv
            lda   RE_MEND+1
            cmp   RE_MSTART+1
            bne   :adv
            inc   PTR2                   ;zero-length match --
            bne   :adv                   ;bump by 1 so the next
            inc   PTR2+1                 ;try makes progress too
:adv        bra   :loop
:done       lda   VI_MFLAG
            beq   :nf
            clc
            rts
:nf         sec
            rts

*---------------------------------------------------------------
* VI_READPAT -- prompt on the status line with the delimiter
* char in A (`/` or `?`), read raw bytes into PATBUF (VI_INSLEN
* as the running length -- the SAME "`:` mode and insert mode
* never overlap" reuse VI_COLON's own header already
* established; search overlaps with neither either) until
* RETURN, ESC, or a read error (^C aborts). RETURN NUL-
* terminates PATBUF and hands it to ED_LASTRE: empty reuses
* LASTPAT. OUT: carry clear = PATBUF ready to search with; carry
* set = user aborted, OR typed empty with no prior search (this
* branch alone status-msg's "No previous regular expression",
* so `/` `?` `n` `N` all get it for free). CLOBBERS: A, X, Y,
* PTR0, PTR1, VI_INSLEN (+ VI_STATUS_MSG/VI_CSI_POS/VI_ERSLN).
*---------------------------------------------------------------
VI_READPAT  sta   VI_SCOL                  ;delimiter -- parked
                                        ;here, not the stack
            lda   VI_ROWS
            ldx   #1
            jsr   VI_CSI_POS
            lda   VI_SCOL
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   VI_ERSLN
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH
            stz   VI_INSLEN
:rd         jsr   VI_RAWKEY
            bcs   :abort
            cmp   #$8D                   ;CR
            beq   :done
            cmp   #$9B                   ;ESC
            beq   :abort
            cmp   #VI_KLEFT              ;left-arrow (^H) / DEL
            beq   :erase                 ;erase (vicmd.s
            cmp   #$FF                   ;VI_LNERASE); other
            beq   :erase                 ;framed arrows ignored
            cmp   #$80
            bcc   :rd
            ldy   VI_INSLEN
            cpy   #PATBUF_MAXLEN-1
            bcs   :rd                    ;full -- drop the byte
            sta   PATBUF,y
            inc   VI_INSLEN
            ldx   #FD_STDOUT
            jsr   PUTC
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH
            bra   :rd
:erase      jsr   VI_LNERASE
            bra   :rd
:done       ldy   VI_INSLEN
            lda   #0
            sta   PATBUF,y
            jsr   ED_LASTRE               ;its sense is carry
                                        ;SET=success -- OPPOSITE
                                        ;of this routine's own
                                        ;(clear=ready), inverted
            bcs   :ok
:nopat      lda   #<VI_NOPAT_MSG
            sta   PTR0
            lda   #>VI_NOPAT_MSG
            sta   PTR0+1
            jsr   VI_STATUS_MSG
            sec
            rts
:ok         clc
            rts
:abort      sec
            rts

*---------------------------------------------------------------
* VI_SRCH_LAND -- common tail once ED_CURLINE/VI_CURCOL have
* been set to a match: repaint if the new line fell outside the
* visible window (VI-DESIGN sec 2.2's v1 "any scroll is a full
* repaint" rule), else just place the cursor. A search can jump
* either direction or wrap, so this is its own direction-
* agnostic visibility check -- NOT vimotion.s's VI_SCROLL_DN/UP
* (each of those assumes a known direction of travel).
* CLOBBERS: A, X, Y, PTR0, ED_TMP16, VI_TMP, VI_TMP2 (+
* viscreen.s's own repaint/place clobbers).
*---------------------------------------------------------------
VI_SRCH_LAND
            lda   VI_NOLAND              ;an operator's search
            beq   :land                ;(VI_SMO_*) wants the
            rts                          ;position, not the move
:land       lda   ED_CURLINE+1
            cmp   VI_TOP+1
            bcc   :out                   ;curline < top -- out
            bne   :chkhi
            lda   ED_CURLINE
            cmp   VI_TOP
            bcc   :out
:chkhi      lda   VI_ROWS
            sec
            sbc   #1
            sta   VI_TMP2                ;textrows
            clc
            lda   VI_TOP
            adc   VI_TMP2
            sta   VI_TMP
            lda   VI_TOP+1
            adc   #0
            sta   VI_TMP+1               ;VI_TMP = top+textrows
            lda   ED_CURLINE+1
            cmp   VI_TMP+1
            bcc   :in
            bne   :out
            lda   ED_CURLINE
            cmp   VI_TMP
            bcc   :in
:out        lda   ED_CURLINE             ;out -- curline becomes
            sta   VI_TOP                 ;the new top (same
            lda   ED_CURLINE+1           ;choice vimotion.s's
            sta   VI_TOP+1               ;own SCROLL_UP makes)
            jmp   VI_REPAINT
:in         jmp   VI_PLACE_CUR

*---------------------------------------------------------------
* VI_SRCH_NOMT -- "Pattern not found": status message only, no
* cursor movement, no crash (the wrap-around search below tried
* every line exactly once and came up empty).
*---------------------------------------------------------------
VI_SRCH_NOMT
            lda   #<VI_NOMTCH_MSG
            sta   PTR0
            lda   #>VI_NOMTCH_MSG
            sta   PTR0+1
            jmp   VI_STATUS_MSG

*---------------------------------------------------------------
* VI_DOSRCH_FWD -- forward wrap-around search from ED_CURLINE/
* VI_CURCOL using whatever PATBUF already holds (VI_READPAT/
* ED_LASTRE already ran). Tries the current line from
* VI_CURCOL+1 first (matches LATER on the same line), then walks
* every other line once, wrapping NLINES -> 1 (mirrors
* ED_SEARCHFWD's own loop shape, edparse.s), then one last full-
* line try of the current line (catches a match EARLIER on it --
* the wraparound-complete-circle case). CLOBBERS: A, X, Y, PTR0,
* PTR1, PTR2, ED_TMP16, ED_TMP16B, VI_SCOL, VI_MCOL (+
* VI_SRCH_LAND's own).
*---------------------------------------------------------------
VI_DOSRCH_FWD
            lda   ED_NLINES
            ora   ED_NLINES+1
            bne   :havelines
            jmp   VI_SRCH_NOMT
:havelines  lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            lda   VI_CURCOL
            clc
            adc   #1
            jsr   VI_LMATCH_FWD
            bcc   :hit

            lda   ED_NLINES
            sta   ED_TMP16B
            lda   ED_NLINES+1
            sta   ED_TMP16B+1
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
:tryline    inc   ED_TMP16
            bne   :chkwrap
            inc   ED_TMP16+1
:chkwrap    lda   ED_TMP16+1
            cmp   ED_NLINES+1
            bcc   :nowrap
            bne   :dowrap
            lda   ED_TMP16
            cmp   ED_NLINES
            bcc   :nowrap
            beq   :nowrap
:dowrap     lda   #1
            sta   ED_TMP16
            stz   ED_TMP16+1
:nowrap     lda   #0
            jsr   VI_LMATCH_FWD          ;whole line, col 0
            bcc   :hit
            lda   ED_TMP16B
            bne   :dec1
            dec   ED_TMP16B+1
:dec1       dec   ED_TMP16B
            lda   ED_TMP16B
            ora   ED_TMP16B+1
            bne   :tryline
            jmp   VI_SRCH_NOMT
:hit        lda   ED_TMP16
            sta   ED_CURLINE
            lda   ED_TMP16+1
            sta   ED_CURLINE+1
            lda   VI_MCOL
            sta   VI_CURCOL
            jmp   VI_SRCH_LAND

*---------------------------------------------------------------
* VI_DOSRCH_BK -- backward wrap-around search, symmetric to
* VI_DOSRCH_FWD: tries the current line for a match strictly
* BEFORE VI_CURCOL first, then walks every other line once
* (mirrors EX_SEARCHBACK's own decrement-and-wrap loop,
* excmd.s), then one last unrestricted try of the current line
* (boundary 255 -- also covers the wraparound-complete-circle
* case, a match at or after VI_CURCOL). CLOBBERS: same as
* VI_DOSRCH_FWD.
*---------------------------------------------------------------
VI_DOSRCH_BK
            lda   ED_NLINES
            ora   ED_NLINES+1
            bne   :havelines
            jmp   VI_SRCH_NOMT
:havelines  lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            lda   VI_CURCOL
            jsr   VI_LMATCH_BK
            bcc   :hit

            lda   ED_NLINES
            sta   ED_TMP16B
            lda   ED_NLINES+1
            sta   ED_TMP16B+1
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
:tryline    lda   ED_TMP16
            bne   :dec
            dec   ED_TMP16+1
:dec        dec   ED_TMP16
            lda   ED_TMP16
            ora   ED_TMP16+1
            bne   :nowrap
            lda   ED_NLINES
            sta   ED_TMP16
            lda   ED_NLINES+1
            sta   ED_TMP16+1
:nowrap     lda   #255
            jsr   VI_LMATCH_BK           ;whole line, no bound
            bcc   :hit
            lda   ED_TMP16B
            bne   :dec1
            dec   ED_TMP16B+1
:dec1       dec   ED_TMP16B
            lda   ED_TMP16B
            ora   ED_TMP16B+1
            bne   :tryline
            jmp   VI_SRCH_NOMT
:hit        lda   ED_TMP16
            sta   ED_CURLINE
            lda   ED_TMP16+1
            sta   ED_CURLINE+1
            lda   VI_MCOL
            sta   VI_CURCOL
            jmp   VI_SRCH_LAND

*---------------------------------------------------------------
* VI_SRCH_FWD -- `/`: prompt, read+resolve a pattern, remember
* the direction for `n`/`N`, then search forward.
*---------------------------------------------------------------
VI_SRCH_FWD lda   #"/"
            jsr   VI_READPAT
            bcs   :done
            stz   VI_LASTDIR
            jsr   VI_DOSRCH_FWD
:done       rts

*---------------------------------------------------------------
* VI_SRCH_BK -- `?`: same as VI_SRCH_FWD but backward.
*---------------------------------------------------------------
VI_SRCH_BK  lda   #"?"
            jsr   VI_READPAT
            bcs   :done
            lda   #1
            sta   VI_LASTDIR
            jsr   VI_DOSRCH_BK
:done       rts

*---------------------------------------------------------------
* VI_SRCH_N -- `n`: repeat the last search, same direction. An
* empty PATBUF forced here always falls through ED_LASTRE to
* LASTPAT (or fails cleanly with "no previous" if there truly
* was none, e.g. `n` before any `/`/`?` ever ran).
*---------------------------------------------------------------
VI_SRCH_N   stz   PATBUF
            jsr   ED_LASTRE               ;carry SET = success
                                        ;(ED_LASTRE's own sense)
            bcs   :ok
            lda   #<VI_NOPAT_MSG
            sta   PTR0
            lda   #>VI_NOPAT_MSG
            sta   PTR0+1
            jmp   VI_STATUS_MSG
:ok         lda   VI_LASTDIR
            bne   :bk
            jmp   VI_DOSRCH_FWD
:bk         jmp   VI_DOSRCH_BK

*---------------------------------------------------------------
* VI_SRCH_NN -- `N`: repeat the last search, OPPOSITE direction.
*---------------------------------------------------------------
VI_SRCH_NN  stz   PATBUF
            jsr   ED_LASTRE               ;carry SET = success
                                        ;(ED_LASTRE's own sense)
            bcs   :ok
            lda   #<VI_NOPAT_MSG
            sta   PTR0
            lda   #>VI_NOPAT_MSG
            sta   PTR0+1
            jmp   VI_STATUS_MSG
:ok         lda   VI_LASTDIR
            bne   :fwd
            jmp   VI_DOSRCH_BK
:fwd        jmp   VI_DOSRCH_FWD

VI_NOPAT_MSG
            asc   "No previous regular expression"
            dfb   0
VI_NOMTCH_MSG
            asc   "Pattern not found"
            dfb   0

*---------------------------------------------------------------
* VI_SMO_PRE/POST -- `/` `?` `n` `N` as an OPERATOR's motion
* (`y/pat`, `d?pat`, `c/pat`): VI_DOMOTION's own first test
* sends
* those four keys here. Runs the ordinary search (prompt and
* all)
* with VI_NOLAND set so it only finds the match, then reads the
* match back as the span end (VI_MO_L1/VI_MO_C1, charwise
* EXCLUSIVE -- vim/POSIX for a search motion) and puts the real
* cursor back. The search tells us nothing but where the cursor
* ended up, so a match at the very spot we started, a miss and
* an
* ESC are all the same thing: no motion (carry set, the operator
* aborts like any refused motion). A count is ignored.
* IN: A = the key. OUT: carry clear + VI_MO_L1/C1/TYPE = target;
* carry set = no motion. CLOBBERS: as VI_SRCH_FWD, + VI_MO_*.
*---------------------------------------------------------------
VI_SMO_PRE
            lda   ED_CURLINE
            sta   VI_SSL
            lda   ED_CURLINE+1
            sta   VI_SSL+1
            lda   VI_CURCOL
            sta   VI_SSC
            lda   #1
            sta   VI_NOLAND
            rts
VI_SMO_POST stz   VI_NOLAND
            lda   VI_CURCOL
            cmp   VI_SSC
            bne   :moved
            lda   ED_CURLINE
            cmp   VI_SSL
            bne   :moved
            lda   ED_CURLINE+1
            cmp   VI_SSL+1
            bne   :moved
            sec                          ;nothing moved
            rts
:moved      lda   ED_CURLINE           ;the match = the span end
            sta   VI_MO_L1
            lda   ED_CURLINE+1
            sta   VI_MO_L1+1
            lda   VI_CURCOL
            sta   VI_MO_C1
            lda   VI_SSL                 ;the cursor goes back
            sta   ED_CURLINE
            lda   VI_SSL+1
            sta   ED_CURLINE+1
            lda   VI_SSC
            sta   VI_CURCOL
            stz   VI_MO_TYPE
            jsr   VI_STAT_BLANK
            clc
            rts
