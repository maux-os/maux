*---------------------------------------------------------------
* nmscan.s -- nm's dictionary-scan half,
* extracted from nm.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2 mains). One
* assembly stream: put exactly where the text sat; every rule
* in the manifest header applies unchanged.
*---------------------------------------------------------------
ADV1        lda   #1
            bra   ADVN
ADV4        lda   #4
ADVN        clc
            adc   NM_DPTR
            sta   NM_DPTR
            bcc   :nc
            inc   NM_DPTR+1
:nc         rts

*---------------------------------------------------------------
* SDADDR/SDGET/SDSET -- SYMDESC[NM_SIDX] access, same shape as
* sort.s's LPADDR/LPGET_A/LPSET_A (pointer array, sort the
* pointers, never move text).
*---------------------------------------------------------------
SDADDR      lda   NM_SIDX
            asl   a
            sta   NM_APTR
            lda   NM_SIDX+1
            rol   a
            sta   NM_APTR+1
            clc
            lda   NM_APTR
            adc   #<SYMDESC
            sta   NM_APTR
            lda   NM_APTR+1
            adc   #>SYMDESC
            sta   NM_APTR+1
            rts

SDGET       jsr   SDADDR
            ldy   #0
            lda   (NM_APTR),y
            sta   NM_AVAL
            iny
            lda   (NM_APTR),y
            sta   NM_AVAL+1
            rts

SDSET       jsr   SDADDR
            ldy   #0
            lda   NM_AVAL
            sta   (NM_APTR),y
            iny
            lda   NM_AVAL+1
            sta   (NM_APTR),y
            rts

*---------------------------------------------------------------
* SORTSYMS -- shell sort SYMDESC[0..NSYMS) by CMPNAME. Same
* shape as sort.s's SORTLINES (halving gap, no recursion).
*---------------------------------------------------------------
SORTSYMS    lda   NSYMS
            sta   NM_GAP
            lda   NSYMS+1
            sta   NM_GAP+1
:halve      lsr   NM_GAP+1
            ror   NM_GAP
            lda   NM_GAP
            ora   NM_GAP+1
            bne   :gapok
            rts
:gapok      lda   NM_GAP
            sta   NM_I
            lda   NM_GAP+1
            sta   NM_I+1
:iloop      lda   NM_I+1
            cmp   NSYMS+1
            bcc   :dorow
            beq   :chklo
            jmp   :nexti
:chklo      lda   NM_I
            cmp   NSYMS
            bcc   :dorow
            jmp   :nexti
:dorow      lda   NM_I
            sta   NM_SIDX
            lda   NM_I+1
            sta   NM_SIDX+1
            jsr   SDGET
            lda   NM_AVAL
            sta   NM_TVAL
            lda   NM_AVAL+1
            sta   NM_TVAL+1
            lda   NM_I
            sta   NM_J
            lda   NM_I+1
            sta   NM_J+1
:jloop      lda   NM_J+1
            cmp   NM_GAP+1
            bcc   :toins
            bne   :dosub
            lda   NM_J
            cmp   NM_GAP
            bcc   :toins
            bra   :dosub
:toins      jmp   :insert
:dosub      sec
            lda   NM_J
            sbc   NM_GAP
            sta   NM_JM
            lda   NM_J+1
            sbc   NM_GAP+1
            sta   NM_JM+1
            lda   NM_JM
            sta   NM_SIDX
            lda   NM_JM+1
            sta   NM_SIDX+1
            jsr   SDGET
            lda   NM_AVAL
            sta   NM_DA
            lda   NM_AVAL+1
            sta   NM_DA+1
            lda   NM_TVAL
            sta   NM_DB
            lda   NM_TVAL+1
            sta   NM_DB+1
            jsr   CMPNAME
            cmp   #1
            beq   :doshift
            bra   :insert
:doshift    lda   NM_J
            sta   NM_SIDX
            lda   NM_J+1
            sta   NM_SIDX+1
            jsr   SDSET
            lda   NM_JM
            sta   NM_J
            lda   NM_JM+1
            sta   NM_J+1
            jmp   :jloop
:insert     lda   NM_J
            sta   NM_SIDX
            lda   NM_J+1
            sta   NM_SIDX+1
            lda   NM_TVAL
            sta   NM_AVAL
            lda   NM_TVAL+1
            sta   NM_AVAL+1
            jsr   SDSET
            inc   NM_I
            bne   :noh
            inc   NM_I+1
:noh        jmp   :iloop
:nexti      jmp   :halve

*---------------------------------------------------------------
* CMPNAME -- IN: NM_DA/NM_DB = pointers to two symbol
* descriptors (each at its flag|len byte). OUT: A = 0 equal,
* $FF if A<B, 1 if A>B -- STRCMP's own convention, but over
* RAW dictionary bytes (7-bit, length-prefixed, no NUL) instead
* of liba strings.
*---------------------------------------------------------------
CMPNAME     ldy   #0
            lda   (NM_DA),y
            and   #LEN_MASK
            sta   CMP_LENA
            lda   (NM_DB),y
            and   #LEN_MASK
            sta   CMP_LENB
            cmp   CMP_LENA
            bcs   :aismin
            lda   CMP_LENA
            bra   :havemin
:aismin     lda   CMP_LENB
:havemin    sta   CMP_MIN
            ldy   #1
