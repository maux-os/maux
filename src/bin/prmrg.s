*---------------------------------------------------------------
* prmrg.s -- pr -m: PRMERGE/READK/STOREM/MPAD. `put` by
* src/bin/pr.s (NOT a standalone binary).
*
* One column per FILE operand, at most NMAXM (8) -- the
* io_buffer
* pool is 8 and the kernel lends buffers past it
* (learning:01M1WQP0J05MFRR0B03X6MB0ZR), but 8 is what the
* process
* fd table is gated at (docs/POSIX-PR-NOTES.md). A "-" operand
* is
* stdin. Each file keeps its own 255-byte read buffer (page
* MRDPG+k
* of the arena) and its own position; READK swaps them into the
* globals GETBYTE/READLN use. One row is read from every file in
* lockstep into the cell pages (MCELLPG+k), then PRROW prints
* it.
* A file that has run out leaves its cell absent; the other
* cells
* still sit at their own column (BSD's behaviour, measured).
*---------------------------------------------------------------

PRMERGE     lda   #>ARENA
            clc
            adc   #1
            sta   MCELLPG
            clc
            adc   #8
            sta   MRDPG
            clc
            adc   #8
            cmp   #$C0
            bcc   :pgok
            lda   #<PAGEMSG
            sta   PTR0
            lda   #>PAGEMSG
            sta   PTR0+1
            jsr   DIE
:pgok       ldx   #NMAXM-1
:zd         stz   MDONE,x
            dex
            bpl   :zd
            stz   FIDX
:open       lda   FIDX
            cmp   NCOLS
            bcc   :ogo
            jmp   :opened
:ogo
            lda   ARGIDX
            cmp   ARGC
            bcs   :stdin
            clc
            adc   FIDX
            jsr   GETARG
            lda   (PTR0)
            cmp   #$AD
            bne   :real
            ldy   #1
            lda   (PTR0),y
            bne   :real
:stdin      lda   #FD_STDIN
            bra   :setfd
:real       lda   PTR0
            sta   FNAMEPTR
            lda   PTR0+1
            sta   FNAMEPTR+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :opn
            lda   #<CANTOPEN
            sta   PTR0
            lda   #>CANTOPEN
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   FNAMEPTR
            sta   PTR0
            lda   FNAMEPTR+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG
            ldx   FIDX
            lda   #1
            sta   MDONE,x
            lda   #0
            bra   :setfd
:opn        lda   OPARM_REF
:setfd      ldx   FIDX
            sta   MFD,x
            stz   MPOS,x
            stz   MLEN,x
            inc   FIDX
            jmp   :open
:opened     lda   #<CLKBUF
            sta   PTR0
            lda   #>CLKBUF
            sta   PTR0+1
            jsr   SC_CLOCK
            lda   CLKBUF
            sta   HDATE
            lda   CLKBUF+1
            sta   HDATE+1
            lda   CLKBUF+2
            sta   HTIME
            lda   CLKBUF+3
            sta   HTIME+1
            lda   #<EMPTYSTR
            sta   FNAMEPTR
            lda   #>EMPTYSTR
            sta   FNAMEPTR+1
            lda   #1
            sta   PAGENUM
            sta   LINENOLO
            stz   LINENOHI
            stz   BODYCNT
:row        stz   ANY
            stz   FIDX
:rk         lda   FIDX
            cmp   NCOLS
            bcs   :rowdone
            jsr   READK
            bcs   :abs
            jsr   STOREM
            ldx   FIDX
            lda   #1
            sta   MEXIST,x
            sta   ANY
            bra   :nk
:abs        ldx   FIDX
            stz   MEXIST,x
:nk         inc   FIDX
            bra   :rk
:rowdone    lda   ANY
            beq   :fin
            lda   EFFT
            bne   :body
            lda   BODYCNT
            bne   :body
            jsr   VISIBLE
            bcc   :body
            jsr   PRINTHDR
:body       jsr   VISIBLE
            bcc   :nb
            jsr   PRROW
:nb         inc   LINENOLO
            bne   :nl
            inc   LINENOHI
:nl         inc   BODYCNT
            lda   EFFT
            bne   :again
            lda   BODYCNT
            cmp   ROWSCAP
            bcc   :again
            jsr   VISIBLE
            bcc   :nt
            jsr   MPAD
:nt         stz   BODYCNT
            inc   PAGENUM
:again      jmp   :row
:fin        lda   EFFT
            bne   :cls
            lda   BODYCNT
            beq   :cls
            jsr   VISIBLE
            bcc   :cls
            jsr   MPAD
:cls        stz   FIDX
:cl         lda   FIDX
            cmp   NCOLS
            bcs   :cdone
            ldx   FIDX
            lda   MFD,x
            beq   :cnx
            cmp   #FD_STDIN
            beq   :cnx
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
:cnx        inc   FIDX
            bra   :cl
:cdone      rts

*---------------------------------------------------------------
* MPAD -- pad (or -F) the page just filled. CLOBBERS: A, X.
*---------------------------------------------------------------
MPAD        lda   BODYCNT
            ldx   DFLAG
            beq   :mp
            asl   a
:mp         sta   PB_PAD
            lda   PAGELEN
            sec
            sbc   #5
            sec
            sbc   PB_PAD
            jmp   PGEND

*---------------------------------------------------------------
* READK -- IN: FIDX. Read one line of file FIDX into LBUF/LLEN.
* OUT:
* carry SET = that file has no line. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
READK       ldx   FIDX
            lda   MDONE,x
            bne   :none
            lda   MFD,x
            sta   CURFD
            lda   MPOS,x
            sta   BUFPOS
            lda   MLEN,x
            sta   BUFLEN
            stz   RLEOF
            stz   PTR2
            lda   MRDPG
            clc
            adc   FIDX
            sta   PTR2+1
            jsr   READLN
            php
            ldx   FIDX
            lda   BUFPOS
            sta   MPOS,x
            lda   BUFLEN
            sta   MLEN,x
            plp
            bcc   :got
            lda   #1
            sta   MDONE,x
:none       sec
            rts
:got        clc
            rts

*---------------------------------------------------------------
* STOREM -- IN: FIDX, LBUF/LLEN. Truncate to the column's text
* width
* and store [len][chars] in cell page MCELLPG+FIDX.
* CLOBBERS: A, Y,
* PTR0.
*---------------------------------------------------------------
STOREM      lda   FIDX
            bne   :n0
            lda   AVAIL0
            bra   :av
:n0         lda   AVAILN
:av         sta   SLEN
            lda   LLEN
            cmp   SLEN
            bcs   :lok
            sta   SLEN
:lok        stz   PTR0
            lda   MCELLPG
            clc
            adc   FIDX
            sta   PTR0+1
            lda   SLEN
            sta   (PTR0)
            ldy   #0
:cp         cpy   SLEN
            beq   :cpd
            lda   LBUF,y
            iny
            sta   (PTR0),y
            bra   :cp
:cpd        rts
