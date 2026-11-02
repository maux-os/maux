*---------------------------------------------------------------
* makeinf.s -- inference rules, the special targets, and the
* internal macros ($@ $< $* $?).
*
* V7 make(1) states the rule this follows, and the ordering
* clause is the half an implementation gets wrong:
*
*   "Prerequisites are inferred according to selected suffixes
*    listed as the 'prerequisites' for the special name
*    '.SUFFIXES': multiple lists accumulate; an empty list
*    clears what came before. ORDER IS SIGNIFICANT: the first
*    possible name for which both a file and a rule as described
*    in the next paragraph exist is inferred."
*
* So both loops below walk .SUFFIXES in declaration order and
* the first pair that has BOTH a `.s1.s2` rule AND a readable
* (or buildable) `stem.s1` wins. Nothing is scored.
*
* SINGLE-STEP, DELIBERATELY. The inferred source must already
* exist as a file or be a target with an explicit rule; make
* does not chain `.y.c` into `.c.o`. That is POSIX's own
* algorithm, it is what keeps this routine free of a nesting
* stack, and it is what maux's own graph needs -- every .S
* source is staged, never generated.
*
* A PRODOS ACCIDENT WORTH NAMING: a ProDOS filename must begin
* with a LETTER (learning:01M07G8WT2R3G2P87EK1DNPVYP), so a
* name beginning with '.' can never be a real file here. make's
* "a target starting with a dot is special" rule is therefore
* unambiguous on this system in a way it is not on Unix.
*---------------------------------------------------------------

*---------------------------------------------------------------
* MK_SPECIAL -- one pass over the parsed rule table, in FILE
* ORDER, acting on the special targets. Done after the parse
* rather than during it so that ".SUFFIXES" accumulation and
* clearing follow the order they were written in, which is the
* part V7 says is significant.
*---------------------------------------------------------------
MK_SPECIAL  stz   SPI
            lda   #$FF
            sta   DEFRULE
:loop       lda   SPI
            cmp   NRULES
            bcs   :done
            tax
            lda   RULE_TGT,x
            sta   MK_SPTR
            sta   PTR0
            lda   RULE_TGT+MK_MAXRULE,x
            sta   MK_SPTR+1
            sta   PTR0+1
            lda   (PTR0)
            cmp   #$AE                 ;'.'
            bne   :next
            lda   #<SUFFIXNM
            ldx   #>SUFFIXNM
            jsr   MK_SPCMP
            beq   :dosuffix
            lda   #<SILENTNM
            ldx   #>SILENTNM
            jsr   MK_SPCMP
            beq   :dosilent
            lda   #<IGNORENM
            ldx   #>IGNORENM
            jsr   MK_SPCMP
            beq   :doignore
            lda   #<DEFAULTNM
            ldx   #>DEFAULTNM
            jsr   MK_SPCMP
            beq   :dodefault
*-- .PRECIOUS and .POSIX are ACCEPTED and do nothing, which is
*-- honest rather than lazy: nothing here deletes a target on
*-- an interrupt, so .PRECIOUS has nothing to protect, and this
*-- make is POSIX-shaped whether or not .POSIX is written.
            bra   :next
:dosilent   inc   SFLAG
            bra   :next
:doignore   inc   IFLAG
            bra   :next
:dodefault  lda   SPI
            sta   DEFRULE
            bra   :next
:dosuffix   jsr   MK_ADDSUFS
:next       inc   SPI
            bra   :loop
:done       rts

*---------------------------------------------------------------
* MK_SPCMP -- compare the current special target (MK_SPTR)
* against the literal in A/X. Z set on a match.
*---------------------------------------------------------------
MK_SPCMP    sta   PTR1
            stx   PTR1+1
            lda   MK_SPTR
            sta   PTR0
            lda   MK_SPTR+1
            sta   PTR0+1
            jmp   STRCMP

