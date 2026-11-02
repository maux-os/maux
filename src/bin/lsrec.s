*---------------------------------------------------------------
* lsrec.s -- ls -R recursion worklist.
*
* readdir.s is deliberately a singleton, so recursion cannot
* hold a parent directory open. LISTDIR closes, sorts and prints
* the parent, then QUEUEDIRS saves its child paths in reverse
* sort order. RUNREC pops them for depth-first sorted output.
* The bounded machine holds 16 pending directory paths. Overflow
* and overlong paths are loud and make rc=1.
*---------------------------------------------------------------

RMAX        equ   16

* A = stack index, PTR1 = 66-byte slot (count + 64 + spare).
RSPTR       sta   RINDEX
            sta   LS_TMP16
            stz   LS_TMP16+1
            ldx   #6
:sh         asl   LS_TMP16
            rol   LS_TMP16+1
            dex
            bne   :sh
            lda   RINDEX
            asl   a
            clc
            adc   LS_TMP16
            sta   LS_TMP16
            bcc   :nocarry
            inc   LS_TMP16+1
:nocarry    clc
            lda   LS_TMP16
            adc   #<RSTACK
            sta   PTR1
            lda   LS_TMP16+1
            adc   #>RSTACK
            sta   PTR1+1
            rts

* Queue directory entries in reverse display order.
QUEUEDIRS   lda   RECFLAG
            bne   :start
            rts
:start      lda   ENTRYCOUNT
            sta   RQIDX
:next       lda   RQIDX
            bne   :have
            rts
:have       dec   RQIDX
            ldx   RQIDX
            lda   ENTIDX,x
            jsr   ENTADDR
            ldy   #RD_STYPE
            lda   (LS_ENT),y
            cmp   #STYP_DIR
            bne   :next
            lda   RCOUNT
            cmp   #RMAX
            bcc   :room
            jsr   RRECERR
            bra   :next
:room       ldy   #0
            lda   (LS_RPAR),y
            sta   RPARLEN
            stz   RSEP
            tay
            lda   (LS_RPAR),y
            cmp   #$2F
            beq   :sepset
            lda   #1
            sta   RSEP
:sepset     ldy   #RD_LEN
            lda   (LS_ENT),y
            sta   RNAMLEN
            clc
            adc   RPARLEN
            adc   RSEP
            sta   RTOTAL
            cmp   #65
            bcc   :pathok
            jsr   RRECERR
            bra   :next
:pathok     lda   RCOUNT
            jsr   RSPTR
            ldy   #0
            lda   RTOTAL
            sta   (PTR1),y
            iny
:parcopy    cpy   RPARLEN
            bcc   :parbyte
            beq   :parbyte
            bra   :parend
:parbyte    lda   (LS_RPAR),y
            sta   (PTR1),y
            iny
            bra   :parcopy
:parend     lda   RPARLEN
            clc
            adc   #1
            sta   RDEST
            lda   RSEP
            beq   :namestart
            ldy   RDEST
            lda   #$2F
            sta   (PTR1),y
            inc   RDEST
:namestart  stz   RCHAR
:namecopy   lda   RCHAR
            cmp   RNAMLEN
            bcs   :pushed
            clc
            adc   #RD_NAME
            tay
            lda   (LS_ENT),y
            and   #$7F
            pha
            ldy   RDEST
            pla
            sta   (PTR1),y
            inc   RDEST
            inc   RCHAR
            bra   :namecopy
:pushed     inc   RCOUNT
            jmp   :next

* Drain the worklist after one top-level directory listing.
RUNREC      lda   RECFLAG
            bne   :loop
            rts
:loop       lda   RCOUNT
            bne   :pop
            rts
:pop        dec   RCOUNT
            lda   RCOUNT
            jsr   RSPTR
            ldy   #0
            lda   (PTR1),y
            sta   PATHBUF
            tax
:copy       iny
            lda   (PTR1),y
            sta   PATHBUF,y
            dex
            bne   :copy
            jsr   PRRHEAD
            lda   #<PATHBUF
            ldx   #>PATHBUF
            jsr   LISTDIR
            bcc   :listed
            jsr   PRRACCESS
            lda   #1
            sta   ERRFLAG
            bra   :loop
:listed     lda   TRUNCATED
            beq   :loop
            jsr   PRRTRUNC
            lda   #1
            sta   ERRFLAG
            bra   :loop

PRRHEAD     lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   PRRPATH
            lda   #$BA
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$8D
            ldx   #FD_STDOUT
            jmp   PUTC

PRRPATH     stz   RINDEX
            lda   PATHBUF
            sta   RCHAR
:ploop      inc   RINDEX
            ldy   RINDEX
            lda   PATHBUF,y
            ora   #$80
            ldx   #FD_STDOUT
            jsr   PUTC
            dec   RCHAR
            bne   :ploop
            rts

PRRACCESS   lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            jsr   PRRERRPATH
            lda   #<ERRSUF_ACCESS
            sta   PTR0
            lda   #>ERRSUF_ACCESS
            bra   PRRERRTAIL

PRRTRUNC    lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            jsr   PRRERRPATH
            lda   #<ERRSUF_TRUNC
            sta   PTR0
            lda   #>ERRSUF_TRUNC
PRRERRTAIL  sta   PTR0+1
            ldx   #FD_STDERR
            jmp   PUTS

PRRERRPATH  ldy   #0
            lda   PATHBUF
            sta   RCHAR
            stz   RINDEX
:eloop      inc   RINDEX
            ldy   RINDEX
            lda   PATHBUF,y
            ora   #$80
            ldx   #FD_STDERR
            jsr   PUTC
            dec   RCHAR
            bne   :eloop
            rts

RRECERR     lda   #1
            sta   ERRFLAG
            lda   RERRFLAG
            beq   :first
            rts
:first      lda   #1
            sta   RERRFLAG
            lda   #<RECLIMMSG
            sta   PTR0
            lda   #>RECLIMMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jmp   PUTS

RECLIMMSG   asc   "ls: recursive path/worklist limit"
            dfb   $8D,0
