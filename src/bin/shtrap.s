*---------------------------------------------------------------
* shtrap.s -- the `trap` builtin, the signal-drain PUMP, and the
* exit-trap hook (docs/SIGNALS.md sec 3; the payoff of the
* held-signal kernel that landed 2026-09-02).
*
* THE MODEL. `trap 'cmd' n...` stores cmd and arms signal n as
* CATCH (SC_SIGNAL); the kernel HOLDS a caught signal as pending
* rather than jumping anywhere. Between complete commands the
* shell drains the pending set (SC_SIGPEND) and runs each armed
* signal's stored string through the ORDINARY line engine -- the
* string is copied into LINEBUF and MAINLOOP's own tokenize/
* parse/dispatch runs it, exactly as if typed. No new input
* abstraction, no re-entrant parser: PUMP_TRAP sits at
* MAINLOOP's top, stuffs LINEBUF, and returns "run this, skip
* READLINE". The exit trap runs the same way via SH_RUNLINE.
*
* V7 sh(1) trap shape (commons manual, chunk 558): arg is
* scanned once when set and once when taken; traps run in
* signal-number order; `trap` alone lists; a numeric-first
* operand resets; arg '' ignores; n=0 is the shell's exit trap.
* maux accepts signal NUMBERS and the common NAMES (EXIT INT
* TERM HUP QUIT KILL) -- A12 no-surprises.
*
* STORAGE. TRAPACT[0..15] flags which signals are armed, zeroed
* by SH_INIT_ZR at every spawn (lazy free retains the bank, so
* BSS is not fresh). TRAPTAB is 16 x 256-byte slots holding the
* strings; only an armed slot is ever read, so TRAPTAB itself
* needs no zeroing.
*---------------------------------------------------------------

TRAP_STR    asc   "TRAP"
            dfb   0
TRAPNM_EXIT asc   "EXIT"
            dfb   0
TRAPNM_INT  asc   "INT"
            dfb   0
TRAPNM_TERM asc   "TERM"
            dfb   0
TRAPNM_HUP  asc   "HUP"
            dfb   0
TRAPNM_QUIT asc   "QUIT"
            dfb   0
TRAPNM_KILL asc   "KILL"
            dfb   0
TRAPBAD_MSG asc   "trap: bad signal"
            dfb   $8D,0
TRAPLPFX    asc   "trap -- '"
            dfb   0
TRAPLSFX    asc   "' "
            dfb   0
*---------------------------------------------------------------
* MOVED 2026-09-16 to src/bin/shsgtrp.s -- the `trap` builtin
* now lives in sh's SECOND CODE SEGMENT at $E000+ (docs/
* SH-SUBSET.md ruling 7.6). The strings stayed here: a segment
* address cannot be handed to a syscall (see the header of
* shsgtrp.s).
*---------------------------------------------------------------


*---------------------------------------------------------------
* SIG_RETRY -- the ONE answer to "a blocking call came back
* ERR_INTR" (RULINGS-1 round 2, G1 + G2). The kernel fails a
* blocking call out with ERR_INTR whenever a CAUGHT signal is
* pending, and an interactive sh catches TERM with no armed
* trap (shlex.s START). That pending TERM is not an
* interruption: it has to be dropped and the call retried, or
* the byte read at the idle prompt reads ERR_INTR as EOF and
* the shell EXITS, FG_WAIT abandons the foreground job, and
* `wait` marks every job Done. Only a signal with a USER TRAP
* (TRAPACT set) interrupts.
*
* IN: A = the error the call returned. OUT: carry CLEAR = retry
* the same call (it was ERR_INTR and every pending signal was
* untrapped and is gone, or a trapped one waits inside a
* construct, where it must not run: PUMP_TRAP defers there
* too). Carry SET = a real interruption, as before: some other
* error, nothing pending, or a trapped signal now parked in
* TRAP_HELD/TRAP_PEND for PUMP_TRAP (a flag per signal and a
* count, drained lowest first; a repeat of a parked number
* merges -- signals are bits). TAB-A2's editor has its own
* ERR_INTR path (ED_SIG, shedit.s): INT and TSTP are always
* interruptions there, so it pops for itself and shares only
* the judging, SIG_PARK below.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*---------------------------------------------------------------
* SIG_PARK -- X = a popped signo. If a user trap is armed for it
* (TRAPACT set), park it for PUMP_TRAP: TRAP_HELD[X] := 1 and
* TRAP_PEND counts it, once however often it repeats. OUT: carry
* SET = trapped (parked, or already parked); carry CLEAR =
* untrapped, dropped. Preserves X. The one place a popped signal
* is judged: SIG_RETRY's loop and TAB-A2's editor (ED_SIG) both
* call it. CLOBBERS: A.
*---------------------------------------------------------------
SIG_PARK    lda   TRAPACT,x
            beq   :no
            lda   TRAP_HELD,x
            bne   :yes                   ;parked already
            lda   #1
            sta   TRAP_HELD,x
            inc   TRAP_PEND
