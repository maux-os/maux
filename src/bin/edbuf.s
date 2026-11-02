*---------------------------------------------------------------
* edbuf.s -- ed's buffer-management half, split from
* edparse.s at a GLOBAL boundary for the as source
* window (S9-PLAN sec 6, tier 2). One assembly stream:
* ALWAYS put immediately after its predecessor; every
* rule in the original header applies unchanged.
*---------------------------------------------------------------
ED_BUMPDST  inc   ED_DST
            bne   :nb
            inc   ED_DST+1
:nb         rts

* -- more zero page, past the $30-$52 already claimed above --
ED_DELDST   equ   $53        ;2  ED_DLT_RANGE's compaction
                             ;dest cursor
ED_DELSRC   equ   $55        ;2  ED_DLT_RANGE's compaction
                             ;src cursor
* See B.ED.TXT: "window now $30-$56 39 bytes --"

*---------------------------------------------------------------
* Line-table primitives. The table (ED_LINES) is MAXLINES+1
* slots of 2 bytes each (slot 0 unused -- lines are numbered
* 1..ED_NLINES), each slot holding a pointer to that line's NUL-
* terminated text somewhere in ED_TEXTBUF.
*---------------------------------------------------------------

*---------------------------------------------------------------
* ED_LTSLOT -- IN: ED_TMP16 = line number n. OUT: ED_LTPTR =
* &ED_LINES[n].
*---------------------------------------------------------------
ED_LTSLOT   lda   ED_TMP16
            sta   ED_LTPTR
            lda   ED_TMP16+1
            sta   ED_LTPTR+1
            asl   ED_LTPTR
            rol   ED_LTPTR+1
            clc
            lda   ED_LTPTR
            adc   #<ED_LINES
            sta   ED_LTPTR
            lda   ED_LTPTR+1
            adc   #>ED_LINES
            sta   ED_LTPTR+1
            rts

*---------------------------------------------------------------
* ED_GETSLOT -- IN: ED_TMP16=n. OUT: ED_SRC/ED_SRC+1 =
* ED_LINES[n]. ED_SETSLOT -- IN: ED_TMP16=n,
* ED_SRC/ED_SRC+1=value. Writes ED_LINES[n].
*---------------------------------------------------------------
ED_GETSLOT  jsr   ED_LTSLOT
            ldy   #0
            lda   (ED_LTPTR),y
            sta   ED_SRC
            iny
            lda   (ED_LTPTR),y
            sta   ED_SRC+1
            rts

ED_SETSLOT  jsr   ED_LTSLOT
            ldy   #0
            lda   ED_SRC
            sta   (ED_LTPTR),y
            iny
            lda   ED_SRC+1
            sta   (ED_LTPTR),y
            rts

*---------------------------------------------------------------
* ED_LINETEXT -- IN: ED_TMP16 = line number n (1..ED_NLINES,
* caller's responsibility to keep in range -- no bounds check
* here). OUT: PTR0 = that line's text pointer.
*---------------------------------------------------------------
ED_LINETEXT jsr   ED_LTSLOT
            ldy   #0
            lda   (ED_LTPTR),y
            sta   PTR0
            iny
            lda   (ED_LTPTR),y
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* ED_ROOM -- IN: ED_NEEDEND = one past the last byte the caller
* is about to write. Grows the break in ED_GROW_SZ steps until
* ED_TEND covers it. OUT: carry clear = covered (ED_TEND may
* have moved); carry set = the kernel refused, the break is at
* PRC_BRK_LIM and the buffer is GENUINELY full -- the caller's
* existing out-of-memory path is now the truth about the bank,
* not about a constant somebody typed.
*
* This is the whole reason the text buffer stopped being
* `ED_TEXTBUF ds 36480`: that number had to be re-derived by
* hand against a real build every time this file grew, and once
* wasn't -- liba's buffered-stream module pushed ed.bin SEVEN
* bytes into the $BF00 overlay page with every gate green (see
* the trim note at the end of this file). The kernel checks it
* now, on every allocation, at run time.
*---------------------------------------------------------------
ED_ROOM     lda   ED_NEEDEND+1
            cmp   ED_TEND+1
            bcc   :fits
            bne   :grow
            lda   ED_NEEDEND
            cmp   ED_TEND
            beq   :fits
            bcc   :fits
