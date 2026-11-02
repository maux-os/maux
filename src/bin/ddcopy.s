*---------------------------------------------------------------
* ddcopy.s -- dd's back half: the copy proper (PREPCOPY/CPYLOOP/
* DOREAD/DD_WRTALL/BUMPCNT), REPORT, MULOFF (the skip=/seek=
* offset multiply), the fatal-error helpers (ERRPUT/REPORTERR2/
* USAGEERR/WRITEERR/OFFOVER/SEEKFAIL/CANTSKIP/CANTSEEK), every
* message string, and the emitted CRPARM/DPARM parmlists. Split
* from dd.s 2026-09-07, put immediately after ddparse.s -- see
* that file's header for why. One assembly stream; every rule
* in dd.s's own header applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PREPCOPY/CPYLOOP/DOREAD -- the copy proper. RPARM_REQ is set
* ONCE here (bs is fixed for the whole run); WPARM_BUF/WPARM_REQ
* are set fresh each record from what was actually read
* (RPARM_TRANS), cat.s's own WRITE_ALL discipline. count= (if
* given) is checked before each read; EOF (read error OR
* trans_count==0, cat.s's own v1 rule) or the count reaching its
* limit both fall into REPORT.
*---------------------------------------------------------------
PREPCOPY    lda   BSVAL
            sta   RPARM_REQ
            lda   BSVAL+1
            sta   RPARM_REQ+1
            lda   INFD
            sta   RPARM_REF
            lda   OUTFD
            sta   WPARM_REF
CPYLOOP     lda   HAVE_COUNT
            beq   DOREAD
            lda   BLKDONE+1
            cmp   COUNTVAL+1
            bcc   DOREAD
            bne   :cp_rep
            lda   BLKDONE
            cmp   COUNTVAL
            bcc   DOREAD
:cp_rep     jsr   REPORT
DOREAD      lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcc   :rd_ok
            jsr   REPORT
:rd_ok      lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            bne   :rd_ok2
            jsr   REPORT
:rd_ok2     lda   RPARM_TRANS
            sta   WPARM_REQ
            lda   RPARM_TRANS+1
            sta   WPARM_REQ+1
            lda   #<CBUF
            sta   WPARM_BUF
            lda   #>CBUF
            sta   WPARM_BUF+1
            jsr   DD_WRTALL
            jsr   BUMPCNT
            inc   BLKDONE
            bne   :bd_ok
            inc   BLKDONE+1
:bd_ok      jmp   CPYLOOP

*---------------------------------------------------------------
* REPORT -- close whichever of if=/of= were real files (stdin/
* stdout are never closed), print the "N+N records in"/"out"
* pair to stderr, EXIT 0. Reached only via `jsr` (see file
* header on branch range), so it never needs to RTS.
*---------------------------------------------------------------
REPORT      lda   IFPTR
            ora   IFPTR+1
            beq   :rp_noin
            lda   #PCOUNT_CLOSE
            sta   CPARM
            lda   INFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
:rp_noin    lda   OFPTR
            ora   OFPTR+1
            beq   :rp_noout
            lda   #PCOUNT_CLOSE
            sta   CPARM
            lda   OUTFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
:rp_noout   lda   IN_FULL
            sta   U2DEC_VAL
            lda   IN_FULL+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDERR
            jsr   PRNUM
            lda   #<PLUSSTR
            sta   PTR0
            lda   #>PLUSSTR
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   IN_PART
            sta   U2DEC_VAL
            lda   IN_PART+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDERR
            jsr   PRNUM
            lda   #<INSTR
            sta   PTR0
            lda   #>INSTR
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   OUT_FULL
            sta   U2DEC_VAL
            lda   OUT_FULL+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDERR
            jsr   PRNUM
            lda   #<PLUSSTR
            sta   PTR0
            lda   #>PLUSSTR
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   OUT_PART
            sta   U2DEC_VAL
            lda   OUT_PART+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDERR
            jsr   PRNUM
            lda   #<OUTSTR
            sta   PTR0
            lda   #>OUTSTR
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* DD_WRTALL -- cat.s's WRITE_ALL, widened to a runtime WPARM_REQ
* and made FATAL on error (spec: "write error" -> EXIT 1, not a
* silent stop). WPARM_BUF/WPARM_REQ are the caller's for this
* record; both advance here exactly like cat.s's own loop.
*---------------------------------------------------------------
DD_WRTALL   lda   WPARM_REQ
            ora   WPARM_REQ+1
            bne   :wa_go
            rts
:wa_go      lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            bcc   :wa_ok
            jsr   WRITEERR
:wa_ok      lda   WPARM_TRANS
            ora   WPARM_TRANS+1
            bne   :wa_ok2
            jsr   WRITEERR
:wa_ok2     sec
            lda   WPARM_REQ
            sbc   WPARM_TRANS
            sta   WPARM_REQ
            lda   WPARM_REQ+1
            sbc   WPARM_TRANS+1
            sta   WPARM_REQ+1
            clc
            lda   WPARM_BUF
            adc   WPARM_TRANS
            sta   WPARM_BUF
            lda   WPARM_BUF+1
            adc   WPARM_TRANS+1
            sta   WPARM_BUF+1
            jmp   DD_WRTALL

*---------------------------------------------------------------
* BUMPCNT -- this record's trans_count vs BSVAL decides full or
* partial; a completed DD_WRTALL (it would have EXITed on error
* otherwise) always writes exactly trans_count bytes, so IN_*
* and OUT_* take the SAME test -- v1 has no partial-write path
* that survives to be counted differently from the read.
*---------------------------------------------------------------
BUMPCNT     lda   RPARM_TRANS
            cmp   BSVAL
            bne   :bpart
            lda   RPARM_TRANS+1
            cmp   BSVAL+1
            bne   :bpart
            inc   IN_FULL
            bne   :bf1
            inc   IN_FULL+1
:bf1        inc   OUT_FULL
            bne   :bf2
            inc   OUT_FULL+1
:bf2        rts
:bpart      inc   IN_PART
            bne   :bp1
            inc   IN_PART+1
:bp1        inc   OUT_PART
            bne   :bp2
            inc   OUT_PART+1
:bp2        rts

*---------------------------------------------------------------
* PFXCMP -- does (PTR1) (a NUL-terminated prefix) match the
* start of (PTR0) (the current argv string)? OUT: carry clear
* and Y = the prefix's length (the value's start offset in
* PTR0) on a match; carry set, Y undefined, on no match.
* CLOBBERS: A, Y. PRESERVES: X, PTR0, PTR1.
*---------------------------------------------------------------
PFXCMP      ldy   #0
:pf_loop    lda   (PTR1),y
            beq   :pf_match
            cmp   (PTR0),y
            bne   :pf_nomat
            iny
            bra   :pf_loop
