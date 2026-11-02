*---------------------------------------------------------------
* testevtestb.s -- image body for testevtest.s. Same boot
* machinery as catreadtestb.s (single process synthesized into
* bank 1, real syscalls live) -- see that file's header. The
* difference: PARENT_PROC here never spawns a child. It runs a
* CASE TABLE against TEST_EVAL directly, glob-test style
* (src/test/globtest.s), staging results at R_RESULTS/R_NCASES/
* R_DONE in bank 1's low memory. TEST_EVAL, and everything it
* calls (MKPATH/STRCMP/SC_GFI), is `put` INSIDE PARENT_PROC's
* own span below so BOOT_CPY_PAR's byte-copy carries it into
* bank 1 too -- code living outside that span never runs there.
*---------------------------------------------------------------

*-- Hoisted above first use (S9 EQU burn-down 2026-08-29).
NCASE       equ   61

R_RESULTS   equ   $1200      ;NCASE bytes, one per case
*-- R_NCASES/R_DONE must sit PAST R_RESULTS+NCASE (61 bytes,
*-- $1200-$123C) -- they used to be $1230/$1231, inside that
*-- span back when NCASE was 40, and the fill/store loop
*-- clobbered them mid-run once NCASE grew (found via
*-- check-testev: two rows at exactly those byte offsets came
*-- back "never ran"). $1240/$1241 leave headroom past $123C.
R_NCASES    equ   $1240
R_DONE      equ   $1241

*---------------------------------------------------------------
* Boot helpers -- identical shape to catreadtestb.s's own.
*---------------------------------------------------------------
BOOT_CPY_PAR
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PARENT_PROC
            sta   K_BC_SRCADDR
            lda   #>PARENT_PROC
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #<PARENT_PROC
            sta   K_BC_DSTADDR
            lda   #>PARENT_PROC
            sta   K_BC_DSTADDR+1
            lda   #1
            sta   K_BC_DSTBANK
            lda   #<PAR_PROC_LEN
            sta   K_BC_LEN
            lda   #>PAR_PROC_LEN
            sta   K_BC_LEN+1
            jsr   BankCopy
            rts

PATCH_PAR_FRM
            lda   #1
            sta   BANKSEL
            sta   ALTZPAUX
            lda   #<PARENT_PROC
            sta   $01FE
            lda   #>PARENT_PROC
            sta   $01FF
            sta   ALTZPMAIN
            rts

NOIRQ       rts

ENTRY       sei
            cld
            ldx   #$FF
            txs

            ldy   #0
:banner     lda   BANNER,y
            sta   $0400,y
            iny
            cpy   #BANNER_END-BANNER
            bne   :banner

            jsr   INSTALL_COPY
            lda   #<NOIRQ
            sta   K_IRQ_HOOK
            lda   #>NOIRQ
            sta   K_IRQ_HOOK+1
            jsr   SCH_INIT
            lda   #1                       ;gates pin 40 cols:
            sta   TTY_BKND_REQ             ;auto = best 80 now
            jsr   PRC_INIT

            lda   #1
            jsr   PRC_STMP_BANK
            lda   #1
            jsr   PRC_SYNTH_FRM
            jsr   PATCH_PAR_FRM
            jsr   BOOT_CPY_PAR

            lda   #1
            ldx   #1
            jsr   SCH_CREATE
            jsr   SCH_START

BANNER      asc   "MAUX TESTEV"
BANNER_END

* PTR0/PCOUNT_GFI/STYP_DIR etc come from ../inc/zp.equ and
* ../inc/mli.equ -- put at TOP LEVEL by testevtest.s (merlin32
* does not support a `put` nested inside a `put`ed file), same
* reason TEST_EVAL's own liba dependencies are put there too,
* AFTER this file, so PAR_PROC_LEN's span covers all of it.

*---------------------------------------------------------------
* PARENT_PROC -- copied verbatim to the same address in bank 1
* (BOOT_CPY_PAR above), same reason catreadtestb.s's own
* PARENT_PROC is: absolute JSR/JMP operands to the code below,
* including into TEST_EVAL itself, must resolve post-copy.
*---------------------------------------------------------------
PARENT_PROC
            ldx   #0
