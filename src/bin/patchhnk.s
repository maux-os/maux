*---------------------------------------------------------------
* patchhnk.s -- the patch READER: find the format, take the
* pathnames out of its header, and turn each hunk of any of the
* three forms into the one triple the rest of the program uses
* (OSTART + the OLD line list + the NEW line list).
*
* `put` into src/bin/patch.s; one assembly stream, every rule in
* that manifest's header applies unchanged.
*
* The lists hold POINTERS INTO THE RAW TEXT this hunk's lines
* were read into, offset past the form's own prefix -- one byte
* for unified, two for context and normal. Nothing is copied
* twice, and the raw lines stay intact for the reject file.
*---------------------------------------------------------------

*---------------------------------------------------------------
* SCANHDR -- read forward until the patch announces itself, and
* keep whatever pathnames it announced on the way. Anything
* unrecognised is skipped, which is what lets a patch that
* arrived inside a mail message still apply. Exits 2 if the
* stream ends without a hunk in it.
*
* The order of the tests below is load-bearing: "*** 1,3 ****"
* also begins "*** ", so the STARS line must end the scan
* before a second `*** ` line can be mistaken for a pathname.
*---------------------------------------------------------------
SCANHDR     stz   LASTSTAR
:loop       jsr   HUNKINIT          ;a skipped line is not part
            jsr   PGETLN            ;of any hunk's raw text
            bcc   :got
            jmp   NOPATCH
:got        lda   (PT_LP)
            cmp   #$AA              ;'*'
            beq   :star
            cmp   #$AD              ;'-'
            beq   :dash
            cmp   #$AB              ;'+'
            beq   :plus
            cmp   #$C0              ;'@'
            beq   :at
            jsr   NORMCMD
            bcs   :skip
            lda   #FORM_N
            sta   FORM
            jmp   PUSHBACK
:skip       stz   LASTSTAR
            jmp   :loop

:star       lda   #3
            jsr   LINECH
            cmp   #$AA              ;"****" -- the stars line
            beq   :isctx
            cmp   #$A0              ;"*** " -- a pathname
            bne   :skip
            lda   #<OLDNAME
            ldx   #>OLDNAME
            jsr   SAVENAME
            lda   #1
            sta   LASTSTAR
            jmp   :loop
:isctx      lda   #FORM_C
            sta   FORM
            jmp   PUSHBACK

:dash       lda   #1
            jsr   LINECH
            cmp   #$AD
            bne   :skip
            lda   #3
            jsr   LINECH
            cmp   #$A0              ;"--- " -- a pathname
            bne   :skip
            lda   LASTSTAR
            bne   :ctxnew
            lda   #<OLDNAME         ;unified: the OLD name
            ldx   #>OLDNAME
            bra   :savit
:ctxnew     lda   #<NEWNAME         ;context: the NEW name
            ldx   #>NEWNAME
:savit      jsr   SAVENAME
            stz   LASTSTAR
            jmp   :loop

:plus       lda   #3
            jsr   LINECH
            cmp   #$A0              ;"+++ "
            bne   :skip
            lda   #<NEWNAME
            ldx   #>NEWNAME
            jsr   SAVENAME
            stz   LASTSTAR
            jmp   :loop

:at         lda   #1
            jsr   LINECH
            cmp   #$C0              ;"@@"
            bne   :skip
            lda   #FORM_U
            sta   FORM
            jmp   PUSHBACK

*---------------------------------------------------------------
* SAVENAME -- IN: A/X = lo/hi of a NAMEMAX buffer. Copy the
* pathname that starts at PT_LP+4, stopping at a <tab>, a
* <space> or the end of the line -- a diff's header line is
* "--- NAME<tab>TIMESTAMP" and maux's own is "--- NAME", so
* both are read by the same rule (src/bin/diffctx.s's TIMESTAMPS
* note).
*---------------------------------------------------------------
SAVENAME    sta   PT_NBUF
            stx   PT_NBUF+1
            lda   #4                ;past the 4-char leader
            jsr   SETSCAN
            ldy   #0
