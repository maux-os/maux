*---------------------------------------------------------------
* lstestb.s -- image body for lstest.s. Split out so the top-
* level stays a thin MANIFEST -- same reason catreadtestb.s is
* split from catreadtest.s (see that file's header,
* learning:01M051EM2HQ3ZVJTR1W9P3G86J).
*
* Shape: identical boot sequence to catreadtestb.s (BankCopy the
* parent process image into bank 1, synthesize its trapframe,
* SCH_CREATE/START it), but PARENT_PROC itself spawns LS four
* times instead of CAT twice:
*   run 1: LS /mnt/MAUX/LSDIR                (plain listing)
*   run 2: LS -l /mnt/MAUX/LSDIR (-l directory listing)
*   run 3: LS -l /mnt/MAUX/LSDIR/bigFile.BIN (-l single-file
*   GFI)
*   run 4: LS /mnt/MAUX/NOSUCH               (nonexistent path)
*   run 5: LS /mnt/MAUX/LSDIR                (run 1 again, byte
*                                          for byte -- the
*                                          poison-between-runs
*                                          gate, sec 25)
* stdout is redirected to a fresh ProDOS file per run
* (LSOUT1-4); run 4 ALSO redirects stderr, to LSERR4. After all
* four runs finish, PARENT_PROC reopens each output file for
* READ and copies its bytes into a fixed R_DATAn landing
* address, exactly like catreadtestb.s's own READ_BACK --
* scripts/check_ls.py peeks those addresses in aux bank 1 the
* same way scripts/check_catread.py peeks R_DATA.
*
* Every scratch structure below (paths, argv arrays, fdactions,
* MLI parmlists) lives at a FIXED low address ($1000-$1450) and
* is filled by RUNTIME code, never assembled as static data at
* that address -- those addresses are outside PARENT_PROC's own
* bank-copied span (BOOT_CPY_PAR copies only PARENT_PROC's CODE,
* PAR_PROC_LEN bytes, from main to bank 1), so nothing is there
* until PARENT_PROC, now running IN bank 1, writes it. This is
* the same reason catreadtestb.s's SETUP_PATHS fills even the
* fully-static "CAT" argv0 string at runtime instead of
* declaring it with `asc` at that address -- mirrored here, not
* reinvented.
*---------------------------------------------------------------


* -- Scratch (parent process bank, runtime-populated -- see
* header). Kept below $1500 with the same wide safety margin
* catreadtestb.s's own $1000-$1292 scratch/result range keeps
* below wherever PARENT_PROC's actual CODE lands (well north of
* $2000, given how many kernel modules precede it) -- see that
* file's own equ block for the precedent.
LSOUT1_PATH   equ $1500    ;MLI pathname, "/mnt/MAUX/LSOUT1"
LSOUT2_PATH   equ $1520    ;"/mnt/MAUX/LSOUT2"
LSOUT3_PATH   equ $1540    ;"/mnt/MAUX/LSOUT3"
LSOUT4_PATH   equ $1560    ;"/mnt/MAUX/LSOUT4"
LSERR4_PATH   equ $1580    ;"/mnt/MAUX/LSERR4"
LS_SPAWN_PATH equ $1050    ;hi-bit NUL, "/bin/LS" -- spawn
                           ;target, all 4 runs
ARG0_LS       equ $1060    ;hi-bit NUL, "LS" -- argv[0], all
                           ;runs
ARG_FLAG_L    equ $1068    ;hi-bit NUL, "-l"
ARG_DIR       equ $1070    ;hi-bit NUL, "/mnt/MAUX/LSDIR"
ARG_FILE      equ $1080    ;hi-bit NUL,
                           ;"/mnt/MAUX/LSDIR/bigFile.BIN" --
                           ;typed
                           ;in the SAME mixed case
                           ;scripts/build_ls_image.py gave the
                           ;file, since GET_FILE_INFO returns no
                           ;case flags for ls to re-derive
                           ;display case from (see
                           ;docs/a2/B.LS.TXT-style note in the
                           ;report: assumption to reconcile)
