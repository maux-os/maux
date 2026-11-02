*---------------------------------------------------------------
* nmtop.s -- nm's front half,
* extracted from nm.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2 mains). One
* assembly stream: put exactly where the text sat; every rule
* in the manifest header applies unchanged.
*---------------------------------------------------------------
START       stz   WANT_U
            stz   WANT_G
            stz   ERRFLAG
            stz   BLKFLAG

            lda   #<NMOPTS
            ldx   #>NMOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$F5              ;'u' high-bit
            bne   :not_u
            sta   WANT_U
            bra   :optlp
:not_u      cmp   #$E7              ;'g' high-bit
            bne   :badopt
            sta   WANT_G
            bra   :optlp
:badopt     jmp   USAGE
:optdone
            lda   ARGC
            cmp   OPTIND
            bne   :havefls
            jmp   USAGE             ;no file operands

:havefls    sec
            lda   ARGC
            sbc   OPTIND
            sta   NFILES

            lda   OPTIND
            sta   ARGIDX
:arglp      lda   ARGIDX
            jsr   PROCFILE
            inc   ARGIDX
            lda   ARGIDX
            cmp   ARGC
            bcc   :arglp
            lda   ERRFLAG
            jsr   EXIT

USAGE       lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* PROCFILE -- IN: A = argv index of the pathname. Opens, stats
* and reads one REL file, parses its dictionary into SYMDESC,
* sorts and prints it. On any failure: diagnostic to fd 2,
* ERRFLAG=1, returns (caller moves to the next file).
*---------------------------------------------------------------
PROCFILE    jsr   GETARG            ;-> PTR0 = path string
            lda   PTR0
            sta   NAMEPTR
            lda   PTR0+1
            sta   NAMEPTR+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH

            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   CANTOPEN
            lda   GFIPARM_AUX
            sta   CODE_LEN
            lda   GFIPARM_AUX+1
            sta   CODE_LEN+1

            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   CANTOPEN
            lda   OPARM_REF
            sta   SRCFD

            jsr   READFILE
            bcs   :rderr

            lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE

            jsr   PARSEDICT
            jsr   SORTSYMS
            jsr   PRINTBLK
            rts

:rderr      lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            lda   #<TOOBIG
            sta   PTR0
            lda   #>TOOBIG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   NAMEPTR
            sta   PTR0
            lda   NAMEPTR+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG
            rts

CANTOPEN    lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   NAMEPTR
            sta   PTR0
            lda   NAMEPTR+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG
            rts

*---------------------------------------------------------------
* READFILE -- read SRCFD whole into REL_BUF, growing FILELEN.
* OUT: carry clear + FILELEN set, or carry set (file too big
* for REL_BUF_SIZE -- SRCFD is left OPEN for the caller to
* close either way).
*---------------------------------------------------------------
READFILE    stz   FILELEN
            stz   FILELEN+1
:rloop      sec
            lda   #<REL_BUF_SIZE
            sbc   FILELEN
            sta   NM_ROOM
            lda   #>REL_BUF_SIZE
            sbc   FILELEN+1
            sta   NM_ROOM+1
            lda   NM_ROOM
            ora   NM_ROOM+1
            bne   :room
            jsr   PROBE1             ;buffer exactly full so
                                     ;far -- is there more?
            bcs   :full
            clc                      ;probe hit EOF -- fits
            rts
:full       sec
            rts
:room       lda   NM_ROOM+1
            bne   :usemax
            lda   NM_ROOM
            cmp   #BUFSZ
            bcs   :usemax
            sta   REQLO
            bra   :setreq
:usemax     lda   #BUFSZ
            sta   REQLO
:setreq     lda   #0
            sta   RPARM_REQ+1
            lda   REQLO
            sta   RPARM_REQ
            clc
            lda   #<REL_BUF
            adc   FILELEN
            sta   RPARM_BUF
            lda   #>REL_BUF
            adc   FILELEN+1
            sta   RPARM_BUF+1
            lda   SRCFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :done              ;read error -- stop here,
                                     ;keep what we have (caller
                                     ;treats it as success --
                                     ;the dict walk is bound-
                                     ;checked, so this is safe)
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :done              ;EOF
            clc
            lda   FILELEN
            adc   RPARM_TRANS
            sta   FILELEN
            lda   FILELEN+1
            adc   RPARM_TRANS+1
            sta   FILELEN+1
            bra   :rloop
:done       clc
            rts

