*---------------------------------------------------------------
* exprcases.s -- MAUXEXPR's Phase-1 case table, argv arrays and
* token strings, assembled ALONE at $1800 (no includes: pure
* data) and staged on the expr image as /mnt/MAUX/EXPRCASES by
* scripts/build_expr_image.py. exprtestb.s's LOAD_CASES READs
* the file into $1800 of the harness's own bank before Phase 1,
* so every `da` below is valid exactly as assembled.
*
* Moved out of exprtestb.s 2026-09-12: MAUXEXPR.SYSTEM sat 31 B
* under PMLI_IBF_BASE and each kernel byte tripped
* check-kernel-images -- this is ~430 B of constant data the
* image carried for no reason (same retirement build_ed_image.py
* 's FIXTURES did for MAUXEDTEST). NCASE here MUST equal
* exprtestb.s's (its `err` pins the row count to it; the
* harness checks the READ transferred at least NCASE*4 bytes).
*---------------------------------------------------------------
            org   $1800
            dsk   ../../build/exprcases.bin
NCASE       equ   37
ROWS_LEN    equ   148            ;NCASE*4 -- merlin32 has no
                                 ;operator precedence, so the
                                 ;err below cannot say NCASE*4

*---------------------------------------------------------------
* Case table -- 4 bytes/row (was 8, 2026-09-12: 148B bought back
* for the VT102 slice-6 kernel growth, PMLI_IBF_BASE margin):
* argv array ptr (lo,hi); a FLAGS byte = argc<<4 | expected
* EXPR_EXITCD (0/1)<<3 | "check the numeric result" (0=skip,
* 1=check)<<2 | expected EXPR_EVAL status (0/2/3); expected
* EX_RV_NUM's LOW byte (every checked result is < 256; the
* high byte is asserted 0). Every operator, both outcomes per
* comparison, precedence both directions, overflow (add/sub/mul/
* literal), division and modulo by zero, non-numeric operand to
* arithmetic, string comparison, malformed expressions, 0 args.
* Every expectation below is derived BY HAND (task brief) --
* none of it was produced by running expr and recording output.
*---------------------------------------------------------------
CASES
            da    AV_OR_LT
            dfb   $34,3
            da    AV_OR_LF
            dfb   $34,5
            da    AV_OR_BF
            dfb   $3C,0
            da    AV_AND_BT
            dfb   $34,3
            da    AV_AND_LF
            dfb   $3C,0
            da    AV_AND_RF
            dfb   $3C,0
            da    AV_EQ_T
            dfb   $34,1
            da    AV_EQ_F
            dfb   $3C,0
            da    AV_NE_T
            dfb   $34,1
            da    AV_NE_F
            dfb   $3C,0
            da    AV_LT_T
            dfb   $34,1
            da    AV_LT_F
            dfb   $3C,0
            da    AV_LE_T
            dfb   $34,1
            da    AV_LE_F
            dfb   $3C,0
            da    AV_GT_T
            dfb   $34,1
            da    AV_GT_F
            dfb   $3C,0
            da    AV_GE_T
            dfb   $34,1
            da    AV_GE_F
            dfb   $3C,0
            da    AV_PREC1
            dfb   $54,14
            da    AV_PREC2
            dfb   $54,10
            da    AV_SUB1
            dfb   $34,7
            da    AV_SUBZERO
            dfb   $3C,0
            da    AV_SUB_UF
            dfb   $32,0
            da    AV_MUL1
            dfb   $34,42
            da    AV_MUL_OF
            dfb   $32,0
            da    AV_DIV1
            dfb   $34,3
            da    AV_MOD1
            dfb   $34,1
            da    AV_DIVZ
            dfb   $33,0
            da    AV_MODZ
            dfb   $33,0
            da    AV_ADD_OF
            dfb   $32,0
            da    AV_NONNUM
            dfb   $32,0
            da    AV_STREQ_T
            dfb   $34,1
            da    AV_STREQ_F
            dfb   $3C,0
            da    AV_STRLT_T
            dfb   $34,1
            da    AV_ORSTR
            dfb   $30,0
            da    AV_MALF2
            dfb   $22,0
            da    AV_EMPTY0
            dfb   $02,0
CASES_END
            err   CASES_END-CASES-ROWS_LEN
