*---------------------------------------------------------------
* bpatch.s -- spec-driven BINARY patcher (NOT text patch(1)).
* Reads a small text SPEC of edit directives and applies them to
* a TARGET binary file, in place.
*
* Usage: bpatch SPEC TARGET
*
* Flow: OPEN+READ TARGET whole into TBUF (cap TBUFMAX). OPEN+
* READ SPEC whole into SBUF (cap SBUFMAX), CLOSE SPEC. Parse it
* by line, masking bit 7 off every byte as read (so both maux
* high-bit text and plain 7-bit specs parse) -- `set`/`expect`/
* `flip-lc` directives, `#` comments, blank lines. Any parse or
* apply error reports and EXITs 1 with NOTHING written back. On
* success: LSEEK TARGET to 0, WRITE TLEN bytes from TBUF (every
* directive is length-preserving), CLOSE, EXIT 0.
*
* Skeleton copied from touch.s (puts/org/dsk/typ, the liba equ
* puts, the dum/dend footer). OPEN/READ-loop/CLOSE is cat.s's/
* dd.s's shape, widened with an overflow PEEK read (request 1
* byte past a filled buffer to tell "exactly TBUFMAX bytes, EOF
* right there" from "more data past the cap") since a request of
* 0 cannot distinguish those two cases from trans_count alone.
* LSEEK is src/liba/seek.s verbatim (SEEK_SET, PTR0 -> a 3-byte
* little-endian offset buffer). WRITE_ALL is cat.s's/dd.s's own
* partial-write loop, widened to TLEN.
*
* SPLIT 2026-09-07 (S9-PLAN sec 6, check_dialect's 16128-byte AS
* window): bpatchp.s carries START + the spec parser (line
* splitting, token/word extraction, hex parsing, directive
* dispatch); bpatchd.s carries the three directive appliers,
* write-back, every error exit + message, and the keyword table.
* Put immediately after the liba equ puts, before the liba code
* puts -- ddparse.s/ddcopy.s's own precedent.
*
* Every conditional branch whose target is not a few lines away
* is guarded (`b<cc> :near / jmp FAR`) or just uses `jmp`
* outright -- dd.s's own discipline, followed here too.
*
* Uses ONLY liba (src/liba) -- no direct syscalls, no raw gate
* address; see docs/USERLAND.md and syscalls.s's header for why.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/bpatch.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

TBUFMAX     equ   28672         ;target file cap
SBUFMAX     equ   4096          ;spec file cap
WORDBUFSZ   equ   16            ;longest real token is 7 chars
                                ;("flip-lc"); this is generous
WORDCAP     equ   WORDBUFSZ-1   ;max chars READWORD will store

            put   bpatchp.s
            put   bpatchd.s

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/seek.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* bpatch's bss -- `dum`/`dend` at the TEXTUAL END, anchored at
* LIBA_BSSEND (libabss.s already opened its own block at `*`).
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21). Read-
* before-write trace:
*  - TLEN/SLEN: `stz`'d by OPENTGT/OPENSPEC right after each
*    OPEN succeeds, before their own read loops accumulate them.
*  - TARGETFD/SPECFD: `sta`'d from OPARM_REF immediately after
*    each successful OPEN.
*  - LPOS/SBUFEND: written by PARSESPEC's own prologue before
*    its loop or FINDEOL reads either.
*  - LINEEND/NEXTLPOS: written by FINDEOL before PROCLINE or
*    PARSESPEC's own loop-advance reads them.
*  - OFFVAL: written whole by HEXPARSE16 before any caller reads
*    it.
*  - BYTETMP: written by HEXPARSE8 (scratch) and by DIR_EXPECT
*    (its own use, after HEXPARSE8 has already returned and no
*    longer needs it) before each is read back.
*  - WORDLEN/WORDBUF: written whole by READWORD (NUL-terminated,
*    length in WORDLEN) before WORDEQ/HEXPARSE16/HEXPARSE8 read
*    either.
*  - GOTONE: `stz`'d at DIR_SET's entry before its own loop-end
*    test reads it.
*  - FLCNT: written whole by DIR_FLIPLC before its loop reads
*    it.
*  - PEEKBUF: written by the one-byte overflow-probe SC_READ
*    call before the same call's own trans_count test -- never
*    read for its VALUE, only used as a WRITE target the
*    kernel's copyout needs somewhere to land.
*  - ERRPATH: `sta`'d by OPENFAIL from the caller's PTR0 before
*    OPENFAIL's own PUTS calls read it back.
*  - PATHBUF: MKPATH writes chars then the count byte; the MLI
*    reads only count+1. OPARM's `da PATHBUF` is just this
*    arena's fixed address, not a value.
*  - SEEKBUF: `stz`'d whole by WRITEBACK before LSEEK reads it.
*  - TBUF: filled by OPENTGT's read loop up to TLEN bytes, then
*    DIR_SET/DIR_FLIPLC's own in-place edits; never read past
*    TLEN by WRITEBACK (which writes exactly TLEN bytes).
*  - SBUF: filled by OPENSPEC's read loop up to SLEN bytes;
*    never scanned past SLEN (PARSESPEC/FINDEOL bound every scan
*    by SBUFEND = SBUF+SLEN).
*  - the four parmlists: constants stored by OPENTGT/OPENSPEC/
*    WRITEBACK before each first use; result/patched fields
*    written before every call that reads them.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
TLEN        ds    2
SLEN        ds    2
TARGETFD    ds    1
SPECFD      ds    1
LPOS        ds    2
SBUFEND     ds    2
LINEEND     ds    2
NEXTLPOS    ds    2
OFFVAL      ds    2
BYTETMP     ds    1
WORDLEN     ds    1
GOTONE      ds    1
FLCNT       ds    2
PEEKBUF     ds    1
ERRPATH     ds    2
WORDBUF     ds    WORDBUFSZ
PATHBUF     ds    65            ;1 count byte + up to 64 chars
                                 ;(MLI shape)
SEEKBUF     ds    3             ;LSEEK's 3-byte little-endian
                                 ;offset buffer (SEEK_SET to 0)
TBUF        ds    TBUFMAX       ;data_buffer -- process-bank
                                 ;address, kernel copyin/outs
                                 ;through it (cat.s's own
                                 ;io_buffer=$0000 convention is
                                 ;unrelated, see OPARM_IOBUF)
SBUF        ds    SBUFMAX

OPARM       ds    1
OPARM_PATH  ds    2
OPARM_IOBUF ds    2              ;kernel-owned (main memory) --
                                 ;NOT a process buffer; see
                                 ;cat.s's own header
OPARM_REF   ds    1              ; result: fd

RPARM       ds    1
RPARM_REF   ds    1              ;patched before each call
RPARM_BUF   ds    2              ;patched before each call
RPARM_REQ   ds    2              ;patched before each call
RPARM_TRANS ds    2              ; result: bytes actually read

WPARM       ds    1
WPARM_REF   ds    1              ;set once in WRITEBACK
WPARM_BUF   ds    2              ;patched per write chunk
WPARM_REQ   ds    2              ;patched per write chunk
WPARM_TRANS ds    2

CPARM       ds    1
CPARM_REF   ds    1              ;patched from SPECFD/TARGETFD
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window. The division is 0
* -- while it fits, 1 when it does not, and `err` fails the
* -- assembly. check_modules' image-window gate cannot see this
* -- -- a `dum` arena emits no bytes. See src/bin/ed.s.
            err   */$BF00
            dend
