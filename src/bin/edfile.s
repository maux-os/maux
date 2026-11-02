*---------------------------------------------------------------
* edfile.s -- ed's filename handling and the file-backed
* commands (`r`, `w`) with their MLI parameter blocks, `put`
* by src/bin/ed.s. See edparse.s's header for the put-module
* shape and why this unit is split at all.
*---------------------------------------------------------------
* carry set = ED_ADDR1 > ED_NLINES (invalid for a/i, which allow
* 0)
ED_CHECK0N  lda   ED_ADDR1+1
            cmp   ED_NLINES+1
            bcc   :ok
            bne   :bad
            lda   ED_ADDR1
            cmp   ED_NLINES
            bcc   :ok
            beq   :ok
:bad        sec
            rts
:ok         clc
            rts

* normalize ED_ADDR1/ED_ADDR2 per the classic 0/1/2-address
* default rule (0 -> .,. ; 1 -> addr1,addr1 ; 2 -> as given)
ED_DFLT_DTDT
            lda   ED_ADDRCNT
            bne   :have1
            lda   ED_CURLINE
            sta   ED_ADDR1
            lda   ED_CURLINE+1
            sta   ED_ADDR1+1
            lda   ED_CURLINE
            sta   ED_ADDR2
            lda   ED_CURLINE+1
            sta   ED_ADDR2+1
            rts
:have1      cmp   #1
            bne   :have2
            lda   ED_ADDR1
            sta   ED_ADDR2
            lda   ED_ADDR1+1
            sta   ED_ADDR2+1
:have2      rts

* carry set = invalid (needs 1<=ADDR1<=ADDR2<=NLINES)
ED_CHC_RNG12N
            lda   ED_ADDR1
            ora   ED_ADDR1+1
            beq   :bad
            lda   ED_ADDR1+1
            cmp   ED_ADDR2+1
            bcc   :chk2
            bne   :bad
            lda   ED_ADDR1
            cmp   ED_ADDR2
            bcc   :chk2
            beq   :chk2
            bra   :bad
:chk2       lda   ED_ADDR2+1
            cmp   ED_NLINES+1
            bcc   :ok
            bne   :bad
            lda   ED_ADDR2
            cmp   ED_NLINES
            bcc   :ok
            beq   :ok
:bad        sec
            rts
:ok         clc
            rts

*---------------------------------------------------------------
* Command handlers.
*---------------------------------------------------------------
ED_CMD_A    lda   ED_ADDRCNT
            cmp   #2
            bne   :toerr1
            jmp   ED_ERR_JMP
:toerr1
            lda   ED_ADDRCNT
            bne   :haveaddr
            lda   ED_CURLINE
            sta   ED_ADDR1
            lda   ED_CURLINE+1
            sta   ED_ADDR1+1
:haveaddr   jsr   ED_CHECK0N
            bcc   :toerr2
            jmp   ED_ERR_JMP
:toerr2
            lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
            jsr   ED_TEXTENTRY
            jmp   MAINLOOP

ED_CMD_I    lda   ED_ADDRCNT
            cmp   #2
            bne   :toerr3
            jmp   ED_ERR_JMP
:toerr3
            lda   ED_ADDRCNT
            bne   :haveaddr
            lda   ED_CURLINE
            sta   ED_ADDR1
            lda   ED_CURLINE+1
            sta   ED_ADDR1+1
:haveaddr   jsr   ED_CHECK0N
            bcc   :toerr4
            jmp   ED_ERR_JMP
:toerr4
            lda   ED_ADDR1
            ora   ED_ADDR1+1
            bne   :nz
            stz   ED_TMP16
            stz   ED_TMP16+1
            bra   :go
:nz         lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
            lda   ED_TMP16
            bne   :nb8
            dec   ED_TMP16+1
:nb8        dec   ED_TMP16
:go         jsr   ED_TEXTENTRY
            jmp   MAINLOOP

ED_CMD_C    jsr   ED_DFLT_DTDT
            jsr   ED_CHC_RNG12N
            bcc   :toerr5
            jmp   ED_ERR_JMP
:toerr5
            lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
            lda   ED_TMP16
            bne   :nb9
            dec   ED_TMP16+1
:nb9        dec   ED_TMP16
            lda   ED_TMP16
            sta   ED_TMP16B
            lda   ED_TMP16+1
            sta   ED_TMP16B+1
            jsr   ED_DLT_RANGE
            lda   ED_TMP16B
            sta   ED_TMP16
            lda   ED_TMP16B+1
            sta   ED_TMP16+1
            jsr   ED_TEXTENTRY
            jmp   MAINLOOP

