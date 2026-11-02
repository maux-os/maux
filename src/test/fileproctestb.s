*---------------------------------------------------------------
* fileproctestb.s -- image body for fileproctest.s.
* Split out so the top-level stays a thin MANIFEST: real
* Merlin holds the resident top-level source AND the PUT
* file being read in the same 41215-byte buffer, so every
* byte here would come off every module's budget.
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J)
*---------------------------------------------------------------


* Result addresses in the parent process bank.
R_FILE_FD       equ $1200
R_FILE_TRANS    equ $1201
R_DATA0         equ $1202
R_DATA1         equ $1203
R_DATA2         equ $1204
R_DATA3         equ $1205
R_OUT_FD        equ $1206
R_OUT_TRANS     equ $1207
R_OUT0          equ $1208
R_OUT1          equ $1209
R_OUT2          equ $120A
R_SPAWN_PID     equ $120B
R_SPAWN_STAT  equ $120C
R_WAIT_PID      equ $120D
R_ECHO_FD       equ $120E
R_ECHO_PID      equ $120F
R_ECHO_STATUS   equ $1210
R_ECH_WT_PID equ $1211
R_ECHO_TRANS    equ $1212
R_ECHO_BYTE     equ $1213
R_ECHO_BYTE1    equ $1214
R_ECHO_BYTE2    equ $1215
R_ECHO_BYTE3    equ $1216      ;task #13 (code review
                               ;C4):
R_ECHO_BYTE4    equ $1217      ;"HI BYE" is 7 bytes (2 user
                               ;args, space-
R_ECHO_BYTE5    equ $1218      ;joined, high-bit + trailing CR)
                               ;-- extends
R_ECHO_BYTE6    equ $1219      ;the old 1-arg/3-byte "HI\r" gate
                               ;to prove the generalized
                               ;PSTG_ARGV
R_DONE          equ $12F0
R_ERR           equ $12F1
R_STEP          equ $12F2

* Parent process scratch.
DATA_PATH       equ $1000
OUT_PATH        equ $1040
CHILD_PATH      equ $1080
ECHO_PATH       equ $10A0
OPEN_PARM       equ $10C0
READ_PARM       equ $10D0
CLOSE_PARM      equ $10E0
CREATE_PARM     equ $10F0
WRITE_PARM      equ $1100
WAIT_PARM       equ $1110
SPAWN_PARM      equ $1120
P_CNT_EXPECT  equ $1130
IO_BUF          equ $1140
ECHOOUT_PATH    equ $1180
ECHO_ARG0       equ $11C0
ECHO_ARG1       equ $11C8
ECHO_ARG2       equ $11D0      ;task #13 (code review
                               ;C4) -- second user arg, proves
                               ;the generalized PSTG_ARGV
                               ;beyond the old 2-entry bridge
                               ;(argv[0]="ECHO", argv[1]="HI",
                               ;argv[2]="BYE")
ECHO_ARGV       equ $11D8
ECHO_FDA        equ $11E0

*---------------------------------------------------------------
* Boot helpers.
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

BANNER      asc   "MAUX FILEPROC"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 because this harness uses helper subroutines with
* absolute JSR/JMP operands. The spawned child still verifies
* the normal file-backed LOAD_BASE path.
*---------------------------------------------------------------
PARENT_PROC
            stz   R_ERR
            stz   R_STEP
            jsr   SETUP_PATHS

            lda   #1
            sta   R_STEP
            jsr   OPEN_DT_FILE
            bcc   :opened_data
            jmp   P_ERR
:opened_data
            sta   R_FILE_FD
            jsr   READ_FOUR
            bcc   :read_data
            jmp   P_ERR
:read_data
            lda   R_FILE_FD
            jsr   CLOSE_FD
            bcc   :closed_data
            jmp   P_ERR
:closed_data

            lda   #2
            sta   R_STEP
            jsr   CRT_OUT_FILE
            bcc   :created
            jmp   P_ERR
:created    jsr   OPEN_OUT_FILE
            bcc   :opened_out
            jmp   P_ERR
:opened_out sta   R_OUT_FD
            jsr   WRITE_THREE
            bcc   :wrote
            jmp   P_ERR
:wrote      lda   R_OUT_FD
            jsr   CLOSE_FD
            bcc   :closed_out
            jmp   P_ERR
:closed_out

            lda   #3
            sta   R_STEP
            jsr   OPEN_OUT_FILE
            bcc   :opnd_rdback
            jmp   P_ERR
:opnd_rdback
            sta   R_OUT_FD
            jsr   READ_THREE
            bcc   :readback
            jmp   P_ERR
:readback   lda   R_OUT_FD
            jsr   CLOSE_FD
            bcc   :clsd_rdback
            jmp   P_ERR
