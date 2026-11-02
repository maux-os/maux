*---------------------------------------------------------------
* xargstok.s -- xargs's stdin tokenizer, -I line reader and
* replstr substitution. `put` out of xargs.s for the native
* assembler's source window (same reason as cut.s/cutlist.s).
*
* TOKREAD (with -0: one NUL-terminated item per call, every
* other byte literal -- no blanks, newlines, quotes or
* backslash) -- one whitespace/quote-aware argument per call,
* the XCU rule: unquoted <blank>/<newline> delimit, adjacent
* delimiters collapse to one, '...' and "..." protect
* delimiters (not the matching quote itself, not a bare
* newline), and an UNQUOTED backslash escapes the very next
* byte literally (including a newline -- it does NOT end the
* token). A quote left open at EOF is a hard error (unmatched
* quote), matching real xargs. Bytes past TOKBUF truncate the
* same way grep.s's GETLINE truncates -- this machine's per-
* argument practical cap, NOT the kernel's (docs/LIMITS.md: no
* per-arg cap exists at the spawn() layer, only ARG_MAX as a
* whole).
*
* NEXTLINE -- one -I mode "line" (leading blanks stripped,
* blank lines skipped, no quote processing -- POSIX -I disables
* blank/quote splitting, the whole line is one string).
*
* SUBST_ONE -- copy a template word into REPLBUF, replacing
* every occurrence of REPLPTR's text with XA_LINE's text.
*---------------------------------------------------------------

*---------------------------------------------------------------
* GETBYTE/REFILL -- one byte from stdin, buffered through CBUF.
* Lifted verbatim (shape) from grep.s's own GETBYTE/REFILL --
* fixed to FD_STDIN, xargs never reads a named file.
*---------------------------------------------------------------
GETBYTE     ldx   BUFPOS
            cpx   BUFLEN
            bcc   :have
            jsr   REFILL
            bcs   :eof
            ldx   BUFPOS
:have       lda   CBUF,x
            inc   BUFPOS
            clc
            rts
:eof        sec
            rts

REFILL      lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :eof
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :eof
            lda   RPARM_TRANS
            sta   BUFLEN
            stz   BUFPOS
            clc
            rts
:eof        sec
            rts

*---------------------------------------------------------------
* TOKREAD -- OUT: carry clear = PENDBUF/PENDLEN hold a token
* (NUL-terminated too); carry set = stdin exhausted, nothing
* pending. Exits the whole program on an unmatched quote.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
TOKREAD     stz   PENDLEN
            stz   XT_INQ
            stz   TOK_EOL
:loop       jsr   GETBYTE
            bcc   :gotb
            jmp   :hiteof
:gotb       ldy   ZFLAG            ;-0: only NUL ends
            beq   :std             ;an item
            cmp   #0
            bne   :emit
            jmp   :delim
:std        cmp   #$DC             ;backslash
            bne   :notbs
            ldy   XT_INQ
            bne   :bslit           ;literal inside a quote --
                                   ;emit the backslash ITSELF
            jsr   GETBYTE
            bcs   :bseof
            bra   :emit
:bslit      lda   #$DC
            bra   :emit
:bseof      jmp   :hiteof
:notbs      ldy   XT_INQ
            cpy   #2
            beq   :indq
            cpy   #1
            beq   :insq
            cmp   #$A7             ;'
            bne   :nsq
            lda   #1
            sta   XT_INQ
            jmp   :loop
:nsq        cmp   #$A2             ;"
            bne   :ndq
            lda   #2
            sta   XT_INQ
            jmp   :loop
:ndq        cmp   #$A0             ;space
            beq   :delim
            cmp   #$89             ;tab
            beq   :delim
*-- A NEWLINE IS STILL JUST A DELIMITER, but -L needs to know
*-- which delimiter ended a token, so record it. Only when it
*-- actually TERMINATES something: a newline seen with PENDLEN
*-- zero is part of a run between tokens, and the line it ended
*-- was counted by the token before it.
            cmp   #$8D             ;CR/newline
            bne   :emit
            ldy   PENDLEN
            beq   :delim
            lda   #1
            sta   TOK_EOL
            jmp   :finish
:delim      lda   PENDLEN
            beq   :loop
            jmp   :finish
:insq       cmp   #$A7
            bne   :emit
            stz   XT_INQ
            jmp   :loop
:indq       cmp   #$A2
            bne   :emit
            stz   XT_INQ
            jmp   :loop
:emit       ldy   PENDLEN
            cpy   #TOKBUF
            bcc   :store
            jmp   :loop
:store      sta   PENDBUF,y
            inc   PENDLEN
            jmp   :loop
:hiteof     lda   XT_INQ
            beq   :eofok
            lda   #<UNMQMSG
            sta   PTR0
            lda   #>UNMQMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT
:eofok      lda   PENDLEN
            bne   :finish
            sec
            rts
:finish     ldy   PENDLEN
            lda   #0
            sta   PENDBUF,y
            clc
            rts

