*---------------------------------------------------------------
* cpcopyd.s -- cp's recursive-copy policy (COPYDIR/DIRERR).
* Further split 2026-09-01:
* window charges the MAIN plus its LARGEST put, so one big put
* is the same debt as inline text; smaller pieces are the only
* way down. One assembly stream, put in place; every
* manifest-header rule applies unchanged.
*---------------------------------------------------------------

*---------------------------------------------------------------
* COPYDIR -- `cp -r DIR DST`. Carry set on a real failure, with
* cptree's reason in CPT_ERR; the one refusal below prints for
* itself and exits, because it is not an errno.
*
* cp -r MERGES into an existing directory rather than refusing
* it -- `mv` demands an EMPTY one, and that is a genuine
* difference between the two tools, measured against /bin/cp and
* /bin/mv on 2026-08-25, not drift. CPT_MKDIR encodes it: a
* duplicate name that IS a directory is success.
*
* COPYING A DIRECTORY INTO ITSELF is refused. THE TWO HOSTS
* DISAGREE HERE and there is no single Unix answer to conform
* to: BSD `cp -r a a/b` exits 0 having copied one level (leaving
* a/b/a/b empty), GNU warns "cannot copy a directory into
* itself" and exits 1. maux takes GNU's answer, because on
* ProDOS the alternative is a walk descending into the
* destination it is still growing. Classified as a divergence
* with no single correct answer, the same shape as `ls`'s usage
* exit status (BSD 1, GNU 2).
*---------------------------------------------------------------
COPYDIR     lda   #<CPT_SRC
            sta   PTR1
            lda   #>CPT_SRC
            sta   PTR1+1
            lda   #<SPATHBUF
            ldx   #>SPATHBUF
            jsr   CPT_UNPATH
            sta   CPT_SLEN
            lda   #<CPT_DST
            sta   PTR1
            lda   #>CPT_DST
            sta   PTR1+1
            lda   #<DPATHBUF
            ldx   #>DPATHBUF
            jsr   CPT_UNPATH
            sta   CPT_DLEN
            lda   #<CPT_SRC
            sta   PTR0
            lda   #>CPT_SRC
            sta   PTR0+1
            lda   #<CPT_DST
            sta   PTR1
            lda   #>CPT_DST
            sta   PTR1+1
            jsr   CPT_ISDESC
            bcc   :go
            lda   #<SELFMSG
            sta   PTR0
            lda   #>SELFMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   PRINTED
            sec
            rts
:go         jsr   CPT_INIT
            jsr   CPT_MKDIR
            bcs   :fail
            jsr   CPT_START
:fail       rts

*---------------------------------------------------------------
* DIRERR -- report cptree's reason and exit 1. CPT_ERR holds
* either a real MLI errno -- always < $80 -- or one of cptree's
* two maux-side refusals, which take values no MLI call can
* return precisely so the two need no second flag.
*---------------------------------------------------------------
DIRERR      lda   PRINTED
            bne   :quiet
            lda   CPT_ERR
            cmp   #CPTE_LONG
            beq   :long
            cmp   #CPTE_DEEP
            beq   :deep
            lda   #<ERRMSG
            sta   PTR0
            lda   #>ERRMSG
            sta   PTR0+1
            bra   :say
:long       lda   #<TOOLONGM
            sta   PTR0
            lda   #>TOOLONGM
            sta   PTR0+1
            bra   :say
:deep       lda   #<DEEPMSG
            sta   PTR0
            lda   #>DEEPMSG
            sta   PTR0+1
:say        ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
:quiet      sec
            rts
