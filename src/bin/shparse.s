*---------------------------------------------------------------
* shparse.s -- PARSE, argv and redirect staging, and the first
* builtins (exit, cd, test/[), `put` by src/bin/sh.s (NOT a
* standalone binary -- the same put-module shape as
* sedexec.s/expr.eval.s). sh.s was 190,960 bytes stripped
* against real Merlin-8's 41,215-byte source buffer, which
* holds the resident manifest plus ONE put file at a time, so
* the body is split across eight modules. Boundaries are banner
* lines at global labels, chosen along the shell's own
* concerns. Every symbol here resolves against sh.s's equates,
* data and arena -- see that file's header for the scope.
*---------------------------------------------------------------
*---------------------------------------------------------------
* APPEND_ARGV -- append PTR0 (word ptr) to the CURRENT command's
* argv. Words beyond MAXARGV FAIL the line rather than being
* dropped: a limit that silently loses an argument runs the
* wrong command and says nothing, which is worse than refusing.
* The word sets PARSE_ERR 2 and SH_RUNLINE's :seg ends the line
* (message, `$?` 1, nothing run) -- true only since SH-DEFECTS
* 12; before it, that path fell through and ran the segment.
* A stage's block holds MAXARGV words AND a NULL (ARGSLOTS).
* Also
* flags commands beyond MAXCMD so PARSE can skip the line
* without corrupting the command tables. CLOBBERS: A, X.
*---------------------------------------------------------------
*---------------------------------------------------------------
* UNESC -- put back the high bits :bescput cleared. IN: PTR0 =
* a NUL-terminated word. OUT: the word is ordinary liba text
* again, in place. PTR0 unchanged. CLOBBERS: A, Y.
*
* IDEMPOTENT and safe on any word: a byte that already has bit 7
* set is unchanged, so calling it on a quoted word, a glob match
* read off the disk, or a word with no escapes in it at all
* costs a pass and changes nothing.
*
* WHERE IT MUST BE CALLED IS THE WHOLE DESIGN. The low form has
* to survive every metacharacter test -- WORDEXPAND's '$' scan,
* HASMETA's, GLOBMATCH's, CLASSIFY's -- and must not survive one
* byte further than that, because a filename or an argv string
* in the low form is simply the wrong bytes. So it is called at
* exactly the two places a word LEAVES the parser:
*
*   APPEND_ARGV   -- the single funnel for argv. Every path in
*                    GLOB_APPEND (quoted, no-metacharacter,
*                    unmatched-pattern literal, and each sorted
*                    glob match) ends here, so one call covers
*                    all four.
*   SET_INFILE / SET_OUT / SET_DUP -- redirect
*                    targets, which never glob and so never
*                    reach APPEND_ARGV. (SET_OUT takes its
*                    target FD as a number in A; only the word
*                    is UNESC'd.)
*---------------------------------------------------------------
UNESC       ldy   #0
:loop       lda   (PTR0),y
            beq   :done
            ora   #$80
            sta   (PTR0),y
            iny
            bne   :loop
:done       rts

APPEND_ARGV jsr   UNESC
*-- SH-CASE2 B: PAT_SPLIT enters here, WITHOUT UNESC, so a case
*-- pattern keeps its quote provenance (a cleared byte is
*-- literal
*-- to GLOBMATCH).
APPEND_RAW  lda   CURARGC
            cmp   #MAXARGV
            bcs   :toomany
            lda   NCMD
            cmp   #MAXCMD
            bcc   :slot
            lda   #1
            sta   PARSE_ERR
            rts
:slot       ldx   NCMD
            lda   STGOFF,x
            sta   ARGVOFF
            lda   CURARGC
            asl   a
            clc
            adc   ARGVOFF
            tax
            lda   PTR0
            sta   CMD_ARGV,x
            lda   PTR0+1
            sta   CMD_ARGV+1,x
            inc   CURARGC
:full       rts
:toomany    lda   #2
            sta   PARSE_ERR
            rts

*---------------------------------------------------------------
* SET_INFILE -- record PTR0 as the CURRENT command's `<` target.
* A later one for the SAME command silently overrides an earlier
* one (v1 -- no diagnostic for "redirected twice"); the output
* side (SET_OUT, below) keeps them all. CLOBBERS: A, X.
*---------------------------------------------------------------
SET_INFILE  jsr   UNESC
            lda   NCMD
            cmp   #MAXCMD
            bcc   :slot
            lda   #1
            sta   PARSE_ERR
            rts
:slot       lda   NCMD
            asl   a
            tax
            lda   PTR0
            sta   CMD_INFILE,x
            lda   PTR0+1
            sta   CMD_INFILE+1,x
            rts

*---------------------------------------------------------------
* SET_OUT -- record PTR0 as an output redirect of the CURRENT
* command: A = the target fd (`>`/`>>` pass 1, `N>`/`N>>` pass
* N), X = 1 for an append (`>>`), 0 for a truncating `>`.
*
* THE FIRST file redirect of a stage fills its slot (CMD_OUTFILE
* / CMD_TGTFD / CMD_APPEND); the pipeline builder opens it
* between the dups written before it and the dups written after
* it (DUP_POS). EVERY LATER ONE is a FILE record in the same
* ordered list the dups live in (KFIX3 item 1): `cmd > A 2> B`
* used to overwrite the slot, so A was never created and B took
* fd 2 or fd 1 depending on the order typed. A FILE record is a
* DUP_POS 1 entry, so it runs after the slot's file and after
* every earlier record, which is the left-to-right order POSIX
* gives and the order the list was appended in. The kind rides
* in DUP_SRC ($FE truncate, $FD append -- never a real source
* fd, which is 0-7, and never $FF, the close).
*
* Overflow (past MAXDUPS) fails the LINE, as SET_DUP does.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SET_OUT     sta   OUTTGT
            stx   OUTAP
            jsr   UNESC
            lda   NCMD
            cmp   #MAXCMD
            bcc   :slot
            lda   #1
            sta   PARSE_ERR
            rts
:slot       asl   a
            tax
            lda   CMD_OUTFILE,x
            ora   CMD_OUTFILE+1,x
            bne   :list
            lda   PTR0
            sta   CMD_OUTFILE,x
            lda   PTR0+1
            sta   CMD_OUTFILE+1,x
            ldx   NCMD
            lda   OUTTGT
            sta   CMD_TGTFD,x
            lda   OUTAP
            sta   CMD_APPEND,x
            rts
:list       lda   #FREC_WR               ;`>`
            ldy   OUTAP
            beq   :kind
            lda   #FREC_AP               ;`>>`
:kind       ldy   #1                     ;after the slot's file
            bra   ADD_FREC

*---------------------------------------------------------------
* SET_INN -- record PTR0 as a `N<` input redirect of the CURRENT
* command (KFIX3 item 2): open the word for READING on fd N,
* N = REDIR_FD (CLASSIFY's; `0<` is `<` and never gets here). It
* is a FILE record of the same ordered list as the later output
* redirects (kind $FC), positioned before or after the stage's
* first file redirect exactly as a dup is, so `3<A 2>&3` and
* `2>&3 3<A` mean what POSIX says they do. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SET_INN     lda   REDIR_FD
            sta   OUTTGT
            jsr   UNESC
            lda   NCMD
            cmp   #MAXCMD
            bcs   ADD_BAD
            asl   a
            tax
            ldy   #0
            lda   CMD_OUTFILE,x
            ora   CMD_OUTFILE+1,x
            beq   :pos0
            iny
:pos0       lda   #FREC_RD               ;READ
*-- falls through to ADD_FREC: A = the kind, Y = DUP_POS

*---------------------------------------------------------------
* ADD_FREC -- append one FILE record to the redirect list. IN: A
* = the kind ($FC read, $FD append, $FE truncate), Y = DUP_POS,
* OUTTGT = the target fd, PTR0 = the name, NCMD = the stage.
* Overflow (past MAXDUPS) fails the LINE. CLOBBERS: A, X.
*---------------------------------------------------------------
ADD_FREC    ldx   DUPN
            cpx   #MAXDUPS
            bcs   ADD_BAD
            sta   DUP_SRC,x
            tya
            sta   DUP_POS,x
            lda   NCMD
            sta   DUP_STG,x
            lda   OUTTGT
            sta   DUP_TGT,x
            lda   PTR0
            sta   DUP_PTRL,x
            lda   PTR0+1
            sta   DUP_PTRH,x
            inc   DUPN
            rts
ADD_BAD     lda   #1
            sta   PARSE_ERR
            rts

*---------------------------------------------------------------
* SET_DUP -- append one ORDERED fd-duplication record for the
* CURRENT stage (docs/SH-FEATURES.md sec 15). Unlike
* a stage's first file redirect, which owns ONE slot (SET_OUT
* keeps the later ones in this same list), dups are a LIST --
* because their whole meaning is positional:
*
*   CMD > FILE 2>&1   both streams -> FILE
*   CMD 2>&1  > FILE  stderr -> the OLD stdout, stdout -> FILE
*
* The two differ ONLY in order, so the order has to survive
* parsing. DUP_POS records the one ordering fact BLD_FDCTS_STG
* needs: whether this dup was written BEFORE (0) or AFTER (1)
* this stage's file redirect. "Has a file redirect been seen for
* this stage yet" is exactly "is CMD_OUTFILE[NCMD] non-NULL",
* which PARSE has already filled in by the time it gets here --
* so no separate counter is needed.
*
* Overflow (past MAXDUPS) fails the LINE rather than dropping a
* record, the same reasoning APPEND_ARGV's own MAXARGV check
* gives: a redirection silently lost runs the command with the
* wrong plumbing and says nothing. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SET_DUP     jsr   UNESC
            lda   NCMD
            cmp   #MAXCMD
            bcs   :bad
            lda   DUPN
            cmp   #MAXDUPS
            bcs   :bad
            ldx   DUPN
            lda   NCMD
            sta   DUP_STG,x
            lda   REDIR_FD
            sta   DUP_TGT,x
            lda   REDIR_SRC
            sta   DUP_SRC,x
            lda   NCMD
            asl   a
            tay                          ;CMD_OUTFILE is 2 bytes
            lda   CMD_OUTFILE,y          ;  per stage -- X still
            ora   CMD_OUTFILE+1,y      ;  holds DUPN throughout
            beq   :pos0
            lda   #1
            bra   :setpos
:pos0       lda   #0
:setpos     sta   DUP_POS,x
            inc   DUPN
            rts
:bad        lda   #1
            sta   PARSE_ERR
            rts

*---------------------------------------------------------------
* FINISH_CMD -- close out the command currently being built. A
* command with zero words (e.g. a bare trailing `|`, or an empty
* line) is silently dropped, not counted. CLOBBERS: A, X.
*---------------------------------------------------------------
FINISH_CMD  lda   CURARGC
            beq   :skip
            lda   NCMD
            cmp   #MAXCMD
            bcc   :slot
            lda   #1
            sta   PARSE_ERR
            bra   :skip
:slot
            ldx   NCMD
            lda   CURARGC
            sta   CMD_ARGC,x
            inc   NCMD
:skip       stz   CURARGC
            rts

*---------------------------------------------------------------
* CHCK_BLTN_EXT -- the ONLY builtin (docs/SH-DESIGN.md
* scope). If the parsed line is a single, unpiped command whose
* argv[0] is exactly "EXIT" (case ruling: file header), calls
* liba's EXIT (docs/PROCIO.md sec 4 -- flushes every buffered
* stream, THEN the raw SC_EXIT door; does not return). Otherwise
* returns normally. An optional argv[1] is
* read as a SINGLE decimal digit exit status (v1: no general
* decimal parser needed for this; SH-DESIGN does not require
* $?-argument decoding at all -- this is a small, cheap
* superset). CLOBBERS: A, X, Y, PTR0/PTR1.
*---------------------------------------------------------------
CHCK_BLTN_EXT
            lda   #<EXIT_STR
            sta   PTR1
            lda   #>EXIT_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcs   :notexit
            lda   CMD_ARGC+0
            cmp   #2
            bne   :status0
            lda   CMD_ARGV+2
            sta   PTR0
            lda   CMD_ARGV+3
            sta   PTR0+1
            jsr   PARSE_STATUS
            jmp   SH_EXIT
:status0    lda   #0
            jmp   SH_EXIT
:notexit    rts

EXIT_STR    asc   "EXIT"
            dfb   0

*---------------------------------------------------------------
* PARSE_STATUS -- decimal status at PTR0 -> A.
*
* Was a single `sbc #'0'` on the FIRST character, so `exit 12`
* returned 1 and `exit X` returned 40. Now: accumulate decimal
* digits, stop at the first non-digit, and saturate at 255
* rather than wrapping -- an exit status that quietly became a
* different number is a bad way to lose an afternoon.
*---------------------------------------------------------------
PARSE_STATUS
*-- NO `and #$7F` here (there used to be one): every string this
*-- file ever tokenizes is high-bit-set ASCII, so PTR0's bytes
*-- and the `#"0"`/`#":"` literals below are BOTH high-bit --
*-- merlin32 compiles a `"X"` character literal high-bit-set,
*-- the same convention ed.s's own digit check (:notdollar,
*-- src/bin/ed.s) already relies on with no masking at all.
*-- Stripping the input's high bit before comparing it against a
*-- still-high-bit literal made every digit comparison fail
*-- immediately -- PARSE_STATUS silently returned 0 for ANY
*-- digit string, on the very first byte, forever (Y never left
*-- 0). Caught by BREAK/CONTINUE's own count argument, which is
*-- the first caller to ever pass PARSE_STATUS a REAL nonzero
*-- digit and check the result -- EXIT's optional status digit
*-- shares this routine and was equally broken, just never
*-- gate-tested with a nonzero argument.
            stz   STATACC
            ldy   #0
