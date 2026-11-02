*---------------------------------------------------------------
* shsubst.s -- command substitution and ( ) groups: the nested-
* sh spawn, the body pipe and the variable serialiser, `put` by
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
* SUB_RUN -- IN: SUBTXT = the captured command text. Splits it
* on runs of $A0 IN PLACE into SUBARGV (a NUL-POINTER-terminated
* pointer array, the exact shape SC_SPAWN wants and CMD_ARGV
* already uses), resolves argv[0] against PATHTAB the same way
* RSLV_PTH_STG does for a pipeline stage, spawns it with fd 1 on
* a fresh pipe, drains that pipe into EXPBUF through EMITB with
* trailing CRs suppressed, and reaps the child into LASTSTATUS.
*
* TRAILING NEWLINES ARE STRIPPED WITH NO BUFFER: SUBPEND counts
* CRs seen and holds them back; a non-CR byte flushes the held
* run first, and EOF simply discards it. That is exactly POSIX's
* "remove all trailing newlines" without ever needing to know
* where the end is in advance -- which matters here, because the
* capture is emitted straight into the destination word as it
* arrives.
*
* Every failure (no pipe, no such command) is a diagnostic plus
* a nonzero LASTSTATUS and an EMPTY substitution, then a normal
* return -- the line keeps going, exactly as RUN_PIPELINE's own
* failed spawn does. Only the SYNTAX refusals in SUB_GRAB
* abandon the line.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
*---------------------------------------------------------------
* SUB_RUN -- run the captured body and leave its output in the
* expansion buffer.
*
* IT SPAWNS A NESTED `sh` AND HANDS IT THE BODY ON fd 0, which
* is what src/bin/sh.s's own SUB_GRAB comment proposed as the
* design candidate and what docs/SH-SUBSHELL.md wanted. It used
* to split the body on spaces and spawn the FIRST word as a
* command, which is why `| < > ; &` had to be refused: an
* operator would have been handed to that command as a literal
* argument. A whole shell handles them, so the refusal is gone.
*
* `sh` reads its script from fd 0 and takes no flags -- there is
* no `-c` to add (docs/SH-FEATURES.md). So the body travels as
* bytes down a pipe, exactly the way `SH < script` already
* works, and nesting shells is already proven cheap: lazy free
* makes a warm respawn skip the image load (check-shwarm, 8.1x).
*
* THE BODY IS WRITTEN BEFORE THE CHILD EXISTS, and that ordering
* is the whole deadlock argument. With two pipes, a parent still
* writing the body while the child is already writing output can
* wedge: each blocks on a full ring the other must drain. Since
* SUBMAX is 96 and PIPE_RNG_SIZE is 256, the entire body fits
* the ring in one go with nobody reading -- so the parent is
* never blocked, and by the time the child runs, the parent's
* only job is to drain. One-directional at every instant.
*
* WHAT THIS DOES NOT YET DO -- and it is the semantic half:
* WORDEXPAND still expands `$` INSIDE the body before it is
* captured, so `$(V=2; echo $V)` sees the parent's V and
* `$(echo '$V')` loses its quotes. POSIX passes the body
* VERBATIM and lets the subshell evaluate it. Fixing that means
* the expander must skip a `$(`..`)` span AND the parent must
* pass its unexported variables down, because they would no
* longer arrive pre-substituted. Both, together, or `$V` breaks.
* docs/SHELL-GAPS.md sec 2.
*---------------------------------------------------------------
SUB_RUN     jsr   SUB_PREPCH            ;child + body pipe, or a
            bcs   :prepfail        ;a diagnostic already
            lda   SUBGONE          ;said why
            bne   :empty

            lda   #<SUBPIPEB             ;pipe B -- the capture
            sta   PTR0
            lda   #>SUBPIPEB
            sta   PTR0+1
            jsr   SC_PIPE
            bcc   :pipedB
            jmp   :pipefail
