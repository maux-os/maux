*---------------------------------------------------------------
* morefile.s -- more's per-file driver (put by more.s): the copy
* path for a non-console stdout, opening an operand or standard
* input (the spill), a file's first screen, and the small
* helpers START uses (DECPARSE, INITPARMS). Split out of more.s
* 2026-09-12 for the self-hosting source-buffer budget
* (check-dialect: resident + largest put <= 41215).
*---------------------------------------------------------------

*---------------------------------------------------------------
* COPYALL -- standard output is not a console: copy every input
* to it unmodified except -s (POSIX: "no options except -s
* shall have any effect"). No table, no spill, no prompt.
*---------------------------------------------------------------
COPYALL     lda   NFILES
            bne   :cfiles
            lda   #FD_STDIN
            sta   RDFD
            jsr   COPYONE
            bra   :cdone
:cfiles     lda   CURIDX
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :copenerr
            lda   OPARM_REF
            sta   RDFD
            jsr   COPYONE
            lda   RDFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            bra   :cnext
:copenerr   jsr   OPENERR
:cnext      inc   CURIDX
            lda   CURIDX
            cmp   ARGC
            bcc   :cfiles
:cdone      lda   ERRFLAG
            jsr   EXIT

*-- COPYONE -- RDFD -> stdout through IOBUF; -s drops a blank
*-- line that follows a blank line. PREVBLANK carries across
*-- files, as it does on the glass.
COPYONE     stz   PREVBLANK
            stz   CHK_LEN                ;IOBUF is reused raw:
            stz   CHK_LEN+1              ;READ_AT cache: void
            lda   #1
            sta   ATBOL
:fill       lda   RDFD
            sta   RPARM_REF
            jsr   RDSETUP
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :out
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :out
            lda   RPARM_TRANS
            sta   MP_NRD
            ldx   #0
:emit       lda   IOBUF,x
            cmp   #$8D
            beq   :cpnl
            cmp   #$0D                   ;a foreign file's CR
            bne   :plain
:cpnl       ldy   ATBOL                  ;a CR at line start = a
            beq   :nlout                 ;blank line
            ldy   OPT_S
            beq   :nlout
            ldy   PREVBLANK
            bne   :skip                  ;second blank: dropped
:nlout      ldy   ATBOL
            sty   PREVBLANK
            ldy   #1
            sty   ATBOL
            bra   :put
:plain      stz   ATBOL
:put        phx
            ldx   #FD_STDOUT
            jsr   PUTC
            plx
:skip       inx
            cpx   MP_NRD
            bne   :emit
            bra   :fill
:out        rts

*---------------------------------------------------------------
* OPENCUR -- open operand CURIDX as the current file: table
* reset, size learned. Carry set (and a diagnostic, ERRFLAG=1)
* when it cannot be opened.
*---------------------------------------------------------------
OPENCUR     jsr   CLOSECUR
            lda   CURIDX
            jsr   GETARG
            lda   PTR0                   ;the operand text, for
            sta   CURNAME                ;the prompt / = / v
            lda   PTR0+1
            sta   CURNAME+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            stz   OPARM_IOBUF
            stz   OPARM_IOBUF+1
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :err
            lda   OPARM_REF
            sta   RDFD
            stz   ISSTDIN
            jsr   TABRESET
            jsr   SIZEFROMFD             ;FSIZE via GET_EOF
            clc
            rts
:err        jsr   OPENERR
            sec
            rts

*-- OPENERR -- "more: cannot open NAME" on stderr; ERRFLAG=1.
OPENERR     ldx   #FD_STDOUT             ;the page before the
            jsr   SIO_FLUSH              ;diagnostic, in order
            lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   CURIDX
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG
            rts

*-- CLOSECUR -- close the current file's fd (never stdin's,
*-- never the spill's: SPILLDROP owns that one).
CLOSECUR    lda   ISSTDIN
            bne   :none
            lda   RDFD
            beq   :none                  ;nothing open yet
            cmp   #FD_STDIN
            beq   :none
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
:none       stz   RDFD
            rts

*---------------------------------------------------------------
* OPENSTDIN -- standard input is the source. A FILE (`more <
* f`) is seekable and is read in place; a PIPE is spilled to
* MORE.INxx as the scan consumes it (moreio.s SCANMORE), and the
* spill file is what the table indexes.
*---------------------------------------------------------------
OPENSTDIN   lda   #<STDINNAME
            sta   CURNAME
            lda   #>STDINNAME
            sta   CURNAME+1
            lda   STDINKIND
            cmp   #FDST_FILE
            bne   :pipe
            lda   #FD_STDIN
            sta   RDFD
            stz   ISSTDIN
            jsr   TABRESET
            jsr   SIZEFROMFD
            clc
            rts
:pipe       jsr   SPILLMAKE              ;SPILLFD; carry = fail
            bcs   :fail
            lda   SPILLFD
            sta   RDFD
            lda   #1
            sta   ISSTDIN
            jsr   TABRESET
            stz   SIZEKNOWN
            clc
            rts
:fail       lda   #<SPILLMSG
            sta   PTR0
            lda   #>SPILLMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            sta   ERRFLAG
            sec
            rts

*---------------------------------------------------------------
* SHOWFIRST -- a file's first screen. With several operands the
* BSD "::::::::::::::" header names the file first (three rows
* off the screenful). If the whole of the LAST file fits, more
* is done -- no prompt (the friction case: `ls | more` on a
* short listing must not stop). ISLAST is computed here.
*---------------------------------------------------------------
SHOWFIRST   stz   TOP
            stz   TOP+1
            lda   #$FF                   ;BOT = -1: none shown
            sta   BOT
            sta   BOT+1
            stz   ATEOF
            stz   PREVBLANK
            lda   #1
            sta   FIRSTSCR
            jsr   CALCLAST
            lda   PAGEROWS
            sta   MP_TMP2                ;rows to fill
            lda   NFILES
            cmp   #2
            bcc   :nohdr
            lda   OPT_C
            beq   :hdr
            jsr   CLEARSCR
:hdr        jsr   FILEHDR                ;3 rows
            lda   MP_TMP2
            sec
            sbc   #3
            bcs   :hdrok
            lda   #1
:hdrok      sta   MP_TMP2
            bra   :fill
:nohdr      lda   OPT_C
            beq   :fill
            jsr   CLEARSCR
:fill       lda   MP_TMP2
            jsr   FILLROWS
            jsr   TOPFROMBOT
            lda   ATEOF
            beq   :out
            lda   ISLAST
            beq   :out
*-- Under -A the glass IS the alternate screen, and leaving
*-- restores the shell's -- so a last file that fits on one
*-- screen would be drawn and wiped in the same instant (man
*-- cxref, 2026-10-01: "starts to display then dies"). Stay at
*-- the (END) prompt instead; q leaves, as for a long file.
            lda   OPT_A
            bne   :out
            lda   #1                     ;last file, fits: leave
            sta   QUITFLG
:out        rts

*-- CALCLAST -- ISLAST = 1 when CURIDX names the last operand
*-- (or stdin is the source).
CALCLAST    lda   NFILES
            beq   :yes
            lda   CURIDX
            clc
            adc   #1
            cmp   ARGC
            bcs   :yes
            stz   ISLAST
            rts
:yes        lda   #1
            sta   ISLAST
            rts

*-- TOPFROMBOT -- after forward output: TOP = BOT-(PAGEROWS-1),
*-- floored at 0 (one row a line assumed; wraps make the screen
*-- start later than this says, which only shortens a `b`).
TOPFROMBOT  lda   BOT
            and   BOT+1
            cmp   #$FF                   ;nothing drawn: TOP = 0
            bne   :some
            stz   TOP
            stz   TOP+1
            rts
:some       lda   PAGEROWS
            sec
            sbc   #1
            sta   MP_TMP
            stz   MP_TMP+1
            lda   BOT
            sec
            sbc   MP_TMP
            sta   TOP
            lda   BOT+1
            sbc   MP_TMP+1
            sta   TOP+1
            bcs   :ok
            stz   TOP
            stz   TOP+1
:ok         rts

*---------------------------------------------------------------
* DECPARSE -- (PTR0) decimal digits -> MP_TMP. Carry set on no
* digit or a trailing non-digit; values wrap past 65535 (no
* caller cares: -n is clamped to 255 anyway).
*---------------------------------------------------------------
DECPARSE    stz   MP_TMP
            stz   MP_TMP+1
            ldy   #0
            lda   (PTR0),y
            beq   :bad
:dig        lda   (PTR0),y
            beq   :ok
            cmp   #"0"
            bcc   :bad
            cmp   #"9"+1
            bcs   :bad
            and   #$0F
            pha
            lda   MP_TMP                 ;MP_TMP *= 10
            sta   MP_ACC
            lda   MP_TMP+1
            sta   MP_ACC+1
            asl   MP_TMP
            rol   MP_TMP+1
            asl   MP_TMP
            rol   MP_TMP+1
            lda   MP_TMP
            clc
            adc   MP_ACC
            sta   MP_TMP
            lda   MP_TMP+1
            adc   MP_ACC+1
            sta   MP_TMP+1
            asl   MP_TMP
            rol   MP_TMP+1
            pla
            clc
            adc   MP_TMP
            sta   MP_TMP
            bcc   :nc
            inc   MP_TMP+1
:nc         iny
            bne   :dig
:ok         clc
            rts
:bad        sec
            rts

INITPARMS   lda   #OPEN_RO            ;read intent for the INPUT
            sta   OPARM               ;opens; TMPCREATE flips it
            lda   #<PATHBUF
            sta   OPARM_PATH
            lda   #>PATHBUF
            sta   OPARM_PATH+1
            lda   #PCOUNT_READ
            sta   RPARM
            lda   #PCOUNT_WRITE
            sta   WPARM
            lda   #PCOUNT_CLOSE
            sta   CPARM
            stz   SPWN_ENVP
            stz   SPWN_ENVP+1
            rts

