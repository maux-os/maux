*---------------------------------------------------------------
* sortnum.s -- sort's numeric-compare half (NUMKCMP/NPREPA/
* NPREPB/ISDIGIT). Further split 2026-09-01:
* window charges the MAIN plus its LARGEST put, so one big put
* is the same debt as inline text; smaller pieces are the only
* way down. One assembly stream, put in place; every
* manifest-header rule applies unchanged.
*---------------------------------------------------------------

*---------------------------------------------------------------
* NUMKCMP -- numeric compare at the two key starts: skip
* blanks, note a '-', strip leading zeros, then decide by sign,
* significant-digit COUNT (16-bit -- no value arithmetic, no
* cap), and finally the digit strings themselves. No digits
* parses as 0, and -0 == 0 (both empty after the zero strip).
*---------------------------------------------------------------
NUMKCMP     jsr   NPREPA
            lda   SRT_KA                ;NPREPB walks SRT_KA as
            sta   SRT_KAE               ;its scratch -- park A's
            lda   SRT_KA+1              ;digit start in the (now
            sta   SRT_KAE+1             ;dead) probe cell. The
            jsr   NPREPB                ;first cut skipped this
            lda   SRT_KAE               ;and compared B's digits
            sta   SRT_KA                ;against B's digits --
            lda   SRT_KAE+1             ;every number "equal"
            sta   SRT_KA+1
            ;-- both zero?
            lda   SRT_NLA
            ora   SRT_NLA+1
            ora   SRT_NLB
            ora   SRT_NLB+1
            bne   :signs
            lda   #0                    ;0 == -0 == "abc"
            rts
:signs      lda   SRT_SGNA
            cmp   SRT_SGNB
            beq   :same
            ;-- signs differ; zero magnitudes already handled,
            ;-- except one side may still be an EMPTY 0 --
            ;-- treat 0 as positive: "-3" < "0", "0" < "3".
            lda   SRT_SGNA
            bne   :alt2                 ;A negative, B not
            bra   :agt2
:same       ;-- same sign: longer magnitude is bigger
            lda   SRT_NLA+1
            cmp   SRT_NLB+1
            bne   :bylen
            lda   SRT_NLA
            cmp   SRT_NLB
            bne   :bylen
            ;-- equal length: digit strings decide
:dig        lda   SRT_NLA
            ora   SRT_NLA+1
            beq   :eq
            lda   (SRT_KA)
            cmp   (SRT_KB)
            bcc   :less
            bne   :more
            inc   SRT_KA
            bne   :ncb
            inc   SRT_KA+1
:ncb        inc   SRT_KB
            bne   :ncc
            inc   SRT_KB+1
:ncc        lda   SRT_NLA
            bne   :ncd
            dec   SRT_NLA+1
:ncd        dec   SRT_NLA
            bra   :dig
:eq         lda   #0
            rts
:bylen      bcc   :less                 ;carry from the len cmp
            bra   :more
:less       lda   SRT_SGNA              ;smaller magnitude --
            bne   :agt2                 ;or bigger NEGATIVE
:alt2       lda   #$FF
            rts
:more       lda   SRT_SGNA
            bne   :alt2
:agt2       lda   #1
            rts

*-- NPREPA/NPREPB -- position SRT_KA/SRT_KB at the first
*-- significant digit; set SRT_SGNA/SGNB and the 16-bit
*-- SRT_NLA/NLB significant-digit counts. The scan walks a
*-- probe ahead in SRT_KAE/KBE to count without losing the
*-- start.
NPREPA      jsr   SKIPBL
            stz   SRT_SGNA
            lda   (SRT_KA)
            tax
            and   #$7F
            cmp   #'-'
            bne   :nosgn
            lda   #1
            sta   SRT_SGNA
            inc   SRT_KA
            bne   :nosgn
            inc   SRT_KA+1
:nosgn      ;-- strip leading zeros
:zeros      lda   (SRT_KA)
            and   #$7F
            cmp   #'0'
            bne   :count
            inc   SRT_KA
            bne   :zeros
            inc   SRT_KA+1
            bra   :zeros
:count      stz   SRT_NLA
            stz   SRT_NLA+1
            lda   SRT_KA
            sta   SRT_KAE
            lda   SRT_KA+1
            sta   SRT_KAE+1
:clp        lda   (SRT_KAE)
            jsr   ISDIGIT
            bcc   :done
            inc   SRT_NLA
            bne   :ncl
            inc   SRT_NLA+1
:ncl        inc   SRT_KAE
            bne   :clp
            inc   SRT_KAE+1
            bra   :clp
:done       rts

NPREPB      ;-- same walk on the B cells. Duplicated rather
            ;-- than indirected: parameterizing zp pairs on a
            ;-- 6502 costs more bytes than the second copy.
            lda   SRT_KB
            sta   SRT_KA
            lda   SRT_KB+1
            sta   SRT_KA+1
            jsr   SKIPBL
            stz   SRT_SGNB
            lda   (SRT_KA)
            and   #$7F
            cmp   #'-'
            bne   :nosgn
            lda   #1
            sta   SRT_SGNB
            inc   SRT_KA
            bne   :nosgn
            inc   SRT_KA+1
:nosgn
:zeros      lda   (SRT_KA)
            and   #$7F
            cmp   #'0'
            bne   :count
            inc   SRT_KA
            bne   :zeros
            inc   SRT_KA+1
            bra   :zeros
:count      lda   SRT_KA              ;B's digits start here
            sta   SRT_KB              ;and STAY here: the count
            sta   SRT_KBE             ;walks the KBE probe not
            lda   SRT_KA+1              ;SRT_KB itself (NPREPA's
            sta   SRT_KB+1              ;shape; the first cut
            sta   SRT_KBE+1             ;walked KB and compared
            stz   SRT_NLB               ;from the digits' END)
            stz   SRT_NLB+1
:clp        lda   (SRT_KBE)
            jsr   ISDIGIT
            bcc   :done
            inc   SRT_NLB
            bne   :ncl
            inc   SRT_NLB+1
:ncl        inc   SRT_KBE
            bne   :clp
            inc   SRT_KBE+1
            bra   :clp
:done       rts

*-- ISDIGIT -- carry set if A is '0'-'9' (either convention).
*-- Preserves A.
ISDIGIT     tax
            and   #$7F
            cmp   #'0'
            bcc   :no
            cmp   #'9'+1
            bcs   :no
            txa
            sec
            rts
:no         txa
            clc
            rts
