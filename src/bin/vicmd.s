*---------------------------------------------------------------
* vicmd.s -- vi's top-level command loop (docs/VI-DESIGN.md sec
* 3.1/3.2/4.1). `put` by vi.s LAST -- ties viscreen.s/
* vimotion.s/viinsert.s together with the four shared-module
* hooks. Owns:
* process entry (VI_START), the raw single-key read helper
* (VI_RAWKEY, shared with viinsert.s), the command-mode dispatch
* (VI_LOOP), the `:` bridge (VI_COLON -> ED_DISPATCH1), `ZZ`
* (VI_ZZ -> EX_XCORE), `u` (VI_UNDO_KEY -> EX_UNDO_CORE), ^C
* handling, and EX_ONQUIT's REAL body (the no-op stub lives in
* ex.s; this is vi's own tty-mode restore).
*---------------------------------------------------------------

VI_RAWMODE  equ   TMD_OPOST     ;SC_TTYMODE newflags: ICANON/
                                ;ECHO clear (cbreak+noecho --
                                ;stty.s's own "stty raw -echo"),
                                ;OPOST stays SET -- vi wants raw
                                ;input, but CR is still ITS OWN
                                ;newline on output (VT102
                                ;slice 1, CONSOLE-VT102.md sec
                                ;3): vi's own $8D-terminated
                                ;writes must still advance a
                                ;line
* VI_SIGINT / VI_SIGTSTP moved to vi.s (beside VI_KLEFT):
* vimotion.s (put BEFORE this file) uses VI_SIGTSTP now, and a
* same-tree forward `equ` is an "Illegal forward reference" on
* real Merlin-8 (check_equ_fwd, 2026-09-10).

*---------------------------------------------------------------
* EX_ONQUIT -- vi's REAL body (docs/VI-DESIGN.md sec 5 item 3).
* excmd.s's EX_CQBANG/EX_CWQ/EX_XCORE call this unconditionally
* right before EXIT; ex.s's own copy is a no-op stub. Restores
* the tty mode vi replaced at entry -- belt to the kernel's own
* PRC_TMD_RST crash-safety backstop's suspenders. CLOBBERS: A,
* X, Y (SC_TTYMODE's own clobbers -- irrelevant, the process is
* about to EXIT either way).
*---------------------------------------------------------------
*-- ESC [ ? 1049 l -- rmcup, xterm's LEAVE-alternate-screen
*-- (docs/VI-ALTSCREEN.md): the console puts the shell's screen
*-- and cursor back from where VI_START's smcup parked them.
*-- This REPLACES the ESC [ 2 J that used to clear the body
*-- here (found live 2026-09-03: without any cleanup the next
*-- prompt collided with stale vi content) -- the restore IS
*-- the cleanup, and the same bytes work verbatim on a real
*-- terminal over a future serial line. EXIT (liba) flushes
*-- stdio on the way out, so no explicit SIO_FLUSH is needed.
*-- A vi that never gets here (killed, ^C'd) is covered by the
*-- kernel's PRC_ALT_RST backstop, PRC_TMD_RST's twin.
EX_ONQUIT   lda   #$EC                 ;'l' | $80
            jsr   VI_ALT_OUT
            lda   #FD_STDOUT
            ldx   VI_SAVEMD
            jsr   SC_TTYMODE
            rts

*-- VI_ALT_OUT -- emit ESC [ ? 1 0 4 9 A (A = 'h' | $80 to
*-- enter the alternate screen, 'l' | $80 to leave), high-bit
*-- bytes like the rest of vi's output. The final byte rides
*-- the stack: no scratch cell in the text (check-modules'
*-- purity ratchet). CLOBBERS: A, X, Y.
VI_ALT_OUT  pha
            ldy   #0
:lp         lda   VI_ALTSEQ,y
            beq   :fin
            phy
            ldx   #FD_STDOUT
            jsr   PUTC
            ply
            iny
            bra   :lp
:fin        pla
            ldx   #FD_STDOUT
            jmp   PUTC
VI_ALTSEQ   dfb   $9B,$DB,$BF,$B1,$B0,$B4,$B9,0

*---------------------------------------------------------------
* VI_SUSPEND -- cooperative ^Z (JOB-CONTROL.md Increment E).
* VI_RAWKEY calls this when SC_SIGPEND pops SIG_TSTP out of a
* read's ERR_INTR: emit rmcup and FLUSH it (so the console hands
* the shell's screen back BEFORE we stop -- a buffered rmcup
* would never reach it), then SC_STOP parks us until the shell's
* fg/bg does SYS_CONT. On resume, smcup re-parks the shell
* screen and clears the glass; VI_RAWKEY's abort-to-repaint tail
* then redraws. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
VI_SUSPEND  lda   #$EC                 ;'l'|$80 -- rmcup
            jsr   VI_ALT_OUT
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH
*-- Hand the shell COOKED+ECHO before parking (VI_SAVEMD, the
*-- mode vi replaced at entry) -- exactly EX_ONSPAWN's move for
*-- `:!`. Without it the shell reprompts in vi's raw+noecho
*-- mode and nothing you type echoes ("no terminal echo after
*-- ^Z", operator 2026-09-08).
            lda   #FD_STDOUT
            ldx   VI_SAVEMD
            jsr   SC_TTYMODE
            jsr   SC_STOP              ;parked until continued
*-- Resumed: raw back for vi (EX_ONSPAWNED's move), then smcup
*-- + the caller's repaint.
            lda   #FD_STDOUT
            ldx   #VI_RAWMODE
            jsr   SC_TTYMODE
            lda   #$E8                 ;'h'|$80 -- smcup
            jsr   VI_ALT_OUT
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH
            rts

*---------------------------------------------------------------
* EX_ONSPAWN -- vi's REAL body (ex.s's copy is a no-op stub).
* excmd2.s's EX_BG_SPAWN/EX_BG_SPAWN2 call it before every
* `!`-family child: hand the console to the child COOKED+echo
* (the mode vi replaced at entry -- what real vi's `!` does,
* V7 vi's unix()), starting it on a fresh line below the `:`
* prompt. SIGINT stays CAUGHT on purpose: a ^C while the child
* runs kills the child (spawn resets CATCH to DFL there) and
* pends against vi, which VI_RAWKEY drains on its next read --
* V7 vi ignores INT in the parent for exactly this reason, and
* restoring DFL here would let the ^C sweep kill vi.
* CLOBBERS: A, X, Y. Touches no PTRn (SC_SPAWN's operands).
*---------------------------------------------------------------
EX_ONSPAWN  lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH
            lda   #FD_STDOUT
            ldx   VI_SAVEMD
            jsr   SC_TTYMODE
            rts

*---------------------------------------------------------------
* EX_ONSPAWNED -- the child is gone (or never spawned): raw
* mode back. Nothing else: the repaint, and for `:!cmd` (its
* child wrote to the console -- ED_GLASSOUT, set by
* EX_BANG_ESC) real vi's "[Hit return to continue]", are the
* `:` landing's (VI_COLON's :vc_ret) -- every `!` form ends
* `jmp MAINLOOP`, whose ED_D1FLAG branch lands there.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
EX_ONSPAWNED
            lda   #FD_STDOUT
            ldx   #VI_RAWMODE
            jsr   SC_TTYMODE
            rts

*---------------------------------------------------------------
* VI_RAWKEY -- read ONE raw byte from FD_STDIN (blocking).
* OUT: carry clear + A = the byte; carry set = SC_READ failed --
* on ERR_INTR specifically (a held ^C, docs/SIGNALS.md), drains
* it via SC_SIGPEND first so it cannot re-fire the same way on
* the NEXT blocking read. Callers (VI_LOOP, VI_COLON,
* viinsert.s's VI_INS_ENTER) all treat "carry set" as "abort
* whatever was pending and redraw" -- there is no per-caller
* distinction needed since v1 has no count/operator prefix to
* unwind. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
* `.`-repeat (2026-09-05): VI_RAWKEY is vi's single key-read
* choke point (command mode AND insert mode), so recording and
* replay both live here. While REPLAYING (`.`), the next byte
* comes from VI_DOTBUF instead of the keyboard; while RECORDING
* (armed once per command by VI_DOT_ARM at VI_LOOP's top), every
* returned byte is appended to VI_RECBUF. Replay bytes are also
* recorded -- harmlessly, since VI_RECBUF is separate from
* VI_DOTBUF, so the commit at the end of a replayed change just
* copies VI_DOTBUF's own bytes back. OUT/CLOBBERS unchanged from
* before: A = key, carry clear = ok / carry set = ^C-or-error;
* clobbers A, X.
*-- ARROWS ARRIVE FRAMED (2026-09-10): the kernel commits an
*-- arrow as ONE 3-byte line (tty7.s TTY_COOK_RAW), so this
*-- asks for 3 bytes: 3 back that are ESC [ final = an arrow,
*-- returned as VI_KUP..VI_KLEFT (vi.s). A bare ESC comes back
*-- alone -- no read-ahead, no timeout. But 3 back is NOT always
*-- an arrow: keys typed ahead of vi's mode switch sit in a
*-- COOKED line ("ialpha" CR, check_play's new-file case) and a
*-- 3-byte read returns "ial" -- those are served one at a time
*-- from VI_RDBUF via VI_RDPOS/VI_RDLEN, never dropped. VI_UNGET
*-- is served first and NOT re-recorded: it was recorded when
*-- first read.
VI_RAWKEY   lda   VI_UNGET
            beq   :rk_play
            stz   VI_UNGET
            clc
            rts
:rk_play    lda   VI_DOTPLAY
            beq   :rk_kbd
            ldx   VI_DOTPTR
            cpx   VI_DOTLEN
            bcs   :rk_exh              ;replay exhausted
            lda   VI_DOTBUF,x
            inc   VI_DOTPTR
            bra   :rk_rec              ;A = the replayed key
:rk_exh     stz   VI_DOTPLAY           ;done -> fall to keyboard
:rk_kbd     ldx   VI_RDPOS             ;bytes left from the
            cpx   VI_RDLEN             ;last read? serve them
            bcc   :rk_next
            lda   #<VI_RDPARM
            ldx   #>VI_RDPARM
            jsr   SC_READ
            bcc   :rk_ok
            cmp   #ERR_INTR
            bne   :rk_oth
            jsr   SC_SIGPEND            ;A = popped signo
            cmp   #VI_SIGTSTP           ;^Z -> suspend dance;
            bne   :rk_oth               ;INT/none -> abort below
            jsr   VI_SUSPEND
:rk_oth     sec
            rts
:rk_ok      lda   VI_RDPARM_TRN
            sta   VI_RDLEN
            stz   VI_RDPOS
            cmp   #3
            bne   :rk_kbd              ;1 (or 2): plain bytes
            lda   VI_RDBUF
            cmp   #$9B                 ;ESC
            bne   :rk_kbd
            lda   VI_RDBUF+1
            cmp   #$DB                 ;'['
            bne   :rk_kbd
            lda   VI_RDBUF+2
            cmp   #$C1                 ;A..D
            bcc   :rk_kbd
            cmp   #$C5
            bcs   :rk_kbd
            stz   VI_RDLEN             ;consumed as one key
            and   #$07                 ;$C1..$C4 -> 1..4
            bra   :rk_rec
:rk_next    lda   VI_RDBUF,x
            inc   VI_RDPOS
:rk_rec     ldx   VI_RECING
            beq   :rk_done
            ldx   VI_RECLEN
            cpx   #VI_DOTCAP
            bcs   :rk_ovf
            sta   VI_RECBUF,x
            inc   VI_RECLEN
            bra   :rk_done
:rk_ovf     ldx   #1
            stx   VI_RECOVF            ;too long -> not
                                       ;dot-repeatable
:rk_done    clc
            rts

*---------------------------------------------------------------
* VI_DOT_ARM -- begin recording a fresh command's keystrokes.
* Called once at VI_LOOP's top (NOT in VI_READCMD, which
* operators call again for their motion key). CLOBBERS: A.
*---------------------------------------------------------------
VI_DOT_ARM  stz   VI_RECLEN
            stz   VI_RECOVF
            lda   #1
            sta   VI_RECING
            rts

*---------------------------------------------------------------
* VI_DOT_COMMIT -- a change command finished: make its recorded
* keys the last change VI_DOTBUF/VI_DOTLEN for `.`. A command
* that overran the cap is dropped (VI_DOTLEN=0), never committed
* truncated (a headless insert would wedge the replay).
* CLOBBERS: A, X.
*---------------------------------------------------------------
VI_DOT_COMMIT
            lda   VI_RECOVF
            beq   :dc_ok
            stz   VI_DOTLEN
            rts
:dc_ok      ldx   #0
:dc_cp      cpx   VI_RECLEN
            beq   :dc_done
            lda   VI_RECBUF,x
            sta   VI_DOTBUF,x
            inx
            bra   :dc_cp
:dc_done    stx   VI_DOTLEN
            rts

*---------------------------------------------------------------
* VI_DOT_REPEAT -- `.`: arm replay of the last change, then the
* caller `jmp VI_LOOP`s -- VI_LOOP's top re-arms recording and
* VI_READCMD pulls the command back out of VI_DOTBUF through
* VI_RAWKEY. A no-op if nothing has been recorded yet.
* CLOBBERS: A.
*---------------------------------------------------------------
VI_DOT_REPEAT
            lda   VI_DOTLEN
            beq   :dr_none
            stz   VI_DOTPTR
            lda   #1
            sta   VI_DOTPLAY
:dr_none    rts

VI_RDPARM      dfb   PCOUNT_READ
VI_RDPARM_REF  dfb   FD_STDIN
VI_RDPARM_BUF  da    VI_RDBUF
VI_RDPARM_REQ  da    3         ;1 key, or a framed arrow's 3
VI_RDPARM_TRN  da    0

*---------------------------------------------------------------
* VI_START -- process entry (vi.s's own preamble `jmp`s straight
* here, bypassing edparse.s's classic START/MAINLOOP entirely).
* Loads the argv[1] file via ED_STARTFILE (unchanged reuse),
* switches the console to cbreak+noecho (saving the previous
* mode), arms ^C as a caught (held) signal, queries geometry
* once, positions the cursor at line 1, paints the first full
* screen, and falls into the command loop. CLOBBERS: everything
* -- this never returns.
*---------------------------------------------------------------
*-- VI_NOTTY -- stdout is a file or a pipe: say so on stderr and
*-- exit 1, before raw mode or a single escape. VI_QUERYGEO used
*-- to ignore SC_TTYGEO's carry, so `vi f > x` ran a 0x0 screen
*-- (found 2026-09-03 wiring the poison gate). vidmode's rule.
VI_NOTTY    lda   #<VINOTTYM
            sta   PTR0
            lda   #>VINOTTYM
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            jmp   EXIT
VINOTTYM    asc   "vi: stdout is not a console"
            dfb   0

VI_START    jsr   VI_QUERYGEO            ;geometry first: carry
            bcs   VI_NOTTY               ;set = not a console
*-- smcup FIRST and FLUSHED (docs/VI-ALTSCREEN.md): ESC[?1049h
*-- parks the shell's screen before the file load, so a "?"
*-- from a missing file and the echo of any typeahead that
*-- arrives before raw mode land on vi's screen (erased by the
*-- first paint), not on the screen rmcup will bring back.
            lda   #$E8                   ;'h'|$80 -- ESC[?1049h
            jsr   VI_ALT_OUT
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH
            jsr   ED_STARTFILE
* -- vi-only: `vi newfile` on a NON-existent file must still let
* -- ZZ/:w CREATE it (standard vi's "[New file]"). ED_STARTFILE
* -- is shared with ed/ex, whose own gates require the name NOT
* -- remembered on their open-fail, so it leaves ED_CURFNAME
* -- empty -- re-derive the arg to PATHBUF and remember it HERE
* -- (found 2026-09-04 by check_vi: `VI VWQ` then `:wq` wrote
* -- nothing, status "" [MOD]).
            lda   ARGC
            cmp   #2
            bcc   :nofn                 ;no filename arg
            lda   ED_CURFNAME
            bne   :nofn                 ;already kept
            lda   #1
            jsr   GETARG                ;PTR0 = argv[1]
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH                ;PATHBUF = the path
            jsr   ED_RMBR_FNAME         ;keep it for :w/ZZ
:nofn       lda   #FD_STDOUT
            ldx   #VI_RAWMODE
            jsr   SC_TTYMODE
            sta   VI_SAVEMD
            lda   #VI_SIGINT
            ldx   #SIGA_CATCH
            jsr   SC_SIGNAL
            lda   #VI_SIGTSTP            ;catch ^Z: rmcup/stop/
            ldx   #SIGA_CATCH            ;smcup instead of a
            jsr   SC_SIGNAL              ;kernel direct-stop
            stz   VI_NOFLUSH             ;VI_CSI_POS flushes by
                                         ;default (viscreen.s)
            stz   VI_UNGET               ;no pushed-back key
            stz   VI_RDPOS               ;no unserved read bytes
            stz   VI_RDLEN
            stz   VI_FCMD                ;no remembered f/F/t/T
                                         ;yet -- `;`/`,` must
                                         ;fail cleanly, not read
                                         ;garbage (this task's
                                         ;own new state, vi.s)
            lda   #1
            sta   VI_TOP
            stz   VI_TOP+1
            stz   VI_CURCOL
            stz   VI_MODE
            lda   ED_NLINES
            ora   ED_NLINES+1
            beq   :empty
            lda   #1
            sta   ED_CURLINE
            stz   ED_CURLINE+1
            bra   :haveline
*-- An empty file (a new one, or one that loaded zero lines) is
*-- presented as a SINGLE empty line -- real vi's model, and
*-- what VI_REPAINT already draws (the lone cursor at 1,1). The
*-- buffer must MATCH: without a real line 1, insert splices
*-- at ED_CURLINE=0 (a nonexistent slot), the first typed
*-- line is written to slot 0 and lost; only text after the
*-- first RETURN survives (found 2026-09-04: `i`, two lines,
*-- ESC left just the second). Seed one empty line, the same
*-- idiom :docr uses to open a line on RETURN.
:empty      lda   #<VI_LBUF
            sta   ED_SRC
            lda   #>VI_LBUF
            sta   ED_SRC+1
            lda   #0
            jsr   ED_BUMP_ALLOC
            stz   ED_TMP16               ;insert AFTER line 0 --
            stz   ED_TMP16+1             ;i.e. as the new line 1
            jsr   ED_INSRT_AFTR         ;NLINES 0->1, CUR->1
:haveline   jsr   VI_REPAINT
            jsr   VI_STAT_LINE         ;file info on open (real
            lda   #1                   ;vi); the first command
            sta   VI_STMSG             ;key clears it
            jsr   VI_PLACE_CUR
            jmp   VI_LOOP               ;skip VI_MOTKEY's
                                        ;body: it sits
                                        ;between here and
                                        ;VI_LOOP, so a
                                        ;fall-through would
                                        ;RTS off an empty
                                        ;stack

*---------------------------------------------------------------
* VI_MOTKEY -- command-mode entry point for every motion key
* vimotion.s owns BEYOND h/j/k/l (which VI_LOOP below still
* dispatches directly, unchanged from the birth slice -- j/k's
* OWN scroll-integrated routines, not VI_DOMOTION, per
* vimotion.s's VI_TARG_J/VI_TARG_K header). IN: A = the raw key
* VI_READCMD returned. OUT: carry clear = the key WAS one of
* these motions (handled -- VI_GOMOTION already moved the
* cursor, or silently no-op'd on an invalid find/repeat); carry
* set = not one of these keys at all -- VI_LOOP's own chain
* keeps trying (i/:/Z/u). CLOBBERS: same as VI_GOMOTION when
* handled; none otherwise.
*---------------------------------------------------------------
VI_MOTKEY   cmp   #"w"
            beq   :mgo
            cmp   #"W"
            beq   :mgo
            cmp   #"b"
            beq   :mgo
            cmp   #"B"
            beq   :mgo
            cmp   #"e"
            beq   :mgo
            cmp   #"E"
            beq   :mgo
            cmp   #"0"
            beq   :mgo
            cmp   #"^"
            beq   :mgo
            cmp   #"+"          ;next line, first non-blank --
            beq   :mgo          ;RETURN too (VI_READCMD maps it)
            cmp   #"$"
            beq   :mgo
            cmp   #"G"
            beq   :mgo
            cmp   #"f"
            beq   :mgo
            cmp   #"F"
            beq   :mgo
            cmp   #"t"
            beq   :mgo
            cmp   #"T"
            beq   :mgo
            cmp   #$BB          ;';' high-bit -- #";" trips
                                ;merlin32's comment-start parser
            beq   :mgo
            cmp   #$AC          ;',' high-bit -- #"," trips
                                ;merlin32's operand parser
                                ;(indexed-addressing separator)
            bne   :mno
:mgo        jsr   VI_GOMOTION
            clc
            rts
:mno        sec
            rts

*---------------------------------------------------------------
* VI_LOOP -- the command-mode key dispatch. h j k l (vimotion.s,
* now count-repeated -- VI_READCMD's own leading-digit accumu-
* lation, VI_COUNT normalized then the single-step routine
* called that many times), every OTHER motion key via VI_MOTKEY
* above, i a A I o O insert-entry variants (viinsert.s), / ? n N
* search (visearch.s), `:` (VI_COLON, below), ZZ (VI_ZZ), u
* (VI_UNDO_KEY). Anything else is silently ignored (v1 -- real
* vi would ring the bell, and this tree has no console primitive
* for one yet). ^C/any read error aborts to a repaint, discards
* any pending count, and stays in command mode.
*---------------------------------------------------------------
VI_LOOP     jsr   VI_DOT_ARM     ;record this command's keys for
                                ;`.` (once per command -- NOT in
                                 ;VI_READCMD, ops re-call it)
            jsr   VI_READCMD
            bcc   :cmdok
            jmp   :vi_intr      ;bcs itself can't reach this
                                ;far in a chain this long --
                                ;jmp has no range limit, bcc
                                ;does (same shape vimotion.s's
                                ;VI_DOMOTION hit and fixed)
:cmdok      ldx   VI_STMSG            ;a key arrived: clear the
            beq   :nostmsg           ;on-open banner. ldx (not
            stz   VI_STMSG           ;lda) so A keeps the
            pha                      ;key across the
            jsr   VI_STAT_BLANK      ;which clobber A/X/Y (real
            jsr   VI_PLACE_CUR       ;vi: the info is transient)
            pla
:nostmsg    jsr   VI_MOTKEY
            bcc   VI_LOOP
            jsr   VI_OPKEY       ;viop.s d c y x X D C Y s
                                 ;P J r ~ (docs/VI-DESIGN.md sec
                                 ;4.1/4.3/4.4)
            bcs   :chkh
            jsr   VI_DOT_COMMIT  ;operator handled = a change ->
            jmp   VI_LOOP        ;record it for `.`
:chkh       cmp   #"h"
            bne   :nh
            jsr   VI_CNTNORM
:hlp        jsr   VI_MOVE_H
            dec   VI_COUNT
            bne   :hlp
            lda   VI_COUNT+1
            beq   :hdn
            dec   VI_COUNT+1
            bra   :hlp
:hdn        jmp   VI_LOOP
:nh         cmp   #"j"
            bne   :nj
            jsr   VI_CNTNORM
:jlp        jsr   VI_MOVE_J
            dec   VI_COUNT
            bne   :jlp
            lda   VI_COUNT+1
            beq   :jdn
            dec   VI_COUNT+1
            bra   :jlp
:jdn        jmp   VI_LOOP
:nj         cmp   #"k"
            bne   :nk
            jsr   VI_CNTNORM
:klp        jsr   VI_MOVE_K
            dec   VI_COUNT
            bne   :klp
            lda   VI_COUNT+1
            beq   :kdn
            dec   VI_COUNT+1
            bra   :klp
:kdn        jmp   VI_LOOP
:nk         cmp   #"l"
            bne   :nl
            jsr   VI_CNTNORM
:llp        jsr   VI_MOVE_L
            dec   VI_COUNT
            bne   :llp
            lda   VI_COUNT+1
            beq   :ldn
            dec   VI_COUNT+1
            bra   :llp
:ldn        jmp   VI_LOOP
:nl         cmp   #"i"
            bne   :ni
            jsr   VI_INS_ENTER
            jsr   VI_DOT_COMMIT
            jmp   VI_LOOP
:ni         cmp   #"a"
            bne   :na
            jsr   VI_INS_A
            jsr   VI_DOT_COMMIT
            jmp   VI_LOOP
:na         cmp   #"A"
            bne   :ncapa
            jsr   VI_INS_AEOL
            jsr   VI_DOT_COMMIT
            jmp   VI_LOOP
:ncapa      cmp   #"I"
            bne   :ncapi
            jsr   VI_INS_FNB
            jsr   VI_DOT_COMMIT
            jmp   VI_LOOP
:ncapi      cmp   #"o"
            bne   :no
            jsr   VI_INS_OBLW
            jsr   VI_DOT_COMMIT
            jmp   VI_LOOP
:no         cmp   #"O"
            bne   :ncapo
            jsr   VI_INS_OABV
            jsr   VI_DOT_COMMIT
            jmp   VI_LOOP
:ncapo      cmp   #"/"
            bne   :nfsl
            jsr   VI_SRCH_FWD
            jmp   VI_LOOP
:nfsl       cmp   #"?"
            bne   :nqst
            jsr   VI_SRCH_BK
            jmp   VI_LOOP
:nqst       cmp   #"n"
            bne   :nn
            jsr   VI_SRCH_N
            jmp   VI_LOOP
:nn         cmp   #"N"
            bne   :nNN
            jsr   VI_SRCH_NN
            jmp   VI_LOOP
:nNN        cmp   #":"
            bne   :ncolon
            jsr   VI_COLON
            jmp   VI_LOOP
:ncolon     cmp   #"Z"
            bne   :nZ
            jsr   VI_ZZ
            jmp   VI_LOOP
:nZ         cmp   #"u"
            bne   :nu
            jsr   VI_UNDO_KEY
            jmp   VI_LOOP
:nu         cmp   #$86               ;^F page down
            bne   :nctlf
            jsr   VI_PAGE_F
            jmp   VI_LOOP
:nctlf      cmp   #$82               ;^B page up
            bne   :nctlb
            jsr   VI_PAGE_B
            jmp   VI_LOOP
:nctlb      cmp   #$84               ;^D half down
            bne   :nctlu
            jsr   VI_PAGE_D
            jmp   VI_LOOP
*-- ^U (half up) -- $95, which is the RIGHT ARROW's wire on this
*-- keyboard. The bare right arrow becomes a CSI upstream
*-- (TTY_KEYIN :plain), so the only raw $95 that reaches vi is
*-- OPTION+U: Solid-Apple folds the key to its control code and
*-- takes the non-CSI path, which is exactly how you type a real
*-- ^U here (2026-09-10). ^B pages up too.
:nctlu      cmp   #$95               ;^U half up (OPTION+U)
            bne   :nctld
            jsr   VI_PAGE_U
            jmp   VI_LOOP
:nctld      cmp   #"."
            bne   :ndot
            jsr   VI_DOT_REPEAT   ;`.` -- replay the last
            jmp   VI_LOOP         ;change (VI_LOOP re-drives
                                 ;it from VI_DOTBUF); no-op
                                 ;if nothing recorded yet
:ndot       jmp   VI_LOOP
:vi_intr    jsr   VI_REPAINT
            jmp   VI_LOOP

*---------------------------------------------------------------
* VI_COLON -- `:` bridge (docs/VI-DESIGN.md sec 3.4/5 item 2).
* Prompts on the status row, echoes typed bytes there itself
* (tty echo is off), reads until RETURN (ESC aborts, matching
* real vi). An EMPTY command line (bare RETURN, or an aborted
* ESC) does nothing -- no `?`, matching real ex's own bare-`:`
* behavior -- everything else hands off to the REAL ex engine
* via ED_DISPATCH1, one command, then a full repaint on return.
* CLOBBERS: A, X, Y, ED_CMDPTR, VI_INSLEN (reused as the
* prompt's own running length -- `:` mode and insert mode never
* overlap) + everything ED_DISPATCH1's dispatched command and
* VI_REPAINT clobber.
*
* S IS PINNED ACROSS THE DISPATCH (VI_D1SP, 2026-09-07). The ex
* engine is jmp-only at its top level: every handler ends `jmp
* MAINLOOP`, never `rts`, and edparse.s's :ga_notbare reaches
* the EX_CMD family by `jsr` -- so each EX_CMD verb (`!`, `u`,
* `e`, `nu`, `k`, ...) and every ED_ERR_JMP from inside a
* handler leaves a return address on the stack. Harmless for
* ed/ex (nothing at their top level ever pops), fatal here:
* :vc_ret's `jmp VI_REPAINT` ends in an `rts` that popped the
* LEAKED address, landed back in the dispatcher, and its second
* `jmp MAINLOOP` -- ED_D1FLAG already cleared -- fell into
* ED_RDCMDLINE's fd-0 read on the RAW console, eating every key
* (`:!echo HI` "wedged vi", 2026-09-07, standing since the
* bridge landed -- reproduced at eac1287; docs/VI-SHELLOUT-
* CRASH.md). tsx/txs around the dispatch makes the bridge
* immune to any leak depth; check_vi_bang.py gates it.
*---------------------------------------------------------------
VI_COLON    jsr   VI_ERRARM             ;see VI_ERRARM below
            lda   VI_ROWS
            ldx   #1
            jsr   VI_CSI_POS
            lda   #$BA                  ;':'
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   VI_ERSLN
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH              ;the `:` prompt itself
                                        ;is visible before the
                                        ;first typed byte
            stz   VI_INSLEN
:rd         jsr   VI_RAWKEY
            bcs   :vc_done               ;^C aborts -- empty cmd
            cmp   #$8D                   ;CR
            beq   :vc_done
            cmp   #$9B                   ;ESC also aborts
            beq   :vc_abort
            cmp   #VI_KLEFT              ;left-arrow (^H) and
            beq   :vc_erase              ;DEL erase the last
            cmp   #$FF                   ;typed char; the other
            beq   :vc_erase              ;framed arrows are
            cmp   #$80                   ;ignored here
            bcc   :rd
            ldy   VI_INSLEN
            cpy   #VI_LBUFLEN-1
            bcs   :rd
            sta   VI_LBUF,y
            inc   VI_INSLEN
            ldx   #FD_STDOUT
            jsr   PUTC
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH              ;same line-buffering
                                        ;reason as viinsert.s
            bra   :rd
:vc_erase   jsr   VI_LNERASE
            bra   :rd
:vc_abort   stz   VI_INSLEN
:vc_done    ldy   VI_INSLEN
            lda   #0
            sta   VI_LBUF,y
            lda   VI_INSLEN
            beq   :vc_ret                ;empty -- skip the ex
                                        ;engine (no `?`)
            lda   #<VI_LBUF
            sta   ED_CMDPTR
            lda   #>VI_LBUF
            sta   ED_CMDPTR+1
            lda   #<:vc_ret
            sta   ED_D1RET
            lda   #>:vc_ret
            sta   ED_D1RET+1
            lda   #1
            sta   ED_D1FLAG
            stz   ED_GLASSOUT            ;set by ED_PUTLINE /
                                         ;EX_BANG_ESC if the
                                         ;command writes to the
                                         ;glass
            tsx                          ;pin S -- see header
            stx   VI_D1SP
            jmp   ED_DISPATCH1
:vc_ret     ldx   VI_D1SP                ;drop whatever the ex
            txs                          ;engine left stacked
            jsr   VI_ERRFIN
            lda   ED_GLASSOUT            ;p/nu/#/=/l output, or
            beq   :vc_paint              ;a `:!cmd` child's --
            lda   #<VI_HITRET_MSG        ;keep it readable (real
            sta   PTR0                   ;vi): one raw key, then
            lda   #>VI_HITRET_MSG        ;the repaint
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            ldx   #FD_STDOUT
            jsr   SIO_FLUSH
            jsr   VI_RAWKEY              ;any key continues
:vc_paint   jsr   VI_REPAINT
            jmp   VI_ERRSHOW ;a refused command says so
VI_HITRET_MSG
            asc   "[Hit return to continue]"
            dfb   0

*---------------------------------------------------------------
* VI_ERRARM / VI_ERRFIN / VI_ERRSHOW -- report an ex-line
* failure
* on the status row (EX-BADCMD). Every refused command goes
* through ED_ERR, which sets ED_ERRSTAT (the sticky, exit-status
* flag) and prints a `?` that the repaint after the dispatch
* wipes -- so a failed `:w` or `:s` said NOTHING. ARM (before
* the
* line is read) stashes the sticky flag and clears the live one
* and EX_MSGP's high byte; FIN (S already restored) records
* whether THIS dispatch failed in VI_ERRNOW and ORs the sticky
* flag back; SHOW (after the repaint) prints EX_MSGP's text if
* EX_ERRMSG set one ("cxyz: Not an editor command"), else the
* generic message, and arms VI_STMSG so the next key clears it
* like the open banner. A bare `:`+RETURN dispatches nothing, so
* ARM-then-FIN leaves VI_ERRNOW 0 and SHOW is silent.
* CLOBBERS: A, X (SHOW: Y, PTR0 and the VI_STATUS_MSG set).
*---------------------------------------------------------------
VI_ERRARM   lda   ED_ERRSTAT
            sta   VI_ERRSAVE
            stz   ED_ERRSTAT
            stz   EX_MSGP+1
            rts
VI_ERRFIN   lda   ED_ERRSTAT
            sta   VI_ERRNOW
            ora   VI_ERRSAVE
            sta   ED_ERRSTAT
            rts
VI_ERRSHOW  lda   VI_ERRNOW
            beq   :es_none
            lda   EX_MSGP
            ldx   EX_MSGP+1
            bne   :es_set
            lda   #<VI_FAILED_MSG
            ldx   #>VI_FAILED_MSG
:es_set     sta   PTR0
            stx   PTR0+1
            jsr   VI_STATUS_MSG
            lda   #1
            sta   VI_STMSG
            jmp   VI_PLACE_CUR
:es_none    rts
VI_FAILED_MSG
            asc   "Command failed"
            dfb   0

*---------------------------------------------------------------
* VI_LNERASE -- erase the last echoed char of a prompt line (the
* `:` line above, the `/` `?` line in visearch.s): one fewer in
* VI_INSLEN, and BS SP BS on the glass. A no-op on an empty
* line. CLOBBERS: A, X.
*---------------------------------------------------------------
VI_LNERASE  lda   VI_INSLEN
            beq   :none
            dec   VI_INSLEN
            lda   #$88
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$88
            ldx   #FD_STDOUT
            jsr   PUTC
            ldx   #FD_STDOUT
            jmp   SIO_FLUSH
:none       rts

*---------------------------------------------------------------
* VI_ZZ -- `ZZ` (docs/VI-DESIGN.md sec 5 item 3): write-if-
* dirty-and-quit, the SAME core `:x` uses (EX_XCORE, excmd.s),
* called directly -- `ZZ` is two keystrokes in command mode,
* never typed after `:`, so it cannot route through EX_CMD's
* text-match dispatch. Arms ED_D1FLAG/ED_D1RET the same way
* VI_COLON does before calling into shared ex-engine code, so a
* WRITE-FAILURE path (EX_XCORE's own `jmp ED_ERR_JMP` ->
* `jmp MAINLOOP`) redirects back into vi's own loop instead of
* MAINLOOP's fd-0 read -- the success path never returns at all
* (EX_XCORE always EXITs). A second byte that isn't `Z` aborts
* (no-op, repaint).
*---------------------------------------------------------------
VI_ZZ       jsr   VI_RAWKEY
            bcs   :zz_abort
            cmp   #"Z"
            bne   :zz_abort
            lda   #<:zz_ret
            sta   ED_D1RET
            lda   #>:zz_ret
            sta   ED_D1RET+1
            lda   #1
            sta   ED_D1FLAG
            jsr   VI_ERRARM              ;a failed write says so
            tsx                          ;pin S (VI_COLON's way)
            stx   VI_D1SP
            jmp   EX_XCORE
:zz_ret     ldx   VI_D1SP
            txs
            jsr   VI_ERRFIN
            jsr   VI_REPAINT
            jmp   VI_ERRSHOW
:zz_abort   jmp   VI_REPAINT

*---------------------------------------------------------------
* VI_UNDO_KEY -- `u` (docs/VI-DESIGN.md sec 5 item 4): the SAME
* EX_HASUNDO check `:u` (EX_CUNDO) makes, then EX_UNDO_CORE's
* block-swap directly -- no ED_CMDPTR token to synthesize.
*---------------------------------------------------------------
VI_UNDO_KEY lda   EX_HASUNDO
            bne   :go
            lda   #<VI_NOUNDO_MSG
            sta   PTR0
            lda   #>VI_NOUNDO_MSG
            sta   PTR0+1
            jmp   VI_STATUS_MSG
:go         jsr   EX_UNDO_CORE
            jmp   VI_REPAINT

VI_NOUNDO_MSG
            asc   "nothing to undo"
            dfb   0