:cl         cpy   #NAMEMAX-1
            bcs   :done
            lda   (PT_SCAN),y
            beq   :done
            cmp   #$89              ;<tab>
            beq   :done
            cmp   #$A0              ;<space>
            beq   :done
            sta   (PT_NBUF),y
            iny
            bra   :cl
:done       lda   #0
            sta   (PT_NBUF),y
            rts

*---------------------------------------------------------------
* LINECH -- IN: A = an offset into the line at PT_LP. OUT: A =
* the character there, or 0 if the line is SHORTER than that --
* every format test below peeks at offset 1 or 3, and a short
* line must answer "not that" rather than read whatever the
* previous hunk left in the arena.
*---------------------------------------------------------------
LINECH      sta   PT_TMP2
            ldy   #0
:l          cpy   PT_TMP2
            beq   :at
            lda   (PT_LP),y
            beq   :short
            iny
            bra   :l
:at         lda   (PT_LP),y
            rts
:short      lda   #0
            rts

*---------------------------------------------------------------
* SETTGT -- decide WHICH file is being patched and leave its
* name in NAMEBUF: the operand if there is one, else the
* header's old name, else its new name -- the first of the two
* that can actually be opened, which is patch(1)'s own rule and
* the reason a `diff -u a b` patch applies to `a`. -p strips
* that many leading pathname components off a header name
* first. Exits 2 if nothing names an openable file.
*---------------------------------------------------------------
SETTGT      lda   HAVEOP
            beq   :fromhdr
            lda   OPIDX
            jsr   GETARG
            lda   #<NAMEBUF
            ldx   #>NAMEBUF
            jmp   CPNAME
:fromhdr    lda   #<OLDNAME
            ldx   #>OLDNAME
            jsr   TRYNAME
            bcc   :ok
            lda   #<NEWNAME
            ldx   #>NEWNAME
            jsr   TRYNAME
            bcc   :ok
            jmp   NOTARGET
:ok         rts

* TRYNAME -- IN: A/X = a header name buffer. Strip -p's
* components, and if what is left opens, put it in NAMEBUF and
* return carry CLEAR.
TRYNAME     sta   PTR0
            stx   PTR0+1
            lda   (PTR0)
            bne   :have
            sec                     ;the header never named one
            rts
:have       jsr   STRIPP
            lda   #<NAMEBUF
            ldx   #>NAMEBUF
            jsr   CPNAME
            lda   #<NAMEBUF
            sta   PTR0
            lda   #>NAMEBUF
            sta   PTR0+1
            jsr   MKPATH1
            lda   #<IOPARM
            ldx   #>IOPARM
            jsr   SC_OPEN
            bcs   :no
            lda   IOPARM_REF
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            clc
            rts
:no         sec
            rts

* STRIPP -- IN: PTR0 = a name. OUT: PTR0 advanced past PSTRIP
* leading "component/" runs (fewer if the name runs out first,
* the same leniency patch(1) has).
STRIPP      lda   PSTRIP
            beq   :done
            sta   PT_TMP
:comp       ldy   #0
:scan       lda   (PTR0),y
            beq   :done             ;no more separators
            iny
            cmp   #$AF              ;'/'
            bne   :scan
            tya
            clc
            adc   PTR0
            sta   PTR0
            lda   PTR0+1
            adc   #0
            sta   PTR0+1
            dec   PT_TMP
            bne   :comp
:done       rts