:grow       lda   #<ED_GROW_SZ
            sta   PTR0
            lda   #>ED_GROW_SZ
            sta   PTR0+1
            jsr   SC_SBRK
            bcs   :nomem
            stz   PTR0              ;sbrk(0) -- ask the KERNEL
            stz   PTR0+1            ;  where the break is now
            jsr   SC_SBRK           ;  instead of re-deriving it
            bcs   :nomem
            lda   PTR0
            sta   ED_TEND
            lda   PTR0+1
            sta   ED_TEND+1
            bra   ED_ROOM
:fits       clc
            rts
:nomem      sec
            rts

* See B.ED.TXT: "EDBUMPALLOC -- copy a NUL-terminated liba"
ED_BUMP_ALLOC
            sta   ED_TMP16
            stz   ED_TMP16+1
            clc
            lda   ED_TEXTPTR
            adc   ED_TMP16
            sta   ED_NEEDEND
            lda   ED_TEXTPTR+1
            adc   ED_TMP16+1
            sta   ED_NEEDEND+1
            inc   ED_NEEDEND
            bne   :chk
            inc   ED_NEEDEND+1
:chk        jsr   ED_ROOM
            bcs   :oom
            lda   ED_TEXTPTR
            sta   PTR0
            lda   ED_TEXTPTR+1
            sta   PTR0+1
            ldy   #0
:cpy        lda   (ED_SRC),y
            sta   (ED_TEXTPTR),y
            beq   :done
            iny
            bra   :cpy
:done       iny
            tya
            clc
            adc   ED_TEXTPTR
            sta   ED_TEXTPTR
            bcc   :nc
            inc   ED_TEXTPTR+1
:nc         clc
            rts
:oom        sec
            rts

*---------------------------------------------------------------
* ED_INSRT_AFTR -- insert one new line right after line
* ED_TMP16 (0 = insert at the very start of the buffer),
* pointing at text PTR0. Shifts every later slot up by one. Sets
* ED_CURLINE to the new line. OUT: carry set = table full
* (MAXLINES reached), nothing inserted.
*---------------------------------------------------------------
ED_INSRT_AFTR
            lda   ED_NLINES
            cmp   #<MAXLINES
            lda   ED_NLINES+1
            sbc   #>MAXLINES
            bcs   :fail
            lda   ED_TMP16
            sta   ED_TMP16B
            lda   ED_TMP16+1
            sta   ED_TMP16B+1        ;ED_TMP16B = afterline
                                     ;(saved)
            lda   PTR0
            pha
            lda   PTR0+1
            pha

            lda   ED_NLINES
            sta   ED_TMP16
            lda   ED_NLINES+1
            sta   ED_TMP16+1        ;i = NLINES

:shiftloop  lda   ED_TMP16
            cmp   ED_TMP16B
            bne   :doshift
            lda   ED_TMP16+1
            cmp   ED_TMP16B+1
            bne   :doshift
            bra   :shiftdone
:doshift    jsr   ED_LTSLOT          ;ED_LTPTR = &slot[i]
            ldy   #0
            lda   (ED_LTPTR),y
            sta   ED_DST
            iny
            lda   (ED_LTPTR),y
            sta   ED_DST+1
            clc
            lda   ED_LTPTR
            adc   #2
            sta   ED_LTPTR
            bcc   :nb5
            inc   ED_LTPTR+1
:nb5        ldy   #0
            lda   ED_DST
            sta   (ED_LTPTR),y
            iny
            lda   ED_DST+1
            sta   (ED_LTPTR),y
            lda   ED_TMP16
            bne   :dn
            dec   ED_TMP16+1
:dn         dec   ED_TMP16
            bra   :shiftloop

:shiftdone  lda   ED_TMP16B
            sta   ED_TMP16
            lda   ED_TMP16B+1
            sta   ED_TMP16+1
            inc   ED_TMP16
            bne   :nb6
            inc   ED_TMP16+1
