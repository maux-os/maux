*---------------------------------------------------------------
* procfile2.s -- Raw ProDOS file-transfer helpers PRC_FILE_READ/
* PRC_FILE_WR (chunked MLI READ/WRITE loops, docs/PROCIO.md) and
* the fdactions replay used by spawn's fd inheritance
* (PRC_FDACTIONS/PRDFDA_TARGET/PRDFDA_SOURCE). Split out of
* procfile.s (task #8, docs/SELFHOST-CONVERSION.md phase 2) to
* keep each kernel module under 28000 bytes for compatibility
* with the maux assembler's shared symbol-table window.
* procfile.s keeps PRC_FILECALL's dispatch and the individual
* delegated syscalls (creat/unlink/rename/setpfx/getpfx/dotdot/
* gfi/pstat/open/close), which `jmp` into this file's transfer
* helpers.
* Full design notes: K.PROCESS.TXT (docs/a2/)
*---------------------------------------------------------------

PRC_FILE_READ
            stx   P_OBJ
            jsr   PRC_OFT_REF
            bcc   :resident
            lda   K_RESULT         ;OPEN-RW-2: $4D from a GROUP
            cmp   #MLIE_RANGE      ;member's mark acquire = a
            bne   :rts             ;VIRTUAL mark (the file was
            bit   OFT_PIPE,x       ;cut under this reader).  Any
            bvc   :rts             ;other $4D stays an error.
            stz   K_RESULT_ERR     ;0 bytes, no error, and
            stz   PRC_DONE         ;nothing was loaded
            stz   PRC_DONE+1
            jmp   :done
:rts        rts
:resident   sta   PMLI_RD_PARMS+MLI_REF
            lda   PRC_PARM+MLI_BUFLO
            sta   PRC_USER_PTR
            lda   PRC_PARM+MLI_BUFHI
            sta   PRC_USER_PTR+1
            lda   PRC_PARM+MLI_REQLO
            sta   PRC_REMAIN
            lda   PRC_PARM+MLI_REQHI
            sta   PRC_REMAIN+1
            stz   PRC_DONE
            stz   PRC_DONE+1
:loop       lda   PRC_REMAIN
            ora   PRC_REMAIN+1
            bne   :more
            jmp   :done
:more
            jsr   PRC_PCK_CHUNK
            lda   #<PMLI_XFER_BUF
            sta   PMLI_RD_PARMS+MLI_BUFLO
            lda   #>PMLI_XFER_BUF
            sta   PMLI_RD_PARMS+MLI_BUFHI
            lda   PRC_CHUNK
            sta   PMLI_RD_PARMS+MLI_REQLO
            lda   PRC_CHUNK+1
            sta   PMLI_RD_PARMS+MLI_REQHI
            stz   PMLI_RD_PARMS+MLI_TRANSLO
            stz   PMLI_RD_PARMS+MLI_TRANSHI
            jsr   PMLI_RD_CALL
            beq   :readok
            cmp   #MLI_ERR_EOF
            bne   :readerr
            jmp   :done
:readerr
            jsr   PRC_FAIL_A
            rts
:readok     lda   PMLI_RD_PARMS+MLI_TRANSLO
            ora   PMLI_RD_PARMS+MLI_TRANSHI
            bne   :hasbytes
            jmp   :done
:hasbytes
            jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PMLI_XFER_BUF
            sta   K_BC_SRCADDR
            lda   #>PMLI_XFER_BUF
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_USER_PTR
            sta   K_BC_DSTADDR
            lda   PRC_USER_PTR+1
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   PMLI_RD_PARMS+MLI_TRANSLO
            sta   K_BC_LEN
            lda   PMLI_RD_PARMS+MLI_TRANSHI
            sta   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :copied
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:copied     jsr   PADV_FL_PTRS
* -- K1: TRANS (trans_count) vs CHUNK (the request just issued)
* -- is now a real 16-bit compare -- CHUNK can be up to 512, so
* -- TRANSHI is no longer always 0 the way it was when the chunk
* -- size fit in a byte. TRANS < CHUNK means ProDOS returned
* -- fewer bytes than asked (short read = EOF mid-chunk); TRANS
* -- >= CHUNK means the chunk was satisfied in full, keep
* looping.
            lda   PMLI_RD_PARMS+MLI_TRANSHI
            cmp   PRC_CHUNK+1
            beq   :samehi
            bcc   :done
            jmp   :loop
:samehi     lda   PMLI_RD_PARMS+MLI_TRANSLO
            cmp   PRC_CHUNK
            bcc   :done
            jmp   :loop
:done       lda   PRC_DONE
            sta   PRC_PARM+MLI_TRANSLO
            lda   PRC_DONE+1
            sta   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts

PRC_FILE_WR
            stx   P_OBJ
            jsr   PRC_OFT_REFW
            bcc   :resident
            rts
:resident   sta   PMLI_WR_PARMS+MLI_REF
            lda   PRC_PARM+MLI_BUFLO
            sta   PRC_USER_PTR
            lda   PRC_PARM+MLI_BUFHI
            sta   PRC_USER_PTR+1
            lda   PRC_PARM+MLI_REQLO
            sta   PRC_REMAIN
            lda   PRC_PARM+MLI_REQHI
            sta   PRC_REMAIN+1
            stz   PRC_DONE
            stz   PRC_DONE+1
:loop       lda   PRC_REMAIN
            ora   PRC_REMAIN+1
            bne   :more
            jmp   :done
:more
            jsr   PRC_PCK_CHUNK
            jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   PRC_USER_PTR
            sta   K_BC_SRCADDR
            lda   PRC_USER_PTR+1
            sta   K_BC_SRCADDR+1
            lda   P_BANK
            sta   K_BC_SRCBANK
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            lda   #<PMLI_XFER_BUF
            sta   K_BC_DSTADDR
            lda   #>PMLI_XFER_BUF
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   PRC_CHUNK
            sta   K_BC_LEN
            lda   PRC_CHUNK+1
            sta   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :copied
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:copied     lda   #<PMLI_XFER_BUF
            sta   PMLI_WR_PARMS+MLI_BUFLO
            lda   #>PMLI_XFER_BUF
            sta   PMLI_WR_PARMS+MLI_BUFHI
            lda   PRC_CHUNK
            sta   PMLI_WR_PARMS+MLI_REQLO
            lda   PRC_CHUNK+1
            sta   PMLI_WR_PARMS+MLI_REQHI
            stz   PMLI_WR_PARMS+MLI_TRANSLO
            stz   PMLI_WR_PARMS+MLI_TRANSHI
            jsr   PMLI_WR_CALL
            beq   :wrote
            jsr   PRC_FAIL_A
            rts
:wrote      jsr   PADV_WR_PTRS
* -- K1: same 16-bit TRANS-vs-CHUNK compare as PRC_FILE_READ
* above
* -- (short write == disk full/error mid-chunk, stop; full chunk
* -- written, keep looping).
            lda   PMLI_WR_PARMS+MLI_TRANSHI
            cmp   PRC_CHUNK+1
            beq   :samehi
            bcc   :done
            jmp   :loop
:samehi     lda   PMLI_WR_PARMS+MLI_TRANSLO
            cmp   PRC_CHUNK
            bcc   :done
            jmp   :loop
:done       lda   PRC_DONE
            sta   PRC_PARM+MLI_TRANSLO
            lda   PRC_DONE+1
            sta   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts

*---------------------------------------------------------------
* The spawn fdactions list: PRC_FDA_CHECK (validate, before
* anything exists) and PRC_FDACTIONS (replay, after). Moved here
* from procfd.s 2026-08-20: that file was over real Merlin's
* MODULE_MAX (37000B, docs/TOOLCHAIN.md) once K2's PRC_READ/
* PRC_WRITE moved IN there; this file had the room they gave up.
* Kernel modules are one flat symbol space (same convention this
* file already relies on for PPP_REQ_LIMIT, procspawn.s).
*
* DUPFD-1 (docs/DUPFD-1.md): the replay used to SKIP a dup whose
* source the parent had closed, end the list at an opcode it did
* not know, take a failed read of the list for a clean end, and
* index PCB_FDTABLE with whatever fd byte it was handed (fd 8
* is the next PCB's first field, $FF wraps to the ones before
* the table).
* posix_spawn's contract is that a bad file action fails the
* spawn with nothing created, so the WHOLE list is walked first.
*---------------------------------------------------------------

*-- PRC_FDA_REC -- read the record at P_IDX of the list at
*-- PRC_FDA_PTR (the one walker: the check and the replay both
*-- use it). OUT: carry SET = unreadable, ERR_INVAL already
*-- set (PRDPAR_BYTE did); carry CLEAR: A = opcode, P_TMP =
*-- target fd and, for a DUP only, P_FD = source fd. A CLOSE's
*-- third byte is reserved: neither read nor judged.
*-- Clobbers X, Y, P_PTR1, PRC_BYTE.
PRC_FDA_REC
            clc
            lda   PRC_FDA_PTR
            adc   P_IDX
            sta   P_PTR1
            lda   PRC_FDA_PTR+1
            adc   #0
            sta   P_PTR1+1
            jsr   PRDPAR_BYTE          ;BYTE=opcode, +1=target
            bcs   :out
            lda   PRC_BYTE+1
            sta   P_TMP
            lda   PRC_BYTE
            cmp   #FDACT_DUP
            bne   :done                ;not a DUP: no source
            pha
            inc   P_PTR1               ;the source: two bytes on
            bne   :inc2
            inc   P_PTR1+1
:inc2       inc   P_PTR1
            bne   :src
            inc   P_PTR1+1
:src        jsr   PRDPAR_BYTE
            bcs   :bad
            lda   PRC_BYTE
            sta   P_FD
            pla
:done       clc
:out        rts
:bad        pla
            sec
            rts

*-- PRC_FDA_CHECK -- PRC_SPAWN calls this first of all, right
*-- after its parm copy: BEFORE the path probe (it leaves the
*-- path's first bytes in PRC_BYTE for PRC_BLTN, and this walk
*-- overwrites PRC_BYTE), before PRC_BLTN (so the builtin-image
*-- spawn and the file spawn are ONE site), before LZ_WANT_SET
*-- (a one-shot only the allocator consumes) and before
*-- PRC_ALLC_BANK. OUT: carry CLEAR = the list is good (or
*-- NULL); carry SET = a bad list, K_RESULT/K_RESULT_ERR set,
*-- nothing touched.
*--
*-- Every record: END ends it; DUP needs target < 8, source < 8
*-- and the source OPEN in the CALLER's table (K_CURPID --
*-- PRC_PAR_PID is only set after allocation, so it is stale
*-- here); CLOSE needs target < 8; any other opcode, or any
*-- unreadable byte, fails ERR_INVAL (what PRC_CUR_FDOBJ answers
*-- for a closed or out-of-range fd everywhere else). Bounded at
*-- 32 records, an END at the 33rd slot included: sh's worst
*-- case is 25 (FDABUFSZ, shpth2.s) and the byte index P_IDX
*-- steps by 3, so it would wrap at 85 and repeat for ever.
*-- Clobbers what PRC_FDA_REC does, P_PID, K_PCB_PTR.
PRC_FDA_CHECK
            lda   PRC_PARM+4
            sta   PRC_FDA_PTR
            lda   PRC_PARM+5
            sta   PRC_FDA_PTR+1
            ora   PRC_FDA_PTR
            beq   :good                ;NULL: no actions
            stz   P_IDX
