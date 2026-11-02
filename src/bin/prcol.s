*---------------------------------------------------------------
* prcol.s -- pr's multi-column engine (-column, -a, -w, -s):
* COLINIT/DIE/FILLPAGE/TABPTR/CALCROWS/PRFILEC/PRROWS/PRROW/
* CELLSEP/GETCELL/COPYCELL. `put` by src/bin/pr.s (NOT a
* standalone binary). The -m merge driver is prmrg.s; both share
* PRROW.
*
* DESIGN. Down/across modes buffer one PAGE of lines: a table of
* 16-bit pointers (TAB, TABMAX entries) into a text arena (ARENA
* .. ARENAEND) holding [len][chars] records, each already
* truncated to the column's text width. A page is R*N lines
* where
* R = body lines per column (page length - 10, or the page
* length
* itself under -t; halved under -d). A page that does not fit
* either store is a LOUD failure (exit 1), never a short page.
* Cell (row r, column c) is line r + c*ROWS (down) or r*N + c
* (across); ROWS = ceil(lines on this page / N), so a short last
* page is as short as it can be (XCU leaves the balance
* unspecified; BSD fills the left columns first and so does
* this).
*
* WIDTH. Text width TW = (W - (N-1)) / N, column stride TW+1 --
* the XCU rule, equal to both hosts' numbers for the default 72
* and for every -w measured. -w default is 72, or 512 under -s.
* Without -s, W above 255 is refused (columns are tracked in 8
* bits).
*
* The emitter (prout.s) pads cell to cell with spaces; -i
* (assumed
* for N>1, per XCU) contracts them to tabs exactly as the
* hosts do.
*---------------------------------------------------------------

*---------------------------------------------------------------
* DIE -- IN: PTR0 -> message (CR-terminated, NUL-ended). Writes
* it to stderr and exits 1.
*---------------------------------------------------------------
DIE         ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

*---------------------------------------------------------------
* COLINIT -- after OPTPARSE: derive the geometry, or die.
* CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
COLINIT     lda   MFLAG
            beq   :nom
            lda   NGIVEN
            beq   :mn
            lda   #<MMSG
            sta   PTR0
            lda   #>MMSG
            sta   PTR0+1
            jsr   DIE
:mn         lda   ARGC
            sec
            sbc   ARGIDX
            bne   :mc
            lda   #1
:mc         cmp   #NMAXM+1
            bcc   :ms
            lda   #<MAXMSG
            sta   PTR0
            lda   #>MAXMSG
            sta   PTR0+1
            jsr   DIE
:ms         sta   NCOLS
*-- each real file takes a slot of the process's 8-entry fd
* table
*-- (stdin, stdout, stderr hold three); "-" is stdin, no new
* slot
            stz   FIDX
            stz   ANY
:cf         lda   FIDX
            cmp   NCOLS
            bcs   :cfd
            lda   ARGIDX
            cmp   ARGC
            bcs   :cfd
            clc
            adc   FIDX
            jsr   GETARG
            lda   (PTR0)
            cmp   #$AD
            bne   :cfr
            ldy   #1
            lda   (PTR0),y
            beq   :cfn
:cfr        inc   ANY
:cfn        inc   FIDX
            bra   :cf
:cfd        lda   ANY
            cmp   #NFILEM+1
            bcc   :cfok
            lda   #<MAXMSG
            sta   PTR0
            lda   #>MAXMSG
            sta   PTR0+1
            jsr   DIE
:cfok
:nom        lda   NCOLS
            cmp   #2
            bcc   :nci
            lda   #1
            sta   IFLAG
:nci        lda   TFLAG
            bne   :et1
            lda   PAGELEN
            cmp   #11
            bcs   :et0
:et1        lda   #1
            sta   EFFT
            lda   PAGELEN
            bra   :rset
:et0        stz   EFFT
            lda   PAGELEN
            sec
            sbc   #10
:rset       ldx   DFLAG
            beq   :rd
            lsr   a
:rd         cmp   #0
            bne   :rok
            lda   #1
