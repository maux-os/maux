*---------------------------------------------------------------
* catreadtestb.s -- image body for catreadtest.s.
* Split out so the top-level stays a thin MANIFEST: real
* Merlin holds the resident top-level source AND the PUT
* file being read in the same 41215-byte buffer, so every
* byte here would come off every module's budget.
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J)
*---------------------------------------------------------------


* Result addresses in the parent process bank.
R_SRC_FD        equ $1200
R_OUT_FD        equ $1201
R_SPAWN_PID     equ $1202
R_WAIT_PID      equ $1203
R_STATUS        equ $1204
R_OUT_FD2       equ $1205
R_TRANS         equ $1206   ;2 bytes: $1206/$1207
R_DATA          equ $1208   ;up to CATBUFLEN bytes
CATBUFLEN       equ 64
R_DONE          equ $1290
R_ERR           equ $1291
R_STEP          equ $1292

* Parent process scratch.
CATSRC_PATH equ $1000 ;/mnt/MAUX/CATSRC, ProDOS MLI pathname
CATOUT_PATH equ $1020 ;/mnt/MAUX/CATOUT, ProDOS MLI pathname
CAT_PATH    equ $1040       ;/bin/CAT, high-bit NUL liba
                            ;string (spawn path)
CAT_ARG0    equ $1060       ;"CAT", high-bit NUL liba string
                            ;(argv[0])
OPEN_PARM   equ $1080
CREATE_PARM equ $1090
CLOSE_PARM  equ $10A0
READ_PARM   equ $10B0
WAIT_PARM   equ $10C0
SPAWN_PARM  equ $10D0
ARGV_ARR    equ $10E0       ;4 bytes: argv[0] ptr, argv[1]=0/0
FDA_BUF     equ $10F0       ;fdactions: DUP/CLOSE x2 + END = 13
                            ;bytes
IO_BUF      equ $1100       ;CATBUFLEN bytes

*---------------------------------------------------------------
* Boot helpers -- identical shape to fileproctest.s's own
* (same BankCopy-via-main bounce, same page-1 frame patch).
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

BANNER      asc   "MAUX CATREAD"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 -- same reason fileproctest.s's own PARENT_PROC is:
* absolute JSR/JMP operands to the helper subroutines below.
*---------------------------------------------------------------
PARENT_PROC bra   CRB_EQHOP
*-- The pathname/label data lives INSIDE the staged parent
*-- span, right behind the entry hop: pid 1 executes a COPY
*-- of [PARENT_PROC..+PAR_PROC_LEN] in its own bank, so data
*-- outside the span reads as never-copied garbage there --
*-- found the hard way on this very edit. The hop keeps the
*-- entry at PARENT_PROC; the placement keeps every *_LEN
*-- equ defined before its immediate use (S9 EQU burn-down
*-- 2026-08-29).
CTBN_PTH_TXT
               ;/bin/CAT
               dfb $AF,$E2,$E9,$EE,$AF,$C3,$C1,$D4
CTBN_PTH_LEN equ *-CTBN_PTH_TXT
CRB_EQHOP
            stz   R_ERR
            stz   R_STEP
            jsr   SETUP_PATHS

            lda   #1
            sta   R_STEP
            jsr   CRT_OUT_FILE
            jsr   OPEN_OUT_FILE
            bcc   :opened_out
            jmp   P_ERR
:opened_out sta   R_OUT_FD

            lda   #2
            sta   R_STEP
            jsr   OPEN_SRC_FILE
            bcc   :opened_src
            jmp   P_ERR
:opened_src sta   R_SRC_FD

            lda   #3
            sta   R_STEP
            jsr   SPAWN_CAT
            bcc   :spawned
            jmp   P_ERR
:spawned    sta   R_SPAWN_PID
            jsr   WAIT_CAT
            bcc   :waited
            jmp   P_ERR
:waited     sta   R_WAIT_PID

            lda   #4
            sta   R_STEP
            lda   R_SRC_FD
            jsr   CLOSE_FD
            lda   R_OUT_FD
            jsr   CLOSE_FD

            lda   #5
            sta   R_STEP
            jsr   OPEN_OUT_FILE
            bcc   :opnd_rdback
            jmp   P_ERR
