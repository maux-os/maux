*---------------------------------------------------------------
* nulib2rle.s -- COMPRESSING on the way out, stage 1: the
* run-length layer, written as a thread_format $0003 stream.
*
* AN RLE-ONLY THREAD IS A COMPLETELY VALID LZW/2 THREAD. Bit 15
* of a chunk's length word is the LZW flag; leave it clear and
* the chunk is RLE-only (rle_len < 4096) or stored (rle_len ==
* 4096). Every reader accepts it. So the whole run-length half
* of ShrinkIt's compression is reachable without writing an LZW
* encoder at all.
*
* AND LZW/2 IS THE EASIER TARGET TO WRITE, which is the opposite
* of the reading side. LZW/1 carries a stream CRC over every
* chunk INCLUDING the last one's zero padding; LZW/2 has none,
* and its extra per-chunk length word appears only when the LZW
* flag is set -- which this encoder never sets.
*
* THE DECISION IS PER CHUNK, as the format intends: a chunk RLE
* makes smaller is emitted run-length coded, one it does not is
* stored outright, and neither costs the other anything. That is
* the same property that lets a mixed archive avoid losing to
* its worst region (Lesson 9's A/B/C argument,
* learning:01M31QSJ9K6V389DEVKMW9CBTK).
*
* WHY RLE IS WORTH HAVING AT ALL, given it does little for text:
* it was put in the format for DISK TRACKS. McFadden: "If more
* or all of a *disk* track is empty, RLE is a win, but it just
* doesn't happen all that often in text files." Padded files,
* zero-filled images and sparse data are exactly what a machine
* hands back to a host.
*---------------------------------------------------------------

*---------------------------------------------------------------
* RLECHUNK -- run-length code 4096 bytes of LZ_CHUNK into
* LZ_OUT, leaving the length in RLELEN.
*
* A run of four or more becomes <escape> <byte> <count-1>; runs
* over 256 split into maximal 256-byte pieces; and a run of ONE
* TO THREE escape bytes is coded as a run anyway, because a bare
* escape byte would be read back as the start of one.
*
* THAT LAST CLAUSE IS WHERE NufxLib IS WRONG. Its encoder emits
* the 1..3-byte tail of a long escape-byte run literally
* (Lzw.c:214, on the reasoning that three literal bytes beat a
* three-byte code), and its own decoder then reads those
* literals as an escape sequence -- a 257-byte run of $DB
* round-trips to 8 bytes. This codes the tail as a run.
* Correcting an ENCODER bug is safe in a way that correcting a
* decoder bug is not: only our own output has to survive it
* (learning:01M0M67H5Y79780K1KY69W8PTN).
*
* OUT: carry clear = RLELEN holds the coded length; carry set =
* the coding would exceed 4096 bytes, so this chunk cannot be
* represented (rle_len is 13 bits) and the caller must store it.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*---------------------------------------------------------------
* RLESCAN -- is this chunk worth run-length coding AT ALL?
* Carry clear = yes, carry set = no, do not bother.
*
* IT IS EXACT, NOT A HEURISTIC. With no run of four or more and
* no byte equal to the escape, every byte of the coding would be
* a literal and the coded length would come to exactly 4096 --
* which is the value that already means "not run-length coded".
* So skipping produces the same archive, byte for byte.
*
* WHY IT PAYS: the coding pass costs ~140 cycles a byte and this
* costs ~27, and it stops the moment it finds a reason to code.
* A profile put RLECHUNK and RLEPUT together at 17.7% of
* `nulib2 -a`, nearly all of it on text chunks that then threw
* the coding away.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
RLESCAN     lda   #<LZ_CHUNK
            sta   LZOP
            lda   #>LZ_CHUNK
            sta   LZOP+1
            ldx   #LZSTKHI           ;4096 bytes, a page at a
            ldy   #0                 ;time
            lda   (LZOP),y
            sta   RLEVAL
            stz   RLERUN             ;bytes seen equal SO FAR
:pg         lda   (LZOP),y
            cmp   LZ_ESC
            beq   :yes
            cmp   RLEVAL
            bne   :newv
            inc   RLERUN
            lda   RLERUN
            cmp   #3                 ;the fourth equal byte
            bcs   :yes
            bra   :nx
