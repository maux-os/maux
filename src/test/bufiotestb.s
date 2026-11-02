*---------------------------------------------------------------
* bufiotestb.s -- image body for bufiotest.s. Split out so the
* top-level stays a thin MANIFEST (learning:01M051EM2HQ3ZVJTR1
* W9P3G86J), same convention as every other *testb.s in this
* tree.
*
* PHASE C (docs/PROCIO.md sec 6 gate (c), "exit flushes"):
* CREATE /mnt/MAUX/BUFOUT, spawn the real ProDOS-staged
* /bin/BUFWR (src/test/bufwriter.s, built via liba's own
* EXIT/PUTC), wait for it, then OPEN/READ BUFOUT back and record
* the bytes. bufwriter writes 5 bytes via PUTC with NO explicit
* flush and NO CR in the payload -- BUFOUT must contain exactly
* those 5 bytes after the child's plain EXIT(0), or EXIT's
* flush-on-exit is broken. R_C_DONE=$AA marks this phase
* complete BEFORE phase D runs, so a phase-D hang (expected --
* see below) can never erase phase C's already-gathered
* evidence.
*
* PHASE D (docs/PROCIO.md sec 5 invariant / sec 6 gate (d)): a
* DELIBERATE violator. Selects LC_FREE_RW ($C083, the process's
* own free LC page -- mm.hw.equ's LCBANK1_RAM) and does NOT
* reselect LC_KRN_RW ($C08B) before issuing a real MLI call
* (SYS_OPEN of the already-CREATEd BUFOUT -- routes through
* P8_DELEGATE to real ProDOS's own $D000-resident dispatcher,
* proven reachable by phase C's own CREATE/OPEN/READ calls
* above) while bank 1 is still selected. docs/PROCIO.md sec 5
* predicts a LOUD failure (garbage execution or a visibly wrong
* result) per its own accepted proof ("run a deliberate violator
* and require a loud failure").
*
* MEASURED RESULT (this task, both address pairs tried): the
* violator completes CLEANLY every time -- first with the
* (buggy, since-fixed) $C08B/$C080 pair, which turned out not to
* violate anything (see LC_FREE_RW/LC_KRN_RW's own header
* below), and AGAIN after the fix, with $C083 left selected
* across a real SYS_GETPFX AND a real SYS_OPEN. A same-run
* diagnostic (removed once explored, see git history)
* snapshotting $D000-$D007 in MAIN memory (ALTZP still main,
* before any process runs) under each bank showed IDENTICAL
* bytes ($A0 x8) for both LC_FREE_RW and LC_KRN_RW at that
* narrow offset -- inconclusive on its own (could mean the two
* MAIN LC banks are genuinely identical there, or that the real
* divergence lives at a different offset this task did not
* sweep). NOT reported as a pass: scripts/check_bufio.py still
* reports gate (d) FAIL when the violator completes cleanly, per
* PROCIO.md sec 6's own reasoning (a silently-successful
* violator means the hazard is not demonstrated, which is itself
* the finding worth surfacing rather than papering over).
* ANSWERED 2026-09-20, and the probe was never going to be
* loud: ProDOS's OWN MLI entry re-selects its bank on EVERY
* call. Read live off the bus at $BFC0: `LDX $E000 / LDA
* $D000` (it samples the caller's READ orientation, which is
* all the hardware lets anyone read back) then `BIT $C08B`
* twice -- bank select AND write-enable, unconditionally,
* before it jumps to the dispatcher. A violator that leaves
* the wrong bank selected across an MLI call therefore CANNOT
* fail: ProDOS fixes it first. The sec 5 invariant still
* holds for anything touching $D000-$DFFF WITHOUT going
* through ProDOS -- which is where the real race lives, and
* it is a scheduler problem, not a syscall one.
* See docs/LANGUAGE-CARD.md.
* Flagged as an open risk for whoever picks this up next -- see
* docs/PROCIO.md's dated results section for the full writeup
* and next-step suggestions (sweep more of the $D000-$DFFF
* range, or try a disk-cache-cold OPEN/READ that forces an
* actual SmartPort block transfer rather than one that might be
* served from ProDOS's own in-memory buffers).
*---------------------------------------------------------------

* -- LC bank-select soft switches -- same idiom/citation/FIX as
* -- src/liba/stdio.s's own copy (this file is a raw kernel
* -- harness, does not put liba, so declared again locally):
* -- $C083 is the process's own FREE LC page (mm.hw.equ's
* -- LCBANK1_RAM), $C088 is ProDOS/the kernel's OWN page
* -- (LCBANK2_STORE) -- see stdio.s's header for the full story
* -- of how this task's first draft had these swapped, and how
* -- this gate's own "the violator completed cleanly" result on
* -- the WRONG address pair is what surfaced the bug.
LC_FREE_RW  equ   $C083
LC_KRN_RW   equ   $C08B

