*---------------------------------------------------------------
* shlangtestb.s -- image body for shlangtest.s (`make check-
* shlang`).
*
* One phase only, simpler than fleettestb.s's two: `sh` (stdin
* redirected from a staged /mnt/MAUX/SCRIPT) runs the Tier 0
* language script (`$?`, `;`, `&&`, `||` -- docs/SH-SUBSET.md
* sec 3) and appends every observable result to
* /mnt/MAUX/RESULTS,
* which scripts/check_shlang.py reads back byte-exact straight
* off the built .po image -- the same "read the ProDOS file off
* the disk" mechanism scripts/check_sh.py uses for EDITED/
* CATOUT. No direct-spawn phase is needed here (unlike
* check-fleet's `cmp`): every case this gate proves is something
* `sh` itself can now express and redirect on its own.
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
* -- sh's own argv (docs/SH-FEATURES.md sec 4, Tier 2): "SCRIPT"
* -- ONE TWO THREE" -- $0 is argv[0], $1-$3 the rest, $4-$9 and
* -- past are UNSET (empty), $# starts at 3.
SH_ARG0       equ $1040   ;"SCRIPT", liba string
SH_ARGS       equ $1050   ;"-s", liba string: POSIX sh -s, the
                          ;commands are on stdin, the operands
                          ;after it are $1..
OPEN_PARM     equ $1060
CLOSE_PARM    equ $1070
WAIT_PARM     equ $1080
SPAWN_PARM    equ $1090
SH_ARGV       equ $10A0   ;6 entries: ARG0,-s,ARG1..ARG3,NULL
                          ;(12 bytes)
FDA_BUF       equ $10B0   ;fdactions: DUP+CLOSE+END = 7 bytes
SH_ARG1       equ $10C0   ;"ONE", liba string
SH_ARG2       equ $10D0   ;"TWO", liba string
SH_ARG3       equ $10E0   ;"THREE", liba string

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

BANNER      asc   "MAUX SHLANG"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 -- same reason shtestb.s's own PARENT_PROC is.
*---------------------------------------------------------------
PARENT_PROC bra   SLB_EQHOP
*-- The pathname/label data lives INSIDE the staged parent
*-- span, right behind the entry hop: pid 1 executes a COPY
*-- of [PARENT_PROC..+PAR_PROC_LEN] in its own bank, so data
*-- outside the span reads as never-copied garbage there --
*-- found the hard way on this very edit. The hop keeps the
*-- entry at PARENT_PROC; the placement keeps every *_LEN
*-- equ defined before its immediate use (S9 EQU burn-down
*-- 2026-08-29).
ARG0_TXT    asc   "SCRIPT"
ARG0_LEN    equ   *-ARG0_TXT
ARGS_TXT    dfb   $AD,$F3,0
ARG1_TXT    asc   "ONE"
ARG1_LEN    equ   *-ARG1_TXT
ARG2_TXT    asc   "TWO"
ARG2_LEN    equ   *-ARG2_TXT
ARG3_TXT    asc   "THREE"
ARG3_LEN    equ   *-ARG3_TXT
SCRPT_PTH_TXT asc "/mnt/MAUX/SCRIPT"
SHBIN_PTH_TXT
                ;/bin/sh
                dfb $AF,$E2,$E9,$EE,$AF,$F3,$E8
SHBIN_PTH_LEN  equ  *-SHBIN_PTH_TXT
SLB_EQHOP
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
*-- ORPHAN-1: the scripts' /bin/kill kills their own shell, so
*-- the live `kill` is ADOPTED by this pid 1 and its exit is a
*-- second wait result. Reap and discard until it is the shell.
:sh_wloop   jsr   WAIT_SH
            bcc   :sh_waited
            jmp   P_ERR
:sh_waited  sta   R_SH_WAIT
            cmp   R_SH_PID
            bne   :sh_wloop
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

            ;sh's own argv (docs/SH-FEATURES.md sec 4, Tier 2)
            ;-- liba strings, high-bit ASCII (same `asc "..."`
            ;convention IF_STR/CD_STR/etc already rely on in
            ;sh.s -- proven by the Tier 0/1 reserved-word/
            ;builtin compares, which could not pass otherwise).
            ldx   #0
:cparg0     lda   ARG0_TXT,x
            sta   SH_ARG0,x
            inx
            cpx   #ARG0_LEN
            bne   :cparg0
            stz   SH_ARG0+ARG0_LEN
            ldx   #2                   ;"-s", high-bit
:cparg_s    lda   ARGS_TXT,x
            sta   SH_ARGS,x
            dex
            bpl   :cparg_s
            ldx   #0
:cparg1     lda   ARG1_TXT,x
            sta   SH_ARG1,x
            inx
            cpx   #ARG1_LEN
            bne   :cparg1
            stz   SH_ARG1+ARG1_LEN
            ldx   #0
:cparg2     lda   ARG2_TXT,x
            sta   SH_ARG2,x
            inx
            cpx   #ARG2_LEN
            bne   :cparg2
            stz   SH_ARG2+ARG2_LEN
            ldx   #0
:cparg3     lda   ARG3_TXT,x
            sta   SH_ARG3,x
            inx
            cpx   #ARG3_LEN
            bne   :cparg3
            stz   SH_ARG3+ARG3_LEN
            rts


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
            lda   #<SH_ARGS
            sta   SH_ARGV+2
            lda   #>SH_ARGS
            sta   SH_ARGV+3
            lda   #<SH_ARG1
            sta   SH_ARGV+4
            lda   #>SH_ARG1
            sta   SH_ARGV+5
            lda   #<SH_ARG2
            sta   SH_ARGV+6
            lda   #>SH_ARG2
            sta   SH_ARGV+7
            lda   #<SH_ARG3
            sta   SH_ARGV+8
            lda   #>SH_ARG3
            sta   SH_ARGV+9
            stz   SH_ARGV+10           ;NULL terminator entry
            stz   SH_ARGV+11

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
