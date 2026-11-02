*---------------------------------------------------------------
* prparse.s -- pr's option engine: OPTPARSE (the +page pre-scan
* and the whole -t/-d/-l/-h/-o/-n option loop) plus GETVALWD/
* PARSEDEC/PARSECG/COPYHDR. `put` by src/bin/pr.s (NOT a
* standalone
* binary -- the same put-module shape as nl.s's own nlopt.s),
* split from pr.s because pr.s's own resident text alone was
* over the 16,128-byte check-dialect as-window budget. Every
* symbol here resolves against pr.s's own equates (DEFPGLEN/
* DEFWIDTH/TABCH/HDRCAP) and data (TFLAG/DFLAG/HAVEH/HAVEN/
* OFFSETVAL/PAGELEN/ERRFLAG/STARTPAGE/PSTART/PLUS_PTR/ARGIDX/
* ONW_PTR/GV_ERR/PD_ACC/PD_HAVE/PD_T2/NCHAR/NWIDTH/HEADERBUF)
* -- see that file's own header for the option grammar this
* codifies. OPTPARSE returns with ARGIDX at the first FILE
* operand (or ARGC if none); a bad option calls EXIT directly
* and never returns.
*---------------------------------------------------------------

*---------------------------------------------------------------
* OPTPARSE -- the +page pre-scan and the option loop. OUT:
* ARGIDX = index of the first FILE operand. CLOBBERS: A, X, Y,
* PTR0.
*---------------------------------------------------------------
OPTPARSE

*-- +page pre-scan: only argv[1], and only if it is spelled
*-- "+" followed by nothing but decimal digits.
            lda   ARGC
            cmp   #2
            bcc   :noplus
            lda   #1
            jsr   GETARG
            lda   (PTR0)
            cmp   #$AB              ;'+' high-bit
            bne   :noplus
            clc
            lda   PTR0
            adc   #1
            sta   PLUS_PTR
            lda   PTR0+1
            adc   #0
            sta   PLUS_PTR+1
            lda   PLUS_PTR
            sta   PTR0
            lda   PLUS_PTR+1
            sta   PTR0+1
            jsr   PARSEDEC
            bcs   :noplus
            sta   STARTPAGE
            lda   #2
            sta   PSTART
:noplus     lda   PSTART
            sta   ARGIDX

*-- option words: anything starting with '-' but not bare "-".
*-- :osdtr is OPTPARSE's one return point: ARGC exhausted, a
*-- non-option word, or a bare "-" all mean "files start here".
:optloop    lda   ARGIDX
            cmp   ARGC
            bcs   :osdtr
            jsr   GETARG
            lda   (PTR0)
            cmp   #$AD              ;'-' high-bit
            bne   :osdtr
            ldy   #1
            lda   (PTR0),y
            beq   :osdtr            ;bare "-": files start here
            bra   :ochk
:osdtr      rts
:ochk       cmp   #$F4              ;'t'
            beq   :o_t
            cmp   #$E4              ;'d'
            beq   :o_d
            cmp   #$EC              ;'l'
            beq   :o_l
            cmp   #$E8              ;'h'
            beq   :o_h
            cmp   #$EF              ;'o'
            beq   :o_o
            cmp   #$EE              ;'n'
            beq   :o_n
            jmp   :ousg
:o_t        lda   #1
            sta   TFLAG
            inc   ARGIDX
            jmp   :optloop
:o_d        lda   #1
            sta   DFLAG
            inc   ARGIDX
            jmp   :optloop
*-- :usage sits well past +/-127 bytes from here (same
*-- trampoline reason as :osdtr above) -- every conditional
*-- branch to it below is inverted around a near `jmp`.
:o_l        jsr   GETVALWD
            lda   GV_ERR
            beq   :ol_ok
            jmp   :usage
:ol_ok      jsr   PARSEDEC
            bcc   :ol_ok2
            jmp   :usage
:ol_ok2     sta   PAGELEN
            jmp   :optloop
:o_o        jsr   GETVALWD
            lda   GV_ERR
            beq   :oo_ok
            jmp   :usage
:oo_ok      jsr   PARSEDEC
            bcc   :oo_ok2
            jmp   :usage
:oo_ok2     sta   OFFSETVAL
            jmp   :optloop
:o_h        jsr   GETVALWD
            lda   GV_ERR
            beq   :oh_ok
            jmp   :usage
