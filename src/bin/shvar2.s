*---------------------------------------------------------------
* shvar2.s -- sh's builtin-read half of variables,
* split from shvar.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2). One assembly
* stream: ALWAYS put immediately after its predecessor; every
* rule in the original header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* CHCK_BLTN_RD -- the `read` builtin (docs/SH-FEATURES.md sec
* 16). `READ VAR` reads ONE line and assigns it; `READ A B C`
* splits that line on spaces/tabs and gives the LAST named
* variable the WHOLE remainder, embedded spaces included --
* Bourne's own rule, and the half that makes `read` useful for
* anything but single words. Fewer words than variables leaves
* the surplus variables EMPTY (Bourne); more words than
* variables is exactly what the last-absorbs rule covers.
*
* IT READS FD 0, NOT CUR_IN_FD, and the distinction is the whole
* correctness question here. CUR_IN_FD is where the SHELL reads
* its script -- a `.`-sourced file while `.` is active, fd 0
* otherwise. `read` is a Unix builtin that consumes the
* PROCESS's standard input, so it hardwires FD_STDIN. The
* consequence, authentic to V7 and documented rather than
* patched: under `SH < FILE` those two fds are the SAME open
* file, so `read` consumes the script's own next line.
*
* At EOF -- a read that produces ZERO bytes -- the status is
* nonzero and NOT ONE VARIABLE IS TOUCHED. That is what lets a
* caller loop on the status, so it is a hard contract, not a
* nicety. A partial final line (bytes, then EOF, no CR) is a
* line like any other, exactly READLINE's own rule above.
*
* `read VAR < FILE` is REFUSED LOUDLY rather than silently
* ignored. Builtins dispatch BEFORE RUN_PIPELINE, which is what
* applies redirection, so the `<` could never take effect -- and
* silently reading fd 0 instead of the named file is the exact
* class of quiet wrong answer this shell diagnoses everywhere
* else. See docs/SH-FEATURES.md sec 16 for why the compound
* form (`... DONE < FILE`) is out of scope too.
*
* Splits on $IFS (IFS_RESOLVE at :rdstart) -- space, tab and
* newline when the variable is unset, V7's own default.
*
* OUT: carry SET if the command was `read` (handled -- do not
* spawn; LASTSTATUS set), carry CLEAR otherwise.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
CHCK_BLTN_RD
            lda   #<READ_STR
            sta   PTR1
            lda   #>READ_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :isread
            clc
            rts
:isread     lda   CMD_ARGC+0
            cmp   #2
            bcs   :haveargs
            jmp   :eusage
*-- The `<` refusal. CMD_INFILE is a 2-byte pointer per stage,
*-- zeroed for every segment by ZR_CMD_TABLES, so both bytes
*-- zero means "this stage named no input file".
:haveargs   lda   CMD_INFILE+0
            ora   CMD_INFILE+1
            ora   HD_ACTIVE              ;`<<EOF` likewise: the
                                         ;  body goes to a pipe
                                         ;  only a spawn builds
            beq   :nameck
            jmp   :eredir
*-- Every NAME is validated HERE, before a single byte is read.
*-- Ordering is a real behaviour, not tidiness: a name rejected
*-- AFTER the read would have silently eaten a line of the
*-- caller's input on its way to reporting the error, and a
*-- script's input stream would then be one line out of step
*-- with itself from that point on. Same first-character rule
*-- CHCK_BLTN_VAR enforces, and for the same reason: a variable
*-- named "9" could never be read back, since `$9` is a
*-- positional parameter -- it would just consume one of the
*-- eight slots invisibly.
:nameck     lda   #1
            sta   RDBI
:nloop      lda   RDBI
            cmp   CMD_ARGC+0
            beq   :rdstart
            jsr   RDB_NAMPTR
            ldy   #0
            lda   (PTR0),y
            jsr   ISNAME1              ;letter, either case
            bcs   :nlen
            jmp   :eusage
:nlen       iny
            lda   (PTR0),y
            beq   :nok
            cpy   #VARNAMELEN
            bcc   :nlen
            jmp   :entlong
:nok        inc   RDBI
            bra   :nloop
