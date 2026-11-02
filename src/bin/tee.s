*---------------------------------------------------------------
* tee.s -- copy fd 0 to fd 1 AND to each named file.
*
* Usage: tee [-ai] file...
*
* -i (SHIPPED 2026-09-17): ignore SIGINT, same posture as
* nohup.s's own SIGHUP ignore -- SC_SIGNAL(2, SIGA_IGN) is a
* REAL syscall that succeeds, best-effort (carry not checked,
* never fatal), even though nothing in this harness raises ^C
* against a spawned pipeline stage today. Signal 2 is INT in
* shtrap.s's own V7 numbering, same table kill.s's -s/-l now
* share.
*
* CONTRACT: every byte read from stdin is written to stdout
* (fd 1) and to every named FILE, in argv order. `-a` appends to
* an existing destination instead of truncating it (default:
* CREATE, ignoring "already exists" -- uniq.s's own documented
* v1 gap: no MLI truncate primitive, so an existing LONGER file
* is not shortened). At least one FILE is required (the usage
* line has no brackets around it).
*
* FILE CAP: 5. inc/mm.annex.equ's PCB_FDTABLE is the
* REAL hard limit -- "8 fds/process (HARD LIMIT)", 8 bytes,
* verified by reading that file, not guessed. fd 0/1/2 are
* always stdin/stdout/stderr (sc.fd.equ), so 5 slots (fds
* 3-7) remain for tee's own destinations. More than 5 named
* files is a loud usage error (exit 2), never a silent drop of
* the extras.
*
* OPEN FAILURE is a per-file diagnostic, not a fatal one: "tee:
* cannot open <path>" to fd 2, that ONE destination is skipped
* for the rest of the run, EXITSTAT becomes 1, and the copy to
* stdout and every OTHER named file continues -- that is the
* entire point of tee (a file with a bad path must not silence
* the pipeline).
*
* WRITE FAILURE, 2026-08-24, same posture as open failure: "tee:
* cannot write <path>" to fd 2, EXITSTAT 1, other destinations
* and stdout unaffected. It is detected at FCLOSE, which is now
* where stdio.s delivers a stream's recorded write error
* (stdio.s's THE ERROR PATH). That timing is visible and is
* correct: a named file is fd>=3, so it is FULL-buffered, so a
* short payload's write does not even happen until the flush
* inside FCLOSE -- the diagnostic therefore lands AFTER the copy
* to stdout, not before it. A locked target is the case that
* found this (check-writefail): ProDOS OPENs it happily, because
* the access byte still permits reads, and fails the WRITE.
*
* CLOSE: every named file goes through FCLOSE (src/liba/
* stdio.s), NOT a bare SC_CLOSE. PUTC full-buffers a real file
* fd (>=3) and only auto-flushes at 512B or at EXIT; FCLOSE
* flushes THEN closes, in one call. A bare SC_CLOSE on a file
* written through PUTC silently drops whatever is still sitting
* in that fd's buffer -- uniq.s discovered this the hard way
* (its own header/commit), and tee, writing to up to 5 files at
* once, is exactly the shape that bug bites hardest.
*
* -a's append seek: CREATE (ignore "already exists" -- append
* must NOT destroy existing content) + OPEN, then
* lseek(fd, 0, SEEK_END) via src/liba/seek.s's LSEEK -- the
* exact package sh.s's own OPEN_REDIR_AP uses for `>>`
* (docs/FLEET.md "`>>` and the seek family").
*
* Byte-oriented (not line-oriented): tee has no reason to know
* where lines are, and a byte copy is binary-safe. Reads stdin
* in BUFSZ chunks (GETBYTE/REFILL, same shape as wc.s/uniq.s);
* each byte is PUTC'd to fd 1, then to every still-open named
* fd. fd 1 is fd<3 so stdio.s line-buffers it (flush on CR) --
* the mechanism that keeps a real pipeline (`X | TEE F | Y`)
* flowing without waiting for tee's own EXIT.
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
            dsk   ../../build/tee.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255              ;stdin read chunk
FILEMAX     equ   5                ;named-file cap -- see header

START       stz   WANT_A
            lda   #<TEEOPTS
            ldx   #>TEEOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$E1                   ;'a' high-bit-set
            beq   :aflag
            cmp   #$E9                   ;'i' high-bit-set
            beq   :iflag
            jmp   :usage
:aflag      sta   WANT_A
            bra   :optlp
:iflag      lda   #2                     ;INT, shtrap.s's V7
            ldx   #SIGA_IGN              ;numbering
            jsr   SC_SIGNAL
            bra   :optlp
:optdone
            lda   ARGC
            sec
            sbc   OPTIND
            sta   NFILES
            bne   :havefls               ;at least one FILE
            jmp   :usage