*---------------------------------------------------------------
* MK_ADDSUFS -- ".SUFFIXES: list". An EMPTY list clears; a
* non-empty one accumulates. The names are COPIED into SUFTEXT
* rather than pointed at, because they are read out of the
* per-depth expansion buffer, which the very next rule reuses.
*---------------------------------------------------------------
MK_ADDSUFS  lda   SPI
            sta   MK_RULEI
            stz   DEPTH
            jsr   MK_EXPDEPS
            lda   MK_DEPN
            bne   :add
            stz   NSUFFIX
            stz   SUFLEN
            rts
:add        jsr   MK_DEPFRST
:each       lda   NSUFFIX
            cmp   #MK_MAXSUF
            bcs   MK_MANYSUF
            tax
*-- record where this one starts, then copy it in
            clc
            lda   #<SUFTEXT
            adc   SUFLEN
            sta   SUF_L,x
            lda   #>SUFTEXT
            adc   #0
            sta   SUF_H,x
            inc   NSUFFIX
:copy       lda   (PTR2)
            ldx   SUFLEN
            cpx   #MK_SUFTSZ-1
            bcs   MK_MANYSUF
            sta   SUFTEXT,x
            inc   SUFLEN
            jsr   MK_TOKINC
            cmp   #0
            bne   :copy
            dec   MK_DEPN
            beq   :done
            bra   :each
:done       rts

MK_MANYSUF  lda   #<MANYSUFMSG
            ldx   #>MANYSUFMSG
            jmp   MK_DIE

*---------------------------------------------------------------
* MK_DEPBASE -- PTR2 = this depth's expanded dependency buffer.
* MK_DEPBSZ is 1024 (four pages), so the arithmetic is two
* shifts rather than a multiply.
*---------------------------------------------------------------
MK_DEPBASE  lda   #<MK_DEPBUF
            sta   PTR2
            lda   DEPTH
            asl   a
            asl   a
            clc
            adc   #>MK_DEPBUF
            sta   PTR2+1
            rts

*---------------------------------------------------------------
* MK_EXPDEPS -- expand rule MK_RULEI's RAW dependency text into
* this depth's buffer and split it into words. MK_DEPN is the
* count; the names are NUL-separated, exactly the shape the walk
* used to get from in-place termination.
*---------------------------------------------------------------
MK_EXPDEPS  ldx   MK_RULEI
            lda   RULE_DEP,x
            sta   PTR0
            lda   RULE_DEP+MK_MAXRULE,x
            sta   PTR0+1
            jsr   MK_DEPBASE
            lda   PTR2
            sta   PTR1
            lda   PTR2+1
            sta   PTR1+1
            clc
            lda   PTR2
            adc   #<MK_DEPLIM
            sta   EXP_END
            lda   PTR2+1
            adc   #>MK_DEPLIM
            sta   EXP_END+1
            lda   #1
            sta   EXP_SEMI             ;';' ends a dep field
            jsr   MK_EXPAND
            jsr   MK_DEPBASE
            jsr   MK_TOKEN
            lda   MK_TOKN
            sta   MK_DEPN
            ldx   DEPTH
            lda   MK_TOK1
            sta   MK_DEP1L,x
            lda   MK_TOK1+1
            sta   MK_DEP1H,x
            rts

*---------------------------------------------------------------
* MK_DEPFRST -- PTR2 = this depth's FIRST dependency name --
* NOT the buffer base. See MK_TOKEN.
*---------------------------------------------------------------
MK_DEPFRST  ldx   DEPTH
            lda   MK_DEP1L,x
            sta   PTR2
            lda   MK_DEP1H,x
            sta   PTR2+1
            rts

