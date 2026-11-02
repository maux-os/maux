*---------------------------------------------------------------
* nulib2.s -- read a NuFX (ShrinkIt) archive.
*
* Usage: nulib2 -t archive
*
* Slice 1 of docs/NUFX.md: LIST. It parses the master header,
* every record header and every thread record, verifies the two
* header CRCs, and prints one row per record. It decompresses
* NOTHING -- that is slices 2-4 -- but it walks the whole
* structure, which is where a NuFX reader actually breaks.
*
* WHY THIS EXISTS. Every piece of Apple II software anyone wants
* is in a .SHK, and maux had no archive tool at all: `ar`,
* `compress` and `uncompress` are man stubs. a2til reads NuFX
* completely ON THE HOST, so this is deliberately not a host
* tool -- the gap was that the machine itself could not open an
* archive, which is backwards for a system whose user is a
* stranger with the disk.
*
* THE FOUR OFFSET TRAPS, all from
* learning:01M0KZQJTHDP01FKPNP1HTWDW7 and all confirmed against
* real bytes before a line of this was written (docs/NUFX.md):
*
*  1. `comp_thread_eof` is the ALLOCATED length and `thread_eof`
*     the USED one. Seek by comp, read by eof. In the very first
*     archive nulib2 makes, the filename thread is eof=9
*     comp=32 and the comment thread is eof=0 comp=200 -- 200
*     bytes of pure padding. Advancing by the wrong one lands
*     at 165 instead of 188 and desyncs every record after it.
*  2. `attrib_count` is the authority for the end of the record
*     header. `filename_length` sits at attrib_count-2, NEVER at
*     a fixed offset, because a v1+ GS/OS option list of
*     variable length sits in between. This reads the tail in
*     chunks and takes the LAST TWO BYTES, so any attrib_count
*     works and a v0 record (where those two bytes are the
*     filename_length directly) needs no special case.
*  3. The name is usually NOT in the header. nulib2 writes
*     filename_length=0 and puts it in a CLASS_FILENAME thread,
*     whose payload is past the whole thread array.
*  4. `file_sys_id` is unreliable -- nulib2 writes 0 ("unknown")
*     while separating with ':'. Nothing here branches on it.
*
* CRC-16/XMODEM, poly $1021, MSB first, no final xor. Two of the
* format's five conventions are checked here, and they differ:
* `master_crc` seeds $0000 over master[8:48]; `header_crc` seeds
* $0000 over record[+6 .. end of the thread array]. The third,
* a v3 `thread_crc` seeding $FFFF over the PLAINTEXT, belongs to
* slice 2 -- there is no plaintext until something expands.
* Verified against a real archive: $63ED, $05F9, $F97B.
*
* A CRC mismatch is reported and does NOT stop the walk: a
* damaged record is exactly when someone wants to see what else
* is in the file. Exit 1 if any row was bad.
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/nulib2.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

