*---------------------------------------------------------------
* shresv.s -- reserved words and the construct stack:
* if/while/until/for/case, and compound redirection, `put` by
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
* RW_DISPATCH -- IN: RW_ID (1-14). Tail-jumps to the matching
* structural handler; each handler ends in RTS (back to
* CHCK_RESERVED's caller) except the DONE loop-back path, which
* jmps MAINLOOP directly. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
RW_DISPATCH lda   RW_ID
            cmp   #1
            bne   :c2
            jmp   RW_IF
:c2         cmp   #2
            bne   :c3
            jmp   RW_THEN
:c3         cmp   #3
            bne   :c4
            jmp   RW_ELIF
:c4         cmp   #4
            bne   :c5
            jmp   RW_ELSE
:c5         cmp   #5
            bne   :c6
            jmp   RW_FI
:c6         cmp   #6
            bne   :c7
            jmp   RW_WHILE
:c7         cmp   #7
            bne   :c8
            jmp   RW_UNTIL
:c8         cmp   #8
            bne   :c9
            jmp   RW_DO
:c9         cmp   #9
            bne   :c10
            jmp   RW_DONE
:c10        cmp   #10
            bne   :c11
            jmp   RW_FOR
:c11        cmp   #11
            bne   :c12
            jmp   RW_CASE
:c12        cmp   #12
            bne   :c13
            jmp   RW_ESAC
:c13        cmp   #13
            bne   :c14
            jmp   RW_BRACE
:c14        jmp   RW_RBRACE

*---------------------------------------------------------------
* RW_IF -- push an IF frame. CSSKIP starts 0 (let the condition
* list that follows execute) -- if an ENCLOSING frame is
* already skipping, CS_EFFSKIP's OR forces the residual
* condition command to not run regardless of this frame's own
* bit (see the file-header note above). CLOBBERS: A, X.
*---------------------------------------------------------------
RW_IF       lda   CSPTR
            cmp   #MAXCDEPTH
            bcc   :ok
            jmp   RW_OVERFLOW
:ok         ldx   CSPTR
            lda   #1
            sta   CSTYPE,x
            sta   CSCOND,x               ;`set -e`: A is 1 --
                                         ;  condition phase
            lda   SH_SKIP                ;SH-CASE2 A: a head
            sta   CSSKIP,x               ;  &&/|| skipped: DEAD,
            sta   CSTAKEN,x              ;  all of it skips, and
                                         ;  1 = a branch taken
            jsr   CR_INSTALL             ;sec 18 -- claim a
            jsr   CR_STARTSCAN           ;  pending redirect, or
            inc   CSPTR                  ;  scan for one
            rts

*---------------------------------------------------------------
* RW_WHILE / RW_UNTIL -- push a loop frame. If an ENCLOSING
* frame is already skipping, the whole construct is inert
* (CS_EFFSKIP's OR guarantees it) and this deliberately skips
* BOTH the seekability probe and its diagnostic -- a while/until
* nested inside dead code should not print a spurious warning
* about a loop that was never going to run anyway. Otherwise, a
* non-seekable fd 0 (CAP_LINE_MARK's own LMARK_OK, MAINLOOP)
* prints ONE diagnostic and permanently forces this frame's
* CSSKIP to 1 -- the doc's own "fail with a clear diagnostic
* rather than looping wrongly or hanging". CLOBBERS: A, X, Y.
*---------------------------------------------------------------
RW_WHILE    lda   #2
            bra   RW_LOOP_PUSH
RW_UNTIL    lda   #3
RW_LOOP_PUSH
            pha
            lda   CSPTR
            cmp   #MAXCDEPTH
            bcc   :ok
            pla
            jmp   RW_OVERFLOW
:ok         jsr   CS_EFFSKIP             ;parent's skip state,
            ora   SH_SKIP                ;SH-CASE2 A: or a head
            sta   CSTMP3                 ;  &&/|| skipped: dead,
                                         ;  a typed one must not
                                         ;  spool
            ldx   CSPTR
            pla
            sta   CSTYPE,x
            lda   SH_SKIP
            sta   CSTAKEN,x              ;every path: dead head
            jsr   CR_INSTALL             ;sec 18 -- on EVERY
                                         ;  path below, dead
                                         ;  frames included: it
                                         ;  also clears a stale
                                         ;  kind left here by an
                                         ;  earlier frame
            lda   CSTMP3
            bne   :dead
            lda   LMARK_OK
            bne   :seekable
*-- Console-loop spooling (docs/SH-FEATURES.md, 2026-09-15): a
*-- LIVE WHILE/UNTIL read from a non-seekable CUR_IN_FD (a tty
*-- or a $( ) pipe) used to be forced dead here with a
*-- diagnostic -- RW_DONE's own seek-back could never replay it.
*-- SPOOL_ENTER (below) copies the whole construct to a temp
*-- file and `.`-sources it instead: no frame is pushed here at
*-- all (X, CSPTR untouched), and it never returns on success.
            jmp   SPOOL_ENTER
:seekable   stz   CSSKIP,x
            lda   LP_PEND                ;the last body status
            sta   CSLPSTAT,x             ;  of a loop-back (0:
            stz   LP_PEND                ;  a fresh loop)
            lda   #1
            sta   CSCOND,x               ;`set -e`: condition
                                         ;  phase (ERREXIT_CK)
            jsr   CS_MARKHEAD
            jsr   CR_STARTSCAN           ;sec 18 -- may re-set
            inc   CSPTR                  ;  CSSKIP to 1
            rts
:dead       sta   CSSKIP,x               ;A = 1: a dead parent
            inc   CSPTR                  ;  dominates anyway, a
            rts                          ;  dead head must skip

*---------------------------------------------------------------
* RW_THEN -- close an IF frame's condition list, open its
* branch.
* CLOBBERS: A, X.
*---------------------------------------------------------------
RW_THEN     lda   CSPTR
            cmp   CS_FLOOR               ;C floor
            beq   :err
            jsr   CR_SCANTOP             ;sec 18 -- a scan pass
            beq   :scanning              ;  must keep CSSKIP=1
            ldx   CSPTR
            dex
            lda   CSTYPE,x
            cmp   #1
            bne   :err
            stz   CSCOND,x               ;`set -e`: condition
                                         ;  phase ends here
*-- A SUPPRESSED elif (RW_ELIF already forced CSSKIP=1 because
*-- an earlier branch already matched) never ran its own
*-- condition at all -- LASTSTATUS is stale, left over from
*-- whatever last actually executed. Reading it here anyway
*-- would let a coincidentally-zero stale value flip CSSKIP back
*-- to 0 and run a branch that was supposed to stay suppressed.
*-- CSTAKEN already says which case this is.
            lda   CSTAKEN,x
            bne   :suppressed
            lda   LASTSTATUS
            beq   :true
            lda   #1
            sta   CSSKIP,x
            stz   CSTAKEN,x
            rts
:true       stz   CSSKIP,x
            lda   #1
            sta   CSTAKEN,x
            rts
:suppressed lda   #1
            sta   CSSKIP,x
            rts
:scanning   rts
:err        jmp   RW_SYNTAXERR

*---------------------------------------------------------------
* RW_ELIF -- close the previous branch; if none has matched yet,
* reopen the condition-list phase (same shape as RW_IF's own
* push) -- once one HAS matched, force skip without evaluating
* the elif's own condition at all (docs/SH-FEATURES.md: a
* matched branch suppresses every later elif condition, not
* just its body). CLOBBERS: A, X.
*---------------------------------------------------------------
RW_ELIF     lda   CSPTR
            cmp   CS_FLOOR               ;C floor
            beq   :err
            jsr   CR_SCANTOP             ;sec 18, as RW_THEN
            beq   :scanning
            ldx   CSPTR
            dex
            lda   CSTYPE,x
            cmp   #1
            bne   :err
            lda   CSTAKEN,x
            beq   :fresh
            lda   #1
            sta   CSSKIP,x
            rts
:fresh      stz   CSSKIP,x
            lda   #1
            sta   CSCOND,x               ;`set -e`: a fresh elif
                                         ;  condition is running
:scanning   rts
:err        jmp   RW_SYNTAXERR

*---------------------------------------------------------------
* RW_ELSE -- unconditional branch iff nothing matched yet.
* CLOBBERS: A, X.
*---------------------------------------------------------------
RW_ELSE     lda   CSPTR
            cmp   CS_FLOOR               ;C floor
            beq   :err
            jsr   CR_SCANTOP             ;sec 18, as RW_THEN
            beq   :scanning
            ldx   CSPTR
            dex
            lda   CSTYPE,x
            cmp   #1
            bne   :err
            lda   CSTAKEN,x
            beq   :fresh
            lda   #1
            sta   CSSKIP,x
            rts
:fresh      stz   CSSKIP,x
            lda   #1
            sta   CSTAKEN,x
:scanning   rts
:err        jmp   RW_SYNTAXERR

*---------------------------------------------------------------
* RW_BRACE -- `{ list ; }` (docs/SH-FEATURES.md, 2026-09-15): a
* group that runs in the CURRENT shell, unlike `( )`'s subshell
* (shsub2.s CHCK_GROUP) -- so there is no fork/pipe/span-capture
* to do at all, only a construct-stack frame with no condition
* of its own: CSSKIP is just the ancestor state (CS_EFFSKIP,
* read BEFORE this push), so `{ X=1 ; }` leaves X set in THIS
* shell and a `{ }` nested inside dead code is dead too, with no
* separate flag (so is a group whose head `&&`/`||` skipped:
* SH_SKIP, SH-CASE2 A). `set -e`: CSCOND stays 0 -- a group is a
* body, never a condition. Redirect-on-terminator (`{ ... } >
* FILE`) reuses sec 18's scan-then-rewind UNCHANGED (CR_INSTALL/
* CR_STARTSCAN here, CR_RESCAN/CR_CLOSE at RW_RBRACE below) --
* the exact shape RW_IF already uses.
*
* LIVE and non-seekable (a tty): same shape as RW_LOOP_PUSH's
* own SPOOL_ENTER jump -- CR_STARTSCAN's own rewind cannot work
* on fd 0 either, so a `{` typed at the console spools its whole
* body through the temp file instead of pushing a frame here at
* all. SPOOL_ADJNEST (shtrap.s) treats `{`/`}` (ids 13/14) as an
* open/close pair, the same shape FOR/WHILE/UNTIL/DONE already
* are -- unlike IF/FI, which stay invisible to it because they
* nest on the real construct stack for free once replayed. A
* brace group needs the SAME free ride when it is NESTED inside
* an already-spooling loop, and gets it: net zero to SPOOL_NEST,
* same as any other correctly-paired open/close. CLOBBERS: A, X.
*---------------------------------------------------------------
RW_BRACE    lda   CSPTR
            cmp   #MAXCDEPTH
            bcc   :ok
            jmp   RW_OVERFLOW
:ok         jsr   CS_EFFSKIP
            ora   SH_SKIP                ;SH-CASE2 A: a skipped
            sta   CSTMP3                 ;  head is dead too
            ldx   CSPTR
            lda   #6
            sta   CSTYPE,x
            stz   CSCOND,x
            jsr   CR_INSTALL             ;on EVERY path, dead
                                         ;  frames included
            lda   CSTMP3
            bne   :dead
            lda   LMARK_OK
            bne   :seekable
            jmp   SPOOL_ENTER
:seekable   stz   CSSKIP,x
            jsr   CR_STARTSCAN
            inc   CSPTR
            rts
:dead       sta   CSSKIP,x               ;A = 1 (a dead parent
            inc   CSPTR                  ;  dominates anyway)
            rts

*---------------------------------------------------------------
* RW_RBRACE -- pop a `{ }` frame, same shape as RW_FI. CLOBBERS:
* A, X.
*---------------------------------------------------------------
RW_RBRACE   lda   CSPTR
            cmp   CS_FLOOR               ;C floor
            beq   :err
            ldx   CSPTR
            dex
            lda   CSTYPE,x
            cmp   #6
            bne   :err
            lda   SCAN_ACT
            cmp   CSPTR
            beq   :rescan
            jsr   CR_CLOSE
            dec   CSPTR
            rts
:rescan     jmp   CR_RESCAN
:err        jmp   RW_SYNTAXERR

*---------------------------------------------------------------
* RW_FI -- pop an IF frame. CLOBBERS: A, X.
*---------------------------------------------------------------
RW_FI       lda   CSPTR
            cmp   CS_FLOOR               ;C floor
            beq   :err
            ldx   CSPTR
            dex
            lda   CSTYPE,x
            cmp   #1
            bne   :err
            lda   SCAN_ACT               ;sec 18 -- the scan
            cmp   CSPTR                  ;  pass's own FI --
            beq   :rescan                ;  rewind, enter real
            jsr   CR_CLOSE               ;X = this frame
            dec   CSPTR
            jsr   CS_POPLIVE             ;SH-CASE2 A: a live
            bne   :done                  ;  `if` that took no
            stz   LASTSTATUS             ;  branch is 0 (POSIX)
:done       rts
:rescan     jmp   CR_RESCAN
:err        jmp   RW_SYNTAXERR

*---------------------------------------------------------------
* RW_DO -- close a WHILE/UNTIL frame's condition, open its body.
* WHILE runs the body iff the condition succeeded; UNTIL iff it
* FAILED -- the one place the two constructs differ at all
* (docs/SH-FEATURES.md: "until nearly free once while exists").
* CLOBBERS: A, X.
*---------------------------------------------------------------
RW_DO       lda   CSPTR
            cmp   CS_FLOOR               ;C floor
            beq   :err
            jsr   CR_SCANTOP             ;sec 18 -- covers FOR's
            beq   :scanning              ;  DO too (RW_DO_FOR is
                                         ;  only reached through
                                         ;  here)
            ldx   CSPTR
            dex
            lda   CSTYPE,x
            cmp   #2
            beq   :isloop
            cmp   #3
            beq   :isloop
            cmp   #4
            beq   :isfor
            bra   :err
:isfor      jmp   RW_DO_FOR
:isloop     stz   CSCOND,x               ;`set -e`: condition
                                         ;  phase ends here
            pha
            lda   LASTSTATUS
            beq   :met
            stz   CSTMP
            bra   :haveflag
:met        lda   #1
            sta   CSTMP
:haveflag   pla                          ;type: 2=WHILE, 3=UNTIL
            cmp   #2
            bne   :isu
            lda   CSTMP
            eor   #1
            bra   :store
:isu        lda   CSTMP
:store      ora   CSTAKEN,x              ;SH-CASE2 A: dead head
            sta   CSSKIP,x
:scanning   rts
:err        jmp   RW_SYNTAXERR

*---------------------------------------------------------------
* RW_DONE -- close a WHILE/UNTIL frame. CS_EFFSKIP (run BEFORE
* popping, so it still includes this frame's own bit) decides:
* 0 = the body just ran and the loop is still live -- seek fd 0
* back to CSHEAD, pop, and JUMP to MAINLOOP directly (a fresh
* frame gets pushed when the WHILE/UNTIL line is read again --
* never returns here). Nonzero = pop and fall through, resuming
* the rest of THIS line exactly where an ordinary command would.
* CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
*-- `:err` moved to the TOP and reached by `bra` from the type
*-- chain below, rather than sitting at the routine's end:
*-- sec 18's scan branches pushed it out of an 8-bit branch's
*-- reach, the same range squeeze this file has hit repeatedly.
RW_DONE     lda   CSPTR
            cmp   CS_FLOOR               ;C floor
            bne   :haveframe
:err        jmp   RW_SYNTAXERR
:haveframe  ldx   CSPTR
            dex
            lda   CSTYPE,x
            cmp   #2
            beq   :ckscan
            cmp   #3
            beq   :ckscan
            cmp   #4
            beq   :ckscan4
            bra   :err
*-- sec 18: the scan pass's own DONE, for either loop shape --
*-- rewind to the head line and enter the construct for real.
*-- Checked before the FOR/WHILE split so one test covers both;
*-- X still holds the frame index either way.
:ckscan4    lda   SCAN_ACT
            cmp   CSPTR
            beq   :rescan
            jmp   RW_DONE_FOR
:ckscan     lda   SCAN_ACT
            cmp   CSPTR
            bne   :isloop
:rescan     jmp   CR_RESCAN
:isloop     jsr   CS_EFFSKIP             ;CLOBBERS X (its own
            bne   :stop                  ;loop counter) -- X no
                                         ;longer holds this
                                         ;frame index once this
                                         ;returns. found the
                                         ;hard way: the stale x
                                         ;read a WRONG (usually
                                         ;still-zero) CSHEAD
                                         ;slot, so DONE seeked
                                         ;fd 0 to byte 0 instead
                                         ;of the loop head --
                                         ;the stack GREW instead
                                         ;of unwinding.
            ldx   CSPTR
            dex
            jsr   CR_HANDOFF             ;sec 18 -- this frame
                                         ;  about to be popped
                                         ;  and re-pushed by the
                                         ;  loop-back; its open
                                         ;  redirect fd goes
                                         ;  with it, never
                                         ;  reopened
            dec   CSPTR
            jmp   CS_GOHEAD              ;Tier 3 `.`: seeks on
                                         ;CUR_IN_FD, not always
                                         ;fd 0
:stop       ldx   CSPTR                  ;the loop is over for
            dex                          ;  good -- sec 18's fd
            jsr   CR_CLOSE               ;  goes with it
            dec   CSPTR
            jsr   CS_POPLIVE             ;SH-CASE2 A: its status
            bne   :done                  ;  is the last body's,
            lda   CSLPSTAT,x             ;  0 if no body ran
            sta   LASTSTATUS             ;  (X = popped frame)
:done       rts

*---------------------------------------------------------------
* RW_OVERFLOW / RW_SYNTAXERR -- diagnostic, nonzero $?, abandon
* the rest of the line (same shape PR_SYNTAX/MAINLOOP already
* use) -- "fail loudly past it" (docs/SHELL-SPLIT.md sec 15).
* Neither ever returns.
*---------------------------------------------------------------
RW_OVERFLOW lda   #<CSDEEP_MSG
            ldx   #>CSDEEP_MSG
            jmp   PR_ERRAX1M

RW_SYNTAXERR
            lda   #<CSSYN_MSG
            ldx   #>CSSYN_MSG
            jmp   PR_ERRAX1M

*-- PR_NOSEEK -- the "cannot seek" message and $? = 1; returns.
PR_NOSEEK   lda   #<NOSEEK_MSG
            ldx   #>NOSEEK_MSG
            jmp   PR_ERRAX1

*-- CS_SEEKHEAD -- X = a construct-stack frame index. Seek
*-- CUR_IN_FD (a sourced file's own fd, not always 0) to that
*-- frame's CSHEAD mark (3 bytes per frame, via LSEEK_BUF).
*-- OUT: LSEEK's carry (SET = the seek failed). CLOBBERS: A, Y,
*-- PTR0, CSTMP; X is not preserved.
CS_SEEKHEAD
            txa
            sta   CSTMP
            clc
            adc   CSTMP
            clc
            adc   CSTMP
            tay
            lda   CSHEAD,y
            sta   LSEEK_BUF
            lda   CSHEAD+1,y
            sta   LSEEK_BUF+1
            lda   CSHEAD+2,y
            sta   LSEEK_BUF+2
            lda   #<LSEEK_BUF
            sta   PTR0
            lda   #>LSEEK_BUF
            sta   PTR0+1
            lda   CUR_IN_FD
            ldy   #SEEK_SET
            jmp   LSEEK

*-- CS_GOHEAD -- CS_SEEKHEAD, then back to the prompt loop so
*-- MAINLOOP re-reads the head line; a failed seek says so and
*-- sets $? = 1 on the way. Never returns.
CS_GOHEAD   jsr   CS_SEEKHEAD
            bcc   :go
            jsr   PR_NOSEEK
            stz   RP_PEND            ;no replay line follows
            stz   LP_PEND            ;SH-CASE2 A: nor a re-push
:go         jmp   MAINLOOP

*---------------------------------------------------------------
* CS_EFFSKIP -- OUT: A = 0 if every open construct-stack frame
* (index 0..CSPTR-1) says "execute", 1 if ANY does not; Z
* reflects A (BEQ = execute). The single OR across the WHOLE
* stack, not just the top frame -- see the file-header note
* above for why that is what makes BREAK correct against a
* nested loop. CLOBBERS: A, X.
*---------------------------------------------------------------
CS_EFFSKIP  ldx   #0
:loop       cpx   CSPTR
            beq   :none
            lda   CSSKIP,x
            bne   :yes
            inx
            bra   :loop
:none       lda   #0
            rts
:yes        lda   #1
            rts

*---------------------------------------------------------------
* CS_POPLIVE -- the frame at index CSPTR has JUST been popped.
* OUT: Z set (A = 0, X = CSPTR) iff no remaining frame skips
* (the ANCESTORS only: the popped frame's own bit says nothing
* about whether it ran) and the frame's head ran: CSTAKEN is
* 0, which for an IF also means no branch was taken. Called by
* the terminators (FI, DONE) after the scan-pass guard, so the
* scan pass publishes nothing. CLOBBERS: A, X.
*---------------------------------------------------------------
CS_POPLIVE  jsr   CS_EFFSKIP
            bne   :r
            ldx   CSPTR
            lda   CSTAKEN,x
:r          rts

*---------------------------------------------------------------
* COMPOUND REDIRECTION -- `DONE < FILE`, `FI > FILE`, and the
* FOR equivalent (docs/SH-FEATURES.md sec 18).
*
* THE ORDER PROBLEM. sh is line-at-a-time: it reads `WHILE ...`,
* pushes a frame and runs the body, and only meets `DONE < FILE`
* after iteration 1 has already executed. Applying the redirect
* from DONE onward would leave iteration 1 unredirected, which
* is silently wrong.
*
* THE ANSWER (sec 18's ruling): enter the construct in SCAN
* mode -- CSSKIP=1, which is the same mechanism an untaken IF
* branch already uses, so nesting costs nothing extra -- walk to
* the matching terminator, OPEN whatever redirect is written
* there, then seek CUR_IN_FD back to the construct's own head
* line and enter it again for real with that fd installed. One
* extra skipped pass per construct ENTRY; a loop's own
* pop-and-re-push carries the record across iterations
* (CR_HANDOFF) rather than re-scanning each time.
*
* WHERE sec 18 IS OVERRULED, and why. That ruling's second half
* said the redirect must "relocate the script" -- move fd 0's
* object to a free fd, point CUR_IN_FD at it and install the
* redirect at fd 0. THERE IS NO dup/dup2 SYSCALL (inc/
* sc.proc.equ, sc.file.equ), so neither half of that
* is expressible: sh cannot move fd 0's object anywhere, and
* SC_OPEN returns a kernel-chosen fd, never 0. The `.` builtin
* is not the precedent it was taken for -- it OPENS A NEW FILE
* by name; it never moves fd 0.
*
* The same fact dissolves the obstacle. sh has NEVER rebound its
* own fds to redirect a command: it opens the file on a fd of
* its own and hands the child an FDACT_DUP record at spawn time
* (BLD_FDCTS_STG). A construct redirect is the same trick with a
* longer life -- the fd stays open for the frame, and every
* command run under it gets the dup. fd 0 and CUR_IN_FD are
* never touched, so the script keeps reading normally and
* obstacle 2 never arises. The one in-process reader of fd 0,
* the `read` builtin, consults CR_FIND instead (sec 16's
* motivating idiom is exactly `WHILE READ L ; DO ... ; DONE <
* FILE`).
*
* v1 limits, deliberate and loud rather than quiet: ONE redirect
* per construct (a terminator carrying both `<` and `>` keeps
* the `<`), and `N>&M` on a terminator is still refused by
* CK_ORPHRDIR rather than applied.
*---------------------------------------------------------------

*---------------------------------------------------------------
* CR_ISTERM -- IN: X = frame index, RW_ID = the reserved word
* just matched. OUT: carry SET if that word is the terminator
* which closes THAT frame's type -- FI for an IF, `}` for a `{
* }` group, DONE for WHILE/UNTIL/FOR. CLOBBERS: A.
*---------------------------------------------------------------
CR_ISTERM   lda   CSTYPE,x
            cmp   #1
            bne   :nif
            lda   RW_ID
            cmp   #5                     ;FI
            beq   :yes
            clc
            rts
:nif        cmp   #6
            bne   :isloop
            lda   RW_ID
            cmp   #14                    ;`}`
            beq   :yes
            clc
            rts
:isloop     cmp   #5                     ;a case: ESAC closes it
            bne   :isdone
            lda   RW_ID
            cmp   #12                    ;ESAC
            beq   :yes
            clc
            rts
:isdone     lda   RW_ID
            cmp   #9                     ;DONE
            beq   :yes
            clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* CR_TRYCAP -- CHCK_RESERVED calls this when a reserved word
* left NO residual command but PARSE may still have recorded
* redirects for the segment. OUT: carry SET = dealt with here,
* CK_ORPHRDIR must NOT also run; carry CLEAR = genuinely
* orphaned, refuse it the way sec 17 already does.
*
* Three ways to reach carry SET: this is the scan pass's own
* terminator (capture it); this is the REAL pass's terminator
* for a frame that already carries the redirect (stay quiet --
* re-opening `> FILE` here would truncate the output that was
* just written to it); or a redirect seen inside dead code or
* inside somebody else's scan, where diagnosing it would be a
* message about a line that is not running.
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
CR_TRYCAP   lda   CSPTR
            beq   :orph                  ;no construct open at
                                         ;  all -- a bare
                                         ;  `< FILE` line
            lda   SCAN_ACT
            beq   :notscan
            cmp   CSPTR
            bne   :quiet                 ;an INNER terminator,
                                         ;  met during somebody
                                         ;  else's scan
            ldx   CSPTR
            dex
            jsr   CR_ISTERM
            bcc   :quiet
            jmp   CR_OPEN                ;always returns carry
                                         ;  SET
:notscan    jsr   CS_EFFSKIP
            bne   :quiet
            ldx   CSPTR
            dex
            lda   CSRKIND,x
            beq   :orph
            jsr   CR_ISTERM
            bcc   :orph
:quiet      sec
            rts
:orph       clc
            rts

*---------------------------------------------------------------
* CR_OPEN -- the scan pass met its terminator: publish whatever
* redirect PARSE recorded for THIS segment into the PENDING
* record, opening the file NOW. Now, not later, because the
* filename lives in LINEBUF and the very next line read destroys
* it -- an fd survives that, a pointer does not.
*
* A terminator with no redirect at all (the common bare `DONE`)
* publishes kind 0, which is not nothing: it is what tells the
* re-entry "already scanned, do not scan again".
* OUT: carry SET, always. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
CR_OPEN     stz   PCR_KIND
            stz   PCR_FD
            lda   #FD_STDOUT
            sta   PCR_TGT
*-- A construct carries ONE output redirect (the slot below). A
*-- second `>`/`N>`/`>>`, or a `N<`, is a FILE record in the
*-- redirect list (KFIX3 items 1 and 2) and a construct has
*-- nowhere to keep it, so it is refused, loudly, not dropped.
            ldx   DUPN
:fscan      dex
            bmi   :nofile
            lda   DUP_SRC,x
            cmp   #FREC_RD               ;a FILE record
            bcc   :fscan
            bra   :failed
*-- `<&N` / `0<&N` on the terminator (a dup record for target 0)
*-- is a BORROWED input: the frame reads sh's own fd N and must
*-- never close it (kind bit 7, see CR_CLOSE / CR_FIND). Until
*-- 2026-10-21 the scan pass saw no FILE record, dropped the dup
*-- and the body read the tty. A close or other non-fd source is
*-- refused. `>&N` on a terminator is still dropped here.
:nofile     ldx   DUPN
:dscan      dex
            bmi   :nodup
            lda   DUP_TGT,x
            bne   :dscan
            lda   DUP_SRC,x
            cmp   #8
            bcs   :failed
            sta   PCR_FD
            lda   #$81
            sta   PCR_KIND
            sec
            rts
:nodup      lda   CMD_INFILE+0
            ora   CMD_INFILE+1
            beq   :ckout
            lda   CMD_INFILE+0
            sta   PTR0
            lda   CMD_INFILE+1
            sta   PTR0+1
            jsr   OPEN_REDIR_RD
            bcs   :failed
            jsr   OPEN_HI                ;out of `exec N<`'s way
            sta   PCR_FD
            lda   #1
            sta   PCR_KIND
            sec
            rts
:ckout      lda   CMD_OUTFILE+0
            ora   CMD_OUTFILE+1
            beq   :none
            lda   CMD_OUTFILE+0
            sta   PTR0
            lda   CMD_OUTFILE+1
            sta   PTR0+1
            lda   CMD_APPEND+0
            beq   :trunc
            jsr   OPEN_REDIR_AP
            bra   :wropened
:trunc      jsr   OPEN_REDIR_WR
:wropened   bcs   :failed
            jsr   OPEN_HI
            sta   PCR_FD
            lda   #2
            sta   PCR_KIND
            lda   CMD_TGTFD+0
            sta   PCR_TGT
:none       sec
            rts
:failed     jsr   PR_REDIRERR
            lda   #1
            sta   LASTSTATUS
            stz   PCR_KIND
            sec
            rts

*---------------------------------------------------------------
* CR_INSTALL -- IN: X = the frame index being pushed. Clear that
* frame's redirect slots (the arrays are reused at every depth,
* so a stale kind from a previous frame at the same index would
* name a CLOSED fd), then claim the pending record if there is
* one. Sets CR_JUSTINS for CR_STARTSCAN below.
* PRESERVES X. CLOBBERS: A.
*---------------------------------------------------------------
CR_INSTALL  stz   CR_JUSTINS
            lda   #0
            sta   CSRKIND,x
            sta   CSRFD,x
            lda   #FD_STDOUT
            sta   CSRTGT,x
            lda   PCR_PEND
            beq   :none
            stz   PCR_PEND
            inc   CR_JUSTINS
            lda   PCR_KIND
            sta   CSRKIND,x
            lda   PCR_FD
            sta   CSRFD,x
            lda   PCR_TGT
            sta   CSRTGT,x
:none       rts

*---------------------------------------------------------------
* CS_MARKHEAD -- IN: X = the frame index. Stores CSHEAD[X] =
* LINE_MARK + (RW_HEADPTR-LINEBUF): the loop head WORD's own fd
* 0 byte position, not column 0 of its physical line. A
* construct opened as a LATER segment on the same line (`N=0 ;
* WHILE ...`) used to rewind to column 0 and replay the earlier
* segment forever -- 2026-09-15, the one-line-loop-from-a-file
* bug. RW_HEADPTR-LINEBUF is the SAME offset SPOOL_ENTER already
* computes (shtrap.s), an 8-bit subtraction exact within one
* line (LINEMAX 255). PRESERVES X. CLOBBERS: A, Y.
*---------------------------------------------------------------
CS_MARKHEAD txa
            sta   CSTMP
            clc
            adc   CSTMP
            clc
            adc   CSTMP                  ;a = 3*x
            tay
            sec
            lda   RW_HEADPTR
            sbc   #<LINEBUF              ;head's own line offset
            clc
            adc   LINE_MARK
            sta   CSHEAD,y
            lda   LINE_MARK+1
            adc   #0
            sta   CSHEAD+1,y
            lda   LINE_MARK+2
            adc   #0
            sta   CSHEAD+2,y
            rts

*---------------------------------------------------------------
* CR_STARTSCAN -- IN: X = the frame index being pushed, CSPTR
* not yet incremented. Decide whether to enter this construct in
* scan mode, and if so set CSSKIP=1, record the head word's own
* mark (CS_MARKHEAD) in CSHEAD and arm SCAN_ACT.
*
* Four refusals, each load-bearing:
*   CR_JUSTINS -- this push IS the re-entry a scan just asked
*     for (or a loop's own next iteration); scanning again would
*     never terminate.
*   SEG_FIRST -- the rewind seeks to the START OF THE LINE, so a
*     construct opened as a LATER segment (`ECHO A ; IF ...`)
*     would replay the earlier segments. Refuse to scan instead:
*     that line behaves exactly as it did before this feature.
*   LMARK_OK -- fd 0 is a pipe or the tty; there is nothing to
*     seek back to. An interactive `if` must keep working.
*   an ancestor already skipping, or a scan already running --
*     dead code has no redirect to apply, and a scan inside a
*     scan would rewind to the wrong head.
* PRESERVES X. CLOBBERS: A, Y.
*---------------------------------------------------------------
CR_STARTSCAN
            stx   CRTMP
            lda   CR_JUSTINS
            bne   :no
            lda   SEG_FIRST
            beq   :no
            lda   LMARK_OK
            beq   :no
            lda   SCAN_ACT
            bne   :no
            jsr   CS_EFFSKIP             ;ancestors only -- this
            bne   :no                    ;  frame is not pushed
            ldx   CRTMP
            stz   PCR_KIND               ;a fresh scan starts
            stz   PCR_FD                 ;  with a clean record
            lda   #1
            sta   CSSKIP,x
            jsr   CS_MARKHEAD
            ldx   CRTMP
            inx                          ;1-based, so SCAN_ACT
            stx   SCAN_ACT               ;  == CSPTR exactly
            ldx   CRTMP                  ;  while this frame is
            rts                          ;  the top one
:no         ldx   CRTMP
            rts

*---------------------------------------------------------------
* CR_SCANTOP -- OUT: Z SET (BEQ) if the TOP frame is the one
* being scanned. THEN/ELIF/ELSE/DO all WRITE CSSKIP, and during
* a scan pass that write would clear the very flag holding the
* body inert. Callers have already proven CSPTR<>0.
* PRESERVES X, Y. CLOBBERS: A.
*---------------------------------------------------------------
CR_SCANTOP  lda   SCAN_ACT
            beq   :no
            cmp   CSPTR
            rts
:no         lda   #$FF                   ;force NE
            rts

*---------------------------------------------------------------
* CR_RESCAN -- the scan pass reached its terminator. Pop the
* scan frame, arm the pending record CR_OPEN just published, and
* seek CUR_IN_FD back to the construct's head line so MAINLOOP
* reads it again -- this time the push finds CR_JUSTINS set and
* runs for real. Never returns (jmps MAINLOOP), the same shape
* RW_DONE's own loop-back already uses. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
CR_RESCAN   stz   SCAN_ACT
            lda   #1
            sta   PCR_PEND
            ldx   CSPTR
            dex
            dec   CSPTR
            jsr   CS_SEEKHEAD
            bcs   :seekfail
            jmp   MAINLOOP
:seekfail   stz   PCR_PEND
            jsr   PR_NOSEEK
            jmp   MAINLOOP
