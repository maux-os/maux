*---------------------------------------------------------------
* exprtestb.s -- image body for exprtest.s (`make check-expr`).
* Same boot shape as testevtestb.s (single process synthesized
* into bank 1, real syscalls live). PARENT_PROC runs a 37-row
* case table calling EXPR_EVAL/EXPR_EXITCD DIRECTLY -- same
* shape as check-testev's own gate against TEST_EVAL.
*
* A real-binary "direct spawn" phase 2 (spawning EXPR itself,
* stdout captured, proving argv/print/exit end to end and that a
* literal `*` survives without `sh`) was first attempted and
* dropped: it hit a file-syscall ERR_INVAL ($E1) whose root
* cause was not pinned down in the time available. That gap has
* since been closed -- see below -- and phase 2 is now live.
* Phase 1 alone already exercises every operator, both
* outcomes per comparison, precedence both directions, overflow,
* and division/modulo by zero on real 6502.
*---------------------------------------------------------------

*-- Hoisted above first use (S9 EQU burn-down 2026-08-29).
NCASE       equ   37

R_RESULTS   equ   $1400      ;NCASE bytes, one per case
R_NCASES    equ   $1440
R_DONE      equ   $1441
R_ERR       equ   $1442
R_STEP      equ   $1443

*---------------------------------------------------------------
* Phase-2 (investigation rebuild, task: root-cause the dropped
* direct-spawn phase) -- same technique lstestb.s/ldtestb.s
* already prove works: CREATE+OPEN a capture file, DUP it onto
* the child's stdout, SPAWN EXPR directly (no sh) with argv
* 2,*,3 (the literal `*` sh could not pass), WAIT, then reopen
* the capture file for read and copy its bytes back.
*
* R2_*/CUR_FD2/IO_BUF2 stay FIXED low scratch, filled by RUNTIME
* code, same reason lstestb.s's own header gives (PARENT_PROC's
* bank-copied span starts well north of here) -- R2_* are also
* the addresses scripts/check_expr.py peeks. But EXPR_PATH2 ..
* READ_PARM2 below are 2026-09-12: real PARENT_PROC-body labels
* now, not fixed scratch -- every one of them is a COMPILE-TIME
* constant (the spawn path, argv strings, and every syscall
* parameter block field except the two fds SPAWN/OPEN hand back
* at runtime), so SETUP_PATH2's old runtime fill (223B: six
* copy loops/stores plus three whole parameter blocks built
* field-by-field) bought nothing a `dfb`/`da`/`asc` declaration,
* copied into bank 1 for free by BOOT_CPY_PAR, didn't already
* do cheaper. Only the fields that really are dynamic (the fd
* OPEN_FILE2 hands back, patched into FDA_EXPR2/READ_PARM2) are
* still set by code, right where each is produced. See
* extestb3.s's own ARGV_ARR5/ARGV_ARR5N note (same insight,
* same day, the `ex` harness's own copy of this fat).
*---------------------------------------------------------------
R2_STEP       equ $1500
R2_ERR        equ $1501
R2_DONE       equ $1502
R2_SPAWN_PID  equ $1503
R2_WAIT_STAT  equ $1504
R2_TRANS      equ $1505    ;2 bytes
R2_DATA       equ $1507    ;32 bytes -- ends $1527

CUR_FD2       equ $1690    ;fd just opened

IOREQLEN2     equ 64
IO_BUF2       equ $1700    ;64B -- ends $1740

