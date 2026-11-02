*---------------------------------------------------------------
* procmli.s -- the MLI call wrappers (the interrupt-bracket
* family).
*
* SPLIT OUT OF procfd2.s (S9 L4, 2026-08-29): that file's own
* stripped text was 19586 B, past `as`'s 16126 B source window,
* so
* it could never be assembled inside maux as one REL module. The
* cut is at a section boundary and this file is `put`
* immediately
* after its parent, so the emitted bytes are unchanged -- which
* is
* what check-bytes asserts.
*---------------------------------------------------------------
*---------------------------------------------------------------
* THE MLI INTERRUPT BRACKET (2026-08-18). Every wrapper below
* runs `cli` before `jsr MLI` and `sei` after it returns: the
* MLI call is the one long, quiescent stretch of kernel time
* (canonical memory config, stable kernel stack -- ProDOS
* demands both of callers anyway), and running it masked LOSES
* things: the level-held IRQ line pends exactly ONE tick, so a
* read longer than 17 ms drops ticks, and the IIe keyboard
* latches exactly ONE key, so type-ahead dies during big I/O.
* With interrupts enabled here, ticks land in MAIN context and
* funnel ROM $FFFE -> $C3FA (the Videx IRQ stub when slot 3
* holds the UltraTerm; internal ROM otherwise -- UT_DETECT's
* fail path guarantees SLOTC3ROM=internal so this never
* fetches floating bus) -> ($03FE) -> MAIN_IRQ_SHIM, which
* acks the timer, polls the keyboard through TTY_TICK, repairs
* the $C800 latch for the disk card, and returns. No scheduling
* happens from that path -- K_NOSWITCH is held across the
* bracket as before, so the quantum stretches during I/O
* rather than a switch being taken out from under ProDOS.
* ProDOS itself is DESIGNED for interrupt-enabled callers (its
* whole receiver machinery exists for them); the unusual caller
* was masked maux, not unmasked maux.
*---------------------------------------------------------------
PMLI_CRT_CALL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   SYS_CREAT
            da    PRC_PARM
            sei
            stz   K_NOSWITCH
            rts

PMLI_RNM_CALL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   SYS_RENAME
            da    PRC_PARM
            sei
            stz   K_NOSWITCH
            rts

PMLI_SPFX_CL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   SYS_SETPFX
            da    PRC_PARM
            sei
            stz   K_NOSWITCH
            rts

PMLI_GPFX_CL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   SYS_GETPFX
            da    PRC_PARM
            sei
            stz   K_NOSWITCH
            rts

PML_DSTRY_CLL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   SYS_UNLINK
            da    PRC_PARM
            sei
            stz   K_NOSWITCH
            rts

PMLI_OPEN_USR
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   SYS_OPEN
            da    PRC_PARM
            sei
            stz   K_NOSWITCH
            rts

PMLI_OPN_CALL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   SYS_OPEN
            da    PML_OPN_PARMS
            sei
            stz   K_NOSWITCH
            rts

PMLI_GPFX2_CL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   SYS_GETPFX
            da    PML_GPFX2
            sei
            stz   K_NOSWITCH
            rts

PMLI_UNPK_CL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   SYS_OPEN
            da    PML_UNPK_PRM
            sei
            stz   K_NOSWITCH
            rts

PMLI_RD_CALL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   SYS_READ
            da    PMLI_RD_PARMS
            sei
            stz   K_NOSWITCH
            rts

PMLI_WR_CALL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   SYS_WRITE
            da    PMLI_WR_PARMS
            sei
            stz   K_NOSWITCH
            rts

PMLI_CLS_CALL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   SYS_CLOSE
            da    PML_CLS_PARMS
            sei
            stz   K_NOSWITCH
            rts

*-- FLUSH ($CD) takes CLOSE's parmlist (count 1, ref_num).
PMLI_FLSH_CL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   $CD
            da    PML_CLS_PARMS
            sei
            stz   K_NOSWITCH
            rts