:havefls    cmp   #FILEMAX+1
            bcc   :capok
            jmp   :toomany
:capok

            stz   EXITSTAT
            stz   FIDX
:openlp     lda   FIDX
            cmp   NFILES
            bne   :moreopen
            jmp   :opendone          ;jmp: the CREAT adoption
                                     ;pushed it out of range
:moreopen   lda   OPTIND
            clc
            adc   FIDX
            sta   ARGIDX
            jsr   GETARG                 ;-> PTR0 = path
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   WANT_A                 ;-a appends -- the old
            bne   :apopen                ;CREATE+OPEN path: it
                                         ;must NOT truncate
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   CREAT                  ;liba creat(2): create-
                                         ;or-TRUNCATE. Host tee
                                         ;truncates; the old
                                         ;CREATE+OPEN left TAIL
                                         ;GARBAGE when the named
                                         ;file already existed
                                         ;longer -- a latent bug
                                         ;no gate reached until
                                         ;e2e's tee-trunc case
                                         ;(2026-08-29)
            bcs   :opnerr
            sta   OPARM_REF              ;fd -- the same cell
            bra   :openok                ;the open path fills
:apopen     lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT                ;ignore dup-name error
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :openok
:opnerr     jsr   TEE_OPNERR
            ldx   FIDX
            stz   FILEOPEN,x
            lda   #1
            sta   EXITSTAT
            bra   :nextfile
:openok     lda   OPARM_REF
            ldx   FIDX
            sta   FILEFD,x
            lda   #1
            sta   FILEOPEN,x
            lda   WANT_A
            beq   :nextfile
            stz   SEEKOFF
            stz   SEEKOFF+1
            stz   SEEKOFF+2
            lda   #<SEEKOFF
            sta   PTR0
            lda   #>SEEKOFF
            sta   PTR0+1
            ldx   FIDX
            lda   FILEFD,x
            ldy   #SEEK_END
            jsr   LSEEK                  ;seek err -- v1 leaves
                                         ;the write at offset 0
                                         ;(swallowed, like other
                                         ;write errors here)
:nextfile   inc   FIDX
            jmp   :openlp            ;jmp: range, see :opendone
:opendone

            stz   BUFPOS
            stz   BUFLEN
:cpylp      jsr   GETBYTE
            bcs   :cpydone
            sta   CURBYTE
            lda   CURBYTE
            ldx   #FD_STDOUT
            jsr   PUTC
            stz   FIDX
:wrlp       lda   FIDX
            cmp   NFILES
            beq   :wrdone
            ldx   FIDX
            lda   FILEOPEN,x
            beq   :skipwr
            ldx   FIDX
            lda   FILEFD,x
            tax
            lda   CURBYTE
            jsr   PUTC
:skipwr     inc   FIDX
            bra   :wrlp
:wrdone     bra   :cpylp
:cpydone

            stz   FIDX
:clslp      lda   FIDX
            cmp   NFILES
            beq   :clsdone
            ldx   FIDX
            lda   FILEOPEN,x
            beq   :clsskip
            ldx   FIDX
            lda   FILEFD,x
            tax
            jsr   FCLOSE                 ;flush+close -- see
                                         ;header. NOT SC_CLOSE.
            bcc   :clsskip               ;carry = the flush (or
                                         ;the close) failed
            lda   OPTIND                 ;name the file: FCLOSE
            clc                          ;clobbered nothing we
            adc   FIDX                   ;kept, but ARGIDX is
            sta   ARGIDX                 ;stale from the OPENs
            lda   #<CANTWRIT
            sta   PTR0
            lda   #>CANTWRIT
            sta   PTR0+1
            jsr   TEE_DIAG
            lda   #1
            sta   EXITSTAT
:clsskip    inc   FIDX
            bra   :clslp
:clsdone    lda   EXITSTAT
            jsr   EXIT

:usage      lda   #<USAGE
            sta   PTR0
            lda   #>USAGE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

