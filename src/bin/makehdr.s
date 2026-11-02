*---------------------------------------------------------------
* makehdr.s -- the rule header: several targets, the raw
* dependency text, and the `;` inline command.
*
* Split out of makeread.s for as's 16,128-byte source window
* (check-dialect 3b): as holds the MANIFEST resident and
* streams each `put` one at a time, so the charge is the
* manifest plus the LARGEST put.
*---------------------------------------------------------------

*---------------------------------------------------------------
* MK_RULEHDR -- parse `target ... : dep ... [; command]`.
*
* A rule with no ':' at all is a syntax error rather than a
* silently ignored line -- a makefile that does not parse should
* say so, not do nothing.
*---------------------------------------------------------------
MK_RULEHDR  jsr   MK_LINEEND
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
:findcol    jsr   MK_ATEOL
            bcs   :incol
            jmp   MK_NOCOLON
:incol
            lda   (PTR1)
            cmp   #$BA                 ;':'
            beq   :gotcol
            jsr   MK_P1INC
            bra   :findcol
:gotcol     lda   #0
            sta   (PTR1)               ;ends the TARGET FIELD
            jsr   MK_P1INC
            lda   PTR1
            sta   HDR_DEP
            lda   PTR1+1
            sta   HDR_DEP+1
*-- the target field, split on blanks: one rule per name, all of
*-- them sharing this header's dependencies and recipe
            lda   NRULES
            sta   HDR_FIRST
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
:tloop      lda   (PTR1)
            beq   :tdone
            cmp   #$A0
            beq   :tblank
            cmp   #$89
            bne   :tstart
:tblank     jsr   MK_P1INC
            bra   :tloop
:tstart     lda   PTR1
            sta   HDR_TGT
            lda   PTR1+1
            sta   HDR_TGT+1
            stz   HDR_HASD
:tscan      lda   (PTR1)
            beq   :taddr
            cmp   #$A0
            beq   :tcut
            cmp   #$89
            beq   :tcut
            cmp   #$A4                 ;'$'
            bne   :tnext
            inc   HDR_HASD
:tnext      jsr   MK_P1INC
            bra   :tscan
:tcut       lda   #0
            sta   (PTR1)
            jsr   MK_P1INC
:taddr      jsr   MK_ADDRULE
            bra   :tloop
:tdone      lda   NRULES
            cmp   HDR_FIRST
            bne   :havetgt
            jmp   MK_NOTGT
:havetgt
            jmp   MK_HDRDEPS

*---------------------------------------------------------------
* MK_ADDRULE -- one rule, target HDR_TGT, dependencies HDR_DEP.
* PTR0/PTR1 are the header's own cursors and MK_EXPTGT needs
* both, so they are parked here rather than in the caller.
*---------------------------------------------------------------
MK_ADDRULE  lda   PTR0
            sta   HDR_SV0
            lda   PTR0+1
            sta   HDR_SV0+1
            lda   PTR1
            sta   HDR_SV1
            lda   PTR1+1
            sta   HDR_SV1+1
            lda   NRULES
            cmp   #MK_MAXRULE
            bcc   :haveroom
            jmp   MK_TOOMANY
:haveroom
            lda   HDR_HASD
            beq   :plain
            jsr   MK_EXPTGT
:plain      ldx   NRULES
            lda   HDR_TGT
            sta   RULE_TGT,x
            lda   HDR_TGT+1
            sta   RULE_TGT+MK_MAXRULE,x
            lda   HDR_DEP
            sta   RULE_DEP,x
            lda   HDR_DEP+1
            sta   RULE_DEP+MK_MAXRULE,x
            stz   RULE_NCMD,x
            stz   RULE_MADE,x
            inc   NRULES
            lda   HDR_SV0
            sta   PTR0
            lda   HDR_SV0+1
            sta   PTR0+1
            lda   HDR_SV1
            sta   PTR1
            lda   HDR_SV1+1
            sta   PTR1+1
            rts

*---------------------------------------------------------------
* MK_EXPTGT -- a target that contains a '$' cannot be left in
* place, so its expansion is appended to MK_NAMES and the rule
* points there. Only such a target costs the arena anything,
* which is why the check is a scan for one byte.
*---------------------------------------------------------------
MK_EXPTGT   lda   HDR_TGT
            sta   PTR0
            lda   HDR_TGT+1
            sta   PTR0+1
            lda   MK_NAMESP
            sta   PTR1
            sta   HDR_TGT
            lda   MK_NAMESP+1
            sta   PTR1+1
            sta   HDR_TGT+1
            clc
            lda   #<MK_NAMES
            adc   #<MK_NAMLIM
            sta   EXP_END
            lda   #>MK_NAMES
            adc   #>MK_NAMLIM
            sta   EXP_END+1
            stz   EXP_SEMI
            jsr   MK_EXPAND
            inc   PTR1                 ;past the NUL it wrote
            bne   :nc
            inc   PTR1+1
