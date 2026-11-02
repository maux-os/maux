*---------------------------------------------------------------
* sedout.s -- sed's space and output helpers, `put` by
* src/bin/sed.s after sedio.s (NOT a standalone binary): the
* pattern/hold space copies and appends, the append queue
* (a, r), w-file opening, the l listing and the y transform.
*---------------------------------------------------------------
* MATERIAL -- make the pattern space OWN its bytes: a line
* served zero-copy out of CBUF (or assembled in LINEBUF, or a
* D-shortened tail) is copied into the PSOWN arena first. Any
* command that appends to the space, or reads more input while
* the space must survive (N), calls this first.
* TOPSOWN -- copy the string at SD_WK into PSOWN and make it
* the pattern space (g, and MATERIAL's tail).
*---------------------------------------------------------------
MATERIAL    lda   LINEPTR
            cmp   PSOWN
            bne   :copy
            lda   LINEPTR+1
            cmp   PSOWN+1
            bne   :copy
            rts
:copy       lda   LINEPTR
            sta   SD_WK
            lda   LINEPTR+1
            sta   SD_WK+1
TOPSOWN     lda   PSOWN
            sta   SD_DST
            sta   LINEPTR
            lda   PSOWN+1
            sta   SD_DST+1
            sta   LINEPTR+1
            jsr   SETLIM
            jmp   CPYSTR

* -- CPYSTR: (SD_WK) -> (SD_DST) through the NUL, bounded by
* -- SD_LIM (SUBPUT's loud overflow).
CPYSTR      lda   (SD_WK)
            beq   :end
            jsr   SUBPUT
            jsr   WKINC
            bra   CPYSTR
:end        sta   (SD_DST)
            rts

* -- APPSTR: a newline, then (SD_WK), onto the string whose
* -- NUL SD_DST points at (SD_LIM already set).
APPSTR      lda   #$8D
            jsr   SUBPUT
            jmp   CPYSTR

* -- PSEND / HSEND: SD_DST -> that space's NUL, SD_LIM set.
PSEND       lda   PSOWN
            sta   SD_DST
            lda   PSOWN+1
            sta   SD_DST+1
            jsr   SETLIM
            bra   FINDEND
HSEND       lda   HSPTR
            sta   SD_DST
            lda   HSPTR+1
            sta   SD_DST+1
            jsr   SETLIM
FINDEND     lda   (SD_DST)
            beq   :r
            inc   SD_DST
            bne   FINDEND
            inc   SD_DST+1
            bra   FINDEND
:r          rts

* -- FINDNL: SD_WK -> the pattern space's first newline; carry
* -- set = found, clear = none (SD_WK at the NUL).
FINDNL      lda   LINEPTR
            sta   SD_WK
            lda   LINEPTR+1
            sta   SD_WK+1
:lp         lda   (SD_WK)
            beq   :no
            cmp   #$8D
            beq   :yes
            jsr   WKINC
            bra   :lp
:yes        sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* OUTTEXT -- command X's text (CP1) + CR to stdout.
* OUTSTR  -- the string at SD_WK + CR to stdout.
*---------------------------------------------------------------
OUTTEXT     lda   CP1L,x
            sta   PTR0
            lda   CP1H,x
            sta   PTR0+1
            bra   OUTPTR0
OUTSTR      lda   SD_WK
            sta   PTR0
            lda   SD_WK+1
            sta   PTR0+1
OUTPTR0     ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            jmp   PUTC1

*---------------------------------------------------------------
* FLUSHAPP -- write the append queue (a text, r files) in
* order and empty it. Called at the end of every cycle and
* before n/N read the next line.
*---------------------------------------------------------------
FLUSHAPP    ldx   #0
:lp         cpx   NAPP
            bcs   :done
            lda   AQPL,x
            sta   SD_WK
            lda   AQPH,x
            sta   SD_WK+1
            lda   AQKIND,x
            phx
            cmp   #V_R
            beq   :rf
            jsr   OUTSTR
            bra   :nx
:rf         jsr   RFILE
:nx         plx
            inx
            bra   :lp
:done       stz   NAPP
            rts

* -- RFILE: copy the file named at SD_WK to stdout; a file
* -- that cannot be opened is silently nothing (POSIX).
RFILE       lda   SD_WK
            sta   PTR0
            lda   SD_WK+1
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            bcs   :done
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :done
            lda   OPARM_REF
            sta   RPARM2_REF
            sta   CPARM_REF
:rd         lda   #<RPARM2
            ldx   #>RPARM2
            jsr   SC_READ
            bcs   :close
            lda   RPARM2_TRNS        ;<= BUFSZ by construction
            beq   :close
            tax
            lda   #0
            sta   RBUF,x
            lda   #<RBUF
            sta   PTR0
            lda   #>RBUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            bra   :rd
:close      lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
:done       rts

*---------------------------------------------------------------
* WFOPEN -- before any input: create (truncate) every w file
* once and keep its fd; "/dev/stdout" is fd 1. liba's stdio
* buffers each fd and EXIT flushes them all.
*---------------------------------------------------------------
WFOPEN      stz   WFIDX
:lp         ldx   WFIDX
            cpx   NWF
            bcs   :done
            lda   WFPL,x
            sta   PTR0
            lda   WFPH,x
            sta   PTR0+1
            lda   #<DEVSTDOUT
            sta   PTR1
            lda   #>DEVSTDOUT
            sta   PTR1+1
            jsr   STRCMP             ;preserves PTR0
            cmp   #0
            bne   :creat
            lda   #FD_STDOUT
            bra   :store
:creat      lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            bcs   :fail
            jsr   CREAT              ;A = fd
            bcs   :fail
:store      ldx   WFIDX
            sta   WFFD,x
            inc   WFIDX
            bra   :lp
:done       rts
:fail       lda   #E_WOPEN
            jmp   RUNERR

*---------------------------------------------------------------
* LIST -- the l command: the pattern space unambiguously.
* '\\' and \a \b \f \n \r \t \v as those escapes, other
* non-printing bytes as \ooo, a '$' at the end, and rows
* folded with a trailing '\' so none exceeds LFOLD-1 chars
* (GNU's 70-column default; this host's BSD sed folds the same
* way under COLUMNS=70).
*---------------------------------------------------------------
LIST        lda   LINEPTR
            sta   SD_WK
            lda   LINEPTR+1
            sta   SD_WK+1
            stz   SD_CNT
:lp         lda   (SD_WK)
            bne   :go
            jmp   :end
:go         and   #$7F
            sta   SD_CH
            cmp   #$5C               ;backslash
            beq   :w2
            cmp   #$20
            bcc   :ctl
            cmp   #$7F
            beq   :w4
            lda   #1
            bra   :have
:ctl        cmp   #$07
            bcc   :w4
            cmp   #$0E
            bcs   :w4
            cmp   #$0A
            beq   :w4
:w2         lda   #2
            bra   :have
:w4         lda   #4
:have       sta   SD_TMP
            clc
            adc   SD_CNT
            cmp   #LFOLD
            bcc   :fits
            lda   #"\"
            jsr   PUTC1
            lda   #$8D
            jsr   PUTC1
            stz   SD_CNT
:fits       lda   SD_CNT
            clc
            adc   SD_TMP
            sta   SD_CNT
            lda   SD_TMP
            cmp   #1
            beq   :plain
            cmp   #2
            beq   :two
            lda   #"\"               ;\ooo
            jsr   PUTC1
            lda   SD_CH
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            ora   #$B0
            jsr   PUTC1
            lda   SD_CH
            lsr   a
            lsr   a
            lsr   a
            and   #7
            ora   #$B0
            jsr   PUTC1
            lda   SD_CH
            and   #7
            ora   #$B0
            jsr   PUTC1
            bra   :next
:plain      lda   SD_CH
            ora   #$80
            jsr   PUTC1
            bra   :next
:two        lda   #"\"
            jsr   PUTC1
            lda   SD_CH
            cmp   #$5C
            bne   :letter
            lda   #"\"
            jsr   PUTC1
            bra   :next
:letter     sec
            sbc   #7
            tax
            lda   LESC,x
            jsr   PUTC1
:next       jsr   WKINC
            jmp   :lp
:end        lda   #"$"
            jsr   PUTC1
            lda   #$8D
            jmp   PUTC1
LESC        asc   "abt?vfn"          ;$07 $08 $09 - $0B $0C $0D

*---------------------------------------------------------------
* YTRANS -- the y command: every byte of the pattern space
* found in the source string (CP1) becomes the byte at the
* same offset of the destination string (CP2), in place.
*---------------------------------------------------------------
YTRANS      jsr   MATERIAL
            lda   LINEPTR
            sta   SD_WK
            lda   LINEPTR+1
            sta   SD_WK+1
            ldx   CURCMD
            lda   CP1L,x
            sta   SD_WK2
            lda   CP1H,x
            sta   SD_WK2+1
            lda   CP2L,x
            sta   SD_TMP
            lda   CP2H,x
            sta   SD_TMP+1
:lp         lda   (SD_WK)
            beq   :done
            ldy   #0
:scan       lda   (SD_WK2),y
            beq   :next
            cmp   (SD_WK)
            beq   :hit
            iny
            bne   :scan
:hit        lda   (SD_TMP),y
            sta   (SD_WK)
:next       jsr   WKINC
            bra   :lp
:done       rts