ED_CMD_D    jsr   ED_DFLT_DTDT
            jsr   ED_CHC_RNG12N
            bcc   :toerr6
            jmp   ED_ERR_JMP
:toerr6
            jsr   ED_DLT_RANGE
            jmp   MAINLOOP

ED_CMD_P    jsr   ED_DFLT_DTDT
            jsr   ED_CHC_RNG12N
            bcc   :toerr7
            jmp   ED_ERR_JMP
:toerr7
            lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
:loop       jsr   ED_LINETEXT
            jsr   ED_PUTLINE
            lda   ED_TMP16
            cmp   ED_ADDR2
            bne   :next
            lda   ED_TMP16+1
            cmp   ED_ADDR2+1
            bne   :next
            bra   :setdot
:next       inc   ED_TMP16
            bne   :nb10
            inc   ED_TMP16+1
:nb10       bra   :loop
:setdot     lda   ED_ADDR2
            sta   ED_CURLINE
            lda   ED_ADDR2+1
            sta   ED_CURLINE+1
            jmp   MAINLOOP

ED_CMD_N    jsr   ED_DFLT_DTDT
            jsr   ED_CHC_RNG12N
            bcc   :toerr8
            jmp   ED_ERR_JMP
:toerr8
            lda   ED_ADDR1
            sta   ED_TMP16
            lda   ED_ADDR1+1
            sta   ED_TMP16+1
:loop       lda   ED_TMP16
            sta   U2DEC_VAL
            lda   ED_TMP16+1
            sta   U2DEC_VAL+1
            lda   #<NUMBUF
            sta   PTR1
            lda   #>NUMBUF
            sta   PTR1+1
            jsr   U2DEC
            lda   #ED_NUM_RJUST      ;ex/vi #/nu: right-justify
            beq   :n_nopad           ;the number in a 7-wide
            ldy   #0                 ;field. ed n: no pad (TAB)
:n_len      lda   NUMBUF,y
            beq   :n_lend
            iny
            bne   :n_len
:n_lend     sty   ED_TMP16B
            lda   #7
            sec
            sbc   ED_TMP16B
            tax
            bmi   :n_nopad
            beq   :n_nopad
:n_pad      lda   #$A0              ;a leading space (high-bit)
            phx
            ldx   #FD_STDOUT
            jsr   PUTC
            plx
            dex
            bne   :n_pad
:n_nopad    lda   #<NUMBUF
            sta   PTR0
            lda   #>NUMBUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #ED_NUM_RJUST
            beq   :n_tab
            lda   #$A0              ;ex/vi: space after number
            bra   :n_sep
:n_tab      lda   #$89              ;ed: a TAB after the number
:n_sep      ldx   #FD_STDOUT
            jsr   PUTC
            jsr   ED_LINETEXT
            jsr   ED_PUTLINE
            lda   ED_TMP16
            cmp   ED_ADDR2
            bne   :next
            lda   ED_TMP16+1
            cmp   ED_ADDR2+1
            bne   :next
            bra   :setdot
:next       inc   ED_TMP16
            bne   :nb11
            inc   ED_TMP16+1
:nb11       bra   :loop
:setdot     lda   ED_ADDR2
            sta   ED_CURLINE
            lda   ED_ADDR2+1
            sta   ED_CURLINE+1
            jmp   MAINLOOP

ED_CMD_Q    lda   ED_ADDRCNT
            beq   :toerr9
            jmp   ED_ERR_JMP
:toerr9
            jsr   ED_QCLEANUP      ;no-op in `ed`; ex's swap
                                   ;CLOSE+UNLINK (exbuf.s)
                                   ;see its own header
            lda   ED_ERRSTAT       ;EX2 2026-09-06
            jsr   EXIT

* -- more zero page, for the substitution engine --
ED_SUBCUR   equ   $57        ;2  s command: "copied from here"
                             ;cursor into the ORIGINAL line
ED_SUBOUT   equ   $59        ;2  s command: output length so far
                             ;in SUBSCR (capped at 254 -- high
                             ;byte always 0)
ED_SUBHIT   equ   $5B        ;1  s command: did THIS line match
                             ;at all
ED_SUBLINE  equ   $5C        ;2  s command: caller's line
                             ;number, preserved across
                             ;ED_BUMP_ALLOC's ED_TMP16 scratch
                             ;use
* window now $30-$5D, 46 bytes -- still inside $30-$5F.

