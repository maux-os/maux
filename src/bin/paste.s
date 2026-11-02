*---------------------------------------------------------------
* paste.s -- POSIX paste(1): merge lines of files.
*
* Usage: paste [-s] [-d list] file...
*
* At least one FILE operand is REQUIRED (POSIX's own synopsis
* has no brackets around it) -- unlike cat/head/cut, bare
* `paste` with no operand is a usage error, measured live: this
* Mac's own /usr/bin/paste prints a usage banner and exits,
* never reads fd 0 implicitly. `-` as an operand DOES mean
* stdin (checked explicitly, same idiom as cut.s's own header
* -- GETOPT treats a bare `-` as an ordinary operand, never an
* option).
*
* DEFAULT (no -s): a PARALLEL merge. Row N of the output is line
* N of every operand, joined by the delimiter list (default a
* single <tab>, $89) and terminated by one CR. A file that has
* already reached EOF contributes an EMPTY field for the rest of
* the run -- rows keep coming until EVERY file is simultaneously
* exhausted (measured: a 3-line/2-line pair produces exactly 3
* rows, not 4 -- the output stops the instant a round finds NO
* file with a real line left, not merely once ANY one file has
* dried up).
*
* -s (SERIAL): one output row PER FILE, that file's own lines
* joined by the delimiter list instead of newlines, real CR only
* at the end. A file with ZERO lines (empty) produces NO row at
* all -- not even a bare CR (measured, BSD paste).
*
* -d list: characters used AS the join delimiter, cycling
* through the list and WRAPPING as needed -- POSIX's escapes
* \n \t \\ \0 are honoured (\0 means "nothing at all" here, NOT
* a NUL byte -- measured live: `paste -d '\0' a b` puts no byte
* between fields whatsoever). The cycle RESETS to the first
* list character at the start of every output row (parallel
* mode) or at the start of every file's own row (-s) --
* measured against both a 2-character list on a 3-file merge
* and a 2-character list against a 5-line file under -s;
* continuing the cycle ACROSS rows/files, or resetting it
* mid-row, both give the wrong answer for one of those two
* fixtures. An empty -d list (`-d ''`) is a usage error, exit 2
* (this host also refuses it, with its own wording and exit 1
* -- see docs/man/paste.1).
*
* EVERY OUTPUT ROW GETS EXACTLY ONE TRAILING CR, including the
* very last one, matching cut.s's own stated convention ("a LINE
* tool"). This host agrees in PARALLEL mode even when a file's
* last line is unterminated (re-measured at review, 2026-09-14:
* `paste p1 p2` with p1 ending in a bare "b" still ends "b<tab>2
* <newline>"); only `-s` on such a file differs -- the host
* prints "a<tab>b" with NO final newline, this file prints one.
* Recorded as a known, accepted divergence (docs/POSIX-GAPS.md),
* the same shape as tail.s's own cmp_tail_noeol; no corpus row
* stages an unterminated -s fixture, so no comparator entry.
*
* TWO DIFFERENT OPEN-FAILURE POLICIES, and both come straight
* from what the two modes actually need to do with their file
* descriptors (measured, not guessed): PARALLEL mode must have
* every operand open AT ONCE to walk them in lockstep, so it
* opens all of them FIRST and, if any one fails, prints ONE
* diagnostic and exits 1 with NO output at all -- not even for
* an operand that would have opened fine (same as cmp.s's own
* OPENERR shape, which never touches a second file after the
* first one fails to open). SERIAL mode never needs more than
* one file open at a time, so it opens, drains and closes each
* operand in turn -- a failure prints a diagnostic, is SKIPPED,
* and the run continues with whatever operands remain; the exit
* status is still 1 if anything failed to open.
*
* PARALLEL MODE'S FILE CAP: MAXFILES below (5) is not arbitrary.
* inc/mm.annex2.equ's PCB_FDTABLE is 8 fds per process,
* a HARD LIMIT, and fd 0/1/2 (stdin/stdout/stderr) are already
* three of those -- leaving 5 that parallel mode can hold open
* AT THE SAME TIME. A 6th operand is refused (usage, exit 2)
* before any file is opened. -s mode has no such cap; it never
* holds more than one operand's fd at a time.
*
* LINES LONGER THAN LINEMAX ($FF) truncate the same way cut.s's
* own GETLINE truncates -- bytes past the limit are dropped and
* scanning resumes at the next CR.
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
            dsk   ../../build/paste.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255
LINEMAX     equ   255
MAXFILES    equ   5
MAXDELIM    equ   8
BKSLASH     equ   $DC              ;'\' high-bit
ESC_N       equ   $EE              ;'n'
ESC_T       equ   $F4              ;'t'
ESC_0       equ   $B0              ;'0'

START       stz   WANT_S
            lda   #$89
            sta   DELIMTAB
            lda   #1
            sta   DCOUNT

            lda   #<PASTOPTS
            ldx   #>PASTOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$F3                  ;'s'
            bne   :notd
            lda   #1
            sta   WANT_S
            bra   :optlp
:notd       cmp   #$E4                  ;'d'
            bne   :usageerr
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSEDLM
            bra   :optlp
:usageerr   jmp   USAGEEXIT

:optdone    lda   ARGC
            sec
            sbc   OPTIND
            beq   :usageerr2             ;>=1 FILE is required
            sta   NFILES
            stz   ERRFLAG
            lda   WANT_S
            bne   :doserial
            jmp   PARDISP
:doserial   jmp   SERIALRUN
:usageerr2  jmp   USAGEEXIT

*---------------------------------------------------------------
* PARSEDLM -- parse the -d option-argument at PTR0 (NUL-
* terminated, high-bit ASCII) into DELIMTAB/DCOUNT. Grammar per
* character: a plain byte, or a backslash followed by one of
* n/t/\/0 (CR $8D, tab $89, a literal backslash, or "nothing").
* An empty list, an unknown escape, a trailing lone backslash,
* or more than MAXDELIM entries are all usage errors.
*---------------------------------------------------------------
PARSEDLM    ldy   #0
            stz   DCOUNT
:ploop      lda   (PTR0),y
            beq   :pdone
            cmp   #BKSLASH
            bne   :pstore
            iny
            lda   (PTR0),y
            beq   :usageerr3
            cmp   #ESC_N
            beq   :pnl
            cmp   #ESC_T
            beq   :ptab
            cmp   #BKSLASH
            beq   :pbs
            cmp   #ESC_0
            beq   :pnone
            bra   :usageerr3
:pnl        lda   #$8D
            bra   :pstore
:ptab       lda   #$89
            bra   :pstore
:pbs        lda   #BKSLASH
            bra   :pstore
:pnone      lda   #0
:pstore     ldx   DCOUNT
            cpx   #MAXDELIM
            bcs   :usageerr3
            sta   DELIMTAB,x
            inc   DCOUNT
            iny
            bra   :ploop
:pdone      lda   DCOUNT
            beq   :usageerr3
            rts
:usageerr3  jmp   USAGEEXIT

*---------------------------------------------------------------
* USAGEEXIT -- usage banner to stderr, exit 2.
*---------------------------------------------------------------
USAGEEXIT   lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* TOOMANYERR -- more than MAXFILES operands in parallel mode.
*---------------------------------------------------------------
TOOMANYERR  lda   #<TOOMANYMSG
            sta   PTR0
            lda   #>TOOMANYMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* EMITDELIM -- print DELIMTAB[DIDX] (nothing if the resolved
* byte is 0, the \0 escape) then advance/wrap DIDX by DCOUNT.
* PRESERVES: X.
*---------------------------------------------------------------
EMITDELIM   phx
            ldx   DIDX
            lda   DELIMTAB,x
            beq   :advance
            pha
            ldx   #FD_STDOUT
            pla
            jsr   PUTC