:newv       sta   RLEVAL
            stz   RLERUN
:nx         iny
            bne   :pg
            inc   LZOP+1
            dex
            bne   :pg
            sec
            rts
:yes        clc
            rts

*---------------------------------------------------------------
RLECHUNK    lda   #<LZ_CHUNK
            sta   LZOP
            lda   #>LZ_CHUNK
            sta   LZOP+1
            lda   #<LZ_OUT
            sta   LZCP
            lda   #>LZ_OUT
            sta   LZCP+1
            stz   RLELEN
            stz   RLELEN+1
            stz   RLEIN
            stz   RLEIN+1
:scan       lda   RLEIN+1            ;every input byte consumed?
            cmp   #$10
            bcc   :more
            clc                      ;yes: done
            rts
:more       ldy   #0
            lda   (LZOP),y
            sta   RLEVAL             ;the byte this run is of
*-- FAST PATH: A BYTE UNLIKE THE NEXT ONE IS A RUN OF ONE, and
*-- that is most bytes of most files. Taking it here skips the
*-- run counter, the over-256 split and the length tests -- a
*-- profile put this routine plus RLEPUT at 21.6% of `nulib2 -a`
*-- and ~230 cycles a byte, nearly all of it spent proving that
*-- a literal was a literal.
*--
*-- The compare reads one byte PAST the last, deliberately
*-- and harmless: it is only ever compared, and if it happens to
*-- match, the slow path counts the run to the chunk end and
*-- still emits one byte.
            iny
            cmp   (LZOP),y
            beq   :slow
            cmp   LZ_ESC             ;the escape is never plain
            beq   :slow
            lda   RLEVAL
            jsr   RLEPUT
            bcc   :fastok
            jmp   :toobig
:fastok     inc   LZOP
            bne   :fnohi
            inc   LZOP+1
:fnohi      inc   RLEIN
            bne   :fscan
            inc   RLEIN+1
:fscan      jmp   :scan
:slow       stz   RLERUN             ;run length, 16-bit because
            stz   RLERUN+1           ;a chunk-long run is 4096
:runlp      ldy   #0
            lda   (LZOP),y
            cmp   RLEVAL
            bne   :runend
            inc   LZOP                ;consume it
            bne   :nohi
            inc   LZOP+1
:nohi       inc   RLERUN
            bne   :nrhi
            inc   RLERUN+1
:nrhi       inc   RLEIN
            bne   :nihi
            inc   RLEIN+1
:nihi       lda   RLEIN+1            ;stop at the chunk's end
            cmp   #$10
            bcc   :runlp
:runend
*-- Split anything over 256 into whole 256-byte codes first, so
*-- the tail below is 1..256 and fits a single count byte.
:biglp      lda   RLERUN+1         ;while run > 256
            cmp   #2
            bcs   :isbig             ;>= 512
            cmp   #1
            bne   :notbig            ;<= 255
            lda   RLERUN
            beq   :notbig            ;exactly 256 is the TAIL,
:isbig      lda   RLEVAL             ;not a split
            ldx   #255
            jsr   RLECODE
            bcs   :toobig
            sec                      ;run -= 256
            lda   RLERUN
            sbc   #0
            sta   RLERUN
            lda   RLERUN+1
            sbc   #1
            sta   RLERUN+1
            bra   :biglp
:notbig
*-- The tail. A run of four or more pays for a three-byte code;
*-- a shorter one does not, UNLESS the byte is the escape, which
*-- must be coded whatever its length.
            lda   RLERUN+1
            bne   :ascode            ;256 exactly
            lda   RLERUN
            cmp   #4
            bcs   :ascode
            ldx   RLEVAL
            cpx   LZ_ESC
            beq   :ascode
:aslit      lda   RLEVAL             ;emit it plainly, run times
            jsr   RLEPUT
            bcs   :toobig
            dec   RLERUN
            bne   :aslit
            jmp   :scan
:ascode     lda   RLEVAL
            ldx   RLERUN             ;count-1, and a run of 256
            dex                      ;gives 255
            jsr   RLECODE
            bcs   :toobig
            jmp   :scan
:toobig     sec
            rts