*-- CONSTANTS FIRST, above every `put` that uses them. Real
*-- Merlin-8 refuses a forward `equ` reference outright
*-- (learning:01M05519PC55WGJNE4PY5HX4TH) while merlin32 accepts
*-- one silently, so a unit with one cannot self-host even
*-- though it builds here. NAMEMAX is read by nulib2thr.s and
*-- TYPEN by nulib2io.s, both `put` below.
NAMEMAX     equ   64        ;NAMEBUF's capacity
TYPEN       equ   5         ;rows in nulib2io.s's TYPETAB
*-- PARTIALLY RESTORED, $40 not $80 (docs/NUFX-PIPE-NOTES.md).
*-- The slice 8 cut moved CRCTABL/CRCTABH off the LOW arena
*-- entirely (below, "THE CRC TABLE" note after the low
*-- arena's `dend`), which affords a full restore on its own --
*-- but the pipe slice's OWN new code (the write-all fix XPUT
*-- needed once `-p`'s output actually reached a live pipe,
*-- the `-`/NAME features) spent that margin back down to
*-- single digits, and this is the one further cut with NO
*-- measured cost against this slice's own workload: XBUFSZ
*-- governs only a STORED-thread `-x`/`-p` or a `-0`/FILECRC
*-- pass, and check-unpack's pipeout fixture (XMASADV.SDK) is
*-- LZW/1-coded, so it never touches XBUF at all -- LZBUFSZ
*-- (below) is the one this slice's own -x measurement actually
*-- exercised, and it keeps its full restore. Real cost: a
*-- large STORED extraction issues twice as many SC_READ/
*-- SC_WRITE calls as a full $80 would.
XBUFSZ      equ   $40       ;nulib2ext.s's copy chunk
FNALLOC     equ   32        ;what a filename thread is given
*-- RESTORED to $80 alongside XBUFSZ, same reasoning. LZGETB/
*-- LZREFILL are byte-generic (LZREFILL explicitly tolerates a
*-- short read), so this only changes how often the compressed
*-- stream is topped up, never what a decode produces.
LZBUFSZ     equ   $80       ;nulib2lzc.s's stream window
LZ_DSKVOL   equ   $FE       ;LZW/2 stream disk_volume:
                            ;NufxLib kNuLZWDefaultVol,
                            ;written for every thread
*-- 4096, because LZW/2 needs it: its table PERSISTS across
*-- chunks, so a single code can name a string as long as the
*-- whole chunk. LZW/1 never uses more than about 100 of it --
*-- a table built in one chunk cannot name a longer string --
*-- but the two formats share this code, so it is sized for the
*-- one that needs it.
LZSTKHI     equ   $10       ;4096 = $1000, as a page count
*-- AND IT IS ALSO THE ENCODER'S BUCKET ARRAY: nulib2lze.s puts
*-- 2048 hash heads over this stack, because compression never
*-- runs in the same process as expansion. Shrink the stack and
*-- the buckets stop being covered, silently, with a corrupt
*-- archive as the only symptom -- so the two sizes are pinned
*-- here. Merlin has no operator precedence, so the expression
*-- is written to come out right evaluated left to right.
            err   LZSTKHI*256-4096

*-- Private zero page. $30-$8F is clear of everything in a
*-- userland bank -- sed.s's own box establishes it and ed.s
*-- agrees. ONE pointer needs to be here and only one:
*-- (CRCPTR),y is this program's single indirect read. RDPTR is
*-- merely copied into an MLI parmlist, so it stays in the arena
*-- with the rest of the per-run state.
CRCPTR      equ   $30       ;2  CRCBYTES's source walk
LZP         equ   $32       ;2  nulib2lzc.s's table walk
LZOP        equ   $34       ;2  its output / RLE input cursor
LZCP        equ   $36       ;2  the expanded chunk cursor
LZSTKP      equ   $38       ;2  the decode stack cursor
*-- The ENCODER's two cursors. They are their own cells rather
*-- than borrowed from the four above: the decode ones are free
*-- while compressing, but `(ptr),y` needs zero page and a
*-- borrowed name in an inner loop is one refactor away from
*-- two routines sharing a cursor by accident.
LZE_IP      equ   $3A       ;2  the chunk being coded
LZE_OP      equ   $3C       ;2  where the codes go

*-- PARMLISTS IN THE ARENA, not in TEXT. chtyp.s's header has
*-- the full argument: emitted as dfb/da they are image bytes
*-- the MLI writes into, and the kernel RETAINS a bank whose
*-- entry head is intact, so the next warm respawn starts on
*-- mutated text. check-textaudit measures this.
START       jsr   CRCINIT            ;every verb checksums
            lda   #PCOUNT_OPEN
            sta   OPARM
            lda   #PCOUNT_READ
            sta   RPARM
            lda   #PCOUNT_CLOSE
            sta   CPARM
            sta   XCPARM
            lda   #PCOUNT_WRITE
            sta   WPARM
            lda   #<PATHBUF
            sta   OPARM_PATH
            lda   #>PATHBUF
            sta   OPARM_PATH+1
            stz   OPARM_IOBUF
            stz   OPARM_IOBUF+1
            stz   ERRFLAG
            stz   TFLAG
            stz   VFLAG
            stz   XFLAG
            stz   PFLAG
            stz   IFLAG
            stz   AFLAG
            stz   NOCOMP
            stz   ISDISK
            stz   XMODE
            stz   B2OFF
            stz   WANTNAME
            lda   #<NUOPTS
            ldx   #>NUOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            and   #$7F               ;the option letter arrives
            cmp   #$74               ;in argv's encoding; mask
                                     ;it and this survives the
                                     ;flip
            bne   :not_t
            lda   #1
            sta   TFLAG
            bra   :optlp
