*---------------------------------------------------------------
* astestb.s -- image body for astest.s (`make check-as`).
* Two runs: (1) `AS` through `sh` (stdin redirected from a
* staged script), a plain `AS src -o obj` with no redirection
* needed -- this is the "runs from the maux shell" proof, and
* its produced object is compared host-side (check_as.py)
* against merlin32 on the same source. (2) `AS` spawned
* DIRECTLY (sh has no `2>` stderr redirection -- grepped sh.s,
* only '<'/'>' are recognized) on a source with a syntax
* error, deliberately staged; fd 2
* dup'd to a harness-owned file, so the diagnostic + exit status
* can be asserted precisely -- the same direct-SPAWN-plus-fd-
* redirect technique src/test/lstest.s and catreadtest.s already
* use for exactly this reason.
*---------------------------------------------------------------

* Result addresses in the parent process bank.
R_SCRIPT_FD  equ $1200
R_SH_PID     equ $1201
R_SH_WAIT    equ $1202
R_SH_STATUS  equ $1203
R_ASERR_FD   equ $1204
R_AS_PID     equ $1205
R_AS_WAIT    equ $1206
R_AS_STATUS  equ $1207
R_ASE_TRANS  equ $1208    ;2 bytes
R_ASE_DATA   equ $120A    ;up to RBLEN bytes
RBLEN        equ 80
R_DONE       equ $1260
R_ERR        equ $1261
R_STEP       equ $1262

* Parent process scratch.
SCRIPT_PATH equ $1000     ;/mnt/MAUX/SCRIPT, MLI pathname
SH_PATH     equ $1020     ;/bin/sh, liba string (spawn path)
SH_ARG0     equ $1040     ;"SH", liba string
AS_PATH     equ $1060 ;/bin/AS, liba string (spawn path)
AS_ARG0     equ $1080     ;"AS", liba string
BADSRC_ARG  equ $10A0     ;/mnt/MAUX/BADMOD.S, liba string
OFLAG_ARG   equ $10D0     ;"-o", liba string
BADOBJ_ARG  equ $10E0     ;/mnt/MAUX/BADMOD.OBJ, liba string
ASERR_PATH  equ $1110     ;/mnt/MAUX/ASERR, MLI pathname

OPEN_PARM   equ $1140
CLOSE_PARM  equ $1150
READ_PARM   equ $1160
WAIT_PARM   equ $1170
SPAWN_PARM  equ $1180
CREAT_PARM  equ $1190
SH_ARGV     equ $11B0     ;2 bytes: argv[0] ptr, argv[1]=0/0
AS_ARGV     equ $11B4     ;5 entries: AS,BADSRC,-o,BADOBJ,NULL
FDA_BUF     equ $11C8     ;fdactions: DUP+CLOSE + END = 7 bytes
IO_BUF      equ $11D8     ;RBLEN bytes

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

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 -- absolute JSR/JMP operands to the helper subroutines
* below need it there (same reason shtestb.s's own PARENT_PROC
* is copied, not run in place).
*---------------------------------------------------------------
PARENT_PROC bra   ATB_EQHOP
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
ASBIN_PTH_TXT
                ;/bin/AS
                dfb $AF,$E2,$E9,$EE,$AF,$C1,$D3
ASBIN_PTH_LEN  equ  *-ASBIN_PTH_TXT
BADSRC_TXT
                ;/mnt/MAUX/BADMOD.S
                dfb $AF,$ED,$EE,$F4,$AF,$CD,$C1,$D5,$D8
                dfb $AF,$C2,$C1,$C4,$CD,$CF,$C4,$AE,$D3
BADSRC_LEN     equ  *-BADSRC_TXT
BADOBJ_TXT
                ;/mnt/MAUX/BADMOD.OBJ
                dfb $AF,$ED,$EE,$F4,$AF,$CD,$C1,$D5,$D8
                dfb $AF,$C2,$C1,$C4,$CD,$CF,$C4,$AE,$CF
                dfb $C2,$CA
BADOBJ_LEN     equ  *-BADOBJ_TXT
ATB_EQHOP
            stz   R_ERR
            stz   R_STEP
            jsr   SETUP_PATHS

* -- run 1: `sh` (stdin = staged SCRIPT) runs
* -- "AS /mnt/MAUX/GOODMOD.S -o /mnt/MAUX/GOODMOD.OBJ" then
* "EXIT" --
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

* -- run 2: `AS` spawned DIRECTLY on a syntax-error source, fd 2
* -- dup'd to a harness file so the diagnostic can be read back.
            lda   #3
            sta   R_STEP
            jsr   CREAT_ASERR
            bcc   :aerr_creat
            jmp   P_ERR
:aerr_creat
            jsr   OPN_ASERR_WR
            bcc   :aserr_opened
            jmp   P_ERR
:aserr_opened
            sta   R_ASERR_FD
            lda   #4
            sta   R_STEP
            jsr   SPAWN_AS
            bcc   :as_spawned
            jmp   P_ERR
:as_spawned sta   R_AS_PID
            lda   R_ASERR_FD
            jsr   CLOSE_FD          ;parent's own copy -- the
                                    ;child holds its dup already
            jsr   WAIT_AS
            bcc   :as_waited
            jmp   P_ERR
:as_waited  sta   R_AS_WAIT

            lda   #5
            sta   R_STEP
            jsr   OPN_ASERR_RD
            bcc   :aerr_reopn
            jmp   P_ERR
