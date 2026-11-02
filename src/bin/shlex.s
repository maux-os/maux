*---------------------------------------------------------------
* shlex.s -- the main loop, line input, comment stripping, the
* tokenizer and CLASSIFY, `put` by src/bin/sh.s (NOT a
* standalone binary -- the same put-module shape as
* sedexec.s/expr.eval.s). sh.s was 190,960 bytes stripped
* against real Merlin-8's 41,215-byte source buffer, which
* holds the resident manifest plus ONE put file at a time, so
* the body is split across eight modules. Boundaries are banner
* lines at global labels, chosen along the shell's own
* concerns. Every symbol here resolves against sh.s's equates,
* data and arena -- see that file's header for the scope.
*---------------------------------------------------------------
START
*-- FIRST, BEFORE ANYTHING: install the second code segment
*-- into the process language card at $E000 (SEG_INIT,
*-- src/bin/shsegi.s; docs/SH-SUBSET.md ruling 7.6). `trap`,
*-- `getopts` and the job-control builtins live there, so no
*-- call can be allowed to reach $E000 ahead of this one. It is
*-- also the first instruction of the image, which is what
*-- spawn JMPs to (docs/SYSCALL.md ruling 11).
            jsr   SEG_INIT
*-- Tier 3 init (docs/SH-FEATURES.md sec 4): CUR_IN_FD/SRC_
*-- DEPTH/SH_XTRACE are ordinary `ds` -- but see SH_INIT_ZR
*-- below: "the loader zeroed it" stopped being true when lazy
*-- free stopped copying the image, so every cell whose
*-- correctness rested on that is established HERE now, not
*-- assumed. CUR_IN_FD was already set explicitly rather than
*-- left to depend on FD_STDIN being 0; it keeps its store for
*-- that reason, and it is not zero.
            lda   #FD_STDIN
            sta   CUR_IN_FD
            stz   SRC_DEPTH
            stz   SH_XTRACE
            stz   SH_ERREXIT
            stz   TC_ON                  ;arena: not zeroed
            stz   PFX_SV                 ;arena: nothing saved
            jsr   SH_INIT_ZR
            jsr   ALI_INIT               ;empty alias table
*-- `times` (docs/SH-FEATURES.md sec 29): the shell's own start
*-- tick, taken once here because there is nowhere later to take
*-- it from: a baseline cannot be reconstructed after the fact.
*-- SB_T0CAP is segment code, so the whole of this costs the LOW
*-- image three bytes plus ten arena cells that emit nothing.
*-- After SH_INIT_ZR on purpose: nothing it zeroes is read here,
*-- but SH_TMODE is read by `times` and must not be clobbered by
*-- a later blanket zeroing if one is ever added.
            jsr   SB_T0CAP
*-- V7 sh(1): "On invocation, the shell scans the environment
*-- and creates a parameter for each name found." AFTER
*-- SH_INIT_ZR, which has just zeroed the table this fills,
*-- and before MAINLOOP, so an inherited PATH is in place
*-- before PATH_SRC first looks. See ENV_IMPORT's header.
            jsr   ENV_IMPORT
*-- Tier 3 `sh SCRIPTFILE` (docs/SH-FEATURES.md; EX3 pipeline
*-- work): a SECOND argv operand and NO MORE (ARGC==2 exactly)
*-- names a file to read commands from -- reuses OPEN_REDIR_RD
*-- VERBATIM, the same routine the `.` builtin uses (CHCK_BLTN_
*-- DOT, shbltn.s), through the SAME parser CUR_IN_FD already
*-- feeds -- no second parser, no LINEBUF side-entry. ARGC!=2
*-- falls through UNCHANGED below: CUR_IN_FD stays FD_STDIN,
*-- today's exact path for BOTH argc==1 (every in-tree harness
*-- spawn: a script dup'd onto fd 0) AND argc>=3 -- a REAL,
*-- already-shipped maux feature (docs/DEMOS.md's etymology
*-- demo: `SH CAT /mnt/MAUX/MGFILE < /mnt/MAUX/MGSCRIPT` sets
*-- $1/$2
*-- from argv while fd 0, not argv, still carries the nested
*-- sh's OWN commands) that argc-alone cannot tell apart from a
*-- script operand -- grepping shtestb.s/envtestb.s/shlangtestb.
*-- s/nmtestb.s/fleettestb.s alone missed this real, non-test
*-- caller; ARGC==2 is the one shape ex's own spawn (Phase C,
*-- argv={"sh",SCRIPTPATH,0}) ever produces, so pinning the
*-- feature to exactly that shape is both correct for THAT
*-- caller and silent for every ARGC>=3 caller already shipping.
*-- `$0` stays "sh" (v1 deviation; ex never reads it); `$1`=
*-- GETARG(2), `$#`=ARGC-2 via POS_SHIFT.
*-- Script mode is non-interactive BY CONSTRUCTION -- it skips
*-- the fd-0 FDSTAT probe below entirely, since fd 0 is now free
*-- for the COMMAND's own I/O, not sh's script source, and
*-- testing it for "is this a tty" would test the wrong fd.
*-- 2026-10-11 (docs/EXEC-SHEBANG.md Part 2): V7's `sh [-ex]
*-- SCRIPT [ARGS]`. Any operand after the options names the
*-- script; `$0` is its path and `$1..` the args after it. This
*-- replaces the ARGC==2-only rule above, so the argc>=3 shape
*-- (`SH CAT FILE < SCRIPT`) is gone: a `#!` script needs args.
            stz   SH_ARG0
            stz   SH_DASHS
            stz   SH_DASHC
            stz   SH_CMODE
            stz   SH_NOEDIT
            lda   ARGC
            cmp   #2
            bcs   :so_hasarg
            jmp   :noscr
