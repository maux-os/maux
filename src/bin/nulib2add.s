*---------------------------------------------------------------
* nulib2add.s -- CREATING an archive: `nulib2 -a archive
* file...`.
*
* Stored threads only ($0000). That is not a stub: every NuFX
* reader accepts stored, it is what `nulib2 -a -0` writes, and
* it is the half of "add" that makes the machine able to hand
* work BACK to a host. Compressing on the way out is a separate
* piece of work (docs/NUFX.md).
*
* CREATE, NOT ADD-TO. nulib2's own -a will add to an existing
* archive; this one always writes a fresh archive over whatever
* the name held. Adding means REBUILDING -- threads are
* compressed and variable-length, so there is no unit to write
* through, and every untouched record has to be re-emitted from
* its own bytes. That is real plumbing and it is not here yet.
* nulib2(1) says so rather than letting someone discover it.
*
* TWO PASSES OVER EVERY INPUT, and the format forces it. A v3
* record's data thread carries a CRC of the PLAINTEXT, and that
* CRC sits inside the record header, which is itself covered by
* header_crc. So the CRC cannot be patched in afterwards -- the
* header would have to be recomputed and rewritten, and the
* payload already follows it. Pass 1 reads the file to checksum
* it, pass 2 reads it again to copy it. The alternative is
* holding the whole file in memory, which a 46 KB bank cannot
* promise.
*
* The MASTER header is the one thing patched at the end: its
* record count and its own eof are not known until the last
* record is written, and nothing follows it that its CRC covers.
*---------------------------------------------------------------

*---------------------------------------------------------------
* ADDARC -- the whole verb. Creates the archive, appends one
* record per file operand, then patches the master header.
* CLOBBERS: everything.
*---------------------------------------------------------------
ADDARC      jsr   CHKSDK
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   CREAT
            bcc   :made
            jmp   :nocreat
:made       sta   ADDFD
            sta   ARCFD              ;SEEKPOS seeks THE ARCHIVE,
            sta   WPARM_REF          ;and for -a this is it --
            sta   CPARM_REF          ;MHPATCH seeks back to 0
