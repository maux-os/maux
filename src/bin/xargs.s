*---------------------------------------------------------------
* xargs.s -- construct argument lists from stdin and run a
* utility with them (XCU xargs).
*
* Usage: xargs [-0prt] [-E eofstr] [-L number] [-n number]
*              [-s size] [-I replstr] [utility [argument...]]
* utility defaults to "echo" (a bare, PATH-searched word, XCU's
* own default).
*
* SPLITTING/QUOTING (no -0; not implemented -- see below). Un-
* quoted <blank> (space/tab) or <newline> delimits arguments;
* adjacent delimiters collapse to one. '...' protects everything
* but the matching single quote; "..." protects everything but
* the matching double quote (neither interprets backslash inside
* it -- BSD/XCU's own rule, not the shell's). An UNQUOTED
* backslash escapes the very next byte literally, newline
* included. A quote left open at end of input is an error
* ("unmatched quote", exit 1) rather than silently absorbed.
* Each argument's TEXT is capped at TOKBUF (255) bytes,
* truncated the same way grep.s's GETLINE truncates -- a
* practical, self-imposed cap; the kernel's own spawn() has
* no such cap (docs/LIMITS.md).
*
* -I replstr [XSI]: one whole INPUT LINE per invocation
* (leading blanks stripped, blank lines skipped, no quote
* splitting -- the line is one string), substituted for every
* occurrence of
* replstr in the utility word and its fixed arguments. Disables
* -n (and this build's -s: a line-at-a-time invocation has no
* batch to size).
*
* -n number: at most `number` STDIN-derived arguments per
* invocation (also bounded below by the machine ceiling).
* -s size: bound the STDIN-derived arguments' packed byte
* total per invocation to `size`, clamped to the machine
* ceiling below.
* -t: each constructed command line is written to stderr,
* terminated with CR, just before it runs.
*
* THE DEFAULT SIZE, and where it comes from (docs/LIMITS.md,
* inc/mm.procbnk2.equ): spawn()'s child receives its
* whole argv+envp packed into ARG_MAX (1280) bytes of strings
* and ARGV_PTR_LIM (255, i.e. 127 total argv+envp pointers) of
* pointer array -- a hard machine ceiling, not a policy choice.
* xargs's own children are spawned with an EMPTY environment
* (SPWN_ENVP left null, unlike find.s's -exec, which inherits
* find's) -- a deliberate v1 simplification: it makes the
* whole ARG_MAX/127-pointer budget available to argv alone,
* computable once at startup from the FIXED words (the utility
* word plus any argument words xargs was itself given) with no
* runtime environment accounting. Utilities xargs runs (echo,
* cat, rm, touch, ...) do not need an inherited environment to
* do their job; PATH resolution happens in xargs's OWN
* process, before the child is asked to do anything. DEFAULT
* -s = ARG_MAX minus the
* fixed words' packed bytes; DEFAULT -n-equivalent = 127 minus
* the fixed words' pointer count (utility + its own arguments).
* A user-supplied -s/-n is clamped DOWN to this ceiling, never
* raised past it (documented, not silently truncated later).
* MAXFIXED (32) additionally caps how many fixed words xargs
* itself may carry, well under the 127-pointer ceiling.
*
* IF A SINGLE STDIN ARGUMENT ALONE exceeds the size budget, it
* is still run BY ITSELF (never silently dropped) -- the only
* way to guarantee forward progress without implementing -x.
*
* THE CHILD'S STDIN is CLOSED (FDACT_CLOSE, fd 0), not dup'd
* from xargs's own stdin. POSIX leaves this unspecified;
* inheriting xargs's own stdin would hand the child the SAME
* pipe/file xargs is still reading its argument stream from
* (`find ... | xargs`
* is the canonical case) -- a real race, and reading it further
* would silently desynchronize xargs's own tokenizer. A real tty
* would be the more traditional choice (GNU/BSD open /dev/tty)
* but costs an extra open() and a de-inherited fd for no gain
* here, since maux does not run xargs sessions where a child
* genuinely needs an interactive terminal xargs itself is not
* using. Closed cleanly signals "no input" to a well-behaved
* child. stdout/stderr are inherited unchanged (SC_SPAWN's own
* default: a spawned child's fd table starts as fds 0/1/2 copied
* from the parent, docs/SYSCALL.md item 10).
*
* THE CHILD IS FOUND THE SAME WAY find.s's -exec finds one
* (src/liba/pathres.s's PATHRSLV -- execvp's own PATH search,
* absolute words bypass it) -- resolved ONCE, before any
* input is read, since the template utility word never
* changes across invocations. Spawn/wait follow findact.s's
* ACT_EXEC shape (SC_SPAWN then SC_WAIT, one child at a time,
* no concurrency).
*
* EXIT STATUS. 0: every invocation exited 0 (or none ran -- no
* stdin arguments at all is NOT an error and never invokes
* utility, matching this host's own /usr/bin/xargs, checked
* empirically 2026-09-14: BSD xargs runs utility zero times on
* empty input, unlike bare POSIX's "-r not given -> run it
* once"). 123: at least one invocation exited 1-125 (noted,
* NOT fatal -- xargs keeps going). 124: an invocation exited
* >=128 (this machine's SC_WAIT status byte cannot
* distinguish "exited 255" from "killed by a signal" -- both
* are bit 7 of the one-byte legacy wait status, memory note
* "kill signo ABI" -- so both fold into this ONE fatal code
* and processing STOPS). 126: the utility resolved
* (PATHRSLV/exec found it) but SC_SPAWN itself failed (this
* machine's only such case in practice is the argv budget
* being exceeded regardless of xargs's own accounting -- e.g.
* a -I substitution that grew a line past ARG_MAX). 127: the
* utility word did not resolve against PATH at all -- checked
* once, before any invocation, so nothing ever runs. 1: usage
* errors, an unmatched quote, and "argument list too long"
* before any input is read (too many fixed words to leave any
* budget).
* -0 (SHIPPED 2026-10-08): input items end at a NUL and at
* nothing else -- blanks, newlines, quotes and backslashes are
* ordinary bytes (TOKREAD's ZFLAG branch). An empty item is
* dropped, as on BSD (GNU passes it as an empty argument; the
* hosts disagree and POSIX is silent). With -I the NUL ends a
* "line" and nothing is stripped from it.
*
* -p (SHIPPED 2026-10-08): before each invocation the command
* line is written to stderr followed by "?...", one reply line
* is read from the TERMINAL, and the utility runs only if that
* line begins with y or Y. The terminal is read as stderr, the
* house rule more.s documents (stderr stays the console when
* stdin is a file or a pipe); where stderr is not a console
* there is nobody to ask and the invocation is declined. -p
* replaces -t's trace, as POSIX has it. A declined invocation
* is not an error and does not change the exit status.
*
* NOT IMPLEMENTED: -x/-P (undocumented options
* are simply not in XAOPTS -- GETOPT reports them unrecognised,
* exit 1). -x is subsumed by the "single oversized argument
* still runs alone" rule above, which is the closest a machine
* with no process limits API can offer.
*
* 3-4 KB target; `put`s xargstok.s (tokenizer/-I/PARSEDEC) and
* xargsrun.s (batch/-I invocation engine: CALCBUDGET/RUN_NMODE/
* BUILD_BATCH/BUILD_ARGV_N/RUN_IMODE/INVOKE/TRACEPRINT) for the
* native assembler's source window -- xargstok.s alone was not
* enough headroom (2026-09-14, check_dialect.py's AS_WINDOW_OVER
* comment has the numbers); same reason as cut.s/cutlist.s.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/mm.procbnk2.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.fdact.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/xargs.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255
TOKBUF      equ   255            ;per-argument practical cap
LMAX        equ   255            ;-I line practical cap
MAXFIXED    equ   32             ;utility + its own fixed args
MAXSLOTN    equ   127            ;ARGV_PTR_LIM/2, whole pointers
REPLBUFSZ   equ   1024
REPLBUFSZ1  equ   REPLBUFSZ-1    ;leaves room for the final NUL

* -- xargs-private zero page: $30-$8F is clear of zp.equ, the
* -- kernel's $F7-$FC and every module this file `put`s
* -- (verified against sed.s's own claim for that range).
* -- All SIX need (zp),y indirect addressing; nothing else does,
* -- which is why the list is short and each entry says what
* -- dereferences it. ("All four" until 2026-09-21 -- the count
* -- had already gone stale once before -E arrived.)
XA_SRC      equ   $30            ;2 -- SUBST_ONE's source cursor
XA_MSRC     equ   $32            ;2 -- TRYMATCH's lookahead
REPLPTR     equ   $34            ;2 -- -I's replstr pointer
SOWPTR      equ   $36            ;2 -- SO_PUT1's write pointer
IB_CUR      equ   $38            ;2 -- BUILD_BATCH's INPUT_BUF
                                 ;write cursor, (IB_CUR),y'd
EOFPTR      equ   $3A            ;2 -- -E's eofstr, (EOFPTR),y'd
                                 ;by XA_ISEOFS

* -- PER-RUN RESET. A warm respawn reuses this SAME bank -- lazy
* -- free never re-zeroes the dum arena, and it may have just
* -- held a DIFFERENT program's own state at these very offsets.
* -- Every flag a later branch tests (`beq`/`bne`) before this
* -- run ever writes it must be zeroed here, not left to a fresh
* -- cold load's zero fill (cut.s/grep.s's own START does the
* -- identical `stz` sweep of its own flags).
START       stz   EFLAG
            stz   LFLAG
            stz   XA_ATEOF
            stz   NFLAG
            stz   SFLAG
            stz   TFLAG
            stz   IFLAG
            stz   PENDVALID
            stz   PFLAG
            stz   ZFLAG
            lda   #$8D
            sta   LINEDELIM
*-- AND THE INPUT CHUNK CURSORS, which were NOT reset here until
*-- 2026-09-21 and had never needed to be. BUFPOS/BUFLEN are
*-- written only by REFILL (xargstok.s), and every path through
*-- this program used to read stdin to EOF -- so a run always
*-- ended with the chunk drained and a warm respawn inherited
*-- nothing that mattered. -E is the FIRST way to stop early,
*-- and it turned that accident into a bug immediately: a run
*-- that halted at the eofstr left the rest of its chunk in
*-- CBUF, and the NEXT xargs to warm-respawn into this bank
*-- served those bytes before reading its own fd. Measured --
*-- `xargs -E STOP echo` then `xargs -E ZZZ echo` on the same
*-- three-line file printed "b a STOP b". head.s's HEADCOPY
*-- carries the identical note for the identical reason.
            stz   BUFPOS
            stz   BUFLEN
            lda   #<XAOPTS
            ldx   #>XAOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcc   :haveopt
            jmp   :optdone
:haveopt    cmp   #$C9                     ;'I'
            bne   :notI
            lda   #1
            sta   IFLAG
            lda   OPTARG
            sta   REPLPTR
            lda   OPTARG+1
            sta   REPLPTR+1
            jmp   :optlp
*-- -r IS ALREADY WHAT THIS PROGRAM DOES. POSIX's -r says: do
*-- not run the utility at all if there are no arguments on
*-- stdin. xargs.s has done exactly that since it was written --
*-- see the "no stdin arguments: utility is not invoked" row in
*-- check_posixutil -- so accepting the flag is honesty, not a
*-- stub. Refusing it made a script that says -r for portability
*-- fail on a machine that already behaves the way -r asks for.
:notI       cmp   #$F2                     ;'r' -- no-run-if-
            bne   :notr                    ;empty, the standing
            jmp   :optlp                   ;behaviour
*-- -x IS DELIBERATELY NOT ACCEPTED, and the reason is measured
*-- rather than assumed. It reads like a free no-op: POSIX's -x
*-- terminates if an argument list would exceed what -n/-s
*-- allow, and BUILD_BATCH never builds one. But this tree's
*-- oracle is the host's own xargs, and `xargs -x` with neither
*-- -n nor -s EXITS 1 AND PRINTS NOTHING there (measured
*-- 2026-09-21). Accepting the flag would make maux diverge
*-- MORE, not less. See the case file's corrected note.
:notr       cmp   #$C5                     ;'E' eofstr -- the
            bne   :notE                    ;token that ends the
            lda   #1                       ;input
            sta   EFLAG
            lda   OPTARG
            sta   EOFPTR
            lda   OPTARG+1
            sta   EOFPTR+1
            jmp   :optlp
:notE       cmp   #$CC                     ;'L' lines per run
            bne   :notL
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSEDEC
            bcs   :usageerr
            lda   PDVAL
            ora   PDVAL+1
            beq   :usageerr                ;-L 0 is meaningless
            lda   #1
            sta   LFLAG
            lda   PDVAL
            sta   LVAL
            lda   PDVAL+1
            sta   LVAL+1
            jmp   :optlp
:notL       cmp   #$EE                     ;'n'
            bne   :notn
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSEDEC
            bcs   :usageerr
            lda   #1
            sta   NFLAG
            lda   PDVAL
            sta   COUNTVAL
            lda   PDVAL+1
            sta   COUNTVAL+1
            jmp   :optlp
:notn       cmp   #$F3                     ;'s'
            bne   :nots
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSEDEC
            bcs   :usageerr
            lda   #1
            sta   SFLAG
            lda   PDVAL
            sta   SIZEVAL
            lda   PDVAL+1
            sta   SIZEVAL+1
            jmp   :optlp
:nots       cmp   #$F4                     ;'t'
            bne   :notT
            lda   #1
            sta   TFLAG
            jmp   :optlp
:usageerr   lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT
:notT       cmp   #$F0                     ;'p' prompt
            bne   :notP
            lda   #1
            sta   PFLAG
            jmp   :optlp
:notP       cmp   #$B0                     ;'0' NUL items
            bne   :usageerr
            lda   #1
            sta   ZFLAG
            stz   LINEDELIM                ;-I: NUL ends a line
            jmp   :optlp

:optdone    lda   OPTIND
            cmp   ARGC
            bcc   :haveutil
            lda   #<DEFECHO
            sta   ORIGWORD
            lda   #>DEFECHO
            sta   ORIGWORD+1
            stz   FIXEDCNT
            bra   :resolve
:haveutil   lda   OPTIND
            jsr   GETARG
            lda   PTR0
            sta   ORIGWORD
            lda   PTR0+1
            sta   ORIGWORD+1
            lda   ARGC
            sec
            sbc   OPTIND
            sec
            sbc   #1
            sta   FIXEDCNT
            cmp   #MAXFIXED
            bcc   :fbok
            jmp   :usageerr
:fbok       lda   OPTIND
            clc
            adc   #1
            sta   FIXEDBASE

:resolve    lda   ORIGWORD
            sta   PTR0
            lda   ORIGWORD+1
            sta   PTR0+1
            jsr   PATHRSLV
            bcc   :found
            lda   #<NOTFOUND1
            sta   PTR0
            lda   #>NOTFOUND1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ORIGWORD
            sta   PTR0
            lda   ORIGWORD+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<NOTFOUND2
            sta   PTR0
            lda   #>NOTFOUND2
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #127
            jsr   EXIT
:found      lda   PTR0
            sta   RESPATH
            lda   PTR0+1
            sta   RESPATH+1

            stz   FINALCODE
            lda   IFLAG
            beq   :nmode
            lda   #<REPLBUF
            sta   REPLLIM
            lda   #>REPLBUF
            sta   REPLLIM+1
            clc
            lda   REPLLIM
            adc   #<REPLBUFSZ1
            sta   REPLLIM
            lda   REPLLIM+1
            adc   #>REPLBUFSZ1
            sta   REPLLIM+1
            jsr   RUN_IMODE
            jmp   :alldone
:nmode      jsr   CALCBUDGET
            jsr   RUN_NMODE
:alldone    lda   FINALCODE
            jsr   EXIT

            put   xargsrun.s
            put   xargsinv.s

*---------------------------------------------------------------
* Data (real bytes -- outside the dum/dend arena).
*---------------------------------------------------------------
XAOPTS      asc   "I:n:s:trE:L:p0"
            dfb   0
DEFECHO     asc   "echo"
            dfb   0
USAGEMSG    asc   "usage: xargs [-n num] [-s size] [-t]"
            dfb   $8D,0
NOTFOUND1   asc   "xargs: "
            dfb   0
NOTFOUND2   asc   ": No such file or directory"
            dfb   $8D,0
TOOLONGMSG  asc   "xargs: argument list too long"
            dfb   $8D,0
XARGSPFX    asc   'xargs: '
            dfb   0
CANTINVOKE  asc   "xargs: cannot invoke utility"
            dfb   $8D,0
ABORTMSG    asc   "xargs: utility exited abnormally; aborting"
            dfb   $8D,0
UNMQMSG     asc   "xargs: unmatched quote"
            dfb   $8D,0
FDA_CLOSE0  dfb   FDACT_CLOSE,0,0
            dfb   FDACT_END

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   FD_STDIN
RPARM_BUF   da    CBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

            put   xargstok.s
            put   xargssub.s

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/spawnwhy.s
            put   ../liba/pathtab.s
            put   ../liba/pathres.s
            put   ../liba/env.s
            put   ../liba/libabss.s

            dum   LIBA_BSSEND
NFLAG       ds    1
SFLAG       ds    1
TFLAG       ds    1
IFLAG       ds    1
COUNTVAL    ds    2
SIZEVAL     ds    2
ORIGWORD    ds    2
RESPATH     ds    2
FIXEDBASE   ds    1
FIXEDCNT    ds    1
FIXEDBYTES  ds    2
REMBYTES    ds    2
REMSLOTS    ds    1
EFFSIZE     ds    2
EFFCNT      ds    1
FINALCODE   ds    1
WSTATUS     ds    1
CB_I        ds    1
BA_I        ds    1
TP_I        ds    1
BATCHCNT    ds    1
BB_BYTES    ds    2
BB_TMP      ds    2
SO_RETLO    ds    1
SO_RETHI    ds    1

PENDVALID   ds    1
EFLAG       ds    1              ;-E was given
LFLAG       ds    1              ;-L was given
LVAL        ds    2              ;.. lines per invocation
BB_LINES    ds    2              ;lines in the batch so far
TOK_EOL     ds    1              ;this token ended a line
PFLAG       ds    1              ;-p was given
ZFLAG       ds    1              ;-0 was given
LINEDELIM   ds    1              ;-I line terminator: CR, or NUL
APCNT       ds    1              ;-p reply parmlist, built
APREF       ds    1              ;at use (writable text is not
APBUF       ds    2              ;allowed -- docs/STICKY.md)
APREQ       ds    2
APTRANS     ds    2
ANSBUF      ds    8
XA_ATEOF    ds    1              ;-E's string has been seen
PENDLEN     ds    1
PENDBUF     ds    TOKBUF+1
XT_INQ      ds    1
BUFPOS      ds    1
BUFLEN      ds    1
CBUF        ds    BUFSZ

LINELEN     ds    1
LINEBUF     ds    LMAX+1
RAWLINE     ds    LMAX+1

PDVAL       ds    2
PDDIGN      ds    1
PDTMPLO     ds    1
PDTMPHI     ds    1
PDSAVLO     ds    1
PDSAVHI     ds    1

SO_START    ds    2
REPLCUR     ds    2
REPLLIM     ds    2

BATCHPTRS   ds    MAXSLOTN*2
INPUT_BUF   ds    ARG_MAX
ARGVLIST    ds    MAXSLOTN*2+2
REPLBUF     ds    REPLBUFSZ
            dend
