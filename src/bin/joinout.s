*---------------------------------------------------------------
* joinout.s -- join's record-composition/printing routines
* (default and `-o` output shapes), `put` by src/bin/join.s (NOT
* a standalone binary -- same reason and shape as joinio.s's own
* header). Every symbol here resolves against join.s's own
* equates/bss and against joinio.s's GETFLD1/GETFLD2/FOFFn/
* FLENn.
*---------------------------------------------------------------
*---------------------------------------------------------------
* OUTREC -- print one output record. IN: CURSIDE = 0 (paired
* both sides), 1 (unpaired, file1 only), 2 (unpaired, file2
* only). Uses OLIST when HAVEO, else the default composition.
*---------------------------------------------------------------
OUTREC      lda   HAVEO
            beq   :dflt
            jmp   VIAOLIST
:dflt       jsr   PRJF
            lda   CURSIDE
            cmp   #2
            beq   :sk1
            jsr   PREXTRA1
:sk1        lda   CURSIDE
            cmp   #1
            beq   :sk2
            jsr   PREXTRA2
:sk2        jmp   ENDLINE

VIAOLIST    ldx   #0
:lp         cpx   OCOUNT
            beq   :done
            cpx   #0
            beq   :nosep
            phx
            jsr   PRINTOFS
            plx
:nosep      lda   OLSIDE,x
            beq   :s0
            cmp   #1
            beq   :s1
            jmp   :s2
:s0         phx
            jsr   PRJF
            plx
            jmp   :nx
:s1         lda   CURSIDE
            cmp   #2
            bne   :s1go
            jsr   PREMPTY
            jmp   :nx
:s1go       lda   OLFLD,x
            phx
            jsr   PRF1BYIDX
            plx
            jmp   :nx
:s2         lda   CURSIDE
            cmp   #1
            bne   :s2go
            jsr   PREMPTY
            jmp   :nx
:s2go       lda   OLFLD,x
            phx
            jsr   PRF2BYIDX
            plx
:nx         inx
            jmp   :lp
:done       jmp   ENDLINE

*---------------------------------------------------------------
* PRJF -- print the join field text: side1's if a file1 line is
* present for this record (CURSIDE 0 or 1), else side2's.
*---------------------------------------------------------------
PRJF        lda   CURSIDE
            cmp   #2
            beq   :two
            lda   JF1
            jsr   GETFLD1
            lda   #<L1BUF
            clc
            adc   JFOFF
            sta   PTR0
            lda   #>L1BUF
            adc   #0
            sta   PTR0+1
            lda   JFLEN
            ldx   #FD_STDOUT
            jmp   PRSLICE
:two        lda   JF2
            jsr   GETFLD2
            lda   #<L2BUF
            clc
            adc   JFOFF
            sta   PTR0
            lda   #>L2BUF
            adc   #0
            sta   PTR0+1
            lda   JFLEN
            ldx   #FD_STDOUT
            jmp   PRSLICE

*---------------------------------------------------------------
* PREXTRA1/PREXTRA2 -- every OTHER field of side n (not JFn), in
* order, each preceded by the output separator.
*---------------------------------------------------------------
PREXTRA1    ldx   #0
:lp         cpx   NFLD1
            beq   :done
            txa
            clc
            adc   #1
            cmp   JF1
            beq   :skip
            phx
            jsr   PRINTOFS
            plx
            jsr   RAWFLD1
:skip       inx
            bra   :lp
:done       rts

PREXTRA2    ldx   #0
:lp         cpx   NFLD2
            beq   :done
            txa
            clc
            adc   #1
            cmp   JF2
            beq   :skip
            phx
            jsr   PRINTOFS
            plx
            jsr   RAWFLD2
:skip       inx
            bra   :lp
:done       rts

*---------------------------------------------------------------
* RAWFLD1/RAWFLD2 -- IN: X = 0-based field index. Prints it
* unconditionally (no -e substitution -- see header).
*---------------------------------------------------------------
RAWFLD1     lda   #<L1BUF
            clc
            adc   FOFF1,x
            sta   PTR0
            lda   #>L1BUF
            adc   #0
            sta   PTR0+1
            lda   FLEN1,x
            ldx   #FD_STDOUT
            jmp   PRSLICE

RAWFLD2     lda   #<L2BUF
            clc
            adc   FOFF2,x
            sta   PTR0
            lda   #>L2BUF
            adc   #0
            sta   PTR0+1
            lda   FLEN2,x
            ldx   #FD_STDOUT
            jmp   PRSLICE

*---------------------------------------------------------------
* PRF1BYIDX/PRF2BYIDX -- IN: A = 1-based field number. -o's own
* per-field printer: an out-of-range field, or one that is
* empty, goes through PREMPTY (the -e substitution point).
*---------------------------------------------------------------
PRF1BYIDX   tax
            dex
            cpx   NFLD1
            bcc   :ok
            jmp   PREMPTY
:ok         lda   FLEN1,x
            bne   :go
            jmp   PREMPTY
:go         jmp   RAWFLD1

PRF2BYIDX   tax
            dex
            cpx   NFLD2
            bcc   :ok
            jmp   PREMPTY
:ok         lda   FLEN2,x
            bne   :go
            jmp   PREMPTY
:go         jmp   RAWFLD2

*---------------------------------------------------------------
* PREMPTY -- an empty (or absent) -o field: ESTR if -e was
* given, nothing otherwise.
*---------------------------------------------------------------
PREMPTY     lda   HAVEE
            beq   :rt
            lda   #<ESTR
            sta   PTR0
            lda   #>ESTR
            sta   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS
:rt         rts

*---------------------------------------------------------------
* PRINTOFS -- one output-field separator: SEPCH under -t, one
* blank otherwise.
*---------------------------------------------------------------
PRINTOFS    lda   TMODE
            bne   :ct
            lda   #$A0
            bra   :pr
:ct         lda   SEPCH
:pr         ldx   #FD_STDOUT
            jmp   PUTC

ENDLINE     lda   #$8D
            ldx   #FD_STDOUT
            jmp   PUTC

*---------------------------------------------------------------
* PRSLICE -- IN: PTR0 = base pointer, A = length, X = fd. Prints
* A bytes starting at PTR0, none of them NUL-terminated slices
* (a field lives inside a larger line buffer). CLOBBERS: A, X,
* Y.
*---------------------------------------------------------------
PRSLICE     sta   PSLEN
            stx   PSFD
            ldy   #0
:lp         cpy   PSLEN
            beq   :done
            lda   (PTR0),y
            pha
            ldx   PSFD
            pla
            jsr   PUTC
            iny
            bra   :lp
:done       rts
*---------------------------------------------------------------
* CMPJF -- compare the current lines' join fields. OUT: A = 0
* equal, 1 file1>file2, $FF file1<file2 (STRCMP's own encoding).
*---------------------------------------------------------------
CMPJF       lda   JF1
            jsr   GETFLD1
            lda   #<L1BUF
            clc
            adc   JFOFF
            sta   PTR0
            lda   #>L1BUF
            adc   #0
            sta   PTR0+1
            lda   JFLEN
            sta   CFALEN
            lda   JF2
            jsr   GETFLD2
            lda   #<L2BUF
            clc
            adc   JFOFF
            sta   PTR1
            lda   #>L2BUF
            adc   #0
            sta   PTR1+1
            lda   JFLEN
            sta   CFBLEN
            jmp   CMPFLD
