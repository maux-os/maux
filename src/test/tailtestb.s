*---------------------------------------------------------------
* tailtestb.s -- image body for tailtest.s. Split out so the
* top-level stays a thin MANIFEST -- see catreadtestb.s's own
* header for why (real Merlin holds the resident top-level AND
* the PUT file in the same buffer).
*
* Six runs of a real spawned TAIL, each with fd 1 (and, for run
* 6, fd 0 too) redirected to real ProDOS files:
*   RUN1  tail /mnt/MAUX/TAILSRC          (default N=10)
*   RUN2  tail -3 /mnt/MAUX/TAILSRC
*   RUN3  tail -20 /mnt/MAUX/TAILSRC      (N > lines in file)
*   RUN4  tail /mnt/MAUX/TAILMT           (empty file)
*   RUN5  tail -2 /mnt/MAUX/TAILNOCR      (last line, no CR)
*   RUN6  tail                          (no operand -- fd 0,
*                                        dup'd from TAILSRC)
* Every result (spawn pid, wait pid, exit status, trans_count,
* up to 64 bytes of output) lands at R_RUN1..R_RUN6 (aux bank 1,
* $1200/$1300/.../$1700) for scripts/check_tail.py to read back
* and compare against scripts/build_tail_image.py's hand-derived
* expectations.
*---------------------------------------------------------------

* -- Runtime scratch (bare addresses, never pre-populated --
* -- PARENT_PROC's own copied code fills every field via
* -- immediate stores before each syscall, same posture as
* -- catreadtestb.s's OPEN_PARM/CREATE_PARM/etc).
CREATE_PARM equ $1000        ;12 bytes
OPEN_PARM   equ $1010        ;6 bytes
CLOSE_PARM  equ $1020        ;2 bytes
READ_PARM   equ $1030        ;8 bytes
SPAWN_PARM  equ $1040        ;6 bytes
WAIT_PARM   equ $1050        ;2 bytes
WAIT_STATUS equ $1052        ;1 byte
ARGV_ARR    equ $1060        ;8 bytes (3 ptrs + NUL pair)
FDA_BUF     equ $1070        ;13 bytes (2 dup/close + END)
IO_BUF      equ $1090        ;READBUFLEN bytes
CUR_OUTFD   equ $1100
CUR_INFD    equ $1101
READBUFLEN  equ 64

* -- Per-run result block (aux bank 1 -- what
* -- scripts/check_tail.py peeks). +0 pid, +1 wait pid,
* -- +2 exit status, +3/+4 trans_count, +6.. up to
* -- READBUFLEN bytes of output.
R_RUN1      equ $1200
R_RUN2      equ $1300
R_RUN3      equ $1400
R_RUN4      equ $1500
R_RUN5      equ $1600
R_RUN6      equ $1700
R_DONE      equ $1900
R_ERR       equ $1901
R_STEP      equ $1902
* -- R_GO handshake (docs/STICKY.md sec 25/37, check_ls.py's own
* -- WAIT_GO protocol): published gap number / released gap
* -- number, so scripts/check_tail.py can re-poison the bank a
* -- finished run used strictly between its reap and the next
* -- spawn, never racing SYS_SPAWN.
R_GO_REQ    equ $1903
R_GO        equ $1904

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

BANNER      asc   "MAUX TAIL"
BANNER_END

*---------------------------------------------------------------
* Parent process image. Copied verbatim to the same address in
* bank 1 -- absolute JSR/JMP operands to the helper subroutines
* below need the SAME address post-copy (catreadtestb.s's own
* reasoning). Every static string this code reads (paths, argv
* text) is declared INSIDE this block, after PAR_TXT_START, so
* it travels with the copy -- a label outside this block would
* only exist in MAIN memory, unreadable once this code is
* running in bank 1.
*---------------------------------------------------------------
PARENT_PROC
            stz   R_ERR
            stz   R_STEP
            stz   R_GO
            stz   R_GO_REQ
            jsr   INIT_PARMS

            jsr   RUN1
            lda   #1
            jsr   WAIT_GO
            jsr   RUN2
            lda   #2
            jsr   WAIT_GO
            jsr   RUN3
            lda   #3
            jsr   WAIT_GO
            jsr   RUN4
            lda   #4
            jsr   WAIT_GO
            jsr   RUN5
            lda   #5
            jsr   WAIT_GO
            jsr   RUN6

            lda   #$AA
            sta   R_DONE
:done       bra   :done

P_ERR       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:park       bra   :park

*---------------------------------------------------------------
* WAIT_GO -- A = gap number (the run that just finished). Same
* four-line park as src/test/lstestb.s's own WAIT_GO: publish
* the gap in R_GO_REQ, spin until scripts/check_tail.py writes
* the same number to R_GO -- which it does only after poisoning
* the bank that run used (docs/STICKY.md sec 25/37's
* poison-between-runs gate). A step-and-poll driver instead
* would race the next SYS_SPAWN; parking here cannot.
*---------------------------------------------------------------
WAIT_GO     sta   R_GO_REQ
:spin       cmp   R_GO
            bne   :spin
            rts

*---------------------------------------------------------------
* INIT_PARMS -- build the two parmlists that never change across
* runs: SPAWN_PARM always targets AV_PATH_TAIL/ARGV_ARR/FDA_BUF
* (ARGV_ARR/FDA_BUF's CONTENTS get repoked per run, not their
* addresses); WAIT_PARM always targets WAIT_STATUS.
*---------------------------------------------------------------
INIT_PARMS  lda   #<AV_PATH_TAIL
            sta   SPAWN_PARM
            lda   #>AV_PATH_TAIL
            sta   SPAWN_PARM+1
            lda   #<ARGV_ARR
            sta   SPAWN_PARM+2
            lda   #>ARGV_ARR
            sta   SPAWN_PARM+3
            lda   #<FDA_BUF
            sta   SPAWN_PARM+4
            lda   #>FDA_BUF
            sta   SPAWN_PARM+5
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
            lda   #<WAIT_STATUS
            sta   WAIT_PARM
            lda   #>WAIT_STATUS
            sta   WAIT_PARM+1
            rts

*---------------------------------------------------------------
* CREATE_COMMON -- IN: A/X = lo/hi of an MLI pathname buffer.
* Builds CREATE_PARM fully (BIN, seedling, no dates -- these are
* scratch files, content is all that matters) and issues
* SYS_CREAT. Result IGNORED by every caller (fresh volume, but
* same "try OPEN regardless" posture as uniq.s's own CREATE).
*---------------------------------------------------------------
CREATE_COMMON
            sta   CREATE_PARM+1
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

*---------------------------------------------------------------
* OPEN_COMMON -- IN: A/X = lo/hi of an MLI pathname buffer.
* OUT: carry clear, A = fd; carry set = error.
*---------------------------------------------------------------
OPEN_COMMON sta   OPEN_PARM+1
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

*---------------------------------------------------------------
* CLOSE_A -- IN: A = fd.
*---------------------------------------------------------------
CLOSE_A     sta   CLOSE_PARM+1
            lda   #1
            sta   CLOSE_PARM
            lda   #<CLOSE_PARM
            ldx   #>CLOSE_PARM
            ldy   #SYS_CLOSE
            jsr   $FF00
            rts

*---------------------------------------------------------------
* READ_UPTO -- IN: A = fd. Reads up to READBUFLEN bytes into
* IO_BUF; trans_count lands at READ_PARM+6/+7. OUT: carry
* clear/set.
*---------------------------------------------------------------
READ_UPTO   sta   READ_PARM+1
            lda   #4
            sta   READ_PARM
            lda   #<IO_BUF
            sta   READ_PARM+2
            lda   #>IO_BUF
            sta   READ_PARM+3
            lda   #READBUFLEN
            sta   READ_PARM+4
            stz   READ_PARM+5
            stz   READ_PARM+6
            stz   READ_PARM+7
            lda   #<READ_PARM
            ldx   #>READ_PARM
            ldy   #SYS_READ
            jsr   $FF00
            bcs   :err
            clc
            rts
:err        sec
            rts

DO_SPAWN    lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            rts

DO_WAIT     lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

*---------------------------------------------------------------
* RUN1 -- tail /mnt/MAUX/TAILSRC (default N=10). Expect the last
* 10
* of TAILSRC's 15 lines.
*---------------------------------------------------------------
RUN1        lda   #1
            sta   R_STEP
            lda   #<PATH_OUT1
            ldx   #>PATH_OUT1
            jsr   CREATE_COMMON
            lda   #<PATH_OUT1
            ldx   #>PATH_OUT1
            jsr   OPEN_COMMON
            bcc   :opened
            jmp   P_ERR
:opened     sta   CUR_OUTFD

            lda   #<AV_TAIL0
            sta   ARGV_ARR
            lda   #>AV_TAIL0
            sta   ARGV_ARR+1
            lda   #<AV_SRC
            sta   ARGV_ARR+2
            lda   #>AV_SRC
            sta   ARGV_ARR+3
            stz   ARGV_ARR+4
            stz   ARGV_ARR+5
            jsr   FDA_OUT1

            lda   #2
            sta   R_STEP
            jsr   DO_SPAWN
            bcc   :spawned
            jmp   P_ERR
:spawned    sta   R_RUN1+0
            jsr   DO_WAIT
            bcc   :waited
            jmp   P_ERR
:waited     sta   R_RUN1+1
            lda   WAIT_STATUS
            sta   R_RUN1+2

            lda   #3
            sta   R_STEP
            lda   CUR_OUTFD
            jsr   CLOSE_A
            jsr   REREAD1
            rts

*---------------------------------------------------------------
* RUN2 -- tail -3 /mnt/MAUX/TAILSRC. Expect L13,L14,L15.
*---------------------------------------------------------------
RUN2        lda   #4
            sta   R_STEP
            lda   #<PATH_OUT2
            ldx   #>PATH_OUT2
            jsr   CREATE_COMMON
            lda   #<PATH_OUT2
            ldx   #>PATH_OUT2
            jsr   OPEN_COMMON
            bcc   :opened
            jmp   P_ERR
:opened     sta   CUR_OUTFD

            lda   #<AV_TAIL0
            sta   ARGV_ARR
            lda   #>AV_TAIL0
            sta   ARGV_ARR+1
            lda   #<AV_M3
            sta   ARGV_ARR+2
            lda   #>AV_M3
            sta   ARGV_ARR+3
            lda   #<AV_SRC
            sta   ARGV_ARR+4
            lda   #>AV_SRC
            sta   ARGV_ARR+5
            stz   ARGV_ARR+6
            stz   ARGV_ARR+7
            jsr   FDA_OUT2

            lda   #5
            sta   R_STEP
            jsr   DO_SPAWN
            bcc   :spawned
            jmp   P_ERR
:spawned    sta   R_RUN2+0
            jsr   DO_WAIT
            bcc   :waited
            jmp   P_ERR
:waited     sta   R_RUN2+1
            lda   WAIT_STATUS
            sta   R_RUN2+2

            lda   #6
            sta   R_STEP
            lda   CUR_OUTFD
            jsr   CLOSE_A
            jsr   REREAD2
            rts

*---------------------------------------------------------------
* RUN3 -- tail -20 /mnt/MAUX/TAILSRC (N > 15 lines). Expect all
* 15.
*---------------------------------------------------------------
RUN3        lda   #7
            sta   R_STEP
            lda   #<PATH_OUT3
            ldx   #>PATH_OUT3
            jsr   CREATE_COMMON
            lda   #<PATH_OUT3
            ldx   #>PATH_OUT3
            jsr   OPEN_COMMON
            bcc   :opened
            jmp   P_ERR
:opened     sta   CUR_OUTFD

            lda   #<AV_TAIL0
            sta   ARGV_ARR
            lda   #>AV_TAIL0
            sta   ARGV_ARR+1
            lda   #<AV_M20
            sta   ARGV_ARR+2
            lda   #>AV_M20
            sta   ARGV_ARR+3
            lda   #<AV_SRC
            sta   ARGV_ARR+4
            lda   #>AV_SRC
            sta   ARGV_ARR+5
            stz   ARGV_ARR+6
            stz   ARGV_ARR+7
            jsr   FDA_OUT3

            lda   #8
            sta   R_STEP
            jsr   DO_SPAWN
            bcc   :spawned
            jmp   P_ERR
:spawned    sta   R_RUN3+0
            jsr   DO_WAIT
            bcc   :waited
            jmp   P_ERR
:waited     sta   R_RUN3+1
            lda   WAIT_STATUS
            sta   R_RUN3+2

            lda   #9
            sta   R_STEP
            lda   CUR_OUTFD
            jsr   CLOSE_A
            jsr   REREAD3
            rts

*---------------------------------------------------------------
* RUN4 -- tail /mnt/MAUX/TAILMT (empty file, default N). Expect
* 0
* bytes.
*---------------------------------------------------------------
RUN4        lda   #10
            sta   R_STEP
            lda   #<PATH_OUT4
            ldx   #>PATH_OUT4
            jsr   CREATE_COMMON
            lda   #<PATH_OUT4
            ldx   #>PATH_OUT4
            jsr   OPEN_COMMON
            bcc   :opened
            jmp   P_ERR
:opened     sta   CUR_OUTFD

            lda   #<AV_TAIL0
            sta   ARGV_ARR
            lda   #>AV_TAIL0
            sta   ARGV_ARR+1
            lda   #<AV_MT
            sta   ARGV_ARR+2
            lda   #>AV_MT
            sta   ARGV_ARR+3
            stz   ARGV_ARR+4
            stz   ARGV_ARR+5
            jsr   FDA_OUT4

            lda   #11
            sta   R_STEP
            jsr   DO_SPAWN
            bcc   :spawned
            jmp   P_ERR
:spawned    sta   R_RUN4+0
            jsr   DO_WAIT
            bcc   :waited
            jmp   P_ERR
:waited     sta   R_RUN4+1
            lda   WAIT_STATUS
            sta   R_RUN4+2

            lda   #12
            sta   R_STEP
            lda   CUR_OUTFD
            jsr   CLOSE_A
            jsr   REREAD4
            rts

*---------------------------------------------------------------
* RUN5 -- tail -2 /mnt/MAUX/TAILNOCR (last line has no trailing
* CR). Expect "A4\rA5\r" -- output-policy normalization, see
* tail.s's own header.
*---------------------------------------------------------------
RUN5        lda   #13
            sta   R_STEP
            lda   #<PATH_OUT5
            ldx   #>PATH_OUT5
            jsr   CREATE_COMMON
            lda   #<PATH_OUT5
            ldx   #>PATH_OUT5
            jsr   OPEN_COMMON
            bcc   :opened
            jmp   P_ERR
:opened     sta   CUR_OUTFD

            lda   #<AV_TAIL0
            sta   ARGV_ARR
            lda   #>AV_TAIL0
            sta   ARGV_ARR+1
            lda   #<AV_M2
            sta   ARGV_ARR+2
            lda   #>AV_M2
            sta   ARGV_ARR+3
            lda   #<AV_NOCR
            sta   ARGV_ARR+4
            lda   #>AV_NOCR
            sta   ARGV_ARR+5
            stz   ARGV_ARR+6
            stz   ARGV_ARR+7
            jsr   FDA_OUT5

            lda   #14
            sta   R_STEP
            jsr   DO_SPAWN
            bcc   :spawned
            jmp   P_ERR
:spawned    sta   R_RUN5+0
            jsr   DO_WAIT
            bcc   :waited
            jmp   P_ERR
:waited     sta   R_RUN5+1
            lda   WAIT_STATUS
            sta   R_RUN5+2

            lda   #15
            sta   R_STEP
            lda   CUR_OUTFD
            jsr   CLOSE_A
            jsr   REREAD5
            rts

*---------------------------------------------------------------
* RUN6 -- tail (no operand -- reads fd 0, dup'd from TAILSRC).
* Expect the same last-10 lines as RUN1 -- proving the fd-0 path
* independently of the file-argument path.
*---------------------------------------------------------------
RUN6        lda   #16
            sta   R_STEP
            lda   #<PATH_SRC
            ldx   #>PATH_SRC
            jsr   OPEN_COMMON
            bcc   :inopened
            jmp   P_ERR
:inopened   sta   CUR_INFD

            lda   #<PATH_OUT6
            ldx   #>PATH_OUT6
            jsr   CREATE_COMMON
            lda   #<PATH_OUT6
            ldx   #>PATH_OUT6
            jsr   OPEN_COMMON
            bcc   :outopened
            jmp   P_ERR
:outopened  sta   CUR_OUTFD

            lda   #<AV_TAIL0
            sta   ARGV_ARR
            lda   #>AV_TAIL0
            sta   ARGV_ARR+1
            stz   ARGV_ARR+2
            stz   ARGV_ARR+3
            jsr   FDA_OUT6IN

            lda   #17
            sta   R_STEP
            jsr   DO_SPAWN
            bcc   :spawned
            jmp   P_ERR
:spawned    sta   R_RUN6+0
            jsr   DO_WAIT
            bcc   :waited
            jmp   P_ERR
:waited     sta   R_RUN6+1
            lda   WAIT_STATUS
            sta   R_RUN6+2

            lda   #18
            sta   R_STEP
            lda   CUR_INFD
            jsr   CLOSE_A
            lda   CUR_OUTFD
            jsr   CLOSE_A
            jsr   REREAD6
            rts

*---------------------------------------------------------------
* FDA_OUTn -- fdactions: dup stdout from CUR_OUTFD, close it,
* END. Shared shape, one per run only because CUR_OUTFD's VALUE
* differs by the time each fires (all read the same scratch
* cell -- named per-run only to keep RUN1..RUN5 symmetric to
* read).
*---------------------------------------------------------------
FDA_OUT1    jsr   FDA_STDOUT
            rts
FDA_OUT2    jsr   FDA_STDOUT
            rts
FDA_OUT3    jsr   FDA_STDOUT
            rts
FDA_OUT4    jsr   FDA_STDOUT
            rts
FDA_OUT5    jsr   FDA_STDOUT
            rts

FDA_STDOUT  lda   #FDACT_DUP
            sta   FDA_BUF
            lda   #FD_STDOUT
            sta   FDA_BUF+1
            lda   CUR_OUTFD
            sta   FDA_BUF+2
            lda   #FDACT_CLOSE
            sta   FDA_BUF+3
            lda   CUR_OUTFD
            sta   FDA_BUF+4
            stz   FDA_BUF+5
            stz   FDA_BUF+6
            rts

*---------------------------------------------------------------
* FDA_OUT6IN -- fdactions for RUN6: dup BOTH stdin (from
* CUR_INFD) and stdout (from CUR_OUTFD), close both, END --
* catreadtestb.s's own SPAWN_CAT shape.
*---------------------------------------------------------------
FDA_OUT6IN  lda   #FDACT_DUP
            sta   FDA_BUF
            lda   #FD_STDIN
            sta   FDA_BUF+1
            lda   CUR_INFD
            sta   FDA_BUF+2
            lda   #FDACT_CLOSE
            sta   FDA_BUF+3
            lda   CUR_INFD
            sta   FDA_BUF+4
            stz   FDA_BUF+5
            lda   #FDACT_DUP
            sta   FDA_BUF+6
            lda   #FD_STDOUT
            sta   FDA_BUF+7
            lda   CUR_OUTFD
            sta   FDA_BUF+8
            lda   #FDACT_CLOSE
            sta   FDA_BUF+9
            lda   CUR_OUTFD
            sta   FDA_BUF+10
            stz   FDA_BUF+11
            stz   FDA_BUF+12
            rts

*---------------------------------------------------------------
* REREADn -- reopen PATH_OUTn, read back up to READBUFLEN bytes,
* stash trans_count + data into R_RUNn, close. Shared copy shape
* -- one per run since the destination base address differs.
*---------------------------------------------------------------
REREAD1     lda   #<PATH_OUT1
            ldx   #>PATH_OUT1
            jsr   OPEN_COMMON
            bcc   :reopened
            jmp   P_ERR
:reopened   sta   CUR_OUTFD
            jsr   READ_UPTO
            bcc   :read
            jmp   P_ERR
:read       lda   READ_PARM+6
            sta   R_RUN1+3
            lda   READ_PARM+7
            sta   R_RUN1+4
            ldy   #0
:cp         cpy   #READBUFLEN
            beq   :cpdone
            lda   IO_BUF,y
            sta   R_RUN1+6,y
            iny
            bra   :cp
:cpdone     lda   CUR_OUTFD
            jsr   CLOSE_A
            rts

REREAD2     lda   #<PATH_OUT2
            ldx   #>PATH_OUT2
            jsr   OPEN_COMMON
            bcc   :reopened
            jmp   P_ERR
:reopened   sta   CUR_OUTFD
            jsr   READ_UPTO
            bcc   :read
            jmp   P_ERR
:read       lda   READ_PARM+6
            sta   R_RUN2+3
            lda   READ_PARM+7
            sta   R_RUN2+4
            ldy   #0
:cp         cpy   #READBUFLEN
            beq   :cpdone
            lda   IO_BUF,y
            sta   R_RUN2+6,y
            iny
            bra   :cp
:cpdone     lda   CUR_OUTFD
            jsr   CLOSE_A
            rts

REREAD3     lda   #<PATH_OUT3
            ldx   #>PATH_OUT3
            jsr   OPEN_COMMON
            bcc   :reopened
            jmp   P_ERR
:reopened   sta   CUR_OUTFD
            jsr   READ_UPTO
            bcc   :read
            jmp   P_ERR
:read       lda   READ_PARM+6
            sta   R_RUN3+3
            lda   READ_PARM+7
            sta   R_RUN3+4
            ldy   #0
:cp         cpy   #READBUFLEN
            beq   :cpdone
            lda   IO_BUF,y
            sta   R_RUN3+6,y
            iny
            bra   :cp
:cpdone     lda   CUR_OUTFD
            jsr   CLOSE_A
            rts

REREAD4     lda   #<PATH_OUT4
            ldx   #>PATH_OUT4
            jsr   OPEN_COMMON
            bcc   :reopened
            jmp   P_ERR
:reopened   sta   CUR_OUTFD
            jsr   READ_UPTO
            bcc   :read
            jmp   P_ERR
:read       lda   READ_PARM+6
            sta   R_RUN4+3
            lda   READ_PARM+7
            sta   R_RUN4+4
            ldy   #0
:cp         cpy   #READBUFLEN
            beq   :cpdone
            lda   IO_BUF,y
            sta   R_RUN4+6,y
            iny
            bra   :cp
:cpdone     lda   CUR_OUTFD
            jsr   CLOSE_A
            rts

REREAD5     lda   #<PATH_OUT5
            ldx   #>PATH_OUT5
            jsr   OPEN_COMMON
            bcc   :reopened
            jmp   P_ERR
:reopened   sta   CUR_OUTFD
            jsr   READ_UPTO
            bcc   :read
            jmp   P_ERR
:read       lda   READ_PARM+6
            sta   R_RUN5+3
            lda   READ_PARM+7
            sta   R_RUN5+4
            ldy   #0
:cp         cpy   #READBUFLEN
            beq   :cpdone
            lda   IO_BUF,y
            sta   R_RUN5+6,y
            iny
            bra   :cp
:cpdone     lda   CUR_OUTFD
            jsr   CLOSE_A
            rts

REREAD6     lda   #<PATH_OUT6
            ldx   #>PATH_OUT6
            jsr   OPEN_COMMON
            bcc   :reopened
            jmp   P_ERR
:reopened   sta   CUR_OUTFD
            jsr   READ_UPTO
            bcc   :read
            jmp   P_ERR
:read       lda   READ_PARM+6
            sta   R_RUN6+3
            lda   READ_PARM+7
            sta   R_RUN6+4
            ldy   #0
:cp         cpy   #READBUFLEN
            beq   :cpdone
            lda   IO_BUF,y
            sta   R_RUN6+6,y
            iny
            bra   :cp
:cpdone     lda   CUR_OUTFD
            jsr   CLOSE_A
            rts

*---------------------------------------------------------------
* Static text this process reads while running IN BANK 1 --
* MUST stay inside PARENT_PROC..PAR_PROC_LEN (see this file's
* own header). MLI pathnames: 1-byte count + raw chars (`asc`
* already emits the bytes ProDOS's OPEN/CREATE accept as-is,
* catreadtestb.s's own SRC_PATH_TXT precedent). argv text and
* the spawn path: liba's high-bit NUL-terminated convention
* (also plain `asc`, see wc.s's WCOPTS: high-bit chars, not
* 7-bit).
*---------------------------------------------------------------
AV_PATH_TAIL
            asc   "/bin/TAIL"
            dfb   0

PATH_SRC    dfb   17
            asc   "/mnt/MAUX/TAILSRC"
PATH_MT     dfb   16
            asc   "/mnt/MAUX/TAILMT"
PATH_NOCR   dfb   18
            asc   "/mnt/MAUX/TAILNOCR"
PATH_OUT1   dfb   18
            asc   "/mnt/MAUX/TAILOUT1"
PATH_OUT2   dfb   18
            asc   "/mnt/MAUX/TAILOUT2"
PATH_OUT3   dfb   18
            asc   "/mnt/MAUX/TAILOUT3"
PATH_OUT4   dfb   18
            asc   "/mnt/MAUX/TAILOUT4"
PATH_OUT5   dfb   18
            asc   "/mnt/MAUX/TAILOUT5"
PATH_OUT6   dfb   18
            asc   "/mnt/MAUX/TAILOUT6"

AV_TAIL0    asc   "TAIL"
            dfb   0
AV_M3       asc   "-3"
            dfb   0
AV_M20      asc   "-20"
            dfb   0
AV_M2       asc   "-2"
            dfb   0
AV_SRC      asc   "/mnt/MAUX/TAILSRC"
            dfb   0
AV_MT       asc   "/mnt/MAUX/TAILMT"
            dfb   0
AV_NOCR     asc   "/mnt/MAUX/TAILNOCR"
            dfb   0

PAR_PROC_LEN equ *-PARENT_PROC
