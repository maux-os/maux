*---------------------------------------------------------------
* findtestc.s -- the second half of findtestb.s's parent
* process (MLI helpers, RUN1-RUN7, the readback), `put` by
* findtest.s directly after it -- see the note at the end of
* findtestb.s: the two files are ONE contiguous parent-process
* image, split only for the check-dialect source-buffer budget.
*---------------------------------------------------------------

*---------------------------------------------------------------
CRT_FILE    sta   CREATE_PARM+1
            stx   CREATE_PARM+2
            lda   #7
            sta   CREATE_PARM
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

OPEN_FILE   sta   OPEN_PARM+1
            stx   OPEN_PARM+2
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

*---------------------------------------------------------------
* RUN1-RUN5 -- CREATE+OPEN the run's stdout file, patch the
* dynamic fd into its FDAn, SPAWN FIND with the run's argv,
* WAIT, CLOSE. Return carry clear on success.
*---------------------------------------------------------------
RUN1        lda   #<FOUT1_PATH
            ldx   #>FOUT1_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT1_PATH
            ldx   #>FOUT1_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA1+2
            sta   FDA1+4
            lda   #<SPAWN_PARM1
            ldx   #>SPAWN_PARM1
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID1
            lda   #<R_STATUS1
            sta   WAIT_PARM
            lda   #>R_STATUS1
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID1
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

RUN2        lda   #<FOUT2_PATH
            ldx   #>FOUT2_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT2_PATH
            ldx   #>FOUT2_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA2+2
            sta   FDA2+4
            lda   #<SPAWN_PARM2
            ldx   #>SPAWN_PARM2
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID2
            lda   #<R_STATUS2
            sta   WAIT_PARM
            lda   #>R_STATUS2
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID2
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

RUN3        lda   #<FOUT3_PATH
            ldx   #>FOUT3_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT3_PATH
            ldx   #>FOUT3_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA3+2
            sta   FDA3+4
            lda   #<SPAWN_PARM3
            ldx   #>SPAWN_PARM3
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID3
            lda   #<R_STATUS3
            sta   WAIT_PARM
            lda   #>R_STATUS3
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID3
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

RUN4        lda   #<FOUT4_PATH
            ldx   #>FOUT4_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT4_PATH
            ldx   #>FOUT4_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA4+2
            sta   FDA4+4
            lda   #<SPAWN_PARM4
            ldx   #>SPAWN_PARM4
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID4
            lda   #<R_STATUS4
            sta   WAIT_PARM
            lda   #>R_STATUS4
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID4
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

RUN5        lda   #<FOUT5_PATH
            ldx   #>FOUT5_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT5_PATH
            ldx   #>FOUT5_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA5+2
            sta   FDA5+4
            lda   #<SPAWN_PARM5
            ldx   #>SPAWN_PARM5
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID5
            lda   #<R_STATUS5
            sta   WAIT_PARM
            lda   #>R_STATUS5
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID5
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* RUN6 -- like RUN1-5, but CREATE+OPEN TWO files (stdout AND
* stderr) and patch both dup/close pairs in FDA6.
*---------------------------------------------------------------
RUN6        lda   #<FOUT6_PATH
            ldx   #>FOUT6_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT6_PATH
            ldx   #>FOUT6_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA6+2
            sta   FDA6+4

            lda   #<FERR6_PATH
            ldx   #>FERR6_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FERR6_PATH
            ldx   #>FERR6_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD2
            sta   FDA6+8
            sta   FDA6+10

            lda   #<SPAWN_PARM6
            ldx   #>SPAWN_PARM6
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID6
            lda   #<R_STATUS6
            sta   WAIT_PARM
            lda   #>R_STATUS6
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID6
            lda   CUR_FD
            jsr   CLOSE_FD
            lda   CUR_FD2
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* RUN7 -- the pathname fence (/mnt/MAUX/LONGDIR): stdout AND
* stderr redirected, exactly RUN6's shape.
*---------------------------------------------------------------
RUN7        lda   #<FOUT7_PATH
            ldx   #>FOUT7_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT7_PATH
            ldx   #>FOUT7_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA7+2
            sta   FDA7+4

            lda   #<FERR7_PATH
            ldx   #>FERR7_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FERR7_PATH
            ldx   #>FERR7_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD2
            sta   FDA7+8
            sta   FDA7+10

            lda   #<SPAWN_PARM7
            ldx   #>SPAWN_PARM7
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID7
            lda   #<R_STATUS7
            sta   WAIT_PARM
            lda   #>R_STATUS7
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID7
            lda   CUR_FD
            jsr   CLOSE_FD
            lda   CUR_FD2
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* RD_INTO_IOBUF -- OPEN(path)+READ(up to IOREQLEN bytes into
* IO_BUF)+CLOSE. Path pointer in A(lo)/X(hi) on entry. Same
* shape as lstestb.s's own.
*---------------------------------------------------------------
RD_INTO_IOBUF
            jsr   OPEN_FILE
            bcs   :err
            sta   CUR_FD
            sta   READ_PARM+1
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #<IOREQLEN
            sta   READ_PARM+4
            lda   #>IOREQLEN
            sta   READ_PARM+5
            stz   READ_PARM+6
            stz   READ_PARM+7
            lda   #4
            sta   READ_PARM
            lda   #<READ_PARM
            ldx   #>READ_PARM
            ldy   #SYS_READ
            jsr   $FF00
            bcs   :err2
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:err2       lda   CUR_FD
            jsr   CLOSE_FD