:loop       lda   (PTR0),y
            beq   :done
            cmp   #"0"
            bcc   :done
            cmp   #":"                   ;'9'+1
            bcs   :done
            sec
            sbc   #"0"
            pha
            lda   STATACC          ;acc = acc*10, saturating
            cmp   #26
            bcs   :pin
            asl   a                      ;x2
            sta   STATACC
            asl   a                      ;x4
            asl   a                      ;x8
            clc
            adc   STATACC                ;x8 + x2 = x10
            sta   STATACC
            pla
            clc
            adc   STATACC
            bcs   :pin2
            sta   STATACC
            iny
            bra   :loop
:pin        pla
:pin2       lda   #255
            sta   STATACC
:done       lda   STATACC
            rts

STATACC     ds    1

*---------------------------------------------------------------
* CHCK_BLTN_CD -- the `cd` builtin.
*
* cd MUST be a builtin. A spawned child gets its own bank and
* exits; anything it changed about the working directory dies
* with it, so the change has to happen in the shell's own call.
* That is the same reason cd is a builtin in every Unix shell,
* and here it is not even a subtlety -- a child process cannot
* reach the parent's state at all.
*
* OUT: carry SET if the command was `cd` and has been handled;
* carry CLEAR to let the pipeline run as normal.
*---------------------------------------------------------------
CHCK_BLTN_CD
            lda   #<CD_STR
            sta   PTR1
            lda   #>CD_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcs   :notcd
            lda   CMD_ARGC+0
            cmp   #2
            beq   :witharg
            cmp   #1
            beq   :bare
            bra   :usage
