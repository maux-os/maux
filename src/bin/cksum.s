*---------------------------------------------------------------
* cksum.s -- POSIX cksum(1): CRC checksum and byte count.
*
* Usage: cksum [file...]
*
* Prints "CRC OCTETS NAME" per named operand to stdout; no NAME
* column for the implicit stdin read when no operand is given
* (same NAMEFLG shape as sum.s). A file that cannot be opened
* prints "cksum: cannot open NAME" to stderr and is SKIPPED, not
* fatal to the rest; overall exit status is 1 if any operand
* failed to open, 0 otherwise.
*
* ALGORITHM -- the POSIX cksum CRC, NOT zlib/CRC-32 (reflected,
* init $FFFFFFFF, no length fold). This one: init 0, MSB-first
* (bit 31 tested before each shift), polynomial $04C11DB7, one
* extra pass over the file's own OCTET COUNT (low byte first,
* shifting the count right 8 bits each round, stopping the
* instant the remaining count is zero -- an empty file therefore
* folds NO length bytes at all), then the whole 32-bit register
* is COMPLEMENTED. Verified against this Mac's /usr/bin/cksum
* (BSD) before writing a byte, both this bitwise formulation
* and a from-scratch Python model of it:
*   printf ''          | cksum  -> 4294967295 0
*   printf 'a'          | cksum  -> 1220704766 1
*   printf 'abc'        | cksum  -> 1219131554 3
*   printf '123456789'  | cksum  -> 930766865 9
*   768-byte fixture (bytes(range(256))*3) -> 794916923 768
* All five match this file's implementation bit for bit.
*
* TABLE-LESS BY MEASUREMENT: a 256-entry x 4-byte CRC table
* would be 1024 bytes on its own, roughly half again this
* tool's whole budget, for a tool that never runs on more than
* one file's worth of bytes at a time and is not on any hot
* path. The bitwise form (8 shift/conditional-xor rounds per
* byte, FEEDBYTE below) costs a few dozen bytes of code instead
* and is what shipped.
*
* 32-BIT DECIMAL PRINTING: liba's PRNUM/U2DEC (src/liba/num.s)
* are 16-bit only, and a 32-bit CRC or a large octet count both
* need more than that. CK32DEC below is the same "repeated
* subtraction of the powers of ten" shape as U2DEC, widened to
* four bytes per value and using a trial-subtract-then-commit
* (discard on borrow) step instead of a separate compare, since
* a real 32-bit compare would cost its own multi-byte routine
* for no benefit here. Kept local to this tool, not liba -- liba
* bytes are volume bytes in ~40 gate images, and no other util
* needs a 32-bit printer yet.
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
            dsk   ../../build/cksum.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255

* -- CRC-32/CKSUM polynomial $04C11DB7, one byte per equate --
* -- no 32-bit literals in Merlin exprs, and no parens either.
POLYB0      equ   $B7
POLYB1      equ   $1D
POLYB2      equ   $C1
POLYB3      equ   $04

START       stz   ERRFLAG
            lda   ARGC
            cmp   #1
            bne   :havefile
            ; ARGC==1: only argv[0] -- no FILE args, same
            ; convention as sum.s/cat.s.
            lda   #FD_STDIN
            sta   SRCFD
            jsr   CKSUMFD
            stz   NAMEFLG
            jsr   REPORT
            lda   #0
            jsr   EXIT

:havefile   lda   #1
            sta   ARGIDX
:looparg    lda   ARGIDX
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :openerr
            lda   OPARM_REF
            sta   SRCFD
            jsr   CKSUMFD
            ldx   SRCFD
            stx   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            lda   #1
            sta   NAMEFLG
            jsr   REPORT
            bra   :nextarg

:openerr    lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG

:nextarg    inc   ARGIDX
            lda   ARGIDX
            cmp   ARGC
            bcc   :looparg
            lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* CKSUMFD -- CRC/count SRCFD into CRC0-3/BYTES0-3, then fold the
* octet count in and complement, leaving the FINAL printable
* value in CRC0-3.
*---------------------------------------------------------------
CKSUMFD     stz   CRC0
            stz   CRC1
            stz   CRC2
            stz   CRC3
            stz   BYTES0
            stz   BYTES1
            stz   BYTES2
            stz   BYTES3
            stz   BUFPOS
            stz   BUFLEN
