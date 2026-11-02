*---------------------------------------------------------------
* moreio.s -- more's file model (put by more.s; shares its arena
* and zero page). The LINE TABLE: LTAB[i] is the 3-byte offset
* of line i's first byte in the seekable source RDFD. NLINES
* counts the STARTS known so far; the scan (SCANMORE) extends it
* a chunk at a time from SCANPOS, and at end of file settles
* TOTAL (a file that ends in CR has a phantom empty start, which
* is dropped). A pipe on stdin is read here too, spilled to the
* temp file the table indexes (SPILLPUT), so the same READ_AT
* serves both. FETCH copies one line into LINEBUF for the
* searcher; the drawer (moreshow.s SHOWLINE) streams straight
* from READ_AT's chunks and has no length cap.
*---------------------------------------------------------------

*-- TABRESET -- a fresh source: one known start, at 0.
TABRESET    stz   CHK_LEN                ;READ_AT's chunk cache:
            stz   CHK_LEN+1              ;IOBUF: another file
            lda   #1
            sta   NLINES
            stz   NLINES+1
            stz   LTAB
            stz   LTAB+1
            stz   LTAB+2
            stz   SCANPOS
            stz   SCANPOS+1
            stz   SCANPOS+2
            stz   EOFSEEN
            stz   TOTAL
            stz   TOTAL+1
            stz   TABFULL
            lda   #1
            sta   SIZEKNOWN
            rts

*-- SIZEFROMFD -- FSIZE = the source's EOF (LSEEK SEEK_END 0).
SIZEFROMFD  stz   SKBUF
            stz   SKBUF+1
            stz   SKBUF+2
            lda   #<SKBUF
            sta   PTR0
            lda   #>SKBUF
            sta   PTR0+1
            lda   RDFD
            ldy   #SEEK_END
            jsr   LSEEK
            bcs   :zero
            lda   SKBUF
            sta   FSIZE
            lda   SKBUF+1
            sta   FSIZE+1
            lda   SKBUF+2
            sta   FSIZE+2
            rts
:zero       stz   FSIZE
            stz   FSIZE+1
            stz   FSIZE+2
            rts