ARG_NOSUCH    equ $15C0    ;hi-bit NUL, "/mnt/MAUX/NOSUCH"

ARGV1         equ $10B0    ;LS,DIR + NULL term            (6B)
ARGV2         equ $10B8    ;LS,-l,DIR + NULL term         (8B)
ARGV3         equ $10C0    ;LS,-l,FILE + NULL term        (8B)
ARGV4         equ $10C8    ;LS,NOSUCH + NULL term         (6B)

SPAWN_PARM1   equ $10D0    ;path/argv/fda ptr triple, run 1
SPAWN_PARM2   equ $10D8    ;run 2
SPAWN_PARM3   equ $10E0    ;run 3
SPAWN_PARM4   equ $10E8    ;run 4

* fdactions -- 3-byte records (ruling 10), FDACT_END a bare 0
* terminator (not a padded record) -- same shape as
* catreadtestb.s's FDA_BUF. Runs 1-3 redirect stdout only; run 4
* redirects stdout AND stderr. The DUP/CLOSE fd-number bytes
* (marked below) are runtime-patched once CRT+OPEN return the
* real fd; everything else here is filled once by SETUP_PATHS.
FDA1          equ $10F0    ;DUP(stdout,fd) CLOSE(fd) END   (7B)
FDA2          equ $1100    ;                               (7B)
FDA3          equ $1110    ;                               (7B)
FDA4          equ $1120    ;DUP/CLOSE stdout, DUP/CLOSE
                           ;stderr, END                   (13B)

OPEN_PARM     equ $1130    ;PCOUNT_OPEN shape (6B)
CREATE_PARM   equ $1140    ;PCOUNT_CREATE shape (12B)
CLOSE_PARM    equ $1150    ;PCOUNT_CLOSE shape (2B)
WAIT_PARM     equ $1158    ;status-dest pointer (2B)
READ_PARM     equ $1160    ;PCOUNT_READ shape (8B)

CUR_FD        equ $1170    ;fd just opened, reused run to run
CUR_FD2       equ $1171    ;run 4's second fd (stderr file)

IOREQLEN      equ 250      ;SC_READ request size -- comfortably
                           ;bigger than any expected run's
                           ;output
IO_BUF        equ $1180    ;staging buffer, reused every
                           ;readback (256B -- ends $1280)

* -- Result addresses in the parent process bank.
* scripts/check_ls.py peeks these in aux bank 1, same convention
* as scripts/check_catread.py's R_* peeks.
R_STATUS1     equ $1280
R_STATUS2     equ $1281
R_STATUS3     equ $1282
R_STATUS4     equ $1283
R_TRANS1      equ $1284    ;2 bytes
R_TRANS2      equ $1286    ;2 bytes
R_TRANS3      equ $1288    ;2 bytes
R_TRANS4      equ $128A    ;2 bytes -- run 4 STDOUT trans (want
                           ;0)
R_ERRTRANS4   equ $128C    ;2 bytes -- run 4 STDERR trans
R_SPAWN_PID1  equ $128E
R_SPAWN_PID2  equ $128F
R_SPAWN_PID3  equ $1290
R_SPAWN_PID4  equ $1291
R_WAIT_PID1   equ $1292
R_WAIT_PID2   equ $1293
R_WAIT_PID3   equ $1294
R_WAIT_PID4   equ $1295
R_DONE        equ $1296
R_ERR         equ $1297
R_STEP        equ $1298

