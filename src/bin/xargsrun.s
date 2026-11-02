*---------------------------------------------------------------
* xargsrun.s -- xargs's invocation engine: CALCBUDGET, TOOLONG,
* RUN_NMODE/BUILD_BATCH/BB_NEED/BUILD_ARGV_N (n-mode batching),
* RUN_IMODE (-I mode), INVOKE and TRACEPRINT (-t). `put` out of
* xargs.s for the native assembler's 16,128-byte source window
* -- xargs.s's own resident text alone (15,746B, before this
* split) left under 400B of headroom before even counting a put
* file, so this moves mainline CODE, not more tokenizer text.
* Every symbol here resolves against xargs.s's own equates,
* data and zero page; see that file's header for the shapes.
*---------------------------------------------------------------
*---------------------------------------------------------------
* CALCBUDGET -- FIXEDBYTES/REMBYTES/REMSLOTS/EFFSIZE/EFFCNT
* from ORIGWORD/FIXEDBASE/FIXEDCNT and the -n/-s flags. Exits
* the program if the fixed words alone leave no budget at all.
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
CALCBUDGET
            lda   ORIGWORD
            sta   PTR0
            lda   ORIGWORD+1
            sta   PTR0+1
            jsr   STRLEN
            inc   a
            bne   :fb1
            inx
:fb1        sta   FIXEDBYTES
            stx   FIXEDBYTES+1
            stz   CB_I
:floop      lda   CB_I
            cmp   FIXEDCNT
            bcs   :fdone
            clc
            adc   FIXEDBASE
            jsr   GETARG
            jsr   STRLEN
            inc   a
            bne   :fb2
            inx
:fb2        clc
            adc   FIXEDBYTES
            sta   FIXEDBYTES
            txa
            adc   FIXEDBYTES+1
            sta   FIXEDBYTES+1
            inc   CB_I
            bra   :floop
:fdone      lda   #<ARG_MAX
            sec
            sbc   FIXEDBYTES
            sta   REMBYTES
            lda   #>ARG_MAX
            sbc   FIXEDBYTES+1
            sta   REMBYTES+1
            bcs   :chkslots
            jmp   TOOLONG
:chkslots   lda   FIXEDCNT
            clc
            adc   #1
            cmp   #MAXSLOTN
            bcc   :sok
            jmp   TOOLONG
:sok        lda   #MAXSLOTN
            sec
            sbc   FIXEDCNT
            sec
            sbc   #1
            sta   REMSLOTS

            lda   SFLAG
            beq   :defsize
            lda   SIZEVAL+1
            cmp   REMBYTES+1
            bcc   :usesz
            bne   :usebyte
            lda   SIZEVAL
            cmp   REMBYTES
            bcc   :usesz
:usebyte    lda   REMBYTES
            sta   EFFSIZE
            lda   REMBYTES+1
            sta   EFFSIZE+1
            bra   :sizedone
:usesz      lda   SIZEVAL
            sta   EFFSIZE
            lda   SIZEVAL+1
            sta   EFFSIZE+1
            bra   :sizedone
:defsize    lda   REMBYTES
            sta   EFFSIZE
            lda   REMBYTES+1
            sta   EFFSIZE+1
:sizedone   lda   NFLAG
            beq   :defcnt
            lda   COUNTVAL+1
            bne   :usecnt2
            lda   COUNTVAL
            cmp   REMSLOTS
            bcc   :usecnt1
:usecnt2    lda   REMSLOTS
            sta   EFFCNT
            bra   :cntdone
:usecnt1    lda   COUNTVAL
            sta   EFFCNT
            bra   :cntdone
:defcnt     lda   REMSLOTS
            sta   EFFCNT
:cntdone    rts

*---------------------------------------------------------------
* TOOLONG -- "xargs: argument list too long", exit 1. Never
* returns.
*---------------------------------------------------------------
TOOLONG     lda   #<TOOLONGMSG
            sta   PTR0
            lda   #>TOOLONGMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

*---------------------------------------------------------------
* RUN_NMODE -- the blank/newline/quote-split batch loop. Exits
* via INVOKE on a fatal child status; otherwise returns once
* stdin is exhausted and every batch has run.
*---------------------------------------------------------------
RUN_NMODE   jsr   BUILD_BATCH
            lda   BATCHCNT
            beq   :done
            jsr   BUILD_ARGV_N
            jsr   INVOKE
            jmp   RUN_NMODE
:done       rts

*---------------------------------------------------------------
* BUILD_BATCH -- fills BATCHPTRS[0..BATCHCNT-1] (pointers into
* INPUT_BUF) up to EFFSIZE bytes / EFFCNT entries. The very
* first entry of a batch is taken regardless of size (forward-
* progress rule in the header). CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
BUILD_BATCH stz   BATCHCNT
            lda   #<INPUT_BUF
            sta   IB_CUR
            lda   #>INPUT_BUF
            sta   IB_CUR+1
            stz   BB_BYTES
            stz   BB_BYTES+1
            stz   BB_LINES
            stz   BB_LINES+1
:loop       jsr   FILLPEND
            bcc   :havetok
            jmp   :stop
