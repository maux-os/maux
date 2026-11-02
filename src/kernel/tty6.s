*---------------------------------------------------------------
* tty6.s -- the readline-lite editor and command history
* (docs/CONSOLE.md sec 4b).
*
* SPLIT OUT OF tty3.s AT BIRTH, 2026-08-31, for the same reason
* every tty split exists: tty3.s + the editor blew real
* Merlin's 41,215 B source buffer (check-librel: KTTY3 41,226
* resident) and pushed 15 harness units past as's source
* window (check-dialect). The cut is at a section boundary and
* this file is `put` immediately after tty3.s. Kernel modules
* are one flat symbol space: tty3.s's cook dispatch jmp/jsrs
* straight in.
*---------------------------------------------------------------
*---------------------------------------------------------------
* READLINE-LITE (docs/CONSOLE.md sec 4b, 2026-08-31). Cook-
* context only -- runs where TTY_COOK1 runs, so the same tick-
* path safety argument applies (no syscall is ever mid-flight
* when a tick fires; tty5.s's exposure note names the rule that
* keeps it true).
*
* DISPLAY RULE: paint FORWARD through TTY_PUT_BYTE, which owns
* wrap and scroll, then walk the cursor BACK a known count.
* Relative motion only -- a scroll can fire only on the final
* freshly-painted cell of a forward pass, and a relative back-
* walk from wherever the pass ended is correct either way. No
* anchors, no scroll counters, nothing for a scroll to strand.
*---------------------------------------------------------------

* Screen cursor one cell left/right, wrap included. Motion never
* leaves painted text, so no scroll can fire here.
TTY_ED_CLF
            lda   VC_COL
            bne   :same
            lda   TTY_COLS
            sta   VC_COL
            dec   VC_ROW
:same       dec   VC_COL
            rts

TTY_ED_CRT
            inc   VC_COL
            lda   VC_COL
            cmp   TTY_COLS
            bcc   :ok
            stz   VC_COL
            inc   VC_ROW
:ok         rts

* Walk the screen cursor back A cells (A may be 0). Preserves
* nothing.
TTY_ED_BWK
            tax
            beq   :done
:lp         jsr   TTY_ED_CLF
            dex
            bne   :lp
:done       rts

*---------------------------------------------------------------
* TTY_ED_ECHO -- print A (readline-lite's own high-bit storage
* form) through TTY_PUT_BYTE, then immediately resolve a pending
* xenl wrap the same call may have just armed (VT102 slice 3,
* docs/CONSOLE-VT102.md sec 2/4). Every readline-lite call site
* that paints N characters and later walks the SCREEN cursor
* back N cells (TTY_ED_BWK, above -- its own stepping model,
* TTY_ED_CLF, is immediate-wrap and always has been) needs this:
* deferred-then-consumed-by-the-next-character is not invertible
* from (row,col,xenl) alone, since the consuming step and an
* ordinary step land on the same (row,col). A real write()
* through TTY_WRITE gets to defer the wrap VT102-style because
* nothing there plans to walk itself back by counting steps;
* readline-lite does, so it resolves its OWN wrap on the spot --
* exactly what happened before xenl existed. Found live: check-
* play's cooked-mode erase-crosses-wrap case went red (TTY_ED_
* DEL's blank-and-walk-back overshot at the wrap boundary) the
* first time xenl ran against it.
*---------------------------------------------------------------
TTY_ED_ECHO jsr   TTY_PUT_BYTE
            lda   VC_XENL
            beq   :ok
            stz   VC_XENL
            jmp   TTY_NEWLINE
:ok         rts

TTY_ED_LEFT
            lda   VC_EDIT_POS
            beq   :done
            dec   VC_EDIT_POS
            jsr   TTY_ED_CLF
:done       rts

TTY_ED_RIGHT
            lda   VC_EDIT_POS
            cmp   VC_EDIT_LEN
            bcs   :done
            inc   VC_EDIT_POS
            jsr   TTY_ED_CRT
:done       rts

TTY_ED_HOME
:lp         lda   VC_EDIT_POS
            beq   :done
            jsr   TTY_ED_LEFT
            bra   :lp
:done       rts

TTY_ED_END
:lp         lda   VC_EDIT_POS
            cmp   VC_EDIT_LEN
            bcs   :done
            jsr   TTY_ED_RIGHT
            bra   :lp
:done       rts

* Carry SET if VC_INBUF,x is a word char (alnum; buffer bytes
* carry bit 7).
TTY_ED_ISW
            lda   VC_INBUF,x
            and   #$7F
            cmp   #$30
            bcc   :no
            cmp   #$3A
            bcc   :yes
            cmp   #$41
            bcc   :no
            cmp   #$5B
            bcc   :yes
            cmp   #$61
            bcc   :no
            cmp   #$7B
            bcc   :yes
:no         clc
            rts
:yes        sec
            rts

* M-f: forward over non-word, then over the word.
TTY_ED_WDF
:sk1        lda   VC_EDIT_POS
            cmp   VC_EDIT_LEN
            bcs   :done
            tax
            jsr   TTY_ED_ISW
            bcs   :sk2
            jsr   TTY_ED_RIGHT
            bra   :sk1
:sk2        lda   VC_EDIT_POS
            cmp   VC_EDIT_LEN
            bcs   :done
            tax
            jsr   TTY_ED_ISW
            bcc   :done
            jsr   TTY_ED_RIGHT
            bra   :sk2
:done       rts

* M-b: back over non-word, then over the word.
TTY_ED_WDB
:sk1        lda   VC_EDIT_POS
            beq   :done
            tax
            dex
            jsr   TTY_ED_ISW
            bcs   :sk2
            jsr   TTY_ED_LEFT
            bra   :sk1
:sk2        lda   VC_EDIT_POS
            beq   :done
            tax
            dex
            jsr   TTY_ED_ISW
            bcc   :done
            jsr   TTY_ED_LEFT
            bra   :sk2
:done       rts

* Paint buffer bytes [A .. VC_EDIT_LEN) through TTY_PUT_BYTE.
* ED_CNT counts what was WALKED, echo or not (stty seed,
* 2026-09-02) -- with ECHO clear the glyph write is skipped but
* the count callers walk the cursor back by is unchanged, so a
* noecho console's cursor bookkeeping stays exactly as
* consistent as an echoing one's; only the ink is missing.
TTY_ED_PTL
            sta   ED_IDX
            stz   ED_CNT
:lp         lda   ED_IDX
            cmp   VC_EDIT_LEN
            bcs   :done
            tax
            lda   VC_TMODE
            and   #TMD_ECHO
            beq   :nopaint
            lda   VC_INBUF,x
            jsr   TTY_ED_ECHO
:nopaint    inc   ED_IDX
            inc   ED_CNT
            bra   :lp
:done       rts

* Insert A (bit 7 already set) at the cursor. The caller checked
* room. Appending (cursor at end) degenerates to the pre-4b
* echo-and-append exactly.
TTY_ED_INS
            sta   ED_CH
            ldx   VC_EDIT_LEN
:mv         cpx   VC_EDIT_POS
            beq   :place
            lda   VC_INBUF-1,x
            sta   VC_INBUF,x
            dex
            bra   :mv
:place      lda   ED_CH
            sta   VC_INBUF,x
            inc   VC_EDIT_LEN
            lda   VC_EDIT_POS
            inc   VC_EDIT_POS
            jsr   TTY_ED_PTL
            lda   ED_CNT
            sec
            sbc   #1
            jmp   TTY_ED_BWK

* Delete the char BEFORE the cursor; close the gap; repaint the
* shifted tail and blank the vacated cell. The blank repaints an
* EXISTING cell, so it cannot corner-scroll.
TTY_ED_DEL
            lda   VC_EDIT_POS
            beq   :done
            dec   VC_EDIT_POS
            dec   VC_EDIT_LEN
            ldx   VC_EDIT_POS
:mv         cpx   VC_EDIT_LEN
            beq   :disp
            lda   VC_INBUF+1,x
            sta   VC_INBUF,x
            inx
            bra   :mv
:disp       jsr   TTY_ED_CLF
            lda   VC_EDIT_POS
            jsr   TTY_ED_PTL
            lda   VC_TMODE          ;stty: the vacated cell's
            and   #TMD_ECHO         ;blank is an ECHO paint too
            beq   :noblank
            lda   #$A0
            jsr   TTY_ED_ECHO
:noblank    lda   ED_CNT
            clc
            adc   #1
            jmp   TTY_ED_BWK
:done       rts

* ^U: kill the whole line from any cursor position -- walk to
* the end, then erase back one cell at a time: step left
* (TTY_ED_CLF, wrapping onto the previous row) and blank. This
* is readline-lite's OWN destructive erase; the terminal's BS
* (tty2.s TTY_BACKSPACE) is a plain non-erasing column move
* since VT102 slice 6 (finding VT2), so it can no longer be
* borrowed for this.
TTY_ED_KILL
            jsr   TTY_ED_END
            lda   VC_EDIT_LEN
            beq   :done
:lp         lda   VC_TMODE          ;stty seed: gate the paint,
            and   #TMD_ECHO         ;not the countdown
            beq   :nopaint
            jsr   TTY_ED_CLF
            jsr   TTY_BLNK_CELL
:nopaint    dec   VC_EDIT_LEN
            bne   :lp
            stz   VC_EDIT_POS
:done       rts

