*---------------------------------------------------------------
* fleettestb.s -- image body for fleettest.s (`make check-
* fleet`).
*
* Two phases, one PARENT_PROC, same shape as ldtestb.s's own two
* runs:
*
*  Phase 1 -- `sh` (stdin redirected from a staged
*  /mnt/MAUX/SCRIPT) runs the seventeen-line fleet script (sort/
*  uniq/tr/od/file, redirection and `>>` append) then `EXIT`.
*  The RESULT files it writes (SORTOUT, SORTROUT, ... COMBO) are
*  read back and compared byte-exact by scripts/check_fleet.py
*  directly off the built .po image (prodos.read), same
*  mechanism check_sh.py uses for EDITED/CATOUT -- far simpler
*  than peeking result buffers out of aux memory for a dozen
*  files.
*
*  Phase 2 -- `cmp` spawned DIRECTLY (twice): `sh` has no `if`
*  and cannot redirect fd 2, but cmp's entire purpose is its
*  exit status and its differ message (on STDOUT since
*  2026-09-13: POSIX cmp's STDOUT section puts it there; it
*  used to be fd 2), so this harness spawns it itself, fd 1
*  dup'd to a harness-owned file it reopens and
*  reads back afterward -- the exact technique ldtestb.s's own
*  SPAWN_LD uses for LD's missing-module diagnostic.
*---------------------------------------------------------------

* Result addresses in the parent process bank (page $13).
R_SCRIPT_FD   equ $1300
R_SH_PID      equ $1301
R_SH_WAIT     equ $1302
R_SH_STATUS   equ $1303
R_CMP1_FD     equ $1304
R_CMP1_PID    equ $1305
R_CMP1_WAIT   equ $1306
R_CMP1_STATUS equ $1307
R_CMP1_TRANS  equ $1308   ;2 bytes
R_CMP1_DATA   equ $130A   ;16 bytes -- identical run, expect 0
                          ;bytes transferred
R_CMP2_FD     equ $1320
R_CMP2_PID    equ $1321
R_CMP2_WAIT   equ $1322
R_CMP2_STATUS equ $1323
R_CMP2_TRANS  equ $1324   ;2 bytes
R_CMP2_DATA   equ $1326   ;64 bytes -- differ run's stdout
R_DONE        equ $1390
R_ERR         equ $1391
R_STEP        equ $1392

* Parent process scratch (pages $10-$12).
SCRIPT_PATH   equ $1000   ;/mnt/MAUX/SCRIPT, MLI pathname
SH_PATH       equ $1020   ;/bin/sh, liba string (spawn path)
SH_ARG0       equ $1040   ;"SH", liba string
CMP_PATH      equ $1060 ;/bin/CMP, liba string (spawn path)
CMP_ARG0      equ $1080   ;"CMP", liba string
CMPA_ARG      equ $10A0   ;/mnt/MAUX/CMPA, liba string (argv)
CMPB_ARG      equ $10C0   ;/mnt/MAUX/CMPB, liba string (argv)
CMPC_ARG      equ $10E0   ;/mnt/MAUX/CMPC, liba string (argv)
CMPERR1_PATH  equ $1100   ;/mnt/MAUX/CMPERR1, MLI pathname
CMPERR2_PATH  equ $1120   ;/mnt/MAUX/CMPERR2, MLI pathname

OPEN_PARM   equ $1140
CLOSE_PARM  equ $1150
READ_PARM   equ $1160
WAIT_PARM   equ $1170
SPAWN_PARM  equ $1180
CREAT_PARM  equ $1190
SH_ARGV     equ $11B0     ;2 entries: SH,NULL (4 bytes)
CMP_ARGV    equ $11B4     ;4 entries: CMP,file1,file2,NULL
                          ;(8 bytes) -- rebuilt per spawn
FDA_BUF     equ $11C0     ;fdactions: DUP+CLOSE+END = 7 bytes
IO_BUF      equ $11D0     ;up to 64 bytes -- stays clear of the
                          ;page $13 result block above

*---------------------------------------------------------------
* Boot helpers -- identical shape to ldtestb.s's own.
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

