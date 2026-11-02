*---------------------------------------------------------------
* difflpb.s -- diff's line-pair buffer machinery,
* extracted from diff.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2 mains). One
* assembly stream: put exactly where the text sat; every rule
* in the manifest header applies unchanged.
*---------------------------------------------------------------
LPB_GET     sec
            sbc   #1
            asl   a
            sta   DF_LPTMP
            stz   DF_LPTMP+1
            clc
            lda   DF_LPTMP
            adc   #<LPB
            sta   DF_LPTMP
            lda   DF_LPTMP+1
            adc   #>LPB
            sta   DF_LPTMP+1
            lda   (DF_LPTMP)
            tax
            ldy   #1
            lda   (DF_LPTMP),y
            sta   DF_LPTMP+1
            stx   DF_LPTMP
            rts

*---------------------------------------------------------------
* PRLINE_A/PRLINE_B -- IN: A = 1-based line number. Print that
* line's text (PUTS) then CR, to fd 1. CLOBBERS: A,X,Y,PTR0.
*---------------------------------------------------------------
PRLINE_A    jsr   LPA_GET
            lda   DF_LPTMP
            sta   PTR0
            lda   DF_LPTMP+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

PRLINE_B    jsr   LPB_GET
            lda   DF_LPTMP
            sta   PTR0
            lda   DF_LPTMP+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* MUL16 -- IN: DF_M1 (2 bytes, high byte 0 on entry), DF_M2 (1
* byte). OUT: DF_PROD (2 bytes) = DF_M1 * DF_M2. Classic
* shift-add over DF_M2's 8 bits. CLOBBERS: A,X, DF_M1, DF_M2.
*---------------------------------------------------------------
MUL16       stz   DF_PROD
            stz   DF_PROD+1
            ldx   #8
:loop       lsr   DF_M2
            bcc   :noadd
            clc
            lda   DF_PROD
            adc   DF_M1
            sta   DF_PROD
            lda   DF_PROD+1
            adc   DF_M1+1
            sta   DF_PROD+1
:noadd      asl   DF_M1
            rol   DF_M1+1
            dex
            bne   :loop
            rts

*---------------------------------------------------------------
* DPCHECK -- OVERFLOW (no return) if (NA+1)*(NB+1) exceeds
* DP_MAX_BYTES. rts otherwise. Must run BEFORE the table is
* touched -- see header.
*---------------------------------------------------------------
DPCHECK     lda   NA
            clc
            adc   #1
            sta   DF_M1
            stz   DF_M1+1
            lda   NB
            clc
            adc   #1
            sta   DF_M2
            jsr   MUL16
            lda   DF_PROD+1
            cmp   #>DP_MAX_BYTES
            bcc   :ok
            bne   :bad
            lda   DF_PROD
            cmp   #<DP_MAX_BYTES
            bcc   :ok
:bad        jmp   OVERFLOW
:ok         rts

*---------------------------------------------------------------
* DPFILL -- fill LCS[0..NA][0..NB] row-major at DPTABLE. Row 0
* is the explicit zero base case; every other row's cell(i,0) is
* also 0 (base case). Recurrence: match -> diag+1; else ->
* max(up,left). No multiply anywhere in this routine -- row i+1
* always starts one byte past row i's last cell (see header).
*---------------------------------------------------------------
DPFILL      lda   #<DPTABLE
            sta   DF_ROWPTR
            lda   #>DPTABLE
            sta   DF_ROWPTR+1
            lda   NB
            clc
            adc   #1
            sta   DF_STRIDE
            stz   DF_STRIDE+1
            lda   DF_STRIDE
            sta   DF_TMP
:zloop      lda   DF_TMP
            beq   :zdone
            lda   #0
            sta   (DF_ROWPTR)
            inc   DF_ROWPTR
            bne   :zn
            inc   DF_ROWPTR+1
:zn         dec   DF_TMP
            bra   :zloop
:zdone      lda   #<DPTABLE
            sta   DF_PVSTART
            lda   #>DPTABLE
            sta   DF_PVSTART+1
            clc
            lda   DF_PVSTART
            adc   DF_STRIDE
            sta   DF_ROWSTA
            lda   DF_PVSTART+1
            adc   DF_STRIDE+1
            sta   DF_ROWSTA+1
            lda   #1
            sta   DF_I
:iloop      lda   DF_I
            cmp   NA
            beq   :dorow
            bcc   :dorow
            jmp   :fdone
:dorow      lda   #0
            sta   (DF_ROWSTA)
            lda   DF_ROWSTA
            sta   DF_ROWPTR
            lda   DF_ROWSTA+1
            sta   DF_ROWPTR+1
            lda   DF_PVSTART
            sta   DF_PVPTR
            lda   DF_PVSTART+1
            sta   DF_PVPTR+1
            lda   #1
            sta   DF_J
:jloop      lda   DF_J
            cmp   NB
            beq   :dcell
            bcc   :dcell
            jmp   :rowdone
:dcell      lda   (DF_PVPTR)
            sta   DF_TMP        ;diagval
            inc   DF_PVPTR
            bne   :pvok
            inc   DF_PVPTR+1
