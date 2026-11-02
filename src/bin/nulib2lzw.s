*---------------------------------------------------------------
* nulib2lzw.s -- the COMPRESSED STREAM: ShrinkIt's chunking, and
* the run-length layer that rides with it.
*
* Both LZW formats cut the input into 4096-byte chunks, because
* that is one track of a 5.25-inch floppy -- the LZW began as a
* disk packer and the chunk size is disk geometry
* (learning:01M31QSJ9K6V389DEVKMW9CBTK). Everything here follows
* from that: which layers a chunk declares, the zero padding a
* short final chunk still carries, and the two CRCs that
* disagree about whether the padding counts.
*
* The LZW ALGORITHM itself is nulib2lzc.s. This file decides
* what to hand it and what to do with the answer.
*---------------------------------------------------------------

*---------------------------------------------------------------
* LZWFORK -- expand the record's LZW/1 data fork to OUTFD. The
* file mark is already at the thread's first byte and REMAIN
* holds thread_eof. OUT: carry set = the stream was malformed;
* the caller reports and keeps what was written.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- LZW/2's stream header is two bytes, not four: it has no CRC
*-- of its own. LZW/1's is the only integrity check
*-- a v1 record has, which is why that format keeps it and this
*-- one moved the job to the thread header.
LZWFORK     lda   #4
            ldx   LZ_T2
            beq   :hdrlen
            lda   #2
:hdrlen     sta   RDLEN
            stz   RDLEN+1
            lda   #<LZ_HDR
            sta   RDPTR
            lda   #>LZ_HDR
            sta   RDPTR+1
            jsr   RDBYTES
            bcc   :nb1
            jmp   :bad
:nb1
            ldx   LZ_T2
            bne   :t2hdr
            lda   LZ_HDR
            sta   LZ_SCRC
            lda   LZ_HDR+1
            sta   LZ_SCRC+1
            lda   LZ_HDR+3
            sta   LZ_ESC
            bra   :seeded
:t2hdr      lda   LZ_HDR+1           ;volume, escape -- no CRC
            sta   LZ_ESC
:seeded
*-- TWO CRCs, and they are different conventions over different
*-- bytes -- copying one into the other is the mistake this
*-- format invites (learning:01M0KZQJTHDP01FKPNP1HTWDW7).
*--   LZ_CCRC  seeds $0000 over every chunk's FULL 4096 bytes,
*--            padding included, and is what the stream header
*--            carries. It is the only integrity check a v1
*--            record has.
*--   LZ_TCRC  seeds $FFFF over the bytes actually WRITTEN, and
*--            is the record's thread_crc -- meaningful only on
*--            a v3 record, which is the caller's test to make.
*-- The thread CRC is handed back in CRCVAL so the stored and
*-- the compressed paths verify through the same code.
            stz   LZ_CCRC
            stz   LZ_CCRC+1
            lda   #$FF
            sta   LZ_TCRC
            sta   LZ_TCRC+1
            stz   LZ_RSTFIX
            lda   #$01               ;an empty table: $0101
            sta   LZ_ENTRY+1
            lda   #$01
            sta   LZ_ENTRY
:chunklp    lda   REMAIN
            ora   REMAIN+1
            ora   REMAIN+2
            beq   :done
            jsr   LZCHUNK
            bcc   :nb2
            jmp   :bad
:nb2
            bra   :chunklp
:done       lda   LZ_TCRC            ;hand the thread CRC back
            sta   CRCVAL
            lda   LZ_TCRC+1
            sta   CRCVAL+1
            lda   LZ_T2
            bne   :nostrm            ;LZW/2 has no stream CRC
            lda   LZ_CCRC            ;the stream's own CRC, over
            cmp   LZ_SCRC            ;every PADDED chunk byte
            bne   :crcbad
            lda   LZ_CCRC+1
            cmp   LZ_SCRC+1
            bne   :crcbad
:nostrm     clc
            rts
:crcbad     sec
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* LZCHUNK -- one 4096-byte chunk: read its header, undo the
* layers it declares, fold the whole 4 KB into the stream CRC,
* and write the part of it that belongs to the file.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- LZW/2's chunk header is a u16 whose HIGH BIT is the lzw flag
*-- and whose low 13 bits are rle_len, optionally followed by a
*-- second u16 giving the compressed length -- which COUNTS
*-- ITSELF, hence the -4. LZW/1 spends a whole byte on the flag
*-- instead. Read the two bytes they share first, then decide.
LZCHUNK     lda   #2
            sta   RDLEN
            stz   RDLEN+1
            lda   #<LZ_CHDR
            sta   RDPTR
            lda   #>LZ_CHDR
            sta   RDPTR+1
            jsr   RDBYTES
            bcc   :nb3
            jmp   :bad
