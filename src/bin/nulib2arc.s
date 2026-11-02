*---------------------------------------------------------------
* nulib2arc.s -- the ARCHIVE: parsing NuFX structure and nothing
* else. The master header (and the Binary II wrapper a .BXY
* hides it behind), the record walk, one record's header and the
* tail attrib_count delimits, and the thread array. Both header
* CRCs are checked here, because both cover bytes this file
* reads.
*
* What it does NOT do: decide how a record is DISPLAYED
* (nulib2lst.s), turn one into a file (nulib2ext.s), or expand a
* compressed thread (nulib2lzw.s). It hands those a parsed
* record.
*---------------------------------------------------------------

*---------------------------------------------------------------
* LISTARC -- the whole walk. Master header, then one pass per
* record. CLOBBERS: everything.
*---------------------------------------------------------------
LISTARC     stz   POS
            stz   POS+1
            stz   POS+2
            lda   #<MHDR
            sta   RDPTR
            lda   #>MHDR
            sta   RDPTR+1
            lda   #48
            sta   RDLEN
            stz   RDLEN+1
*-- A FILE TOO SMALL TO HOLD A MASTER HEADER WAS NEVER AN
*-- ARCHIVE, so it is not "truncated" either. "Ends early" is
*-- for a file whose header parses and whose RECORDS then run
*-- out -- a real archive that was cut short, which is a
*-- different thing to tell somebody.
            jsr   RDBYTES
            bcc   :got1
            jmp   :notnufx
:got1
*-- The master ID is "NuFile" with alternating high bits set:
*-- 4E F5 46 E9 6C E5.
            jsr   :ckid
            bcc   :isnufx
*-- A .BXY is one 128-byte Binary II header in front of the NuFX
*-- data, so a master header not at offset 0 may still be
*-- at 128. nulib2 has a `-b` to FORCE this, which matters to it
*-- because it can read an archive from stdin and cannot seek
*-- back; this reader always has a file and can simply look, so
*-- the flag would be a switch with nothing to switch.
            lda   #128
            sta   B2OFF
            sta   POS
            stz   POS+1
            stz   POS+2
            jsr   SEEKPOS
            lda   #<MHDR
            sta   RDPTR
            lda   #>MHDR
            sta   RDPTR+1
            lda   #48
            sta   RDLEN
            stz   RDLEN+1
*-- A FILE TOO SHORT FOR THE RETRY IS NOT AN ARCHIVE, and saying
*-- "ends early" would be a wrong diagnosis: nothing has
*-- been truncated; it was never a NuFX file. See the note on
*-- the first read above.
            jsr   RDBYTES
            bcs   :notnufx
            jsr   :ckid
            bcs   :notnufx
:isnufx
            stz   CRCVAL             ;master_crc seeds $0000
            stz   CRCVAL+1
            lda   #<MHDRCRC
            sta   CRCPTR
            lda   #>MHDRCRC
            sta   CRCPTR+1
            lda   #40                ;bytes [8:48]
            sta   CRCLEN
            stz   CRCLEN+1
            jsr   CRCBYTES
            lda   CRCVAL
            cmp   MHDR+6
            bne   :badmcrc
            lda   CRCVAL+1
            cmp   MHDR+7
            bne   :badmcrc
:crcok      lda   MHDRCRC             ;total_records, low 16
            sta   NRECS
            lda   MHDR+9
            sta   NRECS+1
            lda   MHDR+10
            ora   MHDR+11
            bne   :toomany
:reclp      lda   NRECS
            ora   NRECS+1
            beq   :done
            jsr   ONEREC
            bcs   :done              ;a short read ends the walk
            lda   NRECS
            bne   :nodec
            dec   NRECS+1
:nodec      dec   NRECS
            bra   :reclp
:done       rts
:ckid       ldx   #0
:ckilp      lda   MHDR,x
            cmp   MASTERID,x
            bne   :ckbad
            inx
            cpx   #6
            bne   :ckilp
            clc
            rts
:ckbad      sec
            rts