:pvok       lda   (DF_PVPTR)
            sta   DF_TMP+1      ;upval
            lda   (DF_ROWPTR)
            sta   DF_M1         ;leftval (byte, DPCHECK is done)
            lda   DF_I
            jsr   LPA_GET
            lda   DF_LPTMP
            sta   PTR0
            lda   DF_LPTMP+1
            sta   PTR0+1
            lda   DF_J
            jsr   LPB_GET
            lda   DF_LPTMP
            sta   PTR1
            lda   DF_LPTMP+1
            sta   PTR1+1
            jsr   DF_LCMP
            bne   :neq
            lda   DF_TMP
            clc
            adc   #1
            bra   :cstore
:neq        lda   DF_TMP+1
            cmp   DF_M1
            bcs   :useup
            lda   DF_M1
            bra   :cstore
:useup      lda   DF_TMP+1
:cstore     inc   DF_ROWPTR
            bne   :rpok
            inc   DF_ROWPTR+1
:rpok       sta   (DF_ROWPTR)
            inc   DF_J
            jmp   :jloop
:rowdone    lda   DF_ROWSTA
            sta   DF_PVSTART
            lda   DF_ROWSTA+1
            sta   DF_PVSTART+1
            lda   DF_ROWPTR
            clc
            adc   #1
            sta   DF_ROWSTA
            lda   DF_ROWPTR+1
            adc   #0
            sta   DF_ROWSTA+1
            inc   DF_I
            jmp   :iloop
:fdone      rts

