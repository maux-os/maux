*---------------------------------------------------------------
* shsgcld.s -- sh's COLD bundle, `put` into the $D000 segment
* (SH-ROOM2 step 2b): the code that runs once per prefixed
* command line or once per `set`, moved out of the low image to
* make room. Code only, and the strings that stay low are the
* ones a SYSCALL receives (copyin refuses a process address
* >= $D000, learning:01M2MCYEXW7JA7ZPZ4F7GC2217):
*   PFX_MANY_M, VARNMLONG_MSG, VARVLLONG_MSG (PR_ERRAX, via
*   PFX_REC) stay in shpfx.s / shvar.s; SETUSAGE_MSG
*   (PR_ERRAX1) stays in shbltn.s.
* The strings that moved are STRCMPI/SB_MATCH operands only,
* which the process's own CPU reads: PFX_SPECS, SET_STR and
* the four option strings.
*
* CONTRACTS (unchanged; every caller is a plain `jsr`, the
* segment being resident from SEG_INIT on):
*   PFX_REC      carry SET after a reported refusal; CLOBBERS
*                A, X, Y, PTR0.
*   PFX_ISSPEC   carry SET = special; CLOBBERS A, X, Y, PTR0,
*                PTR1 (the caller ROLs the carry at once).
*   CHCK_BLTN_SET carry SET = handled; CLOBBERS A, X, Y, PTR0,
*                PTR1.
*   SET_ARG1     Z = equal; X not preserved.
*   CONT_UNWIND  (step 4, from shsgblt.s), CONT_POP's only;
*                its CR_CLOSE parameter block (SH_CPARM) and
*                CSEOF_MSG stay low.
* Cells (PFX_*, SH_XTRACE, SH_ERREXIT) are the arena's.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PFX_REC -- record stage PFX_S's first PFX_K words: split each
* at its `=`, check the lengths, park the NAME pointer.  OUT:
* carry SET after reporting a refusal.  PFX_BASE is the stage's
* argv offset.
*---------------------------------------------------------------
PFX_REC     lda   PFX_K
            cmp   #PFX_MAX+1
            bcc   :go
            lda   #<PFX_MANY_M
            ldx   #>PFX_MANY_M
            bra   :say
:go         stz   PFX_I
:w          lda   PFX_I
            cmp   PFX_K
            bcs   :done
            asl   a
            clc
            adc   PFX_BASE
            tax
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            ldy   #0
:eq         lda   (PTR0),y
            iny
            cmp   #$BD
            bne   :eq
            dey                          ;Y = the name length
            cpy   #VARNAMELEN+1
            bcs   :nlong
            lda   #0
            sta   (PTR0),y               ;split: '=' -> NUL
            iny
            sty   PFX_T                  ;where the value starts
:v          lda   (PTR0),y
            beq   :vok
            iny
            tya
            sec
            sbc   PFX_T
            cmp   #VARVALLEN+1
            bcc   :v
            bra   :vlong
:vok        lda   PFX_S
            asl   a
            asl   a
            asl   a
            clc
            adc   PFX_I
            asl   a
            tax
            lda   PTR0
            sta   PFX_PTR,x
            lda   PTR0+1
            sta   PFX_PTR+1,x
            inc   PFX_I
            bra   :w
:done       lda   PFX_K
            ldx   PFX_S
            sta   PFX_N,x
            clc
            rts
:nlong      lda   #<VARNMLONG_MSG
            ldx   #>VARNMLONG_MSG
            bra   :say
:vlong      lda   #<VARVLLONG_MSG
            ldx   #>VARVLLONG_MSG
:say        jsr   PR_ERRAX
            sec
            rts

*---------------------------------------------------------------
* PFX_ISSPEC -- is argv[0] a special builtin that THIS shell
* has (POSIX 2.14)?  Their assignments persist.  `exec` counts
* only with no command operand (below): with one, its command
* gets the prefixes exported.  OUT: carry SET = special.
*---------------------------------------------------------------
PFX_ISSPEC  lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
            lda   #<PFX_SPECS
            sta   PTR1
            lda   #>PFX_SPECS
            sta   PTR1+1
:l          lda   (PTR1)
            beq   :no
            jsr   STRCMPI
            beq   :yes
            ldy   #0
:sk         lda   (PTR1),y
            iny
            cmp   #0
            bne   :sk
            tya
            clc
            adc   PTR1
            sta   PTR1
            bcc   :l
            inc   PTR1+1
            bra   :l
:yes        sec
            rts
*-- `exec` with no command operand only redirects the shell's
*-- own fds and never execs: a special builtin there, so its
*-- prefix persists (dash, bash --posix: `A=1 exec 3<f; echo
*-- $A` -> 1).  With a command: the temporary, exported kind.
:no         lda   CMD_ARGC+0
            cmp   #1
            bne   :nope
            lda   #<SB_XEC_STR
            sta   PTR1
            lda   #>SB_XEC_STR
            sta   PTR1+1
            jsr   STRCMPI
            beq   :yes
:nope       clc
            rts

