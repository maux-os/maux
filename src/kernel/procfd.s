*---------------------------------------------------------------
* procfd.s -- Process fd layer: paths, PCB fields,
* open-file table, pipes.
* Split out of process.s 2026-08-16 so each kernel module fits
* real Merlin's 41215-byte source buffer
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J). The top-level image
* PUTs each module in order; Merlin-8 cannot nest PUT.
* Full design notes: K.PROCESS.TXT (docs/a2/)
*---------------------------------------------------------------

* Split from process.s: everything that manipulates a process
* control block, a file descriptor, or the open-file table.
* Path and chunk helpers.
*---------------------------------------------------------------
PCPY_SPWN_PTH
            lda   PRC_PARM
            sta   PRC_PATH_PTR
            lda   PRC_PARM+1
            sta   PRC_PATH_PTR+1
            stz   P_IDX
:loop       lda   P_IDX
            cmp   #64
            beq   :done
            clc
            lda   PRC_PATH_PTR
            adc   P_IDX
            sta   P_PTR1
            lda   PRC_PATH_PTR+1
            adc   #0
            sta   P_PTR1+1
            jsr   PRDPAR_BYTE
            bcs   :fail
            lda   PRC_BYTE
            beq   :done
            and   #$7F
            ldx   P_IDX
            sta   PRC_PATHBUF+1,x
            inc   P_IDX
            bra   :loop
:done       lda   P_IDX
            beq   :fail
            sta   PRC_PATHBUF
            lda   PRC_PATHBUF+1
            cmp   #"/"+$80
            clc
            bne   :rel                  ;relative: ProDOS's own
            stz   PRC_PATH_DST          ;prefix resolves it
            sta   VR_PEND
            jmp   VR_XLATE_P            ;virtual -> physical
:rel        rts
:fail       lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
            rts

*---------------------------------------------------------------
* PCPY_MLI_PATH / PCPY_NEW_PATH -- copy a user pathname into one
* of PRC_PATHBUF's two 65-byte slots.
*
* Parameterised, not duplicated: RENAME needs the same copy
* twice, from a different parm offset into a different slot.
* Both offsets are bytes and both slots are in ONE buffer, so
* the stores stay absolute,X with an 8-bit index.
*---------------------------------------------------------------
PCPY_MLI_PATH
            jsr   PCPY_MLI_RAW
            bra   PCPY_XL
PCPY_NEW_PATH
            jsr   PCPY_NEW_RAW
PCPY_XL     bcs   :r
            jmp   VR_XLATE_P
:r          rts

*-- RAW: the path stays VIRTUAL (VR_PEND says so). OPEN and
*-- SET_PREFIX look at it first, then call VR_XLATE_P.
PCPY_MLI_RAW
            lda   #MLI_PATHLO
            sta   PRC_PATH_SRC
            stz   PRC_PATH_DST
            bra   PCPY_PATH_G

PCPY_NEW_RAW
            lda   #MLI_NPATHLO
            sta   PRC_PATH_SRC
            lda   #PRC_PATH2OFF
            sta   PRC_PATH_DST

PCPY_PATH_G
            ldx   PRC_PATH_SRC
            lda   PRC_PARM,x
            sta   PRC_PATH_PTR
            inx
            lda   PRC_PARM,x
            sta   PRC_PATH_PTR+1
            lda   PRC_PATH_PTR
            sta   P_PTR1
            lda   PRC_PATH_PTR+1
            sta   P_PTR1+1
            jsr   PRDPAR_BYTE
            bcs   :fail
            lda   PRC_BYTE
            cmp   #65
            bcs   :fail
            ldx   PRC_PATH_DST
            sta   PRC_PATHBUF,x
            sta   P_COUNT
            stz   P_IDX
:loop       lda   P_IDX
            cmp   P_COUNT
            beq   :done
            clc
            lda   PRC_PATH_PTR
            adc   P_IDX
            sta   P_PTR1
            lda   PRC_PATH_PTR+1
            adc   #0
            sta   P_PTR1+1
            inc   P_PTR1
            bne   :ptrset
            inc   P_PTR1+1
