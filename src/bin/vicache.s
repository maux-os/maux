*---------------------------------------------------------------
* vicache.s -- repaint-only line cache for vi (docs/VI-DESIGN.md
* W3). `put` by vi.s ONLY, after viop.s. Drop-in replacement for
* ED_LINETEXT at exactly three call sites (viscreen.s: VI_RPT_LN
* :real, VI_REPAINT :isreal, VI_PLACE_CUR) -- every other
* ED_LINETEXT caller (edit/motion/search/insert paths) keeps
* calling it directly; they need the write-through contract,
* not a cache of what's already on the glass.
*
* KEY = the line's 4-byte swap descriptor {offset:3,len:1},
* fetched via exbuf.s's own ED_GETSLOT. This is valid FOREVER
* without invalidation, because the swap is append-only
* (exbuf.s's file header: ED_SETSLOT only repoints the RAM
* table, ED_BUMP_ALLOC only appends at EXSW_END -- nothing ever
* rewrites swap bytes at an existing offset). A rewritten line
* gets a brand new offset; a line that merely moves (renumbered
* by `o`/`dd`/`u`) keeps its old one. Grepped the whole reused
* chain for a counter-example while designing this (edsubst.s
* ED_DO_SUBST, edsub2.s ED_CMD_J/ED_CMD_T, edfil2.s ED_CMD_R) --
* none of them do anything but the {GETSLOT/BUMP_ALLOC out ->
* SETSLOT in} handoff exbuf.s's header already documents.
*
* The ONE event that could reuse an offset for different bytes
* is a fresh swap file -- and EXSW_OPEN (exbuf.s) is zeroed
* exactly once per process, at vi.s's own entry stub, before
* VI_START. That is the only place this cache needs zeroing
* too (VI_CACHE_ZR, called right next to it) -- `:e` (EX_CEDIT,
* excmd.s) reloads a new file WITHOUT resetting EXSW_END, so it
* keeps appending past the old file's bytes rather than
* reusing them; no separate invalidation for `:e` is needed.
*
* WIDTH: a slot holds 80 chars + NUL (VC_SLOTSZ, vi.s's own
* equates block has the 3040-byte RAM-wall arithmetic). vi
* wraps a long line rather than truncating it on screen
* (VI-DESIGN.md ~179), so a line over 80 chars is marked
* TRUNCATED (flags bit 7) and NEVER served from a slot, on
* either a hit or a miss -- it always falls through to a full
* ED_LINETEXT, byte-identical to today's cost and output for
* that line. Only the flag decides this; VI_PLACE_CUR needs no
* separate cursor-column test; a truncated hit already refetches
* the full text before VI_CALC_COL ever sees it.
*
* DIALECT NOTE (2026-09-05): every :local label here is prefixed
* `vc` on purpose -- merlin32 resolves a cross-zone :local by
* WHOLE-FILE uniqueness, not per-zone like real Merlin (learning
* 01M0VJF2DXZR55HGJ8PTN1MNJE): a first draft using plain names
* like :scan/:hit collided with viinsert.s's own :scan and
* visearch.s's own :hit (both `put` earlier by vi.s), rendered
* `ozunid_NNN` in the -v1 listing, and silently mis-resolved a
* branch into the WRONG file's routine -- a deterministic hang
* on a specific check-play scenario (30+ line buffer, dd, then
* `i`+ESC), found by bisecting against the unmodified base.
*
* Learnings this leaned on: 01M14B7RFG1024FPA330Z9ZNM2 (a
* refill-alias window in a buffer serving records -- avoided
* here because a slot copy always happens right after
* ED_LINETEXT returns, before anything could refill
* EX_LINECACHE again, and a slot is never itself re-served as
* the read source for another copy); 01M14AH7Q9T7AZTT3FR0YWT8V2
* (promoting scratch to long-lived state aliases its other
* writers -- checked: nothing but ED_LINETEXT ever writes
* EX_LINECACHE, so copying OUT of it here aliases no one).
*---------------------------------------------------------------

*---------------------------------------------------------------
* VI_CACHE_ZR -- invalidate every slot (clear VALID, bit 0 of
* the flags byte) and reset the round-robin index. Called once,
* vi.s's process-entry stub, same moment EXSW_OPEN is zeroed.
* CLOBBERS: A, X, Y, VC_SPTR.
*---------------------------------------------------------------
VI_CACHE_ZR
            lda   #<VC_SLOTS
            sta   VC_SPTR
            lda   #>VC_SLOTS
            sta   VC_SPTR+1
            ldx   #VI_NCACHE
:vczloop    ldy   #4
            lda   #0
            sta   (VC_SPTR),y
            clc
            lda   VC_SPTR
            adc   #VC_SLOTSZ
            sta   VC_SPTR
            bcc   :vcznowrp
            inc   VC_SPTR+1
:vcznowrp   dex
            bne   :vczloop
            stz   VC_NEXT
            rts