R_DATA1       equ $12A0    ;run 1 stdout   (64B  -- ends $12E0)
R_DATA2       equ $12E0    ;run 2 stdout   (224B -- ends $13C0)
R_DATA3       equ $13C0    ;run 3 stdout   (64B  -- ends $1400)
R_DATA4       equ $1400    ;run 4 stdout   (64B  -- ends $1440,
                           ;expected empty -- sized like
                           ;R_DATA1/ R_DATA3, not to IOREQLEN,
                           ;so a BUGGY ls that prints
                           ;unexpectedly to stdout on the not-
                           ;found path can't overrun into
                           ;R_ERRDATA4's own bytes)
R_ERRDATA4    equ $1440    ;run 4 stderr   (64B  -- ends $1480)

* -- THE POISON-BETWEEN-RUNS GATE (docs/STICKY.md sec 25). Run 5
* -- is a byte-for-byte REPEAT of run 1 -- same argv (ARGV1
* -- itself, not a copy), different output file -- and the four
* -- gaps between runs are HANDSHAKES: PARENT_PROC parks on
* -- R_GO until scripts/check_ls.py has scribbled $A5 over the
* -- retained child bank's uncleared region. Under lazy free
* -- that bank is not a fresh one holding some unrelated
* -- occupant's leftovers; it is the SAME bank the previous ls
* -- ran in, holding the same program's own layout -- which is
* -- exactly why a write-before-read bug there reads a
* -- PLAUSIBLE value instead of obvious garbage, and why it
* -- shows up on the second invocation only.
* --
* -- The handshake exists because the poison has to land BETWEEN
* -- two runs, and a driver that just steps in chunks and hopes
* -- would race the next spawn. See WAIT_GO.
R_STATUS5     equ $1480
R_TRANS5      equ $1481    ;2 bytes
R_SPAWN_PID5  equ $1483
R_WAIT_PID5   equ $1484
R_GO_REQ      equ $1485    ;parent -> driver: "gap N reached"
R_GO          equ $1486    ;driver -> parent: "gap N released"
LSOUT5_PATH   equ $15A0    ;"/mnt/MAUX/LSOUT5"
SPAWN_PARM5   equ $14A0    ;path/argv/fda ptr triple, run 5
FDA5          equ $14A8    ;DUP(stdout,fd) CLOSE(fd) END   (7B)
R_DATA5       equ $14B0    ;run 5 stdout   (64B  -- ends $14F0)

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

BANNER      asc   "MAUX LSTEST"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 (BOOT_CPY_PAR) -- absolute JSR/JMP operands to the
* helper subroutines below depend on that, same as
* catreadtestb.s's own PARENT_PROC.
*---------------------------------------------------------------
PARENT_PROC
            stz   R_ERR
            stz   R_STEP
            stz   R_GO
            stz   R_GO_REQ
            jsr   SETUP_PATHS

            lda   #1
            sta   R_STEP
            jsr   RUN1
            bcc   :r1ok
            jmp   P_ERR
:r1ok       lda   #1
            jsr   WAIT_GO
            lda   #2
            sta   R_STEP
            jsr   RUN2
            bcc   :r2ok
            jmp   P_ERR
:r2ok       lda   #2
            jsr   WAIT_GO
            lda   #3
            sta   R_STEP
            jsr   RUN3
            bcc   :r3ok
            jmp   P_ERR
:r3ok       lda   #3
            jsr   WAIT_GO
            lda   #4
            sta   R_STEP
            jsr   RUN4
            bcc   :r4ok
            jmp   P_ERR
:r4ok       lda   #4
            jsr   WAIT_GO
            lda   #5
            sta   R_STEP
            jsr   RUN5
            bcc   :r5ok
            jmp   P_ERR
:r5ok
            lda   #6
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
* WAIT_GO -- A = gap number. Publishes it in R_GO_REQ and parks
* until scripts/check_ls.py writes the same number to R_GO,
* which it does only AFTER poisoning the bank the run that just
* finished ran in (docs/STICKY.md sec 25's poison-between-runs
* gate). Nothing else in this file spins on memory; a driver
* that merely stepped in chunks and poked when it noticed would
* race the next SYS_SPAWN, and a poison that lands DURING a
* spawn proves nothing about the run after it.
*
* The park is a plain read loop, not a syscall: the parent is
* the only runnable process here (every child has been reaped),
* the timer tick keeps preempting and rescheduling it, and A is
* preserved throughout so the compare stays against the gap
* number the caller asked for.
*---------------------------------------------------------------
WAIT_GO     sta   R_GO_REQ
:spin       cmp   R_GO
            bne   :spin
            rts

*---------------------------------------------------------------
* SETUP_PATHS -- fills every static (argv-time-known) structure:
* the 5 own-file MLI pathnames, the 6 hi-bit NUL argv/spawn
* strings, the 4 ARGV pointer arrays, the 4 SPAWN_PARM pointer
* triples, and the STATIC bytes of the 4 FDA arrays (opcodes and
* FD_STDOUT/FD_STDERR target bytes -- the dynamic source-fd
* bytes are patched per-run once CRT+OPEN return a real fd; see
* RUN1-4).
*---------------------------------------------------------------
SETUP_PATHS
            ;-- MLI pathnames (13-char content, 1-byte count
            ;prefix), plain 7-bit ASCII -- no high bit, per TRM
            ;ch. 2 ("ProDOS clears this high bit").
            lda   #16
            sta   LSOUT1_PATH
            ldx   #0
:cp1        lda   T_LSOUT1,x
            sta   LSOUT1_PATH+1,x
            inx
            cpx   #16
            bne   :cp1

            lda   #16
            sta   LSOUT2_PATH
            ldx   #0
:cp2        lda   T_LSOUT2,x
            sta   LSOUT2_PATH+1,x
            inx
            cpx   #16
            bne   :cp2

            lda   #16
            sta   LSOUT3_PATH
            ldx   #0
:cp3        lda   T_LSOUT3,x
            sta   LSOUT3_PATH+1,x
            inx
            cpx   #16
            bne   :cp3

            lda   #16
            sta   LSOUT4_PATH
            ldx   #0
:cp4        lda   T_LSOUT4,x
            sta   LSOUT4_PATH+1,x
            inx
            cpx   #16
            bne   :cp4

            lda   #16
            sta   LSERR4_PATH
            ldx   #0
:cp5        lda   T_LSERR4,x
            sta   LSERR4_PATH+1,x
            inx
            cpx   #16
            bne   :cp5

            lda   #16
            sta   LSOUT5_PATH
            ldx   #0
:cp5b       lda   T_LSOUT5,x
            sta   LSOUT5_PATH+1,x
            inx
            cpx   #16
            bne   :cp5b

            ;-- hi-bit NUL-terminated liba strings (spawn path +
            ;argv elements).
            ldx   #0
:cp6        lda   T_SPAWNLS,x
            ora   #$80
            sta   LS_SPAWN_PATH,x
            inx
            cpx   #7
            bne   :cp6
            stz   LS_SPAWN_PATH,x

            ldx   #0
:cp7        lda   T_ARG0LS,x
            ora   #$80
            sta   ARG0_LS,x
            inx
            cpx   #2
            bne   :cp7
            stz   ARG0_LS,x

            ldx   #0
:cp8        lda   T_FLAGL,x
            ora   #$80
            sta   ARG_FLAG_L,x
            inx
            cpx   #2
            bne   :cp8
            stz   ARG_FLAG_L,x

            ldx   #0
:cp9        lda   T_ARGDIR,x
            ora   #$80
            sta   ARG_DIR,x
            inx
            cpx   #15
            bne   :cp9
            stz   ARG_DIR,x

            ldx   #0
:cp10       lda   T_ARGFILE,x
            ora   #$80
            sta   ARG_FILE,x
            inx
            cpx   #27
            bne   :cp10
            stz   ARG_FILE,x

            ldx   #0
:cp11       lda   T_ARGNOSUCH,x
            ora   #$80
            sta   ARG_NOSUCH,x
            inx
            cpx   #16
            bne   :cp11
            stz   ARG_NOSUCH,x

            ;-- ARGV pointer arrays (each entry: lo,hi; NULL
            ;pointer terminates).
            lda   #<ARG0_LS
            sta   ARGV1
            lda   #>ARG0_LS
            sta   ARGV1+1
            lda   #<ARG_DIR
            sta   ARGV1+2
            lda   #>ARG_DIR
            sta   ARGV1+3
            stz   ARGV1+4
            stz   ARGV1+5

            lda   #<ARG0_LS
            sta   ARGV2
            lda   #>ARG0_LS
            sta   ARGV2+1
            lda   #<ARG_FLAG_L
            sta   ARGV2+2
            lda   #>ARG_FLAG_L
            sta   ARGV2+3
            lda   #<ARG_DIR
            sta   ARGV2+4
            lda   #>ARG_DIR
            sta   ARGV2+5
            stz   ARGV2+6
            stz   ARGV2+7

            lda   #<ARG0_LS
            sta   ARGV3
            lda   #>ARG0_LS
            sta   ARGV3+1
            lda   #<ARG_FLAG_L
            sta   ARGV3+2
            lda   #>ARG_FLAG_L
            sta   ARGV3+3
            lda   #<ARG_FILE
            sta   ARGV3+4
            lda   #>ARG_FILE
            sta   ARGV3+5
            stz   ARGV3+6
            stz   ARGV3+7

            lda   #<ARG0_LS
            sta   ARGV4
            lda   #>ARG0_LS
            sta   ARGV4+1
            lda   #<ARG_NOSUCH
            sta   ARGV4+2
            lda   #>ARG_NOSUCH
            sta   ARGV4+3
            stz   ARGV4+4
            stz   ARGV4+5

            ;-- SPAWN_PARM triples (path ptr, argv ptr, fda
            ;ptr).
            lda   #<LS_SPAWN_PATH
            sta   SPAWN_PARM1
            lda   #>LS_SPAWN_PATH
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

            lda   #<LS_SPAWN_PATH
            sta   SPAWN_PARM2
            lda   #>LS_SPAWN_PATH
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

            lda   #<LS_SPAWN_PATH
            sta   SPAWN_PARM3
            lda   #>LS_SPAWN_PATH
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

            lda   #<LS_SPAWN_PATH
            sta   SPAWN_PARM4
            lda   #>LS_SPAWN_PATH
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

            ;-- run 5 reuses ARGV1 verbatim: it must be the SAME
            ;-- invocation as run 1, or comparing their two
            ;-- outputs proves nothing.
            lda   #<LS_SPAWN_PATH
            sta   SPAWN_PARM5
            lda   #>LS_SPAWN_PATH
            sta   SPAWN_PARM5+1
            lda   #<ARGV1
            sta   SPAWN_PARM5+2
            lda   #>ARGV1
            sta   SPAWN_PARM5+3
            lda   #<FDA5
            sta   SPAWN_PARM5+4
            lda   #>FDA5
            sta   SPAWN_PARM5+5
            stz   SPAWN_PARM5+6           ;NULL envp
            stz   SPAWN_PARM5+7

            ;-- FDA static bytes (dynamic fd bytes, marked
            ;below,
            ;are patched by each RUNn just before spawning).
            lda   #FDACT_DUP
            sta   FDA1+0
            lda   #FD_STDOUT
            sta   FDA1+1
            ;FDA1+2 = dup source fd -- patched by RUN1
            lda   #FDACT_CLOSE
            sta   FDA1+3
            ;FDA1+4 = close target fd -- patched by RUN1
            stz   FDA1+5
            stz   FDA1+6                ;FDACT_END

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
            sta   FDA5+0
            lda   #FD_STDOUT
            sta   FDA5+1
            lda   #FDACT_CLOSE
            sta   FDA5+3
            stz   FDA5+5
            stz   FDA5+6

            lda   #FDACT_DUP
            sta   FDA4+0
            lda   #FD_STDOUT
            sta   FDA4+1
            lda   #FDACT_CLOSE
            sta   FDA4+3
            stz   FDA4+5
            lda   #FDACT_DUP
            sta   FDA4+6
            lda   #FD_STDERR
            sta   FDA4+7
            lda   #FDACT_CLOSE
            sta   FDA4+9
            stz   FDA4+11
            stz   FDA4+12               ;FDACT_END
            rts

T_LSOUT1    asc   "/mnt/MAUX/LSOUT1"
T_LSOUT2    asc   "/mnt/MAUX/LSOUT2"
T_LSOUT3    asc   "/mnt/MAUX/LSOUT3"
T_LSOUT4    asc   "/mnt/MAUX/LSOUT4"
T_LSERR4    asc   "/mnt/MAUX/LSERR4"
T_LSOUT5    asc   "/mnt/MAUX/LSOUT5"
T_SPAWNLS   asc   "/bin/LS"
T_ARG0LS    asc   "LS"
T_FLAGL     asc   "-l"
T_ARGDIR    asc   "/mnt/MAUX/LSDIR"
T_ARGFILE   asc   "/mnt/MAUX/LSDIR/bigFile.BIN"
T_ARGNOSUCH asc   "/mnt/MAUX/NOSUCH"

*---------------------------------------------------------------
* CRT_FILE / OPEN_FILE / CLOSE_FD -- generic MLI helpers, same
* shape as catreadtestb.s's CRT_OUT_FILE/OPEN_COMMON/CLOSE_FD.
* CRT_FILE/OPEN_FILE take the path pointer in A(lo)/X(hi).
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
* RUN1/RUN2/RUN3 -- CREATE+OPEN the run's stdout file, patch the
* dynamic fd into its FDAn, SPAWN LS with the run's argv, WAIT,
* CLOSE. Return carry clear on success (all steps succeeded).
*---------------------------------------------------------------
RUN1        lda   #<LSOUT1_PATH
            ldx   #>LSOUT1_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<LSOUT1_PATH
            ldx   #>LSOUT1_PATH
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
            sta   R_SPAWN_PID1
            lda   #<R_STATUS1
            sta   WAIT_PARM
            lda   #>R_STATUS1
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAIT_PID1
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

RUN2        lda   #<LSOUT2_PATH
            ldx   #>LSOUT2_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<LSOUT2_PATH
            ldx   #>LSOUT2_PATH
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
            sta   R_SPAWN_PID2
            lda   #<R_STATUS2
            sta   WAIT_PARM
            lda   #>R_STATUS2
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAIT_PID2
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

RUN3        lda   #<LSOUT3_PATH
            ldx   #>LSOUT3_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<LSOUT3_PATH
            ldx   #>LSOUT3_PATH
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
            sta   R_SPAWN_PID3
            lda   #<R_STATUS3
            sta   WAIT_PARM
            lda   #>R_STATUS3
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAIT_PID3
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* RUN4 -- like RUN1-3, but CREATE+OPEN TWO files (stdout AND
* stderr) and patch both dup/close pairs in FDA4.
*---------------------------------------------------------------
RUN4        lda   #<LSOUT4_PATH
            ldx   #>LSOUT4_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<LSOUT4_PATH
            ldx   #>LSOUT4_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA4+2
            sta   FDA4+4

            lda   #<LSERR4_PATH
            ldx   #>LSERR4_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<LSERR4_PATH
            ldx   #>LSERR4_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD2
            sta   FDA4+8
            sta   FDA4+10

            lda   #<SPAWN_PARM4
            ldx   #>SPAWN_PARM4
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPAWN_PID4
            lda   #<R_STATUS4
            sta   WAIT_PARM
            lda   #>R_STATUS4
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAIT_PID4
            lda   CUR_FD
            jsr   CLOSE_FD
            lda   CUR_FD2
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* RUN5 -- RUN1 again, exactly: same spawn path, same ARGV1, same
* single stdout redirect. Only the output file differs, so the
* two results can be compared byte for byte. It runs LAST, after
* two `-l` runs and an error run, and after the driver has
* poisoned the retained bank -- so it fails if ls carries ANY
* state between invocations, whether that is an uncleared cell
* it read before writing or a flag a previous run left set.
*---------------------------------------------------------------
RUN5        lda   #<LSOUT5_PATH
            ldx   #>LSOUT5_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<LSOUT5_PATH
            ldx   #>LSOUT5_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA5+2
            sta   FDA5+4
            lda   #<SPAWN_PARM5
            ldx   #>SPAWN_PARM5
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R_SPAWN_PID5
            lda   #<R_STATUS5
            sta   WAIT_PARM
            lda   #>R_STATUS5
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            sta   R_WAIT_PID5
            lda   CUR_FD
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* RD_INTO_IOBUF -- OPEN(path)+READ(up to IOREQLEN bytes into
* IO_BUF)+CLOSE. Path pointer in A(lo)/X(hi) on entry. On return
* (carry clear): the fd used has been closed, IO_BUF holds the
* bytes read, and READ_PARM+6/+7 hold the 2-byte transfer count
* (untouched by the CLOSE that follows the READ, since CLOSE_FD
* only touches CLOSE_PARM) -- callers read that field directly.
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
* READBACK_ALL -- reopen each of the 6 output files for read and
* copy its bytes to the matching R_DATAn/R_ERRDATA4 landing
* area, recording each transfer count. Assumes every transfer
* count fits in one byte (READ_PARM+7 stays 0) -- true for every
* expected output here (largest is run 2's ~180-byte -l
* listing).
*---------------------------------------------------------------
*---------------------------------------------------------------
* NOTE on the "bcc :ok / jmp FAIL_RB" idiom below: a plain `bcs
* FAIL_RB` here is a "Bad Jump ... Too long" assembly error --
* FAIL_RB is well past the +/-127-byte 6502 branch range from
* every one of these 5 blocks. Same trampoline src/bin/ls.s's
* own MAINLOOP already uses for its own far jumps (see that
* file's :chkeq1/:chkeq2 -- "long jump -- :done is far past this
* loop").
*---------------------------------------------------------------
READBACK_ALL
            lda   #<LSOUT1_PATH
            ldx   #>LSOUT1_PATH
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

            lda   #<LSOUT2_PATH
            ldx   #>LSOUT2_PATH
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

            lda   #<LSOUT3_PATH
            ldx   #>LSOUT3_PATH
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

            lda   #<LSOUT4_PATH
            ldx   #>LSOUT4_PATH
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

            lda   #<LSERR4_PATH
            ldx   #>LSERR4_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbEok
            jmp   FAIL_RB
:rbEok      lda   READ_PARM+6
            sta   R_ERRTRANS4
            lda   READ_PARM+7
            sta   R_ERRTRANS4+1
            ldy   #0
:cpE        cpy   READ_PARM+6
            beq   :cpEdone
            lda   IO_BUF,y
            sta   R_ERRDATA4,y
            iny
            bra   :cpE
:cpEdone

            lda   #<LSOUT5_PATH
            ldx   #>LSOUT5_PATH
            jsr   RD_INTO_IOBUF
            bcc   :rbFok
            jmp   FAIL_RB
:rbFok      lda   READ_PARM+6
            sta   R_TRANS5
            lda   READ_PARM+7
            sta   R_TRANS5+1
            ldy   #0
:cpF        cpy   READ_PARM+6
            beq   :cpFdone
            lda   IO_BUF,y
            sta   R_DATA5,y
            iny
            bra   :cpF
:cpFdone
            clc
            rts
FAIL_RB     sec
            rts

PAR_PROC_LEN equ *-PARENT_PROC
