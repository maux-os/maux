*---------------------------------------------------------------
* lscol.s -- ls's column layout (4.2BSD -C, 2026-09-04). Split
* from lsprint.s at birth: `as`'s source window charges a unit
* its largest put, and lsprint.s was ls's.
*---------------------------------------------------------------
*-- Columns, DOWN then across (4.2BSD ls -C, 1983; on by default
*-- when stdout is a console, 2026-09-04): entry i of the sorted
*-- index sits at row i mod NROWS, column i div NROWS. A 48-name
*-- listing on 80 columns is 5 rows instead of 48 and never
*-- scrolls. LSCOLW = longest name + 2; the last column of a row
*-- is not padded.
PRINTCOLS   stz   LSROW
:rowlp      lda   LSROW
            cmp   LSNROWS
            bcs   :done
            sta   LSI                ;i = row
            stz   LSCOL
:collp      lda   LSI
            cmp   ENTRYCOUNT
            bcs   :rowend            ;no entry here: row done
            tax
            lda   ENTIDX,x
            jsr   ENTADDR
            jsr   PRINTENTNAME
            clc                      ;next column's entry:
            lda   LSI                ;i + NROWS
            adc   LSNROWS
            sta   LSI
            cmp   ENTRYCOUNT
            bcs   :rowend            ;last in this row: no pad
            ldy   #RD_LEN            ;pad to LSCOLW
            lda   (LS_ENT),y
            sta   LSPAD
:padlp      lda   LSPAD
            cmp   LSCOLW
            bcs   :padded
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   LSPAD
            bra   :padlp
:padded     inc   LSCOL
            bra   :collp
:rowend     lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   LSROW
            bra   :rowlp
:done       rts


*---------------------------------------------------------------
* COLSETUP -- decide the column geometry. Carry SET = print one
* per line (stdout is not a console and -C was not given, or the
* names are too wide for two columns). Else LSCOLW = longest
* RD_LEN + 2, LSNCOLS = width / LSCOLW, LSNROWS = ceil(n/NCOLS),
* carry clear. Width is SYS_TTYGEO's cols for a console (40 or
* 80), 80 for -C on a file or pipe.
*---------------------------------------------------------------
COLSETUP    lda   #<LSGEO
            sta   PTR0
            lda   #>LSGEO
            sta   PTR0+1
            lda   #FD_STDOUT
            jsr   SC_TTYGEO
            bcc   :havew
            lda   CFLAG
            beq   :none              ;not a console, no -C
            lda   #80
            sta   LSGEO
:havew      ldx   #0                 ;longest name
            stx   LSMAXLEN
            stx   PRIDX
:mxlp       lda   PRIDX
            cmp   ENTRYCOUNT
            bcs   :mxdone
            jsr   ENTADDR            ;record order is fine here
            ldy   #RD_LEN
            lda   (LS_ENT),y
            cmp   LSMAXLEN
            bcc   :mxnext
            sta   LSMAXLEN
:mxnext     inc   PRIDX
            bra   :mxlp
:mxdone     lda   LSMAXLEN
            ldx   FFLAG
            beq   :nosufw
            clc
            adc   #1
:nosufw
            clc
            adc   #2
            sta   LSCOLW
            lda   LSGEO              ;NCOLS = width / COLW
            ldx   #0
:divc       cmp   LSCOLW
            bcc   :divcd
            sbc   LSCOLW             ;carry set from the cmp
            inx
            bra   :divc
:divcd      cpx   #2
            bcc   :none              ;one column: plain list
            stx   LSNCOLS
            lda   ENTRYCOUNT         ;NROWS = ceil(n / NCOLS)
            ldx   #0
:divr       cmp   LSNCOLS
            bcc   :divrd
            sbc   LSNCOLS
            inx
            bra   :divr
:divrd      cmp   #0
            beq   :exact
            inx
:exact      stx   LSNROWS
            clc
            rts
:none       sec
            rts
