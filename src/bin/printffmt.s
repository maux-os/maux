*---------------------------------------------------------------
* printffmt.s -- printf's %-directive parser: the flags/width/
* precision scan (PF_DOCONV) and its dispatch to the conversion
* handlers, plus the once-per-run HASCONV prescan (PF_PRESCAN)
* and CONSUME_ARG. `put` by src/bin/printf.s (NOT a standalone
* binary -- the same put-module shape as cut.s/cutlist.s and
* xargs.s/xargstok.s). THREE-WAY split, not two: printf.s's own
* resident text (6.4KB stripped) left under 10KB of headroom
* against the native assembler's 16128-byte window, and the
* numeric-argument engine alone (parsing plus three digit-string
* builders) already ran ~22KB in one file -- one `put` module
* over budget defeats the split's whole purpose, since `as`
* holds exactly one put file's text at a time (docs/S9-PLAN.md
* sec 5). The other two pieces: src/bin/printfnum.s (PFNUM, the
* octal/decimal/hex digit builders, PF_EMITNUM) and
* src/bin/printfcnv.s (the per-conversion handlers and %b's own
* escape engine) -- put by printf.s right after this file. Every
* symbol in all three resolves against printf.s's own zero page
* (PF_FMT/PF_BARG), equates and `dum` cells; see that file's own
* header for the escape/conversion contract.
*---------------------------------------------------------------
EMPTYSTR    dfb   0
ERRPRE      asc   "printf: "
            dfb   0
ERRSUF      asc   ": expected numeric value"
            dfb   $8D,0
ERRCONV     asc   "printf: unknown format character"
            dfb   $8D,0

