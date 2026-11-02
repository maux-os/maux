*---------------------------------------------------------------
* makerun.s -- the part that makes this `make`: walk the
* dependency graph, compare mod times, run the recipes.
*---------------------------------------------------------------

*---------------------------------------------------------------
* MK_RUNALL -- build each target named on the command line, or
* the FIRST rule in the file if none was named. That default is
* make's oldest convention and the reason a makefile's first
* rule is written to be the one you usually want.
*
* "First rule" means the first rule whose target does NOT begin
* with a dot. A makefile that opens with `.SUFFIXES:` or an
* inference rule -- which is how a macro-and-inference makefile
* is usually written -- would otherwise default to building a
* special target, and the only visible symptom would be a build
* that did nothing and exited 0.
*---------------------------------------------------------------
MK_RUNALL   stz   ERRFLAG
            stz   STOPFLAG
            stz   MK_FAIL
            stz   QOUT
            stz   DEPTH
            lda   NTARGETS
            bne   :named
            ldx   #0
:findfirst  cpx   NRULES
            bcs   :nothing
            lda   RULE_TGT,x
            sta   PTR0
            lda   RULE_TGT+MK_MAXRULE,x
            sta   PTR0+1
            lda   (PTR0)
            cmp   #$AE                 ;'.'
            bne   :usefirst
            inx
            bra   :findfirst
:usefirst   txa
            jsr   MK_BUILDI
:nothing    rts                        ;empty makefile: nothing
                                       ;to do, and that is not
                                       ;an error
:named      stz   ARGI
:loop       lda   ARGI
            cmp   NTARGETS
            bcs   :done
            ldx   ARGI
            lda   TGTLO,x
            sta   MK_NAMEP
            lda   TGTHI,x
            sta   MK_NAMEP+1
            jsr   MK_BUILD
            inc   ARGI
            lda   STOPFLAG
            beq   :loop
:done       rts

*---------------------------------------------------------------
* MK_SETERR -- one failure, recorded once.
*
* ERRFLAG is the EXIT STATUS and is sticky. STOPFLAG is the
* separate question of whether to unwind, and -k is exactly the
* flag that separates them: "abandon work on the current entry,
* but continue on branches that do not depend on the current
* entry" (V7 make(1)). MK_FAIL is how "this entry" propagates --
* MK_DEPS collects it, and a rule with a failed dependency is
* marked failed rather than built.
*---------------------------------------------------------------
MK_SETERR   lda   #1
            sta   ERRFLAG
            sta   MK_FAIL
            lda   KFLAG
            bne   :keepgoing
            lda   #1
            sta   STOPFLAG
:keepgoing  rts

*---------------------------------------------------------------
* MK_BUILD -- bring the target named at MK_NAMEP up to date.
*
* In order: an explicit rule, then an inference rule, then
* .DEFAULT, then "it is a source file if it exists". A name with
* no rule that does NOT exist is an error -- that asymmetry is
* what turns a typo into a diagnostic instead of a silent no-op.
*---------------------------------------------------------------
MK_BUILD    stz   MK_FAIL
            lda   MK_NAMEP
            sta   MK_FNAME
            lda   MK_NAMEP+1
            sta   MK_FNAME+1
            jsr   MK_FINDNM
            bcs   :norule
            jmp   MK_BUILDI
:norule     jsr   MK_INFER
            bcs   :nosuffix
            jmp   MK_INFRUN
:nosuffix   jsr   MK_STAT
            lda   MK_EXISTS
            bne   :issource
            lda   DEFRULE
            cmp   #$FF
            beq   :noway
            lda   MK_NAMEP
            sta   MK_TGTP
            lda   MK_NAMEP+1
            sta   MK_TGTP+1
            stz   MK_SRCP
            stz   MK_SRCP+1
            jsr   MK_SETSTEM
            lda   DEFRULE
            sta   MK_RULEI
            jmp   MK_RECIPE
:noway      lda   #<NORULEMSG
            sta   PTR0
            lda   #>NORULEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   MK_NAMEP
            sta   PTR0
            lda   MK_NAMEP+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            jsr   MK_SETERR
:issource   rts

*---------------------------------------------------------------
* MK_FINDNM -- rule index for the name at MK_FNAME, carry CLEAR
* and A = index if found.
*
* Its loop index is MK_FI, NOT MK_RULEI. Inference calls this
* while MK_RULEI holds the rule being walked, and having the
* lookup quietly overwrite it is exactly the kind of bug that
* only shows up on the graph that actually uses inference.
*---------------------------------------------------------------
MK_FINDNM   ldx   #0
:loop       cpx   NRULES
            bcs   :miss
            stx   MK_FI
            lda   RULE_TGT,x
            sta   PTR1
            lda   RULE_TGT+MK_MAXRULE,x
            sta   PTR1+1
            lda   MK_FNAME
            sta   PTR0
            lda   MK_FNAME+1
            sta   PTR0+1
            jsr   STRCMP
            beq   :hit
            ldx   MK_FI
            inx
            bra   :loop
:hit        lda   MK_FI
            clc
            rts
:miss       sec
            rts

*---------------------------------------------------------------
* MK_BUILDI -- build rule A.
*
* Depth-first: every dependency is brought up to date BEFORE
* this target is judged, because a dependency that was just
* rebuilt is newer than it was when we started and that has to
* count.
*
* RULE_MADE is the cycle guard AND the memo: 1 = in progress, so
* meeting it again is a circular dependency rather than infinite
* recursion; 2 = done; 3 = done and FAILED, which is what makes
* -k refuse the parent of a broken entry without re-running it.
*---------------------------------------------------------------
MK_BUILDI   sta   MK_RULEI
            stz   MK_FAIL
            tax
            lda   RULE_MADE,x
            cmp   #1
            bne   :notcycle
            jmp   :cycle