PMLI_GTF_CALL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   $D1
            da    PML_GTF_PARMS
            sei
            stz   K_NOSWITCH
            rts

* -- SET_MARK ($CE)/GET_MARK ($CF)/SET_EOF ($D0), the other
* -- three of the seek family PMLI_GTF_CALL's GET_EOF belongs
* -- to (docs/FLEET.md "`>>` and the seek family"). Same
* -- interrupt-enabled bracket as every other MLI wrapper in
* -- this file.
PMLI_SMARK_CL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   $CE
            da    PML_SMARK_PRM
            sei
            stz   K_NOSWITCH
            rts

PMLI_GMARK_CL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   $CF
            da    PML_GMARK_PRM
            sei
            stz   K_NOSWITCH
            rts

PMLI_SEOF_CL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   $D0
            da    PML_SEOF_PARM
            sei
            stz   K_NOSWITCH
            rts

* -- READ_BLOCK ($80)/WRITE_BLOCK ($81) wrappers (PMLI_RDBLK_CL/
* -- PMLI_WRBLK_CL) MOVED to procdev.s 2026-09-27 (coordinator
* -- review, DECISION 1 -- module choice replaces
* -- `do ]KSEG_WANT`, which nas cannot assemble at all), `put`
* -- only by a manifest carrying the segment.

* -- task #15 (docs/STICKY.md): GET_FILE_INFO, used by sticky.s
* -- for the raw mod_date/mod_time freshness compare. Same --
* interrupt-enabled bracket as every other MLI wrapper in this
* -- file -- see the file-wide comment above PMLI_CRT_CALL.
PMLI_GFI_CALL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   $C4
            da    PML_GFI_PARMS
            sei
            stz   K_NOSWITCH
            rts