*---------------------------------------------------------------
* ED_RMBR_FNAME / ED_HAS_FNAME -- the remembered-filename buffer
* (finding 3, 2026-08-19). ED_CURFNAME (data section, near
* PATHBUF) is 65 bytes, MLI length-prefixed -- the exact shape
* PATHBUF is already in after MKPATH runs, so remembering a name
* is a straight byte copy either direction, never a re-encode.
* ED_CURFNAME[0]==0 means "nothing remembered yet" (a real MLI
* pathname is never zero-length) -- STARTup stz's it.
*
* ED_RMBR_FNAME -- copy PATHBUF -> ED_CURFNAME (call after a
* successful r/w open, whether the name just came from an
* explicit argument or was itself reused from ED_CURFNAME --
* either way the copy is idempotent).
*---------------------------------------------------------------
ED_RMBR_FNAME
            lda   PATHBUF
            sta   ED_TMP16
            ldy   #0
:loop       lda   PATHBUF,y
            sta   ED_CURFNAME,y
            cpy   ED_TMP16
            beq   :done
            iny
            bra   :loop
:done       rts

*---------------------------------------------------------------
* ED_HAS_FNAME -- OUT: carry set + PATHBUF loaded from
* ED_CURFNAME = a name IS remembered; carry clear = nothing
* remembered yet (PATHBUF untouched).
*---------------------------------------------------------------
ED_HAS_FNAME
            lda   ED_CURFNAME
            bne   :have
            clc
            rts
:have       sta   ED_TMP16
            ldy   #0
:loop       lda   ED_CURFNAME,y
            sta   PATHBUF,y
            cpy   ED_TMP16
            beq   :done
            iny
            bra   :loop
:done       sec
            rts

*---------------------------------------------------------------
* ED_ABSPATH -- XC2 2026-09-06: canonicalize a length-prefixed,
* 7-bit MLI pathname to absolute form, for comparison. MKPATH
* does NOT make a bare relative path absolute (the kernel does
* that at OPEN, via PRC_ABSPATH) -- so ED_FNAME_EQ comparing raw
* PATHBUF/ED_CURFNAME spellings wrongly refused an equivalent
* relative one. A path whose first data byte isn't '/' gets the
* current prefix prepended, via MKP_PFX (mli.s) -- the SAME
* SC_GETPFX/MLI GET_PREFIX ($C7) call MKPATH's own leading-dot
* resolution already uses; no second normalization invented.
*
* IN: PTR0 = source path (PATHBUF/ED_CURFNAME shape); PTR1 =
* a 65-byte destination buffer (never the same storage as the
* source -- the copy loops below index both by the same rules
* MKPATH itself uses for its own dest-from-source shape).
* OUT: destination filled with the absolute MLI-shaped path.
* FALLBACK (documented, XC2): GET_PREFIX failing, or the
* combined length exceeding 64 chars, copies the SOURCE
* verbatim instead -- the conservative "still needs `!`" answer,
* never a further guess. CLOBBERS: A, X, Y, PTR0, PTR2,
* ED_ABSLEN, MKP_ADJ, MKP_GPARM.
*---------------------------------------------------------------
ED_ABSPATH  ldy   #0
            lda   (PTR0),y
            sta   ED_ABSLEN
            beq   :ap_verb        ;empty source -- copy as-is
            ldy   #1
            lda   (PTR0),y
            cmp   #'/'
            beq   :ap_verb        ;already absolute
            jsr   MKP_PFX
            bcc   :ap_verb        ;GET_PREFIX failed -- fallback
            lda   MKP_ADJ
            clc
            adc   ED_ABSLEN
            cmp   #MLI_PTH_MAXLN+1
            bcs   :ap_verb        ;combined too long -- fallback
            ldy   #0
            sta   (PTR1),y        ;final count byte
            inc   PTR0            ;-> source DATA (skip its
            bne   :ap_p0          ;own count byte) so a plain
            inc   PTR0+1          ;0-based Y indexes both below
:ap_p0      lda   PTR1
            sta   PTR2
            lda   PTR1+1
            sta   PTR2+1
            lda   PTR2
            clc
            adc   #1
            sta   PTR2
            bcc   :ap_p1
            inc   PTR2+1
:ap_p1      lda   PTR2             ;PTR2 = PTR1+1+MKP_ADJ, the
            clc                    ;first free destination byte,
            adc   MKP_ADJ          ;right after MKP_PFX's own
            sta   PTR2             ;prefix text
            bcc   :ap_p2
            inc   PTR2+1