:witharg    lda   CMD_ARGV+2
            sta   PTR0
            lda   CMD_ARGV+3
            sta   PTR0+1
            lda   #<CD_PATHBUF
            sta   PTR1
            lda   #>CD_PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            bra   :setpfx
* -- bare `cd` (docs/CD.md): send a 0-length pathname. The --
* kernel's PRC_SETPFX reads that as "go to the boot prefix" --
* -- the one place this ruling is implemented, so sh does not --
* need to know what that path actually is.
:bare       stz   CD_PATHBUF
:setpfx     lda   #<CD_PARM
            ldx   #>CD_PARM
            jsr   SC_SETPFX
            bcc   :ok
            lda   #1
            sta   LASTSTATUS
            lda   #<CD_ERR
            ldx   #>CD_ERR
            jsr   PR_ERRAX
            bra   :done
:ok         stz   LASTSTATUS
            bra   :done
:usage      lda   #1
            sta   LASTSTATUS
            lda   #<CD_USAGE
            ldx   #>CD_USAGE
            jsr   PR_ERRAX
:done       sec
            rts
:notcd      clc
            rts

CD_STR      asc   "CD"
            dfb   0
CD_ERR      asc   "cd: no such directory"
            dfb   $8D,0
CD_USAGE    asc   "usage: cd DIR"
            dfb   $8D,0