:nb3
            lda   LZ_CHDR
            sta   LZ_RLEN
            lda   LZ_CHDR+1
            sta   LZ_RLEN+1
            lda   LZ_T2
            bne   :t2chdr
            lda   #1                 ;LZW/1: the flag is its own
            sta   RDLEN              ;byte, after the length
            stz   RDLEN+1
            lda   #<LZ_CHDRFLG
            sta   RDPTR
            lda   #>LZ_CHDRFLG
            sta   RDPTR+1
            jsr   RDBYTES
            bcc   :gotflag
            jmp   :bad
:gotflag    lda   LZ_CHDRFLG
            cmp   #2
            bcc   :flagok            ;flag > 1: garbled header
            jmp   :bad
:flagok     sta   LZ_FLAG
            bra   :haveflag
:t2chdr     stz   LZ_FLAG            ;LZW/2: bit 15 is the flag
            lda   LZ_RLEN+1
            bpl   :t2nolzw
            inc   LZ_FLAG
:t2nolzw    lda   LZ_RLEN+1          ;and rle_len is 13 bits
            and   #$1F
            sta   LZ_RLEN+1
            lda   LZ_FLAG
            beq   :haveflag
            lda   #2                 ;the compressed length
            sta   RDLEN
            stz   RDLEN+1
            lda   #<LZ_XLEN
            sta   RDPTR
            lda   #>LZ_XLEN
            sta   RDPTR+1
            jsr   RDBYTES
            bcc   :gotxlen
            jmp   :bad
:gotxlen    sec                      ;the field counts itself
            lda   LZ_XLEN
            sbc   #4
            sta   LZ_XLEN
            lda   LZ_XLEN+1
            sbc   #0
            sta   LZ_XLEN+1
            bcs   :haveflag
            jmp   :bad                ;it underflowed
*-- Where the chunk BODY starts, captured after the WHOLE header
*-- (two bytes for LZW/2, three for LZW/1), because
*-- the LZW path finds its own end by counting the bytes its
*-- codes consumed and seeks to CHKSTART plus that.
:haveflag   ldx   #0
:svlp       lda   POS,x
            sta   CHKSTART,x
            inx
            cpx   #3
            bne   :svlp
*-- rle_len must be 1..4096, and == 4096 means "no RLE layer".
            lda   LZ_RLEN
            ora   LZ_RLEN+1
            bne   :nz
            jmp   :bad
:nz
            lda   LZ_RLEN+1
            cmp   #$10
            bcc   :lenok
            beq   :maybe
            jmp   :bad
:maybe      lda   LZ_RLEN
            beq   :lenok
            jmp   :bad
:lenok      stz   LZ_RUSED
            lda   LZ_RLEN+1
            cmp   #$10
            bne   :isrle
            lda   LZ_RLEN
            bne   :isrle
            bra   :haverle
:isrle      lda   #1
            sta   LZ_RUSED
:haverle    jsr   LZWRITELN          ;min(REMAIN, 4096)
            lda   LZ_FLAG
            beq   :nolzw
            jsr   LZCODES            ;-> LZ_OUT, LZ_RLEN bytes
            bcc   :nb4
            jmp   :bad
:nb4
            ldx   #0                 ;the codes ended where they
:nxlp       lda   CHKSTART,x         ;ended; step exactly there
            sta   POS,x
            inx
            cpx   #3
            bne   :nxlp
            clc
            lda   POS
            adc   LZ_USED
            sta   POS
            lda   POS+1
            adc   LZ_USED+1
            sta   POS+1
            lda   POS+2
            adc   #0
            sta   POS+2
            jsr   SEEKPOS
*-- LZW/2 DECLARES how many bytes its codes occupy, so a decoder
*-- that drifted by even one is caught here rather than at the
*-- next chunk header. LZW/1 declares nothing and has only its
*-- stream CRC at the very end.
            lda   LZ_T2
            beq   :noxlen
            lda   LZ_USED
            cmp   LZ_XLEN
            bne   :xbad
            lda   LZ_USED+1
            cmp   LZ_XLEN+1
            beq   :noxlen
:xbad       jmp   :bad
:noxlen     lda   LZ_RUSED
            beq   :fromout
            jsr   LZRLE              ;LZ_OUT -> LZ_CHUNK
            bcc   :nb5
            jmp   :bad
:nb5
            bra   :emit
:fromout    jsr   LZOUT2CHK
            bra   :emit