:so_hasarg  lda   #1
:so_optlp   sta   SCRIDX
            jsr   GETARG                 ;PTR0 = argv[idx]
            bcs   :so_nomore             ;options only
            ldy   #0
            lda   (PTR0),y
            and   #$7F
            cmp   #'-'
            bne   :so_gotscr
            iny
            lda   (PTR0),y
            beq   :so_gotscr             ;a lone '-' is a name
:so_optch   lda   (PTR0),y
            beq   :so_optnext
            and   #$7F
            cmp   #'x'                   ;x: trace
            bne   :so_notx
            lda   #1
            sta   SH_XTRACE
            bra   :so_optc2
:so_notx    cmp   #'e'                   ;e: exit on error
            bne   :so_note
            lda   #1
            sta   SH_ERREXIT
            bra   :so_optc2
:so_note    cmp   #$45                   ;E: no line editor, the
            bne   :so_notE               ;kernel's one reads
            lda   #1
            sta   SH_NOEDIT
            bra   :so_optc2
:so_notE    cmp   #'s'                   ;s: commands from stdin
            bne   :so_notS
            lda   #1
            sta   SH_DASHS
            bra   :so_optc2
:so_notS    cmp   #'c'                   ;c: the next operand is
            bne   :so_optbad             ;the command string
            lda   #1
            sta   SH_DASHC
:so_optc2   iny
            bra   :so_optch
:so_optnext lda   SCRIDX
            inc   a
            bra   :so_optlp
:so_optbad  lda   #<OPTERR_MSG
            ldx   #>OPTERR_MSG
            jsr   PR_ERRAX
            lda   #2
            jsr   EXIT
:so_nomore  lda   SH_DASHC               ;-c needs its string
            beq   :so_nomo2
            lda   #<CUSE_MSG
            ldx   #>CUSE_MSG
            jsr   PR_ERRAX
            lda   #2
            jsr   EXIT
:so_nomo2   lda   SH_DASHS
            beq   :noscr
            bra   :so_dashs
:so_gotscr  lda   SH_DASHC               ;-c: this operand
            bne   :so_cstr               ;is the string
            lda   SH_DASHS               ;-s: an operand
            bne   :so_dashs              ;is $1, no script
            jsr   OPEN_REDIR_RD
            bcc   :so_scropen
            lda   #<SCRERR_MSG
            ldx   #>SCRERR_MSG
            jsr   PR_ERRAX
            lda   #1
            jsr   EXIT
:so_scropen jsr   OPEN_HI                ;out of `exec N<`'s way
            sta   CUR_IN_FD
            lda   SCRIDX
            sta   POS_SHIFT
            sta   SH_ARG0
            stz   SH_INTERACT
            jmp   :notty
*-- `sh -c STRING [NAME [ARG...]]` (POSIX): STRING is the one
*-- line the shell runs, non-interactive, then it leaves with
*-- the last status (MAINLOOP's SH_CMODE hook).  NAME is $0 and
*-- the ARGs are $1...; with no NAME, $0 stays argv[0] and
*-- there are none.  STRING is a single line, run as `eval`
*-- runs its operands (a newline in it separates nothing).
:so_cstr    ldy   #0
:so_cp      lda   (PTR0),y
            sta   LINEBUF,y
            beq   :so_cpd
            iny
            cpy   #LINEMAX
            bcc   :so_cp
            lda   #0
            sta   LINEBUF,y
:so_cpd     lda   SCRIDX
            inc   a
            cmp   ARGC
            bcs   :so_cno
            sta   SH_ARG0                ;NAME is $0
            sta   POS_SHIFT
            bra   :so_cgo
:so_cno     lda   ARGC
            dec   a
            sta   POS_SHIFT              ;no arguments: $# = 0
:so_cgo     lda   #1
            sta   SH_CMODE
            stz   SH_INTERACT
            jmp   :notty
:so_dashs   lda   SCRIDX                 ;$1 = argv[SCRIDX]
            dec   a
            sta   POS_SHIFT
:noscr
*-- INTERACTIVE iff fd 0 is a DEVICE -- V7 sh's own rule (it
*-- gates the prompt on gtty(0) succeeding), decided once here.
*-- Nothing weaker works: a tty and a pipe are both unseekable,
*-- so the seek probe CAP_LINE_MARK already runs cannot tell a
*-- $( ) child (fd 0 = pipe) from a login shell (fd 0 = the
*-- console), and before SYS_FDSTAT existed every sh prompted --
*-- a nested `sh < script 2> err` sprayed "$ " through err, and
*-- a $( ) child sprayed it on the console mid-substitution.
*-- Carry set (fd 0 CLOSED) is non-interactive, same as V7 --
*-- a shell with no stdin has nobody to prompt.
            stz   SH_INTERACT
            lda   #FD_STDIN
            jsr   SC_FDSTAT
            bcs   :notty
            ora   #0                     ;N := result's high bit
            bpl   :notty                 ;-- >= FD_DEV_BASE
                                         ;($80, syscall-devfd
                                         ;.equ, deliberately not
                                         ;put here) IS "device"
            lda   #1
            sta   SH_INTERACT
*-- AN INTERACTIVE SHELL IGNORES TERM (RULINGS-1, V7 sh(1):
*-- "If the shell is interactive then terminate is ignored (so
*-- that kill 0 does not kill an interactive shell)"). CATCH
*-- with no armed trap, not IGN: spawn resets a catch to the
*-- default in children and an IGN would be inherited.
*-- SIG_RETRY (shtrap.s) drops the pending signo and retries the
*-- blocked call (TRAPACT clear). A user `trap ... 15` still
*-- wins (TRAP_SET_ONE). KILL (9) is untouched.
            lda   #15
            ldx   #SIGA_CATCH
            jsr   SC_SIGNAL
