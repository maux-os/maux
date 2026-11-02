*---------------------------------------------------------------
* SH-SEQ B: shlex.s split again, at SH_INIT_ZR. Everything from
* here to READLINE is the tail of shlex.s, in order (the image
* bytes are where they were); the check-dialect budget is the
* manifest plus the largest put, and shlex.s was it.
*---------------------------------------------------------------
*---------------------------------------------------------------
* SH_INIT_ZR -- establish, at entry, every cell whose
* correctness used to rest on "the loader zeroed the image".
*
* WHY IT EXISTS (docs/STICKY.md sec 32). Lazy free (sec 27)
* keeps a dead process's bank, tagged with the program whose
* text it holds, and serves the next spawn of that program out
* of it WITHOUT recopying the image. So a second `sh` in one
* boot starts on the FIRST one's text -- and these cells are
* text. Under a copying loader the emitted zero arrived fresh
* on every spawn; under lazy free it arrives once.
*
* This is not theory. Measured before this routine existed,
* `sh` spawning `sh` twice from byte-identical scripts:
*
*     run 1  S0 0     S1 V=
*     run 2  S0 1     S1 V=WARMLEAK
*
* -- run 2 read `$?` before running anything and got run 1's
* LAST exit status, and read `$V` before assigning and got run
* 1's value. Both are ordinary shell behaviour, silently wrong.
*
* WHAT IS HERE, and it is exactly sec 28's own list of the
* cells a REPL reads on its FIRST pass, before anything has run
* to set them:
*
*   CSPTR       only inc/dec exists; nothing ever stores it
*   LASTSTATUS  `$?` on line 1
*   POS_SHIFT   `$1`/`$#` before any `shift`
*   SCAN_ACT    CR_STARTSCAN, before any scan has run
*   PCR_PEND    CR_INSTALL reads it above its own stz
*   VARNAMES    a free slot IS a zero name byte -- there is no
*               variable counter, so this is the load-bearing
*               one
*   VAREXP      ENV_STAGE walks every slot regardless of
*               occupancy; a garbage byte exports a variable
*               nobody marked
*
* NOT here, deliberately: VARVALS (only ever read for a slot
* VARNAMES says is occupied, and whoever occupied it wrote the
* value), and CSHEAD/CSRKIND/CSRFD/CSRTGT/PCR_KIND/PCR_FD/
* PCR_TGT (frame arrays indexed below CSPTR, or read only when
* PCR_PEND says a record is waiting -- both now zero).
*
* CLOBBERS: A, X. Called once, from START.
*---------------------------------------------------------------
SCRERR_MSG  asc   "sh: cannot open script file"
            dfb   $8D,0
*-- dfb hex, not asc "..": check-encoding's literal pin.
*-- "sh: bad option"
OPTERR_MSG  dfb   $F3,$E8,$BA,$A0,$E2,$E1,$E4,$A0
            dfb   $EF,$F0,$F4,$E9,$EF,$EE,$8D,0
CUSE_MSG    asc   "sh: -c: option requires an argument"
            dfb   $8D,0
*---------------------------------------------------------------
* LB_COPY -- copy LINEBUF to the buffer at A (low) / X (high):
* RAWLINE (the pristine copy SPOOL_ENTER reads) and PRETOK (what
* TOKENIZE is about to squeeze). Leaves PTR0 = LINEBUF and
* PTR1 = the destination (STRCPY restores both). CLOBBERS: A, X,
* Y, PTR0, PTR1 -- X because STRCPY's page count lives there.
*---------------------------------------------------------------
LB_COPY     sta   PTR1
            stx   PTR1+1
            lda   #<LINEBUF
            sta   PTR0
            lda   #>LINEBUF
            sta   PTR0+1
            jmp   STRCPY

SH_INIT_ZR  jsr   SH_HFLUSH          ;tracked-command cache:
                                     ;arena cells, so every
                                     ;spawn re-zeroes them here
            stz   CSPTR
            stz   LASTSTATUS
            ldx   #0                 ;the job table's states and