:oh_ok      jsr   COPYHDR
            lda   #1
            sta   HAVEH
            jmp   :optloop
:o_n        lda   #1
            sta   HAVEN
            ldy   #2
            lda   (PTR0),y
            bne   :onhas
            lda   #TABCH
            sta   NCHAR
            lda   #DEFWIDTH
            sta   NWIDTH
            inc   ARGIDX
            jmp   :optloop
:onhas      and   #$7F
            cmp   #'0'
            bcc   :onnd
            cmp   #'9'+1
            bcs   :onnd
            lda   #TABCH
            sta   NCHAR
            clc
            lda   PTR0
            adc   #2
            sta   ONW_PTR
            lda   PTR0+1
            adc   #0
            sta   ONW_PTR+1
            bra   :onwid
:onnd       ldy   #2
            lda   (PTR0),y
            sta   NCHAR
            clc
            lda   PTR0
            adc   #3
            sta   ONW_PTR
            lda   PTR0+1
            adc   #0
            sta   ONW_PTR+1
:onwid      lda   ONW_PTR
            sta   PTR0
            lda   ONW_PTR+1
            sta   PTR0+1
            lda   (PTR0)
            bne   :onhw
            lda   #DEFWIDTH
            sta   NWIDTH
            bra   :ondn
:onhw       jsr   PARSEDEC
            bcc   :onhw2
            jmp   :usage
:onhw2      sta   NWIDTH
:ondn       inc   ARGIDX
            jmp   :optloop

:ousg       cmp   #$E1              ;'a'
            bne   :p1
            jmp   :o_a
:p1
            cmp   #$ED              ;'m'
            bne   :p2
            jmp   :o_m
:p2
            cmp   #$C6              ;'F'
            bne   :p3
            jmp   :o_F
:p3
            cmp   #$E6              ;'f'
            bne   :p4
            jmp   :o_F
:p4
            cmp   #$F3              ;'s'
            bne   :p5
            jmp   :o_s
:p5
            cmp   #$E5              ;'e'
            bne   :p6
            jmp   :o_e
:p6
            cmp   #$E9              ;'i'
            bne   :p7
            jmp   :o_i
:p7
            cmp   #$F7              ;'w'
            bne   :p8
            jmp   :o_w
:p8
            cmp   #$B1              ;'1'
            bcc   :ousg2
            cmp   #$BA              ;'9'+1
            bcs   :ousg2
            jmp   :o_col
:ousg2      jmp   :usage
*-- -a -m -F: bare flags
:o_a        lda   #1
            sta   AFLAG
            inc   ARGIDX
            jmp   :optloop
:o_m        lda   #1
            sta   MFLAG
            inc   ARGIDX
            jmp   :optloop
:o_F        lda   #1
            sta   FFLAG
            inc   ARGIDX
            jmp   :optloop
*-- -s[char]
:o_s        lda   #1
            sta   SFLAG
            ldy   #2
            lda   (PTR0),y
            bne   :osset
            lda   #TABCH
:osset      sta   SEPCH
            inc   ARGIDX
            jmp   :optloop
*-- -e[char][gap] and -i[char][gap]
:o_e        jsr   PARSECG
            bcc   :oe_ok
            jmp   :usage
:oe_ok      lda   #1
            sta   EFLAG
            lda   CGCH
            bne   :oe1
            lda   #TABCH
:oe1        sta   ETABCH
            lda   CGGAP
            bne   :oe2
            lda   #8
:oe2        sta   EGAP
            inc   ARGIDX
            jmp   :optloop
:o_i        jsr   PARSECG
            bcc   :oi_ok
            jmp   :usage
:oi_ok      lda   #1
            sta   IFLAG
            lda   CGCH
            bne   :oi1
            lda   #TABCH
:oi1        sta   ITABCH
            lda   CGGAP
            bne   :oi2
            lda   #8
:oi2        sta   IGAP
            inc   ARGIDX
            jmp   :optloop
*-- -w width
:o_w        jsr   GETVALWD
            lda   GV_ERR
            beq   :ow_ok
            jmp   :usage
:ow_ok      jsr   PARSEDEC
            bcc   :ow_ok2
            jmp   :usage
:ow_ok2     sta   WIDTH
            lda   #1
            sta   HAVEW
            jmp   :optloop
*-- -column: the digits after the dash
:o_col      clc
            lda   PTR0
            adc   #1
            sta   PTR0
            lda   PTR0+1
            adc   #0
            sta   PTR0+1
            jsr   PARSEDEC
            bcc   :oc_ok
            jmp   :usage
