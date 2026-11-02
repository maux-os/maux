*---------------------------------------------------------------
* sedio.s -- sed's stream reader, `put` by src/bin/sed.s after
* sedsel.s (NOT a standalone binary): the FILE operands as ONE
* stream, the windowed read buffer, zero-copy GETLINE and the
* '$' peek. Unchanged in shape by the POSIX uplift (docs/SED.md)
* except that the pattern space may now be OWNED by the PSOWN
* arena, which PEEKEOF's salvage leaves alone.
*---------------------------------------------------------------
*---------------------------------------------------------------
* STREAMINIT -- stdin, or the first FILE operand. FILE args
* are ONE stream (see header: '$' is the last line of the LAST
* file), opened lazily in order by NEXTFILE.
*---------------------------------------------------------------
STREAMINIT  stz   BUFPOS
            stz   BUFLEN
            stz   W_REM
            stz   W_REM+1
            lda   #<CBUF
            sta   CBPTR
            lda   #>CBUF
            sta   CBPTR+1
            lda   FIRSTFILE          ;operands start after the
            sta   ARGIDX             ;script (START decided)
            cmp   ARGC
            bcc   :files
            lda   #1
            sta   USESTDIN
            lda   #FD_STDIN
            sta   SRCFD
            rts
:files      jsr   NEXTFILE
            bcc   :ok
            lda   #1                 ;every FILE failed to open
            sta   STRMDEAD           ;-- the reports (and exit
:ok         rts                      ;2) are already staged

*---------------------------------------------------------------
* NEXTFILE -- open the next FILE operand into SRCFD. An open
* failure is reported ("sed: cannot open <name>"), forces exit
* status 2, and the NEXT operand is tried -- grep.s's own
* convention. OUT: carry set = no operand left.
*---------------------------------------------------------------
NEXTFILE
:lp         lda   ARGIDX
            cmp   ARGC
            bcc   :have
            sec
            rts
:have       lda   ARGIDX
            inc   ARGIDX
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :operr
            lda   OPARM_REF
            sta   SRCFD
            stz   BUFPOS
            stz   BUFLEN
            stz   W_REM
            stz   W_REM+1
            clc
            rts
:operr      lda   #<OPENMSG
            sta   PTR0
            lda   #>OPENMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX             ;PUTS clobbered PTR0 --
            sec                      ;re-fetch the operand
            sbc   #1
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            sta   ERRFLAG
            bra   :lp

