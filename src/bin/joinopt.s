*---------------------------------------------------------------
* joinopt.s -- join's numeric-argument parser and `-o` list
* parser, `put` by src/bin/join.s (NOT a standalone binary --
* same reason and shape as joinio.s's own header). Every symbol
* here resolves against join.s's own equates/bss (ACCLO/ACCHI,
* OLSIDE/OLFLD/OCOUNT, etc.) unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PDOPTARG -- OPTARG into PTR0, then PARSEDEC. Shared by -a/-v/
* -1/-2's numeric-argument handlers.
*---------------------------------------------------------------
PDOPTARG    lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jmp   PARSEDEC

*---------------------------------------------------------------
* PARSEDEC -- IN: PTR0 = digit string. OUT: ACCLO/ACCHI = value,
* Y = digits consumed (0 = none). split.s's own routine.
*---------------------------------------------------------------
PARSEDEC    stz   ACCLO
            stz   ACCHI
            ldy   #0
:lp         lda   (PTR0),y
            beq   :done
            and   #$7F
            cmp   #'0'
            bcc   :done
            cmp   #'9'+1
            bcs   :done
            and   #$0F
            jsr   ACCUM10
            iny
            bra   :lp
:done       rts

ACCUM10     sta   AC_DIGIT
            asl   ACCLO
            rol   ACCHI
            lda   ACCLO
            sta   AC_TWOLO
            lda   ACCHI
            sta   AC_TWOHI
            asl   ACCLO
            rol   ACCHI
            asl   ACCLO
            rol   ACCHI
            clc
            lda   ACCLO
            adc   AC_TWOLO
            sta   ACCLO
            lda   ACCHI
            adc   AC_TWOHI
            sta   ACCHI
            clc
            lda   ACCLO
            adc   AC_DIGIT
            sta   ACCLO
            bcc   :nc
            inc   ACCHI
:nc         rts

*---------------------------------------------------------------
* OPARSE -- parse -o's OPTARG into OLSIDE/OLFLD[0..OCOUNT-1].
* Grammar: TOKEN ("," TOKEN)*, TOKEN = "0" | SIDE "." FIELD,
* SIDE/FIELD each a SINGLE digit (v1 cap -- see header). IN:
* PTR0 = OPTARG.
*---------------------------------------------------------------
OPARSE      stz   OCOUNT
            ldy   #0
:tok        lda   (PTR0),y
            and   #$7F
            cmp   #'0'
            bcc   :err
            cmp   #'9'+1
            bcs   :err
            sec
            sbc   #'0'
            sta   OOSIDE
            iny
            lda   (PTR0),y
            cmp   #$AE                   ;'.'
            beq   :dot
            lda   OOSIDE
            beq   :zok
            bra   :err
:zok        stz   OOFLD
            jsr   OAPPEND
            bra   :sep
:dot        lda   OOSIDE
            cmp   #1
            beq   :sok
            cmp   #2
            beq   :sok
            bra   :err
:sok        iny
            lda   (PTR0),y
            and   #$7F
            cmp   #'0'
            bcc   :err
            cmp   #'9'+1
            bcs   :err
            sec
            sbc   #'0'
            sta   OOFLD
            iny
            jsr   OAPPEND
:sep        lda   (PTR0),y
            beq   :fin
            cmp   #$AC                   ;','
            beq   :more
            bra   :err
:more       iny
            jmp   :tok
:fin        rts
:err        jmp   USAGEEXIT

OAPPEND     lda   OCOUNT
            cmp   #MAXOL
            bcs   :full
            tax
            lda   OOSIDE
            sta   OLSIDE,x
            lda   OOFLD
            sta   OLFLD,x
            inc   OCOUNT
:full       rts
*---------------------------------------------------------------
* OPENSIDE1/OPENSIDE2 -- IN: A = argv index of the FILE operand.
* "-" (one char) opens fd 0; anything else is MKPATH+SC_OPEN.
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
OPENSIDE1   jsr   GETARG
            jsr   STRLEN
            cmp   #1
            bne   :real
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD
            bne   :real
            lda   #FD_STDIN
            sta   FD1
            stz   ISFILE1
            rts
:real       lda   #<PATH1BUF
            sta   PTR1
            lda   #>PATH1BUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<O1PARM
            ldx   #>O1PARM
            jsr   SC_OPEN
            bcc   :ok
            jmp   OPENERR1
:ok         lda   O1PARM_REF
            sta   FD1
            lda   #1
            sta   ISFILE1
            rts

OPENSIDE2   jsr   GETARG
            jsr   STRLEN
            cmp   #1
            bne   :real
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD
            bne   :real
            lda   #FD_STDIN
            sta   FD2
            stz   ISFILE2
            rts
:real       lda   #<PATH2BUF
            sta   PTR1
            lda   #>PATH2BUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<O2PARM
            ldx   #>O2PARM
            jsr   SC_OPEN
            bcc   :ok
            jmp   OPENERR2
:ok         lda   O2PARM_REF
            sta   FD2
            lda   #1
            sta   ISFILE2
            rts

OPENERR1    lda   #<CANTOPENM
            sta   PTR0
            lda   #>CANTOPENM
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT
OPENERR2    lda   #<CANTOPENM
            sta   PTR0
            lda   #>CANTOPENM
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