*-- One line off FD 0, byte at a time -- READLINE's own shape
*-- and discipline (docs/SH-DESIGN.md ruling 6), against a
*-- SEPARATE buffer: LINEBUF holds the line this very command
*-- was tokenized out of, and CMD_ARGV points INTO it, so the
*-- variable NAMES would be overwritten by the value text.
*-- WHICH fd, resolved ONCE here rather than per byte. Still fd
*-- 0 in every case this builtin shipped with -- but a `read`
*-- running inside `WHILE ... ; DONE < FILE` reads FILE, which
*-- is the entire point of compound redirection (docs/
*-- SH-FEATURES.md sec 18) and the idiom sec 16 had to leave
*-- unusable. NOT CUR_IN_FD, which is still the SCRIPT: the two
*-- are as distinct as they ever were, and a construct redirect
*-- moves neither of them -- it is a third fd sh holds open for
*-- the frame's life.
:rdstart    jsr   IFS_RESOLVE           ;`read` splits on $IFS
                                        ;(V7) -- resolved once
                                        ;per read, not per byte
            stz   RDBLEN
            lda   #1
            jsr   CR_FIND
            bcc   :haverdfd
            lda   #FD_STDIN
:haverdfd   sta   RDFD
*-- A `<&N` / `0<&N` on THIS command is a dup record for
*-- target 0 (never CMD_INFILE, which is `< FILE`): the last
*-- one names the fd. A close or a FILE kind (>= 8) is not
*-- applied, so it is refused.
            ldx   DUPN
:rdscan     dex
            bmi   :rdscdone
            lda   DUP_TGT,x
            bne   :rdscan
            lda   DUP_SRC,x
            cmp   #8
            bcc   :rdfdok
            jmp   :eredir
:rdfdok     sta   RDFD
:rdscdone
:rloop      ldx   RDFD
            jsr   GETC
            bcc   :rgot
            lda   RDBLEN
            bne   :rterm               ;partial line before EOF
            jmp   :eof
:rgot       cmp   #$8D                 ;CR -- ends the line, and
            beq   :rterm               ;  is never stored
            ldy   RDBLEN
            cpy   #LINEMAX
            bcs   :rloop               ;too long -- drop the
            sta   RDBUF,y              ;  excess (READLINE's own
            inc   RDBLEN               ;  v1 rule)
            bra   :rloop
:rterm      ldy   RDBLEN
            lda   #0
            sta   RDBUF,y
*-- Strip TRAILING whitespace once, here, rather than inside the
*-- last variable's own case: it is the same answer for both (a
*-- non-final field ends at whitespace anyway) and it means the
*-- last variable can simply take the rest of the buffer.
:rstrip     ldy   RDBLEN
            beq   :split
            dey
            lda   RDBUF,y
            jsr   ISIFS   
            bne   :split
            sty   RDBLEN
            lda   #0
            sta   RDBUF,y
            bra   :rstrip
:split      lda   #1
            sta   RDBI
            stz   RDBPOS
:vloop      lda   RDBI
            cmp   CMD_ARGC+0
            bne   :skipws
            jmp   :ok
:skipws     ldy   RDBPOS
            lda   RDBUF,y
            beq   :fldstart            ;line exhausted -- this
            jsr   ISIFS                ;  and every remaining
            bne   :fldstart            ;  variable gets ""
            inc   RDBPOS
            bra   :skipws
:fldstart   lda   #<RDBUF
            clc
            adc   RDBPOS
            sta   PTR2
            lda   #>RDBUF
            adc   #0
            sta   PTR2+1
*-- The last variable absorbs the remainder verbatim: the buffer
*-- is already NUL-terminated and already trailing-stripped, so
*-- there is nothing left to do for it.
            lda   RDBI
            clc
            adc   #1
            cmp   CMD_ARGC+0
            beq   :assign
:fscan      ldy   RDBPOS
            lda   RDBUF,y
            beq   :assign
            jsr   ISIFS   
            beq   :fcut
            inc   RDBPOS
            bra   :fscan
:fcut       ldy   RDBPOS
            lda   #0
            sta   RDBUF,y
            inc   RDBPOS               ;past the NUL just laid
*-- VARSET's header makes the length checks the CALLER's job --
*-- it STRCPYs straight into a fixed-stride slot, so an
*-- unchecked over-long value walks into the NEXT variable's.
:assign     ldy   #0
:vlen       lda   (PTR2),y
            beq   :vlenok
            iny
            cpy   #VARVALLEN+1
            bcc   :vlen
            jmp   :evtlong
:vlenok     jsr   RDB_NAMPTR
            jsr   VARSET
            bcs   :evfull
            inc   RDBI
            jmp   :vloop