*---------------------------------------------------------------
* CONSUME_ARG -- OUT: PTR0 = argv[ARGIDX], or EMPTYSTR if none
* remain; ARGIDX incremented either way (the task's own rule: a
* missing argument is the empty string / 0, and format reuse
* keeps consuming argv positions past the end so a later pass
* cannot suddenly find them again). Also sets HADARG (1 = a real
* argument was there, 0 = defaulted) -- PF_NUMCONV needs this: a
* MISSING numeric argument is silently 0, no diagnostic at all
* (checked live against this host's own /usr/bin/printf), where
* a PRESENT but non-numeric one IS diagnosed. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
CONSUME_ARG lda   ARGIDX
            cmp   ARGC
            bcs   :none
            jsr   GETARG
            inc   ARGIDX
            lda   #1
            sta   HADARG
            rts
:none       inc   ARGIDX
            stz   HADARG
            lda   #<EMPTYSTR
            sta   PTR0
            lda   #>EMPTYSTR
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* PF_MUL10B -- A := A*10 (8-bit, truncated -- width/precision
* values this small never need more). CLOBBERS: A.
*---------------------------------------------------------------
PF_MUL10B   asl   a
            sta   PF_T3
            asl   a
            asl   a
            clc
            adc   PF_T3
            rts

*---------------------------------------------------------------
* PF_PRESCAN -- sets HASCONV if the format (FMTBASE) contains at
* least one argument-consuming conversion (%% does not count).
* Computed ONCE, before the reuse loop -- the format text itself
* never changes across passes. CLOBBERS: A, X, Y, PF_FMT.
*---------------------------------------------------------------
PF_PRESCAN  stz   HASCONV
            lda   FMTBASE
            sta   PF_FMT
            lda   FMTBASE+1
            sta   PF_FMT+1
:pl         ldy   #0
            lda   (PF_FMT),y
            bne   :pnz
            jmp   :pdn
:pnz        cmp   #$A5
            beq   :pisp
            jmp   :pa1
:pisp       jsr   PF_ADVFMT
:pfl        ldy   #0
            lda   (PF_FMT),y
            cmp   #$AD
            beq   :pfa
            cmp   #$AB
            beq   :pfa
            cmp   #$A0
            beq   :pfa
            cmp   #$A3
            beq   :pfa
            cmp   #$B0
            beq   :pfa
            bra   :pfld
:pfa        jsr   PF_ADVFMT
            bra   :pfl
:pfld       ldy   #0
            lda   (PF_FMT),y
            cmp   #$B0
            bcc   :pwd
            cmp   #$BA
            bcs   :pwd
            jsr   PF_ADVFMT
            bra   :pfld
:pwd        ldy   #0
            lda   (PF_FMT),y
            cmp   #$AE
            bne   :pcv
            jsr   PF_ADVFMT
:ppl        ldy   #0
            lda   (PF_FMT),y
            cmp   #$B0
            bcc   :pcv
            cmp   #$BA
            bcs   :pcv
            jsr   PF_ADVFMT
            bra   :ppl
:pcv        ldy   #0
            lda   (PF_FMT),y
            bne   :pcnz
            jmp   :pdn
:pcnz       jsr   PF_ADVFMT
            cmp   #$A5
            bne   :pcn2
            jmp   :pl
:pcn2       cmp   #$E4
            beq   :pmk
            cmp   #$E9
            beq   :pmk
            cmp   #$EF
            beq   :pmk
            cmp   #$F5
            beq   :pmk
            cmp   #$F8
            beq   :pmk
            cmp   #$D8
            beq   :pmk
            cmp   #$E3
            beq   :pmk
            cmp   #$F3
            beq   :pmk
            cmp   #$E2
            beq   :pmk
            jmp   :pl
:pmk        lda   #1
            sta   HASCONV
            jmp   :pl
:pa1        jsr   PF_ADVFMT
            jmp   :pl
:pdn        rts

*---------------------------------------------------------------
* PF_DOCONV -- one %-directive; PF_FMT is just past the '%'.
* Parses flags, width, precision, the conversion character, and
* dispatches; each handler consumes an argument (except %% and
* an unrecognised character) and prints the whole field.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PF_DOCONV   stz   PF_FLNEG
            stz   PF_FLPLUS
            stz   PF_FLSPC
            stz   PF_FLHASH
            stz   PF_FLZERO
            stz   PF_WIDTH
            stz   PF_HASPREC
            stz   PF_PREC
:dflg       ldy   #0
            lda   (PF_FMT),y
            cmp   #$AD
            bne   :df2
            lda   #1
            sta   PF_FLNEG
            jsr   PF_ADVFMT
            bra   :dflg
:df2        cmp   #$AB
            bne   :df3
            lda   #1
            sta   PF_FLPLUS
            jsr   PF_ADVFMT
            bra   :dflg
:df3        cmp   #$A0
            bne   :df4
            lda   #1
            sta   PF_FLSPC
            jsr   PF_ADVFMT
            bra   :dflg
:df4        cmp   #$A3
            bne   :df5
            lda   #1
            sta   PF_FLHASH
            jsr   PF_ADVFMT
            bra   :dflg
:df5        cmp   #$B0
            bne   :dfd
            lda   #1
            sta   PF_FLZERO
            jsr   PF_ADVFMT
            bra   :dflg
:dfd        ldy   #0
            lda   (PF_FMT),y
            cmp   #$B0
            bcc   :dwd
            cmp   #$BA
            bcs   :dwd
            and   #$0F
            sta   PF_TMP
            lda   PF_WIDTH
            jsr   PF_MUL10B
            clc
            adc   PF_TMP
            sta   PF_WIDTH
            jsr   PF_ADVFMT
            bra   :dfd
:dwd        ldy   #0
            lda   (PF_FMT),y
            cmp   #$AE
            bne   :dpd
            jsr   PF_ADVFMT
            lda   #1
            sta   PF_HASPREC
:dpl        ldy   #0
            lda   (PF_FMT),y
            cmp   #$B0
            bcc   :dpd
            cmp   #$BA
            bcs   :dpd
            and   #$0F
            sta   PF_TMP
            lda   PF_PREC
            jsr   PF_MUL10B
            clc
            adc   PF_TMP
            sta   PF_PREC
            jsr   PF_ADVFMT
            bra   :dpl
:dpd        ldy   #0
            lda   (PF_FMT),y
            beq   :dnc
            sta   PF_CONVCH
            jsr   PF_ADVFMT
            lda   PF_CONVCH
            cmp   #$E4
            bne   :dc2
            jmp   PF_DO_D
:dc2        cmp   #$E9
            bne   :dc3
            jmp   PF_DO_D
:dc3        cmp   #$EF
            bne   :dc4
            jmp   PF_DO_O
:dc4        cmp   #$F5
            bne   :dc5
            jmp   PF_DO_U
:dc5        cmp   #$F8
            bne   :dc6
            jmp   PF_DO_X
:dc6        cmp   #$D8
            bne   :dc7
            jmp   PF_DO_XU
:dc7        cmp   #$E3
            bne   :dc8
            jmp   PF_DO_C
:dc8        cmp   #$F3
            bne   :dc9
            jmp   PF_DO_S
:dc9        cmp   #$E2
            bne   :dc10
            jmp   PF_DO_B
:dc10       cmp   #$A5
            bne   :dc11
            jmp   PF_DO_PCT
:dc11       jmp   PF_BADCONV
:dnc        jmp   PF_BADCONV

*---------------------------------------------------------------
* PF_BADCONV -- an unrecognised conversion character, or a bare
* trailing '%' with nothing after it. Diagnostic, sticky exit 1,
* nothing printed for this directive (this build never learned
* what it would even consume). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PF_BADCONV  lda   #1
            sta   BADNUM
            lda   #<ERRCONV
            sta   PTR0
            lda   #>ERRCONV
            sta   PTR0+1
            ldx   #FD_STDERR
            jmp   PUTS

*---------------------------------------------------------------
* PF_NUMCONV -- consumes the next argument and parses it into
* PF_NUMVAL (PFNUM's own contract); on failure, a diagnostic
* (naming the offending argument text) to stderr and sticky
* BADNUM, but PF_NUMVAL is already 0 either way. A MISSING
* argument (HADARG clear) is silently 0 -- no diagnostic, no
* BADNUM -- the task's own rule, and this host's own printf
* agrees (checked live: `printf '%d\n'` alone prints "0", exit
* 0, nothing on stderr). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PF_NUMCONV  jsr   CONSUME_ARG
            lda   HADARG
            bne   :ncgo
            stz   PF_NUMVAL
            stz   PF_NUMVAL+1
            rts
:ncgo       lda   PTR0
            sta   PF_BADP
            lda   PTR0+1
            sta   PF_BADP+1
            jsr   PFNUM
            bcc   :nok
            lda   #1
            sta   BADNUM
            lda   #<ERRPRE
            sta   PTR0
            lda   #>ERRPRE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   PF_BADP
            sta   PTR0
            lda   PF_BADP+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<ERRSUF
            sta   PTR0
            lda   #>ERRSUF
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
:nok        rts

*---------------------------------------------------------------
* PFNUM -- IN: PTR0 = argument text. OUT: PF_NUMVAL = its 16-bit
* machine value, carry clear; or PF_NUMVAL = 0, carry SET on any
* failure (empty, non-decimal, trailing garbage after the
* digits, or a magnitude too big for this machine's one 16-bit
* register -- over 65535 unsigned, or over 32768 negated). A
* leading "'c or "c (POSIX's own extension) takes the following
* byte's value, low 7 bits, unconditionally -- never a failure,
* matching this host's own /usr/bin/printf (checked live).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PFNUM       ldy   #0
            lda   (PTR0),y
            bne   :n1nz
            jmp   :nbad
:n1nz       cmp   #$A7
            beq   :nisq
            cmp   #$A2
            bne   :nnq
            jmp   :nq
:nisq       jmp   :nq
:nnq        stz   PF_NSIGN
            cmp   #$AB
            beq   :nsk
            cmp   #$AD
            bne   :nns
            lda   #1
            sta   PF_NSIGN
:nsk        iny
:nns        stz   PF_B0
            stz   PF_B1
            stz   PF_B2
            stz   PF_NDIG
:ndl        lda   (PTR0),y
            beq   :nde
            cmp   #$B0
            bcs   :ndg1
            jmp   :nbad
:ndg1       cmp   #$BA
            bcc   :ndg2
            jmp   :nbad
:ndg2       and   #$0F
            sta   PF_TMP
            lda   PF_NDIG
            cmp   #6
            bcc   :ndg3
            jmp   :nbad
:ndg3       lda   PF_TMP
            jsr   PF_ACC10
            inc   PF_NDIG
            iny
            bra   :ndl
:nde        lda   PF_NDIG
            bne   :nde1
            jmp   :nbad
:nde1       lda   PF_NSIGN
            beq   :npos
            lda   PF_B2
            beq   :nde2
            jmp   :nbad
:nde2       lda   PF_B1
            cmp   #$80
            bcc   :nok2
            beq   :nde3
            jmp   :nbad
:nde3       lda   PF_B0
            beq   :nok2
            jmp   :nbad
:nok2       sec
            lda   #0
            sbc   PF_B0
            sta   PF_NUMVAL
            lda   #0
            sbc   PF_B1
            sta   PF_NUMVAL+1
            clc
            rts
:npos       lda   PF_B2
            beq   :npos2
            jmp   :nbad
:npos2      lda   PF_B0
            sta   PF_NUMVAL
            lda   PF_B1
            sta   PF_NUMVAL+1
            clc
            rts
:nq         iny
            lda   (PTR0),y
            and   #$7F
            sta   PF_NUMVAL
            stz   PF_NUMVAL+1
            clc
            rts
:nbad       stz   PF_NUMVAL
            stz   PF_NUMVAL+1
            sec
            rts

