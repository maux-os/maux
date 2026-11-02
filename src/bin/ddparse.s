*---------------------------------------------------------------
* ddparse.s -- dd's front half: START, the key=value operand
* scan (PARSELOOP/KEY_*/PARSENEXT), decimal parsing (PARSENUM/
* PMUL10), prefix matching (PFXCMP/ADDVOFF), and PARSEDONE's
* validation + if=/of= opens + skip=/seek= application. Split
* from dd.s 2026-09-07 at a GLOBAL boundary for the as source
* window (S9-PLAN sec 6, check_dialect's 16128-byte budget):
* dd.s's own stripped text was 20,992 bytes, over the window by
* itself. One assembly stream, put by dd.s immediately after
* the liba equ puts; every rule in dd.s's own header (branch-
* range guards included) applies unchanged.
*---------------------------------------------------------------
*---------------------------------------------------------------
* START -- set up the constant parmlist fields and the option
* defaults, then either skip straight to PARSEDONE (no operands
* at all -- valid, every default applies) or scan argv[1..].
*---------------------------------------------------------------
START       lda   #PCOUNT_OPEN
            sta   OPARM
            lda   #<PATHBUF
            sta   OPARM_PATH
            lda   #>PATHBUF
            sta   OPARM_PATH+1
            stz   OPARM_IOBUF
            stz   OPARM_IOBUF+1
            lda   #PCOUNT_READ
            sta   RPARM
            lda   #<CBUF
            sta   RPARM_BUF
            lda   #>CBUF
            sta   RPARM_BUF+1
            lda   #PCOUNT_WRITE
            sta   WPARM
            lda   #PCOUNT_CLOSE
            sta   CPARM
            lda   #<DEFBS
            sta   BSVAL
            lda   #>DEFBS
            sta   BSVAL+1
            stz   HAVE_COUNT
            stz   SKIPVAL
            stz   SKIPVAL+1
            stz   SEEKVAL
            stz   SEEKVAL+1
            stz   NOTRUNC
            stz   IFPTR
            stz   IFPTR+1
            stz   OFPTR
            stz   OFPTR+1
            stz   BLKDONE
            stz   BLKDONE+1
            stz   IN_FULL
            stz   IN_FULL+1
            stz   IN_PART
            stz   IN_PART+1
            stz   OUT_FULL
            stz   OUT_FULL+1
            stz   OUT_PART
            stz   OUT_PART+1
            lda   ARGC
            cmp   #1
            bne   :haveop
            jmp   PARSEDONE
:haveop     lda   #1
            sta   ARGIDX
            jmp   PARSELOOP

*---------------------------------------------------------------
* PARSELOOP -- one argv[] operand per pass. Try each key prefix
* in turn (PFXCMP); the first match dispatches to its KEY_*
* handler, which stores the value and jumps to PARSENEXT. No
* prefix matching at all is the unknown-key usage error.
*---------------------------------------------------------------
PARSELOOP   lda   ARGIDX
            jsr   GETARG
            lda   #<PFX_IF
            sta   PTR1
            lda   #>PFX_IF
            sta   PTR1+1
            jsr   PFXCMP
            bcs   :try_of
            jmp   KEY_IF
:try_of     lda   #<PFX_OF
            sta   PTR1
            lda   #>PFX_OF
            sta   PTR1+1
            jsr   PFXCMP
            bcs   :try_bs
            jmp   KEY_OF
:try_bs     lda   #<PFX_BS
            sta   PTR1
            lda   #>PFX_BS
            sta   PTR1+1
            jsr   PFXCMP
            bcs   :try_cnt
            jmp   KEY_BS
:try_cnt    lda   #<PFX_CNT
            sta   PTR1
            lda   #>PFX_CNT
            sta   PTR1+1
            jsr   PFXCMP
            bcs   :try_skip
            jmp   KEY_CNT
:try_skip   lda   #<PFX_SKIP
            sta   PTR1
            lda   #>PFX_SKIP
            sta   PTR1+1
            jsr   PFXCMP
            bcs   :try_seek
            jmp   KEY_SKIP
:try_seek   lda   #<PFX_SEEK
            sta   PTR1
            lda   #>PFX_SEEK
            sta   PTR1+1
            jsr   PFXCMP
            bcs   :try_cnv
            jmp   KEY_SEEK
:try_cnv    lda   #<PFX_CNV
            sta   PTR1
            lda   #>PFX_CNV
            sta   PTR1+1
            jsr   PFXCMP
            bcs   :unknown
            jmp   KEY_CNV
:unknown    jsr   USAGEERR

KEY_IF      jsr   ADDVOFF
            lda   PTR0
            sta   IFPTR
            lda   PTR0+1
            sta   IFPTR+1
            jmp   PARSENEXT

KEY_OF      jsr   ADDVOFF
            lda   PTR0
            sta   OFPTR
            lda   PTR0+1
            sta   OFPTR+1
            jmp   PARSENEXT

KEY_BS      jsr   PARSENUM
            bcc   :bs_good
            jsr   USAGEERR
:bs_good    lda   PARSE_VAL
            sta   BSVAL
            lda   PARSE_VAL+1
            sta   BSVAL+1
            jmp   PARSENEXT

KEY_CNT     jsr   PARSENUM
            bcc   :cnt_good
            jsr   USAGEERR
:cnt_good   lda   PARSE_VAL
            sta   COUNTVAL
            lda   PARSE_VAL+1
            sta   COUNTVAL+1
            lda   #1
            sta   HAVE_COUNT
            jmp   PARSENEXT

KEY_SKIP    jsr   PARSENUM
            bcc   :sk_good
            jsr   USAGEERR
:sk_good    lda   PARSE_VAL
            sta   SKIPVAL
            lda   PARSE_VAL+1
            sta   SKIPVAL+1
            jmp   PARSENEXT