*-- NCASE: hoisted above its first use (EQU burn-down).

*---------------------------------------------------------------
* argv arrays -- each a run of 2-byte token pointers
* (EXPR_EVAL's own argv[0]-free convention).
*---------------------------------------------------------------
AV_OR_LT    da    P_3,P_OR,P_4
AV_OR_LF    da    P_0,P_OR,P_5
AV_OR_BF    da    P_0,P_OR,P_0
AV_AND_BT   da    P_3,P_AND,P_4
AV_AND_LF   da    P_0,P_AND,P_4
AV_AND_RF   da    P_4,P_AND,P_0
AV_EQ_T     da    P_3,P_EQ,P_3
AV_EQ_F     da    P_3,P_EQ,P_4
AV_NE_T     da    P_3,P_NE,P_4
AV_NE_F     da    P_3,P_NE,P_3
AV_LT_T     da    P_3,P_LT,P_4
AV_LT_F     da    P_4,P_LT,P_3
AV_LE_T     da    P_3,P_LE,P_3
AV_LE_F     da    P_4,P_LE,P_3
AV_GT_T     da    P_4,P_GT,P_3
AV_GT_F     da    P_3,P_GT,P_4
AV_GE_T     da    P_3,P_GE,P_3
AV_GE_F     da    P_3,P_GE,P_4
AV_PREC1    da    P_2,P_PLUS,P_3,P_STAR,P_4
AV_PREC2    da    P_2,P_STAR,P_3,P_PLUS,P_4
AV_SUB1     da    P_10,P_MINUS,P_3
AV_SUBZERO  da    P_3,P_MINUS,P_3
AV_SUB_UF   da    P_3,P_MINUS,P_10
AV_MUL1     da    P_6,P_STAR,P_7
AV_MUL_OF   da    P_100,P_STAR,P_1000
AV_DIV1     da    P_7,P_SLASH,P_2
AV_MOD1     da    P_7,P_PCT,P_2
AV_DIVZ     da    P_5,P_SLASH,P_0
AV_MODZ     da    P_5,P_PCT,P_0
AV_ADD_OF   da    P_65535,P_PLUS,P_1
AV_NONNUM   da    P_ABC,P_PLUS,P_3
AV_STREQ_T  da    P_FOO,P_EQ,P_FOO2
AV_STREQ_F  da    P_FOO,P_EQ,P_BAR
AV_STRLT_T  da    P_ABC,P_LT,P_ABD
AV_ORSTR    da    P_FOO,P_OR,P_BAR
AV_MALF2    da    P_3,P_4
AV_EMPTY0   da    0

*---------------------------------------------------------------
* Token strings -- high-bit ASCII, NUL-terminated.
*---------------------------------------------------------------
P_0         asc   "0"
            dfb   0
P_1         asc   "1"
            dfb   0
P_2         asc   "2"
            dfb   0
P_3         asc   "3"
            dfb   0
P_4         asc   "4"
            dfb   0
P_5         asc   "5"
            dfb   0
P_6         asc   "6"
            dfb   0
P_7         asc   "7"
            dfb   0
P_10        asc   "10"
            dfb   0
P_42        asc   "42"
            dfb   0
P_100       asc   "100"
            dfb   0
P_1000      asc   "1000"
            dfb   0
P_65535     asc   "65535"
            dfb   0
P_ABC       asc   "abc"
            dfb   0
P_ABD       asc   "abd"
            dfb   0
P_FOO       asc   "foo"
            dfb   0
P_FOO2      asc   "foo"
            dfb   0
P_BAR       asc   "bar"
            dfb   0
P_OR        asc   "|"
            dfb   0
P_AND       asc   "&"
            dfb   0
P_EQ        asc   "="
            dfb   0
P_NE        asc   "!="
            dfb   0
P_LT        asc   "<"
            dfb   0
P_LE        asc   "<="
            dfb   0
P_GT        asc   ">"
            dfb   0
P_GE        asc   ">="
            dfb   0
P_PLUS      asc   "+"
            dfb   0
P_MINUS     asc   "-"
            dfb   0
P_STAR      asc   "*"
            dfb   0
P_SLASH     asc   "/"
            dfb   0
P_PCT       asc   "%"
            dfb   0