*---------------------------------------------------------------
* READ_AT -- IOBUF <- up to 256 bytes of RDFD at MP_OFF. OUT:
* MP_NRD = bytes read (1..256), carry clear; carry set and
* MP_NRD = 0 at end of file or on error.
*
* CACHED (2026-09-15): the last chunk read is remembered as
* CHK_BASE (its file offset) + CHK_LEN (its length, 1..256; 0 =
* nothing cached) and IOBUF holds exactly that chunk. OUT is an
* INDEX, not a fresh buffer: X = where MP_OFF's byte sits in
* IOBUF (0 after a real read, the delta on a cache hit) and
* MP_NRD = the END index (CHK_LEN; 256 reads as 0 after X wraps,
* the callers' cpx/bne idiom). A hit costs no LSEEK, no SC_READ
* and no copy. Every caller asks for one LINE at a time and
* lines run 4-5 to a chunk, so a page of 23 lines went to the
* kernel 54 times (each 255-byte READ ~15k cycles: cross-bank
* copy out plus the MLI) for bytes it already held -- 46% of a
* page fill, measured on the fast backend with the card. OFFADV
* steps to the chunk's end, whatever X was. Anything else that
* writes IOBUF (COPYONE's copy-through) clears CHK_LEN; the
* stdin spill in SCANBODY sets it to the bytes it just landed;
* every new source (TABRESET) clears it.
*---------------------------------------------------------------
READ_AT     lda   CHK_LEN
            ora   CHK_LEN+1
            beq   :miss
            lda   MP_OFF                 ;delta = off - base
            sec
            sbc   CHK_BASE
            sta   CHK_DLT
            lda   MP_OFF+1               ;high bytes must be
            sbc   CHK_BASE+1             ;zero; a borrow (the
            bne   :miss                  ;offset is BEFORE the
            lda   MP_OFF+2               ;chunk) leaves $FF here
            sbc   CHK_BASE+2
            bne   :miss
            lda   CHK_LEN+1              ;a 256-byte chunk: any
            bne   :hit                   ;delta 0..255 is inside
            lda   CHK_DLT
            cmp   CHK_LEN                ;else delta < length
            bcs   :miss
:hit        lda   CHK_LEN
            sta   MP_NRD
            lda   CHK_LEN+1
            sta   MP_NRD+1
            ldx   CHK_DLT
            clc
            rts
:miss       lda   MP_OFF
            sta   SKBUF
            lda   MP_OFF+1
            sta   SKBUF+1
            lda   MP_OFF+2
            sta   SKBUF+2
            lda   #<SKBUF
            sta   PTR0
            lda   #>SKBUF
            sta   PTR0+1
            lda   RDFD
            ldy   #SEEK_SET
            jsr   LSEEK
            bcs   :none
            lda   RDFD
            sta   RPARM_REF
            jsr   RDSETUP
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :none
            lda   RPARM_TRANS
            sta   MP_NRD
            lda   RPARM_TRANS+1
            sta   MP_NRD+1
            ora   MP_NRD
            beq   :none
            lda   MP_OFF                 ;IOBUF now holds MP_NRD
            sta   CHK_BASE               ;bytes from MP_OFF
            lda   MP_OFF+1
            sta   CHK_BASE+1
            lda   MP_OFF+2
            sta   CHK_BASE+2
            lda   MP_NRD
            sta   CHK_LEN
            lda   MP_NRD+1
            sta   CHK_LEN+1
            ldx   #0
            clc
            rts
:none       stz   MP_NRD
            stz   MP_NRD+1
            sec
            rts

*-- RDSETUP -- RPARM's buffer and request for one chunk.
RDSETUP     lda   #<IOBUF
            sta   RPARM_BUF
            lda   #>IOBUF
            sta   RPARM_BUF+1
            lda   #<BUFSZ
            sta   RPARM_REQ
            lda   #>BUFSZ
            sta   RPARM_REQ+1
            rts

*-- OFFADV -- MP_OFF = the end of IOBUF's chunk (the next one).
OFFADV      lda   CHK_BASE
            clc
            adc   CHK_LEN
            sta   MP_OFF
            lda   CHK_BASE+1
            adc   CHK_LEN+1
            sta   MP_OFF+1
            lda   CHK_BASE+2
            adc   #0
            sta   MP_OFF+2
            rts

*---------------------------------------------------------------
* SCANMORE -- extend the table by one chunk, or learn EOF.
* MP_LN is the CALLER's (ENSURE loops on it); the body below
* uses it for APPEND and the phantom check, so it is saved here.
*---------------------------------------------------------------
SCANMORE    lda   MP_LN
            pha
            lda   MP_LN+1
            pha
            jsr   SCANBODY
            pla
            sta   MP_LN+1
            pla
            sta   MP_LN
            rts

SCANBODY    lda   TABFULL
            beq   :go
:eofj       jmp   :eof
:go         lda   ISSTDIN
            bne   :stdin
            lda   SCANPOS
            sta   MP_OFF
            lda   SCANPOS+1
            sta   MP_OFF+1
            lda   SCANPOS+2
            sta   MP_OFF+2
            jsr   READ_AT                ;X = SCANPOS's index
            bcs   :eofj
            bra   :sc
:stdin      lda   #FD_STDIN
            sta   RPARM_REF
            jsr   RDSETUP
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :eofj
            lda   RPARM_TRANS
            sta   MP_NRD
            lda   RPARM_TRANS+1
            sta   MP_NRD+1
            ora   MP_NRD
            beq   :eofj
            jsr   SPILLPUT               ;the pipe's bytes land
            bcs   :eofj                  ;in the spill (SCANPOS)
            lda   SCANPOS                ;IOBUF IS that spill
            sta   CHK_BASE               ;chunk: READ_AT's cache
            lda   SCANPOS+1              ;describes it
            sta   CHK_BASE+1
            lda   SCANPOS+2
            sta   CHK_BASE+2
            lda   MP_NRD
            sta   CHK_LEN
            lda   MP_NRD+1
            sta   CHK_LEN+1
            ldx   #0
:sc         lda   IOBUF,x
            cmp   #$8D
            beq   :scnl
            cmp   #$0D                   ;a foreign file's CR
            bne   :sn
:scnl       txa                          ;a line starts at
            clc                          ;CHK_BASE + x + 1
            adc   #1
            sta   MP_ACC
            lda   #0
            adc   #0
            sta   MP_ACC+1
            lda   MP_ACC
            clc
            adc   CHK_BASE
            sta   MP_ACC
            lda   MP_ACC+1
            adc   CHK_BASE+1
            sta   MP_ACC+1
            lda   #0
            adc   CHK_BASE+2
            sta   MP_ACC+2
            phx
            jsr   APPEND
            plx
            lda   TABFULL
            bne   :adv
:sn         inx
            cpx   MP_NRD                 ;256 reads as 0 and X
            bne   :sc                    ;wraps to 0 after 255
:adv        lda   CHK_BASE               ;scanned to the chunk's
            clc                          ;end, wherever X began
            adc   CHK_LEN
            sta   SCANPOS
            lda   CHK_BASE+1
            adc   CHK_LEN+1
            sta   SCANPOS+1
            lda   CHK_BASE+2
            adc   #0
            sta   SCANPOS+2
            rts
*-- end of file (or a full table, which ends what more can
*-- reach): TOTAL settles.
:eof        lda   #1
            sta   EOFSEEN
            lda   NLINES
            sta   TOTAL
            lda   NLINES+1
            sta   TOTAL+1
            lda   NLINES                 ;last start: a phantom
            sec                          ;if it IS the end
            sbc   #1
            sta   MP_LN
            lda   NLINES+1
            sbc   #0
            sta   MP_LN+1
            jsr   GETOFF
            lda   MP_OFF
            cmp   SCANPOS
            bne   :size
            lda   MP_OFF+1
            cmp   SCANPOS+1
            bne   :size
            lda   MP_OFF+2
            cmp   SCANPOS+2
            bne   :size
            lda   TOTAL
            bne   :dec
            dec   TOTAL+1
:dec        dec   TOTAL
:size       lda   ISSTDIN
            beq   :out
            lda   SCANPOS
            sta   FSIZE
            lda   SCANPOS+1
            sta   FSIZE+1
            lda   SCANPOS+2
            sta   FSIZE+2
            lda   #1
            sta   SIZEKNOWN
:out        rts

*-- APPEND -- LTAB[NLINES] = MP_ACC; NLINES++. A full table sets
*-- TABFULL (and says so once) instead of writing past LTAB.
APPEND      lda   NLINES+1
            cmp   #>NLMAX
            bcc   :room
            bne   :full
            lda   NLINES
            cmp   #<NLMAX
            bcc   :room
:full       lda   #1
            sta   TABFULL
            ldx   #FD_STDOUT             ;pending page first
            jsr   SIO_FLUSH
            lda   #<TABMSG
            sta   PTR0
            lda   #>TABMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jmp   PUTS
:room       lda   NLINES
            sta   MP_LN
            lda   NLINES+1
            sta   MP_LN+1
            jsr   LTABADDR
            ldy   #0
            lda   MP_ACC
            sta   (MP_PTR),y
            iny
            lda   MP_ACC+1
            sta   (MP_PTR),y
            iny
            lda   MP_ACC+2
            sta   (MP_PTR),y
            inc   NLINES
            bne   :r
            inc   NLINES+1
:r          rts

*-- LTABADDR -- MP_PTR = LTAB + MP_LN*3.
LTABADDR    lda   MP_LN
            asl   a
            sta   MP_PTR
            lda   MP_LN+1
            rol   a
            sta   MP_PTR+1
            lda   MP_PTR
            clc
            adc   MP_LN
            sta   MP_PTR
            lda   MP_PTR+1
            adc   MP_LN+1
            sta   MP_PTR+1
            lda   MP_PTR
            clc
            adc   #<LTAB
            sta   MP_PTR
            lda   MP_PTR+1
            adc   #>LTAB
            sta   MP_PTR+1
            rts

*-- GETOFF -- MP_OFF = LTAB[MP_LN].
GETOFF      jsr   LTABADDR
            ldy   #0
            lda   (MP_PTR),y
            sta   MP_OFF
            iny
            lda   (MP_PTR),y
            sta   MP_OFF+1
            iny
            lda   (MP_PTR),y
            sta   MP_OFF+2
            rts

*---------------------------------------------------------------
* ENSURE -- does line MP_LN exist? Scans as far as it must.
* OUT: carry clear = yes (its start is in the table); carry set
* = the file ends before it.
*---------------------------------------------------------------
ENSURE      lda   MP_LN                  ;MP_LN+1 < NLINES means
            clc                          ;a start follows it: a
            adc   #1                     ;real line
            sta   MP_TMP
            lda   MP_LN+1
            adc   #0
            sta   MP_TMP+1
            lda   MP_TMP
            cmp   NLINES
            lda   MP_TMP+1
            sbc   NLINES+1
            bcc   :yes
            lda   EOFSEEN
            bne   :final
            jsr   SCANMORE
            bra   ENSURE
:final      lda   MP_LN
            cmp   TOTAL
            lda   MP_LN+1
            sbc   TOTAL+1
            bcc   :yes
            sec
            rts
:yes        clc
            rts

*---------------------------------------------------------------
* FETCH -- LINEBUF <- line MP_LN (to LINEMAX bytes), NUL-ended;
* FLEN = its length. For the searcher. The copy is forced to
* bit 7 SET (RE_MATCH compares high-bit text), so a low-ASCII
* file matches like a maux one; the file is never rewritten.
*---------------------------------------------------------------
FETCH       jsr   GETOFF
            stz   FLEN
:chunk      jsr   READ_AT                ;X = the line's index
            bcs   :done
:cp         lda   IOBUF,x
            cmp   #$8D
            beq   :done
            cmp   #$0D
            beq   :done
            ldy   FLEN
            cpy   #LINEMAX
            bcs   :done
            ;-- engine text is high-bit, so the COPY
            ;-- is normalised on the way in
            ora   #$80
            sta   LINEBUF,y
            inc   FLEN
            inx
            cpx   MP_NRD
            bne   :cp
            jsr   OFFADV
            bra   :chunk
:done       ldy   FLEN
            lda   #0
            sta   LINEBUF,y
            rts

*---------------------------------------------------------------
* The spill: MORE.INxx in the working directory (ex's EX.INxx
* naming -- xx = BANK_ID in hex, so two mores in two banks never
* share one). Created, opened read/write, truncated.
*---------------------------------------------------------------
SPILLMAKE   lda   #<SPILLLIT
            ldx   #>SPILLLIT
            jsr   TMPNAMESET
            lda   #<TMPPATH
            ldx   #>TMPPATH
            jsr   TMPCREATE
            bcs   :fail
            lda   OPARM_REF
            sta   SPILLFD
            sta   EFPARM_REF             ;truncate a stale spill
            lda   #2                     ;from a killed more
            sta   EFPARM
            stz   EFPARM_EOF
            stz   EFPARM_EOF+1
            stz   EFPARM_EOF+2
            lda   #<EFPARM
            ldx   #>EFPARM
            jsr   SC_SETEOF
            clc
            rts
:fail       sec
            rts

*-- TMPNAMESET -- TMPNAME = literal at A/X + two hex digits of
*-- BANK_ID, NUL; then MKPATH it into TMPPATH.
TMPNAMESET  sta   PTR0
            stx   PTR0+1
            ldy   #0
:cp         lda   (PTR0),y
            beq   :cpd
            sta   TMPNAME,y
            iny
            bne   :cp
:cpd        lda   BANK_ID
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            jsr   HEXCH
            sta   TMPNAME,y
            iny
            lda   BANK_ID
            and   #$0F
            jsr   HEXCH
            sta   TMPNAME,y
            iny
            lda   #0
            sta   TMPNAME,y
            lda   #<TMPNAME
            sta   PTR0
            lda   #>TMPNAME
            sta   PTR0+1
            lda   #<TMPPATH
            sta   PTR1
            lda   #>TMPPATH
            sta   PTR1+1
            jmp   MKPATH

*-- TMPCREATE -- create (ignore "exists") and open the MLI path
*-- at A/X; OPARM_REF = the fd, carry set if it will not open.
*-- OPARM_PATH is put back to PATHBUF either way.
TMPCREATE   sta   CRPARM_PATH
            sta   OPARM_PATH
            stx   CRPARM_PATH+1
            stx   OPARM_PATH+1
            lda   #PCOUNT_CREATE
            sta   CRPARM
            lda   #ACCESS_UNLKD
            sta   CRPARM_ACC
            lda   #FTYPE_TXT
            sta   CRPARM_FTY
            stz   CRPARM_AUX
            stz   CRPARM_AUX+1
            lda   #STYP_SEEDLING
            sta   CRPARM_STY
            stz   CRPARM_CDT
            stz   CRPARM_CDT+1
            stz   CRPARM_CTM
            stz   CRPARM_CTM+1
            lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT               ;exists already: fine
            stz   OPARM_IOBUF
            stz   OPARM_IOBUF+1
            lda   #PCOUNT_OPEN           ;a spill / cmd file is
            sta   OPARM                 ;WRITTEN: no read intent
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            php
            lda   #OPEN_RO               ;input opens declare it
            sta   OPARM
            lda   #<PATHBUF
            sta   OPARM_PATH
            lda   #>PATHBUF
            sta   OPARM_PATH+1
            plp
            rts

*-- HEXCH -- A = 0..15 -> its hex digit, high-bit ASCII.
HEXCH       cmp   #10
            bcc   :dig
            adc   #6
:dig        clc
            adc   #"0"
            rts

*-- SPILLPUT -- IOBUF[0..MP_NRD) -> SPILLFD at SCANPOS.
SPILLPUT    lda   SCANPOS
            sta   SKBUF
            lda   SCANPOS+1
            sta   SKBUF+1
            lda   SCANPOS+2
            sta   SKBUF+2
            lda   #<SKBUF
            sta   PTR0
            lda   #>SKBUF
            sta   PTR0+1
            lda   SPILLFD
            ldy   #SEEK_SET
            jsr   LSEEK
            bcs   :fail
            lda   SPILLFD
            sta   WPARM_REF
            lda   #<IOBUF
            sta   WPARM_BUF
            lda   #>IOBUF
            sta   WPARM_BUF+1
            lda   MP_NRD
            sta   WPARM_REQ
            lda   MP_NRD+1
            sta   WPARM_REQ+1
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            bcs   :fail
            clc
            rts
:fail       sec
            rts

*-- SPILLDROP -- close and unlink the spill; unlink MORE.CMDxx.
SPILLDROP   lda   SPILLFD
            beq   :nospill
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            stz   SPILLFD
            lda   #<TMPPATH
            ldx   #>TMPPATH
            jsr   UNLINKP
:nospill    lda   CMDFILE
            beq   :r
            stz   CMDFILE
            lda   #<CMDPATH
            ldx   #>CMDPATH
            jsr   UNLINKP
:r          rts

*-- UNLINKP -- DESTROY the MLI path at A/X (best effort).
UNLINKP     sta   ULPARM_PATH
            stx   ULPARM_PATH+1
            lda   #PCNT_DESTROY
            sta   ULPARM
            lda   #<ULPARM
            ldx   #>ULPARM
            jmp   SC_UNLINK

*---------------------------------------------------------------
* NEXTOFF -- MP_OFF = where the screen ends: line BOT+1's start,
* or FSIZE when there is no such line.
*---------------------------------------------------------------
NEXTOFF     lda   BOT
            clc
            adc   #1
            sta   MP_LN
            lda   BOT+1
            adc   #0
            sta   MP_LN+1
            jsr   ENSURE
            bcs   :end
            jmp   GETOFF
:end        lda   FSIZE
            sta   MP_OFF
            lda   FSIZE+1
            sta   MP_OFF+1
            lda   FSIZE+2
            sta   MP_OFF+2
            rts

*---------------------------------------------------------------
* PCT -- A = MP_OFF * 100 / FSIZE (0..100). Both are shifted
* down together until the size is under 512, so the 16-bit
* product cannot overflow; then a subtract-count divide.
*---------------------------------------------------------------
PCT         lda   FSIZE
            ora   FSIZE+1
            ora   FSIZE+2
            bne   :nz
            lda   #100
            rts
:nz         lda   FSIZE
            sta   MP_ACC
            lda   FSIZE+1
            sta   MP_ACC+1
            lda   FSIZE+2
            sta   MP_ACC+2
            lda   MP_OFF
            sta   SKBUF
            lda   MP_OFF+1
            sta   SKBUF+1
            lda   MP_OFF+2
            sta   SKBUF+2
:shift      lda   MP_ACC+2
            bne   :sh1
            lda   MP_ACC+1
            cmp   #2
            bcc   :ready
:sh1        lsr   MP_ACC+2
            ror   MP_ACC+1
            ror   MP_ACC
            lsr   SKBUF+2
            ror   SKBUF+1
            ror   SKBUF
            bra   :shift
:ready      lda   SKBUF                  ;MP_TMP2 = num * 100
            sta   MP_TMP
            lda   SKBUF+1
            sta   MP_TMP+1
            asl   MP_TMP
            rol   MP_TMP+1
            asl   MP_TMP
            rol   MP_TMP+1               ;*4
            lda   MP_TMP
            sta   MP_TMP2
            lda   MP_TMP+1
            sta   MP_TMP2+1
            asl   MP_TMP
            rol   MP_TMP+1
            asl   MP_TMP
            rol   MP_TMP+1
            asl   MP_TMP
            rol   MP_TMP+1               ;*32
            lda   MP_TMP2
            clc
            adc   MP_TMP
            sta   MP_TMP2
            lda   MP_TMP2+1
            adc   MP_TMP+1
            sta   MP_TMP2+1
            asl   MP_TMP
            rol   MP_TMP+1               ;*64
            lda   MP_TMP2
            clc
            adc   MP_TMP
            sta   MP_TMP2
            lda   MP_TMP2+1
            adc   MP_TMP+1
            sta   MP_TMP2+1
            ldx   #0                     ;X = quotient
:div        lda   MP_TMP2
            cmp   MP_ACC
            lda   MP_TMP2+1
            sbc   MP_ACC+1
            bcc   :done
            lda   MP_TMP2
            sec
            sbc   MP_ACC
            sta   MP_TMP2
            lda   MP_TMP2+1
            sbc   MP_ACC+1
            sta   MP_TMP2+1
            inx
            cpx   #100
            bne   :div
:done       txa
            rts

SPILLLIT    asc   "MORE.IN"
            dfb   0
CMDLIT      asc   "MORE.CMD"
            dfb   0
TABMSG      asc   "more: line table full; the rest is out of"
            asc   " reach"
            dfb   $8D,0
