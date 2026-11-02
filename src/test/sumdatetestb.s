*---------------------------------------------------------------
* sumdatetestb.s -- image body for sumdatetest.s (`make check-
* sumdate`). Two phases, one PARENT_PROC, same shape as
* fleettestb.s's own.
*
*  Phase 1 (`sum`) -- spawned DIRECTLY (no `sh`) with argv =
*  SUM, /mnt/MAUX/EMPTY, /mnt/MAUX/ONE, /mnt/MAUX/BIG -- an
*  empty file, a
*  one-byte file and a file crossing a 512-byte block boundary,
*  all in ONE invocation (the task brief's "multiple files"
*  case too). fd 1 dup'd to a harness-opened /mnt/MAUX/SUMOUT.
*  scripts/check_sumdate.py reads SUMOUT back off the built
*  image and compares it byte-exact against hand-computed
*  (Python, independent of the 6502 rotate) expectations.
*
*  Phase 2 (`date`) -- spawned directly, fd 1 dup'd to
*  /mnt/MAUX/
*  DATEOUT and fd 2 dup'd to /mnt/MAUX/DATEERR. Immediately
*  after
*  WAIT returns (no file op in between -- see the comment at
*  DO_CLOCK below), the PARENT calls SYS_CLOCK itself, raw, and
*  stashes the 4 bytes at R_CLOCK_RAW: since our own syscall
*  never refreshes the ProDOS global page (only CREATE/DESTROY/
*  RENAME/SET_FILE_INFO/CLOSE/FLUSH do, per procfile.s's
*  PRC_CLOCK header), and nothing between `date`'s own internal
*  read and this one touches the filesystem, this is EXACTLY
*  the same 4 bytes `date` itself read -- ground truth with no
*  timing race against whatever the checker's own separate
*  `peek` sees later. The checker decodes it in Python (the same
*  legacy/Extended rule PRODOS-VERSION.md gives) and compares
*  against DATEOUT/DATEERR's actual bytes, run once per emulator
*  `clock` setting (docs/FLEET.md's own -- true and false).
*---------------------------------------------------------------

* Result addresses in the parent process bank (page $13).
R_SUM_FD      equ $1300
R_SUM_PID     equ $1301
R_SUM_WAIT    equ $1302
R_SUM_STATUS  equ $1303
R_DATE_OUTFD  equ $1304
R_DATE_ERRFD  equ $1305
R_DATE_PID    equ $1306
R_DATE_WAIT   equ $1307
R_DATE_STATUS equ $1308
R_CLOCK_RAW   equ $1309   ;4 bytes -- ground truth
R_DONE        equ $1390
R_ERR         equ $1391
R_STEP        equ $1392

* Parent process scratch (pages $10-$12).
SUMOUT_PATH   equ $1200   ;MLI pathname
DATEOUT_PATH  equ $1220   ;MLI pathname
DATEERR_PATH  equ $1240   ;MLI pathname
SUM_PATH      equ $1030   ;liba C-string, spawn path
SUM_ARG0      equ $1040   ;liba C-string, argv[0]
EMPTY_ARG     equ $1050   ;liba C-string, argv
ONE_ARG       equ $1060   ;liba C-string, argv
BIG_ARG       equ $1070   ;liba C-string, argv
DATE_PATH     equ $1080   ;liba C-string, spawn path
DATE_ARG0     equ $1090   ;liba C-string, argv[0]

OPEN_PARM   equ $10A0
CLOSE_PARM  equ $10B0
WAIT_PARM   equ $10C0
SPAWN_PARM  equ $10D0
CREAT_PARM  equ $10E0
CLOCK_PARM  equ $10F0

SUM_ARGV    equ $1100     ;5 entries: SUM,EMPTY,ONE,BIG,NULL
                          ;(10 bytes)
DATE_ARGV   equ $1110     ;2 entries: DATE,NULL (4 bytes)
FDA_BUF     equ $1120     ;fdactions -- up to 4 actions + END

*---------------------------------------------------------------
* Boot helpers -- identical shape to fleettestb.s's own.
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

BANNER      asc   "MAUX SUMDATE"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 (absolute JSR/JMP operands need it there).
*---------------------------------------------------------------
PARENT_PROC bra   SDB_EQHOP
*-- The pathname/label data lives INSIDE the staged parent
*-- span, right behind the entry hop: pid 1 executes a COPY
*-- of [PARENT_PROC..+PAR_PROC_LEN] in its own bank, so data
*-- outside the span reads as never-copied garbage there --
*-- found the hard way on this very edit. The hop keeps the
*-- entry at PARENT_PROC; the placement keeps every *_LEN
*-- equ defined before its immediate use (S9 EQU burn-down
*-- 2026-08-29).
SUMBIN_TXT
                ;/bin/SUM
                dfb $AF,$E2,$E9,$EE,$AF,$D3,$D5,$CD
SUMBIN_LEN equ  *-SUMBIN_TXT
SUMARG0_TXT
                ;SUM
                dfb  $D3,$D5,$CD
SUMARG0_LEN equ  *-SUMARG0_TXT
EMPTYA_TXT
                ;/mnt/MAUX/EMPTY
                dfb $AF,$ED,$EE,$F4,$AF,$CD,$C1,$D5,$D8
                dfb $AF,$C5,$CD,$D0,$D4,$D9
EMPTYA_LEN equ  *-EMPTYA_TXT
ONEA_TXT
                ;/mnt/MAUX/ONE
                dfb $AF,$ED,$EE,$F4,$AF,$CD,$C1,$D5,$D8
                dfb $AF,$CF,$CE,$C5
ONEA_LEN equ  *-ONEA_TXT
BIGA_TXT
                ;/mnt/MAUX/BIG
                dfb $AF,$ED,$EE,$F4,$AF,$CD,$C1,$D5,$D8
                dfb $AF,$C2,$C9,$C7
BIGA_LEN equ  *-BIGA_TXT
DATEBIN_TXT
                ;/bin/DATE
                dfb $AF,$E2,$E9,$EE,$AF,$C4,$C1,$D4,$C5
DATEBIN_LEN equ  *-DATEBIN_TXT
DATEARG0_TXT
                ;DATE
                dfb  $C4,$C1,$D4,$C5
DATEARG0_LEN equ  *-DATEARG0_TXT
SDB_EQHOP
            stz   R_ERR
            stz   R_STEP
            jsr   SETUP_PATHS

* -- Phase 1: `sum` on EMPTY+ONE+BIG in one invocation, fd 1
* -- dup'd to a fresh /mnt/MAUX/SUMOUT. Output checked
* host-side.
            lda   #1
            sta   R_STEP
            jsr   CREAT_SUMOUT
            bcc   :sumout_creat
            jmp   P_ERR
:sumout_creat
            jsr   OPN_SUMOUT
            bcc   :sumo_opened
            jmp   P_ERR
:sumo_opened
            sta   R_SUM_FD
            lda   #2
            sta   R_STEP
            jsr   SPAWN_SUM
            bcc   :sum_spawned
            jmp   P_ERR
:sum_spawned
            sta   R_SUM_PID
            lda   R_SUM_FD
            jsr   CLOSE_FD          ;parent's own copy -- the
                                    ;child holds its dup already
            jsr   WAIT_SUM
            bcc   :sum_waited
            jmp   P_ERR
:sum_waited sta   R_SUM_WAIT

* -- Phase 2: `date`, fd 1 -> /mnt/MAUX/DATEOUT, fd 2 ->
* /mnt/MAUX/
* -- DATEERR. Ground truth captured via the parent's OWN
* -- SYS_CLOCK call right after WAIT -- see the file header.
            lda   #3
            sta   R_STEP
            jsr   CREAT_DATEOUT
            bcc   :dout_creat
            jmp   P_ERR
:dout_creat jsr   OPN_DATEOUT
            bcc   :dout_opened
            jmp   P_ERR
:dout_opened
            sta   R_DATE_OUTFD
            lda   #4
            sta   R_STEP
            jsr   CREAT_DATEERR
            bcc   :derr_creat
            jmp   P_ERR
:derr_creat jsr   OPN_DATEERR
            bcc   :derr_opened
            jmp   P_ERR
:derr_opened
            sta   R_DATE_ERRFD
            lda   #5
            sta   R_STEP
            jsr   SPAWN_DATE
            bcc   :date_spawned
            jmp   P_ERR
:date_spawned
            sta   R_DATE_PID
            lda   R_DATE_OUTFD
            jsr   CLOSE_FD
            lda   R_DATE_ERRFD
            jsr   CLOSE_FD
            jsr   WAIT_DATE
            bcc   :date_waited
            jmp   P_ERR
:date_waited
            sta   R_DATE_WAIT
* -- ground truth: nothing above this point touches the
* -- filesystem again (the CLOSE_FDs already ran BEFORE the
* -- wait, so they can't race the WAIT/exit ordering either --
* -- `date`'s own process already exited by the time WAIT
* -- returns), so this SYS_CLOCK sees exactly what `date` saw.
            jsr   DO_CLOCK

            lda   #$AA
            sta   R_DONE
:done       bra   :done

P_ERR       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:park       bra   :park

SETUP_PATHS
            ; "/mnt/MAUX/SUMOUT" -- 13 chars, MLI pathname
            lda   #16
            sta   SUMOUT_PATH
            ldx   #0
:cp1        lda   SUMOUTP_TXT,x
            sta   SUMOUT_PATH+1,x
            inx
            cpx   #16
            bne   :cp1

            ; "/mnt/MAUX/DATEOUT" -- 14 chars, MLI pathname
            lda   #17
            sta   DATEOUT_PATH
            ldx   #0
:cp2        lda   DATEOUTP_TXT,x
            sta   DATEOUT_PATH+1,x
            inx
            cpx   #17
            bne   :cp2

            ; "/mnt/MAUX/DATEERR" -- 14 chars, MLI pathname
            lda   #17
            sta   DATEERR_PATH
            ldx   #0
:cp3        lda   DATEERRP_TXT,x
            sta   DATEERR_PATH+1,x
            inx
            cpx   #17
            bne   :cp3

            ;"/bin/SUM" -- liba C-string, spawn path
            ldx   #0
:cp4        lda   SUMBIN_TXT,x
            sta   SUM_PATH,x
            inx
            cpx   #SUMBIN_LEN
            bne   :cp4
            stz   SUM_PATH+SUMBIN_LEN

            ;"SUM" -- liba C-string, argv[0]
            ldx   #0
:cp5        lda   SUMARG0_TXT,x
            sta   SUM_ARG0,x
            inx
            cpx   #SUMARG0_LEN
            bne   :cp5
            stz   SUM_ARG0+SUMARG0_LEN

            ;"/mnt/MAUX/EMPTY" -- liba C-string, argv
            ldx   #0
:cp6        lda   EMPTYA_TXT,x
            sta   EMPTY_ARG,x
            inx
            cpx   #EMPTYA_LEN
            bne   :cp6
            stz   EMPTY_ARG+EMPTYA_LEN

            ;"/mnt/MAUX/ONE" -- liba C-string, argv
            ldx   #0
:cp7        lda   ONEA_TXT,x
            sta   ONE_ARG,x
            inx
            cpx   #ONEA_LEN
            bne   :cp7
            stz   ONE_ARG+ONEA_LEN

            ;"/mnt/MAUX/BIG" -- liba C-string, argv
            ldx   #0
:cp8        lda   BIGA_TXT,x
            sta   BIG_ARG,x
            inx
            cpx   #BIGA_LEN
            bne   :cp8
            stz   BIG_ARG+BIGA_LEN

            ;"/bin/DATE" -- liba C-string, spawn path
            ldx   #0
:cp9        lda   DATEBIN_TXT,x
            sta   DATE_PATH,x
            inx
            cpx   #DATEBIN_LEN
            bne   :cp9
            stz   DATE_PATH+DATEBIN_LEN

            ;"DATE" -- liba C-string, argv[0]
            ldx   #0
:cp10       lda   DATEARG0_TXT,x
            sta   DATE_ARG0,x
            inx
            cpx   #DATEARG0_LEN
            bne   :cp10
            stz   DATE_ARG0+DATEARG0_LEN
            rts

SUMOUTP_TXT   asc "/mnt/MAUX/SUMOUT"
DATEOUTP_TXT  asc "/mnt/MAUX/DATEOUT"
DATEERRP_TXT  asc "/mnt/MAUX/DATEERR"


CREAT_SUMOUT
            lda   #<SUMOUT_PATH
            sta   CREAT_PARM+1
            lda   #>SUMOUT_PATH
            sta   CREAT_PARM+2
            bra   CREAT_COMMON

CREAT_DATEOUT
            lda   #<DATEOUT_PATH
            sta   CREAT_PARM+1
            lda   #>DATEOUT_PATH
            sta   CREAT_PARM+2
            bra   CREAT_COMMON

CREAT_DATEERR
            lda   #<DATEERR_PATH
            sta   CREAT_PARM+1
            lda   #>DATEERR_PATH
            sta   CREAT_PARM+2
CREAT_COMMON
            lda   #7          ;PCOUNT_CREATE field COUNT
            sta   CREAT_PARM
            lda   #$C3              ;ACCESS_UNLKD
            sta   CREAT_PARM+3
            lda   #$06              ;FTYPE_BIN
            sta   CREAT_PARM+4
            stz   CREAT_PARM+5
            stz   CREAT_PARM+6
            lda   #$01              ;STYP_SEEDLING
            sta   CREAT_PARM+7
            stz   CREAT_PARM+8
            stz   CREAT_PARM+9
            stz   CREAT_PARM+10
            stz   CREAT_PARM+11
            lda   #<CREAT_PARM
            ldx   #>CREAT_PARM
            ldy   #SYS_CREAT
            jsr   $FF00
            bcs   :err
            clc
            rts
:err        sec
            rts

OPN_SUMOUT
            lda   #<SUMOUT_PATH
            sta   OPEN_PARM+1
            lda   #>SUMOUT_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPN_DATEOUT
            lda   #<DATEOUT_PATH
            sta   OPEN_PARM+1
            lda   #>DATEOUT_PATH
            sta   OPEN_PARM+2
            bra   OPEN_COMMON

OPN_DATEERR
            lda   #<DATEERR_PATH
            sta   OPEN_PARM+1
            lda   #>DATEERR_PATH
            sta   OPEN_PARM+2
OPEN_COMMON lda   #3
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

* -- DO_CLOCK -- raw SYS_CLOCK call, stashing the 4 result bytes
* -- at R_CLOCK_RAW. Process calls carry no param_count byte
* -- (syscalls.s's own SC_PSTAT/SC_CLOCK comment) -- the
* -- parmlist is just the 2-byte buffer pointer.
DO_CLOCK    lda   #<R_CLOCK_RAW
            sta   CLOCK_PARM
            lda   #>R_CLOCK_RAW
            sta   CLOCK_PARM+1
            lda   #<CLOCK_PARM
            ldx   #>CLOCK_PARM
            ldy   #SYS_CLOCK
            jsr   $FF00
            rts

SPAWN_SUM   lda   #<SUM_ARG0
            sta   SUM_ARGV
            lda   #>SUM_ARG0
            sta   SUM_ARGV+1
            lda   #<EMPTY_ARG
            sta   SUM_ARGV+2
            lda   #>EMPTY_ARG
            sta   SUM_ARGV+3
            lda   #<ONE_ARG
            sta   SUM_ARGV+4
            lda   #>ONE_ARG
            sta   SUM_ARGV+5
            lda   #<BIG_ARG
            sta   SUM_ARGV+6
            lda   #>BIG_ARG
            sta   SUM_ARGV+7
            stz   SUM_ARGV+8
            stz   SUM_ARGV+9

            lda   #FDACT_DUP
            sta   FDA_BUF+0
            lda   #FD_STDOUT
            sta   FDA_BUF+1
            lda   R_SUM_FD
            sta   FDA_BUF+2
            lda   #FDACT_CLOSE
            sta   FDA_BUF+3
            lda   R_SUM_FD
            sta   FDA_BUF+4
            stz   FDA_BUF+5
            stz   FDA_BUF+6            ;FDACT_END

            lda   #<SUM_PATH
            sta   SPAWN_PARM
            lda   #>SUM_PATH
            sta   SPAWN_PARM+1
            lda   #<SUM_ARGV
            sta   SPAWN_PARM+2
            lda   #>SUM_ARGV
            sta   SPAWN_PARM+3
            lda   #<FDA_BUF
            sta   SPAWN_PARM+4
            lda   #>FDA_BUF
            sta   SPAWN_PARM+5
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            rts

WAIT_SUM    lda   #<R_SUM_STATUS
            sta   WAIT_PARM
            lda   #>R_SUM_STATUS
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

SPAWN_DATE  lda   #<DATE_ARG0
            sta   DATE_ARGV
            lda   #>DATE_ARG0
            sta   DATE_ARGV+1
            stz   DATE_ARGV+2
            stz   DATE_ARGV+3

            lda   #FDACT_DUP
            sta   FDA_BUF+0
            lda   #FD_STDOUT
            sta   FDA_BUF+1
            lda   R_DATE_OUTFD
            sta   FDA_BUF+2
            lda   #FDACT_DUP
            sta   FDA_BUF+3
            lda   #FD_STDERR
            sta   FDA_BUF+4
            lda   R_DATE_ERRFD
            sta   FDA_BUF+5
            lda   #FDACT_CLOSE
            sta   FDA_BUF+6
            lda   R_DATE_OUTFD
            sta   FDA_BUF+7
            stz   FDA_BUF+8            ;CLOSE's reserved byte
            lda   #FDACT_CLOSE
            sta   FDA_BUF+9
            lda   R_DATE_ERRFD
            sta   FDA_BUF+10
            stz   FDA_BUF+11           ;reserved
            stz   FDA_BUF+12           ;FDACT_END

            lda   #<DATE_PATH
            sta   SPAWN_PARM
            lda   #>DATE_PATH
            sta   SPAWN_PARM+1
            lda   #<DATE_ARGV
            sta   SPAWN_PARM+2
            lda   #>DATE_ARGV
            sta   SPAWN_PARM+3
            lda   #<FDA_BUF
            sta   SPAWN_PARM+4
            lda   #>FDA_BUF
            sta   SPAWN_PARM+5
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            rts

WAIT_DATE   lda   #<R_DATE_STATUS
            sta   WAIT_PARM
            lda   #>R_DATE_STATUS
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

PAR_PROC_LEN equ *-PARENT_PROC