:clsd_rdback

            lda   #4
            sta   R_STEP
            jsr   SPAWN_CHILD
            bcc   :spawned
            jmp   P_ERR
:spawned    sta   R_SPAWN_PID
            jsr   WAIT_CHILD
            bcc   :waited
            jmp   P_ERR
:waited     sta   R_WAIT_PID

            lda   #5
            sta   R_STEP
            jsr   CRT_ECH_FILE
            bcc   :created_echo
            jmp   P_ERR
:created_echo
            jsr   OPEN_ECH_FILE
            bcc   :opened_echo
            jmp   P_ERR
:opened_echo
            sta   R_ECHO_FD
            jsr   SPAWN_ECHO
            bcc   :spawned_echo
            jmp   P_ERR
:spawned_echo
            sta   R_ECHO_PID
            jsr   WAIT_ECHO
            bcc   :waited_echo
            jmp   P_ERR
:waited_echo
            sta   R_ECH_WT_PID
            lda   R_ECHO_FD
            jsr   CLOSE_FD
            bcc   :clsd_echo_wr
            jmp   P_ERR
:clsd_echo_wr
            jsr   OPEN_ECH_FILE
            bcc   :opnd_echo_rd
            jmp   P_ERR
:opnd_echo_rd
            sta   R_ECHO_FD
            jsr   READ_ECHO
            bcc   :read_echo
            jmp   P_ERR
:read_echo  lda   R_ECHO_FD
            jsr   CLOSE_FD
            bcc   :clsd_echo_rd
            jmp   P_ERR
:clsd_echo_rd

            lda   #$AA
            sta   R_DONE
:done       bra   :done

P_ERR       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:park       bra   :park

SETUP_PATHS lda   #14                    ;/mnt/MAUX/DATA
            sta   DATA_PATH
            lda   #'/'
            sta   DATA_PATH+1
            lda   #'m'
            sta   DATA_PATH+2
            lda   #'n'
            sta   DATA_PATH+3
            lda   #'t'
            sta   DATA_PATH+4
            lda   #'/'
            sta   DATA_PATH+5
            lda   #'M'
            sta   DATA_PATH+6
            lda   #'A'
            sta   DATA_PATH+7
            lda   #'U'
            sta   DATA_PATH+8
            lda   #'X'
            sta   DATA_PATH+9
            lda   #'/'
            sta   DATA_PATH+10
            lda   #'D'
            sta   DATA_PATH+11
            lda   #'A'
            sta   DATA_PATH+12
            lda   #'T'
            sta   DATA_PATH+13
            lda   #'A'
            sta   DATA_PATH+14

            lda   #17                    ;/mnt/MAUX/OUTFILE
            sta   OUT_PATH
            lda   #'/'
            sta   OUT_PATH+1
            lda   #'m'
            sta   OUT_PATH+2
            lda   #'n'
            sta   OUT_PATH+3
            lda   #'t'
            sta   OUT_PATH+4
            lda   #'/'
            sta   OUT_PATH+5
            lda   #'M'
            sta   OUT_PATH+6
            lda   #'A'
            sta   OUT_PATH+7
            lda   #'U'
            sta   OUT_PATH+8
            lda   #'X'
            sta   OUT_PATH+9
            lda   #'/'
            sta   OUT_PATH+10
            lda   #'O'
            sta   OUT_PATH+11
            lda   #'U'
            sta   OUT_PATH+12
            lda   #'T'
            sta   OUT_PATH+13
            lda   #'F'
            sta   OUT_PATH+14
            lda   #'I'
            sta   OUT_PATH+15
            lda   #'L'
            sta   OUT_PATH+16
            lda   #'E'
            sta   OUT_PATH+17

            lda   #$AF ;/mnt/MAUX/FCHILD, high-
                                         ;bit NUL string
            sta   CHILD_PATH
            lda   #$ED
            sta   CHILD_PATH+1
            lda   #$EE
            sta   CHILD_PATH+2
            lda   #$F4
            sta   CHILD_PATH+3
            lda   #$AF
            sta   CHILD_PATH+4
            lda   #$CD
            sta   CHILD_PATH+5
            lda   #$C1
            sta   CHILD_PATH+6
            lda   #$D5
            sta   CHILD_PATH+7
            lda   #$D8
            sta   CHILD_PATH+8
            lda   #$AF
            sta   CHILD_PATH+9
            lda   #$C6
            sta   CHILD_PATH+10
            lda   #$C3
            sta   CHILD_PATH+11
            lda   #$C8
            sta   CHILD_PATH+12
            lda   #$C9
            sta   CHILD_PATH+13
            lda   #$CC
            sta   CHILD_PATH+14
            lda   #$C4
            sta   CHILD_PATH+15
            stz   CHILD_PATH+16

            lda   #$AF ;/bin/ECHO, high-bit
                                         ;NUL string
            sta   ECHO_PATH
            lda   #$E2
            sta   ECHO_PATH+1
            lda   #$E9
            sta   ECHO_PATH+2
            lda   #$EE
            sta   ECHO_PATH+3
            lda   #$AF
            sta   ECHO_PATH+4
            lda   #$C5
            sta   ECHO_PATH+5
            lda   #$C3
            sta   ECHO_PATH+6
            lda   #$C8
            sta   ECHO_PATH+7
            lda   #$CF
            sta   ECHO_PATH+8
            stz   ECHO_PATH+9

            lda   #17                    ;/mnt/MAUX/ECHOOUT
            sta   ECHOOUT_PATH
            lda   #'/'
            sta   ECHOOUT_PATH+1
            lda   #'m'
            sta   ECHOOUT_PATH+2
            lda   #'n'
            sta   ECHOOUT_PATH+3
            lda   #'t'
            sta   ECHOOUT_PATH+4
            lda   #'/'
            sta   ECHOOUT_PATH+5
            lda   #'M'
            sta   ECHOOUT_PATH+6
            lda   #'A'
            sta   ECHOOUT_PATH+7
            lda   #'U'
            sta   ECHOOUT_PATH+8
            lda   #'X'
            sta   ECHOOUT_PATH+9
            lda   #'/'
            sta   ECHOOUT_PATH+10
            lda   #'E'
            sta   ECHOOUT_PATH+11
            lda   #'C'
            sta   ECHOOUT_PATH+12
            lda   #'H'
            sta   ECHOOUT_PATH+13
            lda   #'O'
            sta   ECHOOUT_PATH+14
            lda   #'O'
            sta   ECHOOUT_PATH+15
            lda   #'U'
            sta   ECHOOUT_PATH+16
            lda   #'T'
            sta   ECHOOUT_PATH+17

            lda   #$C5                   ;argv[0] = "ECHO"
            sta   ECHO_ARG0
            lda   #$C3
            sta   ECHO_ARG0+1
            lda   #$C8
            sta   ECHO_ARG0+2
            lda   #$CF
            sta   ECHO_ARG0+3
            stz   ECHO_ARG0+4
            lda   #$C8                   ;argv[1] = "HI"
            sta   ECHO_ARG1
            lda   #$C9
            sta   ECHO_ARG1+1
            stz   ECHO_ARG1+2
            lda   #$C2                   ;argv[2] = "BYE" --
                                         ;task #13
            sta   ECHO_ARG2              ;(code review
                                         ;C4): a
            lda   #$D9                   ;SECOND user arg,
                                         ;proving the
            sta   ECHO_ARG2+1            ;generalized
                                         ;PSTG_ARGV
            lda   #$C5                   ;stages more than one
            sta   ECHO_ARG2+2
            stz   ECHO_ARG2+3
            rts

