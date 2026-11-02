*---------------------------------------------------------------
* od.s -- octal (and hex, and char) dump.
*
* Usage: od [-bcxdosv] [-A base] [-t type] [-j n] [-N n] [file]
*
* CONTRACT: dump FILE (or stdin, with no FILE argument) as
* bytes, 16 per line, each line prefixed by a 4-digit hex offset
* column ("%04X"). A final line prints the trailing offset ALONE
* (no byte columns) -- classic V6 od's own end-of-dump marker,
* kept here unchanged.
*
* DELIBERATE DIVERGENCE FROM V6 (ruled, not a bug): V6 od
* defaults to OCTAL 16-BIT WORDS -- a PDP-11 artifact (the -11's
* console/front-panel octal display and 16-bit word size). maux
* runs on a BYTE machine (6502/65C02, no 16-bit registers, no
* octal front panel), so this od defaults to HEX BYTES instead
* -- the same rendering V6's own "-x" flag names. House rule:
* match early Unix where the constraints match, follow the
* machine where they don't -- this is a follow-the-machine case.
*   -b  bytes in three-digit octal (always exactly 3 digits --
*       an 8-bit byte needs at most 3 octal digits, so this
*       column never pads short OR overflows).
*   -c  printable characters as themselves, non-printables as
*       ".". See "HIGH-BIT RULING" below for $80-$FF.
*   -x  hex bytes, two digits each -- ALSO the default (no
*       flags). Naming it explicitly is accepted but changes
*       nothing.
*
* FLAG COMBINING: flags DO combine (this task's "if you judge
* combining too costly, say so" escape hatch is NOT taken --
* the three row-printers are small and independent, so the cost
* is low). When more than one of -b/-c/-x is given, EACH format
* gets its own full row (own offset column, own 16-field body,
* own CR) for a given 16-byte block, printed in the FIXED order
* hex, octal, char regardless of the order the flags appeared on
* the command line -- deterministic output beats mirroring argv
* order, and hex-then-octal-then-char is also the order the task
* description itself lists the three flags in. With no flags,
* only the hex row prints (the default IS -x, not "all three").
*
* HIGH-BIT RULING (-c, bytes $80-$FF): file bytes crossing
* SC_READ are OPAQUE raw bytes, verbatim -- docs/USERLAND.md
* ("liba converts NOTHING on read()"), same posture cat.s takes.
* So an input byte is NOT presumed to be a liba high-bit-set
* string byte; it is an arbitrary 8-bit value that may happen to
* carry the high bit for other reasons (maux text, or plain
* binary data). This routine STRIPS the high bit first
* (STRIPHI's own operation, src/liba/string.s) to classify the
* byte in 7-bit ASCII space -- $20-$7E is "printable" -- then
* MAKEHI's the result before PUTC, since PUTC/stdout expect
* liba's high-bit-set convention for anything meant to display
* as text (ls.s's directory-name printing sets the same
* precedent: strip/reclassify, then MAKEHI for display). A byte
* that is high-bit ASCII TEXT ($A0-$FE, e.g. "A" stored as $C1)
* therefore prints as its own letter, same as plain ASCII "A"
* ($41) would -- both strip to $41, which is printable. A byte
* that is genuine BINARY garbage in $80-$FF prints as "."
* exactly when its stripped low 7 bits fall outside $20-$7E,
* same as any other control byte would.
*
* -j skip / -N limit (SHIPPED 2026-09-17): -j reads and discards
* `skip` bytes before the dump starts (stopping early, dumping
* nothing, if EOF hits first) and seeds OFFSET at `skip` rather
* than 0, so the printed column still reads as a real file
* position -- BSD od does the same. -N caps the TOTAL bytes
* dumped at `limit`, checked before every GETBYTE so a limit
* that lands mid-row ends that row short, the same shape EOF
* mid-row already took. Both parse unsigned decimal only (no
* BSD 0x/0-prefixed radix reader -- not needed by any script
* this tree runs), 16-bit, wrapping past 65535 undocumented
* further than this comment (od.s dumps within one process
* bank's own worth of file anyway).
*
* -A base (SHIPPED 2026-09-21): d, o, x or n; widths fixed per
* base
* (4 hex / 5 dec / 6 oct) so the column stays a column.
*
* -t type_string, -d -o -s, -v (SHIPPED 2026-10-08, docs/POSIX-
* ODT.md, notes in docs/POSIX-ODT-NOTES.md): every format is a
* SPEC
* (kind a c d o u x, unit size 1 2 4) printed by ONE row
* printer in
* odtype.s -- the legacy -b/-x/-c letters are specs too (o1,
* x1 and
* the dot-style k), kept at their ruled widths and ruled x,b,c
* order
* when they stand alone. -d/-o/-s are -t u2/o2/d2 (XCU).
* Several -t
* print one line each under the same offset, later lines with a
* blank offset, columns stretched to line up the way GNU od does
* it (odtype.s header). L is 4 bytes on this 16-bit machine;
* x8 and
* every other size are a usage error. A full row equal to the
* one
* before collapses to a `*` line (POSIX), -v turns that off. Hex
* digits stay UPPER case, as the offset column and -x always
* were.
*
* Cannot open FILE: "od: cannot open <name>" to stderr, exit 1.
* More than one FILE argument, or an unrecognised flag: usage to
* stderr, exit 2. Otherwise exit 0.
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
            dsk   ../../build/od.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255              ;read-chunk size, same shape
                                   ;as wc.s/grep.s's GETBYTE
ROWMAX      equ   16               ;bytes per dump line

START       stz   WANT_B
            stz   WANT_C
            stz   WANT_X
            stz   ALIGN
            stz   VFLAG
            stz   HAVEPREV
            stz   SUPP
            stz   SPKIND                ;slots 0-2: the legacy
            stz   SPKIND+1              ;letters, filled at
            stz   SPKIND+2              ;:optdone
            lda   #3
            sta   NSLOT ;-t specs start at slot 3
            lda   #$F8                 ;-A x is the default;
            sta   OD_ABASE             ;hex is what od prints
            stz   HAVESKIP
            stz   HAVELIMIT
            lda   #<ODOPTS
            ldx   #>ODOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcc   :haveopt
            jmp   :optdone               ;the -A block below put
:haveopt                                 ;:optdone out of range
            cmp   #$E2                  ;'b' high-bit
            bne   :not_b
            sta   WANT_B
            bra   :optlp
:not_b      cmp   #$E3                  ;'c'
            bne   :not_c
            sta   WANT_C
            bra   :optlp
:not_c      cmp   #$F8                  ;'x'
            bne   :not_x
            sta   WANT_X
            bra   :optlp
:not_x      cmp   #$C1                  ;'A' -- offset base
            bne   :not_A
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            ldy   #0
            lda   (PTR0),y              ;exactly ONE letter, and
            sta   OD_ABASE              ;nothing after it
            iny
            lda   (PTR0),y
            bne   :abad
            lda   OD_ABASE
            cmp   #$E4                  ;'d'
            beq   :aok
            cmp   #$EF                  ;'o'
            beq   :aok
            cmp   #$F8                  ;'x'
            beq   :aok
            cmp   #$EE                  ;'n' -- no offset at all
            beq   :aok
:abad       jmp   :usage
:aok        jmp   :optlp
:not_A      cmp   #$EA                  ;'j' -- skip
            bne   :not_j
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   OD_PARSENUM
            bcs   :usage
            lda   OD_NVAL
            sta   SKIPN
            lda   OD_NVAL2
            sta   SKIPN+1
            lda   #1
            sta   HAVESKIP
            bra   :optlp
:not_j      cmp   #$CE                  ;'N' -- limit
            bne   :optx
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   OD_PARSENUM
            bcs   :usage
            lda   OD_NVAL
            sta   LIMITN
            lda   OD_NVAL2
            sta   LIMITN+1
            lda   #1
            sta   HAVELIMIT
            jmp   :optlp                ;-A's block put :optlp
                                        ;out of branch range
:optx       jsr   OD_OPTX               ;-t -v -d -o -s
            bcs   :usage
            jmp   :optlp
:usage      lda   #<USAGE
            sta   PTR0
            lda   #>USAGE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

:optdone    lda   WANT_B
            ora   WANT_C
            ora   WANT_X
            bne   :haveopts
            lda   NSLOT
            cmp   #3
            bne   :haveopts             ;a -t spec is the format
            lda   #1                    ;no flags: default is -x
            sta   WANT_X                ;alone, NOT all three --
                                        ;see file header
:haveopts   lda   WANT_X ;legacy letters are specs,
            beq   :lx ;in the ruled order x b c
            lda   #'x'
            sta   SPKIND
            lda   #1
            sta   SPSIZE
:lx         lda   WANT_B
            beq   :lb
            lda   #'o'
            sta   SPKIND+1
            lda   #1
            sta   SPSIZE+1
:lb         lda   WANT_C
            beq   :lc
            lda   #'k'
            sta   SPKIND+2
            lda   #1
            sta   SPSIZE+2
:lc         jsr   OD_TSETUP
            lda   ARGC
            sec
            sbc   OPTIND
            cmp   #2
            bcc   :nargok
            jmp   :usage
:nargok     stz   OFFSET
            stz   OFFSET+1
            stz   FILEFLAG
            lda   ARGC
            cmp   OPTIND
            bne   :havefile
            lda   #FD_STDIN
            sta   SRCFD
            jmp   :dump

:havefile   lda   OPTIND
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :openok
            lda   #<ERRMSG
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
:openok     lda   OPARM_REF
            sta   SRCFD
            lda   #1
            sta   FILEFLAG

:dump       stz   BUFPOS
            stz   BUFLEN
            lda   HAVELIMIT
            beq   :noremn
            lda   LIMITN
            sta   REMAIN
            lda   LIMITN+1
            sta   REMAIN+1
:noremn     lda   HAVESKIP
            beq   :rowloop
            lda   SKIPN
            sta   OFFSET
            lda   SKIPN+1
            sta   OFFSET+1
            lda   SKIPN
            sta   OD_SKCNT
            lda   SKIPN+1
            sta   OD_SKCNT+1
:skiplp     lda   OD_SKCNT
            ora   OD_SKCNT+1
            beq   :rowloop
            jsr   GETBYTE
            bcs   :rowloop           ;EOF during the skip itself
            lda   OD_SKCNT
            bne   :skdeclo
            dec   OD_SKCNT+1
:skdeclo    dec   OD_SKCNT
            bra   :skiplp
:rowloop    stz   LINECNT
:fill       lda   HAVELIMIT
            beq   :fillgo
            lda   REMAIN
            ora   REMAIN+1
            bne   :fillgo
            bra   :filldone          ;-N limit is exhausted
:fillgo     jsr   GETBYTE
            bcs   :filldone          ;EOF mid-row (or at 0)
            ldx   LINECNT
            sta   LINEBUF,x
            inc   LINECNT
            lda   HAVELIMIT
            beq   :nodec
            lda   REMAIN
            bne   :remdeclo
            dec   REMAIN+1
:remdeclo   dec   REMAIN
:nodec      lda   LINECNT
            cmp   #ROWMAX
            bne   :fill
:filldone   lda   LINECNT
            beq   :alldone            ;nothing left -- print the
                                      ;trailing offset and stop
            jsr   OD_EMIT
            clc
            lda   OFFSET
            adc   LINECNT
            sta   OFFSET
            lda   OFFSET+1
            adc   #0
            sta   OFFSET+1
            lda   LINECNT
            cmp   #ROWMAX
            beq   :rowloop            ;full row -- more may
                                      ;follow
            ;-- short row: GETBYTE already hit EOF this pass --
            ;-- fall through to the trailing offset line

:alldone    jsr   PRHEX4
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   FILEFLAG
            beq   :noclose
            lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
:noclose    lda   #0
            jsr   EXIT

            put   odrow.s
            put   odtype.s

USAGE       asc   "usage: od [-bcxdosv][-AtjN x][file]"
            dfb   $8D,$00
ERRMSG      asc   "od: cannot open "
            dfb   $00
ODOPTS      asc   "bcxdosvt:j:N:A:"
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
            put   ../liba/hex.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* od's bss -- `dum`/`dend` at the TEXTUAL END, anchored at
* LIBA_BSSEND rather than `*`
* (learning:01M0FNC75R7YSFRNS328WHXMHN). 348 bytes that were
* emitted zeros. ODOPTS and the three parmlists stay above as
* initialised data; `da PATHBUF` / `da CBUF` resolve into this
* arena.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - WANT_B/WANT_C/WANT_X: `stz`'d in START's opening run, and
*    WANT_X is `sta`'d again for the no-flag default.
*  - FILEFLAG: `stz` at :nargok on every non-exiting path, or
*    `sta` when a path was opened -- so the "do I owe a
*    SC_CLOSE" test never reads a stale 1.
*  - SRCFD: written on both the stdin and opened-file paths
*    before :dump is entered.
*  - OFFSET: `stz`'d as a pair at :nargok, BEFORE any file is
*    opened. od dumps at most one file, so entry-once is the
*    right scope for this accumulator -- :dump's own -j path
*    overwrites it with SKIPN before the skip loop runs.
*  - HAVESKIP/HAVELIMIT: `stz`'d in START's opening run.
*  - SKIPN/LIMITN: written by OD_PARSENUM's own success path,
*    before HAVESKIP/HAVELIMIT (their own guard) is ever set.
*  - OD_SKCNT: copied from SKIPN at :dump, before the skip
*    loop's own first read of it.
*  - REMAIN: copied from LIMITN at :dump (guarded by HAVELIMIT),
*    before the fill loop's own first read of it.
*  - OD_NVAL/OD_NVAL2/OD_DIGIT/OD_T2LO/OD_T2HI: OD_PARSENUM's/
*    OD_MUL10ADD's own scratch, written before each one's own
*    later read, every call.
*  - BUFPOS/BUFLEN: `stz`'d at :dump, making GETBYTE's
*    `pos >= len` refill test a decision rather than an
*    accident.
*  - LINECNT: `stz` at :rowloop; both routes to :alldone are
*    downstream of it.
*  - ROWIDX: `stz` at the head of each of the three row
*    printers.
*  - OD_OBYTE: `sta` as PROCT3's first instruction.
*  - LINEBUF: written for indices 0..LINECNT-1, and each row
*    printer reads only below the LINECNT it just filled.
*  - PATHBUF: MKPATH writes chars then the count byte.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
SRCFD       ds    1
FILEFLAG    ds    1              ;1 = opened via path, needs a
                                 ;matching SC_CLOSE
WANT_B      ds    1
WANT_C      ds    1
WANT_X      ds    1
BUFPOS      ds    1
BUFLEN      ds    1
LINECNT     ds    1
ROWIDX      ds    1
OD_OBYTE    ds    1
OFFSET      ds    2
HAVESKIP    ds    1              ;-j given
SKIPN       ds    2              ;-j's own byte count
OD_SKCNT    ds    2              ;the skip loop's own countdown
HAVELIMIT   ds    1              ;-N given
LIMITN      ds    2              ;-N's own byte count
REMAIN      ds    2              ;the fill loop's own countdown
OD_NVAL     ds    1              ;OD_PARSENUM's own output, lo
OD_NVAL2    ds    1              ;OD_PARSENUM's own output, hi
OD_DIGIT    ds    1              ;OD_MUL10ADD's own scratch
OD_T2LO     ds    1
OD_T2HI     ds    1
OD_ABASE    ds    1              ;-A's letter: d, o, x or n
OD_ADLO     ds    1              ;PROFF_DEC working value, lo
OD_ADHI     ds    1              ;.. hi
OD_ASUP     ds    1              ;.. leading-zero suppression

ALIGN       ds    1 ;1 once any -t/-d/-o/-s is given
VFLAG       ds    1              ;-v: no `*` collapse
HAVEPREV    ds    1              ;PREVBUF holds a full row
SUPP        ds    1 ;a `*` is already out for this run
NSLOT       ds    1              ;next free spec slot (3..11)
NSPEC       ds    1              ;specs after the squeeze
BIGSZ       ds    1              ;largest unit size in use
WBLK        ds    1              ;widest block, ALIGN's width
CURSPEC     ds    1
CURUNIT     ds    1
NUNITS      ds    1
FSIZE       ds    1
FLEN        ds    1
OD_NEG      ds    1
OD_BITS     ds    1
OD_MASK     ds    1
OD_CNT      ds    1
OD_IDX      ds    1
OD_TKIND    ds    1
OD_TSIZE    ds    1
OD_T1       ds    1
OD_T2       ds    1
OD_WI       ds    1
OD_W        ds    1
OD_ACC      ds    1
OD_PB       ds    1
OD_J        ds    1
OD_V0       ds    4              ;the unit being printed, LE
SPKIND      ds    11
SPSIZE      ds    11
SPDIG       ds    11
SPK         ds    11
SPN         ds    11
WTAB        ds    44             ;4 field widths a spec
FLD         ds    12
PREVBUF     ds    ROWMAX
LINEBUF     ds    ROWMAX+4       ;+4: zero pad for a short unit
PATHBUF     ds    65
CBUF        ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