:not_t      cmp   #$76               ;'v'
            bne   :not_v
            lda   #1
            sta   VFLAG
            bra   :optlp
:not_v      cmp   #$78               ;'x'
            bne   :not_x
            lda   #1
            sta   XFLAG
            bra   :optlp
:not_x      cmp   #$70               ;'p'
            bne   :not_p
            lda   #1
            sta   PFLAG
            bra   :optlp
:not_p      cmp   #$69               ;'i'
            bne   :not_i
            lda   #1
            sta   IFLAG
            bra   :optlp
:not_i      cmp   #$30               ;'0' -- nulib2's own letter
            bne   :not_0             ;for "do not compress"
            lda   #1
            sta   NOCOMP
            bra   :optlp
:not_0      cmp   #$61               ;'a'
            beq   :is_a
            jmp   :usage
:is_a       lda   #1
            sta   AFLAG
            bra   :optlp
*-- EXACTLY ONE VERB, counted rather than xor'd: three flags do
*-- not fit in a parity test. A bare archive is a usage error
*-- rather than a guess, and so is naming two -- `nulib2 -tx`
*-- would have to mean "list AND extract", which is two passes
*-- over a file this reader walks once.
:optdone    lda   TFLAG
            clc
            adc   VFLAG
            clc
            adc   XFLAG
            clc
            adc   PFLAG
            clc
            adc   IFLAG
            clc
            adc   AFLAG
            cmp   #1
            beq   :oneverb
            jmp   :usage
:oneverb
*-- XMODE tells the extractor which of the three fork verbs is
*-- running: 0 writes a file, 1 pipes to stdout, 2 writes
*-- and only checks. They share every other step, which is the
*-- point -- `-p` and `-i` are not second implementations of the
*-- expander, they are the same one with its output redirected
*-- or discarded.
            lda   PFLAG
            beq   :notpipe
            lda   #1
            sta   XMODE
:notpipe    lda   IFLAG
            beq   :modeok
            lda   #2
            sta   XMODE
:modeok
            lda   ARGC
            sec
            sbc   OPTIND
*-- -a wants the archive name AND at least one file; every read
*-- verb wants the archive and nothing else.
            ldx   AFLAG
            beq   :readverb
            cmp   #2
            bcs   :haveops
            jmp   :usage
*-- A SECOND OPERAND ON A READ VERB IS A NAME FILTER --
*-- `nulib2 -p archive NAME` (docs/NUFX-PIPE.md), so `-p` can
*-- extract exactly the one disk record a `dd ... | nulib2 -p
*-- archive NAME | dd ...` pipeline wants onto a unit, not every
*-- record concatenated. Only for X/P/I: `-t`/`-v` keep their
*-- original exactly-one-operand shape, unchanged.
*-- The NAME's own pointer is not fetched here -- OPTIND does
*-- not move again once parsing is done, so NAMEMATCH
*-- (nulib2arc.s) re-derives it with the SAME GETARG(OPTIND+1)
*-- call at match time instead of this routine caching it into
*-- an arena cell it would otherwise need.
:readverb   cmp   #1
            beq   :haveops
            cmp   #2
            bne   :rvbad
            lda   XFLAG
            ora   PFLAG
            ora   IFLAG
            beq   :rvbad
            inc   WANTNAME
            bra   :haveops
