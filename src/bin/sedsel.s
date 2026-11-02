*---------------------------------------------------------------
* sedsel.s -- sed's selection and substitution half, `put` by
* src/bin/sed.s after sedexec.s (NOT a standalone binary):
* CHKSEL (does this command's address select the line, with
* the classic two-address range state), DOSUBST (s///), and
* the pattern-space writers PRINTLINE/WRITEPS.
*---------------------------------------------------------------
* CHKSEL -- does command CURCMD's address select the current
* line? OUT: carry SET = selected (before '!'). Maintains CACT
* range state. CLOBBERS everything (RE_MATCH under the address
* REs); CURCMD is the durable cursor, reloaded after every call
* out.
*---------------------------------------------------------------
CHKSEL      ldx   CURCMD
            lda   CA1T,x
            bne   :haveaddr
            sec                      ;no address: every line
            rts
:haveaddr   lda   CA2T,x
            bne   :range
            jmp   MATCHA1            ;single addr: its carry IS
                                     ;the answer
:range      lda   CACT,x
            bne   :active
            jsr   MATCHA1
            bcs   :activate
            clc
            rts
:activate   ldx   CURCMD
            lda   #1
            sta   CACT,x
            lda   CA2T,x             ;numeric addr2 <= this
            cmp   #1                 ;line: one-line range
            bne   :selyes            ;(classic rule)
            jsr   LINEGEA2
            bcc   :selyes
            ldx   CURCMD
            stz   CACT,x
:selyes     sec
            rts
:active     lda   CA2T,x             ;selected; now decide
            cmp   #1                 ;whether the range ENDS
            beq   :endnum            ;here
            cmp   #2
            beq   :endre
            lda   LASTFLG            ;'$'
            beq   :selyes
            ldx   CURCMD
            stz   CACT,x
            bra   :selyes
:endnum     jsr   LINEGEA2
            bcc   :selyes
            ldx   CURCMD
            stz   CACT,x
            bra   :selyes
:endre      lda   CA2VL,x
            sta   PTR1
            lda   CA2VH,x
            sta   PTR1+1
            jsr   REONLINE           ;carry SET = addr2 matches:
            bcc   :selyes            ;the range ends HERE. (The
            ldx   CURCMD             ;first sed had this branch
            stz   CACT,x             ;inverted -- no gate staged
            bra   :selyes            ;a regex addr2 until 09-11)

* -- MATCHA1: carry SET = addr1 matches the current line.
MATCHA1     ldx   CURCMD
            lda   CA1T,x
            cmp   #1
            beq   :num
            cmp   #2
            beq   :re
            lda   LASTFLG            ;'$'
            beq   :no
            sec
            rts
:num        lda   LINENO
            cmp   CA1VL,x
            bne   :no
            lda   LINENO+1
            cmp   CA1VH,x
            bne   :no
            sec
            rts
:re         lda   CA1VL,x
            sta   PTR1
            lda   CA1VH,x
            sta   PTR1+1
            jmp   REONLINE
:no         clc
            rts

* -- LINEGEA2: carry SET = LINENO >= addr2's number.
LINEGEA2    ldx   CURCMD
            lda   LINENO
            cmp   CA2VL,x
            lda   LINENO+1
            sbc   CA2VH,x
            rts

* -- REONLINE: PTR1 = pattern (0 = the last RE used); carry
* -- SET = it matches the pattern space somewhere. (RE_MATCH's
* -- own carry is CLEAR on match; this normalizes to CHKSEL's
* -- selected-is-set convention.)
REONLINE    jsr   REPTR
            lda   LINEPTR
            sta   PTR0
            sta   PTR2
            lda   LINEPTR+1
            sta   PTR0+1
            sta   PTR2+1
            jsr   RE_MATCH
            bcc   :hit
            clc
            rts
:hit        sec
            rts

* -- REPTR: PTR1 = 0 means "the last RE used" (POSIX's empty
* -- RE); otherwise PTR1 becomes the last RE used. No RE yet
* -- is a loud E_NOPREV.
REPTR       lda   PTR1
            ora   PTR1+1
            beq   :last
            lda   PTR1
            sta   LASTRE
            lda   PTR1+1
            sta   LASTRE+1
            rts
:last       lda   LASTRE
            ora   LASTRE+1
            beq   :none
            lda   LASTRE
            sta   PTR1
            lda   LASTRE+1
            sta   PTR1+1
            rts
:none       lda   #E_NOPREV
            jmp   RUNERR

*---------------------------------------------------------------
* DOSUBST -- s/re/repl/[flags] over the pattern space. The
* result is built in the scratch arena (SCRPTR) through SUBPUT,
* bounded at PSMAX (overflow is a LOUD E_PSOVF, never a
* truncation); on a hit the arenas ROTATE -- the scratch becomes
* the pattern space, the old pattern-space arena the scratch --
* so nothing is copied back. A hit sets the t flag and honours
* the p and w flags.
*---------------------------------------------------------------
DOSUBST     stz   SUBHIT
            stz   SUBOCC
            stz   SUBOCC+1
            lda   SCRPTR
            sta   SD_DST
            lda   SCRPTR+1
            sta   SD_DST+1
            jsr   SETLIM
            lda   LINEPTR
            sta   SD_SRC
            sta   PTR2
            lda   LINEPTR+1
            sta   SD_SRC+1
            sta   PTR2+1
:again      lda   LINEPTR
            sta   PTR0
            lda   LINEPTR+1
            sta   PTR0+1
            ldx   CURCMD
            lda   CP1L,x
            sta   PTR1
            lda   CP1H,x
            sta   PTR1+1
            jsr   REPTR
            jsr   RE_MATCH
            bcc   :matched           ;bcs/jmp trampoline --
            jmp   :nomore            ;:nomore is out of range
:matched    lda   RE_MSTART          ;copy the gap up to the
            sta   SD_BND             ;match verbatim
            lda   RE_MSTART+1
            sta   SD_BND+1
            jsr   SBVERB
* -- POSIX: a NULL match immediately after the previous
* -- replacement's end is IGNORED (not replaced, not counted):
* -- s/l*/X/g on "hello" is XhXeXoX, not XhXeXXoX
* -- (learning:01M0NZYZWNEG828YMK57AG5PJN).
            lda   RE_MSTART
            cmp   RE_MEND
            bne   :notnull
            lda   RE_MSTART+1
            cmp   RE_MEND+1
            bne   :notnull
            lda   SUBHIT             ;LASTMEND is written by
            beq   :notnull           ;every :doit, so SUBHIT=1
            lda   RE_MSTART          ;guards the read
            cmp   LASTMEND
            bne   :notnull
            lda   RE_MSTART+1
            cmp   LASTMEND+1
            bne   :notnull
            jmp   :zladv             ;emit the char, advance
:notnull    ldx   CURCMD
            lda   CNUML,x
            ora   CNUMH,x
            beq   :doit              ;no N: every selected match
            inc   SUBOCC
            bne   :occnc
            inc   SUBOCC+1
:occnc      ldx   CURCMD
            lda   SUBOCC+1
            cmp   CNUMH,x
            bcc   :skip              ;before the Nth
            bne   :later
            lda   SUBOCC
            cmp   CNUML,x
            bcc   :skip
            beq   :doit              ;this IS the Nth
:later      lda   CFLG,x             ;past the Nth: only with g
            and   #SF_G              ;(GNU's Ng: the Nth and
            bne   :doit              ;every later one)
