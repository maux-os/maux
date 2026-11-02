*---------------------------------------------------------------
* seektestb.s -- image body for seektest.s. Split out so the
* top-level stays a thin MANIFEST (learning:01M051EM2HQ3ZVJTR1
* W9P3G86J), same convention as every other *testb.s in this
* tree.
*
* PHASE A (docs/FLEET.md "`>>` and the seek family" -- the
* SEEK_SET/SEEK_CUR/SEEK_END half): spawns the real, liba-linked
* /bin/SEEKWR (src/test/seekwr.s), which exercises liba's
* own
* LSEEK three ways and independently re-verifies each landing
* with a raw GET_MARK, writing 10 result bytes to
* /mnt/MAUX/SEEKRES. This parent waits, then reads that file
* back.
*
* PHASE B (the `>>` end-to-end half): stages
* /mnt/MAUX/SEEKSCRIPT
* (built by scripts/build_seek_image.py) as sh's fd 0, spawns
* the real /bin/sh, waits, then reads /mnt/MAUX/APPF back --
* proving `echo a > F` followed by `echo b >> F` leaves F
* holding BOTH, in order, not just the second write.
*---------------------------------------------------------------

* Result addresses in the parent process bank.
R_SEEKWR_PID    equ $1300
R_SEEKWR_WPID   equ $1301
R_SEEKWR_STAT equ $1302
R_SEEKRES_FD    equ $1303
R_SEEKRES_TRN equ $1304    ;2 bytes
R_SEEKRES_DAT  equ $1306    ;10 bytes (3 marks x3 + errflags)
R_PHASEA_DONE   equ $1310

R_SH_PID        equ $1320
R_SCRIPT_FD     equ $1321
R_SH_WPID       equ $1322
R_SH_STATUS     equ $1323
R_APPF_FD       equ $1324
R_APPF_TRANS    equ $1325    ;2 bytes
R_APPF_DATA     equ $1327    ;8 bytes
R_PHASEB_DONE   equ $1330

R_DONE          equ $1390
R_ERR           equ $1391
R_STEP          equ $1392

* Parent process scratch.
SEEKWR_PATH equ $1000 ;/bin/SEEKWR, high-bit NUL liba
                             ;string (spawn path)
SEEKWR_ARG0 equ $1020        ;"SEEKWR", high-bit NUL liba string
SEEKRES_PATH equ $1040       ;/mnt/MAUX/SEEKRES, ProDOS MLI
                             ;pathname
SCRIPT_PATH equ $1060        ;/mnt/MAUX/SEEKSCRIPT, ProDOS MLI
                             ;pathname
SH_PATH     equ $1090        ;/bin/sh, high-bit NUL liba
                             ;string
SH_ARG0     equ $10B0        ;"SH", high-bit NUL liba string
APPF_PATH   equ $10C0 ;/mnt/MAUX/APPF, ProDOS MLI pathname

OPEN_PARM   equ $1100
CLOSE_PARM  equ $1110
READ_PARM   equ $1120
WAIT_PARM   equ $1130
SPAWN_PARM  equ $1140
ARGV_ARR    equ $1150        ;4 bytes: argv[0] ptr, argv[1]=0/0
FDA_BUF     equ $1160        ;fdactions: DUP+CLOSE + END = 7
                             ;bytes
IO_BUF      equ $1200        ;scratch read buffer

*---------------------------------------------------------------
* Boot helpers -- identical shape to every other *testb.s's own.
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

