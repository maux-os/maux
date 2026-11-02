*---------------------------------------------------------------
* shrlog.s -- the logical-line reader's low half (SH-MLQUOTE,
* docs/SH-MLQUOTE.md, docs/SH-MLQUOTE-NOTES.md). `put` by sh.s
* into the LOW image right after shlex2.s: CODE only. The
* join and the refusal of an over-long line are shsgmlq.s, in
* the $E000 segment.
*
* POSIX and every Bourne shell since V7 read a LOGICAL line: a
* quote left open at the end of a physical line continues onto
* the next (the newline becomes part of the word), and a
* backslash-newline outside single quotes is removed.
*
* READLINE (shlex2.s) reads one PHYSICAL line (RL_PHYS) and
* falls in here only when that line holds a quote byte or a
* backslash. Every other line is complete by inspection and
* pays one scan.
*
* THE COMPLETENESS TEST IS TOKENIZE ITSELF, run on a copy:
* LINEBUF is copied to RAWLINE, STRIPCOMMENT and TOKENIZE run
* on it, the verdict is read off TOK_ERR (1: the line ends
* inside '..' or "..") and the last token (a lone `\` is kept
* as $DC: a trailing backslash), and LINEBUF is restored byte
* for byte. The brief allows "call TOKENIZE's own classifier"
* in place of factoring its predicates; this is the strongest
* form. Every context that changes quote meaning ($( ) and ( )
* spans, ${..}, case patterns, glued segments, the quoted-
* assignment and here-doc operator exceptions, comments)
* behaves in the lexer exactly as in the tokenizer, because
* they are one routine. RAWLINE is dead until SH_RUNLINE's own
* copy, and TOKENIZE zeroes every cell it reads at its entry.
*
* The accumulated text lives in HDLINEBUF (the here-doc
* reader's scratch: nothing reads a here-doc body while a line
* is being read). A continued newline is stored as the bit-7-
* CLEAR $0D, the SH-NLVAR encoding: READLINE does not end a
* line on it, no metacharacter test matches it, and UNESC
* restores $8D as the word leaves the parser
* (learning 01M12T7GJFN3QA43YJQRRVRAKN).
*---------------------------------------------------------------

*---------------------------------------------------------------
* RL_LOGICAL -- IN: LINEBUF/LINELEN = the first physical line,
* which holds a quote byte or a backslash, or RL_OVER is set.
* OUT: as READLINE, carry clear: LINEBUF/LINELEN = the logical
* line, or an empty line when the line was refused or
* abandoned. (A true EOF on the FIRST line was READLINE's.)
* CLOBBERS: A, X, Y, PTR0, PTR1 and what TOKENIZE clobbers.
*---------------------------------------------------------------
RL_LOGICAL  stz   RL_ACCN
            stz   RL_CONT
            lda   RL_OVER
            bne   :toolong
*-- No newline after the line (EOF) joins nothing: TOKENIZE
*-- keeps a lone `\` and says `unterminated quote` itself.
:top        lda   RL_NOCR
            bne   :done
            jsr   RL_CLASSIFY
            beq   :done                  ;complete
            cmp   #1
            beq   :go
*-- No room even to say it continues: LINEBUF holds it all.
            stz   RL_ACCN
            bra   :toolong
*-- Stash LINEBUF[0..LINELEN), then read the next physical line.
:go         ldy   #0
:st         cpy   LINELEN
            beq   :std
            lda   LINEBUF,y
            sta   HDLINEBUF,y
            iny
            bne   :st
:std        sty   RL_ACCN
            jsr   RL_PREREAD
            jsr   RL_PHYS
            bcs   :eof
*-- ^C (or a trapped signal) at the `> ` prompt abandons it all.
            lda   RL_ED
            beq   :nint
            lda   ED_INTR
            bne   :abandon
:nint       lda   RL_OVER
            bne   :toolong
            jsr   RL_JOIN
            bcc   :top
:toolong    jsr   RL_REFUSE
            jmp   RL_EMPTY
*-- EOF inside the join: hand over what we hold and let the
*-- pipeline say what is wrong with it (an unterminated quote,
*-- or a joined line that simply runs). Not a complete line:
*-- no history.
*-- A console ^D echoes nothing: end the `> ` row first, as
*-- the shell's own EOF does (shlex.s :realeof).
:eof        lda   SH_INTERACT
            beq   :eofj
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
:eofj       stz   LINEBUF                ;LINELEN is 0: joining
            jsr   RL_JOIN                ;nothing gives back
            stz   RL_ED                  ;what we hold
:done       jmp   RL_FINISH
*-- 128 + signo: ^C is 130.
:abandon    lda   ED_INTR
            ora   #$80
            sta   LASTSTATUS

*-- RL_EMPTY: the line is gone (refused or abandoned). LINEBUF
*-- is an empty line, which runs nothing and keeps `$?`.
RL_EMPTY    stz   LINEBUF
            stz   LINELEN
            stz   RL_ED
*-- RL_FINISH: every way out. The loop head is the FIRST
*-- physical line's start (RL_HMARK), then READLINE's own tail.
RL_FINISH   lda   RL_CONT
            beq   :out
            ldx   #2
:rm         lda   RL_HMARK,x
            sta   LINE_MARK,x
            dex
            bpl   :rm
:out        jmp   RL_DONE

*---------------------------------------------------------------
* RL_PREREAD -- before each continuation physical line: save the
* FIRST line's mark once (the loop rewind needs it), take a
* fresh mark so the seekable fast path seeks from THIS line's
* start, and show PS2. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
RL_PREREAD  lda   RL_CONT
            bne   :saved
            inc   RL_CONT
            ldx   #2
:sv         lda   LINE_MARK,x
            sta   RL_HMARK,x
            dex
            bpl   :sv
:saved      jsr   RL_PS2
            jmp   CAP_LINE_MARK

*---------------------------------------------------------------
* RL_PS2 -- `> ` on stderr, only on an interactive console that
* is reading its own keyboard (not a script, a pipe, a sourced
* file or a spooled loop). ED_PCH is what ^L redraws and what
* TC_TAB refuses (a `>` line completes nothing).
* CLOBBERS: A, X.
*---------------------------------------------------------------
RL_PS2      lda   SH_INTERACT
            beq   :out
            lda   SRC_DEPTH
            bne   :out
            lda   #OPC_GT
            sta   ED_PCH
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #ALC_A0
            ldx   #FD_STDERR
            jmp   PUTC
:out        rts

*---------------------------------------------------------------
* RL_CLASSIFY -- is LINEBUF a complete logical line? OUT: A = 0
* complete (LINEBUF unchanged); 1 it continues, and LINEBUF and
* LINELEN now end where the join resumes (a `$0D` after an open
* quote, or the continuing backslash dropped); 3 it continues
* but there is no room to say so (LINELEN is LINEMAX). Z is set
* iff A = 0. CLOBBERS: A, X, Y, PTR0, PTR1.
*
* Verdict: TOKENIZE says the line ends inside a quote (TOK_ERR
* 1): the newline is data, `$0D`. Else, or inside "..", an ODD
* run of backslashes at the end of the comment-stripped text
* escapes the newline: the last one is dropped and nothing is
* added (an even run pairs off; inside '..' a backslash is
* data). Any other TOKENIZE error (mixed, too many, bad fd)
* is complete: the pipeline reports it as before.
*---------------------------------------------------------------
*-- LINELEN is saved: STRIPCOMMENT rewrites it.
RL_CLASSIFY lda   LINELEN
            pha
            lda   #<RAWLINE
            ldx   #>RAWLINE
            jsr   LB_COPY                ;PTR0 = LINEBUF,
                                         ;PTR1 = RAWLINE
            jsr   STRIPCOMMENT
            ldy   LINELEN                ;trailing backslash run
            ldx   #0
:bs         dey
            cpy   #$FF
            beq   :bsd
            lda   LINEBUF,y
            cmp   #ALC_DC
            bne   :bsd
            txa
            eor   #1
            tax
            bra   :bs
:bsd        stx   RL_ODD
            jsr   TOKENIZE
            stz   RL_KIND
            lda   TOK_ERR
            beq   :noerr
            cmp   #1
            beq   :inq
*-- `V='a` and `<<'E` report `mixed` when the quote is left
*-- open (TOK_UNQ, shtok.s): that is an open quote too.
            cmp   #2
            bne   :rest
            lda   TOK_UNQ
            beq   :rest
:inq        lda   #1                     ;inside a quote: `$0D`
            sta   RL_KIND
            lda   QCH
            cmp   #ALC_A2
            bne   :rest                  ;'..': data
:noerr      lda   RL_ODD
            beq   :rest
            lda   #2
            sta   RL_KIND
*-- Restore LINEBUF, then apply the verdict.
:rest       lda   #<RAWLINE
            sta   PTR0
            lda   #>RAWLINE
            sta   PTR0+1
            lda   #<LINEBUF
            sta   PTR1
            lda   #>LINEBUF
            sta   PTR1+1
            jsr   STRCPY
            pla
            sta   LINELEN
            lda   RL_KIND
            beq   :ret
            cmp   #2
            beq   :bsl
            ldy   LINELEN                ;1: `$0D` added
            cpy   #LINEMAX
            bne   :nl
            lda   #3
            rts
:nl         lda   #$0D
            sta   LINEBUF,y
            iny
            sty   LINELEN
            lda   #1
            rts
:bsl        dec   LINELEN                ;2: the backslash goes
            ldy   LINELEN
            lda   #0
            sta   LINEBUF,y
            lda   #1
:ret        rts
