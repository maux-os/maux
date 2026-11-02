*---------------------------------------------------------------
* shrsv2.s -- sh's control-handoff half of reserved words,
* split from shresv.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2). One assembly
* stream: ALWAYS put immediately after its predecessor; every
* rule in the original header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* CR_HANDOFF -- IN: X = a WHILE/UNTIL frame about to be popped
* by its own DONE and re-pushed by the loop-back. Move its
* redirect into the pending record so the fresh frame inherits
* the SAME open fd -- reopening it per iteration would rewind an
* input file to its first line forever, and truncate an output
* one. Clears the frame's own kind so the pop does not close a
* fd the next frame is about to use.
* PRESERVES X. CLOBBERS: A.
*---------------------------------------------------------------
CR_HANDOFF  lda   LASTSTATUS             ;SH-CASE2 A: the body's
            sta   LP_PEND                ;  status rides along
            lda   CSRKIND,x
            sta   PCR_KIND
            lda   CSRFD,x
            sta   PCR_FD
            lda   CSRTGT,x
            sta   PCR_TGT
            lda   #1
            sta   PCR_PEND
            lda   #0
            sta   CSRKIND,x
            rts

*---------------------------------------------------------------
* CR_CLOSE -- IN: X = a frame index being popped for good. Close
* its construct redirect, if it has one. CLOBBERS: A, X.
*---------------------------------------------------------------
CR_CLOSE    lda   CSRKIND,x
            beq   :none
            stz   CSRKIND,x
            asl   a                      ;bit 7 = borrowed: the
            bcs   :none                  ;  user's fd, not ours
            lda   CSRFD,x
            jmp   CLOSE_FD_A
:none       rts

*---------------------------------------------------------------
* CR_CONTUNW -- IN: X = the loop frame `continue` is targeting.
* `continue` is the one unwind that does NOT run the popped
* frames' own FI/DONE (CHCK_BLTN_BRK :docontinue rewrites CSPTR
* outright), so every construct redirect between the top of the
* stack and the target would leak its fd -- and a process has
* eight. Close those; the TARGET frame is popped and immediately
* re-pushed by the loop-back, so its record is handed over
* instead of closed. PRESERVES X. CLOBBERS: A.
*---------------------------------------------------------------
CR_CONTUNW  stx   CRTMP
            jsr   CR_HANDOFF
            lda   CSPTR
            sta   CRWALK
:loop       lda   CRWALK
            cmp   CRTMP
            beq   :done
            bcc   :done
            dec   CRWALK
            lda   CRWALK
            cmp   CRTMP
            beq   :done
            ldx   CRWALK
            jsr   CR_CLOSE               ;CLOBBERS X
            bra   :loop
:done       ldx   CRTMP
            rts

*---------------------------------------------------------------
* CR_FIND -- IN: A = kind (1 = an input redirect on an enclosing
* construct, 2 = an output one). Walks the construct stack from
* the TOP DOWN, so the INNERMOST enclosing construct wins --
* which is what a nested redirect means in Bourne.
* OUT: carry CLEAR and A = sh's own fd (CRTGT = the child fd it
* feeds) when one is open; carry SET when none is.
* CLOBBERS: A, X.
*---------------------------------------------------------------
CR_FIND     sta   CRWANT
            ldx   CSPTR
:loop       cpx   #0
            beq   :none
            dex
            lda   CSRKIND,x
            and   #$7F                   ;bit 7 = borrowed fd
            cmp   CRWANT
            bne   :loop
            lda   CSRTGT,x
            sta   CRTGT
            lda   CSRFD,x
            clc
            rts
:none       sec
            rts

*---------------------------------------------------------------
* CS_FINDLOOP -- IN: A = N (1-based). Walk the construct stack
* from the TOP down, counting WHILE/UNTIL frames only (IF frames
* are transparent to break/continue) and decrementing N on each.
* OUT: carry CLEAR, X = the matching frame's index, when the Nth
* enclosing loop is found; carry SET (state untouched) when the
* stack holds fewer than N enclosing loops. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
CS_FINDLOOP sta   CSN
            lda   CSPTR
            beq   :notfound
            tay
