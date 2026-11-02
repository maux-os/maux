*---------------------------------------------------------------
* stdio.s -- buffered process I/O streams (docs/PROCIO.md sec
* 4). Own module per #8a: physically its own file, kept separate
* from print.s's print-to-fd call shape. PUT directly by every
* top-level src/bin/*.s program that PUTs print.s (NOT put from
* inside print.s itself -- neither merlin32 nor real Merlin
* nests PUT, docs/TOOLCHAIN.md/commit 004bd02: "INCLUDES ARE A
* TOP-LEVEL CONCERN." Discovered the hard way this round: a
* first draft had print.s PUT this file, which merlin32 silently
* no-oped, leaving SIO_PUTC/EXIT undefined at every caller until
* assembly failed on the first `jsr EXIT`).
*
* PUTC's BODY now lives here, and PUTC's interface (jsr PUTC,
* unchanged) is the one thing this task may not touch, so every
* program that calls PUTC unavoidably carries this module.
* Judged honestly (task instruction's own words): echo DOES
* print, so "give echo a choice to skip it" is not on offer --
* PUTC is not callable without it. What #8a's module boundary
* buys here instead is SEPARATION of concern (this file owns
* buffering; print.s stays about the print-to-fd call shape) and
* an unambiguous audit trail for the two things this task's
* gates check: the LC bank 1 bracket (sec 5) and flush-on-exit
* (sec 4's exit()/_exit() split -- EXIT lives here, SC_EXIT
* stays the raw door in syscalls.s, untouched).
*
* DESIGN:
*
* - Buffering policy is PER-FD, PROBED, V7's own rule
* (2026-08-28, docs/PERF-PLAN.md step 4 -- this replaced the
* original by-fd-NUMBER policy the moment its predicted cost
* showed up in a real profile: one MLI WRITE per 40-char line,
* twice, for a redirected stdout). SIO_MODEOF asks the kernel
* what the fd IS via SYS_FDSTAT (the isatty-equivalent syscall
* the original design said to revisit for -- it landed for sh's
* interactive probe): a DEVICE/tty line-buffers (flush on CR,
* $8D), a FILE or PIPE full-buffers (flush at BUFSIZ), and
* stderr (fd 2) is pinned to line mode unconditionally. The
* probe result is cached in SIO_MODE (libabss.s, kernel-zeroed
* page) and invalidated by FCLOSE; line mode is the fallback
* for a failed probe -- conservative: it only flushes MORE
* often, never less.
*
* - Buffer lives in LC bank 1 (PRC_LC_BANK1, $D000-$DFFF, sec 5)
* -- 8 streams x 512B (BUFSIZ) = 4096B, the whole page, matching
* sec 4's own "eight streams fit the page." Addressed by fd:
* fd's buffer occupies pages $D0+2*fd/$D1+2*fd (BASE_HI_TABLE).
*
* - CRITICAL FINDING (not in PROCIO.md before this task,
* verified   by reading src/kernel/entry2.s's
* CPILC_SRC/CPOLC_SRC, not   guessed): copyin/copyout REFUSES
* any process address >=$D000   outright (K_CPY_ERR=2, "LC path
* not wired yet" -- the comment   there literally says so). So a
* syscall's data_buffer field   can NEVER point into LC bank 1
* -- the kernel would refuse the   whole call. This means
* SC_WRITE cannot read the LC-bank1   buffer directly; flush
* must first copy the pending bytes into   ORDINARY process RAM
* (SIO_STAGE, 512B, this file's own `ds`)   via plain
* same-process (zp),Y addressing (no cross-bank   primitive
* needed -- LC bank 1, once selected, IS this   process's own
* address space, the same CPU, no kernel   involved), THEN issue
* one SC_WRITE against that ordinary-RAM   pointer. Cost: one
* extra 512B footprint in ordinary process   RAM (SIO_STAGE)
* beyond the "free" 4096B in LC bank 1 -- still   a large net
* win over 8 separate 512B ordinary-RAM buffers   (4096B) the
* naive alternative would cost, since only ONE   stage buffer is
* needed (flush is sequential, never concurrent   across fds).
*
* - THE ERROR PATH (2026-08-24; docs/PROCIO.md sec 4a). A failed
* SC_WRITE used to be swallowed here, and the comment saying so
* cited "no v1 util checks PUTC's carry today either" as the
* reason -- which was true and was the bug: check-writefail
* found THREE pinned defects that were all this one routine.
* `tee` onto a locked file exited 0, `ed`'s `w` printed no `?`,
* and `echo REDIR > FILE` on a full volume left `$?` at 0.
*
* PUTC's interface is still silent -- deliberately. Making PUTC
* return a carry would touch every call site in 33 programs to
* fix a condition almost none of them can act on per byte.
* Instead the error is STICKY, per fd, in SIO_ERR: the first
* failed flush records the errno, and it is delivered at one of
* the two places a program has something useful to do with it:
*   FCLOSE -- carry set, A = errno, for a file the program named
*             and can therefore name in a diagnostic;
*   EXIT   -- a zero status becomes EXIT_WRFAIL, so a stream
*             nobody closed (stdout, redirected by the shell)
*             still reaches `$?`.
* That is stdio's own ferror/fclose shape, and it is why the fix
* is ~60 bytes of liba rather than an edit to every util.
*
* - Sec 5's invariant, applied narrowly: bank 1 is selected only
* for the single indexed store (SIO_PUTC) or the copy loop
* (SIO_CPY inside SIO_FLUSH), and bank 2 is restored
* immediately after, in the SAME leaf routine, with no syscall
* ever issued in between. The window with bank 1 selected never
* crosses a `jsr SC_*`/$FF00 call -- see docs/PROCIO.md sec 5's
* gate (d) and scripts/check_bufio.py's deliberate violator for
* the proof this bracket is load-bearing.
*---------------------------------------------------------------

* -- Language-card bank-select soft switches. FIXED A REAL BUG
* -- this task's own gate (d) caught (docs/PROCIO.md's dated
* -- results section has the full story): a first draft used
* -- $C08B for this buffer, on the Sather-table assumption
* -- "$C08B = bank 1 = the free one." $C08B is NOT free --
* -- src/kernel/entry.s's INSTALL_COPY, src/kernel/mli.s's
* -- INSTALL_IRQ, src/kernel/ timer.s, and
* -- src/kernel/procspawn.s ALL write-enable mm.hw.equ's
* -- LCBANK2_RAM ($C08B, comment: "STEADY STATE") to patch/use
* -- ProDOS's OWN resident code, which "keeps executing FROM
* -- this same LC bank" (mli.s's own words) -- and src/bin/as.s
* -- documents WHY the confusion is easy: "the two codebases'
* -- bank-1/bank-2 NAMES are swapped relative to each other (a
* -- real, documented Apple II LC naming inversion), but the
* -- ADDRESS matches" (Merlin's own ASM_ENTRY calls $C08B
* -- "BANK1"; this project's mm.hw.equ calls the SAME
* -- ADDRESS "LCBANK2"). The first draft trusted the generic
* -- hardware name over this codebase's own, repeatedly-proven
* -- convention -- this task's own gate (d) initially reported
* -- the violator completing CLEANLY (should have been
* -- impossible if $C08B were truly free), which is what
* -- surfaced the inversion: selecting "the free bank" and
* -- skipping the restore was harmless because $C08B/bank2 IS
* -- what ProDOS already expects. Fixed to use mm.hw.equ's
* -- own LCBANK1_RAM/LCBANK1_STORE ($C083/$C080 -- the genuinely
* -- unallocated bank) for this buffer, restoring LCBANK2_STORE
* -- ($C088, single read -- the exact idiom mli.s's INSTALL_IRQ
* -- uses to restore ProDOS's own write-protected steady state)
* -- before any syscall. Declared locally (not `put
* -- ../../inc/mm.hw.equ`) to avoid a new put-list edit
* -- across every src/bin/*.s consumer -- see docs/PROCIO.md's
* -- results section for the reasoning and the risk this carries
* -- (two independent spellings of the same four addresses now
* -- exist in the tree; a future drift-check belongs on the next
* -- task's plate). Read-triggered (a bare LDA flips the
* -- switch); the RW addresses need TWO consecutive reads to
* -- latch write- enable (learning:01M0ASR4PKGFNSBVCFTZN61DGX;
* -- the ProDOS 8 TRM's own bootstrap listing does the identical
* -- double-read).
* LC_FREE_RW: def moved to stdio.equ (REL rule)
                                 ;LC page (mm.hw.equ's
                                 ;LCBANK1_RAM) -- read+write
                                 ;(double-read to enable write)
* LC_KRN_RW: def moved to stdio.equ (REL rule)
                                 ;owned LC page (mm.hw.equ's
                                 ;LCBANK2_STORE) read-only/
                                 ;protected -- the STEADY STATE
                                 ;every syscall expects

* -- BUFSIZ (512, one ProDOS block, matching K1's
* -- PMLI_XFR_SIZE) moved to src/liba/libabss.s with SIO_STAGE,
* -- the only thing that used it (docs/STICKY.md sec 21). No
* -- code here references it -- the full-buffer trigger below
* -- tests CNT_HI against 2, which is BUFSIZ/256 written out.

* -- EXIT's status for "your output did not get written". 1 is
* -- the v1 general-failure status every util already uses (see
* -- grep.s's no-match 1 vs usage 2 split), and a write failure
* -- is a general failure, not a usage error. Spelled once here
* -- because check_writefail.py asserts the number.
* EXIT_WRFAIL: def moved to stdio.equ (REL rule)

* -- SIO_MODE's values (the cell itself is in libabss.s's
* -- kernel-zeroed page; 0 = not yet probed). V7's own stdio
* -- policy, decided per fd by ASKING THE KERNEL what the fd is
* -- (SYS_FDSTAT, maux's isatty) instead of by fd NUMBER: a
* -- console/tty flushes on CR so interactive output appears per
* -- line; a file or pipe flushes at BUFSIZ so a 208-file strip
* -- doesn't pay one MLI WRITE per 40-character line
* -- (docs/PERF-PLAN.md step 4). stderr (fd 2) is pinned to
* -- SIOM_LINE unconditionally -- POSIX's "never fully
* -- buffered", and the ordering e2e's `2>&1` merges rely on.
* SIOM_LINE: def moved to stdio.equ (REL rule)
* SIOM_FULL: def moved to stdio.equ (REL rule)

* -- fd's LC-bank1 buffer base page, indexed by fd (0-7,
* -- PCB_FDTABLE's own size) -- fd*2 pages from $D000, low byte
* -- always 0 (BUFSIZ is page-aligned).
BASE_HI_TABLE
            dfb   $D0,$D2,$D4,$D6,$D8,$DA,$DC,$DE

*---------------------------------------------------------------
* SIO_PUTC -- PUTC's real body. IN: A = byte, X = fd. Appends to
* fd's LC-bank1 buffer; flushes on a policy trigger (CR for fd
* 0-2, full 512B for fd 3+). CLOBBERS: A, X (matches PUTC's
* pre-existing contract -- the OLD PUTC body already clobbered X
* setting up SC_WRITE's parmlist pointer). Y is PRESERVED --
* found the hard way (docs/PROCIO.md's dated results): the OLD
* PUTC never touched Y at all, so callers are entitled to use Y
* as their OWN loop index across `jsr PUTC`
* (src/test/bufwriter.s does exactly this); this routine needs
* Y=0 internally for its own indirect store, so it must
* save/restore it explicitly rather than silently reset the
* caller's Y to 0 on every call.
*---------------------------------------------------------------
SIO_PUTC    sta   SIO_BYTE
            stx   SIO_FD
            phy                            ;caller's Y -- see
                                          ;header, PRESERVED
*-- The mode probe MUST precede the buffered store now: the
*-- store's address comes from the geometry tables SIO_MODEOF
*-- fills. (Caught by check-bufio's byte-exact gate (c) on this
*-- change's first run: a PUTC-first stream's opening byte went
*-- through all-zero geometry to $0000.) The syscall inside the
*-- probe is legal here -- no LC bank is selected yet.
            lda   SIO_MODE,x
            bne   :geook
            jsr   SIO_MODEOF               ;X preserved
:geook

            lda   LC_FREE_RW                ;select bank 1,
            lda   LC_FREE_RW                ;read+write (double-
                                          ;read idiom)

            ldx   SIO_FD
            lda   SIO_BASELO,x            ;16-bit base + count:
            clc                           ;the stage owner's
            adc   SIO_CNT_LO,x            ;buffer (SIO_MODEOF's
            sta   STG_PTR                 ;stage-owner note) is
            lda   SIO_BASEHI,x            ;NOT page-aligned; an
            adc   SIO_CNT_HI,x            ;LC fd's BASELO is 0
            sta   STG_PTR+1               ;and this reduces to
                                          ;the old page math
            ldy   #0
            lda   SIO_BYTE
            sta   (STG_PTR),y             ;the buffered store --
                                          ;this process's OWN
                                          ;bank, no kernel
                                          ;involved

            inc   SIO_CNT_LO,x
            bne   :nocarry
            inc   SIO_CNT_HI,x
:nocarry

            lda   LC_KRN_RW              ;reselect bank 2 --
                                          ;IMMEDIATELY, before
                                          ;anything else runs
                                          ;(sec 5's bracket)

            ldx   SIO_FD
            lda   SIO_MODE,x              ;flush policy is the
                                          ;fd's PROBED mode
                                          ;(guaranteed set: the
                                          ;probe ran before the
                                          ;store above)
            cmp   #SIOM_FULL
            beq   :fullmode
            lda   SIO_BYTE
            cmp   #$8D                    ;CR -- Apple II line
                                          ;end, high-bit-set
                                          ;(matches
                                          ;echo.s/cat.s's own
                                          ;$8D convention)
            bne   :nofl
            jsr   SIO_FLUSH               ;X = fd, still
                                          ;SIO_FD's value
            bra   :nofl
:fullmode   lda   SIO_CNT_HI,x
            cmp   SIO_LIMHI,x             ;per-fd trigger: 2 (an
                                          ;LC fd's 512) or
                                          ;STGSIZE/256 for the
                                          ;stage owner
            bne   :nofl
            jsr   SIO_FLUSH               ;X still = fd
:nofl       ply                            ;restore caller's Y
                                          ;(see header)
            rts

*---------------------------------------------------------------
* SIO_MODEOF -- decide (and cache) fd X's buffering mode.
* IN: X = fd. OUT: A = SIOM_LINE or SIOM_FULL, SIO_MODE,x set;
* X preserved. CLOBBERS: Y (the syscall does).
*
* stderr is pinned SIOM_LINE without asking. Everything else is
* one SYS_FDSTAT: a DEVICE byte (>= FD_DEV_BASE -- the high bit
* is isatty) buffers by line; FDST_FILE and both pipe tags
* buffer fully, exactly V7 stdio's not-a-tty rule. A probe
* error (racing close) falls back to SIOM_LINE -- the
* conservative mode: never wrong, only slower. NEVER call with
* the LC bank-1 buffer page selected -- this issues a real
* syscall (sec 5's bracket rule).
*
* The one staleness hazard, named: SC_CLOSE/SC_DUP2 issued
* DIRECTLY (not via FCLOSE, which clears the cache below) can
* re-target an fd after its mode was probed, and the stale mode
* survives until process exit. Today's utils re-target fds only
* before their first write (sh stages child fds pre-spawn, so a
* fresh process always probes fresh); the trigger for revisiting
* is the first util that dup2's an fd it has already written
* through stdio.
*---------------------------------------------------------------
SIO_MODEOF  cpx   #2
            beq   :line                   ;stderr: never full
            stx   SIO_FDPARM              ;the 1-byte parmlist
            phx
            lda   #<SIO_FDPARM
            ldx   #>SIO_FDPARM
            ldy   #SYS_FDSTAT
            jsr   $FF00
            plx                           ;carry survives PLX; N
                                          ;does NOT -- it now
                                          ;reflects the pulled X
            bcs   :line                   ;probe failed: slow,
                                          ;not wrong
            ora   #0                      ;re-establish N from A
                                          ;(the fdstat result)
            bmi   :line                   ;>= FD_DEV_BASE: a
                                          ;DEVICE -- isatty says
                                          ;line-buffer
            lda   #SIOM_FULL              ;file or pipe
            bra   SIO_STMODE
:line       lda   #SIOM_LINE
*-- SIO_STMODE -- store mode A for fd X and lay out its buffer.
*-- Global (not :store) so SIO_SETFULL below can enter it.
SIO_STMODE  sta   SIO_MODE,x
*-- Buffer geometry rides along with the mode. THE STAGE OWNER:
*-- the FIRST fd probing FULL claims SIO_STAGE (ordinary RAM,
*-- STGSIZE bytes) as its buffer -- its stores need no LC
*-- bracket to matter, its flush skips the LC->stage copy
*-- (SIO_FLUSH's :ramdirect), and its bigger size halves the
*-- write syscalls. Every other fd keeps its LC bank-1 pages.
*-- For a util with one redirected stdout -- the whole
*-- self-hosting strip -- the owner is stdout.
            cmp   #SIOM_FULL
            bne   :geolc
            lda   SIO_STGOWN
            bne   :geolc                  ;stage already claimed
            txa
            clc
            adc   #1
            sta   SIO_STGOWN              ;owner = fd+1
*-- The owner gets the stage's UPPER half only: the LOWER
*-- BUFSIZ bytes stay the LC fds' flush BOUNCE (SIO_CPY's
*-- destination), and an owner based at SIO_STAGE+0 is
*-- clobbered the moment any OTHER fd flushes -- check-writefail
*-- caught exactly that (one payload byte overwritten by the
*-- locked file's own FCLOSE flush, 2026-08-28). A truly
*-- separate owner buffer (and the write-halving a bigger one
*-- buys) waits on as.s's symbol-window headroom.
            lda   #<SIO_STGB2        ;=STAGE+BUFSIZ, split
            sta   SIO_BASELO,x
            lda   #>SIO_STGB2        ;label -- REL offset rule
            sta   SIO_BASEHI,x
            lda   #2
            sta   SIO_LIMHI,x
            lda   SIO_MODE,x              ;contract: A = mode
            rts
:geolc      lda   #0
            sta   SIO_BASELO,x
            lda   BASE_HI_TABLE,x
            sta   SIO_BASEHI,x
            lda   #2
            sta   SIO_LIMHI,x
            lda   SIO_MODE,x
            rts

*---------------------------------------------------------------
* SIO_SETFULL -- fd X buffers FULLY, tty or not: a batch
* program's setbuf. Call BEFORE the fd's first write (it
* replaces the probe; it does not re-home a live buffer). Why a
* program would: the console scrolls once per write() burst
* (jump scroll, tty4.s / tty8.s) but line buffering hands the
* kernel one line per call, so a 48-line `ls` paid 26 full-
* screen scrolls -- 15k cycles each on 40 columns, 36k on
* native 80 -- where three writes would pay three. V7's rule
* that a terminal flushes per line is right for a program that
* converses; it is wrong for one that prints a batch and exits,
* and V7 let such a program say so. 2026-09-03, CONSOLE-OPT 8.
*---------------------------------------------------------------
SIO_SETFULL lda   #SIOM_FULL
            jmp   SIO_STMODE

*---------------------------------------------------------------
* SIO_PUTSB -- bulk-append a NUL-terminated string to fd X's LC
* buffer (PUTS's SIOM_FULL path -- docs/PERF-PLAN.md step 4).
* One LC bank bracket per CHUNK instead of SIO_PUTC's per BYTE:
* ~22 cyc/byte against ~85. Chunks are cut at the buffer's next
* 256-byte boundary, so the copy loop shares ONE Y index between
* (PTR0),y and (STG_PTR),y and can never cross out of the fd's
* current buffer page. SIO_PBLEN = chunk length, where 0 MEANS
* 256 (the cpy/bne exit sees Y wrap). Flush trigger is
* SIO_PUTC's own (CNT_HI == 2 <=> 512 buffered), checked with
* the bank RESTORED -- SIO_FLUSH syscalls (sec 5's bracket).
* IN: X = fd, PTR0 = string. OUT: carry clear (buffered errors
* are deferred to SIO_ERR, same as PUTC's). CLOBBERS: A, X, Y,
* PTR0 (PUTS declares PTR0 volatile).
*---------------------------------------------------------------
SIO_PUTSB   stx   SIO_FD
:outer      ldx   SIO_FD
            lda   SIO_CNT_HI,x
            cmp   SIO_LIMHI,x
            bne   :room                   ;full before we start
            jsr   SIO_FLUSH               ;-- flush, then retry
            bra   :outer
:room       lda   #0
            sec
            sbc   SIO_CNT_LO,x            ;bytes to the page
            sta   SIO_PBLEN               ;boundary; 0 means 256

            lda   LC_FREE_RW              ;select bank 1 (RW,
            lda   LC_FREE_RW              ;double-read idiom --
                                          ;harmless for the
                                          ;stage owner: its
                                          ;stores are below
                                          ;$C000 either way)
            lda   SIO_BASELO,x            ;16-bit base + count
            clc                           ;(see SIO_PUTC's note)
            adc   SIO_CNT_LO,x
            sta   STG_PTR
            lda   SIO_BASEHI,x
            adc   SIO_CNT_HI,x
            sta   STG_PTR+1
            ldy   #0
:cp         lda   (PTR0),y
            beq   :strdone
            sta   (STG_PTR),y
            iny
            cpy   SIO_PBLEN
            bne   :cp

*-- chunk filled to the page boundary, string not done: the new
*-- count is exactly the boundary (LO=0, HI+1), and PTR0 steps
*-- by the chunk length (Y, except Y=0 here means 256).
            lda   LC_KRN_RW               ;reselect bank 2 FIRST
            stz   SIO_CNT_LO,x
            inc   SIO_CNT_HI,x
            tya
            clc
            adc   PTR0
            sta   PTR0
            bcs   :ptrhi                  ;carry from the add..
            cpy   #0
            bne   :ptrdone                ;..or Y=0 = 256 copied
:ptrhi      inc   PTR0+1
:ptrdone    lda   SIO_CNT_HI,x
            cmp   SIO_LIMHI,x
            bne   :outer
            jsr   SIO_FLUSH               ;X still = fd
            bra   :outer

:strdone    lda   LC_KRN_RW               ;reselect bank 2 FIRST
            tya                           ;NUL hit: Y bytes went
            clc                           ;into the buffer
            adc   SIO_CNT_LO,x
            sta   SIO_CNT_LO,x
            bcc   :endfl
            inc   SIO_CNT_HI,x
:endfl      lda   SIO_CNT_HI,x
            cmp   SIO_LIMHI,x
            bne   :endok
            jsr   SIO_FLUSH
:endok      clc
            rts

