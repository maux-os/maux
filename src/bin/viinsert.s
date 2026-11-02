*---------------------------------------------------------------
* viinsert.s -- vi's insert mode (docs/VI-DESIGN.md sec
* 3.3/4.1). `put` by vi.s ONLY, after vimotion.s. `i` (VI_INS_
* ENTER) is the birth-slice core; the entry-variant fan-out --
* `a`/`A`/`I`/`o`/`O` (VI_INS_A/VI_INS_AEOL/VI_INS_FNB/VI_INS_
* OBLW/VI_INS_OABV) -- all reposition ED_CURLINE/VI_CURCOL (and,
* for `o`/`O`, splice in a fresh empty line via ED_INSRT_AFTR
* first) then fall into the SAME splice/echo/RETURN/ESC
* machinery through VI_INS_SHOWN. A raw byte loop: printable
* bytes are appended AND echoed live by vi itself (tty echo is
* off, cbreak+noecho -- vicmd.s's VI_START); RETURN splits the
* insertion into a new line via ED_INSRT_AFTR, the SAME
* primitive `ed`'s own `a`/`i`/`c` use; ESC finishes the current
* line (one ED_BUMP_ALLOC + ED_SETSLOT, the same handoff shape
* exbuf.s's header documents for every reused caller) and
* returns to command mode.
*
* Depends on: ED_BUMP_ALLOC/ED_SETSLOT/ED_INSRT_AFTR/ED_LINETEXT
* (exbuf.s, unchanged), EX_SNAPSHOT (exbuf.s -- once per user-
* visible command, before it mutates anything, per docs/VI-
* DESIGN.md sec 5 item 4's one-snapshot-per-command discipline
* -- `o`/`O` snapshot THEMSELVES before their own ED_INSRT_AFTR,
* see VI_INS_SHOWN's own header), TTY_PUT_BYTE via PUTC (echo),
* VI_RAWKEY (vicmd.s -- the raw one-byte read helper, shared
* with the command-mode loop), STRLEN (liba/string.s),
* VI_CLAMP_COL/VI_REPAINT (vimotion.s/viscreen.s).
*
* VI_LASTINS (`.`-repeat's own recording of the typed bytes,
* VI-DESIGN sec 3.3/4.1) is NOT implemented -- `.` itself is
* fan-out scope (sec 3.1's own "not this task" list) and
* nothing here needs to have recorded anything for it yet.
*---------------------------------------------------------------

*---------------------------------------------------------------
* VI_INS_ENTER -- `i`: enter insert mode at the current cursor
* (ED_CURLINE, VI_CURCOL), run the raw byte loop until ESC, then
* return to command mode with a full repaint already done.
* CLOBBERS: A, X, Y, PTR0, ED_TMP16, ED_SRC, VI_TMP, VI_LLEN
* (+ viscreen.s's own repaint clobbers).
*---------------------------------------------------------------
VI_INS_ENTER
            jsr   EX_SNAPSHOT
            stz   VI_INS_STRUCT          ;i/a/A/I: single-line
            jmp   VI_INS_BODY            ;edit, cheap repaint OK

*---------------------------------------------------------------
* VI_INS_A -- `a`: append AFTER the char under the cursor. An
* empty line has nothing to append after, so it degrades to `i`
* (col stays 0) -- same STRLEN-then-compare idiom VI_CLAMP_COL/
* VI_MOVE_L (vimotion.s) already use. CLOBBERS: same as
* VI_INS_ENTER, + STRLEN's own.
*---------------------------------------------------------------
VI_INS_A    lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN                ;A = length
            beq   :empty                ;0 -- degrade to `i`
            inc   VI_CURCOL             ;VI_CURCOL was <= len-1
                                        ;(clamped) -- +1 <= len,
                                        ;worst case lands on the
                                        ;NUL: a valid "append at
                                        ;true EOL" spot
:empty      jmp   VI_INS_ENTER          ;`i` at col 0

*---------------------------------------------------------------
* VI_INS_AEOL -- `A`: append at the end of the line (col =
* length, 0 on an empty line). CLOBBERS: same as VI_INS_A.
*---------------------------------------------------------------
VI_INS_AEOL lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN
            sta   VI_CURCOL
            jmp   VI_INS_ENTER

*---------------------------------------------------------------
* VI_INS_FNB -- `I`: insert before the first non-blank character
* (space $A0 or tab $89 -- this tree's own high-bit-set text
* convention, edfile.s:213/viscreen.s VI_CALC_COL). A blank-only
* or empty line lands at its end (POSIX ex: "insert ... at the
* end of line if it is blank"). CLOBBERS: A, X, Y, PTR0,
* ED_TMP16 (+ VI_INS_ENTER's own).
*---------------------------------------------------------------
VI_INS_FNB  lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT           ;PTR0 = line text
            ldy   #0
:scan       lda   (PTR0),y
            beq   :land                 ;NUL -- all blank (or
                                        ;empty); Y is the length
            cmp   #$A0                  ;space
            beq   :next
            cmp   #$89                  ;tab
            beq   :next
            bra   :land                 ;non-blank -- Y is it
:next       iny
            bra   :scan
:land       sty   VI_CURCOL
            jmp   VI_INS_ENTER

*---------------------------------------------------------------
* VI_INS_OBLW -- `o`: open a new empty line BELOW the current
* one and enter insert on it. Snapshots BEFORE its own
* ED_INSRT_AFTR mutation (VI_INS_SHOWN's own header explains
* why), same ED_BUMP_ALLOC(len=0)+ED_INSRT_AFTR idiom the
* RETURN-split path below already uses. CLOBBERS: A, X, Y, PTR0,
* ED_SRC, ED_TMP16 (+ VI_INS_SHOWN's own).
*---------------------------------------------------------------
VI_INS_OBLW jsr   EX_SNAPSHOT
            lda   #<VI_LBUF
            sta   ED_SRC
            lda   #>VI_LBUF
            sta   ED_SRC+1
            lda   #0
            jsr   ED_BUMP_ALLOC          ;PTR0 = new empty-line
                                        ;descriptor
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_INSRT_AFTR
                                        ;moves ED_CURLINE to it
            stz   VI_CURCOL
            jmp   VI_INS_OPEN

*---------------------------------------------------------------
* VI_INS_OABV -- `O`: open a new empty line ABOVE the current
* one (insert after ED_CURLINE-1 -- 0 both for line 1 and for
* an empty buffer, ED_INSRT_AFTR's own documented "0 = insert
* at the very start") and enter insert on it. CLOBBERS: same as
* VI_INS_OBLW.
*---------------------------------------------------------------
VI_INS_OABV jsr   EX_SNAPSHOT
            lda   #<VI_LBUF
            sta   ED_SRC
            lda   #>VI_LBUF
            sta   ED_SRC+1
            lda   #0
            jsr   ED_BUMP_ALLOC
            lda   ED_CURLINE
            ora   ED_CURLINE+1
            beq   :atstart               ;empty buffer -- 0
            lda   ED_CURLINE
            sec
            sbc   #1
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sbc   #0
            sta   ED_TMP16+1
            bra   :ins
:atstart    stz   ED_TMP16
            stz   ED_TMP16+1
:ins        jsr   ED_INSRT_AFTR
            stz   VI_CURCOL
            jmp   VI_INS_OPEN

*---------------------------------------------------------------
* The insert-mode session (VI_INS_SHOWN below): splice at
* ED_CURLINE/VI_CURCOL, raw-byte loop, RETURN/ESC handling --
* WITHOUT its own EX_SNAPSHOT call. VI_INS_ENTER (`i`) snapshots
* then falls straight in, since nothing has mutated the buffer
* yet at that point -- ONE snapshot, right there, IS the correct
* pre-command state. `a`/`A`/`I` go through VI_INS_ENTER too
* (they only reposition VI_CURCOL, a cell EX_SNAPSHOT never
* captures). `o`/`O` are different: they must snapshot BEFORE
* their own ED_INSRT_AFTR mutation so a later `u` reverses the
* WHOLE composite command (the opened line and its typed text)
* as one unit -- calling VI_INS_ENTER's own snapshot AFTER that
* mutation would overwrite the shadow with POST-mutation state
* and leave the opened line behind after undo (EX_SNAPSHOT,
* excmd.s: "OVERWRITING whatever the previous shadow held"). So
* `o`/`O` (and viop.s's c/C/cc/S/s) snapshot themselves and
* enter through VI_INS_OPEN / VI_INS_1LN / VI_OP_CWCHG, each of
* which first SHOWS its own mutation (2026-09-11: an insert-line
* escape for the opened line, VI_RPT_LN for a changed line,
* VI_RPDEL for folded lines -- never the old full repaint) and
* marks VI_INS_STRUCT = 2 so ESC redraws one row.
* CLOBBERS: A, X, Y, PTR0, ED_TMP16, ED_SRC, VI_TMP, VI_LLEN
* (+ viscreen.s's own repaint clobbers).
*---------------------------------------------------------------
VI_INS_1LN  jsr   VI_RPT_LN              ;`s`: the cursor line
            bra   VI_INS_MARK2           ;alone changed
VI_INS_OPEN lda   #1                     ;o/O: one line opened,
            ldx   #0                     ;the cursor on it --
            jsr   VI_RPINS               ;ESC[1L + paint it
VI_INS_MARK2 lda  #2
            sta   VI_INS_STRUCT
            jmp   VI_INS_SHOWN
* VI_INS_TAIL -- after the live echo of one typed char, redraw
* the pushed TAIL (SUBSCR, the suffix saved at insert entry) and
* put the glass cursor back after the typed text, so the screen
* shows the true line as you type -- what vi does on insert-
* capable output. Without it the echo overstruck the old text
* until ESC's redraw (operator, 2026-09-05: "looks like
* overstrike mode"). Clipped to the cells left on this row (one
* row per line, VI-DESIGN sec 2.3); plain i/a sessions only --
* after a CR the glass row moved and ESC's full repaint covers
* it, and o/O have no tail. The caller still flushes ONCE per
* keystroke. CLOBBERS: A, X, Y, VI_TMP (via VI_CSI_POS -- free
* during the loop; :doesc's own use of it starts after).
*---------------------------------------------------------------
* -- WRAP-aware (2026-09-05): the line owns VI_LNROWS[idx] rows
* -- (capacity = rows*cols columns). While typed+suffix fits,
* -- redraw the whole tail (it flows within the line's own rows)
* -- and put the cursor back with VI_PLACE_CUR's row/col math;
* -- the moment it outgrows them, VI_INS_SYNC commits the line
* -- and repaints so the rows below shift NOW.
VI_INS_TAIL sec                          ;idx = curline - top
            lda   ED_CURLINE
            sbc   VI_TOP
            tax
            lda   ED_CURLINE+1
            sbc   VI_TOP+1
            bne   :itsync                ;not on the table
            cpx   VI_LNCNT
            bcs   :itsync
            lda   VI_LNROWS,x            ;capacity = its rows
            jsr   VI_ROWBUDG             ;* cols -> VI_WBUDG
            lda   VI_INSLEN
            clc
            adc   VI_SFXLEN
            bcs   :itsync                ;> 255: outgrown
            cmp   VI_WBUDG
            bcc   :itfits
            beq   :itfits
:itsync     jmp   VI_INS_SYNC
:itfits     lda   VI_SFXLEN
            beq   :itdone                ;no tail: the cursor is
                                        ;already after the char
            jsr   VI_LBCOL               ;VI_WCOL = where the
            lda   #<SUBSCR               ;tail starts (its tabs
            sta   PTR0                   ;expand from there)
            lda   #>SUBSCR
            sta   PTR0+1
            jsr   VI_BPUTS               ;whole tail (it fits)
            lda   VI_CURCOL              ;cursor back after the
            pha                          ;typed text: VI_PLACE_
            lda   VI_INSLEN              ;CUR row/col math with
            sta   VI_CURCOL              ;the insert point as
            jsr   VI_PLACE_CUR           ;the column
            pla
            sta   VI_CURCOL
:itdone     rts

*---------------------------------------------------------------
* VI_INS_ECHO -- live-echo the byte just appended to VI_LBUF
* (VI_INSLEN already counts it). A TAB is echoed as the spaces
* to its stop, from the display column of the text before it
* (VI_LBCOL over the first VI_INSLEN-1 bytes): the terminal's HT
* paints nothing (viscreen.s VI_PUTCT's note). CLOBBERS: A, X,
* Y, VI_WCOL.
*---------------------------------------------------------------
VI_INS_ECHO ldy   VI_INSLEN
            dey
            lda   VI_LBUF,y
            and   #$7F
            cmp   #9
            beq   :tab
            lda   VI_LBUF,y
            ldx   #FD_STDOUT
            jmp   PUTC
:tab        dec   VI_INSLEN
            jsr   VI_LBCOL
            inc   VI_INSLEN
            lda   #$89
            jmp   VI_PUTCT

*---------------------------------------------------------------
* VI_INS_SYNC -- mid-insert commit + full repaint: the current
* line (accumulator + saved suffix) has outgrown the screen rows
* it was painted with, so the rows below must shift NOW, not at
* ESC. Writes prefix+typed+suffix as the line (append-only swap;
* ESC writes it once more -- cheap), repaints with the cursor
* after the typed text, then restores VI_CURCOL (:doesc/:docr
* never read it -- they use VI_TMP and 0). Bounded at 254 bytes
* like ED_BUMP_ALLOC. CLOBBERS: A, X, Y, PTR0, ED_SRC, ED_TMP16,
* EX_LINECACHE, + VI_REPAINT's own.
*---------------------------------------------------------------
VI_INS_SYNC ldy   #0
            ldx   #0
:isypfx     cpx   VI_INSLEN
            beq   :isysfx
            lda   VI_LBUF,x
            sta   EX_LINECACHE,y
            inx
            iny
            bra   :isypfx
:isysfx     ldx   #0
:isysl      cpx   VI_SFXLEN
            beq   :isyend
            cpy   #254
            bcs   :isyend
            lda   SUBSCR,x
            sta   EX_LINECACHE,y
            inx
            iny
            bra   :isysl
:isyend     lda   #0
            sta   EX_LINECACHE,y
            lda   #<EX_LINECACHE
            sta   ED_SRC
            lda   #>EX_LINECACHE
            sta   ED_SRC+1
            tya
            jsr   ED_BUMP_ALLOC
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_SETSLOT
            lda   VI_CURCOL
            pha
            lda   VI_INSLEN
            sta   VI_CURCOL
            jsr   VI_RPCUR               ;this line and below
            pla
            sta   VI_CURCOL
            rts

* -- VI_INS_BODY (i/a/A/I): place the glass cursor at the insert
* -- point BEFORE the raw loop echoes anything. a/A/I moved
* -- VI_CURCOL but nothing moved the cursor there, so the live
* -- echo landed where command mode left it -- `A` typed over
* -- the last char (found 2026-09-04). i is a no-op here.
VI_INS_BODY jsr   VI_PLACE_CUR
* -- VI_INS_SHOWN: the session proper, entered with the glass
* -- already showing the edit and the cursor placed -- from
* -- VI_INS_BODY above, or VI_INS_OPEN / VI_INS_1LN / viop.s
* -- VI_OP_CWCHG (each shows its own mutation first; until
* -- 2026-09-11 every one of them full-repainted here instead).
VI_INS_SHOWN
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT           ;PTR0 = current line's
                                        ;text
            ;-- copy the prefix [0, VI_CURCOL) into VI_LBUF, the
            ;-- running accumulator for whichever line is
            ;-- "current" at any moment during this insert
            ;-- session (a RETURN retargets it to a fresh line).
            ldy   #0
:pfx        cpy   VI_CURCOL
            beq   :pfxdone
            lda   (PTR0),y
            sta   VI_LBUF,y
            iny
            bra   :pfx
:pfxdone    sty   VI_INSLEN
            ;-- copy the suffix [VI_CURCOL, len) into SUBSCR
            ;-- (shared scratch -- `s` never runs concurrently
            ;-- with insert mode), NUL-terminated. Reappended to
            ;-- whichever line is current when ESC finally
            ;-- closes this session.
            ldy   VI_CURCOL
            ldx   #0
:sfx        lda   (PTR0),y
            beq   :sfxdone
            sta   SUBSCR,x
            iny
            inx
            bra   :sfx
:sfxdone    stz   SUBSCR,x
            stx   VI_SFXLEN              ;VI_INS_TAIL/SYNC/:docr
            lda   #1
            sta   VI_MODE

:rdloop     jsr   VI_RAWKEY              ;A = raw byte, carry
            bcs   :toesc                 ;set on ERR_INTR/error
                                        ;-- treated same as ESC
            cmp   #$9B                   ;ESC
            bne   :notesc
:toesc      jmp   :doesc                 ;(out of branch range
                                        ;since the erase keys)
:notesc     cmp   #$8D                   ;CR
            beq   :docr
*-- ERASE (2026-09-10): the //e's left-arrow IS its backspace
*-- key (^H, one wire) and DEL is the other -- both erase the
*-- last typed char, never past the insert point (POSIX vi's
*-- <erase>). The kernel frames an arrow as one line and
*-- VI_RAWKEY returns VI_KLEFT for it, so it no longer arrives
*-- as an ESC that ended the insert. The other three arrows
*-- still exit-and-move: pushed back via VI_UNGET for command
*-- mode to read as the motion.
            cmp   #$FF                   ;DEL
            beq   :derase
            cmp   #VI_KLEFT
            beq   :derase
            bcc   :doarrow               ;VI_KUP/DOWN/RIGHT
            ldy   VI_INSLEN
            cpy   #VI_LBUFLEN-1
            bcs   :rdloop                ;full -- drop the byte
            sta   VI_LBUF,y
            inc   VI_INSLEN
            jsr   VI_INS_ECHO            ;live echo -- tty echo
                                        ;is off (cbreak+noecho)
            jsr   VI_INS_TAIL            ;redraw the pushed tail
                                        ;(a subroutine: keeps
                                        ;:doesc in branch range)
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH              ;a console line-buffers
                                        ;(flush on CR) -- a bare
                                        ;byte with no CR would
                                        ;sit unseen otherwise
            bra   :rdloop
:derase     jsr   VI_INS_ERASE
            bra   :rdloop
:doarrow    sta   VI_UNGET               ;exit, then move
            jmp   :doesc

:docr       lda   #1                     ;a CR adds a line ->
            sta   VI_INS_STRUCT          ;structural
            ;-- finalize the CURRENT line as
            ;-- VI_LBUF[0,VI_INSLEN)
            lda   #<VI_LBUF
            sta   ED_SRC
            lda   #>VI_LBUF
            sta   ED_SRC+1
            lda   VI_INSLEN
            jsr   ED_BUMP_ALLOC
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_SETSLOT
            ;-- open the new line right after it, holding the
            ;-- saved SUFFIX (real vi shows the split at once;
            ;-- ESC rewrites this line as typed+suffix anyway).
            ;-- ED_INSRT_AFTR moves ED_CURLINE to the new line.
            lda   #<SUBSCR
            sta   ED_SRC
            lda   #>SUBSCR
            sta   ED_SRC+1
            lda   VI_SFXLEN
            jsr   ED_BUMP_ALLOC
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_INSRT_AFTR
            stz   VI_INSLEN
            stz   VI_CURCOL
            lda   #2                     ;the shift is shown NOW
            sta   VI_INS_STRUCT          ;(2 = ESC need not
                                        ;repaint everything)
            lda   #1                     ;one new line (the
            ldx   #1                     ;suffix) + the split
            jsr   VI_RPINS               ;line above it changed:
                                        ;ESC[1L + paint those
                                        ;two, cursor on the new
                                        ;line (2026-09-11; was
                                        ;VI_RPCURP, a repaint
                                        ;from the split line to
                                        ;the bottom, and before
                                        ;2026-09-05 a bare CR
                                        ;echo, lines below stale
                                        ;until ESC)
            jmp   :rdloop

:doesc      ;-- append the saved suffix (SUBSCR) to whatever the
            ;-- accumulator holds now, then close the line.
            lda   VI_INSLEN              ;prefix + TYPED chars,
            sta   VI_TMP                 ;captured BEFORE the
                                        ;suffix goes on: the
                                        ;cursor lands from this
                                        ;(below), not from the
                                        ;whole line's length
            ldy   #0
:apnd       lda   SUBSCR,y
            beq   :apnddone
            pha
            lda   VI_INSLEN
            cmp   #VI_LBUFLEN-1
            bcs   :apndfull
            tax
            pla
            sta   VI_LBUF,x
            inc   VI_INSLEN
            bra   :apndnext
:apndfull   pla
:apndnext   iny
            bra   :apnd
:apnddone   lda   #<VI_LBUF
            sta   ED_SRC
            lda   #>VI_LBUF
            sta   ED_SRC+1
            lda   VI_INSLEN
            jsr   ED_BUMP_ALLOC
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_SETSLOT
            stz   VI_MODE
            lda   VI_TMP                 ;land ON the last typed
            beq   :iesccol               ;char (prefix+typed-1),
            dec   a                      ;or one left of a bare
:iesccol    sta   VI_CURCOL              ;i/ESC, never before
                                        ;col 0 -- real vi's
                                        ;rule. Until 2026-09-05
                                        ;this used VI_INSLEN
                                        ;AFTER the suffix append
                                        ;= the whole line, so
                                        ;ESC parked the cursor
                                        ;at END OF LINE and the
                                        ;next `x` ate the last
                                        ;char ("iQ<ESC>x" on
                                        ;"hello world" lost d)
            jsr   VI_CLAMP_COL
* -- a multi-line insert can push the cursor off the window
* -- bottom: VI_TOPSYNC follows it (2026-09-04). Carry CLEAR =
* -- VI_TOP moved = the whole page scrolled = full repaint.
            jsr   VI_TOPSYNC
            bcc   :fullrp
* -- line count unchanged AND no scroll: only THIS line's text
* -- changed. Two rows, not 24 -- the [MOD] flag (insert dirtied
* -- the buffer) then the edited row, which then places cursor.
* -- 1 = a CR was typed (:docr): the rows below it are STALE --
* -- :docr only echoes the newline -- so the full repaint is
* -- owed. 2 = o/O opened the line: VI_INS_BODY already
* -- repainted the shift at ENTRY, and nothing below changed
* -- since, so this is the two-row case. Repainting all 23 rows
* -- here for every `o` was HALF of the measured 0.6 s
* -- (2026-09-05).
            lda   VI_INS_STRUCT
            cmp   #1
            beq   :fullrp
            jmp   VI_RPT_LN         ;status stays BLANK after an
                                   ;edit now (real vi: no banner
                                   ;redraw; 2026-09-05)
:fullrp     jmp   VI_REPAINT             ;moved/scrolled: full
                                        ;repaint (VI-DESIGN 2.2)

*---------------------------------------------------------------
* VI_INS_ERASE -- insert-mode <erase> (left-arrow/^H or DEL):
* drop the last TYPED char of the current insert line. The
* floor is the insert point: VI_INSLEN counts prefix+typed and
* VI_CURCOL is the prefix length (0 after a CR -- a fresh line
* has no prefix), so nothing before the insert point is ever
* erased and a line is never joined (POSIX vi). Glass: cursor to
* the vacated cell, the pushed tail (SUBSCR) one cell left, one
* blank for the cell the tail's last char vacated, cursor back.
* VI_PLACE_CUR's row/col math keeps this right across a wrapped
* line. Flushes once. CLOBBERS: A, X, Y, PTR0, ED_TMP16, VI_TMP.
*---------------------------------------------------------------
VI_INS_ERASE
            lda   VI_INSLEN
            cmp   VI_CURCOL
            beq   :none                  ;nothing typed on this
            bcc   :none                  ;line yet
            dec   VI_INSLEN
            jsr   :place
            lda   VI_SFXLEN
            beq   :blank
            jsr   VI_LBCOL               ;VI_WCOL = tail start
            lda   #<SUBSCR
            sta   PTR0
            lda   #>SUBSCR
            sta   PTR0+1
            jsr   VI_BPUTS               ;tail, one cell left
:blank      lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC                   ;the vacated cell
            jsr   :place
            ldx   #FD_STDOUT
            jmp   SIO_FLUSH
:place      lda   VI_CURCOL              ;cursor after the typed
            pha                          ;text -- VI_INS_TAIL's
            lda   VI_INSLEN              ;own idiom
            sta   VI_CURCOL
            jsr   VI_PLACE_CUR
            pla
            sta   VI_CURCOL
:none       rts
