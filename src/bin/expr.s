*---------------------------------------------------------------
* expr.s -- the `expr` expression evaluator (docs/SH-SUBSET.md
* sec 4: `$(( ))` is POSIX-era, ruled OUT of `sh`; `expr` is the
* period-correct V6-fleet answer and costs `sh` nothing since it
* is a separate binary). Usage: expr ARG...
*
* The engine (EXPR_EVAL/EXPR_EXITCD and the whole recursive-
* descent grammar) lives in src/bin/expr.eval.s, put below --
* same split as src/bin/testeval.s (a pure evaluator, no I/O of
* its own): src/test/exprtest.s's body calls EXPR_EVAL directly
* with a synthetic argv array, case-table style, same shape as
* check-testev's own gate. This file is the thin I/O glue: adapt
* the real per-process ARGC/ARGV (argv[0] = own name, confirmed
* by getopt.s's OPTINIT and echo.s's own header) down to
* EXPR_EVAL's argv[0]-free convention, print the result, map to
* the POSIX exit status.
*
* GRAMMAR, POSIX precedence order (lowest first), recursive
* descent, one level per precedence tier (expr.eval.s):
*   EX_OR   `|`                lowest
*   EX_AND  `&`
*   EX_CMP  `=` `!=` `<` `<=` `>` `>=`
*   EX_ADD  `+` `-`
*   EX_MUL  `*` `/` `%`
*   EX_COL  `:`                highest (expr.match.s)
*   EX_PRIM one argv token (the operand)
* Each level parses its own left operand by calling the next
* level down, then loops consuming same-precedence operators;
* the operand for `*`/`/` is a single EX_MUL call from EX_ADD's
* loop, so `2 + 3 * 4` computes 3*4 FIRST -- EX_MUL never runs
* left-to-right across a `+`. src/test/exprtest.s case PREC1
* proves this both ways (`2+3*4`=14, `2*3+4`=10).
*
* PARENTHESES: IN (2026-09-21). A parenthesis is the lowest rule
* calling the highest one: EX_PRIM recurses to EX_OR, and a
* missing `)` is status 2 (expr.eval.s's EX_PRIM has the
* whole account).
*
* NUMBERS: unsigned 16-bit only (0-65535), matching U2DEC and
* the rest of the tree. OVERFLOW CHOICE: LOUD ERROR (status 2,
* "invalid expression"), never silent wraparound -- chosen
* because a wrong answer that LOOKS plausible is the failure
* mode this project treats as worst (task brief). This differs
* from testeval.s's STR2NUM, which wraps silently by its own
* header's admission ("undocumented by POSIX... not needed by
* scripts on this machine") -- `test` only compares, `expr`
* computes and PRINTS a number, where a silent wrap is far more
* likely to look like a real (wrong) answer. Overflow is
* detected at THREE points (all in expr.eval.s): parsing a
* literal too large to fit (EX_NPARSE, threshold-checked digit
* by digit, never lets the accumulator itself overflow); `+`
* producing a carry out of bit 15 (EX_DOADD); `*` producing a
* nonzero high 16 bits of the full 32-bit product (EX_DOMUL, a
* real 16x16->32 shift-add, not a truncating multiply). `-` is
* UNSIGNED-only (no negative literals): SV<RV is also status 2,
* not two's-complement wraparound to a huge positive number, for
* the same reason. `/` and `%` cannot overflow (result <=
* dividend); divisor 0 is status 3, not 2 -- see below.
*
* EXIT STATUS, POSIX (note the inverted sense -- 0 means the
* result was neither null nor 0):
*   0  result computed, and it is neither the null string nor 0
*   1  result computed, and it IS the null string or 0
*   2  invalid expression (syntax error, non-numeric operand
*      to an arithmetic op, missing/extra operand, RANGE
*      OVERFLOW -- see above)
*   3  internal error -- division or modulo by zero only
* Division by zero: diagnostic to fd 2, exit 3.
*
* THE `:` MATCHING OPERATOR (SHIPPED 2026-10-08): expr.match.s,
* which links the house BRE engine (liba regex.s + regex2.s, the
* one grep/sed use). Anchored at the start of the left string;
* the result is the match length, or \( \)'s first group text.
* expr.match.s's header has the whole contract.
*
* OUT OF SCOPE, deliberately (task brief): `match`/`substr`/
* `index`/`length` (expr's STRING half -- can come later if
* wanted).
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*
* DIRECT-SPAWN GATE (`make check-expr` phase 2, src/test/
* exprtestb.s): this binary is spawned directly (no `sh`) with
* argv "2","*","3" and its stdout captured, proving the literal
* `*` survives without shell quoting. A first attempt at this
* phase hit a kernel ERR_INVAL that wasn't pinned down in time
* and was dropped; the root cause was CWD_READ (src/kernel/
* sched.s) reading the shared per-pid cwd table through whatever
* RamWorks bank was last selected instead of aux bank 0 -- see
* that routine's header for the full account. Fixed; the phase
* is back and passing.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/expr.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/regex.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

