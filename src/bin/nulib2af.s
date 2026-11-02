*---------------------------------------------------------------
* nulib2af.s -- what `-a` needs from each input FILE: its ProDOS
* metadata, the two passes over its bytes, the date conversion
* and the name it is stored under.
*---------------------------------------------------------------

*---------------------------------------------------------------
* INFO -- GET_FILE_INFO on INPATH into FTYPE/FAUX/FACCESS, and
* the modification stamp into NUFXDATE.
*
* IT DOES NOT GIVE THE LENGTH. GET_FILE_INFO returns
* blocks_used, NOT the EOF, and ls.s's own header says so
* outright: "printing blocks_used*512 as if it were EOF would be
* WRONG". A first version took those bytes as the length anyway,
* with a comment asserting the opposite; every data thread then
* claimed a size of blocks_used with a stray date byte on top,
* and both readers refused the archive. GETLEN asks the open
* file instead.
*
* GET_FILE_INFO CAN FAIL ON A PATH THE KERNEL WILL STILL OPEN.
* ProDOS cannot stat a `/dev/sNdM` path -- it is not a ProDOS
* pathname at all -- so INFO falls back to type $00/no dates
* rather than refusing the whole input (docs/NUFX.md slice 8:
* "the ONE change" `/dev` support needs). NEVER carry set here
* on that path: a genuinely bad path still gets caught, one call
* later, by GETDLEN's own INOPEN -- ADDONE prints the same
* CANTADDM warning either way, so INFO does not need its own
* second opinion on whether the path opens.
* OUT: carry set = GET_FILE_INFO reached the file. Always clear
* otherwise -- see above.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
INFO        lda   #PCOUNT_GFI
            sta   XGPARM
            lda   #<INPATH
            sta   XGPARM_PATH
            lda   #>INPATH
            sta   XGPARM_PATH+1
            lda   #<XGPARM
            ldx   #>XGPARM
            jsr   SC_GFI
            bcs   :nogfi
            lda   XGPARM_ACC
            sta   FACCESS
            lda   XGPARM_FTYP
            sta   FTYPE
            lda   XGPARM_AUX
            sta   FAUX
            lda   XGPARM_AUX+1
            sta   FAUX+1
            jsr   MKDATE
            clc
            rts
:nogfi      stz   FTYPE
            stz   FAUX
            stz   FAUX+1
            lda   #ACCESS_UNLKD      ;full access, unlocked
            sta   FACCESS
            ldy   #0
            lda   #0
:zdt        sta   NUFXDATE,y
            iny
            cpy   #8
            bne   :zdt
            clc
            rts

*---------------------------------------------------------------
* STDINFO -- FTYPE/FAUX/FACCESS/NUFXDATE for a `-` (stdin)
* operand (docs/NUFX-PIPE-NOTES.md), which has no ProDOS path
* for GET_FILE_INFO to stat. Type is $00 for a disk archive
* (thread_kind 1 needs no run-type semantics) or $04/TXT
* otherwise -- the type a shell redirect would make, per
* touch.s's own convention for a file created out of nothing.
*
* DATES ARE ZERO, not "today". The spec's own first cut asked
* for the live clock (SC_CLOCK), which is a genuine 10-byte
* call -- but it lives in syscallp.s, a ~20-routine PROCESS-call
* module this program has never `put`, and pulling the whole
* file in for one of them costs far more than this slice's
* margin (docs/NUFX-PIPE-NOTES.md has the measured delta). Zero
* is not a guess: it is the SAME "no date" stamp this file's own
* INFO already uses one function up, for exactly the same
* reason -- a source with no real timestamp to report -- and
* touch.s's header says the doctrine plainly: "no clock is not
* an error... ls shows -". CLOBBERS: A, X, Y.
*---------------------------------------------------------------
STDINFO     lda   ISDISK
            bne   :isdsk
            lda   #$04                ;TXT
            bra   :settype
:isdsk      lda   #$00
:settype    sta   FTYPE
            stz   FAUX
            stz   FAUX+1
            lda   #ACCESS_UNLKD
            sta   FACCESS
            ldy   #0
            lda   #0
:zdt        sta   NUFXDATE,y
            iny
            cpy   #8
            bne   :zdt
            rts