* ^K: truncate at the cursor; blank the dead tail (existing
* cells only -- no corner-scroll) and walk back.
TTY_ED_KEOL
            lda   VC_EDIT_LEN
            sec
            sbc   VC_EDIT_POS
            beq   :done
            sta   ED_TMP
            sta   ED_CNT
            lda   VC_EDIT_POS
            sta   VC_EDIT_LEN
:lp         lda   VC_TMODE          ;stty seed: gate the paint,
            and   #TMD_ECHO         ;not the countdown
            beq   :nopaint
            lda   #$A0
            jsr   TTY_ED_ECHO
:nopaint    dec   ED_TMP
            bne   :lp
            lda   ED_CNT
            jmp   TTY_ED_BWK
:done       rts

*---------------------------------------------------------------
* History (sec 4b): 8-entry ring + 1 walk stash per console in
* the annex (VC_HIST_ADDR, mm.annex.equ), entries [len byte
* + line], reached only through BankCopy. Every path that copies
* ends in PRC_SEL_CRBNK -- the same $C073-goes-home obligation
* TTY_WAKE_RDRS discharges.
*---------------------------------------------------------------
EDH_BAS0    equ   VC_HIST_ADDR
EDH_BAS1    equ   EDH_BAS0+VC_HIST_SIZE
EDH_BAS2    equ   EDH_BAS1+VC_HIST_SIZE
EDH_BAS3    equ   EDH_BAS2+VC_HIST_SIZE
EDH_CLO     dfb   <EDH_BAS0,<EDH_BAS1
            dfb   <EDH_BAS2,<EDH_BAS3
EDH_CHI     dfb   >EDH_BAS0,>EDH_BAS1
            dfb   >EDH_BAS2,>EDH_BAS3

* A = slot 0..8 -> ED_ALO/ED_AHI = annex address of the ACTIVE
* console's slot (base + slot*128).
TTY_EDH_ADR
            sta   ED_TMP
            ldx   VC_ACTIVE
            lda   EDH_CLO,x
            sta   ED_ALO
            lda   EDH_CHI,x
            sta   ED_AHI
            lda   ED_TMP
            and   #1
            beq   :even
            clc
            lda   ED_ALO
            adc   #$80
            sta   ED_ALO
            bcc   :even
            inc   ED_AHI
:even       lda   ED_TMP
            lsr
            clc
            adc   ED_AHI
            sta   ED_AHI
            rts

* A = walk depth K -> A = ring slot (VC_HIST_W - 1 - K) & 7.
TTY_EDH_SLK
            sta   ED_TMP
            lda   VC_HIST_W
            sec
            sbc   #1
            sec
            sbc   ED_TMP
            and   #7
            rts

* Save the edit buffer to slot A: [VC_EDIT_LEN][bytes]. K_BC_ERR
* is not checked -- both endpoints are fixed kernel addresses
* (the VC_SAVE_X precedent).
TTY_EDH_SAV
            jsr   TTY_EDH_ADR
            lda   VC_EDIT_LEN
            sta   ED_HLEN
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<ED_HLEN
            sta   K_BC_SRCADDR
            lda   #>ED_HLEN
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   ED_ALO
            sta   K_BC_DSTADDR
            lda   ED_AHI
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   #1
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   ED_HLEN
            beq   :done
            inc   ED_ALO                  ;slot lows are $00 or
                                          ;$80 -- +1 never
                                          ;carries
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<VC_INBUF
            sta   K_BC_SRCADDR
            lda   #>VC_INBUF
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   ED_ALO
            sta   K_BC_DSTADDR
            lda   ED_AHI
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   ED_HLEN
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
:done       rts

* Load slot A into the edit buffer; VC_EDIT_LEN follows.
TTY_EDH_LOD
            jsr   TTY_EDH_ADR
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   ED_ALO
            sta   K_BC_SRCADDR
            lda   ED_AHI
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            lda   #<ED_HLEN
            sta   K_BC_DSTADDR
            lda   #>ED_HLEN
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   #1
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   ED_HLEN
            sta   VC_EDIT_LEN
            beq   :done
            inc   ED_ALO                  ;see TTY_EDH_SAV
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   ED_ALO
            sta   K_BC_SRCADDR
            lda   ED_AHI
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            lda   #<VC_INBUF
            sta   K_BC_DSTADDR
            lda   #>VC_INBUF
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   ED_HLEN
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
:done       rts

* ^P / up arrow. First press stashes the in-progress line, so a
* stray walk costs nothing; edits to a RECALLED line are
* discarded by further walking (v1 -- bash keeps them per-entry,
* we do not).
TTY_ED_HPRV
            lda   VC_HIST_N
            beq   :out
            lda   VC_HIST_CUR
            cmp   #$FF
            bne   :deeper
            lda   #8
            jsr   TTY_EDH_SAV
            stz   VC_HIST_CUR
            bra   :load
