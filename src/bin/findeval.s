*---------------------------------------------------------------
* findeval.s -- find's expression EVALUATOR: TOK_PEEK/TOK_ADV,
* the EV_* software stack, and EVAL_EXPR/EVAL_TERM/EVAL_FACT/
* FACT_PRIM/EVAL_TOP/VALIDATE. Split out of findexpr.s at a
* GLOBAL boundary purely for the `as` source-window budget
* (docs/S9-PLAN.md section 5: resident + largest single `put`
* <= 16,128B) -- findexpr.s's own header carries the WHOLE
* engine's design (grammar, short-circuit, default -print, what
* -mtime/-newer/-size measure); this file is audited with it,
* one design, three `put` pieces. One assembly stream: put
* exactly where the text sat.
*---------------------------------------------------------------
*---------------------------------------------------------------
* TOK_PEEK -- CURTT/CURSIGN/CURVLO/CURVHI := TOKTYPE/TOKSIGN/
* TOKVLO/TOKVHI[TOKI], without advancing. CLOBBERS: A, Y.
* TOK_ADV -- TOKI += 1.
*---------------------------------------------------------------
TOK_PEEK    ldy   TOKI
            lda   TOKTYPE,y
            sta   CURTT
            lda   TOKSIGN,y
            sta   CURSIGN
            lda   TOKVLO,y
            sta   CURVLO
            lda   TOKVHI,y
            sta   CURVHI
            rts
TOK_ADV     inc   TOKI
            rts

*---------------------------------------------------------------
* EV_ENTER/EV_LEAVE/EV_GETACT/EV_SETRES/EV_GETRES -- the
* explicit per-call-frame software stack every one of EVAL_EXPR/
* EVAL_TERM/EVAL_FACT opens on entry and closes just before its
* own RTS. See this file's header for why a flat dum byte cannot
* do this job. EVALSP always names the next FREE slot; a frame
* is 2 bytes, {active, result}, at EVALSP-2/EVALSP-1.
*---------------------------------------------------------------
EV_ENTER    ldy   EVALSP
            sta   EVALSTACK,y
            iny
            lda   #0
            sta   EVALSTACK,y
            iny
            sty   EVALSP
            rts
EV_LEAVE    lda   EVALSP
            sec
            sbc   #2
            sta   EVALSP
            rts
EV_GETACT   ldy   EVALSP
            dey
            dey
            lda   EVALSTACK,y
            rts
EV_SETRES   ldy   EVALSP
            dey
            sta   EVALSTACK,y
            rts
EV_GETRES   ldy   EVALSP
            dey
            lda   EVALSTACK,y
            rts

*---------------------------------------------------------------
* EVAL_EXPR -- expr := term { -o term }. IN: A=active.
* OUT: A=result(0/1). CLOBBERS: everything.
*---------------------------------------------------------------
EVAL_EXPR   jsr   EV_ENTER
            jsr   EV_GETACT
            jsr   EVAL_TERM
            jsr   EV_SETRES
:exloop     jsr   TOK_PEEK
            lda   CURTT
            cmp   #TT_OR
            bne   :exdone
            jsr   TOK_ADV
            jsr   EV_GETRES
            bne   :exshortc
            jsr   EV_GETACT
            bra   :excallf
:exshortc   lda   #0
:excallf    jsr   EVAL_TERM
            tax
            jsr   EV_GETRES
            cpx   #0
            beq   :exkeep
            lda   #1
:exkeep     jsr   EV_SETRES
            jmp   :exloop
:exdone     jsr   EV_GETRES
            pha
            jsr   EV_LEAVE
            pla
            rts

*---------------------------------------------------------------
* EVAL_TERM -- term := factor { [-a] factor } (an explicit -a is
* consumed and otherwise a no-op; any other factor-starting
* token begins an IMPLICIT and). IN: A=active. OUT: A=result.
* CLOBBERS: everything.
*---------------------------------------------------------------
EVAL_TERM   jsr   EV_ENTER
            jsr   EV_GETACT
            jsr   EVAL_FACT
            jsr   EV_SETRES
:tmloop     jsr   TOK_PEEK
            lda   CURTT
            cmp   #TT_AND
            bne   :tmchkim
            jsr   TOK_ADV
            bra   :tmnext
:tmchkim    cmp   #TT_OR
            beq   :tmdone
            cmp   #TT_RPAR
            beq   :tmdone
            cmp   #TT_END
            beq   :tmdone
:tmnext     jsr   EV_GETRES
            beq   :tmshortc
            jsr   EV_GETACT
            bra   :tmcallf