*-- THE LOGIN SHELL STARTS ON A SANE TTY (RULINGS-1, the getty
*-- rule: V7's init re-runs getty, which stamps the line modes,
*-- at each login -- not at each shell). A console shell killed
*-- or exited after `stty raw` left its successor a raw console:
*-- the kernel's PRC_TMD_RST resets only a foreground-set
*-- victim and the shell is never in its own. "Login shell" is
*-- "my parent is init (pid 1)": init spawns exactly the console
*-- shell and the rc script, a nested `sh` has the shell for a
*-- parent, and the test needs no marker init does not already
*-- supply. Here, not in init: zero flat bytes. A failed PSTAT
*-- or a serial fd 0 (no mode word) is skipped, harmlessly.
            lda   BANK_ID                ;pid == bank
            ldx   #<PSBUF
            stx   PTR0
            ldx   #>PSBUF
            stx   PTR0+1
            jsr   SC_PSTAT
            bcs   :notty
            lda   PSBUF+PCB_PARENT
            cmp   #1
            bne   :notty
            lda   #FD_STDIN
            ldx   #TMD_ICANON+TMD_ECHO+TMD_OPOST
            jsr   SC_TTYMODE
:notty      jsr   ED_INIT                ;SH_EDIT, history
*-- The prompt goes to STDERR, not stdout. It used to go to
*-- stdout and be excused as "harmless when redirected", which
*-- was only true because nothing yet redirected the SHELL's own
*-- output -- `sh < script > out` would have interleaved "$ "
*-- through out. Real shells prompt on stderr for exactly this
*-- reason, and it costs nothing: stderr is still the tty when
*-- you are typing. AND ONLY WHEN INTERACTIVE, since 2026-08-27:
*-- see SH_INTERACT above -- a non-interactive shell that
*-- prompts is drift, and with $( ) spawning a nested sh it
*-- stopped being invisible drift.
*-- SIGNAL PUMP (docs/SIGNALS.md sec 3): before the prompt,
*-- drain one pending caught-signal trap -- its string goes into
*-- LINEBUF and runs through the ordinary engine below, skipping
*-- READLINE. And if the exit trap has run (SH_EXITING), do the
*-- real exit now that its line is complete.
*-- THE STACK IS RESET at every re-entry. MAINLOOP is reached by
*-- `jmp` from inside whatever `jsr` chain a line was in (a loop
*-- back, a rescan, a syntax error, `eval`), and each such jump
*-- used to strand that chain's return addresses: 4 bytes per
*-- RW_DISPATCH, the shlang script ended 11 bytes from the page
*-- wrap, where the kernel's frame indexing leaves page 1 (SH-FD
*-- notes, sec 9). SH_SP0 is the depth this fall-in has.
            tsx
            stx   SH_SP0
MAINLOOP    stz   OW_INTR                ;(shsgrw.s) never stale
            ldx   SH_SP0
            txs
            jsr   PUMP_TRAP
            bcc   :nopump
            jmp   SH_RUNSTR              ;a trap string is in
                                         ;  LINEBUF now
:nopump
            lda   SH_EXITING
            beq   :noexit
            lda   SH_EXITST
            jsr   EXIT
*-- JOB CONTROL (docs/JOB-CONTROL.md Increment C): reap finished
*-- `&` jobs and print their `[n]  Done   cmd` notices BEFORE
*-- the prompt -- V7's "reported at the next prompt". A poll
*-- (WJ_NOHANG), never a block; skipped outright when no row is
*-- Running, so a shell with no jobs pays a table scan per line.
*-- `sh -c`: run the string (in LINEBUF) once, then leave with
*-- its status unless a `.` is still reading its file
:noexit     lda   SH_CMODE
            beq   :nocmode
            cmp   #1
            bne   :cdone
            inc   SH_CMODE