*-- EACH SITE CARRIES THE WHOLE POINTER. The previous version
*-- passed only the low byte and took the high byte from
*-- TRUNCMSG, on the assumption that the three messages shared a
*-- page -- with a comment saying a gate enforced it. No such
*-- gate was ever written, and renaming the program from `nulib`
*-- to `nulib2` added one character to each message and pushed
*-- two of the three onto the next page: `nulib2 -t` on a file
*-- that is not an archive printed two bytes of garbage instead
*-- of "not a NuFX archive". Four extra bytes per site removes
*-- the class, and check-nulib2 now exercises the path.
:short      lda   #<TRUNCMSG
            ldx   #>TRUNCMSG
            bra   :fail
:notnufx    lda   #<NOTNUFX
            ldx   #>NOTNUFX
            bra   :fail
:toomany    lda   #<TOOMANY
            ldx   #>TOOMANY
            bra   :fail
:badmcrc    lda   #<BADMCRC
            sta   PTR0
            lda   #>BADMCRC
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            sta   ERRFLAG
            bra   :crcok             ;report, then keep walking
:fail       sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            sta   ERRFLAG
            rts

*---------------------------------------------------------------
* ONEREC -- parse one record at POS and print its row. POS is
* left at the start of the NEXT record. OUT: carry set = the
* archive ended early, stop walking. CLOBBERS: everything.
*---------------------------------------------------------------
ONEREC      stz   HAVEFN
            stz   HAVEDATA
            stz   ISDSKREC
            stz   PAYSUM
            stz   PAYSUM+1
            stz   PAYSUM+2
            lda   #<RECHDR
            sta   RDPTR
            lda   #>RECHDR
            sta   RDPTR+1
            lda   #58                ;the fixed part
            sta   RDLEN
            stz   RDLEN+1
            jsr   RDBYTES
            bcc   :ok1
            jmp   :eof
:ok1
            ldx   #0
:idlp       lda   RECHDR,x
            cmp   RECORDID,x
            beq   :idnext
            jmp   :notrec
:idnext     inx
            cpx   #4
            bne   :idlp
*-- header_crc covers [+6 .. end of the thread array], seed
*-- $0000. Start it here and keep feeding it every byte of the
*-- tail, the in-header name and every thread record.
            stz   CRCVAL
            stz   CRCVAL+1
            lda   #<RECHDRCRC
            sta   CRCPTR
            lda   #>RECHDRCRC
            sta   CRCPTR+1
            lda   #52                ;bytes +6..+57
            sta   CRCLEN
            stz   CRCLEN+1
            jsr   CRCBYTES
            lda   RECHDR+22          ;file_type, low byte
            sta   FTYPE
            lda   RECHDR+26          ;extra_type = a file's aux
            sta   FAUX
            lda   RECHDR+27
            sta   FAUX+1
            lda   RECHDR+8           ;the RECORD version, which
            sta   RECVER             ;decides whether a thread
            lda   RECHDR+9           ;CRC means anything
            sta   RECVER+1
*-- file_sys_info's LOW byte is the pathname separator. NEVER
*-- file_sys_id, which nulib2 writes as 0 while separating with
*-- ':' (learning:01M0KZQJTHDP01FKPNP1HTWDW7).
            lda   RECHDR+16
            sta   SEPCH
            lda   RECHDR+10          ;total_threads, low 16
            sta   NTHR
            lda   RECHDR+11
            sta   NTHR+1
*-- attrib_count decides where the header ends. Read the tail in
*-- chunks and keep the LAST TWO BYTES: those are
*-- filename_length whatever attrib_count is, which is why no
*-- GS/OS option list and no v0 record needs a special case.
            sec
            lda   RECHDRCRC
            sbc   #58
            sta   TAILLEN
            lda   RECHDR+7
            sbc   #0
            sta   TAILLEN+1
            bcs   :attrok
            jmp   :badattr           ;attrib_count < 58
:attrok
            lda   RECHDR+56          ;the == 58 case: the last
            sta   FNLEN              ;two bytes are already read
            lda   RECHDR+57
            sta   FNLEN+1
            lda   TAILLEN
            ora   TAILLEN+1
            beq   :havefnl
:taillp     lda   TAILLEN+1
            bne   :bigchunk
            lda   TAILLEN
            cmp   #65
            bcc   :lastchunk
:bigchunk   lda   #64
            sta   RDLEN
            stz   RDLEN+1
            bra   :tailrd
:lastchunk  sta   RDLEN
            stz   RDLEN+1