*---------------------------------------------------------------
* VC_SLOTADR -- IN: A = slot index (0..VI_NCACHE-1). OUT:
* VC_SPTR = VC_SLOTS + A*VC_SLOTSZ (a repeated-add loop, not a
* multiply -- only ever called on a cache MISS, so cheap beats
* clever). CLOBBERS: A, X.
*---------------------------------------------------------------
VC_SLOTADR  tax
            lda   #<VC_SLOTS
            sta   VC_SPTR
            lda   #>VC_SLOTS
            sta   VC_SPTR+1
            cpx   #0
            beq   :vcsadone
:vcsaloop   clc
            lda   VC_SPTR
            adc   #VC_SLOTSZ
            sta   VC_SPTR
            bcc   :vcsanowrp
            inc   VC_SPTR+1
:vcsanowrp  dex
            bne   :vcsaloop
:vcsadone   rts

*---------------------------------------------------------------
* VI_LTEXTC -- drop-in for ED_LINETEXT at vi's three repaint
* call sites. IN: ED_TMP16 = line number n. OUT: PTR0 = pointer
* to that line's NUL-terminated text -- one of the VI_NCACHE
* slots on a short-line hit or fresh miss, or EX_LINECACHE
* (ED_LINETEXT's own buffer, same as every other caller gets)
* whenever the line is over 80 chars, hit or miss alike. NEVER
* hands out a stale EX_LINECACHE pointer: the only one returned
* is fresh from this call's own ED_LINETEXT.
*
* CLOBBERS: A, X, Y, PTR0, PTR1, ED_TMP16, ED_SRC, EX_DESCSCR
* (all already true of ED_GETSLOT/ED_LINETEXT), VC_SPTR.
*---------------------------------------------------------------
VI_LTEXTC   jsr   ED_GETSLOT      ;EX_DESCSCR = this line's key
            lda   #<VC_SLOTS
            sta   VC_SPTR
            lda   #>VC_SLOTS
            sta   VC_SPTR+1
            ldx   #VI_NCACHE
:vcscan     ldy   #4
            lda   (VC_SPTR),y
            and   #1              ;VALID?
            beq   :vcscnext
            ldy   #0
            lda   (VC_SPTR),y
            cmp   EX_DESCSCR
            bne   :vcscnext
            iny
            lda   (VC_SPTR),y
            cmp   EX_DESCSCR+1
            bne   :vcscnext
            iny
            lda   (VC_SPTR),y
            cmp   EX_DESCSCR+2
            bne   :vcscnext
            iny
            lda   (VC_SPTR),y
            cmp   EX_DESCSCR+3
            beq   :vchit
:vcscnext   clc
            lda   VC_SPTR
            adc   #VC_SLOTSZ
            sta   VC_SPTR
            bcc   :vcscnowrp
            inc   VC_SPTR+1
:vcscnowrp  dex
            bne   :vcscan
            bra   :vcmiss

* -- HIT: not-truncated -> PTR0 = this slot's text (offset 5).
* -- truncated -> the slot never held this line's text at all;
* -- fall through to the real thing, same cost as a miss would
* -- have paid.
:vchit      ldy   #4
            lda   (VC_SPTR),y
            bmi   :vchittrn        ;bit7 = TRUNCATED
            clc
            lda   VC_SPTR
            adc   #5
            sta   PTR0
            lda   VC_SPTR+1
            adc   #0
            sta   PTR0+1
            rts
:vchittrn   jmp   ED_LINETEXT

* -- MISS: read the real line once, then decide whether it fits
* -- a slot at all before spending the copy.
:vcmiss     jsr   ED_LINETEXT      ;PTR0=EX_LINECACHE (full
                                   ;text); EX_DESCSCR untouched
                                   ;since ED_GETSLOT -- still
                                   ;this line's own key
            lda   VC_NEXT
            jsr   VC_SLOTADR       ;VC_SPTR = victim slot base
            ldy   #0
:vcmkey     lda   EX_DESCSCR,y
            sta   (VC_SPTR),y
            iny
            cpy   #4
            bne   :vcmkey
            lda   EX_DESCSCR+3     ;raw text length, 0..254
            cmp   #81
            bcc   :vcmshort
            ldx   #80              ;clamp the copy to 80 chars
            lda   #$81             ;VALID(0) + TRUNCATED(7)
            bra   :vcmsetfl
:vcmshort   tax                    ;X = exact length (<81)
            lda   #1               ;VALID only
:vcmsetfl   ldy   #4
            sta   (VC_SPTR),y
            clc
            lda   VC_SPTR          ;PTR1 = this slot's text
            adc   #5               ;field (offset 5)
            sta   PTR1
            lda   VC_SPTR+1
            adc   #0
            sta   PTR1+1
            ldy   #0
:vcmcopy    cpx   #0
            beq   :vcmcpydn
            lda   EX_LINECACHE,y
            sta   (PTR1),y
            iny
            dex
            bra   :vcmcopy
:vcmcpydn   lda   #0
            sta   (PTR1),y         ;NUL after the last char
            inc   VC_NEXT
            lda   VC_NEXT
            cmp   #VI_NCACHE
            bne   :vcmnowrap
            stz   VC_NEXT
:vcmnowrap  ldy   #4
            lda   (VC_SPTR),y
            bmi   :vcmdone         ;truncated -> keep PTR0 as
                                   ;ED_LINETEXT left it (the
                                   ;full line, EX_LINECACHE)
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
:vcmdone    rts