*-- ARCEOF MUST START AT ZERO, EXPLICITLY -- it was never
*-- initialized anywhere in this file and relied entirely on the
*-- kernel zeroing a fresh process's bss at spawn time. That is
*-- true for a COLD spawn but NOT for a WARM RESPAWN (the same
*-- bank reused for a second `-a` invocation within one session,
*-- with nothing reloaded) -- docs/NUFX-PIPE-NOTES.md's "the
*-- pipein bug" section: the SECOND `nulib2 -a` in one session
*-- (proven, not guessed, by a diagnostic build: check-floppy's
*-- own file-route `-a` runs first and left ARCEOF holding its
*-- OWN archive's final length) inherited that value, and every
*-- position this run computed -- RECPOS included -- was offset
*-- by it, so the seek-back before the real record header
*-- landed past the true archive end (ProDOS SET_MARK error
*-- $4D, "position out of range") and the header write fell
*-- through to wherever the file mark already was. Nothing
*-- about this is pipe-specific; it is the first gate case to
*-- run `nulib2 -a` twice in one continuous session, file route
*-- included. NRECW/DCRC/DLEN share this one loop with ARCEOF --
*-- all four are contiguous in the arena and all four want zero
*-- here (DCRC/DLEN are reset again per-record; zeroing them
*-- this once too is free and one byte cheaper than the
*-- original two-instruction NRECW clear plus a separate one
*-- for ARCEOF).
            ldx   #9
:zae        stz   NRECW,x
            dex
            bpl   :zae
*-- THE ESCAPE BYTE IS SET ONCE, HERE, and it is read by both
*-- RLECHUNK and the chunk pricing inside CHUNKPREP. When there
*-- were two passes they each set it and one of them forgot:
*-- comp_thread_eof became a lie and NufxLib reported "RLE input
*-- glitch (off by -254)". There is one pass now, so the two
*-- cannot disagree -- but one place to set it is still right,
*-- and the incident is why the line is here and not there.
            lda   #$DB               ;the customary escape
            sta   LZ_ESC
            jsr   MHBLANK          ;48 bytes of placeholder, so
            bcs   :werr              ;record one lands at 48
            lda   OPTIND             ;the operands after the
            sta   FIDX               ;archive name
:filelp     inc   FIDX
            lda   FIDX
            cmp   ARGC
            bcs   :alldone
            jsr   ADDONE
            bra   :filelp
:alldone    jsr   TRUNCARC
            bcs   :werr
            jsr   MHPATCH
            bcs   :werr
            lda   #<CPARM
            ldx   #>CPARM
            jmp   SC_CLOSE
:werr       lda   #<WRERRM
            ldx   #>WRERRM
            jmp   ARCFAIL
:nocreat    lda   #<NOMAKEM
            ldx   #>NOMAKEM
            jmp   ARCFAIL

*---------------------------------------------------------------
* CHKSDK -- ISDISK := 1 when PATHBUF (the archive name) ends
* case-insensitively in ".SDK", per docs/NUFX.md slice 8: the
* archive's OWN NAME says it holds disk images, the way ShrinkIt
* and CiderPress already tell the two apart. No new letter --
* real nulib2 has no flag for this because NufxLib's command
* line cannot add a disk image at all.
* CLOBBERS: A, X.
*---------------------------------------------------------------
*-- '.' survives OR #$20 unchanged (its bit 5 is already set),
*-- so ONE fold-and-compare loop covers all four characters --
*-- no separate unfolded test for the dot.
CHKSDK      stz   ISDISK
            lda   PATHBUF
            cmp   #4
            bcc   :no
            sec
            sbc   #4
            tax
            ldy   #0
:cmp        inx
            lda   PATHBUF,x
            ora   #$20
            cmp   SDKSUF,y
            bne   :no
            iny
            cpy   #4
            bne   :cmp
            inc   ISDISK
:no         rts
SDKSUF      asc   '.sdk'

*---------------------------------------------------------------
* MHBLANK -- write 48 zero bytes where the master header goes.
* MHPATCH fills them in once the record count and the archive's
* length are known. OUT: carry set = the write failed.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
MHBLANK     ldy   #0
            lda   #0
:zap        sta   MHBUF,y
            iny
            cpy   #48
            bne   :zap
            lda   #<MHBUF
            ldx   #>MHBUF
            ldy   #48
            jmp   WRBLK

*---------------------------------------------------------------
* TRUNCARC -- set the archive's EOF to exactly ARCEOF.
*
* NEEDED BECAUSE THE WRITER REWINDS. When a thread's coded form
* comes out no smaller than the plain one, ADDONE seeks back
* over what it wrote and stores the file instead -- and a ProDOS
* file does not shrink just because you wrote less at a lower
* mark. It keeps its high-water mark, so the archive would carry
* however many bytes the abandoned coding had run to past its
* own master_eof.
*
* NOTHING WOULD HAVE NOTICED. Every reader here, a2til and
* NufxLib included, walks by master_eof and stops; the slack is
* invisible to all of them. It showed up as 26 bytes of growth
* in a gate that happens to print the archive's FILE size, which
* is the only reason this is a bug and not a latent one.
* OUT: carry set = the call failed. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
TRUNCARC    lda   #2
            sta   SEPARM
            lda   ARCFD
            sta   SEPARM_REF
            ldx   #0
:cp         lda   ARCEOF,x
            sta   SEPARM_EOF,x
            inx
            cpx   #3
            bne   :cp
            lda   #<SEPARM
            ldx   #>SEPARM
            jmp   SC_SETEOF

*---------------------------------------------------------------
* MHPATCH -- build the real master header and write it at
* offset 0. Its CRC seeds $0000 over bytes [8:48], i.e.
* everything AFTER the CRC field -- one of the format's five
* conventions and not the one a thread uses
* (learning:01M0KZQJTHDP01FKPNP1HTWDW7).
* OUT: carry set = seek or write failed. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
MHPATCH     ldy   #0
            lda   #0
:zap        sta   MHBUF,y
            iny
            cpy   #48
            bne   :zap
            ldx   #0
:idlp       lda   MASTERID,x
            sta   MHBUF,x
            inx
            cpx   #6
            bne   :idlp
            lda   NRECW              ;total_records u32
            sta   MHBUFCRC
            lda   NRECW+1
            sta   MHBUF+9
            lda   #<NUFXDATE         ;created, modified
            sta   PTR0
            lda   #>NUFXDATE
            sta   PTR0+1
            ldy   #0
:dtlp       lda   (PTR0),y
            sta   MHBUF+12,y
            sta   MHBUF+20,y
            iny
            cpy   #8
            bne   :dtlp
            lda   #2                 ;master_version: says the
            sta   MHBUF+28           ;records may be v3
            lda   ARCEOF             ;master_eof u32 -- counts
            sta   MHBUF+38           ;this header, so it is the
            lda   ARCEOF+1           ;archive's whole length
            sta   MHBUF+39
            lda   ARCEOF+2
            sta   MHBUF+40
            stz   CRCVAL
            stz   CRCVAL+1
            lda   #<MHBUFCRC
            sta   CRCPTR
            lda   #>MHBUFCRC
            sta   CRCPTR+1
            lda   #40
            sta   CRCLEN
            stz   CRCLEN+1
            jsr   CRCBYTES
            lda   CRCVAL
            sta   MHBUF+6
            lda   CRCVAL+1
            sta   MHBUF+7
*-- A FAILED SEEK HERE MUST NOT BE IGNORED. The first version
*-- dropped SEEKPOS's carry, so when the seek failed the write
*-- simply went to the CURRENT mark: the master header landed at
*-- the end of the archive, the file came out exactly 48 bytes
*-- too long, offset 0 stayed zero, and the run reported
*-- success.
            stz   SEEKOFF            ;back to the top, on the fd
            stz   SEEKOFF+1          ;THIS routine writes -- not
            stz   SEEKOFF+2          ;through the reader's ARCFD
            lda   #<SEEKOFF
            sta   PTR0
            lda   #>SEEKOFF
            sta   PTR0+1
            lda   ADDFD
            ldy   #SEEK_SET
            jsr   LSEEK
            bcc   :attop
            sec
            rts
:attop      lda   #<MHBUF
            ldx   #>MHBUF
            ldy   #48
            jmp   WRBLK

*---------------------------------------------------------------
* ADDONE -- one file operand becomes one record. A file that
* cannot be read is reported and SKIPPED: the records already
* written stay valid, and an archive missing one member beats no
* archive at all. CLOBBERS: everything.
*---------------------------------------------------------------
ADDONE      lda   FIDX
            jsr   GETARG             ;leaves the string in PTR0
*-- A BARE '-' OPERAND MEANS STDIN (docs/NUFX-PIPE.md): masked
*-- for argv's high-bit encoding, one character, then NUL. Any
*-- other operand -- including a real path that happens to start
*-- with '-' followed by more characters -- is unaffected.
            stz   STDINFLAG
            ldy   #0
            lda   (PTR0),y
            and   #$7F
            cmp   #$2D               ;'-'
            bne   :normal
            iny
            lda   (PTR0),y
            bne   :normal
            inc   STDINFLAG
*-- -0 (NOCOMP) NEEDS TWO READS OF THE SAME INPUT (FILECRC then
*-- FILECOPY) -- fine for a seekable file, impossible for a pipe
*-- that is already at EOF the second time. Refused cleanly,
*-- the same way an unopenable path is: SKIPPED, nothing
*-- committed yet. docs/NUFX-PIPE-NOTES.md names the trigger.
            lda   NOCOMP
            beq   :dostdin
            bra   :cantadd
*-- STDIN: no path, so no GET_FILE_INFO and no GETDLEN -- a pipe
*-- cannot be lseek'd (LANGUAGE-CARD.md's sibling, PRC_SETMARK's
*-- own OFT_FILE/OFT_BLK-only guard, refuses it cleanly if ever
*-- tried). STDINFO fills the metadata a real path would have;
*-- DLEN starts at 0 and PACK1's pipe-reading arm accumulates
*-- the true total as bytes actually arrive.
:dostdin    jsr   STDINFO
            lda   #FD_STDIN
            sta   INFD
            stz   DLEN
            stz   DLEN+1
            stz   DLEN+2
            bra   :gotlen