*---------------------------------------------------------------
* GETLINE -- next CR-terminated line of the stream into
* LINEBUF, NUL-terminated. carry clear = line; carry set = end
* of the whole stream. Final unterminated line IS returned;
* over-long lines truncate at LINEMAX, remainder discarded
* (grep.s's documented rule).
*---------------------------------------------------------------
*-- The buffer walk is INLINE (docs/PERF-PLAN.md step 4): the
*-- common byte never pays GETBYTE's jsr/dead-check/rts -- X
*-- mirrors BUFPOS, Y counts stored chars, and BUFPOS is written
*-- back only at a line end or before the slow path. GETBYTE
*-- remains the slow path and still owns REFILL, the file-to-
*-- file hop and STRMDEAD, so those semantics live in one place.
*-- LINELEN is GETLINE-private (grepped 2026-08-28) and is now
*-- written at the exits rather than per byte.
*-- ZERO-COPY fast path first (2026-08-28; the copying walk
*-- below measured 13% of the whole strip): a line whose CR
*-- lies inside the current window is served STRAIGHT OUT OF
*-- CBUF -- scan to the CR, overwrite it with the NUL the
*-- consumers expect (the bytes are consumed data; nothing
*-- rereads them), point LINEPTR at the line, copy nothing. A
*-- line of 254 bytes at most fits a 255-byte window, so this
*-- path can never need LINEMAX truncation. Lines that straddle
*-- a window (and EOF tails, and empty windows) fall to the
*-- assembling walk below, which builds into LINEBUF exactly as
*-- before -- rescanning the few bytes the failed scan touched.
GETLINE     ldy   BUFPOS
            cpy   BUFLEN
            bcs   :asm               ;window empty
:zscan      lda   (CBPTR),y
            cmp   #$8D
            beq   :zhit
            cmp   #$0D             ;either terminator ends a
            beq   :zhit          ;line -- a foreign file
            iny
            cpy   BUFLEN
            bne   :zscan
            bra   :asm               ;no CR in window: straddle
:zhit       lda   #0
            sta   (CBPTR),y          ;CR -> NUL, in place
            tya
            sec
            sbc   BUFPOS
            sta   LINELEN
            clc
            lda   CBPTR
            adc   BUFPOS
            sta   LINEPTR
            lda   CBPTR+1
            adc   #0
            sta   LINEPTR+1
            iny                      ;past the CR (y <= BUFLEN,
            sty   BUFPOS             ;no wrap: CR at 254 max)
            clc
            rts

*-- Register roles swapped for the WINDOWED stream (RDCHUNK/
*-- NEXTWIN, sed.s): Y walks the input through (CBPTR),y --
*-- indirect-indexed needs zero page and needs Y -- so X counts
*-- the stored chars and the LINEBUF store is abs,X.
:asm        ldx   #0
            ldy   BUFPOS
:fast       cpy   BUFLEN
            bcs   :slow              ;window exhausted
            lda   (CBPTR),y
            iny
:classify   cmp   #$8D
            beq   :have
            cmp   #$0D             ;either terminator ends a
            beq   :have          ;line -- a foreign file
            cpx   #LINEMAX
            bcs   :fast              ;overlong: drop remainder
                                     ;(grep.s's documented rule)
            sta   LINEBUF,x
            inx
            bra   :fast
:slow       sty   BUFPOS             ;commit consumption before
            phx                      ;the syscall path (GETBYTE
            jsr   GETBYTE            ;clobbers Y; SC_READ under
            plx                      ;REFILL clobbers X)
            bcs   :eof
            ldy   BUFPOS             ;NEXTWIN/REFILL moved it;
            bra   :classify          ;GETBYTE consumed byte A
:have       sty   BUFPOS
            stx   LINELEN
            lda   #0
            sta   LINEBUF,x
            bra   :asmptr
:eof        stx   LINELEN
            cpx   #0
            beq   :empty
            lda   #0
            sta   LINEBUF,x
:asmptr     lda   #<LINEBUF          ;assembled line: the
            sta   LINEPTR            ;pattern space is LINEBUF
            lda   #>LINEBUF
            sta   LINEPTR+1
            clc
            rts
:empty      sec
            rts

*---------------------------------------------------------------
* GETBYTE -- one byte of the concatenated stream, buffered
* through CBUF (grep.s's shape, plus the file-to-file hop).
*---------------------------------------------------------------
GETBYTE     jsr   ENSUREBYTE
            bcs   :dead
            ldy   BUFPOS
            lda   (CBPTR),y
            inc   BUFPOS
            clc
            rts
:dead       sec
            rts

*---------------------------------------------------------------
* ENSUREBYTE -- make sure at least one UNCONSUMED byte of the
* concatenated stream sits in CBUF, refilling (and hopping to
* the next FILE operand) exactly as GETBYTE always did, but
* consuming nothing. carry set = the stream is over. Split out
* of GETBYTE so PEEKEOF below can answer the '$' address
* question -- "is any byte left after this line?" -- without a
* lookahead LINE, a second line buffer, or the per-line copy
* between them (docs/PERF-PLAN.md follow-on, 2026-08-28).
*---------------------------------------------------------------
ENSUREBYTE  lda   STRMDEAD
            bne   :dead
            ldx   BUFPOS
            cpx   BUFLEN
            bcc   :okb
            jsr   NEXTWIN
            bcs   :dead
:okb        clc
            rts
:dead       sec
            rts

*---------------------------------------------------------------
* NEXTWIN -- the current window is consumed: serve the next one
* out of the SAME RDCHUNK read if W_REM says bytes remain
* (CBPTR steps a full window -- BUFLEN is always BUFSZ while
* W_REM is nonzero, by REFILL/NEXTWIN's own construction), else
* REFILL (which owns the file hop and STRMDEAD). carry set =
* stream over.
*---------------------------------------------------------------
NEXTWIN     lda   W_REM
            ora   W_REM+1
            beq   :refill
            clc
            lda   CBPTR
            adc   #BUFSZ
            sta   CBPTR
            bcc   :nc
            inc   CBPTR+1
:nc         lda   W_REM+1
            bne   :fullwin           ;>= 256 left
            lda   W_REM
            cmp   #BUFSZ
            bcs   :fullwin
            sta   BUFLEN             ;the short tail window
            stz   W_REM
            stz   BUFPOS
            clc
            rts
:fullwin    lda   #BUFSZ
            sta   BUFLEN
            lda   W_REM              ;W_REM -= BUFSZ
            sec
            sbc   #BUFSZ
            sta   W_REM
            lda   W_REM+1
            sbc   #0
            sta   W_REM+1
            stz   BUFPOS
            clc
            rts
:refill     jmp   REFILL

*---------------------------------------------------------------
* PEEKEOF -- LASTFLG := 1 if the current line is the last of
* the whole stream (nothing left in CBUF, nothing left in this
* file, no further FILE operand yields a byte), else 0. The
* refilled bytes stay buffered for the next GETLINE.
*---------------------------------------------------------------
*-- THE REFILL-ALIAS HAZARD this routine owns (found 2026-08-29
*-- by run_selfhost's byte-identical tooth -- 6 of 208 real
*-- files corrupted; every small-fixture gate passed): when the
*-- pattern space is served ZERO-COPY out of CBUF and the chunk
*-- is fully drained, the refill this peek needs OVERWRITES the
*-- very bytes EXECLINE is about to process. So: answer with no
*-- syscall at all while bytes or windows remain (which is also
*-- cheaper than the old unconditional ENSUREBYTE), and when a
*-- true refill is unavoidable, SALVAGE an aliased pattern
*-- space into LINEBUF first.
PEEKEOF     lda   STRMDEAD
            bne   :last
            lda   BUFPOS
            cmp   BUFLEN
            bcc   :notlast           ;bytes left in the window
            lda   W_REM
            ora   W_REM+1
            bne   :notlast           ;windows left in the chunk
            lda   LINEPTR
            cmp   #<LINEBUF
            bne   :chkown
            lda   LINEPTR+1
            cmp   #>LINEBUF
            beq   :refill            ;already in LINEBUF
:chkown     lda   LINEPTR
            cmp   PSOWN
            bne   :salvage
            lda   LINEPTR+1
            cmp   PSOWN+1
            beq   :refill            ;owned: stable already
:salvage    lda   LINEPTR
            sta   PTR0
            lda   LINEPTR+1
            sta   PTR0+1
            ldy   #0
:salvcp     lda   (PTR0),y
            sta   LINEBUF,y
            beq   :salvdone
            iny
            bne   :salvcp
:salvdone   lda   #<LINEBUF
            sta   LINEPTR
            lda   #>LINEBUF
            sta   LINEPTR+1
:refill     jsr   ENSUREBYTE
            lda   #0
            rol   a                  ;carry (stream over) -> 1
            sta   LASTFLG
            rts
:notlast    stz   LASTFLG
            rts
:last       lda   #1
            sta   LASTFLG
            rts

REFILL      lda   SRCFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :ended
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :ended
*-- One RDCHUNK read becomes a chain of <=255-byte WINDOWS: the
*-- first is set up here, NEXTWIN serves the rest without a
*-- syscall. trans is 16-bit now (RDCHUNK > 255).
            lda   #<CBUF
            sta   CBPTR
            lda   #>CBUF
            sta   CBPTR+1
            lda   RPARM_TRANS+1
            bne   :bigread           ;>= 256: first window full
            lda   RPARM_TRANS
            sta   BUFLEN
            stz   W_REM
            stz   W_REM+1
            stz   BUFPOS
            clc
            rts
:bigread    lda   #BUFSZ
            sta   BUFLEN
            lda   RPARM_TRANS        ;W_REM = trans - 255
            sec
            sbc   #BUFSZ
            sta   W_REM
            lda   RPARM_TRANS+1
            sbc   #0
            sta   W_REM+1
            stz   BUFPOS
            clc
            rts
:ended      lda   USESTDIN           ;this fd is done: stdin ->
            bne   :dead              ;stream over; a FILE ->
            lda   SRCFD              ;close it, hop to the next
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            jsr   NEXTFILE
            bcs   :dead
            bra   REFILL
:dead       lda   #1
            sta   STRMDEAD
            sec
            rts