:ptrset
            jsr   PRDPAR_BYTE
            bcs   :fail
            lda   P_IDX
            clc
            adc   PRC_PATH_DST
            tax
            lda   PRC_BYTE
            and   #$7F              ;fold to 7-bit: ProDOS
                                    ;masks path high bits
                                    ;(TRM 2.1), GET_PREFIX
                                    ;returns low ASCII, and
                                    ;our compares use $2F
                                    ;for '/', so a hi-bit
                                    ;asc path must be folded
                                    ;HERE or it aliases past
                                    ;the open-file guard
                                    ;(review F1; was in the
                                    ;old PRC_PARK_SAME too)
            sta   PRC_PATHBUF+1,x
            inc   P_IDX
            bra   :loop
:done       jmp   PRC_ABSPATH

:fail       lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
            rts

*---------------------------------------------------------------
* PRC_ABSPATH -- make the slot at PRC_PATH_DST absolute.
*
* This is where per-process cwd becomes REAL. Every delegated
* file call funnels through the path copier above, so resolving
* here covers OPEN, CREATE, DESTROY, RENAME (both paths) and
* SET_PREFIX with one implementation and no per-call changes.
*
* A path already starting with '/' is left alone. Otherwise the
* caller's cwd is prepended, with exactly one '/' between them
* however the cwd was stored. An empty cwd means the process
* never chdir'd, so the path stays relative and ProDOS resolves
* it against its own prefix -- the pre-cwd behaviour, and what
* pid 1 wants before anyone has set anything.
*
* Over-long results are REFUSED, not truncated: a ProDOS path
* maxes at 64, and silently shortening one opens a different
* file than the caller named.
*
* Per-process cwd resolution here was TRIED and DROPPED this
* task (docs/CD.md): recording a chdir into the per-process
* table (CWD_TBL_ADDR, sched.s) via CWD_WRITE landed the write
* shifted into a NEIGHBOURING pid's slot, reproducibly, root
* cause not found within budget -- both the hand-rolled
* RAMWRTAUX/(ptr),y loop AND a BankCopy-based rewrite showed the
* identical symptom, which pointed the fault away from either
* write primitive and at something this task could not isolate
* in time. `cd`'s ".." support (PRC_SETPFX/PRC_DOTDOT,
* process.s) resolves against ProDOS's own CURRENT prefix
* instead (real GET_PREFIX, read-only, proven reliable
* throughout this tree) -- it does not need this table at all.
* Scope cost: only `cd` itself gets ".." -- a plain `cat ../x`
* does not, since THAT would need per-call resolution here,
* which is exactly the code path that proved unreliable.
*---------------------------------------------------------------
PRC_ABSPATH stz   VR_PEND
            ldx   PRC_PATH_DST
            lda   PRC_PATHBUF,x         ;length byte
            beq   :leave                ;empty path -- not ours
            inx
            lda   PRC_PATHBUF,x
            cmp   #"/"+$80
            beq   :virt                 ;typed absolute: VIRTUAL
            lda   K_CURPID
            jsr   CWD_READ
            lda   K_CWD_BUF
            beq   :leave                ;no cwd -- stay relative

*-- Compose into PRC_TMPPATH. X is the DESTINATION index
*-- throughout; Y counts the source.
            ldy   #0
            ldx   #0
:cpcwd      cpy   K_CWD_BUF             ;cwd length
            beq   :cwddone
            iny
            lda   K_CWD_BUF,y
            and   #$7F                  ;synthetic cwd: bit 7
            sta   PRC_TMPPATH+1,x       ;is set on its '/'
            inx
            bra   :cpcwd

