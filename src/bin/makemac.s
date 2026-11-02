*---------------------------------------------------------------
* makemac.s -- macros. The table, the lookup, and the ONE
* expander every other part of make calls.
*
* THREE CALLERS, THREE BUFFERS, AND WHY EXPANSION IS LAZY.
* The obvious implementation expands the whole makefile once at
* read time and parses the result. It does not fit: the expanded
* form of the self-host graph is ~28 KB however small the file
* on disk is, which spends the entire saving macros just bought
* (docs/MAKE-POSIX.md sec 2). So:
*
*   - a TARGET is expanded at parse time, and only when it
*     contains a '$' -- then it lands in MK_NAMES and the rule
*     points there. A target without one is NUL-terminated in
*     place in MKTEXT as it always was, which keeps MK_FINDR a
*     plain STRCMP over stored pointers.
*   - a DEPENDENCY LIST is stored raw and expanded when the rule
*     is walked, into MK_DEPBUF indexed by DEPTH -- the parent's
*     list has to survive the recursion, exactly as MK_SAVEI
*     does.
*   - a RECIPE is stored raw and expanded at execution into
*     MK_CMDBUF. That one is forced, not chosen: $@ differs per
*     target, so one inference recipe serves many targets and
*     cannot be rewritten in place. It also retires a latent
*     wart -- the old MK_SPAWN tokenized the recipe IN PLACE,
*     spaces to NULs, so a recipe was destroyed by its first
*     run. Nothing noticed, because no recipe ran twice.
*
* Deferring the recipe is also the conforming reading: POSIX
* evaluates macros in a command line when the command is
* executed, not when the line is read.
*---------------------------------------------------------------

*---------------------------------------------------------------
* MK_MACSET -- define PTR0 (name) as PTR1 (value). A = 1 for a
* command-line macro, 0 for one from the makefile. A command
* line macro OVERRIDES the makefile and cannot be overridden by
* it, which is what `make CC=nas` has to mean.
* Both strings are pointed at, never copied: a makefile macro
* lives in MKTEXT and a command-line one in this process's own
* argv, and both outlive the run.
*---------------------------------------------------------------
MK_MACSET   sta   MAC_ISCMD
*-- MK_MACIDX clobbers PTR1 (it is STRCMP's second operand) and
*-- PTR1 is this call's VALUE, so it is parked first
            lda   PTR1
            sta   MAC_SVAL
            lda   PTR1+1
            sta   MAC_SVAL+1
            jsr   MK_MACIDX
            bcs   :new
*-- redefinition: refuse it if the standing one came from the
*-- command line and this one did not
            tax
            lda   MAC_FLAG,x
            beq   :again
            lda   MAC_ISCMD
            beq   :done               ;cmdline wins, silently
:again      txa
            bra   :fill
:new        lda   NMACROS
            cmp   #MK_MAXMAC
            bcs   MK_MANYMAC
            inc   NMACROS
:fill       tax
            lda   MAC_SVAL
            sta   PTR1
            lda   MAC_SVAL+1
            sta   PTR1+1
            lda   PTR0
            sta   MAC_NAME,x
            lda   PTR0+1
            sta   MAC_NAME+MK_MAXMAC,x
            lda   PTR1
            sta   MAC_VAL,x
            lda   PTR1+1
            sta   MAC_VAL+MK_MAXMAC,x
            lda   MAC_ISCMD
            sta   MAC_FLAG,x
:done       rts

MK_MANYMAC  lda   #<MANYMACMSG
            ldx   #>MANYMACMSG
            jmp   MK_DIE

*---------------------------------------------------------------
* MK_MACIDX -- index of the macro named at PTR0, carry CLEAR
* and A = index on a hit. PTR1 is clobbered (STRCMP's second
* operand); PTR0 survives.
*---------------------------------------------------------------
MK_MACIDX   ldx   #0
:loop       cpx   NMACROS
            bcs   :miss
            stx   MAC_I
            lda   MAC_NAME,x
            sta   PTR1
            lda   MAC_NAME+MK_MAXMAC,x
            sta   PTR1+1
            jsr   STRCMP
            beq   :hit
            ldx   MAC_I
            inx
            bra   :loop
:hit        lda   MAC_I
            clc
            rts
:miss       sec
            rts

*---------------------------------------------------------------
* MK_MACFIND -- value of the macro named at PTR0, carry CLEAR
* and PTR1 = the value.
*
* THE ENVIRONMENT IS A MACRO SOURCE, which POSIX requires and
* which costs nothing here: there is no enumeration, only a
* fallback in the lookup. -e flips the order so the environment
* beats the makefile; without it the makefile wins, and a
* command-line macro beats both (MK_MACSET).
*---------------------------------------------------------------
MK_MACFIND  lda   EFLAG
            beq   :mkfirst
            jsr   GETENV
            bcc   :done
:mkfirst    jsr   MK_MACIDX
            bcs   :tryenv
            tax
            lda   MAC_VAL,x
            sta   PTR1
            lda   MAC_VAL+MK_MAXMAC,x
            sta   PTR1+1
            clc
            rts
:tryenv     lda   EFLAG
            bne   :nope               ;already tried it
            jsr   GETENV
            bcc   :done
:nope       sec
:done       rts

