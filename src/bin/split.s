*---------------------------------------------------------------
* split.s -- split a file into pieces.
*
* Usage: split [-l n | -b n[k|m]] [-a suffixlen] [file [name]]
*
* Default -l 1000 (1000 lines per piece). -b n/nk/nm splits by
* BYTES instead (k=1024, m=1048576); a piece boundary may fall
* mid-line -- bytes are copied verbatim, never line-aware. -a
* suffix_length (default 2) sets how many letters the generated
* suffix carries. `file` absent or "-" reads fd 0. `name` (only
* meaningful with `file` given) is the piece-name PREFIX,
* default "x".
*
* PIECE NAMES: prefix immediately followed by an ODOMETER of
* `suffixlen` lowercase-shaped letters -- "aa","ab",...,"az",
* "ba",... -- exactly like every host split. On THIS filesystem
* the bytes land as ProDOS names ("XAA","XAB",...): CREATE
* upper-cases everything it stores, so the odometer characters
* are written as high-bit 'a'-'z' text and read back later as
* 'A'-'Z' -- the same case-insensitive-storage fact every ProDOS
* name already has (a2til's own read path folds names the same
* way, which is what lets the test suite name a result tag in
* either case). PREFIX+SUFFIXLEN over 15 characters cannot be a
* ProDOS name at all -- refused up front with a diagnostic and
* exit 1, before any piece is written.
*
* ODOMETER, NOT DIVISION: incrementing the LAST letter and
* carrying into more significant ones on a 'z' wrap (like a
* spreadsheet column) needs no multiply/divide -- there is no
* divide instruction on this CPU. Suffix EXHAUSTION (more pieces
* needed than suffixlen letters can name) is detected the
* instant the odometer carries out of its most significant
* digit; the NEXT piece that would need it is refused with a
* diagnostic and exit 1 -- every piece already written stays.
*
* LAZY PIECE OPEN: a piece file is not created until there is a
* byte to put in it, so a source whose length divides evenly by
* the split unit never leaves a trailing empty piece -- matching
* every host split. An empty source still gets exactly one empty
* piece (EVEROPEN below), also matching every host split.
*
* WRITE FAILURE: PUTC full-buffers a real file fd (>=3, same
* fact tee.s's own header documents) and only flushes at 512B or
* at FCLOSE -- so every piece close goes through FCLOSE, NOT a
* bare SC_CLOSE, and FCLOSE's own carry is checked (a write
* error, e.g. a full volume, surfaces there and nowhere else).
*
* -b's 'm' SUFFIX is a KNOWN LIMITATION: 1,048,576 does not fit
* in 16 bits on this CPU -- a chunk size given in 'm' silently
* wraps modulo 65536 (SHL10 below, called twice). No test
* exercises 'm' for this reason; 'k' (times 1024) is exact for
* every size a v1 fixture can stage.
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
            dsk   ../../build/split.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255              ;source read chunk
DEFNUM      equ   1000              ;default -l count
DEFSUF      equ   2                 ;default -a suffix length
NAMECAP     equ   15                ;ProDOS name length cap

START       lda   #<SPLITOPTS
            ldx   #>SPLITOPTS
            jsr   OPTINIT
            stz   MODE
            lda   #<DEFNUM
            sta   NUMLO
            lda   #>DEFNUM
            sta   NUMHI
            lda   #DEFSUF
            sta   SUFLEN
:optlp      jsr   GETOPT
            bcc   :haveopt
            jmp   :optdone
:haveopt    cmp   #$EC                   ;'l'
            beq   :lopt
            cmp   #$E2                   ;'b'
            beq   :bopt
            cmp   #$E1                   ;'a'
            bne   :notopt
            jmp   :aopt
:notopt     jmp   USAGEEXIT
:lopt       lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSEDEC
            cpy   #0
            beq   :lbad
            lda   (PTR0),y               ;trailing junk -- no
            beq   :lok                   ;unit letter on -l
:lbad       jmp   USAGEEXIT
:lok        lda   ACCLO
            sta   NUMLO
            lda   ACCHI
            sta   NUMHI
            stz   MODE
            jmp   :optlp
:bopt       lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSEDEC
            cpy   #0
            bne   :bunit
            jmp   USAGEEXIT
:bunit      lda   (PTR0),y
            beq   :bnou                  ;plain byte count
            cmp   #$EB                   ;'k'
            beq   :bk
            cmp   #$CB                   ;'K'
            beq   :bk
            cmp   #$ED                   ;'m'
            beq   :bm
            cmp   #$CD                   ;'M'
            beq   :bm
            jmp   USAGEEXIT
