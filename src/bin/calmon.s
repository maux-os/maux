*---------------------------------------------------------------
* calmon.s -- cal's RENDERERS: one month into the output funnel
* (PRINTMON/CALPR2/BUILDTTL) and the year form's quarter painter
* (SLOTBASE/SLOTLO/SLOTHI/PRINTQTR/ROW23TAB/PRINT22/PRINTQSEP).
* `put` by src/bin/cal.s (NOT a standalone binary -- the same
* put-module shape as cal's own calcalc.s), split out for the
* same reason units split anywhere: `as`'s 16,128-byte source
* window holds the resident manifest plus one put file at a
* time, and cal.s's own text alone was past it again once the
* three-column year form landed. Every symbol here resolves
* against cal.s's own equates, zero page pointers, dum cells and
* data tables (CAL_BUFPTR/CAL_QTR/CAL_SLOT/CAL_QROW/CAL_NROWS/
* CAL_TROWS/CAL_MON/CAL_YEAR/CAL_DOW/CAL_MDAYS/CAL_MDAY1/
* CAL_CELL/CAL_ROW/CAL_COL/CAL_PRU/CAL_TLEN/CAL_PAD/CAL_LPAD/
* CAL_RPAD/CAL_I/TITLEBUF/MBUFS0/MBUFS1/MBUFS2/DAYSTAB/MONNAMES/
* DOWHDR) and CALEMITC/CALEMITS/CALCDOW -- see that file's own
* header.
*---------------------------------------------------------------
*---------------------------------------------------------------
* SLOTBASE -- IN: A = 0/1/2. OUT: CAL_BUFPTR = MBUFS0/1/2, the
* base of that slot's own 8-row*23-byte scratch block.
*
* THE THREE SLOTS ARE THREE LABELS, NOT ONE LABEL PLUS AN
* OFFSET, and that is load-bearing for the REL route rather
* than a style choice: MBUFS0..2 live in the `dum LIBA_BSSEND`
* arena, which the REL split extracts into a companion bss
* module, so every reference to them from here is an EXTERNAL.
* An external HIGH-byte fixup ($50) stores only
* `$80 + high(addend)` -- the addend's LOW byte has nowhere to
* live -- so `>SYM+184` loses the carry out of
* `low(SYM) + 184` and links one too low. Three separate ENTs
* make every addend zero, which the format does carry exactly.
* (docs/REL-FORMAT.md, "An external reference carries an
* ADDEND"; measured 2026-09-17 as a one-byte check-nas-librel
* miss on this very table.)
*---------------------------------------------------------------
SLOTBASE    tax
            lda   SLOTLO,x
            sta   CAL_BUFPTR
            lda   SLOTHI,x
            sta   CAL_BUFPTR+1
            rts
SLOTLO      dfb   <MBUFS0,<MBUFS1,<MBUFS2
SLOTHI      dfb   >MBUFS0,>MBUFS1,>MBUFS2

*---------------------------------------------------------------
* PRINTQTR -- re-emit the 3 just-filled MBUFSn interleaved:
* for each of the 8 rows (title/header/6 weeks), print slot 0's
* 22 content bytes, then slot 1's, then slot 2's, then ONE real
* CR -- the buffered CR each slot's OWN row ends with (byte 23
* of its 23-byte row) is skipped by PRINT22's own 22-byte cap,
* never re-emitted mid-line. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PRINTQTR    stz   CAL_QROW
:qrlp       stz   CAL_SLOT
:qslp       lda   CAL_SLOT
            jsr   SLOTBASE
            lda   CAL_QROW
            tax
            lda   ROW23TAB,x
            clc
            adc   CAL_BUFPTR
            sta   PTR0
            lda   CAL_BUFPTR+1
            adc   #0
            sta   PTR0+1
            jsr   PRINT22
            inc   CAL_SLOT
            lda   CAL_SLOT
            cmp   #3
            bne   :qslp
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   CAL_QROW
            lda   CAL_QROW
            cmp   CAL_TROWS
            bne   :qrlp
            rts
ROW23TAB    dfb   0,23,46,69,92,115,138,161

*---------------------------------------------------------------
* PRINT22 -- IN: PTR0. Prints exactly 22 raw bytes, no NUL scan
* (a MBUFSn holds no terminators -- every stored byte is a real,
* nonzero, high-bit space/digit/letter). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PRINT22     ldy   #0
:p22lp      lda   (PTR0),y
            ldx   #FD_STDOUT
            jsr   PUTC
            iny
            cpy   #22
            bne   :p22lp
            rts

