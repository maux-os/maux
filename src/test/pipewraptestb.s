*---------------------------------------------------------------
* pipewraptestb.s -- image body for pipewraptest.s. Split out so
* the top-level stays a thin MANIFEST (learning:
* 01M051EM2HQ3ZVJTR1W9P3G86J), same convention as every other
* *testb.s in this tree.
*
* The scenario (docs/PROCIO.md sec 6, "WATCH THE WRAP"): a pipe
* whose 256B ring is deliberately pushed across its $xx00 wrap
* boundary on BOTH the write side and the read side in the SAME
* run, with a byte pattern that lets the read-back be checked
* byte-exact against a closed-form expected value rather than
* just "some bytes came back":
*
*   write 200 bytes: WBUF1[i] = i               (i=0..199)
*   read  150 bytes (discarded) -- RDP now at 150, WRP at 200
*   write 200 bytes: WBUF2[i] = (200+i) mod 256  (i=0..199)
*                     -- WRP 200+200=400 wraps at 256: CROSSES
*                     the boundary on the WRITE side
*   read  250 bytes into R_DATA -- RDP 150, 150+250=400 wraps at
*                     256: CROSSES the boundary on the READ side
*                     too
*
* Both writes together are one continuous byte stream (values
* increasing mod 256), so after the discard-read consumes the
* first 150 bytes, the ring holds byte values 150,151,...,255,
* 0,1,...,143 in order -- exactly what the final 250-byte read
* must reproduce: R_DATA[p] = (150+p) mod 256 for p=0..249,
* checked byte-exact by scripts/check_pipewrap.py. Also serves
* as this task's before/after K2 cycle measurement: the python
* driver polls cumulative cycles at each R_STEP transition, so
* the wrap-crossing write (step 3->4) and the wrap-crossing read
* (step 4->5) each get a real number.
*---------------------------------------------------------------

* Result/scratch addresses in the parent process bank.
PIPE_FDS    equ $1000        ;2 bytes: rfd, wfd (pipe() result)
PIPE_PARM   equ $1002        ;2 bytes: pointer to PIPE_FDS --
                             ;the SYS_PIPE parmlist itself
WRITE_PARM  equ $1010        ;8 bytes, MLI_REF.. layout
READ_PARM   equ $1020        ;8 bytes, MLI_REF.. layout
CLOSE_PARM  equ $1030        ;2 bytes

R_TRANS1    equ $1040        ;2: write #1 (200B, no wrap)
R_TRANS2    equ $1042        ;2: read #1 (150B, discarded)
R_TRANS3    equ $1044        ;2: write #2 (200B, WRAPS)
R_TRANS4    equ $1046        ;2: read #2 (250B, WRAPS)
R_STEP      equ $1048
R_ERR       equ $1049
R_DONE      equ $104A

WBUF1       equ $1100        ;200B: i, i=0..199
WBUF2       equ $1200        ;200B: (200+i) mod 256, i=0..199
DBUF        equ $1300        ;150B: discard-read target
R_DATA      equ $1400        ;250B: final read-back, checked

*---------------------------------------------------------------
* Boot helpers -- identical shape to catreadtestb.s's own (same
* BankCopy-via-main bounce, same page-1 frame patch).
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

BANNER      asc   "MAUX PIPEWRAP"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 -- same reason catreadtestb.s's own PARENT_PROC is:
* absolute JSR/JMP operands to the helper subroutines below.
*---------------------------------------------------------------
PARENT_PROC
            stz   R_ERR
            stz   R_STEP

            ldy   #0
:fill1      tya
            sta   WBUF1,y
            iny
            cpy   #200
            bne   :fill1

            ldy   #0
:fill2      tya
            clc
            adc   #200
            sta   WBUF2,y
            iny
            cpy   #200
            bne   :fill2

            lda   #1
            sta   R_STEP
            jsr   DO_PIPE
            bcc   :piped
            jmp   P_ERR
