*---------------------------------------------------------------
* ldtestb.s -- image body for ldtest.s (`make check-ld`). Same
* two-run shape as src/test/astestb.s: (1) `LD` through `sh`
* (stdin redirected from a staged script) links RTMAIN+RTLIB to
* /mnt/MAUX/LDOUT -- the "runs from the maux shell,
* byte-identical
* to the stock link" proof, checked host-side (check_ld.py)
* against build/rtlinked.bin. (2) `LD` spawned DIRECTLY on a
* MISSING module (deliberate failure, docs/LD-DESIGN.md section
* 0's own gate requirement), fd 2 dup'd to a harness-owned file,
* so the nonzero exit status and the "ld: "-prefixed diagnostic
* can both be asserted precisely -- same direct-SPAWN-plus-fd-
* redirect technique astestb.s/lstest.s/catreadtest.s already
* use.
*---------------------------------------------------------------

* Result addresses in the parent process bank.
R_SCRIPT_FD  equ $1200
R_SH_PID     equ $1201
R_SH_WAIT    equ $1202
R_SH_STATUS  equ $1203
R_LDERR_FD   equ $1204
R_LD_PID     equ $1205
R_LD_WAIT    equ $1206
R_LD_STATUS  equ $1207
R_LDE_TRANS  equ $1208    ;2 bytes
R_LDE_DATA   equ $120A    ;up to RBLEN bytes
RBLEN        equ 80
R_DONE       equ $1260
R_ERR        equ $1261
R_STEP       equ $1262

* Parent process scratch.
SCRIPT_PATH equ $1000     ;/mnt/MAUX/SCRIPT, MLI pathname
SH_PATH     equ $1020     ;/bin/sh, liba string (spawn path)
SH_ARG0     equ $1040     ;"SH", liba string
LD_PATH     equ $1060 ;/bin/LD, liba string (spawn path)
LD_ARG0     equ $1080     ;"LD", liba string
NOMOD_ARG   equ $10A0     ;/mnt/MAUX/NOSUCH, liba string
OFLAG_ARG   equ $10D0     ;"-o", liba string
BADOUT_ARG  equ $10E0     ;/mnt/MAUX/BADOUT, liba string
LDERR_PATH  equ $1110     ;/mnt/MAUX/LDERR, MLI pathname

OPEN_PARM   equ $1140
CLOSE_PARM  equ $1150
READ_PARM   equ $1160
WAIT_PARM   equ $1170
SPAWN_PARM  equ $1180
CREAT_PARM  equ $1190
SH_ARGV     equ $11B0     ;2 bytes: argv[0] ptr, argv[1]=0/0
LD_ARGV     equ $11B4     ;5 entries: LD,NOSUCH,-o,BADOUT,NULL
FDA_BUF     equ $11C8     ;fdactions: DUP+CLOSE + END = 7 bytes
IO_BUF      equ $11D8     ;RBLEN bytes

*---------------------------------------------------------------
* Boot helpers -- identical shape to astestb.s's own.
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

BANNER      asc   "MAUX LD"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 -- absolute JSR/JMP operands to the helper subroutines
* below need it there (same reason astestb.s's own PARENT_PROC
* is copied, not run in place).
*---------------------------------------------------------------
PARENT_PROC bra   LTB_EQHOP
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
LDBIN_PTH_TXT
                ;/bin/LD
                dfb $AF,$E2,$E9,$EE,$AF,$CC,$C4
LDBIN_PTH_LEN  equ  *-LDBIN_PTH_TXT
NOMOD_TXT
                ;/mnt/MAUX/NOSUCH
                dfb $AF,$ED,$EE,$F4,$AF,$CD,$C1,$D5,$D8
                dfb $AF,$CE,$CF,$D3,$D5,$C3,$C8
NOMOD_LEN      equ  *-NOMOD_TXT
BADOUT_TXT
                ;/mnt/MAUX/BADOUT
                dfb $AF,$ED,$EE,$F4,$AF,$CD,$C1,$D5,$D8
                dfb $AF,$C2,$C1,$C4,$CF,$D5,$D4
BADOUT_LEN     equ  *-BADOUT_TXT
LTB_EQHOP
            stz   R_ERR
            stz   R_STEP
            jsr   SETUP_PATHS

* -- run 1: `sh` (stdin = staged SCRIPT) runs
* -- "LD -o /mnt/MAUX/LDOUT /mnt/MAUX/RTMAIN /mnt/MAUX/RTLIB"
* then "EXIT"
* --
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

* -- run 2: `LD` spawned DIRECTLY on a missing module. fd 2
* -- dup'd to a harness file so the diagnostic can be read back.
            lda   #3
            sta   R_STEP
            jsr   CREAT_LDERR
            bcc   :lerr_creat
            jmp   P_ERR
:lerr_creat
            jsr   OPN_LDERR_WR
            bcc   :lderr_opened
            jmp   P_ERR
:lderr_opened
            sta   R_LDERR_FD
            lda   #4
            sta   R_STEP
            jsr   SPAWN_LD
            bcc   :ld_spawned
            jmp   P_ERR
:ld_spawned sta   R_LD_PID
            lda   R_LDERR_FD
            jsr   CLOSE_FD          ;parent's own copy -- the
                                    ;child holds its dup already
            jsr   WAIT_LD
            bcc   :ld_waited
            jmp   P_ERR
:ld_waited  sta   R_LD_WAIT

            lda   #5
            sta   R_STEP
            jsr   OPN_LDERR_RD
            bcc   :lerr_reopn
            jmp   P_ERR
:lerr_reopn
            sta   R_LDERR_FD
            jsr   READ_LDERR
            bcc   :lderr_read
            jmp   P_ERR
:lderr_read lda   R_LDERR_FD
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

            ; "/mnt/MAUX/LDERR" -- 12 chars, MLI pathname
            lda   #15
            sta   LDERR_PATH
            ldx   #0
:cp2        lda   LDERR_PTH_TXT,x
            sta   LDERR_PATH+1,x
            inx
            cpx   #15
            bne   :cp2

            ;"/bin/sh" -- liba string, spawn path
            ldx   #0
:cp3        lda   SHBIN_PTH_TXT,x
            sta   SH_PATH,x
            inx
            cpx   #SHBIN_PTH_LEN
            bne   :cp3
            stz   SH_PATH+SHBIN_PTH_LEN

            ;"SH" -- liba string, argv[0]
            lda   #$D3
            sta   SH_ARG0
            lda   #$C8
            sta   SH_ARG0+1
            stz   SH_ARG0+2

            ;"/bin/LD" -- liba string, spawn path
            ldx   #0
:cp4        lda   LDBIN_PTH_TXT,x
            sta   LD_PATH,x
            inx
            cpx   #LDBIN_PTH_LEN
            bne   :cp4
            stz   LD_PATH+LDBIN_PTH_LEN

            ;"LD" -- liba string, argv[0]
            lda   #$CC
            sta   LD_ARG0
            lda   #$C4
            sta   LD_ARG0+1
            stz   LD_ARG0+2

            ;"/mnt/MAUX/NOSUCH" -- liba string, argv[1]
            ;(deliberately
            ;a module that does not exist on the image)
            ldx   #0
:cp5        lda   NOMOD_TXT,x
            sta   NOMOD_ARG,x
            inx
            cpx   #NOMOD_LEN
            bne   :cp5
            stz   NOMOD_ARG+NOMOD_LEN

            ;"-o" -- liba string, argv[2]
            lda   #$AD
            sta   OFLAG_ARG
            lda   #$EF
            sta   OFLAG_ARG+1
            stz   OFLAG_ARG+2

            ;"/mnt/MAUX/BADOUT" -- liba string, argv[3]
            ldx   #0
:cp6        lda   BADOUT_TXT,x
            sta   BADOUT_ARG,x
            inx
            cpx   #BADOUT_LEN
            bne   :cp6
            stz   BADOUT_ARG+BADOUT_LEN
            rts

SCRPT_PTH_TXT asc "/mnt/MAUX/SCRIPT"
LDERR_PTH_TXT asc "/mnt/MAUX/LDERR"

OPN_SCRPT_FL
            lda   #<SCRIPT_PATH
            sta   OPEN_PARM+1
            lda   #>SCRIPT_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPN_LDERR_WR
            lda   #<LDERR_PATH
            sta   OPEN_PARM+1
            lda   #>LDERR_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPN_LDERR_RD
            lda   #<LDERR_PATH
            sta   OPEN_PARM+1
            lda   #>LDERR_PATH
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

CREAT_LDERR lda   #<LDERR_PATH
            sta   CREAT_PARM+1
            lda   #>LDERR_PATH
            sta   CREAT_PARM+2
            lda   #7          ;PCOUNT_CREATE (mli.equ) -- the
                              ;field COUNT, not the struct SIZE
                              ;(astestb.s's own bug, fixed there
                              ;2026-08-20 -- inherited correct
                              ;here)
            sta   CREAT_PARM
            lda   #$C3              ;ACCESS_UNLKD
            sta   CREAT_PARM+3
            lda   #$06              ;FTYPE_BIN
            sta   CREAT_PARM+4
            stz   CREAT_PARM+5
            stz   CREAT_PARM+6
            lda   #$01              ;STYP_SEEDLING
            sta   CREAT_PARM+7
            stz   CREAT_PARM+8
            stz   CREAT_PARM+9
            stz   CREAT_PARM+10
            stz   CREAT_PARM+11
            lda   #<CREAT_PARM
            ldx   #>CREAT_PARM
            ldy   #SYS_CREAT
            jsr   $FF00
            rts

CLOSE_FD    sta   CLOSE_PARM+1
            lda   #1
            sta   CLOSE_PARM
            lda   #<CLOSE_PARM
            ldx   #>CLOSE_PARM
            ldy   #SYS_CLOSE
            jsr   $FF00
            rts

READ_LDERR  lda   R_LDERR_FD
            sta   READ_PARM+1
            lda   #<IO_BUF
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
            lda   READ_PARM+6
            sta   R_LDE_TRANS
            lda   READ_PARM+7
            sta   R_LDE_TRANS+1
            ldy   #0
:cp         cpy   #RBLEN
            beq   :done
            lda   IO_BUF,y
            sta   R_LDE_DATA,y
            iny
            bra   :cp
:done       clc
            rts
:err        sec
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

SPAWN_LD    lda   #<LD_ARG0
            sta   LD_ARGV
            lda   #>LD_ARG0
            sta   LD_ARGV+1
            lda   #<OFLAG_ARG
            sta   LD_ARGV+2
            lda   #>OFLAG_ARG
            sta   LD_ARGV+3
            lda   #<BADOUT_ARG
            sta   LD_ARGV+4
            lda   #>BADOUT_ARG
            sta   LD_ARGV+5
            lda   #<NOMOD_ARG
            sta   LD_ARGV+6
            lda   #>NOMOD_ARG
            sta   LD_ARGV+7
            stz   LD_ARGV+8
            stz   LD_ARGV+9

            lda   #FDACT_DUP
            sta   FDA_BUF+0
            lda   #FD_STDERR
            sta   FDA_BUF+1
            lda   R_LDERR_FD
            sta   FDA_BUF+2
            lda   #FDACT_CLOSE
            sta   FDA_BUF+3
            lda   R_LDERR_FD
            sta   FDA_BUF+4
            stz   FDA_BUF+5
            stz   FDA_BUF+6            ;FDACT_END

            lda   #<LD_PATH
            sta   SPAWN_PARM
            lda   #>LD_PATH
            sta   SPAWN_PARM+1
            lda   #<LD_ARGV
            sta   SPAWN_PARM+2
            lda   #>LD_ARGV
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

WAIT_LD     lda   #<R_LD_STATUS
            sta   WAIT_PARM
            lda   #>R_LD_STATUS
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

PAR_PROC_LEN equ *-PARENT_PROC