:yes        sec
            rts
:no         clc
            rts

SIG_RETRY   cmp   #ERR_INTR
            bne   :real
            jsr   SC_SIGPEND
            cmp   #0
            beq   :real                  ;nothing held: not ours
:judge      tax
            jsr   SIG_PARK               ;untrapped: dropped
:next       jsr   SC_SIGPEND
            cmp   #0
            bne   :judge
            lda   TRAP_PEND
            beq   :again                 ;all untrapped: retry
            lda   CSPTR
            bne   :again                 ;a construct is open
:real       sec
            rts
:again      clc
            rts

*---------------------------------------------------------------
* PUMP_TRAP -- MAINLOOP's top hook. Carry SET = a trap's
* string is now in LINEBUF (run it, skip READLINE); carry CLEAR
* = nothing pending, proceed to the prompt. Deferred while a
* construct is open (CSPTR != 0): draining mid-`if` would run
* the trap in the wrong frame. SC_SIGPEND pops the LOWEST
* pending signo, which is V7 trap's signal-number order.
*---------------------------------------------------------------
PUMP_TRAP
            lda   TRAPSV_D            ;SH-CASE2 B H1: put back a
            beq   :nosv                ;  hand-off hidden from a
            dec   a                     ;  trap, once its string
            cmp   SRC_DEPTH           ;  (and any spool it made)
            bne   :nosv                  ;  is done: back at the
            lda   TRAPSV_LP              ;  source depth it was
            sta   LP_PEND                ;  hidden at
            inc   PCR_PEND               ;(0 here)
            stz   TRAPSV_D
:nosv       lda   CSPTR
            bne   :nopump
            lda   TRAP_PEND              ;SIG_RETRY parked some:
            beq   :fetch                 ;they come first,
            ldx   #1                     ;lowest number first
:scanh      lda   TRAP_HELD,x
            bne   :takeh
            inx
            bra   :scanh
:takeh      stz   TRAP_HELD,x
            dec   TRAP_PEND
            txa
            bra   :have
:fetch      jsr   SC_SIGPEND
            cmp   #0
            beq   :nopump
:have       sta   TRAP_SIG
            tax
            lda   TRAPACT,x
            beq   :nopump                ;caught, not armed --
                                         ;the pop drained it,
                                         ;which is correct
            jsr   TRAP_SLOT_P1           ;PTR1 = the string
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            ldy   #0
:pcp        lda   (PTR0),y
            sta   LINEBUF,y
            beq   :pcpd
            iny
            bne   :pcp
:pcpd       sty   LINELEN
            lda   PCR_PEND              ;a loop-back is pending:
            beq   :nohide              ;  hide it from the trap,
            lda   LP_PEND                ;  whose own constructs
            sta   TRAPSV_LP              ;  would claim it
            lda   SRC_DEPTH
            inc   a
            sta   TRAPSV_D
            stz   PCR_PEND
            stz   LP_PEND
:nohide     sec
            rts
:nopump     clc
            rts

*---------------------------------------------------------------
* SH_EXIT -- every shell exit path routes here (A = status),
* `exit` (CHCK_BLTN_EXT, shparse.s) and real top-level EOF
* (SH_EOF's `:realeof`, shlex.s) alike. If the exit trap (signal
* 0) is armed, disarm it, stuff its string into LINEBUF, and
* hand it to the engine via SH_RUNLINE with SH_EXITING set:
* MAINLOOP's top sees SH_EXITING after the line runs and does
* the real EXIT. If no exit trap, exit straight away. Disarm-
* before-run means `exit` inside the trap cannot recurse into
* it.
*
* Console-loop spooling (docs/SH-FEATURES.md, 2026-09-15):
* `exit` from INSIDE a spooled loop's body never reaches SH_
* EOF's own pop-time unlink (shlex.s) -- the process is leaving,
* not popping SRC_STACK -- so it is done here instead, once,
* before anything else: if a spool file is still open (SH_
* SPOOL_LVL nonzero, any nesting depth), close and unlink it.
* `kill -9` bypasses this shell entirely and stays a named gap.
*---------------------------------------------------------------
SH_EXIT     sta   SH_EXITST
            lda   SH_SPOOL_LVL
            beq   :noleak
            stz   SH_SPOOL_LVL
            lda   SPOOL_FD
            jsr   CLOSE_FD_A
            jsr   SPOOL_UNLINK
:noleak     lda   TRAPACT+0
            beq   :now
            lda   #0
            sta   TRAPACT+0
            lda   #1
            sta   SH_EXITING
            lda   #0
            sta   TRAP_SIG               ;slot 0
            jsr   TRAP_SLOT_P1
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            ldy   #0
:xcp        lda   (PTR0),y
            sta   LINEBUF,y
            beq   :xcpd
            iny
            bne   :xcp
