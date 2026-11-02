*---------------------------------------------------------------
* shsgglb.s -- glob's result sort, segment-resident ($E000, like
* shsgblt.s). Moved out of shpth2.s 2026-10-17 (docs/GLOB-VROOT-
* NOTES.md sec 4): the walk that feeds it got the kernel's own
* directories, and the low image and sh's native main piece paid
* for that by shedding the one part of glob that runs once per
* expansion and touches no syscall. Called from GLOB_APPEND
* (shpth2.s) with `jsr GLOB_SORT`; it reads GLOBN and permutes
* GLOBIDX, so nothing here needs a buffer a syscall will see.
*---------------------------------------------------------------

*---------------------------------------------------------------
* GLOB_SORT -- insertion sort of the record INDEX array, so a
* swap moves one byte rather than 64. A shell returns matches in
* sorted order; ProDOS returns them in creation order.
*---------------------------------------------------------------
GLOB_SORT   ldx   #0
:init       cpx   GLOBN
            beq   :go
            txa
            sta   GLOBIDX,x
            inx
            bra   :init
:go         lda   #1
            sta   GSI
:outer      lda   GSI
            cmp   GLOBN
            bcs   :sdone
            sta   GSJ
:inner      lda   GSJ
            beq   :next
            tax
            lda   GLOBIDX-1,x
            sta   GSA
            lda   GLOBIDX,x
            sta   GSB
            jsr   GLOB_CMP
            bcc   :next                  ;already ordered
            ldx   GSJ
            lda   GSA
            sta   GLOBIDX,x
            lda   GSB
            sta   GLOBIDX-1,x
            dec   GSJ
            bra   :inner
:next       inc   GSI
            bra   :outer
:sdone      rts

*---------------------------------------------------------------
* GLOB_CMP -- carry SET if record GSA sorts AFTER record GSB.
* Case-insensitive, to agree with the matcher and with ProDOS.
*---------------------------------------------------------------
GLOB_CMP    lda   GSA
            sta   GSLOT
            jsr   GLOB_SLOTX
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
            lda   GSB
            sta   GSLOT
            jsr   GLOB_SLOTX
            ldy   #0
:clp        lda   (PTR1),y
            jsr   GFOLD
            sta   GSTMP
            lda   (PTR0),y
            jsr   GFOLD
            cmp   GSTMP
            bcc   :after
            beq   :same
            clc
            rts
:same       lda   (PTR1),y
            beq   :eq
            iny
            bne   :clp
:eq         clc
            rts
:after      sec
            rts