OPEN_DT_FILE
            lda   #<DATA_PATH
            sta   OPEN_PARM+1
            lda   #>DATA_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPEN_OUT_FILE
            lda   #<OUT_PATH
            sta   OPEN_PARM+1
            lda   #>OUT_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPEN_ECH_FILE
            lda   #<ECHOOUT_PATH
            sta   OPEN_PARM+1
            lda   #>ECHOOUT_PATH
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

CRT_OUT_FILE
            lda   #7
            sta   CREATE_PARM
            lda   #<OUT_PATH
            sta   CREATE_PARM+1
            lda   #>OUT_PATH
            sta   CREATE_PARM+2
            bra   CREATE_COMMON

CRT_ECH_FILE
            lda   #7
            sta   CREATE_PARM
            lda   #<ECHOOUT_PATH
            sta   CREATE_PARM+1
            lda   #>ECHOOUT_PATH
            sta   CREATE_PARM+2
CREATE_COMMON
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

READ_FOUR   lda   R_FILE_FD
            sta   READ_PARM+1
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #4
            sta   READ_PARM+4
            stz   READ_PARM+5
            stz   READ_PARM+6
            stz   READ_PARM+7
            lda   #4
            bra   READ_COMMON

READ_THREE  lda   R_OUT_FD
            sta   READ_PARM+1
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #3
            sta   READ_PARM+4
            stz   READ_PARM+5
            stz   READ_PARM+6
            stz   READ_PARM+7
            lda   #3
READ_COMMON sta   P_CNT_EXPECT
            lda   #4
            sta   READ_PARM
            lda   #<READ_PARM
            ldx   #>READ_PARM
            ldy   #SYS_READ
            jsr   $FF00
            bcc   :ok
            rts