BANNER      asc   "MAUX SEEK"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 -- same reason every other *testb.s's own PARENT_PROC
* is: absolute JSR/JMP operands to the helper subroutines below.
*---------------------------------------------------------------
PARENT_PROC bra   SKB_EQHOP
*-- The pathname/label data lives INSIDE the staged parent
*-- span, right behind the entry hop: pid 1 executes a COPY
*-- of [PARENT_PROC..+PAR_PROC_LEN] in its own bank, so data
*-- outside the span reads as never-copied garbage there --
*-- found the hard way on this very edit. The hop keeps the
*-- entry at PARENT_PROC; the placement keeps every *_LEN
*-- equ defined before its immediate use (S9 EQU burn-down
*-- 2026-08-29).
SEEKWR_PTHTXT  asc "/bin/SEEKWR"
SEEKWR_PTHLEN  equ *-SEEKWR_PTHTXT
SEEKWR_A0_TXT   asc "SEEKWR"
SEEKWR_A0_LEN   equ *-SEEKWR_A0_TXT
SEEKRES_PTXT asc "/mnt/MAUX/SEEKRES"
SCRIPT_PTHTXT  asc "/mnt/MAUX/SEEKSCRIPT"
SHBIN_PTH_TXT   asc "/bin/sh"
SHBIN_PTH_LEN   equ *-SHBIN_PTH_TXT
SH_A0_TXT       asc "SH"
SH_A0_LEN       equ *-SH_A0_TXT
SKB_EQHOP
            stz   R_ERR
            stz   R_STEP
            stz   R_PHASEA_DONE
            stz   R_PHASEB_DONE
            jsr   SETUP_PATHS

* ---- PHASE A: SEEKWR (SEEK_SET/SEEK_CUR/SEEK_END + GET_MARK) -
            lda   #1
            sta   R_STEP
            jsr   SPAWN_SEEKWR
            bcc   :spawnedA
            jmp   P_ERR
:spawnedA   sta   R_SEEKWR_PID
            jsr   WAIT_SEEKWR
            bcc   :waitedA
            jmp   P_ERR
:waitedA    sta   R_SEEKWR_WPID

            lda   #2
            sta   R_STEP
            jsr   OPEN_SEEKRES
            bcc   :openedA
            jmp   P_ERR
:openedA    sta   R_SEEKRES_FD
            jsr   READ_SEEKRES
            bcc   :readA
            jmp   P_ERR
:readA      lda   R_SEEKRES_FD
            jsr   CLOSE_FD

            lda   #$AA
            sta   R_PHASEA_DONE      ;phase A complete --
                                     ;evidence durable even if
                                     ;phase B below hangs

* ---- PHASE B: sh's `>>` end to end ----
            lda   #3
            sta   R_STEP
            jsr   OPN_SCRPT_FL
            bcc   :openedscr
            jmp   P_ERR
:openedscr  sta   R_SCRIPT_FD

            lda   #4
            sta   R_STEP
            jsr   SPAWN_SH
            bcc   :spawnedB
            jmp   P_ERR
:spawnedB   sta   R_SH_PID
            jsr   WAIT_SH
            bcc   :waitedB
            jmp   P_ERR
:waitedB    sta   R_SH_WPID
            lda   R_SCRIPT_FD
            jsr   CLOSE_FD

            lda   #5
            sta   R_STEP
            jsr   OPEN_APPF
            bcc   :openedB
            jmp   P_ERR
:openedB    sta   R_APPF_FD
            jsr   READ_APPF
            bcc   :readB
            jmp   P_ERR
:readB      lda   R_APPF_FD
            jsr   CLOSE_FD

            lda   #$AA
            sta   R_PHASEB_DONE

            lda   #$AA
            sta   R_DONE
:done       bra   :done

P_ERR       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:park       bra   :park

*---------------------------------------------------------------
SETUP_PATHS
            ; "/bin/SEEKWR" -- high-bit NUL liba string,
            ; spawn
            ; path
            ldx   #0
:cp1        lda   SEEKWR_PTHTXT,x
            sta   SEEKWR_PATH,x
            inx
            cpx   #SEEKWR_PTHLEN
            bne   :cp1
            stz   SEEKWR_PATH+SEEKWR_PTHLEN

            ; "SEEKWR" -- argv[0]
            ldx   #0
:cp2        lda   SEEKWR_A0_TXT,x
            sta   SEEKWR_ARG0,x
            inx
            cpx   #SEEKWR_A0_LEN
            bne   :cp2
            stz   SEEKWR_ARG0+SEEKWR_A0_LEN

            ; "/mnt/MAUX/SEEKRES" -- 14 chars, MLI pathname
            lda   #17
            sta   SEEKRES_PATH
            ldx   #0
