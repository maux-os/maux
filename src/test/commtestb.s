*---------------------------------------------------------------
* commtestb.s -- image body for commtest.s (`make check-comm`).
*
* One phase, same shape as shlangtestb.s's own: `sh` (stdin
* redirected from a staged /mnt/MAUX/SCRIPT) runs the tee/comm
* script and every observable result lands in a named output
* file (via `>`/`>>` redirects and a real pipeline, `CAT | TEE |
* WC`), which scripts/check_comm.py reads back byte-exact
* straight off the built .po image. No direct-spawn phase is
* needed -- every case this gate proves is something `sh` itself
* can express and redirect on its own, same posture shlangtestb.
* s's own header states.
*---------------------------------------------------------------

* Result addresses in the parent process bank (page $12).
R_SCRIPT_FD   equ $1200
R_SH_PID      equ $1201
R_SH_WAIT     equ $1202
R_SH_STATUS   equ $1203
R_DONE        equ $1290
R_ERR         equ $1291
R_STEP        equ $1292

* Parent process scratch.
SCRIPT_PATH   equ $1000   ;/mnt/MAUX/SCRIPT, MLI pathname
SH_PATH       equ $1020   ;/bin/sh, liba string (spawn path)
SH_ARG0       equ $1040   ;"SH", liba string
OPEN_PARM     equ $1060
CLOSE_PARM    equ $1070
WAIT_PARM     equ $1080
SPAWN_PARM    equ $1090
SH_ARGV       equ $10A0   ;2 entries: SH,NULL (4 bytes)
FDA_BUF       equ $10B0   ;fdactions: DUP+CLOSE+END = 7 bytes

*---------------------------------------------------------------
* Boot helpers -- identical shape to shlangtestb.s's own.
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

BANNER      asc   "MAUX COMM"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 -- same reason shlangtestb.s's own PARENT_PROC is.
*---------------------------------------------------------------
PARENT_PROC bra   CMB_EQHOP
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
CMB_EQHOP
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
            bcc   :sh_spawned
            jmp   P_ERR
:sh_spawned sta   R_SH_PID
            jsr   WAIT_SH
            bcc   :sh_waited
            jmp   P_ERR
:sh_waited  sta   R_SH_WAIT
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

            ;"/bin/sh" -- liba string, spawn path
            ldx   #0
:cp2        lda   SHBIN_PTH_TXT,x
            sta   SH_PATH,x
            inx
            cpx   #SHBIN_PTH_LEN
            bne   :cp2
            stz   SH_PATH+SHBIN_PTH_LEN

            ;"SH" -- liba string, argv[0]
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
            sta   SH_ARGV
            lda   #>SH_ARG0
            sta   SH_ARGV+1
            stz   SH_ARGV+2
            stz   SH_ARGV+3

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
            lda   #<SH_ARGV
            sta   SPAWN_PARM+2
            lda   #>SH_ARGV
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

PAR_PROC_LEN equ *-PARENT_PROC