:ok         stz   LASTSTATUS
            sec
            rts
*-- EOF: nonzero status, no variable written. The two halves are
*-- one contract -- a loop that stops on the status must not
*-- also have to defend against a stale assignment.
:eof        lda   #1
            sta   LASTSTATUS
            sec
            rts
:eusage     lda   #<RDUSAGE_MSG
            sta   PTR0
            lda   #>RDUSAGE_MSG
            sta   PTR0+1
            bra   :eprint
:eredir     lda   #<RDREDIR_MSG
            sta   PTR0
            lda   #>RDREDIR_MSG
            sta   PTR0+1
            bra   :eprint
:evfull     jsr   SEL_VARFULL
            sta   PTR0
            stx   PTR0+1
            bra   :eprint
:entlong    lda   #<VARNMLONG_MSG
            sta   PTR0
            lda   #>VARNMLONG_MSG
            sta   PTR0+1
            bra   :eprint
:evtlong    lda   #<VARVLLONG_MSG
            sta   PTR0
            lda   #>VARVLLONG_MSG
            sta   PTR0+1
:eprint     jsr   PR_ERR
            lda   #1
            sta   LASTSTATUS
            sec
            rts

*-- RDB_ISWS (the fixed space/tab separator test) is gone:
*-- `read` splits on ISIFS against the $IFS set IFS_RESOLVE
*-- staged at :rdstart, exactly as SPLIT_APPEND does for words.
*-- With $IFS unset the set is space/tab/newline, and a newline
*-- can never be IN the buffer (CR ends the line, never stored)
*-- -- so default behaviour is byte-identical to the old test.

*---------------------------------------------------------------
* RDB_NAMPTR -- IN: RDBI = an argv index for stage 0. OUT: PTR0
* = CMD_ARGV[RDBI], the variable name in that slot. Stage 0's
* rows start at offset 0, so RDBI*2 indexes CMD_ARGV directly
* and stays inside a byte (MAXARGV is 32). CLOBBERS: A, X.
*---------------------------------------------------------------
RDB_NAMPTR  lda   RDBI
            asl   a
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            rts

READ_STR    asc   "READ"
            dfb   0
RDUSAGE_MSG asc   "usage: read NAME ... (NAME starts A-Z)"
            dfb   $8D,0
RDREDIR_MSG asc   "sh: read: reads fd 0 -- < FILE not applied"
            dfb   $8D,0

RDBLEN      ds    1        ;bytes in RDBUF, excl. the NUL
RDBPOS      ds    1        ;split cursor into RDBUF
RDBI        ds    1        ;which argv slot is being assigned
RDFD        ds    1        ;which fd this `read` is reading --
                           ;FD_STDIN, or an enclosing
                           ;construct's `<` (sec 18)

*---------------------------------------------------------------
* FOR_ROWBASE -- IN: X = construct-stack depth (0..MAXCDEPTH-1).
* OUT: PTR2 = CSFORWORDS + X*(FORWORDMAX*FORWORDLEN) -- the
* base address of this frame's own word-list arena row. X*128
* needs 16-bit math (max 7*128=896), done ONCE per `for` (at
* RW_FOR push time) and cached into CSFORWORDPTR -- every later
* access (RW_DO_FOR, RW_DONE_FOR/FOR_ASSIGN) just loads the
* cached pointer instead of recomputing this. CLOBBERS: A, Y.
*---------------------------------------------------------------
FOR_ROWBASE txa
            sta   FTMP16
            stz   FTMP16+1