:err        sec
            rts

*---------------------------------------------------------------
* READBACK_ALL -- reopen each of the 7 output files for read
* and copy its bytes to the matching R_DATAn/R_ERRDATA6 area.
* Long-jump trampoline idiom (bcc/jmp) per ls.s's/lstestb.s's
* own documented reason: some targets sit past +/-127 bytes.
*---------------------------------------------------------------
READBACK_ALL
            lda   #<FOUT1_PATH
            ldx   #>FOUT1_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbAok
            jmp   FAIL_RB
:rbAok      lda   READ_PARM+6
            sta   R_TRANS1
            lda   READ_PARM+7
            sta   R_TRANS1+1
            ldy   #0
*-- output can exceed 255 bytes (the longer /mnt/MAUX paths):
*-- copy page 0 whole, then the READ_PARM+6 remainder of page 1
:cpA        lda   IO_BUF,y
            sta   R_DATA1,y
            iny
            bne   :cpA
            lda   READ_PARM+7
            beq   :cpAdone
:cpA2       cpy   READ_PARM+6
            beq   :cpAdone
            lda   IO_BUF+256,y
            sta   R_DATA1+256,y
            iny
            bra   :cpA2
:cpAdone

            lda   #<FOUT2_PATH
            ldx   #>FOUT2_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbBok
            jmp   FAIL_RB
:rbBok      lda   READ_PARM+6
            sta   R_TRANS2
            lda   READ_PARM+7
            sta   R_TRANS2+1
            ldy   #0
:cpB        cpy   READ_PARM+6
            beq   :cpBdone
            lda   IO_BUF,y
            sta   R_DATA2,y
            iny
            bra   :cpB
:cpBdone

            lda   #<FOUT3_PATH
            ldx   #>FOUT3_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbCok
            jmp   FAIL_RB
:rbCok      lda   READ_PARM+6
            sta   R_TRANS3
            lda   READ_PARM+7
            sta   R_TRANS3+1
            ldy   #0
:cpC        cpy   READ_PARM+6
            beq   :cpCdone
            lda   IO_BUF,y
            sta   R_DATA3,y
            iny
            bra   :cpC
:cpCdone

            lda   #<FOUT4_PATH
            ldx   #>FOUT4_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbDok
            jmp   FAIL_RB
:rbDok      lda   READ_PARM+6
            sta   R_TRANS4
            lda   READ_PARM+7
            sta   R_TRANS4+1
            ldy   #0
:cpD        cpy   READ_PARM+6
            beq   :cpDdone
            lda   IO_BUF,y
            sta   R_DATA4,y
            iny
            bra   :cpD
:cpDdone

            lda   #<FOUT5_PATH
            ldx   #>FOUT5_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbEok
            jmp   FAIL_RB
:rbEok      lda   READ_PARM+6
            sta   R_TRANS5
            lda   READ_PARM+7
            sta   R_TRANS5+1
            ldy   #0
:cpE        cpy   READ_PARM+6
            beq   :cpEdone
            lda   IO_BUF,y
            sta   R_DATA5,y
            iny
            bra   :cpE
:cpEdone

            lda   #<FOUT6_PATH
            ldx   #>FOUT6_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbFok
            jmp   FAIL_RB
:rbFok      lda   READ_PARM+6
            sta   R_TRANS6
            lda   READ_PARM+7
            sta   R_TRANS6+1
            ldy   #0
*-- output can exceed 255 bytes (the longer /mnt/MAUX paths):
*-- copy page 0 whole, then the READ_PARM+6 remainder of page 1
:cpF        lda   IO_BUF,y
            sta   R_DATA6,y
            iny
            bne   :cpF
            lda   READ_PARM+7
            beq   :cpFdone
:cpF2       cpy   READ_PARM+6
            beq   :cpFdone
            lda   IO_BUF+256,y
            sta   R_DATA6+256,y
            iny
            bra   :cpF2
:cpFdone

            lda   #<FERR6_PATH
            ldx   #>FERR6_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbGok
            jmp   FAIL_RB
:rbGok      lda   READ_PARM+6
            sta   R_ERRTRNS6
            lda   READ_PARM+7
            sta   R_ERRTRNS6+1
            ldy   #0
:cpG        cpy   READ_PARM+6
            beq   :cpGdone
            lda   IO_BUF,y
            sta   R_ERRDATA6,y
            iny
            bra   :cpG
:cpGdone

            lda   #<FOUT7_PATH
            ldx   #>FOUT7_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbHok
            jmp   FAIL_RB
:rbHok      lda   READ_PARM+6
            sta   R_TRANS7
            lda   READ_PARM+7
            sta   R_TRANS7+1
            ldy   #0
:cpH        cpy   READ_PARM+6
            beq   :cpHdone
            lda   IO_BUF,y
            sta   R_DATA7,y
            iny
            bra   :cpH
:cpHdone

            lda   #<FERR7_PATH
            ldx   #>FERR7_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbIok
            jmp   FAIL_RB
:rbIok      lda   READ_PARM+6
            sta   R_ERRTRNS7
            lda   READ_PARM+7
            sta   R_ERRTRNS7+1
            ldy   #0
:cpI        cpy   READ_PARM+6
            beq   :cpIdone
            lda   IO_BUF,y
            sta   R_ERRDATA7,y
            iny
            bra   :cpI
:cpIdone
            clc
            rts
FAIL_RB     sec
            rts

PAR_PROC_LEN equ *-PARENT_PROC
