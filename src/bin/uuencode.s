*---------------------------------------------------------------
* uuencode.s -- encode a file into printable ASCII (XCU
* uuencode.html), historical or -m base64.
*
* Usage: uuencode [-m] [file] decode_pathname
*
* One operand: read fd 0 (stdin), decode_pathname is that
* operand. Two operands: open the first as the source, the
* second is decode_pathname (the name embedded in the header,
* never opened -- pure text, same posture as basename.s's own
* string). MODE is always the literal "644": this machine has
* no permission bits to report (docs/man/uuencode.1 BUGS).
*
* Verified live against this host's own /usr/bin/uuencode/-m
* before writing this file: header, chunking, backquote-for-
* zero, both trailers, "=" padding, all measured against real
* output first -- see docs/man/uuencode.1.
*
* ALGORITHM (both share one 3-byte-to-4-character split,
* SPLIT3): a 6-bit group's PRINTABLE character is (group + 32),
* EXCEPT a zero group prints as a backquote (96) instead of a
* space -- the historical anti-mail-mangling convention (XCU
* text states it explicitly; SPLIT3AND ENCODE6 below implement
* it). Historical lines carry 45 source bytes (60 encoded
* characters) behind a length character; base64 lines carry 57
* source bytes (76 characters, RFC 4648 alphabet, standard "="
* padding on the FINAL group only).
*
* TEXT CONVENTION: the wire format is 7-bit ASCII (that is what
* real uuencode/uudecode everywhere expect), but a maux TEXT
* FILE is high-bit ASCII with CR ($8D) line ends, same as every
* other tool in this tree (echo, cat, ...). This file emits
* high-bit throughout -- header, body characters (ENC_BASE/
* ENC_ZERO/B64TAB already carry the high bit), CR -- and relies
* on docs/SERIAL.md's own documented behavior: `tip` strips bit
* 7 on the way OUT to the line, so `uuencode FILE NAME | tip`
* reaches the host as plain 7-bit ASCII automatically. uudecode
* (this pair's other half) accepts EITHER convention on input by
* normalizing every byte to 7 bits before use.
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
            dsk   ../../build/uuencode.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255               ;read chunk, see GETBYTE
CHUNK_UU    equ   45                ;historical bytes/line
CHUNK_B64   equ   57                ;base64 bytes/line
ENC_BASE    equ   $A0               ;32+$80: nonzero -> char
ENC_ZERO    equ   $E0               ;96+$80: zero group -> `
EQCHAR      equ   $BD               ;'=' high-bit, base64 pad

START       stz   ENC_MFLG
            lda   #<OPTLIST
            ldx   #>OPTLIST
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$ED               ;'m' high-bit
            beq   :mflag
            jmp   :usage             ;'?' or anything else
:mflag      lda   #1
            sta   ENC_MFLG
            bra   :optlp
:optdone

            lda   ARGC
            sec
            sbc   OPTIND
            sta   NARGS
            lda   NARGS
            cmp   #1
            beq   :onearg
            lda   NARGS
            cmp   #2
            beq   :twoarg
            jmp   :usage

:onearg     lda   #FD_STDIN
            sta   SRCFD
            lda   OPTIND
            sta   DECIDX
            bra   :havesrc

:twoarg     lda   OPTIND
            sta   FILEIDX
            clc
            adc   #1
            sta   DECIDX
            lda   FILEIDX
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
            jmp   :openerr
:opened     lda   OPARM_REF
            sta   SRCFD

:havesrc    lda   ENC_MFLG
            beq   :szuu
            lda   #CHUNK_B64
            sta   CHUNKSZ
            bra   :hdr
:szuu       lda   #CHUNK_UU
            sta   CHUNKSZ

:hdr        lda   ENC_MFLG
            beq   :hduu
            lda   #<HDRB64
            sta   PTR0
            lda   #>HDRB64
            sta   PTR0+1
            bra   :hdput
:hduu       lda   #<HDRUU
            sta   PTR0
            lda   #>HDRUU
            sta   PTR0+1
:hdput      jsr   POUT
            lda   #<MODESTR
            sta   PTR0
            lda   #>MODESTR
            sta   PTR0+1
            jsr   POUT
            lda   DECIDX
            jsr   GETARG
            jsr   POUT
            jsr   PUTCR

            stz   BUFPOS
            stz   BUFLEN

*---------------------------------------------------------------
* :mloop -- one chunk (line) at a time until the source is
* exhausted, then the trailer.
*---------------------------------------------------------------
:mloop      lda   CHUNKSZ
            jsr   READCHNK
            sta   LN_CNT
            lda   LN_CNT
            beq   :trailer
            lda   ENC_MFLG
            beq   :dohist
            lda   LN_CNT
            jsr   ENCLINEB
            bra   :aftline
:dohist     lda   LN_CNT
            jsr   ENCODE6            ;length char -- ENCLINEU
            ldx   #FD_STDOUT         ;itself never emits one
            jsr   PUTC
            lda   LN_CNT
            jsr   ENCLINEU
:aftline    jsr   PUTCR
            bra   :mloop

:trailer    lda   ENC_MFLG
            bne   :b64trl
            lda   #0
            jsr   ENCODE6
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   PUTCR
            lda   #<TRLEND
            sta   PTR0
            lda   #>TRLEND
            sta   PTR0+1
            jsr   POUT
            jsr   PUTCR
            bra   :alldone
:b64trl     lda   #<TRLB64
            sta   PTR0
            lda   #>TRLB64
            sta   PTR0+1
            jsr   POUT
            jsr   PUTCR

:alldone    lda   #0
            jsr   EXIT

:openerr    lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   FILEIDX
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
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

*---------------------------------------------------------------
* POUT/PUTCR -- PTR0 to stdout / a bare CR to stdout. Shared by
* every header/trailer/body site below; CLOBBERS A, X, Y.
*---------------------------------------------------------------
POUT        ldx   #FD_STDOUT
            jsr   PUTS
            rts

PUTCR       lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* ENCODE6 -- IN: A = a 6-bit group (0-63). OUT: A = the
* high-bit-set printable character (32+A, or a backquote for
* A==0). CLOBBERS: A.
*---------------------------------------------------------------
ENCODE6     cmp   #0
            bne   :e6nz
            lda   #ENC_ZERO
            rts
:e6nz       clc
            adc   #ENC_BASE
            rts

*---------------------------------------------------------------
* SPLIT3 -- IN: X = offset of 3 source bytes in ENCBUF. OUT:
* SP_V0..SP_V3 = the four 6-bit groups. CLOBBERS: A, X (restored
* to entry value), SP_B0-2/SP_V0-3.
*---------------------------------------------------------------
SPLIT3      lda   ENCBUF,x
            sta   SP_B0
            inx
            lda   ENCBUF,x
            sta   SP_B1
            inx
            lda   ENCBUF,x
            sta   SP_B2
            dex
            dex
            lda   SP_B0
            lsr   a
            lsr   a
            sta   SP_V0
            lda   SP_B0
            and   #3
            asl   a
            asl   a
            asl   a
            asl   a
            sta   SP_V1
            lda   SP_B1
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            ora   SP_V1
            sta   SP_V1
            lda   SP_B1
            and   #$0F
            asl   a
            asl   a
            sta   SP_V2
            lda   SP_B2
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            ora   SP_V2
            sta   SP_V2
            lda   SP_B2
            and   #$3F
            sta   SP_V3
            rts

*---------------------------------------------------------------
* ENCLINEU -- historical body: IN A = n (1-45, real byte count
* for this line). Emits ceil(n/3) groups of 4 characters, ALL
* real (zero-padded source bytes beyond n encode as backquotes,
* matching real uuencode -- decoders keep only the leading n
* decoded bytes via their own length character). CLOBBERS: A,
* X, Y, EU_REMAIN, EU_OFS, SP_*.
*---------------------------------------------------------------
ENCLINEU    sta   EU_REMAIN
            stz   EU_OFS
:eloop      ldx   EU_OFS
            jsr   SPLIT3
            lda   SP_V0
            jsr   ENCODE6
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   SP_V1
            jsr   ENCODE6
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   SP_V2
            jsr   ENCODE6
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   SP_V3
            jsr   ENCODE6
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   EU_OFS
            clc
            adc   #3
            sta   EU_OFS
            lda   EU_REMAIN
            cmp   #4
            bcc   :eudone
            sec
            sbc   #3
            sta   EU_REMAIN
            bra   :eloop
:eudone     rts


            put   uuencln.s

OPTLIST     asc   "m"
            dfb   0
USAGEMSG    asc   "usage: uuencode [-m] [file] decode_pathname"
            dfb   $8D,$00
ERRMSG      asc   "uuencode: cannot open "
            dfb   $00
HDRUU       asc   "begin "
            dfb   $00
HDRB64      asc   "begin-base64 "
            dfb   $00
MODESTR     asc   "644 "
            dfb   $00
TRLEND      asc   "end"
            dfb   $00
TRLB64      asc   "===="
            dfb   $00
B64TAB      asc   "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            asc   "abcdefghijklmnopqrstuvwxyz"
            asc   "0123456789+/"

OPARM       dfb   PCOUNT_OPEN
OPARM_PATH  da    PATHBUF
OPARM_IOBUF da    $0000
OPARM_REF   dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
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
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* uuencode's own bss, `dum`/`dend` off LIBA_BSSEND. NOTHING
* ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - ENC_MFLG: `stz`'d as START's first instruction.
*  - NARGS/FILEIDX/DECIDX/SRCFD/CHUNKSZ: each written on the
*    single path that leads to its own first read (:onearg/
*    :twoarg set FILEIDX/DECIDX/SRCFD before :havesrc reads any
*    of them; CHUNKSZ before :hdr).
*  - BUFPOS/BUFLEN: `stz`'d once before the main loop, same
*    per-run posture as sum.s (this tool never revisits a
*    second file).
*  - RC_TARGET/RC_IDX/RC_COUNT: READCHNK's own first stores.
*  - SP_B0-2/SP_V0-3: SPLIT3's own first stores.
*  - EU_REMAIN/EU_OFS, EB_REMAIN/EB_OFS: ENCLINEU/ENCLINEB's own
*    first stores (never both live at once -- ENC_MFLG selects
*    exactly one body routine per run).
*  - LN_CNT: :mloop's own store before either branch reads it.
*  - PATHBUF: MKPATH writes chars then the count byte; the MLI
*    reads only count+1. Untouched on the stdin (:onearg) path.
*  - CBUF/ENCBUF: filled before any indexed read past what was
*    just written (REFILL/READCHNK's own contracts).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ENC_MFLG    ds    1
NARGS       ds    1
FILEIDX     ds    1
DECIDX      ds    1
SRCFD       ds    1
CHUNKSZ     ds    1
BUFPOS      ds    1
BUFLEN      ds    1
RC_TARGET   ds    1
RC_IDX      ds    1
RC_COUNT    ds    1
SP_B0       ds    1
SP_B1       ds    1
SP_B2       ds    1
SP_V0       ds    1
SP_V1       ds    1
SP_V2       ds    1
SP_V3       ds    1
EU_REMAIN   ds    1
EU_OFS      ds    1
EB_REMAIN   ds    1
EB_OFS      ds    1
LN_CNT      ds    1
PATHBUF     ds    65
CBUF        ds    BUFSZ
ENCBUF      ds    57
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window.
            err   */$BF00
            dend