* -- CD_PATHBUF moved to the dum/dend block at the file's
* textual -- end (2026-08-21, binary-size reclamation) --
* written whole by -- MKPATH (the `cd DIR` case) or by an
* explicit stz (the bare -- `cd` case) immediately before
* SC_SETPFX ever reads it; never -- read first. See the dum
* block's own header for the full -- rationale.
CD_PARM     dfb   1              ;param_count for SET_PREFIX
CD_PARM_PTH da    CD_PATHBUF

*---------------------------------------------------------------
* CHCK_BLTN_TST -- the `test`/`[` builtin (docs/SH-SUBSET.md
* sec 6.3: `test` MUST be a BUILTIN here, not a binary -- spawn
* is length-driven and BankCopy alone is 75% of even a WARM
* spawn, so a re-spawned `test` binary would still cost ~0.06s
* PER CALL versus ~0.03s ONCE for the whole `sh` process as a
* builtin). Also accepts `[` in command position (sec 6.1),
* dropping a required trailing `]` before handing the rest to
* TEST_EVAL (src/bin/testeval.s) -- both ends of the transform
* happen HERE; testeval.s never sees `[`/`]` at all.
*
* Command-position only, the same rule CHCK_BLTN_CD/EXT already
* follow just above: only NCMD==1's own argv[0] is ever
* compared, so `ECHO TEST` or `ECHO [` -- `TEST`/`[` as an
* ORDINARY ARGUMENT -- never reaches here (docs/SH-SUBSET.md sec
* 6.1's "same rule reserved words already need").
*
* `[` with no trailing `]` at all is a usage error, status 2,
* WITHOUT calling TEST_EVAL -- there is nothing left to hand it
* once the missing `]` is detected.
*
* IN: CMD_ARGV/CMD_ARGC[0], as PARSE left them (stage 0 -- NCMD
* is 1 here, so STGOFF[0]=0 and CMD_ARGV+0 is argv[0]). OUT:
* carry SET if the command was `test`/`[` (handled -- do not
* spawn), carry CLEAR otherwise. When carry is SET, LASTSTATUS
* holds TEST_EVAL's own result (or 2, for the missing-`]` case)
* -- $?, `&&`, `||` all read this the same way they read
* RUN_PIPELINE's write; check-shlang proves it, not assumed.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
CHCK_BLTN_TST
            lda   #<TEST_STR
            sta   PTR1
            lda   #>TEST_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :istest
            lda   #<LBRACK_STR
            sta   PTR1
            lda   #>LBRACK_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :isbracket
            jmp   :nottest          ;`jmp`, not `bne` -- range
                                    ;(:nottest sits well past
                                    ;the whole routine now)

:istest     lda   CMD_ARGC+0
            sec
            sbc   #1               ;drop argv[0] ("TEST")
            tax
            lda   #<CMD_ARGV2
            sta   PTR0
            lda   #>CMD_ARGV2
            sta   PTR0+1
            bra   :doeval

:isbracket  lda   CMD_ARGC+0
            sec
            sbc   #1               ;drop argv[0] ("[")
            beq   :usageerr        ;nothing after `[` at all
            tax                    ;X = candidate argc -- STRCMP
                                   ;preserves X (string.s's own
                                   ;header)
            dex                    ;index of the LAST remaining
                                   ;token, 0-based
            txa
            asl   a
            clc
            adc   #<CMD_ARGV2
            sta   PTR2
            lda   #>CMD_ARGV2
            adc   #0
            sta   PTR2+1
            inx                    ;restore X = candidate argc
            ldy   #0
            lda   (PTR2),y
            sta   PTR0
            iny
            lda   (PTR2),y
            sta   PTR0+1
            lda   #<RBRACK_STR
            sta   PTR1
            lda   #>RBRACK_STR
            sta   PTR1+1
            jsr   STRCMP
            bne   :usageerr        ;last token was not `]`
            dex                    ;drop the trailing `]` itself
            lda   #<CMD_ARGV2
            sta   PTR0
            lda   #>CMD_ARGV2
            sta   PTR0+1

:doeval     jsr   TEST_EVAL
            sta   LASTSTATUS
            jsr   TST_REDIR
            sec
            rts

:usageerr   lda   #2
            sta   LASTSTATUS
            jsr   TST_REDIR
            sec
            rts

:nottest    clc
            rts

*---------------------------------------------------------------
* TST_REDIR -- the file-redirect side effect of `test`, which
* CHCK_BLTN_TST needs in miniature. `test`/`[` never runs
* RUN_PIPELINE (a builtin dispatches BEFORE RUN_PIPELINE ever
* applies redirection -- shbltn.s CHCK_BLTN_ECH's own header
* names this exact trap), and unlike echo, test has no external
* binary to fall back to when a target is present, so a
* redirected `test` used to silently create/truncate NOTHING --
* the "quiet wrong answer" this shell has otherwise closed
* everywhere (found by this task's own conformance suite: every
* `TEST ... > OUT` row came back "OUT: no such file").
*
* Every `>`/`>>` the command carries is opened and closed at
* once, wherever it names (`2> E` too), in source order: the
* FILE records of the redirect list first (DUP_SRC $FE truncate,
* $FD append -- shparse.s SET_OUT), then the stage's own slot
* (the LAST file redirect). KFIX3 item 1 moved every earlier
* `>` out of the slot into that list, and this stopped at the
* first `N>&M` or record, so `test x > A > B` made NEITHER file
* where the base made B (review F2). Test writes NOTHING to a
* target, so this is JUST the open-then-immediately-close side
* effect: no fd stays open, and none of STG_OUTFILE's per-stage
* CMD_OUTFD/CHILDMAP/EMIT_DUP bookkeeping is touched, which is
* exactly why this is safe where CHCK_BLTN_ECH's own header says
* a builtin driving these shared parmlists corrupted the NEXT
* command's own redirect: that failure came from leftover
* per-stage state, and this leaves none. `< FILE` and the dups
* are not acted on, as they never were; a failed open is
* skipped, as before.
* CLOBBERS: A, X, Y, PTR0, PTR1, DUPI.
*---------------------------------------------------------------
TST_REDIR   stz   DUPI
:next       ldx   DUPI
            cpx   DUPN
            beq   :slot
            inc   DUPI
            lda   DUP_SRC,x
            cmp   #FREC_AP
            bcc   :next              ;a dup or `N<`
            cmp   #FREC_WR+1
            bcs   :next              ;`N>&-`
            pha
            lda   DUP_PTRL,x
            sta   PTR0
            lda   DUP_PTRH,x
            sta   PTR0+1
            pla
            cmp   #FREC_AP
            beq   :rap
            jsr   OPEN_REDIR_WR
            bra   :ropen
:rap        jsr   OPEN_REDIR_AP
:ropen      bcs   :next
            jsr   CLOSE_FD_A
            bra   :next
:slot       lda   CMD_OUTFILE+0
            ora   CMD_OUTFILE+1
            beq   :none              ;no `>`/`>>` left
            lda   CMD_OUTFILE+0
            sta   PTR0
            lda   CMD_OUTFILE+1
            sta   PTR0+1
            lda   CMD_APPEND
            beq   :trunc
            jsr   OPEN_REDIR_AP
            bra   :opened
:trunc      jsr   OPEN_REDIR_WR
:opened     bcs   :none              ;open failed -- nothing to
                                     ;close, same as before
            jsr   CLOSE_FD_A
:none       rts

TEST_STR    asc   "TEST"
            dfb   0
LBRACK_STR  asc   "["
            dfb   0
RBRACK_STR  asc   "]"
            dfb   0

*---------------------------------------------------------------
* Tier 1 -- if/elif/else/fi, while/until/do/done, break/continue
* (docs/SH-FEATURES.md sec 4, docs/SHELL-SPLIT.md sec 15).
*
* AN EXPLICIT CONSTRUCT STACK, not recursion (SHELL-SPLIT sec
* 15) -- CSTYPE/CSSKIP/CSTAKEN/CSHEAD are parallel arrays,
* indexed by nesting depth, CSPTR the depth. MAXCDEPTH=8: past
* that, RW_OVERFLOW below fails LOUD (diagnostic + nonzero $? +
* abandon the line) rather than corrupt the stack or wrap.
*
* Every frame carries ONE mutable flag, CSSKIP -- "should code
* at THIS level run" -- and CS_EFFSKIP (below) is the OR of
* CSSKIP[0..CSPTR-1] across the WHOLE open stack, not just the
* top. That single OR is what makes a frame born under an
* already-false branch inert for its entire lifetime with no
* separate "dead" flag: whatever THEN/ELIF/ELSE/DO write into
* its OWN CSSKIP, an ancestor's 1 still dominates the OR. Also
* what makes BREAK correct against NESTED loops (CHCK_BLTN_BRK,
* below): setting the TARGET frame's CSSKIP alone forces the OR
* to 1 for every frame nested inside it too, without touching
* them -- they unwind one at a time, the ordinary way, as their
* own FI/DONE is textually reached.
*
* LOOPS RE-READ THEIR BODY BY SEEKING (SHELL-SPLIT sec 15): a
* WHILE/UNTIL frame's CSHEAD is the 3-byte fd-0 mark of the
* WHILE/UNTIL WORD ITSELF, not column 0 of its line --
* CS_MARKHEAD (shresv.s) adds the head word's own offset
* (RW_HEADPTR-LINEBUF) to CAP_LINE_MARK's line-start mark, so
* `N=0 ; WHILE ... ; DONE` on ONE line rewinds past `N=0`
* instead of replaying it forever (2026-09-15 fix; text before
* the head on the same line is skipped, not replayed). DONE
* seeks back and JUMPS to MAINLOOP directly when the loop is
* still live, so the loop's whole body costs three bytes of
* state and zero buffer, at any length (SHELL-SPLIT's own
* promise).
*---------------------------------------------------------------
MAXCDEPTH   equ   8

*---------------------------------------------------------------
* CHCK_RESERVED -- see the extended comment at its call site in
* MAINLOOP, above. IN: CMD_ARGV/CMD_ARGC/NCMD as PARSE left it.
* OUT: RW_ID = 0 (not reserved) or 1-14 (IF/THEN/ELIF/ELSE/FI/
* WHILE/UNTIL/DO/DONE/FOR/CASE/ESAC/`{`/`}`, RESV_LO/HI's own
* order --
* the range said 1-9 until 2026-08-25 and had been wrong since
* FOR landed); RW_HASRES = 1 if
* a residual command remains for the caller to dispatch. Jumps
* straight to MAINLOOP (never returns) on a syntax error or a
* construct-stack overflow. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
CHCK_RESERVED
            lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
            ldx   #0
:loop       cpx   #RESV_CNT
            bne   :try
            stz   RW_ID
            rts
:try        lda   RESV_LO,x
            sta   PTR1
            lda   RESV_HI,x
            sta   PTR1+1
            jsr   STRCMPI
            beq   :found
            inx
            bra   :loop
:found      inx                          ;1-based id
            stx   RW_ID
*-- RW_HEADPTR (docs/SH-FEATURES.md, console-loop spooling):
*-- CMD_ARGV[0] BEFORE RW_SHIFT drops it -- the reserved word's
*-- own address inside LINEBUF (TOKENIZE's own token pointer,
*-- not EXPBUF -- a reserved word is never expanded). SPOOL_
*-- ENTER (shresv.s) reconstructs a non-seekable loop's head
*-- text from here onward when RW_WHILE/RW_LOOP_PUSH/RW_FOR
*-- decide to spool instead of pushing a frame.
            lda   CMD_ARGV+0
            sta   RW_HEADPTR
            lda   CMD_ARGV+1
            sta   RW_HEADPTR+1
            jsr   RW_SHIFT
*-- A structural word with NO residual text (bare FI/DONE/ELSE/
*-- THEN) may still carry redirects PARSE recorded for this
*-- segment: `FI < FILE` parses as the word FI plus a `<`. They
*-- are orphaned -- the construct is closing and there is no
*-- command to attach them to -- and dropping them silently is
*-- docs/SH-FEATURES.md sec 17's quiet wrong answer. Refuse.
*-- CR_TRYCAP runs FIRST (docs/SH-FEATURES.md sec 18): a
*-- terminator's redirect is no longer always orphaned -- it may
*-- be the construct's own, which is captured there and refused
*-- only if it is not.
*--
*-- CORRECTION, 2026-08-22, to the note this comment replaced.
*-- That note said the check had to live here because MAINLOOP's
*-- own RW_HASRES branch "demonstrably never reaches a
*-- terminator segment -- probed with an unconditional call: it
*-- fired for a bare `< FILE` and never for `FI`". Both call
*-- sites reach it; the probe line was `IF TEST -f F; THEN CAT;
*-- FI < F > CRT`, whose `;` are GLUED to the preceding word.
*-- TOKENIZE splits on whitespace ONLY, so `F;` and `CAT;` are
*-- ordinary words: that line is ONE segment whose argv is
*-- `TEST -f F; THEN CAT; FI` after IF is shifted off, `test`
*-- returns its usage error 2, and no terminator segment ever
*-- exists to fire anything. `FI > FILE` -- spelled with the
*-- separators spaced -- records CMD_OUTFILE[0] exactly as a
*-- simple command does, and CK_ORPHRDIR has always fired for
*-- it. The `$? = 2` that sec 17 recorded as "pre-existing and
*-- unexplained" is the same usage error, from the same glued
*-- `;`.
            lda   RW_HASRES
            bne   :hasres
            jsr   CR_TRYCAP
            bcs   :hasres
            jsr   CK_ORPHRDIR
:hasres     jsr   RW_DISPATCH
            rts

*---------------------------------------------------------------
* RW_SHIFT -- drop stage 0's argv[0] (the reserved word just
* matched), shifting every word behind it down one slot and
* decrementing CMD_ARGC+0. Sets RW_HASRES. Only ever touches
* stage 0 -- STGOFF[0] is always 0, and a reserved word is only
* ever recognised as stage 0's own argv[0] (CHCK_RESERVED,
* above) -- so a piped condition ("IF TEST -F X | GREP Y; THEN")
* shifts correctly with no STGOFF math at all; stages 1+ are
* untouched.
*
* The vacated TRAILING slot (index CMD_ARGC+0 after the
* decrement) is explicitly zeroed once the shift is done --
* ZR_CMD_TABLES only zeroes CMD_ARGV once, before PARSE ever
* runs, and a shift-in-place otherwise leaves the OLD last
* word's pointer sitting one slot past the new count, unless it
* happens to have been overwritten already. A spawned child's
* own argv walk trusts a NUL pointer, not CMD_ARGC -- ARGV_PTR_
* STG/PSTG_TO_CHILD hand the child the raw block, so a stale
* pointer there reads as ONE MORE argument no one asked for
* (proven the hard way: "DO ECHO WLOOP" printed "WLOOP WLOOP",
* and "WHILE CMP A B" handed cmp a bogus THIRD operand that
* never let the condition read as equal, no matter how long the
* loop actually ran). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
RW_SHIFT    lda   CMD_ARGC+0
            sec
            sbc   #1
            sta   CMD_ARGC+0
            beq   :zeronone
            ldx   #0
:shloop     cpx   CMD_ARGC+0
            beq   :shdone
            txa
            asl   a
            tay
            lda   CMD_ARGV+2,y
            sta   CMD_ARGV,y
            lda   CMD_ARGV+3,y
            sta   CMD_ARGV+1,y
            inx
            bra   :shloop
:shdone     lda   #1
            sta   RW_HASRES
            bra   :zerotrail
:zeronone   stz   RW_HASRES
:zerotrail  lda   CMD_ARGC+0
            asl   a
            tay
            lda   #0                     ;no STZ abs,Y mode --
            sta   CMD_ARGV,y             ;LDA #0/STA instead
            sta   CMD_ARGV+1,y
            rts