*---------------------------------------------------------------
* PRINTQSEP -- ONE genuinely empty line (CR alone) between
* quarters -- measured live (this host's own cal 2020: line 10,
* between Q1 and Q2, is 0 bytes before its own CR; the 66-space
* row just before it, line 9, is Q1's own fully-blank 6th week
* row, not a second separator -- every quarter really is 6
* rows tall, never fewer).
*---------------------------------------------------------------
PRINTQSEP   lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* PRINTMON -- print the CAL_MON/CAL_YEAR month block: title,
* day-name header, 6 week rows (22 columns each, trailing-
* space padded, matching this host's own BSD cal). CLOBBERS:
* A, X, Y.
*---------------------------------------------------------------
PRINTMON    jsr   CALCDOW
            jsr   BUILDTTL
            sta   CAL_TLEN
            lda   #20
            sec
            sbc   CAL_TLEN
            sta   CAL_PAD
            lsr   a
            sta   CAL_LPAD
            lda   CAL_PAD
            sec
            sbc   CAL_LPAD
            sta   CAL_RPAD

            lda   CAL_LPAD
            sta   CAL_I
:tlp1       lda   CAL_I
            beq   :tlp1d
            lda   #$A0
            jsr   CALEMITC
            dec   CAL_I
            bra   :tlp1
:tlp1d      lda   #<TITLEBUF
            sta   PTR0
            lda   #>TITLEBUF
            sta   PTR0+1
            jsr   CALEMITS
            lda   CAL_RPAD
            clc
            adc   #2
            sta   CAL_I
:tlp2       lda   CAL_I
            beq   :tlp2d
            lda   #$A0
            jsr   CALEMITC
            dec   CAL_I
            bra   :tlp2
:tlp2d      lda   #$8D
            jsr   CALEMITC

            lda   #<DOWHDR
            sta   PTR0
            lda   #>DOWHDR
            sta   PTR0+1
            jsr   CALEMITS
            lda   #$8D
            jsr   CALEMITC

            lda   CAL_MDAYS
            clc
            adc   #1
            sta   CAL_MDAY1
            stz   CAL_CELL
            stz   CAL_ROW
:rowlp      stz   CAL_COL
:collp      lda   CAL_CELL
            cmp   CAL_DOW
            bcc   :blank
            lda   CAL_CELL
            sec
            sbc   CAL_DOW
            clc
            adc   #1
            cmp   CAL_MDAY1
            bcs   :blank
            jsr   CALPR2
            bra   :colend
:blank      lda   #$A0
            jsr   CALEMITC
            lda   #$A0
            jsr   CALEMITC
:colend     inc   CAL_CELL
            inc   CAL_COL
            lda   CAL_COL
            cmp   #7
            beq   :rowend
            lda   #$A0
            jsr   CALEMITC
            bra   :collp
:rowend     lda   #$A0
            jsr   CALEMITC
            lda   #$A0
            jsr   CALEMITC
            lda   #$8D
            jsr   CALEMITC
            inc   CAL_ROW
            lda   CAL_ROW
            cmp   CAL_NROWS
            bne   :rowlp
            rts

*---------------------------------------------------------------
* CALPR2 -- IN: A = 1..31. Prints a 2-column right-justified
* field, high-bit ASCII, space-padded (not zero-padded).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
CALPR2      ldy   #0
:tens       cmp   #10
            bcc   :ones
            sec
            sbc   #10
            iny
            bra   :tens
:ones       sta   CAL_PRU
            cpy   #0
            bne   :tnz
            lda   #$A0
            bra   :tprt
:tnz        tya
            ora   #$B0
:tprt       jsr   CALEMITC
            lda   CAL_PRU
            ora   #$B0
            jsr   CALEMITC
            rts

*---------------------------------------------------------------
* BUILDTTL -- build "MonthName Year" into TITLEBUF, NUL-
* terminated. OUT: A = length (low byte; always < 24).
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
BUILDTTL    lda   CAL_MON
            sec
            sbc   #1
            asl   a
            tax
            lda   MONNAMES,x
            sta   PTR0
            lda   MONNAMES+1,x
            sta   PTR0+1
            lda   #<TITLEBUF
            sta   PTR1
            lda   #>TITLEBUF
            sta   PTR1+1
            jsr   STRCPY
            tax
            lda   CAL_BUFMODE      ;year form: title is the
            beq   :withyr          ;month name ALONE, no " YEAR"
            txa                    ;-- see PRINTYEARHDR for the
            rts                    ;year's own header line
:withyr     lda   #$A0
            sta   TITLEBUF,x
            inx
            txa
            clc
            adc   #<TITLEBUF
            sta   PTR1
            lda   #>TITLEBUF
            adc   #0
            sta   PTR1+1
            lda   CAL_YEAR
            sta   U2DEC_VAL
            lda   CAL_YEAR+1
            sta   U2DEC_VAL+1
            jsr   U2DEC
            lda   #<TITLEBUF
            sta   PTR0
            lda   #>TITLEBUF
            sta   PTR0+1
            jsr   STRLEN
            rts
