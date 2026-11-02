*---------------------------------------------------------------
* shsub2.s -- sh's group-check half of substitution,
* split from shsubst.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2). One assembly
* stream: ALWAYS put immediately after its predecessor; every
* rule in the original header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* CHCK_GROUP -- `( commands )`, the grouping construct, run in a
* SUBSHELL (docs/SH-FEATURES.md; docs/SHELL-GAPS.md sec 2).
*
* IN: CMD_ARGV/CMD_ARGC as PARSE left them. OUT: carry SET if
* this was a group (handled, LASTSTATUS set); carry CLEAR if the
* command word does not start `(` and the caller should carry on
* down its dispatch chain.
*
* TOKENIZE has already made the whole `( ... )` one token and
* marked it literal (:qbare's group-span block), so the body is
* simply this token with its first and last bytes removed. What
* is left is the SAME shape SUB_RUN feeds a nested `sh` -- and
* that is the entire implementation: a group is a command
* substitution whose output is not captured.
*
* Every refusal here is LOUD. A group whose body will not fit,
* or one with no closing `)`, is a wrong answer waiting to
* happen; the diagnostic costs a few dozen bytes and says so.
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
CHCK_GROUP  lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
            ldy   #0
            lda   (PTR0),y
            cmp   #$A8                   ;'(' high-bit-set
            beq   :isgrp
            clc
            rts
*-- A GROUP CANNOT BE A PIPELINE STAGE EITHER, and it is refused
*-- for the same reason and with the same message. NCMD counts
*-- this segment's stages, so anything but 1 means a `|` was
*-- parsed -- and RUN_PIPELINE, which this path bypasses, is
*-- where a stage's fd 1 would be wired to the pipe. Measured
*-- before the check existed: `( ECHO GPIPE ) | WC` printed
*-- GPIPE and no counts, i.e. WC never received the group's
*-- output and the `|` vanished. THIRD instance of this exact
*-- hole (redirect, then `&`, now `|`) -- everything
*-- RUN_PIPELINE does that this path skips has to be either
*-- honoured or refused, and the list is not self-announcing.
:isgrp      lda   NCMD
            cmp   #1
            bne   :grdbad
*-- A REDIRECT ON THE GROUP IS REFUSED, LOUDLY. `( ... ) > F`
*-- tokenizes as the group span plus ordinary `>`/`F` tokens,
*-- which PARSE records for a command this path never routes
*-- through RUN_PIPELINE's redirect staging -- so honouring it
*-- needs that staging, and IGNORING it is exactly the silent
*-- wrong answer docs/SH-FEATURES.md sec 17 rules against (the
*-- group would run and its output would go somewhere else
*-- entirely). Caught by this feature's own gate, which wrote
*-- `( ECHO GA ) >> RESULTS` and found RESULTS empty. Same four
*-- cells CK_ORPHRDIR tests, same reason.
*-- OUTPUT REDIRECTS AND DUPS ARE HONOURED SINCE 2026-08-27:
*-- SUB_GROUP stages them through STG_OUTFILE/EMIT_DUPS, the
*-- same routines an ordinary command uses. Only `<` is still
*-- refused here, and for a STRUCTURAL reason rather than an
*-- unimplemented one: a group's fd 0 is the BODY PIPE, the
*-- channel the child sh reads its script from, so there is no
*-- fd 0 left to point at a file.
            lda   CMD_INFILE
            ora   CMD_INFILE+1
            ora   HD_ACTIVE              ;a here-doc is dropped
            bne   :grdbad                ;  the same way
*-- ...and so is a dup or FILE record that names fd 0 (`<&3`,
*-- `0<&3`): it would REPLACE the body pipe in the child, which
*-- would then run the lines of that file as commands.
            ldx   DUPN
:dscan      dex
            bmi   :norderr
            lda   DUP_TGT,x
            bne   :dscan
:grdbad     lda   #<GRPRDIR_MSG
            sta   PTR0
            lda   #>GRPRDIR_MSG
            sta   PTR0+1
            jmp   :gsay                  ;shared epilogue below
                                         ;-- `jmp`, not `bra`:
                                         ;range
:norderr    lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
*-- Find the token's end, then require its LAST byte to be the
*-- closing ')'. TOKENIZE only ends a group span ON that byte,
*-- so a token that starts `(` and does not end `)` ran off the
*-- end of the line -- unclosed.
            ldy   #0
:glen       lda   (PTR0),y
            beq   :gend
            iny
            bne   :glen
:gend       cpy   #2                     ;`()` is the shortest
            bcc   :gbad                  ;  possible group
            dey
            lda   (PTR0),y
            cmp   #$A9                   ;')' high-bit-set
            bne   :gbad
            sty   SUBGLEN                ;index OF the ')' ==
                                         ;  body length + 1
            cpy   #SUBMAX
            bcs   :gbig
*-- Body = bytes 1..SUBGLEN-1, into SUBTXT, NUL-terminated --
*-- the same buffer and the same terminator discipline SUB_GRAB
*-- uses, so SUB_WRBODY needs no special case.
            stz   SUBGI
:gcpy       ldy   SUBGI
            iny                          ;skip the '('
            cpy   SUBGLEN
            beq   :gcpyend
            lda   (PTR0),y
            ldy   SUBGI
            sta   SUBTXT,y
            inc   SUBGI
            bra   :gcpy
:gcpyend    ldy   SUBGI
            lda   #0
            sta   SUBTXT,y
            sty   SUBTLEN                ;SUB_WRVARS budgets
                                         ;  against this
            jsr   SUB_GROUP
            sec
            rts
:gbad       lda   #<GRPERR_MSG
            sta   PTR0
            lda   #>GRPERR_MSG
            sta   PTR0+1
            bra   :gsay
:gbig       lda   #<GRPBIG_MSG
            sta   PTR0
            lda   #>GRPBIG_MSG
            sta   PTR0+1
:gsay       jsr   PR_ERR
            lda   #1
            sta   LASTSTATUS
*-- ABANDON THE LINE, the same shape SUB_ERR uses for `$( )`'s
*-- own syntax refusals -- do NOT return to the dispatch chain.
*-- A group that did not close swallowed only PART of the line,
*-- so what follows is the REST OF ITS BODY, and letting the
*-- segment loop run it executes the user's inner commands in
*-- the PARENT shell. Measured before this changed:
*-- `( ( ECHO INNER ) ; ECHO OUTER )` printed the refusal AND
*-- THEN `OUTER )` -- a wrong answer wearing a diagnostic.
*-- Nesting now refuses cleanly with nothing executed.
            jmp   MAINLOOP

*---------------------------------------------------------------
* SUB_GROUP -- run SUBTXT as a subshell, output NOT captured.
*
* SUB_RUN with the capture pipe removed: the child inherits fd 1
* and fd 2, so a group's output goes wherever the parent's does
* and its diagnostics reach the tty. Only the BODY pipe remains,
* which also means the deadlock argument is trivial here --
* there is only ever one direction of traffic.
*
* THE ISOLATION IS THE POINT, and it is free: the child is a
* separate process with its own cwd and its own variable table,
* so `( CD X ; ... )` cannot move the parent. That is the one
* property no `$( )` case can demonstrate.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
SUB_GROUP   jsr   DUP_CHECK              ;a bad `N>&M` on the
            bcc   :gchk                  ;  group: nothing made
            rts
:gchk       jsr   SUB_PREPCH            ;child + body pipe, or a
            bcs   :gfail           ;a diagnostic already
            lda   SUBGONE          ;said why
            bne   :gempty
*-- fd 1 and fd 2 are INHERITED -- that is the whole difference
*-- from SUB_RUN, which points fd 1 at a capture pipe. A group's
*-- output goes wherever the parent's goes and its diagnostics
*-- reach the tty.
            stz   FDAIDX
            stz   CMD_OUTFD              ;a stale value would
                                         ;make CLS_OUTFD close
                                         ;another command's fd
            stz   XOUTN                  ;(and so would these)
            jsr   INIT_CHLDMAP
            lda   SUBBRFD                ;child fd 0 <- the body
            jsr   EMIT_DUP0_A
            lda   SUBBRFD
            jsr   EMIT_CLOSE_A
*-- THE GROUP'S OWN `>` / `>>` / `N>` AND ITS DUPS, staged with
*-- the SAME routines an ordinary command uses. CHCK_GROUP used
*-- to refuse these outright, and its comment named the reason
*-- exactly -- "honouring it needs that staging" -- so the fix
*-- was to make the staging reachable, not to reimplement it.
*-- Order matches BLD_FDCTS_STG: dups at position 0, then the
*-- file, then dups at position 1, which is what makes
*-- `> F 2>&1` and `2>&1 > F` differ the way Bourne says.
*--
*-- fd 0 IS NOT AVAILABLE and `< FILE` stays refused: fd 0 is
*-- the BODY PIPE, which is how the child sh receives the very
*-- text it is going to run. That is structural, not a
*-- shortcut.
            stz   STAGEI                 ;CHCK_GROUP enforces
                                         ;NCMD == 1
            lda   #0
            jsr   EMIT_DUPS
            bcs   :gdied
            jsr   STG_OUTFILE
            bcs   :gdied
            lda   #1
            jsr   EMIT_DUPS
            bcs   :gdied
            jsr   EMIT_END
            jsr   SUB_DOSPAWN
            bcc   :gspawned
            cmp   #ERR_INVAL             ;a bad fdactions list
            bne   :gnf                   ;  is not a missing cmd
            ldx   DUPN                   ;  (no records: a bad
            beq   :gnf                   ;  load base, as ever)
            jsr   PR_BADFDK
            bra   :gdied
:gnf        jsr   PR_SPAWNFAIL
:gdied      jsr   CLS_OUTFD
            lda   SUBBRFD
            jsr   CLOSE_FD_A
            lda   #1
            sta   LASTSTATUS
            rts
:gempty     stz   LASTSTATUS             ;`( )` -- empty, and a
:gfail      rts                          ;success, not a fault
*-- The parent's copy of the body read end goes too: the child
*-- has its own, and a surviving reader holds the pipe open.
:gspawned   sta   SUBPID
            jsr   CLS_OUTFD
            lda   SUBBRFD
            jsr   CLOSE_FD_A
*-- `( ... ) &` BACKGROUNDS THE GROUP. `&` is a SEPARATOR, so
*-- PARSE has already recorded it in PARSE_SEPOP by the time
*-- this dispatches -- and RUN_PIPELINE is the only other place
*-- that reads it. Until 2026-08-27 this path did not, so the
*-- `&` was SILENTLY IGNORED and the group ran in the
*-- foreground: measured, `( SLEEP 3 ; ECHO X ) &` held the
*-- prompt for the full three seconds. Same class as the
*-- redirect hole this routine already refuses -- a construct
*-- that intercepts before RUN_PIPELINE drops the modifiers
*-- RUN_PIPELINE would have honoured -- but this one is CHEAPER
*-- TO HONOUR THAN TO REFUSE: a group is one stage, NCMD is 1,
*-- and JOB_BGONE (shjob.s, docs/JOB-CONTROL.md Increment C)
*-- takes CMD_PID[0..NCMD-1] into a Running job-table row and
*-- sets $? to 0 (POSIX: an asynchronous list exits 0). So the
*-- whole feature is one store. `wait`'s "there is never an
*-- unrecorded live child" invariant holds either way: the
*-- foreground path below still reaps its own.
            lda   PARSE_SEPOP
            cmp   #SEP_BG
            beq   :gbg
            jmp   SUB_WAITST             ;tail call -- reap the
                                         ;child into $?
:gbg        lda   SUBPID
            sta   CMD_PID
            jmp   JOB_BGONE

*---------------------------------------------------------------
* SG_RDFETCH -- the front of every redirect operator in
* SUB_GROUP's token walk: step past the operator (TOKI), and
* unless that ran off the end (a dangling operator, ignored in
* v1) load the next token as the target word and expand it.
* OUT: carry SET = dangling (nothing loaded), CLEAR = the
* expanded word is ready. CLOBBERS: A, X, Y, PTR0, PTR1
* (LOAD_TOK_PTR and WORDEXPAND's own).
*---------------------------------------------------------------
SG_RDFETCH  inc   TOKI
            lda   TOKI
            cmp   NTOK
            bcs   :rdx                   ;dangling -- carry set
            jsr   LOAD_TOK_PTR
            jsr   WORDEXPAND
            clc
:rdx        rts

*---------------------------------------------------------------
* SUB_ERR -- a `$(` with no closing `)`, or a nested one.
* Diagnostic to fd 2, nonzero $?, abandon the rest of the line
* -- never returns (HD_UNTERM/RW_SYNTAXERR's own shape, and the
* same MAINLOOP re-entry they use).
*---------------------------------------------------------------
*---------------------------------------------------------------
*-- ONE MESSAGE NOW. The second branch reported the `| < > ; &`
*-- refusal, which no longer exists -- the body goes to a nested
*-- shell that handles them. Only "unclosed, or nested" is left,
*-- and SUBBADOP with it.
SUB_ERR     lda   #<SUBERR_MSG
            ldx   #>SUBERR_MSG
            jmp   PR_ERRAX1M

*-- The command word for the nested shell. Resolved through
*-- BUILD_PATH like any other, so a tree that moves `sh`
*-- keeps working and one that loses it says so.
SUBSH_STR   asc   "sh"
            dfb   0
SUBERR_MSG  asc   "sh: $(): unclosed, or nested"
            dfb   $8D,0
*-- SUB_WRVARS's one refusal: the parent's unexported variables
*-- will not fit the pipe ring, so this substitution cannot be
*-- given the shell's state honestly and does not run at all.
SUBVAR_MSG  asc   "sh: $(): cannot pass variables"
            dfb   $8D,0
GRPERR_MSG  asc   "sh: (): unclosed"
            dfb   $8D,0
GRPBIG_MSG  asc   "sh: (): too long"
            dfb   $8D,0
GRPRDIR_MSG asc   "sh: (): no redirect|pipe"
            dfb   $8D,0
BRUNT_MSG   asc   "sh: ${}: unclosed"
            dfb   $8D,0
BRQ_MSG     asc   "sh: ${?}: parameter not set"
            dfb   $8D,0

*-- SUBMAX follows LINEMAX, not a number of its own: a `$( )`
*-- body is a slice of one input line and can never be longer
*-- than one. SUBARGMAX is a buffer size, not a policy limit --
*-- the kernel's own ARG_MAX is the authority, exactly as
*-- MAXARGV's header already argues for CMD_ARGV.
*-- SUBPIPECAP -- how many bytes the parent may put down the
*-- body pipe before the child exists to drain it. The kernel's
*-- ring is PIPE_RNG_SIZE (256, inc/mm.annex.equ, not
*-- put here); this is that number with headroom, spelled once.
*-- Exceeding it would block the parent forever on a pipe with
*-- no reader, so SUB_WRVARS refuses against it rather than
*-- letting the write wedge.
*-- BRWORD's modes (EMITBRACE): skip the word, emit it into
*-- EXPBUF, or copy it to BRWBUF for VARSET.
*-- BRW_*/SUBPIPECAP/SUBMAX: hoisted to sh.s's top block (EQU
*-- burn-down, 2026-08-29) -- shexpand, put earlier, uses them
*-- in immediate operands.
SUBARGMAX   equ   8           ;words per substituted command
SUBDEPTH    ds    1           ;TOKENIZE: open `$( )` spans in
                              ;the token being built
SUBPRVD     ds    1           ;TOKENIZE: last copied byte was
                              ;'$' (so a '(' opens a span)
SUBTLEN     ds    1           ;SUB_GRAB: bytes copied to SUBTXT
ECHOI       ds    1           ;CHCK_BLTN_ECH: argv cursor
ECHOFD      ds    1           ;CHCK_BLTN_ECH: destination fd
SUBNARG     ds    1           ;SUB_RUN: words split out so far
SUBTMPP     ds    2           ;SUB_RUN: one word's address,
                              ;built before the indexed store
SUBPATH     ds    2           ;SUB_RUN: resolved spawn path,
                              ;held across SC_PIPE's PTR0 use
*-- SUBPIPEA/SUBBRFD/SUBBWFD/SUBBI (pipe A -- the body -- and
*-- SUB_WRBODY's index) and SH_INTERACT live in the dum arena at
*-- the file's textual end, beside SUBTXT -- see the
*-- write-before-read trace there.
SUBPIPEB    ds    2           ;SC_PIPE's 2-byte output
SUBRFD      ds    1
SUBWFD      ds    1
SUBPID      ds    1           ;SUB_WAITST reaps by THIS pid
SUBPEND     ds    1           ;held (possibly trailing) CRs
SUBRESY     ds    1           ;CMDSUBST: its own Y, across the
SUBSAVP     ds    2           ;  capture; and its own PTR0

*---------------------------------------------------------------
* ZR_CMD_TABLES -- clear all per-SEGMENT pipeline state before
* PARSE (one call per `;`/`&&`/`||`-separated segment now, not
* per line -- MAINLOOP's :seg loop). CLOBBERS: A, X.
*---------------------------------------------------------------
ZR_CMD_TABLES
            stz   NCMD
            stz   CURARGC
            stz   PARSE_ERR
*-- HD_ACTIVE (Tier 3 here-docs) must be cleared per SEGMENT,
*-- not just once at startup: a segment that captured a here-doc
*-- body and then dispatched to something OTHER than RUN_
*-- PIPELINE (a builtin, or a later syntax error on the SAME
*-- line) would otherwise leave it set for the NEXT segment/line
*-- to trip over -- BLD_FDCTS_STG reads it unconditionally for
*-- STAGEI==0.
            stz   HD_ACTIVE
*-- The ordered fd-dup list (docs/SH-FEATURES.md sec 15) is
*-- SEGMENT-scoped for the same reason HD_ACTIVE just above is:
*-- DUPN is the only bound any reader of DUP_* uses, so clearing
*-- it here is all the "zeroing" those four arrays ever need.
            stz   DUPN
            ldx   #0
            lda   #0
:z1         sta   CMD_ARGV,x
            inx
            cpx   #CMDARGVSIZE
            bne   :z1
            ldx   #0
:z2         sta   CMD_INFILE,x
            sta   CMD_OUTFILE,x
            inx
            cpx   #CMDFILESIZE
            bne   :z2
            ldx   #0
:z3         sta   CMD_ARGC,x
            sta   CMD_PID,x
            sta   CMD_APPEND,x
            inx
            cpx   #MAXCMD
            bne   :z3
*-- CMD_TGTFD defaults to FD_STDOUT (1), NOT zeroed with
*-- everything above: a stage with no file redirect at all must
*-- still read as target fd 1 (the builtins' guards compare it),
*-- and SET_OUT overwrites it with the first `>`/`N>` it meets.
            lda   #FD_STDOUT
            ldx   #0
:z4         sta   CMD_TGTFD,x
            inx
            cpx   #MAXCMD
            bne   :z4
            rts

*---------------------------------------------------------------
* PARSE -- walk TOKPTR[TOKI..NTOK) building
* CMD_ARGV/CMD_ARGC/CMD_INFILE/ CMD_OUTFILE/CMD_APPEND for NCMD
* commands, for ONE PIPELINE SEGMENT -- `;`/`&&`/`||` end a call
* rather than a stage (docs/SH-DESIGN.md "PARSE(words)";
* CMD_APPEND added for `>>`, docs/FLEET.md "`>>` and the seek
* family"). TOKI is LINE-scoped (TOKENIZE resets it once per
* line, not here) so the NEXT PARSE call resumes right after the
* separator that ended this one -- MAINLOOP (below) is the
* sequencer that calls PARSE again per segment.
* OUT: PARSE_SEPOP = 0 (ran out of tokens), 1 (`;`), 2 (`&&`),
*      4 = SEP_BG (`&`, docs/SH-BG.md) -- sequences exactly like
*      1, and is read by RUN_PIPELINE alone,
* 3 (`||`) -- which operator ended this segment.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PARSE
:loop       lda   TOKI
            cmp   NTOK
            bcc   :body                  ;`jmp`, not `bcs` --
            jmp   :finish                ;range (:finish is far
                                         ;now -- more segment
                                         ;terminators below)
*-- `jmp`, not `beq`, on every case below -- range: :semi
*-- onward sit well past a conditional branch's reach now that
*-- a whole extra dispatch class lives in this one routine.
:body       jsr   LOAD_TOK_PTR
*-- A quoted token is NEVER an operator, whatever its (already
*-- dequoted) text looks like -- `"2>"`/`";"`/`">"` must all
*-- reach here and print literally. CLASSIFY has no way to see
*-- CURQFLAG on its own (it only ever sees token TEXT), so the
*-- guard belongs at the one call site, extending docs/SH-
*-- SUBSET.md sec 8.4's quoting ruling to operator classify --
*-- the same way GLOB_APPEND/WORDEXPAND already extend it to
*-- globbing/expansion.
            lda   CURQFLAG
            beq   :classify
            jmp   :word
:classify   jsr   CLASSIFY
            cmp   #1
            bne   :ck2
            jmp   :lt
:ck2        cmp   #2
            bne   :ck3
            jmp   :gt
:ck3        cmp   #3
            bne   :ck4
            jmp   :pipe
:ck4        cmp   #4
            bne   :ck5
            jmp   :append
:ck5        cmp   #5
            bne   :ck6
            jmp   :semi
:ck6        cmp   #6
            bne   :ck7
            jmp   :andop
:ck7        cmp   #7
            bne   :ck8
            jmp   :orop
:ck8        cmp   #8
            bne   :ck9
            jmp   :fdgt
:ck9        cmp   #9
            bne   :ck10
            jmp   :fdapp
:ck10       cmp   #10
            bne   :ck11
            jmp   :heredoc
:ck11       cmp   #11
            bne   :ck12
            jmp   :fddup
:ck12       cmp   #12
            bne   :ck13
            jmp   :bgop
:ck13       cmp   #13
            bne   :ck14
            jmp   :dsemi
:ck14       cmp   #14
            bne   :word
            jmp   :fdlt
:word       jsr   PAT_CHECK           ;SH-CASE2 B: a lexical `)`
            bcc   :wnorm             ;  that ends a case pattern
            jmp   PAT_SPLIT           ;  here (ends the segment)
:wnorm      jsr   WORDEXPAND
            jsr   SPLIT_APPEND           ;IFS field splitting,
                                         ;then GLOB_APPEND per
                                         ;field -- argv words
                                         ;ONLY; redirect targets
                                         ;below stay unsplit
            inc   TOKI
            jmp   :loop                  ;`jmp` -- range
:lt         jsr   SG_RDFETCH
            bcs   :rdfin                 ;dangling '<' -- ignore
            jsr   SET_INFILE
            bra   :rdnext
:gt         jsr   SG_RDFETCH
            bcs   :rdfin                 ;dangling '>' -- ignore
            lda   #FD_STDOUT
            ldx   #0
            bra   :rdset
:append     jsr   SG_RDFETCH
            bcs   :rdfin                 ;dangling '>>'
            lda   #FD_STDOUT
            ldx   #1
            bra   :rdset
*-- :fdgt/:fdapp -- `N>`/`N>>` (docs/SH-FEATURES.md sec 3). Same
*-- shape as :gt/:append just above; REDIR_FD (set by CLASSIFY,
*-- still holding THIS operator's digit -- WORDEXPAND and
*-- LOAD_TOK_PTR never touch it) is handed to SET_OUT as its
*-- target fd; the plain `>`/`>>` pass FD_STDOUT.
:fdgt       jsr   SG_RDFETCH
            bcs   :rdfin                 ;dangling 'N>'
            lda   REDIR_FD
            ldx   #0
            bra   :rdset
:fdapp      jsr   SG_RDFETCH
            bcs   :rdfin                 ;dangling 'N>>'
            lda   REDIR_FD
            ldx   #1
:rdset      jsr   SET_OUT
:rdnext     inc   TOKI
            jmp   :loop                  ;`jmp` -- range
:rdfin      jmp   :finish                ;(v1) -- `jmp`, range
*-- :heredoc -- `<<WORD`/`<<-WORD` (Tier 3, docs/SH-FEATURES.md
*-- sec 4/6). v1: only the pipeline's FIRST stage (NCMD==0) may
*-- carry one -- BLD_FDCTS_STG's fd0 wiring only checks this for
*-- STAGEI==0, and wiring a LATER stage's fd0 from a here-doc
*-- pipe as well would need its OWN dup/close pair there too.
*-- Unlike `<`/`>`/etc., the "word" here is HD_WPTR (already set
*-- by CLASSIFY, pointing inside THIS token) -- there is no
*-- separate filename token to load or WORDEXPAND. CAPTURE_
*-- HEREDOC does the actual body read; it never returns on
*-- failure (same "jmp MAINLOOP, loud diagnostic" shape RW_
*-- SYNTAXERR/RW_OVERFLOW already use).
*-- :fdlt -- `N<` (KFIX3 item 2): open the next word for READING
*-- on fd N. REDIR_FD (CLASSIFY's, still this operator's digit)
*-- is the target. `0<` never gets here: CLASSIFY calls it `<`.
:fdlt       inc   TOKI
            lda   TOKI
            cmp   NTOK
            bcc   :fdltbody               ;dangling 'N<' --
            jmp   :finish                 ;ignore (v1) -- range
:fdltbody   jsr   LOAD_TOK_PTR
            jsr   WORDEXPAND
            jsr   SET_INN
            inc   TOKI
            jmp   :loop                  ;`jmp` -- range
:heredoc    lda   NCMD
            beq   :hdstg0
            jmp   HD_BADSTAGE
:hdstg0     jsr   CPTR_HEREDOC
            inc   TOKI
            jmp   :loop                  ;`jmp` -- range
*-- :fddup -- `N>&M`/`>&M`/`N>&-` (docs/SH-FEATURES.md sec 15).
*-- Unlike every other redirect above, this operator consumes NO
*-- following token: both fds are inside the operator itself, so
*-- there is nothing to LOAD_TOK_PTR or WORDEXPAND.
:fddup      jsr   SET_DUP
            inc   TOKI
            jmp   :loop                  ;`jmp` -- range
:pipe       jsr   PAT_NOEMPTY
            jsr   FINISH_CMD
            inc   TOKI
            jmp   :loop                  ;`jmp` -- range
:semi       jsr   FINISH_CMD
            lda   #1
            sta   PARSE_SEPOP
            inc   TOKI
            rts
:andop      jsr   PAT_NOEMPTY
            jsr   FINISH_CMD
            lda   #2
            sta   PARSE_SEPOP
            inc   TOKI
            rts
:orop       jsr   PAT_NOEMPTY
            jsr   FINISH_CMD
            lda   #3
            sta   PARSE_SEPOP
            inc   TOKI
            rts
*-- `&` ends the segment exactly the way `;` does -- it is a
*-- SEPARATOR, not a redirect, so it takes no following token
*-- and imposes no short-circuit. The only thing it changes is
*-- what RUN_PIPELINE does after the last spawn (docs/SH-BG.md).
:bgop       jsr   FINISH_CMD
            lda   #SEP_BG
            sta   PARSE_SEPOP
            inc   TOKI
            rts
*-- `;;` ends the segment exactly the way `;` does. What it
*-- ALSO does -- close the current `case` branch -- is the
*-- caller's job, off PARSE_SEPOP, because PARSE has no business
*-- touching the construct stack.
:dsemi      jsr   FINISH_CMD
            lda   #SEP_DSEMI
            sta   PARSE_SEPOP
            inc   TOKI
            rts
:finish     jsr   FINISH_CMD
            stz   PARSE_SEPOP          ;ran out of tokens. Every
            rts                       ;  other exit sets it, and
                                      ;  at entry it still holds
                                         ;  what ended the last
                                        ;  segment (PAT_NOEMPTY)

*---------------------------------------------------------------
* PAT_CHECK -- PARSE :word, before the token is expanded. OUT:
* carry SET iff this token's first lexical `)` (TOKCP, TOKENIZE)
* ENDS a case pattern here: NCMD = 0, and either CURARGC = 0
* with
* the top frame a CASE between branches, or CURARGC = 3 with
* argv
* = [case WORD in], the `case` and the `in` lexically bare (a
* quoted "case" is a word, M2). That second form is the first
* clause on the `case ... in` line: its frame does not exist
* yet,
* because the segment is PARSEd before RW_CASE runs. Anything
* else answers NO and the word is handled as before (a `)`
* elsewhere stays content, G17). PTR0 is reloaded when a compare
* clobbered it. CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
PAT_CHECK   ldx   TOKI
            lda   TOKCP,x
            beq   :no                    ;no lexical `)`
            lda   NCMD
            bne   :no                  ;never a later stage (H3)
            lda   CURARGC
            beq   :first
            cmp   #3
            beq   :c3
            cmp   #4
            bne   :no
            lda   CMD_ARGV               ;a reserved word first:
            sta   PTR0                   ;  do, then, else, `{`,
            lda   CMD_ARGV+1             ;  even `if case`
            sta   PTR0+1
            jsr   SPOOL_KWID
            beq   :reload
:c3         lda   TOKI
            sec
            sbc   #3                     ;`case` and `in` (the
            bcc   :reload                ;  tokens 3 and 1 back)
            tax                          ;  must be lexically
            lda   TOKQUOTE,x             ;  bare (M2)
            inx
            inx
            ora   TOKQUOTE,x
            bne   :reload
            lda   CURARGC
            sec
            sbc   #3
            asl   a
            tax                          ;X = `case`'s byte
            ldy   #0                     ;  offset: 0 or 2
            jsr   ARGV_ISSTR
            bne   :reload
            txa
            clc
            adc   #4
            tax
            ldy   #1
            jsr   ARGV_ISSTR
            bne   :reload
            sec
            rts
:first      jmp   CS_CASEBTW             ;carry = a CASE between
                                         ;  branches
:reload     lda   TOKI                   ;PTR0 was the compare's
            jsr   LOAD_TOK_PTR
:no         clc
            rts

*---------------------------------------------------------------
* PAT_SPLIT -- PAT_CHECK said yes. The `)` becomes a NUL, TOKPTR
* [TOKI] is repointed at the text after it (the remainder, which
* the next PARSE call starts on; an empty remainder moves TOKI
* on), a leading bare `(` is skipped (judged on the token's RAW
* first byte, PRETOK[TOKOFF]: a quoted or escaped `(` is not),
* and the pattern half is expanded ($ only) and appended with
* APPEND_RAW: NOT through SPLIT_APPEND/GLOB_APPEND (a pattern is
* neither field-split nor pathname-expanded) and WITHOUT UNESC,
* so a backslash- or single-quoted `*?[` stays literal for
* GLOBMATCH (H4). A token that began with a seeded group `(` is
* TOKQUOTE 1 (literal): neither half may inherit that (H2). The
* segment ends with PARSE_SEPOP = SEP_PAT.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
PAT_SPLIT   ldx   TOKI
            ldy   TOKOFF,x
            lda   PRETOK,y          ;the token's RAW first byte:
            eor   #ALC_A8            ;  0 = a bare `(` (a quoted
            sta   CPOFF                ;  or escaped one is not)
            cmp   #1                    ;M2: a raw `)` first, or
            beq   :bad                   ;  `()`, is an EMPTY
            lda   CPOFF                  ;  pattern: a syntax
            bne   :ok                    ;  error (`""` is not
            lda   PRETOK+1,y             ;  one: its raw first
            cmp   #ALC_A9                ;  byte is a quote)
            bne   :ok
:bad        lda   #1
            sta   PARSE_ERR
:ok            ldy   TOKCP,x
            stz   TOKCP,x                ;the remainder has none
            dey                          ;Y = offset of the `)`
            txa
            jsr   LOAD_TOK_PTR           ;PTR0 = the token
            lda   #0
            sta   (PTR0),y             ;the `)` ends the pattern
            iny
            lda   (PTR0),y               ;remainder's first byte
            pha
            tya                          ;(X is 2*TOKI still,
            clc                          ;  from LOAD_TOK_PTR)
            adc   PTR0
            sta   TOKPTR,x               ;the remainder is the
            lda   PTR0+1                 ;  token from here on
            adc   #0
            sta   TOKPTR+1,x
            lda   CPOFF
            bne   :nolead
            inc   PTR0                   ;skip the `(`
            bne   :nl2
            inc   PTR0+1
:nl2        stz   CURQFLAG               ;H2: not group-literal
            ldx   TOKI
            stz   TOKQUOTE,x
:nolead     jsr   WORDEXPAND
:raw        jsr   APPEND_RAW
            pla
            bne   :more
            inc   TOKI                   ;nothing glued after it
:more       jsr   FINISH_CMD
            lda   #SEP_PAT
            sta   PARSE_SEPOP
            rts

*---------------------------------------------------------------
* PAT_NOEMPTY -- `&&`/`||` right after a pattern with no word of
* its own (`x)&& echo`) is a syntax error in dash and bash, not
* an
* empty command: PARSE_ERR 1. A redirect-only command after a
* pattern is refused too (named). CLOBBERS: A.
*---------------------------------------------------------------
PAT_NOEMPTY lda   PARSE_SEPOP
            cmp   #SEP_PAT
            bne   :ok
            lda   CURARGC
            ora   NCMD
            bne   :ok
            lda   #1
            sta   PARSE_ERR
:ok         rts

*---------------------------------------------------------------
* ARGV_ISSTR -- Z set iff the word at CMD_ARGV+X is CASE (Y = 0)
* or IN (Y = 1), folded. Leaves PTR0/PTR1 clobbered. Shared by
* PAT_CHECK, RW_CASE and SPLIT_APPEND (inline before).
*---------------------------------------------------------------
ARGV_ISSTR  lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            lda   ASTR_LO,y
            sta   PTR1
            lda   ASTR_HI,y
            sta   PTR1+1
            jmp   STRCMPI
ASTR_LO     dfb   <CASE_STR,<IN_CASESTR
ASTR_HI     dfb   >CASE_STR,>IN_CASESTR