*-- 8 shifts, not 7: FORWORDMAX*FORWORDLEN raised 128 -> 256
*-- (2026-09-15, sh.s's own FORWORDMAX comment) -- still an
*-- exact power of 2, one more shift is the whole fix.
            ldy   #8
:shl        asl   FTMP16
            rol   FTMP16+1
            dey
            bne   :shl
            lda   FTMP16
            clc
            adc   #<CSFORWORDS
            sta   PTR2
            lda   FTMP16+1
            adc   #>CSFORWORDS
            sta   PTR2+1
            rts

*---------------------------------------------------------------
* FOR_WORDADDR -- IN: X = construct-stack depth, A = word index
* (0..FORWORDMAX-1). OUT: PTR2 = &CSFORWORDS[depth][index], via
* the cached CSFORWORDPTR[depth] (no 16-bit math here -- index*
* FORWORDLEN maxes at 7*16=112). CLOBBERS: A, X.
*---------------------------------------------------------------
FOR_WORDADDR
            pha
            txa
            asl   a
            tax
            lda   CSFORWORDPTR,x
            sta   PTR2
            lda   CSFORWORDPTR+1,x
            sta   PTR2+1
            pla
            asl   a
            asl   a
            asl   a
            asl   a
            clc
            adc   PTR2
            sta   PTR2
            lda   PTR2+1
            adc   #0
            sta   PTR2+1
            rts

*---------------------------------------------------------------
* FOR_ASSIGN -- IN: X = construct-stack depth of a live FOR
* frame. Copies CSFORWORDS[depth][CSFORIDX[depth]] into the
* loop variable's value slot (CSFORVARSLOT[depth], set once by
* RW_FOR) directly -- no name search, the slot was already
* resolved at push time. CLOBBERS: A, X, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
FOR_ASSIGN  lda   CSFORVARSLOT,x
            sta   FASLOT
            lda   CSFORIDX,x
            jsr   FOR_WORDADDR             ;CLOBBERS X
            lda   PTR2
            sta   PTR0
            lda   PTR2+1
            sta   PTR0+1
            ldx   FASLOT
            jsr   VSLOT_VAL
            jsr   STRCPY
            rts

