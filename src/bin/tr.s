*---------------------------------------------------------------
* tr.s -- translate, squeeze and/or delete characters.
*
* Usage: tr [-cds] string1 [string2]
*
* Copies fd 0 to fd 1, transforming bytes per string1/string2.
* No FILE operands -- classic V6/V7 tr, stdin/stdout only.
*
* -c   complement: string1 means every byte NOT in the given
*      set (ascending byte order 0-255 drives any positional
*      pairing with string2, since the literal order of a
*      complemented set is not meaningful).
* -d   delete bytes in string1 (string2's positional pairing is
*      skipped; string2, if given, only supplies -s's scope).
* -s   squeeze: a run of a repeated OUTPUT byte that is a member
*      of the squeeze set is reduced to one byte. The squeeze
*      set is string2 when given, else string1 (complemented
*      under -c) -- so "-s string1" alone, with neither -d nor
*      a second operand, is valid: squeeze only, nothing
*      translated or deleted.
*
* Translate mode is a two-operand form with neither -d nor -s
* named: byte i of string1 maps to byte i of string2; if
* string2 is shorter it is extended by repeating its last
* byte. Bytes not named in string1 pass through unchanged.
* Translate is the ONE mode that requires two operands -- -d
* and -s each also accept a single operand on their own.
*
* RANGES: "a-z" expands ascending inside string1/string2, same
* shape as glob.s's `[a-z]` (src/liba/glob.s) but unbracketed --
* tr's ranges sit directly in the operand string. A trailing
* unmatched '-' (nothing after it, or a descending pair) is
* read as a LITERAL '-' rather than a range, avoiding a
* backwards-range hang.
*
* NO BACKSLASH ESCAPES. V6 tr used `\ddd` for octal; string1/
* string2 here are the raw argv bytes with only '-' special.
* Skipped deliberately -- nothing in this task needs it, and
* leaving it out keeps EXPAND (below) a one-pass scan with no
* lookahead beyond one range.
*
* HIGH-BIT RULING: argv strings arrive high-bit-set (liba
* convention, docs/USERLAND.md; see glob.s's own header). File
* bytes, though, are NOT reinterpreted at all -- GETBYTE/PUTC
* move whatever is in the stream (print.s: "GETC -- read a
* single RAW"). So the 256-byte tables below are indexed by the
* RAW byte 0-255, covering the full range unconditionally; no
* STRIPHI/MAKEHI happens on the data path. Consequence: a
* string1/string2 argument written as ordinary shell text is
* high-bit ASCII (matching wc.s's own $8D/$A0/$89 constants),
* so it names the SAME bytes maux text files actually contain.
* But since the table spans all 256 codes, tr also works
* correctly on 7-bit-clean or binary input -- those bytes just
* default to the identity mapping (untouched) unless string1
* explicitly names them.
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
            dsk   ../../build/tr.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

            put   trbody.s
            put   tresc.s

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* tr's bss -- `dum`/`dend` at the TEXTUAL END of the file, so
* the arena begins past every emitted byte. `dum` computes
* addresses from the PC where it opens and `dend` RESTORES that
* PC, so anything emitted after `dend` would be laid down over
* the arena with no diagnostic
* (learning:01M0FNC75R7YSFRNS328WHXMHN). 1,811 bytes that were
* `ds` -- real zeros in the image, carried on every disk read
* and every 39.07 cyc/byte bank copy. Anchored at LIBA_BSSEND,
* not `*`: libabss.s already opened a block at `*` and two
* blocks at `*` are the SAME BYTES.
*
* TROPTS and RPARM stay EMITTED above: TROPTS is the getopt
* spec string and RPARM is an MLI parmlist whose constant
* fields are real initialised data. `RPARM_BUF da CBUF` still
* resolves -- a `dum` label has a real assembly-time address --
* which is the tee.s precedent for not having to drag a
* parmlist into the arena just because its buffer moved.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21). The
* read-before-write trace:
*  - WANT_C/WANT_D/WANT_S/HAVE_STR2: `stz` as START's opening
*    run, before the option loop.
*  - NOPS: `sta` at :optdone; in fact never read at all.
*  - BUFPOS/BUFLEN: `stz` at :run -- SEE THE NOTE AT THAT SITE.
*    These two were the tree's only genuine program-level
*    read-before-write, and the store there is what makes them
*    movable rather than a zero requirement (docs/STICKY.md
*    sec 28).
*  - CURBYTE/OUTBYTE/EXBYTE/EXCUR/EXC1/EXC2/EXSRCY: each
*    `sta`'d by its own routine an instruction or two before
*    that routine reads it back.
*  - LASTVALID: `stz` at :run, before the squeeze test reads
*    it. LASTOUT is read only when LASTVALID is nonzero, and
*    the sole store to LASTVALID sits in the same basic block
*    as the sole store to LASTOUT -- so the guard cannot be
*    true before the value exists.
*  - EXCNT/EXP1LEN/EXP2LEN/CIDX: EXCNT `stz`'d by EXPAND's own
*    entry. EXP1LEN is `sta`'d from EXPAND's return value
*    unconditionally, before any scan reads it. EXP2LEN is
*    `sta`'d the same way but ONLY under HAVE_STR2 (the
*    "expand string2" block is skipped for one operand) --
*    so :setxlat reads HAVE_STR2 FIRST and only trusts
*    EXP2LEN once that confirms it was actually written; see
*    the comment at :setxlat itself. CIDX `stz`'d at :xcomp.
*  - CBUF: filled by SC_READ, and GETBYTE only ever indexes
*    below the BUFLEN that same call set.
*  - EXP1BUF/EXP2BUF: written by EXEMIT for indices below the
*    length EXPAND then publishes; never scanned past it.
*  - MEMBER1/XTAB/DELFLAG: filled over the FULL 0..255 range
*    before any lookup that could reach them -- ZERO256 for
*    MEMBER1 and DELFLAG, and IDFILL's identity sweep for
*    XTAB. IDFILL runs from SETUPXLT (:haveset2) or directly
*    at :sqonly -- the only two ways to reach :run with WANT_D
*    clear, which is the only condition under which the data
*    path's `:xlate` ever indexes XTAB at all. Their zero
*    entries are meaningful ("not a member"), but they are
*    zeros a loop WROTE, never zeros the image carried.
*  - MEMBER2: same full 0..255 ZERO256, but reached only under
*    HAVE_STR2. MEMBER2 is read only via SETUPDEL (guarded on
*    HAVE_STR2 directly) or SETUPXLT -- and SETUPXLT (called
*    only from :haveset2) is reached only after :setxlat has
*    ALREADY tested HAVE_STR2 nonzero, which is the same flag
*    the ZERO256 above is gated on. Direct, not inferred, since
*    the EXP2LEN uninitialised-read fix above.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
WANT_C      ds    1
WANT_D      ds    1
WANT_S      ds    1
NOPS        ds    1
HAVE_STR2   ds    1
BUFPOS      ds    1
BUFLEN      ds    1
CURBYTE     ds    1
OUTBYTE     ds    1
LASTOUT     ds    1
LASTVALID   ds    1

EXCNT       ds    1
EXSRCY      ds    1
EXC1        ds    1
EXC2        ds    1
EXCUR       ds    1
EXBYTE      ds    1
CIDX        ds    1

EXP1LEN     ds    1
EXP2LEN     ds    1
XT_TWIN     ds    1              ;SETUPXLT: the twinned pair
ESCSRC      ds    1              ;ESCPASS read cursor
ESCDST      ds    1              ;.. write cursor
ESCVAL      ds    1              ;.. octal accumulator
ESCTMP      ds    1              ;.. one octal digit
ESCNPOS     ds    1              ;ESCCLASS: name start index
*-- ESCCLASS walks the class table with PTR2, a liba ZERO-PAGE
*-- pointer, because (zp),y is the only indirect the 6502 has --
*-- a cursor in this `dum` arena cannot be dereferenced at all.
*-- PTR2 is free here: both EXPAND call sites set it AFTER their
*-- jsr ESCPASS, so nothing of theirs is live across this.
CLSLEN      ds    1              ;.. this record's name length
CLSTMP      ds    1              ;.. one name byte
CLSN        ds    1              ;.. ranges left to emit
CLSLO       ds    1              ;.. current range low
CLSHI       ds    1              ;.. current range high

CBUF        ds    BUFSZ

ESCBUF      ds    256            ;ESCPASS output, reused for
                                 ;string2 (string1 is fully
                                 ;consumed into EXP1BUF first)
EXP1BUF     ds    256
EXP2BUF     ds    256
MEMBER1     ds    256
MEMBER2     ds    256
XTAB        ds    256
DELFLAG     ds    256
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's
* -- end; $BF00 is the top of the process window. The
* -- division is 0 while it fits, 1 when it does not, and
* -- `err` fails the assembly. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
* -- See src/bin/ed.s for the full note.
            err   */$BF00
            dend
