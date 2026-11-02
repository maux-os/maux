*---------------------------------------------------------------
* expr.eval.s -- the `expr` engine: EXPR_EVAL/EXPR_EXITCD and
* the recursive-descent grammar behind them. Split out of
* src/bin/expr.s the same way TEST_EVAL is its own file
* (src/bin/testeval.s): a pure evaluator, no I/O of its own, so
* it can be `put` by more than one thing -- expr.s (the real
* spawnable binary, which owns `org`/`dsk`/`typ` and cannot
* itself be `put` into another image) AND src/test/exprtest.s's
* body, which calls EXPR_EVAL directly with a synthetic argv
* array, case-table style, same shape as check-testev's gate
* against TEST_EVAL. See expr.s's own header for the grammar,
* precedence, overflow-choice and exit-status documentation --
* this file is the implementation only.
*
* PRECONDITION ON THE INCLUDER: `put ../inc/zp.equ` and
* `put ../inc/mli.equ` before this file (PTR0/PTR1, U2DEC_VAL);
* `put ../liba/string.s` (STRCMP) and `put ../liba/num.s`
* (U2DEC) AFTER it -- same PUT-is-a-top-level-concern rule every
* other liba consumer in this tree follows (docs/TOOLCHAIN.md,
* commit 004bd02).
*---------------------------------------------------------------

EX_REL_LT   equ   0
EX_REL_EQ   equ   1
EX_REL_GT   equ   2

*---------------------------------------------------------------
* EXPR_EVAL -- evaluate an expr expression (the engine, no I/O).
* IN:  X = argc (operand count, NO argv[0] -- 0 is legal, and
*      is itself a syntax error, same as testeval's 0-arg case
*      being handled explicitly rather than by accident).
*      PTR0 = pointer to the argv array: X consecutive 2-byte
*      little-endian pointers, each to a NUL-terminated high-
*      bit-ASCII string (same shape as TEST_EVAL's own
*      contract).
* OUT: A = 0 (result ready in EX_RV_ISNM/EX_RV_NUM/EX_RV_PTR),
*      2 (syntax/range error), 3 (division or modulo by zero).
* CLOBBERS: A, X, Y, PTR0, PTR1 -- liba's shared pointer
*      scratch.
*---------------------------------------------------------------
EXPR_EVAL   stx   EX_ARGC
            lda   PTR0
            sta   EX_AVBASE
            lda   PTR0+1
            sta   EX_AVBASE+1
            stz   EX_POS
            stz   EX_STATUS
            stz   EX_SP
            jsr   EX_OR
            lda   EX_STATUS
            bne   :err
            lda   EX_POS
            cmp   EX_ARGC
            beq   :ok
            lda   #2
            sta   EX_STATUS
:err        lda   EX_STATUS
            rts
:ok         lda   #0
            rts

*---------------------------------------------------------------
* EXPR_EXITCD -- map the just-computed EX_RV to the POSIX 0/1
* exit code (only meaningful after EXPR_EVAL returned A=0).
* OUT: A = 0 (neither null nor 0) or 1 (null or 0).
*---------------------------------------------------------------
EXPR_EXITCD jsr   EX_ISFALS
            bcs   :one
            lda   #0
            rts
:one        lda   #1
            rts

*---------------------------------------------------------------
* EX_OR -- `|`. Left if truthy, else right.
*---------------------------------------------------------------
EX_OR       jsr   EX_AND
:loop       lda   EX_STATUS
            bne   :done
            jsr   EX_PEEK
            bcs   :done
            lda   #$FC             ;'|'
            jsr   EX_IS1CH
            bcs   :done
            inc   EX_POS
            jsr   EX_PUSHRV
            jsr   EX_AND
            jsr   EX_POPSV
            lda   EX_STATUS
            bne   :done
            jsr   EX_SVFALS
            bcs   :loop             ;left falsy -> RV (right) is
                                    ;already the correct result
            jsr   EX_SV2RV          ;left truthy -> keep it (SV)
            bra   :loop
:done       rts

*---------------------------------------------------------------
* EX_AND -- `&`. Left if BOTH truthy, else numeric 0.
*---------------------------------------------------------------
EX_AND      jsr   EX_CMP
:loop       lda   EX_STATUS
            bne   :done
            jsr   EX_PEEK
            bcs   :done
            lda   #$A6             ;'&'
            jsr   EX_IS1CH
            bcs   :done
            inc   EX_POS
            jsr   EX_PUSHRV
            jsr   EX_CMP
            jsr   EX_POPSV
            lda   EX_STATUS
            bne   :done
            jsr   EX_SVFALS
            bcs   :zero
            jsr   EX_ISFALS
            bcs   :zero
            jsr   EX_SV2RV          ;both truthy -> keep left
            bra   :loop