*---------------------------------------------------------------
* MK_EXPCMD -- expand the raw recipe line at MK_CMDP into
* MK_CMDBUF, with the internal macros bound by the caller. A
* ';' is ORDINARY here: it separates a command from a target
* line, never two commands from each other (there is no shell).
*---------------------------------------------------------------
MK_EXPCMD   lda   MK_CMDP
            sta   PTR0
            lda   MK_CMDP+1
            sta   PTR0+1
            lda   #<MK_CMDBUF
            sta   PTR1
            lda   #>MK_CMDBUF
            sta   PTR1+1
            clc
            lda   #<MK_CMDBUF
            adc   #<MK_CMDLIM
            sta   EXP_END
            lda   #>MK_CMDBUF
            adc   #>MK_CMDLIM
            sta   EXP_END+1
            stz   EXP_SEMI
            jmp   MK_EXPAND

*---------------------------------------------------------------
* MK_INTERN -- emit one internal macro. A holds its character.
*---------------------------------------------------------------
MK_INTERN   cmp   #$C0                 ;'@' -- the target
            beq   :target
            cmp   #$BC                 ;'<' -- the source
            beq   :source
            cmp   #$AA                 ;'*' -- the stem
            beq   :stem
*-- anything else is '?', the out-of-date prerequisites
            jmp   MK_EMITQ
:target     lda   MK_TGTP
            sta   PTR2
            lda   MK_TGTP+1
            sta   PTR2+1
            jmp   MK_EMITSTR
:source     lda   MK_SRCP
            sta   PTR2
            lda   MK_SRCP+1
            sta   PTR2+1
            jmp   MK_EMITSTR
*-- $* is the target with its suffix removed, and the stem is a
*-- LENGTH rather than a copy: there is no second buffer to keep
*-- in step, and the target string is right there.
:stem       lda   MK_STEML
            beq   :nostem
            sta   MK_SCNT
            lda   MK_TGTP
            sta   PTR2
            lda   MK_TGTP+1
            sta   PTR2+1
:scopy      lda   (PTR2)
            beq   :nostem
            jsr   MK_EMIT
            jsr   MK_TOKINC
            dec   MK_SCNT
            bne   :scopy
:nostem     rts

*---------------------------------------------------------------
* MK_EMITQ -- $?, the prerequisites that are out of date.
*
* COMPUTED, NOT REMEMBERED. It re-stats each dependency here
* rather than carrying a list built during the walk. That is the
* cheapest correct implementation in this arena -- no storage at
* all -- and on a volume where a GET_FILE_INFO costs 470,048
* cycles (docs/AS-PROFILE.md) it is also the reason not to put
* $? in a hot recipe.
*---------------------------------------------------------------
MK_EMITQ    lda   INF_ACTIVE
            beq   :walk
*-- in an inference rule there is exactly one prerequisite
            lda   MK_SRCP
            sta   PTR2
            lda   MK_SRCP+1
            sta   PTR2+1
            jmp   MK_EMITSTR
:walk       lda   MK_DEPN
            beq   :done
            sta   MK_QN
            stz   MK_QANY
            jsr   MK_DEPFRST
*-- MK_STATN preserves PTR0/PTR1/PTR2, which is what lets a stat
*-- happen in the middle of an expansion at all
:each       lda   PTR2
            sta   MK_FNAME
            lda   PTR2+1
            sta   MK_FNAME+1
            jsr   MK_STATN
            lda   MK_EXISTS
            beq   :skip
            ldy   #3
:cpd        lda   MK_STAMP,y
            sta   MK_DSTAMP,y
            dey
            bpl   :cpd
            jsr   MK_NEWER
            bcc   :skip
            lda   MK_QANY
            beq   :first
            lda   #$A0
            jsr   MK_EMIT
:first      inc   MK_QANY
            jsr   MK_EMITSTR           ;leaves PTR2 on the NUL
            bra   :advance
:skip       jsr   MK_SKIPP2
            bra   :advance2
:advance    jsr   MK_TOKINC            ;past the NUL
:advance2   dec   MK_QN
            bne   :each
:done       rts

*-- advance PTR2 past the NUL-terminated name it points at
MK_SKIPP2   lda   (PTR2)
            beq   :hit
            jsr   MK_TOKINC
            bra   MK_SKIPP2
:hit        jmp   MK_TOKINC

