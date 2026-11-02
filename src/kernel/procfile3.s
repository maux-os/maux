*---------------------------------------------------------------
* procfile3.s -- the newest file-call handlers, split out of
* procfile.s 2026-08-21 because that file reached 38,932 bytes
* against real Merlin-8's 41,215-byte source buffer and
* check-dual began failing with `56 MEMORY IN USE`. Same
* reason procfile2.s exists (commit c9c1db1). Nothing here is
* new code -- it is PRC_CLOCK/PRC_CLK_FETCH and the seek
* family, moved verbatim.
*
* SELF-HOSTING IS A SIZE BUDGET, not just a dialect one: the
* dual-assembly gate fails on TOTAL source volume, and it is
* the only gate that can see it. A kernel change that passes
* every functional gate can still break the milestone this
* project exists for.
*---------------------------------------------------------------


*---------------------------------------------------------------
* PRC_CLOCK -- SYS_CLOCK (sc.proc.equ, task 2026-08-21):
* copy the ProDOS Global Page's raw date/time words ($BF90-
* $BF93, ProDOS 8 TRM ch.6 "ProDOS Date and Time Locations")
* into the caller's 4-byte buffer, byte for byte, uninterpreted.
*
* No MLI call backs this: ProDOS has no GET_TIME entry, the
* global page is plain main memory any program may read once
* mapped in -- so this is a maux PROCESS call (sc.proc.equ)
* like SYS_PSTAT, NOT a PRC_FILECALL delegate, and inc/
* sc.file.equ's "file syscall numbers ARE raw MLI opcodes"
* rule does not apply.
*
* docs/PROCIO.md sec 1's "pragmatic kernel, elegant library"
* ruling applies verbatim: hand back the four bytes AS-IS --
* date.s (liba's SC_CLOCK caller) does the legacy/Extended
* validity check and decode, docs/PRODOS-VERSION.md's ruling,
* the same one src/bin/ls.s's PRINTDATE already established.
*
* Freshness caveat (TRM ch.6, artifact d82965d8...f8): ProDOS's
* clock driver refreshes this page only on CREATE/DESTROY/
* RENAME/SET_FILE_INFO/CLOSE/FLUSH -- there is no periodic tick.
* This call reads whatever is CURRENTLY there; it does not force
* a refresh (that would mean a hidden file op on every `date`).
*
* Byte order matches ls.s's DTDATE/DTTIME: offset 0/1 = date
* word (lo/hi); offset 2/3 = time word, MINUTE in the low byte,
* HOUR in the high byte (TRM Figure 6-1, same orientation ls.s
* cites).
*
* Same shape as PRC_GFI/PRC_GETPFX: one dispatch entry (K_DISP
* table -- a low-range maux call, NOT routed through
* PRC_FILECALL above), one parmlist (buffer pointer only --
* process calls carry no param_count byte, syscalls.s's own
* SC_PSTAT comment), one wrapper (PRC_CLK_FETCH) that isolates
* the read, then a targeted BankCopy of the result.
*---------------------------------------------------------------
PRC_CLOCK
            lda   #2              ;buffer pointer, 2 bytes
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+0
            sta   PRC_USER_PTR    ;stash first -- the BankCopy
            lda   PRC_PARM+1      ;below flips banks
            sta   PRC_USER_PTR+1
            jsr   PRC_CLK_FETCH
            jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PRC_CLKBUF
            sta   K_BC_SRCADDR
            lda   #>PRC_CLKBUF
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_USER_PTR
            sta   K_BC_DSTADDR
            lda   PRC_USER_PTR+1
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   #4
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :copied
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:copied     jsr   PRC_RET_OK0
            rts

*---------------------------------------------------------------
* PRC_TICK -- elapsed time (docs/SHELL-GAPS.md sec 5). IN: a
* 2-byte parameter, the caller's buffer pointer. OUT: FIVE bytes
* written there --
*
*   +0        K_TIMER_MODE: 1 mouse VBL, 2 Mockingboard 6522,
*             3 COOP (NO hardware source -- see below)
*   +1..+4    K_VBL_TICKS, 32-bit little-endian
*
* THE MODE BYTE IS THE POINT. In TIMER_MD_COOP the probe armed
* nothing, so the counter is not slow, it is FROZEN -- and a
* caller reading only the count cannot tell "no time has passed"
* from "time does not pass on this machine". A `sleep` that
* polls a frozen counter hangs forever, which is the worst
* outcome available and exactly the class this tree refuses
* elsewhere. Reporting the mode makes the refusal possible in
* userland, where the diagnostic belongs.
*
* THE COUNT IS NOT A DURATION. It is a free-running count of
* SERVICED interrupts since boot; the caller subtracts two
* samples. At 60 Hz the 32-bit counter runs ~2.3 years, where
* the 16-bit one it replaced wrapped every ~18.2 minutes.
*
* Same shape as PRC_CLOCK above -- stage into main, one
* BankCopy out -- for the same reason: the kernel must not
* write a user bank except through that one primitive.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PRC_VCSTAT -- which virtual consoles already have a shell.
* IN: a 2-byte parameter, the caller's buffer pointer. OUT:
* VC_COUNT bytes written there, console 1 first: the pid
* attached to that console, or 0 if nothing is.
*
* ATTACHMENT, NOT BLOCKING, IS THE PROPERTY, and that is the
* whole reason this is a syscall rather than a PSTAT scan in
* userland. PSTAT already reports PCB_WCHAN, so a program can
* see who is asleep on TTY_RD_CHAN+N -- but that is true only
* while the shell sits at its prompt and FALSE for the entire
* time it is running a command, which is exactly when a person
* switches away and later comes back. Answering from the wait
* channel would hand that person a second shell on a console
* that already had one, both then reading the same tty.
*
* fd 0's object byte is FD_DEV_BASE+console for a
* console-attached process in BOTH states, and it is already
* how PRC_TCSETFG identifies its own caller's console
* (procspawn2.s). First attached pid wins: a console with a
* shell AND its foreground child reports the shell, because the
* scan runs upward from pid 1 and the shell is always older.
*---------------------------------------------------------------
PRC_VCSTAT
            lda   #2              ;buffer pointer, 2 bytes
            jsr   PCPI_CALLPARM
            bcc   :vparmsok
            rts
:vparmsok   lda   PRC_PARM+0
            sta   PRC_USER_PTR    ;stash before any bank flip,
            lda   PRC_PARM+1      ;same as PRC_TICK below
            sta   PRC_USER_PTR+1
            jsr   PRC_VCSCAN
            jsr   PRC_SEL_CRBNK
            sta   P_BANK
            bra   :vcopy

*---------------------------------------------------------------
* PRC_VCSCAN -- fill PRC_VCSBUF with the pid attached to each
* console, 0 for none. Split out of PRC_VCSTAT 2026-09-20 so the
* tty can ask the same question: TTY_VC_PEND refuses to move the
* glass to a console with no shell, which is what stops
* Option-N being a one-way trip to a screen nobody can leave.
* LEAVES BANKSEL ON THE ANNEX -- every caller must follow with
* PRC_SEL_CRBNK (learning:01M28001EKW3KDXM109P97AJHH).
* PROCESS CONTEXT ONLY: it walks 47 PCBs.
*---------------------------------------------------------------
PRC_VCSCAN  lda   #0
            ldx   #VC_COUNT-1
:vzero      sta   PRC_VCSBUF,x
            dex
            bpl   :vzero
            lda   #1
            sta   P_PID
:vscan      lda   P_PID
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            lda   #PCB_STATE
            ldx   #1
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH
            beq   :vnext          ;PCB_UNUSED: its fd table is
                                  ;stale, not live -- skipping
                                  ;it is what stops a reaped
                                  ;shell owning a console for
                                  ;ever
            stz   P_FD
            jsr   PRC_GET_FDOBJ
            sec
            sbc   #FD_DEV_BASE
            bcc   :vnext          ;an ordinary file, no device
            cmp   #VC_COUNT
            bcs   :vnext          ;a device, but not a console
            tax
            lda   PRC_VCSBUF,x
            bne   :vnext          ;an older pid claimed it
            lda   P_PID
            sta   PRC_VCSBUF,x
:vnext      inc   P_PID
            lda   P_PID
            cmp   #PCB_COUNT
            bcc   :vscan
            rts

:vcopy      lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PRC_VCSBUF
            sta   K_BC_SRCADDR
            lda   #>PRC_VCSBUF
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_USER_PTR
            sta   K_BC_DSTADDR
            lda   PRC_USER_PTR+1
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   #VC_COUNT
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :vcopied
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:vcopied    jsr   PRC_RET_OK0
            rts

PRC_VCSBUF  ds    VC_COUNT

PRC_TICK
            lda   #2              ;buffer pointer, 2 bytes
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+0
            sta   PRC_USER_PTR    ;stash first -- the BankCopy
            lda   PRC_PARM+1      ;below flips banks
            sta   PRC_USER_PTR+1
            jsr   PRC_TICKFTCH
            jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PRC_TICKBUF
            sta   K_BC_SRCADDR
            lda   #>PRC_TICKBUF
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_USER_PTR
            sta   K_BC_DSTADDR
            lda   PRC_USER_PTR+1
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   #5
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :copied
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:copied     jsr   PRC_RET_OK0
            rts

*---------------------------------------------------------------
* PRC_TICKFTCH -- stage mode + counter into PRC_TICKBUF.
*
* THE FIVE BYTES ARE SAMPLED WITH INTERRUPTS ALREADY MASKED,
* which is what makes them consistent with each other. Kernel
* handlers run interrupt-masked by default (procfd2.s's
* file-wide comment), and that matters more here than it did
* for PRC_CLK_FETCH's four static global-page bytes: this
* counter is incremented BY an interrupt handler, so an
* unmasked read could catch a carry half-propagated -- byte 0
* wrapped to 0 while byte 1 has not yet been bumped, reporting
* a count 256 ticks in the PAST. No bracket is added because
* none is needed; the note is here so nobody adds one, or
* removes the masking this quietly depends on.
*---------------------------------------------------------------
PRC_TICKFTCH
            lda   K_TIMER_MODE
            sta   PRC_TICKBUF
            lda   K_VBL_TICKS
            sta   PRC_TICKBUF+1
            lda   K_VBL_TICKS+1
            sta   PRC_TICKBUF+2
            lda   K_VBL_TICKS+2
            sta   PRC_TICKBUF+3
            lda   K_VBL_TICKS+3
            sta   PRC_TICKBUF+4
            rts

*---------------------------------------------------------------
* PRC_SLPUNTIL -- SYS_SLPUNTIL (docs/SLEEP-1.md): sleep until
* the tick counter reaches an ABSOLUTE target. IN: A/X = a
* 4-byte parameter block, the target, little-endian, on the
* K_VBL_TICKS timeline (SYS_TICK's count plus a delay). OUT:
* A = 0 once the target is reached or already past; carry set
* with ERR_NOSYS when no tick runs (K_TIMER_MODE 0 or 3: the
* counter is FROZEN there, so the call would never return), or
* ERR_INTR for a held signal (PRC_BLCK_RTRY's one delivery
* point, as for every blocking call).
*
* WHY ABSOLUTE. A blocked call REWINDS the user PC and RERUNS
* the whole call on wake (PRC_BLCK_RTRY), and the kernel keeps
* no frame for a sleeper. A relative sleep(N) would restart its
* N on every wake, or need per-pid state. The target needs
* neither: each rerun compares now with it, returns if due, or
* lowers the deadline and blocks again.
*
* V6's DESIGN (sys2.c sslep, clock.c): ONE global earliest
* deadline, K_SLP_DL, that every sleeper lowers and the tick
* hook wakes SLP_CHAN on. The hook (tty.s TTY_TICK) clears
* K_SLP_ARM and wakes; EVERY sleeper reruns; the ones not yet
* due lower the deadline and block again. No per-pid state, so
* nothing to clear at fork or pid reuse, and ^Z/fg is free.
* V6 wakes on equality once a second; we wake on >=, every tick.
*
* WRAP. K_VBL_TICKS is 32-bit and wraps. Both tests are SIGNED
* MODULAR subtractions (the high byte's sign of a - b), valid
* while the two times are under 2^31 ticks apart.
*
* THE INTERRUPT CONTRACT. The tick hook runs from MAIN_IRQ_SHIM
* too, inside the MLI and TTY windows, and writes K_SLP_ARM
* (and wakes). This handler updates the deadline with
* interrupts masked: the syscall is entered masked (ffpage.s
* sei) and this opens no window, and the explicit sei below
* makes that independent of the caller. It stays masked
* through the block (SCH_SLEEP); EXIT_TAIL's rti restores the
* caller's own P.
*---------------------------------------------------------------
PRC_SLPUNTIL
            sei
            lda   #4
            jsr   PCPI_CALLPARM
            bcc   :parmok
            rts
:parmok     lda   K_TIMER_MODE         ;1 mouse, 2 Mockingboard
            dec   a                    ;tick; 0 unprobed and 3
            cmp   #2                   ;COOP never advance it
            bcs   :nosys
            sec                        ;due? now - target >= 0
            lda   K_VBL_TICKS
            sbc   PRC_PARM
            lda   K_VBL_TICKS+1
            sbc   PRC_PARM+1
            lda   K_VBL_TICKS+2
            sbc   PRC_PARM+2
            lda   K_VBL_TICKS+3
            sbc   PRC_PARM+3
            bmi   :future
            jsr   PRC_RET_OK0
            rts
:future     lda   K_SLP_ARM
            beq   :setdl
            sec                        ;target - deadline < 0 ->
            lda   PRC_PARM             ;this sleeper is earlier
            sbc   K_SLP_DL
            lda   PRC_PARM+1
            sbc   K_SLP_DL+1
            lda   PRC_PARM+2
            sbc   K_SLP_DL+2
            lda   PRC_PARM+3
            sbc   K_SLP_DL+3
            bpl   :block               ;the deadline stands
:setdl      ldx   #3
:cpdl       lda   PRC_PARM,x
            sta   K_SLP_DL,x
            dex
            bpl   :cpdl
            inx                        ;X is $FF here:
            inx                        ;+2 = 1, armed
            stx   K_SLP_ARM
:block      lda   #SLP_CHAN
            jsr   PRC_BLCK_RTRY
            rts
:nosys      lda   #ERR_NOSYS
            jsr   PRC_FAIL_A
            rts

*---------------------------------------------------------------
* PRC_CLK_FETCH -- stage the 4 global-page bytes into
* PRC_CLKBUF. No cli/sei bracket, unlike the PMLI_ wrappers in
* procfd2.s: those re-enable interrupts around a slow ProDOS
* MLI call and mask again afterward BECAUSE kernel handlers run
* interrupt-MASKED by default (procfd2.s's file-wide comment
* above PMLI_CRT_CALL). A 4-byte memory read needs no such
* window -- already atomic under that default masking -- so this
* routine's only job is to keep the read in one named place, the
* same structural role PMLI_GFI_CALL plays for GET_FILE_INFO.
* $BF90-$BF93 is ordinary main RAM below $C000, no language-
* card bank switch involved, and kernel code runs with RAMRD/
* RAMWRT already main (mm.hw.equ's "STEADY STATE"), so a
* plain LDA reads it correctly with no softswitch flips needed.
*---------------------------------------------------------------
PRC_CLK_FETCH
            lda   $BF90
            sta   PRC_CLKBUF
            lda   $BF91
            sta   PRC_CLKBUF+1
            lda   $BF92
            sta   PRC_CLKBUF+2
            lda   $BF93
            sta   PRC_CLKBUF+3
            rts

PRC_CLKBUF  ds    4
*-- PRC_TICK's staging buffer: mode byte then the 32-bit count.
PRC_TICKBUF ds    5

PRC_OPEN
            lda   #6
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    jsr   PRC_OPEN_INT   ;OPEN-RO/OAPPEND-1: intent in
            bcc   :ro0             ;param_count -> PRC_ROI; the
            rts                    ;MLI still gets its 3 ($A3
:ro0        jsr   PCPY_MLI_RAW     ;is refused, reported)
            bcc   :pathok
            rts
:pathok     jsr   PRC_DEVOPEN
            bcs   :isfile
            beq   :devfail        ;/DEV path, no such device
            sta   P_TMP2          ;the handle itself is the obj
            jsr   PRC_FND_FR_FD
            bcc   :devfd
            rts
:devfd      sta   P_FD
            lda   K_CURPID
            sta   P_PID
            jsr   PRC_SET_FDOBJ   ;no OFT entry, no io_buffer,
            jmp   PRDOP_RETFD     ;and no MLI call at all
:devfail    rts
:isfile     jsr   VR_XLATE_P     ;virtual -> physical
            bcc   :xlated
            rts
:xlated     jsr   PRC_FILE_FIND  ;already open, resident OR
            bcc   :notpark       ;parked: refuse as ProDOS
            txa                  ;would ($50) -- IB1/IB2 --
            beq   :busy          ;unless the open can SHARE it:
            stx   PRC_ROX        ;every peer has read intent, or
            jsr   PRC_ADMIT      ;one does not, or they all
            bcs   :busy          ;append (OPEN-RW-2, OAPPEND-1:
            ldx   PRC_ROX        ;procfile4.s counts EVERY
            bra   :join          ;entry of the path)
:busy       lda   #MLIE_FILOPEN
            jsr   PRC_FAIL_A
            rts
*-- OPEN-RO join: X = the peer. A lone peer becomes a group
*-- first (its live mark goes to its slot); the new entry takes
*-- the peer's refnum and buffer id, no MLI OPEN, mark 0.
:join       lda   OFT_PIPE,x
            and   #OFTF_MG
            bne   :grp
            lda   OFT_IOBUF,x    ;a parked peer's mark is in its
            beq   :flag          ;slot already
            jsr   PRC_MARK_SAVE
            beq   :flag
            jsr   PRC_FAIL_A
            rts
:flag       ldx   PRC_ROX
            lda   OFT_PIPE,x
            ora   #OFTF_MG
            sta   OFT_PIPE,x
:grp        ldx   PRC_ROX
            lda   OFT_REFNUM,x
            sta   P_TMP
            lda   OFT_IOBUF,x
            sta   PRC_IOBUF_ID
            lda   #OFTF_MG       ;keeps its own intent bit: a
            tsb   PRC_ROI        ;joining writer must not be RO
            jsr   PALOBJ_FILE
            bcc   :objok
            rts
:notpark    jsr   PRC_ALLC_IBF
            bcc   :bufok
            rts
:bufok      sta   PRC_IOBUF_ID
            lda   #<PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHLO
            lda   #>PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHHI
            lda   #0
            sta   PRC_PARM+MLI_IOBUFLO
            lda   PRC_IOBUF_ID
            jsr   PRC_IBF_HI_A
            sta   PRC_PARM+MLI_IOBUFHI
            jsr   PMLI_OPEN_USR
            beq   :openok
            pha
            lda   PRC_IOBUF_ID
            jsr   PRC_FR_IBF_A
            pla
            jsr   PRC_FAIL_A
            rts
:openok     lda   PRC_PARM+MLI_OPEN_REF
            sta   P_TMP                 ;raw ProDOS refnum
            jsr   PALOBJ_FILE
            bcc   :objok
            lda   P_TMP
            jsr   PCLS_RAWREF_A
            lda   PRC_IOBUF_ID
            jsr   PRC_FR_IBF_A
            rts
:objok      sta   P_OBJ
            tax
            lda   PRC_ROI          ;OPEN-RO flags ($80/$C0/0)
            sta   OFT_PIPE,x
            jsr   PRC_OFT_SETP     ;save the reopen path
            jsr   LZ_ARM           ;read keeps the tag
            jsr   PRC_FND_FR_FD
            bcc   :fdok
            lda   P_OBJ
            sta   P_OBJ
            jsr   PRC_DEC_OBJ
            rts
:fdok       sta   P_FD
            sta   PRC_PARM+MLI_OPEN_REF
            lda   P_OBJ
            sta   P_TMP2
            lda   K_CURPID
            sta   P_PID
            jsr   PRC_SET_FDOBJ
            ;-- ROOT-CAUSE FIX (sh.s round): only the ref_num
            ;RESULT
            ;-- field (offset MLI_OPEN_REF) goes back to the
            ;caller --
            ;-- NOT the whole 6-byte parmlist via
            ;PCPO_PARM_LEN.
            ;-- Offsets MLI_PATHLO/HI and MLI_IOBUFLO/HI were
            ;repointed,
            ;-- above, to KERNEL-owned buffers (PRC_PATHBUF;
            ;the
            ; -- allocated iobuf) purely for this call's own MLI
            ;-- dereference -- those are not results, and
            ;copying them
            ;-- back overwrites the CALLER's own copy of its
            ;OPEN
            ;-- parmlist with kernel-internal main-memory
            ;addresses.
            ;-- A caller that only ever builds a fresh pointer
            ;field
            ;-- before every open() (every raw kernel-test
            ;harness in
            ;-- this tree does) never notices; a caller that
            ;reuses ONE
            ;-- static parmlist struct across multiple open()
            ;calls --
            ;-- exactly what liba encourages (cat.s/sh.s's
            ;OPARM-style
            ;-- static parmlists, refreshing only the pathname
            ;buffer's
            ;-- CONTENT via MKPATH, not the parmlist's pointer
            ;FIELD)
            ;-- has its pathname-pointer field silently
            ;corrupted to
            ;-- PRC_PATHBUF after the FIRST open(), so the
            ;SECOND
            ;-- open() through that same struct feeds
            ;PCPY_MLI_PATH
            ;-- a copyin source address that is meaningless in
            ;the
            ;-- CALLER's own bank (reads whatever garbage/zero
            ;byte
            ;-- happens to sit there as a bogus pathname
            ;length),
            ;-- surfacing as a raw MLI $40 (invalid pathname
            ;syntax) on
            ;-- the real, correctly-supplied CREATE that always
            ;precedes
            ;-- it. Found and diagnosed via sh.s's own two-
            ;redirect
            ;-- pipeline gate (`make check-sh`) -- see docs/SH-
            ;DESIGN.md.
PRDOP_RETFD clc
            lda   K_PARMLO
            adc   #MLI_OPEN_REF
            sta   P_PTR1
            lda   K_PARMHI
            adc   #0
            sta   P_PTR1+1
            lda   P_FD
            sta   PRC_BYTE
            jsr   PWRPAR_BYTE
            bcc   :wrote
            rts
:wrote      jsr   PRC_RET_OK0
            rts

PRC_CLOSE
            lda   #2
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+MLI_REF
            cmp   #8
            bcc   :fdok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:fdok       sta   P_FD
            lda   K_CURPID
            sta   P_PID
            jsr   PCLS_ONE_FD
            lda   K_CLSERR             ;OPEN-RW-2: the writer's
            beq   :closed              ;FLUSH or the last CLOSE
            jsr   PRC_FAIL_A           ;failed; the fd is gone
            rts                        ;all the same (Unix)
:closed     jsr   PRC_RET_OK0
            rts

*---------------------------------------------------------------
* PRC_SETMARK/PRC_GETMARK/PRC_GETEOF/PRC_SETEOF -- the seek
* family (docs/FLEET.md "`>>` and the seek family", task
* 2026-08-20). Plain MLI delegates, same shape as PRC_GFI: one
* dispatch entry, one parmlist, one bracketed wrapper each. The
* kernel gains NO Unix-shaped call -- liba's lseek(fd,offset,
* whence) (docs/PROCIO.md sec 1) is what composes these into
* something a program calls.
*
* Caller's parmlist is the SAME 5-byte shape ProDOS's own
* SET_MARK/GET_MARK/SET_EOF/GET_EOF calls use (param_count=2,
* ref_num, 3-byte value) -- except offset 1 carries the
* caller's maux FD, not a raw ProDOS ref_num (same convention
* PRC_READ/PRC_WRITE/PRC_CLOSE already use). PRC_CUR_FDOBJ
* resolves it through the OFT to the real ref_num, which is
* what actually goes out over the wire in PML_SMARK_PRM/
* PML_GMARK_PRM/PML_GTF_PARMS/PML_SEOF_PARM -- never the raw
* MLI parmlist PRC_PARM itself, unlike CREATE/UNLINK/OPEN
* (user), because those have no pointer fields to redirect and
* PRC_OPEN's own long comment (above) is exactly the bug a
* whole-parmlist copyback here would repeat: copying offset 1
* back would silently corrupt the caller's FD field with a raw
* ProDOS ref_num. So GET_MARK/GET_EOF's result copyback is
* BankCopy, targeted at offsets 2..4 only (PRC_GFI's own
* established pattern) -- never the full 5 bytes.
*---------------------------------------------------------------
PRC_SETMARK
            lda   #5              ;param_count + fd + 3-byte
                                  ;position (INPUT)
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+MLI_REF
            sta   P_FD
            jsr   PRC_CUR_FDOBJ
            bcc   :objok
            rts
:objok      cmp   #FD_DEV_BASE
            bcc   :oftobj          ;PRC_CUR_FDOBJ's return value
                                   ;can ALSO be a tty pseudo-fd
                                   ;($80+, sc.devfd.equ) --
                                   ;not an OFT index, same guard
                                   ;PRC_READ uses before ever
                                   ;indexing OFT_TYPE with it
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:oftobj     tax
            lda   OFT_TYPE,x
            cmp   #OFT_FILE
            beq   :isfile
            cmp   #OFT_BLK
            beq   :isblk
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:isblk      jsr   PRC_BLK_SM_G
            rts
:isfile     jsr   PRC_OFT_RES      ;OPEN-RW-2: no mark load,
            bcc   :resid           ;the mark is being REPLACED
            rts                    ;(a virtual one won't load)
:resid
            sta   PML_SMARK_PRM+MLI_REF
            lda   PRC_PARM+MLI_EOFLO
            sta   PML_SMARK_PRM+MLI_EOFLO
            lda   PRC_PARM+MLI_EOFHI
            sta   PML_SMARK_PRM+MLI_EOFHI
            lda   PRC_PARM+MLI_EOFBANK
            sta   PML_SMARK_PRM+MLI_EOFBANK
            stz   PRC_ROX          ;0: no holder to name after
            lda   OFT_PIPE,x
            and   #OFTF_MG
            beq   :go
            cpx   K_ROOWN
            beq   :go
            jsr   PRC_ROSAVE       ;a group member: the holder's
            bne   :smf             ;mark to its slot, then this
:go         jsr   PMLI_SMARK_CL    ;member BECOMES the holder
            bne   :smf             ;(ROX) once the call worked
            ldx   PRC_ROX
            beq   :smok
            stx   K_ROOWN
:smok       jmp   PRC_RET_OK0
:smf        jmp   PRC_FAIL_A

PRC_GETMARK
            lda   #5              ;param_count + fd + 3-byte
                                  ;position (RESULT -- caller's
                                  ;own 3 bytes are ignored on
                                  ;input)
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+MLI_REF
            sta   P_FD
            jsr   PRC_CUR_FDOBJ
            bcc   :objok
            rts
:objok      cmp   #FD_DEV_BASE
            bcc   :oftobj          ;PRC_CUR_FDOBJ's return value
                                   ;can ALSO be a tty pseudo-fd
                                   ;($80+, sc.devfd.equ) --
                                   ;not an OFT index, same guard
                                   ;PRC_READ uses before ever
                                   ;indexing OFT_TYPE with it
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:oftobj     tax
            lda   OFT_TYPE,x
            cmp   #OFT_FILE
            beq   :isfile
            cmp   #OFT_BLK
            beq   :isblk
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:isblk      jsr   PRC_BLK_GM_G
            rts
:isfile     lda   OFT_PIPE,x       ;OPEN-RW-2: a member that
            and   #OFTF_MG         ;does not hold the live
            beq   :live            ;mark answers from its slot:
            cpx   K_ROOWN          ;no swap, no unpark, and a
            beq   :live            ;VIRTUAL mark (past the live
            jsr   PRC_OFT_SLOTP    ;EOF) is still its mark
            ldy   #OFT_SLOT_MRK
:sm         lda   (P_PTR3),y
            sta   PML_GMARK_PRM+MLI_EOFLO-OFT_SLOT_MRK,y
            iny
            cpy   #OFT_SLOT_MRK+3
            bne   :sm
            bra   :gmok
:live       jsr   PRC_OFT_REF
            bcc   :resid
            rts
:resid
            sta   PML_GMARK_PRM+MLI_REF
            jsr   PMLI_GMARK_CL
            beq   :gmok
            jsr   PRC_FAIL_A
            rts
:gmok       jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            clc
            lda   #<PML_GMARK_PRM
            adc   #MLI_EOFLO
            sta   K_BC_SRCADDR
            lda   #>PML_GMARK_PRM
            adc   #0
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            clc
            lda   K_PARMLO
            adc   #MLI_EOFLO
            sta   K_BC_DSTADDR
            lda   K_PARMHI
            adc   #0
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   #3
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :copied
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:copied     jsr   PRC_RET_OK0
            rts

* -- GET_EOF ($D1) is ALREADY wired -- PRC_LD_FL_IMG
* -- (procspawn.s) has used PML_GTF_PARMS/PMLI_GTF_CALL
* -- internally since before this task, to size a spawned image
* -- before its read loop. This handler is its SECOND caller,
* -- exposing the exact same primitive to a syscall instead of
* -- duplicating it -- both run in process context only, on the
* -- one call stack a running process has, so sharing the
* -- kernel-owned parmlist is safe (same non-reentrancy
* -- argument PRC_GFI's own header makes for PML_GFI_PARMS).
PRC_GETEOF
            lda   #5              ;param_count + fd + 3-byte eof
                                  ;(RESULT)
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+MLI_REF
            sta   P_FD
            jsr   PRC_CUR_FDOBJ
            bcc   :objok
            rts
:objok      cmp   #FD_DEV_BASE
            bcc   :oftobj          ;PRC_CUR_FDOBJ's return value
                                   ;can ALSO be a tty pseudo-fd
                                   ;($80+, sc.devfd.equ) --
                                   ;not an OFT index, same guard
                                   ;PRC_READ uses before ever
                                   ;indexing OFT_TYPE with it
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:oftobj     tax
            lda   OFT_TYPE,x
            cmp   #OFT_FILE
            beq   :isfile
            cmp   #OFT_BLK
            beq   :isblk
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:isblk      jsr   PRC_BLK_GE_G
            rts
:isfile     jsr   PRC_OFT_RES      ;OPEN-RW-2: EOF is an FCB
            bcc   :resid           ;value, no member's mark
            rts                    ;(a virtual mark must not
:resid                             ;$4D here: lseek SEEK_END
            sta   PML_GTF_PARMS+MLI_REF
            jsr   PMLI_GTF_CALL
            beq   :geok
            jsr   PRC_FAIL_A
            rts
:geok       jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            clc
            lda   #<PML_GTF_PARMS
            adc   #MLI_EOFLO
            sta   K_BC_SRCADDR
            lda   #>PML_GTF_PARMS
            adc   #0
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            clc
            lda   K_PARMLO
            adc   #MLI_EOFLO
            sta   K_BC_DSTADDR
            lda   K_PARMHI
            adc   #0
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   #3
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :copied
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:copied     jsr   PRC_RET_OK0
            rts

PRC_SETEOF
            lda   #5              ;param_count + fd + 3-byte eof
                                  ;(INPUT)
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+MLI_REF
            sta   P_FD
            jsr   PRC_CUR_FDOBJ
            bcc   :objok
            rts
:objok      cmp   #FD_DEV_BASE
            bcc   :oftobj          ;PRC_CUR_FDOBJ's return value
                                   ;can ALSO be a tty pseudo-fd
                                   ;($80+, sc.devfd.equ) --
                                   ;not an OFT index, same guard
                                   ;PRC_READ uses before ever
                                   ;indexing OFT_TYPE with it
*-- TRUNCATING A CHARACTER DEVICE IS A NO-OP, NOT AN ERROR.
*-- liba's CREAT SET_EOFs every fd it opens (that is how it
*-- truncates by handle instead of UNLINK+CREATE), and sh's
*-- `>` IS CREAT -- so refusing here is precisely what would
*-- make `cmd > /dev/null` fail, with the errno arriving from
*-- a call the user never made. Unix ignores O_TRUNC on a
*-- device for the same reason.
            jmp   PRC_RET_OK0
:oftobj     tax
            lda   OFT_TYPE,x
            cmp   #OFT_FILE
            beq   :isfile
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:isfile     jsr   LZ_DIRTY         ;first write: drop the tag
            jsr   PRC_OFT_REFW
            bcc   :resid
            rts
:resid
            sta   PML_SEOF_PARM+MLI_REF
            lda   PRC_PARM+MLI_EOFLO
            sta   PML_SEOF_PARM+MLI_EOFLO
            lda   PRC_PARM+MLI_EOFHI
            sta   PML_SEOF_PARM+MLI_EOFHI
            lda   PRC_PARM+MLI_EOFBANK
            sta   PML_SEOF_PARM+MLI_EOFBANK
            jsr   PMLI_SEOF_CL
            jmp   PRC_RET_MLI_A

*---------------------------------------------------------------
* PRC_SETFI -- SET_FILE_INFO ($C3), chmod's target (task
* 2026-08-21). Plain MLI delegate, PRC_CREAT's own shape (see
* that routine, procfile.s): the caller's FULL 14-byte input
* struct (param_count + path ptr(2) + access + file_type +
* aux_type(2) + null_field(3) + mod_date(2) + mod_time(2))
* lands straight in PRC_PARM (PCPI_CALLPARM #14), the pathname
* field is repointed at PRC_PATHBUF like every other delegate,
* null_field (3 bytes, TRM: "preserve symmetry between this and
* GET_FILE_INFO") is FORCED to zero regardless of what the
* caller sent (TRM: "should contain zero" -- defense, not
* trust), and the MLI call runs straight against PRC_PARM -- no
* separate PML_ struct (SET_FILE_INFO has no RESULT fields to
* protect from a whole-parmlist copyback, unlike PRC_OPEN/
* PRC_GFI), no copyback.
*
* THE READ-MODIFY-WRITE ITSELF IS NOT HERE. This is a bare
* delegate -- it trusts every field the caller sends. chmod.s
* (the only caller) runs GET_FILE_INFO first and changes only
* the access byte before calling this; a caller that skips that
* step and sends zeroed file_type/aux_type/dates WOULD blank
* them, exactly the class of bug PRC_OPEN's own header warns
* about for a different field. See src/bin/chmod.s's header for
* the read-modify-write proof.
*---------------------------------------------------------------
PRC_SETFI
            lda   #14              ;full 14-byte SFI input --
                                   ;see header
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    jsr   PCPY_MLI_PATH
            bcc   :pathok
            rts
:pathok
* -- aux_type is the load base a retained bank was tagged with,
* -- and chtyp keeps the mtime: the tag must go (lazyfree.s).
            jsr   LZ_INVAL_PB
            lda   #<PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHLO
            lda   #>PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHHI
            stz   PRC_PARM+MLI_SFI_NULL
            stz   PRC_PARM+MLI_SFI_NULL+1
            stz   PRC_PARM+MLI_SFI_NULL+2
            jsr   PMLI_SFI_CALL
            jmp   PRC_RET_MLI_A

* -- PRC_READ/PRC_WRITE (incl. K2's bulk pipe transfer, docs/
* -- PROCIO.md sec 3) moved to procfd.s 2026-08-20 -- this file
* -- was crowding real Merlin's 41215B source buffer (check-
* -- dual) once K2 landed; procfd.s had the room. PRC_FILECALL
* -- above still `jmp`s to both -- kernel modules are one flat
* -- symbol space, same convention as PPP_REQ_LIMIT
* -- (procspawn.s) being called from here.

*---------------------------------------------------------------
* PRC_HALT -- stop the world (SYS_HALT, call 22). ONE parameter
* byte, the mode. It does NOT return: there is no result to
* write back and nowhere to write it, because the caller's
* console stops existing halfway through.
*
* WHY A SYSCALL AND NOT A PROGRAM. Every resource that has to be
* given up is the kernel's: the open ProDOS files, the periodic
* interrupt source, the display switches. A userland `shutdown`
* can ask for those to be released; it cannot release them. So
* `shutdown` owns the words and the exit status of the DECISION
* -- print the message, flush its own stdout -- and this owns
* the machine. Same split as init/`chvt`: the verb is a program,
* the mechanism is a call.
*
* ORDER, and each step is load-bearing in this position:
*
* 1. CLOSE EVERY OPEN FILE FIRST, while interrupts still work
*    and the scheduler still exists, because CLOSE is an MLI
*    call and the MLI is not reentrant. refnum 0 means "all
*    open files" (TRM 4.5.5), so this is one call and not a walk
*    of a table the kernel would have to keep correct. This is
*    the step that makes the DISK consistent -- ProDOS writes
*    back dirty index and directory blocks on close, and a maux
*    that stopped without it would leave a volume that looks
*    fine until the next `ls` of a directory somebody wrote.
*
* 2. QUIESCE THE TIMER -- the DEVICE, not just K_IRQ_HOOK. A
*    source left asserting still wants servicing 60 times a
*    second by whoever owns the machine next, and after step 4
*    that is nobody.
*
*    THROUGH A VECTOR, because timer.s is not in every image.
*    Thirty of the thirty-two kernel .SYSTEM images omit it --
*    only playtest and sertest link a timer at all -- while the
*    dispatch table in kdisp.s references PRC_HALT from all of
*    them, so a direct `jsr TMR_QUIESCE` does not assemble
*    anywhere else (it did not; that is how this was found).
*    K_HALT_TMR is zero unless TIMER_PROBE filled it in, and
*    zero is not a fallback here -- an image with no timer has
*    no timer to quiesce, so skipping is the correct answer
*    rather than a tolerated one. tty.s needs no such treatment:
*    every image has it.
*
* 3. SEI, and mean it. From here there is no handler worth
*    reaching: the hook is an RTS and the scheduler will never
*    run again.
*
* 4. Leave a marker and spin. K_HALT_MARK is what check-shutdown
*    reads to tell "halted deliberately" from "wedged", which
*    are indistinguishable on a screen and from a cycle count --
*    the same job K_BRK_MARKER does for the BRK trap, and the
*    same reason.
*
* IT DELIBERATELY DOES NOT TOUCH THE DISPLAY, and the first
* version did. docs/COVER-OFF.md's sketch of `shutdown` says
* "put the glass back", and a routine to do it was written and
* called from here -- motherboard video, 40 columns, primary
* character set. It made `shutdown` WORSE, measured on the first
* run: the farewell message is written in 80 columns, which
* splits each line between main and aux text memory, so
* dropping to 40 displays every other character of it. "System
* halted -- it is safe to reset." came back as
* "ytmhle -i ssf orst".
*
* The sketch was not wrong, it was about the OTHER verb. Handing
* the glass to a live ProDOS program that is about to run --
* `bye` -- genuinely needs the display back in a state that
* program expects. Halting does not: the person is looking at
* the screen and wants to READ it, and the Ctrl-Reset that
* follows re-initialises the display anyway. The one residue is
* an UltraTerm, which keeps driving the monitor across a reset
* so a rebooting ProDOS paints a screen nobody sees -- but that
* is true of resetting maux at any other moment too, it is
* `vidmode`'s state to own, and fixing it here would mean
* blanking the message this routine just printed.
*
* IT FORCES THE NEXT RESET TO BE A COLD START, and this is the
* step that makes the printed promise true. The claim used to
* be an argument -- maux never took $03F2, so the ROM/ProDOS
* reset path was never displaced -- and the argument was right
* and the conclusion was wrong. Measured 2026-09-21: Ctrl-Reset
* from the halt landed in the MONITOR, at a `*` prompt, which
* for anyone who is not an Apple II hand is a worse dead end
* than the halt they were trying to leave.
*
* The //e ROM decides warm vs cold from the POWER-UP BYTE:
* $03F4 must equal $03F3 EOR $A5 for the reset to be trusted as
* warm and vectored through ($03F2). Anything else is a cold
* start -- reboot from the boot device. So writing a byte that
* cannot match is the whole mechanism, and `eor #$5A` is how:
* $5A is not $A5, so the result differs from the valid one for
* every possible $03F3, with no compare and no branch.
*
* This is the machine's own documented door, not a trick, and
* it is what any ProDOS program does on the way out when it
* wants the next reset to reboot. check-shutdown drives a real
* Ctrl-Reset and waits for a prompt on the other side, because
* "it is safe to reset" is printed on the glass where a person
* will read it, and a promise on the glass is a promise.
*---------------------------------------------------------------
PRC_HALT
            lda   #1              ;the mode byte
            jsr   PCPI_CALLPARM
            bcc   :modeok
            rts                   ;a malformed call is the ONE
                                  ;way back out of this routine
:modeok     lda   #$48            ;'H' -- ordinary syscall-
            bra   PRC_HALT_CORE   ;requested halt, same mark as
                                  ;before this split

*---------------------------------------------------------------
* PRC_HALT_CORE -- the actual "stop the world": close every
* open file, halt the armed timer if any, flip the power-up
* byte for a cold restart, mask interrupts, and spin -- exactly
* PRC_HALT's own body, split out (2026-09-26) so kernel-context
* code with NO syscall frame to read a mode byte from can reuse
* it directly instead of inventing a second halt. PRC_RAMDIS's
* aux-ownership refusal (procmli.s) is the first such caller.
*
* IN: A = the reason byte to record in K_HALT_MARK, BEFORE
* anything else runs -- so a crash partway through this routine
* still leaves the reason readable.
*---------------------------------------------------------------
PRC_HALT_CORE
            sta   K_HALT_MARK
            stz   PML_CLS_PARMS+MLI_REF
            jsr   PMLI_CLS_CALL   ;refnum 0 = every open file
            lda   K_HALT_TMR+1
            beq   :notimer        ;this image links no timer
            jsr   :viatmr
:notimer    lda   $03F3           ;POWER-UP BYTE: make the
            eor   #$5A            ;next Ctrl-Reset a COLD
            sta   $03F4           ;start -- see the header
            sei
:spin       bra   :spin
*-- The 65C02 has no `jsr (abs)`, so the call goes through a
*-- one-instruction thunk: jsr pushes the return, the indirect
*-- jmp transfers, and the target's own rts lands after the jsr.
:viatmr     jmp   (K_HALT_TMR)
K_HALT_MARK ds    1
*-- K_HALT_TMR is DEFINED IN entry2.s, not here, and the reason
*-- is a containment fact: entry2.s zeroes it at INSTALL_COPY,
*-- and three low-level harnesses (bankcopytest, schedtest,
*-- syscalltest) link entry2.s WITHOUT this file. Defining it
*-- here made those three fail to assemble. Every image that
*-- has procfile3.s has entry2.s -- the reverse is not true --
*-- so the definition belongs at the wider end.
