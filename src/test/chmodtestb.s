*---------------------------------------------------------------
* chmodtestb.s -- image body for chmodtest.s (`make check-
* chmod`).
*
* Two phases, one PARENT_PROC, same shape as fleettestb.s's own:
*
*  Phase 1 -- `sh` (stdin redirected from a staged /mnt/MAUX/
*  SCRIPT) locks LOCKFILE, round-trips RWFILE through lock then
*  unlock, and runs `df` twice (bare, then with an explicit
*  volume argument), redirecting both runs to files. scripts/
*  check_chmod.py reads every result file (DFOUT/DFOUT2) AND
*  the final file metadata (LOCKFILE/RWFILE's access/type/
*  aux_type/dates) straight off the built .po image afterward --
*  the same "read the disk directly" mechanism check_fleet.py
*  uses for SORTOUT etc.
*
*  Phase 2 -- `rm` spawned DIRECTLY against the still-locked
*  LOCKFILE: `sh` has no way to hand this harness rm's exit
*  status on its own fd 2, so the harness spawns rm itself, fd 2
*  dup'd to a harness-owned file it reopens and reads back --
*  the exact technique fleettestb.s's own SPAWN_CMP1/2 use.
*  Expect a NONZERO exit and LOCKFILE still present afterward --
*  the resists-deletion proof.
*---------------------------------------------------------------

* Result addresses in the parent process bank (page $13).
R_SCRIPT_FD   equ $1300
R_SH_PID      equ $1301
R_SH_WAIT     equ $1302
R_SH_STATUS   equ $1303
R_RM_FD       equ $1304
R_RM_PID      equ $1305
R_RM_WAIT     equ $1306
R_RM_STATUS   equ $1307
R_RM_TRANS    equ $1308   ;2 bytes
R_RM_DATA     equ $130A   ;40 bytes -- rm's own stderr message
R_DONE        equ $1390
R_ERR         equ $1391
R_STEP        equ $1392

* Parent process scratch (pages $10-$12).
SCRIPT_PATH   equ $1000   ;/mnt/MAUX/SCRIPT, MLI pathname
SH_PATH       equ $1020   ;/bin/sh, liba string (spawn path)
SH_ARG0       equ $1040   ;"SH", liba string
RM_PATH       equ $1060 ;/bin/RM, liba string (spawn path)
RM_ARG0       equ $1080   ;"RM", liba string
LOCKFILE_ARG  equ $10A0 ;/mnt/MAUX/LOCKFILE, liba string (argv)
RMERR_PATH    equ $10C0   ;/mnt/MAUX/RMERR, MLI pathname

OPEN_PARM   equ $1140
CLOSE_PARM  equ $1150
READ_PARM   equ $1160
WAIT_PARM   equ $1170
SPAWN_PARM  equ $1180
CREAT_PARM  equ $1190
SH_ARGV     equ $11B0     ;2 entries: SH,NULL (4 bytes)
RM_ARGV     equ $11B4     ;3 entries: RM,LOCKFILE,NULL (6 bytes)
FDA_BUF     equ $11C0     ;fdactions: DUP+CLOSE+END = 7 bytes
IO_BUF      equ $11D0     ;up to 64 bytes -- stays clear of the
                          ;page $13 result block above

*---------------------------------------------------------------
* Boot helpers -- identical shape to fleettestb.s's own.
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

BANNER      asc   "MAUX CHMOD"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 (absolute JSR/JMP operands need it there) -- same
* reason fleettestb.s's own PARENT_PROC is copied, not run in
* place.
*---------------------------------------------------------------
PARENT_PROC bra   CHB_EQHOP
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
RMBIN_PTH_TXT
                ;/bin/RM
                dfb $AF,$E2,$E9,$EE,$AF,$D2,$CD
RMBIN_PTH_LEN  equ  *-RMBIN_PTH_TXT
LOCKFILE_TXT
                ;/mnt/MAUX/LOCKFILE
                dfb $AF,$ED,$EE,$F4,$AF,$CD,$C1,$D5,$D8
                dfb $AF,$CC,$CF,$C3,$CB,$C6,$C9,$CC,$C5
LOCKFILE_LEN   equ  *-LOCKFILE_TXT
CHB_EQHOP
            stz   R_ERR
            stz   R_STEP
            jsr   SETUP_PATHS

* -- Phase 1: `sh` (stdin = staged SCRIPT) locks LOCKFILE,
* -- round-trips RWFILE, runs `df` twice, then `EXIT`. Every
* -- result is checked host-side by scripts/check_chmod.py,
* -- reading the built image directly.
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

* -- Phase 2: `rm /mnt/MAUX/LOCKFILE` spawned directly --
* LOCKFILE
* -- is still locked (-dnw, phase 1), so DESTROY must fail. fd 2
* -- dup'd to R_RM_FD.
            lda   #3
            sta   R_STEP
            jsr   CREAT_RMERR
            bcc   :rmerr_creat
            jmp   P_ERR