*-- ONE SHARED TAIL for all three "cannot read, not added"
*-- warnings this routine can hit (the NOCOMP+stdin refusal
*-- above, and INFO's/GETDLEN's own failures below) -- one
*-- message load instead of three.
:cantadd    lda   #<CANTADDM
            ldx   #>CANTADDM
            jmp   ADDWARN
:normal     lda   #<INPATH
            sta   PTR1
            lda   #>INPATH
            sta   PTR1+1
            jsr   MKPATH
            jsr   INFO               ;type, aux, dates, length
            bcc   :gotinfo
            bra   :cantadd
*-- THE LENGTH FIRST, AND NOTHING WRITTEN YET. A file that
*-- cannot be opened is SKIPPED with a warning, and skipping is
*-- only possible while the archive has had nothing committed to
*-- it. Everything after this point is the archive's problem.
:gotinfo    jsr   GETDLEN
            bcc   :gotlen
            bra   :cantadd
*-- A HEADER WITH TWO FIELDS IT CANNOT KNOW YET. comp_thread_eof
*-- and the plaintext thread_crc are only known once the payload
*-- has been coded, and header_crc covers both -- so this writes
*-- a placeholder of exactly the right SIZE, and the real header
*-- is laid over it below. That is what removed the second pass
*-- (PACK1's header says why) and it is ShrinkIt's own trick.
:gotlen     ldx   #0
:rpsv       lda   ARCEOF,x
            sta   RECPOS,x
            inx
            cpx   #3
            bne   :rpsv
            stz   CSIZE
            stz   CSIZE+1
            stz   CSIZE+2
            stz   DCRC
            stz   DCRC+1
            lda   #1                 ;assume coded: the size is
            sta   COMPFLG            ;the same either way
            jsr   BUILDREC
            bcc   :on1
            jmp   :werr
:on1
            ldx   #0
:pysv       lda   ARCEOF,x
            sta   PAYPOS,x
            inx
            cpx   #3
            bne   :pysv
*-- `-0` SKIPS THE CODING ALTOGETHER. Not "code it and throw the
*-- answer away" -- the point of the flag is the work, not the
*-- bytes, and on this machine that is ~22 seconds against ~2
*-- for a 28 KB file. WORTHIT's comparison below then sees a
*-- CSIZE it can never beat and takes the stored path, which is
*-- the same path an incompressible file takes anyway.
            lda   NOCOMP
            bne   :stored
            jsr   PACK1
            bcc   :on2
            jmp   :werr
*-- The thread still needs its plaintext CRC, and PACK1 was the
*-- thing computing it -- so this path uses FILECRC, which the
*-- single-pass rewrite had left with no callers at all. Two
*-- reads and no coding, which is what `-0` is asking for.
:stored     jsr   FILECRC
            bcc   :nocrcerr
            jmp   :werr
:nocrcerr   ldx   #0                 ;a length no coding can
:csbig      lda   #$FF               ;reach, so WORTHIT stores
            sta   CSIZE,x
            inx
            cpx   #3
            bne   :csbig
:on2
*-- STDIN + .SDK: GETDLEN's own "whole number of 512-byte
*-- blocks" check runs BEFORE commit for a real path; a pipe's
*-- true length is not known until PACK1 has read every byte,
*-- and BY THEN the placeholder header is already written -- so
*-- this cannot un-commit the way a real GETDLEN failure does.
*-- It is the archive's problem now, and this build's arena has
*-- no room left to say so out loud either (docs/NUFX-PIPE-
*-- NOTES.md): BUILDREC's own extra_type shift already floors
*-- silently to whole blocks either way, exactly as it would for
*-- a real file if GETDLEN's own check were ever bypassed --
*-- this is a KNOWN, undiagnosed gap for an odd-length `.SDK`
*-- piped in, not a new failure mode.
*-- AND IF CODING LOST, rewind over it and store instead. Only
*-- this branch reads the input twice, and it is the branch
*-- where the file was small or incompressible enough that a
*-- second pass costs nothing. A STDIN INPUT CANNOT TAKE THIS
*-- BRANCH -- the pipe is already at EOF -- so COMPFLG is forced
*-- to "kept" for it regardless of what WORTHIT decided; the
*-- coded thread is what the archive gets, even on the rare
*-- input where coding did not shrink it.
            jsr   WORTHIT
            lda   STDINFLAG
            bne   :kept
            lda   COMPFLG
            bne   :kept
            ldx   #0
:pyback     lda   PAYPOS,x
            sta   POS,x
            sta   ARCEOF,x
            inx
            cpx   #3
            bne   :pyback
            jsr   SEEKPOS
            jsr   FILECOPY
            bcc   :on3
            jmp   :werr
:on3
            ldx   #0
:dlcp       lda   DLEN,x
            sta   CSIZE,x
            inx
            cpx   #3
            bne   :dlcp
:kept       ldx   #0                 ;where the record really
:epsv       lda   ARCEOF,x           ;ends
            sta   ENDPOS,x
            sta   POS,x
            inx
            cpx   #3
            bne   :epsv
            ldx   #0
:rpback     lda   RECPOS,x
            sta   POS,x
            inx
            cpx   #3
            bne   :rpback
            jsr   SEEKPOS
            jsr   BUILDREC           ;the real one, over the
            bcc   :on4        ;placeholder
            jmp   :werr
:on4
            ldx   #0                 ;BUILDREC counted its 124
:eprest     lda   ENDPOS,x           ;bytes a second time; the
            sta   ARCEOF,x           ;archive is this long
            sta   POS,x
            inx
            cpx   #3
            bne   :eprest
            jsr   SEEKPOS
            inc   NRECW
            bne   :done
            inc   NRECW+1
:done       rts
:werr       lda   #<WRERRM
            ldx   #>WRERRM
            jmp   ARCFAIL

*---------------------------------------------------------------
* BUILDREC -- the 60-byte record header, its two thread records
* and the padded name, written in one go. header_crc covers
* [+6 .. end of the thread array]; every field it covers is in
* memory here, which is the whole reason this is assembled
* before anything is written.
* OUT: carry set = the write failed. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
BUILDREC    ldy   #0
            lda   #0
:zap        sta   RECBUF,y
            iny
            cpy   #60
            bne   :zap
            ldx   #0
:idlp       lda   RECORDID,x
            sta   RECBUF,x
            inx
            cpx   #4
            bne   :idlp
            lda   #60              ;attrib_count: the authority
            sta   RECBUFCRC           ;where this header ends
            lda   #3               ;record version 3 -- the one
            sta   RECBUF+8           ;whose thread_crc means
            lda   #2                 ;something
            sta   RECBUF+10          ;total_threads
            lda   #1               ;file_sys_id: ProDOS, and we
            sta   RECBUF+14          ;can say so honestly
            lda   #$2F               ;file_sys_info low byte IS
            sta   RECBUF+16          ;the pathname separator
            lda   FACCESS
            sta   RECBUF+18
            lda   FTYPE
            sta   RECBUF+22
            lda   FAUX
            sta   RECBUF+26
            lda   FAUX+1
            sta   RECBUF+27
            lda   #1                 ;storage_type: descriptive
            sta   RECBUF+30        ;here, a record has no blocks
*-- A DISK RECORD (docs/NUFX.md slice 8) OVERWRITES three of
*-- those: file_type is ZERO, extra_type is the BLOCK COUNT (the
*-- byte length >> 9 -- GETDLEN already refused any length that
*-- is not a whole number of 512-byte blocks, so this is exact)
*-- and storage_type is $0200 -- 512, the block size, not a
*-- descriptive ProDOS storage type.
            lda   ISDISK
            beq   :stypeok
            stz   RECBUF+22
            lda   DLEN+2
            lsr   a
            sta   RECBUF+27
            lda   DLEN+1
            ror   a
            sta   RECBUF+26
            stz   RECBUF+30
            lda   #2
            sta   RECBUF+31
:stypeok    lda   #<NUFXDATE
            sta   PTR0
            lda   #>NUFXDATE
            sta   PTR0+1
            ldy   #0
:dtlp       lda   (PTR0),y
            sta   RECBUF+32,y        ;created
            sta   RECBUF+40,y        ;modified
            sta   RECBUF+48,y        ;archived
            iny
            cpy   #8
            bne   :dtlp
*-- option_size and filename_length both stay zero: no GS/OS
*-- option list, and the name goes in a thread the way every
*-- modern writer puts it.
            jsr   BUILDTHR
            stz   CRCVAL
            stz   CRCVAL+1
            lda   #<RECBUFCRC
            sta   CRCPTR
            lda   #>RECBUFCRC
            sta   CRCPTR+1
            lda   #54                ;+6..+59
            sta   CRCLEN
            stz   CRCLEN+1
            jsr   CRCBYTES
            lda   #<THRBUF
            sta   CRCPTR
            lda   #>THRBUF
            sta   CRCPTR+1
            lda   #32                ;both thread records
            sta   CRCLEN
            stz   CRCLEN+1
            jsr   CRCBYTES
            lda   CRCVAL
            sta   RECBUF+4
            lda   CRCVAL+1
            sta   RECBUF+5
            lda   #<RECBUF
            ldx   #>RECBUF
            ldy   #60
            jsr   WRBLK
            bcs   :err
            lda   #<THRBUF
            ldx   #>THRBUF
            ldy   #32
            jsr   WRBLK
            bcs   :err
            lda   #<NAMEPAD
            ldx   #>NAMEPAD
            ldy   #FNALLOC
            jmp   WRBLK
:err        sec
            rts

*---------------------------------------------------------------
* BUILDTHR -- the two thread records, and the padded name buffer
* they describe.
*
* The filename thread is OVER-ALLOCATED to FNALLOC on purpose:
* that is what nulib2 and P8 ShrinkIt both do, and it is the
* trap a reader has to survive (thread_eof is the USED length,
* comp_thread_eof the ALLOCATED one). Writing them equal would
* produce archives that never exercise it.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
BUILDTHR    ldy   #0
            lda   #0
:zap        sta   THRBUF,y
            iny
            cpy   #32
            bne   :zap
            ldy   #0
:npad       lda   #0
            sta   NAMEPAD,y
            iny
            cpy   #FNALLOC
            bne   :npad
*-- A disk record's name is the input's basename (LEAFIN), same
*-- as a file's. docs/NUFX.md slice 8 also allows the image's
*-- own ProDOS volume name here, graded [likely] and NOT load-
*-- bearing -- both host oracles find the record by its disk
*-- thread, not its name -- and this build's err */$BF00 arena
*-- ceiling has no room for the ~120 bytes a block-2 read
*-- costs. Left undone; trigger: headroom after a future size-
*-- reduction pass.
*-- A `-` (stdin) OPERAND HAS NO PATH, so LEAFIN (which reads
*-- INPATH) has nothing to read -- STEMNAME reads the ARCHIVE's
*-- OWN name instead (docs/NUFX-PIPE-NOTES.md): "FLOP.SDK" ->
*-- "FLOP". Both routines fill the SAME NAMEPAD/NAMELEN cells,
*-- so nothing downstream needs to know which ran.
            lda   STDINFLAG
            bne   :stdinnm
            jsr   LEAFIN
            bra   :namedone
:stdinnm    jsr   STEMNAME
:namedone
            lda   #3                 ;CLASS_FILENAME
            sta   THRBUF
            lda   NAMELEN            ;thread_eof: what is USED
            sta   THRBUF+8
            lda   #FNALLOC           ;comp_thread_eof: allocated
            sta   THRBUF+12
            lda   #2                 ;CLASS_DATA
            sta   THRBUF+16
            lda   ISDISK             ;thread_kind: 0 data fork,
            sta   THRBUF+20          ;1 disk image
            lda   COMPFLG            ;$0003 coded, $0000 stored
            beq   :fmtok
            lda   #3
            sta   THRBUF+18
:fmtok      lda   DCRC             ;a v3 thread_crc: seed $FFFF
            sta   THRBUF+22          ;over the PLAINTEXT
            lda   DCRC+1
            sta   THRBUF+23
*-- thread_eof is what comes OUT; comp_thread_eof is what the
*-- archive SPENDS. Stored they agree, coded they do not, and
*-- conflating them is this format's oldest trap.
            ldx   #0
:lenlp      lda   DLEN,x
            sta   THRBUF+24,x
            inx
            cpx   #3
            bne   :lenlp
            ldx   #0
:clenlp     lda   COMPFLG
            beq   :usedlen
            lda   CSIZE,x
            bra   :putlen
:usedlen    lda   DLEN,x
:putlen     sta   THRBUF+28,x
            inx
            cpx   #3
            bne   :clenlp
            rts

*---------------------------------------------------------------
* WRBLK -- Y bytes from A/X to the archive, advancing ARCEOF so
* the master header can say how long the archive became.
* OUT: carry set = short or failed. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
WRBLK       sta   WPARM_BUF
            stx   WPARM_BUF+1
            sty   WPARM_REQ
            stz   WPARM_REQ+1
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
            adc   #0
            sta   ARCEOF+1
            lda   ARCEOF+2
            adc   #0
            sta   ARCEOF+2
            clc
            rts
:bad        sec
            rts