:tmshortc   lda   #0
:tmcallf    jsr   EVAL_FACT
            tax
            jsr   EV_GETRES
            cpx   #0
            bne   :tmkeep
            lda   #0
:tmkeep     jsr   EV_SETRES
            jmp   :tmloop
:tmdone     jsr   EV_GETRES
            pha
            jsr   EV_LEAVE
            pla
            rts

*---------------------------------------------------------------
* EVAL_FACT -- factor := '!' factor | '(' expr ')' | primary.
* IN: A=active. OUT: A=result. An unmatched '(' (no closing ')')
* or a stray operator/end token in factor position sets
* PARSEBAD -- caught once, at parse time, by VALIDATE. CLOBBERS:
* everything.
*---------------------------------------------------------------
EVAL_FACT   jsr   EV_ENTER
            jsr   TOK_PEEK
            lda   CURTT
            cmp   #TT_NOT
            bne   :fnotnot
            jsr   TOK_ADV
            jsr   EV_GETACT
            jsr   EVAL_FACT
            eor   #1
            jsr   EV_SETRES
            bra   :fdone
:fnotnot    cmp   #TT_LPAR
            bne   :fnotlp
            jsr   TOK_ADV
            jsr   EV_GETACT
            jsr   EVAL_EXPR
            jsr   EV_SETRES
            jsr   TOK_PEEK
            lda   CURTT
            cmp   #TT_RPAR
            beq   :flpok
            lda   #1
            sta   PARSEBAD
            bra   :fdone
:flpok      jsr   TOK_ADV
            bra   :fdone
:fnotlp     jsr   FACT_PRIM
:fdone      jsr   EV_GETRES
            pha
            jsr   EV_LEAVE
            pla
            rts