:loop       jsr   PRC_FDA_REC
            bcs   :out
            cmp   #FDACT_END
            beq   :good
            cmp   #FDACT_CLOSE
            beq   :tgt
            cmp   #FDACT_DUP
            bne   :bad                 ;an opcode we do not have
            lda   P_FD
            cmp   #8
            bcs   :bad
            lda   K_CURPID
            sta   P_PID
            jsr   PRC_GET_FDOBJ
            beq   :bad                 ;the source is not open
:tgt        lda   P_TMP
            cmp   #8
            bcs   :bad
            lda   P_IDX
            clc
            adc   #3
            sta   P_IDX
            cmp   #99                  ;32 records + END slot
            bcc   :loop
:bad        lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
            rts
:good       clc
:out        rts

*-- PRC_FDACTIONS -- replay a list PRC_FDA_CHECK has proven
*-- good, onto the child (PRC_CHILD_PID) with sources taken from
*-- the parent (PRC_PAR_PID, set by now). Nothing here can fail:
*-- no read error, no unknown opcode, no closed or out-of-range
*-- fd. So a dup's source is never found empty and nothing
*-- here skips a record.
PRC_FDACTIONS
            lda   PRC_PARM+4
            sta   PRC_FDA_PTR
            lda   PRC_PARM+5
            sta   PRC_FDA_PTR+1
            ora   PRC_FDA_PTR
            bne   :have
            rts
:have       stz   P_IDX
:loop       jsr   PRC_FDA_REC
            cmp   #FDACT_DUP
            beq   :dup
            cmp   #FDACT_CLOSE
            beq   :close
            rts                        ;FDACT_END

:dup        lda   PRC_PAR_PID
            sta   P_PID
            jsr   PRC_GET_FDOBJ
            sta   P_OBJ
            lda   P_TMP
            sta   P_FD
            lda   PRC_CHILD_PID
            sta   P_PID
            jsr   PRC_GET_FDOBJ
            cmp   P_OBJ
            beq   :advance
*-- close-then-reference-then-set, shared with SYS_DUP2:
*-- src/kernel/procfd2.s PRC_DUP2_SET. It was written here
*-- first; dup2 needs the identical three steps against the
*-- caller's own table instead of the child's, so it moved
*-- rather than being copied.
            jsr   PRC_DUP2_SET
            bra   :advance

:close      lda   P_TMP
            sta   P_FD
            lda   PRC_CHILD_PID
            sta   P_PID
            jsr   PCLS_ONE_FD

:advance    clc
            lda   P_IDX
            adc   #3
            sta   P_IDX
            bra   :loop

*---------------------------------------------------------------