:cwddone    dex                         ;last char written
            lda   PRC_TMPPATH+1,x
            inx
            cmp   #"/"+$80
            beq   :nosep                ;cwd already ends in '/'
            lda   #"/"+$80
            sta   PRC_TMPPATH+1,x
            inx

*-- Append the caller's relative path. P_TMP walks the source
*-- slot; X stays the destination.
:nosep      lda   PRC_PATH_DST
            inc
            sta   P_TMP
            ldy   PRC_PATH_DST
            lda   PRC_PATHBUF,y
            sta   P_COUNT
            ldy   #0
:cppath     cpy   P_COUNT
            beq   :composed
            phx
            ldx   P_TMP
            lda   PRC_PATHBUF,x
            plx
            sta   PRC_TMPPATH+1,x
            inx
            inc   P_TMP
            iny
            bra   :cppath

:composed   txa
            cmp   #65
            bcs   :toolong
            sta   PRC_TMPPATH           ;composed length
*-- copy length byte + chars back into the slot
            ldy   #0
            ldx   PRC_PATH_DST
:back       lda   PRC_TMPPATH,y
            sta   PRC_PATHBUF,x
            inx
            iny
            cpy   PRC_TMPPATH
            bcc   :back
            beq   :back
            lda   K_CWD_BUF+1           ;synthetic cwd: the
            bpl   :leave                ;result is VIRTUAL; a
:virt       sta   VR_PEND               ;real one is physical
:leave      clc
            rts
:toolong    lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
            rts