:zero       lda   #1
            sta   EX_RV_ISNM
            stz   EX_RV_NUM
            stz   EX_RV_NUM+1
            bra   :loop
:done       rts

*---------------------------------------------------------------
* EX_CMP -- `=` `!=` `<` `<=` `>` `>=`. Numeric if both operands
* are numeric, else lexicographic (string). Result always 0/1.
*---------------------------------------------------------------
EX_CMP      jsr   EX_ADD
:loop       lda   EX_STATUS
            bne   :done
            jsr   EX_PEEK
            bcs   :done
            jsr   EX_MCMP
            bcs   :done
            sta   EX_CMPOP
            inc   EX_POS
            jsr   EX_PUSHRV
            jsr   EX_ADD
            jsr   EX_POPSV
            lda   EX_STATUS
            bne   :done
            jsr   EX_DOCMP
            bra   :loop
:done       rts

*---------------------------------------------------------------
* EX_ADD -- `+` `-`.
*---------------------------------------------------------------
EX_ADD      jsr   EX_MUL
:loop       lda   EX_STATUS
            bne   :done
            jsr   EX_PEEK
            bcs   :done
            lda   #$AB             ;'+'
            jsr   EX_IS1CH
            bcc   :isadd
            lda   #$AD             ;'-'
            jsr   EX_IS1CH
            bcs   :done
            inc   EX_POS
            jsr   EX_PUSHRV
            jsr   EX_MUL
            jsr   EX_POPSV
            lda   EX_STATUS
            bne   :done
            jsr   EX_DOSUB
            bra   :loop
:isadd      inc   EX_POS
            jsr   EX_PUSHRV
            jsr   EX_MUL
            jsr   EX_POPSV
            lda   EX_STATUS
            bne   :done
            jsr   EX_DOADD
            bra   :loop
:done       rts

*---------------------------------------------------------------
* EX_MUL -- `*` `/` `%`.
*---------------------------------------------------------------
EX_MUL      jsr   EX_COL
:loop       lda   EX_STATUS
            bne   :done
            jsr   EX_PEEK
            bcs   :done
            lda   #$AA             ;'*'
            jsr   EX_IS1CH
            bcc   :ismul
            lda   #$AF             ;'/'
            jsr   EX_IS1CH
            bcc   :isdiv
            lda   #$A5             ;'%'
            jsr   EX_IS1CH
            bcs   :done
            inc   EX_POS
            jsr   EX_PUSHRV
            jsr   EX_COL
            jsr   EX_POPSV
            lda   EX_STATUS
            bne   :done
            jsr   EX_DOMOD
            bra   :loop
:ismul      inc   EX_POS
            jsr   EX_PUSHRV
            jsr   EX_COL
            jsr   EX_POPSV
            lda   EX_STATUS
            bne   :done
            jsr   EX_DOMUL
            bra   :loop
:isdiv      inc   EX_POS
            jsr   EX_PUSHRV
            jsr   EX_COL
            jsr   EX_POPSV
            lda   EX_STATUS
            bne   :done
            jsr   EX_DODIV
            bra   :loop
:done       rts