KEY_SEEK    jsr   PARSENUM
            bcc   :se_good
            jsr   USAGEERR
:se_good    lda   PARSE_VAL
            sta   SEEKVAL
            lda   PARSE_VAL+1
            sta   SEEKVAL+1
            jmp   PARSENEXT

KEY_CNV     jsr   ADDVOFF
            lda   #<NOTRUNCST
            sta   PTR1
            lda   #>NOTRUNCST
            sta   PTR1+1
            jsr   STRCMP
            cmp   #0
            beq   :cnv_good
            jsr   USAGEERR
:cnv_good   lda   #1
            sta   NOTRUNC
            jmp   PARSENEXT

PARSENEXT   lda   ARGIDX
            clc
            adc   #1
            sta   ARGIDX
            cmp   ARGC
            bcc   :ploop2
            jmp   PARSEDONE
:ploop2     jmp   PARSELOOP

*---------------------------------------------------------------
* PARSEDONE -- validate bs=/skip=/seek=, open if=/of= (or take
* the stdin/stdout default), apply skip/seek, then run the copy.
*---------------------------------------------------------------
PARSEDONE   lda   BSVAL
            ora   BSVAL+1
            bne   :bs_ck2
            jsr   USAGEERR
:bs_ck2     lda   BSVAL+1
            cmp   #$10
            bcc   :bs_ok
            beq   :bs_ck3
            jsr   USAGEERR
:bs_ck3     lda   BSVAL
            beq   :bs_ok
            jsr   USAGEERR
:bs_ok      lda   SKIPVAL
            ora   SKIPVAL+1
            beq   :sk_ok
            lda   IFPTR
            ora   IFPTR+1
            bne   :sk_ok
            jsr   CANTSKIP
:sk_ok      lda   SEEKVAL
            ora   SEEKVAL+1
            beq   :sk_ok2
            lda   OFPTR
            ora   OFPTR+1
            bne   :sk_ok2
            jsr   CANTSEEK
:sk_ok2     lda   IFPTR
            ora   IFPTR+1
            bne   :if_real
            jmp   IN_STDIN
:if_real    lda   IFPTR
            sta   PTR0
            lda   IFPTR+1
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :if_ok
            lda   IFPTR
            sta   ERRPATH
            lda   IFPTR+1
            sta   ERRPATH+1
            lda   #<OPNSFX
            sta   ERRSFX
            lda   #>OPNSFX
            sta   ERRSFX+1
            jsr   REPORTERR2
:if_ok      lda   OPARM_REF
            sta   INFD
            jmp   IN_SEEK
IN_STDIN    lda   #FD_STDIN
            sta   INFD
IN_SEEK     lda   SKIPVAL
            ora   SKIPVAL+1
            bne   :do_skip
            jmp   OUT_START
:do_skip    lda   SKIPVAL
            sta   OFF_BLK
            lda   SKIPVAL+1
            sta   OFF_BLK+1
            jsr   MULOFF
            lda   OFHI
            beq   :sk_szok
            jsr   OFFOVER
:sk_szok    lda   #<OFFBUF
            sta   PTR0
            lda   #>OFFBUF
            sta   PTR0+1
            lda   INFD
            ldy   #SEEK_SET
            jsr   LSEEK
            bcc   :sk_lsok
            jsr   SEEKFAIL
:sk_lsok    jmp   OUT_START

OUT_START   lda   OFPTR
            ora   OFPTR+1
            bne   :of_real
            jmp   OUT_STDOUT
:of_real    lda   OFPTR
            sta   PTR0
            lda   OFPTR+1
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   NOTRUNC
            bne   OUT_NOTRNC
            lda   #<DPARM
            ldx   #>DPARM
            jsr   SC_UNLINK
            lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT
            bcc   :cr_ok
            lda   OFPTR
            sta   ERRPATH
            lda   OFPTR+1
            sta   ERRPATH+1
            lda   #<CRTSFX
            sta   ERRSFX
            lda   #>CRTSFX
            sta   ERRSFX+1
            jsr   REPORTERR2
:cr_ok      lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :cr_ok2
            lda   OFPTR
            sta   ERRPATH
            lda   OFPTR+1
            sta   ERRPATH+1
            lda   #<CRTSFX
            sta   ERRSFX
            lda   #>CRTSFX
            sta   ERRSFX+1
            jsr   REPORTERR2
:cr_ok2     lda   OPARM_REF
            sta   OUTFD
            jmp   OUT_SEEK
OUT_NOTRNC  lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :nt_ok
            lda   OFPTR
            sta   ERRPATH
            lda   OFPTR+1
            sta   ERRPATH+1
            lda   #<OPNSFX
            sta   ERRSFX
            lda   #>OPNSFX
            sta   ERRSFX+1
            jsr   REPORTERR2
:nt_ok      lda   OPARM_REF
            sta   OUTFD
            jmp   OUT_SEEK
OUT_STDOUT  lda   #FD_STDOUT
            sta   OUTFD
OUT_SEEK    lda   SEEKVAL
            ora   SEEKVAL+1
            bne   :do_seek
            jmp   PREPCOPY
:do_seek    lda   SEEKVAL
            sta   OFF_BLK
            lda   SEEKVAL+1
            sta   OFF_BLK+1
            jsr   MULOFF
            lda   OFHI
            beq   :se_szok
            jsr   OFFOVER
:se_szok    lda   #<OFFBUF
            sta   PTR0
            lda   #>OFFBUF
            sta   PTR0+1
            lda   OUTFD
            ldy   #SEEK_SET
            jsr   LSEEK
            bcc   :se_lsok
            jsr   SEEKFAIL
:se_lsok    jmp   PREPCOPY