*---------------------------------------------------------------
* BACKTRACE -- walk cell(NA,NB) back to cell(0,0), emitting
* OP_KEEP/OP_DEL/OP_INS into OPS, building it FORWARD-ordered by
* writing from the END of OPS backward (no separate reverse
* pass). Content-equal lines always take the diagonal (matches
* DPFILL's own unconditional diag+1 rule); otherwise prefers
* OP_INS on a tie (leftval >= upval) -- a fixed, documented
* tie-break, not left to chance. The one multiply in this
* routine computes the SINGLE starting address; every step after
* that is a pointer add/subtract by 1 or DF_STRIDE.
*---------------------------------------------------------------
BACKTRACE   lda   NB
            clc
            adc   #1
            sta   DF_STRIDE
            stz   DF_STRIDE+1
            lda   NA
            sta   DF_M1
            stz   DF_M1+1
            lda   DF_STRIDE
            sta   DF_M2
            jsr   MUL16
            clc
            lda   DF_PROD
            adc   #<DPTABLE
            sta   DF_CURPTR
            lda   DF_PROD+1
            adc   #>DPTABLE
            sta   DF_CURPTR+1
            clc
            lda   DF_CURPTR
            adc   NB
            sta   DF_CURPTR
            lda   DF_CURPTR+1
            adc   #0
            sta   DF_CURPTR+1
            lda   NA
            sta   DF_I
            lda   NB
            sta   DF_J
            lda   #OPS_MAX-1
            sta   DF_WPOS
:bloop      lda   DF_I
            ora   DF_J
            beq   :bdone
            lda   DF_I
            beq   :noeq
            lda   DF_J
            beq   :noeq
            lda   DF_I
            jsr   LPA_GET
            lda   DF_LPTMP
            sta   PTR0
            lda   DF_LPTMP+1
            sta   PTR0+1
            lda   DF_J
            jsr   LPB_GET
            lda   DF_LPTMP
            sta   PTR1
            lda   DF_LPTMP+1
            sta   PTR1+1
            jsr   DF_LCMP
            bne   :noeq
            lda   #OP_KEEP
            jsr   BPUTOP
            jsr   BMVSTRD       ;CUR_PTR -= STRIDE
            jsr   BMV1          ;CUR_PTR -= 1
            dec   DF_I
            dec   DF_J
            jmp   :bloop
:noeq       lda   DF_J
            beq   :mustdel
            lda   DF_I
            beq   :mustins
            lda   DF_CURPTR
            sec
            sbc   DF_STRIDE
            sta   DF_UPPTR
            lda   DF_CURPTR+1
            sbc   DF_STRIDE+1
            sta   DF_UPPTR+1
            lda   DF_CURPTR
            sec
            sbc   #1
            sta   DF_LEFTPTR
            lda   DF_CURPTR+1
            sbc   #0
            sta   DF_LEFTPTR+1
            lda   (DF_UPPTR)
            sta   DF_TMP
            lda   (DF_LEFTPTR)
            cmp   DF_TMP
            bcs   :doins
:mustdel    lda   #OP_DEL
            jsr   BPUTOP
            jsr   BMVSTRD
            dec   DF_I
            jmp   :bloop
:doins
:mustins    lda   #OP_INS
            jsr   BPUTOP
            jsr   BMV1
            dec   DF_J
            jmp   :bloop
:bdone      lda   DF_WPOS
            clc
            adc   #1
            sta   OPS_START
            rts

* BPUTOP -- IN: A = op byte. Store at OPS[DF_WPOS], DF_WPOS--.
BPUTOP      ldy   DF_WPOS
            sta   OPS,y
            dec   DF_WPOS
            rts

* BMVSTRD -- DF_CURPTR -= DF_STRIDE (16-bit).
BMVSTRD     sec
            lda   DF_CURPTR
            sbc   DF_STRIDE
            sta   DF_CURPTR
            lda   DF_CURPTR+1
            sbc   DF_STRIDE+1
            sta   DF_CURPTR+1
            rts

* BMV1 -- DF_CURPTR -= 1 (16-bit).
BMV1        lda   DF_CURPTR
            bne   :nb
            dec   DF_CURPTR+1
:nb         dec   DF_CURPTR
            rts

*---------------------------------------------------------------
* MKHUNKS -- scan OPS[OPS_START..OPS_MAX-1] forward, grouping
* maximal non-KEEP runs into HUNKTBL records {HA,HB,HDELS,HINS}
* (HA/HB = last unchanged line before the hunk, in file1/file2).
* Jumps to OVERFLOW (no return) past MAXHUNKS.
*---------------------------------------------------------------
MKHUNKS     stz   NHUNKS
            stz   INHUNK
            lda   #1
            sta   ANEXT
            sta   BNEXT
            lda   OPS_START
            sta   OPSCUR
:oloop      lda   OPSCUR
            cmp   #OPS_MAX
            bcc   :have
            jmp   :closeall
:have       ldy   OPSCUR
            lda   OPS,y
            cmp   #OP_KEEP
            bne   :notkeep
            lda   INHUNK
            beq   :advkeep
            jsr   CLOSEHUNK
:advkeep    inc   ANEXT
            inc   BNEXT
            bra   :nextop
:notkeep    cmp   #OP_DEL
            bne   :isins
            lda   INHUNK
            bne   :delgo
            jsr   OPENHUNK
:delgo      inc   HDELS
            inc   ANEXT
            bra   :nextop
:isins      lda   INHUNK
            bne   :insgo
            jsr   OPENHUNK
:insgo      inc   HINS
            inc   BNEXT
:nextop     inc   OPSCUR
            jmp   :oloop
:closeall   lda   INHUNK
            beq   :mkdone
            jsr   CLOSEHUNK
:mkdone     rts

OPENHUNK    lda   #1
            sta   INHUNK
            lda   ANEXT
            sec
            sbc   #1
            sta   HA
            lda   BNEXT
            sec
            sbc   #1
            sta   HB
            stz   HDELS
            stz   HINS
            rts

*---------------------------------------------------------------
* DF_LCMP -- compare the two lines at PTR0/PTR1, returning Z set
* when they are equal, exactly as STRCMP does. Without -b it IS
* STRCMP (tail call, no cost); with -b it applies POSIX's rule:
* "any amount of white space at the end of a line ... treated as
* a single <newline>", and other white-space strings compare
* equal to each other.
*
* A RUN MUST FACE A RUN. "a b" and "ab" are NOT equal under -b
* -- the rule makes runs of white space equivalent to each
* other, not equivalent to none -- and the only place a run may
* face nothing is at end of line, which is the both-at-NUL test
* below. Getting that backwards would quietly merge lines a
* person can see are different, so the two cases are separate
* branches rather than one clever test.
*---------------------------------------------------------------
DF_LCMP     lda   BFLAG
            bne   :bcmp
            jmp   STRCMP
:bcmp       stz   DF_BI
            stz   DF_BJ
:blp        ldy   DF_BI
            lda   (PTR0),y
            jsr   DF_ISWS
            lda   #0
            rol   a
            sta   DF_AWS
            beq   :askipd
:askip      inc   DF_BI
            ldy   DF_BI
            lda   (PTR0),y
            jsr   DF_ISWS
            bcs   :askip
:askipd     ldy   DF_BJ
            lda   (PTR1),y
            jsr   DF_ISWS
            lda   #0
            rol   a
            sta   DF_BWS
            beq   :bskipd
:bskip      inc   DF_BJ
            ldy   DF_BJ
            lda   (PTR1),y
            jsr   DF_ISWS
            bcs   :bskip
*-- neither cursor sits on white space now
:bskipd     ldy   DF_BI
            lda   (PTR0),y
            sta   DF_BA
            ldy   DF_BJ
            lda   (PTR1),y
            sta   DF_BB
            lda   DF_BA
            ora   DF_BB
            beq   :beq              ;both ended: trailing blanks
            lda   DF_AWS            ;are gone by construction
            eor   DF_BWS
            bne   :bne              ;a run faced something that
            lda   DF_AWS            ;was not a run, mid-line
            bne   :blp              ;both consumed runs
            lda   DF_BA
            cmp   DF_BB
            bne   :bne
            inc   DF_BI
            inc   DF_BJ
            bra   :blp
:beq        lda   #0
            rts
:bne        lda   #1
            rts

*-- carry SET if A is a white-space byte. Space and tab are the
*-- whole set here: a newline never appears INSIDE one of these
*-- lines, having been the thing that ended it.
DF_ISWS     cmp   #$A0
            beq   :wyes
            cmp   #$89
            beq   :wyes
            clc
            rts
:wyes       sec
            rts