*-- SH-SEQ A: the -c STRING is a string source like eval's, so
*-- it enters through SH_RUNSTR: LMARK_OK 0 (a loop must SPOOL;
*-- the cell is never initialised and a reused bank keeps the
*-- last script's 1) and STR_SRC 1 (an unfinished loop is
*-- refused, it never reads the caller's stdin).
            jmp   SH_RUNSTR
:cdone      lda   SRC_DEPTH
            bne   :nocmode
            jmp   SH_EOF
:nocmode    jsr   JOB_DRAIN
            lda   SH_INTERACT
            beq   :noprompt
*-- Console-loop spooling review (2026-09-15): print "$ " only
*-- when the NEXT line read comes from the console itself, not
*-- from a sourced file on SRC_STACK -- SRC_DEPTH nonzero means
*-- `.`-sourcing (plain or spooled) is live, and that file's own
*-- lines must run silently. A spooled loop over N lines used to
*-- print N stray "$ " prompts interleaved with real output; the
*-- same wart already existed for a plain `. FILE`, quieter.
*-- The prompt reappears exactly once, when SH_EOF pops back to
*-- the console. The secondary "> " prompt during spooling is
*-- unaffected -- SPOOL_ENTER (shtrap.s) writes it itself, never
*-- through here.
            lda   SRC_DEPTH
            bne   :noprompt
            lda   #$A4                   ; '$' high-bit-set
            sta   ED_PCH                 ;(for ^L)
            ldx   SH_EDIT                ;the editor shows this
            stx   ED_PRM                 ;prompt itself, once
            bne   :noprompt              ;the console is raw (a
                                         ;visible prompt means a
                                         ;ready console)
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #$A0
            ldx   #FD_STDERR
            jsr   PUTC
:noprompt   jsr   CAP_LINE_MARK           ;best-effort fd 0 mark
                                         ;before this line is
                                         ;read -- WHILE/UNTIL's
                                         ;loop head (RW_LOOP_
                                         ;PUSH, below)
            jsr   READLINE
            bcc   :noteof                ;`bcc`/`jmp`, not `bcs`
                                         ;-- range (:eof is far
                                         ;now)
            jmp   SH_EOF
*-- SH-EXECLOOP: a `for` replay posted the first-token index of
*-- its DO segment (RP_PEND); the line READLINE just
*-- returned is the one the loop seeked back to, so it becomes
*-- RP_TOK for the :toknoerr path below. Every other line
*-- reads 0 here (the trap pump and eval enter at SH_RUNLINE
*-- and never copy).
*-- SH_RUNSTR -- SH-EXECLOOP: run a STRING (eval, a trap) that
*-- the caller has put in LINEBUF. Not a position in CUR_IN_FD:
*-- no seek mark (a loop in it must spool), no further lines
*-- (STR_SRC).
SH_RUNSTR   stz   LMARK_OK
            lda   #1
            sta   STR_SRC
            jmp   SH_RUNLINE
*-- SH_RUNLINE: run whatever is in LINEBUF (READLINE just filled
*-- it, or the trap pump / exit trap stuffed it). Every path
*-- every path with `jmp MAINLOOP`, so this is an entry, not a
*-- ends `jmp MAINLOOP`, so this is an ENTRY not a sub -- the
*-- pump reaches it by carry, the exit trap by SH_EXIT's jmp.
:noteof     stz   STR_SRC                ;SH-EXECLOOP: file line
            lda   RP_PEND
            sta   RP_TOK
            stz   RP_PEND
*-- Console-loop spooling (docs/SH-FEATURES.md, 2026-09-15): a
*-- pristine copy of LINEBUF, taken HERE -- before STRIPCOMMENT/
*-- TOKENIZE mutate it -- so SPOOL_ENTER (shtrap.s) can spool a
*-- loop head's REAL text (quotes, spaces, all) instead of
*-- TOKENIZE's own NUL-for-separator rewrite. Same "survives
*-- tokenizing" precedent HDLINEBUF already uses for here-doc
*-- terminator text. Every SH_RUNLINE entry gets one, trap
*-- strings included -- harmless, and one copy site beats three.
SH_RUNLINE  lda   #<RAWLINE
            ldx   #>RAWLINE
            jsr   LB_COPY
            jsr   STRIPCOMMENT
*-- Alias expansion (shsgali.s): text pass, command-position
*-- words only. ALI_MINPOS = lowest splice offset this line,
*-- read by SPOOL_ENTER; $FF = none. ALI_USED = 0 skips it.
            lda   #$FF
            sta   ALI_MINPOS
            lda   ALI_USED
            beq   :alidone
            lda   CONT_SEP               ;SH-SEQ C: a resumed
            bne   :alidone               ;  remainder: done
            jsr   ALI_EXPAND
            bcc   :alidone
            lda   #<ALI_LONG_M
            ldx   #>ALI_LONG_M
            jmp   PR_ERRAX1M
:alidone
*-- SH-SEQ C: the text TOKENIZE is about to squeeze in place.
*-- DOT_SAVE cuts a `.` line's remainder out of it at the raw
*-- offset TOKENIZE records for each token (TOKOFF).
            lda   #<PRETOK
            ldx   #>PRETOK
            jsr   LB_COPY
            jsr   TOKENIZE
*-- TOK_ERR is set by TOKENIZE itself (docs/SH-SUBSET.md
*-- sec 8.4): an unterminated quote, or a mixed bare/quoted
*-- token (e.g. `abc"def"ghi`), is a syntax error caught
*-- BEFORE PARSE ever runs -- never a silently-extended or
*-- silently mis-handled token (3: more tokens than MAXTOK or
*-- the operator pool holds, KFIX2 5; 4: a glued number before
*-- `>`/`<` the shell cannot redirect). All report to stderr and
*-- set LASTSTATUS nonzero, then abandon the rest of the
*-- line, same shape PARSE_ERR's syntax path already uses
*-- below.
            lda   TOK_ERR
            beq   :toknoerr
            cmp   #2
            beq   :tokmixed
            cmp   #3
            beq   :toktoo
            bcs   :tokfd                 ;4 (carry: A >= 3)
            lda   #<TOKUNTERM_MSG
            sta   PTR0
            lda   #>TOKUNTERM_MSG
            sta   PTR0+1
            bra   :tokerrpr
:tokmixed   lda   #<TOKMIXED_MSG
            sta   PTR0
            lda   #>TOKMIXED_MSG
            sta   PTR0+1
            bra   :tokerrpr
:toktoo     jsr   PR_TOOMANY             ;3: MAXTOK/pool
            bra   :tokst
:tokfd      jsr   PR_REDIRERR            ;4: `8>F`, `2<F`
            bra   :tokst
:tokerrpr   jsr   PR_ERR
:tokst      lda   #1
            sta   LASTSTATUS
            jmp   MAINLOOP               ;`jmp`: alias hook grew
:toknoerr
*-- A line is now a SEQUENCE of pipeline segments (`;`/`&&`/`||`
*-- separated, docs/SH-SUBSET.md Tier 0). :seg below runs once
*-- per segment; SH_SKIP is the short-circuit state carried
*-- between them -- set by NEXT_SKIP from the separator that
*-- just ended a segment plus LASTSTATUS, exactly the way a real
*-- shell's left-to-right evaluation works (no construct stack
*-- needed: `&&`/`||` bind no tighter or looser than each
*-- other, so one flag suffices).
            stz   SH_SKIP
