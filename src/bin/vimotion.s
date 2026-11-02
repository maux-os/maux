*---------------------------------------------------------------
* vimotion.s -- vi's cursor motions (docs/VI-DESIGN.md sec 4.1)
* AND the operator-motion span contract, VI_DOMOTION (this
* task's own addition -- a later stream's operators, d/c/y,
* consume it). `put` by vi.s ONLY, after viscreen.s.
*
* MOTION SET: h j k l (birth slice, unchanged) plus w W b B e E
* (word motions -- lower = punctuation-aware "word", upper =
* whitespace-delimited "WORD"), 0 ^ $ (column/first-non-blank/
* last-char), G (goto line, count = target, none = last line --
* NOT `gg`, excluded per the vi timeline learning, `1G` is the
* period-correct spelling), f F t T ; , (find/till char, and
* repeat/reverse-repeat), and a leading decimal count prefix
* (VI_READCMD, vicmd.s's own VI_LOOP calls it before dispatch).
*
* Every h/j/k/l routine is still self-contained (updates
* ED_CURLINE/VI_CURCOL and repaints directly) -- unchanged from
* the birth slice, deliberately NOT rerouted through VI_DOMOTION
* (see VI_TARG_J/VI_TARG_K's own header for why). Every OTHER
* motion here follows the shared shape the task asked for: one
* "compute the destination" routine, used both ways --
* VI_DOMOTION reports the destination (VI_MO_L1/VI_MO_C1/
* VI_MO_TYPE) without touching the live cursor, and
* VI_GOMOTION (vicmd.s's VI_MOTKEY calls it) applies that same
* destination to ED_CURLINE/VI_CURCOL for command-mode movement.
*
* Depends on: ED_LINETEXT/STRLEN (read-only), ED_NLINES,
* VI_PLACE_CUR/VI_REPAINT (viscreen.s), VI_RAWKEY (vicmd.s --
* forward reference, same as viinsert.s's own call to it,
* already proven safe by that precedent).
*---------------------------------------------------------------

*---------------------------------------------------------------
* VI_CLAMP_COL -- clamp VI_CURCOL to the current line's own
* length (0 on an empty line, else [0, len-1] -- command mode
* never sits PAST the last character, same as real vi). Called
* after any motion that changes ED_CURLINE. CLOBBERS: A, Y,
* PTR0, ED_TMP16, VI_LLEN.
*---------------------------------------------------------------
VI_CLAMP_COL
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN                ;A = length (0-254)
            sta   VI_LLEN
            beq   :zero
            sec
            sbc   #1                    ;A = max valid col
            cmp   VI_CURCOL
            bcs   :done                 ;max_valid >= VI_CURCOL
            sta   VI_CURCOL
            bra   :done
:zero       stz   VI_CURCOL
:done       rts

*---------------------------------------------------------------
* VI_SCROLL_DN -- after ED_CURLINE moved DOWN, move VI_TOP if it
* left the text-row window, else just place the cursor. When the
* window scrolls up by a fraction of a screen AND no line wraps,
* it emits ONE terminal scroll (ESC [ n S) and repaints only the
* exposed bottom rows instead of the whole window -- the partial
* scroll a 300-baud-usable vi needs (VI-DESIGN sec 2.2; the old
* "any scroll is a full repaint" v1 rule is retired for the
* common case). CLOBBERS: A, X, Y, PTR0, ED_TMP16, VI_TMP,
* VI_TMP2, VI_SCR_SAVT, VI_SCR_DLT (+ viscreen.s clobbers).
*---------------------------------------------------------------
VI_SCROLL_DN
            lda   VI_ROWS
            sec
            sbc   #1
            sta   VI_TMP2               ;textrows (byte -- a
                                        ;window is never >255
                                        ;rows on this hardware)
            sec
            lda   ED_CURLINE
            sbc   VI_TOP
            sta   VI_TMP
            lda   ED_CURLINE+1
            sbc   VI_TOP+1
            sta   VI_TMP+1              ;VI_TMP = curline - top
            lda   VI_TMP+1
            bne   :scroll                ;hi byte set -> way
                                        ;past the window
            lda   VI_TMP
            cmp   VI_LNCNT               ;offset < lines PAINTED
            bcc   :norepaint             ;-- visible (wrap:
                                        ;VI_REPAINT's VI_FITCUR
                                        ;settles the exact top)
:scroll     lda   VI_TOP                 ;save old top -- the
            sta   VI_SCR_SAVT        ;delta = new - old top
            lda   VI_TOP+1               ;new top - old top
            sta   VI_SCR_SAVT+1
            lda   ED_CURLINE             ;VI_TOP = curline -
            sec                          ;textrows + 1 (last
            sbc   VI_TMP2                ;visible row becomes
            sta   VI_TOP                 ;the new bottom)
            lda   ED_CURLINE+1
            sbc   #0
            sta   VI_TOP+1
            inc   VI_TOP
            bne   :nb
            inc   VI_TOP+1
*-- PARTIAL SCROLL (docs/VI-DESIGN.md sec 2.2). A full repaint
*-- per scrolled line is the 300-baud sin real vi never commits.
*-- If the window has no WRAPPED line (VI_LNCNT == textrows: one
*-- row per line) and it moved up by less than a screen, emit
*-- ONE terminal scroll (ESC [ delta S -- a CRTC bump on the
*-- card) and repaint ONLY the exposed bottom `delta` rows.
*-- Anything else -- a wrapped window, or a jump of a screen or
*-- more -- falls back to the full repaint, which is then no
*-- more work than the scroll would have been.
:nb         lda   VI_TOP+1               ;same 256-line page as
            cmp   VI_SCR_SAVT+1          ;the old top?
            bne   :full
            sec
            lda   VI_TOP
            sbc   VI_SCR_SAVT            ;delta = new - old top
            bcc   :full                  ;(never negative here)
            beq   :full                  ;no actual move
            cmp   VI_TMP2                ;delta >= textrows: a
            bcs   :full        ;>= screen: full is cheaper
            sta   VI_SCR_DLT
            lda   VI_LNCNT               ;wrapped window? (LNCNT
            cmp   VI_TMP2                ;< textrows means some
            bne   :full                  ;line spans >1 row)
            lda   VI_TMP2                ;k = textrows - delta =
            sec                          ;first exposed row's
            sbc   VI_SCR_DLT             ;visible index
            pha                          ;keep k across the emit
            lda   VI_SCR_DLT
            jsr   VI_EMIT_SU             ;scroll the glass up
            pla                          ;k
            jmp   VI_RPFROM          ;paint the exposed rows
:full       jmp   VI_REPAINT
:norepaint  jmp   VI_PLACE_CUR

*---------------------------------------------------------------
* VI_SCROLL_UP -- symmetric for a motion that moved ED_CURLINE
* UP. A single line up (`k` at the top) into an unwrapped window
* scrolls the glass DOWN one (ESC[nT) and repaints only the new
* top line (VI_RPT_LN) -- the reverse of VI_SCROLL_DN's partial
* scroll. Bigger jumps (Nk) and wrapped windows full-repaint.
* CLOBBERS: same as VI_SCROLL_DN, + VI_SCR_SAVT.
*---------------------------------------------------------------
VI_SCROLL_UP
            lda   ED_CURLINE+1
            cmp   VI_TOP+1
            bcc   :scroll                ;curline < top (hi)
            bne   :norepaint             ;curline > top (hi)
            lda   ED_CURLINE
            cmp   VI_TOP
            bcc   :scroll
            bra   :norepaint
:scroll     lda   VI_TOP                 ;save old top for delta
            sta   VI_SCR_SAVT
            lda   VI_TOP+1
            sta   VI_SCR_SAVT+1
            lda   ED_CURLINE             ;new top = cursor line
            sta   VI_TOP
            lda   ED_CURLINE+1
            sta   VI_TOP+1
*-- PARTIAL SCROLL-UP: delta==1 into an unwrapped window -> one
*-- ESC[1T (glass scrolls DOWN one, top row blank) + repaint the
*-- one new top line. Else the full repaint.
            lda   VI_SCR_SAVT+1          ;same 256-line page?
            cmp   VI_TOP+1
            bne   :full
            sec
            lda   VI_SCR_SAVT            ;delta = old - new top
            sbc   VI_TOP
            cmp   #1                     ;only 1 line = partial
            bne   :full
            lda   VI_ROWS                ;window unwrapped?
            sec
            sbc   #1                     ;textrows
            cmp   VI_LNCNT               ;== lines painted
            bne   :full
            lda   #1
            jsr   VI_EMIT_SD             ;scroll glass down 1
            jmp   VI_RPT_LN              ;draw the new top line
:full       jmp   VI_REPAINT
:norepaint  jmp   VI_PLACE_CUR

*---------------------------------------------------------------
* VI_MOVE_H -- one char left, clamped at column 0. No line/
* window change -- just places the cursor.
*---------------------------------------------------------------
VI_MOVE_H   lda   VI_CURCOL
            beq   :done
            dec   VI_CURCOL
:done       jmp   VI_PLACE_CUR

*---------------------------------------------------------------
* VI_MOVE_L -- one char right, clamped at the last character of
* the current line (never past it, real vi's own command-mode
* rule).
*---------------------------------------------------------------
VI_MOVE_L   lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN                ;A = length
            beq   :done                 ;empty line: col stays 0
            sec
            sbc   #1                    ;A = max valid col
            cmp   VI_CURCOL
            bcc   :done
            beq   :done                 ;already at the last
                                        ;char
            inc   VI_CURCOL
:done       jmp   VI_PLACE_CUR

*---------------------------------------------------------------
* VI_MOVE_J -- one line down (`.` < `$`), clamping the column to
* the new line's own length, then fixing scroll.
*---------------------------------------------------------------
VI_MOVE_J   lda   ED_CURLINE+1
            cmp   ED_NLINES+1
            bcc   :can
            bne   :done
            lda   ED_CURLINE
            cmp   ED_NLINES
            bcc   :can
            bra   :done
:can        inc   ED_CURLINE
            bne   :nb
            inc   ED_CURLINE+1
:nb         jsr   VI_CLAMP_COL
            jmp   VI_SCROLL_DN
:done       rts

*---------------------------------------------------------------
* VI_MOVE_K -- one line up (`.` > 1), clamping the column, then
* fixing scroll.
*---------------------------------------------------------------
VI_MOVE_K   lda   ED_CURLINE
            ora   ED_CURLINE+1
            beq   :done                 ;empty buffer -- no `.`
            lda   ED_CURLINE+1
            bne   :dec                  ;hi byte set -> >= 256
            lda   ED_CURLINE
            cmp   #2
            bcc   :done                 ;== 1 already -- no move
:dec        lda   ED_CURLINE
            bne   :nb
            dec   ED_CURLINE+1
:nb         dec   ED_CURLINE
            jsr   VI_CLAMP_COL
            jmp   VI_SCROLL_UP
:done       rts

*---------------------------------------------------------------
* VI_CNTNORM -- normalize VI_COUNT: 0 (no count typed) becomes 1
* (repeat once). Motions whose count means something other than
* "repeat N times" (G's count is a target line) do NOT call
* this. CLOBBERS: A.
*---------------------------------------------------------------
VI_CNTNORM  lda   VI_COUNT
            ora   VI_COUNT+1
            bne   :done
            inc   VI_COUNT
:done       rts

*---------------------------------------------------------------
* VI_CNTDIG -- accumulate one decimal digit into VI_COUNT
* (VI_COUNT = VI_COUNT*10 + digit), reusing edparse.s's own
* ED_MUL10 (val*8 + val*2) via ED_TMP16 -- not held live across
* this call by any caller, same "short-lived scratch" discipline
* every reused ED_* cell already follows in this file. IN: A =
* the digit's raw key byte ('0'-'9', high-bit-set per
* VI_RAWKEY). CLOBBERS: A, ED_TMP16, ED_TMP16B.
*---------------------------------------------------------------
VI_CNTDIG   and   #$0F               ;digit value -- low nibble
                                     ;is the same either way
                                     ;(ED_PARSENUM's own trick,
                                     ;edparse.s)
            pha
            lda   VI_COUNT
            sta   ED_TMP16
            lda   VI_COUNT+1
            sta   ED_TMP16+1
            jsr   ED_MUL10
            lda   ED_TMP16
            sta   VI_COUNT
            lda   ED_TMP16+1
            sta   VI_COUNT+1
            pla
            clc
            adc   VI_COUNT
            sta   VI_COUNT
            lda   #0
            adc   VI_COUNT+1
            sta   VI_COUNT+1
            rts

*---------------------------------------------------------------
* VI_READCMD -- vicmd.s's VI_LOOP calls this INSTEAD of
* VI_RAWKEY at the top of every command-mode cycle: reads keys,
* transparently accumulating a leading decimal count prefix into
* VI_COUNT (a leading '1'-'9' then any digits; a bare '0' with
* no count started yet is the column-0 MOTION, not a digit --
* real vi's own rule). OUT: carry clear + A = the first
* non-count-digit key, VI_COUNT left set (0 = none typed) for
* the dispatch that follows; carry set = VI_RAWKEY failed (^C/
* read error) -- VI_COUNT is reset to 0, matching real vi's own
* "abort the pending prefix" ^C behavior (docs/VI-DESIGN.md sec
* 3.1). CLOBBERS: A, X, Y, VI_TMP, ED_TMP16, ED_TMP16B.
*---------------------------------------------------------------
VI_READCMD  stz   VI_COUNT
            stz   VI_COUNT+1
:rd         jsr   VI_RAWKEY
            bcc   :haskey
            jmp   :intr             ;block below outgrew bcs's
                                    ;reach to :intr (framed +
                                    ;unframed arrows, CR/^C
                                    ;disambiguation)
:haskey
*-- ARROW KEYS (2026-09-04, reframed 2026-09-10). TTY_KEYIN
*-- (tty3.s) turns the //e arrows into CSI ESC [ A..D; the raw
*-- cook commits the trio as ONE line (tty7.s) and VI_RAWKEY
*-- hands it back as a single VI_KUP..VI_KLEFT code (vi.s). Map
*-- them to k/j/l/h. An arrow typed INSIDE an insert ends it
*-- and is pushed back through VI_UNGET (viinsert.s :doarrow),
*-- so it lands here as exit-and-move -- except LEFT, which is
*-- the //e's backspace key and erases in insert instead. A
*-- bare ESC is swallowed and consumes nothing -- it arrives
*-- alone now, framing makes read-ahead unnecessary.
*-- RETURN is `+` (2026-09-10): next line, first non-blank --
*-- POSIX vi's <newline>, and for an operator's motion too
*-- (d<CR> deletes two lines).
            cmp   #$9B                ;ESC: swallow
            beq   :rd
            cmp   #$8D                ;RETURN = +
            bne   :ncr
*-- TELL A REAL RETURN FROM A ^C/^Z PHANTOM (2026-09-10). A ^C
*-- or ^Z reaches vi as BOTH a caught-signal pending bit AND an
*-- empty CR line the kernel commits to wake the blocked reader
*-- (tty3.s TTY_INTR). The CR wins the race -- available data
*-- returns before PRC_BLCK_RTRY's ERR_INTR check -- so once
*-- RETURN means `+`, an un-checked CR would move the cursor on
*-- every ^C/^Z. A pending caught signal alongside this CR marks
*-- it the phantom: ^Z suspends, anything else (^C) aborts to a
*-- repaint; no signal = a genuine RETURN = `+`.
            jsr   SC_SIGPEND          ;pop pending signo, 0=none
            cmp   #0                  ;(the wrapper's Z is not
            beq   :realcr             ;A's -- test explicitly)
            cmp   #VI_SIGTSTP
            beq   :dosusp
            jmp   :intr               ;^C &c: abort, repaint
:dosusp     jsr   VI_SUSPEND
            jmp   :intr               ;resumed: repaint (jmp --
                                      ;:intr out of bra range)
:realcr     lda   #"+"
            clc
            rts
:ncr        cmp   #VI_KUP
            bne   :nup
            lda   #"k"
            clc
            rts
:nup        cmp   #VI_KDOWN
            bne   :ndn
            lda   #"j"
            clc
            rts
:ndn        cmp   #VI_KRIGHT
            bne   :nrt
            lda   #"l"
            clc
            rts
:nrt        cmp   #VI_KLEFT
            bne   :unfrm
            lda   #"h"
            clc
            rts
*-- UNFRAMED CSI FALLBACK. The kernel frames a PHYSICAL arrow
*-- (KEYIN pushes ESC [ final three-or-none, so TTY_COOK_RAW
*-- commits them as one line -- VI_K* above). A TYPED escape
*-- ("\x1b[B", a serial terminal, a slow paste) can split across
*-- polls, arriving as the raw bytes ESC, '[' ($DB), final
*-- ($C1..$C4); the ESC was swallowed at :rd, so a lone '[' here
*-- is an arrow tail. Read its final and map it. A '[' + a
*-- non-arrow byte is dropped (swallow, :rd) -- same as the
*-- pre-framing code.
:unfrm      cmp   #$DB                ;'['
            bne   :nocsi
            jsr   VI_RAWKEY
            bcs   :intr
            cmp   #$C1                ;up
            bne   :u2
            lda   #"k"
            clc
            rts
:u2         cmp   #$C2                ;down
            bne   :u3
            lda   #"j"
            clc
            rts
:u3         cmp   #$C3                ;right
            bne   :u4
            lda   #"l"
            clc
            rts
:u4         cmp   #$C4                ;left
            bne   :rd                 ;'[' + non-arrow: swallow
            lda   #"h"
            clc
            rts
:nocsi      cmp   #"1"
            bcc   :maybez
            cmp   #"9"+1
            bcs   :notdig
            jsr   VI_CNTDIG
            bra   :rd
:maybez     cmp   #"0"
            bne   :notdig
            lda   VI_COUNT
            ora   VI_COUNT+1
            bne   :zerodig       ;count pending: digit
            lda   #"0"           ;no count: "0" is the
                                ;motion key -- reload it,
                                ;the VI_COUNT test above
                                ;clobbered A (else VI_LOOP
                                ;dispatches $00, "0" no-ops)
:notdig     clc
            rts
:zerodig    jsr   VI_CNTDIG
            jmp   :rd                ;:rd out of bra range now
:intr       stz   VI_COUNT
            stz   VI_COUNT+1
            sec
            rts

*---------------------------------------------------------------
* VI_CLASS -- classify one raw text byte for word-motion
* purposes. IN: A = the byte (buffer text -- possibly NOT
* high-bit-set, docs/USERLAND.md "file data... might be 7-bit
* ASCII, high-bit-set... or arbitrary binary" -- so this masks
* first, same defensive idiom PARSEPID (kill.s) and viscreen.s's
* own VI_CALC_COL already use for the identical reason). OUT: A
* = 0 blank (space/tab), 1 word (alnum/underscore -- or ANY
* non-blank at all when VI_BIGF is set, folding punct into word
* for the W/B/E "WORD" variants), 2 punct. CLOBBERS: A, Y.
*---------------------------------------------------------------
VI_CLASS    and   #$7F
            cmp   #' '
            beq   :isblnk
            cmp   #9                  ;TAB
            beq   :isblnk
            cmp   #'0'
            bcc   :ispunc
            cmp   #'9'+1
            bcc   :isword
            cmp   #'A'
            bcc   :ispunc
            cmp   #'Z'+1
            bcc   :isword
            cmp   #'_'
            beq   :isword
            cmp   #'a'
            bcc   :ispunc
            cmp   #'z'+1
            bcc   :isword
:ispunc     lda   #2
            bra   :fold
:isword     lda   #1
:fold       ldy   VI_BIGF
            beq   :done
            lda   #1                  ;WORD variant -- punct
                                     ;folds into word
:done       cmp   #0             ;Z/N must reflect the class
                                ;in A, not the VI_BIGF the
                                ;`ldy`+`beq` above last saw:
                                ;bne/beq callers (w/b/e, /)
                                ;test "class==blank" off it.
                                ;Without this a 0 VI_BIGF
                                ;makes non-blanks look blank
                                ;and the scan walks to EOF.
            rts
:isblnk     lda   #0
            rts

*---------------------------------------------------------------
* VI_MO_LDLINE -- IN: VI_MO_L1 = a line number. OUT: PTR0 = that
* line's text (ED_LINETEXT), VI_LLEN = its length (STRLEN).
* Every word/find-motion routine below calls this whenever
* VI_MO_L1 changes (and once at entry) -- cheap enough (the same
* swap-file-read cost model docs/EX-DESIGN.md already priced for
* every other ED_LINETEXT caller) and it keeps PTR0/VI_LLEN
* provably in sync with VI_MO_L1 rather than trusting a stale
* line-crossing to remember to refresh them. CLOBBERS: A, X, Y,
* PTR0, ED_TMP16, VI_LLEN.
*---------------------------------------------------------------
VI_MO_LDLINE
            lda   VI_MO_L1
            sta   ED_TMP16
            lda   VI_MO_L1+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN
            sta   VI_LLEN
            rts

*---------------------------------------------------------------
* VI_MO_ADV1 -- advance the word-motion working position
* (VI_MO_L1/VI_MO_C1) by exactly one character, crossing into
* the next line's column 0 when the current line is exhausted
* (reloading via VI_MO_LDLINE). OUT: carry clear = advanced;
* carry set = already at the end of the buffer (last line, last
* char, or column 0 of an empty last line) -- position clamped
* there, unchanged on a repeat call. CLOBBERS: A, X, Y, PTR0,
* ED_TMP16, VI_LLEN.
*---------------------------------------------------------------
VI_MO_ADV1  lda   VI_MO_C1
            clc
            adc   #1
            cmp   VI_LLEN
            bcs   :xline
            sta   VI_MO_C1
            clc
            rts
:xline      lda   VI_MO_L1+1
            cmp   ED_NLINES+1
            bcc   :nextl
            bne   :atend
            lda   VI_MO_L1
            cmp   ED_NLINES
            bcc   :nextl
:atend      inc   VI_MO_END      ;tell VI_W_OPADJ: clamped
            lda   VI_LLEN
            beq   :atend0
            dec   a
            sta   VI_MO_C1
            sec
            rts
:atend0     stz   VI_MO_C1
            sec
            rts
:nextl      lda   VI_MO_L1
            bne   :nl1
            inc   VI_MO_L1+1
:nl1        inc   VI_MO_L1
            stz   VI_MO_C1
            jsr   VI_MO_LDLINE
            clc
            rts

*---------------------------------------------------------------
* VI_FNB1 -- first non-blank column of line VI_MO_L1 (real vi's
* `^` and its own use by G/every line-goto). OUT: VI_MO_C1 = the
* column (0 if the line is empty or all blank). CLOBBERS: A, X,
* Y, PTR0, ED_TMP16, VI_LLEN.
*---------------------------------------------------------------
VI_FNB1     jsr   VI_MO_LDLINE
            stz   VI_MO_C1
:loop       lda   VI_MO_C1
            cmp   VI_LLEN
            bcs   :ranoff
            ldy   VI_MO_C1
            lda   (PTR0),y
            jsr   VI_CLASS
            bne   :done
            inc   VI_MO_C1
            bra   :loop
:ranoff     stz   VI_MO_C1
:done       rts

*---------------------------------------------------------------
* VI_WFWD1 -- one `w`/`W` step: advance VI_MO_L1/VI_MO_C1 to the
* start of the next word (VI_BIGF selects small/big). If
* currently inside a non-blank run, first skips to the end of
* THIS run (same-line only -- a run never crosses a line
* boundary), then skips blanks (crossing lines via VI_MO_ADV1
* freely) until a non-blank char is found OR a newly-entered
* line turns out to be EMPTY (itself a word stop, real vi's own
* rule) OR the buffer end is reached. CLOBBERS: A, X, Y, PTR0,
* ED_TMP16, VI_LLEN, VI_TMP.
*---------------------------------------------------------------
VI_WFWD1    jsr   VI_MO_LDLINE
            lda   VI_MO_C1
            cmp   VI_LLEN
            bcs   :skip
            ldy   VI_MO_C1
            lda   (PTR0),y
            jsr   VI_CLASS
            beq   :skip
            sta   VI_TMP
:same       lda   VI_MO_C1
            clc
            adc   #1
            cmp   VI_LLEN
            bcs   :sadv
            ldy   VI_MO_C1
            iny
            lda   (PTR0),y
            jsr   VI_CLASS
            cmp   VI_TMP
            bne   :sadv
            inc   VI_MO_C1
            bra   :same
:sadv       inc   VI_MO_C1       ;:same stops ON the run's
                                ;last char; step one PAST it
                                ;so the blank-skip starts at
                                ;the next word, not re-seeing
                                ;the char just skipped (else
                                ;`w` sticks at the word end)
:skip       lda   VI_MO_C1
            cmp   VI_LLEN
            bcc   :chk
            jsr   VI_MO_ADV1
            bcs   :done
            lda   VI_LLEN
            beq   :done                ;empty line -- word stop
            bra   :skip
:chk        ldy   VI_MO_C1
            lda   (PTR0),y
            jsr   VI_CLASS
            bne   :done
            jsr   VI_MO_ADV1
            bcs   :done
            lda   VI_LLEN
            beq   :done
            bra   :skip
:done       rts

*---------------------------------------------------------------
* VI_WFWDN -- repeat VI_WFWD1 VI_COUNT times (caller has already
* normalized VI_COUNT via VI_CNTNORM). CLOBBERS: same as
* VI_WFWD1, + VI_COUNT (consumed).
*---------------------------------------------------------------
VI_WFWDN    jsr   VI_WFWD1
            dec   VI_COUNT
            bne   VI_WFWDN
            lda   VI_COUNT+1
            beq   :done
            dec   VI_COUNT+1
            bra   VI_WFWDN
:done       rts

*---------------------------------------------------------------
* VI_W_OPADJ -- POSIX's adjustments for `w`/`W` as an OPERATOR
* motion (dw/cw/yw), run by VI_DOMOTION after VI_WFWDN. Both
* cases measured 2026-09-05 against vim -u NONE (no nvi here):
* (1) the walk was CLAMPED at the end of the buffer (VI_MO_END,
*     set by VI_MO_ADV1's :atend): the last char must go too,
*     so the exclusive end becomes VI_LLEN, one past it. Before:
*     `dw` on a line's last word left its final char behind
*     ("one two three" -> "one two e").
* (2) the walk ended in COLUMN 0 of a LATER line (the next word
*     starts a new line, or that line is empty): an exclusive
*     motion ending in column 0 is pulled back to the end of
*     the previous line. `dw` on a last word deletes to EOL and
*     never joins ("aa bb"/"cc dd" -> "aa "/"cc dd"); a one-
*     word line is left empty, not deleted (vim: no linewise
*     conversion for w). A count that lands MID-line on a later
*     line still joins, as vi does (`2dw` there -> "aa dd").
* CLOBBERS: A, X, Y, PTR0, ED_TMP16, VI_LLEN, VI_MO_L1/C1.
*---------------------------------------------------------------
VI_W_OPADJ  lda   VI_MO_END
            beq   :wanotend
            lda   VI_LLEN         ;LDLINE'd = the clamped line
            sta   VI_MO_C1
            rts
:wanotend   lda   VI_MO_C1
            bne   :wadone         ;not column 0
            lda   VI_MO_L1
            cmp   ED_CURLINE
            bne   :wapull
            lda   VI_MO_L1+1
            cmp   ED_CURLINE+1
            beq   :wadone         ;same line: nothing to pull
:wapull     lda   VI_MO_L1        ;L1 -= 1
            bne   :wanb
            dec   VI_MO_L1+1
:wanb       dec   VI_MO_L1
            jsr   VI_MO_LDLINE    ;VI_LLEN = that line's length
            lda   VI_LLEN
            sta   VI_MO_C1        ;exclusive end = its EOL
:wadone     rts

*---------------------------------------------------------------
* VI_WBACK1 -- one `b`/`B` step: move VI_MO_L1/VI_MO_C1 back to
* the start of the previous word. Mirrors VI_WFWD1 backward: an
* unconditional one-char step back (crossing into the previous
* line's LAST char if already at column 0 -- landing on an empty
* previous line is itself a word stop), then skip blanks
* backward the same way, then walk back to the START of the
* run now under the cursor (same-line only). No-ops at the very
* start of the buffer. CLOBBERS: A, X, Y, PTR0, ED_TMP16,
* VI_LLEN, VI_TMP.
*---------------------------------------------------------------
VI_WBACK1   jsr   VI_MO_LDLINE
            lda   VI_MO_C1
            bne   :dec
            lda   VI_MO_L1+1
            bne   :prev
            lda   VI_MO_L1
            cmp   #2
            bcc   :done                ;already line 1 col 0
:prev       lda   VI_MO_L1
            bne   :p1
            dec   VI_MO_L1+1
:p1         dec   VI_MO_L1
            jsr   VI_MO_LDLINE
            lda   VI_LLEN
            bne   :pne
            stz   VI_MO_C1
            rts                        ;empty line -- word stop
:pne        lda   VI_LLEN
            sec
            sbc   #1
            sta   VI_MO_C1
            bra   :skip
:dec        dec   VI_MO_C1
:skip       ldy   VI_MO_C1
            lda   (PTR0),y
            jsr   VI_CLASS
            bne   :found
            lda   VI_MO_C1
            bne   :sdec
            lda   VI_MO_L1+1
            bne   :sprev
            lda   VI_MO_L1
            cmp   #2
            bcc   :done                ;buffer start -- land 0
:sprev      lda   VI_MO_L1
            bne   :sp1
            dec   VI_MO_L1+1
:sp1        dec   VI_MO_L1
            jsr   VI_MO_LDLINE
            lda   VI_LLEN
            bne   :sne
            stz   VI_MO_C1
            rts
:sne        lda   VI_LLEN
            sec
            sbc   #1
            sta   VI_MO_C1
            bra   :skip
:sdec       dec   VI_MO_C1
            bra   :skip
:found      sta   VI_TMP
:start      lda   VI_MO_C1
            beq   :done
            ldy   VI_MO_C1
            dey
            lda   (PTR0),y
            jsr   VI_CLASS
            cmp   VI_TMP
            bne   :done
            dec   VI_MO_C1
            bra   :start
:done       rts

*---------------------------------------------------------------
* VI_WBACKN -- repeat VI_WBACK1 VI_COUNT times (normalized).
* CLOBBERS: same as VI_WBACK1, + VI_COUNT (consumed).
*---------------------------------------------------------------
VI_WBACKN   jsr   VI_WBACK1
            dec   VI_COUNT
            bne   VI_WBACKN
            lda   VI_COUNT+1
            beq   :done
            dec   VI_COUNT+1
            bra   VI_WBACKN
:done       rts

*---------------------------------------------------------------
* VI_WEND1 -- one `e`/`E` step: advance VI_MO_L1/VI_MO_C1 to the
* end of the next word. Steps forward one char (VI_MO_ADV1,
* skipping empty lines entirely -- `e` has no "end" on a blank
* line, unlike `w`'s own word-stop rule), keeps stepping through
* blanks, then walks forward to the LAST char of the run now
* found (same-line only). CLOBBERS: A, X, Y, PTR0, ED_TMP16,
* VI_LLEN, VI_TMP.
*---------------------------------------------------------------
VI_WEND1    jsr   VI_MO_LDLINE
            jsr   VI_MO_ADV1
            bcs   :done
:skip       lda   VI_LLEN
            beq   :adv
            ldy   VI_MO_C1
            lda   (PTR0),y
            jsr   VI_CLASS
            bne   :found
:adv        jsr   VI_MO_ADV1
            bcs   :done
            bra   :skip
:found      sta   VI_TMP
:end        lda   VI_MO_C1
            clc
            adc   #1
            cmp   VI_LLEN
            bcs   :done
            ldy   VI_MO_C1
            iny
            lda   (PTR0),y
            jsr   VI_CLASS
            cmp   VI_TMP
            bne   :done
            inc   VI_MO_C1
            bra   :end
:done       rts

*---------------------------------------------------------------
* VI_WENDN -- repeat VI_WEND1 VI_COUNT times (normalized).
* CLOBBERS: same as VI_WEND1, + VI_COUNT (consumed).
*---------------------------------------------------------------
VI_WENDN    jsr   VI_WEND1
            dec   VI_COUNT
            bne   VI_WENDN
            lda   VI_COUNT+1
            beq   :done
            dec   VI_COUNT+1
            bra   VI_WENDN
:done       rts

*---------------------------------------------------------------
* VI_TARG_G -- `G` target: VI_COUNT (0 = none) as a 1-based
* target line, clamped to [1, ED_NLINES]; no count = the last
* line. Column lands on the first non-blank (VI_FNB1), real
* vi's own line-goto convention. VI_MO_L1 must already be seeded
* (VI_DOMOTION's own entry does this for every motion).
* CLOBBERS: A, X, Y, PTR0, ED_TMP16, VI_LLEN.
*---------------------------------------------------------------
VI_TARG_G   lda   VI_COUNT
            ora   VI_COUNT+1
            bne   :expl
            lda   ED_NLINES
            sta   VI_MO_L1
            lda   ED_NLINES+1
            sta   VI_MO_L1+1
            bra   :nb1
:expl       lda   VI_COUNT
            sta   VI_MO_L1
            lda   VI_COUNT+1
            sta   VI_MO_L1+1
            lda   VI_MO_L1+1
            cmp   ED_NLINES+1
            bcc   :ok
            bne   :clamp
            lda   VI_MO_L1
            cmp   ED_NLINES
            bcc   :ok
:clamp      lda   ED_NLINES
            sta   VI_MO_L1
            lda   ED_NLINES+1
            sta   VI_MO_L1+1
:ok
:nb1        jmp   VI_FNB1

*---------------------------------------------------------------
* VI_TARG_J/VI_TARG_K -- `j`/`k` LINEWISE targets for
* VI_DOMOTION only (the future operator stream's `dj`/`dk` etc).
* Command-mode `j`/`k` keeps using VI_MOVE_J/VI_MOVE_K directly
* (unchanged birth-slice code, own scroll handling already
* proven) rather than being rerouted through here -- a
* deliberate, named deviation from full command/VI_DOMOTION
* sharing (docs/VI-DESIGN.md's own directive): the target math
* is four lines, duplicating it is far cheaper than risking the
* tested scroll-integrated routines. VI_MO_C1 is just set to 0
* (linewise operators use the line range, not a column).
* CLOBBERS: A, VI_TMP.
*---------------------------------------------------------------
VI_TARG_J   clc
            lda   VI_MO_L1
            adc   VI_COUNT
            sta   VI_MO_L1
            lda   VI_MO_L1+1
            adc   VI_COUNT+1
            sta   VI_MO_L1+1
            lda   VI_MO_L1+1
            cmp   ED_NLINES+1
            bcc   :ok
            bne   :clamp
            lda   VI_MO_L1
            cmp   ED_NLINES
            bcc   :ok
:clamp      lda   ED_NLINES
            sta   VI_MO_L1
            lda   ED_NLINES+1
            sta   VI_MO_L1+1
:ok         stz   VI_MO_C1
            rts

VI_TARG_K   lda   VI_MO_L1
            sta   VI_TMP
            lda   VI_MO_L1+1
            sta   VI_TMP+1
            sec
            lda   VI_MO_L1
            sbc   VI_COUNT
            sta   VI_MO_L1
            lda   VI_MO_L1+1
            sbc   VI_COUNT+1
            sta   VI_MO_L1+1
            lda   VI_MO_L1+1
            cmp   VI_TMP+1
            bcc   :ok
            bne   :clamp
            lda   VI_MO_L1
            cmp   VI_TMP
            bcc   :ok
:clamp      lda   #1
            sta   VI_MO_L1
            stz   VI_MO_L1+1
:ok         stz   VI_MO_C1
            rts

*---------------------------------------------------------------
* VI_REVCMD -- OUT: A = VI_FCMD's find command with direction
* reversed (f<->F, t<->T), for `,`. Does not touch VI_FCMD
* itself -- a later `;` must still repeat the ORIGINAL
* direction, not whatever `,` last reversed it to.
* CLOBBERS: A.
*---------------------------------------------------------------
VI_REVCMD   lda   VI_FCMD
            cmp   #"f"
            bne   :r1
            lda   #"F"
            rts
:r1         cmp   #"F"
            bne   :r2
            lda   #"f"
            rts
:r2         cmp   #"t"
            bne   :r3
            lda   #"T"
            rts
:r3         lda   #"t"
            rts

*---------------------------------------------------------------
* VI_DOFIND -- the char-search core for f/F/t/T/;/,. IN: A =
* command char ('f'/'F'/'t'/'T' -- callers translate `;`/`,`
* into one of these), VI_FCHAR = target char (already masked to
* 7 bits at capture, see VI_DOMOTION), VI_COUNT = normalized
* repeat count. Searches the CURRENT LINE ONLY (real vi's find/
* till never crosses lines), each repetition continuing from the
* previous hit. OUT: carry clear + VI_MO_C1 set (VI_MO_L1
* unchanged -- same line) on success; carry set = char not found
* (VI_MO_C1 undefined). CLOBBERS: A, X, Y, PTR0, ED_TMP16,
* VI_LLEN, VI_TMP2.
*---------------------------------------------------------------
VI_DOFIND   cmp   #"f"
            beq   :islow
            cmp   #"F"
            beq   :isupp
            cmp   #"t"
            beq   :istil
            lda   #3
            bra   :dirok
:istil      lda   #2
            bra   :dirok
:isupp      lda   #1
            bra   :dirok
:islow      lda   #0
:dirok      sta   VI_TMP2
            jsr   VI_MO_LDLINE
* -- bit 0 of VI_TMP2 is the direction (0 fwd, 1 back): f=0/t=2
* -- forward, F=1/T=3 back. Was `cmp #1 / bcs` -- which routed t
* -- (code 2) to the BACKWARD scan, so `t` never moved forward
* -- (found 2026-09-04 by check_vi).
:rep        lda   VI_TMP2
            lsr
            bcs   :back
            ldy   VI_MO_C1
:fscan      iny
            cpy   VI_LLEN
            bcs   :nf
            lda   (PTR0),y
            and   #$7F
            cmp   VI_FCHAR
            bne   :fscan
            lda   VI_TMP2
            beq   :flnd
            dey
:flnd       sty   VI_MO_C1
            bra   :next
:back       lda   VI_MO_C1
            beq   :nf
            ldy   VI_MO_C1
:bscan      dey
            bmi   :nf
            lda   (PTR0),y
            and   #$7F
            cmp   VI_FCHAR
            bne   :bscan
            lda   VI_TMP2
            cmp   #1
            beq   :blnd
            iny
:blnd       sty   VI_MO_C1
:next       dec   VI_COUNT
            bne   :rep
            lda   VI_COUNT+1
            beq   :ok
            dec   VI_COUNT+1
            bra   :rep
:ok         clc
            rts
:nf         sec
            rts

*---------------------------------------------------------------
* VI_DOMOTION -- the operator-motion span contract this task
* was asked to define precisely (docs/VI-DESIGN.md sec 4.1/4.3
* extended, this task's own new interface -- a later operators
* stream, d/c/y, is the intended consumer). IN: A = the pending
* motion key, VI_COUNT = the pending count (0 = none -- motions
* whose count means "repeat N times" normalize it themselves via
* VI_CNTNORM; G's count means a target line and is used as-is).
* The span START is ALWAYS the current cursor -- ED_CURLINE/
* VI_CURCOL are copied into VI_MO_L1/VI_MO_C1 as the working
* position before any per-key routine runs; those routines
* mutate VI_MO_L1/VI_MO_C1 IN PLACE as they compute, and NEVER
* touch ED_CURLINE/VI_CURCOL themselves -- moving the real
* cursor is the caller's job (VI_GOMOTION, below, for command
* mode). OUT: carry clear = valid motion -- VI_MO_L1 (2, target
* line)/VI_MO_C1 (1, target column)/VI_MO_TYPE (1: 0 = charwise
* EXCLUSIVE, 1 = charwise INCLUSIVE, 2 = LINEWISE) all set;
* carry set = the key is not one of these motions, or a find
* with nothing to find/repeat (`;`/`,` before any f/F/t/T, or a
* char not found on the line) -- VI_MO_* left undefined, the
* caller aborts (silently, v1's own existing "unmatched key"
* convention -- vicmd.s's VI_LOOP header already names this
* rather than a bell this tree has no console primitive for).
*
* Motion -> TYPE: w/W/b/B = 0 (exclusive), e/E/f/F/t/T = 1
* (inclusive), 0/^ = 0, $ = 1, G/j/k = 2 (linewise). e/f/t
* inclusive and w exclusive are given directly by the task brief
* (real vi/POSIX); b/B/0/^/$/F/T's grading here extends that
* using the same well-attested vi/POSIX operator table (NOT
* independently re-verified against the 1977 Ex manual this
* session -- HACKING.md's own confidence discipline flags this
* as the one [reported]-grade extrapolation in this contract;
* see the task report).
*
* CLOBBERS: A, X, Y, PTR0, ED_TMP16, ED_TMP16B, VI_TMP, VI_TMP2,
* VI_LLEN, VI_BIGF (+ each dispatched motion's own clobbers, +
* VI_RAWKEY's clobbers for a fresh f/F/t/T).
*---------------------------------------------------------------
*---------------------------------------------------------------
* Every case below ends INLINE (its own "set VI_MO_TYPE; clc;
* rts" or "sec; rts") rather than branching to a shared tail --
* `bra`'s signed 8-bit range cannot reach a tail this far away
* from the EARLY cases in a chain this long (found live building
* this file: "Bad Jump for instruction 'bra _typ0'... Too long"
* -- the fix is inlining, not `jmp`, since a JMP target still
* has to be reached by a CONDITIONAL branch to get there, which
* has the identical range limit; VI_LOOP/VI_MOTKEY's existing
* chains dodge this by only ever branching to the NEXT nearby
* check, never to a distant shared exit -- worth citing as a
* dialect note, not just a local fix).
*---------------------------------------------------------------
VI_DOMOTION cmp   #"/"                  ;the search keys are an
            beq   :sfwd                  ;operator's motion too:
            cmp   #"?"                 ;the search runs with the
            beq   :sbk                 ;cursor saved, not moved
            cmp   #"n"                 ;(visearch.s VI_SMO_*)
            beq   :sn
            cmp   #"N"
            bne   :nosrch
            jsr   VI_SMO_PRE
            jsr   VI_SRCH_NN
            jmp   VI_SMO_POST
:sfwd       jsr   VI_SMO_PRE
            jsr   VI_SRCH_FWD
            jmp   VI_SMO_POST
:sbk        jsr   VI_SMO_PRE
            jsr   VI_SRCH_BK
            jmp   VI_SMO_POST
:sn         jsr   VI_SMO_PRE
            jsr   VI_SRCH_N
            jmp   VI_SMO_POST
:nosrch     pha
            stz   VI_MO_END
            lda   ED_CURLINE
            sta   VI_MO_L1
            lda   ED_CURLINE+1
            sta   VI_MO_L1+1
            lda   VI_CURCOL
            sta   VI_MO_C1
            pla
            cmp   #"w"
            bne   :d01
            stz   VI_BIGF
            jsr   VI_CNTNORM
            jsr   VI_WFWDN
            jsr   VI_W_OPADJ
            stz   VI_MO_TYPE
            clc
            rts
:d01        cmp   #"W"
            bne   :d02
            lda   #1
            sta   VI_BIGF
            jsr   VI_CNTNORM
            jsr   VI_WFWDN
            jsr   VI_W_OPADJ
            stz   VI_BIGF
            stz   VI_MO_TYPE
            clc
            rts
:d02        cmp   #"b"
            bne   :d03
            stz   VI_BIGF
            jsr   VI_CNTNORM
            jsr   VI_WBACKN
            stz   VI_MO_TYPE
            clc
            rts
:d03        cmp   #"B"
            bne   :d04
            lda   #1
            sta   VI_BIGF
            jsr   VI_CNTNORM
            jsr   VI_WBACKN
            stz   VI_BIGF
            stz   VI_MO_TYPE
            clc
            rts
:d04        cmp   #"e"
            bne   :d05
            stz   VI_BIGF
            jsr   VI_CNTNORM
            jsr   VI_WENDN
            lda   #1
            sta   VI_MO_TYPE
            clc
            rts
:d05        cmp   #"E"
            bne   :d06
            lda   #1
            sta   VI_BIGF
            jsr   VI_CNTNORM
            jsr   VI_WENDN
            stz   VI_BIGF
            lda   #1
            sta   VI_MO_TYPE
            clc
            rts
:d06        cmp   #"0"
            bne   :d07
            stz   VI_MO_C1
            stz   VI_MO_TYPE
            clc
            rts
:d07        cmp   #"^"
            bne   :d08
            jsr   VI_FNB1
            stz   VI_MO_TYPE
            clc
            rts
:d08        cmp   #"$"
            bne   :d09
            jsr   VI_MO_LDLINE
            lda   VI_LLEN
            beq   :dolz
            dec   a
            sta   VI_MO_C1
            bra   :doldn
:dolz       stz   VI_MO_C1
:doldn      lda   #1
            sta   VI_MO_TYPE
            clc
            rts
:d09        cmp   #"G"
            bne   :d10
            jsr   VI_TARG_G
            lda   #2
            sta   VI_MO_TYPE
            clc
            rts
:d10        cmp   #"j"
            bne   :d11
            jsr   VI_CNTNORM
            jsr   VI_TARG_J
            lda   #2
            sta   VI_MO_TYPE
            clc
            rts
:d11        cmp   #"k"
            bne   :d11p
            jsr   VI_CNTNORM
            jsr   VI_TARG_K
            lda   #2
            sta   VI_MO_TYPE
            clc
            rts
*-- `+` / RETURN (2026-09-10): [count] lines down, first
*-- non-blank, linewise. On the LAST line it is invalid (real
*-- vi rings; VI_GOMOTION leaves the cursor, an operator gets
*-- carry set) rather than clamping onto itself.
:d11p       cmp   #"+"
            bne   :d12
            lda   VI_MO_L1
            cmp   ED_NLINES
            bne   :plusok
            lda   VI_MO_L1+1
            cmp   ED_NLINES+1
            bne   :plusok
            sec
            rts
:plusok     jsr   VI_CNTNORM
            jsr   VI_TARG_J
            jsr   VI_FNB1
            lda   #2
            sta   VI_MO_TYPE
            clc
            rts
:d12        cmp   #"f"
            beq   :dnew
            cmp   #"F"
            beq   :dnew
            cmp   #"t"
            beq   :dnew
            cmp   #"T"
            bne   :d13
:dnew       sta   VI_FCMD
            jsr   VI_RAWKEY
            bcs   :nfnd
            and   #$7F
            sta   VI_FCHAR
            jsr   VI_CNTNORM
            lda   VI_FCMD
            jsr   VI_DOFIND
            bcs   :nfnd
            lda   #1
            sta   VI_MO_TYPE
            clc
            rts
:d13        cmp   #$BB          ;';' high-bit -- #";" trips
                                ;merlin32's comment-start parser
            bne   :d14
            lda   VI_FCMD
            beq   :nfnd
            jsr   VI_CNTNORM
            lda   VI_FCMD        ;RELOAD: VI_CNTNORM clobbers A,
                                ;VI_DOFIND decodes A -- without
                                ;this `;` defaulted to T (back
                                ;till), never moved (2026-09-04)
            jsr   VI_DOFIND
            bcs   :nfnd
            lda   #1
            sta   VI_MO_TYPE
            clc
            rts
:d14        cmp   #$AC          ;',' high-bit-set -- #"," trips
                                ;merlin32's operand parser
                                ;(comma = the indexed-addr
                                ;separator, quoted or not --
                                ;edparse.s/sedexec.s/shsubst.s/
                                ;sortkey.s all hit this already)
            bne   :nfnd
            lda   VI_FCMD
            beq   :nfnd
            jsr   VI_CNTNORM
            jsr   VI_REVCMD
            jsr   VI_DOFIND
            bcs   :nfnd
            lda   #1
            sta   VI_MO_TYPE
            clc
            rts
:nfnd       sec
            rts

*---------------------------------------------------------------
* VI_RESYNC -- after ED_CURLINE has ALREADY been updated to a
* new target (VI_GOMOTION, below), bring it into the visible
* window: if it is within [VI_TOP, VI_TOP+textrows) just place
* the cursor there; otherwise reposition VI_TOP so the target
* becomes the window's FIRST row and do a full repaint. Unlike
* VI_SCROLL_DN/VI_SCROLL_UP (h/j/k/l's own one-line-step scroll,
* which assume a known direction), this handles an ARBITRARY
* jump (G, a word motion crossing many lines) either direction,
* any distance -- the v1 "any scroll is a full repaint" rule
* (docs/VI-DESIGN.md sec 2.2) already covers doing so with no
* partial-scroll optimization; it just does not mandate landing
* the target at any SPECIFIC row when it is this far out of
* view, and "top of the window" is the simplest correct choice.
* CLOBBERS: A, X, Y, PTR0, ED_TMP16, VI_TMP, VI_TMP2 (+
* VI_REPAINT's own clobbers on the out-of-window path).
*---------------------------------------------------------------
VI_RESYNC   jsr   VI_TOPSYNC
            bcc   :paint             ;VI_TOP moved: repaint
            jmp   VI_PLACE_CUR       ;cursor already visible
:paint      jmp   VI_REPAINT