:ok         lda   P_CNT_EXPECT
            cmp   #4
            bne   :three
            lda   READ_PARM+6
            sta   R_FILE_TRANS
            lda   IO_BUF
            sta   R_DATA0
            lda   IO_BUF+1
            sta   R_DATA1
            lda   IO_BUF+2
            sta   R_DATA2
            lda   IO_BUF+3
            sta   R_DATA3
            clc
            rts
:three      lda   READ_PARM+6
            sta   R_OUT_TRANS
            lda   IO_BUF
            sta   R_OUT0
            lda   IO_BUF+1
            sta   R_OUT1
            lda   IO_BUF+2
            sta   R_OUT2
            clc
            rts

WRITE_THREE lda   R_OUT_FD
            sta   WRITE_PARM+1
            lda   #$11
            sta   IO_BUF
            lda   #$22
            sta   IO_BUF+1
            lda   #$33
            sta   IO_BUF+2
            lda   #<IO_BUF
            sta   WRITE_PARM+2
            lda   #>IO_BUF
            sta   WRITE_PARM+3
            lda   #3
            sta   WRITE_PARM+4
            stz   WRITE_PARM+5
            stz   WRITE_PARM+6
            stz   WRITE_PARM+7
            lda   #4
            sta   WRITE_PARM
            lda   #<WRITE_PARM
            ldx   #>WRITE_PARM
            ldy   #SYS_WRITE
            jsr   $FF00
            bcs   :err
            lda   WRITE_PARM+6
            sta   R_OUT_TRANS
            clc
            rts
:err        sec
            rts

READ_ECHO   lda   R_ECHO_FD
            sta   READ_PARM+1
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #7                     ;task #13
                                         ;(code review
            sta   READ_PARM+4            ;C4): "HI BYE\r" = 7
                                         ;bytes (was 3, "HI\r",
                                         ;the old 1-arg gate)
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
            sta   R_ECHO_TRANS
            lda   IO_BUF
            sta   R_ECHO_BYTE
            lda   IO_BUF+1
            sta   R_ECHO_BYTE1
            lda   IO_BUF+2
            sta   R_ECHO_BYTE2
            lda   IO_BUF+3
            sta   R_ECHO_BYTE3
            lda   IO_BUF+4
            sta   R_ECHO_BYTE4
            lda   IO_BUF+5
            sta   R_ECHO_BYTE5
            lda   IO_BUF+6
            sta   R_ECHO_BYTE6
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

SPAWN_CHILD lda   #<CHILD_PATH
            sta   SPAWN_PARM
            lda   #>CHILD_PATH
            sta   SPAWN_PARM+1
            stz   SPAWN_PARM+2
            stz   SPAWN_PARM+3
            stz   SPAWN_PARM+4
            stz   SPAWN_PARM+5
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            rts

SPAWN_ECHO  lda   #<ECHO_ARG0
            sta   ECHO_ARGV
            lda   #>ECHO_ARG0
            sta   ECHO_ARGV+1
            lda   #<ECHO_ARG1
            sta   ECHO_ARGV+2
            lda   #>ECHO_ARG1
            sta   ECHO_ARGV+3
            lda   #<ECHO_ARG2           ;task #13
                                        ;(code review
            sta   ECHO_ARGV+4           ;C4): third argv entry
                                        ;(second
            lda   #>ECHO_ARG2           ;user arg) --
                                        ;PSTG_ARGV now
            sta   ECHO_ARGV+5           ;generalizes past the
                                        ;old 2-entry
            stz   ECHO_ARGV+6           ;bridge, scanning this
                                        ;NULL-
            stz   ECHO_ARGV+7           ;terminated pointer
                                        ;array (docs/ SYSCALL.md
                                        ;ruling 13) until it
                                        ;finds this $0000
                                        ;terminator
            lda   #FDACT_DUP
            sta   ECHO_FDA
            lda   #FD_STDOUT
            sta   ECHO_FDA+1
            lda   R_ECHO_FD
            sta   ECHO_FDA+2
            stz   ECHO_FDA+3
            lda   #<ECHO_PATH
            sta   SPAWN_PARM
            lda   #>ECHO_PATH
            sta   SPAWN_PARM+1
            lda   #<ECHO_ARGV
            sta   SPAWN_PARM+2
            lda   #>ECHO_ARGV
            sta   SPAWN_PARM+3
            lda   #<ECHO_FDA
            sta   SPAWN_PARM+4
            lda   #>ECHO_FDA
            sta   SPAWN_PARM+5
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            rts

WAIT_CHILD  lda   #<R_SPAWN_STAT
            sta   WAIT_PARM
            lda   #>R_SPAWN_STAT
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

WAIT_ECHO   lda   #<R_ECHO_STATUS
            sta   WAIT_PARM
            lda   #>R_ECHO_STATUS
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

PAR_PROC_LEN equ *-PARENT_PROC
