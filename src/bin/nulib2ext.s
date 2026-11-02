*---------------------------------------------------------------
* nulib2ext.s -- EXTRACTION: turning a parsed record into bytes,
* under whichever of the three fork verbs is running.
*
* `-x` writes a file, `-p` writes stdout, `-i` writes nothing
* and only checks. They are ONE path with its output redirected
* or discarded (XMODE, XPUT), never three expanders that could
* drift. The ProDOS type and aux stamp lives here too: on ProDOS
* the type is where "can this be run?" lives, so an extractor
* that drops it produces files that look right and cannot be
* used.
*---------------------------------------------------------------

*---------------------------------------------------------------
* EXTRACT -- one record's data fork. POS is at the first payload
* byte on entry and restored on exit, so the caller's record
* arithmetic is untouched. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
EXTRACT     lda   HAVEDATA
            bne   :havedat
            rts
:havedat    stz   LZ_T2
            lda   DATFMT+1
            bne   :notours
            lda   DATFMT
            beq   :ours              ;$0000 stored
            cmp   #2
            beq   :ours              ;$0002 LZW/1
            cmp   #3
            bne   :notours
            inc   LZ_T2              ;$0003 LZW/2
            bra   :ours
:notours    jmp   NOTSTORED
:ours       lda   DSIZE+3            ;a fork this reader cannot
            beq   :sizeok            ;address in a 3-byte mark
            jmp   :toobig
:sizeok     lda   XMODE
            beq   :tofile
            cmp   #1
            beq   :topipe
            lda   #FD_STDOUT         ;-i writes nothing, but
            sta   WPARM_REF          ;the field is kept sane
            bra   :haveout
:topipe     lda   #FD_STDOUT         ;-p: exactly -x with its
            sta   WPARM_REF          ;output redirected
            bra   :haveout
:tofile     jsr   LEAFNAME
            lda   #<OUTPATH
            sta   PTR1
            lda   #>OUTPATH
            sta   PTR1+1
            jsr   CREAT
            bcc   :created
            jmp   :nocreat
:created
            sta   OUTFD
            sta   WPARM_REF
            sta   XCPARM_REF
:haveout
            ldx   #0                 ;park POS across the copy
:svlp       lda   POS,x
            sta   XSAVE,x
            inx
            cpx   #3
            bne   :svlp
            clc
            lda   POS
            adc   DATOFF
            sta   POS
            lda   POS+1
            adc   DATOFF+1
            sta   POS+1
            lda   POS+2
            adc   DATOFF+2
            sta   POS+2
            jsr   SEEKPOS
            ldx   #0                 ;REMAIN = the USED length
:rmlp       lda   DSIZE,x
            sta   REMAIN,x
            inx
            cpx   #3
            bne   :rmlp
            lda   #$FF               ;v3 thread_crc seeds $FFFF
            sta   CRCVAL
            sta   CRCVAL+1
            stz   LZBAD              ;tested at :noclose
            lda   DATFMT             ;stored copies; LZW/1 goes
            beq   :plain             ;through the expander, and
            jsr   LZWFORK            ;a malformed stream is
            bcc   :copied            ;reported, not silent
            lda   #1
            sta   LZBAD
            bra   :copied
:plain      jsr   COPYFORK
:copied     lda   XMODE              ;only -x opened anything
            bne   :noclose
            lda   #<XCPARM
            ldx   #>XCPARM
            jsr   SC_CLOSE
:noclose
            lda   LZBAD              ;an LZW stream that did not
            beq   :sumok             ;verify has already been
            stz   LZBAD              ;judged; its thread CRC
            lda   #<BADSTRM
            ldx   #>BADSTRM          ;would only repeat it
            jsr   XWARN
            bra   :stamp
:sumok      jsr   CRCVERIFY
:stamp      lda   XMODE              ;a pipe and a check have no
            bne   :nostamp           ;directory entry to stamp
            jsr   STAMP
:nostamp
            ldx   #0
:rslp       lda   XSAVE,x
            sta   POS,x
            inx
            cpx   #3
            bne   :rslp
            jmp   SEEKPOS