*---------------------------------------------------------------
* FILLPEND -- ensure PENDVALID; OUT: carry clear = a token is
* ready in PENDBUF/PENDLEN, carry set = stdin exhausted.
*---------------------------------------------------------------
FILLPEND    lda   XA_ATEOF
            bne   :none                  ;-E already fired: the
            lda   PENDVALID              ;rest of stdin is not
            bne   :have                  ;read at all
            jsr   TOKREAD
            bcs   :none
*-- -E eofstr: a token EQUAL to the string ends the input here,
*-- and everything after it is ignored -- not skipped, ignored,
*-- which is why the latch above short-circuits every later
*-- call rather than just this one. Checked at FILLPEND because
*-- it is the single choke point every token passes through;
*-- putting it in TOKREAD would miss nothing today and would
*-- rot the day a second reader appears.
            lda   EFLAG
            beq   :keep
            jsr   XA_ISEOFS
            bcs   :keep
            lda   #1
            sta   XA_ATEOF
            bra   :none
:keep       lda   #1
            sta   PENDVALID
:have       clc
            rts
:none       stz   PENDVALID
            sec
            rts

*---------------------------------------------------------------
* XA_ISEOFS -- carry CLEAR if PENDBUF holds exactly -E's string.
* Both are NUL-terminated (TOKREAD terminates PENDBUF at
* :finish), so this is an ordinary string compare and the
* LENGTHS do not need comparing separately.
*---------------------------------------------------------------
XA_ISEOFS   ldy   #0
:eqlp       lda   (EOFPTR),y
            cmp   PENDBUF,y
            bne   :ne
            lda   PENDBUF,y
            beq   :eq                    ;both hit NUL together
            iny
            bne   :eqlp
:ne         sec
            rts
:eq         clc
            rts

*---------------------------------------------------------------
* NEXTLINE -- next nonblank -I line into LINEBUF (leading blanks
* stripped), LINELEN set. OUT: carry clear = a line is ready,
* carry set = EOF, no more lines. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
NEXTLINE    stz   LINELEN
:raw        jsr   GETBYTE
            bcs   :rawend
            cmp   LINEDELIM
            beq   :gotraw
            ldy   LINELEN
            cpy   #LMAX
            bcs   :raw
            sta   RAWLINE,y
            inc   LINELEN
            bra   :raw
:rawend     lda   LINELEN
            beq   :alldone
:gotraw     ldy   LINELEN
            lda   #0
            sta   RAWLINE,y
            jsr   STRIPLEAD
            lda   LINELEN
            bne   :haveln
            stz   LINELEN
            bra   :raw
:haveln     clc
            rts
:alldone    sec
            rts

*---------------------------------------------------------------
* STRIPLEAD -- RAWLINE -> LINEBUF, skipping leading space/tab.
* LINELEN updated to the stripped length. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
STRIPLEAD   ldx   #0
            lda   ZFLAG            ;-0: nothing is stripped
            bne   :done
:skp        lda   RAWLINE,x
            beq   :done
            cmp   #$A0
            beq   :adv
            cmp   #$89
            bne   :done
:adv        inx
            bra   :skp
:done       ldy   #0
:cpy        lda   RAWLINE,x
            sta   LINEBUF,y
            beq   :fin
            inx
            iny
            bra   :cpy
:fin        sty   LINELEN
            rts

*---------------------------------------------------------------
* PARSEDEC -- IN: PTR0 = digit string (liba). OUT: carry clear,
* PDVAL/PDVAL+1 = 16-bit value; carry set = empty or a non-digit
* seen. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PARSEDEC    stz   PDVAL
            stz   PDVAL+1
            stz   PDDIGN
            ldy   #0
:loop       lda   (PTR0),y
            beq   :end
            cmp   #$B0
            bcc   :bad
            cmp   #$BA
            bcs   :bad
            sec
            sbc   #$B0
            jsr   PD_ACCUM
            lda   #1
            sta   PDDIGN
            iny
            bra   :loop
:end        lda   PDDIGN
            beq   :bad
            clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* PD_ACCUM -- PDVAL := PDVAL*10 + A (A a 0-9 digit). Same shape
* as findexpr.s's PN_ACCUM. CLOBBERS: A.
*---------------------------------------------------------------
PD_ACCUM    pha
            lda   PDVAL
            sta   PDTMPLO
            lda   PDVAL+1
            sta   PDTMPHI
            asl   PDTMPLO
            rol   PDTMPHI
            lda   PDTMPLO
            sta   PDSAVLO
            lda   PDTMPHI
            sta   PDSAVHI
            asl   PDTMPLO
            rol   PDTMPHI
            asl   PDTMPLO
            rol   PDTMPHI
            clc
            lda   PDTMPLO
            adc   PDSAVLO
            sta   PDVAL
            lda   PDTMPHI
            adc   PDSAVHI
            adc   #0
            sta   PDVAL+1
            pla
            clc
            adc   PDVAL
            sta   PDVAL
            bcc   :nc
            inc   PDVAL+1
:nc         rts