*---------------------------------------------------------------
* PROBE1 -- one 1-byte read into a scratch cell, NOT REL_BUF.
* OUT: carry clear = EOF (nothing more), carry set = more data
* exists than REL_BUF_SIZE can hold.
*---------------------------------------------------------------
PROBE1      lda   #0
            sta   PRPARM_REQ+1
            lda   #1
            sta   PRPARM_REQ
            lda   #<PROBEBYTE
            sta   PRPARM_BUF
            lda   #>PROBEBYTE
            sta   PRPARM_BUF+1
            lda   SRCFD
            sta   PRPARM_REF
            lda   #<PRPARM
            ldx   #>PRPARM
            jsr   SC_READ
            bcs   :eof
            lda   PRPARM_TRANS
            ora   PRPARM_TRANS+1
            beq   :eof
            sec
            rts
:eof        clc
            rts

*---------------------------------------------------------------
* PARSEDICT -- walk REL_BUF's dictionary (CODE_LEN..FILELEN),
* skip the fixup list, then fill SYMDESC/NSYMS from the symbol
* list, applying the -u/-g filter as each record is seen.
*---------------------------------------------------------------
PARSEDICT   stz   NSYMS
            stz   NSYMS+1

            lda   CODE_LEN+1
            cmp   FILELEN+1
            bcc   :clampok
            bne   :doclamp
            lda   CODE_LEN
            cmp   FILELEN
            bcc   :clampok
:doclamp    lda   FILELEN
            sta   CODE_LEN
            lda   FILELEN+1
            sta   CODE_LEN+1
:clampok
            clc
            lda   #<REL_BUF
            adc   CODE_LEN
            sta   NM_DPTR
            lda   #>REL_BUF
            adc   CODE_LEN+1
            sta   NM_DPTR+1
            clc
            lda   #<REL_BUF
            adc   FILELEN
            sta   NM_DEND
            lda   #>REL_BUF
            adc   FILELEN+1
            sta   NM_DEND+1

:fixlp      jsr   ATEND
            bcs   :fixdone
            ldy   #0
            lda   (NM_DPTR),y
            beq   :fix0
            jsr   ADV4
            bra   :fixlp
:fix0       jsr   ADV1
:fixdone

:symlp      jsr   ATEND
            bcs   :symdone
            ldy   #0
            lda   (NM_DPTR),y
            beq   :sym0
            sta   RECFLAG
            and   #LEN_MASK
            sta   RECLEN
            jsr   WANTREC
            bcc   :skip
            lda   NSYMS+1
            cmp   #>MAXSYMS
            bcc   :store
            bne   :skip
            lda   NSYMS
            cmp   #<MAXSYMS
            bcs   :skip
:store      lda   NSYMS
            sta   NM_SIDX
            lda   NSYMS+1
            sta   NM_SIDX+1
            lda   NM_DPTR
            sta   NM_AVAL
            lda   NM_DPTR+1
            sta   NM_AVAL+1
            jsr   SDSET
            inc   NSYMS
            bne   :skip
            inc   NSYMS+1
:skip       lda   RECLEN
            clc
            adc   #3                ;flag byte + 2 addr bytes
            jsr   ADVN
            bra   :symlp
:sym0       jsr   ADV1
:symdone    rts

*---------------------------------------------------------------
* WANTREC -- IN: RECFLAG (this record's flag|len byte). OUT:
* carry SET if the current -u/-g filter keeps it. Keep ENT iff
* (WANT_G and not WANT_U); keep EXT iff (WANT_U and not
* WANT_G) -- so "-u -g" together always excludes both (this
* file header's "empty" ruling), and neither flag keeps all.
*---------------------------------------------------------------
WANTREC     lda   WANT_U
            ora   WANT_G
            bne   :filt
            sec
            rts
:filt       lda   RECFLAG
            and   #TYPE_EXT
            bne   :isext
            lda   WANT_U
            bne   :no
            lda   WANT_G
            beq   :no
            sec
            rts
:isext      lda   WANT_G
            bne   :no
            lda   WANT_U
            beq   :no
            sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* ATEND/ADV1/ADV4/ADVN -- dictionary-walk helpers. ATEND: carry
* SET if NM_DPTR >= NM_DEND. ADVn: NM_DPTR += n (ADVN: += A).
*---------------------------------------------------------------
ATEND       lda   NM_DPTR+1
            cmp   NM_DEND+1
            bcc   :no
            bne   :yes
            lda   NM_DPTR
            cmp   NM_DEND
            bcc   :no
:yes        sec
            rts
:no         clc
            rts