:rok        sta   ROWSCAP
            lda   MFLAG
            bne   :wd
            lda   NCOLS
            cmp   #2
            bcs   :wd
            rts
:wd         lda   HAVEW
            bne   :wg
            lda   SFLAG
            bne   :w512
            lda   #72
            sta   WIDTH
            stz   WIDTH+1
            bra   :wset
:w512       stz   WIDTH
            lda   #2
            sta   WIDTH+1
            bra   :wset
:wg         stz   WIDTH+1
:wset       lda   SFLAG
            bne   :wok
            lda   WIDTH+1
            bne   :wbig
            lda   WIDTH
            cmp   #$FF
            bcc   :wok
:wbig       lda   #<WIDEMSG
            sta   PTR0
            lda   #>WIDEMSG
            sta   PTR0+1
            jsr   DIE
:wok        lda   WIDTH
            sec
            adc   #0
            sta   DV
            lda   WIDTH+1
            adc   #0
            sta   DV+1
            lda   DV
            sec
            sbc   NCOLS
            sta   DV
            lda   DV+1
            sbc   #0
            sta   DV+1
            bcs   :wdiv
            jmp   :wsmall
:wdiv       stz   TW
:wlp        lda   DV+1
            bne   :wsub
            lda   DV
            cmp   NCOLS
            bcc   :wdone
:wsub       lda   DV
            sec
            sbc   NCOLS
            sta   DV
            lda   DV+1
            sbc   #0
            sta   DV+1
            inc   TW
            bra   :wlp
:wdone      lda   TW
            bne   :wgood
:wsmall     lda   #<NARROWMSG
            sta   PTR0
            lda   #>NARROWMSG
            sta   PTR0+1
            jsr   DIE
:wgood      clc
            adc   #1
            sta   STRIDE
*-- number prefix width and the text width left in a cell
            stz   NUMPFX
            lda   HAVEN
            beq   :np0
            lda   NCHAR
            cmp   #TABCH
            bne   :npc
            lda   NWIDTH
            clc
            adc   #8
            and   #$F8
            bra   :nps
:npc        lda   NWIDTH
            clc
            adc   #1
:nps        sta   NUMPFX
:np0        lda   TW
            sec
            sbc   NUMPFX
            beq   :a0one
            bcs   :a0set
:a0one      lda   #1
:a0set      sta   AVAIL0
            lda   TW
            ldx   MFLAG
            bne   :anset
            ldx   HAVEN
            beq   :anset
            lda   AVAIL0
:anset      sta   AVAILN
*-- CAPLN = ROWSCAP * NCOLS
            stz   CAPLN
            stz   CAPLN+1
            lda   MFLAG
            bne   :cdone
            ldx   ROWSCAP
:cml        lda   CAPLN
            clc
            adc   NCOLS
            sta   CAPLN
            bcc   :cmn
            inc   CAPLN+1
:cmn        dex
            bne   :cml
            lda   CAPLN+1
            cmp   #>TABMAX
            bcc   :cdone
            bne   :cbig
            lda   CAPLN
            cmp   #<TABMAX+1
            bcc   :cdone
:cbig       lda   #<PAGEMSG
            sta   PTR0
            lda   #>PAGEMSG
            sta   PTR0+1
            jsr   DIE
:cdone      rts

*---------------------------------------------------------------
* TABPTR -- IN: IDX. OUT: PTR0 -> TAB entry IDX. CLOBBERS: A.
*---------------------------------------------------------------
TABPTR      lda   IDX
            asl   a
            sta   PTR0
            lda   IDX+1
            rol   a
            sta   PTR0+1
            lda   PTR0
            clc
            adc   #<TAB
            sta   PTR0
            lda   PTR0+1
            adc   #>TAB
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* FILLPAGE -- read up to CAPLN lines into the arena. OUT: CNT =
* lines read; FILLEOF set once the file is exhausted. A page
* that
* overflows the arena dies. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
FILLPAGE    stz   CNT
            stz   CNT+1
            stz   FILLEOF
            lda   #<ARENA
            sta   ARP
            lda   #>ARENA
            sta   ARP+1
