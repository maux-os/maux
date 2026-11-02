*---------------------------------------------------------------
* shsgblt.s -- `command`, `type`, `eval`, `exec`, `readonly` and
* `times`, segment-resident. This file is `put` inside sh.s's
* `org PRC_LC_COMMON` block, so every label here resolves at
* $E000+ and the low image keeps only the `jsr`s into it.
* docs/SH-SUBSET.md ruling 7.6 has the mechanism (SEG_INIT, the
* low copy, the two tripwires); docs/SH-FEATURES.md sec 29 has
* the semantics and the divergences.
*
* NOTHING HERE MAY BE REACHED BEFORE SEG_INIT RAN -- it is the
* first thing START (shlex.s) does.
*
* AND NOTHING WRITABLE MAY LIVE HERE. SEG_INIT leaves the
* language card WRITE-PROTECTED, so every scratch cell is in
* sh.s's `dum` arena (which costs no image bytes at all), never
* a `ds` in this file.
*
* AND NOTHING HERE MAY BE HANDED TO A SYSCALL. COPYIN_ENTRY/
* COPYOUT_ENTRY (src/kernel/entry2.s) refuse a process address
* >= $D000, and BankCopy -- the path a tty or file write's
* BUFFER takes -- is built on them. Every string PUTS or
* PR_ERRAX sees is in shblt3.s, low.
*
* WHAT STAYED HERE, and it is the one refinement on shsgtrp.s/
* shsggop.s's precedent: the builtin NAME strings and BLTTAB.
* They are read ONLY by STRCMPI, i.e. by this process's own CPU
* through `lda (PTR1),y`, which never touches the kernel at all
* -- so the >= $D000 wall does not apply to them, and keeping
* them beside their code costs the low image nothing. Only the
* bytes a WRITE ever sees had to go down.
*---------------------------------------------------------------

*---------------------------------------------------------------
* SB_MATCH -- the dispatch preamble every builtin in this file
* opens with, factored because six copies of it is 150 bytes of
* the same twelve instructions. IN: PTR1 = the builtin's name.
* OUT: carry CLEAR = this segment is a single unpiped command
* (NCMD==1) whose argv[0] is that name; carry SET otherwise.
*
* CASE-INSENSITIVE (STRCMPI, not STRCMP) -- docs/SH-CASE.md:
* the tables hold UPPERCASE names and ProDOS folds pathnames,
* so a case-sensitive compare would make `cd` fail while `CD`
* worked. CLOBBERS: A, Y, PTR0. PRESERVES: X, PTR1.
*
* NCMD==1 is the same command-position rule CD/EXIT/TEST/EXPORT
* already use, and it carries the same v1 limitation: a builtin
* named in a PIPELINE stage (`CAT | TYPE X`) is not recognised
* and is spawned, which fails "command not found". Pre-existing
* for every builtin in this shell; recorded, not introduced.
*---------------------------------------------------------------
SB_MATCH    lda   NCMD
            cmp   #1
            bne   :sbmno
            lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
            jsr   STRCMPI
            beq   :sbmyes
:sbmno      sec
            rts
:sbmyes     clc
            rts

*---------------------------------------------------------------
* SB_NOREDIR -- the shared redirect refusal for the builtins in
* this file that PRINT (`type`, `times`, `readonly`, `command
* -v`/`-V`) and for `eval`, whose redirect would belong to the
* line it re-runs rather than to itself.
*
* OUT: carry CLEAR = no redirection on this segment, carry SET =
* refused (diagnostic printed, LASTSTATUS 1, caller returns
* "handled"). CLOBBERS: A, X.
*
* WHY REFUSE RATHER THAN HONOUR. See shblt3.s's BLT_NORDR_M
* comment: a builtin dispatches BEFORE RUN_PIPELINE stages
* redirection, and CHCK_BLTN_ECH measured what happens when a
* builtin drives the shell's single shared set of redirect
* parmlists itself -- the NEXT command's output file came back
* empty. `echo` can fall through to /bin/ECHO when it
* meets a shape it will not do; these five have no binary twin,
* so a refusal is the only answer that is not a silent wrong
* one. `exec` is the exception and does its own (SB_EXECRD):
* applying the redirection IS the feature there.
*---------------------------------------------------------------
SB_NOREDIR  lda   CMD_INFILE+0
            ora   CMD_INFILE+1
            bne   :sbnrref
            lda   CMD_OUTFILE+0
            ora   CMD_OUTFILE+1
            bne   :sbnrref
            lda   DUPN
            bne   :sbnrref
            clc
            rts
