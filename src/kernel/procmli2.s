*---------------------------------------------------------------
* procmli2.s -- the tail of the MLI call wrappers.
*
* SPLIT OUT OF procmli.s (S9 L4, 2026-08-29): that file's own
* stripped text was 14470 B, past `as`'s 16126 B source window,
* so
* it could never be assembled inside maux as one REL module. The
* cut is at a section boundary and this file is `put`
* immediately
* after its parent, so the emitted bytes are unchanged -- which
* is
* what check-bytes asserts.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PRC_DUP2_SET -- point one fd slot at an already-open object.
*
* IN:  P_PID / P_FD = the DESTINATION (whose table, which slot)
*      P_OBJ        = the OFT object to point it at
* OUT: nothing. CLOBBERS: A, X, Y, P_TMP2. P_OBJ and P_FD are
*      preserved across the close -- see below.
*
* This was PRC_FDACTIONS's `:dup` tail, lifted verbatim so that
* SYS_DUP2 and spawn()'s fdactions share one implementation of
* the three steps that are easy to get subtly wrong:
*
*   1. CLOSE whatever the destination held first, or its
*      reference leaks for the life of the process.
*   2. TAKE a reference on the new object, or the first close of
*      either fd frees an object the other still points at.
*   3. Do (1) before (2), and survive the fact that PCLS_ONE_FD
*      CLOBBERS P_OBJ and P_FD -- which is what the stack dance
*      below is for, and why this is worth factoring rather than
*      writing twice.
*
* The device exemption is NOT repeated here: PRC_INC_OBJ_A opens
* with its own `cmp #FD_DEV_BASE / bcs :done`, so a tty object
* is already left unrefcounted. PCLS_ONE_FD guards its own
* decrement the same way.
*---------------------------------------------------------------
PRC_DUP2_SET
            lda   P_FD
            pha
            lda   P_OBJ
            pha
            jsr   PCLS_ONE_FD
            pla
            sta   P_OBJ
            pla
            sta   P_FD
            lda   P_OBJ
            sta   P_TMP2
            jsr   PRC_INC_OBJ_A
            jsr   PRC_SET_FDOBJ
            rts

*---------------------------------------------------------------
* PRC_DUP2 -- SYS_DUP2 (9). dup2(oldfd, newfd).
*
* Parameters: 2 bytes, oldfd then newfd. Returns newfd.
*
* POSIX semantics, and the two that implementations differ on
* are called out because both fall out of the order below:
*
*  - dup2(fd, fd) where fd is OPEN returns fd and does NOT close
*    it. Checked BEFORE the close, so the close cannot happen.
*  - dup2(fd, fd) where fd is CLOSED is an error, not a no-op --
*    the open-check runs first and fails it.
*  - either fd outside 0..7 is an error, not a silent
*    truncation. PCB_FDTABLE is 8 bytes (mm.annex.equ) and
*    that is a HARD LIMIT, so refusing is the honest answer.
*
* Both fds resolve against the CALLER's own table -- that is the
* whole difference from spawn()'s fdactions, which resolves the
* source against the PARENT's. The shared tail is PRC_DUP2_SET.
*---------------------------------------------------------------
PRC_DUP2    lda   #2
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+1             ;newfd range -- checked
            cmp   #8                     ;  here because nothing
            bcs   :badfd                 ;  else will look at it
*-- oldfd's range AND open checks, and the fetch, are all
*-- PRC_CUR_FDOBJ's -- it resolves against K_CURPID and reports
*-- ERR_INVAL itself for either failure. Reusing it is why this
*-- handler is short; writing the checks out again cost 18 bytes
*-- of a kernel image that is already over PMLI_IBF_BASE.
            lda   PRC_PARM
            sta   P_FD
            jsr   PRC_CUR_FDOBJ
            bcs   :fail
            sta   P_OBJ
            lda   PRC_PARM               ;dup2(fd,fd) on an open
            cmp   PRC_PARM+1             ;  fd: return it, and
            beq   :done                  ;  do NOT close it
            lda   PRC_PARM+1
            sta   P_FD
            jsr   PRC_DUP2_SET
:done       lda   PRC_PARM+1             ;dup2 returns newfd
            jsr   PRC_RET_OK_A
:fail       rts
:badfd      lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts

*---------------------------------------------------------------
* PRC_FDSTAT -- SYS_FDSTAT (11): what kind of object does one of
* the CALLER'S OWN fd slots hold. maux's isatty (V7 sh gates its
* prompt on gtty(0) succeeding; a tty and a pipe are equally
* unseekable, so nothing weaker than asking the kernel works --
* inc/sc.proc.equ has the caller-facing contract).
*
* One parameter byte: the fd. Returns the fd-table byte's
* MEANING in A: a device slot comes back RAW (>= FD_DEV_BASE --
* the high bit IS the isatty answer), an OFT-backed slot comes
* back as its OFT_TYPE tag (== the FDST_* names). Range and
* open checks, and both failure errnos, are PRC_CUR_FDOBJ's.
*
* READ-ONLY: no refcount moves, no table writes -- safe at any
* point in a process's life, which is what a shell's one-time
* startup probe wants.
*---------------------------------------------------------------
PRC_FDSTAT  lda   #1
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM
            sta   P_FD
            jsr   PRC_CUR_FDOBJ
            bcs   :fail
            cmp   #FD_DEV_BASE
            bcs   :dev                   ;device: raw table byte
            tax
            lda   OFT_TYPE,x             ;OFT slot: its type tag
:dev        jsr   PRC_RET_OK_A
:fail       rts