*-- A CHUNK THAT WAS NOT LZW CODED EMPTIES THE TABLE. LZW/2
*-- carries its table across chunk boundaries, but only across
*-- COMPRESSED ones: a stored or RLE-only chunk resets it, and a
*-- decoder that kept the old table would read the next chunk's
*-- codes against entries the encoder had already discarded.
:nolzw      lda   #$01
            sta   LZ_ENTRY
            sta   LZ_ENTRY+1
            stz   LZ_RSTFIX
            lda   LZ_RUSED
            beq   :stored
            lda   LZ_RLEN            ;RLE only: read it raw
            sta   RDLEN
            lda   LZ_RLEN+1
            sta   RDLEN+1
            lda   #<LZ_OUT
            sta   RDPTR
            lda   #>LZ_OUT
            sta   RDPTR+1
            jsr   RDBYTES
            bcc   :nb6
            jmp   :bad
:nb6
            jsr   LZRLE
            bcc   :nb7
            jmp   :bad
:nb7
            bra   :emit
*-- STORED: read only what will be written and zero the rest.
*-- Stepping over a whole 4096 here desynchronises the next
*-- chunk header on the final, padded chunk.
:stored     lda   LZ_WLEN
            sta   RDLEN
            lda   LZ_WLEN+1
            sta   RDLEN+1
            lda   #<LZ_CHUNK
            sta   RDPTR
            lda   #>LZ_CHUNK
            sta   RDPTR+1
            jsr   RDBYTES
            bcc   :nb8
            jmp   :bad
:nb8
            jsr   LZPADCHK
:emit       lda   LZ_T2              ;the stream CRC is LZW/1's
            bne   :nochcrc           ;alone
            jsr   LZCRCCHK
:nochcrc    jsr   LZTCRC
            jsr   LZWRITE
            bcc   :nb9
            jmp   :bad
:nb9
            sec                      ;REMAIN -= write_len
            lda   REMAIN
            sbc   LZ_WLEN
            sta   REMAIN
            lda   REMAIN+1
            sbc   LZ_WLEN+1
            sta   REMAIN+1
            lda   REMAIN+2
            sbc   #0
            sta   REMAIN+2
            clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* LZWRITELN -- LZ_WLEN := min(REMAIN, 4096). CLOBBERS: A.
*---------------------------------------------------------------
LZWRITELN   lda   REMAIN+2
            bne   :full
            lda   REMAIN+1
            cmp   #$10
            bcs   :full
            lda   REMAIN
            sta   LZ_WLEN
            lda   REMAIN+1
            sta   LZ_WLEN+1
            rts
:full       stz   LZ_WLEN
            lda   #$10
            sta   LZ_WLEN+1
            rts

*---------------------------------------------------------------
* LZPADCHK -- zero LZ_CHUNK from LZ_WLEN to 4096, so a short
* final chunk still folds its padding into the stream CRC.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZPADCHK    lda   #<LZ_CHUNK
            clc
            adc   LZ_WLEN
            sta   LZCP
            lda   #>LZ_CHUNK
            adc   LZ_WLEN+1
            sta   LZCP+1
            sec                      ;count = 4096 - write_len
            lda   #0
            sbc   LZ_WLEN
            sta   LZ_TMP
            lda   #$10
            sbc   LZ_WLEN+1
            sta   LZ_TMP+1
            ldy   #0
:lp         lda   LZ_TMP
            ora   LZ_TMP+1
            beq   :done
            lda   #0
            sta   (LZCP),y
            inc   LZCP
            bne   :nohi
            inc   LZCP+1
:nohi       lda   LZ_TMP
            bne   :nodec
            dec   LZ_TMP+1
:nodec      dec   LZ_TMP
            bra   :lp
:done       rts

*---------------------------------------------------------------
* LZOUT2CHK -- a chunk that was LZW coded but NOT run-length
* coded decodes straight to its 4096 bytes, so LZ_OUT already
* holds the chunk. Copy rather than alias: LZCRCCHK and LZWRITE
* both read LZ_CHUNK, and one buffer pretending to be the other
* is how a later edit breaks quietly. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZOUT2CHK   lda   #<LZ_OUT
            sta   LZOP
            lda   #>LZ_OUT
            sta   LZOP+1
            lda   #<LZ_CHUNK
            sta   LZCP
            lda   #>LZ_CHUNK
            sta   LZCP+1
            ldx   #$10               ;16 pages of 256
            ldy   #0
:lp         lda   (LZOP),y
            sta   (LZCP),y
            iny
            bne   :lp
            inc   LZOP+1
            inc   LZCP+1
            dex
            bne   :lp
            rts

*---------------------------------------------------------------
* LZCRCCHK -- fold all 4096 bytes of LZ_CHUNK into LZ_CCRC.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZCRCCHK    lda   LZ_CCRC
            sta   CRCVAL
            lda   LZ_CCRC+1
            sta   CRCVAL+1
            lda   #<LZ_CHUNK
            sta   CRCPTR
            lda   #>LZ_CHUNK
            sta   CRCPTR+1
            stz   CRCLEN
            lda   #$10
            sta   CRCLEN+1
            jsr   CRCBYTES
            lda   CRCVAL
            sta   LZ_CCRC
            lda   CRCVAL+1
            sta   LZ_CCRC+1
            rts

