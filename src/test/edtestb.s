*---------------------------------------------------------------
* edtestb.s -- image body for edtest.s.
* Split out so the top-level stays a thin MANIFEST: real
* Merlin holds the resident top-level source AND the PUT
* file being read in the same 41215-byte buffer, so every
* byte here would come off every module's budget.
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J)
*---------------------------------------------------------------


* -- Result addresses in the parent process bank (bank 1). --
R_LEN1      equ   $1200      ;byte count staged from
                             ;/mnt/MAUX/EDFILE
R_STAGE1    equ   $1210      ;up to 48 bytes of /mnt/MAUX/EDFILE
R_SPAWN1_PID    equ $1250
R_SPAWN1_STAT equ $1251
R_WAIT1_PID     equ $1252

R_LEN2A     equ   $1260      ;byte count staged from EDOUT2
                             ;(g/re/p output)
R_STAGE2A   equ   $1270      ;up to 48 bytes
R_LEN2B     equ   $12B0      ;byte count staged from EDFILE2
R_STAGE2B   equ   $12C0      ;up to 48 bytes
R_SPAWN2_PID    equ $1300
R_SPAWN2_STAT equ $1301
R_WAIT2_PID     equ $1302

R_DONE      equ   $12F0
R_ERR       equ   $12F1
R_STEP      equ   $12F2

