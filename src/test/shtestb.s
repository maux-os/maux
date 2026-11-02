*---------------------------------------------------------------
* shtestb.s -- image body for shtest.s.
* Split out so the top-level stays a thin MANIFEST: real
* Merlin holds the resident top-level source AND the PUT
* file being read in the same 41215-byte buffer, so every
* byte here would come off every module's budget.
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J)
*---------------------------------------------------------------


* Result addresses in the parent process bank.
R_SCRIPT_FD     equ $1200
R_SH_PID        equ $1201
R_WAIT_PID      equ $1202
R_SH_STATUS     equ $1203
R_OUT1_FD       equ $1204
R_OUT1_TRANS    equ $1205    ;2 bytes
R_OUT1_DATA     equ $1207    ;up to RBLEN bytes
R_OUT2_FD       equ $1220
R_OUT2_TRANS    equ $1221    ;2 bytes
R_OUT2_DATA     equ $1223    ;up to RBLEN bytes
RBLEN           equ 16
R_DONE          equ $1290
R_ERR           equ $1291
R_STEP          equ $1292
* fork() smoke-probe results (R_STEP = 7 while it runs): the
* proof SYS_FORK is dispatched in THIS shipping image, not only
* in forktest's. FOUR gates boot this body -- check-sh and
* check-v1-system (which assert these cells), plus check-shwarm
* and check-textaudit (which merely pay the probe's ~1.9s
* whole-window fork). The probe is safe upstream of all four
* ONLY because of two invariants:
*   (a) the free list is LIFO (procspawn.s pops and pushes at
*       PRC_FREE_CNT-1) and PRC_FORK zeroes LZ_WANT, so the
*       child's bank is UNTAGGED and PRC_FREE_BANK's push at
*       reap restores the list exactly -- the later SPAWN(SH)
*       still gets the same bank (fork_a == sh_pid == 2), and
*       check_v1_system's EXACTLY-pinned ps table holds.
*   (b) textaudit counts the forked bank 'untagged' and never
*       asserts on it.
* A change to bank-allocation order or to lazy-free's verdict
* on forked banks breaks check-v1-system as a confusing ps
* diff, not a fork error -- look HERE first.
R_FORK_A        equ $1293    ;pid the parent's fork() returned
R_FORK_ST       equ $1294    ;child's exit status ($C9)
R_FORK_W        equ $1295    ;pid wait() reaped afterwards

* `sh SCRIPTFILE` mode (Phase B, EX3 pipeline work): a SECOND
* `sh` spawn, argv={"SH","/mnt/MAUX/SCRIPT3"} -- no fd 0 dup
* this
* time. Proves (a) commands run from the named file (SCRIPT3's
* own CAT writes OUT3) and (b) fd 0/1/2 stay free for the
* COMMAND's own I/O -- IN3 is dup'd onto fd 0 same as any
* ordinary spawn, SCRIPT3's `CAT` (no args) reads it with NO
* redirection of its own, proving sh's own script source (now
* CUR_IN_FD, a THIRD fd) never touched fd 0 at all. Runs AFTER
* the existing OUT1/OUT2 sequence below, isolated result cells,
* so (c) (argc==1 unchanged) is exercised, byte-checked and
* fully done BEFORE this ever starts.
R_IN3_FD        equ $1240
R_SH2_PID       equ $1241
R_WAIT2_PID     equ $1242
R_SH2_STATUS    equ $1243
R_OUT3_FD       equ $1244
R_OUT3_TRANS    equ $1245    ;2 bytes
R_OUT3_DATA     equ $1247    ;up to RBLEN bytes

* Parent process scratch.
SCRIPT_PATH equ $1000 ;/mnt/MAUX/SCRIPT, ProDOS MLI pathname
SH_PATH     equ $1020        ;/bin/sh, high-bit NUL liba
                             ;string (spawn path)
SH_ARG0     equ $1040        ;"SH", high-bit NUL liba string
                             ;(argv[0])