:ap_p2      ldy   #0
:ap_cpy     cpy   ED_ABSLEN
            beq   :ap_done
            lda   (PTR0),y
            sta   (PTR2),y
            iny
            bra   :ap_cpy
:ap_done    rts
:ap_verb    ldy   #0
:ap_vloop   lda   (PTR0),y         ;count byte, then N data
            sta   (PTR1),y         ;bytes -- ED_ABSLEN+1 total
            cpy   ED_ABSLEN
            beq   :ap_vdone
            iny
            bra   :ap_vloop
:ap_vdone   rts

*---------------------------------------------------------------
* ED_FNAME_EQ -- EX5 (2026-09-06); canonicalized XC2 2026-09-06.
* Does the just-resolved write target (PATHBUF, post-MKPATH)
* name the SAME file as the remembered current filename
* (ED_CURFNAME)? Used by the `w!` guard: a target naming the
* file already open needs no `!` -- only a genuinely DIFFERENT
* existing file does.
*
* Both sides are canonicalized to absolute form by ED_ABSPATH
* first (into ED_ABSBUF/ED_ABSBUF2) -- comparing the raw
* spellings missed an absolute current file re-saved through an
* equivalent RELATIVE path (XC2).
*
* Deliberately NOT liba's STRCMPI: these are MLI pathnames --
* 7-bit (MKPATH strips the high bit, mli.s), length-prefixed,
* NOT NUL-terminated -- while STRCMPI's SIFOLD only folds
* high-bit 'a'-'z' ($E1-$FA) and hunts for a NUL. Calling it
* here would neither fold a typed lowercase letter (7-bit 'a'-
* 'z' is $61-$7A, outside SIFOLD's range) nor stop at the right
* place (an MLI pathname has no terminator to find). Reuses
* SIFOLD itself -- the one case-fold RULE in the tree (string.s)
* -- rather than inventing a second: `ora #$80` lifts each 7-bit
* byte into SIFOLD's own domain first, so 'k'/'K' fold
* identically to how STRCMPI would fold them for a liba string.
* The length prefix bounds the walk; no terminator needed.
*
* IN: PATHBUF = resolved target, ED_CURFNAME = remembered name
* (both already in MKPATH's output shape -- ED_RMBR_FNAME's own
* header). OUT: carry set = same file; carry clear = different,
* or ED_CURFNAME[0]==0 (nothing remembered -- can't match).
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2, ED_TMP16, ED_ABSLEN,
* MKP_ADJ, MKP_GPARM.
*---------------------------------------------------------------
ED_FNAME_EQ lda   ED_CURFNAME
            beq   :fq_diff        ;nothing remembered yet
            lda   #<PATHBUF
            sta   PTR0
            lda   #>PATHBUF
            sta   PTR0+1
            lda   #<ED_ABSBUF
            sta   PTR1
            lda   #>ED_ABSBUF
            sta   PTR1+1
            jsr   ED_ABSPATH
            lda   #<ED_CURFNAME
            sta   PTR0
            lda   #>ED_CURFNAME
            sta   PTR0+1
            lda   #<ED_ABSBUF2
            sta   PTR1
            lda   #>ED_ABSBUF2
            sta   PTR1+1
            jsr   ED_ABSPATH
            lda   ED_ABSBUF2
            cmp   ED_ABSBUF
            bne   :fq_diff        ;different lengths
            tay
:fq_loop    lda   ED_ABSBUF,y
            ora   #$80
            jsr   SIFOLD
            sta   ED_TMP16
            lda   ED_ABSBUF2,y
            ora   #$80
            jsr   SIFOLD
            cmp   ED_TMP16
            bne   :fq_diff
            dey
            bne   :fq_loop
            sec
            rts
:fq_diff    clc
            rts

*---------------------------------------------------------------
* ED_PRS_FNAME -- expects a single space then a filename
* (the rest of the command line) at ED_CMDPTR. OUT: carry clear,
* PTR0 = filename (a liba string -- points directly into CMDBUF,
* not copied); carry set = no space, or an empty filename.
*---------------------------------------------------------------
ED_PRS_FNAME
            ldy   #0
            lda   (ED_CMDPTR),y
            cmp   #$A0
            bne   :bad
            inc   ED_CMDPTR
            bne   :ok
            inc   ED_CMDPTR+1
:ok         lda   (ED_CMDPTR),y
            beq   :bad
            lda   ED_CMDPTR
            sta   PTR0
            lda   ED_CMDPTR+1
            sta   PTR0+1
            clc
            rts
:bad        sec
            rts