:pipedB     lda   SUBPIPEB
            sta   SUBRFD
            lda   SUBPIPEB+1
            sta   SUBWFD

            stz   FDAIDX
            jsr   EMIT_USERFDS           ;the user's fds, first
            lda   SUBBRFD                ;child fd 0 <- the body
            jsr   EMIT_DUP0_A
            lda   SUBBRFD
            jsr   EMIT_CLOSE_A
            lda   SUBWFD                 ;child fd 1 -> capture
            jsr   EMIT_DUP1_A
            lda   SUBWFD
            jsr   EMIT_CLOSE_A
            jsr   EMIT_END
            jsr   SUB_DOSPAWN
            bcc   :spawnok
            jsr   PR_SPAWNFAIL
            lda   SUBBRFD
            jsr   CLOSE_FD_A
            lda   SUBWFD
            jsr   CLOSE_FD_A
            lda   SUBRFD
            jsr   CLOSE_FD_A
            lda   #1
            sta   LASTSTATUS
            rts
:pipefail   lda   SUBBRFD                ;pipe B failed with A
            jsr   CLOSE_FD_A             ;still open
            jsr   PR_PIPEFAIL
            lda   #1
            sta   LASTSTATUS
            rts
:empty      stz   LASTSTATUS             ;`$()` -- empty, and a
:prepfail   rts                          ;success, not a fault
*-- The parent's copy of the BODY read end goes too: the child
*-- has its own, and a surviving reader here is one more thing
*-- holding the pipe open.
:spawnok    sta   SUBPID
            lda   SUBBRFD
            jsr   CLOSE_FD_A
            lda   SUBPID
            jmp   :spawned                ;`jmp`, not `bra` --
                                          ;range (the variable
                                          ;serialiser now sits
                                          ;between the two)