*---------------------------------------------------------------
* FACT_PRIM -- the primary-token branch of EVAL_FACT, split out
* for the line-length budget. IN: CURTT/CURSIGN/CURVLO/CURVHI
* already peeked (by EVAL_FACT); shares EVAL_FACT's OWN frame
* (does not open one of its own -- every path ends in EV_SETRES
* against that frame). An unrecognized token sets PARSEBAD and
* does NOT advance TOKI (so the caller's loop halts on it).
* CLOBBERS: everything.
*---------------------------------------------------------------
FACT_PRIM   lda   CURTT
            cmp   #TT_NAME
            bne   :fpc1
            jmp   :fpname
:fpc1       cmp   #TT_TYPE
            bne   :fpc2
            jmp   :fptype
:fpc2       cmp   #TT_PATH
            bne   :fpc3
            jmp   :fppath
:fpc3       cmp   #TT_NEWER
            bne   :fpc4
            jmp   :fpnewer
:fpc4       cmp   #TT_MTIME
            bne   :fpc5
            jmp   :fpmtime
:fpc5       cmp   #TT_SIZEB
            bne   :fpc6
            jmp   :fpsizeb
:fpc6       cmp   #TT_SIZEC
            bne   :fpc7
            jmp   :fpsizec
:fpc7       cmp   #TT_LINKS
            bne   :fpc8
            jmp   :fplinks
:fpc8       cmp   #TT_XDEV
            bne   :fpc9
            jmp   :fptrue
:fpc9       cmp   #TT_NOUSER
            bne   :fpc10
            jmp   :fptrue
:fpc10      cmp   #TT_NOGROUP
            bne   :fpc11
            jmp   :fptrue
:fpc11      cmp   #TT_PRINT
            bne   :fpc12
            jmp   :fpprint
:fpc12      cmp   #TT_PRUNE
            bne   :fpc13
            jmp   :fpprune
:fpc13      cmp   #TT_EXEC
            beq   :fpxjmp
            cmp   #TT_OK
            bne   :fpc13b
:fpxjmp     jmp   :fpexec
:fpc13b     cmp   #TT_DEPTH
            bne   :fpc14
            jmp   :fptrue
:fpc14      lda   #1
            sta   PARSEBAD
            lda   #0
            jmp   EV_SETRES
:fptrue     jsr   TOK_ADV
            lda   #1
            jmp   EV_SETRES
:fpname     jsr   TOK_ADV
            jsr   EV_GETACT
            bne   :fpok1
            jmp   :fpfalse
:fpok1      jsr   TESTNAME
            jmp   EV_SETRES
:fptype     jsr   TOK_ADV
            jsr   EV_GETACT
            bne   :fpok2
            jmp   :fpfalse
:fpok2      jsr   TESTTYPE
            jmp   EV_SETRES
:fppath     jsr   TOK_ADV
            jsr   EV_GETACT
            bne   :fpok3
            jmp   :fpfalse
:fpok3      jsr   TESTPATH
            jmp   EV_SETRES
:fpnewer    jsr   TOK_ADV
            jsr   EV_GETACT
            bne   :fpok4
            jmp   :fpfalse
:fpok4      jsr   TESTNEWER
            jmp   EV_SETRES
:fpmtime    jsr   TOK_ADV
            jsr   EV_GETACT
            bne   :fpok5
            jmp   :fpfalse
:fpok5      jsr   TESTMTIME
            jmp   EV_SETRES
:fpsizeb    jsr   TOK_ADV
            jsr   EV_GETACT
            bne   :fpok6
            jmp   :fpfalse
:fpok6      lda   #0
            jsr   TESTSIZE
            jmp   EV_SETRES
:fpsizec    jsr   TOK_ADV
            jsr   EV_GETACT
            bne   :fpok7
            jmp   :fpfalse
:fpok7      lda   #1
            jsr   TESTSIZE
            jmp   EV_SETRES
:fplinks    jsr   TOK_ADV
            jsr   EV_GETACT
            bne   :fpok8
            jmp   :fpfalse
:fpok8      jsr   TESTLINKS
            jmp   EV_SETRES
:fpprint    jsr   TOK_ADV
            jsr   EV_GETACT
            beq   :fpskipa
            jsr   ACT_PRINT
:fpskipa    lda   #1
            jmp   EV_SETRES
:fpprune    jsr   TOK_ADV
            jsr   EV_GETACT
            beq   :fpskipp
            lda   #1
            sta   PRUNEFLAG
:fpskipp    lda   #1
            jmp   EV_SETRES
:fpexec     jsr   TOK_ADV
            lda   CURVLO
            sta   EXECSLOT
            ldx   #0                 ;-ok: -exec, asks first
            lda   CURTT
            cmp   #TT_OK
            bne   :fpxok
            inx
:fpxok      stx   OKFLAG
            jsr   EV_GETACT
            beq   :fpskipe
            jsr   ACT_EXEC
            jmp   EV_SETRES
:fpskipe    lda   #1
            jmp   EV_SETRES
:fpfalse    lda   #0
            jmp   EV_SETRES

*---------------------------------------------------------------
* EVAL_TOP -- WALK's own entry point (findtop.s): evaluate the
* WHOLE parsed expression against ONE visited path and perform
* every action it triggers -- this call IS the filtering AND the
* action, not a filter WALK then acts on. IN: A=isdir(1/0),
* PTR0=full path ptr, PTR1=basename ptr. OUT: none -- WALK
* reads PRUNEFLAG itself right after this returns. CLOBBERS:
* everything.
*---------------------------------------------------------------
EVAL_TOP    sta   AF_ISDIR
            lda   PTR0
            sta   EVPATH
            lda   PTR0+1
            sta   EVPATH+1
            lda   PTR1
            sta   EVBASE
            lda   PTR1+1
            sta   EVBASE+1
            stz   PRUNEFLAG
            stz   TOKI
*-- POSIX: "If no expression is present, -print shall be used
*-- as the expression" -- a DIFFERENT rule from the "does not
*-- contain -exec/-print" default-print-APPEND rule below, and
*-- the grammar itself has no empty-expression production (every
*-- one of expr/term/factor requires at least one factor), so
*-- NTOK=0 has to be caught HERE, before EVAL_EXPR ever runs,
*-- not threaded through it.
            lda   NTOK
            bne   :evhave
            jsr   ACT_PRINT
            rts
:evhave     lda   #1
            jsr   EVAL_EXPR
            pha
            lda   ANYACTION
            bne   :evdone
            pla
            beq   :evdone2
            jsr   ACT_PRINT
            rts
:evdone     pla
:evdone2    rts

*---------------------------------------------------------------
* VALIDATE -- the dry run (TOKENIZE's own caller, PARSE in
* findtop.s, runs this once right after TOKENIZE): EVAL_EXPR
* with active=0 from TOKI=0, which can never touch the
* filesystem. A well-formed expression sets PARSEBAD=0 and
* consumes every token through TT_END. Does not return on
* failure (USAGE_ERR, exit 2). CLOBBERS: everything.
*---------------------------------------------------------------
VALIDATE    lda   NTOK
            bne   :vgo
            rts                  ;no expression at all -- see
                                 ;EVAL_TOP's own NTOK=0 note
:vgo        stz   TOKI
            stz   PARSEBAD
            lda   #0
            jsr   EVAL_EXPR
            lda   PARSEBAD
            bne   :vbad
            lda   TOKI
            cmp   NTOK
            bne   :vbad
            rts
:vbad       jmp   USAGE_ERR

