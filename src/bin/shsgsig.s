*---------------------------------------------------------------
* shsgsig.s -- the signal-name table and its two printers (KFIX3
* item 3), in sh's $D000 segment. A process that dies of a
* signal used to be named only by a background job's
* `Terminated` (TERM_STR, for EVERY signal); a foreground death
* was silent, so a corrupt binary that ran BRK (SIGTRAP, `$?`
* 133) or a kill -9 left a bare status and no word. V7 sh's
* await() prints the signal's name for every foreground death
* but the interrupt and the broken pipe -- `Killed`,
* `Terminated`, `Trace/BPT trap` -- and that is the reference
* matched here (V7 sh msg.c sysmsg[], not bash 3.2, whose
* message carries a pid, the signal number and the command line,
* and not macOS dash, which appends `: N`). ONE table serves the
* foreground report and the job table's `Terminated`-style state
* column.
*
* The names are read with the process's own CPU and put out one
* byte at a time through JOB_PUTC, so no address in this segment
* is ever handed to a syscall (copyin/copyout refuse >= $D000).
* Signal numbers are maux's (V7's), 1-15; an empty entry has no
* message: 2 (the interrupt, `^C` already shows) and 13 (the
* broken pipe, which V7 leaves unreported too).
*---------------------------------------------------------------

*---------------------------------------------------------------
* SIG_PUTNAME -- IN: A = a signo. Writes its V7 name to JOB_FD's
* stream (JOB_PUTC). OUT: carry CLEAR and SIGN = the length, or
* carry SET when that signal has no message (nothing written).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SIG_PUTNAME cmp   #16
            bcs   :none
            tax
            beq   :none
            ldy   #0
:skip       dex
            beq   :at
:sk1        lda   SIG_TAB,y
            iny
            cmp   #0
            bne   :sk1
            bra   :skip
:at         lda   SIG_TAB,y
            beq   :none                  ;an empty entry
            sty   SIGI
            stz   SIGN
:pl         ldy   SIGI
            lda   SIG_TAB,y
            beq   :done
            inc   SIGI
            inc   SIGN
            jsr   JOB_PUTC
            bra   :pl
:done       clc
            rts
:none       sec
            rts

*---------------------------------------------------------------
* SIG_FGMSG -- a foreground process was reaped with WJ_SIGNALED:
* say so on stderr, V7's way (the name and a newline). IN:
* WJSTAT+1 = the signo, X = the job row (kept for the caller).
* CLOBBERS: A, Y.
*---------------------------------------------------------------
SIG_FGMSG   stx   JOB_X
            lda   #FD_STDERR
            sta   JOB_FD
            lda   WJSTAT+1
            jsr   SIG_PUTNAME
            bcs   :quiet
            jmp   JOB_CR                 ;ends with LDX JOB_X
:quiet      ldx   JOB_X
            rts

*---------------------------------------------------------------
* SIG_JOBSTATE -- the state column of a job line for a row that
* ended on a signal: the name, padded with blanks to 13 columns
* (one blank at least), which makes `Terminated` byte-identical
* to the string it replaces. A signal with no message (2, 13)
* reads as `Terminated`, as every signal did before. IN: JOB_X =
* the row. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SIG_JOBSTATE ldx  JOB_X
            lda   JOB_EXST,x
            and   #$7F
            jsr   SIG_PUTNAME
            bcc   :pad
            lda   #15                    ;no message: Terminated
            jsr   SIG_PUTNAME
:pad        lda   SIGN
:blank      pha
            lda   #ALC_A0
            jsr   JOB_PUTC
            pla
            inc   a
            cmp   #13
            bcc   :blank
            ldx   JOB_X
            rts

*---------------------------------------------------------------
* SIG_TAB -- the names, NUL-terminated, in signo order from 1
* (V7 sh msg.c sysmsg[]); an empty entry is no message.
*---------------------------------------------------------------
SIG_TAB     asc   "Hangup"
            dfb   0
            dfb   0                      ;2  the interrupt
            asc   "Quit"
            dfb   0
            asc   "Illegal instruction"
            dfb   0
            asc   "Trace/BPT trap"
            dfb   0
            asc   "IOT trap"
            dfb   0
            asc   "EMT trap"
            dfb   0
            asc   "Floating exception"
            dfb   0
            asc   "Killed"
            dfb   0
            asc   "Bus error"
            dfb   0
            asc   "Memory fault"
            dfb   0
            asc   "Bad system call"
            dfb   0
            dfb   0                      ;13 the broken pipe
            asc   "Alarm call"
            dfb   0
            asc   "Terminated"
            dfb   0