:fill       lda   #$EE
            sta   R_RESULTS,x
            inx
            cpx   #NCASE
            bne   :fill

            stz   CASEI
:caselp     lda   CASEI
            cmp   #NCASE
            bcs   :alldone
            asl   a
            asl   a
            tax
            lda   CASES,x
            sta   PTR0
            lda   CASES+1,x
            sta   PTR0+1
            lda   CASES+2,x
            sta   CARGC
            lda   CASES+3,x
            sta   CWANT
            ldx   CARGC
            jsr   TEST_EVAL
            cmp   CWANT
            beq   :pass
            lda   #0
            bra   :storeit
:pass       lda   #1
:storeit    ldy   CASEI
            sta   R_RESULTS,y
            inc   CASEI
            jmp   :caselp
:alldone    lda   #NCASE
            sta   R_NCASES
            lda   #$AA
            sta   R_DONE
:park       bra   :park

CASEI       ds    1
CARGC       ds    1
CWANT       ds    1

*---------------------------------------------------------------
* The case table -- 4 bytes/row: argv array ptr (lo,hi), argc,
* want (0=true 1=false 2=syntax error). Every operator, both
* outcomes; a nonexistent path for -f/-d/-e; both non-numeric
* operand positions; `!` over bare-word/unary/binary; the
* 1-arg bare-word form both ways; two malformed shapes; argc=0.
*---------------------------------------------------------------
CASES
            da    AV_F_EXIST
            dfb   2,0
            da    AV_F_ISDIR
            dfb   2,1
            da    AV_F_NOPE
            dfb   2,1
            da    AV_D_ISDIR
            dfb   2,0
            da    AV_D_ISFILE
            dfb   2,1
            da    AV_D_NOPE
            dfb   2,1
            da    AV_E_EXIST
            dfb   2,0
            da    AV_E_NOPE
            dfb   2,1
            da    AV_Z_EMPTY
            dfb   2,0
            da    AV_Z_FOO
            dfb   2,1
            da    AV_N_FOO
            dfb   2,0
            da    AV_N_EMPTY
            dfb   2,1
            da    AV_EQ_T
            dfb   3,0
            da    AV_EQ_F
            dfb   3,1
            da    AV_NE_T
            dfb   3,0
            da    AV_NE_F
            dfb   3,1
            da    AV_EQI_T
            dfb   3,0
            da    AV_EQI_F
            dfb   3,1
            da    AV_NEI_T
            dfb   3,0
            da    AV_NEI_F
            dfb   3,1
            da    AV_LT_T
            dfb   3,0
            da    AV_LT_F
            dfb   3,1
            da    AV_GT_T
            dfb   3,0
            da    AV_GT_F
            dfb   3,1
            da    AV_LE_T
            dfb   3,0
            da    AV_LE_F
            dfb   3,1
            da    AV_GE_T
            dfb   3,0
            da    AV_GE_F
            dfb   3,1
            da    AV_NNL
            dfb   3,2
            da    AV_NNR
            dfb   3,2
            da    AV_BNG_T
            dfb   2,0
            da    AV_BNG_F
            dfb   2,1
            da    AV_BNGF_F
            dfb   3,1
            da    AV_BNGF_T
            dfb   3,0
            da    AV_BNGEQ_T
            dfb   4,0
            da    AV_BW_T
            dfb   1,0
            da    AV_BW_F
            dfb   1,1
            da    AV_MALF1
            dfb   2,2
            da    AV_MALF2
            dfb   3,2
            da    AV_EMPTY0
            dfb   0,1
