*---------------------------------------------------------------
* grep.s -- print lines matching a pattern.
*
* Usage: grep [-cilnqsvx] [-e RE] RE [FILE...]
*
* CONTRACT: compile nothing -- RE is interpreted directly by
* liba/regex.s, the same Thompson-subset BRE engine ed uses for
* g/re/p and s///. That sharing is deliberate and is why the
* engine lives in liba rather than inside ed: V6/V7 did it the
* same way, one matcher behind both tools.
*
* Each input line is tested; matching lines go to stdout (fd 1)
* with a CR appended, including for a final unterminated line.
* With no FILE arguments, stdin (fd 0) is read -- the classic
* no-args behaviour, same shape as cat.s. A FILE that fails to
* open prints "grep: cannot open <name>" to stderr and is
* SKIPPED; grep continues with the remaining arguments.
*
* Exit status is the classic one, and programs depend on it:
*   0  at least one line matched
*   1  no line matched
*   2  usage error, or a FILE could not be opened
*
* FLAGS: -v inverts the match, -n prefixes the line number, -c
* prints only a count, and -e takes the RE as its own option
* argument -- which is the only way to search for a pattern
* that begins with '-'. A -e RE beats a positional RE.
*
* FLEET F.2 additions (2026-09-01, A12 spellings): -i matches
* case-insensitively (V7 spelled it -y; every living hand types
* -i) by folding BOTH the pattern and a COPY of each line to
* lowercase -- the printed line is the original, and folding
* the pattern folds class members too, so -i [A-Z] means [a-z],
* the reference behaviour. -l prints each FILE's name ONCE at
* its first selected line and moves to the next operand (stdin
* prints "(standard input)", the modern spelling); -l overrides
* -c and -n -- names only. -s suppresses the cannot-open
* MESSAGE; the exit-2 status is not suppressed, so scripts keep
* the signal and humans lose the noise.
*
* POSIX -q AND -x (2026-09-13): -q is QUIET -- nothing goes to
* stdout no matter what other flags ask for (-c/-l/-n included),
* and grep exits the moment the FIRST line is selected, without
* reading the rest of the input -- POSIX permits this, BSD grep
* does it, and it is why a matching line found AFTER an earlier
* operand's open failure still exits 0: the early exit happens
* before the ERRFLAG-outranks-MATCHED rule below is ever
* consulted. No match at all still falls through to that rule,
* so a lone open failure with nothing selected is still exit 2.
*
* -x selects only a line the pattern matches AS A WHOLE LINE.
* It is implemented as anchoring, not a span check on
* RE_MSTART/RE_MEND: the engine is backtracking first-match, not
* leftmost-longest, so a span check could reject a line a
* different backtrack path would have spanned. Building
* ^PATTERN$ makes the ENGINE backtrack until the whole line is
* covered. A pattern already anchored is left alone -- no `^` is
* added if it already starts with one, no `$` if it already ends
* with an UNESCAPED one (a `$` preceded by `\` is a literal
* dollar, still needing the real anchor). PATBUF grew by 2 bytes
* for the pair; the two-byte margin is checked before use --
* XANCHOR refuses (usage, exit 2) rather than silently drop a
* byte if the pattern is already at LINEMAX and needs both.
* -i and -x compose: -i folds PATBUF first, and the anchors are
* not letters, so folding after adding them would be a no-op
* either way.
*
* ONE PATTERN, NOT A SET, AND IT SAYS SO. A second -e is a USAGE
* ERROR (exit 2), not a silent last-one-wins: `grep -e A -e B F`
* means "lines matching A or B" everywhere else, and a v1 bank
* has no room for a pattern set, so the only two honest answers
* are implement it or refuse it. Refusing is the one that cannot
* return a confidently wrong ANSWER. -f is the same decision and
* is also not v1. The divergence from /usr/bin/grep is named in
* scripts/e2e_divergence.py and gated by its own corpus case.
*
* MULTIPLE FILEs ARE PREFIXED. With more than one FILE operand
* each selected line prints as FILE:line, and under -n as
* FILE:NUM:line -- the -H default of every Unix grep. One FILE,
* or stdin, stays bare. The decision is the OPERAND COUNT, not
* how many of them opened: an unopenable operand still counts,
* which is what /usr/bin/grep does (measured, BSD grep 2.6.0).
* The name printed is the operand AS TYPED, not the resolved
* path -- again the reference behaviour.
*
* -c PRINTS ONE COUNT PER FILE under the same prefix rule, and
* prints NOTHING for a file that would not open. Both the count
* and -n's line numbers restart at each FILE.
*
* Lines longer than LINEMAX are TRUNCATED at the limit and the
* remainder is skipped to the next CR. Silently truncating is
* wrong for a tool people grep logs with, but a v1 bank has no
* room to grow the buffer and failing the whole run is worse;
* the truncation point is a documented limit, not a surprise.
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
            dsk   ../../build/grep.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/regex.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

            put   grepbody.s

            put   ../liba/regex.s
            put   ../liba/regex2.s
            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s
            put   ../liba/regexbss.s

*---------------------------------------------------------------
* grep's bss -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at LIBA_BSSEND rather than `*`
* (learning:01M0FNC75R7YSFRNS328WHXMHN). 846 bytes that were
* emitted zeros. GREPOPTS and the three parmlists stay above as
* initialised data; `da PATHBUF` / `da CBUF` resolve into this
* arena as forward references.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21). grep is
* the cleanest of the buffered readers -- START carries an
* explicit flag clear and GREPFD a per-file one:
*  - MATCHED/ERRFLAG: `stz`'d at :nopfx, on the only path that
*    reaches a file.
*  - NLINE/NHIT: `stz`'d PER FILE at the top of GREPFD, which
*    is both the read-before-write guard and the reason -n's
*    numbers and -c's counts restart at each FILE. The `inc
*    NLINE` / `inc NHIT` read-modify-writes are genuine reads,
*    and that block is what makes them safe.
*  - WANT_V/WANT_N/WANT_C/WANT_E/WANT_I/WANT_L/WANT_S/WANT_Q/
*    WANT_X/STDINF/PFX: `stz` in START's opening run, before
*    GETOPT can set any of them (STDINF is then set only on
*    the stdin path).
*  - XLEN/XHI/XNEEDP/XNEEDS/XREQ: XANCHOR's own scratch, all
*    `stz`'d or `sta`'d at the top of that routine before any
*    read, and XANCHOR runs at most once per process (:nofold,
*    only when WANT_X is set) -- nothing carries over.
*  - LDONE: `stz` at the top of GREPFD, per FILE -- the same
*    guard that makes "one name per file" true for -l.
*  - FOLDBUF: FOLDCOPY writes it whole (incl. the NUL) before
*    RE_MATCH reads it, and only the WANT_I path touches it.
*  - SRCFD: written on both paths (stdin, or from OPARM_REF
*    after a successful open) before any read.
*  - ARGIDX: `sta` at :havefile before its own next read. PRPFX
*    reads it too, but only with PFX set, and PFX is set only
*    when there are >=2 FILE operands -- which is a path that
*    goes through :havefile.
*  - BUFPOS/BUFLEN: `stz` as GREPFD's first two instructions --
*    PER FILE, which is what makes the multi-FILE loop correct
*    as well as making the `pos >= len` refill test a decision
*    rather than an accident.
*  - LINELEN: `sty LINELEN` after `ldy #0` in GETLINE.
*  - PATBUF: STRCPY'd by TOPATBUF -- from argv, or from -e's
*    OPTARG -- before RE_MATCH reads it. Every path to a file
*    passes through one of the two callers. WANT_X's XANCHOR
*    then rewrites it in place, itself before any RE_MATCH.
*  - LINEBUF: NUL-terminated by GETLINE, and TESTLINE runs
*    only after GETLINE returned carry-clear. Bytes past the
*    NUL are never read -- RE_MATCH and PUTS both stop there.
*  - PATHBUF: MKPATH writes chars then the count byte; the MLI
*    reads only count+1.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*---------------------------------------------------------------
            dum   REGEX_BSSEND
SRCFD       ds    1
ARGIDX      ds    1
ERRFLAG     ds    1
MATCHED     ds    1
WANT_V      ds    1              ;-v invert the match
WANT_N      ds    1              ;-n prefix line numbers
WANT_C      ds    1              ;-c print only a count
WANT_E      ds    1              ;-e gave us the RE
WANT_I      ds    1              ;-i fold case
WANT_L      ds    1              ;-l names only
WANT_S      ds    1              ;-s quiet open errors
WANT_Q      ds    1              ;-q quiet, exit on 1st match
WANT_X      ds    1              ;-x whole-line match (anchor)
LDONE       ds    1              ;-l said this file's name
STDINF      ds    1              ;reading fd 0 (for -l's name)
PFX         ds    1              ;>1 FILE: name every line
NLINE       ds    2              ;lines read so far
NHIT        ds    2              ;lines selected so far
LINELEN     ds    1
BUFPOS      ds    1
BUFLEN      ds    1
XLEN        ds    1              ;XANCHOR: PATBUF's length
XHI         ds    1              ;.. length's high byte (STRLEN)
XNEEDP      ds    1              ;.. 1 = prepend '^'
XNEEDS      ds    1              ;.. 1 = append '$'
XREQ        ds    1              ;.. XNEEDP+XNEEDS
WANT_F      ds    1              ;-F pattern is a fixed string
FLEN        ds    1              ;FESCAPE: PATBUF's length
NPAT        ds    1              ;patterns collected
PATIDX      ds    1              ;current slot (prep and match)
PATHIT      ds    1              ;some pattern matched this line
PFANY       ds    1              ;-f file had at least one line
FCNT        ds    1              ;.. metacharacters found
FSRC        ds    1              ;.. read cursor (backwards)
FDST        ds    1              ;.. write cursor (backwards)

PATBUF      ds    LINEMAX+3      ;+2 over LINEMAX+1: room for
                                 ;-x's '^'...'$' pair (XANCHOR)
*-- The pattern SET (-e repeated, -f a file). PATMAX pages, and
*-- a page each so slot N is >PATTAB+N with no multiply. This is
*-- a `dum` arena: it emits NO image bytes, so the eight pages
*-- cost nothing in the binary and only address space this
*-- process has spare.
PATTAB      ds    PATMAX*256
LINEBUF     ds    LINEMAX+1
FOLDBUF     ds    LINEMAX+1      ;-i's folded copy of LINEBUF
PATHBUF     ds    65
CBUF        ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
