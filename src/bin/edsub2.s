*---------------------------------------------------------------
* edsub2.s -- ed's g/v command half,
* split from edsubst.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2). One assembly
* stream: ALWAYS put immediately after its predecessor; every
* rule in the original header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* ED_CMD_G / ED_CMD_V -- g/re/cmds and v/re/cmds (global /
* global! -- Ex Reference Manual v1.1,
* learning:01M1FX8HT89CKR9CB8T8VKCW1S: the global command runs
* its command-list on EVERY matching line; "The global command
* itself may not appear in cmds. The undo command is also not
* permitted there"; `v` is literally "a synonym for the global
* command variant 'global!'"). 2026-09-02 widening: cmds may now
* be ANY single addressable command (not just p/d, the old v1
* scope limit that file header used to call deliberate) except
* g/v/u, refused with `?` before any mutation.
*
* TWO PASSES -- the only way a command that itself inserts/
* deletes lines can run against a fixed match set without a live
* index desyncing under its own edits (real ex's own shape, not
* a coincidence):
*
*   PASS 1 (below) walks [ADDR1,ADDR2] (default 1,$, ED_GDFLT_
*   RNG) once, RE_MATCH's each line (sense inverted for v,
*   ED_GNEG), and APPENDS every (non-)matching line's CURRENT
*   number to ED_GMARKS (edbuf.s/exbuf.s's own array, ED_GMCOUNT
*   entries, ED_GMARK_ADD below) -- capped at GMARK_CAP;
*   exceeding it refuses the WHOLE command (pass 1 never mutates
*   the buffer, so aborting mid-scan is safe) -- EXACTLY M2's
*   own 'x-mark shape (EX_MARKS/EX_MARK_INS/EX_MARK_DEL,
*   excmd.s) -- ED_GMARKS is a second, larger instance of the
*   IDENTICAL "store the CURRENT line number, shift-adjust it
*   from the insert/delete primitives" discipline (ED_GMARK_INS/
*   ED_GMARK_DEL below, hooked into ED_INSRT_AFTR/ED_DLT_RANGE
*   in BOTH edbuf.s and exbuf.s at the SAME points EX_MARK_INS/
*   EX_MARK_DEL already are for exbuf.s), generalized to a
*   runtime-sized list instead of 27 fixed named slots. A plain
*   snapshot list that ISN'T shift-adjusted would desync the
*   moment cmds inserts or deletes a line -- that is why marks,
*   not an index array, are the mechanism.
*
*   PASS 2: set ED_GMODE=1, `jmp MAINLOOP`. edparse.s's own
*   MAINLOOP top now repeatedly calls ED_GNEXT_MARK (lowest
*   still-marked line, consumed/cleared), resets ED_CMDPTR to
*   the SAVED command-list text (ED_GCMDPTR) and ED_CURLINE to
*   that line, then falls into the IDENTICAL address-parse-then-
*   dispatch path every top-level command line already uses --
*   fully re-entrant, no stdin read, no duplicated command
*   handler (see edparse.s's own header for the exact re-entry
*   shape and why EX_MUTCHECK's one-snapshot-per-outer-command
*   undo hook is skipped for these inner dispatches -- `u` after
*   a whole g/v undoes the WHOLE g/v, not just its last line).
*   Once ED_GNEXT_MARK finds nothing left, MAINLOOP clears
*   ED_GMODE/ED_GMCOUNT and resumes its normal stdin read -- the
*   `jmp MAINLOOP` below is the ONLY place that starts pass 2.
*
* g's default range is `1,$` (ED_GDFLT_RNG); v's is the same --
* only the RE_MATCH sense differs (ED_GNEG).
*---------------------------------------------------------------
ED_CMD_V    lda   #1
            sta   ED_GNEG
            bra   ED_CMD_G2
ED_CMD_G    stz   ED_GNEG
ED_CMD_G2   ldy   #0
            lda   (ED_CMDPTR),y
            cmp   #"/"
            beq   :toerr19
            jmp   ED_ERR_JMP
:toerr19
            inc   ED_CMDPTR
            bne   :g1
            inc   ED_CMDPTR+1
