*---------------------------------------------------------------
* calcalc.s -- cal's calendar arithmetic: operand parsing
* (CKYEAR/PARSENUM/ACCUM10) and the Sakamoto day-of-week plus
* leap-year test (CALCDOW/DIV16). `put` by src/bin/cal.s (NOT
* a standalone binary -- the same put-module shape as nl.s's
* own nlopt.s), split out for the same reason units split
* anywhere: `as`'s 16,128-byte source window holds the
* resident manifest plus one put file at a time, and cal.s's
* own text alone was past it. Every symbol here resolves
* against cal.s's own equates, zero page pointers and dum
* cells (ACCLO/ACCHI/AC_DIGIT/AC_TWOLO/AC_TWOHI/CAL_YEAR/
* CAL_MON/CAL_DOW/CAL_MDAYS/NUM/DEN/REM/LP_R4/LP_R100/LP_R400/
* CAL_LEAP/CD_YY/CD_Y4/CD_Y100/CD_Y400/CD_SUM) and SAKTAB/
* DAYSTAB -- see that file's own header.
*---------------------------------------------------------------
*---------------------------------------------------------------
* CKYEAR -- IN: ACCLO/ACCHI (PARSENUM's own output). OUT: carry
* CLEAR and CAL_YEAR set if 1 <= value <= 9999; carry SET
* otherwise (CAL_YEAR untouched). CLOBBERS: A.
*---------------------------------------------------------------
CKYEAR      lda   ACCLO
            ora   ACCHI
            beq   :ckbad
            sec
            lda   ACCLO
            sbc   #<10000
            lda   ACCHI
            sbc   #>10000
            bcs   :ckbad
            lda   ACCLO
            sta   CAL_YEAR
            lda   ACCHI
            sta   CAL_YEAR+1
            clc
            rts
:ckbad      sec
            rts

*---------------------------------------------------------------
* PARSENUM -- IN: PTR0 = a word (liba text). OUT: ACCLO/ACCHI =
* its value (16-bit); carry CLEAR on success, SET if empty or
* any byte is not a decimal digit. CLOBBERS: A, Y.
*---------------------------------------------------------------
PARSENUM    stz   ACCLO
            stz   ACCHI
            ldy   #0
:pnlp       lda   (PTR0),y
            beq   :pnend
            and   #$7F
            cmp   #'0'
            bcc   :pnbad
            cmp   #'9'+1
            bcs   :pnbad
            and   #$0F
            phy
            jsr   ACCUM10
            ply
            iny
            bne   :pnlp
            bra   :pnbad
:pnend      cpy   #0
            beq   :pnbad
            clc
            rts
:pnbad      sec
            rts

*---------------------------------------------------------------
* ACCUM10 -- ACCLO/ACCHI = ACCLO/ACCHI*10 + A (A=0-9). Same
* shape as head.s/tail.s's own digit accumulator. CLOBBERS: A.
*---------------------------------------------------------------
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
* CALCDOW -- IN: CAL_MON, CAL_YEAR. OUT: CAL_DOW (0=Sunday..
* 6=Saturday, the weekday of day 1), CAL_MDAYS (days in the
* month, Feb adjusted for a leap CAL_YEAR). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
CALCDOW
*-- leap(CAL_YEAR): div/mod by 4, 100, 400 on the REAL year (not
*-- Sakamoto's Jan/Feb-adjusted one below -- a different value).
            lda   CAL_YEAR
            sta   NUM
            lda   CAL_YEAR+1
            sta   NUM+1
            lda   #4
            sta   DEN
            stz   DEN+1
            jsr   DIV16
            lda   REM
            ora   REM+1
            sta   LP_R4

            lda   CAL_YEAR
            sta   NUM
            lda   CAL_YEAR+1
            sta   NUM+1
            lda   #100
            sta   DEN
            stz   DEN+1
            jsr   DIV16
            lda   REM
            ora   REM+1
            sta   LP_R100

            lda   CAL_YEAR
            sta   NUM
            lda   CAL_YEAR+1
            sta   NUM+1
            lda   #<400
            sta   DEN
            lda   #>400
            sta   DEN+1
            jsr   DIV16
            lda   REM
            ora   REM+1
            sta   LP_R400

            lda   LP_R4
            bne   :notleap
            lda   LP_R100
            bne   :leap
            lda   LP_R400
            bne   :notleap
:leap       lda   #1
            sta   CAL_LEAP
            bra   :leapdn
:notleap    stz   CAL_LEAP
:leapdn

            lda   CAL_MON
            sec
            sbc   #1
            tax
            lda   DAYSTAB,x
            sta   CAL_MDAYS
            lda   CAL_MON
            cmp   #2
            bne   :mdset
            lda   CAL_LEAP
            beq   :mdset
            lda   #29
            sta   CAL_MDAYS
:mdset

*-- Sakamoto: yy = CAL_YEAR, yy -= 1 if CAL_MON < 3.
            lda   CAL_YEAR
            sta   CD_YY
            lda   CAL_YEAR+1
            sta   CD_YY+1
            lda   CAL_MON
            cmp   #3
            bcs   :nomar
            sec
            lda   CD_YY
            sbc   #1
            sta   CD_YY
            lda   CD_YY+1
            sbc   #0
            sta   CD_YY+1
:nomar

            lda   CD_YY
            sta   NUM
            lda   CD_YY+1
            sta   NUM+1
            lda   #4
            sta   DEN
            stz   DEN+1
            jsr   DIV16
            lda   NUM
            sta   CD_Y4
            lda   NUM+1
            sta   CD_Y4+1

            lda   CD_YY
            sta   NUM
            lda   CD_YY+1
            sta   NUM+1
            lda   #100
            sta   DEN
            stz   DEN+1
            jsr   DIV16
            lda   NUM
            sta   CD_Y100
            lda   NUM+1
            sta   CD_Y100+1

            lda   CD_YY
            sta   NUM
            lda   CD_YY+1
            sta   NUM+1
            lda   #<400
            sta   DEN
            lda   #>400
            sta   DEN+1
            jsr   DIV16
            lda   NUM
            sta   CD_Y400
            lda   NUM+1
            sta   CD_Y400+1

            clc
            lda   CD_YY
            adc   CD_Y4
            sta   CD_SUM
            lda   CD_YY+1
            adc   CD_Y4+1
            sta   CD_SUM+1

            clc
            lda   CD_SUM
            adc   CD_Y400
            sta   CD_SUM
            lda   CD_SUM+1
            adc   CD_Y400+1
            sta   CD_SUM+1

            lda   CAL_MON
            sec
            sbc   #1
            tax
            clc
            lda   CD_SUM
            adc   SAKTAB,x
            sta   CD_SUM
            lda   CD_SUM+1
            adc   #0
            sta   CD_SUM+1

            clc
            lda   CD_SUM
            adc   #1
            sta   CD_SUM
            lda   CD_SUM+1
            adc   #0
            sta   CD_SUM+1

            sec
            lda   CD_SUM
            sbc   CD_Y100
            sta   CD_SUM
            lda   CD_SUM+1
            sbc   CD_Y100+1
            sta   CD_SUM+1

            lda   CD_SUM
            sta   NUM
            lda   CD_SUM+1
            sta   NUM+1
            lda   #7
            sta   DEN
            stz   DEN+1
            jsr   DIV16
            lda   REM
            sta   CAL_DOW
            rts

*---------------------------------------------------------------
* DIV16 -- 16x16 unsigned restoring division. IN: NUM
* (dividend), DEN (divisor, nonzero). OUT: NUM = quotient, REM
* = remainder. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
DIV16       stz   REM
            stz   REM+1
            ldx   #16
:dloop      asl   NUM
            rol   NUM+1
            rol   REM
            rol   REM+1
            lda   REM
            sec
            sbc   DEN
            tay
            lda   REM+1
            sbc   DEN+1
            bcc   :dskip
            sta   REM+1
            sty   REM
            inc   NUM
:dskip      dex
            bne   :dloop
            rts