* Result/scratch addresses in the parent process bank.
BUFOUT_PATH equ $1000        ;MLI pathname, 14 bytes (1 count +
                             ;13 chars)
BUFWR_PATH  equ $1020 ;liba string "/bin/BUFWR", spawn
                             ;path
BUFWR_ARG0  equ $1040        ;liba string "BUFWR", argv[0]
CREATE_PARM equ $1060
OPEN_PARM   equ $1080
CLOSE_PARM  equ $1090
READ_PARM   equ $10A0
WAIT_PARM   equ $10B0
SPAWN_PARM  equ $10C0
ARGV_ARR    equ $10D0        ;4 bytes: argv[0] ptr, argv[1]=0/0
GPPARM      equ $10E0        ;phase D's violating call's own
                             ;parmlist -- shaped as OPEN's 6
                             ;bytes (count+path+iobuf+ref), NOT
                             ;GET_PREFIX's 3 (see phase D's own
                             ;comment for why the call changed)
PFXBUF      equ $10F0        ;unused by phase D now -- kept as a
                             ;spare scratch region, harmless
IO_BUF      equ $1300        ;PAYLOAD_LEN-byte read-back staging

R_SPAWN_PID equ $1200
R_WAIT_PID  equ $1201
R_STATUS    equ $1202
R_OUT_FD2   equ $1203
R_TRANS     equ $1204        ;2 bytes
R_DATA      equ $1206        ;PAYLOAD_LEN bytes
PAYLOAD_LEN equ 5
R_C_DONE    equ $1220        ;phase C completion marker
R_D_DONE    equ $1221        ;phase D completion marker (NOT
                             ;expected to ever be set -- see
                             ;header)
R_D_ERR     equ $1222        ;carry-set path's errno, if phase D
                             ;somehow returns cleanly
R_DONE      equ $1290
R_ERR       equ $1291
R_STEP      equ $1292

*---------------------------------------------------------------
* Boot helpers -- identical shape to catreadtestb.s's own (same
* BankCopy-via-main bounce, same page-1 frame patch).
*---------------------------------------------------------------
BOOT_CPY_PAR
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PARENT_PROC
            sta   K_BC_SRCADDR
            lda   #>PARENT_PROC
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #<PARENT_PROC
            sta   K_BC_DSTADDR
            lda   #>PARENT_PROC
            sta   K_BC_DSTADDR+1
            lda   #1
            sta   K_BC_DSTBANK
            lda   #<PAR_PROC_LEN
            sta   K_BC_LEN
            lda   #>PAR_PROC_LEN
            sta   K_BC_LEN+1
            jsr   BankCopy
            rts

PATCH_PAR_FRM
            lda   #1
            sta   BANKSEL
            sta   ALTZPAUX
            lda   #<PARENT_PROC
            sta   $01FE
            lda   #>PARENT_PROC
            sta   $01FF
            sta   ALTZPMAIN
            rts

NOIRQ       rts

ENTRY       sei
            cld
            ldx   #$FF
            txs

            ldy   #0
:banner     lda   BANNER,y
            sta   $0400,y
            iny
            cpy   #BANNER_END-BANNER
            bne   :banner

            jsr   INSTALL_COPY
            lda   #<NOIRQ
            sta   K_IRQ_HOOK
            lda   #>NOIRQ
            sta   K_IRQ_HOOK+1
            jsr   SCH_INIT
            lda   #1                       ;gates pin 40 cols:
            sta   TTY_BKND_REQ             ;auto = best 80 now
            jsr   PRC_INIT

            lda   #1
            jsr   PRC_STMP_BANK
            lda   #1
            jsr   PRC_SYNTH_FRM
            jsr   PATCH_PAR_FRM
            jsr   BOOT_CPY_PAR

            lda   #1
            ldx   #1
            jsr   SCH_CREATE
            jsr   SCH_START