:opnd_rdback
            sta   R_OUT_FD2
            jsr   READ_BACK
            bcc   :readback
            jmp   P_ERR
:readback   lda   R_OUT_FD2
            jsr   CLOSE_FD

            lda   #$AA
            sta   R_DONE
:done       bra   :done

P_ERR       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:park       bra   :park

SETUP_PATHS
            ;"/mnt/MAUX/CATSRC" -- 13 chars, MLI pathname
            ;(1-byte
            ;count prefix)
            lda   #16
            sta   CATSRC_PATH
            ldx   #0
:cp1        lda   SRC_PATH_TXT,x
            sta   CATSRC_PATH+1,x
            inx
            cpx   #16
            bne   :cp1

            ; "/mnt/MAUX/CATOUT" -- 13 chars, MLI pathname
            lda   #16
            sta   CATOUT_PATH
            ldx   #0
:cp2        lda   OUT_PATH_TXT,x
            sta   CATOUT_PATH+1,x
            inx
            cpx   #16
            bne   :cp2

            ;"/bin/CAT" -- high-bit NUL-terminated liba
            ;string, spawn path
            ldx   #0
:cp3        lda   CTBN_PTH_TXT,x
            sta   CAT_PATH,x
            inx
            cpx   #CTBN_PTH_LEN
            bne   :cp3
            stz   CAT_PATH+CTBN_PTH_LEN

            ;"CAT" -- high-bit NUL-terminated liba string,
            ;argv[0]
            lda   #$C3
            sta   CAT_ARG0
            lda   #$C1
            sta   CAT_ARG0+1
            lda   #$D4
            sta   CAT_ARG0+2
            stz   CAT_ARG0+3
            rts

SRC_PATH_TXT   asc "/mnt/MAUX/CATSRC"
OUT_PATH_TXT   asc "/mnt/MAUX/CATOUT"

CRT_OUT_FILE
            lda   #7
            sta   CREATE_PARM
            lda   #<CATOUT_PATH
            sta   CREATE_PARM+1
            lda   #>CATOUT_PATH
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
            lda   #<CATOUT_PATH
            sta   OPEN_PARM+1
            lda   #>CATOUT_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPEN_SRC_FILE
            lda   #<CATSRC_PATH
            sta   OPEN_PARM+1
            lda   #>CATSRC_PATH
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

READ_BACK   lda   R_OUT_FD2
            sta   READ_PARM+1
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #CATBUFLEN
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
:cp         cpy   #CATBUFLEN
            beq   :done
            lda   IO_BUF,y
            sta   R_DATA,y
            iny
            bra   :cp
:done       clc
            rts
:err        sec
            rts

SPAWN_CAT   lda   #<CAT_ARG0
            sta   ARGV_ARR
            lda   #>CAT_ARG0
            sta   ARGV_ARR+1
            stz   ARGV_ARR+2
            stz   ARGV_ARR+3

            lda   #FDACT_DUP
            sta   FDA_BUF+0
            lda   #FD_STDIN
            sta   FDA_BUF+1
            lda   R_SRC_FD
            sta   FDA_BUF+2
            lda   #FDACT_CLOSE
            sta   FDA_BUF+3
            lda   R_SRC_FD
            sta   FDA_BUF+4
            stz   FDA_BUF+5
            lda   #FDACT_DUP
            sta   FDA_BUF+6
            lda   #FD_STDOUT
            sta   FDA_BUF+7
            lda   R_OUT_FD
            sta   FDA_BUF+8
            lda   #FDACT_CLOSE
            sta   FDA_BUF+9
            lda   R_OUT_FD
            sta   FDA_BUF+10
            stz   FDA_BUF+11
            stz   FDA_BUF+12          ;FDACT_END

            lda   #<CAT_PATH
            sta   SPAWN_PARM
            lda   #>CAT_PATH
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

WAIT_CAT    lda   #<R_STATUS
            sta   WAIT_PARM
            lda   #>R_STATUS
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

PAR_PROC_LEN equ *-PARENT_PROC