* -- 2026-08-19 audit-fix phases (session 3 = findings 1, 2, 4,
* 5, 6; session 4 = finding 3's cold/negative case). All still
* comfortably below PARENT_PROC's own load address ($2000) --
* $1200-$1FFF is free scratch in this raw boot environment (no
* ProDOS running IN bank 1; see file header). --
R3MAXLEN    equ   250        ;session 3's capture is the busiest
                             ;script in this harness
R_LEN3      equ   $1310
R_STAGE3    equ   $1320      ;up to R3MAXLEN bytes -- ends $1419
R_LEN3B     equ   $141A
R_STAGE3B   equ   $1420 ;up to 96 bytes of /mnt/MAUX/EDFILE3
R_SPAWN3_PID  equ $1480
R_SPAWN3_STAT equ $1481
R_WAIT3_PID   equ $1482

R_LEN4      equ   $1490
R_STAGE4    equ   $14A0      ;up to 48 bytes
R_SPAWN4_PID  equ $14D0
R_SPAWN4_STAT equ $14D1
R_WAIT4_PID   equ $14D2

* -- Session 5: `j` (join) and `=` (print line number), added
* this round (task: "ed grows j and ="). One buffer, one stdout
* capture (R_STAGE5) plus the final written-file capture
* (R_STAGE5B), same two-capture shape as session 3.
R5MAXLEN    equ   128
R_LEN5      equ   $1500
R_STAGE5    equ   $1510      ;up to R5MAXLEN bytes -- ends $158F
R_LEN5B     equ   $1590
R_STAGE5B   equ   $15A0 ;up to 32 bytes of /mnt/MAUX/EDFILE5
R_SPAWN5_PID  equ $15D0
R_SPAWN5_STAT equ $15D1
R_WAIT5_PID   equ $15D2

* -- Session 6 (2026-09-02, filename-on-launch task): `ed FILE`
* -- loads FILE at startup instead of a bare launch + `r`.
* -- 6a is the positive case (a real fixture, loaded via argv
* -- not `r`, then `,p`/bare `w` prove the load AND the
* -- remembered filename); 6b is the negative case (a path that
* -- does NOT exist -- must stay `?`, no crash, filename not
* -- remembered, same path `e NOSUCHFILE` already takes). --
R_LEN6      equ   $1600      ;byte count from EDOUT6 (`,p`
                             ;capture of the launch-loaded file)
R_STAGE6    equ   $1610      ;up to 48 bytes
R_LEN6B     equ   $1650      ;byte count from EDFILE6, RE-READ
                             ;after the bare `w`
R_STAGE6B   equ   $1660      ;up to 32 bytes
R_SPAWN6_PID  equ $1690
R_SPAWN6_STAT equ $1691
R_WAIT6_PID   equ $1692

R_LEN6N     equ   $16A0      ;byte count from EDCAP6N (the
                             ;nonexistent-path negative case)
R_STAGE6N   equ   $16B0      ;up to 16 bytes
R_SPAWN6N_PID  equ $16D0
R_SPWN6N_STAT equ $16D1
R_WAIT6N_PID   equ $16D2

*---------------------------------------------------------------
* Boot helpers -- identical pattern to fileproctest.s.
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

BANNER      asc   "MAUX EDTEST"
BANNER_END

*---------------------------------------------------------------
* Parent process image -- copied verbatim into bank 1 (see file
* header).
*---------------------------------------------------------------
PARENT_PROC
            ldx   #0                 ;zero the dum cells
:zcells     stz   EDT_CELLS,x        ;(edtestb2.s tail)
            inx
            cpx   #EDT_CELLS_END-EDT_CELLS
            bne   :zcells
            stz   R_ERR
            stz   R_STEP

* ---- Session 1: `a` three lines (two containing BANK), `.`,
* `w`, `q` ----
* ---- EDSCR1 (the script fed to `ed` on fd 0) is ON ed.po
* ---- already: every session's fixture/script file below is
* ---- staged at BUILD time by scripts/build_ed_image.py
* ---- (FIXTURES, 2026-09-12) -- they used to be written here
* ---- from text embedded in this image, which is what left
* ---- MAUXEDTEST.SYSTEM only 4 bytes under PMLI_IBF_BASE (docs/
* ---- CONSOLE-VT102.md sec 7; same debt shape de7ea88 retired
* ---- for MAUXEXTEST). The harness now only OPENs them. ----
            lda   #1
            sta   R_STEP

* ---- create EDOUT1 (`ed`'s captured stdout) ----
            lda   #<PATH_EDOUT1
            ldx   #>PATH_EDOUT1
            jsr   CRT_BY_PATH
            lda   #<PATH_EDOUT1
            ldx   #>PATH_EDOUT1
            jsr   OPEN_BY_PATH
            sta   S1OUTFD

* ---- open EDSCR1 for `ed`'s stdin ----
            lda   #<PATH_EDSCR1
            ldx   #>PATH_EDSCR1
            jsr   OPEN_BY_PATH
            sta   S1INFD

            lda   #2
            sta   R_STEP
            lda   #FDACT_DUP
            sta   FDA1
            lda   #FD_STDIN
            sta   FDA1+1
            lda   S1INFD
            sta   FDA1+2
            lda   #FDACT_DUP
            sta   FDA1+3
            lda   #FD_STDOUT
            sta   FDA1+4
            lda   S1OUTFD
            sta   FDA1+5
            stz   FDA1+6

            lda   #<FDA1
            sta   SFDAPTR
            lda   #>FDA1
            sta   SFDAPTR+1
            jsr   SPAWN_ED
            sta   R_SPAWN1_PID

            lda   #<R_SPAWN1_STAT
            sta   WSTATUSPTR
            lda   #>R_SPAWN1_STAT
            sta   WSTATUSPTR+1
            jsr   WAIT_ONE
            sta   R_WAIT1_PID

            lda   #3
            sta   R_STEP
            lda   S1INFD
            jsr   CLOSE_FD
            lda   S1OUTFD
            jsr   CLOSE_FD

            lda   #<PATH_EDFILE
            ldx   #>PATH_EDFILE
            jsr   OPEN_BY_PATH
            sta   S1RFD
            lda   S1RFD
            sta   RFD
            lda   #<R_STAGE1
            sta   RBUFPTR
            lda   #>R_STAGE1
            sta   RBUFPTR+1
            lda   #48
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN1
            lda   S1RFD
            jsr   CLOSE_FD

* ---- Session 2: `r`, `g/BANK/p`, `3s/BANK/&X/`, `w`, `q` ----
* ---- EDSCR2 staged by build_ed_image.py (see session 1). ----
            lda   #4
            sta   R_STEP

            lda   #<PATH_EDOUT2
            ldx   #>PATH_EDOUT2
            jsr   CRT_BY_PATH
            lda   #<PATH_EDOUT2
            ldx   #>PATH_EDOUT2
            jsr   OPEN_BY_PATH
            sta   S2OUTFD

            lda   #<PATH_EDSCR2
            ldx   #>PATH_EDSCR2
            jsr   OPEN_BY_PATH
            sta   S2INFD

            lda   #5
            sta   R_STEP
            lda   #FDACT_DUP
            sta   FDA2
            lda   #FD_STDIN
            sta   FDA2+1
            lda   S2INFD
            sta   FDA2+2
            lda   #FDACT_DUP
            sta   FDA2+3
            lda   #FD_STDOUT
            sta   FDA2+4
            lda   S2OUTFD
            sta   FDA2+5
            stz   FDA2+6

            lda   #<FDA2
            sta   SFDAPTR
            lda   #>FDA2
            sta   SFDAPTR+1
            jsr   SPAWN_ED
            sta   R_SPAWN2_PID

            lda   #<R_SPAWN2_STAT
            sta   WSTATUSPTR
            lda   #>R_SPAWN2_STAT
            sta   WSTATUSPTR+1
            jsr   WAIT_ONE
            sta   R_WAIT2_PID

            lda   #6
            sta   R_STEP
            lda   S2INFD
            jsr   CLOSE_FD
            lda   S2OUTFD
            jsr   CLOSE_FD

            lda   #<PATH_EDOUT2
            ldx   #>PATH_EDOUT2
            jsr   OPEN_BY_PATH
            sta   S2ARFD
            lda   S2ARFD
            sta   RFD
            lda   #<R_STAGE2A
            sta   RBUFPTR
            lda   #>R_STAGE2A
            sta   RBUFPTR+1
            lda   #48
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN2A
            lda   S2ARFD
            jsr   CLOSE_FD

            lda   #<PATH_EDFILE2
            ldx   #>PATH_EDFILE2
            jsr   OPEN_BY_PATH
            sta   S2BRFD
            lda   S2BRFD
            sta   RFD
            lda   #<R_STAGE2B
            sta   RBUFPTR
            lda   #>R_STAGE2B
            sta   RBUFPTR+1
            lda   #48
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN2B
            lda   S2BRFD
            jsr   CLOSE_FD

* ---- Session 3: 2026-08-19 audit-fix phases (findings 1, 2, 4,
* 5, 6 -- s///N + bad-flag, no-match /re/, m/t incl. self-range,
* bare address, bare `,`/`;`) -- one buffer, one capture ----
            lda   #7
            sta   R_STEP
* ---- EDSCR3 staged by build_ed_image.py (see session 1). ----

            lda   #<PATH_EDOUT3
            ldx   #>PATH_EDOUT3
            jsr   CRT_BY_PATH
            lda   #<PATH_EDOUT3
            ldx   #>PATH_EDOUT3
            jsr   OPEN_BY_PATH
            sta   S3OUTFD

            lda   #<PATH_EDSCR3
            ldx   #>PATH_EDSCR3
            jsr   OPEN_BY_PATH
            sta   S3INFD

            lda   #8
            sta   R_STEP
            lda   #FDACT_DUP
            sta   FDA3
            lda   #FD_STDIN
            sta   FDA3+1
            lda   S3INFD
            sta   FDA3+2
            lda   #FDACT_DUP
            sta   FDA3+3
            lda   #FD_STDOUT
            sta   FDA3+4
            lda   S3OUTFD
            sta   FDA3+5
            stz   FDA3+6

            lda   #<FDA3
            sta   SFDAPTR
            lda   #>FDA3
            sta   SFDAPTR+1
            jsr   SPAWN_ED
            sta   R_SPAWN3_PID

*-- SEGMENT CUT POINT for the REL form (S9-PLAN 6b): this blob
*-- is one global-label-free zone larger than as's source
*-- window, so the generator needs a zone boundary here. No
*-- :local straddles this line (verified by the safe-cut scan)
*-- and nothing references the label -- it emits no bytes.
ETB_SEG2
            lda   #<R_SPAWN3_STAT
            sta   WSTATUSPTR
            lda   #>R_SPAWN3_STAT
            sta   WSTATUSPTR+1
            jsr   WAIT_ONE
            sta   R_WAIT3_PID

            lda   #9
            sta   R_STEP
            lda   S3INFD
            jsr   CLOSE_FD
            lda   S3OUTFD
            jsr   CLOSE_FD

            lda   #<PATH_EDOUT3
            ldx   #>PATH_EDOUT3
            jsr   OPEN_BY_PATH
            sta   S3ARFD
            lda   S3ARFD
            sta   RFD
            lda   #<R_STAGE3
            sta   RBUFPTR
            lda   #>R_STAGE3
            sta   RBUFPTR+1
            lda   #<R3MAXLEN
            sta   RMAXLEN
            lda   #>R3MAXLEN
            sta   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN3
            lda   S3ARFD
            jsr   CLOSE_FD

            lda   #<PATH_EDFILE3
            ldx   #>PATH_EDFILE3
            jsr   OPEN_BY_PATH
            sta   S3BRFD
            lda   S3BRFD
            sta   RFD
            lda   #<R_STAGE3B
            sta   RBUFPTR
            lda   #>R_STAGE3B
            sta   RBUFPTR+1
            lda   #96
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN3B
            lda   S3BRFD
            jsr   CLOSE_FD

* ---- Session 4: bare `w` with NOTHING remembered yet (a fresh
* ed process -- finding 3's negative case) must stay `?` ----
            lda   #10
            sta   R_STEP
* ---- EDSCR4 staged by build_ed_image.py (see session 1). ----

            lda   #<PATH_EDOUT4
            ldx   #>PATH_EDOUT4
            jsr   CRT_BY_PATH
            lda   #<PATH_EDOUT4
            ldx   #>PATH_EDOUT4
            jsr   OPEN_BY_PATH
            sta   S4OUTFD

            lda   #<PATH_EDSCR4
            ldx   #>PATH_EDSCR4
            jsr   OPEN_BY_PATH
            sta   S4INFD

            lda   #11
            sta   R_STEP
            lda   #FDACT_DUP
            sta   FDA4
            lda   #FD_STDIN
            sta   FDA4+1
            lda   S4INFD
            sta   FDA4+2
            lda   #FDACT_DUP
            sta   FDA4+3
            lda   #FD_STDOUT
            sta   FDA4+4
            lda   S4OUTFD
            sta   FDA4+5
            stz   FDA4+6

            lda   #<FDA4
            sta   SFDAPTR
            lda   #>FDA4
            sta   SFDAPTR+1
            jsr   SPAWN_ED
            sta   R_SPAWN4_PID

            lda   #<R_SPAWN4_STAT
            sta   WSTATUSPTR
            lda   #>R_SPAWN4_STAT
            sta   WSTATUSPTR+1
            jsr   WAIT_ONE
            sta   R_WAIT4_PID

            lda   #12
            sta   R_STEP
            lda   S4INFD
            jsr   CLOSE_FD
            lda   S4OUTFD
            jsr   CLOSE_FD

            lda   #<PATH_EDOUT4
            ldx   #>PATH_EDOUT4
            jsr   OPEN_BY_PATH
            sta   S4ARFD
            lda   S4ARFD
            sta   RFD
            lda   #<R_STAGE4
            sta   RBUFPTR
            lda   #>R_STAGE4
            sta   RBUFPTR+1
            lda   #48
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN4
            lda   S4ARFD
            jsr   CLOSE_FD

* ---- Session 5: `j` (join) and `=` (print line number) -- see
* the trace above PATH_EDSCR5 in edtestb2.s for the full
* per-command trace ----
            lda   #13
            sta   R_STEP
* ---- EDSCR5 staged by build_ed_image.py (see session 1). ----

            lda   #<PATH_EDOUT5
            ldx   #>PATH_EDOUT5
            jsr   CRT_BY_PATH
            lda   #<PATH_EDOUT5
            ldx   #>PATH_EDOUT5
            jsr   OPEN_BY_PATH
            sta   S5OUTFD

            lda   #<PATH_EDSCR5
            ldx   #>PATH_EDSCR5
            jsr   OPEN_BY_PATH
            sta   S5INFD

            lda   #14
            sta   R_STEP
            lda   #FDACT_DUP
            sta   FDA5
            lda   #FD_STDIN
            sta   FDA5+1
            lda   S5INFD
            sta   FDA5+2
            lda   #FDACT_DUP
            sta   FDA5+3
            lda   #FD_STDOUT
            sta   FDA5+4
            lda   S5OUTFD
            sta   FDA5+5
            stz   FDA5+6

            lda   #<FDA5
            sta   SFDAPTR
            lda   #>FDA5
            sta   SFDAPTR+1
            jsr   SPAWN_ED
            sta   R_SPAWN5_PID

            lda   #<R_SPAWN5_STAT
            sta   WSTATUSPTR
            lda   #>R_SPAWN5_STAT
            sta   WSTATUSPTR+1
            jsr   WAIT_ONE
            sta   R_WAIT5_PID

            lda   #15
            sta   R_STEP
            lda   S5INFD
            jsr   CLOSE_FD
            lda   S5OUTFD
            jsr   CLOSE_FD

            lda   #<PATH_EDOUT5
            ldx   #>PATH_EDOUT5
            jsr   OPEN_BY_PATH
            sta   S5ARFD
            lda   S5ARFD
            sta   RFD
            lda   #<R_STAGE5
            sta   RBUFPTR
            lda   #>R_STAGE5
            sta   RBUFPTR+1
            lda   #<R5MAXLEN
            sta   RMAXLEN
            lda   #>R5MAXLEN
            sta   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN5
            lda   S5ARFD
            jsr   CLOSE_FD

            lda   #<PATH_EDFILE5
            ldx   #>PATH_EDFILE5
            jsr   OPEN_BY_PATH
            sta   S5BRFD
            lda   S5BRFD
            sta   RFD
            lda   #<R_STAGE5B
            sta   RBUFPTR
            lda   #>R_STAGE5B
            sta   RBUFPTR+1
            lda   #32
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN5B
            lda   S5BRFD
            jsr   CLOSE_FD

* ---- Session 6a: `ed /mnt/MAUX/EDFILE6` -- launch-load, `,p`,
* bare `w` round-trip ----
* ---- EDFILE6 (the launch-load fixture) and EDSCR6 (its script)
* ---- are ON ed.po already, staged by build_ed_image.py (see
* ---- session 1). ----
            lda   #16
            sta   R_STEP

            lda   #<PATH_EDOUT6
            ldx   #>PATH_EDOUT6
            jsr   CRT_BY_PATH
            lda   #<PATH_EDOUT6
            ldx   #>PATH_EDOUT6
            jsr   OPEN_BY_PATH
            sta   S6OUTFD

            lda   #<PATH_EDSCR6
            ldx   #>PATH_EDSCR6
            jsr   OPEN_BY_PATH
            sta   S6INFD

            lda   #17
            sta   R_STEP
            lda   #FDACT_DUP
            sta   FDA6
            lda   #FD_STDIN
            sta   FDA6+1
            lda   S6INFD
            sta   FDA6+2
            lda   #FDACT_DUP
            sta   FDA6+3
            lda   #FD_STDOUT
            sta   FDA6+4
            lda   S6OUTFD
            sta   FDA6+5
            stz   FDA6+6

            lda   #<FDA6
            sta   SFDAPTR
            lda   #>FDA6
            sta   SFDAPTR+1

            lda   #<AV_ED0
            sta   ARGV_ARR6
            lda   #>AV_ED0
            sta   ARGV_ARR6+1
            lda   #<AV_EDFILE6
            sta   ARGV_ARR6+2
            lda   #>AV_EDFILE6
            sta   ARGV_ARR6+3
            stz   ARGV_ARR6+4
            stz   ARGV_ARR6+5
            lda   #<ARGV_ARR6
            sta   AVPTR
            lda   #>ARGV_ARR6
            sta   AVPTR+1

            jsr   SPAWN_ED_A
            sta   R_SPAWN6_PID

            lda   #<R_SPAWN6_STAT
            sta   WSTATUSPTR
            lda   #>R_SPAWN6_STAT
            sta   WSTATUSPTR+1
            jsr   WAIT_ONE
            sta   R_WAIT6_PID

            lda   #18
            sta   R_STEP
            lda   S6INFD
            jsr   CLOSE_FD
            lda   S6OUTFD
            jsr   CLOSE_FD

            lda   #<PATH_EDOUT6
            ldx   #>PATH_EDOUT6
            jsr   OPEN_BY_PATH
            sta   S6ARFD
            lda   S6ARFD
            sta   RFD
            lda   #<R_STAGE6
            sta   RBUFPTR
            lda   #>R_STAGE6
            sta   RBUFPTR+1
            lda   #48
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN6
            lda   S6ARFD
            jsr   CLOSE_FD

            lda   #<PATH_EDFILE6
            ldx   #>PATH_EDFILE6
            jsr   OPEN_BY_PATH
            sta   S6BRFD
            lda   S6BRFD
            sta   RFD
            lda   #<R_STAGE6B
            sta   RBUFPTR
            lda   #>R_STAGE6B
            sta   RBUFPTR+1
            lda   #32
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN6B
            lda   S6BRFD
            jsr   CLOSE_FD

* ---- Session 6b: `ed /mnt/MAUX/EDNOSUCH6` -- launch-load of a
* path that does NOT exist: `?`, no crash, filename not
* remembered ----
            lda   #19
            sta   R_STEP
* ---- EDSCR6N staged by build_ed_image.py (see session 1). ----

            lda   #<PATH_EDCAP6N
            ldx   #>PATH_EDCAP6N
            jsr   CRT_BY_PATH
            lda   #<PATH_EDCAP6N
            ldx   #>PATH_EDCAP6N
            jsr   OPEN_BY_PATH
            sta   S6NOUTFD

            lda   #<PATH_EDSCR6N
            ldx   #>PATH_EDSCR6N
            jsr   OPEN_BY_PATH
            sta   S6NINFD

            lda   #20
            sta   R_STEP
            lda   #FDACT_DUP
            sta   FDA6N
            lda   #FD_STDIN
            sta   FDA6N+1
            lda   S6NINFD
            sta   FDA6N+2
            lda   #FDACT_DUP
            sta   FDA6N+3
            lda   #FD_STDOUT
            sta   FDA6N+4
            lda   S6NOUTFD
            sta   FDA6N+5
            stz   FDA6N+6

            lda   #<FDA6N
            sta   SFDAPTR
            lda   #>FDA6N
            sta   SFDAPTR+1

            lda   #<AV_ED0
            sta   ARGV_ARR6N
            lda   #>AV_ED0
            sta   ARGV_ARR6N+1
            lda   #<AV_EDNOSUCH
            sta   ARGV_ARR6N+2
            lda   #>AV_EDNOSUCH
            sta   ARGV_ARR6N+3
            stz   ARGV_ARR6N+4
            stz   ARGV_ARR6N+5
            lda   #<ARGV_ARR6N
            sta   AVPTR
            lda   #>ARGV_ARR6N
            sta   AVPTR+1

            jsr   SPAWN_ED_A
            sta   R_SPAWN6N_PID

            lda   #<R_SPWN6N_STAT
            sta   WSTATUSPTR
            lda   #>R_SPWN6N_STAT
            sta   WSTATUSPTR+1
            jsr   WAIT_ONE
            sta   R_WAIT6N_PID

            lda   #21
            sta   R_STEP
            lda   S6NINFD
            jsr   CLOSE_FD
            lda   S6NOUTFD
            jsr   CLOSE_FD

            lda   #<PATH_EDCAP6N
            ldx   #>PATH_EDCAP6N
            jsr   OPEN_BY_PATH
            sta   S6NCAPFD
            lda   S6NCAPFD
            sta   RFD
            lda   #<R_STAGE6N
            sta   RBUFPTR
            lda   #>R_STAGE6N
            sta   RBUFPTR+1
            lda   #16
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN6N
            lda   S6NCAPFD
            jsr   CLOSE_FD

*-- PARENT_PROC's own epilogue (:donepark/PFAIL/:pfailpark) now
*-- lives at the tail of edtestb2.s (Session 7, "last regular
*-- expression" task, 2026-09-02) -- this file's own tail falls
*-- straight through into it, same split precedent as extest.s's
*-- extestb2.s->extestb4.s (one continuous PARENT_PROC assembly
*-- stream; forced by check-dialect's real-Merlin 41215-byte
*-- source-buffer budget, which edtestb.s alone cleared once
*-- Session 7 landed here).


*-- Everything past this point (small call helpers, all
*-- call-site scratch, every PATH_*/PAR_PROC_LEN) moved to
*-- edtestb2.s's own tail (2026-09-02, "last regular
*-- expression" task): they are reached only via jsr/lda
*-- #<label, never by fallthrough, so they must sit AFTER
*-- edtestb2.s's own Session 7 driver + epilogue in the
*-- assembled byte stream, not between Session 6b's code and
*-- it -- an earlier draft left them here, and PARENT_PROC's
*-- fallthrough ran straight into OPEN_BY_PATH's own bytes as
*-- if they were more instructions. See edtestb2.s's header.
*-- (Every EDSCR*/EDFILE6/EDFIX1 script/fixture's own bytes are
*-- build_ed_image.py's FIXTURES as of 2026-09-12 -- see session
*-- 1's own note above PARENT_PROC.)