*---------------------------------------------------------------
* PRC_PCK_CHUNK -- K1: PRC_CHUNK (2 bytes) = MIN(PRC_REMAIN,
* PMLI_XFR_SIZE), both 16-bit. Was a single-byte immediate
* compare (PMLI_XFR_SIZE topped out at 128, fit in a byte); K1
* raised the size to 512 so this is now a real 16-bit compare --
* every caller (procfile.s PRC_FILE_READ/PRC_FILE_WR,
* procspawn.s's loader) already treats PRC_CHUNK as 2 bytes.
*---------------------------------------------------------------
PRC_PCK_CHUNK
            lda   PRC_REMAIN+1
            cmp   #>PMLI_XFR_SIZE
            bcc   :useremain     ;hi(REMAIN) < hi(XFR) -> REMAIN
                                 ;smaller
            bne   :max           ;hi(REMAIN) > hi(XFR) -> XFR
                                 ;smaller (clamp)
            lda   PRC_REMAIN
            cmp   #<PMLI_XFR_SIZE
            bcc   :useremain     ;hi equal, lo(REMAIN) < lo(XFR)
:max        lda   #<PMLI_XFR_SIZE
            sta   PRC_CHUNK
            lda   #>PMLI_XFR_SIZE
            sta   PRC_CHUNK+1
            rts
:useremain  lda   PRC_REMAIN
            sta   PRC_CHUNK
            lda   PRC_REMAIN+1
            sta   PRC_CHUNK+1
            rts

PADV_FL_PTRS
            clc
            lda   PRC_DONE
            adc   PMLI_RD_PARMS+MLI_TRANSLO
            sta   PRC_DONE
            lda   PRC_DONE+1
            adc   PMLI_RD_PARMS+MLI_TRANSHI
            sta   PRC_DONE+1
            clc
            lda   PRC_USER_PTR
            adc   PMLI_RD_PARMS+MLI_TRANSLO
            sta   PRC_USER_PTR
            lda   PRC_USER_PTR+1
            adc   PMLI_RD_PARMS+MLI_TRANSHI
            sta   PRC_USER_PTR+1
            sec
            lda   PRC_REMAIN
            sbc   PMLI_RD_PARMS+MLI_TRANSLO
            sta   PRC_REMAIN
            lda   PRC_REMAIN+1
            sbc   PMLI_RD_PARMS+MLI_TRANSHI
            sta   PRC_REMAIN+1
            rts

PADV_WR_PTRS
            clc
            lda   PRC_DONE
            adc   PMLI_WR_PARMS+MLI_TRANSLO
            sta   PRC_DONE
            lda   PRC_DONE+1
            adc   PMLI_WR_PARMS+MLI_TRANSHI
            sta   PRC_DONE+1
            clc
            lda   PRC_USER_PTR
            adc   PMLI_WR_PARMS+MLI_TRANSLO
            sta   PRC_USER_PTR
            lda   PRC_USER_PTR+1
            adc   PMLI_WR_PARMS+MLI_TRANSHI
            sta   PRC_USER_PTR+1
            sec
            lda   PRC_REMAIN
            sbc   PMLI_WR_PARMS+MLI_TRANSLO
            sta   PRC_REMAIN
            lda   PRC_REMAIN+1
            sbc   PMLI_WR_PARMS+MLI_TRANSHI
            sta   PRC_REMAIN+1
            rts

*---------------------------------------------------------------
* PCB/fd helpers.
*---------------------------------------------------------------
PPCB_WR_BYTE
            lda   P_PID
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            ldy   P_TMP
            lda   P_TMP2
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN
            rts

*---------------------------------------------------------------
* PPCB_WR_PAR -- A = parent pid, P_PID = the child: publish
* PCB_PARENT in the annex AND in its main shadow K_PAR_SHD
* (WAIT-1). The ONLY writer of a nonzero PCB_PARENT:
* PPCB_WR_BYTE stays generic, but no caller may hand it
* PCB_PARENT (check-wait census). The shadow store sits AFTER
* PPCB_WR_BYTE's RAMWRTMAIN: an absolute store inside the
* RAMWRTAUX bracket lands in aux.
* Clobbers A, X, Y, P_TMP, P_TMP2.
*---------------------------------------------------------------
PPCB_WR_PAR
            sta   P_TMP2
            lda   #PCB_PARENT
            sta   P_TMP
            jsr   PPCB_WR_BYTE
            lda   P_PID
            jsr   PAR_CELL               ;X = 48 - child
            lda   P_TMP2
            sta   K_PAR_SHD,x            ;main (RAMWRT is main)
            rts

PRDPAR_FIELD
            lda   P_PID
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            lda   #PCB_PARENT
            ldx   #1
            jsr   PCB_RD_FIELDS
            rts

PRC_GET_FDOBJ
            lda   P_PID
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            clc
            lda   #PCB_FDTABLE
            adc   P_FD
            ldx   #1
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH
            rts

PRC_SET_FDOBJ
            lda   P_PID
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            clc
            lda   #PCB_FDTABLE
            adc   P_FD
            tay
            lda   P_TMP2
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN
            rts

PRC_CUR_FDOBJ
            lda   P_FD
            cmp   #8
            bcc   :fdok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
            rts
:fdok       lda   K_CURPID
            sta   P_PID
            jsr   PRC_GET_FDOBJ
            beq   :closed
            clc
            rts
:closed     lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
            rts

PRC_FND_FR_FD
            lda   #3
            sta   P_FD
:loop       lda   P_FD
            cmp   #8
            beq   :none
            lda   K_CURPID
            sta   P_PID
            jsr   PRC_GET_FDOBJ
            beq   :found
            inc   P_FD
            bra   :loop
:found      lda   P_FD
            clc
            rts
:none       lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
            rts

PCLS_ONE_FD
            stz   K_CLSERR             ;OPEN-RW-2: PRC_DEC_OBJ's
            jsr   PRC_GET_FDOBJ        ;verdict on THIS close
            beq   :done
            sta   P_OBJ
            cmp   #FD_DEV_BASE
            bcs   :clear
            jsr   PRC_DEC_OBJ
:clear
            lda   #0
            sta   P_TMP2
            jsr   PRC_SET_FDOBJ
:done       rts

PCLS_ALL_FDS
            stz   P_FD
:loop       lda   P_FD
            cmp   #8
            beq   :done
            jsr   PCLS_ONE_FD
            inc   P_FD
            bra   :loop
:done       rts

PRC_DFLT_FDS
            stz   P_FD
:loop       lda   P_FD
            cmp   #3
            beq   :done
            lda   PRC_PAR_PID
            sta   P_PID
            jsr   PRC_GET_FDOBJ
            bne   :have
            lda   #FD_TTY0
:have
            sta   P_TMP2
            cmp   #FD_DEV_BASE
            bcs   :setchild
            jsr   PRC_INC_OBJ_A
:setchild
            lda   PRC_CHILD_PID
            sta   P_PID
            jsr   PRC_SET_FDOBJ
            inc   P_FD
            bra   :loop
:done       rts

* -- PRC_FDACTIONS/PRDFDA_TARGET/PRDFDA_SOURCE moved to
* -- procfile.s 2026-08-20 -- this file was over real Merlin's
* -- MODULE_MAX (37000B, docs/TOOLCHAIN.md) once K2's PRC_READ/
* -- PRC_WRITE moved IN; procfile.s had the room they gave up.
* -- Kernel modules are one flat symbol space (same convention
* -- noted where PRC_READ/PRC_WRITE landed, above).


*---------------------------------------------------------------
* TTY_RUN -- write-path RUN BATCH, all three foreground backends
* (docs/CONSOLE-RUN-BATCH.md). Placed here (not tty4/tty8)
* purely
* for as's source window. Was TTY_UT_RUN, the card only, until
* perf slice 2 (2026-09-12, performance-review item 4) gave the
* native-80 and 40-column backends the same shape: an 80-char
* row on native-80 cost 31.7k cycles per-cell (N8_STORE's row
* setup + one masked aux window PER EVEN COLUMN), 2.7x the card.
*
* If not redirected (TTY_DSTBASE+1==0), not mid-escape
* (VC_ESC_STATE==0), not in IRM or the line-drawing set, and
* TTY_OUTBUF[P_FD] is printable -- bit 7 ignored, so $20-$7E
* and $A0-$FE alike (TTY_PUT_BYTE folds bit 7 first, so the
* per-byte path never told them apart either; the run path DID,
* admitting only high-bit text, and tip(1) masks every incoming
* byte to 7 bits, so a remote screen paid 3.4x -- review
* 2026-09-12
* performance review, item 1) -- encode the maximal printable
* run into UT_ROWBUF[VC_COL..] -- bounded by the chunk end
* (P_PIPE), the row right edge, or a control byte -- then store
* it with ONE backend span: UT_PUT_SPAN (VRAM, one firmware
* setup), N8_PUT_SPAN (tty5.s: odd columns straight to main,
* even columns through one masked aux window) or a direct
* text-page copy (40-column, contiguous row). Then advance
* VC_COL/P_FD/PRC_TRANS by the run and wrap (TTY_NEWLINE) if it
* filled the row. The card store is no longer written here
* (VCS_ST_SPAN, removed 2026-09-10): it is rebuilt from VRAM on
* switch-away (VCS_UTSAVE).
*
* The encode is per backend, the same fold TTY_WR_CELL applies
* per cell: card cells are ASCII with bit 7 = inverse; text-page
* cells are ASCII OR $80 with TTY_INVERSE_A's range fold for
* inverse (VC_ATTR is constant across a run -- an SGR is a
* control byte, which ends the run; CONSOLE-RUN-BATCH.md sec 4).
* The run taps the ^L shadow ONCE, at :done, via TTY_SHDW_SPN
* (below) -- a jsr TTY_SHDW_TAP per byte until 2026-09-16.
* cap = min(chunk room P_PIPE-P_FD, row room TTY_COLS-VC_COL).
* Carry CLEAR = handled; SET = not applicable, caller runs its
* per-byte path. CLOBBERS A,X,Y,P_PTR1,P_PTR2,PRC_BYTE,
* UT_RUNLEN,UT_RUNCAP,UT_TMPCOL,UT_SPANEND,TT9_EEND,P_TMP.
*
* VT102 slices 2/3 (docs/CONSOLE-VT102.md sec 2/4): this batch
* path is a SECOND renderer beside TTY_PUT_PRNTB (tty2.s), so
* both of that routine's new checks have to be repeated here or
* the glass silently loses them. IRM (VC_IRM) REJECTS the batch
* outright -- the per-byte path's TT9_ICHSH shift has no batched
* form, and IRM is an interactive-typing feature, not a bulk-
* output one, so there is nothing to optimize. xenl (VC_XENL): a
* PENDING wrap is consumed (newline) before this run paints
* anything, the same as TTY_PUT_PRNTB's own top check; a run
* that fills exactly to the last column sets the flag instead
* of wrapping, the same as TTY_PUT_PRNTB's tail check. Found
* live, both slices: check-vt102 smir/rmir and xenl went red on
* the 'ut' backend only, text40/text80 green, because this
* routine intercepts every printable BEFORE TTY_PUT_PRNTB ever
* sees it (2026-09-12). Since perf slice 2 it intercepts them
* on every backend, so those cases guard all three legs.
*---------------------------------------------------------------
TTY_RUN
            lda   TTY_DSTBASE+1
            bne   :rej
            lda   VC_ESC_STATE
            bne   :rej
            lda   VC_IRM
            bne   :rej
            lda   VC_ACS                   ;line-drawing set
            bne   :rej                     ;active: per-byte map
            ldx   P_FD
            lda   TTY_OUTBUF,x
            and   #$7F                     ;7-bit and high-bit
            cmp   #$20                     ;text are the same
            bcc   :rej                     ;printable here
            cmp   #$7F                     ;(DEL is not)
            bcc   :chkxenl
:rej        sec
            rts
:chkxenl    lda   VC_XENL
            beq   :body
            stz   VC_XENL
            jsr   TTY_NEWLINE
:body       sec
            lda   P_PIPE
            sbc   P_FD
            sta   UT_RUNCAP
            sec
            lda   TTY_COLS
            sbc   VC_COL
            cmp   UT_RUNCAP
            bcs   :cap
            sta   UT_RUNCAP
:cap        clc
            lda   #<TTY_OUTBUF
            adc   P_FD
            sta   P_PTR1
            lda   #>TTY_OUTBUF
            adc   #0
            sta   P_PTR1+1
            clc
            lda   #<UT_ROWBUF
            adc   VC_COL
            sta   P_PTR2
            lda   #>UT_ROWBUF
            adc   #0
            sta   P_PTR2+1
            ldy   #0
            lda   TTY_BKND
            cmp   #TTY_BKUT
            bne   :apenc
*-- card encode: ASCII, bit 7 = inverse
:enc        cpy   UT_RUNCAP
            bcs   :done
            lda   (P_PTR1),y
            and   #$7F                     ;the encode folds the
            cmp   #$20                     ;byte; the ^L shadow
            bcc   :done                    ;keeps the raw one
            cmp   #$7F                     ;and is taken as a
            bcs   :done                    ;SPAN at :done
            ldx   VC_ATTR
            beq   :noat
            ora   #$80
:noat       sta   (P_PTR2),y
            iny
            bra   :enc
*-- text-page encode: ASCII OR $80, inverse by the range fold
:apenc      cpy   UT_RUNCAP
            bcs   :done
            lda   (P_PTR1),y
            and   #$7F
            cmp   #$20
            bcc   :done
            cmp   #$7F
            bcs   :done
            ora   #$80                     ;(A&$7F)|$80 == A|$80
            ldx   VC_ATTR
            beq   :apst
            jsr   TTY_INVERSE_A
:apst       sta   (P_PTR2),y
            iny
            bra   :apenc
:done       sty   UT_RUNLEN
            lda   UT_RUNLEN
            bne   :shdw
            sec
            rts
:shdw       jsr   TTY_SHDW_SPN             ;the whole run, once
:render     lda   VC_COL
            sta   UT_TMPCOL
            clc
            adc   UT_RUNLEN
            sta   TT9_EEND                 ;end col (exclusive)
            tax
            lda   TTY_BKND
            cmp   #TTY_BKUT
            bne   :aprend
            lda   VC_ROW
*-- VRAM only; the store is rebuilt from VRAM on switch-away
*-- (VCS_UTSAVE) -- no per-run store copy.
            jsr   UT_PUT_SPAN
            bra   :adv
:aprend     cmp   #TTY_BKN8
            bne   :r40
            jsr   N8_PUT_SPAN
            bra   :adv
:r40        lda   VC_ROW                   ;40-col: the row is
            jsr   TTY_ROW_DST_A            ;40 contiguous bytes
            ldy   VC_COL
:c40        lda   UT_ROWBUF,y
            sta   (P_PTR2),y
            iny
            cpy   TT9_EEND
            bcc   :c40
:adv        clc
            lda   VC_COL
            adc   UT_RUNLEN
            sta   VC_COL
            clc
            lda   P_FD
            adc   UT_RUNLEN
            sta   P_FD
            clc
            lda   PRC_TRANS
            adc   UT_RUNLEN
            sta   PRC_TRANS
            lda   VC_COL
            cmp   TTY_COLS
            bcc   :nowrap
            dec   VC_COL                   ;xenl: park at the
            lda   VC_AWM                   ;last column, defer
            beq   :nowrap                  ;the wrap (slice 3)
            lda   #1                       ;-- unless autowrap
            sta   VC_XENL                  ;is off (slice 7)
:nowrap     clc
            rts

*---------------------------------------------------------------
* TTY_SHDW_SPN -- the ^L replay shadow for a WHOLE printable run
* (TTY_OUTBUF via P_PTR1, UT_RUNLEN bytes), the span form of
* tty.s TTY_SHDW_TAP. TTY_RUN used to `jsr TTY_SHDW_TAP` once
* PER BYTE; that call was the single largest named cost in a
* console write -- 910 entries and 35,521 cycles, 14% of a
* 23-line `man cut` page, plus the 6 cycles a byte the two
* encode loops spent stashing the raw byte in PRC_BYTE and
* reloading it purely to hand it over (docs/PROCIO.md sec 15).
*
* The filter collapses to ONE `bpl`, and that is exact, not an
* approximation. TTY_RUN's encode loops admit a byte only when
* $20 <= b&$7F <= $7E, so every byte of a run is in
* [$20,$7E] + [$A0,$FE]. TTY_SHDW_TAP records exactly
* $A0 <= b < $FF, which over that set is exactly "bit 7 set".
* Its other two guards cannot fire on a run byte either:
* VC_ESC_STATE is 0 (TTY_RUN rejects a run outright when it is
* not) and $8D folds to $0D, below $20, so a CR ends the run
* before it can be recorded. The 80-byte cap and the append
* order are kept as they were; nothing reads the shadow between
* bytes, so recording the run at its end is indistinguishable
* from recording it byte by byte.
*
* Carries no error. CLOBBERS A, X, Y. Called from TTY_RUN only,
* after :done has set UT_RUNLEN and while P_PTR1 still points at
* the run's first byte.
*---------------------------------------------------------------
TTY_SHDW_SPN
            ldx   VC_OSHDW_LEN
            cpx   #80                      ;already at the cap:
            bcs   :sdone                   ;record nothing
            ldy   #0
:slp        lda   (P_PTR1),y
            bpl   :snext                   ;7-bit: not recorded,
                                           ;same as TTY_SHDW_TAP
            sta   VC_OUTSHDW,x
            inx
            cpx   #80
            bcs   :sfin                    ;hit the cap mid-run
:snext      iny
            cpy   UT_RUNLEN
            bcc   :slp
:sfin       stx   VC_OSHDW_LEN
:sdone      rts
