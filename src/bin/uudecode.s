*---------------------------------------------------------------
* uudecode.s -- decode a uuencode(1) file, historical or
* base64, per XCU uudecode.html.
*
* Usage: uudecode [-o outfile] [file]
*
* Reads FILE (or fd 0), skips any text before the first "begin"
* or "begin-base64" line (tolerant of banner/mail-header noise
* ahead of it -- the same posture real uudecode takes), decodes
* to the pathname named in that header, or to -o's argument if
* given (outfile "/dev/stdout" writes to fd 1 -- POSIX-2024's
* own spelling, same precedent as sed's own "/dev/stdout" is fd
* 1" WFOPEN special-case, src/bin/sedout.s). Exits 1 with a
* diagnostic if no begin line is ever found, or if the body is
* short/malformed (verified live against this host's own
* /usr/bin/uudecode: removing either trailer line -- the
* zero-length backquote+"end" pair, or base64's own "===="  --
* makes it fail with "short file", not a silent partial decode;
* this file matches that: EOF before a trailer is malformed). A
* write that fails (FCLOSE's carry: the volume filled under the
* output) is "write error", exit 1 -- found 2026-09-14 when the
* textaudit's own volume ran out and uudecode exited 0 with a
* 512-byte file (tee.s/sort.s take the same posture).
*
* INPUT NORMALIZATION -- the one piece of design this pair's
* header comment insists on: a maux TEXT file is high-bit ASCII
* ($8D newline), but a uuencode(1) file arriving over `tip` is
* plain 7-bit ASCII (docs/SERIAL.md: tip's line->console child
* strips bit 7 before ever reaching a redirected fd). GETLINE
* below ANDs every byte with $7F before use, so the SAME decode
* path reads either convention -- a file this machine's own
* uuencode wrote (high-bit) or one that rode in over the serial
* line (plain) -- without a mode flag or a guess.
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
            dsk   ../../build/uudecode.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255               ;read chunk, see GETBYTE
LBMAX       equ   100               ;one line, see GETLINE
LBCAP       equ   99                ;LBMAX-1, room for the NUL
HNMAX       equ   65                ;header pathname, ProDOS cap
HNCAP       equ   64                ;HNMAX-1, room for the NUL
MODE_UU     equ   0
MODE_B64    equ   1
HSKIP_UU    equ   6                 ;strlen("begin ")
HSKIP_B64   equ   13                ;strlen("begin-base64 ")

START       stz   HAVEO
            lda   #<OPTLIST
            ldx   #>OPTLIST
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$EF               ;'o' high-bit
            beq   :oflag
            jmp   :usage
:oflag      lda   OPTARG
            sta   OUTARGP
            lda   OPTARG+1
            sta   OUTARGP+1
            lda   #1
            sta   HAVEO
            bra   :optlp
:optdone

            lda   ARGC
            sec
            sbc   OPTIND
            sta   NARGS
            lda   NARGS
            beq   :usestdin
            cmp   #1
            beq   :openfile
            jmp   :usage

:openfile   lda   OPTIND
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :opened
            jmp   :nosrc
:opened     lda   OPARM_REF
            sta   SRCFD
            lda   #1
            sta   SRCISF
            bra   :havesrc
:usestdin   lda   #FD_STDIN
            sta   SRCFD
            stz   SRCISF

:havesrc    stz   BUFPOS
            stz   BUFLEN

*---------------------------------------------------------------
* :findbeg -- skip lines until "begin " or "begin-base64 ",
* or EOF (a diagnostic, exit 1).
*---------------------------------------------------------------
:findbeg    jsr   GETLINE
            bcc   :gotline
            jmp   :nobegin
:gotline    lda   #<LINEBUF
            sta   PTR0
            lda   #>LINEBUF
            sta   PTR0+1
            lda   #<PFXB64
            sta   PTR1
            lda   #>PFXB64
            sta   PTR1+1
            jsr   PREFIXCMP
            bcc   :isb64
            lda   #<PFXUU
            sta   PTR1
            lda   #>PFXUU
            sta   PTR1+1
            jsr   PREFIXCMP
            bcc   :isuu
            bra   :findbeg
:isb64      lda   #MODE_B64
            sta   MODE
            lda   #HSKIP_B64
            jsr   PARSEHDR
            bra   :havehdr
:isuu       lda   #MODE_UU
            sta   MODE
            lda   #HSKIP_UU
            jsr   PARSEHDR

*---------------------------------------------------------------
* :havehdr -- open the destination: -o's argument (checking the
* "/dev/stdout" special case), else HDRNAME from the header.
*---------------------------------------------------------------
:havehdr    stz   HAVECRE
            lda   HAVEO
            beq   :usehdrn
            lda   OUTARGP
            sta   PTR0
            lda   OUTARGP+1
            sta   PTR0+1
            lda   #<DEVSTDOUT
            sta   PTR1
            lda   #>DEVSTDOUT
            sta   PTR1+1
            jsr   STRCMP
            cmp   #0
            bne   :ocreate
            lda   #FD_STDOUT
            sta   OUTFD
            bra   :havedst
:ocreate    lda   OUTARGP
            sta   PTR0
            lda   OUTARGP+1
            sta   PTR0+1
            bra   :docreat
:usehdrn    lda   #<HDRNAME
            sta   PTR0
            lda   #>HDRNAME
            sta   PTR0+1
:docreat    lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            jsr   CREAT
            bcc   :creok
            jmp   :nocreate
:creok      sta   OUTFD
            lda   #1
            sta   HAVECRE

*---------------------------------------------------------------
* :havedst -- decode the body, per MODE, then verify the
* trailer.
*---------------------------------------------------------------
:havedst    lda   MODE
            beq   :bodyuu
            jmp   :bodyb64