*---------------------------------------------------------------
* LZTCRC -- fold the bytes this chunk CONTRIBUTES TO THE FILE --
* write_len of them, not the padded 4096 -- into LZ_TCRC. That
* is what a v3 thread_crc covers. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZTCRC      lda   LZ_TCRC
            sta   CRCVAL
            lda   LZ_TCRC+1
            sta   CRCVAL+1
            lda   #<LZ_CHUNK
            sta   CRCPTR
            lda   #>LZ_CHUNK
            sta   CRCPTR+1
            lda   LZ_WLEN
            sta   CRCLEN
            lda   LZ_WLEN+1
            sta   CRCLEN+1
            jsr   CRCBYTES
            lda   CRCVAL
            sta   LZ_TCRC
            lda   CRCVAL+1
            sta   LZ_TCRC+1
            rts

*---------------------------------------------------------------
* LZWRITE -- LZ_WLEN bytes of LZ_CHUNK to OUTFD.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZWRITE     lda   #<LZ_CHUNK
            sta   WPARM_BUF
            lda   #>LZ_CHUNK
            sta   WPARM_BUF+1
            lda   LZ_WLEN
            sta   WPARM_REQ
            lda   LZ_WLEN+1
            sta   WPARM_REQ+1
            jmp   XPUT

*---------------------------------------------------------------
* LZRLE -- expand LZ_RLEN bytes of LZ_OUT into a full 4096-byte
* LZ_CHUNK. `<escape> <byte> <count>` repeats byte count+1
* times, so a run spans 1..256, and a lone escape byte is
* itself coded as a run of one. Both ends must come out exact: a
* run overrunning 4 KB means a damaged chunk, not one to clip.
* OUT: carry set = malformed. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LZRLE       lda   #<LZ_OUT
            sta   LZOP
            lda   #>LZ_OUT
            sta   LZOP+1
            lda   #<LZ_CHUNK
            sta   LZCP
            lda   #>LZ_CHUNK
            sta   LZCP+1
            lda   LZ_RLEN            ;input bytes left
            sta   LZ_ILEFT
            lda   LZ_RLEN+1
            sta   LZ_ILEFT+1
            stz   LZ_OLEFT           ;output bytes still wanted
            lda   #$10
            sta   LZ_OLEFT+1
            ldy   #0
:lp         lda   LZ_OLEFT
            ora   LZ_OLEFT+1
            beq   :full
            jsr   LZINBYTE
            bcc   :nb10
            jmp   :bad
:nb10
            cmp   LZ_ESC
            beq   :esc
            jsr   LZPUTB
            bra   :lp
:esc        jsr   LZINBYTE           ;the repeated value
            bcc   :nb11
            jmp   :bad
:nb11
            sta   LZ_RVAL
            jsr   LZINBYTE           ;count-1
            bcc   :nb12
            jmp   :bad
:nb12
            sta   LZ_RCNT
            inc   LZ_RCNT            ;1..256: a wrapped 0 counts
                                     ;down through 256 exactly
:runlp      lda   LZ_OLEFT
            ora   LZ_OLEFT+1
            beq   :bad               ;the run overruns 4 KB
            lda   LZ_RVAL
            jsr   LZPUTB
            dec   LZ_RCNT
            bne   :runlp
            bra   :lp
:full       lda   LZ_ILEFT           ;every input byte must have
            ora   LZ_ILEFT+1         ;been used, or this was not
            bne   :bad               ;the chunk it claimed to be
            clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* LZINBYTE -- one byte from LZ_OUT via LZOP, decrementing
* LZ_ILEFT. OUT: carry set = the input ran out.
* CLOBBERS: A, Y (Y left 0).
*---------------------------------------------------------------
LZINBYTE    lda   LZ_ILEFT
            ora   LZ_ILEFT+1
            beq   :out
            ldy   #0
            lda   (LZOP),y
            inc   LZOP
            bne   :nohi
            inc   LZOP+1
:nohi       pha
            lda   LZ_ILEFT
            bne   :nodec
            dec   LZ_ILEFT+1
:nodec      dec   LZ_ILEFT
            pla
            clc
            rts
:out        sec
            rts

*---------------------------------------------------------------
* LZPUTB -- store A into LZ_CHUNK via LZCP, decrementing
* LZ_OLEFT. The caller has already checked there is room.
* CLOBBERS: Y (left 0).
*---------------------------------------------------------------
LZPUTB      ldy   #0
            sta   (LZCP),y
            inc   LZCP
            bne   :nohi
            inc   LZCP+1
:nohi       pha
            lda   LZ_OLEFT
            bne   :nodec
            dec   LZ_OLEFT+1
:nodec      dec   LZ_OLEFT
            pla
            rts