OUT1_PATH   equ $1060 ;/mnt/MAUX/OUT1, ProDOS MLI pathname
OUT2_PATH   equ $1080 ;/mnt/MAUX/OUT2, ProDOS MLI pathname
OPEN_PARM   equ $10A0
CLOSE_PARM  equ $10B0
READ_PARM   equ $10C0
WAIT_PARM   equ $10D0
SPAWN_PARM  equ $10E0
ARGV_ARR    equ $10F0        ;4 bytes: argv[0] ptr, argv[1]=0/0
FDA_BUF     equ $1100        ;fdactions: DUP+CLOSE + END = 7
                             ;bytes
IO_BUF      equ $1110        ;RBLEN bytes
FPROBE_PARM equ $1130        ;fork probe: wait parmlist (2) +
                             ;the child's exit-status byte (1)

* `sh SCRIPTFILE` mode scratch (Phase B). OPEN_PARM/CLOSE_PARM/
* READ_PARM/WAIT_PARM/IO_BUF above are reused verbatim -- every
* use is strictly sequential, same as OUT1 vs OUT2 already share
* them.
IN3_PATH    equ $1140        ;/mnt/MAUX/IN3, ProDOS MLI pathname
OUT3_PATH   equ $1150 ;/mnt/MAUX/OUT3, ProDOS MLI pathname
SCRIPT3_ARG equ $1160 ;/mnt/MAUX/SCRIPT3, high-bit NUL liba
                             ;string (sh's argv[1])
ARGV2_ARR   equ $1175        ;6 bytes: argv[0] ptr, argv[1] ptr,
                             ;NULL terminator
FDA_BUF2    equ $1180        ;fdactions: DUP+CLOSE+END = 7 bytes
SPAWN_PARM2 equ $1190
WAIT_PARM2  equ $11A0

*---------------------------------------------------------------
* Boot helpers -- identical shape to fileproctest.s's own.
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

BANNER      asc   "MAUX SH"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 -- same reason fileproctest.s's own PARENT_PROC is:
* absolute JSR/JMP operands to the helper subroutines below.
*---------------------------------------------------------------
PARENT_PROC bra   STB_EQHOP
*-- The pathname/label data lives INSIDE the staged parent
*-- span, right behind the entry hop: pid 1 executes a COPY
*-- of [PARENT_PROC..+PAR_PROC_LEN] in its own bank, so data
*-- outside the span reads as never-copied garbage there --
*-- found the hard way on this very edit. The hop keeps the
*-- entry at PARENT_PROC; the placement keeps every *_LEN
*-- equ defined before its immediate use (S9 EQU burn-down
*-- 2026-08-29).
SHBIN_PTH_TXT
                ;/bin/sh
                dfb $AF,$E2,$E9,$EE,$AF,$F3,$E8
SHBIN_PTH_LEN  equ  *-SHBIN_PTH_TXT
SCR3_PTH_TXT   asc   "/mnt/MAUX/SCRIPT3"
SCR3_PTH_LEN  equ   *-SCR3_PTH_TXT
STB_EQHOP
            stz   R_ERR
            stz   R_STEP

*-- fork() smoke probe, FIRST -- before any fd is open, while
*-- every bank but this one is free. No brk is declared yet, so
*-- the copy is the whole window (~1.8s at 1 MHz), paid once.
*-- A is loaded nonzero on purpose: the kernel ignores fork's
*-- parms pointer, but with A=0 going in a deleted frame-A
*-- patch hands the child a 0 that reads as success -- the
*-- vacuous-sabotage shape docs/FORK.md records.
            lda   #7
            sta   R_STEP
            lda   #$5A
            ldy   #SYS_FORK
            jsr   $FF00
            bcc   :forkok
            jmp   P_ERR
:forkok     cmp   #0
            bne   :fparent
*-- the CHILD: exit $C9 immediately, nothing else.
            lda   #$C9
            sta   FPROBE_PARM+2
            lda   #<FPROBE_PARM+2
            ldx   #>FPROBE_PARM+2
            ldy   #SYS_EXIT
            jsr   $FF00
            bra   *
:fparent    sta   R_FORK_A
            lda   #<R_FORK_ST
            sta   FPROBE_PARM
            lda   #>R_FORK_ST
            sta   FPROBE_PARM+1
            lda   #<FPROBE_PARM
            ldx   #>FPROBE_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :freaped
            jmp   P_ERR
:freaped    sta   R_FORK_W
            stz   R_STEP

            jsr   SETUP_PATHS

            lda   #1
            sta   R_STEP
            jsr   OPN_SCRPT_FL
            bcc   :opnd_script
            jmp   P_ERR
:opnd_script
            sta   R_SCRIPT_FD

            lda   #2
            sta   R_STEP
            jsr   SPAWN_SH
            bcc   :spawned
            jmp   P_ERR
:spawned    sta   R_SH_PID
            jsr   WAIT_SH
            bcc   :waited
            jmp   P_ERR
:waited     sta   R_WAIT_PID
            lda   R_SCRIPT_FD
            jsr   CLOSE_FD

            lda   #3
            sta   R_STEP
            jsr   OPEN_OT1_FILE
            bcc   :opened1
            jmp   P_ERR
:opened1    sta   R_OUT1_FD
            jsr   READ_OUT1
            bcc   :read1
            jmp   P_ERR
:read1      lda   R_OUT1_FD
            jsr   CLOSE_FD

            lda   #4
            sta   R_STEP
            jsr   OPEN_OT2_FILE
            bcc   :opened2
            jmp   P_ERR
:opened2    sta   R_OUT2_FD
            jsr   READ_OUT2
            bcc   :read2
            jmp   P_ERR
:read2      lda   R_OUT2_FD
            jsr   CLOSE_FD

*-- `sh SCRIPTFILE` mode (Phase B): SH2 reads its commands from
*-- /mnt/MAUX/SCRIPT3 (argv[1]), NOT fd 0 -- IN3 is dup'd onto
*-- fd 0
*-- instead, and SCRIPT3's own `CAT` (no args, no redirection)
*-- reads it, proving fd 0 was free for the command all along.
*-- IN3/SCRIPT3 are staged ONLY by images that exercise `sh
*-- SCRIPTFILE` (build_sh_image.py). Images that reuse this
*-- shared harness for the earlier steps but not this test
*-- (v1-system, shwarm, textaudit) do not stage them -- a
*-- not-found IN3 SKIPS steps 5-6 cleanly, so the SCRIPTFILE
*-- test is opt-in by staging the file rather than a failure
*-- forced on every consumer of this harness (2026-09-07: it
*-- was added unconditionally at eac1287 and reddened three
*-- gates that never staged IN3). A not-found is $46; any other
*-- open error is real.
            lda   #5
            sta   R_STEP
            jsr   OPN_IN3_FILE
            bcc   :openedi3
            cmp   #MLIE_NOFILE
            beq   :sfskip
            jmp   P_ERR
:sfskip     jmp   :sfdone
:openedi3   sta   R_IN3_FD
            jsr   SPAWN_SH2
            bcc   :spawned2
            jmp   P_ERR
:spawned2   sta   R_SH2_PID
            jsr   WAIT_SH2
            bcc   :waited2
            jmp   P_ERR
:waited2    sta   R_WAIT2_PID
            lda   R_IN3_FD
            jsr   CLOSE_FD

            lda   #6
            sta   R_STEP
            jsr   OPEN_OT3_FILE
            bcc   :opened3
            jmp   P_ERR
:opened3    sta   R_OUT3_FD
            jsr   READ_OUT3
            bcc   :read3
            jmp   P_ERR
:read3      lda   R_OUT3_FD
            jsr   CLOSE_FD

:sfdone     lda   #$AA
            sta   R_DONE
:done       bra   :done

P_ERR       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:park       bra   :park

SETUP_PATHS
            ; "/mnt/MAUX/SCRIPT" -- 13 chars, MLI pathname
            lda   #16
            sta   SCRIPT_PATH
            ldx   #0
:cp1        lda   SCRPT_PTH_TXT,x
            sta   SCRIPT_PATH+1,x
            inx
            cpx   #16
            bne   :cp1

            ; "/mnt/MAUX/OUT1" -- 11 chars, MLI pathname
            lda   #14
            sta   OUT1_PATH
            ldx   #0
:cp2        lda   OUT1_PATH_TXT,x
            sta   OUT1_PATH+1,x
            inx
            cpx   #14
            bne   :cp2

            ; "/mnt/MAUX/OUT2" -- 11 chars, MLI pathname
            lda   #14
            sta   OUT2_PATH
            ldx   #0
:cp3        lda   OUT2_PATH_TXT,x
            sta   OUT2_PATH+1,x
            inx
            cpx   #14
            bne   :cp3

            ;"/bin/sh" -- high-bit NUL-terminated liba string,
            ;spawn path
            ldx   #0
:cp4        lda   SHBIN_PTH_TXT,x
            sta   SH_PATH,x
            inx
            cpx   #SHBIN_PTH_LEN
            bne   :cp4
            stz   SH_PATH+SHBIN_PTH_LEN

            ;"SH" -- high-bit NUL-terminated liba string,
            ;argv[0]
            lda   #$D3
            sta   SH_ARG0
            lda   #$C8
            sta   SH_ARG0+1
            stz   SH_ARG0+2

            ; "/mnt/MAUX/IN3" -- 10 chars, MLI pathname
            lda   #13
            sta   IN3_PATH
            ldx   #0
:cp5        lda   IN3_PATH_TXT,x
            sta   IN3_PATH+1,x
            inx
            cpx   #13
            bne   :cp5

            ; "/mnt/MAUX/OUT3" -- 11 chars, MLI pathname
            lda   #14
            sta   OUT3_PATH
            ldx   #0
:cp6        lda   OUT3_PATH_TXT,x
            sta   OUT3_PATH+1,x
            inx
            cpx   #14
            bne   :cp6

            ;"/mnt/MAUX/SCRIPT3" -- high-bit NUL-terminated liba
            ;string, sh's argv[1] (script path operand)
            ldx   #0
:cp7        lda   SCR3_PTH_TXT,x
            sta   SCRIPT3_ARG,x
            inx
            cpx   #SCR3_PTH_LEN
            bne   :cp7
            stz   SCRIPT3_ARG+SCR3_PTH_LEN
            rts

SCRPT_PTH_TXT asc "/mnt/MAUX/SCRIPT"
OUT1_PATH_TXT   asc "/mnt/MAUX/OUT1"
OUT2_PATH_TXT   asc "/mnt/MAUX/OUT2"
IN3_PATH_TXT    asc "/mnt/MAUX/IN3"
OUT3_PATH_TXT   asc "/mnt/MAUX/OUT3"

OPN_IN3_FILE
            lda   #<IN3_PATH
            sta   OPEN_PARM+1
            lda   #>IN3_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPEN_OT3_FILE
            lda   #<OUT3_PATH
            sta   OPEN_PARM+1
            lda   #>OUT3_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPN_SCRPT_FL
            lda   #<SCRIPT_PATH
            sta   OPEN_PARM+1
            lda   #>SCRIPT_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPEN_OT1_FILE
            lda   #<OUT1_PATH
            sta   OPEN_PARM+1
            lda   #>OUT1_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPEN_OT2_FILE
            lda   #<OUT2_PATH
            sta   OPEN_PARM+1
            lda   #>OUT2_PATH
            sta   OPEN_PARM+2
OPEN_COMMON lda   #3
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

READ_OUT1   lda   R_OUT1_FD
            ldx   #<R_OUT1_TRANS
            ldy   #<R_OUT1_DATA
            jsr   RD_CMMN_SETUP
            jsr   READ_COMMON
            bcs   :err
            rts
:err        sec
            rts

READ_OUT2   lda   R_OUT2_FD
            ldx   #<R_OUT2_TRANS
            ldy   #<R_OUT2_DATA
            jsr   RD_CMMN_SETUP
            jsr   READ_COMMON
            bcs   :err
            rts
:err        sec
            rts

READ_OUT3   lda   R_OUT3_FD
            ldx   #<R_OUT3_TRANS
            ldy   #<R_OUT3_DATA
            jsr   RD_CMMN_SETUP
            jsr   READ_COMMON
            bcs   :err
            rts
:err        sec
            rts

;IN: A=fd, X=<trans result addr (page $12), Y=<data dest addr
;(page $12)
RD_CMMN_SETUP
            sta   READ_PARM+1
            stx   RB_TRANS_LO
            sty   RB_DATA_LO
            rts

READ_COMMON lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #RBLEN
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
            ldy   RB_TRANS_LO
            lda   READ_PARM+6
            sta   $1200,y                ;RB_TRANS_LO is always
                                         ;page $12
            lda   READ_PARM+7
            sta   $1201,y
            ldy   #0
            ldx   RB_DATA_LO
:cp         cpy   #RBLEN
            beq   :done
            lda   IO_BUF,y
            sta   $1200,x
            inx
            iny
            bra   :cp
:done       clc
            rts
:err        sec
            rts

RB_TRANS_LO ds 1
RB_DATA_LO  ds 1

SPAWN_SH    lda   #<SH_ARG0
            sta   ARGV_ARR
            lda   #>SH_ARG0
            sta   ARGV_ARR+1
            stz   ARGV_ARR+2
            stz   ARGV_ARR+3

            lda   #FDACT_DUP
            sta   FDA_BUF+0
            lda   #FD_STDIN
            sta   FDA_BUF+1
            lda   R_SCRIPT_FD
            sta   FDA_BUF+2
            lda   #FDACT_CLOSE
            sta   FDA_BUF+3
            lda   R_SCRIPT_FD
            sta   FDA_BUF+4
            stz   FDA_BUF+5
            stz   FDA_BUF+6            ;FDACT_END

            lda   #<SH_PATH
            sta   SPAWN_PARM
            lda   #>SH_PATH
            sta   SPAWN_PARM+1
            lda   #<ARGV_ARR
            sta   SPAWN_PARM+2
            lda   #>ARGV_ARR
            sta   SPAWN_PARM+3
            lda   #<FDA_BUF
            sta   SPAWN_PARM+4
            lda   #>FDA_BUF
            sta   SPAWN_PARM+5
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            rts

WAIT_SH     lda   #<R_SH_STATUS
            sta   WAIT_PARM
            lda   #>R_SH_STATUS
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

*-- SPAWN_SH2/WAIT_SH2 -- the `sh SCRIPTFILE` mode spawn (Phase
*-- B). argv={"SH","/mnt/MAUX/SCRIPT3"} -- TWO argv entries,
*-- unlike
*-- SPAWN_SH's one -- and fd 0 is dup'd from IN3 (real data),
*-- NOT the script: SCRIPT3 reaches sh via OPEN_REDIR_RD on
*-- argv[1] instead.
SPAWN_SH2   lda   #<SH_ARG0
            sta   ARGV2_ARR
            lda   #>SH_ARG0
            sta   ARGV2_ARR+1
            lda   #<SCRIPT3_ARG
            sta   ARGV2_ARR+2
            lda   #>SCRIPT3_ARG
            sta   ARGV2_ARR+3
            stz   ARGV2_ARR+4
            stz   ARGV2_ARR+5

            lda   #FDACT_DUP
            sta   FDA_BUF2+0
            lda   #FD_STDIN
            sta   FDA_BUF2+1
            lda   R_IN3_FD
            sta   FDA_BUF2+2
            lda   #FDACT_CLOSE
            sta   FDA_BUF2+3
            lda   R_IN3_FD
            sta   FDA_BUF2+4
            stz   FDA_BUF2+5
            stz   FDA_BUF2+6            ;FDACT_END

            lda   #<SH_PATH
            sta   SPAWN_PARM2
            lda   #>SH_PATH
            sta   SPAWN_PARM2+1
            lda   #<ARGV2_ARR
            sta   SPAWN_PARM2+2
            lda   #>ARGV2_ARR
            sta   SPAWN_PARM2+3
            lda   #<FDA_BUF2
            sta   SPAWN_PARM2+4
            lda   #>FDA_BUF2
            sta   SPAWN_PARM2+5
            stz   SPAWN_PARM2+6          ;NULL envp
            stz   SPAWN_PARM2+7
            lda   #<SPAWN_PARM2
            ldx   #>SPAWN_PARM2
            ldy   #SYS_SPAWN
            jsr   $FF00
            rts

WAIT_SH2    lda   #<R_SH2_STATUS
            sta   WAIT_PARM2
            lda   #>R_SH2_STATUS
            sta   WAIT_PARM2+1
            lda   #<WAIT_PARM2
            ldx   #>WAIT_PARM2
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

PAR_PROC_LEN equ *-PARENT_PROC