:skip       lda   RE_MEND            ;not selected -- keep the
            sta   SD_BND             ;match text itself
            lda   RE_MEND+1
            sta   SD_BND+1
            jsr   SBVERB
            bra   :zladv
:doit       lda   #1
            sta   SUBHIT
            jsr   SBEXPAND
            lda   RE_MEND
            sta   SD_SRC
            sta   LASTMEND           ;the null-adjacent rule
            lda   RE_MEND+1          ;above reads this back
            sta   SD_SRC+1
            sta   LASTMEND+1
            ldx   CURCMD
            lda   CFLG,x
            and   #SF_G
            beq   :nomore            ;no g: one substitution
:zladv      lda   RE_MEND            ;zero-length match must
            cmp   RE_MSTART          ;advance by hand or spin
            bne   :advance
            lda   RE_MEND+1
            cmp   RE_MSTART+1
            bne   :advance
            lda   (SD_SRC)
            beq   :nomore
            jsr   SUBPUT
            inc   SD_SRC
            bne   :advance
            inc   SD_SRC+1
:advance    lda   SD_SRC
            sta   PTR2
            lda   SD_SRC+1
            sta   PTR2+1
            jmp   :again

:nomore     lda   SUBHIT
            bne   :hadhit
            rts                      ;no match: line untouched
:hadhit     jsr   SBTAIL
            lda   #0
            sta   (SD_DST)
            ldx   #1                 ;rotate: scratch -> pattern
:rot        lda   SCRPTR,x           ;space, old one -> scratch
            ldy   PSOWN,x
            sta   PSOWN,x
            sta   LINEPTR,x
            tya
            sta   SCRPTR,x
            dex
            bpl   :rot
            lda   #1
            sta   TFLAG
            ldx   CURCMD
            lda   CFLG,x
            and   #SF_P
            beq   :nop
            jsr   PRINTLINE
:nop        ldx   CURCMD
            lda   CFLG,x
            and   #SF_W
            beq   :now
            ldy   CWFD,x
            ldx   WFFD,y
            jsr   WRITEPS
:now        rts

