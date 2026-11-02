*---------------------------------------------------------------
* viscreen.s -- vi's screen model (docs/VI-DESIGN.md sec 2/6).
* `put` by vi.s ONLY, after excmd.s. Owns rendering the buffer's
* window to the glass through cursor-addressing CSI writes (the
* `docs/CONSOLE.md` sec 6 terminal subset -- ESC[r;cH, ESC[K,
* and the scroll family ESC[nS/T and ESC[nL/M that VI_RPINS/
* VI_RPDEL/VI_SCROLL_* ride instead of repainting -- sec 2.2),
* the reserved bottom-row status line, and the tab-stop-aware
* column math for cursor placement (sec 2.4 -- there is no
* readback, so the on-screen column is always COMPUTED, never
* trusted).
*
* Text rows are 1..(VI_ROWS-1); the LAST row (VI_ROWS) is vi's
* own status line -- docs/CONSOLE.md sec 6's row-0 reservation
* already accounts for the console's OWN status row, so vi's
* window math never needs to know row 0 exists (VI-DESIGN sec
* 2.1).
*
* Depends on: ED_LINETEXT (exbuf.s, read-only), ED_CURLINE/
* ED_NLINES (shared cells), PUTC/PUTS/PRNUM (liba). Every
* routine here CLOBBERS A/X/Y/PTR0 freely, same convention every
* reused ed/ex routine already uses.
*---------------------------------------------------------------

*---------------------------------------------------------------
* VI_QUERYGEO -- SC_TTYGEO(FD_STDOUT) -> VI_ROWS/VI_COLS, once
* at startup (vicmd.s's VI_START). Same read-modify-verify idiom
* vidmode.s uses for the same syscall. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
VI_QUERYGEO
            lda   #<VI_GEOBUF
            sta   PTR0
            lda   #>VI_GEOBUF
            sta   PTR0+1
            lda   #FD_STDOUT
            jsr   SC_TTYGEO
            lda   VI_GEOBUF
            sta   VI_COLS
            lda   VI_GEOBUF+1
            sta   VI_ROWS
            rts

*---------------------------------------------------------------
* VI_CSI_POS -- write ESC [ <row> ; <col> H to FD_STDOUT. IN:
* A = row (1-based), X = col (1-based). Byte-at-a-time PUTCs,
* same discipline vidmode.s/chvt.s already use for a CSI
* sequence (check_purity, docs/STICKY.md sec 29 -- no
* patched-in-place mutable text). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
VI_CSI_POS  sta   VI_TMP
            stx   VI_TMP+1
            lda   #$9B                 ;ESC
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$DB                 ;'['
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   VI_TMP               ;row, buffered digits --
            jsr   VI_PUT2D             ;NOT PRNUM (see VI_PUT2D)
            lda   #$BB                 ;';'
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   VI_TMP+1             ;col
            jsr   VI_PUT2D
            lda   #$C8                 ;'H'
            ldx   #FD_STDOUT
            jsr   PUTC
            ;-- a console fd LINE-buffers (flush on CR) -- see
            ;-- stdio.s's own header -- so a screen update with
            ;-- no CR in it (nearly everything vi writes) would
            ;-- sit unseen until an unrelated later write
            ;-- happened to cross the 512B auto-flush threshold.
            ;-- Cursor placement is the LAST step of essentially
            ;-- every vi repaint/motion path, so flushing HERE
            ;-- makes every one of them visible immediately.
            ;-- Found live, 2026-09-03: an insert-mode
            ;-- keystroke's own echo (a single byte, no CR)
            ;-- never appeared on screen until this fix. BUT
            ;-- VI_REPAINT calls VI_CSI_POS at the START of
            ;-- each row, so an unconditional flush made a
            ;-- repaint ~23 write()s -- the "1200 baud" crawl
            ;-- the operator watched (2026-09-04). VI_NOFLUSH
            ;-- lets the repaint suppress the per-row flush and
            ;-- flush ONCE at the end (VI_PLACE_CUR); single
            ;-- keystrokes and motions keep flushing (it is 0).
            lda   VI_NOFLUSH
            bne   :noflush
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH
:noflush    rts

*---------------------------------------------------------------
* VI_ERSLN -- ESC [ K (erase cursor-to-end-of-line, docs/
* CONSOLE.md sec 6), to FD_STDOUT. CLOBBERS: A, X.
*---------------------------------------------------------------
VI_ERSLN    lda   #$9B
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$DB
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$CB                 ;'K'
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* VI_CALC_COL -- IN: PTR0 = the current line's text (already
* fetched via ED_LINETEXT by the caller), VI_CURCOL = the
* logical byte offset. OUT: A = the 1-based screen column,
* walking the SAME 8-column tab-stop fold TTY_TAB implements
* (src/kernel/tty2.s, `and #7` -- docs/VI-DESIGN.md sec 2.4).
* CLOBBERS: A, Y, VI_TMP.
*---------------------------------------------------------------
VI_CALC_COL
            ldy   #0
            stz   VI_TMP                ;running 0-based column
                                        ;-- a line is capped at
                                        ;254 bytes, so this
                                        ;never needs a high byte
:loop       cpy   VI_CURCOL
            beq   :done
            lda   (PTR0),y
            and   #$7F
            cmp   #9                    ;TAB
            bne   :plain
            lda   VI_TMP
            ora   #7
            clc
            adc   #1
            sta   VI_TMP
            bra   :adv
:plain      inc   VI_TMP
:adv        iny
            bra   :loop
:done       lda   VI_TMP
            clc
            adc   #1
            rts

*---------------------------------------------------------------
* VI_PLACE_CUR -- recompute VI_SCRROW/VI_SCRCOL from
* ED_CURLINE/VI_TOP/VI_CURCOL and position the hardware cursor
* there (VI-DESIGN sec 2.4 -- always an absolute CSI H, never a
* relative walk). CLOBBERS: A, X, Y, PTR0, ED_TMP16, VI_TMP.
*---------------------------------------------------------------
VI_PLACE_CUR
* -- WRAP-aware (2026-09-05): row = the cursor line's first
* -- screen row (VI_LNSUM over VI_LNROWS) + display-col/cols;
* -- col = display-col mod cols. A cursor line not in the table
* -- (nothing painted yet) is treated as the first visible line.
            sec
            lda   ED_CURLINE
            sbc   VI_TOP
            sta   VI_LRIDX
            lda   ED_CURLINE+1
            sbc   VI_TOP+1
            bne   :pcrow1
            lda   VI_LRIDX
            cmp   VI_LNCNT
            bcc   :pcok
:pcrow1     stz   VI_LRIDX
:pcok       lda   VI_LRIDX
            jsr   VI_LNSUM
            sta   VI_SCRROW
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   VI_LTEXTC             ;PTR0 = current line's
                                        ;text -- cached, vicache
            jsr   VI_CALC_COL           ;A = 1-based display col
            sec
            sbc   #1
:pcwrap     cmp   VI_COLS
            bcc   :pccol
            sec
            sbc   VI_COLS
            inc   VI_SCRROW
            bra   :pcwrap
:pccol      clc
            adc   #1
            sta   VI_SCRCOL
            lda   VI_ROWS               ;never below the text
            sec                         ;window (a clipped top
            sbc   #1                    ;line longer than it)
            cmp   VI_SCRROW
            bcs   :pcgo
            sta   VI_SCRROW
:pcgo       lda   VI_SCRROW
            ldx   VI_SCRCOL
            jmp   VI_CSI_POS

*---------------------------------------------------------------
* Line-wrap helpers (2026-09-05). A buffer line occupies
* max(1, ceil(width/VI_COLS)) screen rows; width = display
* columns with TAB folded to 8-column stops exactly as
* VI_CALC_COL/TTY_TAB fold it (line-relative -- identical to the
* console's row-relative fold whenever VI_COLS is a multiple of
* 8, i.e. 40/80; a TAB on the 2nd+ row of a wrapped line in the
* UltraTerm's 132-column mode is the one accepted gap, and the
* tree holds no TABs today).
*---------------------------------------------------------------
* VI_ROWSOF -- IN: A = width (0-255). OUT: A = rows. CLOBBERS:
* A, X.
VI_ROWSOF   ldx   #1
:rocont     cmp   VI_COLS
            bcc   :rodone
            beq   :rodone
            sec
            sbc   VI_COLS
            inx
            bra   :rocont
:rodone     txa
            rts

* VI_LNWIDTH -- IN: PTR0 = text. OUT: A = VI_WCOL = width,
* saturated at 255. CLOBBERS: A, Y, VI_WCOL.
VI_LNWIDTH  ldy   #0
            stz   VI_WCOL
:lwloop     lda   (PTR0),y
            beq   :lwdone
            and   #$7F
            cmp   #9                    ;TAB
            bne   :lwplain
            lda   VI_WCOL
            ora   #7
            clc
            adc   #1
            bcs   :lwsat
            sta   VI_WCOL
            bra   :lwnext
:lwplain    inc   VI_WCOL
            beq   :lwsat
:lwnext     iny
            bra   :lwloop
:lwsat      lda   #255
            sta   VI_WCOL
:lwdone     lda   VI_WCOL
            rts

* VI_ROWBUDG -- IN: A = rows. OUT: VI_WBUDG = rows*VI_COLS,
* saturated at 255 (a 254-byte line always fits). CLOBBERS:
* A, X, VI_WBUDG.
VI_ROWBUDG  tax
            lda   #0
:rbloop     clc
            adc   VI_COLS
            bcs   :rbsat
            dex
            bne   :rbloop
            bra   :rbdone
:rbsat      lda   #255
:rbdone     sta   VI_WBUDG
            rts

* VI_BPUTSW -- write the text at PTR0 with PUTC, stopping before
* any char that would take the display past VI_WBUDG columns.
* OUT: VI_WCOL = columns written. CLOBBERS: A, X, Y, VI_WCOL.
VI_BPUTSW   ldy   #0
            stz   VI_WCOL
:bwloop     lda   (PTR0),y
            beq   :bwdone
            pha
            and   #$7F
            cmp   #9                    ;TAB
            bne   :bwplain
            lda   VI_WCOL
            ora   #7
            clc
            adc   #1
            bra   :bwchk
:bwplain    lda   VI_WCOL
            clc
            adc   #1
:bwchk      bcs   :bwstop               ;past 255
            cmp   VI_WBUDG
            bcc   :bwok
            beq   :bwok
:bwstop     pla
            rts
:bwok       pla
            phy
            jsr   VI_PUTCT              ;PUTC; a TAB as spaces
            ply                         ;(advances VI_WCOL)
            iny
            bra   :bwloop
:bwdone     rts

* VI_PUTCT -- PUTC A (the line's own high-bit byte) to stdout,
* advancing VI_WCOL: a TAB ($89) is written as the spaces to the
* next 8-column stop -- the same fold VI_CALC_COL/VI_LNWIDTH
* count -- because the terminal's HT is a cursor motion that
* paints nothing and stops at the right edge (VT102; VT3,
* 2026-09-12), so a raw tab over a stale row left the old text
* showing and a tab past the edge landed on the next row where
* vi's column model did not expect it. CLOBBERS: A, X, VI_WCOL.
VI_PUTCT    pha
            and   #$7F
            cmp   #9                    ;TAB
            beq   :tab
            pla
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   VI_WCOL
            rts
:tab        pla
:sp         lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   VI_WCOL
            lda   VI_WCOL
            and   #7
            bne   :sp
            rts

* VI_LBCOL -- VI_WCOL = the display column after VI_LBUF's first
* VI_INSLEN bytes (the insert line's prefix + typed text), same
* tab fold as VI_CALC_COL: where the pushed tail (SUBSCR) starts
* on the glass, so VI_BPUTS can expand the tail's own tabs from
* the right column. CLOBBERS: A, Y, VI_WCOL.
VI_LBCOL    ldy   #0
            stz   VI_WCOL
:lp         cpy   VI_INSLEN
            beq   :done
            lda   VI_LBUF,y
            and   #$7F
            cmp   #9
            bne   :plain
            lda   VI_WCOL
            ora   #7
            inc   a
            sta   VI_WCOL
            bra   :next
:plain      inc   VI_WCOL
:next       iny
            bra   :lp
:done       rts

* VI_ERSLTAIL -- erase to end of row after VI_BPUTSW, UNLESS the
* last row is exactly full (VI_WCOL a nonzero multiple of cols):
* nothing is left to erase there, and an ESC[K after a full row
* could clear the NEXT row on an eagerly-wrapping console.
* CLOBBERS: A, X.
VI_ERSLTAIL lda   VI_WCOL
            beq   :etdo
:etmod      cmp   VI_COLS
            bcc   :etdo
            beq   :etskip
            sec
            sbc   VI_COLS
            bra   :etmod
:etdo       jmp   VI_ERSLN
:etskip     rts

* VI_LNSUM -- IN: A = k. OUT: A = 1 + VI_LNROWS[0]+..+[k-1] =
* the 1-based screen row where visible line k starts.
* CLOBBERS: A, X, Y.
VI_LNSUM    tay
            lda   #1
            ldx   #0
:lsloop     cpy   #0
            beq   :lsdone
            clc
            adc   VI_LNROWS,x
            inx
            dey
            bra   :lsloop
:lsdone     rts

* VI_FITCUR -- advance VI_TOP until the cursor line's LAST row
* is inside the text window (a line that alone exceeds it is
* shown clipped from its top). Widths come from the line cache.
* A cursor above VI_TOP top-aligns. CLOBBERS: A, X, Y, PTR0,
* ED_TMP16, VI_LRIDX, VI_WCOL (+ VI_LTEXTC's).
VI_FITCUR   lda   ED_NLINES             ;empty buffer: nothing
            ora   ED_NLINES+1           ;to fit (and no line 0
            beq   :fcok                 ;to fetch)
            lda   ED_CURLINE            ;curline 0 = "before
            ora   ED_CURLINE+1          ;line 1", transient
            beq   :fcok                 ;during P-above-line-1 /
                                        ;a file open: NOT a
                                        ;reason to move the top
                                        ;(it painted a phantom
                                        ;blank row 1, check-vi
                                        ;Y+P, 2026-09-05)
            lda   ED_CURLINE+1          ;curline < top? top =
            cmp   VI_TOP+1              ;curline
            bcc   :fctop
            bne   :fcagain
            lda   ED_CURLINE
            cmp   VI_TOP
            bcs   :fcagain
:fctop      lda   ED_CURLINE
            sta   VI_TOP
            lda   ED_CURLINE+1
            sta   VI_TOP+1
:fcagain    stz   VI_LRIDX              ;rows TOP..CURLINE
            lda   VI_TOP
            sta   ED_TMP16
            lda   VI_TOP+1
            sta   ED_TMP16+1
:fcwalk     jsr   VI_LNROWSOF
            clc
            adc   VI_LRIDX
            bcs   :fcover
            sta   VI_LRIDX
            lda   ED_TMP16
            cmp   ED_CURLINE
            bne   :fcnext
            lda   ED_TMP16+1
            cmp   ED_CURLINE+1
            beq   :fcend
:fcnext     inc   ED_TMP16
            bne   :fcwalk
            inc   ED_TMP16+1
            bra   :fcwalk
:fcend      lda   VI_ROWS
            sec
            sbc   #1                    ;textrows
            cmp   VI_LRIDX
            bcs   :fcok                 ;total <= textrows: fits
:fcover     lda   VI_TOP                ;top == curline: clip it
            cmp   ED_CURLINE
            bne   :fcbump
            lda   VI_TOP+1
            cmp   ED_CURLINE+1
            beq   :fcok
:fcbump     inc   VI_TOP
            bne   :fcagain
            inc   VI_TOP+1
            bra   :fcagain
:fcok       rts

*---------------------------------------------------------------
* VI_PRFNAME -- print ED_CURFNAME (MLI length-prefixed, NOT
* NUL-terminated -- edfile.s's own shape) to FD_STDOUT. Prints
* nothing if empty (no remembered filename). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
VI_PRFNAME  ldy   #0
            lda   ED_CURFNAME
            beq   :done
            sta   VI_TMP
:loop       iny
            lda   ED_CURFNAME,y
            ldx   #FD_STDOUT
            jsr   PUTC
            cpy   VI_TMP
            bne   :loop
:done       rts

*---------------------------------------------------------------
* VI_STAT_LINE -- render the reserved bottom row: filename +
* a `*` dirty flag when EX_DIRTY is set. Does NOT move the
* logical cursor -- callers that need the glass cursor back on
* the text area call VI_PLACE_CUR afterward (VI_REPAINT does
* both). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*---------------------------------------------------------------
* BLANK during editing; content -- filename info on open/^G, a
* `:` command, a search, a message -- is TRANSIENT, not a fixed
* command, a search, a message -- is TRANSIENT, not a permanent
* full repaint clears a stale message, leaves an empty command
* line. (2026-09-05, operator: a permanent status line is not
* CLOBBERS: A, X, Y.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
VI_STAT_BLANK
            lda   VI_ROWS
            ldx   #1
            jsr   VI_CSI_POS
            jmp   VI_ERSLN

*---------------------------------------------------------------
* VI_STAT_LINE -- draw the `"filename" [MOD]` info on the status
* row. Shown ONCE at open (VI_START) and on demand, NOT on every
* repaint (that is VI_STAT_BLANK now). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
VI_STAT_LINE
            lda   VI_ROWS
            ldx   #1
            jsr   VI_CSI_POS
            lda   #$A2                 ;'"' -- quoted filename,
            ldx   #FD_STDOUT           ;same convention real
            jsr   PUTC                 ;vi's status line uses
            jsr   VI_PRFNAME
            lda   #$A2
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   EX_DIRTY
            beq   :notdirty
            lda   #$A0                 ;space
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$DB                 ;'['
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$CD                 ;'M'
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$CF                 ;'O'
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$C4                 ;'D'
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$DD                 ;']'
            ldx   #FD_STDOUT
            jsr   PUTC
:notdirty   jmp   VI_ERSLN

*---------------------------------------------------------------
* VI_STATUS_MSG -- write a NUL-terminated liba string at PTR0
* (caller-owned buffer -- vicmd.s's VI_LBUF for a `:`-typed
* command, or a literal message buffer for an error) onto the
* status row, erase-to-EOL, WITHOUT touching VI_TOP/repainting
* the text area (cheap -- used for one-line error/status
* messages, e.g. `u` with nothing to undo). CLOBBERS: A, X, Y.
* PTR0 must survive the VI_CSI_POS call below. HISTORY: until
* 2026-09-05 VI_CSI_POS called PRNUM twice, and PRNUM repoints
* PTR0 at its PRNBUF scratch (src/liba/num.s) -- found live
* 2026-09-03 via visearch.s's no-match message (the original
* `pha`/`phx` saved the WRONG registers). VI_CSI_POS now emits
* its digits through VI_PUT2D, which leaves PTR0 alone, so this
* save is belt-and-braces -- kept because it is cheap and the
* next PRNUM someone adds there would silently re-open the bug.
*---------------------------------------------------------------
VI_STATUS_MSG
            lda   PTR0
            pha
            lda   PTR0+1
            pha
            lda   VI_ROWS
            ldx   #1
            jsr   VI_CSI_POS
            pla
            sta   PTR0+1
            pla
            sta   PTR0
            ldx   #FD_STDOUT
            jsr   PUTS
            jmp   VI_ERSLN

*---------------------------------------------------------------
* VI_PUT2D -- A = 0..99 -> its decimal digits via PUTC, no
* leading zero. VI_BPUTS -- PTR0 = NUL-terminated string -> each
* byte via PUTC. Both are BUFFERED, and that is the point: PRNUM
* and PUTS on a console fd flush-then-write-DIRECT (print.s), so
* the two PRNUMs per cursor address split one 23-row repaint
* into ~4 write syscalls per ROW -- 123 writes, ~115k cycles,
* measured 2026-09-05 on the card. Through PUTC the repaint is
* ONE buffered write, flushed once by the final VI_PLACE_CUR --
* what 60fcb23's VI_NOFLUSH always intended. SIO_PUTC preserves
* Y and PTR0 (stdio.s). CLOBBERS: A, X; VI_BPUTS also Y.
*---------------------------------------------------------------
VI_PUT2D    ldx   #0                   ;tens
:tens       cmp   #10
            bcc   :ones
            sbc   #10                  ;carry set by the cmp
            inx
            bra   :tens
:ones       pha
            txa
            beq   :noten               ;<10: no leading zero
            ora   #$B0                 ;'0'+tens, high bit set
            ldx   #FD_STDOUT
            jsr   PUTC
:noten      pla
            ora   #$B0                 ;'0'+ones
            ldx   #FD_STDOUT
            jmp   PUTC

*---------------------------------------------------------------
* VI_EMIT_SU -- ESC [ n S (SU, scroll the screen body UP n rows)
* to FD_STDOUT. The terminal scroll a partial-scroll rides
* instead of repainting the whole window (docs/VI-DESIGN.md sec
* 2.2 -- what a 300-baud-usable vi does). IN: A = n. The caller
* (VI_SCROLL_DN) repaints the exposed bottom rows right after,
* and that repaint's own tail flushes, so no flush here.
* CLOBBERS: A, X.
*---------------------------------------------------------------
* VI_EMIT_IL -- ESC [ n L (IL, insert n blank lines at the
* cursor row; the rows below shift down). VI_EMIT_DL -- ESC [ n
* M (DL, delete n lines at the cursor row; the rows below pull
* up). The region scrolls VI_RPINS/VI_RPDEL ride (docs/
* CONSOLE.md sec 4). IN: A = n. CLOBBERS: A, X, Y.
VI_EMIT_IL  ldy   #$CC                 ;'L' -- IL (insert line)
            bra   VI_EMIT_SUD
VI_EMIT_DL  ldy   #$CD                 ;'M' -- DL (delete line)
            bra   VI_EMIT_SUD
VI_EMIT_SU  ldy   #$D3                 ;'S' -- SU (scroll up)
            bra   VI_EMIT_SUD
*---------------------------------------------------------------
* VI_EMIT_SD -- ESC [ n T (SD, scroll the body DOWN n rows) to
* FD_STDOUT. The reverse of VI_EMIT_SU, for vi `k` scroll-up.
* IN: A = n. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
VI_EMIT_SD  ldy   #$D4                 ;'T' -- SD (scroll down)
VI_EMIT_SUD pha                         ;final byte in Y
            lda   #$9B                 ;ESC
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$DB                 ;'['
            ldx   #FD_STDOUT
            jsr   PUTC
            pla
            jsr   VI_PUT2D             ;n, buffered digits
            tya                         ;'S' or 'T'
            ldx   #FD_STDOUT
            jmp   PUTC

* VI_BPUTS -- write the NUL-terminated text at PTR0 with PUTC,
* tabs as spaces from the column the CALLER put in VI_WCOL
* (VI_LBCOL for the insert tail). CLOBBERS: A, X, Y, VI_WCOL.
VI_BPUTS    ldy   #0
:bp         lda   (PTR0),y
            beq   :bpd
            phy
            jsr   VI_PUTCT             ;preserves PTR0
            ply
            iny
            bne   :bp
:bpd        rts

*---------------------------------------------------------------
* VI_RPT_LN -- re-fetch and rewrite just the screen rows
* ED_CURLINE currently occupies (VI-DESIGN sec 2.2's cheap-path
* repaint -- a char-wise edit confined to one line). WRAP-aware
* (2026-09-05): if the line's row count changed, or it is not in
* the painted table at all (past EOF, or off screen), the rows
* below must shift -- full repaint instead. Does NOT touch the
* status line. Ends by placing the cursor. CLOBBERS: A, X, Y,
* PTR0, ED_TMP16, VI_TMP, VI_LRIDX, VI_LR, VI_WCOL, VI_WBUDG.
*---------------------------------------------------------------
VI_RPT_LN   sec
            lda   ED_CURLINE
            sbc   VI_TOP
            sta   VI_LRIDX
            lda   ED_CURLINE+1
            sbc   VI_TOP+1
            bne   :rlfull
            lda   VI_LRIDX
            cmp   VI_LNCNT
            bcs   :rlfull              ;not painted as a line
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   VI_LNROWSOF          ;cached (vicache.s)
            ldx   VI_LRIDX
            cmp   VI_LNROWS,x
            bne   :rlfull              ;row count changed
            jsr   VI_RPLINE            ;X = its index, ED_TMP16
            jmp   VI_PLACE_CUR         ;still the line
:rlfull     jmp   VI_REPAINT

*---------------------------------------------------------------
* VI_LNROWSOF -- IN: ED_TMP16 = a buffer line. OUT: A = the
* screen rows it takes (cached text -> VI_LNWIDTH -> VI_ROWSOF;
* ED_TMP16 survives). CLOBBERS: A, X, Y, PTR0, VI_WCOL (+
* VI_LTEXTC's).
*---------------------------------------------------------------
VI_LNROWSOF jsr   VI_LTEXTC
            jsr   VI_LNWIDTH
            jmp   VI_ROWSOF

*---------------------------------------------------------------
* VI_RPLINE -- rewrite visible line X in place. IN: X = its
* index (its VI_LNROWS entry valid and still its row count),
* ED_TMP16 = its buffer line. Positions to its first row, writes
* within its rows, erases the tail. The one-line redraw shared
* by VI_RPT_LN and the IL/DL paths' "neighbour line changed
* too" case. CLOBBERS: A, X, Y, PTR0, VI_TMP, VI_LR, VI_WCOL,
* VI_WBUDG.
*---------------------------------------------------------------
VI_RPLINE   lda   VI_LNROWS,x
            sta   VI_LR
            txa
            jsr   VI_LNSUM             ;A = its first row
            ldx   #1
            jsr   VI_CSI_POS
            lda   VI_LR
            jsr   VI_ROWBUDG
            jsr   VI_LTEXTC            ;PTR0 (cache hit)
            jsr   VI_BPUTSW
            jmp   VI_ERSLTAIL

*---------------------------------------------------------------
* VI_REPAINT -- full repaint: walk VI_TOP..VI_TOP+textrows-1,
* one text row each, `~` past EOF (VI-DESIGN sec 2.2/2.3), then
* the status line, then place the cursor. Used on entry,
* any scroll, return from the `:` bridge, and any insert-mode
* exit that touched more than the current line (the conservative
* v1 rule VI-DESIGN sec 2.2 names). CLOBBERS: A, X, Y, PTR0,
* ED_TMP16, VI_TMP, VI_TMP2.
*---------------------------------------------------------------
* -- WRAP-aware (2026-09-05): each line takes VI_ROWSOF(width)
* -- rows, recorded in VI_LNROWS/VI_LNCNT for VI_PLACE_CUR and
* -- VI_RPT_LN. VI_FITCUR first moves VI_TOP so the cursor line
* -- fits. A line that would not fit below is replaced by `@`
* -- rows (real vi); only the TOP line may be clipped.
VI_REPAINT  jsr   VI_FITCUR
            lda   #0                    ;fall into VI_RPFROM(0)
* VI_RPFROM -- IN: A = visible-line index k (0..VI_LNCNT). Paint
* from that line's first row to the bottom of the text window,
* leaving the rows above (and VI_LNROWS[0..k)) untouched. The
* cheap path for a change touching only the cursor line and
* those below; VI_RPCUR picks between this and a full repaint.
VI_RPFROM   stz   VI_RPLIM              ;paint to the bottom
* VI_RPFROMN -- VI_RPFROM that stops after VI_RPLIM (preset by
* the caller, >= 1) real lines instead of at the bottom -- how
* VI_RPINS paints only the inserted lines after the terminal
* shifted the rest. Still ends with the status row and the
* cursor; the caller fixes VI_LNCNT for the lines it kept.
VI_RPFROMN  sta   VI_LNCNT              ;[0,k) stay valid
            jsr   VI_LNSUM              ;A = line k's first row
            sta   VI_TMP2+1             ;physical row, 1-based
            lda   VI_ROWS               ;remaining = textrows -
            sec                         ;row + 1 = VI_ROWS - row
            sbc   VI_TMP2+1             ;(0 when row is already
            bcs   :rprem                ;past the window)
            lda   #0
:rprem      sta   VI_TMP2               ;text rows REMAINING
            clc
            lda   VI_TOP
            adc   VI_LNCNT
            sta   ED_TMP16              ;current buffer line --
            lda   VI_TOP+1              ;kept in ED_TMP16, NOT
            adc   #0                    ;VI_TMP (VI_CSI_POS's
            sta   ED_TMP16+1            ;scratch; found live
                                        ;2026-09-03)
            lda   #1
            sta   VI_NOFLUSH            ;suppress row flush
:rowloop    lda   VI_TMP2
            bne   :rpbody
            jmp   :rowsdone
:rpbody     lda   VI_TMP2+1
            ldx   #1
            jsr   VI_CSI_POS            ;clobbers VI_TMP/+1
            lda   ED_TMP16+1            ;line <= ED_NLINES?
            cmp   ED_NLINES+1
            bcc   :isreal
            bne   :isblank
            lda   ED_TMP16
            cmp   ED_NLINES
            bcc   :isreal
            beq   :isreal
:isblank    lda   #$FE                  ;'~' past EOF: one row
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   VI_ERSLN
            dec   VI_TMP2
            inc   VI_TMP2+1
            bra   :rowloop
:isreal     jsr   VI_LNROWSOF           ;cached (vicache.s); IN:
                                        ;ED_TMP16 (survives it)
            sta   VI_LR
            cmp   VI_TMP2               ;rows > remaining?
            bcc   :rpfits
            beq   :rpfits
            lda   VI_LNCNT              ;the TOP line alone
            bne   :rpat                 ;taller than the window:
            lda   VI_TMP2               ;clip it to the window
            sta   VI_LR
:rpfits     lda   VI_LR
            jsr   VI_ROWBUDG
            jsr   VI_LTEXTC             ;PTR0 again (cache hit)
            jsr   VI_BPUTSW
            jsr   VI_ERSLTAIL
            ldx   VI_LNCNT
            lda   VI_LR
            sta   VI_LNROWS,x
            inc   VI_LNCNT
            lda   VI_TMP2
            sec
            sbc   VI_LR
            sta   VI_TMP2
            lda   VI_TMP2+1
            clc
            adc   VI_LR
            sta   VI_TMP2+1
            inc   ED_TMP16
            bne   :rplim
            inc   ED_TMP16+1
:rplim      lda   VI_RPLIM              ;a bounded paint (VI_RP-
            beq   :rpgo                 ;FROMN): count it down
            dec   VI_RPLIM
            beq   :rowsdone
:rpgo       jmp   :rowloop
:rpat       lda   #$C0                  ;'@': a line that does
            ldx   #FD_STDOUT            ;not fit below (real vi)
            jsr   PUTC
            jsr   VI_ERSLN
            dec   VI_TMP2
            beq   :rowsdone
            inc   VI_TMP2+1
            lda   VI_TMP2+1
            ldx   #1
            jsr   VI_CSI_POS
            bra   :rpat
:rowsdone   jsr   VI_STAT_BLANK
            stz   VI_NOFLUSH           ;final placement flush
            jmp   VI_PLACE_CUR          ;whole repaint at once

*---------------------------------------------------------------
* VI_RPCUR -- repaint from the CURSOR LINE down when VI_TOP need
* not move (VI_FITCUR left it alone), else a full repaint. For a
* change confined to the cursor line and the rows below it: a
* line opened by Enter inside insert, or a line that outgrew its
* rows (viinsert.s). Appending at the end of a short buffer then
* costs one line plus the `~` rows, not the whole window -- a
* full repaint per Enter was slow enough that a 30-line insert
* dropped keystrokes (check-play, 2026-09-05). CLOBBERS: as
* VI_REPAINT.
*---------------------------------------------------------------
VI_RPCUR    ldx   #0                    ;from the cursor line
            bra   :rcgo
* VI_RPCURP -- like VI_RPCUR but starts ONE line ABOVE cursor.
* An Enter inside insert (viinsert.s :docr) finalizes the line
* ABOVE the new cursor line (its suffix moved down), so it
* changed too and must be repainted -- from the cursor alone it
* stayed stale ("hello ABworld" instead of "hello AB", check-vi
* wrap, 2026-09-05). Same clobbers as VI_RPCUR.
VI_RPCURP   ldx   #1                    ;from cursor-1
:rcgo       stx   VI_RPADJ
            lda   VI_TOP
            pha
            lda   VI_TOP+1
            pha
            jsr   VI_FITCUR
            pla
            cmp   VI_TOP+1
            bne   :rcfull2
            pla
            cmp   VI_TOP
            bne   :rcfull
            sec
            lda   ED_CURLINE
            sbc   VI_TOP                ;k = curline-top (<256:
            cmp   VI_LNCNT              ;fits: within or right
            bcc   :rchavk               ;after the table)
            beq   :rchavk
            lda   VI_LNCNT
:rchavk     sec
            sbc   VI_RPADJ              ;back over a finalized
            bcs   :rcfrom               ;line (floor at 0)
            lda   #0
:rcfrom     jmp   VI_RPFROM
:rcfull2    pla                         ;balance the stack
:rcfull     lda   #0                    ;top moved: everything
            jmp   VI_RPFROM             ;(already fitted above)

*---------------------------------------------------------------
* The IL/DL redisplay (VI-DESIGN sec 2.2, 2026-09-11). A line
* opened (o/O/p/P, Enter inside insert) or removed (dd, a
* linewise d, the lines a cross-line d/c, cc or J fold away)
* used to repaint from the cursor to the bottom. Now ONE ESC[r;
* 1H + ESC[nL / ESC[nM -- the terminal shifts the rows below
* (docs/CONSOLE.md sec 4) -- and only the new/exposed rows are
* painted, the painted-row table fixed in place. THE INVARIANT:
* VI_LNROWS/VI_LNCNT must describe the glass byte-exactly
* afterwards, or the next VI_PLACE_CUR/VI_RPT_LN lands on the
* wrong row. So the fast path is taken only where the shift is
* provably rows == lines (see each routine), and every other
* shape falls back to VI_RPFROM from the first changed line --
* the same result, more bytes.
*---------------------------------------------------------------
* VI_ILSAVE -- shared prologue: remember VI_TOP/VI_LNCNT
* (VI_ILTOP/VI_ILSAV), fit the cursor. OUT: carry SET when
* VI_FITCUR moved VI_TOP. CLOBBERS: A + VI_FITCUR's.
*---------------------------------------------------------------
VI_ILSAVE   lda   VI_LNCNT
            sta   VI_ILSAV
            lda   VI_TOP
            sta   VI_ILTOP
            lda   VI_TOP+1
            sta   VI_ILTOP+1
            jsr   VI_FITCUR
            lda   VI_TOP
            cmp   VI_ILTOP
            bne   :ilmoved
            lda   VI_TOP+1
            cmp   VI_ILTOP+1
            bne   :ilmoved
            clc
            rts
:ilmoved    sec
            rts

*---------------------------------------------------------------
* VI_ILADJCK -- the line right above visible index VI_ILK also
* changed (the Enter split's upper half, the join/cc line).
* OUT: carry SET if it is on the glass and its row count still
* matches its table entry (VI_RPLINE can redraw it in place;
* ED_TMP16 = its buffer line, left for that), CLEAR otherwise
* (including VI_ILK = 0: nothing above). CLOBBERS: A, X, Y,
* PTR0, ED_TMP16, VI_LR, VI_WCOL.
*---------------------------------------------------------------
VI_ILADJCK  lda   VI_ILK
            beq   :adjno
            sec
            sbc   #1
            sta   VI_LR
            clc
            adc   VI_TOP
            sta   ED_TMP16
            lda   VI_TOP+1
            adc   #0
            sta   ED_TMP16+1
            jsr   VI_LNROWSOF
            ldx   VI_LR
            cmp   VI_LNROWS,x
            bne   :adjno
            sec
            rts
:adjno      clc
            rts

*---------------------------------------------------------------
* VI_ILSLOW -- the fallback: repaint from the first changed line
* (VI_ILK, minus one when its upper neighbour changed too),
* clamped to the painted table like VI_RPCUR. VI_TOP is already
* fitted. CLOBBERS: VI_RPFROM's.
*---------------------------------------------------------------
VI_ILSLOW   lda   VI_ILK
            cmp   VI_LNCNT
            bcc   :slowk
            lda   VI_LNCNT
:slowk      sec
            sbc   VI_ILADJ
            bcs   :slowgo
            lda   #0
:slowgo     jmp   VI_RPFROM

*---------------------------------------------------------------
* VI_RPINS -- redisplay after n lines were INSERTED with
* ED_CURLINE the first of them (o/O, a linewise p/P, the Enter
* inside insert). IN: A = n (>= 1), X = 1 when the line ABOVE
* the cursor line changed too (the Enter split: its suffix moved
* down), else 0. Fast path: ESC[r;1H + ESC[nL at the cursor
* line's row, paint ONLY the n new lines (and the split line
* above, in place), then extend the table: the shifted lines
* keep their one-row entries. Conditions: VI_TOP unchanged;
* every painted line from the cursor's index is one row (the
* terminal shifts ROWS, so rows must equal lines); each new line
* is one row; the split line's row count unchanged. A cursor
* line that fell off the bottom (o/Enter/p on the last row) of
* an unwrapped window scrolls the glass instead -- ESC[nS, the
* VI_SCROLL_DN partial scroll -- and paints from the first new
* line. Anything else: VI_ILSLOW. CLOBBERS: A, X, Y, PTR0,
* ED_TMP16, VI_TMP, VI_TMP2, VI_LR, VI_LRIDX, VI_WCOL, VI_WBUDG,
* VI_IL*, VI_RPLIM, VI_NOFLUSH (+ VI_RPFROM's).
*---------------------------------------------------------------
VI_RPINS    stx   VI_ILADJ
            sta   VI_ILN
            lda   VI_ILN               ;set Z on n itself -- the
            bne   :ingo                ;caller ldx set it
            jmp   VI_REPAINT            ;nothing inserted (an
:ingo       jsr   VI_ILSAVE             ;empty register): as was
            bcc   :infit
            jmp   :inmoved              ;(out of branch range)
:inslow     jmp   VI_ILSLOW             ;(branch-range stub)
:infit
            sec                         ;k = curline - top
            lda   ED_CURLINE
            sbc   VI_TOP
            sta   VI_ILK
            lda   ED_CURLINE+1
            sbc   VI_TOP+1
            bne   :inslow
            lda   VI_ILK
            cmp   VI_LNCNT              ;k <= lines painted (==
            beq   :inunw                ;is right after them)
            bcs   :inslow
:inunw      ldx   VI_ILK                ;the painted lines from
:inuloop    cpx   VI_LNCNT              ;k: all one row?
            bcs   :innew
            lda   VI_LNROWS,x
            cmp   #1
            bne   :inslow
            inx
            bra   :inuloop
:innew      lda   ED_CURLINE            ;the n new lines: one
            sta   ED_TMP16              ;row each?
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            ldx   VI_ILN
:innloop    phx
            jsr   VI_LNROWSOF
            plx
            cmp   #1
            bne   :inslow
            inc   ED_TMP16
            bne   :innnext
            inc   ED_TMP16+1
:innnext    dex
            bne   :innloop
            lda   VI_ILADJ              ;the split line above:
            beq   :inemit               ;rows unchanged?
            jsr   VI_ILADJCK
            bcc   :inslow
:inemit     lda   VI_ILK
            jsr   VI_LNSUM
            sta   VI_ILROW              ;r = cursor line's row
            lda   #1
            sta   VI_NOFLUSH            ;one flush, at the end
            lda   VI_ILROW
            ldx   #1
            jsr   VI_CSI_POS
            lda   VI_ILN
            jsr   VI_EMIT_IL            ;the glass shifts down
            lda   VI_ILADJ
            beq   :inpaint
            ldx   VI_ILK                ;the split line in place
            dex                         ;(ED_TMP16 = it, from
            jsr   VI_RPLINE             ;VI_ILADJCK)
:inpaint    lda   VI_ILN
            sta   VI_RPLIM              ;paint the n new lines
            lda   VI_ILK                ;only; status + cursor
            jsr   VI_RPFROMN
            lda   VI_ILSAV              ;lines still on glass
            clc                         ;below: min(old + n,
            adc   VI_ILN                ;k + rows from r down)
            sta   VI_TMP
            lda   VI_ROWS
            sec
            sbc   VI_ILROW
            clc
            adc   VI_ILK
            cmp   VI_TMP
            bcs   :infill
            sta   VI_TMP
:infill     ldx   VI_LNCNT              ;the shifted lines: one
:infloop    cpx   VI_TMP                ;row each (checked)
            bcs   :infdone
            lda   #1
            sta   VI_LNROWS,x
            inx
            bra   :infloop
:infdone    stx   VI_LNCNT
            rts
*-- The cursor line left the window (below): an unwrapped window
*-- that moved less than a screen scrolls the glass up by the
*-- move and paints from the first new line (the split line
*-- above it too) -- VI_SCROLL_DN's partial scroll, here for an
*-- edit. The table stays all-ones; VI_RPFROM resets VI_LNCNT.
:inmoved    lda   VI_ROWS
            sec
            sbc   #1                    ;textrows
            cmp   VI_ILSAV              ;window was unwrapped?
            bne   :infull
            lda   VI_TOP+1
            cmp   VI_ILTOP+1
            bne   :infull
            sec
            lda   VI_TOP
            sbc   VI_ILTOP              ;delta = new - old top
            bcc   :infull               ;moved up: full
            beq   :infull
            sta   VI_TMP
            lda   VI_ROWS
            sec
            sbc   #1
            cmp   VI_TMP                ;delta < textrows
            bcc   :infull
            beq   :infull
            lda   VI_TMP
            jsr   VI_EMIT_SU            ;scroll the glass up
            sec                         ;paint from the first
            lda   ED_CURLINE            ;new line, or the split
            sbc   VI_TOP                ;line above it
            sec
            sbc   VI_ILADJ
            jmp   VI_RPFROM
:infull     lda   #0                    ;top moved: everything
            jmp   VI_RPFROM             ;(already fitted)

*---------------------------------------------------------------
* VI_RPDEL -- redisplay after n buffer lines were DELETED
* starting at line ED_TMP16B (dd and the linewise d motions;
* the lines a cross-line charwise d/c, a J or a cc folded away).
* IN: A = n, X = 1 when the cursor line -- right above the
* deleted ones -- changed text too (the join/cc shape), else 0.
* n = 0 (with X = 1) is the one-line case: VI_RPT_LN. Fast path:
* ESC[r;1H + ESC[mM with m the deleted lines' ROW count -- the
* terminal pulls the rows below up -- shift the table entries
* down over them, then paint only what the pull exposed: the
* lines that scroll in at the bottom (VI_RPFROM from the first
* of them), or, when the file already ended on the glass, `~` on
* the m exposed rows plus the status row. Lines below MAY wrap
* (their rows move intact). Conditions, else VI_ILSLOW: VI_TOP
* unchanged; the deleted lines were painted and at least one
* painted line survives below them (else the repaint from k IS
* the cheapest); the changed cursor line keeps its row count.
* CLOBBERS: as VI_RPINS, + VI_ILDLR.
*---------------------------------------------------------------
VI_RPDEL    stx   VI_ILADJ
            sta   VI_ILN
            lda   VI_ILN               ;set Z on n itself -- the
            bne   :dlgo                ;caller ldx set it
            jmp   VI_RPT_LN             ;nothing deleted: the
:dlgo       jsr   VI_ILSAVE             ;cursor line alone
            bcc   :dltop
            lda   #0                    ;top moved: everything
            jmp   VI_RPFROM
:dlslow     jmp   VI_ILSLOW             ;(branch-range stub)
:dltop      sec                         ;k = first - top
            lda   ED_TMP16B
            sbc   VI_TOP
            sta   VI_ILK
            lda   ED_TMP16B+1
            sbc   VI_TOP+1
            beq   :dlk
            lda   VI_LNCNT              ;far below: the gap
            sta   VI_ILK
:dlk        lda   VI_ILK
            cmp   VI_LNCNT
            bcs   :dlslow               ;not painted: from there
            lda   VI_LNCNT              ;painted lines from k
            sec
            sbc   VI_ILK
            cmp   VI_ILN
            bcc   :dlslow               ;all gone: repaint k..
            beq   :dlslow
            lda   VI_ILADJ              ;changed cursor line:
            beq   :dlrows               ;rows unchanged?
            jsr   VI_ILADJCK
            bcc   :dlslow
:dlrows     ldx   VI_ILK                ;rows the deleted lines
            ldy   VI_ILN                ;held = the DL count
            lda   #0
:dlrloop    clc
            adc   VI_LNROWS,x
            inx
            dey
            bne   :dlrloop
            sta   VI_ILDLR
            lda   #1
            sta   VI_NOFLUSH
            lda   VI_ILK
            jsr   VI_LNSUM
            sta   VI_ILROW
            ldx   #1
            jsr   VI_CSI_POS
            lda   VI_ILDLR
            jsr   VI_EMIT_DL            ;the glass pulls up
            lda   VI_ILADJ
            beq   :dlmove
            ldx   VI_ILK                ;cursor line, in place
            dex                         ;(ED_TMP16 = it)
            jsr   VI_RPLINE
:dlmove     ldx   VI_ILK                ;table: [k+n, cnt) down
            lda   VI_ILK                ;to [k, cnt-n)
            clc
            adc   VI_ILN
            tay
:dlmloop    cpy   VI_LNCNT
            bcs   :dlmdone
            lda   VI_LNROWS,y
            sta   VI_LNROWS,x
            inx
            iny
            bra   :dlmloop
:dlmdone    stx   VI_LNCNT              ;= old count - n
            clc                         ;top + count <= NLINES:
            lda   VI_TOP                ;lines scroll in below
            adc   VI_LNCNT
            sta   VI_TMP
            lda   VI_TOP+1
            adc   #0
            cmp   ED_NLINES+1
            bcc   :dlmore
            bne   :dltilde
            lda   VI_TMP
            cmp   ED_NLINES
            bcc   :dlmore
            beq   :dlmore
:dltilde    lda   VI_ROWS               ;file ended on glass:
            sec                         ;exposed rows VI_ROWS
            sbc   VI_ILDLR              ;-m .. VI_ROWS-1 are `~`
            sta   VI_TMP2+1
            lda   VI_ILDLR
            sta   VI_TMP2
:dltloop    lda   VI_TMP2+1
            ldx   #1
            jsr   VI_CSI_POS
            lda   #$FE                  ;'~'
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   VI_ERSLN
            inc   VI_TMP2+1
            dec   VI_TMP2
            bne   :dltloop
            jsr   VI_STAT_BLANK         ;pulled-up status row
            stz   VI_NOFLUSH
            jmp   VI_PLACE_CUR
:dlmore     lda   VI_LNCNT              ;paint from the first
            jmp   VI_RPFROM             ;line that scrolled in