:rmerr_creat
            jsr   OPN_RMERR
            bcc   :rmwopened
            jmp   P_ERR
:rmwopened
            sta   R_RM_FD
            lda   #4
            sta   R_STEP
            jsr   SPAWN_RM
            bcc   :rm_spawned
            jmp   P_ERR
:rm_spawned
            sta   R_RM_PID
            lda   R_RM_FD
            jsr   CLOSE_FD          ;parent's own copy -- the
                                    ;child holds its dup already
            jsr   WAIT_RM
            bcc   :rm_waited
            jmp   P_ERR
:rm_waited  sta   R_RM_WAIT

            lda   #5
            sta   R_STEP
            jsr   OPN_RMERR
            bcc   :rmropened
            jmp   P_ERR
:rmropened
            sta   R_RM_FD
            jsr   READ_RM
            bcc   :rmerr_read
            jmp   P_ERR
:rmerr_read lda   R_RM_FD
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

            ;"/bin/RM" -- liba string, spawn path
            ldx   #0
:cp3        lda   RMBIN_PTH_TXT,x
            sta   RM_PATH,x
            inx
            cpx   #RMBIN_PTH_LEN
            bne   :cp3
            stz   RM_PATH+RMBIN_PTH_LEN

            ;"RM" -- liba string, argv[0]
            lda   #$D2
            sta   RM_ARG0
            lda   #$CD
            sta   RM_ARG0+1
            stz   RM_ARG0+2

            ;"/mnt/MAUX/LOCKFILE" -- liba string, argv
            ldx   #0
:cp4        lda   LOCKFILE_TXT,x
            sta   LOCKFILE_ARG,x
            inx
            cpx   #LOCKFILE_LEN
            bne   :cp4
            stz   LOCKFILE_ARG+LOCKFILE_LEN

            ; "/mnt/MAUX/RMERR" -- 12 chars, MLI pathname
            lda   #15
            sta   RMERR_PATH
            ldx   #0
:cp5        lda   RMERR_TXT,x
            sta   RMERR_PATH+1,x
            inx
            cpx   #15
            bne   :cp5
            rts

SCRPT_PTH_TXT asc "/mnt/MAUX/SCRIPT"
RMERR_TXT     asc "/mnt/MAUX/RMERR"

OPN_SCRPT_FL
            lda   #<SCRIPT_PATH
            sta   OPEN_PARM+1
            lda   #>SCRIPT_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPN_RMERR
            lda   #<RMERR_PATH
            sta   OPEN_PARM+1
            lda   #>RMERR_PATH
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

CREAT_RMERR
            lda   #<RMERR_PATH
            sta   CREAT_PARM+1
            lda   #>RMERR_PATH
            sta   CREAT_PARM+2
            lda   #7          ;PCOUNT_CREATE (mli.equ) -- the
                              ;field COUNT, not the struct SIZE
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

READ_RM     lda   R_RM_FD
            sta   READ_PARM+1
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #40
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
            sta   R_RM_TRANS
            lda   READ_PARM+7
            sta   R_RM_TRANS+1
            ldy   #0
:cp         cpy   #40
            beq   :done
            lda   IO_BUF,y
            sta   R_RM_DATA,y
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

* -- SPAWN_RM -- argv = RM, /mnt/MAUX/LOCKFILE. fd 2 dup'd to
* -- R_RM_FD.
SPAWN_RM    lda   #<RM_ARG0
            sta   RM_ARGV
            lda   #>RM_ARG0
            sta   RM_ARGV+1
            lda   #<LOCKFILE_ARG
            sta   RM_ARGV+2
            lda   #>LOCKFILE_ARG
            sta   RM_ARGV+3
            stz   RM_ARGV+4
            stz   RM_ARGV+5

            lda   #FDACT_DUP
            sta   FDA_BUF+0
            lda   #FD_STDERR
            sta   FDA_BUF+1
            lda   R_RM_FD
            sta   FDA_BUF+2
            lda   #FDACT_CLOSE
            sta   FDA_BUF+3
            lda   R_RM_FD
            sta   FDA_BUF+4
            stz   FDA_BUF+5
            stz   FDA_BUF+6            ;FDACT_END

            lda   #<RM_PATH
            sta   SPAWN_PARM
            lda   #>RM_PATH
            sta   SPAWN_PARM+1
            lda   #<RM_ARGV
            sta   SPAWN_PARM+2
            lda   #>RM_ARGV
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

WAIT_RM     lda   #<R_RM_STATUS
            sta   WAIT_PARM
            lda   #>R_RM_STATUS
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

PAR_PROC_LEN equ *-PARENT_PROC
