*---------------------------------------------------------------
* dd.s -- file-level block copy, key=value operands.
*
* Usage: dd [if=F] [of=F] [bs=N] [count=N] [skip=N] [seek=N]
*           [conv=notrunc]
*
* if=/of= default to stdin/stdout. bs= is the block size, 1..
* BUFMAX bytes, default 512. count= caps the number of INPUT
* blocks copied (default: until EOF). skip=/seek= LSEEK past N
* blocks of if=/of= before the copy starts -- only legal against
* a real file (an LSEEK on the tty fds makes no sense, so stdin/
* stdout + skip/seek is a usage-shaped error, not a kernel one).
* conv=notrunc is the ONLY conv token: it selects IN-PLACE mode
* (OPEN the existing of=, no UNLINK/CREATE) instead of the
* default FRESH mode (UNLINK, then CREATE a BIN seedling). No
* other conv value, no k/b/w/x suffix on any N -- decimal digits
* only, v1's documented deferral.
*
* All values are 16-bit block counts; skip*bs/seek*bs is done at
* RUNTIME as a 16x16->32 shift-add multiply (MULOFF) because
* this dialect has no operator precedence to lean on for it, and
* the ProDOS mark is only 24 bits -- a product that doesn't fit
* is "offset too large", not a silently truncated seek.
*
* Skeleton copied from touch.s (puts/org/dsk/typ, the liba equ
* puts, the CREATE parmlist style, the dum/dend footer). The
* OPEN/READ/WRITE-loop/CLOSE shape and the partial-write
* WRITE_ALL loop are cat.s's, widened from a fixed 512-byte
* BUFSZ to a runtime bs (DD_WRTALL below); io_buffer=$0000 is
* cat.s's own convention, unrelated to the process-bank data
* buffer. LSEEK is src/liba/seek.s verbatim (SEEK_SET, PTR0 ->
* a 3-byte little-endian offset buffer, carry set = error).
* PRNUM (src/liba/num.s) prints the final report's four counts.
*
* Every conditional branch whose target is not a few
* instructions away is guarded: `b<cc> :near / jmp FAR`. JSR/JMP
* are absolute (no range limit); Bxx/BRA are +-127 and this file
* is long enough that a direct branch to a distant label is not
* safe to assume in range.
*
* Uses ONLY liba (src/liba) -- no direct syscalls, no raw gate
* address, no equates; see docs/USERLAND.md and syscalls.s's
* header for why.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/dd.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFMAX      equ   4096             ;max bs=, and CBUF's size
DEFBS       equ   512              ;bs= default

            put   ddparse.s
            put   ddcopy.s

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/seek.s
            put   ../liba/num.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* dd's bss -- `dum`/`dend` at the TEXTUAL END, anchored at
* LIBA_BSSEND (libabss.s already opened its own block at `*`).
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21). Read-
* before-write trace:
*  - ARGIDX/BSVAL/HAVE_COUNT/SKIPVAL/SEEKVAL/NOTRUNC/IFPTR/
*    OFPTR/BLKDONE/IN_FULL/IN_PART/OUT_FULL/OUT_PART: all
*    `stz`'d or `sta`'d by START's opening run, before
*    PARSELOOP or the copy can read any of them.
*  - COUNTVAL: only read when HAVE_COUNT=1, which only happens
*    after KEY_CNT has just stored it.
*  - INFD/OUTFD: written by the IN_*/OUT_* open blocks before
*    IN_SEEK/OUT_SEEK or PREPCOPY read them.
*  - PARSE_VAL/TENTMP: PARSENUM/PMUL10 write-before-read (stz
*    then accumulate; TENTMP copied from PARSE_VAL before use).
*  - OFF_BLK: `sta`'d from SKIPVAL/SEEKVAL immediately before
*    every MULOFF call.
*  - OMCND0-3/OFFBUF/OFHI: MULOFF's own stz/sta, before its
*    first add or its caller's OFHI test.
*  - ERRPATH/ERRSFX: `sta`'d at every REPORTERR2 call site
*    immediately before the `jsr`.
*  - PATHBUF: MKPATH writes chars then the count byte, and the
*    MLI reads only count+1; DPARM/CRPARM's `da PATHBUF` is
*    just this arena's fixed address, not a value.
*  - CBUF: filled by SC_READ; WPARM_REQ is set from RPARM_TRANS,
*    so DD_WRTALL never reads past what this record read.
*  - the four parmlists: constants stored by START (OPARM/RPARM/
*    WPARM/CPARM's count/path/iobuf/buf fields), ref/req/buf
*    result and per-record fields written before each call that
*    reads them (PREPCOPY sets RPARM_REF/WPARM_REF once; DOREAD
*    sets WPARM_BUF/WPARM_REQ every record; REPORT sets
*    CPARM_REF per close).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ARGIDX      ds    1
BSVAL       ds    2
COUNTVAL    ds    2
HAVE_COUNT  ds    1
SKIPVAL     ds    2
SEEKVAL     ds    2
NOTRUNC     ds    1
IFPTR       ds    2
OFPTR       ds    2
INFD        ds    1
OUTFD       ds    1
BLKDONE     ds    2
IN_FULL     ds    2
IN_PART     ds    2
OUT_FULL    ds    2
OUT_PART    ds    2
PARSE_VAL   ds    2
TENTMP      ds    2
OFF_BLK     ds    2
OMCND0      ds    1
OMCND1      ds    1
OMCND2      ds    1
OMCND3      ds    1
OFFBUF      ds    3
OFHI        ds    1
ERRPATH     ds    2
ERRSFX      ds    2
PATHBUF     ds    65             ;1 count byte + up to 64 chars
                                 ;(MLI shape)
CBUF        ds    BUFMAX         ;data_buffer -- process-bank
                                 ;address, kernel copyin/outs
                                 ;through it (unlike io_buffer)

OPARM       ds    1
OPARM_PATH  ds    2
OPARM_IOBUF ds    2              ;kernel-owned (main memory) --
                                 ;NOT a process buffer; see
                                 ;cat.s's own header
OPARM_REF   ds    1              ; result: fd

RPARM       ds    1
RPARM_REF   ds    1              ;set once in PREPCOPY
RPARM_BUF   ds    2
RPARM_REQ   ds    2              ;set once in PREPCOPY, from
                                 ;BSVAL
RPARM_TRANS ds    2              ; result: bytes actually read

WPARM       ds    1
WPARM_REF   ds    1              ;set once in PREPCOPY
WPARM_BUF   ds    2              ;patched per write chunk
WPARM_REQ   ds    2              ;patched per record/chunk
WPARM_TRANS ds    2

CPARM       ds    1
CPARM_REF   ds    1              ;patched from INFD/OUTFD
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window. The division is 0
* -- while it fits, 1 when it does not, and `err` fails the
* -- assembly. check_modules' image-window gate cannot see this
* -- -- a `dum` arena emits no bytes. See src/bin/ed.s.
            err   */$BF00
            dend