*---------------------------------------------------------------
* RLECODE -- emit <escape> <A> <X>. CLOBBERS: A, Y.
* OUT: carry set = the output would overrun 4096.
*---------------------------------------------------------------
RLECODE     sta   RLECV
            stx   RLECC
            lda   LZ_ESC
            jsr   RLEPUT
            bcs   :full
            lda   RLECV
            jsr   RLEPUT
            bcs   :full
            lda   RLECC
            jmp   RLEPUT
:full       sec
            rts

*---------------------------------------------------------------
* RLEPUT -- one byte into LZ_OUT. Refuses past 4096: rle_len is
* thirteen bits, so a longer coding cannot be described and the
* caller has to store the chunk instead.
* OUT: carry set = full. CLOBBERS: Y.
*---------------------------------------------------------------
RLEPUT      pha
            lda   RLELEN+1
            cmp   #$10
            bcs   :full
            pla
            ldy   #0
            sta   (LZCP),y
            inc   LZCP
            bne   :nohi
            inc   LZCP+1
:nohi       inc   RLELEN
            bne   :done
            inc   RLELEN+1
:done       clc
            rts
:full       pla
            sec
            rts

*---------------------------------------------------------------
* RDCHUNK -- up to 4096 bytes of the input into LZ_CHUNK, ZERO
* PADDED to a full chunk, with the real count in WL.
*
* The padding is what the format asks for: "If the last piece of
* the file doesn't fill an entire 4K chunk, then the rest of the
* 4K chunk is filled with zeros. The ENTIRE chunk is compressed,
* zeros and all" (Lesson 9). It is also why RLE earns its keep
* on a short final chunk -- those zeros code to three bytes.
* OUT: carry set = nothing left. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- STDIN (docs/NUFX-PIPE-NOTES.md) SHARES THIS ROUTINE rather
*-- than a second copy of it: a pipe's own SC_READ is SHORT well
*-- before EOF (measured -- docs/NUFX-PIPE-NOTES.md has the
*-- actual size), so treating one short read as "that is the
*-- whole chunk" the way a real ProDOS file safely can would
*-- zero-pad real data still in flight and corrupt everything
*-- after it. The fix generalizes rather than duplicates: WL is
*-- the TARGET this chunk is trying to reach (REMAIN-derived for
*-- a file, always 4096 for stdin, since a pipe's total length
*-- is not known ahead of time -- that is the whole reason DLEN
*-- starts at 0 for it), and :doread LOOPS, accumulating into
*-- PIPEOFF, until either the target is reached or a read
*-- returns trans=0 (true EOF, never carry-set for a clean
*-- end -- learning:01M0PYBMS4TSKS0RW5N2NAENV2). A real
*-- file's own reads are never short except exactly at that
*-- target, so this loop runs its body once for a file, same as
*-- the single-shot version it replaces.
RDCHUNK     lda   STDINFLAG
            bne   :pipetgt
            lda   REMAIN
            ora   REMAIN+1
            ora   REMAIN+2
            bne   :some
            sec
            rts
:some       lda   REMAIN+2           ;WL = min(REMAIN, 4096)
            bne   :full
            lda   REMAIN+1
            cmp   #$10
            bcs   :full
            lda   REMAIN
            sta   WL
            lda   REMAIN+1
            sta   WL+1
            bra   :havewl
:full       stz   WL
            lda   #$10
            sta   WL+1
            bra   :havewl
:pipetgt    stz   WL                 ;stdin: always try for a
            lda   #$10               ;full 4096-byte chunk
            sta   WL+1
:havewl     stz   PIPEOFF            ;bytes actually IN this
            stz   PIPEOFF+1          ;chunk so far
:doread     lda   #PCOUNT_READ
            sta   RPARM
            lda   INFD
            sta   RPARM_REF
            clc
            lda   #<LZ_CHUNK
            adc   PIPEOFF
            sta   RPARM_BUF
            lda   #>LZ_CHUNK
            adc   PIPEOFF+1
            sta   RPARM_BUF+1
            sec                      ;request = WL - PIPEOFF
            lda   WL
            sbc   PIPEOFF
            sta   RPARM_REQ
            lda   WL+1
            sbc   PIPEOFF+1
            sta   RPARM_REQ+1
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :maybedone
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :maybedone
            clc
            lda   PIPEOFF
            adc   RPARM_TRANS
            sta   PIPEOFF
            lda   PIPEOFF+1
            adc   RPARM_TRANS+1
            sta   PIPEOFF+1
            lda   PIPEOFF
            cmp   WL
            bne   :doread
            lda   PIPEOFF+1
            cmp   WL+1
            bne   :doread
            bra   :finish
