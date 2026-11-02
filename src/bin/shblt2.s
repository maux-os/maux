*---------------------------------------------------------------
* shblt2.s -- sh's heredoc-tail half of builtins,
* split from shbltn.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2). One assembly
* stream: ALWAYS put immediately after its predecessor; every
* rule in the original header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* HD_UNTERM -- true EOF reached before the terminator.
* Diagnostic to fd 2, LASTSTATUS=1, discard whatever partial
* body was captured (nothing to feed), `jmp` MAINLOOP directly
* -- never returns (RW_SYNTAXERR's own shape). MAINLOOP's own
* :eof handler (above) is what makes this safe even inside a
* `.`-sourced file: CUR_IN_FD is genuinely at EOF now, so the
* very next READLINE there pops back to the caller correctly,
* rather than hanging.
*---------------------------------------------------------------
*-- HD_LONG: a body line past LINEMAX or a body past HDBODYLEN,
*-- found at the terminator: refused, never truncated.
HD_LONG     lda   #<HDLONG_MSG
            ldx   #>HDLONG_MSG
            bra   :hdmsg
HD_UNTERM   lda   #<HDUNTERM_MSG
            ldx   #>HDUNTERM_MSG
:hdmsg      jsr   PR_ERRAX1
            stz   HD_ACTIVE
            jmp   MAINLOOP

*---------------------------------------------------------------
* HD_BADSTAGE -- a here-doc attached to a pipeline stage past
* the first (v1 restriction, PARSE's own :heredoc handler,
* above). Diagnostic, LASTSTATUS=1, abandon the line -- same HD_
* UNTERM/RW_SYNTAXERR use.
*---------------------------------------------------------------
HD_BADSTAGE lda   #<HDSTAGE_MSG
            ldx   #>HDSTAGE_MSG
            jmp   PR_ERRAX1M

HDUNTERM_MSG
            asc   "sh: here-doc: EOF before terminator"
            dfb   $8D,0
*-- dfb hex, not asc "..": check-encoding's literal pin.
*-- "sh: here-doc: too long"
HDLONG_MSG  dfb   $F3,$E8,$BA,$A0,$E8,$E5,$F2,$E5
            dfb   $AD,$E4,$EF,$E3,$BA,$A0,$F4,$EF
            dfb   $EF,$A0,$EC,$EF,$EE,$E7,$8D,0
HDSTAGE_MSG asc   "sh: here-doc: only the first pipeline stage"
            dfb   $8D,0

*---------------------------------------------------------------
* HD_MKPIPE -- create the here-doc's own pipe (SC_PIPE), record
* HD_RFD/HD_WFD (sh's own copies), and stage the CHILD's fd0
* wiring (dup HD_RFD onto 0, close HD_RFD) -- same EMIT_DUP0_A/
* EMIT_CLOSE_A primitives BLD_FDCTS_STG's own `<` path already
* uses. Called from BLD_FDCTS_STG in place of the normal
* CMD_INFILE file-open, STAGEI==0 only. OUT: carry clear on
* success. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
HD_MKPIPE   lda   #<HDPIPETMP
            sta   PTR0
            lda   #>HDPIPETMP
            sta   PTR0+1
            jsr   SC_PIPE
            bcs   :fail
            lda   HDPIPETMP
            sta   HD_RFD
            lda   HDPIPETMP+1
            sta   HD_WFD
            lda   HD_RFD
            jsr   EMIT_DUP0_A
            lda   HD_RFD
            jsr   EMIT_CLOSE_A
            clc
            rts
*-- SC_PIPE failed: HD_RFD/HD_WFD were NEVER assigned this line,
*-- so they still hold the PREVIOUS here-doc's fd numbers.
*-- RUN_PIPELINE's own :nohdclose/:hdclose paths are gated on
*-- HD_ACTIVE, not on the pipe having been made, so leaving it
*-- set here made the redirect-failure path CLOSE_FD_A two stale
*-- fds -- someone else's, by then. Clearing it is also exactly
*-- right semantically: with no pipe there is no body to feed
*-- and no ends to close.
:fail       stz   HD_ACTIVE
            sec
            rts

*---------------------------------------------------------------
* HD_WRITE_BODY -- write HD_LEN bytes of HD_BODY to HD_WFD, in a
* loop (a pipe write can complete SHORT -- src/kernel/procfd2.s
* PRC_WRITE's own K2 bulk path -- so one SC_WRITE is not enough
* for anything past the 256B ring, exactly cat.s's own WRITE_ALL
* shape). Called from RUN_PIPELINE only after every stage has
* been spawned (see that routine's own comment) and only if
* stage 0 actually spawned. CLOBBERS: A, X.
*---------------------------------------------------------------
HD_WRITE_BODY
            lda   HD_LEN
            sta   HD_WPARM_REQ
            lda   HD_LEN+1
            sta   HD_WPARM_REQ+1
            lda   #<HD_BODY
            sta   HD_WPARM_BUF
            lda   #>HD_BODY
            sta   HD_WPARM_BUF+1
            lda   HD_WFD
            sta   HD_WPARM_REF
:loop       lda   HD_WPARM_REQ
            ora   HD_WPARM_REQ+1
            beq   :done
            lda   #<HD_WPARM
            ldx   #>HD_WPARM
            jsr   SC_WRITE
            bcs   :done                  ;write error -- stop,
                                         ;v1 (cat.s's own
                                         ;WRITE_ALL precedent)
            lda   HD_WPRM_TRANS
            ora   HD_WPRM_TRANS+1
            beq   :done                  ;defensive -- avoid an
                                         ;infinite loop
            sec
            lda   HD_WPARM_REQ
            sbc   HD_WPRM_TRANS
            sta   HD_WPARM_REQ
            lda   HD_WPARM_REQ+1
            sbc   HD_WPRM_TRANS+1
            sta   HD_WPARM_REQ+1
            clc
            lda   HD_WPARM_BUF
            adc   HD_WPRM_TRANS
            sta   HD_WPARM_BUF
            lda   HD_WPARM_BUF+1
            adc   HD_WPRM_TRANS+1
            sta   HD_WPARM_BUF+1
            bra   :loop
:done       rts

HD_WPARM       dfb   PCOUNT_WRITE
HD_WPARM_REF   dfb   0
HD_WPARM_BUF   da    0
HD_WPARM_REQ   da    0
HD_WPRM_TRANS da    0

HDPIPETMP   ds    2
HD_RFD      ds    1
HD_WFD      ds    1
HD_LEN      ds    2
HD_ACTIVE   ds    1
HD_STRIP    ds    1
HD_QUOTED   ds    1        ;this heredoc's own terminator word
                           ;was quoted (`<<'WORD'`/`<<"WORD"`)
                           ;-- 0 expand the body (Bourne
                           ;default), 1 literal (docs/SH-
                           ;FEATURES.md sec 6/12). Set by
                           ;CLASSIFY, consumed by CPTR_HEREDOC
                           ;-- same "written fresh every time,
                           ;never reset elsewhere" precedent
                           ;HD_STRIP/HD_WPTR already use
HD_WPTR     ds    2
HDCUR       ds    1
HDLLEN      ds    1
HDSKIP      ds    1

CUR_IN_FD   ds    1
SRC_DEPTH   ds    1
SRC_STACK   ds    SRC_MAXDEPTH
SH_XTRACE   ds    1
SH_ERREXIT  ds    1          ;`set -e`/`set +e` (shbltn.s)

*---------------------------------------------------------------
* DUP_CHECK -- refuse a redirect list that dups from a fd the
* user does not hold, BEFORE anything is opened (DUPFD-1, phase
* S; docs/DUPFD-1-NOTES.md). `cat <&3` with fd 3 closed used to
* read fd 0 and exit 0: the kernel skipped the dup. The kernel
* refuses it now (ERR_INVAL, phase K) but cannot see the user's
* view: sh opens its own fds first (RUN_PIPELINE's pipes, the
* FILE records), lowest-free from 3, so by spawn time the user's
* closed fd 3 is often a pipe end or a temporary file and the
* kernel finds it open. So the shell judges, from its own books.
*
* Per stage, in the order BLD_FDCTS_STG applies them (the dups
* before the stage's first file redirect, that file, the dups
* after): HELD starts as fds 0-2 plus USERFDS and follows the
* list -- a close drops its target, a dup or a FILE record adds
* its target. A `N>&M` whose M is not in HELD fails the whole
* line: `sh: M: bad file descriptor`, LASTSTATUS 1, nothing
* spawned, opened or written. Status 1 is a maux ruling (bash
* says 1, dash 2).
* Fds 0-2 count as held: `exec 1>&-; ls 2>&1` is left to the
* kernel's backstop (PR_BADFDK).
* OUT: carry set on a refusal. CLOBBERS: A, X, Y, STAGEI,
* DUPI, DUPWANT, DUPTGT, DCHELD.
*---------------------------------------------------------------
DUP_CHECK   stz   STAGEI
:stage      lda   STAGEI
            cmp   NCMD
            beq   :ok
            lda   USERFDS
            ora   #$07
            sta   DCHELD
            stz   DUPWANT                ;dups before the
            jsr   DC_RECS                ;  stage's file
            bcs   :bad
            lda   STAGEI
            asl   a
            tax
            lda   CMD_OUTFILE,x
            ora   CMD_OUTFILE+1,x
            beq   :nofile
            ldx   STAGEI
            ldy   CMD_TGTFD,x            ;the file's fd
            lda   TGT_BIT,y
            ora   DCHELD
            sta   DCHELD
:nofile     lda   #1
            sta   DUPWANT                ;then the dups after it
            jsr   DC_RECS
            bcs   :bad
            inc   STAGEI
            bra   :stage
:ok         clc
            rts
:bad        jsr   PR_BADFD               ;A = the offending M
            stz   HD_ACTIVE              ;no pipe made yet
            lda   #1
            sta   LASTSTATUS
            sec
            rts

* DC_RECS -- DUP_CHECK's walk of one position (DUPWANT) of the
* stage STAGEI. OUT: carry set, A = M on the first bad source.
DC_RECS     stz   DUPI
:loop       lda   DUPI
            cmp   DUPN
            beq   :done
            tax
            lda   DUP_STG,x
            cmp   STAGEI
            bne   :next
            lda   DUP_POS,x
            cmp   DUPWANT
            bne   :next
            lda   DUP_TGT,x
            sta   DUPTGT
            lda   DUP_SRC,x
            cmp   #$FF
            beq   :close                 ;`N>&-`
            cmp   #FREC_RD
            bcs   :set                   ;a FILE record opens N
            tay
            lda   TGT_BIT,y
            and   DCHELD
            beq   :refuse                ;M is not held
:set        ldy   DUPTGT
            lda   TGT_BIT,y
            ora   DCHELD
            bra   :store
:close      ldy   DUPTGT
            lda   TGT_BIT,y
            eor   #$FF
            and   DCHELD
:store      sta   DCHELD
:next       inc   DUPI
            bra   :loop
:done       clc
            rts
:refuse     tya                          ;M
            sec
            rts

*---------------------------------------------------------------
* RUN_PIPELINE -- execute the NCMD commands PARSE just built:
* allocate NCMD-1 pipes, spawn every stage with the fdactions
* described in this file's header, close sh's own pipe/redirect
* fds, wait() NCMD times (ruling 9). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
RUN_PIPELINE
            jsr   DUP_CHECK              ;a bad `N<&M` runs and
            bcc   :dcok                  ;opens nothing
            rts
:dcok       lda   NCMD
            sec
            sbc   #1
            sta   NPIPES
            stz   PIPEI
:mkpipe     lda   PIPEI
            cmp   NPIPES
            beq   :pipesdone
            lda   #<PIPETMP
            sta   PTR0
            lda   #>PIPETMP
            sta   PTR0+1
            jsr   SC_PIPE
            bcs   :pipefail
            ldx   PIPEI
            lda   PIPETMP
            sta   PIPE_RFD,x
            lda   PIPETMP+1
            sta   PIPE_WFD,x
            inc   PIPEI
            bra   :mkpipe
:pipefail   lda   PIPEI
            sta   NPIPES                 ;only close what
                                         ;actually opened
            jsr   CLS_ALL_PIPES
            jsr   PR_PIPEFAIL
            rts
*-- JOB CONTROL (docs/JOB-CONTROL.md Increment C): every
*-- pipeline gets a job-table row BEFORE it spawns -- the row's
*-- command text is rebuilt from CMD_ARGV here, while the words
*-- are whole -- and a full table refuses the line the way a
*-- failed pipe does, BEFORE anything runs. Unreachable in
*-- practice (BGMAX is the bank ceiling; a Done row is freed
*-- before every line), but a refusal beats a job nobody can
*-- name.
:pipesdone  jsr   JOB_ALLOC
            bcc   :jobok
            jsr   CLS_ALL_PIPES
            lda   #<JOBFULL_MSG
            ldx   #>JOBFULL_MSG
            jmp   PR_ERRAX1
:jobok      stz   STAGEI
*-- `bne` past a `jmp`: :spawndone moved out of an 8-bit
*-- branch's reach when the resolver's failure path was added
*-- below. Same idiom the rest of this routine already uses.
:spawnloop  lda   STAGEI
            cmp   NCMD
            bne   :stagego
            jmp   :spawndone
:stagego    stz   SHEB_N                 ;`#!` rewrites so far
            stz   SHEB_RETRY
:resolve
*-- Resolve BEFORE staging redirects. The PATH probe opens a
*-- file, and the kernel's io_buffers are few: probing after a
*-- redirect was already open emptied a three-stage pipeline.
*-- Resolving first means nothing of ours is open when it runs.
*-- HONOUR THE RESOLVER'S CARRY. BUILD_PATH's :exhausted branch
*-- returns carry SET and leaves the BARE WORD in SH_PATHFULL
*-- "so the caller's failure names what was actually typed" --
*-- its own words. Neither caller failed: this one let the very
*-- next `jsr` destroy the carry, so the bare word was SPAWNED.
*--
*-- That is an accidental CURRENT-DIRECTORY SEARCH, because
*-- ProDOS resolves a pathname with no leading '/' against the
*-- prefix. So `FOO` found no /bin/FOO, no /mnt/MAUX/FOO --
*-- and then ran ./FOO. docs/ANACHRONISMS.md A11 says maux has
*-- no cwd entry in its search path, and this was the back door,
*-- on a kernel that does not check file types before jumping to
*-- LOAD_BASE. It is also how an unresolvable `ECHO` reached the
*-- kernel as a path starting with 'E'
*-- (docs/SPAWN-BANK7-CRASH.md).
            jsr   RSLV_PTH_STG
            bcc   :rslvok
*-- ZERO THE STAGE'S fds BEFORE TAKING THE FAILURE PATH. It ends
*-- at :closestage, which closes CMD_INFD/CMD_OUTFD -- and this
*-- jump happens BEFORE BLD_FDCTS_STG has set them, so they
*-- still hold the PREVIOUS stage's. Closing another stage's fd
*-- is how the first cut of this fix broke check-shlang-hd:
*-- everything downstream of the unresolved command read from
*-- an fd that had been shut under it.
            stz   CMD_INFD
            stz   CMD_OUTFD
            stz   XOUTN
            jmp   :notfound              ;`jmp` -- range
*-- MAKE-FLUSH: a builtin's output sits in liba's buffer if
*-- fd 1 is a file or pipe; the child writes through its own.
*-- Flush before the spawn, and before redirects are opened.
:rslvok     jsr   SIO_FLUSHALL
            jsr   BLD_FDCTS_STG
            bcs   :redirfail
*-- The environment, staged BEFORE the three pointer arguments
*-- below because it clobbers PTR0/PTR1 (docs/SYSCALL.md item
*-- 13c). It writes SPWN_ENVP, which SC_SPAWN reads as its
*-- fourth argument -- an uncleared cell every caller must set,
*-- so this call is not optional decoration.
            jsr   PFX_STG_APPLY          ;shpfx.s: this stage's
            bcc   :pfxok                 ;NAME=value prefixes; a
            jmp   :status1               ;refusal is reported
:pfxok      jsr   ENV_STAGE
            lda   #<SH_PATHFULL          ;BLD_FDCTS_STG clobbers
            sta   PTR0                   ;  PTR0; the resolved
            lda   #>SH_PATHFULL          ;  path is still here
            sta   PTR0+1
            jsr   ARGV_PTR_STG
            lda   #<FDABUF
            sta   PTR2
            lda   #>FDABUF
            sta   PTR2+1
            jsr   SC_SPAWN
            jsr   PFX_STG_UNDO           ;envp is the kernel's
            ldx   STAGEI
            bcs   :spawnerr
            sta   CMD_PID,x
            bra   :closestage
*-- A STAGE THAT NEVER RAN MUST NOT REPORT THE PREVIOUS
*-- COMMAND'S $?. This path and :spawnerrx below both set
*-- CMD_PID to 0, and FG_WAIT (shjob.s) only stores LASTSTATUS
*-- from the row's TAIL pid, which is CMD_PID[NCMD-1] -- so
*-- with no child there was nothing to match and $? kept
*-- whatever the line before it left there. `ECHO X > LOCKED`
*-- printed a stale 0 right after `sh: cannot redirect`, which
*-- is the quiet-wrong-answer class this shell exists to close.
*-- Measured by check-writefail: `>` onto a locked target fails
*-- at the SET_EOF inside OPEN_REDIR_WR's liba CREAT (CREATE's
*-- $47 for an existing name is ignored; no UNLINK precedes it
*-- since 2026-08-29), so the child is never
*-- spawned and no write is ever attempted -- the pinned defect
*-- blamed unreported WRITE errors, and the write was not the
*-- mechanism. 1 is what every other diagnostic path in this
*-- file uses (HD_UNTERM, HD_BADSTAGE, CR's own :failed).
:redirfail  ldx   STAGEI
            stz   CMD_PID,x
*-- A `>`/`>>` that a ^C ended while it waited for a busy file
*-- (OW_INTR, shsgrw.s) is status 130 and silent -- the kernel
*-- painted `^C` -- not a refusal. OW_INTR is cleared at every
*-- MAINLOOP pass and every OW_RUN: never stale here.
            lda   OW_INTR
            beq   :rfmsg
            lda   #130
            bra   :rfset
:rfmsg      jsr   PR_REDIRERR
            lda   #1
:rfset      sta   LASTSTATUS
            bra   :nextstage
*-- SC_SPAWN's error code, not just the fact of failure. This is
*-- the ONE code sh decodes (docs/SH-DESIGN.md ruling 7
*-- keeps the generic message for everything else): the
*-- kernel now enforces ARG_MAX itself, so a line whose
*-- argv fits sh's buffers and
*-- not the child's bank comes back as ERR_2BIG -- and reporting
*-- that as "command not found" would send you looking for a
*-- missing binary that is sitting right there.
*-- X is RELOADED after the message, not carried through
*-- it: PUTS documents "CLOBBERS: A, X, Y", so the
*-- `sta CMD_PID,x` here
*-- used to index with whatever X the write syscall happened to
*-- return -- leaving this stage's pid stale AND zeroing a byte
*-- somewhere past CMD_PID (STAGEI and CMD_INFD are the next
*-- cells). :redirfail three lines up already reloads X; this
*-- path was the outlier, and a too-large argv failing HERE
*-- rather than truncating in the kernel is what makes it
*-- reachable.
*-- ERR_NOEXEC: the file is there and is not a program (spawn
*-- inspects the type, docs/EXEC-SHEBANG.md). POSIX: $? is 126
*-- for "found but not executable", 127 for "not found".
:spawnerr   cmp   #ERR_2BIG
            beq   :toobig
            cmp   #ERR_NOEXEC
            bne   :refused
            jsr   SHEB_FIX               ;a `#!` script?
            bcs   :noexec
            inc   SHEB_RETRY             ;argv rewritten:
            bra   :closestage            ;spawn this stage again
:noexec     jsr   PR_NOEXEC
            lda   #126
            bra   :spawnerrx
:toobig     jsr   PR_TOOMANY
            bra   :status1
*-- A MISSING file -- the open's MLI $44 path / $45 volume / $46
*-- file not found, or $40 invalid pathname (`dir/../x`: MKPATH
*-- resolves only a LEADING run of dots, so the kernel gets the
*-- dots and refuses them) -- is POSIX's 127, as is a bare word
*-- PATH could not resolve (KFIX10 item 3). Any other refusal (a
*-- loader that will not take the image: too big, a base below
*-- the window) keeps the status 1 it always had, and the words.
:refused    cmp   #ERR_INVAL             ;a bad fdactions list
            beq   :einval                ;  (phase K) or a bad
                                         ;  load base (below)
            cmp   #$46
            beq   :notfound
            cmp   #$45
            beq   :notfound
            cmp   #$44
            beq   :notfound
            cmp   #$40                   ;invalid pathname: what
            beq   :notfound              ;`d/../x` earns (below)
            jsr   PR_SPAWNFAIL           ;ENOMEM, ENFILE, else
            bra   :status1               ;  the generic words
*-- ERR_INVAL is also what a load base below the window earns
*-- (PRC_CHK_BASE): that stays `command not found`. Only a line
*-- with redirect records of its own can have a bad list.
:einval     lda   DUPN
            bne   :badfdk
            jsr   PR_CMDNOTFND
            bra   :status1
:badfdk     jsr   PR_BADFDK
            bra   :status1
:notfound   jsr   PR_CMDNOTFND
            lda   #127
            bra   :spawnerrx
:status1    lda   #1               ;same staleness as :redirfail
:spawnerrx  ldx   STAGEI           ;above -- `sh: command not
            stz   CMD_PID,x        ;found` left $? untouched too
            sta   LASTSTATUS
:closestage lda   CMD_INFD
            beq   :noin
            jsr   CLOSE_FD_A
:noin       jsr   CLS_OUTFD
            lda   SHEB_RETRY             ;a `#!` retry keeps the
            bne   :sheb                  ;here-doc pipe, stays
                                         ;on this stage
*-- Tier 3 here-doc: close sh's OWN copy of the pipe's READ end
*-- once stage 0's spawn attempt is done, succeeded or not --
*-- the child (if any) already has its own dup via fdactions --
*-- never reads HD_RFD itself. Gated on STAGEI==0 (not yet
*-- incremented here) so a LATER stage in the same pipeline
*-- never repeats this close.
            lda   HD_ACTIVE
            beq   :nohdclose
            lda   STAGEI
            bne   :nohdclose
            lda   HD_RFD
            jsr   CLOSE_FD_A
:nohdclose
:nextstage  inc   STAGEI
            jmp   :spawnloop
:sheb       stz   SHEB_RETRY
            jmp   :resolve         ;jmp, not bra: the two
                                     ;LASTSTATUS stores above
                                     ;pushed :spawnloop past the
                                     ;+/-127 window (same shape
                                     ;as :hdfailed's own
                                     ;trampoline higher up)
*-- Tier 3 here-doc: feed the body only AFTER every stage has
*-- been spawned (docs/SH-FEATURES.md sec 6.2's pipe route) --
*-- writing earlier risks a multi-stage pipeline stalling on a
*-- downstream pipe that has no reader yet. Only if stage 0
*-- actually spawned (CMD_PID+0 <> 0) is there anyone to feed;
*-- either way sh's own write-end copy is always closed, to send
*-- EOF (or just release the pipe slot on a failed spawn).
:spawndone  jsr   CLS_ALL_PIPES
            lda   HD_ACTIVE
            beq   :nohdwrite
            lda   CMD_PID+0
            beq   :hdclose
            jsr   HD_WRITE_BODY
:hdclose    lda   HD_WFD
            jsr   CLOSE_FD_A
            stz   HD_ACTIVE
:nohdwrite
*-- The row learns its pids now (JOB_SETPIDS). Nothing spawned
*-- at all: the row is freed and there is nothing to wait for or
*-- background -- `$?` stands as :redirfail/:spawnerrx left it,
*-- except that a `&` list is 0 whatever happened (BG_RECORD's
*-- unconditional store, kept).
            jsr   JOB_SETPIDS
            bcc   :jspawned
            lda   PARSE_SEPOP
            cmp   #SEP_BG
            bne   :nokids
            stz   LASTSTATUS
:nokids     rts
*-- BACKGROUND (docs/SH-BG.md). Everything above is identical
*-- for a foreground and a background pipeline -- same pipes,
*-- same redirects, same spawns. The ONLY difference is here:
*-- the row stays Running instead of being waited on (JOB_BG:
*-- `[n] pid`, the W4 diagnostic, `$?` = 0 because POSIX says
*-- an asynchronous list exits 0 whatever its children do).
:jspawned    lda   PARSE_SEPOP
            cmp   #SEP_BG
            bne   :fgjob
            jmp   JOB_BG
*-- FOREGROUND (docs/JOB-CONTROL.md Increment A): name the job
*-- to the kernel BEFORE waiting on it, so a ^C during the wait
*-- kills exactly these stages. A `&` pipeline never gets here,
*-- which is precisely what lets it survive ^C. Then FG_WAIT
*-- (shjob.s, Increment C): the reap loop that used SC_WAIT
*-- here -- blocking, zombies only -- is SC_WAITJOB now, so a ^Z
*-- comes back as a Stopped job instead of an ERR_CHILD the
*-- shell shrugged at. It ends in FG_CLEAR: nothing is
*-- foreground at the prompt.
:fgjob      jsr   FG_DECLARE
            jmp   FG_WAIT

*---------------------------------------------------------------
* CLS_ALL_PIPES -- close sh's own copies of
* PIPE_RFD/WFD[0..NPIPES). CLOBBERS: A, X.
*---------------------------------------------------------------
CLS_ALL_PIPES
            stz   PIPEI
:loop       lda   PIPEI
            cmp   NPIPES
            beq   :done
            ldx   PIPEI
            lda   PIPE_RFD,x
            jsr   CLOSE_FD_A
            ldx   PIPEI
            lda   PIPE_WFD,x
            jsr   CLOSE_FD_A
            inc   PIPEI
            bra   :loop
:done       rts

* See B.SH.TXT: "BUILDFDACTIONSSTAGE -- build FDABUF (a FDACTEN"
*
*-- CHILDMAP and the ordering rule (docs/SH-FEATURES.md sec 15).
*-- The kernel resolves a FDACT_DUP's SOURCE fd against the
*-- PARENT's table as of spawn() time -- never against a fd an
*-- EARLIER action in the same list just created (inc/
*-- sc.fdact.equ says so in as many words, and PRC_
*-- FDACTIONS in src/kernel/procfile2.s does exactly that: it
*-- looks the source up under PRC_PAR_PID and the target under
*-- PRC_CHILD_PID). So a naive `2>&1` -- emit DUP target=2
*-- source=1 and hope the kernel notices that fd 1 was just
*-- pointed at a file -- would ALWAYS copy sh's own fd 1, and
*-- `CMD > FILE 2>&1` would send stderr to the tty.
*--
*-- sh therefore does the resolution itself, which it is in a
*-- position to do because it built the list: CHILDMAP[k] is the
*-- PARENT fd that the child's fd k points at, as of this point
*-- in the left-to-right walk. It starts as the identity (the
*-- child inherits the parent's table), each wiring step updates
*-- the entry it changed, and `N>&M` emits DUP target=N source=
*-- CHILDMAP[M] -- a parent fd, which is what the kernel wants.
*-- $FF marks a child fd closed by `N>&-`.
*--
*-- Order of application, and it IS the feature:
*--   1. fd 0 (pipe-in / here-doc / `< FILE`)
*--   2. fd 1 (pipe-out), when this is not the last stage
*--   3. the dups written BEFORE this stage's file redirect
*--   4. the file redirect itself (`> FILE`, `N>> FILE`, ...)
*--   5. the dups written AFTER it
*-- Steps 3-5 are the source order PARSE recorded in DUP_POS.
*-- Steps 1-2 come first on purpose and match Bourne: a pipeline
*-- is plumbed before the command's own redirections run, which
*-- is what makes `AS FOO.S 2>&1 | GREP ERROR` put the
*-- diagnostics into the PIPE rather than on the tty.
BLD_FDCTS_STG
            stz   CMD_INFD
            stz   CMD_OUTFD
            stz   XOUTN
            stz   FDAIDX
            jsr   INIT_CHLDMAP
*-- Compound redirection (docs/SH-FEATURES.md sec 18) goes in
*-- FIRST, before this command's own plumbing, because that is
*-- when it happened: the enclosing construct's `< FILE` was
*-- established before the command inside it ever started. Every
*-- wiring step below therefore OVERRIDES it -- the command's
*-- own `<`/`>`, a pipe, a here-doc -- which is exactly Bourne's
*-- inner-wins rule, and it costs no test here to get: the last
*-- FDACT_DUP naming a given child fd is the one that sticks.
            jsr   CR_STAGE_IN
            jsr   CR_STAGE_OUT

            lda   STAGEI
            bne   :pipein
*-- Tier 3 here-doc (docs/SH-FEATURES.md sec 6.2): a here-doc on
*-- stage 0 wins over an ordinary CMD_INFILE check entirely --
*-- HD_MKPIPE wires fd0 from a fresh pipe instead of opening a
*-- file. v1 restriction: only STAGEI==0 is ever checked here
*-- (PARSE's own :heredoc handler already refuses one on a later
*-- stage, HD_BADSTAGE).
            lda   HD_ACTIVE
            beq   :normalin
            jsr   HD_MKPIPE
            bcs   :hdfailed
            lda   HD_RFD               ;child fd0 now names the
            sta   CHILDMAP+0             ;  here-doc pipe
            bra   :fd0done
:hdfailed   jmp   :stagefail
:normalin   lda   STAGEI
            asl   a
            tax
            lda   CMD_INFILE,x
            ora   CMD_INFILE+1,x
            beq   :fd0done
            lda   CMD_INFILE,x
            sta   PTR0
            lda   CMD_INFILE+1,x
            sta   PTR0+1
            jsr   OPEN_REDIR_RD
            bcc   :rdopened         ;`jmp`, not `bcs` -- range
            jmp   :stagefail        ;(:stagefail is too far)
:rdopened   sta   CMD_INFD
            sta   CHILDMAP+0
            jsr   EMIT_DUP0_A
            lda   CMD_INFD
            jsr   EMIT_CLOSE_A
            bra   :fd0done
:pipein     ldx   STAGEI
            dex
            lda   PIPE_RFD,x
            sta   CHILDMAP+0
            pha
            lda   PIPE_WFD,x
            sta   FDATMP2
            pla
            jsr   EMIT_DUP0_A
            lda   FDATMP2
            jsr   EMIT_CLOSE_A
:fd0done
            lda   STAGEI
            clc
            adc   #1
            cmp   NCMD
            beq   :redirs                ;the last stage
:pipeout    ldx   STAGEI
            lda   PIPE_WFD,x
            sta   CHILDMAP+1
            pha
            lda   PIPE_RFD,x
            sta   FDATMP2
            pla
            jsr   EMIT_DUP1_A
            lda   FDATMP2
            jsr   EMIT_CLOSE_A
*-- THE STAGE'S OWN REDIRECTIONS, piped or not, after the pipe
*-- is plumbed (KFIX3 item 1). Bourne runs a pipeline's plumbing
*-- first and the command's redirections on top of it, so a
*-- piped stage's `2> E` puts stderr in E while stdout goes down
*-- the pipe, and its `> F` takes fd 1 away from the pipe. This
*-- used to skip the file redirect on every stage but the last
*-- ("the pipe wins"): `cmd 2> E | next` never created E.
*-- Steps 3-5: the records written before the stage's first
*-- file redirect, that redirect, then everything after it.
:redirs     lda   #0
            jsr   EMIT_DUPS
            bcs   :stagefail
            jsr   STG_OUTFILE
            bcs   :stagefail
            lda   #1
            jsr   EMIT_DUPS
            bcs   :stagefail
            jsr   EMIT_END
            clc
            rts
:stagefail  lda   CMD_INFD
            beq   :nfi
            jsr   CLOSE_FD_A
            stz   CMD_INFD
:nfi        jsr   CLS_OUTFD              ;files opened before
            sec                          ;one failed
            rts

*---------------------------------------------------------------
* CR_STAGE_IN / CR_STAGE_OUT -- wire this stage's fds from the
* innermost enclosing construct redirect, if any (docs/
* SH-FEATURES.md sec 18). Called at the TOP of BLD_FDCTS_STG, so
* anything the command itself asks for overwrites them.
*
* CR_STAGE_IN applies to the FIRST stage only and CR_STAGE_OUT
* to the LAST -- `DONE < F` feeds the head of a pipeline and
* `DONE > F` catches its tail, the same shape a simple command's
* own `< F`/`> F` already have. Middle stages are pipe to pipe.
*
* The EMIT_CLOSE_A closes the CHILD's inherited copy of sh's own
* fd, never sh's -- sh keeps it open for the construct's whole
* life. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*---------------------------------------------------------------
* CLS_OUTFD -- close sh's OWN copy of a staged redirect target,
* the same duty RUN_PIPELINE discharges at :closestage.
*
* THE CHILD HAS ITS OWN via fdactions, so a surviving parent
* copy is a pure leak -- and with 8 fds per process it is a leak
* that kills the SHELL, several commands later, nowhere near
* the construct that caused it. Measured 2026-08-27: the first
* cut of the group-redirect work omitted this, and check-shlang
* wrote `GX` correctly and then died -- 57 of its 83 expected
* lines simply absent, with no diagnostic. Idempotent (`stz`),
* so calling it on both the spawned and the failed path is
* safe. KFIX3 item 1: the FILE records of the stage's redirect
* list (XOUTFD) are parent copies of the same kind and go with
* it. CLOBBERS: A, X.
*---------------------------------------------------------------
CLS_OUTFD   lda   CMD_OUTFD
            beq   :cofnone
            jsr   CLOSE_FD_A
            stz   CMD_OUTFD
:cofnone    lda   XOUTN
            beq   :cofdone
            dec   XOUTN
            ldx   XOUTN
            lda   XOUTFD,x
            jsr   CLOSE_FD_A
            bra   :cofnone
:cofdone    rts

*---------------------------------------------------------------
* INIT_CHLDMAP -- CHILDMAP[i] = i, the identity map every fd
* wiring step then overrides. Factored 2026-08-27 alongside
* STG_OUTFILE so SUB_GROUP starts from the same clean map an
* ordinary command does. CLOBBERS: A, X.
*---------------------------------------------------------------
INIT_CHLDMAP
            stz   TGTSET                 ;no target named yet
            ldx   #0
:cmloop     txa
            sta   CHILDMAP,x
            inx
            cpx   #NFDMAP
            bne   :cmloop
*-- falls into EMIT_USERFDS: every list starts with the grant
*-- (FDAIDX is 0 at both callers' INIT_CHLDMAP)

*---------------------------------------------------------------
* EMIT_USERFDS -- grant the child the descriptors the USER holds
* A spawned child starts with fds 0/1/2 only (docs/SYSCALL.md
* Item 10), so without this `exec 3<F; ( cat <&3 )` hands the
* subshell nothing, and `cat <&3` there dups from a closed fd,
* which the kernel skips silently (docs/SH-FD-NOTES.md). One
* identity dup per USERFDS bit, ahead of every other record,
* so a stage's own `3>G` still overrides it (the last record
* for a child fd wins). CHILDMAP is already the identity. Only
* the fds the user opened, never sh's own pipes and script fd.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
EMIT_USERFDS
            ldx   #3
:uf         lda   TGT_BIT,x
            and   USERFDS
            beq   :ufn
            txa
            jsr   EMIT_DUP_A             ;source = target = X
:ufn        inx
            cpx   #8
            bne   :uf
            rts

*---------------------------------------------------------------
* UFD_DUP2 / UFD_CLOSE -- the segment's `exec` calls these in
* place of SC_DUP2 / CLOSE_FD_A, so USERFDS tracks the fds it
* opens and closes at no cost in the $E000 segment.
* UFD_DUP2: A = old fd, X = new fd; carry as SC_DUP2.
* UFD_CLOSE: A = the fd. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- Refuse an `exec` onto the fd the shell is reading its
*-- commands from (CUR_IN_FD) or an outer `.`/script's: the new
*-- file's lines would run as commands.  Only fd 3 and up; fd 0
*-- is the script's own stdin and `exec <F` re-points it by
*-- design.
UFD_DUP2    cpx   #3
            bcc   :go
            cpx   CUR_IN_FD
            beq   :ref
            pha
            ldy   SRC_DEPTH
:ck         dey
            bmi   :pgo
            txa
            cmp   SRC_STACK,y
            bne   :ck
            pla
:ref        sec
            rts
:pgo        pla
:go         phx
            jsr   SC_DUP2
            plx
            bcs   :out
            jsr   UFD_SET                ;(leaves carry alone)
:out        rts
UFD_CLOSE   pha
            jsr   CLOSE_FD_A
            plx
            jmp   UFD_CLR

*---------------------------------------------------------------
* SB_DUPCL -- IN: A = a freshly opened fd, X = the fd it should
* become. dup2 then close the temporary, so the shell keeps
* exactly one fd per redirection rather than two. (Moved here
* from the $E000 segment with UFD_DUP2, which it now calls.)
*
* The equality guard is not decoration: dup2(fd, fd) on an OPEN
* fd is a documented no-op returning fd (SC_DUP2's own header),
* so closing the temporary would shut the very fd the caller
* just installed. That case is the COMMON one for `exec 3<F`
* (the open lands on 3 itself); it still goes through UFD_DUP2,
* for the mark, and skips the close.
* OUT: carry from SC_DUP2. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SB_DUPCL    sta   SBFD
            stx   SBDTGT
            cmp   SBDTGT
            beq   :xdsame
            ldx   SBDTGT
            jsr   UFD_DUP2
            bcs   :xdbad
            lda   SBFD
            jsr   CLOSE_FD_A
            clc
:xdout      rts
:xdbad      lda   SBFD                   ;refused: close the
            jsr   CLOSE_FD_A             ;temporary
            sec
            rts
:xdsame     ldx   SBDTGT
            lda   SBFD
            jmp   UFD_DUP2

*---------------------------------------------------------------
* UFD_SET / UFD_CLR -- X = fd (0-7): set / clear its USERFDS bit
* Bits 0-2 are harmless (EMIT_USERFDS starts at 3). CLOBBERS: A.
*---------------------------------------------------------------
UFD_SET     lda   TGT_BIT,x
            ora   USERFDS
            sta   USERFDS
            rts
UFD_CLR     lda   TGT_BIT,x
            eor   #$FF
            and   USERFDS
            sta   USERFDS
            rts

*---------------------------------------------------------------
* STG_OUTFILE -- stage STAGEI's own `>` / `>>` / `N>` into the
* child's fd-action list.
*
* FACTORED OUT OF BLD_FDCTS_STG 2026-08-27 so SUB_GROUP can
* reuse it. A `( ... ) > F` used to be REFUSED because this
* staging lived inline in a path a group never reaches, and
* CHCK_GROUP said so in its own words: "honouring it needs that
* staging". This IS that staging; nothing about it was ever
* specific to an ordinary command.
*
* IN:  STAGEI.
* OUT: carry SET if the open FAILED (caller abandons the stage);
*      carry CLEAR both when a redirect was staged and when this
*      stage has no file redirect at all.
* CLOBBERS: A, X, Y, PTR0, CMD_OUTFD, CHILDMAP[target].
*---------------------------------------------------------------
STG_OUTFILE lda   STAGEI
            asl   a
            tax
            lda   CMD_OUTFILE,x
            ora   CMD_OUTFILE+1,x
            beq   :sgnone
            lda   CMD_OUTFILE,x
            sta   PTR0
            lda   CMD_OUTFILE+1,x
            sta   PTR0+1
            ldx   STAGEI                  ;CMD_APPEND is 1 byte/
                                          ;stage, unlike
                                          ;CMD_OUTFILE -- reload
                                          ;UNSCALED
            lda   CMD_APPEND,x
            beq   :sgtrunc
            jsr   OPEN_REDIR_AP
            bra   :sgopened
:sgtrunc    jsr   OPEN_REDIR_WR
*-- The target fd is not always 1: plain `>`/`>>` arrive with
*-- CMD_TGTFD[STAGEI]==FD_STDOUT (ZR_CMD_TABLES' default), and
*-- `2>`/`N>`/`N>>` with whatever SET_TGTFD recorded -- hence
*-- the GENERIC EMIT_DUP_A, not the fd1-only EMIT_DUP1_A.
:sgopened   bcs   :sgofail
            sta   CMD_OUTFD
            ldx   STAGEI
            lda   CMD_TGTFD,x
            tax                           ;X = target fd
            lda   CMD_OUTFD
            jsr   EMIT_FILEFD             ;dup, close, and the
                                          ;CHILDMAP entry a
                                          ;LATER `M>&N` sees
:sgnone     clc
            rts
:sgofail    sec
            rts

CR_STAGE_IN lda   STAGEI
            bne   :no
            lda   #1
            jsr   CR_FIND
            bcs   :no
            sta   FDATMP2
            sta   CHILDMAP+0
            jsr   EMIT_DUP0_A
            lda   FDATMP2
            jsr   EMIT_CLOSE_A
:no         rts

CR_STAGE_OUT
            lda   STAGEI
            clc
            adc   #1
            cmp   NCMD
            bne   :no
            lda   #2
            jsr   CR_FIND
            bcs   :no
            sta   FDATMP2
            ldx   CRTGT
            sta   CHILDMAP,x             ;a later `M>&N` in this
                                         ;  command must see the
                                         ;  construct's FILE
            lda   FDATMP2
            jsr   EMIT_DUP_A             ;X = target child fd
            lda   FDATMP2
            jsr   EMIT_CLOSE_A
:no         rts

*---------------------------------------------------------------
* EMIT_DUP0_A / EMIT_DUP1_A / EMIT_CLOSE_A / EMIT_END -- append
* one fdactions record to FDABUF at FDAIDX, advance FDAIDX. IN:
* A = source fd (DUP) or target fd (CLOSE). CLOBBERS: A, Y.
*---------------------------------------------------------------
EMIT_DUP0_A phx                      ;X is preserved, as it
            ldx   #0                     ;always was: the target
            bra   EMIT_DUPX              ;fd is the opcode's own

EMIT_DUP1_A phx
            ldx   #1
EMIT_DUPX   jsr   EMIT_DUP_A
            plx
            rts

*---------------------------------------------------------------
* EMIT_DUP_A -- same record as EMIT_DUP0_A/EMIT_DUP1_A above,
* but with an ARBITRARY target fd instead of one baked into the
* opcode -- the one call site (BLD_FDCTS_STG's file-redirect
* path) that needs a target the PARSER chose (`2>`/`N>`/`N>>`,
* docs/SH-FEATURES.md sec 3). The pipe-stage dup (:pipeout,
* above) keeps calling EMIT_DUP1_A directly -- a pipe's write
* end always becomes the NEXT stage's fd 1, unaffected by this
* feature. IN: A = source fd, X = target fd. CLOBBERS: A, Y.
*---------------------------------------------------------------
EMIT_DUP_A  pha
            txa
            jsr   MARK_TGT
            ldy   FDAIDX
            lda   #FDACT_DUP
            sta   FDABUF,y
            txa
            sta   FDABUF+1,y
            pla
            sta   FDABUF+2,y
EMIT_ADV3   lda   FDAIDX
            clc
            adc   #3
            sta   FDAIDX
            rts

*---------------------------------------------------------------
* MARK_TGT -- record that child fd A is the TARGET of a dup this
* stage's fdactions list now carries (KFIX3 review B1). IN: A =
* the target fd (0-7). X, Y and the stack are preserved.
* EMIT_FILEFD reads it back: the child's inherited copy of a
* FRESH file fd must not be closed when an earlier record
* already installed something on that very number.
*---------------------------------------------------------------
MARK_TGT    phx
            tax
            lda   TGT_BIT,x
            ora   TGTSET
            sta   TGTSET
            plx
            rts
TGT_BIT     dfb   $01,$02,$04,$08,$10,$20,$40,$80

EMIT_CLOSE_A
            pha
            ldy   FDAIDX
            lda   #FDACT_CLOSE
            sta   FDABUF,y
            pla
            sta   FDABUF+1,y
            lda   #0
            sta   FDABUF+2,y
            bra   EMIT_ADV3

EMIT_END    ldy   FDAIDX
            lda   #FDACT_END
            sta   FDABUF,y
            rts
