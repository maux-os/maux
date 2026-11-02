*---------------------------------------------------------------
* exbuf.s -- ex's buffer-management half, FORKED from edbuf.s
* (M1, docs/EX-DESIGN.md sec 5). Same entry points, same ZP/
* register conventions as edbuf.s --
* edparse.s/edfile.s/edfil2.s/
* edsubst.s/edsub2.s `put` by src/bin/ex.s call these UNCHANGED,
* exactly as they call edbuf.s's originals in `ed`. Put
* immediately after edparse.s, same "one assembly stream" rule
* as every other split module in this tree.
*
* WHAT CHANGED: the line-table slot widens from a 2-byte RAM
* pointer to a 4-byte {offset:3, len:1} descriptor -- offset is
* a
* byte position in a per-session SWAP FILE (EX.SWPxx, xx = hex
* BANK_ID), not a process-bank address. Line text is never held
* in RAM except transiently: ED_BUMP_ALLOC WRITEs it to the swap
* file's current end; ED_LINETEXT SET_MARKs+READs it back into a
* single resident cache, EX_LINECACHE (the same "valid only
* until
* the next call" contract edbuf's callers already satisfy -- see
* EX-DESIGN.md sec 5.1).
*
* THE HANDOFF CONVENTION THAT MAKES THIS A DROP-IN FORK: every
* REUSED module that touches "the slot value" does so by copying
* exactly 2 bytes (PTR0/PTR0+1, or ED_SRC/ED_SRC+1) between
* ED_BUMP_ALLOC's OUT and ED_SETSLOT's IN, or between
* ED_GETSLOT's
* OUT and ED_INSRT_AFTR's IN (edsubst.s ED_DO_SUBST, edsub2.s
* ED_CMD_T, edfil2.s ED_CMD_R -- grep-confirmed, none of them do
* a
* 4-byte copy). A literal 4-byte descriptor could not survive
* that unchanged 2-byte copy. So PTR0/ED_SRC here do NOT carry
* the descriptor's 4 bytes directly -- they carry a POINTER to
* EX_DESCSCR, a single shared 4-byte scratch cell that
* ED_GETSLOT/ED_BUMP_ALLOC fill and ED_SETSLOT/ED_INSRT_AFTR
* dereference. A 2-byte pointer copy is exactly what those
* reused call sites already do, so the fork needed ZERO edits to
* them. The one place this shared scratch is NOT enough --
* ED_DOMOVE, which must survive a nested ED_DLT_RANGE call that
* itself re-fills EX_DESCSCR via its own GETSLOT/SETSLOT pair --
* keeps its own independent 4-byte copy in ED_MPTR (widened from
* 2 bytes, moved out of zero page since nothing ever
* dereferences
* it indirectly -- see ED_DOMOVE below).
*
* M2 FIX (2026-09-02): `j` (join, edsub2.s ED_CMD_J) used to
* bypass this handoff entirely -- it poked bytes directly at
* (ED_TEXTPTR) via a since-removed ED_JPUTBYTE, then handed
* ED_SETSLOT a raw 2-byte RAM POINTER (not a pointer to a 4-byte
* descriptor); under exbuf's SETSLOT that pointer got
* dereferenced for 4 bytes, silently reading the joined line's
* own first 4 bytes as a bogus {offset,len} and corrupting the
* line. Fixed by routing `j` through the SAME {build in SUBSCR,
* one ED_BUMP_ALLOC call, ED_SETSLOT the result} shape `s`
* already used -- see edsub2.s's ED_CMD_J for the new
* implementation. That was the last caller of the vestigial RAM
* arena (ED_ROOM/ED_TEXTPTR/ED_JPUTBYTE) this fork used to carry
* just to keep edsub2.s assembling; ED_ROOM's exbuf-side copy is
* removed below as dead code (edbuf.s's own copy, used by every
* `ed` allocation, is untouched). ED_TEXTPTR/ED_TEND/ED_NEEDEND/
* ED_GROW_SZ stay DECLARED (edparse.s's shared START still
* references them at startup, unconditionally) but are otherwise
* unused by ex from here on.
*---------------------------------------------------------------
ED_BUMPDST  inc   ED_DST
            bne   :nb
            inc   ED_DST+1
