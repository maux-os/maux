*---------------------------------------------------------------
* excmd.s -- ex's own M2 command set (docs/EX-DESIGN.md sec 5.5,
* 2026-09-02). `put` by ex.s ONLY, LAST in the manifest (after
* edsub2.s) -- everything here is new, ex-only code; `ed` never
* assembles this file. Hooks into the SHARED modules (edparse.s/
* edfil2.s/exbuf.s) via the six no-op-in-ed / real-in-ex symbols
* those files call unconditionally: EX_CMD, EX_PREMOVE,
* EX_MUTCHECK, EX_MARKREF, EX_SEARCHBACK (edparse.s), EX_ONWRITE
* (edfil2.s's ED_DOWRITE), EX_MARK_INS/EX_MARK_DEL (exbuf.s's
* ED_INSRT_AFTR/ED_DLT_RANGE -- ex-only calls, no ed-side stub
* needed since exbuf.s and edbuf.s are independent forks).
*
* Primary source for every command's semantics: the Ex Reference
* Manual v1.1 (William N. Joy, UC Berkeley, Nov 1977),
* learning:01M1FX8HT89CKR9CB8T8VKCW1S. Divergences from it are
* called out at each command below, per HACKING.md's A12
* discipline -- ship the modern-canonical spelling, note the
* older/absent form beside it.
*
* q!/wq/x (M2 item 1, [reported]/A12-modern -- NOT in the 1977
* source, confirmed by full-text read: v1.1's own `x` means
* `xpand` (tab-expand), not exit; `wq`/`xit` are not attested at
* all). Needs a DIRTY flag -- none existed in `ed`/`ex` before
* this (grepped); EX_DIRTY is new, set by exbuf.s's ED_SETSLOT
* (every content/table mutation runs through it -- the only 4
* SETSLOT callers in the tree: ED_DLT_RANGE, ED_INSRT_AFTR, `s`,
* the M2-fixed `j`), cleared by a successful ED_DOWRITE
* (EX_ONWRITE hook).
*
* marks (M2 item 2, [fact] per the primary source's own `mark`/
* `k`/`'x`/`''` account). `mark x`/`ma x` (exname.s rewrites
* them
* to the short form) or `kx` record
* the CURRENT addressed line (default `.`, or the one address
* given -- a range is `?`) under letter x. `'x` resolves it as
* an address; `''` is the previous-context mark, auto-set (by
* EX_PREMOVE) to the OLD `.` right before any command that was
* given an explicit address. Storage: EX_MARKS, 27 slots of 2
* bytes (26 letters + '' as slot 26) -- shift-adjusted by
* EX_MARK_INS/EX_MARK_DEL, hooked into exbuf.s's insert/delete
* primitives so every mutation path (a/i/c/d/s/g/m/t/j/r/e)
* keeps marks correct without each command needing its own
* bookkeeping.
*
* ?re? backward search (M2 item 3, [fact] for the wrap-by-
* default behavior and the `?` spelling). Mirrors ED_SEARCHFWD's
* wrap logic in reverse, reusing RE_MATCH exactly as forward
* search does. `??`-repeats-last-search IS implemented (2026-09-
* 02, "last regular expression" -- learning:
* 01M1FX8HT89CKR9CB8T8VKCW1S: "null-re repeats the last search
* (`//`, `??`)"): edsubst.s's ED_LASTRE is the ONE shared helper
* -- forward `/re/` (ED_SEARCHFWD), backward `?re?` (this
* routine), `s//repl/` and `g//` all call it right after
* copying their own freshly-parsed token into PATBUF, so there
* is exactly ONE last-RE store (LASTPAT) shared by all four --
* a `/fwd/`
* search followed by a bare `??` reuses `fwd` for the backward
* search, and vice versa. An empty pattern with no prior RE is a
* `?`, not a crash and not an empty-matches-everything.
*
* u undo (M2 item 4, [fact]: "Undo is its own inverse", primary
* source). Single-level: EX_SNAPSHOT copies the live line table
* into EX_SHADOW before each mutating command (EX_MUTCHECK's
* hook, keyed on the command LETTER so it fires exactly once per
* command regardless of how many INSRT_AFTR/DLT_RANGE calls that
* command makes internally); `u` SWAPS live<->shadow (via
* EX_BLKSWAP) so a second `u` redoes. Undo covers the line
* table only, not marks (the primary source's own account is
* about buffer content, not `ex`'s auxiliary mark state).
*
* e/e! (M2 item 6, [fact] for the shape: "the commands write and
* edit... cannot be undone" -- e itself CAN, per this
* implementation, via the same EX_SNAPSHOT hook `e` also fires).
* Discards the whole line table and reloads via the shared
* ED_READLOOP (edfil2.s, factored out of ED_CMD_R for this
* reuse -- M2 item 6's own note). e! skips the dirty guard.
*
* #/nu numbered print, and `n` RESERVED (M2 item 5, [fact]: the
* primary source settled that `n` means `next` in real ex, not
* numbered-print, which is `#`/`number`(nu) -- COLLIDING with
* `ed`'s OWN `n` dispatch. `ed`'s `n` stays numbered-print,
* UNCHANGED (edparse.s's shared MAINLOOP dispatch is untouched).
* ex never reaches that `n`: exname.s's table has no row for a
* bare `n` (refused "n: Not an editor command") and rewrites
* `nu`/`num`/`number` to `#`, which EX_CNUMPR tail-calls into
* the shared ED_CMD_N. `next` is out of scope (needs a
* multi-file
* argument list -- deferred, EX-DESIGN.md sec 3.1/3.3).
*
* COMMAND NAMES (docs/EX-BADCMD.md, 2026-10-08): the first thing
* EX_CMD does is `jsr EX_NAME` (exname.s). It resolves the WORD
* -- the run of letters -- against the POSIX name table and
* rewrites it in place to the one-letter spelling every handler
* below and the classic chain were written for, moving ED_CMDPTR
* onto that letter (so the "UNCHANGED" in the contract below
* means: unchanged BY A HANDLER that declines). An unknown word,
* or a verb with an operand it does not take, is refused there
* and never reaches a handler. Before this, `cxyz` ran `c`.
*
* Dispatch contract (EX_CMD and every routine it reaches): IN --
* ED_CMDPTR at the first byte of the command text (after any
* address prefix edparse.s's shared ED_PARSEADDR already parsed
* into ED_ADDR1/2/ED_ADDRCNT), before EX_NAME has moved it.
* OUT -- a command that IS recognized does its own work and ends
* with `jmp MAINLOOP` (NEVER `rts` -- edparse.s's :addrok caller
* does not check carry after `jsr EX_CMD`, it just falls through
* assuming "not handled" and re-fetches the command byte for the
* classic a/i/c/... chain); a command that turns out NOT to
* match falls through to `clc / rts` with ED_CMDPTR UNCHANGED.
*---------------------------------------------------------------

*---------------------------------------------------------------
* EX_ONWRITE -- ED_DOWRITE's (edfil2.s) success hook. "cleared
* by w" (M2 item 1) -- a successful write always means the
* buffer now matches what's on disk.
*---------------------------------------------------------------
EX_ONWRITE  stz   EX_DIRTY
            rts

*---------------------------------------------------------------
* EX_BLKCOPY -- IN: PTR1=src, PTR2=dst, EX_CPLEN=byte count
* (16-bit). One-way copy PTR1->PTR2. CLOBBERS: A, Y, PTR1, PTR2,
* EX_CPLEN (all consumed by the loop).
*---------------------------------------------------------------
EX_BLKCOPY
:cploop     lda   EX_CPLEN
            ora   EX_CPLEN+1
            beq   :cpdone
            ldy   #0
            lda   (PTR1),y
            sta   (PTR2),y
            inc   PTR1
            bne   :cp1nb
            inc   PTR1+1
:cp1nb      inc   PTR2
            bne   :cp2nb
            inc   PTR2+1
:cp2nb      lda   EX_CPLEN
            bne   :cplnb
            dec   EX_CPLEN+1
:cplnb      dec   EX_CPLEN
            bra   :cploop
:cpdone     rts

*---------------------------------------------------------------
* EX_BLKSWAP -- IN: PTR1, PTR2, EX_CPLEN, same shape as
* EX_BLKCOPY. Exchanges the bytes at PTR1 and PTR2 in place (a
* true swap, not a copy -- what makes `u` its own inverse).
* CLOBBERS: same as EX_BLKCOPY.
*---------------------------------------------------------------
EX_BLKSWAP
:swloop     lda   EX_CPLEN
            ora   EX_CPLEN+1
            beq   :swdone
            ldy   #0
            lda   (PTR1),y
            pha
            lda   (PTR2),y
            sta   (PTR1),y
            pla
            sta   (PTR2),y
            inc   PTR1
            bne   :sw1nb
            inc   PTR1+1
:sw1nb      inc   PTR2
            bne   :sw2nb
            inc   PTR2+1
:sw2nb      lda   EX_CPLEN
            bne   :swlnb
            dec   EX_CPLEN+1
:swlnb      dec   EX_CPLEN
            bra   :swloop
:swdone     rts

*---------------------------------------------------------------
* EX_SNAPSHOT -- copy the live line table (ED_LINES[0..NLINES])
* and NLINES/CURLINE into the shadow, OVERWRITING whatever the
* previous shadow held (single-level undo -- only the most
* recent pre-command state matters). Called once per mutating
* command, BEFORE it runs (EX_MUTCHECK's hook, or excmd.s's own
* `e` handler). CLOBBERS: A, X, Y, PTR1, PTR2, EX_CPLEN.
*---------------------------------------------------------------
*---------------------------------------------------------------
* EX_SHADOW lives in the process LANGUAGE CARD ($D000) now, not
* the low window (ex.s/vi.s) -- 8196 bytes reclaimed. It is
* written by EX_SNAPSHOT and read+written by EX_UNDO_CORE; both
* bracket the LC copy with the kernel's own write-enable/protect
* pattern (LCBANK2_RAM 2x-read write-enables, LCBANK2_STORE
* re-protects -- src/kernel/mli.s, procspawn3.s, timer.s).
* ALTZP already maps the process LC
* (learning:01KW1GTYGVYAPQRGS5P7J66RWD) so $FF00 keeps working
* throughout; nothing else in the process touches $D000.
* LCBANK2_RAM ($C08B) / LCBANK2_STORE ($C088) are the canonical
* names from inc/mm.hw.equ, put by ex.s and vi.s (the
* only two units that assemble this file).
*---------------------------------------------------------------

EX_SNAPSHOT
            lda   ED_NLINES
            sta   EX_SHDNLIN
            lda   ED_NLINES+1
            sta   EX_SHDNLIN+1
            lda   ED_CURLINE
            sta   EX_SHDCUR
            lda   ED_CURLINE+1
            sta   EX_SHDCUR+1
            lda   #1
            sta   EX_HASUNDO
            lda   ED_NLINES
            sta   EX_CPLEN
            lda   ED_NLINES+1
            sta   EX_CPLEN+1
            inc   EX_CPLEN
            bne   :ss_nb
            inc   EX_CPLEN+1
:ss_nb      asl   EX_CPLEN
            rol   EX_CPLEN+1
            asl   EX_CPLEN
            rol   EX_CPLEN+1
            lda   #<ED_LINES
            sta   PTR1
            lda   #>ED_LINES
            sta   PTR1+1
            lda   #<EX_SHADOW
            sta   PTR2
            lda   #>EX_SHADOW
            sta   PTR2+1
            lda   LCBANK2_RAM        ;write-enable process LC
            lda   LCBANK2_RAM        ;(EX_SHADOW at $D000)
            jsr   EX_BLKCOPY
*-- no re-protect (docs/LANGUAGE-CARD.md)
            rts

*---------------------------------------------------------------
* EX_MARK_INS -- IN: ED_TMP16B = the "afterline" N this insert
* used (ED_INSRT_AFTR's own saved value, still live at its call
* site). For each of the 27 stored line-refs (EX_MARKS -- 26
* letters + the '' slot), if its line > N, bump it by one: every
* line already past the insertion point shifted up. CLOBBERS: A,
* X, ED_TMP16 (both dead in ED_INSRT_AFTR's own tail by the time
* this is called).
*---------------------------------------------------------------
EX_MARK_INS
            ldx   #0
:mi_loop    lda   EX_MARKS+1,x
            cmp   ED_TMP16B+1
            bcc   :mi_next
            bne   :mi_bump
            lda   EX_MARKS,x
            cmp   ED_TMP16B
            bcc   :mi_next
            beq   :mi_next
:mi_bump    inc   EX_MARKS,x
            bne   :mi_next
            inc   EX_MARKS+1,x
:mi_next    inx
            inx
            cpx   #54
            bne   :mi_loop
            rts

*---------------------------------------------------------------
* EX_MARK_DEL -- IN: ED_ADDR1/ED_ADDR2 = the just-deleted range
* (inclusive, both >=1, ADDR1<=ADDR2 -- ED_DLT_RANGE's own
* precondition, both still live at its :done label). For each of
* the 27 stored line-refs: inside [ADDR1,ADDR2] -> invalidate
* (0); past ADDR2 -> shift down by the range length; before
* ADDR1, or already 0/unset -> unaffected. CLOBBERS: A, X,
* ED_TMP16/ED_TMP16B (both dead in ED_DLT_RANGE's own tail).
*---------------------------------------------------------------
EX_MARK_DEL
            sec
            lda   ED_ADDR2
            sbc   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR2+1
            sbc   ED_ADDR1+1
            sta   ED_TMP16+1
            inc   ED_TMP16
            bne   :md_lnnb
            inc   ED_TMP16+1
:md_lnnb    ldx   #0
:md_loop    lda   EX_MARKS,x
            ora   EX_MARKS+1,x
            beq   :md_next
            lda   EX_MARKS+1,x
            cmp   ED_ADDR1+1
            bcc   :md_next
            bne   :md_chkhi
            lda   EX_MARKS,x
            cmp   ED_ADDR1
            bcc   :md_next
:md_chkhi   lda   EX_MARKS+1,x
            cmp   ED_ADDR2+1
            bcc   :md_inside
            bne   :md_above
            lda   EX_MARKS,x
            cmp   ED_ADDR2
            bcc   :md_inside
            beq   :md_inside
:md_above   sec
            lda   EX_MARKS,x
            sbc   ED_TMP16
            sta   EX_MARKS,x
            lda   EX_MARKS+1,x
            sbc   ED_TMP16+1
            sta   EX_MARKS+1,x
            bra   :md_next
:md_inside  stz   EX_MARKS,x
            stz   EX_MARKS+1,x
:md_next    inx
            inx
            cpx   #54
            bne   :md_loop
            rts

*---------------------------------------------------------------
* EX_PREMOVE -- edparse.s's :addrok calls this on EVERY command
* line (before :bareaddr's own branch), unconditionally. If an
* explicit address was given this line (ED_ADDRCNT != 0),
* snapshot the OLD `.` into EX_PREVMARK (the '' slot, EX_MARKS
* index 26) before whatever command runs moves it. A bare-
* address command (ED_ADDRCNT==0, using the `.` default) is not
* a "motion" -- left alone. CLOBBERS: A (caller preserves it via
* its own pha/pla around this call).
*---------------------------------------------------------------
EX_PREMOVE  lda   ED_ADDRCNT
            beq   :pm_done
            lda   ED_CURLINE
            sta   EX_MARKS+52
            lda   ED_CURLINE+1
            sta   EX_MARKS+53
:pm_done    rts

*---------------------------------------------------------------
* EX_MUTCHECK -- edparse.s's :havecmd calls this with A = the
* resolved single-char command byte, right before the classic
* a/i/c/d/p/n/q/r/w/s/g/m/t/j/= dispatch chain. If A is one of
* the mutating verbs (a i c d s g m t j r), snapshot the line
* table for `u` via EX_SNAPSHOT BEFORE that command runs --
* keyed on the LETTER (not the lower-level INSRT_AFTR/DLT_RANGE
* primitives) so a multi-line `a`/`g...d`/`m`/`t` still gets
* exactly ONE snapshot per user command, not one per internal
* primitive call (which would only capture the state before the
* LAST internal step). Preserves A -- the caller's own dispatch
* chain still needs it afterward.
*---------------------------------------------------------------
EX_MUTCHECK pha
            cmp   #"a"
            beq   :mc_snap
            cmp   #"i"
            beq   :mc_snap
            cmp   #"c"
            beq   :mc_snap
            cmp   #"d"
            beq   :mc_snap
            cmp   #"s"
            beq   :mc_snap
            cmp   #"g"
            beq   :mc_snap
            cmp   #"m"
            beq   :mc_snap
            cmp   #"t"
            beq   :mc_snap
            cmp   #"j"
            beq   :mc_snap
            cmp   #"r"
            beq   :mc_snap
            cmp   #$A6            ;EX6 2026-09-06: '&' (repeat
            beq   :mc_snap        ;the last subst) mutates too
                                  ;-- give it its own undo
                                  ;boundary instead of reusing
                                  ;the prior `s`'s snapshot
            cmp   #"v"            ;XC3 2026-09-06: `v` never
            beq   :mc_snap        ;took its own snapshot; give
                                  ;it the same outer one as `g`
            pla
            rts
:mc_snap    jsr   EX_SNAPSHOT
            pla
            rts

*---------------------------------------------------------------
* EX_MARKREF -- ED_PARSE1ADDR's `'` address-token hook. Entry:
* (ED_CMDPTR),Y with Y=0 is the `'` itself, unconsumed. Handles
* both `'x` (x = a-z, a real mark) and `''` (the previous-
* context slot). OUT: carry set + ED_TMP16 = the resolved line,
* ED_CMDPTR advanced past the 2-byte token (ED_PARSE1ADDR's own
* contract); carry clear = malformed token (bad letter) or an
* unset/out-of-range mark -- ED_CMDPTR restored to the token's
* own start, same "carry clear = unchanged" contract
* ED_SEARCHFWD's own nomatch path already keeps.
*---------------------------------------------------------------
EX_MARKREF  lda   ED_CMDPTR
            sta   ED_ADDRSTRT
            lda   ED_CMDPTR+1
            sta   ED_ADDRSTRT+1
            ldy   #1
            lda   (ED_CMDPTR),y
            cmp   #"'"
            beq   :mr_prev
            cmp   #"a"
            bcc   :mr_bad
            cmp   #"z"+1
            bcs   :mr_bad
            sec
            sbc   #"a"
            asl   a
            tax
            lda   EX_MARKS,x
            sta   ED_TMP16
            lda   EX_MARKS+1,x
            sta   ED_TMP16+1
            bra   :mr_have
:mr_prev    lda   EX_MARKS+52
            sta   ED_TMP16
            lda   EX_MARKS+53
            sta   ED_TMP16+1
:mr_have    lda   ED_TMP16
            ora   ED_TMP16+1
            beq   :mr_bad         ;0 = unset (no line is ever 0)
            lda   ED_TMP16+1
            cmp   ED_NLINES+1
            bcc   :mr_inrng
            bne   :mr_bad
            lda   ED_TMP16
            cmp   ED_NLINES
            bcc   :mr_inrng
            beq   :mr_inrng
            bra   :mr_bad
:mr_inrng   clc
            lda   ED_CMDPTR
            adc   #2
            sta   ED_CMDPTR
            bcc   :mr_nb
            inc   ED_CMDPTR+1
:mr_nb      sec
            rts
:mr_bad     lda   ED_ADDRSTRT
            sta   ED_CMDPTR
            lda   ED_ADDRSTRT+1
            sta   ED_CMDPTR+1
            clc
            rts

*---------------------------------------------------------------
* EX_SEARCHBACK -- ED_PARSE1ADDR's `?` address-token hook.
* Mirrors ED_SEARCHFWD (edparse.s) exactly, but the delimiter is
* `?` and the scan direction is backward (decrement, wrapping
* line 1 -> $) -- `wrap` default ON, per the primary source
* (learning:01M1FX8HT89CKR9CB8T8VKCW1S). `??` DOES repeat the
* last pattern (2026-09-02) via edsubst.s's ED_LASTRE, called
* right after the copy loop below finishes -- see this file's
* own header for the shared-store guarantee (forward and
* backward reuse the SAME LASTPAT). OUT/IN: same contract as
* ED_SEARCHFWD.
*---------------------------------------------------------------
EX_SEARCHBACK
            lda   ED_CMDPTR          ;save the token's OWN start
            sta   ED_ADDRSTRT        ;(the `?` itself) -- ED_
            lda   ED_CMDPTR+1        ;PARSE1ADDR jumps straight
            sta   ED_ADDRSTRT+1      ;here with ED_CMDPTR UNCON-
                                     ;SUMED, unlike ED_SEARCHFWD
                                     ;whose caller (:dosearch)
                                     ;already did this step
            inc   ED_CMDPTR          ;advance past the leading
            bne   :sb_qnb            ;`?` before the copy loop
            inc   ED_CMDPTR+1        ;below starts (else the
:sb_qnb                              ;opening delimiter matches
                                      ;its OWN closing-delimiter
                                      ;check on the very first
                                      ;byte, yielding an empty
                                      ;pattern every time)
            lda   #<PATBUF
            sta   ED_DST
            lda   #>PATBUF
            sta   ED_DST+1
            ldy   #0
:sb_cploop  lda   (ED_CMDPTR),y
            beq   :sb_endpat
            cmp   #"?"
            beq   :sb_endpat
            cmp   #"\"
            bne   :sb_plain
            sta   (ED_DST)
            jsr   ED_BUMPDST
            iny
            lda   (ED_CMDPTR),y
            beq   :sb_stoend
            sta   (ED_DST)
            jsr   ED_BUMPDST
            iny
            bra   :sb_cploop
:sb_stoend  bra   :sb_endpt2
:sb_plain   sta   (ED_DST)
            jsr   ED_BUMPDST
            iny
            bra   :sb_cploop
:sb_endpat  lda   (ED_CMDPTR),y
            bne   :sb_hasdlm
            bra   :sb_endpt2
:sb_hasdlm  iny
:sb_endpt2  lda   #0
            sta   (ED_DST)
            tya
            clc
            adc   ED_CMDPTR
            sta   ED_CMDPTR
            bcc   :sb_nocar
            inc   ED_CMDPTR+1
:sb_nocar
            ; empty pattern -- reuse LASTPAT, or `?` if there is
            ; none (2026-09-02, "last regular expression" --
            ; SHARED with forward `/re/` search, one store)
            jsr   ED_LASTRE
            bcc   :sb_nomatch

            lda   ED_NLINES
            ora   ED_NLINES+1
            bne   :sb_havelin
            bra   :sb_nomatch

:sb_havelin lda   ED_NLINES
            sta   ED_TMP16B
            lda   ED_NLINES+1
            sta   ED_TMP16B+1
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
:sb_tryln   lda   ED_TMP16
            bne   :sb_dec
            dec   ED_TMP16+1
:sb_dec     dec   ED_TMP16
            lda   ED_TMP16
            ora   ED_TMP16+1
            bne   :sb_nowrap
            lda   ED_NLINES
            sta   ED_TMP16
            lda   ED_NLINES+1
            sta   ED_TMP16+1
:sb_nowrap  jsr   ED_LINETEXT
            lda   #<PATBUF
            sta   PTR1
            lda   #>PATBUF
            sta   PTR1+1
            lda   PTR0
            sta   PTR2
            lda   PTR0+1
            sta   PTR2+1
            jsr   RE_MATCH
            bcc   :sb_found
            lda   ED_TMP16B
            bne   :sb_dec1
            dec   ED_TMP16B+1
:sb_dec1    dec   ED_TMP16B
            lda   ED_TMP16B
            ora   ED_TMP16B+1
            bne   :sb_tryln
:sb_nomatch lda   ED_ADDRSTRT
            sta   ED_CMDPTR
            lda   ED_ADDRSTRT+1
            sta   ED_CMDPTR+1
            clc
            rts
:sb_found   sec
            rts

*---------------------------------------------------------------
* EX_SETMARK -- IN: A = mark letter, already validated a-z.
* Records the addressed line (default `.` if ED_ADDRCNT==0,
* ED_ADDR1 if ==1, `?` if ==2 -- a range makes no sense for a
* single-line mark) under EX_MARKS[A-'a']. CLOBBERS: A, X.
*---------------------------------------------------------------
EX_SETMARK  sec
            sbc   #"a"
            asl   a
            tax
            lda   ED_ADDRCNT
            cmp   #2
            bne   :sm_ok
            jsr   ED_ERR
            rts
:sm_ok      lda   ED_ADDRCNT
            bne   :sm_use1
            lda   ED_CURLINE
            sta   EX_MARKS,x
            lda   ED_CURLINE+1
            sta   EX_MARKS+1,x
            rts
:sm_use1    lda   ED_ADDR1
            sta   EX_MARKS,x
            lda   ED_ADDR1+1
            sta   EX_MARKS+1,x
            rts

*---------------------------------------------------------------
* EX_CMD -- the M2 command dispatcher. See file header for the
* IN/OUT contract. EX_NAME (exname.s) goes first: it resolves
* the
* command WORD against the POSIX name table, rewrites it to the
* canonical one-letter spelling (or refuses it and never
* returns), and moves ED_CMDPTR onto that spelling. Then this
* switches on the first byte to a per-letter handler; each
* handler independently confirms the rest of the match.
*---------------------------------------------------------------
EX_CMD      jsr   EX_NAME
            ldy   #0
            lda   (ED_CMDPTR),y
            cmp   #"q"
            bne   :ec_notq
            jmp   EX_CQBANG
:ec_notq    cmp   #"w"
            bne   :ec_notw
            jmp   EX_CWQ
:ec_notw    cmp   #"x"
            bne   :ec_notx
            jmp   EX_CX
:ec_notx    cmp   #"u"
            bne   :ec_notu
            jmp   EX_CUNDO
:ec_notu    cmp   #"#"
            bne   :ec_noth
            jmp   EX_CNUMPR
:ec_noth    cmp   #"e"
            bne   :ec_note
            jmp   EX_CEDIT
:ec_note    cmp   #"k"
            bne   :ec_notk
            jmp   EX_CMARKSHORT
:ec_notk    cmp   #"l"
            bne   :ec_notl
            jmp   EX_CLIST
:ec_notl    cmp   #"z"
            bne   :ec_notz
            jmp   EX_CWIN
:ec_notz    cmp   #"!"
            bne   :ec_notbg
            jmp   EX_CBANG
:ec_notbg   cmp   #"r"
            bne   :ec_notr
            jmp   EX_CRHOOK
:ec_notr    clc
            rts

*---------------------------------------------------------------
* EX_CQBANG -- q! (M2 item 1). Requires ED_ADDRCNT==0 (matching
* `q`'s own scope). Skips the "buffer modified" guard entirely
* (there is none for plain `q` either -- q! is force in the
* sense that a FUTURE `q`-with-a-dirty-buffer guard, if ever
* added, would not apply here; today it just quits).
*---------------------------------------------------------------
EX_CQBANG   ldy   #1
            lda   (ED_CMDPTR),y
            cmp   #"!"
            beq   :qb_go          ;q!
            cmp   #0              ;plain q (NUL-terminated by
            beq   :qb_go          ;VI_COLON / ED_DISPATCH1)
            clc                   ;`q` is a prefix of something
            rts                   ;else -- classic chain
*-- PLAIN `:q` HANDLED HERE, not left to the classic ED_CMD_Q
*-- (edfile.s): that path skips EX_ONQUIT, so vi quit without
*-- restoring the tty or handing back the screen (rmcup) -- the
*-- shell's next prompt jammed onto the `:q` line and the ~
*-- tildes stayed on screen ("terminal stuffed after :q",
*-- operator 2026-09-04). ED_CMD_Q stays as-is for `ed`, which
*-- links no excmd.s and needs no EX_ONQUIT. (No dirty-buffer
*-- guard yet -- plain q still quits a modified buffer, exactly
*-- as before; the "No write since last change" refusal is a
*-- separate follow-up.)
:qb_go      lda   ED_ADDRCNT
            beq   :qb_ok
            jsr   ED_ERR
            jmp   MAINLOOP
:qb_ok      jsr   EX_ONQUIT       ;vi: restore saved tty mode
                                  ;+ leave the alt screen before
                                  ;EXIT (VI-DESIGN sec 5 item
                                  ;3); ex/ed: no-op
            jsr   ED_QCLEANUP
            lda   ED_ERRSTAT      ;EX2 2026-09-06: exit nonzero
            jsr   EXIT            ;if any command this session
                                  ;was refused/failed

*---------------------------------------------------------------
* EX_CWQ -- wq (M2 item 1, [reported]/A12-modern). Bare form
* only -- no filename argument (v1 scope). Requires ED_ADDRCNT==
* 0 (matching `w`'s own "no address prefix" scope).
*---------------------------------------------------------------
EX_CWQ      ldy   #1
            lda   (ED_CMDPTR),y
            cmp   #"q"
            beq   :wq_isq
            jmp   EX_WCHKBG      ;not "wq" -- `w [sp]*!cmd`
                                 ;(filter-write) before falling
                                 ;through to the classic `w`/
                                 ;`w!` chain -- see EX_WCHKBG's
                                 ;own header for the space-vs-
                                 ;bang disambiguation
:wq_isq     ldy   #2
            lda   (ED_CMDPTR),y
            beq   :wq_bare
            cmp   #"!"      ;`wq!` -- EX_NAME ended the line
            beq   :wq_bare        ;right after the bang
            clc
            rts
:wq_bare    lda   ED_ADDRCNT
            beq   :wq_noaddr
            jsr   ED_ERR
            jmp   MAINLOOP
:wq_noaddr  jsr   ED_DOWRITE
            bcc   :wq_wrote
            jmp   ED_ERR_JMP
:wq_wrote   jsr   EX_ONQUIT       ;vi: restore saved tty mode;
                                  ;ex: no-op (ex.s)
            jsr   ED_QCLEANUP
            lda   ED_ERRSTAT      ;EX2 2026-09-06
            jsr   EXIT

*---------------------------------------------------------------
* EX_CX -- x (M2 item 1, [reported]/A12-modern -- v1.1's `x` is
* `xpand`, unimplemented and unrelated; this is the later,
* universal "write if modified, else just quit" meaning). Bare
* form only. Requires ED_ADDRCNT==0. The dirty-check/write/
* cleanup CORE (EX_XCORE, below) needs no ED_CMDPTR at all, so
* it is factored out for vi's `ZZ` (VI-DESIGN sec 5 item 3):
* two keystrokes typed directly in command mode, never through
* `:`, so vi calls EX_XCORE straight from vicmd.s instead of
* synthesizing a fake ":x" command line for ED_DISPATCH1.
*---------------------------------------------------------------
EX_CX       ldy   #1
            lda   (ED_CMDPTR),y
            beq   :x_bare
            cmp   #"!"      ;`x!` -- same as `x` (nothing to
            beq   :x_bare   ;force); EX_NAME ended the line
            clc
            rts
:x_bare     lda   ED_ADDRCNT
            beq   :x_core           ;short branch only -- `jmp
                                    ;EX_XCORE` below stays in
                                    ;range regardless of how far
                                    ;EX_XCORE itself ends up
            jsr   ED_ERR
            jmp   MAINLOOP
:x_core     jmp   EX_XCORE

*---------------------------------------------------------------
* EX_XCORE -- the "write if EX_DIRTY, else just quit" core (`x`/
* `ZZ` semantics), with no ED_CMDPTR dependency -- callable
* directly from vicmd.s's `ZZ` handler as well as from EX_CX
* above. Always terminates the process (jsr EXIT); never
* returns.
*---------------------------------------------------------------
EX_XCORE    lda   EX_DIRTY
            beq   :x_justq
            jsr   ED_DOWRITE
            bcc   :x_wrote
            jmp   ED_ERR_JMP
:x_wrote    jsr   EX_ONQUIT       ;vi: restore saved tty mode;
                                  ;ex: no-op (ex.s)
            jsr   ED_QCLEANUP
            lda   ED_ERRSTAT      ;EX2 2026-09-06
            jsr   EXIT
:x_justq    jsr   EX_ONQUIT
            jsr   ED_QCLEANUP
            lda   ED_ERRSTAT      ;EX2 2026-09-06
            jsr   EXIT

*---------------------------------------------------------------
* EX_CUNDO -- u (M2 item 4). Bare form only. Requires
* ED_ADDRCNT==0. Swaps live<->shadow via EX_BLKSWAP over
* max(live NLINES, shadow NLINES)+1 slots (*4 bytes) so BOTH
* copies end up fully correct -- a second `u` then swaps back
* ("its own inverse", primary source). Sets EX_DIRTY (undo is
* itself a mutation). The swap CORE (EX_UNDO_CORE, docs/VI-
* DESIGN.md sec 5 item 4) needs no ED_CMDPTR -- factored out for
* vi's `u` key, typed directly in command mode with no `:`
* prefix and no address to parse. EX_CUNDO's own EX_HASUNDO
* check above it is UNCHANGED (still `ex`'s own "nothing to
* undo" `?`); vicmd.s's `u` handler makes the identical check
* itself before calling EX_UNDO_CORE (this file's own header for
* the discipline).
*---------------------------------------------------------------
EX_CUNDO    ldy   #1
            lda   (ED_CMDPTR),y
            beq   :u_isu
            clc
            rts
:u_isu      lda   ED_ADDRCNT
            beq   :u_noaddr
            jsr   ED_ERR
            jmp   MAINLOOP
:u_noaddr   lda   EX_HASUNDO
            bne   :u_go
            jsr   ED_ERR
            jmp   MAINLOOP
:u_go       jsr   EX_UNDO_CORE
            jmp   MAINLOOP

*---------------------------------------------------------------
* EX_UNDO_CORE -- the live<->shadow block-swap itself, no
* ED_CMDPTR dependency. Caller (EX_CUNDO above, or vicmd.s's
* `u`) must already know EX_HASUNDO is set. Sets EX_DIRTY.
* Returns (rts) -- unlike EX_XCORE, this never exits the
* process.
*---------------------------------------------------------------
EX_UNDO_CORE
            lda   ED_NLINES+1
            cmp   EX_SHDNLIN+1
            bcc   :u_useshd
            bne   :u_uselive
            lda   ED_NLINES
            cmp   EX_SHDNLIN
            bcc   :u_useshd
:u_uselive  lda   ED_NLINES
            sta   EX_CPLEN
            lda   ED_NLINES+1
            sta   EX_CPLEN+1
            bra   :u_haven
:u_useshd   lda   EX_SHDNLIN
            sta   EX_CPLEN
            lda   EX_SHDNLIN+1
            sta   EX_CPLEN+1
:u_haven    inc   EX_CPLEN
            bne   :u_lnb
            inc   EX_CPLEN+1
:u_lnb      asl   EX_CPLEN
            rol   EX_CPLEN+1
            asl   EX_CPLEN
            rol   EX_CPLEN+1

            lda   #<ED_LINES
            sta   PTR1
            lda   #>ED_LINES
            sta   PTR1+1
            lda   #<EX_SHADOW
            sta   PTR2
            lda   #>EX_SHADOW
            sta   PTR2+1
            lda   LCBANK2_RAM        ;write-enable LC for the
            lda   LCBANK2_RAM        ;swap (EX_SHADOW at $D000)
            jsr   EX_BLKSWAP
*-- no re-protect (docs/LANGUAGE-CARD.md)

            ldx   ED_NLINES
            lda   EX_SHDNLIN
            sta   ED_NLINES
            stx   EX_SHDNLIN
            ldx   ED_NLINES+1
            lda   EX_SHDNLIN+1
            sta   ED_NLINES+1
            stx   EX_SHDNLIN+1
            ldx   ED_CURLINE
            lda   EX_SHDCUR
            sta   ED_CURLINE
            stx   EX_SHDCUR
            ldx   ED_CURLINE+1
            lda   EX_SHDCUR+1
            sta   ED_CURLINE+1
            stx   EX_SHDCUR+1

            lda   #1
            sta   EX_DIRTY
            rts

*---------------------------------------------------------------
* EX_CNUMPR -- # (M2 item 5). Tail-calls the shared ED_CMD_N
* (edfile.s) unchanged -- same handler `ed`'s own `n` uses.
*---------------------------------------------------------------
EX_CNUMPR   jmp   ED_CMD_N

*---------------------------------------------------------------
* EX_CLIST -- `l` (list): print the addressed range like `p`,
* but each line ends with a literal `$` and non-printing bytes
* show in caret notation (^I for a tab, etc.). Default address
* is `.`. Sets dot to the last line listed.
*---------------------------------------------------------------
EX_CLIST    jsr   ED_DFLT_DTDT
            jsr   ED_CHC_RNG12N
            bcc   :cl_ok
            jmp   ED_ERR_JMP
:cl_ok      lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
:cl_loop    jsr   ED_LINETEXT
            jsr   EX_LISTLN
            lda   ED_TMP16
            cmp   ED_ADDR2
            bne   :cl_next
            lda   ED_TMP16+1
            cmp   ED_ADDR2+1
            beq   :cl_setdot
:cl_next    inc   ED_TMP16
            bne   :cl_loop
            inc   ED_TMP16+1
            bra   :cl_loop
:cl_setdot  lda   ED_ADDR2
            sta   ED_CURLINE
            lda   ED_ADDR2+1
            sta   ED_CURLINE+1
            jmp   MAINLOOP

*---------------------------------------------------------------
* EX_LISTLN -- IN: PTR0 = a NUL-terminated line's text. Write it
* to stdout in `l` form: printables verbatim, a control byte
* (masked < $20, or DEL) as `^`+(c+$40), then a trailing `$` and
* CR. Y indexes the text (lines are far under 256 bytes).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
EX_LISTLN   ldy   #0
:ll_loop    lda   (PTR0),y
            beq   :ll_end
            and   #$7F
            cmp   #$20
            bcc   :ll_ctrl
            cmp   #$7F
            beq   :ll_ctrl
            lda   (PTR0),y           ;printable: emit as stored
            ldx   #FD_STDOUT
            phy
            jsr   PUTC
            ply
            bra   :ll_adv
:ll_ctrl    lda   #$DE              ;'^' (high-bit)
            ldx   #FD_STDOUT
            phy
            jsr   PUTC
            ply
            lda   (PTR0),y
            and   #$7F
            clc
            adc   #$40              ;caret letter = c + $40
            ora   #$80              ;console wants the high bit
            ldx   #FD_STDOUT
            phy
            jsr   PUTC
            ply
:ll_adv     iny
            bne   :ll_loop
:ll_end     lda   #$A4              ;'$' (high-bit)
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$8D              ;CR (high-bit)
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* EX_CWIN -- `z` (window): [addr]z[count]. Print `count` lines
* from the addressed line (default `.`); with no count, a
* default window (EX_ZWIN lines). Sets dot to the last line
* shown. POSIX z's type flags (+,-,.,=) are not supported --
* v1 is the plain count form the suite exercises (`1z3`).
*---------------------------------------------------------------
EX_ZWIN     equ   23
EX_CWIN     jsr   ED_DFLT_DTDT
            inc   ED_CMDPTR          ;step past the 'z'
            bne   :zw_nb
            inc   ED_CMDPTR+1
:zw_nb      jsr   ED_PARSENUM        ;ED_TMP16 = trailing count
            lda   ED_TMP16
            ora   ED_TMP16+1
            bne   :zw_cnt
            lda   #EX_ZWIN
            sta   ED_TMP16
            stz   ED_TMP16+1
:zw_cnt     lda   ED_ADDR2           ;start at addressed line
            sta   ED_ADDR1
            lda   ED_ADDR2+1
            sta   ED_ADDR1+1
            jsr   ED_ENDFROMCNT      ;ADDR2 = ADDR1+count-1, <=$
            jsr   ED_CHC_RNG12N
            bcc   :zw_ok
            jmp   ED_ERR_JMP
:zw_ok      lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
:zw_loop    jsr   ED_LINETEXT
            jsr   ED_PUTLINE
            lda   ED_TMP16
            cmp   ED_ADDR2
            bne   :zw_next
            lda   ED_TMP16+1
            cmp   ED_ADDR2+1
            beq   :zw_setdot
:zw_next    inc   ED_TMP16
            bne   :zw_loop
            inc   ED_TMP16+1
            bra   :zw_loop
:zw_setdot  lda   ED_ADDR2
            sta   ED_CURLINE
            lda   ED_ADDR2+1
            sta   ED_CURLINE+1
            jmp   MAINLOOP

*---------------------------------------------------------------
* EX_CEDIT -- e/e! (M2 item 6). No address prefix accepted
* (replaces the WHOLE buffer). e! skips the "buffer modified"
* guard. Opens the new file BEFORE discarding anything -- a bad
* filename leaves the old buffer intact. Snapshots for `u` (an
* `e` IS undoable here, unlike real ex's stated w/e-cannot-be-
* undone -- see file header) and clears EX_DIRTY once the reload
* completes (the buffer now matches what's on disk).
*---------------------------------------------------------------
EX_CEDIT    ldy   #1
            lda   (ED_CMDPTR),y
            cmp   #"!"
            bne   :ce_noforce
            lda   #1
            sta   EX_EFORCE
            ldy   #2
            bra   :ce_parsefn
:ce_noforce stz   EX_EFORCE
            ldy   #1
:ce_parsefn lda   ED_ADDRCNT
            beq   :ce_addrok
            jsr   ED_ERR
            jmp   MAINLOOP
:ce_addrok  lda   EX_EFORCE
            bne   :ce_dirtyok
            lda   EX_DIRTY
            beq   :ce_dirtyok
            jsr   ED_ERR
            jmp   MAINLOOP
:ce_dirtyok
            tya
            clc
            adc   ED_CMDPTR
            sta   ED_TMP16
            lda   ED_CMDPTR+1
            adc   #0
            sta   ED_TMP16+1
            lda   ED_TMP16
            sta   ED_CMDPTR
            lda   ED_TMP16+1
            sta   ED_CMDPTR+1

            jsr   ED_PRS_FNAME
            bcs   :ce_nofname
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            bra   :ce_pathrdy
:ce_nofname jsr   ED_HAS_FNAME
            bcs   :ce_pathrdy
            jsr   ED_ERR
            jmp   MAINLOOP
:ce_pathrdy
            jsr   EX_SNAPSHOT
            stz   ROPARM_IOBUF
            stz   ROPARM_IOBUF+1
            lda   #<ROPARM
            ldx   #>ROPARM
            jsr   SC_OPEN
            bcc   :ce_openok
            jsr   ED_ERR
            jmp   MAINLOOP
:ce_openok  jsr   ED_RMBR_FNAME
            lda   ROPARM_REF
            sta   ED_RFD
            stz   R_RDPOS
            stz   R_RDLEN

            stz   ED_NLINES
            stz   ED_NLINES+1
            stz   ED_CURLINE
            stz   ED_CURLINE+1
            stz   ED_RAFTER
            stz   ED_RAFTER+1
            jsr   ED_READLOOP

            lda   ED_RFD
            sta   RCPARM_REF
            lda   #<RCPARM
            ldx   #>RCPARM
            jsr   SC_CLOSE
            stz   EX_DIRTY
            jmp   MAINLOOP

*---------------------------------------------------------------
* EX_CMARKSHORT -- "kX" (M2 item 2, short form; `mark x` and
* `ma x` reach it too -- EX_NAME rewrites them to `kx`, folding
* the blanks away). Falls through unless the second byte is
* exactly one a-z letter and the THIRD byte is NUL (a bare
* 2-char command -- `k` is otherwise unused by the classic
* chain, so no collision risk, but a stray trailing byte still
* isn't this command).
*---------------------------------------------------------------
EX_CMARKSHORT
            ldy   #1
            lda   (ED_CMDPTR),y
            cmp   #"a"
            bcc   :ks_notmk
            cmp   #"z"+1
            bcs   :ks_notmk
            pha
            ldy   #2
            lda   (ED_CMDPTR),y
            bne   :ks_notmk2
            pla
            jsr   EX_SETMARK
            jmp   MAINLOOP
:ks_notmk2  pla
:ks_notmk   clc
            rts

*---------------------------------------------------------------
* The `!` family -- :!cmd, [a,b]!cmd, :r !cmd, [a,b]w !cmd. All
* four write a one-line script to EX.CMDxx and spawn `sh` with
* the script as its fd 0 (maux's `sh` has no -c; it reads
* commands from fd 0 and does its own `< > |` redirection and
* PATH search -- so the redirection each form needs is TEXT in
* the script, not fdactions). Spawn template: find -exec
* (findact.s ACT_EXEC) -- PATHRSLV then SC_SPAWN/SC_WAIT, single
* child, no pid-match loop. Temp-file convention: exbuf.s's own
* EX.SWPxx (EX_SW_ENSURE) -- xx = 2 hex digits of BANK_ID so
* concurrent instances never collide.
*
* SEQUENCING IS LOAD-BEARING (the open-file pool is 6, kernel-
* wide): EX.IN is written AND CLOSED before spawn (sh opens it
* itself via `<`); EX.OUT is opened for read-back only AFTER
* SC_WAIT returns (sh's own `>` creates/fills it). Peak fd count
* during a filter: ex's swap + the reopened cmd + sh's own IN +
* OUT + the filter binary's own load = 5.
*---------------------------------------------------------------


*---------------------------------------------------------------
* The `!` command family and its EX_BG_* shell-spawn helpers
* CONTINUE in excmd2.s -- split out 2026-09-07 so ex.s/vi.s
* fit real Merlin`s 41,215 B source buffer (excmd.s alone was
* 41,554 B stripped, over by itself; check-dialect). PUT is
* textual, so excmd2.s follows this file in the stream and the
* emitted bytes are unchanged -- check-dual proves it.
*---------------------------------------------------------------