:bodyuu     jsr   GETLINE
            bcc   :uuhave
            jmp   :short
:uuhave     lda   LINELEN
            bne   :uulen
            jmp   :malform
:uulen      lda   LINEBUF
            jsr   DECODE6
            bcc   :uun
            jmp   :malform
:uun        cmp   #0
            beq   :uuterm
            cmp   #46
            bcs   :uubad
            jsr   DECLINEU
            bcc   :bodyuu
:uubad      jmp   :malform
:uuterm     jsr   GETLINE
            bcc   :uuendln
            jmp   :short
:uuendln    lda   #<LINEBUF
            sta   PTR0
            lda   #>LINEBUF
            sta   PTR0+1
            lda   #<TRLENDLO
            sta   PTR1
            lda   #>TRLENDLO
            sta   PTR1+1
            jsr   STRCMP
            cmp   #0
            beq   :done
            jmp   :malform

:bodyb64    jsr   GETLINE
            bcc   :b64have
            jmp   :short
:b64have    lda   LINELEN
            beq   :malform
            lda   LINEBUF
            cmp   #'='
            beq   :done
            jsr   DECLINEB
            bcc   :bodyb64
            jmp   :malform

:done       lda   HAVECRE
            beq   :closesrc
            lda   OUTFD
            cmp   #FD_STDOUT
            beq   :closesrc
            ldx   OUTFD
            jsr   FCLOSE
            bcc   :closesrc
            jmp   :wrerr             ;flush/close failed: the
                                     ;file is short -- say so,
                                     ;exit 1 (tee.s's posture)
:closesrc   lda   SRCISF
            beq   :ok0
            ldx   SRCFD
            stx   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
:ok0        lda   #0
            jsr   EXIT

:wrerr      lda   #<WRERRMSG
            sta   PTR0
            lda   #>WRERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:short      lda   #<SHORTMSG
            sta   PTR0
            lda   #>SHORTMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:malform    lda   #<MALFMSG
            sta   PTR0
            lda   #>MALFMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:nobegin    lda   #<NOBEGMSG
            sta   PTR0
            lda   #>NOBEGMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:nosrc      lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   OPTIND
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            jsr   EXIT

:nocreate   lda   #<CREMSG
            sta   PTR0
            lda   #>CREMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
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


            put   uudecdec.s
            put   uudecln.s
OPTLIST     asc   "o:"
            dfb   0
USAGEMSG    asc   "usage: uudecode [-o outfile] [file]"
            dfb   $8D,$00
ERRMSG      asc   "uudecode: cannot open "
            dfb   $00
CREMSG      asc   "uudecode: cannot create output file"
            dfb   $8D,$00
NOBEGMSG    asc   'uudecode: missing or bad "begin" line'
            dfb   $8D,$00
SHORTMSG    asc   "uudecode: short file"
            dfb   $8D,$00
WRERRMSG    asc   "uudecode: write error"
            dfb   $8D,$00
MALFMSG     asc   "uudecode: malformed body"
            dfb   $8D,$00
DEVSTDOUT   asc   "/dev/stdout"
            dfb   $00
PFXUU       asc   'begin '
            dfb   0
PFXB64      asc   'begin-base64 '
            dfb   0
TRLENDLO    asc   'end'
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
            put   ../liba/syscalls.s
            put   ../liba/creat.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* uudecode's own bss, `dum`/`dend` off LIBA_BSSEND. NOTHING
* ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - HAVEO: `stz`'d as START's first instruction.
*  - OUTARGP: written only on the -o path, before :havehdr's own
*    read of it (gated behind `lda HAVEO / beq`).
*  - NARGS/SRCFD/SRCISF: NARGS always written before its own
*    read; SRCFD/SRCISF on both the stdin and file-open paths,
*    before :havesrc reads either.
*  - BUFPOS/BUFLEN: `stz`'d once before the first GETLINE (this
*    tool never revisits a second source).
*  - LINELEN: GETLINE's own first store, every call.
*  - MODE/PH_I/HDRNAME: :isuu/:isb64 set MODE; PARSEHDR's own
*    first store of PH_I; HDRNAME is written up to PH_I's copy
*    loop and always NUL-terminated at the end of PARSEHDR.
*  - HAVECRE/OUTFD: `stz`'d at :havehdr; OUTFD written on both
*    branches before :havedst reads it.
*  - DU_REMAIN/DU_LOFS/DU_V0-3/DU_BYTE0-2/DU_CNT/DU_TMP: each
*    routine's own first store, never live across DECLINEU and
*    DECLINEB in the same run (MODE selects exactly one body).
*  - DB_OFS: DECLINEB's own `stz`, once per call.
*  - PATHBUF: MKPATH writes chars then the count byte; the MLI
*    reads only count+1.
*  - CBUF/LINEBUF: filled before any indexed read past what was
*    just written (REFILL/GETLINE's own contracts).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
HAVEO       ds    1
OUTARGP     ds    2
NARGS       ds    1
SRCFD       ds    1
SRCISF      ds    1
BUFPOS      ds    1
BUFLEN      ds    1
LINELEN     ds    1
MODE        ds    1
PH_I        ds    1
HAVECRE     ds    1
OUTFD       ds    1
DU_REMAIN   ds    1
DU_LOFS     ds    1
DU_V0       ds    1
DU_V1       ds    1
DU_V2       ds    1
DU_V3       ds    1
DU_BYTE0    ds    1
DU_BYTE1    ds    1
DU_BYTE2    ds    1
DU_CNT      ds    1
DU_TMP      ds    1
DB_OFS      ds    1
PATHBUF     ds    65
CBUF        ds    BUFSZ
LINEBUF     ds    LBMAX
HDRNAME     ds    HNMAX
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window.
            err   */$BF00
            dend