*---------------------------------------------------------------
* RW_FOR -- push a FOR frame: `FOR NAME IN WORD...` (FOR already
* shifted off by CHCK_RESERVED/RW_SHIFT, so CMD_ARGV[0]=NAME,
* CMD_ARGV[1]="IN", CMD_ARGV[2..]=the word list -- already
* glob-expanded, `for f in *.S` needs nothing extra here, docs/
* SH-FEATURES.md sec 4). Copies the word list into this frame's
* own arena row (CMD_ARGV/LINEBUF/EXPBUF are all about to be
* overwritten by the very next line read) and resolves the loop
* variable's table slot once, up front -- every iteration after
* this just pokes that slot directly (FOR_ASSIGN).
*
* Unlike RW_IF/RW_LOOP_PUSH, does NOT depend on ancestor-skip
* state at push time: copying a word list has no side effect
* worth skipping (contrast RW_LOOP_PUSH's real LSEEK probe).
* The one real side effect -- capturing the body's seek head --
* is deferred to RW_DO_FOR, which DOES check ancestor skip first
* (same courtesy RW_LOOP_PUSH shows WHILE/UNTIL).
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
RW_FOR      lda   CSPTR
            cmp   #MAXCDEPTH
            bcc   :ok
            jmp   RW_OVERFLOW
*-- Console-loop spooling (docs/SH-FEATURES.md, 2026-09-15):
*-- ancestor-dead first (CS_EFFSKIP, same courtesy RW_LOOP_PUSH
*-- shows WHILE/UNTIL -- dead code gets no diagnostic and no
*-- spool, it just copies the word list harmlessly the old way
*-- and RW_DO_FOR's own dead branch takes it from there). LIVE
*-- and non-seekable (LMARK_OK 0 -- a tty or a $( ) pipe) means
*-- RW_DONE_FOR could never seek back to replay this body, so
*-- SPOOL_ENTER (shresv.s) copies the whole construct to a temp
*-- file and `.`-sources it INSTEAD of pushing a frame here at
*-- all -- never returns here on success.
:ok         jsr   CS_EFFSKIP
            ora   SH_SKIP                ;SH-CASE2 A: a skipped
            bne   :spoolno               ;  head never spools
            lda   LMARK_OK
            bne   :spoolno
            jmp   SPOOL_ENTER
:spoolno    lda   CMD_ARGC+0
            cmp   #2
            bcs   :haveargs
            jmp   RW_FORSYNERR
:haveargs   lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
            ldy   #0
            lda   (PTR0),y
            jsr   ISNAME1                 ;letter, either case
            bcc   :synerr
            jsr   STRLEN            ;A/X = 16-bit length; a
            cpx   #0                ;high byte at all is longer
            bne   :synerr           ;than any legal name, and
                                    ;the low byte alone would
                                    ;wrap a 300-char name to 44
                                    ;and admit it (string.s's
                                    ;STRLEN header)
            cmp   #VARNAMELEN+1
            bcc   :namelenok
:synerr     jmp   RW_FORSYNERR
:namelenok  lda   CMD_ARGV+2
            sta   PTR0
            lda   CMD_ARGV+3
            sta   PTR0+1
            lda   #<FORIN_STR
            sta   PTR1
            lda   #>FORIN_STR
            sta   PTR1+1
            jsr   STRCMPI
            bne   :synerr
            lda   CMD_ARGC+0
            sec
            sbc   #2
            sta   FORWC
            cmp   #FORWORDMAX+1
            bcc   :wcok
            jmp   RW_FORTOOMANY
:wcok       ldx   CSPTR
            stx   FORFRAME
            jsr   FOR_ROWBASE               ;X (still CSPTR) in
                                            ;-> PTR2 = row base
            ldx   FORFRAME
            txa
            asl   a
            tax
            lda   PTR2
            sta   CSFORWORDPTR,x
            lda   PTR2+1
            sta   CSFORWORDPTR+1,x
            stz   FORI
:cpword     lda   FORI
            cmp   FORWC
            bcs   :cpdone
            lda   FORI
            asl   a
            clc
            adc   #4                       ;CMD_ARGV index of
                                           ;word FORI is
                                           ;(2+FORI), byte
                                           ;offset (2+FORI)*2
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            jsr   STRLEN            ;A/X = 16-bit length; same
            cpx   #0                ;rule as the loop variable
            bne   :wtoolong         ;above -- reject on the high
                                    ;byte before trusting the
                                    ;low one, or STRCPY below
                                    ;overruns this frame's row
            cmp   #FORWORDLEN
            bcc   :wordlenok
:wtoolong   jmp   RW_FORWLONG
:wordlenok  ldx   FORFRAME
            lda   FORI
            jsr   FOR_WORDADDR              ;CLOBBERS X
            lda   PTR2
            sta   PTR1
            lda   PTR2+1
            sta   PTR1+1
            jsr   STRCPY                     ;PTR0(word)->PTR1
            inc   FORI
            bra   :cpword
:cpdone     ldx   FORFRAME
            lda   FORWC
            sta   CSFORCNT,x
            stz   CSFORIDX,x
            lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
            lda   #<EMPTYSTR
            sta   PTR2
            lda   #>EMPTYSTR
            sta   PTR2+1
            jsr   VARSET
            bcc   :varok
            jmp   RW_FORVFULL
:varok      stx   FORVSLOT
            ldx   FORFRAME
            lda   FORVSLOT
            sta   CSFORVARSLOT,x
            lda   #4
            sta   CSTYPE,x
            stz   CSCOND,x               ;`set -e`: FOR has no
                                         ;  condition command
            lda   SH_SKIP                ;SH-CASE2 A: dead head,
            sta   CSSKIP,x               ;  skipped at the push
            sta   CSTAKEN,x
            jsr   CR_INSTALL             ;sec 18 -- X is
            jsr   CR_STARTSCAN           ;  FORFRAME here
            inc   CSPTR
            stz   RW_HASRES              ;var/IN/words are ours
                                         ;-- no residual command
                                         ;(cf. RW_CASE); without
                                         ;it the caller ran the
                                         ;word list as a command
                                         ;-> stray "command not
                                         ;found" on the for line
*-- SH-EXECLOOP: the FIRST word is assigned HERE, not at DO. A
*-- command after `do` on the same line (`do echo $i`) is
*-- expanded when its segment is PARSED, before RW_DO_FOR runs,
*-- so a DO-time assignment would show the residual the previous
*-- word. Live (CS_EFFSKIP counts this frame: 0 unless a scan
*-- pass or an ancestor skips) and non-empty only.
            ldx   FORFRAME
            lda   CSFORCNT,x
            beq   :noasg
            jsr   CS_EFFSKIP
            bne   :noasg
            ldx   FORFRAME
            jmp   FOR_ASSIGN
:noasg      rts

RW_FORSYNERR
            lda   #<FORSYN_MSG
            ldx   #>FORSYN_MSG
            jmp   PR_ERRAX1M

RW_FORTOOMANY
            lda   #<FORMANY_MSG
            ldx   #>FORMANY_MSG
            jmp   PR_ERRAX1M

RW_FORWLONG
            lda   #<FORWLONG_MSG
            ldx   #>FORWLONG_MSG
            jmp   PR_ERRAX1M

RW_FORVFULL
            jsr   PR_VARFULL
            lda   #1
            sta   LASTSTATUS
            jmp   MAINLOOP

FORIN_STR   asc   "IN"
            dfb   0
EMPTYSTR    dfb   0
FORSYN_MSG  asc   "sh: for: syntax error"
            dfb   $8D,0
FORMANY_MSG asc   "sh: for: too many words"
            dfb   $8D,0
FORWLONG_MSG
            asc   "sh: for: word too long"
            dfb   $8D,0

*---------------------------------------------------------------
* RW_DO_FOR -- DO's FOR-type branch (RW_DO, above, jmps here).
* Unlike WHILE/UNTIL's DO, there is no condition to evaluate --
* the "condition" is simply "does the word list have a first
* word". Anything may follow DO on its line (`do CMD`, `; do
* CMD; done`). The frame's replay coordinate is NOT a byte
* offset into the line but two things that survive line
* joining and alias expansion: the LOGICAL LINE'S START
* MARK (LINE_MARK,
* which READLINE leaves at the first physical line of a joined
* line) and SEG_TOKI, the token index where DO's segment begins.
* RW_DONE_FOR posts that index as RP_PEND and seeks to the
* mark; the re-read line is the same text, re-joined and
* re-aliased the same way, so the same tokens; :toknoerr
* (shlex.s) starts PARSE at the DO token. A byte offset would
* be wrong after a backslash-newline (the file has 2 bytes the
* line does not) or an alias spliced in before DO.
* The loop variable is NOT assigned here: words after DO are
* expanded when the segment is parsed, before this runs. RW_FOR
* assigns word 0, RW_DONE_FOR the next one before it seeks.
* REFUSED, loudly (poisoned frame: CSSKIP=1, not popped, so its
* DONE closes it): a here-doc captured in a segment BEFORE DO on
* this line -- its body is read from the input at parse time and
* a replay that skips those segments would run the body as
* commands. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
RW_DO_FOR   stx   FORDOX                    ;X is CSPTR-1
                                            ;already (RW_DO's
                                            ;own :isfor branch
                                            ;never changed it)
            jsr   CS_EFFSKIP                ;this frame's own
                                            ;CSSKIP is still 0
                                            ;-- reflects
                                            ;ancestors only,
                                            ;same trick
                                            ;RW_LOOP_PUSH uses,
                                            ;unless its head was
                                            ;skipped (CSSKIP 1)
            bne   :fordead
            ldx   FORDOX
            lda   CSFORCNT,x
            bne   :nonempty
            lda   #1
            sta   CSSKIP,x
            rts
:nonempty   lda   LMARK_OK
            bne   :seekable
            lda   #1
            sta   CSSKIP,x
            jmp   PR_NOSEEK              ;returns; frame stays
                                         ;pushed and dead, its
                                         ;DONE pops it
:seekable   lda   HD_BEFORE
            beq   :nohd
            lda   #1
            sta   CSSKIP,x
            lda   #<FORHD_MSG
            ldx   #>FORHD_MSG
            jmp   PR_ERRAX1              ;returns, as PR_NOSEEK
:nohd       txa
            sta   CSTMP
            clc
            adc   CSTMP
            clc
            adc   CSTMP                      ;a = 3*x
            tay
            lda   LINE_MARK
            sta   CSHEAD,y
            lda   LINE_MARK+1
            sta   CSHEAD+1,y
            lda   LINE_MARK+2
            sta   CSHEAD+2,y
            lda   SEG_TOKI
            sta   CSFORTOK,x
            stz   CSSKIP,x
            rts
FORHD_MSG   asc   "sh: for: here-doc before do"
            dfb   $8D,0
:fordead    rts                     ;dominated or poisoned:
                                         ;CSSKIP stays until its
                                         ;matching done
*---------------------------------------------------------------
* MOVED 2026-09-16 to src/bin/shsggop.s -- the `getopts` builtin
* now lives in sh's SECOND CODE SEGMENT at $E000+ (docs/
* SH-SUBSET.md ruling 7.6). The strings stayed here: a segment
* address cannot be handed to a syscall (see the header of
* shsggop.s).
*---------------------------------------------------------------


GOPTS_STR   asc   "GETOPTS"
            dfb   0
OPTIND_STR  asc   "OPTIND"
            dfb   0
OPTARG_STR  asc   "OPTARG"
            dfb   0
GOPTUSE_MSG asc   "sh: getopts: usage: getopts optstring name"
            dfb   $8D,0
GOPTBAD_MSG asc   "sh: getopts: illegal option"
            dfb   $8D,0
GOPTREQ_MSG asc   "sh: getopts: option requires an argument"
            dfb   $8D,0
