*---------------------------------------------------------------
* procmli3.s -- the read/write syscall brokers.
*
* SPLIT OUT OF procmli.s (S9 L4, 2026-08-29): that file's own
* stripped text was 12840 B, past `as`'s 16126 B source window,
* so
* it could never be assembled inside maux as one REL module. The
* cut is at a section boundary and this file is `put`
* immediately
* after its parent, so the emitted bytes are unchanged -- which
* is
* what check-bytes asserts.
*---------------------------------------------------------------
PRC_WRITE
            lda   #8
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+MLI_REF
            sta   P_FD
            jsr   PRC_CUR_FDOBJ
            bcc   :objok
            rts
:objok      cmp   #FD_DEV_BASE
            bcc   :oftobj
            cmp   #FD_TTY3+1
            bcc   :istty
            cmp   #FD_NULL
            beq   :isnull
            cmp   #FD_SER0
            beq   :isser
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:isser      jmp   SER_WRITE
:istty      sec               ;THE HANDLE IS THE CONSOLE. This
            sbc   #FD_DEV_BASE      ;used to validate all four
            sta   TTY_TARGET        ;and then throw away which
            jmp   TTY_WRITE     ;one it was
*-- /dev/null: discard, and report the whole request written.
*-- Short counts are what a caller retries on, so a sink that
*-- under-reports would spin.
:isnull     lda   PRC_PARM+MLI_REQLO
            sta   PRC_PARM+MLI_TRANSLO
            lda   PRC_PARM+MLI_REQHI
            sta   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts
:oftobj     tax
            lda   OFT_TYPE,x
            cmp   #OFT_PIPE_W
            beq   :ispipe
            cmp   #OFT_FILE
            beq   :isfile
            cmp   #OFT_BLK
            beq   :isblk
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:isblk      jsr   PRC_BLK_WR_G
            rts
:isfile     jsr   LZ_DIRTY         ;first write: drop the tag
            jmp   PRC_FILE_WR
:ispipe     lda   OFT_PIPE,x
            sta   P_PIPE
            ldx   P_PIPE
            lda   PIPE_RREFS,x
            bne   :readers
            lda   #ERR_PIPE
            jsr   PRC_FAIL_A
            rts
:readers    lda   PRC_PARM+MLI_REQLO
            ora   PRC_PARM+MLI_REQHI
            bne   :want
            stz   PRC_PARM+MLI_TRANSLO
            stz   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts
:want       ldx   P_PIPE
            lda   PIPE_BYTES,x
            cmp   #$FF
            bne   :space
            lda   P_PIPE
            clc
            adc   #PIPE_WR_CHAN
            jsr   PRC_BLCK_RTRY
            rts

* -- K2: bulk pipe write, mirror image of PRC_READ's bulk read
* -- above. "Full" is BYTES=$FF (the 8-bit count's own ceiling,
* -- one below the ring's real 256B size -- see PPP_PUT_BYTE's
* -- old per-byte check, same cap, now computed once for the
* -- whole request instead of re-checked every byte).
:space      jsr   PPP_REQ_LIMIT
            ldx   P_PIPE
            lda   #255
            sec
            sbc   PIPE_BYTES,x
            cmp   P_COUNT
            bcc   :wavail           ;room<requested: use room
            lda   P_COUNT
:wavail     sta   P_TMP              ;P_TMP = N

* -- RUN1 = MIN(N, 256-WRP), RUN2 = N-RUN1, against the WRITE
* -- pointer this time.
            ldx   P_PIPE
            lda   PIPE_WRP,x
            beq   :wnowrap
            lda   #0
            sec
            sbc   PIPE_WRP,x
            cmp   P_TMP
            bcs   :wnowrap
            sta   P_TMP2             ;RUN1 = room
            lda   P_TMP
            sec
            sbc   P_TMP2
            sta   P_IDX               ;RUN2
            bra   :whaverun
:wnowrap    lda   P_TMP
            sta   P_TMP2
            stz   P_IDX
:whaverun
            jsr   PRC_SEL_CRBNK
            sta   P_BANK

* -- run 1: caller buf[0..RUN1) -> ring[WRP..WRP+RUN1).
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   PRC_PARM+MLI_BUFLO
            sta   K_BC_SRCADDR
            lda   PRC_PARM+MLI_BUFHI
            sta   K_BC_SRCADDR+1
            lda   P_BANK
            sta   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            ldx   P_PIPE
            lda   PIPE_WRP,x
            sta   K_BC_DSTADDR
            lda   P_PIPE
            sec
            sbc   #1
            clc
            adc   #>PPP_RNG_BASE
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   P_TMP2
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :wrun1ok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:wrun1ok    lda   P_IDX
            beq   :wnorun2

* -- run 2 (wrap): caller buf[RUN1..RUN1+RUN2) -> ring[0..RUN2).
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            clc
            lda   PRC_PARM+MLI_BUFLO
            adc   P_TMP2
            sta   K_BC_SRCADDR
            lda   PRC_PARM+MLI_BUFHI
            adc   #0
            sta   K_BC_SRCADDR+1
            lda   P_BANK
            sta   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            stz   K_BC_DSTADDR
            lda   P_PIPE
            sec
            sbc   #1
            clc
            adc   #>PPP_RNG_BASE
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   P_IDX
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :wnorun2
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:wnorun2

* -- bookkeeping: advance WRP by N, grow BYTES by N,
* -- PRC_TRANS=N.
            ldx   P_PIPE
            lda   PIPE_WRP,x
            clc
            adc   P_TMP
            sta   PIPE_WRP,x
            lda   PIPE_BYTES,x
            clc
            adc   P_TMP
            sta   PIPE_BYTES,x
            lda   P_TMP
            sta   PRC_TRANS
:wrdone     lda   PRC_TRANS
            sta   PRC_PARM+MLI_TRANSLO
            stz   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            lda   P_PIPE
            clc
            adc   #PIPE_RD_CHAN
            jsr   SCH_WAKEUP
            jsr   PRC_SEL_CRBNK
            rts

PRC_FAIL_A
            sta   K_RESULT
            lda   #1
            sta   K_RESULT_ERR
            jsr   PRC_SEL_CRBNK
            rts

PRC_RET_OK0
            lda   #0
PRC_RET_OK_A
            sta   K_RESULT
            stz   K_RESULT_ERR
            jsr   PRC_SEL_CRBNK
            rts