* CPNAME -- IN: PTR0 = source, A/X = a NAMEMAX destination.
* Bounded copy (STRCPY has no bound -- liba/string.s's header).
CPNAME      sta   PT_NBUF
            stx   PT_NBUF+1
            ldy   #0
:cl         cpy   #NAMEMAX-1
            bcs   :cdone
            lda   (PTR0),y
            beq   :cdone
            sta   (PT_NBUF),y
            iny
            bra   :cl
:cdone      lda   #0
            sta   (PT_NBUF),y
            rts

*---------------------------------------------------------------
* NUMBERS. GETNUM reads a decimal at PT_SCAN into A, saturating
* at 255 (a stated line number past the target's own cap cannot
* match anything anyway, so saturation loses nothing a larger
* accumulator would keep). Carry SET = there was no digit.
*---------------------------------------------------------------
GETNUM      stz   PT_TMP2
            stz   PT_TMP2+1         ;digits seen
:nl         lda   (PT_SCAN)
            and   #$7F
            cmp   #'0'
            bcc   :ndone
            cmp   #'9'+1
            bcs   :ndone
            and   #$0F
            sta   PT_TMP
            lda   PT_TMP2
            cmp   #24               ;24*10+9 would wrap a byte
            bcs   :nsat
            asl   a
            sta   PT_TMP+1
            asl   a
            asl   a
            clc
            adc   PT_TMP+1
            clc
            adc   PT_TMP
            sta   PT_TMP2
            bra   :nadv
:nsat       lda   #255
            sta   PT_TMP2
:nadv       inc   PT_TMP2+1
            jsr   SCANADV
            bra   :nl
:ndone      lda   PT_TMP2+1
            beq   :nonum
            lda   PT_TMP2
            clc
            rts
:nonum      sec
            rts

* SCANADV -- PT_SCAN += 1.
SCANADV     inc   PT_SCAN
            bne   :sa
            inc   PT_SCAN+1
:sa         rts

* SCANTO -- IN: A = a character. Advance PT_SCAN to the first
* occurrence at or after it, then one past. Carry SET = end of
* line first.
SCANTO      sta   PT_TMP
:tl         lda   (PT_SCAN)
            beq   :tno
            cmp   PT_TMP
            beq   :thit
            jsr   SCANADV
            bra   :tl
:thit       jsr   SCANADV
            clc
            rts
:tno        sec
            rts

* SETSCAN -- PT_SCAN = PT_LP + A.
SETSCAN     clc
            adc   PT_LP
            sta   PT_SCAN
            lda   PT_LP+1
            adc   #0
            sta   PT_SCAN+1
            rts

*---------------------------------------------------------------
* SKIPPFX -- IN: A = the form's prefix length. OUT: PT_LP2 =
* the line's TEXT. A line SHORTER than its own prefix (a
* trailing-blank-stripped context line, which mailers produce)
* yields a pointer to its NUL, i.e. the empty line it stands
* for, rather than a read past the end.
*---------------------------------------------------------------
SKIPPFX     sta   PT_TMP2
            ldy   #0
:l          cpy   PT_TMP2
            bcs   :done
            lda   (PT_LP),y
            beq   :done
            iny
            bra   :l
:done       tya
            clc
            adc   PT_LP
            sta   PT_LP2
            lda   PT_LP+1
            adc   #0
            sta   PT_LP2+1
            rts

*---------------------------------------------------------------
* NORMCMD -- is the line at PT_LP a normal-diff command
* ("3c3", "3a4", "3,5d2")? Carry CLEAR = yes, with OSTART,
* NSTART and CMDC set. Nothing else in the three formats begins
* with a digit, which is what makes this a safe detector as
* well as a parser.
*---------------------------------------------------------------
NORMCMD     lda   #0
            jsr   SETSCAN
            jsr   GETNUM
            bcs   :no
            sta   OSTART
            lda   (PT_SCAN)
            cmp   #$AC              ;',' -- a range's end line
            bne   :cmd
            jsr   SCANADV
            jsr   GETNUM
            bcs   :no
:cmd        lda   (PT_SCAN)
            cmp   #$E1              ;'a'
            beq   :havec
            cmp   #$E3              ;'c'
            beq   :havec
            cmp   #$E4              ;'d'
            bne   :no
:havec      sta   CMDC
            jsr   SCANADV
            jsr   GETNUM
            bcs   :no
            sta   NSTART
            lda   (PT_SCAN)
            cmp   #$AC
            bne   :end
            jsr   SCANADV
            jsr   GETNUM
            bcs   :no
:end        lda   (PT_SCAN)
            bne   :no               ;junk: not a command
            clc
            rts
:no         sec
            rts

*---------------------------------------------------------------