:fl         lda   CNT+1
            cmp   CAPLN+1
            bcc   :rd
            bne   :fdone
            lda   CNT
            cmp   CAPLN
            bcs   :fdone
:rd         jsr   READLN
            bcc   :got
            lda   #1
            sta   FILLEOF
:fdone      rts
:got        lda   LLEN
            cmp   AVAILN
            bcc   :lok
            lda   AVAILN
:lok        sta   SLEN
            lda   ARP
            sec
            adc   SLEN
            sta   DV
            lda   ARP+1
            adc   #0
            sta   DV+1
            cmp   #>ARENAEND
            bcc   :room
            bne   :full
            lda   DV
            bne   :full
:room       lda   CNT
            sta   IDX
            lda   CNT+1
            sta   IDX+1
            jsr   TABPTR
            lda   ARP
            sta   (PTR0)
            ldy   #1
            lda   ARP+1
            sta   (PTR0),y
            lda   ARP
            sta   PTR0
            lda   ARP+1
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
:cpd        lda   DV
            sta   ARP
            lda   DV+1
            sta   ARP+1
            inc   CNT
            bne   :cn
            inc   CNT+1
:cn         lda   RLEOF
            bne   :feof
            jmp   :fl
:feof       lda   #1
            sta   FILLEOF
            rts
:full       lda   #<PAGEMSG
            sta   PTR0
            lda   #>PAGEMSG
            sta   PTR0+1
            jsr   DIE

*---------------------------------------------------------------
* CALCROWS -- ROWS = ceil(CNT / NCOLS). CLOBBERS: A.
*---------------------------------------------------------------
CALCROWS    stz   ROWS
            lda   CNT
            sta   DV
            lda   CNT+1
            sta   DV+1
:cr         lda   DV
            ora   DV+1
            beq   :crd
            inc   ROWS
            lda   DV
            sec
            sbc   NCOLS
            sta   DV
            lda   DV+1
            sbc   #0
            sta   DV+1
            bcs   :cr
:crd        rts

*---------------------------------------------------------------
* PRFILEC -- paginate CURFD in down/across columns, using
* FNAMEPTR/HDATE/HTIME already set by the caller. CLOBBERS: all.
*---------------------------------------------------------------
PRFILEC     lda   #<CBUF
            sta   PTR2
            lda   #>CBUF
            sta   PTR2+1
            stz   BUFPOS
            stz   BUFLEN
            stz   RLEOF
            lda   #1
            sta   PAGENUM
            sta   LINENOLO
            stz   LINENOHI
:page       jsr   FILLPAGE
            lda   CNT
            ora   CNT+1
            beq   :done
            jsr   CALCROWS
            jsr   VISIBLE
            bcc   :adv
            lda   EFFT
            bne   :nh
            jsr   PRINTHDR
:nh         jsr   PRROWS
            lda   EFFT
            bne   :adv
            lda   ROWS
            ldx   DFLAG
            beq   :np
            asl   a
:np         sta   PB_PAD
            lda   PAGELEN
            sec
            sbc   #5
            sec
            sbc   PB_PAD
            jsr   PGEND
:adv        clc
            lda   LINENOLO
            adc   CNT
            sta   LINENOLO
            lda   LINENOHI
            adc   CNT+1
            sta   LINENOHI
            inc   PAGENUM
            lda   FILLEOF
            beq   :page
:done       rts

*---------------------------------------------------------------
* PRROWS -- print ROWS rows of the filled page. CLOBBERS: all.
*---------------------------------------------------------------
PRROWS      stz   ROWI
            stz   ROWIDX
            stz   ROWIDX+1
            stz   COLSTEP+1
            lda   AFLAG
            bne   :ac
            lda   #1
            sta   ROWSTEP
            lda   ROWS
            sta   COLSTEP
            bra   :go
:ac         lda   NCOLS
            sta   ROWSTEP
            lda   #1
            sta   COLSTEP
:go         jsr   PRROW
            inc   ROWI
            lda   ROWIDX
            clc
            adc   ROWSTEP
            sta   ROWIDX
            bcc   :nc
            inc   ROWIDX+1
