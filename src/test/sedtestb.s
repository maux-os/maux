*---------------------------------------------------------------
* sedtestb.s -- image body for sedtest.s (`make check-sed`).
* Same boot shape as findtestb.s (BankCopy a hand-synthesized
* parent process into bank 1, SCH_CREATE/START it), but the
* NINE runs are TABLE-DRIVEN rather than nine hand-copied RUNn
* routines: every run redirects BOTH stdout and stderr (so a
* clean run's empty stderr is asserted too), the per-run output
* files are "/mnt/MAUX/SOUT<n>"/"/mnt/MAUX/SERR<n>", and the
* result
* areas are strided off one base each -- which is what lets ONE
* RUNCASE/RDCASE pair replace ~500 duplicated lines. The
* per-run output files are lettered (SOUTA..SOUTK) because
* eleven runs outrun the digits.
*
*   run 1: SED s/alpha/beta/ SEDIN         (s + auto-print)
*   run 2: SED -n /ell/p SEDIN             (-n, RE address, p)
*   run 3: SED s/l*/X/g SEDIN              (star, zero-length
*          match advance, g)
*   run 4: SED 2,3d SEDIN                  (numeric range + d)
*   run 5: SED s/gamma/[&]/;s/l/L/2 SEDIN  (';', '&', Nth)
*   run 6: SED -n $p SEDIN SEDIN2          ($ + two FILEs as
*          ONE stream: prints SEDIN2's last line only)
*   run 7: SED q SEDIN                     (quit after line 1)
*   run 8: SED s/x/y/ /mnt/MAUX/NOSUCH        (open failure:
*          stderr + exit 2)
*   run 9: SED k/a/b/ SEDIN                (no such command --
*          LOUD bad-script refusal, exit 2)
*   run 10: SED s/x/y/ SEDIN3              (input whose final
*          line has NO terminator: maux appends CR where the
*          host preserves the absence -- the divergence is
*          ASSERTED, docs/E2E.md sec 4)
*   run 11: SED s/./&&&&&&&&&&/g x3 SEDIN   (the pattern space
*          grown past PSMAX on line 1: nothing prints, it dies
*          LOUDLY -- "sed: pattern space overflow", exit 2;
*          asserted divergence, host prints it all)
*
* Runs 1-7's expected bytes are HOST-DIFFERENTIAL: scripts/
* build_sed_image.py runs the SAME scripts through the host's
* /usr/bin/sed and translates (docs/E2E.md sec 4 -- the
* reference implementation is the oracle). Runs 8-9 are maux's
* own error paths, asserted as invariants with NAMED divergence
* entries in scripts/check_sed.py, as are runs 10-11's boundary
* behaviors (docs/E2E.md sec 5: inputs sit on the tree's own
* declared limits, not on the happy path).
*
* Between every pair of runs the parent parks on the R_GO
* handshake so the gate can RE-POISON the just-freed bank --
* every run after the first executes warm in run 1's bank, so a
* pre-boot poison alone is consumed by run 1 (adversarial
* review N3; check_ls.py's own between-run protocol).
*---------------------------------------------------------------

NRUNS       equ 11
DSTP        equ $30      ;zp pair -- RDCASE's strided result
                         ;destination (parent-bank private zp)

* -- argv words, hi-bit NUL strings, staged at runtime --
W_ARG0      equ $1000    ;"SED"
W_S1        equ $1018    ;"s/alpha/beta/"
W_WN        equ $1030    ;"-n"
W_S2        equ $1048    ;"/ell/p"
W_S3        equ $1060    ;"s/l*/X/g"
W_S4        equ $1078    ;"2,3d"
W_S5        equ $1090    ;"s/gamma/[&]/;s/l/L/2"
W_S6        equ $10A8    ;"$p"
W_S7        equ $10C0    ;"q"
W_S8        equ $10D8    ;"s/x/y/"
W_S9        equ $10F0    ;"k/a/b/"
W_FIN       equ $1108    ;"/mnt/MAUX/SEDIN"
W_FIN2      equ $1120    ;"/mnt/MAUX/SEDIN2"
W_NOSUCH    equ $1138    ;"/mnt/MAUX/NOSUCH"
SED_SPWN_P  equ $1150 ;"/bin/SED" -- spawn path, all runs
W_FIN3      equ $1160    ;"/mnt/MAUX/SEDIN3"
W_S11       equ $1180    ;3 x s/./&&&&&&&&&&/g -- 50 chars,
                         ;its own wide slot (ends $11B3)

ARGVT       equ $1200    ;11 argv arrays, 16 bytes apart --
                         ;run n's argv lives at ARGVT + n*16
                         ;(ends $12B0)
SPAWN_PARM  equ $12B0    ;ONE spawn parm; argv ptr patched per
                         ;run (path/fda/envp constant)
FDA         equ $12C0    ;ONE fdactions block: DUP/CLOSE stdout
                         ;+ DUP/CLOSE stderr; fds patched per
                         ;run (13B)
OPEN_PARM   equ $12D0
CREATE_PARM equ $12E0
CLOSE_PARM  equ $12F0
WAIT_PARM   equ $1300
READ_PARM   equ $1310
CUR_FD      equ $1320
CUR_FD2     equ $1321
RUNIDX      equ $1322
LOOPI       equ $1323

FOUT_PATH   equ $1330    ;counted "/mnt/MAUX/SOUT<c>" -- rebuilt
FERR_PATH   equ $1340    ;counted "/mnt/MAUX/SERR<c>" -- per run

IOREQLEN    equ 340
IO_BUF      equ $1350    ;ends $14A4

* -- Result addresses, strided. scripts/check_sed.py peeks
* -- these in aux bank 1: run n's status at R_STATUS0+n, its
* -- stdout at R_DATA0 + n*128, its stderr at R_ERRDATA0 +
* -- n*64, trans counts 2 bytes apart.
R_STATUS0   equ $14B0    ;11B
R_SPWNPID0  equ $14C0    ;11B
R_WAITPID0  equ $14D0    ;11B
R_TRANS0    equ $14E0    ;22B
R_ERRTRNS0  equ $1500    ;22B
R_DONE      equ $1518
R_ERR       equ $1519
R_STEP      equ $151A
R_GO_REQ    equ $151B    ;gap handshake: parent publishes the
R_GO        equ $151C    ;gap number, parks until the gate
                         ;echoes it (check-ls's between-run
                         ;poison protocol)
R_DATA0     equ $1600    ;11 x 128B -- ends $1B80
R_ERRDATA0  equ $1C00    ;11 x 64B  -- ends $1EC0

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

BANNER      asc   "MAUX SEDTEST"
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
            jsr   SETUP_ALL

            stz   LOOPI
:runlp      lda   LOOPI
            cmp   #NRUNS
            bcs   :rdphase
            clc
            adc   #1              ;R_STEP 1-9: spawn phase
            sta   R_STEP
            ldx   LOOPI
            jsr   RUNCASE
            bcc   :runok
            jmp   P_ERR
:runok      inc   LOOPI
            lda   LOOPI
            cmp   #NRUNS
            bcs   :runlp             ;last run: no gap after it
            jsr   GAPWAIT            ;A = the gap number
            bra   :runlp

:rdphase    stz   LOOPI
:rdlp       lda   LOOPI
            cmp   #NRUNS
            bcs   :alldone
            clc
            adc   #$11            ;R_STEP $11-$19: readback
            sta   R_STEP
            ldx   LOOPI
            jsr   RDCASE
            bcc   :rdok
            jmp   P_ERR
:rdok       inc   LOOPI
            bra   :rdlp

:alldone    lda   #$AA
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
* SETUP_ALL -- stage every argv word (hi-bit NUL), the 9 argv
* arrays, the shared spawn parm and fdactions block.
*---------------------------------------------------------------
SETUP_ALL   ldx   #0
:cpA0       lda   T_ARG0,x
            ora   #$80
            sta   W_ARG0,x
            inx
            cpx   #3
            bne   :cpA0
            stz   W_ARG0,x

            ldx   #0
:cpS1       lda   T_S1,x
            ora   #$80
            sta   W_S1,x
            inx
            cpx   #13
            bne   :cpS1
            stz   W_S1,x

            ldx   #0
:cpWN       lda   T_WN,x
            ora   #$80
            sta   W_WN,x
            inx
            cpx   #2
            bne   :cpWN
            stz   W_WN,x

            ldx   #0
:cpS2       lda   T_S2,x
            ora   #$80
            sta   W_S2,x
            inx
            cpx   #6
            bne   :cpS2
            stz   W_S2,x

            ldx   #0
:cpS3       lda   T_S3,x
            ora   #$80
            sta   W_S3,x
            inx
            cpx   #8
            bne   :cpS3
            stz   W_S3,x

            ldx   #0
:cpS4       lda   T_S4,x
            ora   #$80
            sta   W_S4,x
            inx
            cpx   #4
            bne   :cpS4
            stz   W_S4,x

            ldx   #0
:cpS5       lda   T_S5,x
            ora   #$80
            sta   W_S5,x
            inx
            cpx   #20
            bne   :cpS5
            stz   W_S5,x

            ldx   #0
:cpS6       lda   T_S6,x
            ora   #$80
            sta   W_S6,x
            inx
            cpx   #2
            bne   :cpS6
            stz   W_S6,x

            ldx   #0
:cpS7       lda   T_S7,x
            ora   #$80
            sta   W_S7,x
            inx
            cpx   #1
            bne   :cpS7
            stz   W_S7,x

            ldx   #0
:cpS8       lda   T_S8,x
            ora   #$80
            sta   W_S8,x
            inx
            cpx   #6
            bne   :cpS8
            stz   W_S8,x

            ldx   #0
:cpS9       lda   T_S9,x
            ora   #$80
            sta   W_S9,x
            inx
            cpx   #6
            bne   :cpS9
            stz   W_S9,x

            ldx   #0
:cpFI       lda   T_FIN,x
            ora   #$80
            sta   W_FIN,x
            inx
            cpx   #15
            bne   :cpFI
            stz   W_FIN,x

            ldx   #0
:cpF2       lda   T_FIN2,x
            ora   #$80
            sta   W_FIN2,x
            inx
            cpx   #16
            bne   :cpF2
            stz   W_FIN2,x

            ldx   #0
:cpNS       lda   T_NOSUCH,x
            ora   #$80
            sta   W_NOSUCH,x
            inx
            cpx   #16
            bne   :cpNS
            stz   W_NOSUCH,x

            ldx   #0
:cpF3       lda   T_FIN3,x
            ora   #$80
            sta   W_FIN3,x
            inx
            cpx   #16
            bne   :cpF3
            stz   W_FIN3,x

            ldx   #0
:cpS11      lda   T_S11,x
            ora   #$80
            sta   W_S11,x
            inx
            cpx   #50
            bne   :cpS11
            stz   W_S11,x

            ldx   #0
:cpSP       lda   T_SPWNSED,x
            ora   #$80
            sta   SED_SPWN_P,x
            inx
            cpx   #8
            bne   :cpSP
            stz   SED_SPWN_P,x

            jsr   SETUP_ARGV
            jsr   SETUP_SPAWN
            jsr   SETUP_FDA
            rts

T_ARG0      asc   "SED"
T_S1        asc   "s/alpha/beta/"
T_WN        asc   "-n"
T_S2        asc   "/ell/p"
T_S3        asc   "s/l*/X/g"
T_S4        asc   "2,3d"
T_S5        asc   "s/gamma/[&]/;s/l/L/2"
T_S6        asc   "$p"
T_S7        asc   "q"
T_S8        asc   "s/x/y/"
T_S9        asc   "k/a/b/"
T_FIN       asc   "/mnt/MAUX/SEDIN"
T_FIN2      asc   "/mnt/MAUX/SEDIN2"
T_NOSUCH    asc   "/mnt/MAUX/NOSUCH"
T_FIN3      asc   "/mnt/MAUX/SEDIN3"
* -- T_S11 is one 50-char word laid out over two adjacent
* -- asc lines (a single line would break real Merlin's
* -- 64-char source-line limit): three s/./&&&&&&&&&&/g in a
* -- row -- every char x1000, past PSMAX on the FIRST line.
T_S11       asc   "s/./&&&&&&&&&&/g;s/./&&&&&&&&&&/g;"
            asc   "s/./&&&&&&&&&&/g"
T_SPWNSED   asc   "/bin/SED"
T_SOUTP     asc   "/mnt/MAUX/SOUT"
T_SERRP     asc   "/mnt/MAUX/SERR"

*---------------------------------------------------------------
* SETUP_ARGV -- run n's argv array at ARGVT + n*16 (lo,hi
* pairs, NULL pointer terminates). The run list is this file's
* header.
*---------------------------------------------------------------
SETUP_ARGV  lda   #<W_ARG0        ;run 1: SED s/alpha/beta/ FIN
            sta   ARGVT
            lda   #>W_ARG0
            sta   ARGVT+1
            lda   #<W_S1
            sta   ARGVT+2
            lda   #>W_S1
            sta   ARGVT+3
            lda   #<W_FIN
            sta   ARGVT+4
            lda   #>W_FIN
            sta   ARGVT+5
            stz   ARGVT+6
            stz   ARGVT+7

            lda   #<W_ARG0        ;run 2: SED -n /ell/p FIN
            sta   ARGVT+16
            lda   #>W_ARG0
            sta   ARGVT+17
            lda   #<W_WN
            sta   ARGVT+18
            lda   #>W_WN
            sta   ARGVT+19
            lda   #<W_S2
            sta   ARGVT+20
            lda   #>W_S2
            sta   ARGVT+21
            lda   #<W_FIN
            sta   ARGVT+22
            lda   #>W_FIN
            sta   ARGVT+23
            stz   ARGVT+24
            stz   ARGVT+25

            lda   #<W_ARG0        ;run 3: SED s/l*/X/g FIN
            sta   ARGVT+32
            lda   #>W_ARG0
            sta   ARGVT+33
            lda   #<W_S3
            sta   ARGVT+34
            lda   #>W_S3
            sta   ARGVT+35
            lda   #<W_FIN
            sta   ARGVT+36
            lda   #>W_FIN
            sta   ARGVT+37
            stz   ARGVT+38
            stz   ARGVT+39

            lda   #<W_ARG0        ;run 4: SED 2,3d FIN
            sta   ARGVT+48
            lda   #>W_ARG0
            sta   ARGVT+49
            lda   #<W_S4
            sta   ARGVT+50
            lda   #>W_S4
            sta   ARGVT+51
            lda   #<W_FIN
            sta   ARGVT+52
            lda   #>W_FIN
            sta   ARGVT+53
            stz   ARGVT+54
            stz   ARGVT+55

            lda   #<W_ARG0        ;run 5: SED s5 FIN
            sta   ARGVT+64
            lda   #>W_ARG0
            sta   ARGVT+65
            lda   #<W_S5
            sta   ARGVT+66
            lda   #>W_S5
            sta   ARGVT+67
            lda   #<W_FIN
            sta   ARGVT+68
            lda   #>W_FIN
            sta   ARGVT+69
            stz   ARGVT+70
            stz   ARGVT+71

            lda   #<W_ARG0        ;run 6: SED -n $p FIN FIN2
            sta   ARGVT+80
            lda   #>W_ARG0
            sta   ARGVT+81
            lda   #<W_WN
            sta   ARGVT+82
            lda   #>W_WN
            sta   ARGVT+83
            lda   #<W_S6
            sta   ARGVT+84
            lda   #>W_S6
            sta   ARGVT+85
            lda   #<W_FIN
            sta   ARGVT+86
            lda   #>W_FIN
            sta   ARGVT+87
            lda   #<W_FIN2
            sta   ARGVT+88
            lda   #>W_FIN2
            sta   ARGVT+89
            stz   ARGVT+90
            stz   ARGVT+91

            lda   #<W_ARG0        ;run 7: SED q FIN
            sta   ARGVT+96
            lda   #>W_ARG0
            sta   ARGVT+97
            lda   #<W_S7
            sta   ARGVT+98
            lda   #>W_S7
            sta   ARGVT+99
            lda   #<W_FIN
            sta   ARGVT+100
            lda   #>W_FIN
            sta   ARGVT+101
            stz   ARGVT+102
            stz   ARGVT+103

            lda   #<W_ARG0        ;run 8: SED s/x/y/ NOSUCH
            sta   ARGVT+112
            lda   #>W_ARG0
            sta   ARGVT+113
            lda   #<W_S8
            sta   ARGVT+114
            lda   #>W_S8
            sta   ARGVT+115
            lda   #<W_NOSUCH
            sta   ARGVT+116
            lda   #>W_NOSUCH
            sta   ARGVT+117
            stz   ARGVT+118
            stz   ARGVT+119

            lda   #<W_ARG0        ;run 9: SED y/a/b/ FIN
            sta   ARGVT+128
            lda   #>W_ARG0
            sta   ARGVT+129
            lda   #<W_S9
            sta   ARGVT+130
            lda   #>W_S9
            sta   ARGVT+131
            lda   #<W_FIN
            sta   ARGVT+132
            lda   #>W_FIN
            sta   ARGVT+133
            stz   ARGVT+134
            stz   ARGVT+135

            lda   #<W_ARG0        ;run 10: SED s/x/y/ FIN3
            sta   ARGVT+144
            lda   #>W_ARG0
            sta   ARGVT+145
            lda   #<W_S8
            sta   ARGVT+146
            lda   #>W_S8
            sta   ARGVT+147
            lda   #<W_FIN3
            sta   ARGVT+148
            lda   #>W_FIN3
            sta   ARGVT+149
            stz   ARGVT+150
            stz   ARGVT+151

            lda   #<W_ARG0        ;run 11: SED <s/l/64a/g> FIN
            sta   ARGVT+160
            lda   #>W_ARG0
            sta   ARGVT+161
            lda   #<W_S11
            sta   ARGVT+162
            lda   #>W_S11
            sta   ARGVT+163
            lda   #<W_FIN
            sta   ARGVT+164
            lda   #>W_FIN
            sta   ARGVT+165
            stz   ARGVT+166
            stz   ARGVT+167
            rts

*---------------------------------------------------------------
* SETUP_SPAWN / SETUP_FDA -- the shared blocks. RUNCASE patches
* SPAWN_PARM's argv pointer and FDA's four fd bytes per run.
*---------------------------------------------------------------
SETUP_SPAWN lda   #<SED_SPWN_P
            sta   SPAWN_PARM
            lda   #>SED_SPWN_P
            sta   SPAWN_PARM+1
            stz   SPAWN_PARM+2    ;argv ptr -- per run
            stz   SPAWN_PARM+3
            lda   #<FDA
            sta   SPAWN_PARM+4
            lda   #>FDA
            sta   SPAWN_PARM+5
            stz   SPAWN_PARM+6    ;NULL envp
            stz   SPAWN_PARM+7
            rts

SETUP_FDA   lda   #FDACT_DUP
            sta   FDA+0
            lda   #FD_STDOUT
            sta   FDA+1
            lda   #FDACT_CLOSE
            sta   FDA+3
            stz   FDA+5
            lda   #FDACT_DUP
            sta   FDA+6
            lda   #FD_STDERR
            sta   FDA+7
            lda   #FDACT_CLOSE
            sta   FDA+9
            stz   FDA+11
            stz   FDA+12
            rts

*---------------------------------------------------------------
* BLDPATHS -- FOUT_PATH/FERR_PATH := counted
* "/mnt/MAUX/SOUT<c>"/
* "/mnt/MAUX/SERR<c>", c = 'A' + RUNIDX.
*---------------------------------------------------------------
BLDPATHS    lda   #15
            sta   FOUT_PATH
            sta   FERR_PATH
            ldx   #0
:cpp        lda   T_SOUTP,x
            sta   FOUT_PATH+1,x
            lda   T_SERRP,x
            sta   FERR_PATH+1,x
            inx
            cpx   #14
            bne   :cpp
            lda   RUNIDX
            clc
            adc   #"A"               ;SOUTA..SOUTK -- letters,
            sta   FOUT_PATH+15       ;eleven runs outrun the
            sta   FERR_PATH+15       ;digits and ':' is not a
            rts                      ;legal ProDOS name char

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
* RUNCASE -- IN: X = run index 0..NRUNS-1. CREATE+OPEN the
* run's SOUT/SERR files, patch the shared FDA and the spawn
* parm's argv pointer, SPAWN, WAIT, CLOSE. Carry set = harness
* failure (NOT a sed failure -- sed's own exit status lands in
* R_STATUS0+n via WAIT).
*---------------------------------------------------------------
RUNCASE     stx   RUNIDX
            jsr   BLDPATHS
            lda   #<FOUT_PATH
            ldx   #>FOUT_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FOUT_PATH
            ldx   #>FOUT_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD
            sta   FDA+2
            sta   FDA+4
            lda   #<FERR_PATH
            ldx   #>FERR_PATH
            jsr   CRT_FILE
            bcs   :fail
            lda   #<FERR_PATH
            ldx   #>FERR_PATH
            jsr   OPEN_FILE
            bcs   :fail
            sta   CUR_FD2
            sta   FDA+8
            sta   FDA+10

            lda   RUNIDX          ;argv ptr = ARGVT + n*16
            asl   a
            asl   a
            asl   a
            asl   a
            clc
            adc   #<ARGVT
            sta   SPAWN_PARM+2
            lda   #>ARGVT
            adc   #0
            sta   SPAWN_PARM+3

            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            ldx   RUNIDX
            sta   R_SPWNPID0,x
            lda   #<R_STATUS0     ;WAIT status -> R_STATUS0+n
            clc
            adc   RUNIDX
            sta   WAIT_PARM
            lda   #>R_STATUS0
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            ldx   RUNIDX
            sta   R_WAITPID0,x
            lda   CUR_FD
            jsr   CLOSE_FD
            lda   CUR_FD2
            jsr   CLOSE_FD
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* RD_INTO_IOBUF -- OPEN(path)+READ(<=IOREQLEN into IO_BUF)+
* CLOSE. Path ptr in A(lo)/X(hi). Same shape as findtestb.s's.
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
* RDCASE -- IN: X = run index. Reopen the run's SOUT/SERR and
* copy their bytes to R_DATA0 + n*128 / R_ERRDATA0 + n*64,
* trans counts to R_TRANS0/R_ERRTRNS0 + 2n.
*---------------------------------------------------------------
RDCASE      stx   RUNIDX
            jsr   BLDPATHS
            lda   #<FOUT_PATH
            ldx   #>FOUT_PATH
            jsr   RD_INTO_IOBUF
            bcs   :fail
            lda   RUNIDX
            asl   a
            tax
            lda   READ_PARM+6
            sta   R_TRANS0,x
            lda   READ_PARM+7
            sta   R_TRANS0+1,x
            lda   RUNIDX          ;dest = R_DATA0 + n*128
            and   #1
            beq   :even
            lda   #$80
:even       sta   DSTP
            lda   RUNIDX
            lsr   a
            clc
            adc   #>R_DATA0
            sta   DSTP+1
            ldy   #0
:cpo        cpy   READ_PARM+6
            beq   :odone
            lda   IO_BUF,y
            sta   (DSTP),y
            iny
            bra   :cpo
:odone
            lda   #<FERR_PATH
            ldx   #>FERR_PATH
            jsr   RD_INTO_IOBUF
            bcs   :fail
            lda   RUNIDX
            asl   a
            tax
            lda   READ_PARM+6
            sta   R_ERRTRNS0,x
            lda   READ_PARM+7
            sta   R_ERRTRNS0+1,x
            lda   RUNIDX          ;dest = R_ERRDATA0 + n*64
            and   #3
            asl   a
            asl   a
            asl   a
            asl   a
            asl   a
            asl   a
            sta   DSTP
            lda   RUNIDX
            lsr   a
            lsr   a
            clc
            adc   #>R_ERRDATA0
            sta   DSTP+1
            ldy   #0
:cpe        cpy   READ_PARM+6
            beq   :edone
            lda   IO_BUF,y
            sta   (DSTP),y
            iny
            bra   :cpe
:edone      clc
            rts
:fail       sec
            rts

PAR_PROC_LEN equ *-PARENT_PROC