:nb6        pla
            sta   ED_SRC+1
            pla
            sta   ED_SRC
            jsr   ED_SETSLOT
            inc   ED_NLINES
            bne   :nb7
            inc   ED_NLINES+1
:nb7        lda   ED_TMP16
            sta   ED_CURLINE
            lda   ED_TMP16+1
            sta   ED_CURLINE+1
            jsr   ED_GMARK_INS    ;widened g/v (2026-09-02,
                                  ;edsub2.s): every pending g/v
                                  ;match past the insertion
                                  ;point shifts down one, same
                                  ;posture as excmd.s's own
                                  ;EX_MARK_INS for 'x marks --
                                  ;a no-op (ED_GMCOUNT==0)
                                  ;whenever no g/v is mid-flight
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* ED_DLT_RANGE -- remove lines [ED_ADDR1,ED_ADDR2] inclusive,
* shifting later lines down. Sets ED_NLINES and ED_CURLINE
* (classic rule: dot becomes the line after the deleted range,
* clamped to the new $, or 0 if the buffer is now empty). Does
* NOT reclaim the deleted lines' text bytes (see file header --
* no compaction).
*---------------------------------------------------------------
ED_DLT_RANGE
            lda   ED_ADDR1
            sta   ED_DELDST
            lda   ED_ADDR1+1
            sta   ED_DELDST+1
            lda   ED_ADDR2
            sta   ED_TMP16
            lda   ED_ADDR2+1
            sta   ED_TMP16+1
            inc   ED_TMP16
            bne   :sn
            inc   ED_TMP16+1
:sn         lda   ED_TMP16
            sta   ED_DELSRC
            lda   ED_TMP16+1
            sta   ED_DELSRC+1

:loop       lda   ED_DELSRC+1
            cmp   ED_NLINES+1
            bcc   :cont
            bne   :done
            lda   ED_DELSRC
            cmp   ED_NLINES
            bcc   :cont
            bne   :done
:cont       lda   ED_DELSRC
            sta   ED_TMP16
            lda   ED_DELSRC+1
            sta   ED_TMP16+1
            jsr   ED_GETSLOT
            lda   ED_DELDST
            sta   ED_TMP16
            lda   ED_DELDST+1
            sta   ED_TMP16+1
            jsr   ED_SETSLOT
            inc   ED_DELDST
            bne   :i1
            inc   ED_DELDST+1
:i1         inc   ED_DELSRC
            bne   :loop
            inc   ED_DELSRC+1
            bra   :loop

:done       jsr   ED_GMARK_DEL    ;widened g/v (2026-09-02,
                                  ;edsub2.s): invalidate any
                                  ;pending g/v match inside
                                  ;[ADDR1,ADDR2] (just deleted),
                                  ;shift down any past it -- the
                                  ;same posture as excmd.s's own
                                  ;EX_MARK_DEL for 'x marks, and
                                  ;the SAME still-live ED_ADDR1/
                                  ;ED_ADDR2 precondition
            lda   ED_DELDST
            sec
            sbc   #1
            sta   ED_NLINES
            lda   ED_DELDST+1
            sbc   #0
            sta   ED_NLINES+1
            lda   ED_ADDR1+1
            cmp   ED_NLINES+1
            bcc   :useaddr1
            bne   :usenlines
            lda   ED_ADDR1
            cmp   ED_NLINES
            bcc   :useaddr1
            beq   :useaddr1
:usenlines  lda   ED_NLINES
            sta   ED_CURLINE
            lda   ED_NLINES+1
            sta   ED_CURLINE+1
            rts
:useaddr1   lda   ED_ADDR1
            sta   ED_CURLINE
            lda   ED_ADDR1+1
            sta   ED_CURLINE+1
            rts

*---------------------------------------------------------------
* ED_MDST_CHK -- OUT: carry set = ED_MDEST > ED_NLINES (an out-
* of-range destination for m/t; 0 is always in range, the
* "before line 1" position).
*---------------------------------------------------------------
ED_MDST_CHK lda   ED_MDEST+1
            cmp   ED_NLINES+1
            bcc   :ok
            bne   :bad
            lda   ED_MDEST
            cmp   ED_NLINES
            bcc   :ok
            beq   :ok