:havetok    lda   BATCHCNT
            beq   :take
            lda   BATCHCNT
            cmp   EFFCNT
            bcc   :chksize
            jmp   :stop
:chksize    jsr   BB_NEED
            clc
            lda   BB_TMP
            adc   BB_BYTES
            sta   BB_TMP
            lda   BB_TMP+1
            adc   BB_BYTES+1
            sta   BB_TMP+1
            lda   BB_TMP+1
            cmp   EFFSIZE+1
            bcc   :take
            beq   :chklo
            jmp   :stop
:chklo      lda   BB_TMP
            cmp   EFFSIZE
            bcc   :take
            beq   :take
            jmp   :stop
:take       ldx   BATCHCNT
            txa
            asl   a
            tay
            lda   IB_CUR
            sta   BATCHPTRS,y
            lda   IB_CUR+1
            sta   BATCHPTRS+1,y
            ldy   #0
:cpy        lda   PENDBUF,y
            sta   (IB_CUR),y
            beq   :cpydone
            iny
            bra   :cpy
:cpydone    jsr   BB_NEED
            clc
            lda   IB_CUR
            adc   BB_TMP
            sta   IB_CUR
            lda   IB_CUR+1
            adc   BB_TMP+1
            sta   IB_CUR+1
            clc
            lda   BB_BYTES
            adc   BB_TMP
            sta   BB_BYTES
            lda   BB_BYTES+1
            adc   BB_TMP+1
            sta   BB_BYTES+1
            inc   BATCHCNT
            stz   PENDVALID
*-- -L counts LINES, not arguments, so the count advances only
*-- on a token the tokenizer marked as ending one. The check is
*-- AFTER taking the token, never before: POSIX's -L is "at most
*-- number lines", and a batch that stopped before taking the
*-- token that completes its last line would run one line short
*-- and leave the rest for an extra invocation.
            lda   LFLAG
            beq   :loopj
            lda   TOK_EOL
            beq   :loopj
            inc   BB_LINES
            bne   :lchk
            inc   BB_LINES+1
:lchk       lda   BB_LINES+1
            cmp   LVAL+1
            bcc   :loopj
            bne   :stop
            lda   BB_LINES
            cmp   LVAL
            bcs   :stop
:loopj      jmp   :loop
:stop       rts

*---------------------------------------------------------------
* BB_NEED -- OUT: BB_TMP/BB_TMP+1 = PENDLEN+1 (16-bit). Small
* helper so both BUILD_BATCH sites share it. CLOBBERS: A.
*---------------------------------------------------------------
BB_NEED     lda   PENDLEN
            clc
            adc   #1
            sta   BB_TMP
            lda   #0
            adc   #0
            sta   BB_TMP+1
            rts

*---------------------------------------------------------------
* BUILD_ARGV_N -- ARGVLIST := ORIGWORD, fixed args, batch args,
* NULL. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
BUILD_ARGV_N
            lda   ORIGWORD
            sta   ARGVLIST
            lda   ORIGWORD+1
            sta   ARGVLIST+1
            ldx   #2
            stz   BA_I
:floop      lda   BA_I
            cmp   FIXEDCNT
            bcs   :fdone
            clc
            adc   FIXEDBASE
            phx
            jsr   GETARG
            plx
            lda   PTR0
            sta   ARGVLIST,x
            lda   PTR0+1
            sta   ARGVLIST+1,x
            inx
            inx
            inc   BA_I
            bra   :floop
:fdone      stz   BA_I
:bloop      lda   BA_I
            cmp   BATCHCNT
            bcs   :bdone
            lda   BA_I
            asl   a
            tay
            lda   BATCHPTRS,y
            sta   ARGVLIST,x
            lda   BATCHPTRS+1,y
            sta   ARGVLIST+1,x
            inx
            inx
            inc   BA_I
            bra   :bloop
:bdone      stz   ARGVLIST,x
            inx
            stz   ARGVLIST,x
            rts

*---------------------------------------------------------------
* RUN_IMODE -- -I mode: one substituted invocation per nonblank
* input line. Exits via INVOKE on a fatal status; returns at
* EOF.
*---------------------------------------------------------------
RUN_IMODE   jsr   NEXTLINE
            bcs   :done
            lda   #<REPLBUF
            sta   REPLCUR
            lda   #>REPLBUF
            sta   REPLCUR+1
            lda   ORIGWORD
            sta   PTR0
            lda   ORIGWORD+1
            sta   PTR0+1
            jsr   SUBST_ONE
            sta   ARGVLIST
            stx   ARGVLIST+1
            ldx   #2
            stz   BA_I
:floop      lda   BA_I
            cmp   FIXEDCNT
            bcs   :fdone
            clc
            adc   FIXEDBASE
            phx
            jsr   GETARG
            jsr   SUBST_ONE
            sta   SO_RETLO
            stx   SO_RETHI
            plx
            lda   SO_RETLO
            sta   ARGVLIST,x
            lda   SO_RETHI
            sta   ARGVLIST+1,x
            inx
            inx
            inc   BA_I
            bra   :floop
:fdone      stz   ARGVLIST,x
            inx
            stz   ARGVLIST,x
            jsr   INVOKE
            jmp   RUN_IMODE
:done       rts