:maybedone  lda   PIPEOFF
            ora   PIPEOFF+1
            bne   :finish
            sec
            rts
*-- WHATEVER ARRIVED (PIPEOFF, which for a file is always the
*-- ORIGINAL target WL unless something failed early) becomes
*-- the real count, padded and dispatched by source: a file
*-- counts it against REMAIN; a pipe has none to count against,
*-- so DLEN grows by it instead.
:finish     lda   PIPEOFF
            sta   WL
            lda   PIPEOFF+1
            sta   WL+1
            jsr   PADCHUNK
            lda   STDINFLAG
            bne   :pipedone
            sec                      ;REMAIN -= WL
            lda   REMAIN
            sbc   WL
            sta   REMAIN
            lda   REMAIN+1
            sbc   WL+1
            sta   REMAIN+1
            lda   REMAIN+2
            sbc   #0
            sta   REMAIN+2
            clc
            rts
:pipedone   lda   WL
            ldx   WL+1
            jsr   DLADD
            clc
            rts

*---------------------------------------------------------------
* PADCHUNK -- zero LZ_CHUNK from WL to 4096. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PADCHUNK    lda   #<LZ_CHUNK
            clc
            adc   WL
            sta   LZCP
            lda   #>LZ_CHUNK
            adc   WL+1
            sta   LZCP+1
            sec
            lda   #0
            sbc   WL
            sta   RLERUN
            lda   #$10
            sbc   WL+1
            sta   RLERUN+1
            ldy   #0
:lp         lda   RLERUN
            ora   RLERUN+1
            beq   :done
            lda   #0
            sta   (LZCP),y
            inc   LZCP
            bne   :nohi
            inc   LZCP+1
:nohi       lda   RLERUN
            bne   :nodec
            dec   RLERUN+1
:nodec      dec   RLERUN
            bra   :lp
:done       rts

*---------------------------------------------------------------
* CHUNKPREP -- THE ONE PLACE A CHUNK'S FORM IS DECIDED. Both
* passes call it and neither decides anything itself.
*
* It used to matter because there WERE two passes -- a pricer
* and a writer that each ran the coder and each applied their
* own test -- and the first time they disagreed (an escape byte
* set in one and not the other) comp_thread_eof became a lie and
* both readers failed inside the chunk. There is one pass now,
* so that class of bug is gone by construction rather than by
* discipline. The routine stays: PACK1 needs exactly one answer
* per chunk, and a single place to change when a fourth chunk
* shape turns up.
*
* IN:  LZ_CHUNK = the 4096-byte padded chunk, WL = the bytes of
*      it that belong to the file.
* OUT: CHKIND 0 stored / 1 RLE only / 2 LZW, CHBUF/CHLEN the
*      body, CHRLEN the rle_len field.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- The two buffers TRADE PLACES rather than a third being
*-- allocated. Whichever of them holds the form this chunk falls
*-- back to is the one the coder must not touch, and the other
*-- is free by construction: if RLE won, the raw chunk is spent
*-- and the codes go there; if RLE lost, its output is spent
*-- instead.
CHUNKPREP   jsr   RLESCAN            ;nothing to code? do not
            bcs   :norle             ;spend a pass proving it
            jsr   RLECHUNK
            bcs   :norle
            lda   RLELEN+1           ;a coding of 4096 or more
            cmp   #$10               ;cannot be described, and
            bcs   :norle             ;would not help anyway
            lda   #1
            sta   CHKIND
            lda   RLELEN
            sta   CHLEN
            sta   CHRLEN
            lda   RLELEN+1
            sta   CHLEN+1
            sta   CHRLEN+1
            lda   #<LZ_OUT
            sta   CHBUF
            sta   LZE_IP
            lda   #>LZ_OUT
            sta   CHBUF+1
            sta   LZE_IP+1
            lda   #<LZ_CHUNK
            sta   LZE_OP
            lda   #>LZ_CHUNK
            sta   LZE_OP+1
            bra   :sized