:nb         rts

* -- more zero page, past the $30-$52 already claimed above --
ED_DELDST   equ   $53        ;2  ED_DLT_RANGE's compaction
                             ;dest cursor (line NUMBERS, not
                             ;bytes -- unaffected by descriptor
                             ;width)
ED_DELSRC   equ   $55        ;2  ED_DLT_RANGE's compaction
                             ;src cursor

*---------------------------------------------------------------
* ED_LTSLOT -- IN: ED_TMP16 = line number n. OUT: ED_LTPTR =
* &ED_LINES[n]. Stride is n*4 now (two asl/rol pairs instead of
* one) -- the descriptor is 4 bytes.
*---------------------------------------------------------------
ED_LTSLOT   lda   ED_TMP16
            sta   ED_LTPTR
            lda   ED_TMP16+1
            sta   ED_LTPTR+1
            asl   ED_LTPTR
            rol   ED_LTPTR+1
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
* ED_GETSLOT -- IN: ED_TMP16=n. OUT: EX_DESCSCR = the 4-byte
* descriptor ED_LINES[n] (copied out), ED_SRC/ED_SRC+1 = pointer
* to EX_DESCSCR. ED_SETSLOT -- IN: ED_TMP16=n, ED_SRC/ED_SRC+1 =
* pointer to a 4-byte descriptor value (EX_DESCSCR via GETSLOT/
* ED_BUMP_ALLOC, or ED_MPTR in ED_DOMOVE's case). Writes those 4
* bytes into ED_LINES[n]. See file header for why this is a
* pointer-to-descriptor, not the descriptor inline.
*---------------------------------------------------------------
ED_GETSLOT  jsr   ED_LTSLOT
            ldy   #0
:rd         lda   (ED_LTPTR),y
            sta   EX_DESCSCR,y
            iny
            cpy   #4
            bne   :rd
            lda   #<EX_DESCSCR
            sta   ED_SRC
            lda   #>EX_DESCSCR
            sta   ED_SRC+1
            rts

ED_SETSLOT  jsr   ED_LTSLOT
            ldy   #0
:wr         lda   (ED_SRC),y
            sta   (ED_LTPTR),y
            iny
            cpy   #4
            bne   :wr
            lda   #1             ;M2 item 1: every repoint is a
            sta   EX_DIRTY        ;real content/table mutation
                                  ;(called by ED_DLT_RANGE's
                                  ;compaction, ED_INSRT_AFTR's
                                  ;shift+insert, `s`'s repoint,
                                  ;and the fixed `j`'s repoint
                                  ;-- the only 4 SETSLOT callers
                                  ;in the whole put-chain)
            rts

*---------------------------------------------------------------
* ED_LINETEXT -- IN: ED_TMP16 = line number n. OUT: PTR0 =
* pointer to that line's NUL-terminated text, valid only until
* the next ED_LINETEXT call (EX-DESIGN.md sec 5.1 -- verified
* safe, every caller reads one line at a time). Reads the 4-byte
* descriptor directly (no need to go through the GETSLOT
* handoff -- nothing outside this routine needs the pointer),
* SET_MARKs the swap fd to its offset, READs len bytes into
* EX_LINECACHE, NUL-terminates.
*---------------------------------------------------------------
ED_LINETEXT jsr   ED_LTSLOT
            ldy   #0
:rd         lda   (ED_LTPTR),y
            sta   EX_DESCSCR,y
            iny
            cpy   #4
            bne   :rd
            lda   EX_DESCSCR
            sta   EX_SEEKBUF
            lda   EX_DESCSCR+1
            sta   EX_SEEKBUF+1
            lda   EX_DESCSCR+2
            sta   EX_SEEKBUF+2
            lda   #<EX_SEEKBUF
            sta   PTR0
            lda   #>EX_SEEKBUF
            sta   PTR0+1
            lda   EXSW_FD
            ldy   #SEEK_SET
            jsr   LSEEK           ;a seek failure here means the
                                   ;swap fd itself is broken --
                                   ;M1 has no recovery path for
                                   ;that (see EX-DESIGN.md sec
                                   ;2.7, deferred); proceed and
                                   ;let the READ below fail
                                   ;visibly instead of hanging
            lda   EX_DESCSCR+3
            sta   EXRDP_REQ
            stz   EXRDP_REQ+1
            lda   #<EX_LINECACHE
            sta   EXRDP_BUF
            lda   #>EX_LINECACHE
            sta   EXRDP_BUF+1
            lda   EXSW_FD
            sta   EXRDP_REF
            lda   #<EXRDP
            ldx   #>EXRDP
            jsr   SC_READ
            ldy   EX_DESCSCR+3
            lda   #0
            sta   EX_LINECACHE,y
            lda   #<EX_LINECACHE
            sta   PTR0
            lda   #>EX_LINECACHE
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* ED_BUMP_ALLOC -- IN: A = length (0-254) of the text at
* (ED_SRC); every caller in this tree (ED_TEXTENTRY below,
* edfil2.s ED_CMD_R, edsubst.s ED_DO_SUBST) passes the EXACT
* byte
* count, never a NUL-scan estimate -- verified against all three
* call sites, so this never scans for a terminator, unlike
* edbuf's RAM-copy version. OUT: PTR0 = pointer to EX_DESCSCR
* holding the new {offset,len} descriptor, for the caller to
* hand
* to ED_SETSLOT/ED_INSRT_AFTR exactly as edbuf's callers already
* do (see file header). Lazily opens the swap file on the first
* call. Carry set = swap I/O failed.
*
* Writes the text bytes, THEN one CR ($8D) -- byte-identical to
* what `w` already writes (EX-DESIGN.md sec 2.2), so a crash-
* abandoned swap file is still a legal text file. The stored
* `len` excludes the CR.
*---------------------------------------------------------------
ED_BUMP_ALLOC
            cmp   #255
            bcc   :lenok
            lda   #254
:lenok      sta   EX_WLEN
            lda   ED_SRC
            sta   EX_WSRC
            lda   ED_SRC+1
            sta   EX_WSRC+1
            jsr   EX_SW_ENSURE
            bcc   :ens_ok
            jmp   :fail
:ens_ok
            lda   EXSW_END
            sta   EX_SEEKBUF
            lda   EXSW_END+1
            sta   EX_SEEKBUF+1
            lda   EXSW_END+2
            sta   EX_SEEKBUF+2
            lda   #<EX_SEEKBUF
            sta   PTR0
            lda   #>EX_SEEKBUF
            sta   PTR0+1
            lda   EXSW_FD
            ldy   #SEEK_SET
            jsr   LSEEK
            bcc   :sk_ok
            jmp   :fail
:sk_ok
            lda   EX_WSRC
            sta   EXWRP_BUF
            lda   EX_WSRC+1
            sta   EXWRP_BUF+1
            lda   EX_WLEN
            sta   EXWRP_REQ
            stz   EXWRP_REQ+1
            lda   EXSW_FD
            sta   EXWRP_REF
            lda   #<EXWRP
            ldx   #>EXWRP
            jsr   SC_WRITE
            bcc   :w1_ok
            jmp   :fail
:w1_ok
            lda   EXSW_FD
            sta   EXCRP_REF
            lda   #<EXCRP
            ldx   #>EXCRP
            jsr   SC_WRITE
            bcc   :w2_ok
            jmp   :fail
:w2_ok
            lda   EXSW_END
            sta   EX_DESCSCR
            lda   EXSW_END+1
            sta   EX_DESCSCR+1
            lda   EXSW_END+2
            sta   EX_DESCSCR+2
            lda   EX_WLEN
            sta   EX_DESCSCR+3

            clc
            lda   EXSW_END
            adc   EX_WLEN
            sta   EXSW_END
            lda   EXSW_END+1
            adc   #0
            sta   EXSW_END+1
            lda   EXSW_END+2
            adc   #0
            sta   EXSW_END+2
            inc   EXSW_END           ;+1 more, for the CR
            bne   :noc2
            inc   EXSW_END+1
            bne   :noc2
            inc   EXSW_END+2
:noc2       lda   #<EX_DESCSCR
            sta   PTR0
            lda   #>EX_DESCSCR
            sta   PTR0+1
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* EX_SW_ENSURE -- lazily CREATE (best-effort, ignore "exists" --
* same posture as `w`'s CREATE, edfil2.s) + OPEN the swap file
* on
* the first call, name EX.SWPxx (xx = 2 hex digits of BANK_ID,
* $FF2E -- sh.s's own `$$` reads the same cell). The filename is
* a plain relative liba string; MKPATH's existing "no leading
* dot -> just re-encode 7-bit, let ProDOS resolve it against the
* process's own current prefix" path (src/liba/mli.s) already
* puts it in the cwd -- no separate SC_GETPFX/concat needed (a
* simplification from EX-DESIGN.md sec 5.3's literal wording,
* but
* the same outcome `r`/`w`'s bare filenames already get).
* OUT: carry clear = fd ready in EXSW_FD (already true if this
* was called before); carry set never returned -- a real open
* failure is loud-message-and-exit, matching `ed`'s "no heap"
* posture (EX-DESIGN.md sec 2.2/2.7), not a recoverable error.
*---------------------------------------------------------------
EX_SW_ENSURE
            lda   EXSW_OPEN
            bne   :already

            ldy   #0
:cplit      lda   EXSWLIT,y
            sta   EXSW_NAME,y
            iny
            cpy   #6
            bne   :cplit
            lda   BANK_ID
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            jsr   EX_HEXCH
            sta   EXSW_NAME+6
            lda   BANK_ID
            and   #$0F
            jsr   EX_HEXCH
            sta   EXSW_NAME+7
            stz   EXSW_NAME+8

            lda   #<EXSW_NAME
            sta   PTR0
            lda   #>EXSW_NAME
            sta   PTR0+1
            lda   #<EXSW_PATH
            sta   PTR1
            lda   #>EXSW_PATH
            sta   PTR1+1
            jsr   MKPATH

            lda   #<EXCRE
            ldx   #>EXCRE
            jsr   SC_CREAT        ;best-effort, ignore result --
                                   ;ed's own `w` precedent
            stz   EXOPP_IOB
            stz   EXOPP_IOB+1
            lda   #<EXOPP
            ldx   #>EXOPP
            jsr   SC_OPEN
            bcc   :opened

            lda   #<EXNOSWPMSG
            sta   PTR0
            lda   #>EXNOSWPMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

:opened     lda   EXOPP_REF
            sta   EXSW_FD
            stz   EXSW_END
            stz   EXSW_END+1
            stz   EXSW_END+2
            lda   #1
            sta   EXSW_OPEN
:already    clc
            rts

*---------------------------------------------------------------
* EX_HEXCH -- IN: A (low nibble). OUT: A = that nibble as a
* high-bit-ASCII hex digit, uppercase (PRHEX8's own :nib logic,
* src/liba/hex.s, reused as a pure function since PRHEX8 itself
* only knows how to PRINT).
*---------------------------------------------------------------
EX_HEXCH    and   #$0F
            cmp   #10
            bcc   :dig
            sec
            sbc   #10
            clc
            adc   #$C1
            rts
:dig        ora   #$B0
            rts

*---------------------------------------------------------------
* ED_QCLEANUP -- the real (ex) half of the quit-path cleanup
* hook
* edfile.s's ED_CMD_Q now calls unconditionally (edbuf.s carries
* a no-op RTS under the same name for `ed`, since edfile.s is
* shared source -- see that file's own comment). CLOSE + UNLINK
* the swap file, only if one was ever opened.
*---------------------------------------------------------------
ED_QCLEANUP lda   EXSW_OPEN
            beq   :done
            lda   EXSW_FD
            sta   EXQCL_REF
            lda   #<EXQCL
            ldx   #>EXQCL
            jsr   SC_CLOSE
            lda   #<EXUNL
            ldx   #>EXUNL
            jsr   SC_UNLINK
:done       rts

*---------------------------------------------------------------
* ED_INSRT_AFTR -- insert one new line right after line ED_TMP16
* (0 = insert at the very start), the descriptor at *PTR0
* (pointer to a 4-byte value -- EX_DESCSCR via ED_BUMP_ALLOC/
* ED_GETSLOT, or ED_MPTR via ED_DOMOVE). Shifts every later slot
* up by one, 4 bytes at a stride instead of 2 (mechanical
* translation of edbuf's inline shift, via the ED_SHIFT4 scratch
* -- not through GETSLOT/SETSLOT, same as edbuf's original
* shape).
* Sets ED_CURLINE to the new line. OUT: carry set = table full
* (MAXLINES reached), nothing inserted.
*---------------------------------------------------------------
ED_INSRT_AFTR
            ;2026-09-06 EX1 defense-in-depth: refuse an insert
            ;point past NLINES here too, not just at EX_RBANG's
            ;own ED_CHECK0N gate -- one missed caller must not
            ;be able to underflow the descending shift below.
            lda   ED_TMP16+1
            cmp   ED_NLINES+1
            bcc   :ia_ptok
            bne   :ia_ptbad
            lda   ED_TMP16
            cmp   ED_NLINES
            bcc   :ia_ptok
            beq   :ia_ptok
:ia_ptbad   jmp   :fail
:ia_ptok    lda   ED_NLINES
            cmp   #<MAXLINES
            lda   ED_NLINES+1
            sbc   #>MAXLINES
            bcc   :ia_room            ;2026-09-02: `jmp`, not
            jmp   :fail               ;`bcs` -- the widened g/v
                                     ;ED_GMARK_INS call below
                                     ;pushed :fail out of
                                     ;`bcs`'s +/-127-byte range
:ia_room    lda   ED_TMP16
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
:sh_rd      lda   (ED_LTPTR),y
            sta   ED_SHIFT4,y
            iny
            cpy   #4
            bne   :sh_rd
            clc
            lda   ED_LTPTR
            adc   #4
            sta   ED_LTPTR
            bcc   :nb5
            inc   ED_LTPTR+1
:nb5        ldy   #0
:sh_wr      lda   ED_SHIFT4,y
            sta   (ED_LTPTR),y
            iny
            cpy   #4
            bne   :sh_wr
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
            jsr   EX_MARK_INS    ;M2 item 2: every mark past the
                                 ;insertion point (still in
                                 ;ED_TMP16B) shifts down one --
                                 ;it lives in excmd.s, put
                                 ;further down this same stream
            jsr   ED_GMARK_INS    ;widened g/v (2026-09-02,
                                  ;edsub2.s): the SAME shift for
                                  ;pending g/v matches -- a
                                  ;separate array from EX_MARKS,
                                  ;same discipline, a no-op when
                                  ;no g/v is mid-flight
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* ED_DLT_RANGE -- UNCHANGED from edbuf.s. Only moves LINE
* NUMBERS through its own loop; the actual 4-byte descriptor
* move is delegated to ED_GETSLOT/ED_SETSLOT (above), which
* already handle the width -- so this routine needed no edits at
* all beyond the ones already in its callees.
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

:done       jsr   EX_MARK_DEL   ;M2 item 2: invalidate any mark
                                ;inside [ADDR1,ADDR2] (just
                                ;deleted), shift down any mark
                                ;past it -- reads ED_ADDR1/
                                ;ED_ADDR2 only, both still the
                                ;deleted range here
            jsr   ED_GMARK_DEL  ;widened g/v (2026-09-02,
                                ;edsub2.s): the SAME invalidate/
                                ;shift for pending g/v matches
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
* ED_MDST_CHK -- UNCHANGED from edbuf.s (pure line-number
* comparison).
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
* ED_DOMOVE -- same algorithm as edbuf.s's original (see that
* file's header comment for the full derivation; unchanged
* here).
* The one real edit: the line's descriptor must survive the
* nested ED_DLT_RANGE call (which itself repoints EX_DESCSCR via
* its own GETSLOT/SETSLOT pair), so it is copied out to ED_MPTR
* -- now 4 bytes, and moved out of zero page (nothing ever
* dereferences ED_MPTR itself; only its ADDRESS is taken, via
* PTR0, so it does not need to live on the direct page -- see
* the data section below).
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

:md_down    lda   ED_ADDR1
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

:md_upcase  lda   ED_ADDR2
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
            ldy   #0
:mp_rd      lda   (ED_SRC),y
            sta   ED_MPTR,y
            iny
            cpy   #4
            bne   :mp_rd
            jsr   ED_DLT_RANGE
            lda   ED_MIA
            sta   ED_TMP16
            lda   ED_MIA+1
            sta   ED_TMP16+1
            lda   #<ED_MPTR
            sta   PTR0
            lda   #>ED_MPTR
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
* ED_TEXTENTRY -- UNCHANGED from edbuf.s. Reads lines from fd 0,
* handing each to ED_BUMP_ALLOC (now swap-backed) then
* ED_INSRT_AFTR, exactly as before -- the PTR0 handoff between
* them (see file header) is what makes this need no edits.
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
* Data -- code-adjacent MLI parmlists and the read-only filename
* stem, same "emitted, best-effort-writable" shape edfil2.s's
* ROPARM/WOPARM/WWPARM/WCRPARM already use (established pattern
* in this tree; not a new writable-text exception). Buffers that
* are pure scratch
* (EX_DESCSCR/EX_SEEKBUF/EX_LINECACHE/ED_SHIFT4/
* ED_MPTR/EXSW_NAME/EXSW_PATH and the session-state cells) live
* in the `dum` arena in ex.s's own tail per docs/STICKY.md sec
* 21
* -- see ex.s for that block; MOST of them need no zero-init at
* all (write-before-read: EX_SW_ENSURE always fills EXSW_NAME
* fresh, ED_LINETEXT/ED_BUMP_ALLOC always fill EX_DESCSCR/
* EX_SEEKBUF fresh before any read). EXSW_OPEN is the one
* exception -- see ex.s's own header for why it is zeroed by a
* tiny stub ex.s runs BEFORE falling into edparse.s's START,
* rather than by relying on any implicit BSS clearing.
*---------------------------------------------------------------
EXSWLIT     asc   "EX.SWP"

EXNOSWPMSG  asc   "ex: no swap"
            dfb   $00

EXCRE          dfb   PCOUNT_CREATE
EXCRE_PATH     da    EXSW_PATH
EXCRE_ACC      dfb   ACCESS_UNLKD
EXCRE_FTY      dfb   FTYPE_TXT
EXCRE_AUX      da    0
EXCRE_STY      dfb   STYP_SEEDLING
EXCRE_CDT      da    0
EXCRE_CTM      da    0

EXOPP          dfb   PCOUNT_OPEN
EXOPP_PATH     da    EXSW_PATH
EXOPP_IOB      da    0
EXOPP_REF      dfb   0

EXQCL          dfb   PCOUNT_CLOSE
EXQCL_REF      dfb   0

EXUNL          dfb   PCNT_DESTROY
EXUNL_PATH     da    EXSW_PATH

EXWRP          dfb   PCOUNT_WRITE
EXWRP_REF      dfb   0
EXWRP_BUF      da    0
EXWRP_REQ      da    0
EXWRP_TRN      da    0

EXCRBYTE       dfb   $8D
EXCRP          dfb   PCOUNT_WRITE
EXCRP_REF      dfb   0
EXCRP_BUF      da    EXCRBYTE
EXCRP_REQ      da    1
EXCRP_TRN      da    0

EXRDP          dfb   PCOUNT_READ
EXRDP_REF      dfb   0
EXRDP_BUF      da    0
EXRDP_REQ      da    0
EXRDP_TRN      da    0