*---------------------------------------------------------------
* SUB_WRBODY -- the captured text plus one CR, onto the body
* pipe's write end. NOTHING LANDS IN THE PIPE HERE: PUTC
* full-buffers every fd >= 3 (512B trigger, src/liba/stdio.s),
* so the bytes sit in liba's LC-bank buffer until the FCLOSE at
* the call site flushes them. An earlier version of this header
* claimed the opposite ("a pipe fd is past the 0-2 range liba's
* stdio buffers") and the bare CLOSE_FD_A written against that
* claim dropped the whole body -- empty capture, $? = 0, no
* diagnostic. The index lives in a cell because PUTC does not
* promise Y.
*---------------------------------------------------------------
SUB_WRBODY  stz   SUBBI
:w          ldy   SUBBI
            lda   SUBTXT,y
            beq   :wend
            ldx   SUBBWFD
            jsr   PUTC
            inc   SUBBI
            bra   :w
:wend       lda   #$8D                   ;sh needs the line
            ldx   SUBBWFD                ;terminated
            jsr   PUTC
            rts


*---------------------------------------------------------------
* SUB_PREPCH -- everything `$( )` and `( )` do IDENTICALLY
* before they diverge: resolve `sh`, build its argv, make the
* BODY pipe,
* serialise the parent's unexported variables into it, write the
* body, and flush-close the write end.
*
* Factored 2026-08-27 because SUB_GROUP had been written by
* copying SUB_RUN, and the copy is what pushed sh.bin through
* check-modules' 16 KB tripwire. docs/SH-SUBSET.md sec 7 says
* that tripwire means "a subsystem arrived, discuss it" rather
* than "trim a feature" -- so nothing was trimmed: the DUPLICATE
* was removed, which is the honest reading of a size gate firing
* on code written an hour earlier.
*
* OUT: carry CLEAR = ready. SUBBRFD is the body pipe's read end
* (the child's fd 0), SUBPATH/SUBARGV are staged, and SUBGONE is
* nonzero iff the body was EMPTY -- an empty `$()`/`( )` is a
* success with nothing to run, and the caller returns without
* spawning. Carry SET = failed; the diagnostic is already
* printed, LASTSTATUS is already 1, and no fd is left open.
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
SUB_PREPCH  stz   SUBGONE
            lda   SUBTXT
            bne   :havebody
            inc   SUBGONE                ;empty body -- nothing
            clc                    ;to run, not a fault
            rts
*-- The child is `sh`, resolved the same way any command word is
*-- -- through PATH then PATHTAB -- rather than a hardcoded
*-- /mnt/MAUX/SH. A shell that cannot find itself should say so.
:havebody   lda   #<SUBSH_STR
            sta   PTR0
            lda   #>SUBSH_STR
            sta   PTR0+1
            jsr   BUILD_PATH
            bcc   :haveshp
            jsr   PR_CMDNOTFND
            bra   :fail1
:haveshp    lda   PTR0
            sta   SUBPATH
            lda   PTR0+1
            sta   SUBPATH+1
*-- argv is just { "SH", NULL }: sh reads no flags, and argv
*-- beyond argv[0] would become the child's POSITIONAL
*-- parameters, which a subshell must not inherit.
            lda   #<SUBSH_STR
            sta   SUBARGV
            lda   #>SUBSH_STR
            sta   SUBARGV+1
            stz   SUBARGV+2
            stz   SUBARGV+3

            lda   #<SUBPIPEA             ;the BODY pipe
            sta   PTR0
            lda   #>SUBPIPEA
            sta   PTR0+1
            jsr   SC_PIPE
            bcc   :piped
            jsr   PR_PIPEFAIL
            bra   :fail1
:piped      lda   SUBPIPEA
            sta   SUBBRFD
            lda   SUBPIPEA+1
            sta   SUBBWFD
*-- The parent's UNEXPORTED variables go FIRST, as assignments
*-- the child runs before the body -- see SUB_WRVARS. Exported
*-- ones are not here; ENV_STAGE carries those at spawn time.
            jsr   SUB_WRVARS
            bcc   :varsok
*-- FCLOSE, NOT a bare close, on THIS path too. PUTC has very
*-- likely already buffered earlier variables' lines, and a bare
*-- SC_CLOSE leaves those bytes AND their counts in liba's
*-- per-fd buffer -- counts reset only on a flush. The fd number
*-- is then reused by the next substitution's pipe, which
*-- inherits the stale bytes: a corrupt body first, and a hang
*-- once the carried total crosses the 512-byte flush threshold
*-- and writes into a ring nobody drains. Exactly the bug class
*-- this feature opened with, reintroduced on the ERROR path
*-- while the success path was fixed. Found by review, not by a
*-- gate -- see the gate added alongside.
            ldx   SUBBWFD           ;refused: flush and drop
            jsr   FCLOSE            ;whatever was buffered
            lda   SUBBRFD
            jsr   CLOSE_FD_A
            lda   #<SUBVAR_MSG
            ldx   #>SUBVAR_MSG
            jsr   PR_ERRAX
            bra   :fail1
:varsok     jsr   SUB_WRBODY
*-- FCLOSE, NOT CLOSE_FD_A. PUTC FULL-BUFFERS an fd >= 3 (512B
*-- trigger, src/liba/stdio.s SIO_PUTC), so the body is still in
*-- liba's buffer here, and a bare SC_CLOSE drops it -- FCLOSE's
*-- own header names this exact hazard. The cost of getting it
*-- wrong, measured 2026-08-27: the child read an EMPTY script
*-- from a ring the kernel showed at BYTES=0, exited 0, and
*-- every capture was '' with no diagnostic -- in scripts AND at
*-- the tty alike (the handoff's "works in a script" was a
*-- stale-gate mirage).
            ldx   SUBBWFD                ;flush + EOF for the
            jsr   FCLOSE                 ;child's script fd
            clc
            rts
:fail1      lda   #1
            sta   LASTSTATUS
            sec
            rts

*---------------------------------------------------------------
* SUB_DOSPAWN -- the spawn call both subshell paths make, once
* their fdactions differ and are already staged. ENV_STAGE goes
* FIRST because it clobbers PTR0/PTR1 (RUN_PIPELINE's own call
* site records the same ordering). Carry/A are SC_SPAWN's.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
SUB_DOSPAWN jsr   SIO_FLUSHALL         ;MAKE-FLUSH: see shblt2
            jsr   ENV_STAGE
            lda   SUBPATH
            sta   PTR0
            lda   SUBPATH+1
            sta   PTR0+1
            lda   #<SUBARGV
            sta   PTR1
            lda   #>SUBARGV
            sta   PTR1+1
            lda   #<FDABUF
            sta   PTR2
            lda   #>FDABUF
            sta   PTR2+1
            jmp   SC_SPAWN               ;tail call -- its carry
                                         ;and A are ours

*---------------------------------------------------------------
* SUB_WAITST -- reap SUBPID, and make ITS status $?. Both
* subshell paths end this way. CLOBBERS: A, X, Y, PTR0.
*
* BY PID, and the pid-less SC_WAIT this used to call was wrong
* for the same reason RUN_PIPELINE's own wait loop was (shjob.s
* FG_WAIT, Increment C): the kernel reports the LOWEST-pid ready
* child, not the one the caller wants. CMDSUBST's header argued
* the opposite -- "this runs during PARSE ... always BEFORE
* RUN_PIPELINE has spawned anything, so SUB_RUN's SC_WAIT can
* only ever reap its own child" -- and that is true of THIS
* line's children and FALSE of a `&` job from an earlier line,
* which is still this shell's child and can zombie at any
* moment. MEASURED (check-shlang, 2026-09-16): with `cmp` on a
* missing file backgrounded on the same line, `$(cat F1 | cat)`
* came back with `$?` = 2 -- the background job's status -- and
* `wait %1` then reported 0 for that job, because the one status
* it would ever be told had been consumed here and thrown away.
*
* So: SC_WAITJOB in a loop, and every OTHER pid's report is
* re-filed into the job table through JOB_REAP rather than
* dropped -- exactly what FG_WAIT does with the reports that
* arrive while it waits. JOB_REAP returns carry set for a pid
* the table never had (a nested `$( )`'s own child, say), which
* is simply "not ours, keep waiting".
*
* FLAGS 0, never WJ_UNTRACED: a stopped SIBLING must stay
* invisible here or the loop would spin on it forever (the
* report-once hazard, learning 01M20AYDE01C7N0M1HKDM88VCJ). The
* kernel then treats a stopped child as not-live, so this
* blocks while anything can still wake it and gets ERR_CHILD
* when nothing can -- the same contract SC_WAIT gave before.
*
* PTR0 is set ONCE: SC_WAITJOB clobbers only X and Y, and
* JOB_REAP only A and Y.
*---------------------------------------------------------------
SUB_WAITST  lda   #<WJSTAT
            sta   PTR0
            lda   #>WJSTAT
            sta   PTR0+1
:wloop      lda   #0
            jsr   SC_WAITJOB
            bcs   :wfail
            cmp   SUBPID
            beq   :wmine
            jsr   JOB_REAP               ;someone else's -- file
            bra   :wloop                 ;it, do not eat it
*-- {kind, code} back to the one byte $? has always been: an
*-- exit status, or $80|signo for a death by signal.
:wmine      ldy   WJSTAT
            lda   WJSTAT+1
            cpy   #WJ_SIGNALED
            bne   :wst
            ora   #$80
:wst        sta   LASTSTATUS
            rts
:wfail      lda   #1
            sta   LASTSTATUS
            rts

*---------------------------------------------------------------
* SUB_WRVARS -- the parent's UNEXPORTED variables, as assignment
* lines AHEAD of the body on the same pipe. Reproduces the other
* half of V7's shell-variable/environment distinction, which the
* expander's new `$( )` verbatim rule would otherwise have taken
* away (docs/SHELL-GAPS.md sec 2):
*
*   EXPORTED ones are NOT here -- they already travel by
*   themselves, staged into envp by ENV_STAGE and read back by
*   the child's own ENV_IMPORT, which marks them exported so
*   they stay transitive. Emitting them here too would make the
*   child's copy UNexported and break that chain.
*
*   UNEXPORTED ones become assignments the child runs, so they
*   are the child's own unexported variables -- exactly V7 --
*   and they cost no ARG_MAX and no kernel change.
*
* BACKSLASH-ESCAPED, NOT QUOTED, and both halves of that were
* MEASURED at maux's own prompt rather than assumed:
*
*     $ W='a b'          -> sh: mixed quoting
*     $ Q=a\ b           -> $Q is `a b`
*
* SHELL-GAPS sec 2 specified `V='value'` lines, reasoning from
* POSIX. This shell cannot PARSE that: TOKENIZE treats a bare
* run followed by a quote as one MIXED token and refuses it, so
* there is no quoted-assignment form here at all -- for the
* serialiser OR for a human. (That is real V7 drift, recorded as
* its own follow-up; it is not worked around here, because the
* workaround would mean emitting something the shell being fed
* cannot read.)
*
* Per-CHARACTER escaping, which this shell does have, carries
* everything quoting would have: :besc stores the escaped byte
* with bit 7 CLEAR, every metacharacter test downstream compares
* against a HIGH-BIT constant, and UNESC puts the bits back as
* the word leaves the parser. So a space, a `$`, a `*`, a quote
* -- anything SUB_VSAFE does not vouch for -- travels as `\`
* plus itself and arrives literal. No value is refused for its
* CONTENT; the only refusal left is the ring budget, which is a
* real resource limit rather than a character-class one.
*
* THE BUDGET IS THE DEADLOCK ARGUMENT, and it is why that one
* refuses rather than truncates. The parent writes the whole
* pipe before the child exists, so nothing is draining: every
* byte must fit the ring or the parent blocks forever on a pipe
* with no reader. SUBMAX (96) alone always fit; MAXVARS(8) x a
* 15-byte name plus a 31-byte value that may double under
* escaping does not.
*
* OUT: carry clear = written. Carry SET = refused, nothing more
* should be sent. CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
SUB_WRVARS  stz   SUBVSLOT
            lda   SUBTLEN           ;the body and its CR
            clc                     ;are already spoken for
            adc   #1
            sta   SUBVCNT
:loop       ldx   SUBVSLOT
            cpx   #MAXVARS
            beq   :ok
            lda   VAREXP,x
            bne   :next                  ;exported -- envp's job
            jsr   VSLOT_NAME             ;PTR1 = &name; X kept
            ldy   #0
            lda   (PTR1),y
            beq   :next                  ;free slot IS a zero
                                         ;name byte
            jsr   SUB_VLINE
            bcs   :fail
:next       inc   SUBVSLOT
            bra   :loop
:ok         clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* SUB_VLINE -- one unexported slot (SUBVSLOT) as `V=value` + CR
* onto the body pipe, escaping what needs it and refusing only
* if the ring cannot hold it. CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
SUB_VLINE   stz   SUBVESC
            ldx   SUBVSLOT
            jsr   VSLOT_VAL              ;PTR1 = &value
            ldy   #0
:vscan      lda   (PTR1),y
            beq   :vend
            jsr   SUB_VSAFE
            bcs   :vsafe
            inc   SUBVESC                ;this byte costs a `\`
:vsafe      iny
            bra   :vscan
:vend       sty   SUBVLEN
            ldx   SUBVSLOT
            jsr   VSLOT_NAME
            ldy   #0
:nscan      lda   (PTR1),y
            beq   :nend
            iny
            bra   :nscan
:nend       sty   SUBVNLEN
*-- name + '=' + value + one `\` per escaped byte + CR, against
*-- the ring. Nothing drains until the child exists, so this is
*-- the deadlock bound, not a style limit.
            lda   SUBVCNT
            clc
            adc   SUBVNLEN
            bcs   :bad
            clc
            adc   SUBVLEN
            bcs   :bad
            clc
            adc   SUBVESC
            bcs   :bad
            clc
            adc   #2
            bcs   :bad
            cmp   #SUBPIPECAP
            bcs   :bad
            sta   SUBVCNT
            ldx   SUBVSLOT
            jsr   VSLOT_NAME
            jsr   SUB_WRSTR              ;a NAME is safe by its
            lda   #$BD                   ;own grammar
            ldx   SUBBWFD
            jsr   PUTC
            ldx   SUBVSLOT
            jsr   VSLOT_VAL
            jsr   SUB_WRVAL              ;the VALUE is not
            lda   #$8D
            ldx   SUBBWFD
            jsr   PUTC
            clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* SUB_VSAFE -- IN: A = one byte of a variable's value. OUT:
* carry SET if it can travel BARE through a shell line (letters,
* digits, and the punctuation that carries no meaning to
* TOKENIZE, WORDEXPAND or GLOB; and a newline, which SUB_WRVAL
* turns into $0D -- one byte, so SUB_VLINE counts it as one);
* carry CLEAR if it needs a `\`.
*
* A WHITELIST, not a blacklist, deliberately: the set of bytes
* that mean something to this shell is the set someone will add
* to, and a blacklist that misses one emits a wrong answer
* silently. Being wrong in the whitelist's direction only ever
* costs one redundant backslash, which the escape machinery
* strips right back off. CLOBBERS: nothing but the flags.
*---------------------------------------------------------------
SUB_VSAFE   cmp   #$C1                   ;'A'
            bcc   :notupper
            cmp   #$DB                   ;past 'Z'
            bcc   :yes
:notupper   cmp   #$E1                   ;'a'
            bcc   :notlower
            cmp   #$FB                   ;past 'z'
            bcc   :yes
:notlower   cmp   #$B0                   ;'0'
            bcc   :punct
            cmp   #$BA                   ;past '9'
            bcc   :yes
:punct      cmp   #$8D                   ;a newline: bare, and
            beq   :yes                   ;  one byte (SUB_WRVAL)
            cmp   #$AE                   ;'.'
            beq   :yes
            cmp   #$AF                   ;'/'
            beq   :yes
            cmp   #$AD                   ;'-'
            beq   :yes
            cmp   #$DF                   ;'_'
            beq   :yes
            cmp   #$BA                   ;':'
            beq   :yes
            cmp   #$AC                   ;','
            beq   :yes
            cmp   #$C0                   ;'@'
            beq   :yes
            cmp   #$A5                   ;'%'
            beq   :yes
            cmp   #$AB                   ;'+'
            beq   :yes
            clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* SUB_WRSTR -- the NUL-terminated string at PTR1 onto the body
* pipe, unescaped. PTR1 survives PUTC (STG_PTR is $EE, PTR1 is
* $E2), but the index lives in a cell for the same reason
* SUB_WRBODY's does. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SUB_WRSTR   stz   SUBSI
:s          ldy   SUBSI
            lda   (PTR1),y
            beq   :sdone
            ldx   SUBBWFD
            jsr   PUTC
            inc   SUBSI
            bra   :s
:sdone      rts

*---------------------------------------------------------------
* SUB_WRVAL -- the value at PTR1 onto the body pipe, with a `\`
* ahead of every byte SUB_VSAFE will not vouch for, and a
* newline ($8D, which a `$( )` capture keeps between its lines)
* written as $0D with NO backslash. READLINE ends a line on $8D
* only, so the child reads ONE line; no metacharacter test
* matches a bit-7-clear byte; UNESC puts the bit back as the
* word leaves the parser, so the child's variable holds the $8D
* again. (A `\` ahead of a newline was the defect: the child
* read `V=L1\` and ran every later line as a command.) This is
* byte-preserving within the high-bit shell-string domain; a
* low $0D is already $8D after UNESC today and is not a value
* this shell holds distinctly. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SUB_WRVAL   stz   SUBSI
:v          ldy   SUBSI
            lda   (PTR1),y
            beq   :vdone
            jsr   SUB_VSAFE
            bcs   :vplain
            lda   #$DC                   ;'\' -- escape it
            ldx   SUBBWFD
            jsr   PUTC
            ldy   SUBSI
            lda   (PTR1),y
:vplain     cmp   #$8D                   ;a newline goes as the
            bne   :vput                  ;  bit-7-CLEAR $0D: no
            lda   #$0D                   ;  line end, not a meta
:vput       ldx   SUBBWFD
            jsr   PUTC
            inc   SUBSI
            bra   :v
:vdone      rts


:spawned    sta   SUBPID
            lda   SUBWFD
            jsr   CLOSE_FD_A
            stz   SUBPEND
:rd         ldx   SUBRFD
            jsr   GETC
            bcs   :eof
            cmp   #$8D                   ;CR -- hold it back
            beq   :hold
            pha                          ;a real byte: release
:flush      lda   SUBPEND                ;  every held CR first
            beq   :flushed
            dec   SUBPEND
            lda   #$8D
            jsr   EMITB
            bra   :flush
:flushed    pla
            jsr   EMITB
            bra   :rd
:hold       lda   SUBPEND
            cmp   #255
            beq   :rd                    ;saturate -- 255 held
            inc   SUBPEND                ;  CRs already exceeds
            bra   :rd                    ;  EXPBUF entirely
*-- EOF: SUBPEND held CRs are simply DROPPED -- they were, by
*-- definition, trailing. That is the whole stripping rule.
:eof        lda   SUBRFD
            jsr   CLOSE_FD_A
            jmp   SUB_WAITST             ;tail call -- reap the
                                         ;child into $?