*-- rle_len == 4096 says "not run-length coded". The STORED body
*-- is only the bytes that belong to the file, but the LZW one
*-- codes the whole padded 4096: the decoder produces rle_len
*-- bytes from the codes and only then decides how many to
*-- write, so the padding has to be in there.
:norle      stz   CHKIND
            lda   WL
            sta   CHLEN
            lda   WL+1
            sta   CHLEN+1
            stz   CHRLEN
            lda   #$10
            sta   CHRLEN+1
            lda   #<LZ_CHUNK
            sta   CHBUF
            sta   LZE_IP
            lda   #>LZ_CHUNK
            sta   CHBUF+1
            sta   LZE_IP+1
            lda   #<LZ_OUT
            sta   LZE_OP
            lda   #>LZ_OUT
            sta   LZE_OP+1
:sized      lda   CHRLEN
            sta   LZE_ILEFT
            lda   CHRLEN+1
            sta   LZE_ILEFT+1
*-- WHEN LZW PAYS. An LZW chunk spends four header bytes to the
*-- other forms' two, so it must beat them by more than its
*-- codes: lzwlen + 2 < fallback. NufxLib compares lzwlen <
*-- fallback and therefore picks LZW for chunks it makes one or
*-- two bytes BIGGER (learning:01M0M67H5Y79780K1KY69W8PTN names
*-- the same off-by-two). Coding past that size is wasted work,
*-- so it is also the abandon threshold.
            sec
            lda   CHLEN
            sbc   #2
            sta   LZE_OMAX
            lda   CHLEN+1
            sbc   #0
            sta   LZE_OMAX+1
            bcc   :nolzw             ;a body under two bytes
            lda   LZE_OMAX
            ora   LZE_OMAX+1
            beq   :nolzw
            jsr   LZECHUNK
            bcs   :nolzw             ;abandoned: it had lost
            lda   #2
            sta   CHKIND
            lda   LZE_OLEN
            sta   CHLEN
            lda   LZE_OLEN+1
            sta   CHLEN+1
            lda   LZE_OP             ;the codes ended where the
            sec                      ;output cursor did
            sbc   LZE_OLEN
            sta   CHBUF
            lda   LZE_OP+1
            sbc   LZE_OLEN+1
            sta   CHBUF+1
            rts
*-- A CHUNK THAT IS NOT LZW CODED EMPTIES THE TABLE, on this
*-- side exactly as on the reader's. It is not a correctness
*-- subtlety but a memory economy of Andy Nicholas's: clearing
*-- on failure is what saves GS/ShrinkIt from snapshotting the
*-- table at every chunk boundary
*-- (learning:01M31QSJ9K6V389DEVKMW9CBTK). Whatever the
*-- abandoned attempt wrote into the table goes with it.
:nolzw      jmp   LZECLRT

*---------------------------------------------------------------
* PACK1 -- THE ONLY PASS. Read the input once; for each chunk
* fold its real bytes into the thread CRC, choose the chunk's
* form, and write it.
*
* WHY THERE USED TO BE TWO. `comp_thread_eof` and the plaintext
* `thread_crc` both live in a record header that PRECEDES the
* payload, and `header_crc` covers them, so neither can be
* patched into a header already written. The first version
* therefore read and CODED every file twice -- once to price it,
* once to write it -- which measured at ~60 seconds of real //e
* time for 28 KB against ShrinkIt's ~14.
*
* WHAT SHRINKIT DOES INSTEAD, and this now does: write the
* header with the fields it cannot know yet, write the payload,
* then SEEK BACK and lay the real header over it. Andy Nicholas
* describes the same trick in Hacking Data Compression lesson 9
* -- "it can seek back and patch the length in before writing"
* -- and it is why ShrinkIt never needed a pricing pass either.
* ADDONE owns the seeking; this routine just packs and counts.
*
* OUT: CSIZE = comp_thread_eof, DCRC = the v3 thread_crc.
*      carry set = a read or a write failed.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- STDIN NEEDS NO INOPEN -- INFD is already fd 0, set by
*-- ADDONE's own :dostdin branch (docs/NUFX-PIPE-NOTES.md), and
*-- there is no path to open. INCLOSE is skipped for the same
*-- reason at both exits below: fd 0 is the process's own stdin,
*-- not a handle this routine allocated, and closing it here
*-- would be closing what ADDONE never opened.
PACK1       lda   STDINFLAG
            bne   :opened
            jsr   INOPEN
            bcc   :opened
            jmp   :bad