:sbnrref    lda   #<BLT_NORDR_M
            ldx   #>BLT_NORDR_M
            jsr   PR_ERRAX1
            sec
            rts

*---------------------------------------------------------------
* SB_POUT / SB_PRNM / SB_PRNL -- print A/X (a LOW string), the
* name SB_WHAT is reporting on, and one newline, all to stdout.
* PUTS declares PTR0 volatile, so every piece is reloaded rather
* than carried. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
SB_POUT     sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS
SB_PRNM     lda   SBNAME
            ldx   SBNAME+1
            jmp   SB_POUT
SB_PRNL     lda   #<BLT_NL_M
            ldx   #>BLT_NL_M
            jmp   SB_POUT

*---------------------------------------------------------------
* SB_ISBLTN -- IN: PTR0 = a NUL-terminated name. OUT: A (and the
* Z flag) = 0 not one of ours, 1 a shell BUILTIN, 2 a RESERVED
* WORD. PRESERVES PTR0 (STRCMPI's own contract). CLOBBERS: A, X,
* Y, PTR1.
*
* Two tables, because the two answers have different wording and
* POSIX's `command -v` reports both. The builtins are BLTTAB
* below -- NUL-separated, an empty entry ends it, exactly
* PATHTAB's own shape. The keywords are NOT copied: RESV_LO/HI
* (shrsv2.s) is CHCK_RESERVED's own table and is the single
* source of truth for what this shell treats as reserved, so a
* keyword added there is reported here the same day. SPOOL_
* ADJNEST (shtrap.s) already reuses it the same way.
*---------------------------------------------------------------
SB_ISBLTN   lda   #<BLTTAB
            sta   PTR1
            lda   #>BLTTAB
            sta   PTR1+1
:sbiloop    ldy   #0
            lda   (PTR1),y
            beq   :sbikw
            jsr   STRCMPI
            beq   :sbiblt
            ldy   #0
:sbiadv     lda   (PTR1),y
            beq   :sbiadvd
            iny
            bne   :sbiadv
:sbiadvd    iny                          ;step past the NUL too
            tya
            clc
            adc   PTR1
            sta   PTR1
            lda   PTR1+1
            adc   #0
            sta   PTR1+1
            bra   :sbiloop
:sbiblt     lda   #1
            rts
*-- Reserved words, through CHCK_RESERVED's own table. STRCMPI
*-- preserves X (string.s's contract), so the cursor survives
*-- the compare without being spilled.
:sbikw      ldx   #0
:sbikloop   cpx   #RESV_CNT
            beq   :sbinone
            lda   RESV_LO,x
            sta   PTR1
            lda   RESV_HI,x
            sta   PTR1+1
            jsr   STRCMPI
            beq   :sbiiskw
            inx
            bra   :sbikloop
:sbiiskw    lda   #2
            rts
:sbinone    lda   #0
            rts

*---------------------------------------------------------------
* SB_WHAT -- the whole of `type NAME` and `command -v/-V NAME`.
* IN: PTR0 = the name, SBVERB = 0 (terse, `command -v`) or 1
* (verbose, `type` and `command -V`). OUT: SBSTAT set to 1 if
* the name resolved to nothing (the caller ORs it into
* LASTSTATUS; POSIX's exit status for `type` is nonzero if ANY
* operand was not found, which is why the flag is sticky and
* the caller clears it once).
*
* Terse:   a builtin/keyword prints as its own name; a found
*          command prints as its resolved pathname; nothing
*          found prints NOTHING at all (POSIX: `command -v` is
*          silent on failure).
* Verbose: "NAME is a shell builtin" / "... keyword" / "NAME is
*          /bin/NAME" on stdout, "NAME: not found" on
*          stderr.
*
* A NAME CONTAINING A '/' (ANYWHERE: `./x`, `dir/x`) IS NOT
* PATH-SEARCHED, and is probed relative to the cwd. POSIX says
* `command -v` writes such a name unchanged; this goes one step
* further and PROBES it (PATH_EXISTS, an open-and-close), so
* `type /mnt/MAUX/NOSUCH` says "not found" rather than
* confidently
* naming a file that is not there. Without the check BUILD_PATH
* would build "/bin//bin/ECHO" and report every
* absolute path as missing.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
SB_WHAT     lda   PTR0
            sta   SBNAME
            lda   PTR0+1
            sta   SBNAME+1
            jsr   SB_ISBLTN
            sta   SBKIND
            beq   :sbwpath
            lda   SBVERB
            bne   :sbwvblt
            jsr   SB_PRNM
            jmp   SB_PRNL
:sbwvblt    jsr   SB_PRNM
            lda   SBKIND
            cmp   #2
            beq   :sbwvkw
            lda   #<BLT_ISBLT_M
            ldx   #>BLT_ISBLT_M
            jmp   SB_POUT
:sbwvkw     lda   #<BLT_ISKW_M
            ldx   #>BLT_ISKW_M
            jmp   SB_POUT
*-- Not a builtin: resolve it the way the spawn path would.
:sbwpath    lda   SBNAME
            sta   PTR0
            lda   SBNAME+1
            sta   PTR0+1
            lda   #<SH_TPATHBUF          ;a slash name is a
            sta   PTR1                   ;path, never searched
            lda   #>SH_TPATHBUF          ;(CMDSLASH): PTR0 comes
            sta   PTR1+1                 ;back resolved
            jsr   CMDSLASH
            bcs   :sbwsrch
            jsr   PATH_EXISTS            ;reads PTR0, as
            bcs   :sbwnone               ;  BUILD_PATH's own
            lda   SBNAME                 ;  :built call does
            sta   SBPATH
            lda   SBNAME+1
            sta   SBPATH+1
            bra   :sbwrep
:sbwsrch    jsr   BUILD_PATH             ;carry set = table
            bcs   :sbwnone               ;  exhausted
            lda   #<SH_PATHFULL
            sta   SBPATH
            lda   #>SH_PATHFULL
            sta   SBPATH+1
:sbwrep     lda   SBVERB
            bne   :sbwvpth
            lda   SBPATH
            ldx   SBPATH+1
            jsr   SB_POUT
            jmp   SB_PRNL
:sbwvpth    jsr   SB_PRNM
            lda   #<BLT_IS_M
            ldx   #>BLT_IS_M
            jsr   SB_POUT
            lda   SBPATH
            ldx   SBPATH+1
            jsr   SB_POUT
            jmp   SB_PRNL
:sbwnone    lda   #1
            sta   SBSTAT
            lda   SBVERB
            beq   :sbwquit
            lda   SBNAME
            sta   PTR0
            lda   SBNAME+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<BLT_NOTFN_M
            sta   PTR0
            lda   #>BLT_NOTFN_M
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
:sbwquit    rts

*---------------------------------------------------------------
* CHCK_BLTN_CMD -- `command [-v|-V] NAME [ARG...]` (POSIX XCU).
*
* THE PLAIN FORM COSTS ALMOST NOTHING, and that is the design.
* `command NAME ARG...` means "run NAME, bypassing functions".
* This shell has no functions, so all that is left is "run
* NAME" -- and the cheapest correct way to say that is to drop
* our own word from argv (RW_SHIFT, shparse.s -- the reserved-
* word shifter, which already zeroes the vacated trailing slot
* a child's argv walk would otherwise read as one argument too
* many) and return carry CLEAR. The dispatch chain below simply
* carries on against the shifted argv, so `command cd X` runs
* the CD builtin and `command cat F` spawns cat -- which is
* exactly POSIX's rule that builtins are still found.
*
* This routine therefore sits FIRST in the chain, above
* CHCK_BLTN_EXT, so `command exit` can reach `exit`.
*
* `-v`/`-V` are compared with STRCMP, NOT STRCMPI, and that is
* deliberate against docs/SH-CASE.md's general "fold the
* operands with the verb" rule: here the two spellings MEAN
* DIFFERENT THINGS, so folding them would silently merge the
* terse form into the verbose one. The verb `command` itself is
* still folded.
*
* OUT: carry SET = handled here (a -v/-V report, or a refusal);
* carry CLEAR = either not `command` at all, or the plain form,
* whose argv has been shifted for the chain below. CLOBBERS: A,
* X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
CHCK_BLTN_CMD
            lda   #<SB_CMD_STR
            sta   PTR1
            lda   #>SB_CMD_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :cmiscmd
            clc
            rts
:cmiscmd    lda   CMD_ARGC+0
            cmp   #2
            bcs   :cmhaveop
            stz   LASTSTATUS            ;bare `command`: nothing
            sec                         ;to run, and POSIX makes
            rts                         ;that a success
:cmhaveop   lda   CMD_ARGV+2
            sta   PTR0
            lda   CMD_ARGV+3
            sta   PTR0+1
            lda   #<SB_DV_STR
            sta   PTR1
            lda   #>SB_DV_STR
            sta   PTR1+1
            jsr   STRCMP
            beq   :cmterse
            lda   #<SB_DVV_STR
            sta   PTR1
            lda   #>SB_DVV_STR
            sta   PTR1+1
            jsr   STRCMP
            beq   :cmverb
            jsr   RW_SHIFT               ;plain form -- hand the
            clc                          ;real command word to
            rts                          ;the chain below
:cmterse    stz   SBVERB
            bra   :cmrep
:cmverb     lda   #1
            sta   SBVERB
:cmrep      jsr   SB_NOREDIR
            bcs   :cmdone
            lda   CMD_ARGC+0
            cmp   #3
            bcs   :cmhavenm
            lda   #1                     ;`command -v` with no
            sta   LASTSTATUS             ;NAME -- a usage error
            sec
            rts
:cmhavenm   stz   SBSTAT
            lda   CMD_ARGV+4
            sta   PTR0
            lda   CMD_ARGV+5
            sta   PTR0+1
            jsr   SB_WHAT
            lda   SBSTAT
            sta   LASTSTATUS
:cmdone     sec
            rts

*---------------------------------------------------------------
* CHCK_BLTN_TYP -- `type NAME...` (POSIX XCU). Always verbose;
* the exit status is 1 if ANY operand resolved to nothing, 0
* otherwise, which is why SBSTAT is cleared once here and only
* ever set by SB_WHAT. A bare `type` with no operands is a
* silent success, matching this host's own /bin/sh.
* OUT: carry SET = handled. CLOBBERS: A, X, Y, PTR0-PTR2.
*---------------------------------------------------------------
CHCK_BLTN_TYP
            lda   #<SB_TYP_STR
            sta   PTR1
            lda   #>SB_TYP_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :tyis
            clc
            rts
:tyis       jsr   SB_NOREDIR
            bcs   :tydone
            stz   SBSTAT
            lda   #1
            sta   SBVERB
            lda   #1
            sta   SBI
:tyloop     lda   SBI
            cmp   CMD_ARGC+0
            beq   :tyend
            asl   a
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            jsr   SB_WHAT
            inc   SBI
            bra   :tyloop
:tyend      lda   SBSTAT
            sta   LASTSTATUS
:tydone     sec
            rts

*---------------------------------------------------------------
* CHCK_BLTN_EVL -- `eval [ARG...]` (POSIX XCU): join the
* operands with single spaces and run the result as a command
* line, in THIS shell.
*
* NO TEMP FILE AND NO SECOND PARSER. The shell already has an
* entry point for "run whatever is in LINEBUF" -- SH_RUNLINE
* (shlex.s), which the trap pump and the exit trap both use --
* so `eval` is a concatenation plus a `jmp` there. The operands
* arrive already expanded and quote-stripped, and SH_RUNLINE
* expands them AGAIN, which is precisely POSIX's two passes.
*
* THE CONCATENATION IS BUILT IN RAWLINE, NOT LINEBUF, and that
* is load-bearing: a word that needed no expansion is never
* copied to EXPBUF, so CMD_ARGV can point straight INTO LINEBUF
* (DOEXPAND only runs for a word holding a `$`). Building the
* new line over the top of the old one would overwrite the very
* bytes being read. RAWLINE is the pristine copy SH_RUNLINE
* takes for console-loop spooling; no spool is in progress at a
* dispatch (SPOOL_DONE finishes before a spooled body ever
* runs), and SH_RUNLINE's own first act is to rewrite RAWLINE
* from LINEBUF, so the borrow ends at the `jmp`.
*
* DIVERGENCE, documented rather than hidden (docs/SH-FEATURES.md
* sec 29): `eval` ABANDONS THE REST OF ITS OWN LINE. `EVAL X ;
* ECHO DONE` runs X and never runs the `ECHO`. That is the same
* shape `.` (CHCK_BLTN_DOT) has had since Tier 3 -- "a bare `.`
* is meant to stand alone" -- and it comes from the same place:
* both replace the line the dispatch loop is walking.
* OUT: carry SET = handled (or refused); never returns on the
* success path. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
CHCK_BLTN_EVL
            lda   #<SB_EVL_STR
            sta   PTR1
            lda   #>SB_EVL_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :evis
            clc
            rts
:evis       jsr   SB_NOREDIR
            bcs   :evdone
            lda   CMD_ARGC+0
            cmp   #2
            bcs   :evhave
            stz   LASTSTATUS             ;bare `eval` is a
            sec                          ;successful no-op
            rts
:evhave     stz   SBLEN
            lda   #1
            sta   SBI
:evloop     lda   SBI
            cmp   CMD_ARGC+0
            beq   :evrun
            cmp   #1
            beq   :evnosp
            lda   #$A0                   ;' ' -- one separator
            jsr   SB_EVPUT               ;between operands
            bcs   :evlong
:evnosp     lda   SBI
            asl   a
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            ldy   #0
:evcpy      lda   (PTR0),y
            beq   :evcpyd
            phy
            jsr   SB_EVPUT
            ply
            bcs   :evlong
            iny
            bne   :evcpy
:evcpyd     inc   SBI
            bra   :evloop
:evlong     lda   #<EVAL_LONG_M
            ldx   #>EVAL_LONG_M
            jsr   PR_ERRAX1
:evdone     sec
            rts
*-- Publish it: terminate RAWLINE, copy it over LINEBUF, set
*-- LINELEN to the length the way SH_EXIT's own trap-string
*-- stuffer does, and hand it to the engine.
*-- SH-EXECLOOP: this line is a STRING (SH_RUNSTR), not the file
*-- position LINE_MARK names: a loop in it must spool and never
*-- seek back, and spooling must never read the caller's lines.
:evrun
            ldx   SBLEN
            lda   #0
            sta   RAWLINE,x
            stx   LINELEN
            ldy   #0
:evpub      lda   RAWLINE,y
            sta   LINEBUF,y
            beq   :evpubd
            iny
            bne   :evpub
:evpubd     jmp   SH_RUNSTR

*---------------------------------------------------------------
* SB_EVPUT -- append A to RAWLINE at SBLEN. OUT: carry SET if
* the line is full (LINEMAX bytes of text plus the terminator
* RAWLINE always has room for). CLOBBERS: A, X.
*---------------------------------------------------------------
SB_EVPUT    ldx   SBLEN
            cpx   #LINEMAX
            bcs   :evpfull
            sta   RAWLINE,x
            inc   SBLEN
            clc
            rts
:evpfull    sec
            rts

*---------------------------------------------------------------
* CHCK_BLTN_XEC -- `exec [COMMAND [ARG...]]` (POSIX XCU).
*
* TWO FORMS, AND THEY ARE DIFFERENT FEATURES.
*
* (1) `exec >FILE` / `exec 2>&1` / `exec <FILE` -- redirection
* with no command. POSIX makes it PERMANENT: the shell's own
* fds are changed for the rest of its life. This is the form
* scripts actually use, and maux can do it exactly, because the
* kernel has a real dup2 (SYS_DUP2, src/liba/syscallp.s). Open
* the target, dup2 it onto the fd the redirection named, close
* the temporary. No fdactions list, no child.
*
* (2) `exec COMMAND` -- POSIX replaces the shell's process
* image. MAUX HAS NO exec SYSCALL: a process is a bank and
* spawn is the only way to start a program (docs/ARCHITECTURE.
* md). The honest approximation, and the DOCUMENTED divergence
* (docs/SH-FEATURES.md sec 29): run COMMAND through the ordinary
* pipeline path, then leave the shell with its status. The
* observable difference from real `exec` is the extra bank the
* shell occupies while the child runs, and that `$$` does not
* become the child's pid.
*
* Form (2) runs COMMAND as an EXTERNAL command (RUN_PIPELINE),
* not as a builtin -- `exec echo hi` spawns /bin/ECHO.
* That is what a real `exec` does too, since a builtin has no
* image to replace the shell with.
* OUT: carry SET = handled; form (2) never returns.
* CLOBBERS: A, X, Y, PTR0-PTR2.
*---------------------------------------------------------------
CHCK_BLTN_XEC
            lda   #<SB_XEC_STR
            sta   PTR1
            lda   #>SB_XEC_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :xcis
            clc
            rts
:xcis       lda   CMD_ARGC+0
            cmp   #2
            bcs   :xcrun
            jsr   SB_EXECRD
            sec
            rts
:xcrun      jsr   RW_SHIFT
            jsr   RUN_PIPELINE           ;sets LASTSTATUS
            lda   LASTSTATUS
            jmp   SH_EXIT                ;runs the exit trap,
                                         ;then leaves

*---------------------------------------------------------------
* SB_EXECRD -- apply this segment's redirections to the SHELL's
* OWN fds, permanently. `<FILE` onto fd 0, then the redirect
* list in the SOURCE ORDER the parser recorded it (KFIX3 item
* 1): the `N>&M`/`N>&-` records written before the first file
* redirect (DUP_POS 0), that redirect (`>FILE`/`>>FILE`/`N>FILE`
* onto CMD_TGTFD), then everything after it (DUP_POS 1) -- the
* dups and every later file redirect, each opened as it is
* reached.
*
* That is POSIX's left-to-right rule exactly: `exec >FILE 2>&1`
* puts BOTH streams in the file, and `exec 2>&1 >FILE` leaves
* fd 2 on the old fd 1. (This routine used to apply the file
* first and every dup after it, which got the second idiom
* wrong, and kept only the last of two file redirects.)
* DUP_STG is not consulted: NCMD==1 here by SB_MATCH's own rule,
* so every record belongs to stage 0.
*
* `exec <FILE` when the shell is READING ITS SCRIPT from fd 0
* really does re-point the script source. That is POSIX's
* behaviour, not an accident of this implementation.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
SB_EXECRD   jsr   SIO_FLUSHALL         ;buffered output stays
            lda   CMD_INFILE+0
            ora   CMD_INFILE+1
            beq   :xrnoin
            lda   CMD_INFILE+0
            sta   PTR0
            lda   CMD_INFILE+1
            sta   PTR0+1
            jsr   OPEN_REDIR_RD
            bcs   :xrfail
            ldx   #FD_STDIN
            jsr   SB_DUPCL
            bcs   :xrfail
:xrnoin     lda   #0
            jsr   SB_EXREC               ;the records before it
            bcs   :xrfail
            lda   CMD_OUTFILE+0
            ora   CMD_OUTFILE+1
            beq   :xrnoout
            lda   CMD_OUTFILE+0
            sta   PTR0
            lda   CMD_OUTFILE+1
            sta   PTR0+1
            lda   CMD_APPEND+0
            beq   :xrtrunc
            jsr   OPEN_REDIR_AP
            bra   :xropend
:xrtrunc    jsr   OPEN_REDIR_WR
:xropend    bcs   :xrfail
            ldx   CMD_TGTFD+0
            jsr   SB_DUPCL
            bcs   :xrfail
:xrnoout    lda   #1
            jsr   SB_EXREC               ;and the ones after
            bcs   :xrfail
            stz   LASTSTATUS
            rts
:xrfail     lda   #<EXEC_RD_M
            ldx   #>EXEC_RD_M
            jsr   PR_ERRAX1
            rts

*---------------------------------------------------------------
* SB_EXREC -- apply the redirect-list records of ONE position to
* the shell's own fds, in order. IN: A = 0 (before the first
* file redirect) or 1 (after it). Each record is a dup (`N>&M`,
* SC_DUP2), a close (`N>&-`) or a FILE (a later `>`/`N>`/`>>`:
* open it, then SB_DUPCL onto the target). OUT: carry SET on a
* failure. CLOBBERS: A, X, Y, PTR0-PTR2.
*---------------------------------------------------------------
SB_EXREC    sta   SBPOS
            stz   SBI
:xrloop     ldx   SBI
            cpx   DUPN
            beq   :xrdone
            lda   DUP_POS,x
            cmp   SBPOS
            bne   :xrnext
            lda   DUP_TGT,x
            sta   SBTGT
            lda   DUP_SRC,x
            cmp   #$FF                   ;`N>&-` -- a close
            beq   :xrcls
            cmp   #FREC_RD
            bcs   :xrfile                ;a FILE record
            ldx   SBTGT
            jsr   UFD_DUP2               ;A = old fd, X = new fd
            bcs   :xrbad
            bra   :xrnext
:xrcls      lda   SBTGT
            jsr   UFD_CLOSE
            bra   :xrnext
:xrfile     pha                          ;the kind
            lda   DUP_PTRL,x
            sta   PTR0
            lda   DUP_PTRH,x
            sta   PTR0+1
            pla
            cmp   #FREC_AP
            beq   :xrfapp
            bcs   :xrftrunc              ;FREC_WR
            jsr   OPEN_REDIR_RD          ;FREC_RD: `N<`
            bra   :xrfopen
:xrftrunc   jsr   OPEN_REDIR_WR
            bra   :xrfopen
:xrfapp     jsr   OPEN_REDIR_AP
:xrfopen    bcs   :xrbad
            ldx   SBTGT
            jsr   SB_DUPCL
            bcs   :xrbad
:xrnext     inc   SBI
            bra   :xrloop
:xrdone     clc
:xrbad      rts

*-- SB_DUPCL (dup2 onto a target, then close the temporary)
*-- moved to the low image, shblt2.s, beside UFD_DUP2 (SH-FD):
*-- it marks the fds the user opens, and frees 27 bytes here.

*---------------------------------------------------------------
* CHCK_BLTN_RO -- `readonly [-p] [NAME[=VALUE]]...` (POSIX XCU).
* Marks a variable so that every later assignment and every
* `unset` refuses it; with no operands (or `-p`) it LISTS the
* marked variables in a form that can be read back.
*
* The flag itself is VARRO, one byte per slot beside VAREXP
* (sh.s's arena) and zeroed by SH_INIT_ZR in the same run --
* which it MUST be, for exactly VAREXP's own reason: lazy free
* hands the next `sh` this one's bss, and a stale byte would
* make a variable nobody protected refuse to be written, with
* no way at all to clear it.
*
* The refusal lives in VARSET/VARUNSET (shvar.s), not here, so
* it covers every writer at once: `NAME=v`, `export`, `read`,
* `for`, `getopts`' OPTIND/OPTARG and `${V=word}`.
* OUT: carry SET = handled. CLOBBERS: A, X, Y, PTR0-PTR2.
*---------------------------------------------------------------
CHCK_BLTN_RO
            lda   #<SB_RO_STR
            sta   PTR1
            lda   #>SB_RO_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :rois
            clc
            rts
:rois       jsr   SB_NOREDIR
            bcs   :rodone
            stz   LASTSTATUS
            lda   CMD_ARGC+0
            cmp   #2
            bcc   :rolist
            lda   CMD_ARGV+2
            sta   PTR0
            lda   CMD_ARGV+3
            sta   PTR0+1
            lda   #<SB_DP_STR
            sta   PTR1
            lda   #>SB_DP_STR
            sta   PTR1+1
            jsr   STRCMP                 ;`-p` is POSIX's own
            beq   :rolist                ;spelling for the list
            lda   #1
            sta   SBI
:roloop     lda   SBI
            cmp   CMD_ARGC+0
            beq   :rodone
            jsr   SB_RO_ONE
            inc   SBI
            bra   :roloop
:rolist     jsr   SB_RO_LIST
:rodone     sec
            rts

*---------------------------------------------------------------
* SB_RO_ONE -- one `readonly` operand: NAME, or NAME=VALUE.
* NAME=VALUE is split IN PLACE ('=' becomes a NUL) exactly the
* way CHCK_BLTN_VAR splits a bare assignment, and for the same
* reason -- this command's own token text is never read again.
* Both lengths are checked HERE: VARSET's header makes that the
* caller's job, and the one caller that forgot walked a 127-byte
* word through a 16-byte slot (shvar.s EXP_ONE's own note).
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.

*-- CONT_UNWIND MOVED to shsgcld.s (the $D000 segment, SH-ROOM2
*-- step 4); CONT_POP's plain `jsr` is unchanged.