:loop       cpy   CS_FLOOR               ;C floor
            beq   :notfound
            dey
            lda   CSTYPE,y
            cmp   #2
            beq   :isl
            cmp   #3
            beq   :isl
            cmp   #4                     ;FOR (docs/SH-FEATURES
            beq   :isl                   ;.md sec 4) is a loop
                                         ;type too, transparent
                                         ;to break the same way
                                         ;WHILE/UNTIL are
            bra   :loop
:isl        dec   CSN
            bne   :loop
            tya
            tax
            clc
            rts
:notfound   sec
            rts

*---------------------------------------------------------------
* CHCK_BLTN_BRK -- the `break`/`continue` builtins. Command-
* position only (NCMD==1), same shape as CD/EXIT/TEST -- only
* ever reached once BOTH skip gates (SH_SKIP, CS_EFFSKIP) have
* already passed, unlike CHCK_RESERVED's structural words, which
* are recognised regardless of skip. An optional argv[1] is a
* decimal loop count (default 1, PARSE_STATUS's own saturating
* decimal parser, reused verbatim). Outside a loop -- CS_FIND-
* LOOP can't find the Nth enclosing WHILE/UNTIL -- prints a
* diagnostic to fd 2, sets LASTSTATUS nonzero, and touches
* NOTHING on the construct stack (docs/SH-FEATURES.md's own "do
* not unwind").
*
* `break` sets ONLY the target frame's CSSKIP; CS_EFFSKIP's OR
* across the whole stack silences everything nested inside it,
* which then unwinds normally, one FI/DONE at a time, as the
* script keeps being read -- no code needed here beyond the one
* flag (see the file-header note above).
*
* `continue` instead pops the stack down to (not including) the
* target frame, seeks fd 0 back to ITS remembered loop head, and
* jumps straight to MAINLOOP -- the exact shape RW_DONE's own
* loop-back path uses. A fresh frame is pushed when the
* WHILE/UNTIL line is read again.
*
* OUT: carry SET if the command was `break`/`continue` (handled
* -- do not spawn), carry CLEAR otherwise. CLOBBERS: A, X, Y,
* PTR0, PTR1.

*---------------------------------------------------------------
* `case` / `esac` (docs/SHELL-GAPS.md sec 4). The construct is
* three separate recognitions, only one of which is a reserved
* word in the ordinary sense:
*
*   CASE WORD IN   RW_CASE below -- pushes a frame holding the
*                  EXPANDED word, skipping, no branch taken.
*   PATTERN)       CS_CASEPAT -- NOT a reserved word (the text
*                  is arbitrary), intercepted in MAINLOOP.
*   ;;             a SEPARATOR, classified in CLASSIFY and
*                  reported through PARSE_SEPOP -- see
*                  SEP_DSEMI's own note for why it cannot be a
*                  reserved word.
*   ESAC           RW_ESAC -- pops.
*
* THE FRAME'S SKIP BIT DOUBLES AS THE PARSER STATE, which is
* what keeps this small. CSSKIP=1 means "between branches", and
* that is exactly when a `PATTERN)` word is a pattern; CSSKIP=0
* means a branch is running, and then argv[0] is an ordinary
* command even if it happens to end in ')'. `;;` sets the bit
* again. No separate state byte, and no way for the two to
* disagree.
*
* CSTAKEN stops a SECOND pattern from matching once one has --
* Bourne runs the first matching branch only.
*---------------------------------------------------------------
* CS_CASEWPTR -- IN: X = frame index. OUT: PTR1 = that frame's
* saved word. X survives. CLOBBERS: A.
*---------------------------------------------------------------
CS_CASEWPTR txa
            asl   a                      ;X*CASEWLEN (32); X is
            asl   a                      ;< MAXCDEPTH(8) so the
            asl   a                      ;product is <= 224 and
            asl   a                      ;cannot leave the byte
            asl   a
            clc
            adc   #<CSCASEW
            sta   PTR1
            lda   #>CSCASEW
            adc   #0
            sta   PTR1+1
            rts