:loop       jsr   GETBYTE
            bcs   :eof
            jsr   FEEDBYTE
            inc   BYTES0
            bne   :loop
            inc   BYTES1
            bne   :loop
            inc   BYTES2
            bne   :loop
            inc   BYTES3
            bra   :loop
:eof        lda   BYTES0
            sta   LEN0
            lda   BYTES1
            sta   LEN1
            lda   BYTES2
            sta   LEN2
            lda   BYTES3
            sta   LEN3
:lenloop    lda   LEN0
            ora   LEN1
            ora   LEN2
            ora   LEN3
            beq   :lendone
            lda   LEN0
            jsr   FEEDBYTE
            lda   LEN1
            sta   LEN0
            lda   LEN2
            sta   LEN1
            lda   LEN3
            sta   LEN2
            stz   LEN3
            bra   :lenloop
:lendone    lda   CRC0
            eor   #$FF
            sta   CRC0
            lda   CRC1
            eor   #$FF
            sta   CRC1
            lda   CRC2
            eor   #$FF
            sta   CRC2
            lda   CRC3
            eor   #$FF
            sta   CRC3
            rts

*---------------------------------------------------------------
* FEEDBYTE -- fold byte A into CRC0-3, MSB-first, poly
* $04C11DB7. CRC ^= (A << 24); 8x { shift CRC left 1 (32-bit);
* if the bit shifted out of bit 31 was 1, CRC ^= POLY }.
* CLOBBERS: A, X.
*---------------------------------------------------------------
FEEDBYTE    eor   CRC3
            sta   CRC3
            ldx   #8
:bitloop    asl   CRC0
            rol   CRC1
            rol   CRC2
            rol   CRC3
            bcc   :noxor
            lda   CRC0
            eor   #POLYB0
            sta   CRC0
            lda   CRC1
            eor   #POLYB1
            sta   CRC1
            lda   CRC2
            eor   #POLYB2
            sta   CRC2
            lda   CRC3
            eor   #POLYB3
            sta   CRC3
:noxor      dex
            bne   :bitloop
            rts

*---------------------------------------------------------------
* REPORT -- print "CRC OCTETS[ NAME]", CR-terminated. Neither
* number is zero-padded (measured, BSD cksum) -- CK32DEC already
* suppresses leading zeros the same way liba's U2DEC does.
*---------------------------------------------------------------
REPORT      lda   CRC0
            sta   PR32V0
            lda   CRC1
            sta   PR32V1
            lda   CRC2
            sta   PR32V2
            lda   CRC3
            sta   PR32V3
            ldx   #FD_STDOUT
            jsr   PR32
            jsr   PRSPACE
            lda   BYTES0
            sta   PR32V0
            lda   BYTES1
            sta   PR32V1
            lda   BYTES2
            sta   PR32V2
            lda   BYTES3
            sta   PR32V3
            ldx   #FD_STDOUT
            jsr   PR32
            lda   NAMEFLG
            beq   :nonm
            jsr   PRSPACE
            lda   ARGIDX
            jsr   GETARG
            ldx   #FD_STDOUT
            jsr   PUTS
:nonm       lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

PRSPACE     lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* PR32 -- print the 32-bit value PR32V0-3 as decimal to fd X.
* CLOBBERS: A, X, Y. See this file's header for why this is not
* in liba.
*---------------------------------------------------------------
PR32        stx   PR32FD
            jsr   CK32DEC
            lda   #<CK32BUF
            sta   PTR0
            lda   #>CK32BUF
            sta   PTR0+1
            ldx   PR32FD
            jsr   PUTS
            rts

*---------------------------------------------------------------
* CK32DEC -- PR32V0-3 (32-bit, consumed) -> decimal ASCII
* string in CK32BUF, NUL-terminated. Ten power-of-ten
* positions, trial-subtract-then-commit (a borrow means "too
* small", and the trial result is simply discarded rather than
* compared first -- one fewer multi-byte compare routine).
*---------------------------------------------------------------
POW10T      dfb   $00,$CA,$9A,$3B    ;1000000000
            dfb   $00,$E1,$F5,$05    ;100000000
            dfb   $80,$96,$98,$00    ;10000000
            dfb   $40,$42,$0F,$00    ;1000000
            dfb   $A0,$86,$01,$00    ;100000
            dfb   $10,$27,$00,$00    ;10000
            dfb   $E8,$03,$00,$00    ;1000
            dfb   $64,$00,$00,$00    ;100
            dfb   $0A,$00,$00,$00    ;10
            dfb   $01,$00,$00,$00    ;1