BANNER      asc   "MAUX FLEET"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 (absolute JSR/JMP operands need it there) -- same
* reason ldtestb.s's own PARENT_PROC is copied, not run in
* place.
*---------------------------------------------------------------
PARENT_PROC bra   FLB_EQHOP
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
CMPBIN_TXT
                ;/bin/CMP
                dfb $AF,$E2,$E9,$EE,$AF,$C3,$CD,$D0
CMPBIN_LEN equ  *-CMPBIN_TXT
CMPARG0_TXT
                ;CMP
                dfb  $C3,$CD,$D0
CMPARG0_LEN    equ  *-CMPARG0_TXT
CMPA_TXT
                ;/mnt/MAUX/CMPA
                dfb $AF,$ED,$EE,$F4,$AF,$CD,$C1,$D5,$D8
                dfb $AF,$C3,$CD,$D0,$C1
CMPA_LEN       equ  *-CMPA_TXT
CMPB_TXT
                ;/mnt/MAUX/CMPB
                dfb $AF,$ED,$EE,$F4,$AF,$CD,$C1,$D5,$D8
                dfb $AF,$C3,$CD,$D0,$C2
CMPB_LEN       equ  *-CMPB_TXT
CMPC_TXT
                ;/mnt/MAUX/CMPC
                dfb $AF,$ED,$EE,$F4,$AF,$CD,$C1,$D5,$D8
                dfb $AF,$C3,$CD,$D0,$C3
CMPC_LEN       equ  *-CMPC_TXT
FLB_EQHOP
            stz   R_ERR
            stz   R_STEP
            jsr   SETUP_PATHS

* -- Phase 1: `sh` (stdin = staged SCRIPT) runs the fleet
* -- script, then `EXIT`. Its output files are checked host-
* -- side by scripts/check_fleet.py, reading the built image
* -- directly.
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

* -- Phase 2, run A: `cmp /mnt/MAUX/CMPA /mnt/MAUX/CMPC`
* (identical
* -- files) -- expect exit 0, no stderr output at all.
            lda   #3
            sta   R_STEP
            jsr   CREAT_CMPERR1
            bcc   :cerr1_creat
            jmp   P_ERR
:cerr1_creat
            jsr   OPN_CMPERR1
            bcc   :c1wopened
            jmp   P_ERR
:c1wopened
            sta   R_CMP1_FD
            lda   #4
            sta   R_STEP
            jsr   SPAWN_CMP1
            bcc   :cmp1_spawned
            jmp   P_ERR
:cmp1_spawned
            sta   R_CMP1_PID
            lda   R_CMP1_FD
            jsr   CLOSE_FD          ;parent's own copy -- the
                                    ;child holds its dup already
            jsr   WAIT_CMP1
            bcc   :cmp1_waited
            jmp   P_ERR
:cmp1_waited
            sta   R_CMP1_WAIT

            lda   #5
            sta   R_STEP
            jsr   OPN_CMPERR1
            bcc   :c1ropened
            jmp   P_ERR
:c1ropened
            sta   R_CMP1_FD
            jsr   READ_CMP1
            bcc   :cerr1_read
            jmp   P_ERR
:cerr1_read lda   R_CMP1_FD
            jsr   CLOSE_FD

* -- Phase 2, run B: `cmp /mnt/MAUX/CMPA /mnt/MAUX/CMPB` (differ
* at
* -- byte 16, line 2) -- expect exit 1 and a "differ:" message.
            lda   #6
            sta   R_STEP
            jsr   CREAT_CMPERR2
            bcc   :cerr2_creat
            jmp   P_ERR
:cerr2_creat
            jsr   OPN_CMPERR2
            bcc   :c2wopened
            jmp   P_ERR
:c2wopened
            sta   R_CMP2_FD
            lda   #7
            sta   R_STEP
            jsr   SPAWN_CMP2
            bcc   :cmp2_spawned
            jmp   P_ERR