*---------------------------------------------------------------
* RW_CASE -- `CASE WORD IN`. argv is [WORD, IN] by the time this
* runs (RW_SHIFT dropped the CASE). CLOBBERS: A, X, Y, PTR0,
* PTR1.
*---------------------------------------------------------------
RW_CASE     lda   CSPTR
            cmp   #MAXCDEPTH
            bcc   :ok
            jmp   RW_OVERFLOW
:ok         lda   CMD_ARGC+0
            cmp   #2
            bcs   :chkin
            jmp   RW_SYNTAXERR           ;`CASE` alone, or with
                                         ;no `IN`
:chkin      ldx   #2
            ldy   #1
            jsr   ARGV_ISSTR
            beq   :havein
            jmp   RW_SYNTAXERR
*-- The word is COPIED, not pointed at: it lives in LINEBUF,
*-- which the very next line read overwrites, and a `case` is
*-- open across many lines by construction.
:havein     lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
            ldx   CSPTR
            jsr   CS_CASEWPTR
            ldy   #0
:cpw        lda   (PTR0),y
            sta   (PTR1),y
            beq   :cpdone
            iny
            cpy   #CASEWLEN
            bcc   :cpw
            jmp   RW_CASELONG
:cpdone     ldx   CSPTR
            lda   #5
            sta   CSTYPE,x
            lda   #1
            sta   CSSKIP,x               ;nothing runs until a
*-- SH-SEQ B: a head that `&&`/`||` skipped is DEAD ($80 in
*-- CSTAKEN): no pattern may match, ESAC leaves `$?` alone.
            lda   SH_SKIP
            lsr   a
            ror   a                      ;$80 if SH_SKIP
            sta   CSTAKEN,x
            stz   CSCOND,x               ;`set -e`: CASE has no
                                         ;  condition command
            jsr   CR_INSTALL             ;sec 18 -- `esac <&3`,
            jsr   CR_STARTSCAN           ;  like every other
                                         ;  terminator (X kept)
            inc   CSPTR
*-- SH-SEQ B: WORD and IN are ours; what follows them is the
*-- FIRST PATTERN and any commands glued behind it
*-- (`case x in x) echo hit;; esac`). Shifted, not dropped:
*-- RW_HASRES says whether a residual is left and MAINLOOP
*-- hands it to CS_CASEPAT.
            jsr   RW_SHIFT
            jmp   RW_SHIFT

*---------------------------------------------------------------
* RW_ESAC -- pop the frame. CLOBBERS: A, X.
*---------------------------------------------------------------
RW_ESAC     lda   CSPTR
            cmp   CS_FLOOR               ;C floor
            beq   :bad
            ldx   CSPTR
            dex
            lda   CSTYPE,x
            cmp   #5
            bne   :bad                   ;`ESAC` closing an IF
                                         ;or a loop -- refuse
                                         ;rather than unwind the
                                         ;wrong construct
            lda   SCAN_ACT               ;sec 18 -- the scan
            cmp   CSPTR                  ;  pass's own ESAC
            beq   :rescan
            lda   CSRKIND,x              ;captured by the scan?
            pha
            jsr   CR_CLOSE
            dec   CSPTR
            stz   RW_HASRES
            jsr   CASE_STATUS            ;SH-SEQ B
            pla
            bne   :done                  ;yes -- it was applied
            jsr   CS_EFFSKIP             ;no: in dead code say
            bne   :done                  ;  nothing, else refuse
            jmp   CK_ORPHRDIR            ;  it, not drop it
:done       rts                          ;  (a typed line)
:rescan     jmp   CR_RESCAN
:bad        jmp   RW_SYNTAXERR