:advance    inc   DIDX
            lda   DIDX
            cmp   DCOUNT
            bcc   :ret
            stz   DIDX
:ret        plx
            rts

*---------------------------------------------------------------
* pastepar.s -- paste's PARALLEL (non -s) mode: PARDISP/OPENALL/
* CLOSEALL/CBUFBASE/LBUFBASE/GETBYTEM/REFILLM/GETLINEM/
* EMITFIELDM/MERGERUN. `put` by src/bin/paste.s (NOT a
* standalone binary -- the same put-module shape as cut.s's own
* cutlist.s), split out for the same reason units split
* anywhere: `as`'s 16,128-byte source window holds the resident
* manifest plus one put file at a time, and paste.s's own text
* alone was past it (measured: 18,690 B stripped, over by
* 2,562). Every symbol here resolves against paste.s's own
* equates (MAXFILES/BUFSZ), zero-page pointers (PTR1/PTR2), data
* (SRCFDA/BUFPOSA/BUFLENA/EOFFLGA/LINELENA/CBUFALL/LBUFALL/
* CBB_IDX/LBB_IDX/EFM_LEN/FSLOT/NFILES/ARGIDX/OPTIND/DIDX/
* OPARM*/RPARM*/CPARM*/PATHBUF) and EMITDELIM/USAGEEXIT/
* TOOMANYERR/OPENMSG -- see that file's own header for the
* row/termination rule this codifies.
*---------------------------------------------------------------
            put   pastepar.s


