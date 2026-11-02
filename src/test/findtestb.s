*---------------------------------------------------------------
* findtestb.s -- image body for findtest.s (`make check-find`).
* Same shape as lstestb.s (BankCopy a hand-synthesized parent
* process into bank 1, SCH_CREATE/START it), but PARENT_PROC
* spawns FIND directly SIX times -- no shell involved, so argv
* carries a bare ";" for -exec exactly as docs/FLEET.md's find
* section requires for a harness-spawned subject (same technique
* check-ld/check-testev already use):
*   run 1: FIND /mnt/MAUX/FINDDIR                (plain walk)
*   run 2: FIND /mnt/MAUX/FINDDIR -name [AND]*.TXT (-name
*   filter)
*   run 3: FIND /mnt/MAUX/FINDDIR -type d         (-type d)
*   run 4: FIND /mnt/MAUX/FINDDIR -type f         (-type f)
*   run 5: FIND /mnt/MAUX/FINDDIR -name [AND]*.TXT -exec
*          /bin/CAT {} ;                     (-exec)
*   run 6: FIND /mnt/MAUX/DEEPDIR (depth overflow
*          -- DEEPDIR/A/B/C/D/E/F/G/H/I is 9 levels deep, one
*          past FIND_MAXDEP=8)
*   run 7: FIND /mnt/MAUX/LONGDIR                 (the pathname
*          fence -- a 62-char directory holding two children
*          past 64 chars, refused loudly, and one at EXACTLY
*          64 that must still print; exit 1)
* stdout is redirected to a fresh ProDOS file per run; runs 6
* and 7 ALSO redirect stderr, to see the loud failures.
* After every run finishes, PARENT_PROC reopens each output file
* for READ and copies its bytes into a fixed R_DATAn address
* -- scripts/check_find.py peeks those in aux bank 1, exactly
* like scripts/check_ls.py.
*
* Every scratch structure below lives at a FIXED low address and
* is filled by RUNTIME code, never assembled as static data
* there -- same reason lstestb.s's own SETUP_PATHS does this
* (see that file's header).
*---------------------------------------------------------------

FOUT1_PATH  equ $1000    ;"/mnt/MAUX/FOUT1"
FOUT2_PATH  equ $1010    ;"/mnt/MAUX/FOUT2"
FOUT3_PATH  equ $1020    ;"/mnt/MAUX/FOUT3"
FOUT4_PATH  equ $1030    ;"/mnt/MAUX/FOUT4"
FOUT5_PATH  equ $1040    ;"/mnt/MAUX/FOUT5"
FOUT6_PATH  equ $1050    ;"/mnt/MAUX/FOUT6"
FERR6_PATH  equ $1060    ;"/mnt/MAUX/FERR6"

FIND_SPWN_P equ $1070    ;hi-bit NUL "/bin/FIND" -- spawn
                         ;path, all 6 runs
ARG0_FIND   equ $1080    ;hi-bit NUL "FIND" -- argv[0], all runs
ARG_ROOT1   equ $1CC0    ;"/mnt/MAUX/FINDDIR" (18B, moved)
ARG_ROOT2   equ $1CE0    ;"/mnt/MAUX/DEEPDIR" (18B, moved)
ARG_NAMEFLG equ $10B0    ;"-name"
*-- ANCHORED ON PURPOSE, and 11 bytes still fits the 16 here.
*-- The pattern used to be "*.TXT", which could not tell a
*-- CORRECT find from a broken one: with a leading '*' the
*-- whole path "/mnt/MAUX/FINDDIR/AFILE.TXT" matches exactly as
*-- happily as the basename "AFILE.TXT", so the gate passed
*-- while find globbed against the wrong string for both.
*-- A leading class cannot match a path, because every path
*-- starts with '/' -- and [AND] still matches all three of
*-- AFILE/NESTED/DEEP, so nothing was traded away for the
*-- anchor.
ARG_TPATVAL equ $10C0    ;"[AND]*.TXT" -- see below
ARG_TYPEFLG equ $10D0    ;"-type"
ARG_TYPED   equ $10E0    ;"d"
ARG_TYPEF   equ $10F0    ;"f"
ARG_EXECFLG equ $1100    ;"-exec"
ARG_CATPATH equ $1110    ;"/bin/CAT"
ARG_BRACE   equ $1120    ;"{}"
ARG_SEMI    equ $1130    ;";" -- BARE, no backslash: no shell is
                         ;involved (docs/FLEET.md find section
                         ;#2's own "spawned directly by a gate
                         ;harness" scope note)

ARGV1       equ $1140    ;FIND,ROOT1 + NULL               (6B)
ARGV2       equ $1160    ;FIND,ROOT1,-name,PAT + NULL    (10B)
ARGV3       equ $1180    ;FIND,ROOT1,-type,d + NULL      (10B)
ARGV4       equ $11A0    ;FIND,ROOT1,-type,f + NULL      (10B)
ARGV5       equ $11C0    ;FIND,ROOT1,-name,PAT,-exec,
                         ;CATPATH,BRACE,SEMI + NULL      (18B)
ARGV6       equ $11E0    ;FIND,ROOT2 + NULL               (6B)

SPAWN_PARM1 equ $1200
SPAWN_PARM2 equ $1210
SPAWN_PARM3 equ $1220
SPAWN_PARM4 equ $1230
SPAWN_PARM5 equ $1240
SPAWN_PARM6 equ $1250

* fdactions -- 3-byte records, FDACT_END a bare 0 terminator.
* Runs 1-5 redirect stdout only; run 6 redirects stdout AND
* stderr. DUP/CLOSE fd-number bytes are runtime-patched once
* CRT+OPEN return the real fd.
FDA1        equ $1260    ;DUP(stdout,fd) CLOSE(fd) END    (7B)
FDA2        equ $1270
FDA3        equ $1280
FDA4        equ $1290
FDA5        equ $12A0
FDA6        equ $12B0    ;DUP/CLOSE stdout, DUP/CLOSE
                         ;stderr, END                    (13B)

OPEN_PARM   equ $12C0    ;PCOUNT_OPEN shape (6B)
CREATE_PARM equ $12D0    ;PCOUNT_CREATE shape (12B)
CLOSE_PARM  equ $12E0    ;PCOUNT_CLOSE shape (2B)
WAIT_PARM   equ $12F0    ;status-dest pointer (2B)
READ_PARM   equ $1300    ;PCOUNT_READ shape (8B)

CUR_FD      equ $1310
CUR_FD2     equ $1311

IOREQLEN    equ 340      ;bigger than any expected run's output
                         ;(run 1/6's own ~9-10 lines)
IO_BUF      equ $1320    ;staging buffer, reused every readback

* -- Result addresses in the parent process bank.
* scripts/check_find.py peeks these in aux bank 1.
R_STATUS1   equ $1480
R_STATUS2   equ $1481
R_STATUS3   equ $1482
R_STATUS4   equ $1483
R_STATUS5   equ $1484
R_STATUS6   equ $1485
R_TRANS1    equ $1486    ;2 bytes
R_TRANS2    equ $1488
R_TRANS3    equ $148A
R_TRANS4    equ $148C
R_TRANS5    equ $148E
R_TRANS6    equ $1490
R_ERRTRNS6  equ $1492    ;2 bytes -- run 6 stderr trans
R_SPWNPID1  equ $1494
R_SPWNPID2  equ $1495
R_SPWNPID3  equ $1496
R_SPWNPID4  equ $1497
R_SPWNPID5  equ $1498
R_SPWNPID6  equ $1499
R_WAITPID1  equ $149A
R_WAITPID2  equ $149B
R_WAITPID3  equ $149C
R_WAITPID4  equ $149D
R_WAITPID5  equ $149E
R_WAITPID6  equ $149F
R_DONE      equ $14A0
R_ERR       equ $14A1
R_STEP      equ $14A2

R_DATA1     equ $14B0    ;340B -- ends $1604
R_DATA2     equ $1604    ;128B -- ends $1684
R_DATA3     equ $1684    ;128B -- ends $1704
R_DATA4     equ $1704    ;256B -- ends $1804
R_DATA5     equ $1804    ;64B  -- ends $1844
R_DATA6     equ $1844    ;340B -- ends $1998
R_ERRDATA6  equ $1998    ;64B  -- ends $19D8

* -- run 7 (the pathname fence -- /mnt/MAUX/LONGDIR) lives past
* -- run 6's result area, added 2026-08-23 with find's
* -- BUILDCHILD bound (see src/bin/find.s FP_BUFLEN).
ARG_ROOT3   equ $1D00    ;"/mnt/MAUX/LONGDIR" (18B, moved)
FOUT7_PATH  equ $19F0    ;"/mnt/MAUX/FOUT7"
FERR7_PATH  equ $1A00    ;"/mnt/MAUX/FERR7"
ARGV7       equ $1A10    ;FIND,ROOT3 + NULL               (6B)
SPAWN_PARM7 equ $1A20
FDA7        equ $1A30    ;DUP/CLOSE stdout + stderr      (13B)
R_STATUS7   equ $1A40
R_TRANS7    equ $1A41    ;2 bytes
R_ERRTRNS7  equ $1A43    ;2 bytes
R_SPWNPID7  equ $1A45
R_WAITPID7  equ $1A46
R_GO_REQ    equ $1A47    ;gap handshake: parent publishes the
R_GO        equ $1A48    ;gap number here and parks until the
                         ;gate echoes it into R_GO (check-ls's
                         ;between-run poison protocol)
R_DATA7     equ $1A50    ;340B -- ends $1BA4
R_ERRDATA7  equ $1BB0    ;256B -- ends $1CB0 (two long
                         ;"pathname too long" lines)

*---------------------------------------------------------------
* Boot helpers -- identical shape to lstestb.s's own.
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

BANNER      asc   "MAUX FINDTEST"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 -- absolute JSR/JMP operands to the helpers below
* depend on that, same as lstestb.s's own PARENT_PROC.
*---------------------------------------------------------------
PARENT_PROC
            stz   R_ERR
            stz   R_STEP
            stz   R_GO_REQ           ;bank-1 scratch is not part
            stz   R_GO               ;of the copied image --
                                     ;defined state before the
                                     ;gate ever reads it
            jsr   SETUP_PATHS

            lda   #1
            sta   R_STEP
            jsr   RUN1
            bcc   :r1ok
            jmp   P_ERR
:r1ok
            lda   #1
            jsr   GAPWAIT
            lda   #2
            sta   R_STEP
            jsr   RUN2
            bcc   :r2ok
            jmp   P_ERR
:r2ok
            lda   #2
            jsr   GAPWAIT
            lda   #3
            sta   R_STEP
            jsr   RUN3
            bcc   :r3ok
            jmp   P_ERR
:r3ok
            lda   #3
            jsr   GAPWAIT
            lda   #4
            sta   R_STEP
            jsr   RUN4
            bcc   :r4ok
            jmp   P_ERR
:r4ok
            lda   #4
            jsr   GAPWAIT
            lda   #5
            sta   R_STEP
            jsr   RUN5
            bcc   :r5ok
            jmp   P_ERR
:r5ok
            lda   #5
            jsr   GAPWAIT
            lda   #6
            sta   R_STEP
            jsr   RUN6
            bcc   :r6ok
            jmp   P_ERR
:r6ok
            lda   #6
            jsr   GAPWAIT
            lda   #7
            sta   R_STEP
            jsr   RUN7
            bcc   :r7ok
            jmp   P_ERR
:r7ok
            lda   #8
            sta   R_STEP
            jsr   READBACK_ALL
            bcc   :rbok
            jmp   P_ERR
:rbok
            lda   #$AA
            sta   R_DONE
:done       bra   :done

P_ERR       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:park       bra   :park

*---------------------------------------------------------------
* GAPWAIT -- IN: A = gap number. Publish it in R_GO_REQ and
* park until the gate has re-poisoned the just-freed bank and
* echoed the number into R_GO -- so the scribble lands strictly
* between one run's reap and the next one's spawn, never mid-
* spawn (check_ls.py's own protocol, docs/STICKY.md sec 25).
*---------------------------------------------------------------
GAPWAIT     sta   R_GO_REQ
:gw         lda   R_GO
            cmp   R_GO_REQ
            bne   :gw
            rts

*---------------------------------------------------------------
* SETUP_PATHS -- fills every static (argv-time-known) structure.
*---------------------------------------------------------------
SETUP_PATHS
            lda   #15
            sta   FOUT1_PATH
            ldx   #0
:cp1        lda   T_FOUT1,x
            sta   FOUT1_PATH+1,x
            inx
            cpx   #15
            bne   :cp1

            lda   #15
            sta   FOUT2_PATH
            ldx   #0
:cp2        lda   T_FOUT2,x
            sta   FOUT2_PATH+1,x
            inx
            cpx   #15
            bne   :cp2

            lda   #15
            sta   FOUT3_PATH
            ldx   #0
:cp3        lda   T_FOUT3,x
            sta   FOUT3_PATH+1,x
            inx
            cpx   #15
            bne   :cp3

            lda   #15
            sta   FOUT4_PATH
            ldx   #0
:cp4        lda   T_FOUT4,x
            sta   FOUT4_PATH+1,x
            inx
            cpx   #15
            bne   :cp4

            lda   #15
            sta   FOUT5_PATH
            ldx   #0
:cp5        lda   T_FOUT5,x
            sta   FOUT5_PATH+1,x
            inx
            cpx   #15
            bne   :cp5

            lda   #15
            sta   FOUT6_PATH
            ldx   #0
:cp6        lda   T_FOUT6,x
            sta   FOUT6_PATH+1,x
            inx
            cpx   #15
            bne   :cp6

            lda   #15
            sta   FERR6_PATH
            ldx   #0
:cp7        lda   T_FERR6,x
            sta   FERR6_PATH+1,x
            inx
            cpx   #15
            bne   :cp7

            lda   #15
            sta   FOUT7_PATH
            ldx   #0
:cp7b       lda   T_FOUT7,x
            sta   FOUT7_PATH+1,x
            inx
            cpx   #15
            bne   :cp7b

            lda   #15
            sta   FERR7_PATH
            ldx   #0
:cp7c       lda   T_FERR7,x
            sta   FERR7_PATH+1,x
            inx
            cpx   #15
            bne   :cp7c

            ldx   #0
:cp8        lda   T_SPWNFIND,x
            ora   #$80
            sta   FIND_SPWN_P,x
            inx
            cpx   #9
            bne   :cp8
            stz   FIND_SPWN_P,x

            ldx   #0
:cp9        lda   T_ARG0FIND,x
            ora   #$80
            sta   ARG0_FIND,x
            inx
            cpx   #4
            bne   :cp9
            stz   ARG0_FIND,x

            ldx   #0
:cp10       lda   T_ARGROOT1,x
            ora   #$80
            sta   ARG_ROOT1,x
            inx
            cpx   #17
            bne   :cp10
            stz   ARG_ROOT1,x

            ldx   #0
:cp11       lda   T_ARGROOT2,x
            ora   #$80
            sta   ARG_ROOT2,x
            inx
            cpx   #17
            bne   :cp11
            stz   ARG_ROOT2,x

            ldx   #0
:cp11b      lda   T_ARGROOT3,x
            ora   #$80
            sta   ARG_ROOT3,x
            inx
            cpx   #17
            bne   :cp11b
            stz   ARG_ROOT3,x

            ldx   #0
:cp12       lda   T_NAMEFLG,x
            ora   #$80
            sta   ARG_NAMEFLG,x
            inx
            cpx   #5
            bne   :cp12
            stz   ARG_NAMEFLG,x

            ldx   #0
:cp13       lda   T_TPATVAL,x
            ora   #$80
            sta   ARG_TPATVAL,x
            inx
            cpx   #10
            bne   :cp13
            stz   ARG_TPATVAL,x

            ldx   #0
:cp14       lda   T_TYPEFLG,x
            ora   #$80
            sta   ARG_TYPEFLG,x
            inx
            cpx   #5
            bne   :cp14
            stz   ARG_TYPEFLG,x

* -- $E4: high-bit LOWERCASE 'd', the spelling find's own usage
* -- banner documents and the only one a person types. This
* -- harness typed $C4 (uppercase 'D') -- the one spelling the
* -- binary's own $C4 bug accepted -- so the gate passed while
* -- `-type d` exited 2 for every real user. Gate the form a
* -- human types (learning:01M0PKP4ZK7NX6HASWHTKKZHDG).
            lda   #$E4              ;'d' high-bit, LOWER
            sta   ARG_TYPED
            stz   ARG_TYPED+1
            lda   #$E6              ;'f' high-bit
            sta   ARG_TYPEF
            stz   ARG_TYPEF+1

            ldx   #0
:cp15       lda   T_EXECFLG,x
            ora   #$80
            sta   ARG_EXECFLG,x
            inx
            cpx   #5
            bne   :cp15
            stz   ARG_EXECFLG,x

            ldx   #0
:cp16       lda   T_CATPATH,x
            ora   #$80
            sta   ARG_CATPATH,x
            inx
            cpx   #8
            bne   :cp16
            stz   ARG_CATPATH,x

            lda   #$FB              ;'{' high-bit
            sta   ARG_BRACE
            lda   #$FD              ;'}' high-bit
            sta   ARG_BRACE+1
            stz   ARG_BRACE+2

            lda   #$BB              ;';' high-bit -- BARE, see
                                     ;this file's own header
            sta   ARG_SEMI
            stz   ARG_SEMI+1

            jsr   SETUP_ARGV
            jsr   SETUP_SPAWN
            jsr   SETUP_FDA
            rts

T_FOUT7     asc   "/mnt/MAUX/FOUT7"
T_FERR7     asc   "/mnt/MAUX/FERR7"
T_ARGROOT3  asc   "/mnt/MAUX/LONGDIR"
T_FOUT1     asc   "/mnt/MAUX/FOUT1"
T_FOUT2     asc   "/mnt/MAUX/FOUT2"
T_FOUT3     asc   "/mnt/MAUX/FOUT3"
T_FOUT4     asc   "/mnt/MAUX/FOUT4"
T_FOUT5     asc   "/mnt/MAUX/FOUT5"
T_FOUT6     asc   "/mnt/MAUX/FOUT6"
T_FERR6     asc   "/mnt/MAUX/FERR6"
T_SPWNFIND  asc   "/bin/FIND"
T_ARG0FIND  asc   "FIND"
T_ARGROOT1  asc   "/mnt/MAUX/FINDDIR"
T_ARGROOT2  asc   "/mnt/MAUX/DEEPDIR"
T_NAMEFLG   asc   "-name"
T_TPATVAL   asc   "[AND]*.TXT"
T_TYPEFLG   asc   "-type"
T_EXECFLG   asc   "-exec"
T_CATPATH   asc   "/bin/CAT"

*---------------------------------------------------------------
* SETUP_ARGV -- the 6 ARGV pointer arrays (each entry: lo,hi;
* NULL pointer terminates).
*---------------------------------------------------------------
SETUP_ARGV  lda   #<ARG0_FIND
            sta   ARGV1
            lda   #>ARG0_FIND
            sta   ARGV1+1
            lda   #<ARG_ROOT1
            sta   ARGV1+2
            lda   #>ARG_ROOT1
            sta   ARGV1+3
            stz   ARGV1+4
            stz   ARGV1+5

            lda   #<ARG0_FIND
            sta   ARGV2
            lda   #>ARG0_FIND
            sta   ARGV2+1
            lda   #<ARG_ROOT1
            sta   ARGV2+2
            lda   #>ARG_ROOT1
            sta   ARGV2+3
            lda   #<ARG_NAMEFLG
            sta   ARGV2+4
            lda   #>ARG_NAMEFLG
            sta   ARGV2+5
            lda   #<ARG_TPATVAL
            sta   ARGV2+6
            lda   #>ARG_TPATVAL
            sta   ARGV2+7
            stz   ARGV2+8
            stz   ARGV2+9

            lda   #<ARG0_FIND
            sta   ARGV3
            lda   #>ARG0_FIND
            sta   ARGV3+1
            lda   #<ARG_ROOT1
            sta   ARGV3+2
            lda   #>ARG_ROOT1
            sta   ARGV3+3
            lda   #<ARG_TYPEFLG
            sta   ARGV3+4
            lda   #>ARG_TYPEFLG
            sta   ARGV3+5
            lda   #<ARG_TYPED
            sta   ARGV3+6
            lda   #>ARG_TYPED
            sta   ARGV3+7
            stz   ARGV3+8
            stz   ARGV3+9

            lda   #<ARG0_FIND
            sta   ARGV4
            lda   #>ARG0_FIND
            sta   ARGV4+1
            lda   #<ARG_ROOT1
            sta   ARGV4+2
            lda   #>ARG_ROOT1
            sta   ARGV4+3
            lda   #<ARG_TYPEFLG
            sta   ARGV4+4
            lda   #>ARG_TYPEFLG
            sta   ARGV4+5
            lda   #<ARG_TYPEF
            sta   ARGV4+6
            lda   #>ARG_TYPEF
            sta   ARGV4+7
            stz   ARGV4+8
            stz   ARGV4+9

            lda   #<ARG0_FIND
            sta   ARGV5
            lda   #>ARG0_FIND
            sta   ARGV5+1
            lda   #<ARG_ROOT1
            sta   ARGV5+2
            lda   #>ARG_ROOT1
            sta   ARGV5+3
            lda   #<ARG_NAMEFLG
            sta   ARGV5+4
            lda   #>ARG_NAMEFLG
            sta   ARGV5+5
            lda   #<ARG_TPATVAL
            sta   ARGV5+6
            lda   #>ARG_TPATVAL
            sta   ARGV5+7
            lda   #<ARG_EXECFLG
            sta   ARGV5+8
            lda   #>ARG_EXECFLG
            sta   ARGV5+9
            lda   #<ARG_CATPATH
            sta   ARGV5+10
            lda   #>ARG_CATPATH
            sta   ARGV5+11
            lda   #<ARG_BRACE
            sta   ARGV5+12
            lda   #>ARG_BRACE
            sta   ARGV5+13
            lda   #<ARG_SEMI
            sta   ARGV5+14
            lda   #>ARG_SEMI
            sta   ARGV5+15
            stz   ARGV5+16
            stz   ARGV5+17

            lda   #<ARG0_FIND
            sta   ARGV6
            lda   #>ARG0_FIND
            sta   ARGV6+1
            lda   #<ARG_ROOT2
            sta   ARGV6+2
            lda   #>ARG_ROOT2
            sta   ARGV6+3
            stz   ARGV6+4
            stz   ARGV6+5

            lda   #<ARG0_FIND
            sta   ARGV7
            lda   #>ARG0_FIND
            sta   ARGV7+1
            lda   #<ARG_ROOT3
            sta   ARGV7+2
            lda   #>ARG_ROOT3
            sta   ARGV7+3
            stz   ARGV7+4
            stz   ARGV7+5
            rts

*---------------------------------------------------------------
* SETUP_SPAWN -- the 6 SPAWN_PARM triples (path ptr, argv ptr,
* fda ptr). Path is the SAME FIND_SPWN_P for every run.
*---------------------------------------------------------------
SETUP_SPAWN lda   #<FIND_SPWN_P
            sta   SPAWN_PARM1
            lda   #>FIND_SPWN_P
            sta   SPAWN_PARM1+1
            lda   #<ARGV1
            sta   SPAWN_PARM1+2
            lda   #>ARGV1
            sta   SPAWN_PARM1+3
            lda   #<FDA1
            sta   SPAWN_PARM1+4
            lda   #>FDA1
            sta   SPAWN_PARM1+5
            stz   SPAWN_PARM1+6           ;NULL envp
            stz   SPAWN_PARM1+7

            lda   #<FIND_SPWN_P
            sta   SPAWN_PARM2
            lda   #>FIND_SPWN_P
            sta   SPAWN_PARM2+1
            lda   #<ARGV2
            sta   SPAWN_PARM2+2
            lda   #>ARGV2
            sta   SPAWN_PARM2+3
            lda   #<FDA2
            sta   SPAWN_PARM2+4
            lda   #>FDA2
            sta   SPAWN_PARM2+5
            stz   SPAWN_PARM2+6           ;NULL envp
            stz   SPAWN_PARM2+7

            lda   #<FIND_SPWN_P
            sta   SPAWN_PARM3
            lda   #>FIND_SPWN_P
            sta   SPAWN_PARM3+1
            lda   #<ARGV3
            sta   SPAWN_PARM3+2
            lda   #>ARGV3
            sta   SPAWN_PARM3+3
            lda   #<FDA3
            sta   SPAWN_PARM3+4
            lda   #>FDA3
            sta   SPAWN_PARM3+5
            stz   SPAWN_PARM3+6           ;NULL envp
            stz   SPAWN_PARM3+7

            lda   #<FIND_SPWN_P
            sta   SPAWN_PARM4
            lda   #>FIND_SPWN_P
            sta   SPAWN_PARM4+1
            lda   #<ARGV4
            sta   SPAWN_PARM4+2
            lda   #>ARGV4
            sta   SPAWN_PARM4+3
            lda   #<FDA4
            sta   SPAWN_PARM4+4
            lda   #>FDA4
            sta   SPAWN_PARM4+5
            stz   SPAWN_PARM4+6           ;NULL envp
            stz   SPAWN_PARM4+7

            lda   #<FIND_SPWN_P
            sta   SPAWN_PARM5
            lda   #>FIND_SPWN_P
            sta   SPAWN_PARM5+1
            lda   #<ARGV5
            sta   SPAWN_PARM5+2
            lda   #>ARGV5
            sta   SPAWN_PARM5+3
            lda   #<FDA5
            sta   SPAWN_PARM5+4
            lda   #>FDA5
            sta   SPAWN_PARM5+5
            stz   SPAWN_PARM5+6           ;NULL envp
            stz   SPAWN_PARM5+7

            lda   #<FIND_SPWN_P
            sta   SPAWN_PARM6
            lda   #>FIND_SPWN_P
            sta   SPAWN_PARM6+1
            lda   #<ARGV6
            sta   SPAWN_PARM6+2
            lda   #>ARGV6
            sta   SPAWN_PARM6+3
            lda   #<FDA6
            sta   SPAWN_PARM6+4
            lda   #>FDA6
            sta   SPAWN_PARM6+5
            stz   SPAWN_PARM6+6           ;NULL envp
            stz   SPAWN_PARM6+7

            lda   #<FIND_SPWN_P
            sta   SPAWN_PARM7
            lda   #>FIND_SPWN_P
            sta   SPAWN_PARM7+1
            lda   #<ARGV7
            sta   SPAWN_PARM7+2
            lda   #>ARGV7
            sta   SPAWN_PARM7+3
            lda   #<FDA7
            sta   SPAWN_PARM7+4
            lda   #>FDA7
            sta   SPAWN_PARM7+5
            stz   SPAWN_PARM7+6           ;NULL envp
            stz   SPAWN_PARM7+7
            rts

*---------------------------------------------------------------
* SETUP_FDA -- static FDA bytes (opcodes and FD_STDOUT/
* FD_STDERR target bytes -- dynamic source-fd bytes are patched
* per-run once CRT+OPEN return a real fd; see RUN1-6).
*---------------------------------------------------------------
SETUP_FDA   lda   #FDACT_DUP
            sta   FDA1+0
            lda   #FD_STDOUT
            sta   FDA1+1
            lda   #FDACT_CLOSE
            sta   FDA1+3
            stz   FDA1+5
            stz   FDA1+6

            lda   #FDACT_DUP
            sta   FDA2+0
            lda   #FD_STDOUT
            sta   FDA2+1
            lda   #FDACT_CLOSE
            sta   FDA2+3
            stz   FDA2+5
            stz   FDA2+6

            lda   #FDACT_DUP
            sta   FDA3+0
            lda   #FD_STDOUT
            sta   FDA3+1
            lda   #FDACT_CLOSE
            sta   FDA3+3
            stz   FDA3+5
            stz   FDA3+6

            lda   #FDACT_DUP
            sta   FDA4+0
            lda   #FD_STDOUT
            sta   FDA4+1
            lda   #FDACT_CLOSE
            sta   FDA4+3
            stz   FDA4+5
            stz   FDA4+6

            lda   #FDACT_DUP
            sta   FDA5+0
            lda   #FD_STDOUT
            sta   FDA5+1
            lda   #FDACT_CLOSE
            sta   FDA5+3
            stz   FDA5+5
            stz   FDA5+6

            lda   #FDACT_DUP
            sta   FDA6+0
            lda   #FD_STDOUT
            sta   FDA6+1
            lda   #FDACT_CLOSE
            sta   FDA6+3
            stz   FDA6+5
            lda   #FDACT_DUP
            sta   FDA6+6
            lda   #FD_STDERR
            sta   FDA6+7
            lda   #FDACT_CLOSE
            sta   FDA6+9
            stz   FDA6+11
            stz   FDA6+12

            lda   #FDACT_DUP
            sta   FDA7+0
            lda   #FD_STDOUT
            sta   FDA7+1
            lda   #FDACT_CLOSE
            sta   FDA7+3
            stz   FDA7+5
            lda   #FDACT_DUP
            sta   FDA7+6
            lda   #FD_STDERR
            sta   FDA7+7
            lda   #FDACT_CLOSE
            sta   FDA7+9
            stz   FDA7+11
            stz   FDA7+12
            rts

*---------------------------------------------------------------
* CRT_FILE / OPEN_FILE / CLOSE_FD -- generic MLI helpers, same
* shape as lstestb.s's own.

* -- The MLI helpers, RUN1-RUN7 and the readback continue in
* -- src/test/findtestc.s, `put` by findtest.s IMMEDIATELY
* -- after this file: the parent-process image must stay one
* -- contiguous byte range from PARENT_PROC to PAR_PROC_LEN
* -- (BOOT_CPY_PAR copies that span verbatim), and adjacent
* -- puts emit adjacent bytes. Split so the findtest UNIT
* -- fits real Merlin-8's 41,215-byte source buffer
* -- (scripts/check_dialect.py budget 3: resident + largest
* -- single put) -- run 7 pushed this file past tty.s as the
* -- unit's largest put.