:rvbad      jmp   :usage
:haveops    lda   OPTIND
*-- GETARG returns the string in PTR0 ALONE. A is left holding
*-- the pointer's HIGH byte and X the argv index doubled, so the
*-- obvious `sta PTR0 / stx PTR0+1` after it overwrites the
*-- answer with garbage -- which opens nothing while still
*-- printing the right path in the error, because PUTS reads the
*-- PTR0 a later GETARG set correctly. cat.s says it plainly:
*-- "PTR0 again -- the test above left it".
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
*-- -a CREATES the archive; the read verbs open one.
            lda   AFLAG
            beq   :readopen
            jsr   ADDARC
            lda   ERRFLAG
            jsr   EXIT
:readopen   lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :noopen
            lda   OPARM_REF
            sta   ARCFD
            sta   RPARM_REF
            sta   CPARM_REF
            jsr   LISTARC
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            lda   ERRFLAG
            jsr   EXIT
:noopen     lda   #<CANTOPEN
            sta   PTR0
            lda   #>CANTOPEN
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   OPTIND
            jsr   GETARG             ;PUTS clobbered PTR0
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$0D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            jsr   EXIT
:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

            put   nulib2arc.s
            put   nulib2lst.s
            put   nulib2ext.s
            put   nulib2add.s
            put   nulib2af.s
            put   nulib2rle.s
            put   nulib2lze.s
            put   nulib2lzw.s
            put   nulib2lzc.s
            put   nulib2io.s
            put   nulib2msg.s

            put   ../liba/string.s
            put   ../liba/print.s
            put   ../liba/hex.s
            put   ../liba/getopt.s
            put   ../liba/argv.s
            put   ../liba/mli.s
            put   ../liba/creat.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/syscalls.s
            put   ../liba/seek.s
            put   ../liba/libabss.s
*---------------------------------------------------------------
* THE ARENA: every byte of per-run state nulib2 owns, in a
* `dum` block so none of it is emitted into the image.
*
* IT STAYS INLINE HERE, and that is not an oversight. It
* anchors on LIBA_BSSEND, so it must follow
* `put ../liba/libabss.s` -- and check-modules refuses a
* non-liba `put` after that file, so it cannot become a module
* of its own the way the rest of this program has. The
* resident window pays for the declarations; the message
* strings went to nulib2msg.s instead, because emitted data
* has no such constraint.
*---------------------------------------------------------------


            dum   LIBA_BSSEND
ERRFLAG     ds    1
TFLAG       ds    1
ARCFD       ds    1
CRCBAD      ds    1
POS         ds    3
SAVEPOS     ds    3
PAYSUM      ds    3
FNOFF       ds    3
NRECS       ds    2
NTHR        ds    2
TAILLEN     ds    2
FNLEN       ds    2
FNTLEN      ds    2
NAMELEN     ds    1
HAVEFN      ds    1
HAVEDATA    ds    1
ISDSKREC    ds    1                  ;this record's data thread
                                     ;is a disk image (kind 1)