:aerr_reopn
            sta   R_ASERR_FD
            jsr   READ_ASERR
            bcc   :aserr_read
            jmp   P_ERR
:aserr_read lda   R_ASERR_FD
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

            ; "/mnt/MAUX/ASERR" -- 12 chars, MLI pathname
            lda   #15
            sta   ASERR_PATH
            ldx   #0
:cp2        lda   ASERR_PTH_TXT,x
            sta   ASERR_PATH+1,x
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

            ;"/bin/AS" -- liba string, spawn path
            ldx   #0
:cp4        lda   ASBIN_PTH_TXT,x
            sta   AS_PATH,x
            inx
            cpx   #ASBIN_PTH_LEN
            bne   :cp4
            stz   AS_PATH+ASBIN_PTH_LEN

            ;"AS" -- liba string, argv[0]
            lda   #$C1
            sta   AS_ARG0
            lda   #$D3
            sta   AS_ARG0+1
            stz   AS_ARG0+2

            ;"/mnt/MAUX/BADMOD.S" -- liba string, argv[1]
            ldx   #0
:cp5        lda   BADSRC_TXT,x
            sta   BADSRC_ARG,x
            inx
            cpx   #BADSRC_LEN
            bne   :cp5
            stz   BADSRC_ARG+BADSRC_LEN

            ;"-o" -- liba string, argv[2]
            lda   #$AD
            sta   OFLAG_ARG
            lda   #$EF
            sta   OFLAG_ARG+1
            stz   OFLAG_ARG+2

            ;"/mnt/MAUX/BADMOD.OBJ" -- liba string, argv[3]
            ldx   #0
:cp6        lda   BADOBJ_TXT,x
            sta   BADOBJ_ARG,x
            inx
            cpx   #BADOBJ_LEN
            bne   :cp6
            stz   BADOBJ_ARG+BADOBJ_LEN
            rts

SCRPT_PTH_TXT asc "/mnt/MAUX/SCRIPT"
ASERR_PTH_TXT asc "/mnt/MAUX/ASERR"

OPN_SCRPT_FL
            lda   #<SCRIPT_PATH
            sta   OPEN_PARM+1
            lda   #>SCRIPT_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPN_ASERR_WR
            lda   #<ASERR_PATH
            sta   OPEN_PARM+1
            lda   #>ASERR_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPN_ASERR_RD
            lda   #<ASERR_PATH
            sta   OPEN_PARM+1
            lda   #>ASERR_PATH
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

CREAT_ASERR lda   #<ASERR_PATH
            sta   CREAT_PARM+1
            lda   #>ASERR_PATH
            sta   CREAT_PARM+2
            lda   #7          ;PCOUNT_CREATE (mli.equ) -- the
                              ;field COUNT, not CREAT_PARM's
                              ;12-byte struct SIZE (bug found
                              ;2026-08-20, task #8 phase C:
                              ;dormant since run 2 was never
                              ;reached before the ISLOC/
                              ;SENDMSG/bug-4 hang was fixed --
                              ;the kernel's own pcount check
                              ;rejects 12 with a raw MLI $04
                              ;BAD PCOUNT)
            sta   CREAT_PARM
            lda   #$C3              ;ACCESS_UNLKD
            sta   CREAT_PARM+3
            lda   #$06              ;FTYPE_BIN (v1 -- as itself
                                    ;never writes this file; its
                                    ;own -o target does)
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

READ_ASERR  lda   R_ASERR_FD
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
            sta   R_ASE_TRANS
            lda   READ_PARM+7
            sta   R_ASE_TRANS+1
            ldy   #0
:cp         cpy   #RBLEN
            beq   :done
            lda   IO_BUF,y
            sta   R_ASE_DATA,y
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

SPAWN_AS    lda   #<AS_ARG0
            sta   AS_ARGV
            lda   #>AS_ARG0
            sta   AS_ARGV+1
            lda   #<BADSRC_ARG
            sta   AS_ARGV+2
            lda   #>BADSRC_ARG
            sta   AS_ARGV+3
            lda   #<OFLAG_ARG
            sta   AS_ARGV+4
            lda   #>OFLAG_ARG
            sta   AS_ARGV+5
            lda   #<BADOBJ_ARG
            sta   AS_ARGV+6
            lda   #>BADOBJ_ARG
            sta   AS_ARGV+7
            stz   AS_ARGV+8
            stz   AS_ARGV+9

            lda   #FDACT_DUP
            sta   FDA_BUF+0
            lda   #FD_STDERR
            sta   FDA_BUF+1
            lda   R_ASERR_FD
            sta   FDA_BUF+2
            lda   #FDACT_CLOSE
            sta   FDA_BUF+3
            lda   R_ASERR_FD
            sta   FDA_BUF+4
            stz   FDA_BUF+5
            stz   FDA_BUF+6            ;FDACT_END

            lda   #<AS_PATH
            sta   SPAWN_PARM
            lda   #>AS_PATH
            sta   SPAWN_PARM+1
            lda   #<AS_ARGV
            sta   SPAWN_PARM+2
            lda   #>AS_ARGV
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

WAIT_AS     lda   #<R_AS_STATUS
            sta   WAIT_PARM
            lda   #>R_AS_STATUS
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

PAR_PROC_LEN equ *-PARENT_PROC