:toobig     lda   #<TOOBIGM
            ldx   #>TOOBIGM
            jmp   XWARN
:nocreat    lda   #<NOCREATM
            ldx   #>NOCREATM
            jmp   XWARN

*---------------------------------------------------------------
* COPYFORK -- REMAIN bytes from the archive to OUTFD, folding
* each chunk into CRCVAL on the way past. A short read stops the
* copy: the file keeps what arrived, and the CRC test below is
* what reports it. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
COPYFORK    lda   REMAIN
            ora   REMAIN+1
            ora   REMAIN+2
            bne   :more
            rts
:more       lda   REMAIN+1           ;chunk = min(REMAIN,XBUFSZ)
            ora   REMAIN+2
            bne   :full
            lda   REMAIN
            cmp   #XBUFSZ
            bcs   :full
            sta   RDLEN
            stz   RDLEN+1
            bra   :doread
:full       lda   #XBUFSZ
            sta   RDLEN
            stz   RDLEN+1
:doread     lda   #<XBUF
            sta   RDPTR
            lda   #>XBUF
            sta   RDPTR+1
            jsr   RDBYTES
            bcs   :stop
            lda   #<XBUF
            sta   CRCPTR
            lda   #>XBUF
            sta   CRCPTR+1
            lda   RDLEN
            sta   CRCLEN
            stz   CRCLEN+1
            jsr   CRCBYTES
            lda   RDLEN
            sta   WPARM_REQ
            stz   WPARM_REQ+1
            lda   #<XBUF
            sta   WPARM_BUF
            lda   #>XBUF
            sta   WPARM_BUF+1
            jsr   XPUT
            bcs   :stop
            sec                      ;REMAIN -= chunk
            lda   REMAIN
            sbc   RDLEN
            sta   REMAIN
            lda   REMAIN+1
            sbc   #0
            sta   REMAIN+1
            lda   REMAIN+2
            sbc   #0
            sta   REMAIN+2
            jmp   COPYFORK
:stop       rts

*---------------------------------------------------------------
* XPUT -- the one write in this program, so that `-i` can be the
* same code path with its output thrown away rather than a
* second expander that could drift from the first.
*
* WRITE-ALL, not one shot -- discovered load-bearing by the pipe
* slice (docs/NUFX-PIPE-NOTES.md): `-p archive | dd ...` sends
* this write to a PIPE, and a pipe's own write CAN return fewer
* bytes than asked with carry CLEAR (its ring is 255 bytes, so a
* write finding the ring already partly full is legitimately
* SHORT -- `src/kernel/procmli3.s` `PRC_WRITE`'s `:ispipe`/
* `:space` arm). A single-shot write silently drops the
* untransferred tail every time the reader has not drained fast
* enough, which desyncs the whole stream from that point on --
* MEASURED: check-unpack's pipeout leg diverged at byte 255, one
* chunk boundary in. Same shape as `dd`'s own `DD_WRTALL`/cat's
* `WRITE_ALL`, not shared code (house convention: no liba
* routine for a two-caller shape).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
XPUT        lda   XMODE
            cmp   #2
            beq   :sink
:more       lda   WPARM_REQ
            ora   WPARM_REQ+1
            beq   :done
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            bcs   :bad
            lda   WPARM_TRANS
            ora   WPARM_TRANS+1
            beq   :bad
            sec
            lda   WPARM_REQ
            sbc   WPARM_TRANS
            sta   WPARM_REQ
            lda   WPARM_REQ+1
            sbc   WPARM_TRANS+1
            sta   WPARM_REQ+1
            clc
            lda   WPARM_BUF
            adc   WPARM_TRANS
            sta   WPARM_BUF
            lda   WPARM_BUF+1
            adc   WPARM_TRANS+1
            sta   WPARM_BUF+1
            bra   :more
:done
:sink       clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* CRCVERIFY -- compare the folded CRC with the thread's own, on
* a v3 record only. See this file's header for why v1 is exempt
* rather than tolerated. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
CRCVERIFY   lda   RECVER+1
            bne   :nocheck
            lda   RECVER
            cmp   #3
            bcc   :nocheck
            lda   CRCVAL
            cmp   DATCRC
            bne   :bad
            lda   CRCVAL+1
            cmp   DATCRC+1
            bne   :bad