*---------------------------------------------------------------
* CASE_STATUS -- ESAC has popped its frame (X is not used by the
* caller). POSIX: a case returns 0 when no pattern matched, and
* 0 when the matching clause held no command; otherwise the last
* command's status, which LASTSTATUS already holds. LIVE cases
* only (head not short-circuited, no skipping ancestor): a case
* in dead code ran nothing and must not touch `$?`.
* CLOBBERS: A, X.
*---------------------------------------------------------------
CASE_STATUS jsr   CS_EFFSKIP
            bne   :no
            ldx   CSPTR                  ;the popped frame
            lda   CSTAKEN,x
            bmi   :no                    ;dead head
            beq   :zero                  ;no match
            lda   CASE_EMPTY
            beq   :no                    ;a command ran
:zero       stz   LASTSTATUS
:no         rts

*---------------------------------------------------------------
* RW_DSEMI -- `;;` closed a branch. Called from MAINLOOP off
* PARSE_SEPOP, not from RW_DISPATCH. CLOBBERS: A, X.
*---------------------------------------------------------------
RW_DSEMI    lda   CSPTR
            cmp   CS_FLOOR               ;C floor
            beq   :bad
            ldx   CSPTR
            dex
            lda   CSTYPE,x
            cmp   #5
            bne   :bad
            lda   #1
            sta   CSSKIP,x               ;back to "between
            rts                          ;branches"
:bad        jmp   RW_SYNTAXERR           ;`;;` outside a case

*---------------------------------------------------------------
* CS_CASEBTW -- OUT: carry SET and X = the frame index iff the
* top
* construct frame is a CASE between branches (its skip bit is
* the
* parser state, see the case header above). Used by CS_CASEPAT
* and
* by PARSE's PAT_CHECK. CLOBBERS: A, X.
*---------------------------------------------------------------
CS_CASEBTW  ldx   CSPTR
            beq   :no
            dex
            lda   CSTYPE,x
            cmp   #5
            bne   :no
            lda   CSSKIP,x
            beq   :no
            sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* CS_CASEPAT -- is this segment a `case` PATTERN? IN: CMD_ARGV
* and CMD_ARGC as PARSE left them, RW_ID == 0. Carry SET = it
* was, and has been fully handled (the frame's skip bit is set
* or cleared and argv shifted past the pattern); the commands
* glued after it are the NEXT segment and run under the new
* state. Carry CLEAR = not a pattern, dispatch it normally.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*
* SH-CASE2 B: PARSE decides, BEFORE expansion and with the real
* construct stack (PAT_CHECK/PAT_SPLIT, shsub2.s), and says so
* with PARSE_SEPOP = SEP_PAT; the pattern word arrives with its
* `)` already consumed, never globbed or field-split (it used to
* be saved from globbing only because a ProDOS name cannot hold
* a `)`), and with its quote provenance (low bytes) intact.
*---------------------------------------------------------------
CS_CASEPAT  lda   PARSE_SEPOP           ;SH-CASE2 B: PARSE ended
            cmp   #SEP_PAT        ;  this segment at a pattern's
            bne   :no                    ;  `)` (PAT_SPLIT)
            jsr   CS_CASEBTW             ;X = the frame
            bcc   :no
            lda   CMD_ARGC+0
            beq   :no
            lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
            phx                          ;frame index
            jsr   CS_CASEMATCH           ;carry clear = matched
            plx
            bcs   :nomatch
            lda   SCAN_ACT               ;the scan pass runs no
            cmp   CSPTR                  ;  branch, whatever
            beq   :nomatch               ;  the pattern says
            lda   CSTAKEN,x
            bne   :nomatch               ;an earlier branch
            lda   #1                     ;already won
            sta   CSTAKEN,x
            stz   CSSKIP,x               ;run this branch
*-- A match under a SKIPPING ancestor (a nested case in a clause
*-- that did not match) runs nothing and must leave CASE_EMPTY
*-- to the outer case whose clause did.
            jsr   CS_EFFSKIP
            bne   :shift
            lda   #1
            sta   CASE_EMPTY             ;SH-SEQ B
            bra   :shift
:nomatch    lda   #1
            sta   CSSKIP,x