:cp3        lda   SEEKRES_PTXT,x
            sta   SEEKRES_PATH+1,x
            inx
            cpx   #17
            bne   :cp3

            ; "/mnt/MAUX/SEEKSCRIPT" -- 17 chars, MLI pathname
            lda   #20
            sta   SCRIPT_PATH
            ldx   #0
:cp4        lda   SCRIPT_PTHTXT,x
            sta   SCRIPT_PATH+1,x
            inx
            cpx   #20
            bne   :cp4

            ; "/bin/sh" -- high-bit NUL liba string, spawn
            ; path
            ldx   #0
:cp5        lda   SHBIN_PTH_TXT,x
            sta   SH_PATH,x
            inx
            cpx   #SHBIN_PTH_LEN
            bne   :cp5
            stz   SH_PATH+SHBIN_PTH_LEN

            ; "SH" -- argv[0]
            ldx   #0
:cp6        lda   SH_A0_TXT,x
            sta   SH_ARG0,x
            inx
            cpx   #SH_A0_LEN
            bne   :cp6
            stz   SH_ARG0+SH_A0_LEN

            ; "/mnt/MAUX/APPF" -- 11 chars, MLI pathname
            lda   #14
            sta   APPF_PATH
            ldx   #0
:cp7        lda   APPF_PTH_TXT,x
            sta   APPF_PATH+1,x
            inx
            cpx   #14
            bne   :cp7
            rts

APPF_PTH_TXT    asc "/mnt/MAUX/APPF"

*---------------------------------------------------------------
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

OPEN_SEEKRES
            lda   #<SEEKRES_PATH
            sta   OPEN_PARM+1
            lda   #>SEEKRES_PATH
            sta   OPEN_PARM+2
            jmp   OPEN_COMMON

OPEN_APPF   lda   #<APPF_PATH
            sta   OPEN_PARM+1
            lda   #>APPF_PATH
            sta   OPEN_PARM+2
            jmp   OPEN_COMMON

CLOSE_FD    sta   CLOSE_PARM+1
            lda   #1
            sta   CLOSE_PARM
            lda   #<CLOSE_PARM
            ldx   #>CLOSE_PARM
            ldy   #SYS_CLOSE
            jsr   $FF00
            rts

READ_SEEKRES
            lda   R_SEEKRES_FD
            sta   READ_PARM+1
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #10
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
            sta   R_SEEKRES_TRN
            lda   READ_PARM+7
            sta   R_SEEKRES_TRN+1
            ldy   #0
:cp         cpy   #10
            beq   :done
            lda   IO_BUF,y
            sta   R_SEEKRES_DAT,y
            iny
            bra   :cp
:done       clc
            rts
:err        sec
            rts

READ_APPF   lda   R_APPF_FD
            sta   READ_PARM+1
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #8
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
            sta   R_APPF_TRANS
            lda   READ_PARM+7
            sta   R_APPF_TRANS+1
            ldy   #0
:cp         cpy   #8
            beq   :done
            lda   IO_BUF,y
            sta   R_APPF_DATA,y
            iny
            bra   :cp
:done       clc
            rts
:err        sec
            rts

SPAWN_SEEKWR
            lda   #<SEEKWR_ARG0
            sta   ARGV_ARR
            lda   #>SEEKWR_ARG0
            sta   ARGV_ARR+1
            stz   ARGV_ARR+2
            stz   ARGV_ARR+3

            lda   #<SEEKWR_PATH
            sta   SPAWN_PARM
            lda   #>SEEKWR_PATH
            sta   SPAWN_PARM+1
            lda   #<ARGV_ARR
            sta   SPAWN_PARM+2
            lda   #>ARGV_ARR
            sta   SPAWN_PARM+3
            stz   SPAWN_PARM+4      ;fdactions ptr = NULL
            stz   SPAWN_PARM+5
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            rts

WAIT_SEEKWR lda   #<R_SEEKWR_STAT
            sta   WAIT_PARM
            lda   #>R_SEEKWR_STAT
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

OPN_SCRPT_FL
            lda   #<SCRIPT_PATH
            sta   OPEN_PARM+1
            lda   #>SCRIPT_PATH
            sta   OPEN_PARM+2
            jmp   OPEN_COMMON

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

PAR_PROC_LEN equ *-PARENT_PROC