:pf_match   clc
            rts
:pf_nomat   sec
            rts

*---------------------------------------------------------------
* ADDVOFF -- PTR0 += Y (16-bit-safe 8-bit add), in place. Turns
* a PFXCMP match's Y-offset into a real pointer at the value
* substring, for if=/of=/conv='s consumers. CLOBBERS: A.
*---------------------------------------------------------------
ADDVOFF     tya
            clc
            adc   PTR0
            pha
            lda   PTR0+1
            adc   #0
            sta   PTR0+1
            pla
            sta   PTR0
            rts

*---------------------------------------------------------------
* PARSENUM -- decimal-digits-only ASCII (high-bit-set, liba
* convention) to 16-bit binary. IN: PTR0 = string, Y = offset of
* the first value char (from PFXCMP). OUT: carry clear, PARSE_
* VAL = value; carry set = malformed (a non-digit, or no digits
* at all -- an empty value is malformed too). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PARSENUM    stz   PARSE_VAL
            stz   PARSE_VAL+1
            ldx   #0
:pn_loop    lda   (PTR0),y
            beq   :pn_end
            cmp   #$B0
            bcc   :pn_bad
            cmp   #$BA
            bcs   :pn_bad
            and   #$0F
            pha
            jsr   PMUL10
            pla
            clc
            adc   PARSE_VAL
            sta   PARSE_VAL
            bcc   :pn_nc
            inc   PARSE_VAL+1