PFX_SPECS   asc   ":"
            dfb   0
            asc   "."
            dfb   0
            asc   "BREAK"
            dfb   0
            asc   "CONTINUE"
            dfb   0
            asc   "EVAL"
            dfb   0
            asc   "EXIT"
            dfb   0
            asc   "EXPORT"
            dfb   0
            asc   "READONLY"
            dfb   0
            asc   "SET"
            dfb   0
            asc   "SHIFT"
            dfb   0
            asc   "TIMES"
            dfb   0
            asc   "TRAP"
            dfb   0
            asc   "UNSET"
            dfb   0,0

*---------------------------------------------------------------
* CHCK_BLTN_SET -- `set -x`/`set +x` (trace) and `set -e`/
* `set +e` (errexit, docs/SH-FEATURES.md 2026-09-15). Only these
* two flags are implemented -- no -u/export/--, see this task's
* own scope note. Command-position only, same shape as the
* builtins above; exactly one argument, one of "-X"/"+X"/"-E"/
* "+E", is accepted -- anything else is a loud usage error
* rather than a silent no-op.
* OUT: carry SET if the command was `set` (handled), carry CLEAR
* otherwise. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
CHCK_BLTN_SET
            lda   #<SET_STR
            sta   PTR1
            lda   #>SET_STR
            sta   PTR1+1
            jsr   SB_MATCH
            bcc   :isset
            jmp   :no                   ;range -- more flags
:isset      lda   CMD_ARGC+0
            cmp   #2
            bne   :usage
            lda   #<SETX_STR
            ldx   #>SETX_STR
            jsr   SET_ARG1
            beq   :on
            lda   #<SETXOFF_STR
            ldx   #>SETXOFF_STR
            jsr   SET_ARG1
            beq   :off
            lda   #<SETE_STR
            ldx   #>SETE_STR
            jsr   SET_ARG1
            beq   :eon
            lda   #<SETEOFF_STR
            ldx   #>SETEOFF_STR
            jsr   SET_ARG1
            beq   :eoff
:usage      lda   #<SETUSAGE_MSG
            ldx   #>SETUSAGE_MSG
            jsr   PR_ERRAX1
            sec
            rts
:on         lda   #1
            sta   SH_XTRACE
            stz   LASTSTATUS
            sec
            rts
:off        stz   SH_XTRACE
            stz   LASTSTATUS
            sec
            rts
:eon        lda   #1
            sta   SH_ERREXIT
            stz   LASTSTATUS
            sec
            rts
:eoff       stz   SH_ERREXIT
            stz   LASTSTATUS
            sec
            rts
:no         clc
            rts

*-- SET_ARG1 -- compare argv[1] with the string at A/X, letters
*-- folded (STRCMPI). OUT: Z set on equal. CLOBBERS: A, Y, PTR0,
*-- PTR1; X is NOT preserved.
SET_ARG1    sta   PTR1
            stx   PTR1+1
            lda   CMD_ARGV+2
            sta   PTR0
            lda   CMD_ARGV+3
            sta   PTR0+1
            jmp   STRCMPI

SET_STR      asc   "SET"
             dfb   0
SETX_STR     asc   "-X"
             dfb   0
SETXOFF_STR  asc   "+X"
             dfb   0
SETE_STR     asc   "-E"
             dfb   0
SETEOFF_STR  asc   "+E"
             dfb   0

*---------------------------------------------------------------
* CONT_UNWIND -- a `.` file ended with constructs of its own
* still open (CSPTR above CS_FLOOR). docs/SH-SEQ-NOTES.md sec 5,
* the bash policy: ONE diagnostic, every frame X opened closed
* (CR_CLOSE gives back a construct redirect's fd), a pending
* captured redirect forgotten, `.` returns status 2. Called by
* CONT_POP only. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
CONT_UNWIND lda   #<CSEOF_MSG
            ldx   #>CSEOF_MSG
            jsr   PR_ERRAX1
            lda   #2
            sta   LASTSTATUS
            stz   PCR_PEND
:lp         ldx   CSPTR
            dex
            jsr   CR_CLOSE
            dec   CSPTR
            lda   CSPTR
            cmp   CS_FLOOR
            bne   :lp
            rts

*-- PR_SPAWNFAIL -- IN: A = the errno SC_SPAWN refused with.
*-- Said as V7 would (ENOMEM here is the bank pool: the free
*-- list holds banks 2-15 and the shell is bank 1: pid = bank,
*-- so at most 15 processes, and the 16th spawn is refused), and
*-- everything else keeps the old generic words (ruling 7).
*-- Jumps out: carries PR_ERRAX's registers, CLOBBERS A, X.
PR_SPAWNFAIL
            cmp   #ERR_NOMEM
            beq   :spnoproc
            cmp   #ERR_NFILE
            beq   :spnfile
            jmp   PR_CMDNOTFND
:spnfile    lda   #<NFILE_MSG
            ldx   #>NFILE_MSG
            jmp   PR_ERRAX
:spnoproc   lda   #<NOPROC_MSG
            ldx   #>NOPROC_MSG
            jmp   PR_ERRAX