:opened     jsr   LZEINIT
            lda   #$FF               ;v3 thread_crc: seed $FFFF
            sta   DCRC
            sta   DCRC+1
            lda   #2                 ;the stream header is the
            sta   CSIZE              ;first thing it spends
            stz   CSIZE+1
            stz   CSIZE+2
*-- THE ESCAPE BYTE IS STILL SET ONCE, in ADDARC. It is read
*-- here and inside RLECHUNK, and when those two disagreed the
*-- archive was off by one run per chunk.
*-- disk_volume: $00 for a file thread, unchanged and already
*-- verified byte-identical against real ShrinkIt 3.4; $FE for a
*-- disk thread, matching a2til's LZW_DEFAULT_VOLUME and
*-- NufxLib's kNuLZWDefaultVol (Lzw.c) -- both write $FE for
*-- EVERY LZW/2 stream, unconditionally (docs/NUFX.md slice 8).
            lda   ISDISK
            beq   :filevol
            lda   #LZ_DSKVOL
            bra   :setvol
:filevol    lda   #0
:setvol     sta   LZ_HDR
            lda   LZ_ESC
            sta   LZ_HDR+1
            lda   #<LZ_HDR
            ldx   #>LZ_HDR
            ldy   #2
            jsr   WRBLK
            bcs   :werr
            ldx   #0
:rmlp       lda   DLEN,x
            sta   REMAIN,x
            inx
            cpx   #3
            bne   :rmlp
:lp         jsr   RDCHUNK
            bcs   :eof
*-- The thread CRC covers the REAL bytes and never the padding;
*-- the chunk coder sees all 4096.
            lda   DCRC
            sta   CRCVAL
            lda   DCRC+1
            sta   CRCVAL+1
            lda   #<LZ_CHUNK
            sta   CRCPTR
            lda   #>LZ_CHUNK
            sta   CRCPTR+1
            lda   WL
            sta   CRCLEN
            lda   WL+1
            sta   CRCLEN+1
            jsr   CRCBYTES
            lda   CRCVAL
            sta   DCRC
            lda   CRCVAL+1
            sta   DCRC+1
            jsr   CHUNKPREP
            jsr   WRCHUNK
            bcs   :werr
            bra   :lp
:eof        lda   STDINFLAG
            bne   :nocl1
            jsr   INCLOSE
:nocl1      clc
            rts
:werr       lda   STDINFLAG
            bne   :bad
            jsr   INCLOSE
:bad        sec
            rts

*---------------------------------------------------------------
* WRCHUNK -- write the chunk CHUNKPREP just decided, and add
* what it cost to CSIZE.
* OUT: carry set = the write failed. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- The header word is rle_len with bit 15 as the LZW flag. The
*-- stored form says 4096, which is the same word as "coded to
*-- exactly 4096 bytes" -- a length no coding is allowed to
*-- produce, which is what frees the value to mean "not coded".
WRCHUNK     lda   CHRLEN
            sta   LZ_CHDR
            lda   CHRLEN+1
            ldx   CHKIND
            cpx   #2
            bne   :nolzwb
            ora   #$80
:nolzwb     sta   LZ_CHDR+1
            lda   #<LZ_CHDR
            ldx   #>LZ_CHDR
            ldy   #2
            jsr   WRBLK
            bcs   :bad
            lda   #2
            ldx   #0
            jsr   CSADD
*-- AND LZW DECLARES ITS OWN LENGTH, COUNTING THE FIELD AND THE
*-- word before it -- hence +4 over the codes. It is there for
*-- recovery, not for decoding: a reader that has drifted by one
*-- byte is caught at this chunk instead of at the next header.
            lda   CHKIND
            cmp   #2
            bne   :body
            clc
            lda   CHLEN
            adc   #4
            sta   LZ_XLEN
            lda   CHLEN+1
            adc   #0
            sta   LZ_XLEN+1
            lda   #<LZ_XLEN
            ldx   #>LZ_XLEN
            ldy   #2
            jsr   WRBLK
            bcs   :bad
            lda   #2
            ldx   #0
            jsr   CSADD