*---------------------------------------------------------------
* MKDATE -- the ProDOS mod stamp as a NuFX DateTimeRec.
*
* THE TWO FIELDS THAT CATCH PEOPLE: day and month are ZERO-BASED
* in NuFX and one-based in ProDOS, and the year is a full byte
* of year-1900, NOT two digits -- a 2026 stamp stores $7E = 126,
* which is why no century heuristic is needed
* (learning:01M0KZQJTHDP01FKPNP1HTWDW7).
*
* ProDOS's own year is two digits with a pivot at 78
* (docs/PRODOS-VERSION.md, TN #28): 78..99 are 1978..1999, 0..77
* are 2000..2077. Both map to year-1900 by adding 100 below the
* pivot, which is the whole conversion.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
MKDATE      ldy   #0                 ;second: ProDOS has none
            lda   #0
            sta   NUFXDATE
            lda   XGPARM_MTIME       ;minute
            sta   NUFXDATE+1
            lda   XGPARM_MTIME+1     ;hour
            sta   NUFXDATE+2
            lda   XGPARM_MDATE+1     ;year: the high 7 bits
            lsr   a
            cmp   #78
            bcs   :haveyr
            clc
            adc   #100               ;0..77 mean 2000..2077
:haveyr     sta   NUFXDATE+3
            lda   XGPARM_MDATE       ;day: the low 5 bits, and
            and   #$1F               ;NuFX wants it zero-based
            beq   :dayok             ;a zero stamp stays zero
            sec
            sbc   #1
:dayok      sta   NUFXDATE+4
            lda   XGPARM_MDATE+1     ;month: bit 0 of the high
            and   #$01               ;byte is its top bit
            lsr   a
            ror   a
            ror   a
            ror   a
            sta   MDTMP
            lda   XGPARM_MDATE
            and   #$E0
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            ora   MDTMP
            beq   :monok             ;likewise zero-based
            sec
            sbc   #1
:monok      sta   NUFXDATE+5
            stz   NUFXDATE+6         ;filler
            stz   NUFXDATE+7         ;weekday: 0 = not supplied
            rts

*---------------------------------------------------------------
* FILECRC -- PASS ONE. Read the whole input and fold it into
* DCRC, seeded $FFFF because that is what a v3 thread_crc uses.
* Nothing is written. See nulib2add.s's header for why the file
* has to be read twice.
* OUT: carry set = could not read it. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- ITS ONE CALLER IS `-0`. PACK1 checksums as it codes, so the
*-- ordinary path has no use for a separate pass -- this exists
*-- for the flag that asks for no coding at all.
FILECRC     jsr   INOPEN
            bcs   :bad
            jsr   GETLEN             ;the real EOF
            bcs   :bad
            lda   #$FF
            sta   DCRC
            sta   DCRC+1
:lp         jsr   INCHUNK
            bcs   :eof
            lda   DCRC
            sta   CRCVAL
            lda   DCRC+1
            sta   CRCVAL+1
            lda   #<XBUF
            sta   CRCPTR
            lda   #>XBUF
            sta   CRCPTR+1
            lda   RPARM_TRANS
            sta   CRCLEN
            lda   RPARM_TRANS+1
            sta   CRCLEN+1
            jsr   CRCBYTES
            lda   CRCVAL
            sta   DCRC
            lda   CRCVAL+1
            sta   DCRC+1
            bra   :lp
:eof        jsr   INCLOSE
            clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* FILECOPY -- PASS TWO. The same bytes, this time into the
* archive. OUT: carry set = a read or a write failed.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
FILECOPY    jsr   INOPEN
            bcs   :bad
:lp         jsr   INCHUNK
            bcs   :eof
            lda   #<XBUF
            sta   WPARM_BUF
            lda   #>XBUF
            sta   WPARM_BUF+1
            lda   RPARM_TRANS
            sta   WPARM_REQ
            lda   RPARM_TRANS+1
            sta   WPARM_REQ+1
            lda   ADDFD
            sta   WPARM_REF
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            bcs   :werr
            clc                      ;the archive grew
            lda   ARCEOF
            adc   WPARM_REQ
            sta   ARCEOF
            lda   ARCEOF+1
            adc   WPARM_REQ+1
            sta   ARCEOF+1
            lda   ARCEOF+2
            adc   #0
            sta   ARCEOF+2
            bra   :lp
:eof        jsr   INCLOSE
            clc
            rts
:werr       jsr   INCLOSE
:bad        sec
            rts

*---------------------------------------------------------------
* GETLEN -- DLEN := the open file's length, and the mark back to
* the start. LSEEK reports where it landed, so seeking to the
* END is how you ask a ProDOS file how long it is without
* trusting a directory field that means something else.
* OUT: carry set = the seek failed. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
GETLEN      stz   SEEKOFF
            stz   SEEKOFF+1
            stz   SEEKOFF+2
            lda   #<SEEKOFF
            sta   PTR0
            lda   #>SEEKOFF
            sta   PTR0+1
            lda   INFD
            ldy   #SEEK_END
            jsr   LSEEK
            bcs   :bad
            ldx   #0
:cp         lda   SEEKOFF,x
            sta   DLEN,x
            inx
            cpx   #3
            bne   :cp
            stz   SEEKOFF            ;and back to the beginning
            stz   SEEKOFF+1
            stz   SEEKOFF+2
            lda   #<SEEKOFF
            sta   PTR0
            lda   #>SEEKOFF
            sta   PTR0+1
            lda   INFD
            ldy   #SEEK_SET
            jmp   LSEEK
:bad        sec
            rts

*---------------------------------------------------------------
* INOPEN / INCHUNK / INCLOSE -- the input file, read through
* XBUF. INCHUNK returns carry set at end of file, which for this
* reader means "nothing more", not "something went wrong": a
* short read here is ordinary, unlike RDBYTES's.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
INOPEN      lda   #PCOUNT_OPEN
            sta   IOPARM
            lda   #<INPATH
            sta   IOPARM_PATH
            lda   #>INPATH
            sta   IOPARM_PATH+1
            stz   IOPARM_IOBUF
            stz   IOPARM_IOBUF+1
            lda   #<IOPARM
            ldx   #>IOPARM
            jsr   SC_OPEN
            bcs   :bad
            lda   IOPARM_REF
            sta   INFD
            sta   ICPARM_REF
            lda   #PCOUNT_CLOSE
            sta   ICPARM
            clc
            rts
:bad        sec
            rts

INCHUNK     lda   #PCOUNT_READ
            sta   RPARM
            lda   INFD
            sta   RPARM_REF
            lda   #<XBUF
            sta   RPARM_BUF
            lda   #>XBUF
            sta   RPARM_BUF+1
            lda   #XBUFSZ
            sta   RPARM_REQ
            stz   RPARM_REQ+1
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :none
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :none
            clc
            rts
:none       sec
            rts

INCLOSE     lda   #<ICPARM
            ldx   #>ICPARM
            jmp   SC_CLOSE

*---------------------------------------------------------------
* LEAFIN -- NAMEPAD := the last component of the operand, and
* NAMELEN its length. A record stores a leaf; this writer does
* not build directory records, and nulib2(1) says so.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- THE INDEX ADVANCES BEFORE THE LOAD, not after. INPATH is
*-- count-prefixed, so the byte after the last separator sits at
*-- MDTMP+1 and the copy must reach it. A first version
*-- incremented twice before its first load and stored "BB.BIN"
*-- for BBB.BIN -- still a legal ProDOS name, which is why
*-- nothing downstream complained about it.
LEAFIN      stz   MDTMP              ;last separator index, 0
            stz   NAMELEN            ;when there is none
            ldy   #0
:scan       cpy   INPATH
            beq   :scanned
            iny
            lda   INPATH,y
            cmp   #$2F               ;'/' -- an MLI path is
            bne   :scan              ;7-bit, so a bare compare
            sty   MDTMP              ;is right here
            bra   :scan
:scanned    ldx   MDTMP
            ldy   #0
:cpy        cpx   INPATH
            beq   :done
            inx
            lda   INPATH,x
            sta   NAMEPAD,y
            iny
            cpy   #FNALLOC
            bne   :cpy
:done       sty   NAMELEN
            rts

*---------------------------------------------------------------
* STEMNAME -- NAMEPAD/NAMELEN := PATHBUF's (the ARCHIVE's OWN
* name) last component, stopping at its FIRST '.' --
* "/mnt/MAUX/FLOP.SDK" -> "FLOP". Used only for a `-` (stdin)
* operand, whose own name a pipe cannot supply
* (docs/NUFX-PIPE-NOTES.md); a leaf with no '.' at all keeps its
* whole name. FIRST dot, not last (os.path.splitext's rule) --
* cheaper code (no separate "was a dot seen" scratch byte, one
* comparison per character instead of two) and every fixture
* this project's own `-a` names has exactly one dot; a name
* with more than one stops at the first, a documented,
* untriggered corner rather than the general rule.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
STEMNAME    stz   MDTMP              ;last '/' in PATHBUF, 0 if
            ldy   #0                 ;none
:scan       cpy   PATHBUF
            beq   :scanned
            iny
            lda   PATHBUF,y
            cmp   #$2F               ;'/'
            bne   :scan
            sty   MDTMP
            bra   :scan
:scanned    ldx   MDTMP
            ldy   #0
:cpy2       cpx   PATHBUF
            beq   :done2
            inx
            lda   PATHBUF,x
            cmp   #$2E               ;'.' ends the stem
            beq   :done2
            sta   NAMEPAD,y
            iny
            cpy   #FNALLOC
            bne   :cpy2
:done2      sty   NAMELEN
            rts

*---------------------------------------------------------------
* ADDWARN / ARCFAIL -- a file that could not be added is named
* and SKIPPED (records already written stay valid); a failure
* of the ARCHIVE itself stops the run, because everything after
* it would be written into a file that is already wrong.
* IN: A/X = message low/high. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
ADDWARN     sta   XMSGL
            stx   XMSGH
            lda   #<XPFX
            sta   PTR0
            lda   #>XPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   FIDX
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   XMSGL
            sta   PTR0
            lda   XMSGH
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            sta   ERRFLAG
            rts

ARCFAIL     sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT
