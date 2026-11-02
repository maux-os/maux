*---------------------------------------------------------------
* makeprt.s -- -p: the macro definitions and the target
* descriptions.
*
* Split out of makeinf.s for as's 16,128-byte source window
* (check-dialect 3b): as holds the MANIFEST resident and
* streams each `put` one at a time, so the charge is the
* manifest plus the LARGEST put.
*---------------------------------------------------------------

*---------------------------------------------------------------
* MK_PRINT -- -p: the macro definitions and target descriptions,
* on standard output. POSIX asks for "the complete set", so the
* macro VALUES are printed RAW, unexpanded: that is what the
* makefile says, and what it expands to depends on which target
* is being made.
*---------------------------------------------------------------
MK_PRINT    stz   SPI
:mloop      lda   SPI
            cmp   NMACROS
            bcs   :rules
            tax
            lda   MAC_NAME,x
            sta   PTR0
            lda   MAC_NAME+MK_MAXMAC,x
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #<EQMSG
            sta   PTR0
            lda   #>EQMSG
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            ldx   SPI
            lda   MAC_VAL,x
            sta   PTR0
            lda   MAC_VAL+MK_MAXMAC,x
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            jsr   MK_PRCR
            inc   SPI
            bra   :mloop
:rules      stz   SPI
:rloop      lda   SPI
            cmp   NRULES
            bcc   :onerule
            rts
:onerule    tax
            lda   RULE_TGT,x
            sta   PTR0
            lda   RULE_TGT+MK_MAXRULE,x
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #<COLONMSG
            sta   PTR0
            lda   #>COLONMSG
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
*-- the dependencies EXPANDED, because that is the description
*-- make will actually walk
            lda   SPI
            sta   MK_RULEI
            stz   DEPTH
            jsr   MK_EXPDEPS
            lda   MK_DEPN
            beq   :nodeps
            sta   MK_QN
            jsr   MK_DEPFRST
:dep        lda   PTR2
            sta   PTR0
            lda   PTR2+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   MK_SKIPP2
            dec   MK_QN
            bne   :dep
:nodeps     jsr   MK_PRCR
            ldx   SPI
            lda   RULE_NCMD,x
            beq   :rnext
            sta   MK_CMDN
            lda   RULE_CMD,x
            sta   MK_CMDP
            lda   RULE_CMD+MK_MAXRULE,x
            sta   MK_CMDP+1
:cmd        lda   #$89
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   MK_CMDP
            sta   PTR0
            lda   MK_CMDP+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            jsr   MK_PRCR
            dec   MK_CMDN
            beq   :rnext
            jsr   MK_SKIPCM
            bra   :cmd
:rnext      inc   SPI
            jmp   :rloop

MK_PRCR     lda   #$8D
            ldx   #FD_STDOUT
            jmp   PUTC

EQMSG       asc   " = "
            dfb   0
COLONMSG    asc   ": "
            dfb   0
MANYSUFMSG  asc   "make: too many suffixes"
            dfb   $8D,$00
SUFFIXNM    asc   ".SUFFIXES"
            dfb   0
SILENTNM    asc   ".SILENT"
            dfb   0
IGNORENM    asc   ".IGNORE"
            dfb   0
DEFAULTNM   asc   ".DEFAULT"
            dfb   0