:pn_nc      inx
            iny
            bra   :pn_loop
:pn_end     cpx   #0
            beq   :pn_bad
            clc
            rts
:pn_bad     sec
            rts

*---------------------------------------------------------------
* PMUL10 -- PARSE_VAL *= 10, in place (v*10 = v*8 + v*2; no
* multiply instruction on 6502/65C02). CLOBBERS: A.
*---------------------------------------------------------------
PMUL10      lda   PARSE_VAL
            sta   TENTMP
            lda   PARSE_VAL+1
            sta   TENTMP+1
            asl   PARSE_VAL
            rol   PARSE_VAL+1
            asl   PARSE_VAL
            rol   PARSE_VAL+1
            asl   PARSE_VAL
            rol   PARSE_VAL+1
            asl   TENTMP
            rol   TENTMP+1
            clc
            lda   PARSE_VAL
            adc   TENTMP
            sta   PARSE_VAL
            lda   PARSE_VAL+1
            adc   TENTMP+1
            sta   PARSE_VAL+1
            rts

*---------------------------------------------------------------
* MULOFF -- OFFBUF(3)/OFHI(1) = OFF_BLK * BSVAL, a 16x16->32
* shift-add multiply (schoolbook doubling: walk OFF_BLK's bits
* LSB first: bit set -> add the current doubled multiplicand
* into the 32-bit accumulator; double the multiplicand every
* iteration regardless). OFFBUF is little-endian and IS the
* LSEEK offset buffer directly -- no separate copy step. OFHI
* nonzero after the call means the product doesn't fit ProDOS's
* 24-bit mark (the caller's overflow check). Destroys OFF_BLK.
* CLOBBERS: A, X.
*---------------------------------------------------------------
MULOFF      stz   OFFBUF
            stz   OFFBUF+1
            stz   OFFBUF+2
            stz   OFHI
            lda   BSVAL
            sta   OMCND0
            lda   BSVAL+1
            sta   OMCND1
            stz   OMCND2
            stz   OMCND3
            ldx   #16
:mo_loop    lsr   OFF_BLK+1
            ror   OFF_BLK
            bcc   :mo_nadd
            clc
            lda   OFFBUF
            adc   OMCND0
            sta   OFFBUF
            lda   OFFBUF+1
            adc   OMCND1
            sta   OFFBUF+1
            lda   OFFBUF+2
            adc   OMCND2
            sta   OFFBUF+2
            lda   OFHI
            adc   OMCND3
            sta   OFHI
:mo_nadd    asl   OMCND0
            rol   OMCND1
            rol   OMCND2
            rol   OMCND3
            dex
            bne   :mo_loop
            rts

*---------------------------------------------------------------
* ERRPUT -- PUTS(PTR0) to stderr, then return (the non-EXITing
* half of the error helpers below). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
ERRPUT      ldx   #FD_STDERR
            jsr   PUTS
            rts

*---------------------------------------------------------------
* REPORTERR2 -- "dd: " + (ERRPATH, a liba string ptr) + (ERRSFX,
* a liba string ptr, CR baked in) to stderr, then EXIT 1. Shared
* by every if=/of= open/create failure -- only ERRPATH/ERRSFX
* differ per call site. Does not return.
*---------------------------------------------------------------
REPORTERR2  lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            jsr   ERRPUT
            lda   ERRPATH
            sta   PTR0
            lda   ERRPATH+1
            sta   PTR0+1
            jsr   ERRPUT
            lda   ERRSFX
            sta   PTR0
            lda   ERRSFX+1
            sta   PTR0+1
            jsr   ERRPUT
            lda   #1
            jsr   EXIT

* -- the fixed-message error exits: print, then EXIT. None
* -- return -- SC_EXIT's own defensive hang covers a kernel that
* -- somehow comes back anyway (see syscalls.s).
USAGEERR    lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            jsr   ERRPUT
            lda   #2
            jsr   EXIT

WRITEERR    lda   #<WERRMSG
            sta   PTR0
            lda   #>WERRMSG
            sta   PTR0+1
            jsr   ERRPUT
            lda   #1
            jsr   EXIT

OFFOVER     lda   #<OFLGMSG
            sta   PTR0
            lda   #>OFLGMSG
            sta   PTR0+1
            jsr   ERRPUT
            lda   #1
            jsr   EXIT

SEEKFAIL    lda   #<SEEKMSG
            sta   PTR0
            lda   #>SEEKMSG
            sta   PTR0+1
            jsr   ERRPUT
            lda   #1
            jsr   EXIT

CANTSKIP    lda   #<SKIPMSG
            sta   PTR0
            lda   #>SKIPMSG
            sta   PTR0+1
            jsr   ERRPUT
            lda   #1
            jsr   EXIT

CANTSEEK    lda   #<SEKOMSG
            sta   PTR0
            lda   #>SEKOMSG
            sta   PTR0+1
            jsr   ERRPUT
            lda   #1
            jsr   EXIT

* -- messages --
USAGEMSG    asc   "usage: dd [if=F] [of=F] [bs=N] [count=N] "
            asc   "[skip=N] [seek=N] [conv=notrunc]"
            dfb   $8D,0
SKIPMSG     asc   "dd: cannot skip stdin"
            dfb   $8D,0
SEKOMSG     asc   "dd: cannot seek stdout"
            dfb   $8D,0
WERRMSG     asc   "dd: write error"
            dfb   $8D,0
OFLGMSG     asc   "dd: offset too large"
            dfb   $8D,0
SEEKMSG     asc   "dd: seek failed"
            dfb   $8D,0
ERRPFX      asc   "dd: "
            dfb   0
OPNSFX      asc   ": cannot open"
            dfb   $8D,0
CRTSFX      asc   ": cannot create"
            dfb   $8D,0
PLUSSTR     asc   "+"
            dfb   0
INSTR       asc   " records in"
            dfb   0
OUTSTR      asc   " records out"
            dfb   0
NOTRUNCST   asc   "notrunc"
            dfb   0
PFX_IF      asc   "if="
            dfb   0
PFX_OF      asc   "of="
            dfb   0
PFX_BS      asc   "bs="
            dfb   0
PFX_CNT     asc   "count="
            dfb   0
PFX_SKIP    asc   "skip="
            dfb   0
PFX_SEEK    asc   "seek="
            dfb   0
PFX_CNV     asc   "conv="
            dfb   0

* -- CREATE ($C0), PCOUNT_CREATE-shaped (mli.equ) -- touch.s's
* -- CRPARM style. Always a BIN seedling, unlocked, aux 0, and
* -- (spec) cdate/ctime 0 -- dd stamps no clock, unlike touch.
CRPARM      dfb   PCOUNT_CREATE
CRPARM_PATH da    PATHBUF
CRPARM_ACC  dfb   ACCESS_UNLKD
CRPARM_TYPE dfb   FTYPE_BIN
CRPARM_AUX  da    0
CRPARM_STORE dfb  STYP_SEEDLING
CRPARM_CDATE da   0
CRPARM_CTIME da   0

* -- DESTROY ($C1), PCNT_DESTROY-shaped -- rm.s's DPARM style.
* -- Its carry is IGNORED entirely at the one call site (spec:
* -- fresh of= unlinks first, tolerating "wasn't there").
DPARM       dfb   PCNT_DESTROY
DPARM_PATH  da    PATHBUF
