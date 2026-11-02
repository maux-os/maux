*---------------------------------------------------------------
* patchtgt.s -- the TARGET file's side: read it whole into the
* arena as a line table, hand a line back by number, and create
* the output stream.
*
* `put` into src/bin/patch.s after patchwr.s (split from
* patchio.s for check-dialect's as-window budget); one assembly
* stream, every rule in that manifest's header applies
* unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* READTGT -- open NAMEBUF, read it whole into ARENA/TGTLP with
* CR ($8D) turned into NUL in place (sort.s/diff.s's own line
* storage), close it. A final unterminated line still counts.
* Exits 2 if the target cannot be opened -- there is nothing to
* patch.
*---------------------------------------------------------------
READTGT     lda   #<NAMEBUF
            sta   PTR0
            lda   #>NAMEBUF
            sta   PTR0+1
            jsr   MKPATH1
            lda   #<IOPARM
            ldx   #>IOPARM
            jsr   SC_OPEN
            bcc   :topen
            jmp   NOTARGET
:topen      lda   IOPARM_REF
            sta   TFD
            lda   #<ARENA
            sta   PT_TPOS
            lda   #>ARENA
            sta   PT_TPOS+1
            lda   PT_TPOS
            sta   PT_LSTART
            lda   PT_TPOS+1
            sta   PT_LSTART+1
            stz   TBUFPOS
            stz   TBUFLEN
:loop       jsr   GETTB
            bcs   :eof
            sta   PT_CBYTE
            jsr   CHKTROOM
            lda   PT_CBYTE
            cmp   #$8D
            bne   :put
            lda   #0
:put        sta   (PT_TPOS)
            lda   PT_CBYTE
            cmp   #$8D
            bne   :adv
            jsr   ADDTLINE
            inc   PT_TPOS
            bne   :sl
            inc   PT_TPOS+1
:sl         lda   PT_TPOS
            sta   PT_LSTART
            lda   PT_TPOS+1
            sta   PT_LSTART+1
            bra   :loop
:adv        inc   PT_TPOS
            bne   :loop
            inc   PT_TPOS+1
            bra   :loop
:eof        lda   PT_TPOS
            cmp   PT_LSTART
            bne   :tail
            lda   PT_TPOS+1
            cmp   PT_LSTART+1
            beq   :close
:tail       jsr   CHKTROOM
            lda   #0
            sta   (PT_TPOS)
            jsr   ADDTLINE
:close      lda   TFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jmp   SC_CLOSE

CHKTROOM    lda   PT_TPOS+1
            cmp   #>ARENAEND
            bcc   :ok
            bne   :full
            lda   PT_TPOS
            cmp   #<ARENAEND
            bcc   :ok
:full       jmp   OVERFLOW
:ok         rts

ADDTLINE    lda   NT
            cmp   #MAXLINES
            bcs   :tfull
            asl   a
            sta   PT_TMP
            lda   #0
            rol   a
            sta   PT_TMP+1
            clc
            lda   PT_TMP
            adc   #<TGTLP
            sta   PT_TMP
            lda   PT_TMP+1
            adc   #>TGTLP
            sta   PT_TMP+1
            lda   PT_LSTART
            sta   (PT_TMP)
            ldy   #1
            lda   PT_LSTART+1
            sta   (PT_TMP),y
            inc   NT
            rts
:tfull      jmp   OVERFLOW

GETTB       ldx   TBUFPOS
            cpx   TBUFLEN
            bcc   :have
            jsr   REFILT
            bcs   :eof
            ldx   TBUFPOS
:have       lda   TBUF,x
            inc   TBUFPOS
            clc
            rts
:eof        sec
            rts

REFILT      lda   TFD
            sta   TRPARM_REF
            lda   #<TRPARM
            ldx   #>TRPARM
            jsr   SC_READ
            bcs   :rerr
            lda   TRPARM_TRANS
            ora   TRPARM_TRANS+1
            beq   :rerr
            lda   TRPARM_TRANS
            sta   TBUFLEN
            stz   TBUFPOS
            clc
            rts
:rerr       sec
            rts

*---------------------------------------------------------------
* TGTLINE -- IN: A = 1-based target line number. OUT: PTR0 ->
* its text. Only ever called for 1..NT.
*---------------------------------------------------------------
TGTLINE     sec
            sbc   #1
            ldx   #<TGTLP
            ldy   #>TGTLP
            jsr   LPGET
            lda   PT_LP2
            sta   PTR0
            lda   PT_LP2+1
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* OPENOUT -- CREAT the output (the -o name if given, else the
* target itself) and leave its fd in OFD. The target's own fd
* is already CLOSED by READTGT, so output-onto-input needs no
* temporary file: the whole original is in the arena.
*---------------------------------------------------------------
OPENOUT     lda   HAVEOUT
            beq   :inplace
            lda   #<OUTNAME
            ldx   #>OUTNAME
            bra   :doit
:inplace    lda   #<NAMEBUF
            ldx   #>NAMEBUF
:doit       sta   PTR0
            stx   PTR0+1
            jsr   MKPATH1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   CREAT
            bcs   :cfail
            sta   OFD
            rts
:cfail      jmp   NOWRITE