*-- The body goes out through SC_WRITE rather than WRBLK: it can
*-- be 4096 bytes and WRBLK takes its length in Y.
:body       lda   CHBUF
            sta   WPARM_BUF
            lda   CHBUF+1
            sta   WPARM_BUF+1
            lda   CHLEN
            sta   WPARM_REQ
            lda   CHLEN+1
            sta   WPARM_REQ+1
            lda   ADDFD
            sta   WPARM_REF
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            bcs   :bad
            clc
            lda   ARCEOF
            adc   WPARM_REQ
            sta   ARCEOF
            lda   ARCEOF+1
            adc   WPARM_REQ+1
            sta   ARCEOF+1
            lda   ARCEOF+2
            adc   #0
            sta   ARCEOF+2
            lda   CHLEN
            ldx   CHLEN+1
            jmp   CSADD
:bad        sec
            rts

*---------------------------------------------------------------
* CSADD -- CSIZE += A/X, widened to the 24 bits a thread length
* is allowed. CLOBBERS: A.
*---------------------------------------------------------------
CSADD       clc
            adc   CSIZE
            sta   CSIZE
            txa
            adc   CSIZE+1
            sta   CSIZE+1
            lda   CSIZE+2
            adc   #0
            sta   CSIZE+2
            clc
            rts

*---------------------------------------------------------------
* DLADD -- DLEN += A/X, the same shape as CSADD, above, but for
* the PLAINTEXT running total a `-` (stdin) operand accumulates
* as RDCHUNKPIPE reads it -- a real file already has DLEN from
* GETDLEN's own LSEEK(END) before PACK1 ever runs; a pipe has no
* such answer, so DLEN grows one chunk at a time instead.
* CLOBBERS: A.
*---------------------------------------------------------------
DLADD       clc
            adc   DLEN
            sta   DLEN
            txa
            adc   DLEN+1
            sta   DLEN+1
            lda   DLEN+2
            adc   #0
            sta   DLEN+2
            clc
            rts

*---------------------------------------------------------------
* GETDLEN -- DLEN := the input's length, with the file opened
* and closed again.
*
* It runs BEFORE the record header is written, and that ordering
* is the point: a file that cannot be opened has to be SKIPPED
* with a warning, and skipping is only possible while nothing
* has been committed to the archive. Once PACK1 starts, a
* failure is the archive's and stops the run.
* OUT: carry set = it could not be reached. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
GETDLEN     jsr   INOPEN
            bcs   :bad
            jsr   GETLEN
            bcs   :shut
            lda   ISDISK
            beq   :lenok
*-- A DISK INPUT MUST BE A WHOLE NUMBER OF 512-BYTE BLOCKS,
*-- decided here so nothing has been committed yet -- the same
*-- CANTADDM skip an unopenable file gets, for the same reason
*-- (docs/NUFX.md slice 8). A zero-length input also passes this
*-- arithmetic test (0 is a multiple of 512); left as a known,
*-- untriggered gap rather than spending the arena bytes a
*-- separate zero check costs on this tight a build.
            lda   DLEN
            bne   :shut
            lda   DLEN+1
            and   #1
            bne   :shut
:lenok      jmp   INCLOSE
:shut       jsr   INCLOSE
:bad        sec
            rts

*---------------------------------------------------------------
* WORTHIT -- COMPFLG := 1 if the coded thread came out smaller
* than the plain one. Unlike the version this replaces it is
* asked AFTER the payload is written, which is what the rewrite
* bought; ADDONE handles the rare loser by rewinding over what
* PACK1 wrote.
* CLOBBERS: A.
*---------------------------------------------------------------
WORTHIT     stz   COMPFLG
            lda   CSIZE+2
            cmp   DLEN+2
            bcc   :yes
            bne   :no
            lda   CSIZE+1
            cmp   DLEN+1
            bcc   :yes
            bne   :no
            lda   CSIZE
            cmp   DLEN
            bcs   :no
:yes        lda   #1
            sta   COMPFLG
:no         rts