*---------------------------------------------------------------
* Phase-1 case scratch (parent's own working cells).
*---------------------------------------------------------------
CASEI       ds    1
CARGC       ds    1
CEXPSTAT    ds    1
CEXPISNM    ds    1
CEXPNUM     ds    2
CEXPEXIT    ds    1
CGOTSTAT    ds    1

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

BANNER      asc   "MAUX EXPR"
BANNER_END

*---------------------------------------------------------------
* PARENT_PROC -- copied verbatim to bank 1 (BOOT_CPY_PAR above),
* same reason fleettestb.s's own PARENT_PROC is.
*---------------------------------------------------------------
PARENT_PROC
            ldx   #0
:fill       lda   #$EE
            sta   R_RESULTS,x
            inx
            cpx   #NCASE
            bne   :fill
            stz   R_ERR
            stz   R_STEP
*-- LOAD_CASES: the case table lives in /mnt/MAUX/EXPRCASES
*-- (src/test/exprcases.s, assembled at $1800), not in this
*-- image -- OPEN, READ it into $1800 of this bank, CLOSE. A
*-- failed open/read/short file parks R_ERR ($C1/$C2/$C3) and
*-- skips Phase 1: every result stays $EE and check_expr.py
*-- reports it.
            lda   #<OPEN_PARMC
            ldx   #>OPEN_PARMC
            ldy   #SYS_OPEN
            jsr   $FF00
            bcc   :lopen
            lda   #$C1
            bra   :lderr
:lopen      lda   OPEN_PARMC+5
            sta   CUR_FD2
            sta   READ_PARMC+1
            lda   #<READ_PARMC
            ldx   #>READ_PARMC
            ldy   #SYS_READ
            jsr   $FF00
            bcc   :lread
            lda   #$C2
            bra   :lderr
:lread      lda   CUR_FD2
            jsr   CLOSE_FD2
            lda   READ_PARMC+7             ;transferred >= the
            bne   :lok                     ;table's NCASE*4?
            lda   READ_PARMC+6
            cmp   #NCASE*4
            bcs   :lok
            lda   #$C3
:lderr      sta   R_ERR
            jmp   :p1done
:lok

*-- Phase 1: EXPR_EVAL/EXPR_EXITCD called DIRECTLY, case table.
*-- 4 bytes/row (packed 2026-09-12 -- see the table's header):
*-- NCASE=37 rows end at offset 148, so the row offset FITS an
*-- 8-bit index and CASES,y addresses it directly. (The 8-byte
*-- rows this replaced reached 288 and needed a 16-bit pointer
*-- walk; the `asl` x3 overflow past case 31 that preceded THAT
*-- is why NCASE*4 must stay under 256 -- an `err` pins it.)
            err   NCASE*4/256
            stz   CASEI
:caselp     lda   CASEI
            cmp   #NCASE
            bcc   :haverow
            jmp   :p1done
:haverow    lda   CASEI
            asl
            asl
            tay                     ;Y = CASEI*4
            lda   CASES,y
            sta   PTR0
            lda   CASES+1,y
            sta   PTR0+1
            lda   CASES+3,y
            sta   CEXPNUM           ;low byte; high always 0
            stz   CEXPNUM+1
            lda   CASES+2,y         ;flags: argc<<4 | exit<<3 |
            sta   CEXPSTAT          ;isnum<<2 | status (unpacked
            lsr                     ;below; CEXPSTAT is the
            lsr                     ;scratch until its own and)
            lsr
            lsr
            sta   CARGC
            lda   CEXPSTAT
            lsr
            lsr
            pha
            and   #1
            sta   CEXPISNM
            pla
            lsr
            and   #1
            sta   CEXPEXIT
            lda   CEXPSTAT
            and   #3
            sta   CEXPSTAT
            ldx   CARGC
            jsr   EXPR_EVAL
            sta   CGOTSTAT
            cmp   CEXPSTAT
            bne   :cfail
            lda   CEXPSTAT
            bne   :cpass           ;nonzero expected status --
                                   ;the status match IS the test
            lda   CEXPISNM
            beq   :ckexit
            lda   EX_RV_ISNM
            cmp   #1
            bne   :cfail
            lda   EX_RV_NUM
            cmp   CEXPNUM
            bne   :cfail
            lda   EX_RV_NUM+1
            cmp   CEXPNUM+1
            bne   :cfail
:ckexit     jsr   EXPR_EXITCD
            cmp   CEXPEXIT
            bne   :cfail
:cpass      lda   #1
            bra   :cstore
:cfail      lda   #0
:cstore     ldy   CASEI
            sta   R_RESULTS,y
            inc   CASEI
            jmp   :caselp

:p1done     lda   #NCASE
            sta   R_NCASES
            lda   #$AA
            sta   R_DONE

*-- Phase 2: real EXPR binary spawned DIRECTLY (no sh), stdout
*-- redirected to a capture file, argv "2","*","3" -- the
*-- investigation rebuild of the dropped phase. Every path/argv/
*-- parameter-block byte SETUP_PATH2 used to build at runtime is
*-- now static data (this file's own Phase-2 header) -- no setup
*-- call needed any more.
            stz   R2_ERR
            lda   #2
            sta   R2_STEP
            jsr   RUN_EXPR_SPW
            bcc   :p2ok
            jmp   P2_ERR
:p2ok       lda   #3
            sta   R2_STEP
            jsr   READBACK2
            bcc   :p2rbok
            jmp   P2_ERR
:p2rbok     lda   #$AA
            sta   R2_DONE
:done       bra   :done

P2_ERR      sta   R2_ERR
            lda   #$EE
            sta   R2_DONE
:p2park     bra   :p2park

*---------------------------------------------------------------
* Phase-2 helpers -- CRT_FILE2/OPEN_FILE2 (no args -- both act
* on the ONE static EXPROUT_PATH this file ever names)/CLOSE_FD2
* (still generic, fd in A -- a real "which fd" argument every
* call). RUN_EXPR_SPW does CREATE+OPEN+SPAWN+WAIT+CLOSE,
* READBACK2 reopens the capture file and copies its bytes to
* R2_DATA. Same shape as lstestb.s's own CRT_FILE/OPEN_FILE/
* CLOSE_FD/RUN1/RD_INTO_IOBUF -- that gate's technique is
* already proven working; this rebuild follows it exactly
* rather than reinventing it, so any divergence in behaviour
* points at something EXPR-specific, not the harness shape
* itself. 2026-09-12: SETUP_PATH2 (which used to fill
* CREATE_PARM2/OPEN_PARM2/EXPR_PATH2/ARGV_EXPR2/SPAWN_PARM2/
* FDA_EXPR2 at runtime, six copy loops and three parameter
* blocks) is GONE -- every byte it built was compile-time-
* constant, so it is all static data below instead (this
* file's own Phase-2 header has the why).
*---------------------------------------------------------------
CRT_FILE2   lda   #<CREATE_PARM2
            ldx   #>CREATE_PARM2
            ldy   #SYS_CREAT
            jsr   $FF00
            rts

OPEN_FILE2  lda   #<OPEN_PARM2
            ldx   #>OPEN_PARM2
            ldy   #SYS_OPEN
            jsr   $FF00
            bcs   :err
            lda   OPEN_PARM2+5
            clc
            rts
:err        sec
            rts

CLOSE_FD2   sta   CLOSE_PARM2+1
            lda   #<CLOSE_PARM2
            ldx   #>CLOSE_PARM2
            ldy   #SYS_CLOSE
            jsr   $FF00
            rts

*---------------------------------------------------------------
* RUN_EXPR_SPW -- CREATE+OPEN EXPROUT, patch the dynamic fd into
* FDA_EXPR2, SPAWN EXPR directly with argv "2","*","3", WAIT,
* CLOSE the parent's own fd (the child holds its dup already --
* same comment ldtestb.s's own SPAWN_LD path carries). Carry
* clear on success.
*---------------------------------------------------------------
RUN_EXPR_SPW
            lda   #20
            sta   R2_STEP
            jsr   CRT_FILE2
            bcs   :fail
            lda   #21
            sta   R2_STEP
            jsr   OPEN_FILE2
            bcs   :fail
            sta   CUR_FD2
            sta   FDA_EXPR2+2
            sta   FDA_EXPR2+4
            lda   #22
            sta   R2_STEP
            lda   #<SPAWN_PARM2
            ldx   #>SPAWN_PARM2
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :fail
            sta   R2_SPAWN_PID
            lda   #23
            sta   R2_STEP
            lda   #<WAIT_PARM2
            ldx   #>WAIT_PARM2
            ldy   #SYS_WAIT
            jsr   $FF00
            bcs   :fail
            lda   CUR_FD2
            jsr   CLOSE_FD2
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* READBACK2 -- reopen EXPROUT for read, copy up to 32 bytes into
* R2_DATA, record the transfer count at R2_TRANS. Same shape as
* lstestb.s's RD_INTO_IOBUF+READBACK_ALL, collapsed to one file.
*---------------------------------------------------------------
READBACK2   jsr   OPEN_FILE2
            bcs   :err
            sta   CUR_FD2
            sta   READ_PARM2+1
            lda   #<READ_PARM2
            ldx   #>READ_PARM2
            ldy   #SYS_READ
            jsr   $FF00
            bcs   :err2
            lda   READ_PARM2+6
            sta   R2_TRANS
            lda   READ_PARM2+7
            sta   R2_TRANS+1
            ldy   #0
:cp         cpy   READ_PARM2+6
            beq   :cpdone
            cpy   #32
            beq   :cpdone
            lda   IO_BUF2,y
            sta   R2_DATA,y
            iny
            bra   :cp
:cpdone     lda   CUR_FD2
            jsr   CLOSE_FD2
            clc
            rts
:err2       lda   CUR_FD2
            jsr   CLOSE_FD2
:err        sec
            rts

*---------------------------------------------------------------
* Phase-2 static structures -- every field below is a compile-
* time constant except FDA_EXPR2+2/+4 (patched by RUN_EXPR_SPW
* with the real fd once CRT+OPEN return it) and READ_PARM2+1
* (patched by READBACK2 the same way). Placeholder 0s mark
* those two fields; everything else is the value SETUP_PATH2
* used to compute at runtime, written once here instead.
*---------------------------------------------------------------
EXPROUT_PATH dfb   17
             asc   "/mnt/MAUX/EXPROUT"
EXPR_PATH2  asc   "/bin/EXPR"
            dfb   0
ARG0_EXPR2  asc   "EXPR"
            dfb   0
ARG_TWO     asc   "2"
            dfb   0
ARG_STAR    asc   "*"
            dfb   0
ARG_THREE   asc   "3"
            dfb   0

*-- ARGV pointer array (Unix argv[argc]==NULL term). --
ARGV_EXPR2  da    ARG0_EXPR2,ARG_TWO,ARG_STAR,ARG_THREE,0

*-- SPAWN_PARM2 triple (path/argv/fda ptr), NULL envp. --
SPAWN_PARM2 da    EXPR_PATH2,ARGV_EXPR2,FDA_EXPR2,0

*-- FDA_EXPR2 -- DUP(stdout,fd) CLOSE(fd) END; +2/+4 (the fd)
*-- are placeholders, patched by RUN_EXPR_SPW.
FDA_EXPR2   dfb   FDACT_DUP,FD_STDOUT,0,FDACT_CLOSE,0,0,0

*-- CREATE_PARM2 -- PCOUNT_CREATE shape, path baked in. --
CREATE_PARM2 dfb  7
             da   EXPROUT_PATH
             dfb  $C3,$06,0,0,1
             dfb  0,0,0,0

*-- OPEN_PARM2 -- PCOUNT_OPEN shape, path baked in. --
OPEN_PARM2  dfb   3
            da    EXPROUT_PATH
            dfb   0,0,0

*-- WAIT_PARM2 -- the ONE field a WAIT parm block has: the
*-- status-dest pointer, always R2_WAIT_STAT here.
WAIT_PARM2  da    R2_WAIT_STAT

*-- CLOSE_PARM2 -- PCOUNT_CLOSE shape; the count is always 1,
*-- +1 (fd) is a placeholder, patched by CLOSE_FD2 every call
*-- (fd genuinely varies -- CLOSE_FD2 stays a generic helper).
CLOSE_PARM2 dfb   1,0

*-- READ_PARM2 -- PCOUNT_READ shape; +1 (fd) is a placeholder,
*-- patched by READBACK2. +6/+7 (transferred count) start 0 and
*-- are overwritten by the syscall itself on success.
READ_PARM2  dfb   4,0
            da    IO_BUF2
            dfb   IOREQLEN2,0
            dfb   0,0

*-- LOAD_CASES's blocks: the staged case-table file, read whole
*-- (512 B requested, ~430 B long) into CASES ($1800).
CASES_PATH  dfb   19
            asc   "/mnt/MAUX/EXPRCASES"
OPEN_PARMC  dfb   3
            da    CASES_PATH
            dfb   0,0,0
READ_PARMC  dfb   4,0
            da    CASES
            dfb   0,2
            dfb   0,0

*---------------------------------------------------------------
* Case table, argv arrays and token strings: src/test/
* exprcases.s, assembled ALONE at $1800 and staged on the image
* as /mnt/MAUX/EXPRCASES; LOAD_CASES (PARENT_PROC, above) READs
* it
* into $1800 of this bank before Phase 1. Moved out 2026-09-12:
* ~430 B of constant data the SYSTEM image carried to within
* 31 B of PMLI_IBF_BASE, so every kernel byte tripped
* check-kernel-images (same retirement build_ed_image.py's
* FIXTURES did for edtest).
*---------------------------------------------------------------
CASES       equ   $1800

* PAR_PROC_LEN (exprtest.s) closes over EXPR_EVAL and its liba
* dependencies too -- see that file, which `put`s them right
* after this file for exactly that reason.