BANNER      asc   "MAUX BUFIO"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 -- same reason catreadtestb.s's own PARENT_PROC is:
* absolute JSR/JMP operands to the helper subroutines below.
*---------------------------------------------------------------
PARENT_PROC bra   BTB_EQHOP
*-- The pathname/label data lives INSIDE the staged parent
*-- span, right behind the entry hop: pid 1 executes a COPY
*-- of [PARENT_PROC..+PAR_PROC_LEN] in its own bank, so data
*-- outside the span reads as never-copied garbage there --
*-- found the hard way on this very edit. The hop keeps the
*-- entry at PARENT_PROC; the placement keeps every *_LEN
*-- equ defined before its immediate use (S9 EQU burn-down
*-- 2026-08-29).
BWPTH_TXT
               ;/bin/BUFWR
               dfb $AF,$E2,$E9,$EE,$AF,$C2,$D5,$C6,$D7
               dfb $D2
BWPTH_LEN equ *-BWPTH_TXT
BTB_EQHOP
            stz   R_ERR
            stz   R_STEP
            stz   R_C_DONE
            stz   R_D_DONE
            jsr   SETUP_PATHS

            lda   #1
            sta   R_STEP
            jsr   CRT_OUT_FILE
            bcc   :created
            jmp   P_ERR
:created

            lda   #2
            sta   R_STEP
            jsr   SPAWN_BUFWR
            bcc   :spawned
            jmp   P_ERR
:spawned    sta   R_SPAWN_PID
            jsr   WAIT_BUFWR
            bcc   :waited
            jmp   P_ERR
:waited     sta   R_WAIT_PID

            lda   #3
            sta   R_STEP
            jsr   OPEN_OUT_FILE
            bcc   :opened
            jmp   P_ERR
:opened     sta   R_OUT_FD2
            jsr   READ_BACK
            bcc   :readback
            jmp   P_ERR
:readback   lda   R_OUT_FD2
            jsr   CLOSE_FD

            lda   #$AA
            sta   R_C_DONE          ;phase C complete -- gate
                                    ;(c) evidence is now durable
                                    ;even if phase D below hangs

* ---- PHASE D: the deliberate LC-bank-1-at-syscall violator ---
* SYS_GETPFX was tried first and completed CLEANLY even with
* bank 1 left selected -- maux's own GET_PREFIX path turned out
* to be cheap enough (no real disk I/O, TRM: a housekeeping
* call) that it may never actually touch ProDOS's
* $D000-bank-specific resident code, only the common
* ($E000-$FFFF) portion -- so it proved nothing. SYS_OPEN of a
* real, already-CREATEd file forces real directory/ block-driver
* dispatch, which the TRM's own memory map documents as living
* in the banked region -- see phase C's own OPEN_OUT_FILE,
* proven to reach real ProDOS above.
            lda   #4
            sta   R_STEP
            lda   LC_FREE_RW
            lda   LC_FREE_RW          ;select bank 1 --
                                      ;DELIBERATELY do not
                                      ;restore bank 2 before the
                                      ;syscall below (the exact
                                      ;violation docs/PROCIO.md
                                      ;sec 5 forbids)
            lda   #<BUFOUT_PATH
            sta   GPPARM+1
            lda   #>BUFOUT_PATH
            sta   GPPARM+2
            lda   #3
            sta   GPPARM
            stz   GPPARM+3
            stz   GPPARM+4
            stz   GPPARM+5
            lda   #<GPPARM
            ldx   #>GPPARM
            ldy   #SYS_OPEN
            jsr   $FF00             ;the violating call -- if
                                    ;this line ever completes
                                    ;and falls through, the CPU
                                    ;did NOT derail; record
                                    ;whatever happened rather
                                    ;than assume
            bcs   :d_err
            lda   #$AA
            sta   R_D_DONE
            bra   :d_after
:d_err      sta   R_D_ERR
            lda   #$EE
            sta   R_D_DONE
:d_after    lda   LC_KRN_RW        ;best-effort cleanup so the
                                    ;final :done park below (a
                                    ;syscall-free spin) can't
                                    ;itself be blamed on stale
                                    ;bank state

            lda   #$AA
            sta   R_DONE
:done       bra   :done

P_ERR       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:park       bra   :park

SETUP_PATHS
            ;"/mnt/MAUX/BUFOUT" -- 13 chars, MLI pathname
            ;(1-byte
            ;count prefix)
            lda   #16
            sta   BUFOUT_PATH
            ldx   #0