:shift      jsr   RW_SHIFT
            sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* CS_CASEMATCH -- IN: PTR0 = the pattern text, ')' already
* removed; X = frame index. OUT: carry CLEAR if the frame's
* saved word matches. Handles `a|b|c` alternation by cutting
* each alternative's terminator in place and putting it back.
* CLOBBERS: A, Y, PTR1, PTR2.
*---------------------------------------------------------------
CS_CASEMATCH
            jsr   CS_CASEWPTR            ;PTR1 = the word
            lda   PTR1
            sta   CASEWP
            lda   PTR1+1
            sta   CASEWP+1
:alt        ldy   #0                     ;this alternative's
:ascan      lda   (PTR0),y               ;end: '|' or NUL
            beq   :last
            cmp   #$FC                   ;'|' high-bit-set
            beq   :cut
            iny
            bne   :ascan
:last       ldy   #$FF                   ;no '|' -- whole rest
*-- CASEALTY IS WRITTEN ON BOTH PATHS, and the `sty` sits above
*-- the test for that reason. It used to sit below, so the
*-- no-alternation path left it holding the PREVIOUS call's
*-- offset; the restore below then wrote a byte at a stale
*-- offset and the advance loop walked PTR0 off the pattern.
*-- Symptom was a HANG, three lines after the construct it broke
*-- `case` (1) printed correctly, then the shell never came
*-- back.
*-- The declaration's own comment claimed this cell was written
*-- before read on every path; the code did not do it.
:cut        sty   CASEALTY
            cpy   #$FF
            beq   :trywhole
            lda   (PTR0),y
            sta   CASEALTC               ;save the '|'
            lda   #0
            sta   (PTR0),y               ;temporary terminator
:trywhole   lda   CASEWP
            sta   PTR1
            lda   CASEWP+1
            sta   PTR1+1
            jsr   GLOBMATCH              ;PTR0 pat, PTR1 name
            php                          ;verdict
            ldy   CASEALTY
            cpy   #$FF
            beq   :nocut
            lda   CASEALTC
            sta   (PTR0),y               ;put the '|' back
:nocut      plp
            bcc   :hit
            ldy   CASEALTY
            cpy   #$FF
            beq   :miss                  ;that was the last one
            iny                          ;step past the '|'
            tya
            clc
            adc   PTR0
            sta   PTR0
            lda   PTR0+1
            adc   #0
            sta   PTR0+1
            bra   :alt
:hit        clc
            rts
:miss       sec
            rts

RW_CASELONG
            lda   #<CASELONG_MSG
            ldx   #>CASELONG_MSG
            jmp   PR_ERRAX1M

CASELONG_MSG
            asc   "sh: case word too long"
            dfb   $8D,0

*---------------------------------------------------------------
CHCK_BLTN_BRK
            lda   #<BREAK_STR
            sta   PTR1
            lda   #>BREAK_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :isbreak
            lda   #<CONTINUE_STR
            sta   PTR1
            lda   #>CONTINUE_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :iscontinue
            clc
            rts

:isbreak    stz   BRK_KIND
            bra   :getn
:iscontinue lda   #1
            sta   BRK_KIND
:getn       lda   CMD_ARGC+0
            cmp   #2
            bne   :n1
            lda   CMD_ARGV+2
            sta   PTR0
            lda   CMD_ARGV+3
            sta   PTR0+1
            jsr   PARSE_STATUS
            bra   :haven
:n1         lda   #1
:haven      jsr   CS_FINDLOOP
            bcc   :found
            lda   #<NOLOOP_MSG
            ldx   #>NOLOOP_MSG
            jsr   PR_ERRAX1
            sec
            rts

:found      lda   BRK_KIND
            beq   :dobreaknow
