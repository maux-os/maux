*---------------------------------------------------------------
* envtestb.s -- image body for envtest.s (`make check-env`,
* docs/SYSCALL.md item 13c). Split out so the top-level stays a
* thin MANIFEST: real Merlin holds the resident top-level source
* AND the PUT file being read in the same 41215-byte buffer, so
* every byte here would come off every module's budget
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J).
*
* This harness is deliberately shtestb.s's, minus its file
* read-back: every observable of THIS gate is a file `sh` writes
* on the disk, and scripts/check_env.py reads those off the
* built image host-side (check_sh.py's own EDITED/CATOUT
* mechanism). All this process does is hand `sh` the script on
* fd 0, wait for it, and record that it exited 0 -- because a
* shell that died on line 1 also produces "no output", and the
* status is what tells those two apart.
*---------------------------------------------------------------

* Result addresses in the parent process bank.
R_SCRIPT_FD     equ $1200
R_SH_PID        equ $1201
R_WAIT_PID      equ $1202
R_SH_STATUS     equ $1203
R_DONE          equ $1290
R_ERR           equ $1291
R_STEP          equ $1292

* Parent process scratch.
SCRIPT_PATH equ $1000 ;/mnt/MAUX/SCRIPT, ProDOS MLI pathname
SH_PATH     equ $1020        ;/bin/sh, high-bit NUL liba
                             ;string (spawn path)
SH_ARG0     equ $1040        ;"SH", high-bit NUL liba string
                             ;(argv[0])
OPEN_PARM   equ $10A0
CLOSE_PARM  equ $10B0
WAIT_PARM   equ $10D0
SPAWN_PARM  equ $10E0
ARGV_ARR    equ $10F0        ;4 bytes: argv[0] ptr, argv[1]=0/0
FDA_BUF     equ $1100        ;fdactions: DUP+CLOSE + END = 7
                             ;bytes

*---------------------------------------------------------------
* Boot helpers -- identical shape to shtestb.s's own.
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

BANNER      asc   "MAUX ENV"
BANNER_END

* Dummy embedded images keep process.s link-compatible with the
* raw gate.
SIMG_EXIT
            rts
SIMG_EXIT_END
SIMG_READER
            rts
SIMG_RDR_END
SIMG_WRITER
            rts
SIMG_WRTR_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 -- absolute JSR/JMP operands to the helpers below.
*---------------------------------------------------------------
PARENT_PROC bra   EVB_EQHOP
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
EVB_EQHOP
            stz   R_ERR
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

            lda   #$AA
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
            rts

SCRPT_PTH_TXT asc "/mnt/MAUX/SCRIPT"

OPN_SCRPT_FL
            lda   #<SCRIPT_PATH
            sta   OPEN_PARM+1
            lda   #>SCRIPT_PATH
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
*-- The shell itself starts with an EMPTY environment (item
*-- 13c): everything the script's children inherit, `sh` must
*-- have exported itself. Written, never assumed -- SPAWN_PARM
*-- is ordinary process memory, and a stale byte here would hand
*-- `sh` an environment nobody staged.
            stz   SPAWN_PARM+6         ;NULL envp
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

PAR_PROC_LEN equ *-PARENT_PROC