:nc         lda   ROWI
            cmp   ROWS
            bcc   :go
            rts

*---------------------------------------------------------------
* PRROW -- one output row: IN ROWIDX = index of its first cell
* (down/across); the -m driver has MEXIST/MCELL filled instead.
* CLOBBERS: all.
*---------------------------------------------------------------
PRROW       jsr   PUTOFS
            jsr   EMBEG
            lda   ROWIDX
            sta   IDX
            lda   ROWIDX+1
            sta   IDX+1
            lda   OFFSETVAL
            sta   COLPOS
            stz   COLI
            stz   LASTCOL
            lda   MFLAG
            beq   :cell
            lda   HAVEN
            beq   :cell
            lda   LINENOLO
            sta   U2DEC_VAL
            lda   LINENOHI
            sta   U2DEC_VAL+1
            jsr   EMNUM
:cell       lda   COLI
            cmp   NCOLS
            bcs   :end
            lda   MFLAG
            bne   :mcell
            lda   IDX+1
            cmp   CNT+1
            bcc   :ex
            bne   :absent
            lda   IDX
            cmp   CNT
            bcs   :absent
:ex         jsr   GETCELL
            bra   :show
:mcell      ldx   COLI
            lda   MEXIST,x
            beq   :absent
            jsr   GETMCELL
:show       jsr   CELLSEP
            lda   HAVEN
            beq   :txt
            lda   MFLAG
            bne   :txt
            clc
            lda   LINENOLO
            adc   IDX
            sta   U2DEC_VAL
            lda   LINENOHI
            adc   IDX+1
            sta   U2DEC_VAL+1
            jsr   EMNUM
:txt        jsr   EMITLBUF
:absent     inc   COLI
            lda   COLPOS
            clc
            adc   STRIDE
            sta   COLPOS
            lda   IDX
            clc
            adc   COLSTEP
            sta   IDX
            lda   IDX+1
            adc   COLSTEP+1
            sta   IDX+1
            bra   :cell
:end        jsr   EMCR
            lda   DFLAG
            beq   :rd
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:rd         rts

*---------------------------------------------------------------
* CELLSEP -- before a present cell: one -s separator per column
* crossed, or spaces up to the column's start. CLOBBERS: all.
*---------------------------------------------------------------
CELLSEP     lda   COLI
            sec
            sbc   LASTCOL
            beq   :csd
            ldx   SFLAG
            beq   :pad
            sta   CSN
:sl         lda   SEPCH
            jsr   EMCH
            dec   CSN
            bne   :sl
            bra   :csd
:pad        lda   COLPOS
            jsr   EMPADTO
:csd        lda   COLI
            sta   LASTCOL
            rts

*---------------------------------------------------------------
* GETCELL -- IN: IDX. Loads that line into LBUF/LLEN.
* GETMCELL -- IN: COLI. Same, from the -m cell page.
* COPYCELL -- IN: PTR0 -> [len][chars]. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
GETCELL     jsr   TABPTR
            ldy   #1
            lda   (PTR0),y
            pha
            lda   (PTR0)
            sta   PTR0
            pla
            sta   PTR0+1
            bra   COPYCELL
GETMCELL    stz   PTR0
            clc
            lda   MCELLPG
            adc   COLI
            sta   PTR0+1
COPYCELL    lda   (PTR0)
            sta   LLEN
            ldx   #0
            ldy   #1
:gc         cpx   LLEN
            beq   :gcd
            lda   (PTR0),y
            sta   LBUF,x
            inx
            iny
            bra   :gc
:gcd        rts

MMSG        asc   "pr: -m cannot be used with -column"
            dfb   $8D,$00
MAXMSG      asc   "pr: -m takes at most 5 files (fd table)"
            dfb   $8D,$00
WIDEMSG     asc   "pr: -w over 254 needs -s"
            dfb   $8D,$00
NARROWMSG   asc   "pr: page width too small for the columns"
            dfb   $8D,$00
PAGEMSG     asc   "pr: a page of columns does not fit in memory"
            dfb   $8D,$00