:tailrd     lda   #<SCRATCH
            sta   RDPTR
            lda   #>SCRATCH
            sta   RDPTR+1
            jsr   RDBYTES
            bcc   :ok2
            jmp   :eof
:ok2
            lda   #<SCRATCH
            sta   CRCPTR
            lda   #>SCRATCH
            sta   CRCPTR+1
            lda   RDLEN
            sta   CRCLEN
            stz   CRCLEN+1
            jsr   CRCBYTES
            ldx   RDLEN              ;remember this chunk's last
            dex                      ;two bytes
            lda   SCRATCH,x
            sta   FNLEN+1
            dex
            lda   SCRATCH,x
            sta   FNLEN
            sec
            lda   TAILLEN
            sbc   RDLEN
            sta   TAILLEN
            lda   TAILLEN+1
            sbc   #0
            sta   TAILLEN+1
            lda   TAILLEN
            ora   TAILLEN+1
            bne   :taillp
:havefnl    jsr   RDNAMEHDR
            bcc   :ok3
            jmp   :eof
:ok3
            jsr   RDTHREADS
            bcc   :ok4
            jmp   :eof
:ok4
*-- Now the thread array has been CRC'd, so the header CRC is
*-- complete and comparable.
            lda   CRCVAL
            cmp   RECHDR+4
            bne   :badhcrc
            lda   CRCVAL+1
            cmp   RECHDR+5
            beq   :hcrcok
:badhcrc    lda   #1
            sta   ERRFLAG
            lda   #1
            sta   CRCBAD
            bra   :afterh
:hcrcok     stz   CRCBAD
:afterh     jsr   RDFNTHRD           ;name, if it is a thread
            lda   TFLAG
            beq   :notlist
            jsr   PRNAME
            bra   :advance
:notlist    lda   VFLAG
            beq   :extract
            jsr   PRROW
            bra   :advance
*-- WANTNAME (docs/NUFX-PIPE-NOTES.md): `-x`/`-p`/`-i` took an
*-- optional second operand, a NAME filter. HAVEFN clear means
*-- this record has no name at all -- NAMEBUF may be stale from
*-- the PREVIOUS record, so that case is a forced non-match
*-- rather than trusting a comparison against it.
:extract    lda   WANTNAME
            beq   :doext
            lda   HAVEFN
            beq   :advance
            jsr   NAMEMATCH
            bcs   :advance
:doext      jsr   EXTRACT
:advance
*-- Next record = the first payload byte + every comp_thread_eof
*-- in this record. POS is already at the first payload byte.
            clc
            lda   POS
            adc   PAYSUM
            sta   POS
            lda   POS+1
            adc   PAYSUM+1
            sta   POS+1
            lda   POS+2
            adc   PAYSUM+2
            sta   POS+2
            jsr   SEEKPOS
            clc
            rts
:eof        sec
            rts
:notrec     lda   #<NOTREC
            sta   PTR0
            lda   #>NOTREC
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            sta   ERRFLAG
            sec
            rts
:badattr    lda   #<BADATTR
            sta   PTR0
            lda   #>BADATTR
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            sta   ERRFLAG
            sec
            rts

*---------------------------------------------------------------
* RDNAMEHDR -- read the in-header filename, if this record has
* one (filename_length > 0), CRC it, and keep it. Most writers
* put the name in a thread instead and leave this zero.
* OUT: carry set = short read. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
RDNAMEHDR   lda   FNLEN
            ora   FNLEN+1
            bne   :have
            clc
            rts
:have       lda   FNLEN+1            ;a name longer than the
            bne   :toolong           ;buffer is truncated, not a
            lda   FNLEN              ;reason to abandon the row
            cmp   #NAMEMAX
            bcc   :fits
:toolong    lda   #NAMEMAX
:fits       sta   NAMELEN
            lda   #<SCRATCH
            sta   RDPTR
            lda   #>SCRATCH
            sta   RDPTR+1
            lda   FNLEN
            sta   RDLEN
            lda   FNLEN+1
            sta   RDLEN+1
            jsr   RDBYTES
            bcc   :nx1
            jmp   :eof
