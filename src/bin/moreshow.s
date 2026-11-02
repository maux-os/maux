*---------------------------------------------------------------
* moreshow.s -- more's drawing (put by more.s). SHOWLINE streams
* one line from the table's offset through EMITCH -- the POSIX
* overstrike rules (X\bX bold, _\bX plain, other backspaces
* eat), escape sequences passed through at zero width, a
* column count that turns into the rows the line took on the
* glass (the console wraps EAGERLY: a line exactly COLS wide
* costs two rows, so rows = 1 + COL/COLS). FILLROWS/FILLLINES
* draw forward from BOT+1; REPAINT clears and draws a screenful
* from TOP. PROMPT/ERASEPROMPT own the last row.
*---------------------------------------------------------------

*-- CLEARSCR -- ESC [ 2 J, ESC [ H.
CLEARSCR    lda   #<CLRSEQ
            sta   PTR0
            lda   #>CLRSEQ
            sta   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS

*-- FILEHDR -- the BSD multi-file header: colons, name, colons.
FILEHDR     jsr   :colons
            lda   CURNAME
            sta   PTR0
            lda   CURNAME+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:colons     lda   #<COLONS
            sta   PTR0
            lda   #>COLONS
            sta   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS

*---------------------------------------------------------------
* FILLROWS -- A = rows: draw lines from BOT+1 until that many
* rows are used (a wrapped line may overshoot) or the file ends
* (ATEOF=1). BOT tracks the last line drawn.
*---------------------------------------------------------------
FILLROWS    sta   FROWS
            stz   FROWCNT
            stz   ATEOF
:fl         jsr   NEXTLN
            jsr   ENSURE
            bcs   :eof
            jsr   SHOWLINE
            clc
            adc   FROWCNT
            bcs   :over
            sta   FROWCNT
            jsr   BOTSET
            lda   FROWCNT
            cmp   FROWS
            bcc   :fl
            jmp   EOFPEEK
:over       jsr   BOTSET
            jmp   EOFPEEK
:eof        lda   #1
            sta   ATEOF
            rts

*-- EOFPEEK -- a fill that stopped ON the last line is at end of
*-- file too: the prompt should say so before the next command
*-- finds nothing (POSIX: the prompt marks the end when the last
*-- line is written).
EOFPEEK     jsr   NEXTLN
            jsr   ENSURE
            bcc   :more
            lda   #1
            sta   ATEOF
:more       rts

*-- FILLLINES -- MP_CNT lines from BOT+1, however many rows.
FILLLINES   stz   ATEOF
:fl         lda   MP_CNT
            ora   MP_CNT+1
            bne   :go
            jmp   EOFPEEK
:go
            jsr   NEXTLN
            jsr   ENSURE
            bcs   :eof
            jsr   SHOWLINE
            jsr   BOTSET
            lda   MP_CNT
            bne   :dl
            dec   MP_CNT+1
:dl         dec   MP_CNT
            bra   :fl
:eof        lda   #1
            sta   ATEOF
            rts

*-- NEXTLN -- MP_LN = BOT + 1.   BOTSET -- BOT = MP_LN.
NEXTLN      lda   BOT
            clc
            adc   #1
            sta   MP_LN
            lda   BOT+1
            adc   #0
            sta   MP_LN+1
            rts
BOTSET      lda   MP_LN
            sta   BOT
            lda   MP_LN+1
            sta   BOT+1
            rts

*-- REPAINT -- clear, then a screenful from TOP.
REPAINT     jsr   CLEARSCR
            stz   PREVBLANK
            lda   TOP
            sec
            sbc   #1
            sta   BOT
            lda   TOP+1
            sbc   #0
            sta   BOT+1
            lda   PAGEROWS
            jmp   FILLROWS

*---------------------------------------------------------------
* SHOWLINE -- draw line MP_LN. OUT: A = rows it took (0 when -s
* squeezed it away). MP_LN is preserved.
*---------------------------------------------------------------
SHOWLINE    jsr   GETOFF
            stz   MP_COL
            stz   MP_COL+1
            stz   PEND
            stz   PENDBOLD
            stz   BSCNT
            stz   BOLDON
            stz   ESCST
            jsr   READ_AT                ;X = the line's index
            bcc   :have
            lda   #0
            rts
:have       lda   OPT_S
            beq   :b
            lda   IOBUF,x
            cmp   #$8D
            beq   :sqnl
            cmp   #$0D
            bne   :b
:sqnl       lda   PREVBLANK
            beq   :b
            lda   #0                     ;a second blank: gone
            rts
:b          lda   IOBUF,x
            cmp   #$8D
            beq   :eol
            ;-- low-ASCII text ends its lines in $0D
            ;-- (a2til, NuFX), so accept that too
            cmp   #$0D
            beq   :eol
            phx
            jsr   EMITCH
            plx
            inx
            cpx   MP_NRD
            bne   :b
            jsr   OFFADV
            jsr   READ_AT                ;X = 0: a fresh chunk
            bcs   :eol
            bra   :b
:eol        jsr   FLUSHPEND
            lda   BOLDON
            beq   :nob
            jsr   SGROFF
:nob        lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   FLUSHPAR               ;a write every SECOND
            lda   FLUSHPAR               ;line (operator): the
            and   #1                     ;512 B stage is half a
            bne   :nofl                  ;page, so a page came
            ldx   #FD_STDOUT             ;as two bursts with a
            jsr   SIO_FLUSH              ;read+format gap ahead
                                          ;each: a stutter; per
                                          ;line was free but
                                          ;busier than it needs.
                                          ;PROMPT/RAWKEY flush
                                          ;an odd last line.
:nofl
            lda   MP_COL
            ora   MP_COL+1
            bne   :notblank
            lda   #1
            sta   PREVBLANK
            rts                          ;A = 1 row
:notblank   stz   PREVBLANK
            lda   #1
            sta   MP_TMP
:div        lda   MP_COL
            cmp   COLS
            lda   MP_COL+1
            sbc   #0
            bcc   :ddone
            lda   MP_COL
            sec
            sbc   COLS
            sta   MP_COL
            bcs   :nb
            dec   MP_COL+1
:nb         inc   MP_TMP
            bne   :div
            dec   MP_TMP                 ;255 rows: clamp
:ddone      lda   MP_TMP
            rts

*---------------------------------------------------------------
* EMITCH -- one byte of a line. Escape sequences pass straight
* through (ESC x, or ESC [ ... final). A backspace after a held
* character starts an overstrike: the next byte decides --
* the same character = bold, `_` under a character = that
* character plain, anything else = the later character. Plain
* bytes are HELD one deep (PEND) so the backspace can be seen.
*---------------------------------------------------------------
EMITCH      ldy   ESCST
            bne   :inesc
            cmp   #$9B
            bne   :notesc
            jsr   FLUSHPEND
            lda   #1
            sta   ESCST
            lda   #$9B
            bra   :raw
:inesc      cpy   #1
            bne   :csi
            cmp   #$DB                   ;ESC [ : a CSI follows
            bne   :escend
            ldy   #2
            sty   ESCST
            stz   ESCN
            bra   :raw
:csi        cmp   #$C0                   ;a final byte @..~ ends
            bcs   :final
            sta   ESCPAR                 ;a parameter byte
            inc   ESCN
            bra   :raw
:final      cmp   #$ED                   ;ESC [ 1 m or ESC [ 7 m
            bne   :escend                ;in the text: emphasis
            ldy   ESCN                   ;-> the card shows it
            cpy   #1                     ;bright (HLSWITCH,
            bne   :escend                ;AFTER the m goes out,
            ldy   ESCPAR                 ;never inside a CSI).
            cpy   #"1"                   ;A page opens with a
            beq   :arm                   ;heading, which is the
            cpy   #"7"                   ;7, so arm on either or
            bne   :escend                ;the card stays inverse
:arm        stz   ESCST                  ;for the first screen
            ldx   #FD_STDOUT
            jsr   PUTC
            jmp   HLSWITCH
:escend     stz   ESCST
:raw        ldx   #FD_STDOUT
            jmp   PUTC
:notesc     cmp   #$88
            bne   :notbs
            lda   OPT_U                  ;-u: a backspace is a
            bne   :rawu                  ;byte for the console
            lda   PEND
            beq   :out                   ;nothing to strike over
            inc   BSCNT
:out        rts
:rawu       lda   #$88
            bra   :raw
:notbs      ldy   BSCNT
            beq   :plainch
            stz   BSCNT
            cmp   PEND
            bne   :notsame
            lda   #1                     ;X\bX -> bold X
            sta   PENDBOLD
            rts
:notsame    ldy   PEND
            cpy   #"_"
            beq   :repl                  ;_\bX -> X
            cmp   #"_"
            beq   :keep                  ;X\b_ -> X
:repl       sta   PEND                   ;X\bY -> Y
            stz   PENDBOLD
:keep       rts
:plainch    pha
            jsr   FLUSHPEND
            pla
            sta   PEND
            stz   PENDBOLD
            rts

*-- FLUSHPEND -- emit the held character with its emphasis,
*-- counting its columns (a tab to the next multiple of 8).
FLUSHPEND   lda   PEND
            beq   :r
            lda   PENDBOLD
            beq   :nobold
            lda   BOLDON
            bne   :emit
            jsr   SGRON
            bra   :emit
:nobold     lda   BOLDON
            beq   :emit
            jsr   SGROFF
:emit       lda   PEND
            stz   PEND
            stz   PENDBOLD
            pha
            cmp   #$89
            beq   :tab
            cmp   #$A0
            bcc   :done                  ;a control: no column
            inc   MP_COL
            bne   :done
            inc   MP_COL+1
            bra   :done
:tab        lda   MP_COL
            ora   #7
            clc
            adc   #1
            sta   MP_COL
            bcc   :done
            inc   MP_COL+1
:done       pla
            ldx   #FD_STDOUT
            jmp   PUTC
:r          rts

*---------------------------------------------------------------
* SGRON -- start an emphasised run. A run that starts the line
* is a section heading (nroff bolds NAME, SYNOPSIS... from
* column 0): ask for INVERSE, which every console can show.
* Anything else is a word inside a sentence -- ask only for
* BRIGHTNESS (SGR 1), which the UltraTerm gives and the //e
* text page drops. On a //e that leaves headings standing out
* and paragraphs clean, instead of a ragged column of inverse
* blocks mid-line; TTY_SGR_CLASS (kernel tty2.s) is what drops
* it.
*---------------------------------------------------------------
SGRON       jsr   HLSWITCH
            lda   #1
            sta   BOLDON
            lda   MP_COL
            ora   MP_COL+1
            bne   :inline
            lda   #<SGR7SEQ
            ldx   #>SGR7SEQ
            jmp   PUTSP
:inline     lda   #<BOLDSEQ
            ldx   #>BOLDSEQ
            jmp   PUTSP

*---------------------------------------------------------------
* HLSWITCH -- the first bold on a console: switch its emphasis
* to HIGHLIGHT (ESC [ ? 3001 h, docs/CONSOLE.md) so the
* UltraTerm shows bold bright, not inverse; the //e backends
* ignore it. HLRESTORE puts inverse back at exit -- a pager
* leaves the terminal as it found it.
*---------------------------------------------------------------
HLSWITCH    lda   HLSW
            bne   :r
            inc   HLSW
            lda   #<HLONSEQ
            ldx   #>HLONSEQ
            jmp   PUTSP
:r          rts
HLRESTORE   lda   HLSW
            beq   :r
            stz   HLSW
            lda   #<HLOFFSEQ
            ldx   #>HLOFFSEQ
            jmp   PUTSP
:r          rts
SGROFF      lda   #<SGR0SEQ
            sta   PTR0
            lda   #>SGR0SEQ
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            stz   BOLDON
            rts

*---------------------------------------------------------------
* PROMPT -- flush the page, then `--More--` with `(NN%)`,
* `(END)` or `(Next file: name)` after it. PLEN counts the
* characters for ERASEPROMPT. Plain, not standout: the //e text
* page has no inverse lowercase (docs/CONSOLE.md), and the
* prompt row is cue enough.
*---------------------------------------------------------------
PROMPT      ldx   #FD_STDOUT
            jsr   SIO_FLUSH
            stz   PLEN
            lda   #<MOREMSG
            ldx   #>MOREMSG
            jsr   PUTSPL
            lda   ATEOF
            beq   :pct
            lda   ISLAST
            beq   :next
            lda   #<ENDMSG
            ldx   #>ENDMSG
            jsr   PUTSPL
            bra   :fin
:next       lda   #<NEXTMSG
            ldx   #>NEXTMSG
            jsr   PUTSPL
            lda   CURIDX
            clc
            adc   #1
            jsr   GETARG
            lda   PTR0
            ldx   PTR0+1
            jsr   PUTSPL
            lda   #<CLOSEP
            ldx   #>CLOSEP
            jsr   PUTSPL
            bra   :fin
:pct        lda   SIZEKNOWN
            beq   :fin
            jsr   NEXTOFF
            jsr   PCT
            jsr   PUTPCT
:fin        ldx   #FD_STDOUT
            jmp   SIO_FLUSH

*-- PUTPCT -- "(NN%)" for A, counted into PLEN.
PUTPCT      pha
            lda   #<OPENP
            ldx   #>OPENP
            jsr   PUTSPL
            pla
            jsr   PUTDEC8
            lda   #<PCTMSG
            ldx   #>PCTMSG
            jmp   PUTSPL

*-- PUTDEC8 -- A (0..255) in decimal to stdout, PLEN counted.
PUTDEC8     sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            ldx   #1
            cmp   #10
            bcc   :len
            inx
            cmp   #100
            bcc   :len
            inx
:len        txa
            clc
            adc   PLEN
            sta   PLEN
            ldx   #FD_STDOUT
            jmp   PRNUM

*-- PUTSP -- the string at A/X to stdout (escapes: not counted).
*-- PUTSPL -- the same, its length added to PLEN.
PUTSP       sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS
PUTSPL      sta   PTR0
            stx   PTR0+1
            jsr   STRLEN
            clc
            adc   PLEN
            sta   PLEN
            ldx   #FD_STDOUT
            jmp   PUTS

*-- ERASEPROMPT -- back over the prompt and clear the row.
ERASEPROMPT ldx   PLEN
            beq   :clr
:bs         phx
            lda   #$88
            ldx   #FD_STDOUT
            jsr   PUTC
            plx
            dex
            bne   :bs
:clr        stz   PLEN
            lda   #<CEOLSEQ
            ldx   #>CEOLSEQ
            jmp   PUTSP

*-- MSG -- a message (A/X) on the prompt row, which is clear
*-- when this is called. It STANDS IN for the next prompt
*-- (MSGUP): the next key erases it, PLEN says how much.
MSG         jsr   PUTSPL
            lda   #1
            sta   MSGUP
            rts

*---------------------------------------------------------------
* INFO -- `=`: name, line, (file i of n), percentage.
*---------------------------------------------------------------
INFO        stz   PLEN
            lda   CURNAME
            ldx   CURNAME+1
            jsr   PUTSPL
            lda   #<LINEMSG
            ldx   #>LINEMSG
            jsr   PUTSPL
            lda   TOP
            clc
            adc   #1
            sta   U2DEC_VAL
            lda   TOP+1
            adc   #0
            sta   U2DEC_VAL+1
            jsr   PUTDEC16
            lda   NFILES
            cmp   #2
            bcc   :nofiles
            lda   #<FILEMSG
            ldx   #>FILEMSG
            jsr   PUTSPL
            lda   CURIDX
            sec
            sbc   OPTIND
            clc
            adc   #1
            jsr   PUTDEC8
            lda   #<OFMSG
            ldx   #>OFMSG
            jsr   PUTSPL
            lda   NFILES
            jsr   PUTDEC8
            lda   #<CLOSEP
            ldx   #>CLOSEP
            jsr   PUTSPL
:nofiles    lda   SIZEKNOWN
            beq   :done
            lda   #<SPACEMSG
            ldx   #>SPACEMSG
            jsr   PUTSPL
            jsr   NEXTOFF
            jsr   PCT
            jsr   PUTDEC8
            lda   #<PCTSIGN
            ldx   #>PCTSIGN
            jsr   PUTSPL
:done       lda   #1
            sta   MSGUP
            rts

*-- PUTDEC16 -- U2DEC_VAL in decimal, PLEN counted.
PUTDEC16    lda   #<PRNBUF
            sta   PTR1
            lda   #>PRNBUF
            sta   PTR1+1
            jsr   U2DEC                  ;A = the digit count
            clc
            adc   PLEN
            sta   PLEN
            lda   #<PRNBUF
            ldx   #>PRNBUF
            jmp   PUTSP

*---------------------------------------------------------------
* HELP -- the command summary on a cleared screen, then wait
* for a key and redraw the page.
*---------------------------------------------------------------
HELP        jsr   CLEARSCR
            lda   #<HELPTXT
            ldx   #>HELPTXT
            jsr   PUTSP
            lda   #<HELPTXT2
            ldx   #>HELPTXT2
            jsr   PUTSP
            lda   #<ANYKEY
            ldx   #>ANYKEY
            jsr   PUTSP
            jsr   RAWKEY
            jmp   REPAINT

CLRSEQ      dfb   $9B,$DB,$B2,$CA        ;ESC [ 2 J
            dfb   $9B,$DB,$C8,0          ;ESC [ H
CEOLSEQ     dfb   $9B,$DB,$CB,0          ;ESC [ K
SGR7SEQ     dfb   $9B,$DB,$B7,$ED,0      ;ESC [ 7 m
BOLDSEQ     dfb   $9B,$DB,$B1,$ED,0      ;ESC [ 1 m
SGR0SEQ     dfb   $9B,$DB,$B0,$ED,0      ;ESC [ 0 m
HLONSEQ     dfb   $9B,$DB,$BF,$B3,$B0,$B0,$B1,$E8,0
HLOFFSEQ    dfb   $9B,$DB,$BF,$B3,$B0,$B0,$B1,$EC,0
COLONS      asc   "::::::::::::::"
            dfb   $8D,0
MOREMSG     asc   "--More--"
            dfb   0
ENDMSG      asc   "(END)"
            dfb   0
NEXTMSG     asc   "(Next file: "
            dfb   0
OPENP       asc   "("
            dfb   0
CLOSEP      asc   ")"
            dfb   0
PCTMSG      asc   "%)"
            dfb   0
PCTSIGN     asc   "%"
            dfb   0
SPACEMSG    asc   " "
            dfb   0
LINEMSG     asc   " line "
            dfb   0
FILEMSG     asc   " (file "
            dfb   0
OFMSG       asc   " of "
            dfb   0
ANYKEY      asc   "[Press any key to continue]"
            dfb   0
HELPTXT     asc   "A count may precede a command (default 1)"
            dfb   $8D
            asc   "  SPACE f ^F  forward a screen (count lines)"
            dfb   $8D
            asc   "  RETURN j    forward a line  k  back a line"
            dfb   $8D
            asc   "  d ^D        forward half    u ^U back half"
            dfb   $8D
            asc   "  b ^B        back a screen   s   skip lines"
            dfb   $8D
            asc   "  g  G        go to line / end"
            dfb   $8D
            asc   "  /pat ?pat   search fwd / back (!pat: not)"
            dfb   $8D,0
HELPTXT2    asc   "  n  N        repeat, same / other way"
            dfb   $8D
            asc   "  m<a-z> '<a-z> mark / go to mark; '' back"
            dfb   $8D
            asc   "  :n  :p      next / previous file  :e file"
            dfb   $8D
            asc   "  =           where am I    v   edit in vi"
            dfb   $8D
            asc   "  !cmd        shell command r ^L redraw"
            dfb   $8D
            asc   "  h           this list     q   quit"
            dfb   $8D,0