CK32DEC     ldy   #0
            stz   CK_LZ
            ldx   #0
:digitloop  stz   CK_DIG
:trysub     sec
            lda   PR32V0
            sbc   POW10T,x
            sta   CK_T0
            lda   PR32V1
            sbc   POW10T+1,x
            sta   CK_T1
            lda   PR32V2
            sbc   POW10T+2,x
            sta   CK_T2
            lda   PR32V3
            sbc   POW10T+3,x
            sta   CK_T3
            bcc   :nodig
            lda   CK_T0
            sta   PR32V0
            lda   CK_T1
            sta   PR32V1
            lda   CK_T2
            sta   PR32V2
            lda   CK_T3
            sta   PR32V3
            inc   CK_DIG
            bra   :trysub
:nodig      lda   CK_DIG
            bne   :emit
            lda   CK_LZ
            bne   :emit
            cpx   #36
            beq   :emit
            bra   :skip
:emit       lda   #1
            sta   CK_LZ
            lda   CK_DIG
            ora   #$B0
            sta   CK32BUF,y
            iny
:skip       inx
            inx
            inx
            inx
            cpx   #40
            bne   :digitloop
            lda   #0
            sta   CK32BUF,y
            rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as sum.s/wc.s.
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

REFILL      lda   SRCFD
            sta   RPARM_REF
            lda   #<RPARM
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

ERRMSG      asc   "cksum: cannot open "
            dfb   $00

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
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* cksum's bss -- `dum`/`dend` at the textual end, anchored at
* LIBA_BSSEND (learning:01M0FNC75R7YSFRNS328WHXMHN). NOTHING
* ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - ERRFLAG: `stz` as START's first instruction.
*  - SRCFD: written on both the stdin and per-file paths.
*  - ARGIDX: `sta` at :havefile; the stdin path never reads it
*    (NAMEFLG is `stz`'d first, so REPORT's ARGIDX read is
*    unreachable on that path, not merely unreached).
*  - NAMEFLG: written once per REPORT call.
*  - BUFPOS/BUFLEN: `stz`'d by CKSUMFD, PER FILE.
*  - CRC0-3/BYTES0-3: `stz`'d by CKSUMFD, PER FILE -- the
*    accumulators, explicitly cleared rather than relying on a
*    zero start (a warm respawn hands the next invocation the
*    SAME bank with the last one's values still in it).
*  - LEN0-3: CKSUMFD's own store at :eof, before :lenloop's
*    first read.
*  - PR32V0-3: REPORT stores all four before every PR32 call.
*  - PR32FD: PR32's own first store.
*  - CK_LZ/CK_DIG/CK_T0-3: CK32DEC stores each before its own
*    later read.
*  - PATHBUF: MKPATH writes chars then the count byte. Untouched
*    on the stdin path.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*  - CK32BUF: filled by CK32DEC before PR32's PUTS reads it.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
SRCFD       ds    1
ARGIDX      ds    1
ERRFLAG     ds    1
NAMEFLG     ds    1
BUFPOS      ds    1
BUFLEN      ds    1

CRC0        ds    1
CRC1        ds    1
CRC2        ds    1
CRC3        ds    1
BYTES0      ds    1
BYTES1      ds    1
BYTES2      ds    1
BYTES3      ds    1
LEN0        ds    1
LEN1        ds    1
LEN2        ds    1
LEN3        ds    1

PR32V0      ds    1
PR32V1      ds    1
PR32V2      ds    1
PR32V3      ds    1
PR32FD      ds    1
CK_LZ       ds    1
CK_DIG      ds    1
CK_T0       ds    1
CK_T1       ds    1
CK_T2       ds    1
CK_T3       ds    1

PATHBUF     ds    65
CBUF        ds    BUFSZ
CK32BUF     ds    11
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window (see src/bin/sum.s for the
* -- full note).
            err   */$BF00
            dend
