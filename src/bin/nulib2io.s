*---------------------------------------------------------------
* nulib2io.s -- PRIMITIVES: the three things every other file in
* this program stands on. A read that refuses a short count, a
* seek that does not let LSEEK overwrite the caller's position,
* and a CRC-16 that accumulates without ever choosing a seed --
* because NuFX has five conventions and picking one here would
* be picking the wrong one four times.
*---------------------------------------------------------------

*---------------------------------------------------------------
* RDBYTES -- read RDLEN bytes into (RDPTR), advancing POS by
* what was actually transferred.
*
* A SHORT READ IS A HARD STOP, not a partial parse. Every caller
* here is reading a fixed-size structure -- a 48-byte master
* header, a 16-byte thread record -- so fewer bytes than asked
* means the archive ends inside a structure, and continuing
* would parse whatever happened to be in the buffer from the
* previous read. That is exactly the failure that makes a
* truncated download look like a corrupt archive.
*
* OUT: carry clear = all RDLEN bytes read; carry set = short or
* failed. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
RDBYTES     lda   RDPTR
            sta   RPARM_BUF
            lda   RDPTR+1
            sta   RPARM_BUF+1
            lda   RDLEN
            sta   RPARM_REQ
            lda   RDLEN+1
            sta   RPARM_REQ+1
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :fail
            lda   RPARM_TRANS
            cmp   RDLEN
            bne   :fail
            lda   RPARM_TRANS+1
            cmp   RDLEN+1
            bne   :fail
            clc                      ;POS += RDLEN
            lda   POS
            adc   RDLEN
            sta   POS
            lda   POS+1
            adc   RDLEN+1
            sta   POS+1
            lda   POS+2
            adc   #0
            sta   POS+2
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* SEEKPOS -- put the file mark at POS (SEEK_SET).
*
* LSEEK OVERWRITES THE THREE BYTES AT (PTR0) with where it
* landed, so POS cannot be handed to it directly -- a failed
* seek would leave POS undefined and the walk would continue
* from garbage. It goes through SEEKOFF, and POS is only ever
* written by its own arithmetic.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SEEKPOS     ldx   #0
:cp         lda   POS,x
            sta   SEEKOFF,x
            inx
            cpx   #3
            bne   :cp
            lda   #<SEEKOFF
            sta   PTR0
            lda   #>SEEKOFF
            sta   PTR0+1
            lda   ARCFD
            ldy   #SEEK_SET
            jmp   LSEEK

*---------------------------------------------------------------
* CRCBYTES -- fold CRCLEN bytes at (CRCPTR) into CRCVAL.
*
* CRC-16/XMODEM: poly $1021, MSB first, no final xor, and the
* SEED is the caller's business -- NuFX uses three different
* ones and copying a seed across is the format's classic bug
* (learning:01M0KZQJTHDP01FKPNP1HTWDW7). This routine never
* seeds; it only accumulates, so a caller can feed a CRC from
* several non-adjacent buffers, which is what a record header's
* CRC over "[+6 .. end of the thread array]" actually requires.
*
* Bit-at-a-time, no 512-byte table: the table would cost more
* image bytes than this whole tool and every CRC here runs over
* tens of bytes, not kilobytes.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*---------------------------------------------------------------
* CRCINIT -- build the 512-byte CRC table, once, at startup.
*
* It runs the ORIGINAL bit-serial loop 256 times, which is the
* point: the table is derived from the definition rather than
* stated a second time, so there is no way for the two to
* disagree about the polynomial. 256 entries x 8 bits is ~50k
* cycles, paid once against the ~5.8M the bit loop was costing.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
CRCINIT     ldx   #0
:entry      stx   CRCTMP+1           ;t = x << 8
            stz   CRCTMP
            ldy   #8
:bit        asl   CRCTMP
            rol   CRCTMP+1
            bcc   :nox
            lda   CRCTMP
            eor   #$21
            sta   CRCTMP
            lda   CRCTMP+1
            eor   #$10
            sta   CRCTMP+1
:nox        dey
            bne   :bit
            lda   CRCTMP
            sta   CRCTABL,x
            lda   CRCTMP+1
            sta   CRCTABH,x
            inx
            bne   :entry
            rts

*---------------------------------------------------------------
CRCBYTES    lda   CRCLEN
            ora   CRCLEN+1
            bne   :go
            rts
*-- ONE TABLE LOOKUP A BYTE, not eight shifts. The bit-serial
*-- version this replaces cost ~200 cycles a byte and a sampling
*-- profile put it at 31.9% of `nulib2 -a` -- the single largest
*-- item, ahead of the whole LZW family, which is not where
*-- anyone would have looked. It is the same polynomial and the
*-- same seeds: CRCINIT builds the table FROM the bit loop, so
*-- there is no second definition of the CRC to drift.
:go         ldy   #0
:bytelp     lda   (CRCPTR),y
            eor   CRCVAL+1           ;x = (crc >> 8) ^ b
            tax
            lda   CRCVAL             ;crc = (crc << 8) ^ t[x]
            eor   CRCTABH,x
            sta   CRCVAL+1
            lda   CRCTABL,x
            sta   CRCVAL
            inc   CRCPTR
            bne   :nohi
            inc   CRCPTR+1
:nohi       lda   CRCLEN
            bne   :nodec
            dec   CRCLEN+1
:nodec      dec   CRCLEN
            lda   CRCLEN
            ora   CRCLEN+1
            bne   :bytelp
            rts
