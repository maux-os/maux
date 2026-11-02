*---------------------------------------------------------------
* uniqcmp.s -- uniq's comparison and run-output layer: the
* previous-line save (SAVEPREV), the -f/-s field/char skip and
* the compare it feeds (SKIPCMP/SK_ADV/ISBLANK), the -f/-s
* operand parser (PARSENUM8), and the run accounting and
* emission (BUMPRUN/ISDUP/OUTRUN/PRCNT). `put` by src/bin/uniq.s
* exactly where the code used to sit -- one assembly stream,
* byte-identical -- and it is uniq's SECOND put file, beside
* uniqio.s; same two-module precedent as nl.s's nlopt.s/nlfmt.s.
* Split at a GLOBAL boundary (SAVEPREV's banner) so no :local
* reparents. NOT a standalone binary. The reason is S9's
* as-window budget (docs/S9-PLAN.md sec 5): `as`'s 16,128-byte
* source window holds the resident manifest plus one put file at
* a time, and uniq.s's own text went past it again once -f/-s
* landed. Every symbol here resolves against uniq.s's own
* equates, zero page pointers and dum cells (CNTFLD/LINEMAX/
* CURBUF/PREVBUF/CNTBUF/RUNCNT/SKIPFLD/SKIPCHR/PNVAL/WANT_C/
* WANT_D/WANT_U/OUTFD) -- see that file's own header.
*---------------------------------------------------------------
*---------------------------------------------------------------
* SAVEPREV -- PREVBUF <- CURBUF (liba STRCPY).
*---------------------------------------------------------------
SAVEPREV    lda   #<CURBUF
            sta   PTR0
            lda   #>CURBUF
            sta   PTR0+1
            lda   #<PREVBUF
            sta   PTR1
            lda   #>PREVBUF
            sta   PTR1+1
            jsr   STRCPY
            rts

*---------------------------------------------------------------
* SKIPCMP -- IN: PTR0 = start of a NUL-terminated line. OUT:
* PTR0 advanced past SKIPFLD fields (leading blanks + a maximal
* non-blank run, repeated) then SKIPCHR further raw bytes -- see
* file header. Stops early, at the line's own NUL, if it runs
* out before finishing either skip. CLOBBERS: A, Y, SK_I.
*---------------------------------------------------------------
SKIPCMP     lda   SKIPFLD
            beq   :dochars
            sta   SK_I
:ffldlp     ldy   #0
:fbl        lda   (PTR0),y
            beq   :done
            jsr   ISBLANK
            bcc   :ffld
            jsr   SK_ADV
            bra   :fbl
:ffld       ldy   #0
            lda   (PTR0),y
            beq   :done
            jsr   ISBLANK
            bcs   :ffend
            jsr   SK_ADV
            bra   :ffld
:ffend      dec   SK_I
            bne   :ffldlp
:dochars    lda   SKIPCHR
            beq   :done
            sta   SK_I
:cskiplp    ldy   #0
            lda   (PTR0),y
            beq   :done
            jsr   SK_ADV
            dec   SK_I
            bne   :cskiplp
:done       rts

*---------------------------------------------------------------
* SK_ADV -- PTR0 += 1 (16-bit). CLOBBERS: A.
*---------------------------------------------------------------
SK_ADV      inc   PTR0
            bne   :ok
            inc   PTR0+1
:ok         rts

*---------------------------------------------------------------
* ISBLANK -- carry SET if A is space or tab (high-bit-set),
* clear otherwise. Same shape as wc.s's ISSPACE, minus CR (a
* GETLINE buffer never contains one).
*---------------------------------------------------------------
ISBLANK     cmp   #$A0
            beq   :yes
            cmp   #$89
            beq   :yes
            cmp   #$20             ;the LOW twins, from a file
            beq   :yes             ;that came from outside maux
            cmp   #$09
            beq   :yes
            clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* PARSENUM8 -- IN: PTR0 = operand text. OUT: carry CLEAR and