:cmp2_spawned
            sta   R_CMP2_PID
            lda   R_CMP2_FD
            jsr   CLOSE_FD
            jsr   WAIT_CMP2
            bcc   :cmp2_waited
            jmp   P_ERR
:cmp2_waited
            sta   R_CMP2_WAIT

            lda   #8
            sta   R_STEP
            jsr   OPN_CMPERR2
            bcc   :c2ropened
            jmp   P_ERR
:c2ropened
            sta   R_CMP2_FD
            jsr   READ_CMP2
            bcc   :cerr2_read
            jmp   P_ERR
:cerr2_read lda   R_CMP2_FD
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

            ;"/bin/CMP" -- liba string, spawn path
            ldx   #0
:cp3        lda   CMPBIN_TXT,x
            sta   CMP_PATH,x
            inx
            cpx   #CMPBIN_LEN
            bne   :cp3
            stz   CMP_PATH+CMPBIN_LEN

            ;"CMP" -- liba string, argv[0]
            ldx   #0
:cp4        lda   CMPARG0_TXT,x
            sta   CMP_ARG0,x
            inx
            cpx   #CMPARG0_LEN
            bne   :cp4
            stz   CMP_ARG0+CMPARG0_LEN

            ;"/mnt/MAUX/CMPA" -- liba string, argv
            ldx   #0
:cp5        lda   CMPA_TXT,x
            sta   CMPA_ARG,x
            inx
            cpx   #CMPA_LEN
            bne   :cp5
            stz   CMPA_ARG+CMPA_LEN

            ;"/mnt/MAUX/CMPB" -- liba string, argv
            ldx   #0
:cp6        lda   CMPB_TXT,x
            sta   CMPB_ARG,x
            inx
            cpx   #CMPB_LEN
            bne   :cp6
            stz   CMPB_ARG+CMPB_LEN

            ;"/mnt/MAUX/CMPC" -- liba string, argv
            ldx   #0
:cp7        lda   CMPC_TXT,x
            sta   CMPC_ARG,x
            inx
            cpx   #CMPC_LEN
            bne   :cp7
            stz   CMPC_ARG+CMPC_LEN

            ; "/mnt/MAUX/CMPERR1" -- 14 chars, MLI pathname
            lda   #17
            sta   CMPERR1_PATH
            ldx   #0
:cp8        lda   CMPERR1_TXT,x
            sta   CMPERR1_PATH+1,x
            inx
            cpx   #17
            bne   :cp8

            ; "/mnt/MAUX/CMPERR2" -- 14 chars, MLI pathname
            lda   #17
            sta   CMPERR2_PATH
            ldx   #0
:cp9        lda   CMPERR2_TXT,x
            sta   CMPERR2_PATH+1,x
            inx
            cpx   #17
            bne   :cp9
            rts

SCRPT_PTH_TXT asc "/mnt/MAUX/SCRIPT"
CMPERR1_TXT   asc "/mnt/MAUX/CMPERR1"
CMPERR2_TXT   asc "/mnt/MAUX/CMPERR2"

OPN_SCRPT_FL
            lda   #<SCRIPT_PATH
            sta   OPEN_PARM+1
            lda   #>SCRIPT_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPN_CMPERR1
            lda   #<CMPERR1_PATH
            sta   OPEN_PARM+1
            lda   #>CMPERR1_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPN_CMPERR2
            lda   #<CMPERR2_PATH
            sta   OPEN_PARM+1
            lda   #>CMPERR2_PATH
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

CREAT_CMPERR1
            lda   #<CMPERR1_PATH
            sta   CREAT_PARM+1
            lda   #>CMPERR1_PATH
            sta   CREAT_PARM+2
            bra   CREAT_COMMON

CREAT_CMPERR2
            lda   #<CMPERR2_PATH
            sta   CREAT_PARM+1
            lda   #>CMPERR2_PATH
            sta   CREAT_PARM+2
CREAT_COMMON
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

READ_CMP1   lda   R_CMP1_FD
            sta   READ_PARM+1
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #16
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
            sta   R_CMP1_TRANS
            lda   READ_PARM+7
            sta   R_CMP1_TRANS+1
            ldy   #0
