*---------------------------------------------------------------
* shsgmlq.s -- the logical-line reader's coldest half
* (SH-MLQUOTE, docs/SH-MLQUOTE.md, docs/SH-MLQUOTE-NOTES.md):
* the join, and the refusal of an over-long line. `put` by
* sh.s into the $E000 segment: CODE only, run by the CPU. Every
* buffer a syscall sees is in the arena and the one message is
* in the low image (TOOLONG_MSG, shpath.s). The rest of the
* reader is shrlog.s.
*
* An over-long line is REFUSED whole (`sh: line too long`,
* status 1), never run truncated, and the reader resynchronises
* where the LOGICAL command ends: a small byte scanner (RL_DSB)
* carries the quote, backslash, comment and `$( )`/`( )` span
* state through the bytes that cannot be kept. It calls
* TOKENIZE's own span tracker (SUB_TRKCH), so a quote inside an
* open span is content there exactly as it is in TOKENIZE
* (docs/SH-MLQUOTE-NOTES.md sec 6).
*---------------------------------------------------------------

*---------------------------------------------------------------
* RL_JOIN -- LINEBUF = the new physical line (LINELEN bytes),
* HDLINEBUF = RL_ACCN bytes already held. OUT: carry clear,
* LINEBUF = held ++ new; carry set: the logical line would pass
* LINEMAX (LINEBUF untouched). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
RL_JOIN     clc
            lda   RL_ACCN
            adc   LINELEN
            bcs   :big
            sta   RL_NEWN
            tax                          ;X = new NUL index
            ldy   LINELEN
:mv         lda   LINEBUF,y              ;shift up, NUL included
            sta   LINEBUF,x
            dex
            dey
            cpy   #$FF
            bne   :mv
            ldy   #0
:cp         cpy   RL_ACCN
            beq   :cpd
            lda   HDLINEBUF,y
            sta   LINEBUF,y
            iny
            bne   :cp
:cpd        lda   RL_NEWN
            sta   LINELEN
            clc
            rts
:big        sec
            rts

*---------------------------------------------------------------
* RL_REFUSE -- `sh: line too long`, status 1, and resynchronise:
* the bytes held (HDLINEBUF), the line in LINEBUF (its 256th
* byte in RL_X256 when RL_OVER) and every further physical line
* the logical command still spans go through RL_DSB until it
* ends. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
RL_REFUSE   lda   #<TOOLONG_MSG
            ldx   #>TOOLONG_MSG
            jsr   PR_ERRAX1
            stz   RL_DSQ
            stz   RL_DSE
            stz   RL_DSC
            stz   SUBDEPTH
            stz   SUBPRVD
            lda   #1
            sta   RL_DSW
            sta   RL_DSX
            ldy   #0
:acc        cpy   RL_ACCN
            beq   :line
            lda   HDLINEBUF,y
            phy
            jsr   RL_DSB
            ply
            iny
            bne   :acc
:line       ldy   #0
:ln         cpy   LINELEN
            beq   :lnd
            lda   LINEBUF,y
            phy
            jsr   RL_DSB
            ply
            iny
            bne   :ln
:lnd        lda   RL_OVER
            beq   :eol
            lda   RL_X256                ;the byte past the cap,
            jsr   RL_DSB                 ;then the rest
:drain      ldx   CUR_IN_FD
            jsr   GETC
            bcs   :done                  ;EOF
            cmp   #$8D
            beq   :eol
            jsr   RL_DSB
            bra   :drain
*-- The physical line ended. A newline inside a quote, or after
*-- a backslash, continues the logical line; else it is over.
:eol        stz   RL_DSC                 ;a comment ends here
            lda   RL_DSQ
            bne   :more
            lda   RL_DSE
            beq   :done
            stz   RL_DSE                 ;bs-newline joins:
            stz   RL_DSW                 ;the word goes on
:more       lda   RL_NOCR
            bne   :done
            jsr   RL_PREREAD
            stz   RL_ACCN                ;(already scanned)
            jsr   RL_PHYS
            bcs   :done
            lda   RL_ED
            beq   :nint
            lda   ED_INTR
            bne   :done
:nint       jmp   :line
:done       rts

*---------------------------------------------------------------
* RL_DSB -- one byte (A) through the refusal scanner: the quote,
* backslash, comment and SPAN rules of STRIPCOMMENT and
* TOKENIZE. A quote or a blank inside an open `$( )` span, or a
* group `( )` (a `(` that starts the first token or follows
* `;`), is content: TOKENIZE's own SUBDEPTH/SUBPRVD tracker
* (SUB_TRKCH) is called for every byte it applies to, so the
* two agree by construction. State: RL_DSQ (0 bare, else the
* open quote), RL_DSE (the next byte is escaped), RL_DSW (a word
* may start: a `#` or a group `(` here counts), RL_DSX (command
* position: line start or just after `;`), RL_DSC (in a
* comment). CLOBBERS: A, X.
*---------------------------------------------------------------
RL_DSB      ldx   RL_DSC
            beq   :c1
            rts                          ;a comment: skip
:c1         ldx   RL_DSE
            beq   :noesc
            stz   RL_DSE                 ;the escaped byte
            stz   RL_DSW
            rts
:noesc      ldx   RL_DSQ
            bne   :inq
            cmp   #ALC_DC
            beq   :esc
            ldx   SUBDEPTH
            bne   :span                  ;inside a span: content
            cmp   #ALC_A7
            beq   :open
            cmp   #ALC_A2
            beq   :open
            cmp   #ALC_A0
            beq   :blank
            cmp   #TCC_HASH
            bne   :word
            ldx   RL_DSW
            beq   :word
            inc   RL_DSC                 ;a comment starts
            rts
:blank      stz   SUBPRVD
            lda   #1
            sta   RL_DSW
            rts
:word       ldx   RL_DSX                 ;command position?
            stz   RL_DSX
            cmp   #OPC_SEMI
            bne   :wn
            inc   RL_DSX                 ;after `;`: yes
:wn         cmp   #ALC_A8                ;`(` at a word start in
            bne   :wt                    ;command position opens
            cpx   #0                     ;a group span
            beq   :wt
            ldx   RL_DSW
            beq   :wt
            ldx   #1
            stx   SUBPRVD
:wt         stz   RL_DSW
            jmp   SUB_TRKCH
:span       stz   RL_DSW
            jmp   SUB_TRKCH
:esc        inc   RL_DSE
            stz   RL_DSW
            stz   RL_DSX
            stz   SUBPRVD
            rts
:open       sta   RL_DSQ
            stz   RL_DSW
            stz   RL_DSX
            rts
:inq        cmp   RL_DSQ
            bne   :inq2
            stz   RL_DSQ                 ;the closing quote
            rts
:inq2       cmp   #ALC_DC
            bne   :ret
            ldx   RL_DSQ
            cpx   #ALC_A2
            bne   :ret                   ;'..': data
            inc   RL_DSE
:ret        rts
