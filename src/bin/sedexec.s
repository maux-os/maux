*---------------------------------------------------------------
* sedexec.s -- sed's cycle executor, `put` by src/bin/sed.s
* (NOT a standalone binary). EXECLINE runs the compiled script
* over the pattern space once per cycle; every verb handler is
* reached through VTAB and leaves through CNEXT (next command),
* CEND (end of script: autoprint unless -n or a delete, then
* the append queue) or EXLOOP (a branch). The selection half
* (CHKSEL, DOSUBST) is sedsel.s; the space/output helpers
* (MATERIAL, APPSTR, FLUSHAPP, LIST, YTRANS) are sedout.s.
*---------------------------------------------------------------
EXECLINE    stz   DELFLG
            stz   CURCMD
EXLOOP      ldx   CURCMD
            cpx   NCMDS
            bcs   CEND
            jsr   CHKSEL             ;carry = address selects
            ldx   CURCMD
            lda   CFLG,x
            and   #SF_NEG
            beq   :plain
            bcs   :unsel             ;'!' flips the answer
            bra   :sel
:plain      bcc   :unsel
:sel        lda   CVERB,x
            asl   a
            tax
            jmp   (VTAB,x)
:unsel      lda   CVERB,x
            cmp   #V_LBRACE
            bne   CNEXT
            lda   CP1L,x             ;skip the whole block
            sta   CURCMD
            bra   EXLOOP

CNEXT       inc   CURCMD
            bra   EXLOOP

CDEL        lda   #1                 ;d: end the cycle, no
            sta   DELFLG             ;autoprint
CEND        lda   DELFLG
            bne   :nopr
            lda   NFLAG
            bne   :nopr
            jsr   PRINTLINE
:nopr       jmp   FLUSHAPP           ;its rts ends EXECLINE

* -- verb handlers, indexed by verb code --
VTAB        da    X_NOP,X_NOP,X_A,X_B
            da    X_C,X_D,X_DD,X_EQ
            da    X_G,X_GG,X_H,X_HH
            da    X_I,X_L,X_N,X_NN
            da    X_P,X_PP,X_Q,X_R
            da    X_S,X_T,X_W,X_X
            da    X_Y,X_NOP

X_NOP       jmp   CNEXT              ;{ (selected), }, :

*---------------------------------------------------------------
* a, r -- queue for the end of the cycle (or the next read).
* i -- text now. c -- delete; the text goes out on a 1-address
* command every time, on a 2-address range once, at its end
* (a negated range: every selected line).
*---------------------------------------------------------------
X_A         lda   #V_A
            bra   ENQUEUE
X_R         lda   #V_R
ENQUEUE     ldy   NAPP
            cpy   #MAXAPP
            bcc   :room
            lda   #E_APPFULL
            jmp   RUNERR
:room       sta   AQKIND,y
            ldx   CURCMD
            lda   CP1L,x
            sta   AQPL,y
            lda   CP1H,x
            sta   AQPH,y
            inc   NAPP
            jmp   CNEXT

X_I         ldx   CURCMD
            jsr   OUTTEXT
            jmp   CNEXT

X_C         ldx   CURCMD
            lda   CA2T,x
            beq   :print
            lda   CFLG,x
            and   #SF_NEG
            bne   :print
            lda   CACT,x             ;still inside the range:
            bne   :del               ;delete only
:print      ldx   CURCMD
            jsr   OUTTEXT
:del        jmp   CDEL

*---------------------------------------------------------------
* d, D
*---------------------------------------------------------------
X_D         jmp   CDEL

X_DD        jsr   FINDNL             ;SD_WK -> first CR
            bcc   X_D                ;none: plain d
            jsr   WKINC
            lda   SD_WK
            sta   LINEPTR
            lda   SD_WK+1
            sta   LINEPTR+1
            lda   #1                 ;rerun the script on the
            sta   RESTART            ;rest, reading nothing
            jmp   CDEL

*---------------------------------------------------------------
* =, l, p, P, w
*---------------------------------------------------------------
X_EQ        lda   LINENO
            sta   U2DEC_VAL
            lda   LINENO+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            lda   #$8D
            jsr   PUTC1
            jmp   CNEXT

X_L         jsr   LIST
            jmp   CNEXT

X_P         jsr   PRINTLINE
            jmp   CNEXT