:jobz       stz   JOB_ST,x           ;%+/%-/JOB_FG/JOB_QUIET --
            inx                      ;one contiguous run (sh.s's
            cpx   #BGMAX+4+JOBPIDSZ  ;arena says so), BG_CNT's
            bne   :jobz              ;successor
            stz   POS_SHIFT
            stz   SCAN_ACT
            stz   PCR_PEND
            stz   RP_PEND            ;SH-EXECLOOP: no replay
            stz   RP_TOK             ;  owed to a first line
            stz   SH_EXITING
            stz   LP_PEND                ;SH-CASE2 A
            stz   TRAPSV_D
            stz   CONT_SEP               ;SH-SEQ C: a warm bank
            stz   EE_SUPP                ;  keeps the last run's
            stz   CS_FLOOR
            stz   TRAP_PEND
            stz   SH_SPOOL_LVL           ;console-loop spooling
                                         ;(sh.s's own dum-arena
                                         ;header) -- no spool
                                         ;file open yet, a fresh
                                         ;spawn's own first fact
            stz   SH_BGPID                ;`$!` -- no `&` yet
*-- USERFDS: whatever this shell was STARTED with beyond 0-2
*-- is the user's, and it passes it on. dup2(k,k) on an open fd
*-- is a no-op, on a closed one an error (SC_DUP2's header): a
*-- free "is it open" probe. Nothing has opened a fd yet.
            stz   USERFDS
            lda   #3
            sta   UFDK
:ufdp       lda   UFDK
            tax
            jsr   SC_DUP2
            bcs   :ufdn
            ldx   UFDK
            jsr   UFD_SET
:ufdn       inc   UFDK
            lda   UFDK
            cmp   #8
            bne   :ufdp
            stz   GOPTCIDX                ;getopts -- no call
            stz   GOPTLASTOI
            ldx   #0                     ;disarm every trap (BSS
            lda   #0                     ;is retained by lazy
:trapz      sta   TRAPACT,x              ;free, docs/SIGNALS.md)
            sta   TRAP_HELD,x
            inx
            cpx   #16
            bne   :trapz
            lda   #0
            ldx   #0
:names      sta   VARNAMES,x
            inx
            cpx   #MAXVARS*VARNAMESZ
            bne   :names
*-- VAREXP AND VARRO IN ONE RUN. sh.s's arena declares VARRO
*-- immediately after VAREXP and says why: the two are the same
*-- kind of cell (one byte per variable slot, meaningless unless
*-- it starts zero) and lazy free retains both. `readonly`'s bit
*-- is the worse of the two to inherit -- a stale VARRO byte
*-- makes a variable nobody protected refuse every assignment
*-- AND every `unset`, with nothing left in the language to
*-- clear it (docs/SH-FEATURES.md sec 29).
            ldx   #0
:exp        sta   VAREXP,x
            inx
            cpx   #MAXVARS+MAXVARS
            bne   :exp
            rts

*---------------------------------------------------------------
* CAP_LINE_MARK -- best-effort GET_MARK of fd 0 into
* LINE_MARK, BEFORE READLINE consumes the line about to be
* read. This is RW_LOOP_PUSH's (below) only source for a
* WHILE/UNTIL's loop head -- "the file offset of the start of
* the line the WHILE/UNTIL token is on" (docs/SHELL-SPLIT.md sec
* 15's "remember the file offset of the loop head"). Also
* DOUBLES as the non-seekable-stdin detector: LSEEK(SEEK_CUR)
* composes SC_GETMARK, and the kernel's PRC_GETMARK (src/kernel/
* procfile3.s) fails with ERR_INVAL for anything whose OFT_TYPE
* isn't OFT_FILE -- a pipe (OFT_PIPE_R/W) or a tty (a $80+
* pseudo-fd, never even an OFT index) both fail the same way, so
* LMARK_OK is exactly "was fd 0 seekable for THIS line".
* Failure is NOT itself an error -- most lines never open a
* WHILE/UNTIL at all -- RW_LOOP_PUSH is what turns a stale
* LMARK_OK into a loud diagnostic, only when it actually
* matters. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
CAP_LINE_MARK
*-- LSEEK(SEEK_CUR) reads the 3 bytes AT (PTR0) as the DELTA to
*-- add, then OVERWRITES them with the resulting absolute mark
*-- (seek.s's own contract) -- LINE_MARK doubles as both,
*-- so it MUST be re-zeroed before every call, not just once: a
*-- stale mark left over from the PREVIOUS line would otherwise
*-- get ADDED to the current one, walking fd 0 further off the
*-- real position every single line.
            stz   LINE_MARK
            stz   LINE_MARK+1
            stz   LINE_MARK+2
            lda   #<LINE_MARK
            sta   PTR0
            lda   #>LINE_MARK
            sta   PTR0+1
*-- CUR_IN_FD, not the FD_STDIN constant (Tier 3 docs/SH-
*-- FEATURES.md sec 4, `.`): a sourced file reads through this
*-- SAME routine, and its own WHILE/UNTIL loop heads must mark
*-- ITS fd, not the outer script's.
            lda   CUR_IN_FD
            ldy   #SEEK_CUR
            jsr   LSEEK
            bcs   :bad
            lda   #1
            sta   LMARK_OK
            rts
:bad        stz   LMARK_OK
            rts

*---------------------------------------------------------------
* STRIPCOMMENT -- truncate LINEBUF at a '#' that starts a WORD
* (POSIX 2.2/2.3: column 0, or a blank right before it) and is
* not inside an open quote (2026-09-15 rewrite -- see docs/
* SH-FEATURES.md sec 22). QUOTE-AWARE now: `ECHO "a # b"` and
* `ECHO 'a#b'` used to lose everything from the FIRST '#' no
* matter where it sat, which is a plain shell bug (POSIX 2.2.2:
* nothing is special inside a quote except the quote itself),
* not a scope limit -- `sh: unterminated quote` on a perfectly
* well-formed line was the symptom (STRPQST tracks the span).
*
* The old rule was "any '#' not immediately preceded by '$'",
* carved out ONLY for `$#` (docs/SH-FEATURES.md sec 4, Tier 2's
* positional-parameter count). The WORD-START rule subsumes it
* for free: a '#' right after '$' is never right after a blank
* either, so `$#`/`ECHO SC:$#` still keep their '#' as data, and
* `ECHO A#B` now ALSO keeps its mid-word '#' (POSIX: a '#' is a
* comment marker only where a new word could start) -- the old
* rule wrongly cut that one, just never on a `$`-prefixed word.
*
* Scripts you cannot annotate are scripts nobody maintains.
* ProDOS filenames cannot contain '#', so this cannot eat a
* pathname either way.
*
* 2026-09-15: an escaped `"` (`\"`) inside a DOUBLE-quoted span
* is content, not the close -- consistency with TOKENIZE's own
* POSIX 2.2.3 rule (shtok.s :qloop2) -- so `ECHO "a\" #b"` does
* not see a `#` that TOKENIZE itself will treat as still-quoted.
* Single-quoted spans have no such escape (STRPQST<>'"' there).
*---------------------------------------------------------------
STRIPCOMMENT
            stz   STRPQST
            lda   #$FF                   ;no escaped byte yet:
            sta   STRPEX                 ;255 is the NUL slot,
            ldy   #0                     ;never a text index
:scan       lda   LINEBUF,y
            beq   :done
            ldx   STRPQST                ;X unused past here --
                                         ;just a zero/nonzero
                                         ;test that spares A
            beq   :bare
            cpx   #$A2
            bne   :inqst
            cmp   #$DC                   ;'\' high-bit-set
            bne   :inqst
            iny
            lda   LINEBUF,y
            beq   :done
            iny                          ;skip BOTH bytes: an
            bra   :adv2                  ;escaped quote does not
                                         ;toggle, and `\\` is a
                                         ;PAIR (SH-MLQUOTE: the
                                         ;`"` after it closes)
*-- inside a quote (STRPQST = the byte that closes it): only
*-- that exact byte ends the span -- '#' is content here, same
*-- as every other character.
:inqst      cmp   STRPQST
            bne   :adv
            stz   STRPQST
            bra   :adv
*-- `\X`: X is part of the word, whatever it is (SH-MLQUOTE:
*-- `echo a\ #b` is `a #b`; that blank is escaped, so the `#`
*-- does not start a word).
:bare       cmp   #ALC_DC
            bne   :bnbs
            iny
            sty   STRPEX
            lda   LINEBUF,y
            beq   :done
            bra   :adv
:bnbs       cmp   #$A7                   ;''' high-bit-set
            beq   :openq
            cmp   #$A2                   ;'"' high-bit-set
            beq   :openq
            cmp   #$A3                   ;'#'
            bne   :adv
            cpy   #0
            beq   :cut                   ;column 0 -- a word
                                         ;start with nothing
                                         ;before it
            dey
            lda   LINEBUF,y
            cmp   #$A0                   ;blank right before it
            bne   :hno
            cpy   STRPEX                 ;... and not escaped?
            beq   :hno
            iny
            bra   :cut
:hno        iny
            bra   :adv
:openq      sta   STRPQST
:adv        iny
:adv2       cpy   #LINEMAX
            bne   :scan
            rts
:cut        lda   #0
            sta   LINEBUF,y
            sty   LINELEN
:done       rts

*---------------------------------------------------------------
* shlex2.s -- READLINE, `put` by src/bin/sh.s right after
* shlex.s.  Split from it at a global label (SH-PREFIX): shlex.s
* is the largest put file and the check-dialect source-buffer
* budget is the manifest plus the largest put.  The bytes are
* where they were: this is the tail of shlex.s, in order.
*---------------------------------------------------------------
*---------------------------------------------------------------
* READLINE -- read one LOGICAL line (SH-MLQUOTE,
* docs/SH-MLQUOTE.md): one physical line (RL_PHYS, below); if it
* holds a quote byte or a backslash, RL_LOGICAL (shrlog.s)
* decides whether it is complete and joins the next physical
* line when it is not. A line with neither is complete by
* inspection: one scan. OUT as RL_PHYS's. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
READLINE    stz   RL_ED
            jsr   RL_PHYS
            bcs   :out                   ;true EOF
            lda   RL_OVER
            bne   :slow                  ;over-long: refused
            ldy   #0
:pf         lda   LINEBUF,y
            beq   RL_DONE                ;no quote, no backslash
            cmp   #ALC_A7
            beq   :slow
            cmp   #ALC_A2
            beq   :slow
            cmp   #ALC_DC
            beq   :slow
            iny
            bne   :pf
:slow       jmp   RL_LOGICAL
:out        rts
*-- RL_DONE: a COMPLETE logical line leaves here. History is
*-- TRANSACTIONAL: the editor no longer adds at Return; the
*-- whole logical line is added once, if the slot (ED_LENMAX)
*-- holds it.
RL_DONE     lda   RL_ED
            beq   :ok
            lda   LINELEN
            cmp   #ED_LENMAX+1
            bcs   :ok
            sta   ED_LEN
            jsr   ED_HADD
:ok         clc
            rts

*---------------------------------------------------------------
* RL_PHYS -- read one CR-terminated line from CUR_IN_FD (fd 0
* at the top level; a sourced file's own fd while `.` is active,
* Tier 3 docs/SH-FEATURES.md sec 4) into LINEBUF, raw bytes, one
* at a time (docs/SH-DESIGN.md ruling 6). NUL-terminates in
* place (CR is NOT included in LINEBUF). A
* partial line followed by EOF (no trailing CR) is still
* returned as a line -- only a read that produces ZERO bytes
* before EOF is reported as true end-of-script. OUT: carry
* clear, LINEBUF/LINELEN valid; carry set = true EOF, no line.
* ALSO (SH-MLQUOTE): RL_NOCR = 1 if the line ended at EOF with
* no CR; RL_OVER = 1 if it was longer than LINEMAX -- then
* LINEBUF holds its first LINEMAX bytes, RL_X256 its 256th and
* the fd is just past that byte (the rest is the caller's: it
* used to be dropped silently and the truncated line ran);
* RL_ED is incremented when the line editor produced it.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*-- THE SEEKABLE FAST PATH (docs/PERF-PLAN.md step 5). When the
*-- input is a FILE, read ONE chunk and SET_MARK back to just
*-- past the consumed CR -- the fd position after every line is
*-- byte-identical to the byte-at-a-time path's (children
*-- spawned mid-script, `break`/`continue`/`.`'s own seeks, and
*-- heredoc bodies all see exactly what they used to), but a
*-- 60-char command line costs 2 syscalls instead of ~60 one-
*-- byte MLI READs. Seekability is CAP_LINE_MARK's verdict,
*-- already computed for this very line: LMARK_OK says whether
*-- CUR_IN_FD answered GET_MARK, and LINE_MARK then holds this
*-- line's own start (the loop-head mark -- which is why the
*-- seek target is computed in RL_MARK, never in place). A
*-- console or a pipe ($( )'s child sh) takes the byte-at-a-
*-- time path below, unchanged.
RL_PHYS     stz   LINELEN
            stz   RL_NOCR
            stz   RL_OVER
            lda   SH_EDIT                ;the editor: only a
            beq   :nedit                 ;console prompt
            lda   CUR_IN_FD
            bne   :nedit
            jsr   ED_LINE                ;carry as READLINE's; X
            inx                          ;= $FF: not a console
            bne   :edone                 ;after all: read it the
                                         ;old way (INX, not CPX:
                                         ;carry is the EOF flag)
:nedit      lda   LMARK_OK
            bne   :rlfast                ;seekable
            jmp   :loop                  ;console/pipe: the
                                         ;byte-at-a-time path
:edone      inc   RL_ED
            rts
:rlfast
            lda   #PCOUNT_READ
            sta   RL_PARM
            lda   CUR_IN_FD
            sta   RL_PARM_REF
            lda   #<RL_BUF
            sta   RL_PARM_BUF
            lda   #>RL_BUF
            sta   RL_PARM_BUF+1
*-- LINEMAX+1 = 256: a real 16-bit request since LINEMAX went
*-- 255 (S9 L3) -- #LINEMAX+1 alone would truncate to #0.
            lda   #<LINEMAX+1
            sta   RL_PARM_REQ
            lda   #>LINEMAX+1
            sta   RL_PARM_REQ+1
            lda   #<RL_PARM
            ldx   #>RL_PARM
            jsr   SC_READ
            bcs   :rleof0                ;read error == end of
                                         ;script -- GETC's rule
            lda   RL_PRM_TRNS
            ora   RL_PRM_TRNS+1
            bne   :rlhave
:rleof0     sec                          ;nothing read at all --
            rts                          ;true EOF (short final
                                         ;lines return via
                                         ;:rlpd, never here)
:rlhave     ldy   #0
*-- SH-FOREIGN: this is the FILE path (LMARK_OK: the fd
*-- answered GET_MARK), the only place a script in the system's
*-- standard text (ProDOS TXT: low ASCII, $0D) can arrive.
*-- Fold each byte to the high form IN PLACE as the scan
*-- passes it, so the four copy sites below and RL_X256 see
*-- high text and a $0D end is $8D. Pipes and the tty (the
*-- byte path) are NEVER folded: the `$( )` serialiser carries
*-- a bit-7-CLEAR $0D there (SH-NLVAR) that must not end a
*-- line. A file is where a person put the bytes; a pipe is
*-- where sh's own serialiser did.
:rlscan     lda   RL_BUF,y
            ora   #$80
            sta   RL_BUF,y
            cmp   #$8D
            beq   :rlgotcr
            iny
            cpy   RL_PRM_TRNS
            bne   :rlscan
*-- no CR in the chunk. A SHORT chunk is the file's final,
*-- unterminated line: the position is already at EOF, return
*-- it. A FULL chunk is an over-long line: keep the first
*-- LINEMAX bytes and hand the rest to the caller (RL_OVER: it
*-- refuses the line and resynchronises) -- the fd is already
*-- past the 256th byte, so no seek is needed on this path.
            lda   RL_PRM_TRNS+1
            bne   :rlover                ;trans == 256 == the
                                         ;full request: an
                                         ;over-long line (the
                                         ;8-bit cmp #LINEMAX+1
                                         ;died at LINEMAX 255)
            ldy   #0
:rlpcp      cpy   RL_PRM_TRNS
            beq   :rlpd
            lda   RL_BUF,y
            sta   LINEBUF,y
            iny
            bne   :rlpcp
:rlpd       sty   LINELEN
            lda   #0
            sta   LINEBUF,y
            inc   RL_NOCR
            clc
            rts
:rlover     ldy   #0
:rlocp      lda   RL_BUF,y
            sta   LINEBUF,y
            iny
            cpy   #LINEMAX
            bne   :rlocp
            sty   LINELEN
            lda   #0
            sta   LINEBUF,y
            lda   RL_BUF+LINEMAX         ;the byte past the cap
            sta   RL_X256
            inc   RL_OVER
            clc
            rts
:rlgotcr    sty   RL_CRP
            ldy   #0
:rlcp       cpy   RL_CRP
            beq   :rlcpd
            lda   RL_BUF,y
            sta   LINEBUF,y
            iny
            bne   :rlcp
:rlcpd      sty   LINELEN
            lda   #0
            sta   LINEBUF,y
*-- RL_MARK = LINE_MARK + CRP + 1: the byte after the CR.
            lda   RL_CRP
            sec                          ;the +1, via carry --
            adc   LINE_MARK              ;CRP can be 255 now,
            sta   RL_MARK                ;so +1 CAN carry
            lda   LINE_MARK+1
            adc   #0
            sta   RL_MARK+1
            lda   LINE_MARK+2
            adc   #0
            sta   RL_MARK+2
            lda   #<RL_MARK
            sta   PTR0
            lda   #>RL_MARK
            sta   PTR0+1
            lda   CUR_IN_FD
            ldy   #SEEK_SET
            jsr   LSEEK
            bcs   :rlbad                 ;a SET_MARK the fd just
                                         ;answered GET_MARK for
                                         ;cannot fail; if it
                                         ;somehow does, ending
                                         ;the script LOUDLY
                                         ;beats running it from
                                         ;a corrupt position
            clc
            rts
:rlbad      sec
            rts

:loop       ldx   CUR_IN_FD              ;Tier 3 `.`: read
                                         ;through whichever fd
                                         ;is currently active,
                                         ;not always fd 0
            jsr   GETC
            bcc   :got
*-- ERR_INTR is not EOF (RULINGS-1 round 2, G1): drop untrapped
*-- pending signals and read on. Only ERR_INTR gets here (H1): a
*-- real EOF (^D) is EOF whatever is parked. A TRAPPED signal
*-- ends the read with an EMPTY line so MAINLOOP's top runs its
*-- trap -- but not over bytes already read (H2): a half-typed
*-- line is finished first and the trap runs after it.
            cmp   #ERR_INTR
            bne   :rleof
            jsr   SIG_RETRY
            bcc   :loop
            lda   CSPTR
            bne   :rleof
            lda   TRAP_PEND
            beq   :rleof
            lda   LINELEN
            bne   :loop
            bra   :haveline
:rleof      lda   LINELEN
            bne   :rlpart                ;partial line before
                                         ;EOF
            sec                          ;nothing at all -- true
                                         ;EOF
            rts
:rlpart     inc   RL_NOCR
            bra   :haveline
:got        cmp   #$8D                   ; CR?
            beq   :haveline
            ldy   LINELEN
            cpy   #LINEMAX
            bcs   :rlbyover              ;too long: the caller
                                         ;refuses it (RL_OVER)
            sta   LINEBUF,y
            inc   LINELEN
            bra   :loop
:rlbyover   sta   RL_X256
            inc   RL_OVER
:haveline   ldy   LINELEN
            lda   #0
            sta   LINEBUF,y
            clc
            rts