:bk         iny
            lda   (PTR0),y
            beq   :bkok
            jmp   USAGEEXIT
:bkok       jsr   SHL10
            bra   :bnou
:bm         iny
            lda   (PTR0),y
            beq   :bmok
            jmp   USAGEEXIT
:bmok       jsr   SHL10                  ;KNOWN LIMIT -- see
            jsr   SHL10                  ;header, wraps mod 64K
:bnou       lda   ACCLO
            sta   NUMLO
            lda   ACCHI
            sta   NUMHI
            lda   #1
            sta   MODE
            jmp   :optlp
:aopt       lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSEDEC
            cpy   #0
            bne   :agot
            jmp   USAGEEXIT
:agot       lda   (PTR0),y
            beq   :aterm
            jmp   USAGEEXIT
:aterm      lda   ACCHI
            beq   :ahi                   ;suffix length > 255 --
            jmp   USAGEEXIT              ;refuse, never fits
:ahi        lda   ACCLO
            bne   :aset                  ;-a 0: no odometer
            jmp   USAGEEXIT
:aset       sta   SUFLEN
            jmp   :optlp
:optdone

*-- operands: 0, 1 (file) or 2 (file name) -- anything else is
*-- a usage error.
            lda   ARGC
            sec
            sbc   OPTIND
            cmp   #3
            bcc   :nargok
            jmp   USAGEEXIT
:nargok     sta   NARGS

*-- default prefix "x" -- overwritten below iff a NAME operand
*-- is given.
            lda   #"x"
            sta   PFXBUF
            stz   PFXBUF+1
            lda   #1
            sta   PFXLEN

            lda   NARGS
            beq   :nosrc                 ;0 operands: stdin
            lda   #FD_STDIN
            sta   SRCFD
            stz   ISFILE
            lda   OPTIND
            jsr   GETARG                 ;PTR0 = file operand
            jsr   STRLEN
            cmp   #1
            bne   :realfile
            ldy   #0                     ;peek the one byte
            lda   (PTR0),y
            cmp   #$AD                   ;'-' -- stdin, explicit
            beq   :nosrc
:realfile   lda   OPTIND
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :fok
            jmp   CANTOPENSRC
:fok        lda   OPARM_REF
            sta   SRCFD
            lda   #1
            sta   ISFILE

            lda   NARGS
            cmp   #2
            bne   :nosrc
            lda   OPTIND
            clc
            adc   #1
            jsr   GETARG                 ;PTR0 = NAME operand
            lda   #<PFXBUF
            sta   PTR1
            lda   #>PFXBUF
            sta   PTR1+1
            jsr   STRCPY
            lda   #<PFXBUF
            sta   PTR0
            lda   #>PFXBUF
            sta   PTR0+1
            jsr   STRLEN
            sta   PFXLEN
:nosrc

*-- name-length gate, BEFORE any file is written. The cap is a
*-- ProDOS FILENAME limit, not a whole-PATH one -- a NAME
*-- operand may be "/mnt/MAUX/O/x" (a real, ordinary usage) and
*-- only the "x" component plus the suffix must clear 15
*-- characters. Scan PFXBUF for the LAST '/' (high-bit $AF);
*-- BASENIDX is the index right after it, 0 if there is none.
            stz   BASENIDX
            ldx   #0
:bnlp       cpx   PFXLEN
            beq   :bndone
            lda   PFXBUF,x
            cmp   #$AF
            bne   :bnnext
            inx
            stx   BASENIDX
            dex
:bnnext     inx
            bra   :bnlp
:bndone     lda   PFXLEN
            sec
            sbc   BASENIDX
            clc
            adc   SUFLEN
            cmp   #NAMECAP+1
            bcc   :namok
            jmp   NAMETOOLONG
:namok

*-- odometer: SUFLEN letters, all 'a'.
            ldx   #0
:sufinit    cpx   SUFLEN
            beq   :sufdone
            lda   #"a"
            sta   SUFBUF,x
            inx
            bra   :sufinit
:sufdone

            stz   PIECEOPEN
            stz   EVEROPEN
            stz   EXHAUSTED
            stz   BUFPOS
            stz   BUFLEN
:cpylp      jsr   GETBYTE
            bcs   :srcdone
            sta   CURBYTE
            lda   PIECEOPEN
            bne   :havep
            jsr   OPENPIECE