*===============================================================
* SERIAL MODE (-s)
*===============================================================
SERIALRUN   lda   OPTIND
            sta   ARGIDX
:srloop     lda   ARGIDX
            jsr   GETARG
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD
            bne   :srreal
            iny
            lda   (PTR0),y
            bne   :srreal
            lda   #FD_STDIN
            sta   SFD
            bra   :sropen
:srreal     lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :srfail
            lda   OPARM_REF
            sta   SFD

:sropen     stz   SBUFPOS
            stz   SBUFLEN
            stz   DIDX
            stz   SFIRST
:sloop      jsr   GETLINES
            bcs   :sdone
            lda   SFIRST
            beq   :snodelim
            jsr   EMITDELIM
:snodelim   jsr   EMITLINES
            lda   #1
            sta   SFIRST
            bra   :sloop
:sdone      lda   SFIRST
            beq   :snorow
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:snorow     lda   SFD
            cmp   #FD_STDIN
            beq   :srnext
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
:srnext     inc   ARGIDX
            lda   ARGIDX
            cmp   ARGC
            bcc   :srloop
            bra   :srdone
:srfail     lda   #<OPENMSG
            sta   PTR0
            lda   #>OPENMSG
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
            bra   :srnext
:srdone     lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* GETLINES/GETBYTES/REFILLS/EMITLINES -- single-file line I/O
* for serial mode (one operand open at a time, so no per-file
* array or indirect addressing is needed -- same shape as
* cut.s's own GETLINE/GETBYTE/REFILL).
*---------------------------------------------------------------
GETLINES    stz   SLINELEN
:gsloop     jsr   GETBYTES
            bcs   :gseof
            cmp   #$8D               ;either terminator -- see
            beq   :gshave            ;wc.s's own note
            cmp   #$0D
            beq   :gshave
            ldy   SLINELEN
            cpy   #LINEMAX
            bcs   :gsloop
            sta   SLINEBUF,y
            inc   SLINELEN
            bra   :gsloop
:gshave     clc
            rts
:gseof      lda   SLINELEN
            beq   :gsnone
            clc
            rts
:gsnone     sec
            rts

GETBYTES    ldx   SBUFPOS
            cpx   SBUFLEN
            bcc   :have
            jsr   REFILLS
            bcs   :eof
            ldx   SBUFPOS
:have       lda   SCBUF,x
            inc   SBUFPOS
            clc
            rts
:eof        sec
            rts

REFILLS     lda   SFD
            sta   RPARM_REF
            lda   #<SCBUF
            sta   RPARM_BUF
            lda   #>SCBUF
            sta   RPARM_BUF+1
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :eof
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :eof
            lda   RPARM_TRANS
            sta   SBUFLEN
            stz   SBUFPOS
            clc
            rts
:eof        sec
            rts

EMITLINES   ldy   #0
:eloop      cpy   SLINELEN
            bcs   :edone
            lda   SLINEBUF,y
            ldx   #FD_STDOUT
            jsr   PUTC
            iny
            bra   :eloop
:edone      rts

USAGEMSG    asc   "usage: paste [-s] [-d list] file ..."
            dfb   $8D,$00
TOOMANYMSG  asc   "paste: too many files (max "
            asc   "5)"
            dfb   $8D,$00
OPENMSG     asc   "paste: cannot open "
            dfb   $00
PASTOPTS    asc   "sd:"
            dfb   0

OPARM       dfb   OPEN_RO
OPARM_PATH  da    PATHBUF
OPARM_IOBUF da    $0000
OPARM_REF   dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    SCBUF
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
            put   ../liba/libabss.s

*---------------------------------------------------------------
* paste's bss -- `dum`/`dend` off LIBA_BSSEND (docs/STICKY.md
* sec 21, learning:01M0FNC75R7YSFRNS328WHXMHN). NOTHING ZEROES
* THIS ARENA:
*  - WANT_S/DELIMTAB[0]/DCOUNT: START's opening run stores all
*    three before GETOPT can read any of them.
*  - ERRFLAG/NFILES: written right after option parsing.
*  - ARGIDX: `sta` before the loop that is its only reader, in
*    every path (OPENALL/SERIALRUN each set it themselves).
*  - DIDX: `stz`'d at the top of every row (MERGERUN) or every
*    file (SERIALRUN), before EMITDELIM's first read.
*  - PRODUCED: `stz`'d at MERGERUN's :roundloop, every round.
*  - SRCFDA/BUFPOSA/BUFLENA/EOFFLGA/LINELENA: MERGERUN's own
*    :initlp zeroes the first three for 0..NFILES-1 before any
*    reader; LINELENA is `stz`'d by GETLINEM (or the empty-field
*    path) every round, per file; SRCFDA is written by OPENALL
*    before MERGERUN ever runs.
*  - CBB_IDX/LBB_IDX: CBUFBASE/LBUFBASE's own first store.
*  - EFM_LEN: EMITFIELDM's own first store.
*  - FSLOT: `stz`'d at OPENALL's own entry -- the file-slot
*    index, carried here rather than in X because GETARG's own
*    body ends `asl a / tax`, clobbering X on every call.
*  - SFD/SBUFPOS/SBUFLEN/SLINELEN/SFIRST: SERIALRUN sets SFD
*    per operand and `stz`'s the rest at :sropen, every operand.
*  - PATHBUF: MKPATH writes chars then the count byte.
*  - CBUFALL/LBUFALL: filled by REFILLM/GETLINEM, indexed only
*    below BUFLENA,x / LINELENA,x for the CURRENT file.
*  - SCBUF/SLINEBUF: filled by REFILLS/GETLINES, same reasoning,
*    single-file scalars.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
WANT_S      ds    1
DCOUNT      ds    1
DELIMTAB    ds    MAXDELIM
DIDX        ds    1
ERRFLAG     ds    1
NFILES      ds    1
ARGIDX      ds    1
PRODUCED    ds    1
CBB_IDX     ds    1
LBB_IDX     ds    1
EFM_LEN     ds    1
FSLOT       ds    1

SRCFDA      ds    MAXFILES
BUFPOSA     ds    MAXFILES
BUFLENA     ds    MAXFILES
EOFFLGA     ds    MAXFILES
LINELENA    ds    MAXFILES

SFD         ds    1
SBUFPOS     ds    1
SBUFLEN     ds    1
SLINELEN    ds    1
SFIRST      ds    1

PATHBUF     ds    65
SCBUF       ds    BUFSZ
SLINEBUF    ds    LINEMAX+1
CBUFALL     ds    MAXFILES*256
LBUFALL     ds    MAXFILES*256
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window (see src/bin/cut.s for the
* -- full note).
            err   */$BF00
            dend