:xcpd       sty   LINELEN
            jmp   SH_RUNSTR              ;SH-EXECLOOP: a string
:now        lda   SH_EXITST
            jsr   EXIT

*---------------------------------------------------------------
* CONSOLE-LOOP SPOOLING lives HERE, in shtrap.s, not shbltn.s
* where its callers (RW_WHILE/RW_LOOP_PUSH, shresv.s; RW_FOR,
* shvar2.s) would suggest -- PLACEMENT, not logic, and
* specifically NOT shjob.s (tried first, reverted): shjob.s is
* ALREADY the single largest `put` file in this manifest
* (check_dialect.py's real-Merlin-8 41215-byte source-buffer
* budget binds on the WORST put file, not a sum), so landing
* here instead pushed sh.s over that ceiling -- shtrap.s has far
* more headroom. Putting it after shpath.s (this file's own
* `put` position) ALSO keeps its size off VNBUF's own address
* (shpath.s, EMITVAR's scratch), which check_shwarm.py's span
* check already measured within a dozen bytes of $4000/ANNX_
* DHR_PG2 (mm.annex2.equ) before this code even existed
* (docs/SH-FEATURES.md sec 21's own "narrow capacity finding").
* Everything below is called ONLY by `jmp`/`jsr` to a plain code
* label, which resolves regardless of `put` order -- moving it
* here changes no behavior, only where its bytes land.
*---------------------------------------------------------------
*---------------------------------------------------------------
* SPOOL_ENTER -- console-loop spooling (docs/SH-FEATURES.md,
* 2026-09-15). RW_WHILE/RW_LOOP_PUSH (shresv.s) and RW_FOR
* (shvar2.s) jmp here instead of pushing a frame when their
* construct is LIVE but CUR_IN_FD is not seekable (LMARK_OK 0 --
* a tty or a $( ) pipe): RW_DONE/RW_DONE_FOR's own seek-back
* could never replay such a body. Copies the WHOLE construct --
* from RW_HEADPTR (CHCK_RESERVED's own capture, shparse.s,
* BEFORE RW_SHIFT dropped it) through its matching DONE, however
* many more lines that takes -- into a per-process temp file
* (SPOOL_NAME, ex's own EX.SWPxx naming/directory precedent,
* exbuf.s), then sources it exactly like `.` (CHCK_BLTN_DOT,
* above): CUR_IN_FD becomes the temp file, which CAN seek, so
* every existing seek-based mechanism -- nested loops, break/
* continue, here-docs, variable persistence -- runs completely
* unmodified on replay, because it is the SAME shell, not a
* child.
*
* SPOOL_SPLIT (below) writes each `;`-separated SEGMENT of a
* spooled line as its OWN LINE in the temp file, and ALSO splits
* a `DO` with a residual body onto its own line -- never as one
* physical line joined by `;`/a bare space. This is not
* cosmetic: a compound-redirect scan pass (sec 18's
* CR_STARTSCAN) captures CSHEAD at the START of whatever
* physical line a construct's head is on, which assumes the
* multi-line shape every existing script already uses. Splitting
* turns ANY one-liner into that shape before it is replayed, so
* the ordinary, already-proven seek machinery is what runs it.
* (Until SH-EXECLOOP this was also load-bearing for FOR:
* RW_DO_FOR refused a `DO` that was not the last thing on its
* line, with a diagnostic that printed through a PTR0 whose high
* byte was never set. RW_DO_FOR now takes `do CMD` itself --
* its replay coordinate is the line's start mark plus the DO
* segment's index -- and the refusal is gone; the split stays
* because it is harmless and the scan pass still wants it.)
*
* The head line spools from RAWLINE (sh.s), a pristine copy of
* LINEBUF taken by SH_RUNLINE (shlex.s) before STRIPCOMMENT/
* TOKENIZE mutate LINEBUF's own bytes -- real quotes and spaces,
* not TOKENIZE's NUL-for-separator rewrite. SPOOL_HOFS is
* RW_HEADPTR translated into an offset into RAWLINE (both point
* into the SAME physical line, so the offset is exact) -- UNLESS
* a quote precedes the head on that line (`X="a b" ; FOR ...`):
* TOKENIZE's own quote squeeze (sec 18) shifts bytes left in
* LINEBUF for exactly that reason, and RW_HEADPTR is an address
* INTO THE SHIFTED LINEBUF, not an offset RAWLINE shares. Rather
* than spool shifted text, SPOOL_ENTER scans RAWLINE[0..SPOOL_
* HOFS) for a quote mark and REFUSES the whole construct loudly
* (SPOOL_QUOTED, below) if it finds one -- the one shape this
* feature does not spool. Once inside the head (SPOOL_HOFS
* onward) and on every later line, SPOOL_SPLIT (below) is fully
* quote-aware, so quoting the LOOP'S OWN words/body works fine;
* only text quoted BEFORE the loop on its own line is refused.
*
* Depth tracked by SPOOL_SPLIT over EVERY segment, head line
* included -- a one-liner's own trailing DONE closes it without
* reading anything more. Reuses RESV_LO/HI (CHCK_RESERVED's own
* table, shparse.s) so no new keyword list is spent; IF/THEN/
* ELIF/ELSE/FI are correctly invisible to it, the same free ride
* sec 18's own scan pass gets from a `case` pattern -- they nest
* on the construct stack once the real pass re-parses this text.
*
* OUT: never returns on success (`jmp MAINLOOP`, `.`'s own
* shape). On any failure: diagnostic, LASTSTATUS=1, `rts` --
* WITHOUT pushing a frame, since both callers intercept BEFORE
* touching CSPTR. CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
*-- SH-EXECLOOP (review): ONE spool at a time. SH_SPOOL_LVL is
*-- nonzero while a spooled loop is being read; a string loop
*-- (eval, a trap) starting now would re-create the file under
*-- it (the name and SPOOL_FD are global). Refuse before
*-- touching anything.
SPOOL_ENTER lda   SH_SPOOL_LVL
            beq   :spidle
            jmp   SPOOL_DEEP
:spidle     lda   SRC_DEPTH
            cmp   #SRC_MAXDEPTH
            bcc   :spdepth
            jmp   SPOOL_DEEP
*-- SPOOL_HOFS = RW_HEADPTR - LINEBUF, an 8-bit subtraction that
*-- is exact even across a page boundary as long as the TRUE
*-- difference fits a byte (it always does -- LINEMAX is 255).
:spdepth    sec
            lda   RW_HEADPTR
            sbc   #<LINEBUF
            sta   SPOOL_HOFS
*-- An alias expanded at or before the head shifted LINEBUF away
*-- from RAWLINE, so SPOOL_HOFS no longer indexes it: refuse.
            cmp   ALI_MINPOS
            bcc   :spalok
            lda   #<ALI_SPL_M
            ldx   #>ALI_SPL_M
            jmp   PR_ERRAX1M             ;C: abandon line
:spalok     ldy   #0
:spqbchk    cpy   SPOOL_HOFS
            beq   :spqbok
            lda   RAWLINE,y
            cmp   #$A7                   ;''' high-bit-set
            beq   :spquotd
            cmp   #$A2                   ;'"' high-bit-set
            beq   :spquotd
            cmp   #ALC_DC                ;'\' too: an escape was
            beq   :spquotd           ;  squeezed out of LINEBUF,
            iny                         ;  so the head offset is
            bra   :spqbchk               ;  off (SH-CASE2 B H3)
:spquotd    jmp   SPOOL_QUOTED
:spqbok     jsr   SPOOL_MKNAME
            lda   #<SPOOL_NAME
            sta   PTR0
            lda   #>SPOOL_NAME
            sta   PTR0+1
            jsr   OPEN_REDIR_WR
            bcc   :spopn2
            jmp   SPOOL_OPENERR
:spopn2     jsr   OPEN_HI                ;see shpath.s
            sta   SPOOL_FD
            stz   SPOOL_NEST
            lda   #<RAWLINE
            clc
            adc   SPOOL_HOFS
            sta   PTR0
            lda   #>RAWLINE
            adc   #0
            sta   PTR0+1
            jsr   SPOOL_SPLIT
            bcc   :spmore
            jmp   SPOOL_IOERR
*-- read more lines while a construct is still open
:spmore     lda   SPOOL_NEST
            bne   :spcont
            jmp   SPOOL_DONE
:spcont     lda   STR_SRC                ;a string ends with its
            beq   :spnostr               ;  text: never read the
            jmp   SPOOL_STREOF           ;  caller's lines
:spnostr    jsr   RL_PS2                 ;`> ` (shsgmlq.s): the
                                         ;same prompt a quote
                                         ;continuation shows
:spnopr     jsr   READLINE
            bcc   :sphavln
            jmp   SPOOL_EOF
:sphavln    lda   #<LINEBUF
            sta   PTR0
            lda   #>LINEBUF
            sta   PTR0+1
            jsr   SPOOL_SPLIT
            bcc   :spmore
            jmp   SPOOL_IOERR

*---------------------------------------------------------------
* SPOOL_DONE -- spooling finished (SPOOL_NEST back to 0):
* rewind, push CUR_IN_FD like `.` does (CHCK_BLTN_DOT, above),
* switch to the spool file. Never returns.
* CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
SPOOL_DONE  stz   SPOOL_SEEK
            stz   SPOOL_SEEK+1
            stz   SPOOL_SEEK+2
            lda   #<SPOOL_SEEK
            sta   PTR0
            lda   #>SPOOL_SEEK
            sta   PTR0+1
            lda   SPOOL_FD
            ldy   #SEEK_SET
            jsr   LSEEK
            bcc   :spseekok
            jmp   SPOOL_IOERR
:spseekok   ldx   SRC_DEPTH
            lda   CUR_IN_FD
            sta   SRC_STACK,x
            inc   SRC_DEPTH
            lda   SRC_DEPTH
            sta   SH_SPOOL_LVL
            lda   SPOOL_FD
            sta   CUR_IN_FD
            jmp   MAINLOOP

*---------------------------------------------------------------
* SPOOL_DEEP/SPOOL_QUOTED/SPOOL_OPENERR/SPOOL_IOERR/SPOOL_EOF --
* spooling failed: diagnostic, LASTSTATUS=1, `jmp MAINLOOP` --
* same shape RW_FORSYNERR/RW_OVERFLOW/RW_SYNTAXERR already use
* to ABANDON THE REST OF THE LINE, not `rts`: no frame was ever
* pushed (both callers intercept before touching CSPTR), so
* RW_SHIFT's own residual (e.g. "I IN CC" once "FOR" is shifted
* off) is still sitting in CMD_ARGV with RW_HASRES=1 and NOTHING
* pushed to make the skip-gate catch it -- an `rts` here let
* MAINLOOP's normal dispatch chain run that residual as an
* ordinary command ("sh: command not found"), found testing
* SPOOL_QUOTED. DEEP/QUOTED/OPENERR never created a file at
* all; IOERR/EOF close and unlink the temp file so far.
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
SPOOL_DEEP  lda   #<SPLDEEP_MSG
            ldx   #>SPLDEEP_MSG
            jmp   PR_ERRAX1M
SPOOL_QUOTED
            lda   #<SPLQUOT_MSG
            ldx   #>SPLQUOT_MSG
            jmp   PR_ERRAX1M
SPOOL_OPENERR
            lda   #<SPLOPEN_MSG
            ldx   #>SPLOPEN_MSG
            jmp   PR_ERRAX1M
SPOOL_IOERR lda   #<SPLIO_MSG
            ldx   #>SPLIO_MSG
            jsr   PR_ERRAX
            bra   SPOOL_FAILUNL
SPOOL_EOF   lda   #<CSEOF_MSG
            ldx   #>CSEOF_MSG
            jsr   PR_ERRAX
SPOOL_FAILUNL
            lda   #1
*-- SPOOL_TAIL -- IN: A = the status. Close and unlink the
*-- spool, carry on with the caller's next line. Neither the
*-- close nor the unlink reads or writes LASTSTATUS, so it is
*-- stored first.
SPOOL_TAIL  sta   LASTSTATUS
            lda   SPOOL_FD
            jsr   CLOSE_FD_A
            jsr   SPOOL_UNLINK
            jmp   MAINLOOP

*-- SPOOL_STREOF -- an eval/trap string whose loop is still open
*-- at the end of its text: refuse, status 2 (bash's, for eval),
*-- unlink the spool, carry on with the caller's next line.
SPOOL_STREOF
            lda   #<CSEOF_MSG
            ldx   #>CSEOF_MSG
            jsr   PR_ERRAX
            lda   #2
            bra   SPOOL_TAIL

SPLDEEP_MSG asc   "sh: for/while: too many nested sources"
            dfb   $8D,0
SPLQUOT_MSG asc   "sh: for/while: quoted text before the loop"
            dfb   $8D,0
SPLOPEN_MSG asc   "sh: for/while: cannot open spool file"
            dfb   $8D,0
SPLIO_MSG   asc   "sh: for/while: spool write failed"
            dfb   $8D,0

*---------------------------------------------------------------
* SPOOL_SPLIT -- IN: PTR0 = a NUL-terminated line, real ASCII
* separators ($A0 space, $BB ';', $A7/$A2 quotes, high-bit-set).
* Splits it on `;` into its segments and writes EACH ONE as its
* OWN LINE (its own trailing CR) to SPOOL_FD -- see SPOOL_
* ENTER's own header for why a one-liner must become multi-line,
* `DO` included (SPOOL_DOSPLIT, below). Also checks ONLY each
* segment's OWN leading word against RESV_LO/HI (CHCK_RESERVED's
* own table, shparse.s) to adjust SPOOL_NEST -- FOR/WHILE/UNTIL/
* CASE open, DONE/ESAC close -- an embedded `ECHO DONE` is never
* mistaken for one, since only the FIRST word of a segment is
* ever compared, and a segment that STARTS with a quote is never
* even checked (a keyword is never quoted).
*
* QUOTE-AWARE (SPOOL_QST, one line's worth of state, sh.s): a
* `;` seen while SPOOL_QST is nonzero is ordinary text, not a
* segment boundary -- `ECHO 'S;$I'` spools as ONE line. Tracked
* from the point a segment's scan reaches it onward; a segment
* that OPENS a quote closes it before this routine returns to
* `;`/NUL scanning, the same rule real shell quoting always has.
* An escaped `"` (`\"`) inside a DOUBLE-quoted span does NOT
* close it (2026-09-15, consistency with TOKENIZE's own POSIX
* 2.2.3 rule -- shtok.s :qloop2, docs/SH-FEATURES.md sec 23) --
* a segment like `ECHO "a\;b"` keeps its `;` inside the quote.
* Single-quoted spans have no such escape, unchanged: a bare
* `\'` there is still two ordinary bytes, not an escape.
* v1 LIMITATION: splits on `;` only, not `&&`/`||` -- an idiom
* that opens a loop right after one of those is not in this tree
* and is not detected.
* OUT: carry set on any write failure. Consumes PTR0.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2.
*---------------------------------------------------------------
SPOOL_SPLIT stz   SPOOL_CUR
            stz   SPOOL_QST
:splseg     ldy   SPOOL_CUR
            lda   (PTR0),y
            bne   :splchk
            clc
            rts
:splchk     cmp   #$A0
            bne   :splqst
            inc   SPOOL_CUR
            bra   :splseg
*-- a segment whose FIRST byte is a quote mark -- no leading
*-- word to check (SPOOL_ENTER's own header explains why).
:splqst     cmp   #$A7
            beq   :splqs
            cmp   #$A2
            bne   :splword
:splqs      lda   SPOOL_CUR
            sta   SPOOL_SEGST
            jmp   :splrest
:splword    lda   SPOOL_CUR
            sta   SPOOL_SEGST
            stz   SPOOL_TRUNC
            ldx   #0
:splwcp     ldy   SPOOL_CUR
            lda   (PTR0),y
            beq   :splwend
            cmp   #$A0
            beq   :splwend
            cmp   #OPC_SEMI
            beq   :splwend
            cpx   #5
            bcc   :splwst
            inc   SPOOL_TRUNC
            bra   :splwsk
:splwst     sta   SPOOL_WBUF,x
            inx
:splwsk     inc   SPOOL_CUR
            bra   :splwcp
:splwend    stz   SPOOL_WBUF,x
            lda   SPOOL_TRUNC
            bne   :splrest
            lda   PTR0
            pha
            lda   PTR0+1
            pha
            lda   #<SPOOL_WBUF
            sta   PTR0
            lda   #>SPOOL_WBUF
            sta   PTR0+1
            jsr   SPOOL_KWID
            sta   SPOOL_ID
            pla
            sta   PTR0+1
            pla
            sta   PTR0
            jsr   SPOOL_ADJNEST
            lda   SPOOL_ID
            cmp   #8
            bne   :splrest
*-- `DO` (id 8): if content follows in THIS segment, split it
*-- onto its own line and re-scan the rest as a fresh one (its
*-- own leading word gets checked too -- SPOOL_ENTER's header).
            ldy   SPOOL_CUR
            lda   (PTR0),y
            beq   :splrest
            cmp   #OPC_SEMI
            beq   :splrest
            jsr   SPOOL_DOSPLIT
            bcc   :splword
            sec
            rts
*-- quote-aware scan to the end of THIS segment -- an unquoted
*-- ';' or NUL ends it; a quote mark toggles SPOOL_QST; anything
*-- else, quoted or not, is just consumed.
*-- SPOOL_QST holds 0 (bare) or the CLOSING quote character
*-- itself ($A7/$A2) -- one compare closes either kind, and the
*-- SAME byte just matched (A unchanged by CMP) is what OPENS
*-- one, so :splropen below stores it verbatim for both.
:splrest    ldy   SPOOL_CUR
            lda   (PTR0),y
            beq   :splwr             ;NUL always ends, quoted
                                     ;or not (an unterminated
                                     ;quote is not this v1's
                                     ;problem to diagnose)
            ldx   SPOOL_QST
            beq   :splrunq
*-- an escaped '"' inside a double-quoted span is content, not
*-- the close (consistency with TOKENIZE's own POSIX 2.2.3 rule,
*-- shtok.s :qloop2) -- skip BOTH bytes, no toggle.
            cpx   #$A2
            bne   :splrq
            cmp   #$DC                   ;'\' high-bit-set
            bne   :splrq
            iny
            lda   (PTR0),y
            cmp   #$A2
            bne   :splrq2
            inc   SPOOL_CUR
            inc   SPOOL_CUR
            bra   :splrest
:splrq2     dey
            lda   (PTR0),y               ;A = the '\' itself
:splrq      cmp   SPOOL_QST
            bne   :splrnxt
            stz   SPOOL_QST
            bra   :splrnxt
:splrunq    cmp   #$BB
            beq   :splwr             ;unquoted ';' -- real end
            cmp   #$A7
            beq   :splropen
            cmp   #$A2
            bne   :splrnxt
:splropen   sta   SPOOL_QST
:splrnxt    inc   SPOOL_CUR
            bra   :splrest
:splwr      pha
            cmp   #OPC_SEMI
            bne   :splw1
            ldy   SPOOL_CUR
            iny
            lda   (PTR0),y
            cmp   #OPC_SEMI
            bne   :splw1
            inc   SPOOL_CUR          ;`;;` closes a case branch:
            inc   SPOOL_CUR              ;  the line keeps both
            pla                          ;  (SH-CASE2 B M4)
            lda   #1                    ;1 = CUR is already past
            pha                          ;  the terminator
:splw1      jsr   SPOOL_WRSEG
            bcc   :splwrok
            pla
            sec
            rts
:splwrok    pla
            beq   :spldone
            cmp   #1
            beq   :splgo
            inc   SPOOL_CUR
:splgo      jmp   :splseg
:spldone    clc
            rts

*---------------------------------------------------------------
* SPOOL_DOSPLIT -- IN: SPOOL_SEGST = the start of the `DO` word
* just scanned, SPOOL_CUR = right after it (the caller has
* already proven the next byte is not ';'/NUL -- a real space).
* Writes `DO` alone as its own spool-file line, then skips the
* separating space(s) and resets SPOOL_SEGST to where the
* residual begins, ready for the caller to re-scan it as a fresh
* segment. Unconditional -- harmless for WHILE/UNTIL, whose own
* DO carries no such rule, and for FOR since SH-EXECLOOP (it was
* required while RW_DO_FOR refused `do CMD`; see SPOOL_ENTER's
* header).
* OUT: carry set on a write failure. CLOBBERS: A, X, Y, PTR2.
*---------------------------------------------------------------
SPOOL_DOSPLIT
            jsr   SPOOL_WRSEG
            bcs   :spdsfail
:spdsskip   ldy   SPOOL_CUR
            lda   (PTR0),y
            cmp   #$A0
            bne   :spdsdone
            inc   SPOOL_CUR
            bra   :spdsskip
:spdsdone   lda   SPOOL_CUR
            sta   SPOOL_SEGST
            clc
            rts
:spdsfail   sec
            rts

*---------------------------------------------------------------
* SPOOL_WRSEG -- IN: PTR0 = line base, SPOOL_SEGST/SPOOL_CUR =
* the [start,end) offsets (relative to PTR0) of the segment to
* write. Computes PTR2/SPOOL_LEN and tail-calls SPOOL_WRLINE --
* SPOOL_SPLIT's own `:splwr` and SPOOL_DOSPLIT share this rather
* than each carrying its own copy of the offset arithmetic.
* OUT: carry set on any write failure. CLOBBERS: A, X.
*---------------------------------------------------------------
SPOOL_WRSEG sec
            lda   SPOOL_CUR
            sbc   SPOOL_SEGST
            sta   SPOOL_LEN
            clc
            lda   PTR0
            adc   SPOOL_SEGST
            sta   PTR2
            lda   PTR0+1
            adc   #0
            sta   PTR2+1
            jmp   SPOOL_WRLINE
*---------------------------------------------------------------
* SPOOL_ADJNEST -- IN: SPOOL_ID (0, or CHCK_RESERVED's own 1-14
* id, shparse.s). WHILE/UNTIL/FOR/CASE (6,7,10,11) open;
* DONE/ESAC (9,12) close, clamped at 0 -- an extra DONE never
* wraps negative; the real pass, replaying this text, is what
* actually diagnoses that. `{`/`}` (13,14, docs/SH-FEATURES.md
* 2026-09-15) open/close the SAME way -- unlike IF/FI, which
* stay invisible on purpose (sec 21's own note), a brace group
* needs the counter's help too: it is the thing SPOOLING when
* typed bare at the console (RW_BRACE's own SPOOL_ENTER jump),
* and net-zero when merely nested inside an outer spooled loop.
* CLOBBERS: A.
*---------------------------------------------------------------
SPOOL_ADJNEST
            lda   SPOOL_ID
            cmp   #6
            beq   :spopen
            cmp   #7
            beq   :spopen
            cmp   #10
            beq   :spopen
            cmp   #11
            beq   :spopen
            cmp   #13
            beq   :spopen
            cmp   #9
            beq   :spclose
            cmp   #12
            beq   :spclose
            cmp   #14
            beq   :spclose
            rts
:spopen     inc   SPOOL_NEST
            rts
:spclose    lda   SPOOL_NEST
            beq   :spzero
            dec   SPOOL_NEST
:spzero     rts

*---------------------------------------------------------------
* SPOOL_KWID -- IN: PTR0 = a NUL-terminated candidate word.
* OUT: A = CHCK_RESERVED's own RW_ID (shparse.s -- 1-14) if it
* matches one of the 14 reserved words, 0 otherwise. Reuses
* RESV_LO/HI/RESV_CNT verbatim -- CHCK_RESERVED's own loop body,
* without RW_SHIFT/CR_TRYCAP/RW_DISPATCH's side effects.
* CLOBBERS: A, X, PTR1.
*---------------------------------------------------------------
SPOOL_KWID  ldx   #0
:sploop2    cpx   #RESV_CNT
            bne   :sptry
            lda   #0
            rts
:sptry      lda   RESV_LO,x
            sta   PTR1
            lda   RESV_HI,x
            sta   PTR1+1
            jsr   STRCMPI
            beq   :spfound2
            inx
            bra   :sploop2
:spfound2   inx
            txa
            rts

*---------------------------------------------------------------
* SPOOL_MKNAME -- fill SPOOL_NAME with "/tmp/SH.SPLxx" (xx = 2
* hex digits of BANK_ID) -- ex's own EX.SWPxx naming (exbuf.s
* EX_SW_ENSURE) in the one directory a file can always be made
* in. It used to be a bare name for MKPATH to place in the cwd,
* and at a cwd of `/`, `/dev` or `/mnt` -- kernel-owned
* directories that refuse a create -- every `for`/`while` typed
* there printed "sh: for/while: cannot open spool file"
* (KFIX3 item 5). /tmp is the virtual root's own (VROOT.md) and
* BANK_ID is unique among live processes, so two shells cannot
* collide in it. Only one spool file is ever open per process
* (a spooled loop's own body runs from a now-seekable fd, so it
* never re-spools), so one deterministic name is enough -- no
* nesting suffix needed.
* CLOBBERS: A, Y.
*---------------------------------------------------------------
SPOOL_MKNAME
            ldy   #0
:spcplit    lda   SPOOLLIT,y
            sta   SPOOL_NAME,y
            iny
            cpy   #11
            bne   :spcplit
            lda   BANK_ID
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            jsr   SPOOL_HEX
            sta   SPOOL_NAME+11
            lda   BANK_ID
            and   #$0F
            jsr   SPOOL_HEX
            sta   SPOOL_NAME+12
            stz   SPOOL_NAME+13
            rts

SPOOLLIT    asc   "/tmp/SH.SPL"

*---------------------------------------------------------------
* SPOOL_HEX -- IN: A (low nibble). OUT: A = that nibble as a
* high-bit-ASCII hex digit, uppercase (ex's own EX_HEXCH,
* exbuf.s -- not shared code across binaries in this tree, so a
* second small copy rather than a cross-program call).
*---------------------------------------------------------------
SPOOL_HEX   and   #$0F
            cmp   #10
            bcc   :sphdig
            sec
            sbc   #10
            clc
            adc   #$C1
            rts
:sphdig     ora   #$B0
            rts

*---------------------------------------------------------------
* SPOOL_WRLINE -- IN: PTR2 = line start, SPOOL_LEN = byte count
* (0-255). PTR2, not PTR0/PTR1 -- SPOOL_SPLIT's own callers keep
* PTR0 live as their line-scan base throughout. Writes the
* content then one CR ($8D) to SPOOL_FD -- byte-identical to
* what ED_BUMP_ALLOC/`w` already write (exbuf.s), so a script
* this project already reads can read a spooled one too.
* OUT: carry set on any write failure. CLOBBERS: A, X.
*---------------------------------------------------------------
SPOOL_WRLINE
            lda   PTR2
            sta   SWR_BUF
            lda   PTR2+1
            sta   SWR_BUF+1
            lda   SPOOL_LEN
            sta   SWR_REQ
            stz   SWR_REQ+1
            lda   SPOOL_FD
            sta   SWR_REF
            lda   #<SWR_PARM
            ldx   #>SWR_PARM
            jsr   SC_WRITE
            bcs   :spwrfl
            lda   SPOOL_FD
            sta   SWRC_REF
            lda   #<SWRC_PARM
            ldx   #>SWRC_PARM
            jsr   SC_WRITE
            bcs   :spwrfl
            clc
            rts
:spwrfl     sec
            rts

SWR_PARM    dfb   PCOUNT_WRITE
SWR_REF     dfb   0
SWR_BUF     da    0
SWR_REQ     da    0
SWR_TRN     da    0

SWRCRBYTE   dfb   $8D
SWRC_PARM   dfb   PCOUNT_WRITE
SWRC_REF    dfb   0
SWRC_BUF    da    SWRCRBYTE
SWRC_REQ    da    1
SWRC_TRN    da    0

*---------------------------------------------------------------
* SPOOL_UNLINK -- best-effort UNLINK of SPOOL_NAME (SPOOL_MKNAME
* must have built it already), same posture as ED_QCLEANUP's own
* SC_UNLINK (exbuf.s) -- the carry is not even checked.
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
SPOOL_UNLINK
            lda   #<SPOOL_NAME
            sta   PTR0
            lda   #>SPOOL_NAME
            sta   PTR0+1
            lda   #<SH_PATHBUF
            sta   PTR1
            lda   #>SH_PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<SPLUNLPARM
            ldx   #>SPLUNLPARM
            jmp   SC_UNLINK

SPLUNLPARM  dfb   PCNT_DESTROY
SPLUNLPATH  da    SH_PATHBUF