:toomany    lda   #<TOOMANY
            sta   PTR0
            lda   #>TOOMANY
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* TEE_OPNERR -- "tee: cannot open <argv[ARGIDX]>" to fd 2. Does
* NOT exit -- caller marks the slot closed and keeps going (see
* header's "open failure is a per-file diagnostic").
*---------------------------------------------------------------
TEE_OPNERR  lda   #<CANTOPEN
            sta   PTR0
            lda   #>CANTOPEN
            sta   PTR0+1
*-- falls into TEE_DIAG

*---------------------------------------------------------------
* TEE_DIAG -- "<PTR0><argv[ARGIDX]>" + CR to fd 2. The two
* per-file diagnostics differ only in their first string, so
* they share the tail: PUTS clobbers PTR0, which is why the
* operand is re-fetched with GETARG rather than kept.
*---------------------------------------------------------------
TEE_DIAG    ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG                 ;PUTS clobbered PTR0
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered stdin (fd 0), same shape as
* wc.s/uniq.s's own.
*---------------------------------------------------------------
GETBYTE     ldx   BUFPOS
            cpx   BUFLEN
            bcc   :have
            jsr   REFILL
            bcs   :eof
            ldx   BUFPOS
:have       lda   CBUF,x
            inc   BUFPOS
            clc
            rts
:eof        sec
            rts

REFILL      lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :eof
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :eof
            lda   RPARM_TRANS
            sta   BUFLEN
            stz   BUFPOS
            clc
            rts
:eof        sec
            rts

USAGE       asc   "usage: tee [-ai] file..."
            dfb   $8D,$00
TOOMANY     asc   "tee: too many files (max 5)"
            dfb   $8D,$00
CANTOPEN    asc   "tee: cannot open "
            dfb   $00
CANTWRIT    asc   "tee: cannot write "
            dfb   $00
TEEOPTS     asc   "ai"
            dfb   0

* CREATE parmlist, reused per file (PATHBUF is repatched by
* MKPATH before every SC_CREAT/SC_OPEN pair). FTYPE_TXT/
* ACCESS_UNLKD/STYP_SEEDLING -- same DRAFT-VALUEs uniq.s's own
* CRPARM uses.
CRPARM        dfb   PCOUNT_CREATE
CRPARM_PATH   da    PATHBUF
CRPARM_ACCESS dfb   ACCESS_UNLKD
CRPARM_TYPE   dfb   FTYPE_TXT
CRPARM_AUX    da    0
CRPARM_STORE  dfb   STYP_SEEDLING
CRPARM_CDATE  da    0            ;no clock wired
CRPARM_CTIME  da    0

OPARM       dfb   OPEN_APPEND
OPARM_PATH  da    PATHBUF
OPARM_IOBUF da    $0000          ;kernel-owned (main memory)
OPARM_REF   dfb   0              ; result: fd

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   FD_STDIN       ;constant -- tee always reads
                                 ;stdin
RPARM_BUF   da    CBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/seek.s
            put   ../liba/creat.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* tee's own scratch, `dum`/`dend`'d at the textual end of the
* file (never `ds` -- real zero bytes, 39.07 cyc/byte spawn
* cost). Must stay textually LAST (`dum`'s addresses are
* relative to the real PC where it opens).
*
* `dum` memory is NOT zeroed -- read-before-write trace:
*  - WANT_A/EXITSTAT/FIDX: written by START before any read.
*  - NFILES: written by the ARGC-OPTIND subtract before its own
*    first read (the `beq :usage` right after).
*  - ARGIDX: written every open-loop iteration before GETARG
*    reads it, both for the path AND (TEE_OPNERR) the error
*    message re-fetch. The CLOSE loop recomputes it the same way
*    before its own diagnostic -- the open loop left it pointing
*    at the LAST file, not at this one.
*  - FILEFD/FILEOPEN: each slot [0,NFILES) is written exactly
*    once by the open loop before the copy/close loops (which
*    only ever index [0,NFILES)) read it back.
*  - CURBYTE: written by the copy loop immediately after
*    GETBYTE, before either PUTC reads it.
*  - SEEKOFF: zeroed immediately before every LSEEK call that
*    reads it (only reached when WANT_A is set).
*  - BUFPOS/BUFLEN: explicitly zeroed by START before the first
*    GETBYTE call -- GETBYTE's own `cpx BUFLEN` would otherwise
*    compare against garbage and could read uninitialized CBUF
*    bytes (the exact bug class this arena's own doc warns
*    about).
*  - PATHBUF: written whole by MKPATH (count-prefixed, not
*    NUL-scanned) before CREATE/OPEN read it, every iteration.
*  - CBUF: written by REFILL's SC_READ before GETBYTE reads it;
*    BUFPOS/BUFLEN bound every read to bytes REFILL actually
*    wrote this call.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
WANT_A      ds    1
NFILES      ds    1
FIDX        ds    1
EXITSTAT    ds    1
ARGIDX      ds    1
CURBYTE     ds    1
SEEKOFF     ds    3
BUFPOS      ds    1
BUFLEN      ds    1

FILEFD      ds    FILEMAX
FILEOPEN    ds    FILEMAX

PATHBUF     ds    65
CBUF        ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's
* -- end; $BF00 is the top of the process window. The
* -- division is 0 while it fits, 1 when it does not, and
* -- `err` fails the assembly. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
* -- See src/bin/ed.s for the full note.
            err   */$BF00
            dend