*-- SEG_FIRST -- "this segment is the first on its line". Only
*-- CR_STARTSCAN (docs/SH-FEATURES.md sec 18) reads it, and only
*-- to REFUSE: a construct's scan pass rewinds to the start of
*-- the LINE, so one opened as a LATER segment of that line
*-- would replay the segments before it. Refusing to scan
*-- there leaves such a line behaving exactly as it did before
*-- compound redirection existed.
            lda   #1
            sta   SEG_FIRST
            stz   LN_HD                  ;SH-EXECLOOP: none yet
*-- SH-SEQ C: the REMAINDER of a line a `.` left (CONT_POP).
*-- AFTER the ordinary init above, or `. X && A || B` runs A:
*-- the separator that ended the `.` segment, `;;` first (it
*-- closes a case branch, :segdone's order), then NEXT_SKIP on
*-- the status X left. The alias pass was skipped for this text
*-- (SH_RUNLINE tests CONT_SEP). Bit 7 of the separator: an
*-- alias spliced on that line, so ALI_MINPOS 0 makes
*-- SPOOL_ENTER refuse a loop here (no double expansion).
            lda   CONT_SEP
            beq   :nocont
            stz   CONT_SEP
            asl   a
            bcc   :nali
            stz   ALI_MINPOS
:nali       lsr   a
            sta   PARSE_SEPOP
            cmp   #SEP_DSEMI
            bne   :nds
            jsr   RW_DSEMI
:nds        jsr   NEXT_SKIP
            stz   SEG_FIRST
:nocont
*-- SH-EXECLOOP: a `for` replay re-enters its line AT the DO
*-- segment. TOKENIZE has just reset TOKI to 0; setting it to
*-- DO's first token (RP_TOK, from the frame) makes PARSE
*-- start there, so the segments before DO are neither
*-- re-parsed nor re-expanded (a `$( )` there would run again).
            lda   RP_TOK
            beq   :seg
            sta   TOKI
            stz   RP_TOK
            stz   SEG_FIRST              ;DO is not segment 0
:seg        lda   TOKI                   ;SH-EXECLOOP: this
            sta   SEG_TOKI               ;  segment's 1st token
            lda   LN_HD                  ;  and whether a
            sta   HD_BEFORE              ;  here-doc was before
            jsr   ZR_CMD_TABLES
            jsr   PARSE
            lda   PARSE_ERR
            beq   :segok
            cmp   #2
            bne   :segsyn
*-- PARSE_ERR 2: APPEND_ARGV refused a word. It ends the line
*-- as a syntax error does -- NOTHING runs and `$?` is 1.
*-- (It used to fall through to :segok and run the segment cut
*-- short; SH-DEFECTS 12.)
            jsr   PR_TOOMANY
            bra   :segfail
:segsyn     jsr   PR_SYNTAX
*-- A syntax error must SET a status, not leave the previous
*-- command's standing. Without this, `$?` reads stale after a
*-- refused line -- so a bad line followed by `ECHO $?` prints
*-- the status of whatever ran BEFORE it, and no gate can assert
*-- that a refusal happened at all. Bourne sets nonzero here.
:segfail    lda   #1
            sta   LASTSTATUS
            jmp   MAINLOOP               ;abandon the rest of
                                         ;this line (v1) --
                                         ;`jmp`, not `bra` --
                                         ;range (console-loop
                                         ;spooling's RAWLINE
                                         ;copy pushed this out
                                         ;of an 8-bit branch)
:segok
            lda   NCMD
            bne   :segcmd                ;a real command word
*-- NCMD==0. Two very different things reach here. A stray `;`
*-- or a blank line is genuinely empty and must stay silent.
*-- But REDIRECTIONS WITH NO COMMAND WORD also land here --
*-- SET_INFILE/SET_OUTFILE/SET_DUP index their tables by NCMD
*-- and never increment it -- and that is the shape a compound
*-- redirect takes: `DONE < FILE` leaves `< FILE` as residual
*-- text after CHCK_RESERVED consumed DONE. Falling into
*-- :segdone DISCARDED those tokens without a word, so the
*-- user's redirect silently did nothing (docs/SH-FEATURES.md
*-- sec 17). Refuse instead: a refusal is strictly better than
*-- a wrong answer, and this is a few dozen bytes against a
*-- feature that is not small (sec 18's ruling).
            jsr   CK_ORPHRDIR            ;redirects with no
            jmp   :segdone               ;  command word at all
                                         ;  (jmp: the trap
                                         ;  builtin grew the
                                         ;  dispatch chain past
                                         ;  bra's reach)
:segcmd
*-- CHCK_RESERVED recognises IF/THEN/ELIF/ELSE/FI/WHILE/UNTIL/
*-- DO/DONE at stage 0's argv[0] -- command position, same shape
*-- CD/EXIT/TEST already use -- REGARDLESS of skip (nesting
*-- has to stay correct even inside a false branch). It may jmp
*-- MAINLOOP itself (a loop-back seek, or a syntax/overflow
*-- diagnostic) and never return here at all in that case. A
*-- structural word with no residual text (bare "FI"/"DONE"/
*-- "ELSE"/"THEN") sets RW_HASRES=0 -- nothing left to run this
*-- segment. One WITH residual text ("IF TEST -F X") leaves it,
*-- shifted, in CMD_ARGV/CMD_ARGC/NCMD exactly as PARSE would
*-- have built it alone -- it falls into the SAME skip gate and
*-- dispatch chain an ordinary command uses below.
            jsr   CHCK_RESERVED
            lda   RW_ID
            bne   :wasresv
*-- Not a reserved word -- but inside an open `case` that is
*-- BETWEEN branches, a word ending in ')' is a PATTERN, and
*-- has to be tested even while the frame is skipping: that is
*-- how the next branch gets its chance. So this sits ABOVE the
*-- skip gate, not below it. CS_CASEPAT shifts the pattern off
*-- and leaves any commands glued after it on the same line to
*-- fall through into the gate under the state it just set.
:ptest      jsr   CS_CASEPAT
            bcc   :ckskip
*-- SH-CASE2 B: a pattern is a segment of its own (SEP_PAT), so
*-- nothing is left after it - not a nested `case`'s residual
*-- either: that is the NEXT segment, and CHCK_RESERVED sees it
*-- at argv[0] there. (This used to ask CHCK_RESERVED again.)
            jmp   :segdone
:wasresv    lda   RW_HASRES
            bne   :wr1
            jmp   :segdone
*-- SH-EXECLOOP: THEN, ELSE and DO open a compound list, so what
*-- follows them may itself be reserved (`do for ..`, `then
*-- while ..`): ask again, as the case-pattern path above does,
*-- until a word that is not.
:wr1        lda   RW_ID
            cmp   #11                    ;SH-SEQ B: CASE's
            bne   :wr2                   ;residual is its first
            jmp   :ptest                 ;pattern
:wr2        cmp   #2                     ;THEN
            beq   :again
            cmp   #4                     ;ELSE
            beq   :again
            cmp   #8                     ;DO
            bne   :ckskip
:again      jsr   CHCK_RESERVED
            lda   RW_ID
            bne   :wasresv
            beq   :ckskip
:ckskip     lda   SH_SKIP
            beq   :skipok                ;short-circuited --
            jmp   :segdone               ;LASTSTATUS untouched.
                                         ;`beq` over a `jmp`,
                                         ;not `bne` -- range
:skipok     jsr   CS_EFFSKIP             ;construct skip -- a
            beq   :csskipok              ;false if-branch, or a
            jmp   :segdone               ;false while condition,
                                         ;any nesting depth
                                         ;(SHELL-SPLIT sec 15)
:csskipok   stz   CASE_EMPTY             ;SH-SEQ B
            jsr   SH_TRACE          ;Tier 3 `set -x` -- one call
                                    ;site covers every dispatch
                                    ;shape below, builtins
                                    ;included (docs/SH-FEATURES
                                    ;.md sec 4)
*-- PREFIX ASSIGNMENTS (shpfx.s): `NAME=value cmd` and bare
*-- `NAME=value`.  After the trace so it shows the whole line;
*-- carry set = finished (assignments only, or refused).
            jsr   PFX_PEEL
            bcc   :nopfx
            jmp   :segdone
:nopfx
*---------------------------------------------------------------
* THE BUILTIN DISPATCH BELOW IS CASE-INSENSITIVE (2026-08-23).
* Every name compare here is `jsr STRCMPI`, not `jsr STRCMP`.
* Full argument: docs/SH-CASE.md.
*
* The short version: the tables below hold UPPERCASE names, so a
* case-SENSITIVE compare meant `CD D` worked and `cd D` did not.
* It went unnoticed for every builtin that ALSO ships as a
* binary -- lowercase `echo` missed the builtin and then found
* `ECHO` on disk, because ProDOS's pathname parser folds case.
* `cd` has no binary twin, so it was the one visible casualty,
* and a user could not change directory at all without shouting.
*
* STRCMPI is byte-for-byte free here: string.s is `put` whole
* into every program, so STRCMPI was already emitted in sh.bin
* and simply had no caller (its own header called it
* unreachable).
*
* NOT converted, deliberately, and each for its own reason:
*  - VARFIND (shell variable names) -- $PATH and $path are
*    distinct variables in every Unix shell, and folding them
*    would silently merge a user's variable into an exported
*    one. Variables never reach the filesystem, so ProDOS's
*    fold has no bearing.
*  - the heredoc terminator compare -- POSIX matches the
*    delimiter literally. Folding would let a body line `done`
*    close a heredoc opened with `<<DONE`.
*  - `[` / `]` / `.` / `:` -- pure punctuation. SIFOLD only
*    touches $E1-$FA, so STRCMPI and STRCMP are the SAME
*    comparison on these, and switching them would advertise a
*    semantic change that does not exist.
* `set`'s OPERANDS (`-x`/`+x`) ARE folded, with `set` itself:
* fixing the verb and leaving the flag would make `SET -X` work
* and `set -x` -- the spelling every Bourne manual prints --
* still fail, which is worse than the bug it replaced.
*---------------------------------------------------------------
*-- `( ... )` -- a GROUP, run in a subshell. First in the chain
*-- because a token starting `(` can be nothing else, and it
*-- sits below BOTH skip gates: a group inside a false branch
*-- must not run.
            jsr   CHCK_GROUP        ;carry set = was a `( )`
            bcc   :notgroup         ;  group, handled -- `jmp`:
            jmp   :segdone          ;  the alias hook pushed
:notgroup                           ;  :segdone out of range
*-- `command` and `exec` sit ABOVE every other builtin on
*-- purpose (docs/SH-FEATURES.md sec 29). `command NAME ...`
*-- must be able to reach ANY of them -- `command exit` and
*-- `command cd X` included -- and it gets there by dropping its
*-- own word from argv and returning carry CLEAR, so the whole
*-- chain below simply runs again against the shifted argv. Two
*-- extra STRCMPIs per command line is the price; the dispatch
*-- already runs eighteen.
            jsr   CHCK_BLTN_CMD   ;`command` -- carry set = a
            bcs   :segdone          ;  -v/-V report, handled;
                                    ;  carry CLEAR after the
                                    ;  plain form shifted argv
            jsr   CHCK_BLTN_XEC   ;`exec` -- carry set =
            bcs   :segdone          ;  redirections applied to
                                    ;  sh's OWN fds; the form
                                    ;  WITH a command never
                                    ;  returns (it exits)
            jsr   CHCK_BLTN_EXT     ;never returns if it
                                         ;WAS "EXIT"
            jsr   CHCK_BLTN_CD      ;carry set = was "CD",
            bcs   :segdone          ;  handled, do not spawn
            jsr   CHCK_BLTN_TST    ;carry set = was "TEST"/"[",
            bcs   :segdone          ;  handled, do not spawn
            jsr   CHCK_BLTN_BRK    ;carry set = was "BREAK"/
            bcs   :segdone          ;  "CONTINUE", handled --
                                    ;  only ever reached once
                                    ;  BOTH skip gates passed
            jsr   CHCK_BLTN_EXP   ;carry set = was "EXPORT",
            bcs   :segdone          ;  handled (docs/SYSCALL.md
                                    ;  item 13c)
            jsr   CHCK_BLTN_UNS   ;`unset` -- carry set =
            bcs   :segdone          ;  handled (docs/SH-
                                    ;  FEATURES.md, 2026-09-15)
            jsr   CHCK_BLTN_GOP   ;`getopts` -- carry set =
            bcs   :segdone          ;  handled (docs/SH-
                                    ;  FEATURES.md, 2026-09-15)
            jsr   CHCK_SHIFT  ;carry set = was "SHIFT",
            bcs   :segdone          ;  handled
            jsr   CHCK_BLTN_RD      ;`read` -- carry set = was
            bcs   :segdone          ;  "READ", handled (docs/
                                    ;  SH-FEATURES.md sec 16).
                                    ;  Reads FD 0, not CUR_IN_FD
            jsr   CHCK_BLTN_DOT     ;Tier 3 `.` -- on SUCCESS
                                    ;this jmp's MAINLOOP
                                    ;directly and never returns
                                    ;here (same shape EXIT
                                    ;already uses); carry set
                                    ;here only means the open
                                    ;FAILED
            bcs   :segdone
            jsr   CHCK_BLTN_CLN   ;Tier 3 `:` -- carry set =
            bcs   :segdone          ;  handled
            jsr   CHCK_BLTN_ECH     ;`echo` -- carry set =
            bcs   :segdone          ;  handled here; a shape it
                                    ;  cannot do returns clear
                                    ;  and the external ECHO
                                    ;  runs instead
            jsr   CHCK_BLTN_SET     ;Tier 3 `set -x`/`set +x` --
            bcs   :segdone          ;  carry set = handled
            jsr   CHCK_BLTN_WT    ;`wait` -- carry set =
            bcs   :segdone          ;  handled (docs/SH-BG.md)
            jsr   CHCK_BLTN_TRP   ;`trap` -- carry set =
            bcs   :segdone          ;  handled (docs/SIGNALS.md)
            jsr   CHCK_BLTN_JOB   ;`jobs`/`fg`/`bg` -- carry
            bcs   :segdone          ;  set = handled (docs/JOB-
                                    ;  CONTROL.md Increment C)
            jsr   CHCK_BLTN_TYP   ;`type` -- carry set =
            bcs   :segdone          ;  handled (docs/SH-
                                    ;  FEATURES.md sec 29)
            jsr   CHCK_BLTN_EVL   ;`eval` -- on SUCCESS this
                                    ;  jmp's SH_RUNLINE with the
                                    ;  joined operands in
                                    ;  LINEBUF and never returns
                                    ;  here (same shape `.`
                                    ;  uses); carry set here
                                    ;  means refused
            bcs   :segdone
            jsr   CHCK_BLTN_RO    ;`readonly` -- carry set =
            bcs   :segdone          ;  handled
            jsr   CHCK_BLTN_TMS   ;`times` -- carry set =
            bcs   :segdone          ;  handled
            jsr   CHCK_BLTN_ALI   ;alias/unalias/hash/fc --
            bcs   :segdone          ;  carry set = handled
            jsr   KILL_SPECS        ;`kill %n`: the spec becomes
            bcs   :segdone          ;  the job's pids in argv
                                    ;  before /bin/kill spawns;
                                    ;  carry set = no such job
            jsr   RUN_PIPELINE           ;sets LASTSTATUS
            jsr   ERREXIT_CK             ;`set -e` -- may not
                                         ;  return (shbltn.s)
*-- `;;` reaches here through PARSE_SEPOP rather than the
*-- reserved-word path -- see SEP_DSEMI. It runs BEFORE
*-- NEXT_SKIP, which reads the same byte for its own purpose.
:segdone    jsr   PFX_RESTORE            ;temporary prefixes
            lda   PARSE_SEPOP
            cmp   #SEP_DSEMI
            bne   :nodsemi
            jsr   RW_DSEMI
:nodsemi    jsr   NEXT_SKIP
            lda   PARSE_SEPOP
            cmp   #SEP_PAT           ;SH-CASE2 B: a pattern runs
            beq   :segkeep            ;  nothing, so the segment
            stz   SEG_FIRST             ;  after it is still the
:segkeep    lda   PARSE_SEPOP         ;  line's first for sec 18
            beq   :segsdone              ;`beq` over a `jmp`,
            jmp   :seg                   ;  not `bne :seg` --
                                         ;  sec 17's redirect-
                                         ;  without-a-command
                                         ;  check pushed :seg
                                         ;  out of an 8-bit
                                         ;  branch's reach too,
                                         ;  same as Tier 1 did
                                         ;  to the jump below
:segsdone   jmp   MAINLOOP                ;`jmp`, not `bra` --
                                         ;range (Tier 1's code
                                         ;pushed this out of an
                                         ;8-bit branch's reach)
*-- Tier 3 `.` (docs/SH-FEATURES.md sec 4): EOF on CUR_IN_FD
*-- ends a SOURCED file's own input, not necessarily the
*-- shell's -- SRC_DEPTH>0 means `.` is active, so close the fd,
*-- pop CUR_IN_FD back to whatever was reading before it, and
*-- resume the CALLER's script right where it left off (its own
*-- fd position was never touched, so the next READLINE there
*-- picks up correctly). Only true top-level EOF (SRC_DEPTH==0)
*-- still exits the process.
*-- EOF reached with a SCAN pass still open (docs/SH-FEATURES.md
*-- sec 18) means the construct it was scanning has no
*-- terminator anywhere in the file. Say so. Without this the
*-- symptom is a silently truncated script -- the scan skips
*-- every remaining line looking for a DONE/FI that is not
*-- coming -- which is the quiet-wrong-answer class this shell
*-- refuses everywhere else. An unterminated construct was
*-- always broken here; before the scan it was broken by running
*-- the rest of the file under a stuck frame instead.
SH_EOF      lda   SCAN_ACT
            beq   :noscan
            stz   SCAN_ACT
*-- SH-SEQ C (M2): a `.` file's open scan is reported once, by
*-- CONT_UNWIND; this message is for the top level.
            lda   SRC_DEPTH
            bne   :noscan
            lda   #<CSEOF_MSG
            ldx   #>CSEOF_MSG
            jsr   PR_ERRAX1
:noscan     lda   SRC_DEPTH
            beq   :realeof
            lda   CUR_IN_FD
            jsr   CLOSE_FD_A
*-- console-loop spooling (docs/SH-FEATURES.md, 2026-09-15):
*-- SPOOL_ENTER (shtrap.s) pushed a temp file at exactly this
*-- SRC_DEPTH -- popping it back off is the only place a
*-- spooled construct's own natural end (or `break`, which just
*-- seeks this same fd forward to EOF) ever runs, so it is where
*-- the file gets deleted. `exit` mid-loop skips this pop
*-- entirely (the process is leaving) -- SH_EXIT (shtrap.s)
*-- handles that case itself. `kill -9` bypasses this shell
*-- entirely and stays a named gap.
            lda   SRC_DEPTH
            cmp   SH_SPOOL_LVL
            php                          ;Z: this was the spool
            bne   :nospool
            stz   SH_SPOOL_LVL
            jsr   SPOOL_UNLINK
:nospool    ldx   SRC_DEPTH
            dex
            lda   SRC_STACK,x
            sta   CUR_IN_FD
            stx   SRC_DEPTH
            plp
            bne   :dotpop                ;SH-SEQ C: a `.` frame
            jmp   MAINLOOP
:dotpop     jmp   CONT_POP
:realeof
*-- An INTERACTIVE shell leaving on EOF ends the prompt's own
*-- row first (2026-10-08, operator: ^D at the console printed
*-- `$ $`). The cooked ^D echoes nothing -- correct, it is not
*-- a CR -- so the cursor is still two cells into the old
*-- prompt when pid 1's respawned shell prints its own. bash
*-- prints `exit`, V7 relied on getty's CR; one CR to stderr
*-- is the smallest honest version. Scripts and `$( )` children
*-- (SH_INTERACT clear) print nothing, as before.
            lda   SH_INTERACT
            beq   :eofquiet
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
:eofquiet   lda   LASTSTATUS             ;POSIX: sh's status at
                                         ;  EOF is the LAST
                                         ;  command's, not 0
            jmp   SH_EXIT                ;  runs the exit trap,
                                         ;  then exits -- the
                                         ;  diagnostic above is
                                         ;  the whole report

*---------------------------------------------------------------
* NEXT_SKIP -- decide whether the segment PARSE is about to
* build next should run, from PARSE_SEPOP (what just ended the
* PREVIOUS segment) and LASTSTATUS (its accumulated result).
* `;` always continues; `&&` continues iff the last status was
* 0; `||` continues iff it was nonzero. A skipped segment leaves
* LASTSTATUS untouched, so a chain of skips still tests the
* status of the last segment that actually RAN -- the whole
* mechanism needed for left-to-right `&&`/`||` precedence, no
* stack. CLOBBERS: A.
*---------------------------------------------------------------
NEXT_SKIP   lda   PARSE_SEPOP
            cmp   #1
            beq   :run
            cmp   #SEP_BG                ;`&` sequences like `;`
            beq   :run
            cmp   #SEP_DSEMI             ;so does `;;` -- it
            beq   :run                   ;imposes no short-
                                         ;circuit of its own
            cmp   #2
            beq   :and
            cmp   #3
            beq   :or
            rts                          ;end of line -- moot
:and        lda   LASTSTATUS
            beq   :run
            bra   :skip
:or         lda   LASTSTATUS
            bne   :run
:skip       lda   #1
            sta   SH_SKIP
            rts
:run        stz   SH_SKIP
            rts

