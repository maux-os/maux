*---------------------------------------------------------------
* dutestb.s -- image body for dutest.s (`make check-du`). Same
* shape as findtestb.s (BankCopy a hand-synthesized parent
* process into bank 1, SCH_CREATE/START it), but PARENT_PROC
* spawns DU directly EIGHT times -- no shell involved:
*   run 1: DU /mnt/MAUX/DUDIR                  (plain walk)
*   run 2: DU -s /mnt/MAUX/DUDIR                (-s summary)
*   run 3: DU -a /mnt/MAUX/DUDIR                (-a, every file)
*   run 4: DU /mnt/MAUX/DUDIR/B.BIN (single file arg)
*   run 5: DU -s /mnt/MAUX/NONEXIST /mnt/MAUX/DUDIR2 (bad path
*   then
*          good path -- stderr diagnostic, continue, exit 1)
*   run 6: DU /mnt/MAUX/LONGDIR                 (the pathname
*          fence -- two children past 64 chars refused loudly
*          and EXCLUDED from every total, one at exactly 64
*          counted; exit 1)
*   run 7: DU /mnt/MAUX/DUDIR/ (docs/DU-DF.md: a
*          trailing "/" must not double -- children print
*          /mnt/MAUX/DUDIR/SUB1, never /mnt/MAUX/DUDIR//SUB1)
*   run 8: DU, cwd = /mnt/MAUX/DUDIR (no operand: names
*          print relative, ./SUB1/SUB2 ... and "." last; the
*          parent SET_PREFIXes first, so this run is LAST)
* stdout is redirected to a fresh ProDOS file per run; runs 5
* and 6 ALSO redirect stderr, to see the loud diagnostics.
* After every run finishes, PARENT_PROC reopens each output
* file for READ
* and copies its bytes into a fixed R_DATAn address --
* scripts/check_du.py peeks those in aux bank 1, exactly like
* scripts/check_find.py.
*
* Every scratch structure below lives at a FIXED low address and
* is filled by RUNTIME code, never assembled as static data
* there -- same reason findtestb.s's own SETUP_PATHS does this.
*---------------------------------------------------------------

FOUT1_PATH  equ $1000    ;"/mnt/MAUX/FOUT1"
FOUT2_PATH  equ $1010    ;"/mnt/MAUX/FOUT2"
FOUT3_PATH  equ $1020    ;"/mnt/MAUX/FOUT3"
FOUT4_PATH  equ $1030    ;"/mnt/MAUX/FOUT4"
FOUT5_PATH  equ $1040    ;"/mnt/MAUX/FOUT5"
FERR5_PATH  equ $1050    ;"/mnt/MAUX/FERR5"

DU_SPWN_P   equ $1060 ;"/bin/DU" -- spawn path, all 8 runs
ARG0_DU     equ $1080    ;"DU" -- argv[0], all runs
ARG_ROOT    equ $1090    ;"/mnt/MAUX/DUDIR"
ARG_ROOT2   equ $10B0    ;"/mnt/MAUX/DUDIR2"
ARG_FILEB   equ $10D0    ;"/mnt/MAUX/DUDIR/B.BIN"
ARG_NOEXIST equ $10F0    ;"/mnt/MAUX/NONEXIST"
ARG_SFLAG   equ $1110    ;"-s"
ARG_AFLAG   equ $1130    ;"-a"

ARGV1       equ $1200    ;DU,ROOT + NULL                  (6B)
ARGV2       equ $1210    ;DU,-s,ROOT + NULL                (8B)
ARGV3       equ $1220    ;DU,-a,ROOT + NULL                (8B)
ARGV4       equ $1230    ;DU,FILEB + NULL                  (6B)
ARGV5       equ $1240    ;DU,-s,NOEXIST,ROOT2 + NULL      (10B)

SPAWN_PARM1 equ $1250
SPAWN_PARM2 equ $1260
SPAWN_PARM3 equ $1270
SPAWN_PARM4 equ $1280
SPAWN_PARM5 equ $1290

* fdactions -- 3-byte records, FDACT_END a bare 0 terminator.
* Runs 1-4 redirect stdout only; run 5 redirects stdout AND
* stderr. DUP/CLOSE fd-number bytes are runtime-patched once
* CRT+OPEN return the real fd.
FDA1        equ $12A0    ;DUP(stdout,fd) CLOSE(fd) END    (7B)
FDA2        equ $12B0
FDA3        equ $12C0
FDA4        equ $12D0
FDA5        equ $12E0    ;DUP/CLOSE stdout, DUP/CLOSE
                         ;stderr, END                    (13B)

OPEN_PARM   equ $1300    ;PCOUNT_OPEN shape (6B)
CREATE_PARM equ $1310    ;PCOUNT_CREATE shape (12B)
CLOSE_PARM  equ $1320    ;PCOUNT_CLOSE shape (2B)
WAIT_PARM   equ $1330    ;status-dest pointer (2B)
READ_PARM   equ $1340    ;PCOUNT_READ shape (8B)

CUR_FD      equ $1350
CUR_FD2     equ $1351

IOREQLEN    equ 340      ;bigger than any expected run's output
IO_BUF      equ $1360    ;staging buffer, reused every readback

* -- Result addresses in the parent process bank.
* scripts/check_du.py peeks these in aux bank 1.
R_STATUS1   equ $1500
R_STATUS2   equ $1501
R_STATUS3   equ $1502
R_STATUS4   equ $1503
R_STATUS5   equ $1504
R_TRANS1    equ $1505    ;2 bytes
R_TRANS2    equ $1507
R_TRANS3    equ $1509
R_TRANS4    equ $150B
R_TRANS5    equ $150D
R_ERRTRNS5  equ $150F    ;2 bytes -- run 5 stderr trans
R_SPWNPID1  equ $1511
R_SPWNPID2  equ $1512
R_SPWNPID3  equ $1513
R_SPWNPID4  equ $1514
R_SPWNPID5  equ $1515
R_WAITPID1  equ $1516
R_WAITPID2  equ $1517
R_WAITPID3  equ $1518
R_WAITPID4  equ $1519
R_WAITPID5  equ $151A
R_DONE      equ $151B
R_ERR       equ $151C
R_STEP      equ $151D

R_DATA1     equ $1600    ;128B -- ends $1680
R_DATA2     equ $1680    ;64B  -- ends $16C0
R_DATA3     equ $16C0    ;256B -- ends $17C0
R_DATA4     equ $17C0    ;64B  -- ends $1800
R_DATA5     equ $1800    ;64B  -- ends $1840
R_ERRDATA5  equ $1840    ;64B  -- ends $1880

* -- run 6 (the pathname fence -- /mnt/MAUX/LONGDIR) lives past
* -- run 5's result area, added 2026-08-23 with du's
* -- BUILDCHILD bound (see src/bin/du.s FP_BUFLEN).
ARG_ROOT3   equ $1890    ;"/mnt/MAUX/LONGDIR"
FOUT6_PATH  equ $18B0    ;"/mnt/MAUX/FOUT6"
FERR6_PATH  equ $18C0    ;"/mnt/MAUX/FERR6"
ARGV6       equ $18D0    ;DU,ROOT3 + NULL                 (6B)
SPAWN_PARM6 equ $18E0
FDA6        equ $18F0    ;DUP/CLOSE stdout + stderr      (13B)
R_STATUS6   equ $1900
R_TRANS6    equ $1901    ;2 bytes
R_ERRTRNS6  equ $1903    ;2 bytes
R_SPWNPID6  equ $1905
R_WAITPID6  equ $1906
R_GO_REQ    equ $1907    ;gap handshake: parent publishes the
R_GO        equ $1908    ;gap number, parks until the gate
                         ;echoes it (check-ls's between-run
                         ;poison protocol)
R_DATA6     equ $1910    ;256B -- ends $1A10
R_ERRDATA6  equ $1A10    ;256B -- ends $1B10 (two long
                         ;"pathname too long" lines)

* -- runs 7 and 8 (docs/DU-DF.md), past run 6's area.
ARG_ROOT4   equ $1B20    ;"/mnt/MAUX/DUDIR/" (trailing slash)
FOUT7_PATH  equ $1B40    ;"/mnt/MAUX/FOUT7"
FOUT8_PATH  equ $1B50    ;"/mnt/MAUX/FOUT8"
ARGV7       equ $1B60    ;DU,ROOT4 + NULL                 (6B)
ARGV8       equ $1B70    ;DU + NULL                       (4B)
SPAWN_PARM7 equ $1B80
SPAWN_PARM8 equ $1B90
FDA7        equ $1BA0    ;DUP/CLOSE stdout + END          (7B)
FDA8        equ $1BB0
SPFX_PARM   equ $1BC0    ;SET_PREFIX parmlist: 1, path ptr (3B)
SPFX_PATH   equ $1BD0    ;counted "/mnt/MAUX/DUDIR" (13B)
R_STATUS7   equ $1C00
R_TRANS7    equ $1C01    ;2 bytes
R_SPWNPID7  equ $1C03
R_WAITPID7  equ $1C04
R_STATUS8   equ $1C05
R_TRANS8    equ $1C06    ;2 bytes
R_SPWNPID8  equ $1C08
R_WAITPID8  equ $1C09
R_DATA7     equ $1C10    ;256B -- ends $1D10
R_DATA8     equ $1D10    ;256B -- ends $1E10

*---------------------------------------------------------------
* Boot helpers -- identical shape to findtestb.s's own.
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

BANNER      asc   "MAUX DUTEST"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 -- absolute JSR/JMP operands to the helpers below
* depend on that, same as findtestb.s's own PARENT_PROC.
*---------------------------------------------------------------
PARENT_PROC
            stz   R_ERR
            stz   R_STEP
            stz   R_GO_REQ           ;bank-1 scratch is not part
            stz   R_GO               ;of the copied image
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
            lda   #7
            jsr   GAPWAIT
            lda   #8
            sta   R_STEP
            jsr   RUN8
            bcc   :r8ok
            jmp   P_ERR
:r8ok
            lda   #9
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
* GAPWAIT -- IN: A = gap number. Publish and park until the
* gate has re-poisoned the just-freed bank and echoed the
* number (check_ls.py's own protocol) -- the scribble lands
* strictly between one run's reap and the next one's spawn.
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
            sta   FERR5_PATH
            ldx   #0
:cp6        lda   T_FERR5,x
            sta   FERR5_PATH+1,x
            inx
            cpx   #15
            bne   :cp6

            lda   #15
            sta   FOUT6_PATH
            ldx   #0
:cp6b       lda   T_FOUT6,x
            sta   FOUT6_PATH+1,x
            inx
            cpx   #15
            bne   :cp6b

            lda   #15
            sta   FERR6_PATH
            ldx   #0
:cp6c       lda   T_FERR6,x
            sta   FERR6_PATH+1,x
            inx
            cpx   #15
            bne   :cp6c

            ldx   #0
:cp7        lda   T_SPWNDU,x
            ora   #$80
            sta   DU_SPWN_P,x
            inx
            cpx   #7
            bne   :cp7
            stz   DU_SPWN_P,x

            ldx   #0
:cp8        lda   T_ARG0DU,x
            ora   #$80
            sta   ARG0_DU,x
            inx
            cpx   #2
            bne   :cp8
            stz   ARG0_DU,x

            ldx   #0
:cp9        lda   T_ARGROOT,x
            ora   #$80
            sta   ARG_ROOT,x
            inx
            cpx   #15
            bne   :cp9
            stz   ARG_ROOT,x

            ldx   #0
:cp10       lda   T_ARGROOT2,x
            ora   #$80
            sta   ARG_ROOT2,x
            inx
            cpx   #16
            bne   :cp10
            stz   ARG_ROOT2,x

            ldx   #0
:cp10b      lda   T_ARGROOT3,x
            ora   #$80
            sta   ARG_ROOT3,x
            inx
            cpx   #17
            bne   :cp10b
            stz   ARG_ROOT3,x

            ldx   #0
:cp11       lda   T_ARGFILEB,x
            ora   #$80
            sta   ARG_FILEB,x
            inx
            cpx   #21
            bne   :cp11
            stz   ARG_FILEB,x

            ldx   #0
:cp12       lda   T_ARGNOEX,x
            ora   #$80
            sta   ARG_NOEXIST,x
            inx
            cpx   #18
            bne   :cp12
            stz   ARG_NOEXIST,x

            ldx   #0
:cp13       lda   T_ARGSFLG,x
            ora   #$80
            sta   ARG_SFLAG,x
            inx
            cpx   #2
            bne   :cp13
            stz   ARG_SFLAG,x

            ldx   #0
:cp14       lda   T_ARGAFLG,x
            ora   #$80
            sta   ARG_AFLAG,x
            inx
            cpx   #2
            bne   :cp14
            stz   ARG_AFLAG,x

            lda   #15
            sta   FOUT7_PATH
            ldx   #0
:cp15       lda   T_FOUT7,x
            sta   FOUT7_PATH+1,x
            inx
            cpx   #15
            bne   :cp15

            lda   #15
            sta   FOUT8_PATH
            ldx   #0
:cp16       lda   T_FOUT8,x
            sta   FOUT8_PATH+1,x
            inx
            cpx   #15
            bne   :cp16

            ldx   #0
:cp17       lda   T_ARGROOT4,x
            ora   #$80
            sta   ARG_ROOT4,x
            inx
            cpx   #16
            bne   :cp17
            stz   ARG_ROOT4,x

            lda   #15
            sta   SPFX_PATH
            ldx   #0
:cp18       lda   T_ARGROOT,x
            sta   SPFX_PATH+1,x
            inx
            cpx   #15
            bne   :cp18
            lda   #1
            sta   SPFX_PARM
            lda   #<SPFX_PATH
            sta   SPFX_PARM+1
            lda   #>SPFX_PATH
            sta   SPFX_PARM+2

            jsr   SETUP_ARGV
            jsr   SETUP_SPAWN
            jsr   SETUP_FDA
            rts

T_FOUT1     asc   "/mnt/MAUX/FOUT1"
T_FOUT2     asc   "/mnt/MAUX/FOUT2"
T_FOUT3     asc   "/mnt/MAUX/FOUT3"
T_FOUT4     asc   "/mnt/MAUX/FOUT4"
T_FOUT5     asc   "/mnt/MAUX/FOUT5"
T_FERR5     asc   "/mnt/MAUX/FERR5"
T_FOUT6     asc   "/mnt/MAUX/FOUT6"
T_FERR6     asc   "/mnt/MAUX/FERR6"
T_FOUT7     asc   "/mnt/MAUX/FOUT7"
T_FOUT8     asc   "/mnt/MAUX/FOUT8"
T_ARGROOT4  asc   "/mnt/MAUX/DUDIR/"
T_ARGROOT3  asc   "/mnt/MAUX/LONGDIR"
T_SPWNDU    asc   "/bin/DU"
T_ARG0DU    asc   "DU"
T_ARGROOT   asc   "/mnt/MAUX/DUDIR"
T_ARGROOT2  asc   "/mnt/MAUX/DUDIR2"
T_ARGFILEB  asc   "/mnt/MAUX/DUDIR/B.BIN"
T_ARGNOEX   asc   "/mnt/MAUX/NONEXIST"
T_ARGSFLG   asc   "-s"
T_ARGAFLG   asc   "-a"

*---------------------------------------------------------------
* SETUP_ARGV -- the 5 ARGV pointer arrays (each entry: lo,hi;
* NULL pointer terminates).
*---------------------------------------------------------------
SETUP_ARGV  lda   #<ARG0_DU
            sta   ARGV1
            lda   #>ARG0_DU
            sta   ARGV1+1
            lda   #<ARG_ROOT
            sta   ARGV1+2
            lda   #>ARG_ROOT
            sta   ARGV1+3
            stz   ARGV1+4
            stz   ARGV1+5

            lda   #<ARG0_DU
            sta   ARGV2
            lda   #>ARG0_DU
            sta   ARGV2+1
            lda   #<ARG_SFLAG
            sta   ARGV2+2
            lda   #>ARG_SFLAG
            sta   ARGV2+3
            lda   #<ARG_ROOT
            sta   ARGV2+4
            lda   #>ARG_ROOT
            sta   ARGV2+5
            stz   ARGV2+6
            stz   ARGV2+7

            lda   #<ARG0_DU
            sta   ARGV3
            lda   #>ARG0_DU
            sta   ARGV3+1
            lda   #<ARG_AFLAG
            sta   ARGV3+2
            lda   #>ARG_AFLAG
            sta   ARGV3+3
            lda   #<ARG_ROOT
            sta   ARGV3+4
            lda   #>ARG_ROOT
            sta   ARGV3+5
            stz   ARGV3+6
            stz   ARGV3+7

            lda   #<ARG0_DU
            sta   ARGV4
            lda   #>ARG0_DU
            sta   ARGV4+1
            lda   #<ARG_FILEB
            sta   ARGV4+2
            lda   #>ARG_FILEB
            sta   ARGV4+3
            stz   ARGV4+4
            stz   ARGV4+5

            lda   #<ARG0_DU
            sta   ARGV5
            lda   #>ARG0_DU
            sta   ARGV5+1
            lda   #<ARG_SFLAG
            sta   ARGV5+2
            lda   #>ARG_SFLAG
            sta   ARGV5+3
            lda   #<ARG_NOEXIST
            sta   ARGV5+4
            lda   #>ARG_NOEXIST
            sta   ARGV5+5
            lda   #<ARG_ROOT2
            sta   ARGV5+6
            lda   #>ARG_ROOT2
            sta   ARGV5+7
            stz   ARGV5+8
            stz   ARGV5+9

            lda   #<ARG0_DU
            sta   ARGV6
            lda   #>ARG0_DU
            sta   ARGV6+1
            lda   #<ARG_ROOT3
            sta   ARGV6+2
            lda   #>ARG_ROOT3
            sta   ARGV6+3
            stz   ARGV6+4
            stz   ARGV6+5

            lda   #<ARG0_DU
            sta   ARGV7
            lda   #>ARG0_DU
            sta   ARGV7+1
            lda   #<ARG_ROOT4
            sta   ARGV7+2
            lda   #>ARG_ROOT4
            sta   ARGV7+3
            stz   ARGV7+4
            stz   ARGV7+5

            lda   #<ARG0_DU
            sta   ARGV8
            lda   #>ARG0_DU
            sta   ARGV8+1
            stz   ARGV8+2
            stz   ARGV8+3
            rts

*---------------------------------------------------------------
* SETUP_SPAWN -- the 8 SPAWN_PARM triples (path ptr, argv ptr,
* fda ptr). Path is the SAME DU_SPWN_P for every run.
*---------------------------------------------------------------
SETUP_SPAWN lda   #<DU_SPWN_P
            sta   SPAWN_PARM1
            lda   #>DU_SPWN_P
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

            lda   #<DU_SPWN_P
            sta   SPAWN_PARM2
            lda   #>DU_SPWN_P
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

            lda   #<DU_SPWN_P
            sta   SPAWN_PARM3
            lda   #>DU_SPWN_P
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

            lda   #<DU_SPWN_P
            sta   SPAWN_PARM4
            lda   #>DU_SPWN_P
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

            lda   #<DU_SPWN_P
            sta   SPAWN_PARM5
            lda   #>DU_SPWN_P
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

            lda   #<DU_SPWN_P
            sta   SPAWN_PARM6
            lda   #>DU_SPWN_P
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

            lda   #<DU_SPWN_P
            sta   SPAWN_PARM7
            lda   #>DU_SPWN_P
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

            lda   #<DU_SPWN_P
            sta   SPAWN_PARM8
            lda   #>DU_SPWN_P
            sta   SPAWN_PARM8+1
            lda   #<ARGV8
            sta   SPAWN_PARM8+2
            lda   #>ARGV8
            sta   SPAWN_PARM8+3
            lda   #<FDA8
            sta   SPAWN_PARM8+4
            lda   #>FDA8
            sta   SPAWN_PARM8+5
            stz   SPAWN_PARM8+6           ;NULL envp
            stz   SPAWN_PARM8+7
            rts

*---------------------------------------------------------------
* SETUP_FDA -- static FDA bytes (opcodes and FD_STDOUT/
* FD_STDERR target bytes -- dynamic source-fd bytes are patched
* per-run once CRT+OPEN return a real fd; see RUN1-5).
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
            lda   #FDACT_DUP
            sta   FDA5+6
            lda   #FD_STDERR
            sta   FDA5+7
            lda   #FDACT_CLOSE
            sta   FDA5+9
            stz   FDA5+11
            stz   FDA5+12

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

            ldx   #6                ;FDA7/FDA8: stdout-only,
:fdcp       lda   FDA1,x            ;the same 7 bytes as FDA1
            sta   FDA7,x
            sta   FDA8,x
            dex
            bpl   :fdcp
            rts

*---------------------------------------------------------------
* CRT_FILE / OPEN_FILE / CLOSE_FD -- generic MLI helpers, same
* shape as findtestb.s's own.
*---------------------------------------------------------------
CRT_FILE    sta   CREATE_PARM+1
            stx   CREATE_PARM+2
            lda   #7
            sta   CREATE_PARM
            lda   #$C3
            sta   CREATE_PARM+3
            lda   #$06
            sta   CREATE_PARM+4
            stz   CREATE_PARM+5
            stz   CREATE_PARM+6
            lda   #$01
            sta   CREATE_PARM+7
            stz   CREATE_PARM+8
            stz   CREATE_PARM+9
            stz   CREATE_PARM+10
            stz   CREATE_PARM+11
            lda   #<CREATE_PARM
            ldx   #>CREATE_PARM
            ldy   #SYS_CREAT
            jsr   $FF00
            rts

OPEN_FILE   sta   OPEN_PARM+1
            stx   OPEN_PARM+2
            lda   #3
            sta   OPEN_PARM
            stz   OPEN_PARM+3
            stz   OPEN_PARM+4
            stz   OPEN_PARM+5
            lda   #<OPEN_PARM
            ldx   #>OPEN_PARM
            ldy   #SYS_OPEN
            jsr   $FF00
            bcs   :err
            lda   OPEN_PARM+5
            clc
            rts
:err        sec
            rts

CLOSE_FD    sta   CLOSE_PARM+1
            lda   #1
            sta   CLOSE_PARM
            lda   #<CLOSE_PARM
            ldx   #>CLOSE_PARM
            ldy   #SYS_CLOSE
            jsr   $FF00
            rts

*---------------------------------------------------------------
* RUN1-RUN4 -- CREATE+OPEN the run's stdout file, patch the
* dynamic fd into its FDAn, SPAWN DU with the run's argv, WAIT,
* CLOSE. Return carry clear on success.
*---------------------------------------------------------------
RUN1        lda   #<FOUT1_PATH
            ldx   #>FOUT1_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT1_PATH
            ldx   #>FOUT1_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA1+2
            sta   FDA1+4
            lda   #<SPAWN_PARM1
            ldx   #>SPAWN_PARM1
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID1
            lda   #<R_STATUS1
            sta   WAIT_PARM
            lda   #>R_STATUS1
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID1
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

RUN2        lda   #<FOUT2_PATH
            ldx   #>FOUT2_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT2_PATH
            ldx   #>FOUT2_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA2+2
            sta   FDA2+4
            lda   #<SPAWN_PARM2
            ldx   #>SPAWN_PARM2
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID2
            lda   #<R_STATUS2
            sta   WAIT_PARM
            lda   #>R_STATUS2
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID2
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

RUN3        lda   #<FOUT3_PATH
            ldx   #>FOUT3_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT3_PATH
            ldx   #>FOUT3_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA3+2
            sta   FDA3+4
            lda   #<SPAWN_PARM3
            ldx   #>SPAWN_PARM3
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID3
            lda   #<R_STATUS3
            sta   WAIT_PARM
            lda   #>R_STATUS3
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID3
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

RUN4        lda   #<FOUT4_PATH
            ldx   #>FOUT4_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT4_PATH
            ldx   #>FOUT4_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA4+2
            sta   FDA4+4
            lda   #<SPAWN_PARM4
            ldx   #>SPAWN_PARM4
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID4
            lda   #<R_STATUS4
            sta   WAIT_PARM
            lda   #>R_STATUS4
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID4
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* RUN5 -- like RUN1-4, but CREATE+OPEN TWO files (stdout AND
* stderr) and patch both dup/close pairs in FDA5.
*---------------------------------------------------------------
RUN5        lda   #<FOUT5_PATH
            ldx   #>FOUT5_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT5_PATH
            ldx   #>FOUT5_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA5+2
            sta   FDA5+4

            lda   #<FERR5_PATH
            ldx   #>FERR5_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FERR5_PATH
            ldx   #>FERR5_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD2
            sta   FDA5+8
            sta   FDA5+10

            lda   #<SPAWN_PARM5
            ldx   #>SPAWN_PARM5
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID5
            lda   #<R_STATUS5
            sta   WAIT_PARM
            lda   #>R_STATUS5
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID5
            lda   CUR_FD
            jsr   CLOSE_FD
            lda   CUR_FD2
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* RUN6 -- the pathname fence (/mnt/MAUX/LONGDIR): stdout AND
* stderr redirected, exactly RUN5's shape.
*---------------------------------------------------------------
RUN6        lda   #<FOUT6_PATH
            ldx   #>FOUT6_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT6_PATH
            ldx   #>FOUT6_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA6+2
            sta   FDA6+4

            lda   #<FERR6_PATH
            ldx   #>FERR6_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FERR6_PATH
            ldx   #>FERR6_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD2
            sta   FDA6+8
            sta   FDA6+10

            lda   #<SPAWN_PARM6
            ldx   #>SPAWN_PARM6
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID6
            lda   #<R_STATUS6
            sta   WAIT_PARM
            lda   #>R_STATUS6
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID6
            lda   CUR_FD
            jsr   CLOSE_FD
            lda   CUR_FD2
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* RUN7 -- trailing-slash operand, stdout only.
*---------------------------------------------------------------
RUN7        lda   #<FOUT7_PATH
            ldx   #>FOUT7_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT7_PATH
            ldx   #>FOUT7_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA7+2
            sta   FDA7+4
            lda   #<SPAWN_PARM7
            ldx   #>SPAWN_PARM7
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID7
            lda   #<R_STATUS7
            sta   WAIT_PARM
            lda   #>R_STATUS7
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID7
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* RUN8 -- no operand, cwd = /mnt/MAUX/DUDIR (SET_PREFIX first;
* the
* child inherits the parent's working directory). LAST, so the
* parent's own cwd change cannot reach an earlier run.
*---------------------------------------------------------------
RUN8        lda   #<FOUT8_PATH
            ldx   #>FOUT8_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT8_PATH
            ldx   #>FOUT8_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA8+2
            sta   FDA8+4
            lda   #<SPFX_PARM
            ldx   #>SPFX_PARM
            ldy   #SYS_SETPFX
            jsr   $FF00
            bcs   :fail
            lda   #<SPAWN_PARM8
            ldx   #>SPAWN_PARM8
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPWNPID8
            lda   #<R_STATUS8
            sta   WAIT_PARM
            lda   #>R_STATUS8
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAITPID8
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* RD_INTO_IOBUF -- OPEN(path)+READ(up to IOREQLEN bytes into
* IO_BUF)+CLOSE. Path pointer in A(lo)/X(hi) on entry. Same
* shape as findtestb.s's own.
*---------------------------------------------------------------
RD_INTO_IOBUF
            jsr   OPEN_FILE
            bcs   :err
            sta   CUR_FD
            sta   READ_PARM+1
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #<IOREQLEN
            sta   READ_PARM+4
            lda   #>IOREQLEN
            sta   READ_PARM+5
            stz   READ_PARM+6
            stz   READ_PARM+7
            lda   #4
            sta   READ_PARM
            lda   #<READ_PARM
            ldx   #>READ_PARM
            ldy   #SYS_READ
            jsr   $FF00
            bcs   :err2
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:err2       lda   CUR_FD
            jsr   CLOSE_FD
:err        sec
            rts

*---------------------------------------------------------------
* READBACK_ALL -- reopen each of the 8 output files for read and
* copy its bytes to the matching R_DATAn/R_ERRDATA5 area.
* Long-jump trampoline idiom (bcc/jmp) per findtestb.s's own
* documented reason: some targets sit past +/-127 bytes.
*---------------------------------------------------------------
READBACK_ALL
            lda   #<FOUT1_PATH
            ldx   #>FOUT1_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbAok
            jmp   FAIL_RB
:rbAok      lda   READ_PARM+6
            sta   R_TRANS1
            lda   READ_PARM+7
            sta   R_TRANS1+1
            ldy   #0
:cpA        cpy   READ_PARM+6
            beq   :cpAdone
            lda   IO_BUF,y
            sta   R_DATA1,y
            iny
            bra   :cpA
:cpAdone

            lda   #<FOUT2_PATH
            ldx   #>FOUT2_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbBok
            jmp   FAIL_RB
:rbBok      lda   READ_PARM+6
            sta   R_TRANS2
            lda   READ_PARM+7
            sta   R_TRANS2+1
            ldy   #0
:cpB        cpy   READ_PARM+6
            beq   :cpBdone
            lda   IO_BUF,y
            sta   R_DATA2,y
            iny
            bra   :cpB
:cpBdone

            lda   #<FOUT3_PATH
            ldx   #>FOUT3_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbCok
            jmp   FAIL_RB
:rbCok      lda   READ_PARM+6
            sta   R_TRANS3
            lda   READ_PARM+7
            sta   R_TRANS3+1
            ldy   #0
:cpC        cpy   READ_PARM+6
            beq   :cpCdone
            lda   IO_BUF,y
            sta   R_DATA3,y
            iny
            bra   :cpC
:cpCdone

            lda   #<FOUT4_PATH
            ldx   #>FOUT4_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbDok
            jmp   FAIL_RB
:rbDok      lda   READ_PARM+6
            sta   R_TRANS4
            lda   READ_PARM+7
            sta   R_TRANS4+1
            ldy   #0
:cpD        cpy   READ_PARM+6
            beq   :cpDdone
            lda   IO_BUF,y
            sta   R_DATA4,y
            iny
            bra   :cpD
:cpDdone

            lda   #<FOUT5_PATH
            ldx   #>FOUT5_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbEok
            jmp   FAIL_RB
:rbEok      lda   READ_PARM+6
            sta   R_TRANS5
            lda   READ_PARM+7
            sta   R_TRANS5+1
            ldy   #0
:cpE        cpy   READ_PARM+6
            beq   :cpEdone
            lda   IO_BUF,y
            sta   R_DATA5,y
            iny
            bra   :cpE
:cpEdone

            lda   #<FERR5_PATH
            ldx   #>FERR5_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbFok
            jmp   FAIL_RB
:rbFok      lda   READ_PARM+6
            sta   R_ERRTRNS5
            lda   READ_PARM+7
            sta   R_ERRTRNS5+1
            ldy   #0
:cpF        cpy   READ_PARM+6
            beq   :cpFdone
            lda   IO_BUF,y
            sta   R_ERRDATA5,y
            iny
            bra   :cpF
:cpFdone

            lda   #<FOUT6_PATH
            ldx   #>FOUT6_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbGok
            jmp   FAIL_RB
:rbGok      lda   READ_PARM+6
            sta   R_TRANS6
            lda   READ_PARM+7
            sta   R_TRANS6+1
            ldy   #0
:cpG        cpy   READ_PARM+6
            beq   :cpGdone
            lda   IO_BUF,y
            sta   R_DATA6,y
            iny
            bra   :cpG
:cpGdone

            lda   #<FERR6_PATH
            ldx   #>FERR6_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbHok
            jmp   FAIL_RB
:rbHok      lda   READ_PARM+6
            sta   R_ERRTRNS6
            lda   READ_PARM+7
            sta   R_ERRTRNS6+1
            ldy   #0
:cpH        cpy   READ_PARM+6
            beq   :cpHdone
            lda   IO_BUF,y
            sta   R_ERRDATA6,y
            iny
            bra   :cpH
:cpHdone

            lda   #<FOUT7_PATH
            ldx   #>FOUT7_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbIok
            jmp   FAIL_RB
:rbIok  lda   READ_PARM+6
            sta   R_TRANS7
            lda   READ_PARM+7
            sta   R_TRANS7+1
            ldy   #0
:cpI        cpy   READ_PARM+6
            beq   :cpIdone
            lda   IO_BUF,y
            sta   R_DATA7,y
            iny
            bra   :cpI
:cpIdone

            lda   #<FOUT8_PATH
            ldx   #>FOUT8_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbJok
            jmp   FAIL_RB
:rbJok  lda   READ_PARM+6
            sta   R_TRANS8
            lda   READ_PARM+7
            sta   R_TRANS8+1
            ldy   #0
:cpJ        cpy   READ_PARM+6
            beq   :cpJdone
            lda   IO_BUF,y
            sta   R_DATA8,y
            iny
            bra   :cpJ
:cpJdone
            clc
            rts
FAIL_RB     sec
            rts

PAR_PROC_LEN equ *-PARENT_PROC