* -- SBVERB: SUBPUT bytes from (SD_SRC) until it reaches
* -- SD_BND. Leaves SD_SRC = SD_BND.
SBVERB
:lp         lda   SD_SRC
            cmp   SD_BND
            bne   :go
            lda   SD_SRC+1
            cmp   SD_BND+1
            bne   :go
            rts
:go         lda   (SD_SRC)
            jsr   SUBPUT
            inc   SD_SRC
            bne   :lp
            inc   SD_SRC+1
            bra   :lp

* -- SBTAIL: SUBPUT bytes from (SD_SRC) to its NUL.
SBTAIL
:lp         lda   (SD_SRC)
            beq   :done
            jsr   SUBPUT
            inc   SD_SRC
            bne   :lp
            inc   SD_SRC+1
            bra   :lp
:done       rts

* -- SBEXPAND: the replacement (CP2): '&' = the matched text,
* -- '\1'-'\9' = that group's text (empty if it did not take
* -- part), '\n' = newline, '\X' = literal X (so '\&', '\\' and
* -- a backslash-newline all do what POSIX says).
SBEXPAND    ldx   CURCMD
            lda   CP2L,x
            sta   SD_REP
            lda   CP2H,x
            sta   SD_REP+1
:lp         lda   (SD_REP)
            beq   :done
            cmp   #"&"
            beq   :amp
            cmp   #"\"
            beq   :esc
            jsr   SUBPUT
:next       inc   SD_REP
            bne   :lp
            inc   SD_REP+1
            bra   :lp
:amp        lda   RE_MSTART
            sta   SD_AMP
            lda   RE_MSTART+1
            sta   SD_AMP+1
            lda   RE_MEND
            sta   SD_TMP
            lda   RE_MEND+1
            sta   SD_TMP+1
            jsr   COPYRNG
            bra   :next
:esc        ldy   #1
            lda   (SD_REP),y
            beq   :lonebs            ;trailing '\': literal
            cmp   #"n"
            bne   :notn
            lda   #$8D
            bra   :putesc
:notn       cmp   #"1"
            bcc   :putesc
            cmp   #"9"+1
            bcs   :putesc
            and   #$0F               ;group N -> RE_GRPST index
            sec
            sbc   #1
            asl   a
            tax
            lda   RE_GRPST+1,x
            cmp   #$FF               ;never captured: empty
            beq   :esc2
            lda   RE_GRPST,x
            sta   SD_AMP
            lda   RE_GRPST+1,x
            sta   SD_AMP+1
            lda   RE_GRPEND,x
            sta   SD_TMP
            lda   RE_GRPEND+1,x
            sta   SD_TMP+1
            jsr   COPYRNG
            bra   :esc2
:putesc     jsr   SUBPUT
:esc2       clc
            lda   SD_REP
            adc   #2
            sta   SD_REP
            lda   SD_REP+1
            adc   #0
            sta   SD_REP+1
            jmp   :lp
:lonebs     lda   #"\"
            jsr   SUBPUT
            bra   :next
:done       rts

* -- COPYRNG: SUBPUT the bytes [SD_AMP, SD_TMP).
COPYRNG     lda   SD_AMP
            cmp   SD_TMP
            bne   :go
            lda   SD_AMP+1
            cmp   SD_TMP+1
            beq   :done
:go         lda   (SD_AMP)
            jsr   SUBPUT
            inc   SD_AMP
            bne   COPYRNG
            inc   SD_AMP+1
            bra   COPYRNG
:done       rts

* -- SUBPUT: A -> (SD_DST)++; reaching SD_LIM is fatal and loud
* -- (E_PSOVF does not return).
SUBPUT      pha
            lda   SD_DST
            cmp   SD_LIM
            bne   :fits
            lda   SD_DST+1
            cmp   SD_LIM+1
            beq   :ovf
:fits       pla
            sta   (SD_DST)
            inc   SD_DST
            bne   :r
            inc   SD_DST+1
:r          rts
:ovf        lda   #E_PSOVF
            jmp   RUNERR

* -- SETLIM: SD_LIM = SD_DST + PSMAX (the arena's last byte,
* -- reserved for the NUL).
SETLIM      clc
            lda   SD_DST
            adc   #<PSMAX
            sta   SD_LIM
            lda   SD_DST+1
            adc   #>PSMAX
            sta   SD_LIM+1
            rts

*---------------------------------------------------------------
* PRINTLINE -- pattern space + CR to stdout.
* WRITEPS   -- pattern space + CR to fd X.
* PUTC1     -- A to stdout.
*---------------------------------------------------------------
PRINTLINE   ldx   #FD_STDOUT
WRITEPS     stx   WRFD
            lda   LINEPTR
            sta   PTR0
            lda   LINEPTR+1
            sta   PTR0+1
            jsr   PUTS
            lda   #$8D
            ldx   WRFD
            jmp   PUTC

PUTC1       ldx   #FD_STDOUT
            jmp   PUTC