:nocheck    rts
:bad        lda   #<BADTCRC
            ldx   #>BADTCRC
            jmp   XWARN

*---------------------------------------------------------------
* STAMP -- give the new file the record's own ProDOS type and
* aux. CREAT makes an unlocked TXT seedling, which is right for
* creat(2) and wrong for an extracted file: on ProDOS the TYPE
* is where "can this be run?" lives, and maux's spawn loads a
* binary AT ITS AUX. Read-modify-write, chmod.s's and chtyp.s's
* dance: SET_FILE_INFO writes a FULL block, so a caller that
* sends zeros for the fields it does not mean to change destroys
* them. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
STAMP       lda   #PCOUNT_GFI
            sta   XGPARM
            lda   #PCOUNT_SFI
            sta   XSPARM
            lda   #<OUTPATH
            sta   XGPARM_PATH
            sta   XSPARM_PATH
            lda   #>OUTPATH
            sta   XGPARM_PATH+1
            sta   XSPARM_PATH+1
            lda   #<XGPARM
            ldx   #>XGPARM
            jsr   SC_GFI
            bcs   :nostamp
*-- FIELD BY FIELD, because the two parameter blocks do NOT
*-- share a layout: GET_FILE_INFO returns storage_type and
*-- blocks_used where SET_FILE_INFO wants three null bytes. A
*-- block copy would write a block count into the reserved
*-- field. chtyp.s does exactly this dance and for the same
*-- reason.
            lda   XGPARM_ACC
            sta   XSPARM_ACC
            stz   XSPARM_NULL
            stz   XSPARM_NULL+1
            stz   XSPARM_NULL+2
            lda   XGPARM_MDATE
            sta   XSPARM_MDATE
            lda   XGPARM_MDATE+1
            sta   XSPARM_MDATE+1
            lda   XGPARM_MTIME
            sta   XSPARM_MTIME
            lda   XGPARM_MTIME+1
            sta   XSPARM_MTIME+1
*-- ... and only then the two fields this tool is here to set.
            lda   FTYPE
            sta   XSPARM_FTYP
            lda   FAUX
            sta   XSPARM_AUX
            lda   FAUX+1
            sta   XSPARM_AUX+1
            lda   #<XSPARM
            ldx   #>XSPARM
            jsr   SC_SFI
            bcs   :nostamp
            rts
:nostamp    lda   #<NOSTAMPM
            ldx   #>NOSTAMPM
            jmp   XWARN

*---------------------------------------------------------------
* LEAFNAME -- OUTPATH := the last component of NAMEBUF, as an
* MLI count-prefixed pathname. The separator is SEPCH, the low
* byte of the record's file_sys_info. A name with no separator
* is its own leaf. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
LEAFNAME    ldx   #0                 ;X = start of the last run
            ldy   #0
:scan       lda   NAMEBUF,y
            beq   :scanned
            cmp   SEPCH
            bne   :next
            iny                      ;the byte AFTER the
            tya                      ;separator starts a run
            tax
            bra   :scan
:next       iny
            bne   :scan
:scanned    ldy   #0
:cpy        lda   NAMEBUF,x
            beq   :cpydone
            iny
            sta   OUTPATH,y
            inx
            cpy   #MLI_PTH_MAXLN
            bne   :cpy
:cpydone    sty   OUTPATH            ;the MLI count byte
            rts

*---------------------------------------------------------------
* NOTSTORED / XWARN -- "nulib2: NAME: <what>", status 1, and
* the walk continues. A record this reader cannot expand is not
* a reason to abandon the ones it can.
*---------------------------------------------------------------
NOTSTORED   lda   #<COMPRM
            ldx   #>COMPRM
XWARN       sta   XMSGL
            stx   XMSGH
            lda   #<XPFX
            sta   PTR0
            lda   #>XPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<NAMEBUF
            sta   PTR0
            lda   #>NAMEBUF
            sta   PTR0+1
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