:piped

            lda   #2
            sta   R_STEP
            lda   #<WBUF1
            sta   WRITE_PARM+MLI_BUFLO
            lda   #>WBUF1
            sta   WRITE_PARM+MLI_BUFHI
            lda   #200
            sta   WRITE_PARM+MLI_REQLO
            stz   WRITE_PARM+MLI_REQHI
            jsr   DO_WRITE
            bcc   :w1ok
            jmp   P_ERR
:w1ok       lda   WRITE_PARM+MLI_TRANSLO
            sta   R_TRANS1
            lda   WRITE_PARM+MLI_TRANSHI
            sta   R_TRANS1+1

            lda   #3
            sta   R_STEP
            lda   #<DBUF
            sta   READ_PARM+MLI_BUFLO
            lda   #>DBUF
            sta   READ_PARM+MLI_BUFHI
            lda   #150
            sta   READ_PARM+MLI_REQLO
            stz   READ_PARM+MLI_REQHI
            jsr   DO_READ
            bcc   :r1ok
            jmp   P_ERR
:r1ok       lda   READ_PARM+MLI_TRANSLO
            sta   R_TRANS2
            lda   READ_PARM+MLI_TRANSHI
            sta   R_TRANS2+1

            lda   #4
            sta   R_STEP
            lda   #<WBUF2
            sta   WRITE_PARM+MLI_BUFLO
            lda   #>WBUF2
            sta   WRITE_PARM+MLI_BUFHI
            lda   #200
            sta   WRITE_PARM+MLI_REQLO
            stz   WRITE_PARM+MLI_REQHI
            jsr   DO_WRITE
            bcc   :w2ok
            jmp   P_ERR
:w2ok       lda   WRITE_PARM+MLI_TRANSLO
            sta   R_TRANS3
            lda   WRITE_PARM+MLI_TRANSHI
            sta   R_TRANS3+1

            lda   #5
            sta   R_STEP
            lda   #<R_DATA
            sta   READ_PARM+MLI_BUFLO
            lda   #>R_DATA
            sta   READ_PARM+MLI_BUFHI
            lda   #250
            sta   READ_PARM+MLI_REQLO
            stz   READ_PARM+MLI_REQHI
            jsr   DO_READ
            bcc   :r2ok
            jmp   P_ERR
:r2ok       lda   READ_PARM+MLI_TRANSLO
            sta   R_TRANS4
            lda   READ_PARM+MLI_TRANSHI
            sta   R_TRANS4+1

            lda   #6
            sta   R_STEP
            lda   PIPE_FDS
            jsr   DO_CLOSE
            lda   PIPE_FDS+1
            jsr   DO_CLOSE

            lda   #$AA
            sta   R_DONE
:done       bra   :done

P_ERR       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:park       bra   :park

DO_PIPE     lda   #<PIPE_FDS
            sta   PIPE_PARM
            lda   #>PIPE_FDS
            sta   PIPE_PARM+1
            lda   #<PIPE_PARM
            ldx   #>PIPE_PARM
            ldy   #SYS_PIPE
            jsr   $FF00
            rts

DO_WRITE    lda   PIPE_FDS+1        ;write fd
            sta   WRITE_PARM+MLI_REF
            lda   #8
            sta   WRITE_PARM
            lda   #<WRITE_PARM
            ldx   #>WRITE_PARM
            ldy   #SYS_WRITE
            jsr   $FF00
            rts

DO_READ     lda   PIPE_FDS          ;read fd
            sta   READ_PARM+MLI_REF
            lda   #8
            sta   READ_PARM
            lda   #<READ_PARM
            ldx   #>READ_PARM
            ldy   #SYS_READ
            jsr   $FF00
            rts

DO_CLOSE    sta   CLOSE_PARM+1
            lda   #1
            sta   CLOSE_PARM
            lda   #<CLOSE_PARM
            ldx   #>CLOSE_PARM
            ldy   #SYS_CLOSE
            jsr   $FF00
            rts

PAR_PROC_LEN equ *-PARENT_PROC