*---------------------------------------------------------------
* EX_PRIM -- one argv token: the operand. No operator-word
* exclusion -- a token that happens to spell an operator is
* only ever seen here if no enclosing level consumed it as one,
* and is then just a literal (permissive, position-driven
* grammar, same spirit as testeval's own leaf handling).
*---------------------------------------------------------------
EX_PRIM     lda   EX_POS
            cmp   EX_ARGC
            bcc   :have
            lda   #2
            sta   EX_STATUS
            lda   #1
            sta   EX_RV_ISNM
            stz   EX_RV_NUM
            stz   EX_RV_NUM+1
            rts
*-- '(' RECURSES TO THE TOP OF THE GRAMMAR, which is all a
*-- parenthesis is in a recursive-descent parser: the lowest
*-- rule calling the highest one. The precedence chain
*-- (EX_OR -> EX_AND -> EX_CMP -> EX_ADD -> EX_MUL -> here) is
*-- unchanged, and each nesting level costs one jsr frame.
*--
*-- A missing ')' is status 2, the same usage-shaped exit an
*-- expression that runs out of tokens already takes. It is NOT
*-- treated as end-of-expression: `expr ( 1 + 2` would otherwise
*-- quietly evaluate to 3 and tell the caller nothing went
*-- wrong, which is the class of silence this tree exists to
*-- close.
:have       jsr   EX_PEEK
            bcs   :notparen
            lda   #$A8             ;'('
            jsr   EX_IS1CH
            bcs   :notparen
            inc   EX_POS           ;eat the '('
            jsr   EX_OR
            lda   EX_STATUS
            bne   :prdone          ;already failed inside
            jsr   EX_PEEK
            bcs   :unbal
            lda   #$A9             ;')'
            jsr   EX_IS1CH
            bcs   :unbal
            inc   EX_POS           ;eat the ')'
:prdone     rts
:unbal      lda   #2
            sta   EX_STATUS
            lda   #1
            sta   EX_RV_ISNM
            stz   EX_RV_NUM
            stz   EX_RV_NUM+1
            rts
:notparen   jsr   EX_GETTOK
            inc   EX_POS
            jsr   EX_NPARSE
            bcs   :strval
            lda   #1
            sta   EX_RV_ISNM
            lda   EX_TMP
            sta   EX_RV_NUM
            lda   EX_TMP+1
            sta   EX_RV_NUM+1
            rts
:strval     stz   EX_RV_ISNM
            lda   PTR1
            sta   EX_RV_PTR
            lda   PTR1+1
            sta   EX_RV_PTR+1
            rts

*---------------------------------------------------------------
* EX_PEEK -- fetch the token at EX_POS into PTR1 WITHOUT
* advancing EX_POS. OUT: carry SET if EX_POS>=EX_ARGC (nothing
* left); carry CLEAR + PTR1 set otherwise.
*---------------------------------------------------------------
EX_PEEK     lda   EX_POS
            cmp   EX_ARGC
            bcc   :have
            sec
            rts
:have       jsr   EX_GETTOK
            clc
            rts

*---------------------------------------------------------------
* EX_GETTOK -- PTR1 = argv[EX_POS], from EX_AVBASE. Same
* reload-every-call shape as TEST_EVAL's own GETTOK, and for the
* same reason (PTR0 is shared scratch, not preserved).
*---------------------------------------------------------------
EX_GETTOK   lda   EX_POS
            asl   a
            tay
            lda   EX_AVBASE
            sta   PTR0
            lda   EX_AVBASE+1
            sta   PTR0+1
            lda   (PTR0),y
            sta   PTR1
            iny
            lda   (PTR0),y
            sta   PTR1+1
            rts

*---------------------------------------------------------------
* EX_IS1CH -- IN: A = expected single high-bit-ASCII char, PTR1
* = candidate token. OUT: carry CLEAR if the token is EXACTLY
* that one character; carry SET otherwise. Every non-comparison
* operator in this grammar is one character, so this replaces a
* whole match-table for those five.
*---------------------------------------------------------------
EX_IS1CH    sta   EX_TMPCH
            ldy   #0
            lda   (PTR1),y
            cmp   EX_TMPCH
            bne   :no
            iny
            lda   (PTR1),y
            bne   :no
            clc
            rts
:no         sec
            rts

*---------------------------------------------------------------
* EX_MCMP -- match a comparison operator token (PTR1, set by the
* caller's EX_PEEK). OUT: carry CLEAR + A = opcode (0='=' 1='!='
* 2='<' 3='<=' 4='>' 5='>=') on a match; carry SET otherwise.
* Same table-walk shape as TEST_EVAL's MATCH_BOP.
*---------------------------------------------------------------
EX_MCMP     ldx   #0
:loop       cpx   #6
            beq   :nomatch
            lda   EX_CMPLO,x
            sta   PTR0
            lda   EX_CMPHI,x
            sta   PTR0+1
            jsr   STRCMP
            cmp   #0
            beq   :found
            inx
            bra   :loop
:found      txa
            clc
            rts
:nomatch    sec
            rts

EX_CMPLO    dfb   <EX_S_EQ,<EX_S_NE,<EX_S_LT
            dfb   <EX_S_LE,<EX_S_GT,<EX_S_GE
EX_CMPHI    dfb   >EX_S_EQ,>EX_S_NE,>EX_S_LT
            dfb   >EX_S_LE,>EX_S_GT,>EX_S_GE
EX_S_EQ     asc   "="
            dfb   0
EX_S_NE     asc   "!="
            dfb   0
EX_S_LT     asc   "<"
            dfb   0
EX_S_LE     asc   "<="
            dfb   0
EX_S_GT     asc   ">"
            dfb   0
EX_S_GE     asc   ">="
            dfb   0

*---------------------------------------------------------------
* EX_PUSHRV / EX_POPSV -- stash the current "left" value (EX_RV)
* around a recursive call for the right operand, on a small
* SOFTWARE stack (EX_STK/EX_SP) in ordinary memory -- NOT the
* 6502 hardware stack. A first draft used PHA/PLA directly
* inside these two JSR'd routines, which is wrong: PHA pushes
* the caller's data ON TOP OF the return address JSR itself just
* pushed, so PUSHRV's own closing RTS pops that data back off as
* if it were a jump target instead of returning -- corrupts
* execution (a BRK-trap hang in src/test/exprtestb.s's own gate
* is what caught this). Max real depth is 5 (one push per
* grammar level -- EX_OR down to EX_MUL); EX_STK's 8-slot size
* is headroom, not a count some caller could ever fill.
*---------------------------------------------------------------
EX_PUSHRV   ldx   EX_SP
            lda   EX_RV_ISNM
            sta   EX_STK,x
            lda   EX_RV_NUM
            sta   EX_STK+1,x
            lda   EX_RV_NUM+1
            sta   EX_STK+2,x
            lda   EX_RV_PTR
            sta   EX_STK+3,x
            lda   EX_RV_PTR+1
            sta   EX_STK+4,x
            lda   EX_SP
            clc
            adc   #5
            sta   EX_SP
            rts

EX_POPSV    lda   EX_SP
            sec
            sbc   #5
            sta   EX_SP
            tax
            lda   EX_STK,x
            sta   EX_SV_ISNM
            lda   EX_STK+1,x
            sta   EX_SV_NUM
            lda   EX_STK+2,x
            sta   EX_SV_NUM+1
            lda   EX_STK+3,x
            sta   EX_SV_PTR
            lda   EX_STK+4,x
            sta   EX_SV_PTR+1
            rts

*---------------------------------------------------------------
* EX_SV2RV -- copy the saved/left value (EX_SV) over the
* current/right one (EX_RV) -- "the left operand wins".
*---------------------------------------------------------------
EX_SV2RV    lda   EX_SV_ISNM
            sta   EX_RV_ISNM
            lda   EX_SV_NUM
            sta   EX_RV_NUM
            lda   EX_SV_NUM+1
            sta   EX_RV_NUM+1
            lda   EX_SV_PTR
            sta   EX_RV_PTR
            lda   EX_SV_PTR+1
            sta   EX_RV_PTR+1
            rts

*---------------------------------------------------------------
* EX_ISFALS / EX_SVFALS -- "null or 0" test (POSIX `|`/`&`/exit-
* status rule), on EX_RV and EX_SV respectively. Numeric: falsy
* iff the 16-bit value is 0. String: falsy iff the string is
* empty, or is exactly "0" (unreachable in practice -- any
* string reading exactly "0" already classifies numeric at
* EX_PRIM -- kept for spec fidelity, belt and suspenders).
* OUT: carry SET if falsy, CLEAR if truthy. CLOBBERS: A, Y.
*---------------------------------------------------------------
EX_ISFALS   lda   EX_RV_ISNM
            beq   :str
            lda   EX_RV_NUM
            ora   EX_RV_NUM+1
            beq   :falsy
            clc
            rts
:str        lda   EX_RV_PTR
            sta   PTR1
            lda   EX_RV_PTR+1
            sta   PTR1+1
            bra   EX_FALSCK
:falsy      sec
            rts

EX_SVFALS   lda   EX_SV_ISNM
            beq   :str
            lda   EX_SV_NUM
            ora   EX_SV_NUM+1
            beq   :falsy
            clc
            rts
:str        lda   EX_SV_PTR
            sta   PTR1
            lda   EX_SV_PTR+1
            sta   PTR1+1
            bra   EX_FALSCK
:falsy      sec
            rts

*-- shared string-falsy check: PTR1 = string to test.
EX_FALSCK   ldy   #0
            lda   (PTR1),y
            beq   :falsy
:zl         cmp   #$B0             ;'0'
            bne   :truthy
            iny
            lda   (PTR1),y
            bne   :zl
:falsy      sec
            rts
:truthy     clc
            rts

*---------------------------------------------------------------
* EX_CMPNUM -- unsigned 16-bit compare, EX_SV_NUM (left) vs
* EX_RV_NUM (right). Same CMP16 shape as testeval.s: Z set iff
* equal, C set iff SV>=RV.
*---------------------------------------------------------------
EX_CMPNUM   lda   EX_SV_NUM+1
            cmp   EX_RV_NUM+1
            bne   :done
            lda   EX_SV_NUM
            cmp   EX_RV_NUM
:done       rts