*-- `continue` targeting a FOR frame: refused, loudly, rather
*-- than run WHILE/UNTIL's pop-and-reexecute-header logic below,
*-- which assumes re-entering the loop head re-evaluates a
*-- CONDITION (harmless to redo) -- FOR's own head is a fixed,
*-- already-computed word list (docs/SH-FEATURES.md sec 4), and
*-- popping the frame there would discard the iteration state
*-- entirely. Not in this task's required scope (`break` inside
*-- a `for` is; `continue` inside one is not) -- documented v1
*-- gap, not a silent misbehavior.
            lda   CSTYPE,x
            cmp   #4
            bne   :docontinue
            lda   #<CONTFOR_MSG
            ldx   #>CONTFOR_MSG
            jsr   PR_ERRAX1
            sec
            rts
:dobreaknow lda   #1
            sta   CSSKIP,x
            stz   LASTSTATUS
            stz   CSLPSTAT,x             ;SH-CASE2 A: the loop
                                         ;  ends with status 0
            sec
            rts

:docontinue stx   CSN2
            stz   LASTSTATUS             ;before the handoff,
                                         ;  which files it
            jsr   CR_CONTUNW             ;sec 18 -- the frames
                                         ;  this is about to
                                         ;  discard never run
                                         ;  their own DONE
            lda   CSN2
            sta   CSPTR
            jmp   CS_GOHEAD              ;X is still the frame