:cp1        lda   BOUT_PATH_TXT,x
            sta   BUFOUT_PATH+1,x
            inx
            cpx   #16
            bne   :cp1

            ;"/bin/BUFWR" -- high-bit NUL-terminated liba
            ;string, spawn path
            ldx   #0
:cp2        lda   BWPTH_TXT,x
            sta   BUFWR_PATH,x
            inx
            cpx   #BWPTH_LEN
            bne   :cp2
            stz   BUFWR_PATH+BWPTH_LEN

            ;"BUFWR" -- high-bit NUL-terminated liba string,
            ;argv[0]
            ldx   #0
:cp3        lda   ARG0_TXT,x
            sta   BUFWR_ARG0,x
            inx
            cpx   #5
            bne   :cp3
            stz   BUFWR_ARG0+5
            rts

BOUT_PATH_TXT  asc "/mnt/MAUX/BUFOUT"
ARG0_TXT
               dfb  $C2,$D5,$C6,$D7,$D2      ;BUFWR

CRT_OUT_FILE
            lda   #7
            sta   CREATE_PARM
            lda   #<BUFOUT_PATH
            sta   CREATE_PARM+1
            lda   #>BUFOUT_PATH
            sta   CREATE_PARM+2
            lda   #$C3
            sta   CREATE_PARM+3
            lda   #$06
            sta   CREATE_PARM+4
            stz   CREATE_PARM+5
            stz   CREATE_PARM+6
            lda   #$01
            sta   CREATE_PARM+7
            stz   CREATE_PARM+8
            stz   CREATE_PARM+9
            stz   CREATE_PARM+10
            stz   CREATE_PARM+11
            lda   #<CREATE_PARM
            ldx   #>CREATE_PARM
            ldy   #SYS_CREAT
            jsr   $FF00
            rts

OPEN_OUT_FILE
            lda   #<BUFOUT_PATH
            sta   OPEN_PARM+1
            lda   #>BUFOUT_PATH
            sta   OPEN_PARM+2
            lda   #3
            sta   OPEN_PARM
            stz   OPEN_PARM+3
            stz   OPEN_PARM+4
            stz   OPEN_PARM+5
            lda   #<OPEN_PARM
            ldx   #>OPEN_PARM
            ldy   #SYS_OPEN
            jsr   $FF00
            bcs   :err
            lda   OPEN_PARM+5
            clc
            rts
:err        sec
            rts

CLOSE_FD    sta   CLOSE_PARM+1
            lda   #1
            sta   CLOSE_PARM
            lda   #<CLOSE_PARM
            ldx   #>CLOSE_PARM
            ldy   #SYS_CLOSE
            jsr   $FF00
            rts

READ_BACK   lda   R_OUT_FD2
            sta   READ_PARM+1
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #PAYLOAD_LEN
            sta   READ_PARM+4
            stz   READ_PARM+5
            stz   READ_PARM+6
            stz   READ_PARM+7
            lda   #4
            sta   READ_PARM
            lda   #<READ_PARM
            ldx   #>READ_PARM
            ldy   #SYS_READ
            jsr   $FF00
            bcs   :err
            lda   READ_PARM+6
            sta   R_TRANS
            lda   READ_PARM+7
            sta   R_TRANS+1
            ldy   #0
:cp         cpy   #PAYLOAD_LEN
            beq   :done
            lda   IO_BUF,y
            sta   R_DATA,y
            iny
            bra   :cp
:done       clc
            rts
:err        sec
            rts

SPAWN_BUFWR lda   #<BUFWR_ARG0
            sta   ARGV_ARR
            lda   #>BUFWR_ARG0
            sta   ARGV_ARR+1
            stz   ARGV_ARR+2
            stz   ARGV_ARR+3

            lda   #<BUFWR_PATH
            sta   SPAWN_PARM
            lda   #>BUFWR_PATH
            sta   SPAWN_PARM+1
            lda   #<ARGV_ARR
            sta   SPAWN_PARM+2
            lda   #>ARGV_ARR
            sta   SPAWN_PARM+3
            stz   SPAWN_PARM+4      ;fdactions ptr = NULL --
            stz   SPAWN_PARM+5      ;"no actions" (syscall-
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
                                    ;fdact. equ's own FDACT_END
                                    ;comment)
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            rts

WAIT_BUFWR  lda   #<R_STATUS
            sta   WAIT_PARM
            lda   #>R_STATUS
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

PAR_PROC_LEN equ *-PARENT_PROC