*-- New primaries (docs/POSIX-GAPS.md sec 2's `test` row): -s -r
*-- -w -x, the always-false -b/.../-u group, -a/-o precedence,
*-- and `( )` grouping. See src/bin/testeval.s decision 4 for
*-- the ProDOS mapping each row is proving.
            da    AV_X_ISBIN
            dfb   2,0
            da    AV_X_ISTXT
            dfb   2,1
            da    AV_X_NOPE
            dfb   2,1
            da    AV_S_HASDATA
            dfb   2,0
            da    AV_S_NOPE
            dfb   2,1
            da    AV_R_EXIST
            dfb   2,0
            da    AV_R_NOPE
            dfb   2,1
            da    AV_W_EXIST
            dfb   2,0
            da    AV_W_NOPE
            dfb   2,1
            da    AV_B_EXIST
            dfb   2,1
            da    AV_U_NOPE
            dfb   2,1
            da    AV_AND_TT
            dfb   3,0
            da    AV_AND_FT
            dfb   3,1
            da    AV_OR_TF
            dfb   3,0
            da    AV_OR_FF
            dfb   3,1
            da    AV_PREC_AO
            dfb   5,0
            da    AV_PREC_OA
            dfb   5,1
            da    AV_PAREN_T
            dfb   3,0
            da    AV_PAREN_F
            dfb   3,1
            da    AV_PAREN_MISS
            dfb   2,2
            da    AV_BNG_PAREN
            dfb   6,0
*-- NCASE: hoisted above its first use (EQU burn-down).

*---------------------------------------------------------------
* argv arrays -- each a run of 2-byte token pointers, exactly
* the shape TEST_EVAL's own header documents.
*---------------------------------------------------------------
AV_F_EXIST  da    TK_DASHF,TK_TESTF
AV_F_ISDIR  da    TK_DASHF,TK_TESTD
AV_F_NOPE   da    TK_DASHF,TK_NOPE
AV_D_ISDIR  da    TK_DASHD,TK_TESTD
AV_D_ISFILE da    TK_DASHD,TK_TESTF
AV_D_NOPE   da    TK_DASHD,TK_NOPE
AV_E_EXIST  da    TK_DASHE,TK_TESTF
AV_E_NOPE   da    TK_DASHE,TK_NOPE
AV_Z_EMPTY  da    TK_DASHZ,TK_EMPTY
AV_Z_FOO    da    TK_DASHZ,TK_FOO
AV_N_FOO    da    TK_DASHN,TK_FOO
AV_N_EMPTY  da    TK_DASHN,TK_EMPTY
AV_EQ_T     da    TK_FOO,TK_EQ,TK_FOO
AV_EQ_F     da    TK_FOO,TK_EQ,TK_BAR
AV_NE_T     da    TK_FOO,TK_NE,TK_BAR
AV_NE_F     da    TK_FOO,TK_NE,TK_FOO
AV_EQI_T    da    TK_N3,TK_EQOP,TK_N3
AV_EQI_F    da    TK_N3,TK_EQOP,TK_N4
AV_NEI_T    da    TK_N3,TK_NEOP,TK_N4
AV_NEI_F    da    TK_N3,TK_NEOP,TK_N3
AV_LT_T     da    TK_N3,TK_LTOP,TK_N4
AV_LT_F     da    TK_N4,TK_LTOP,TK_N3
AV_GT_T     da    TK_N4,TK_GTOP,TK_N3
AV_GT_F     da    TK_N3,TK_GTOP,TK_N4
AV_LE_T     da    TK_N3,TK_LEOP,TK_N3
AV_LE_F     da    TK_N4,TK_LEOP,TK_N3
AV_GE_T     da    TK_N3,TK_GEOP,TK_N3
AV_GE_F     da    TK_N3,TK_GEOP,TK_N4
AV_NNL      da    TK_ABC,TK_EQOP,TK_N3
AV_NNR      da    TK_N3,TK_EQOP,TK_ABC
AV_BNG_T    da    TK_BANG,TK_EMPTY
AV_BNG_F    da    TK_BANG,TK_FOO
AV_BNGF_F   da    TK_BANG,TK_DASHF,TK_TESTF
AV_BNGF_T   da    TK_BANG,TK_DASHF,TK_NOPE
AV_BNGEQ_T  da    TK_BANG,TK_FOO,TK_EQ,TK_BAR
AV_BW_T     da    TK_FOO
AV_BW_F     da    TK_EMPTY
AV_MALF1    da    TK_DASHQ,TK_FOO
AV_MALF2    da    TK_FOO,TK_BAR,TK_BAZ
AV_EMPTY0   da    0
AV_X_ISBIN  da    TK_DASHX,TK_TESTB
AV_X_ISTXT  da    TK_DASHX,TK_TESTF
AV_X_NOPE   da    TK_DASHX,TK_NOPE
AV_S_HASDATA da   TK_DASHS,TK_TESTF
AV_S_NOPE   da    TK_DASHS,TK_NOPE
AV_R_EXIST  da    TK_DASHR,TK_TESTF
AV_R_NOPE   da    TK_DASHR,TK_NOPE
AV_W_EXIST  da    TK_DASHW,TK_TESTF
AV_W_NOPE   da    TK_DASHW,TK_NOPE
AV_B_EXIST  da    TK_DASHB,TK_TESTF
AV_U_NOPE   da    TK_DASHU,TK_NOPE
AV_AND_TT   da    TK_FOO,TK_DASHA,TK_BAR
AV_AND_FT   da    TK_EMPTY,TK_DASHA,TK_FOO
AV_OR_TF    da    TK_FOO,TK_DASHO,TK_EMPTY
AV_OR_FF    da    TK_EMPTY,TK_DASHO,TK_EMPTY
AV_PREC_AO  da    TK_FOO,TK_DASHA,TK_EMPTY
            da    TK_DASHO,TK_BAR
AV_PREC_OA  da    TK_EMPTY,TK_DASHO,TK_FOO
            da    TK_DASHA,TK_EMPTY
AV_PAREN_T  da    TK_LPAREN,TK_FOO,TK_RPAREN
AV_PAREN_F  da    TK_LPAREN,TK_EMPTY,TK_RPAREN
AV_PAREN_MISS da  TK_LPAREN,TK_FOO
AV_BNG_PAREN da   TK_BANG,TK_LPAREN,TK_FOO
            da    TK_DASHA,TK_EMPTY,TK_RPAREN

*---------------------------------------------------------------
* Token strings -- high-bit ASCII, NUL-terminated. Paths are
* absolute against the carrier volume; scripts/
* build_testev_image.py stages TESTF as a regular file and
* TESTD as a directory, and leaves NOPE unwritten.
*---------------------------------------------------------------
TK_TESTF    asc   "/mnt/MAUX/TESTF"
            dfb   0
TK_TESTD    asc   "/mnt/MAUX/TESTD"
            dfb   0
TK_TESTB    asc   "/mnt/MAUX/TESTB"
            dfb   0
TK_NOPE     asc   "/mnt/MAUX/NOPE"
            dfb   0
TK_DASHF    asc   "-f"
            dfb   0
TK_DASHD    asc   "-d"
            dfb   0
TK_DASHE    asc   "-e"
            dfb   0
TK_DASHZ    asc   "-z"
            dfb   0
TK_DASHN    asc   "-n"
            dfb   0
TK_DASHX    asc   "-x"
            dfb   0
TK_DASHS    asc   "-s"
            dfb   0
TK_DASHR    asc   "-r"
            dfb   0
TK_DASHW    asc   "-w"
            dfb   0
TK_DASHB    asc   "-b"
            dfb   0
TK_DASHU    asc   "-u"
            dfb   0
TK_DASHA    asc   "-a"
            dfb   0
TK_DASHO    asc   "-o"
            dfb   0
TK_DASHQ    asc   "-q"
            dfb   0
TK_LPAREN   asc   "("
            dfb   0
TK_RPAREN   asc   ")"
            dfb   0
TK_EQOP     asc   "-eq"
            dfb   0
TK_NEOP     asc   "-ne"
            dfb   0
TK_LTOP     asc   "-lt"
            dfb   0
TK_GTOP     asc   "-gt"
            dfb   0
TK_LEOP     asc   "-le"
            dfb   0
TK_GEOP     asc   "-ge"
            dfb   0
TK_EQ       asc   "="
            dfb   0
TK_NE       asc   "!="
            dfb   0
TK_BANG     asc   "!"
            dfb   0
TK_EMPTY    dfb   0
TK_FOO      asc   "foo"
            dfb   0
TK_BAR      asc   "bar"
            dfb   0
TK_BAZ      asc   "baz"
            dfb   0
TK_N3       asc   "3"
            dfb   0
TK_N4       asc   "4"
            dfb   0
TK_ABC      asc   "abc"
            dfb   0

* PAR_PROC_LEN closes over TEST_EVAL and its liba dependencies
* too -- see testevtest.s, which `put`s them right after this
* file for exactly that reason.