:nx1
            lda   #<SCRATCH
            sta   CRCPTR
            lda   #>SCRATCH
            sta   CRCPTR+1
            lda   FNLEN
            sta   CRCLEN
            lda   FNLEN+1
            sta   CRCLEN+1
            jsr   CRCBYTES
            ldy   #0
*-- AND #$7F: an old P8 ShrinkIt in-header name may carry the
*-- ordinary Apple II high-bit-ASCII display convention (every
*-- byte's bit 7 set) -- real ShrinkIt-family readers strip it,
*-- and a high-bit byte is not a legal ProDOS pathname character
*-- (CREATE would refuse it). Idempotent on a name that is
*-- already 7-bit clean. docs/UNPACK-E2E-NOTES.md, 2026-09-29.
:cpy        cpy   NAMELEN
            beq   :cpyend
            lda   SCRATCH,y
            and   #$7F
            sta   NAMEBUF,y          ;hands ls its names
            iny
            bra   :cpy
:cpyend     lda   #0
            sta   NAMEBUF,y
            lda   #1
            sta   HAVEFN
            clc
            rts
:eof        sec
            rts

*---------------------------------------------------------------
* RDTHREADS -- read all NTHR thread records, CRC each, and learn
* three things: the running sum of comp_thread_eof (where the
* next record is), the data fork's thread_eof (the size column),
* and where the filename thread's payload sits.
*
* A thread's payload offset is the first payload byte plus every
* comp_thread_eof BEFORE it -- which is why the sum is taken
* before the class test, not after.
* OUT: carry set = short read. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
RDTHREADS   lda   NTHR
            ora   NTHR+1
            bne   :go
            clc
            rts
:go         lda   #<THR
            sta   RDPTR
            lda   #>THR
            sta   RDPTR+1
            lda   #16
            sta   RDLEN
            stz   RDLEN+1
            jsr   RDBYTES
            bcc   :nx2
            jmp   :eof
:nx2
            lda   #<THR
            sta   CRCPTR
            lda   #>THR
            sta   CRCPTR+1
            lda   #16
            sta   CRCLEN
            stz   CRCLEN+1
            jsr   CRCBYTES
*-- CLASS_FILENAME (3) kind 0: remember where its payload is,
*-- which is the running sum SO FAR, and how long it really is
*-- (thread_eof, not comp_thread_eof -- trap 1).
            lda   THR+2              ;thread_format
            ora   THR+3
            bne   :notfn             ;a compressed name: skip it
            lda   THR                ;thread_class
            cmp   #3
            bne   :notfn
            lda   THR+1
            bne   :notfn
            lda   THR+4              ;thread_kind
            ora   THR+5
            bne   :notfn
            lda   PAYSUM
            sta   FNOFF
            lda   PAYSUM+1
            sta   FNOFF+1
            lda   PAYSUM+2
            sta   FNOFF+2
            lda   THR+8
            sta   FNTLEN
            lda   THR+9
            sta   FNTLEN+1
            lda   #2
            sta   HAVEFN             ;2 = it is a thread
*-- CLASS_DATA (2), kind 0 (data fork) or kind 1 (disk image) --
*-- both are shown; anything else (e.g. 2, resource) is not.
:notfn      lda   THR
            cmp   #2
            bne   :notdat
            lda   THR+1
            bne   :notdat
            lda   THR+5               ;kind high byte must be 0
            bne   :notdat
            lda   THR+4               ;kind low byte
            beq   :isdat
            cmp   #1
            bne   :notdat
            inc   ISDSKREC
:isdat      ldx   #0
:dcpy       lda   THR+8,x
            sta   DSIZE,x
            inx
            cpx   #4
            bne   :dcpy
*-- A disk thread's own thread_eof is UNRELIABLE in the wild --
*-- measured truncated (DEMOPROG.SDK) and zero (XMASADV.SDK),
*-- docs/UNPACK-E2E-NOTES.md 2026-09-29. The true byte count is
*-- FAUX (extra_type, the block count) * 512, the one block size
*-- every real disk archive here uses; storage_type is no more
*-- trustworthy, so this does not read it (a2til's own reader
*-- ladder falls back to 512 the same way). FAUX<<9 done as an
*-- 8-bit byte move plus one more shift, not a general multiply.
            lda   ISDSKREC
            beq   :notdsk2
            lda   FAUX
            sta   DSIZE+1
            lda   FAUX+1
            sta   DSIZE+2
            stz   DSIZE
            stz   DSIZE+3
            asl   DSIZE
            rol   DSIZE+1
            rol   DSIZE+2
            rol   DSIZE+3
:notdsk2
*-- Where this thread's payload sits, which is the running sum
*-- of comp_thread_eof BEFORE it -- so it is taken here, above
*-- the addition below, not after. Its FORMAT decides whether
*-- -x can write it, and its own CRC is what -x checks the
*-- bytes against on a v3 record.
            lda   PAYSUM
            sta   DATOFF
            lda   PAYSUM+1
            sta   DATOFF+1
            lda   PAYSUM+2
            sta   DATOFF+2
            lda   THR+2
            sta   DATFMT
            lda   THR+3
            sta   DATFMT+1
            lda   THR+6
            sta   DATCRC
            lda   THR+7
            sta   DATCRC+1
            lda   #1
            sta   HAVEDATA
:notdat     clc                      ;PAYSUM += comp_thread_eof
            lda   PAYSUM
            adc   THR+12
            sta   PAYSUM
            lda   PAYSUM+1
            adc   THR+13
            sta   PAYSUM+1
            lda   PAYSUM+2
            adc   THR+14
            sta   PAYSUM+2
            lda   NTHR
            bne   :nodec
            dec   NTHR+1
:nodec      dec   NTHR
            lda   NTHR
            ora   NTHR+1
            beq   :allthrd
            jmp   :go
:allthrd    clc
            rts
:eof        sec
            rts

*---------------------------------------------------------------
* RDFNTHRD -- if the name lives in a thread, seek to its payload
* and read it, then seek back. POS is at the first payload byte
* on entry and on exit, so the caller's sums are unaffected.
* CLOBBERS: A, X, Y (and the file mark, restored).
*---------------------------------------------------------------
RDFNTHRD    lda   HAVEFN
            cmp   #2
            beq   :go
            rts
:go         ldx   #0                 ;save POS across the detour
:svlp       lda   POS,x
            sta   SAVEPOS,x
            inx
            cpx   #3
            bne   :svlp
            clc
            lda   POS
            adc   FNOFF
            sta   POS
            lda   POS+1
            adc   FNOFF+1
            sta   POS+1
            lda   POS+2
            adc   FNOFF+2
            sta   POS+2
            jsr   SEEKPOS
            lda   FNTLEN+1
            bne   :toolong
            lda   FNTLEN
            cmp   #NAMEMAX
            bcc   :fits
:toolong    lda   #NAMEMAX
:fits       sta   NAMELEN
            sta   RDLEN
            stz   RDLEN+1
            lda   #<SCRATCH
            sta   RDPTR
            lda   #>SCRATCH
            sta   RDPTR+1
            jsr   RDBYTES
            bcs   :back
            ldy   #0
*-- AND #$7F: the same high-bit strip as RDNAMEHDR's copy loop
*-- above, for a name that arrived in a filename THREAD instead.
:cpy        cpy   NAMELEN
            beq   :cpyend
            lda   SCRATCH,y
            and   #$7F
            sta   NAMEBUF,y
            iny
            bra   :cpy
:cpyend     lda   #0
            sta   NAMEBUF,y
:back       ldx   #0
:rslp       lda   SAVEPOS,x
            sta   POS,x
            inx
            cpx   #3
            bne   :rslp
            jmp   SEEKPOS

*---------------------------------------------------------------
* NAMEMATCH -- does NAMEBUF (already 7-bit clean) equal the
* NAME operand's own string (argv's high-bit encoding, masked
* here)? OPTIND never moves again once parsing finished, so the
* operand is re-fetched here with GETARG(OPTIND+1) rather than a
* pointer nulib2.s's own parse cached -- one arena cell fewer.
* Both strings are NUL-terminated. OUT: carry clear = match.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
NAMEMATCH   lda   OPTIND
            clc
            adc   #1
            jsr   GETARG
            ldy   #0
:cmp        lda   (PTR0),y
            and   #$7F
            cmp   NAMEBUF,y
            bne   :no
            lda   NAMEBUF,y
            beq   :yes
            iny
            bra   :cmp
:yes        clc
            rts
:no         sec
            rts
