*---------------------------------------------------------------
* viop.s -- vi's operators (docs/VI-DESIGN.md sec 4.1/4.3/4.4).
* `put` by vi.s ONLY, after visearch.s. Consumes vimotion.s's
* VI_DOMOTION span contract: d/c/y + a motion key run VI_
* DOMOTION for that key, normalize the [cursor,target) span
* (VI_SPAN_NORM), then either call ED_DLT_RANGE/ED_INSRT_AFTR
* (linewise, VI_MO_TYPE==2) or splice a scratch buffer + one
* ED_BUMP_ALLOC/ED_SETSLOT (charwise, VI_MO_TYPE 0/1) -- exactly
* the two shapes docs/VI-DESIGN.md sec 4.3 names, the charwise
* one a sibling of edsubst.s's ED_DO_SUBST.
*
* Adds: d c y (operator+motion, doubled dd/cc/yy), x X D C Y s S
* (char-span shortcuts -- X deletes before the cursor, S = cc;
* both 2026-09-05), p P (put from VI_REG, the one unnamed
* register), J (direct ED_CMD_J reuse via the SAME ED_D1FLAG/
* ED_D1RET redirect VI_COLON/VI_ZZ already use for a classic
* `jmp MAINLOOP`-tailed handler), r (replace one char), ~
* (toggle case). EX_SNAPSHOT is called directly, once per user-
* visible mutating command, before the first mutation -- vi's
* own loop is not edparse.s's dispatch chain, so EX_MUTCHECK's
* letter-keyed hook never fires for these keys (same posture
* viinsert.s already established for i/a/A/I/o/O).
*
* Named registers `"a`-`"z` are virg.s's (a `"` key reaches it
* through VI_OPKEY); the yank/delete cores here end in its
* VI_RG_STORE and p/P begin with its VI_RG_LOAD. A charwise span
* that crosses lines (a search motion, w/b/e at a line end) is
* captured whole, one arena string per line, VI_REGTY 2 (VI_
* OP_CWY :multi); virg.s's VI_OP_PML puts it back. Not
* implemented: `"A`-`"Z` append and numbered registers `"1`-`"9`
* (both are errors, virg.s header).
*
* Depends on: ED_LINETEXT/ED_BUMP_ALLOC/ED_SETSLOT/ED_DLT_RANGE/
* ED_INSRT_AFTR/EX_SNAPSHOT (exbuf.s/excmd.s, unchanged), ED_
* CMD_J (edsub2.s, unchanged -- reached via the MAINLOOP
* redirect, never `jsr`'d directly since it never `rts`s), VI_
* DOMOTION (vimotion.s), VI_CNTNORM/VI_CLAMP_COL (vimotion.s),
* VI_INS_SHOWN (viinsert.s -- `c`/`s` end by falling into it,
* snapshot already taken by this file), VI_REPAINT/VI_RPT_LN
* (viscreen.s), VI_RAWKEY/VI_READCMD (vicmd.s/vimotion.s).
*---------------------------------------------------------------

VI_REGMAXL  equ   250     ;most lines a multi-line yank may hold
                            ;(VI_REGLCNT is a byte); the arena
                            ;(VI_RGCAP) usually binds first.
                            ;Over either: BEL, register EMPTY

*---------------------------------------------------------------
* VI_OPKEY -- command-mode entry point for every key this file
* owns (vicmd.s's VI_LOOP calls this the same way it already
* calls VI_MOTKEY). IN: A = the raw key VI_READCMD returned.
* OUT: carry clear = handled; carry set = not one of these keys,
* VI_LOOP's own chain keeps trying. CLOBBERS: same as whichever
* handler ran, when handled; none otherwise.
*---------------------------------------------------------------
VI_OPKEY    cmp   #"d"
            beq   :dgo
            cmp   #"c"
            beq   :cgo
            cmp   #"y"
            beq   :ygo
            cmp   #"x"
            beq   :xgo
            cmp   #"X"
            beq   :cxgo
            cmp   #"S"
            beq   :csgo
            cmp   #"D"
            beq   :cdgo
            cmp   #"C"
            beq   :ccgo
            cmp   #"Y"
            beq   :cygo
            cmp   #"s"
            beq   :sgo
            cmp   #"p"
            beq   :pgo
            cmp   #"P"
            beq   :Pgo
            cmp   #"J"
            beq   :Jgo
            cmp   #"r"
            beq   :rgo
            cmp   #"~"
            beq   :tgo
            cmp   #VI_KQUOTE  ;'"': a register prefix (virg.s)
            beq   :rggo
            sec
            rts
:dgo        jsr   VI_OP_D
            clc
            rts
:cgo        jsr   VI_OP_C
            clc
            rts
:ygo        jsr   VI_OP_Y
            clc
            rts
:xgo        jsr   VI_OP_X
            clc
            rts
:cxgo       jsr   VI_OP_CAPX
            clc
            rts
:csgo       jsr   VI_OP_CAPS
            clc
            rts
:cdgo       jsr   VI_OP_CAPD
            clc
            rts
:ccgo       jsr   VI_OP_CAPC
            clc
            rts
:cygo       jsr   VI_OP_CAPY
            clc
            rts
:sgo        jsr   VI_OP_S
            clc
            rts
:pgo        jsr   VI_OP_PA
            clc
            rts
:Pgo        jsr   VI_OP_PB
            clc
            rts
:Jgo        jsr   VI_OP_J
            clc
            rts
:rgo        jsr   VI_OP_R
            clc
            rts
:tgo        jsr   VI_OP_TILDE
            clc
            rts
:rggo       jsr   VI_OP_RGPFX
            clc
            rts

*---------------------------------------------------------------
* VI_MUL16 -- IN: ED_TMP16B, VI_COUNT (16-bit each). OUT: VI_
* COUNT = ED_TMP16B * VI_COUNT, truncated to 16 bits (line
* counts stay well under MAXLINES=2048, so truncation is never
* actually reached by a real count). Textbook shift-add 16x16.
* CLOBBERS: A, X, VI_TMP, ED_TMP16B, VI_COUNT.
*---------------------------------------------------------------
VI_MUL16    stz   VI_TMP
            stz   VI_TMP+1
            ldx   #16
:loop       lsr   VI_COUNT+1
            ror   VI_COUNT
            bcc   :noadd
            clc
            lda   VI_TMP
            adc   ED_TMP16B
            sta   VI_TMP
            lda   VI_TMP+1
            adc   ED_TMP16B+1
            sta   VI_TMP+1
:noadd      asl   ED_TMP16B
            rol   ED_TMP16B+1
            dex
            bne   :loop
            lda   VI_TMP
            sta   VI_COUNT
            lda   VI_TMP+1
            sta   VI_COUNT+1
            rts

*---------------------------------------------------------------
* VI_OP_COMBINE -- combine an operator's own leading count
* (ED_TMP16B, saved by the caller BEFORE its nested VI_READCMD)
* with the count typed after the operator (VI_COUNT, that nested
* read's own result): 0/0 -> 0 (motion picks its own default);
* one zero -> the other count wins; both nonzero -> multiplied
* (standard vi repeat-count composition -- "3dw"/"d3w"/"3d2w").
* OUT: VI_COUNT = the combined count. CLOBBERS: A, + VI_MUL16's
* own when both counts were given.
*---------------------------------------------------------------
VI_OP_COMBINE
            lda   ED_TMP16B
            ora   ED_TMP16B+1
            beq   :done          ;opcnt==0 -- VI_COUNT (motcnt,
                                 ;maybe also 0) is already right
            lda   VI_COUNT
            ora   VI_COUNT+1
            bne   :both
            lda   ED_TMP16B
            sta   VI_COUNT
            lda   ED_TMP16B+1
            sta   VI_COUNT+1
:done       rts
:both       jmp   VI_MUL16

*---------------------------------------------------------------
* VI_SPAN_NORM -- normalize the span between the cursor (ED_
* CURLINE/VI_CURCOL) and the motion target (VI_MO_L1/VI_MO_C1,
* VI_DOMOTION's own OUT) into ED_ADDR1/VI_SPSC (the SMALLER
* position) and ED_ADDR2/VI_SPEC (the LARGER position's line,
* plus its column as an EXCLUSIVE end -- +1 past it when VI_MO_
* TYPE is inclusive). Works for either direction (b/0/F/T moving
* backward, w/e/G moving forward) and for linewise motions too
* (columns are set but ignored by linewise callers). CLOBBERS:
* A, ED_ADDR1, ED_ADDR2, VI_SPSC, VI_SPEC.
*---------------------------------------------------------------
VI_SPAN_NORM
            lda   ED_CURLINE+1
            cmp   VI_MO_L1+1
            bcc   :curmin
            bne   :targmin
            lda   ED_CURLINE
            cmp   VI_MO_L1
            bcc   :curmin
            bne   :targmin
            lda   VI_CURCOL
            cmp   VI_MO_C1
            bcc   :curmin
            bne   :targmin
:curmin     lda   ED_CURLINE
            sta   ED_ADDR1
            lda   ED_CURLINE+1
            sta   ED_ADDR1+1
            lda   VI_CURCOL
            sta   VI_SPSC
            lda   VI_MO_L1
            sta   ED_ADDR2
            lda   VI_MO_L1+1
            sta   ED_ADDR2+1
            lda   VI_MO_C1
            bra   :endcalc
:targmin    lda   VI_MO_L1
            sta   ED_ADDR1
            lda   VI_MO_L1+1
            sta   ED_ADDR1+1
            lda   VI_MO_C1
            sta   VI_SPSC
            lda   ED_CURLINE
            sta   ED_ADDR2
            lda   ED_CURLINE+1
            sta   ED_ADDR2+1
            lda   VI_CURCOL
:endcalc    sta   VI_SPEC
            lda   VI_MO_TYPE
            cmp   #1
            bne   :done
            inc   VI_SPEC
:done       rts

*---------------------------------------------------------------
* VI_OP_DDSPAN -- IN: VI_COUNT = normalized (>=1) line count.
* OUT: ED_ADDR1 = ED_CURLINE, ED_ADDR2 = ED_CURLINE+VI_COUNT-1,
* clamped to ED_NLINES -- the `dd`/`cc`/`yy`/`Y` doubled-form
* span (count = TOTAL lines involved, not a repeat count).
* CLOBBERS: A, ED_ADDR1, ED_ADDR2.
*---------------------------------------------------------------
VI_OP_DDSPAN
            lda   ED_CURLINE
            sta   ED_ADDR1
            lda   ED_CURLINE+1
            sta   ED_ADDR1+1
            clc
            lda   ED_CURLINE
            adc   VI_COUNT
            sta   ED_ADDR2
            lda   ED_CURLINE+1
            adc   VI_COUNT+1
            sta   ED_ADDR2+1
            lda   ED_ADDR2
            bne   :nb
            dec   ED_ADDR2+1
:nb         dec   ED_ADDR2
            lda   ED_ADDR2+1
            cmp   ED_NLINES+1
            bcc   :ok
            bne   :clamp
            lda   ED_ADDR2
            cmp   ED_NLINES
            bcc   :ok
            beq   :ok
:clamp      lda   ED_NLINES
            sta   ED_ADDR2
            lda   ED_NLINES+1
            sta   ED_ADDR2+1
:ok         rts

*---------------------------------------------------------------
* VI_OP_LWY -- linewise yank core. IN: ED_ADDR1/ED_ADDR2 = the
* line range (inclusive) to remember. Packs each line's text
* into arena entry 26 (virg.s; over VI_REGMAXL lines or the
* arena: BEL, entry left empty), sets VI_REGTY=1 and VI_REGLCNT.
* Used by y/yy/Y directly, and by d/dd/c/cc
* BEFORE they delete (delete also fills the unnamed register,
* real vi's own rule). Keeps its own line-slot counter in VI_
* TMP2, NOT X -- ED_LINETEXT clobbers X internally (its own
* SC_READ dispatch), so an X-held loop counter would silently
* lose its place after the FIRST line (found live, 2026-09-03:
* `yy`+`p` pasted an EMPTY line -- the old slot lookup's
* X-indexed
* stride landed on slot 0 only by accident of X's post-syscall
* garbage value, never the real per-line index). CLOBBERS: A, X,
* Y, PTR0-2, ED_TMP16, VI_TMP2, VI_REGTY, VI_REGLCNT, VI_RG*.
*---------------------------------------------------------------
VI_OP_LWY   lda   #1
            sta   VI_REGTY
            lda   #VI_RGU
            jsr   VI_RG_BEG       ;arena entry 26 (virg.s)
            stz   VI_TMP2
            lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
:loop       lda   VI_TMP2
            cmp   #VI_REGMAXL
            bcs   :over
            jsr   ED_LINETEXT     ;clobbers X -- VI_TMP2 (not X)
                                  ;is this loop's own counter
            jsr   VI_RG_PUT       ;PTR0 = the line's text
            inc   VI_TMP2
            lda   ED_TMP16
            cmp   ED_ADDR2
            bne   :next
            lda   ED_TMP16+1
            cmp   ED_ADDR2+1
            bne   :next
            bra   :done          ;just did the last line
:next       inc   ED_TMP16
            bne   :loop
            inc   ED_TMP16+1
            bra   :loop
:over       lda   #1              ;too many lines: an error, the
            sta   VI_RGBAD        ;register is left empty
            jsr   VI_BELL
:done       lda   VI_TMP2
            sta   VI_REGLCNT
            jsr   VI_RG_FIN
            jmp   VI_RG_STORE     ;a pending "x prefix saves it

*---------------------------------------------------------------
* VI_OP_LWCT -- linewise CHANGE's own tail: after the caller has
* already yanked-into-register and ED_DLT_RANGE'd the span (ED_
* CURLINE now the line after it, or 0 if the buffer is now
* empty), open ONE new empty line right there and fall into
* insert -- the SAME ED_BUMP_ALLOC(0)+ED_INSRT_AFTR idiom
* viinsert.s's VI_INS_OBLW/OABV already use. Never returns here
* (VI_INS_SHOWN's own tail eventually `rts`s through whatever
* called the routine that jumped in). CLOBBERS: A, X, Y, PTR0,
* ED_SRC, ED_TMP16 (+ VI_INS_SHOWN's own).
*---------------------------------------------------------------
* -- Open the fresh empty line at the DELETION START (ED_ADDR1),
* -- not ED_CURLINE. ED_DLT_RANGE leaves dot at ED_ADDR1 when
* -- lines remain below the deleted range, but moves it UP when
* -- the range reached the last line -- so ED_CURLINE reopened
* -- the line in the wrong place for `cc`/`S`/`cG` on the last
* -- line (it prepended to the top). ED_ADDR1 (the first deleted
* -- line) is the correct spot in every case, and it survives
* -- ED_DLT_RANGE untouched. (2026-09-05, check_posixvi.)
VI_OP_LWCT  lda   ED_ADDR1
            ora   ED_ADDR1+1
            beq   :atzero
            lda   ED_ADDR1
            sec
            sbc   #1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sbc   #0
            sta   ED_TMP16+1
            bra   :ins
:atzero     stz   ED_TMP16
            stz   ED_TMP16+1
:ins        lda   #<VI_LBUF
            sta   ED_SRC
            lda   #>VI_LBUF
            sta   ED_SRC+1
            lda   #0
            jsr   ED_BUMP_ALLOC
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            jsr   ED_INSRT_AFTR
            stz   VI_CURCOL
            jmp   VI_OP_CWCHG           ;ADDR1 = the emptied
                                        ;line, ADDR1+1..ADDR2
                                        ;gone: VI_RP_CWD's shape

*---------------------------------------------------------------
* VI_OP_CWY -- charwise yank core. IN: ED_ADDR1/VI_SPSC = span
* start, ED_ADDR2/VI_SPEC = span end (exclusive), from VI_SPAN_
* NORM. Copies into VI_REG (254-byte flat, NUL-terminated), sets
* VI_REGTY=0. A span crossing lines (ED_ADDR1<>ED_ADDR2) packs
* one string per line into arena entry 26 and sets VI_REGTY=2
* (see :multi; it stages each piece in SUBSCR). Ends in
* VI_RG_STORE, so a pending "x prefix saves the result.
* CLOBBERS: A, X, Y, PTR0-2, ED_TMP16, VI_REG, VI_REGTY,
* VI_REGLCNT, SUBSCR, VI_TMP, VI_TMP2, VI_RG*.
*---------------------------------------------------------------
VI_OP_CWY   lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
            lda   ED_ADDR1
            cmp   ED_ADDR2
            bne   :multi
            lda   ED_ADDR1+1
            cmp   ED_ADDR2+1
            bne   :multi
            jsr   ED_LINETEXT
            jsr   STRLEN
            sta   VI_TMP
            lda   VI_SPEC
            cmp   VI_TMP
            bcc   :usespec
            lda   VI_TMP
            bra   :haveend
:usespec    lda   VI_SPEC
:haveend    sta   VI_TMP2
            ldy   VI_SPSC
            ldx   #0
:loop       cpy   VI_TMP2
            bcs   :done
            cpx   #254
            bcs   :done
            lda   (PTR0),y
            sta   VI_REG,x
            iny
            inx
            bra   :loop
:done       stz   VI_REG,x
            stz   VI_REGTY
            jmp   VI_RG_STORE     ;a pending "x prefix saves it
* -- A span crossing lines: REGTY 2, one slot per line (virg.s
* -- has the model). Slot 0 = ADDR1's tail from VI_SPSC, middle
* -- lines whole, the last slot = ADDR2's head [0,VI_SPEC). The
* -- slot index lives in VI_TMP2, not X: ED_LINETEXT clobbers X.
:multi      lda   #2
            sta   VI_REGTY
            lda   #VI_RGU
            jsr   VI_RG_BEG
            stz   VI_TMP2
:mloop      jsr   ED_LINETEXT
            jsr   STRLEN
            sta   VI_TMP          ;line length
            sta   VI_TMP+1        ;end column: the whole line..
            lda   ED_TMP16
            cmp   ED_ADDR2
            bne   :notlast
            lda   ED_TMP16+1
            cmp   ED_ADDR2+1
            bne   :notlast
            lda   VI_SPEC         ;..but the LAST line stops at
            cmp   VI_TMP          ;the span end
            bcs   :notlast
            sta   VI_TMP+1
:notlast    ldy   #0
            lda   VI_TMP2
            bne   :mcp0
            ldy   VI_SPSC     ;string 0 starts at the span start
:mcp0       ldx   #0
:mcp        cpy   VI_TMP+1
            bcs   :mcpd
            lda   (PTR0),y
            sta   SUBSCR,x        ;stage the piece (NUL-ended)
            iny
            inx
            bra   :mcp
:mcpd       lda   #0
            sta   SUBSCR,x
            lda   #<SUBSCR
            sta   PTR0
            lda   #>SUBSCR
            sta   PTR0+1
            jsr   VI_RG_PUT
            inc   VI_TMP2
            lda   ED_TMP16
            cmp   ED_ADDR2
            bne   :mnext
            lda   ED_TMP16+1
            cmp   ED_ADDR2+1
            beq   :mdone          ;just did the last line
:mnext      lda   VI_TMP2
            cmp   #VI_REGMAXL
            bcs   :mcap
            inc   ED_TMP16
            bne   :mloop
            inc   ED_TMP16+1
            bra   :mloop
:mcap       lda   #1              ;too many lines: an error, the
            sta   VI_RGBAD        ;register is left empty
            jsr   VI_BELL
:mdone      lda   VI_TMP2
            sta   VI_REGLCNT
            jsr   VI_RG_FIN
            jmp   VI_RG_STORE     ;a pending "x prefix saves it

*---------------------------------------------------------------
* VI_OP_CWD -- charwise delete core. IN: same span args as VI_
* OP_CWY (which this calls FIRST, so d always fills the register
* too). Same-line: splice prefix+suffix into SUBSCR, one BUMP_
* ALLOC+SETSLOT. Cross-line: merge ED_ADDR1's prefix with ED_
* ADDR2's suffix into SUBSCR, repoint ED_ADDR1 to it, then
* ED_DLT_RANGE away [ED_ADDR1+1,ED_ADDR2] (now redundant). OUT:
* ED_CURLINE/VI_CURCOL = the span's start (correct for BOTH
* directions, since VI_SPAN_NORM already put the smaller
* position at ED_ADDR1/VI_SPSC). CLOBBERS: A, X, Y, PTR0,
* ED_TMP16, ED_SRC, SUBSCR, VI_TMP, VI_TMP2 (+ VI_OP_CWY's own).
*---------------------------------------------------------------
VI_OP_CWD   jsr   VI_OP_CWY
            lda   ED_ADDR1
            cmp   ED_ADDR2
            bne   :multi
            lda   ED_ADDR1+1
            cmp   ED_ADDR2+1
            bne   :multi
            lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN
            sta   VI_TMP
            lda   VI_SPEC
            cmp   VI_TMP
            bcc   :endok
            lda   VI_TMP
:endok      sta   VI_TMP2
            ldy   #0
            ldx   #0
:pfx        cpy   VI_SPSC
            beq   :pfxdone
            lda   (PTR0),y
            sta   SUBSCR,x
            iny
            inx
            bra   :pfx
:pfxdone    ldy   VI_TMP2
:sfx        cpy   VI_TMP
            bcs   :sfxdone
            lda   (PTR0),y
            sta   SUBSCR,x
            iny
            inx
            bra   :sfx
:sfxdone    stz   SUBSCR,x
            lda   #<SUBSCR
            sta   ED_SRC
            lda   #>SUBSCR
            sta   ED_SRC+1
            txa
            jsr   ED_BUMP_ALLOC
            lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            jsr   ED_SETSLOT
            jmp   :setcur
:multi      lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            ldy   #0
            ldx   #0
:mpfx       cpy   VI_SPSC
            beq   :mpfxdone
            lda   (PTR0),y
            sta   SUBSCR,x
            iny
            inx
            bra   :mpfx
:mpfxdone   phx                   ;X = prefix length in SUBSCR;
                                  ;ED_LINETEXT and STRLEN both
                                  ;clobber X, and the suffix
                                  ;copy below continues at
                                  ;SUBSCR,x -- unsaved, X came
                                  ;back 0 and the suffix over-
                                  ;wrote the prefix: every
                                  ;cross-line charwise delete
                                  ;lost line 1's kept head
                                  ;(`2dw` "aa bb"/"cc dd" gave
                                  ;"dd" not "aa dd", 2026-09-05)
            lda   ED_ADDR2
            sta   ED_TMP16
            lda   ED_ADDR2+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN
            sta   VI_TMP
            lda   VI_SPEC
            cmp   VI_TMP
            bcc   :mendok
            lda   VI_TMP
:mendok     sta   VI_TMP2
            plx
            ldy   VI_TMP2
:msfx       cpy   VI_TMP
            bcs   :msfxdone
            cpx   #254
            bcs   :msfxdone
            lda   (PTR0),y
            sta   SUBSCR,x
            iny
            inx
            bra   :msfx
:msfxdone   stz   SUBSCR,x
            lda   #<SUBSCR
            sta   ED_SRC
            lda   #>SUBSCR
            sta   ED_SRC+1
            txa
            jsr   ED_BUMP_ALLOC
            lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            jsr   ED_SETSLOT
            lda   ED_ADDR1
            pha
            lda   ED_ADDR1+1
            pha
            clc
            lda   ED_ADDR1
            adc   #1
            sta   ED_ADDR1
            lda   ED_ADDR1+1
            adc   #0
            sta   ED_ADDR1+1
            jsr   ED_DLT_RANGE
            pla
            sta   ED_ADDR1+1
            pla
            sta   ED_ADDR1
:setcur     lda   ED_ADDR1
            sta   ED_CURLINE
            lda   ED_ADDR1+1
            sta   ED_CURLINE+1
            lda   VI_SPSC
            sta   VI_CURCOL
            rts

*---------------------------------------------------------------
* VI_OP_DC_BODY -- shared `d`/`c` body. IN: VI_OPCHAR = the
* doubled-form key to match ("d" or "c"), VI_OPISCH = 0 (plain
* delete) or 1 (change -- fall into insert after deleting), VI_
* COUNT = the leading count already read by VI_LOOP's own
* VI_READCMD (0 = none). Reads the following key itself (a
* second, optional count, then the motion key or a doubled
* operator letter) via VI_READCMD, same nested-read idiom VI_ZZ/
* VI_DOFIND already use for THEIR own second key. CLOBBERS:
* everything VI_DOMOTION/VI_SPAN_NORM/VI_OP_CWD/VI_OP_LWY/
* EX_SNAPSHOT/VI_INS_SHOWN each clobber.
*---------------------------------------------------------------
VI_OP_DC_BODY
            lda   VI_COUNT
            pha
            lda   VI_COUNT+1
            pha
            jsr   VI_READCMD
            bcc   :dcgotk
            jmp   :abort           ;bcs out of range
                                   ;after the cw=ce insert
:dcgotk
            sta   VI_TMP
            pla
            sta   ED_TMP16B+1
            pla
            sta   ED_TMP16B
            lda   VI_TMP
            cmp   VI_OPCHAR
            beq   :doubled
            jsr   VI_OP_COMBINE
* -- `cw`/`cW` special case (POSIX vi): on a NON-blank, behave
* -- as `ce`/`cE` -- change to the word END, NOT through the
* -- trailing whitespace a plain `w` would swallow. On a blank,
* -- `cw` stays `w`. w->e / W->E is -$12 for both. (2026-09-05,
* -- found via `.`-repeat's cw case.)
            lda   VI_OPCHAR
            cmp   #"c"
            bne   :nocwce
            lda   VI_TMP
            cmp   #"w"
            beq   :cwce
            cmp   #"W"
            bne   :nocwce
:cwce       lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            ldy   VI_CURCOL
            lda   (PTR0),y
            beq   :nocwce               ;past EOL -- leave as w
            cmp   #$A0                  ;space
            beq   :nocwce
            cmp   #$89                  ;tab
            beq   :nocwce
            lda   VI_TMP                 ;non-blank -> ce/cE
            sec
            sbc   #$12                   ;w->e, W->E
            sta   VI_TMP
:nocwce     lda   VI_TMP
            jsr   VI_DOMOTION
            bcs   :bell
            jsr   EX_SNAPSHOT
            jsr   VI_SPAN_NORM
            jsr   VI_SAVESPAN           ;pre-delete capture
            lda   VI_MO_TYPE
            cmp   #2
            beq   :lw
            jsr   VI_OP_CWD
            lda   VI_OPISCH
            beq   :done
            jmp   VI_OP_CWCHG
:lw         jsr   VI_OP_LWY
            jsr   ED_DLT_RANGE
            lda   VI_OPISCH
            beq   :donelw
            jmp   VI_OP_LWCT
:doubled    jsr   VI_OP_COMBINE
            jsr   VI_CNTNORM
            jsr   VI_OP_DDSPAN
            jsr   VI_SAVESPAN
            jsr   EX_SNAPSHOT
            jsr   VI_OP_LWY
            jsr   ED_DLT_RANGE
            lda   VI_OPISCH
            beq   :donelw
            jmp   VI_OP_LWCT
*-- Redisplay (2026-09-11, the IL/DL increment): a charwise
*-- delete changed the cursor line and folded ADDR1+1..ADDR2
*-- away; a linewise one removed ADDR1..ADDR2 -- one delete-line
*-- escape each (viscreen.s VI_RPDEL), not a repaint from the
*-- cursor down. A refused motion/aborted read changed nothing.
:done       jsr   VI_CLAMP_COL
            jmp   VI_RP_CWD
:donelw     jsr   VI_CLAMP_COL
            ldx   #0
            jmp   VI_RP_LWD
:bell       jmp   VI_PLACE_CUR
:abort      pla
            pla
            jmp   VI_PLACE_CUR

*---------------------------------------------------------------
* VI_OP_D -- `d` + motion, or doubled `dd`. CLOBBERS: same as
* VI_OP_DC_BODY.
*---------------------------------------------------------------
VI_OP_D     lda   #"d"
            sta   VI_OPCHAR
            stz   VI_OPISCH
            jmp   VI_OP_DC_BODY

*---------------------------------------------------------------
* VI_OP_C -- `c` + motion, or doubled `cc`: same span math as
* `d`, then falls into insert (VI_INS_SHOWN -- this file's own
* EX_SNAPSHOT, taken before the delete, already covers the
* delete+insert pair as ONE undo unit, mirroring viinsert.s's
* `o`/`O` precedent). CLOBBERS: same as VI_OP_DC_BODY.
*---------------------------------------------------------------
VI_OP_C     lda   #"c"
            sta   VI_OPCHAR
            lda   #1
            sta   VI_OPISCH
            jmp   VI_OP_DC_BODY

*---------------------------------------------------------------
* VI_OP_Y -- `y` + motion, or doubled `yy`. Never mutates the
* buffer (no EX_SNAPSHOT -- nothing for `u` to reverse). Moves
* the cursor to the span's start (matches real vi for a
* BACKWARD yank like `yb`; a no-op for a forward one, since the
* start there already IS the original cursor). CLOBBERS: A, X,
* Y, PTR0, ED_TMP16, ED_TMP16B, VI_TMP, VI_TMP2, VI_MO_*,
* VI_REG*, ED_ADDR1/2, VI_SPSC/VI_SPEC (+ VI_DOMOTION's own).
*---------------------------------------------------------------
VI_OP_Y     lda   VI_COUNT
            pha
            lda   VI_COUNT+1
            pha
            jsr   VI_READCMD
            bcs   :abort
            sta   VI_TMP
            pla
            sta   ED_TMP16B+1
            pla
            sta   ED_TMP16B
            lda   VI_TMP
            cmp   #"y"
            beq   :doubled
            jsr   VI_OP_COMBINE
            lda   VI_TMP
            jsr   VI_DOMOTION
            bcs   :bell
            jsr   VI_SPAN_NORM
            lda   VI_MO_TYPE
            cmp   #2
            beq   :lw
            jsr   VI_OP_CWY
            bra   :setcur
:lw         jsr   VI_OP_LWY
:setcur     lda   ED_ADDR1
            sta   ED_CURLINE
            lda   ED_ADDR1+1
            sta   ED_CURLINE+1
            lda   VI_SPSC
            sta   VI_CURCOL
            bra   :done
:doubled    jsr   VI_OP_COMBINE
            jsr   VI_CNTNORM
            jsr   VI_OP_DDSPAN
            jsr   VI_OP_LWY       ;ED_CURLINE unchanged -- `yy`
                                  ;never moves the cursor
:done       jsr   VI_CLAMP_COL    ;nothing on the glass changed:
            jmp   VI_SCROLL_UP    ;place the cursor, scrolling
                                  ;if a backward yank left the
                                  ;window (2026-09-11)
:bell       jmp   VI_PLACE_CUR
:abort      pla
            pla
            jmp   VI_PLACE_CUR

*---------------------------------------------------------------
* VI_OP_CAPD -- `D` = `d$`: delete to end of line, no nested
* read (`$` ignores count). CLOBBERS: same as VI_OP_CWD, +
* EX_SNAPSHOT/VI_DOMOTION/VI_SPAN_NORM's own.
*---------------------------------------------------------------
VI_OP_CAPD  lda   #"$"
            jsr   VI_DOMOTION
            jsr   EX_SNAPSHOT
            jsr   VI_SPAN_NORM
            jsr   VI_OP_CWD
            jsr   VI_CLAMP_COL
            jmp   VI_RPT_LN             ;one line changed

*---------------------------------------------------------------
* VI_OP_CAPC -- `C` = `c$`. CLOBBERS: same as VI_OP_CAPD, + VI_
* INS_NOSNAP's own (never returns here).
*---------------------------------------------------------------
VI_OP_CAPC  lda   #"$"
            jsr   VI_DOMOTION
            jsr   EX_SNAPSHOT
            jsr   VI_SPAN_NORM
            jsr   VI_SAVESPAN
            jsr   VI_OP_CWD
            jmp   VI_OP_CWCHG

*---------------------------------------------------------------
* VI_OP_CAPY -- `Y` = `yy` (respects a leading count, same as
* `yy` itself -- VI_COUNT already holds it from VI_LOOP's own
* VI_READCMD). CLOBBERS: same as VI_OP_LWY, + VI_CNTNORM/VI_OP_
* DDSPAN's own.
*---------------------------------------------------------------
VI_OP_CAPY  jsr   VI_CNTNORM
            jsr   VI_OP_DDSPAN
            jsr   VI_OP_LWY
            jmp   VI_PLACE_CUR          ;nothing on the glass
                                        ;changed

*---------------------------------------------------------------
* VI_DELN -- delete up to VI_COUNT (normalized) chars starting
* at the cursor, yanking them into VI_REG first (charwise -- `x`
* and `s` both feed the unnamed register too, real vi's rule). A
* no-op if the cursor is already at/past the line's own length
* (empty line, or a fully-consumed short line). CLOBBERS: A, X,
* Y, PTR0, ED_TMP16, ED_SRC, SUBSCR, VI_REG, VI_REGTY, VI_TMP,
* VI_TMP2.
*---------------------------------------------------------------
VI_DELN     jsr   VI_CNTNORM
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN
            sta   VI_TMP
            lda   VI_CURCOL
            cmp   VI_TMP
            bcc   :haveroom
            rts                   ;nothing under the cursor
:haveroom   lda   VI_TMP
            sec
            sbc   VI_CURCOL
            sta   VI_TMP2         ;available chars
            lda   VI_COUNT+1
            bne   :usemax
            lda   VI_TMP2
            cmp   VI_COUNT
            bcs   :usecount
:usemax     lda   VI_TMP2
            bra   :haven
:usecount   lda   VI_COUNT
:haven      sta   VI_TMP2         ;n -- final delete count
            ldy   VI_CURCOL
            ldx   #0
:regcpy     cpx   VI_TMP2
            beq   :regdone
            lda   (PTR0),y
            sta   VI_REG,x
            iny
            inx
            bra   :regcpy
:regdone    lda   #0
            sta   VI_REG,x
            stz   VI_REGTY
            ldy   #0
            ldx   #0
:pfx        cpy   VI_CURCOL
            beq   :pfxdone
            lda   (PTR0),y
            sta   SUBSCR,x
            iny
            inx
            bra   :pfx
:pfxdone    tya
            clc
            adc   VI_TMP2
            tay
:sfx        cpy   VI_TMP
            bcs   :sfxdone
            lda   (PTR0),y
            sta   SUBSCR,x
            iny
            inx
            bra   :sfx
:sfxdone    stz   SUBSCR,x
            lda   #<SUBSCR
            sta   ED_SRC
            lda   #>SUBSCR
            sta   ED_SRC+1
            txa
            jsr   ED_BUMP_ALLOC
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            jsr   ED_SETSLOT
            jmp   VI_RG_STORE     ;a pending "x prefix saves it

*---------------------------------------------------------------
* VI_OP_X -- `x`: delete count chars forward, count-repeated
* (real vi -- `3x`). A true no-op (no snapshot) when there is
* nothing under the cursor. CLOBBERS: same as VI_DELN, + VI_
* CLAMP_COL/VI_RPT_LN's own.
*---------------------------------------------------------------
VI_OP_X     lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN
            cmp   VI_CURCOL
            beq   :none
            bcc   :none
            jsr   EX_SNAPSHOT
            jsr   VI_DELN
            jsr   VI_CLAMP_COL
            jmp   VI_RPT_LN
:none       rts

*---------------------------------------------------------------
* VI_OP_CAPX -- `X`: delete count chars BEFORE cursor
* (real vi -- `3X`), cursor lands where the first deleted char
* was. n = min(count, VI_CURCOL); a no-op at column 0 (nothing
* to the left). Reuses VI_DELN by moving the cursor back n then
* deleting n forward from there. CLOBBERS: same as VI_DELN, +
* VI_CLAMP_COL/VI_RPT_LN's own. (2026-09-05, check_posixvi.)
*---------------------------------------------------------------
VI_OP_CAPX  jsr   VI_CNTNORM            ;VI_COUNT >= 1
            lda   VI_CURCOL
            bne   :cx_have
            rts                          ;col 0 -- nothing left
:cx_have    lda   VI_COUNT+1             ;n = min(count, col)
            bne   :cx_ncol               ;count >= 256 -> col
            lda   VI_CURCOL
            cmp   VI_COUNT
            bcs   :cx_ncount             ;col >= count -> count
:cx_ncol    lda   VI_CURCOL             ;col < count -> col
            bra   :cx_haven
:cx_ncount  lda   VI_COUNT
:cx_haven   sta   VI_TMP                 ;n
            lda   VI_CURCOL             ;move the cursor back n:
            sec                          ;the n chars to delete
            sbc   VI_TMP                 ;are now [cursor, +n)
            sta   VI_CURCOL
            lda   VI_TMP                 ;delete exactly n
            sta   VI_COUNT
            stz   VI_COUNT+1
            jsr   EX_SNAPSHOT
            jsr   VI_DELN
            jsr   VI_CLAMP_COL
            jmp   VI_RPT_LN

*---------------------------------------------------------------
* VI_OP_CAPS -- `S` = `cc`: change count WHOLE lines. Doubled-
* `c` path (VI_OP_DC_BODY :doubled) without the nested key read:
* span the lines, snapshot, yank them to the register, delete
* them, open one fresh empty line and enter insert. CLOBBERS:
* same as that path. (2026-09-05, check_posixvi.)
*---------------------------------------------------------------
VI_OP_CAPS  jsr   VI_CNTNORM
            jsr   VI_OP_DDSPAN          ;ED_ADDR1/2 = the lines
            jsr   VI_SAVESPAN
            jsr   EX_SNAPSHOT
            jsr   VI_OP_LWY             ;yank to VI_REG
            jsr   ED_DLT_RANGE
            jmp   VI_OP_LWCT            ;empty line + insert

*---------------------------------------------------------------
* VI_OP_S -- `s` = `cl`: delete count chars forward (same core
* as `x`), then enter insert -- unlike `x`, always snapshots
* (even on an empty line, `s` degrades to a plain `i`, itself a
* real -- if trivial -- undo point, matching VI_INS_ENTER's own
* precedent of an unconditional snapshot). CLOBBERS: same as VI_
* DELN, + VI_INS_SHOWN's own (never returns here).
*---------------------------------------------------------------
VI_OP_S     jsr   EX_SNAPSHOT
            jsr   VI_DELN
            jmp   VI_INS_1LN            ;show the line, insert