* -- SET_FILE_INFO ($C3), chmod task 2026-08-21. PRC_SETFI
* -- (procfile3.s) builds the parmlist directly in PRC_PARM
* -- (CREATE's own precedent, not a dedicated PML_ struct --
* -- see that routine's header). Same interrupt-enabled bracket
* -- as every other MLI wrapper in this file.
PMLI_SFI_CALL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   SYS_SFI
            da    PRC_PARM
            sei
            stz   K_NOSWITCH
            rts

* -- PPP_GET_BYTE/PPP_PUT_BYTE (the old per-byte pipe ring
* -- accessors) were removed 2026-08-20: K2 (docs/PROCIO.md sec
* -- 3) replaced their only callers (PRC_READ/PRC_WRITE's pipe
* -- branches, below) with bulk BankCopy transfers, and moving
* -- those two routines here (from procfile.s, which was
* -- crowding real Merlin's 41215B source buffer -- check-dual)
* -- left this file with the room they used to occupy.

PRC_READ
            lda   #8
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+MLI_REF
            sta   P_FD
            jsr   PRC_CUR_FDOBJ
            bcc   :objok
            rts
:objok      cmp   #FD_DEV_BASE
            bcc   :oftobj
            cmp   #FD_TTY3+1
            bcc   :istty
            cmp   #FD_NULL        ;/dev/null is always at EOF --
            beq   :eof            ;:eof already reports 0 read
            cmp   #FD_SER0
            beq   :isser
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:isser      jmp   SER_READ
:istty      sec               ;THE HANDLE IS THE CONSOLE. This
            sbc   #FD_DEV_BASE      ;used to validate all four
            sta   TTY_TARGET        ;and then throw away which
            jmp   TTY_READ     ;one it was
:oftobj     tax
            lda   OFT_TYPE,x
            cmp   #OFT_PIPE_R
            beq   :ispipe
            cmp   #OFT_FILE
            beq   :isfile
            cmp   #OFT_BLK
            beq   :isblk
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:isblk      jsr   PRC_BLK_RD_G
            rts
:isfile     jmp   PRC_FILE_READ
:ispipe     lda   OFT_PIPE,x
            sta   P_PIPE
            lda   PRC_PARM+MLI_REQLO
            ora   PRC_PARM+MLI_REQHI
            bne   :want
            stz   PRC_PARM+MLI_TRANSLO
            stz   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts
:want       ldx   P_PIPE
            lda   PIPE_BYTES,x
            bne   :hasdata
            lda   PIPE_WREFS,x
            beq   :eof
            lda   P_PIPE
            clc
            adc   #PIPE_RD_CHAN
            jsr   PRC_BLCK_RTRY
            rts
:eof        stz   PRC_PARM+MLI_TRANSLO
            stz   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts

* -- K2 (docs/PROCIO.md sec 3): bulk pipe read. The ring is one
* -- contiguous 256B page per pipe (PIPE_RNG_SIZE), so RDP/BYTES
* -- being plain bytes means N and the wrap split are ordinary
* -- 8-bit arithmetic -- no per-byte PPP_GET_BYTE/PWRPAR_BYTE
* -- round trips, at most two BankCopy calls (one if the run
* -- doesn't cross the page boundary).
:hasdata    jsr   PPP_REQ_LIMIT
            ldx   P_PIPE
            lda   PIPE_BYTES,x
            cmp   P_COUNT
            bcc   :ravail          ;avail<requested: use avail
            lda   P_COUNT
:ravail     sta   P_TMP             ;P_TMP = N, bytes this call
                                    ;transfers (1..255)

* -- RUN1 = MIN(N, 256-RDP), RUN2 = N-RUN1 (0 unless this
* -- transfer crosses the ring's $xx00 wrap boundary).
            ldx   P_PIPE
            lda   PIPE_RDP,x
            beq   :rnowrap          ;RDP=0: rest of page ahead,
                                    ;never wraps
            lda   #0
            sec
            sbc   PIPE_RDP,x         ;A=256-RDP (RDP in 1..255,
                                     ;fits a byte)
            cmp   P_TMP
            bcs   :rnowrap          ;room >= N -- no wrap
            sta   P_TMP2             ;P_TMP2=RUN1=room to the
                                     ;page boundary
            lda   P_TMP
            sec
            sbc   P_TMP2
            sta   P_IDX               ;P_IDX = RUN2
            bra   :rhaverun
:rnowrap    lda   P_TMP
            sta   P_TMP2             ;RUN1 = N, whole run fits
            stz   P_IDX               ;RUN2 = 0
:rhaverun
            jsr   PRC_SEL_CRBNK
            sta   P_BANK

* -- run 1: ring[RDP..RDP+RUN1) -> caller buf[0..RUN1), bank-to-
* -- bank via BankCopy's own bounce buffer.
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            ldx   P_PIPE
            lda   PIPE_RDP,x
            sta   K_BC_SRCADDR
            lda   P_PIPE
            sec
            sbc   #1
            clc
            adc   #>PPP_RNG_BASE
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_PARM+MLI_BUFLO
            sta   K_BC_DSTADDR
            lda   PRC_PARM+MLI_BUFHI
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   P_TMP2
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :rrun1ok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:rrun1ok    lda   P_IDX
            beq   :rnorun2

* -- run 2 (wrap): ring[0..RUN2) -> caller buf[RUN1..RUN1+RUN2).
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            stz   K_BC_SRCADDR
            lda   P_PIPE
            sec
            sbc   #1
            clc
            adc   #>PPP_RNG_BASE
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            clc
            lda   PRC_PARM+MLI_BUFLO
            adc   P_TMP2
            sta   K_BC_DSTADDR
            lda   PRC_PARM+MLI_BUFHI
            adc   #0
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   P_IDX
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :rnorun2
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:rnorun2

* -- bookkeeping: advance RDP by N (mod 256 -- an 8-bit ADC
* -- wraps exactly at the page boundary), shrink BYTES by N, and
* -- PRC_TRANS = N feeds the SAME tail every path below already
* -- used.
            ldx   P_PIPE
            lda   PIPE_RDP,x
            clc
            adc   P_TMP
            sta   PIPE_RDP,x
            lda   PIPE_BYTES,x
            sec
            sbc   P_TMP
            sta   PIPE_BYTES,x
            lda   P_TMP
            sta   PRC_TRANS
:rddone     lda   PRC_TRANS
            sta   PRC_PARM+MLI_TRANSLO
            stz   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            lda   P_PIPE
            clc
            adc   #PIPE_WR_CHAN
            jsr   SCH_WAKEUP
            jsr   PRC_SEL_CRBNK
            rts

*---------------------------------------------------------------
* PRC_RAMDIS -- reads the /RAM aux-ownership protocol (TRM
* 5.2.2.3, TN #8, TN #26; learning:01KW1GTYH4NRG0F8M7AAT6EG9Z)
* and ACTS on what it reads. Called once from PRC_INIT.
*
* ProDOS auto-installs /RAM over aux $0200-$BFFF -- the same
* aux every process bank lives in -- and its driver runs with
* RAMRD/RAMWRT=aux inside the MLI's interrupts-enabled window.
* A tick taken there vectors to MAIN_IRQ_SHIM's ADDRESS but
* FETCHES the selected process bank's bytes at that address:
* zeros, a BRK grinder -- the bad-volume wedge
* (docs/BADVOL-WEDGE.md; any open naming an offline volume runs
* ProDOS's ON_LINE scan over DEVLST and into that driver).
* Disconnecting the unit removes the only DEVLST driver that
* opens the window -- that is case 4 below, and it is unchanged.
*
* FOUR CASES, not one (2026-09-26 fix -- the operator caught
* this reading the design: this routine used to READ the
* protocol's other two answers and then IGNORE them, proceeding
* to claim aux anyway):
*
*  1. No resident MLI ($BF00 is not a JMP) -- a raw-block boot
*     (processtest et al.) has no protocol to read. PROCEED.
*     Harnesses depend on this; unchanged.
*  2. MLI present, not 128K -- MACHID says no aux memory exists
*     AT ALL. A bank-per-process OS with no banks proceeding
*     here would write process images into nothing. REFUSE.
*  3. MLI present, 128K, /RAM absent from DEVLST -- TN #26's own
*     words: "its absence means other system software owns
*     aux". Proceeding claims a bank another program is already
*     using, silently, underneath it. REFUSE.
*  4. MLI present, 128K, /RAM found -- disconnect, set
*     K_HAD_RAM, proceed. Unchanged from before this fix.
*
* A refusal reuses PRC_HALT_CORE (procfile3.s's PRC_HALT, split
* 2026-09-26 for exactly this: kernel-context code with no
* syscall frame to read a mode byte from) rather than inventing
* a second halt. It cannot print WHY: TTY_WRITE's own path
* (TTY_WR_ENTER's PRC_SEL_CRBNK/annex-struct bracket) depends on
* a live process bank that does not exist yet at PRC_INIT time,
* and the alternative -- banking ROM in to call COUT ($FDED) --
* needs a $C081/$C082-family soft switch check-lc bans tree-wide
* (inc/mm.hw.equ: only $C083/$C08B may ever be written). So the
* reason is a byte, K_HALT_MARK ('A' or 'O' below, in the SAME
* cell and PLACE PRC_HALT's own 'H' already uses) -- readable by
* an emulator peek or a debugger, not by a person at the glass.
* Halting with no visible message is a real cost of refusing
* this early; it is the honest option once printing is off the
* table, not the preferred one.
*
* GUARDED for raw-block boots (processtest et al. load with no
* ProDOS resident): only runs when $BF00 holds the MLI's JMP.
* Poking a bare-RAM global page or calling a nonexistent MLI
* would crash exactly the harnesses that boot rawest.
*
* TN #26: K_HAD_RAM records whether /RAM was present at launch;
* a future QUIT path reinstalls (K_RAM_VEC + K_RAM_DEV) ONLY if
* it is set -- absence at launch means other software owns aux.
* TN #8: the ON_LINE for $B0 (unit_num encoding, NOT DEVLST's
* $BF -- the learning's trap) expects error $28; the error is
* the point, it erases the stale VCB on every ProDOS version.
*
* Global-page constants used ONLY here stay module-local (the
* mli.s spike's own isolation precedent) -- RD_MACHID/RD_MLIENT
* below. RD_DEVCNT/RD_DEVLST/RD_RAMSLT/RD_NODEV moved to
* inc/mm.hw.equ 2026-09-26: procbye.s's PRC_RAMRECONN/
* PRC_RAMREDISC need them too, and nas-librel's own REL-module
* export rule refuses a cross-module equate outside an equ file.
*---------------------------------------------------------------
RD_MACHID   equ   $BF98
RD_MLIENT   equ   $BF00

*-- K_HALT_MARK reason bytes for the two refusal cases below,
*-- in the SAME cell (procfile3.s) PRC_HALT's own 'H' already
*-- uses -- distinct, memorable ASCII, not a new mechanism.
K_HALT_NOAUX equ  $41           ;'A' -- no Aux memory at all
K_HALT_RAMOWN equ $4F           ;'O' -- aux already Owned

PRC_RAMDIS
            php
            sei
            stz   K_HAD_RAM
            lda   RD_MLIENT
            cmp   #$4C            ;no resident MLI: raw boot,
            bne   :done           ;no protocol to read: proceed
            lda   RD_MACHID
            and   #$30
            cmp   #$30
            bne   :noaux          ;not 128K: no aux exists
            ldy   RD_DEVCNT
:scan       lda   RD_DEVLST,y
            and   #$F0
            cmp   #$B0            ;slot 3 drive 2, the TRM's
                                  ;fixed /RAM slot (RD_RAMSLT
                                  ;above is that slot's own
                                  ;vector) -- NOT a type-nibble
                                  ;match: measured 2026-09-26,
                                  ;ProDOS 2.5 uses $B0 here,
                                  ;2.4 uses $BF, so the TN's
                                  ;"$B3/$B7/$BB/$BF family" is a
                                  ;2.4-only fact, not invariant.
            beq   :found
            dey
            bpl   :scan
            bra   :owned          ;/RAM absent: another program
                                  ;already owns aux
:found      lda   RD_DEVLST,y
            sta   K_RAM_DEV
            lda   #1
            sta   K_HAD_RAM
:shift      lda   RD_DEVLST+1,y   ;bubble trailing entries up
            sta   RD_DEVLST,y     ;(the TRM's own pattern)
            beq   :patch
            iny
            bne   :shift
:patch      lda   RD_RAMSLT       ;keep the driver vector for
            sta   K_RAM_VEC       ;the future QUIT reinstall
            lda   RD_RAMSLT+1
            sta   K_RAM_VEC+1
            lda   RD_NODEV
            sta   RD_RAMSLT
            lda   RD_NODEV+1
            sta   RD_RAMSLT+1
            dec   RD_DEVCNT
            jsr   MLI             ;TN #8: expect $28, want $28
            dfb   $C5
            da    RDS_PARMS
:done       plp
            rts
:noaux      lda   #K_HALT_NOAUX
            jmp   PRC_HALT_CORE   ;never returns
:owned      lda   #K_HALT_RAMOWN
            jmp   PRC_HALT_CORE   ;never returns

RDS_PARMS    dfb   2
            dfb   $B0             ;ON_LINE unit_num FORM ($B0,
                                  ;never DEVLST's $BF)
            da    PMLI_XFER_BUF   ;the 512-byte kernel bounce
                                  ;buffer every other
                                  ;synchronous
                                  ;MLI transfer already shares
                                  ;(docs/DEVFS.md, 2026-09-30)
                                  ;--
                                  ;16 bytes of it are used here.
                                  ;RDS_BUF's own dedicated 16
                                  ;bytes retired the same day:
                                  ;neither of this parmlist's
                                  ;PRE-EXISTING callers
                                  ;(PRC_RAMDIS's
                                  ;TN #8 check, PRC_RAMREDISC)
                                  ;ever
                                  ;read the buffer contents --
                                  ;only
                                  ;the MLI's error/status
                                  ;mattered
                                  ;to either of them.

* -- PMLI_ONLN_CL -- ON_LINE ($C5), same interrupt-enabled
* -- bracket as every other PMLI_*_CALL wrapper. MOVED HERE from
* -- procdev.s 2026-09-30 (docs/DEVFS.md): SYS_ONLINE's new
* -- file-call delegate (PRC_ONLINE, procfile4.s) needs it, and
* -- that delegate is linked into every full-kernel image, so
* -- this wrapper must be flat and universal too -- "kernel-wide
* -- now", costing 23 B on every image that did not already
* -- carry it. PRC_RAMREDISC (kbye.s, segment-resident) is
* -- UNCHANGED at its own call site (`jsr PMLI_ONLN_CL`, the
* -- same
* -- cross-file symbol reference as always) but now ALSO sets
* -- RDS_PARMS+1 = $B0 immediately before calling, since this
* -- parmlist's unit_num field is no longer PRC_RAMREDISC's
* -- alone to assume.
*
* A IS PRESERVED across the bank-reselect epilogue now (`pha`
* around the two LCBANK1_RAM reads, `pla` before `rts`) -- ADDED
* 2026-09-30. Neither pre-existing caller ever looked at A on
* return (both only cared about the MLI call's SIDE EFFECT, the
* TN #8 VCB erase), so this was silently free to clobber;
* SYS_ONLINE's delegate is the first caller that needs the real
* MLI status back.
*
* RESELECT (2026-09-27, coordinator review, DECISION 2): the
* ORIGINAL version of this wrapper omitted the post-`sei`
* LCBANK1_RAM reselect its siblings above both have -- the exact
* island hazard learning:01M3G46SEZ3D1RCVJGN39VYE43 describes.
* PRC_RAMREDISC calls this FROM the segment; without the
* reselect, the MLI's own bank-restore heuristic can leave
* LCBANK2_RAM selected on return, unmapping the segment code
* about to execute the very next instruction. See
* docs/DEV-BLOCK-NOTES.md's dated entry for the read that found
* this and the box-sweep confirmation after the fix.
PMLI_ONLN_CL
            lda   #1
            sta   K_NOSWITCH
            cli
            jsr   MLI
            dfb   $C5
            da    RDS_PARMS
            pha                    ;the MLI's own status -- see
                                   ;header, "A IS PRESERVED"
            sei
            stz   K_NOSWITCH
            lda   LCBANK1_RAM
            lda   LCBANK1_RAM
            pla
            rts

K_HAD_RAM   ds    1
K_RAM_DEV   ds    1
K_RAM_VEC   ds    2

* -- PRC_RAMRECONN/PRC_RAMREDISC (the reconnect/redisconnect
* -- mirror of the disconnect just above) live in procbye.s, NOT
* -- here, even though they use this file's own RD_DEVCNT/
* -- RD_DEVLST/RD_RAMSLT/RD_NODEV/RDS_PARMS/K_RAM_DEV/K_RAM_VEC
* -- (plain `equ`s and `ds` cells, visible tree-wide within one
* -- assembly, same as procbye.s already reading K_HAD_RAM
* -- directly). MEASURED, not stylistic: procmli.s is `put` by
* -- all ~32 production kernel images (ordinary MLI wrappers
* -- every image needs), while procbye.s -- via the
* -- PRC_BYE_STUB/K_BYE_VEC indirection (entry.s) -- is linked
* -- ONLY by playtest.s. Code placed here would have grown
* -- every OTHER image's KNOWN_OVERRUN baseline for a mechanism
* -- only `bye` ever calls; placed in procbye.s, it costs
* -- MAUXPLAY.SYSTEM's own PT_HOLD headroom alone, exactly like
* -- the rest of this round's growth.
