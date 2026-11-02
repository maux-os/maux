*---------------------------------------------------------------
* shbltn.s -- the remaining builtins (dot, set -x, read), here-
* documents, and the fd staging a pipeline needs, `put` by
* src/bin/sh.s (NOT a standalone binary -- the same put-module
* shape as sedexec.s/expr.eval.s). sh.s was 190,960 bytes
* stripped against real Merlin-8's 41,215-byte source buffer,
* which holds the resident manifest plus ONE put file at a
* time, so the body is split across eight modules. Boundaries
* are banner lines at global labels, chosen along the shell's
* own concerns. Every symbol here resolves against sh.s's
* equates, data and arena -- see that file's header for the
* scope.
*---------------------------------------------------------------
*---------------------------------------------------------------
* RW_DONE_FOR -- DONE's FOR-type branch (RW_DONE, above, jmps
* here). CS_EFFSKIP first, same as WHILE/UNTIL's own DONE: a
* dominated-dead frame (an ancestor skipping, OR `break` having
* set THIS frame's own CSSKIP) pops and falls through. Otherwise
* advance the word index; more words -> post the frame's DO
* segment index (CSFORTOK) and seek fd 0 back to CSHEAD (the
* start of the logical line holding DO; see RW_DO_FOR), and
* resume WITHOUT popping (the SAME frame keeps running, unlike
* WHILE/UNTIL's pop-and-refresh); the new word is assigned
* BEFORE the seek (the re-read `do CMD` is expanded at parse
* time); exhausted -> pop and fall through, same as the
* dominated-dead case. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
RW_DONE_FOR stx   RDFRAME
            jsr   CS_EFFSKIP
            bne   :forstop
            ldx   RDFRAME
            inc   CSFORIDX,x
            lda   CSFORIDX,x
            cmp   CSFORCNT,x
            bcc   :formore
:forstop    ldx   RDFRAME                ;sec 18: a FOR frame is
            jsr   CR_CLOSE               ;  NOT popped between
            dec   CSPTR                  ;  iterations, so this
                                         ;  is the only close
            jsr   CS_POPLIVE             ;SH-CASE2 A: an empty
            bne   :done                  ;  list is status 0
            lda   CSFORCNT,x             ;  (else the last
            bne   :done                  ;  status stands)
            stz   LASTSTATUS
:done       rts
:formore    ldx   RDFRAME
            jsr   FOR_ASSIGN             ;next word, BEFORE the
            ldx   RDFRAME                ;  replay parses it
            lda   CSFORTOK,x             ;replay from the line
            sta   RP_PEND            ;  holding DO, passing
            jmp   CS_GOHEAD              ;  this many segments

*-- Tier 2 construct-stack extension: FOR-frame state, parallel
*-- to CSTYPE/CSSKIP (indexed by the SAME construct-stack depth,
*-- valid only where CSTYPE[depth]==4). CSHEAD (above) is REUSED
*-- for FOR's own body-start mark -- no separate array needed,
*-- it is already 3 bytes/depth and unused by whichever frame
*-- type isn't occupying a given depth.
*-- FORWORDMAX/CASEWLEN/FORWORDLEN: hoisted to sh.s's top
*-- block (EQU burn-down 2026-08-29). CASEWLEN is 31 chars +
*-- NUL (see CSCASEW); FORWORDLEN 15 + NUL -- matches
*-- ProDOS's own filename length cap,
                              ;so a glob match can never
                              ;overflow a slot
*-- CSFORWORDS (the word-list arena, one fixed-size row per
*-- construct-stack depth) moved to the dum/dend block at the
*-- file's textual end (2026-08-21) -- RW_FOR always STRCPYs the
*-- whole word list into a frame's row, up front, before
*-- FOR_ASSIGN/RW_DO_FOR ever read a slot from it. See the dum
*-- block's own header for the full rationale.
CSFORWORDPTR
            ds    MAXCDEPTH*2
                             ;this depth's cached row base (set
                             ;once by RW_FOR, read by
                             ;FOR_WORDADDR)
CSFORCNT    ds    MAXCDEPTH  ;word count for this depth's list
CSFORIDX    ds    MAXCDEPTH  ;current index, 0-based
CSFORVARSLOT
            ds    MAXCDEPTH  ;VARNAMES/VARVALS slot for the loop
                             ;variable, resolved once by RW_FOR

FORFRAME    ds    1          ;RW_FOR: this push's frame index
FORWC       ds    1          ;RW_FOR: word count being copied in
FORI        ds    1          ;RW_FOR: word-copy loop cursor
FORVSLOT    ds    1          ;RW_FOR: VARSET's returned slot
FORDOX      ds    1          ;RW_DO_FOR: frame index, held
                             ;across CS_EFFSKIP/CAP_LINE_MARK
                             ;(both clobber X)
RDFRAME     ds    1          ;RW_DONE_FOR: frame index, held
                             ;across CS_EFFSKIP (clobbers X)
FASLOT      ds    1          ;FOR_ASSIGN: the variable slot,
                             ;held across FOR_WORDADDR (clobbers
                             ;X)
FTMP16      ds    2          ;FOR_ROWBASE: 16-bit shift scratch

*-- Variable table (docs/SH-FEATURES.md sec 4). Sizing:
*-- MAXVARS(8) * VARNAMESZ(16) = 128, MAXVARS(8) * VARVALSZ(32)
*-- = 256, total 384 bytes. A slot's name byte 0 == 0 means
*-- free -- see VARFIND/VARSET's own header for why that needs
*-- no separate "in use" array.
*-- VARNAMES AND VAREXP ARE NOT HERE EITHER, since 2026-08-27
*-- (136 more bytes). Both still MUST start at zero -- a zero
*-- name byte is the free-slot marker, and a stray export bit
*-- would leak an unexported variable to every child -- but
*-- SH_INIT_ZR zeroes both BY NAME at entry, on every spawn
*-- including a warm respawn (docs/STICKY.md sec 32). Once
*-- something establishes the zeros at run time, paying for them
*-- again in the file is paying twice.
*-- VARVALS IS NOT HERE. It moved to the dum arena 2026-08-27,
*-- 256 emitted zero bytes reclaimed, and the proof it never
*-- needed them is three lines up in this very file: SH_INIT_ZR
*-- zeroes VARNAMES and VAREXP by name and does NOT touch
*-- VARVALS. A value is only ever read for a slot VARNAMES says
*-- is OCCUPIED, and VARSET writes the name and the value
*-- together -- so the shell already depended on write-before-
*-- read here, and the emitted zeros were paying for a guarantee
*-- nothing asked for. See the arena for the full trace.
*-- The exported bit, one byte per slot (docs/SYSCALL.md item
*-- 13c). `ds` beside the table it belongs to, for the SAME
*-- reason VARNAMES is `ds`: it must start at zero. A slot whose
*-- byte read as garbage would export a variable nobody marked,
*-- which is the one direction this bit must never fail in --
*-- Bourne's rule is that an UNEXPORTED variable never leaves
*-- the shell, and a scratch local silently reaching every child
*-- is exactly the leak `VAR=x` is supposed not to be. That
*-- argument is unchanged and still load-bearing; only the
*-- SOURCE of the zero moved, from the image to SH_INIT_ZR.

*---------------------------------------------------------------
* Tier 3 -- `:`, `.` (source), `set -x`, `<<`/`<<-` here-docs
* (docs/SH-FEATURES.md sec 4/6). `export` and the environment
* landed 2026-08-22 (docs/SYSCALL.md item 13c) -- see
* CHCK_BLTN_EXP/ENV_STAGE below; `env` as a command and `unset`
* are still out of scope, and that ruling says why.
*---------------------------------------------------------------
HDBODYLEN   equ   255         ;here-doc body cap, 8-bit cursor
                              ;-- best-effort truncation past
                              ;that, EXPBUF's own v1 precedent
SRC_MAXDEPTH equ  4           ;`.` nesting cap

*---------------------------------------------------------------
* CHCK_BLTN_DOT -- the `.` (source) builtin: read and execute
* FILE in the CURRENT shell -- variables/positional-parameters/
* construct-stack state ALL persist afterward, which is the
* entire point (a spawned child would have its own bank and
* could never reach back into this one). Reuses OPEN_REDIR_RD
* verbatim (MKPATH + SC_OPEN) -- relative to the current prefix,
* NOT PATHTAB-searched (v1; PATHTAB exists to find EXECUTABLES,
* and `.` is given an explicit or relative pathname the same way
* `cd DIR`/`< file` already are).
*
* Command-position only (NCMD==1), same shape as CD/EXIT/TEST
* above -- "ECHO ." never reaches here. On success this pushes
* CUR_IN_FD onto SRC_STACK, repoints CUR_IN_FD at the newly
* opened file, and `jmp`s MAINLOOP DIRECTLY -- it never returns
* to the rest of its own line, same shape EXIT already uses (a
* bare "." is meant to stand alone). MAINLOOP's own :eof path
* (above) is what pops SRC_STACK back and resumes the CALLER's
* script once the sourced file runs out -- including correctly
* when the sourced file itself contains WHILE/UNTIL/FOR loops
* (RW_DONE/CHCK_BLTN_BRK/RW_DONE_FOR all seek CUR_IN_FD, not a
* hardwired fd 0, for exactly this).
*
* OUT: carry SET only on an OPEN FAILURE or a too-deep nesting
* refusal (handled -- diagnostic, LASTSTATUS=1, control returns
* to the caller normally); carry CLEAR if this was not `.` at
* all. Success never returns here.
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
CHCK_BLTN_DOT
            lda   NCMD
            cmp   #1
            beq   :ncmd1
            clc
            rts
:ncmd1      lda   CMD_ARGC+0
            cmp   #2
            beq   :onearg
            clc
            rts
:onearg     lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
            lda   #<DOT_STR
            sta   PTR1
            lda   #>DOT_STR
            sta   PTR1+1
            jsr   STRCMP
            beq   :isdot
            clc
            rts
:isdot      jsr   SB_NOREDIR             ;V7: no redirection on
            bcc   :dotnord               ;  `.`; it used to be
            rts                          ;  dropped in silence
:dotnord    lda   CMD_ARGV+2
            sta   PTR0
            lda   CMD_ARGV+3
            sta   PTR0+1
            jsr   OPEN_REDIR_RD
            bcc   :opened
            lda   #<DOTERR_MSG
            ldx   #>DOTERR_MSG
            jsr   PR_ERRAX1
            sec
            rts
:opened     jsr   OPEN_HI                ;see shpath.s
            pha                          ;the new fd
            lda   SRC_DEPTH
            cmp   #SRC_MAXDEPTH
            bcc   :pushok
            pla
            jsr   CLOSE_FD_A            ;too deep -- close it,
                                        ;refuse, same "fail
                                        ;loudly" shape RW_
                                        ;OVERFLOW uses
            lda   #<DOTDEEP_MSG
            ldx   #>DOTDEEP_MSG
            jsr   PR_ERRAX1
            sec
            rts
:pushok     jsr   DOT_SAVE               ;SH-SEQ C: the rest of
                                         ;  this line, and the
                                         ;  context X runs in
            ldx   SRC_DEPTH
            lda   CUR_IN_FD
            sta   SRC_STACK,x
            inc   SRC_DEPTH
            pla
            sta   CUR_IN_FD
            stz   LASTSTATUS             ;an empty file is 0
            jmp   MAINLOOP

*---------------------------------------------------------------
* SLOT_PTR -- PTR1 = the continuation slot of SRC_DEPTH. The
* index goes into the HIGH byte only (slots are 256 apart), so
* CONT_BUF needs no alignment. CLOBBERS: A, PTR1.
*---------------------------------------------------------------
SLOT_PTR    lda   #<CONT_BUF
            sta   PTR1
            lda   #>CONT_BUF
            clc
            adc   SRC_DEPTH
            sta   PTR1+1
            rts

*---------------------------------------------------------------
* DOT_SAVE -- `.` is about to open a file: park what the jump
* to MAINLOOP would lose (docs/SH-SEQ-NOTES.md sec 5). Slot
* SRC_DEPTH gets the separator that ended the `.` segment (bit 7
* if an alias spliced on this line), EE_SUPP, STR_SRC, the old
* CS_FLOOR and then the REMAINDER of the line as text, cut from
* PRETOK at TOKENIZE's raw offset of the next segment's first
* token. Then the floor moves up to the current construct depth
* and, if this `.` sits in a tested position (EE_TESTED),
* errexit is suppressed until the pop. CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
DOT_SAVE    jsr   SLOT_PTR
            ldy   #0
            lda   PARSE_SEPOP
            ldx   ALI_MINPOS
            inx
            beq   :nali
            ora   #$80
:nali       sta   (PTR1),y
            iny
            lda   EE_SUPP
            sta   (PTR1),y
            iny
            lda   STR_SRC
            sta   (PTR1),y
            iny
            lda   CS_FLOOR
            sta   (PTR1),y
            iny
            lda   CSPTR
            sta   CS_FLOOR
            jsr   EE_TESTED
            beq   :cpy0
            lda   #1
            sta   EE_SUPP
:cpy0       ldx   TOKI
            cpx   NTOK
            bcs   :nul
            lda   TOKOFF,x
            tax
:cp         lda   PRETOK,x
            sta   (PTR1),y
            beq   :ret
            inx
            iny
            bne   :cp
:nul        lda   #0
            sta   (PTR1),y
:ret        rts

*---------------------------------------------------------------
* CONT_POP -- SH_EOF closed a `.` file and popped its fd. Close
* any construct X left open (CONT_UNWIND: one diagnostic, status
* 2, down to CS_FLOOR), put back the context `.` saved, and
* resume the caller's line: the remainder goes into LINEBUF and
* through SH_RUNLINE with the alias pass off (it is already
* expanded) and CONT_SEP set (:toknoerr applies the separator).
* An unwound X is a status 2 that goes through the errexit
* decision with the caller's own separator and context.
* Never returns. CLOBBERS: everything.
*---------------------------------------------------------------
CONT_POP    lda   CSPTR
            cmp   CS_FLOOR
            php                          ;Z: X closed all
            beq   :clean
            jsr   CONT_UNWIND
:clean      jsr   SLOT_PTR
            ldy   #1
            lda   (PTR1),y
            sta   EE_SUPP
            iny
            lda   (PTR1),y
            sta   STR_SRC
            iny
            lda   (PTR1),y
            sta   CS_FLOOR
            ldy   #0
            lda   (PTR1),y
            and   #$7F
            plp
            beq   :ndiag
            sta   PARSE_SEPOP
            jsr   ERREXIT_CK
*-- CONT_SEP is published only now: errexit can leave for the
*-- prompt or the EXIT trap, and a CONT_SEP left set would make
*-- the next line skip its alias pass (review finding M2).
:ndiag      ldy   #0
            lda   (PTR1),y
            sta   CONT_SEP
            clc
            lda   PTR1                   ;slot + 4 (the base is
            adc   #4                     ;  not page aligned)
            sta   PTR0
            lda   PTR1+1
            adc   #0
            sta   PTR0+1
            lda   #<LINEBUF
            sta   PTR1
            lda   #>LINEBUF
            sta   PTR1+1
            jsr   STRCPY
            stz   LMARK_OK               ;a loop here must spool
            jmp   SH_RUNLINE

DOT_STR     asc   "."
            dfb   0
DOTERR_MSG  asc   "sh: .: cannot open file"
            dfb   $8D,0
DOTDEEP_MSG asc   "sh: .: too many nested sources"
            dfb   $8D,0

*---------------------------------------------------------------
* CHCK_BLTN_CLN -- the `:` null command -- a fossil of
* Thompson's `goto` label marker. Always succeeds; any argv past
* ":" is accepted and ignored (real Bourne's own behaviour).
* Command-position only, same shape as the other builtins above.
* OUT: carry SET if the command was `:` (handled), carry CLEAR
* otherwise. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
CHCK_BLTN_CLN
            lda   NCMD
            cmp   #1
            bne   :no
            lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
            lda   #<COLON_STR
            sta   PTR1
            lda   #>COLON_STR
            sta   PTR1+1
            jsr   STRCMP
            bne   :no
*-- `: > F` must make F, and a builtin does not open
*-- redirects: with any, run /bin/TRUE instead
            jsr   PFX_HASRD
            bne   :ext
            stz   LASTSTATUS
            sec
            rts
:ext        lda   #<TRUE_STR
            sta   CMD_ARGV+0
            lda   #>TRUE_STR
            sta   CMD_ARGV+1
:no         clc
            rts

COLON_STR   asc   ":"
            dfb   0
TRUE_STR    asc   "TRUE"
            dfb   0

*---------------------------------------------------------------
* CHCK_BLTN_ECH -- `echo` as a builtin. Carry set = handled.
*
* WHY: every external ECHO is a 1276-byte BankCopy, 39.07 cyc/
* byte = ~50ms at 1MHz. A `while read ... do echo ... done` loop
* pays that PER ITERATION, which is what makes the shell feel
* clunky in exactly the place it should feel quick.
*
* docs/ANACHRONISMS.md test 1 licenses this: V7 kept echo
* external because fork+exec with SHARED TEXT made a process
* nearly free. maux copies a whole bank instead, so the old
* constraint does not merely still apply -- it is WORSE here.
* Departing from V7 is adapting to the machine, not modernising.
*
* SCOPE, and the fall-through is the safety property: this
* handles a lone stage (NCMD==1) writing to fd 1, optionally
* redirected with `>` or `>>`. ANY other shape returns carry
* CLEAR and the external binary runs exactly as before -- a
* pipeline, `< FILE`, an fd-specific target like `2> FILE`, or
* any `N>&M`. Nothing gets slower or changes meaning; some
* things get 50ms faster.
*
* Builtins dispatch BEFORE RUN_PIPELINE applies redirection, so
* `> FILE` is opened HERE rather than inherited -- which is the
* whole reason the scope is drawn where it is. A builtin that
* silently ignored `>` would be the quiet-wrong-answer class
* this shell has spent its life closing (docs/SH-FEATURES.md
* sec 17/20).
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
CHCK_BLTN_ECH
            lda   #<ECHO_STR
            sta   PTR1
            lda   #>ECHO_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :isecho
*-- :no sits HERE, not at the end: every guard below branches
*-- to it, and this routine is longer than an 8-bit branch.
:no         clc
            rts
*-- Shapes the builtin does not implement fall through to the
*-- external binary rather than being approximated here.
:isecho     lda   CMD_INFILE+0
            ora   CMD_INFILE+1
            bne   :no                    ;`< FILE`
            lda   DUPN
            bne   :no                    ;`N>&M`
            lda   CMD_TGTFD+0
            cmp   #FD_STDOUT
            bne   :no                    ;`2> FILE`
*-- `> FILE` / `>> FILE` fall through to the external binary,
*-- deliberately. The obvious implementation -- call the shell's
*-- own OPEN_REDIR_WR/_AP here -- CORRUPTS THE NEXT COMMAND'S
*-- REDIRECT: those routines drive a SINGLE shared set of shell
*-- parmlists (SH_OPARM, SH_CRT_PARM, SH_DSTRY_PARM, SH_PATHBUF,
*-- SH_APND_FD) that exist to be driven from BLD_FDCTS_STG at
*-- pipeline-build time, and calling them from a builtin leaves
*-- state the next BLD_FDCTS_STG reads. Measured: with the open
*-- path enabled, check-v1-system's very next line
*-- (`/bin/ECHO ABSPATH > /mnt/MAUX/SUB/ABSCMD`) produced an
*-- EMPTY file; with it removed, green. Giving the builtin its
*-- own parmlists would fix it and is the follow-up -- but a
*-- redirected ECHO spawning exactly as it does today is worth
*-- nothing lost, and the un-redirected case is where the 50ms
*-- per iteration actually hurts.
            lda   CMD_OUTFILE+0
            ora   CMD_OUTFILE+1
            bne   :no
*-- An enclosing construct may hold an output redirect (`FI >
*-- FILE`). That works by injecting an FDACT_DUP into a CHILD's
*-- fd-action list at spawn -- and a builtin never spawns, so
*-- without this it would write to the shell's own fd 1 and the
*-- construct's redirect would silently not apply. `read` has
*-- the mirror of this for input (sec 19, CR_FIND). Only a
*-- redirect whose target is fd 1 is ours to honour.
:tostdout   lda   #2                     ;2 = output redirect
            jsr   CR_FIND
            bcs   :plainout
            ldx   CRTGT
            cpx   #FD_STDOUT
            bne   :plainout
            sta   ECHOFD                 ;A = sh's own fd for it
            bra   :emit
:plainout   lda   #FD_STDOUT
            sta   ECHOFD
*-- Same shape as src/bin/echo.s: argv[1..argc-1] separated by
*-- single spaces, then one CR, and a bare ECHO prints just the
*-- CR; a first argv[1] of exactly "-n" suppresses that CR.
*-- Kept deliberately identical to echo.s's own -n check (2026-
*-- 09-15, see echo.s START/:chkflag) -- two implementations of
*-- one command is how they drift.
:emit       stz   ECHONFL
            lda   CMD_ARGC+0
            cmp   #1
            beq   :nl
*-- argv[1] is CMD_ARGV+2/+3 (entry 1, two bytes each); STRCMP
*-- (not -I) so "-N" and "-nx" are NOT the flag, exactly as
*-- echo.s's byte compare rejects them.
            lda   CMD_ARGV+2
            sta   PTR0
            lda   CMD_ARGV+3
            sta   PTR0+1
            lda   #<NFLAG_STR
            sta   PTR1
            lda   #>NFLAG_STR
            sta   PTR1+1
            jsr   STRCMP
            bne   :haveargs
            lda   #1
            sta   ECHONFL
            lda   CMD_ARGC+0
            cmp   #2
            beq   :nl                    ;`ECHO -n` alone
            lda   #2
            sta   ECHOI
            bra   :loop
:haveargs   lda   #1
            sta   ECHOI
:loop       lda   ECHOI
            asl   a
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            ldx   ECHOFD
            jsr   PUTS
            lda   ECHOI
            clc
            adc   #1
            cmp   CMD_ARGC+0
            bcs   :nl
            sta   ECHOI
            lda   #$A0                   ;space, high-bit-set
            ldx   ECHOFD
            jsr   PUTC
            bra   :loop
:nl         lda   ECHONFL                ;-n: stop before the CR
            bne   :noCR
            lda   #$8D                   ;CR, high-bit-set
            ldx   ECHOFD
            jsr   PUTC
*-- PUTC is BUFFERED (PUTS is not -- it flushes then writes
*-- unbuffered), so the trailing CR is still sitting in the
*-- buffer here. Flushing is not tidiness: without it a child
*-- spawned by the NEXT command could write first and the output
*-- would invert, which is docs/PROCIO.md sec 6 gate (a) all
*-- over again. `ECHO -n` alone reaches here too, with nothing
*-- to flush -- harmless, same fd's buffer PUTC would have used.
:noCR       ldx   ECHOFD                 ;not always fd 1 -- may
            jsr   SIO_FLUSH              ;  be a construct's fd.
                                         ;  Never CLOSED: the
                                         ;  fd is always someone
                                         ;  else's (fd 1, or a
                                         ;  construct's)
            stz   LASTSTATUS
            sec
            rts
ECHO_STR    asc   "ECHO"
            dfb   0
NFLAG_STR   asc   "-n"
            dfb   0

*-- CHCK_BLTN_SET and SET_ARG1 MOVED to shsgcld.s (the $D000
*-- segment, SH-ROOM2 step 2b); the usage message stays low,
*-- PR_ERRAX1 hands it to a syscall.
SETUSAGE_MSG asc   "usage: set -x|+x|-e|+e"
             dfb   $8D,0

*-- BG_RECORD is GONE (2026-09-08, docs/JOB-CONTROL.md Increment
*-- C): the `&` tail is shjob.s's JOB_BG, and the flat BG_PIDS
*-- list it pushed onto is the job table now -- one truth for
*-- `wait`, `jobs`, `fg` and `bg`. Its reasoning survives there:
*-- every stage, not just the last; `$?` = 0 for an async list.
*---------------------------------------------------------------
* FG_DECLARE / FG_CLEAR -- RUN_PIPELINE's FOREGROUND tail
* (docs/JOB-CONTROL.md Increment A), JOB_BG's twin. DECLARE
* hands the kernel the stages that actually spawned (CMD_PID
* [0..NCMD), zeros skipped) as this console's foreground job
* via SYS_TCSETFG, so ^C kills THEM -- and not a `&` job, and
* not another console's pipeline. CLEAR declares an empty set
* once the reap loop is done: at the prompt nothing is
* foreground, and ^C just reprompts.
*
* ONLY AN INTERACTIVE SHELL DECLARES. POSIX job control is an
* interactive-shell feature (`set -m` is off in a script); a
* `sh SCRIPT` or a `$( )` child is itself INSIDE the job its
* interactive parent declared, and the kernel's sweep reaches
* its children as descendants. If it declared too it would
* replace its parent's set with its own child and step out of
* the job -- a ^C would then kill the command and leave the
* script running, which is not what ^C means.
* CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
FG_DECLARE  ldy   #0
            ldx   #0
:loop       cpy   NCMD
            beq   FG_SETX
            lda   CMD_PID,y
            beq   :next                  ;that stage never
                                         ;spawned
            sta   FG_PARM+1,x
            inx
:next       iny
            bra   :loop
FG_CLEAR    ldx   #0
FG_SETX     lda   SH_INTERACT
            beq   :out
            stx   FG_PARM                ;count
:zero       cpx   #TCSETFG_MAX
            beq   :call
            stz   FG_PARM+1,x            ;unused slots: 0
            inx
            bra   :zero
:call       lda   #<FG_PARM
            sta   PTR0
            lda   #>FG_PARM
            sta   PTR0+1
            jsr   SC_TCSETFG
:out        rts

*-- CHCK_BLTN_WT (`wait`) MOVED to shjob.s with the job table it
*-- drains (Increment C). Same contract: operand-less only, 0.
*---------------------------------------------------------------
* SH_TRACE -- if SH_XTRACE is set, print "+ " then stage 0's own
* argv, space-separated, CR-terminated, to fd 2, before this
* command dispatches. ONE call site (MAINLOOP, right after both
* skip gates pass) covers every dispatch shape, builtins
* included -- real `set -x` traces those too. v1: stage 0 only,
* a later
* pipeline stage is not individually traced (documented gap, not
* a silent wrong answer: the FIRST stage's own words still
* print).
* CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
SH_TRACE    lda   SH_XTRACE
            bne   :go
            rts
:go         lda   #$AB                   ;'+' high-bit-set
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #$A0
            ldx   #FD_STDERR
            jsr   PUTC
            stz   SHT_I
:wloop      lda   SHT_I
            cmp   CMD_ARGC+0
            beq   :nl
            cmp   #0
            beq   :first
            lda   #$A0
            ldx   #FD_STDERR
            jsr   PUTC
:first      lda   SHT_I
            asl   a
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            jsr   PR_ERR
            inc   SHT_I
            bra   :wloop
:nl         lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            rts

SHT_I       ds    1

*---------------------------------------------------------------
* ERREXIT_CK -- `set -e` (docs/SH-FEATURES.md, 2026-09-15): a
* simple command's nonzero LASTSTATUS ends the shell, UNLESS it
* is the left side of `&&`/`||` (PARSE_SEPOP 2/3 -- the whole
* list's own value is still pending) or it is the TOP construct
* frame's own CONDITION (CSCOND,x -- an `if`/`while`/`until`
* test is allowed to fail). An INTERACTIVE shell (SH_INTERACT)
* abandons the rest of the line and reprompts instead of really
* exiting -- the same "loud, not silent" shape RW_SYNTAXERR
* already uses. Called once, right after RUN_PIPELINE (shlex.s),
* the ONE place every dispatch shape (builtin or spawned)
* rejoins with LASTSTATUS set. Never returns when it fires.
* CLOBBERS: A, X.
*---------------------------------------------------------------
ERREXIT_CK  lda   SH_ERREXIT
            beq   :no
            lda   LASTSTATUS
            beq   :no
            jsr   EE_TESTED
            bne   :no
:fire       lda   SH_INTERACT
            beq   :exitnow
            jmp   MAINLOOP
:exitnow    lda   LASTSTATUS
            jmp   SH_EXIT
:no         rts

*---------------------------------------------------------------
* EE_TESTED -- is the command being judged in a TESTED position
* (POSIX 2.8.1: a failure there must not end a `set -e` shell)?
* NZ (A nonzero) = yes: EE_SUPP (a tested `.` is running), the
* left of `&&`/`||` (PARSE_SEPOP 2/3), or the top frame's own
* condition list (CSCOND). Shared by ERREXIT_CK and DOT_SAVE so
* the two cannot drift. CLOBBERS: A, X.
*---------------------------------------------------------------
EE_TESTED   lda   EE_SUPP
            bne   :ret
            lda   PARSE_SEPOP
            cmp   #2
            beq   :yes
            cmp   #3
            beq   :yes
            lda   CSPTR
            beq   :ret
            tax
            dex
            lda   CSCOND,x
:ret        rts
:yes        lda   #1
            rts

*---------------------------------------------------------------
* CPTR_HEREDOC -- the here-doc lexer hijack: read subsequent
* physical lines directly off CUR_IN_FD, byte at a time via GETC
* -- no lookahead, same discipline READLINE itself already keeps
* (SHELL-SPLIT sec 15's "sh does not read ahead"), which is
* EXACTLY what lets a WHILE/UNTIL loop's own seek-back re-run
* this capture correctly on every iteration: the loop re-seeks
* CUR_IN_FD, MAINLOOP re-reads the SAME `<<WORD` line, and this
* routine re-consumes the SAME following lines off the (now-
* rewound) fd, fresh, every time.
*
* A line, after optional `<<-` leading-tab stripping, that
* matches HD_WPTR exactly ends the body. Every OTHER line is
* expanded (unless HD_QUOTED -- see below) and appended to
* HD_BODY, CR-terminated, up to HDBODYLEN -- best-effort
* truncation past that, matching EXPBUF's own "generous, not
* enforced" v1 precedent.
*
* Bourne's own rule (docs/SH-FEATURES.md sec 6/12): an UNQUOTED
* terminator (`<<WORD`, HD_QUOTED=0) expands each body line same
* as an ordinary word -- `$VAR`/`$?`/`$0`-`$9`/`$#`, through
* WORDEXPAND/DOEXPAND exactly as they already exist for a token
* (no second expander). A QUOTED terminator (`<<'WORD'`/
* `<<"WORD"`, HD_QUOTED=1) skips this entirely -- the body stays
* byte-for-byte literal, `$` included (the `ed` address case,
* `1,$s/.../.../`, docs/SH-FEATURES.md sec 12).
*
* CAPTURE TIME, not write time (this task's own report): this is
* also what makes a here-doc INSIDE a while/until loop show each
* iteration's OWN values, for free -- the loop's seek-back re-
* enters MAINLOOP, which re-reads the SAME `<<WORD` line and
* calls this routine fresh every iteration (the file-header
* comment above already explains why the RE-CAPTURE itself is
* correct; expansion just rides along, re-reading whatever
* LASTSTATUS/variables/positional parameters are current AT THAT
* call).
*
* True EOF before the terminator is a loud diagnostic to fd 2, a
* nonzero $?, and never a hang -- HD_UNTERM (below) never
* returns. A PARTIAL final line (EOF with no trailing CR) is
* still checked against the terminator first, same "still a
* line" leniency READLINE itself grants -- only EOF with NOTHING
* read for the CURRENT line is the true failure.
*
* IN: HD_WPTR (terminator text, NUL-terminated, inside the
* CURRENT line's own token -- this routine never touches
* LINEBUF, so it stays valid throughout), HD_STRIP, HD_QUOTED.
* OUT: HD_ACTIVE=1, HD_BODY/HD_LEN populated.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2, CURQFLAG (and everything
* WORDEXPAND/DOEXPAND themselves clobber, on an expanding line).
*---------------------------------------------------------------
CPTR_HEREDOC
*-- SH-SEQ C (M4): a string source (eval, a trap, -c, a
*-- remainder cut from one) holds no body, and reading one from
*-- CUR_IN_FD would take the caller's lines (or stdin).
            lda   STR_SRC
            beq   :notstr
            jmp   HD_UNTERM
:notstr     lda   #1                     ;SH-EXECLOOP: a `for`
            sta   LN_HD                  ;  after it: no replay
            stz   HDCUR
            stz   HDOVF
:nextline   stz   HDLLEN
            stz   HDESC
:rdloop     lda   CUR_IN_FD
            tax
            jsr   GETC
            bcc   :got
            lda   HDLLEN
            bne   :haveline              ;partial line -- still
                                         ;checked, READLINE's
                                         ;own leniency
            jmp   HD_UNTERM              ;nothing at all -- the
                                         ;real failure
:got        cmp   #$8D                   ;CR?
            beq   :hdcr
            ldy   HDLLEN
            cpy   #LINEMAX
            bcs   :hdov                  ;overflow: refused when
                                         ;the body ends
            sta   HDLINEBUF,y
            inc   HDLLEN
*-- POSIX 2.7.4 (SH-MLQUOTE): an ODD run of backslashes ends the
*-- line. With an UNQUOTED delimiter that backslash-newline is
*-- removed and the lines join BEFORE the delimiter compare; a
*-- QUOTED delimiter keeps both bytes and joins nothing.
            cmp   #ALC_DC
            bne   :hdnbs
            lda   HDESC
            eor   #1
            sta   HDESC
            bra   :rdloop
:hdnbs      stz   HDESC
            bra   :rdloop
:hdov       inc   HDOVF
            bra   :rdloop
:hdcr       lda   HDESC
            beq   :haveline
            lda   HD_QUOTED
            bne   :haveline
            dec   HDLLEN                 ;the backslash goes and
            stz   HDESC                  ;the next line is this
            bra   :rdloop                ;one's tail
:haveline   ldy   HDLLEN
            lda   #0
            sta   HDLINEBUF,y
            stz   HDSKIP
            lda   HD_STRIP
            beq   :cmpit
:tabskip    ldy   HDSKIP
            lda   HDLINEBUF,y
            cmp   #$89                   ;tab, high-bit-set
            bne   :cmpit
            inc   HDSKIP
            bra   :tabskip
:cmpit      lda   #<HDLINEBUF
            clc
            adc   HDSKIP
            sta   PTR0
            lda   #>HDLINEBUF
            adc   #0
            sta   PTR0+1
            lda   HD_WPTR
            sta   PTR1
            lda   HD_WPTR+1
            sta   PTR1+1
            jsr   STRCMP
            beq   :hddone                ;terminator matched
*-- Expand this body line, unless the terminator was quoted --
*-- see this routine's own header. CURQFLAG is forced to 0
*-- first: a heredoc body line is not a tokenized word, so
*-- there is no real per-token quote state for WORDEXPAND to
*-- consult otherwise (a stale CURQFLAG==1 left over from the
*-- LAST token PARSE classified would wrongly suppress
*-- expansion here).
            lda   HD_QUOTED
            bne   :hdnoexp
            stz   CURQFLAG
            jsr   WORDEXPAND              ;PTR0 in/out -- may
                                          ;repoint at an EXPBUF
                                          ;slice if `$` was
                                          ;found, unchanged
                                          ;otherwise (its own
                                          ;header)
            jsr   UNESC                   ;EMITB_LIT may have
                                          ;marked literal $IFS
                                          ;bytes low; a heredoc
                                          ;body never splits and
                                          ;leaves the parser
                                          ;RIGHT HERE -- this is
                                          ;its UNESC site (the
                                          ;argv/redirect funnels
                                          ;have their own)
:hdnoexp    ldy   #0
:apploop    lda   (PTR0),y
            beq   :appcr
            jsr   HD_APPENDB
            iny
            bra   :apploop
:appcr      lda   #$8D
            jsr   HD_APPENDB
            jmp   :nextline
:hddone     lda   HDOVF
            beq   :hdok
            jmp   HD_LONG                ;too long: refused
:hdok       lda   HDCUR
            sta   HD_LEN
            stz   HD_LEN+1
            lda   #1
            sta   HD_ACTIVE
            rts

*---------------------------------------------------------------
* HD_APPENDB -- IN: A = byte. Appends to HD_BODY at HDCUR,
* clamped to HDBODYLEN; past that HDOVF is set and the body is
* refused when its terminator is found (HD_LONG, shblt2.s).
* CLOBBERS: X.
*---------------------------------------------------------------
HD_APPENDB  ldx   HDCUR
            cpx   #HDBODYLEN
            bcs   :full
            sta   HD_BODY,x
            inc   HDCUR
            rts
:full       inc   HDOVF
            rts