:g1         lda   #<PATBUF
            sta   ED_DST
            lda   #>PATBUF
            sta   ED_DST+1
            jsr   ED_COPYDELIM
            jsr   ED_LASTRE           ;empty g// -> reuse
                                     ;LASTPAT, or `?` if none
                                     ;(2026-09-02)
            bcs   :toerr19b
            jmp   ED_ERR_JMP
:toerr19b
            ;-- ED_CMDPTR now sits at cmds' own start,
            ;-- unconsumed. Save it -- pass 2 resets ED_CMDPTR
            ;-- here every iteration (edparse.s's own MAINLOOP).
            lda   ED_CMDPTR
            sta   ED_GCMDPTR
            lda   ED_CMDPTR+1
            sta   ED_GCMDPTR+1

            ;-- FF1 (2026-09-06): cmds still lives in CMDBUF,
            ;-- and a text-reading sub-command (ED_RDFILELINE,
            ;-- for r/r!/filter, or text-entry) writes into
            ;-- that same CMDBUF -- the first match's read
            ;-- would clobber the command-list bytes pass 2
            ;-- still needs. Copy cmds (through its NUL) into
            ;-- the dedicated GCMDBUF and point ED_GCMDPTR
            ;-- there instead -- transparent to a g/v whose
            ;-- sub-commands never read text.
            ldy   #0
:gcopy      cpy   #CMDBUF_MAXLEN-1
            bcs   :gcopyterm
            lda   (ED_GCMDPTR),y
            sta   GCMDBUF,y
            beq   :gcopydone
            iny
            bra   :gcopy
:gcopyterm  lda   #0
            sta   GCMDBUF,y
:gcopydone  lda   #<GCMDBUF
            sta   ED_GCMDPTR
            lda   #>GCMDBUF
            sta   ED_GCMDPTR+1

            ;-- Refuse g/v/u in cmds BEFORE any mutation (the
            ;-- primary source's own restriction). A throwaway
            ;-- ED_PARSEADDR skips any address prefix cmds
            ;-- itself carries -- its own ED_ADDR1/2/ED_ADDRCNT
            ;-- don't matter yet, g's OWN range isn't resolved
            ;-- into them until below.
            jsr   ED_PARSEADDR
            bcc   :gv_scanok
            jmp   ED_ERR_JMP
:gv_scanok  ldy   #0
            lda   (ED_CMDPTR),y
            cmp   #"g"
            beq   :gv_refuse
            cmp   #"v"
            beq   :gv_refuse
            cmp   #"u"
            bne   :gv_ok
:gv_refuse  jmp   ED_ERR_JMP
:gv_ok      lda   ED_GCMDPTR
            sta   ED_CMDPTR
            lda   ED_GCMDPTR+1
            sta   ED_CMDPTR+1

            ;-- g/v's OWN address range: default 1,$.
            jsr   ED_GDFLT_RNG
            jsr   ED_CHC_RNG12N
            bcc   :g_rngok
            jmp   ED_ERR_JMP
:g_rngok
            ;-- PASS 1: mark every (non-)matching line in
            ;-- [ADDR1,ADDR2], ascending, CURRENT numbering
            ;-- (pass 1 never mutates the buffer, so "current"
            ;-- == "original" throughout it).
            stz   ED_GMCOUNT
            lda   ED_ADDR1
            sta   ED_GIDX
            lda   ED_ADDR1+1
            sta   ED_GIDX+1
:g_mloop    lda   ED_GIDX
            sta   ED_TMP16
            lda   ED_GIDX+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            lda   #<PATBUF
            sta   PTR1
            lda   #>PATBUF
            sta   PTR1+1
            lda   PTR0
            sta   PTR2
            lda   PTR0+1
            sta   PTR2+1
            jsr   RE_MATCH            ;carry clear = matched
            lda   ED_GNEG
            bne   :g_vsense
            bcs   :g_nohit            ;g: no match -- skip
            bra   :g_hit              ;g: matched -- mark
:g_vsense   bcc   :g_nohit            ;v: matched -- skip
:g_hit      lda   ED_GIDX
            sta   ED_TMP16
            lda   ED_GIDX+1
            sta   ED_TMP16+1
            jsr   ED_GMARK_ADD
            bcc   :g_nohit
            jmp   ED_ERR_JMP         ;GMARK_CAP exceeded --
                                     ;refuse the WHOLE command,
                                     ;nothing mutated yet
:g_nohit    lda   ED_GIDX
            cmp   ED_ADDR2
            bne   :g_mnext
            lda   ED_GIDX+1
            cmp   ED_ADDR2+1
            bne   :g_mnext
            bra   :g_m1done
:g_mnext    inc   ED_GIDX
            bne   :g_mnb
            inc   ED_GIDX+1
:g_mnb      bra   :g_mloop
:g_m1done
            ;-- PASS 2: edparse.s's own MAINLOOP top drives it
            ;-- from here (ED_GNEXT_MARK/ED_GCMDPTR/ED_GMODE) --
            ;-- see that file's header for the re-entry shape.
            lda   #1
            sta   ED_GMODE
            jmp   MAINLOOP

*---------------------------------------------------------------
* ED_GMARK_ADD -- widened g/v's pass 1 append. IN: ED_TMP16 =
* the matching line's CURRENT number. OUT: carry clear =
* appended at ED_GMARKS[ED_GMCOUNT], count bumped; carry set =
* GMARK_CAP already reached (caller refuses the whole g/v).
* CLOBBERS: A, X.
*---------------------------------------------------------------
ED_GMARK_ADD
            lda   ED_GMCOUNT
            cmp   #GMARK_CAP
            bcs   :full
            asl   a
            tax
            lda   ED_TMP16
            sta   ED_GMARKS,x
            lda   ED_TMP16+1
            sta   ED_GMARKS+1,x
            inc   ED_GMCOUNT
            clc
            rts
:full       sec
            rts

*---------------------------------------------------------------
* ED_GMARK_INS -- widened g/v's own mark-shift hook, modeled on
* excmd.s's EX_MARK_INS but scoped to ED_GMARKS/ED_GMCOUNT
* (runtime-sized) instead of EX_MARKS/54 (fixed 27 slots).
* IN: ED_TMP16B = the "afterline" N this insert used
* (ED_INSRT_AFTR's own saved value, still live at its call
* site, SAME convention EX_MARK_INS uses). For each of the
* ED_GMCOUNT entries, if it is > N, bump it by one (an
* unset/0 entry is never > any valid N, so no explicit skip
* is needed -- same as EX_MARK_INS). Called unconditionally
* from BOTH edbuf.s's and exbuf.s's own ED_INSRT_AFTR -- the
* ED_GMCOUNT==0 fast exit makes it free whenever no g/v is
* mid-flight. CLOBBERS: A, X, ED_TMP16 (both dead in
* ED_INSRT_AFTR's own tail by the time this runs).
*---------------------------------------------------------------
ED_GMARK_INS
            lda   ED_GMCOUNT
            beq   :gmi_done
            asl   a
            sta   ED_TMP16
            ldx   #0
:gmi_loop   cpx   ED_TMP16
            beq   :gmi_done
            lda   ED_GMARKS+1,x
            cmp   ED_TMP16B+1
            bcc   :gmi_next
            bne   :gmi_bump
            lda   ED_GMARKS,x
            cmp   ED_TMP16B
            bcc   :gmi_next
            beq   :gmi_next
:gmi_bump   inc   ED_GMARKS,x
            bne   :gmi_next
            inc   ED_GMARKS+1,x
:gmi_next   inx
            inx
            bra   :gmi_loop
:gmi_done   rts

*---------------------------------------------------------------
* ED_GMARK_DEL -- widened g/v's own mark-shift hook, mirrors
* excmd.s's EX_MARK_DEL over ED_GMARKS/ED_GMCOUNT instead of
* EX_MARKS/54. IN: ED_ADDR1/ED_ADDR2 = the just-deleted range
* (ED_DLT_RANGE's own precondition, both still live at its
* :done label). For each of the ED_GMCOUNT entries: inside
* [ADDR1,ADDR2] -> invalidate (0, "already handled"); past
* ADDR2 -> shift down by the range length; before ADDR1, or
* already unset -> unaffected. Called unconditionally from
* BOTH edbuf.s's and exbuf.s's own ED_DLT_RANGE -- free when
* no g/v is mid-flight, same posture as ED_GMARK_INS.
* CLOBBERS: A, X, ED_TMP16/ED_TMP16B (both dead in
* ED_DLT_RANGE's own tail).
*---------------------------------------------------------------
ED_GMARK_DEL
            lda   ED_GMCOUNT
            beq   :gmd_done
            asl   a
            sta   ED_TMP16B           ;byte bound -- the range-
                                      ;length calc below needs
                                      ;ED_TMP16 itself, so the
                                      ;bound borrows ED_TMP16B
            sec
            lda   ED_ADDR2
            sbc   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR2+1
            sbc   ED_ADDR1+1
            sta   ED_TMP16+1
            inc   ED_TMP16
            bne   :gmd_lnnb
            inc   ED_TMP16+1
:gmd_lnnb   ldx   #0
:gmd_loop   cpx   ED_TMP16B
            beq   :gmd_done
            lda   ED_GMARKS,x
            ora   ED_GMARKS+1,x
            beq   :gmd_next
            lda   ED_GMARKS+1,x
            cmp   ED_ADDR1+1
            bcc   :gmd_next
            bne   :gmd_chkhi
            lda   ED_GMARKS,x
            cmp   ED_ADDR1
            bcc   :gmd_next
:gmd_chkhi  lda   ED_GMARKS+1,x
            cmp   ED_ADDR2+1
            bcc   :gmd_inside
            bne   :gmd_above
            lda   ED_GMARKS,x
            cmp   ED_ADDR2
            bcc   :gmd_inside
            beq   :gmd_inside
:gmd_above  sec
            lda   ED_GMARKS,x
            sbc   ED_TMP16
            sta   ED_GMARKS,x
            lda   ED_GMARKS+1,x
            sbc   ED_TMP16+1
            sta   ED_GMARKS+1,x
            bra   :gmd_next
:gmd_inside stz   ED_GMARKS,x
            stz   ED_GMARKS+1,x
:gmd_next   inx
            inx
            bra   :gmd_loop
:gmd_done   rts

*---------------------------------------------------------------
* ED_GNEXT_MARK -- widened g/v's pass 2 driver, called ONLY from
* edparse.s's MAINLOOP top. OUT: carry set + ED_CURLINE = the
* lowest still-marked line (that ED_GMARKS entry cleared/
* consumed); carry clear = none left, AND ED_GMODE/ED_GMCOUNT
* are both reset to 0 here (so ED_GMARK_INS/ED_GMARK_DEL go
* back to their free no-op state until the next g/v).
* CLOBBERS: A, X, ED_TMP16B.
*---------------------------------------------------------------
ED_GNEXT_MARK
            lda   ED_GMCOUNT
            beq   :gnm_none
            asl   a
            sta   ED_TMP16B
            ldx   #0
:gnm_loop   cpx   ED_TMP16B
            bcs   :gnm_none
            lda   ED_GMARKS,x
            ora   ED_GMARKS+1,x
            bne   :gnm_found
            inx
            inx
            bra   :gnm_loop
:gnm_found  lda   ED_GMARKS,x
            sta   ED_CURLINE
            lda   ED_GMARKS+1,x
            sta   ED_CURLINE+1
            stz   ED_GMARKS,x
            stz   ED_GMARKS+1,x
            sec
            rts
:gnm_none   stz   ED_GMODE
            stz   ED_GMCOUNT
            clc
            rts

*---------------------------------------------------------------
* ED_CMD_M -- [addr1,addr2]mADDR3 (2026-08-19, finding 4). Move
* the range to right after ADDR3. Default range .,. ; ADDR3 is
* REQUIRED (no default -- classic ed has none either) and must
* be 0<=ADDR3<=$; ADDR3 inside the source range is `?` (moving a
* block into itself).
*---------------------------------------------------------------
ED_CMD_M    jsr   ED_DFLT_DTDT
            jsr   ED_CHC_RNG12N
            bcc   :m_rngok
            jmp   ED_ERR_JMP
:m_rngok    jsr   ED_PARSE1ADDR
            bcs   :m_haveaddr
            jmp   ED_ERR_JMP
:m_haveaddr lda   ED_TMP16
            sta   ED_MDEST
            lda   ED_TMP16+1
            sta   ED_MDEST+1
            jsr   ED_MDST_CHK
            bcs   :m_bad
            lda   ED_MDEST+1
            cmp   ED_ADDR1+1
            bcc   :m_go
            bne   :m_chkafter
            lda   ED_MDEST
            cmp   ED_ADDR1
            bcc   :m_go
:m_chkafter lda   ED_MDEST+1
            cmp   ED_ADDR2+1
            bcc   :m_bad
            bne   :m_go
            lda   ED_MDEST
            cmp   ED_ADDR2
            bcc   :m_bad
            beq   :m_bad
:m_go       jsr   ED_DOMOVE
            jmp   MAINLOOP
:m_bad      jmp   ED_ERR_JMP

*---------------------------------------------------------------
* ED_CMD_T -- [addr1,addr2]tADDR3 (2026-08-19, finding 4). Copy
* the range to right after ADDR3. Default range .,. ; ADDR3 is
* REQUIRED, 0<=ADDR3<=$ -- UNLIKE m, ADDR3 MAY be inside the
* source range (copying into your own range is classic-legal).
*
* TEXT-ARENA DECISION (documented once, here): the copies SHARE
* text-pointer bytes with the originals -- never re-allocate.
* Safe because ED_TEXTBUF is a monotonic bump allocator with NO
* in-place mutation, ever: a rewritten line (s, r, a, i, c, j)
* always ED_BUMP_ALLOC's a FRESH buffer and repoints only that
* one line-table slot; a slot's bytes, once written, are never
* touched again. Two slots sharing the same bytes can therefore
* never see one edit corrupt the other -- there is nothing to
* corrupt.
*
* IMPLEMENTATION: append count copies (sharing pointers) to the
* tail in source order -- appending strictly after ADDR2 never
* disturbs [ADDR1,ADDR2] itself, so this phase needs no self-
* overlap bookkeeping -- then hand the freshly-appended tail
* block to ED_DOMOVE exactly as `m` would (the tail's own start
* is always > ADDR3, since ADDR3<=the ORIGINAL $, so this is
* always ED_DOMOVE's "upcase" direction). Verified against a
* self-overlapping `1,3t2`-shape case by hand simulation (task
* notes) -- the classic result (copies inserted in order right
* after line 2, originals untouched) falls out correctly.
*---------------------------------------------------------------
ED_CMD_T    jsr   ED_DFLT_DTDT
            jsr   ED_CHC_RNG12N
            bcc   :t_rngok
            jmp   ED_ERR_JMP
:t_rngok    jsr   ED_PARSE1ADDR
            bcs   :t_haveaddr
            jmp   ED_ERR_JMP
:t_haveaddr lda   ED_TMP16
            sta   ED_MDEST
            lda   ED_TMP16+1
            sta   ED_MDEST+1
            jsr   ED_MDST_CHK
            bcc   :t_ok
            jmp   ED_ERR_JMP
:t_ok       lda   ED_NLINES
            sta   ED_TSTART
            lda   ED_NLINES+1
            sta   ED_TSTART+1
            lda   ED_ADDR1
            sta   ED_TCUR
            lda   ED_ADDR1+1
            sta   ED_TCUR+1
:t_apploop  lda   ED_TCUR
            sta   ED_TMP16
            lda   ED_TCUR+1
            sta   ED_TMP16+1
            jsr   ED_GETSLOT
            lda   ED_SRC
            sta   PTR0
            lda   ED_SRC+1
            sta   PTR0+1
            lda   ED_NLINES
            sta   ED_TMP16
            lda   ED_NLINES+1
            sta   ED_TMP16+1
            jsr   ED_INSRT_AFTR
            lda   ED_TCUR
            cmp   ED_ADDR2
            bne   :t_appnext
            lda   ED_TCUR+1
            cmp   ED_ADDR2+1
            bne   :t_appnext
            bra   :t_appdone
:t_appnext  inc   ED_TCUR
            bne   :t_annb
            inc   ED_TCUR+1
:t_annb     bra   :t_apploop
:t_appdone  lda   ED_TSTART
            sta   ED_ADDR1
            lda   ED_TSTART+1
            sta   ED_ADDR1+1
            inc   ED_ADDR1
            bne   :t_a1nb
            inc   ED_ADDR1+1
:t_a1nb     lda   ED_NLINES
            sta   ED_ADDR2
            lda   ED_NLINES+1
            sta   ED_ADDR2+1
            jsr   ED_DOMOVE
            jmp   MAINLOOP

*---------------------------------------------------------------
* ED_JDFLT_RNG -- like ED_DFLT_DTDT but the 0-address default is
* `.,.+1` (j's own classic default), not `.,.`.
*---------------------------------------------------------------
ED_JDFLT_RNG
            lda   ED_ADDRCNT
            bne   :have1j
            lda   ED_CURLINE
            sta   ED_ADDR1
            lda   ED_CURLINE+1
            sta   ED_ADDR1+1
            lda   ED_CURLINE
            sta   ED_ADDR2
            lda   ED_CURLINE+1
            sta   ED_ADDR2+1
            inc   ED_ADDR2
            bne   :jd_nb
            inc   ED_ADDR2+1
:jd_nb      rts
:have1j     cmp   #1
            bne   :have2j
            lda   ED_ADDR1
            sta   ED_ADDR2
            lda   ED_ADDR1+1
            sta   ED_ADDR2+1
:have2j     rts

*---------------------------------------------------------------
* ED_JPUTC -- IN: A = byte. Appends it to SUBSCR at the running
* ED_JOUT cursor (0-254 -- exbuf's own descriptor length cap,
* the SAME ceiling every other stored line already carries via
* CMDBUF_MAXLEN/ED_SUBPUTCHAR -- EX-DESIGN.md sec 2.5's "one
* line-length ceiling system-wide" decision). OUT: carry clear =
* stored, ED_JOUT incremented; carry set = the join would exceed
* 254 bytes -- NOT stored, ED_JOUT unchanged, caller refuses the
* whole join with `?` (unlike ED_SUBPUTCHAR, which silently caps
* -- `j`'s M2 fix needs the signal so nothing partial gets
* SETSLOT'd).
*---------------------------------------------------------------
ED_JPUTC    ldy   ED_JOUT
            cpy   #254
            bcs   :full
            sta   SUBSCR,y
            inc   ED_JOUT
            clc
            rts
:full       sec
            rts

*---------------------------------------------------------------
* ED_CMD_J -- [range]j (2026-08-19; M2 2026-09-02 fix: routed
* through the accessor contract -- see exbuf.s's own header for
* the corruption bug this replaced). See file header for the
* chosen no-op semantics. A genuine join concatenates lines
* [ADDR1,ADDR2]'s bytes (no separator) into SUBSCR (`s`'s own
* scratch, unused while `j` runs -- capped at 254 bytes same as
* every other stored line, see ED_JPUTC above), then hands the
* whole thing to ED_BUMP_ALLOC in ONE call -- exactly the same
* {build in scratch, allocate once, ED_SETSLOT the result} shape
* `s`'s ED_DO_SUBST already uses -- and ED_SETSLOT's own PTR0-
* in/ED_SRC-out 2-byte-pointer handoff (edbuf.s: a real RAM
* pointer; exbuf.s: a pointer to EX_DESCSCR) is honored
* unchanged, same as every other reused call site. Then
* collapses [ADDR1+1,ADDR2] out of the line table via
* ED_DLT_RANGE, exactly as before.
*---------------------------------------------------------------
ED_CMD_J    jsr   ED_JDFLT_RNG
            jsr   ED_CHC_RNG12N
            bcc   :j_rngok
            jmp   ED_ERR_JMP
:j_rngok    lda   ED_ADDR1
            cmp   ED_ADDR2
            bne   :j_multi
            lda   ED_ADDR1+1
            cmp   ED_ADDR2+1
            bne   :j_multi
            jmp   MAINLOOP           ;single-line range -- NO-OP
                                     ;(file header): buffer and
                                     ;. both untouched
:j_multi    lda   ED_ADDR1
            sta   ED_JTARGET
            lda   ED_ADDR1+1
            sta   ED_JTARGET+1
            stz   ED_JOUT
            lda   ED_JTARGET
            sta   ED_JCUR
            lda   ED_JTARGET+1
            sta   ED_JCUR+1
:j_lineloop lda   ED_JCUR
            sta   ED_TMP16
            lda   ED_JCUR+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT        ;PTR0 = that line's text
                                     ;(valid only until the NEXT
                                     ;ED_LINETEXT call -- copied
                                     ;out below before this
                                     ;line's fetch is disturbed)
            lda   PTR0
            sta   ED_JSRC
            lda   PTR0+1
            sta   ED_JSRC+1
* -- ex/vi `j`/`J` join with a SEPARATING SPACE and strip the
* -- appended line's leading blanks (POSIX ex/vi); ed`s `j`
* -- joins with NOTHING (POSIX ed). ED_JOINSEP is a build-time
* -- constant per binary: 0 in ed.s, 1 in ex.s/vi.s -- so the
* -- SAME shared ED_CMD_J does the right thing in each. The
* -- FIRST line (ED_JTARGET) is always copied verbatim.
* -- (2026-09-05, check_posixex found ex `j` needed the space.)
            lda   #ED_JOINSEP
            beq   :j_byteloop
            lda   ED_JCUR
            cmp   ED_JTARGET
            bne   :jvsub
            lda   ED_JCUR+1
            cmp   ED_JTARGET+1
            beq   :j_byteloop           ;first line: verbatim
:jvsub      ldy   #0                     ;strip leading blanks
:jvstrip    lda   (ED_JSRC),y
            cmp   #$A0                   ;space
            beq   :jvadv
            cmp   #$89                   ;tab
            bne   :jvsep
:jvadv      inc   ED_JSRC
            bne   :jvstrip
            inc   ED_JSRC+1
            bra   :jvstrip
:jvsep      lda   ED_JOUT               ;one space, unless the
            beq   :j_byteloop           ;accumulator is empty,
            tay                          ;already ends in a
            dey                          ;or this line starts
            lda   SUBSCR,y
            cmp   #$A0
            beq   :j_byteloop
            ldy   #0
            lda   (ED_JSRC),y
            cmp   #$A9                   ;')'
            beq   :j_byteloop
            lda   #$A0
            jsr   ED_JPUTC
            bcc   :j_byteloop
            jmp   ED_CMD_J_LONG
:j_byteloop ldy   #0
            lda   (ED_JSRC),y
            beq   :j_linedone
            jsr   ED_JPUTC
            bcc   :j_bytenext
            jmp   ED_CMD_J_LONG
:j_bytenext inc   ED_JSRC
            bne   :j_bnb
            inc   ED_JSRC+1
:j_bnb      bra   :j_byteloop
:j_linedone lda   ED_JCUR
            cmp   ED_ADDR2
            bne   :j_linenext
            lda   ED_JCUR+1
            cmp   ED_ADDR2+1
            bne   :j_linenext
            bra   :j_copydone
:j_linenext inc   ED_JCUR
            bne   :j_lnb
            inc   ED_JCUR+1
:j_lnb      jmp   :j_lineloop         ;jmp: the vi-space insert
                                      ;above pushed the loop top
                                      ;out of bra range
:j_copydone ldy   ED_JOUT
            lda   #0
            sta   SUBSCR,y            ;NUL-terminate at the
                                      ;built length -- edbuf's
                                      ;ED_BUMP_ALLOC NUL-scans;
                                      ;exbuf's ignores it and
                                      ;copies exactly A bytes --
                                      ;same idiom `s`'s :hadhit
                                      ;already uses
            lda   #<SUBSCR
            sta   ED_SRC
            lda   #>SUBSCR
            sta   ED_SRC+1
            lda   ED_JOUT
            jsr   ED_BUMP_ALLOC
            bcc   :j_alloc_ok
            jmp   ED_CMD_J_OOM
:j_alloc_ok lda   ED_JTARGET
            sta   ED_TMP16
            lda   ED_JTARGET+1
            sta   ED_TMP16+1
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            jsr   ED_SETSLOT          ;line ADDR1 now points at
                                      ;the fresh combined text
            lda   ED_JTARGET
            sta   ED_ADDR1
            lda   ED_JTARGET+1
            sta   ED_ADDR1+1
            inc   ED_ADDR1            ;[ADDR1+1,ADDR2] is now
            bne   :j_r1nb             ;redundant -- collapse it
            inc   ED_ADDR1+1          ;out of the line table (it
:j_r1nb     jsr   ED_DLT_RANGE        ;never touches slot
                                      ;ADDR1 itself, which sits
                                      ;outside this range)
            lda   ED_JTARGET          ;classic rule: . becomes
            sta   ED_CURLINE          ;the joined line, not
            lda   ED_JTARGET+1        ;ED_DLT_RANGE's own "line
            sta   ED_CURLINE+1        ;after the deleted range"
            jmp   MAINLOOP

ED_CMD_J_OOM
            jsr   ED_ERR
            jmp   MAINLOOP

ED_CMD_J_LONG
            jsr   ED_ERR              ;the joined line would
                                     ;exceed 254 bytes -- refuse
                                     ;whole, nothing SETSLOT'd
                                     ;or DLT_RANGE'd (EX-DESIGN.
                                     ;md sec 2.5)
            jmp   MAINLOOP

*---------------------------------------------------------------
* ED_CMD_EQ -- [addr]= (2026-08-19). See file header. At most
* one address; default $. Never touches the buffer or `.`.
*---------------------------------------------------------------
ED_CMD_EQ   lda   ED_ADDRCNT
            cmp   #2
            bne   :eq_not2
            jmp   ED_ERR_JMP
:eq_not2    lda   ED_ADDRCNT
            bne   :eq_have1
            lda   ED_NLINES
            sta   ED_ADDR1
            lda   ED_NLINES+1
            sta   ED_ADDR1+1
            bra   :eq_print
:eq_have1   lda   ED_ADDR1            ;explicit address -- must
            ora   ED_ADDR1+1          ;be a real line, 1<=addr
            beq   :eq_bad             ;<=$ (0 has no line-
            lda   ED_ADDR1+1          ;number sense for `=`,
            cmp   ED_NLINES+1         ;unlike a/i)
            bcc   :eq_print
            bne   :eq_bad
            lda   ED_ADDR1
            cmp   ED_NLINES
            bcc   :eq_print
            beq   :eq_print
:eq_bad     jmp   ED_ERR_JMP
:eq_print   lda   ED_ADDR1
            sta   U2DEC_VAL
            lda   ED_ADDR1+1
            sta   U2DEC_VAL+1
            lda   #<NUMBUF
            sta   PTR1
            lda   #>NUMBUF
            sta   PTR1+1
            jsr   U2DEC
            lda   #<NUMBUF
            sta   PTR0
            lda   #>NUMBUF
            sta   PTR0+1
            jsr   ED_PUTLINE          ;same bytes out as the
            jmp   MAINLOOP            ;inline PUTS+CR it was,
                                      ;plus the ED_GLASSOUT mark

*---------------------------------------------------------------
* Data. Fixed-size buffers first; ED_LINES (the line-pointer
* table) and ED_TEXTBUF (the bump-allocated text arena) last,
* per cat.s/ls.s precedent (docs/USERLAND.md "Consumer-reality
* findings" -- buffers declared textually AFTER the code so they
* never sit between a branch and its target).
*---------------------------------------------------------------
* -- brk() refused at startup: this binary has grown so close
* -- to $BF00 that there is no heap left below the overlay
* -- page. Louder than ed's usual "?" on purpose -- "?" means
* -- "that command was wrong", and this is not that.
ED_NOHEAPMSG asc  "ed: no heap"
            dfb   $00
