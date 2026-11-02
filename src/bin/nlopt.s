*---------------------------------------------------------------
* nlopt.s -- nl's option-value parsers: SETPTRO/PARSETY/PARSED/
* PARSEI/PARSEL/PARSEN/PARSES/PARSEV/ACCUM16/PARSEW2. `put` by
* src/bin/nl.s (NOT a standalone binary -- the same put-module
* shape as cut.s's own cutlist.s), split out for the same reason
* units split anywhere: `as`'s 16,128-byte source window holds
* the resident manifest plus one put file at a time, and nl.s's
* own text alone was past it (measured: 24,534 B stripped, over
* by 8,406). Every symbol here resolves against nl.s's own
* equates (TY_A/TY_T/TY_N/NLMAXW), zero page pointers, and data
* (BTYPE/HTYPE/FTYPE/DELIM1/DELIM2/INCRMAG/INCRNEG/STARTLO/
* STARTHI/WIDTH/NFORMAT/SEPBUF/WANT_P/NLNUM/IACC/IHAVE/IDIGIT/
* ITMP/VACC/VHAVE/AC_DIG/AC_T2LO/AC_T2HI/WACC/WDIGIT/WTMP) and
* USAGEEXIT/OPTARG -- see that file's own header for the type/
* delimiter/format/width/blank-group option rules this codifies.
*---------------------------------------------------------------
*---------------------------------------------------------------
* SETPTRO -- PTR0 = OPTARG (helper for -b/-f/-h, all sharing
* PARSETY).
*---------------------------------------------------------------
SETPTRO     lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* PARSETY -- IN: PTR0 = type-value string ("a"/"t"/"n"/"p..."),
* X = section index (0 header, 1 body, 2 footer: TYPEARR's
* order). OUT: A = TY_A/TY_T/TY_N/TY_P. "pBRE" files the address
* of the BRE (the byte after the `p`, empty allowed) in
* NLPAT[X*2] -- argv memory, which outlives the whole run.
*---------------------------------------------------------------
PARSETY     ldy   #0
            lda   (PTR0),y
            and   #$7F
            cmp   #'a'
            bne   :tnota
            iny
            lda   (PTR0),y
            bne   :tbad
            lda   #TY_A
            rts
:tnota      cmp   #'t'
            bne   :tnott
            iny
            lda   (PTR0),y
            bne   :tbad
            lda   #TY_T
            rts
:tnott      cmp   #'n'
            bne   :tnotn
            iny
            lda   (PTR0),y
            bne   :tbad
            lda   #TY_N
            rts

:tnotn      cmp   #'p'
            bne   :tbad
            txa
            asl   a
            tax
            clc
            lda   PTR0
            adc   #1
            sta   NLPAT,x
            lda   PTR0+1
            adc   #0
            sta   NLPAT+1,x
            lda   #TY_P
            rts
:tbad       jmp   USAGEEXIT

*---------------------------------------------------------------
* PARSED -- -d's OPTARG: 1 or 2 raw bytes. One byte given leaves
* DELIM2 at its default colon (POSIX's own rule); more than 2 is
* a usage error.
*---------------------------------------------------------------
PARSED      lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            ldy   #0
            lda   (PTR0),y
            beq   :usageerr3
            sta   DELIM1
            iny
            lda   (PTR0),y
            beq   :d1only
            sta   DELIM2
            iny
            lda   (PTR0),y
            bne   :usageerr3
            rts
:d1only     lda   #$BA
            sta   DELIM2
            rts
:usageerr3  jmp   USAGEEXIT

*---------------------------------------------------------------
* PARSEI -- -i's OPTARG: optional leading '-', then digits, into
* INCRMAG (byte, cap ~255 via the same 26-guard shape as
* fold.s's PARSEW) and INCRNEG.
*---------------------------------------------------------------
PARSEI      lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            stz   INCRNEG
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD
            bne   :iparse
            lda   #1
            sta   INCRNEG
            iny
:iparse     stz   IACC
            stz   IHAVE
:iloop      lda   (PTR0),y
            beq   :iend
            and   #$7F
            cmp   #'0'
            bcc   :usageerr4
            cmp   #'9'+1
            bcs   :usageerr4
            and   #$0F
            sta   IDIGIT
            lda   IACC
            cmp   #26
            bcs   :usageerr4
            asl   a
            sta   ITMP
            lda   IACC
            asl   a
            asl   a
            asl   a
            clc
            adc   ITMP
            clc
            adc   IDIGIT
            sta   IACC
            lda   #1
            sta   IHAVE
            iny
            bra   :iloop
:iend       lda   IHAVE
            beq   :usageerr4
            lda   IACC
            sta   INCRMAG
            rts
:usageerr4  jmp   USAGEEXIT

*---------------------------------------------------------------
* PARSEL -- -l's OPTARG: unsigned digits into NLNUM (byte, same
* 26-guard cap shape as PARSEI, no sign -- a blank-line-group
* size is never negative). 0 is a usage error, same as an empty
* string -- "count 0 blank lines as one" is not a legal group
* size on either side of this tool.
*---------------------------------------------------------------
PARSEL      lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            ldy   #0
            stz   IACC
            stz   IHAVE
:lloop      lda   (PTR0),y
            beq   :lend
            and   #$7F
            cmp   #'0'
            bcc   :usageerr5
            cmp   #'9'+1
            bcs   :usageerr5
            and   #$0F
            sta   IDIGIT
            lda   IACC
            cmp   #26
            bcs   :usageerr5
            asl   a
            sta   ITMP
            lda   IACC
            asl   a
            asl   a
            asl   a
            clc
            adc   ITMP
            clc
            adc   IDIGIT
            sta   IACC
            lda   #1
            sta   IHAVE
            iny
            bra   :lloop
:lend       lda   IHAVE
            beq   :usageerr5
            lda   IACC
            beq   :usageerr5        ;-l 0 -- no legal group size
            sta   NLNUM
            rts
:usageerr5  jmp   USAGEEXIT

*---------------------------------------------------------------
* PARSEN -- -n's OPTARG: "ln"/"rn"/"rz" exactly. OUT: NFORMAT =
* 0/1/2.
*---------------------------------------------------------------
PARSEN      lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            ldy   #0
            lda   (PTR0),y
            and   #$7F
            cmp   #'l'
            beq   :nfl
            cmp   #'r'
            bne   :usageerr5
            iny
            lda   (PTR0),y
            and   #$7F
            cmp   #'n'
            beq   :nfrn
            cmp   #'z'
            beq   :nfrz
            bra   :usageerr5
:nfl        iny
            lda   (PTR0),y
            and   #$7F
            cmp   #'n'
            bne   :usageerr5
            iny
            lda   (PTR0),y
            bne   :usageerr5
            stz   NFORMAT
            rts
:nfrn       iny
            lda   (PTR0),y
            bne   :usageerr5
            lda   #1
            sta   NFORMAT
            rts
:nfrz       iny
            lda   (PTR0),y
            bne   :usageerr5
            lda   #2
            sta   NFORMAT
            rts
:usageerr5  jmp   USAGEEXIT

*---------------------------------------------------------------
* PARSES -- -s's OPTARG copied verbatim into SEPBUF, truncated
* (silently) past SEPCAP-1 -- separators in this tree's own
* corpus are a character or two, never near that cap.
*---------------------------------------------------------------
PARSES      lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            ldy   #0
:sloop      lda   (PTR0),y
            beq   :sdone
            cpy   #SEPCAP-1
            bcs   :sdone
            sta   SEPBUF,y
            iny
            bra   :sloop
:sdone      lda   #0
            sta   SEPBUF,y
            rts

*---------------------------------------------------------------
* PARSEV -- -v's OPTARG: unsigned decimal into STARTLO/STARTHI
* (16-bit, the classic x10=x8+x2 accumulate -- same shape as
* cutlist.s's own ACCUM, unindexed since there is only one
* accumulator here).
*---------------------------------------------------------------
PARSEV      lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            stz   VACC
            stz   VACC+1
            stz   VHAVE
            ldy   #0
:vloop      lda   (PTR0),y
            beq   :vend
            and   #$7F
            cmp   #'0'
            bcc   :usageerr6
            cmp   #'9'+1
            bcs   :usageerr6
            and   #$0F
            jsr   ACCUM16
            lda   #1
            sta   VHAVE
            iny
            bra   :vloop
:vend       lda   VHAVE
            beq   :usageerr6
            lda   VACC
            sta   STARTLO
            lda   VACC+1
            sta   STARTHI
            rts
:usageerr6  jmp   USAGEEXIT

*---------------------------------------------------------------
* ACCUM16 -- IN: A = digit 0-9. VACC(2) = VACC*10 + A.
*---------------------------------------------------------------
ACCUM16     sta   AC_DIG
            asl   VACC
            rol   VACC+1
            lda   VACC
            sta   AC_T2LO
            lda   VACC+1
            sta   AC_T2HI
            asl   VACC
            rol   VACC+1
            asl   VACC
            rol   VACC+1
            clc
            lda   VACC
            adc   AC_T2LO
            sta   VACC
            lda   VACC+1
            adc   AC_T2HI
            sta   VACC+1
            clc
            lda   VACC
            adc   AC_DIG
            sta   VACC
            bcc   :ac16nc
            inc   VACC+1
:ac16nc     rts

*---------------------------------------------------------------
* PARSEW2 -- -w's OPTARG into WIDTH, 1..NLMAXW. Same shape as
* fold.s's own PARSEW.
*---------------------------------------------------------------
PARSEW2     lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            stz   WACC
            ldy   #0
:wloop      lda   (PTR0),y
            beq   :wend
            and   #$7F
            cmp   #'0'
            bcc   :usageerr7
            cmp   #'9'+1
            bcs   :usageerr7
            and   #$0F
            sta   WDIGIT
            lda   WACC
            cmp   #26
            bcs   :usageerr7
            asl   a
            sta   WTMP
            lda   WACC
            asl   a
            asl   a
            asl   a
            clc
            adc   WTMP
            clc
            adc   WDIGIT
            sta   WACC
            iny
            bra   :wloop
:wend       cpy   #0
            beq   :usageerr7
            lda   WACC
            beq   :usageerr7
            cmp   #NLMAXW+1
            bcs   :usageerr7
            sta   WIDTH
            rts
:usageerr7  jmp   USAGEEXIT