:oc_ok      sta   NCOLS
            cmp   #2
            bcc   :oc_n
            sta   NGIVEN
:oc_n       inc   ARGIDX
            jmp   :optloop

:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* GETVALWD -- IN: ARGIDX = index of the current "-X..." word.
* OUT: PTR0 -> the option's value text (attached, or the next
* argv word if separated); ARGIDX advanced past whatever was
* consumed; GV_ERR = 1 if a separate value was required but no
* more argv words exist. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
GETVALWD    lda   ARGIDX
            jsr   GETARG
            ldy   #2
            lda   (PTR0),y
            bne   :gvatt
            inc   ARGIDX
            lda   ARGIDX
            cmp   ARGC
            bcs   :gvmiss
            jsr   GETARG
            inc   ARGIDX
            stz   GV_ERR
            rts
:gvatt      clc
            lda   PTR0
            adc   #2
            sta   PTR0
            lda   PTR0+1
            adc   #0
            sta   PTR0+1
            inc   ARGIDX
            stz   GV_ERR
            rts
:gvmiss     lda   #1
            sta   GV_ERR
            rts

*---------------------------------------------------------------
* PARSEDEC -- IN: PTR0 -> a NUL-terminated decimal string. OUT:
* A = its value (8-bit; carry SET past 255); carry SET if
* the string is empty or has any non-digit byte. CLOBBERS: A, Y.
*---------------------------------------------------------------
PARSEDEC    stz   PD_ACC
            stz   PD_HAVE
            ldy   #0
:pdlp       lda   (PTR0),y
            beq   :pddn
            and   #$7F
            cmp   #'0'
            bcc   :pdbad
            cmp   #'9'+1
            bcs   :pdbad
            and   #$0F
            sta   PD_D
            lda   PD_ACC
            cmp   #25
            bcc   :pdmul
            bne   :pdbad
            lda   PD_D
            cmp   #6
            bcs   :pdbad
:pdmul      lda   PD_ACC
            asl   a
            sta   PD_T2
            asl   a
            asl   a
            clc
            adc   PD_T2
            sta   PD_ACC
            lda   PD_D
            clc
            adc   PD_ACC
            sta   PD_ACC
            lda   #1
            sta   PD_HAVE
            iny
            bra   :pdlp
:pddn       lda   PD_HAVE
            beq   :pdbad
            lda   PD_ACC
            clc
            rts
:pdbad      sec
            rts

*---------------------------------------------------------------
* PARSECG -- IN: PTR0 -> an "-e..." / "-i..." word. Parses the
* optional [char][gap] after the letter. OUT: CGCH = the char
* (0 = none), CGGAP = the gap (0 = none); carry SET on junk.
* CLOBBERS: A, Y, PTR0.
*---------------------------------------------------------------
PARSECG     stz   CGCH
            stz   CGGAP
            ldy   #2
            lda   (PTR0),y
            beq   :cgok
            and   #$7F
            cmp   #'0'
            bcc   :cgchr
            cmp   #'9'+1
            bcc   :cgdig
:cgchr      lda   (PTR0),y
            sta   CGCH
            iny
:cgdig      tya
            clc
            adc   PTR0
            sta   PTR0
            lda   PTR0+1
            adc   #0
            sta   PTR0+1
            lda   (PTR0)
            beq   :cgok
            jsr   PARSEDEC
            bcs   :cgbad
            sta   CGGAP
:cgok       clc
            rts
:cgbad      sec
            rts

*---------------------------------------------------------------
* COPYHDR -- IN: PTR0 -> the -h text. Copies up to HDRCAP-1
* characters into HEADERBUF, NUL-terminated. CLOBBERS: A, Y.
*---------------------------------------------------------------
COPYHDR     ldy   #0
:chlp       lda   (PTR0),y
            beq   :chdn
            cpy   #HDRCAP-1
            bcs   :chdn
            sta   HEADERBUF,y
            iny
            bra   :chlp
:chdn       lda   #0
            sta   HEADERBUF,y
            rts

USAGEMSG    asc   "usage: pr [+page] [-column] [-adFmt] "
            asc   "[-e[c][n]] [-i[c][n]] [-h header] "
            asc   "[-l lines] [-n[c][w]] [-o offset] "
            asc   "[-s[c]] [-w width] [file...]"
            dfb   $8D,$00