*---------------------------------------------------------------
* START -- process entry. ARGC/ARGV include argv[0] (the
* program's own name -- getopt.s's OPTINIT: "argv[0] is the
* name"; echo.s's own header says the same). EXPR_EVAL's own
* convention has NO argv[0] (same as TEST_EVAL's), so the real
* args start one slot in: X = ARGC-1, PTR0 -> ARGV+2. ARGC=0 (no
* argv at all -- PSTG_ARGV's documented NULL-argv edge case) is
* guarded so X never underflows to 255.
*---------------------------------------------------------------
START       lda   ARGC
            bne   :haveav
            ldx   #0
            bra   :call
:haveav     sec
            sbc   #1
            tax
:call       lda   #<ARGV+2
            sta   PTR0
            lda   #>ARGV+2
            sta   PTR0+1
            jsr   EXPR_EVAL
            cmp   #2
            beq   :synerr
            cmp   #3
            beq   :divzero

            ;-- status 0: print the result, then map to 0/1.
            lda   EX_RV_ISNM
            beq   :prstr
            lda   EX_RV_NUM
            sta   U2DEC_VAL
            lda   EX_RV_NUM+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            bra   :cr
:prstr      lda   EX_RV_PTR
            sta   PTR0
            lda   EX_RV_PTR+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
:cr         lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   EXPR_EXITCD
            jsr   EXIT

:synerr     lda   #<E_SYNTAX
            sta   PTR0
            lda   #>E_SYNTAX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

:divzero    lda   #<E_DIVZERO
            sta   PTR0
            lda   #>E_DIVZERO
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #3
            jsr   EXIT

E_SYNTAX    asc   "expr: invalid expression"
            dfb   0
E_DIVZERO   asc   "expr: division by zero"
            dfb   0

            put   expr.eval.s
            put   expr.ops.s
            put   expr.match.s

            put   ../liba/string.s
            put   ../liba/regex.s
            put   ../liba/regex2.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s
            put   ../liba/regexbss.s

*---------------------------------------------------------------
* expr.match.s's scratch -- `dum`/`dend` at the TEXTUAL END,
* chained onto REGEX_BSSEND (learning:01M28FXZHBN4V6T4NT6PZZ4M4S
* -- a program that puts regexbss.s anchors HERE, not at
* LIBA_BSSEND).
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21), and nothing
* needs it to: EX_MLT and EX_MRT are `sta`'d by EX_COL before
* EX_DOMATCH reads them, EX_MTXT/EX_MPAT/EX_MGRP by EX_DOMATCH
* itself before its own reads, and EX_SBUFB by U2DEC before
* RE_MATCH sees the pattern it holds.
*---------------------------------------------------------------
            dum   REGEX_BSSEND
EX_SBUFB    ds    7        ;the pattern's stringify scratch
EX_MLT      ds    1        ;left operand's argv index, or $FF
EX_MRT      ds    1        ;right operand's, ditto
EX_MTXT     ds    2        ;the text being matched
EX_MPAT     ds    2        ;the BRE
EX_MGRP     ds    1        ;1 = the BRE holds a \( \)
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window (see src/bin/cut.s).
            err   */$BF00
            dend