*-- Reserved-word table -- RESV_LO/HI[i] paired with id i+1
*-- (CHCK_RESERVED's own 1-based RW_ID). Order fixed by
*-- RW_DISPATCH's cmp chain above: IF THEN ELIF ELSE FI WHILE
*-- UNTIL DO DONE FOR (FOR added Tier 2, docs/SH-FEATURES.md
*-- sec 4 -- appended rather than inserted, so every existing id
*-- keeps its number).
*-- RESV_CNT (12): hoisted to sh.s's top block.
RESV_LO     dfb   <IF_STR,<THEN_STR,<ELIF_STR,<ELSE_STR,<FI_STR
            dfb   <WHILE_STR,<UNTIL_STR,<DO_STR,<DONE_STR
            dfb   <FOR_STR,<CASE_STR,<ESAC_STR
            dfb   <LBRACE_STR,<RBRACE_STR
RESV_HI     dfb   >IF_STR,>THEN_STR,>ELIF_STR,>ELSE_STR,>FI_STR
            dfb   >WHILE_STR,>UNTIL_STR,>DO_STR,>DONE_STR
            dfb   >FOR_STR,>CASE_STR,>ESAC_STR
            dfb   >LBRACE_STR,>RBRACE_STR

CASE_STR    asc   "CASE"
            dfb   0
ESAC_STR    asc   "ESAC"
            dfb   0
LBRACE_STR  asc   "{"
            dfb   0
RBRACE_STR  asc   "}"
            dfb   0
*-- `IN` is NOT reserved, for the same reason `for` does not
*-- reserve it: it is only meaningful in one position and
*-- RW_CASE checks it there. Reserving it would break `ECHO IN`.
IN_CASESTR  asc   "IN"
            dfb   0
IF_STR      asc   "IF"
            dfb   0
THEN_STR    asc   "THEN"
            dfb   0
ELIF_STR    asc   "ELIF"
            dfb   0
ELSE_STR    asc   "ELSE"
            dfb   0
FI_STR      asc   "FI"
            dfb   0
WHILE_STR   asc   "WHILE"
            dfb   0
UNTIL_STR   asc   "UNTIL"
            dfb   0
DO_STR      asc   "DO"
            dfb   0
DONE_STR    asc   "DONE"
            dfb   0
FOR_STR     asc   "FOR"
            dfb   0
BREAK_STR   asc   "BREAK"
            dfb   0
CONTINUE_STR
            asc   "CONTINUE"
            dfb   0

CSDEEP_MSG  asc   "sh: construct nesting too deep"
            dfb   $8D,0
CSSYN_MSG   asc   "sh: unexpected then/elif/else/fi/do/done"
            dfb   $8D,0
NOSEEK_MSG  asc   "sh: while/until: stdin not seekable"
            dfb   $8D,0
NOLOOP_MSG  asc   "sh: break/continue: not in a loop"
            dfb   $8D,0
CONTFOR_MSG asc   "sh: continue: not supported in for loops"
            dfb   $8D,0
CSEOF_MSG   asc   "sh: EOF with a construct still open"
            dfb   $8D,0

*-- Construct-stack state (MAXCDEPTH deep) and CHCK_RESERVED/
*-- CHCK_BLTN_BRK scratch.
CSTYPE      ds    MAXCDEPTH    ;1=IF 2=WHILE 3=UNTIL
                               ;4=FOR 5=CASE
CSSKIP      ds    MAXCDEPTH    ;0=execute at this level, 1=skip
CSTAKEN     ds    MAXCDEPTH    ;IF frames only: has a branch
                               ;matched yet
CSCOND      ds    MAXCDEPTH    ;`set -e` (shbltn.s ERREXIT_CK):
                               ;1 while the TOP frame's own
                               ;condition list is still being
                               ;evaluated (IF before its THEN,
                               ;WHILE/UNTIL before its DO) -- a
                               ;failing command there must not
                               ;trigger errexit
CSHEAD      ds    MAXCDEPTH*3  ;WHILE/UNTIL frames only: fd 0
                               ;loop-head mark
CSPTR       ds    1            ;open-frame count (stack depth)
CSTMP       ds    1
CSTMP3      ds    1
CSN         ds    1            ;CS_FINDLOOP's own N countdown
CSN2        ds    1            ;CHCK_BLTN_BRK: target index,
                               ;held across the CSPTR store
LSEEK_BUF   ds    3

RW_ID       ds    1
RW_HASRES   ds    1
BRK_KIND    ds    1            ;0=break 1=continue

LINE_MARK
            ds    3
LMARK_OK
            ds    1

*-- Compound redirection (docs/SH-FEATURES.md sec 18): a `<`/`>`
*-- written after a construct's TERMINATOR applies to the whole
*-- construct. Three bytes per frame, exactly what that ruling
*-- budgeted, plus one PENDING record handed between a scan pass
*-- and the real entry that follows it (and between a loop's
*-- DONE and the fresh frame its own loop-back push creates --
*-- WHILE/UNTIL pop and re-push every iteration, so the frame
*-- itself cannot carry anything across one).
*-- Plain `ds`, not the dum/dend arena, and DELIBERATELY: every
*-- one of these is read before it is written (CR_FIND walks
*-- CSRKIND for frames it did not push; CR_STARTSCAN reads
*-- SCAN_ACT before any scan has ever run), so they depend on
*-- the loader's zero-fill -- which dum/dend does not give.
CSRKIND     ds    MAXCDEPTH    ;0 = none, 1 = `<`, 2 = `>`/`>>`
CSRFD       ds    MAXCDEPTH    ;sh's OWN fd, open for the
                               ;frame's whole life
CSRTGT      ds    MAXCDEPTH    ;kind 2: the CHILD fd it feeds
                               ;(1 for `>`, 2 for `2>`, ...)
SCAN_ACT    ds    1            ;0 = not scanning; else the
                               ;1-based index of the frame whose
                               ;body is being scanned, which is
                               ;CSPTR exactly while that frame
                               ;is the top one
PCR_PEND    ds    1            ;a record is waiting for the next
                               ;construct push to claim
PCR_KIND    ds    1
PCR_FD      ds    1
PCR_TGT     ds    1
CR_JUSTINS  ds    1            ;CR_INSTALL consumed a pending
                               ;record -- CR_STARTSCAN must not
                               ;then scan the same construct
                               ;a second time
CRWANT      ds    1            ;CR_FIND's wanted kind
CRTGT       ds    1            ;CR_FIND's matching CSRTGT
CRTMP       ds    1            ;CR_STARTSCAN: frame index held
                               ;across CS_EFFSKIP (clobbers X)
CRWALK      ds    1            ;CR_CONTUNW's own walk cursor
SEG_FIRST   ds    1            ;this segment is the FIRST on its
                               ;line -- see CR_STARTSCAN