:havep      ldx   CURFD
            lda   CURBYTE
            jsr   PUTC
            lda   MODE
            beq   :linechk
            bra   :dec
:linechk    lda   CURBYTE
            cmp   #$8D
            bne   :cpylp
:dec        lda   REMAINLO
            bne   :declo
            dec   REMAINHI
:declo      dec   REMAINLO
            lda   REMAINLO
            ora   REMAINHI
            bne   :cpylp
            jsr   CLOSEPIECE
            bra   :cpylp
:srcdone    lda   PIECEOPEN
            beq   :chkempty
            jsr   CLOSEPIECE
            bra   :closesrc
:chkempty   lda   EVEROPEN
            bne   :closesrc
            jsr   OPENPIECE
            jsr   CLOSEPIECE
:closesrc   lda   ISFILE
            beq   :done
            lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
:done       lda   #0
            jsr   EXIT

USAGEMSG    asc   "usage: split [-l n | -b n[k|m]] "
            asc   "[-a suffix_length] [file [name]]"
            dfb   $8D,$00
CANTOPENM   asc   "split: cannot open input file"
            dfb   $8D,$00
NAMELONGM   asc   "split: prefix+suffix exceeds 15 "
            asc   "characters"
            dfb   $8D,$00
SUFEXM      asc   "split: output file suffixes exhausted"
            dfb   $8D,$00
CREATFM     asc   "split: cannot create output file"
            dfb   $8D,$00
WRFAILM     asc   "split: write error"
            dfb   $8D,$00
SPLITOPTS   asc   "l:b:a:"
            dfb   0

OPARM       dfb   PCOUNT_OPEN
OPARM_PATH  da    PATHBUF
OPARM_IOBUF da    $0000
OPARM_REF   dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    CBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/creat.s
            put   ../liba/syscalls.s
            put   splitpc.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* split's own scalars, `dum`/`dend` off LIBA_BSSEND -- no `ds`
* zeros needed (docs/STICKY.md sec 21): every cell below is
* write-before-read.
*  - MODE/NUMLO/NUMHI/SUFLEN: START's own defaults, before the
*    option loop that may override them.
*  - NARGS: the ARGC-OPTIND subtract, before its own first read.
*  - PFXBUF/PFXLEN: the default-"x" store, before either the
*    NAME-operand overwrite or the length-cap check reads them.
*  - BASENIDX: `stz`'d right before the scan loop that is its
*    only reader (the length-cap check right after it).
*  - SRCFD/ISFILE: written on every path (stdin or opened file)
*    before GETBYTE or the closing check reads them.
*  - SUFBUF: :sufinit's own loop, SUFLEN bytes, before OPENPIECE
*    ever reads it.
*  - PIECEOPEN/EVEROPEN/EXHAUSTED: `stz`'d right before the copy
*    loop that is their only reader/writer.
*  - BUFPOS/BUFLEN: `stz`'d before the first GETBYTE call.
*  - CURBYTE: written by the copy loop right after GETBYTE,
*    before either PUTC or the CR test reads it.
*  - REMAINLO/HI: OPENPIECE's own stores, every piece.
*  - CURFD: OPENPIECE's own store, before PUTC/CLOSEPIECE read
*    it.
*  - ACCLO/ACCHI/AC_DIGIT/AC_TWOLO/AC_TWOHI: PARSEDEC/ACCUM10's
*    own stores, each before its own read.
*  - PATHBUF: MKPATH writes chars then the count byte.
*  - PNAMEBUF: OPENPIECE's own two copy loops, then the NUL,
*    all before MKPATH reads it.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
MODE        ds    1
NUMLO       ds    1
NUMHI       ds    1
SUFLEN      ds    1
NARGS       ds    1
PFXLEN      ds    1
BASENIDX    ds    1
SRCFD       ds    1
ISFILE      ds    1
PIECEOPEN   ds    1
EVEROPEN    ds    1
EXHAUSTED   ds    1
BUFPOS      ds    1
BUFLEN      ds    1
CURBYTE     ds    1
REMAINLO    ds    1
REMAINHI    ds    1
CURFD       ds    1
ACCLO       ds    1
ACCHI       ds    1
AC_DIGIT    ds    1
AC_TWOLO    ds    1
AC_TWOHI    ds    1

PFXBUF      ds    64
SUFBUF      ds    16
PNAMEBUF    ds    82
PATHBUF     ds    65
CBUF        ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window (see src/bin/ed.s
* -- for the full note).
            err   */$BF00
            dend