:bad        sec
            rts
:ok         clc
            rts

*---------------------------------------------------------------
* ED_DOMOVE (2026-08-19, finding 4) -- relocate the block
* [ED_ADDR1,ED_ADDR2] (contiguous, already range-checked:
* 1<=ADDR1<=ADDR2<=NLINES) to right after ED_MDEST, preserving
* the block's internal order. ED_MDEST must NOT be inside
* [ADDR1,ADDR2] (ED_CMD_M checks this; ED_CMD_T can never
* produce it -- see that routine's own header). Composes
* ED_DLT_RANGE (single-line) + ED_INSRT_AFTR per the audit's own
* framing -- no new line-table primitive.
*
* THE ALGORITHM (both directions reduce to the same shape): pick
* whichever end of the block sits next to the destination as a
* constant "remove position" (ADDR1 if the dest is past the
* block, ADDR2 if before it), collapse ED_ADDR1/ED_ADDR2 to that
* single constant line, and repeatedly delete-then-reinsert-
* after-ED_MIA. Neither ED_DLT_RANGE nor ED_INSRT_AFTR ever
* write ED_ADDR1/ED_ADDR2, so the remove position and ED_MIA
* both stay correct across every iteration without re-deriving
* them -- verified by hand simulation (task notes).
*
* ED_INSRT_AFTR's own MAXLINES check can never fire here: each
* iteration deletes one line before inserting one, so the table
* is never larger than it was on entry.
*
* OUT: ED_CURLINE = the block's LAST line (original relative
* order), at its new position (classic ed's m/t dot rule).
*---------------------------------------------------------------
ED_DOMOVE   lda   ED_ADDR2
            sec
            sbc   ED_ADDR1
            sta   ED_MCOUNT
            lda   ED_ADDR2+1
            sbc   ED_ADDR1+1
            sta   ED_MCOUNT+1
            inc   ED_MCOUNT
            bne   :mc_nc
            inc   ED_MCOUNT+1
:mc_nc      lda   ED_MDEST+1
            cmp   ED_ADDR2+1
            bcc   :md_upcase
            bne   :md_down
            lda   ED_MDEST
            cmp   ED_ADDR2
            bcc   :md_upcase

:md_down    ;dest is after the block -- remove from ADDR1,
            ;insert after dest-1; final dot = dest (ED_MDEST
            ;itself, left untouched)
            lda   ED_ADDR1
            sta   ED_ADDR2
            lda   ED_ADDR1+1
            sta   ED_ADDR2+1
            lda   ED_MDEST
            sta   ED_MIA
            lda   ED_MDEST+1
            sta   ED_MIA+1
            lda   ED_MIA
            bne   :dnb1
            dec   ED_MIA+1
:dnb1       dec   ED_MIA
            bra   :mv_loop

:md_upcase  ;dest is before the block -- remove from ADDR2,
            ;insert after dest; final dot = dest+count (ED_MDEST
            ;is overwritten with that sum up front)
            lda   ED_ADDR2
            sta   ED_ADDR1
            lda   ED_ADDR2+1
            sta   ED_ADDR1+1
            lda   ED_MDEST
            sta   ED_MIA
            lda   ED_MDEST+1
            sta   ED_MIA+1
            clc
            lda   ED_MDEST
            adc   ED_MCOUNT
            sta   ED_MDEST
            lda   ED_MDEST+1
            adc   ED_MCOUNT+1
            sta   ED_MDEST+1

:mv_loop    lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
            jsr   ED_GETSLOT
            lda   ED_SRC
            sta   ED_MPTR
            lda   ED_SRC+1
            sta   ED_MPTR+1
            jsr   ED_DLT_RANGE
            lda   ED_MIA
            sta   ED_TMP16
            lda   ED_MIA+1
            sta   ED_TMP16+1
            lda   ED_MPTR
            sta   PTR0
            lda   ED_MPTR+1
            sta   PTR0+1
            jsr   ED_INSRT_AFTR
            lda   ED_MCOUNT
            bne   :mcdec
            dec   ED_MCOUNT+1
:mcdec      dec   ED_MCOUNT
            lda   ED_MCOUNT
            ora   ED_MCOUNT+1
            bne   :mv_loop
            lda   ED_MDEST
            sta   ED_CURLINE
            lda   ED_MDEST+1
            sta   ED_CURLINE+1
            rts

*---------------------------------------------------------------
* ED_TEXTENTRY -- shared a/i/c text-input mode: read lines from
* fd 0, inserting each after a running cursor (starting at
* ED_TMP16, the caller's "insert after" line), until a line that
* is exactly "." or EOF. Leaves ED_CURLINE at the last inserted
* line (or unchanged if none were).
*---------------------------------------------------------------
ED_TEXTENTRY
            lda   ED_TMP16
            sta   ED_GAFTER
            lda   ED_TMP16+1
            sta   ED_GAFTER+1
:loop       jsr   ED_RDCMDLINE
            sta   ED_TMP16B
            php
            cmp   #1
            bne   :notdot
            lda   CMDBUF
            cmp   #"."
            bne   :notdot
            plp
            rts
:notdot     plp
            bcs   :eofstop
            lda   #<CMDBUF
            sta   ED_SRC
            lda   #>CMDBUF
            sta   ED_SRC+1
            lda   ED_TMP16B
            jsr   ED_BUMP_ALLOC
            bcs   :oom
            lda   ED_GAFTER
            sta   ED_TMP16
            lda   ED_GAFTER+1
            sta   ED_TMP16+1
            jsr   ED_INSRT_AFTR
            bcs   :oom
            lda   ED_CURLINE
            sta   ED_GAFTER
            lda   ED_CURLINE+1
            sta   ED_GAFTER+1
            bra   :loop
:eofstop    lda   ED_TMP16B
            beq   :done2
            lda   #<CMDBUF
            sta   ED_SRC
            lda   #>CMDBUF
            sta   ED_SRC+1
            lda   ED_TMP16B
            jsr   ED_BUMP_ALLOC
            bcs   :oom
            lda   ED_GAFTER
            sta   ED_TMP16
            lda   ED_GAFTER+1
            sta   ED_TMP16+1
            jsr   ED_INSRT_AFTR
            bcs   :oom
            lda   ED_CURLINE
            sta   ED_GAFTER
            lda   ED_CURLINE+1
            sta   ED_GAFTER+1
:done2      rts
:oom        jsr   ED_ERR
            rts

*---------------------------------------------------------------
* Small shared address-range helpers.
*---------------------------------------------------------------
ED_ERR_JMP  jsr   ED_ERR
            jmp   MAINLOOP

*---------------------------------------------------------------
* ED_QCLEANUP -- no-op for `ed`. edfile.s is SHARED source
* (put by both ed.s and ex.s), and its ED_CMD_Q now calls this
* unconditionally as ex's swap-file quit-cleanup hook (docs/
* EX-DESIGN.md sec 5.3) -- `ed` has no swap file to clean up, so
* its own copy of edbuf.s (this file) just carries the matching
* no-op RTS under the same name. exbuf.s's ED_QCLEANUP does the
* real CLOSE+UNLINK.
*---------------------------------------------------------------
ED_QCLEANUP rts

*---------------------------------------------------------------
* M2 hooks -- ed's no-op halves. edparse.s/edfil2.s are SHARED
* source and call these six unconditionally at fixed points
* (MAINLOOP's :addrok/:havecmd, ED_PARSE1ADDR's address-token
* dispatch, ED_DOWRITE's write-succeeded point). `ed` has none
* of ex's M2 command set (q!/wq/x, marks, ?re?, u, e, #/nu) or
* dirty tracking, so every one of these is a pure no-op here --
* SAME shape as ED_QCLEANUP above. excmd.s carries the real ex
* implementations. Each preserves whatever its caller needs
* preserved (A, ED_CMDPTR, carry) simply by touching nothing.
*---------------------------------------------------------------
EX_PREMOVE  rts
EX_MUTCHECK rts
EX_ONWRITE  rts

EX_CMD      clc
            rts

EX_MARKREF  clc
            rts

EX_SEARCHBACK
            clc
            rts