:notcycle   cmp   #2
            beq   :already
            cmp   #3
            beq   :wasfail
            lda   #1
            sta   RULE_MADE,x
            inc   DEPTH
            lda   DEPTH
            cmp   #MK_DEPTH
            bcc   :depthok
            jmp   :deep
:depthok
            ldx   DEPTH
            lda   MK_RULEI
            sta   MK_SAVRI,x
            jsr   MK_DEPS
            ldx   DEPTH
            lda   MK_SAVRI,x
            sta   MK_RULEI
            ldx   DEPTH
            lda   MK_SAVEF,x
            bne   :depfail
            lda   STOPFLAG
            bne   :out
            jsr   MK_DECIDE
            lda   MK_NEEDS
            beq   :out
            ldx   MK_RULEI
            lda   RULE_NCMD,x
            bne   :runit
*-- a rule with dependencies and no recipe can still be made by
*-- an inference rule: the `a.o b.o: incl` form in V7 make(1)
            jsr   MK_INFER
            bcs   :out
            jsr   MK_INFRUN
            bra   :out
:runit      jsr   MK_SETINT
            jsr   MK_RECIPE
            bra   :out
:depfail    lda   #1
            sta   MK_FAIL
:out        ldx   DEPTH
            lda   MK_SAVRI,x
            sta   MK_RULEI
            dec   DEPTH
            ldx   MK_RULEI
            lda   MK_FAIL
            bne   :markfail
            lda   #2
            sta   RULE_MADE,x
            rts
:markfail   lda   #3
            sta   RULE_MADE,x
            rts
:already    rts
:wasfail    lda   #1
            sta   MK_FAIL
            rts
:cycle      lda   #<CYCLEMSG
            sta   PTR0
            lda   #>CYCLEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            jmp   MK_SETERR
:deep       dec   DEPTH
            lda   #<DEEPMSG
            sta   PTR0
            lda   #>DEEPMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            jmp   MK_SETERR

*---------------------------------------------------------------
* MK_DEPS -- expand rule MK_RULEI's dependency list into this
* depth's buffer and build every name in it.
*
* MK_RULEI is saved and restored around each recursion because
* the callee overwrites it; MK_SAVEI is a stack indexed by DEPTH
* rather than the 6502's, which has 256 bytes and other users.
*
* MK_DEPN and MK_NAMEP are clobbered by the recursion exactly as
* MK_RULEI is -- the callee's own MK_DEPS runs the same loop --
* so all THREE ride the DEPTH stack. Saving only the rule index
* walked the FIRST dep and then decremented the child's leftover
* count against the child's last name: CAT echoed one recipe of
* twelve (check-selfmake, 2026-09-01).
*---------------------------------------------------------------
MK_DEPS     ldx   DEPTH
            lda   #0
            sta   MK_SAVEF,x
            jsr   MK_EXPDEPS
            lda   MK_DEPN
            bne   :have
            rts
*-- MK_DEPC is the COUNTDOWN and MK_DEPN stays the rule's dep
*-- COUNT. They used to be one cell, and the loop below left it
*-- at zero: MK_DECIDE then saw a rule with no dependencies, $<
*-- and $? expanded to nothing, and -q answered "up to date" for
*-- every rule that had any. Both ride the DEPTH stack.
:have       jsr   MK_DEPFRST
            lda   PTR2
            sta   MK_NAMEP
            lda   PTR2+1
            sta   MK_NAMEP+1
            lda   MK_DEPN
            sta   MK_DEPC
:each       ldx   DEPTH
            lda   MK_RULEI
            sta   MK_SAVEI,x
            lda   MK_DEPN
            sta   MK_SAVED,x
            lda   MK_DEPC
            sta   MK_SAVEC,x
            lda   MK_NAMEP
            sta   MK_SAVENL,x
            lda   MK_NAMEP+1
            sta   MK_SAVENH,x
            jsr   MK_BUILD
            ldx   DEPTH
            lda   MK_SAVEI,x
            sta   MK_RULEI
            lda   MK_SAVED,x
            sta   MK_DEPN
            lda   MK_SAVEC,x
            sta   MK_DEPC
            lda   MK_SAVENL,x
            sta   MK_NAMEP
            lda   MK_SAVENH,x
            sta   MK_NAMEP+1
            lda   MK_FAIL
            beq   :ok
            ldx   DEPTH
            lda   #1
            sta   MK_SAVEF,x
:ok         lda   STOPFLAG
            bne   :done
            dec   MK_DEPC
            beq   :done
*-- names are NUL-terminated back to back in the expansion
*-- buffer, so the next one starts one past this one's
            jsr   MK_SKIPNM
            bra   :each
:done       rts

MK_SKIPNM   lda   MK_NAMEP
            sta   PTR0
            lda   MK_NAMEP+1
            sta   PTR0+1
:scan       lda   (PTR0)
            beq   :hit
            inc   PTR0
            bne   :scan
            inc   PTR0+1
            bra   :scan
:hit        inc   PTR0
            bne   :nc
            inc   PTR0+1
:nc         lda   PTR0
            sta   MK_NAMEP
            lda   PTR0+1
            sta   MK_NAMEP+1
            rts