:cloop      lda   CMP_MIN
            beq   :tie
            lda   (NM_DA),y
            cmp   (NM_DB),y
            bne   :diff
            iny
            dec   CMP_MIN
            bra   :cloop
:diff       bcc   :lt
            lda   #1
            rts
:lt         lda   #$FF
            rts
:tie        lda   CMP_LENA
            cmp   CMP_LENB
            beq   :eq
            bcc   :lt2
            lda   #1
            rts
:lt2        lda   #$FF
            rts
:eq         lda   #0
            rts

*---------------------------------------------------------------
* PRINTBLK -- print this file's header (if NFILES>1) then its
* NSYMS symbols in SYMDESC order (already sorted).
*---------------------------------------------------------------
PRINTBLK    lda   NFILES
            cmp   #2
            bcc   :nohdr
            lda   BLKFLAG
            beq   :hdr
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:hdr        lda   NAMEPTR
            sta   PTR0
            lda   NAMEPTR+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$BA              ;':' high-bit
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #1
            sta   BLKFLAG
:nohdr      jsr   PRINTALL
            rts

PRINTALL    stz   NM_I
            stz   NM_I+1
:loop       lda   NM_I+1
            cmp   NSYMS+1
            bcc   :dop
            beq   :chklo
            rts
:chklo      lda   NM_I
            cmp   NSYMS
            bcc   :dop
            rts
:dop        lda   NM_I
            sta   NM_SIDX
            lda   NM_I+1
            sta   NM_SIDX+1
            jsr   SDGET
            lda   NM_AVAL
            sta   PTR0
            lda   NM_AVAL+1
            sta   PTR0+1
            jsr   PRINTSYM
            inc   NM_I
            bne   :noh
            inc   NM_I+1
:noh        bra   :loop

*---------------------------------------------------------------
* PRINTSYM -- IN: PTR0 = descriptor pointer (its flag|len byte).
* Prints one full "ADDR TYPE NAME" line to fd 1.
*---------------------------------------------------------------
PRINTSYM    ldy   #0
            lda   (PTR0),y
            sta   RECFLAG
            and   #LEN_MASK
            sta   RECLEN

            lda   RECFLAG
            and   #TYPE_EXT
            bne   :undef

            ;-- ENT: addr lo/hi sit right after the name.
            ldy   RECLEN
            iny                     ;past flag byte too
            lda   (PTR0),y          ;addr lo
            pha
            iny
            lda   (PTR0),y          ;addr hi
            and   #$7F              ;- $8000, see file header
            ldx   #FD_STDOUT
            jsr   PRHEX8
            pla
            ldx   #FD_STDOUT
            jsr   PRHEX8
            bra   :typ
:undef      ldx   #FD_STDOUT
            lda   #$A0
            jsr   PUTC
*-- PUTC's contract clobbers A AND X (stdio.s SIO_PUTC header);
*-- the four back-to-back calls here used to lean on the OLD
*-- line-buffer body happening to leave A = the byte, and the
*-- probed-buffering rework (docs/PERF-PLAN.md step 4) exposed
*-- it: full-mode PUTC exits with A = a count byte, so three of
*-- the four spaces printed as NULs (check-nm, 2026-08-28).
*-- Reload BOTH registers per call, as the contract requires.
            ldx   #FD_STDOUT
            lda   #$A0
            jsr   PUTC
            ldx   #FD_STDOUT
            lda   #$A0
            jsr   PUTC
            ldx   #FD_STDOUT
            lda   #$A0
            jsr   PUTC

:typ        lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   RECFLAG
            and   #TYPE_EXT
            bne   :isu
            lda   #$D8              ;'X' high-bit
            bra   :ptyp
:isu        lda   #$D5              ;'U' high-bit
:ptyp       ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC

            ldy   #1
            stz   RECIDX
:nlp        lda   RECIDX
            cmp   RECLEN
            beq   :ndone
            lda   (PTR0),y
            jsr   MAKEHI
            ldx   #FD_STDOUT
            jsr   PUTC
            iny
            inc   RECIDX
            bra   :nlp
:ndone      lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

USAGEMSG    asc   "usage: nm [-u] [-g] file..."
            dfb   $8D,$00
ERRMSG      asc   "nm: cannot open "
            dfb   $00
TOOBIG      asc   "nm: too large: "
            dfb   $00
NMOPTS      asc   "ug"
            dfb   0

OPARM       dfb   PCOUNT_OPEN
OPARM_PATH  da    PATHBUF
OPARM_IOBUF da    $0000
OPARM_REF   dfb   0

GFIPARM      dfb   PCOUNT_GFI
GFIPARM_PATH da    PATHBUF
GFIPARM_ACC  dfb   0
GFIPARM_FTYP dfb   0
GFIPARM_AUX  da    0
GFIPARM_STYP dfb   0
GFIPARM_BLKS da    0
GFIPARM_MDT  da    0
GFIPARM_MTM  da    0
GFIPARM_CDT  da    0
GFIPARM_CTM  da    0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    0             ;patched per read, see READFILE
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

PRPARM       dfb   PCOUNT_READ
PRPARM_REF   dfb   0
PRPARM_BUF   da    0
PRPARM_REQ   da    1
PRPARM_TRANS da    0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0