:deeper     clc
            adc   #1
            cmp   VC_HIST_N
            bcs   :bank                   ;at the oldest: stay
            sta   VC_HIST_CUR
:load       jsr   TTY_ED_KILL
            lda   VC_HIST_CUR
            jsr   TTY_EDH_SLK
            jsr   TTY_EDH_LOD
            lda   #0
            jsr   TTY_ED_PTL
            lda   VC_EDIT_LEN
            sta   VC_EDIT_POS
:bank       jmp   PRC_SEL_CRBNK
:out        rts

* ^N / down arrow. Walking past the newest restores the stash.
TTY_ED_HNXT
            lda   VC_HIST_CUR
            cmp   #$FF
            beq   :out
            cmp   #0
            beq   :unstash
            sec
            sbc   #1
            sta   VC_HIST_CUR
            jsr   TTY_ED_KILL
            lda   VC_HIST_CUR
            jsr   TTY_EDH_SLK
            jsr   TTY_EDH_LOD
            bra   :paint
:unstash    jsr   TTY_ED_KILL
            lda   #8
            jsr   TTY_EDH_LOD
            lda   #$FF
            sta   VC_HIST_CUR
:paint      lda   #0
            jsr   TTY_ED_PTL
            lda   VC_EDIT_LEN
            sta   VC_EDIT_POS
            jmp   PRC_SEL_CRBNK
:out        rts

* Commit hook, called by :cr and :eof BEFORE the CR lands in
* the buffer: record a non-empty line, reset cursor and walk.
* No dedup in v1 (a compare needs the newest entry back in main
* memory and TTY_OUTBUF is 96B against a 126B line) -- a
* consecutive duplicate costs one extra ^P.
TTY_ED_CMIT
            stz   VC_EDIT_POS
            lda   #$FF
            sta   VC_HIST_CUR
            lda   VC_EDIT_LEN
            beq   :out
            lda   VC_HIST_W
            jsr   TTY_EDH_SAV
            lda   VC_HIST_W
            clc
            adc   #1
            and   #7
            sta   VC_HIST_W
            lda   VC_HIST_N
            cmp   #8
            bcs   :bank
            inc   VC_HIST_N
:bank       jmp   PRC_SEL_CRBNK
:out        rts

*-- Editor scratch -- global on purpose: only the ACTIVE console
*-- cooks, ever (one keyboard), so per-console copies would buy
*-- nothing and cost 4x the slot bytes.
ED_MKEY     ds 1               ;key in flight across the OA-
                               ;meta prefix push (TTY_KEYIN)
ED_CH       ds 1               ;byte being inserted
ED_IDX      ds 1               ;TTY_ED_PTL walk index
ED_CNT      ds 1               ;TTY_ED_PTL painted count
ED_TMP      ds 1               ;small loop scratch
ED_HLEN     ds 1               ;history entry length byte
ED_ALO      ds 1               ;computed annex slot address
ED_AHI      ds 1

* VC_SAVE_X / VC_LOAD_X -- move the active image to/from annex
* slot X via BankCopy (bank 0 = the annex). BankCopy owns the
* 80STORE bracket and restores it exactly; the slots sit at
* $7000+, nowhere near the video apertures. K_BC_ERR is not
* checked: both endpoints are fixed kernel addresses, so the
* only failure BankCopy can report (bad range) is a build-time
* bug -- and check-vc's checksummed roundtrip is the gate that
* would catch it.
VC_SAVE_X
            jsr   VC_BC_COMM
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<VC_STATE
            sta   K_BC_SRCADDR
            lda   #>VC_STATE
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   VC_SLT_LO,x
            sta   K_BC_DSTADDR
            lda   VC_SLT_HI,x
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK             ;bank 0 = the annex
            jmp   BankCopy

VC_LOAD_X
            jsr   VC_BC_COMM
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   VC_SLT_LO,x
            sta   K_BC_SRCADDR
            lda   VC_SLT_HI,x
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK             ;bank 0 = the annex
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            lda   #<VC_STATE
            sta   K_BC_DSTADDR
            lda   #>VC_STATE
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            jmp   BankCopy

VC_BC_COMM                     ;shared length; preserves X
            lda   #<VC_ST_SIZE
            sta   K_BC_LEN
            lda   #>VC_ST_SIZE
            sta   K_BC_LEN+1
            rts

VC_MASK_X                      ;A = bit for console X (1<<X)
            lda   #1
:shift      cpx   #0
            beq   :out
            asl
            dex
            bra   :shift
:out        rts

*-- THE VIDMODE MACHINERY (TTY_HW_SET, the N8 blit,
*-- TTY_CSI_MODE) lives in src/kernel/tty7.s, put directly after
*-- this file -- split 2026-09-01 when this file's STRIPPED size
*-- (18,191) alone outgrew as's 16,128-byte source window and
*-- every kernel harness got charged for it (check-dialect 3b).