:cp         cpy   #16
            beq   :done
            lda   IO_BUF,y
            sta   R_CMP1_DATA,y
            iny
            bra   :cp
:done       clc
            rts
:err        sec
            rts

READ_CMP2   lda   R_CMP2_FD
            sta   READ_PARM+1
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #64
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
            sta   R_CMP2_TRANS
            lda   READ_PARM+7
            sta   R_CMP2_TRANS+1
            ldy   #0
:cp         cpy   #64
            beq   :done
            lda   IO_BUF,y
            sta   R_CMP2_DATA,y
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

* -- SPAWN_CMP1 -- argv = CMP, /mnt/MAUX/CMPA, /mnt/MAUX/CMPC
* (byte-
* -- for-byte identical files -- expect silent exit 0). fd 2
* -- dup'd to R_CMP1_FD.
SPAWN_CMP1  lda   #<CMP_ARG0
            sta   CMP_ARGV
            lda   #>CMP_ARG0
            sta   CMP_ARGV+1
            lda   #<CMPA_ARG
            sta   CMP_ARGV+2
            lda   #>CMPA_ARG
            sta   CMP_ARGV+3
            lda   #<CMPC_ARG
            sta   CMP_ARGV+4
            lda   #>CMPC_ARG
            sta   CMP_ARGV+5
            stz   CMP_ARGV+6
            stz   CMP_ARGV+7

            lda   #FDACT_DUP
            sta   FDA_BUF+0
            lda   #FD_STDERR
            sta   FDA_BUF+1
            lda   R_CMP1_FD
            sta   FDA_BUF+2
            lda   #FDACT_CLOSE
            sta   FDA_BUF+3
            lda   R_CMP1_FD
            sta   FDA_BUF+4
            stz   FDA_BUF+5
            stz   FDA_BUF+6            ;FDACT_END

            lda   #<CMP_PATH
            sta   SPAWN_PARM
            lda   #>CMP_PATH
            sta   SPAWN_PARM+1
            lda   #<CMP_ARGV
            sta   SPAWN_PARM+2
            lda   #>CMP_ARGV
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

WAIT_CMP1   lda   #<R_CMP1_STATUS
            sta   WAIT_PARM
            lda   #>R_CMP1_STATUS
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

* -- SPAWN_CMP2 -- argv = CMP, /mnt/MAUX/CMPA, /mnt/MAUX/CMPB
* (differ
* -- at byte 16, line 2 -- expect a "differ:" message and exit
* -- 1). fd 2 dup'd to R_CMP2_FD.
SPAWN_CMP2  lda   #<CMP_ARG0
            sta   CMP_ARGV
            lda   #>CMP_ARG0
            sta   CMP_ARGV+1
            lda   #<CMPA_ARG
            sta   CMP_ARGV+2
            lda   #>CMPA_ARG
            sta   CMP_ARGV+3
            lda   #<CMPB_ARG
            sta   CMP_ARGV+4
            lda   #>CMPB_ARG
            sta   CMP_ARGV+5
            stz   CMP_ARGV+6
            stz   CMP_ARGV+7

            lda   #FDACT_DUP
            sta   FDA_BUF+0
            lda   #FD_STDOUT  ;POSIX: msg on fd 1
            sta   FDA_BUF+1
            lda   R_CMP2_FD
            sta   FDA_BUF+2
            lda   #FDACT_CLOSE
            sta   FDA_BUF+3
            lda   R_CMP2_FD
            sta   FDA_BUF+4
            stz   FDA_BUF+5
            stz   FDA_BUF+6            ;FDACT_END

            lda   #<CMP_PATH
            sta   SPAWN_PARM
            lda   #>CMP_PATH
            sta   SPAWN_PARM+1
            lda   #<CMP_ARGV
            sta   SPAWN_PARM+2
            lda   #>CMP_ARGV
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

WAIT_CMP2   lda   #<R_CMP2_STATUS
            sta   WAIT_PARM
            lda   #>R_CMP2_STATUS
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

PAR_PROC_LEN equ *-PARENT_PROC
