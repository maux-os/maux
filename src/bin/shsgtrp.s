*---------------------------------------------------------------
* shsgtrp.s -- the `trap` builtin (set/reset/list),
* segment-resident.
* Moved out of shtrap.s 2026-09-16 with NO source change: this
* file is `put` inside sh.s's `org PRC_LC_COMMON` block, so
* every label here resolves at $E000+ and the low image keeps
* only the `jsr`s into it. docs/SH-SUBSET.md ruling 7.6 has
* the mechanism (SEG_INIT, the low copy, the two tripwires).
*
* NOTHING HERE MAY BE REACHED BEFORE SEG_INIT RAN -- it is the
* first thing START (shlex.s) does.
*
* AND NOTHING HERE MAY BE HANDED TO A SYSCALL. The kernel's
* COPYIN_ENTRY/COPYOUT_ENTRY templates (src/kernel/entry2.s)
* REFUSE a process address >= $D000 outright ("LC path not
* wired yet", K_CPY_ERR=2), and BankCopy -- the path a tty or
* file write's BUFFER takes -- is built on them. So the
* strings, parmlists and buffers these routines hand to
* PUTS/PR_ERRAX/SC_* stayed behind in shtrap.s; only CODE moved.
*---------------------------------------------------------------

*---------------------------------------------------------------
* CHCK_BLTN_TRP -- carry SET = the command was `trap` (handled,
* do not spawn); carry CLEAR otherwise. Command-position only.
* CLOBBERS: A, X, Y, PTR0, PTR1, TRAP_* scratch.
*---------------------------------------------------------------
CHCK_BLTN_TRP
            lda   NCMD
            cmp   #1
            bne   :notrap
            lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
            lda   #<TRAP_STR
            sta   PTR1
            lda   #>TRAP_STR
            sta   PTR1+1
            jsr   STRCMPI
            beq   :istrap
:notrap     clc
            rts

:istrap     lda   CMD_ARGC+0
            cmp   #1
            bne   :haveargs
            jsr   TRAP_LIST              ;`trap` alone: list
            sec
            rts

*-- FORM: `trap n...` (reset -- argv[1] is a valid signal spec)
*-- vs `trap arg n...` (argv[1] is the action string): V7's
*-- own rule.
*-- TRAP_ARGX indexes CMD_ARGV in BYTES: argv[k] at +2*k.
:haveargs   lda   #2
            sta   TRAP_ARGX
            jsr   TRAP_ARG_PTR           ;PTR0 = argv[1]
            jsr   TRAP_AS_SIG
            bcc   :isaction
*-- reset form: argv[1..] are all signals to reset.
            lda   #2
            sta   TRAP_ARGX
:resetlp    lda   TRAP_ARGX
            lsr   a
            cmp   CMD_ARGC
            bcs   :done
            jsr   TRAP_ARG_PTR
            jsr   TRAP_AS_SIG
            bcc   :badsig
            lda   #0                      ;mode 0 = reset (DFL)
            jsr   TRAP_SET_ONE
            inc   TRAP_ARGX
            inc   TRAP_ARGX
            bra   :resetlp

*-- action form: argv[1] is the string; argv[2..] are signals.
:isaction   jsr   TRAP_ARG_PTR           ;PTR0 = the action
            lda   PTR0
            sta   TRAP_ACT
            lda   PTR0+1
            sta   TRAP_ACT+1
            ldy   #0
            lda   (PTR0),y                ;empty -> IGN
            bne   :actset
            lda   #1
            sta   TRAP_MODE
            bra   :actlp0
*-- A lone "-" is POSIX's reset form (`trap - 15`); it used
*-- to be stored as the action string "-".
:actset     and   #$7F
            cmp   #'-'
            bne   :actcatch
            iny
            lda   (PTR0),y
            bne   :actcatch
            sta   TRAP_MODE                ;A = 0: reset
            bra   :actlp0
:actcatch   lda   #2                       ;catch + store
            sta   TRAP_MODE
:actlp0     lda   #4
            sta   TRAP_ARGX
:actlp      lda   TRAP_ARGX
            lsr   a
            cmp   CMD_ARGC
            bcs   :done
            jsr   TRAP_ARG_PTR
            jsr   TRAP_AS_SIG
            bcc   :badsig
            lda   TRAP_MODE
            jsr   TRAP_SET_ONE
            inc   TRAP_ARGX
            inc   TRAP_ARGX
            bra   :actlp
:badsig     lda   #<TRAPBAD_MSG
            ldx   #>TRAPBAD_MSG
            jsr   PR_ERRAX1
            sec
            rts
:done       sec
            rts

*---------------------------------------------------------------
* TRAP_ARG_PTR -- PTR0 = CMD_ARGV[TRAP_ARGX] (a byte index).
*---------------------------------------------------------------
TRAP_ARG_PTR
            ldx   TRAP_ARGX
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* TRAP_AS_SIG -- PTR0 = an operand. Carry SET + TRAP_SIG = signo
* (0-15) if it is a decimal number 0-15 or a known name; carry
* CLEAR if not a signal (the caller reads it as the action).
* CLOBBERS A, X, Y; preserves PTR0.
*---------------------------------------------------------------
TRAP_AS_SIG
            ldy   #0
            lda   (PTR0),y
            and   #$7F
            cmp   #'0'
            bcc   :name
            cmp   #'9'+1
            bcs   :name
            lda   #0
            sta   TRAP_SIG
:numlp      lda   (PTR0),y
            beq   :numend
            and   #$7F
            cmp   #'0'
            bcc   :no
            cmp   #'9'+1
            bcs   :no
            sec
            sbc   #'0'
            pha
            lda   TRAP_SIG
            asl   a
            asl   a
            adc   TRAP_SIG
            asl   a
            sta   TRAP_SIG
            pla
            clc
            adc   TRAP_SIG
            sta   TRAP_SIG
            iny
            bne   :numlp
:numend     lda   TRAP_SIG
            cmp   #16
            bcs   :no
            sec
            rts
:name       lda   #0
            sta   TRAP_SIG
            lda   #<TRAPNM_EXIT
            ldx   #>TRAPNM_EXIT
            jsr   TRAP_NAME_IS
            bcs   :yes
            lda   #2
            sta   TRAP_SIG
            lda   #<TRAPNM_INT
            ldx   #>TRAPNM_INT
            jsr   TRAP_NAME_IS
            bcs   :yes
            lda   #15
            sta   TRAP_SIG
            lda   #<TRAPNM_TERM
            ldx   #>TRAPNM_TERM
            jsr   TRAP_NAME_IS
            bcs   :yes
            lda   #1
            sta   TRAP_SIG
            lda   #<TRAPNM_HUP
            ldx   #>TRAPNM_HUP
            jsr   TRAP_NAME_IS
            bcs   :yes
            lda   #3
            sta   TRAP_SIG
            lda   #<TRAPNM_QUIT
            ldx   #>TRAPNM_QUIT
            jsr   TRAP_NAME_IS
            bcs   :yes
            lda   #9
            sta   TRAP_SIG
            lda   #<TRAPNM_KILL
            ldx   #>TRAPNM_KILL
            jsr   TRAP_NAME_IS
            bcs   :yes
:no         clc
            rts
:yes        sec
            rts

*-- TRAP_NAME_IS -- A/X = a name. Carry SET iff PTR0's operand
*-- equals it (case-insensitive). Preserves PTR0.
TRAP_NAME_IS
            sta   PTR1
            stx   PTR1+1
            lda   PTR0
            pha
            lda   PTR0+1
            pha
            jsr   STRCMPI
            sta   TRAP_TMP
            pla
            sta   PTR0+1
            pla
            sta   PTR0
            lda   TRAP_TMP
            bne   :ne
            sec
            rts
:ne         clc
            rts

*---------------------------------------------------------------
* TRAP_SLOT_P1 -- PTR1 = &TRAPTAB[TRAP_SIG]. Slots are exactly
* 256 bytes, so slot N is TRAPTAB + N*256: the low byte is
* TRAPTAB's OWN low byte and only the high byte takes +signo.
*
* This used to force the low byte to 0 -- correct only if
* TRAPTAB were page-aligned, and it is a bare `ds` in bss, so
* it never was. Every slot sat (TRAPTAB & $FF) bytes BEFORE the
* table, on whatever bss preceded it; store and read agreed, so
* a trap worked exactly as long as nothing wrote that spillover
* between arm and fire. An 11-byte layout shift (a third PATHTAB
* entry) moved the exit trap's slot 0 onto TRAP_TMP/TRAP_ACT and
* arming clobbered byte 0 of its own string; 53 more bytes moved
* it onto dormant SH_PATHSRC and it "worked" again. Found
* 2026-09-05 (check-play's trap phase). Do NOT "fix" this by
* page-aligning TRAPTAB -- that is the same accident, re-armed.
*---------------------------------------------------------------
TRAP_SLOT_P1
            lda   #<TRAPTAB
            sta   PTR1
            clc
            lda   TRAP_SIG
            adc   #>TRAPTAB
            sta   PTR1+1
            rts

*---------------------------------------------------------------
* TRAP_SET_ONE -- A = mode (0 reset/DFL, 1 ignore/IGN, 2 catch+
* store), TRAP_SIG = signo, TRAP_ACT/+1 = action (mode 2). Sets
* the disposition via SC_SIGNAL (except signo 0, the exit trap,
* which is purely shell-side) and updates TRAPACT/TRAPTAB.
* CLOBBERS A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
TRAP_SET_ONE
            sta   TRAP_MODE
            cmp   #2
            beq   :store
            ldx   TRAP_SIG
            lda   #0
            sta   TRAPACT,x
            lda   TRAP_SIG
            beq   :sdone                 ;signo 0: no syscall
            lda   TRAP_MODE
            bne   :ign
            ldx   #SIGA_DFL
            lda   TRAP_SIG
            cmp   #15                    ;an interactive shell's
            bne   :call                  ;default for TERM is to
            lda   SH_INTERACT            ;catch and drop it, not
            beq   :call                  ;the kernel's terminate
            ldx   #SIGA_CATCH            ;(shlex.s START)
            bra   :call
:ign        ldx   #SIGA_IGN
:call       lda   TRAP_SIG
            jsr   SC_SIGNAL
:sdone      rts
:store      jsr   TRAP_SLOT_P1           ;PTR1 = dest slot
            lda   TRAP_ACT
            sta   PTR0
            lda   TRAP_ACT+1
            sta   PTR0+1
            ldy   #0
:scp        lda   (PTR0),y
            sta   (PTR1),y
            beq   :scpd
            iny
            bne   :scp
:scpd       ldx   TRAP_SIG
            lda   #1
            sta   TRAPACT,x
            lda   TRAP_SIG
            beq   :armed                 ;signo 0: exit trap
            lda   TRAP_SIG
            ldx   #SIGA_CATCH
            jsr   SC_SIGNAL
:armed      rts

*---------------------------------------------------------------
* TRAP_LIST -- `trap` with no operands: `trap -- 'CMD' N` per
* armed signal, signal-number order (exit trap 0 included).
*---------------------------------------------------------------
TRAP_LIST   lda   #0
            sta   TRAP_SIG
:llp        ldx   TRAP_SIG
            lda   TRAPACT,x
            beq   :lnext
            lda   #<TRAPLPFX
            sta   PTR0
            lda   #>TRAPLPFX
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            jsr   TRAP_SLOT_P1
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #<TRAPLSFX
            sta   PTR0
            lda   #>TRAPLSFX
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   TRAP_SIG
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:lnext      inc   TRAP_SIG
            lda   TRAP_SIG
            cmp   #16
            bne   :llp
            rts