FTYPE       ds    1
FAUX        ds    2
DSIZE       ds    4
XFLAG       ds    1
VFLAG       ds    1
PFLAG       ds    1
IFLAG       ds    1
AFLAG       ds    1
NOCOMP      ds    1
ISDISK      ds    1                  ;-a: archive name ends .SDK
ADDFD       ds    1
INFD        ds    1
FIDX        ds    1
FACCESS     ds    1
MDTMP       ds    1
*-- THE PIPE SLICE (docs/NUFX-PIPE.md): `-a ARCHIVE -` reads
*-- fd 0 instead of a path, `-p ARCHIVE NAME` filters the
*-- extract walk to one record.
STDINFLAG   ds    1                  ;-a operand N is "-"
PIPEOFF     ds    2                  ;RDCHUNK's pipe-fill cursor
WANTNAME    ds    1                  ;-x/-p/-i got a NAME
NRECW       ds    2
DCRC        ds    2
DLEN        ds    3
ARCEOF      ds    3
NUFXDATE    ds    8
COMPFLG     ds    1
CSIZE       ds    3
WL          ds    2
RLELEN      ds    2
RLEIN       ds    2
RLERUN      ds    2
RLEVAL      ds    1
RLECV       ds    1
RLECC       ds    1
RLETMP      ds    2
*-- THE FIVE BUFFERS BELOW ARE SPLIT AT AN OFFSET ON PURPOSE.
*-- Each has a sub-field -- the CRC-covered span, or a flag --
*-- whose ADDRESS this program loads, and `#>BUF+n` on a `dum`
*-- cell cannot survive the REL link: that arena is a separate
*-- bss MODULE under the nas+ld split, so BUF is EXTERNAL, and
*-- kind $50 spends byte3 on the refnum with nowhere left to put
*-- the addend's low half. The linker drops the carry out of
*-- `low(BUF) + n` and the byte comes out one too low
*-- (docs/REL-FORMAT.md, learning:01M2PSVAFMJJQN1PMPVS0FPYZP).
*-- RECHDR is the one that FIRED -- it sits at $97FF, so +6
*-- crosses a page -- and check-nas-librel caught it as a single
*-- byte, $97 against merlin32's $98, in an otherwise identical
*-- image. The other four are correct today only because their
*-- low bytes happen not to carry, which is not a property to
*-- rely on: an arena cell moves whenever the image before it
*-- changes size. Giving the offset its own label makes every
*-- addend ZERO, which the format carries exactly. Do not merge
*-- these back into one `ds`.
MHBUF       ds    8
MHBUFCRC    ds    40
RECBUF      ds    6
RECBUFCRC   ds    54
THRBUF      ds    32
NAMEPAD     ds    FNALLOC
INPATH      ds    65
IOPARM      ds    1
IOPARM_PATH ds    2
IOPARM_IOBUF ds   2
IOPARM_REF  ds    1
ICPARM      ds    1
ICPARM_REF  ds    1
XMODE       ds    1
B2OFF       ds    1
RECVER      ds    2
SEPCH       ds    1
DATOFF      ds    3
DATFMT      ds    2
DATCRC      ds    2
REMAIN      ds    3
XSAVE       ds    3
OUTFD       ds    1
XMSGL       ds    1
XMSGH       ds    1
OUTPATH     ds    65
XBUF        ds    XBUFSZ
WPARM       ds    1
WPARM_REF   ds    1
WPARM_BUF   ds    2
WPARM_REQ   ds    2
WPARM_TRANS ds    2
XCPARM      ds    1
XCPARM_REF  ds    1
XGPARM      ds    1
XGPARM_PATH ds    2
XGPARM_ACC  ds    1
XGPARM_FTYP ds    1
XGPARM_AUX  ds    2
XGPARM_STYP ds    1
XGPARM_BLKS ds    2
XGPARM_MDATE ds   2
XGPARM_MTIME ds   2
XGPARM_CDATE ds   2
XGPARM_CTIME ds   2
XSPARM      ds    1
XSPARM_PATH ds    2
XSPARM_ACC  ds    1
XSPARM_FTYP ds    1
XSPARM_AUX  ds    2
XSPARM_NULL ds    3
XSPARM_MDATE ds   2
XSPARM_MTIME ds   2
LZ_HDR      ds    4
LZ_CHDR     ds    2
LZ_CHDRFLG  ds    1
LZ_ESC      ds    1
LZ_SCRC     ds    2
LZ_CCRC     ds    2
LZ_TCRC     ds    2
LZ_RLEN     ds    2
LZ_FLAG     ds    1
LZ_RUSED    ds    1
LZ_WLEN     ds    2
LZ_ILEFT    ds    2
LZ_OLEFT    ds    2
LZ_RVAL     ds    1
LZ_RCNT     ds    1
LZ_TMP      ds    2
LZ_ENTRY    ds    2
LZ_OLD      ds    2
LZ_IN       ds    2
LZ_PTR      ds    2
LZ_TIX      ds    2
LZ_CODE     ds    2
LZ_FIN      ds    1
LZ_SP       ds    2
LZ_ACC      ds    3
LZ_HAVE     ds    1
LZ_W        ds    1
LZ_MSKL     ds    1
LZ_MSKH     ds    1
LZ_BPOS     ds    1
LZ_BLEN     ds    1
LZ_USED     ds    2
LZBAD       ds    1
LZ_T2       ds    1
LZ_RSTFIX   ds    1
LZ_CLRING   ds    1
LZ_XLEN     ds    2
CHKSTART    ds    3
LZ_STACK    ds    4096
LZ_LBUF     ds    LZBUFSZ
LZ_OUT      ds    4096
LZ_CHUNK    ds    4096
*-- NOT page-aligned, and nulib2lzc.s adds a full 16-bit offset
*-- because of it. Merlin's `ds \` aligns, merlin32 honours it,
*-- but `nas` does not -- it reports "ds operand unresolved" and
*-- refuses the unit, so the page-aligned version built here and
*-- could not self-host. check-nas-librel caught it: it is the
*-- only gate that assembles this tree with its own assembler.
*-- The ENCODER's state (nulib2lze.s). LZE_E is the next free
*-- code and is ONE AHEAD of the decoder's LZ_ENTRY at the same
*-- point in the stream -- see LZEMIT for why that matters.
LZE_E       ds    2
LZE_W       ds    2
LZE_LAST    ds    2
LZE_PEND    ds    1
LZE_K       ds    1
LZE_C       ds    2
LZE_H       ds    2
LZE_BK      ds    2
LZE_T       ds    3
LZE_TT      ds    2
LZE_CODE    ds    2
LZE_WID     ds    1
LZE_ACC     ds    3
LZE_HAVE    ds    1
LZE_OLEN    ds    2
LZE_OMAX    ds    2
LZE_ILEFT   ds    2
LZE_PB      ds    1
*-- CRCTABL/CRCTABH are back in the LOW arena (docs/NUFX-LC-
*-- NOTES.md): the 7,680-byte LZ_NEXT took their place in the
*-- language card common region ("THE LZW CHAIN TABLE" after
*-- this dum's `dend`).
CRCTABL     ds    256
CRCTABH     ds    256
CRCTMP      ds    2
SEPARM      ds    1
SEPARM_REF  ds    1
SEPARM_EOF  ds    3
*-- Where this record starts, where its payload starts, and
*-- where it ends -- the three marks ADDONE seeks between to lay
*-- the real header over the placeholder it wrote first.
RECPOS      ds    3
PAYPOS      ds    3
ENDPOS      ds    3
*-- What CHUNKPREP decided.
CHKIND      ds    1
CHLEN       ds    2
CHBUF       ds    2
CHRLEN      ds    2
*-- (The encoder's collision chains, LZ_NEXT, live in the
*-- language card -- "THE LZW CHAIN TABLE" below.)
LZ_PFXL     ds    4096
LZ_PFXH     ds    4096
LZ_SFX      ds    4096
CRCVAL      ds    2
TYPEIDX     ds    1
TYPECNT     ds    1
SIZELEN     ds    1
U4_LZ       ds    1
U4_DIG      ds    1
U4_T        ds    3
CRCLEN      ds    2
RDPTR       ds    2
RDLEN       ds    2
MHDR        ds    8
MHDRCRC     ds    40
RECHDR      ds    6
RECHDRCRC   ds    52
THR         ds    16
SCRATCH     ds    64
NAMEBUF     ds    66
SIZEBUF     ds    12
SEEKOFF     ds    3
OPARM       ds    1
OPARM_PATH  ds    2
OPARM_IOBUF ds    2
OPARM_REF   ds    1
RPARM       ds    1
RPARM_REF   ds    1
RPARM_BUF   ds    2
RPARM_REQ   ds    2
RPARM_TRANS ds    2
CPARM       ds    1
CPARM_REF   ds    1
PATHBUF     ds    65                 ;count byte + 64 chars
*-- THE ARENA'S CEILING, which this program had never declared
*-- although 79 others do. It is not decoration here: the LZW
*-- encoder's chains took the block to within ~1.5 KB of the
*-- floor of the free region, so the next buffer added blind is
*-- the one that overruns it.
            err   */$BF00
            dend

*-- THE LZW CHAIN TABLE, IN THE PROCESS LANGUAGE CARD COMMON
*-- REGION (docs/NUFX-LC.md; the CRC tables lived here from the
*-- pipe slice until this move -- docs/NUFX-PIPE-NOTES.md, and
*-- ex.s did the same for EX_SHADOW, commit 1f232ed).
*-- $E000-$FEFF is UNBANKED: the same physical bytes regardless
*-- of which $D000-$DFFF bank $C083/$C08B selected -- confirmed
*-- independently by learning:01M2MCYEXW7JA7ZPZ4F7GC2217 ("the
*-- two LC banks alias $D000-$DFFF only") -- and every maux
*-- process already runs with LC read-RAM + write-enable LATCHED
*-- before its first instruction: its own $FFxx syscall stubs
*-- live IN the language card, so merely being here to execute
*-- proves the steady state (docs/LANGUAGE-CARD.md) already
*-- holds. NO $C08x switch anywhere in this program, and none is
*-- needed or may be added (learning:01M2Y920F5DM0YKMCFVZDEBR6F:
*-- write-enable is one machine-wide latch with no readback).
*-- THE TEST THAT SAME LEARNING GIVES for what may live up here:
*-- "does a SYSCALL ever receive this address?" LZ_NEXT is
*-- touched ONLY by LZENPTR (nulib2lze.s), which forms its
*-- address into LZP, and every access is `lda/sta (LZP),y` --
*-- never handed to SC_READ/SC_WRITE/PUTS or any MLI parmlist
*-- (copyin refuses >= $D000). LZ_OUT and LZ_CHUNK ARE handed to
*-- syscalls, so they stay in the low arena above.
*-- It is the encoder's collision chains, indexed by a DOUBLED
*-- code with $0100 taken off it first (LZENPTR says why): a
*-- chain node is always an entry, and entries start at $0101,
*-- so the array holds 3840 and not 4096. The buckets it pairs
*-- with are LZ_STACK, which is dead while compressing.
*-- It must be ABSOLUTE: a `dum` on an external base is placed
*-- wrong by the nas+ld path (the LZ_STACK note below). 7,680 of
*-- the 7,936 bytes there; the CRC tables (512) cannot share it,
*-- which is why they went back low.
            dum   $E000
LZ_NEXT     ds    7680
            err   */PRC_LC_TOP
            dend

*-- THE HASH HEADS ARE THE DECODE STACK. Expansion and
*-- compression never run in the same process -- a program
*-- either reads an archive or writes one -- so LZ_STACK's 4096
*-- bytes are dead for the whole of `-a`, and that is the only
*-- reason the encoder's index fits at all.
*--
*-- IT IS SPELLED `LZ_STACK` AT BOTH USE SITES, and it was worth
*-- one red to learn why. The readable form is an alias --
*-- `dum LZ_STACK / LZ_HEAD ds 4096 / dend` -- which merlin32
*-- assembles correctly and the REL link gets WRONG: under the
*-- nas+ld split this arena is a separate bss module, so
*-- LZ_STACK is an EXTERNAL whose value no assembler knows, and
*-- a `dum` needs that value at assembly time to place its
*-- labels. nas placed them 18 bytes off and said nothing;
*-- check-nas-librel caught it as one byte of a 10,535-byte
*-- image. Same lesson as the `#>BUF+n` carry above and a
*-- different mechanism: a construct can be correct in the flat
*-- build and unrepresentable in the relocatable one, and only
*-- the byte-compare between the two routes can see it.
*--
*-- The size assertion that pins the two together lives with
*-- LZSTKHI at the top of this file, not here: everything after
*-- the libabss.s `put` is inside a `dum` block by construction,
*-- and check-modules fails an `err` out here because it cannot
*-- tell a directive that reserves nothing from one that
*-- overlays liba's arena.