:nc         lda   PTR1
            sta   MK_NAMESP
            lda   PTR1+1
            sta   MK_NAMESP+1
            rts

*---------------------------------------------------------------
* MK_HDRDEPS -- the dependency text. It is not split here (a
* macro can expand to any number of names); all this does is
* find the inline `;` command and cut a trailing `#` comment.
*---------------------------------------------------------------
MK_HDRDEPS  lda   HDR_DEP
            sta   PTR1
            lda   HDR_DEP+1
            sta   PTR1+1
            stz   HDR_SEMI
            stz   HDR_SEMI+1
:dscan      jsr   MK_ATEOL
            bcc   :ddone
            lda   (PTR1)
            cmp   #$A3                 ;'#' ends the line here
            beq   :dcomm
            cmp   #$BB                 ;';'
            bne   :dnext
            lda   HDR_SEMI
            ora   HDR_SEMI+1
            bne   :dnext
            jsr   MK_P1INC
*-- the command starts at the first non-blank after the ';', not
*-- at the blank itself: `ALL: ; cmd` must spawn `cmd`, and echo
*-- it without a leading space
:dsblank    lda   (PTR1)
            cmp   #$A0
            beq   :dsskip
            cmp   #$89
            bne   :dsgot
:dsskip     jsr   MK_P1INC
            bra   :dsblank
:dsgot      lda   PTR1
            sta   HDR_SEMI
            lda   PTR1+1
            sta   HDR_SEMI+1
            bra   :dscan
:dnext      jsr   MK_P1INC
            bra   :dscan
:dcomm      lda   #0
            sta   (PTR1)
            bra   :dfin
*-- an inline command needs a terminator of its own, and the
*-- line's own CR is it
:ddone      lda   HDR_SEMI
            ora   HDR_SEMI+1
            beq   :dfin
            lda   HDR_EOL
            sta   PTR1
            lda   HDR_EOL+1
            sta   PTR1+1
            lda   (PTR1)
            beq   :dfin
            lda   #0
            sta   (PTR1)
:dfin       lda   HDR_SEMI
            ora   HDR_SEMI+1
            beq   :dnone
            lda   HDR_SEMI
            sta   HDR_CMDP
            lda   HDR_SEMI+1
            sta   HDR_CMDP+1
            jsr   MK_SETCMD
:dnone      lda   HDR_NEXT
            sta   PTR0
            lda   HDR_NEXT+1
            sta   PTR0+1
            rts

MK_NOTGT    lda   #<NOTGTMSG
            ldx   #>NOTGTMSG
            jmp   MK_DIE
MK_NOCOLON  lda   #<SYNTAXMSG
            ldx   #>SYNTAXMSG
            jmp   MK_DIE
MK_TOOMANY  lda   #<TOOMANYMSG
            ldx   #>TOOMANYMSG
            jmp   MK_DIE
MK_TOOBIG   lda   #<TOOBIGMSG
            ldx   #>TOOBIGMSG
            jmp   MK_DIE
MK_NOFILE   lda   #<NOFILEMSG
            ldx   #>NOFILEMSG
            jmp   MK_DIE

MK_DIE      sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

DFLTMK      asc   "MAKEFILE"
            dfb   0
USAGEMSG    asc   "usage: make [-eikNnpqrSst] [-f file] "
            asc   "[NAME=value ...] [target ...]"
            dfb   $8D,$00
SYNTAXMSG   asc   "make: rule line has no ':'"
            dfb   $8D,$00
NOTGTMSG    asc   "make: rule line has no target"
            dfb   $8D,$00
TOOMANYMSG  asc   "make: too many rules or dependencies"
            dfb   $8D,$00
TOOBIGMSG   asc   "make: makefile too large"
            dfb   $8D,$00
NOFILEMSG   asc   "make: cannot open makefile"
            dfb   $8D,$00

MKOPARM        dfb   PCOUNT_OPEN
MKOPARM_PATH   da    PATHBUF
MKOPARM_IOBF   da    $0000
MKOPARM_REF    dfb   0
MKRPARM        dfb   PCOUNT_READ
MKRPARM_REF    dfb   0
MKRPARM_BUF    da    0
MKRPARM_REQ    da    0
MKRPARM_TRN    da    0
MKCPARM        dfb   PCOUNT_CLOSE
MKCPARM_REF    dfb   0