X_PP        jsr   FINDNL
            bcc   X_P                ;no newline: whole space
            lda   #0
            sta   (SD_WK)
            jsr   PRINTLINE
            lda   #$8D
            sta   (SD_WK)
            jmp   CNEXT

X_W         ldx   CURCMD
            ldy   CP1L,x
            ldx   WFFD,y
            jsr   WRITEPS
            jmp   CNEXT

*---------------------------------------------------------------
* g, G, h, H, x -- the hold space.
*---------------------------------------------------------------
X_G         lda   HSPTR
            sta   SD_WK
            lda   HSPTR+1
            sta   SD_WK+1
            jsr   TOPSOWN
            jmp   CNEXT

X_GG        jsr   MATERIAL
            jsr   PSEND
            lda   HSPTR
            sta   SD_WK
            lda   HSPTR+1
            sta   SD_WK+1
            jsr   APPSTR
            jmp   CNEXT

X_H         lda   LINEPTR
            sta   SD_WK
            lda   LINEPTR+1
            sta   SD_WK+1
            lda   HSPTR
            sta   SD_DST
            lda   HSPTR+1
            sta   SD_DST+1
            jsr   SETLIM
            jsr   CPYSTR
            jmp   CNEXT

X_HH        jsr   HSEND
            lda   LINEPTR
            sta   SD_WK
            lda   LINEPTR+1
            sta   SD_WK+1
            jsr   APPSTR
            jmp   CNEXT

X_X         jsr   MATERIAL
            ldx   #1
:swap       lda   PSOWN,x
            ldy   HSPTR,x
            sta   HSPTR,x
            tya
            sta   PSOWN,x
            dex
            bpl   :swap
            lda   PSOWN
            sta   LINEPTR
            lda   PSOWN+1
            sta   LINEPTR+1
            jmp   CNEXT

*---------------------------------------------------------------
* n, N -- the next input line. With none left: n ends the
* script (autoprint applies) and quits; N quits WITHOUT the
* autoprint (POSIX, and this host's BSD sed; GNU prints).
*---------------------------------------------------------------
X_N         lda   LASTFLG
            beq   :more
            lda   #1
            sta   QUITFLG
            jmp   CEND
:more       lda   NFLAG
            bne   :nopr
            jsr   PRINTLINE
:nopr       jsr   FLUSHAPP
            jsr   NEXTLINE
            jmp   CNEXT

X_NN        lda   LASTFLG
            beq   :more
            lda   #1
            sta   QUITFLG
            jmp   CDEL
:more       jsr   MATERIAL           ;the read may refill CBUF
            jsr   FLUSHAPP
            jsr   NEXTLINE           ;new line -> LINEPTR
            lda   LINEPTR
            sta   SD_WK
            lda   LINEPTR+1
            sta   SD_WK+1
            lda   PSOWN
            sta   LINEPTR
            lda   PSOWN+1
            sta   LINEPTR+1
            jsr   PSEND
            jsr   APPSTR
            jmp   CNEXT

* -- NEXTLINE: GETLINE + PEEKEOF + LINENO + the t flag reset.
* -- Only called with LASTFLG clear, so GETLINE has a line;
* -- the defensive branch makes an impossible EOF harmless.
NEXTLINE    jsr   GETLINE
            bcs   :eof
            jsr   PEEKEOF
            inc   LINENO
            bne   :nc
            inc   LINENO+1
:nc         stz   TFLAG
            rts
:eof        lda   #<EMPTYSTR
            sta   LINEPTR
            lda   #>EMPTYSTR
            sta   LINEPTR+1
            lda   #1
            sta   LASTFLG
            sta   QUITFLG
            rts
EMPTYSTR    dfb   0

*---------------------------------------------------------------
* q, s, b, t, y
*---------------------------------------------------------------
X_Q         ldx   CURCMD
            lda   CP1L,x
            sta   QCODE
            lda   #1
            sta   QUITFLG
            jmp   CEND

X_S         jsr   DOSUBST
            jmp   CNEXT

X_B         ldx   CURCMD
            lda   CP1L,x
            sta   CURCMD
            jmp   EXLOOP

X_T         lda   TFLAG
            beq   :no
            stz   TFLAG
            bra   X_B
:no         jmp   CNEXT

X_Y         jsr   YTRANS
            jmp   CNEXT