* PNVAL = its 8-bit value; carry SET on empty, non-digit, or a
* value > 255. kill.s's own PARSEPID, duplicated rather than
* shared -- see this file's header on why (no cross-bin headers
* for a routine this small).
*---------------------------------------------------------------
PARSENUM8   stz   PNVAL
            ldy   #0
            lda   (PTR0),y
            beq   :bad
:pnlp       lda   (PTR0),y
            beq   :ok
            and   #$7F
            cmp   #'0'
            bcc   :bad
            cmp   #'9'+1
            bcs   :bad
            sec
            sbc   #'0'
            pha
            lda   PNVAL
            asl   a
            bcs   :badp
            asl   a
            bcs   :badp
            adc   PNVAL
            bcs   :badp
            asl   a
            bcs   :badp
            sta   PNVAL
            pla
            clc
            adc   PNVAL
            bcs   :bad
            sta   PNVAL
            iny
            bra   :pnlp
:badp       pla
:bad        sec
            rts
:ok         clc
            rts

*---------------------------------------------------------------
* BUMPRUN -- RUNCNT++, saturating at $FFFF (wc.s's BUMP, scoped
* to uniq's one run counter).
*---------------------------------------------------------------
BUMPRUN     lda   RUNCNT
            cmp   #$FF
            bne   :inclo
            lda   RUNCNT+1
            cmp   #$FF
            beq   :rt                ;pinned, stay
:inclo      inc   RUNCNT
            bne   :rt
            inc   RUNCNT+1
:rt         rts

*---------------------------------------------------------------
* ISDUP -- carry SET if RUNCNT > 1, CLEAR if RUNCNT == 1.
*---------------------------------------------------------------
ISDUP       lda   RUNCNT+1
            bne   :yes
            lda   RUNCNT
            cmp   #2
            bcc   :no
:yes        sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* OUTRUN -- emit PREVBUF's run (collapsed to one copy) to OUTFD,
* honouring WANT_D/WANT_U/WANT_C. No-op if -d/-u filters it out.
*---------------------------------------------------------------
OUTRUN      lda   WANT_D
            beq   :ckoutu
            jsr   ISDUP
            bcc   :rt                ;len==1 -- -d wants dups
            jmp   :doprint
:ckoutu     lda   WANT_U
            beq   :doprint           ;neither flag: always print
            jsr   ISDUP
            bcs   :rt                ;len>1 -- -u wants uniques
:doprint    lda   WANT_C
            beq   :noc
            jsr   PRCNT
:noc        lda   #<PREVBUF
            sta   PTR0
            lda   #>PREVBUF
            sta   PTR0+1
            ldx   OUTFD
            jsr   PUTS
            lda   #$8D
            ldx   OUTFD
            jsr   PUTC
:rt         rts

*---------------------------------------------------------------
* PRCNT -- print RUNCNT right-aligned in a CNTFLD-wide field,
* then one separator space, to OUTFD. See header for why this
* is not liba's PRNUM (no CNTFLD-width padding there).
*---------------------------------------------------------------
PRCNT       lda   RUNCNT
            sta   U2DEC_VAL
            lda   RUNCNT+1
            sta   U2DEC_VAL+1
            lda   #<CNTBUF
            sta   PTR1
            lda   #>CNTBUF
            sta   PTR1+1
            jsr   U2DEC              ;A = digit count
            sta   CNTLEN
            lda   #CNTFLD
            sec
            sbc   CNTLEN
            bcc   :nopad             ;count wider than the field
            beq   :nopad
            sta   PADCNT
:padlp      lda   #$A0               ;space, high-bit-set
            ldx   OUTFD
            jsr   PUTC
            dec   PADCNT
            bne   :padlp
:nopad      lda   #<CNTBUF
            sta   PTR0
            lda   #>CNTBUF
            sta   PTR0+1
            ldx   OUTFD
            jsr   PUTS
            lda   #$A0               ;separator space
            ldx   OUTFD
            jsr   PUTC
            rts
