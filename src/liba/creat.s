*---------------------------------------------------------------
* creat.s -- V7 creat(2): make-or-truncate a file and return an
* fd open for writing. THE UNIX-LAYER RULE (sc.file.equ's
* "the kernel gains no Unix-shaped call"): Unix shapes live in
* liba over MLI-thin syscalls -- LSEEK (seek.s) is the standing
* precedent, and this is the same composition for V7's other
* fd-producing door. In V7 itself creat(2) IS a kernel call
* (open(2) grew O_CREAT only later); maux's ratified layering
* puts the same contract here instead.
*
* WHY IT EXISTS (docs/PERF-PLAN.md follow-on, 2026-08-29):
* ProDOS has no truncate-by-pathname, which is the only reason
* the UNLINK+CREATE+OPEN idiom ever existed -- but SET_EOF by
* open HANDLE truncates in place with no pathname walk at all.
* One full directory resolution saved per call (proving a
* target ABSENT walks the whole chain too), one fewer MLI
* call, and the surviving file keeps its identity -- which is
* what creat(2) does: it never re-inodes an existing file.
*
* IN:  PTR1 = MLI count-prefixed pathname.
* OUT: carry clear, A = fd (open, mark 0, EOF 0).
*      carry set,  A = errno -- the OPEN's, or the SET_EOF's
*      for a write-locked target, with the fd CLOSED first.
* Creates an unlocked TXT seedling; an EXISTING file of any
* type is truncated as-is ($47 from CREATE is the expected
* exists case, deliberately ignored -- a real path failure
* resurfaces at the OPEN, the rule sh's `>>` path has always
* used). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
CREAT       lda   PTR1
            sta   CR8_CPATH
            sta   CR8_OPATH
            lda   PTR1+1
            sta   CR8_CPATH+1
            sta   CR8_OPATH+1
            lda   #PCOUNT_CREATE
            sta   CR8_CPARM
            lda   #ACCESS_UNLKD
            sta   CR8_CACC
            lda   #FTYPE_TXT
            sta   CR8_CTYP
            stz   CR8_CAUX
            stz   CR8_CAUX+1
            lda   #STYP_SEEDLING
            sta   CR8_CSTY
            stz   CR8_CDAT
            stz   CR8_CDAT+1
            stz   CR8_CTIM
            stz   CR8_CTIM+1
            lda   #<CR8_CPARM
            ldx   #>CR8_CPARM
            jsr   SC_CREAT
            lda   #PCOUNT_OPEN
            sta   CR8_OPARM
            stz   CR8_OIOB
            stz   CR8_OIOB+1
            lda   #<CR8_OPARM
            ldx   #>CR8_OPARM
            jsr   SC_OPEN
            bcs   :fail
            lda   #2
            sta   CR8_SPARM
            lda   CR8_OREF
            sta   CR8_SREF
            stz   CR8_SEOF
            stz   CR8_SEOF+1
            stz   CR8_SEOF+2
            lda   #<CR8_SPARM
            ldx   #>CR8_SPARM
            jsr   SC_SETEOF
            bcs   :truncfl
            lda   CR8_OREF
            clc
            rts
:truncfl    sta   CR8_ERR            ;the SET_EOF's errno is the
            lda   #PCOUNT_CLOSE      ;verdict; close the fd
            sta   CR8_KPARM          ;before reporting it
            lda   CR8_OREF
            sta   CR8_KREF
            lda   #<CR8_KPARM
            ldx   #>CR8_KPARM
            jsr   SC_CLOSE
            lda   CR8_ERR
:fail       sec
            rts
